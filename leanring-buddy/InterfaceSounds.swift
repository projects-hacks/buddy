//
//  InterfaceSounds.swift
//  leanring-buddy
//
//  Short sounds for the moments where hearing beats looking: the mic is
//  live, the question went, the notch opened, something was copied or
//  cleared, something failed. Made by scripts/sounds/make_sounds.py.
//
//  Kept out of the way on purpose:
//  - Nothing decorative plays over the tutor's voice. Only the sounds for
//    the student's own actions with the mic do, since those answer "did it
//    hear me" at the moment it matters.
//  - The water drop on opening the notch is quiet and does not repeat within
//    a few seconds: hover happens constantly, and a sound on every pass
//    would turn charm into nagging within a minute.
//  - Silent when the student turns Sounds off, and when macOS's own "Play
//    user interface sound effects" is off.
//  - Every player is loaded and primed at launch, so a sound is never late.
//

import AVFoundation
import Foundation

@MainActor
final class InterfaceSounds {
    enum Sound: String, CaseIterable {
        case drop, listen, type, sent, tick, wipe, error
    }

    static let shared = InterfaceSounds()
    static let enabledDefaultsKey = "interfaceSoundsEnabled"

    /// Set while the tutor's voice is playing.
    var isTutorSpeaking = false

    private var players: [Sound: AVAudioPlayer] = [:]
    private var lastPlayedAt: [Sound: Date] = [:]

    private init() {
        for sound in Sound.allCases {
            guard let url = Bundle.main.url(forResource: "sound-\(sound.rawValue)", withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else {
                TutorDebugLog.write("⚠️ sound missing: \(sound.rawValue)")
                continue
            }
            player.volume = Self.volume(of: sound)
            player.prepareToPlay()
            players[sound] = player
        }
    }

    /// Loads the players ahead of the first sound.
    func prepare() {}

    func play(_ sound: Sound) {
        guard isEnabled, macOSInterfaceSoundsAreOn else { return }
        if isTutorSpeaking && Self.isDecorative(sound) { return }

        let now = Date()
        if let last = lastPlayedAt[sound], now.timeIntervalSince(last) < Self.minimumGap(for: sound) { return }
        lastPlayedAt[sound] = now

        guard let player = players[sound] else { return }
        player.currentTime = 0
        player.play()
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    /// System Settings > Sound > "Play user interface sound effects". Absent
    /// means it was never changed, which means on.
    private var macOSInterfaceSoundsAreOn: Bool {
        let value = CFPreferencesCopyAppValue(
            "com.apple.sound.uiaudio.enabled" as CFString,
            "com.apple.systemsound" as CFString
        )
        return (value as? NSNumber)?.boolValue ?? true
    }

    private static func isDecorative(_ sound: Sound) -> Bool {
        sound == .drop || sound == .tick || sound == .wipe
    }

    /// Set by ear, against the voice at its usual level: the mic sounds are
    /// clear, the drop and the tick barely there.
    private static func volume(of sound: Sound) -> Float {
        switch sound {
        case .drop: return 0.22
        case .listen: return 0.35
        case .type: return 0.32
        case .sent: return 0.28
        case .tick: return 0.25
        case .wipe: return 0.3
        case .error: return 0.45
        }
    }

    private static func minimumGap(for sound: Sound) -> TimeInterval {
        switch sound {
        case .drop: return 2.5
        case .tick: return 0.15
        default: return 0.3
        }
    }
}
