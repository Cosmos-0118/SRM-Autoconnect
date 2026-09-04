import Foundation
import Security

class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    // Pins the item to this app's keychain partition with no interactive auth
    // (Touch ID / "Always Allow"). Without an explicit access-control object,
    // locally signed apps can be re-prompted on every reboot.
    private func selfOnlyAccessControl() -> SecAccessControl? {
        var error: Unmanaged<CFError>?
        return SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlocked,
            [],
            &error
        )
    }

    func save(_ data: Data, service: String, account: String) {
        let matchQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        var addQuery = matchQuery
        addQuery[kSecValueData] = data
        if let access = selfOnlyAccessControl() {
            addQuery[kSecAttrAccessControl] = access
        }

        var status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecDuplicateItem {
            var updates: [CFString: Any] = [kSecValueData: data]
            if let access = selfOnlyAccessControl() {
                updates[kSecAttrAccessControl] = access
            }
            status = SecItemUpdate(matchQuery as CFDictionary, updates as CFDictionary)

            // Items created with the old SecAccess ACL can't always be migrated
            // in place; delete and recreate with the modern access control.
            if status != errSecSuccess {
                SecItemDelete(matchQuery as CFDictionary)
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }
        }
    }
    
    func read(service: String, account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecClass: kSecClassGenericPassword,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        
        return (result as? Data)
    }
    
    func delete(service: String, account: String) {
        let query = [
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecClass: kSecClassGenericPassword,
        ] as CFDictionary
        
        SecItemDelete(query)
    }
}
