//
//  ConnectionEntity.swift
//  macSCP
//
//  SwiftData entity for SSH connections
//

import Foundation
import SwiftData

@Model
final class ConnectionEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: String
    var sshKeyId: UUID?
    var savePassword: Bool
    var connectionDescription: String?
    var tags: [String]
    var iconName: String
    var createdAt: Date
    var updatedAt: Date

    // S3-specific fields (connectionType defaults to "sftp" for migration compatibility)
    var connectionType: String = "sftp"
    var s3Region: String?
    var s3Bucket: String?
    var s3Endpoint: String?

    var folder: FolderEntity?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: String = "password",
        sshKeyId: UUID? = nil,
        savePassword: Bool = false,
        connectionDescription: String? = nil,
        tags: [String] = [],
        iconName: String = "server.rack",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        connectionType: String = "sftp",
        s3Region: String? = nil,
        s3Bucket: String? = nil,
        s3Endpoint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sshKeyId = sshKeyId
        self.savePassword = savePassword
        self.connectionDescription = connectionDescription
        self.tags = tags
        self.iconName = iconName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.connectionType = connectionType
        self.s3Region = s3Region
        self.s3Bucket = s3Bucket
        self.s3Endpoint = s3Endpoint
    }
}
