//
//  SecurityAndTransferTests.swift
//  macSCPTests
//
//  Tests for security fixes, host key verification, and window manager cleanup
//

import XCTest
import CryptoKit
import NIOCore
import NIOSSH
@testable import macSCP

@MainActor
final class SecurityAndTransferTests: XCTestCase {
    
    override func setUp() async throws {
        try await super.setUp()
        KnownHostsManager.shared.removeHost(host: "test.example.com", port: 22)
    }

    override func tearDown() async throws {
        KnownHostsManager.shared.removeHost(host: "test.example.com", port: 22)
        try await super.tearDown()
    }

    func testKnownHostsManager_TrustOnFirstUse() throws {
        // Generate test Ed25519 key
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = NIOSSHPrivateKey(ed25519Key: privateKey).publicKey
        
        let result1 = KnownHostsManager.shared.verify(host: "test.example.com", port: 22, hostKey: publicKey)
        switch result1 {
        case .newHostAdded(let fingerprint):
            XCTAssertTrue(fingerprint.hasPrefix("SHA256:"))
        default:
            XCTFail("Expected newHostAdded on first connect, got \(result1)")
        }

        // Second connection with same key should be trusted
        let result2 = KnownHostsManager.shared.verify(host: "test.example.com", port: 22, hostKey: publicKey)
        switch result2 {
        case .trusted:
            break
        default:
            XCTFail("Expected trusted on second connect, got \(result2)")
        }
    }

    func testKnownHostsManager_DetectsMITMKeyMismatch() throws {
        let key1 = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let key2 = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey

        // First connect with key1
        _ = KnownHostsManager.shared.verify(host: "test.example.com", port: 22, hostKey: key1)

        // Second connect with different key (MITM)
        let result = KnownHostsManager.shared.verify(host: "test.example.com", port: 22, hostKey: key2)
        switch result {
        case .hostKeyMismatch(let expected, let actual):
            XCTAssertNotEqual(expected, actual)
            XCTAssertTrue(expected.hasPrefix("SHA256:"))
            XCTAssertTrue(actual.hasPrefix("SHA256:"))
        default:
            XCTFail("Expected hostKeyMismatch on MITM key change, got \(result)")
        }
    }

    func testWindowManager_RemovesDataOnWindowClose() {
        let windowManager = WindowManager.shared
        
        let browserData = FileBrowserWindowData(
            connectionId: UUID(),
            connectionName: "Test",
            host: "localhost",
            port: 22,
            username: "user",
            password: "secretpassword",
            authMethod: .password,
            privateKeyPath: nil
        )

        let id = windowManager.storeFileBrowserData(browserData)
        XCTAssertNotNil(windowManager.getFileBrowserData(for: id))

        windowManager.removeFileBrowserData(for: id)
        XCTAssertNil(windowManager.getFileBrowserData(for: id))
    }
}
