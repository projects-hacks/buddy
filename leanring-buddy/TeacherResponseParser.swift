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
        /// Fall back to an explicit coordinate when no indexed target fits,
        /// preserving the upstream tag format.
        case pointAtCoordinate(x: Double, y: Double, label: String, displayIndex: Int)
    }

    let action: Action

    /// Index into `ParsedTeacherResponse.spokenText` where this tag appeared.
    /// Speech reaching this offset is the cue to draw the mark.
    let characterOffsetInSpokenText: Int
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
        "SPOTLIGHT", "FOCUS", "CLEAR", "ERASE"
    ]

    /// Removes tags from `rawResponse` and returns them alongside the clean text.
    static func parse(rawResponse: String) -> ParsedTeacherResponse {
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

    /// Collapses the gaps left behind by removed tags.
    private static func tidyWhitespace(in text: String) -> String {
        var tidied = text.replacingOccurrences(
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
