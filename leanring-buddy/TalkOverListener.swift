//
//  TalkOverListener.swift
//  leanring-buddy
//
//  Talking over an answer without pressing anything. While an answer plays,
//  the microphone stays open and what is heard is read for four things:
//  a real question ("wait, why?") stops Buddy and is answered with the cut
//  off answer as context; "hold on" or "wait" alone pauses and "go on"
//  resumes; "slower" slows the rest; "go back" says the last sentence again.
//  Pressing the talk keys still works exactly as before, and closes this.
//
//  Buddy must not hear itself. macOS's echo canceller (voice processing on
//  an AVAudioEngine's input) removes what that same engine's output plays,
//  and the narration plays through its own engine (NarrationVoice), so it
//  is not cancelled; switching voice processing on also reconfigures the
//  audio device and ducks other audio, which can stop the narration's
//  engine mid-sentence. It is left off unless the `talkOverUsesVoiceProcessing`
//  default is set, for trying it on a given Mac. What protects the answer
//  is the software guard below: heard words that match the sentence being
//  said, or the two before it, are Buddy's own voice coming back.
//
//  With speakers, Buddy's own voice comes back into the same transcript as
//  the student's, word by word, interleaved. So heard words are not judged
//  in chunks cut at pauses: the last few seconds of words are kept, the runs
//  that follow Buddy's own sentences word for word are taken out, and what
//  is left is the student. A cue ("wait", "hold on", "but why") among the
//  student's words stops Buddy at once; the student's words are judged as
//  one utterance when the student, not Buddy, has paused; and the question
//  sent is all of them, Buddy's words removed (TalkOverTranscript).
//
//  Other people, a video and background noise must not stop Buddy, so a
//  question has to be loud enough to be the student at the Mac, addressed
//  to Buddy (a question, or opened with "wait", "but", "sorry"...), short,
//  and not an echo. Commands must be the whole of what was heard.
//
//  Costs: with a Deepgram key the audio goes to Nova-3 while the answer
//  plays, about $0.009 a minute, counted in the meter as every question is;
//  without one, Apple Speech on the Mac only. Off in Settings.
//

import AVFoundation
import CoreAudio
import Foundation

/// Listens while an answer plays and reports what the student asked for.
@MainActor
final class TalkOverListener {
    enum Request: Equatable {
        /// The student started cutting in: stop talking while they finish.
        case yield
        /// What made Buddy yield turned out not to be for it.
        case endYield
        case hold
        case resume
        case slower
        case repeatPreviousSentence
        case replayAnswer
        case question(String)
    }

    static let enabledDefaultsKey = "talkOverEnabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true }
    private static let usesVoiceProcessingDefaultsKey = "talkOverUsesVoiceProcessing"

    /// The loudest 20 ms of what was heard must reach this. Speech from
    /// someone at a laptop reaches about -30 to -20 dBFS on its microphone;
    /// a quiet room sits near -60 and a television across it near -45, so
    /// this is about fifteen decibels above the room and below a person
    /// talking to the Mac. To be checked on real microphones.
    static let loudEnoughDecibels: Float = -40

    var onRequest: (Request) -> Void = { _ in }
    /// The sentence being said and the two before it, for the echo guard.
    var recentlySpokenSentences: () -> [SpokenSentence] = { [] }
    /// Told when the microphone opens and closes, for the notch's mic glyph:
    /// the student should always be able to see that Buddy can hear them.
    var onListeningChanged: (Bool) -> Void = { _ in }
    /// The words of a student cutting in, live, for the notch's second line.
    var onWordsHeardWhileCuttingIn: (String) -> Void = { _ in }

    private(set) var isListening = false {
        didSet { if isListening != oldValue { onListeningChanged(isListening) } }
    }
    private var audioEngine: AVAudioEngine?
    private var configurationChangeObserver: NSObjectProtocol?
    private var transcriptionSession: (any BuddyStreamingTranscriptionSession)?
    private let transcriptionProvider = PreferredTranscriptionProvider()
    private var startTask: Task<Void, Never>?
    private var sessionGeneration = 0

    private var transcript = TalkOverTranscript()
    /// Asks the transcript a few times a second whether the student paused.
    private var pauseClock: Task<Void, Never>?
    /// Loudness of recent buffers, newest last, for the loudness gate.
    private var recentLevels: [(at: Date, decibels: Float)] = []

    /// Opens the microphone for the answer that started playing. Does
    /// nothing when switched off, without microphone permission, or when
    /// the input is a Bluetooth headset, whose microphone would switch it to
    /// call quality for the whole answer.
    func start() {
        guard Self.isEnabled, !isListening, startTask == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        if Self.defaultInputIsBluetooth() {
            TutorDebugLog.write("👂 talk-over: not listening, the microphone is a Bluetooth headset")
            return
        }
        sessionGeneration += 1
        let generation = sessionGeneration
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.sessionGeneration == generation { self.startTask = nil } }
            do {
                let session = try await self.transcriptionProvider.startStreamingSession(
                    keyterms: [],
                    onTranscriptUpdate: { [weak self] text in
                        Task { @MainActor in
                            guard let self, self.sessionGeneration == generation else { return }
                            self.heard(text)
                        }
                    },
                    onFinalTranscriptReady: { _ in },
                    onError: { [weak self] error in
                        Task { @MainActor in
                            guard let self, self.sessionGeneration == generation else { return }
                            TutorDebugLog.write("👂 talk-over: recognizer stopped (\(error.localizedDescription))")
                            self.stop()
                        }
                    })
                guard self.sessionGeneration == generation, !Task.isCancelled else { session.cancel(); return }
                self.transcriptionSession = session
                try self.startMicrophone(generation: generation)
                self.isListening = true
                self.startPauseClock(generation: generation)
                TutorDebugLog.write("👂 talk-over: listening while the answer plays")
            } catch {
                TutorDebugLog.write("👂 talk-over: could not listen (\(error.localizedDescription))")
                self.tearDown()
            }
        }
    }

    /// Closes the microphone. The heard audio's cost is counted as the
    /// recognizer session closes.
    func stop() {
        guard isListening || startTask != nil else { return }
        sessionGeneration += 1
        startTask?.cancel()
        startTask = nil
        if isListening { TutorDebugLog.write("👂 talk-over: stopped listening") }
        tearDown()
    }

    private func tearDown() {
        pauseClock?.cancel()
        pauseClock = nil
        if let configurationChangeObserver { NotificationCenter.default.removeObserver(configurationChangeObserver) }
        configurationChangeObserver = nil
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        transcriptionSession?.cancel()
        transcriptionSession = nil
        isListening = false
        transcript = TalkOverTranscript()
        recentLevels = []
    }

    // MARK: - Microphone

    /// A fresh engine for every answer, and the tap rebuilt from the
    /// hardware's current format whenever it changes (AirPods, another app
    /// opening the mic). A tap installed with a stale format throws an
    /// Objective-C exception that hangs the app; see BuddyDictationManager.
    private func startMicrophone(generation: Int) throws {
        let engine = AVAudioEngine()
        if UserDefaults.standard.bool(forKey: Self.usesVoiceProcessingDefaultsKey) {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        audioEngine = engine
        try installTapAndStart(on: engine)
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation, self.audioEngine === engine else { return }
                TutorDebugLog.write("👂 talk-over: microphone format changed; listening again with the new one")
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                do { try self.installTapAndStart(on: engine) } catch { self.stop() }
            }
        }
    }

    private func installTapAndStart(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "TalkOver", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone is available"])
        }
        inputNode.removeTap(onBus: 0)
        let session = transcriptionSession
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            session?.appendAudioBuffer(buffer)
            let decibels = Self.decibels(of: buffer)
            DispatchQueue.main.async { self?.noteLevel(decibels) }
        }
        engine.prepare()
        try engine.start()
    }

    private nonisolated static func decibels(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -120 }
        var sumOfSquares: Float = 0
        for index in 0..<Int(buffer.frameLength) { sumOfSquares += samples[index] * samples[index] }
        let rootMeanSquare = sqrt(sumOfSquares / Float(buffer.frameLength))
        return rootMeanSquare > 0 ? 20 * log10(rootMeanSquare) : -120
    }

    private func noteLevel(_ decibels: Float) {
        transcript.levelHeard(decibels, at: Self.now)
        let now = Date()
        recentLevels.append((now, decibels))
        recentLevels.removeAll { now.timeIntervalSince($0.at) > 6 }
    }

    /// Whether anything in the last few seconds was as loud as a person at
    /// the Mac. Words arrive a little after the sound that carried them,
    /// so the window reaches back further than the utterance.
    private var wasLoudEnoughRecently: Bool {
        recentLevels.contains { $0.decibels >= Self.loudEnoughDecibels }
    }

    // MARK: - Hearing

    /// The clock heard words and Buddy's sentences are both timed on.
    static var now: Double { Date().timeIntervalSinceReferenceDate }

    private func heard(_ fullText: String) {
        let actions = transcript.heard(fullText, at: Self.now, recentlySpoken: recentlySpokenSentences(),
                                       wasLoudEnough: wasLoudEnoughRecently)
        perform(actions)
    }

    private func startPauseClock(generation: Int) {
        pauseClock?.cancel()
        pauseClock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, self.sessionGeneration == generation else { return }
                let actions = self.transcript.timePassed(to: Self.now, recentlySpoken: self.recentlySpokenSentences(),
                                                         wasLoudEnough: self.wasLoudEnoughRecently)
                self.perform(actions)
            }
        }
    }

    private func perform(_ actions: [TalkOverTranscript.Action]) {
        for action in actions {
            switch action {
            case .yield:
                TutorDebugLog.write("👂 talk-over: the student is cutting in, pausing")
                onRequest(.yield)
            case .endYield: onRequest(.endYield)
            case .flushRecognizer:
                transcriptionSession?.flushPendingWords()
            case .ignored(let wordCount, let reason):
                TutorDebugLog.write("👂 talk-over: ignored \(wordCount) words (\(reason))")
            case .hold:
                TutorDebugLog.write("👂 talk-over: hold on")
                onRequest(.hold)
            case .resume:
                TutorDebugLog.write("👂 talk-over: go on")
                onRequest(.resume)
            case .slower:
                TutorDebugLog.write("👂 talk-over: slower")
                onRequest(.slower)
            case .repeatPreviousSentence:
                TutorDebugLog.write("👂 talk-over: go back")
                onRequest(.repeatPreviousSentence)
            case .replayAnswer:
                TutorDebugLog.write("👂 talk-over: say that again")
                onRequest(.replayAnswer)
            case .question(let question):
                TutorDebugLog.write("👂 talk-over: a question cut in")
                onRequest(.question(question))
            }
        }
    }

    // MARK: - Devices

    /// Whether the system's default input is a Bluetooth device.
    private static func defaultInputIsBluetooth() -> Bool {
        var deviceIdentifier = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIdentifier) == noErr,
              deviceIdentifier != 0 else { return false }
        var transportType = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(deviceIdentifier, &address, 0, nil, &size, &transportType) == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}
