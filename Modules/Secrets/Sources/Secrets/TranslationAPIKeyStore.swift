//
//  TranslationAPIKeyStore.swift
//  Secrets
//
//  Keychain-backed storage for the user's LLM-translation API key.
//  Uses kSecClassGenericPassword with a fixed service + account.
//

import Foundation
import Security

public enum TranslationAPIKeyStore {

    private static let service = "com.ranchero.NetNewsWire.translation"
    private static let account = "apiKey"

    public static func save(_ key: String) throws {
        try delete()  // overwrite semantics

        let data = key.data(using: .utf8) ?? Data()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        if let group = appAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func load() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if let group = appAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    public static func delete() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let group = appAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private static let appAccessGroup: String? = {
        guard let appGroup = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String,
              let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String else {
            return nil
        }
        let groupSuffix = appGroup.suffix(appGroup.count - 6)
        return "\(prefix)\(groupSuffix)"
    }()

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "Keychain error: \(status)" }
    }
}
