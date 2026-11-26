//
//  TransferCoreTests.swift
//  macSCPTests
//
//  Unit tests for TransferRetryPolicy, RemoteDirectoryManager, and StreamingFileScanner
//

import XCTest
@testable import macSCP

final class TransferCoreTests: XCTestCase {

    // MARK: - TransferRetryPolicy Tests

    func testRetryPolicy_RespectsMaxRetries() {
        let policy = TransferRetryPolicy(maxRetries: 3, initialDelay: 0.5, maxDelay: 4.0, backoffMultiplier: 2.0, jitterFactor: 0.25)
        XCTAssertTrue(policy.shouldRetry(error: AppError.connectionTimeout, attempt: 1))
        XCTAssertTrue(policy.shouldRetry(error: AppError.connectionTimeout, attempt: 2))
        XCTAssertFalse(policy.shouldRetry(error: AppError.connectionTimeout, attempt: 3))
        XCTAssertFalse(TransferRetryPolicy.none.shouldRetry(error: AppError.connectionTimeout, attempt: 0))
    }

    func testRetryPolicy_NeverRetriesCancellationOrPermanentErrors() {
        let policy = TransferRetryPolicy.default
        XCTAssertFalse(policy.shouldRetry(error: CancellationError(), attempt: 1))
        XCTAssertFalse(policy.shouldRetry(error: AppError.permissionDenied, attempt: 1))
        XCTAssertFalse(policy.shouldRetry(error: AppError.s3AccessDenied, attempt: 1))
        XCTAssertFalse(policy.shouldRetry(error: AppError.invalidS3Credentials, attempt: 1))
        XCTAssertFalse(policy.shouldRetry(error: AppError.fileNotFound, attempt: 1))
        XCTAssertFalse(policy.shouldRetry(error: AppError.s3OperationFailed("AccessDenied"), attempt: 1))
        XCTAssertFalse(policy.shouldRetry(error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), attempt: 1))
        XCTAssertFalse(policy.shouldRetry(error: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)), attempt: 1))
    }

    func testRetryPolicy_RetriesTransientNetworkAndThrottlingErrors() {
        let policy = TransferRetryPolicy.default
        XCTAssertTrue(policy.shouldRetry(error: AppError.connectionTimeout, attempt: 1))
        XCTAssertTrue(policy.shouldRetry(error: AppError.connectionFailed("reset"), attempt: 1))
        XCTAssertTrue(policy.shouldRetry(error: AppError.s3OperationFailed("503 SlowDown"), attempt: 1))
        XCTAssertTrue(policy.shouldRetry(error: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET)), attempt: 1))
        XCTAssertTrue(policy.shouldRetry(error: NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)), attempt: 1))
    }

    func testRetryPolicy_ExponentialBackoffDelayWithinBounds() {
        let policy = TransferRetryPolicy(maxRetries: 4, initialDelay: 0.4, maxDelay: 2.0, backoffMultiplier: 2.0, jitterFactor: 0.25)
        XCTAssertEqual(policy.delay(forAttempt: 0), 0)

        for _ in 0..<20 {
            let d1 = policy.delay(forAttempt: 1) // base 0.4 ± 0.1 -> [0.3, 0.5]
            XCTAssertGreaterThanOrEqual(d1, 0.3 - 0.001)
            XCTAssertLessThanOrEqual(d1, 0.5 + 0.001)

            let d4 = policy.delay(forAttempt: 4) // capped at 2.0 ± 0.5 -> [1.5, 2.5]
            XCTAssertGreaterThanOrEqual(d4, 1.5 - 0.001)
            XCTAssertLessThanOrEqual(d4, 2.5 + 0.001)
        }
    }

    // MARK: - RemoteDirectoryManager Tests

    private final class RecordingDirectoryRepository: FileRepositoryProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var createdOrder: [String] = []
        var failPaths: Set<String> = []
        var alreadyExistsPaths: Set<String> = []

        func listFiles(at path: String) async throws -> [RemoteFile] { [] }
        func getFileInfo(at path: String) async throws -> RemoteFile { throw AppError.fileNotFound }
        func createDirectory(at path: String) async throws {
            lock.lock()
            createdOrder.append(path)
            let shouldFail = failPaths.contains(path)
            let alreadyExists = alreadyExistsPaths.contains(path)
            lock.unlock()

            if shouldFail {
                throw AppError.permissionDenied
            }
            if alreadyExists {
                throw NSError(domain: "test", code: 17, userInfo: [NSLocalizedDescriptionKey: "File exists"])
            }
        }
        func createFile(at path: String) async throws {}
        func delete(at path: String, isDirectory: Bool) async throws {}
        func rename(from sourcePath: String, to destinationPath: String) async throws {}
        func copy(from sourcePath: String, to destinationPath: String, isDirectory: Bool) async throws {}
        func move(from sourcePath: String, to destinationPath: String) async throws {}
        func download(remotePath: String, to localURL: URL) async throws {}
        func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {}
        func upload(localURL: URL, to remotePath: String) async throws {}
        func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {}
        func readFileContent(at path: String) async throws -> String { "" }
        func writeFileContent(_ content: String, to path: String) async throws {}
        func getRealPath(at path: String) async throws -> String { path }
        func openStreamReader(at path: String) async throws -> FileStreamReader { fatalError() }
        func writeStream(from reader: FileStreamReader, to path: String, totalSize: Int64?, progress: TransferProgressHandler?) async throws {}
    }

    func testRemoteDirectoryManager_DepthOrderingDeduplicationAndAlreadyExists() async {
        let repo = RecordingDirectoryRepository()
        repo.alreadyExistsPaths = ["/root/a"]
        let manager = RemoteDirectoryManager(repository: repo, maxConcurrency: 2)

        let errors = await manager.createDirectories([
            "/root/a/b/c",
            "/root/a/",
            "/root//a//b",
            "/root/a/b"
        ])

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(repo.createdOrder, ["/root/a", "/root/a/b", "/root/a/b/c"])
    }

    func testRemoteDirectoryManager_ParentFailureBlocksChildren() async {
        let repo = RecordingDirectoryRepository()
        repo.failPaths = ["/root/blocked"]
        let manager = RemoteDirectoryManager(repository: repo, maxConcurrency: 2)

        let errors = await manager.createDirectories([
            "/root/blocked",
            "/root/blocked/sub",
            "/root/ok"
        ])

        XCTAssertNotNil(errors["/root/blocked"])
        XCTAssertNotNil(errors["/root/blocked/sub"])
        XCTAssertNil(errors["/root/ok"])

        // Child should NOT have been attempted on the repository
        XCTAssertFalse(repo.createdOrder.contains("/root/blocked/sub"))

        let ancestorError = await manager.failureForAncestor(of: "/root/blocked/sub/file.txt")
        XCTAssertNotNil(ancestorError)
        let okAncestorError = await manager.failureForAncestor(of: "/root/ok/file.txt")
        XCTAssertNil(okAncestorError)
    }

    // MARK: - StreamingFileScanner Tests

    func testStreamingFileScanner_LocalURLsTreeAndHiddenSkip() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("scanner_\(UUID().uuidString)")
        let nestedDir = tempRoot.appendingPathComponent("folder/sub")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let topFile = tempRoot.appendingPathComponent("root.txt")
        let nestedFile = nestedDir.appendingPathComponent("leaf.txt")
        let hiddenFile = nestedDir.appendingPathComponent(".hidden")
        try Data("hello".utf8).write(to: topFile)
        try Data("world!".utf8).write(to: nestedFile)
        try Data("secret".utf8).write(to: hiddenFile)

        var topFolders: [RemoteFile] = []
        var directories: [String] = []
        var files: [TransferQueueItem] = []
        var finishedTotals: (Int, Int64)?

        let stream = StreamingFileScanner.streamLocalURLs(
            [topFile, tempRoot.appendingPathComponent("folder")],
            targetRemotePath: "/remote"
        )
        for await event in stream {
            switch event {
            case .topLevelFolder(let folder): topFolders.append(folder)
            case .directory(let path): directories.append(path)
            case .file(let item): files.append(item)
            case .finished(let count, let bytes): finishedTotals = (count, bytes)
            }
        }

        XCTAssertEqual(topFolders.map(\.name), ["folder"])
        XCTAssertTrue(directories.contains("/remote/folder"))
        XCTAssertTrue(directories.contains("/remote/folder/sub"))
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(Set(files.map(\.remotePath)), Set(["/remote/root.txt", "/remote/folder/sub/leaf.txt"]))
        XCTAssertEqual(finishedTotals?.0, 2)
        XCTAssertEqual(finishedTotals?.1, 11)
    }

    func testStreamingFileScanner_RemoteFilesTree() async {
        final class TreeMockRepo: FileRepositoryProtocol, @unchecked Sendable {
            func listFiles(at path: String) async throws -> [RemoteFile] {
                if path == "/src/dir" || path == "/src/dir/" {
                    return [
                        RemoteFile(name: "nested.txt", path: "/src/dir/nested.txt", isDirectory: false, size: 42, permissions: "-rw-r--r--")
                    ]
                }
                return []
            }
            func getFileInfo(at path: String) async throws -> RemoteFile { throw AppError.fileNotFound }
            func createDirectory(at path: String) async throws {}
            func createFile(at path: String) async throws {}
            func delete(at path: String, isDirectory: Bool) async throws {}
            func rename(from sourcePath: String, to destinationPath: String) async throws {}
            func copy(from sourcePath: String, to destinationPath: String, isDirectory: Bool) async throws {}
            func move(from sourcePath: String, to destinationPath: String) async throws {}
            func download(remotePath: String, to localURL: URL) async throws {}
            func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {}
            func upload(localURL: URL, to remotePath: String) async throws {}
            func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {}
            func readFileContent(at path: String) async throws -> String { "" }
            func writeFileContent(_ content: String, to path: String) async throws {}
            func getRealPath(at path: String) async throws -> String { path }
            func openStreamReader(at path: String) async throws -> FileStreamReader { fatalError() }
            func writeStream(from reader: FileStreamReader, to path: String, totalSize: Int64?, progress: TransferProgressHandler?) async throws {}
        }

        let dirFile = RemoteFile(name: "dir", path: "/src/dir", isDirectory: true, size: 0, permissions: "drwxr-xr-x")
        let singleFile = RemoteFile(name: "top.txt", path: "/src/top.txt", isDirectory: false, size: 10, permissions: "-rw-r--r--")

        var files: [TransferQueueItem] = []
        var dirs: [String] = []
        let stream = StreamingFileScanner.streamRemoteFiles(
            [dirFile, singleFile],
            targetBasePath: "/dst",
            sourceRepo: TreeMockRepo()
        )
        for await event in stream {
            switch event {
            case .directory(let path): dirs.append(path)
            case .file(let item): files.append(item)
            default: break
            }
        }

        XCTAssertEqual(dirs, ["/dst/dir"])
        XCTAssertEqual(Set(files.map(\.remotePath)), Set(["/dst/dir/nested.txt", "/dst/top.txt"]))
        XCTAssertEqual(files.reduce(0) { $0 + $1.fileSize }, 52)
    }
}
