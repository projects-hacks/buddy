//
//  TeachBackListener.swift
//  leanring-buddy
//
//  Listens while the student explains a topic to Buddy, hands free. An
//  explanation takes a minute or two, and holding two keys that long is
//  hostile, so the microphone stays open from the moment the board says
//  "Listening" until the student is done: they say "i'm done" or "that's
//  it" as a sentence of its own, press Return or the bar's I'm done, or go
//  quiet for eight seconds. Esc or Cancel throws it away. Three minutes is
//  the most it will take.
//
//  The microphone is opened the way TalkOverListener opens it: a fresh
//  AVAudioEngine every time, with the tap rebuilt from the hardware's
//  current format whenever it changes (AirPods connecting, another app
//  taking the microphone). A tap installed with a stale format throws an
//  Objective-C exception that hangs the app.
//
//  Unlike talking over an answer, a Bluetooth headset is fine here: nothing
//  is playing while the student talks, and they chose to talk.
//
//  The words go to Deepgram Nova-3 when a key is set, told the topic and the
//  ideas memory has near it, with Apple Speech hearing the same audio as a
//  backup (PreferredTranscriptionProvider); Apple Speech alone otherwise.
//  Deepgram's session records what it heard in the spending meter as it
//  closes, about $0.009 a minute.
//

import AVFoundation
import Foundation

@MainActor
final class TeachBackListener {
    enum Ending: Equatable {
        /// The student said they were done, pressed Return or I'm done.
        case finished
        /// Eight seconds with no new words.
        case silence
        /// Three minutes, the most one explanation may take.
        case timeLimit
        /// Nothing at all was heard after the first wait.
        case nothingHeard
        /// The recognizer or the microphone stopped; what was heard is kept.
        case failed(String)
    }

    /// Eight seconds of quiet ends an explanation: long enough to think in
    /// the middle of one, short enough that a finished student is not left
    /// waiting.
    static let silenceSecondsBeforeEnding: TimeInterval = 8
    /// Before the first word a student often needs longer to start.
    static let silenceSecondsBeforeFirstWord: TimeInterval = 15
    static let longestExplanationSeconds: TimeInterval = 180
    /// After a closing phrase is heard, a short wait in case the student
    /// carries on ("that's it. no wait, the replicas...").
    static let closingPhraseGraceSeconds: TimeInterval = 1.2

    /// The words so far, several times a second, for the notch.
    var onWordsHeard: (String) -> Void = { _ in }
    /// The microphone's level, 0 to 1, for the bar's meter.
    var onLevel: (Double) -> Void = { _ in }
    /// Once, with the explanation as heard (closing words taken off).
    var onEnded: (_ explanation: String, _ ending: Ending) -> Void = { _, _ in }

    private(set) var isListening = false
    private var audioEngine: AVAudioEngine?
    private var configurationChangeObserver: NSObjectProtocol?
    private var transcriptionSession: (any BuddyStreamingTranscriptionSession)?
    private let transcriptionProvider = PreferredTranscriptionProvider()
    private var sessionGeneration = 0
    private var startedAt = Date()
    private var lastNewWordsAt: Date?
    private var latestHeardText = ""
    private var silenceWatcher: Task<Void, Never>?
    private var closingPhraseCheck: Task<Void, Never>?
    private var finalTranscriptWait: Task<Void, Never>?
    private var hasEnded = false
    private var lastLevelSentAt = Date.distantPast

    /// Opens the microphone. `keyterms` are the words Deepgram should
    /// expect: the topic and the ideas memory holds near it.
    func start(keyterms: [String]) {
        guard !isListening else { return }
        sessionGeneration += 1
        let generation = sessionGeneration
        hasEnded = false
        latestHeardText = ""
        lastNewWordsAt = nil
        startedAt = Date()
        isListening = true
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            end(.failed("no microphone permission"))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await self.transcriptionProvider.startStreamingSession(
                    keyterms: keyterms,
                    onTranscriptUpdate: { [weak self] text in
                        Task { @MainActor in
                            guard let self, self.sessionGeneration == generation else { return }
                            self.heard(text)
                        }
                    },
                    onFinalTranscriptReady: { [weak self] text in
                        Task { @MainActor in
                            guard let self, self.sessionGeneration == generation else { return }
                            self.finalTranscriptArrived(text)
                        }
                    },
                    onError: { [weak self] error in
                        Task { @MainActor in
                            guard let self, self.sessionGeneration == generation else { return }
                            TutorDebugLog.write("🎓 teach-back: recognizer stopped (\(error.localizedDescription))")
                            self.end(.failed(error.localizedDescription))
                        }
                    })
                guard self.sessionGeneration == generation, self.isListening else { session.cancel(); return }
                self.transcriptionSession = session
                try self.startMicrophone(generation: generation)
                TutorDebugLog.write("🎓 teach-back: listening, expecting \(keyterms.prefix(8).joined(separator: ", "))")
                self.watchForSilence(generation: generation)
            } catch {
                TutorDebugLog.write("🎓 teach-back: could not listen (\(error.localizedDescription))")
                self.end(.failed(error.localizedDescription))
            }
        }
    }

    /// Return, I'm done, or the talk keys: the explanation is finished.
    /// The recognizer is asked for its last words first, so the sentence
    /// being said is not cut off.
    func finish() {
        guard isListening, !hasEnded else { return }
        askForFinalWords(ending: .finished)
    }

    /// Esc or Cancel: nothing heard is kept.
    func cancel() {
        guard isListening else { return }
        TutorDebugLog.write("🎓 teach-back: cancelled after \(Int(Date().timeIntervalSince(startedAt)))s")
        hasEnded = true
        sessionGeneration += 1
        tearDown()
    }

    // MARK: - Hearing

    private func heard(_ fullText: String) {
        // Words still arriving after the end was asked for are the last of
        // the sentence being said, and are kept.
        guard isListening else { return }
        if fullText != latestHeardText {
            // Only words count as speech: a fan or a room's hum moves the
            // meter but never keeps the microphone open.
            if TalkOverHearing.words(of: fullText) != TalkOverHearing.words(of: latestHeardText) { lastNewWordsAt = Date() }
            latestHeardText = fullText
            onWordsHeard(fullText)
        }
        guard !hasEnded else { return }
        closingPhraseCheck?.cancel()
        guard TeachBackHearing.explanationIfFinished(fullText) != nil else { return }
        let generation = sessionGeneration
        closingPhraseCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.closingPhraseGraceSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.sessionGeneration == generation, !self.hasEnded,
                  TeachBackHearing.explanationIfFinished(self.latestHeardText) != nil else { return }
            TutorDebugLog.write("🎓 teach-back: the student said they were done")
            self.askForFinalWords(ending: .finished)
        }
    }

    /// Checks twice a second for the quiet that ends an explanation, and
    /// for the time limit.
    private func watchForSilence(generation: Int) {
        silenceWatcher?.cancel()
        silenceWatcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.sessionGeneration == generation, !self.hasEnded else { return }
                let now = Date()
                if now.timeIntervalSince(self.startedAt) >= Self.longestExplanationSeconds {
                    TutorDebugLog.write("🎓 teach-back: three minutes, ending")
                    self.askForFinalWords(ending: .timeLimit)
                    return
                }
                if let lastNewWordsAt = self.lastNewWordsAt {
                    if now.timeIntervalSince(lastNewWordsAt) >= Self.silenceSecondsBeforeEnding {
                        TutorDebugLog.write("🎓 teach-back: eight seconds of quiet, ending")
                        self.askForFinalWords(ending: .silence)
                        return
                    }
                } else if now.timeIntervalSince(self.startedAt) >= Self.silenceSecondsBeforeFirstWord {
                    TutorDebugLog.write("🎓 teach-back: nothing heard")
                    self.end(.nothingHeard)
                    return
                }
            }
        }
    }

    private var pendingEnding: Ending = .finished

    /// Stops sending audio and waits, at most the recognizer's own grace,
    /// for its final words; the live words stand in if they do not come.
    private func askForFinalWords(ending: Ending) {
        guard !hasEnded else { return }
        hasEnded = true
        pendingEnding = ending
        silenceWatcher?.cancel()
        closingPhraseCheck?.cancel()
        stopMicrophone()
        guard let transcriptionSession else {
            deliver(latestHeardText, ending: ending)
            return
        }
        transcriptionSession.requestFinalTranscript()
        let generation = sessionGeneration
        let waitSeconds = transcriptionSession.finalTranscriptFallbackDelaySeconds
        finalTranscriptWait = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.sessionGeneration == generation else { return }
            TutorDebugLog.write("🎓 teach-back: no final words in \(waitSeconds)s, using the live ones")
            self.deliver(self.latestHeardText, ending: ending)
        }
    }

    private func finalTranscriptArrived(_ text: String) {
        // The final text can be shorter than the live one when a recognizer
        // dropped its last interim words; the longer is what was said.
        let best = text.count >= latestHeardText.count ? text : latestHeardText
        if hasEnded {
            deliver(best, ending: pendingEnding)
        } else {
            // A recognizer that finished by itself (Apple Speech's limit).
            latestHeardText = best
            hasEnded = true
            stopMicrophone()
            deliver(best, ending: .failed("the recognizer finished early"))
        }
    }

    private func end(_ ending: Ending) {
        if case .failed = ending, !latestHeardText.isEmpty {
            // What was heard before the recognizer stopped is still the
            // student's explanation.
            hasEnded = true
            deliver(latestHeardText, ending: ending)
            return
        }
        hasEnded = true
        deliver(latestHeardText, ending: ending)
    }

    private func deliver(_ text: String, ending: Ending) {
        guard isListening else { return }
        sessionGeneration += 1
        let explanation = TeachBackHearing.explanationIfFinished(text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        TutorDebugLog.write("🎓 teach-back: heard \(TalkOverHearing.words(of: explanation).count) words in \(Int(Date().timeIntervalSince(startedAt)))s, ended by \(ending)")
        tearDown()
        onEnded(explanation, ending)
    }

    private func tearDown() {
        silenceWatcher?.cancel()
        silenceWatcher = nil
        closingPhraseCheck?.cancel()
        closingPhraseCheck = nil
        finalTranscriptWait?.cancel()
        finalTranscriptWait = nil
        stopMicrophone()
        // Cancelling closes Deepgram's socket and records the audio sent in
        // the spending meter, once.
        transcriptionSession?.cancel()
        transcriptionSession = nil
        isListening = false
    }

    // MARK: - Microphone

    private func startMicrophone(generation: Int) throws {
        let engine = AVAudioEngine()
        audioEngine = engine
        try installTapAndStart(on: engine)
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation, self.audioEngine === engine else { return }
                TutorDebugLog.write("🎓 teach-back: microphone format changed; listening again with the new one")
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                do { try self.installTapAndStart(on: engine) } catch { self.end(.failed("the microphone went away")) }
            }
        }
    }

    private func installTapAndStart(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        // Read now, never cached: a format from before a device change is
        // what makes installTap throw.
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "TeachBack", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone is available"])
        }
        inputNode.removeTap(onBus: 0)
        let session = transcriptionSession
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            session?.appendAudioBuffer(buffer)
            let level = Self.level(of: buffer)
            DispatchQueue.main.async { self?.reportLevel(level) }
        }
        engine.prepare()
        try engine.start()
    }

    private func stopMicrophone() {
        if let configurationChangeObserver { NotificationCenter.default.removeObserver(configurationChangeObserver) }
        configurationChangeObserver = nil
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        onLevel(0)
    }

    /// Loudness as 0 to 1, from -60 dBFS (a quiet room) to -15 (close speech).
    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for index in 0..<Int(buffer.frameLength) { sumOfSquares += samples[index] * samples[index] }
        let rootMeanSquare = sqrt(sumOfSquares / Float(buffer.frameLength))
        let decibels = rootMeanSquare > 0 ? 20 * log10(Double(rootMeanSquare)) : -120
        return min(1, max(0, (decibels + 60) / 45))
    }

    /// About twelve times a second is smooth for a meter and cheap for the page.
    private func reportLevel(_ level: Double) {
        guard isListening, !hasEnded else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLevelSentAt) >= 0.08 else { return }
        lastLevelSentAt = now
        onLevel(level)
    }
}
