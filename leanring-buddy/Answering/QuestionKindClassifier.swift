//
//  QuestionKindClassifier.swift
//  leanring-buddy
//
//  The second stage of sorting a question: Claude Haiku, asked only when the
//  on-device sorter is unsure.
//
//  Graded on the held-out half of a blind set of 100 spoken questions
//  (scripts/question_sorting/cascade_test.py): Haiku put 46 of 50 in the right
//  kind where the on-device sorter put 33, and never mistook a new question
//  for "I didn't follow", the mistake that throws away a good answer. It takes
//  about 0.7s, and it is asked while the screen is captured and read, which
//  takes about as long, so it adds little or nothing to the wait. It costs a
//  small fraction of a cent.
//
//  The on-device answer stands whenever Haiku is not back in time, fails, or
//  there is no Anthropic key: a slower or missing second opinion must never
//  hold up the answer.
//

import Foundation

extension ClaudeVisionProvider {
    /// What Haiku is told, kept in a file so scripts/question_sorting grades
    /// exactly what ships.
    private static let questionSorterPrompt: String? = Bundle.main
        .url(forResource: "QuestionSorterPrompt", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The kind of question by Haiku's reading, or nil if it could not say.
    /// What Haiku is shown: the exchange before, when there is one, so it
    /// can tell a new question from "that did not land", and the message.
    /// The same text the grader sends (scripts/question_sorting/).
    static func sortingMessage(_ transcript: String, previousExchange: (question: String, spokenAnswer: String)?) -> String {
        let before: String
        if let previousExchange {
            before = """
            <previous_exchange>
            <student_asked>\(previousExchange.question)</student_asked>
            <buddy_said>\(String(previousExchange.spokenAnswer.prefix(400)))</buddy_said>
            </previous_exchange>
            """
        } else {
            before = "<previous_exchange>none: this is the first thing they have said</previous_exchange>"
        }
        return before + "\n<message>\(transcript)</message>"
    }

    func classifyQuestion(_ transcript: String,
                          previousExchange: (question: String, spokenAnswer: String)?) async -> QuestionKind? {
        guard let apiKey = APIKeyStore.key(for: .anthropic),
              let systemPrompt = Self.questionSorterPrompt,
              let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }

        let body: [String: Any] = [
            "model": "claude-haiku-5-5",
            "max_tokens": 8,
            "system": systemPrompt,
            "thinking": ["type": "disabled"],
            "messages": [["role": "user", "content": Self.sortingMessage(transcript, previousExchange: previousExchange)]]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]] else {
                TutorDebugLog.write("⚠️ question classifier: unexpected response")
                return nil
            }
            SpendingMeter.record(APIPrices.claude(model: "claude-haiku-5-5", usageIn: json), for: .claude, purpose: .helpers)
            let word = content.compactMap { $0["text"] as? String }.joined().lowercased()
            // Longest names first, so "reexplain" is not read as something shorter.
            let kindsByName: [(String, QuestionKind)] = [
                ("reexplain", .reexplain), ("tradeoff", .tradeOff), ("normal", .normal),
                ("teach", .teach), ("quick", .quick), ("chat", .chat)
            ]
            return kindsByName.first { word.contains($0.0) }?.1
        } catch {
            // Cancelled at the deadline is the design working, not a failure.
            let wasCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !wasCancelled {
                TutorDebugLog.write("⚠️ question classifier failed: \(error.localizedDescription)")
            }
            return nil
        }
    }
}
