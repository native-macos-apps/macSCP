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
        leftPane.browserViewModel?.cancelBatch()
        rightPane.browserViewModel?.cancelBatch()
    }

    func clearCompletedTransfers() {
        if activeBatch?.status == .completed || activeBatch?.status == .cancelled || activeBatch?.status == .failed {
            activeBatch = nil
        }
        leftPane.browserViewModel?.clearCompletedTransfers()
        rightPane.browserViewModel?.clearCompletedTransfers()
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

    private struct PendingCommanderTransfer {
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

    private func updateBatchTransferredBytes(targetVM: FileBrowserViewModel) {
        guard var batch = activeBatch else { return }
        let activeBytes = targetVM.activeTransfers.values.reduce(0) { $0 + $1.bytesTransferred }
        batch.transferredBytes = min(batch.totalBytes, batch.completedBytes + activeBytes)
        self.activeBatch = batch
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

        // Create all subdirectories (depth first / length sorted)
        directoriesToCreate.sort { $0.count < $1.count }
        for dir in directoriesToCreate {
            try? await targetVM.fileRepository.createDirectory(at: dir)
        }

        guard !itemsToTransfer.isEmpty else { return }

        let totalFilesCount = itemsToTransfer.count
        let totalBytesSum = itemsToTransfer.reduce(0) { $0 + $1.sourceFile.size }

        if topLevelDirectoryNames.count > 0 || itemsToTransfer.count > 1 {
            let title = topLevelDirectoryNames.count == 1
                ? "Transferring \"\(topLevelDirectoryNames[0])\""
                : "Transferring \(totalFilesCount) files"
            self.activeBatch = BatchTransferProgress(
                title: title,
                totalFiles: totalFilesCount,
                totalBytes: totalBytesSum
            )
        }

        let maxConcurrent = TransferSettings.shared.maxConcurrentTransfers

        await withTaskGroup(of: Void.self) { group in
            var fileIndex = 0
            let initialCount = min(maxConcurrent, itemsToTransfer.count)
            while fileIndex < initialCount {
                let item = itemsToTransfer[fileIndex]
                fileIndex += 1
                group.addTask { [weak self] in
                    await self?.transferSingleFile(
                        sourceFile: item.sourceFile,
                        displayName: item.displayName,
                        targetPath: item.targetPath,
                        isTopLevel: item.isTopLevel,
                        from: sourceVM,
                        to: targetVM
                    )
                }
            }

            for await _ in group {
                if Task.isCancelled || self.isBatchCancelled {
                    break
                }
                if fileIndex < itemsToTransfer.count {
                    let item = itemsToTransfer[fileIndex]
                    fileIndex += 1
                    group.addTask { [weak self] in
                        await self?.transferSingleFile(
                            sourceFile: item.sourceFile,
                            displayName: item.displayName,
                            targetPath: item.targetPath,
                            isTopLevel: item.isTopLevel,
                            from: sourceVM,
                            to: targetVM
                        )
                    }
                }
            }
        }

        if var batch = self.activeBatch, batch.isInProgress {
            batch.status = self.isBatchCancelled ? .cancelled : .completed
            if !self.isBatchCancelled {
                batch.completedFiles = batch.totalFiles
                batch.transferredBytes = batch.totalBytes
            }
            self.activeBatch = batch
        }
    }

    private func transferSingleFile(
        sourceFile: RemoteFile,
        displayName: String,
        targetPath: String,
        isTopLevel: Bool,
        from sourceVM: FileBrowserViewModel,
        to targetVM: FileBrowserViewModel
    ) async {
        if isBatchCancelled || Task.isCancelled { return }

        let transferId = UUID()
        let transfer = TransferProgress(
            id: transferId,
            fileName: displayName,
            localURL: targetVM.isLocal ? URL(fileURLWithPath: targetPath) : (sourceVM.isLocal ? URL(fileURLWithPath: sourceFile.path) : nil),
            remotePath: targetPath,
            bytesTransferred: 0,
            totalBytes: sourceFile.size,
            transferType: targetVM.isLocal ? .download : .upload,
            status: .inProgress,
            isDirectory: false,
            itemCount: 1
        )

        var lastProgressUpdateTime: CFAbsoluteTime = 0

        let transferTask = Task {
            do {
                try Task.checkCancellation()

                let reader = try await sourceVM.fileRepository.openStreamReader(at: sourceFile.path)
                var closed = false
                defer {
                    if !closed {
                        Task { await reader.close() }
                    }
                }

                try await targetVM.fileRepository.writeStream(
                    from: reader,
                    to: targetPath,
                    totalSize: sourceFile.size,
                    progress: { [weak self] bytesTransferred in
                        let now = CFAbsoluteTimeGetCurrent()
                        let isCompleted = bytesTransferred >= sourceFile.size
                        // Throttle progress updates to MainActor: at most once every 70ms, or when completed
                        if isCompleted || (now - lastProgressUpdateTime) >= 0.07 {
                            lastProgressUpdateTime = now
                            Task { @MainActor in
                                targetVM.updateTransferProgress(id: transferId, bytesTransferred: bytesTransferred)
                                self?.updateBatchTransferredBytes(targetVM: targetVM)
                            }
                        }
                    }
                )
                await reader.close()
                closed = true

                try Task.checkCancellation()

                await MainActor.run {
                    targetVM.completeTransfer(id: transferId, totalBytes: sourceFile.size)
                    self.activeBatch?.completedFiles += 1
                    self.activeBatch?.completedBytes += sourceFile.size
                    self.updateBatchTransferredBytes(targetVM: targetVM)
                }

                if isTopLevel {
                    var destFile: RemoteFile
                    if let fetched = try? await targetVM.fileRepository.getFileInfo(at: targetPath) {
                        destFile = fetched
                    } else {
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
                    await MainActor.run {
                        targetVM.appendFile(destFile)
                    }
                }

                logInfo("Transfer completed: \(displayName)", category: .app)
            } catch {
                let isCancelled = Task.isCancelled || error is CancellationError
                await MainActor.run {
                    targetVM.failTransfer(id: transferId, error: error, isCancelled: isCancelled)
                    self.activeBatch?.completedFiles += 1
                    self.activeBatch?.completedBytes += sourceFile.size
                    self.updateBatchTransferredBytes(targetVM: targetVM)
                    if !isCancelled {
                        self.error = AppError.from(error)
                    }
                }
                logError("Transfer failed for \(displayName): \(error)", category: .app)
            }
        }

        await MainActor.run {
            targetVM.trackTransfer(transfer, task: transferTask)
        }

        _ = await transferTask.result
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
