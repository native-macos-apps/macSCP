//
//  StreamingFileScanner.swift
//  macSCP
//
//  Builds the file and directory manifest consumed by batch transfers
//

import Foundation

nonisolated struct TransferQueueItem: Identifiable, Sendable {
    let id: UUID
    let localURL: URL?
    let remotePath: String
    let displayName: String
    let fileSize: Int64
    let isDirectory: Bool
    let isTopLevel: Bool
    let sourceRemoteFile: RemoteFile?

    init(
        id: UUID = UUID(),
        localURL: URL? = nil,
        remotePath: String,
        displayName: String,
        fileSize: Int64,
        isDirectory: Bool = false,
        isTopLevel: Bool = false,
        sourceRemoteFile: RemoteFile? = nil
    ) {
        self.id = id
        self.localURL = localURL
        self.remotePath = remotePath
        self.displayName = displayName
        self.fileSize = fileSize
        self.isDirectory = isDirectory
        self.isTopLevel = isTopLevel
        self.sourceRemoteFile = sourceRemoteFile
    }
}

nonisolated struct TransferScan: Sendable {
    var items: [TransferQueueItem] = []
    var directoriesToCreate: [String] = []
    var topLevelDirectoryNames: [String] = []
}

enum StreamingFileScanner {
    nonisolated static func scanLocalURLs(_ urls: [URL], targetRemotePath: String) async throws -> TransferScan {
        let worker = Task.detached(priority: .userInitiated) {
            try buildLocalScan(urls, targetRemotePath: targetRemotePath)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func buildLocalScan(
        _ urls: [URL],
        targetRemotePath: String
    ) throws -> TransferScan {
        var scan = TransferScan()

        for url in urls {
            try Task.checkCancellation()
            guard url.isFileURL else { throw AppError.invalidPath }
            let root = url.resolvingSymlinksInPath()
            let name = url.lastPathComponent
            let destination = targetRemotePath.appendingPathComponent(name)

            do {
                let values = try root.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values.isDirectory == true {
                    scan.topLevelDirectoryNames.append(name)
                    scan.directoriesToCreate.append(destination)
                    try scanLocalDirectory(root, name: name, target: destination, into: &scan)
                } else {
                    scan.items.append(TransferQueueItem(
                        localURL: url, remotePath: destination, displayName: name,
                        fileSize: Int64(values.fileSize ?? 0), isTopLevel: true
                    ))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppError.unknown("Could not scan '\(url.path)': \(error.localizedDescription)")
            }
        }

        try Task.checkCancellation()
        return scan
    }

    nonisolated private static func scanLocalDirectory(
        _ root: URL,
        name: String,
        target: String,
        into scan: inout TransferScan
    ) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        let fileManager = FileManager.default
        var enumerationError: AppError?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                enumerationError = .unknown("Could not read '\(url.path)': \(error.localizedDescription)")
                return false
            }
        ) else {
            throw AppError.fileReadFailed
        }

        let rootComponents = root.standardizedFileURL.pathComponents
        for case let entry as URL in enumerator {
            try Task.checkCancellation()
            let components = entry.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents), components.count > rootComponents.count else {
                throw AppError.unknown("Could not determine the relative path for '\(entry.path)'.")
            }

            let relativePath = components.dropFirst(rootComponents.count).joined(separator: "/")
            let destination = target.appendingPathComponent(relativePath)
            let values = try entry.resourceValues(forKeys: Set(keys))
            var isLinkedDirectory: ObjCBool = false
            if values.isSymbolicLink == true {
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isLinkedDirectory) else {
                    throw AppError.unknown("Could not read the target of '\(entry.path)'.")
                }
            }
            if values.isDirectory == true || isLinkedDirectory.boolValue {
                scan.directoriesToCreate.append(destination)
            } else {
                scan.items.append(TransferQueueItem(
                    localURL: entry, remotePath: destination,
                    displayName: name.appendingPathComponent(relativePath),
                    fileSize: Int64(values.fileSize ?? 0)
                ))
            }
        }

        if let enumerationError { throw enumerationError }
    }

    nonisolated static func scanRemoteFiles(
        _ files: [RemoteFile],
        targetBasePath: String,
        sourceRepo: FileRepositoryProtocol
    ) async throws -> TransferScan {
        struct Pending {
            let file: RemoteFile
            let target: String
            let displayName: String
            let isTopLevel: Bool
        }

        var scan = TransferScan()
        var pending = files.reversed().map { file in
            Pending(file: file, target: targetBasePath.appendingPathComponent(file.name),
                    displayName: file.name, isTopLevel: true)
        }

        while let entry = pending.popLast() {
            try Task.checkCancellation()
            if entry.file.isDirectory {
                let children: [RemoteFile]
                do {
                    children = try await sourceRepo.listFiles(at: entry.file.path)
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    throw AppError.unknown("Could not list '\(entry.file.path)': \(error.localizedDescription)")
                }

                scan.directoriesToCreate.append(entry.target)
                if entry.isTopLevel { scan.topLevelDirectoryNames.append(entry.displayName) }

                pending.append(contentsOf: children.reversed().map { child in
                    Pending(file: child, target: entry.target.appendingPathComponent(child.name),
                            displayName: entry.displayName.appendingPathComponent(child.name), isTopLevel: false)
                })
            } else {
                scan.items.append(TransferQueueItem(
                    remotePath: entry.target, displayName: entry.displayName,
                    fileSize: entry.file.size, isTopLevel: entry.isTopLevel,
                    sourceRemoteFile: entry.file
                ))
            }
        }

        try Task.checkCancellation()
        return scan
    }
}
