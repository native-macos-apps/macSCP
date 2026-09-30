//
//  AnalyticsServiceTests.swift
//  macSCPTests
//
//  Tests for AnalyticsService verifying thread-safe atomic counter updates and batch tracking.
//

import XCTest
@testable import macSCP

final class AnalyticsServiceTests: XCTestCase {

    func testConcurrentAnalyticsTracking_ThreadSafeNoRace() async {
        let initialCount = AnalyticsService.totalFilesTransferred
        let taskCount = 50
        let incrementsPerTask = 10

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    for _ in 0..<incrementsPerTask {
                        _ = AnalyticsService.incrementFilesTransferred(by: 1)
                    }
                }
            }
        }

        let expectedCount = initialCount + (taskCount * incrementsPerTask)
        XCTAssertEqual(
            AnalyticsService.totalFilesTransferred,
            expectedCount,
            "Concurrent increments to totalFilesTransferred must be atomic with zero lost updates"
        )
    }

    func testBatchTransferredTracking() {
        let initialCount = AnalyticsService.totalFilesTransferred
        AnalyticsService.trackBatchTransferred(
            protocol: .sftp,
            fileCount: 42,
            totalBytes: 1024 * 1024,
            isUpload: true
        )
        XCTAssertEqual(AnalyticsService.totalFilesTransferred, initialCount + 42)
    }
}
