//
//  TalkOverMicrophone.swift
//  leanring-buddy
//
//  Which microphone talk-over listens through. A Bluetooth headset's
//  microphone switches the headset to call quality for as long as it is
//  open, which is the whole answer, so Buddy's voice and the video would
//  sound like a phone call. With a headset as the input, talk-over listens
//  through the Mac's own microphone instead, and the headset keeps playing
//  at full quality. With headphones on, that microphone hears little of
//  Buddy or of a video, so there is little to filter out. A Mac with no
//  microphone of its own, or a laptop with its lid closed, has nothing to
//  switch to, and talk-over stays off; holding the keys still works.
//

import CoreAudio
import CoreGraphics
import Foundation

/// One audio device, as far as choosing a microphone needs to know it.
struct AudioInputCandidate: Equatable {
    let deviceIdentifier: AudioDeviceID
    let transportType: UInt32
    let hasInput: Bool

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
    var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
}

enum TalkOverMicrophone {
    enum Choice: Equatable {
        /// The system's input, as before.
        case systemInput
        /// The Mac's own microphone, because the system's is a headset.
        case builtIn(AudioDeviceID)
        /// Nothing to listen through without degrading the headset.
        case none(reason: String)
    }

    /// Pure, so the unit tests cover every case without hardware.
    static func choose(systemInput: AudioInputCandidate?, devices: [AudioInputCandidate],
                       builtInMicrophoneCanHear: Bool) -> Choice {
        guard let systemInput, systemInput.isBluetooth else { return .systemInput }
        guard let builtIn = devices.first(where: { $0.isBuiltIn && $0.hasInput }) else {
            return .none(reason: "the microphone is a Bluetooth headset and this Mac has none of its own")
        }
        guard builtInMicrophoneCanHear else {
            return .none(reason: "the microphone is a Bluetooth headset and the Mac's own is off with the lid closed")
        }
        return .builtIn(builtIn.deviceIdentifier)
    }

    /// The choice for this Mac as it is now.
    static func current() -> Choice {
        choose(systemInput: systemInputDevice(), devices: allDevices(), builtInMicrophoneCanHear: builtInDisplayIsOn())
    }

    // MARK: - Reading Core Audio

    private static func systemInputDevice() -> AudioInputCandidate? {
        var deviceIdentifier = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIdentifier) == noErr,
              deviceIdentifier != 0 else { return nil }
        return candidate(deviceIdentifier)
    }

    private static func allDevices() -> [AudioInputCandidate] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var identifiers = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &identifiers) == noErr else { return [] }
        return identifiers.map(candidate)
    }

    private static func candidate(_ deviceIdentifier: AudioDeviceID) -> AudioInputCandidate {
        var transportType = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(deviceIdentifier, &address, 0, nil, &size, &transportType)
        var streamsSize = UInt32(0)
        var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                        mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        let hasInput = AudioObjectGetPropertyDataSize(deviceIdentifier, &streamsAddress, 0, nil, &streamsSize) == noErr && streamsSize > 0
        return AudioInputCandidate(deviceIdentifier: deviceIdentifier, transportType: transportType, hasInput: hasInput)
    }

    /// A laptop's microphone is cut off with its lid closed, while macOS
    /// may still list it; the built-in display being on is the sign the
    /// lid is open. A desktop with a built-in microphone (an iMac) has a
    /// built-in display too.
    private static func builtInDisplayIsOn() -> Bool {
        var displayCount = UInt32(0)
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else { return false }
        return displays.contains { CGDisplayIsBuiltin($0) != 0 }
    }
}
