//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        TutorDebugLog.beginSession()
        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        // No menu bar icon: everything lives in the notch, settings included,
        // so there is one place to look instead of two.
        companionManager.start()
        companionManager.keepSettingsOpenWhileSetupIsNeeded()
        registerAsLoginItemIfNeeded()
    }

    /// Clicking Buddy in the Dock opens the notch, its only window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        companionManager.openNotchBriefly(on: .lesson)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        // Registered once from a build folder, the login item would go on
        // starting that copy. When this is a different copy, the one in
        // Applications, the registration is renewed so login starts it.
        let registeredPathKey = "loginItemRegisteredBundlePath"
        let registeredPath = UserDefaults.standard.string(forKey: registeredPathKey)
        if loginItemService.status == .enabled, registeredPath != Bundle.main.bundlePath {
            try? loginItemService.unregister()
        }
        defer {
            if loginItemService.status == .enabled {
                UserDefaults.standard.set(Bundle.main.bundlePath, forKey: registeredPathKey)
            }
        }
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        }
    }

}
