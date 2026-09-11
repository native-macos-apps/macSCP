//
//  RemoteStreamTransferEngine.swift
//  macSCP
//
//  Engine for direct streaming transfers between two repositories without local disk caching
//

import Foundation

final class RemoteStreamTransferEngine: Sendable {

    /// Transfers a single file or an entire directory tree from source repository to target repository using direct streams.
    /// No intermediate files are written to local disk.
    static func transfer(
        file: RemoteFile,
        from sourceRepo: FileRepositoryProtocol,
        to targetRepo: FileRepositoryProtocol,
        targetDirectory: String,
        progress: TransferProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()

        let destinationPath = targetDirectory.hasSuffix("/")
            ? "\(targetDirectory)\(file.name)"
            : "\(targetDirectory)/\(file.name)"

        if file.isDirectory {
            try await transferDirectory(
                remoteDirPath: file.path,
                from: sourceRepo,
                to: targetRepo,
                targetDirPath: destinationPath,
                progress: progress
            )
        } else {
            let reader = try await sourceRepo.openStreamReader(at: file.path)
            var closed = false
            defer {
                if !closed {
                    Task { await reader.close() }
                }
            }

            try await targetRepo.writeStream(
                from: reader,
                to: destinationPath,
                totalSize: file.size,
                progress: progress
            )
            await reader.close()
            closed = true
        }
    }

    /// Recursively transfers a directory and all its contents using streaming
    static func transferDirectory(
        remoteDirPath: String,
        from sourceRepo: FileRepositoryProtocol,
        to targetRepo: FileRepositoryProtocol,
        targetDirPath: String,
        progress: TransferProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()

        // Create directory on target repository (ignore if already exists)
        try? await targetRepo.createDirectory(at: targetDirPath)

        let entries = try await sourceRepo.listFiles(at: remoteDirPath)
        for entry in entries {
            try Task.checkCancellation()

            let childTargetPath = targetDirPath.hasSuffix("/")
                ? "\(targetDirPath)\(entry.name)"
                : "\(targetDirPath)/\(entry.name)"

            if entry.isDirectory {
                try await transferDirectory(
                    remoteDirPath: entry.path,
                    from: sourceRepo,
                    to: targetRepo,
                    targetDirPath: childTargetPath,
                    progress: progress
                )
            } else {
                let reader = try await sourceRepo.openStreamReader(at: entry.path)
                var closed = false
                defer {
                    if !closed {
                        Task { await reader.close() }
                    }
                }

                try await targetRepo.writeStream(
                    from: reader,
                    to: childTargetPath,
                    totalSize: entry.size,
                    progress: progress
                )
                await reader.close()
                closed = true
            }
        }
    }
}
