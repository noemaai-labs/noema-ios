import Foundation
import Security

/// A minimal Keychain helper for storing small blobs as generic passwords.
/// All operations use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
enum KeychainStore {
    /// Reads a value for the given service/account.
    /// - Throws: `UsageLimiterError.keychainFailure` wrapping the OSStatus
    static func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw UsageLimiterError.keychainFailure(status)
        }
    }

    /// Adds or updates the value for service/account atomically.
    /// - Throws: `UsageLimiterError.keychainFailure` wrapping the OSStatus
    static func write(service: String, account: String, data: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let updateAttributes: [String: Any] = [
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw UsageLimiterError.keychainFailure(updateStatus)
            }
        } else if status != errSecSuccess {
            throw UsageLimiterError.keychainFailure(status)
        }
    }

    /// Deletes the item for service/account.
    /// - Throws: `UsageLimiterError.keychainFailure` wrapping the OSStatus
    @discardableResult
    static func delete(service: String, account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw UsageLimiterError.keychainFailure(status)
        }
    }
}


