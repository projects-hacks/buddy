//
//  AppIdentity.swift
//  leanring-buddy
//
//  Where Buddy keeps its things, derived from its bundle identifier, so a
//  copy built under another identifier (the "Buddy QA" fresh-install test)
//  gets its own Keychain items, data folder and log, starts as empty as a
//  friend's first install, and can never read or overwrite Buddy's own.
//
//  The bundle identifier, and so the Keychain items and settings, keep the
//  name from before Buddy was Buddy: macOS ties the permissions to it, and
//  every installed copy's updater only accepts a release with the same one.
//  The folder and the log, which people do see, are named Buddy; a folder
//  from an earlier version is moved across the first time it is needed.
//

import Foundation

enum AppIdentity {
    static let standardBundleIdentifier = "com.maverickrajeev.clicky-local"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? standardBundleIdentifier
    }

    /// "Buddy" for Buddy, "Buddy-qa" for a copy whose identifier ends in
    /// ".qa". Worked out once, which is also when older files are moved.
    static let dataName: String = {
        let name = names(prefix: "Buddy")
        moveFilesFromEarlierName(names(prefix: "ClickyLocal"), to: name)
        return name
    }()

    private static func names(prefix: String) -> String {
        guard bundleIdentifier != standardBundleIdentifier else { return prefix }
        let suffix = bundleIdentifier.split(separator: ".").last.map(String.init) ?? "copy"
        return "\(prefix)-\(suffix)"
    }

    /// Before 1.4 everything lived under ClickyLocal. Transcripts, memory and
    /// hint steps move as one folder, so nothing is lost or left half-moved,
    /// and the last session's log comes along as the previous one.
    private static func moveFilesFromEarlierName(_ earlierName: String, to name: String) {
        let fileManager = FileManager.default
        let library = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let earlierFolder = library.appendingPathComponent("Application Support/\(earlierName)")
        let folder = library.appendingPathComponent("Application Support/\(name)")
        if fileManager.fileExists(atPath: earlierFolder.path), !fileManager.fileExists(atPath: folder.path) {
            try? fileManager.moveItem(at: earlierFolder, to: folder)
        }
        let logs = library.appendingPathComponent("Logs")
        let earlierLog = logs.appendingPathComponent("\(earlierName).log")
        let previousLog = logs.appendingPathComponent("\(name).previous.log")
        if fileManager.fileExists(atPath: earlierLog.path) {
            try? fileManager.removeItem(at: previousLog)
            try? fileManager.moveItem(at: earlierLog, to: previousLog)
        }
        try? fileManager.removeItem(at: logs.appendingPathComponent("\(earlierName).previous.log"))
    }

    static var supportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(dataName)")
    }

    static func keychainService(_ name: String) -> String {
        "\(bundleIdentifier).\(name)"
    }
}
