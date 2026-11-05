//
//  MarkFollower.swift
//  leanring-buddy
//
//  Keeps the marks of an answer on the things they mark. Marks are drawn at
//  places on the screenshot, and the content under them does not stay put:
//  the window is dragged, the page scrolls, another app comes in front.
//
//  - The window drags or resizes: marks follow its frame, read from the
//    accessibility tree as it moves. A resize can reflow the content, so
//    once it stops the marked items are found again.
//  - The page scrolls: marks move with a trackpad's deltas while it moves.
//    When it stops (200 ms), only that window is captured and read, and each
//    marked item's text is found again near where it should now be; marks
//    glide there, fade if their item has left the view, and come back if it
//    returns. Where the same text appears several times, the copy nearest
//    the expected place is taken, and none if no copy is near: a mark never
//    jumps to a far duplicate.
//  - The window goes behind another, to another Space, or its app is
//    hidden: its marks are hidden, and shown again when it is back.
//
//  Nothing runs while nothing moves: window moves are notifications, and
//  the one text recognition happens after a scroll or resize has stopped.
//  No model is asked. Marks over things outside the window (the menu bar,
//  an open menu) stay where they are, as guide mode expects.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// Where an anchor should be drawn: an offset in canvas pixels from where
/// its item was listed, and whether it is in view.
struct AnchorPlacement: Equatable {
    let id: String
    let dx: Double
    let dy: Double
    let visible: Bool
}

/// Finding marked items again in a fresh capture of their window. Pure apart
/// from Vision, so it can be measured and checked offline on a saved image.
enum MarkRefinding {
    /// An item to look for: its text, and where it should be now, in the
    /// capture's pixels with the origin at the top left.
    struct WantedItem: Sendable {
        let id: String
        let label: String
        let expectedCenter: CGPoint
        /// How far from the expected place a copy of a repeated text may be.
        let nearEnoughPixels: CGFloat
    }

    /// Each found item's box in the capture's pixels, top-left origin.
    /// Off the main actor: recognition takes a fifth of a second.
    nonisolated static func find(_ wantedItems: [WantedItem], in image: CGImage, regionOfInterest: CGRect?) -> [String: CGRect] {
        let request = VNRecognizeTextRequest()
        // As the screen index reads, so the same text is found the same way.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if let regionOfInterest { request.regionOfInterest = regionOfInterest }
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return [:] }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let candidates = (request.results ?? []).compactMap { observation in observation.topCandidates(1).first }

        func pixelRect(_ normalized: CGRect) -> CGRect {
            CGRect(x: normalized.minX * width, y: (1 - normalized.maxY) * height,
                   width: normalized.width * width, height: normalized.height * height)
        }

        var found: [String: CGRect] = [:]
        for wanted in wantedItems {
            let wantedText = normalized(wanted.label)
            guard wantedText.count >= 2 else { continue }
            var matches: [CGRect] = []
            for candidate in candidates {
                let lineText = normalized(candidate.string)
                if lineText == wantedText || isCloseEnough(lineText, wantedText) {
                    if let box = try? candidate.boundingBox(for: candidate.string.startIndex..<candidate.string.endIndex) {
                        matches.append(pixelRect(box.boundingBox))
                    }
                } else if wantedText.count >= 4, let range = candidate.string.range(of: wanted.label, options: [.caseInsensitive]) {
                    // The item is part of a longer recognised line: its own
                    // part of the line, not the whole line.
                    if let box = try? candidate.boundingBox(for: range) { matches.append(pixelRect(box.boundingBox)) }
                }
            }
            if let chosen = chooseMatch(matches, expectedCenter: wanted.expectedCenter, nearEnough: wanted.nearEnoughPixels) {
                found[wanted.id] = chosen
            }
        }
        return found
    }

    /// One copy is taken wherever it is. Of several, the nearest to where
    /// the item should be, and only if it is near: a far duplicate is never
    /// taken, the mark fades instead.
    nonisolated static func chooseMatch(_ matches: [CGRect], expectedCenter: CGPoint, nearEnough: CGFloat) -> CGRect? {
        if matches.count == 1 { return matches[0] }
        let byDistance = matches.map { rect in
            (rect: rect, distance: hypot(rect.midX - expectedCenter.x, rect.midY - expectedCenter.y))
        }.sorted { $0.distance < $1.distance }
        guard let nearest = byDistance.first, nearest.distance <= nearEnough else { return nil }
        return nearest.rect
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".:;,\u{2026}"))
    }

    /// The same line read slightly differently: one contains the other and
    /// they are nearly the same length.
    private nonisolated static func isCloseEnough(_ first: String, _ second: String) -> Bool {
        let shorter = first.count <= second.count ? first : second
        let longer = first.count <= second.count ? second : first
        guard shorter.count >= 4, longer.contains(shorter) else { return false }
        return Double(shorter.count) / Double(longer.count) >= 0.75
    }
}

@MainActor
final class MarkFollower {
    /// Sends placements to the drawing engine; the flag animates a settled move.
    var placeAnchors: ([AnchorPlacement], Bool) -> Void = { _, _ in }

    /// After a scroll or a resize stops, before the window is read again.
    private static let settleSeconds: TimeInterval = 0.2

    private var isFollowing = false
    private var displayFrame: CGRect = .zero
    private var canvasSize: CGSize = .zero
    private var pointsPerCanvasPixel: CGFloat = 1
    private var targets: [String: [Double]] = [:]
    private var labels: [String: String] = [:]
    /// Items read from the accessibility tree: controls that may carry no
    /// readable text, which stay where the window puts them if not found.
    private var accessibilityItemIds: Set<String> = []
    private var anchorIds: [String] = []

    // The window the answer was drawn over.
    private var windowElement: AXUIElement?
    private var applicationElement: AXUIElement?
    private var processIdentifier: pid_t = 0
    private var windowNumber: CGWindowID?
    private var windowFrameAtAnswer: CGRect = .zero
    private var windowFrameNow: CGRect = .zero
    private var accessibilityObserver: AXObserver?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// How far the content has moved inside the window, per item, in
    /// points: from finding it again after a scroll.
    private var contentOffsets: [String: CGPoint] = [:]
    /// Scrolling seen since the items were last found, in points.
    private var unconfirmedScroll: CGPoint = .zero
    /// A mouse wheel says lines, not points: where items went is unknown
    /// until they are found again, so they are hidden meanwhile.
    private var scrollDistanceUnknown = false
    private var itemsOutOfView: Set<String> = []
    private var itemsCovered: Set<String> = []
    private var windowIsVisible = true
    private var settleTask: Task<Void, Never>?
    private var refindTask: Task<Void, Never>?

    var isActive: Bool { isFollowing }

    /// Starts following for an answer drawn over the app in front. Without
    /// accessibility or a window to follow, it does nothing and the caller
    /// keeps the older behaviour.
    func begin(displayFrame: CGRect, canvasSize: CGSize, targets: [String: [Double]], labels: [String: String],
               accessibilityItemIds: Set<String>) {
        stop()
        guard AXIsProcessTrusted(), canvasSize.width > 0, displayFrame.width > 0,
              let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return }
        // The force cast is checked by the type id above.
        let windowElement = windowValue as! AXUIElement
        guard let windowFrame = WindowFrameReader.frame(of: windowElement) else { return }

        self.displayFrame = displayFrame
        self.canvasSize = canvasSize
        pointsPerCanvasPixel = displayFrame.width / canvasSize.width
        self.targets = targets
        self.labels = labels
        self.accessibilityItemIds = accessibilityItemIds
        self.windowElement = windowElement
        self.applicationElement = applicationElement
        processIdentifier = application.processIdentifier
        windowFrameAtAnswer = windowFrame
        windowFrameNow = windowFrame
        windowNumber = Self.windowNumber(processIdentifier: application.processIdentifier, frame: windowFrame)
        isFollowing = true
        observeWindow()
        observeWorkspace()
    }

    func stop() {
        guard isFollowing else { return }
        isFollowing = false
        settleTask?.cancel()
        refindTask?.cancel()
        if let accessibilityObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(accessibilityObserver), .defaultMode)
        }
        accessibilityObserver = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        windowElement = nil
        applicationElement = nil
        windowNumber = nil
        anchorIds = []
        contentOffsets = [:]
        unconfirmedScroll = .zero
        scrollDistanceUnknown = false
        itemsOutOfView = []
        itemsCovered = []
        windowIsVisible = true
    }

    /// The engine made anchors for these ids (from each piece of the program).
    func anchorsNow(_ ids: [String]) {
        guard isFollowing else { return }
        anchorIds = ids
    }

    // MARK: - Scrolling

    /// A scroll anywhere. Only one over the followed window moves its marks.
    func scrolled(deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool) {
        guard isFollowing, deltaX != 0 || deltaY != 0, windowIsVisible else { return }
        let pointer = Self.globalTopLeft(fromAppKit: NSEvent.mouseLocation)
        guard windowFrameNow.contains(pointer) else { return }
        if hasPreciseDeltas {
            // AppKit's deltas are content moving down and right, which is
            // the canvas's own direction too.
            unconfirmedScroll.x += deltaX
            unconfirmedScroll.y += deltaY
        } else {
            scrollDistanceUnknown = true
        }
        place(animate: false)
        settleThenRefind()
    }

    // MARK: - Placing

    private func place(animate: Bool) {
        guard isFollowing, !anchorIds.isEmpty else { return }
        let windowShift = CGPoint(x: windowFrameNow.minX - windowFrameAtAnswer.minX,
                                  y: windowFrameNow.minY - windowFrameAtAnswer.minY)
        var placements: [AnchorPlacement] = []
        for id in anchorIds {
            var offset = CGPoint.zero
            var visible = windowIsVisible
            let isInWindow = id == "__window" || itemIsInWindowAtAnswer(id)
            if isInWindow {
                offset = windowShift
                if id != "__window" {
                    let contentOffset = contentOffsets[id] ?? .zero
                    offset.x += contentOffset.x + unconfirmedScroll.x
                    offset.y += contentOffset.y + unconfirmedScroll.y
                    if scrollDistanceUnknown || itemsOutOfView.contains(id) || itemsCovered.contains(id) { visible = false }
                }
                // Moved off this display, where the drawing is not.
                if let rect = currentGlobalRect(of: id, offset: offset), !displayGlobalTopLeftFrame.intersects(rect) { visible = false }
            }
            placements.append(AnchorPlacement(id: id, dx: Double(offset.x / pointsPerCanvasPixel),
                                              dy: Double(offset.y / pointsPerCanvasPixel), visible: visible))
        }
        placeAnchors(placements, animate)
    }

    // MARK: - Finding items again

    private func settleThenRefind() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.refind()
        }
    }

    private func refind() {
        guard isFollowing, windowIsVisible, let windowNumber else { return }
        refindTask?.cancel()
        let windowShift = CGPoint(x: windowFrameNow.minX - windowFrameAtAnswer.minX, y: windowFrameNow.minY - windowFrameAtAnswer.minY)
        let windowFrame = windowFrameNow
        // Where each item should be now, in the window's own points.
        var expected: [(id: String, label: String, centerInWindow: CGPoint, height: CGFloat)] = []
        for id in anchorIds where id != "__window" && itemIsInWindowAtAnswer(id) {
            guard let label = labels[id], let originalRect = originalGlobalRect(of: id) else { continue }
            let contentOffset = contentOffsets[id] ?? .zero
            let center = CGPoint(x: originalRect.midX + windowShift.x + contentOffset.x + unconfirmedScroll.x - windowFrame.minX,
                                 y: originalRect.midY + windowShift.y + contentOffset.y + unconfirmedScroll.y - windowFrame.minY)
            expected.append((id, label, center, originalRect.height))
        }
        guard !expected.isEmpty else { return }
        let distanceIsUnknown = scrollDistanceUnknown
        let startedAt = Date()
        refindTask = Task { @MainActor [weak self] in
            let screenScale = NSScreen.screens.first { $0.frame == self?.displayFrame }?.backingScaleFactor ?? 2
            guard let image = await Self.captureWindow(windowNumber, screenScale: screenScale), !Task.isCancelled,
                  let self, self.isFollowing else { return }
            let pixelsPerPoint = CGFloat(image.width) / max(windowFrame.width, 1)
            let wanted = expected.map { item in
                MarkRefinding.WantedItem(
                    id: item.id, label: item.label,
                    expectedCenter: CGPoint(x: item.centerInWindow.x * pixelsPerPoint, y: item.centerInWindow.y * pixelsPerPoint),
                    // A few lines either way. After a mouse wheel, where the
                    // items went is a guess, so only a unique copy is taken.
                    nearEnoughPixels: distanceIsUnknown ? 0 : max(120, item.height * 3) * pixelsPerPoint)
            }
            // Only the part of the window the items can be in, unless a
            // wheel moved them by an unknown amount.
            let regionOfInterest = distanceIsUnknown ? nil : Self.regionOfInterest(around: expected.map(\.centerInWindow), in: windowFrame.size)
            let found = await Task.detached(priority: .userInitiated) {
                MarkRefinding.find(wanted, in: image, regionOfInterest: regionOfInterest)
            }.value
            guard !Task.isCancelled, self.isFollowing else { return }
            for item in expected {
                guard let originalRect = self.originalGlobalRect(of: item.id) else { continue }
                if let box = found[item.id] {
                    let foundCenter = CGPoint(x: windowFrame.minX + box.midX / pixelsPerPoint, y: windowFrame.minY + box.midY / pixelsPerPoint)
                    self.contentOffsets[item.id] = CGPoint(x: foundCenter.x - originalRect.midX - windowShift.x,
                                                           y: foundCenter.y - originalRect.midY - windowShift.y)
                    self.itemsOutOfView.remove(item.id)
                } else if self.accessibilityItemIds.contains(item.id) {
                    // A control with no readable text is most likely chrome
                    // that does not scroll: it stays where the window has it.
                    self.contentOffsets[item.id] = .zero
                    self.itemsOutOfView.remove(item.id)
                } else {
                    self.itemsOutOfView.insert(item.id)
                }
            }
            self.unconfirmedScroll = .zero
            self.scrollDistanceUnknown = false
            TutorDebugLog.write("📌 marks: found \(found.count) of \(expected.count) marked items again in \(String(format: "%.0f", Date().timeIntervalSince(startedAt) * 1000)) ms")
            self.checkCovering()
            self.place(animate: true)
        }
    }

    private static func regionOfInterest(around centers: [CGPoint], in windowSize: CGSize) -> CGRect? {
        guard let first = centers.first, windowSize.height > 0 else { return nil }
        var minY = first.y, maxY = first.y
        for center in centers { minY = min(minY, center.y); maxY = max(maxY, center.y) }
        // Full width, since lines are wide; a margin of 220 points above and
        // below where the items should be. Vision's region has its origin at
        // the bottom left, as fractions of the image.
        let top = max(0, minY - 220), bottom = min(windowSize.height, maxY + 220)
        guard bottom > top else { return nil }
        let fraction = CGRect(x: 0, y: 1 - bottom / windowSize.height, width: 1, height: (bottom - top) / windowSize.height)
        return fraction.height >= 0.95 ? nil : fraction
    }

    /// The followed window's own content, even where something covers it,
    /// and none of Buddy's windows.
    private static func captureWindow(_ windowNumber: CGWindowID, screenScale: CGFloat) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowNumber }) else { return nil }
        let configuration = SCStreamConfiguration()
        // The screen's own pixels, as sharp as text is drawn, capped for
        // a very wide window so recognition stays quick.
        let pixelScale = min(screenScale, 2560 / max(window.frame.width, 1))
        configuration.width = max(1, Int(window.frame.width * pixelScale))
        configuration.height = max(1, Int(window.frame.height * pixelScale))
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    // MARK: - The window

    private func observeWindow() {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let follower = Unmanaged<MarkFollower>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { follower.windowNotified(name) }
        }
        guard AXObserverCreate(processIdentifier, callback, &observer) == .success, let observer,
              let windowElement, let applicationElement else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, windowElement, notification as CFString, refcon)
        }
        // Another of the app's windows coming to the front can cover it.
        AXObserverAddNotification(observer, applicationElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        accessibilityObserver = observer
    }

    private func windowNotified(_ notification: String) {
        guard isFollowing, let windowElement else { return }
        switch notification {
        case kAXMovedNotification, kAXResizedNotification:
            guard let frame = WindowFrameReader.frame(of: windowElement) else { return }
            let resized = frame.size != windowFrameNow.size
            windowFrameNow = frame
            place(animate: false)
            if resized {
                // The content may have reflowed: found again once it settles.
                settleThenRefind()
            } else {
                settleThenCheckCovering()
            }
        case kAXUIElementDestroyedNotification:
            windowIsVisible = false
            place(animate: true)
        default:
            // Minimised, restored, or another of its windows in front.
            settleThenCheckCovering()
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.settleThenCheckCovering() }
            })
        }
    }

    private var coveringCheckTask: Task<Void, Never>?

    /// Windows reorder a moment after the notification, so the check waits
    /// for them to settle.
    private func settleThenCheckCovering() {
        coveringCheckTask?.cancel()
        coveringCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.checkVisibility()
        }
    }

    private func checkVisibility() {
        guard isFollowing else { return }
        let wasVisible = windowIsVisible
        checkCovering()
        place(animate: true)
        // Back from another app or Space while the page may have moved.
        if windowIsVisible && !wasVisible { settleThenRefind() }
    }

    /// Whether the window is on screen at all, and which marked items other
    /// windows in front of it cover. Buddy's own windows never count.
    private func checkCovering() {
        guard let windowNumber,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        var windowsInFront: [CGRect] = []
        var foundOurs = false
        // Front to back: everything before ours is in front of it.
        for window in windows {
            guard let number = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            if number == windowNumber { foundOurs = true; break }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let owner = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            guard layer == 0, owner != ownProcess, alpha > 0.05,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { continue }
            windowsInFront.append(bounds)
        }
        windowIsVisible = foundOurs
        itemsCovered = []
        guard foundOurs else { return }
        let windowShift = CGPoint(x: windowFrameNow.minX - windowFrameAtAnswer.minX, y: windowFrameNow.minY - windowFrameAtAnswer.minY)
        for id in anchorIds where id != "__window" && itemIsInWindowAtAnswer(id) {
            let contentOffset = contentOffsets[id] ?? .zero
            let offset = CGPoint(x: windowShift.x + contentOffset.x + unconfirmedScroll.x, y: windowShift.y + contentOffset.y + unconfirmedScroll.y)
            guard let rect = currentGlobalRect(of: id, offset: offset) else { continue }
            if windowsInFront.contains(where: { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }) { itemsCovered.insert(id) }
        }
    }

    /// The on-screen window list's number for the window the accessibility
    /// tree reported, matched by its owner and frame.
    private static func windowNumber(processIdentifier: pid_t, frame: CGRect) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var firstOfTheApp: CGWindowID?
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { continue }
            if firstOfTheApp == nil { firstOfTheApp = number }
            if abs(bounds.minX - frame.minX) < 3, abs(bounds.minY - frame.minY) < 3,
               abs(bounds.width - frame.width) < 3, abs(bounds.height - frame.height) < 3 { return number }
        }
        return firstOfTheApp
    }

    // MARK: - Coordinates

    /// AppKit's points (bottom-left origin) to global top-left points, the
    /// accessibility tree's and the window list's.
    private static func globalTopLeft(fromAppKit point: CGPoint) -> CGPoint {
        let menuBarScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: menuBarScreenHeight - point.y)
    }

    private var displayGlobalTopLeftFrame: CGRect {
        let menuBarScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: displayFrame.minX, y: menuBarScreenHeight - displayFrame.maxY,
                      width: displayFrame.width, height: displayFrame.height)
    }

    /// An item's rectangle as listed for the answer, in global top-left points.
    private func originalGlobalRect(of id: String) -> CGRect? {
        guard let box = targets[id], box.count == 4 else { return nil }
        let origin = displayGlobalTopLeftFrame.origin
        return CGRect(x: origin.x + box[0] * pointsPerCanvasPixel, y: origin.y + box[1] * pointsPerCanvasPixel,
                      width: box[2] * pointsPerCanvasPixel, height: box[3] * pointsPerCanvasPixel)
    }

    private func currentGlobalRect(of id: String, offset: CGPoint) -> CGRect? {
        originalGlobalRect(of: id)?.offsetBy(dx: offset.x, dy: offset.y)
    }

    /// Whether an item was inside the window when the answer was drawn.
    /// Anything outside (the menu bar, an open menu) stays where it is.
    private func itemIsInWindowAtAnswer(_ id: String) -> Bool {
        guard let rect = originalGlobalRect(of: id) else { return false }
        return windowFrameAtAnswer.contains(CGPoint(x: rect.midX, y: rect.midY))
    }
}
