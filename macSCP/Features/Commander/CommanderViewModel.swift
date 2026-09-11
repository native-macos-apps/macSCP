//
//  CommanderViewModel.swift
//  macSCP
//
//  ViewModel for the dual-pane Commander workspace
//

import Foundation
import SwiftUI

enum PanePosition: String, CaseIterable, Identifiable, Sendable {
    case left
    case right

    var id: String { rawValue }

    var other: PanePosition {
        self == .left ? .right : .left
    }
}

enum PaneContentType: Equatable {
    case local
    case remote(Connection)
    case servers

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    var isLocal: Bool {
        self == .local
    }

    var isServers: Bool {
        self == .servers
    }

    var connection: Connection? {
        if case .remote(let conn) = self { return conn }
        return nil
    }

    var title: String {
        switch self {
        case .local:
            return "Local"
        case .remote(let connection):
            return connection.name
        case .servers:
            return "Servers"
        }
    }

    var iconName: String {
        switch self {
        case .local:
            return "laptopcomputer"
        case .remote(let conn):
            return conn.connectionType.iconName
        case .servers:
            return "server.rack"
        }
    }
}

@MainActor
@Observable
final class CommanderPaneState: Identifiable {
    let id: UUID = UUID()
    let position: PanePosition
    var contentType: PaneContentType
    var browserViewModel: FileBrowserViewModel?
    var serverSearchText: String = ""

    init(position: PanePosition, contentType: PaneContentType, browserViewModel: FileBrowserViewModel? = nil) {
        self.position = position
        self.contentType = contentType
        self.browserViewModel = browserViewModel
    }
}

@MainActor
@Observable
final class CommanderViewModel {
    // MARK: - Panes State
    var leftPane: CommanderPaneState
    var rightPane: CommanderPaneState
    var activePanePosition: PanePosition = .left
    var isDualPane: Bool = true

    // MARK: - Sheets & Prompts
    var isShowingPasswordPrompt: Bool = false
    var isShowingNewConnectionSheet: Bool = false
    var isShowingTransfersPopover: Bool = false
    var activeBatch: BatchTransferProgress?
    private var isBatchCancelled: Bool = false
    private var currentBatchTracker: BatchProgressTracker?
    var pendingConnection: Connection?
    var pendingPanePosition: PanePosition?

    var error: AppError?

    // MARK: - Dependencies
    private let dependencyContainer: DependencyContainer
    var connectionListViewModel: ConnectionListViewModel

    // MARK: - Computed Properties

    var activePane: CommanderPaneState {
        pane(for: activePanePosition)
    }

    var inactivePane: CommanderPaneState {
        pane(for: activePanePosition.other)
    }

    func pane(for position: PanePosition) -> CommanderPaneState {
        position == .left ? leftPane : rightPane
    }

    /// Aggregated active transfers across both panes
    var allActiveTransfers: [TransferProgress] {
        var transfers: [TransferProgress] = []
        if let leftTransfers = leftPane.browserViewModel?.activeTransfers.values {
            transfers.append(contentsOf: leftTransfers)
        }
        if let rightTransfers = rightPane.browserViewModel?.activeTransfers.values {
            transfers.append(contentsOf: rightTransfers)
        }
        return transfers.sorted { $0.startTime > $1.startTime }
    }

    var allRecentTransfers: [TransferProgress] {
        var recent: [TransferProgress] = []
        if let leftRecent = leftPane.browserViewModel?.recentTransfers {
            recent.append(contentsOf: leftRecent)
        }
        if let rightRecent = rightPane.browserViewModel?.recentTransfers {
            recent.append(contentsOf: rightRecent)
        }
        return recent.sorted { $0.startTime > $1.startTime }
    }

    var currentActiveBatch: BatchTransferProgress? {
        activeBatch ?? leftPane.browserViewModel?.activeBatch ?? rightPane.browserViewModel?.activeBatch
    }

    var hasActiveTransfers: Bool {
        !allActiveTransfers.isEmpty || (currentActiveBatch?.isInProgress ?? false)
    }

    var activeTransferCount: Int {
        if let batch = currentActiveBatch, batch.isInProgress {
            return max(1, batch.totalFiles - batch.completedFiles)
        }
        return allActiveTransfers.count
    }

    var overallProgress: Double {
        if let batch = currentActiveBatch, batch.totalBytes > 0 {
            return batch.fractionCompleted
        }
        let transfers = allActiveTransfers
        guard !transfers.isEmpty else { return 0 }
        let totalBytes = transfers.reduce(0) { $0 + $1.totalBytes }
        let transferredBytes = transfers.reduce(0) { $0 + $1.bytesTransferred }
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }

    func cancelBatch() {
        isBatchCancelled = true
        activeBatch?.status = .cancelled
        currentBatchTracker?.cancelAll()
        leftPane.browserViewModel?.cancelBatch()
        rightPane.browserViewModel?.cancelBatch()
    }

    func clearCompletedTransfers() {
        currentBatchTracker?.clearCompleted()
        if activeBatch?.status == .completed || activeBatch?.status == .cancelled || activeBatch?.status == .failed {
            activeBatch = nil
        }
        leftPane.browserViewModel?.clearCompletedTransfers()
        rightPane.browserViewModel?.clearCompletedTransfers()
    }

    func removeTransfer(_ transfer: TransferProgress) {
        currentBatchTracker?.removeRecent(id: transfer.id)
        leftPane.browserViewModel?.removeTransfer(transfer)
        rightPane.browserViewModel?.removeTransfer(transfer)
    }

    // MARK: - Initialization

    init(container: DependencyContainer) {
        self.dependencyContainer = container
        self.connectionListViewModel = container.makeConnectionListViewModel()

        // Initialize Left pane as Local
        let localVM = container.makeLocalFileBrowserViewModel()
        self.leftPane = CommanderPaneState(
            position: .left,
            contentType: .local,
            browserViewModel: localVM
        )

        // Initialize Right pane as Servers by default
        self.rightPane = CommanderPaneState(
            position: .right,
            contentType: .servers,
            browserViewModel: nil
        )

        // Connect local browser
        Task { @MainActor in
            await localVM.connect()
            await connectionListViewModel.loadData()
        }
    }

    convenience init() {
        self.init(container: DependencyContainer.shared)
    }

    // MARK: - Pane Source Management

    func switchToLocal(in position: PanePosition, initialPath: String? = nil) {
        let targetPane = pane(for: position)
        if case .remote = targetPane.contentType {
            Task {
                await targetPane.browserViewModel?.disconnect()
            }
        }

        let localVM = dependencyContainer.makeLocalFileBrowserViewModel(initialPath: initialPath)
        targetPane.contentType = .local
        targetPane.browserViewModel = localVM

        Task {
            await localVM.connect()
        }
    }

    func switchToServers(in position: PanePosition) {
        let targetPane = pane(for: position)
        if case .remote = targetPane.contentType {
            Task {
                await targetPane.browserViewModel?.disconnect()
            }
        }

        targetPane.contentType = .servers
        targetPane.browserViewModel = nil

        Task {
            await connectionListViewModel.loadData()
        }
    }

    func disconnect(in position: PanePosition) {
        let targetPane = pane(for: position)
        Task {
            await targetPane.browserViewModel?.disconnect()
            targetPane.contentType = .servers
            targetPane.browserViewModel = nil
        }
    }

    // MARK: - Connection

    func connect(to connection: Connection, in position: PanePosition) {
        Task { @MainActor in
            let allowed = await AppLockManager.shared.authenticateForConnection()
            guard allowed else {
                logInfo("Connection cancelled: biometric auth denied", category: .auth)
                return
            }

            if connection.connectionType == .s3 {
                if let credentials = dependencyContainer.keychainService.getS3Credentials(for: connection.id) {
                    await completeConnect(to: connection, in: position, password: credentials.secretAccessKey)
                } else {
                    pendingConnection = connection
                    pendingPanePosition = position
                    isShowingPasswordPrompt = true
                }
            } else {
                if let savedPassword = dependencyContainer.keychainService.getPassword(for: connection.id) {
                    await completeConnect(to: connection, in: position, password: savedPassword)
                } else if connection.authMethod == .privateKey {
                    await completeConnect(to: connection, in: position, password: "")
                } else {
                    pendingConnection = connection
                    pendingPanePosition = position
                    isShowingPasswordPrompt = true
                }
            }
        }
    }

    func connectWithPassword(_ password: String) {
        guard let conn = pendingConnection, let pos = pendingPanePosition else { return }
        isShowingPasswordPrompt = false
        pendingConnection = nil
        pendingPanePosition = nil

        Task {
            await completeConnect(to: conn, in: pos, password: password)
        }
    }

    func cancelPasswordPrompt() {
        isShowingPasswordPrompt = false
        pendingConnection = nil
        pendingPanePosition = nil
    }

    private func completeConnect(to connection: Connection, in position: PanePosition, password: String) async {
        let targetPane = pane(for: position)

        let browserVM: FileBrowserViewModel
        if connection.connectionType == .s3 {
            let s3Session = dependencyContainer.makeS3Session()
            browserVM = dependencyContainer.makeS3FileBrowserViewModel(
                connection: connection,
                s3Session: s3Session,
                secretAccessKey: password
            )
        } else {
            let sftpSession = dependencyContainer.makeSFTPSession()
            browserVM = dependencyContainer.makeFileBrowserViewModel(
                connection: connection,
                sftpSession: sftpSession,
                password: password
            )
        }

        targetPane.contentType = .remote(connection)
        targetPane.browserViewModel = browserVM

        await browserVM.connect()
    }

    // MARK: - Inter-Pane Transfers (Commander Actions)

    func transfer(files: [RemoteFile]? = nil, from sourcePos: PanePosition, to targetPos: PanePosition) {
        let source = pane(for: sourcePos)
        let target = pane(for: targetPos)

        guard let sourceVM = source.browserViewModel,
              let targetVM = target.browserViewModel else {
            logWarning("Cannot transfer: one or both panes are not in file browser mode", category: .ui)
            return
        }

        let filesToTransfer = files ?? sourceVM.selectedFilesList
        guard !filesToTransfer.isEmpty else {
            logInfo("No files selected for transfer", category: .ui)
            return
        }

        Task {
            await performTransfer(files: filesToTransfer, from: sourceVM, to: targetVM)
        }
    }

    private struct PendingCommanderTransfer: Sendable {
        let sourceFile: RemoteFile
        let displayName: String
        let targetPath: String
        let isTopLevel: Bool
    }

    private func collectRemoteItems(
        sourceDir: RemoteFile,
        relativePrefix: String,
        targetBaseDir: String,
        sourceRepo: FileRepositoryProtocol,
        directoriesToCreate: inout [String],
        filesToTransfer: inout [PendingCommanderTransfer]
    ) async throws {
        let entries = try await sourceRepo.listFiles(at: sourceDir.path)
        for entry in entries {
            try Task.checkCancellation()
            guard entry.name != "." && entry.name != ".." else { continue }
            let relPath = relativePrefix.isEmpty ? entry.name : "\(relativePrefix)/\(entry.name)"
            let targetPath = (targetBaseDir as NSString).appendingPathComponent(entry.name)
            if entry.isDirectory {
                directoriesToCreate.append(targetPath)
                try await collectRemoteItems(
                    sourceDir: entry,
                    relativePrefix: relPath,
                    targetBaseDir: targetPath,
                    sourceRepo: sourceRepo,
                    directoriesToCreate: &directoriesToCreate,
                    filesToTransfer: &filesToTransfer
                )
            } else {
                filesToTransfer.append(PendingCommanderTransfer(
                    sourceFile: entry,
                    displayName: relPath,
                    targetPath: targetPath,
                    isTopLevel: false
                ))
            }
        }
    }


    private func performTransfer(
        files: [RemoteFile],
        from sourceVM: FileBrowserViewModel,
        to targetVM: FileBrowserViewModel
    ) async {
        isShowingTransfersPopover = true
        self.isBatchCancelled = false

        var directoriesToCreate: [String] = []
        var itemsToTransfer: [PendingCommanderTransfer] = []
        var topLevelDirectoryNames: [String] = []

        for file in files {
            let destPath = (targetVM.currentPath as NSString).appendingPathComponent(file.name)
            if file.isDirectory {
                topLevelDirectoryNames.append(file.name)
                // 1. Create root folder
                try? await targetVM.fileRepository.createDirectory(at: destPath)
                let formattedPath = destPath.hasSuffix("/") ? destPath : destPath + "/"
                let destFolder = RemoteFile(
                    name: file.name,
                    path: formattedPath,
                    isDirectory: true,
                    size: 0,
                    permissions: file.permissions.hasPrefix("d") ? file.permissions : "drwxr-xr-x",
                    modificationDate: Date(),
                    owner: file.owner,
                    group: file.group
                )
                await MainActor.run {
                    targetVM.appendFile(destFolder)
                }

                // 2. Recursively gather all directories and files
                do {
                    try await collectRemoteItems(
                        sourceDir: file,
                        relativePrefix: file.name,
                        targetBaseDir: destPath,
                        sourceRepo: sourceVM.fileRepository,
                        directoriesToCreate: &directoriesToCreate,
                        filesToTransfer: &itemsToTransfer
                    )
                } catch {
                    logError("Failed to enumerate directory \(file.name): \(error)", category: .app)
                    self.error = AppError.from(error)
                    continue
                }
            } else {
                itemsToTransfer.append(PendingCommanderTransfer(
                    sourceFile: file,
                    displayName: file.name,
                    targetPath: destPath,
                    isTopLevel: true
                ))
            }
        }

        guard !itemsToTransfer.isEmpty else { return }

        let totalFilesCount = itemsToTransfer.count
        let totalBytesSum = itemsToTransfer.reduce(0) { $0 + $1.sourceFile.size }

        let batchId = UUID()
        if topLevelDirectoryNames.count > 0 || itemsToTransfer.count > 1 {
            let title = topLevelDirectoryNames.count == 1
                ? "Transferring \"\(topLevelDirectoryNames[0])\""
                : "Transferring \(totalFilesCount) files"
            self.activeBatch = BatchTransferProgress(
                id: batchId,
                title: title,
                totalFiles: totalFilesCount,
                totalBytes: totalBytesSum
            )
        }

        // Create all subdirectories (parallel per depth level)
        if !directoriesToCreate.isEmpty {
            let uniqueDirs = Array(NSOrderedSet(array: directoriesToCreate)) as? [String] ?? directoriesToCreate
            let sortedDirs = uniqueDirs.sorted { $0.components(separatedBy: "/").count < $1.components(separatedBy: "/").count }
            let dirsByDepth = Dictionary(grouping: sortedDirs) { $0.components(separatedBy: "/").count }
            let depths = dirsByDepth.keys.sorted()
            for depth in depths {
                if let dirsAtDepth = dirsByDepth[depth] {
                    await withTaskGroup(of: Void.self) { dirGroup in
                        for dir in dirsAtDepth {
                            dirGroup.addTask {
                                try? await targetVM.fileRepository.createDirectory(at: dir)
                            }
                        }
                    }
                }
            }
        }

        let tracker = BatchProgressTracker(
            batchId: batchId,
            totalFiles: itemsToTransfer.count,
            totalBytes: totalBytesSum,
            initialRecent: targetVM.recentTransfers
        )
        self.currentBatchTracker = tracker

        let maxConcurrent = TransferSettings.shared.maxConcurrentTransfers
        let sourceRepo = sourceVM.fileRepository
        let targetRepo = targetVM.fileRepository
        let isTargetLocal = targetVM.isLocal
        let isSourceLocal = sourceVM.isLocal

        let onUpdate: @Sendable (BatchProgressSnapshot) -> Void = { [weak self, weak targetVM] snapshot in
            Task { @MainActor [weak self, weak targetVM] in
                guard let self, let targetVM else { return }
                self.applyBatchSnapshot(snapshot, targetVM: targetVM)
            }
        }
        let onError: @Sendable (AppError) -> Void = { [weak self] appError in
            Task { @MainActor [weak self] in
                self?.error = appError
            }
        }

        await Self.processBatchTransfer(
            items: itemsToTransfer,
            maxConcurrent: maxConcurrent,
            sourceRepo: sourceRepo,
            targetRepo: targetRepo,
            isTargetLocal: isTargetLocal,
            isSourceLocal: isSourceLocal,
            tracker: tracker,
            onUpdate: onUpdate,
            onError: onError
        )

        let finalSnapshot = tracker.drainFinal(isCancelled: self.isBatchCancelled)
        self.applyBatchSnapshot(finalSnapshot, targetVM: targetVM)
        if var batch = self.activeBatch, batch.id == batchId, batch.isInProgress {
            batch.status = self.isBatchCancelled ? .cancelled : .completed
            self.activeBatch = batch
        }
        self.currentBatchTracker = nil
    }

    /// Applies an atomic throttled snapshot from BatchProgressTracker to target FileBrowserViewModel and activeBatch
    func applyBatchSnapshot(_ snapshot: BatchProgressSnapshot, targetVM: FileBrowserViewModel) {
        targetVM.applyBatchSnapshot(snapshot)
        guard let batch = self.activeBatch, batch.id == snapshot.batchId else { return }
        var updatedBatch = batch
        updatedBatch.completedFiles = snapshot.completedFiles
        updatedBatch.completedBytes = snapshot.completedBytes
        updatedBatch.transferredBytes = snapshot.transferredBytes
        if snapshot.isFinal {
            updatedBatch.status = self.isBatchCancelled ? .cancelled : .completed
        }
        self.activeBatch = updatedBatch
    }

    nonisolated private static func processBatchTransfer(
        items: [PendingCommanderTransfer],
        maxConcurrent: Int,
        sourceRepo: FileRepositoryProtocol,
        targetRepo: FileRepositoryProtocol,
        isTargetLocal: Bool,
        isSourceLocal: Bool,
        tracker: BatchProgressTracker,
        onUpdate: @escaping @Sendable (BatchProgressSnapshot) -> Void,
        onError: @escaping @Sendable (AppError) -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var fileIndex = 0
            let initialCount = min(maxConcurrent, items.count)
            while fileIndex < initialCount {
                let item = items[fileIndex]
                fileIndex += 1
                group.addTask {
                    await Self.transferSingleFile(
                        sourceFile: item.sourceFile,
                        displayName: item.displayName,
                        targetPath: item.targetPath,
                        isTopLevel: item.isTopLevel,
                        sourceRepo: sourceRepo,
                        targetRepo: targetRepo,
                        isTargetLocal: isTargetLocal,
                        isSourceLocal: isSourceLocal,
                        tracker: tracker,
                        onUpdate: onUpdate,
                        onError: onError
                    )
                }
            }

            for await _ in group {
                if Task.isCancelled || tracker.isBatchCancelled {
                    break
                }
                if fileIndex < items.count {
                    let item = items[fileIndex]
                    fileIndex += 1
                    group.addTask {
                        await Self.transferSingleFile(
                            sourceFile: item.sourceFile,
                            displayName: item.displayName,
                            targetPath: item.targetPath,
                            isTopLevel: item.isTopLevel,
                            sourceRepo: sourceRepo,
                            targetRepo: targetRepo,
                            isTargetLocal: isTargetLocal,
                            isSourceLocal: isSourceLocal,
                            tracker: tracker,
                            onUpdate: onUpdate,
                            onError: onError
                        )
                    }
                }
            }
        }
    }

    nonisolated private static func transferSingleFile(
        sourceFile: RemoteFile,
        displayName: String,
        targetPath: String,
        isTopLevel: Bool,
        sourceRepo: FileRepositoryProtocol,
        targetRepo: FileRepositoryProtocol,
        isTargetLocal: Bool,
        isSourceLocal: Bool,
        tracker: BatchProgressTracker,
        onUpdate: @escaping @Sendable (BatchProgressSnapshot) -> Void,
        onError: @escaping @Sendable (AppError) -> Void
    ) async {
        if Task.isCancelled { return }

        let transferId = UUID()
        let transfer = TransferProgress(
            id: transferId,
            fileName: displayName,
            localURL: isTargetLocal ? URL(fileURLWithPath: targetPath) : (isSourceLocal ? URL(fileURLWithPath: sourceFile.path) : nil),
            remotePath: targetPath,
            bytesTransferred: 0,
            totalBytes: sourceFile.size,
            transferType: isTargetLocal ? .download : .upload,
            status: .inProgress,
            isDirectory: false,
            itemCount: 1
        )

        // Register in tracker buffer immediately
        if let snapshot = tracker.registerActive(transfer: transfer) {
            onUpdate(snapshot)
        }

        do {
            try Task.checkCancellation()

            let reader = try await sourceRepo.openStreamReader(at: sourceFile.path)
            var closed = false
            defer {
                if !closed {
                    Task { await reader.close() }
                }
            }

            try await targetRepo.writeStream(
                from: reader,
                to: targetPath,
                totalSize: sourceFile.size,
                progress: { bytesTransferred in
                    if let snapshot = tracker.updateActiveBytes(id: transferId, bytes: bytesTransferred) {
                        onUpdate(snapshot)
                    }
                }
            )
            await reader.close()
            closed = true

            try Task.checkCancellation()

            var destFile: RemoteFile? = nil
            if isTopLevel {
                destFile = RemoteFile(
                    name: sourceFile.name,
                    path: targetPath,
                    isDirectory: false,
                    size: sourceFile.size,
                    permissions: sourceFile.permissions,
                    modificationDate: Date(),
                    owner: sourceFile.owner,
                    group: sourceFile.group
                )
            }

            if let snapshot = tracker.completeFile(id: transferId, totalBytes: sourceFile.size, topLevelFile: destFile) {
                onUpdate(snapshot)
            }

            logInfo("Transfer completed: \(displayName)", category: .app)
        } catch {
            let isCancelled = Task.isCancelled || error is CancellationError

            if let snapshot = tracker.failOrCancelFile(id: transferId, totalBytes: sourceFile.size, error: error, isCancelled: isCancelled) {
                onUpdate(snapshot)
            }

            if !isCancelled {
                onError(AppError.from(error))
            }
            logError("Transfer failed for \(displayName): \(error)", category: .app)
        }
    }

    /// Transfers selected files from active pane to inactive opposite pane
    func transferSelectedToOppositePane() {
        let targetPos: PanePosition = activePanePosition == .left ? .right : .left
        transfer(from: activePanePosition, to: targetPos)
    }

    // MARK: - Terminal Launcher

    func openTerminalForActivePane() {
        let active = activePane
        guard case .remote(let connection) = active.contentType,
              connection.connectionType == .sftp else {
            logWarning("Terminal is only available for active SFTP connections", category: .ui)
            return
        }

        openTerminal(for: connection, initialPath: active.browserViewModel?.currentPath)
    }

    func openTerminal(for connection: Connection, initialPath: String? = nil) {
        guard connection.connectionType == .sftp else {
            logWarning("Terminal is only available for SFTP connections", category: .ui)
            return
        }

        Task {
            let allowed = await AppLockManager.shared.authenticateForConnection()
            guard allowed else {
                logInfo("Terminal cancelled: biometric auth denied", category: .auth)
                return
            }

            _ = await TerminalLauncher.launchTerminal(
                host: connection.host,
                port: connection.port,
                username: connection.username,
                privateKeyPath: connection.privateKeyPath,
                initialPath: initialPath
            )
        }
    }

    // MARK: - Refresh

    func refreshActivePane() {
        let active = activePane
        if let browserVM = active.browserViewModel {
            Task { await browserVM.refresh() }
        } else {
            Task { await connectionListViewModel.loadData() }
        }
    }
}
