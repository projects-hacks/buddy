//
//  QuestionSorter.swift
//  leanring-buddy
//
//  Decides what kind of question was asked, which decides which model answers
//  it, how long the answer may be, and whether the tutor changes tack.
//
//  By meaning rather than by keywords. Graded on 50 spoken phrasings
//  (scripts/question_sorting), the keyword lists put 30 in the right kind and
//  sent 35 to the right model: "that makes no sense to me" contains no phrase
//  on the push-back list, and "is it worth adding a cdn" missed "worth it".
//  Comparing the question's meaning to example phrasings with the sentence
//  model built into macOS got 40 kinds and 45 models right, the same 45 as
//  asking Claude Haiku, in 9 milliseconds instead of 700, on the machine, and
//  for nothing. It also wrongly decided the student was lost once where Haiku
//  did three times, and that mistake is the costly one, because it tells the
//  tutor its last answer failed and to start again differently.
//
//  On a blind set of 100 spoken questions written by someone who had never
//  seen the examples (scripts/question_sorting/spoken_test.json), it fared
//  worse: 33 of the 50 held-out ones. Its examples had been written in the
//  same short style as its first test. It is now the first of two stages: it
//  decides alone only when it is very sure, and otherwise Claude Haiku
//  decides (QuestionKindClassifier.swift), which got 46 of the 50.
//
//  The keyword lists stay as the fallback for the moment before the model has
//  loaded, or if macOS has not downloaded it.
//

import Foundation
import NaturalLanguage

/// Sorts a transcript into a question kind by its nearest example phrasings.
///
/// Main actor because NLContextualEmbedding is not documented as safe to use
/// from several threads, and one sentence takes about 9ms, which is nothing
/// against the screenshot that follows.
@MainActor
final class QuestionSorter {
    private var embeddingModel: NLContextualEmbedding?
    /// Each example's vector and the kind it stands for, built once.
    private var exampleVectors: [(vector: [Double], kind: QuestionKind)] = []

    var isReady: Bool { !exampleVectors.isEmpty }

    /// Loads the model and embeds the examples. Called at launch so the first
    /// question does not pay for it.
    func prepare() async {
        guard !isReady else { return }
        guard let model = NLContextualEmbedding(language: .english) else {
            TutorDebugLog.write("⚠️ question sorter: no English embedding model, using keywords")
            return
        }

        if !model.hasAvailableAssets {
            // macOS downloads the model on request. Until it arrives the
            // keyword fallback answers, so nothing waits on this.
            let assetsArrived = await withCheckedContinuation { continuation in
                model.requestAssets { result, _ in
                    continuation.resume(returning: result == .available)
                }
            }
            guard assetsArrived else {
                TutorDebugLog.write("⚠️ question sorter: embedding model not downloaded, using keywords")
                return
            }
        }

        do {
            try model.load()
        } catch {
            TutorDebugLog.write("⚠️ question sorter: model failed to load (\(error.localizedDescription)), using keywords")
            return
        }
        embeddingModel = model

        guard let examplesURL = Bundle.main.url(forResource: "QuestionKindExamples", withExtension: "json"),
              let examplesData = try? Data(contentsOf: examplesURL),
              let examplesFile = try? JSONDecoder().decode(ExamplesFile.self, from: examplesData) else {
            TutorDebugLog.write("⚠️ question sorter: examples file missing, using keywords")
            return
        }

        var builtVectors: [(vector: [Double], kind: QuestionKind)] = []
        let allExamples = examplesFile.examples.merging(examplesFile.spokenExamples ?? [:]) { $0 + $1 }
        for (kindName, phrasings) in allExamples {
            guard let kind = QuestionKind(exampleFileName: kindName) else { continue }
            for phrasing in phrasings {
                if let vector = normalisedVector(for: phrasing) {
                    builtVectors.append((vector, kind))
                }
            }
        }
        exampleVectors = builtVectors
        TutorDebugLog.write("🗂️ question sorter ready: \(builtVectors.count) examples")
    }

    /// Turns similarity scores into probabilities. Fitted by leave-one-out
    /// over the examples alone (scripts/question_sorting/calibrate.py); on the
    /// blind spoken test half the stated confidence was within 8 points of
    /// how often it was right, and every answer above 0.9 was right.
    static let temperature = 0.008

    /// Above this the on-device answer is trusted without asking Haiku.
    /// Chosen on the dev half of the blind spoken set.
    static let confidentEnough = 0.95

    /// How likely each kind is, or nil when the sorter is not ready and the
    /// caller should fall back to keywords.
    ///
    /// Push-back needs something to push back on. With no previous answer,
    /// "i don't understand this" is a request to be taught, so whatever
    /// weight re-explaining had goes to teaching.
    func probabilities(of transcript: String, hasPreviousAnswer: Bool) -> [QuestionKind: Double]? {
        guard isReady, let questionVector = normalisedVector(for: transcript.lowercased()) else {
            return nil
        }

        var similaritiesByKind: [QuestionKind: [Double]] = [:]
        for example in exampleVectors {
            let similarity = zip(questionVector, example.vector).reduce(0) { sum, pair in
                sum + pair.0 * pair.1
            }
            similaritiesByKind[example.kind, default: []].append(similarity)
        }

        // Each kind scores the mean of its three closest examples, so one
        // stray close example cannot decide it alone.
        let scoresByKind = similaritiesByKind.mapValues { similarities in
            let closest = similarities.sorted(by: >).prefix(3)
            return closest.reduce(0, +) / Double(closest.count)
        }
        guard let highestScore = scoresByKind.values.max() else { return nil }

        var weights = scoresByKind.mapValues { exp(($0 - highestScore) / Self.temperature) }
        if !hasPreviousAnswer, let reexplainWeight = weights[.reexplain] {
            weights[.reexplain] = 0
            weights[.teach, default: 0] += reexplainWeight
        }
        let total = weights.values.reduce(0, +)
        return weights.mapValues { $0 / total }
    }

    /// The likeliest kind and how sure the sorter is of it.
    func kind(of transcript: String, hasPreviousAnswer: Bool) -> (kind: QuestionKind, confidence: Double)? {
        guard let probabilities = probabilities(of: transcript, hasPreviousAnswer: hasPreviousAnswer),
              let best = probabilities.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value)
    }

    /// Mean of the model's per-token vectors, scaled to length one so a dot
    /// product is the cosine similarity. Same pooling the test grades.
    private func normalisedVector(for sentence: String) -> [Double]? {
        guard let embeddingModel,
              let result = try? embeddingModel.embeddingResult(for: sentence, language: .english) else {
            return nil
        }

        var summed = [Double](repeating: 0, count: embeddingModel.dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: sentence.startIndex..<sentence.endIndex) { tokenVector, _ in
            for index in 0..<min(tokenVector.count, summed.count) {
                summed[index] += tokenVector[index]
            }
            tokenCount += 1
            return true
        }
        guard tokenCount > 0 else { return nil }

        let length = sqrt(summed.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return nil }
        return summed.map { $0 / length }
    }

    private struct ExamplesFile: Decodable {
        let examples: [String: [String]]
        /// Long, padded phrasings in the way real questions arrive.
        let spokenExamples: [String: [String]]?

        enum CodingKeys: String, CodingKey {
            case examples
            case spokenExamples = "spoken_examples"
        }
    }
}

private extension QuestionKind {
    /// The examples file names kinds the way the test does.
    init?(exampleFileName: String) {
        switch exampleFileName {
        case "quick": self = .quick
        case "normal": self = .normal
        case "teach": self = .teach
        case "reexplain": self = .reexplain
        case "tradeoff": self = .tradeOff
        default: return nil
        }
    }
}
