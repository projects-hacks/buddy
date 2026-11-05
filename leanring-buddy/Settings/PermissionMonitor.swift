//
//  PermissionMonitor.swift
//  leanring-buddy
//
//  The four permissions Buddy needs (accessibility, screen recording,
//  microphone, screen content), read again every 1.5 seconds so the notch
//  and setup update as soon as one is granted in System Settings. The same
//  timer drives the companion's other periodic work through `onPoll`.
//

import AVFoundation
import AppKit
import Combine
import Foundation
import ScreenCaptureKit

@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, the grant is kept so
    /// it is never asked for again.
    @Published private(set) var isRequestingScreenContent = false

    /// Told whether accessibility is granted after every check, because the
    /// talk keys' event tap can only run while it is.
    var onAccessibilityChecked: (_ isGranted: Bool) -> Void = { _ in }
    /// The screen content picker was approved.
    var onScreenContentGranted: () -> Void = {}
    /// Run on every tick after the permissions are read. The flag is true on
    /// every eighth tick, the rate at which the brain may be probed.
    var onPoll: (_ shouldProbeModelServer: Bool) async -> Void = { _ in }

    private var pollTimer: Timer?

    /// True when all required permissions are granted. Used by the panel to
    /// show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    func refresh() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility
        onAccessibilityChecked(currentlyHasAccessibility)

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            TutorDebugLog.write("🔑 accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted, once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }
    }

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content, a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result, width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    onScreenContentGranted()
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception,
    /// macOS requires an app restart for that one to take effect.
    func startPolling() {
        var tickCount = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            tickCount += 1
            let shouldProbeModelServer = tickCount % 8 == 0

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                await self.onPoll(shouldProbeModelServer)
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
