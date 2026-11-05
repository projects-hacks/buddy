//
//  BoardProgramTranslator.swift
//  leanring-buddy
//
//  Turns the board calls in a piece of the model's program into strokes,
//  on the Mac, before the piece runs in the drawing engine.
//
//  The model writes `board.box("ring", "hash ring", {near: "client"})` the
//  way it writes `say("...")`: plain literal arguments, never built from
//  variables. Like the sentences ProgramStream reads out of the text, the
//  board calls are read out of the text here, applied to the board in Swift,
//  and replaced in place by `BuddyBoard.apply([...])` carrying the exact
//  geometry. Everything else in the piece is left alone, so `say`, `step`,
//  `button` and `lessonTitle` run exactly as in any answer, and each board
//  stroke still belongs to the sentence before it and is drawn while that
//  sentence is spoken.
//
//  Why not let the page run the board calls itself and ask the Mac where
//  things go: a program piece runs in one synchronous evaluation, and the
//  marks it makes must exist by the time it returns for the pen to be paced
//  to the voice. Reading the calls first keeps one source of truth, the
//  Swift board, with nothing waiting on a round trip.
//

import Foundation

/// A JavaScript literal as the model writes it in a board call.
indirect enum BoardLiteral: Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null
    case array([BoardLiteral])
    case object([String: BoardLiteral])

    var stringValue: String? {
        switch self {
        case .string(let text): return text
        case .number(let number):
            return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .boolean(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }
}

struct BoardProgramTranslator {
    /// The piece with every board call replaced, and the calls that failed.
    struct Translation {
        var code: String
        var operations: [BoardOperation]
        var problems: [String]
    }

    /// Reads, applies and replaces every `board.something(...)` in `piece`.
    static func translate(_ piece: String, on board: TeachingBoard) -> Translation {
        let calls = findBoardCalls(in: piece)
        guard !calls.isEmpty else { return Translation(code: piece, operations: [], problems: []) }

        var problems: [String] = []
        var parsed: [(range: Range<Int>, operation: BoardOperation?, problem: String?)] = []
        for call in calls {
            switch operation(method: call.method, arguments: call.arguments) {
            case .success(let operation): parsed.append((call.range, operation, nil))
            case .failure(let problem):
                problems.append(problem.message)
                parsed.append((call.range, nil, problem.message))
            }
        }

        // A box added and linked in the same sentence goes beside what it is
        // linked to, when the model gave no position of its own.
        let operations = inferAnchorsFromLinks(parsed.compactMap(\.operation), existing: board.state)
        var operationIterator = operations.makeIterator()

        let characters = Array(piece)
        var output = ""
        var cursor = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for entry in parsed {
            output += String(characters[cursor..<entry.range.lowerBound])
            if entry.operation != nil, let operation = operationIterator.next() {
                let commands = board.apply(operation)
                if let data = try? encoder.encode(commands), let json = String(data: data, encoding: .utf8), !commands.isEmpty {
                    output += "BuddyBoard.apply(\(json))"
                } else {
                    output += "void 0"
                }
            } else {
                output += "BuddyBoard.reportError(\(javaScriptStringLiteral(entry.problem ?? "board call not understood")))"
            }
            cursor = entry.range.upperBound
        }
        output += String(characters[cursor...])
        problems += board.takeWarnings()
        return Translation(code: output, operations: operations, problems: problems)
    }

    // MARK: - Finding calls

    struct BoardCall {
        let method: String
        let arguments: [BoardLiteral]
        /// Character offsets of `board.method(...)`, the parentheses included.
        let range: Range<Int>
    }

    /// Every `board.method(...)` outside strings and comments. A call whose
    /// arguments are not plain literals is returned with a `nil`-like
    /// failure so it can be reported rather than silently run.
    static func findBoardCalls(in code: String) -> [BoardCall] {
        let characters = Array(code)
        var calls: [BoardCall] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            // Skip strings and comments: a sentence saying "board.box" is not a call.
            if character == "\"" || character == "'" || character == "`" {
                index = endOfStringLiteral(characters, from: index)
                continue
            }
            if character == "/", index + 1 < characters.count {
                if characters[index + 1] == "/" {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                    continue
                }
                if characters[index + 1] == "*" {
                    index += 2
                    while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                    index += 2
                    continue
                }
            }
            let startsWord = index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber
                                              || characters[index - 1] == "_" || characters[index - 1] == "." || characters[index - 1] == "$")
            if startsWord, matches(characters, at: index, word: "board") {
                var cursor = index + 5
                skipSpace(characters, &cursor)
                guard cursor < characters.count, characters[cursor] == "." else { index += 5; continue }
                cursor += 1
                skipSpace(characters, &cursor)
                var method = ""
                while cursor < characters.count, characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "_" {
                    method.append(characters[cursor]); cursor += 1
                }
                skipSpace(characters, &cursor)
                guard !method.isEmpty, cursor < characters.count, characters[cursor] == "(" else { index = cursor; continue }
                cursor += 1
                var parser = LiteralParser(characters: characters, position: cursor)
                if let arguments = parser.parseArgumentList() {
                    calls.append(BoardCall(method: method, arguments: arguments, range: index..<parser.position))
                    index = parser.position
                } else {
                    // Not literals: find the matching parenthesis so the
                    // whole call is replaced by an error instead of running.
                    let end = endOfParenthesised(characters, openingAt: cursor - 1)
                    calls.append(BoardCall(method: "__unreadable__" + method, arguments: [], range: index..<end))
                    index = end
                }
                continue
            }
            index += 1
        }
        return calls
    }

    private static func matches(_ characters: [Character], at index: Int, word: String) -> Bool {
        let wordCharacters = Array(word)
        guard index + wordCharacters.count <= characters.count else { return false }
        return Array(characters[index..<(index + wordCharacters.count)]) == wordCharacters
    }

    private static func skipSpace(_ characters: [Character], _ cursor: inout Int) {
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
    }

    private static func endOfStringLiteral(_ characters: [Character], from start: Int) -> Int {
        let quote = characters[start]
        var cursor = start + 1
        while cursor < characters.count {
            if characters[cursor] == "\\" { cursor += 2; continue }
            if characters[cursor] == quote { return cursor + 1 }
            cursor += 1
        }
        return characters.count
    }

    private static func endOfParenthesised(_ characters: [Character], openingAt opening: Int) -> Int {
        var depth = 0
        var cursor = opening
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\"" || character == "'" || character == "`" {
                cursor = endOfStringLiteral(characters, from: cursor); continue
            }
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1; if depth == 0 { return cursor + 1 } }
            cursor += 1
        }
        return characters.count
    }

    // MARK: - Calls to operations

    struct TranslationProblem: Error { let message: String }

    /// The board API, as documented to the model in BoardProgramPrompt.
    static func operation(method: String, arguments: [BoardLiteral]) -> Result<BoardOperation, TranslationProblem> {
        func fail(_ message: String) -> Result<BoardOperation, TranslationProblem> { .failure(TranslationProblem(message: message)) }
        func string(_ position: Int) -> String? {
            position < arguments.count ? arguments[position].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        func options(_ position: Int) -> [String: BoardLiteral] {
            guard position < arguments.count, case .object(let dictionary) = arguments[position] else { return [:] }
            return dictionary
        }
        func stringList(_ literal: BoardLiteral?) -> [String]? {
            guard case .array(let values)? = literal else { return nil }
            return values.compactMap(\.stringValue)
        }
        func rows(_ literal: BoardLiteral?) -> [[String]]? {
            guard case .array(let values)? = literal else { return nil }
            return values.compactMap { row in
                if case .array = row { return stringList(row) }
                return row.stringValue.map { [$0] }
            }
        }
        func placement(_ options: [String: BoardLiteral]) -> BoardPlacementHint {
            BoardPlacementHint(
                nearIdentifier: options["near"]?.stringValue,
                side: options["side"]?.stringValue.flatMap { side in
                    BoardSide(rawValue: side.lowercased()) ?? ["under": .below, "beneath": .below, "over": .above,
                                                               "top": .above, "bottom": .below][side.lowercased()]
                },
                groupIdentifier: options["in"]?.stringValue ?? options["group"]?.stringValue)
        }
        func contentValue(_ literal: BoardLiteral?) -> BoardContentValue? {
            guard let literal else { return nil }
            if case .array(let values) = literal {
                if values.contains(where: { if case .array = $0 { return true }; return false }) {
                    return rows(literal).map(BoardContentValue.rows)
                }
                return .items(values.compactMap(\.stringValue))
            }
            return literal.stringValue.map(BoardContentValue.text)
        }

        if method.hasPrefix("__unreadable__") {
            let name = String(method.dropFirst("__unreadable__".count))
            return fail("board.\(name)(...) has arguments that are not plain literals, so it was not drawn")
        }

        switch method {
        case "title":
            guard let title = string(0) else { return fail("board.title needs words") }
            return .success(.setTitle(title))

        case "box", "circle", "label", "note", "group":
            guard let identifier = string(0), !identifier.isEmpty else { return fail("board.\(method) needs an id first") }
            let kind = BoardElement.Kind(rawValue: method) ?? .box
            let text = string(1) ?? identifier
            let optionValues = options(arguments.count > 1 && string(1) == nil ? 1 : 2)
            return .success(.add(kind: kind, identifier: identifier, text: text, listItems: [], tableRows: [],
                                 placement: placement(optionValues), tone: optionValues["tone"]?.stringValue))

        case "list":
            guard let identifier = string(0), !identifier.isEmpty else { return fail("board.list needs an id first") }
            let optionValues = options(3)
            return .success(.add(kind: .list, identifier: identifier, text: string(1) ?? "",
                                 listItems: stringList(arguments.count > 2 ? arguments[2] : nil) ?? [], tableRows: [],
                                 placement: placement(optionValues), tone: optionValues["tone"]?.stringValue))

        case "table":
            guard let identifier = string(0), !identifier.isEmpty else { return fail("board.table needs an id first") }
            let optionValues = options(3)
            return .success(.add(kind: .table, identifier: identifier, text: string(1) ?? "", listItems: [],
                                 tableRows: rows(arguments.count > 2 ? arguments[2] : nil) ?? [],
                                 placement: placement(optionValues), tone: optionValues["tone"]?.stringValue))

        case "link", "connect", "arrow":
            guard let fromIdentifier = string(0), let toIdentifier = string(1) else { return fail("board.link needs two ids") }
            let labelIsGiven = arguments.count > 2 && string(2) != nil
            let optionValues = options(labelIsGiven ? 3 : 2)
            var isDashed = false
            if case .boolean(let dashed)? = optionValues["dashed"] { isDashed = dashed }
            return .success(.link(fromIdentifier: fromIdentifier, toIdentifier: toIdentifier,
                                  label: labelIsGiven ? (string(2) ?? "") : (optionValues["label"]?.stringValue ?? ""),
                                  isDashed: isDashed, tone: optionValues["tone"]?.stringValue))

        case "unlink":
            guard let fromIdentifier = string(0), let toIdentifier = string(1) else { return fail("board.unlink needs two ids") }
            return .success(.unlink(fromIdentifier: fromIdentifier, toIdentifier: toIdentifier))

        case "update", "rename", "set":
            guard let identifier = string(0), let value = contentValue(arguments.count > 1 ? arguments[1] : nil) else {
                return fail("board.update needs an id and the new words")
            }
            return .success(.update(identifier: identifier, value: value))

        case "append", "addItem", "addRow":
            guard let identifier = string(0), let value = contentValue(arguments.count > 1 ? arguments[1] : nil) else {
                return fail("board.append needs an id and what to add")
            }
            return .success(.append(identifier: identifier, value: value))

        case "move":
            guard let identifier = string(0), let groupIdentifier = string(1) else { return fail("board.move needs an id and a group") }
            return .success(.moveIntoGroup(identifier: identifier, groupIdentifier: groupIdentifier))

        case "highlight", "point", "ring":
            guard let identifier = string(0) else { return fail("board.highlight needs an id") }
            return .success(.highlight(identifier: identifier))

        case "remove", "erase", "delete":
            guard let identifier = string(0) else { return fail("board.remove needs an id") }
            return .success(.remove(identifier: identifier))

        default:
            return fail("board.\(method) is not part of the board")
        }
    }

    /// Fills in `near` for an element the same piece adds and then links,
    /// so a node that is connected to the ring is drawn beside the ring.
    private static func inferAnchorsFromLinks(_ operations: [BoardOperation], existing state: BoardState) -> [BoardOperation] {
        var result = operations
        for (index, operation) in operations.enumerated() {
            guard case let .add(kind, identifier, text, listItems, tableRows, placement, tone) = operation,
                  placement.groupIdentifier == nil else { continue }
            // Already near something: only make room if it is linked to it.
            if let nearIdentifier = placement.nearIdentifier {
                let isLinkedToIt = operations[(index + 1)...].contains { later in
                    guard case let .link(fromIdentifier, toIdentifier, _, _, _) = later else { return false }
                    return Set([fromIdentifier, toIdentifier]) == Set([identifier, nearIdentifier])
                }
                if isLinkedToIt {
                    var roomier = placement
                    roomier.leavesRoomForArrow = true
                    result[index] = .add(kind: kind, identifier: identifier, text: text, listItems: listItems,
                                         tableRows: tableRows, placement: roomier, tone: tone)
                }
                continue
            }
            var known = Set(state.elements.map(\.identifier))
            for earlier in operations[..<index] {
                if case let .add(_, earlierIdentifier, _, _, _, _, _) = earlier { known.insert(earlierIdentifier) }
            }
            for later in operations[(index + 1)...] {
                guard case let .link(fromIdentifier, toIdentifier, _, _, _) = later else { continue }
                var inferred: BoardPlacementHint?
                if fromIdentifier == identifier, known.contains(toIdentifier) {
                    inferred = BoardPlacementHint(nearIdentifier: toIdentifier, side: .left, groupIdentifier: nil, leavesRoomForArrow: true)
                } else if toIdentifier == identifier, known.contains(fromIdentifier) {
                    inferred = BoardPlacementHint(nearIdentifier: fromIdentifier, side: .right, groupIdentifier: nil, leavesRoomForArrow: true)
                }
                if let inferred {
                    result[index] = .add(kind: kind, identifier: identifier, text: text, listItems: listItems,
                                         tableRows: tableRows, placement: inferred, tone: tone)
                    break
                }
            }
        }
        return result
    }

    static func javaScriptStringLiteral(_ text: String) -> String {
        let data = (try? JSONEncoder().encode([text])) ?? Data("[\"\"]".utf8)
        let arrayText = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arrayText.dropFirst().dropLast())
    }
}

/// Reads JavaScript literals: strings in any quote, numbers, true, false,
/// null, arrays and objects with bare or quoted keys. Anything else (a
/// variable, an expression, a template with `${}`) is refused.
private struct LiteralParser {
    let characters: [Character]
    var position: Int

    /// Arguments up to and including the closing parenthesis.
    mutating func parseArgumentList() -> [BoardLiteral]? {
        var arguments: [BoardLiteral] = []
        skipIgnorable()
        if peek() == ")" { position += 1; return arguments }
        while true {
            guard let value = parseValue() else { return nil }
            arguments.append(value)
            skipIgnorable()
            guard let next = peek() else { return nil }
            position += 1
            if next == ")" { return arguments }
            guard next == "," else { return nil }
            skipIgnorable()
            if peek() == ")" { position += 1; return arguments }
        }
    }

    private func peek() -> Character? { position < characters.count ? characters[position] : nil }

    private mutating func skipIgnorable() {
        while position < characters.count {
            if characters[position].isWhitespace { position += 1; continue }
            if characters[position] == "/", position + 1 < characters.count, characters[position + 1] == "/" {
                while position < characters.count, characters[position] != "\n" { position += 1 }
                continue
            }
            if characters[position] == "/", position + 1 < characters.count, characters[position + 1] == "*" {
                position += 2
                while position + 1 < characters.count, !(characters[position] == "*" && characters[position + 1] == "/") { position += 1 }
                position += 2
                continue
            }
            break
        }
    }

    private mutating func parseValue() -> BoardLiteral? {
        skipIgnorable()
        guard let character = peek() else { return nil }
        switch character {
        case "\"", "'", "`": return parseString().map(BoardLiteral.string)
        case "[": return parseArray()
        case "{": return parseObject()
        case "-", "+", "0"..."9", ".": return parseNumber()
        default:
            for (word, literal) in [("true", BoardLiteral.boolean(true)), ("false", .boolean(false)),
                                    ("null", .null), ("undefined", .null)] where matchesWord(word) {
                position += word.count
                return literal
            }
            return nil
        }
    }

    private func matchesWord(_ word: String) -> Bool {
        let wordCharacters = Array(word)
        guard position + wordCharacters.count <= characters.count,
              Array(characters[position..<(position + wordCharacters.count)]) == wordCharacters else { return false }
        let after = position + wordCharacters.count
        return after >= characters.count || !(characters[after].isLetter || characters[after].isNumber || characters[after] == "_")
    }

    private mutating func parseString() -> String? {
        let quote = characters[position]
        position += 1
        var text = ""
        while position < characters.count {
            let character = characters[position]
            if character == "\\", position + 1 < characters.count {
                let escaped = characters[position + 1]
                position += 2
                switch escaped {
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "u":
                    let hex = String(characters[position..<min(position + 4, characters.count)])
                    if let scalarValue = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(scalarValue) {
                        text.unicodeScalars.append(scalar)
                    }
                    position += 4
                default: text.append(escaped)
                }
                continue
            }
            if quote == "`", character == "$", position + 1 < characters.count, characters[position + 1] == "{" { return nil }
            if character == quote { position += 1; return text }
            text.append(character)
            position += 1
        }
        return nil
    }

    private mutating func parseNumber() -> BoardLiteral? {
        var text = ""
        while position < characters.count, "+-0123456789.eE".contains(characters[position]) {
            text.append(characters[position]); position += 1
        }
        return Double(text).map(BoardLiteral.number)
    }

    private mutating func parseArray() -> BoardLiteral? {
        position += 1
        var values: [BoardLiteral] = []
        while true {
            skipIgnorable()
            if peek() == "]" { position += 1; return .array(values) }
            guard let value = parseValue() else { return nil }
            values.append(value)
            skipIgnorable()
            if peek() == "," { position += 1; continue }
            if peek() == "]" { position += 1; return .array(values) }
            return nil
        }
    }

    private mutating func parseObject() -> BoardLiteral? {
        position += 1
        var dictionary: [String: BoardLiteral] = [:]
        while true {
            skipIgnorable()
            if peek() == "}" { position += 1; return .object(dictionary) }
            var key = ""
            if let character = peek(), character == "\"" || character == "'" {
                guard let quotedKey = parseString() else { return nil }
                key = quotedKey
            } else {
                while let character = peek(), character.isLetter || character.isNumber || character == "_" || character == "$" {
                    key.append(character); position += 1
                }
            }
            guard !key.isEmpty else { return nil }
            skipIgnorable()
            guard peek() == ":" else { return nil }
            position += 1
            guard let value = parseValue() else { return nil }
            dictionary[key] = value
            skipIgnorable()
            if peek() == "," { position += 1; continue }
            if peek() == "}" { position += 1; return .object(dictionary) }
            return nil
        }
    }
}
