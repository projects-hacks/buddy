// Grades and times ConceptIndex, the part of learning memory that runs while
// the student waits.
//
// The questions in blind_questions.json were written by someone who saw only
// concepts.json, never this code or its weights. They are split into two
// halves, alternating within each difficulty. Weights are chosen on the dev
// half; the test half is scored once with the chosen weights and is the
// number to believe.
//
// Then times recall on 5,000 concepts, more than years of study produce, to
// show retrieval costs nothing the student would notice.
//
// build and run (from the repository root):
//   xcrun swiftc -O -o /tmp/recall_eval leanring-buddy/Memory/ConceptIndex.swift scripts/learning_memory/recall_eval.swift
//   /tmp/recall_eval scripts/learning_memory /tmp/shortlists.json
//   then: python3 -I scripts/learning_memory/rerank_eval.py /tmp/shortlists.json  (key on stdin, see there)

import Foundation
import NaturalLanguage

struct ConceptFile: Decodable {
    struct Entry: Decodable { let name: String; let aliases: [String]; let summary: String; let cues: [String]? }
    let concepts: [Entry]
}
struct QuestionFile: Decodable {
    struct Item: Decodable { let question: String; let context: String; let expected: [String]; let acceptable: [String] }
    let items: [Item]
}

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
// concepts_filed.json is concepts.json after filing through the shipped
// prompt (make_cues.py), which adds the aliases and cues Haiku wrote.
let conceptFile = try! JSONDecoder().decode(ConceptFile.self, from: Data(contentsOf: folder.appendingPathComponent("concepts_filed.json")))
let questionFile = try! JSONDecoder().decode(QuestionFile.self, from: Data(contentsOf: folder.appendingPathComponent("blind_questions.json")))

// The same pooling LearningMemory uses: mean of token vectors, unit length.
let model = NLContextualEmbedding(language: .english)!
if !model.hasAvailableAssets {
    let semaphore = DispatchSemaphore(value: 0)
    model.requestAssets { _, _ in semaphore.signal() }
    semaphore.wait()
}
try! model.load()
func embed(_ text: String) -> [Float]? {
    let sentence = text.lowercased()
    guard let result = try? model.embeddingResult(for: sentence, language: .english) else { return nil }
    var summed = [Double](repeating: 0, count: model.dimension)
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

let now = Date()
var baseIndex = ConceptIndex()
for entry in conceptFile.concepts {
    let concept = RememberedConcept(
        id: UUID(), name: entry.name, aliases: entry.aliases, cues: entry.cues, summary: entry.summary, lastAngle: nil,
        firstExplainedAt: now, lastExplainedAt: now, timesExplained: 1, timesLost: 0, lastLostAt: nil,
        stabilityDays: ForgettingCurve.initialStabilityDays, lessonTitles: [])
    baseIndex.upsert(concept, vector: embed("\(entry.name): \(entry.summary)"))
}

struct Prepared { let item: QuestionFile.Item; let vector: [Float]? }
let prepared = questionFile.items.map { Prepared(item: $0, vector: embed($0.question)) }

// Halves alternate within "has an answer" and "has none", so both see both.
var dev: [Prepared] = [], test: [Prepared] = []
var seenWith = 0, seenWithout = 0
for entry in prepared {
    if entry.item.expected.isEmpty {
        (seenWithout % 2 == 0 ? { dev.append(entry) } : { test.append(entry) })(); seenWithout += 1
    } else {
        (seenWith % 2 == 0 ? { dev.append(entry) } : { test.append(entry) })(); seenWith += 1
    }
}

struct Score {
    var found = 0, expectedTotal = 0
    var falsePositives = 0, retrievedTotal = 0
    var cleanNegatives = 0, negatives = 0
    var misses: [String] = [], wrong: [String] = []
    var recall: Double { expectedTotal == 0 ? 1 : Double(found) / Double(expectedTotal) }
    var precision: Double { retrievedTotal == 0 ? 1 : 1 - Double(falsePositives) / Double(retrievedTotal) }
    /// Missing a concept costs a little (the answer is generic, as today);
    /// surfacing a wrong one costs more (the tutor builds on something the
    /// student never asked about), so it is weighted double.
    var objective: Double { Double(found) - 2 * Double(falsePositives) }
}

func score(_ items: [Prepared], tuning: ConceptIndex.Tuning) -> Score {
    var index = baseIndex
    index.tuning = tuning
    var result = Score()
    for entry in items {
        let recalled = index.recall(questionText: entry.item.question, contextText: entry.item.context,
                                    questionVector: entry.vector, limit: 3, now: now).map(\.concept.name)
        let allowed = Set(entry.item.expected + entry.item.acceptable)
        let foundHere = entry.item.expected.filter(recalled.contains)
        result.found += foundHere.count
        result.expectedTotal += entry.item.expected.count
        let wrongHere = recalled.filter { !allowed.contains($0) }
        result.falsePositives += wrongHere.count
        result.retrievedTotal += recalled.count
        if entry.item.expected.isEmpty {
            result.negatives += 1
            if recalled.isEmpty { result.cleanNegatives += 1 }
        }
        if foundHere.count < entry.item.expected.count {
            result.misses.append("\(entry.item.question)  wanted \(entry.item.expected) got \(recalled)")
        }
        if !wrongHere.isEmpty {
            result.wrong.append("\(entry.item.question)  wrongly \(wrongHere)")
        }
    }
    return result
}

func describe(_ name: String, _ result: Score) {
    print("\(name): found \(result.found)/\(result.expectedTotal) expected (\(Int(result.recall * 100))%), "
          + "\(result.falsePositives) wrong of \(result.retrievedTotal) surfaced (precision \(Int(result.precision * 100))%), "
          + "\(result.cleanNegatives)/\(result.negatives) unrelated questions left alone")
}

print("concepts \(baseIndex.count), questions \(prepared.count): dev \(dev.count), test \(test.count)")
// Stage one, names only: what is used when Haiku is late or there is no key.
describe("names only, dev", score(dev, tuning: .namesOnly))
let final = score(test, tuning: .namesOnly)
describe("names only, TEST", final)
print("names-only wrong surfacings on test:")
final.wrong.forEach { print("  " + $0) }

// Stage one, the shortlist: does it contain the right concepts at all?
// Haiku can only choose what it is shown.
func shortlistRecall(_ items: [Prepared], limit: Int) -> (found: Int, total: Int, averageLength: Double) {
    var found = 0, total = 0, lengths = 0
    for entry in items {
        let shortlist = baseIndex.candidates(questionText: entry.item.question, contextText: entry.item.context,
                                             questionVector: entry.vector, limit: limit).map(\.name)
        found += entry.item.expected.filter(shortlist.contains).count
        total += entry.item.expected.count
        lengths += shortlist.count
    }
    return (found, total, Double(lengths) / Double(max(1, items.count)))
}
for limit in [6, 12, 20] {
    let devRecall = shortlistRecall(dev, limit: limit), testRecall = shortlistRecall(test, limit: limit)
    print(String(format: "shortlist of up to %d: dev holds %d/%d, test holds %d/%d expected (average length %.1f)",
                 limit, devRecall.found, devRecall.total, testRecall.found, testRecall.total, testRecall.averageLength))
}

// For the Haiku stage, graded in rerank_eval.py.
struct ShortlistRow: Encodable {
    let half: String; let question: String; let context: String
    let expected: [String]; let acceptable: [String]
    let candidates: [[String: String]]
}
var rows: [ShortlistRow] = []
for (half, items) in [("dev", dev), ("test", test)] {
    for entry in items {
        let shortlist = baseIndex.candidates(questionText: entry.item.question, contextText: entry.item.context,
                                             questionVector: entry.vector, limit: 12)
        rows.append(ShortlistRow(half: half, question: entry.item.question, context: entry.item.context,
                                 expected: entry.item.expected, acceptable: entry.item.acceptable,
                                 candidates: shortlist.map { ["name": $0.name, "summary": $0.summary] }))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted]
let shortlistFile = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : NSTemporaryDirectory() + "shortlists.json")
try! encoder.encode(rows).write(to: shortlistFile)
print("wrote shortlists for the Haiku stage to \(shortlistFile.path)")

// Timing at a size no student reaches.
var bigIndex = ConceptIndex()
let vocabulary = conceptFile.concepts.flatMap { ConceptText.tokens($0.name + " " + $0.summary) }
let dimension = baseIndex.vector(at: 0)?.count ?? 512
for number in 0..<5_000 {
    var vector = (0..<dimension).map { _ in Float.random(in: -1...1) }
    let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    vector = vector.map { $0 / length }
    let name = (0..<3).map { _ in vocabulary.randomElement()! }.joined(separator: " ") + " \(number)"
    let summary = (0..<14).map { _ in vocabulary.randomElement()! }.joined(separator: " ")
    bigIndex.upsert(RememberedConcept(
        id: UUID(), name: name, aliases: [], cues: (0..<10).map { _ in (0..<3).map { _ in vocabulary.randomElement()! }.joined(separator: " ") },
        summary: summary, lastAngle: nil,
        firstExplainedAt: now, lastExplainedAt: now, timesExplained: 1, timesLost: 0, lastLostAt: nil,
        stabilityDays: 2, lessonTitles: []), vector: vector)
}
let sampleQuestion = prepared[0]
var timings: [Double] = []
for _ in 0..<200 {
    let start = DispatchTime.now().uptimeNanoseconds
    _ = bigIndex.candidates(questionText: sampleQuestion.item.question,
                            contextText: String(repeating: "load balancer redis postgres app server ", count: 40),
                            questionVector: sampleQuestion.vector, limit: 12)
    timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}
timings.sort()
print(String(format: "\nshortlist over 5000 concepts with a long screen: median %.2f ms, p95 %.2f ms, max %.2f ms",
             timings[100], timings[190], timings[199]))

let start = DispatchTime.now().uptimeNanoseconds
_ = embed(sampleQuestion.item.question)
print(String(format: "embedding one question: %.1f ms (already done for the question sorter, so reused)",
             Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
