//
//  SSHKeyStorageService.swift
//  macSCP
//
//  Secure in-app storage for SSH private keys backed by macOS Keychain and App Sandbox
//

import Foundation

final class SSHKeyStorageService: SSHKeyRepositoryProtocol, @unchecked Sendable {
    static let shared = SSHKeyStorageService()

    private let service: String
    private let metadataKey: String
    private let userDefaults: UserDefaults
    private let lock = NSLock()

    internal init(
        service: String = AppConstants.keychainSSHKeyService,
        metadataKey: String = "com.macSCP.sshKeyItems",
        userDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.metadataKey = metadataKey
        self.userDefaults = userDefaults
    }

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

        guard let data = KeychainStore.read(service: service, account: keyId.uuidString),
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
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = SSHKeyItem(
            id: keyId,
            name: trimmedName.isEmpty ? meta.keyType : trimmedName,
            keyType: meta.keyType,
            fingerprint: meta.fingerprint,
            publicKeyString: meta.publicKeyString,
            createdAt: Date()
        )

        guard let keyData = trimmed.data(using: .utf8) else {
            throw AppError.keychainSaveFailed
        }

        try KeychainStore.save(keyData, service: service, account: keyId.uuidString)

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

        try KeychainStore.delete(service: service, account: id.uuidString)

        var currentItems = loadMetadata()
        currentItems.removeAll { $0.id == id }
        saveMetadata(currentItems)

        logInfo("Deleted SSH key \(id) from Keychain and metadata", category: .keychain)
    }

    // MARK: - Private Helpers

    private func loadMetadata() -> [SSHKeyItem] {
        guard let data = userDefaults.data(forKey: metadataKey),
              let items = try? JSONDecoder().decode([SSHKeyItem].self, from: data) else {
            return []
        }
        return items
    }

    private func saveMetadata(_ items: [SSHKeyItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        userDefaults.set(data, forKey: metadataKey)
    }
}
