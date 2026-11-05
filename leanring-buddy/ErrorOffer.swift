//
//  ErrorOffer.swift
//  leanring-buddy
//
//  "Explain this error?" When a stack trace, a failing test, a compiler
//  error or a judge's verdict appears in front of the student, the notch
//  glows softly with "explain this error?". One press of the talk keys
//  without speaking, or a click on the glow, and the error is explained
//  through the ordinary answer, ringing the line it points to. Ignored, the
//  glow fades after 20 seconds and never comes back for the same error.
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

    private let watcher = ErrorWatcher()
    private lazy var glow = ErrorGlowWindows(onClick: { [weak self] in self?.studentClickedGlow() })

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
        glow.show(shapeSize: notchShapeSize)
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.glowLastsSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.withdraw(reason: "ignored")
        }
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
    }

    private func accept(how: String) {
        guard let offeredError else { return }
        TutorDebugLog.write("💡 error offer accepted by \(how)")
        errorAwaitingQuestion = (offeredError, Date())
        withdraw(reason: "accepted")
        onExplainRequested(Self.question)
    }

    // MARK: What the student does

    private func studentClickedGlow() {
        accept(how: "a click on the glow")
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

// MARK: - The glow

/// Two small windows at the top of the notch screen: a soft halo behind
/// the notch, which takes no clicks, and the label just under the notch's
/// shape, which does. The notch's own window sits above both, so the halo
/// seems to come from behind the black shape.
@MainActor
private final class ErrorGlowWindows {
    private let onClick: () -> Void
    private var haloPanel: NSPanel?
    private var labelPanel: NSPanel?
    private let appearance = ErrorGlowAppearance()
    private var shapeSize: () -> CGSize = { .zero }
    /// Runs only while the glow shows, at most 20 seconds, so the label
    /// follows the notch when it grows or shrinks under it.
    private var followNotchTimer: Timer?

    private static let labelSize = CGSize(width: 214, height: 30)
    private static let haloMargin: CGFloat = 40

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
    }

    private static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// The camera housing's size when the notch has not reported its shape.
    private static func housingSize(of screen: NSScreen) -> CGSize {
        let height = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return CGSize(width: 180, height: height)
        }
        return CGSize(width: max(120, right.minX - left.maxX), height: height)
    }

    func show(shapeSize: @escaping () -> CGSize) {
        self.shapeSize = shapeSize
        if haloPanel == nil { haloPanel = makePanel(acceptsClicks: false, content: AnyView(ErrorGlowHalo(appearance: appearance))) }
        if labelPanel == nil {
            labelPanel = makePanel(acceptsClicks: true, content: AnyView(ErrorGlowLabel(appearance: appearance, onClick: { [weak self] in
                self?.onClick()
            })))
        }
        place()
        haloPanel?.orderFrontRegardless()
        labelPanel?.orderFrontRegardless()
        withAnimation(.easeOut(duration: 0.45)) { appearance.isVisible = true }
        followNotchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followNotchTimer = timer
    }

    func hide() {
        followNotchTimer?.invalidate()
        followNotchTimer = nil
        withAnimation(.easeIn(duration: 0.5)) { appearance.isVisible = false }
        // Taken off screen once faded, so nothing is left to catch clicks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, !self.appearance.isVisible else { return }
            self.haloPanel?.orderOut(nil)
            self.labelPanel?.orderOut(nil)
        }
    }

    private func place() {
        guard let screen = Self.notchScreen else { return }
        let reported = shapeSize()
        let shape = reported.width > 0 && reported.height > 0 ? reported : Self.housingSize(of: screen)
        appearance.shapeSize = shape
        let haloSize = CGSize(width: shape.width + Self.haloMargin * 2, height: shape.height + Self.haloMargin)
        haloPanel?.setFrame(NSRect(x: screen.frame.midX - haloSize.width / 2, y: screen.frame.maxY - haloSize.height,
                                   width: haloSize.width, height: haloSize.height), display: true)
        labelPanel?.setFrame(NSRect(x: screen.frame.midX - Self.labelSize.width / 2,
                                    y: screen.frame.maxY - shape.height - 8 - Self.labelSize.height,
                                    width: Self.labelSize.width, height: Self.labelSize.height), display: true)
    }

    private func makePanel(acceptsClicks: Bool, content: AnyView) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.labelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Just under the notch, which is one above .screenSaver, so the
        // black shape covers the centre of the halo.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = !acceptsClicks
        // Non-activating, so a click on the label leaves the app with the
        // error in front: its name and window are what the answer is about.
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        return panel
    }
}

@MainActor
private final class ErrorGlowAppearance: ObservableObject {
    @Published var isVisible = false
    @Published var shapeSize: CGSize = .zero
}

/// Warm, so it reads as "something went wrong" without the alarm of red.
private let errorGlowColour = Color(red: 1.0, green: 0.62, blue: 0.28)

private struct ErrorGlowHalo: View {
    @ObservedObject var appearance: ErrorGlowAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathingIn = false

    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
            .fill(errorGlowColour.opacity(isBreathingIn ? 0.75 : 0.45))
            .frame(width: appearance.shapeSize.width, height: appearance.shapeSize.height)
            .blur(radius: 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(appearance.isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { isBreathingIn = true }
            }
    }
}

private struct ErrorGlowLabel: View {
    @ObservedObject var appearance: ErrorGlowAppearance
    let onClick: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(errorGlowColour)
                Text("explain this error?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(isHovered ? 1 : 0.9))
                Text("\u{2303}\u{2325}")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Capsule()
                    .fill(Color.black.opacity(isHovered ? 0.92 : 0.82))
                    .overlay(Capsule().strokeBorder(errorGlowColour.opacity(isHovered ? 0.9 : 0.55), lineWidth: 1))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .help("Explain this error. Or tap Control + Option without speaking.")
        .accessibilityLabel("Explain this error")
        .opacity(appearance.isVisible ? 1 : 0)
        .allowsHitTesting(appearance.isVisible)
    }
}
