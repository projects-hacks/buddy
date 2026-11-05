//
//  TalkSessionCoordinator.swift
//  leanring-buddy
//
//  One press of the talk keys: the short wait before listening that lets
//  Control + Option + T become typing, the screen read and the pointer
//  watched while the student talks, the microphone through the dictation
//  manager, and handing the question, its early screen and what "this"
//  pointed at to whoever answers. Taking a press back (Esc, typing) undoes
//  all of it at once. What a press clears or prepares around it is the
//  manager's, which calls in here.
//

import Foundation

@MainActor
final class TalkSessionCoordinator {
    private let dictation: BuddyDictationManager

    /// The screen read while the keys are held, for the question they end in.
    let earlyScreenCapture = EarlyScreenCapture()
    /// Where the pointer rested while the keys were held, and the rests of
    /// the press just ended, until its question claims them.
    let pointerRestWatcher = PointerRestWatcher()
    private var pointerRestsOfLastPress: [PointerRest] = []

    /// The wait between the keys going down and listening.
    private var pendingTalkStart: Task<Void, Never>?
    /// The dictation manager starting to listen, which takes a moment.
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?

    /// When the keys were let go, for the stage timings in the log: the only
    /// latency the student feels is from then to the first spoken word.
    var shortcutReleasedAt: Date?

    static let talkStartDelaySeconds: TimeInterval = 0.2

    init(dictation: BuddyDictationManager) {
        self.dictation = dictation
    }

    /// The keys went down and listening has not begun yet.
    var isWaitingToListen: Bool { pendingTalkStart != nil }

    /// Control + Option + T starts with the same two keys. Waiting a
    /// fifth of a second before listening lets the T arrive first, so
    /// typing never turns the mic on, plays the listening sound or
    /// cuts off an answer. It is shorter than anyone takes to start
    /// speaking after the keys go down.
    func keysPressed(thenBeginTalking beginTalking: @escaping () -> Void) {
        pendingTalkStart?.cancel()
        pendingTalkStart = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.talkStartDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingTalkStart = nil
            beginTalking()
        }
    }

    /// Let go before listening began: a tap of the keys, or the T took them
    /// for typing. Nothing was started, so nothing is stopped. Whether that
    /// was the case.
    func keysReleasedBeforeListening() -> Bool {
        guard let pendingTalkStart else { return false }
        pendingTalkStart.cancel()
        self.pendingTalkStart = nil
        return true
    }

    /// The Mac is going to sleep: a press waiting to listen never will.
    func cancelPendingStart() {
        pendingTalkStart?.cancel()
        pendingTalkStart = nil
    }

    /// Takes the press back: nothing heard is sent, and the screen read and
    /// the pointer's rests for it are dropped.
    func takeBackPress(reason: String) {
        pendingTalkStart?.cancel()
        pendingTalkStart = nil
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        dictation.cancelCurrentDictation(preserveDraftText: false)
        earlyScreenCapture.discard(reason: reason)
        pointerRestWatcher.cancel()
        pointerRestsOfLastPress = []
    }

    /// Listening ended with nothing heard. A question that was heard has
    /// claimed the early capture by then, since the transcript is handed
    /// over before this is reported; one still held was for nothing.
    func dropCaptureNoQuestionClaimed() {
        guard earlyScreenCapture.isHoldingCapture, earlyScreenCapture.keysWereReleasedForHeldCapture else { return }
        earlyScreenCapture.discard(reason: "no question was heard")
        pointerRestsOfLastPress = []
    }

    /// The screen is read now, while they talk, rather than after they
    /// let go; at release it is checked against the screen as it is then.
    func startReadingTheScreen() {
        TutorDebugLog.write("⏱ keys down: reading the screen while the student talks")
        earlyScreenCapture.start()
        pointerRestsOfLastPress = []
        pointerRestWatcher.start()
    }

    /// Opens the microphone. `onHeard` is told the words as soon as they are
    /// final; `onQuestion` then gets them with the screen read while they
    /// were said and what "this" meant.
    func startListening(
        onHeard: @escaping (_ finalTranscript: String) -> Void,
        onQuestion: @escaping (_ finalTranscript: String, _ earlyScreen: Task<PreparedScreen?, Never>?,
                               _ studentPointing: StudentPointingClues) -> Void
    ) {
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = Task {
            await dictation.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { _ in
                    // Partial transcripts are hidden (waveform-only UI)
                },
                submitDraftText: { [weak self] finalTranscript in
                    onHeard(finalTranscript)
                    guard let self else { return }
                    // What "this" means: where the pointer rested while
                    // they talked, and what is selected now.
                    let studentPointing = StudentPointingClues(
                        pointerRests: self.pointerRestsOfLastPress,
                        selection: SelectedTextReader.selectionInFrontApp())
                    self.pointerRestsOfLastPress = []
                    onQuestion(finalTranscript, self.earlyScreenCapture.handOverToQuestion(), studentPointing)
                }
            )
        }
    }

    /// The keys went up after listening began.
    func finishListening() {
        shortcutReleasedAt = Date()
        // Cancel the pending start task in case the user released the shortcut
        // before the async startPushToTalk had a chance to begin recording.
        // Without this, a quick press-and-release drops the release event and
        // leaves the waveform overlay stuck on screen indefinitely.
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        earlyScreenCapture.keysWereReleased()
        pointerRestsOfLastPress = pointerRestWatcher.stop()
        dictation.stopPushToTalkFromKeyboardShortcut()
    }

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
}
