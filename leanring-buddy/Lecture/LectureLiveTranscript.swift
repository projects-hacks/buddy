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
//  kept per app, in memory only, while Buddy runs, and never written
//  anywhere: a glance at another app and back loses nothing.
//

import AppKit
import AVFoundation
import Foundation
import Speech

@MainActor
final class LectureLiveTranscript {
    // One request runs for as long as the sound does. On-device recognition
    // has no length limit, and its text starts over after each pause, so a
    // request never holds a whole lecture. A new one is started only once
    // the last has ended by itself: Apple's recognizer serves one task at a
    // time, and starting the next before the last had finished, once a
    // minute as 2.0.2's first build did, lost the speech on either side.

    /// Each app's words, by its process.
    private var logs: [pid_t: LectureHeardWordLog] = [:]
    /// The app whose sound is being recognised now.
    private var owner: pid_t?
    private let feed = LectureRecognitionFeed()
    private var recognizer: SFSpeechRecognizer?
    private var tasksByIdentifier: [Int: SFSpeechRecognitionTask] = [:]
    private var currentIdentifier = 0
    private(set) var isRunning = false
    private var loggedUnavailableReason: String?


    /// Called from the tap's audio thread with 16 kHz mono samples.
    nonisolated func append(_ samples: [Int16]) {
        feed.append(samples)
    }

    func log(for processIdentifier: pid_t) -> LectureHeardWordLog {
        logs[processIdentifier] ?? LectureHeardWordLog()
    }

    /// The words of the app being heard now, for the microphone's filter.
    var currentLog: LectureHeardWordLog { owner.map(log(for:)) ?? LectureHeardWordLog() }

    func noteAnchor(playbackSeconds: Double, videoKey: String, for processIdentifier: pid_t,
                    at time: Double? = nil) {
        logs[processIdentifier, default: LectureHeardWordLog()]
            .noteAnchor(playbackSeconds: playbackSeconds, videoKey: videoKey, at: time ?? TalkOverListener.now)
    }

    func start(for processIdentifier: pid_t) {
        if owner != processIdentifier { stop() }
        owner = processIdentifier
        // Apps that quit take their words with them.
        for gone in logs.keys where NSRunningApplication(processIdentifier: gone) == nil { logs[gone] = nil }
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
        isRunning = true
        startRequest()
        TutorDebugLog.write("🎓 lecture: transcribing the sound on the Mac as it plays")
    }

    /// Paused, or another app in front: the words heard so far are kept.
    func stop() {
        isRunning = false
        feed.replace(with: nil)?.endAudio()
    }

    private func startRequest() {
        guard let recognizer, let owner else { return }
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
            let errorText = error.map { ($0 as NSError).domain + " \(($0 as NSError).code): " + $0.localizedDescription }
            Task { @MainActor in
                guard let self else { return }
                if let text { self.logs[owner, default: LectureHeardWordLog()].update(request: identifier, text: text, at: TalkOverListener.now) }
                guard isDone else { return }
                self.tasksByIdentifier[identifier] = nil
                let wordCount = text?.split(separator: " ").count ?? 0
                TutorDebugLog.write("🎓 lecture: recognizer request \(identifier) ended, \(errorText.map { "with \($0)" } ?? "final"), its last text \(wordCount) words")
                // The recognizer gives up on a request after a quiet stretch
                // ("no speech detected"); sound fed to it after that is lost.
                // In the 2.0.2 test that lost the first 35 s of a lecture,
                // until the next minute's restart. The current request, once
                // ended, is replaced at once.
                guard identifier == self.currentIdentifier, self.isRunning else { return }
                if let errorText { TutorDebugLog.write("🎓 lecture: the Mac's recognizer ended a request (\(errorText)), starting another") }
                self.restartAfterEnd()
            }
        }
        feed.replace(with: request)?.endAudio()
    }

    /// A new request a moment after one ended, so a recognizer that keeps
    /// ending at once (silence) is not restarted in a tight loop.
    private func restartAfterEnd() {
        let endedIdentifier = currentIdentifier
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.isRunning, self.currentIdentifier == endedIdentifier else { return }
            self.startRequest()
        }
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
