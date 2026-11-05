//
//  TutorDebugLog.swift
//  leanring-buddy
//
//  Appends diagnostics to a file alongside the usual console output.
//
//  Why a file: a menu bar app launched normally has nowhere to print. Running
//  the binary from a terminal does surface stdout, but macOS then attributes
//  microphone and screen access to the terminal rather than to the app, so the
//  permissions under test stop behaving like the real thing. Writing to a file
//  keeps the app launching the way a user launches it while still leaving a
//  record of what the model actually returned and which marks resolved.
//
//  Local only, never transmitted. Each launch starts a fresh file and keeps
//  the one before as Buddy.previous.log, so a crash or force quit followed
//  by a normal relaunch still leaves its record; a session's file is moved
//  aside to Buddy.rotated.log once it passes 5 MB.
//

import Foundation

/// Written from every thread: audio, network and accessibility work log too.
nonisolated enum TutorDebugLog {
    /// `~/Library/Logs/Buddy.log`, the conventional place for an app's
    /// own log and readable without elevated permissions.
    static let fileURL: URL = {
        let logsDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return logsDirectory.appendingPathComponent("\(AppIdentity.dataName).log")
    }()

    /// The last session's log, kept at launch.
    static var previousFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("\(AppIdentity.dataName).previous.log")
    }

    /// This session's earlier part, once its log passed `largestFileBytes`.
    static var rotatedFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("\(AppIdentity.dataName).rotated.log")
    }

    static let largestFileBytes = 5 * 1024 * 1024

    /// The line written when Buddy quits normally. A previous log that does
    /// not end with it ended in a crash, a force quit or a power loss.
    static let cleanQuitLine = "=== Buddy quit ==="

    /// Serialises writes, since the pipeline logs from several tasks.
    private static let writeQueue = DispatchQueue(label: "buddy.debug-log")

    // Touched only on `writeQueue`.
    nonisolated(unsafe) private static var bytesWrittenThisFile = 0
    nonisolated(unsafe) private static var lastEntry = ""

    /// Starts a fresh file, so a session's log is only that session, and
    /// keeps the last session's as the previous log.
    static func beginSession() {
        writeQueue.async {
            let fileManager = FileManager.default
            var previousSessionEndedCleanly = true
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               (attributes[.size] as? Int ?? 0) > 0 {
                previousSessionEndedCleanly = lastLineOfFile(at: fileURL) == cleanQuitLine
                try? fileManager.removeItem(at: previousFileURL)
                try? fileManager.moveItem(at: fileURL, to: previousFileURL)
            }
            try? fileManager.removeItem(at: rotatedFileURL)
            let header = "=== Buddy session \(timestamp()) ===\n"
            try? header.write(to: fileURL, atomically: true, encoding: .utf8)
            bytesWrittenThisFile = header.utf8.count
            if !previousSessionEndedCleanly {
                appendOnQueue("[\(timestamp())] ⚠️ the last session ended without quitting (a crash, force quit or power loss); its log is \(previousFileURL.lastPathComponent)\n")
            }
        }
    }

    /// Marks the session as ended normally; called as the app quits, and
    /// waited for, since the process ends right after.
    static func endSession() {
        writeQueue.sync {
            appendOnQueue("\(cleanQuitLine)\n")
        }
    }

    /// Writes one entry, and mirrors it to stdout for terminal runs.
    static func write(_ message: String) {
        print(message)

        writeQueue.async {
            lastEntry = message
            appendOnQueue("[\(timestamp())] \(message)\n")
        }
    }

    /// The most recent entry, for saying what was going on when something
    /// went wrong. Never called on the log's own queue.
    static func mostRecentEntry() -> String {
        writeQueue.sync { lastEntry }
    }

    /// Writes at once, on the calling thread, for an exception about to end
    /// the process: the queue may never get to run again.
    static func writeImmediately(_ message: String) {
        let entry = "[\(timestamp())] \(message)\n"
        guard let entryData = entry.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: entryData)
    }

    /// Called only on `writeQueue`.
    private static func appendOnQueue(_ entry: String) {
        guard let entryData = entry.data(using: .utf8) else { return }
        if bytesWrittenThisFile + entryData.count > largestFileBytes {
            // The newest part of the session is what explains a problem,
            // so the older part is moved aside rather than the new dropped.
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: rotatedFileURL)
            try? fileManager.moveItem(at: fileURL, to: rotatedFileURL)
            let header = "=== Buddy session continued \(timestamp()), earlier part in \(rotatedFileURL.lastPathComponent) ===\n"
            try? header.write(to: fileURL, atomically: true, encoding: .utf8)
            bytesWrittenThisFile = header.utf8.count
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: entryData)
        } else {
            try? entry.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        bytesWrittenThisFile += entryData.count
    }

    private static func lastLineOfFile(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let tailLength = min(fileSize, 512)
        try? handle.seek(toOffset: fileSize - tailLength)
        guard let tailData = try? handle.readToEnd(),
              let tail = String(data: tailData, encoding: .utf8) else { return nil }
        return tail.split(separator: "\n").last.map(String.init)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }
}

/// Logs an Objective-C exception nothing caught (AppKit and AVFoundation
/// raise them, and Swift cannot catch them), with its call stack, before
/// the process ends.
nonisolated enum UncaughtExceptionLogger {
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(40).joined(separator: "\n")
            TutorDebugLog.writeImmediately("💥 uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason given")\n\(stack)")
        }
    }
}

/// Notices the main thread being held: a background timer asks the main
/// queue to answer every half second, and a question unanswered for more
/// than two seconds is logged with the last entry written before it, which
/// is the best record of what was running. The notch, the voice and every
/// click wait while the main thread is held, so these lines are where a
/// freeze shows up in the log.
nonisolated enum MainThreadWatchdog {
    static let longestAcceptableBlockSeconds: TimeInterval = 2

    private static let queue = DispatchQueue(label: "buddy.main-thread-watchdog", qos: .utility)

    // Touched only on `queue`.
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var unansweredSince: Date?
    nonisolated(unsafe) private static var entryBeforeTheBlock = ""
    nonisolated(unsafe) private static var hasReportedThisBlock = false

    static func start() {
        queue.async {
            guard timer == nil else { return }
            let newTimer = DispatchSource.makeTimerSource(queue: queue)
            newTimer.schedule(deadline: .now() + 1, repeating: 0.5)
            newTimer.setEventHandler { checkMainThread() }
            timer = newTimer
            newTimer.resume()
        }
    }

    /// Called only on `queue`.
    private static func checkMainThread() {
        if let unansweredSince {
            let secondsBlocked = Date().timeIntervalSince(unansweredSince)
            if secondsBlocked > longestAcceptableBlockSeconds, !hasReportedThisBlock {
                hasReportedThisBlock = true
                TutorDebugLog.write("⚠️ main thread blocked for \(String(format: "%.1f", secondsBlocked))s so far; last logged before it: \(entryBeforeTheBlock)")
            }
            return
        }
        unansweredSince = Date()
        entryBeforeTheBlock = TutorDebugLog.mostRecentEntry()
        DispatchQueue.main.async {
            queue.async { mainThreadAnswered() }
        }
    }

    /// Called only on `queue`.
    private static func mainThreadAnswered() {
        if hasReportedThisBlock, let unansweredSince {
            TutorDebugLog.write("⚠️ main thread was blocked for \(String(format: "%.1f", Date().timeIntervalSince(unansweredSince)))s in all")
        }
        unansweredSince = nil
        hasReportedThisBlock = false
    }
}
