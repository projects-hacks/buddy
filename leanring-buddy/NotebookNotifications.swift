//
//  NotebookNotifications.swift
//  leanring-buddy
//
//  Saying a PDF export is done, and the notch's notice of it when
//  notifications are off. (The notch's way into the Notebook is the
//  Notebook button in its tab row, TutorControlBar.swift.)
//
//  An export runs in the background, so it ends with a macOS notification
//  that has an Open PDF action. Permission is asked for once, when the first
//  export starts (the moment the student can see why it is wanted), never at
//  launch. If notifications are refused, or turned off later in System
//  Settings, the result is shown in the notch instead: the notch opens
//  briefly with the file's name and an Open button.
//

import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class NotebookExportNotifier: NSObject, ObservableObject {
    static let shared = NotebookExportNotifier()

    nonisolated private static let categoryIdentifier = "notebook-export"
    nonisolated private static let openActionIdentifier = "open-pdf"
    nonisolated private static let pdfPathKey = "pdfPath"

    /// The last export's result, shown in the notch when there is no
    /// notification to show it in.
    struct NotchNotice: Equatable {
        let message: String
        let pdfURL: URL?
    }
    @Published var notchNotice: NotchNotice?

    private var openNotch: () -> Void = {}
    private var noticeDismissalTask: Task<Void, Never>?
    private var isConnected = false

    func connect(openNotch: @escaping () -> Void) {
        self.openNotch = openNotch
        guard !isConnected else { return }
        isConnected = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let openAction = UNNotificationAction(identifier: Self.openActionIdentifier, title: "Open PDF", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [openAction], intentIdentifiers: [])
        ])
    }

    /// Called as an export starts: asks for permission the first time only.
    func prepareForExport() {
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func announceFinishedExport(pdfURL: URL, lessonCount: Int, pageCount: Int) {
        let lessonsText = lessonCount == 1 ? "1 lesson" : "\(lessonCount) lessons"
        let pagesText = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        let body = "\(pdfURL.lastPathComponent): \(lessonsText), \(pagesText)."
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let canNotify = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            guard canNotify, settings.alertSetting != .disabled else {
                showInNotch(NotchNotice(message: "Notes exported. \(body)", pdfURL: pdfURL))
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Your notes are ready"
            content.body = body
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [Self.pdfPathKey: pdfURL.path]
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                showInNotch(NotchNotice(message: "Notes exported. \(body)", pdfURL: pdfURL))
            }
        }
    }

    func announceFailedExport(_ message: String) {
        showInNotch(NotchNotice(message: "The PDF was not made. \(message)", pdfURL: nil))
    }

    private func showInNotch(_ notice: NotchNotice) {
        notchNotice = notice
        openNotch()
        noticeDismissalTask?.cancel()
        // Long enough to come back to after looking away; not forever.
        noticeDismissalTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled else { return }
            self.notchNotice = nil
        }
    }

    func openNoticePDF() {
        if let pdfURL = notchNotice?.pdfURL { NSWorkspace.shared.open(pdfURL) }
        notchNotice = nil
    }
}

extension NotebookExportNotifier: UNUserNotificationCenterDelegate {
    /// Buddy counts as the app in use while it runs, so without this the
    /// banner would be swallowed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Open PDF, or a click on the notification itself, opens the file.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let opensFile = response.actionIdentifier == Self.openActionIdentifier
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        if opensFile, let path = userInfo[Self.pdfPathKey] as? String {
            let pdfURL = URL(fileURLWithPath: path)
            DispatchQueue.main.async { NSWorkspace.shared.open(pdfURL) }
        }
        completionHandler()
    }
}

// MARK: - In the notch

/// An export's result, when there is no notification to carry it.
struct NotebookNotchExportNotice: View {
    @ObservedObject private var notifier = NotebookExportNotifier.shared
    @State private var isHoveringOpen = false

    var body: some View {
        if let notice = notifier.notchNotice {
            HStack(spacing: 10) {
                Image(systemName: notice.pdfURL == nil ? "exclamationmark.triangle" : "doc.richtext")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.5, green: 0.75, blue: 1.0))
                Text(notice.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if notice.pdfURL != nil {
                    Button(action: { notifier.openNoticePDF() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 10, weight: .bold))
                            Text("Open")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(isHoveringOpen ? 0.2 : 0.1)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .onHover { hovering in isHoveringOpen = hovering }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.blue.opacity(0.2)))
            .padding(.horizontal, 18)
        }
    }
}
