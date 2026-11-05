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
}

/// Where the paper sits on a screen, and the board area inside it, in the
/// drawing canvas's pixels. The canvas is the screen's size in points, so
/// board units at full zoom are points.
struct BoardSurface: Equatable {
    let canvasWidth: Double
    let canvasHeight: Double
    let paper: BoardRect
    let content: BoardRect

    /// The notch's caption hangs over the top 96 points, so the paper starts
    /// below it; the title takes the paper's first 84 points.
    init(canvasWidth: Double, canvasHeight: Double) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        let paper = BoardRect(x: 28, y: 104, width: canvasWidth - 56, height: canvasHeight - 104 - 28)
        self.paper = paper
        self.content = BoardRect(x: paper.x + 40, y: paper.y + 84, width: paper.width - 80, height: paper.height - 84 - 30)
    }

    var layout: BoardLayout {
        BoardLayout(boardWidth: content.width, visibleHeight: content.height)
    }

    /// The argument for BuddyBoard.open in draw-board.js.
    var openArgumentsJSON: String {
        "{\"paper\": [\(paper.x), \(paper.y), \(paper.width), \(paper.height)], "
            + "\"content\": [\(content.x), \(content.y), \(content.width), \(content.height)]}"
    }
}

final class TeachingBoard {
    private(set) var state = BoardState()
    let layout: BoardLayout
    /// Calls that could not be carried out, for the log.
    private(set) var warnings: [String] = []
    /// The top-level element drawn last, where the next unanchored one goes beside.
    private var lastTopLevelIdentifier: String?
    /// Everything this turn has drawn or pointed at, so the view, when it
    /// has to scroll, shows the turn being talked about and not only its
    /// last stroke.
    private var thisTurnFocus: BoardRect?

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
        thisTurnFocus = nil
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
        var commands: [BoardDrawCommand] = []
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
            var connector = existing ?? BoardConnector(
                fromIdentifier: fromIdentifier, toIdentifier: toIdentifier, label: label, isDashed: isDashed,
                tone: tone, routePoints: [], labelFrame: nil, addedInTurn: state.currentTurn)
            connector.label = label.isEmpty ? connector.label : label
            connector.isDashed = isDashed
            connector.tone = tone ?? connector.tone
            if existing == nil { state.insert(connector) }
            commands.append(routeAndDraw(&connector))
            focus = fromElement.frame.union(toElement.frame)

        case let .unlink(fromIdentifier, toIdentifier):
            guard state.connector(from: fromIdentifier, to: toIdentifier) != nil else { return [] }
            state.removeConnector(from: fromIdentifier, to: toIdentifier)
            commands.append(BoardDrawCommand(action: .unlink,
                                             identifier: BoardConnector.identifier(from: fromIdentifier, to: toIdentifier)))

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
            commands.append(BoardDrawCommand(action: .remove, removedIdentifiers: removedElements + Array(Set(removedConnectors)).sorted()))
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
        }

        // The whole turn in view when it fits at the smallest zoom, else
        // the part just drawn.
        if let focus { thisTurnFocus = thisTurnFocus.map { $0.union(focus) } ?? focus }
        let turnFitsInView = (thisTurnFocus?.height ?? 0) <= layout.visibleHeight / layout.minimumScale - 48
        let newViewport = layout.viewport(for: state, showing: turnFitsInView ? thisTurnFocus : focus, previous: state.viewport)
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
                     tableRows: [[String]], placement: BoardPlacementHint, tone: String?) -> ([BoardDrawCommand], BoardRect) {
        var element = BoardElement(identifier: identifier, kind: kind, text: text, listItems: listItems,
                                   tableRows: tableRows, groupIdentifier: nil, tone: tone,
                                   frame: BoardRect(x: 0, y: 0, width: 0, height: 0),
                                   addedInTurn: state.currentTurn, lastChangedInTurn: state.currentTurn)
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
        if let lastTopLevelIdentifier, let last = state.element(lastTopLevelIdentifier) {
            let besideLast = BoardRect(x: last.frame.maxX + BoardLayout.gapBetweenElements, y: last.frame.minY,
                                       width: width, height: height)
            if !startsOnNewRow, layout.isFree(besideLast, in: state, ignoring: [], avoidingArrows: true) { return besideLast }
            let underLast = BoardRect(x: 0, y: (state.contentBounds?.maxY ?? 0) + BoardLayout.gapBetweenElements,
                                      width: width, height: height)
            if layout.isFree(underLast, in: state, ignoring: [], avoidingArrows: true) { return underLast }
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
        let reverseRoute = state.connector(from: connector.toIdentifier, to: connector.fromIdentifier)?.routePoints
        connector.routePoints = layout.routeArrow(from: fromElement.frame, to: toElement.frame, obstacles: obstacles,
                                                  avoiding: reverseRoute)
        connector.labelFrame = nil
        state.replace(connector)
        let placedLabel = layout.placeArrowLabel(connector.label, along: connector.routePoints, in: state,
                                                 ignoringConnector: connector.identifier)
        connector.labelFrame = placedLabel?.frame
        state.replace(connector)
        return linkCommand(for: connector, labelLines: placedLabel?.lines)
    }

    private func rerouteConnectors(touching identifiers: [String]) -> [BoardDrawCommand] {
        var commands: [BoardDrawCommand] = []
        var seen = Set<String>()
        for identifier in identifiers {
            for var connector in state.connectors(touching: identifier) where !seen.contains(connector.identifier) {
                seen.insert(connector.identifier)
                commands.append(routeAndDraw(&connector))
            }
        }
        return commands
    }

    // MARK: - Commands

    private func drawCommand(for element: BoardElement, keepsShape: Bool) -> BoardDrawCommand {
        BoardDrawCommand(action: .element, identifier: element.identifier, kind: element.kind.rawValue,
                         tone: element.tone, geometry: BoardLayout.geometry(for: element, at: element.frame),
                         keepsShape: keepsShape ? true : nil)
    }

    private func linkCommand(for connector: BoardConnector, labelLines: [BoardTextLine]? = nil) -> BoardDrawCommand {
        var lines = labelLines
        if lines == nil, let labelFrame = connector.labelFrame, !connector.label.isEmpty {
            lines = BoardLayout.wrapText(connector.label, size: 20, isBold: false, maximumWidth: 220).enumerated().map { index, line in
                BoardTextLine(text: line, x: labelFrame.x + 4, y: labelFrame.y + Double(index) * BoardLayout.lineHeight(forSize: 20) + 20,
                              size: 20, isBold: false, anchor: "start")
            }
        }
        return BoardDrawCommand(action: .link, identifier: connector.identifier, tone: connector.tone,
                                route: connector.routePoints, labelLines: lines,
                                isDashed: connector.isDashed ? true : nil)
    }
}
