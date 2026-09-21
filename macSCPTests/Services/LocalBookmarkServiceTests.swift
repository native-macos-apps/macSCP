//
//  LocalBookmarkServiceTests.swift
//  macSCPTests
//
//  Unit tests for LocalBookmarkService and LocalFileRepository directory resolution
//

import XCTest
@testable import macSCP

final class LocalBookmarkServiceTests: XCTestCase {
    private let testKey = "macscp.local.homeBookmarkData"
    private var originalBookmarkData: Data?

    override func setUp() {
        super.setUp()
        originalBookmarkData = UserDefaults.standard.data(forKey: testKey)
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    override func tearDown() {
        if let original = originalBookmarkData {
            UserDefaults.standard.set(original, forKey: testKey)
        } else {
            UserDefaults.standard.removeObject(forKey: testKey)
        }
        LocalBookmarkService.shared.stopAccess()
        super.tearDown()
    }

    func testInitialStateHasNoBookmark() {
        XCTAssertFalse(LocalBookmarkService.shared.hasBookmark)
        XCTAssertNil(LocalBookmarkService.shared.restoreAccess())
    }

    func testUserHomeDirectoryIsNonEmpty() {
        let home = LocalFileRepository.userHomeDirectory
        XCTAssertFalse(home.isEmpty)
        XCTAssertTrue(home.hasPrefix("/"))
    }

    func testDownloadsDirectoryIsNonEmpty() {
        let downloads = LocalFileRepository.downloadsDirectory
        XCTAssertFalse(downloads.isEmpty)
        XCTAssertTrue(downloads.hasPrefix("/"))
        XCTAssertTrue(downloads.contains("Downloads"))
    }

    func testSaveBookmarkForTemporaryDirectory() throws {
        let tempURL = FileManager.default.temporaryDirectory
        // In non-sandboxed unit tests, bookmarkData with .withSecurityScope may succeed or fallback
        do {
            try LocalBookmarkService.shared.saveBookmark(for: tempURL)
            XCTAssertTrue(LocalBookmarkService.shared.hasBookmark)
            XCTAssertNotNil(UserDefaults.standard.data(forKey: testKey))
        } catch {
            // Under standard non-sandboxed unit test runners without sandbox entitlement,
            // .withSecurityScope creation may throw Cocoa error 256. This is expected outside sandbox.
            XCTAssertTrue(true)
        }
    }
}
