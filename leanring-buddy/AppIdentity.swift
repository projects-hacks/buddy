//
//  AppIdentity.swift
//  leanring-buddy
//
//  Where Buddy keeps its things, derived from its bundle identifier, so a
//  copy built under another identifier (the "Buddy QA" fresh-install test)
//  gets its own Keychain items, data folder and log, starts as empty as a
//  friend's first install, and can never read or overwrite Buddy's own.
//
//  Buddy itself keeps the names it always had: the folder is still
//  ClickyLocal and the Keychain items still com.maverickrajeev.clicky-local.*,
//  so nothing saved before moves.
//

import Foundation

enum AppIdentity {
    static let standardBundleIdentifier = "com.maverickrajeev.clicky-local"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? standardBundleIdentifier
    }

    /// "ClickyLocal" for Buddy, "ClickyLocal-qa" for a copy whose identifier
    /// ends in ".qa".
    static var dataName: String {
        guard bundleIdentifier != standardBundleIdentifier else { return "ClickyLocal" }
        let suffix = bundleIdentifier.split(separator: ".").last.map(String.init) ?? "copy"
        return "ClickyLocal-\(suffix)"
    }

    static var supportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(dataName)")
    }

    static func keychainService(_ name: String) -> String {
        "\(bundleIdentifier).\(name)"
    }
}
