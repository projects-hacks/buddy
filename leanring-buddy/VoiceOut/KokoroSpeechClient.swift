//
//  KokoroSpeechClient.swift
//  leanring-buddy
//
//  Neural speech via a long-lived Kokoro helper process.
//
//  Why not AVSpeechSynthesizer: no premium or enhanced voice is installed on
//  this machine, so every system voice is the compact tier, which sounds
//  flatly synthetic. Slowing the rate and adding pauses helped the pacing but
//  could not fix the timbre. Kokoro is an 82M neural model that runs on-device
//  at roughly twice realtime, which is a different class of sound.
//
//  What it costs: speech now depends on a Python process. It can fail to
//  start, and it can die. Every failure path here falls back to
//  `LocalSpeechSynthesisClient`, because a worse voice is recoverable and
//  silence in the middle of an explanation is not.
//

import AVFoundation
import Foundation

/// Speaks text by generating audio with Kokoro and playing the result.
@MainActor
final class KokoroSpeechClient: NSObject {
    /// Voice to synthesize with. `af_heart` was chosen by listening.
    var voiceName: String = "af_heart"

    /// Speaking rate multiplier passed to Kokoro. Below one is slower.
    var speechSpeed: Double = 0.95

    /// Fires as playback progresses, with the character offset reached so far.
    ///
    /// `AVSpeechSynthesizer` reports true word boundaries. Kokoro returns a
    /// finished waveform with no timing information at all, so this is
    /// interpolated from elapsed time against total duration. It is an
    /// estimate, and it only has to be good enough to land a mark in the right
    /// clause, which proportional timing achieves for a single sentence.
    var onSpokenProgress: ((Int) -> Void)?

    private var helperProcess: Process?
    private var helperInput: FileHandle?
    private var helperOutput: FileHandle?

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var activePlaybackContinuation: CheckedContinuation<Void, Never>?

    /// Whether the helper is up and has reported its model loaded.
    private(set) var isReady = false

    /// Absolute path to the helper script.
    ///
    /// Read from a build setting or defaults rather than hardcoded, so the
    /// script can live beside the repo during development without the path
    /// being baked into the binary.
    private let helperScriptPath: String

    init(helperScriptPath: String) {
        self.helperScriptPath = helperScriptPath
        super.init()
    }

    // MARK: - Lifecycle

    /// Starts the helper and waits for it to report the model is loaded.
    ///
    /// Returns false on any failure, which is the caller's signal to use the
    /// system voice instead.
    @discardableResult
    func start() async -> Bool {
        guard helperProcess == nil else { return isReady }

        guard FileManager.default.fileExists(atPath: helperScriptPath) else {
            TutorDebugLog.write("⚠️ Kokoro helper script missing at \(helperScriptPath)")
            return false
        }

        guard let uvExecutableURL = Self.locateUV() else {
            TutorDebugLog.write("⚠️ uv not found; Kokoro unavailable, using system voice")
            return false
        }

        let process = Process()
        process.executableURL = uvExecutableURL
        process.arguments = [
            "run", "-q",
            "--with", "kokoro-mlx",
            "--with", "soundfile",
            "--with", "numpy",
            "python3", "-I", helperScriptPath
        ]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        // Kept separate so dependency resolution chatter cannot be mistaken
        // for a protocol response on stdout, and thrown away: a pipe nobody
        // reads fills after 64 KB of warnings and the helper then blocks.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            TutorDebugLog.write("⚠️ Kokoro helper failed to start: \(error.localizedDescription)")
            return false
        }

        helperProcess = process
        helperInput = inputPipe.fileHandleForWriting
        helperOutput = outputPipe.fileHandleForReading

        // First line is the readiness report. Resolving dependencies on a cold
        // cache can take a while, hence the generous ceiling.
        guard let readyResponse = await readResponseLine(timeoutSeconds: 180),
              readyResponse["ready"] as? Bool == true else {
            TutorDebugLog.write("⚠️ Kokoro helper never reported ready; using system voice")
            shutDown()
            return false
        }

        let loadSeconds = readyResponse["load_seconds"] as? Double ?? 0
        TutorDebugLog.write("🔊 Kokoro ready in \(String(format: "%.1f", loadSeconds))s, voice \(voiceName)")
        isReady = true
        return true
    }

    func shutDown() {
        stopPlayback()
        stopHelperProcess()
    }

    /// Ends the helper but lets a clip already rendered finish playing:
    /// the next sentence is rendered while the current one plays.
    private func stopHelperProcess() {
        try? helperInput?.close()
        helperProcess?.terminate()
        helperProcess = nil
        helperInput = nil
        helperOutput = nil
        isReady = false
    }

    // MARK: - Speaking

    /// A rendered sentence, ready to play.
    struct GeneratedClip {
        let path: String
        let text: String
    }

    /// The most recent generation, used to serialise requests to the helper.
    ///
    /// The helper speaks one request at a time over a single pipe, so two
    /// overlapping requests would interleave and each would read the other's
    /// response. Chaining keeps them in order while still letting a caller
    /// start the next one early.
    private var lastGenerationTask: Task<GeneratedClip, Error>?

    /// Begins rendering `text` and returns a handle to await.
    ///
    /// Separated from playback so the next sentence can render while the
    /// current one is still being spoken. Rendering and playing in lockstep
    /// left roughly a second and a half of silence before every sentence,
    /// which is what made the speech sound halting rather than fluent.
    @discardableResult
    func beginGeneratingClip(for text: String) -> Task<GeneratedClip, Error> {
        let previousGeneration = lastGenerationTask

        let generationTask = Task { [weak self] () throws -> GeneratedClip in
            // Wait for any earlier render to finish with the pipe. Its failure
            // is not this sentence's problem, hence the discarded result.
            _ = try? await previousGeneration?.value

            guard let self else { throw KokoroError.notRunning }
            return try await self.renderClip(for: text)
        }

        lastGenerationTask = generationTask
        return generationTask
    }

    /// Sends one request to the helper and waits for the rendered file.
    private func renderClip(for text: String) async throws -> GeneratedClip {
        let spokenText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenText.isEmpty else { throw KokoroError.badRequest }
        guard isReady, let helperInput, helperProcess?.isRunning == true else {
            if isReady { TutorDebugLog.write("⚠️ Kokoro helper is no longer running") }
            stopHelperProcess()
            throw KokoroError.notRunning
        }

        let request: [String: Any] = [
            "text": spokenText,
            "voice": voiceName,
            "speed": speechSpeed
        ]
        guard let requestData = try? JSONSerialization.data(withJSONObject: request) else {
            throw KokoroError.badRequest
        }

        // The throwing write: the older `write(_:)` raises an exception on a
        // helper that has exited, which Swift cannot catch.
        do {
            try helperInput.write(contentsOf: requestData + Data("\n".utf8))
        } catch {
            TutorDebugLog.write("⚠️ Kokoro helper did not take the sentence: \(error.localizedDescription)")
            stopHelperProcess()
            throw KokoroError.notRunning
        }

        guard let response = await readResponseLine(timeoutSeconds: 60) else {
            // The reader is still waiting on the pipe and would take the next
            // reply as this one's, so the helper is not asked again.
            TutorDebugLog.write("⚠️ Kokoro helper did not answer in time, stopping it")
            stopHelperProcess()
            throw KokoroError.timedOut
        }
        guard response["ok"] as? Bool == true,
              let clipPath = response["path"] as? String else {
            throw KokoroError.generationFailed(response["error"] as? String ?? "unknown")
        }

        return GeneratedClip(path: clipPath, text: spokenText)
    }

    /// Plays an already-rendered clip, returning when it finishes.
    func play(clip: GeneratedClip) async throws {
        try await playClip(atPath: clip.path, forText: clip.text)
    }

    /// Renders and plays in one step. Kept for callers with nothing to overlap.
    func speakText(_ text: String) async throws {
        let clip = try await beginGeneratingClip(for: text).value
        try await play(clip: clip)
    }

    private func playClip(atPath clipPath: String, forText text: String) async throws {
        let clipURL = URL(fileURLWithPath: clipPath)
        let player = try AVAudioPlayer(contentsOf: clipURL)
        player.delegate = self
        audioPlayer = player

        let totalCharacters = text.count
        let totalDuration = player.duration

        // A player that will not start never calls its delegate, so waiting
        // for the end would wait forever.
        guard player.play() else {
            audioPlayer = nil
            try? FileManager.default.removeItem(at: clipURL)
            throw KokoroError.playbackFailed
        }
        startProgressTimer(totalCharacters: totalCharacters, totalDuration: totalDuration)

        // Never longer than the clip plus a margin, in case the output stops
        // without the player noticing.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((max(0, totalDuration) + 5) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.audioPlayer === player,
                  self.activePlaybackContinuation != nil else { return }
            TutorDebugLog.write("⚠️ Kokoro voice: a clip never finished playing, moving on")
            self.stopPlayback()
        }
        defer { watchdog.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Finished, or stopped, before the wait began.
                if audioPlayer !== player {
                    continuation.resume()
                } else {
                    resumePlaybackContinuation()
                    activePlaybackContinuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.stopPlayback() }
        }

        // The clip is single use, so it goes as soon as it has been heard.
        try? FileManager.default.removeItem(at: clipURL)
    }

    /// Drives `onSpokenProgress` from elapsed playback time.
    private func startProgressTimer(totalCharacters: Int, totalDuration: TimeInterval) {
        progressTimer?.invalidate()
        guard totalCharacters > 0, totalDuration > 0 else { return }

        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, let player = self.audioPlayer, player.isPlaying else {
                    timer.invalidate()
                    return
                }
                let fractionPlayed = min(1.0, player.currentTime / totalDuration)
                self.onSpokenProgress?(Int(fractionPlayed * Double(totalCharacters)))
            }
        }
    }

    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    func stopPlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        resumePlaybackContinuation()
    }

    private func resumePlaybackContinuation() {
        guard let continuation = activePlaybackContinuation else { return }
        activePlaybackContinuation = nil
        continuation.resume()
    }

    // MARK: - Helper IO

    /// Reads one newline-terminated JSON response, or nil on timeout.
    ///
    /// Reading happens off the main actor because `availableData` blocks, and
    /// blocking the main actor here would freeze the overlay while the tutor
    /// is mid-sentence.
    private func readResponseLine(timeoutSeconds: TimeInterval) async -> [String: Any]? {
        guard let helperOutput else { return nil }

        return await withCheckedContinuation { continuation in
            let hasResumed = ResumeGuard()

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) {
                if hasResumed.claim() { continuation.resume(returning: nil) }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                while true {
                    let chunk = helperOutput.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    guard let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) else { continue }

                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                    let parsed = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                    if hasResumed.claim() { continuation.resume(returning: parsed ?? nil) }
                    return
                }
                if hasResumed.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Finds `uv`, which is not on the PATH a GUI app inherits.
    private static func locateUV() -> URL? {
        let candidatePaths = [
            "\(NSHomeDirectory())/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv"
        ]
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

// MARK: - Playback completion

extension KokoroSpeechClient: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // A clip that was replaced finishing late is not the current one.
            guard audioPlayer === player else { return }
            progressTimer?.invalidate()
            progressTimer = nil
            audioPlayer = nil
            // Report the end of the text so any mark attached past the last
            // sampled position still fires.
            resumePlaybackContinuation()
        }
    }

    /// A clip that cannot be decoded never finishes either.
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard audioPlayer === player else { return }
            TutorDebugLog.write("⚠️ Kokoro voice: clip could not be decoded (\(error?.localizedDescription ?? "unknown"))")
            stopPlayback()
        }
    }
}

// MARK: - Supporting types

/// One-shot latch, so a timeout racing a read cannot resume a continuation twice.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasFired { return false }
        hasFired = true
        return true
    }
}

enum KokoroError: LocalizedError {
    case notRunning
    case badRequest
    case timedOut
    case generationFailed(String)
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .playbackFailed: return "The rendered clip would not play."
        case .notRunning: return "Kokoro helper is not running."
        case .badRequest: return "Could not encode the speech request."
        case .timedOut: return "Kokoro did not respond in time."
        case .generationFailed(let detail): return "Kokoro failed: \(detail)"
        }
    }
}
