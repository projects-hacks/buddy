//
//  KnowledgeMapLayout.swift
//  leanring-buddy
//
//  Where each idea sits on the map of what the student knows, and how
//  strongly it is still remembered. Pure (no files, no window, no clock of
//  its own) so the same ideas always give the same map, and so
//  scripts/knowledge_map can lay out fixtures and time it.
//
//  How it lays the map out, and why:
//
//  - Topics first. Ideas joined by a relation, or taught in the same lesson,
//    fall into one cluster (connected components). Each cluster is laid out
//    on its own, so a new idea changes the shape of its own topic only.
//    Other clusters keep their shape and may slide over to make room, which
//    the window animates rather than redrawing the map from scratch.
//  - Inside a cluster, a force layout (Fruchterman and Reingold): links pull,
//    every pair pushes. Starting points come from a hash of each idea's id,
//    never from a random generator, which is what makes it repeatable.
//    The cluster is then turned so its long side runs across the window.
//  - Ideas with no link yet sit together in a sunflower spiral, oldest in
//    the middle, rather than drifting off as lone dots.
//  - Then nothing may overlap: each idea is a box (its dot and its name),
//    and overlapping boxes are pushed apart along their shallower side.
//  - Clusters are packed outward from the middle on a coarse grid, largest
//    first and unlinked ideas last, so the main topics are what the window
//    opens on, and a cluster that grows a little leaves the others in place.
//

import CoreGraphics
import Foundation

/// How well an idea is probably still remembered, from FSRS, in the same
/// bands the tutor's note uses (LearningMemory.promptNote).
nonisolated enum KnowledgeMapStrength: Equatable {
    /// 85% or more: built on without a reminder.
    case solid
    /// 60 to 85%: a one-line reminder would help.
    case fading
    /// Under 60%: probably needs teaching again.
    case faded

    init(retrievability: Double) {
        if retrievability >= 0.85 {
            self = .solid
        } else if retrievability >= 0.6 {
            self = .fading
        } else {
            self = .faded
        }
    }

    var needsReview: Bool { self != .solid }
}

nonisolated struct KnowledgeMapNode: Identifiable, Equatable {
    let id: UUID
    let concept: RememberedConcept
    /// The dot's centre, in map points at zoom 1.
    var position: CGPoint
    let radius: CGFloat
    /// The name as drawn: long names are cut at a word so labels stay short.
    let displayName: String
    let retrievability: Double
    let strength: KnowledgeMapStrength
    /// Which colour of the palette its cluster wears, or nil for an idea with
    /// no links, which is drawn in the neutral ink.
    let colorIndex: Int?
    /// Links drawn to and from it, which decides whose name shows first when
    /// there is no room for all of them.
    let linkCount: Int

    /// How opaque it is drawn: solid ideas fully, fading ones less, faded
    /// ones faint but still findable.
    var opacity: Double {
        let progress = min(1, max(0, (retrievability - 0.3) / 0.6))
        let smoothed = progress * progress * (3 - 2 * progress)
        return 0.28 + 0.72 * smoothed
    }
}

nonisolated struct KnowledgeMapEdge: Identifiable, Equatable {
    let fromID: UUID
    let toID: UUID
    /// One of ConceptRelation.kinds, read as "from <kind> to".
    let kind: String
    var id: String { "\(fromID.uuidString)>\(toID.uuidString)" }
}

/// A cluster of three or more ideas, named after its most linked idea.
nonisolated struct KnowledgeMapTopic: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// Around its ideas' dots and names, in map points.
    let frame: CGRect
    let colorIndex: Int
}

nonisolated struct KnowledgeMapLayout: Equatable {
    let nodes: [KnowledgeMapNode]
    let edges: [KnowledgeMapEdge]
    let topics: [KnowledgeMapTopic]
    /// Around everything, in map points.
    let bounds: CGRect

    static let empty = KnowledgeMapLayout(nodes: [], edges: [], topics: [], bounds: .zero)

    /// How many colours the topic palette has; the view supplies them.
    static let paletteSize = 8
    /// Labels are drawn at a fixed size on screen; this is their height at
    /// zoom 1, used to keep names from overlapping.
    static let labelHeight: CGFloat = 16
    static let labelGap: CGFloat = 4

    /// The box an idea takes up, its dot and the name under it, which is what
    /// must not overlap another.
    static func box(around position: CGPoint, radius: CGFloat, labelWidth: CGFloat) -> CGRect {
        let width = max(2 * radius, labelWidth)
        let height = 2 * radius + labelGap + labelHeight
        return CGRect(x: position.x - width / 2, y: position.y - radius, width: width, height: height)
    }

    /// A rough width for a name at the label font, close enough to keep
    /// labels apart without measuring text off the main thread.
    static func estimatedLabelWidth(_ displayName: String) -> CGFloat {
        CGFloat(displayName.count) * 6.9 + 10
    }

    static func displayName(for name: String) -> String {
        let maximumCharacters = 28
        guard name.count > maximumCharacters else { return name }
        let cut = name.prefix(maximumCharacters)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord + "\u{2026}"
    }

    // MARK: - Making the layout

    /// The whole map for these ideas. Positions depend only on the ideas
    /// themselves; `now` only decides how faded each one is drawn.
    static func make(concepts: [RememberedConcept], now: Date) -> KnowledgeMapLayout {
        guard !concepts.isEmpty else { return .empty }
        // A stable order, whatever order the store keeps them in.
        let ordered = concepts.sorted { ($0.firstExplainedAt, $0.id.uuidString) < ($1.firstExplainedAt, $1.id.uuidString) }
        let positionByID = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })

        let edges = drawnEdges(ordered: ordered, positionByID: positionByID)
        var neighbours = [[(other: Int, weight: Double)]](repeating: [], count: ordered.count)
        var linkCounts = [Int](repeating: 0, count: ordered.count)
        for edge in edges {
            guard let from = positionByID[edge.fromID], let to = positionByID[edge.toID] else { continue }
            neighbours[from].append((to, 1.0))
            neighbours[to].append((from, 1.0))
            linkCounts[from] += 1
            linkCounts[to] += 1
        }
        // Taught in the same lesson is a weaker tie than a named relation.
        // A lesson shared by many ideas would knot them into one ball, so
        // only small ones count.
        var conceptsByLessonTitle: [String: [Int]] = [:]
        for (position, concept) in ordered.enumerated() {
            for title in Set(concept.lessonTitles.map { $0.lowercased() }) {
                conceptsByLessonTitle[title, default: []].append(position)
            }
        }
        for members in conceptsByLessonTitle.values.sorted(by: { $0.first ?? 0 < $1.first ?? 0 })
        where members.count >= 2 && members.count <= 6 {
            for first in members.indices {
                for second in members.indices where second > first {
                    let firstPosition = members[first], secondPosition = members[second]
                    guard !neighbours[firstPosition].contains(where: { $0.other == secondPosition }) else { continue }
                    neighbours[firstPosition].append((secondPosition, 0.5))
                    neighbours[secondPosition].append((firstPosition, 0.5))
                }
            }
        }

        // Bigger for ideas explained more often and for the ones others
        // hang off, so the heart of each topic stands out.
        let radii = ordered.indices.map { position -> CGFloat in
            let explained = Double(max(1, ordered[position].timesExplained))
            let links = Double(min(linkCounts[position], 5))
            return CGFloat(min(24, 10 + 3.5 * log2(explained) + 1.6 * links))
        }
        let displayNames = ordered.map { displayName(for: $0.name) }
        let labelWidths = displayNames.map(estimatedLabelWidth)

        // Clusters, each laid out on its own.
        let components = connectedComponents(count: ordered.count, neighbours: neighbours)
        var linkedBlocks: [LayoutBlock] = []
        var looseMembers: [Int] = []
        for members in components {
            if members.count == 1 {
                looseMembers.append(members[0])
                continue
            }
            var local = forceLayout(members: members, neighbours: neighbours, ordered: ordered)
            orientHorizontally(&local)
            separateOverlaps(&local, members: members, radii: radii, labelWidths: labelWidths)
            let hub = members.max { first, second in
                (linkCounts[first], ordered[first].timesExplained, -first)
                    < (linkCounts[second], ordered[second].timesExplained, -second)
            } ?? members[0]
            linkedBlocks.append(LayoutBlock(members: members, localPositions: local, hub: hub,
                                            hasTitle: members.count >= 3, title: ordered[hub].name))
        }
        var blocks = linkedBlocks
        if !looseMembers.isEmpty {
            var local = sunflower(members: looseMembers)
            separateOverlaps(&local, members: looseMembers, radii: radii, labelWidths: labelWidths)
            blocks.append(LayoutBlock(members: looseMembers, localPositions: local, hub: nil, hasTitle: false))
        }
        // Linked topics before the ideas with no link yet, so topics hold the
        // middle; then largest first, then the one begun earliest, which is
        // the same order every time for the same ideas.
        blocks.sort { first, second in
            (first.hub != nil ? 1 : 0, first.members.count, -(first.members.min() ?? 0))
                > (second.hub != nil ? 1 : 0, second.members.count, -(second.members.min() ?? 0))
        }

        let packedOffsets = packBlocks(blocks, radii: radii, labelWidths: labelWidths)
        let colorIndexes = blockColors(blocks, offsets: packedOffsets, ordered: ordered, radii: radii, labelWidths: labelWidths)

        var nodes: [KnowledgeMapNode] = []
        var topics: [KnowledgeMapTopic] = []
        var allBoxes = CGRect.null
        for (blockPosition, block) in blocks.enumerated() {
            let offset = packedOffsets[blockPosition]
            let colorIndex = colorIndexes[blockPosition]
            var blockBoxes = CGRect.null
            for (memberPosition, member) in block.members.enumerated() {
                let local = block.localPositions[memberPosition]
                let position = CGPoint(x: local.x + offset.x, y: local.y + offset.y)
                let concept = ordered[member]
                let elapsedDays = now.timeIntervalSince(concept.lastExplainedAt) / 86_400
                let retrievability = ForgettingCurve.retrievability(elapsedDays: elapsedDays, stabilityDays: concept.stabilityDays)
                nodes.append(KnowledgeMapNode(
                    id: concept.id, concept: concept, position: position, radius: radii[member],
                    displayName: displayNames[member], retrievability: retrievability,
                    strength: KnowledgeMapStrength(retrievability: retrievability),
                    colorIndex: colorIndex, linkCount: linkCounts[member]))
                blockBoxes = blockBoxes.union(box(around: position, radius: radii[member], labelWidth: labelWidths[member]))
            }
            allBoxes = allBoxes.union(blockBoxes)
            if block.hasTitle, let hub = block.hub, let colorIndex {
                let frame = blockBoxes.insetBy(dx: -18, dy: -14)
                topics.append(KnowledgeMapTopic(id: ordered[hub].id, title: ordered[hub].name, frame: frame, colorIndex: colorIndex))
                allBoxes = allBoxes.union(frame.insetBy(dx: 0, dy: -24))
            }
        }
        return KnowledgeMapLayout(nodes: nodes, edges: edges, topics: topics, bounds: allBoxes)
    }

    /// The relations worth a line: both ends on the map, each pair once
    /// (a relation stated from both sides keeps the one from the older idea).
    private static func drawnEdges(ordered: [RememberedConcept], positionByID: [UUID: Int]) -> [KnowledgeMapEdge] {
        var edges: [KnowledgeMapEdge] = []
        var linkedPairs: Set<Set<UUID>> = []
        for concept in ordered {
            for relation in concept.relations ?? []
            where relation.targetID != concept.id && positionByID[relation.targetID] != nil {
                let pair: Set<UUID> = [concept.id, relation.targetID]
                guard !linkedPairs.contains(pair) else { continue }
                linkedPairs.insert(pair)
                edges.append(KnowledgeMapEdge(fromID: concept.id, toID: relation.targetID, kind: relation.kind))
            }
        }
        return edges
    }

    private struct LayoutBlock {
        let members: [Int]
        var localPositions: [CGPoint]
        let hub: Int?
        let hasTitle: Bool
        var title: String = ""
    }

    /// Topic names are drawn in heavy capitals with wide letter spacing.
    static func estimatedTitleWidth(_ title: String) -> CGFloat {
        CGFloat(title.count) * 8.6 + 6
    }

    private static func connectedComponents(count: Int, neighbours: [[(other: Int, weight: Double)]]) -> [[Int]] {
        var componentOf = [Int](repeating: -1, count: count)
        var components: [[Int]] = []
        for start in 0..<count where componentOf[start] < 0 {
            var members: [Int] = []
            var stack = [start]
            componentOf[start] = components.count
            while let current = stack.popLast() {
                members.append(current)
                for neighbour in neighbours[current] where componentOf[neighbour.other] < 0 {
                    componentOf[neighbour.other] = components.count
                    stack.append(neighbour.other)
                }
            }
            components.append(members.sorted())
        }
        return components
    }

    /// A number in 0..<1 from an id, the same on every Mac and every run,
    /// unlike Swift's hashValue, which is seeded per process.
    static func stableFraction(of id: UUID, salt: UInt64) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ salt
        for byte in id.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // SplitMix64's finaliser, so nearby ids give far-apart numbers.
        hash = (hash ^ (hash >> 30)) &* 0xbf58_476d_1ce4_e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d0_49bb_1331_11eb
        hash ^= hash >> 31
        return Double(hash >> 11) / Double(1 << 53)
    }

    static func paletteIndex(for id: UUID) -> Int {
        Int(stableFraction(of: id, salt: 7) * Double(paletteSize)) % paletteSize
    }

    /// Each cluster's colour: the one its hub's id picks, unless a cluster
    /// already coloured nearby wears it, when the next free one. Two
    /// neighbouring topics in one colour would read as one topic.
    private static func blockColors(_ blocks: [LayoutBlock], offsets: [CGPoint], ordered: [RememberedConcept],
                                    radii: [CGFloat], labelWidths: [CGFloat]) -> [Int?] {
        var colors: [Int?] = []
        var colouredFootprints: [(rect: CGRect, color: Int)] = []
        for (blockPosition, block) in blocks.enumerated() {
            guard let hub = block.hub else {
                colors.append(nil)
                continue
            }
            var footprint = CGRect.null
            for (memberPosition, member) in block.members.enumerated() {
                let local = block.localPositions[memberPosition]
                let position = CGPoint(x: local.x + offsets[blockPosition].x, y: local.y + offsets[blockPosition].y)
                footprint = footprint.union(box(around: position, radius: radii[member], labelWidth: labelWidths[member]))
            }
            let nearby = footprint.insetBy(dx: -320, dy: -240)
            let takenNearby = Set(colouredFootprints.filter { $0.rect.intersects(nearby) }.map(\.color))
            let preferred = paletteIndex(for: ordered[hub].id)
            let color = (0..<paletteSize).map { (preferred + $0) % paletteSize }.first { !takenNearby.contains($0) } ?? preferred
            colors.append(color)
            colouredFootprints.append((footprint, color))
        }
        return colors
    }

    /// Fruchterman and Reingold within one cluster. Returns positions in the
    /// order of `members`, centred on zero.
    private static func forceLayout(members: [Int], neighbours: [[(other: Int, weight: Double)]],
                                    ordered: [RememberedConcept]) -> [CGPoint] {
        let count = members.count
        let idealDistance = 118.0
        var localIndexByMember: [Int: Int] = [:]
        for (localIndex, member) in members.enumerated() { localIndexByMember[member] = localIndex }
        var springs: [(first: Int, second: Int, weight: Double)] = []
        for (localIndex, member) in members.enumerated() {
            for neighbour in neighbours[member] {
                guard let other = localIndexByMember[neighbour.other], other > localIndex else { continue }
                springs.append((localIndex, other, neighbour.weight))
            }
        }

        let spread = idealDistance * sqrt(Double(count)) * 0.6
        var xs = [Double](repeating: 0, count: count)
        var ys = [Double](repeating: 0, count: count)
        for (localIndex, member) in members.enumerated() {
            let angle = stableFraction(of: ordered[member].id, salt: 1) * 2 * Double.pi
            let distance = sqrt(stableFraction(of: ordered[member].id, salt: 2)) * spread
            xs[localIndex] = cos(angle) * distance
            ys[localIndex] = sin(angle) * distance
        }

        let iterations = min(300, max(120, 60 + 3 * count))
        let startingTemperature = idealDistance * 1.5
        // Beyond this, two ideas no longer push each other, which keeps a
        // big cluster from blowing apart into a ring.
        let repulsionCutoffSquared = pow(idealDistance * 4, 2)
        var displacementX = [Double](repeating: 0, count: count)
        var displacementY = [Double](repeating: 0, count: count)
        for iteration in 0..<iterations {
            for index in 0..<count {
                displacementX[index] = 0
                displacementY[index] = 0
            }
            for first in 0..<count {
                for second in (first + 1)..<max(first + 1, count) {
                    var deltaX = xs[first] - xs[second]
                    var deltaY = ys[first] - ys[second]
                    var distanceSquared = deltaX * deltaX + deltaY * deltaY
                    if distanceSquared < 0.01 {
                        // Two ideas on one spot: nudge apart by index, not at random.
                        deltaX = Double(first - second) * 0.1
                        deltaY = 0.1
                        distanceSquared = deltaX * deltaX + deltaY * deltaY
                    }
                    guard distanceSquared < repulsionCutoffSquared else { continue }
                    let force = idealDistance * idealDistance / distanceSquared
                    displacementX[first] += deltaX * force
                    displacementY[first] += deltaY * force
                    displacementX[second] -= deltaX * force
                    displacementY[second] -= deltaY * force
                }
            }
            for spring in springs {
                let deltaX = xs[spring.first] - xs[spring.second]
                let deltaY = ys[spring.first] - ys[spring.second]
                let distance = max(0.1, sqrt(deltaX * deltaX + deltaY * deltaY))
                let force = distance * spring.weight / idealDistance
                displacementX[spring.first] -= deltaX * force
                displacementY[spring.first] -= deltaY * force
                displacementX[spring.second] += deltaX * force
                displacementY[spring.second] += deltaY * force
            }
            // A gentle pull to the middle keeps separate arms of a cluster
            // from drifting far apart.
            for index in 0..<count {
                displacementX[index] -= xs[index] * 0.03
                displacementY[index] -= ys[index] * 0.03
            }
            let temperature = startingTemperature * (1 - Double(iteration) / Double(iterations)) + 1
            for index in 0..<count {
                let length = sqrt(displacementX[index] * displacementX[index] + displacementY[index] * displacementY[index])
                guard length > 0 else { continue }
                let step = min(length, temperature)
                xs[index] += displacementX[index] / length * step
                ys[index] += displacementY[index] / length * step
            }
        }
        let meanX = xs.reduce(0, +) / Double(count)
        let meanY = ys.reduce(0, +) / Double(count)
        return (0..<count).map { CGPoint(x: xs[$0] - meanX, y: ys[$0] - meanY) }
    }

    /// Turns a cluster so its long side runs across the window, which is
    /// wider than it is tall, then flips it so its oldest idea is on the
    /// left: the same cluster always comes out the same way round.
    private static func orientHorizontally(_ positions: inout [CGPoint]) {
        guard positions.count >= 2 else { return }
        var covarianceXX = 0.0, covarianceYY = 0.0, covarianceXY = 0.0
        for point in positions {
            covarianceXX += Double(point.x * point.x)
            covarianceYY += Double(point.y * point.y)
            covarianceXY += Double(point.x * point.y)
        }
        let angle = 0.5 * atan2(2 * covarianceXY, covarianceXX - covarianceYY)
        let cosine = cos(-angle), sine = sin(-angle)
        positions = positions.map { point in
            CGPoint(x: Double(point.x) * cosine - Double(point.y) * sine,
                    y: Double(point.x) * sine + Double(point.y) * cosine)
        }
        // Positions follow the sorted members, and lower ones are older ideas.
        if let oldest = positions.first, oldest.x > 0 {
            positions = positions.map { CGPoint(x: -$0.x, y: $0.y) }
        }
        if let oldest = positions.first, oldest.y > 0 {
            positions = positions.map { CGPoint(x: $0.x, y: -$0.y) }
        }
    }

    /// Ideas with no links, oldest in the middle, on the golden-angle spiral
    /// sunflowers grow on, which spaces any number evenly.
    private static func sunflower(members: [Int]) -> [CGPoint] {
        let goldenAngle = Double.pi * (3 - sqrt(5))
        let spacing = 62.0
        return members.enumerated().map { offset, _ in
            let distance = spacing * sqrt(Double(offset))
            let angle = Double(offset) * goldenAngle
            // Wider than tall, like the window.
            return CGPoint(x: cos(angle) * distance * 1.35, y: sin(angle) * distance * 0.85)
        }
    }

    /// Pushes apart ideas whose boxes overlap, along the side that needs the
    /// shorter push, until none do or the passes run out.
    private static func separateOverlaps(_ positions: inout [CGPoint], members: [Int],
                                         radii: [CGFloat], labelWidths: [CGFloat]) {
        let horizontalGap: CGFloat = 12
        let verticalGap: CGFloat = 10
        let count = positions.count
        guard count >= 2 else { return }
        for _ in 0..<80 {
            var movedAny = false
            for first in 0..<count {
                for second in (first + 1)..<count {
                    let firstBox = box(around: positions[first], radius: radii[members[first]],
                                       labelWidth: labelWidths[members[first]])
                    let secondBox = box(around: positions[second], radius: radii[members[second]],
                                        labelWidth: labelWidths[members[second]])
                    let overlapX = min(firstBox.maxX, secondBox.maxX) - max(firstBox.minX, secondBox.minX) + horizontalGap
                    let overlapY = min(firstBox.maxY, secondBox.maxY) - max(firstBox.minY, secondBox.minY) + verticalGap
                    guard overlapX > 0, overlapY > 0 else { continue }
                    movedAny = true
                    // Vertical pushes are cheaper: labels are wide and short.
                    if overlapY < overlapX {
                        let direction: CGFloat = positions[first].y <= positions[second].y ? -1 : 1
                        positions[first].y += direction * overlapY / 2
                        positions[second].y -= direction * overlapY / 2
                    } else {
                        let direction: CGFloat = positions[first].x <= positions[second].x ? -1 : 1
                        positions[first].x += direction * overlapX / 2
                        positions[second].x -= direction * overlapX / 2
                    }
                }
            }
            if !movedAny { break }
        }
    }

    /// Where each cluster goes: the first in the middle, each next at the
    /// free spot nearest the middle (a little wider than tall, like the
    /// window). Spots are on a coarse grid, so a cluster that grows a little
    /// usually leaves the others exactly where they were. Returns an offset
    /// per block, in block order.
    private static func packBlocks(_ blocks: [LayoutBlock], radii: [CGFloat], labelWidths: [CGFloat]) -> [CGPoint] {
        let margin: CGFloat = 26
        let gridStep: CGFloat = 60
        let footprints = blocks.map { block -> CGRect in
            var localBounds = CGRect.null
            for (memberPosition, member) in block.members.enumerated() {
                localBounds = localBounds.union(box(around: block.localPositions[memberPosition],
                                                    radius: radii[member], labelWidth: labelWidths[member]))
            }
            // Room for the topic's name above it, which can be wider than
            // the cluster under it.
            let titleRoom: CGFloat = block.hasTitle ? 30 : 0
            let titleWidth = block.hasTitle ? estimatedTitleWidth(block.title) + 22 + margin : 0
            return CGRect(x: localBounds.minX - margin, y: localBounds.minY - margin - titleRoom,
                          width: max(localBounds.width + 2 * margin, titleWidth),
                          height: localBounds.height + 2 * margin + titleRoom)
        }
        let totalArea = footprints.reduce(0) { $0 + $1.width * $1.height }
        let largestSide = footprints.reduce(0) { max($0, $1.width, $1.height) }
        var reach = sqrt(totalArea) * 1.3 + largestSide

        func candidateSpots(within reach: CGFloat) -> [CGPoint] {
            let steps = Int(reach * 1.5 / gridStep) + 1
            var spots: [CGPoint] = []
            for column in -steps...steps {
                for row in -steps...steps {
                    spots.append(CGPoint(x: CGFloat(column) * gridStep, y: CGFloat(row) * gridStep))
                }
            }
            func closeness(_ spot: CGPoint) -> CGFloat { pow(spot.x / 1.5, 2) + pow(spot.y, 2) }
            return spots.filter { closeness($0) <= reach * reach }.sorted { first, second in
                let firstCloseness = closeness(first), secondCloseness = closeness(second)
                if firstCloseness != secondCloseness { return firstCloseness < secondCloseness }
                return atan2(first.y, first.x) < atan2(second.y, second.x)
            }
        }

        while true {
            let spots = candidateSpots(within: reach)
            var placedRectangles: [CGRect] = []
            var offsets: [CGPoint] = []
            for footprint in footprints {
                guard let spot = spots.first(where: { spot in
                    let candidate = footprint.offsetBy(dx: spot.x, dy: spot.y)
                    return !placedRectangles.contains { $0.intersects(candidate) }
                }) else { break }
                offsets.append(spot)
                placedRectangles.append(footprint.offsetBy(dx: spot.x, dy: spot.y))
            }
            if offsets.count == footprints.count { return offsets }
            reach *= 1.6
        }
    }
}
