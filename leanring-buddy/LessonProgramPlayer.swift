//
//  LessonProgramPlayer.swift
//  leanring-buddy
//
//  Plays one answer written as a drawing program: sentences go to the voice
//  as soon as they close, code goes to the drawing engine as soon as a piece
//  is whole, and the voice tells the engine when each sentence starts and
//  how long it lasts so the pen keeps pace.
//
//  The voice leads and the pen follows, never the reverse. A sentence is
//  spoken the moment it exists; if its marks arrive late they are drawn in
//  whatever time the sentence has left, and if the sentence ends first they
//  appear at once.
//

import AppKit
import Foundation

/// One answer as it was heard and drawn, kept in memory only, so "say that
/// again" plays it back with no model and no speech request.
struct AnswerRecording {
    let program: String
    let sentences: [RecordedSentence]
    let canvasSize: CGSize
    let targets: [String: [Double]]
    let targetLabels: [String: String]
    let screenInkHex: String
    /// The display drawn on, and a thumbnail of it at the time, so a replay
    /// can tell whether marks pinned to the screen's content still fit.
    let displayFrame: CGRect
    let screenThumbnail: [UInt8]?
}

@MainActor
final class LessonProgramPlayer {
    private let overlay: DrawingOverlay
    private let voice: NarrationVoice
    private let bar: TutorControlBarModel

    private var stream = ProgramStream()
    private var sentences: [String] = []
    private var pendingPieces: [String] = []
    private var pieceRunner: Task<Void, Never>?
    private(set) var lessonTitle: String?
    private(set) var hasDrawing = false
    /// Sentences already written into the transcript, so one said again
    /// for "go back" is not written twice.
    private var sentencesRecordedInTranscript = Set<Int>()

    /// What the answer on screen was drawn over, and its program so far,
    /// for keeping it as a recording.
    private struct AnswerSetup {
        let canvasSize: CGSize
        let targets: [String: [Double]]
        let targetLabels: [String: String]
        let screenInkHex: String
        let displayFrame: CGRect
        let screenThumbnail: [UInt8]?
    }
    private var currentAnswerSetup: AnswerSetup?
    private var currentProgramText = ""
    /// The last answer heard before the one now on screen.
    private var previousAnswerRecording: AnswerRecording?
    /// A replay is not a new turn: its sentences are not written into the
    /// transcript again.
    private(set) var isReplaying = false

    var isSpeaking: Bool { voice.isSpeaking }

    /// The anchors of marked items, whenever a piece of the program adds one.
    var onAnchorsChanged: (([String]) -> Void)?

    /// For the stage timings: the moment the first sentence has closed and
    /// goes to the voice, and the moment the student starts hearing it.
    var onFirstSentenceReady: (() -> Void)?
    var onFirstSentenceHeard: (() -> Void)?

    /// Teaching board hook (TeachingBoardSession): while the board is open,
    /// each piece's board calls are replaced by exact strokes before it runs.
    var transformPieceBeforeRunning: ((String) -> String)?

    init(overlay: DrawingOverlay, voice: NarrationVoice, bar: TutorControlBarModel) {
        self.overlay = overlay
        self.voice = voice
        self.bar = bar

        voice.onLineStarted = { [weak self] index, seconds in
            guard let self else { return }
            TutorDebugLog.write("🗣️ sentence \(index + 1) starts, \(String(format: "%.1f", seconds))s")
            if index == 0 { self.onFirstSentenceHeard?() }
            self.overlay.playLine(index, seconds: seconds)
            if index < self.sentences.count {
                self.bar.caption = self.sentences[index]
                if !self.isReplaying, self.sentencesRecordedInTranscript.insert(index).inserted {
                    self.bar.recordTutorSentence(self.sentences[index])
                }
            }
            self.bar.isSpeaking = true
        }
        voice.onLineDurationKnown = { [weak self] index, seconds in
            self?.overlay.updateLineDuration(index, seconds: seconds)
        }
        voice.onLineFinished = { [weak self] index in
            self?.overlay.finishLine(index)
        }
    }

    /// Readies the screen for a new answer over a screenshot of `canvasSize`.
    /// Whatever the last answer drew is cleared: the screen may have changed
    /// under it, and a new question deserves a clean board.
    func begin(on screen: NSScreen, canvasSize: CGSize, targets: [String: [Double]],
               targetLabels: [String: String] = [:], screenInkHex: String,
               screenThumbnail: [UInt8]? = nil, screenMarksHidden: Bool = false) {
        stop()
        isReplaying = false
        currentAnswerSetup = AnswerSetup(canvasSize: canvasSize, targets: targets, targetLabels: targetLabels,
                                         screenInkHex: screenInkHex, displayFrame: screen.frame,
                                         screenThumbnail: screenThumbnail)
        currentProgramText = ""
        stream = ProgramStream()
        sentences = []
        sentencesRecordedInTranscript = []
        pendingPieces = []
        lessonTitle = nil
        overlay.show(on: screen)
        overlay.clearAll()
        overlay.beginAnswer(canvasSize: canvasSize, targets: targets, targetLabels: targetLabels, screenInkHex: screenInkHex,
                            screenMarksHidden: screenMarksHidden)
        hasDrawing = false
        bar.caption = ""
        bar.followUps = []
        bar.hasDrawing = false
    }

    /// Takes the whole answer streamed so far.
    func feed(accumulatedText: String) {
        currentProgramText = accumulatedText
        apply(stream.feed(accumulatedText: accumulatedText))
    }

    /// Takes the finished answer and waits for every piece of it to run.
    func finish(fullText: String) async {
        currentProgramText = fullText
        apply(stream.finish(fullText: fullText))
        await pieceRunner?.value
    }

    /// Waits until the last sentence has been spoken, then makes sure every
    /// mark is down.
    func waitUntilSpoken() async {
        while voice.isSpeaking {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
        }
        overlay.finishAll()
        bar.isSpeaking = false
    }

    /// Stops talking. What is drawn stays, completed, so a barge-in does not
    /// throw away the picture.
    func stop() {
        // Kept before the voice lets go of its audio.
        if let recording = recordingOfAnswerOnScreen() { previousAnswerRecording = recording }
        voice.stop()
        pieceRunner?.cancel()
        pieceRunner = nil
        pendingPieces = []
        overlay.finishAll()
        bar.isSpeaking = false
    }

    /// Takes everything down.
    func clear() {
        if hasDrawing { TutorDebugLog.write("🧽 drawing cleared") }
        stop()
        overlay.clearAll()
        hasDrawing = false
        bar.caption = ""
        bar.followUps = []
        bar.hasDrawing = false
    }

    // MARK: - Playing an answer again

    /// The answer heard last: the one on screen if any of it was heard,
    /// otherwise the one before it.
    func recordingOfLastAnswer() -> AnswerRecording? {
        recordingOfAnswerOnScreen() ?? previousAnswerRecording
    }

    private func recordingOfAnswerOnScreen() -> AnswerRecording? {
        guard let currentAnswerSetup else { return nil }
        let recordedSentences = voice.recordedSentences()
        guard !recordedSentences.isEmpty else { return nil }
        return AnswerRecording(
            program: Self.program(currentProgramText, keepingSentences: recordedSentences.count),
            sentences: recordedSentences,
            canvasSize: currentAnswerSetup.canvasSize,
            targets: currentAnswerSetup.targets,
            targetLabels: currentAnswerSetup.targetLabels,
            screenInkHex: currentAnswerSetup.screenInkHex,
            displayFrame: currentAnswerSetup.displayFrame,
            screenThumbnail: currentAnswerSetup.screenThumbnail)
    }

    /// Plays a recorded answer again: its own audio, its own drawing. With
    /// `includeScreenMarks` false the marks pinned to the screen's content
    /// are left out, since that content has moved, and the cards stay.
    func replay(_ recording: AnswerRecording, on screen: NSScreen, includeScreenMarks: Bool) async {
        begin(on: screen, canvasSize: recording.canvasSize, targets: recording.targets,
              targetLabels: recording.targetLabels, screenInkHex: recording.screenInkHex,
              screenThumbnail: recording.screenThumbnail, screenMarksHidden: !includeScreenMarks)
        isReplaying = true
        replayedSentences = recording.sentences
        await finish(fullText: recording.program)
    }

    /// The sentences a replay speaks, from its recording, in place of new audio.
    private var replayedSentences: [RecordedSentence] = []

    /// A program cut before its sentence number `count` (counting from
    /// zero), so a replay of an answer cut off ends where the student
    /// stopped hearing it.
    static func program(_ programText: String, keepingSentences count: Int) -> String {
        let code = ProgramStream.code(in: programText)
        var kept: [Substring] = []
        var sentencesSoFar = 0
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let sentencesInLine = ProgramStream.closedSayArguments(in: String(line)).count
            if sentencesInLine > 0 && sentencesSoFar + sentencesInLine > count { break }
            sentencesSoFar += sentencesInLine
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Talking over the answer

    var isPaused: Bool { voice.isPaused }
    func pauseVoice() { voice.pause() }
    func resumeVoice() { voice.resume() }
    func slowDown() { voice.slowDown() }
    func repeatPreviousSentence() { voice.repeatPreviousSentence() }

    /// The sentence being said and the two before it: what Buddy's own
    /// voice would sound like coming back through the microphone.
    var recentlySpokenSentences: [String] {
        guard let current = voice.currentLineIndex, current < sentences.count else {
            return Array(sentences.suffix(1))
        }
        return Array(sentences[max(0, current - 2)...current])
    }

    /// What the student has heard of this answer so far, for an answer cut
    /// off by a question.
    var sentencesSpokenSoFar: [String] {
        sentencesRecordedInTranscript.sorted().compactMap { index in index < sentences.count ? sentences[index] : nil }
    }

    /// The sentence being said, for the caption after a pause.
    var currentSentence: String? {
        guard let current = voice.currentLineIndex, current < sentences.count else { return nil }
        return sentences[current]
    }

    func clearScreenMarks() { overlay.clearScreenMarks() }
    func placeAnchors(_ placements: [AnchorPlacement], animate: Bool) { overlay.placeAnchors(placements, animate: animate) }
    func scrollScreenMarks(byPoints points: CGFloat) { overlay.scrollScreenMarks(byPoints: points) }

    // MARK: -

    private func apply(_ update: ProgramStream.Update) {
        for sentence in update.newSentences {
            sentences.append(sentence)
            if isReplaying {
                let index = sentences.count - 1
                if index < replayedSentences.count { voice.enqueueRecorded(replayedSentences[index]) }
            } else {
                voice.enqueue(sentence)
            }
            if sentences.count == 1 { onFirstSentenceReady?() }
        }
        guard !update.newPieces.isEmpty else { return }
        pendingPieces.append(contentsOf: update.newPieces)
        if pieceRunner == nil { runPieces() }
    }

    /// Runs pieces strictly in order, since a later piece uses the cards an
    /// earlier one opened.
    private func runPieces() {
        pieceRunner = Task { [weak self] in
            guard let self else { return }
            while !self.pendingPieces.isEmpty, !Task.isCancelled {
                let piece = self.pendingPieces.removeFirst()
                let pieceToRun = self.transformPieceBeforeRunning?(piece) ?? piece
                let result = await self.overlay.run(programPiece: pieceToRun)
                if !result.errors.isEmpty {
                    TutorDebugLog.write("⚠️ drawing program: \(result.errors.joined(separator: "; "))")
                }
                if !result.newButtons.isEmpty {
                    self.bar.followUps.append(contentsOf: result.newButtons.prefix(3))
                }
                if let title = result.lessonTitle { self.lessonTitle = title }
                if !result.anchorIds.isEmpty { self.onAnchorsChanged?(result.anchorIds) }
                // Anything drawn makes Clear worth showing.
                if result.newMarkCount > 0 && !self.hasDrawing {
                    self.hasDrawing = true
                    self.bar.hasDrawing = true
                }
            }
            self.pieceRunner = nil
        }
    }
}
