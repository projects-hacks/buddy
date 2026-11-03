//
//  TutorWhiteboard.swift
//  leanring-buddy
//
//  A scratch surface the tutor draws on while explaining, separate from the
//  marks it puts on the user's own screen.
//
//  Why both exist: marking up the screen says "look at this". A board says
//  "here is the idea". A teacher does the second constantly, sketching a
//  picture next to the textbook rather than only pointing at it, and that
//  picture is usually not on screen anywhere. Storage and compute separating
//  is far clearer as three columns over a persistent bar than as a sentence.
//
//  Why nothing here carries a coordinate: the same lesson that produced the
//  screen index. A 4B model picks structure reliably and estimates geometry
//  badly, so it says "a column labelled Morning holding a compute box" and the
//  layout is computed here. Asking it for positions would reproduce the
//  invented-identifier failure in a form that cannot be recovered from text.
//

import SwiftUI

/// The board's contents. Built up directive by directive as the tutor speaks,
/// so elements appear in the order they are described.
struct TutorWhiteboard {
    struct Column: Identifiable {
        let id = UUID()
        let label: String
        let content: String
    }

    struct Pointer: Identifiable {
        let id = UUID()
        let cellIndex: Int
        let name: String
    }

    /// A labelled box placed on the board's grid.
    struct Node: Identifiable {
        let id: String
        let column: Int
        let row: Int
        let widthInColumns: Int
        let label: String
        let tint: Tint

        enum Tint: String {
            case blue, green, amber, grey, red

            init(name: String) {
                self = Tint(rawValue: name) ?? {
                    switch name {
                    case "yellow", "orange": return .amber
                    case "gray", "neutral", "white": return .grey
                    case "pink", "danger": return .red
                    default: return .blue
                    }
                }()
            }
        }
    }

    /// An arrow from one node to another.
    struct Edge: Identifiable {
        let id = UUID()
        let fromIdentifier: String
        let toIdentifier: String
        let label: String
    }

    /// The board's grid. Twelve across is divisible by two, three, four and
    /// six, so the common arrangements land on whole cells without fractions.
    static let gridColumns = 12
    static let gridRows = 7

    var title: String = ""

    /// Freely positioned boxes, for diagrams that are not a row of columns.
    ///
    /// Populated by expanding a named shape rather than by the model placing
    /// boxes itself. The renderer is the same either way; only the source of
    /// the positions differs, and the measured difference was 49 seconds
    /// against 3 for the same resulting picture.
    var nodes: [Node] = []

    /// Arrows between those boxes.
    var edges: [Edge] = []

    /// Labelled columns, left to right. Stages, moments in time, or a flow.
    var columns: [Column] = []

    /// Full-width bar beneath the columns: the thing that stays put while the
    /// columns change. Storage, in the separation example.
    var baseLabel: String?

    /// A row of values, for walking an algorithm over data.
    var cells: [String] = []

    /// Named markers under cells, such as `lo`, `mid`, `hi`.
    var pointers: [Pointer] = []

    /// The takeaway, written under the drawing.
    var caption: String?

    var hasContent: Bool {
        !columns.isEmpty || !cells.isEmpty || !nodes.isEmpty
            || baseLabel != nil || caption != nil
    }
}

// MARK: - Laying out a named shape

extension DiagramShape {
    /// Expands a named shape into positioned boxes and the arrows between them.
    ///
    /// Every layout here is one a person would draw the same way every time,
    /// which is why it belongs in code: decided once, correct always, and free
    /// at answer time. The model's contribution is the labels and which shape
    /// fits, both of which it does instantly.
    func expand() -> (nodes: [TutorWhiteboard.Node], edges: [TutorWhiteboard.Edge]) {
        switch self {
        case .pipeline(let steps):
            return Self.layOutPipeline(steps: steps)
        case .fanOut(let source, let branches, let sink):
            return Self.layOutFanOut(source: source, branches: branches, sink: sink)
        case .layers(let tiers):
            return Self.layOutLayers(tiers: tiers)
        case .tree(let levels):
            return Self.layOutTree(levels: levels)
        }
    }

    /// Steps left to right, wrapping to a second row when there are too many
    /// to stay above the minimum readable box width.
    private static func layOutPipeline(
        steps: [String]
    ) -> (nodes: [TutorWhiteboard.Node], edges: [TutorWhiteboard.Edge]) {
        let perRow = steps.count <= 4 ? steps.count : Int(ceil(Double(steps.count) / 2.0))
        let width = max(2, TutorWhiteboard.gridColumns / perRow)

        var nodes: [TutorWhiteboard.Node] = []
        for (index, step) in steps.enumerated() {
            let row = index / perRow
            let positionInRow = index % perRow
            nodes.append(
                TutorWhiteboard.Node(
                    id: "p\(index)",
                    column: positionInRow * width,
                    row: row,
                    widthInColumns: width,
                    label: step,
                    // The last step is where the data rests, so it reads as the
                    // destination rather than another hop.
                    tint: index == steps.count - 1 ? .green : .blue
                )
            )
        }

        let edges = (0..<max(0, steps.count - 1)).map { index in
            TutorWhiteboard.Edge(fromIdentifier: "p\(index)", toIdentifier: "p\(index + 1)", label: "")
        }
        return (nodes, edges)
    }

    /// One box above, several beneath it, and optionally one spanning below
    /// those. The shape of load balancing, replication and fan-out reads.
    private static func layOutFanOut(
        source: String,
        branches: [String],
        sink: String?
    ) -> (nodes: [TutorWhiteboard.Node], edges: [TutorWhiteboard.Edge]) {
        var nodes: [TutorWhiteboard.Node] = []
        var edges: [TutorWhiteboard.Edge] = []

        let sourceWidth = 4
        nodes.append(
            TutorWhiteboard.Node(
                id: "src",
                column: (TutorWhiteboard.gridColumns - sourceWidth) / 2,
                row: 0,
                widthInColumns: sourceWidth,
                label: source,
                tint: .amber
            )
        )

        let branchWidth = max(2, TutorWhiteboard.gridColumns / branches.count)
        for (index, branch) in branches.enumerated() {
            let identifier = "b\(index)"
            nodes.append(
                TutorWhiteboard.Node(
                    id: identifier,
                    column: index * branchWidth,
                    row: 1,
                    widthInColumns: branchWidth,
                    label: branch,
                    tint: .blue
                )
            )
            edges.append(TutorWhiteboard.Edge(fromIdentifier: "src", toIdentifier: identifier, label: ""))
        }

        if let sink {
            nodes.append(
                TutorWhiteboard.Node(
                    id: "snk",
                    column: 0,
                    row: 2,
                    widthInColumns: TutorWhiteboard.gridColumns,
                    label: sink,
                    tint: .green
                )
            )
            // Only the outer branches are joined to the sink. Every branch
            // connected would be a thicket, and the point reads from two.
            for index in [0, branches.count - 1] where branches.indices.contains(index) {
                edges.append(
                    TutorWhiteboard.Edge(fromIdentifier: "b\(index)", toIdentifier: "snk", label: "")
                )
            }
        }

        return (nodes, edges)
    }

    /// Full-width tiers, top to bottom, with no arrows: a stack is read by
    /// position rather than by flow.
    private static func layOutLayers(
        tiers: [String]
    ) -> (nodes: [TutorWhiteboard.Node], edges: [TutorWhiteboard.Edge]) {
        let nodes = tiers.enumerated().map { index, tier in
            TutorWhiteboard.Node(
                id: "l\(index)",
                column: 0,
                row: index,
                widthInColumns: TutorWhiteboard.gridColumns,
                label: tier,
                tint: index == tiers.count - 1 ? .green : .blue
            )
        }
        return (nodes, [])
    }

    /// Levels centred under one another, each child joined to its parent.
    private static func layOutTree(
        levels: [[String]]
    ) -> (nodes: [TutorWhiteboard.Node], edges: [TutorWhiteboard.Edge]) {
        var nodes: [TutorWhiteboard.Node] = []
        var edges: [TutorWhiteboard.Edge] = []

        for (levelIndex, level) in levels.enumerated() {
            let width = max(2, TutorWhiteboard.gridColumns / max(1, level.count))
            // Centred so each level sits under the middle of the one above.
            let leadingOffset = (TutorWhiteboard.gridColumns - width * level.count) / 2

            for (positionInLevel, label) in level.enumerated() {
                let identifier = "n\(levelIndex)_\(positionInLevel)"
                nodes.append(
                    TutorWhiteboard.Node(
                        id: identifier,
                        column: leadingOffset + positionInLevel * width,
                        row: levelIndex,
                        widthInColumns: width,
                        label: label,
                        tint: levelIndex == 0 ? .amber : .blue
                    )
                )

                // Joined to its parent, assuming a binary shape, which is what
                // a tree drawn while explaining an algorithm almost always is.
                if levelIndex > 0 {
                    let parentCount = levels[levelIndex - 1].count
                    let parentPosition = min(positionInLevel / 2, parentCount - 1)
                    edges.append(
                        TutorWhiteboard.Edge(
                            fromIdentifier: "n\(levelIndex - 1)_\(parentPosition)",
                            toIdentifier: identifier,
                            label: ""
                        )
                    )
                }
            }
        }

        return (nodes, edges)
    }
}

// MARK: - Appearance

private enum BoardStyle {
    /// Warm off-white rather than pure white, which glares against a dark
    /// screen and reads as a dialog rather than paper.
    static let paper = Color(red: 0.953, green: 0.945, blue: 0.918)
    static let ink = Color(red: 0.192, green: 0.196, blue: 0.220)
    static let mutedInk = Color(red: 0.482, green: 0.490, blue: 0.525)
    static let gridLine = Color(red: 0.855, green: 0.843, blue: 0.808)

    static let boxFill = Color(red: 0.776, green: 0.855, blue: 0.953)
    static let boxStroke = Color(red: 0.400, green: 0.573, blue: 0.796)
    static let baseFill = Color(red: 0.800, green: 0.902, blue: 0.812)
    static let baseStroke = Color(red: 0.400, green: 0.682, blue: 0.482)
    static let accent = Color(red: 0.149, green: 0.451, blue: 0.824)

    /// Handwriting faces in preference order.
    ///
    /// Resolved by name at runtime rather than bundled, and every one of these
    /// ships with macOS. The fallback is a rounded system face, which is not
    /// handwriting but still reads as informal rather than as UI chrome.
    static func hand(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let preferredFaces = ["Noteworthy-Light", "BradleyHandITCTT-Bold", "MarkerFelt-Thin", "Chalkboard"]
        let availableFamilies = Set(NSFontManager.shared.availableFontFamilies)
        let familyForFace = [
            "Noteworthy-Light": "Noteworthy",
            "BradleyHandITCTT-Bold": "Bradley Hand",
            "MarkerFelt-Thin": "Marker Felt",
            "Chalkboard": "Chalkboard"
        ]

        for face in preferredFaces {
            if let family = familyForFace[face], availableFamilies.contains(family) {
                return .custom(face, size: size)
            }
        }
        return .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - The board

/// Renders the board as a sheet of paper floating over the screen.
struct TutorWhiteboardView: View {
    let board: TutorWhiteboard

    /// Height the positioned diagram needs, from the deepest row used.
    private var diagramHeight: CGFloat {
        let deepestRow = board.nodes.map(\.row).max() ?? 0
        return CGFloat(deepestRow + 1) * 54 + CGFloat(deepestRow) * 26
    }

    /// Caption shown in the title strip, naming what is being worked through.
    private var headerText: String {
        board.title.isEmpty ? "working it out" : board.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleStrip

            VStack(alignment: .leading, spacing: 18) {
                if !board.title.isEmpty {
                    Text(board.title)
                        .font(BoardStyle.hand(size: 25))
                        .foregroundStyle(BoardStyle.ink)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                if !board.nodes.isEmpty {
                    DiagramCanvas(board: board)
                        .frame(height: diagramHeight)
                        .transition(.opacity)
                }

                if !board.columns.isEmpty {
                    columnsRow
                }

                if let baseLabel = board.baseLabel {
                    baseBar(label: baseLabel)
                }

                if !board.cells.isEmpty {
                    cellsRow
                }

                if let caption = board.caption {
                    Text(caption)
                        .font(BoardStyle.hand(size: 15))
                        .foregroundStyle(BoardStyle.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 600)
        .frame(minHeight: 240, alignment: .top)
        .background(paperBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 26, y: 10)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .center)),
            removal: .opacity
        ))
    }

    private var titleStrip: some View {
        Text(headerText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(BoardStyle.mutedInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.045))
    }

    /// Faint ruled grid, which reads as paper without competing with the ink.
    private var paperBackground: some View {
        BoardStyle.paper.overlay(
            Canvas { context, size in
                let spacing: CGFloat = 22
                var gridPath = Path()
                var y: CGFloat = spacing
                while y < size.height {
                    gridPath.move(to: CGPoint(x: 0, y: y))
                    gridPath.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
                var x: CGFloat = spacing
                while x < size.width {
                    gridPath.move(to: CGPoint(x: x, y: 0))
                    gridPath.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }
                context.stroke(gridPath, with: .color(BoardStyle.gridLine.opacity(0.5)), lineWidth: 0.5)
            }
        )
    }

    // MARK: Columns

    private var columnsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(board.columns) { column in
                VStack(spacing: 9) {
                    Text(column.label)
                        .font(BoardStyle.hand(size: 15))
                        .foregroundStyle(BoardStyle.mutedInk)

                    if column.content.isEmpty {
                        // A column may be named before its content is described.
                        Color.clear.frame(height: 48)
                    } else {
                        columnContent(column.content)
                    }

                    // Points down to whatever persists underneath.
                    if board.baseLabel != nil {
                        DownArrow()
                            .stroke(BoardStyle.boxStroke, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .frame(width: 12, height: 22)
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
    }

    /// Short content becomes a drawn box; longer content stays as written text,
    /// since a sentence crammed into a box is less readable, not more.
    @ViewBuilder
    private func columnContent(_ content: String) -> some View {
        if content.count <= 18 {
            Text(content)
                .font(BoardStyle.hand(size: 14))
                .foregroundStyle(BoardStyle.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .frame(minWidth: 74, minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(BoardStyle.boxFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(BoardStyle.boxStroke, lineWidth: 1.4)
                        )
                )
        } else {
            Text(content)
                .font(BoardStyle.hand(size: 14))
                .foregroundStyle(BoardStyle.ink)
                .multilineTextAlignment(.center)
                .frame(minHeight: 48)
        }
    }

    private func baseBar(label: String) -> some View {
        Text(label)
            .font(BoardStyle.hand(size: 16))
            .foregroundStyle(BoardStyle.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(BoardStyle.baseFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(BoardStyle.baseStroke, lineWidth: 1.4)
                    )
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: Cells

    /// A row of values with named pointers underneath, for walking an
    /// algorithm. Binary search is unreadable as prose and obvious as cells
    /// with `lo`, `mid` and `hi` sitting under them.
    private var cellsRow: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                ForEach(Array(board.cells.enumerated()), id: \.offset) { cellIndex, value in
                    Text(value)
                        .font(BoardStyle.hand(size: 15))
                        .foregroundStyle(BoardStyle.ink)
                        .frame(minWidth: 38, minHeight: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isPointedAt(cellIndex) ? BoardStyle.boxFill : Color.white.opacity(0.65))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(
                                            isPointedAt(cellIndex) ? BoardStyle.boxStroke : BoardStyle.gridLine,
                                            lineWidth: isPointedAt(cellIndex) ? 1.8 : 1.1
                                        )
                                )
                        )
                }
            }

            // Index ruler, so a pointer at 3 is checkable against the picture.
            HStack(spacing: 5) {
                ForEach(Array(board.cells.enumerated()), id: \.offset) { cellIndex, _ in
                    Text("\(cellIndex)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(BoardStyle.mutedInk.opacity(0.75))
                        .frame(minWidth: 38)
                }
            }

            if !board.pointers.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(board.cells.enumerated()), id: \.offset) { cellIndex, _ in
                        VStack(spacing: 1) {
                            ForEach(pointerNames(at: cellIndex), id: \.self) { pointerName in
                                Text("↑\(pointerName)")
                                    .font(BoardStyle.hand(size: 12))
                                    .foregroundStyle(BoardStyle.accent)
                            }
                        }
                        .frame(minWidth: 38)
                    }
                }
                .transition(.opacity)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))
    }

    private func isPointedAt(_ cellIndex: Int) -> Bool {
        board.pointers.contains { pointer in pointer.cellIndex == cellIndex }
    }

    private func pointerNames(at cellIndex: Int) -> [String] {
        board.pointers
            .filter { pointer in pointer.cellIndex == cellIndex }
            .map { pointer in pointer.name }
    }
}

// MARK: - Positioned diagram

/// Lays out grid-placed nodes and routes arrows between them.
///
/// The model gives grid cells; everything that makes a diagram readable is
/// decided here. Node sizes have floors because a box sized to its text alone
/// comes out cramped and inconsistent, and arrows leave and enter at the
/// nearest edges rather than at centres so they do not run through the boxes
/// they connect.
private struct DiagramCanvas: View {
    let board: TutorWhiteboard

    /// Smallest a labelled box may be drawn, regardless of grid width.
    private static let minimumNodeWidth: CGFloat = 112
    private static let nodeHeight: CGFloat = 54
    private static let rowSpacing: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = geometry.size.width / CGFloat(TutorWhiteboard.gridColumns)

            ZStack(alignment: .topLeading) {
                // Arrows first so they sit behind the boxes and any overshoot
                // is hidden rather than drawn across a label.
                ForEach(board.edges) { edge in
                    if let fromRect = rect(forNodeIdentifier: edge.fromIdentifier, columnWidth: columnWidth),
                       let toRect = rect(forNodeIdentifier: edge.toIdentifier, columnWidth: columnWidth) {
                        EdgeShape(from: fromRect, to: toRect)
                            .stroke(
                                BoardStyle.mutedInk.opacity(0.8),
                                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                            )

                        if !edge.label.isEmpty {
                            Text(edge.label)
                                .font(BoardStyle.hand(size: 12))
                                .foregroundStyle(BoardStyle.mutedInk)
                                .padding(.horizontal, 4)
                                .background(BoardStyle.paper)
                                .position(
                                    x: (fromRect.midX + toRect.midX) / 2,
                                    y: (fromRect.midY + toRect.midY) / 2
                                )
                        }
                    }
                }

                ForEach(board.nodes) { node in
                    let nodeRect = rect(for: node, columnWidth: columnWidth)
                    Text(node.label)
                        .font(BoardStyle.hand(size: 15))
                        .foregroundStyle(BoardStyle.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 8)
                        .frame(width: nodeRect.width, height: nodeRect.height)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(fill(for: node.tint))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(stroke(for: node.tint), lineWidth: 1.4)
                                )
                        )
                        .position(x: nodeRect.midX, y: nodeRect.midY)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
        }
    }

    private func rect(for node: TutorWhiteboard.Node, columnWidth: CGFloat) -> CGRect {
        let clampedColumn = max(0, min(node.column, TutorWhiteboard.gridColumns - 1))
        let requestedWidth = CGFloat(max(1, node.widthInColumns)) * columnWidth - 10
        let width = max(Self.minimumNodeWidth, requestedWidth)

        return CGRect(
            x: CGFloat(clampedColumn) * columnWidth + 5,
            y: CGFloat(max(0, node.row)) * (Self.nodeHeight + Self.rowSpacing),
            width: width,
            height: Self.nodeHeight
        )
    }

    private func rect(forNodeIdentifier identifier: String, columnWidth: CGFloat) -> CGRect? {
        guard let node = board.nodes.first(where: { candidate in candidate.id == identifier }) else {
            return nil
        }
        return rect(for: node, columnWidth: columnWidth)
    }

    private func fill(for tint: TutorWhiteboard.Node.Tint) -> Color {
        switch tint {
        case .blue: return BoardStyle.boxFill
        case .green: return BoardStyle.baseFill
        case .amber: return Color(red: 0.99, green: 0.90, blue: 0.71)
        case .grey: return Color.white.opacity(0.7)
        case .red: return Color(red: 0.99, green: 0.80, blue: 0.80)
        }
    }

    private func stroke(for tint: TutorWhiteboard.Node.Tint) -> Color {
        switch tint {
        case .blue: return BoardStyle.boxStroke
        case .green: return BoardStyle.baseStroke
        case .amber: return Color(red: 0.85, green: 0.65, blue: 0.25)
        case .grey: return BoardStyle.gridLine
        case .red: return Color(red: 0.85, green: 0.42, blue: 0.42)
        }
    }
}

/// An arrow between two boxes, leaving and entering at their facing edges.
private struct EdgeShape: Shape {
    let from: CGRect
    let to: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Leave and arrive on whichever sides actually face each other, so the
        // line does not cross the box it starts from.
        let isMostlyVertical = abs(to.midY - from.midY) > abs(to.midX - from.midX)

        let start: CGPoint
        let end: CGPoint
        if isMostlyVertical {
            let goingDown = to.midY > from.midY
            start = CGPoint(x: from.midX, y: goingDown ? from.maxY : from.minY)
            end = CGPoint(x: to.midX, y: goingDown ? to.minY : to.maxY)
        } else {
            let goingRight = to.midX > from.midX
            start = CGPoint(x: goingRight ? from.maxX : from.minX, y: from.midY)
            end = CGPoint(x: goingRight ? to.minX : to.maxX, y: to.midY)
        }

        path.move(to: start)
        path.addLine(to: end)

        // Arrowhead aligned to the direction of travel.
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let length = max(1, sqrt(deltaX * deltaX + deltaY * deltaY))
        let angle = atan2(deltaY / length, deltaX / length)
        let headLength: CGFloat = 9
        let spread = Double.pi / 7

        path.move(to: end)
        path.addLine(to: CGPoint(
            x: end.x - headLength * CGFloat(cos(angle - spread)),
            y: end.y - headLength * CGFloat(sin(angle - spread))
        ))
        path.move(to: end)
        path.addLine(to: CGPoint(
            x: end.x - headLength * CGFloat(cos(angle + spread)),
            y: end.y - headLength * CGFloat(sin(angle + spread))
        ))

        return path
    }
}

// MARK: - Shapes

/// A short downward arrow joining a column to the bar beneath it.
private struct DownArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.midX - 4, y: rect.maxY - 5))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX + 4, y: rect.maxY - 5))
        return path
    }
}
