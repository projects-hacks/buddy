//
//  LocalSpeechSynthesisClient.swift
//  leanring-buddy
//
//  On-device text-to-speech via AVSpeechSynthesizer, replacing the hosted
//  ElevenLabs path. Matches `ElevenLabsTTSClient`'s surface so the companion
//  pipeline can swap between them.
//

import AVFoundation
import Foundation

/// Speaks responses aloud using the voices already installed on this Mac.
///
/// Why on-device: it is free, it works with no network, and it starts speaking
/// immediately instead of waiting for an audio file to be generated and
/// downloaded. The tradeoff is prosody, which is noticeably flatter than a
/// hosted neural voice. That is mitigated by preferring the highest-quality
/// voice macOS has, and the quality ceiling is why `speechRateMultiplier` and
/// voice choice are exposed rather than hardcoded.
@MainActor
final class LocalSpeechSynthesisClient: NSObject {
    private let synthesizer = AVSpeechSynthesizer()

    /// Resolved once, because enumerating installed voices is not free and the
    /// set does not change while the app is running.
    private let selectedVoice: AVSpeechSynthesisVoice?

    /// Continuation for the in-flight `speakText` call, resumed when the
    /// utterance finishes or is cancelled.
    private var activeSpeechContinuation: CheckedContinuation<Void, Error>?

    /// Called as each word is about to be spoken, with the character range of
    /// that word in the text passed to `speakText`.
    ///
    /// This is what lets an on-screen annotation land on the word that
    /// describes it, rather than all drawings appearing at once up front.
    var onWillSpeakRange: ((NSRange, String) -> Void)?

    /// Multiplier applied to the system default speech rate.
    ///
    /// Slightly above default: explanation audio at the stock rate sounds
    /// sluggish, but pushing it far hurts comprehension of unfamiliar terms,
    /// which is exactly what a learner is listening for.
    var speechRateMultiplier: Float = 1.08

    override init() {
        self.selectedVoice = Self.resolveHighestQualityEnglishVoice()
        super.init()
        synthesizer.delegate = self

        if let selectedVoice {
            print("🗣️ LocalSpeechSynthesis: using \(selectedVoice.name) (\(selectedVoice.quality.debugDescriptionForLogging))")
        } else {
            print("⚠️ LocalSpeechSynthesis: no English voice found, falling back to system default")
        }
    }

    // MARK: - Voice selection

    /// Picks the best-sounding installed English voice.
    ///
    /// macOS ships a compact default and lets users download premium and
    /// enhanced voices that sound dramatically better. Preferring those when
    /// present is the single largest quality win available without leaving
    /// the device, and costs nothing when they are absent.
    private static func resolveHighestQualityEnglishVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix("en")
        }

        guard !englishVoices.isEmpty else { return nil }

        func qualityRank(for voice: AVSpeechSynthesisVoice) -> Int {
            switch voice.quality {
            case .premium: return 3
            case .enhanced: return 2
            case .default: return 1
            @unknown default: return 0
            }
        }

        // Prefer quality first, then a voice matching the user's own locale so
        // the accent is not jarring against their expectations.
        let preferredLanguageCode = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")

        return englishVoices.max { firstVoice, secondVoice in
            let firstRank = qualityRank(for: firstVoice)
            let secondRank = qualityRank(for: secondVoice)
            if firstRank != secondRank { return firstRank < secondRank }

            let firstMatchesLocale = preferredLanguageCode.hasPrefix(firstVoice.language)
            let secondMatchesLocale = preferredLanguageCode.hasPrefix(secondVoice.language)
            return !firstMatchesLocale && secondMatchesLocale
        }
    }

    // MARK: - Speaking

    /// Speaks `text` aloud, returning once playback finishes.
    ///
    /// Note the contract difference from the hosted client: `ElevenLabsTTSClient`
    /// returned as soon as playback started, because the audio was already fully
    /// downloaded. Here the utterance is synthesized progressively, so awaiting
    /// actual completion is both possible and more useful for sequencing.
    func speakText(_ text: String) async throws {
        let spokenText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenText.isEmpty else { return }

        stopPlayback()

        let utterance = AVSpeechUtterance(string: spokenText)
        utterance.voice = selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * speechRateMultiplier
        // Flat pitch and full volume: pitch shifting on an already-synthetic
        // voice reads as cartoonish rather than warmer.
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                activeSpeechContinuation = continuation
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor in self.stopPlayback() }
        }
    }

    /// Whether speech is currently being produced.
    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    /// Stops any in-progress speech immediately.
    ///
    /// `.immediate` rather than `.word` so a barge-in while the user presses
    /// push-to-talk cuts off mid-word instead of talking over them.
    func stopPlayback() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        resumeActiveContinuation()
    }

    /// Resumes and clears the pending continuation exactly once, so a
    /// cancel racing a natural finish cannot resume it twice.
    private func resumeActiveContinuation() {
        guard let continuation = activeSpeechContinuation else { return }
        activeSpeechContinuation = nil
        continuation.resume()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension LocalSpeechSynthesisClient: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        MainActor.assumeIsolated { resumeActiveContinuation() }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        MainActor.assumeIsolated { resumeActiveContinuation() }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        MainActor.assumeIsolated {
            onWillSpeakRange?(characterRange, utterance.speechString)
        }
    }
}

// MARK: - Logging helpers

private extension AVSpeechSynthesisVoiceQuality {
    /// Human-readable quality name, for the startup log line only.
    var debugDescriptionForLogging: String {
        switch self {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        case .default: return "default"
        @unknown default: return "unknown"
        }
    }
}
