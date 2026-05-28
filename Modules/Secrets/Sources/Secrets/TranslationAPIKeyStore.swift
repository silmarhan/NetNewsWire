//
//  TranslationAPIKeyStore.swift
//  Secrets
//
//  Persistent storage for the user's LLM-translation API key.
//
//  Primary backend: iOS Keychain (kSecClassGenericPassword) — used when
//  the app has the required `keychain-access-groups` entitlement.
//
//  Fallback backend: UserDefaults — used only when the Keychain returns
//  `errSecMissingEntitlement` (-34018). This happens on simulator/ad-hoc
//  builds of forks without a configured signing team; the app would
//  otherwise be unusable. UserDefaults is sandboxed to the app on iOS,
//  so the key is still inaccessible to other apps.
//

import Foundation
import Security

public enum TranslationAPIKeyStore {

    private static let service = "com.ranchero.NetNewsWire.translation"
    private static let account = "apiKey"
    private static let userDefaultsKey = "translation.apiKey.fallback"

    public static func save(_ key: String) throws {
        try? delete()  // overwrite semantics

        let data = key.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        case errSecMissingEntitlement:
            UserDefaults.standard.set(key, forKey: userDefaultsKey)
        default:
            throw KeychainError(status: status)
        }
    }

    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        return UserDefaults.standard.string(forKey: userDefaultsKey)
    }

    public static func delete() throws {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound, errSecMissingEntitlement:
            return
        default:
            throw KeychainError(status: status)
        }
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "Keychain error: \(status)" }
    }
}
