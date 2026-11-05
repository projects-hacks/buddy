//
//  EarlyScreenCapture.swift
//  leanring-buddy
//
//  Captures and reads the screen while the student is still talking, so that
//  after the talk keys are let go only the work that needs their words is
//  left: sorting the question, recalling memory, asking the model.
//
//  Why it is safe to read the screen before the question exists. The screen
//  a spoken question is about is almost always the one in front of the
//  student when they pressed the keys, and the few seconds of talking are
//  dead time. What can go wrong is the screen changing while they talk: a
//  page finishing loading, a scroll, a switch to another app or window. So
//  at release the early capture is checked, cheaply and on the Mac, against
//  the screen as it is now (the app and window in front, the display under
//  the pointer, and a 96 x 60 grey thumbnail as guide mode compares them),
//  and any difference throws it away so the screen is captured again. An
//  answer is never given about a screen that has gone.
//
//  Nothing here leaves memory. A capture that no question claims (a tap of
//  the keys, Control + Option + T, Esc, nothing heard) is dropped.
//

import AppKit
import ApplicationServices
import Foundation

/// A screen captured and read, ready for a question.
struct PreparedScreen {
    let screenCaptures: [CompanionScreenCapture]
    /// The display holding the pointer: its screenshot is the canvas.
    let primaryCapture: CompanionScreenCapture
    /// Built for this capture alone, so a capture that is thrown away leaves
    /// the index the app is using untouched.
    let screenIndex: ScreenIndex
}

@MainActor
final class EarlyScreenCapture {
    /// The app and window in front when the screen was read. A different
    /// one at release means the student moved on while talking.
    private struct FrontWindow: Equatable {
        let processIdentifier: pid_t?
        let windowTitle: String?
        let windowFrame: CGRect?
    }

    /// More cells than a blinking caret or the pointer change, as in guide
    /// mode. A smaller change still counts: a capture thrown away costs a
    /// few hundred milliseconds, an answer about the wrong screen costs the
    /// answer.
    static let changedCellsMeaningTheScreenMoved = 9

    private var captureTask: Task<PreparedScreen?, Never>?
    private var freshnessCheckTask: Task<PreparedScreen?, Never>?
    /// Drops a capture no question claimed, in case the end of listening
    /// was never reported. Longer than the slowest final transcript.
    private var unclaimedCaptureTimeout: Task<Void, Never>?
    private static let unclaimedCaptureTimeoutSeconds: TimeInterval = 10
    private var frontWindowAtCapture: FrontWindow?

    /// Whether a capture is held for the press in progress or just ended.
    var isHoldingCapture: Bool { captureTask != nil }
    /// Whether the keys of the press that owns the held capture are up.
    private(set) var keysWereReleasedForHeldCapture = false

    /// Starts reading the screen for the press that just began. Replaces any
    /// capture an earlier press left unclaimed.
    func start() {
        discard(reason: nil)
        keysWereReleasedForHeldCapture = false
        frontWindowAtCapture = Self.frontWindowNow()
        let startedAt = Date()
        captureTask = Task { @MainActor in
            guard let screenCaptures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(),
                  !screenCaptures.isEmpty, !Task.isCancelled else { return nil }
            let capturedAt = Date()
            // Same choice as a question asked after release: only the display
            // holding the pointer is indexed.
            let primaryCapture = screenCaptures.first(where: { capture in capture.isCursorScreen }) ?? screenCaptures[0]
            let screenIndex = ScreenIndex()
            await screenIndex.rebuild(
                fromScreenshot: primaryCapture.imageData,
                displayIndex: 0,
                displayBoundsInPoints: CGSize(
                    width: primaryCapture.displayWidthInPoints,
                    height: primaryCapture.displayHeightInPoints
                )
            )
            guard !Task.isCancelled else { return nil }
            TutorDebugLog.write("⏱ early screen: captured in \(Self.seconds(capturedAt.timeIntervalSince(startedAt))), read in \(Self.seconds(Date().timeIntervalSince(capturedAt)))")
            return PreparedScreen(screenCaptures: screenCaptures, primaryCapture: primaryCapture, screenIndex: screenIndex)
        }
    }

    /// The keys are up: checks, while the last words are transcribed, that
    /// the screen read early is still the screen in front of the student.
    func keysWereReleased() {
        guard let captureTask, !keysWereReleasedForHeldCapture else { return }
        keysWereReleasedForHeldCapture = true
        let frontWindowAtCapture = frontWindowAtCapture
        let releasedAt = Date()
        freshnessCheckTask = Task { @MainActor in
            guard let prepared = await captureTask.value, !Task.isCancelled else { return nil }
            if let reason = await Self.reasonTheScreenMoved(since: prepared, frontWindowAtCapture: frontWindowAtCapture) {
                TutorDebugLog.write("⏱ early screen not used, \(reason); reading it again")
                return nil
            }
            TutorDebugLog.write("⏱ early screen still current, checked in \(Self.seconds(Date().timeIntervalSince(releasedAt))) after release")
            return prepared
        }
        unclaimedCaptureTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.unclaimedCaptureTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.discard(reason: "no question claimed it")
        }
    }

    /// Gives the held capture to the question that was just heard, and lets
    /// go of it. Nil means there is none to give, or the screen moved, and
    /// the caller captures the screen as before.
    func handOverToQuestion() -> Task<PreparedScreen?, Never>? {
        guard captureTask != nil else { return nil }
        // A question can only follow a release, but the check is started
        // here too in case the release was never seen.
        if !keysWereReleasedForHeldCapture { keysWereReleased() }
        let handedOver = freshnessCheckTask
        unclaimedCaptureTimeout?.cancel()
        unclaimedCaptureTimeout = nil
        captureTask = nil
        freshnessCheckTask = nil
        frontWindowAtCapture = nil
        keysWereReleasedForHeldCapture = false
        return handedOver
    }

    /// Drops the held capture: no question is coming for it.
    func discard(reason: String?) {
        guard captureTask != nil else { return }
        if let reason { TutorDebugLog.write("⏱ early screen dropped: \(reason)") }
        captureTask?.cancel()
        freshnessCheckTask?.cancel()
        unclaimedCaptureTimeout?.cancel()
        unclaimedCaptureTimeout = nil
        captureTask = nil
        freshnessCheckTask = nil
        frontWindowAtCapture = nil
        keysWereReleasedForHeldCapture = false
    }

    // MARK: - Has the screen moved?

    private static func reasonTheScreenMoved(since prepared: PreparedScreen, frontWindowAtCapture: FrontWindow?) async -> String? {
        let pointer = NSEvent.mouseLocation
        if !prepared.primaryCapture.displayFrame.contains(pointer),
           NSScreen.screens.contains(where: { screen in screen.frame.contains(pointer) }) {
            return "the pointer moved to another display"
        }
        if let frontWindowAtCapture {
            let frontWindowNow = frontWindowNow()
            if frontWindowNow.processIdentifier != frontWindowAtCapture.processIdentifier {
                return "another app came to the front"
            }
            if frontWindowNow.windowTitle != frontWindowAtCapture.windowTitle {
                return "the window's title changed"
            }
            if frontWindowNow.windowFrame != frontWindowAtCapture.windowFrame {
                return "the window moved or changed size"
            }
        }
        guard let earlyThumbnail = GuideWatcher.thumbnail(fromImageData: prepared.primaryCapture.imageData),
              let currentThumbnail = await GuideWatcher.captureThumbnail(of: prepared.primaryCapture.displayFrame) else {
            return "the screen could not be compared"
        }
        let (changedCells, _) = GuideWatcher.changes(earlyThumbnail, currentThumbnail)
        if changedCells >= changedCellsMeaningTheScreenMoved {
            return "\(changedCells) of the screen's cells changed"
        }
        return nil
    }

    /// The frontmost app other than Buddy, and its focused window's title
    /// and frame from the accessibility tree.
    private static func frontWindowNow() -> FrontWindow {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return FrontWindow(processIdentifier: nil, windowTitle: nil, windowFrame: nil)
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return FrontWindow(processIdentifier: application.processIdentifier, windowTitle: nil, windowFrame: nil)
        }
        // The force cast is checked by the type id above.
        let window = windowValue as! AXUIElement
        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
        return FrontWindow(
            processIdentifier: application.processIdentifier,
            windowTitle: titleValue as? String,
            windowFrame: WindowFrameReader.frame(of: window)
        )
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.2fs", interval)
    }
}

/// An accessibility element's frame in global, top-left-origin points.
enum WindowFrameReader {
    static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        // The force casts are checked by the type ids above.
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
