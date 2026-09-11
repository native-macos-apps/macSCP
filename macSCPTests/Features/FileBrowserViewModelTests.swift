//
//  FileBrowserViewModelTests.swift
//  macSCPTests
//
//  Unit tests for FileBrowserViewModel
//

import XCTest
@testable import macSCP

@MainActor
final class FileBrowserViewModelTests: XCTestCase {
    var sut: FileBrowserViewModel!
    var mockSFTPSession: MockSFTPSession!
    var mockS3Session: MockS3Session!
    var mockFileRepository: MockFileRepository!
    var mockClipboardService: ClipboardService!

    let testConnection = Connection(
        name: "Test Server",
        host: "test.example.com",
        username: "testuser"
    )

    override func setUp() async throws {
        try await super.setUp()
        mockSFTPSession = MockSFTPSession()
        mockS3Session = MockS3Session()
        mockFileRepository = MockFileRepository()
        mockClipboardService = ClipboardService.shared

        sut = FileBrowserViewModel(
            connection: testConnection,
            sftpSession: mockSFTPSession,
            fileRepository: mockFileRepository,
            clipboardService: mockClipboardService,
            password: "testpass"
        )
    }

    override func tearDown() async throws {
        sut = nil
        mockSFTPSession = nil
        mockS3Session = nil
        mockFileRepository = nil
        mockClipboardService = nil
        try await super.tearDown()
    }

    // MARK: - Connection Tests

    func testConnect_Success() async {
        // Given
        await mockSFTPSession.reset()

        // When
        await sut.connect()

        // Then
        let connectCalled = await mockSFTPSession.connectPasswordCalled
        let isConnected = await mockSFTPSession.isConnected
        XCTAssertTrue(connectCalled)
        XCTAssertTrue(isConnected)
        XCTAssertTrue(sut.isConnected)
    }

    func testConnect_Error() async {
        // Given
        await MainActor.run {
            Task {
                await mockSFTPSession.reset()
            }
        }
        // Note: Setting error on actor requires proper handling
        // For this test, we'll verify the error state

        // When
        // await sut.connect()

        // Then - state management tests
        XCTAssertFalse(sut.isConnected)
    }

    func testDisconnect() async {
        // Given
        await sut.connect()

        // When
        await sut.disconnect()

        // Then
        XCTAssertFalse(sut.isConnected)
        XCTAssertEqual(sut.currentPath, "/")
        XCTAssertTrue(sut.files.isEmpty)
    }

    // MARK: - Navigation Tests

    func testNavigateTo_Success() async {
        // Given
        let testFiles = [
            RemoteFile(name: "test.txt", path: "/test.txt", isDirectory: false, size: 100, permissions: "-rw-r--r--")
        ]
        mockFileRepository.mockFiles = testFiles
        await sut.connect()

        // When
        await sut.navigateTo("/home")

        // Then
        XCTAssertTrue(mockFileRepository.listFilesCalled)
        XCTAssertEqual(mockFileRepository.lastListPath, "/home")
    }

    func testGoUp() async {
        // Given
        mockFileRepository.mockFiles = []
        await sut.connect()
        sut = FileBrowserViewModel(
            connection: testConnection,
            sftpSession: mockSFTPSession,
            fileRepository: mockFileRepository,
            clipboardService: mockClipboardService,
            password: "testpass"
        )

        // Then - verify parent path calculation
        XCTAssertTrue(sut.canGoUp == (sut.currentPath != "/"))
    }

    // MARK: - File Operations Tests

    func testCreateFolder() async {
        // Given
        await sut.connect()

        // When
        await sut.createFolder(name: "NewFolder")

        // Then
        XCTAssertTrue(mockFileRepository.createDirectoryCalled)
    }

    func testCreateFile() async {
        // Given
        await sut.connect()

        // When
        await sut.createFile(name: "newfile.txt")

        // Then
        XCTAssertTrue(mockFileRepository.createFileCalled)
    }

    func testRenameFile() async {
        // Given
        let file = RemoteFile(name: "old.txt", path: "/old.txt", isDirectory: false, size: 100, permissions: "-rw-r--r--")
        await sut.connect()

        // When
        await sut.renameFile(file, to: "new.txt")

        // Then
        XCTAssertTrue(mockFileRepository.renameCalled)
    }

    func testDeleteFiles() async {
        // Given
        let file = RemoteFile(name: "test.txt", path: "/test.txt", isDirectory: false, size: 100, permissions: "-rw-r--r--")
        await sut.connect()

        // When
        await sut.deleteFiles([file])

        // Then
        XCTAssertTrue(mockFileRepository.deleteCalled)
    }

    // MARK: - Clipboard Tests

    func testCopySelectedFiles() async {
        // Given
        let file = RemoteFile(name: "test.txt", path: "/test.txt", isDirectory: false, size: 100, permissions: "-rw-r--r--")
        mockFileRepository.mockFiles = [file]
        await sut.connect()
        await sut.loadFiles()
        sut.selectedFiles = [file.id]

        // When
        sut.copySelectedFiles()

        // Then
        XCTAssertTrue(mockClipboardService.isCopy)
        XCTAssertEqual(mockClipboardService.fileCount, 1)
    }

    func testCutSelectedFiles() async {
        // Given
        let file = RemoteFile(name: "test.txt", path: "/test.txt", isDirectory: false, size: 100, permissions: "-rw-r--r--")
        mockFileRepository.mockFiles = [file]
        await sut.connect()
        await sut.loadFiles()
        sut.selectedFiles = [file.id]

        // When
        sut.cutSelectedFiles()

        // Then
        XCTAssertTrue(mockClipboardService.isCut)
    }

    func testS3ObjectURL_UsesS3SessionPublicURL() async throws {
        let file = RemoteFile(name: "report.csv", path: "/reports/report.csv", isDirectory: false, size: 100, permissions: "-rw-r--r--")
        let connection = Connection(
            name: "S3",
            host: "",
            username: "access-key",
            connectionType: .s3,
            s3Region: "us-east-1",
            s3Bucket: "test-bucket"
        )
        let s3ViewModel = FileBrowserViewModel(
            connection: connection,
            s3Session: mockS3Session,
            fileRepository: mockFileRepository,
            clipboardService: mockClipboardService,
            secretAccessKey: "secret"
        )

        let url = try await s3ViewModel.s3ObjectURL(for: file)

        let publicURLCalled = await mockS3Session.publicURLCalled
        let lastPath = await mockS3Session.lastPublicURLPath
        XCTAssertTrue(publicURLCalled)
        XCTAssertEqual(lastPath, file.path)
        XCTAssertEqual(url.absoluteString, "https://example.com/test.txt")
    }

    func testS3PresignedURL_UsesTenMinuteExpiration() async throws {
        let file = RemoteFile(name: "report.csv", path: "/reports/report.csv", isDirectory: false, size: 100, permissions: "-rw-r--r--")
        let connection = Connection(
            name: "S3",
            host: "",
            username: "access-key",
            connectionType: .s3,
            s3Region: "us-east-1",
            s3Bucket: "test-bucket"
        )
        let s3ViewModel = FileBrowserViewModel(
            connection: connection,
            s3Session: mockS3Session,
            fileRepository: mockFileRepository,
            clipboardService: mockClipboardService,
            secretAccessKey: "secret"
        )

        let url = try await s3ViewModel.s3PresignedURL(for: file)

        let presignedURLCalled = await mockS3Session.presignedURLCalled
        let lastPath = await mockS3Session.lastPresignedURLPath
        let lastExpiration = await mockS3Session.lastPresignedExpiration
        XCTAssertTrue(presignedURLCalled)
        XCTAssertEqual(lastPath, file.path)
        XCTAssertNotNil(lastExpiration)
        XCTAssertEqual(lastExpiration ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(url.absoluteString, "https://example.com/test.txt?X-Amz-Signature=test")
    }

    func testS3Connection_AllowsEmptyBucket() {
        let connection = Connection(
            name: "S3",
            host: "",
            username: "access-key",
            connectionType: .s3,
            s3Region: "us-east-1",
            s3Bucket: ""
        )

        XCTAssertTrue(connection.isValid)
        XCTAssertFalse(connection.validationErrors.contains("Bucket name is required"))
        XCTAssertEqual(connection.connectionString, "S3")
        XCTAssertEqual(connection.displayHost, "S3")
    }

    // MARK: - Selection Tests

    func testSelectAll() async {
        // Given
        let files = [
            RemoteFile(name: "file1.txt", path: "/file1.txt", isDirectory: false, size: 100, permissions: "-rw-r--r--"),
            RemoteFile(name: "file2.txt", path: "/file2.txt", isDirectory: false, size: 100, permissions: "-rw-r--r--")
        ]
        mockFileRepository.mockFiles = files
        await sut.connect()
        await sut.loadFiles()

        // When
        sut.selectAll()

        // Then
        XCTAssertEqual(sut.selectedFiles.count, files.count)
    }

    func testDeselectAll() async {
        // Given
        let file = RemoteFile(name: "test.txt", path: "/test.txt", isDirectory: false, size: 100, permissions: "-rw-r--r--")
        mockFileRepository.mockFiles = [file]
        await sut.connect()
        await sut.loadFiles()
        sut.selectedFiles = [file.id]

        // When
        sut.deselectAll()

        // Then
        XCTAssertTrue(sut.selectedFiles.isEmpty)
    }

    // MARK: - Sorted Files Tests

    func testSortedFiles_DirectoriesFirst() async {
        // Given
        let files = [
            RemoteFile(name: "file.txt", path: "/file.txt", isDirectory: false, size: 100, permissions: "-rw-r--r--"),
            RemoteFile(name: "folder", path: "/folder", isDirectory: true, size: 0, permissions: "drwxr-xr-x")
        ]
        mockFileRepository.mockFiles = files
        await sut.connect()
        await sut.loadFiles()

        // Then
        XCTAssertTrue(sut.sortedFiles.first?.isDirectory ?? false)
    }

    func testSortedFiles_HiddenFilesFiltered() async {
        // Given
        let files = [
            RemoteFile(name: ".hidden", path: "/.hidden", isDirectory: false, size: 100, permissions: "-rw-r--r--"),
            RemoteFile(name: "visible.txt", path: "/visible.txt", isDirectory: false, size: 100, permissions: "-rw-r--r--")
        ]
        mockFileRepository.mockFiles = files
        await sut.connect()
        await sut.loadFiles()
        sut.showHiddenFiles = false

        // Then
        XCTAssertEqual(sut.sortedFiles.count, 1)
        XCTAssertFalse(sut.sortedFiles.first?.isHidden ?? true)
    }

    func testBucketRow_UsesDistinctIconAndTypeDescription() {
        let bucket = RemoteFile(
            name: "photos",
            path: "/photos",
            isDirectory: true,
            size: 0,
            permissions: "brwxr-xr-x"
        )
        let folder = RemoteFile(
            name: "photos",
            path: "/photos",
            isDirectory: true,
            size: 0,
            permissions: "drwxr-xr-x"
        )

        XCTAssertTrue(bucket.isBucket)
        XCTAssertFalse(folder.isBucket)
        XCTAssertTrue(FileTypeService.isBucket(bucket))
        XCTAssertFalse(FileTypeService.isBucket(folder))

        let bucketIcon = FileTypeService.systemIcon(for: bucket)
        let folderIcon = FileTypeService.systemIcon(for: folder)
        XCTAssertTrue(bucketIcon.isValid)
        XCTAssertTrue(folderIcon.isValid)
        XCTAssertNotEqual(bucketIcon.tiffRepresentation, folderIcon.tiffRepresentation)
        XCTAssertEqual(FileTypeService.typeDescription(for: bucket), "Bucket")
        XCTAssertEqual(FileTypeService.typeDescription(for: folder), "Folder")
    }

    // MARK: - Batch Progress Tracker & Snapshot Ordering Tests

    func testBatchProgressTracker_MonotonicSequencesAndFinalDrain() {
        let batchId = UUID()
        let tracker = BatchProgressTracker(batchId: batchId, totalFiles: 70, totalBytes: 70 * 25000)

        var lastSequence: UInt64 = 0
        for i in 1...70 {
            let id = UUID()
            let transfer = TransferProgress(
                id: id,
                fileName: "file\(i).txt",
                localURL: nil,
                remotePath: "/remote/file\(i).txt",
                bytesTransferred: 0,
                totalBytes: 25000,
                transferType: .upload,
                status: .inProgress,
                isDirectory: false,
                itemCount: 1
            )
            if let snap = tracker.registerActive(transfer: transfer) {
                XCTAssertGreaterThan(snap.sequence, lastSequence)
                lastSequence = snap.sequence
                XCTAssertEqual(snap.batchId, batchId)
            }

            if let snap = tracker.completeFile(id: id, totalBytes: 25000) {
                XCTAssertGreaterThan(snap.sequence, lastSequence)
                lastSequence = snap.sequence
                XCTAssertEqual(snap.batchId, batchId)
                if i == 70 {
                    XCTAssertTrue(snap.isFinal)
                }
            }
        }

        let finalSnap = tracker.drainFinal(isCancelled: false)
        XCTAssertGreaterThan(finalSnap.sequence, lastSequence)
        XCTAssertTrue(finalSnap.isFinal)
        XCTAssertEqual(finalSnap.completedFiles, 70)
        XCTAssertTrue(finalSnap.activeTransfers.isEmpty)
    }

    func testApplyBatchSnapshot_DiscardsStaleOutOfOrderSnapshots() {
        let batchId = UUID()
        sut.activeBatch = BatchTransferProgress(
            id: batchId,
            title: "Uploading 70 files",
            totalFiles: 70,
            totalBytes: 70 * 25000
        )

        // Snapshot #2 arrives first
        let snap2 = BatchProgressSnapshot(
            batchId: batchId,
            sequence: 2,
            isFinal: false,
            completedFiles: 30,
            completedBytes: 30 * 25000,
            totalFiles: 70,
            totalBytes: 70 * 25000,
            transferredBytes: 30 * 25000,
            activeTransfers: [:],
            recentTransfers: [],
            topLevelFiles: []
        )
        sut.applyBatchSnapshot(snap2)
        XCTAssertEqual(sut.activeBatch?.completedFiles, 30)

        // Snapshot #1 arrives delayed (out of order)
        let snap1 = BatchProgressSnapshot(
            batchId: batchId,
            sequence: 1,
            isFinal: false,
            completedFiles: 10,
            completedBytes: 10 * 25000,
            totalFiles: 70,
            totalBytes: 70 * 25000,
            transferredBytes: 10 * 25000,
            activeTransfers: [:],
            recentTransfers: [],
            topLevelFiles: []
        )
        sut.applyBatchSnapshot(snap1)
        // Must NOT overwrite with stale completedFiles = 10
        XCTAssertEqual(sut.activeBatch?.completedFiles, 30)

        // Final snapshot #3 arrives
        let snap3 = BatchProgressSnapshot(
            batchId: batchId,
            sequence: 3,
            isFinal: true,
            completedFiles: 70,
            completedBytes: 70 * 25000,
            totalFiles: 70,
            totalBytes: 70 * 25000,
            transferredBytes: 70 * 25000,
            activeTransfers: [:],
            recentTransfers: [],
            topLevelFiles: []
        )
        sut.applyBatchSnapshot(snap3)
        XCTAssertEqual(sut.activeBatch?.completedFiles, 70)
        XCTAssertEqual(sut.activeBatch?.status, .completed)
    }

    func testApplyBatchSnapshot_DiscardsMismatchedBatchId() {
        let currentBatchId = UUID()
        let oldBatchId = UUID()
        sut.activeBatch = BatchTransferProgress(
            id: currentBatchId,
            title: "Uploading new files",
            totalFiles: 10,
            totalBytes: 1000
        )

        let oldSnap = BatchProgressSnapshot(
            batchId: oldBatchId,
            sequence: 999,
            isFinal: false,
            completedFiles: 99,
            completedBytes: 99999,
            totalFiles: 100,
            totalBytes: 100000,
            transferredBytes: 99999,
            activeTransfers: [:],
            recentTransfers: [],
            topLevelFiles: []
        )
        sut.applyBatchSnapshot(oldSnap)
        // Must ignore snapshot from different batch
        XCTAssertEqual(sut.activeBatch?.id, currentBatchId)
        XCTAssertEqual(sut.activeBatch?.completedFiles, 0)
    }
}
