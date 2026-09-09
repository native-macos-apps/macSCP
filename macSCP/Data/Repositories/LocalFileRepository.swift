//
//  LocalFileRepository.swift
//  macSCP
//
//  Repository implementation for local macOS file operations
//

import Foundation

final class LocalFileRepository: FileRepositoryProtocol, @unchecked Sendable {
    private let fileManager = FileManager.default

    init() {}

    // MARK: - Path Resolution

    private func resolvePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return standardized.isEmpty ? "/" : standardized
    }

    // MARK: - FileRepositoryProtocol

    func listFiles(at path: String) async throws -> [RemoteFile] {
        let resolved = resolvePath(path)
        let url = URL(fileURLWithPath: resolved)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsPackageDescendants]
        ) else {
            // Check if directory exists
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: resolved, isDirectory: &isDir) {
                throw AppError.fileNotFound
            }
            throw AppError.permissionDenied
        }

        var files: [RemoteFile] = []
        for fileURL in contents {
            let filePath = fileURL.path
            if let file = try? fileInfo(at: filePath) {
                files.append(file)
            }
        }

        return files
    }

    func getFileInfo(at path: String) async throws -> RemoteFile {
        let resolved = resolvePath(path)
        return try fileInfo(at: resolved)
    }

    func createDirectory(at path: String) async throws {
        let resolved = resolvePath(path)
        try fileManager.createDirectory(atPath: resolved, withIntermediateDirectories: true, attributes: nil)
    }

    func createFile(at path: String) async throws {
        let resolved = resolvePath(path)
        let parentDir = (resolved as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: parentDir) {
            try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true, attributes: nil)
        }
        let created = fileManager.createFile(atPath: resolved, contents: Data(), attributes: nil)
        if !created {
            throw AppError.unknown("Failed to create file at \(resolved)")
        }
    }

    func delete(at path: String, isDirectory: Bool) async throws {
        let resolved = resolvePath(path)
        guard fileManager.fileExists(atPath: resolved) else {
            throw AppError.fileNotFound
        }
        try fileManager.removeItem(atPath: resolved)
    }

    func rename(from sourcePath: String, to destinationPath: String) async throws {
        let src = resolvePath(sourcePath)
        let dst = resolvePath(destinationPath)
        try fileManager.moveItem(atPath: src, toPath: dst)
    }

    func copy(from sourcePath: String, to destinationPath: String, isDirectory: Bool) async throws {
        let src = resolvePath(sourcePath)
        let dst = resolvePath(destinationPath)
        try fileManager.copyItem(atPath: src, toPath: dst)
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        let src = resolvePath(sourcePath)
        let dst = resolvePath(destinationPath)
        try fileManager.moveItem(atPath: src, toPath: dst)
    }

    func download(remotePath: String, to localURL: URL) async throws {
        try await download(remotePath: remotePath, to: localURL, progress: nil)
    }

    func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {
        let src = resolvePath(remotePath)
        let dst = localURL.path
        if fileManager.fileExists(atPath: dst) {
            try? fileManager.removeItem(atPath: dst)
        }
        try fileManager.copyItem(atPath: src, toPath: dst)
        if let attrs = try? fileManager.attributesOfItem(atPath: dst),
           let size = attrs[.size] as? Int64 {
            progress?(size)
        }
    }

    func upload(localURL: URL, to remotePath: String) async throws {
        try await upload(localURL: localURL, to: remotePath, progress: nil)
    }

    func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {
        let src = localURL.path
        let dst = resolvePath(remotePath)
        if fileManager.fileExists(atPath: dst) {
            try? fileManager.removeItem(atPath: dst)
        }
        try fileManager.copyItem(atPath: src, toPath: dst)
        if let attrs = try? fileManager.attributesOfItem(atPath: dst),
           let size = attrs[.size] as? Int64 {
            progress?(size)
        }
    }

    func readFileContent(at path: String) async throws -> String {
        let resolved = resolvePath(path)
        return try String(contentsOfFile: resolved, encoding: .utf8)
    }

    func writeFileContent(_ content: String, to path: String) async throws {
        let resolved = resolvePath(path)
        try content.write(toFile: resolved, atomically: true, encoding: .utf8)
    }

    func getRealPath(at path: String) async throws -> String {
        resolvePath(path)
    }

    // MARK: - Private Helpers

    private func fileInfo(at path: String) throws -> RemoteFile {
        let resolved = resolvePath(path)
        let url = URL(fileURLWithPath: resolved)
        let name = (resolved == "/" ? "/" : url.lastPathComponent)

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw AppError.fileNotFound
        }

        let isDirectory = isDir.boolValue
        let attributes = (try? fileManager.attributesOfItem(atPath: resolved)) ?? [:]

        let size = (attributes[.size] as? Int64) ?? 0
        let modificationDate = attributes[.modificationDate] as? Date
        let owner = attributes[.ownerAccountName] as? String
        let group = attributes[.groupOwnerAccountName] as? String

        let posixPerms = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? (isDirectory ? 0o755 : 0o644)
        let permissions = formatPermissions(posixPerms, isDirectory: isDirectory)

        return RemoteFile(
            name: name,
            path: resolved,
            isDirectory: isDirectory,
            size: size,
            permissions: permissions,
            modificationDate: modificationDate,
            owner: owner,
            group: group
        )
    }

    private func formatPermissions(_ perms: UInt16, isDirectory: Bool) -> String {
        var str = isDirectory ? "d" : "-"
        let user = (perms >> 6) & 0o7
        let group = (perms >> 3) & 0o7
        let other = perms & 0o7

        func triplet(_ v: UInt16) -> String {
            let r = (v & 4) != 0 ? "r" : "-"
            let w = (v & 2) != 0 ? "w" : "-"
            let x = (v & 1) != 0 ? "x" : "-"
            return "\(r)\(w)\(x)"
        }

        str += triplet(user)
        str += triplet(group)
        str += triplet(other)
        return str
    }
}
