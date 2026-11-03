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
        for (kindName, phrasings) in examplesFile.examples {
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

    /// The kind of question, or nil when the sorter is not ready and the
    /// caller should fall back to keywords.
    ///
    /// Push-back needs something to push back on, so with no previous answer
    /// a "re-explain" verdict is read as a normal question.
    func kind(of transcript: String, hasPreviousAnswer: Bool) -> QuestionKind? {
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
        // stray close example cannot decide it alone. Three is under half of
        // the eight examples each kind has.
        let scoresByKind = similaritiesByKind.mapValues { similarities in
            let closest = similarities.sorted(by: >).prefix(3)
            return closest.reduce(0, +) / Double(closest.count)
        }
        guard let bestKind = scoresByKind.max(by: { $0.value < $1.value })?.key else {
            return nil
        }

        if bestKind == .reexplain && !hasPreviousAnswer {
            return .normal
        }
        return bestKind
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
