// Checks that a lesson is filed under a known idea only when it really is
// that idea (FilingMatchCheck in LearningMemory.swift), since filing under
// one replaces its explanation.
//
// A live store had an off-by-one lesson filed under "division by zero": the
// filing call's same_as named that idea's id, and the division record ended
// up with an off-by-one explanation under its old name. live_store_fixture.json
// holds that store.
//
//   grade    offline. The live replay: the reply that did the damage, run
//            through the real LearningMemory on the store as it was, must
//            leave "division by zero" alone. Then every recorded filing reply
//            in filing_replies.json is graded: a same_as kept must be one the
//            lesson allows, and the ones refused are counted. Then how close
//            the sentence model puts different ideas and the same idea, which
//            is why the check does not rest on meaning.
//   record   calls Claude Haiku with the LessonConceptPrompt.txt that ships, on
//            the lessons in filing_cases.json and relation_fixture.json, and
//            writes filing_replies.json. Key on stdin, never printed.
//
// build and run (from the repository root):
//   mkdir -p /tmp/filing && cp scripts/learning_memory/filing_check.swift /tmp/filing/main.swift
//   xcrun swiftc -O -o /tmp/filing/check leanring-buddy/Memory/ConceptIndex.swift leanring-buddy/Memory/LearningMemory.swift \
//     leanring-buddy/Memory/Map/KnowledgeMapRelations.swift /tmp/filing/main.swift
//   /tmp/filing/check grade scripts /tmp/filing/store
//   security find-generic-password -a api-key -s com.maverickrajeev.clicky-local.anthropic -w \
//     | /tmp/filing/check record scripts

import CryptoKit
import Foundation
import NaturalLanguage

enum TutorDebugLog { static func write(_ line: String) { print("   log:", line) } }
// LearningMemory's default folder names it; every store here is a scratch one.
enum AppIdentity { static let dataName = "Buddy-filing-check" }

let mode = CommandLine.arguments[1]
let scriptsFolder = URL(fileURLWithPath: CommandLine.arguments[2])
let memoryFolder = scriptsFolder.appendingPathComponent("learning_memory")
let repliesFile = memoryFolder.appendingPathComponent("filing_replies.json")

func readJSON(_ url: URL) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()
let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

func concepts(from entries: Any?) -> [RememberedConcept] {
    let data = try! JSONSerialization.data(withJSONObject: entries as! [[String: Any]])
    return try! decoder.decode([RememberedConcept].self, from: data)
}

/// A fixture idea that has only a key, a name and a summary, with the id
/// relation_check.py gives it: the first eight hex characters are the key's
/// SHA-256, so both scripts show Haiku the same short ids.
func fixtureConcept(key: String, name: String, aliases: [String], summary: String) -> RememberedConcept {
    let digest = Array(SHA256.hash(data: Data(key.utf8)))
    let id = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                         digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    return RememberedConcept(id: id, name: name, aliases: aliases, cues: nil, summary: summary, lastAngle: nil,
                             firstExplainedAt: Date(), lastExplainedAt: Date(), timesExplained: 1, timesLost: 0,
                             lastLostAt: nil, stabilityDays: 2, lessonTitles: [])
}

func shortID(_ concept: RememberedConcept) -> String { String(concept.id.uuidString.prefix(8)).lowercased() }

// MARK: - The lessons and the stores they are filed against

struct GradedLesson {
    let label: String
    let store: [RememberedConcept]
    let question: String
    let title: String
    let explanation: String
    /// Names (or fixture keys) of the known ideas this lesson may be filed under.
    let acceptable: Set<String>
    /// Names of known ideas it must never be filed under.
    let never: Set<String>
}

let liveFixture = readJSON(memoryFolder.appendingPathComponent("live_store_fixture.json"))
let liveBefore = concepts(from: liveFixture["before"])
let liveAfter = concepts(from: liveFixture["after"])
let badLesson = liveFixture["bad_lesson"] as! [String: String]
// The later live lessons are graded against the store as it would be without
// the damage. Haiku sees only names, which the damage did not change, but the
// damaged record also took the off-by-one aliases, which would let a misread
// id onto it pass the name check; that is counted on its own below.
let liveDivisionBefore = liveBefore.first { $0.name == "division by zero" }!
let liveAfterUndamaged = liveAfter.map { $0.id == liveDivisionBefore.id ? liveDivisionBefore : $0 }

func gradedLessons() -> [GradedLesson] {
    var lessons: [GradedLesson] = []
    let relationFixture = readJSON(scriptsFolder.appendingPathComponent("knowledge_map/relation_fixture.json"))
    let relationStore = (relationFixture["known"] as! [[String: String]]).map {
        fixtureConcept(key: $0["key"]!, name: $0["name"]!, aliases: [], summary: $0["summary"]!)
    }
    let relationNamesByKey = Dictionary(uniqueKeysWithValues: (relationFixture["known"] as! [[String: String]]).map { ($0["key"]!, $0["name"]!) })
    let cases = readJSON(memoryFolder.appendingPathComponent("filing_cases.json"))
    let alsoAcceptableByTitle = cases["relation_acceptable"] as? [String: Any] ?? [:]
    for lesson in relationFixture["lessons"] as! [[String: Any]] {
        // A lesson's new idea may be filed under its same_as, and under no
        // other: it is linked to the rest, never one of them.
        let title = lesson["title"] as! String
        let sameAs = (lesson["same_as"] as? String).flatMap { relationNamesByKey[$0] }
        let alsoAcceptable = alsoAcceptableByTitle[title] as? [String] ?? []
        lessons.append(GradedLesson(
            label: "relation: \(title)", store: relationStore,
            question: lesson["question"] as! String, title: title,
            explanation: lesson["explanation"] as! String,
            acceptable: Set((sameAs.map { [$0] } ?? []) + alsoAcceptable), never: []))
    }

    let flowEntries = cases["flow_store"] as! [[String: Any]]
    let flowStore = flowEntries.map {
        fixtureConcept(key: $0["key"] as! String, name: $0["name"] as! String,
                       aliases: $0["aliases"] as! [String], summary: $0["summary"] as! String)
    }
    let flowNamesByKey = Dictionary(uniqueKeysWithValues: flowEntries.map { ($0["key"] as! String, $0["name"] as! String) })
    for lesson in cases["lessons"] as! [[String: Any]] {
        let storeName = lesson["store"] as! String
        let store = storeName == "flow" ? flowStore : storeName == "live_before" ? liveBefore : liveAfterUndamaged
        let explanation = lesson["explanation"] as! String
        let acceptable = (lesson["acceptable"] as! [String]).map { flowNamesByKey[$0] ?? $0 }
        lessons.append(GradedLesson(
            label: "\(storeName): \(lesson["title"] as! String)", store: store,
            question: lesson["question"] as! String, title: lesson["title"] as! String,
            explanation: explanation == "from_fixture" ? badLesson["spokenAnswer"]! : explanation,
            acceptable: Set(acceptable), never: Set(lesson["never"] as? [String] ?? [])))
    }
    return lessons
}

/// The message LearningMemoryCalls.extractLessonConcepts sends.
func filingMessage(_ lesson: GradedLesson) -> String {
    let knownLines = lesson.store.map { "\(shortID($0)): \($0.name)" }.joined(separator: "\n")
    return "KNOWN:\n\(knownLines)\n\nTHE STUDENT ASKED: \(lesson.question)\nLESSON TITLE: \(lesson.title)\nTHE EXPLANATION: \(lesson.explanation.prefix(1_800))"
}

// MARK: - record

if mode == "record" {
    let apiKey = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let prompt = try! String(contentsOf: scriptsFolder.deletingLastPathComponent()
        .appendingPathComponent("leanring-buddy/Memory/LessonConceptPrompt.txt"), encoding: .utf8)
    let runsPerLesson = 2
    var recorded: [[String: Any]] = []
    var inputTokens = 0
    var outputTokens = 0
    for lesson in gradedLessons() {
        for _ in 0..<runsPerLesson {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try! JSONSerialization.data(withJSONObject: [
                "model": "claude-haiku-5-5", "max_tokens": 1_600, "system": prompt,
                "thinking": ["type": "disabled"], "messages": [["role": "user", "content": filingMessage(lesson)]]])
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]] else {
                print("no reply for", lesson.label)
                continue
            }
            let usage = json["usage"] as? [String: Any] ?? [:]
            inputTokens += usage["input_tokens"] as? Int ?? 0
            outputTokens += usage["output_tokens"] as? Int ?? 0
            recorded.append(["lesson": lesson.label, "reply": content.compactMap { $0["text"] as? String }.joined()])
        }
    }
    try! JSONSerialization.data(withJSONObject: ["replies": recorded], options: [.prettyPrinted, .sortedKeys]).write(to: repliesFile)
    // Haiku at the price SpendingMeter records, and at the older list price
    // the other scripts here quote, as an upper bound.
    print("recorded \(recorded.count) replies; \(inputTokens) input and \(outputTokens) output tokens, "
          + String(format: "$%.4f at $0.10/$0.50 per million, $%.4f at $1/$5", (Double(inputTokens) * 0.1 + Double(outputTokens) * 0.5) / 1e6,
                   (Double(inputTokens) + Double(outputTokens) * 5) / 1e6))
    exit(0)
}

// MARK: - grade

let sentenceModel = NLContextualEmbedding(language: .english)!
try! sentenceModel.load()
/// The same pooling QuestionSorter.sentenceVector gives learning memory.
func embed(_ text: String) -> [Float]? {
    let sentence = text.lowercased()
    guard let result = try? sentenceModel.embeddingResult(for: sentence, language: .english) else { return nil }
    var summed = [Double](repeating: 0, count: sentenceModel.dimension)
    var count = 0
    result.enumerateTokenVectors(in: sentence.startIndex..<sentence.endIndex) { vector, _ in
        for index in 0..<min(vector.count, summed.count) { summed[index] += vector[index] }
        count += 1
        return true
    }
    let length = sqrt(summed.reduce(0) { $0 + $1 * $1 })
    guard count > 0, length > 0 else { return nil }
    return summed.map { Float($0 / length) }
}
func similarity(_ first: String, _ second: String) -> Double {
    guard let firstVector = embed(first), let secondVector = embed(second) else { return 0 }
    return Double(zip(firstVector, secondVector).reduce(Float(0)) { $0 + $1.0 * $1.1 })
}

var failures = 0
func check(_ condition: Bool, _ description: String) {
    print(condition ? "PASS" : "FAIL", description)
    if !condition { failures += 1 }
}

let storeFolder = URL(fileURLWithPath: CommandLine.arguments[3])

/// A scratch store holding these ideas, in the app's own file format.
func writeStore(_ storeConcepts: [RememberedConcept]) {
    try? FileManager.default.removeItem(at: storeFolder)
    try! FileManager.default.createDirectory(at: storeFolder, withIntermediateDirectories: true)
    struct ConceptsFile: Encodable { var version = 1; let embeddingModel: String?; let concepts: [RememberedConcept] }
    try! encoder.encode(ConceptsFile(embeddingModel: nil, concepts: storeConcepts))
        .write(to: storeFolder.appendingPathComponent("concepts.json"))
}

let badExtractionEntry = liveFixture["bad_extraction"] as! [String: Any]
let lessonDate = ISO8601DateFormatter().date(from: badLesson["date"]!)!
let badLessonToRemember = LessonToRemember(
    question: badLesson["question"]!, lessonTitle: badLesson["lessonTitle"]!, spokenAnswer: badLesson["spokenAnswer"]!,
    questionKind: badLesson["questionKind"]!, answeredBy: badLesson["answeredBy"]!, date: lessonDate)

/// Files the lesson through the real LearningMemory, on the store as it was
/// before the damage, with the filing call's reply replaced by `extraction`.
@MainActor func fileIntoLiveStore(_ extraction: ExtractedConcept) async -> [RememberedConcept] {
    writeStore(liveBefore)
    let memory = LearningMemory(folder: storeFolder)
    memory.embed = embed
    memory.extract = { _, _ in [extraction] }
    await memory.load()
    await memory.remember(badLessonToRemember)
    await memory.flushWrites()
    return memory.index.concepts
}

let result: Int = await Task { @MainActor in
    let divisionBefore = liveBefore.first { $0.name == "division by zero" }!
    let offByOneBefore = liveBefore.first { $0.name == "off by one error" }!

    print("1. the reply that overwrote division by zero, replayed on the store as it was")
    let damagingExtraction = ExtractedConcept(
        name: badExtractionEntry["name"] as! String,
        sameAsID: UUID(uuidString: badExtractionEntry["same_as"] as! String),
        aliases: badExtractionEntry["aliases"] as! [String], cues: badExtractionEntry["cues"] as! [String],
        summary: badExtractionEntry["summary"] as! String, angle: badExtractionEntry["angle"] as? String,
        relations: [])
    let afterReplay = await fileIntoLiveStore(damagingExtraction)
    let divisionAfterReplay = afterReplay.first { $0.id == divisionBefore.id }
    let offByOneAfterReplay = afterReplay.first { $0.id == offByOneBefore.id }
    check(divisionAfterReplay == divisionBefore,
          "division by zero is untouched (summary: \(divisionAfterReplay?.summary.prefix(60) ?? "gone")...)")
    check(offByOneAfterReplay?.summary == damagingExtraction.summary && offByOneAfterReplay?.lessonTitles.last == badLesson["lessonTitle"],
          "the lesson is filed under off by one error, the idea its name names")
    check(afterReplay.count == liveBefore.count, "no second idea of the same name (\(afterReplay.count) ideas)")

    print("\n2. the same misread id, with a name no known idea has")
    let renamedExtraction = ExtractedConcept(name: "binary search upper bound", sameAsID: damagingExtraction.sameAsID,
                                         aliases: [], cues: damagingExtraction.cues, summary: damagingExtraction.summary,
                                         angle: damagingExtraction.angle, relations: [])
    let afterRenamed = await fileIntoLiveStore(renamedExtraction)
    check(afterRenamed.first { $0.id == divisionBefore.id } == divisionBefore, "division by zero is untouched")
    check(afterRenamed.contains { $0.name == "binary search upper bound" && $0.summary == damagingExtraction.summary },
          "the lesson becomes a new idea under its own name, its name and summary agreeing")

    print("\n3. a real match still updates the known idea")
    let rightExtraction = ExtractedConcept(name: "off-by-one error", sameAsID: offByOneBefore.id,
                                           aliases: ["fencepost error"], cues: damagingExtraction.cues,
                                           summary: damagingExtraction.summary, angle: damagingExtraction.angle, relations: [])
    let afterRight = await fileIntoLiveStore(rightExtraction)
    check(afterRight.first { $0.id == offByOneBefore.id }?.summary == damagingExtraction.summary && afterRight.count == liveBefore.count,
          "filed under off by one error, the latest explanation replacing the old")

    print("\n4. recorded filing replies (filing_replies.json), graded")
    let recorded = (readJSON(repliesFile)["replies"] as! [[String: String]])
    let lessonsByLabel = Dictionary(uniqueKeysWithValues: gradedLessons().map { ($0.label, $0) })
    var keptRight = 0, refusedRight = 0, refusedWrong = 0, keptWrong = 0, noMatch = 0
    var sameIdeaSimilarities: [Double] = []
    var misreadTotal = 0
    var misreadKept: [String] = []
    var misreadOntoDamagedTotal = 0
    var misreadOntoDamagedKept = 0
    for entry in recorded {
        guard let lesson = lessonsByLabel[entry["lesson"]!], let reply = entry["reply"],
              let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let replyConcepts = json["concepts"] as? [[String: Any]] else {
            print("   unreadable reply for", entry["lesson"]!)
            continue
        }
        for replyConcept in replyConcepts {
            let name = (replyConcept["name"] as? String ?? "").lowercased()
            let aliases = replyConcept["aliases"] as? [String] ?? []
            let summary = replyConcept["summary"] as? String ?? ""
            guard let sameAs = replyConcept["same_as"] as? String,
                  let known = lesson.store.first(where: { shortID($0) == sameAs.lowercased() }) else {
                noMatch += 1
                continue
            }
            let isAllowed = lesson.acceptable.contains(known.name) && !lesson.never.contains(known.name)
            let isKept = FilingMatchCheck.namesAgree(extractedName: name, extractedAliases: aliases, known: known)
            let meaning = similarity("\(name): \(summary)", LearningMemory.embeddingText(for: known))
            if isAllowed { sameIdeaSimilarities.append(meaning) }
            switch (isAllowed, isKept) {
            case (true, true): keptRight += 1
            case (true, false): refusedRight += 1
            case (false, false): refusedWrong += 1
            case (false, true): keptWrong += 1
            }
            print(String(format: "   %@ %@ \"%@\" as \"%@\" (meaning %.3f), in %@", isKept ? "kept   " : "refused",
                         isAllowed ? "right" : "WRONG", name, known.name, meaning, lesson.label))
            // The failure seen live, made on purpose: the same idea with its
            // id misread as each other known idea Haiku was shown.
            for otherKnown in lesson.store where otherKnown.id != known.id && !lesson.acceptable.contains(otherKnown.name) {
                misreadTotal += 1
                if FilingMatchCheck.namesAgree(extractedName: name, extractedAliases: aliases, known: otherKnown) {
                    misreadKept.append("\"\(name)\" as \"\(otherKnown.name)\"")
                }
            }
            if lesson.label.hasPrefix("live_after"), let damagedDivision = liveAfter.first(where: { $0.id == liveDivisionBefore.id }) {
                misreadOntoDamagedTotal += 1
                if FilingMatchCheck.namesAgree(extractedName: name, extractedAliases: aliases, known: damagedDivision) {
                    misreadOntoDamagedKept += 1
                }
            }
        }
    }
    print("   the same ideas with their id misread as every other idea in their store: \(misreadKept.count) of \(misreadTotal) kept"
          + (misreadKept.isEmpty ? "" : ": " + misreadKept.joined(separator: ", ")))
    print("   misread as the damaged division by zero as found, which took the off-by-one aliases: "
          + "\(misreadOntoDamagedKept) of \(misreadOntoDamagedTotal) kept")
    check(misreadKept.isEmpty, "a misread id onto another idea is refused")
    print("   same_as kept and right \(keptRight), refused though right \(refusedRight) (filed as a new idea instead), "
          + "refused and wrong \(refusedWrong), kept though wrong \(keptWrong); \(noMatch) ideas named no known one")
    check(keptWrong == 0, "no lesson is filed under an idea it is not")
    check(refusedRight == 0, "every right match is kept")

    print("\n5. how close the sentence model puts ideas, name and summary against name and summary")
    @MainActor func pairSimilarities(_ storeConcepts: [RememberedConcept]) -> [Double] {
        let vectors = storeConcepts.map { embed(LearningMemory.embeddingText(for: $0))! }
        var values: [Double] = []
        for first in vectors.indices { for second in vectors.indices where second > first {
            values.append(Double(zip(vectors[first], vectors[second]).reduce(Float(0)) { $0 + $1.0 * $1.1 }))
        } }
        return values.sorted()
    }
    struct GradedConcepts: Decodable { struct Entry: Decodable { let name: String; let summary: String }; let concepts: [Entry] }
    let gradedFifty = try! JSONDecoder().decode(GradedConcepts.self, from: Data(contentsOf: memoryFolder.appendingPathComponent("concepts.json")))
        .concepts.map { fixtureConcept(key: $0.name, name: $0.name, aliases: [], summary: $0.summary) }
    let liveWithoutDamage = liveAfter.filter { $0.name != "division by zero" }
    for (label, values) in [("50 graded ideas, different pairs", pairSimilarities(gradedFifty)),
                            ("live store, different pairs", pairSimilarities(liveWithoutDamage)),
                            ("recorded right same_as pairs", sameIdeaSimilarities.sorted())] where !values.isEmpty {
        print(String(format: "   %@: %d, from %.3f to %.3f, median %.3f", label, values.count, values.first!, values.last!,
                     values[values.count / 2]))
    }
    let damagingPair = similarity("\(damagingExtraction.name): \(damagingExtraction.summary)", LearningMemory.embeddingText(for: divisionBefore))
    print(String(format: "   the damaging pair, off by one error against division by zero: %.3f", damagingPair))
    return failures
}.value
print(result == 0 ? "\nall checks passed" : "\n\(result) checks failed")
exit(result == 0 ? 0 : 1)
