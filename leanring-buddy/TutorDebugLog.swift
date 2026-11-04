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
//  Local only, never transmitted, and truncated on launch so it stays readable.
//

import Foundation

enum TutorDebugLog {
    /// `~/Library/Logs/Buddy.log`, the conventional place for an app's
    /// own log and readable without elevated permissions.
    static let fileURL: URL = {
        let logsDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return logsDirectory.appendingPathComponent("\(AppIdentity.dataName).log")
    }()

    /// Serialises writes, since the pipeline logs from several tasks.
    private static let writeQueue = DispatchQueue(label: "buddy.debug-log")

    /// Starts a fresh file, so a session's log is only that session.
    static func beginSession() {
        writeQueue.async {
            let header = "=== Buddy session \(timestamp()) ===\n"
            try? header.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Writes one entry, and mirrors it to stdout for terminal runs.
    static func write(_ message: String) {
        print(message)

        writeQueue.async {
            let entry = "[\(timestamp())] \(message)\n"
            guard let entryData = entry.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: entryData)
            } else {
                try? entry.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
