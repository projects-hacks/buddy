//
//  ScreenIndex.swift
//  leanring-buddy
//
//  Builds a numbered inventory of everything addressable on screen, so the
//  model can name a target by identifier instead of estimating pixels.
//
//  Why this exists: the hosted build asks Claude's Computer Use tool for raw
//  (x, y) coordinates, which leans on pixel-counting training that a locally
//  run model does not have. Study material makes that worse, because the
//  targets are small and dense: one line in a code block, one node in a
//  diagram. Rather than ask a local model to do the thing it is weakest at,
//  this splits the job in two. macOS locates things exactly, via on-device
//  text recognition and the accessibility tree. The model only has to choose
//  which of those things to mark, which is a selection problem it handles well.
//
//  It turned out to matter for more than pointing. Measured on this machine,
//  a 4B model given only a screenshot of a binary search blamed integer
//  overflow, a defect Python cannot have, having pattern matched the familiar
//  Java bug. Given the same screenshot plus this listing, it found the real
//  off-by-one. Small models misread dense code from pixels and fail
//  confidently, so the recognised text goes into every prompt, not just the
//  ones that end in a mark.
//

import AppKit
import ApplicationServices
import Foundation
import Vision

/// One addressable thing on screen, carrying the exact rectangle macOS reported.
struct ScreenTarget: Identifiable {
    /// How this target was located, which says how much to trust its rectangle.
    enum LocationSource {
        /// Recognised by on-device text recognition. Rectangle hugs the glyphs.
        case recognizedText
        /// Read from the accessibility tree. Rectangle is the control's real frame.
        case accessibilityElement
    }

    /// Short identifier handed to the model, for example `t42`. Stable only
    /// within the index it was built in, because the screen keeps changing.
    let id: String

    /// The text a user would recognise, which is how the model picks this target.
    let displayedText: String

    /// Rectangle in display-local AppKit points, bottom-left origin, matching
    /// what the overlay expects for cursor and annotation placement.
    let boundsInDisplayPoints: CGRect

    let displayIndex: Int
    let locationSource: LocationSource

    /// Recogniser confidence, 0...1. Always 1 for accessibility elements,
    /// whose frames are authoritative rather than inferred.
    let confidence: Float
}

/// Builds and resolves `ScreenTarget` inventories for the current screen.
///
/// Main-actor isolated because the accessibility API is read against the
/// frontmost application and the results feed SwiftUI state directly. The
/// expensive part, text recognition, is explicitly pushed off this actor.
@MainActor
final class ScreenIndex {
    /// Targets from the most recent build, keyed for tag resolution.
    private var targetsByIdentifier: [String: ScreenTarget] = [:]

    /// Ordered targets from the most recent build, for prompt rendering.
    private(set) var orderedTargets: [ScreenTarget] = []

    /// Upper bound on accessibility traversal depth.
    ///
    /// Browsers and Electron apps nest extremely deeply, and an unbounded walk
    /// stalls the voice loop. Twelve levels reaches real controls in practice.
    private static let maximumAccessibilityDepth = 12

    /// Upper bound on indexed accessibility elements, bounding both the walk
    /// and the prompt it feeds.
    private static let maximumAccessibilityElements = 250

    /// Text shorter than this is dropped, since stray single glyphs are
    /// recogniser noise rather than something a learner would ask about.
    private static let minimumRecognizedTextLength = 2

    // MARK: - Building

    /// Rebuilds the index for one display from its screenshot.
    ///
    /// The two sources are complementary. Recognition catches rendered content
    /// such as diagrams, PDFs and video frames that expose no accessibility
    /// information, while the accessibility tree catches real controls whose
    /// frames are exact rather than inferred from glyphs.
    func rebuild(
        fromScreenshot screenshotData: Data,
        displayIndex: Int,
        displayBoundsInPoints: CGSize,
        includeAccessibilityElements: Bool = true
    ) async {
        var collectedTargets: [ScreenTarget] = []
        var nextIdentifierNumber = 1

        let recognizedLines = await Self.performTextRecognition(onScreenshotData: screenshotData)

        for recognizedLine in recognizedLines {
            // Vision reports a normalised rectangle with a bottom-left origin,
            // which already matches AppKit, so this is a scale with no flip.
            let boundsInPoints = CGRect(
                x: recognizedLine.normalizedBounds.origin.x * displayBoundsInPoints.width,
                y: recognizedLine.normalizedBounds.origin.y * displayBoundsInPoints.height,
                width: recognizedLine.normalizedBounds.size.width * displayBoundsInPoints.width,
                height: recognizedLine.normalizedBounds.size.height * displayBoundsInPoints.height
            )

            collectedTargets.append(
                ScreenTarget(
                    id: "t\(nextIdentifierNumber)",
                    displayedText: recognizedLine.text,
                    boundsInDisplayPoints: boundsInPoints,
                    displayIndex: displayIndex,
                    locationSource: .recognizedText,
                    confidence: recognizedLine.confidence
                )
            )
            nextIdentifierNumber += 1
        }

        if includeAccessibilityElements, AXIsProcessTrusted() {
            let accessibilityTargets = accessibilityTargetsForFrontmostApplication(
                displayIndex: displayIndex,
                displayBoundsInPoints: displayBoundsInPoints,
                startingIdentifierNumber: &nextIdentifierNumber
            )
            collectedTargets.append(contentsOf: accessibilityTargets)
        }

        orderedTargets = collectedTargets
        targetsByIdentifier = Dictionary(
            collectedTargets.map { target in (target.id, target) },
            uniquingKeysWith: { first, _ in first }
        )

        TutorDebugLog.write("🗂️ ScreenIndex: \(collectedTargets.count) targets (\(recognizedLines.count) recognised text)")
    }

    // MARK: - On-device text recognition

    /// One line of recognised text, in normalised image coordinates.
    private struct RecognizedLine: Sendable {
        let text: String
        let normalizedBounds: CGRect
        let confidence: Float
    }

    /// Runs Apple's text recogniser off the main actor.
    ///
    /// `VNImageRequestHandler.perform` is synchronous and takes hundreds of
    /// milliseconds on a full-resolution screenshot. Running it inline would
    /// stall the overlay animation at exactly the moment the user is waiting
    /// for an answer, so it is pushed to a detached task and only the small
    /// Sendable result comes back.
    private static func performTextRecognition(
        onScreenshotData screenshotData: Data
    ) async -> [RecognizedLine] {
        await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(data: screenshotData),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("⚠️ ScreenIndex: could not decode screenshot for recognition")
                return []
            }

            let textRequest = VNRecognizeTextRequest()
            // Accurate over fast: targets here are small, and a missed code
            // line costs more than a few hundred milliseconds in a study session.
            textRequest.recognitionLevel = .accurate
            // Language correction fights us on code, where tokens such as
            // `nums[i]` are not words and must not be autocorrected.
            textRequest.usesLanguageCorrection = false

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([textRequest])
            } catch {
                print("⚠️ ScreenIndex: text recognition failed: \(error.localizedDescription)")
                return []
            }

            guard let observations = textRequest.results else { return [] }

            return observations.compactMap { observation -> RecognizedLine? in
                guard let bestCandidate = observation.topCandidates(1).first else { return nil }

                let recognizedString = bestCandidate.string
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard recognizedString.count >= minimumRecognizedTextLength else { return nil }

                // Drop bare short numbers. In practice these are the line-number
                // gutter of a code block, which produced one useless target per
                // line and crowded out real content in the prompt. Anything with
                // a non-digit survives, so "94%" and "O(1)" are kept.
                let isBareShortNumber = recognizedString.count <= 3
                    && recognizedString.allSatisfy { character in character.isNumber }
                guard !isBareShortNumber else { return nil }

                return RecognizedLine(
                    text: recognizedString,
                    normalizedBounds: observation.boundingBox,
                    confidence: bestCandidate.confidence
                )
            }
        }.value
    }

    // MARK: - Accessibility tree

    /// Walks the frontmost application's accessibility tree for labelled controls.
    ///
    /// Requires Accessibility permission. Without it this returns nothing and
    /// the index falls back to recognised text, which still covers study content.
    private func accessibilityTargetsForFrontmostApplication(
        displayIndex: Int,
        displayBoundsInPoints: CGSize,
        startingIdentifierNumber: inout Int
    ) -> [ScreenTarget] {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return [] }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var collectedTargets: [ScreenTarget] = []

        appendAccessibilityTargets(
            from: applicationElement,
            currentDepth: 0,
            displayIndex: displayIndex,
            displayBoundsInPoints: displayBoundsInPoints,
            startingIdentifierNumber: &startingIdentifierNumber,
            into: &collectedTargets
        )

        return collectedTargets
    }

    private func appendAccessibilityTargets(
        from element: AXUIElement,
        currentDepth: Int,
        displayIndex: Int,
        displayBoundsInPoints: CGSize,
        startingIdentifierNumber: inout Int,
        into collectedTargets: inout [ScreenTarget]
    ) {
        guard currentDepth <= Self.maximumAccessibilityDepth,
              collectedTargets.count < Self.maximumAccessibilityElements else {
            return
        }

        if let label = accessibilityLabel(for: element),
           let frameInGlobalPoints = accessibilityFrame(for: element) {
            // Zero-sized and full-window frames are container artifacts rather
            // than things a learner can usefully be shown.
            let isPointableSize = frameInGlobalPoints.width >= 8
                && frameInGlobalPoints.height >= 8
                && frameInGlobalPoints.width <= displayBoundsInPoints.width
                && frameInGlobalPoints.height <= displayBoundsInPoints.height

            if isPointableSize {
                collectedTargets.append(
                    ScreenTarget(
                        id: "a\(startingIdentifierNumber)",
                        displayedText: label,
                        boundsInDisplayPoints: convertGlobalFrameToDisplayLocalPoints(
                            frameInGlobalPoints,
                            displayBoundsInPoints: displayBoundsInPoints
                        ),
                        displayIndex: displayIndex,
                        locationSource: .accessibilityElement,
                        confidence: 1.0
                    )
                )
                startingIdentifierNumber += 1
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success, let children = childrenValue as? [AXUIElement] else {
            return
        }

        for childElement in children {
            appendAccessibilityTargets(
                from: childElement,
                currentDepth: currentDepth + 1,
                displayIndex: displayIndex,
                displayBoundsInPoints: displayBoundsInPoints,
                startingIdentifierNumber: &startingIdentifierNumber,
                into: &collectedTargets
            )
        }
    }

    /// Picks the most human-meaningful label available on an element.
    private func accessibilityLabel(for element: AXUIElement) -> String? {
        let preferredAttributes = [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXValueAttribute
        ]

        for attributeName in preferredAttributes {
            var attributeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                attributeName as CFString,
                &attributeValue
            ) == .success else { continue }

            guard let stringValue = attributeValue as? String else { continue }

            let trimmedValue = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Long values are document bodies rather than labels and would
            // swamp the prompt. Recognised text already covers that content.
            if trimmedValue.count >= 2 && trimmedValue.count <= 120 {
                return trimmedValue
            }
        }

        return nil
    }

    /// Reads an element's on-screen frame in global, top-left-origin points.
    private func accessibilityFrame(for element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success else {
            return nil
        }

        var elementOrigin = CGPoint.zero
        var elementSize = CGSize.zero

        // A conditional cast to a CoreFoundation type always succeeds, so the
        // type has to be verified by its CFTypeID before the cast. An element
        // can legitimately return a non-AXValue here, and force-casting that
        // without the check would crash rather than skip the element.
        guard let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue

        guard AXValueGetValue(positionAXValue, .cgPoint, &elementOrigin),
              AXValueGetValue(sizeAXValue, .cgSize, &elementSize) else {
            return nil
        }

        return CGRect(origin: elementOrigin, size: elementSize)
    }

    /// Flips an accessibility frame from global top-left origin into
    /// display-local bottom-left origin, which is what the overlay draws in.
    private func convertGlobalFrameToDisplayLocalPoints(
        _ globalFrame: CGRect,
        displayBoundsInPoints: CGSize
    ) -> CGRect {
        let flippedOriginY = displayBoundsInPoints.height - globalFrame.origin.y - globalFrame.height
        return CGRect(
            x: globalFrame.origin.x,
            y: flippedOriginY,
            width: globalFrame.width,
            height: globalFrame.height
        )
    }

    // MARK: - Prompt rendering and resolution

    /// Renders the index as a compact listing for the model's prompt.
    ///
    /// Terse on purpose: this rides along with a screenshot on every turn, and
    /// a 16 GB machine cannot spare context on formatting.
    func renderForPrompt(maximumTargets: Int = 120) -> String {
        guard !orderedTargets.isEmpty else {
            return "(no text could be read from the screen)"
        }

        // Recognised text comes first, always.
        //
        // This was previously ranked by confidence alone, which quietly broke
        // the feature on a real screen. Accessibility elements are assigned a
        // confidence of 1 because their rectangles are exact, so on a browser
        // page the 107 of them outranked all 62 recognised lines and filled
        // almost the whole listing with window chrome. The model could see the
        // study material in the screenshot, found no id for any of it, and
        // started inventing ids, which is what produced a spotlight over
        // sixteen imaginary targets.
        //
        // Exact rectangles are not the same as useful targets. What the
        // student is studying is the text on the page, so that is ranked
        // first, and the controls around it get whatever room is left.
        let recognisedTextTargets = orderedTargets
            .filter { target in target.locationSource == .recognizedText }
            .sorted { firstTarget, secondTarget in
                firstTarget.confidence > secondTarget.confidence
            }

        // Anything the recogniser already found is dropped from the control
        // list, since a button whose label was read anyway would otherwise
        // appear twice under two different ids and invite the model to mark
        // the wrong one.
        let alreadyListedText = Set(recognisedTextTargets.map { target in
            target.displayedText.lowercased()
        })
        let accessibilityTargets = orderedTargets
            .filter { target in
                target.locationSource == .accessibilityElement
                    && !alreadyListedText.contains(target.displayedText.lowercased())
            }

        // Controls are capped well below the overall limit so they can never
        // squeeze out the content again, however many a page exposes.
        let accessibilityAllowance = max(0, min(accessibilityTargets.count, maximumTargets / 4))
        let textAllowance = maximumTargets - accessibilityAllowance

        let targetsForPrompt = Array(recognisedTextTargets.prefix(textAllowance))
            + Array(accessibilityTargets.prefix(accessibilityAllowance))

        return targetsForPrompt.map { target in
            // Collapse newlines so one target stays on one line and the
            // listing cannot be mistaken for free-form text.
            let singleLineText = target.displayedText
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            return "\(target.id): \(singleLineText)"
        }
        .joined(separator: "\n")
    }

    /// Resolves an identifier the model emitted back to its exact rectangle.
    /// Returns nil for an identifier that was invented rather than chosen.
    func target(forIdentifier identifier: String) -> ScreenTarget? {
        targetsByIdentifier[identifier.trimmingCharacters(in: .whitespaces)]
    }

    /// Recovers a target from the words surrounding a mark when its id is bogus.
    ///
    /// Observed failure this exists for: asked to walk through a five-box
    /// diagram, the 4B wrote "the client [POINT:t1] and the load balancer
    /// [POINT:t2]", numbering its own list instead of copying ids from the
    /// listing, where those boxes were t11 and t12. Every such mark resolves to
    /// nothing and the explanation plays with a blank screen.
    ///
    /// The words are more reliable than the id, because the model is describing
    /// what it genuinely sees even when it miscopies the label. So when an id
    /// misses, the phrase being spoken is searched for the longest piece of
    /// indexed text it contains, and that target is used instead.
    func bestTextMatch(forSpokenPhrase phrase: String) -> ScreenTarget? {
        let searchablePhrase = phrase.lowercased()
        guard !searchablePhrase.isEmpty else { return nil }

        var bestMatch: (target: ScreenTarget, matchedLength: Int)?

        for candidate in orderedTargets {
            let candidateText = candidate.displayedText
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Very short strings match far too easily. Three characters is
            // where a match starts carrying real information.
            guard candidateText.count >= 3,
                  searchablePhrase.contains(candidateText) else { continue }

            // Longest match wins: "load balancer" should beat "load".
            if bestMatch == nil || candidateText.count > bestMatch!.matchedLength {
                bestMatch = (candidate, candidateText.count)
            }
        }

        return bestMatch?.target
    }

    /// Clears the index once an interaction ends, since the rectangles describe
    /// a screen state that has probably already changed.
    func clear() {
        orderedTargets = []
        targetsByIdentifier = [:]
    }
}
