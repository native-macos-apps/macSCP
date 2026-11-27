//
//  KeychainServiceProtocol.swift
//  macSCP
//
//  Protocol for keychain operations
//

import Foundation

protocol KeychainServiceProtocol: Sendable {
    /// Saves a password for a connection
    func savePassword(_ password: String, for connectionId: UUID) throws

    /// Retrieves a password for a connection
    func getPassword(for connectionId: UUID) -> String?

    /// Distinguishes a missing password from a failed Keychain read.
    func readPassword(for connectionId: UUID) throws -> String?

    /// Deletes a password for a connection
    func deletePassword(for connectionId: UUID) throws

    /// Updates a password for a connection
    func updatePassword(_ password: String, for connectionId: UUID) throws

    /// Checks if a password exists for a connection
    func hasPassword(for connectionId: UUID) -> Bool

    // MARK: - S3 Credentials

    /// Saves S3 credentials for a connection
    func saveS3Credentials(_ credentials: S3Credentials, for connectionId: UUID) throws

    /// Retrieves S3 credentials for a connection
    func getS3Credentials(for connectionId: UUID) -> S3Credentials?

    /// Distinguishes missing credentials from a failed Keychain read.
    func readS3Credentials(for connectionId: UUID) throws -> S3Credentials?

    /// Deletes S3 credentials for a connection
    func deleteS3Credentials(for connectionId: UUID) throws

    /// Updates S3 credentials for a connection
    func updateS3Credentials(_ credentials: S3Credentials, for connectionId: UUID) throws

    /// Checks if S3 credentials exist for a connection
    func hasS3Credentials(for connectionId: UUID) -> Bool
}
