//
//  LearningMemoryCalls.swift
//  leanring-buddy
//
//  The Claude Haiku calls learning memory makes (and the one how-tos make), each with its prompt in
//  a file so scripts/learning_memory grades exactly what ships.
//
//  Filing (LessonConceptPrompt.txt) runs after an answer has been spoken and
//  names the ideas it taught, matched against the nearest ones already
//  known, with the plain-words cues retrieval later matches on, and how each
//  relates to those known ones, which the map of what the student knows
//  draws. About $0.002 a lesson.
//
//  Choosing (MemoryRecallPrompt.txt) runs while the screen is captured and
//  picks, from an on-device shortlist, the ideas a question is about. On the
//  held-out half of 80 blind questions it found 32 of 33 with 88 to 91% precision over repeated runs,
//  in a median 0.74s, about $0.0006 a question. When it is late or fails,
//  the names-only match on the device stands in.
//

import Foundation

extension ClaudeVisionProvider {
    private static let lessonConceptPrompt: String? = Bundle.main
        .url(forResource: "LessonConceptPrompt", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private static let howToCuesPrompt: String? = Bundle.main
        .url(forResource: "HowToCuesPrompt", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// A plain name for a finished how-to and ten ways of asking for it, so
    /// the next request finds it on the Mac with no model call. Written once,
    /// when the how-to is saved, for about $0.0005.
    func howToCues(_ howTo: HowTo) async -> (title: String, phrasings: [String])? {
        guard let systemPrompt = Self.howToCuesPrompt else { return nil }
        let steps = howTo.steps.enumerated().map { index, step in
            "\(index + 1). \(step.instruction ?? step.sentences.joined(separator: " "))"
                + (step.targetLabel.map { " (control: \($0))" } ?? "")
        }.joined(separator: "\n")
        let message = "app: \(howTo.appName)\nthey asked: \(howTo.questions.first ?? howTo.title)\nsteps:\n\(steps)"
        guard let reply = await quickHaikuReply(system: systemPrompt, message: message, maximumTokens: 400, timeout: 10),
              let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] else {
            return nil
        }
        let title = (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let phrasings = (json["phrasings"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (title, Array(phrasings.prefix(12)))
    }

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
        // Three ideas with a dozen cues each run to about 900 tokens; 700 cut
        // replies off mid-object in real use.
        guard let reply = await quickHaikuReply(system: systemPrompt, message: message, maximumTokens: 1_600, timeout: 25),
              let concepts = Self.conceptObjects(in: reply) else {
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
                angle: entry["angle"] as? String,
                relations: ConceptRelationReading.filingRelations(
                    in: entry["related"], idsByShortID: idsByShortID, sameAsID: sameAs)
            )
        }
    }

    /// The concept objects in a reply, keeping every complete one even when
    /// the reply was cut off part-way through a later one.
    static func conceptObjects(in reply: String) -> [[String: Any]]? {
        guard let start = reply.firstIndex(of: "{") else { return nil }
        var candidate = String(reply[start...])
        if let end = candidate.lastIndex(of: "}") {
            let whole = String(candidate[...end])
            if let json = try? JSONSerialization.jsonObject(with: Data(whole.utf8)) as? [String: Any],
               let concepts = json["concepts"] as? [[String: Any]] {
                return concepts
            }
        }
        // Cut off: close the array after the last complete object.
        while let lastBoundary = candidate.range(of: "},", options: .backwards) {
            candidate = String(candidate[..<lastBoundary.lowerBound]) + "}]}"
            if let json = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any],
               let concepts = json["concepts"] as? [[String: Any]], !concepts.isEmpty {
                TutorDebugLog.write("🧠 memory: lesson reply was cut off, kept \(concepts.count) complete ideas")
                return concepts
            }
            candidate = String(candidate.dropLast(3))
        }
        return nil
    }

    /// One short Haiku reply, or nil. No key, a timeout or an error all mean
    /// nil, and the caller carries on without it. Not private so the map's
    /// one-time relation pass (KnowledgeMapRelations.swift) shares it.
    func quickHaikuReply(system: String, message: String, maximumTokens: Int, timeout: TimeInterval) async -> String? {
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
            SpendingMeter.record(APIPrices.claude(model: "claude-haiku-5-5", usageIn: json), for: .claude, purpose: .helpers)
            return content.compactMap { $0["text"] as? String }.joined()
        } catch {
            return nil
        }
    }
}
