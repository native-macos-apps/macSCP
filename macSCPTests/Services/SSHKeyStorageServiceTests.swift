//
//  SSHKeyStorageServiceTests.swift
//  macSCPTests
//
//  Tests for In-App SSH Key Storage, SSHKeyParser, and SFTPChannelHandler subsystem synchronization
//

import XCTest
import CryptoKit
import NIOCore
import NIOPosix
import NIOEmbedded
import NIOSSH
@testable import macSCP

final class SSHKeyStorageServiceTests: XCTestCase {
    private let testKeyName = "Test-Ed25519-Key"
    private var createdKeyId: UUID?

    override func tearDown() {
        if let keyId = createdKeyId {
            try? SSHKeyStorageService.shared.deleteKey(id: keyId)
            createdKeyId = nil
        }
        super.tearDown()
    }

    func testSSHKeyParser_InspectEd25519Key() throws {
        // Raw 32-byte Ed25519 seed encoded in Base64
        let rawSeed = Curve25519.Signing.PrivateKey().rawRepresentation
        let base64Seed = rawSeed.base64EncodedString()

        let metadata = try SSHKeyParser.inspectKey(from: base64Seed)
        XCTAssertEqual(metadata.keyType, "Ed25519")
        XCTAssertTrue(metadata.fingerprint.hasPrefix("SHA256:"))
        XCTAssertNotNil(metadata.publicKeyString)
        XCTAssertTrue(metadata.publicKeyString!.hasPrefix("ssh-ed25519"))
    }

    func testSSHKeyStorageService_SaveRetrieveDelete() throws {
        let rawSeed = Curve25519.Signing.PrivateKey().rawRepresentation
        let base64Seed = rawSeed.base64EncodedString()

        // 1. Save
        let item = try SSHKeyStorageService.shared.saveKey(name: testKeyName, privateKeyContent: base64Seed)
        createdKeyId = item.id

        XCTAssertEqual(item.name, testKeyName)
        XCTAssertEqual(item.keyType, "Ed25519")
        XCTAssertTrue(item.fingerprint.hasPrefix("SHA256:"))

        // 2. Retrieve metadata
        let retrieved = SSHKeyStorageService.shared.getKey(by: item.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, item.id)
        XCTAssertEqual(retrieved?.name, testKeyName)

        // 3. Retrieve private key from Keychain
        let retrievedContent = try SSHKeyStorageService.shared.getPrivateKeyContent(for: item.id)
        XCTAssertEqual(retrievedContent, base64Seed)

        // 4. Delete
        try SSHKeyStorageService.shared.deleteKey(id: item.id)
        createdKeyId = nil

        XCTAssertNil(SSHKeyStorageService.shared.getKey(by: item.id))
        XCTAssertNil(try SSHKeyStorageService.shared.getPrivateKeyContent(for: item.id))
    }

    func testSFTPChannelHandler_SubsystemSuccess() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? eventLoopGroup.syncShutdownGracefully() }

        let handler = SFTPChannelHandler()
        let eventLoop = eventLoopGroup.next()
        let promise = eventLoop.makePromise(of: Void.self)
        handler.setSubsystemPromise(promise)

        // Simulate ChannelSuccessEvent
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }

        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())

        // The promise should succeed
        try await promise.futureResult.get()
    }

    func testSFTPChannelHandler_SubsystemFailure() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? eventLoopGroup.syncShutdownGracefully() }

        let handler = SFTPChannelHandler()
        let eventLoop = eventLoopGroup.next()
        let promise = eventLoop.makePromise(of: Void.self)
        handler.setSubsystemPromise(promise)

        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }

        // Simulate ChannelFailureEvent
        channel.pipeline.fireUserInboundEventTriggered(ChannelFailureEvent())

        // The promise should fail
        do {
            try await promise.futureResult.get()
            XCTFail("Promise should have failed on ChannelFailureEvent")
        } catch {
            // Expected
            XCTAssertTrue(error.localizedDescription.contains("SFTP subsystem was rejected"))
        }
    }
}
