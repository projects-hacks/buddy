//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window, just an
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
        print("🎯 Buddy: Starting...")
        print("🎯 Buddy: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        TutorDebugLog.beginSession()
        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        // No menu bar icon: everything lives in the notch, settings included,
        // so there is one place to look instead of two.
        companionManager.start()
        // Lecture mode hook: watches which app is in front and whether it plays sound.
        LectureMode.shared.startWatching()
        companionManager.updateNotchNeeds()
        registerAsLoginItemIfNeeded()
    }

    /// Clicking Buddy in the Dock opens the notch, its only window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        companionManager.openNotchBriefly(on: .lesson)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
        SpendingMeter.shared.saveNow()
    }

    /// Keeps the login item matching the student's choice. Nothing is
    /// registered until they have chosen in setup, or in Settings: an app
    /// that adds itself to login items on first launch, unasked, is the kind
    /// of surprise people uninstall over.
    private func registerAsLoginItemIfNeeded() {
        LoginItem.applyChoice()
    }
}

/// Opening Buddy at login, as the student chose it.
enum LoginItem {
    static let choiceDefaultsKey = "openAtLogin"

    /// The choice, or for an install from before the choice existed, whether
    /// it was already registered (those installs keep what they had).
    static var isChosen: Bool {
        if let chosen = UserDefaults.standard.object(forKey: choiceDefaultsKey) as? Bool { return chosen }
        return SMAppService.mainApp.status == .enabled
    }

    static func setChosen(_ chosen: Bool) {
        UserDefaults.standard.set(chosen, forKey: choiceDefaultsKey)
        applyChoice()
    }

    static func applyChoice() {
        let service = SMAppService.mainApp
        // An install from before the choice existed, already starting at
        // login: that counts as having said yes, and is saved as such, so a
        // copy launched from elsewhere (an update, a build) moves the login
        // item to itself instead of dropping it.
        if UserDefaults.standard.object(forKey: choiceDefaultsKey) == nil, service.status == .enabled {
            UserDefaults.standard.set(true, forKey: choiceDefaultsKey)
        }
        let hasChosen = UserDefaults.standard.object(forKey: choiceDefaultsKey) != nil
        // Registered once from a build folder, the login item would go on
        // starting that copy; a different copy renews it.
        let registeredPathKey = "loginItemRegisteredBundlePath"
        let registeredPath = UserDefaults.standard.string(forKey: registeredPathKey)
        if service.status == .enabled, registeredPath != Bundle.main.bundlePath || (hasChosen && !isChosen) {
            try? service.unregister()
        }
        defer { TutorDebugLog.write("🔌 open at login: \(hasChosen ? (isChosen ? "chosen" : "declined") : "not chosen yet"), registered=\(service.status == .enabled)") }
        guard hasChosen, isChosen, service.status != .enabled else { return }
        do {
            try service.register()
            UserDefaults.standard.set(Bundle.main.bundlePath, forKey: registeredPathKey)
        } catch {
            TutorDebugLog.write("⚠️ could not add Buddy to login items: \(error.localizedDescription)")
        }
    }
}
