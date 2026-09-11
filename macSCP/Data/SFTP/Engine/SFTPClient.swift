//
//  SFTPClient.swift
//  macSCP
//
//  Asynchronous SFTP v3 Client Actor managing request dispatching & operations
//

import Foundation
import NIOCore

private final class SFTPClientState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var isClosed = false
    private var pendingRequests: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private var initContinuation: CheckedContinuation<SFTPResponse, Error>?

    func registerInit(continuation: CheckedContinuation<SFTPResponse, Error>) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else {
            throw SFTPClientError.connectionClosed
        }
        self.initContinuation = continuation
    }

    func registerRequest(id: UInt32, continuation: CheckedContinuation<SFTPResponse, Error>) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else {
            throw SFTPClientError.connectionClosed
        }
        pendingRequests[id] = continuation
    }

    func resumeResponse(_ response: SFTPResponse) {
        lock.lock()
        if case .version = response {
            let cont = initContinuation
            initContinuation = nil
            lock.unlock()
            cont?.resume(returning: response)
            return
        }

        guard let reqId = response.requestId, let continuation = pendingRequests.removeValue(forKey: reqId) else {
            lock.unlock()
            return
        }
        lock.unlock()
        continuation.resume(returning: response)
    }

    func failRequest(id: UInt32, error: Error) {
        lock.lock()
        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        lock.unlock()
        continuation.resume(throwing: error)
    }

    func failInit(error: Error) {
        lock.lock()
        guard let cont = initContinuation else {
            lock.unlock()
            return
        }
        initContinuation = nil
        lock.unlock()
        cont.resume(throwing: error)
    }

    func close(error: Error?) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let finalError = error ?? SFTPClientError.connectionClosed
        let cont = initContinuation
        initContinuation = nil
        let currentRequests = pendingRequests
        pendingRequests.removeAll()
        lock.unlock()

        cont?.resume(throwing: finalError)
        for (_, continuation) in currentRequests {
            continuation.resume(throwing: finalError)
        }
    }
}

actor SFTPClient: SFTPChannelHandlerDelegate {
    private let channel: Channel
    private var nextRequestId: UInt32 = 1
    private let state = SFTPClientState()

    init(channel: Channel) {
        self.channel = channel
    }

    // MARK: - Delegate Callbacks

    nonisolated func sftpChannelHandler(_ handler: SFTPChannelHandler, didReceiveResponse response: SFTPResponse) {
        state.resumeResponse(response)
    }

    nonisolated func sftpChannelHandler(_ handler: SFTPChannelHandler, didCloseWithError error: Error?) {
        state.close(error: error)
    }

    // MARK: - Request Execution

    private func allocateRequestId() -> UInt32 {
        let id = nextRequestId
        nextRequestId = (nextRequestId == UInt32.max) ? 1 : (nextRequestId + 1)
        return id
    }

    private func sendRequest(_ packet: ByteBuffer, requestId: UInt32, timeoutSeconds: TimeInterval = 30) async throws -> SFTPResponse {
        guard !state.isClosed else {
            throw SFTPClientError.connectionClosed
        }

        let promise = channel.eventLoop.makePromise(of: Void.self)
        let stateRef = self.state

        promise.futureResult.whenFailure { error in
            stateRef.failRequest(id: requestId, error: error)
        }

        let timeoutTask = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            stateRef.failRequest(id: requestId, error: SFTPClientError.timeout)
        }

        do {
            let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFTPResponse, Error>) in
                do {
                    try state.registerRequest(id: requestId, continuation: continuation)
                    channel.writeAndFlush(packet, promise: promise)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            timeoutTask.cancel()
            return response
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    // MARK: - Core Operations

    func initialize(timeoutSeconds: TimeInterval = 15) async throws {
        let packet = SFTPRequestBuilder.buildInit(version: 3)
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let stateRef = self.state

        promise.futureResult.whenFailure { error in
            stateRef.failInit(error: error)
        }

        let timeoutTask = channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            stateRef.failInit(error: SFTPClientError.timeout)
        }

        let response: SFTPResponse
        do {
            response = try await withCheckedThrowingContinuation { continuation in
                do {
                    try state.registerInit(continuation: continuation)
                    channel.writeAndFlush(packet, promise: promise)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            throw error
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
        guard !state.isClosed else { return }
        state.close(error: nil)
        channel.close(promise: nil)
    }
}
