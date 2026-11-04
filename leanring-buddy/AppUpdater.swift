//
//  AppUpdater.swift
//  leanring-buddy
//
//  Keeps a downloaded Buddy current: checks GitHub's latest release once a
//  day, and when there is a newer one, downloads it, proves it is genuine,
//  swaps it in place and relaunches, all from one click in the notch.
//
//  Why it can be trusted with replacing the app:
//  - The disk image must match the checksum published with the release, so
//    a truncated or corrupted download is never opened.
//  - The app inside must satisfy this app's own designated requirement: the
//    same bundle identifier, signed by the same certificate. Only whoever
//    holds that certificate's private key can make such an app, so a
//    substituted download is refused even if its checksum was swapped too.
//    It is the check Sparkle makes, without the framework.
//  - It must be a newer version than the one running.
//
//  Why it is smoother than downloading by hand: macOS marks files a browser
//  downloads as quarantined, which is what triggers "Open Anyway". A file
//  Buddy downloads itself is not marked, and the new copy is signed with the
//  same certificate, so it opens straight away with every permission intact.
//
//  Never on a local development build: those carry their own version and
//  would be offered a release to replace them. A manual check still works.
//

import AppKit
import Combine
import CryptoKit
import Foundation
import Security

@MainActor
final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed(String)
    }

    struct Release: Equatable {
        let version: String
        let pageURL: URL
        let diskImageURL: URL
        let checksumURL: URL
    }

    static let repository = "projects-hacks/buddy"
    static let automaticChecksDefaultsKey = "automaticUpdateChecks"
    private static let lastCheckDefaultsKey = "lastUpdateCheck"
    /// Once a day is plenty for an app released every few weeks, and well
    /// inside GitHub's limit for unauthenticated requests.
    private static let checkEvery: TimeInterval = 20 * 60 * 60

    @Published private(set) var state: State = .idle
    @Published private(set) var availableRelease: Release?

    /// Told when a newer release is found, for the notch.
    var onUpdateAvailable: (Release) -> Void = { _ in }

    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: Self.automaticChecksDefaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.automaticChecksDefaultsKey)
            objectWillChange.send()
        }
    }

    // MARK: - Checking

    func startAutomaticChecks() {
        #if DEBUG
        return
        #else
        timer?.invalidate()
        // A few minutes after launch, so it never competes with the first
        // question, then looked at every few hours, checking once a day.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            Task { @MainActor in await self?.checkIfDue() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        #endif
    }

    private func checkIfDue() async {
        guard checksAutomatically else { return }
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckDefaultsKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) > Self.checkEvery else { return }
        await check()
    }

    /// Asks GitHub for the latest release and compares it with this one.
    func check() async {
        guard state != .checking, state != .downloading, state != .installing else { return }
        state = .checking
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckDefaultsKey)
        do {
            guard let release = try await Self.fetchLatestRelease() else {
                state = .upToDate
                return
            }
            if Self.isVersion(release.version, newerThan: currentVersion) {
                availableRelease = release
                state = .available
                TutorDebugLog.write("⬆️ update: Buddy \(release.version) is available (running \(currentVersion))")
                onUpdateAvailable(release)
            } else {
                availableRelease = nil
                state = .upToDate
            }
        } catch {
            state = .failed("Couldn't check for updates. Check the internet connection, then try again.")
            TutorDebugLog.write("⚠️ update check failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static func fetchLatestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Buddy-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        func asset(endingWith suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        guard let diskImage = asset(endingWith: ".dmg"), let checksum = asset(endingWith: ".dmg.sha256") else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, pageURL: page, diskImageURL: diskImage, checksumURL: checksum)
    }

    /// "1.10" is newer than "1.9": compared number by number, not as text.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        for position in 0..<max(candidateParts.count, currentParts.count) {
            let candidatePart = position < candidateParts.count ? candidateParts[position] : 0
            let currentPart = position < currentParts.count ? currentParts[position] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
    }

    // MARK: - Installing

    /// Downloads, verifies, swaps and relaunches. On any failure the running
    /// app is left exactly as it was, and the release page is the fallback.
    func installAvailableUpdate() async {
        guard let release = availableRelease, state == .available || isFailed else { return }
        let appPath = Bundle.main.bundlePath
        let parent = (appPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            fail("Buddy can't replace itself where it is (\(parent)). Move Buddy into Applications, or download the update from the release page.")
            return
        }

        state = .downloading
        TutorDebugLog.write("⬆️ update: downloading Buddy \(release.version)")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloadedImage, _) = try await URLSession.shared.download(from: release.diskImageURL)
            let diskImage = work.appendingPathComponent("Buddy.dmg")
            try FileManager.default.moveItem(at: downloadedImage, to: diskImage)
            let (checksumData, _) = try await URLSession.shared.data(from: release.checksumURL)

            state = .installing
            let currentRequirement = Self.designatedRequirementOfThisApp()
            let stagedApp = try await Task.detached(priority: .userInitiated) {
                try Self.verifyAndStage(diskImage: diskImage, checksumFile: checksumData, in: work,
                                        requirement: currentRequirement, expectedVersion: release.version)
            }.value
            TutorDebugLog.write("⬆️ update: Buddy \(release.version) verified, relaunching into it")
            try Self.swapInWhenThisAppQuits(appPath: appPath, newApp: stagedApp.path, workFolder: work.path)
            NSApp.terminate(nil)
        } catch let error as UpdateError {
            try? FileManager.default.removeItem(at: work)
            fail(error.message)
        } catch {
            try? FileManager.default.removeItem(at: work)
            fail("The update couldn't be downloaded. Try again, or download it from the release page.")
            TutorDebugLog.write("⚠️ update failed: \(error.localizedDescription)")
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func fail(_ message: String) {
        state = .failed(message)
        TutorDebugLog.write("⚠️ update: \(message)")
    }

    struct UpdateError: Error {
        let message: String
    }

    private static func designatedRequirementOfThisApp() -> SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Off the main thread: hashing, mounting and copying take seconds.
    private nonisolated static func verifyAndStage(
        diskImage: URL, checksumFile: Data, in work: URL, requirement: SecRequirement?, expectedVersion: String
    ) throws -> URL {
        // 1. The download is the file that was published.
        let expected = String(data: checksumFile, encoding: .utf8)?
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)?.lowercased() ?? ""
        let actual = SHA256.hash(data: try Data(contentsOf: diskImage, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, expected == actual else {
            throw UpdateError(message: "The download didn't match the published checksum, so it wasn't installed. Try again in a while.")
        }

        // 2. Out of the disk image, onto this disk.
        let mountPoint = work.appendingPathComponent("mount")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, diskImage.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }
        let staged = work.appendingPathComponent("Buddy.app")
        try run("/usr/bin/ditto", [mountPoint.appendingPathComponent("Buddy.app").path, staged.path])

        // 3. Made by whoever made this app, and newer than it.
        guard let requirement else {
            throw UpdateError(message: "Buddy couldn't read its own signature to compare the update against, so it wasn't installed.")
        }
        var stagedCode: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(staged as CFURL, [], &stagedCode) == errSecSuccess, let stagedCode,
              SecStaticCodeCheckValidity(stagedCode, flags, requirement) == errSecSuccess else {
            throw UpdateError(message: "The update isn't signed the way Buddy is, so it wasn't installed. Download it from the release page only if you trust it.")
        }
        let stagedVersion = Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard stagedVersion == expectedVersion else {
            throw UpdateError(message: "The update said it was \(expectedVersion) but contained \(stagedVersion), so it wasn't installed.")
        }
        return staged
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(message: "The update couldn't be unpacked (\((tool as NSString).lastPathComponent) failed). Try again, or download it from the release page.")
        }
        return process.terminationStatus
    }

    /// A small shell helper, started now and left running when Buddy quits,
    /// that waits for this process to exit, puts the new app where this one
    /// is (keeping the old one until the new one is in place, and putting it
    /// back if the move fails), then opens it. Paths travel as arguments,
    /// never inside the script, so no path can change what runs.
    private static func swapInWhenThisAppQuits(appPath: String, newApp: String, workFolder: String) throws {
        let previous = appPath + ".previous"
        // Afterwards the staged copy's path is forgotten by Launch Services
        // (a stale registration is where System Settings finds old names) and
        // the download is deleted.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$4"
        if mv "$2" "$4"; then
          if mv "$3" "$2"; then rm -rf "$4"; else mv "$4" "$2"; fi
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$3" 2>/dev/null
        rm -rf "$5"
        open "$2"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "buddy-update", String(ProcessInfo.processInfo.processIdentifier),
                            appPath, newApp, previous, workFolder]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }
}
