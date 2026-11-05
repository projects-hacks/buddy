//
//  SystemEventsObserver.swift
//  leanring-buddy
//
//  Sleep, wake and display changes, in one place. Sleep drops every
//  network stream and usually stops the audio engines; a display plugged
//  in or removed leaves windows sized for screens that are not there. Each
//  is handed to CompanionManager, which knows what to stop and rebuild.
//

import AppKit

@MainActor
final class SystemEventsObserver {
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(willSleep: @escaping @MainActor () -> Void,
         didWake: @escaping @MainActor () -> Void,
         screensChanged: @escaping @MainActor () -> Void) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observe(workspaceCenter, NSWorkspace.willSleepNotification, willSleep)
        observe(workspaceCenter, NSWorkspace.didWakeNotification, didWake)
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, screensChanged)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        observers.append((center, token))
    }

    func stopObserving() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
    }
}
