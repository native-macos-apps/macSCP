//
//  StreamingFileScanner.swift
//  macSCP
//
//  Producer-consumer streaming file enumerator with bounded buffer and cancellation support
//

import Foundation

struct TransferQueueItem: Identifiable, Sendable {
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

enum ScannedItemEvent: Sendable {
    case topLevelFolder(RemoteFile)
    case directory(remotePath: String)
    case file(TransferQueueItem)
    case finished(totalFiles: Int, totalBytes: Int64)
}

enum StreamingFileScanner {
    /// Streams local files and directories for upload without loading entire trees into memory upfront.
    static func streamLocalURLs(
        _ urls: [URL],
        targetRemotePath: String,
        bufferSize: Int = 100
    ) -> AsyncStream<ScannedItemEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var totalFiles = 0
                var totalBytes: Int64 = 0

                for url in urls {
                    if Task.isCancelled { break }
                    guard url.isFileURL else { continue }

                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

                    if !isDir.boolValue {
                        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                        let remotePath = targetRemotePath.appendingPathComponent(url.lastPathComponent)
                        let item = TransferQueueItem(
                            localURL: url,
                            remotePath: remotePath,
                            displayName: url.lastPathComponent,
                            fileSize: size,
                            isDirectory: false,
                            isTopLevel: true
                        )
                        totalFiles += 1
                        totalBytes += size
                        continuation.yield(.file(item))
                    } else {
                        let folderName = url.lastPathComponent
                        let rootRemotePath = targetRemotePath.appendingPathComponent(folderName)
                        let formattedPath = rootRemotePath.hasSuffix("/") ? rootRemotePath : rootRemotePath + "/"
                        let topFolder = RemoteFile(
                            name: folderName,
                            path: formattedPath,
                            isDirectory: true,
                            size: 0,
                            permissions: "drwxr-xr-x",
                            modificationDate: Date()
                        )
                        continuation.yield(.topLevelFolder(topFolder))
                        continuation.yield(.directory(remotePath: rootRemotePath))

                        let baseDirURL = url.deletingLastPathComponent()
                        if let enumerator = FileManager.default.enumerator(
                            at: url,
                            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                            options: [.skipsHiddenFiles]
                        ) {
                            for case let fileURL as URL in enumerator {
                                if Task.isCancelled { break }

                                var childIsDir: ObjCBool = false
                                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &childIsDir) else { continue }

                                let relativePath: String
                                if fileURL.path.hasPrefix(baseDirURL.path) {
                                    relativePath = String(fileURL.path.dropFirst(baseDirURL.path.count))
                                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                } else {
                                    relativePath = fileURL.lastPathComponent
                                }
                                let childRemotePath = targetRemotePath.appendingPathComponent(relativePath)

                                if childIsDir.boolValue {
                                    continuation.yield(.directory(remotePath: childRemotePath))
                                } else {
                                    let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                                    let item = TransferQueueItem(
                                        localURL: fileURL,
                                        remotePath: childRemotePath,
                                        displayName: relativePath,
                                        fileSize: size,
                                        isDirectory: false,
                                        isTopLevel: false
                                    )
                                    totalFiles += 1
                                    totalBytes += size
                                    continuation.yield(.file(item))
                                }
                            }
                        }
                    }
                }

                continuation.yield(.finished(totalFiles: totalFiles, totalBytes: totalBytes))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Streams remote files and directories for Commander transfers without unbounded memory allocation.
    static func streamRemoteFiles(
        _ files: [RemoteFile],
        targetBasePath: String,
        sourceRepo: FileRepositoryProtocol,
        bufferSize: Int = 100
    ) -> AsyncStream<ScannedItemEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var totalFiles = 0
                var totalBytes: Int64 = 0

                for file in files {
                    if Task.isCancelled { break }
                    let destPath = targetBasePath.appendingPathComponent(file.name)

                    if file.isDirectory {
                        let topFolder = RemoteFile(
                            name: file.name,
                            path: destPath.hasSuffix("/") ? destPath : destPath + "/",
                            isDirectory: true,
                            size: 0,
                            permissions: file.permissions,
                            modificationDate: file.modificationDate,
                            owner: file.owner,
                            group: file.group
                        )
                        continuation.yield(.topLevelFolder(topFolder))
                        continuation.yield(.directory(remotePath: destPath))

                        // Recursively enumerate directory levels
                        await enumerateRemoteDirectory(
                            at: file.path,
                            relativePrefix: file.name,
                            targetBaseDir: destPath,
                            sourceRepo: sourceRepo,
                            continuation: continuation,
                            totalFiles: &totalFiles,
                            totalBytes: &totalBytes
                        )
                    } else {
                        let item = TransferQueueItem(
                            remotePath: destPath,
                            displayName: file.name,
                            fileSize: file.size,
                            isDirectory: false,
                            isTopLevel: true,
                            sourceRemoteFile: file
                        )
                        totalFiles += 1
                        totalBytes += file.size
                        continuation.yield(.file(item))
                    }
                }

                continuation.yield(.finished(totalFiles: totalFiles, totalBytes: totalBytes))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func enumerateRemoteDirectory(
        at remoteDirPath: String,
        relativePrefix: String,
        targetBaseDir: String,
        sourceRepo: FileRepositoryProtocol,
        continuation: AsyncStream<ScannedItemEvent>.Continuation,
        totalFiles: inout Int,
        totalBytes: inout Int64
    ) async {
        if Task.isCancelled { return }

        guard let children = try? await sourceRepo.listFiles(at: remoteDirPath) else {
            return
        }

        for child in children {
            if Task.isCancelled { break }
            let childRelative = relativePrefix.appendingPathComponent(child.name)
            let childTargetPath = targetBaseDir.appendingPathComponent(child.name)

            if child.isDirectory {
                continuation.yield(.directory(remotePath: childTargetPath))
                await enumerateRemoteDirectory(
                    at: child.path,
                    relativePrefix: childRelative,
                    targetBaseDir: childTargetPath,
                    sourceRepo: sourceRepo,
                    continuation: continuation,
                    totalFiles: &totalFiles,
                    totalBytes: &totalBytes
                )
            } else {
                let item = TransferQueueItem(
                    remotePath: childTargetPath,
                    displayName: childRelative,
                    fileSize: child.size,
                    isDirectory: false,
                    isTopLevel: false,
                    sourceRemoteFile: child
                )
                totalFiles += 1
                totalBytes += child.size
                continuation.yield(.file(item))
            }
        }
    }
}
