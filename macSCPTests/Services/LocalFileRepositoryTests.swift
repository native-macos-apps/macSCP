//
//  LocalFileRepositoryTests.swift
//  macSCPTests
//
//  Unit tests for LocalFileRepository CRUD, UTF-8 validation, progress reporting,
//  and LocalFileStreamReader / writeStream streaming.
//

import XCTest
@testable import macSCP

@MainActor
final class LocalFileRepositoryTests: XCTestCase {
    private var tempDir: URL!
    private var repo: LocalFileRepository!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repo = LocalFileRepository()
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        repo = nil
        tempDir = nil
        try await super.tearDown()
    }

    func testCRUDListAndFileInfo() async throws {
        let subDir = tempDir.appendingPathComponent("nested/dir").path
        try await repo.createDirectory(at: subDir)

        let filePath = tempDir.appendingPathComponent("nested/dir/hello.txt").path
        try await repo.createFile(at: filePath)
        try await repo.writeFileContent("Hello Local!", to: filePath)

        let content = try await repo.readFileContent(at: filePath)
        XCTAssertEqual(content, "Hello Local!")

        let info = try await repo.getFileInfo(at: filePath)
        XCTAssertEqual(info.name, "hello.txt")
        XCTAssertFalse(info.isDirectory)
        XCTAssertEqual(info.size, Int64("Hello Local!".utf8.count))
        XCTAssertTrue(info.permissions.hasPrefix("-"))
        XCTAssertEqual(info.permissions.count, 10)

        let listed = try await repo.listFiles(at: subDir)
        XCTAssertEqual(listed.map(\.name), ["hello.txt"])

        // Copy & Rename & Move
        let copiedPath = tempDir.appendingPathComponent("nested/dir/hello_copy.txt").path
        try await repo.copy(from: filePath, to: copiedPath, isDirectory: false)
        let renamedPath = tempDir.appendingPathComponent("nested/dir/renamed.txt").path
        try await repo.rename(from: copiedPath, to: renamedPath)
        let movedPath = tempDir.appendingPathComponent("moved.txt").path
        try await repo.move(from: renamedPath, to: movedPath)

        let movedContent = try await repo.readFileContent(at: movedPath)
        XCTAssertEqual(movedContent, "Hello Local!")

        // Delete
        try await repo.delete(at: movedPath, isDirectory: false)
        do {
            try await repo.delete(at: movedPath, isDirectory: false)
            XCTFail("Expected fileNotFound when deleting missing file")
        } catch let error as AppError {
            XCTAssertEqual(error, .fileNotFound)
        }
    }

    func testReadFileContent_RejectsInvalidUTF8() async throws {
        let binaryURL = tempDir.appendingPathComponent("binary.dat")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: binaryURL)

        do {
            _ = try await repo.readFileContent(at: binaryURL.path)
            XCTFail("Expected invalidFileEncoding")
        } catch let error as AppError {
            XCTAssertEqual(error, .invalidFileEncoding)
        }
    }

    func testUploadDownloadAndStreamingRoundTrip() async throws {
        let payload = Data(repeating: 0x42, count: 150_000)
        let srcURL = tempDir.appendingPathComponent("source.bin")
        try payload.write(to: srcURL)

        let uploadedPath = tempDir.appendingPathComponent("uploaded.bin").path
        var uploadProgressBytes: Int64 = 0
        try await repo.upload(localURL: srcURL, to: uploadedPath) { bytes in
            uploadProgressBytes = bytes
        }
        XCTAssertEqual(uploadProgressBytes, Int64(payload.count))

        let downloadedURL = tempDir.appendingPathComponent("downloaded.bin")
        var downloadProgressBytes: Int64 = 0
        try await repo.download(remotePath: uploadedPath, to: downloadedURL) { bytes in
            downloadProgressBytes = bytes
        }
        XCTAssertEqual(downloadProgressBytes, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: downloadedURL), payload)

        // Stream reader + writeStream
        let reader = try await repo.openStreamReader(at: uploadedPath)
        let streamedPath = tempDir.appendingPathComponent("sub/streamed.bin").path
        var progressEvents: [Int64] = []
        try await repo.writeStream(from: reader, to: streamedPath, totalSize: Int64(payload.count)) { bytes in
            progressEvents.append(bytes)
        }
        await reader.close()

        // Closing twice is idempotent and subsequent reads return nil
        await reader.close()
        let afterClose = try await reader.readNextChunk()
        XCTAssertNil(afterClose)

        XCTAssertEqual(progressEvents.first, 0)
        XCTAssertEqual(progressEvents.last, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: streamedPath)), payload)
    }

    func testListFiles_MissingDirectoryThrowsFileNotFound() async {
        let missing = tempDir.appendingPathComponent("does-not-exist").path
        do {
            _ = try await repo.listFiles(at: missing)
            XCTFail("Expected fileNotFound")
        } catch let error as AppError {
            XCTAssertEqual(error, .fileNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFailedStreamPreservesExistingFileAndLeavesNoNewFile() async throws {
        let existing = tempDir.appendingPathComponent("existing.txt")
        let fresh = tempDir.appendingPathComponent("fresh.txt")
        let original = Data("original".utf8)
        try original.write(to: existing)

        for destination in [existing, fresh] {
            do {
                try await repo.writeStream(from: FailingReader(), to: destination.path, totalSize: nil, progress: nil)
                XCTFail("Expected a stream error")
            } catch let error as AppError {
                XCTAssertEqual(error, .connectionLost)
            }
        }

        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testCancelledStreamPreservesDestination() async throws {
        let destination = tempDir.appendingPathComponent("destination.txt")
        let original = Data("original".utf8)
        try original.write(to: destination)
        let (started, continuation) = AsyncStream<Int64>.makeStream()
        let reader = FailingReader(waitBeforeError: true)
        let repository = repo!
        let write = Task {
            defer { continuation.finish() }
            try await repository.writeStream(from: reader, to: destination.path, totalSize: nil) { bytes in
                continuation.yield(bytes)
            }
        }

        for await progress in started where progress > 0 { break }
        write.cancel()
        do {
            try await write.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }

    func testLocalCopyPreservesDestinationOnFailureAndReplacesDirectoryOnSuccess() async throws {
        let destination = tempDir.appendingPathComponent("destination")
        let source = tempDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: destination.appendingPathComponent("old"))

        do {
            try await repo.download(remotePath: source.path, to: destination)
            XCTFail("Expected a missing source")
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["old"])
        }

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: source.appendingPathComponent("new"))
        try await repo.download(remotePath: source.path, to: destination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["new"])
    }

    @MainActor
    private final class FailingReader: FileStreamReader {
        private var yielded = false
        private let waitBeforeError: Bool

        init(waitBeforeError: Bool = false) {
            self.waitBeforeError = waitBeforeError
        }

        func readNextChunk() async throws -> Data? {
            if !yielded {
                yielded = true
                return Data("partial".utf8)
            }
            if waitBeforeError { try await Task.sleep(for: .seconds(5)) }
            throw AppError.connectionLost
        }

        func close() async {}
    }
}
