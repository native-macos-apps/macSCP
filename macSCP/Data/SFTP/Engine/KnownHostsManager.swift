//
//  KnownHostsManager.swift
//  macSCP
//
//  SSH Host Key validation and storage (Trust On First Use + MITM attack prevention)
//

import Foundation
import CryptoKit
import NIOCore
import NIOSSH

enum HostKeyVerificationResult: Sendable {
    case trusted
    case newHostAdded(fingerprint: String)
    case hostKeyMismatch(expectedFingerprint: String, actualFingerprint: String)
}

final class KnownHostsManager: @unchecked Sendable {
    static let shared = KnownHostsManager()
    private let storageKey = "com.macSCP.knownHosts"
    private let lock = NSLock()

    private init() {}

    static func computeFingerprint(for hostKey: NIOSSHPublicKey) -> String {
        let keyString = String(openSSHPublicKey: hostKey)
        let parts = keyString.split(separator: " ")
        if parts.count >= 2, let keyData = Data(base64Encoded: String(parts[1])) {
            let digest = SHA256.hash(data: keyData)
            return "SHA256:" + Data(digest).base64EncodedString()
        }
        let digest = SHA256.hash(data: Data(keyString.utf8))
        return "SHA256:" + Data(digest).base64EncodedString()
    }

    func verify(host: String, port: Int, hostKey: NIOSSHPublicKey) -> HostKeyVerificationResult {
        lock.lock()
        defer { lock.unlock() }

        let identifier = "\(host.lowercased()):\(port)"
        let actualFingerprint = Self.computeFingerprint(for: hostKey)

        let defaults = UserDefaults.standard
        var knownHosts = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]

        if let expectedFingerprint = knownHosts[identifier] {
            if expectedFingerprint == actualFingerprint {
                return .trusted
            } else {
                return .hostKeyMismatch(expectedFingerprint: expectedFingerprint, actualFingerprint: actualFingerprint)
            }
        } else {
            // Trust On First Use (TOFU): Record host key on first connection
            knownHosts[identifier] = actualFingerprint
            defaults.set(knownHosts, forKey: storageKey)
            return .newHostAdded(fingerprint: actualFingerprint)
        }
    }

    func removeHost(host: String, port: Int) {
        removeHost(identifier: "\(host.lowercased()):\(port)")
    }

    func removeHost(identifier: String) {
        lock.lock()
        defer { lock.unlock() }

        let defaults = UserDefaults.standard
        var knownHosts = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        knownHosts.removeValue(forKey: identifier)
        defaults.set(knownHosts, forKey: storageKey)
    }

    /// All trusted hosts as (identifier "host:port", fingerprint), sorted by identifier.
    func allHosts() -> [(identifier: String, fingerprint: String)] {
        lock.lock()
        defer { lock.unlock() }

        let knownHosts = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        return knownHosts
            .map { (identifier: $0.key, fingerprint: $0.value) }
            .sorted { $0.identifier < $1.identifier }
    }
}
