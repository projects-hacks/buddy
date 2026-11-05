//
//  BoardLayout.swift
//  leanring-buddy
//
//  Where things go on the teaching board, decided on the Mac.
//
//  The rules that make a board read like a teacher's and not a jumble:
//
//  - Nothing already drawn moves to make room. A new element goes into free
//    space: beside the element it was asked to be near, else to the right of
//    the last thing drawn, else on a new row underneath, else into the first
//    hole big enough, searched in reading order. The same operations always
//    give the same board, so a session can be replayed exactly.
//  - Text never overlaps. Every element is sized from its words measured in
//    the board's own handwriting font, wrapped to a width, and kept a gap
//    away from everything else, arrow labels included.
//  - Arrows go around boxes where they can: a straight line, an elbow or a
//    bowed curve, whichever crosses the fewest other elements and is
//    shortest.
//  - When the board outgrows the paper it zooms out, down to a scale that is
//    still readable across a room, and after that scrolls to keep the newest
//    part in view.
//
//  The model's position words (near, side, in) are hints. They choose where
//  the search starts, never where something must be.
//

import CoreGraphics
import CoreText
import Foundation

/// A line of words as the engine writes it: `y` is the baseline.
struct BoardTextLine: Codable, Equatable {
    var text: String
    var x: Double
    var y: Double
    var size: Double
    var isBold: Bool
    /// "start" or "middle", as SVG's text-anchor.
    var anchor: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(boardRounded(x), forKey: .x)
        try container.encode(boardRounded(y), forKey: .y)
        try container.encode(size, forKey: .size)
        try container.encode(isBold, forKey: .isBold)
        try container.encode(anchor, forKey: .anchor)
    }
}

/// Everything the engine needs to draw one element, all in board units.
struct BoardElementGeometry: Codable, Equatable {
    var frame: BoardRect
    var textLines: [BoardTextLine]
    /// Straight pen lines inside the element: a table's grid, a list's rule.
    var ruleLines: [[BoardPoint]]
}

/// Which way from the element it was asked to be near.
enum BoardSide: String, Codable, CaseIterable {
    case right, below, left, above
}

struct BoardLayout {
    /// How wide the paper's drawing area is in board units at full size.
    /// Fixed when the board opens. Zoomed out, the same paper shows more
    /// board, up to `widestBoardWidth`, so the board can grow sideways into
    /// the paper's empty right before it has to scroll.
    let boardWidth: Double
    /// How tall the paper shows at full size.
    let visibleHeight: Double
    /// The smallest zoom before the view scrolls instead. Text 24 units tall
    /// at 0.62 is about 15 points, which still reads from across a desk.
    var minimumScale: Double = 0.62

    /// As wide as the board may get: the paper's width at the smallest zoom.
    var widestBoardWidth: Double { boardWidth / minimumScale }

    /// An arrow longer than this, or crossing more than one element, is
    /// drawn as two short numbered stubs instead of a line across the board.
    var longestArrow: Double { boardWidth * 0.6 }

    /// Space kept between separate elements, wide enough for an arrow and
    /// its label to pass between them.
    static let gapBetweenElements: Double = 46
    /// Space between elements inside the same group.
    static let gapInsideGroup: Double = 40
    static let groupPadding: Double = 22
    static let groupTitleBand: Double = 44

    // MARK: - Measuring words

    /// The engine writes in Noteworthy (DrawingEngine/draw-engine.js,
    /// HAND_FONT), so words are measured in the same font here and a box is
    /// never too small for the label written into it.
    static func widthOfText(_ text: String, size: Double, isBold: Bool) -> Double {
        let fontName = isBold ? "Noteworthy-Bold" : "Noteworthy-Light"
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(size), nil)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedText)
        let measuredWidth = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        // A little slack: the browser and Core Text round differently.
        return measuredWidth > 0 ? measuredWidth * 1.04 : Double(text.count) * size * 0.5
    }

    /// Words wrapped greedily to `maximumWidth`. A single word longer than
    /// the width keeps its own line rather than being broken.
    static func wrapText(_ text: String, size: Double, isBold: Bool, maximumWidth: Double) -> [String] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !words.isEmpty else { return [""] }
        var lines: [String] = []
        var currentLine = ""
        for word in words {
            let candidate = currentLine.isEmpty ? word : currentLine + " " + word
            if currentLine.isEmpty || widthOfText(candidate, size: size, isBold: isBold) <= maximumWidth {
                currentLine = candidate
            } else {
                lines.append(currentLine)
                currentLine = word
            }
        }
        lines.append(currentLine)
        return lines
    }

    static func lineHeight(forSize size: Double) -> Double { size * 1.32 }

    // MARK: - Sizes and drawing geometry per kind

    /// Type sizes in board units, large on purpose: the board is read from
    /// further away than a card.
    private struct KindStyle {
        let textSize: Double
        let isBold: Bool
        let maximumTextWidth: Double
        let horizontalPadding: Double
        let verticalPadding: Double
        let minimumWidth: Double
        let minimumHeight: Double
    }

    private static func style(for kind: BoardElement.Kind) -> KindStyle {
        switch kind {
        case .box: return KindStyle(textSize: 26, isBold: false, maximumTextWidth: 300, horizontalPadding: 24, verticalPadding: 18, minimumWidth: 130, minimumHeight: 72)
        case .circle: return KindStyle(textSize: 24, isBold: false, maximumTextWidth: 160, horizontalPadding: 22, verticalPadding: 22, minimumWidth: 128, minimumHeight: 128)
        case .label: return KindStyle(textSize: 24, isBold: false, maximumTextWidth: 380, horizontalPadding: 4, verticalPadding: 4, minimumWidth: 40, minimumHeight: 34)
        case .note: return KindStyle(textSize: 22, isBold: false, maximumTextWidth: 210, horizontalPadding: 18, verticalPadding: 16, minimumWidth: 200, minimumHeight: 80)
        case .list: return KindStyle(textSize: 23, isBold: false, maximumTextWidth: 380, horizontalPadding: 16, verticalPadding: 12, minimumWidth: 160, minimumHeight: 60)
        case .table: return KindStyle(textSize: 22, isBold: false, maximumTextWidth: 200, horizontalPadding: 14, verticalPadding: 10, minimumWidth: 120, minimumHeight: 60)
        case .group: return KindStyle(textSize: 22, isBold: true, maximumTextWidth: 420, horizontalPadding: groupPadding, verticalPadding: groupPadding, minimumWidth: 340, minimumHeight: 200)
        }
    }

    /// The size an element needs for its words. A group's is its smallest
    /// size when empty; it grows as members join.
    func naturalSize(of element: BoardElement) -> (width: Double, height: Double) {
        let geometry = Self.geometry(for: element, at: BoardRect(x: 0, y: 0, width: 0, height: 0), sizeToFit: true)
        return (geometry.frame.width, geometry.frame.height)
    }

    /// Lays out the words and rules of `element` inside `frame`. With
    /// `sizeToFit` the frame's size is computed and returned instead of used.
    static func geometry(for element: BoardElement, at frame: BoardRect, sizeToFit: Bool = false) -> BoardElementGeometry {
        let kindStyle = style(for: element.kind)
        let size = kindStyle.textSize
        let bodyLineHeight = Self.lineHeight(forSize: size)

        switch element.kind {
        case .box, .circle, .label, .note:
            let lines = wrapText(element.text, size: size, isBold: kindStyle.isBold, maximumWidth: kindStyle.maximumTextWidth)
            let widestLine = lines.map { widthOfText($0, size: size, isBold: kindStyle.isBold) }.max() ?? 0
            let textHeight = Double(lines.count) * bodyLineHeight
            var width = max(kindStyle.minimumWidth, widestLine + kindStyle.horizontalPadding * 2)
            var height = max(kindStyle.minimumHeight, textHeight + kindStyle.verticalPadding * 2)
            if element.kind == .circle {
                // A circle's words must fit inside the round part, not the corners.
                let diameter = max(width, height, (widestLine + textHeight) * 0.86 + kindStyle.horizontalPadding)
                width = diameter
                height = diameter
            }
            if element.kind == .label {
                width = widestLine + kindStyle.horizontalPadding * 2
                height = textHeight + kindStyle.verticalPadding * 2
            }
            let placedFrame = sizeToFit ? BoardRect(x: frame.x, y: frame.y, width: width, height: height) : frame
            let firstLineTop = placedFrame.midY - textHeight / 2
            let isCentred = element.kind == .box || element.kind == .circle
            let textLines = lines.enumerated().map { index, line in
                BoardTextLine(
                    text: line,
                    x: isCentred ? placedFrame.midX : placedFrame.x + kindStyle.horizontalPadding,
                    y: firstLineTop + Double(index) * bodyLineHeight + bodyLineHeight * 0.74,
                    size: size, isBold: kindStyle.isBold, anchor: isCentred ? "middle" : "start")
            }
            return BoardElementGeometry(frame: placedFrame, textLines: textLines, ruleLines: [])

        case .list:
            let titleSize = size + 2
            let titleLines = wrapText(element.text, size: titleSize, isBold: true, maximumWidth: kindStyle.maximumTextWidth)
            let itemLines = element.listItems.map { item in
                wrapText(item, size: size, isBold: false, maximumWidth: kindStyle.maximumTextWidth - 24)
            }
            let widestTitle = titleLines.map { widthOfText($0, size: titleSize, isBold: true) }.max() ?? 0
            let widestItem = itemLines.flatMap { $0 }.map { widthOfText($0, size: size, isBold: false) + 24 }.max() ?? 0
            let width = max(kindStyle.minimumWidth, max(widestTitle, widestItem) + kindStyle.horizontalPadding * 2)
            let titleHeight = Double(titleLines.count) * Self.lineHeight(forSize: titleSize)
            let itemsHeight = Double(itemLines.reduce(0) { $0 + $1.count }) * bodyLineHeight
            let height = max(kindStyle.minimumHeight, kindStyle.verticalPadding * 2 + titleHeight + 12 + itemsHeight)
            let placedFrame = sizeToFit ? BoardRect(x: frame.x, y: frame.y, width: width, height: height) : frame
            var textLines: [BoardTextLine] = []
            var cursorY = placedFrame.y + kindStyle.verticalPadding
            for titleLine in titleLines {
                textLines.append(BoardTextLine(text: titleLine, x: placedFrame.x + kindStyle.horizontalPadding,
                                               y: cursorY + Self.lineHeight(forSize: titleSize) * 0.74,
                                               size: titleSize, isBold: true, anchor: "start"))
                cursorY += Self.lineHeight(forSize: titleSize)
            }
            let ruleY = cursorY + 4
            cursorY += 12
            for (itemIndex, wrappedItem) in itemLines.enumerated() {
                for (lineIndex, itemLine) in wrappedItem.enumerated() {
                    // Numbered, because a list on a teaching board is almost
                    // always an order of steps, and "step two" can be said.
                    let prefix = lineIndex == 0 ? "\(itemIndex + 1). " : "    "
                    textLines.append(BoardTextLine(text: prefix + itemLine, x: placedFrame.x + kindStyle.horizontalPadding,
                                                   y: cursorY + bodyLineHeight * 0.74, size: size, isBold: false, anchor: "start"))
                    cursorY += bodyLineHeight
                }
            }
            let rule = [BoardPoint(x: placedFrame.x + kindStyle.horizontalPadding, y: ruleY),
                        BoardPoint(x: placedFrame.x + kindStyle.horizontalPadding + max(widestTitle, 60), y: ruleY)]
            return BoardElementGeometry(frame: placedFrame, textLines: textLines, ruleLines: [rule])

        case .table:
            let titleSize = size + 2
            let rows = element.tableRows.isEmpty ? [[""]] : element.tableRows
            let columnCount = rows.map(\.count).max() ?? 1
            var columnWidths = Array(repeating: 60.0, count: columnCount)
            for (rowIndex, row) in rows.enumerated() {
                for (columnIndex, cell) in row.enumerated() {
                    let cellWidth = widthOfText(cell, size: size, isBold: rowIndex == 0) + kindStyle.horizontalPadding * 2
                    columnWidths[columnIndex] = max(columnWidths[columnIndex], min(cellWidth, kindStyle.maximumTextWidth))
                }
            }
            let rowHeight = bodyLineHeight + kindStyle.verticalPadding * 2
            let titleHeight = element.text.isEmpty ? 0 : Self.lineHeight(forSize: titleSize) + 8
            let gridWidth = columnWidths.reduce(0, +)
            let titleWidth = element.text.isEmpty ? 0 : widthOfText(element.text, size: titleSize, isBold: true)
            let width = max(kindStyle.minimumWidth, gridWidth, titleWidth)
            let height = titleHeight + rowHeight * Double(rows.count)
            let placedFrame = sizeToFit ? BoardRect(x: frame.x, y: frame.y, width: width, height: height) : frame
            var textLines: [BoardTextLine] = []
            if !element.text.isEmpty {
                textLines.append(BoardTextLine(text: element.text, x: placedFrame.x, y: placedFrame.y + Self.lineHeight(forSize: titleSize) * 0.74,
                                               size: titleSize, isBold: true, anchor: "start"))
            }
            let gridTop = placedFrame.y + titleHeight
            var ruleLines: [[BoardPoint]] = []
            for rowBoundary in 0...rows.count {
                let y = gridTop + Double(rowBoundary) * rowHeight
                ruleLines.append([BoardPoint(x: placedFrame.x, y: y), BoardPoint(x: placedFrame.x + gridWidth, y: y)])
            }
            var columnLeft = placedFrame.x
            for columnIndex in 0...columnCount {
                ruleLines.append([BoardPoint(x: columnLeft, y: gridTop), BoardPoint(x: columnLeft, y: gridTop + rowHeight * Double(rows.count))])
                if columnIndex < columnCount { columnLeft += columnWidths[columnIndex] }
            }
            for (rowIndex, row) in rows.enumerated() {
                var cellLeft = placedFrame.x
                for (columnIndex, cell) in row.enumerated() {
                    textLines.append(BoardTextLine(text: cell, x: cellLeft + kindStyle.horizontalPadding,
                                                   y: gridTop + Double(rowIndex) * rowHeight + kindStyle.verticalPadding + bodyLineHeight * 0.74,
                                                   size: size, isBold: rowIndex == 0, anchor: "start"))
                    cellLeft += columnWidths[columnIndex]
                }
            }
            return BoardElementGeometry(frame: placedFrame, textLines: textLines, ruleLines: ruleLines)

        case .group:
            let titleWidth = widthOfText(element.text, size: size, isBold: true)
            let width = max(kindStyle.minimumWidth, titleWidth + groupPadding * 2)
            let placedFrame = sizeToFit ? BoardRect(x: frame.x, y: frame.y, width: width, height: kindStyle.minimumHeight) : frame
            let title = BoardTextLine(text: element.text, x: placedFrame.x + groupPadding, y: placedFrame.y + 30,
                                      size: size, isBold: true, anchor: "start")
            return BoardElementGeometry(frame: placedFrame, textLines: [title], ruleLines: [])
        }
    }

    // MARK: - Free space

    /// Whether `rect` can hold a new top-level element: on the board, a full
    /// gap from every element and group, clear of arrow labels, and, when
    /// `avoidingArrows`, not lying across an arrow already drawn.
    func isFree(_ rect: BoardRect, in state: BoardState, ignoring ignoredIdentifiers: Set<String>,
                avoidingArrows: Bool, gap: Double = BoardLayout.gapBetweenElements) -> Bool {
        guard rect.x >= 0, rect.y >= 0, rect.maxX <= widestBoardWidth else { return false }
        let padded = rect.insetBy(-gap / 2)
        for element in state.elements where !ignoredIdentifiers.contains(element.identifier) {
            if padded.intersects(element.frame.insetBy(-gap / 2)) { return false }
        }
        // Arrows between things that are themselves being ignored (a group's
        // own members, when the group grows) are part of what is moving.
        for connector in state.connectors where !(ignoredIdentifiers.contains(connector.fromIdentifier)
                                                   && ignoredIdentifiers.contains(connector.toIdentifier)) {
            if let labelFrame = connector.labelFrame, padded.intersects(labelFrame) { return false }
            if avoidingArrows, Self.route(connector.routePoints, crosses: rect.insetBy(-6)) { return false }
            if let tagFrames = connector.stubTagFrames, tagFrames.contains(where: { padded.intersects($0) }) { return false }
            if avoidingArrows, let targetStub = connector.targetStubPoints,
               Self.route(targetStub, crosses: rect.insetBy(-6)) { return false }
        }
        return true
    }

    /// The parts of the board that show without zooming out any further:
    /// the paper at the current zoom, then at the smallest zoom, then
    /// everything, which means scrolling. A new element goes in the first
    /// of these it fits in.
    func roomTiers(for state: BoardState) -> [BoardRect] {
        let currentScale = min(1, max(minimumScale, state.viewport.scale))
        return [
            BoardRect(x: 0, y: 0, width: boardWidth / currentScale, height: visibleHeight / currentScale),
            BoardRect(x: 0, y: 0, width: widestBoardWidth, height: visibleHeight / minimumScale),
            BoardRect(x: 0, y: 0, width: widestBoardWidth, height: 1_000_000)
        ]
    }

    /// The first hole, row by row from the top left, inside `room`.
    func firstFreeSpotInReadingOrder(width: Double, height: Double, in state: BoardState, within room: BoardRect,
                                     ignoring ignoredIdentifiers: Set<String> = []) -> BoardRect? {
        let contentBottom = state.contentBounds?.maxY ?? 0
        let lowestTop = min(room.maxY - height, contentBottom + Self.gapBetweenElements)
        let searchStep = 20.0
        for avoidingArrows in [true, false] {
            var y = 0.0
            while y <= lowestTop {
                var x = 0.0
                while x + width <= room.maxX {
                    let candidate = BoardRect(x: x, y: y, width: width, height: height)
                    if isFree(candidate, in: state, ignoring: ignoredIdentifiers, avoidingArrows: avoidingArrows) {
                        return candidate
                    }
                    x += searchStep
                }
                y += searchStep
            }
        }
        return nil
    }

    /// A free spot for something of `size`. Beside `anchor` first, on
    /// `preferredSide` and then the other sides further out, in the part of
    /// the board that shows without zooming; then beside it anywhere the
    /// smallest zoom shows; then the first hole in reading order; and only
    /// then below everything, where the view has to scroll.
    func findFreeSpot(width: Double, height: Double, in state: BoardState, near anchor: BoardRect?,
                      preferredSide: BoardSide?, ignoring ignoredIdentifiers: Set<String> = [],
                      extraSpacing: Double = 0) -> BoardRect {
        let tiers = roomTiers(for: state)
        func besideAnchor(within room: BoardRect) -> BoardRect? {
            guard let anchor else { return nil }
            var sides: [BoardSide] = []
            if let preferredSide { sides.append(preferredSide) }
            for side in [BoardSide.right, .below, .left, .above] where !sides.contains(side) { sides.append(side) }
            for avoidingArrows in [true, false] {
                for extraDistance in [0.0, 50, 120, 220, 360] {
                    for side in sides {
                        for candidate in Self.candidates(beside: anchor, side: side, width: width, height: height,
                                                         distance: Self.gapBetweenElements + extraSpacing + extraDistance)
                        where room.contains(candidate) {
                            if isFree(candidate, in: state, ignoring: ignoredIdentifiers, avoidingArrows: avoidingArrows) {
                                return candidate
                            }
                        }
                    }
                }
            }
            return nil
        }
        if let spot = besideAnchor(within: tiers[0]) ?? besideAnchor(within: tiers[1]) { return spot }
        for room in tiers.prefix(2) {
            if let spot = firstFreeSpotInReadingOrder(width: width, height: height, in: state, within: room,
                                                      ignoring: ignoredIdentifiers) { return spot }
        }
        if let spot = besideAnchor(within: tiers[2]) { return spot }
        if let spot = firstFreeSpotInReadingOrder(width: width, height: height, in: state, within: tiers[2],
                                                  ignoring: ignoredIdentifiers) { return spot }
        let contentBottom = state.contentBounds?.maxY ?? 0
        return BoardRect(x: 0, y: (state.elements.isEmpty ? 0 : contentBottom + Self.gapBetweenElements),
                         width: width, height: height)
    }

    /// Positions on one side of `anchor`: aligned with its top or left edge,
    /// centred on it, then sliding along that side.
    private static func candidates(beside anchor: BoardRect, side: BoardSide, width: Double, height: Double,
                                   distance: Double) -> [BoardRect] {
        let slide = 70.0
        switch side {
        case .right, .left:
            let x = side == .right ? anchor.maxX + distance : anchor.minX - distance - width
            let alignments = [anchor.minY, anchor.midY - height / 2, anchor.minY + slide, anchor.minY - slide,
                              anchor.minY + slide * 2, anchor.minY - slide * 2]
            return alignments.map { BoardRect(x: x, y: $0, width: width, height: height) }
        case .below, .above:
            let y = side == .below ? anchor.maxY + distance : anchor.minY - distance - height
            let alignments = [anchor.minX, anchor.midX - width / 2, anchor.minX + slide * 1.5, anchor.minX - slide * 1.5,
                              anchor.minX + slide * 3, anchor.minX - slide * 3]
            return alignments.map { BoardRect(x: $0, y: y, width: width, height: height) }
        }
    }

    // MARK: - Groups

    /// Where a new member of `group` goes, and the group's frame afterwards.
    /// Fills the room the group already has first, beside the last member,
    /// then on a new row; grows the frame only into free space. `nil` when
    /// the group cannot grow where it is.
    func spotInGroup(_ group: BoardElement, width: Double, height: Double, in state: BoardState,
                     excluding movingIdentifier: String? = nil) -> (member: BoardRect, groupFrame: BoardRect)? {
        let members = state.members(ofGroup: group.identifier).filter { $0.identifier != movingIdentifier }
        let innerLeft = group.frame.x + Self.groupPadding
        let innerTop = group.frame.y + Self.groupTitleBand
        var candidates: [BoardRect] = []
        if members.isEmpty {
            candidates.append(BoardRect(x: innerLeft, y: innerTop, width: width, height: height))
        } else {
            for member in members.reversed() {
                candidates.append(BoardRect(x: member.frame.maxX + Self.gapInsideGroup, y: member.frame.minY, width: width, height: height))
            }
            let lowestMemberBottom = members.map(\.frame.maxY).max() ?? innerTop
            candidates.append(BoardRect(x: innerLeft, y: lowestMemberBottom + Self.gapInsideGroup, width: width, height: height))
            for member in members {
                candidates.append(BoardRect(x: member.frame.minX, y: member.frame.maxY + Self.gapInsideGroup, width: width, height: height))
            }
        }
        let memberIdentifiers = Set(members.map(\.identifier))
        func clearOfOtherMembers(_ candidate: BoardRect) -> Bool {
            let padded = candidate.insetBy(-Self.gapInsideGroup / 2)
            return !members.contains { padded.intersects($0.frame.insetBy(-Self.gapInsideGroup / 2)) }
        }
        func grownFrame(for candidate: BoardRect) -> BoardRect {
            group.frame.union(candidate.insetBy(-Self.groupPadding))
        }
        // First choice: fits in the room the group already has.
        for candidate in candidates where clearOfOtherMembers(candidate) && group.frame.insetBy(Self.groupPadding / 2).contains(candidate) {
            return (candidate, group.frame)
        }
        // Then: the group grows, but only into free space.
        var ignored = memberIdentifiers
        ignored.insert(group.identifier)
        if let movingIdentifier { ignored.insert(movingIdentifier) }
        for candidate in candidates where clearOfOtherMembers(candidate) {
            let frame = grownFrame(for: candidate)
            if isFree(frame, in: state, ignoring: ignored, avoidingArrows: false) {
                return (candidate, frame)
            }
        }
        return nil
    }

    // MARK: - Arrows

    /// The path for an arrow from `fromFrame` to `toFrame` that crosses the
    /// fewest other elements, then is shortest. Only crossings of elements
    /// that are not the ends, and not a group holding an end, count.
    /// A route, with what decides whether to draw it whole or as stubs.
    struct ArrowRoute {
        var points: [BoardPoint]
        var crossings: Int
        var length: Double
    }

    func routeArrow(from fromFrame: BoardRect, to toFrame: BoardRect, obstacles: [BoardRect],
                    avoiding existingRoute: [BoardPoint]? = nil) -> ArrowRoute {
        // An arrow leaves from the middle of one side and arrives at the
        // middle of one side; every pairing is tried, each as a straight
        // line, an elbow and bowed curves.
        func port(of frame: BoardRect, on side: BoardSide, standingOff distance: Double) -> BoardPoint {
            switch side {
            case .right: return BoardPoint(x: frame.maxX + distance, y: frame.midY)
            case .left: return BoardPoint(x: frame.minX - distance, y: frame.midY)
            case .below: return BoardPoint(x: frame.midX, y: frame.maxY + distance)
            case .above: return BoardPoint(x: frame.midX, y: frame.minY - distance)
            }
        }
        func outwardDirection(_ side: BoardSide) -> (x: Double, y: Double) {
            switch side {
            case .right: return (1, 0)
            case .left: return (-1, 0)
            case .below: return (0, 1)
            case .above: return (0, -1)
            }
        }
        let isHorizontalSide: (BoardSide) -> Bool = { $0 == .left || $0 == .right }

        var candidates: [(route: [BoardPoint], facesAway: Bool)] = []
        // Linked both ways: first choice is the same straight line drawn
        // twice side by side, as a teacher draws a request and its reply.
        var parallelCandidates: [[BoardPoint]] = []
        if let existingRoute, existingRoute.count == 2 {
            let reversedStart = existingRoute[1], reversedEnd = existingRoute[0]
            let deltaX = reversedEnd.x - reversedStart.x, deltaY = reversedEnd.y - reversedStart.y
            let length = max(1, hypot(deltaX, deltaY))
            for offset in [18.0, -18.0] {
                let shiftX = -deltaY / length * offset, shiftY = deltaX / length * offset
                let parallel = [BoardPoint(x: reversedStart.x + shiftX, y: reversedStart.y + shiftY),
                                BoardPoint(x: reversedEnd.x + shiftX, y: reversedEnd.y + shiftY)]
                parallelCandidates.append(parallel)
                candidates.append((parallel, false))
            }
        }
        for startSide in BoardSide.allCases {
            for endSide in BoardSide.allCases {
                let start = port(of: fromFrame, on: startSide, standingOff: 6)
                let end = port(of: toFrame, on: endSide, standingOff: 8)
                let leaving = outwardDirection(startSide), arriving = outwardDirection(endSide)
                // A side facing away from the other end makes an arrow that
                // doubles back on itself.
                let facesAway = (end.x - start.x) * leaving.x + (end.y - start.y) * leaving.y < 0
                    || (start.x - end.x) * arriving.x + (start.y - end.y) * arriving.y < 0
                candidates.append(([start, end], facesAway))
                switch (isHorizontalSide(startSide), isHorizontalSide(endSide)) {
                case (true, true):
                    // Both ports on the same side go out and round, with
                    // room to spare, instead of skimming along the edges.
                    let middleX = startSide != endSide ? (start.x + end.x) / 2
                        : (startSide == .right ? max(start.x, end.x) + 28 : min(start.x, end.x) - 28)
                    candidates.append(([start, BoardPoint(x: middleX, y: start.y), BoardPoint(x: middleX, y: end.y), end], facesAway))
                case (false, false):
                    let middleY = startSide != endSide ? (start.y + end.y) / 2
                        : (startSide == .below ? max(start.y, end.y) + 28 : min(start.y, end.y) - 28)
                    candidates.append(([start, BoardPoint(x: start.x, y: middleY), BoardPoint(x: end.x, y: middleY), end], facesAway))
                case (true, false):
                    candidates.append(([start, BoardPoint(x: end.x, y: start.y), end], facesAway))
                case (false, true):
                    candidates.append(([start, BoardPoint(x: start.x, y: end.y), end], facesAway))
                }
                // Bowed curves either side of the straight line, further out each time.
                let deltaX = end.x - start.x, deltaY = end.y - start.y
                let length = max(1, hypot(deltaX, deltaY))
                let perpendicular = (x: -deltaY / length, y: deltaX / length)
                let middle = BoardPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                for bow in [70.0, -70, 140, -140, 230, -230] {
                    candidates.append(([start, BoardPoint(x: middle.x + perpendicular.x * bow, y: middle.y + perpendicular.y * bow), end], facesAway))
                }
            }
        }

        // Never off the drawing area: above it is the title, to the left
        // and right the paper's edge. A candidate that leaves is not a
        // choice at all, however much shorter.
        let inside = candidates.filter { candidate in
            Self.sampledPoints(of: candidate.route).allSatisfy { isInsideDrawingArea($0) }
        }
        func crossingCount(_ route: [BoardPoint]) -> Int {
            obstacles.filter { Self.route(route, crosses: $0.insetBy(-10)) }.count
        }
        func length(_ route: [BoardPoint]) -> Double {
            var pathLength = 0.0
            for index in 1..<route.count {
                pathLength += hypot(route[index].x - route[index - 1].x, route[index].y - route[index - 1].y)
            }
            return pathLength
        }
        func cost(_ candidate: (route: [BoardPoint], facesAway: Bool)) -> Double {
            let route = candidate.route
            let crossings = crossingCount(route)
            let pathLength = length(route)
            // A curve's middle point is where it bends: the first bend is
            // worth taking only when it saves a crossing.
            let bendPenalty = route.count == 3 ? 60.0 : Double(route.count - 2) * 40
            // The same two elements linked both ways: the second arrow keeps
            // clear of the first instead of drawing over it.
            var overlapsExisting = false
            if let existingRoute {
                for point in route.dropFirst().dropLast() where Self.route(existingRoute, crosses: BoardRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40)) {
                    overlapsExisting = true
                }
                if route.count == 2 && !parallelCandidates.contains(route) { overlapsExisting = true }
            }
            return Double(crossings) * 900 + (candidate.facesAway ? 600 : 0)
                + (overlapsExisting ? 3_000 : 0) + pathLength + bendPenalty
        }
        let chosen = inside.min { cost($0) < cost($1) }?.route
            ?? [clampedIntoDrawingArea(BoardPoint(x: fromFrame.midX, y: fromFrame.midY)),
                clampedIntoDrawingArea(BoardPoint(x: toFrame.midX, y: toFrame.midY))]
        return ArrowRoute(points: chosen, crossings: crossingCount(chosen), length: length(chosen))
    }

    func isInsideDrawingArea(_ point: BoardPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x <= widestBoardWidth
    }

    func clampedIntoDrawingArea(_ point: BoardPoint) -> BoardPoint {
        BoardPoint(x: min(max(0, point.x), widestBoardWidth), y: max(0, point.y))
    }

    /// The points a pen path really passes through: the corners of a line,
    /// and along a bowed curve, which the engine draws smoothly through its
    /// three points and which bulges past them.
    static func sampledPoints(of route: [BoardPoint]) -> [BoardPoint] {
        guard route.count == 3 else { return route }
        let start = route[0], through = route[1], end = route[2]
        // The quadratic through `through` at its midpoint has this control point.
        let control = BoardPoint(x: 2 * through.x - (start.x + end.x) / 2, y: 2 * through.y - (start.y + end.y) / 2)
        return (0...12).map { step in
            let fraction = Double(step) / 12
            let inverse = 1 - fraction
            return BoardPoint(x: inverse * inverse * start.x + 2 * inverse * fraction * control.x + fraction * fraction * end.x,
                              y: inverse * inverse * start.y + 2 * inverse * fraction * control.y + fraction * fraction * end.y)
        }
    }

    // MARK: - Stubs

    /// Two short arrows with a matching number, for a link that would
    /// otherwise cross the board: one leaving `fromFrame` towards the other
    /// end, one arriving at `toFrame` from it. Each side is chosen to face
    /// the other end and to keep its tag clear.
    struct ArrowStubs {
        var leaving: [BoardPoint]
        var arriving: [BoardPoint]
        var leavingTag: BoardRect
        var arrivingTag: BoardRect
    }

    static let stubTagRadius = 16.0

    func stubs(from fromFrame: BoardRect, to toFrame: BoardRect, in state: BoardState,
               ignoring endIdentifiers: Set<String>) -> ArrowStubs {
        func sidesFacing(_ target: BoardRect, from frame: BoardRect) -> [BoardSide] {
            let deltaX = target.midX - frame.midX, deltaY = target.midY - frame.midY
            let horizontal: BoardSide = deltaX >= 0 ? .right : .left
            let vertical: BoardSide = deltaY >= 0 ? .below : .above
            let first = abs(deltaX) >= abs(deltaY) ? [horizontal, vertical] : [vertical, horizontal]
            return first + BoardSide.allCases.filter { !first.contains($0) }
        }
        func stub(of frame: BoardRect, facing target: BoardRect) -> (points: [BoardPoint], tag: BoardRect) {
            let radius = Self.stubTagRadius
            var fallback: (points: [BoardPoint], tag: BoardRect, touches: Int)?
            // Each side, at the middle and then sliding along it, at two
            // reaches: an element with many links gets a fan of tags rather
            // than a pile of them.
            var placements: [(side: BoardSide, reach: Double, slide: Double)] = []
            for side in sidesFacing(target, from: frame) {
                for reach in [52.0, 92.0, 132.0] {
                    for slide in [0.0, -44, 44, -88, 88, -132, 132] { placements.append((side, reach, slide)) }
                }
            }
            for (side, reach, slide) in placements {
                let port: BoardPoint
                let direction: (x: Double, y: Double)
                let alongWidth = max(0, frame.width / 2 - 10), alongHeight = max(0, frame.height / 2 - 10)
                let slideAcross = min(max(slide, -alongWidth), alongWidth)
                let slideDown = min(max(slide, -alongHeight), alongHeight)
                switch side {
                case .right: port = BoardPoint(x: frame.maxX + 6, y: frame.midY + slideDown); direction = (1, 0)
                case .left: port = BoardPoint(x: frame.minX - 6, y: frame.midY + slideDown); direction = (-1, 0)
                case .below: port = BoardPoint(x: frame.midX + slideAcross, y: frame.maxY + 6); direction = (0, 1)
                case .above: port = BoardPoint(x: frame.midX + slideAcross, y: frame.minY - 6); direction = (0, -1)
                }
                let centre = BoardPoint(x: port.x + direction.x * reach, y: port.y + direction.y * reach)
                let tag = BoardRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
                let points = [port, BoardPoint(x: centre.x - direction.x * radius, y: centre.y - direction.y * radius)]
                guard isInsideDrawingArea(BoardPoint(x: tag.minX, y: tag.minY)), tag.maxX <= widestBoardWidth else { continue }
                // What the tag would touch; the first spot touching nothing
                // wins, and with none the spot touching least.
                var touches = state.elements.filter { $0.kind != .group && $0.frame.insetBy(-6).intersects(tag) }.count * 3
                // A group's title, and its border: a tag is wholly inside a
                // group or wholly outside it.
                for group in state.elements where group.kind == .group {
                    let titleBand = BoardRect(x: group.frame.x, y: group.frame.y,
                                              width: min(group.frame.width, Self.widthOfText(group.text, size: 22, isBold: true) + Self.groupPadding * 2),
                                              height: Self.groupTitleBand)
                    if titleBand.insetBy(-4).intersects(tag) { touches += 3 }
                    if group.frame.insetBy(-4).intersects(tag) && !group.frame.insetBy(4).contains(tag) { touches += 2 }
                }
                for connector in state.connectors {
                    if connector.labelFrame.map({ $0.insetBy(-6).intersects(tag) }) ?? false { touches += 3 }
                    touches += (connector.stubTagFrames ?? []).filter { $0.insetBy(-6).intersects(tag) }.count * 3
                    if Self.route(Self.sampledPoints(of: connector.routePoints), crosses: tag) { touches += 1 }
                }
                // The stub's own line keeps off other elements and group titles too.
                for element in state.elements where element.frame != frame {
                    if element.kind != .group, Self.route(points, crosses: element.frame.insetBy(-2)) { touches += 3 }
                    if element.kind == .group {
                        let titleBand = BoardRect(x: element.frame.x, y: element.frame.y,
                                                  width: min(element.frame.width, Self.widthOfText(element.text, size: 22, isBold: true) + Self.groupPadding * 2),
                                                  height: Self.groupTitleBand)
                        if Self.route(points, crosses: titleBand) { touches += 3 }
                    }
                }
                if touches == 0 { return (points, tag) }
                if fallback == nil || touches < fallback!.touches { fallback = (points, tag, touches) }
            }
            // Boxed in on every side: the tag becomes a badge on the
            // element's own corner, where a box keeps only padding, and the
            // stub's line is left out.
            var badgeCentres: [(Double, Double)] = [(frame.maxX, frame.maxY), (frame.minX, frame.maxY), (frame.maxX, frame.minY), (frame.minX, frame.minY)]
            // Then along the edges, for an element with many links: a box's
            // padding is as deep as a badge's half.
            for fraction in [0.85, 0.15] {
                let alongX = frame.minX + frame.width * fraction, alongY = frame.minY + frame.height * fraction
                badgeCentres += [(alongX, frame.maxY), (alongX, frame.minY), (frame.maxX, alongY), (frame.minX, alongY)]
            }
            for (cornerX, cornerY) in badgeCentres {
                let badge = BoardRect(x: cornerX - radius, y: cornerY - radius, width: radius * 2, height: radius * 2)
                guard badge.minX >= 0, badge.minY >= 0, badge.maxX <= widestBoardWidth else { continue }
                let touchesSomethingElse = state.elements.contains { element in
                    element.kind != .group && element.frame != frame && element.frame.insetBy(-4).intersects(badge)
                } || state.elements.contains { group in
                    group.kind == .group && BoardRect(
                        x: group.frame.x, y: group.frame.y,
                        width: min(group.frame.width, Self.widthOfText(group.text, size: 22, isBold: true) + Self.groupPadding * 2),
                        height: Self.groupTitleBand).intersects(badge)
                } || state.connectors.contains { connector in
                    (connector.labelFrame.map { $0.insetBy(-4).intersects(badge) } ?? false)
                        || (connector.stubTagFrames ?? []).contains { $0.insetBy(-4).intersects(badge) }
                }
                if !touchesSomethingElse { return ([], badge) }
            }
            return fallback.map { ($0.points, $0.tag) } ?? ([], BoardRect(x: 0, y: 0, width: 0, height: 0))
        }
        let leaving = stub(of: fromFrame, facing: toFrame)
        let arrivingStub = stub(of: toFrame, facing: fromFrame)
        // The arriving stub is drawn from its tag into the element, so its
        // arrowhead lands on the element.
        return ArrowStubs(leaving: leaving.points, arriving: arrivingStub.points.reversed(),
                          leavingTag: leaving.tag, arrivingTag: arrivingStub.tag)
    }

    /// Where an arrow's label goes, so that it touches nothing: no
    /// element, no group's title or border, no other label, tag or stroke.
    /// Tried beside every stretch of the route, then with only its first
    /// words, then by the arrow's start. With no clear place at all the
    /// label is left off the drawing (it stays in the board's listing),
    /// because words on top of words are worse than no words.
    func placeArrowLabel(_ text: String, along route: [BoardPoint], in state: BoardState,
                         ignoringConnector ignoredConnectorIdentifier: String,
                         alsoAvoiding ownTags: [BoardRect] = []) -> (frame: BoardRect, lines: [BoardTextLine])? {
        guard !text.isEmpty, route.count >= 2 else { return nil }
        let size = 20.0
        let words = text.split(separator: " ").map(String.init)
        var wordings = [text]
        if words.count > 3 { wordings.append(words.prefix(3).joined(separator: " ") + "\u{2026}") }
        if words.count > 2 { wordings.append(words.prefix(2).joined(separator: " ") + "\u{2026}") }

        let groupTitleBands = state.elements.filter { $0.kind == .group }.map { group in
            BoardRect(x: group.frame.x, y: group.frame.y,
                      width: min(group.frame.width, Self.widthOfText(group.text, size: 22, isBold: true) + Self.groupPadding * 2),
                      height: Self.groupTitleBand)
        }
        let groupFrames = state.elements.filter { $0.kind == .group }.map(\.frame)
        let pathPoints = Self.sampledPoints(of: route)

        func isClear(_ candidate: BoardRect) -> Bool {
            guard candidate.x >= 0, candidate.y >= 0, candidate.maxX <= widestBoardWidth else { return false }
            let padded = candidate.insetBy(-4)
            if Self.route(pathPoints, crosses: candidate.insetBy(-2)) { return false }
            for element in state.elements where element.kind != .group && padded.intersects(element.frame) { return false }
            for band in groupTitleBands where padded.intersects(band) { return false }
            // Wholly inside a group or wholly outside it, never across its border.
            for frame in groupFrames where padded.intersects(frame) && !frame.insetBy(6).contains(padded) { return false }
            for tag in ownTags where padded.intersects(tag) { return false }
            for connector in state.connectors where connector.identifier != ignoredConnectorIdentifier {
                if let labelFrame = connector.labelFrame, padded.intersects(labelFrame) { return false }
                if Self.route(Self.sampledPoints(of: connector.routePoints), crosses: candidate) { return false }
                if let targetStub = connector.targetStubPoints, Self.route(targetStub, crosses: candidate) { return false }
                if let tagFrames = connector.stubTagFrames, tagFrames.contains(where: { padded.intersects($0) }) { return false }
            }
            return true
        }

        func candidates(width: Double, height: Double, aroundStartOnly: Bool) -> [BoardRect] {
            var rects: [BoardRect] = []
            if aroundStartOnly {
                let start = route[0]
                for (offsetX, offsetY) in [(10.0, -height - 6), (10.0, 6), (-width - 10, -height - 6), (-width - 10, 6),
                                           (-width / 2, -height - 14), (-width / 2, 14)] {
                    rects.append(BoardRect(x: start.x + offsetX, y: start.y + offsetY, width: width, height: height))
                }
                return rects
            }
            // Stretches longest first, so a label sits on the arrow's main run.
            var stretches: [(BoardPoint, BoardPoint, Double)] = []
            for index in 1..<pathPoints.count {
                let from = pathPoints[index - 1], to = pathPoints[index]
                stretches.append((from, to, hypot(to.x - from.x, to.y - from.y)))
            }
            stretches.sort { $0.2 > $1.2 }
            for distance in [8.0, 28, 56, 96] {
                for (from, to, stretchLength) in stretches where stretchLength > 1 {
                    let perpendicular = (x: -(to.y - from.y) / stretchLength, y: (to.x - from.x) / stretchLength)
                    let extent = abs(perpendicular.x) * width / 2 + abs(perpendicular.y) * height / 2
                    for fraction in [0.5, 0.3, 0.7] {
                        let pointX = from.x + (to.x - from.x) * fraction
                        let pointY = from.y + (to.y - from.y) * fraction
                        for direction in [-1.0, 1.0] {
                            let centreX = pointX + perpendicular.x * direction * (extent + distance)
                            let centreY = pointY + perpendicular.y * direction * (extent + distance)
                            rects.append(BoardRect(x: centreX - width / 2, y: centreY - height / 2, width: width, height: height))
                        }
                    }
                }
            }
            return rects
        }

        for aroundStartOnly in [false, true] {
            for wording in wordings {
                let lines = Self.wrapText(wording, size: size, isBold: false, maximumWidth: 220)
                let width = (lines.map { Self.widthOfText($0, size: size, isBold: false) }.max() ?? 0) + 8
                let height = Double(lines.count) * Self.lineHeight(forSize: size) + 4
                if let chosen = candidates(width: width, height: height, aroundStartOnly: aroundStartOnly).first(where: isClear) {
                    let textLines = lines.enumerated().map { index, line in
                        BoardTextLine(text: line, x: chosen.x + 4, y: chosen.y + Double(index) * Self.lineHeight(forSize: size) + size,
                                      size: size, isBold: false, anchor: "start")
                    }
                    return (chosen, textLines)
                }
            }
        }
        return nil
    }

    /// Whether a pen path passes through `rect`, segment by segment.
    static func route(_ points: [BoardPoint], crosses rect: BoardRect) -> Bool {
        guard points.count >= 2 else { return false }
        for index in 1..<points.count where segment(from: points[index - 1], to: points[index], crosses: rect) {
            return true
        }
        return false
    }

    /// Liang-Barsky clipping: does the segment enter the rectangle at all.
    private static func segment(from start: BoardPoint, to end: BoardPoint, crosses rect: BoardRect) -> Bool {
        let deltaX = end.x - start.x, deltaY = end.y - start.y
        var entering = 0.0, leaving = 1.0
        let edges: [(Double, Double)] = [
            (-deltaX, start.x - rect.minX), (deltaX, rect.maxX - start.x),
            (-deltaY, start.y - rect.minY), (deltaY, rect.maxY - start.y)
        ]
        for (direction, distance) in edges {
            if direction == 0 {
                if distance < 0 { return false }
            } else {
                let fraction = distance / direction
                if direction < 0 { entering = max(entering, fraction) } else { leaving = min(leaving, fraction) }
                if entering > leaving { return false }
            }
        }
        return true
    }

    // MARK: - The view

    /// Full size while everything fits on the paper. Past that, zoomed out
    /// just enough, down to `minimumScale`; past that, scrolled only as far
    /// as needed to show `focus`, the part being talked about.
    func viewport(for state: BoardState, showing focus: BoardRect?, previous: BoardViewport) -> BoardViewport {
        guard let bounds = state.contentBounds else { return BoardViewport() }
        let contentHeight = bounds.maxY + 16
        let contentWidth = bounds.maxX + 16
        guard contentHeight > visibleHeight || contentWidth > boardWidth else { return BoardViewport() }
        // Zoomed out just enough for the board's width and height, never
        // below the smallest readable zoom; the width always fits there.
        let scale = max(minimumScale, min(1, visibleHeight / contentHeight, boardWidth / contentWidth))
        // Anchored at the top left as it shrinks, like stepping back from a
        // whiteboard: nothing appears to slide sideways.
        let horizontalInset = 0.0
        let visibleBoardHeight = visibleHeight / scale
        var scrolledDownBy = previous.scale == scale ? previous.scrolledDownBy : 0
        if contentHeight > visibleBoardHeight {
            if let focus {
                if focus.maxY + 24 > scrolledDownBy + visibleBoardHeight { scrolledDownBy = focus.maxY + 24 - visibleBoardHeight }
                if focus.minY - 24 < scrolledDownBy { scrolledDownBy = max(0, focus.minY - 24) }
            }
            scrolledDownBy = min(max(0, scrolledDownBy), contentHeight - visibleBoardHeight)
        } else {
            scrolledDownBy = 0
        }
        return BoardViewport(scale: scale, scrolledDownBy: scrolledDownBy, horizontalInset: horizontalInset)
    }
}
