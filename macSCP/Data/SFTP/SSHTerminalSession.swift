//
//  SSHTerminalSession.swift
//  macSCP
//
//  Native Actor-based interactive SSH terminal session using apple/swift-nio-ssh.
//  Private keys are parsed in memory and never written to disk.
//

import Foundation
import NIOCore
@preconcurrency import NIOSSH

actor SSHTerminalSession: SSHTerminalSessionProtocol {
    private var connection: SSHConnection?
    private var shellChannel: SSHShellChannel?
    private(set) var isConnected = false

    init() {}

    func connect(
        host: String,
        port: Int,
        username: String,
        password: String,
        cols: Int,
        rows: Int,
        onData: @escaping @Sendable ([UInt8]) -> Void,
        onClose: @escaping @Sendable (Int?, Error?) -> Void
    ) async throws {
        logInfo("Connecting SSH terminal to \(username)@\(host):\(port) with password", category: .sftp)
        let userAuth = SimplePasswordDelegate(username: username, password: password)
        try await openShell(
            host: host,
            port: port,
            userAuthDelegate: userAuth,
            cols: cols,
            rows: rows,
            onData: onData,
            onClose: onClose
        )
    }

    func connect(
        host: String,
        port: Int,
        username: String,
        privateKeyContent: String,
        passphrase: String?,
        cols: Int,
        rows: Int,
        onData: @escaping @Sendable ([UInt8]) -> Void,
        onClose: @escaping @Sendable (Int?, Error?) -> Void
    ) async throws {
        logInfo("Connecting SSH terminal to \(username)@\(host):\(port) with in-app private key", category: .sftp)
        let nioPrivateKey = try SSHKeyParser.parsePrivateKey(from: privateKeyContent, passphrase: passphrase)
        let userAuth = SSHKeyUserAuthDelegate(username: username, privateKey: nioPrivateKey)
        try await openShell(
            host: host,
            port: port,
            userAuthDelegate: userAuth,
            cols: cols,
            rows: rows,
            onData: onData,
            onClose: onClose
        )
    }

    func send(_ bytes: [UInt8]) async {
        shellChannel?.write(bytes)
    }

    func resize(cols: Int, rows: Int) async {
        shellChannel?.resize(cols: cols, rows: rows)
    }

    func disconnect() async {
        logInfo("Disconnecting SSH terminal session", category: .sftp)
        isConnected = false
        await shellChannel?.close()
        await connection?.disconnect()
        shellChannel = nil
        connection = nil
    }

    // MARK: - Helpers

    /// Builds a POSIX-safe `cd` command for the remote login shell when an initial directory is requested.
    /// Rejects control characters (`\0`, `\r`, `\n`) and uses single-quote POSIX escaping to prevent shell injection.
    nonisolated static func makeInitialDirectoryCommand(for path: String?) -> String? {
        guard let rawPath = path else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/", trimmed != "~" else {
            return nil
        }

        // Reject control characters that could inject extra lines or truncate strings
        if rawPath.contains("\0") || rawPath.contains("\r") || rawPath.contains("\n") {
            return nil
        }

        let posixEscaped = "'" + rawPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(posixEscaped) && clear\n"
    }

    // MARK: - Private

    private func openShell(
        host: String,
        port: Int,
        userAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
        cols: Int,
        rows: Int,
        onData: @escaping @Sendable ([UInt8]) -> Void,
        onClose: @escaping @Sendable (Int?, Error?) -> Void
    ) async throws {
        await disconnect()

        let normalizedHost = (host.lowercased() == "localhost") ? "127.0.0.1" : host
        let conn = SSHConnection()
        self.connection = conn

        do {
            let channel = try await conn.connectShell(
                host: normalizedHost,
                port: port,
                userAuthDelegate: userAuthDelegate,
                cols: cols,
                rows: rows,
                onData: onData,
                onClose: onClose
            )
            self.shellChannel = channel
            self.isConnected = true
            logInfo("SSH terminal connected to \(host):\(port)", category: .sftp)
        } catch {
            await conn.disconnect()
            self.connection = nil
            self.shellChannel = nil
            self.isConnected = false
            throw mapError(error)
        }
    }

    private func mapError(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }

        if let channelError = error as? ChannelError {
            switch channelError {
            case .eof, .ioOnClosedChannel:
                return .connectionFailed("Connection closed by remote host. Please verify your SSH credentials.")
            case .connectTimeout:
                return .connectionTimeout
            case .writeHostUnreachable:
                return .hostUnreachable
            default:
                return .connectionFailed(channelError.description)
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
