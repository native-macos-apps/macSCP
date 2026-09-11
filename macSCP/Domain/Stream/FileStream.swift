//
//  FileStream.swift
//  macSCP
//
//  Streaming abstractions for chunk-by-chunk file transfers without local disk buffering
//

import Foundation

/// Protocol for reading file chunks sequentially with backpressure
protocol FileStreamReader: Sendable {
    /// Reads the next available chunk of data.
    /// Returns `nil` when end-of-file (EOF) is reached.
    func readNextChunk() async throws -> Data?

    /// Closes any open handles or resources associated with the stream reader.
    func close() async
}

/// In-memory stream reader implementation, useful for tests and small buffers
final class MemoryStreamReader: FileStreamReader, @unchecked Sendable {
    private let data: Data
    private let chunkSize: Int
    private var offset: Int = 0
    private var isClosed = false

    init(data: Data, chunkSize: Int = 64 * 1024) {
        self.data = data
        self.chunkSize = chunkSize
    }

    public func readNextChunk() async throws -> Data? {
        guard !isClosed, offset < data.count else { return nil }
        let nextOffset = min(offset + chunkSize, data.count)
        let chunk = data.subdata(in: offset..<nextOffset)
        offset = nextOffset
        return chunk
    }

    public func close() async {
        isClosed = true
    }
}
