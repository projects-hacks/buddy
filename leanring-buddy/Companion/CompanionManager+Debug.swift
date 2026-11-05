//
//  CompanionManager+Debug.swift
//  leanring-buddy
//
//  The QA channel's entry points and the file triggers, debug builds only.
//

import AppKit
import Foundation

#if DEBUG
extension CompanionManager {
    /// Test triggers read from files in ~/Library/Logs, checked on every
    /// permission poll. Debug builds only: any program on the Mac can write
    /// those files, and one of them makes Buddy capture the screen and send
    /// it to a model.
    func runDebugFileTriggers() async {
        if FileManager.default.fileExists(atPath: CalibrationSnapshot.triggerURL.path) {
            try? FileManager.default.removeItem(at: CalibrationSnapshot.triggerURL)
            await runCalibration()
        }

        if let tabName = try? String(contentsOf: CalibrationSnapshot.openNotchURL, encoding: .utf8) {
            try? FileManager.default.removeItem(at: CalibrationSnapshot.openNotchURL)
            switch tabName.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "transcript": openNotchBriefly(on: .transcript)
            case "settings": openNotchBriefly(on: .settings)
            default: openNotchBriefly(on: .lesson)
            }
        }

        // A question in this file is asked as if spoken, so the whole
        // pipeline can be checked from a terminal: capture, model,
        // voice, drawing.
        if let question = try? String(contentsOf: CalibrationSnapshot.askURL, encoding: .utf8) {
            try? FileManager.default.removeItem(at: CalibrationSnapshot.askURL)
            let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuestion.isEmpty {
                TutorDebugLog.write("🧪 asked from file")
                sendTranscriptToTutorWithScreenshot(transcript: trimmedQuestion)
            }
        }

        // A picture of the screen with whatever is drawn on it, to
        // check a drawing by looking at it.
        if FileManager.default.fileExists(atPath: CalibrationSnapshot.snapshotTriggerURL.path) {
            try? FileManager.default.removeItem(at: CalibrationSnapshot.snapshotTriggerURL)
            do {
                try await CalibrationSnapshot.captureIncludingOverlay()
                TutorDebugLog.write("📸 snapshot saved")
            } catch {
                TutorDebugLog.write("⚠️ snapshot failed: \(error.localizedDescription)")
            }
        }
    }

    /// As if spoken: the connections are warmed the way holding the keys
    /// warms them, then the question goes in after a speaking-length pause,
    /// so timings match real use instead of a cold start.
    func qaAsk(_ text: String) {
        if APIKeyStore.hasKey(for: .anthropic) { claudeBrain.prewarmConnection() }
        narrationVoice.prewarmConnection()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            sendTranscriptToTutorWithScreenshot(transcript: text)
        }
    }
    func qaPressEscape() { handleEscape() }
    /// Control + Option held and let go, as the shortcut monitor reports
    /// them, so a spoken question can be tested through the real microphone.
    /// Through the same handler as the real keys, so setup's trial,
    /// teach-back and the error offer see a scripted press as they would a real one.
    func qaHoldTalkKeys(down: Bool) { handleShortcutTransition(down ? .pressed : .released) }
    func qaOpenChat() { openChatForTyping() }
    func qaSetNotchTab(_ name: String) {
        // "chat" is the tab's name now; "transcript" still works for older scripts.
        controlBar.model.selectedTab = name == "settings" ? .settings : (name == "transcript" || name == "chat" ? .transcript : .lesson)
    }
    func qaSetChatDraft(_ text: String) { controlBar.model.chatDraft = text }
    func qaSendChat() { controlBar.qaSendDraft() }
    func qaCloseChat() { controlBar.qaFinishTyping() }
    func qaPressChatReturn(withShift: Bool) { controlBar.qaPressReturn(withShift: withShift) }
    /// Held open while the snapshot is taken: the pointer is not over it.
    func qaSetNotchOpen(_ open: Bool) {
        controlBar.model.isPinnedOpen = open
        controlBar.model.isExpanded = open
    }
    func qaLogState() {
        let model = controlBar.model
        TutorDebugLog.write("🧪 state: activity=\(model.activity) stage=\(model.waitingStage ?? "-") expanded=\(model.isExpanded) "
            + "answeredBy=\(model.answeredBy) buildsOn=\(model.buildsOn) keyProblem=\(model.keyProblemMessage ?? "-") "
            + "followUps=\(model.followUps.map(\.title)) memory=\(learningMemory.conceptCount) brain=\(brainKind.rawValue) "
            + "claude=\(canUseClaude) argon=\(canUseArgon) vertex=\(usesVertexForArgon) setupNeeded=\(needsSetup) "
            + "tab=\(model.selectedTab) chatFocused=\(model.isChatFocused) chatDraft=\(model.chatDraft.count) "
            + "front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-") appActive=\(NSApp.isActive) "
            + "transcript=\(model.transcript.count) howtos=\(howToMemory.count) spentToday=\(SpendingMeter.shared.today.dollars)")
    }
}
#endif
