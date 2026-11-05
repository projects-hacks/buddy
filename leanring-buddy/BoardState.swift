//
//  BoardState.swift
//  leanring-buddy
//
//  What is on the teaching board, kept on the Mac across turns.
//
//  Why the board is state and not a picture. A teacher at a whiteboard adds
//  to what is already there: the ring drawn in the first minute is still the
//  ring when the student asks what happens when a node leaves. If the model
//  redrew the board every turn it would put things somewhere new each time
//  and the student would lose their place. So the model only ever sends
//  operations (add this box, link these two, change that label), and this is
//  where the result lives, with stable ids the next turn can refer to.
//
//  Positions are in board units, the board's own coordinates before the view
//  zooms or scrolls. They are decided by BoardLayout, never by the model, and
//  are never sent back to it: the turn note carries ids, kinds, texts and
//  groups only (compactListing).
//

import CoreGraphics
import Foundation

/// A rectangle in board units, Codable so a whole board can be saved.
struct BoardRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    func insetBy(_ amount: Double) -> BoardRect {
        BoardRect(x: x + amount, y: y + amount, width: width - amount * 2, height: height - amount * 2)
    }

    func intersects(_ other: BoardRect) -> Bool {
        x < other.maxX && maxX > other.x && y < other.maxY && maxY > other.y
    }

    func contains(_ other: BoardRect) -> Bool {
        other.x >= x && other.maxX <= maxX && other.y >= y && other.maxY <= maxY
    }

    func union(_ other: BoardRect) -> BoardRect {
        let left = min(x, other.x), top = min(y, other.y)
        let right = max(maxX, other.maxX), bottom = max(maxY, other.maxY)
        return BoardRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    func offsetBy(dx: Double, dy: Double) -> BoardRect {
        BoardRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    var asArray: [Double] { [x, y, width, height] }

    // Written to a tenth of a unit: the engine draws nothing finer, and a
    // board of twenty elements stays a few kilobytes on its way to the page.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(boardRounded(x), forKey: .x)
        try container.encode(boardRounded(y), forKey: .y)
        try container.encode(boardRounded(width), forKey: .width)
        try container.encode(boardRounded(height), forKey: .height)
    }
}

struct BoardPoint: Codable, Equatable {
    var x: Double
    var y: Double

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(boardRounded(x), forKey: .x)
        try container.encode(boardRounded(y), forKey: .y)
    }
}

/// A board coordinate to one decimal place, for writing out.
func boardRounded(_ value: Double) -> Double {
    (value * 10).rounded() / 10
}

/// Whose pen drew something, for teach it back (TeachBackSession.swift):
/// the student's explanation in their own purple, and the gaps Buddy marks
/// on it in red, dashed. A board taught by Buddy alone has none.
enum BoardInk: String, Codable, Equatable {
    /// What the student said, drawn as they said it.
    case student
    /// What is missing or wrong in it: dashed red, beside what they said.
    case gap
}

/// One thing on the board.
struct BoardElement: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        /// A hand-drawn box with a few words in it: a server, a step, a component.
        case box
        /// A circle with a word or two: a node, a value, a state.
        case circle
        /// Handwriting with no border: a fact beside the drawing.
        case label
        /// A sticky note: the one caveat worth remembering.
        case note
        /// A titled list: steps in order, properties, cases.
        case list
        /// A titled table of values: keys and where they live, inputs and outputs.
        case table
        /// A dashed frame with a title that holds other elements.
        case group
    }

    let identifier: String
    var kind: Kind
    /// The words in a box, circle, label or note; the title of a list, table or group.
    var text: String
    /// A list's items, in order.
    var listItems: [String] = []
    /// A table's rows, the first one being its header.
    var tableRows: [[String]] = []
    /// The group this element sits inside, if any.
    var groupIdentifier: String?
    /// A colour name from the drawing engine's palette, for meaning only.
    var tone: String?
    /// Where it is, in board units. Decided by BoardLayout.
    var frame: BoardRect
    /// The turn that put it on the board, so the student's lesson can be
    /// replayed or a later turn can tell what is new.
    let addedInTurn: Int
    var lastChangedInTurn: Int
    /// Teach it back: whose pen drew it. Nil for Buddy's own lessons.
    var ink: BoardInk? = nil
    /// Teach it back: set on a correction, the id of the element or arrow
    /// ("from>to") it corrects, which is ringed in red while it stands.
    var correctsIdentifier: String? = nil
}

/// An arrow between two elements.
struct BoardConnector: Codable, Equatable {
    let fromIdentifier: String
    let toIdentifier: String
    var label: String
    var isDashed: Bool
    var tone: String?
    /// The pen's path, in board units, routed around other elements.
    var routePoints: [BoardPoint]
    /// Where the label sits, so nothing else is placed on it.
    var labelFrame: BoardRect?
    let addedInTurn: Int
    /// Set when the arrow would cross the board: it is drawn as two short
    /// stubs carrying this number, one leaving the start (`routePoints`) and
    /// one arriving at the end (`targetStubPoints`), so the eye can pair them.
    var stubTag: Int? = nil
    var targetStubPoints: [BoardPoint]? = nil
    /// Where the two numbered tags sit, so nothing is placed on them.
    var stubTagFrames: [BoardRect]? = nil
    /// The label as drawn, which may be its first words only when the
    /// whole label had no clear place.
    var drawnLabelLines: [BoardTextLine]? = nil
    /// Teach it back: whose pen drew it. Nil for Buddy's own lessons.
    var ink: BoardInk? = nil

    /// Stable and readable: the model can see which arrow is which.
    var identifier: String { Self.identifier(from: fromIdentifier, to: toIdentifier) }

    static func identifier(from fromIdentifier: String, to toIdentifier: String) -> String {
        "\(fromIdentifier)>\(toIdentifier)"
    }
}

/// How board units map onto the paper on screen. Changed only when the board
/// outgrows the paper: it zooms out first, then scrolls to the newest part.
struct BoardViewport: Codable, Equatable {
    var scale: Double = 1
    /// Board units hidden above the paper's top edge once the board scrolls.
    var scrolledDownBy: Double = 0
    /// Board units of room on the left, to keep a zoomed-out board centred.
    var horizontalInset: Double = 0
}

/// The whole board: what is on it, in the order it was added, and the view.
struct BoardState: Codable, Equatable {
    var title: String = ""
    private(set) var elements: [BoardElement] = []
    private(set) var connectors: [BoardConnector] = []
    var viewport = BoardViewport()
    /// The latest turn that changed anything, starting at 1.
    var currentTurn = 0

    var isEmpty: Bool { elements.isEmpty && connectors.isEmpty }

    func element(_ identifier: String) -> BoardElement? {
        elements.first { $0.identifier == identifier }
    }

    func connector(from fromIdentifier: String, to toIdentifier: String) -> BoardConnector? {
        connectors.first { $0.fromIdentifier == fromIdentifier && $0.toIdentifier == toIdentifier }
    }

    func members(ofGroup groupIdentifier: String) -> [BoardElement] {
        elements.filter { $0.groupIdentifier == groupIdentifier }
    }

    func connectors(touching identifier: String) -> [BoardConnector] {
        connectors.filter { $0.fromIdentifier == identifier || $0.toIdentifier == identifier }
    }

    /// Everything drawn, in board units: shapes, arrows and their labels.
    var contentBounds: BoardRect? {
        var bounds: BoardRect?
        func include(_ rect: BoardRect) { bounds = bounds.map { $0.union(rect) } ?? rect }
        for element in elements { include(element.frame) }
        for connector in connectors {
            if let labelFrame = connector.labelFrame { include(labelFrame) }
            for point in connector.routePoints + (connector.targetStubPoints ?? []) {
                include(BoardRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            for tagFrame in connector.stubTagFrames ?? [] { include(tagFrame) }
        }
        return bounds
    }

    // MARK: - Changes, used only by TeachingBoard

    mutating func insert(_ element: BoardElement) {
        elements.append(element)
    }

    mutating func replace(_ element: BoardElement) {
        guard let index = elements.firstIndex(where: { $0.identifier == element.identifier }) else { return }
        elements[index] = element
    }

    mutating func removeElement(_ identifier: String) {
        elements.removeAll { $0.identifier == identifier }
        connectors.removeAll { $0.fromIdentifier == identifier || $0.toIdentifier == identifier }
    }

    mutating func insert(_ connector: BoardConnector) {
        connectors.append(connector)
    }

    mutating func replace(_ connector: BoardConnector) {
        guard let index = connectors.firstIndex(where: { $0.identifier == connector.identifier }) else { return }
        connectors[index] = connector
    }

    mutating func removeConnector(from fromIdentifier: String, to toIdentifier: String) {
        connectors.removeAll { $0.fromIdentifier == fromIdentifier && $0.toIdentifier == toIdentifier }
    }

    // MARK: - What the model is told

    /// The board as the model needs it to refer to and edit what is there:
    /// ids, kinds, texts, groups and arrows, one line each, and never a
    /// coordinate. A whole turn note for a 20-element board with 7 arrows
    /// is 574 tokens, counted by the API's tokenizer in
    /// scripts/board/board_harness.swift.
    func compactListing() -> String {
        guard !isEmpty else { return "ON THE BOARD: nothing yet." }
        var lines: [String] = []
        lines.append("ON THE BOARD\(title.isEmpty ? "" : " \"\(title)\"") (id kind \"text\", t = turn added):")
        for element in elements {
            var line = "\(element.identifier) \(element.kind.rawValue) \"\(element.text)\""
            switch element.kind {
            case .list:
                line += ": " + element.listItems.map { "\"\($0)\"" }.joined(separator: " | ")
            case .table:
                line += ": " + element.tableRows.map { $0.joined(separator: ",") }.joined(separator: "; ")
            default:
                break
            }
            if let groupIdentifier = element.groupIdentifier { line += " in \(groupIdentifier)" }
            line += " t\(element.addedInTurn)"
            // Teach it back: whose words these are, and what a correction corrects.
            if let ink = element.ink { line += " \(ink.rawValue)" }
            if let correctsIdentifier = element.correctsIdentifier { line += " corrects \(correctsIdentifier)" }
            lines.append(line)
        }
        if !connectors.isEmpty {
            let arrows = connectors.map { connector -> String in
                var arrow = connector.identifier
                if !connector.label.isEmpty { arrow += " \"\(connector.label)\"" }
                if connector.isDashed { arrow += " dashed" }
                if let ink = connector.ink { arrow += " \(ink.rawValue)" }
                return arrow
            }
            lines.append("ARROWS: " + arrows.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}
