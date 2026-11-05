//
//  DeepgramTranscriptionProvider.swift
//  leanring-buddy
//
//  Speech to text with Deepgram's Nova-3, streamed while the keys are held,
//  with Apple's recognizer listening to the same audio as a backup.
//
//  Why Deepgram when Apple's recognizer is free. Apple's on-device model is
//  weak on technical words ("wallet DB" heard as "wall DB"), starts a new
//  utterance after every pause, and takes vocabulary only as a soft hint.
//  Nova-3 is trained on far more speech, is told the terms to expect up
//  front (keyterm prompting), and returns each finished stretch of speech
//  marked final, so a long explanation with pauses arrives whole. It costs
//  about $0.009 a minute of speech, a third of a cent for a 20 second
//  question, and only runs when a Deepgram key is set.
//
//  Why Apple as well. A network drop or a rejected key mid-question would
//  otherwise lose what was said. Both hear the same audio; Deepgram's text is
//  used when it arrives, Apple's when it does not, and nothing is asked twice.
//
//  The protocol, from Deepgram's own reference: audio as binary frames of
//  16 bit mono PCM, `Finalize` then `CloseStream` on release, and the final
//  `Metadata` message as the sign that every result has been sent.
//

import AVFoundation
import Foundation

/// Deepgram when there is a key, Apple Speech alongside it; Apple Speech
/// alone otherwise. Decided per question, so a key added in Settings is used
/// from the next question on.
final class PreferredTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Deepgram Nova-3, with Apple Speech as backup"
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true
    let unavailableExplanation: String? = nil

    private let appleSpeech = AppleSpeechTranscriptionProvider()

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let deepgramKey = APIKeyStore.key(for: .deepgram) else {
            return try await appleSpeech.startStreamingSession(
                keyterms: keyterms, onTranscriptUpdate: onTranscriptUpdate,
                onFinalTranscriptReady: onFinalTranscriptReady, onError: onError)
        }
        let combined = CombinedTranscriptionSession(
            onTranscriptUpdate: onTranscriptUpdate, onFinalTranscriptReady: onFinalTranscriptReady, onError: onError)
        // Apple first: if it cannot start, Deepgram alone still hears the question.
        if let backup = try? await appleSpeech.startStreamingSession(
            keyterms: keyterms,
            onTranscriptUpdate: { [weak combined] text in combined?.appleUpdated(text) },
            onFinalTranscriptReady: { [weak combined] text in combined?.appleFinished(text) },
            onError: { [weak combined] _ in combined?.appleFailed() }) {
            combined.backup = backup
        }
        combined.deepgram = DeepgramStreamingSession(
            apiKey: deepgramKey, keyterms: keyterms,
            onTranscriptUpdate: { [weak combined] text in combined?.deepgramUpdated(text) },
            onFinished: { [weak combined] text in combined?.deepgramFinished(text) },
            onFailed: { [weak combined] error in combined?.deepgramFailed(error) })
        return combined
    }
}

/// One question heard by both recognizers. Deepgram's words win whenever
/// it has any; Apple's are the fallback.
private final class CombinedTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// Deepgram usually answers a Finalize in well under half a second; the
    /// dictation manager gives up and takes the best text so far after this.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.5

    var deepgram: DeepgramStreamingSession?
    var backup: (any BuddyStreamingTranscriptionSession)?

    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void
    private let lock = NSLock()

    private var deepgramText = ""
    private var appleText = ""
    private var deepgramDone = false
    private var deepgramBroken = false
    private var appleDone = false
    private var appleBroken = false
    private var delivered = false

    init(onTranscriptUpdate: @escaping (String) -> Void,
         onFinalTranscriptReady: @escaping (String) -> Void,
         onError: @escaping (Error) -> Void) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        deepgram?.appendAudioBuffer(audioBuffer)
        backup?.appendAudioBuffer(audioBuffer)
    }

    func requestFinalTranscript() {
        deepgram?.requestFinalTranscript()
        backup?.requestFinalTranscript()
    }

    func cancel() {
        deepgram?.cancel()
        backup?.cancel()
    }

    // MARK: Results from each

    func deepgramUpdated(_ text: String) {
        lock.lock(); deepgramText = text; lock.unlock()
        onTranscriptUpdate(text)
    }

    func appleUpdated(_ text: String) {
        lock.lock(); appleText = text; let showApple = deepgramText.isEmpty; lock.unlock()
        // Live words come from Apple only until Deepgram has heard something.
        if showApple { onTranscriptUpdate(text) }
    }

    func deepgramFinished(_ text: String) {
        lock.lock(); deepgramText = text; deepgramDone = true; lock.unlock()
        deliverIfReady()
    }

    func deepgramFailed(_ error: Error) {
        TutorDebugLog.write("🎙️ Deepgram did not finish (\(error.localizedDescription)); using Apple Speech for this question")
        lock.lock(); deepgramBroken = true; lock.unlock()
        deliverIfReady()
    }

    func appleFinished(_ text: String) {
        lock.lock(); appleText = text; appleDone = true; lock.unlock()
        deliverIfReady()
    }

    func appleFailed() {
        lock.lock(); appleBroken = true; lock.unlock()
        deliverIfReady()
    }

    private func deliverIfReady() {
        lock.lock()
        guard !delivered else { lock.unlock(); return }
        var chosen: (text: String, source: String)?
        if deepgramDone, !deepgramText.isEmpty {
            chosen = (deepgramText, "Deepgram")
        } else if (deepgramDone || deepgramBroken), appleDone, !appleText.isEmpty {
            chosen = (appleText, "Apple Speech")
        } else if (deepgramDone || deepgramBroken), (appleDone || appleBroken || backup == nil) {
            // Neither heard anything usable.
            delivered = true
            lock.unlock()
            if deepgramText.isEmpty && appleText.isEmpty {
                onError(NSError(domain: "Transcription", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "no speech was recognised"]))
            } else {
                onFinalTranscriptReady(deepgramText.isEmpty ? appleText : deepgramText)
            }
            return
        }
        guard let chosen else { lock.unlock(); return }
        delivered = true
        lock.unlock()
        TutorDebugLog.write("🎙️ heard by \(chosen.source)")
        onFinalTranscriptReady(chosen.text)
    }
}

/// One question streamed to Deepgram.
final class DeepgramStreamingSession {
    /// Nova-3 streaming plus keyterm prompting, pay as you go, per minute.
    static let dollarsPerMinute = 0.0077 + 0.0013
    private static let sampleRate = 16_000

    private let socket: URLSessionWebSocketTask
    private let converter = BuddyPCM16AudioConverter(targetSampleRate: Double(sampleRate))
    private let onTranscriptUpdate: (String) -> Void
    private let onFinished: (String) -> Void
    private let onFailed: (Error) -> Void
    private let queue = DispatchQueue(label: "buddy.deepgram-listen")

    // Touched only on `queue`.
    private var finalizedSegments: [String] = []
    private var interimText = ""
    private var bytesSent = 0
    private var hasEnded = false
    private var isFinishing = false

    init(apiKey: String, keyterms: [String],
         onTranscriptUpdate: @escaping (String) -> Void,
         onFinished: @escaping (String) -> Void,
         onFailed: @escaping (Error) -> Void) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinished = onFinished
        self.onFailed = onFailed

        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var items = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(Self.sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "language", value: "en")
        ]
        // One keyterm parameter per term, as Deepgram asks; it caps them at
        // about 500 tokens, which 60 short terms stay well inside.
        items += keyterms.prefix(60).map { URLQueryItem(name: "keyterm", value: $0) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        receive()
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let data = converter.convertToPCM16Data(from: audioBuffer) else { return }
        queue.async { [weak self] in
            guard let self, !self.isFinishing, !self.hasEnded else { return }
            self.bytesSent += data.count
            self.socket.send(.data(data)) { _ in }
        }
    }

    /// Released: flush what is buffered, then close. Deepgram sends the last
    /// results and a Metadata message, then closes the socket.
    func requestFinalTranscript() {
        queue.async { [weak self] in
            guard let self, !self.isFinishing, !self.hasEnded else { return }
            self.isFinishing = true
            self.socket.send(.string(#"{"type":"Finalize"}"#)) { _ in }
            self.socket.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.hasEnded else { return }
            self.hasEnded = true
            self.recordCost()
            self.socket.cancel(with: .normalClosure, reason: nil)
        }
    }

    private var transcriptSoFar: String {
        (finalizedSegments + (interimText.isEmpty ? [] : [interimText])).joined(separator: " ")
    }

    private func receive() {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.hasEnded else { return }
                switch result {
                case .failure(let error):
                    self.end(error: self.isFinishing && !self.finalizedSegments.isEmpty ? nil : error)
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    if !self.hasEnded { self.receive() }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        switch json["type"] as? String {
        case "Results":
            let channel = json["channel"] as? [String: Any]
            let transcript = ((channel?["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if json["is_final"] as? Bool == true {
                if !transcript.isEmpty { finalizedSegments.append(transcript) }
                interimText = ""
            } else {
                interimText = transcript
            }
            let snapshot = transcriptSoFar
            DispatchQueue.main.async { self.onTranscriptUpdate(snapshot) }
        case "Metadata":
            // Sent after CloseStream once every result has gone out.
            if isFinishing { end(error: nil) }
        case "Error":
            end(error: NSError(domain: "Deepgram", code: 2,
                               userInfo: [NSLocalizedDescriptionKey: json["description"] as? String ?? "error"]))
        default:
            break
        }
    }

    private func end(error: Error?) {
        guard !hasEnded else { return }
        hasEnded = true
        recordCost()
        socket.cancel(with: .normalClosure, reason: nil)
        let text = finalizedSegments.joined(separator: " ")
        DispatchQueue.main.async {
            if let error { self.onFailed(error) } else { self.onFinished(text) }
        }
    }

    /// Billed per second of audio sent.
    private func recordCost() {
        let seconds = Double(bytesSent) / Double(Self.sampleRate * 2)
        SpendingMeter.record(seconds / 60 * Self.dollarsPerMinute, for: .deepgram)
    }
}
