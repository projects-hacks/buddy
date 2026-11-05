// End-to-end test of LearningMemory itself, in a scratch folder, with real
// Claude Haiku calls through the prompts that ship. Nothing is spoken or
// drawn. Checks filing, merging the same idea under another wording, spaced
// strengthening, getting lost, saving and reloading, archiving stale ideas,
// recall through the cascade and by name, the note the tutor gets, and the
// relations filing gives the map of what the student knows.
//
// build and run (from the repository root), key on stdin, never printed:
//   cp scripts/learning_memory/memory_flow_test.swift /tmp/flow/main.swift
//   xcrun swiftc -O -o /tmp/flow/test leanring-buddy/Memory/ConceptIndex.swift leanring-buddy/Memory/LearningMemory.swift \
//     leanring-buddy/Memory/Map/KnowledgeMapRelations.swift /tmp/flow/main.swift
//   security find-generic-password -a api-key -s com.maverickrajeev.clicky-local.anthropic -w | /tmp/flow/test /tmp/flow/store

import Foundation
import NaturalLanguage

enum TutorDebugLog { static func write(_ line: String) { print("   log:", line) } }
// LearningMemory's default folder names it; every store here is a scratch one.
enum AppIdentity { static let dataName = "Buddy-flow-test" }

let apiKey = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let storeFolder = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: storeFolder)
let promptFolder = URL(fileURLWithPath: "leanring-buddy/Memory")
let lessonPrompt = try! String(contentsOf: promptFolder.appendingPathComponent("LessonConceptPrompt.txt"), encoding: .utf8)
let recallPrompt = try! String(contentsOf: promptFolder.appendingPathComponent("MemoryRecallPrompt.txt"), encoding: .utf8)

let model = NLContextualEmbedding(language: .english)!
try! model.load()
nonisolated(unsafe) let embeddingLock = NSLock()
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

func haiku(_ system: String, _ message: String, _ maximumTokens: Int) async -> String? {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try! JSONSerialization.data(withJSONObject: [
        "model": "claude-haiku-5-5", "max_tokens": maximumTokens, "system": system,
        "thinking": ["type": "disabled"], "messages": [["role": "user", "content": message]]])
    guard let (data, _) = try? await URLSession.shared.data(for: request),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = json["content"] as? [[String: Any]] else { return nil }
    return content.compactMap { $0["text"] as? String }.joined()
}

// The same message shapes as LearningMemoryCalls.swift.
@MainActor func configure(_ memory: LearningMemory) {
    memory.embed = embed
    memory.embeddingModelIdentifier = { "\(model.modelIdentifier)#\(model.revision)" }
    memory.extract = { lesson, known in
        var ids: [String: UUID] = [:]
        let knownLines = known.map { concept -> String in
            let short = String(concept.id.uuidString.prefix(8)).lowercased()
            ids[short] = concept.id
            return "\(short): \(concept.name)"
        }
        let message = "KNOWN:\n\(knownLines.isEmpty ? "(none)" : knownLines.joined(separator: "\n"))\n\nTHE STUDENT ASKED: \(lesson.question)\nLESSON TITLE: \(lesson.lessonTitle ?? "(none)")\nTHE EXPLANATION: \(lesson.spokenAnswer)"
        guard let reply = await haiku(lessonPrompt, message, 1_600),
              let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(String(reply[start...end]).utf8)) as? [String: Any],
              let concepts = json["concepts"] as? [[String: Any]] else { return nil }
        return concepts.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return ExtractedConcept(name: name, sameAsID: (entry["same_as"] as? String).flatMap { ids[$0.lowercased()] },
                                    aliases: entry["aliases"] as? [String] ?? [], cues: entry["cues"] as? [String] ?? [],
                                    summary: entry["summary"] as? String ?? "", angle: entry["angle"] as? String,
                                    relations: ConceptRelationReading.filingRelations(
                                        in: entry["related"], idsByShortID: ids,
                                        sameAsID: (entry["same_as"] as? String).flatMap { ids[$0.lowercased()] }))
        }
    }
    memory.choose = { question, window, candidates in
        let ideas = candidates.enumerated().map { "\($0.offset + 1). \($0.element.name): \($0.element.summary)" }.joined(separator: "\n")
        guard let reply = await haiku(recallPrompt, "the student said: \(question)\nwindow: \(window ?? "unknown")\n\nideas:\n\(ideas)", 12)?.lowercased() else { return nil }
        if reply.contains("none") { return [] }
        return reply.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...candidates.count).contains($0) }.map { $0 - 1 }
    }
}

var failures = 0
func check(_ condition: Bool, _ description: String) {
    print(condition ? "PASS" : "FAIL", description)
    if !condition { failures += 1 }
}

let day: TimeInterval = 86_400
let start = Date().addingTimeInterval(-10 * day)

await MainActor.run {} // enter the main actor's world for the test body below
let result: Int = await Task { @MainActor in
    let memory = LearningMemory(folder: storeFolder)
    configure(memory)
    await memory.load()

    print("\n1. filing two lessons")
    await memory.remember(LessonToRemember(
        question: "can you explain how consistent hashing works with these servers", lessonTitle: "Consistent Hashing",
        spokenAnswer: "servers sit on a ring of hash values. each key goes to the first server clockwise from its hash. adding a server only moves the keys between it and the one before it. virtual nodes give each server many points on the ring so load stays even.",
        questionKind: "teach", answeredBy: "argon", date: start))
    await memory.remember(LessonToRemember(
        question: "what's eventual consistency", lessonTitle: "Eventual Consistency",
        spokenAnswer: "after a write, replicas can disagree for a moment. your friend may still see your old bio on another server. given time with no new writes, every replica catches up to the same value.",
        questionKind: "normal", answeredBy: "sonnet", date: start.addingTimeInterval(600)))
    let names = memory.index.concepts.map(\.name)
    print("   known:", names)
    check(names.contains { $0.contains("consistent hashing") }, "consistent hashing filed")
    check(names.contains { $0.contains("eventual consistency") }, "eventual consistency filed")
    check(memory.index.concepts.allSatisfy { !($0.cues ?? []).isEmpty }, "every idea got cues")
    let countAfterTwo = memory.conceptCount

    print("\n2. the same idea, two days later, worded differently")
    await memory.remember(LessonToRemember(
        question: "wait how does the hash ring deal with a new box being added", lessonTitle: "Adding Nodes to a Hash Ring",
        spokenAnswer: "the new server takes a spot on the ring and only claims the keys just before it, so almost every key stays where it was.",
        questionKind: "normal", answeredBy: "sonnet", date: start.addingTimeInterval(2 * day)))
    let hashing = memory.index.concepts.first { $0.name.contains("consistent hashing") }
    print("   known:", memory.index.concepts.map(\.name))
    check(hashing?.timesExplained == 2, "merged into the known idea, explained twice (got \(hashing?.timesExplained ?? 0))")
    check((hashing?.stabilityDays ?? 0) > ForgettingCurve.initialStabilityDays, "spaced re-explaining strengthened it (stability \(String(format: "%.1f", hashing?.stabilityDays ?? 0)) days)")
    check(hashing?.summary.contains("new") == true || hashing?.summary.contains("add") == true, "summary replaced by the latest explanation: \(hashing?.summary ?? "")")
    check(memory.conceptCount <= countAfterTwo + 1, "no duplicate idea (count \(memory.conceptCount))")

    print("\n3. the student did not follow the last lesson")
    let stabilityBefore = hashing?.stabilityDays ?? 0
    memory.studentGotLost()
    let lost = memory.index.concepts.first { $0.name.contains("consistent hashing") }
    check(lost?.timesLost == 1, "marked as not followed")
    check((lost?.stabilityDays ?? 99) < stabilityBefore, "memory estimate weakened")

    print("\n4. recall through the cascade")
    let describing = "so if i add one more server how many of the keys actually have to move"
    let found = await memory.startRecall(question: describing, windowTitle: "Excalidraw", questionVector: embed(describing)).value ?? []
    print("   recalled:", found.map(\.concept.name))
    check(found.first?.concept.name.contains("consistent hashing") == true, "a question describing it without its name finds it")
    let unrelated = "how do i center a div in css"
    let none = await memory.startRecall(question: unrelated, windowTitle: "Visual Studio Code", questionVector: embed(unrelated)).value ?? []
    check(none.isEmpty, "an unrelated question finds nothing (got \(none.map(\.concept.name)))")
    let byName = memory.namesOnlyRecall(question: "remind me what eventual consistency means", screenContext: "")
    check(byName.first?.concept.name.contains("eventual consistency") == true, "names-only fallback finds a named idea")

    print("\n5. the note the tutor gets")
    let note = LearningMemory.promptNote(for: found + byName)
    print(note.split(separator: "\n").map { "   " + $0 }.joined(separator: "\n"))
    check(note.contains("did not follow"), "note says they got lost last time")

    print("\n6. saving, a stale idea, and reloading")
    await memory.remember(LessonToRemember(
        question: "what is a bloom filter", lessonTitle: "Bloom Filters",
        spokenAnswer: "a bit array and a few hash functions. it can say definitely not present, or probably present.",
        questionKind: "normal", answeredBy: "argon", date: Date().addingTimeInterval(-200 * day)))
    await memory.flushWrites()
    let reloaded = LearningMemory(folder: storeFolder)
    configure(reloaded)
    await reloaded.load()
    let reloadedNames = reloaded.index.concepts.map(\.name)
    print("   after reload:", reloadedNames)
    check(!reloadedNames.contains { $0.contains("bloom") }, "met once, 200 days ago: archived, out of the live index")
    check(reloaded.index.concepts.contains { $0.name.contains("consistent hashing") && $0.timesLost == 1 }, "history survives a relaunch")
    check((0..<reloaded.conceptCount).allSatisfy { reloaded.index.vector(at: $0) != nil }, "vectors survive a relaunch")
    await reloaded.remember(LessonToRemember(
        question: "what was a bloom filter again", lessonTitle: "Bloom Filters",
        spokenAnswer: "a bit array with several hashes: definitely not there, or maybe there.",
        questionKind: "quick", answeredBy: "sonnet", date: Date()))
    let restored = reloaded.index.concepts.first { $0.name.contains("bloom") }
    check(restored?.timesExplained == 2, "coming up again restores it from the archive with its history (explained \(restored?.timesExplained ?? 0) times)")

    print("\n7. ideas filed before the sentence model existed, given vectors later")
    var index = ConceptIndex()
    let first = RememberedConcept(id: UUID(), name: "trie", aliases: [], cues: nil, summary: "a tree of characters",
                                  lastAngle: nil, firstExplainedAt: Date(), lastExplainedAt: Date(), timesExplained: 1,
                                  timesLost: 0, lastLostAt: nil, stabilityDays: 2, lessonTitles: [])
    var second = first
    second.id = UUID(); second.name = "heap"; second.summary = "smallest on top"
    index.upsert(first, vector: nil)
    index.upsert(second, vector: embed("heap: smallest on top"))
    index.setVector(embed("trie: a tree of characters")!, for: first.id)
    let shortlisted = index.candidates(questionText: "what's a trie", contextText: "", questionVector: embed("what's a trie"))
    check(index.vector(at: 0) != nil && index.vector(at: 1) != nil && shortlisted.first?.name == "trie",
          "vectors arriving late line up with their ideas, no crash")
    index.upsert(second, vector: [Float](repeating: 0.1, count: 3))
    check(index.vector(at: 1) != nil, "a vector of the wrong length is ignored, the old one kept")

    print("\n8. relations for the map, from the same filing call")
    await reloaded.remember(LessonToRemember(
        question: "why does each server get lots of spots on the hash ring", lessonTitle: "Virtual Nodes",
        spokenAnswer: "with one spot each, an unlucky server can own a huge arc of the ring. virtual nodes give every server many spots, so each one's share of the keys evens out, and a server leaving spreads its keys across all the others.",
        questionKind: "normal", answeredBy: "sonnet", date: Date()))
    let knownIDs = Set(reloaded.index.concepts.map(\.id))
    let hashingID = reloaded.index.concepts.first { $0.name.contains("consistent hashing") }?.id
    let virtualNodes = reloaded.index.concepts.first { $0.name.contains("virtual node") }
    print("   virtual nodes relations:", (virtualNodes?.relations ?? []).map { relation in
        "\(relation.kind) \(reloaded.index.concepts.first { $0.id == relation.targetID }?.name ?? "?")" })
    check(virtualNodes?.relations?.contains { $0.targetID == hashingID && ["part of", "uses"].contains($0.kind) } == true,
          "a new idea is linked to the known idea it belongs to")
    check(reloaded.index.concepts.allSatisfy { ($0.relations ?? []).allSatisfy { knownIDs.contains($0.targetID) } },
          "every relation points at a known idea")

    print("\n9. forgetting everything")
    reloaded.forgetEverything()
    await reloaded.flushWrites()
    check(reloaded.conceptCount == 0 && !FileManager.default.fileExists(atPath: storeFolder.path), "store and files gone")
    return failures
}.value
print(result == 0 ? "\nall checks passed" : "\n\(result) checks failed")
exit(result == 0 ? 0 : 1)
