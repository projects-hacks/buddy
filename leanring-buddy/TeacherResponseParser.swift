//
//  TeacherResponseParser.swift
//  leanring-buddy
//
//  Splits a model response into the words that get spoken and the on-screen
//  marks that accompany them, keeping the two aligned in time.
//
//  Why the vocabulary is this wide: a study screen is dense. An IDE, a lecture
//  slide or a PDF can hold hundreds of addressable things at once, and a single
//  cursor resting on one of them communicates almost nothing. A real teacher at
//  a whiteboard circles, underlines, crosses out, numbers the steps, draws an
//  arrow between two ideas, and wipes the board before the next point. Each of
//  those is a different claim about the material, so each gets its own mark.
//
//  Why the character offsets matter: `AVSpeechSynthesizer` reports the range of
//  each word as it speaks it. Recording where a tag sat in the spoken text lets
//  a circle appear exactly as the sentence describing it is said, instead of
//  every mark landing at once before the explanation has started. That timing
//  is most of the difference between a teacher and a diagram.
//

import Foundation

/// One mark the tutor draws on screen while speaking.
struct TeacherDirective {
    enum Action {
        /// Fly the cursor to a target and rest there.
        case point(targetIdentifier: String)
        /// Draw an ellipse around a target.
        case circle(targetIdentifier: String)
        /// Draw a rectangle around a region or diagram node.
        case box(targetIdentifier: String)
        /// Underline a line of code or a phrase.
        case underline(targetIdentifier: String)
        /// Lay a translucent marker over a target.
        case highlight(targetIdentifier: String)
        /// Strike through something that is wrong or superseded.
        case strikethrough(targetIdentifier: String)
        /// Draw an arrow between two targets, for flow or cause.
        case arrow(fromTargetIdentifier: String, toTargetIdentifier: String)
        /// Place a numbered badge, for walking an ordered sequence.
        case step(targetIdentifier: String, stepNumber: Int)
        /// Attach a short text callout beside a target.
        case callout(targetIdentifier: String, text: String)
        /// Dim everything except these targets.
        ///
        /// The strongest tool available on a crowded screen, because it removes
        /// competing detail rather than adding more ink on top of it.
        case spotlight(targetIdentifiers: [String])
        /// Wipe every current mark. The equivalent of clearing the board.
        case clearAll

        // MARK: Whiteboard
        //
        // Marks annotate what is already on screen. These draw something new
        // beside it, which is the difference between pointing at the textbook
        // and sketching the idea next to it.
        //
        // Every one of these describes structure only. No tag carries a
        // coordinate, a size or a position, for the same reason marks name a
        // target id instead of a pixel: a small model picks structure reliably
        // and estimates geometry badly. Placement is the app's job.

        /// Open a fresh board with a title. Replaces any board already shown.
        case beginBoard(title: String)
        /// Add a labelled column, left to right. Used for stages, time or flow.
        case addBoardColumn(label: String, content: String)
        /// A full-width bar beneath the columns, for the thing that persists
        /// while the columns change.
        case addBoardBase(label: String)
        /// A row of array cells, for walking an algorithm over data.
        case addBoardCells(values: [String])
        /// A named pointer under one cell, such as `lo`, `mid` or `hi`.
        ///
        /// The position may be symbolic. Asked to walk a binary search the
        /// model wrote `[PTR:last:hi]` and `[PTR:mid:middle]` rather than
        /// digits, which is a reasonable thing to mean and was previously
        /// discarded. Resolving it needs the row length, so it is kept
        /// unresolved here and settled where the board is known.
        case addBoardPointer(position: BoardPointerPosition, name: String)
        /// A caption line under the board carrying the takeaway.
        case addBoardNote(text: String)

        // MARK: Positioned diagrams
        //
        // Columns and a base bar draw one shape of picture. Anything else, a
        // cycle, a tree, a fan-out, a thing sitting beside another thing, has
        // no way to be expressed. These two allow an arbitrary diagram.
        //
        // Positions are grid cells, not pixels. Pixels were refused earlier
        // because a 4B invented them, and that reasoning held: even a capable
        // model placing pixels has to track overlap, text width and alignment
        // while also explaining something. A coarse grid is a decision it can
        // actually make, and the exact geometry, minimum sizes and spacing
        // stay with the app, which is the half it does reliably.

        /// A labelled box at a grid position.
        case addBoardNode(
            identifier: String,
            column: Int,
            row: Int,
            widthInColumns: Int,
            label: String,
            tint: String
        )

        /// An arrow between two nodes, optionally labelled.
        case addBoardEdge(fromIdentifier: String, toIdentifier: String, label: String)

        /// A whole diagram of a named shape, filled with labels.
        ///
        /// The third approach to drawing, and the one that works. Asking the
        /// model for a grid position per box was measured at 49 seconds to
        /// first byte against 3 for columns, and produced the same answer:
        /// deciding *where* things go is reasoning work, and a frontier model
        /// pays for it in latency rather than accuracy.
        ///
        /// So it is not asked. It names a shape it recognises and supplies the
        /// labels, which is recall rather than deliberation, and the layout for
        /// each shape is hand-tuned here once.
        case drawDiagram(shape: DiagramShape)
        /// Fall back to an explicit coordinate when no indexed target fits,
        /// preserving the upstream tag format.
        case pointAtCoordinate(x: Double, y: Double, label: String, displayIndex: Int)
    }

    let action: Action

    /// Index into `ParsedTeacherResponse.spokenText` where this tag appeared.
    /// Speech reaching this offset is the cue to draw the mark.
    let characterOffsetInSpokenText: Int
}

/// A diagram the app knows how to lay out, filled with the model's labels.
///
/// Deliberately a small, closed set. Each shape answers a question that comes
/// up constantly in system design and algorithms, and every one of them has a
/// layout a person would draw the same way every time, which is exactly the
/// kind of decision worth making once in code rather than per answer in a
/// model.
enum DiagramShape {
    /// A request moving through stages: client, balancer, server, cache, store.
    case pipeline(steps: [String])
    /// One thing feeding many, optionally converging on one underneath.
    /// The shape of load balancing, replication and fan-out reads.
    case fanOut(source: String, branches: [String], sink: String?)
    /// Stacked tiers, top to bottom. API over logic over storage.
    case layers(tiers: [String])
    /// A binary tree by levels, for walking an algorithm over structure.
    case tree(levels: [[String]])
}

/// Where a board pointer sits, before the row length is known.
enum BoardPointerPosition {
    case index(Int)
    case first
    case middle
    case last

    /// Settles the position against an actual row, or nil if it falls outside.
    func resolve(inCellCount cellCount: Int) -> Int? {
        guard cellCount > 0 else { return nil }
        switch self {
        case .index(let index):
            return (0..<cellCount).contains(index) ? index : nil
        case .first:
            return 0
        case .middle:
            return cellCount / 2
        case .last:
            return cellCount - 1
        }
    }
}

/// A model response separated into speech and on-screen marks.
struct ParsedTeacherResponse {
    /// The response with every tag removed. This is what gets spoken and shown,
    /// so a malformed tag can never be read aloud.
    let spokenText: String

    /// Marks in the order they should be drawn, each tied to a speech offset.
    let directives: [TeacherDirective]
}

/// Parses tagged tutor responses and prepares them for speech.
enum TeacherResponseParser {

    /// Matches any bracketed tag and captures its name and payload. One pattern
    /// for the whole vocabulary keeps adding a mark to a single switch case
    /// rather than another regex to keep in sync.
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"\[([A-Za-z]+)(?::([^\]]*))?\]"#,
        options: []
    )

    /// Matches the upstream coordinate payload, `x,y:label:screenN`.
    ///
    /// Kept so a model that ignores the screen index and emits raw coordinates
    /// still produces a usable gesture rather than a tag read aloud as text.
    private static let coordinatePayloadPattern = try! NSRegularExpression(
        pattern: #"^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*(?::([^:]*))?(?::screen(\d+))?\s*$"#,
        options: [.caseInsensitive]
    )

    /// Tags the parser owns. Membership decides removal; producing an action
    /// is separate, because `[POINT:none]` is a tag the model is told it may
    /// emit to decline pointing. It must still be stripped, or the tutor reads
    /// "point none" aloud.
    private static let recognizedTagNames: Set<String> = [
        "POINT", "CIRCLE", "BOX", "RECT", "UNDERLINE", "HIGHLIGHT", "MARK",
        "STRIKE", "STRIKETHROUGH", "ARROW", "STEP", "LABEL", "NOTE",
        "SPOTLIGHT", "FOCUS", "CLEAR", "ERASE",
        "BOARD", "COL", "COLUMN", "BASE", "CELLS", "PTR", "POINTER", "CAPTION",
        "NODE", "EDGE", "DIAGRAM"
    ]

    /// Matches a board tag sitting alone on its line, with the lines under it.
    ///
    /// The model writes a board the way a person writes a slide: the tag as a
    /// heading, the contents as prose beneath it.
    ///
    ///     [COLUMN:what snowflake does]
    ///     data lives once in cheap storage
    ///     any cluster reads it without owning it
    ///
    /// Taken literally that is a column with no content followed by two
    /// sentences of speech, so the column renders empty and the text that
    /// should have been drawn gets read aloud instead. That is the whole of
    /// the "it just reads everything out" complaint.
    private static let boardTagWithTrailingLinesPattern = try! NSRegularExpression(
        pattern: #"\[(COL|COLUMN|BASE)\s*:\s*([^\]:]+)\][ \t]*\n((?:[ \t]*[^\[\n][^\n]*\n?)+)"#,
        options: [.caseInsensitive]
    )

    /// Folds lines written under a board tag back into the tag itself.
    ///
    /// Rewriting the model's output is preferable to insisting it change: the
    /// heading-then-content shape is how it naturally writes a diagram, and the
    /// intent is unambiguous.
    private static func foldTrailingLinesIntoBoardTags(_ rawResponse: String) -> String {
        let sourceText = rawResponse as NSString
        let matches = boardTagWithTrailingLinesPattern.matches(
            in: rawResponse,
            options: [],
            range: NSRange(location: 0, length: sourceText.length)
        )
        guard !matches.isEmpty else { return rawResponse }

        let rewritten = NSMutableString(string: rawResponse)

        for match in matches.reversed() {
            let tagName = sourceText.substring(with: match.range(at: 1))
            let label = sourceText.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespaces)
            let trailingBlock = sourceText.substring(with: match.range(at: 3))

            let contentLines = trailingBlock
                .components(separatedBy: .newlines)
                .map { line in line.trimmingCharacters(in: .whitespaces) }
                .filter { line in !line.isEmpty }

            guard !contentLines.isEmpty else { continue }

            // Joined rather than kept as separate lines because a column holds
            // one short piece of content, and the colon is dropped so it cannot
            // be mistaken for another field of the tag.
            let joinedContent = contentLines
                .joined(separator: ", ")
                .replacingOccurrences(of: ":", with: " ")
            let folded = "[\(tagName):\(label):\(joinedContent)]"

            rewritten.replaceCharacters(in: match.range, with: folded + "\n")
        }

        return rewritten as String
    }

    /// Removes tags from `rawResponse` and returns them alongside the clean text.
    static func parse(rawResponse: String) -> ParsedTeacherResponse {
        let rawResponse = foldTrailingLinesIntoBoardTags(rawResponse)
        let sourceText = rawResponse as NSString
        let matches = tagPattern.matches(
            in: rawResponse,
            options: [],
            range: NSRange(location: 0, length: sourceText.length)
        )

        var removableRanges: [NSRange] = []
        var directivesWithSourceOffsets: [(action: TeacherDirective.Action, sourceOffset: Int)] = []

        // Forward order, so offsets can be rebased onto the cleaned string by
        // subtracting the tag text removed ahead of each one.
        for match in matches {
            let tagName = sourceText.substring(with: match.range(at: 1)).uppercased()

            // An unrecognised bracketed phrase is left alone: the model may
            // have meant it as prose, and a malformed mark is worth seeing
            // while the system prompt is still being tuned.
            guard Self.recognizedTagNames.contains(tagName) else { continue }

            removableRanges.append(match.range)

            let payload: String
            if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
                payload = sourceText.substring(with: match.range(at: 2))
            } else {
                payload = ""
            }

            if let action = makeAction(tagName: tagName, payload: payload) {
                directivesWithSourceOffsets.append((action, match.range.location))
            }
        }

        // Remove back to front so each range stays valid as earlier ones go.
        let mutableText = NSMutableString(string: rawResponse)
        for range in removableRanges.reversed() {
            mutableText.replaceCharacters(in: range, with: "")
        }

        let strippedText = mutableText as String
        let cleanedText = tidyWhitespace(in: strippedText)

        // Rebase each offset onto the stripped string. Tidying shifts things a
        // little further, which is immaterial: the offset only has to land in
        // the right clause for the mark to appear on the right words.
        let characterCountRemovedBefore = { (sourceOffset: Int) -> Int in
            removableRanges
                .filter { range in range.location < sourceOffset }
                .reduce(0) { runningTotal, range in runningTotal + range.length }
        }

        let maximumOffset = cleanedText.count
        let orderedDirectives = directivesWithSourceOffsets.map { entry in
            let rebasedOffset = entry.sourceOffset - characterCountRemovedBefore(entry.sourceOffset)
            return TeacherDirective(
                action: entry.action,
                characterOffsetInSpokenText: max(0, min(rebasedOffset, maximumOffset))
            )
        }

        // Already in source order, and deliberately not re-sorted: clamping can
        // tie two offsets, and Swift's sort is not stable, which previously
        // scrambled numbered step sequences into 1, 3, 2.
        return ParsedTeacherResponse(spokenText: cleanedText, directives: orderedDirectives)
    }

    // MARK: - Tag interpretation

    private static func makeAction(tagName: String, payload: String) -> TeacherDirective.Action? {
        let trimmedPayload = payload.trimmingCharacters(in: .whitespaces)

        switch tagName {
        case "CLEAR", "ERASE":
            return .clearAll

        case "POINT":
            // `[POINT:none]` is upstream's way of declining to point.
            if trimmedPayload.lowercased() == "none" || trimmedPayload.isEmpty { return nil }
            if let coordinateAction = makeCoordinateAction(fromPayload: trimmedPayload) {
                return coordinateAction
            }
            return .point(targetIdentifier: normalizeIdentifier(trimmedPayload))

        case "CIRCLE":
            return .circle(targetIdentifier: normalizeIdentifier(trimmedPayload))
        case "BOX", "RECT":
            return .box(targetIdentifier: normalizeIdentifier(trimmedPayload))
        case "UNDERLINE":
            return .underline(targetIdentifier: normalizeIdentifier(trimmedPayload))
        case "HIGHLIGHT", "MARK":
            return .highlight(targetIdentifier: normalizeIdentifier(trimmedPayload))
        case "STRIKE", "STRIKETHROUGH":
            return .strikethrough(targetIdentifier: normalizeIdentifier(trimmedPayload))

        case "ARROW":
            let endpoints = trimmedPayload
                .components(separatedBy: "->")
                .map { endpoint in endpoint.trimmingCharacters(in: .whitespaces) }
                .filter { endpoint in !endpoint.isEmpty }
            // A one-ended arrow degrades to a point rather than vanishing.
            guard endpoints.count >= 2 else {
                guard let onlyEndpoint = endpoints.first else { return nil }
                return .point(targetIdentifier: normalizeIdentifier(onlyEndpoint))
            }
            return .arrow(
                fromTargetIdentifier: normalizeIdentifier(endpoints[0]),
                toTargetIdentifier: normalizeIdentifier(endpoints[1])
            )

        case "STEP":
            let components = trimmedPayload.components(separatedBy: ":")
            guard let targetComponent = components.first, !targetComponent.isEmpty else { return nil }
            let stepNumber = components.count >= 2 ? (Int(components[1].trimmingCharacters(in: .whitespaces)) ?? 1) : 1
            return .step(
                targetIdentifier: normalizeIdentifier(targetComponent),
                stepNumber: stepNumber
            )

        case "LABEL", "NOTE":
            // Split once only, so the label text may itself contain a colon.
            guard let separatorRange = trimmedPayload.range(of: ":") else { return nil }
            let targetComponent = String(trimmedPayload[..<separatorRange.lowerBound])
            let labelText = String(trimmedPayload[separatorRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !targetComponent.isEmpty, !labelText.isEmpty else { return nil }
            return .callout(
                targetIdentifier: normalizeIdentifier(targetComponent),
                text: labelText
            )

        case "BOARD":
            guard !trimmedPayload.isEmpty else { return nil }
            return .beginBoard(title: trimmedPayload)

        case "COL", "COLUMN":
            // `label:content`, where the content is optional so a column may
            // be a bare heading with nothing under it yet.
            if let separatorRange = trimmedPayload.range(of: ":") {
                let label = String(trimmedPayload[..<separatorRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let content = String(trimmedPayload[separatorRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { return nil }
                return .addBoardColumn(label: label, content: content)
            }
            guard !trimmedPayload.isEmpty else { return nil }
            return .addBoardColumn(label: trimmedPayload, content: "")

        case "BASE":
            guard !trimmedPayload.isEmpty else { return nil }
            // A base bar takes one field, but folding lines written underneath
            // it produces "label:detail". Rendered with the colon intact that
            // reads as a stray separator, so it is normalised to a readable
            // phrase instead.
            let readableLabel = trimmedPayload
                .replacingOccurrences(of: ":", with: ", ")
                .replacingOccurrences(of: ", ,", with: ",")
                .trimmingCharacters(in: .whitespaces)
            return .addBoardBase(label: readableLabel)

        case "CELLS":
            let values = trimmedPayload
                .components(separatedBy: ",")
                .map { value in value.trimmingCharacters(in: .whitespaces) }
                .filter { value in !value.isEmpty }
            guard !values.isEmpty else { return nil }
            return .addBoardCells(values: values)

        case "PTR", "POINTER":
            let components = trimmedPayload.components(separatedBy: ":")
            guard components.count >= 2 else { return nil }

            let rawPosition = components[0].trimmingCharacters(in: .whitespaces).lowercased()
            let position: BoardPointerPosition
            if let numericIndex = Int(rawPosition) {
                position = .index(numericIndex)
            } else {
                switch rawPosition {
                case "last", "end", "hi", "high", "right": position = .last
                case "first", "start", "lo", "low", "left", "begin": position = .first
                case "mid", "middle", "center", "centre", "half": position = .middle
                default: return nil
                }
            }

            let pointerName = components[1].trimmingCharacters(in: .whitespaces)
            guard !pointerName.isEmpty else { return nil }
            return .addBoardPointer(position: position, name: pointerName)

        case "DIAGRAM":
            // shape : payload, where the payload's shape depends on the shape.
            guard let separatorRange = trimmedPayload.range(of: ":") else { return nil }
            let shapeName = String(trimmedPayload[..<separatorRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let payload = String(trimmedPayload[separatorRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)

            /// Splits a comma list, dropping blanks so a trailing comma is harmless.
            func items(_ text: String) -> [String] {
                text.components(separatedBy: ",")
                    .map { item in item.trimmingCharacters(in: .whitespaces) }
                    .filter { item in !item.isEmpty }
            }

            switch shapeName {
            case "pipeline", "flow", "path":
                let steps = items(payload)
                guard steps.count >= 2 else { return nil }
                return .drawDiagram(shape: .pipeline(steps: Array(steps.prefix(6))))

            case "fanout", "fan-out", "spread":
                // source | branch,branch | sink   (sink optional)
                let groups = payload.components(separatedBy: "|")
                    .map { group in group.trimmingCharacters(in: .whitespaces) }
                guard groups.count >= 2 else { return nil }
                let branches = items(groups[1])
                guard !groups[0].isEmpty, !branches.isEmpty else { return nil }
                let sink = groups.count >= 3 && !groups[2].isEmpty ? groups[2] : nil
                return .drawDiagram(shape: .fanOut(
                    source: groups[0],
                    branches: Array(branches.prefix(4)),
                    sink: sink
                ))

            case "layers", "stack", "tiers":
                let tiers = items(payload)
                guard tiers.count >= 2 else { return nil }
                return .drawDiagram(shape: .layers(tiers: Array(tiers.prefix(5))))

            case "tree":
                // root | a,b | c,d,e,f   one group per level
                let levels = payload.components(separatedBy: "|")
                    .map { level in items(level) }
                    .filter { level in !level.isEmpty }
                guard levels.count >= 2 else { return nil }
                return .drawDiagram(shape: .tree(levels: Array(levels.prefix(4))))

            default:
                return nil
            }

        case "NODE":
            // id : column,row : widthInColumns : label [: tint]
            let fields = trimmedPayload.components(separatedBy: ":")
            guard fields.count >= 4 else { return nil }

            let identifier = fields[0].trimmingCharacters(in: .whitespaces)
            let position = fields[1].components(separatedBy: ",")
            guard !identifier.isEmpty,
                  position.count == 2,
                  let column = Int(position[0].trimmingCharacters(in: .whitespaces)),
                  let row = Int(position[1].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }

            // A width the model forgot, or wrote as a word, defaults to
            // something sane rather than discarding the node.
            let widthInColumns = Int(fields[2].trimmingCharacters(in: .whitespaces)) ?? 3
            let label = fields[3].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { return nil }

            let tint = fields.count >= 5
                ? fields[4].trimmingCharacters(in: .whitespaces).lowercased()
                : "blue"

            return .addBoardNode(
                identifier: identifier,
                column: column,
                row: row,
                widthInColumns: widthInColumns,
                label: label,
                tint: tint
            )

        case "EDGE":
            // from->to [: label]
            let parts = trimmedPayload.components(separatedBy: ":")
            let endpoints = parts[0]
                .components(separatedBy: "->")
                .map { endpoint in endpoint.trimmingCharacters(in: .whitespaces) }
                .filter { endpoint in !endpoint.isEmpty }
            guard endpoints.count >= 2 else { return nil }

            let label = parts.count >= 2
                ? parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
                : ""

            return .addBoardEdge(
                fromIdentifier: endpoints[0],
                toIdentifier: endpoints[1],
                label: label
            )

        case "CAPTION":
            guard !trimmedPayload.isEmpty else { return nil }
            return .addBoardNote(text: trimmedPayload)

        case "SPOTLIGHT", "FOCUS":
            let targetIdentifiers = trimmedPayload
                .components(separatedBy: CharacterSet(charactersIn: ", "))
                .map { identifier in normalizeIdentifier(identifier) }
                .filter { identifier in !identifier.isEmpty }
            guard !targetIdentifiers.isEmpty else { return nil }
            return .spotlight(targetIdentifiers: targetIdentifiers)

        default:
            return nil
        }
    }

    /// Strips decoration a model may add around an identifier.
    ///
    /// Measured behaviour: the 4B model emits bare `t23` reliably but sometimes
    /// wraps it in backticks or trailing punctuation. Normalising here is
    /// cheaper than trying to prompt the habit away.
    private static func normalizeIdentifier(_ rawIdentifier: String) -> String {
        rawIdentifier.trimmingCharacters(
            in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "_"))
        )
    }

    private static func makeCoordinateAction(fromPayload payload: String) -> TeacherDirective.Action? {
        let payloadAsNSString = payload as NSString
        guard let match = coordinatePayloadPattern.firstMatch(
            in: payload,
            options: [],
            range: NSRange(location: 0, length: payloadAsNSString.length)
        ),
            let xCoordinate = Double(payloadAsNSString.substring(with: match.range(at: 1))),
            let yCoordinate = Double(payloadAsNSString.substring(with: match.range(at: 2))) else {
            return nil
        }

        var label = ""
        if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
            label = payloadAsNSString.substring(with: match.range(at: 3))
        }

        var displayIndex = 1
        if match.numberOfRanges >= 5, match.range(at: 4).location != NSNotFound {
            displayIndex = Int(payloadAsNSString.substring(with: match.range(at: 4))) ?? 1
        }

        return .pointAtCoordinate(
            x: xCoordinate,
            y: yCoordinate,
            label: label,
            displayIndex: displayIndex
        )
    }

    // MARK: - Text preparation

    /// Collapses the gaps left behind by removed tags, and strips markdown.
    ///
    /// Markdown is banned in the prompt and the model emits it anyway: its
    /// first real answer used blockquotes to read the screen back. Every one
    /// of those characters is spoken aloud, so they are removed here rather
    /// than left to the model's good behaviour.
    private static func tidyWhitespace(in text: String) -> String {
        var tidied = text

        // Blockquote and heading markers at the start of a line.
        tidied = tidied.replacingOccurrences(
            of: "(?m)^\\s*[>#]+\\s*",
            with: "",
            options: .regularExpression
        )
        // Bullet markers, which otherwise get read out as "dash".
        tidied = tidied.replacingOccurrences(
            of: "(?m)^\\s*[-*•]\\s+",
            with: "",
            options: .regularExpression
        )
        // Bold and italic markers.
        tidied = tidied.replacingOccurrences(
            of: "\\*{1,3}([^*]+)\\*{1,3}",
            with: "$1",
            options: .regularExpression
        )
        // Backticks around code, which are silent but make the voice stumble.
        tidied = tidied.replacingOccurrences(of: "`", with: "")
        // An em or en dash used as punctuation reads as a hard stop.
        tidied = tidied.replacingOccurrences(
            of: "\\s*[—–]\\s*",
            with: ", ",
            options: .regularExpression
        )

        // Sentences that only announce what is about to happen. The prompt
        // bans these and the model writes them anyway, and once the board is
        // drawing, "let me show you" is both filler and a lie: the showing is
        // already happening. Matched whole and exactly, so a sentence that
        // merely begins with these words is left alone.
        let pureAnnouncementSentences = [
            "let me show you", "let's take a look", "let me explain",
            "here's what i mean", "let's break this down", "let me walk you through",
            "let's walk through this", "here's the thing", "let me draw this",
            "let's picture this", "i'll show you"
        ]
        for announcement in pureAnnouncementSentences {
            tidied = tidied.replacingOccurrences(
                of: "(?i)(^|[.!?]\\s+)\(NSRegularExpression.escapedPattern(for: announcement))[.!]?(\\s+|$)",
                with: "$1",
                options: .regularExpression
            )
        }

        tidied = tidied.replacingOccurrences(
            of: "[ \\t]{2,}",
            with: " ",
            options: .regularExpression
        )
        // A tag sitting before punctuation leaves " ." behind.
        tidied = tidied.replacingOccurrences(
            of: "\\s+([,.;:!?])",
            with: "$1",
            options: .regularExpression
        )
        tidied = tidied.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        return tidied.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the portion of a growing stream that is safe to speak now.
    ///
    /// Only complete sentences are handed over, because speaking a half
    /// sentence forces an unnatural pause exactly where meaning is carried.
    /// This is what lets speech start while the model is still generating,
    /// which is the whole reason the local pipeline feels responsive.
    static func nextSpeakableChunk(
        fromStreamedText streamedText: String,
        alreadySpokenCharacterCount: Int
    ) -> String? {
        guard alreadySpokenCharacterCount < streamedText.count else { return nil }

        let startIndex = streamedText.index(
            streamedText.startIndex,
            offsetBy: alreadySpokenCharacterCount
        )
        let remainingText = String(streamedText[startIndex...])

        // Anything after the last terminator is still being generated and is
        // held back until it completes.
        guard let lastTerminatorIndex = remainingText.lastIndex(where: { character in
            character == "." || character == "!" || character == "?" || character == "\n"
        }) else {
            return nil
        }

        let completedPortion = String(remainingText[...lastTerminatorIndex])
        return completedPortion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : completedPortion
    }
}
