//
//  CompanionManager+Interruptions.swift
//  leanring-buddy
//
//  What stops or rebuilds an answer from outside: Esc, the stop
//  button, sleep, wake and display changes.
//

import AppKit
import Foundation

extension CompanionManager {
    /// Stop on the bar: stops talking and the answer being written, and
    /// leaves what is drawn.
    func stopAnswering() {
        stopGuide(reason: "Stop")
        questionAwaitingAnswer = nil
        cancelCurrentResponseTask()
        cancelSpeechAndClearQueue()
        voiceState = .idle
        controlBar.model.caption = ""
    }

    func observeSystemEvents() {
        systemEventsObserver = SystemEventsObserver(
            willSleep: { [weak self] in self?.systemWillSleep() },
            didWake: { [weak self] in self?.systemDidWake() },
            screensChanged: { [weak self] in self?.screensChanged() })
    }

    /// Sleep drops every stream mid-answer and stops the audio engines, so
    /// the answer is stopped cleanly first rather than failing on waking.
    private func systemWillSleep() {
        TutorDebugLog.write("💤 the Mac is going to sleep: answer stopped, listening cancelled")
        stopAnswering()
        pendingTalkStart?.cancel()
        pendingTalkStart = nil
        buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
        talkOverListener.stop()
    }

    /// The audio output may be another device now, the key taps may have
    /// been switched off, and the brain may have been unreachable while asleep.
    private func systemDidWake() {
        TutorDebugLog.write("☀️ the Mac woke: audio engines and key taps rebuilt")
        narrationVoice.prepareAfterWake()
        deepgramClient.prepareAfterWake()
        deepgramProseVoiceBenchedUntil = .distantPast
        globalPushToTalkShortcutMonitor.stop()
        if hasAccessibilityPermission { globalPushToTalkShortcutMonitor.start() }
        Task { [weak self] in
            guard let self, !self.isProbingBrain else { return }
            self.isProbingBrain = true
            defer { self.isProbingBrain = false }
            let brainKindProbed = self.brainKind
            let (isReachable, _) = await self.tutorBrain.probeServer()
            self.isLocalModelReachable = isReachable
            self.brainKindKnownReachable = isReachable ? brainKindProbed : nil
            TutorDebugLog.write("☀️ after waking, the brain is \(isReachable ? "reachable" : "UNREACHABLE")")
        }
    }

    /// A display came or went: the cursor overlay is one window per screen
    /// and is built again; marks and a guide on a display that is gone end.
    private func screensChanged() {
        let screenFrames = NSScreen.screens.map(\.frame)
        TutorDebugLog.write("🖥️ displays changed: \(screenFrames.count) now")
        if isOverlayVisible {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        }
        if let guideBaseline, !screenFrames.contains(guideBaseline.displayFrame) {
            stopGuide(reason: "its display is gone")
        }
        if lessonPlayer.hasDrawing, !screenFrames.contains(drawingOverlay.screenFrame) {
            markFollower.stop()
            lessonPlayer.clear()
        }
    }

    /// Esc puts everything away at once: the drawing, the open notch and a
    /// walkthrough. Closing the notch first and clearing on a second press
    /// read as Esc not working.
    func handleEscape() {
        teachingBoard.escapeWasPressed()
        stopGuide(reason: "Esc")
        // Esc while the keys are held, or while the last words are still
        // being transcribed, takes the question back: nothing is sent.
        if pendingTalkStart != nil || buddyDictationManager.isDictationInProgress || earlyScreenCapture.isHoldingCapture {
            pendingTalkStart?.cancel()
            pendingTalkStart = nil
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
            earlyScreenCapture.discard(reason: "Esc")
            pointerRestWatcher.cancel()
            pointerRestsOfLastPress = []
            controlBar.model.heardWords = ""
        }
        let closedNotch = controlBar.closeFromKeyboard()
        let clearedDrawing = clearAnnotations()
        TutorDebugLog.write("⎋ Esc: \(clearedDrawing ? "drawing cleared" : "nothing drawn")\(closedNotch ? ", notch closed" : "")")
        if clearedDrawing { InterfaceSounds.shared.play(.wipe) }
    }
}
