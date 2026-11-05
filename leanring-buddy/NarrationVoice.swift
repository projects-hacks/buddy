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

import AVFoundation
import Foundation

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
    private var isEngineRunning = false
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
        if playerNode.isPlaying { playerNode.stop() }
        fallbackVoice.stopPlayback()
        currentLineDrained?.resume()
        currentLineDrained = nil
        isSpeaking = false
    }

    // MARK: - Downloading

    private func startDownload(_ line: Line) {
        guard line.downloadTask == nil else { return }
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
                var components = URLComponents(string: "https://api.deepgram.com/v1/speak")!
                components.queryItems = [
                    URLQueryItem(name: "model", value: self.voiceName),
                    URLQueryItem(name: "encoding", value: "linear16"),
                    URLQueryItem(name: "sample_rate", value: String(Int(Self.sampleRate)))
                ]
                var request = URLRequest(url: components.url!)
                request.httpMethod = "POST"
                request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["text": line.text])

                let (bytes, response) = try await self.session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw DeepgramError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
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
                self.onLineFinished?(line.index)
                self.nextLineToPlay += 1
            }
            guard generationAtStart == self.generation else { return }
            self.playerTask = nil
            self.isSpeaking = false
        }
    }

    private func play(_ line: Line) async {
        // Nothing has arrived yet: wait for the first audio or a failure.
        if line.chunks.isEmpty, !line.isDownloaded, !line.downloadFailed {
            if line.downloadTask == nil { startDownload(line) }
            await withCheckedContinuation { line.waitingForAudio = $0 }
        }

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

        let lengthKnownAtStart = line.isDownloaded
        onLineStarted?(line.index, lengthKnownAtStart ? seconds(line.totalFrames) : estimatedSeconds(for: line.text))

        framesScheduledForCurrentLine = 0
        framesPlayedForCurrentLine = 0
        playerNode.play()

        var scheduledChunkCount = 0
        while true {
            while scheduledChunkCount < line.chunks.count {
                schedule(line.chunks[scheduledChunkCount])
                scheduledChunkCount += 1
            }
            if line.isDownloaded || line.downloadFailed { break }
            await withCheckedContinuation { line.waitingForAudio = $0 }
            if Task.isCancelled { return }
        }
        if !lengthKnownAtStart, line.isDownloaded {
            onLineDurationKnown?(line.index, seconds(line.totalFrames))
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
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generationAtSchedule == self.generation else { return }
                self.framesPlayedForCurrentLine += AVAudioFramePosition(frameCount)
                if self.framesPlayedForCurrentLine >= self.framesScheduledForCurrentLine {
                    self.currentLineDrained?.resume()
                    self.currentLineDrained = nil
                }
            }
        }
    }

    private func startEngineIfNeeded() throws {
        guard !isEngineRunning else { return }
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)
        try audioEngine.start()
        isEngineRunning = true
    }

    private func seconds(_ frames: AVAudioFramePosition) -> TimeInterval {
        Double(frames) / Self.sampleRate
    }

    private func estimatedSeconds(for text: String) -> TimeInterval {
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        return max(0.8, Double(wordCount) / Self.wordsPerSecond)
    }
}
