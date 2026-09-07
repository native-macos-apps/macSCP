//
//  SFTPClient.swift
//  macSCP
//
//  Asynchronous SFTP v3 Client Actor managing request dispatching & operations
//

import Foundation
import NIOCore

actor SFTPClient: SFTPChannelHandlerDelegate {
    private let channel: Channel
    private var nextRequestId: UInt32 = 1
    private var pendingRequests: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private var initContinuation: CheckedContinuation<SFTPResponse, Error>?
    private var isClosed = false

    init(channel: Channel) {
        self.channel = channel
    }

    // MARK: - Delegate Callbacks

    nonisolated func sftpChannelHandler(_ handler: SFTPChannelHandler, didReceiveResponse response: SFTPResponse) {
        Task {
            await self.handleResponse(response)
        }
    }

    nonisolated func sftpChannelHandler(_ handler: SFTPChannelHandler, didCloseWithError error: Error?) {
        Task {
            await self.handleClose(error: error)
        }
    }

    private func handleResponse(_ response: SFTPResponse) {
        if case .version = response {
            if let cont = initContinuation {
                initContinuation = nil
                cont.resume(returning: response)
            }
            return
        }

        guard let reqId = response.requestId, let continuation = pendingRequests.removeValue(forKey: reqId) else {
            return
        }

        continuation.resume(returning: response)
    }

    private func handleClose(error: Error?) {
        isClosed = true
        let finalError = error ?? SFTPClientError.connectionClosed

        if let cont = initContinuation {
            initContinuation = nil
            cont.resume(throwing: finalError)
        }

        let currentRequests = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in currentRequests {
            continuation.resume(throwing: finalError)
        }
    }

    // MARK: - Request Execution

    private func allocateRequestId() -> UInt32 {
        let id = nextRequestId
        nextRequestId = (nextRequestId == UInt32.max) ? 1 : (nextRequestId + 1)
        return id
    }

    private func sendRequest(_ packet: ByteBuffer, requestId: UInt32) async throws -> SFTPResponse {
        guard !isClosed else {
            throw SFTPClientError.connectionClosed
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation
            channel.writeAndFlush(packet, promise: nil)
        }
    }

    // MARK: - Core Operations

    func initialize() async throws {
        let packet = SFTPRequestBuilder.buildInit(version: 3)
        let response: SFTPResponse = try await withCheckedThrowingContinuation { continuation in
            self.initContinuation = continuation
            channel.writeAndFlush(packet, promise: nil)
        }

        guard case .version(let version, _) = response else {
            throw SFTPClientError.invalidPacket
        }

        guard version >= 3 else {
            throw SFTPClientError.unsupportedVersion(version)
        }
    }

    func realPath(at path: String) async throws -> String {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildRealPath(requestId: reqId, path: path)
        let response = try await sendRequest(packet, requestId: reqId)

        switch response {
        case .name(_, let entries):
            guard let first = entries.first else {
                throw SFTPClientError.invalidPacket
            }
            return first.filename
        case .status(_, let code, let message):
            throw SFTPClientError.failure(code: code, message: message)
        default:
            throw SFTPClientError.invalidPacket
        }
    }

    func openFile(path: String, flags: SFTPOpenFlags, attributes: SFTPFileAttributes = .init()) async throws -> ByteBuffer {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildOpen(requestId: reqId, path: path, flags: flags, attributes: attributes)
        let response = try await sendRequest(packet, requestId: reqId)

        switch response {
        case .handle(_, let handle):
            return handle
        case .status(_, let code, let message):
            throw SFTPClientError.failure(code: code, message: message)
        default:
            throw SFTPClientError.invalidPacket
        }
    }

    func closeHandle(_ handle: ByteBuffer) async throws {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildClose(requestId: reqId, handle: handle)
        let response = try await sendRequest(packet, requestId: reqId)

        if case .status(_, let code, let message) = response {
            if code != .ok {
                throw SFTPClientError.failure(code: code, message: message)
            }
        }
    }

    /// Reads bytes from an open file handle at the given offset. Returns nil on EOF.
    func read(handle: ByteBuffer, offset: UInt64, length: UInt32) async throws -> ByteBuffer? {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildRead(requestId: reqId, handle: handle, offset: offset, length: length)
        let response = try await sendRequest(packet, requestId: reqId)

        switch response {
        case .data(_, let data):
            return data
        case .status(_, let code, let message):
            if code == .eof {
                return nil
            }
            throw SFTPClientError.failure(code: code, message: message)
        default:
            throw SFTPClientError.invalidPacket
        }
    }

    /// Writes bytes to an open file handle at the given offset.
    func write(handle: ByteBuffer, offset: UInt64, data: ByteBuffer) async throws {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildWrite(requestId: reqId, handle: handle, offset: offset, data: data)
        let response = try await sendRequest(packet, requestId: reqId)

        switch response {
        case .status(_, let code, let message):
            if code != .ok {
                throw SFTPClientError.failure(code: code, message: message)
            }
        default:
            throw SFTPClientError.invalidPacket
        }
    }

    func openDir(at path: String) async throws -> ByteBuffer {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildOpenDir(requestId: reqId, path: path)
        let response = try await sendRequest(packet, requestId: reqId)

        switch response {
        case .handle(_, let handle):
            return handle
        case .status(_, let code, let message):
            throw SFTPClientError.failure(code: code, message: message)
        default:
            throw SFTPClientError.invalidPacket
        }
    }

    /// Reads directory entries from an open directory handle. Returns nil on EOF.
    func readDir(handle: ByteBuffer) async throws -> [SFTPNameEntry]? {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildReadDir(requestId: reqId, handle: handle)
        let response = try await sendRequest(packet, requestId: reqId)

        switch response {
        case .name(_, let entries):
            return entries
        case .status(_, let code, let message):
            if code == .eof {
                return nil
            }
            throw SFTPClientError.failure(code: code, message: message)
        default:
            throw SFTPClientError.invalidPacket
        }
    }

    /// Lists all entries in a remote directory, handling pagination and filtering . and ..
    func listDirectory(at path: String) async throws -> [SFTPNameEntry] {
        let handle = try await openDir(at: path)
        defer {
            Task {
                try? await self.closeHandle(handle)
            }
        }

        var allEntries: [SFTPNameEntry] = []
        while let batch = try await readDir(handle: handle) {
            for entry in batch {
                if entry.filename != "." && entry.filename != ".." {
                    allEntries.append(entry)
                }
            }
        }

        return allEntries
    }

    func stat(at path: String) async throws -> SFTPFileAttributes {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildStat(requestId: reqId, path: path)
        let response = try await sendRequest(packet, requestId: reqId)

        switch response {
        case .attrs(_, let attributes):
            return attributes
        case .status(_, let code, let message):
            throw SFTPClientError.failure(code: code, message: message)
        default:
            throw SFTPClientError.invalidPacket
        }
    }

    func lstat(at path: String) async throws -> SFTPFileAttributes {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildLStat(requestId: reqId, path: path)
        let response = try await sendRequest(packet, requestId: reqId)

        switch response {
        case .attrs(_, let attributes):
            return attributes
        case .status(_, let code, let message):
            throw SFTPClientError.failure(code: code, message: message)
        default:
            throw SFTPClientError.invalidPacket
        }
    }

    func createDirectory(at path: String, attributes: SFTPFileAttributes = .init()) async throws {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildMkDir(requestId: reqId, path: path, attributes: attributes)
        let response = try await sendRequest(packet, requestId: reqId)

        if case .status(_, let code, let message) = response {
            if code != .ok {
                throw SFTPClientError.failure(code: code, message: message)
            }
        }
    }

    func removeFile(at path: String) async throws {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildRemove(requestId: reqId, path: path)
        let response = try await sendRequest(packet, requestId: reqId)

        if case .status(_, let code, let message) = response {
            if code != .ok {
                throw SFTPClientError.failure(code: code, message: message)
            }
        }
    }

    func removeDirectory(at path: String) async throws {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildRmDir(requestId: reqId, path: path)
        let response = try await sendRequest(packet, requestId: reqId)

        if case .status(_, let code, let message) = response {
            if code != .ok {
                throw SFTPClientError.failure(code: code, message: message)
            }
        }
    }

    func rename(from sourcePath: String, to destinationPath: String) async throws {
        let reqId = allocateRequestId()
        let packet = SFTPRequestBuilder.buildRename(requestId: reqId, oldPath: sourcePath, newPath: destinationPath)
        let response = try await sendRequest(packet, requestId: reqId)

        if case .status(_, let code, let message) = response {
            if code != .ok {
                throw SFTPClientError.failure(code: code, message: message)
            }
        }
    }

    /// Pure native SFTP recursive delete without requiring remote shell access
    func removeDirectoryRecursive(at path: String) async throws {
        let entries = try await listDirectory(at: path)

        for entry in entries {
            let childPath = path.hasSuffix("/") ? "\(path)\(entry.filename)" : "\(path)/\(entry.filename)"
            if entry.attributes.isDirectory {
                try await removeDirectoryRecursive(at: childPath)
            } else {
                try await removeFile(at: childPath)
            }
        }

        try await removeDirectory(at: path)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        channel.close(promise: nil)
    }
}
