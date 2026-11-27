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
    var isShowingTransfersPopover: Bool {
        get { transferManager.isShowingTransfersPopover }
        set { transferManager.isShowingTransfersPopover = newValue }
    }
    var activeBatch: BatchTransferProgress? {
        get { transferManager.activeBatch }
        set { transferManager.activeBatch = newValue }
    }
    var pendingConnection: Connection?
    var pendingPanePosition: PanePosition?
    private var pendingTerminalInitialPath: String?
    private var isPasswordPromptForTerminal: Bool = false

    // Window opening state
    var pendingTerminalWindowId: String?

    var error: AppError?

    // MARK: - Dependencies
    private let dependencyContainer: DependencyContainer
    private let transferManager: FileTransferManager
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
        transferManager.cancelBatch()
        leftPane.browserViewModel?.cancelBatch()
        rightPane.browserViewModel?.cancelBatch()
    }

    func clearCompletedTransfers() {
        transferManager.clearCompletedTransfers()
        leftPane.browserViewModel?.clearCompletedTransfers()
        rightPane.browserViewModel?.clearCompletedTransfers()
    }

    func removeTransfer(_ transfer: TransferProgress) {
        transferManager.removeTransfer(transfer)
        leftPane.browserViewModel?.removeTransfer(transfer)
        rightPane.browserViewModel?.removeTransfer(transfer)
    }

    // MARK: - Initialization

    init(container: DependencyContainer) {
        self.dependencyContainer = container
        self.transferManager = FileTransferManager(
            coordinator: container.batchTransferCoordinator,
            transferSettings: container.transferSettings
        )
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
        let previousRemoteVM = detachRemoteViewModel(from: targetPane)

        let localVM = dependencyContainer.makeLocalFileBrowserViewModel(initialPath: initialPath)
        targetPane.contentType = .local
        targetPane.browserViewModel = localVM

        if let previousRemoteVM {
            Task {
                await previousRemoteVM.disconnect()
            }
        }

        Task {
            await localVM.connect()
        }
    }

    func switchToServers(in position: PanePosition) {
        let targetPane = pane(for: position)
        let previousRemoteVM = detachRemoteViewModel(from: targetPane)

        targetPane.contentType = .servers
        targetPane.browserViewModel = nil

        if let previousRemoteVM {
            Task {
                await previousRemoteVM.disconnect()
            }
        }

        Task {
            await connectionListViewModel.loadData()
        }
    }

    func disconnect(in position: PanePosition) {
        let targetPane = pane(for: position)
        let previousVM = targetPane.browserViewModel

        targetPane.contentType = .servers
        targetPane.browserViewModel = nil

        if let previousVM {
            Task {
                await previousVM.disconnect()
            }
        }
    }

    private func detachRemoteViewModel(from pane: CommanderPaneState) -> FileBrowserViewModel? {
        guard case .remote = pane.contentType else { return nil }
        return pane.browserViewModel
    }

    // MARK: - Connection

    func connect(to connection: Connection, in position: PanePosition) {
        Task { @MainActor in
            let allowed = await dependencyContainer.appLockManager.authenticateForConnection()
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
        guard let conn = pendingConnection else { return }
        let forTerminal = isPasswordPromptForTerminal
        let initialPath = pendingTerminalInitialPath
        let pos = pendingPanePosition

        isShowingPasswordPrompt = false
        pendingConnection = nil
        pendingPanePosition = nil
        pendingTerminalInitialPath = nil
        isPasswordPromptForTerminal = false

        if forTerminal {
            presentTerminalWindow(for: conn, password: password, initialPath: initialPath)
        } else if let pos = pos {
            Task {
                await completeConnect(to: conn, in: pos, password: password)
            }
        }
    }

    func cancelPasswordPrompt() {
        isShowingPasswordPrompt = false
        pendingConnection = nil
        pendingPanePosition = nil
        pendingTerminalInitialPath = nil
        isPasswordPromptForTerminal = false
    }

    private func completeConnect(to connection: Connection, in position: PanePosition, password: String) async {
        let targetPane = pane(for: position)
        let previousRemoteVM = detachRemoteViewModel(from: targetPane)

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

        if let previousRemoteVM {
            Task {
                await previousRemoteVM.disconnect()
            }
        }

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

    var lastFailedCommanderItems: [TransferQueueItem] { transferManager.lastFailedItems }
    private weak var lastSourceVM: FileBrowserViewModel?
    private weak var lastTargetVM: FileBrowserViewModel?

    /// Retries failed transfers from the previous commander batch
    func retryFailedTransfers() async {
        guard !lastFailedCommanderItems.isEmpty, !transferManager.isBatchInProgress,
              let sourceVM = lastSourceVM, let targetVM = lastTargetVM else { return }
        let itemsToRetry = lastFailedCommanderItems
        guard transferManager.beginBatchSession() else { return }
        defer { transferManager.endBatchSession() }
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
        guard transferManager.beginBatchSession() else {
            logWarning("Commander batch already in progress, ignoring concurrent request", category: .app)
            self.error = .uploadFailed("A transfer batch is already in progress. Please wait for it to finish or cancel it first.")
            return
        }
        defer { transferManager.endBatchSession() }

        self.lastSourceVM = sourceVM
        self.lastTargetVM = targetVM

        let targetBasePath = targetVM.currentPath
        let sourceRepo = sourceVM.fileRepository

        do {
            let scan = try await transferManager.prepareScan {
                try await StreamingFileScanner.scanRemoteFiles(
                    files, targetBasePath: targetBasePath, sourceRepo: sourceRepo
                )
            }
            guard !scan.items.isEmpty || !scan.directoriesToCreate.isEmpty else { return }
            await executeCommanderBatch(
                items: scan.items,
                directoriesToCreate: scan.directoriesToCreate,
                topLevelNames: scan.topLevelDirectoryNames,
                sourceVM: sourceVM,
                targetVM: targetVM
            )
        } catch is CancellationError {
            return
        } catch {
            self.error = AppError.from(error)
        }
    }

    private func executeCommanderBatch(
        items: [TransferQueueItem],
        directoriesToCreate: [String],
        topLevelNames: [String] = [],
        sourceVM: FileBrowserViewModel,
        targetVM: FileBrowserViewModel
    ) async {
        let title: String
        if topLevelNames.count == 1 {
            title = "Transferring \"\(topLevelNames[0])\""
        } else {
            title = "Transferring \(items.count) files"
        }

        let sourceRepo = sourceVM.fileRepository
        let targetRepo = targetVM.fileRepository
        let transferType: TransferType = targetVM.isLocal ? .download : .upload

        let result = await transferManager.executeBatch(
            title: title,
            items: items,
            directoriesToCreate: directoriesToCreate,
            repository: targetRepo,
            transferType: transferType,
            initialRecent: targetVM.recentTransfers,
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

                guard item.isTopLevel, let src = item.sourceRemoteFile else { return nil }
                return RemoteFile(
                    name: src.name,
                    path: item.remotePath,
                    isDirectory: false,
                    size: src.size,
                    permissions: src.permissions,
                    modificationDate: Date(),
                    owner: src.owner,
                    group: src.group
                )
            },
            onSnapshot: { [weak self, weak targetVM] snapshot in
                guard let self, let targetVM else { return }
                self.applyBatchSnapshot(snapshot, targetVM: targetVM)
            },
            onError: { [weak self] appError in
                self?.error = appError
            }
        )

        AnalyticsService.trackBatchTransferred(
            protocol: .init(from: targetVM.connection.connectionType),
            fileCount: result.completedFiles,
            totalBytes: result.completedBytes,
            isUpload: !targetVM.isLocal
        )

        if result.completedFiles > 0 || !directoriesToCreate.isEmpty {
            await targetVM.loadFiles()
        }
    }

    /// Applies an atomic throttled snapshot from BatchProgressTracker to target FileBrowserViewModel and activeBatch
    func applyBatchSnapshot(_ snapshot: BatchProgressSnapshot, targetVM: FileBrowserViewModel) {
        targetVM.applyBatchSnapshot(snapshot)
        transferManager.applyBatchSnapshot(snapshot, updateTransferLists: false)
    }

    /// Transfers selected files from active pane to inactive opposite pane
    func transferSelectedToOppositePane() {
        let targetPos: PanePosition = activePanePosition == .left ? .right : .left
        transfer(from: activePanePosition, to: targetPos)
    }

    // MARK: - Integrated SSH Terminal

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

        Task { @MainActor in
            let allowed = await dependencyContainer.appLockManager.authenticateForConnection()
            guard allowed else {
                logInfo("Terminal cancelled: biometric auth denied", category: .auth)
                return
            }

            if let savedPassword = dependencyContainer.keychainService.getPassword(for: connection.id) {
                presentTerminalWindow(for: connection, password: savedPassword, initialPath: initialPath)
            } else if connection.authMethod == .privateKey {
                presentTerminalWindow(for: connection, password: "", initialPath: initialPath)
            } else {
                pendingConnection = connection
                pendingPanePosition = nil
                pendingTerminalInitialPath = initialPath
                isPasswordPromptForTerminal = true
                isShowingPasswordPrompt = true
            }
        }
    }

    func clearPendingTerminalWindow() {
        pendingTerminalWindowId = nil
    }

    private func presentTerminalWindow(for connection: Connection, password: String, initialPath: String?) {
        let data = TerminalWindowData(
            connectionId: connection.id,
            connectionName: connection.name,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password,
            authMethod: connection.authMethod,
            sshKeyId: connection.sshKeyId,
            initialPath: initialPath
        )
        let windowId = dependencyContainer.windowManager.storeTerminalData(data)
        logInfo("Stored terminal window data with ID: \(windowId)", category: .ui)
        pendingTerminalWindowId = windowId
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
