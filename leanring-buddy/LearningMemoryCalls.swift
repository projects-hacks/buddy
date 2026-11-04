//
//  LearningMemoryCalls.swift
//  leanring-buddy
//
//  The two Claude Haiku calls learning memory makes, each with its prompt in
//  a file so scripts/learning_memory grades exactly what ships.
//
//  Filing (LessonConceptPrompt.txt) runs after an answer has been spoken and
//  names the ideas it taught, matched against the nearest ones already
//  known, with the plain-words cues retrieval later matches on. About $0.002
//  a lesson.
//
//  Choosing (MemoryRecallPrompt.txt) runs while the screen is captured and
//  picks, from an on-device shortlist, the ideas a question is about. On the
//  held-out half of 80 blind questions it found 32 of 33 with 91% precision,
//  in a median 0.74s, about $0.0006 a question. When it is late or fails,
//  the names-only match on the device stands in.
//

import Foundation

extension ClaudeVisionProvider {
    private static let lessonConceptPrompt: String? = Bundle.main
        .url(forResource: "LessonConceptPrompt", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private static let memoryRecallPrompt: String? = Bundle.main
        .url(forResource: "MemoryRecallPrompt", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// Which of the shortlisted ideas the question is about, as positions in
    /// `candidates`. Nil when Haiku could not be asked or did not answer.
    func chooseRememberedConcepts(
        question: String,
        windowTitle: String?,
        candidates: [RememberedConcept]
    ) async -> [Int]? {
        guard !candidates.isEmpty, let systemPrompt = Self.memoryRecallPrompt else { return nil }
        let ideas = candidates.enumerated()
            .map { "\($0.offset + 1). \($0.element.name): \($0.element.summary)" }
            .joined(separator: "\n")
        let message = "the student said: \(question)\nwindow: \(windowTitle ?? "unknown")\n\nideas:\n\(ideas)"
        guard let reply = await quickHaikuReply(system: systemPrompt, message: message, maximumTokens: 12, timeout: 4) else {
            return nil
        }
        let numbers = reply.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if numbers.isEmpty { return [] }
        var positions: [Int] = []
        for number in numbers where (1...candidates.count).contains(number) && !positions.contains(number - 1) {
            positions.append(number - 1)
        }
        return Array(positions.prefix(3))
    }

    /// The ideas a finished lesson taught, or nil if Haiku could not be asked.
    func extractLessonConcepts(_ lesson: LessonToRemember, known: [RememberedConcept]) async -> [ExtractedConcept]? {
        guard let systemPrompt = Self.lessonConceptPrompt else { return nil }
        // Short ids keep the prompt small; they map back to the real ones.
        var idsByShortID: [String: UUID] = [:]
        let knownLines = known.map { concept -> String in
            let shortID = String(concept.id.uuidString.prefix(8)).lowercased()
            idsByShortID[shortID] = concept.id
            return "\(shortID): \(concept.name)"
        }
        let message = """
        KNOWN:
        \(knownLines.isEmpty ? "(none)" : knownLines.joined(separator: "\n"))

        THE STUDENT ASKED: \(lesson.question)
        LESSON TITLE: \(lesson.lessonTitle ?? "(none)")
        THE EXPLANATION: \(lesson.spokenAnswer.prefix(1_800))
        """
        guard let reply = await quickHaikuReply(system: systemPrompt, message: message, maximumTokens: 700, timeout: 20),
              let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let data = String(reply[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let concepts = json["concepts"] as? [[String: Any]] else {
            TutorDebugLog.write("⚠️ memory: could not file the lesson")
            return nil
        }
        return concepts.compactMap { entry in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            let sameAs = (entry["same_as"] as? String).flatMap { idsByShortID[$0.lowercased()] }
            return ExtractedConcept(
                name: name,
                sameAsID: sameAs,
                aliases: (entry["aliases"] as? [String]) ?? [],
                cues: (entry["cues"] as? [String]) ?? [],
                summary: (entry["summary"] as? String) ?? "",
                angle: entry["angle"] as? String
            )
        }
    }

    /// One short Haiku reply, or nil. No key, a timeout or an error all mean
    /// nil, and the caller carries on without it.
    private func quickHaikuReply(system: String, message: String, maximumTokens: Int, timeout: TimeInterval) async -> String? {
        guard let apiKey = APIKeyStore.key(for: .anthropic),
              let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        let body: [String: Any] = [
            "model": "claude-haiku-5-5",
            "max_tokens": maximumTokens,
            "system": system,
            "thinking": ["type": "disabled"],
            "messages": [["role": "user", "content": message]]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { $0["text"] as? String }.joined()
        } catch {
            return nil
        }
    }
}
