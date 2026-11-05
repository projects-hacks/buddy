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

/// What something heard while an answer played means. Pure, so it can be
/// checked without a microphone.
enum TalkOverHearing {
    enum Meaning: Equatable {
        case ignore(reason: String)
        case hold
        case resume
        case slower
        case repeatPreviousSentence
        case replayAnswer
        case question(String)
    }

    /// A word counts as Buddy's own when its share of matching words is at
    /// least this. A clean echo comes back almost word for word (0.8 and
    /// up); a student's own question shares a topic noun or two with the
    /// sentence, and its question words never, so it stays well below.
    static let echoShareThreshold = 0.6
    /// A real question has at least this many words, unless it is two
    /// words opened by a cue, like "wait, why?".
    static let minimumQuestionWords = 3
    /// Past this it is a conversation or a video, not a question cutting in.
    static let maximumQuestionWords = 40

    private static let fillerWords: Set<String> = ["um", "uh", "er", "erm", "hmm", "mm", "mhm", "ah", "oh", "like"]
    /// Words that carry no topic, left out when comparing with what Buddy said.
    private static let commonWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "it", "its", "this", "that", "these", "those",
        "to", "of", "in", "on", "at", "for", "and", "or", "so", "you", "i", "we", "they", "he", "she",
        "do", "does", "did", "has", "have", "had", "with", "as", "by", "from", "if", "then", "there", "here",
        "can", "will", "just", "not", "no", "yes", "one", "all", "what"
    ]
    private static let cueOpenings = ["wait", "hold on", "hang on", "sorry", "but", "actually", "excuse me", "hey", "so"]
    private static let questionWords: Set<String> = [
        "why", "what", "how", "when", "where", "which", "who", "whats", "hows", "huh", "really",
        "is", "does", "do", "can", "could", "should", "would", "are", "isnt", "doesnt", "explain"
    ]

    private static let holdPhrases: Set<String> = ["wait", "hold on", "hang on", "one sec", "one second", "pause", "wait a second", "wait a sec", "hold on a second", "just a second", "wait wait"]
    private static let resumePhrases: Set<String> = ["go on", "continue", "keep going", "carry on", "go ahead", "resume", "ok go on", "okay go on", "ok continue", "okay continue", "yes go on", "yeah go on", "go on please", "please continue"]
    private static let slowerPhrases: Set<String> = ["slower", "slow down", "more slowly", "a bit slower", "a little slower", "slower please", "slow down please", "can you slow down", "could you slow down", "talk slower", "speak slower"]
    private static let replayPhrases: Set<String> = ["say that again", "say it again", "can you say that again", "could you say that again", "say all that again", "repeat the answer", "repeat your answer", "repeat the whole thing", "one more time", "from the top", "start again", "play that again"]
    private static let repeatPhrases: Set<String> = ["go back", "go back one", "back", "repeat that", "repeat", "repeat that sentence", "say that sentence again", "what was that", "come again"]

    /// The whole of something heard, once its speaker paused.
    static func meaning(ofUtterance utterance: String, recentlySpoken: [String], wasLoudEnough: Bool) -> Meaning {
        let words = Self.words(of: utterance)
        guard !words.isEmpty else { return .ignore(reason: "nothing") }
        guard wasLoudEnough else { return .ignore(reason: "too quiet to be the student at the Mac") }

        let phrase = commandPhrase(from: words)
        if holdPhrases.contains(phrase) { return .hold }
        if resumePhrases.contains(phrase) { return .resume }
        if slowerPhrases.contains(phrase) { return .slower }
        if repeatPhrases.contains(phrase) { return .repeatPreviousSentence }
        if replayPhrases.contains(phrase) { return .replayAnswer }

        let realWords = words.filter { !fillerWords.contains($0) }
        if echoShare(of: realWords, recentlySpoken: recentlySpoken) >= echoShareThreshold {
            return .ignore(reason: "Buddy's own voice")
        }
        guard realWords.count <= maximumQuestionWords else { return .ignore(reason: "too long to be cutting in") }
        let opensWithCue = opensWithCue(realWords)
        let asksSomething = utterance.contains("?") || realWords.prefix(3).contains { questionWords.contains($0) }
        if realWords.count >= minimumQuestionWords, opensWithCue || asksSomething {
            return .question(utterance.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if realWords.count == 2, opensWithCue, questionWords.contains(realWords[1]) {
            return .question(utterance.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .ignore(reason: "not addressed to Buddy")
    }

    /// Whether a question asked the usual way is only asking to hear the
    /// last answer again, which is replayed rather than answered.
    static func isReplayRequest(_ question: String) -> Bool {
        replayPhrases.contains(commandPhrase(from: words(of: question)))
    }

    /// While the student is still speaking: whether to stop talking at once,
    /// before the whole of it is in. Only for what already reads as cutting
    /// in, so a voice in the room does not make Buddy stutter.
    static func shouldYield(toPartial partial: String, recentlySpoken: [String], wasLoudEnough: Bool) -> Bool {
        guard wasLoudEnough else { return false }
        let realWords = words(of: partial).filter { !fillerWords.contains($0) }
        guard realWords.count >= 2, realWords.count <= maximumQuestionWords,
              echoShare(of: realWords, recentlySpoken: recentlySpoken) < echoShareThreshold else { return false }
        if opensWithCue(realWords) { return true }
        return realWords.count >= 4 && realWords.prefix(3).contains { questionWords.contains($0) }
    }

    /// The share of the heard topic words that are also in what Buddy just
    /// said. Common words are left out: "is", "the", "it" are in every
    /// sentence and would make any question look like an echo.
    static func echoShare(of heardWords: [String], recentlySpoken: [String]) -> Double {
        let spokenWords = recentlySpoken.flatMap(words(of:))
        guard !spokenWords.isEmpty else { return 0 }
        var comparedWords = heardWords.filter { !commonWords.contains($0) }
        if comparedWords.count < 2 { comparedWords = heardWords }
        guard !comparedWords.isEmpty else { return 0 }
        let matching = comparedWords.filter { heard in spokenWords.contains { spoken in sameWord(heard, spoken) } }
        return Double(matching.count) / Double(comparedWords.count)
    }

    /// The same word, allowing for the recognizer's endings ("caches" for
    /// "cache", "returned" for "returns").
    private static func sameWord(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        guard first.count >= 5, second.count >= 5 else { return false }
        return first.prefix(5) == second.prefix(5)
    }

    private static func opensWithCue(_ realWords: [String]) -> Bool {
        let opening = realWords.prefix(2).joined(separator: " ")
        return cueOpenings.contains { cue in opening == cue || opening.hasPrefix(cue + " ") }
    }

    /// The words with "okay", "buddy" and "please" around a command taken
    /// off, so "okay buddy, go on please" is "go on".
    private static func commandPhrase(from words: [String]) -> String {
        var trimmed = words.filter { !fillerWords.contains($0) }
        while let first = trimmed.first, ["okay", "ok", "buddy", "hey", "alright", "right"].contains(first) { trimmed.removeFirst() }
        while let last = trimmed.last, ["please", "buddy", "thanks"].contains(last), trimmed.count > 1 { trimmed.removeLast() }
        return trimmed.joined(separator: " ")
    }

    static func words(of text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

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
    /// How long nothing new is heard before what was said counts as finished.
    static let utteranceEndSilenceSeconds: TimeInterval = 0.6

    var onRequest: (Request) -> Void = { _ in }
    /// The sentence being said and the two before it, for the echo guard.
    var recentlySpokenSentences: () -> [String] = { [] }

    private(set) var isListening = false
    private var audioEngine: AVAudioEngine?
    private var configurationChangeObserver: NSObjectProtocol?
    private var transcriptionSession: (any BuddyStreamingTranscriptionSession)?
    private let transcriptionProvider = PreferredTranscriptionProvider()
    private var startTask: Task<Void, Never>?
    private var sessionGeneration = 0

    private var heardWordsSoFar: [String] = []
    private var latestHeardText = ""
    private var consumedWordCount = 0
    private var utteranceEndCheck: Task<Void, Never>?
    private var isYielding = false
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
        utteranceEndCheck?.cancel()
        utteranceEndCheck = nil
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
        isYielding = false
        heardWordsSoFar = []
        latestHeardText = ""
        consumedWordCount = 0
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

    private func heard(_ fullText: String) {
        latestHeardText = fullText
        heardWordsSoFar = TalkOverHearing.words(of: fullText)
        // A recognizer revising its words can make the text shorter.
        if consumedWordCount > heardWordsSoFar.count { consumedWordCount = heardWordsSoFar.count }
        let newText = newWordsText()
        guard !newText.isEmpty else { return }

        if !isYielding, TalkOverHearing.shouldYield(toPartial: newText, recentlySpoken: recentlySpokenSentences(),
                                                    wasLoudEnough: wasLoudEnoughRecently) {
            isYielding = true
            TutorDebugLog.write("👂 talk-over: the student is cutting in, pausing")
            onRequest(.yield)
        }

        utteranceEndCheck?.cancel()
        utteranceEndCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.utteranceEndSilenceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.utteranceEnded()
        }
    }

    /// The words heard since the last finished utterance, with the
    /// recognizer's own punctuation kept where it can be, since a question
    /// mark is part of what is read.
    private func newWordsText() -> String {
        guard consumedWordCount < heardWordsSoFar.count else { return "" }
        let newWords = heardWordsSoFar[consumedWordCount...]
        let rawTokens = latestHeardText.split(whereSeparator: { $0.isWhitespace })
        // Words and tokens line up one to one except around punctuation the
        // word list drops; when they do, the raw text is used.
        if rawTokens.count == heardWordsSoFar.count {
            return rawTokens[consumedWordCount...].joined(separator: " ")
        }
        return newWords.joined(separator: " ")
    }

    private func utteranceEnded() {
        let utterance = newWordsText()
        consumedWordCount = heardWordsSoFar.count
        guard !utterance.isEmpty else { return }
        let meaning = TalkOverHearing.meaning(ofUtterance: utterance, recentlySpoken: recentlySpokenSentences(),
                                              wasLoudEnough: wasLoudEnoughRecently)
        let wasYielding = isYielding
        isYielding = false
        switch meaning {
        case .ignore(let reason):
            TutorDebugLog.write("👂 talk-over: ignored \(TalkOverHearing.words(of: utterance).count) words (\(reason))")
            if wasYielding { onRequest(.endYield) }
        case .hold:
            TutorDebugLog.write("👂 talk-over: hold on")
            onRequest(.hold)
        case .resume:
            TutorDebugLog.write("👂 talk-over: go on")
            onRequest(.resume)
        case .slower:
            TutorDebugLog.write("👂 talk-over: slower")
            if wasYielding { onRequest(.endYield) }
            onRequest(.slower)
        case .repeatPreviousSentence:
            TutorDebugLog.write("👂 talk-over: go back")
            if wasYielding { onRequest(.endYield) }
            onRequest(.repeatPreviousSentence)
        case .replayAnswer:
            TutorDebugLog.write("👂 talk-over: say that again")
            onRequest(.replayAnswer)
        case .question(let question):
            TutorDebugLog.write("👂 talk-over: a question cut in")
            onRequest(.question(question))
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
