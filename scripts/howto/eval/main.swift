// Grades how-to retrieval with the code that ships (HowToMatching in
// leanring-buddy/HowToMemory.swift) and the same on-device sentence model and
// pooling as QuestionSorter. Each task's ways of asking come from
// make_cues.py; the questions were written without seeing them.
//
// The thresholds are swept on the first half of every question list and
// reported on the second half, so the reported numbers are held out.
//
// usage (from the repository root):
//   swiftc -O -o "$TMPDIR/howto_eval" scripts/howto/eval/*.swift leanring-buddy/HowToMemory.swift \
//     leanring-buddy/GuideMode.swift leanring-buddy/AppIdentity.swift
//   "$TMPDIR/howto_eval"

import Foundation
import NaturalLanguage

struct TaskFile: Decodable {
    struct Task: Decodable {
        let app: String, app_name: String, asked: String, title: String
        let steps: [[String]], cues: [String], found: [String], not_found: [String]
        let fresh_found: [String], fresh_not_found: [String]
    }
    let tasks: [Task]
}

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/howto")
let file = try JSONDecoder().decode(TaskFile.self, from: Data(contentsOf: folder.appendingPathComponent("tasks_with_cues.json")))

guard let model = NLContextualEmbedding(language: .english) else { fatalError("no English embedding model") }
if !model.hasAvailableAssets {
    let semaphore = DispatchSemaphore(value: 0)
    model.requestAssets { _, _ in semaphore.signal() }
    semaphore.wait()
}
try model.load()

func vector(_ text: String) -> [Float]? {
    let sentence = text.lowercased()
    guard let result = try? model.embeddingResult(for: sentence, language: .english) else { return nil }
    var summed = [Double](repeating: 0, count: model.dimension)
    var count = 0
    result.enumerateTokenVectors(in: sentence.startIndex..<sentence.endIndex) { tokenVector, _ in
        for index in 0..<min(tokenVector.count, summed.count) { summed[index] += tokenVector[index] }
        count += 1
        return true
    }
    let length = sqrt(summed.reduce(0) { $0 + $1 * $1 })
    guard count > 0, length > 0 else { return nil }
    return summed.map { Float($0 / length) }
}

let howTos: [HowTo] = file.tasks.map { task in
    HowTo(appBundleIdentifier: task.app, appName: task.app_name, title: task.title, questions: [task.asked],
          cues: task.cues,
          steps: task.steps.map { HowToStep(sentences: [$0[0]], targetLabel: $0[1], instruction: $0[0]) })
}
let phrasingVectors = howTos.map { HowToMatching.phrasings(of: $0).compactMap(vector) }

/// Which set a question is in: tuning, held out, or fresh (written after the
/// first two were scored).
enum QuestionSet { case tuning, heldOut, fresh }
struct Question {
    let text: String
    let app: String
    let expected: Int?
    let group: QuestionSet
    var tuning: Bool { group == .tuning }
}
var questions: [Question] = []
for (index, task) in file.tasks.enumerated() {
    for (position, text) in task.found.enumerated() {
        questions.append(Question(text: text, app: task.app, expected: index, group: position % 2 == 0 ? .tuning : .heldOut))
    }
    for (position, text) in task.not_found.enumerated() {
        questions.append(Question(text: text, app: task.app, expected: nil, group: position % 2 == 0 ? .tuning : .heldOut))
    }
    for text in task.fresh_found { questions.append(Question(text: text, app: task.app, expected: index, group: .fresh)) }
    for text in task.fresh_not_found { questions.append(Question(text: text, app: task.app, expected: nil, group: .fresh)) }
}
let questionVectors = questions.map { vector($0.text) }

/// What the app would replay for a question, under given thresholds.
func replayed(_ questionIndex: Int, similarity: Double, coverage: Double, phrasingCoverage: Double) -> Int? {
    let question = questions[questionIndex]
    guard HowToMatching.isTaskRequest(question.text) else { return nil }
    var best: (index: Int, total: Double)?
    for (index, howTo) in howTos.enumerated() where howTo.appBundleIdentifier == question.app {
        let score = HowToMatching.score(question: question.text, questionVector: questionVectors[questionIndex],
                                        howTo: howTo, phrasingVectors: phrasingVectors[index])
        guard score.similarity >= similarity, score.coverage >= coverage,
              score.phrasingCoverage >= phrasingCoverage else { continue }
        let total = score.coverage + score.phrasingCoverage
        if best.map({ total > $0.total }) ?? true { best = (index, total) }
    }
    return best?.index
}

struct Tally { var found = 0, foundOf = 0, wrong = 0, falseReplays = 0, nearMissOf = 0 }
func tally(_ set: QuestionSet, similarity: Double, coverage: Double, phrasingCoverage: Double) -> Tally {
    var result = Tally()
    for index in questions.indices where questions[index].group == set {
        let got = replayed(index, similarity: similarity, coverage: coverage, phrasingCoverage: phrasingCoverage)
        if let expected = questions[index].expected {
            result.foundOf += 1
            if got == expected { result.found += 1 } else if got != nil { result.wrong += 1 }
        } else {
            result.nearMissOf += 1
            if got != nil { result.falseReplays += 1 }
        }
    }
    return result
}

// A wrong replay is far worse than a missed one, which only costs a normal
// answer: the sweep allows none on the tuning half, then finds the most.
// Among ties, the strictest settings win, since they are the safest.
var best: (similarity: Double, coverage: Double, phrasingCoverage: Double, tally: Tally)?
for similarity in [0.0, 0.80, 0.85, 0.88, 0.90, 0.92] {
    for coverage in [0.5, 0.6, 0.66, 0.75, 0.8, 1.0] {
        for phrasingCoverage in [0.34, 0.5, 0.6, 0.66, 0.75, 0.8, 1.0] {
            let result = tally(.tuning, similarity: similarity, coverage: coverage, phrasingCoverage: phrasingCoverage)
            guard result.falseReplays == 0, result.wrong == 0 else { continue }
            let strictness = similarity + coverage + phrasingCoverage
            if best.map({ result.found > $0.tally.found
                || (result.found == $0.tally.found && strictness > $0.similarity + $0.coverage + $0.phrasingCoverage) }) ?? true {
                best = (similarity, coverage, phrasingCoverage, result)
            }
        }
    }
}
guard let best else { print("no threshold avoids every false replay on the tuning half"); exit(1) }
let held = tally(.heldOut, similarity: best.similarity, coverage: best.coverage, phrasingCoverage: best.phrasingCoverage)
let shipped = tally(.heldOut, similarity: HowToMatching.minimumSimilarity, coverage: HowToMatching.minimumCoverage,
                    phrasingCoverage: HowToMatching.minimumPhrasingCoverage)
print(String(format: "tuned: meaning >= %.2f, question words >= %.2f, phrasing words >= %.2f",
             best.similarity, best.coverage, best.phrasingCoverage))
print("tuning half:  found \(best.tally.found)/\(best.tally.foundOf), wrong task \(best.tally.wrong), near misses replayed \(best.tally.falseReplays)/\(best.tally.nearMissOf)")
let fresh = tally(.fresh, similarity: HowToMatching.minimumSimilarity, coverage: HowToMatching.minimumCoverage,
                  phrasingCoverage: HowToMatching.minimumPhrasingCoverage)
print("fresh set, shipped values: found \(fresh.found)/\(fresh.foundOf), wrong task \(fresh.wrong), near misses replayed \(fresh.falseReplays)/\(fresh.nearMissOf)")
print("held-out half: found \(held.found)/\(held.foundOf), wrong task \(held.wrong), near misses replayed \(held.falseReplays)/\(held.nearMissOf)")
print(String(format: "shipped values (%.2f, %.2f, %.2f) on held-out: found %d/%d, wrong %d, near misses %d/%d",
             HowToMatching.minimumSimilarity, HowToMatching.minimumCoverage, HowToMatching.minimumPhrasingCoverage,
             shipped.found, shipped.foundOf, shipped.wrong, shipped.falseReplays, shipped.nearMissOf))

// What each held-out question did, so misses can be read.
for index in questions.indices where questions[index].group != .tuning {
    let question = questions[index]
    let got = replayed(index, similarity: HowToMatching.minimumSimilarity, coverage: HowToMatching.minimumCoverage,
                       phrasingCoverage: HowToMatching.minimumPhrasingCoverage)
    let ok = got == question.expected
    let gate = HowToMatching.isTaskRequest(question.text) ? "" : " [not a how-to question]"
    let scores = howTos.indices.filter { howTos[$0].appBundleIdentifier == question.app }.map { taskIndex -> String in
        let score = HowToMatching.score(question: question.text, questionVector: questionVectors[index],
                                        howTo: howTos[taskIndex], phrasingVectors: phrasingVectors[taskIndex])
        return String(format: "%@ %.2f/%.2f/%.2f", String(howTos[taskIndex].title.prefix(14)),
                      score.similarity, score.coverage, score.phrasingCoverage)
    }.joined(separator: "  ")
    print("\(ok ? "  " : "✗ ")\(question.group == .fresh ? "fresh " : "")\(question.expected == nil ? "miss" : "find") \"\(question.text)\"\(gate)  \(scores)")
}
