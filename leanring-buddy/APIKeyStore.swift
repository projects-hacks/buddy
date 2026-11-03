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
        case gemini = "com.maverickrajeev.clicky-local.gemini"

        var humanReadableName: String {
            switch self {
            case .gemini: return "Google Gemini"
            }
        }
    }

    // MARK: - Reading

    /// Returns the stored key, or nil when none has been saved.
    static func key(for service: Service) -> String? {
        var query = baseQuery(for: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedKey.isEmpty ? nil : trimmedKey
    }

    static func hasKey(for service: Service) -> Bool {
        key(for: service) != nil
    }

    // MARK: - Writing

    /// Saves or replaces the key. Returns false if the Keychain refused.
    @discardableResult
    static func save(key: String, for service: Service) -> Bool {
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
        let status = SecItemDelete(baseQuery(for: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Private

    private static func baseQuery(for service: Service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: "api-key"
        ]
    }
}
