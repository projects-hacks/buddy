//
//  DeepgramSpeechClient.swift
//  leanring-buddy
//
//  Hosted speech, streamed as raw PCM straight into the audio engine.
//
//  Why not wait for the finished file: measured against this account, the
//  whole clip takes 2.7 to 4.2 seconds to download, but the first bytes
//  arrive in about 0.16 once the connection is warm. Playing from a complete
//  file throws that away and waits for the slowest number. Feeding the engine
//  as the bytes land turns a three second wait into a fifth of a second.
//
//  Why `linear16`: it is uncompressed PCM, so each chunk can be handed to the
//  engine the moment it arrives with no decoder to keep in sync and no frame
//  boundaries to reassemble. The extra bandwidth is irrelevant next to the
//  latency it saves.
//

import AVFoundation
import Foundation

/// Speaks text using Deepgram's Aura voices.
@MainActor
final class DeepgramSpeechClient {
    /// Voice identifier.
    ///
    /// Deepgram's own examples use `aura-2-thalia-en`, which their docs tag
    /// "Energetic, Enthusiastic" for casual chat. This defaults to a voice
    /// their docs tag "Professional" for informative delivery instead, which
    /// is the register of a study helper rather than an assistant.
    var voiceName: String = "aura-2-hera-en"

    /// PCM sample rate requested from the API and used by the engine.
    private static let sampleRate: Double = 24_000

    private let session: URLSession
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isEngineRunning = false

    /// Frames handed to the player for the sentence being spoken, used to
    /// report progress without guessing.
    private var scheduledFrameCount: AVAudioFramePosition = 0
    private var playedFrameCount: AVAudioFramePosition = 0
    private var totalCharactersInCurrentSentence = 0

    /// Fires as playback advances, with the character offset reached.
    ///
    /// Derived from frames actually played rather than elapsed wall time, so
    /// it stays correct even when rendering stalls mid-sentence.
    var onSpokenProgress: ((Int) -> Void)?

    private var activePlaybackContinuation: CheckedContinuation<Void, Never>?
    private var isCancelled = false
    private var engineConfigurationObserver: NSObjectProtocol?
    /// Which sentence the scheduled buffers belong to, so a completion from
    /// a sentence that was ended never counts toward the next one.
    private var sentenceToken = 0

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        // Reused so the TLS handshake is not paid per sentence: the first
        // request measured 1.31s to first byte against 0.16s once warm.
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration)

        audioEngine.attach(playerNode)
        // A device change (headphones, AirPods, a display's speakers) stops
        // the engine and drops every scheduled buffer. Noticed here, the
        // sentence ends and the next one starts the engine again; unnoticed,
        // the next play() would raise on a stopped engine.
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                TutorDebugLog.write("🔈 Deepgram voice: audio device changed, restarting the engine")
                self.isEngineRunning = false
                self.sentenceToken += 1
                if self.playerNode.isPlaying { self.playerNode.stop() }
                self.resumePlaybackContinuation()
            }
        }
    }

    var isConfigured: Bool { APIKeyStore.hasKey(for: .deepgram) }

    // MARK: - Speaking

    /// Streams `text` as speech, returning when playback finishes.
    func speakText(_ text: String) async throws {
        let spokenText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenText.isEmpty else { return }
        guard let apiKey = APIKeyStore.key(for: .deepgram) else {
            throw DeepgramError.missingKey
        }

        // One sentence at a time. A call that arrives while another is still
        // speaking ends that one first, so its continuation is resumed rather
        // than overwritten and its stream stops feeding the player.
        if activePlaybackContinuation != nil || playerNode.isPlaying { stopPlayback() }
        isCancelled = false
        sentenceToken += 1
        let thisSentenceToken = sentenceToken
        /// Ended by a stop, a device change or a newer sentence.
        func thisSentenceWasEnded() -> Bool { isCancelled || sentenceToken != thisSentenceToken }
        totalCharactersInCurrentSentence = spokenText.count
        scheduledFrameCount = 0
        playedFrameCount = 0

        try startEngineIfNeeded()

        var components = URLComponents(string: "https://api.deepgram.com/v1/speak")!
        components.queryItems = [
            URLQueryItem(name: "model", value: voiceName),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(Int(Self.sampleRate)))
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": spokenText])

        let (byteStream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepgramError.malformedResponse }
        guard (200...299).contains(http.statusCode) else {
            throw DeepgramError.httpStatus(http.statusCode)
        }
        SpendingMeter.record(APIPrices.deepgram(characters: spokenText.count), for: .deepgram)

        guard let format = Self.playbackFormat else {
            throw DeepgramError.malformedResponse
        }

        guard !thisSentenceWasEnded() else { return }

        // The engine may have stopped while the request was in flight, and
        // playing into a stopped engine raises an exception nothing catches.
        try startEngineIfNeeded()
        guard audioEngine.isRunning else { throw DeepgramError.audioEngineStopped }
        playerNode.play()

        // Chunked rather than scheduled per byte: a buffer per sample would
        // swamp the engine, and waiting for the whole response would give back
        // the latency this exists to save. Roughly a fifth of a second of
        // audio per buffer keeps the queue fed without noticeable granularity.
        let framesPerBuffer = 4_800
        let bytesPerBuffer = framesPerBuffer * 2
        var pendingBytes = Data()
        var hasSkippedHeader = false

        for try await byte in byteStream {
            if thisSentenceWasEnded() { break }
            pendingBytes.append(byte)

            // Deepgram returns a WAV container for linear16, so the 44 byte
            // header has to go before the rest is treated as samples.
            if !hasSkippedHeader {
                guard pendingBytes.count >= 44 else { continue }
                if pendingBytes.prefix(4) == Data("RIFF".utf8) {
                    pendingBytes.removeFirst(44)
                }
                hasSkippedHeader = true
            }

            guard pendingBytes.count >= bytesPerBuffer else { continue }
            let chunk = pendingBytes.prefix(bytesPerBuffer)
            pendingBytes.removeFirst(bytesPerBuffer)
            scheduleChunk(chunk, format: format)
        }

        if !thisSentenceWasEnded(), !pendingBytes.isEmpty {
            scheduleChunk(pendingBytes, format: format)
        }

        guard !thisSentenceWasEnded() else { return }

        // Never longer than what is left of the audio plus a margin: an
        // output that stops rendering without a notification leaves the
        // buffer completions unfired.
        let sentenceTokenAtWait = sentenceToken
        let secondsOfAudioLeft = Double(scheduledFrameCount - playedFrameCount) / Self.sampleRate
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((max(0, secondsOfAudioLeft) + 5) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.sentenceToken == sentenceTokenAtWait,
                  self.activePlaybackContinuation != nil else { return }
            TutorDebugLog.write("⚠️ Deepgram voice: a sentence never finished playing, moving on")
            self.sentenceToken += 1
            if self.playerNode.isPlaying { self.playerNode.stop() }
            self.audioEngine.stop()
            self.isEngineRunning = false
            self.resumePlaybackContinuation()
        }
        defer { watchdog.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Nothing was scheduled, or all of it has played already, so
                // nothing will complete.
                if scheduledFrameCount == 0 || playedFrameCount >= scheduledFrameCount || thisSentenceWasEnded() {
                    continuation.resume()
                } else {
                    resumePlaybackContinuation()
                    activePlaybackContinuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.stopPlayback() }
        }
    }

    /// Format the engine plays, and the format buffers must be built in.
    ///
    /// Float32 rather than the Int16 the API returns. The player node has to be
    /// connected with the same format as the buffers scheduled on it, and
    /// AVAudioEngine's mixer works in float: connecting with Int16 left every
    /// buffer unplayed, the completion handler never fired, and the whole
    /// pipeline waited forever on a sentence that was never spoken. The
    /// samples are converted on the way in instead.
    private static let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )

    /// Converts one chunk of 16-bit PCM to a float buffer and queues it.
    private func scheduleChunk(_ chunk: Data, format: AVAudioFormat) {
        let frameCount = AVAudioFrameCount(chunk.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount

        chunk.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: Int16.self).baseAddress,
                  let destination = buffer.floatChannelData?[0] else { return }
            // Int16 full scale is 32768, so this maps to the -1...1 range the
            // engine expects.
            for frameIndex in 0..<Int(frameCount) {
                destination[frameIndex] = Float(source[frameIndex]) / 32_768.0
            }
        }

        scheduledFrameCount += AVAudioFramePosition(frameCount)
        let totalScheduledAtQueueTime = scheduledFrameCount
        let sentenceTokenAtSchedule = sentenceToken

        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled, self.sentenceToken == sentenceTokenAtSchedule else { return }

                self.playedFrameCount += AVAudioFramePosition(frameCount)

                // Characters are assumed evenly spread across the audio, which
                // is close enough to land a mark in the right clause. Deepgram
                // does not return word timings on this endpoint.
                if self.totalCharactersInCurrentSentence > 0, self.scheduledFrameCount > 0 {
                    let fractionPlayed = Double(self.playedFrameCount) / Double(self.scheduledFrameCount)
                    let reachedOffset = Int(
                        min(1.0, fractionPlayed) * Double(self.totalCharactersInCurrentSentence)
                    )
                    self.onSpokenProgress?(reachedOffset)
                }

                // Finished only when the last queued buffer is the one that
                // just drained and nothing further arrived behind it.
                if self.playedFrameCount >= totalScheduledAtQueueTime,
                   self.playedFrameCount >= self.scheduledFrameCount {
                    self.resumePlaybackContinuation()
                }
            }
        }
    }

    private func startEngineIfNeeded() throws {
        guard !(isEngineRunning && audioEngine.isRunning) else { return }

        // Connected with the buffer format, not the output device's format.
        // The engine resamples to the hardware rate itself; scheduling buffers
        // whose format differs from the connection is what silently dropped
        // every one of them.
        guard let format = Self.playbackFormat else {
            throw DeepgramError.malformedResponse
        }
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        try audioEngine.start()
        isEngineRunning = true
    }

    var isPlaying: Bool { playerNode.isPlaying }

    func stopPlayback() {
        isCancelled = true
        sentenceToken += 1
        if playerNode.isPlaying {
            playerNode.stop()
        }
        scheduledFrameCount = 0
        playedFrameCount = 0
        resumePlaybackContinuation()
    }

    func shutDown() {
        stopPlayback()
        if isEngineRunning {
            audioEngine.stop()
            isEngineRunning = false
        }
    }

    private func resumePlaybackContinuation() {
        guard let continuation = activePlaybackContinuation else { return }
        activePlaybackContinuation = nil
        continuation.resume()
    }
}

// MARK: - Errors

extension Notification.Name {
    /// Deepgram refused the key while listening (the object is the
    /// `DeepgramError`), posted on the main thread for the key banner.
    static let deepgramKeyRefused = Notification.Name("buddy.deepgramKeyRefused")
}

enum DeepgramError: LocalizedError {
    case missingKey
    case httpStatus(Int)
    case malformedResponse
    case audioEngineStopped

    var errorDescription: String? {
        switch self {
        case .audioEngineStopped:
            return "The audio output stopped."
        case .missingKey:
            return "No Deepgram API key saved."
        case .httpStatus(let code):
            return "Deepgram HTTP \(code)."
        case .malformedResponse:
            return "Deepgram returned audio in an unexpected shape."
        }
    }
}
