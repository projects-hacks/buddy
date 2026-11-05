//
//  HowToMemory.swift
//  leanring-buddy
//
//  Tasks Buddy has already walked the student through, kept so the same
//  question next time is answered from memory: the same steps, said the
//  same way and pointed at the same controls, with no model asked at all.
//  Only the voice costs anything.
//
//  Recorded from a guide that reached the end of its task (GuideMode.swift).
//  Each step keeps what was said, the label of the control it pointed at,
//  and what it waited for. Labels rather than ids, because ids are new on
//  every screen and the label "Export as PDF…" is what is still there
//  tomorrow.
//
//  Found again only when it is plainly the same request: the same app, a
//  question that asks how to do something, close in meaning, and nearly
//  every word that matters in the question already among the ways this task
//  was asked or described. A near miss ("export as PNG" against a saved
//  "export as PDF") falls through to the model, which is slower but never
//  wrong in that way. The ways of asking are written once, when the how-to
//  is saved, by one small Haiku call; finding it costs nothing. Thresholds
//  are measured by scripts/howto/.
//
//  When a replay meets a screen that no longer matches (the app changed,
//  a step's control is not there), the model takes over from that step and
//  the how-to is re-recorded from the new walkthrough.
//
//  Kept in ~/Library/Application Support/Buddy/Memory/howtos.json.
//

import AppKit
import Foundation

struct HowToStep: Codable, Equatable {
    /// What was said, sentence by sentence.
    var sentences: [String]
    /// The text of the control the step pointed at, if it pointed.
    var targetLabel: String?
    /// The mark used on it ("point", "ring") and the words on its pill.
    var markKind: String?
    var markPill: String?
    /// What the student was asked to do; nil on the last step.
    var instruction: String?
    var doneWhen: String?
}

struct HowTo: Codable, Identifiable, Equatable {
    var id = UUID()
    var appBundleIdentifier: String
    var appName: String
    /// "export the document as a PDF".
    var title: String
    /// The questions that asked for it, the first and every later match.
    var questions: [String]
    /// Other ways a person would ask for it, written when it was saved.
    var cues: [String] = []
    var steps: [HowToStep]
    var created = Date()
    var lastReplayed: Date?
    var timesReplayed = 0
    var replayFailures = 0
}

/// The deciding numbers, measured in scripts/howto/ on held-out phrasings.
enum HowToMatching {
    /// Cosine similarity of meaning, best over the how-to's phrasings. The
    /// on-device model rates all short how-to questions alike (0.89 to 0.99
    /// in the test), so this is only a floor; the words decide.
    static var minimumSimilarity = 0.88
    /// For the best-matching phrasing: the share of the question's content
    /// words it has, and the share of its own content words in the question.
    /// Both ways, so "open a new window" does not find "open a private
    /// window" and "turn off dark mode" does not find "turn on dark mode".
    static var minimumCoverage = 1.0
    static var minimumPhrasingCoverage = 0.5

    /// Questions that ask to get something done.
    static func isTaskRequest(_ question: String) -> Bool {
        let lowered = " " + question.lowercased() + " "
        let openings = [
            " how do i ", " how can i ", " how would i ", " how should i ", " how to ", " how do you ",
            " where is ", " where do i ", " where can i ", " where's ", " show me how ", " walk me through ",
            " help me ", " i want to ", " i need to ", " i'd like to ", " can you help me ", " teach me how to ",
            " how do we ", " what do i click ", " which button ", " take me through ", " i need ", " i want "
        ]
        if openings.contains(where: { lowered.contains($0) }) { return true }
        // Or a command to the app, "make my mac dark", "add another slide".
        let firstWord = question.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return actionVerbs.contains(firstWord) || lowered.hasPrefix(" can i ")
    }

    private static let actionVerbs: Set<String> = [
        "make", "turn", "add", "open", "create", "change", "switch", "export", "save", "rotate", "lock", "insert",
        "put", "set", "enable", "disable", "convert", "start", "remove", "delete", "rename", "close", "print",
        "share", "move", "copy", "duplicate", "hide", "show", "install", "connect", "send", "find", "unlock",
        "new", "protect", "secure", "get", "lock"
    ]

    /// Words that carry no task: question openings, filler, the app itself.
    private static let fillerWords: Set<String> = [
        "how", "do", "does", "i", "can", "could", "would", "should", "you", "me", "my", "mine", "the", "a",
        "an", "to", "in", "on", "of", "this", "that", "these", "those", "it", "its", "is", "are", "be",
        "with", "for", "and", "or", "please", "buddy", "app", "here", "there", "what", "where", "which",
        "show", "help", "want", "need", "like", "walk", "through", "way", "now", "just", "again", "some",
        "thing", "something", "into", "from", "at", "as", "by", "we", "our", "us", "so", "then", "id",
        "where's", "whats", "what's", "im", "i'm", "let", "lets", "go", "get", "use", "using", "one",
        "teach", "take", "click", "button", "option", "setting", "settings", "real", "quick", "quickly",
        "currently", "current", "have", "has", "had", "tell", "more"
    ]

    /// Two-word ways of saying on and off, read as one word before anything
    /// else, so the direction of a request is never lost as filler.
    private static let phraseSynonyms: [(String, String)] = [
        ("turn on", "enable"), ("switch on", "enable"), ("turn off", "disable"), ("switch off", "disable"),
        ("put in", "add"), ("password protect", "lock"), ("go incognito", "private")
    ]

    /// Everyday words for the same request, folded together. Only words
    /// that mean the same thing in any app: creating, documents, privacy.
    private static let wordSynonyms: [String: String] = [
        "create": "add", "make": "add", "insert": "add", "new": "add", "another": "add",
        "doc": "document", "docs": "document", "txt": "text",
        "incognito": "private", "privately": "private",
        "activate": "enable", "deactivate": "disable",
        "protect": "lock", "secure": "lock"
    ]

    /// Lowercased content words, lightly stemmed so "exporting" meets "export".
    static func contentWords(_ text: String) -> Set<String> {
        var lowered = " " + text.lowercased() + " "
        for (phrase, word) in phraseSynonyms { lowered = lowered.replacingOccurrences(of: " \(phrase) ", with: " \(word) ") }
        // "turn dark mode on", with the direction at the end.
        for (direction, word) in [("on", "enable"), ("off", "disable")] {
            lowered = lowered.replacingOccurrences(
                of: #"\b(turn|switch)((?: [a-z]+){1,3}) "# + direction + #"\b"#,
                with: word + "$2", options: .regularExpression)
        }
        var words = Set<String>()
        for raw in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }) {
            let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard word.count > 1, !fillerWords.contains(word) else { continue }
            let folded = wordSynonyms[word] ?? word
            words.insert(stem(folded))
        }
        return words
    }

    /// "browsing", "browse" and "browsed" all become "brows".
    static func stem(_ word: String) -> String {
        var stemmed = word
        for suffix in ["ing", "ed", "es", "s"] where stemmed.count > suffix.count + 3 && stemmed.hasSuffix(suffix) {
            stemmed = String(stemmed.dropLast(suffix.count))
            break
        }
        if stemmed.count > 4, stemmed.hasSuffix("e") { stemmed.removeLast() }
        return stemmed
    }

    /// Every phrasing whose meaning is compared with the question's.
    static func phrasings(of howTo: HowTo) -> [String] {
        [howTo.title] + howTo.questions + howTo.cues
    }

    static func cosine(_ first: [Float], _ second: [Float]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        var sum: Float = 0
        for index in first.indices { sum += first[index] * second[index] }
        return Double(sum)
    }

    struct Score {
        let similarity: Double
        let coverage: Double
        let phrasingCoverage: Double
    }

    /// How close a question is to a how-to, against its best phrasing. The
    /// steps' own words are left out: "open the File menu" is the route, not
    /// the task, and counting it let "how do I open a PDF" find "save as PDF".
    static func score(question: String, questionVector: [Float]?, howTo: HowTo, phrasingVectors: [[Float]]) -> Score {
        let questionWords = contentWords(question)
        var bestCoverage = 0.0, bestPhrasingCoverage = 0.0
        if !questionWords.isEmpty {
            for phrasing in phrasings(of: howTo) {
                let phrasingWords = contentWords(phrasing)
                guard !phrasingWords.isEmpty else { continue }
                let shared = Double(questionWords.intersection(phrasingWords).count)
                let coverage = shared / Double(questionWords.count)
                let phrasingCoverage = shared / Double(phrasingWords.count)
                if coverage + phrasingCoverage > bestCoverage + bestPhrasingCoverage {
                    (bestCoverage, bestPhrasingCoverage) = (coverage, phrasingCoverage)
                }
            }
        }
        let similarity = questionVector.map { vector in
            phrasingVectors.map { cosine(vector, $0) }.max() ?? 0
        } ?? 0
        return Score(similarity: similarity, coverage: bestCoverage, phrasingCoverage: bestPhrasingCoverage)
    }

    static func accepts(_ score: Score) -> Bool {
        score.similarity >= minimumSimilarity && score.coverage >= minimumCoverage
            && score.phrasingCoverage >= minimumPhrasingCoverage
    }

    // MARK: Controls by label

    private static func normalLabel(_ text: String) -> String {
        var label = text.lowercased().replacingOccurrences(of: "\u{2026}", with: "")
        while let last = label.last, last == "." || last == ":" { label.removeLast() }
        return label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The listed control with this label: the same text, or failing that
    /// the shortest listed text holding it as whole words. Matches the
    /// drawing engine's own rule, so what is found here is what gets drawn.
    static func targetIdentifier(forLabel label: String, in labels: [String: String]) -> String? {
        let wanted = normalLabel(label)
        guard !wanted.isEmpty else { return nil }
        var containing: (id: String, length: Int)?
        for (identifier, listedText) in labels {
            let listed = normalLabel(listedText)
            if listed == wanted { return identifier }
            let asWords = " \(listed) ".contains(" \(wanted) ") || listed.hasPrefix("\(wanted) ")
            if asWords, listed.count <= wanted.count + 24, containing.map({ listed.count < $0.length }) ?? true {
                containing = (identifier, listed.count)
            }
        }
        return containing?.id
    }
}

@MainActor
final class HowToMemory {
    private(set) var howTos: [HowTo] = []
    private let file = AppIdentity.supportFolder.appendingPathComponent("Memory/howtos.json")
    /// Meaning vectors of each how-to's phrasings, worked out on first use.
    private var phrasingVectors: [UUID: [[Float]]] = [:]

    /// Writes the ways of asking for a new how-to. Set by the owner, since
    /// the Haiku call lives with the other memory calls.
    var writeCues: (_ howTo: HowTo) async -> (title: String, phrasings: [String])? = { _ in nil }

    init() {
        if let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            howTos = (try? decoder.decode([HowTo].self, from: data)) ?? []
        }
    }

    var count: Int { howTos.count }

    // MARK: Finding

    /// The saved how-to this question asks for, or nil. No network, no model.
    func match(question: String, appBundleIdentifier: String?, vectorFor: (String) -> [Float]?) -> HowTo? {
        guard let appBundleIdentifier, HowToMatching.isTaskRequest(question) else { return nil }
        let candidates = howTos.filter { $0.appBundleIdentifier == appBundleIdentifier }
        guard !candidates.isEmpty else { return nil }
        let questionVector = vectorFor(question)
        var best: (howTo: HowTo, score: HowToMatching.Score)?
        for howTo in candidates {
            let vectors = phrasingVectors[howTo.id] ?? HowToMatching.phrasings(of: howTo).compactMap(vectorFor)
            phrasingVectors[howTo.id] = vectors
            let score = HowToMatching.score(question: question, questionVector: questionVector,
                                            howTo: howTo, phrasingVectors: vectors)
            TutorDebugLog.write(String(format: "📒 how-to \"%@\": meaning %.3f, words %.2f both ways %.2f",
                                       howTo.title, score.similarity, score.coverage, score.phrasingCoverage))
            if HowToMatching.accepts(score),
               best.map({ score.coverage + score.phrasingCoverage > $0.score.coverage + $0.score.phrasingCoverage }) ?? true {
                best = (howTo, score)
            }
        }
        return best?.howTo
    }

    func noteReplayed(_ howTo: HowTo, askedAs question: String) {
        guard let index = howTos.firstIndex(where: { $0.id == howTo.id }) else { return }
        howTos[index].timesReplayed += 1
        howTos[index].lastReplayed = Date()
        // A new way of asking that found it is kept, so it is found the
        // same way again however the cues were worded.
        if !howTos[index].questions.contains(where: { $0.lowercased() == question.lowercased() }) {
            howTos[index].questions.append(question)
            phrasingVectors[howTo.id] = nil
        }
        save()
    }

    func noteReplayFailed(_ howTo: HowTo) {
        guard let index = howTos.firstIndex(where: { $0.id == howTo.id }) else { return }
        howTos[index].replayFailures += 1
        save()
    }

    func forgetAll() {
        howTos = []
        phrasingVectors = [:]
        recording = nil
        save()
    }

    // MARK: Recording

    private struct Recording {
        var question: String
        var application: NSRunningApplication
        var steps: [HowToStep]
        /// Set when a replay was taken over by the model: the finished
        /// walkthrough replaces the how-to that no longer matched.
        var replacing: UUID?
    }
    private var recording: Recording?

    /// The first step of a guide, or the takeover of a replay at `steps.count`.
    func startRecording(question: String, application: NSRunningApplication?, seededWith steps: [HowToStep] = [],
                        replacing: UUID? = nil) {
        guard let application else { recording = nil; return }
        recording = Recording(question: question, application: application, steps: steps, replacing: replacing)
    }

    /// A step the model gave. A repeat of the last step's instruction is a
    /// correction ("not quite, go back"), which is not part of the task.
    func recordStep(program: String, labels: [String: String], waitingFor step: GuideStep?) {
        guard recording != nil else { return }
        let sentences = Self.sayArguments(in: program)
        guard !sentences.isEmpty else { return }
        if let step, let last = recording?.steps.last,
           last.instruction?.lowercased() == step.instruction.lowercased() { return }
        let (kind, target, pill) = Self.firstMark(in: program)
        let label = target.map { labels[$0] ?? $0 }
        // Back at a control an earlier step pointed at: everything since was
        // a detour (a wrong turn, a misread dialog) and is not part of the
        // task, so the saved steps never loop.
        if let label, let earlier = recording?.steps.firstIndex(where: {
            $0.targetLabel?.lowercased() == label.lowercased()
        }) {
            recording?.steps.removeSubrange(earlier...)
        }
        recording?.steps.append(HowToStep(sentences: sentences, targetLabel: label, markKind: kind, markPill: pill,
                                          instruction: step?.instruction, doneWhen: step?.doneWhen))
    }

    func abandonRecording() { recording = nil }

    /// The task is done: saved if every step but the last pointed at
    /// something, since a step with nothing to find cannot be replayed.
    func finishRecording(program: String, labels: [String: String], lessonTitle: String?) {
        recordStep(program: program, labels: labels, waitingFor: nil)
        guard let finished = recording else { return }
        recording = nil
        let steps = finished.steps
        guard steps.count >= 2, steps.dropLast().allSatisfy({ $0.targetLabel != nil }),
              let bundleIdentifier = finished.application.bundleIdentifier else {
            TutorDebugLog.write("📒 how-to not kept: \(steps.count) steps, some without a control")
            return
        }
        var howTo = HowTo(appBundleIdentifier: bundleIdentifier,
                          appName: finished.application.localizedName ?? bundleIdentifier,
                          title: lessonTitle ?? finished.question, questions: [finished.question], steps: steps)
        if let replacing = finished.replacing, let old = howTos.first(where: { $0.id == replacing }) {
            howTo.id = old.id
            howTo.questions = old.questions
            howTo.cues = old.cues
            howTo.title = old.title
            howTos.removeAll { $0.id == replacing }
        }
        howTos.append(howTo)
        phrasingVectors[howTo.id] = nil
        save()
        TutorDebugLog.write("📒 how-to kept: \"\(howTo.title)\" in \(howTo.appName), \(steps.count) steps")
        guard howTo.cues.isEmpty else { return }
        let saved = howTo
        Task { [weak self] in
            guard let self, let written = await self.writeCues(saved),
                  let index = self.howTos.firstIndex(where: { $0.id == saved.id }) else { return }
            if !written.title.isEmpty { self.howTos[index].title = written.title }
            self.howTos[index].cues = written.phrasings
            self.phrasingVectors[saved.id] = nil
            self.save()
            TutorDebugLog.write("📒 how-to \"\(self.howTos[index].title)\": \(written.phrasings.count) ways of asking written")
        }
    }

    // MARK: Replaying

    /// One step as a drawing program for the engine, the same as the model's.
    static func program(for step: HowToStep, targetIdentifier: String?) -> String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var lines = ["step(1);"]
        for (index, sentence) in step.sentences.enumerated() {
            lines.append("say(\(quoted(sentence)));")
            if index == 0, let targetIdentifier {
                let kind = ["point", "ring", "frame", "underline", "highlight"].contains(step.markKind ?? "")
                    ? step.markKind! : "point"
                lines.append(kind == "point" || kind == "ring"
                             ? "\(kind)(\(quoted(targetIdentifier)), \(quoted(step.markPill ?? "click")));"
                             : "\(kind)(\(quoted(targetIdentifier)));")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// For a model taking over a replay: what was done before, so it carries
    /// on from the right place instead of starting again.
    static func takeoverNote(_ howTo: HowTo, stepsDone: Int) -> String {
        let done = howTo.steps.prefix(stepsDone).compactMap(\.instruction).joined(separator: "; ")
        return "you walked them through this task before and they have done: \(done). the next step you saved no longer matches the screen, so look at it fresh and give the next step."
    }

    // MARK: Reading programs

    static func sayArguments(in program: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"say\(\s*"((?:[^"\\]|\\.)*)"\s*\)"#) else { return [] }
        let range = NSRange(program.startIndex..., in: program)
        return expression.matches(in: program, range: range).compactMap { match in
            Range(match.range(at: 1), in: program).map {
                String(program[$0]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
        }
    }

    /// The first mark on a real control: its kind, its target, its pill.
    static func firstMark(in program: String) -> (kind: String?, target: String?, pill: String?) {
        let pattern = #"\b(point|ring|frame|underline|highlight)\(\s*"((?:[^"\\]|\\.)*)"\s*(?:,\s*"((?:[^"\\]|\\.)*)")?"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: program, range: NSRange(program.startIndex..., in: program)) else {
            return (nil, nil, nil)
        }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: program).map { String(program[$0]) }
        }
        return (group(1), group(2), group(3))
    }

    // MARK: Disk

    private func save() {
        let snapshot = howTos
        let file = self.file
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
