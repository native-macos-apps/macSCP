//
//  SSHKeyRepositoryProtocol.swift
//  macSCP
//
//  Protocol defining storage and lifecycle operations for in-app SSH keys
//

import Foundation

protocol SSHKeyRepositoryProtocol: Sendable {
    func getAllKeys() -> [SSHKeyItem]
    func getKey(by id: UUID) -> SSHKeyItem?
    func getPrivateKeyContent(for keyId: UUID) throws -> String?
    func saveKey(name: String, privateKeyContent: String) throws -> SSHKeyItem
    func deleteKey(id: UUID) throws
}
