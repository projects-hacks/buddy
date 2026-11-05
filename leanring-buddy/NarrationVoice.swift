//
//  NarrationVoice.swift
//  leanring-buddy
//
//  Speaks a drawing program's sentences one after another, and says how long
//  each one lasts, because the pen is paced by it.
//
//  Measured on this account with `aura-2-hera-en`: an eleven-word sentence
//  starts arriving in 0.2s, is fully downloaded in about 2.1s, and takes
//  about 4.3s to say. So the next sentence can be fetched completely while
//  the current one is still playing, and from the second sentence on, each
//  one starts with no gap and with its exact length known. Only the first
//  sentence of an answer is streamed as it arrives, because that is the one
//  the student is waiting in silence for; its length is estimated at first
//  and corrected once its audio has all arrived.
//
//  The student can talk over an answer (TalkOverListener), so the voice can
//  also pause where it is and go on, say the last sentence again, and slow
//  down for the rest of the answer. Slower uses Aura-2's own `speed`
//  parameter (0.7 to 1.5) for sentences not yet fetched, and a time
//  stretch, which keeps the pitch, for audio already downloaded at the
//  normal speed; the pen is paced by the stretched length.
//

import AVFoundation
import Foundation

/// One sentence as it was heard: its audio, kept in memory so the answer
/// can be played again without asking Deepgram a second time.
struct RecordedSentence {
    let text: String
    let audioChunks: [Data]
    let totalFrames: AVAudioFramePosition
    /// Spoken by the system voice the first time, which a replay does again.
    let usedSystemVoice: Bool
}

@MainActor
final class NarrationVoice {
    var onLineStarted: ((Int, TimeInterval) -> Void)?
    var onLineDurationKnown: ((Int, TimeInterval) -> Void)?
    var onLineFinished: ((Int) -> Void)?

    var voiceName = "aura-2-hera-en"
    private(set) var isSpeaking = false

    private static let sampleRate: Double = 24_000
    /// Measured speaking rate of this voice, for the estimate before a
    /// sentence's audio has fully arrived.
    private static let wordsPerSecond = 2.55

    private final class Line {
        let index: Int
        let text: String
        var chunks: [Data] = []
        var totalFrames: AVAudioFramePosition = 0
        var isDownloaded = false
        var downloadFailed = false
        var downloadTask: Task<Void, Never>?
        /// The Aura speed this sentence's audio was made at.
        var downloadedAtSpeed: Double = 1.0
        /// Wakes the player when more audio, or the end, arrives.
        var waitingForAudio: CheckedContinuation<Void, Never>?
        init(index: Int, text: String) { self.index = index; self.text = text }
    }

    private var lines: [Line] = []
    private var nextLineToPlay = 0
    private var playerTask: Task<Void, Never>?
    private var generation = 0

    private let session: URLSession
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Bypassed at normal speed; stretches audio already downloaded at the
    /// normal speed when the student asks for slower.
    private let timeStretch = AVAudioUnitTimePitch()
    private var isEngineRunning = false
    private var engineConfigurationObserver: NSObjectProtocol?

    /// Paused by the student ("hold on"), not stopped: the sentence carries
    /// on from where it was when they say "go on".
    private(set) var isPaused = false
    private var waitersForResume: [CheckedContinuation<Void, Never>] = []
    /// Each "slower" moves one step down, to Aura's floor of 0.7.
    private static let slowerSpeeds: [Double] = [1.0, 0.85, 0.72]
    private var slowerStep = 0
    private var speakingSpeed: Double { Self.slowerSpeeds[slowerStep] }
    /// Set if Deepgram ever refuses the speed parameter, so slower falls
    /// back to stretching every sentence instead of losing the voice.
    private var speedParameterRefused = false
    /// "Go back": the sentence to start again from once the current one is cut.
    private var sentenceToRepeatFrom: Int?
    private var currentLineIsBeingCut = false
    /// Which play the scheduled buffers belong to, so a buffer finishing
    /// late after a cut never counts toward the next sentence.
    private var playToken = 0
    /// The sentence being played, for the echo guard and "go back".
    private(set) var currentLineIndex: Int?
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!

    private var framesScheduledForCurrentLine: AVAudioFramePosition = 0
    private var framesPlayedForCurrentLine: AVAudioFramePosition = 0
    private var currentLineDrained: CheckedContinuation<Void, Never>?

    /// Spoken through instead when Deepgram has no key or fails.
    private let fallbackVoice: LocalSpeechSynthesisClient
    private var deepgramUnavailable = false

    init(fallbackVoice: LocalSpeechSynthesisClient) {
        self.fallbackVoice = fallbackVoice
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
        audioEngine.attach(playerNode)
        audioEngine.attach(timeStretch)
        timeStretch.bypass = true
        // A device change (headphones, a microphone opening in call mode)
        // stops the engine. Without noticing, the next sentence would play
        // into a stopped engine, which throws and hangs the app; the cut
        // sentence ends here and the next one starts the engine again.
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                TutorDebugLog.write("🔈 narration: audio device changed, restarting the voice")
                self.isEngineRunning = false
                self.cutCurrentLine()
            }
        }
    }

    /// Opens the connection to Deepgram while the student is still talking.
    func prewarmConnection() {
        guard let url = URL(string: "https://api.deepgram.com/v1/projects") ,
              let apiKey = APIKeyStore.key(for: .deepgram) else { return }
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        session.dataTask(with: request).resume()
    }

    // MARK: - Queue

    /// Adds the next sentence. Its audio starts downloading at once if the
    /// sentence before it has finished downloading.
    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = Line(index: lines.count, text: trimmed)
        lines.append(line)
        if line.index == 0 || lines[line.index - 1].isDownloaded || lines[line.index - 1].downloadFailed {
            startDownload(line)
        }
        if playerTask == nil { startPlayer() }
    }

    /// Plays a sentence from an earlier answer's audio: no request is made.
    func enqueueRecorded(_ sentence: RecordedSentence) {
        let line = Line(index: lines.count, text: sentence.text)
        line.chunks = sentence.audioChunks
        line.totalFrames = sentence.totalFrames
        line.isDownloaded = !sentence.usedSystemVoice
        line.downloadFailed = sentence.usedSystemVoice
        lines.append(line)
        if playerTask == nil { startPlayer() }
    }

    /// The sentences of this answer whose audio is complete, in order, up
    /// to the first that is not: what can be played again exactly as heard.
    /// Empty until a sentence has started, so an answer cut off before a
    /// word of it was heard never replaces the one before it.
    func recordedSentences() -> [RecordedSentence] {
        guard currentLineIndex != nil || nextLineToPlay > 0 else { return [] }
        var recorded: [RecordedSentence] = []
        for line in lines {
            if line.isDownloaded {
                recorded.append(RecordedSentence(text: line.text, audioChunks: line.chunks,
                                                 totalFrames: line.totalFrames, usedSystemVoice: false))
            } else if line.downloadFailed && line.chunks.isEmpty {
                recorded.append(RecordedSentence(text: line.text, audioChunks: [], totalFrames: 0, usedSystemVoice: true))
            } else {
                break
            }
        }
        return recorded
    }

    /// Stops speaking and forgets every sentence.
    func stop() {
        generation += 1
        playerTask?.cancel()
        playerTask = nil
        for line in lines {
            line.downloadTask?.cancel()
            line.waitingForAudio?.resume()
            line.waitingForAudio = nil
        }
        lines.removeAll()
        nextLineToPlay = 0
        if playerNode.isPlaying || isPaused { playerNode.stop() }
        fallbackVoice.stopPlayback()
        currentLineDrained?.resume()
        currentLineDrained = nil
        isSpeaking = false
        isPaused = false
        let waiters = waitersForResume
        waitersForResume = []
        waiters.forEach { $0.resume() }
        slowerStep = 0
        timeStretch.bypass = true
        timeStretch.rate = 1
        sentenceToRepeatFrom = nil
        currentLineIsBeingCut = false
        currentLineIndex = nil
    }

    // MARK: - The student's requests while it speaks

    /// "Hold on": stops where it is, mid-sentence, until resumed.
    func pause() {
        guard isSpeaking, !isPaused else { return }
        isPaused = true
        if playerNode.isPlaying { playerNode.pause() }
        fallbackVoice.pausePlayback()
    }

    /// "Go on": carries on from exactly where it paused.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        if currentLineIndex != nil, audioEngine.isRunning { playerNode.play() }
        fallbackVoice.resumePlayback()
        let waiters = waitersForResume
        waitersForResume = []
        waiters.forEach { $0.resume() }
    }

    /// "Slower": the rest of this answer, the current sentence included.
    func slowDown() {
        guard slowerStep + 1 < Self.slowerSpeeds.count else { return }
        slowerStep += 1
        TutorDebugLog.write("🔈 narration: speaking at \(speakingSpeed)x for the rest of the answer")
        if let currentLineIndex, currentLineIndex < lines.count {
            let line = lines[currentLineIndex]
            applyTimeStretch(for: line)
            if line.isDownloaded { onLineDurationKnown?(line.index, playedSeconds(of: line)) }
        }
    }

    /// "Go back": cuts the current sentence and says the one before it
    /// again, then carries on from the cut one.
    func repeatPreviousSentence() {
        guard isSpeaking, let currentLineIndex else { return }
        // Between two sentences the previous one is the one just finished.
        let currentLineHasFinished = nextLineToPlay > currentLineIndex
        sentenceToRepeatFrom = currentLineHasFinished ? currentLineIndex : max(0, currentLineIndex - 1)
        if isPaused { resume() }
        cutCurrentLine()
    }

    /// Ends the sentence being played now, wherever it is.
    private func cutCurrentLine() {
        guard currentLineIndex != nil else { return }
        currentLineIsBeingCut = true
        playToken += 1
        if playerNode.isPlaying || isPaused { playerNode.stop() }
        fallbackVoice.stopPlayback()
        if let currentLineIndex, currentLineIndex < lines.count { wake(lines[currentLineIndex]) }
        currentLineDrained?.resume()
        currentLineDrained = nil
    }

    private func waitWhilePaused() async {
        while isPaused {
            await withCheckedContinuation { waitersForResume.append($0) }
        }
    }

    /// Stretches a sentence whose audio was made faster than the speed now
    /// asked for; bypassed when the audio already has the right speed.
    private func applyTimeStretch(for line: Line) {
        let rate = Float(speakingSpeed / line.downloadedAtSpeed)
        if abs(rate - 1) < 0.01 {
            timeStretch.bypass = true
            timeStretch.rate = 1
        } else {
            timeStretch.rate = rate
            timeStretch.bypass = false
        }
    }

    /// How long a downloaded sentence takes to play at the current stretch.
    private func playedSeconds(of line: Line) -> TimeInterval {
        let rate = timeStretch.bypass ? 1 : Double(timeStretch.rate)
        return seconds(line.totalFrames) / rate
    }

    // MARK: - Downloading

    private func startDownload(_ line: Line) {
        // A replayed sentence already has its audio, or speaks locally.
        guard line.downloadTask == nil, !line.isDownloaded, !line.downloadFailed else { return }
        guard !deepgramUnavailable, !line.text.isEmpty, let apiKey = APIKeyStore.key(for: .deepgram) else {
            line.downloadFailed = true
            wake(line)
            startNextDownload(after: line)
            return
        }
        let generationAtStart = generation
        line.downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let voiceNameForRequest = self.voiceName
                func request(atSpeed speed: Double) throws -> URLRequest {
                    var components = URLComponents(string: "https://api.deepgram.com/v1/speak")!
                    components.queryItems = [
                        URLQueryItem(name: "model", value: voiceNameForRequest),
                        URLQueryItem(name: "encoding", value: "linear16"),
                        URLQueryItem(name: "sample_rate", value: String(Int(Self.sampleRate)))
                    ]
                    // Only when slowed, so an ordinary answer's request is
                    // exactly what it always was.
                    if speed != 1.0 {
                        components.queryItems?.append(URLQueryItem(name: "speed", value: String(format: "%.2f", speed)))
                    }
                    var request = URLRequest(url: components.url!)
                    request.httpMethod = "POST"
                    request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: ["text": line.text])
                    return request
                }

                var speed = self.speedParameterRefused ? 1.0 : self.speakingSpeed
                var (bytes, response) = try await self.session.bytes(for: request(atSpeed: speed))
                if speed != 1.0, (response as? HTTPURLResponse)?.statusCode == 400 {
                    TutorDebugLog.write("🔈 narration: Deepgram refused the speed parameter, stretching the audio instead")
                    self.speedParameterRefused = true
                    speed = 1.0
                    (bytes, response) = try await self.session.bytes(for: request(atSpeed: speed))
                }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw DeepgramError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                line.downloadedAtSpeed = speed
                SpendingMeter.record(APIPrices.deepgram(characters: line.text.count), for: .deepgram)

                // About a fifth of a second per chunk: small enough that the
                // first one plays almost at once, large enough not to swamp
                // the engine with buffers.
                let bytesPerChunk = 9_600
                var pending = Data()
                var skippedHeader = false
                for try await byte in bytes {
                    if Task.isCancelled || generationAtStart != self.generation { return }
                    pending.append(byte)
                    if !skippedHeader {
                        guard pending.count >= 44 else { continue }
                        if pending.prefix(4) == Data("RIFF".utf8) { pending.removeFirst(44) }
                        skippedHeader = true
                    }
                    if pending.count >= bytesPerChunk {
                        self.append(pending.prefix(bytesPerChunk), to: line)
                        pending.removeFirst(bytesPerChunk)
                    }
                }
                if !pending.isEmpty { self.append(pending, to: line) }
                line.isDownloaded = true
            } catch {
                guard generationAtStart == self.generation, !Task.isCancelled else { return }
                TutorDebugLog.write("⚠️ narration download failed: \(error.localizedDescription). system voice from here.")
                self.deepgramUnavailable = true
                line.downloadFailed = true
            }
            guard generationAtStart == self.generation else { return }
            self.wake(line)
            self.startNextDownload(after: line)
        }
    }

    private func startNextDownload(after line: Line) {
        let nextIndex = line.index + 1
        if nextIndex < lines.count { startDownload(lines[nextIndex]) }
    }

    private func append(_ chunk: Data, to line: Line) {
        line.chunks.append(Data(chunk))
        line.totalFrames += AVAudioFramePosition(chunk.count / 2)
        wake(line)
    }

    private func wake(_ line: Line) {
        line.waitingForAudio?.resume()
        line.waitingForAudio = nil
    }

    // MARK: - Playing

    private func startPlayer() {
        isSpeaking = true
        let generationAtStart = generation
        playerTask = Task { [weak self] in
            guard let self else { return }
            while generationAtStart == self.generation, self.nextLineToPlay < self.lines.count {
                let line = self.lines[self.nextLineToPlay]
                await self.play(line)
                guard generationAtStart == self.generation, !Task.isCancelled else { return }
                if let sentenceToRepeatFrom = self.sentenceToRepeatFrom {
                    // Cut for "go back": the previous sentence again, then
                    // this one from its start.
                    self.sentenceToRepeatFrom = nil
                    self.nextLineToPlay = sentenceToRepeatFrom
                    continue
                }
                self.onLineFinished?(line.index)
                self.nextLineToPlay += 1
            }
            guard generationAtStart == self.generation else { return }
            self.currentLineIndex = nil
            self.playerTask = nil
            self.isSpeaking = false
        }
    }

    private func play(_ line: Line) async {
        // Paused between sentences: the next one waits too.
        await waitWhilePaused()
        // "Go back" between two sentences: the loop goes back before this one.
        if sentenceToRepeatFrom != nil { return }
        currentLineIndex = line.index
        currentLineIsBeingCut = false
        playToken += 1
        // Nothing has arrived yet: wait for the first audio or a failure.
        if line.chunks.isEmpty, !line.isDownloaded, !line.downloadFailed {
            if line.downloadTask == nil { startDownload(line) }
            await withCheckedContinuation { line.waitingForAudio = $0 }
        }

        if currentLineIsBeingCut { return }
        if line.downloadFailed && line.chunks.isEmpty {
            let estimate = estimatedSeconds(for: line.text)
            onLineStarted?(line.index, estimate)
            try? await fallbackVoice.speakText(line.text)
            return
        }

        do { try startEngineIfNeeded() } catch {
            onLineStarted?(line.index, estimatedSeconds(for: line.text))
            try? await fallbackVoice.speakText(line.text)
            return
        }

        applyTimeStretch(for: line)
        let lengthKnownAtStart = line.isDownloaded
        onLineStarted?(line.index, lengthKnownAtStart ? playedSeconds(of: line) : estimatedSeconds(for: line.text))

        framesScheduledForCurrentLine = 0
        framesPlayedForCurrentLine = 0
        // Paused while the first audio was awaited: the buffers are
        // scheduled below and play once resumed.
        if !isPaused { playerNode.play() }

        var scheduledChunkCount = 0
        while true {
            while scheduledChunkCount < line.chunks.count {
                schedule(line.chunks[scheduledChunkCount])
                scheduledChunkCount += 1
            }
            if line.isDownloaded || line.downloadFailed || currentLineIsBeingCut { break }
            await withCheckedContinuation { line.waitingForAudio = $0 }
            if Task.isCancelled || currentLineIsBeingCut { return }
        }
        if currentLineIsBeingCut { return }
        if !lengthKnownAtStart, line.isDownloaded {
            onLineDurationKnown?(line.index, playedSeconds(of: line))
        }

        // Wait for the last buffer of this sentence to finish playing.
        if framesPlayedForCurrentLine < framesScheduledForCurrentLine {
            await withCheckedContinuation { currentLineDrained = $0 }
        }
    }

    private func schedule(_ chunk: Data) {
        let frameCount = AVAudioFrameCount(chunk.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        chunk.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int16.self).baseAddress,
                  let destination = buffer.floatChannelData?[0] else { return }
            for frame in 0..<Int(frameCount) {
                destination[frame] = Float(source[frame]) / 32_768.0
            }
        }
        framesScheduledForCurrentLine += AVAudioFramePosition(frameCount)
        let generationAtSchedule = generation
        let playTokenAtSchedule = playToken
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generationAtSchedule == self.generation, playTokenAtSchedule == self.playToken else { return }
                self.framesPlayedForCurrentLine += AVAudioFramePosition(frameCount)
                if self.framesPlayedForCurrentLine >= self.framesScheduledForCurrentLine {
                    self.currentLineDrained?.resume()
                    self.currentLineDrained = nil
                }
            }
        }
    }

    private func startEngineIfNeeded() throws {
        guard !(isEngineRunning && audioEngine.isRunning) else { return }
        audioEngine.connect(playerNode, to: timeStretch, format: playbackFormat)
        audioEngine.connect(timeStretch, to: audioEngine.mainMixerNode, format: playbackFormat)
        try audioEngine.start()
        isEngineRunning = true
    }

    private func seconds(_ frames: AVAudioFramePosition) -> TimeInterval {
        Double(frames) / Self.sampleRate
    }

    private func estimatedSeconds(for text: String) -> TimeInterval {
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        return max(0.8, Double(wordCount) / (Self.wordsPerSecond * speakingSpeed))
    }
}
