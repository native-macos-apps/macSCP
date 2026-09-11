//
//  RemoteStreamTransferEngineTests.swift
//  macSCPTests
//
//  Unit tests for RemoteStreamTransferEngine
//

import XCTest
@testable import macSCP

final class RemoteStreamTransferEngineTests: XCTestCase {
    var sourceRepo: MockFileRepository!
    var targetRepo: MockFileRepository!

    override func setUp() {
        super.setUp()
        sourceRepo = MockFileRepository()
        targetRepo = MockFileRepository()
    }

    override func tearDown() {
        sourceRepo = nil
        targetRepo = nil
        super.tearDown()
    }

    // MARK: - Single File Streaming Tests

    func testSingleFileStreamTransfer() async throws {
        let testContent = "Hello, world! This is a test for streaming file transfer between two connections."
        let testData = testContent.data(using: .utf8)!
        let sourcePath = "/remote/source/hello.txt"
        let targetDir = "/remote/target"

        sourceRepo.mockStreamData[sourcePath] = testData
        let sourceFile = RemoteFile(
            name: "hello.txt",
            path: sourcePath,
            isDirectory: false,
            size: Int64(testData.count),
            permissions: "-rw-r--r--"
        )

        var reportedBytes: [Int64] = []
        try await RemoteStreamTransferEngine.transfer(
            file: sourceFile,
            from: sourceRepo,
            to: targetRepo,
            targetDirectory: targetDir,
            progress: { bytes in
                reportedBytes.append(bytes)
            }
        )

        XCTAssertTrue(sourceRepo.openStreamReaderCalled)
        XCTAssertEqual(sourceRepo.lastStreamReadPath, sourcePath)

        XCTAssertTrue(targetRepo.writeStreamCalled)
        let expectedTargetPath = "/remote/target/hello.txt"
        XCTAssertEqual(targetRepo.lastStreamWritePath, expectedTargetPath)

        let writtenData = targetRepo.writtenStreamData[expectedTargetPath]
        XCTAssertNotNil(writtenData)
        XCTAssertEqual(writtenData, testData)
        XCTAssertEqual(String(data: writtenData ?? Data(), encoding: .utf8), testContent)
        XCTAssertFalse(reportedBytes.isEmpty)
        XCTAssertEqual(reportedBytes.last, Int64(testData.count))
    }

    // MARK: - Directory Recursive Streaming Tests

    func testDirectoryRecursiveStreamTransfer() async throws {
        let rootDirPath = "/source/folder"
        let targetDir = "/target"

        let file1Content = "File 1 content"
        let file2Content = "File 2 content inside subfolder"

        let file1Data = file1Content.data(using: .utf8)!
        let file2Data = file2Content.data(using: .utf8)!

        sourceRepo.mockStreamData["/source/folder/file1.txt"] = file1Data
        sourceRepo.mockStreamData["/source/folder/sub/file2.txt"] = file2Data

        let rootDir = RemoteFile(
            name: "folder",
            path: rootDirPath,
            isDirectory: true,
            size: 0,
            permissions: "drwxr-xr-x"
        )

        sourceRepo.mockDirectoryContents["/source/folder"] = [
            RemoteFile(name: "file1.txt", path: "/source/folder/file1.txt", isDirectory: false, size: Int64(file1Data.count), permissions: "-rw-r--r--"),
            RemoteFile(name: "sub", path: "/source/folder/sub", isDirectory: true, size: 0, permissions: "drwxr-xr-x")
        ]
        sourceRepo.mockDirectoryContents["/source/folder/sub"] = [
            RemoteFile(name: "file2.txt", path: "/source/folder/sub/file2.txt", isDirectory: false, size: Int64(file2Data.count), permissions: "-rw-r--r--")
        ]

        try await RemoteStreamTransferEngine.transfer(
            file: rootDir,
            from: sourceRepo,
            to: targetRepo,
            targetDirectory: targetDir
        )

        // Verify target created folder and streamed files
        XCTAssertTrue(targetRepo.createDirectoryCalled)
        let writtenFile1 = targetRepo.writtenStreamData["/target/folder/file1.txt"]
        XCTAssertEqual(writtenFile1, file1Data)

        let writtenFile2 = targetRepo.writtenStreamData["/target/folder/sub/file2.txt"]
        XCTAssertEqual(writtenFile2, file2Data)
    }

    // MARK: - MemoryStreamReader Tests

    func testMemoryStreamReaderChunking() async throws {
        let string = "ABCDEFGHIJ" // 10 bytes
        let data = string.data(using: .utf8)!
        let reader = MemoryStreamReader(data: data, chunkSize: 3)

        var chunks: [Data] = []
        while let chunk = try await reader.readNextChunk() {
            chunks.append(chunk)
        }

        // Expected chunks: 3, 3, 3, 1 = 4 chunks
        XCTAssertEqual(chunks.count, 4)
        let concatenated = chunks.reduce(Data(), +)
        XCTAssertEqual(concatenated, data)

        // Next read should be nil
        let eofChunk = try await reader.readNextChunk()
        XCTAssertNil(eofChunk)

        await reader.close()
    }
}
