//
//  CompanionManager+Marks.swift
//  leanring-buddy
//
//  What is drawn on the screen as the manager reaches it: the prose
//  path's marks from MarkCoordinator, the drawing program's marks kept on
//  their items, what clears them (scrolling, app switches, Esc, Clear),
//  the cursor overlay, and the calibration capture.
//

import AppKit
import Combine
import Foundation

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

    var detectedElementScreenLocation: CGPoint? { marks.detectedElementScreenLocation }
    var detectedElementDisplayFrame: CGRect? { marks.detectedElementDisplayFrame }
    var activeAnnotations: [TeacherAnnotation] { marks.activeAnnotations }
    var spotlightRectsInGlobalPoints: [CGRect] { marks.spotlightRectsInGlobalPoints }
    var whiteboard: TutorWhiteboard { marks.whiteboard }
    var boardRevealFraction: Double { marks.boardRevealFraction }

    func clearDetectedElementLocation() { marks.clearDetectedElementLocation() }

    func apply(directive: TeacherDirective, spokenContext: String = "") {
        marks.apply(directive: directive, spokenContext: spokenContext)
    }

    /// Connects the coordinator once, at start: the overlay observes the
    /// manager, so every change to what is drawn is passed on as a change of
    /// the manager's.
    func connectMarks() {
        marksCancellable = marks.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        marks.currentScreenIndex = { [weak self] in self?.screenIndex ?? ScreenIndex() }
        marks.isOverlayVisible = { [weak self] in self?.isOverlayVisible ?? false }
        marks.onClearEverything = { [weak self] in self?.clearAnnotations() }
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
            marks.displayFrameForCurrentAnswer = capture.displayFrame

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
            marks.revealWholeBoard()

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
            marks.$activeAnnotations, marks.$spotlightRectsInGlobalPoints, marks.$whiteboard
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
        guard marks.hasScreenMarks else { return }

        guard hasPreciseDeltas else {
            clearScreenMarks()
            return
        }

        marks.shiftScreenMarks(byVerticalDelta: verticalDelta)
    }

    /// Removes the older tag pipeline's marks only, leaving a followed drawing.
    private func clearOlderMarksOnly() {
        marks.clearScreenMarks()
    }

    /// Removes marks drawn over screen content, keeping the board.
    private func clearScreenMarks() {
        markFollower.stop()
        lessonPlayer.clearScreenMarks()
        marks.clearScreenMarks()
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
        let clearedMarks = marks.clearEverythingDrawn()
        return clearedMarks || lessonHadDrawing
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

            while marks.detectedElementScreenLocation != nil {
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
