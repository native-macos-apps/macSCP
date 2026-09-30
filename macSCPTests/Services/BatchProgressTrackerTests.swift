//
//  BatchProgressTrackerTests.swift
//  macSCPTests
//
//  Unit tests for BatchProgressTracker verifying accurate progress accounting,
//  partial failure handling, cancellation, drainFinal safety, and late callback protection.
//

import XCTest
@testable import macSCP

final class BatchProgressTrackerTests: XCTestCase {

    func testTracker_SuccessCompletion() {
        let tracker = BatchProgressTracker(
            batchId: UUID(),
            totalFiles: 3,
            totalBytes: 300
        )

        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        _ = tracker.registerActive(transfer: TransferProgress(id: id1, fileName: "file1.txt", totalBytes: 100))
        _ = tracker.registerActive(transfer: TransferProgress(id: id2, fileName: "file2.txt", totalBytes: 100))
        _ = tracker.registerActive(transfer: TransferProgress(id: id3, fileName: "file3.txt", totalBytes: 100))

        _ = tracker.completeFile(id: id1, totalBytes: 100)
        _ = tracker.completeFile(id: id2, totalBytes: 100)
        let finalSnap = tracker.completeFile(id: id3, totalBytes: 100)

        XCTAssertNotNil(finalSnap)
        XCTAssertEqual(tracker.completedFiles, 3)
        XCTAssertEqual(tracker.failedFiles, 0)
        XCTAssertEqual(tracker.cancelledFiles, 0)
        XCTAssertEqual(tracker.completedBytes, 300)
        XCTAssertEqual(finalSnap?.completedFiles, 3)
        XCTAssertEqual(finalSnap?.completedBytes, 300)
        XCTAssertEqual(finalSnap?.isFinal, true)
    }

    func testTracker_PartialFailureDoesNotFabricate100Percent() {
        let tracker = BatchProgressTracker(
            batchId: UUID(),
            totalFiles: 4,
            totalBytes: 400
        )

        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let id4 = UUID()

        _ = tracker.registerActive(transfer: TransferProgress(id: id1, fileName: "file1.txt", totalBytes: 100))
        _ = tracker.registerActive(transfer: TransferProgress(id: id2, fileName: "file2.txt", totalBytes: 100))
        _ = tracker.registerActive(transfer: TransferProgress(id: id3, fileName: "file3.txt", totalBytes: 100))
        _ = tracker.registerActive(transfer: TransferProgress(id: id4, fileName: "file4.txt", totalBytes: 100))

        // Complete 2 files, fail 1 file, cancel 1 file
        _ = tracker.completeFile(id: id1, totalBytes: 100)
        _ = tracker.completeFile(id: id2, totalBytes: 100)
        _ = tracker.failOrCancelFile(id: id3, totalBytes: 100, error: NSError(domain: "test", code: 1), isCancelled: false)
        let snap4 = tracker.failOrCancelFile(id: id4, totalBytes: 100, error: nil, isCancelled: true)

        XCTAssertNotNil(snap4)
        XCTAssertEqual(tracker.completedFiles, 2)
        XCTAssertEqual(tracker.failedFiles, 1)
        XCTAssertEqual(tracker.cancelledFiles, 1)
        // Completed bytes must ONLY count successfully completed files (200 bytes, not 400)
        XCTAssertEqual(tracker.completedBytes, 200)
        XCTAssertEqual(snap4?.completedBytes, 200)
        XCTAssertEqual(snap4?.transferredBytes, 200)

        // Drain final should NEVER turn failed/cancelled into completed!
        let drained = tracker.drainFinal()
        XCTAssertEqual(drained.completedFiles, 2)
        XCTAssertEqual(drained.failedFiles, 1)
        XCTAssertEqual(drained.cancelledFiles, 1)
        XCTAssertEqual(drained.completedBytes, 200)
        XCTAssertEqual(drained.transferredBytes, 200)
        XCTAssertEqual(drained.failedTransfers.count, 1)
        XCTAssertEqual(drained.failedTransfers.first?.id, id3)

        // Verify BatchTransferProgress computation with partial failure
        let batch = BatchTransferProgress(
            title: "Test Batch",
            totalFiles: 4,
            completedFiles: drained.completedFiles,
            failedFiles: drained.failedFiles,
            cancelledFiles: drained.cancelledFiles,
            totalBytes: 400,
            completedBytes: drained.completedBytes,
            transferredBytes: drained.transferredBytes,
            status: .failed,
            failedTransfers: drained.failedTransfers
        )
        // Fraction completed must be 200/400 = 0.5, NEVER 1.0
        XCTAssertEqual(batch.fractionCompleted, 0.5)
        XCTAssertTrue(batch.hasFailures)
        XCTAssertFalse(batch.isInProgress)
        XCTAssertTrue(batch.progressText.contains("2 succeeded"))
        XCTAssertTrue(batch.progressText.contains("1 failed"))
        XCTAssertTrue(batch.progressText.contains("1 cancelled"))
    }

    func testTracker_CancellationStopsAndDrainsProperly() {
        let tracker = BatchProgressTracker(
            batchId: UUID(),
            totalFiles: 3,
            totalBytes: 300
        )

        let id1 = UUID()
        let id2 = UUID()
        var cancelledHandlerCalled = false

        _ = tracker.registerActive(
            transfer: TransferProgress(id: id1, fileName: "active1.txt", totalBytes: 100),
            onCancel: { cancelledHandlerCalled = true }
        )
        _ = tracker.registerActive(
            transfer: TransferProgress(id: id2, fileName: "active2.txt", totalBytes: 100)
        )

        XCTAssertFalse(tracker.isBatchCancelled)
        tracker.cancelAll()
        XCTAssertTrue(tracker.isBatchCancelled)
        XCTAssertTrue(cancelledHandlerCalled)

        let drained = tracker.drainFinal(isCancelled: true)
        XCTAssertEqual(drained.completedFiles, 0)
        XCTAssertEqual(drained.cancelledFiles, 2)
        XCTAssertEqual(drained.completedBytes, 0)
    }

    func testTracker_LateCallbacksDoNotReverseState() {
        let tracker = BatchProgressTracker(
            batchId: UUID(),
            totalFiles: 2,
            totalBytes: 200
        )

        let id1 = UUID()
        _ = tracker.registerActive(transfer: TransferProgress(id: id1, fileName: "file1.txt", totalBytes: 100))

        // Cancel id1 first
        tracker.cancelTransfer(id: id1)
        XCTAssertEqual(tracker.cancelledFiles, 1)

        // Late completion arrives for id1 -> must be ignored!
        let lateSnap = tracker.completeFile(id: id1, totalBytes: 100)
        XCTAssertNil(lateSnap)
        XCTAssertEqual(tracker.completedFiles, 0)
        XCTAssertEqual(tracker.cancelledFiles, 1)

        // Now test reverse: complete id2 first
        let id2 = UUID()
        _ = tracker.registerActive(transfer: TransferProgress(id: id2, fileName: "file2.txt", totalBytes: 100))
        _ = tracker.completeFile(id: id2, totalBytes: 100)
        XCTAssertEqual(tracker.completedFiles, 1)

        // Late cancel/fail arrives for id2 -> must be ignored!
        let lateFailSnap = tracker.failOrCancelFile(id: id2, totalBytes: 100, error: nil, isCancelled: true)
        XCTAssertNil(lateFailSnap)
        XCTAssertEqual(tracker.completedFiles, 1)
        XCTAssertEqual(tracker.cancelledFiles, 1)
    }

    func testTracker_SnapshotSequenceIncrementsMonotonically() {
        let tracker = BatchProgressTracker(
            batchId: UUID(),
            totalFiles: 5,
            totalBytes: 500
        )

        let id = UUID()
        let snap1 = tracker.registerActive(transfer: TransferProgress(id: id, fileName: "f.txt", totalBytes: 100))
        let snap2 = tracker.completeFile(id: id, totalBytes: 100)

        if let s1 = snap1, let s2 = snap2 {
            XCTAssertGreaterThan(s2.sequence, s1.sequence)
        }
    }
}
