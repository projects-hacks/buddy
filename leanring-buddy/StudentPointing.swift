//
//  StudentPointing.swift
//  leanring-buddy
//
//  What "this" means. A student asking "why is this slow" or "what does
//  that do" usually has the thing under the pointer or selected, and the
//  model, seeing only a still screenshot, cannot tell which of forty lines
//  they mean. Two signals are read on the Mac and handed to the model as
//  one line of the turn note:
//
//  - Selected text in the app in front, read from the accessibility tree at
//    question time. Selecting is deliberate, so it is a strong signal.
//  - The pointer, but only where it rested: still for 0.4 s or more on a
//    listed screen item while the keys were held. Where the pointer merely
//    happens to sit says nothing; a pause on a line while saying "this" does.
//
//  Both are optional and often absent. With neither, the turn note is
//  exactly what it was without this file, so the cache and the answers are
//  unchanged.
//

import AppKit
import ApplicationServices
import Foundation

/// Where the pointer rested while the talk keys were held.
struct PointerRest: Equatable {
    /// AppKit global points, bottom-left origin, as NSEvent.mouseLocation.
    let location: CGPoint
    let seconds: TimeInterval
}

/// Text the student had selected when they asked.
struct StudentSelection: Equatable {
    let text: String
    /// Accessibility's global, top-left-origin points, when the app reports them.
    let boundsInGlobalTopLeftPoints: CGRect?
}

/// What the student pointed at or selected for one question.
struct StudentPointingClues: Equatable {
    var pointerRests: [PointerRest] = []
    var selection: StudentSelection?

    var isEmpty: Bool { pointerRests.isEmpty && selection == nil }
}

/// Samples the pointer while the keys are held and keeps the places it
/// rested. A timer rather than an event monitor: a resting pointer sends no
/// events, and the rest is exactly what is being measured.
@MainActor
final class PointerRestWatcher {
    /// Long enough that passing over a line on the way somewhere does not
    /// count, short enough that a pause while saying "this" does.
    static let minimumRestSeconds: TimeInterval = 0.4
    /// A hand on a trackpad drifts by a point or two while resting.
    static let stillWithinPoints: CGFloat = 4
    private static let sampleIntervalSeconds: TimeInterval = 0.05

    private var samplingTimer: Timer?
    private var stillSince: Date?
    private var stillLocation: CGPoint?
    private var rests: [PointerRest] = []

    func start() {
        cancel()
        stillSince = Date()
        stillLocation = NSEvent.mouseLocation
        let timer = Timer(timeInterval: Self.sampleIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        samplingTimer = timer
    }

    /// Stops sampling and returns the rests, the one in progress included.
    func stop() -> [PointerRest] {
        closeCurrentStillPeriod(at: Date())
        let collected = rests
        cancel()
        return collected
    }

    func cancel() {
        samplingTimer?.invalidate()
        samplingTimer = nil
        stillSince = nil
        stillLocation = nil
        rests = []
    }

    private func sample() {
        let location = NSEvent.mouseLocation
        guard let stillLocation else {
            self.stillLocation = location
            stillSince = Date()
            return
        }
        if hypot(location.x - stillLocation.x, location.y - stillLocation.y) > Self.stillWithinPoints {
            closeCurrentStillPeriod(at: Date())
            self.stillLocation = location
            stillSince = Date()
        }
    }

    private func closeCurrentStillPeriod(at moment: Date) {
        guard let stillSince, let stillLocation else { return }
        let seconds = moment.timeIntervalSince(stillSince)
        if seconds >= Self.minimumRestSeconds {
            rests.append(PointerRest(location: stillLocation, seconds: seconds))
        }
        self.stillSince = nil
        self.stillLocation = nil
    }
}

enum SelectedTextReader {
    /// Enough for a line of code, an error or a sentence; a whole selected
    /// page would crowd the screen's own listing out of the prompt.
    static let maximumCharacters = 400

    /// The selected text in the frontmost app other than Buddy, read from
    /// its focused element. Asked of that app rather than system-wide, so
    /// Buddy's own chat box, which has the keyboard while a question is
    /// typed, is never what is read.
    @MainActor
    static func selectionInFrontApp() -> StudentSelection? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        // Read on the main thread: a busy app must not hold it.
        AXUIElementSetMessagingTimeout(applicationElement, 0.25)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        // The force cast is checked by the type id above.
        let focusedElement = focusedValue as! AXUIElement

        // A password field never gives its text, but it is not even asked.
        var subroleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedElement, kAXSubroleAttribute as CFString, &subroleValue)
        if (subroleValue as? String) == (kAXSecureTextFieldSubrole as String) { return nil }

        var selectedTextValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selectedTextValue) == .success,
              let selectedText = selectedTextValue as? String else { return nil }
        let cleanedText = selectedText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard cleanedText.count >= 2 else { return nil }
        let shortenedText = cleanedText.count > maximumCharacters
            ? String(cleanedText.prefix(maximumCharacters)) + "..."
            : cleanedText
        return StudentSelection(text: shortenedText,
                                boundsInGlobalTopLeftPoints: selectionBounds(of: focusedElement))
    }

    private static func selectionBounds(of element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        // The force cast is checked by the type id above.
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds), bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }
}

enum StudentPointingNote {
    /// The turn note's line for what the student pointed at or selected, or
    /// nil when there is nothing to say. Selected text wins: it was chosen
    /// on purpose. Of the pointer's rests, the longest on a listed item wins,
    /// then the latest.
    @MainActor
    static func line(
        for clues: StudentPointingClues,
        screenIndex: ScreenIndex,
        displayFrame: CGRect,
        canvasSize: CGSize,
        includePointer: Bool
    ) -> String? {
        if let selection = clues.selection {
            var line = "SELECTED TEXT"
            if let bounds = selection.boundsInGlobalTopLeftPoints,
               let canvasBox = canvasBox(forGlobalTopLeftRect: bounds, displayFrame: displayFrame, canvasSize: canvasSize) {
                line += " (at [\(Int(canvasBox.minX)), \(Int(canvasBox.minY)), \(Int(canvasBox.width)), \(Int(canvasBox.height))])"
            }
            return line + ": \"\(quoted(selection.text))\""
        }
        guard includePointer else { return nil }
        var bestMatch: (rest: PointerRest, target: ScreenTarget)?
        for rest in clues.pointerRests {
            let displayLocalPoint = CGPoint(x: rest.location.x - displayFrame.minX, y: rest.location.y - displayFrame.minY)
            guard let target = screenIndex.listedTarget(atDisplayLocalPoint: displayLocalPoint) else { continue }
            if bestMatch == nil || rest.seconds >= bestMatch!.rest.seconds {
                bestMatch = (rest, target)
            }
        }
        guard let bestMatch else { return nil }
        let text = bestMatch.target.displayedText.replacingOccurrences(of: "\n", with: " ")
        let shortenedText = text.count > 80 ? String(text.prefix(80)) + "..." : text
        return "THE STUDENT IS POINTING AT: \(bestMatch.target.id) \"\(quoted(shortenedText))\""
    }

    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
    }

    /// Accessibility's global top-left points to the canvas's pixels. The
    /// top-left origin is the top of the screen holding the menu bar, which
    /// is AppKit's first screen; a rect off this display gives nil.
    static func canvasBox(forGlobalTopLeftRect rect: CGRect, displayFrame: CGRect, canvasSize: CGSize,
                          menuBarScreenHeight: CGFloat? = NSScreen.screens.first?.frame.height) -> CGRect? {
        guard let menuBarScreenHeight, displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        let displayTopInGlobalTopLeft = menuBarScreenHeight - displayFrame.maxY
        let scaleX = canvasSize.width / displayFrame.width
        let scaleY = canvasSize.height / displayFrame.height
        let box = CGRect(
            x: ((rect.minX - displayFrame.minX) * scaleX).rounded(),
            y: ((rect.minY - displayTopInGlobalTopLeft) * scaleY).rounded(),
            width: (rect.width * scaleX).rounded(),
            height: (rect.height * scaleY).rounded())
        guard box.intersects(CGRect(origin: .zero, size: canvasSize)) else { return nil }
        return box
    }
}
