//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    /// Asks for the words heard so far as final, and keeps listening.
    func flushPendingWords()
    func cancel()
}

extension BuddyStreamingTranscriptionSession {
    /// A recognizer whose partial words are already its best has nothing
    /// to flush (Apple Speech).
    func flushPendingWords() {}
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    /// Deepgram Nova-3 when a Deepgram key is set, with Apple Speech hearing
    /// the same audio as a backup; Apple Speech alone otherwise
    /// (DeepgramTranscriptionProvider.swift). Push-to-talk's, so its
    /// minutes are counted as hearing the student.
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = PreferredTranscriptionProvider(spendingPurpose: .hearing)
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }
}
