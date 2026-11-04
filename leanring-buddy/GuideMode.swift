//
//  GuideMode.swift
//  leanring-buddy
//
//  Helping someone do something in an app they do not know yet, one step at
//  a time: Buddy says the step and points at the control, then watches for
//  it to be done and says the next one without being asked.
//
//  The model starts a guide itself. When a question is a task in an app
//  ("how do I export this", "where do I turn on dark mode"), its answer gives
//  only the first step and ends with waitForStep(...). There is no button and
//  no mode to switch on; a question that is not a task never gets one.
//
//  Watching costs nothing. Nothing is captured until the student clicks,
//  presses a key or scrolls, and then the screen is compared, on the Mac, as
//  a 96 x 60 grey thumbnail against the one from when the step was given.
//  The model is asked again only when the student acted and the screen
//  visibly changed: one ordinary answer, the same as asking "what next?".
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

/// The step the student was just given, as the program stated it.
struct GuideStep: Equatable {
    /// What they were asked to do: "click Export in the top right".
    let instruction: String
    /// What the screen shows once it is done: "a save dialog".
    let doneWhen: String
}

enum GuideMode {
    /// A long task is still finished well inside this; a guide that runs
    /// past it is lost, and each step is a paid answer.
    static let maximumSteps = 15
    /// A step not done in this long has been abandoned.
    static let giveUpAfterSeconds: TimeInterval = 300

    /// The waitForStep("...", "...") line of a program, if it has one.
    static func step(inProgram program: String) -> GuideStep? {
        let pattern = #"waitForStep\(\s*"((?:[^"\\]|\\.)*)"\s*(?:,\s*"((?:[^"\\]|\\.)*)"\s*)?\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(program.startIndex..., in: program)
        guard let match = expression.matches(in: program, range: range).last,
              let instructionRange = Range(match.range(at: 1), in: program) else { return nil }
        let instruction = unescaped(String(program[instructionRange]))
        guard !instruction.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var doneWhen = ""
        if let doneRange = Range(match.range(at: 2), in: program) {
            doneWhen = unescaped(String(program[doneRange]))
        }
        return GuideStep(instruction: instruction, doneWhen: doneWhen)
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// What the next turn is told when the screen changed after a step. It
    /// stands in for the student's words, since they said nothing.
    static func continuationQuestion(after step: GuideStep) -> String {
        "(guide) the screen changed after you asked me to: \(step.instruction)"
    }

    /// `changedRegion` is where the screen changed, as fractions of it with
    /// the origin at the top left, and is turned into canvas pixels.
    static func continuationNote(after step: GuideStep, stepNumber: Int, changedRegion: CGRect?, canvasSize: CGSize) -> String {
        var whereItChanged = ""
        if let changedRegion {
            let x = Int(changedRegion.minX * canvasSize.width), y = Int(changedRegion.minY * canvasSize.height)
            let width = Int(changedRegion.width * canvasSize.width), height = Int(changedRegion.height * canvasSize.height)
            whereItChanged = " what changed is the area at [\(x), \(y), \(width), \(height)] on the canvas: look there first. a menu that opened, a dialog or a new window there means the step is done."
        }
        return """
        GUIDING THEM THROUGH A TASK
        you are walking them through a task in this app, and this is step \(stepNumber + 1). the last step you gave was: \(step.instruction). \(step.doneWhen.isEmpty ? "" : "once done, the screen shows: \(step.doneWhen).")
        they said nothing: they clicked, typed or scrolled and the screen changed, so you are looking again on your own.\(whereItChanged) answer with the program only, as always, never a word of thinking before it.
        - if that step is done, give the next one the same way: one or two short sentences, point at the exact control, waitForStep(...) at the end.
        - if they went somewhere else by mistake, say in one sentence how to get back, point at it, and waitForStep(...) again.
        - if it is not done yet and nothing went wrong (they are still typing, a menu is half open), write only waitForStep(...) with the same step and nothing else: no say(), no marks. they do not need to hear from you.
        - if they are plainly doing something unrelated now, write a program with no say() and no waitForStep(): the guide ends quietly.
        - if the whole task is finished, say so in one short sentence and do not call waitForStep. that ends the guide.
        """
    }
}

/// Watches for the student to do the step, without the model.
@MainActor
final class GuideWatcher {
    /// Called once, when the student acted and the screen visibly changed,
    /// with where it changed: fractions of the screen, origin top left.
    var onStepLooksDone: (CGRect) -> Void = { _ in }

    private var baseline: [UInt8]?
    private var displayFrame: CGRect = .zero
    /// The app the step is in, and the step's own words. A switch to some
    /// other app (replying to a message, say) changes the whole screen but
    /// is not the step, unless the step names that app.
    private var guidedApplication: NSRunningApplication?
    private var stepWords = ""
    private var inputMonitors: [Any] = []
    private var pendingCheck: Task<Void, Never>?
    private var firstUncheckedInputAt: Date?
    private var giveUpTask: Task<Void, Never>?
    private var isChecking = false

    private(set) var isWatching = false

    /// The grid the screen is reduced to. Small enough to compare in
    /// microseconds, fine enough that a menu, a dialog or a selected row
    /// still changes dozens of cells.
    private static let gridWidth = 96
    private static let gridHeight = 60
    /// A cell counts as changed past this much brightness, so JPEG noise and
    /// anti-aliasing do not.
    private static let cellChangeThreshold = 26
    /// A blinking caret or the pointer is two or three cells; a step is more.
    private static let changedCellsForAStep = 9
    /// The menu bar's clock and status icons tick on their own.
    private static let ignoredTopRows = 2

    /// Starts watching. `baselineScreenshot` is the screen as it was when the
    /// step was given, so a step done while Buddy was still talking is
    /// noticed straight away rather than missed.
    func watch(step: GuideStep, baselineScreenshot: Data, displayFrame: CGRect, guidedApplication: NSRunningApplication?) {
        stop()
        guard let baseline = Self.thumbnail(fromImageData: baselineScreenshot) else { return }
        self.baseline = baseline
        self.displayFrame = displayFrame
        self.guidedApplication = guidedApplication
        stepWords = (step.instruction + " " + step.doneWhen).lowercased()
        isWatching = true

        let events: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .keyDown, .scrollWheel]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            Task { @MainActor in self?.studentActed() }
        }) {
            inputMonitors.append(monitor)
        }
        giveUpTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(GuideMode.giveUpAfterSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            TutorDebugLog.write("🧭 guide: no progress in \(Int(GuideMode.giveUpAfterSeconds))s, stopping")
            self?.stop()
        }
        // Done during the explanation already?
        scheduleCheck(after: 0.1)
    }

    func stop() {
        isWatching = false
        baseline = nil
        inputMonitors.forEach(NSEvent.removeMonitor)
        inputMonitors = []
        pendingCheck?.cancel()
        pendingCheck = nil
        giveUpTask?.cancel()
        giveUpTask = nil
        firstUncheckedInputAt = nil
    }

    /// A click, key or scroll. The check waits for the screen to settle, and
    /// is pushed back while input keeps coming, but never more than two
    /// seconds, so steady typing is still looked at.
    private func studentActed() {
        guard isWatching else { return }
        let now = Date()
        if firstUncheckedInputAt == nil { firstUncheckedInputAt = now }
        let waitedSoFar = now.timeIntervalSince(firstUncheckedInputAt ?? now)
        scheduleCheck(after: waitedSoFar > 2.0 ? 0.2 : 0.7)
    }

    private func scheduleCheck(after seconds: TimeInterval) {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.checkScreen()
        }
    }

    private func checkScreen() async {
        guard isWatching, !isChecking, let baseline else { return }
        if let front = NSWorkspace.shared.frontmostApplication, let guidedApplication,
           front.processIdentifier != guidedApplication.processIdentifier,
           front.bundleIdentifier != Bundle.main.bundleIdentifier,
           !stepWords.contains((front.localizedName ?? "\u{0}").lowercased()) {
            TutorDebugLog.write("🧭 guide: in \(front.localizedName ?? "another app"), not counted")
            return
        }
        isChecking = true
        defer { isChecking = false }
        firstUncheckedInputAt = nil
        guard let current = await Self.captureThumbnail(of: displayFrame) else { return }
        guard isWatching else { return }
        let (changedCells, changedRegion) = Self.changes(baseline, current)
        TutorDebugLog.write("🧭 guide: \(changedCells) cells changed")
        if changedCells >= Self.changedCellsForAStep {
            stop()
            onStepLooksDone(changedRegion)
        }
    }

    /// How many cells changed, and the box around them. Row 0 of the
    /// thumbnail is the top of the screen.
    private static func changes(_ first: [UInt8], _ second: [UInt8]) -> (count: Int, region: CGRect) {
        guard first.count == second.count else { return (0, .zero) }
        var count = 0
        var minColumn = gridWidth, maxColumn = -1, minRow = gridHeight, maxRow = -1
        for index in (ignoredTopRows * gridWidth)..<first.count
        where abs(Int(first[index]) - Int(second[index])) > cellChangeThreshold {
            count += 1
            let column = index % gridWidth, row = index / gridWidth
            minColumn = min(minColumn, column); maxColumn = max(maxColumn, column)
            minRow = min(minRow, row); maxRow = max(maxRow, row)
        }
        guard count > 0 else { return (0, .zero) }
        let region = CGRect(
            x: CGFloat(minColumn) / CGFloat(gridWidth), y: CGFloat(minRow) / CGFloat(gridHeight),
            width: CGFloat(maxColumn - minColumn + 1) / CGFloat(gridWidth),
            height: CGFloat(maxRow - minRow + 1) / CGFloat(gridHeight))
        return (count, region)
    }

    // MARK: Thumbnails

    private static func thumbnail(fromImageData data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return thumbnail(of: image)
    }

    private static func thumbnail(of image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: gridWidth, height: gridHeight,
                bitsPerComponent: 8, bytesPerRow: gridWidth,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))
            return true
        }
        return drew ? pixels : nil
    }

    /// A small capture of one display, Buddy's own windows and the pointer
    /// left out, so the drawing and the notch never count as a change.
    private static func captureThumbnail(of displayFrame: CGRect) async -> [UInt8]? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let screenNumberForFrame = NSScreen.screens.first { $0.frame == displayFrame }?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == screenNumberForFrame })
                ?? content.displays.first else { return nil }

        let configuration = SCStreamConfiguration()
        configuration.width = 384
        configuration.height = max(1, Int(384 * CGFloat(display.height) / CGFloat(max(display.width, 1))))
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            return nil
        }
        return thumbnail(of: image)
    }
}
