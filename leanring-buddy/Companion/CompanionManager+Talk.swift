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
                if !isRecording, !isFinalizing, !isPreparing,
                   self.earlyScreenCapture.isHoldingCapture,
                   self.earlyScreenCapture.keysWereReleasedForHeldCapture {
                    self.earlyScreenCapture.discard(reason: "no question was heard")
                    self.pointerRestsOfLastPress = []
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
        pendingTalkStart?.cancel()
        pendingTalkStart = nil
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
        earlyScreenCapture.discard(reason: "the keys became Control + Option + T")
        pointerRestWatcher.cancel()
        pointerRestsOfLastPress = []
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

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
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
            // Control + Option + T starts with the same two keys. Waiting a
            // fifth of a second before listening lets the T arrive first, so
            // typing never turns the mic on, plays the listening sound or
            // cuts off an answer. It is shorter than anyone takes to start
            // speaking after the keys go down.
            pendingTalkStart?.cancel()
            pendingTalkStart = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.talkStartDelaySeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.pendingTalkStart = nil
                self.beginTalking()
            }
        case .released:
            if teachingBoard.talkKeysReleased() { return } // Teach it back hook.
            // Let go before listening began: a tap of the keys, or the T took
            // them for typing. Nothing was started, so nothing is stopped.
            if let pendingTalkStart {
                pendingTalkStart.cancel()
                self.pendingTalkStart = nil
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
    private static let talkStartDelaySeconds: TimeInterval = 0.2

    /// Words the recognizer should expect, from three places, so jargon is
    /// expected whether or not it is on screen right now:
    /// the screen Buddy last read ("Wallet DB", "Kafka", "O(n)"), the labels
    /// Buddy itself drew in the last few answers, and the ideas the student
    /// has learned most recently. Deepgram takes about 60 terms, so each
    /// source gets a share instead of the screen crowding the others out.
    static func speechHints(
        screenLabels: [String],
        recentAnswerPrograms: [String],
        recentlyLearnedConceptNames: [String]
    ) -> [String] {
        var seen = Set<String>()
        func cleaned(_ hint: String) -> String? {
            // Sentence punctuation only: the brackets in "O(n)" are part of it.
            let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?\"'")))
            guard trimmed.count >= 2, trimmed.count <= 40, trimmed.split(separator: " ").count <= 4 else { return nil }
            return trimmed
        }

        // Screens are full of things nobody says: times, file ids, counters,
        // symbols. Each takes one of the few places Deepgram has, so only
        // text that is mostly letters is kept, and a word with digits only
        // when it is short, like "v2", "S3" or "O(n)".
        func isSpeakable(_ text: String) -> Bool {
            let letterCount = text.filter(\.isLetter).count
            let digitCount = text.filter(\.isNumber).count
            let wordsWithDigitsAreShort = text.split(separator: " ")
                .allSatisfy { word in !word.contains(where: \.isNumber) || word.count <= 6 }
            return letterCount >= 2 && letterCount * 2 >= text.count && digitCount <= 2 && wordsWithDigitsAreShort
        }
        var screenHints: [String] = []
        for label in screenLabels {
            let words = label.split(separator: " ")
            // A short label is usually a name: a box, a button, a heading.
            if words.count <= 4, let hint = cleaned(label), isSpeakable(hint) { screenHints.append(hint) }
            // Inside longer text, keep the words a recognizer would not guess:
            // capitals after the first letter, digits, acronyms.
            for word in words where word.count >= 3 {
                let text = String(word)
                let hasInnerCapital = text.dropFirst().contains(where: \.isUppercase)
                let hasDigit = text.contains(where: \.isNumber)
                if hasInnerCapital || hasDigit, let hint = cleaned(text), isSpeakable(hint) { screenHints.append(hint) }
            }
        }

        // The short quoted strings in Buddy's own programs are its card
        // labels and headings: the terms of the topic being discussed.
        var answerHints: [String] = []
        let quotedString = try! NSRegularExpression(pattern: #""([^"\n]{2,40})""#)
        // Spoken sentences are skipped: they are not terms, and a quote
        // inside one would split it into fragments.
        let drawingLines = recentAnswerPrograms.reversed().flatMap { $0.split(separator: "\n") }
            .map(String.init).filter { !$0.contains("say(") }
        for line in drawingLines {
            let range = NSRange(line.startIndex..., in: line)
            for match in quotedString.matches(in: line, range: range) {
                guard let textRange = Range(match.range(at: 1), in: line) else { continue }
                let text = String(line[textRange])
                // Colours, pixel sizes and style names are not words.
                guard text.contains(where: \.isLetter), !text.hasPrefix("#"), text != text.lowercased() || text.contains(" ") else { continue }
                if let hint = cleaned(text) { answerHints.append(hint) }
            }
        }

        let conceptHints = recentlyLearnedConceptNames.compactMap(cleaned)

        var hints: [String] = []
        func take(_ source: [String], upTo limit: Int) {
            var taken = 0
            for hint in source where taken < limit {
                if seen.insert(hint.lowercased()).inserted {
                    hints.append(hint)
                    taken += 1
                }
            }
        }
        take(screenHints, upTo: 30)
        take(answerHints, upTo: 15)
        take(conceptHints, upTo: 15)
        // Whatever share a source did not use goes to the screen.
        take(screenHints, upTo: 100)
        return Array(hints.prefix(100))
    }

    func beginTalking() {
            guard !buddyDictationManager.isDictationInProgress else { return }
            // The talk keys work over an answer exactly as before: the
            // talk-over microphone closes before listening for the question.
            talkOverListener.stop()
            buddyDictationManager.updateContextualKeyterms(Self.speechHints(
                screenLabels: Array(screenIndex.lastListedLabels.values),
                recentAnswerPrograms: conversation.exchanges.suffix(3).map(\.assistantResponse),
                recentlyLearnedConceptNames: learningMemory.recentlyExplainedConceptNames(limit: 15)))
            stopGuide(reason: "the student is talking")
            // The screen is read now, while they talk, rather than after they
            // let go; at release it is checked against the screen as it is then.
            TutorDebugLog.write("⏱ keys down: reading the screen while the student talks")
            earlyScreenCapture.start()
            pointerRestsOfLastPress = []
            pointerRestWatcher.start()
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
            markDismissalTask?.cancel()
            markDismissalTask = nil
            diagramTask?.cancel()
            diagramTask = nil
            cancelSpeechAndClearQueue()
            clearDetectedElementLocation()
            clearAnnotations()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        InterfaceSounds.shared.play(.sent)
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        guard let self else { return }
                        // What "this" means: where the pointer rested while
                        // they talked, and what is selected now.
                        let studentPointing = StudentPointingClues(
                            pointerRests: self.pointerRestsOfLastPress,
                            selection: SelectedTextReader.selectionInFrontApp())
                        self.pointerRestsOfLastPress = []
                        self.sendTranscriptToTutorWithScreenshot(
                            transcript: finalTranscript,
                            earlyScreen: self.earlyScreenCapture.handOverToQuestion(),
                            studentPointing: studentPointing)
                    }
                )
            }
    }

    func finishTalking() {
            shortcutReleasedAt = Date()
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            earlyScreenCapture.keysWereReleased()
            pointerRestsOfLastPress = pointerRestWatcher.stop()
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
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
