//
//  CompanionManager+Debug.swift
//  leanring-buddy
//
//  The QA channel's entry points, debug builds only.
//

import AppKit
import Foundation

#if DEBUG
extension CompanionManager {
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
    func qaHoldTalkKeys(down: Bool) { down ? beginTalking() : finishTalking() }
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
