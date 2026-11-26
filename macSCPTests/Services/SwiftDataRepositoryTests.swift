//
//  SwiftDataRepositoryTests.swift
//  macSCPTests
//
//  Unit tests for ConnectionRepository and FolderRepository backed by an
//  isolated in-memory SwiftData DataStore.
//

import XCTest
@testable import macSCP

@MainActor
final class SwiftDataRepositoryTests: XCTestCase {
    private var dataStore: DataStore!
    private var folderRepo: FolderRepository!
    private var connectionRepo: ConnectionRepository!

    override func setUp() async throws {
        try await super.setUp()
        dataStore = DataStore(inMemoryOnly: true)
        folderRepo = FolderRepository(dataStore: dataStore)
        connectionRepo = ConnectionRepository(dataStore: dataStore)
    }

    override func tearDown() async throws {
        connectionRepo = nil
        folderRepo = nil
        dataStore = nil
        try await super.tearDown()
    }

    // MARK: - FolderRepository

    func testFolderRepository_CRUDOrderingAndExistence() async throws {
        let prod = Folder(name: "Production", displayOrder: 2)
        let staging = Folder(name: "Staging", displayOrder: 0)
        let alpha = Folder(name: "Alpha", displayOrder: 1)

        try await folderRepo.save(prod)
        try await folderRepo.save(staging)
        try await folderRepo.save(alpha)

        let count = try await folderRepo.count()
        XCTAssertEqual(count, 3)

        let all = try await folderRepo.fetchAll()
        XCTAssertEqual(all.map(\.name), ["Staging", "Alpha", "Production"])

        let fetched = try await folderRepo.fetch(id: prod.id)
        XCTAssertEqual(fetched.name, "Production")

        let existsProd = try await folderRepo.exists(name: "Production")
        let existsMissing = try await folderRepo.exists(name: "NonExistent")
        XCTAssertTrue(existsProd)
        XCTAssertFalse(existsMissing)

        var updatedProd = prod
        updatedProd.name = "Prod-EU"
        try await folderRepo.update(updatedProd)
        let afterUpdate = try await folderRepo.fetch(id: prod.id)
        XCTAssertEqual(afterUpdate.name, "Prod-EU")

        var reorderedProd = afterUpdate
        reorderedProd.displayOrder = 0
        var reorderedStaging = staging
        reorderedStaging.displayOrder = 2
        try await folderRepo.updateOrder([reorderedProd, reorderedStaging])

        let afterReorder = try await folderRepo.fetchAll()
        XCTAssertEqual(afterReorder.first?.name, "Prod-EU")

        try await folderRepo.delete(id: alpha.id)
        let remainingCount = try await folderRepo.count()
        XCTAssertEqual(remainingCount, 2)
    }

    func testFolderRepository_MissingEntityThrowsEntityNotFound() async {
        let missingId = UUID()

        do {
            _ = try await folderRepo.fetch(id: missingId)
            XCTFail("Expected entityNotFound")
        } catch let error as AppError {
            XCTAssertEqual(error, .entityNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await folderRepo.delete(id: missingId)
            XCTFail("Expected entityNotFound")
        } catch let error as AppError {
            XCTAssertEqual(error, .entityNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - ConnectionRepository

    func testConnectionRepository_CRUDFolderFilterMoveSearchAndCounts() async throws {
        let folderA = Folder(name: "AWS", displayOrder: 0)
        let folderB = Folder(name: "OnPrem", displayOrder: 1)
        try await folderRepo.save(folderA)
        try await folderRepo.save(folderB)

        let sftpConn = Connection(
            name: "Web Server",
            host: "10.0.0.5",
            port: 2222,
            username: "deploy",
            folderId: folderA.id
        )
        let s3Conn = Connection(
            name: "Backup Bucket",
            host: "s3.amazonaws.com",
            port: 443,
            username: "AKIAEXAMPLE",
            folderId: nil,
            connectionType: .s3,
            s3Region: "us-east-1",
            s3Bucket: "backups"
        )

        try await connectionRepo.save(sftpConn)
        try await connectionRepo.save(s3Conn)

        let total = try await connectionRepo.count()
        let inFolderA = try await connectionRepo.count(forFolderId: folderA.id)
        let ungroupedCount = try await connectionRepo.count(forFolderId: nil)
        XCTAssertEqual(total, 2)
        XCTAssertEqual(inFolderA, 1)
        XCTAssertEqual(ungroupedCount, 1)

        let all = try await connectionRepo.fetchAll()
        XCTAssertEqual(all.map(\.name), ["Backup Bucket", "Web Server"])

        let folderAConns = try await connectionRepo.fetchConnections(forFolderId: folderA.id)
        XCTAssertEqual(folderAConns.map(\.id), [sftpConn.id])

        let ungrouped = try await connectionRepo.fetchConnections(forFolderId: nil)
        XCTAssertEqual(ungrouped.map(\.id), [s3Conn.id])

        // Search by host / username / name
        let byHost = try await connectionRepo.search(query: "10.0.0")
        XCTAssertEqual(byHost.map(\.id), [sftpConn.id])
        let byUser = try await connectionRepo.search(query: "akia")
        XCTAssertEqual(byUser.map(\.id), [s3Conn.id])

        // Move connection to folderB and then to ungrouped
        try await connectionRepo.move(connectionId: sftpConn.id, toFolderId: folderB.id)
        let moved = try await connectionRepo.fetch(id: sftpConn.id)
        XCTAssertEqual(moved.folderId, folderB.id)

        // Update connection fields and folder
        var edited = moved
        edited.name = "Web Server Updated"
        edited.port = 22
        edited.folderId = folderA.id
        try await connectionRepo.update(edited)

        let fetchedEdited = try await connectionRepo.fetch(id: sftpConn.id)
        XCTAssertEqual(fetchedEdited.name, "Web Server Updated")
        XCTAssertEqual(fetchedEdited.port, 22)
        XCTAssertEqual(fetchedEdited.folderId, folderA.id)

        // Deleting folderA nullifies connection's folderId instead of deleting connection
        try await folderRepo.delete(id: folderA.id)
        let orphaned = try await connectionRepo.fetch(id: sftpConn.id)
        XCTAssertNil(orphaned.folderId)

        // Delete connection
        try await connectionRepo.delete(id: sftpConn.id)
        let finalCount = try await connectionRepo.count()
        XCTAssertEqual(finalCount, 1)
    }

    func testConnectionRepository_MissingEntityThrowsEntityNotFound() async {
        let missingId = UUID()

        do {
            _ = try await connectionRepo.fetch(id: missingId)
            XCTFail("Expected entityNotFound")
        } catch let error as AppError {
            XCTAssertEqual(error, .entityNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await connectionRepo.move(connectionId: missingId, toFolderId: nil)
            XCTFail("Expected entityNotFound")
        } catch let error as AppError {
            XCTAssertEqual(error, .entityNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
