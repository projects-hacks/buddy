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

    var title: String = ""

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
        !columns.isEmpty || !cells.isEmpty || baseLabel != nil || caption != nil
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
