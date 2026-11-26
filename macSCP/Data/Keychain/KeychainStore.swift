//
//  KeychainStore.swift
//  macSCP
//
//  Shared Keychain CRUD helper for generic password items
//

import Foundation
import Security

enum KeychainStore {
    static func save(_ data: Data, service: String, account: String) throws {
        // Delete any existing entry first to guarantee clean replacement
        try delete(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logError("Keychain save failed for service '\(service)' with status: \(status)", category: .keychain)
            throw AppError.keychainSaveFailed
        }
    }

    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return data
    }

    static func update(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            try save(data, service: service, account: account)
            return
        }

        guard status == errSecSuccess else {
            logError("Keychain update failed for service '\(service)' with status: \(status)", category: .keychain)
            throw AppError.keychainSaveFailed
        }
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logError("Keychain delete failed for service '\(service)' with status: \(status)", category: .keychain)
            throw AppError.keychainDeleteFailed
        }
    }
}
