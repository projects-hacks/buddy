//
//  APIKeyStore.swift
//  leanring-buddy
//
//  Reads and writes API keys in the macOS Keychain.
//
//  Why the Keychain and not the upstream approach: the original build routes
//  every request through a Cloudflare Worker that holds the keys, which exists
//  because that app ships to strangers and a key compiled into a distributed
//  binary is a key published. This build runs on its owner's machine, so the
//  proxy would add a network hop, an account and a deploy step to protect a
//  key from the person who owns it.
//
//  Why not a plist, a dotfile or an environment variable: all three leave the
//  key readable by anything running as the user, and a dotfile inside the
//  checkout is one `git add -A` away from being committed. The Keychain is
//  encrypted at rest, access is scoped to this application, and nothing
//  sensitive ever enters the repository or the binary.
//

import Foundation
import Security

enum APIKeyStore {
    /// Which hosted service a key belongs to.
    enum Service: String {
        /// Only used for the AI Studio endpoint. Vertex authenticates with a
        /// gcloud access token instead, so the hosted brain needs no key here.
        case gemini = "com.maverickrajeev.clicky-local.gemini"
        /// Speech to text and text to speech.
        case deepgram = "com.maverickrajeev.clicky-local.deepgram"
        /// Claude, first-party API.
        case anthropic = "com.maverickrajeev.clicky-local.anthropic"

        var humanReadableName: String {
            switch self {
            case .gemini: return "Google Gemini"
            case .deepgram: return "Deepgram"
            case .anthropic: return "Anthropic"
            }
        }
    }

    // MARK: - Reading

    /// Returns the stored key, or nil when none has been saved.
    /// Keys already read this run.
    ///
    /// Read once and kept in memory because each Keychain read can put a
    /// password prompt in front of the student: the items were created by the
    /// `security` command, so until "Always Allow" is chosen for this app,
    /// macOS asks on every read, and the app reads on every question and
    /// every press of the shortcut.
    private static let cache = KeyCache()

    static func key(for service: Service) -> String? {
        if let cached = cache.value(for: service) { return cached }
        // A key that is not saved is checked again only now and then, since
        // the UI asks often and each check starts a process.
        if cache.wasRecentlyMissing(service) { return nil }
        if let viaSecurityTool = keyReadThroughSecurityTool(for: service) {
            cache.store(viaSecurityTool, for: service)
            return viaSecurityTool
        }
        var query = baseQuery(for: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            cache.recordMissing(service)
            return nil
        }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        cache.store(trimmedKey, for: service)
        return trimmedKey
    }

    static func hasKey(for service: Service) -> Bool {
        key(for: service) != nil
    }

    // MARK: - Writing

    /// Saves or replaces the key. Returns false if the Keychain refused.
    @discardableResult
    static func save(key: String, for service: Service) -> Bool {
        cache.store(nil, for: service)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, let keyData = trimmedKey.data(using: .utf8) else {
            return false
        }

        // Delete first rather than branch on whether one exists: an update on a
        // missing item and an add on an existing one both fail, and this is
        // simpler than handling each.
        SecItemDelete(baseQuery(for: service) as CFDictionary)

        var query = baseQuery(for: service)
        query[kSecValueData as String] = keyData
        // Available only while the machine is unlocked, and never migrated to
        // another device by a backup.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            TutorDebugLog.write("⚠️ Keychain refused to store \(service.humanReadableName) key: OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func deleteKey(for service: Service) -> Bool {
        cache.store(nil, for: service)
        let status = SecItemDelete(baseQuery(for: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Private

    /// Reads a key the way it was saved, through `/usr/bin/security`.
    ///
    /// Why not SecItemCopyMatching directly. The keys were saved with the
    /// `security` command, so the Keychain trusts that tool to read them and
    /// asks the user about any other app. "Always Allow" for this app does not
    /// survive a rebuild: macOS remembers a trusted app by its Team ID, a
    /// locally signed build has none, and it falls back to the build's exact
    /// fingerprint, which changes every time. Asking the already-trusted tool
    /// never prompts. It reads nothing the tool could not already read for
    /// anyone, so it opens no new access. The key comes back over a pipe,
    /// never as a command-line argument.
    private static func keyReadThroughSecurityTool(for service: Service) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", "api-key", "-s", service.rawValue, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    private static func baseQuery(for service: Service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: "api-key"
        ]
    }
}


/// Thread-safe memory of keys read this run. Reads come from the main actor
/// and from network tasks alike.
private final class KeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [APIKeyStore.Service: String] = [:]
    private var missingSince: [APIKeyStore.Service: Date] = [:]

    func wasRecentlyMissing(_ service: APIKeyStore.Service) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let since = missingSince[service] else { return false }
        return Date().timeIntervalSince(since) < 30
    }

    func recordMissing(_ service: APIKeyStore.Service) {
        lock.lock(); defer { lock.unlock() }
        missingSince[service] = Date()
    }

    func value(for service: APIKeyStore.Service) -> String? {
        lock.lock(); defer { lock.unlock() }
        return keys[service]
    }

    func store(_ key: String?, for service: APIKeyStore.Service) {
        lock.lock(); defer { lock.unlock() }
        keys[service] = key
        missingSince[service] = nil
    }
}
