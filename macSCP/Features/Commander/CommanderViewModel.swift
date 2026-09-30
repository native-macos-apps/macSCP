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
            return max(1, allActiveTransfers.count)
        }
        return allActiveTransfers.count
    }

    var activeTransferBadgeText: String {
        let count = activeTransferCount
        if count > 99 {
            return "99+"
        }
        return "\(count)"
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

    // MARK: - Batch Transfer Handling

    private var isBatchInProgress = false
    private(set) var lastFailedCommanderItems: [TransferQueueItem] = []
    private weak var lastSourceVM: FileBrowserViewModel?
    private weak var lastTargetVM: FileBrowserViewModel?

    /// Retries failed transfers from the previous commander batch
    func retryFailedTransfers() async {
        guard !lastFailedCommanderItems.isEmpty, !isBatchInProgress,
              let sourceVM = lastSourceVM, let targetVM = lastTargetVM else { return }
        let itemsToRetry = lastFailedCommanderItems
        await executeCommanderBatch(
            items: itemsToRetry,
            directoriesToCreate: [],
            topLevelNames: [],
            sourceVM: sourceVM,
            targetVM: targetVM
        )
    }

    private func performTransfer(
        files: [RemoteFile],
        from sourceVM: FileBrowserViewModel,
        to targetVM: FileBrowserViewModel
    ) async {
        guard !isBatchInProgress else {
            logInfo("Commander batch already in progress, skipping concurrent request", category: .app)
            return
        }
        isBatchInProgress = true
        defer { isBatchInProgress = false }

        self.lastSourceVM = sourceVM
        self.lastTargetVM = targetVM
        self.isShowingTransfersPopover = true
        self.isBatchCancelled = false

        let targetBasePath = targetVM.currentPath
        let sourceRepo = sourceVM.fileRepository

        var directoriesToCreate: [String] = []
        var itemsToTransfer: [TransferQueueItem] = []
        var topLevelDirectoryNames: [String] = []

        // Stream remote file enumeration with bounded memory
        let stream = StreamingFileScanner.streamRemoteFiles(
            files,
            targetBasePath: targetBasePath,
            sourceRepo: sourceRepo,
            bufferSize: 100
        )

        for await event in stream {
            if Task.isCancelled || isBatchCancelled { break }
            switch event {
            case .topLevelFolder(let folder):
                topLevelDirectoryNames.append(folder.name)
                targetVM.appendFile(folder)
            case .directory(let remotePath):
                directoriesToCreate.append(remotePath)
            case .file(let item):
                itemsToTransfer.append(item)
            case .finished:
                break
            }
        }

        guard !itemsToTransfer.isEmpty else {
            if !directoriesToCreate.isEmpty {
                let dirMgr = RemoteDirectoryManager(repository: targetVM.fileRepository, maxConcurrency: 3)
                _ = await dirMgr.createDirectories(directoriesToCreate)
            }
            return
        }

        await executeCommanderBatch(
            items: itemsToTransfer,
            directoriesToCreate: directoriesToCreate,
            topLevelNames: topLevelDirectoryNames,
            sourceVM: sourceVM,
            targetVM: targetVM
        )
    }

    private func executeCommanderBatch(
        items: [TransferQueueItem],
        directoriesToCreate: [String],
        topLevelNames: [String] = [],
        sourceVM: FileBrowserViewModel,
        targetVM: FileBrowserViewModel
    ) async {
        let totalFilesCount = items.count
        let totalBytesSum = items.reduce(0) { $0 + $1.fileSize }
        let batchId = UUID()
        let initialRecent = targetVM.recentTransfers

        let title: String
        if !topLevelNames.isEmpty {
            title = topLevelNames.count == 1
                ? "Transferring \"\(topLevelNames[0])\""
                : "Transferring \(totalFilesCount) files"
        } else {
            title = "Transferring \(totalFilesCount) files"
        }

        self.activeBatch = BatchTransferProgress(
            id: batchId,
            title: title,
            totalFiles: totalFilesCount,
            totalBytes: totalBytesSum,
            status: .inProgress
        )

        let tracker = BatchProgressTracker(
            batchId: batchId,
            totalFiles: totalFilesCount,
            totalBytes: totalBytesSum,
            initialRecent: initialRecent
        )
        self.currentBatchTracker = tracker

        let maxConcurrent = TransferSettings.shared.maxConcurrentTransfers
        let sourceRepo = sourceVM.fileRepository
        let targetRepo = targetVM.fileRepository

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

        let result = await BatchTransferCoordinator.shared.executeBatch(
            items: items,
            directoriesToCreate: directoriesToCreate,
            repository: targetRepo,
            maxConcurrent: maxConcurrent,
            retryPolicy: .default,
            tracker: tracker,
            executor: { item, progress in
                let sourcePath = item.sourceRemoteFile?.path ?? item.remotePath
                let reader = try await sourceRepo.openStreamReader(at: sourcePath)
                var closed = false
                defer {
                    if !closed {
                        Task { await reader.close() }
                    }
                }

                try await targetRepo.writeStream(
                    from: reader,
                    to: item.remotePath,
                    totalSize: item.fileSize,
                    progress: progress
                )
                await reader.close()
                closed = true

                var destFile: RemoteFile? = nil
                if item.isTopLevel, let src = item.sourceRemoteFile {
                    destFile = RemoteFile(
                        name: src.name,
                        path: item.remotePath,
                        isDirectory: false,
                        size: src.size,
                        permissions: src.permissions,
                        modificationDate: Date(),
                        owner: src.owner,
                        group: src.group
                    )
                }
                return destFile
            },
            onUpdate: onUpdate,
            onError: onError
        )

        self.lastFailedCommanderItems = result.failedItems
        self.currentBatchTracker = nil

        AnalyticsService.trackBatchTransferred(
            protocol: .init(from: targetVM.connection.connectionType),
            fileCount: result.completedFiles,
            totalBytes: result.completedBytes,
            isUpload: !targetVM.isLocal
        )

        if result.completedFiles > 0 {
            await targetVM.loadFiles()
        }
    }

    /// Applies an atomic throttled snapshot from BatchProgressTracker to target FileBrowserViewModel and activeBatch
    func applyBatchSnapshot(_ snapshot: BatchProgressSnapshot, targetVM: FileBrowserViewModel) {
        targetVM.applyBatchSnapshot(snapshot)
        guard let batch = self.activeBatch, batch.id == snapshot.batchId else { return }
        var updatedBatch = batch
        updatedBatch.completedFiles = snapshot.completedFiles
        updatedBatch.failedFiles = snapshot.failedFiles
        updatedBatch.cancelledFiles = snapshot.cancelledFiles
        updatedBatch.queuedFiles = snapshot.queuedFiles
        updatedBatch.completedBytes = snapshot.completedBytes
        updatedBatch.transferredBytes = snapshot.transferredBytes
        updatedBatch.failedTransfers = snapshot.failedTransfers
        updatedBatch.directoryErrors = snapshot.directoryErrors
        if snapshot.isFinal {
            if self.isBatchCancelled || (snapshot.cancelledFiles > 0 && snapshot.completedFiles == 0 && snapshot.failedFiles == 0) {
                updatedBatch.status = .cancelled
            } else if snapshot.failedFiles > 0 || !snapshot.failedTransfers.isEmpty || !snapshot.directoryErrors.isEmpty {
                updatedBatch.status = .failed
            } else {
                updatedBatch.status = .completed
            }
        }
        self.activeBatch = updatedBatch
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
