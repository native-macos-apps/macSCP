//
//  SFTPSession.swift
//  macSCP
//
//  Native Actor-based SFTP session using apple/swift-nio-ssh (no Citadel dependency)
//

import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH

actor SFTPSession: SFTPSessionProtocol {
    private var connection: SSHConnection?
    private var client: SFTPClient?
    private(set) var isConnected = false
    private(set) var currentPath = "/"

    init() {}

    // MARK: - Connection

    func connect(
        host: String,
        port: Int,
        username: String,
        password: String
    ) async throws {
        logInfo("Connecting to \(username)@\(host):\(port) with password", category: .sftp)

        let normalizedHost = (host.lowercased() == "localhost") ? "127.0.0.1" : host
        let conn = SSHConnection()
        self.connection = conn

        do {
            let userAuth = SimplePasswordDelegate(username: username, password: password)
            let sftpClient = try await conn.connect(
                host: normalizedHost,
                port: port,
                userAuthDelegate: userAuth
            )

            self.client = sftpClient
            self.isConnected = true
            self.currentPath = try await getRealPath(at: ".")
            logInfo("Connected successfully to \(host)", category: .sftp)
        } catch {
            await conn.disconnect()
            self.connection = nil
            self.client = nil
            self.isConnected = false
            throw parseError(error)
        }
    }

    func connect(
        host: String,
        port: Int,
        username: String,
        privateKeyPath: String,
        bookmarkData: Data?,
        passphrase: String?
    ) async throws {
        logInfo("Connecting to \(username)@\(host):\(port) with private key", category: .sftp)

        let normalizedHost = (host.lowercased() == "localhost") ? "127.0.0.1" : host
        let conn = SSHConnection()
        self.connection = conn

        do {
            // Read private key file with security-scoped bookmark support
            var privateKeyURL: URL
            var isStale = false
            var accessedSecurityScope = false

            if let bookmarkData = bookmarkData {
                privateKeyURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isStale {
                    logWarning("Private key bookmark is stale for \(privateKeyURL.path)", category: .sftp)
                }
                accessedSecurityScope = privateKeyURL.startAccessingSecurityScopedResource()
                if !accessedSecurityScope {
                    throw AppError.connectionFailed("Couldn't access the saved private key. Re-select the key file in connection settings.")
                }
            } else {
                privateKeyURL = URL(fileURLWithPath: privateKeyPath)
            }

            defer {
                if accessedSecurityScope {
                    privateKeyURL.stopAccessingSecurityScopedResource()
                }
            }

            let privateKeyData = try Data(contentsOf: privateKeyURL)
            let privateKeyString = String(data: privateKeyData, encoding: .utf8) ?? ""

            let privateKey = try SSHKeyParser.parsePrivateKey(from: privateKeyString, passphrase: passphrase)
            let userAuth = SSHKeyUserAuthDelegate(username: username, privateKey: privateKey)

            let sftpClient = try await conn.connect(
                host: normalizedHost,
                port: port,
                userAuthDelegate: userAuth
            )

            self.client = sftpClient
            self.isConnected = true
            self.currentPath = try await getRealPath(at: ".")
            logInfo("Connected successfully to \(host) using private key", category: .sftp)
        } catch {
            await conn.disconnect()
            self.connection = nil
            self.client = nil
            self.isConnected = false
            throw parseError(error)
        }
    }

    func disconnect() async {
        logInfo("Disconnecting from server", category: .sftp)
        await client?.close()
        await connection?.disconnect()

        client = nil
        connection = nil
        isConnected = false
        currentPath = "/"
    }

    // MARK: - File & Directory Operations

    func listFiles(at path: String) async throws -> [RemoteFile] {
        guard let client = client else { throw AppError.notConnected }

        let actualPath = try await resolvePath(path)
        let entries = try await client.listDirectory(at: actualPath)

        var files: [RemoteFile] = []
        for entry in entries {
            let isDirectory = entry.attributes.isDirectory
            var fullPath = actualPath.hasSuffix("/")
                ? "\(actualPath)\(entry.filename)"
                : "\(actualPath)/\(entry.filename)"

            if isDirectory && !fullPath.hasSuffix("/") {
                fullPath += "/"
            }

            let size = Int64(entry.attributes.size ?? 0)
            let permissions = entry.attributes.formatPermissions()
            let modDate = entry.attributes.modificationTime

            files.append(RemoteFile(
                name: entry.filename,
                path: fullPath,
                isDirectory: isDirectory,
                size: size,
                permissions: permissions,
                modificationDate: modDate
            ))
        }

        currentPath = actualPath
        return RemoteFile.sortedFiles(files, by: .name)
    }

    func getFileInfo(at path: String) async throws -> RemoteFile {
        guard let client = client else { throw AppError.notConnected }

        let attrs = try await client.stat(at: path)
        let isDirectory = attrs.isDirectory
        let size = Int64(attrs.size ?? 0)
        let permissions = attrs.formatPermissions()
        let modDate = attrs.modificationTime
        let fileName = (path as NSString).lastPathComponent

        return RemoteFile(
            name: fileName,
            path: path,
            isDirectory: isDirectory,
            size: size,
            permissions: permissions,
            modificationDate: modDate
        )
    }

    func createDirectory(at path: String) async throws {
        guard let client = client else { throw AppError.notConnected }
        do {
            try await client.createDirectory(at: path)
            logInfo("Created directory: \(path)", category: .sftp)
        } catch {
            throw parseError(error)
        }
    }

    func createFile(at path: String) async throws {
        guard let client = client else { throw AppError.notConnected }
        do {
            let handle = try await client.openFile(path: path, flags: [.write, .creat, .trunc])
            try await client.closeHandle(handle)
            logInfo("Created empty file: \(path)", category: .sftp)
        } catch {
            throw parseError(error)
        }
    }

    func deleteFile(at path: String) async throws {
        guard let client = client else { throw AppError.notConnected }
        do {
            try await client.removeFile(at: path)
            logInfo("Deleted file: \(path)", category: .sftp)
        } catch {
            throw parseError(error)
        }
    }

    /// Pure native SFTP recursive delete without requiring remote shell access
    func deleteDirectory(at path: String) async throws {
        guard let client = client else { throw AppError.notConnected }
        do {
            try await client.removeDirectoryRecursive(at: path)
            logInfo("Recursively deleted directory: \(path)", category: .sftp)
        } catch {
            throw parseError(error)
        }
    }

    func rename(from sourcePath: String, to destinationPath: String) async throws {
        guard let client = client else { throw AppError.notConnected }
        do {
            try await client.rename(from: sourcePath, to: destinationPath)
            logInfo("Renamed \(sourcePath) to \(destinationPath)", category: .sftp)
        } catch {
            throw parseError(error)
        }
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        try await rename(from: sourcePath, to: destinationPath)
    }

    func copyFile(from sourcePath: String, to destinationPath: String) async throws {
        guard let connection = connection else { throw AppError.notConnected }
        // Fast server-side copy via shell if available
        do {
            let result = try await connection.executeCommand("cp '\(sourcePath)' '\(destinationPath)'")
            if result.lowercased().contains("permission denied") {
                throw AppError.permissionDenied
            }
            logInfo("Copied file: \(sourcePath) to \(destinationPath)", category: .sftp)
        } catch {
            throw parseError(error)
        }
    }

    func copyDirectory(from sourcePath: String, to destinationPath: String) async throws {
        guard let connection = connection else { throw AppError.notConnected }
        do {
            let result = try await connection.executeCommand("cp -r '\(sourcePath)' '\(destinationPath)'")
            if result.lowercased().contains("permission denied") {
                throw AppError.permissionDenied
            }
            logInfo("Copied directory: \(sourcePath) to \(destinationPath)", category: .sftp)
        } catch {
            throw parseError(error)
        }
    }

    // MARK: - High-Performance Pipelined Transfers

    func downloadFile(from remotePath: String, to localURL: URL) async throws {
        try await downloadFile(from: remotePath, to: localURL, progress: nil)
    }

    func downloadFile(from remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {
        guard let client = client else { throw AppError.notConnected }

        do {
            try await SFTPTransferEngine.download(
                client: client,
                remotePath: remotePath,
                localURL: localURL,
                progress: progress
            )
            logInfo("Pipelined download completed: \(remotePath) -> \(localURL.path)", category: .sftp)
        } catch {
            throw parseError(error)
        }
    }

    func uploadFile(from localURL: URL, to remotePath: String) async throws {
        try await uploadFile(from: localURL, to: remotePath, progress: nil)
    }

    func uploadFile(from localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {
        guard let client = client else { throw AppError.notConnected }

        do {
            try await SFTPTransferEngine.upload(
                client: client,
                localURL: localURL,
                remotePath: remotePath,
                progress: progress
            )
            logInfo("Pipelined upload completed: \(localURL.path) -> \(remotePath)", category: .sftp)
        } catch {
            throw parseError(error)
        }
    }

    func readFileContent(at path: String) async throws -> String {
        guard let client = client else { throw AppError.notConnected }

        let handle = try await client.openFile(path: path, flags: [.read])
        defer {
            Task {
                try? await client.closeHandle(handle)
            }
        }

        var offset: UInt64 = 0
        var allData = Data()
        let chunkSize: UInt32 = 64 * 1024

        while let chunk = try await client.read(handle: handle, offset: offset, length: chunkSize) {
            let data = Data(buffer: chunk)
            if data.isEmpty { break }
            allData.append(data)
            offset += UInt64(data.count)
        }

        return String(data: allData, encoding: .utf8) ?? ""
    }

    func writeFileContent(_ content: String, to path: String) async throws {
        guard let client = client else { throw AppError.notConnected }

        let handle = try await client.openFile(path: path, flags: [.write, .creat, .trunc])
        defer {
            Task {
                try? await client.closeHandle(handle)
            }
        }

        let contentData = content.data(using: .utf8) ?? Data()
        var buffer = ByteBufferAllocator().buffer(capacity: contentData.count)
        buffer.writeBytes(contentData)

        try await client.write(handle: handle, offset: 0, data: buffer)
        logInfo("Wrote content to: \(path)", category: .sftp)
    }

    func getRealPath(at path: String) async throws -> String {
        guard let client = client else { throw AppError.notConnected }
        return try await client.realPath(at: path)
    }

    func executeCommand(_ command: String) async throws -> String {
        guard let connection = connection else { throw AppError.notConnected }
        return try await connection.executeCommand(command)
    }

    // MARK: - Private Helpers

    private func resolvePath(_ path: String) async throws -> String {
        guard let client = client else { throw AppError.notConnected }

        if path == "~" || path == "." {
            return try await client.realPath(at: ".")
        } else if path == ".." {
            let components = currentPath.split(separator: "/")
            if components.count > 1 {
                return "/" + components.dropLast().joined(separator: "/")
            }
            return "/"
        } else if path.hasPrefix("/") {
            return path
        } else {
            return currentPath.appendingPathComponent(path)
        }
    }

    private func parseError(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }

        if let sftpError = error as? SFTPClientError {
            switch sftpError {
            case .connectionClosed:
                return .connectionLost
            case .failure(let code, let msg):
                switch code {
                case .noSuchFile:
                    return .fileNotFound
                case .permissionDenied:
                    return .permissionDenied
                case .connectionLost, .noConnection:
                    return .connectionLost
                default:
                    return .sftpOperationFailed(msg.isEmpty ? "SFTP operation failed" : msg)
                }
            default:
                return .sftpOperationFailed(sftpError.localizedDescription)
            }
        }

        let description = error.localizedDescription.lowercased()
        if description.contains("connection refused") {
            return .connectionFailed("Connection refused. Make sure the SSH server is running.")
        } else if description.contains("host unreachable") || description.contains("no route to host") {
            return .hostUnreachable
        } else if description.contains("timeout") {
            return .connectionTimeout
        } else if description.contains("authentication") || description.contains("permission denied") {
            return .authenticationFailed
        }

        return .connectionFailed(error.localizedDescription)
    }
}
