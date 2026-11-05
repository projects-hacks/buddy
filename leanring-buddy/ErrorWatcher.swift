//
//  ErrorWatcher.swift
//  leanring-buddy
//
//  Notices an error appearing in front of the student, entirely on the Mac:
//  no model, no network, no tokens. ErrorOffer.swift decides whether to
//  offer it; this file only finds it.
//
//  Event driven, so it costs nothing while nothing happens. It listens only
//  while a terminal, an editor, Xcode, or a browser on a judge's page is in
//  front, and then only for what makes output appear: Return in a terminal,
//  a run, build or test shortcut or a click in an editor, Command + Return
//  or a click on a judge's page. After one of those it waits for the window
//  to change and then to hold still for 600 ms, the way output settles, and
//  reads only that window: through its accessibility text where the app
//  exposes one (Terminal, iTerm2), otherwise with text recognition on just
//  the rows that changed. At most one read every 3 seconds.
//
//  Old output never counts. The accessibility path reads only what was
//  printed after Return went down; the recognition path reads only the rows
//  that changed; a scroll during the wait abandons it, since scrolling back
//  through history is not something happening now.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// An error just found on screen, with where its important lines are.
struct DetectedScreenError {
    let recognized: RecognizedError
    /// The lines that were read, top to bottom.
    let lines: [String]
    /// Where the message, cause and code lines are, in global screen points
    /// with the origin at the top left of the main display, when known.
    let rectsInGlobalTopLeftPoints: [Int: CGRect]
    let applicationName: String
    let place: ErrorReadingPlace

    var messageText: String { lines[recognized.messageLineIndex].trimmingCharacters(in: .whitespaces) }
    var causeText: String? { recognized.causeLineIndex.map { lines[$0].trimmingCharacters(in: .whitespaces) } }
    var causeCodeText: String? { recognized.causeCodeLineIndex.map { lines[$0].trimmingCharacters(in: .whitespaces) } }
}

/// The kinds of app an error can appear in.
enum ErrorWatchedAppKind {
    case terminal
    case editor
    case xcode
    case browser
}

@MainActor
final class ErrorWatcher {
    /// A new error, never seen before this session.
    var onErrorAppeared: (DetectedScreenError) -> Void = { _ in }
    /// False while Buddy is answering, guiding or listening, during the
    /// minute after a glow, and in a Focus. Nothing is read then.
    var isAllowedToRead: () -> Bool = { true }
    /// The student switched apps: an error offered in the last one is no
    /// longer in front of them.
    var onFrontApplicationChanged: () -> Void = {}

    private var activationObserver: NSObjectProtocol?
    private var inputMonitor: Any?
    private var watchedApplication: NSRunningApplication?
    private var watchedAppKind: ErrorWatchedAppKind?
    private var currentWatch: Task<Void, Never>?
    private var currentWatchStartedByClick = false
    /// Waits still running. A replaced wait is cancelled but may take a
    /// moment to finish, so this is a count rather than a flag.
    private var runningWatchCount = 0
    /// A thumbnail of the front window from just before the student acted,
    /// taken in the pause after typing. A fast error (Python prints one in
    /// about 60 ms) can be on screen before a capture made after Return
    /// arrives, and would then look like no change at all.
    private var baselineThumbnail: (windowIdentifier: CGWindowID, cells: [UInt8], capturedAt: Date)?
    private var baselineRefreshTask: Task<Void, Never>?
    /// The same for a terminal read through its text: how long the text
    /// was in the last pause. Text added after it (the command being typed,
    /// then its output) is what gets read; starting a little early only
    /// adds the command line, which never looks like an error.
    private var baselineCharacterCount: (processIdentifier: pid_t, characterCount: Int, capturedAt: Date)?
    private static let baselineUsableForSeconds: TimeInterval = 20
    private var lastScrollAt: Date?
    private var lastReadAt: Date?
    private var seenFingerprints = SeenErrorFingerprints()

    /// Output that takes longer than this to appear (a long build) is not
    /// waited for; the next trigger starts a new wait. A click gets a short
    /// wait: most clicks in an editor run nothing.
    private static let longestWaitAfterKeySeconds: TimeInterval = 45
    private static let longestWaitAfterClickSeconds: TimeInterval = 10
    /// A click in an editor that changed most of the window switched the
    /// view (another file, another tab); output appears in a panel.
    private static let largestChangeAfterEditorClick = 0.6
    /// How long the window has to hold still for output to count as settled.
    private static let settledAfterSeconds: TimeInterval = 0.6
    private static let minimumSecondsBetweenReads: TimeInterval = 3

    // MARK: Which apps

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
        "co.zeit.hyper", "com.raphaelamorim.rio"
    ]
    private static let editorBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.sublimetext.4", "com.sublimetext.3",
        "com.google.android.studio", "com.panic.Nova"
    ]
    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen", "org.chromium.Chromium"
    ]
    /// The judge sites a browser is read on, by what their window title says.
    private static let judgeSiteTitleWords = ["leetcode", "hackerrank", "codeforces", "codesignal", "neetcode"]

    static func appKind(of application: NSRunningApplication) -> ErrorWatchedAppKind? {
        guard let bundleIdentifier = application.bundleIdentifier else { return nil }
        if bundleIdentifier == "com.apple.dt.Xcode" { return .xcode }
        if terminalBundleIdentifiers.contains(bundleIdentifier) { return .terminal }
        // Every JetBrains IDE (IntelliJ, PyCharm, WebStorm, CLion, GoLand...).
        if editorBundleIdentifiers.contains(bundleIdentifier) || bundleIdentifier.hasPrefix("com.jetbrains.") { return .editor }
        if browserBundleIdentifiers.contains(bundleIdentifier) { return .browser }
        return nil
    }

    // MARK: Starting and stopping

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.frontApplicationChanged(to: application) }
        }
        frontApplicationChanged(to: NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        stopListeningToInput()
    }

    /// Input is listened to only while an app where errors happen is in
    /// front. Anywhere else there is no monitor and no work at all.
    private func frontApplicationChanged(to application: NSRunningApplication?) {
        // Buddy's own notch or chat taking focus is not a switch away.
        if application?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        if application?.processIdentifier != watchedApplication?.processIdentifier {
            onFrontApplicationChanged()
        }
        currentWatch?.cancel()
        currentWatch = nil
        guard let application, let kind = Self.appKind(of: application) else {
            stopListeningToInput()
            watchedApplication = nil
            watchedAppKind = nil
            return
        }
        watchedApplication = application
        watchedAppKind = kind
        baselineThumbnail = nil
        startListeningToInput()
        scheduleBaselineRefresh(after: 0.6)
    }

    private func startListeningToInput() {
        guard inputMonitor == nil else { return }
        // Listen-only and global: these never see or delay the keys and
        // clicks, they only hear that one happened.
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseUp, .scrollWheel]) { [weak self] event in
            let eventType = event.type
            let keyCode = event.type == .keyDown ? event.keyCode : 0
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            Task { @MainActor in self?.studentActed(eventType: eventType, keyCode: keyCode, modifiers: modifiers) }
        }
    }

    private func stopListeningToInput() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        currentWatch?.cancel()
        currentWatch = nil
    }

    // MARK: Triggers

    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let bKeyCode: UInt16 = 11
    private static let rKeyCode: UInt16 = 15
    private static let uKeyCode: UInt16 = 32
    private static let sKeyCode: UInt16 = 1
    private static let quoteKeyCode: UInt16 = 39
    private static let f5KeyCode: UInt16 = 96
    private static let f10KeyCode: UInt16 = 109

    private func studentActed(eventType: NSEvent.EventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        if eventType == .scrollWheel {
            lastScrollAt = Date()
            return
        }
        guard let kind = watchedAppKind else { return }
        let isReturn = keyCode == Self.returnKeyCode || keyCode == Self.keypadEnterKeyCode
        let hasCommand = modifiers.contains(.command)
        let hasControl = modifiers.contains(.control)
        let isTrigger: Bool
        switch (kind, eventType) {
        case (.terminal, .keyDown):
            isTrigger = isReturn && !hasCommand
        case (.terminal, _):
            isTrigger = false
        case (.editor, .keyDown), (.xcode, .keyDown):
            // Run, build and test shortcuts across Xcode, VS Code and
            // JetBrains; Save, for test runners that watch files; Shift or
            // Command + Return, which runs a notebook cell; and Return in
            // an editor's own terminal panel.
            let isRunShortcut = (hasCommand && [Self.bKeyCode, Self.rKeyCode, Self.uKeyCode, Self.sKeyCode].contains(keyCode))
                || (hasControl && keyCode == Self.rKeyCode)
                || keyCode == Self.f5KeyCode || keyCode == Self.f10KeyCode
                || (isReturn && (hasCommand || modifiers.contains(.shift)))
            isTrigger = isRunShortcut || (isReturn && Self.focusedElementIsATerminal())
        case (.editor, _), (.xcode, _):
            isTrigger = true
        case (.browser, .keyDown):
            // Run and Submit on judge sites: Command or Control + Return,
            // and LeetCode's Command + '. Plain Return is typing code.
            isTrigger = (isReturn && (hasCommand || hasControl)) || (hasCommand && keyCode == Self.quoteKeyCode)
        case (.browser, _):
            isTrigger = true
        }
        guard isTrigger else {
            // Typing after a click in an editor or on a page means the
            // change on screen is the student's own, so that wait is
            // dropped. A wait after Return or a build keeps going: typing on
            // while a build or a test runs is common.
            if eventType == .keyDown, kind != .terminal, currentWatchStartedByClick {
                currentWatch?.cancel()
                currentWatch = nil
            }
            if eventType == .keyDown, kind != .browser, runningWatchCount == 0 {
                scheduleBaselineRefresh(after: 0.4)
            }
            return
        }
        triggered(byClick: eventType == .leftMouseUp)
    }

    /// VS Code's terminal is a text area labelled "Terminal"; so are
    /// JetBrains' and Zed's. Asked only when Return is pressed in an editor.
    private static func focusedElementIsATerminal() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        guard let focused = copyElementAttribute(systemWide, kAXFocusedUIElementAttribute) else { return false }
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXRoleDescriptionAttribute, kAXHelpAttribute] {
            if let text = copyAttribute(focused, attribute) as? String, text.lowercased().contains("terminal") { return true }
        }
        return false
    }

    /// Captures the front window's thumbnail once the student pauses, so a
    /// trigger has a true before to compare with. A browser needs none: a
    /// judge's verdict takes longer than a capture to come back.
    private func scheduleBaselineRefresh(after seconds: TimeInterval) {
        baselineRefreshTask?.cancel()
        baselineRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshBaseline()
        }
    }

    private func refreshBaseline() async {
        guard let application = watchedApplication, let kind = watchedAppKind, kind != .browser,
              runningWatchCount == 0, isAllowedToRead(),
              application.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        if kind == .terminal, let terminalText = AccessibilityTerminalText(processIdentifier: application.processIdentifier) {
            if let characterCount = terminalText.state()?.characterCount {
                baselineCharacterCount = (application.processIdentifier, characterCount, Date())
            }
            return
        }
        guard let window = Self.frontWindow(of: application),
              let capturableWindow = await CapturableWindow.find(windowIdentifier: window.windowIdentifier),
              let image = await capturableWindow.capture(maximumWidth: 240),
              let cells = ErrorWindowReading.thumbnail(of: image), !Task.isCancelled else { return }
        baselineThumbnail = (window.windowIdentifier, cells, Date())
    }

    private func triggered(byClick: Bool) {
        guard let application = watchedApplication, let kind = watchedAppKind,
              application.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              isAllowedToRead() else { return }
        guard let window = Self.frontWindow(of: application) else { return }
        guard let place = Self.readingPlace(for: kind, windowTitle: window.title) else { return }
        // A new trigger replaces a wait already running: the newest action
        // is the one whose output matters.
        currentWatch?.cancel()
        let triggeredAt = Date()
        currentWatchStartedByClick = byClick
        currentWatch = Task { [weak self] in
            await self?.waitForOutputAndRead(application: application, kind: kind, place: place,
                                             window: window, triggeredAt: triggeredAt, byClick: byClick)
        }
    }

    /// Where reading happens, or nil for a browser on any other site.
    static func readingPlace(for kind: ErrorWatchedAppKind, windowTitle: String) -> ErrorReadingPlace? {
        switch kind {
        case .terminal: return .terminal
        case .editor: return .editor
        case .xcode: return .xcode
        case .browser:
            let title = windowTitle.lowercased()
            if judgeSiteTitleWords.contains(where: { title.contains($0) }) { return .judgeSite }
            // Developer tools in their own window. Docked inside the page
            // window they leave no trace in the title, and are not detected.
            if title.hasPrefix("devtools") || title.contains("web inspector") || title.contains("developer tools") {
                return .browserDeveloperTools
            }
            return nil
        }
    }

    // MARK: Waiting for output

    /// The state of the window to compare against, by whichever means the
    /// app allows: its text where it has accessibility text, a thumbnail
    /// otherwise.
    private enum WindowState: Equatable {
        case text(characterCount: Int, tailHash: Int)
        case thumbnail([UInt8])
    }

    private func waitForOutputAndRead(application: NSRunningApplication, kind: ErrorWatchedAppKind, place: ErrorReadingPlace,
                                      window: FrontWindow, triggeredAt: Date, byClick: Bool) async {
        runningWatchCount += 1
        defer { runningWatchCount -= 1 }
        let terminalText = kind == .terminal ? AccessibilityTerminalText(processIdentifier: application.processIdentifier) : nil
        let capturableWindow = terminalText == nil ? await CapturableWindow.find(windowIdentifier: window.windowIdentifier) : nil
        guard terminalText != nil || capturableWindow != nil else { return }

        func currentState() async -> WindowState? {
            if let terminalText { return terminalText.state().map { .text(characterCount: $0.characterCount, tailHash: $0.tailHash) } }
            guard let image = await capturableWindow?.capture(maximumWidth: 240) else { return nil }
            return ErrorWindowReading.thumbnail(of: image).map(WindowState.thumbnail)
        }
        func differs(_ first: WindowState, _ second: WindowState) -> Bool {
            switch (first, second) {
            case let (.thumbnail(firstCells), .thumbnail(secondCells)):
                return ErrorWindowReading.changedRows(from: firstCells, to: secondCells).changedCells >= ErrorWindowReading.changedCellsForNewOutput
            default:
                return first != second
            }
        }

        // The baseline from the last pause is the truer before, when it is
        // of this window and recent; otherwise a capture now.
        var baselineState: WindowState?
        if terminalText == nil, let baselineThumbnail, baselineThumbnail.windowIdentifier == window.windowIdentifier,
           triggeredAt.timeIntervalSince(baselineThumbnail.capturedAt) < Self.baselineUsableForSeconds {
            baselineState = .thumbnail(baselineThumbnail.cells)
        }
        if baselineState == nil { baselineState = await currentState() }
        guard let stateAtTrigger = baselineState else { return }
        var characterCountAtTrigger = 0
        if case let .text(characterCount, _) = stateAtTrigger { characterCountAtTrigger = characterCount }
        if let baselineCharacterCount, baselineCharacterCount.processIdentifier == application.processIdentifier,
           triggeredAt.timeIntervalSince(baselineCharacterCount.capturedAt) < Self.baselineUsableForSeconds,
           baselineCharacterCount.characterCount <= characterCountAtTrigger {
            characterCountAtTrigger = baselineCharacterCount.characterCount
        }
        let longestWait = byClick ? Self.longestWaitAfterClickSeconds : Self.longestWaitAfterKeySeconds
        var lastState = stateAtTrigger
        var hasChanged = false
        var lastChangeAt = Date()
        var hasSettled = false
        // Text added since the last pause, already there when Return was
        // seen: a fast program printed before the first look.
        if case let .text(characterCountWhenSeen, _) = stateAtTrigger, characterCountAtTrigger < characterCountWhenSeen {
            hasChanged = true
        }
        while !Task.isCancelled, Date().timeIntervalSince(triggeredAt) < longestWait {
            // Quick at first, when output usually appears; slower after,
            // for a build or a test run that takes a while.
            let interval: TimeInterval = Date().timeIntervalSince(triggeredAt) < 5 ? 0.3 : 1.0
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if let lastScrollAt, lastScrollAt > triggeredAt { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return }
            guard let state = await currentState() else { return }
            if differs(state, lastState) {
                hasChanged = true
                lastChangeAt = Date()
                lastState = state
            } else if hasChanged, Date().timeIntervalSince(lastChangeAt) >= Self.settledAfterSeconds {
                hasSettled = true
                break
            }
        }
        guard hasSettled, !Task.isCancelled else { return }

        if let lastReadAt {
            let wait = Self.minimumSecondsBetweenReads - Date().timeIntervalSince(lastReadAt)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        guard !Task.isCancelled, isAllowedToRead(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return }
        lastReadAt = Date()
        switch lastState {
        case let .thumbnail(settledCells):
            baselineThumbnail = (window.windowIdentifier, settledCells, Date())
        case let .text(settledCharacterCount, _):
            baselineCharacterCount = (application.processIdentifier, settledCharacterCount, Date())
        }

        let readStartedAt = Date()
        let found: DetectedScreenError?
        if let terminalText {
            found = terminalText.readError(printedAfter: characterCountAtTrigger, place: place,
                                           applicationName: application.localizedName ?? "the terminal")
        } else if let capturableWindow, case let .thumbnail(cellsAtTrigger) = stateAtTrigger, case let .thumbnail(cellsNow) = lastState {
            found = await readErrorWithRecognition(window: capturableWindow, frame: window.frameInGlobalTopLeftPoints,
                                                   cellsAtTrigger: cellsAtTrigger, cellsNow: cellsNow, place: place,
                                                   isEditorClick: byClick && kind != .browser,
                                                   applicationName: application.localizedName ?? "the app")
        } else {
            found = nil
        }
        let readMilliseconds = Int(Date().timeIntervalSince(readStartedAt) * 1000)
        guard let found, !Task.isCancelled else {
            TutorDebugLog.write("🩺 error watch: read \(application.localizedName ?? "app") in \(readMilliseconds) ms, no error")
            return
        }
        guard seenFingerprints.insertIfNew(found.recognized.fingerprint) else {
            TutorDebugLog.write("🩺 error watch: \(found.recognized.kind.rawValue) already seen")
            return
        }
        TutorDebugLog.write("🩺 error watch: \(found.recognized.kind.rawValue) in \(found.applicationName), read in \(readMilliseconds) ms")
        onErrorAppeared(found)
    }

    /// Text recognition on the rows of the window that changed since the
    /// trigger, so old output above them is never read. When nearly every
    /// row changed (the output scrolled the window) the whole window is
    /// read, and the recognizer's own rule that a terminal's error must be
    /// at the end of the output keeps old errors out.
    private func readErrorWithRecognition(window: CapturableWindow, frame: CGRect, cellsAtTrigger: [UInt8], cellsNow: [UInt8],
                                          place: ErrorReadingPlace, isEditorClick: Bool,
                                          applicationName: String) async -> DetectedScreenError? {
        guard let image = await window.capture(maximumWidth: nil) else { return nil }
        var band = ErrorWindowReading.changedRows(from: cellsAtTrigger, to: cellsNow).rowBand
        if let changedBand = band, isEditorClick,
           changedBand.upperBound - changedBand.lowerBound > Self.largestChangeAfterEditorClick { return nil }
        if let changedBand = band, changedBand.upperBound - changedBand.lowerBound > 0.85 { band = nil }
        let rowBand = band
        let readLines = await Task.detached(priority: .utility) {
            ErrorWindowReading.readLines(in: image, rowBand: rowBand, accurate: true)
        }.value
        let lines = readLines.map(\.text)
        guard let recognized = ErrorRecognizer.recognize(lines: lines, place: place) else { return nil }
        let pointsPerPixel = frame.width / CGFloat(max(image.width, 1))
        var rects: [Int: CGRect] = [:]
        for lineIndex in [recognized.messageLineIndex, recognized.causeLineIndex, recognized.causeCodeLineIndex].compactMap({ $0 }) {
            let pixelBounds = readLines[lineIndex].boundsInImage
            rects[lineIndex] = CGRect(x: frame.minX + pixelBounds.minX * pointsPerPixel,
                                      y: frame.minY + pixelBounds.minY * pointsPerPixel,
                                      width: pixelBounds.width * pointsPerPixel,
                                      height: pixelBounds.height * pointsPerPixel)
        }
        return DetectedScreenError(recognized: recognized, lines: lines, rectsInGlobalTopLeftPoints: rects,
                                   applicationName: applicationName, place: place)
    }

    // MARK: The front window

    struct FrontWindow {
        let windowIdentifier: CGWindowID
        let frameInGlobalTopLeftPoints: CGRect
        let title: String
    }

    /// The app's frontmost ordinary window. The window list is in front to
    /// back order, so the first one of the app's that is a real window
    /// (layer 0, not a sliver) is the one being looked at.
    static func frontWindow(of application: NSRunningApplication) -> FrontWindow? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for windowInfo in windowList {
            guard (windowInfo[kCGWindowOwnerPID as String] as? pid_t) == application.processIdentifier,
                  (windowInfo[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 200, bounds.height >= 120,
                  let windowNumber = windowInfo[kCGWindowNumber as String] as? CGWindowID else { continue }
            // The window server's name needs Screen Recording; the
            // accessibility title is the fallback and is what browsers fill.
            let title = (windowInfo[kCGWindowName as String] as? String) ?? focusedWindowTitle(of: application) ?? ""
            return FrontWindow(windowIdentifier: windowNumber, frameInGlobalTopLeftPoints: bounds,
                               title: title.isEmpty ? (focusedWindowTitle(of: application) ?? "") : title)
        }
        return nil
    }

    private static func focusedWindowTitle(of application: NSRunningApplication) -> String? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.2)
        guard let window = copyElementAttribute(applicationElement, kAXFocusedWindowAttribute) else { return nil }
        return copyAttribute(window, kAXTitleAttribute) as? String
    }
}

// MARK: - Capturing one window

/// One window, captured on its own: never the whole screen, never Buddy's
/// drawing or the pointer over it.
private struct CapturableWindow {
    let shareableWindow: SCWindow

    static func find(windowIdentifier: CGWindowID) async -> CapturableWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let shareableWindow = content.windows.first(where: { $0.windowID == windowIdentifier }) else { return nil }
        return CapturableWindow(shareableWindow: shareableWindow)
    }

    /// `maximumWidth` small for the thumbnail; nil for the window's own
    /// size at Retina scale, for reading text.
    func capture(maximumWidth: Int?) async -> CGImage? {
        let frame = shareableWindow.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let fullWidth = Int(frame.width * scale)
        let width = min(maximumWidth ?? fullWidth, fullWidth)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = max(1, Int(CGFloat(width) * frame.height / frame.width))
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

// MARK: - A terminal's accessibility text

/// Terminal and iTerm2 expose their output as an accessibility text area.
/// Reading it is exact and costs a fraction of a millisecond; nothing is
/// captured. Apps that draw their own text on the GPU (Warp, Ghostty,
/// kitty, Alacritty, WezTerm) expose none, and use recognition instead.
@MainActor
private final class AccessibilityTerminalText {
    private let textArea: AXUIElement

    init?(processIdentifier: pid_t) {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.25)
        if let focused = copyElementAttribute(applicationElement, kAXFocusedUIElementAttribute),
           (copyAttribute(focused, kAXRoleAttribute) as? String) == (kAXTextAreaRole as String) {
            textArea = focused
        } else if let window = copyElementAttribute(applicationElement, kAXFocusedWindowAttribute),
                  let found = Self.findTextArea(under: window, depth: 0) {
            textArea = found
        } else {
            return nil
        }
        AXUIElementSetMessagingTimeout(textArea, 0.25)
        guard state() != nil else { return nil }
    }

    private static func findTextArea(under element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 8 else { return nil }
        if (copyAttribute(element, kAXRoleAttribute) as? String) == (kAXTextAreaRole as String) { return element }
        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children.prefix(40) {
            if let found = findTextArea(under: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The length of the text and a hash of what is on screen: cheap
    /// enough to ask three times a second while waiting for output.
    func state() -> (characterCount: Int, tailHash: Int)? {
        guard let characterCount = copyAttribute(textArea, kAXNumberOfCharactersAttribute) as? Int else { return nil }
        let visible = visibleRange() ?? NSRange(location: max(0, characterCount - 4_000), length: min(characterCount, 4_000))
        return (characterCount, (string(for: visible) ?? "").hashValue)
    }

    private func visibleRange() -> NSRange? {
        guard let value = copyAttribute(textArea, kAXVisibleCharacterRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // Checked to be an AXValue just above.
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func string(for range: NSRange) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard range.length > 0, let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(textArea, kAXStringForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &result) == .success else { return nil }
        return result as? String
    }

    private func bounds(for range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard range.length > 0, let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(textArea, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        // Checked to be an AXValue just above.
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// The error in what was printed after the trigger and is on screen.
    func readError(printedAfter characterCountAtTrigger: Int, place: ErrorReadingPlace,
                   applicationName: String) -> DetectedScreenError? {
        guard let characterCount = copyAttribute(textArea, kAXNumberOfCharactersAttribute) as? Int else { return nil }
        let visible = visibleRange() ?? NSRange(location: max(0, characterCount - 8_000), length: min(characterCount, 8_000))
        let range = ErrorWindowReading.rangeToRead(characterCountAtTrigger: characterCountAtTrigger, visibleRange: visible,
                                                   currentCharacterCount: characterCount)
        guard range.length > 0, let text = string(for: range) else { return nil }

        // Lines with where each starts, in UTF-16 units as the API counts.
        var lines: [String] = []
        var lineStarts: [Int] = []
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            lines.append(line)
            lineStarts.append(range.location + offset)
            offset += line.utf16.count + 1
        }
        guard let recognized = ErrorRecognizer.recognize(lines: lines, place: place) else { return nil }
        var rects: [Int: CGRect] = [:]
        for lineIndex in [recognized.messageLineIndex, recognized.causeLineIndex, recognized.causeCodeLineIndex].compactMap({ $0 }) {
            let lineRange = NSRange(location: lineStarts[lineIndex], length: lines[lineIndex].utf16.count)
            if let rect = bounds(for: lineRange) { rects[lineIndex] = rect }
        }
        return DetectedScreenError(recognized: recognized, lines: lines, rectsInGlobalTopLeftPoints: rects,
                                   applicationName: applicationName, place: place)
    }
}

// MARK: - Accessibility helpers

private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

private func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    // Checked to be an AXUIElement just above.
    return (value as! AXUIElement)
}
