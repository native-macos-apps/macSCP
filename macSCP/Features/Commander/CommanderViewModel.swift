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

    var hasActiveTransfers: Bool {
        !allActiveTransfers.isEmpty
    }

    var activeTransferCount: Int {
        allActiveTransfers.count
    }

    var overallProgress: Double {
        let transfers = allActiveTransfers
        guard !transfers.isEmpty else { return 0 }
        let totalBytes = transfers.reduce(0) { $0 + $1.totalBytes }
        let transferredBytes = transfers.reduce(0) { $0 + $1.bytesTransferred }
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
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

    func transfer(from sourcePos: PanePosition, to targetPos: PanePosition) {
        let source = pane(for: sourcePos)
        let target = pane(for: targetPos)

        guard let sourceVM = source.browserViewModel,
              let targetVM = target.browserViewModel else {
            logWarning("Cannot transfer: one or both panes are not in file browser mode", category: .ui)
            return
        }

        let selected = sourceVM.selectedFilesList
        guard !selected.isEmpty else {
            logInfo("No files selected for transfer", category: .ui)
            return
        }

        Task {
            await performTransfer(files: selected, from: sourceVM, to: targetVM)
        }
    }

    private func performTransfer(
        files: [RemoteFile],
        from sourceVM: FileBrowserViewModel,
        to targetVM: FileBrowserViewModel
    ) async {
        let isSourceLocal = sourceVM.isLocal
        let isTargetLocal = targetVM.isLocal

        if isSourceLocal && !isTargetLocal {
            // Local -> Remote (Upload)
            let urls = files.map { URL(fileURLWithPath: $0.path) }
            await targetVM.uploadDroppedFiles(urls)
            await targetVM.refresh()
        } else if !isSourceLocal && isTargetLocal {
            // Remote -> Local (Download)
            let targetDirURL = URL(fileURLWithPath: targetVM.currentPath)
            for file in files {
                let destURL = targetDirURL.appendingPathComponent(file.name)
                try? await sourceVM.downloadFileToURL(file, destinationURL: destURL)
            }
            await targetVM.refresh()
        } else if isSourceLocal && isTargetLocal {
            // Local -> Local (Copy)
            let targetDir = targetVM.currentPath
            let fm = FileManager.default
            for file in files {
                let destPath = (targetDir as NSString).appendingPathComponent(file.name)
                try? fm.copyItem(atPath: file.path, toPath: destPath)
            }
            await targetVM.refresh()
        } else {
            // Remote -> Remote (Download to temp then upload to target)
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            var downloadedURLs: [URL] = []

            for file in files {
                let localDest = tempDir.appendingPathComponent(file.name)
                try? await sourceVM.downloadFileToURL(file, destinationURL: localDest)
                if FileManager.default.fileExists(atPath: localDest.path) {
                    downloadedURLs.append(localDest)
                }
            }

            if !downloadedURLs.isEmpty {
                await targetVM.uploadDroppedFiles(downloadedURLs)
                await targetVM.refresh()
            }

            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Terminal Launcher

    func openTerminalForActivePane() {
        let active = activePane
        guard case .remote(let connection) = active.contentType,
              connection.connectionType == .sftp else {
            logWarning("Terminal is only available for active SFTP connections", category: .ui)
            return
        }

        Task {
            let initialPath = active.browserViewModel?.currentPath
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
