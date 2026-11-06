//
//  CompanionManager+Talk.swift
//  leanring-buddy
//
//  The talk keys, the typed question, the dictation state bound to
//  the voice state, and talking over an answer without the keys.
//

import AppKit
import Combine
import Foundation

extension CompanionManager {
    /// When the keys were let go, for the stage timings in the log.
    var shortcutReleasedAt: Date? {
        get { talkSession.shortcutReleasedAt }
        set { talkSession.shortcutReleasedAt = newValue }
    }

    func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Listening ended after the keys went up. A question that was
                // heard has claimed the early capture by now, since the
                // transcript is handed over before this is reported; one
                // still held was for nothing. Checked before the guard below,
                // because a press that talks over an answer ends here too.
                if !isRecording, !isFinalizing, !isPreparing {
                    self.talkSession.dropCaptureNoQuestionClaimed()
                }
                // Don't override .responding, the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }
                // Teach it back hook: its own microphone is listening, which
                // the end of the question that started it must not cover.
                guard !self.teachingBoard.isTeachBackListening else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs, schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
        typeQuestionCancellable = globalPushToTalkShortcutMonitor
            .typeQuestionRequestPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.openChatForTyping()
            }
    }

    /// Control + Option + T. The talk keys went down first, so listening has
    /// already begun; it is dropped without sending anything, and the chat
    /// box opens with the keyboard in it.
    func openChatForTyping() {
        TutorDebugLog.write("⌨️ chat opened from the keyboard")
        // Normally the T beats the talk delay and nothing was started. A slow
        // T finds listening begun, which is dropped without sending.
        talkSession.takeBackPress(reason: "the keys became Control + Option + T")
        controlBar.model.heardWords = ""
        errorOffer.studentStartedTyping() // Hook for ErrorOffer.swift.
        controlBar.openChat()
    }

    /// A question typed in the notch's chat box. It is answered exactly as a
    /// spoken one is, out loud and drawn, and lands in the same conversation.
    func askTypedQuestion(_ question: String) {
        TutorDebugLog.write("⌨️ typed: \(question.count) characters")
        // The screen is read at send, not while typing: typing takes long
        // enough that the student often goes back to the page meanwhile, to
        // scroll to the part or copy an error, and the screen at send is the
        // one the question is about. The notch holding the chat box is
        // Buddy's own window, left out of every capture either way.
        // Timed from sending, not from the last time the talk keys were let go.
        shortcutReleasedAt = nil
        if APIKeyStore.hasKey(for: .anthropic) { claudeBrain.prewarmConnection() }
        narrationVoice.prewarmConnection()
        if !isOverlayVisible {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
        transientHideTask?.cancel()
        transientHideTask = nil
        // Text selected in the app before typing is what a typed "this"
        // means. There is no pointer to read: nothing was said while it rested.
        let selection = SelectedTextReader.selectionInFrontApp()
        sendTranscriptToTutorWithScreenshot(transcript: question,
                                            studentPointing: StudentPointingClues(selection: selection))
    }

    func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        // Setup's last step checks the shortcut and the microphone for real.
        // The keys go to that check alone, so nothing is sent to a model.
        if setupWindow.isTryingTheShortcut {
            switch transition {
            case .pressed: setupWindow.shortcutTrial.keysPressed()
            case .released: setupWindow.shortcutTrial.keysReleased()
            case .none: break
            }
            return
        }
        switch transition {
        case .pressed:
            // Teach it back hook: the talk keys end a hands-free explanation
            // as Return does, and start no question of their own.
            if teachingBoard.talkKeysPressed() { return }
            guard !buddyDictationManager.isDictationInProgress else { return }
            errorOffer.talkKeysPressed() // Hook for ErrorOffer.swift.
            talkSession.keysPressed(thenBeginTalking: { [weak self] in self?.beginTalking() })
        case .released:
            if teachingBoard.talkKeysReleased() { return } // Teach it back hook.
            // Let go before listening began: a tap of the keys, or the T took
            // them for typing. Nothing was started, so nothing is stopped.
            if talkSession.keysReleasedBeforeListening() {
                // Hook for ErrorOffer.swift: a tap accepts an offered error.
                errorOffer.talkKeysReleased(listeningBegan: false)
                return
            }
            finishTalking()
            // Hook for ErrorOffer.swift: let go without a word accepts it too.
            errorOffer.talkKeysReleased(listeningBegan: true)
        case .none:
            break
        }
    }
    /// Long enough to look something up; then the mic is not left open on
    /// an answer that is never going to be resumed.
    private static let talkOverHoldLimitSeconds: TimeInterval = 90
    static let joinUnansweredQuestionWithinSeconds: TimeInterval = 90

    func beginTalking() {
            guard !buddyDictationManager.isDictationInProgress else { return }
            // The talk keys work over an answer exactly as before: the
            // talk-over microphone closes before listening for the question.
            talkOverListener.stop()
            buddyDictationManager.updateContextualKeyterms(TalkSessionCoordinator.speechHints(
                screenLabels: Array(screenIndex.lastListedLabels.values),
                recentAnswerPrograms: conversation.exchanges.suffix(3).map(\.assistantResponse),
                recentlyLearnedConceptNames: learningMemory.recentlyExplainedConceptNames(limit: 15)))
            stopGuide(reason: "the student is talking")
            talkSession.startReadingTheScreen()
            // First, so it lands the instant the keys go down: the student
            // hears that the mic is live without looking for the red dot.
            InterfaceSounds.shared.play(.listen)
            // The student is about to talk for a few seconds. That is free
            // time to open the secure connections the answer will need, so
            // the handshake is not paid after they stop.
            // Claude is warmed under every setting that has a key, because the
            // question classifier uses the same connection whichever brain answers.
            if APIKeyStore.hasKey(for: .anthropic) { claudeBrain.prewarmConnection() }
            narrationVoice.prewarmConnection()

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // Make sure there is an overlay to draw into before answering.
            //
            // Upstream only reinstated it when the cursor had been switched
            // off, because every other path had already created it during
            // onboarding. This fork is useful before anyone sits through
            // onboarding, and until that happens the overlay window does not
            // exist, so marks resolve correctly and then render into nothing:
            // the answer is spoken over a completely unmarked screen.
            if !isOverlayVisible {
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Cancel any in-progress response and TTS from a previous utterance
            cancelCurrentResponseTask()
            marks.cancelDismissal()
            diagramTask?.cancel()
            diagramTask = nil
            cancelSpeechAndClearQueue()
            clearDetectedElementLocation()
            clearAnnotations()

            talkStartedAt = TalkOverListener.now
            talkSession.startListening(
                onHeard: { [weak self] finalTranscript in
                    InterfaceSounds.shared.play(.sent)
                    self?.lastTranscript = finalTranscript
                    print("🗣️ Companion received transcript: \(finalTranscript)")
                },
                onQuestion: { [weak self] finalTranscript, earlyScreen, studentPointing in
                    guard let self else { return }
                    // Lecture mode hook: the video's words heard by the
                    // microphone are not the student's.
                    guard let studentsWords = LectureMode.shared.withoutTheLecture(finalTranscript, heardSince: self.talkStartedAt) else {
                        TutorDebugLog.write("🎓 lecture: the microphone heard only the video, nothing sent")
                        earlyScreen?.cancel()
                        return
                    }
                    self.sendTranscriptToTutorWithScreenshot(
                        transcript: studentsWords,
                        earlyScreen: earlyScreen,
                        studentPointing: studentPointing)
                })
    }

    func finishTalking() {
        talkSession.finishListening()
    }

    // MARK: - Talking over an answer

    /// What the student said over the answer, without the keys.
    func handleTalkOver(_ request: TalkOverListener.Request) {
        let model = controlBar.model
        // The notch shows "Buddy paused" while the student cuts in or holds
        // the answer, and goes back to explaining when it carries on.
        func showExplainingAgain() {
            model.talkOverPause = isHeldByTalkOver ? .held : nil
            model.talkOverHeardWords = ""
        }
        switch request {
        case .yield:
            lessonPlayer.pauseVoice()
            model.talkOverPause = .cuttingIn
        case .endYield:
            if !isHeldByTalkOver { lessonPlayer.resumeVoice() }
            showExplainingAgain()
        case .hold:
            lessonPlayer.pauseVoice()
            isHeldByTalkOver = true
            model.talkOverPause = .held
            model.talkOverHeardWords = ""
            // "Buddy paused" is on the right; the line under says how to go on.
            model.caption = "Say \u{201C}go on\u{201D} to carry on."
            talkOverHoldTimeout?.cancel()
            talkOverHoldTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.talkOverHoldLimitSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self, self.isHeldByTalkOver else { return }
                TutorDebugLog.write("👂 talk-over: paused for \(Int(Self.talkOverHoldLimitSeconds))s, ending the answer")
                self.stopAnswering()
            }
        case .resume:
            releaseTalkOverHold()
            showExplainingAgain()
            lessonPlayer.resumeVoice()
            if let currentSentence = lessonPlayer.currentSentence { controlBar.model.caption = currentSentence }
        case .slower:
            lessonPlayer.slowDown()
            if !isHeldByTalkOver { lessonPlayer.resumeVoice() }
            showExplainingAgain()
        case .repeatPreviousSentence:
            releaseTalkOverHold()
            showExplainingAgain()
            lessonPlayer.repeatPreviousSentence()
        case .replayAnswer:
            showExplainingAgain()
            _ = replayLastAnswer(startedBy: "said over the answer")
        case .question(let question):
            // The new question replaces the answer, which clears any hold.
            model.talkOverPause = nil
            model.talkOverHeardWords = ""
            // Cut off and answered with what was heard of this answer, which
            // is not in the conversation until an answer finishes.
            let note = TutorProgramPrompt.interruptionNote(
                interruptedQuestion: questionBeingAnswered ?? "",
                sentencesHeard: lessonPlayer.sentencesSpokenSoFar)
            InterfaceSounds.shared.play(.sent)
            shortcutReleasedAt = nil
            questionAwaitingAnswer = nil
            sendTranscriptToTutorWithScreenshot(
                transcript: question,
                studentPointing: StudentPointingClues(selection: SelectedTextReader.selectionInFrontApp()),
                interruptedAnswerNote: note)
        }
    }

    private func releaseTalkOverHold() {
        isHeldByTalkOver = false
        talkOverHoldTimeout?.cancel()
        talkOverHoldTimeout = nil
    }

    /// Closes the talk-over microphone and forgets any hold.
    func endTalkOver() {
        talkOverListener.stop()
        releaseTalkOverHold()
        controlBar.model.talkOverPause = nil
        controlBar.model.talkOverHeardWords = ""
    }
}
