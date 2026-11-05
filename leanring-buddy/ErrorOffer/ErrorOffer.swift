//
//  ErrorOffer.swift
//  leanring-buddy
//
//  "Explain this error?" When a stack trace, a failing test, a compiler
//  error or a judge's verdict appears in front of the student, a soft red
//  halo glows under the notch, which says "An error on screen." Hovering
//  opens the notch on the error card; Explain this error there, or one
//  press of the talk keys without speaking, and the error is explained
//  through the ordinary answer, ringing the line it points to. Ignored, the
//  glow fades after 20 seconds and never comes back for the same error;
//  Not now lets it go at once.
//
//  Nothing leaves the Mac and no model is asked until the student presses.
//  ErrorWatcher finds the error; this file decides whether to offer it,
//  draws the glow, and writes the turn note that names the error's lines
//  and their screen index ids when the question goes out.
//
//  There is no switch for it. It keeps out of the way instead: never while
//  Buddy is answering, guiding or listening, never in a Focus when the
//  Focus state can be read, never more than once a minute.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class ErrorOfferController {
    /// What is sent as the student's question when they accept.
    static let question = "explain this error"

    /// Sends the question through the normal pipeline, as a typed one is.
    var onExplainRequested: (String) -> Void = { _ in }
    /// True while Buddy answers, speaks, guides or listens.
    var isBuddyBusy: () -> Bool = { false }
    var isDictationInProgress: () -> Bool = { false }
    /// The notch's black shape as last laid out, for placing the glow.
    var notchShapeSize: () -> CGSize = { .zero }
    /// Whether the notch is open. Open, the card is on screen and the halo
    /// is not needed; and an offer the student is reading is not taken away
    /// when its 20 seconds run out.
    var isNotchOpen: () -> Bool = { false }
    /// Told when an offer appears or goes, for the notch's error row and
    /// the Lesson tab's error card.
    var onOfferChanged: (NotchErrorOffer?) -> Void = { _ in }

    private let watcher = ErrorWatcher()
    private lazy var glow = ErrorGlowWindows()

    private var offeredError: DetectedScreenError?
    private var fadeTask: Task<Void, Never>?
    private var lastGlowAt: Date?
    /// The offer was up when the talk keys went down, so letting them go
    /// without a word accepts it.
    private var offerWasUpWhenTalkKeysWentDown = false
    private var waitForSilentPressTask: Task<Void, Never>?
    /// The error being asked about, until the question carrying it goes out.
    private var errorAwaitingQuestion: (error: DetectedScreenError, askedAt: Date)?

    private static let glowLastsSeconds: TimeInterval = 20
    private static let minimumSecondsBetweenGlows: TimeInterval = 60

    func start() {
        watcher.isAllowedToRead = { [weak self] in
            guard let self else { return false }
            if self.offeredError != nil || self.isBuddyBusy() || FocusModeProbe.isFocusOn() { return false }
            if let lastGlowAt = self.lastGlowAt, Date().timeIntervalSince(lastGlowAt) < Self.minimumSecondsBetweenGlows { return false }
            return true
        }
        watcher.onErrorAppeared = { [weak self] error in self?.offer(error) }
        watcher.onFrontApplicationChanged = { [weak self] in self?.withdraw(reason: "the student switched apps") }
        watcher.start()
    }

    // MARK: Offering

    private func offer(_ error: DetectedScreenError) {
        // Checked again: Buddy may have started answering during the read.
        guard offeredError == nil, !isBuddyBusy() else { return }
        offeredError = error
        lastGlowAt = Date()
        TutorDebugLog.write("💡 offering to explain a \(error.recognized.kind.rawValue) in \(error.applicationName)")
        glow.show(shapeSize: notchShapeSize, isNotchOpen: isNotchOpen)
        onOfferChanged(Self.notchOffer(for: error))
        // One announcement, never a sound: VoiceOver users get the same
        // offer the glow makes.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "Buddy noticed an error on screen. Open the notch to have it explained.",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.glowLastsSeconds * 1_000_000_000))
            // Opened during the glow, the card stays until the notch closes
            // or the student answers it.
            while let self, !Task.isCancelled, self.isNotchOpen() {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.withdraw(reason: "ignored")
        }
    }

    /// The error as the card shows it: the message, and where it points as
    /// "at render, app.js line 14" when the trace says.
    static func notchOffer(for error: DetectedScreenError) -> NotchErrorOffer {
        var locationLine: String?
        if let fileName = error.recognized.causeFileName {
            var place = (fileName as NSString).lastPathComponent
            if let lineNumber = error.recognized.causeLineNumber { place += " line \(lineNumber)" }
            // "at render (/path/app.js:14:23)" names the function first.
            if let causeText = error.causeText, causeText.hasPrefix("at ") {
                let functionName = causeText.dropFirst(3).prefix(while: { $0 != " " && $0 != "(" })
                if !functionName.isEmpty, !functionName.contains("/") { place = "at \(functionName), " + place }
            }
            locationLine = place
        } else if let causeText = error.causeText {
            locationLine = String(causeText.prefix(120))
        }
        return NotchErrorOffer(applicationName: error.applicationName,
                               messageLine: String(error.messageText.prefix(200)),
                               locationLine: locationLine)
    }

    /// The glow goes. The error's fingerprint stays remembered by the
    /// watcher, so the same error never glows again.
    private func withdraw(reason: String) {
        guard offeredError != nil else { return }
        TutorDebugLog.write("💡 error offer withdrawn: \(reason)")
        offeredError = nil
        offerWasUpWhenTalkKeysWentDown = false
        fadeTask?.cancel()
        fadeTask = nil
        glow.hide()
        onOfferChanged(nil)
    }

    private func accept(how: String) {
        guard let offeredError else { return }
        TutorDebugLog.write("💡 error offer accepted by \(how)")
        errorAwaitingQuestion = (offeredError, Date())
        withdraw(reason: "accepted")
        onExplainRequested(Self.question)
    }

    // MARK: What the student does

    /// Explain this error on the notch's card, or Return in its chat box.
    func studentChoseExplain() {
        accept(how: "Explain this error in the notch")
    }

    /// Not now on the card. The watcher remembers the error's fingerprint,
    /// so it is not offered again this session.
    func studentChoseNotNow() {
        waitForSilentPressTask?.cancel()
        withdraw(reason: "Not now")
    }

    /// The glow is never shown while the student talks, but the offer
    /// stays, so letting go without a word can still accept it.
    func talkKeysPressed() {
        waitForSilentPressTask?.cancel()
        offerWasUpWhenTalkKeysWentDown = offeredError != nil
        if offerWasUpWhenTalkKeysWentDown {
            fadeTask?.cancel()
            glow.hide()
        }
    }

    /// `listeningBegan` is false for a tap, let go before the microphone
    /// opened. After a longer press, the answer is whether any words were
    /// heard, which is known once dictation finishes.
    func talkKeysReleased(listeningBegan: Bool) {
        guard offerWasUpWhenTalkKeysWentDown, offeredError != nil else { return }
        guard listeningBegan else {
            accept(how: "a tap of the talk keys")
            return
        }
        waitForSilentPressTask?.cancel()
        waitForSilentPressTask = Task { [weak self] in
            // Bounded: at most a few seconds after one press, never a loop
            // that runs on its own.
            let releasedAt = Date()
            while let self, Date().timeIntervalSince(releasedAt) < 4 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, self.offerWasUpWhenTalkKeysWentDown else { return }
                if !self.isDictationInProgress() {
                    // A transcript lands just after dictation ends.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled, self.offerWasUpWhenTalkKeysWentDown else { return }
                    self.accept(how: "a press of the talk keys without speaking")
                    return
                }
            }
            self?.withdraw(reason: "the press did not finish")
        }
    }

    /// Control + Option + T: they want to type, not this.
    func studentStartedTyping() {
        waitForSilentPressTask?.cancel()
        withdraw(reason: "the student opened the chat")
    }

    /// Called for every question on its way to the model. Returns the error
    /// when the question is the one accepting the offer; any other question
    /// means the student moved on, and the offer goes.
    func errorAskedAbout(question: String) -> DetectedScreenError? {
        if let errorAwaitingQuestion, question == Self.question,
           Date().timeIntervalSince(errorAwaitingQuestion.askedAt) < 10 {
            self.errorAwaitingQuestion = nil
            return errorAwaitingQuestion.error
        }
        errorAwaitingQuestion = nil
        waitForSilentPressTask?.cancel()
        withdraw(reason: "another question was asked")
        return nil
    }

    // MARK: The turn note

    /// What the model is told on the turn that explains the error: which
    /// lines are the error and which line to ring, by screen index id when
    /// the line was listed, by its box on the canvas otherwise.
    static func turnNote(for error: DetectedScreenError, listedLabels: [String: String],
                         canvasSize: CGSize, displayFrame: CGRect) -> String {
        func listedIdentifier(for lineText: String?) -> String? {
            guard let lineText else { return nil }
            return ErrorWindowReading.bestListedIdentifier(for: lineText, among: listedLabels)
        }
        func canvasBox(forLine lineIndex: Int?) -> String? {
            guard let lineIndex, let rect = error.rectsInGlobalTopLeftPoints[lineIndex],
                  let box = canvasRect(fromGlobalTopLeft: rect, displayFrame: displayFrame, canvasSize: canvasSize) else { return nil }
            return "[\(Int(box.minX)), \(Int(box.minY)), \(Int(box.width)), \(Int(box.height))]"
        }
        func reference(_ text: String?, lineIndex: Int?) -> String? {
            guard let text else { return nil }
            if let identifier = listedIdentifier(for: text) { return "\(identifier) (\"\(text.prefix(140))\")" }
            if let box = canvasBox(forLine: lineIndex) { return "\"\(text.prefix(140))\" at \(box) on the canvas" }
            return "\"\(text.prefix(140))\""
        }

        let recognized = error.recognized
        let message = reference(error.messageText, lineIndex: recognized.messageLineIndex) ?? "\"\(error.messageText)\""
        var lines = [
            "THEY ASKED ABOUT THE ERROR ON SCREEN",
            "a \(recognized.kind.rawValue) just appeared in \(error.applicationName). they pressed to have it explained without saying anything else, so explain this error and nothing else on the screen.",
            "- the error: \(message)."
        ]
        var ringTarget = message
        if let cause = reference(error.causeText, lineIndex: recognized.causeLineIndex) {
            var whereItPoints = "- it points at"
            if let fileName = recognized.causeFileName { whereItPoints += " \(fileName)" }
            if let lineNumber = recognized.causeLineNumber { whereItPoints += " line \(lineNumber)" }
            lines.append(whereItPoints + ": \(cause).")
            ringTarget = cause
        }
        if let code = reference(error.causeCodeText, lineIndex: recognized.causeCodeLineIndex) {
            lines.append("- the line of their code it prints: \(code).")
            ringTarget = code
        }
        lines.append("- ring the line in their own code that caused it: \(ringTarget). if their editor is on screen showing \(recognized.causeFileName ?? "that file")\(recognized.causeLineNumber.map { " at line \($0)" } ?? ""), ring that line in the editor instead. ring the error message as well only if it helps.")
        lines.append("- first sentence: what went wrong, in plain words, using the real name or value from the message. then why that line does it, and the one change to try. never read the trace aloud or walk through every frame.")
        if error.place == .judgeSite {
            lines.append("- this is a judge's verdict on a practice problem: say what kind of input breaks their code and where, not the whole solution, unless they ask for it.")
        }
        return lines.joined(separator: "\n")
    }

    /// Global screen points with the origin at the top left of the main
    /// display, to the canvas's pixels. `displayFrame` is in AppKit's
    /// coordinates, origin at the bottom left of the main display.
    static func canvasRect(fromGlobalTopLeft rect: CGRect, displayFrame: CGRect, canvasSize: CGSize) -> CGRect? {
        guard displayFrame.width > 0, displayFrame.height > 0,
              let mainDisplayHeight = NSScreen.screens.first?.frame.height else { return nil }
        let displayTopInTopLeftPoints = mainDisplayHeight - displayFrame.maxY
        let scaleX = canvasSize.width / displayFrame.width
        let scaleY = canvasSize.height / displayFrame.height
        let canvasBox = CGRect(x: (rect.minX - displayFrame.minX) * scaleX,
                               y: (rect.minY - displayTopInTopLeftPoints) * scaleY,
                               width: rect.width * scaleX, height: rect.height * scaleY)
        // A line on another display is not on this canvas.
        guard CGRect(origin: .zero, size: canvasSize).intersects(canvasBox) else { return nil }
        return canvasBox
    }
}

// MARK: - Focus

/// Whether a Focus (Do Not Disturb, Work, Sleep...) is on. macOS has no
/// public way to ask without a permission prompt; its own record of active
/// Focus modes is readable only with Full Disk Access. When it cannot be
/// read, Focus is taken as off, and the other limits still apply.
@MainActor
enum FocusModeProbe {
    private static var cachedAnswer: (isOn: Bool, checkedAt: Date)?

    static func isFocusOn() -> Bool {
        if let cachedAnswer, Date().timeIntervalSince(cachedAnswer.checkedAt) < 30 { return cachedAnswer.isOn }
        let isOn = readFocusAssertions()
        cachedAnswer = (isOn, Date())
        return isOn
    }

    private static func readFocusAssertions() -> Bool {
        let assertionsFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: assertionsFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stores = root["data"] as? [[String: Any]] else { return false }
        return stores.contains { store in
            !((store["storeAssertionRecords"] as? [Any]) ?? []).isEmpty
        }
    }
}
