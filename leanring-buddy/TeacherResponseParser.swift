//
//  TeacherResponseParser.swift
//  leanring-buddy
//
//  Splits a model response into the words that get spoken and the on-screen
//  actions that accompany them, keeping the two aligned in time.
//
//  Why the character offsets matter: `AVSpeechSynthesizer` reports the range of
//  each word as it speaks it. Recording where a tag sat in the spoken text lets
//  a circle appear exactly as the sentence describing it is said, instead of
//  every annotation firing at once before the explanation has started. That
//  timing is most of the difference between a teacher at a whiteboard and a
//  diagram that simply appears.
//

import Foundation

/// One thing the tutor should do on screen while speaking.
struct TeacherDirective {
    enum Action {
        /// Fly the cursor to a target and rest there.
        case point(targetIdentifier: String)
        /// Draw an ellipse around a target.
        case circle(targetIdentifier: String)
        /// Underline a target, for a line of code or a phrase.
        case underline(targetIdentifier: String)
        /// Draw a rectangle around a target, for a region or diagram node.
        case box(targetIdentifier: String)
        /// Draw an arrow from one target to another, for showing flow.
        case arrow(fromTargetIdentifier: String, toTargetIdentifier: String)
        /// Fall back to an explicit coordinate when no indexed target fits,
        /// preserving the original upstream tag format.
        case pointAtCoordinate(x: Double, y: Double, label: String, displayIndex: Int)
    }

    let action: Action

    /// Index into `ParsedTeacherResponse.spokenText` where this tag appeared.
    /// Speech reaching this offset is the cue to perform the action.
    let characterOffsetInSpokenText: Int
}

/// A model response separated into speech and on-screen actions.
struct ParsedTeacherResponse {
    /// The response with every tag removed. This is what gets spoken and shown
    /// as text, so a malformed tag can never be read aloud to the user.
    let spokenText: String

    /// Actions in the order they should happen, each tied to a speech offset.
    let directives: [TeacherDirective]

    /// Sentence ranges over `spokenText`, used to start speaking before the
    /// model has finished generating.
    let sentenceRanges: [Range<String.Index>]
}

/// Parses tagged tutor responses and prepares them for speech.
enum TeacherResponseParser {

    /// Matches the identifier-based tags this build prefers, for example
    /// `[POINT:t42]`, `[CIRCLE:a7]` or `[ARROW:t12->t15]`.
    private static let identifierTagPattern = try! NSRegularExpression(
        pattern: #"\[(POINT|CIRCLE|UNDERLINE|BOX|ARROW):([A-Za-z0-9_]+)(?:\s*->\s*([A-Za-z0-9_]+))?\]"#,
        options: [.caseInsensitive]
    )

    /// Matches the upstream coordinate tag, `[POINT:x,y:label:screenN]`.
    ///
    /// Kept so a model that ignores the screen index and emits raw coordinates
    /// still produces a usable gesture rather than a tag read aloud as text.
    private static let coordinateTagPattern = try! NSRegularExpression(
        pattern: #"\[POINT:\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*:([^:\]]*):screen(\d+)\]"#,
        options: [.caseInsensitive]
    )

    /// Removes tags from `rawResponse` and returns them alongside the clean text.
    static func parse(rawResponse: String) -> ParsedTeacherResponse {
        var workingText = rawResponse
        var collectedDirectives: [TeacherDirective] = []

        // Coordinate tags are resolved first because their syntax overlaps the
        // identifier form on the `[POINT:` prefix, and the more specific
        // pattern has to claim its matches before the looser one runs.
        workingText = extractDirectives(
            using: coordinateTagPattern,
            from: workingText,
            into: &collectedDirectives,
            buildAction: makeCoordinateAction
        )

        workingText = extractDirectives(
            using: identifierTagPattern,
            from: workingText,
            into: &collectedDirectives,
            buildAction: makeIdentifierAction
        )

        let cleanedText = tidyWhitespace(in: workingText)

        // Offsets were recorded against the pre-tidy text. Clamp them so a
        // collapsed double space can never push an offset past the end.
        let maximumOffset = cleanedText.count
        let clampedDirectives = collectedDirectives
            .map { directive in
                TeacherDirective(
                    action: directive.action,
                    characterOffsetInSpokenText: min(directive.characterOffsetInSpokenText, maximumOffset)
                )
            }
            .sorted { firstDirective, secondDirective in
                firstDirective.characterOffsetInSpokenText < secondDirective.characterOffsetInSpokenText
            }

        return ParsedTeacherResponse(
            spokenText: cleanedText,
            directives: clampedDirectives,
            sentenceRanges: sentenceRanges(in: cleanedText)
        )
    }

    // MARK: - Tag extraction

    /// Walks matches back to front so removing one cannot shift the ranges of
    /// those not yet processed.
    private static func extractDirectives(
        using pattern: NSRegularExpression,
        from text: String,
        into collectedDirectives: inout [TeacherDirective],
        buildAction: (NSTextCheckingResult, NSString) -> TeacherDirective.Action?
    ) -> String {
        let mutableText = NSMutableString(string: text)
        let fullRange = NSRange(location: 0, length: mutableText.length)
        let matches = pattern.matches(in: text, options: [], range: fullRange)

        for match in matches.reversed() {
            guard let action = buildAction(match, mutableText as NSString) else { continue }

            collectedDirectives.append(
                TeacherDirective(
                    action: action,
                    characterOffsetInSpokenText: match.range.location
                )
            )
            mutableText.replaceCharacters(in: match.range, with: "")
        }

        return mutableText as String
    }

    private static func makeIdentifierAction(
        from match: NSTextCheckingResult,
        in text: NSString
    ) -> TeacherDirective.Action? {
        guard match.numberOfRanges >= 3 else { return nil }

        let tagName = text.substring(with: match.range(at: 1)).uppercased()
        let primaryIdentifier = text.substring(with: match.range(at: 2))

        switch tagName {
        case "POINT":
            return .point(targetIdentifier: primaryIdentifier)
        case "CIRCLE":
            return .circle(targetIdentifier: primaryIdentifier)
        case "UNDERLINE":
            return .underline(targetIdentifier: primaryIdentifier)
        case "BOX":
            return .box(targetIdentifier: primaryIdentifier)
        case "ARROW":
            // An arrow needs both ends; a one-ended arrow is treated as a
            // point so the gesture degrades rather than disappearing.
            guard match.numberOfRanges >= 4,
                  match.range(at: 3).location != NSNotFound else {
                return .point(targetIdentifier: primaryIdentifier)
            }
            let destinationIdentifier = text.substring(with: match.range(at: 3))
            return .arrow(
                fromTargetIdentifier: primaryIdentifier,
                toTargetIdentifier: destinationIdentifier
            )
        default:
            return nil
        }
    }

    private static func makeCoordinateAction(
        from match: NSTextCheckingResult,
        in text: NSString
    ) -> TeacherDirective.Action? {
        guard match.numberOfRanges >= 5,
              let xCoordinate = Double(text.substring(with: match.range(at: 1))),
              let yCoordinate = Double(text.substring(with: match.range(at: 2))),
              let displayIndex = Int(text.substring(with: match.range(at: 4))) else {
            return nil
        }

        return .pointAtCoordinate(
            x: xCoordinate,
            y: yCoordinate,
            label: text.substring(with: match.range(at: 3)),
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

    /// Splits text into sentences so speech can begin on the first complete
    /// one rather than waiting for the whole response.
    ///
    /// Uses the system's linguistic sentence segmentation rather than splitting
    /// on periods, which would break on decimals and on the abbreviations that
    /// turn up constantly in this material, such as "O(n log n)" or "etc.".
    static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .localized]
        ) { _, substringRange, _, _ in
            ranges.append(substringRange)
        }

        // Segmentation yields nothing for a fragment with no terminator, which
        // is the normal case mid-stream. Treat the whole fragment as one unit.
        return ranges.isEmpty ? [text.startIndex..<text.endIndex] : ranges
    }

    /// Returns the portion of a growing stream that is safe to speak now.
    ///
    /// Only complete sentences are handed over, because speaking a half
    /// sentence forces an unnatural pause exactly where meaning is carried.
    /// `alreadySpokenCharacterCount` is how much has been dispatched so far.
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

        // Find the last sentence terminator in what has arrived. Anything after
        // it is still being generated and is held back until it completes.
        guard let lastTerminatorIndex = remainingText.lastIndex(where: { character in
            character == "." || character == "!" || character == "?" || character == "\n"
        }) else {
            return nil
        }

        let completedPortion = String(remainingText[...lastTerminatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return completedPortion.isEmpty ? nil : completedPortion
    }
}
