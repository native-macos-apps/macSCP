//
//  ConnectionMapper.swift
//  macSCP
//
//  Maps between ConnectionEntity and Connection domain model
//

import Foundation

enum ConnectionMapper {
    /// Converts a ConnectionEntity to a Connection domain model
    static func toDomain(_ entity: ConnectionEntity) -> Connection {
        Connection(
            id: entity.id,
            name: entity.name,
            host: entity.host,
            port: entity.port,
            username: entity.username,
            authMethod: AuthMethod(rawValue: entity.authMethod) ?? .password,
            sshKeyId: entity.sshKeyId,
            savePassword: entity.savePassword,
            description: entity.connectionDescription,
            tags: entity.tags,
            iconName: entity.iconName,
            folderId: entity.folder?.id,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            connectionType: ConnectionType(rawValue: entity.connectionType) ?? .sftp,
            s3Region: entity.s3Region,
            s3Bucket: entity.s3Bucket,
            s3Endpoint: entity.s3Endpoint
        )
    }

    /// Updates a ConnectionEntity from a Connection domain model
    static func update(_ entity: ConnectionEntity, from domain: Connection) {
        entity.name = domain.name
        entity.host = domain.host
        entity.port = domain.port
        entity.username = domain.username
        entity.authMethod = domain.authMethod.rawValue
        entity.sshKeyId = domain.sshKeyId
        entity.savePassword = domain.savePassword
        entity.connectionDescription = domain.description
        entity.tags = domain.tags
        entity.iconName = domain.iconName
        entity.updatedAt = Date()
        entity.connectionType = domain.connectionType.rawValue
        entity.s3Region = domain.s3Region
        entity.s3Bucket = domain.s3Bucket
        entity.s3Endpoint = domain.s3Endpoint
    }

    /// Creates a new ConnectionEntity from a Connection domain model
    static func toEntity(_ domain: Connection) -> ConnectionEntity {
        ConnectionEntity(
            id: domain.id,
            name: domain.name,
            host: domain.host,
            port: domain.port,
            username: domain.username,
            authMethod: domain.authMethod.rawValue,
            sshKeyId: domain.sshKeyId,
            savePassword: domain.savePassword,
            connectionDescription: domain.description,
            tags: domain.tags,
            iconName: domain.iconName,
            createdAt: domain.createdAt,
            updatedAt: domain.updatedAt,
            connectionType: domain.connectionType.rawValue,
            s3Region: domain.s3Region,
            s3Bucket: domain.s3Bucket,
            s3Endpoint: domain.s3Endpoint
        )
    }
}
