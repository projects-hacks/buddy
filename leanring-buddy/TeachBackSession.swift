//
//  TeachBackSession.swift
//  leanring-buddy
//
//  Teach it back: the student explains a topic to Buddy out loud, Buddy
//  draws what they ACTUALLY said, then rings the gaps and explains them.
//  Explaining is how a student finds out whether they understand, and
//  seeing their own explanation drawn makes the gaps visible.
//
//  One session lives on the teaching board (TeachingBoardSession), which
//  owns the paper, the voice and the brains:
//
//  1. Listening, hands free (TeachBackListener): the board is titled
//     "Teach me {topic}" with the invitation under it and a bar with the
//     live red meter, Listening, I'm done and Cancel. The notch says
//     "you're teaching" with the words as they are heard.
//  2. Their version: one call (TeachBackPrompt.drawingSystem) turns what
//     was heard into board calls drawn in the student's purple, only what
//     they said, wrong claims as stated, while Buddy says one sentence.
//  3. The gaps: a second call (TeachBackPrompt.gapSystem) marks the same
//     board, dashed red outlines for missing parts, red rings with the
//     correction beside them for wrong claims, dashed red arrows for
//     missing links, one sentence each, at most four, and names the ideas
//     right and missed for learning memory. The board refuses any change
//     to the student's drawing while it checks (TeachingBoard).
//  4. Another go: "let me try that part again" (or the bar's Try again)
//     listens again; the old marks are rubbed out, only the part they spoke
//     about is updated in purple, and it is checked again. Any other
//     question is answered on the board as usual.
//
//  On leaving, the board goes into the Notebook and the verdict into
//  learning memory (TeachingBoardSession.close).
//

import Foundation

@MainActor
final class TeachBackSession {
    enum Phase: String {
        case listening, drawing, checking, result
    }

    let topic: String
    private unowned let host: TeachingBoardSession
    private let listener = TeachBackListener()
    private(set) var phase: Phase = .listening
    /// Every go at explaining, in order.
    private(set) var explanations: [String] = []
    private var rightIdeas: [String] = []
    private var missedIdeas: [String] = []
    /// What Buddy said in the session: the "here is what you described"
    /// lines, each gap's sentence and any board answer after.
    private var sentencesSaid: [String] = []

    var isListening: Bool { phase == .listening }

    init(topic: String, host: TeachingBoardSession) {
        self.topic = topic
        self.host = host
    }

    // MARK: - Listening

    func startListening() {
        host.prepareForListening()
        phase = .listening
        host.showTeachBackPhase(Phase.listening.rawValue)
        host.hooks.setVoiceState(.listening)
        host.bar.heardWords = ""
        InterfaceSounds.shared.play(.listen)
        // Return finishes and Esc cancels; the keys go to Buddy, never to
        // the app hidden under the paper.
        host.overlay.takeKeyboard { [weak self] keyCode in
            switch keyCode {
            case 36, 76:
                self?.finishListening()
                return true
            case 53:
                self?.cancelListening()
                return true
            default:
                return false
            }
        }
        listener.onWordsHeard = { [weak self] words in self?.host.bar.heardWords = words }
        listener.onLevel = { [weak self] level in
            self?.host.overlay.callBoard("setLevel", argumentsJSON: String(format: "%.2f", level))
        }
        listener.onEnded = { [weak self] explanation, ending in self?.heard(explanation, ending: ending) }
        listener.start(keyterms: host.hooks.keytermsForTopic(topic))
    }

    /// Return, I'm done, or the talk keys.
    func finishListening() {
        guard isListening else { return }
        listener.finish()
    }

    /// Esc or Cancel. Before anything was drawn this leaves the board with
    /// nothing kept; after, it goes back to the drawing as it was.
    func cancelListening() {
        guard isListening else { return }
        listener.cancel()
        host.overlay.releaseKeyboard()
        host.bar.heardWords = ""
        if explanations.isEmpty {
            host.close(reason: "teach-back cancelled before anything was explained", keepsNothing: true)
            return
        }
        showResult()
    }

    /// "Let me try that part again", Try again, or a fresh "let me explain
    /// the second part".
    func listenAgain() {
        guard !isListening else { return }
        startListening()
    }

    private func heard(_ explanation: String, ending: TeachBackListener.Ending) {
        host.overlay.releaseKeyboard()
        host.listeningEnded()
        InterfaceSounds.shared.play(.sent)
        let wordCount = TalkOverHearing.words(of: explanation).count
        guard wordCount >= 3 else {
            // Nothing worth drawing: say so, and leave Try again to them.
            let sentence: String
            switch ending {
            case .failed:
                sentence = "The microphone stopped before anything was heard, so nothing is drawn. Press Try again when you are ready."
            default:
                sentence = "No explanation was heard, so nothing is drawn. Press Try again when you are ready."
            }
            showResult()
            host.runTeachBackWork { [weak self] in
                await self?.host.speakOnBoard(sentence)
            }
            return
        }
        host.bar.heardWords = explanation
        host.runTeachBackWork { [weak self] in
            await self?.drawAndCheck(explanation)
        }
    }

    // MARK: - Drawing and checking

    private func drawAndCheck(_ explanation: String) async {
        let earlierExplanation = explanations.isEmpty ? nil : explanations.joined(separator: " ")
        explanations.append(explanation)

        // Their version, in their purple. A second go first rubs out the
        // last check's marks, with the new drawing's first sentence.
        phase = .drawing
        host.showTeachBackPhase(Phase.drawing.rawValue)
        let rubbedOutMarks = earlierExplanation == nil ? [] : host.removeGapMarks()
        let drawingNote = TeachBackPrompt.drawingNote(topic: topic, explanation: explanation,
                                                      boardListing: host.boardListing,
                                                      earlierExplanation: earlierExplanation)
        guard let drawn = await host.playBoardAnswer(
            systemPrompt: TeachBackPrompt.drawingSystem, history: [], turnNote: drawingNote,
            maximumTokens: TeachBackPrompt.drawingMaximumTokens, ink: .student,
            commandsWithFirstSentence: rubbedOutMarks, keepsOnlyTheFirstBlock: true) else {
            showResult()
            return
        }
        sentencesSaid += drawn.sentences
        guard !Task.isCancelled else { return }

        // The gaps, marked on the same board in red.
        phase = .checking
        host.showTeachBackPhase(Phase.checking.rawValue)
        let gapNote = TeachBackPrompt.gapNote(topic: topic, explanations: explanations, boardListing: host.boardListing)
        guard let checked = await host.playBoardAnswer(
            systemPrompt: TeachBackPrompt.gapSystem, history: [], turnNote: gapNote,
            maximumTokens: TeachBackPrompt.gapMaximumTokens, ink: .gap, keepsOnlyTheFirstBlock: true) else {
            showResult()
            return
        }
        sentencesSaid += checked.sentences
        for operation in checked.operations {
            if case .verdict(let right, let missed) = operation {
                // The latest check is what they know now.
                rightIdeas = right
                missedIdeas = missed
            }
        }
        TutorDebugLog.write("🎓 teach-back: right \(rightIdeas), missed \(missedIdeas)")
        showResult()
    }

    private func showResult() {
        phase = .result
        host.showTeachBackPhase(Phase.result.rawValue)
    }

    // MARK: - From the board

    /// Esc while Buddy was drawing or checking: the board stays as it is.
    func answerWasStopped() {
        guard !isListening else { return }
        showResult()
    }

    /// A question answered on the board as usual ("fill the gaps").
    func boardAnswerWasGiven(sentences: [String]) {
        sentencesSaid += sentences
        showResult()
    }

    /// The board is closing.
    func end() {
        if isListening { listener.cancel() }
        host.overlay.releaseKeyboard()
    }

    // MARK: - What is kept

    /// For the Notebook page: what they said, then what Buddy said about it.
    var notebookParagraphs: [String] {
        var paragraphs = explanations.enumerated().map { index, explanation in
            (explanations.count > 1 ? "Your explanation, go \(index + 1): " : "Your explanation: ") + "\u{201C}\(explanation)\u{201D}"
        }
        paragraphs += sentencesSaid
        return paragraphs
    }

    /// For learning memory, once something was explained and checked.
    func record(openingQuestion: String) -> TeachBackRecord? {
        guard !explanations.isEmpty, !(rightIdeas.isEmpty && missedIdeas.isEmpty) else { return nil }
        return TeachBackRecord(topic: topic, openingQuestion: openingQuestion, explanations: explanations,
                               rightIdeas: rightIdeas, missedIdeas: missedIdeas,
                               spokenAnswer: sentencesSaid.joined(separator: " "))
    }
}
