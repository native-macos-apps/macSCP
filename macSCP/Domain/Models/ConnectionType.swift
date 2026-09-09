//
//  ConnectionType.swift
//  macSCP
//
//  Connection type for distinguishing SFTP vs S3 connections
//

import Foundation

enum ConnectionType: String, Codable, Sendable, CaseIterable {
    case sftp
    case s3
    case local

    static var creatableCases: [ConnectionType] {
        [.sftp, .s3]
    }

    var displayName: String {
        switch self {
        case .sftp:
            return "SFTP"
        case .s3:
            return "S3"
        case .local:
            return "Local"
        }
    }

    var iconName: String {
        switch self {
        case .sftp:
            return "server.rack"
        case .s3:
            return "externaldrive.connected.to.line.below"
        case .local:
            return "laptopcomputer"
        }
    }

    var description: String {
        switch self {
        case .sftp:
            return "Secure File Transfer Protocol"
        case .s3:
            return "Amazon S3 / S3-Compatible Storage"
        case .local:
            return "Local macOS Filesystem"
        }
    }
}
