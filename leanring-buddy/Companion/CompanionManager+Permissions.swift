//
//  CompanionManager+Permissions.swift
//  leanring-buddy
//
//  The permissions as the views read them, from PermissionMonitor, and the
//  periodic work that shares its timer: the notch's needs, the debug-only
//  file triggers and the brain probe.
//

import AppKit
import Combine
import Foundation

extension CompanionManager {
    var hasAccessibilityPermission: Bool { permissionMonitor.hasAccessibilityPermission }
    var hasScreenRecordingPermission: Bool { permissionMonitor.hasScreenRecordingPermission }
    var hasMicrophonePermission: Bool { permissionMonitor.hasMicrophonePermission }
    var hasScreenContentPermission: Bool { permissionMonitor.hasScreenContentPermission }
    var isRequestingScreenContent: Bool { permissionMonitor.isRequestingScreenContent }
    var allPermissionsGranted: Bool { permissionMonitor.allPermissionsGranted }

    func refreshAllPermissions() { permissionMonitor.refresh() }
    func requestScreenContentPermission() { permissionMonitor.requestScreenContentPermission() }

    /// Connects the monitor once, before its first check: the views observe
    /// the manager, so every change to a permission is passed on as a change
    /// of the manager's.
    func connectPermissionMonitor() {
        permissionMonitorCancellable = permissionMonitor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        permissionMonitor.onAccessibilityChecked = { [weak self] isGranted in
            guard let self else { return }
            if isGranted {
                self.globalPushToTalkShortcutMonitor.start()
            } else {
                self.globalPushToTalkShortcutMonitor.stop()
            }
        }
        permissionMonitor.onScreenContentGranted = { [weak self] in
            guard let self else { return }
            // Show the cursor overlay now that every permission is granted
            if self.allPermissionsGranted && !self.isOverlayVisible && self.isClickyCursorEnabled {
                self.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                self.isOverlayVisible = true
            }
        }
        permissionMonitor.onPoll = { [weak self] shouldProbeModelServer in
            await self?.periodicCheck(shouldProbeModelServer: shouldProbeModelServer)
        }
    }

    /// Every 1.5 seconds, after the permissions are read.
    private func periodicCheck(shouldProbeModelServer: Bool) async {
        // Re-probe far less often than permissions. This exists so the
        // "Ollama is not running" warning clears on its own once the
        // user starts it, instead of needing an app restart.
        updateNotchNeeds()

        #if DEBUG
        await runDebugFileTriggers()
        #endif

        // Only until the brain is known to answer: probing a reachable
        // brain all day costs a request every twelve seconds (a real
        // model listing for an AI Studio key). A failed answer marks
        // it unreachable, and waking re-probes, which starts this again.
        // Never two probes at once, however slow one is.
        let brainNeedsProbing = !isLocalModelReachable || brainKindKnownReachable != brainKind
        if shouldProbeModelServer, brainNeedsProbing, !isProbingBrain {
            isProbingBrain = true
            defer { isProbingBrain = false }
            let brainKindProbed = brainKind
            let (isReachable, _) = await tutorBrain.probeServer()
            brainKindKnownReachable = isReachable ? brainKindProbed : nil
            if isReachable != isLocalModelReachable {
                isLocalModelReachable = isReachable
                if isReachable {
                    print("🦙 Ollama came back, preloading \(selectedModel)")
                    await tutorBrain.preloadModel()
                }
            }
        }
    }
}
