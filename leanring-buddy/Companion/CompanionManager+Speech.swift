//
//  CompanionManager+Speech.swift
//  leanring-buddy
//
//  The prose path's voice: sentences queued from the stream and
//  spoken one after another by whichever engine is in use.
//

import AVFoundation
import Foundation
import SwiftUI

extension CompanionManager {
    /// Location of the speech helper: shipped inside the app, so it is found
    /// on any Mac and wherever the source checkout lives. Overridable through
    /// defaults, for trying a changed script without a rebuild.
    static var kokoroHelperScriptPath: String {
        if let overridePath = UserDefaults.standard.string(forKey: "kokoroHelperScriptPath") {
            return overridePath
        }
        return Bundle.main.path(forResource: "kokoro_speech_server", ofType: "py") ?? ""
    }

    // MARK: - Progressive speech

    /// Pulls any newly completed sentences out of the stream and queues them.
    func enqueueCompletedSentences(fromStreamedText streamedText: String) {
        guard let chunk = TeacherResponseParser.nextSpeakableChunk(
            fromStreamedText: streamedText,
            alreadySpokenCharacterCount: streamedCharactersAlreadyQueued
        ) else { return }

        streamedCharactersAlreadyQueued += chunk.count
        enqueueParsedSegment(TeacherResponseParser.parse(rawResponse: chunk))
    }

    /// Queues the tail that followed the last sentence terminator.
    func enqueueRemainder(ofStreamedText fullText: String) {
        guard streamedCharactersAlreadyQueued < fullText.count else { return }

        let startIndex = fullText.index(fullText.startIndex, offsetBy: streamedCharactersAlreadyQueued)
        let remainder = String(fullText[startIndex...])
        streamedCharactersAlreadyQueued = fullText.count

        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        enqueueParsedSegment(TeacherResponseParser.parse(rawResponse: remainder))
    }

    private func enqueueParsedSegment(_ segment: ParsedTeacherResponse) {
        // A segment that was nothing but tags still carries marks worth drawing.
        guard !segment.spokenText.isEmpty || !segment.directives.isEmpty else { return }

        if !segment.directives.isEmpty {
            TutorDebugLog.write("✏️ segment carries \(segment.directives.count) mark(s)")
        }

        pendingSpeechSegments.append(segment)
        startSpeechConsumerIfIdle()
    }

    private func startSpeechConsumerIfIdle() {
        guard speechConsumerTask == nil else { return }

        let consumerIdentifier = UUID()
        currentSpeechConsumerIdentifier = consumerIdentifier
        speechConsumerTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.currentSpeechConsumerIdentifier == consumerIdentifier {
                    self.speechConsumerTask = nil
                    self.currentSpeechConsumerIdentifier = nil
                }
            }

            // Audio for the sentence after the current one, rendered while the
            // current one plays. Without this the speech stopped for a second
            // and a half before every sentence, which is what made it sound
            // halting instead of fluent: rendering only started once the
            // previous sentence had finished.
            var prefetchedClipTask: Task<KokoroSpeechClient.GeneratedClip, Error>?

            while !self.pendingSpeechSegments.isEmpty {
                guard !Task.isCancelled, self.currentSpeechConsumerIdentifier == consumerIdentifier else { break }

                let segment = self.pendingSpeechSegments.removeFirst()
                if !segment.spokenText.isEmpty {
                    self.controlBar.model.recordTutorSentence(segment.spokenText)
                }

                if self.voiceState != .responding {
                    self.voiceState = .responding
                }

                let clipTaskForThisSegment = prefetchedClipTask
                prefetchedClipTask = nil

                // Start the next sentence rendering before speaking this one.
                // Only Kokoro needs this: it renders a whole clip before
                // playing, so without a lookahead every sentence began with a
                // second and a half of silence. Deepgram streams into the
                // engine as bytes arrive and reaches first audio in about a
                // sixth of a second, so there is no gap worth hiding.
                if self.voiceEngine == .kokoro,
                   let nextSegment = self.pendingSpeechSegments.first,
                   !nextSegment.spokenText.isEmpty {
                    prefetchedClipTask = self.kokoroClient.beginGeneratingClip(
                        for: nextSegment.spokenText
                    )
                }

                // A ceiling on how long one sentence may take. Without it a
                // single stalled playback holds the pipeline open and the user
                // gets no answer at all and no error explaining why, which is
                // precisely what an audio format mismatch caused: buffers were
                // silently dropped, the completion handler never fired, and
                // everything waited on a sentence that was never spoken.
                let finishedSpeaking: Void? = try? await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in
                        await self.speak(segment: segment, prerenderedClip: clipTaskForThisSegment)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 45_000_000_000)
                        throw CancellationError()
                    }
                    try await group.next()
                    group.cancelAll()
                }

                if finishedSpeaking == nil {
                    TutorDebugLog.write("⚠️ sentence never finished speaking, abandoning the rest")
                    // Only the speech: the stream's place is kept, so the
                    // sentences still to come are spoken, not the answer again
                    // from its start.
                    self.abandonQueuedSpeech()
                    break
                }
            }
        }
    }

    /// Stops every voice and drops the sentences waiting, but keeps how far
    /// the answer's stream has been read and what format it is.
    private func abandonQueuedSpeech() {
        speechConsumerTask?.cancel()
        speechConsumerTask = nil
        currentSpeechConsumerIdentifier = nil
        pendingSpeechSegments.removeAll()
        speechClient.onWillSpeakRange = nil
        speechClient.stopPlayback()
        kokoroClient.onSpokenProgress = nil
        kokoroClient.stopPlayback()
        deepgramClient.onSpokenProgress = nil
        deepgramClient.stopPlayback()
    }

    /// Speaks one segment, drawing its marks as the words carrying them are said.
    ///
    /// Both engines report progress as a character offset into the text, but
    /// they measure it very differently. AVSpeechSynthesizer reports real word
    /// boundaries as it speaks them. Kokoro hands back a finished waveform with
    /// no timing at all, so its offsets are interpolated from elapsed playback.
    /// That is an estimate, and it only has to be close enough to land a mark
    /// in the right clause.
    private func speak(
        segment: ParsedTeacherResponse,
        prerenderedClip: Task<KokoroSpeechClient.GeneratedClip, Error>? = nil
    ) async {
        var undispatchedDirectives = segment.directives
        let charactersBeforeThisSegment = charactersSpokenInAnswer

        // Until the stream finishes the total is unknown, so it is estimated
        // from what has been queued. Otherwise the first segment would divide
        // by nothing and the board would appear complete immediately.
        if totalCharactersInAnswer == 0 {
            totalCharactersInAnswer = max(1, charactersBeforeThisSegment + segment.spokenText.count * 3)
        }

        func drawMarksReached(upToCharacterOffset offset: Int) {
            let spokenOverall = charactersBeforeThisSegment + offset
            charactersSpokenInAnswer = max(charactersSpokenInAnswer, spokenOverall)
            let fraction = Double(charactersSpokenInAnswer) / Double(max(1, totalCharactersInAnswer))
            // Monotonic: a diagram must never un-draw itself mid-sentence.
            if fraction > boardRevealFraction {
                withAnimation(.easeOut(duration: 0.35)) {
                    boardRevealFraction = min(1.0, fraction)
                }
            }

            while let next = undispatchedDirectives.first,
                  Self.offsetWhereMarkedPhraseBegins(
                    tagOffset: next.characterOffsetInSpokenText,
                    spokenText: segment.spokenText
                  ) <= offset {
                undispatchedDirectives.removeFirst()
                apply(directive: next, spokenContext: segment.spokenText)
            }
        }

        // A segment that is nothing but tags still has marks worth drawing.
        guard !segment.spokenText.isEmpty else {
            drawMarksReached(upToCharacterOffset: Int.max)
            return
        }

        let isDeepgramBenched = Date() < deepgramProseVoiceBenchedUntil
        switch voiceEngine == .deepgram && isDeepgramBenched ? .system : voiceEngine {
        case .deepgram:
            deepgramClient.onSpokenProgress = { reachedOffset in
                drawMarksReached(upToCharacterOffset: reachedOffset)
            }
            do {
                // No prefetch needed here. Deepgram streams PCM into the audio
                // engine as it arrives, so the gap before a sentence is about
                // a sixth of a second rather than the second and a half that
                // made rendering ahead worth the complexity for Kokoro.
                try await deepgramClient.speakText(segment.spokenText)
                clearDeepgramKeyProblemIfReported()
            } catch {
                TutorDebugLog.write("⚠️ Deepgram failed: \(error.localizedDescription). system voice for \(Int(NarrationVoice.deepgramBenchSeconds / 60)) minutes.")
                deepgramProseVoiceBenchedUntil = Date().addingTimeInterval(NarrationVoice.deepgramBenchSeconds)
                reportDeepgramKeyProblem(error)
                deepgramClient.onSpokenProgress = nil
                speechClient.onWillSpeakRange = { spokenRange, _ in
                    drawMarksReached(upToCharacterOffset: spokenRange.location + spokenRange.length)
                }
                try? await speechClient.speakText(segment.spokenText)
                speechClient.onWillSpeakRange = nil
            }
            deepgramClient.onSpokenProgress = nil

        case .kokoro:
            kokoroClient.onSpokenProgress = { reachedOffset in
                drawMarksReached(upToCharacterOffset: reachedOffset)
            }
            do {
                // Already rendering, or rendered, from the previous iteration.
                let clipTask = prerenderedClip
                    ?? kokoroClient.beginGeneratingClip(for: segment.spokenText)
                try await kokoroClient.play(clip: try await clipTask.value)
            } catch {
                // Falling back for the rest of the session rather than retrying
                // each sentence: whatever broke the helper will break it again,
                // and a stutter between every sentence is worse than a plainer
                // voice throughout.
                TutorDebugLog.write("⚠️ neural voice failed: \(error.localizedDescription). system voice from here.")
                isUsingNeuralVoice = false
                kokoroClient.onSpokenProgress = nil
                try? await speechClient.speakText(segment.spokenText)
            }
            kokoroClient.onSpokenProgress = nil
            if voiceEngine == .kokoro, !isUsingNeuralVoice { voiceEngine = .system }

        case .system:
            speechClient.onWillSpeakRange = { spokenRange, _ in
                drawMarksReached(upToCharacterOffset: spokenRange.location + spokenRange.length)
            }
            try? await speechClient.speakText(segment.spokenText)
            speechClient.onWillSpeakRange = nil
        }

        // Anything the progress callback never reached, because speech was cut
        // short or the tag sat past the final word.
        drawMarksReached(upToCharacterOffset: segment.spokenText.count)
        charactersSpokenInAnswer = charactersBeforeThisSegment + segment.spokenText.count
    }

    /// Whether either speech engine is currently producing audio.
    var isAnyVoicePlaying: Bool {
        speechClient.isPlaying || kokoroClient.isPlaying || deepgramClient.isPlaying || narrationVoice.isSpeaking
    }

    func cancelSpeechAndClearQueue() {
        endTalkOver()
        abandonQueuedSpeech()
        streamedCharactersAlreadyQueued = 0
        lessonPlayer.stop()
        currentAnswerFormat = .undecided
    }
}
