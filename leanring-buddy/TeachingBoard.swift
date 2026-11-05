//
//  TeachingBoard.swift
//  leanring-buddy
//
//  The board's rules: an operation from the model goes in, the board's
//  state changes, and out come the exact strokes the page should draw.
//
//  This is the one place board state changes, and it does not touch the
//  screen, the network or the app, so the offline harness in scripts/board/
//  runs exactly this against real model answers.
//
//  The model never redraws. Adding an id that is already on the board
//  updates it instead, so even a model that forgets the rule cannot make a
//  second ring appear beside the first.
//

import Foundation

/// What the model can ask of the board, one call of the board API each.
enum BoardOperation: Equatable {
    case setTitle(String)
    case add(kind: BoardElement.Kind, identifier: String, text: String, listItems: [String],
             tableRows: [[String]], placement: BoardPlacementHint, tone: String?)
    case link(fromIdentifier: String, toIdentifier: String, label: String, isDashed: Bool, tone: String?)
    case unlink(fromIdentifier: String, toIdentifier: String)
    case update(identifier: String, value: BoardContentValue)
    case append(identifier: String, value: BoardContentValue)
    case moveIntoGroup(identifier: String, groupIdentifier: String)
    case highlight(identifier: String)
    case remove(identifier: String)
    /// Teach it back: something the student said is wrong. It is ringed in
    /// red and the correction is written beside it; what they said stays.
    case markWrong(identifier: String, correction: String)
    /// Teach it back: the ideas the student got right and missed, for
    /// learning memory. Draws nothing.
    case verdict(rightIdeas: [String], missedIdeas: [String])
}

/// Where the model would like something. Only a starting point for the search.
struct BoardPlacementHint: Equatable {
    var nearIdentifier: String?
    var side: BoardSide?
    var groupIdentifier: String?
    /// Set when the same sentence also links it to what it is near, so the
    /// two are kept far enough apart for the arrow and its label to read.
    var leavesRoomForArrow = false
}

/// New words for an element: text, a list's items, or a table's rows.
enum BoardContentValue: Equatable {
    case text(String)
    case items([String])
    case rows([[String]])
}

/// One thing for the page to draw, in board units. Read by
/// DrawingEngine/draw-board.js (BuddyBoard.apply).
struct BoardDrawCommand: Codable, Equatable {
    enum Action: String, Codable {
        /// The board's heading, above the drawing.
        case title
        /// Draw an element, or redraw one already there (`keepsShape` keeps
        /// its outline and rewrites only the words).
        case element
        /// Draw or redraw an arrow.
        case link
        case unlink
        /// Slide an element to `frame`, as drawn.
        case move
        /// A ring around something while it is being talked about.
        case highlight
        case remove
        /// Zoom or scroll the whole board.
        case viewport
        /// Teach it back: a red ring that stays around something the student
        /// said wrong, for as long as its correction stands. Its identifier
        /// is "ring:" and the correction's id, so removing one removes both.
        case ring
    }

    var action: Action
    var identifier: String?
    var kind: String?
    var text: String?
    var tone: String?
    var geometry: BoardElementGeometry?
    var keepsShape: Bool?
    var frame: BoardRect?
    var route: [BoardPoint]?
    var labelLines: [BoardTextLine]?
    var isDashed: Bool?
    var removedIdentifiers: [String]?
    var viewport: BoardViewport?
    /// For an arrow drawn as two stubs: the number on both tags, the stub
    /// arriving at the end, and where the tags are.
    var stubTag: Int?
    var arrivingRoute: [BoardPoint]?
    var tagFrames: [BoardRect]?
    /// Teach it back: "student" (purple, their words) or "gap" (red,
    /// dashed). Absent for Buddy's own pen.
    var ink: String?
}

/// Where everything sits on a screen, in the drawing canvas's pixels. The
/// canvas is the screen's size in points, so board units at full zoom are
/// points.
///
/// From the approved design (board mode): the whole display is paper, the
/// title and the current part sit top left under the notch's height, a
/// "Today's board" card lists the parts at top right, and one dark bar sits
/// bottom centre. The drawing area is what is left, so nothing drawn ever
/// goes under the title, the card or the bar.
struct BoardSurface: Equatable {
    let canvasWidth: Double
    let canvasHeight: Double
    let paper: BoardRect
    let content: BoardRect
    /// Top left of the board's title; the part's name is written under it.
    let titleOrigin: BoardPoint
    let partsCard: BoardRect
    /// The bottom bar's vertical band; it is centred and sized to its words
    /// by the page.
    let barBand: BoardRect

    static let sideMargin: Double = 56
    static let partsCardWidth: Double = 280

    init(canvasWidth: Double, canvasHeight: Double) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        paper = BoardRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        // Below the notch, which hangs about 90 points at most.
        titleOrigin = BoardPoint(x: Self.sideMargin, y: 112)
        partsCard = BoardRect(x: canvasWidth - Self.sideMargin - Self.partsCardWidth, y: 112,
                              width: Self.partsCardWidth, height: 0)
        barBand = BoardRect(x: 0, y: canvasHeight - 24 - 44, width: canvasWidth, height: 44)
        let contentTop = 200.0
        let contentBottom = barBand.y - 24
        content = BoardRect(x: Self.sideMargin, y: contentTop,
                            width: partsCard.x - 40 - Self.sideMargin,
                            height: contentBottom - contentTop)
    }

    var layout: BoardLayout {
        BoardLayout(boardWidth: content.width, visibleHeight: content.height)
    }

    /// The argument for BuddyBoard.open in draw-board.js.
    var openArgumentsJSON: String {
        "{\"paper\": [\(paper.x), \(paper.y), \(paper.width), \(paper.height)], "
            + "\"content\": [\(content.x), \(content.y), \(content.width), \(content.height)], "
            + "\"title\": [\(titleOrigin.x), \(titleOrigin.y)], "
            + "\"partsCard\": [\(partsCard.x), \(partsCard.y), \(partsCard.width)], "
            + "\"bar\": [\(barBand.y), \(barBand.height)]}"
    }
}

/// Where the board's own notes go: the app's log in the app, nowhere in
/// the offline harness. Kept here so this file needs nothing from the app.
enum TutorBoardLog {
    static var write: (String) -> Void = { _ in }
    static func note(_ line: String) { write("🧑‍🏫 board layout: " + line) }
}

final class TeachingBoard {
    private(set) var state = BoardState()
    let layout: BoardLayout
    /// Teach it back: the pen for everything added or linked from now on,
    /// the student's while their explanation is drawn and the gaps' while
    /// it is checked. Nil is Buddy's own pen, as on every other board.
    var inkForNewMarks: BoardInk?
    /// Calls that could not be carried out, for the log.
    private(set) var warnings: [String] = []
    /// The top-level element drawn last, where the next unanchored one goes beside.
    private var lastTopLevelIdentifier: String?
    /// What this turn has drawn or pointed at, by id, so the view can be
    /// found again after a closing-up has moved things.
    private var thisTurnIdentifiers: Set<String> = []
    /// What this turn added: when not everything fits, the view keeps the
    /// new parts in sight rather than an old one that was only pointed at.
    private var thisTurnAddedIdentifiers: Set<String> = []

    init(layout: BoardLayout) {
        self.layout = layout
    }

    /// A board restored from a saved state, for replaying a lesson.
    init(layout: BoardLayout, restoring savedState: BoardState) {
        self.layout = layout
        self.state = savedState
        self.lastTopLevelIdentifier = savedState.elements.last { $0.groupIdentifier == nil }?.identifier
    }

    func beginTurn() {
        state.currentTurn += 1
        thisTurnIdentifiers = []
        thisTurnAddedIdentifiers = []
        gapIdentifierReplacements = [:]
        gapMarksThisTurn = 0
        // Between turns is the moment to close up empty bands left by
        // rubbed-out parts. Done at the turn's first board call, so the
        // slide is drawn with the first sentence, and never at all in a turn
        // that draws nothing.
        compactsAtTheTurnsFirstChange = true
    }

    private var compactsAtTheTurnsFirstChange = false

    /// When the board no longer fits the paper at full size, empty
    /// horizontal bands (left by rubbed-out parts, or by a row that moved)
    /// are closed up: everything below a band slides up together, so the
    /// drawing keeps its shape and nothing changes its place relative to its
    /// neighbours. This is the only time older parts move.
    private func compactEmptyBands() -> [BoardDrawCommand] {
        guard let bounds = state.contentBounds, bounds.maxY + 16 > layout.visibleHeight else { return [] }
        // The vertical extent of everything that has a place of its own;
        // arrows are re-routed afterwards, so they do not hold bands open.
        var occupied: [(top: Double, bottom: Double)] = state.elements
            .filter { $0.groupIdentifier == nil }
            .map { ($0.frame.minY, $0.frame.maxY) }
        occupied += state.connectors.compactMap(\.labelFrame).map { ($0.minY, $0.maxY) }
        occupied.sort { $0.top < $1.top }
        guard !occupied.isEmpty else { return [] }

        // How far each band's content moves up: the sum of the excess of
        // every gap above it.
        var shifts: [(fromY: Double, by: Double)] = []
        var totalShift = max(0, occupied[0].top)
        if totalShift > 0 { shifts.append((occupied[0].top, totalShift)) }
        var reachedBottom = occupied[0].bottom
        for interval in occupied.dropFirst() {
            if interval.top > reachedBottom + BoardLayout.gapBetweenElements * 2 {
                totalShift += interval.top - reachedBottom - BoardLayout.gapBetweenElements
                shifts.append((interval.top, totalShift))
            }
            reachedBottom = max(reachedBottom, interval.bottom)
        }
        guard !shifts.isEmpty else { return [] }
        func shift(forTop top: Double) -> Double {
            shifts.last { $0.fromY <= top + 0.5 }?.by ?? 0
        }

        var commands: [BoardDrawCommand] = []
        var movedIdentifiers: [String] = []
        for element in state.elements where element.groupIdentifier == nil {
            let distance = shift(forTop: element.frame.minY)
            guard distance > 0.5 else { continue }
            var moving = [element] + state.members(ofGroup: element.identifier)
            for index in moving.indices {
                moving[index].frame = moving[index].frame.offsetBy(dx: 0, dy: -distance)
                state.replace(moving[index])
                commands.append(BoardDrawCommand(action: .move, identifier: moving[index].identifier, frame: moving[index].frame))
                movedIdentifiers.append(moving[index].identifier)
            }
        }
        // Labels are placed again with their arrows.
        for var connector in state.connectors {
            connector.labelFrame = nil
            state.replace(connector)
        }
        commands += rerouteConnectors(touching: state.elements.map(\.identifier))
        TutorBoardLog.note("closed \(shifts.count) empty bands, moved \(movedIdentifiers.count) elements up")
        return commands
    }

    /// What the view should keep in sight: everything this turn touched if
    /// that fits at the smallest zoom, else everything it added, else the
    /// last thing it added, else the change just made.
    private func focusForThisTurn(lastChange: BoardRect?) -> BoardRect? {
        let fitsHeight = layout.visibleHeight / layout.minimumScale - 48
        func union(of identifiers: Set<String>) -> BoardRect? {
            let frames = state.elements.filter { identifiers.contains($0.identifier) }.map(\.frame)
            return frames.dropFirst().reduce(frames.first) { result, frame in result?.union(frame) }
        }
        if let touched = union(of: thisTurnIdentifiers), touched.height <= fitsHeight { return touched }
        if let added = union(of: thisTurnAddedIdentifiers), added.height <= fitsHeight { return added }
        if let lastAdded = state.elements.last(where: { thisTurnAddedIdentifiers.contains($0.identifier) })?.frame {
            return lastAdded
        }
        return lastChange
    }

    func takeWarnings() -> [String] {
        defer { warnings = [] }
        return warnings
    }

    // MARK: - Applying operations

    /// Carries out one operation and returns what to draw, in order. A
    /// zoom or scroll the change needs comes first, so the new part is drawn
    /// where the student can already see it.
    func apply(_ operation: BoardOperation) -> [BoardDrawCommand] {
        // Teach it back: the check marks the student's drawing and never
        // changes it, whatever the model writes.
        guard let operation = operationAllowedInGapCheck(operation) else { return [] }
        // Before this turn's first change is placed, so it lands on the
        // closed-up board.
        var compaction: [BoardDrawCommand] = []
        if compactsAtTheTurnsFirstChange {
            compactsAtTheTurnsFirstChange = false
            compaction = compactEmptyBands()
        }
        var commands = compaction + applyOperation(operation)
        // A change that would make the view scroll closes up empty bands
        // first, if there are any: scrolling hides part of the lesson.
        if let bounds = state.contentBounds, bounds.maxY + 16 > layout.visibleHeight / layout.minimumScale {
            let closingUp = compactEmptyBands()
            if !closingUp.isEmpty {
                commands += closingUp
                let newViewport = layout.viewport(for: state, showing: focusForThisTurn(lastChange: nil), previous: state.viewport)
                if newViewport != state.viewport {
                    state.viewport = newViewport
                    commands.append(BoardDrawCommand(action: .viewport, viewport: newViewport))
                }
            }
        }
        return commands
    }

    private func applyOperation(_ operation: BoardOperation) -> [BoardDrawCommand] {
        var commands: [BoardDrawCommand] = []
        switch operation {
        case .add(_, let identifier, _, _, _, _, _):
            thisTurnIdentifiers.insert(identifier)
            thisTurnAddedIdentifiers.insert(identifier)
        case .update(let identifier, _), .append(let identifier, _),
             .moveIntoGroup(let identifier, _), .highlight(let identifier):
            thisTurnIdentifiers.insert(identifier)
        case .link(let fromIdentifier, let toIdentifier, _, _, _):
            thisTurnIdentifiers.formUnion([fromIdentifier, toIdentifier])
        default:
            break
        }
        var focus: BoardRect?

        switch operation {
        case .setTitle(let title):
            state.title = title
            commands.append(BoardDrawCommand(action: .title, text: title))

        case let .add(kind, identifier, text, listItems, tableRows, placement, tone):
            if state.element(identifier) != nil {
                warnings.append("board.\(kind.rawValue)(\"\(identifier)\") is already on the board: updated instead")
                let value: BoardContentValue = kind == .list && !listItems.isEmpty ? .items(listItems)
                    : kind == .table && !tableRows.isEmpty ? .rows(tableRows) : .text(text)
                return apply(.update(identifier: identifier, value: value))
            }
            let (addCommands, placedFrame) = add(kind: kind, identifier: identifier, text: text, listItems: listItems,
                                                 tableRows: tableRows, placement: placement, tone: tone)
            commands += addCommands
            focus = placedFrame

        case let .link(fromIdentifier, toIdentifier, label, isDashed, tone):
            guard let fromElement = state.element(fromIdentifier), let toElement = state.element(toIdentifier) else {
                warnings.append("board.link(\"\(fromIdentifier)\", \"\(toIdentifier)\") names something not on the board")
                return []
            }
            guard fromIdentifier != toIdentifier else { return [] }
            let existing = state.connector(from: fromIdentifier, to: toIdentifier)
            if existing == nil { commands += bringNewEndCloser(fromIdentifier: fromIdentifier, toIdentifier: toIdentifier) }
            var connector = existing ?? BoardConnector(
                fromIdentifier: fromIdentifier, toIdentifier: toIdentifier, label: label, isDashed: isDashed,
                tone: tone, routePoints: [], labelFrame: nil, addedInTurn: state.currentTurn)
            connector.label = label.isEmpty ? connector.label : label
            connector.isDashed = isDashed
            connector.tone = tone ?? connector.tone
            if existing == nil {
                connector.ink = inkForNewMarks
                state.insert(connector)
            }
            commands.append(routeAndDraw(&connector))
            focus = fromElement.frame.union(toElement.frame)

        case let .unlink(fromIdentifier, toIdentifier):
            guard state.connector(from: fromIdentifier, to: toIdentifier) != nil else { return [] }
            state.removeConnector(from: fromIdentifier, to: toIdentifier)
            let arrowIdentifier = BoardConnector.identifier(from: fromIdentifier, to: toIdentifier)
            commands.append(BoardDrawCommand(action: .unlink, identifier: arrowIdentifier))
            // Teach it back: an arrow said again differently loses the
            // correction that was about the old one.
            let corrections = state.elements.filter { $0.correctsIdentifier == arrowIdentifier }.map(\.identifier)
            for correction in corrections { state.removeElement(correction) }
            if !corrections.isEmpty {
                commands.append(BoardDrawCommand(action: .remove, removedIdentifiers: corrections + corrections.map { "ring:\($0)" }))
            }

        case let .update(identifier, value):
            guard var element = state.element(identifier) else {
                warnings.append("board.update(\"\(identifier)\") names something not on the board")
                return []
            }
            switch value {
            case .text(let newText): element.text = newText
            case .items(let newItems):
                if element.kind == .list { element.listItems = newItems } else { element.text = newItems.joined(separator: ", ") }
            case .rows(let newRows):
                if element.kind == .table { element.tableRows = newRows } else { element.text = newRows.map { $0.joined(separator: " ") }.joined(separator: ", ") }
            }
            commands += resize(element)
            focus = state.element(identifier)?.frame

        case let .append(identifier, value):
            guard var element = state.element(identifier) else {
                warnings.append("board.append(\"\(identifier)\") names something not on the board")
                return []
            }
            switch (element.kind, value) {
            case (.list, .text(let item)): element.listItems.append(item)
            case (.list, .items(let items)): element.listItems += items
            case (.table, .items(let row)): element.tableRows.append(row)
            case (.table, .rows(let rows)): element.tableRows += rows
            case (.table, .text(let cell)): element.tableRows.append([cell])
            case (_, .text(let words)): element.text += " " + words
            default:
                warnings.append("board.append(\"\(identifier)\") does not fit a \(element.kind.rawValue)")
                return []
            }
            commands += resize(element)
            focus = state.element(identifier)?.frame

        case let .moveIntoGroup(identifier, groupIdentifier):
            guard var element = state.element(identifier), let group = state.element(groupIdentifier),
                  group.kind == .group, element.kind != .group, element.groupIdentifier != groupIdentifier else {
                warnings.append("board.move(\"\(identifier)\", \"\(groupIdentifier)\") cannot be done")
                return []
            }
            let (groupCommands, memberFrame) = makeRoomInGroup(groupIdentifier, width: element.frame.width,
                                                                height: element.frame.height, excluding: identifier)
            commands += groupCommands
            element.groupIdentifier = groupIdentifier
            element.frame = memberFrame
            element.lastChangedInTurn = state.currentTurn
            state.replace(element)
            if lastTopLevelIdentifier == identifier { lastTopLevelIdentifier = groupIdentifier }
            commands.append(BoardDrawCommand(action: .move, identifier: identifier, frame: memberFrame))
            commands += rerouteConnectors(touching: [identifier])
            focus = state.element(groupIdentifier)?.frame

        case .highlight(let identifier):
            if let element = state.element(identifier) {
                commands.append(BoardDrawCommand(action: .highlight, identifier: identifier, frame: element.frame))
                focus = element.frame
            } else if let connector = connectorNamed(identifier), let labelFrame = connector.labelFrame {
                commands.append(BoardDrawCommand(action: .highlight, identifier: identifier, frame: labelFrame))
                focus = labelFrame
            } else {
                warnings.append("board.highlight(\"\(identifier)\") names something not on the board")
            }

        case .remove(let identifier):
            if let connector = connectorNamed(identifier) {
                return apply(.unlink(fromIdentifier: connector.fromIdentifier, toIdentifier: connector.toIdentifier))
            }
            guard let element = state.element(identifier) else { return [] }
            var removedElements = [identifier]
            if element.kind == .group { removedElements += state.members(ofGroup: identifier).map(\.identifier) }
            var removedConnectors: [String] = []
            for removedIdentifier in removedElements {
                removedConnectors += state.connectors(touching: removedIdentifier).map(\.identifier)
                state.removeElement(removedIdentifier)
            }
            if let lastTopLevelIdentifier, removedElements.contains(lastTopLevelIdentifier) {
                self.lastTopLevelIdentifier = state.elements.last { $0.groupIdentifier == nil }?.identifier
            }
            // A correction takes its red ring with it, and an element that
            // goes takes the corrections of it.
            var removedRings = [element].filter { $0.correctsIdentifier != nil }.map { "ring:\($0.identifier)" }
            for correction in state.elements where correction.correctsIdentifier.map({ removedElements.contains($0) || removedConnectors.contains($0) }) == true {
                removedRings.append("ring:\(correction.identifier)")
                removedElements.append(correction.identifier)
                state.removeElement(correction.identifier)
            }
            commands.append(BoardDrawCommand(action: .remove, removedIdentifiers: removedElements + Array(Set(removedConnectors)).sorted() + removedRings))
            // A group that lost a member closes up around the rest, from its
            // top left, so it moves nothing and leaves no empty frame.
            if let groupIdentifier = element.groupIdentifier, var group = state.element(groupIdentifier) {
                let remaining = state.members(ofGroup: groupIdentifier)
                let minimum = layout.naturalSize(of: group)
                var fitted = BoardRect(x: group.frame.x, y: group.frame.y, width: minimum.width, height: minimum.height)
                for member in remaining { fitted = fitted.union(member.frame.insetBy(-BoardLayout.groupPadding)) }
                if fitted.width < group.frame.width - 1 || fitted.height < group.frame.height - 1 {
                    group.frame = BoardRect(x: group.frame.x, y: group.frame.y,
                                            width: min(group.frame.width, fitted.maxX - group.frame.x),
                                            height: min(group.frame.height, fitted.maxY - group.frame.y))
                    state.replace(group)
                    commands.append(drawCommand(for: group, keepsShape: false))
                    commands += rerouteConnectors(touching: [groupIdentifier])
                }
            }

        case let .markWrong(identifier, correction):
            // What is wrong is ringed where it is; the correction goes beside
            // it as words in the gap's pen, placed like any element so it
            // covers nothing the student said.
            let targetFrame: BoardRect
            let nearIdentifier: String
            if let element = state.element(identifier) {
                targetFrame = element.frame
                nearIdentifier = identifier
            } else if let connector = connectorNamed(identifier) {
                let routeBounds = (connector.routePoints + (connector.targetStubPoints ?? [])).reduce(nil as BoardRect?) { bounds, point in
                    let pointRect = BoardRect(x: point.x, y: point.y, width: 0, height: 0)
                    return bounds.map { $0.union(pointRect) } ?? pointRect
                }
                guard let ringed = connector.labelFrame ?? routeBounds else { return [] }
                targetFrame = ringed
                nearIdentifier = connector.toIdentifier
            } else {
                warnings.append("board.wrong(\"\(identifier)\") names something not on the board")
                return []
            }
            let correctionIdentifier = "fix-" + identifier.replacingOccurrences(of: ">", with: "-")
            if state.element(correctionIdentifier) != nil {
                return apply(.update(identifier: correctionIdentifier, value: .text(correction)))
            }
            let (addCommands, placedFrame) = add(kind: .label, identifier: correctionIdentifier, text: correction,
                                                 listItems: [], tableRows: [],
                                                 placement: BoardPlacementHint(nearIdentifier: nearIdentifier, side: nil, groupIdentifier: nil),
                                                 tone: nil, ink: .gap, correctsIdentifier: identifier)
            commands.append(BoardDrawCommand(action: .ring, identifier: "ring:\(correctionIdentifier)", frame: targetFrame,
                                             ink: BoardInk.gap.rawValue))
            commands += addCommands
            focus = targetFrame.union(placedFrame)

        case .verdict:
            return []
        }

        // The whole turn in view when it fits at the smallest zoom, else
        // the part just drawn.
        let newViewport = layout.viewport(for: state, showing: focusForThisTurn(lastChange: focus), previous: state.viewport)
        if newViewport != state.viewport {
            state.viewport = newViewport
            commands.insert(BoardDrawCommand(action: .viewport, viewport: newViewport), at: 0)
        }
        return commands
    }

    /// Everything on the board, to draw it again from nothing: after the
    /// page reloads, or to show a saved board.
    func commandsToRedrawEverything() -> [BoardDrawCommand] {
        var commands: [BoardDrawCommand] = [BoardDrawCommand(action: .viewport, viewport: state.viewport)]
        if !state.title.isEmpty { commands.append(BoardDrawCommand(action: .title, text: state.title)) }
        for element in state.elements { commands.append(drawCommand(for: element, keepsShape: false)) }
        for connector in state.connectors { commands.append(linkCommand(for: connector)) }
        return commands
    }

    // MARK: - Adding

    private func add(kind: BoardElement.Kind, identifier: String, text: String, listItems: [String],
                     tableRows: [[String]], placement: BoardPlacementHint, tone: String?,
                     ink: BoardInk? = nil, correctsIdentifier: String? = nil) -> ([BoardDrawCommand], BoardRect) {
        var element = BoardElement(identifier: identifier, kind: kind, text: text, listItems: listItems,
                                   tableRows: tableRows, groupIdentifier: nil, tone: tone,
                                   frame: BoardRect(x: 0, y: 0, width: 0, height: 0),
                                   addedInTurn: state.currentTurn, lastChangedInTurn: state.currentTurn,
                                   ink: ink ?? inkForNewMarks, correctsIdentifier: correctsIdentifier)
        let size = layout.naturalSize(of: element)
        var commands: [BoardDrawCommand] = []

        if kind != .group, let groupIdentifier = placement.groupIdentifier,
           let group = state.element(groupIdentifier), group.kind == .group {
            let (groupCommands, memberFrame) = makeRoomInGroup(groupIdentifier, width: size.width, height: size.height, excluding: nil)
            commands += groupCommands
            element.groupIdentifier = groupIdentifier
            element.frame = memberFrame
        } else {
            if placement.groupIdentifier != nil {
                warnings.append("board.\(kind.rawValue)(\"\(identifier)\") asked for a group that is not on the board")
            }
            element.frame = topLevelSpot(width: size.width, height: size.height, placement: placement,
                                         startsOnNewRow: kind == .group)
            lastTopLevelIdentifier = identifier
        }
        state.insert(element)
        commands.append(drawCommand(for: element, keepsShape: false))
        return (commands, element.frame)
    }

    /// Beside what it was asked to be near, else to the right of the last
    /// thing drawn, else a new row underneath everything. A group with no
    /// hint starts a row of its own, at the left, so it has the board's whole
    /// width to grow into as members join.
    private func topLevelSpot(width: Double, height: Double, placement: BoardPlacementHint,
                              startsOnNewRow: Bool = false) -> BoardRect {
        if let nearIdentifier = placement.nearIdentifier, let nearElement = state.element(nearIdentifier) {
            // Beside a group's member from outside the group means beside the group.
            let anchorFrame = nearElement.groupIdentifier.flatMap { state.element($0)?.frame } ?? nearElement.frame
            return layout.findFreeSpot(width: width, height: height, in: state, near: anchorFrame,
                                       preferredSide: placement.side,
                                       extraSpacing: placement.leavesRoomForArrow ? 110 : 0)
        }
        if state.elements.isEmpty {
            return BoardRect(x: 0, y: 0, width: width, height: height)
        }
        // Beside the last thing drawn, if that is on the paper as it shows
        // now; else the first hole on that paper; else a new row, if the
        // smallest zoom still shows it; and only then wherever there is room.
        let tiers = layout.roomTiers(for: state)
        let besideLast = lastTopLevelIdentifier.flatMap { state.element($0) }.map { last in
            BoardRect(x: last.frame.maxX + BoardLayout.gapBetweenElements, y: last.frame.minY, width: width, height: height)
        }
        let underEverything = BoardRect(x: 0, y: (state.contentBounds?.maxY ?? 0) + BoardLayout.gapBetweenElements,
                                        width: width, height: height)
        for room in tiers.prefix(2) {
            if !startsOnNewRow, let besideLast, room.contains(besideLast),
               layout.isFree(besideLast, in: state, ignoring: [], avoidingArrows: true) { return besideLast }
            if startsOnNewRow, room.contains(underEverything),
               layout.isFree(underEverything, in: state, ignoring: [], avoidingArrows: true) { return underEverything }
            if let hole = layout.firstFreeSpotInReadingOrder(width: width, height: height, in: state, within: room) { return hole }
            if room.contains(underEverything), layout.isFree(underEverything, in: state, ignoring: [], avoidingArrows: true) {
                return underEverything
            }
        }
        return layout.findFreeSpot(width: width, height: height, in: state, near: nil, preferredSide: nil)
    }

    /// A spot for a member of `groupIdentifier`, growing the group into free
    /// space if it is full, and as a last resort sliding the whole group to
    /// somewhere with room. Returns the redraws that needs, then the spot.
    private func makeRoomInGroup(_ groupIdentifier: String, width: Double, height: Double,
                                 excluding movingIdentifier: String?) -> ([BoardDrawCommand], BoardRect) {
        guard var group = state.element(groupIdentifier) else { return ([], BoardRect(x: 0, y: 0, width: width, height: height)) }
        if let spot = layout.spotInGroup(group, width: width, height: height, in: state, excluding: movingIdentifier) {
            var commands: [BoardDrawCommand] = []
            if spot.groupFrame != group.frame {
                group.frame = spot.groupFrame
                state.replace(group)
                commands.append(drawCommand(for: group, keepsShape: false))
                commands += rerouteConnectors(touching: [groupIdentifier])
            }
            return (commands, spot.member)
        }

        // No room where it is: the group and its members slide together to
        // a place big enough for one more row.
        let members = state.members(ofGroup: groupIdentifier).filter { $0.identifier != movingIdentifier }
        let lowestMemberBottom = members.map(\.frame.maxY).max() ?? (group.frame.y + BoardLayout.groupTitleBand)
        let newRowSpot = BoardRect(x: group.frame.x + BoardLayout.groupPadding,
                                   y: lowestMemberBottom + BoardLayout.gapInsideGroup, width: width, height: height)
        let grownFrame = group.frame.union(newRowSpot.insetBy(-BoardLayout.groupPadding))
        var ignored = Set(members.map(\.identifier))
        ignored.insert(groupIdentifier)
        if let movingIdentifier { ignored.insert(movingIdentifier) }
        let destination = layout.findFreeSpot(width: grownFrame.width, height: grownFrame.height, in: state,
                                              near: group.frame, preferredSide: .below, ignoring: ignored)
        let deltaX = destination.x - grownFrame.x, deltaY = destination.y - grownFrame.y
        var commands: [BoardDrawCommand] = []
        group.frame = grownFrame.offsetBy(dx: deltaX, dy: deltaY)
        state.replace(group)
        commands.append(drawCommand(for: group, keepsShape: false))
        for var member in members {
            member.frame = member.frame.offsetBy(dx: deltaX, dy: deltaY)
            state.replace(member)
            commands.append(BoardDrawCommand(action: .move, identifier: member.identifier, frame: member.frame))
        }
        commands += rerouteConnectors(touching: [groupIdentifier] + members.map(\.identifier))
        return (commands, newRowSpot.offsetBy(dx: deltaX, dy: deltaY))
    }

    // MARK: - Changing words

    /// New words may need a different size. The element keeps its place
    /// when the new size is free there, and finds the nearest free place
    /// otherwise; its outline is kept when the size did not change at all.
    private func resize(_ changedElement: BoardElement) -> [BoardDrawCommand] {
        var element = changedElement
        element.lastChangedInTurn = state.currentTurn
        let size = layout.naturalSize(of: element)
        let isSameSize = abs(size.width - element.frame.width) < 0.5 && abs(size.height - element.frame.height) < 0.5
        if isSameSize || element.kind == .group {
            state.replace(element)
            return [drawCommand(for: element, keepsShape: true)]
        }

        var commands: [BoardDrawCommand] = []
        let inPlace = BoardRect(x: element.frame.x, y: element.frame.y, width: size.width, height: size.height)
        if let groupIdentifier = element.groupIdentifier, let group = state.element(groupIdentifier) {
            let otherMembers = state.members(ofGroup: groupIdentifier).filter { $0.identifier != element.identifier }
            let clearOfMembers = !otherMembers.contains { inPlace.insetBy(-BoardLayout.gapInsideGroup / 2).intersects($0.frame) }
            let grownGroup = group.frame.union(inPlace.insetBy(-BoardLayout.groupPadding))
            var ignored = Set(otherMembers.map(\.identifier))
            ignored.insert(groupIdentifier)
            ignored.insert(element.identifier)
            if clearOfMembers && (group.frame.contains(inPlace) || layout.isFree(grownGroup, in: state, ignoring: ignored, avoidingArrows: false)) {
                element.frame = inPlace
                if grownGroup != group.frame {
                    var grown = group
                    grown.frame = grownGroup
                    state.replace(grown)
                    commands.append(drawCommand(for: grown, keepsShape: false))
                }
            } else {
                let (groupCommands, spot) = makeRoomInGroup(groupIdentifier, width: size.width, height: size.height,
                                                            excluding: element.identifier)
                commands += groupCommands
                element.frame = spot
            }
        } else if layout.isFree(inPlace, in: state, ignoring: [element.identifier], avoidingArrows: false) {
            element.frame = inPlace
        } else {
            element.frame = layout.findFreeSpot(width: size.width, height: size.height, in: state, near: element.frame,
                                                preferredSide: .right, ignoring: [element.identifier])
        }
        state.replace(element)
        commands.append(drawCommand(for: element, keepsShape: false))
        commands += rerouteConnectors(touching: [element.identifier])
        return commands
    }

    // MARK: - Arrows

    private func connectorNamed(_ identifier: String) -> BoardConnector? {
        state.connectors.first { $0.identifier == identifier }
    }

    /// Routes an arrow around the elements between its ends, places its
    /// label, stores both and returns the stroke to draw.
    private func routeAndDraw(_ connector: inout BoardConnector) -> BoardDrawCommand {
        guard let fromElement = state.element(connector.fromIdentifier),
              let toElement = state.element(connector.toIdentifier) else {
            return BoardDrawCommand(action: .unlink, identifier: connector.identifier)
        }
        let endGroups = Set([fromElement.groupIdentifier, toElement.groupIdentifier].compactMap { $0 })
        let obstacles = state.elements.filter { element in
            element.kind != .group
                && element.identifier != fromElement.identifier
                && element.identifier != toElement.identifier
                && !endGroups.contains(element.identifier)
        }.map(\.frame) + state.connectors.filter { $0.identifier != connector.identifier }.compactMap(\.labelFrame)
            + state.connectors.filter { $0.identifier != connector.identifier }.flatMap { $0.stubTagFrames ?? [] }
            // A group's title is words too, even the group an end sits in.
            + state.elements.filter { $0.kind == .group }.map { group in
                BoardRect(x: group.frame.x, y: group.frame.y,
                          width: min(group.frame.width, BoardLayout.widthOfText(group.text, size: 22, isBold: true) + BoardLayout.groupPadding * 2),
                          height: BoardLayout.groupTitleBand - 6)
            }
        let reverseRoute = state.connector(from: connector.toIdentifier, to: connector.fromIdentifier)?.routePoints
        let route = layout.routeArrow(from: fromElement.frame, to: toElement.frame, obstacles: obstacles,
                                      avoiding: reverseRoute)
        connector.labelFrame = nil
        connector.drawnLabelLines = nil
        // A line across the board, or through more than one thing, reads as
        // clutter: two short stubs with the same number say the same.
        if route.crossings > 1 || route.length > layout.longestArrow {
            state.replace(BoardConnector(fromIdentifier: connector.fromIdentifier, toIdentifier: connector.toIdentifier,
                                         label: connector.label, isDashed: connector.isDashed, tone: connector.tone,
                                         routePoints: [], labelFrame: nil, addedInTurn: connector.addedInTurn))
            let stubs = layout.stubs(from: fromElement.frame, to: toElement.frame, in: state,
                                     ignoring: [fromElement.identifier, toElement.identifier])
            connector.stubTag = connector.stubTag ?? nextStubTag()
            connector.routePoints = stubs.leaving
            connector.targetStubPoints = stubs.arriving
            connector.stubTagFrames = [stubs.leavingTag, stubs.arrivingTag]
        } else {
            connector.routePoints = route.points
            connector.stubTag = nil
            connector.targetStubPoints = nil
            connector.stubTagFrames = nil
        }
        state.replace(connector)
        // A stub whose start became a corner badge has no line there; its
        // label goes by the arriving stub instead.
        let labelRoute = connector.routePoints.count >= 2 ? connector.routePoints : (connector.targetStubPoints ?? [])
        let placedLabel = layout.placeArrowLabel(connector.label, along: labelRoute, in: state,
                                                 ignoringConnector: connector.identifier,
                                                 alsoAvoiding: connector.stubTagFrames ?? [])
        connector.labelFrame = placedLabel?.frame
        connector.drawnLabelLines = placedLabel?.lines
        state.replace(connector)
        return linkCommand(for: connector)
    }

    private func nextStubTag() -> Int {
        (state.connectors.compactMap(\.stubTag).max() ?? 0) + 1
    }

    /// When a link joins something drawn this turn to something older and
    /// far away, the new one slides over beside the old one, the way a
    /// teacher would have drawn it had they known. Only ever the new one:
    /// what the student has been looking at stays where it is.
    private func bringNewEndCloser(fromIdentifier: String, toIdentifier: String) -> [BoardDrawCommand] {
        guard let fromElement = state.element(fromIdentifier), let toElement = state.element(toIdentifier) else { return [] }
        for (newEnd, oldEnd) in [(toElement, fromElement), (fromElement, toElement)] {
            guard newEnd.addedInTurn == state.currentTurn, oldEnd.addedInTurn < state.currentTurn,
                  newEnd.groupIdentifier == nil, newEnd.kind != .group,
                  state.connectors(touching: newEnd.identifier).isEmpty else { continue }
            let distance = hypot(newEnd.frame.midX - oldEnd.frame.midX, newEnd.frame.midY - oldEnd.frame.midY)
            guard distance > layout.longestArrow * 0.6 else { continue }
            let anchor = oldEnd.groupIdentifier.flatMap { state.element($0)?.frame } ?? oldEnd.frame
            let spot = layout.findFreeSpot(width: newEnd.frame.width, height: newEnd.frame.height, in: state,
                                           near: anchor, preferredSide: newEnd.frame.midX >= anchor.midX ? .right : .left,
                                           ignoring: [newEnd.identifier], extraSpacing: 110)
            let newDistance = hypot(spot.midX - oldEnd.frame.midX, spot.midY - oldEnd.frame.midY)
            guard newDistance < distance * 0.6 else { continue }
            var moved = newEnd
            moved.frame = spot
            state.replace(moved)
            return [BoardDrawCommand(action: .move, identifier: moved.identifier, frame: spot)]
        }
        return []
    }

    private func rerouteConnectors(touching identifiers: [String]) -> [BoardDrawCommand] {
        var commands: [BoardDrawCommand] = []
        var affected: [String] = []
        for identifier in identifiers {
            for connector in state.connectors(touching: identifier) where !affected.contains(connector.identifier) {
                affected.append(connector.identifier)
            }
        }
        // Every affected arrow lets go of its old place first, so each one
        // is placed against where the others are now, not where they were.
        for identifier in affected {
            guard var connector = state.connectors.first(where: { $0.identifier == identifier }) else { continue }
            connector.routePoints = []
            connector.labelFrame = nil
            connector.targetStubPoints = nil
            connector.stubTagFrames = nil
            state.replace(connector)
        }
        for identifier in affected {
            guard var connector = state.connectors.first(where: { $0.identifier == identifier }) else { continue }
            commands.append(routeAndDraw(&connector))
        }
        return commands
    }

    // MARK: - Commands

    private func drawCommand(for element: BoardElement, keepsShape: Bool) -> BoardDrawCommand {
        BoardDrawCommand(action: .element, identifier: element.identifier, kind: element.kind.rawValue,
                         tone: element.tone, geometry: BoardLayout.geometry(for: element, at: element.frame),
                         keepsShape: keepsShape ? true : nil, ink: element.ink?.rawValue)
    }

    private func linkCommand(for connector: BoardConnector) -> BoardDrawCommand {
        BoardDrawCommand(action: .link, identifier: connector.identifier, tone: connector.tone,
                         route: connector.routePoints, labelLines: connector.drawnLabelLines,
                         isDashed: connector.isDashed || connector.ink == .gap ? true : nil,
                         stubTag: connector.stubTag, arrivingRoute: connector.targetStubPoints,
                         tagFrames: connector.stubTagFrames, ink: connector.ink?.rawValue)
    }

    // MARK: - Teach it back

    /// Ids the check gave to a new mark that were already taken by the
    /// student's drawing, this turn, and the fresh id each was given.
    private var gapIdentifierReplacements: [String: String] = [:]
    private var gapMarksThisTurn = 0
    static let maximumGapMarks = 4

    /// While the gap check draws, only marks are made: what the student
    /// said is never updated, rubbed out, unlinked or moved. A new mark
    /// whose id is already one of theirs gets a fresh id, and arrows from
    /// the same turn that name it follow it there.
    private func operationAllowedInGapCheck(_ operation: BoardOperation) -> BoardOperation? {
        guard inkForNewMarks == .gap else { return operation }
        func isTheStudents(_ identifier: String) -> Bool {
            if let element = state.element(identifier) { return element.ink != .gap }
            if let connector = connectorNamed(identifier) { return connector.ink != .gap }
            return false
        }
        func current(_ identifier: String) -> String { gapIdentifierReplacements[identifier] ?? identifier }
        // At most four gaps a check: a missing part, a correction, or a
        // missing link between two parts already there. A link to a part
        // marked missing belongs to that part's gap.
        let isNewGap: Bool
        switch operation {
        case .add(_, let identifier, _, _, _, _, _): isNewGap = state.element(current(identifier)) == nil
        case .markWrong(let identifier, _): isNewGap = state.element("fix-" + identifier.replacingOccurrences(of: ">", with: "-")) == nil
        case let .link(fromIdentifier, toIdentifier, _, _, _):
            isNewGap = state.element(current(fromIdentifier))?.ink != .gap && state.element(current(toIdentifier))?.ink != .gap
                && state.connector(from: current(fromIdentifier), to: current(toIdentifier)) == nil
        default: isNewGap = false
        }
        if isNewGap {
            guard gapMarksThisTurn < Self.maximumGapMarks else {
                warnings.append("a fifth gap was left off: a check marks at most \(Self.maximumGapMarks)")
                return nil
            }
            gapMarksThisTurn += 1
        }
        switch operation {
        case let .add(kind, identifier, text, listItems, tableRows, placement, tone):
            var markIdentifier = current(identifier)
            if isTheStudents(markIdentifier) {
                var suffix = 1
                repeat { markIdentifier = "\(identifier)-gap\(suffix == 1 ? "" : String(suffix))"; suffix += 1 }
                while state.element(markIdentifier) != nil
                gapIdentifierReplacements[identifier] = markIdentifier
            }
            var markPlacement = placement
            markPlacement.nearIdentifier = placement.nearIdentifier.map(current)
            return .add(kind: kind, identifier: markIdentifier, text: text, listItems: listItems, tableRows: tableRows,
                        placement: markPlacement, tone: tone)
        case let .link(fromIdentifier, toIdentifier, label, isDashed, tone):
            let from = current(fromIdentifier), to = current(toIdentifier)
            // Relabelling one of their arrows would change what they said.
            if let existing = state.connector(from: from, to: to), existing.ink != .gap {
                warnings.append("the check tried to change the student's arrow \(existing.identifier): left as said")
                return nil
            }
            return .link(fromIdentifier: from, toIdentifier: to, label: label, isDashed: isDashed, tone: tone)
        case let .update(identifier, _), let .append(identifier, _), let .remove(identifier),
             let .moveIntoGroup(identifier, _):
            guard !isTheStudents(current(identifier)) else {
                warnings.append("the check tried to change the student's \(identifier): left as said")
                return nil
            }
            return operation
        case let .unlink(fromIdentifier, toIdentifier):
            guard !isTheStudents(BoardConnector.identifier(from: fromIdentifier, to: toIdentifier)) else {
                warnings.append("the check tried to rub out the student's arrow \(fromIdentifier)>\(toIdentifier): left as said")
                return nil
            }
            return operation
        case .setTitle:
            return nil
        default:
            return operation
        }
    }

    /// Rubs out every gap mark (missing parts, missing links, corrections
    /// and their rings) before the student's explanation is checked again,
    /// so the new check starts from their drawing alone.
    func removeGapMarks() -> [BoardDrawCommand] {
        var commands: [BoardDrawCommand] = []
        for connector in state.connectors where connector.ink == .gap {
            commands += apply(.unlink(fromIdentifier: connector.fromIdentifier, toIdentifier: connector.toIdentifier))
        }
        for element in state.elements where element.ink == .gap && state.element(element.identifier) != nil {
            commands += apply(.remove(identifier: element.identifier))
        }
        return commands
    }
}
