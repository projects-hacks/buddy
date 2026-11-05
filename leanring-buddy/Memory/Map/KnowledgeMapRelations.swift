//
//  KnowledgeMapRelations.swift
//  leanring-buddy
//
//  How remembered ideas relate to each other, for the map of what the
//  student knows (KnowledgeMapWindow.swift).
//
//  New lessons get their relations from the filing call that already runs
//  after every answer (LessonConceptPrompt.txt asks for a short "related"
//  list against the known ideas it was shown), so the map costs no extra
//  call per lesson. Stores from before relations get them once, in the
//  background, the first time the map is opened: one Claude Haiku call per
//  20 ideas (ConceptRelationsPrompt.txt), sending only names and the
//  one-sentence summaries, never a lesson, a question or the screen.
//
//  Both replies are read the same strict way: a link counts only if its kind
//  is on the fixed list and both its ids were in what Haiku was shown, so an
//  invented or misread id can never put an edge on the map.
//

import Foundation

nonisolated enum ConceptRelationReading {
    /// The links an idea's "related" list names in a filing reply. Nil when
    /// the reply had no list at all, so the idea counts as never asked.
    static func filingRelations(in related: Any?, idsByShortID: [String: UUID], sameAsID: UUID?) -> [ConceptRelation]? {
        guard let entries = related as? [[String: Any]] else { return nil }
        var relations: [ConceptRelation] = []
        for entry in entries {
            guard let targetID = (entry["id"] as? String).flatMap({ idsByShortID[$0.lowercased()] }),
                  targetID != sameAsID,
                  let kind = normalisedKind(entry["how"]),
                  !relations.contains(where: { $0.targetID == targetID }) else { continue }
            relations.append(ConceptRelation(kind: kind, targetID: targetID))
        }
        return Array(relations.prefix(3))
    }

    /// The links in a relation-pass reply, by the idea they start from. Every
    /// idea in `subjectIDs` gets an entry, empty when it has no link, so a
    /// pass that was answered never asks about the same idea again.
    static func passLinks(in reply: String, idsByShortID: [String: UUID], subjectIDs: Set<UUID>) -> [UUID: [ConceptRelation]]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let links = json["links"] as? [[String: Any]] else { return nil }
        var relationsBySubject: [UUID: [ConceptRelation]] = [:]
        for subjectID in subjectIDs { relationsBySubject[subjectID] = [] }
        var linkedPairs: Set<Set<UUID>> = []
        for link in links {
            guard let fromID = (link["from"] as? String).flatMap({ idsByShortID[$0.lowercased()] }),
                  subjectIDs.contains(fromID),
                  let toID = (link["to"] as? String).flatMap({ idsByShortID[$0.lowercased()] }),
                  toID != fromID,
                  let kind = normalisedKind(link["how"]),
                  !linkedPairs.contains([fromID, toID]),
                  (relationsBySubject[fromID]?.count ?? 0) < 3 else { continue }
            linkedPairs.insert([fromID, toID])
            relationsBySubject[fromID, default: []].append(ConceptRelation(kind: kind, targetID: toID))
        }
        return relationsBySubject
    }

    private static func normalisedKind(_ value: Any?) -> String? {
        guard let kind = (value as? String)?.lowercased().trimmingCharacters(in: .whitespaces),
              ConceptRelation.kinds.contains(kind) else { return nil }
        return kind
    }

    /// The first eight characters of the id, which is all Haiku needs to
    /// tell ideas apart and a third of the tokens of a whole one. Lengthened
    /// in the rare case two ideas share a prefix.
    static func shortIDs(for concepts: [RememberedConcept]) -> [UUID: String] {
        var shortIDByID: [UUID: String] = [:]
        var usedShortIDs: Set<String> = []
        for concept in concepts {
            var length = 8
            var shortID = String(concept.id.uuidString.prefix(length)).lowercased()
            while usedShortIDs.contains(shortID) && length < 36 {
                length += 4
                shortID = String(concept.id.uuidString.prefix(length)).lowercased()
            }
            usedShortIDs.insert(shortID)
            shortIDByID[concept.id] = shortID
        }
        return shortIDByID
    }
}

/// One call's worth of the one-time pass: up to 20 ideas to find links for,
/// and the nearest other ideas, by name only, that they may link to.
nonisolated struct RelationPassBatch {
    let subjects: [RememberedConcept]
    let neighbours: [RememberedConcept]

    /// The message Haiku is sent, and the short ids it may answer with.
    func message() -> (text: String, idsByShortID: [String: UUID]) {
        let shortIDByID = ConceptRelationReading.shortIDs(for: subjects + neighbours)
        var idsByShortID: [String: UUID] = [:]
        for (id, shortID) in shortIDByID { idsByShortID[shortID] = id }
        let subjectLines = subjects.map { concept in
            "\(shortIDByID[concept.id] ?? ""): \(concept.name): \(concept.summary.prefix(200))"
        }
        let neighbourLines = neighbours.map { concept in "\(shortIDByID[concept.id] ?? ""): \(concept.name)" }
        let text = """
        IDEAS:
        \(subjectLines.joined(separator: "\n"))

        OTHER KNOWN:
        \(neighbourLines.isEmpty ? "(none)" : neighbourLines.joined(separator: "\n"))
        """
        return (text, idsByShortID)
    }
}

nonisolated enum KnowledgeMapRelationPass {
    static let conceptsPerCall = 20
    static let neighboursPerCall = 20
    /// Set once every batch has been answered, so the pass runs once per
    /// store, on the first opening of the map, and never again.
    static let finishedDefaultsKey = "knowledgeMapRelationPassFinished"

    static func hasFinished(in defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: finishedDefaultsKey) }

    /// The ideas with no relations on record, in batches of related ideas,
    /// so most links a batch could draw are inside what it is shown. Each
    /// batch starts from the oldest idea left and takes the ones most like
    /// it, by meaning where both have a vector and by shared words always.
    static func batches(concepts: [RememberedConcept], vectorForConceptID: (UUID) -> [Float]?) -> [RelationPassBatch] {
        let wordsByID = Dictionary(uniqueKeysWithValues: concepts.map {
            ($0.id, Set(ConceptText.tokens("\($0.name) \($0.summary)")))
        })
        let vectorsByID = Dictionary(uniqueKeysWithValues: concepts.compactMap { concept in
            vectorForConceptID(concept.id).map { (concept.id, $0) }
        })
        func similarity(_ first: RememberedConcept, _ second: RememberedConcept) -> Double {
            let firstWords = wordsByID[first.id] ?? [], secondWords = wordsByID[second.id] ?? []
            let union = firstWords.union(secondWords).count
            let sharedWords = union == 0 ? 0 : Double(firstWords.intersection(secondWords).count) / Double(union)
            guard let firstVector = vectorsByID[first.id], let secondVector = vectorsByID[second.id],
                  firstVector.count == secondVector.count else { return sharedWords }
            var dotProduct: Float = 0
            for position in firstVector.indices { dotProduct += firstVector[position] * secondVector[position] }
            return sharedWords + Double(dotProduct)
        }

        var remaining = concepts.filter { $0.relations == nil }
            .sorted { ($0.firstExplainedAt, $0.id.uuidString) < ($1.firstExplainedAt, $1.id.uuidString) }
        var batches: [RelationPassBatch] = []
        while !remaining.isEmpty {
            let seed = remaining.removeFirst()
            let nearest = remaining.sorted { similarity(seed, $0) > similarity(seed, $1) }
                .prefix(conceptsPerCall - 1)
            let subjects = [seed] + nearest
            let subjectIDs = Set(subjects.map(\.id))
            remaining.removeAll { subjectIDs.contains($0.id) }
            let neighbours = concepts.filter { !subjectIDs.contains($0.id) }
                .map { candidate in (candidate, subjects.reduce(0.0) { $0 + similarity($1, candidate) }) }
                .sorted { $0.1 > $1.1 }
                .prefix(neighboursPerCall)
                .map(\.0)
            batches.append(RelationPassBatch(subjects: subjects, neighbours: Array(neighbours)))
        }
        return batches
    }

    /// Runs the pass if it has not finished before, one batch at a time,
    /// applying each as it comes back so an open map fills in as it goes.
    /// `ask` sends one message and returns Haiku's reply, or nil.
    @MainActor
    /// `defaults` is a parameter only so scripts/knowledge_map can test the
    /// pass without touching the app's own settings.
    static func runIfNeeded(memory: LearningMemory, defaults: UserDefaults = .standard,
                            ask: @escaping (String) async -> String?) async {
        guard memory.isEnabled, memory.isLoaded, !hasFinished(in: defaults) else { return }
        let concepts = memory.index.concepts
        var vectorsByID: [UUID: [Float]] = [:]
        for position in concepts.indices {
            if let vector = memory.index.vector(at: position) { vectorsByID[concepts[position].id] = vector }
        }
        // Grouping hundreds of ideas compares every pair; off the main actor
        // so the map opens without a stall.
        let batches = await Task.detached(priority: .utility) {
            Self.batches(concepts: concepts) { vectorsByID[$0] }
        }.value
        guard !batches.isEmpty else {
            defaults.set(true, forKey: finishedDefaultsKey)
            return
        }
        TutorDebugLog.write("🗺️ map: finding relations for \(batches.reduce(0) { $0 + $1.subjects.count }) older ideas in \(batches.count) calls")
        var everyBatchAnswered = true
        for batch in batches {
            let message = batch.message()
            guard let reply = await ask(message.text),
                  let links = ConceptRelationReading.passLinks(
                      in: reply, idsByShortID: message.idsByShortID, subjectIDs: Set(batch.subjects.map(\.id))) else {
                everyBatchAnswered = false
                continue
            }
            memory.applyBackfilledRelations(links)
        }
        // A batch that failed (offline, no key) leaves its ideas unasked, and
        // the next opening tries only those again.
        if everyBatchAnswered { defaults.set(true, forKey: finishedDefaultsKey) }
    }
}
