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
    func classifyQuestion(_ transcript: String, hasPreviousAnswer: Bool) async -> QuestionKind? {
        guard let apiKey = APIKeyStore.key(for: .anthropic),
              let systemPrompt = Self.questionSorterPrompt,
              let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }

        let situation = hasPreviousAnswer
            ? "the helper has already answered something in this conversation."
            : "this is the first thing the student has asked; nothing has been explained yet."
        let body: [String: Any] = [
            "model": "claude-haiku-5-5",
            "max_tokens": 8,
            "system": systemPrompt,
            "thinking": ["type": "disabled"],
            "messages": [["role": "user", "content": "\(situation)\n\nthe student said: \(transcript)"]]
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
            let word = content.compactMap { $0["text"] as? String }.joined().lowercased()
            // Longest names first, so "reexplain" is not read as something shorter.
            let kindsByName: [(String, QuestionKind)] = [
                ("reexplain", .reexplain), ("tradeoff", .tradeOff), ("normal", .normal),
                ("teach", .teach), ("quick", .quick)
            ]
            return kindsByName.first { word.contains($0.0) }?.1
        } catch {
            if !(error is CancellationError) {
                TutorDebugLog.write("⚠️ question classifier failed: \(error.localizedDescription)")
            }
            return nil
        }
    }
}
