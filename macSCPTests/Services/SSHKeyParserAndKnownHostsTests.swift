//
//  SSHKeyParserAndKnownHostsTests.swift
//  macSCPTests
//
//  Unit tests for SSHKeyParser and isolated KnownHostsManager
//

import XCTest
import CryptoKit
import NIOCore
import NIOSSH
@testable import macSCP

final class SSHKeyParserAndKnownHostsTests: XCTestCase {

    // MARK: - OpenSSH PEM Builder Helper

    private func buildOpenSSHEd25519PEM(
        seed: Data,
        publicKeyBytes: Data,
        cipherName: String = "none",
        keyType: String = "ssh-ed25519"
    ) -> String {
        func appendSSHString(_ data: inout Data, _ bytes: Data) {
            var len = UInt32(bytes.count).bigEndian
            data.append(Data(bytes: &len, count: 4))
            data.append(bytes)
        }
        func appendSSHString(_ data: inout Data, _ string: String) {
            appendSSHString(&data, Data(string.utf8))
        }

        // Public key blob
        var pubBlob = Data()
        appendSSHString(&pubBlob, keyType)
        appendSSHString(&pubBlob, publicKeyBytes)

        // Private section
        var privSection = Data()
        var checkInt = UInt32(0x12345678).bigEndian
        privSection.append(Data(bytes: &checkInt, count: 4))
        privSection.append(Data(bytes: &checkInt, count: 4))
        appendSSHString(&privSection, keyType)
        appendSSHString(&privSection, publicKeyBytes)
        var combinedPriv = Data()
        combinedPriv.append(seed)
        combinedPriv.append(publicKeyBytes)
        appendSSHString(&privSection, combinedPriv)
        appendSSHString(&privSection, "test@macscp")

        // Outer OpenSSH v1 container
        var payload = Data("openssh-key-v1\0".utf8)
        appendSSHString(&payload, cipherName)
        appendSSHString(&payload, "none")
        appendSSHString(&payload, Data())
        var numKeys = UInt32(1).bigEndian
        payload.append(Data(bytes: &numKeys, count: 4))
        appendSSHString(&payload, pubBlob)
        appendSSHString(&payload, privSection)

        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(payload.base64EncodedString())
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    // MARK: - SSHKeyParser Tests

    func testSSHKeyParser_ValidEd25519OpenSSHPEM() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pem = buildOpenSSHEd25519PEM(
            seed: key.rawRepresentation,
            publicKeyBytes: key.publicKey.rawRepresentation
        )

        let parsed = try SSHKeyParser.parsePrivateKey(from: pem)
        let metadata = try SSHKeyParser.inspectKey(from: pem)

        XCTAssertEqual(metadata.keyType, "Ed25519")
        XCTAssertTrue(metadata.fingerprint.hasPrefix("SHA256:"))
        XCTAssertTrue(metadata.publicKeyString?.hasPrefix("ssh-ed25519 ") ?? false)
        XCTAssertEqual(
            KnownHostsManager.computeFingerprint(for: parsed.publicKey),
            metadata.fingerprint
        )
    }

    func testSSHKeyParser_RawBase64Ed25519Seed() throws {
        let key = Curve25519.Signing.PrivateKey()
        let rawBase64 = key.rawRepresentation.base64EncodedString()

        let metadata = try SSHKeyParser.inspectKey(from: rawBase64)
        XCTAssertEqual(metadata.keyType, "Ed25519")
        XCTAssertTrue(metadata.fingerprint.hasPrefix("SHA256:"))
    }

    func testSSHKeyParser_InvalidFormatThrows() {
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(from: "not-a-valid-key")) { error in
            guard case SSHKeyParser.KeyError.invalidKeyFormat = error else {
                return XCTFail("Expected invalidKeyFormat, got \(error)")
            }
        }
    }

    func testSSHKeyParser_InvalidBase64Throws() {
        let badPEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        !!!not-valid-base64!!!
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(from: badPEM)) { error in
            guard case SSHKeyParser.KeyError.base64DecodeFailed = error else {
                return XCTFail("Expected base64DecodeFailed, got \(error)")
            }
        }
    }

    func testSSHKeyParser_EncryptedKeyThrows() {
        let key = Curve25519.Signing.PrivateKey()
        let encryptedPEM = buildOpenSSHEd25519PEM(
            seed: key.rawRepresentation,
            publicKeyBytes: key.publicKey.rawRepresentation,
            cipherName: "aes256-ctr"
        )
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(from: encryptedPEM)) { error in
            guard case SSHKeyParser.KeyError.encryptedKeyNotSupported = error else {
                return XCTFail("Expected encryptedKeyNotSupported, got \(error)")
            }
        }
    }

    func testSSHKeyParser_UnsupportedKeyTypeThrowsAccurateMessage() {
        let key = Curve25519.Signing.PrivateKey()
        let rsaPEM = buildOpenSSHEd25519PEM(
            seed: key.rawRepresentation,
            publicKeyBytes: key.publicKey.rawRepresentation,
            keyType: "ssh-rsa"
        )
        XCTAssertThrowsError(try SSHKeyParser.parsePrivateKey(from: rsaPEM)) { error in
            guard case SSHKeyParser.KeyError.unsupportedKeyType(let type) = error else {
                return XCTFail("Expected unsupportedKeyType, got \(error)")
            }
            XCTAssertEqual(type, "ssh-rsa")
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("Ed25519"))
            XCTAssertFalse(desc.contains("P-256"))
        }
    }

    // MARK: - Isolated KnownHostsManager Tests

    func testKnownHostsManager_IsolatedLifecycleAndCaseInsensitiveHost() {
        let suiteName = "com.macSCP.tests.knownhosts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = KnownHostsManager(userDefaults: defaults)
        let keyA = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let keyB = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey

        // First connect adds host (TOFU)
        if case .newHostAdded = manager.verify(host: "Alpha.Example.COM", port: 2222, hostKey: keyA) {
            // expected
        } else {
            XCTFail("Expected newHostAdded")
        }

        // Case-insensitive match is trusted
        if case .trusted = manager.verify(host: "alpha.example.com", port: 2222, hostKey: keyA) {
            // expected
        } else {
            XCTFail("Expected trusted")
        }

        // Different key triggers mismatch
        if case .hostKeyMismatch = manager.verify(host: "alpha.example.com", port: 2222, hostKey: keyB) {
            // expected
        } else {
            XCTFail("Expected hostKeyMismatch")
        }

        // Add second host and verify sorted listing
        _ = manager.verify(host: "beta.example.com", port: 22, hostKey: keyB)
        let hosts = manager.allHosts()
        XCTAssertEqual(hosts.map(\.identifier), ["alpha.example.com:2222", "beta.example.com:22"])

        // Remove host and verify removal
        manager.removeHost(host: "ALPHA.EXAMPLE.COM", port: 2222)
        XCTAssertEqual(manager.allHosts().map(\.identifier), ["beta.example.com:22"])
    }
}
