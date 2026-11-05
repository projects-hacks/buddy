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

        // Read at the same time as recognition, and off the main thread: the
        // accessibility calls wait on the front app, however busy it is.
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let accessibilityReadingTask: Task<AccessibilityScreenReading?, Never> = Task.detached(priority: .userInitiated) {
            guard let frontmostProcessIdentifier, AXIsProcessTrusted() else { return nil }
            return ScreenIndexAccessibilityReader.read(
                processIdentifier: frontmostProcessIdentifier,
                includeLabelledElements: includeAccessibilityElements,
                displayBoundsInPoints: displayBoundsInPoints)
        }

        let recognizedLines = await Self.performTextRecognition(onScreenshotData: screenshotData)
        let accessibilityReading = await accessibilityReadingTask.value

        // Recognition covers the whole screen, so the lesson arrives mixed in
        // with tabs, bookmarks and toolbars. Restricting to the content area
        // is what stops the model marking a bookmark when asked about the page.
        let contentRegion = accessibilityReading?.contentFrameInGlobalPoints.map { frame in
            convertGlobalFrameToDisplayLocalPoints(frame, displayBoundsInPoints: displayBoundsInPoints)
        }

        // Vision reports a normalised rectangle with a bottom-left origin,
        // which already matches AppKit, so this is a scale with no flip.
        let piecesInPoints = recognizedLines.map { recognizedLine in
            LinePiece(
                text: recognizedLine.text,
                bounds: CGRect(
                    x: recognizedLine.normalizedBounds.origin.x * displayBoundsInPoints.width,
                    y: recognizedLine.normalizedBounds.origin.y * displayBoundsInPoints.height,
                    width: recognizedLine.normalizedBounds.size.width * displayBoundsInPoints.width,
                    height: recognizedLine.normalizedBounds.size.height * displayBoundsInPoints.height
                ),
                confidence: recognizedLine.confidence
            )
        }

        for piece in Self.joiningPiecesOfOneLine(piecesInPoints) {
            collectedTargets.append(
                ScreenTarget(
                    id: "t\(nextIdentifierNumber)",
                    displayedText: piece.text,
                    boundsInDisplayPoints: piece.bounds,
                    displayIndex: displayIndex,
                    locationSource: .recognizedText,
                    confidence: piece.confidence
                )
            )
            nextIdentifierNumber += 1
        }

        for labelledElement in accessibilityReading?.labelledElements ?? [] {
            collectedTargets.append(
                ScreenTarget(
                    id: "a\(nextIdentifierNumber)",
                    displayedText: labelledElement.label,
                    boundsInDisplayPoints: convertGlobalFrameToDisplayLocalPoints(
                        labelledElement.frameInGlobalPoints,
                        displayBoundsInPoints: displayBoundsInPoints
                    ),
                    displayIndex: displayIndex,
                    locationSource: .accessibilityElement,
                    confidence: 1.0
                )
            )
            nextIdentifierNumber += 1
        }

        // Applied after building rather than during, so a region that turns out
        // to be wrong can be discarded without having lost anything. Dropping
        // to almost nothing means the region was not the content area, and a
        // cluttered index beats an empty one.
        var targetsToKeep = collectedTargets
        var droppedOutsideContent = 0

        if let contentRegion, contentRegion.width > 100, contentRegion.height > 100 {
            // The menu bar and an open menu are kept too: they are chrome for
            // a question about a page, but they are exactly where a step goes
            // when the student is being guided through an app.
            let openMenuRegions = (accessibilityReading?.openMenuFramesInGlobalPoints ?? []).map { frame in
                convertGlobalFrameToDisplayLocalPoints(frame, displayBoundsInPoints: displayBoundsInPoints)
            }
            let keptRegions = [contentRegion, menuBarRegionInDisplayPoints(displayBoundsInPoints: displayBoundsInPoints)]
                + openMenuRegions
            let insideContent = collectedTargets.filter { target in
                keptRegions.contains { region in region.intersects(target.boundsInDisplayPoints) }
            }
            if insideContent.count >= 5 {
                droppedOutsideContent = collectedTargets.count - insideContent.count
                targetsToKeep = insideContent
            }
        }

        orderedTargets = targetsToKeep
        targetsByIdentifier = Dictionary(
            targetsToKeep.map { target in (target.id, target) },
            uniquingKeysWith: { first, _ in first }
        )

        let regionDescription = contentRegion.map { region in
            "content \(Int(region.width))x\(Int(region.height)) at \(Int(region.minX)),\(Int(region.minY))"
        } ?? "no content region found"
        TutorDebugLog.write("🗂️ ScreenIndex: \(targetsToKeep.count) targets (\(recognizedLines.count) recognised, \(droppedOutsideContent) dropped as chrome), \(regionDescription)")
    }

    /// One run of recognised text, in display points.
    struct LinePiece: Equatable {
        var text: String
        var bounds: CGRect
        var confidence: Float
    }

    /// Recognition sometimes reads one line of small text as two or three
    /// items ("low," then "high = 0, len(items)" at 11 pt), and a mark on
    /// one then covers part of the line the model meant. Pieces on the same
    /// baseline, of the same height, with no more than about a word's space
    /// between them, are listed as the one line they are. Columns, menu
    /// titles and table cells sit further apart and stay separate.
    static func joiningPiecesOfOneLine(_ pieces: [LinePiece]) -> [LinePiece] {
        var joined: [LinePiece] = []
        for piece in pieces.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
            if let index = joined.lastIndex(where: { isNextOnTheSameLine(piece, after: $0) }) {
                joined[index].text += " " + piece.text
                joined[index].bounds = joined[index].bounds.union(piece.bounds)
                joined[index].confidence = min(joined[index].confidence, piece.confidence)
            } else {
                joined.append(piece)
            }
        }
        // Back in the order recognition gave, top to bottom, so ids read as before.
        return joined.sorted { first, second in
            abs(first.bounds.midY - second.bounds.midY) > min(first.bounds.height, second.bounds.height) / 2
                ? first.bounds.midY > second.bounds.midY
                : first.bounds.minX < second.bounds.minX
        }
    }

    private static func isNextOnTheSameLine(_ piece: LinePiece, after earlier: LinePiece) -> Bool {
        let first = earlier.bounds, second = piece.bounds
        let shorter = min(first.height, second.height), taller = max(first.height, second.height)
        guard shorter > 0, taller / shorter <= 1.6 else { return false }
        let verticalOverlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
        guard verticalOverlap >= shorter * 0.6, abs(first.midY - second.midY) <= taller * 0.35 else { return false }
        let gap = second.minX - first.maxX
        return gap >= -shorter * 0.3 && gap <= taller * 1.2
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

    // MARK: - Content region

    /// The menu bar strip in display-local points, which is kept with the
    /// content region: it is chrome for a question about a page, but it is
    /// exactly where a step goes when the student is being guided.
    private func menuBarRegionInDisplayPoints(displayBoundsInPoints: CGSize) -> CGRect {
        let menuBarHeight = max(NSStatusBar.system.thickness, NSScreen.main?.safeAreaInsets.top ?? 0) + 2
        // Display-local points start at the bottom left, as Vision's do.
        return CGRect(x: 0, y: displayBoundsInPoints.height - menuBarHeight,
                      width: displayBoundsInPoints.width, height: menuBarHeight)
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
    /// The targets worth showing the model, in the order they are listed.
    private func targetsForPrompt(maximumTargets: Int) -> [ScreenTarget] {

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

        let selectedTargets = Array(recognisedTextTargets.prefix(textAllowance))
            + Array(accessibilityTargets.prefix(accessibilityAllowance))
        return selectedTargets
    }

    func renderForPrompt(maximumTargets: Int = 120) -> String {
        guard !orderedTargets.isEmpty else {
            return "(no text could be read from the screen)"
        }
        let selectedTargets = targetsForPrompt(maximumTargets: maximumTargets)
        return selectedTargets.map { target in
            // Collapse newlines so one target stays on one line and the
            // listing cannot be mistaken for free-form text.
            let singleLineText = target.displayedText
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            return "\(target.id): \(singleLineText)"
        }
        .joined(separator: "\n")
    }

    /// The listing for a drawing program: each line carries its box in the
    /// screenshot's pixels, top-left origin, which is the canvas the program
    /// draws on. Returned with the same boxes keyed by id, for the engine.
    func listingWithBoxes(
        canvasSize: CGSize,
        displaySizeInPoints: CGSize,
        maximumTargets: Int = 120
    ) -> (listing: String, boxes: [String: [Double]]) {
        guard !orderedTargets.isEmpty, displaySizeInPoints.width > 0, displaySizeInPoints.height > 0 else {
            return ("(no text could be read from the screen)", [:])
        }
        let scaleX = canvasSize.width / displaySizeInPoints.width
        let scaleY = canvasSize.height / displaySizeInPoints.height
        var boxes: [String: [Double]] = [:]
        var labels: [String: String] = [:]
        let lines = targetsForPrompt(maximumTargets: maximumTargets).map { target -> String in
            let bounds = target.boundsInDisplayPoints
            // Bottom-left points to top-left pixels.
            let box = [
                (bounds.minX * scaleX).rounded(),
                ((displaySizeInPoints.height - bounds.maxY) * scaleY).rounded(),
                (bounds.width * scaleX).rounded(),
                (bounds.height * scaleY).rounded()
            ].map(Double.init)
            boxes[target.id] = box
            let singleLineText = target.displayedText
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            labels[target.id] = singleLineText
            return "\(target.id) [\(Int(box[0])), \(Int(box[1])), \(Int(box[2])), \(Int(box[3]))] \(singleLineText)"
        }
        lastListedLabels = labels
        return (lines.joined(separator: "\n"), boxes)
    }

    /// The text of each target in the last listing, by id. The engine uses it
    /// when a program names a control by its label instead of its id.
    private(set) var lastListedLabels: [String: String] = [:]

    /// The smallest target in the last listing under a point, in the same
    /// display-local points as the targets. Only listed ones, since an id
    /// the model was not shown means nothing to it. A few points of slack,
    /// because recognised text hugs the glyphs and a pointer resting on a
    /// word often sits just above or below them.
    func listedTarget(atDisplayLocalPoint point: CGPoint) -> ScreenTarget? {
        orderedTargets
            .filter { target in
                lastListedLabels[target.id] != nil && target.boundsInDisplayPoints.insetBy(dx: -4, dy: -4).contains(point)
            }
            .min { first, second in
                first.boundsInDisplayPoints.width * first.boundsInDisplayPoints.height
                    < second.boundsInDisplayPoints.width * second.boundsInDisplayPoints.height
            }
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

// MARK: - Accessibility reading, off the main thread

/// What the accessibility tree said about the front app, in global
/// top-left-origin points, read away from the main thread.
nonisolated struct AccessibilityScreenReading: Sendable {
    struct LabelledElement: Sendable {
        let label: String
        let frameInGlobalPoints: CGRect
    }

    /// The page (a browser's `AXWebArea`) or else the focused window.
    var contentFrameInGlobalPoints: CGRect?
    /// Any menu the front app has open.
    var openMenuFramesInGlobalPoints: [CGRect] = []
    var labelledElements: [LabelledElement] = []
}

/// Every accessibility call is a message to another app, answered when that
/// app gets round to it. A busy or hung app (a browser on a heavy page, an
/// app stuck on a dialog) can take seconds per call, and a web area can hold
/// thousands of elements. So the walk runs off the main thread, each call
/// gives up after a quarter of a second, and the walk stops after a fixed
/// number of elements or a fixed time, whichever comes first.
nonisolated enum ScreenIndexAccessibilityReader {
    /// Upper bound on accessibility traversal depth.
    ///
    /// Browsers and Electron apps nest extremely deeply, and an unbounded walk
    /// stalls the voice loop. Twelve levels reaches real controls in practice.
    static let maximumAccessibilityDepth = 12

    /// Upper bound on indexed accessibility elements, bounding the prompt it feeds.
    static let maximumAccessibilityElements = 250

    /// Upper bounds on the walk itself: elements visited, not only kept.
    static let maximumElementsVisited = 2_000
    static let maximumSecondsSpentWalking: TimeInterval = 0.3

    /// How long one call to the front app may take.
    static let messagingTimeoutSeconds: Float = 0.25

    private struct Walk {
        let startedAt: Date
        var elementsVisited = 0
        var isOverBudget: Bool {
            elementsVisited >= ScreenIndexAccessibilityReader.maximumElementsVisited
                || Date().timeIntervalSince(startedAt) >= ScreenIndexAccessibilityReader.maximumSecondsSpentWalking
        }
    }

    static func read(
        processIdentifier: pid_t,
        includeLabelledElements: Bool,
        displayBoundsInPoints: CGSize
    ) -> AccessibilityScreenReading {
        var reading = AccessibilityScreenReading()
        guard AXIsProcessTrusted() else { return reading }
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, messagingTimeoutSeconds)

        reading.contentFrameInGlobalPoints = contentFrame(of: applicationElement)
        reading.openMenuFramesInGlobalPoints = openMenuFrames(of: applicationElement)

        if includeLabelledElements {
            var walk = Walk(startedAt: Date())
            appendLabelledElements(from: applicationElement, currentDepth: 0,
                                   displayBoundsInPoints: displayBoundsInPoints,
                                   walk: &walk, into: &reading.labelledElements)
            if walk.isOverBudget {
                TutorDebugLog.write("🗂️ ScreenIndex: accessibility walk stopped at \(walk.elementsVisited) elements, \(String(format: "%.2f", Date().timeIntervalSince(walk.startedAt)))s")
            }
        }
        return reading
    }

    /// The part of the screen holding what the user is actually working on,
    /// in global points. Nil when it cannot be determined.
    ///
    /// Why this is needed: text recognition reads the entire screen, which on
    /// a browser means the tab strip, every bookmark, the toolbar and the menu
    /// bar land in the listing beside the lesson. Asked about Snowflake
    /// internals, the model circled a bookmark titled "Hive (DM)", which was a
    /// perfectly reasonable pick from a listing that gives no hint which lines
    /// are furniture. Nothing in the text distinguishes them, but their
    /// position does.
    ///
    /// Taken from the accessibility tree rather than guessed: a browser
    /// exposes its page as an `AXWebArea`, which is exactly the content area
    /// with the chrome excluded. Other apps fall back to the focused window,
    /// which still drops the menu bar, the dock and anything behind.
    private static func contentFrame(of applicationElement: AXUIElement) -> CGRect? {
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        // The force cast is checked by the type id above.
        let focusedWindow = focusedWindowValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focusedWindow, messagingTimeoutSeconds)

        // Depth is bounded because the search runs on every question.
        var walk = Walk(startedAt: Date())
        if let webAreaFrame = findWebAreaFrame(under: focusedWindow, depth: 0, walk: &walk) {
            return webAreaFrame
        }
        return accessibilityFrame(for: focusedWindow)
    }

    private static func openMenuFrames(of applicationElement: AXUIElement) -> [CGRect] {
        var frames: [CGRect] = []
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBarValue, CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return frames }
        let menuBar = menuBarValue as! AXUIElement
        AXUIElementSetMessagingTimeout(menuBar, messagingTimeoutSeconds)
        var titlesValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &titlesValue) == .success,
              let titles = titlesValue as? [AXUIElement] else { return frames }
        for title in titles {
            AXUIElementSetMessagingTimeout(title, messagingTimeoutSeconds)
            var selectedValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(title, kAXSelectedAttribute as CFString, &selectedValue) == .success,
                  (selectedValue as? Bool) == true else { continue }
            var menusValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(title, kAXChildrenAttribute as CFString, &menusValue) == .success,
                  let menus = menusValue as? [AXUIElement] else { continue }
            for menu in menus {
                AXUIElementSetMessagingTimeout(menu, messagingTimeoutSeconds)
                if let frame = accessibilityFrame(for: menu) { frames.append(frame) }
            }
        }
        return frames
    }

    /// Searches for the first `AXWebArea` beneath an element.
    private static func findWebAreaFrame(under element: AXUIElement, depth: Int, walk: inout Walk) -> CGRect? {
        guard depth <= 6, !walk.isOverBudget else { return nil }
        walk.elementsVisited += 1
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)

        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String,
           role == "AXWebArea" {
            return accessibilityFrame(for: element)
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success, let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let found = findWebAreaFrame(under: child, depth: depth + 1, walk: &walk) {
                return found
            }
        }
        return nil
    }

    private static func appendLabelledElements(
        from element: AXUIElement,
        currentDepth: Int,
        displayBoundsInPoints: CGSize,
        walk: inout Walk,
        into labelledElements: inout [AccessibilityScreenReading.LabelledElement]
    ) {
        guard currentDepth <= maximumAccessibilityDepth,
              labelledElements.count < maximumAccessibilityElements,
              !walk.isOverBudget else {
            return
        }
        walk.elementsVisited += 1
        // Set per element: a timeout set on the app's element covers only
        // that element, not the ones read from it.
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)

        if let label = accessibilityLabel(for: element),
           let frameInGlobalPoints = accessibilityFrame(for: element) {
            // Zero-sized and full-window frames are container artifacts rather
            // than things a learner can usefully be shown.
            let isPointableSize = frameInGlobalPoints.width >= 8
                && frameInGlobalPoints.height >= 8
                && frameInGlobalPoints.width <= displayBoundsInPoints.width
                && frameInGlobalPoints.height <= displayBoundsInPoints.height

            if isPointableSize {
                labelledElements.append(.init(label: label, frameInGlobalPoints: frameInGlobalPoints))
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
            appendLabelledElements(
                from: childElement,
                currentDepth: currentDepth + 1,
                displayBoundsInPoints: displayBoundsInPoints,
                walk: &walk,
                into: &labelledElements
            )
        }
    }

    /// Picks the most human-meaningful label available on an element.
    private static func accessibilityLabel(for element: AXUIElement) -> String? {
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
    private static func accessibilityFrame(for element: AXUIElement) -> CGRect? {
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
}
