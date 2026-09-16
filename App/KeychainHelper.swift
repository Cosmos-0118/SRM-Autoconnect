import Foundation
import Security

/// Thin wrapper over the Keychain generic-password class with one rule:
/// failures are never silent. An earlier fire-and-forget version let the
/// Settings UI report success while nothing was stored (denied access
/// prompt, locked keychain, stale ACL) — every call here either succeeds
/// or throws a human-readable error instead.
class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    struct KeychainFailure: LocalizedError {
        let operation: String
        let status: OSStatus
        var errorDescription: String? {
            "\(operation) failed: \(KeychainHelper.describe(status))"
        }
    }

    /// What the user should actually do about it.
    static func hint(for status: OSStatus) -> String {
        switch status {
        case errSecAuthFailed:
            return "Access was denied. Open Keychain Access, search for “SRMAutoconnect”, delete stale entries (or Get Info > Access Control > allow this app), then save again."
        case errSecInteractionNotAllowed:
            return "The login keychain is locked. Unlock it in Keychain Access and try again."
        case errSecItemNotFound:
            return "Nothing saved yet — enter your details and press Save."
        default:
            return "Open Keychain Access and check the login keychain for “SRMAutoconnect” entries."
        }
    }

    static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "OSStatus \(status)"
    }

    /// Add-or-update. Intentionally sets NO kSecAttrAccessControl object:
    /// app-pinned access controls re-prompt (or hard-fail with
    /// errSecAuthFailed) whenever a locally-signed build is re-signed,
    /// moved, or built under a different self-signed cert on a teammate's
    /// Mac. Default ACL + WhenUnlocked survives rebuilds without prompts.
    func save(_ data: Data, service: String, account: String) throws {
        let matchQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        var addQuery = matchQuery
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        addQuery[kSecValueData] = data

        var status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Update the secret only — never the access metadata. Items
            // created by older builds carry an app-pinned access-control
            // object that SecItemUpdate rejects outright; touching just the
            // data migrates them in place, usually with no prompt.
            let updates: [CFString: Any] = [kSecValueData: data]
            status = SecItemUpdate(matchQuery as CFDictionary, updates as CFDictionary)

            if status != errSecSuccess {
                // Stale entry that can't be updated in place (e.g. created
                // under a different signing identity): recreate from scratch.
                SecItemDelete(matchQuery as CFDictionary)
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }
        }

        guard status == errSecSuccess else {
            throw KeychainFailure(operation: "Save", status: status)
        }
    }

    /// Returns nil only when nothing was ever saved. Anything else —
    /// denied access, locked keychain — throws so the caller can say why
    /// instead of treating it as "no credentials".
    func read(service: String, account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainFailure(operation: "Read", status: status)
        }
        return result as? Data
    }

    /// Throws on real failures, the same as `save` and `read`. Deleting
    /// something that was never there is success, not an error. The previous
    /// version discarded the OSStatus entirely, so a delete refused by a locked
    /// or ACL-protected keychain looked identical to one that worked — exactly
    /// the silent-failure shape this file exists to avoid.
    func delete(service: String, account: String) throws {
        let query = [
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecClass: kSecClassGenericPassword,
        ] as CFDictionary

        let status = SecItemDelete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainFailure(operation: "Delete", status: status)
        }
    }
}
