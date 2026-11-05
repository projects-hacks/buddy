//
//  CompanionManager+Marks.swift
//  leanring-buddy
//
//  Drawing on the screen for the prose path: marks, spotlight,
//  whiteboard, pointing, their lifetime, scrolling and dismissal, the
//  cursor overlay, and the calibration capture.
//

import AppKit
import Combine
import Foundation
import SwiftUI

extension CompanionManager {
    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
    }

    /// Starts following the marks of the answer just begun on this screen.
    func followMarks(displayFrame: CGRect, canvasSize: CGSize, targets: [String: [Double]],
                             labels: [String: String]) {
        let accessibilityItemIds = Set(screenIndex.orderedTargets
            .filter { target in target.locationSource == .accessibilityElement }
            .map(\.id))
        markFollower.begin(displayFrame: displayFrame, canvasSize: canvasSize, targets: targets,
                           labels: labels, accessibilityItemIds: accessibilityItemIds)
    }

    // MARK: - Drawing on screen

    /// Turns one directive into a mark, resolving its target to an exact rectangle.
    ///
    /// `spokenContext` is the sentence the mark was attached to. It is only
    /// consulted when an id fails to resolve, as the recovery path described
    /// on `ScreenIndex.bestTextMatch(forSpokenPhrase:)`.
    func apply(directive: TeacherDirective, spokenContext: String = "") {
        let displayFrame = displayFrameForCurrentAnswer

        /// Converts a display-local rectangle into global AppKit points.
        func globalRect(for target: ScreenTarget) -> CGRect {
            CGRect(
                x: target.boundsInDisplayPoints.origin.x + displayFrame.origin.x,
                y: target.boundsInDisplayPoints.origin.y + displayFrame.origin.y,
                width: target.boundsInDisplayPoints.width,
                height: target.boundsInDisplayPoints.height
            )
        }

        func resolve(_ identifier: String) -> CGRect? {
            if let target = screenIndex.target(forIdentifier: identifier) {
                return globalRect(for: target)
            }

            // The id missed. The words around it are usually still honest
            // about what the model meant, so try to recover from those before
            // dropping the mark.
            let leadingPhrase = phraseLeadingUpTo(
                characterOffset: directive.characterOffsetInSpokenText,
                in: spokenContext
            )

            if let recoveredTarget = screenIndex.bestTextMatch(forSpokenPhrase: leadingPhrase) {
                TutorDebugLog.write("↩️ Recovered bad id \(identifier) as \(recoveredTarget.id) via \"\(recoveredTarget.displayedText)\"")
                return globalRect(for: recoveredTarget)
            }

            TutorDebugLog.write("⚠️ unknown target \(identifier), nothing nearby matched")
            return nil
        }

        switch directive.action {
        case .clearAll:
            clearAnnotations()

        // MARK: Board
        //
        // Each of these appends to the board, and appending is the reveal:
        // because directives fire from speech word boundaries, an element
        // lands exactly as it is described rather than the finished picture
        // appearing at once.

        case .beginBoard(let title):
            withAnimation(.easeOut(duration: 0.3)) {
                whiteboard = TutorWhiteboard(title: title)
            }

        case .addBoardColumn(let label, let content):
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                whiteboard.columns.append(
                    TutorWhiteboard.Column(label: label, content: content)
                )
            }

        case .addBoardBase(let label):
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                whiteboard.baseLabel = label
            }

        case .addBoardCells(let values):
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                whiteboard.cells = values
                // Pointers refer to positions in the old row, so they are
                // dropped rather than left pointing somewhere arbitrary.
                whiteboard.pointers = []
            }

        case .addBoardPointer(let position, let name):
            guard let cellIndex = position.resolve(inCellCount: whiteboard.cells.count) else {
                TutorDebugLog.write("⚠️ pointer \(name) could not be placed; row has \(whiteboard.cells.count) cell(s)")
                return
            }
            withAnimation(.easeOut(duration: 0.22)) {
                // One name per position: re-stating `mid` moves it rather than
                // stacking a second label under the same cell. This is what
                // makes a walkthrough animate, since each restatement of `lo`
                // slides the marker along instead of littering the row.
                whiteboard.pointers.removeAll { pointer in pointer.name == name }
                whiteboard.pointers.append(
                    TutorWhiteboard.Pointer(cellIndex: cellIndex, name: name)
                )
            }

        case .addBoardNode(let identifier, let column, let row, let widthInColumns, let label, let tint):
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                // Restating a node moves it rather than stacking a duplicate,
                // which is what lets a diagram be corrected mid-explanation.
                whiteboard.nodes.removeAll { existing in existing.id == identifier }
                whiteboard.nodes.append(
                    TutorWhiteboard.Node(
                        id: identifier,
                        column: column,
                        row: row,
                        widthInColumns: widthInColumns,
                        label: label,
                        tint: TutorWhiteboard.Node.Tint(name: tint)
                    )
                )
            }

        case .addBoardEdge(let fromIdentifier, let toIdentifier, let label):
            // Both ends must exist, or the arrow has nothing to attach to and
            // would be drawn from the origin.
            let knownIdentifiers = Set(whiteboard.nodes.map(\.id))
            guard knownIdentifiers.contains(fromIdentifier),
                  knownIdentifiers.contains(toIdentifier) else {
                TutorDebugLog.write("⚠️ edge \(fromIdentifier)->\(toIdentifier) references a node that was never drawn")
                return
            }
            withAnimation(.easeOut(duration: 0.3)) {
                whiteboard.edges.append(
                    TutorWhiteboard.Edge(
                        fromIdentifier: fromIdentifier,
                        toIdentifier: toIdentifier,
                        label: label
                    )
                )
            }

        case .drawDiagram(let shape):
            let expanded = shape.expand()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                whiteboard.nodes = expanded.nodes
                whiteboard.edges = expanded.edges
            }
            TutorDebugLog.write("📐 drew \(expanded.nodes.count) boxes, \(expanded.edges.count) arrows")

        case .addBoardNote(let text):
            withAnimation(.easeOut(duration: 0.25)) {
                whiteboard.caption = text
            }

        case .point(let identifier):
            guard let rect = resolve(identifier) else { return }
            detectedElementScreenLocation = CGPoint(x: rect.midX, y: rect.midY)
            detectedElementDisplayFrame = displayFrame

        case .pointAtCoordinate(let x, let y, _, _):
            // Coordinates arrive in the screenshot's top-left space; the
            // overlay works in AppKit's bottom-left space.
            let flippedY = displayFrame.height - y
            detectedElementScreenLocation = CGPoint(
                x: x + displayFrame.origin.x,
                y: flippedY + displayFrame.origin.y
            )
            detectedElementDisplayFrame = displayFrame

        case .circle(let identifier):
            appendAnnotation(style: .circle, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .box(let identifier):
            appendAnnotation(style: .box, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .underline(let identifier):
            appendAnnotation(style: .underline, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .highlight(let identifier):
            appendAnnotation(style: .highlight, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .strikethrough(let identifier):
            appendAnnotation(style: .strikethrough, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .step(let identifier, let stepNumber):
            appendAnnotation(style: .step(number: stepNumber), identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .callout(let identifier, let text):
            appendAnnotation(style: .callout(text: text), identifier: identifier, resolve: resolve, displayFrame: displayFrame)

        case .arrow(let fromIdentifier, let toIdentifier):
            guard let fromRect = resolve(fromIdentifier),
                  let toRect = resolve(toIdentifier) else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                activeAnnotations.append(
                    TeacherAnnotation(
                        style: .arrow(destinationRectInGlobalPoints: toRect),
                        rectInGlobalPoints: fromRect,
                        displayFrame: displayFrame
                    )
                )
            }

        case .spotlight(let identifiers):
            // Capped in code, not just asked for in the prompt. The model
            // spotlighted sixteen targets on its first real run, which lights
            // most of the screen and hides nothing, defeating the one mark
            // whose whole value is removing distraction.
            let litRects = identifiers.prefix(3).compactMap(resolve)
            guard !litRects.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                spotlightRectsInGlobalPoints = litRects
            }
        }
    }

    /// Returns the words just before a mark, which is where the model names
    /// the thing it is marking.
    ///
    /// Looks backwards rather than around the offset because the natural
    /// phrasing is "the load balancer [POINT:t12]": the noun precedes the tag.
    /// A short lookahead is still included for the occasional inversion.
    private func phraseLeadingUpTo(characterOffset: Int, in text: String) -> String {
        guard !text.isEmpty else { return "" }

        let charactersBefore = 70
        let charactersAfter = 25

        let clampedOffset = max(0, min(characterOffset, text.count))
        let lowerBound = max(0, clampedOffset - charactersBefore)
        let upperBound = min(text.count, clampedOffset + charactersAfter)
        guard lowerBound < upperBound else { return "" }

        let startIndex = text.index(text.startIndex, offsetBy: lowerBound)
        let endIndex = text.index(text.startIndex, offsetBy: upperBound)
        return String(text[startIndex..<endIndex])
    }

    private func appendAnnotation(
        style: TeacherAnnotation.Style,
        identifier: String,
        resolve: (String) -> CGRect?,
        displayFrame: CGRect
    ) {
        guard let rect = resolve(identifier) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            activeAnnotations.append(
                TeacherAnnotation(
                    style: style,
                    rectInGlobalPoints: rect,
                    displayFrame: displayFrame
                )
            )
        }
        TutorDebugLog.write("🖊️ \(identifier) -> rect (\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height)) on display \(Int(displayFrame.width))x\(Int(displayFrame.height)) at \(Int(displayFrame.origin.x)),\(Int(displayFrame.origin.y)), total now \(activeAnnotations.count), overlayVisible=\(isOverlayVisible)")
    }

    /// Boxes every indexed target and photographs the result.
    ///
    /// Runs the exact capture, indexing and drawing path a real answer uses,
    /// minus the model, so a misplaced box here is misplaced for the same
    /// reason a misplaced mark is in an answer.
    func runCalibration() async {
        TutorDebugLog.write("🎯 calibration: starting")
        do {
            if !isOverlayVisible {
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let capture = captures.first(where: { candidate in candidate.isCursorScreen })
                    ?? captures.first else { return }
            displayFrameForCurrentAnswer = capture.displayFrame

            await screenIndex.rebuild(
                fromScreenshot: capture.imageData,
                displayIndex: 0,
                displayBoundsInPoints: CGSize(
                    width: capture.displayWidthInPoints,
                    height: capture.displayHeightInPoints
                )
            )

            clearAnnotations()
            let targets = screenIndex.orderedTargets
                .filter { target in target.locationSource == .recognizedText }
                .prefix(40)
            for target in targets {
                apply(directive: TeacherDirective(action: .box(targetIdentifier: target.id),
                                                  characterOffsetInSpokenText: 0))
            }
            TutorDebugLog.write("🎯 calibration: boxed \(targets.count) targets, waiting for render")

            // The board from a real answer that came out clipped and mostly
            // empty, so its size and placement are in the same picture.
            let sampleBoard = TeacherResponseParser.parse(rawResponse: """
            [BOARD:Separated Storage and Compute][COL:Finance Cluster:Stateless CPUs]\
            [COL:Data Science:Stateless CPUs][BASE:Shared Cloud Storage (S3)]\
            [CAPTION:Workers own zero data, they only cache it]
            """)
            for directive in sampleBoard.directives {
                apply(directive: directive)
            }
            boardRevealFraction = 1

            // Long enough for every box's stroke animation to finish.
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            try await CalibrationSnapshot.captureIncludingOverlay()
            TutorDebugLog.write("🎯 calibration: saved \(CalibrationSnapshot.outputURL.path)")

            // A sample of indexed text and rectangles, so the image can be
            // checked against what the index believed.
            for target in targets.prefix(8) {
                let r = target.boundsInDisplayPoints
                TutorDebugLog.write("🎯   \(target.id) '\(target.displayedText.prefix(30))' bottomLeft (\(Int(r.minX)),\(Int(r.minY))) \(Int(r.width))x\(Int(r.height))")
            }

            try? await Task.sleep(nanoseconds: 800_000_000)
            clearAnnotations()
        } catch {
            TutorDebugLog.write("⚠️ calibration failed: \(error.localizedDescription)")
        }
    }

    /// Takes the board and marks down a while after the answer finishes.
    ///
    /// They previously stayed until the next question, so a board left behind
    /// covered the screen indefinitely. The delay is generous on purpose: the
    /// diagram is the part worth looking at after the talking stops, and
    /// asking again clears it immediately anyway.
    func scheduleMarkDismissal() {
        markDismissalTask?.cancel()
        markDismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clearAnnotations()
        }
    }

    /// Where the words a mark belongs to start, so the mark appears as they
    /// are spoken rather than after.
    ///
    /// The model writes a tag after the phrase it marks: "the real separation
    /// is between workers and a shared storage layer like s3 [UNDERLINE:t44]".
    /// Fired at the tag, that underline landed ten seconds into the sentence,
    /// after the student had finished hearing about the thing it underlines.
    /// Backed up to the start of the clause, it appears as the phrase begins.
    /// Capped at about four seconds of speech, so a long clause does not mark
    /// its subject before it has been named at all.
    static func offsetWhereMarkedPhraseBegins(tagOffset: Int, spokenText: String) -> Int {
        let characters = Array(spokenText)
        let clampedTagOffset = min(max(tagOffset, 0), characters.count)
        let longestLeadInCharacters = 60
        let clauseBoundaries: Set<Character> = [".", ",", ";", ":", "!", "?"]

        var phraseStart = clampedTagOffset
        // Step over any boundary sitting right at the tag, so "s3 [TAG]." backs
        // into its own clause rather than stopping at its own full stop.
        while phraseStart > 0, characters[phraseStart - 1] == " " {
            phraseStart -= 1
        }
        while phraseStart > 0,
              clampedTagOffset - phraseStart < longestLeadInCharacters,
              !clauseBoundaries.contains(characters[phraseStart - 1]) {
            phraseStart -= 1
        }
        // The cap can stop mid-word. Finish the word, so the count is in words.
        while phraseStart > 0, characters[phraseStart - 1].isLetter || characters[phraseStart - 1].isNumber {
            phraseStart -= 1
        }
        return phraseStart
    }

    /// Keeps marks attached to what they point at, and gives the student ways
    /// to get rid of them.
    ///
    /// A mark is drawn at a fixed place on the screen, and the content under
    /// it does not stay put: the student scrolls, or switches to another app,
    /// and the underline that was under "data lives once" is now under
    /// something else, or across a different window entirely.
    func bindMarkLifetime() {
        notchActivityCancellable = $voiceState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .idle: self.controlBar.model.activity = .ready
                case .listening:
                    // A new question: the last one's words must not linger.
                    self.controlBar.model.heardWords = ""
                    self.controlBar.model.activity = .listening
                case .processing: self.controlBar.model.activity = .thinking
                case .responding: self.controlBar.model.activity = .speaking
                }
                InterfaceSounds.shared.isTutorSpeaking = state == .responding
                if state != .processing { self.controlBar.model.waitingStage = nil }
            }

        notchHeardWordsCancellable = buddyDictationManager.$liveTranscriptText
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] liveTranscriptText in
                // Empty when the session resets on release; the final question
                // is put in place by sendTranscriptToTutorWithScreenshot.
                guard let self, !liveTranscriptText.isEmpty else { return }
                self.controlBar.model.heardWords = Self.questionWithoutGreeting(liveTranscriptText)
            }

        controlBarDrawingCancellable = Publishers.CombineLatest3(
            $activeAnnotations, $spotlightRectsInGlobalPoints, $whiteboard
        )
        .map { annotations, spotlightRects, whiteboard in
            !annotations.isEmpty || !spotlightRects.isEmpty || whiteboard.hasContent
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] somethingIsDrawn in
            guard let self else { return }
            self.controlBar.model.hasDrawing = somethingIsDrawn || self.lessonPlayer.hasDrawing
        }

        // Esc clears, while there is something to clear. Observed, never
        // swallowed: the app in front still gets its Esc too.
        escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.handleEscape() }
        }

        scrollWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let hasPreciseDeltas = event.hasPreciseScrollingDeltas
            let verticalDelta = event.scrollingDeltaY
            let horizontalDelta = event.scrollingDeltaX
            Task { @MainActor in
                self?.followScroll(verticalDelta: verticalDelta, horizontalDelta: horizontalDelta, hasPreciseDeltas: hasPreciseDeltas)
            }
        }

        // Marks belong to the window they were drawn over. In another app
        // they point at nothing. The board stays: it is about the idea, not
        // about a place on the screen.
        applicationSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // This app coming forward (for a permission prompt) is not the
            // student leaving the content.
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard activatedApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            Task { @MainActor in
                guard let self else { return }
                // A drawing being followed is hidden while its window is
                // away and shown when it is back (MarkFollower); the older
                // marks are still cleared.
                if self.markFollower.isActive {
                    self.clearOlderMarksOnly()
                } else {
                    self.clearScreenMarks()
                }
            }
        }
    }

    /// Moves screen marks with the content as it scrolls.
    ///
    /// A trackpad reports scrolling in points, and browsers move the page by
    /// that amount, so the marks can move with it. A mouse wheel reports
    /// lines, whose size in points depends on the app, so rather than guess,
    /// the marks are cleared. Positive deltas move content down the screen,
    /// which is downward in AppKit's bottom-left coordinates.
    private func followScroll(verticalDelta: CGFloat, horizontalDelta: CGFloat, hasPreciseDeltas: Bool) {
        if lessonPlayer.hasDrawing, markFollower.isActive {
            markFollower.scrolled(deltaX: horizontalDelta, deltaY: verticalDelta, hasPreciseDeltas: hasPreciseDeltas)
            return
        }
        guard verticalDelta != 0 else { return }
        if lessonPlayer.hasDrawing {
            // The drawing page is top-left origin, so content moving down is
            // a positive offset there.
            if hasPreciseDeltas {
                lessonPlayer.scrollScreenMarks(byPoints: verticalDelta)
            } else {
                lessonPlayer.clearScreenMarks()
            }
        }
        guard !activeAnnotations.isEmpty || !spotlightRectsInGlobalPoints.isEmpty else { return }

        guard hasPreciseDeltas else {
            clearScreenMarks()
            return
        }

        activeAnnotations = activeAnnotations.map { annotation in
            annotation.shiftedVertically(by: -verticalDelta)
        }
        spotlightRectsInGlobalPoints = spotlightRectsInGlobalPoints.map { rect in
            rect.offsetBy(dx: 0, dy: -verticalDelta)
        }
    }

    /// Removes the older tag pipeline's marks only, leaving a followed drawing.
    private func clearOlderMarksOnly() {
        guard !activeAnnotations.isEmpty || !spotlightRectsInGlobalPoints.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            activeAnnotations.removeAll()
            spotlightRectsInGlobalPoints.removeAll()
        }
    }

    /// Removes marks drawn over screen content, keeping the board.
    private func clearScreenMarks() {
        markFollower.stop()
        lessonPlayer.clearScreenMarks()
        guard !activeAnnotations.isEmpty || !spotlightRectsInGlobalPoints.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            activeAnnotations.removeAll()
            spotlightRectsInGlobalPoints.removeAll()
        }
    }

    /// Wipes every mark and takes down the board.
    /// Whether anything was on screen to clear, so the student's own Clear
    /// and Esc can be heard to work while the clears that come with every
    /// new question stay silent.
    @discardableResult
    func clearAnnotations() -> Bool {
        // Notebook hook: clearing a lesson while it is still being spoken
        // (Esc, Clear) stops it, so it is not kept.
        if lessonPlayer.isSpeaking { notebookRecorder.answerWasDismissed() }

        // Clearing stops the voice, so nothing is left to talk over.
        endTalkOver()
        markFollower.stop()
        let lessonHadDrawing = lessonPlayer.hasDrawing
        lessonPlayer.clear()
        let hasNothingToClear = activeAnnotations.isEmpty
            && spotlightRectsInGlobalPoints.isEmpty
            && !whiteboard.hasContent
        guard !hasNothingToClear else { return lessonHadDrawing }

        withAnimation(.easeOut(duration: 0.25)) {
            activeAnnotations.removeAll()
            spotlightRectsInGlobalPoints.removeAll()
            whiteboard = TutorWhiteboard()
        }
        return true
    }

    /// If the cursor is in transient mode, waits for speech and any pointing
    /// animation to finish, then fades the overlay out.
    func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            while isAnyVoicePlaying || proseSpeech.isSpeaking {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            clearAnnotations()
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }
}
