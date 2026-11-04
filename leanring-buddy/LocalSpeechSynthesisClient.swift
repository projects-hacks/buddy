//
//  LocalSpeechSynthesisClient.swift
//  leanring-buddy
//
//  On-device text-to-speech via AVSpeechSynthesizer, replacing the hosted
//  hosted voice path. Matches the hosted voice clients' surface so the companion
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
    /// Below default on purpose. This was set above default on the assumption
    /// that stock pacing sounds sluggish, which was wrong for teaching: the
    /// listener is meeting unfamiliar terms for the first time and needs room
    /// to take each one in. Rushed delivery is the single thing that most makes
    /// a synthetic voice sound like a machine reading rather than a person
    /// explaining.
    var speechRateMultiplier: Float = 0.94

    /// Silence left after each sentence, in seconds.
    ///
    /// Because sentences are spoken as separate utterances, without this they
    /// run together into one breathless stream. A real explanation has gaps at
    /// the clause boundaries, and the gap is where the listener catches up.
    var pauseBetweenSentencesSeconds: TimeInterval = 0.28

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

    /// Narrator voices, in fallback order.
    ///
    /// macOS installs these alongside character voices such as Grandma, Rocko
    /// and Bubbles, which are indistinguishable by any API flag. On the machine
    /// this was built for, every installed English voice reported `default`
    /// quality, so a pure quality ranking left every voice tied and the winner
    /// was whichever the sort happened to favour. An explicit list is the only
    /// reliable way to keep a tutor from explaining binary search in Bubbles.
    private static let narratorVoiceNamesInFallbackOrder = [
        "Samantha", "Alex", "Ava", "Allison", "Susan", "Tom",
        "Rishi", "Daniel", "Serena", "Kate",
        "Karen", "Moira", "Fiona", "Tessa"
    ]

    /// Picks the best-sounding installed English voice.
    ///
    /// Quality first, because a downloaded premium or enhanced voice is a far
    /// larger improvement than any choice among compact ones. Then a voice
    /// whose region matches the user's locale, so the accent is not jarring.
    /// Then the narrator list, which is what breaks the all-compact tie.
    private static func resolveHighestQualityEnglishVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix("en")
        }
        guard !englishVoices.isEmpty else { return nil }

        let currentRegionCode = Locale.current.region?.identifier ?? "US"

        func score(for voice: AVSpeechSynthesisVoice) -> Int {
            var total = 0

            switch voice.quality {
            case .premium: total += 10_000
            case .enhanced: total += 5_000
            default: break
            }

            // Region match, for example an en-IN voice for a user in India.
            if voice.language.hasSuffix("-\(currentRegionCode)") { total += 1_000 }

            // Earlier in the narrator list scores higher. A voice absent from
            // the list scores nothing here, which is what demotes the
            // character voices without needing to enumerate them.
            if let listPosition = narratorVoiceNamesInFallbackOrder.firstIndex(where: { name in
                voice.name.localizedCaseInsensitiveContains(name)
            }) {
                total += 100 * (narratorVoiceNamesInFallbackOrder.count - listPosition)
            }

            return total
        }

        // Compare on score, falling back to name so the result is stable rather
        // than depending on the sort's handling of equal elements.
        return englishVoices.max { firstVoice, secondVoice in
            let firstScore = score(for: firstVoice)
            let secondScore = score(for: secondVoice)
            if firstScore != secondScore { return firstScore < secondScore }
            return firstVoice.name > secondVoice.name
        }
    }

    // MARK: - Speaking

    /// Speaks `text` aloud, returning once playback finishes.
    ///
    /// Note the contract difference from the hosted clients, which
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
        // The beat after each sentence, which is what turns a stream of
        // utterances into something that sounds like someone thinking.
        utterance.postUtteranceDelay = pauseBetweenSentencesSeconds

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
