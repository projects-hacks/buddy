//
//  CompanionManager+Speech.swift
//  leanring-buddy
//
//  The prose path's voice as the manager reaches it, from ProseSpeechQueue:
//  the engines, what the queue reports back, and clearing it for a new answer.
//

import Foundation
import SwiftUI

extension CompanionManager {
    var speechClient: LocalSpeechSynthesisClient { proseSpeech.speechClient }
    var deepgramClient: DeepgramSpeechClient { proseSpeech.deepgramClient }
    var kokoroClient: KokoroSpeechClient { proseSpeech.kokoroClient }

    /// Connects the queue once, at start.
    func connectProseSpeech() {
        proseSpeech.onSentenceStarted = { [weak self] spokenText in
            self?.controlBar.model.recordTutorSentence(spokenText)
        }
        proseSpeech.onWillSpeak = { [weak self] in
            guard let self else { return }
            if self.voiceState != .responding {
                self.voiceState = .responding
            }
        }
        proseSpeech.marksForSegment = { [weak self] segment in
            guard let self else { return ProseSpeechQueue.SegmentMarks(reached: { _ in }, finished: {}) }
            return self.marksFollowingSpeech(of: segment)
        }
        proseSpeech.onDeepgramWorked = { [weak self] in self?.clearDeepgramKeyProblemIfReported() }
        proseSpeech.onDeepgramKeyProblem = { [weak self] error in self?.reportDeepgramKeyProblem(error) }
    }

    /// One sentence's marks, drawn as the words carrying them are said, and
    /// the board revealed as far as the answer has been spoken.
    func marksFollowingSpeech(of segment: ParsedTeacherResponse) -> ProseSpeechQueue.SegmentMarks {
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

        return ProseSpeechQueue.SegmentMarks(
            reached: { offset in drawMarksReached(upToCharacterOffset: offset) },
            finished: { [self] in
                drawMarksReached(upToCharacterOffset: segment.spokenText.count)
                charactersSpokenInAnswer = charactersBeforeThisSegment + segment.spokenText.count
            }
        )
    }

    /// Whether either speech engine is currently producing audio.
    var isAnyVoicePlaying: Bool {
        proseSpeech.isAnyEnginePlaying || narrationVoice.isSpeaking
    }

    func cancelSpeechAndClearQueue() {
        endTalkOver()
        proseSpeech.abandonQueuedSpeech()
        proseSpeech.resetStreamPosition()
        lessonPlayer.stop()
        currentAnswerFormat = .undecided
    }
}
