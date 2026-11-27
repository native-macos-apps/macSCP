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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        let status = addStatus == errSecDuplicateItem
            ? updateItem(data, service: service, account: account, enforceAccessibility: true)
            : addStatus
        guard status == errSecSuccess else {
            logError("Keychain save failed for service '\(service)' with status: \(status)", category: .keychain)
            throw AppError.keychainSaveFailed
        }
    }

    static func read(service: String, account: String) -> Data? {
        try? readIfPresent(service: service, account: account)
    }

    static func readIfPresent(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppError.keychainReadFailed
        }

        return data
    }

    static func update(_ data: Data, service: String, account: String) throws {
        let status = updateItem(data, service: service, account: account)

        if status == errSecItemNotFound {
            try save(data, service: service, account: account)
            return
        }

        guard status == errSecSuccess else {
            logError("Keychain update failed for service '\(service)' with status: \(status)", category: .keychain)
            throw AppError.keychainSaveFailed
        }
    }

    private static func updateItem(
        _ data: Data,
        service: String,
        account: String,
        enforceAccessibility: Bool = false
    ) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        var attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        if enforceAccessibility {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        }
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
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
