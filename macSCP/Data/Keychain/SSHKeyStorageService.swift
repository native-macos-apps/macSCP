//
//  SSHKeyStorageService.swift
//  macSCP
//
//  Secure in-app storage for SSH private keys backed by macOS Keychain and App Sandbox
//

import Foundation
import Security

final class SSHKeyStorageService: SSHKeyRepositoryProtocol, @unchecked Sendable {
    static let shared = SSHKeyStorageService()

    private let service = AppConstants.keychainSSHKeyService
    private let metadataKey = "com.macSCP.sshKeyItems"
    private let lock = NSLock()

    private init() {}

    // MARK: - Public API

    func getAllKeys() -> [SSHKeyItem] {
        lock.lock()
        defer { lock.unlock() }
        return loadMetadata()
    }

    func getKey(by id: UUID) -> SSHKeyItem? {
        lock.lock()
        defer { lock.unlock() }
        return loadMetadata().first { $0.id == id }
    }

    func getPrivateKeyContent(for keyId: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let keyString = String(data: data, encoding: .utf8) else {
            return nil
        }

        return keyString
    }

    @discardableResult
    func saveKey(name: String, privateKeyContent: String) throws -> SSHKeyItem {
        lock.lock()
        defer { lock.unlock() }

        let trimmed = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.connectionFailed("Private key content cannot be empty.")
        }

        // Validate and inspect key
        let meta = try SSHKeyParser.inspectKey(from: trimmed)

        let keyId = UUID()
        let item = SSHKeyItem(
            id: keyId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? meta.keyType : name.trimmingCharacters(in: .whitespacesAndNewlines),
            keyType: meta.keyType,
            fingerprint: meta.fingerprint,
            publicKeyString: meta.publicKeyString,
            createdAt: Date()
        )

        // Save to Keychain
        guard let keyData = trimmed.data(using: .utf8) else {
            throw AppError.keychainSaveFailed
        }

        // Delete any existing item for this id
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyId.uuidString
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyId.uuidString,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            logError("Failed to save SSH key to Keychain with status \(status)", category: .keychain)
            throw AppError.keychainSaveFailed
        }

        // Save metadata
        var currentItems = loadMetadata()
        currentItems.append(item)
        saveMetadata(currentItems)

        logInfo("Successfully imported SSH key '\(item.name)' (\(item.keyType)) into Keychain", category: .keychain)
        return item
    }

    func deleteKey(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var currentItems = loadMetadata()
        currentItems.removeAll { $0.id == id }
        saveMetadata(currentItems)

        logInfo("Deleted SSH key \(id) from Keychain and metadata", category: .keychain)
    }

    // MARK: - Private Helpers

    private func loadMetadata() -> [SSHKeyItem] {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let items = try? JSONDecoder().decode([SSHKeyItem].self, from: data) else {
            return []
        }
        return items
    }

    private func saveMetadata(_ items: [SSHKeyItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: metadataKey)
    }
}
