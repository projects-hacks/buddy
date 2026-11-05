// Offline checks of the map of what the student knows, and pictures of it.
//
// Lays out the fixture memories (make_fixture.py) of 5, 40 and 300 ideas,
// checks the layout is the same every time and for any input order, that no
// two ideas' dots and names overlap, and how long it takes; checks that
// relations from Haiku are read strictly (no invented ids, no unknown kinds),
// that a store from before relations loads, and that the one-time relation
// pass makes one call per 20 ideas and never again; then renders the real
// map view to PNG in light and dark. No network, no real memory: every store
// is a copy in a scratch folder.
//
// build and run (from the repository root):
//   mkdir -p /tmp/map_check && cp scripts/knowledge_map/map_check.swift /tmp/map_check/main.swift
//   xcrun swiftc -O -parse-as-library -o /tmp/map_check/check leanring-buddy/ConceptIndex.swift \
//     leanring-buddy/LearningMemory.swift leanring-buddy/KnowledgeMapRelations.swift \
//     leanring-buddy/KnowledgeMapLayout.swift leanring-buddy/KnowledgeMapView.swift \
//     leanring-buddy/DesignSystem.swift /tmp/map_check/main.swift
//   /tmp/map_check/check scripts/knowledge_map /tmp/map_check/out

import AppKit
import SwiftUI

enum TutorDebugLog { static func write(_ line: String) { print("   log:", line) } }
// Never the app's own folder: every store here is passed a scratch folder.
enum AppIdentity { static let dataName = "Buddy-map-check" }

struct StoreFile: Codable {
    var version = 1
    var embeddingModel: String?
    var concepts: [RememberedConcept]
}

var failures = 0
func check(_ condition: Bool, _ description: String) {
    print(condition ? "PASS" : "FAIL", description)
    if !condition { failures += 1 }
}

let fixedNow = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!

func loadFixture(_ folder: URL, _ name: String) -> [RememberedConcept] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(StoreFile.self, from: Data(contentsOf: folder.appendingPathComponent(name))).concepts
}

func overlappingPairs(_ layout: KnowledgeMapLayout) -> Int {
    let boxes = layout.nodes.map {
        KnowledgeMapLayout.box(around: $0.position, radius: $0.radius,
                               labelWidth: KnowledgeMapLayout.estimatedLabelWidth($0.displayName))
    }
    var count = 0
    for first in boxes.indices {
        for second in boxes.indices where second > first && boxes[first].intersects(boxes[second]) { count += 1 }
    }
    return count
}

@MainActor
func render(_ model: KnowledgeMapModel, appearance: NSAppearance.Name, to file: URL, size: CGSize = CGSize(width: 1200, height: 780),
            prepare: (KnowledgeMapModel) -> Void = { _ in }) {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.appearance = NSAppearance(named: appearance)
    let hostingView = NSHostingView(rootView: KnowledgeMapView(model: model))
    hostingView.sizingOptions = []
    window.contentView = hostingView
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    prepare(model)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    hostingView.layoutSubtreeIfNeeded()
    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
    window.orderOut(nil)
    print("   wrote \(file.path)")
}

@main
struct MapCheck {
    @MainActor
    static func main() async {
        let fixtureFolder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/knowledge_map")
        let outputFolder = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : NSTemporaryDirectory() + "map_check")
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let fixtures = [5: loadFixture(fixtureFolder, "fixture_5.json"),
                        40: loadFixture(fixtureFolder, "fixture_40.json"),
                        300: loadFixture(fixtureFolder, "fixture_300.json")]

        print("\n1. layout: repeatable, no overlaps, quick")
        for size in [5, 40, 300] {
            let concepts = fixtures[size]!
            var timings: [Double] = []
            var layout = KnowledgeMapLayout.empty
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                layout = KnowledgeMapLayout.make(concepts: concepts, now: fixedNow)
                timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let again = KnowledgeMapLayout.make(concepts: concepts, now: fixedNow)
            var shuffled = concepts
            shuffled.reverse()
            shuffled.swapAt(0, shuffled.count / 2)
            let fromShuffled = KnowledgeMapLayout.make(concepts: shuffled, now: fixedNow)
            let positionsByID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.position) })
            let sameForAnyOrder = fromShuffled.nodes.allSatisfy { positionsByID[$0.id] == $0.position }
            let later = KnowledgeMapLayout.make(concepts: concepts, now: fixedNow.addingTimeInterval(30 * 86_400))
            let samePlacesLater = later.nodes.allSatisfy { positionsByID[$0.id] == $0.position }
            check(layout == again, "\(size) ideas: the same layout twice")
            check(sameForAnyOrder, "\(size) ideas: the same layout whatever order the store keeps them in")
            check(samePlacesLater, "\(size) ideas: a month later only the fading changes, not the places")
            check(overlappingPairs(layout) == 0, "\(size) ideas: no two ideas' dots and names overlap (\(overlappingPairs(layout)) pairs)")
            check(layout.nodes.count == concepts.count, "\(size) ideas: every idea drawn")
            let counts = Dictionary(grouping: layout.nodes, by: \.strength).mapValues(\.count)
            print(String(format: "   %d ideas, %d links, %d topics; %d remembered, %d review soon, %d fading out; layout %.1f ms (best of 3)",
                         layout.nodes.count, layout.edges.count, layout.topics.count,
                         counts[.solid] ?? 0, counts[.fading] ?? 0, counts[.faded] ?? 0, timings.min() ?? 0))
            print(String(format: "   map is %.0f by %.0f points at zoom 1", layout.bounds.width, layout.bounds.height))
        }
        // One new idea reshapes only its own topic; the others keep their shape.
        var withNewIdea = fixtures[40]!
        let hub = withNewIdea.first { $0.name == "event loop" }!
        var newIdea = hub
        newIdea.id = UUID()
        newIdea.name = "task queue"
        newIdea.firstExplainedAt = fixedNow
        newIdea.lastExplainedAt = fixedNow
        newIdea.relations = [ConceptRelation(kind: "part of", targetID: hub.id)]
        withNewIdea.append(newIdea)
        let before = KnowledgeMapLayout.make(concepts: fixtures[40]!, now: fixedNow)
        let after = KnowledgeMapLayout.make(concepts: withNewIdea, now: fixedNow)
        let beforeByID = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0.position) })
        let afterByID = Dictionary(uniqueKeysWithValues: after.nodes.map { ($0.id, $0.position) })
        var ownTopic: Set<UUID> = [hub.id]
        var grew = true
        while grew {
            grew = false
            for edge in after.edges where ownTopic.contains(edge.fromID) != ownTopic.contains(edge.toID) {
                ownTopic.formUnion([edge.fromID, edge.toID])
                grew = true
            }
        }
        let otherLinks = before.edges.filter { !ownTopic.contains($0.fromID) }
        let shapesKept = otherLinks.allSatisfy { edge in
            let beforeDelta = CGPoint(x: beforeByID[edge.toID]!.x - beforeByID[edge.fromID]!.x, y: beforeByID[edge.toID]!.y - beforeByID[edge.fromID]!.y)
            let afterDelta = CGPoint(x: afterByID[edge.toID]!.x - afterByID[edge.fromID]!.x, y: afterByID[edge.toID]!.y - afterByID[edge.fromID]!.y)
            return hypot(beforeDelta.x - afterDelta.x, beforeDelta.y - afterDelta.y) < 0.5
        }
        let slid = before.nodes.filter { !ownTopic.contains($0.id) && hypot(beforeByID[$0.id]!.x - afterByID[$0.id]!.x, beforeByID[$0.id]!.y - afterByID[$0.id]!.y) > 1 }
        check(shapesKept, "a new idea in one topic leaves every other topic's shape as it was (\(otherLinks.count) links compared)")
        print("   \(slid.count) of \(before.nodes.count - (ownTopic.count - 1)) ideas outside that topic slid over to make room, shape intact")

        print("\n2. relations are read strictly")
        let knownA = UUID(), knownB = UUID(), sameAs = UUID()
        let shortIDs = ["aaaa0001": knownA, "bbbb0002": knownB, "cccc0003": sameAs]
        let filed = ConceptRelationReading.filingRelations(in: [
            ["id": "AAAA0001", "how": "uses"],
            ["id": "deadbeef", "how": "uses"],
            ["id": "bbbb0002", "how": "is like"],
            ["id": "cccc0003", "how": "part of"],
            ["id": "aaaa0001", "how": "part of"],
            ["id": "bbbb0002", "how": "Contrasts With "]
        ], idsByShortID: shortIDs, sameAsID: sameAs)
        check(filed == [ConceptRelation(kind: "uses", targetID: knownA), ConceptRelation(kind: "contrasts with", targetID: knownB)],
              "filing: invented id, unknown kind, its own same_as and a second link to one idea all dropped")
        check(ConceptRelationReading.filingRelations(in: nil, idsByShortID: shortIDs, sameAsID: nil) == nil,
              "filing: a reply with no related list leaves the idea unasked (nil), not linked to nothing")
        let passReply = #"{"links":[{"from":"aaaa0001","to":"bbbb0002","how":"uses"},{"from":"bbbb0002","to":"aaaa0001","how":"part of"},{"from":"aaaa0001","to":"aaaa0001","how":"uses"},{"from":"aaaa0001","to":"99999999","how":"uses"},{"from":"cccc0003","to":"aaaa0001","how":"uses"}]}"#
        let passed = ConceptRelationReading.passLinks(in: passReply, idsByShortID: shortIDs, subjectIDs: [knownA, knownB])
        check(passed?[knownA] == [ConceptRelation(kind: "uses", targetID: knownB)] && passed?[knownB] == [],
              "pass: one link per pair, none to itself, none to an invented id, none from an idea not asked about")
        check(LearningMemory.mergedRelations(existing: [ConceptRelation(kind: "uses", targetID: knownA)],
                                             new: [ConceptRelation(kind: "part of", targetID: knownA), ConceptRelation(kind: "uses", targetID: knownB)],
                                             ownID: knownB) == [ConceptRelation(kind: "part of", targetID: knownA)],
              "merging: the newest kind for a link wins, and never a link to itself")

        print("\n3. a store from before relations, and the one-time pass")
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("map-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Written the way 1.5 wrote it: no relations key at all.
        var oldJSON = try! JSONSerialization.jsonObject(with: Data(contentsOf: fixtureFolder.appendingPathComponent("fixture_40.json"))) as! [String: Any]
        oldJSON["concepts"] = (oldJSON["concepts"] as! [[String: Any]]).map { concept in
            var concept = concept
            concept.removeValue(forKey: "relations")
            return concept
        }
        try! JSONSerialization.data(withJSONObject: oldJSON).write(to: scratch.appendingPathComponent("concepts.json"))
        let memory = LearningMemory(folder: scratch)
        await memory.load()
        check(memory.conceptCount == 40 && memory.index.concepts.allSatisfy { $0.relations == nil },
              "an older store loads, every idea with no relations on record (\(memory.conceptCount) ideas)")
        let defaults = UserDefaults(suiteName: "map-check-\(UUID().uuidString)")!
        var calls = 0
        var sentText = ""
        await KnowledgeMapRelationPass.runIfNeeded(memory: memory, defaults: defaults) { message in
            calls += 1
            sentText += message + "\n"
            // Links the first two ideas asked about, and tries an invented id.
            let lines = message.split(separator: "\n").filter { $0.contains(": ") }
            let ids = lines.prefix(2).map { String($0.split(separator: ":")[0]) }
            guard ids.count == 2 else { return #"{"links":[]}"# }
            return #"{"links":[{"from":"\#(ids[0])","to":"\#(ids[1])","how":"uses"},{"from":"\#(ids[0])","to":"0badf00d","how":"uses"}]}"#
        }
        check(calls == 2, "40 ideas: \(calls) calls, one per 20")
        let summaryByName = Dictionary(uniqueKeysWithValues: memory.index.concepts.map { ($0.name, $0.summary) })
        let sentLines = sentText.split(separator: "\n").filter { $0.contains(": ") }
        let onlyNamesAndSummaries = sentLines.allSatisfy { line in
            let parts = line.components(separatedBy: ": ")
            guard parts.count == 2 || parts.count == 3, let summary = summaryByName[parts[1]] else { return false }
            return parts.count == 2 || String(summary.prefix(200)) == parts[2]
        }
        check(!sentLines.isEmpty && onlyNamesAndSummaries, "the pass sends each idea's id, name and summary, nothing else")
        check(memory.index.concepts.allSatisfy { $0.relations != nil }, "every idea asked about now has relations on record")
        let validIDs = Set(memory.index.concepts.map(\.id))
        check(memory.index.concepts.allSatisfy { ($0.relations ?? []).allSatisfy { validIDs.contains($0.targetID) } },
              "no relation points at an id that is not a known idea")
        var callsAgain = 0
        await KnowledgeMapRelationPass.runIfNeeded(memory: memory, defaults: defaults) { _ in callsAgain += 1; return nil }
        check(callsAgain == 0, "opening the map again makes no call")

        let linked = memory.index.concepts.first { !($0.relations ?? []).isEmpty }!
        let target = linked.relations![0].targetID
        memory.forgetConcept(id: target)
        check(memory.index.index(of: target) == nil, "forgetting an idea removes it")
        check(memory.index.concepts.allSatisfy { ($0.relations ?? []).allSatisfy { $0.targetID != target } },
              "and every link to it")
        await memory.flushWrites()
        let reloaded = LearningMemory(folder: scratch)
        await reloaded.load()
        check(reloaded.conceptCount == 39 && reloaded.index.concepts.contains { !($0.relations ?? []).isEmpty },
              "relations and the forgetting survive a relaunch")
        try? FileManager.default.removeItem(at: scratch)

        print("\n4. pictures")
        let png = { (name: String) in outputFolder.appendingPathComponent(name) }
        for size in [5, 40, 300] {
            for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let model = KnowledgeMapModel()
                model.apply(KnowledgeMapLayout.make(concepts: fixtures[size]!, now: fixedNow), appearingIDs: [], animated: false)
                render(model, appearance: appearance, to: png("map-\(size)-\(label).png"))
            }
        }
        for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let model = KnowledgeMapModel()
            let layout = KnowledgeMapLayout.make(concepts: fixtures[40]!, now: fixedNow)
            model.apply(layout, appearingIDs: [], animated: false)
            render(model, appearance: appearance, to: png("map-40-selected-\(label).png")) { model in
                let hubNode = layout.nodes.first { $0.concept.name == "event loop" }!
                let other = layout.nodes.first { $0.concept.name == "cache invalidation" }!
                model.selectedID = hubNode.id
                model.hoveredID = other.id
            }
            let zoomedModel = KnowledgeMapModel()
            let bigLayout = KnowledgeMapLayout.make(concepts: fixtures[300]!, now: fixedNow)
            zoomedModel.apply(bigLayout, appearingIDs: [], animated: false)
            render(zoomedModel, appearance: appearance, to: png("map-300-zoomed-\(label).png")) { model in
                let hubNode = bigLayout.nodes.first { $0.concept.name == "http" }!
                model.zoom = 1
                model.panOffset = CGSize(width: -hubNode.position.x, height: -hubNode.position.y)
            }
            let searchModel = KnowledgeMapModel()
            searchModel.apply(bigLayout, appearingIDs: [], animated: false)
            render(searchModel, appearance: appearance, to: png("map-300-search-\(label).png")) { model in
                model.searchText = "hash"
            }
            let emptyModel = KnowledgeMapModel()
            emptyModel.apply(.empty, appearingIDs: [], animated: false)
            render(emptyModel, appearance: appearance, to: png("map-empty-\(label).png"))
        }

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
