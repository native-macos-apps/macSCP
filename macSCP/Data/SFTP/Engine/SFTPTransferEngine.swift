//
//  SFTPTransferEngine.swift
//  macSCP
//
//  High-Performance Pipelined SFTP Transfer Engine using a Concurrent Sliding Window
//  Supports both individual files and recursive directory transfers
//

import Foundation
import NIOCore
import NIOFoundationCompat

final class SFTPTransferEngine: Sendable {
    nonisolated static let defaultChunkSize: UInt32 = 32 * 1024 // 32 KB per chunk, standard SFTP packet size avoiding SSH channel fragmentation
    nonisolated static let defaultWindowSize: Int = 6           // 6 in-flight chunks = 192 KB window per stream, optimal for concurrent transfers without channel saturation

    // MARK: - Download

    static func download(
        client: SFTPClient,
        remotePath: String,
        localURL: URL,
        chunkSize: UInt32 = defaultChunkSize,
        windowSize: Int = defaultWindowSize,
        progress: TransferProgressHandler?
    ) async throws {
        let attrs = try await client.stat(at: remotePath)
        if attrs.isDirectory {
            try await downloadDirectory(
                client: client,
                remoteDirPath: remotePath,
                localDirURL: localURL,
                chunkSize: chunkSize,
                windowSize: windowSize,
                progress: progress
            )
        } else {
            try await downloadSingleFile(
                client: client,
                remotePath: remotePath,
                localURL: localURL,
                fileSize: attrs.size ?? 0,
                chunkSize: chunkSize,
                windowSize: windowSize,
                progress: progress
            )
        }
    }

    private static func downloadDirectory(
        client: SFTPClient,
        remoteDirPath: String,
        localDirURL: URL,
        chunkSize: UInt32,
        windowSize: Int,
        progress: TransferProgressHandler?,
        tracker: CumulativeTransferTracker? = nil
    ) async throws {
        let activeTracker = tracker ?? CumulativeTransferTracker(progress: progress)
        try FileManager.default.createDirectory(at: localDirURL, withIntermediateDirectories: true)
        let entries = try await client.listDirectory(at: remoteDirPath)

        for entry in entries {
            try Task.checkCancellation()

            let childRemote = remoteDirPath.hasSuffix("/")
                ? "\(remoteDirPath)\(entry.filename)"
                : "\(remoteDirPath)/\(entry.filename)"
            let childLocal = localDirURL.appendingPathComponent(entry.filename)

            if entry.attributes.isDirectory {
                try await downloadDirectory(
                    client: client,
                    remoteDirPath: childRemote,
                    localDirURL: childLocal,
                    chunkSize: chunkSize,
                    windowSize: windowSize,
                    progress: progress,
                    tracker: activeTracker
                )
            } else {
                let fileSize = entry.attributes.size ?? 0
                activeTracker.startFile()
                try await downloadSingleFile(
                    client: client,
                    remotePath: childRemote,
                    localURL: childLocal,
                    fileSize: fileSize,
                    chunkSize: chunkSize,
                    windowSize: windowSize,
                    progress: { fileBytes in
                        activeTracker.updateCurrentFile(bytes: fileBytes)
                    }
                )
                activeTracker.finishFile(size: Int64(fileSize))
            }
        }
    }

    private static func downloadSingleFile(
        client: SFTPClient,
        remotePath: String,
        localURL: URL,
        fileSize: UInt64,
        chunkSize: UInt32,
        windowSize: Int,
        progress: TransferProgressHandler?
    ) async throws {
        progress?(0)

        let handle = try await client.openFile(path: remotePath, flags: [.read])
        var needsRemoteClose = true
        defer {
            if needsRemoteClose {
                Task { try? await client.closeHandle(handle) }
            }
        }

        let fileHandle = try prepareLocalDestinationFile(at: localURL)
        defer { try? fileHandle.close() }

        if fileSize == 0 {
            progress?(0)
        } else if fileSize <= UInt64(chunkSize) {
            try await downloadSmallFile(
                client: client,
                handle: handle,
                fileHandle: fileHandle,
                fileSize: UInt32(fileSize),
                progress: progress
            )
        } else {
            try await downloadWithSlidingWindow(
                client: client,
                handle: handle,
                fileHandle: fileHandle,
                fileSize: fileSize,
                chunkSize: chunkSize,
                windowSize: max(1, windowSize),
                progress: progress
            )
        }

        needsRemoteClose = false
        try await client.closeHandle(handle)
    }

    private static func prepareLocalDestinationFile(at localURL: URL) throws -> FileHandle {
        if FileManager.default.fileExists(atPath: localURL.path) {
            try? FileManager.default.removeItem(at: localURL)
        }
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        return try FileHandle(forWritingTo: localURL)
    }

    private static func downloadSmallFile(
        client: SFTPClient,
        handle: ByteBuffer,
        fileHandle: FileHandle,
        fileSize: UInt32,
        progress: TransferProgressHandler?
    ) async throws {
        if let buffer = try await client.read(handle: handle, offset: 0, length: fileSize),
           let chunkData = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
            try fileHandle.write(contentsOf: chunkData)
            progress?(Int64(chunkData.count))
        }
    }

    private static func downloadWithSlidingWindow(
        client: SFTPClient,
        handle: ByteBuffer,
        fileHandle: FileHandle,
        fileSize: UInt64,
        chunkSize: UInt32,
        windowSize: Int,
        progress: TransferProgressHandler?
    ) async throws {
        var nextReadOffset: UInt64 = 0
        var totalBytesDownloaded: Int64 = 0

        try await withThrowingTaskGroup(of: (offset: UInt64, data: Data?).self) { group in
            func scheduleNextChunk() {
                guard nextReadOffset < fileSize else { return }
                let offset = nextReadOffset
                let length = UInt32(min(UInt64(chunkSize), fileSize - offset))
                nextReadOffset += UInt64(length)

                group.addTask {
                    try Task.checkCancellation()
                    if let buffer = try await client.read(handle: handle, offset: offset, length: length) {
                        return (offset: offset, data: Data(buffer: buffer))
                    }
                    return (offset: offset, data: nil)
                }
            }

            for _ in 0..<windowSize {
                if nextReadOffset >= fileSize { break }
                scheduleNextChunk()
            }

            for try await result in group {
                try Task.checkCancellation()

                if let data = result.data, !data.isEmpty {
                    try fileHandle.seek(toOffset: result.offset)
                    try fileHandle.write(contentsOf: data)
                    totalBytesDownloaded += Int64(data.count)
                    progress?(totalBytesDownloaded)
                }

                scheduleNextChunk()
            }
        }
    }

    // MARK: - Upload

    static func upload(
        client: SFTPClient,
        localURL: URL,
        remotePath: String,
        chunkSize: UInt32 = defaultChunkSize,
        windowSize: Int = defaultWindowSize,
        progress: TransferProgressHandler?
    ) async throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir) else {
            throw AppError.fileNotFound
        }

        if isDir.boolValue {
            try await uploadDirectory(
                client: client,
                localDirURL: localURL,
                remoteDirPath: remotePath,
                chunkSize: chunkSize,
                windowSize: windowSize,
                progress: progress
            )
        } else {
            let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            let fileSize = attributes[.size] as? UInt64 ?? 0
            try await uploadSingleFile(
                client: client,
                localURL: localURL,
                remotePath: remotePath,
                fileSize: fileSize,
                chunkSize: chunkSize,
                windowSize: windowSize,
                progress: progress
            )
        }
    }

    private static func uploadDirectory(
        client: SFTPClient,
        localDirURL: URL,
        remoteDirPath: String,
        chunkSize: UInt32,
        windowSize: Int,
        progress: TransferProgressHandler?,
        tracker: CumulativeTransferTracker? = nil
    ) async throws {
        let activeTracker = tracker ?? CumulativeTransferTracker(progress: progress)

        // Create remote directory if not exists
        try? await client.createDirectory(at: remoteDirPath)

        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(
            at: localDirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        )

        for item in items {
            try Task.checkCancellation()

            let itemRemotePath = remoteDirPath.hasSuffix("/")
                ? "\(remoteDirPath)\(item.lastPathComponent)"
                : "\(remoteDirPath)/\(item.lastPathComponent)"

            var isItemDir: ObjCBool = false
            if fileManager.fileExists(atPath: item.path, isDirectory: &isItemDir), isItemDir.boolValue {
                try await uploadDirectory(
                    client: client,
                    localDirURL: item,
                    remoteDirPath: itemRemotePath,
                    chunkSize: chunkSize,
                    windowSize: windowSize,
                    progress: progress,
                    tracker: activeTracker
                )
            } else {
                let attrs = try fileManager.attributesOfItem(atPath: item.path)
                let itemSize = attrs[.size] as? UInt64 ?? 0
                activeTracker.startFile()
                try await uploadSingleFile(
                    client: client,
                    localURL: item,
                    remotePath: itemRemotePath,
                    fileSize: itemSize,
                    chunkSize: chunkSize,
                    windowSize: windowSize,
                    progress: { fileBytes in
                        activeTracker.updateCurrentFile(bytes: fileBytes)
                    }
                )
                activeTracker.finishFile(size: Int64(itemSize))
            }
        }
    }

    private static func uploadSingleFile(
        client: SFTPClient,
        localURL: URL,
        remotePath: String,
        fileSize: UInt64,
        chunkSize: UInt32,
        windowSize: Int,
        progress: TransferProgressHandler?
    ) async throws {
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }

        progress?(0)

        let handle = try await client.openFile(
            path: remotePath,
            flags: [.write, .creat, .trunc],
            attributes: .init()
        )
        var needsRemoteClose = true
        defer {
            if needsRemoteClose {
                Task { try? await client.closeHandle(handle) }
            }
        }

        if fileSize == 0 {
            progress?(0)
        } else if fileSize <= UInt64(chunkSize) {
            try await uploadSmallFile(
                client: client,
                handle: handle,
                fileHandle: fileHandle,
                progress: progress
            )
        } else {
            try await uploadWithSlidingWindow(
                client: client,
                handle: handle,
                fileHandle: fileHandle,
                fileSize: fileSize,
                chunkSize: chunkSize,
                windowSize: max(1, windowSize),
                progress: progress
            )
        }

        needsRemoteClose = false
        try await client.closeHandle(handle)
    }

    private static func uploadSmallFile(
        client: SFTPClient,
        handle: ByteBuffer,
        fileHandle: FileHandle,
        progress: TransferProgressHandler?
    ) async throws {
        let data = try fileHandle.readToEnd() ?? Data()
        guard !data.isEmpty else { return }

        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await client.write(handle: handle, offset: 0, data: buffer)
        progress?(Int64(data.count))
    }

    private static func uploadWithSlidingWindow(
        client: SFTPClient,
        handle: ByteBuffer,
        fileHandle: FileHandle,
        fileSize: UInt64,
        chunkSize: UInt32,
        windowSize: Int,
        progress: TransferProgressHandler?
    ) async throws {
        var nextWriteOffset: UInt64 = 0
        var totalBytesUploaded: Int64 = 0

        try await withThrowingTaskGroup(of: (offset: UInt64, count: Int).self) { group in
            func scheduleNextChunk() throws -> Bool {
                guard nextWriteOffset < fileSize else { return false }
                let offset = nextWriteOffset
                try fileHandle.seek(toOffset: offset)
                let bytesToRead = Int(min(UInt64(chunkSize), fileSize - offset))

                guard let chunkData = try fileHandle.read(upToCount: bytesToRead), !chunkData.isEmpty else {
                    return false
                }
                nextWriteOffset += UInt64(chunkData.count)

                group.addTask {
                    try Task.checkCancellation()
                    var buffer = ByteBufferAllocator().buffer(capacity: chunkData.count)
                    buffer.writeBytes(chunkData)
                    try await client.write(handle: handle, offset: offset, data: buffer)
                    return (offset: offset, count: chunkData.count)
                }
                return true
            }

            for _ in 0..<windowSize {
                if try !scheduleNextChunk() { break }
            }

            for try await result in group {
                try Task.checkCancellation()
                totalBytesUploaded += Int64(result.count)
                progress?(totalBytesUploaded)
                _ = try scheduleNextChunk()
            }
        }
    }
}
