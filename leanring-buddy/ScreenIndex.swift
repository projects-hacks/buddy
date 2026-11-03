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
//  which of those things to point at, which is a selection problem it handles
//  well. The model emits `[POINT:t42]`, and the exact rectangle is looked up here.
//

import AppKit
import ApplicationServices
import Foundation
import Vision

/// One addressable thing on screen, carrying the exact rectangle macOS reported for it.
struct ScreenTarget: Identifiable {
    /// How this target was located, which determines how much to trust its rectangle.
    enum LocationSource {
        /// Recognized by on-device text recognition. Rectangle is tight to the glyphs.
        case recognizedText
        /// Read from the accessibility tree. Rectangle is the control's real frame.
        case accessibilityElement
    }

    /// Short identifier handed to the model, for example `t42`. Stable only
    /// within the index it was built in, because the screen changes constantly.
    let id: String

    /// The text the user would recognize, used by the model to pick this target.
    let displayedText: String

    /// Rectangle in display-local AppKit points, bottom-left origin, matching
    /// what `OverlayWindow` expects for cursor and annotation placement.
    let boundsInDisplayPoints: CGRect

    /// Which connected display this target lives on.
    let displayIndex: Int

    let locationSource: LocationSource

    /// Recognizer confidence, 0...1. Always 1 for accessibility elements,
    /// whose frames are authoritative rather than inferred.
    let confidence: Float

    /// Center point for the cursor to fly to, in display-local AppKit points.
    var centerInDisplayPoints: CGPoint {
        CGPoint(x: boundsInDisplayPoints.midX, y: boundsInDisplayPoints.midY)
    }
}

/// Builds and resolves `ScreenTarget` inventories for the current screen contents.
///
/// Everything here runs on-device with no network involvement, which is what
/// lets the pointing path stay accurate without a hosted model.
final class ScreenIndex {
    /// Targets from the most recent build, keyed by identifier for tag resolution.
    private var targetsByIdentifier: [String: ScreenTarget] = [:]

    /// Ordered targets from the most recent build, for prompt rendering.
    private(set) var orderedTargets: [ScreenTarget] = []

    /// Upper bound on accessibility-tree traversal depth.
    ///
    /// Browsers and Electron apps nest extremely deeply, and an unbounded walk
    /// stalls the voice loop. Twelve levels reaches real controls in practice.
    private static let maximumAccessibilityDepth = 12

    /// Upper bound on indexed elements, to keep the prompt and the walk bounded.
    private static let maximumAccessibilityElements = 250

    /// Text shorter than this is dropped, since single stray glyphs are usually
    /// recognizer noise rather than something a learner would ask about.
    private static let minimumRecognizedTextLength = 2

    // MARK: - Building

    /// Rebuilds the index for one display from its screenshot.
    ///
    /// Text recognition runs against the captured image; accessibility elements
    /// are read live from the frontmost application. The two sources are
    /// complementary: recognition catches rendered content such as diagrams,
    /// PDFs and video frames that expose no accessibility information, while the
    /// accessibility tree catches real controls whose frames are exact.
    func rebuild(
        fromScreenshot screenshotData: Data,
        displayIndex: Int,
        displayBoundsInPoints: CGSize,
        includeAccessibilityElements: Bool = true
    ) async {
        var collectedTargets: [ScreenTarget] = []
        var nextIdentifierNumber = 1

        let recognizedTextTargets = await recognizeText(
            inScreenshot: screenshotData,
            displayIndex: displayIndex,
            displayBoundsInPoints: displayBoundsInPoints,
            startingIdentifierNumber: &nextIdentifierNumber
        )
        collectedTargets.append(contentsOf: recognizedTextTargets)

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

        print("🗂️ ScreenIndex: \(collectedTargets.count) targets on display \(displayIndex) " +
              "(\(recognizedTextTargets.count) recognized text)")
    }

    // MARK: - On-device text recognition

    /// Runs Apple's text recognizer over the screenshot and converts each
    /// observation into a display-local rectangle.
    private func recognizeText(
        inScreenshot screenshotData: Data,
        displayIndex: Int,
        displayBoundsInPoints: CGSize,
        startingIdentifierNumber: inout Int
    ) async -> [ScreenTarget] {
        guard let image = NSImage(data: screenshotData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("⚠️ ScreenIndex: could not decode screenshot for text recognition")
            return []
        }

        let textRequest = VNRecognizeTextRequest()
        // Accurate over fast: the targets here are small, and a missed code line
        // is worse than a few hundred extra milliseconds in a study session.
        textRequest.recognitionLevel = .accurate
        // Language correction fights us on code and identifiers, where tokens
        // like `nums[i]` are not words and should not be autocorrected.
        textRequest.usesLanguageCorrection = false

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try requestHandler.perform([textRequest])
        } catch {
            print("⚠️ ScreenIndex: text recognition failed: \(error.localizedDescription)")
            return []
        }

        guard let observations = textRequest.results else { return [] }

        var recognizedTargets: [ScreenTarget] = []

        for observation in observations {
            guard let bestCandidate = observation.topCandidates(1).first else { continue }

            let recognizedString = bestCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard recognizedString.count >= Self.minimumRecognizedTextLength else { continue }

            // Vision reports a normalized rectangle with a bottom-left origin,
            // which already matches AppKit's convention, so this is a straight
            // scale up to display points with no vertical flip.
            let normalizedBounds = observation.boundingBox
            let boundsInPoints = CGRect(
                x: normalizedBounds.origin.x * displayBoundsInPoints.width,
                y: normalizedBounds.origin.y * displayBoundsInPoints.height,
                width: normalizedBounds.size.width * displayBoundsInPoints.width,
                height: normalizedBounds.size.height * displayBoundsInPoints.height
            )

            recognizedTargets.append(
                ScreenTarget(
                    id: "t\(startingIdentifierNumber)",
                    displayedText: recognizedString,
                    boundsInDisplayPoints: boundsInPoints,
                    displayIndex: displayIndex,
                    locationSource: .recognizedText,
                    confidence: bestCandidate.confidence
                )
            )
            startingIdentifierNumber += 1
        }

        return recognizedTargets
    }

    // MARK: - Accessibility tree

    /// Walks the frontmost application's accessibility tree for labeled controls.
    ///
    /// Requires Accessibility permission. Without it this returns nothing and the
    /// index falls back to recognized text alone, which still covers study content.
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
            // Zero-sized and absurdly large frames are container artifacts
            // rather than things a learner can be pointed at.
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
            // Long values are document bodies rather than labels, and would
            // swamp the prompt. Recognized text already covers that content.
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

        guard let positionAXValue = positionValue as? AXValue,
              let sizeAXValue = sizeValue as? AXValue,
              AXValueGetValue(positionAXValue, .cgPoint, &elementOrigin),
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
    /// Kept terse on purpose: this rides along with a screenshot on every turn,
    /// and a 16 GB machine cannot spare context on pretty formatting.
    func renderForPrompt(maximumTargets: Int = 120) -> String {
        guard !orderedTargets.isEmpty else {
            return "No addressable screen targets were detected."
        }

        // Highest-confidence first, so truncation drops the least reliable
        // entries rather than whatever happened to be recognized last.
        let targetsForPrompt = orderedTargets
            .sorted { firstTarget, secondTarget in
                firstTarget.confidence > secondTarget.confidence
            }
            .prefix(maximumTargets)

        let renderedLines = targetsForPrompt.map { target in
            // Collapse newlines so one target stays on one line and the
            // listing cannot be confused for free-form text.
            let singleLineText = target.displayedText
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            return "\(target.id): \(singleLineText)"
        }

        return renderedLines.joined(separator: "\n")
    }

    /// Resolves an identifier the model emitted back to its exact rectangle.
    /// Returns nil for an identifier that was invented rather than chosen.
    func target(forIdentifier identifier: String) -> ScreenTarget? {
        targetsByIdentifier[identifier.trimmingCharacters(in: .whitespaces)]
    }

    /// Clears the index once an interaction ends, since the rectangles describe
    /// a screen state that has probably already changed.
    func clear() {
        orderedTargets = []
        targetsByIdentifier = [:]
    }
}
