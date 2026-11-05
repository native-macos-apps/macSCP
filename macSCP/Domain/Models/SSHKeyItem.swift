//
//  SSHKeyItem.swift
//  macSCP
//
//  Domain model representing an SSH private key stored securely in macOS Keychain
//

import Foundation

struct SSHKeyItem: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var keyType: String
    var fingerprint: String
    var publicKeyString: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        keyType: String,
        fingerprint: String,
        publicKeyString: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.publicKeyString = publicKeyString
        self.createdAt = createdAt
    }

    var displayName: String {
        "\(name) (\(keyType))"
    }

    var shortFingerprint: String {
        if fingerprint.hasPrefix("SHA256:") {
            let hash = fingerprint.dropFirst(7)
            return "SHA256:" + hash.prefix(12) + "..."
        }
        return fingerprint
    }
}
