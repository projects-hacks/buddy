//
//  CompanionManager+Permissions.swift
//  leanring-buddy
//
//  The four permissions Buddy needs, polled so the notch and setup
//  update as soon as one is granted, and the debug-only file triggers
//  that share the same timer.
//

import AVFoundation
import AppKit
import Foundation
import ScreenCaptureKit

extension CompanionManager {
    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

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

                    // Show the cursor overlay now that every permission is granted
                    if allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception , 
    /// macOS requires an app restart for that one to take effect.
    func startPermissionPolling() {
        var tickCount = 0
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            tickCount += 1
            let shouldProbeModelServer = tickCount % 8 == 0

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshAllPermissions()

                // Re-probe far less often than permissions. This exists so the
                // "Ollama is not running" warning clears on its own once the
                // user starts it, instead of needing an app restart.
                self.updateNotchNeeds()

                // Test triggers read from files in ~/Library/Logs. Debug builds
                // only: any program on the Mac can write those files, and one
                // of them makes Buddy capture the screen and send it to a model.
                #if DEBUG
                if FileManager.default.fileExists(atPath: CalibrationSnapshot.triggerURL.path) {
                    try? FileManager.default.removeItem(at: CalibrationSnapshot.triggerURL)
                    await self.runCalibration()
                }

                if let tabName = try? String(contentsOf: CalibrationSnapshot.openNotchURL, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: CalibrationSnapshot.openNotchURL)
                    switch tabName.trimmingCharacters(in: .whitespacesAndNewlines) {
                    case "transcript": self.openNotchBriefly(on: .transcript)
                    case "settings": self.openNotchBriefly(on: .settings)
                    default: self.openNotchBriefly(on: .lesson)
                    }
                }

                // A question in this file is asked as if spoken, so the whole
                // pipeline can be checked from a terminal: capture, model,
                // voice, drawing.
                if let question = try? String(contentsOf: CalibrationSnapshot.askURL, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: CalibrationSnapshot.askURL)
                    let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedQuestion.isEmpty {
                        TutorDebugLog.write("🧪 asked from file")
                        self.sendTranscriptToTutorWithScreenshot(transcript: trimmedQuestion)
                    }
                }

                // A picture of the screen with whatever is drawn on it, to
                // check a drawing by looking at it.
                if FileManager.default.fileExists(atPath: CalibrationSnapshot.snapshotTriggerURL.path) {
                    try? FileManager.default.removeItem(at: CalibrationSnapshot.snapshotTriggerURL)
                    do {
                        try await CalibrationSnapshot.captureIncludingOverlay()
                        TutorDebugLog.write("📸 snapshot saved")
                    } catch {
                        TutorDebugLog.write("⚠️ snapshot failed: \(error.localizedDescription)")
                    }
                }

                #endif

                // Only until the brain is known to answer: probing a reachable
                // brain all day costs a request every twelve seconds (a real
                // model listing for an AI Studio key). A failed answer marks
                // it unreachable, and waking re-probes, which starts this again.
                // Never two probes at once, however slow one is.
                let brainNeedsProbing = !self.isLocalModelReachable || self.brainKindKnownReachable != self.brainKind
                if shouldProbeModelServer, brainNeedsProbing, !self.isProbingBrain {
                    self.isProbingBrain = true
                    defer { self.isProbingBrain = false }
                    let brainKindProbed = self.brainKind
                    let (isReachable, _) = await self.tutorBrain.probeServer()
                    self.brainKindKnownReachable = isReachable ? brainKindProbed : nil
                    if isReachable != self.isLocalModelReachable {
                        self.isLocalModelReachable = isReachable
                        if isReachable {
                            print("🦙 Ollama came back, preloading \(self.selectedModel)")
                            await self.tutorBrain.preloadModel()
                        }
                    }
                }
            }
        }
    }
}
