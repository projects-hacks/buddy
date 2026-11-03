//
//  CalibrationSnapshot.swift
//  leanring-buddy
//
//  Captures the screen with the overlay's own marks included, so whether a
//  mark lands on the text it was meant for can be checked by looking rather
//  than inferred.
//
//  Why this exists: every alignment judgement until now came from the user
//  photographing their screen after an answer had finished, by which point
//  the page may have scrolled, and from estimating pixel scales by eye. That
//  produced theories (a notch safe-area offset, letterboxing) that each took
//  a round trip to rule out. A capture taken by the app itself, at the moment
//  of drawing, with the marks and the text in one image, settles it directly.
//
//  The normal capture path deliberately excludes this app's windows so the
//  model never sees its own annotations. This one deliberately includes them.
//

import AppKit
import ScreenCaptureKit

enum CalibrationSnapshot {
    /// Where the snapshot is written. Beside the debug log, so the two are
    /// read together.
    static let outputURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClickyLocal-calibration.png")

    /// Presence of this file asks the running app to calibrate. A file rather
    /// than a menu item so it can be triggered from a terminal without the
    /// user having to speak or click anything.
    static let triggerURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClickyLocal.calibrate")

    /// A question written here is asked as if it had been spoken.
    static let askURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClickyLocal.ask")

    /// Opens the notch on the tab named in this file (lesson, transcript or
    /// settings) for a few seconds, so its open state can be snapshotted
    /// without anyone hovering over it.
    static let openNotchURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClickyLocal.notch")

    /// Presence of this file takes a snapshot of the screen with the drawing.
    static let snapshotTriggerURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClickyLocal.snapshot")

    /// Captures the display under the cursor, this app's overlay included.
    static func captureIncludingOverlay() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let mouseLocation = NSEvent.mouseLocation
        let screenUnderCursor = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main

        let displayIdentifier = screenUnderCursor?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

        guard let display = content.displays.first(where: { candidate in
            candidate.displayID == displayIdentifier
        }) ?? content.displays.first else {
            throw NSError(domain: "Calibration", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display to capture"])
        }

        // Nothing excluded: the overlay is the thing being checked.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Native point size, so one pixel in the image is one point on screen
        // and a mark's offset can be read straight off the picture.
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let pngData = NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Calibration", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode snapshot"])
        }

        try pngData.write(to: outputURL)
    }
}
