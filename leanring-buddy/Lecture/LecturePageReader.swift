//
//  LecturePageReader.swift
//  leanring-buddy
//
//  Reads the front window through the accessibility tree for lecture mode:
//  the page's address, the player's time, and a transcript panel if the
//  page shows one (YouTube's "Show transcript", Coursera's interactive
//  transcript). Only reads; nothing on the page is clicked or changed.
//
//  Why the accessibility tree and not only the screenshot. A playing
//  YouTube video hides its controls, so the "12:34 / 48:10" is often not on
//  screen when the question is asked, but the seek bar keeps telling screen
//  readers where it is. A transcript panel holds far more lines than fit
//  on screen. And the address, which says which video it is, is never in
//  the screenshot of the page itself.
//

import AppKit
import ApplicationServices
import Foundation

/// What lecture mode learned from the front window.
nonisolated struct LecturePageReading: Sendable {
    var pageURL: URL?
    var windowTitle: String?
    var playbackPosition: LecturePlaybackPosition?
    /// Lines of a transcript panel in the page, empty when there is none.
    var transcriptCues: [TimedTranscriptCue] = []
    var showsAnAdvert = false
}

nonisolated enum LecturePageReader {
    /// Browsers built on Chromium leave their pages out of the
    /// accessibility tree until a client asks for it with this attribute,
    /// the switch screen readers and window managers use. Safari and
    /// Firefox always expose the page.
    private static let chromiumBrowserBundleIdentifiers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "company.thebrowser.Browser", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium", "ai.perplexity.comet"
    ]

    /// The tree of a long page (comments, recommendations) can hold tens of
    /// thousands of elements, and every attribute read is a message to the
    /// other app. The player and the transcript panel sit early in it.
    private static let maximumElementsVisited = 6000
    private static let maximumSecondsSpentReading = 1.2
    private static let maximumDepth = 60

    /// Parts of YouTube's page that never hold the player or the
    /// transcript, skipped by their element id to keep within the budget.
    private static let skippedDOMIdentifiers: Set<String> = [
        "comments", "related", "masthead-container", "guide", "guide-wrapper", "chat", "chat-container"
    ]

    /// Runs off the main thread: the accessibility calls block on the
    /// other app, and the question's screen capture runs meanwhile.
    static func readFrontWindow(processIdentifier: pid_t, bundleIdentifier: String?) -> LecturePageReading {
        var reading = LecturePageReading()
        guard AXIsProcessTrusted() else { return reading }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        // A hung app must not hold up the question.
        AXUIElementSetMessagingTimeout(applicationElement, 0.25)
        if let bundleIdentifier, chromiumBrowserBundleIdentifiers.contains(bundleIdentifier) {
            AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else { return reading }
        // The force cast is checked by the type id above.
        let focusedWindow = focusedWindowValue as! AXUIElement
        reading.windowTitle = stringAttribute(kAXTitleAttribute, of: focusedWindow)

        var walk = TreeWalk(startedAt: Date())
        visit(focusedWindow, depth: 0, walk: &walk)

        reading.pageURL = walk.webAreaURL ?? walk.addressBarText.flatMap(LectureVideoPage.pageURL(fromAddressBarText:))
        reading.playbackPosition = walk.seekBarPosition ?? LectureClock.playbackPosition(fromScreenTexts: walk.texts)
        reading.transcriptCues = LectureTranscriptFinder.transcriptCues(inReadingOrder: walk.texts)
        reading.showsAnAdvert = LectureClock.showsAnAdvert(screenTexts: walk.texts)
        return reading
    }

    private struct TreeWalk {
        let startedAt: Date
        var elementsVisited = 0
        var texts: [String] = []
        var webAreaURL: URL?
        var addressBarText: String?
        var seekBarPosition: LecturePlaybackPosition?
        var isInsideWebArea = false

        var isOverBudget: Bool {
            elementsVisited >= LecturePageReader.maximumElementsVisited
                || Date().timeIntervalSince(startedAt) > LecturePageReader.maximumSecondsSpentReading
        }
    }

    private static let attributesReadPerElement = [
        kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        "AXValueDescription", kAXMaxValueAttribute, "AXDOMIdentifier", kAXChildrenAttribute, "AXURL"
    ] as CFArray

    private static func visit(_ element: AXUIElement, depth: Int, walk: inout TreeWalk) {
        guard depth <= maximumDepth, !walk.isOverBudget else { return }
        walk.elementsVisited += 1

        // One message for all of an element's attributes instead of nine.
        var valuesArray: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributesReadPerElement, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &valuesArray) == .success,
              let values = valuesArray as? [AnyObject], values.count == 9 else { return }
        let role = values[0] as? String ?? ""
        let value = values[1]
        let title = (values[2] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = (values[3] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let valueDescription = (values[4] as? String) ?? ""
        let maximumValue = (values[5] as? NSNumber)?.doubleValue
        let domIdentifier = values[6] as? String ?? ""
        let children = values[7] as? [AXUIElement] ?? []

        if skippedDOMIdentifiers.contains(domIdentifier) { return }

        switch role {
        case "AXWebArea":
            if walk.webAreaURL == nil, let pageURL = values[8] as? URL, pageURL.scheme?.hasPrefix("http") == true {
                walk.webAreaURL = pageURL
            }
            let wasInsideWebArea = walk.isInsideWebArea
            walk.isInsideWebArea = true
            for child in children { visit(child, depth: depth + 1, walk: &walk) }
            walk.isInsideWebArea = wasInsideWebArea
            return
        case "AXStaticText":
            if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 600 {
                walk.texts.append(text)
            }
        case "AXSlider":
            if walk.seekBarPosition == nil {
                walk.seekBarPosition = seekBarPosition(label: description.isEmpty ? title : description,
                                                       valueDescription: valueDescription,
                                                       value: (value as? NSNumber)?.doubleValue, maximumValue: maximumValue)
            }
        case "AXTextField", "AXComboBox":
            // The browser's own address bar, outside the page. Safari and
            // Chrome show it without the scheme.
            if !walk.isInsideWebArea, walk.addressBarText == nil, let text = value as? String,
               LectureVideoPage.pageURL(fromAddressBarText: text) != nil {
                walk.addressBarText = text
            }
        default:
            // A transcript line's button carries its time in its label,
            // and on some pages that label is all the tree has of it.
            let label = description.isEmpty ? title : description
            if walk.isInsideWebArea, !label.isEmpty, label.count <= 600 {
                switch LectureTranscriptFinder.classify(label) {
                case .timestampOnly, .timestampedText: walk.texts.append(label)
                case .plainText: break
                }
            }
        }

        for child in children { visit(child, depth: depth + 1, walk: &walk) }
    }

    /// A player's seek bar: its description for screen readers ("12
    /// Minutes 34 Seconds of 48 Minutes 10 Seconds"), or failing that its
    /// value in seconds when it is labelled as a seek or progress bar.
    /// The volume slider is neither.
    private static func seekBarPosition(label: String, valueDescription: String, value: Double?,
                                        maximumValue: Double?) -> LecturePlaybackPosition? {
        if let position = LectureClock.playbackPosition(fromSeekBarDescription: valueDescription) { return position }
        let lowercasedLabel = label.lowercased()
        guard lowercasedLabel.contains("seek") || lowercasedLabel.contains("progress") || lowercasedLabel.contains("timeline"),
              let value, let maximumValue, maximumValue > 30, value >= 0, value <= maximumValue else { return nil }
        return LecturePlaybackPosition(currentSeconds: Int(value), totalSeconds: Int(maximumValue))
    }

    /// Only the title, for the once-a-second check on what is in front.
    static func focusedWindowTitle(processIdentifier: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.1)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else { return nil }
        // The force cast is checked by the type id above.
        return stringAttribute(kAXTitleAttribute, of: focusedWindowValue as! AXUIElement)
    }

    private static func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return nil }
        return attributeValue as? String
    }
}
