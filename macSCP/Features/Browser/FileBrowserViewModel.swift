//
//  FileBrowserViewModel.swift
//  macSCP
//
//  ViewModel for the file browser feature
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class FileBrowserViewModel {
    // MARK: - Published State
    private(set) var files: [RemoteFile] = []
    private(set) var state: ViewState<Void> = .idle
    private(set) var currentPath: String = "/"
    private(set) var isConnected: Bool = false
    var error: AppError?

    // MARK: - Composed Controllers
    let transferManager: FileTransferManager
    let quickLookController: BrowserQuickLookController

    // MARK: - Transfer Progress Facade
    var activeTransfers: [UUID: TransferProgress] { transferManager.activeTransfers }
    var recentTransfers: [TransferProgress] { transferManager.recentTransfers }
    var lastFailedUploadItems: [TransferQueueItem] { transferManager.lastFailedItems }

    var isShowingTransfersPopover: Bool {
        get { transferManager.isShowingTransfersPopover }
        set { transferManager.isShowingTransfersPopover = newValue }
    }

    var activeBatch: BatchTransferProgress? {
        get { transferManager.activeBatch }
        set { transferManager.activeBatch = newValue }
    }

    var hasActiveTransfers: Bool { transferManager.hasActiveTransfers }
    var activeTransferCount: Int { transferManager.activeTransferCount }
    var activeTransferBadgeText: String { transferManager.activeTransferBadgeText }
    var allTransfers: [TransferProgress] { transferManager.allTransfers }
    var overallProgress: Double { transferManager.overallProgress }

    // MARK: - Selection & Sorting State
    var selectedFiles: Set<UUID> = []
    var primarySelectedFile: RemoteFile? {
        didSet {
            quickLookController.handlePrimarySelectionChanged(primarySelectedFile)
        }
    }
    var sortCriteria: RemoteFile.SortCriteria = .name
    var sortAscending: Bool = true
    var showHiddenFiles: Bool = false

    // MARK: - Quick Look Facade
    var isShowingQuickLook: Bool {
        get { quickLookController.isShowingQuickLook }
        set { quickLookController.isShowingQuickLook = newValue }
    }
    var quickLookFile: RemoteFile? {
        get { quickLookController.quickLookFile }
        set { quickLookController.quickLookFile = newValue }
    }
    var quickLookContent: QuickLookContent { quickLookController.quickLookContent }

    // MARK: - Sheet States
    var isShowingNewFolderSheet = false
    var isShowingNewFileSheet = false
    var isShowingRenameSheet = false
    var isShowingDeleteConfirmation = false

    var fileToRename: RemoteFile?
    var filesToDelete: [RemoteFile] = []

    // MARK: - Window Opening State
    var pendingFileInfoWindowId: String?
    var pendingEditorWindowId: String?

    // MARK: - Connection Info
    let connection: Connection
    private let password: String

    // MARK: - Dependencies
    private let session: BrowserSessionProtocol
    let fileRepository: FileRepositoryProtocol
    private let clipboardService: ClipboardService
    private let windowManager: WindowManager
    private let navigationService = NavigationService()

    // MARK: - Computed Properties

    var isLocal: Bool {
        session.isLocal
    }

    // MARK: - Initialization (SFTP)
    init(
        connection: Connection,
        sftpSession: SFTPSessionProtocol,
        fileRepository: FileRepositoryProtocol,
        clipboardService: ClipboardService,
        password: String,
        sshKeyRepository: SSHKeyRepositoryProtocol = SSHKeyStorageService.shared,
        windowManager: WindowManager = .shared,
        transferSettings: TransferSettings = .shared,
        batchTransferCoordinator: BatchTransferCoordinator = .shared
    ) {
        self.connection = connection
        self.password = password
        self.session = SFTPBrowserSession(
            connection: connection,
            password: password,
            session: sftpSession,
            sshKeyRepository: sshKeyRepository
        )
        self.fileRepository = fileRepository
        self.clipboardService = clipboardService
        self.windowManager = windowManager
        self.transferManager = FileTransferManager(
            coordinator: batchTransferCoordinator,
            transferSettings: transferSettings
        )
        self.quickLookController = BrowserQuickLookController(fileRepository: fileRepository)
    }

    // MARK: - Initialization (S3)
    init(
        connection: Connection,
        s3Session: S3SessionProtocol,
        fileRepository: FileRepositoryProtocol,
        clipboardService: ClipboardService,
        secretAccessKey: String,
        windowManager: WindowManager = .shared,
        transferSettings: TransferSettings = .shared,
        batchTransferCoordinator: BatchTransferCoordinator = .shared
    ) {
        self.connection = connection
        self.password = secretAccessKey
        self.session = S3BrowserSession(
            connection: connection,
            secretAccessKey: secretAccessKey,
            session: s3Session
        )
        self.fileRepository = fileRepository
        self.clipboardService = clipboardService
        self.windowManager = windowManager
        self.transferManager = FileTransferManager(
            coordinator: batchTransferCoordinator,
            transferSettings: transferSettings
        )
        self.quickLookController = BrowserQuickLookController(fileRepository: fileRepository)
    }

    // MARK: - Initialization (Local)
    init(
        localRepository: FileRepositoryProtocol,
        clipboardService: ClipboardService,
        initialPath: String? = nil,
        windowManager: WindowManager = .shared,
        transferSettings: TransferSettings = .shared,
        batchTransferCoordinator: BatchTransferCoordinator = .shared
    ) {
        let startingPath = initialPath ?? LocalFileRepository.userHomeDirectory
        self.connection = Connection(
            id: UUID(),
            name: "Mac",
            host: "localhost",
            username: NSUserName(),
            connectionType: .local
        )
        self.password = ""
        self.session = LocalBrowserSession()
        self.fileRepository = localRepository
        self.clipboardService = clipboardService
        self.windowManager = windowManager
        self.transferManager = FileTransferManager(
            coordinator: batchTransferCoordinator,
            transferSettings: transferSettings
        )
        self.quickLookController = BrowserQuickLookController(fileRepository: localRepository)
        self.currentPath = startingPath
    }

    // MARK: - Computed Properties

    var sortedFiles: [RemoteFile] {
        var result = files
        if !showHiddenFiles {
            result = result.filter { !$0.isHidden }
        }
        return RemoteFile.sortedFiles(result, by: sortCriteria, ascending: sortAscending)
    }

    var selectedFilesList: [RemoteFile] {
        files.filter { selectedFiles.contains($0.id) }
    }

    var canGoBack: Bool { navigationService.canGoBack }
    var canGoForward: Bool { navigationService.canGoForward }
    var canGoUp: Bool { currentPath != "/" }

    var pathComponents: [PathComponent] {
        var components: [PathComponent] = []
        var currentAccumulatedPath = "/"

        let targetPath = primarySelectedFile?.path ?? currentPath
        let parts = targetPath.split(separator: "/", omittingEmptySubsequences: true)

        for (index, component) in parts.enumerated() {
            let componentString = String(component)
            currentAccumulatedPath = currentAccumulatedPath.appendingPathComponent(componentString)

            let isLast = index == parts.count - 1
            let isSelectedFile = isLast && primarySelectedFile != nil && !(primarySelectedFile?.isDirectory ?? true)

            let path: String
            if isSelectedFile {
                path = currentAccumulatedPath
            } else {
                path = currentAccumulatedPath.hasSuffix("/") ? currentAccumulatedPath : currentAccumulatedPath + "/"
            }
            components.append(PathComponent(name: componentString, path: path))
        }

        return components
    }

    var clipboardDisplayText: String { clipboardService.displayText }
    var hasClipboardItems: Bool { !clipboardService.isEmpty }
    var canPaste: Bool { clipboardService.canPaste(to: connection.id) }

    // MARK: - Connection

    func connect() async {
        state = .loading

        do {
            currentPath = try await session.connect(initialPath: currentPath)
            isConnected = true
            navigationService.reset(to: currentPath)
            AnalyticsService.trackFileBrowserOpened(protocol: .init(from: connection.connectionType))
            await loadFiles()
        } catch {
            logError("Connection failed: \(error)", category: session.logCategory)
            state = .error(AppError.from(error))
        }
    }

    func disconnect() async {
        await session.disconnect()
        quickLookController.reset()
        isConnected = false
        files = []
        if !isLocal {
            currentPath = "/"
        }
        navigationService.reset()
    }

    // MARK: - Navigation

    func loadFiles(showLoading: Bool = false) async {
        if showLoading || files.isEmpty {
            state = .loading
        }

        do {
            files = try await fileRepository.listFiles(at: currentPath)
            if !isLocal {
                currentPath = await session.resolveCurrentPath(afterListing: currentPath, fallback: "/")
            }
            state = .success(())
        } catch {
            logError("Failed to load files: \(error)", category: session.logCategory)
            state = .error(AppError.from(error))
        }
    }

    /// Fetches the contents of a folder at `path` without changing navigation state.
    func listChildFiles(at path: String) async throws -> [RemoteFile] {
        try await fileRepository.listFiles(at: path)
    }

    func navigateTo(_ path: String, addToHistory: Bool = true) async {
        state = .loading

        do {
            logInfo("Navigating to: \(path) (history: \(addToHistory))", category: .ui)

            let newFiles = try await fileRepository.listFiles(at: path)
            let newPath = await session.resolveCurrentPath(afterListing: path, fallback: "/")

            self.files = newFiles
            self.currentPath = newPath

            if addToHistory {
                navigationService.navigate(to: newPath)
            }

            self.selectedFiles.removeAll()
            self.state = .success(())

            logInfo("Successfully navigated to: \(newPath)", category: .ui)
        } catch {
            logError("Failed to navigate to \(path): \(error)", category: session.logCategory)
            state = .error(AppError.from(error))
        }
    }

    func openFile(_ file: RemoteFile) async {
        if file.isDirectory {
            await navigateTo(file.path)
        } else if FileTypeService.isPreviewable(file) {
            // Open in editor - handled by view
        }
    }

    func goBack() async {
        if let path = navigationService.goBack() {
            await navigateTo(path, addToHistory: false)
        }
    }

    func goForward() async {
        if let path = navigationService.goForward() {
            await navigateTo(path, addToHistory: false)
        }
    }

    func goUp() async {
        await navigateTo(currentPath.parentPath)
    }

    func goHome() async {
        await navigateTo(session.homePath())
    }

    func refresh() async {
        await loadFiles(showLoading: false)
    }

    // MARK: - File Operations

    func createFolder(name: String) async {
        let path = currentPath.appendingPathComponent(name)

        do {
            try await fileRepository.createDirectory(at: path)
            isShowingNewFolderSheet = false
            AnalyticsService.trackFileOperation(.createFolder, protocol: .init(from: connection.connectionType))
            await loadFiles()
        } catch {
            logError("Failed to create folder: \(error)", category: session.logCategory)
            self.error = AppError.from(error)
        }
    }

    func createFile(name: String) async {
        let path = currentPath.appendingPathComponent(name)

        do {
            try await fileRepository.createFile(at: path)
            isShowingNewFileSheet = false
            await loadFiles()
        } catch {
            logError("Failed to create file: \(error)", category: session.logCategory)
            self.error = AppError.from(error)
        }
    }

    func renameFile(_ file: RemoteFile, to newName: String) async {
        let newPath = file.path.directoryPath.appendingPathComponent(newName)

        do {
            try await fileRepository.rename(from: file.path, to: newPath)
            isShowingRenameSheet = false
            fileToRename = nil
            AnalyticsService.trackFileOperation(.rename, protocol: .init(from: connection.connectionType))
            await loadFiles()
        } catch {
            logError("Failed to rename file: \(error)", category: session.logCategory)
            self.error = AppError.from(error)
        }
    }

    nonisolated private static func executeDelete(
        files: [RemoteFile],
        repository: FileRepositoryProtocol
    ) async throws {
        for file in files {
            try await repository.delete(at: file.path, isDirectory: file.isDirectory)
        }
    }

    func deleteFiles(_ files: [RemoteFile]) async {
        let repository = self.fileRepository
        do {
            try await Self.executeDelete(files: files, repository: repository)
        } catch {
            logError("Failed to delete files: \(error)", category: session.logCategory)
            self.error = AppError.from(error)
            return
        }

        isShowingDeleteConfirmation = false
        filesToDelete = []
        selectedFiles.removeAll()
        AnalyticsService.trackFileOperation(.delete, protocol: .init(from: connection.connectionType), count: files.count)
        await loadFiles()
    }

    func deleteSelectedFiles() async {
        await deleteFiles(selectedFilesList)
    }

    // MARK: - Clipboard Operations

    func copySelectedFiles() {
        clipboardService.copy(files: selectedFilesList, from: currentPath, connectionId: connection.id)
    }

    func cutSelectedFiles() {
        clipboardService.cut(files: selectedFilesList, from: currentPath, connectionId: connection.id)
    }

    func copyFiles(_ files: [RemoteFile]) {
        selectedFiles = Set(files.map { $0.id })
        clipboardService.copy(files: files, from: currentPath, connectionId: connection.id)
    }

    func cutFiles(_ files: [RemoteFile]) {
        selectedFiles = Set(files.map { $0.id })
        clipboardService.cut(files: files, from: currentPath, connectionId: connection.id)
    }

    func copyS3ObjectURL(for file: RemoteFile) async {
        do {
            let url = try await s3ObjectURL(for: file)
            copyTextToPasteboard(url.absoluteString)
            logInfo("Copied S3 object URL: \(file.name)", category: .s3)
        } catch {
            self.error = AppError.from(error)
        }
    }

    func copyS3PresignedURL(for file: RemoteFile, expiresIn: TimeInterval = 600) async {
        do {
            let url = try await s3PresignedURL(for: file, expiresIn: expiresIn)
            copyTextToPasteboard(url.absoluteString)
            logInfo("Copied S3 presigned URL: \(file.name)", category: .s3)
        } catch {
            self.error = AppError.from(error)
        }
    }

    func s3ObjectURL(for file: RemoteFile) async throws -> URL {
        try await session.s3ObjectURL(for: file.path)
    }

    func s3PresignedURL(for file: RemoteFile, expiresIn: TimeInterval = 600) async throws -> URL {
        try await session.s3PresignedURL(for: file.path, expiresIn: expiresIn)
    }

    nonisolated private static func executePaste(
        items: [ClipboardItem],
        isCut: Bool,
        destinationBasePath: String,
        repository: FileRepositoryProtocol
    ) async throws {
        for item in items {
            let destinationPath = destinationBasePath.appendingPathComponent(item.fileName)
            if isCut {
                try await repository.move(from: item.fullSourcePath, to: destinationPath)
            } else {
                try await repository.copy(
                    from: item.fullSourcePath,
                    to: destinationPath,
                    isDirectory: item.isDirectory
                )
            }
        }
    }

    func paste() async {
        guard canPaste else { return }

        let items = clipboardService.items
        let isCut = clipboardService.isCut
        let destinationBasePath = currentPath
        let repository = self.fileRepository

        do {
            try await Self.executePaste(
                items: items,
                isCut: isCut,
                destinationBasePath: destinationBasePath,
                repository: repository
            )
        } catch {
            logError("Failed to paste: \(error)", category: session.logCategory)
            self.error = AppError.from(error)
            return
        }

        if isCut {
            clipboardService.clear()
        }

        await loadFiles()
    }

    private func copyTextToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    // MARK: - Download / Upload

    func downloadFile(_ file: RemoteFile) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        transferManager.startDownload(
            file: file,
            to: url,
            repository: fileRepository,
            connectionType: connection.connectionType,
            logCategory: session.logCategory
        ) { [weak self] appError in
            self?.error = appError
        }
    }

    func uploadFiles() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else { return }

        await uploadURLs(panel.urls)
    }

    /// Retries failed transfers from the previous batch without re-uploading succeeded files
    func retryFailedTransfers() async {
        guard !lastFailedUploadItems.isEmpty, !transferManager.isBatchInProgress else { return }
        let itemsToRetry = lastFailedUploadItems
        guard transferManager.beginBatchSession() else { return }
        defer { transferManager.endBatchSession() }
        await executeUploadBatch(items: itemsToRetry, directoriesToCreate: [], topLevelNames: [])
    }

    private func uploadURLs(_ urls: [URL]) async {
        guard transferManager.beginBatchSession() else {
            logWarning("Upload batch already in progress, ignoring concurrent request", category: .app)
            self.error = .uploadFailed("A transfer batch is already in progress. Please wait for it to finish or cancel it first.")
            return
        }
        defer { transferManager.endBatchSession() }

        let targetPath = currentPath
        do {
            let scan = try await transferManager.prepareScan {
                try await StreamingFileScanner.scanLocalURLs(urls, targetRemotePath: targetPath)
            }
            guard !scan.items.isEmpty || !scan.directoriesToCreate.isEmpty else { return }
            await executeUploadBatch(
                items: scan.items,
                directoriesToCreate: scan.directoriesToCreate,
                topLevelNames: scan.topLevelDirectoryNames
            )
        } catch is CancellationError {
            return
        } catch {
            self.error = AppError.from(error)
        }
    }

    private func executeUploadBatch(
        items: [TransferQueueItem],
        directoriesToCreate: [String],
        topLevelNames: [String] = []
    ) async {
        let title: String
        if topLevelNames.count == 1 {
            title = "Uploading \"\(topLevelNames[0])\""
        } else {
            title = "Uploading \(items.count) files"
        }

        let repository = self.fileRepository
        let connectionType = self.connection.connectionType

        let result = await transferManager.executeBatch(
            title: title,
            items: items,
            directoriesToCreate: directoriesToCreate,
            repository: repository,
            transferType: .upload,
            executor: { item, progress in
                guard let localURL = item.localURL else {
                    throw AppError.fileNotFound
                }
                try await repository.upload(localURL: localURL, to: item.remotePath, progress: progress)

                guard item.isTopLevel else { return nil }
                return RemoteFile(
                    name: item.displayName,
                    path: item.remotePath,
                    isDirectory: false,
                    size: item.fileSize,
                    permissions: "-rw-r--r--",
                    modificationDate: Date()
                )
            },
            onSnapshot: { [weak self] snapshot in
                self?.applyBatchSnapshot(snapshot)
            },
            onError: { [weak self] appError in
                self?.error = appError
            }
        )

        AnalyticsService.trackBatchTransferred(
            protocol: .init(from: connectionType),
            fileCount: result.completedFiles,
            totalBytes: result.completedBytes,
            isUpload: true
        )

        if result.completedFiles > 0 || !directoriesToCreate.isEmpty {
            await loadFiles()
        }
    }

    /// Applies an atomic throttled snapshot from BatchProgressTracker to the UI state
    func applyBatchSnapshot(_ snapshot: BatchProgressSnapshot) {
        guard transferManager.applyBatchSnapshot(snapshot) else { return }

        if !snapshot.topLevelFiles.isEmpty {
            var updatedFiles = self.files
            for file in snapshot.topLevelFiles {
                let cleanPath = file.path.trimmingCharacters(in: ["/"])
                if let idx = updatedFiles.firstIndex(where: {
                    $0.name == file.name || $0.path.trimmingCharacters(in: ["/"]) == cleanPath
                }) {
                    updatedFiles[idx] = file
                } else {
                    updatedFiles.append(file)
                }
            }
            self.files = updatedFiles
            if case .loading = state {
                state = .success(())
            } else if case .idle = state {
                state = .success(())
            }
        }
    }

    func cancelBatch() { transferManager.cancelBatch() }
    func cancelTransfer(_ transfer: TransferProgress) { transferManager.cancelTransfer(transfer) }
    func cancelAllTransfers() { transferManager.cancelAllTransfers() }
    func clearCompletedTransfers() { transferManager.clearCompletedTransfers() }
    func removeTransfer(_ transfer: TransferProgress) { transferManager.removeTransfer(transfer) }

    func trackTransfer(_ transfer: TransferProgress, task: Task<Void, Never>? = nil) {
        transferManager.trackTransfer(transfer, task: task)
    }

    func updateTransferProgress(id: UUID, bytesTransferred: Int64) {
        transferManager.updateTransferProgress(id: id, bytesTransferred: bytesTransferred)
    }

    func completeTransfer(id: UUID, totalBytes: Int64) {
        transferManager.completeTransfer(id: id, totalBytes: totalBytes)
    }

    func failTransfer(id: UUID, error: Error?, isCancelled: Bool) {
        transferManager.failTransfer(id: id, error: error, isCancelled: isCancelled)
    }

    // MARK: - Drag and Drop

    /// Downloads a file to a specific URL (used for drag-out file promises)
    func downloadFileToURL(_ file: RemoteFile, destinationURL: URL) async throws {
        try await transferManager.downloadToURL(
            file: file,
            destinationURL: destinationURL,
            repository: fileRepository,
            connectionType: connection.connectionType,
            logCategory: session.logCategory
        )
    }

    /// Uploads files dropped from Finder into the current directory
    func uploadDroppedFiles(_ urls: [URL]) async {
        await uploadURLs(urls)
    }

    // MARK: - File Content

    func getFileContent(_ file: RemoteFile) async throws -> String {
        try await fileRepository.readFileContent(at: file.path)
    }

    func saveFileContent(_ content: String, to path: String) async throws {
        try await fileRepository.writeFileContent(content, to: path)
    }

    // MARK: - Selection

    func selectAll() {
        selectedFiles = Set(sortedFiles.map { $0.id })
    }

    func deselectAll() {
        selectedFiles.removeAll()
    }

    func toggleSelection(for file: RemoteFile) {
        if selectedFiles.contains(file.id) {
            selectedFiles.remove(file.id)
        } else {
            selectedFiles.insert(file.id)
        }
    }

    // MARK: - UI Actions

    func confirmDelete(_ files: [RemoteFile]) {
        filesToDelete = files
        isShowingDeleteConfirmation = true
    }

    func confirmDeleteSelected() {
        confirmDelete(selectedFilesList)
    }

    func startRename(_ file: RemoteFile) {
        fileToRename = file
        isShowingRenameSheet = true
    }

    func showFileInfo(_ file: RemoteFile) {
        let data = FileInfoWindowData(
            file: file,
            connectionName: connection.name
        )
        let windowId = windowManager.storeFileInfoData(data)
        pendingFileInfoWindowId = windowId
        AnalyticsService.track(.fileInfoOpened)
    }

    func clearPendingFileInfoWindow() {
        pendingFileInfoWindowId = nil
    }

    func openEditor(for file: RemoteFile, content: String) {
        let data = FileEditorWindowData(
            filePath: file.path,
            fileName: file.name,
            content: content,
            connectionId: connection.id,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password,
            authMethod: connection.authMethod,
            sshKeyId: connection.sshKeyId,
            connectionType: connection.connectionType,
            s3Region: connection.s3Region,
            s3Bucket: connection.s3Bucket,
            s3Endpoint: connection.s3Endpoint
        )
        let windowId = windowManager.storeFileEditorData(data)
        pendingEditorWindowId = windowId
        AnalyticsService.trackEditorOpened(fileExtension: (file.name as NSString).pathExtension)
    }

    func clearPendingEditorWindow() {
        pendingEditorWindowId = nil
    }

    func clearError() {
        error = nil
    }

    // MARK: - Quick Look

    func toggleQuickLook() {
        quickLookController.toggle(for: primarySelectedFile)
    }

    func showQuickLook(for file: RemoteFile) {
        quickLookController.show(for: file)
    }

    func closeQuickLook() {
        quickLookController.close()
    }
}

// MARK: - Path Component
struct PathComponent: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String

    static func == (lhs: PathComponent, rhs: PathComponent) -> Bool {
        lhs.path == rhs.path && lhs.name == rhs.name
    }
}
