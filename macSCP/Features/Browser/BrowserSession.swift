//
//  BrowserSession.swift
//  macSCP
//
//  Protocol abstraction for Local, SFTP, and S3 browser session lifecycles
//

import Foundation

protocol BrowserSessionProtocol: Sendable {
    var logCategory: LogCategory { get }
    var isLocal: Bool { get }

    func connect(initialPath: String) async throws -> String
    func disconnect() async
    func resolveCurrentPath(afterListing path: String, fallback: String) async -> String
    func homePath() -> String
    func s3ObjectURL(for path: String) async throws -> URL
    func s3PresignedURL(for path: String, expiresIn: TimeInterval) async throws -> URL
}

extension BrowserSessionProtocol {
    func s3ObjectURL(for path: String) async throws -> URL {
        throw AppError.notConnected
    }

    func s3PresignedURL(for path: String, expiresIn: TimeInterval) async throws -> URL {
        throw AppError.notConnected
    }
}

struct LocalBrowserSession: BrowserSessionProtocol {
    let logCategory: LogCategory = .local
    let isLocal: Bool = true

    func connect(initialPath: String) async throws -> String {
        if initialPath.isEmpty || initialPath == "/" {
            return LocalFileRepository.userHomeDirectory
        }
        return initialPath
    }

    func disconnect() async {}

    func resolveCurrentPath(afterListing path: String, fallback: String) async -> String {
        (path as NSString).expandingTildeInPath
    }

    func homePath() -> String {
        LocalFileRepository.userHomeDirectory
    }
}

struct SFTPBrowserSession: BrowserSessionProtocol {
    let connection: Connection
    let password: String
    let session: SFTPSessionProtocol
    let sshKeyRepository: SSHKeyRepositoryProtocol

    let logCategory: LogCategory = .sftp
    let isLocal: Bool = false

    func connect(initialPath: String) async throws -> String {
        switch connection.authMethod {
        case .password:
            try await session.connect(
                host: connection.host,
                port: connection.port,
                username: connection.username,
                password: password
            )
        case .privateKey:
            guard let sshKeyId = connection.sshKeyId else {
                throw AppError.connectionFailed("No SSH key selected for this connection. Please edit the connection and select an SSH key.")
            }
            guard let keyContent = try sshKeyRepository.getPrivateKeyContent(for: sshKeyId), !keyContent.isEmpty else {
                throw AppError.connectionFailed("SSH key was not found in Keychain. Please edit the connection and re-select or import an SSH key.")
            }
            try await session.connect(
                host: connection.host,
                port: connection.port,
                username: connection.username,
                privateKeyContent: keyContent,
                passphrase: password.isEmpty ? nil : password
            )
        }
        return await session.currentPath
    }

    func disconnect() async {
        await session.disconnect()
    }

    func resolveCurrentPath(afterListing path: String, fallback: String) async -> String {
        await session.currentPath
    }

    func homePath() -> String {
        "~"
    }
}

struct S3BrowserSession: BrowserSessionProtocol {
    let connection: Connection
    let secretAccessKey: String
    let session: S3SessionProtocol

    let logCategory: LogCategory = .s3
    let isLocal: Bool = false

    func connect(initialPath: String) async throws -> String {
        try await session.connect(
            accessKeyId: connection.username,
            secretAccessKey: secretAccessKey,
            region: connection.s3Region ?? "us-east-1",
            bucket: connection.s3Bucket ?? "",
            endpoint: connection.s3Endpoint
        )
        return await session.currentPath
    }

    func disconnect() async {
        await session.disconnect()
    }

    func resolveCurrentPath(afterListing path: String, fallback: String) async -> String {
        await session.currentPath
    }

    func homePath() -> String {
        "~"
    }

    func s3ObjectURL(for path: String) async throws -> URL {
        try await session.publicURL(for: path)
    }

    func s3PresignedURL(for path: String, expiresIn: TimeInterval) async throws -> URL {
        try await session.presignedURL(for: path, expiresIn: expiresIn)
    }
}
