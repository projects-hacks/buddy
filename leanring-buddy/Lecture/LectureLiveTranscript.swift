//
//  LectureLiveTranscript.swift
//  leanring-buddy
//
//  The video's words, recognised on the Mac while it plays, the way meeting
//  note takers such as Granola transcribe as the meeting goes rather than
//  when asked. Two things need the words before the question: the answer,
//  which then knows what was just said without waiting for a minute of
//  sound to be transcribed, and the microphone, whose words are compared
//  with them so the lecturer on the speakers is never taken for the
//  student (TalkOverHearing.lectureWordMask).
//
//  Fed by the same tap as LectureAudioBuffer, so it runs only when that
//  does: the app in front playing sound, the permission given, and not a
//  call, a meeting or a music app. On the Mac only: if this Mac cannot
//  recognise speech on device, nothing is transcribed this way and lecture
//  mode falls back to transcribing the buffer when asked. The words are
//  kept in memory for two minutes and never written anywhere.
//

import AVFoundation
import Foundation
import Speech

@MainActor
final class LectureLiveTranscript {
    /// On-device recognition has no length limit, but one long request
    /// drifts and holds its whole text in memory, so a fresh one is started
    /// about once a minute.
    static let secondsPerRequest: Double = 55

    private(set) var log = LectureHeardWordLog()
    private let feed = LectureRecognitionFeed()
    private var recognizer: SFSpeechRecognizer?
    private var tasksByIdentifier: [Int: SFSpeechRecognitionTask] = [:]
    private var currentIdentifier = 0
    private var rotationTimer: Timer?
    private var loggedUnavailableReason: String?

    var isRunning: Bool { rotationTimer != nil }

    /// Called from the tap's audio thread with 16 kHz mono samples.
    nonisolated func append(_ samples: [Int16]) {
        feed.append(samples)
    }

    func start() {
        guard !isRunning else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            logOnce("speech recognition is not allowed, so the sound is transcribed only when asked")
            return
        }
        let candidate = recognizer ?? SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        // Only on the Mac: a lecture's sound is never sent to Apple's
        // servers just because it played.
        guard let candidate, candidate.isAvailable, candidate.supportsOnDeviceRecognition else {
            logOnce("this Mac cannot recognise speech on device, so the sound is transcribed only when asked")
            return
        }
        recognizer = candidate
        startRequest()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: Self.secondsPerRequest, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startRequest() }
        }
        TutorDebugLog.write("🎓 lecture: transcribing the sound on the Mac as it plays")
    }

    /// Paused, or another app in front: the words heard so far are kept.
    func stop() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        feed.replace(with: nil)?.endAudio()
    }

    /// The app in front changed: its words are not this app's.
    func forgetEverything() {
        stop()
        for task in tasksByIdentifier.values { task.cancel() }
        tasksByIdentifier.removeAll()
        log.removeAll()
    }

    func forgetOldWords() {
        log.forget(before: TalkOverListener.now - LectureHeardWordLog.keptSeconds)
    }

    private func startRequest() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        currentIdentifier += 1
        let identifier = currentIdentifier
        tasksByIdentifier[identifier] = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isDone = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text { self.log.update(request: identifier, text: text, at: TalkOverListener.now) }
                if isDone { self.tasksByIdentifier[identifier] = nil }
            }
        }
        // The new request takes the sound before the old one is ended, so
        // nothing falls between them.
        feed.replace(with: request)?.endAudio()
        forgetOldWords()
    }

    private func logOnce(_ reason: String) {
        guard reason != loggedUnavailableReason else { return }
        loggedUnavailableReason = reason
        TutorDebugLog.write("🎓 lecture: \(reason)")
    }
}

/// The request the tap's thread appends to, swapped from the main thread.
nonisolated final class LectureRecognitionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(LectureAudioBuffer.sampleRate),
                                       channels: 1, interleaved: false)

    /// Puts `newRequest` in place and returns the one it replaced.
    func replace(with newRequest: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock(); defer { lock.unlock() }
        let old = request
        request = newRequest
        return old
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices { channel[index] = Float(samples[index]) / Float(Int16.max) }
        lock.lock(); defer { lock.unlock() }
        request?.append(buffer)
    }
}
