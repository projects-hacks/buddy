//
//  CompanionManager+History.swift
//  leanring-buddy
//
//  The conversation kept for the model, shortened and trimmed in
//  batches, and the re-explanation it feeds.
//

import AppKit
import Foundation

extension CompanionManager {
    /// Recent answers are kept whole, so the next one can build on what was
    /// drawn or explain it differently. Older ones keep only what was said,
    /// about a tenth of the size, so a long session stays in view without
    /// paying for every old drawing again.
    static let wholeAnswersKept = 10
    static let exchangesKept = 40
    /// Older answers are shortened, and the oldest dropped, several at a
    /// time rather than one per question: the cached history then stays the
    /// same for several questions in a row instead of changing every time.
    static let historyTrimBatch = 6

    func rememberExchange(question: String, answer: String) {
        conversationHistory = Self.history(conversationHistory, remembering: question, answer: answer)
    }

    /// The history with one more exchange, shortened and trimmed as above.
    /// Pure, so the unit tests check it.
    static func history(
        _ earlierHistory: [(userTranscript: String, assistantResponse: String)],
        remembering question: String, answer: String
    ) -> [(userTranscript: String, assistantResponse: String)] {
        var history = earlierHistory
        history.append((userTranscript: question, assistantResponse: answer))
        let wholeAnswerCount = history.filter { !$0.assistantResponse.hasPrefix(spokenOnlyMarker) }.count
        if wholeAnswerCount > wholeAnswersKept {
            var shortened = 0
            for position in history.indices where shortened < historyTrimBatch {
                let entry = history[position]
                guard !entry.assistantResponse.hasPrefix(spokenOnlyMarker) else { continue }
                history[position].assistantResponse = spokenPart(of: entry.assistantResponse)
                shortened += 1
            }
        }
        if history.count > exchangesKept {
            history.removeFirst(min(history.count, historyTrimBatch))
        }
        return history
    }

    static let spokenOnlyMarker = "(An earlier answer, only what was said; its drawing is left out.)"

    /// The sentences of a drawing program, in order. A prose answer has no
    /// say() lines and is kept as it is, cut to a length that still reads.
    static func spokenPart(of answer: String) -> String {
        let sayCall = try! NSRegularExpression(pattern: #"say\(\s*"((?:[^"\\]|\\.)*)""#)
        let range = NSRange(answer.startIndex..., in: answer)
        let sentences = sayCall.matches(in: answer, range: range).compactMap { match -> String? in
            guard let sentenceRange = Range(match.range(at: 1), in: answer) else { return nil }
            return String(answer[sentenceRange]).replacingOccurrences(of: #"\""#, with: "\"")
        }
        let spoken = sentences.isEmpty ? String(answer.prefix(800)) : sentences.joined(separator: " ")
        return spokenOnlyMarker + " " + spoken
    }

    /// Whether the student is saying the last explanation did not work.
    static func isAskingAgain(_ transcript: String) -> Bool {
        let lowercasedTranscript = transcript.lowercased()
        let pushBackPhrases = [
            "again", "didn't get", "didnt get", "don't get", "dont get",
            "don't understand", "dont understand", "not clear", "unclear",
            "confused", "confusing", "still", "what do you mean",
            "simpler", "another way", "rephrase", "lost me", "huh"
        ]
        return pushBackPhrases.contains { phrase in lowercasedTranscript.contains(phrase) }
    }

    func reexplanationInstruction() -> String {
        guard consecutiveReexplanationCount > 0 else { return "" }

        // Ordered from cheapest shift to most drastic, so a student who keeps
        // pushing back gets progressively more concrete rather than more words.
        let strategiesInEscalatingOrder = [
            "take one small concrete example with real numbers and walk it through a step at a time. no definitions.",
            "use an analogy from ordinary life, nothing to do with computers, then tie it back in one sentence.",
            "stop explaining and show it. mark up what is on their screen and talk only about what you marked.",
            "start from what goes wrong without it. describe the failure first, then the fix."
        ]
        let chosenStrategy = strategiesInEscalatingOrder[
            min(consecutiveReexplanationCount - 1, strategiesInEscalatingOrder.count - 1)
        ]

        let failedAttempt = conversationHistory.last?.assistantResponse ?? ""

        return """


        THE STUDENT STILL DOES NOT FOLLOW. this is attempt \(consecutiveReexplanationCount + 1).
        your previous attempt was: "\(failedAttempt.prefix(350))"
        that did not work. do not restate it and do not paraphrase it.
        change the approach completely: \(chosenStrategy)
        """
    }
}
