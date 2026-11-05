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

    var isSpeaking: Bool { voice.isSpeaking }

    /// For the stage timings: the moment the first sentence has closed and
    /// goes to the voice, and the moment the student starts hearing it.
    var onFirstSentenceReady: (() -> Void)?
    var onFirstSentenceHeard: (() -> Void)?

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
                if self.sentencesRecordedInTranscript.insert(index).inserted {
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
               targetLabels: [String: String] = [:], screenInkHex: String) {
        stop()
        stream = ProgramStream()
        sentences = []
        sentencesRecordedInTranscript = []
        pendingPieces = []
        lessonTitle = nil
        overlay.show(on: screen)
        overlay.clearAll()
        overlay.beginAnswer(canvasSize: canvasSize, targets: targets, targetLabels: targetLabels, screenInkHex: screenInkHex)
        hasDrawing = false
        bar.caption = ""
        bar.followUps = []
        bar.hasDrawing = false
    }

    /// Takes the whole answer streamed so far.
    func feed(accumulatedText: String) {
        apply(stream.feed(accumulatedText: accumulatedText))
    }

    /// Takes the finished answer and waits for every piece of it to run.
    func finish(fullText: String) async {
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
    func scrollScreenMarks(byPoints points: CGFloat) { overlay.scrollScreenMarks(byPoints: points) }

    // MARK: -

    private func apply(_ update: ProgramStream.Update) {
        for sentence in update.newSentences {
            sentences.append(sentence)
            voice.enqueue(sentence)
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
                let result = await self.overlay.run(programPiece: piece)
                if !result.errors.isEmpty {
                    TutorDebugLog.write("⚠️ drawing program: \(result.errors.joined(separator: "; "))")
                }
                if !result.newButtons.isEmpty {
                    self.bar.followUps.append(contentsOf: result.newButtons.prefix(3))
                }
                if let title = result.lessonTitle { self.lessonTitle = title }
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
