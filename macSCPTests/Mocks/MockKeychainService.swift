//
//  MockKeychainService.swift
//  macSCPTests
//
//  Mock implementation of KeychainServiceProtocol for testing
//

import Foundation
@testable import macSCP

final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    // MARK: - Recorded Calls
    var savePasswordCalled = false
    var getPasswordCalled = false
    var deletePasswordCalled = false
    var updatePasswordCalled = false
    var hasPasswordCalled = false
    var saveS3CredentialsCalled = false
    var getS3CredentialsCalled = false
    var deleteS3CredentialsCalled = false
    var updateS3CredentialsCalled = false
    var hasS3CredentialsCalled = false

    // MARK: - Recorded Parameters
    var lastSavedPassword: String?
    var lastSavedConnectionId: UUID?
    var lastGetConnectionId: UUID?
    var lastDeleteConnectionId: UUID?
    var lastUpdatePassword: String?
    var lastUpdateConnectionId: UUID?
    var lastHasPasswordConnectionId: UUID?

    // MARK: - Mock Responses
    var mockPasswords: [UUID: String] = [:]
    var mockS3Credentials: [UUID: S3Credentials] = [:]
    var mockError: Error?
    var mockReadError: Error?
    var mockS3SaveError: Error?

    // MARK: - Protocol Implementation

    func savePassword(_ password: String, for connectionId: UUID) throws {
        savePasswordCalled = true
        lastSavedPassword = password
        lastSavedConnectionId = connectionId
        if let error = mockError { throw error }
        mockPasswords[connectionId] = password
    }

    func getPassword(for connectionId: UUID) -> String? {
        getPasswordCalled = true
        lastGetConnectionId = connectionId
        return mockPasswords[connectionId]
    }

    func readPassword(for connectionId: UUID) throws -> String? {
        if let mockReadError { throw mockReadError }
        return getPassword(for: connectionId)
    }

    func deletePassword(for connectionId: UUID) throws {
        deletePasswordCalled = true
        lastDeleteConnectionId = connectionId
        if let error = mockError { throw error }
        mockPasswords.removeValue(forKey: connectionId)
    }

    func updatePassword(_ password: String, for connectionId: UUID) throws {
        updatePasswordCalled = true
        lastUpdatePassword = password
        lastUpdateConnectionId = connectionId
        if let error = mockError { throw error }
        mockPasswords[connectionId] = password
    }

    func hasPassword(for connectionId: UUID) -> Bool {
        hasPasswordCalled = true
        lastHasPasswordConnectionId = connectionId
        return mockPasswords[connectionId] != nil
    }

    // MARK: - S3 Credentials

    func saveS3Credentials(_ credentials: S3Credentials, for connectionId: UUID) throws {
        saveS3CredentialsCalled = true
        if let error = mockS3SaveError ?? mockError { throw error }
        mockS3Credentials[connectionId] = credentials
    }

    func getS3Credentials(for connectionId: UUID) -> S3Credentials? {
        getS3CredentialsCalled = true
        return mockS3Credentials[connectionId]
    }

    func readS3Credentials(for connectionId: UUID) throws -> S3Credentials? {
        if let mockReadError { throw mockReadError }
        return getS3Credentials(for: connectionId)
    }

    func deleteS3Credentials(for connectionId: UUID) throws {
        deleteS3CredentialsCalled = true
        if let error = mockError { throw error }
        mockS3Credentials.removeValue(forKey: connectionId)
    }

    func updateS3Credentials(_ credentials: S3Credentials, for connectionId: UUID) throws {
        updateS3CredentialsCalled = true
        if let error = mockError { throw error }
        mockS3Credentials[connectionId] = credentials
    }

    func hasS3Credentials(for connectionId: UUID) -> Bool {
        hasS3CredentialsCalled = true
        return mockS3Credentials[connectionId] != nil
    }

    // MARK: - Reset
    func reset() {
        savePasswordCalled = false
        getPasswordCalled = false
        deletePasswordCalled = false
        updatePasswordCalled = false
        hasPasswordCalled = false

        lastSavedPassword = nil
        lastSavedConnectionId = nil
        lastGetConnectionId = nil
        lastDeleteConnectionId = nil
        lastUpdatePassword = nil
        lastUpdateConnectionId = nil
        lastHasPasswordConnectionId = nil

        mockPasswords = [:]
        mockS3Credentials = [:]
        mockError = nil

        saveS3CredentialsCalled = false
        getS3CredentialsCalled = false
        deleteS3CredentialsCalled = false
        updateS3CredentialsCalled = false
        hasS3CredentialsCalled = false
    }
}
