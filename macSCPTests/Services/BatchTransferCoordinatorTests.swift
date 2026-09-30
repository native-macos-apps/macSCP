//
//  BatchTransferCoordinatorTests.swift
//  macSCPTests
//
//  Unit tests for BatchTransferCoordinator covering bounded concurrency,
//  directory failure propagation, retry/backoff policy, cancellation mid-batch,
//  1,000 small files benchmark, and Retry Failed semantics.
//

import XCTest
@testable import macSCP

final class BatchTransferCoordinatorTests: XCTestCase {

    func testConcurrencyLimit() async {
        let coordinator = BatchTransferCoordinator()
        let maxConcurrent = 3
        let totalItems = 12

        let lock = NSLock()
        var currentActive = 0
        var maxActiveObserved = 0

        let items = (0..<totalItems).map { i in
            TransferQueueItem(
                remotePath: "/remote/file_\(i).txt",
                displayName: "file_\(i).txt",
                fileSize: 100
            )
        }

        let tracker = BatchProgressTracker(batchId: UUID(), totalFiles: totalItems, totalBytes: Int64(totalItems * 100))
        let mockRepo = MockFileRepository()

        let result = await coordinator.executeBatch(
            items: items,
            directoriesToCreate: [],
            repository: mockRepo,
            maxConcurrent: maxConcurrent,
            retryPolicy: .none,
            tracker: tracker,
            executor: { _, progress in
                lock.lock()
                currentActive += 1
                if currentActive > maxActiveObserved {
                    maxActiveObserved = currentActive
                }
                lock.unlock()

                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                progress(100)

                lock.lock()
                currentActive -= 1
                lock.unlock()
                return nil
            },
            onUpdate: { _ in }
        )

        XCTAssertEqual(result.completedFiles, totalItems)
        XCTAssertLessThanOrEqual(
            maxActiveObserved,
            maxConcurrent,
            "Active concurrent tasks must never exceed configured maxConcurrent (\(maxConcurrent))"
        )
    }

    func testDirectoryCreationFailure_PreventsDependentUpload() async {
        let coordinator = BatchTransferCoordinator()
        let tracker = BatchProgressTracker(batchId: UUID(), totalFiles: 2, totalBytes: 200)

        final class MockDirRepo: FileRepositoryProtocol, @unchecked Sendable {
            func listFiles(at path: String) async throws -> [RemoteFile] { [] }
            func getFileInfo(at path: String) async throws -> RemoteFile { throw AppError.fileNotFound }
            func createDirectory(at path: String) async throws {
                if path.contains("bad_dir") {
                    throw AppError.permissionDenied
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
        let mockRepo = MockDirRepo()

        var uploadedFiles: [String] = []
        let lock = NSLock()

        let item1 = TransferQueueItem(
            remotePath: "/remote/bad_dir/file1.txt",
            displayName: "file1.txt",
            fileSize: 100
        )
        let item2 = TransferQueueItem(
            remotePath: "/remote/good_dir/file2.txt",
            displayName: "file2.txt",
            fileSize: 100
        )

        let result = await coordinator.executeBatch(
            items: [item1, item2],
            directoriesToCreate: ["/remote/bad_dir", "/remote/good_dir"],
            repository: mockRepo,
            maxConcurrent: 2,
            retryPolicy: .none,
            tracker: tracker,
            executor: { item, progress in
                lock.lock()
                uploadedFiles.append(item.remotePath)
                lock.unlock()
                progress(100)
                return nil
            },
            onUpdate: { _ in }
        )

        XCTAssertEqual(result.completedFiles, 1, "Only the file in the successfully created directory should succeed")
        XCTAssertEqual(result.failedFiles, 1, "File under failed directory must fail fast")
        XCTAssertFalse(
            uploadedFiles.contains("/remote/bad_dir/file1.txt"),
            "Dependent file under failed directory must never be executed by executor"
        )
        XCTAssertTrue(uploadedFiles.contains("/remote/good_dir/file2.txt"))
    }

    func testRetryPolicy_TransientErrorRetriedAndSucceeds() async {
        let coordinator = BatchTransferCoordinator()
        let tracker = BatchProgressTracker(batchId: UUID(), totalFiles: 1, totalBytes: 100)
        let mockRepo = MockFileRepository()

        var attempts = 0
        let lock = NSLock()

        let retryPolicy = TransferRetryPolicy(
            maxRetries: 3,
            initialDelay: 0.01,
            maxDelay: 0.05,
            backoffMultiplier: 2.0,
            jitterFactor: 0.0
        )

        let item = TransferQueueItem(
            remotePath: "/remote/transient.txt",
            displayName: "transient.txt",
            fileSize: 100
        )

        let result = await coordinator.executeBatch(
            items: [item],
            directoriesToCreate: [],
            repository: mockRepo,
            maxConcurrent: 1,
            retryPolicy: retryPolicy,
            tracker: tracker,
            executor: { _, progress in
                lock.lock()
                attempts += 1
                let currentAttempt = attempts
                lock.unlock()

                if currentAttempt < 3 {
                    throw AppError.connectionTimeout
                }
                progress(100)
                return nil
            },
            onUpdate: { _ in }
        )

        XCTAssertEqual(attempts, 3, "Transient error should be retried until 3rd attempt succeeds")
        XCTAssertEqual(result.completedFiles, 1)
        XCTAssertEqual(result.failedFiles, 0)
    }

    func testRetryPolicy_PermanentErrorFailsImmediately() async {
        let coordinator = BatchTransferCoordinator()
        let tracker = BatchProgressTracker(batchId: UUID(), totalFiles: 1, totalBytes: 100)
        let mockRepo = MockFileRepository()

        var attempts = 0
        let lock = NSLock()

        let retryPolicy = TransferRetryPolicy(
            maxRetries: 3,
            initialDelay: 0.01,
            maxDelay: 0.05,
            backoffMultiplier: 2.0,
            jitterFactor: 0.0
        )

        let item = TransferQueueItem(
            remotePath: "/remote/permanent.txt",
            displayName: "permanent.txt",
            fileSize: 100
        )

        let result = await coordinator.executeBatch(
            items: [item],
            directoriesToCreate: [],
            repository: mockRepo,
            maxConcurrent: 1,
            retryPolicy: retryPolicy,
            tracker: tracker,
            executor: { _, _ in
                lock.lock()
                attempts += 1
                lock.unlock()
                throw AppError.permissionDenied
            },
            onUpdate: { _ in }
        )

        XCTAssertEqual(attempts, 1, "Permanent error (permissionDenied) must NOT be retried")
        XCTAssertEqual(result.completedFiles, 0)
        XCTAssertEqual(result.failedFiles, 1)
    }

    func testCancellationDuringBatch() async {
        let coordinator = BatchTransferCoordinator()
        let totalItems = 20
        let tracker = BatchProgressTracker(batchId: UUID(), totalFiles: totalItems, totalBytes: Int64(totalItems * 100))
        let mockRepo = MockFileRepository()

        let items = (0..<totalItems).map { i in
            TransferQueueItem(
                remotePath: "/remote/cancel_\(i).txt",
                displayName: "cancel_\(i).txt",
                fileSize: 100
            )
        }

        let result = await coordinator.executeBatch(
            items: items,
            directoriesToCreate: [],
            repository: mockRepo,
            maxConcurrent: 2,
            retryPolicy: .none,
            tracker: tracker,
            executor: { _, progress in
                try await Task.sleep(nanoseconds: 10_000_000)
                if tracker.completedFiles >= 2 {
                    tracker.cancelAll()
                }
                progress(100)
                return nil
            },
            onUpdate: { _ in }
        )

        XCTAssertTrue(result.isCancelled)
        XCTAssertLessThan(result.completedFiles, totalItems, "Cancelled batch must not process all items")
        XCTAssertGreaterThan(result.cancelledFiles, 0)
    }

    func test1000SmallFilesScaleAndCorrectness() async {
        let coordinator = BatchTransferCoordinator()
        let count = 1000
        let fileBytes: Int64 = 10
        let totalBytes = Int64(count) * fileBytes

        let tracker = BatchProgressTracker(
            batchId: UUID(),
            totalFiles: count,
            totalBytes: totalBytes
        )
        let mockRepo = MockFileRepository()

        let items = (0..<count).map { i in
            TransferQueueItem(
                remotePath: "/remote/dir/file_\(i).txt",
                displayName: "file_\(i).txt",
                fileSize: fileBytes
            )
        }

        let result = await coordinator.executeBatch(
            items: items,
            directoriesToCreate: ["/remote/dir"],
            repository: mockRepo,
            maxConcurrent: 4,
            retryPolicy: .none,
            tracker: tracker,
            executor: { _, progress in
                progress(fileBytes)
                return nil
            },
            onUpdate: { _ in }
        )

        XCTAssertEqual(result.completedFiles, count)
        XCTAssertEqual(result.failedFiles, 0)
        XCTAssertEqual(result.cancelledFiles, 0)
        XCTAssertEqual(result.completedBytes, totalBytes)
        XCTAssertEqual(tracker.completedFiles, count)
        XCTAssertEqual(tracker.completedBytes, totalBytes)
    }

    func testRetryFailedTransfers_OnlyRetriesFailed() async {
        let coordinator = BatchTransferCoordinator()
        let totalItems = 5
        let tracker1 = BatchProgressTracker(batchId: UUID(), totalFiles: totalItems, totalBytes: 500)
        let mockRepo = MockFileRepository()

        let items = (0..<totalItems).map { i in
            TransferQueueItem(
                remotePath: "/remote/item_\(i).txt",
                displayName: "item_\(i).txt",
                fileSize: 100
            )
        }

        // First batch: item 1 and item 3 fail permanently
        let result1 = await coordinator.executeBatch(
            items: items,
            directoriesToCreate: [],
            repository: mockRepo,
            maxConcurrent: 2,
            retryPolicy: .none,
            tracker: tracker1,
            executor: { item, progress in
                if item.displayName == "item_1.txt" || item.displayName == "item_3.txt" {
                    throw AppError.fileNotFound
                }
                progress(100)
                return nil
            },
            onUpdate: { _ in }
        )

        XCTAssertEqual(result1.completedFiles, 3)
        XCTAssertEqual(result1.failedFiles, 2)
        XCTAssertEqual(result1.failedItems.count, 2)

        // Second batch: Retry failed only
        let failedItems = result1.failedItems
        let tracker2 = BatchProgressTracker(batchId: UUID(), totalFiles: failedItems.count, totalBytes: 200)

        var retriedFileNames: [String] = []
        let lock = NSLock()

        let result2 = await coordinator.executeBatch(
            items: failedItems,
            directoriesToCreate: [],
            repository: mockRepo,
            maxConcurrent: 2,
            retryPolicy: .none,
            tracker: tracker2,
            executor: { item, progress in
                lock.lock()
                retriedFileNames.append(item.displayName)
                lock.unlock()
                progress(100)
                return nil
            },
            onUpdate: { _ in }
        )

        XCTAssertEqual(result2.completedFiles, 2)
        XCTAssertEqual(result2.failedFiles, 0)
        XCTAssertEqual(retriedFileNames.sorted(), ["item_1.txt", "item_3.txt"].sorted())
    }
}
