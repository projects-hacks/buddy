//
//  CompanionManager+Speech.swift
//  leanring-buddy
//
//  The prose path's voice as the manager reaches it, from ProseSpeechQueue:
//  the engines, what the queue reports back, and clearing it for a new answer.
//

import Foundation

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
            return self.marks.marksFollowingSpeech(of: segment)
        }
        proseSpeech.onDeepgramWorked = { [weak self] in self?.clearDeepgramKeyProblemIfReported() }
        proseSpeech.onDeepgramKeyProblem = { [weak self] error in self?.reportDeepgramKeyProblem(error) }
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
