//
//  SFTPTransferEngine.swift
//  macSCP
//
//  High-Performance Pipelined SFTP Transfer Engine using a Concurrent Sliding Window
//

import Foundation
import NIOCore
import NIOFoundationCompat

final class SFTPTransferEngine: Sendable {
    nonisolated static let defaultChunkSize: UInt32 = 64 * 1024 // 64 KB per chunk
    nonisolated static let defaultWindowSize: Int = 16          // 16 in-flight chunks = 1 MB window

    // MARK: - Pipelined Download

    static func download(
        client: SFTPClient,
        remotePath: String,
        localURL: URL,
        chunkSize: UInt32 = defaultChunkSize,
        windowSize: Int = defaultWindowSize,
        progress: TransferProgressHandler?
    ) async throws {
        // 1. Get file size
        let attrs = try await client.stat(at: remotePath)
        let fileSize = attrs.size ?? 0

        // Report initial progress
        progress?(0)

        // 2. Open remote file for reading
        let handle = try await client.openFile(path: remotePath, flags: [.read])

        // Ensure remote handle is closed when done
        var closedRemote = false
        defer {
            if !closedRemote {
                Task {
                    try? await client.closeHandle(handle)
                }
            }
        }

        // 3. Prepare local destination file
        if FileManager.default.fileExists(atPath: localURL.path) {
            try? FileManager.default.removeItem(at: localURL)
        }
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: localURL)
        defer { try? fileHandle.close() }

        // If file is empty, we are done
        guard fileSize > 0 else {
            progress?(0)
            try await client.closeHandle(handle)
            closedRemote = true
            return
        }

        // 4. Sliding window pipelined download
        var nextReadOffset: UInt64 = 0
        var totalBytesDownloaded: Int64 = 0

        // Use TaskGroup with limited concurrency
        try await withThrowingTaskGroup(of: (offset: UInt64, data: Data?).self) { group in
            // Pre-fill window
            while nextReadOffset < fileSize && group.isEmpty || (nextReadOffset / UInt64(chunkSize) < UInt64(windowSize)) {
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

                if nextReadOffset >= fileSize { break }
            }

            // As each chunk completes, write to disk and dispatch the next chunk
            for try await result in group {
                try Task.checkCancellation()

                if let data = result.data, !data.isEmpty {
                    try fileHandle.seek(toOffset: result.offset)
                    try fileHandle.write(contentsOf: data)
                    totalBytesDownloaded += Int64(data.count)
                    progress?(totalBytesDownloaded)
                }

                // If more bytes remain, dispatch next chunk into the window
                if nextReadOffset < fileSize {
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
            }
        }

        // Close remote handle
        try await client.closeHandle(handle)
        closedRemote = true
    }

    // MARK: - Pipelined Upload

    static func upload(
        client: SFTPClient,
        localURL: URL,
        remotePath: String,
        chunkSize: UInt32 = defaultChunkSize,
        windowSize: Int = defaultWindowSize,
        progress: TransferProgressHandler?
    ) async throws {
        // 1. Get local file size and prepare reading
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = attributes[.size] as? UInt64 ?? 0

        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }

        // Report initial progress
        progress?(0)

        // 2. Open remote file for writing (create or truncate)
        let handle = try await client.openFile(
            path: remotePath,
            flags: [.write, .creat, .trunc],
            attributes: .init(size: fileSize)
        )

        var closedRemote = false
        defer {
            if !closedRemote {
                Task {
                    try? await client.closeHandle(handle)
                }
            }
        }

        // If file is empty, close and return
        guard fileSize > 0 else {
            progress?(0)
            try await client.closeHandle(handle)
            closedRemote = true
            return
        }

        // 3. Sliding window pipelined upload
        var nextWriteOffset: UInt64 = 0
        var totalBytesUploaded: Int64 = 0

        try await withThrowingTaskGroup(of: (offset: UInt64, count: Int).self) { group in
            // Pre-fill write window
            while nextWriteOffset < fileSize && (nextWriteOffset / UInt64(chunkSize) < UInt64(windowSize)) {
                let offset = nextWriteOffset
                try fileHandle.seek(toOffset: offset)
                let bytesToRead = Int(min(UInt64(chunkSize), fileSize - offset))

                guard let chunkData = try fileHandle.read(upToCount: bytesToRead), !chunkData.isEmpty else {
                    break
                }
                nextWriteOffset += UInt64(chunkData.count)

                group.addTask {
                    try Task.checkCancellation()
                    var buffer = ByteBufferAllocator().buffer(capacity: chunkData.count)
                    buffer.writeBytes(chunkData)
                    try await client.write(handle: handle, offset: offset, data: buffer)
                    return (offset: offset, count: chunkData.count)
                }

                if nextWriteOffset >= fileSize { break }
            }

            // As each write completes, send the next chunk
            for try await result in group {
                try Task.checkCancellation()
                totalBytesUploaded += Int64(result.count)
                progress?(totalBytesUploaded)

                if nextWriteOffset < fileSize {
                    let offset = nextWriteOffset
                    try fileHandle.seek(toOffset: offset)
                    let bytesToRead = Int(min(UInt64(chunkSize), fileSize - offset))

                    if let chunkData = try fileHandle.read(upToCount: bytesToRead), !chunkData.isEmpty {
                        nextWriteOffset += UInt64(chunkData.count)

                        group.addTask {
                            try Task.checkCancellation()
                            var buffer = ByteBufferAllocator().buffer(capacity: chunkData.count)
                            buffer.writeBytes(chunkData)
                            try await client.write(handle: handle, offset: offset, data: buffer)
                            return (offset: offset, count: chunkData.count)
                        }
                    }
                }
            }
        }

        // Close remote handle
        try await client.closeHandle(handle)
        closedRemote = true
    }
}
