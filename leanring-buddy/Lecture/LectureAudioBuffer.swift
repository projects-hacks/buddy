//
//  LectureAudioBuffer.swift
//  leanring-buddy
//
//  Lecture mode's fallback for players with no transcript to read: the
//  last 90 seconds of the sound of the app in front, held in memory, and
//  the newest 65 of them transcribed only when a question is about a
//  lecture (LectureAudioGate).
//
//  How it hears one app and nothing else. Core Audio process taps (macOS
//  14.2) deliver the output of chosen processes, here the app in front and
//  its helper processes (a browser plays sound from a helper), mixed to
//  stereo. Never the microphone, never another app. The tap is private to
//  Buddy and does not mute or change what the student hears.
//
//  When it runs. Only after macOS has been asked for the permission once,
//  and then only while the app in front is playing sound and is not a call,
//  a meeting or a music app. Any app using a microphone counts as a call.
//  The buffer is a fixed ring, so older sound is overwritten continuously;
//  it is emptied whenever the app in front changes or turns into a call,
//  and after ten minutes without sound. Nothing is ever written to disk.
//
//  The permission. A tap needs "System Audio Recording" (Privacy and
//  Security, Screen and System Audio Recording), with the sentence in
//  NSAudioCaptureUsageDescription. macOS has no public call to ask for it
//  or to read whether it was given: the prompt appears the first time a
//  tap starts, and a refused tap simply hears silence. So the prompt is
//  raised once, at the first question where the sound would have helped,
//  and silence is treated as "nothing to add" from then on.
//

import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Speech

/// The newest sound of the app in front, taken when a question is asked.
nonisolated struct LectureAudioSnapshot: Sendable {
    let samples: [Int16]
    let sampleRate: Int
    let applicationName: String

    var durationSeconds: Double { Double(samples.count) / Double(sampleRate) }
}

@MainActor
final class LectureAudioBuffer {
    static let keptSeconds: Double = 90
    /// What is transcribed of it: the minute the note keeps, plus a few
    /// seconds to start that minute at the beginning of a sentence. Only
    /// this much is ever sent, and the cost is counted on it.
    static let transcribedSeconds: Double = 65
    static let sampleRate = 16_000

    /// Set the moment the prompt is first raised, so it is raised once ever.
    static let permissionAskedDefaultsKey = "lectureAudioPermissionAsked"

    private let ringBuffer = LectureAudioRingBuffer(sampleRate: LectureAudioBuffer.sampleRate,
                                                    capacitySeconds: LectureAudioBuffer.keptSeconds)
    /// The same sound recognised on the Mac as it plays.
    let liveTranscript = LectureLiveTranscript()
    private var watchTimer: Timer?
    private var activeTap: LectureProcessTap? {
        didSet {
            let isTapping = activeTap != nil
            if isTapping != (oldValue != nil) { onTappingChanged(isTapping) }
        }
    }
    /// Told when a tap starts or stops, so the notch can show that the
    /// front app's sound is being kept, the way macOS shows the microphone.
    var onTappingChanged: (Bool) -> Void = { _ in }
    /// The app whose sound is in the ring. Any other app in front empties it.
    private var bufferOwnerProcessIdentifier: pid_t?
    private var bufferOwnerName = ""
    private var frontApplicationLastPlayedSoundAt: Date?
    /// Apps whose tap heard only silence while they were playing: video
    /// protected from capture, or a refused permission. Left alone for the
    /// rest of the session rather than tapped over and over for nothing.
    private var processIdentifiersThatStayedSilent: Set<pid_t> = []
    private var lastLoggedSkipReason: String?

    var hasAskedForPermission: Bool { UserDefaults.standard.bool(forKey: Self.permissionAskedDefaultsKey) }

    /// Polls once a second. Reading which processes are playing needs no
    /// permission and costs almost nothing; a tap is started only after the
    /// permission has been asked for.
    func startWatching() {
        guard watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkFrontApplication() }
        }
        listenForOutputDeviceChanges()
    }

    /// The tap's aggregate device is clocked by the output device it was
    /// built on. When that changes (AirPods connect, headphones come out),
    /// the old device stops delivering, yet the tap has already heard sound,
    /// so the silence check would never restart it. A new tap is built on
    /// the new device instead; what is in the ring is kept.
    private func listenForOutputDeviceChanges() {
        var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputDeviceAddress, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in self?.defaultOutputDeviceChanged() }
        }
        if status != noErr {
            TutorDebugLog.write("🎓 lecture: could not watch for output device changes (\(status))")
        }
    }

    private func defaultOutputDeviceChanged() {
        guard activeTap != nil, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == bufferOwnerProcessIdentifier else { return }
        TutorDebugLog.write("🎓 lecture: output device changed, listening again on the new one")
        startTap(on: LectureAudioProcesses.processesBelonging(to: front))
    }

    /// Whether the app in front played sound in the last `seconds`.
    func frontApplicationPlayedSound(withinSeconds seconds: TimeInterval) -> Bool {
        guard let frontApplicationLastPlayedSoundAt else { return false }
        return Date().timeIntervalSince(frontApplicationLastPlayedSoundAt) <= seconds
    }

    /// What the buffer holds, in words, for the log line each lecture
    /// question writes: a question answered without the sound says why.
    func stateForLog() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication else { return "no app in front" }
        guard activeTap != nil else { return "not listening" }
        guard front.processIdentifier == bufferOwnerProcessIdentifier else {
            return "kept for \(bufferOwnerName), not \(front.localizedName ?? "the app in front")"
        }
        let samples = ringBuffer.newestSamples(seconds: Self.transcribedSeconds)
        let seconds = LectureAudioRingBuffer.secondsWithSound(in: samples, sampleRate: Self.sampleRate)
        return "\(Int(seconds))s with sound in the last \(Int(Self.transcribedSeconds))s"
    }

    /// How often the player's time is read while it plays, to place what
    /// is heard on the video's own clock. A read takes about a tenth of a
    /// second off the main thread in Brave.
    static let secondsBetweenPlaybackReadings = 5
    private var playbackReadingInFlight = false

    private func notePlaybackTime(of front: NSRunningApplication) {
        guard !playbackReadingInFlight else { return }
        playbackReadingInFlight = true
        let processIdentifier = front.processIdentifier
        let bundleIdentifier = front.bundleIdentifier
        Task {
            let reading = await Task.detached(priority: .utility) {
                LecturePageReader.readFrontWindow(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier)
            }.value
            playbackReadingInFlight = false
            guard !reading.showsAnAdvert, let position = reading.playbackPosition,
                  let key = LectureVideoPage.key(pageURL: reading.pageURL, windowTitle: reading.windowTitle) else { return }
            liveTranscript.noteAnchor(playbackSeconds: Double(position.currentSeconds), videoKey: key, for: processIdentifier)
        }
    }

    /// What the app in front said before the player's time, as Buddy heard
    /// it playing there, however long ago.
    func liveWords(atPlayback position: LecturePlaybackPosition, videoKey: String) -> (passage: String, secondsCovered: Int)? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return liveTranscript.log(for: front.processIdentifier)
            .passage(endingAtPlayback: Double(position.currentSeconds), videoKey: videoKey)
    }

    /// The last minute Buddy heard the app in front say, for a player whose
    /// time cannot be read. Only within ten minutes of hearing it.
    func lastHeardWords() -> (passage: String, secondsCovered: Int)? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let heard = liveTranscript.log(for: front.processIdentifier).lastHeard(),
              TalkOverListener.now - heard.lastHeardAt <= 600 else { return nil }
        return (heard.passage, heard.secondsCovered)
    }

    /// The buffered sound, if there is enough of it to be worth hearing.
    func snapshotForQuestion() -> LectureAudioSnapshot? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == bufferOwnerProcessIdentifier else { return nil }
        let samples = ringBuffer.newestSamples(seconds: Self.transcribedSeconds)
        // Under three seconds of actual sound is silence, a click, or a
        // tap that heard nothing because the video is protected.
        guard LectureAudioRingBuffer.secondsWithSound(in: samples, sampleRate: Self.sampleRate) >= 3 else { return nil }
        return LectureAudioSnapshot(samples: samples, sampleRate: Self.sampleRate, applicationName: bufferOwnerName)
    }

    /// Raises macOS's permission prompt by starting a tap on the app in
    /// front, once ever. The tap that raises it keeps running if allowed.
    /// Returns whether the prompt could be raised.
    @discardableResult
    func askForPermissionNow() -> Bool {
        guard !hasAskedForPermission, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == bufferOwnerProcessIdentifier else { return false }
        let familyProcesses = LectureAudioProcesses.processesBelonging(to: front)
        guard !familyProcesses.isEmpty, !familyProcesses.contains(where: \.isRunningInput) else { return false }
        UserDefaults.standard.set(true, forKey: Self.permissionAskedDefaultsKey)
        TutorDebugLog.write("🎓 lecture: asking once to hear the sound of the app in front")
        // Started now even if the video is paused, so the prompt appears
        // while the student is asking, not later at a random moment.
        startTap(on: familyProcesses)
        return activeTap != nil
    }

    private func startTap(on familyProcesses: [LectureAudioProcess]) {
        activeTap?.stop()
        let liveTranscript = self.liveTranscript
        activeTap = LectureProcessTap(
            processObjectIdentifiers: Array(Set(familyProcesses.map(\.audioObjectIdentifier))),
            ringBuffer: ringBuffer, targetSampleRate: Double(Self.sampleRate),
            onSamples: { samples in liveTranscript.append(samples) })
        secondsPlayedWhileTapped = 0
        if activeTap != nil, let bufferOwnerProcessIdentifier {
            lastLoggedSkipReason = nil
            liveTranscript.start(for: bufferOwnerProcessIdentifier)
        }
    }

    /// Seconds the app played sound while the current tap was running, for
    /// telling a silent tap from a paused video.
    private var secondsPlayedWhileTapped = 0
    /// How many taps of each app heard only silence. The first may be the
    /// tap that raised the prompt, started before the answer was given, so
    /// it takes two before an app is left alone.
    private var silentTapCountByProcessIdentifier: [pid_t: Int] = [:]

    // MARK: - Watching the app in front

    private func checkFrontApplication() {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            stopTapAndForget(reason: "no app in front")
            return
        }
        // Buddy's own windows (setup, the notch) leave the lecture where it was.
        if front.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        if front.processIdentifier != bufferOwnerProcessIdentifier {
            stopTapAndForget(reason: nil)
            bufferOwnerProcessIdentifier = front.processIdentifier
            bufferOwnerName = front.localizedName ?? "the app"
            frontApplicationLastPlayedSoundAt = nil
        }

        let familyProcesses = LectureAudioProcesses.processesBelonging(to: front)
        let isPlayingSound = familyProcesses.contains(where: \.isRunningOutput)
        if isPlayingSound { frontApplicationLastPlayedSoundAt = Date() }

        // A microphone in use means a call: the other people on it have
        // not agreed to be heard.
        if familyProcesses.contains(where: \.isRunningInput) {
            stopTapAndForget(reason: "\(bufferOwnerName) is using a microphone, treated as a call")
            return
        }
        // The title matters only for telling a meeting tab apart, and only
        // while something plays; reading it costs a message to the app, so
        // idle seconds make none.
        let windowTitle = isPlayingSound ? LecturePageReader.focusedWindowTitle(processIdentifier: front.processIdentifier) : nil
        if let exclusionReason = LectureCaptureExclusions.reasonToExclude(
            bundleIdentifier: front.bundleIdentifier, applicationName: front.localizedName,
            windowTitle: windowTitle, pageURL: nil) {
            stopTapAndForget(reason: "\(bufferOwnerName) is \(exclusionReason)")
            return
        }

        guard hasAskedForPermission, !processIdentifiersThatStayedSilent.contains(front.processIdentifier) else { return }

        if isPlayingSound {
            let playingObjectIdentifiers = Set(familyProcesses.filter(\.isRunningOutput).map(\.audioObjectIdentifier))
            guard let activeTap, playingObjectIdentifiers.isSubset(of: activeTap.tappedObjectIdentifiers) else {
                // Nothing tapped yet, or a helper started playing that the
                // tap does not cover.
                startTap(on: familyProcesses)
                return
            }
            secondsPlayedWhileTapped += 1
            if secondsPlayedWhileTapped % Self.secondsBetweenPlaybackReadings == 1 {
                notePlaybackTime(of: front)
            }
            // Twenty seconds of playing that reached the tap as pure
            // silence: protected video, or the permission was refused.
            if !activeTap.hasHeardSound, secondsPlayedWhileTapped > 20 {
                let silentTapCount = (silentTapCountByProcessIdentifier[front.processIdentifier] ?? 0) + 1
                silentTapCountByProcessIdentifier[front.processIdentifier] = silentTapCount
                if silentTapCount >= 2 {
                    processIdentifiersThatStayedSilent.insert(front.processIdentifier)
                    TutorDebugLog.write("🎓 lecture: \(bufferOwnerName)'s sound reaches Buddy as silence (protected, or permission not given); not tapping it again this session")
                    stopTapAndForget(reason: nil)
                } else {
                    startTap(on: familyProcesses)
                }
            }
            return
        }

        if let activeTap {
            // Paused: stop listening a few seconds later, keep what was heard.
            let secondsSincePlayed = frontApplicationLastPlayedSoundAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if secondsSincePlayed > 4, Date().timeIntervalSince(activeTap.startedAt) > 4 {
                activeTap.stop()
                self.activeTap = nil
                liveTranscript.stop()
            }
        } else if let frontApplicationLastPlayedSoundAt, Date().timeIntervalSince(frontApplicationLastPlayedSoundAt) > 600 {
            ringBuffer.removeAll()
        }
    }

    private func stopTapAndForget(reason: String?) {
        activeTap?.stop()
        activeTap = nil
        ringBuffer.removeAll()
        // The words stay with the app they came from, for when it is back
        // in front; only the sound is emptied.
        liveTranscript.stop()
        if let reason, reason != lastLoggedSkipReason {
            TutorDebugLog.write("🎓 lecture: not listening, \(reason)")
            lastLoggedSkipReason = reason
        }
    }
}

// MARK: - Which processes are the app in front

/// One process Core Audio knows about, with whether it is playing or
/// recording right now. Reading this list needs no permission.
nonisolated struct LectureAudioProcess: Sendable {
    let audioObjectIdentifier: AudioObjectID
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let isRunningOutput: Bool
    let isRunningInput: Bool
}

nonisolated enum LectureAudioProcesses {
    /// WebKit plays a page's sound from a shared GPU process whose parent is
    /// launchd, not the browser, so it is matched by name for WebKit browsers.
    private static let webKitBrowserBundleIdentifiers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS"
    ]

    static func processesBelonging(to application: NSRunningApplication) -> [LectureAudioProcess] {
        let frontProcessIdentifier = application.processIdentifier
        let frontBundleIdentifier = application.bundleIdentifier ?? ""
        let usesWebKitGPUProcess = webKitBrowserBundleIdentifiers.contains(frontBundleIdentifier)
        return allAudioProcesses().filter { process in
            if process.processIdentifier == frontProcessIdentifier { return true }
            if !frontBundleIdentifier.isEmpty, process.bundleIdentifier.hasPrefix(frontBundleIdentifier + ".") { return true }
            if parentProcessIdentifier(of: process.processIdentifier) == frontProcessIdentifier { return true }
            if usesWebKitGPUProcess, process.bundleIdentifier == "com.apple.WebKit.GPU" { return true }
            return false
        }
    }

    private static func allAudioProcesses() -> [LectureAudioProcess] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        var objectIdentifiers = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize,
                                         &objectIdentifiers) == noErr else { return [] }
        return objectIdentifiers.compactMap { objectIdentifier in
            guard let processIdentifier: pid_t = readProperty(kAudioProcessPropertyPID, of: objectIdentifier) else { return nil }
            let isRunningOutput: UInt32 = readProperty(kAudioProcessPropertyIsRunningOutput, of: objectIdentifier) ?? 0
            let isRunningInput: UInt32 = readProperty(kAudioProcessPropertyIsRunningInput, of: objectIdentifier) ?? 0
            return LectureAudioProcess(audioObjectIdentifier: objectIdentifier, processIdentifier: processIdentifier,
                                       bundleIdentifier: readStringProperty(kAudioProcessPropertyBundleID, of: objectIdentifier) ?? "",
                                       isRunningOutput: isRunningOutput != 0, isRunningInput: isRunningInput != 0)
        }
    }

    private static func readProperty<Value>(_ selector: AudioObjectPropertySelector, of objectIdentifier: AudioObjectID) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var dataSize = UInt32(MemoryLayout<Value>.size)
        let valuePointer = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { valuePointer.deallocate() }
        guard AudioObjectGetPropertyData(objectIdentifier, &address, 0, nil, &dataSize, valuePointer) == noErr else { return nil }
        return valuePointer.pointee
    }

    static func readStringProperty(_ selector: AudioObjectPropertySelector, of objectIdentifier: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var stringValue: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(objectIdentifier, &address, 0, nil, &dataSize, &stringValue) == noErr,
              let stringValue else { return nil }
        // Core Audio hands over a retained string.
        return stringValue.takeRetainedValue() as String
    }

    private static func parentProcessIdentifier(of processIdentifier: pid_t) -> pid_t? {
        var processInfo = kinfo_proc()
        var infoSize = MemoryLayout<kinfo_proc>.stride
        var managementInfoBase: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        guard sysctl(&managementInfoBase, 4, &processInfo, &infoSize, nil, 0) == 0, infoSize > 0 else { return nil }
        return processInfo.kp_eproc.e_ppid
    }
}

// MARK: - The tap

/// One running process tap, from creation to teardown. Its sound goes
/// straight into the ring as 16 kHz mono and nowhere else.
nonisolated final class LectureProcessTap {
    let tappedObjectIdentifiers: Set<AudioObjectID>
    let startedAt = Date()

    private var tapObjectIdentifier = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceIdentifier = AudioObjectID(kAudioObjectUnknown)
    private var ioProcIdentifier: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "buddy.lecture-tap", qos: .userInitiated)
    private let heardSoundLock = NSLock()
    private var heardSound = false

    var hasHeardSound: Bool {
        heardSoundLock.lock(); defer { heardSoundLock.unlock() }
        return heardSound
    }

    init?(processObjectIdentifiers: [AudioObjectID], ringBuffer: LectureAudioRingBuffer, targetSampleRate: Double,
          onSamples: (@Sendable ([Int16]) -> Void)? = nil) {
        tappedObjectIdentifiers = Set(processObjectIdentifiers)
        guard !processObjectIdentifiers.isEmpty else { return nil }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIdentifiers)
        tapDescription.uuid = UUID()
        tapDescription.name = "Buddy lecture sound"
        // Private: no other app sees this tap. Unmuted: the student keeps
        // hearing the video exactly as before.
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var createdTapIdentifier = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &createdTapIdentifier)
        guard status == noErr else {
            TutorDebugLog.write("🎓 lecture: could not create the process tap (\(status))")
            return nil
        }
        tapObjectIdentifier = createdTapIdentifier

        var tapFormatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
        var tapStreamDescription = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapObjectIdentifier, &tapFormatAddress, 0, nil, &formatSize, &tapStreamDescription)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &tapStreamDescription) else {
            TutorDebugLog.write("🎓 lecture: could not read the tap's format (\(status))")
            tearDown()
            return nil
        }

        // A tap is read through a private aggregate device built around it,
        // clocked by the current output device.
        guard let outputDeviceUID = Self.defaultOutputDeviceUID() else {
            tearDown()
            return nil
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Buddy lecture sound",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: tapDescription.uuid.uuidString]]
        ]
        var createdAggregateIdentifier = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregateIdentifier)
        guard status == noErr else {
            TutorDebugLog.write("🎓 lecture: could not create the aggregate device (\(status))")
            tearDown()
            return nil
        }
        aggregateDeviceIdentifier = createdAggregateIdentifier

        let downsampler = LectureAudioDownsampler(sourceSampleRate: tapFormat.sampleRate, targetSampleRate: targetSampleRate)
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcIdentifier, aggregateDeviceIdentifier, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            // The buffer list is only valid during this call, so the sound
            // is mixed down and copied into the ring before returning.
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil),
                  let monoSamples = Self.monoSamples(from: pcmBuffer), !monoSamples.isEmpty else { return }
            if let self, monoSamples.contains(where: { $0 != 0 }) {
                self.heardSoundLock.lock(); self.heardSound = true; self.heardSoundLock.unlock()
            }
            let downsampled = downsampler.downsample(monoSamples)
            ringBuffer.append(downsampled)
            onSamples?(downsampled)
        }
        guard status == noErr else {
            TutorDebugLog.write("🎓 lecture: could not attach to the tap (\(status))")
            tearDown()
            return nil
        }
        // The first start is what raises the permission prompt.
        status = AudioDeviceStart(aggregateDeviceIdentifier, ioProcIdentifier)
        guard status == noErr else {
            TutorDebugLog.write("🎓 lecture: could not start listening (\(status))")
            tearDown()
            return nil
        }
        TutorDebugLog.write("🎓 lecture: listening to the app in front (\(processObjectIdentifiers.count) processes)")
    }

    func stop() { tearDown() }

    deinit { tearDown() }

    private func tearDown() {
        if aggregateDeviceIdentifier != kAudioObjectUnknown {
            if let ioProcIdentifier {
                AudioDeviceStop(aggregateDeviceIdentifier, ioProcIdentifier)
                AudioDeviceDestroyIOProcID(aggregateDeviceIdentifier, ioProcIdentifier)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceIdentifier)
            aggregateDeviceIdentifier = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcIdentifier = nil
        if tapObjectIdentifier != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectIdentifier)
            tapObjectIdentifier = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Averages the channels into one, whether the tap's format keeps
    /// channels apart or interleaved.
    private static func monoSamples(from pcmBuffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = pcmBuffer.floatChannelData else { return nil }
        let frameCount = Int(pcmBuffer.frameLength)
        let channelCount = Int(pcmBuffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }
        var monoSamples = [Float](repeating: 0, count: frameCount)
        if pcmBuffer.format.isInterleaved {
            let interleavedSamples = channelData[0]
            for frameIndex in 0..<frameCount {
                var sum: Float = 0
                for channelIndex in 0..<channelCount { sum += interleavedSamples[frameIndex * channelCount + channelIndex] }
                monoSamples[frameIndex] = sum / Float(channelCount)
            }
        } else {
            for channelIndex in 0..<channelCount {
                let channelSamples = channelData[channelIndex]
                for frameIndex in 0..<frameCount { monoSamples[frameIndex] += channelSamples[frameIndex] / Float(channelCount) }
            }
        }
        return monoSamples
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var outputDeviceIdentifier = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize,
                                         &outputDeviceIdentifier) == noErr else { return nil }
        return LectureAudioProcesses.readStringProperty(kAudioDevicePropertyDeviceUID, of: outputDeviceIdentifier)
    }
}

// MARK: - Transcribing the buffer

/// The lecture's words heard from the buffer.
nonisolated struct LectureHeardWords: Sendable {
    let passage: String
    let secondsCovered: Int
    let heardBy: String
}

nonisolated enum LectureAudioTranscriber {
    /// Published Nova-3 price per minute of audio, rounded up to the
    /// streaming rate so the meter overstates rather than hides.
    static let deepgramDollarsPerMinute = 0.0077

    /// Deepgram when a key is set, Apple's on-device recognizer otherwise
    /// or when Deepgram fails. Nil when neither hears any words.
    static func transcribe(_ snapshot: LectureAudioSnapshot) async -> LectureHeardWords? {
        // The key store and its cache belong to the main actor.
        if let deepgramKey = await MainActor.run(body: { APIKeyStore.key(for: .deepgram) }) {
            if let heardWords = await transcribeWithDeepgram(snapshot, apiKey: deepgramKey) { return heardWords }
        }
        return await transcribeWithAppleSpeech(snapshot)
    }

    private static func transcribeWithDeepgram(_ snapshot: LectureAudioSnapshot, apiKey: String) async -> LectureHeardWords? {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "smart_format", value: "true"),
            // Lectures come in many languages; the student's dictation
            // settings say nothing about the lecturer's.
            URLQueryItem(name: "detect_language", value: "true")
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let pcmData = snapshot.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        request.httpBody = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: pcmData, sampleRate: snapshot.sampleRate)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                TutorDebugLog.write("🎓 lecture: Deepgram answered \(statusCode), trying Apple Speech")
                return nil
            }
            SpendingMeter.record(snapshot.durationSeconds / 60 * deepgramDollarsPerMinute, for: .deepgram, purpose: .lectures)
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let results = root["results"] as? [String: Any],
                  let channels = results["channels"] as? [[String: Any]],
                  let alternatives = channels.first?["alternatives"] as? [[String: Any]],
                  let words = alternatives.first?["words"] as? [[String: Any]] else { return nil }
            let timedWords: [(word: String, startSeconds: Double)] = words.compactMap { word in
                guard let text = (word["punctuated_word"] as? String) ?? (word["word"] as? String),
                      let start = (word["start"] as? NSNumber)?.doubleValue else { return nil }
                return (text, start)
            }
            let passage = LectureTranscriptWindow.lastMinute(ofTimedWords: timedWords, audioDurationSeconds: snapshot.durationSeconds)
            guard !passage.isEmpty else { return nil }
            return LectureHeardWords(passage: passage, secondsCovered: Int(min(snapshot.durationSeconds, 60)), heardBy: "Deepgram")
        } catch {
            TutorDebugLog.write("🎓 lecture: Deepgram failed (\(error.localizedDescription)), trying Apple Speech")
            return nil
        }
    }

    private static func transcribeWithAppleSpeech(_ snapshot: LectureAudioSnapshot) async -> LectureHeardWords? {
        // Asked for by dictation already; lecture mode never raises a
        // second prompt for it.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { return nil }

        // Recognition on Apple's servers stops at one minute of audio.
        let isOnDevice = recognizer.supportsOnDeviceRecognition
        let samples = isOnDevice ? snapshot.samples : Array(snapshot.samples.suffix(snapshot.sampleRate * 58))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(snapshot.sampleRate),
                                         channels: 1, interleaved: false),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = pcmBuffer.floatChannelData else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        for sampleIndex in samples.indices { channelData[0][sampleIndex] = Float(samples[sampleIndex]) / Float(Int16.max) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = isOnDevice
        request.addsPunctuation = true
        request.append(pcmBuffer)
        request.endAudio()

        let durationSeconds = Double(samples.count) / Double(snapshot.sampleRate)
        let timedWords: [(word: String, startSeconds: Double)] = await withCheckedContinuation { continuation in
            let resumeOnce = LectureResumeOnce()
            var recognitionTask: SFSpeechRecognitionTask?
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let words = result.bestTranscription.segments.map { ($0.substring, $0.timestamp) }
                    if resumeOnce.claim() { continuation.resume(returning: words) }
                } else if error != nil {
                    if resumeOnce.claim() { continuation.resume(returning: []) }
                }
            }
            // On-device recognition of 90 seconds takes a few seconds; the
            // question does not wait longer than lecture mode allows anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if resumeOnce.claim() {
                    recognitionTask?.cancel()
                    continuation.resume(returning: [])
                }
            }
        }
        let passage = LectureTranscriptWindow.lastMinute(ofTimedWords: timedWords, audioDurationSeconds: durationSeconds)
        guard !passage.isEmpty else { return nil }
        return LectureHeardWords(passage: passage, secondsCovered: Int(min(durationSeconds, 60)), heardBy: "the Mac")
    }
}

/// Lets exactly one of several callbacks resume a continuation.
nonisolated final class LectureResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isClaimed { return false }
        isClaimed = true
        return true
    }
}
