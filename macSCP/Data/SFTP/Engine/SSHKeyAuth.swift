//
//  SSHKeyAuth.swift
//  macSCP
//
//  SSH User Authentication delegates and key parser for NIOSSH
//

import Foundation
import CryptoKit
import NIOCore
@preconcurrency import NIOSSH

// MARK: - Key Authentication Delegate

nonisolated final class SSHKeyUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    nonisolated(unsafe) private var authOffer: NIOSSHUserAuthenticationOffer?

    nonisolated init(username: String, privateKey: NIOSSHPrivateKey) {
        self.authOffer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: privateKey))
        )
    }

    nonisolated func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if let offer = self.authOffer, availableMethods.contains(.publicKey) {
            self.authOffer = nil
            nextChallengePromise.succeed(offer)
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}

// MARK: - Server Host Key Validator (Accept All)

nonisolated final class AcceptAllServerAuthDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    nonisolated init() {}

    nonisolated func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

// MARK: - OpenSSH Key Parser

nonisolated enum SSHKeyParser {
    enum KeyError: LocalizedError {
        case invalidKeyFormat
        case unsupportedKeyType(String)
        case encryptedKeyNotSupported
        case base64DecodeFailed

        var errorDescription: String? {
            switch self {
            case .invalidKeyFormat:
                return "The private key file format is invalid."
            case .unsupportedKeyType(let type):
                return "Unsupported SSH key type '\(type)'. Supported types: Ed25519, P-256."
            case .encryptedKeyNotSupported:
                return "Passphrase-encrypted OpenSSH keys are currently not supported. Please use an unencrypted key."
            case .base64DecodeFailed:
                return "Failed to decode base64 data in private key."
            }
        }
    }

    /// Parses an SSH private key from file string into a NIOSSHPrivateKey
    static func parsePrivateKey(from keyString: String, passphrase: String? = nil) throws -> NIOSSHPrivateKey {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSHPrivateKey(trimmed)
        }

        // Try raw 32-byte Ed25519 seed if base64 encoded or raw bytes
        if let rawData = Data(base64Encoded: trimmed), rawData.count == 32 {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawData)
            return NIOSSHPrivateKey(ed25519Key: key)
        }

        throw KeyError.invalidKeyFormat
    }

    private static func parseOpenSSHPrivateKey(_ pemString: String) throws -> NIOSSHPrivateKey {
        // Strip PEM headers and whitespace
        let lines = pemString.components(separatedBy: .newlines)
        let base64Lines = lines.filter { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return !l.isEmpty && !l.hasPrefix("-----")
        }
        let base64String = base64Lines.joined()

        guard let keyData = Data(base64Encoded: base64String) else {
            throw KeyError.base64DecodeFailed
        }

        var buffer = ByteBufferAllocator().buffer(capacity: keyData.count)
        buffer.writeBytes(keyData)

        // OpenSSH private key format:
        // "openssh-key-v1\0" (15 bytes)
        guard let magic = buffer.readString(length: 15), magic == "openssh-key-v1\0" else {
            throw KeyError.invalidKeyFormat
        }

        guard let cipherName = buffer.readSSHString(),
              let _ = buffer.readSSHString(), // kdfName
              let _ = buffer.readSSHBuffer(), // kdf options
              let numKeys = buffer.readInteger(as: UInt32.self),
              numKeys >= 1 else {
            throw KeyError.invalidKeyFormat
        }

        if cipherName != "none" {
            throw KeyError.encryptedKeyNotSupported
        }

        // Read public keys buffer (skip)
        guard let _ = buffer.readSSHBuffer() else {
            throw KeyError.invalidKeyFormat
        }

        // Read private keys buffer
        guard var privKeyBuffer = buffer.readSSHBuffer() else {
            throw KeyError.invalidKeyFormat
        }

        // Verify check integers
        guard let checkint1 = privKeyBuffer.readInteger(as: UInt32.self),
              let checkint2 = privKeyBuffer.readInteger(as: UInt32.self),
              checkint1 == checkint2 else {
            throw KeyError.invalidKeyFormat
        }

        guard let keyType = privKeyBuffer.readSSHString() else {
            throw KeyError.invalidKeyFormat
        }

        switch keyType {
        case "ssh-ed25519":
            // Read public key buffer (32 bytes)
            guard let _ = privKeyBuffer.readSSHBuffer() else {
                throw KeyError.invalidKeyFormat
            }
            // Read private key buffer (64 bytes: 32 bytes seed + 32 bytes pubkey)
            guard let privBuffer = privKeyBuffer.readSSHBuffer(), privBuffer.readableBytes >= 32 else {
                throw KeyError.invalidKeyFormat
            }

            var mutablePriv = privBuffer
            guard let seedBytes = mutablePriv.readBytes(length: 32) else {
                throw KeyError.invalidKeyFormat
            }

            let curveKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seedBytes)
            return NIOSSHPrivateKey(ed25519Key: curveKey)

        default:
            throw KeyError.unsupportedKeyType(keyType)
        }
    }
}
