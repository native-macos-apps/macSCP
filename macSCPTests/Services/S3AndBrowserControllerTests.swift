//
//  S3AndBrowserControllerTests.swift
//  macSCPTests
//
//  Unit tests for S3PathResolver, S3ErrorMapper, BrowserQuickLookController,
//  FileTransferManager, BatchTransferCoordinator transferType, and AppLockManager auth flows
//

import XCTest
@testable import macSCP

@MainActor
final class S3AndBrowserControllerTests: XCTestCase {

    // MARK: - S3PathResolver Tests

    func testS3PathResolver_BucketScopedResolutionAndAWSURL() throws {
        let resolver = S3PathResolver(
            configuredBucketName: "my-bucket",
            regionName: "ap-southeast-1",
            endpointURL: nil,
            usesPathStyleURLs: false
        )

        let rootList = try resolver.resolveListTarget(for: "/")
        XCTAssertEqual(rootList.bucket, "my-bucket")
        XCTAssertEqual(rootList.prefix, "")
        XCTAssertEqual(rootList.displayPath, "/")

        let nestedList = try resolver.resolveListTarget(for: "/logs/2026")
        XCTAssertEqual(nestedList.bucket, "my-bucket")
        XCTAssertEqual(nestedList.prefix, "logs/2026/")
        XCTAssertEqual(nestedList.displayPath, "/logs/2026/")

        let objTarget = try resolver.resolveObjectTarget(for: "/logs/my file.txt")
        XCTAssertEqual(objTarget.bucket, "my-bucket")
        XCTAssertEqual(objTarget.key, "logs/my file.txt")

        let url = resolver.buildObjectURL(bucket: objTarget.bucket, forKey: objTarget.key)
        XCTAssertEqual(url?.absoluteString, "https://my-bucket.s3.ap-southeast-1.amazonaws.com/logs/my%20file.txt")
    }

    func testS3PathResolver_AccountScopedAndCustomEndpointPathStyleURL() throws {
        let endpoint = S3PathResolver.normalizeEndpointURL("minio.local:9000/storage")
        XCTAssertEqual(endpoint?.absoluteString, "https://minio.local:9000/storage")
        XCTAssertNil(S3PathResolver.normalizeEndpointURL("   "))

        let resolver = S3PathResolver(
            configuredBucketName: "",
            regionName: "us-east-1",
            endpointURL: endpoint,
            usesPathStyleURLs: true
        )

        let root = try resolver.resolveListTarget(for: "/")
        XCTAssertEqual(root.bucket, "")
        XCTAssertEqual(root.displayPath, "/")

        let bucketDir = try resolver.resolveListTarget(for: "/assets/images")
        XCTAssertEqual(bucketDir.bucket, "assets")
        XCTAssertEqual(bucketDir.prefix, "images/")
        XCTAssertEqual(bucketDir.displayPath, "/assets/images")

        let obj = try resolver.resolveObjectTarget(for: "/assets/images/logo.png")
        XCTAssertEqual(obj.bucket, "assets")
        XCTAssertEqual(obj.key, "images/logo.png")

        let url = resolver.buildObjectURL(bucket: obj.bucket, forKey: obj.key)
        XCTAssertEqual(url?.absoluteString, "https://minio.local:9000/storage/assets/images/logo.png")
        XCTAssertEqual(resolver.buildDisplayPath(bucket: "assets", key: "images/logo.png"), "/assets/images/logo.png")
    }

    func testS3ErrorMapper_MapsTypedAndDescriptiveErrors() {
        XCTAssertEqual(S3ErrorMapper.mapOperationError(AppError.invalidFileEncoding), .invalidFileEncoding)
        XCTAssertEqual(S3ErrorMapper.mapConnectionError(URLError(.timedOut)), .connectionTimeout)
        XCTAssertEqual(
            S3ErrorMapper.mapOperationError(NSError(domain: "S3", code: 404, userInfo: [NSLocalizedDescriptionKey: "NoSuchBucket"])),
            .s3BucketNotFound
        )
        XCTAssertEqual(
            S3ErrorMapper.mapOperationError(NSError(domain: "S3", code: 403, userInfo: [NSLocalizedDescriptionKey: "AccessDenied"])),
            .s3AccessDenied
        )
    }

    // MARK: - BrowserQuickLookController Tests

    func testQuickLookController_CachesSuccessAndDoesNotCacheErrors() async {
        let mockRepo = MockFileRepository()
        let file = RemoteFile(name: "notes.txt", path: "/notes.txt", isDirectory: false, size: 12, permissions: "-rw-r--r--")
        let controller = BrowserQuickLookController(fileRepository: mockRepo)

        // First load fails transiently
        mockRepo.mockError = AppError.connectionTimeout
        controller.quickLookFile = file
        await controller.loadContent(for: file)

        if case .error = controller.quickLookContent {
            // expected
        } else {
            XCTFail("Expected .error state")
        }
        XCTAssertFalse(controller.hasCachedEntry(forPath: file.path), "Errors must not be cached")

        // Second load succeeds and gets cached
        mockRepo.mockError = nil
        mockRepo.mockFileContent = "Hello QuickLook"
        await controller.loadContent(for: file)

        if case .text(let content) = controller.quickLookContent {
            XCTAssertEqual(content, "Hello QuickLook")
        } else {
            XCTFail("Expected .text state")
        }
        XCTAssertTrue(controller.hasCachedEntry(forPath: file.path))

        // Reset clears cache
        controller.reset()
        XCTAssertFalse(controller.hasCachedEntry(forPath: file.path))
        XCTAssertNil(controller.quickLookFile)
    }

    // MARK: - FileTransferManager & BatchTransferCoordinator Tests

    func testFileTransferManager_DiscardsOutOfOrderSnapshotsAndCapsRecentAt30() {
        let manager = FileTransferManager()
        let batchId = UUID()
        manager.activeBatch = BatchTransferProgress(id: batchId, title: "Test", totalFiles: 2, totalBytes: 200, status: .inProgress)

        let snap2 = BatchProgressSnapshot(
            batchId: batchId,
            sequence: 2,
            isFinal: false,
            completedFiles: 2,
            completedBytes: 200,
            totalFiles: 2,
            totalBytes: 200,
            transferredBytes: 200
        )
        let snap1 = BatchProgressSnapshot(
            batchId: batchId,
            sequence: 1,
            isFinal: false,
            completedFiles: 1,
            completedBytes: 100,
            totalFiles: 2,
            totalBytes: 200,
            transferredBytes: 100
        )

        XCTAssertTrue(manager.applyBatchSnapshot(snap2))
        XCTAssertEqual(manager.activeBatch?.completedFiles, 2)

        // Older sequence must be discarded
        XCTAssertFalse(manager.applyBatchSnapshot(snap1))
        XCTAssertEqual(manager.activeBatch?.completedFiles, 2)

        // Recent transfers cap must be consistently 30
        for i in 0..<40 {
            let transfer = TransferProgress(
                id: UUID(),
                fileName: "file_\(i).txt",
                remotePath: "/file_\(i).txt",
                bytesTransferred: 0,
                totalBytes: 10,
                transferType: .download,
                status: .inProgress
            )
            manager.trackTransfer(transfer)
            manager.completeTransfer(id: transfer.id, totalBytes: 10)
        }
        XCTAssertEqual(manager.recentTransfers.count, FileTransferManager.maxRecentTransfers)
        XCTAssertEqual(FileTransferManager.maxRecentTransfers, 30)
    }

    func testBatchTransferCoordinator_PropagatesDownloadTransferType() async {
        let coordinator = BatchTransferCoordinator()
        let item = TransferQueueItem(remotePath: "/local/a.txt", displayName: "a.txt", fileSize: 50)
        let tracker = BatchProgressTracker(batchId: UUID(), totalFiles: 1, totalBytes: 50)
        let mockRepo = MockFileRepository()

        var observedTypes: [TransferType] = []
        let lock = NSLock()

        _ = await coordinator.executeBatch(
            items: [item],
            directoriesToCreate: [],
            repository: mockRepo,
            maxConcurrent: 1,
            transferType: .download,
            retryPolicy: .none,
            tracker: tracker,
            executor: { _, progress in
                progress(50)
                return nil
            },
            onUpdate: { snapshot in
                lock.lock()
                for t in snapshot.activeTransfers.values { observedTypes.append(t.transferType) }
                for t in snapshot.recentTransfers { observedTypes.append(t.transferType) }
                lock.unlock()
            }
        )

        XCTAssertFalse(observedTypes.isEmpty)
        XCTAssertTrue(observedTypes.allSatisfy { $0 == .download })
    }

    // MARK: - AppLockManager Auth Flow Tests

    private final class MockBiometricService: BiometricAuthServiceProtocol, @unchecked Sendable {
        var available = true
        var result: Result<Void, BiometricError> = .success(())
        private(set) var authenticateCalls = 0

        func isBiometricAvailable() -> Bool { available }
        func authenticate(reason: String) async -> Result<Void, BiometricError> {
            authenticateCalls += 1
            return result
        }
    }

    func testAppLockManager_DisableRequiresBiometricAndAuthenticateForConnection() async {
        let suiteName = "com.macSCP.tests.applock.auth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let bio = MockBiometricService()
        let manager = AppLockManager(
            biometricService: bio,
            userDefaults: defaults,
            installObservers: false
        )

        manager.enableBiometricLock()
        XCTAssertTrue(manager.isBiometricLockEnabled)

        // When lockBeforeConnection is false, connection is allowed without prompting
        manager.lockBeforeConnection = false
        let allowedWithoutLock = await manager.authenticateForConnection()
        XCTAssertTrue(allowedWithoutLock)
        XCTAssertEqual(bio.authenticateCalls, 0)

        // When lockBeforeConnection is true, biometric auth is invoked
        manager.lockBeforeConnection = true
        bio.result = .failure(.userCancelled)
        let deniedConnection = await manager.authenticateForConnection()
        XCTAssertFalse(deniedConnection)
        XCTAssertEqual(bio.authenticateCalls, 1)

        // Disabling lock fails when biometric fails
        let disabledOnFail = await manager.disableBiometricLock()
        XCTAssertFalse(disabledOnFail)
        XCTAssertTrue(manager.isBiometricLockEnabled)

        // Disabling lock succeeds when biometric succeeds
        bio.result = .success(())
        let disabledOnSuccess = await manager.disableBiometricLock()
        XCTAssertTrue(disabledOnSuccess)
        XCTAssertFalse(manager.isBiometricLockEnabled)
    }
}
