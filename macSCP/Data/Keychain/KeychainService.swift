//
//  KeychainService.swift
//  macSCP
//
//  Keychain implementation for secure password and S3 credential storage
//

import Foundation

final class KeychainService: KeychainServiceProtocol, Sendable {
    static let shared = KeychainService()

    private let service = AppConstants.keychainService
    private let s3Service = AppConstants.keychainS3Service

    private init() {}

    // MARK: - Passwords

    func savePassword(_ password: String, for connectionId: UUID) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw AppError.keychainSaveFailed
        }
        try KeychainStore.save(passwordData, service: service, account: connectionId.uuidString)
        logDebug("Password saved for connection: \(connectionId)", category: .keychain)
    }

    func getPassword(for connectionId: UUID) -> String? {
        try? readPassword(for: connectionId)
    }

    func readPassword(for connectionId: UUID) throws -> String? {
        guard let data = try KeychainStore.readIfPresent(service: service, account: connectionId.uuidString) else {
            return nil
        }
        guard let password = String(data: data, encoding: .utf8) else {
            throw AppError.keychainReadFailed
        }
        return password
    }

    func deletePassword(for connectionId: UUID) throws {
        try KeychainStore.delete(service: service, account: connectionId.uuidString)
        logDebug("Password deleted for connection: \(connectionId)", category: .keychain)
    }

    func updatePassword(_ password: String, for connectionId: UUID) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw AppError.keychainSaveFailed
        }
        try KeychainStore.update(passwordData, service: service, account: connectionId.uuidString)
        logDebug("Password updated for connection: \(connectionId)", category: .keychain)
    }

    func hasPassword(for connectionId: UUID) -> Bool {
        getPassword(for: connectionId) != nil
    }

    // MARK: - S3 Credentials

    func saveS3Credentials(_ credentials: S3Credentials, for connectionId: UUID) throws {
        guard let credentialsData = try? JSONEncoder().encode(credentials) else {
            throw AppError.keychainSaveFailed
        }
        try KeychainStore.save(credentialsData, service: s3Service, account: connectionId.uuidString)
        logDebug("S3 credentials saved for connection: \(connectionId)", category: .keychain)
    }

    func getS3Credentials(for connectionId: UUID) -> S3Credentials? {
        try? readS3Credentials(for: connectionId)
    }

    func readS3Credentials(for connectionId: UUID) throws -> S3Credentials? {
        guard let data = try KeychainStore.readIfPresent(service: s3Service, account: connectionId.uuidString) else {
            return nil
        }
        guard let credentials = try? JSONDecoder().decode(S3Credentials.self, from: data) else {
            throw AppError.keychainReadFailed
        }
        return credentials
    }

    func deleteS3Credentials(for connectionId: UUID) throws {
        try KeychainStore.delete(service: s3Service, account: connectionId.uuidString)
        logDebug("S3 credentials deleted for connection: \(connectionId)", category: .keychain)
    }

    func updateS3Credentials(_ credentials: S3Credentials, for connectionId: UUID) throws {
        guard let credentialsData = try? JSONEncoder().encode(credentials) else {
            throw AppError.keychainSaveFailed
        }
        try KeychainStore.update(credentialsData, service: s3Service, account: connectionId.uuidString)
        logDebug("S3 credentials updated for connection: \(connectionId)", category: .keychain)
    }

    func hasS3Credentials(for connectionId: UUID) -> Bool {
        getS3Credentials(for: connectionId) != nil
    }
}
