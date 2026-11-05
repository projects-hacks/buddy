//
//  LearningMemory.swift
//  leanring-buddy
//
//  What Buddy remembers about what the student has learned, across days and
//  relaunches, so an answer can build on an earlier one ("the same trade-off
//  as the consistent hashing from Tuesday") instead of starting from zero
//  every time.
//
//  Built the way production agent memory is built, and kept on the Mac:
//
//  - Write after, read during. Filing a lesson away (naming its ideas,
//    matching them to ones already known, writing the plain-words cues a
//    student might use for each) happens after the answer has been spoken,
//    off the student's clock. Reading happens while they wait, as a cascade:
//    an on-device scan (ConceptIndex, a few milliseconds even at 5,000
//    ideas) shortlists, and Claude Haiku chooses from the shortlist while the
//    screen is being captured, so the wait does not grow. Late or keyless, a
//    names-only match on the device stands in. On 80 blind questions the
//    cascade found 96% of the right ideas at 88 to 91% precision; names alone
//    found 48% at 94%. (scripts/learning_memory)
//  - Extract, then update, not append. Like Mem0 (arXiv 2504.19413), each
//    new explanation is matched against the nearest ideas already known and
//    either updates one of them or adds a new one, so the store grows with
//    the number of ideas, not the number of questions. Claude Haiku does the
//    naming and matching when there is a key; without one the lesson's title
//    stands in, matched by name.
//  - Stale data is handled three ways. A concept keeps only the latest
//    explanation of it, never an old one alongside, the way Zep marks a
//    superseded fact invalid rather than keeping both. How well the student
//    probably still remembers it follows a forgetting curve (FSRS), which
//    decides whether the tutor builds on it, gives a one-line reminder first,
//    or treats it as new. And ideas met once and not seen for months are
//    moved out of the live index into an archive, restored if they come up
//    again, so the index stays small however long the student studies.
//  - The sentence model can change under us with a macOS update, which would
//    make old vectors meaningless next to new ones. The model's identity is
//    stored with the vectors, and a mismatch re-embeds everything quietly in
//    the background, with words-only recall working meanwhile.
//
//  Files, in ~/Library/Application Support/Buddy/Memory, never leaving
//  the Mac: concepts.json (what is known), vectors.bin (their vectors),
//  archive.json (set aside), lessons.jsonl (an append-only log of every
//  lesson, the record everything else could be rebuilt from).
//

import Foundation

/// One finished lesson, as handed over for filing.
struct LessonToRemember {
    let question: String
    let lessonTitle: String?
    let spokenAnswer: String
    let questionKind: String
    let answeredBy: String
    let date: Date
}

/// An idea named by the extractor for one lesson.
struct ExtractedConcept {
    let name: String
    /// The id of a known concept it is the same idea as, if any.
    let sameAsID: UUID?
    let aliases: [String]
    let cues: [String]
    let summary: String
    let angle: String?
    /// How it relates to the known ideas it was shown with. Nil when the
    /// extractor was not asked (no key), so the map's one-time pass can.
    var relations: [ConceptRelation]? = nil
}

/// Whether a known idea the filing call says a lesson is the same as can be
/// believed on the Mac's own evidence, before its explanation is replaced.
/// Graded by scripts/learning_memory/filing_check.swift.
nonisolated enum FilingMatchCheck {
    /// The new name and a known name or alias, or a new alias and the known
    /// name, where one's words hold all of the other's: "binary heap" and
    /// "heap", "off-by-one bounds" and the alias "off-by-one", the alias
    /// "consistent hashing node addition" and "consistent hashing". A known
    /// alias of one everyday word ("index") is too loose to count unless it
    /// is the whole new name. Two aliases alone never count, since related
    /// ideas share them ("index out of range" is kept on both "off by one
    /// error" and "array index out of bounds").
    ///
    /// Meaning is not used. The sentence model puts different ideas on one
    /// real store between 0.88 and 0.98 and the same idea filed twice between
    /// 0.94 and 0.99, and the off-by-one lesson scored 0.96 against "division
    /// by zero", so no floor keeps real matches and refuses that one.
    static func namesAgree(extractedName: String, extractedAliases: [String], known: RememberedConcept) -> Bool {
        let extractedNameWords = words(of: extractedName)
        let knownNameWords = words(of: known.name)
        guard !extractedNameWords.isEmpty, !knownNameWords.isEmpty else { return false }
        let knownAliasWords = known.aliases.map { words(of: $0) }.filter { !$0.isEmpty }
        if knownAliasWords.contains(extractedNameWords) { return true }
        let knownLabelsSpecificEnough = [knownNameWords] + knownAliasWords.filter { aliasWords in
            aliasWords.count > 1 || aliasWords.allSatisfy(ConceptText.looksLikeTermOfArt)
        }
        if knownLabelsSpecificEnough.contains(where: { oneHoldsTheOther(extractedNameWords, $0) }) { return true }
        return extractedAliases.map { words(of: $0) }.contains { aliasWords in
            let isSpecificEnough = aliasWords.count > 1 || aliasWords.allSatisfy(ConceptText.looksLikeTermOfArt)
            return (aliasWords == knownNameWords) || (isSpecificEnough && oneHoldsTheOther(aliasWords, knownNameWords))
        }
    }

    private static func words(of label: String) -> Set<String> {
        Set(ConceptText.tokens(label.lowercased()))
    }

    private static func oneHoldsTheOther(_ firstWords: Set<String>, _ secondWords: Set<String>) -> Bool {
        firstWords.isSubset(of: secondWords) || secondWords.isSubset(of: firstWords)
    }
}

@MainActor
final class LearningMemory {
    static let enabledDefaultsKey = "learningMemoryEnabled"

    /// Turns a sentence into the sorter's unit vector, or nil while the model
    /// is not ready.
    var embed: (String) -> [Float]? = { _ in nil }
    /// Which sentence model `embed` uses, so vectors from another are never
    /// compared with its.
    var embeddingModelIdentifier: () -> String? = { nil }
    /// Names the ideas in a lesson. Nil when there is no way to (no key).
    var extract: ((LessonToRemember, [RememberedConcept]) async -> [ExtractedConcept]?)?
    /// Picks, from a shortlist, the ideas a question is about, as positions.
    /// Nil result means it could not answer.
    var choose: ((String, String?, [RememberedConcept]) async -> [Int]?)?
    // Notebook hook: told the ideas each lesson was filed under, so its
    // notebook page can list them with when to review them.
    var onLessonFiled: ((LessonToRemember, [RememberedConcept]) -> Void)?

    private(set) var index: ConceptIndex = {
        var index = ConceptIndex()
        index.tuning = .namesOnly
        return index
    }()
    private var archived: [RememberedConcept] = []
    private var storedEmbeddingModelIdentifier: String?
    /// The ideas of the last lesson, which "I didn't follow" is about.
    private var lastLessonConceptIDs: [UUID] = []
    private(set) var isLoaded = false

    /// The ideas explained most recently, for the speech recognizer to
    /// expect: a student keeps using the words of what they are studying.
    func recentlyExplainedConceptNames(limit: Int) -> [String] {
        index.concepts.sorted { $0.lastExplainedAt > $1.lastExplainedAt }.prefix(limit).map(\.name)
    }

    /// The idea most worth teaching back now, for the notch's home: one that
    /// is fading (recall between 60 and 85%), the most faded of those, so the
    /// review lands before it is lost. Nil when nothing is fading, since a
    /// start tile that cannot act is never shown.
    func ideaFadingMost(now: Date = Date()) -> RememberedConcept? {
        guard isEnabled else { return nil }
        let fading = index.concepts.compactMap { concept -> (concept: RememberedConcept, retrievability: Double)? in
            let elapsedDays = now.timeIntervalSince(concept.lastExplainedAt) / 86_400
            let retrievability = ForgettingCurve.retrievability(elapsedDays: elapsedDays, stabilityDays: concept.stabilityDays)
            guard retrievability >= 0.6, retrievability < 0.85 else { return nil }
            return (concept, retrievability)
        }
        return fading.min { $0.retrievability < $1.retrievability }?.concept
    }
    /// Bumped by forgetEverything, so work that started before it (a lesson
    /// waiting on Haiku, the re-embedding loop) never writes anything back.
    private var memoryGeneration = 0
    private var isFilingLesson = false
    private var wasLostDuringFiling = false

    private let ioQueue = DispatchQueue(label: "clicky.learning-memory", qos: .utility)
    private let folder: URL

    /// The folder is a parameter only so scripts/learning_memory can test the
    /// real store in a scratch folder; the app uses the default.
    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(AppIdentity.dataName)/Memory")) {
        self.folder = folder
    }

    /// Waits for every pending write, for tests that read the files back.
    func flushWrites() async {
        await withCheckedContinuation { continuation in ioQueue.async { continuation.resume() } }
    }

    /// More than years of study produce; past it the weakest go to the archive.
    private static let maximumActiveConcepts = 5_000
    /// Met once, never again, and this long ago: set aside.
    private static let archiveAfterDays = 120.0
    /// Explained again within this, it is the same sitting, not a spaced
    /// review, and does not strengthen the memory.
    private static let sameSittingSeconds: TimeInterval = 60 * 60
    /// Explained within this, it is still in the conversation history the
    /// model sees, so repeating it in the note would only cost tokens.
    /// A variable only so a scripted test can shorten it.
    static var stillInConversationSeconds: TimeInterval = 20 * 60

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    var conceptCount: Int { index.count }

    // MARK: - Loading

    /// Reads the store off the main thread. Safe to call at launch: until it
    /// finishes, recall finds nothing and the tutor answers as it always has.
    func load() async {
        let folder = self.folder
        let snapshot = await withCheckedContinuation { (continuation: CheckedContinuation<StoreSnapshot?, Never>) in
            ioQueue.async { continuation.resume(returning: StoreFiles.read(from: folder)) }
        }
        guard let snapshot else {
            isLoaded = true
            TutorDebugLog.write("🧠 memory: starting empty")
            return
        }

        storedEmbeddingModelIdentifier = snapshot.embeddingModelIdentifier
        archived = snapshot.archived
        var restoredIndex = ConceptIndex()
        restoredIndex.tuning = .namesOnly
        restoredIndex.bulkInsert(snapshot.concepts.map { ($0, snapshot.vectors[$0.id]) })
        index = restoredIndex
        isLoaded = true
        let archivedNow = sweepStaleConcepts(now: Date())
        TutorDebugLog.write("🧠 memory: \(index.count) ideas known, \(archived.count) archived"
            + (archivedNow > 0 ? ", \(archivedNow) set aside as stale" : ""))
        if archivedNow > 0 { save() }
    }

    /// Embeds concepts that have no vector, or whose vector came from another
    /// sentence model. In small batches with pauses, after launch, so it
    /// never competes with a question.
    func embedMissingVectorsInBackground() async {
        guard let currentModel = embeddingModelIdentifier() else { return }
        let modelChanged = storedEmbeddingModelIdentifier != nil && storedEmbeddingModelIdentifier != currentModel
        if modelChanged {
            TutorDebugLog.write("🧠 memory: sentence model changed, re-embedding \(index.count) ideas")
        }
        let needingVectors = index.concepts.indices.filter { modelChanged || index.vector(at: $0) == nil }
            .map { index.concepts[$0].id }
        guard !needingVectors.isEmpty else {
            storedEmbeddingModelIdentifier = currentModel
            return
        }
        let generation = memoryGeneration
        for (count, id) in needingVectors.enumerated() {
            // Read the concept as it is now, not as it was when the loop
            // began: a lesson filed during a pause must not be overwritten,
            // and an idea archived or forgotten meanwhile stays gone.
            guard memoryGeneration == generation else { return }
            if let position = index.index(of: id),
               let vector = embed(Self.embeddingText(for: index.concepts[position])) {
                index.setVector(vector, for: id)
            }
            if count % 20 == 19 { try? await Task.sleep(nanoseconds: 80_000_000) }
        }
        guard memoryGeneration == generation else { return }
        storedEmbeddingModelIdentifier = currentModel
        save()
    }

    // MARK: - Reading, on the student's clock

    /// Starts recall the moment the question is in, so Haiku chooses while
    /// the screen is captured. The task's value is nil when Haiku could not
    /// answer, and the caller then uses `namesOnlyRecall`.
    func startRecall(question: String, windowTitle: String?, questionVector: [Float]?) -> Task<[ConceptRecollection]?, Never> {
        guard isEnabled, isLoaded, index.count > 0 else { return Task { [] } }
        let started = DispatchTime.now().uptimeNanoseconds
        let shortlist = index.candidates(questionText: question, contextText: windowTitle ?? "", questionVector: questionVector)
            .filter { Date().timeIntervalSince($0.lastExplainedAt) > Self.stillInConversationSeconds }
        let shortlistMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        guard !shortlist.isEmpty else { return Task { [] } }
        guard let choose else { return Task { nil } }
        return Task {
            guard let chosen = await choose(question, windowTitle, shortlist) else { return nil }
            let now = Date()
            let found = chosen.map { position -> ConceptRecollection in
                let concept = shortlist[position]
                return ConceptRecollection(
                    concept: concept, score: 1,
                    retrievability: ForgettingCurve.retrievability(
                        elapsedDays: now.timeIntervalSince(concept.lastExplainedAt) / 86_400,
                        stabilityDays: concept.stabilityDays))
            }
            if !found.isEmpty {
                TutorDebugLog.write(String(format: "🧠 memory: recalled %@ (shortlist of %d in %.1f ms, chosen by haiku)",
                                           found.map(\.concept.name).joined(separator: ", "), shortlist.count, shortlistMilliseconds))
            }
            return found
        }
    }

    /// Recall from names alone, on the device: for when Haiku is late or
    /// there is no key. Rarely wrong, and finds about half as much.
    func namesOnlyRecall(question: String, screenContext: String) -> [ConceptRecollection] {
        guard isEnabled, isLoaded, index.count > 0 else { return [] }
        let now = Date()
        let found = index.recall(questionText: question, contextText: screenContext, questionVector: nil, limit: 3, now: now)
            .filter { now.timeIntervalSince($0.concept.lastExplainedAt) > Self.stillInConversationSeconds }
        if !found.isEmpty {
            TutorDebugLog.write("🧠 memory: recalled \(found.map(\.concept.name).joined(separator: ", ")) by name")
        }
        return found
    }

    /// What the tutor is told about the student's history with these ideas.
    static func promptNote(for recollections: [ConceptRecollection], now: Date = Date()) -> String {
        guard !recollections.isEmpty else { return "" }
        var lines = ["WHAT THEY HAVE LEARNED WITH YOU BEFORE, in earlier sessions. use it the way a friend who was there would: connect the new idea to it in a sentence (\"the same trade-off as the consistent hashing from tuesday\"). never say you have a memory or notes, never quiz them on it."]
        for recollection in recollections {
            let concept = recollection.concept
            let when = describe(elapsedFrom: concept.lastExplainedAt, to: now)
            let times = concept.timesExplained == 1 ? "explained once" : "explained \(concept.timesExplained) times"
            var line = "- \(concept.name): \(times), last \(when). last time: \"\(concept.summary)\"."
            if let lastLostAt = concept.lastLostAt, now.timeIntervalSince(lastLostAt) < 30 * 86_400 {
                let angle = concept.lastAngle.map { " with \"\($0)\"" } ?? ""
                line += " they did not follow it \(describe(elapsedFrom: lastLostAt, to: now))\(angle): use a different example this time."
            } else if recollection.retrievability >= 0.85 {
                line += " probably still fresh: build on it, do not re-teach it."
            } else if recollection.retrievability >= 0.6 {
                line += " probably fading: one sentence of reminder, then build on it."
            } else {
                line += " probably forgotten: teach it again from the start, mentioning in passing that they met it \(when)."
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(elapsedFrom date: Date, to now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "earlier today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        if days < 7 {
            let weekday = DateFormatter()
            weekday.dateFormat = "EEEE"
            return "on \(weekday.string(from: date).lowercased())"
        }
        if days < 15 { return "\(days) days ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return "on \(formatter.string(from: date))"
    }

    // MARK: - Writing, after the answer

    /// The student said they did not follow the last lesson.
    ///
    /// If that lesson is still being filed (Haiku takes a few seconds), the
    /// mark waits for it, rather than landing on the lesson before.
    func studentGotLost() {
        guard isEnabled else { return }
        if isFilingLesson {
            wasLostDuringFiling = true
            return
        }
        markLost(lastLessonConceptIDs)
    }

    private func markLost(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let now = Date()
        for id in ids {
            guard let position = index.index(of: id) else { continue }
            var concept = index.concepts[position]
            concept.timesLost += 1
            concept.lastLostAt = now
            concept.stabilityDays = ForgettingCurve.stabilityAfterGettingLost(concept.stabilityDays)
            index.upsert(concept, vector: index.vector(at: position))
        }
        save()
    }

    // MARK: Teach it back hook (TeachBackSession.swift)

    /// The student explained a topic back. What they got right was
    /// recalled, which strengthens it as a review would (the FSRS curve
    /// starts again from now, with the stability a successful recall
    /// earns); what they missed or got wrong counts as lost, as "I didn't
    /// follow" does, so the map shows those ideas fading. Ideas are found
    /// by name or alias, then by the names-only match; a missed idea memory
    /// does not hold on its own counts against the topic it belongs to. A
    /// topic memory has never seen is filed as a lesson first.
    func recordTeachBack(_ lesson: LessonToRemember, topic: String, rightIdeas: [String], missedIdeas: [String]) async {
        guard isEnabled, isLoaded else { return }
        let topicID = knownConceptID(named: topic)
        var rightIDs = Set(rightIdeas.compactMap(knownConceptID(named:)))
        var missedIDs = Set(missedIdeas.compactMap(knownConceptID(named:)))
        let someMissedIdeaIsUnknown = missedIdeas.contains { knownConceptID(named: $0) == nil }

        if topicID == nil && rightIDs.isEmpty && missedIDs.isEmpty {
            // New to memory: filed from what Buddy said about it, so its
            // summary is the right version, then weakened by the gaps.
            await remember(lesson)
            if !missedIdeas.isEmpty { markLost(lastLessonConceptIDs) }
            TutorDebugLog.write("🧠 memory: teach-back of a new topic, filed\(missedIdeas.isEmpty ? "" : " and marked weak")")
            return
        }
        appendToLessonLog(lesson)
        if let topicID {
            if someMissedIdeaIsUnknown { missedIDs.insert(topicID) } else if missedIDs.isEmpty { rightIDs.insert(topicID) }
        }
        rightIDs.subtract(missedIDs)
        let now = lesson.date
        for id in rightIDs {
            guard let position = index.index(of: id) else { continue }
            var concept = index.concepts[position]
            let elapsedDays = now.timeIntervalSince(concept.lastExplainedAt) / 86_400
            if now.timeIntervalSince(concept.lastExplainedAt) > Self.sameSittingSeconds {
                let retrievability = ForgettingCurve.retrievability(elapsedDays: elapsedDays, stabilityDays: concept.stabilityDays)
                concept.stabilityDays = ForgettingCurve.stabilityAfterReexplaining(concept.stabilityDays,
                                                                                   retrievabilityAtTheTime: retrievability)
            }
            concept.lastExplainedAt = now
            index.upsert(concept, vector: index.vector(at: position))
        }
        markLost(Array(missedIDs))
        let touched = (rightIDs.union(missedIDs)).compactMap { id in index.index(of: id).map { index.concepts[$0] } }
        onLessonFiled?(lesson, touched)
        TutorDebugLog.write("🧠 memory: teach-back strengthened \(rightIDs.count), marked \(missedIDs.count) lost")
        save()
    }

    /// A known idea by its name or an alias, else the best names-only match.
    private func knownConceptID(named name: String) -> UUID? {
        let normalised = ConceptText.normalisedName(name.lowercased())
        guard !normalised.isEmpty else { return nil }
        if let exact = index.concepts.first(where: { known in
            ConceptText.normalisedName(known.name) == normalised
                || known.aliases.contains { ConceptText.normalisedName($0) == normalised }
        }) {
            return exact.id
        }
        return namesOnlyRecall(question: name, screenContext: "").first?.concept.id
    }

    /// Files one finished lesson away. Runs after the answer; nothing waits on it.
    func remember(_ lesson: LessonToRemember) async {
        guard isEnabled else { return }
        appendToLessonLog(lesson)
        guard isLoaded else { return }
        let generation = memoryGeneration
        isFilingLesson = true
        defer { isFilingLesson = false }

        // The nearest known ideas, so the extractor can say "same as" rather
        // than inventing a second name for one idea.
        let lessonVector = embed("\(lesson.lessonTitle ?? "") \(lesson.question)")
        var candidates = index.candidates(questionText: lesson.question + " " + (lesson.lessonTitle ?? ""),
                                          contextText: "", questionVector: lessonVector, limit: 10)
        for concept in lessonVector.map({ index.nearestByMeaning(to: $0, limit: 6) }) ?? []
        where !candidates.contains(where: { $0.id == concept.id }) {
            candidates.append(concept)
        }

        var extracted: [ExtractedConcept]?
        if let extract {
            extracted = await extract(lesson, candidates)
        }
        if extracted == nil {
            extracted = Self.fallbackConcepts(for: lesson)
        }
        // Forgotten while Haiku was working: the lesson goes with the rest.
        guard memoryGeneration == generation else { return }
        guard let extracted, !extracted.isEmpty else {
            lastLessonConceptIDs = []
            return
        }

        var filedIDs: [UUID] = []
        for concept in extracted.prefix(3) {
            filedIDs.append(file(concept, from: lesson))
        }
        lastLessonConceptIDs = filedIDs
        if wasLostDuringFiling {
            wasLostDuringFiling = false
            markLost(filedIDs)
        }
        _ = sweepStaleConcepts(now: lesson.date)
        onLessonFiled?(lesson, filedIDs.compactMap { id in index.index(of: id).map { index.concepts[$0] } })
        TutorDebugLog.write("🧠 memory: filed \(extracted.prefix(3).map(\.name).joined(separator: ", ")) (\(index.count) ideas known)")
        save()
    }

    /// Updates the idea if it is already known (by the extractor's match, by
    /// name, or from the archive), adds it otherwise. Returns its id.
    private func file(_ extracted: ExtractedConcept, from lesson: LessonToRemember) -> UUID {
        let name = String(extracted.name.lowercased().prefix(60)).trimmingCharacters(in: .whitespaces)
        let normalised = ConceptText.normalisedName(name)

        var existingPosition: Int?
        if let sameAsID = extracted.sameAsID, let matchedPosition = index.index(of: sameAsID) {
            // The filing call names a match only by a short id, and a wrong
            // id once filed an off-by-one lesson under "division by zero",
            // which then explained off-by-one under that name. Updating a
            // known idea replaces its explanation, so the match is kept only
            // when the names agree; otherwise the lesson is filed by its own
            // name, as a new idea when no known one has it.
            let matchedConcept = index.concepts[matchedPosition]
            if FilingMatchCheck.namesAgree(extractedName: name, extractedAliases: extracted.aliases, known: matchedConcept) {
                existingPosition = matchedPosition
            } else {
                TutorDebugLog.write("🧠 memory: the filing call matched \(name) to \(matchedConcept.name), which shares no name with it, so \(matchedConcept.name) is left as it was")
            }
        }
        if existingPosition == nil {
            existingPosition = index.concepts.firstIndex { known in
                ConceptText.normalisedName(known.name) == normalised
                    || known.aliases.contains { ConceptText.normalisedName($0) == normalised }
            }
        }
        if existingPosition == nil,
           let archivedPosition = archived.firstIndex(where: { ConceptText.normalisedName($0.name) == normalised }) {
            // Back from the archive, history intact.
            let restored = archived.remove(at: archivedPosition)
            index.upsert(restored, vector: embed(Self.embeddingText(for: restored)))
            existingPosition = index.index(of: restored.id)
        }

        let summary = String(extracted.summary.prefix(240))
        if let existingPosition {
            var concept = index.concepts[existingPosition]
            let elapsed = lesson.date.timeIntervalSince(concept.lastExplainedAt)
            if elapsed > Self.sameSittingSeconds {
                let retrievability = ForgettingCurve.retrievability(
                    elapsedDays: elapsed / 86_400, stabilityDays: concept.stabilityDays)
                concept.stabilityDays = ForgettingCurve.stabilityAfterReexplaining(
                    concept.stabilityDays, retrievabilityAtTheTime: retrievability)
                concept.timesExplained += 1
            }
            concept.lastExplainedAt = lesson.date
            // The latest explanation replaces the old one: the note must
            // describe what the student last heard, not what they heard first.
            if !summary.isEmpty { concept.summary = summary }
            if let angle = extracted.angle, !angle.isEmpty { concept.lastAngle = String(angle.prefix(80)) }
            for alias in extracted.aliases.map({ $0.lowercased() })
            where !alias.isEmpty && alias != concept.name && !concept.aliases.contains(alias) && concept.aliases.count < 6 {
                concept.aliases.append(alias)
            }
            // New cues first, then the old ones, capped: a concept explained
            // many times keeps a bounded vocabulary, weighted to the recent.
            if !extracted.cues.isEmpty {
                var merged: [String] = []
                for cue in extracted.cues.map({ $0.lowercased() }) + (concept.cues ?? []) where !merged.contains(cue) {
                    merged.append(cue)
                }
                concept.cues = Array(merged.prefix(24))
            }
            if let title = lesson.lessonTitle, concept.lessonTitles.last != title {
                concept.lessonTitles = Array((concept.lessonTitles + [title]).suffix(5))
            }
            concept.relations = Self.mergedRelations(
                existing: concept.relations, new: extracted.relations, ownID: concept.id)
            index.upsert(concept, vector: embed(Self.embeddingText(for: concept)))
            return concept.id
        }

        let newID = UUID()
        let concept = RememberedConcept(
            id: newID, name: name,
            aliases: Array(extracted.aliases.map { $0.lowercased() }.filter { !$0.isEmpty && $0 != name }.prefix(6)),
            cues: Array(extracted.cues.map { $0.lowercased() }.prefix(24)),
            summary: summary, lastAngle: extracted.angle.map { String($0.prefix(80)) },
            firstExplainedAt: lesson.date, lastExplainedAt: lesson.date,
            timesExplained: 1, timesLost: 0, lastLostAt: nil,
            stabilityDays: ForgettingCurve.initialStabilityDays,
            lessonTitles: lesson.lessonTitle.map { [$0] } ?? [],
            relations: Self.mergedRelations(existing: nil, new: extracted.relations, ownID: newID)
        )
        index.upsert(concept, vector: embed(Self.embeddingText(for: concept)))
        return concept.id
    }

    /// The newest links first, then the older ones to other ideas, capped so
    /// an idea explained many times keeps a readable handful on the map. A
    /// lesson filed without asking (nil) keeps what was there.
    static func mergedRelations(existing: [ConceptRelation]?, new: [ConceptRelation]?, ownID: UUID) -> [ConceptRelation]? {
        guard let new else { return existing }
        var merged: [ConceptRelation] = []
        for relation in new + (existing ?? [])
        where relation.targetID != ownID && !merged.contains(where: { $0.targetID == relation.targetID }) {
            merged.append(relation)
        }
        return Array(merged.prefix(8))
    }

    /// Without a key: the lesson's own title is the idea, and its first
    /// spoken sentence the summary. Coarser, but it still lets a later
    /// question find the lesson by name.
    private static func fallbackConcepts(for lesson: LessonToRemember) -> [ExtractedConcept]? {
        guard let title = lesson.lessonTitle, !title.isEmpty else { return nil }
        let firstSentence = lesson.spokenAnswer.split(separator: ".").first.map(String.init) ?? ""
        return [ExtractedConcept(name: title.lowercased(), sameAsID: nil, aliases: [], cues: [],
                                 summary: firstSentence, angle: nil)]
    }

    static func embeddingText(for concept: RememberedConcept) -> String {
        "\(concept.name): \(concept.summary)"
    }

    /// Moves ideas met once and long forgotten, and the weakest past the
    /// size limit, out of the live index. Returns how many moved.
    @discardableResult
    private func sweepStaleConcepts(now: Date) -> Int {
        var toArchive: [UUID] = []
        for concept in index.concepts {
            let elapsedDays = now.timeIntervalSince(concept.lastExplainedAt) / 86_400
            let retrievability = ForgettingCurve.retrievability(elapsedDays: elapsedDays, stabilityDays: concept.stabilityDays)
            if concept.timesExplained == 1, elapsedDays > Self.archiveAfterDays, retrievability < 0.6 {
                toArchive.append(concept.id)
            }
        }
        let remaining = index.count - toArchive.count
        if remaining > Self.maximumActiveConcepts {
            let weakest = index.concepts
                .filter { !toArchive.contains($0.id) }
                .sorted { strength(of: $0, now: now) < strength(of: $1, now: now) }
                .prefix(remaining - Self.maximumActiveConcepts)
            toArchive.append(contentsOf: weakest.map(\.id))
        }
        for id in toArchive {
            if let position = index.index(of: id) {
                archived.append(index.concepts[position])
                index.remove(id: id)
            }
        }
        return toArchive.count
    }

    private func strength(of concept: RememberedConcept, now: Date) -> Double {
        let elapsedDays = now.timeIntervalSince(concept.lastExplainedAt) / 86_400
        return ForgettingCurve.retrievability(elapsedDays: elapsedDays, stabilityDays: concept.stabilityDays)
            * log(1 + Double(concept.timesExplained))
    }

    // MARK: - The student's control

    /// Deletes everything remembered. Asked for in Settings, nowhere else.
    func forgetEverything() {
        memoryGeneration += 1
        wasLostDuringFiling = false
        index = ConceptIndex()
        index.tuning = .namesOnly
        archived = []
        lastLessonConceptIDs = []
        let folder = self.folder
        ioQueue.async { try? FileManager.default.removeItem(at: folder) }
        TutorDebugLog.write("🧠 memory: forgotten at the student's request")
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - The map of what the student knows (KnowledgeMapWindow.swift)

    /// Posted on the main actor after anything remembered changes, so an open
    /// map can redraw with the new idea without polling.
    static let didChangeNotification = Notification.Name("LearningMemoryDidChange")

    /// Forgets one idea, from the map, after the student confirmed. It goes
    /// from the archive too, and every link to it goes with it, so it cannot
    /// come back as a dangling edge or be restored by a later lesson's name.
    func forgetConcept(id: UUID) {
        guard index.index(of: id) != nil || archived.contains(where: { $0.id == id }) else { return }
        let forgottenName = index.index(of: id).map { index.concepts[$0].name }
        index.remove(id: id)
        archived.removeAll { $0.id == id }
        lastLessonConceptIDs.removeAll { $0 == id }
        removeRelations(pointingAt: id)
        TutorDebugLog.write("🧠 memory: forgot \(forgottenName ?? "an archived idea") at the student's request")
        save()
    }

    /// Adds the links the map's one-time pass found to ideas that had none
    /// on record. Ideas that already have relations (filed since) keep their
    /// own, since those came from the lesson itself.
    func applyBackfilledRelations(_ relationsByConceptID: [UUID: [ConceptRelation]]) {
        var changed = 0
        for (id, relations) in relationsByConceptID {
            guard let position = index.index(of: id) else { continue }
            var concept = index.concepts[position]
            guard concept.relations == nil else { continue }
            concept.relations = Self.mergedRelations(
                existing: nil, new: relations.filter { index.index(of: $0.targetID) != nil }, ownID: id)
            index.upsert(concept, vector: index.vector(at: position))
            changed += 1
        }
        guard changed > 0 else { return }
        TutorDebugLog.write("🧠 memory: gave \(changed) older ideas their relations for the map")
        save()
    }

    private func removeRelations(pointingAt id: UUID) {
        for position in index.concepts.indices {
            var concept = index.concepts[position]
            guard let relations = concept.relations, relations.contains(where: { $0.targetID == id }) else { continue }
            concept.relations = relations.filter { $0.targetID != id }
            index.upsert(concept, vector: index.vector(at: position))
        }
        for position in archived.indices {
            archived[position].relations = archived[position].relations?.filter { $0.targetID != id }
        }
    }

    // MARK: - Files

    private func appendToLessonLog(_ lesson: LessonToRemember) {
        let record: [String: String] = [
            "date": ISO8601DateFormatter().string(from: lesson.date),
            "question": lesson.question,
            "lesson": lesson.lessonTitle ?? "",
            "kind": lesson.questionKind,
            "brain": lesson.answeredBy
        ]
        let folder = self.folder
        ioQueue.async {
            guard var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            line.append(0x0A)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("lessons.jsonl")
            // The throwing calls: the older `write(_:)` raises an exception
            // on a full disk, which Swift cannot catch.
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } catch {
                    TutorDebugLog.write("⚠️ lesson log not saved: \(error.localizedDescription)")
                }
            } else {
                try? line.write(to: file)
            }
        }
    }

    private func save() {
        var vectors: [UUID: [Float]] = [:]
        for position in index.concepts.indices {
            if let vector = index.vector(at: position) { vectors[index.concepts[position].id] = vector }
        }
        let snapshot = StoreSnapshot(
            concepts: index.concepts, vectors: vectors, archived: archived,
            embeddingModelIdentifier: storedEmbeddingModelIdentifier ?? embeddingModelIdentifier()
        )
        let folder = self.folder
        ioQueue.async { StoreFiles.write(snapshot, to: folder) }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

/// Everything on disk, read and written as a whole, off the main thread.
private struct StoreSnapshot {
    let concepts: [RememberedConcept]
    let vectors: [UUID: [Float]]
    let archived: [RememberedConcept]
    let embeddingModelIdentifier: String?
}

private enum StoreFiles {
    private struct ConceptsFile: Codable {
        var version = 1
        let embeddingModel: String?
        let concepts: [RememberedConcept]
    }

    /// "BUDV", then the vector length and count, then per concept its id's
    /// 16 bytes and its floats. Binary because thousands of 512-float vectors
    /// as JSON text would be slow to read at every launch.
    private static let magic: [UInt8] = Array("BUDV".utf8)

    static func read(from folder: URL) -> StoreSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let conceptsFile = folder.appendingPathComponent("concepts.json")
        guard let data = try? Data(contentsOf: conceptsFile) else { return nil }
        guard let file = try? decoder.decode(ConceptsFile.self, from: data) else {
            let aside = folder.appendingPathComponent("concepts.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: conceptsFile, to: aside)
            return nil
        }
        let archived = (try? Data(contentsOf: folder.appendingPathComponent("archive.json")))
            .flatMap { try? decoder.decode([RememberedConcept].self, from: $0) } ?? []
        return StoreSnapshot(
            concepts: file.concepts,
            vectors: readVectors(folder.appendingPathComponent("vectors.bin")),
            archived: archived,
            embeddingModelIdentifier: file.embeddingModel
        )
    }

    static func write(_ snapshot: StoreSnapshot, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic writes: a crash mid-save leaves the previous file whole.
        if let data = try? encoder.encode(ConceptsFile(embeddingModel: snapshot.embeddingModelIdentifier,
                                                       concepts: snapshot.concepts)) {
            try? data.write(to: folder.appendingPathComponent("concepts.json"), options: .atomic)
        }
        if let data = try? encoder.encode(snapshot.archived) {
            try? data.write(to: folder.appendingPathComponent("archive.json"), options: .atomic)
        }
        try? vectorData(snapshot.vectors).write(to: folder.appendingPathComponent("vectors.bin"), options: .atomic)
    }

    private static func vectorData(_ vectors: [UUID: [Float]]) -> Data {
        var data = Data(magic)
        let dimension = UInt32(vectors.first?.value.count ?? 0)
        withUnsafeBytes(of: dimension.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(vectors.count).littleEndian) { data.append(contentsOf: $0) }
        for (id, vector) in vectors where vector.count == Int(dimension) {
            withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
            vector.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
        }
        return data
    }

    private static func readVectors(_ file: URL) -> [UUID: [Float]] {
        guard let data = try? Data(contentsOf: file), data.count >= 12, Array(data.prefix(4)) == magic else { return [:] }
        let dimension = Int(data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let count = Int(data.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let recordSize = 16 + dimension * 4
        let (recordsSize, overflowed) = count.multipliedReportingOverflow(by: recordSize)
        guard dimension > 0, dimension < 100_000, !overflowed, data.count >= 12 + recordsSize else { return [:] }
        var vectors: [UUID: [Float]] = [:]
        vectors.reserveCapacity(count)
        data.withUnsafeBytes { bytes in
            for record in 0..<count {
                let start = 12 + record * recordSize
                let uuidBytes = bytes.loadUnaligned(fromByteOffset: start, as: uuid_t.self)
                var vector = [Float](repeating: 0, count: dimension)
                for position in 0..<dimension {
                    vector[position] = bytes.loadUnaligned(fromByteOffset: start + 16 + position * 4, as: Float.self)
                }
                vectors[UUID(uuid: uuidBytes)] = vector
            }
        }
        return vectors
    }
}
