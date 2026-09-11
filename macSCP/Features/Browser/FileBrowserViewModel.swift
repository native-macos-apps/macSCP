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

    // MARK: - Transfer Progress State
    private(set) var activeTransfers: [UUID: TransferProgress] = [:]
    private(set) var recentTransfers: [TransferProgress] = []  // Completed/failed transfers
    private var transferTasks: [UUID: Task<Void, Never>] = [:]  // Tasks for cancellation
    private var currentBatchTracker: BatchProgressTracker?
    private var lastAppliedSnapshotSequence: UInt64 = 0
    var isShowingTransfersPopover: Bool = false
    var activeBatch: BatchTransferProgress?
    private var isBatchCancelled: Bool = false

    /// Whether any transfer is currently in progress
    var hasActiveTransfers: Bool {
        !activeTransfers.isEmpty || (activeBatch?.isInProgress ?? false)
    }

    /// Total number of active transfers
    var activeTransferCount: Int {
        if let batch = activeBatch, batch.isInProgress {
            return max(1, batch.totalFiles - batch.completedFiles)
        }
        return activeTransfers.values.reduce(0) { $0 + ($1.isDirectory ? max($1.itemCount, 1) : 1) }
    }

    /// All transfers for display (active + recent)
    var allTransfers: [TransferProgress] {
        let active = activeTransfers.values.sorted { $0.startTime > $1.startTime }
        return active + recentTransfers
    }

    /// Overall progress of all active transfers (0.0 to 1.0)
    var overallProgress: Double {
        if let batch = activeBatch, batch.totalBytes > 0 {
            return batch.fractionCompleted
        }
        guard !activeTransfers.isEmpty else { return 0 }
        let totalBytes = activeTransfers.values.reduce(0) { $0 + $1.totalBytes }
        let transferredBytes = activeTransfers.values.reduce(0) { $0 + $1.bytesTransferred }
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }

    var selectedFiles: Set<UUID> = []
    var primarySelectedFile: RemoteFile? {
        didSet {
            if isShowingQuickLook {
                if let file = primarySelectedFile {
                    showQuickLook(for: file)
                } else {
                    quickLookFile = nil
                    quickLookTask?.cancel()
                }
            }
        }
    }
    var sortCriteria: RemoteFile.SortCriteria = .name
    var sortAscending: Bool = true
    var showHiddenFiles: Bool = false

    // Quick Look state
    var isShowingQuickLook: Bool = false {
        didSet {
            if !isShowingQuickLook {
                quickLookTask?.cancel()
            }
        }
    }
    var quickLookFile: RemoteFile?
    private(set) var quickLookContent: QuickLookContent = .loading
    private var quickLookCache: [String: QuickLookContent] = [:]
    private var quickLookTask: Task<Void, Never>?

    // Sheet states
    var isShowingNewFolderSheet = false
    var isShowingNewFileSheet = false
    var isShowingRenameSheet = false
    var isShowingDeleteConfirmation = false

    // File to operate on
    var fileToRename: RemoteFile?
    var filesToDelete: [RemoteFile] = []

    // Window opening state
    var pendingFileInfoWindowId: String?
    var pendingEditorWindowId: String?

    // MARK: - Connection Info
    let connection: Connection
    private let password: String

    // MARK: - Dependencies
    private let sftpSession: SFTPSessionProtocol?
    private let s3Session: S3SessionProtocol?
    let fileRepository: FileRepositoryProtocol
    private let clipboardService: ClipboardService
    private let navigationService = NavigationService()

    // MARK: - Computed Properties

    var isLocal: Bool {
        connection.connectionType == .local
    }

    // MARK: - Initialization (SFTP)
    init(
        connection: Connection,
        sftpSession: SFTPSessionProtocol,
        fileRepository: FileRepositoryProtocol,
        clipboardService: ClipboardService,
        password: String
    ) {
        self.connection = connection
        self.sftpSession = sftpSession
        self.s3Session = nil
        self.fileRepository = fileRepository
        self.clipboardService = clipboardService
        self.password = password
    }

    // MARK: - Initialization (S3)
    init(
        connection: Connection,
        s3Session: S3SessionProtocol,
        fileRepository: FileRepositoryProtocol,
        clipboardService: ClipboardService,
        secretAccessKey: String
    ) {
        self.connection = connection
        self.sftpSession = nil
        self.s3Session = s3Session
        self.fileRepository = fileRepository
        self.clipboardService = clipboardService
        self.password = secretAccessKey
    }

    // MARK: - Initialization (Local)
    init(
        localRepository: FileRepositoryProtocol,
        clipboardService: ClipboardService,
        initialPath: String? = nil
    ) {
        let homeDir = LocalFileRepository.userHomeDirectory
        let startingPath = initialPath ?? homeDir
        self.connection = Connection(
            id: UUID(),
            name: "Mac",
            host: "localhost",
            username: NSUserName(),
            connectionType: .local
        )
        self.sftpSession = nil
        self.s3Session = nil
        self.fileRepository = localRepository
        self.clipboardService = clipboardService
        self.password = ""
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

    var canGoBack: Bool {
        navigationService.canGoBack
    }

    var canGoForward: Bool {
        navigationService.canGoForward
    }

    var canGoUp: Bool {
        currentPath != "/"
    }

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

    var clipboardDisplayText: String {
        clipboardService.displayText
    }

    var hasClipboardItems: Bool {
        !clipboardService.isEmpty
    }

    var canPaste: Bool {
        clipboardService.canPaste(to: connection.id)
    }

    // MARK: - Connection

    func connect() async {
        state = .loading

        if isLocal {
            isConnected = true
            if currentPath.isEmpty || currentPath == "/" {
                currentPath = FileManager.default.homeDirectoryForCurrentUser.path
            }
            navigationService.reset(to: currentPath)
            AnalyticsService.trackFileBrowserOpened(protocol: .local)
            await loadFiles()
            return
        }

        do {
            if connection.connectionType == .s3 {
                // S3 connection
                guard let s3Session = s3Session else {
                    throw AppError.notConnected
                }
                try await s3Session.connect(
                    accessKeyId: connection.username,
                    secretAccessKey: password,
                    region: connection.s3Region ?? "us-east-1",
                    bucket: connection.s3Bucket ?? "",
                    endpoint: connection.s3Endpoint
                )
                isConnected = true
                currentPath = await s3Session.currentPath
                navigationService.reset(to: currentPath)
                AnalyticsService.trackFileBrowserOpened(protocol: .init(from: connection.connectionType))
                await loadFiles()
            } else {
                // SFTP connection
                guard let sftpSession = sftpSession else {
                    throw AppError.notConnected
                }
                if connection.authMethod == .password {
                    try await sftpSession.connect(
                        host: connection.host,
                        port: connection.port,
                        username: connection.username,
                        password: password
                    )
                } else if let keyPath = connection.privateKeyPath {
                    try await sftpSession.connect(
                        host: connection.host,
                        port: connection.port,
                        username: connection.username,
                        privateKeyPath: keyPath,
                        bookmarkData: connection.securityScopedBookmarkData,
                        passphrase: password.isEmpty ? nil : password
                    )
                }
                isConnected = true
                currentPath = await sftpSession.currentPath
                navigationService.reset(to: currentPath)
                AnalyticsService.trackFileBrowserOpened(protocol: .init(from: connection.connectionType))
                await loadFiles()
            }
        } catch {
            logError("Connection failed: \(error)", category: connection.connectionType == .s3 ? .s3 : .sftp)
            state = .error(AppError.from(error))
        }
    }

    func disconnect() async {
        if isLocal {
            isConnected = false
            files = []
            navigationService.reset()
            return
        }
        if connection.connectionType == .s3 {
            await s3Session?.disconnect()
        } else {
            await sftpSession?.disconnect()
        }
        isConnected = false
        files = []
        currentPath = "/"
        navigationService.reset()
    }

    // MARK: - Navigation

    /// Appends or updates a file in the files list without triggering full reload/loading state
    func appendFile(_ file: RemoteFile) {
        let cleanPath = file.path.trimmingCharacters(in: ["/"])
        if let idx = files.firstIndex(where: {
            $0.name == file.name || $0.path.trimmingCharacters(in: ["/"]) == cleanPath
        }) {
            files[idx] = file
        } else {
            files.append(file)
        }
        if case .loading = state {
            state = .success(())
        } else if case .idle = state {
            state = .success(())
        }
    }

    func loadFiles(showLoading: Bool = false) async {
        if showLoading || files.isEmpty {
            state = .loading
        }

        do {
            files = try await fileRepository.listFiles(at: currentPath)
            if !isLocal {
                if connection.connectionType == .s3 {
                    currentPath = await s3Session?.currentPath ?? "/"
                } else {
                    currentPath = await sftpSession?.currentPath ?? "/"
                }
            }
            state = .success(())
        } catch {
            logError("Failed to load files: \(error)", category: connection.connectionType == .s3 ? .s3 : .sftp)
            state = .error(AppError.from(error))
        }
    }

    /// Fetches the contents of a folder at `path` without changing navigation
    /// state. Used by the outline view for lazy child-node loading.
    func listChildFiles(at path: String) async throws -> [RemoteFile] {
        try await fileRepository.listFiles(at: path)
    }

    func navigateTo(_ path: String, addToHistory: Bool = true) async {
        state = .loading

        do {
            logInfo("Navigating to: \(path) (history: \(addToHistory))", category: .ui)
            
            let newFiles = try await fileRepository.listFiles(at: path)
            
            let newPath: String
            if isLocal {
                newPath = (path as NSString).expandingTildeInPath
            } else if connection.connectionType == .s3 {
                newPath = await s3Session?.currentPath ?? "/"
            } else {
                newPath = await sftpSession?.currentPath ?? "/"
            }
            
            // Update state atomically on MainActor
            self.files = newFiles
            self.currentPath = newPath
            
            if addToHistory {
                navigationService.navigate(to: newPath)
            }
            
            self.selectedFiles.removeAll()
            self.state = .success(())
            
            logInfo("Successfully navigated to: \(newPath)", category: .ui)
        } catch {
            logError("Failed to navigate to \(path): \(error)", category: connection.connectionType == .s3 ? .s3 : .sftp)
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
        if isLocal {
            await navigateTo(FileManager.default.homeDirectoryForCurrentUser.path)
        } else {
            await navigateTo("~")
        }
    }

    func refresh() async {
        await loadFiles(showLoading: false)
    }

    private func navigateWithoutHistory(to path: String) async {
        state = .loading

        do {
            files = try await fileRepository.listFiles(at: path)
            if isLocal {
                currentPath = (path as NSString).expandingTildeInPath
            } else if connection.connectionType == .s3 {
                currentPath = await s3Session?.currentPath ?? "/"
            } else {
                currentPath = await sftpSession?.currentPath ?? "/"
            }
            selectedFiles.removeAll()
            state = .success(())
        } catch {
            logError("Failed to navigate to \(path): \(error)", category: connection.connectionType == .s3 ? .s3 : .sftp)
            state = .error(AppError.from(error))
        }
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
            logError("Failed to create folder: \(error)", category: .sftp)
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
            logError("Failed to create file: \(error)", category: .sftp)
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
            logError("Failed to rename file: \(error)", category: .sftp)
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
            logError("Failed to delete files: \(error)", category: .sftp)
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
        guard connection.connectionType == .s3, let s3Session else {
            throw AppError.notConnected
        }
        return try await s3Session.publicURL(for: file.path)
    }

    func s3PresignedURL(for file: RemoteFile, expiresIn: TimeInterval = 600) async throws -> URL {
        guard connection.connectionType == .s3, let s3Session else {
            throw AppError.notConnected
        }
        return try await s3Session.presignedURL(for: file.path, expiresIn: expiresIn)
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
            logError("Failed to paste: \(error)", category: .sftp)
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

    // MARK: - Download/Upload

    func downloadFile(_ file: RemoteFile) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let transferId = UUID()
        let transfer = TransferProgress(
            id: transferId,
            fileName: file.name,
            localURL: url,
            remotePath: file.path,
            bytesTransferred: 0,
            totalBytes: file.size,
            transferType: .download,
            status: .inProgress
        )
        activeTransfers[transferId] = transfer
        isShowingTransfersPopover = true

        let throttler = SingleTransferThrottler(interval: 0.1)

        let downloadTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                try Task.checkCancellation()

                try await self.fileRepository.download(remotePath: file.path, to: url) { [weak self] bytesTransferred in
                    guard let self else { return }
                    if throttler.shouldUpdate() {
                        Task { @MainActor in
                            guard self.activeTransfers[transferId] != nil else { return }
                            self.activeTransfers[transferId]?.bytesTransferred = bytesTransferred
                        }
                    }
                }

                try Task.checkCancellation()

                await MainActor.run {
                    if var completedTransfer = self.activeTransfers.removeValue(forKey: transferId) {
                        completedTransfer.status = .completed
                        completedTransfer.bytesTransferred = file.size
                        self.recentTransfers.insert(completedTransfer, at: 0)
                        if self.recentTransfers.count > 10 {
                            self.recentTransfers = Array(self.recentTransfers.prefix(10))
                        }
                    }
                    self.transferTasks.removeValue(forKey: transferId)
                }

                AnalyticsService.trackFileDownloaded(protocol: .init(from: self.connection.connectionType), fileCount: 1, totalBytes: file.size)
                logInfo("Downloaded: \(file.name)", category: self.connection.connectionType == .s3 ? .s3 : .sftp)

            } catch {
                let isCancellation = error is CancellationError ||
                    Task.isCancelled ||
                    String(describing: error).contains("CancellationError")

                if isCancellation {
                    await MainActor.run {
                        if var cancelledTransfer = self.activeTransfers.removeValue(forKey: transferId) {
                            cancelledTransfer.status = .cancelled
                            self.recentTransfers.insert(cancelledTransfer, at: 0)
                        }
                        self.transferTasks.removeValue(forKey: transferId)
                    }
                    logInfo("Download cancelled: \(file.name)", category: self.connection.connectionType == .s3 ? .s3 : .sftp)
                } else {
                    await MainActor.run {
                        if var failedTransfer = self.activeTransfers.removeValue(forKey: transferId) {
                            failedTransfer.status = .failed
                            failedTransfer.error = error.localizedDescription
                            self.recentTransfers.insert(failedTransfer, at: 0)
                        }
                        self.transferTasks.removeValue(forKey: transferId)
                    }

                    logError("Download failed: \(error)", category: self.connection.connectionType == .s3 ? .s3 : .sftp)
                    await MainActor.run {
                        self.error = AppError.from(error)
                    }
                }
            }
        }

        transferTasks[transferId] = downloadTask
    }

    func uploadFiles() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else { return }

        await uploadURLs(panel.urls)
    }

    private struct PendingUploadFile: Sendable {
        let localURL: URL
        let displayName: String
        let remotePath: String
        let fileSize: Int64
        let isTopLevel: Bool
    }

    private struct ScannedUploadData: Sendable {
        let directoriesToCreate: [String]
        let topLevelFolders: [(name: String, remotePath: String)]
        let filesToUpload: [PendingUploadFile]
    }

    nonisolated private static func scanLocalURLs(_ urls: [URL], currentPath: String) -> ScannedUploadData {
        var directoriesToCreate: [String] = []
        var topLevelFolders: [(name: String, remotePath: String)] = []
        var filesToUpload: [PendingUploadFile] = []

        for url in urls {
            guard url.isFileURL else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if !isDir.boolValue {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                let remotePath = currentPath.appendingPathComponent(url.lastPathComponent)
                filesToUpload.append(PendingUploadFile(
                    localURL: url,
                    displayName: url.lastPathComponent,
                    remotePath: remotePath,
                    fileSize: size,
                    isTopLevel: true
                ))
            } else {
                let folderName = url.lastPathComponent
                let rootRemotePath = currentPath.appendingPathComponent(folderName)
                topLevelFolders.append((name: folderName, remotePath: rootRemotePath))
                directoriesToCreate.append(rootRemotePath)

                let baseDirURL = url.deletingLastPathComponent()
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for case let fileURL as URL in enumerator {
                        var childIsDir: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &childIsDir) else { continue }

                        let relativePath: String
                        if fileURL.path.hasPrefix(baseDirURL.path) {
                            relativePath = String(fileURL.path.dropFirst(baseDirURL.path.count))
                                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        } else {
                            relativePath = fileURL.lastPathComponent
                        }
                        let childRemotePath = currentPath.appendingPathComponent(relativePath)

                        if childIsDir.boolValue {
                            directoriesToCreate.append(childRemotePath)
                        } else {
                            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                            filesToUpload.append(PendingUploadFile(
                                localURL: fileURL,
                                displayName: relativePath,
                                remotePath: childRemotePath,
                                fileSize: size,
                                isTopLevel: false
                            ))
                        }
                    }
                }
            }
        }

        return ScannedUploadData(
            directoriesToCreate: directoriesToCreate,
            topLevelFolders: topLevelFolders,
            filesToUpload: filesToUpload
        )
    }

    nonisolated private static func createRemoteDirectories(
        _ directoriesToCreate: [String],
        repository: FileRepositoryProtocol
    ) async {
        guard !directoriesToCreate.isEmpty else { return }
        let uniqueDirs = Array(NSOrderedSet(array: directoriesToCreate)) as? [String] ?? directoriesToCreate
        let sortedDirs = uniqueDirs.sorted { $0.components(separatedBy: "/").count < $1.components(separatedBy: "/").count }
        let dirsByDepth = Dictionary(grouping: sortedDirs) { $0.components(separatedBy: "/").count }
        let depths = dirsByDepth.keys.sorted()
        for depth in depths {
            if let dirsAtDepth = dirsByDepth[depth] {
                await withTaskGroup(of: Void.self) { dirGroup in
                    for dir in dirsAtDepth {
                        dirGroup.addTask {
                            try? await repository.createDirectory(at: dir)
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func executeBatchUploadCoordinator(
        files: [PendingUploadFile],
        directoriesToCreate: [String],
        maxConcurrent: Int,
        repository: FileRepositoryProtocol,
        connectionType: ConnectionType,
        tracker: BatchProgressTracker,
        onUpdate: @escaping @Sendable (BatchProgressSnapshot) -> Void
    ) async {
        await createRemoteDirectories(directoriesToCreate, repository: repository)

        await processBatchUpload(
            files: files,
            maxConcurrent: maxConcurrent,
            repository: repository,
            connectionType: connectionType,
            tracker: tracker,
            onUpdate: onUpdate
        )

        let finalSnapshot = tracker.drainFinal(isCancelled: tracker.isBatchCancelled)
        onUpdate(finalSnapshot)
    }

    /// Core upload method that handles multiple files and directories with per-file progress tracking
    private func uploadURLs(_ urls: [URL]) async {
        let currentPath = self.currentPath
        let scanned = await Task.detached(priority: .userInitiated) {
            Self.scanLocalURLs(urls, currentPath: currentPath)
        }.value

        let filesToUpload = scanned.filesToUpload
        let topLevelFolders = scanned.topLevelFolders
        let directoriesToCreate = scanned.directoriesToCreate

        self.isBatchCancelled = false
        let totalFilesCount = filesToUpload.count
        let totalBytesSum = filesToUpload.reduce(0) { $0 + $1.fileSize }
        let batchId = UUID()
        self.lastAppliedSnapshotSequence = 0

        if topLevelFolders.count > 0 || filesToUpload.count > 1 {
            let title = topLevelFolders.count == 1
                ? "Uploading \"\(topLevelFolders[0].name)\""
                : "Uploading \(totalFilesCount) files"
            self.activeBatch = BatchTransferProgress(
                id: batchId,
                title: title,
                totalFiles: totalFilesCount,
                totalBytes: totalBytesSum
            )
        }

        if !isShowingTransfersPopover {
            isShowingTransfersPopover = true
        }

        // Immediately append top-level folders to current directory view
        for folder in topLevelFolders {
            let formattedPath = folder.remotePath.hasSuffix("/") ? folder.remotePath : folder.remotePath + "/"
            let folderFile = RemoteFile(
                name: folder.name,
                path: formattedPath,
                isDirectory: true,
                size: 0,
                permissions: "drwxr-xr-x",
                modificationDate: Date()
            )
            appendFile(folderFile)
        }

        guard !filesToUpload.isEmpty else {
            if !directoriesToCreate.isEmpty {
                let repository = self.fileRepository
                Task.detached {
                    await Self.createRemoteDirectories(directoriesToCreate, repository: repository)
                }
            }
            return
        }

        let tracker = BatchProgressTracker(
            batchId: batchId,
            totalFiles: filesToUpload.count,
            totalBytes: totalBytesSum,
            initialRecent: recentTransfers
        )
        self.currentBatchTracker = tracker

        let maxConcurrent = TransferSettings.shared.maxConcurrentTransfers
        let repository = self.fileRepository
        let connectionType = self.connection.connectionType

        let onUpdate: @Sendable (BatchProgressSnapshot) -> Void = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.applyBatchSnapshot(snapshot)
            }
        }

        await Self.executeBatchUploadCoordinator(
            files: filesToUpload,
            directoriesToCreate: directoriesToCreate,
            maxConcurrent: maxConcurrent,
            repository: repository,
            connectionType: connectionType,
            tracker: tracker,
            onUpdate: onUpdate
        )

        self.currentBatchTracker = nil
    }

    /// Applies an atomic throttled snapshot from BatchProgressTracker to the UI state
    func applyBatchSnapshot(_ snapshot: BatchProgressSnapshot) {
        // Discard snapshots from an older/different batch
        if let batch = self.activeBatch, batch.id != snapshot.batchId {
            return
        }
        // Discard out-of-order snapshots
        guard snapshot.sequence > self.lastAppliedSnapshotSequence else {
            return
        }
        self.lastAppliedSnapshotSequence = snapshot.sequence

        self.activeTransfers = snapshot.activeTransfers
        self.recentTransfers = snapshot.recentTransfers
        if var batch = self.activeBatch {
            batch.completedFiles = snapshot.completedFiles
            batch.completedBytes = snapshot.completedBytes
            batch.transferredBytes = snapshot.transferredBytes
            if snapshot.isFinal {
                batch.status = self.isBatchCancelled ? .cancelled : .completed
            }
            self.activeBatch = batch
        }
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

    nonisolated private static func processBatchUpload(
        files: [PendingUploadFile],
        maxConcurrent: Int,
        repository: FileRepositoryProtocol,
        connectionType: ConnectionType,
        tracker: BatchProgressTracker,
        onUpdate: @escaping @Sendable (BatchProgressSnapshot) -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var fileIndex = 0
            let initialCount = min(maxConcurrent, files.count)
            while fileIndex < initialCount {
                let file = files[fileIndex]
                fileIndex += 1
                group.addTask {
                    await Self.uploadSingleFile(
                        file,
                        repository: repository,
                        connectionType: connectionType,
                        tracker: tracker,
                        onUpdate: onUpdate
                    )
                }
            }

            for await _ in group {
                if Task.isCancelled || tracker.isBatchCancelled {
                    break
                }
                if fileIndex < files.count {
                    let file = files[fileIndex]
                    fileIndex += 1
                    group.addTask {
                        await Self.uploadSingleFile(
                            file,
                            repository: repository,
                            connectionType: connectionType,
                            tracker: tracker,
                            onUpdate: onUpdate
                        )
                    }
                }
            }
        }
    }

    nonisolated private static func uploadSingleFile(
        _ file: PendingUploadFile,
        repository: FileRepositoryProtocol,
        connectionType: ConnectionType,
        tracker: BatchProgressTracker,
        onUpdate: @escaping @Sendable (BatchProgressSnapshot) -> Void
    ) async {
        if Task.isCancelled { return }

        let transferId = UUID()
        let transfer = TransferProgress(
            id: transferId,
            fileName: file.displayName,
            localURL: file.localURL,
            remotePath: file.remotePath,
            bytesTransferred: 0,
            totalBytes: file.fileSize,
            transferType: .upload,
            status: .inProgress,
            isDirectory: false,
            itemCount: 1
        )

        // Atomically register in tracker buffer
        if let snapshot = tracker.registerActive(transfer: transfer) {
            onUpdate(snapshot)
        }

        do {
            try Task.checkCancellation()

            try await repository.upload(localURL: file.localURL, to: file.remotePath) { bytesTransferred in
                if let snapshot = tracker.updateActiveBytes(id: transferId, bytes: bytesTransferred) {
                    onUpdate(snapshot)
                }
            }

            try Task.checkCancellation()

            var destRemoteFile: RemoteFile? = nil
            if file.isTopLevel {
                destRemoteFile = RemoteFile(
                    name: file.displayName,
                    path: file.remotePath,
                    isDirectory: false,
                    size: file.fileSize,
                    permissions: "-rw-r--r--",
                    modificationDate: Date()
                )
            }

            if let snapshot = tracker.completeFile(id: transferId, totalBytes: file.fileSize, topLevelFile: destRemoteFile) {
                onUpdate(snapshot)
            }

            AnalyticsService.trackFileUploaded(protocol: .init(from: connectionType), fileCount: 1, totalBytes: file.fileSize)
            logInfo("Uploaded: \(file.displayName)", category: connectionType == .s3 ? .s3 : .sftp)
        } catch {
            let isCancellation = error is CancellationError ||
                Task.isCancelled ||
                String(describing: error).contains("CancellationError")

            if let snapshot = tracker.failOrCancelFile(id: transferId, totalBytes: file.fileSize, error: error, isCancelled: isCancellation) {
                onUpdate(snapshot)
            }

            if isCancellation {
                logInfo("Upload cancelled: \(file.displayName)", category: connectionType == .s3 ? .s3 : .sftp)
            } else {
                logError("Upload failed for \(file.displayName): \(error)", category: connectionType == .s3 ? .s3 : .sftp)
            }
        }
    }

    /// Cancels the entire active batch and all active file transfers
    func cancelBatch() {
        isBatchCancelled = true
        activeBatch?.status = .cancelled
        currentBatchTracker?.cancelAll()
        cancelAllTransfers()
    }

    /// Cancels an active transfer
    func cancelTransfer(_ transfer: TransferProgress) {
        guard transfer.isInProgress else { return }
        currentBatchTracker?.cancelTransfer(id: transfer.id)

        // Cancel the task
        if let task = transferTasks[transfer.id] {
            task.cancel()
        }

        // Immediately update UI to show cancelled state
        if var cancelledTransfer = activeTransfers.removeValue(forKey: transfer.id) {
            cancelledTransfer.status = .cancelled
            recentTransfers.insert(cancelledTransfer, at: 0)
            if recentTransfers.count > 30 {
                recentTransfers = Array(recentTransfers.prefix(30))
            }
        }
        transferTasks.removeValue(forKey: transfer.id)
    }

    /// Cancels all active transfers
    func cancelAllTransfers() {
        isBatchCancelled = true
        activeBatch?.status = .cancelled
        currentBatchTracker?.cancelAll()
        for (id, task) in transferTasks {
            task.cancel()
            if var cancelledTransfer = activeTransfers.removeValue(forKey: id) {
                cancelledTransfer.status = .cancelled
                recentTransfers.insert(cancelledTransfer, at: 0)
            }
        }
        for (_, var cancelledTransfer) in activeTransfers {
            cancelledTransfer.status = .cancelled
            recentTransfers.insert(cancelledTransfer, at: 0)
        }
        activeTransfers.removeAll()
        if recentTransfers.count > 30 {
            recentTransfers = Array(recentTransfers.prefix(30))
        }
        transferTasks.removeAll()
    }

    // MARK: - Drag and Drop

    /// Downloads a file to a specific URL (used for drag-out file promises)
    func downloadFileToURL(_ file: RemoteFile, destinationURL: URL) async throws {
        let transferId = UUID()
        let transfer = TransferProgress(
            id: transferId,
            fileName: file.name,
            localURL: destinationURL,
            remotePath: file.path,
            bytesTransferred: 0,
            totalBytes: file.size,
            transferType: .download,
            status: .inProgress
        )
        activeTransfers[transferId] = transfer
        isShowingTransfersPopover = true

        let throttler = SingleTransferThrottler(interval: 0.1)

        do {
            try await fileRepository.download(remotePath: file.path, to: destinationURL) { [weak self] bytesTransferred in
                guard let self else { return }
                if throttler.shouldUpdate() {
                    Task { @MainActor in
                        guard self.activeTransfers[transferId] != nil else { return }
                        self.activeTransfers[transferId]?.bytesTransferred = bytesTransferred
                    }
                }
            }

            if var completedTransfer = activeTransfers.removeValue(forKey: transferId) {
                completedTransfer.status = .completed
                completedTransfer.bytesTransferred = file.size
                recentTransfers.insert(completedTransfer, at: 0)
                if recentTransfers.count > 10 {
                    recentTransfers = Array(recentTransfers.prefix(10))
                }
            }

            AnalyticsService.trackFileDownloaded(protocol: .init(from: connection.connectionType), fileCount: 1, totalBytes: file.size)
            logInfo("Downloaded via drag: \(file.name)", category: connection.connectionType == .s3 ? .s3 : .sftp)
        } catch {
            if var failedTransfer = activeTransfers.removeValue(forKey: transferId) {
                failedTransfer.status = .failed
                failedTransfer.error = error.localizedDescription
                recentTransfers.insert(failedTransfer, at: 0)
            }
            throw error
        }
    }

    /// Uploads files dropped from Finder into the current directory
    func uploadDroppedFiles(_ urls: [URL]) async {
        await uploadURLs(urls)
    }

    /// Clears completed/failed transfers from the list
    func clearCompletedTransfers() {
        currentBatchTracker?.clearCompleted()
        recentTransfers.removeAll()
        if activeBatch?.status == .completed || activeBatch?.status == .cancelled || activeBatch?.status == .failed {
            activeBatch = nil
        }
    }

    /// Removes a specific transfer from the recent list
    func removeTransfer(_ transfer: TransferProgress) {
        currentBatchTracker?.removeRecent(id: transfer.id)
        recentTransfers.removeAll { $0.id == transfer.id }
    }

    /// Registers a transfer and optionally its Task for tracking and cancellation
    func trackTransfer(_ transfer: TransferProgress, task: Task<Void, Never>? = nil) {
        activeTransfers[transfer.id] = transfer
        if let task = task {
            transferTasks[transfer.id] = task
        }
        isShowingTransfersPopover = true
    }

    /// Updates bytes transferred for an active transfer
    func updateTransferProgress(id: UUID, bytesTransferred: Int64) {
        guard activeTransfers[id] != nil else { return }
        activeTransfers[id]?.bytesTransferred = bytesTransferred
    }

    /// Marks a transfer as completed and moves it to recent transfers
    func completeTransfer(id: UUID, totalBytes: Int64) {
        if var completedTransfer = activeTransfers.removeValue(forKey: id) {
            completedTransfer.status = .completed
            completedTransfer.bytesTransferred = totalBytes
            recentTransfers.insert(completedTransfer, at: 0)
            if recentTransfers.count > 30 {
                recentTransfers = Array(recentTransfers.prefix(30))
            }
        }
        transferTasks.removeValue(forKey: id)
    }

    /// Marks a transfer as failed or cancelled
    func failTransfer(id: UUID, error: Error?, isCancelled: Bool) {
        if var transfer = activeTransfers.removeValue(forKey: id) {
            transfer.status = isCancelled ? .cancelled : .failed
            transfer.error = isCancelled ? nil : error?.localizedDescription
            recentTransfers.insert(transfer, at: 0)
            if recentTransfers.count > 30 {
                recentTransfers = Array(recentTransfers.prefix(30))
            }
        }
        transferTasks.removeValue(forKey: id)
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
        let windowId = WindowManager.shared.storeFileInfoData(data)
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
            privateKeyPath: connection.privateKeyPath,
            securityScopedBookmarkData: connection.securityScopedBookmarkData,
            connectionType: connection.connectionType,
            s3Region: connection.s3Region,
            s3Bucket: connection.s3Bucket,
            s3Endpoint: connection.s3Endpoint
        )
        let windowId = WindowManager.shared.storeFileEditorData(data)
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
        if isShowingQuickLook {
            isShowingQuickLook = false
            quickLookTask?.cancel()
        } else {
            if let file = primarySelectedFile {
                showQuickLook(for: file)
            }
        }
    }

    /// Opens the Quick Look panel for a specific file.
    func showQuickLook(for file: RemoteFile) {
        isShowingQuickLook = true

        // If already showing this file, no-op
        if quickLookFile?.id == file.id { return }

        quickLookFile = file
        quickLookTask?.cancel()

        // Check cache first
        if let cached = quickLookCache[file.path] {
            quickLookContent = cached
            return
        }

        quickLookContent = .loading
        quickLookTask = Task { @MainActor in
            await loadQuickLookContent(for: file)
        }
    }

    /// Loads content for the given file and caches the result.
    private func loadQuickLookContent(for file: RemoteFile) async {
        // Directories and large files → metadata only
        if file.isDirectory || file.size > FileOperationConstants.maxFilePreviewSize {
            let result = QuickLookContent.unsupported
            quickLookCache[file.path] = result
            if quickLookFile?.id == file.id {
                quickLookContent = result
            }
            return
        }

        let fileType = file.fileType
        do {
            switch fileType {
            case .image:
                // Download to a temp location then read Data
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "_" + file.name)
                try await fileRepository.download(remotePath: file.path, to: tempURL) { _ in }
                let data = try Data(contentsOf: tempURL)
                try? FileManager.default.removeItem(at: tempURL)
                let result = QuickLookContent.image(data)
                quickLookCache[file.path] = result
                if !Task.isCancelled, quickLookFile?.id == file.id {
                    quickLookContent = result
                }

            case .pdf:
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "_" + file.name)
                try await fileRepository.download(remotePath: file.path, to: tempURL) { _ in }
                let data = try Data(contentsOf: tempURL)
                try? FileManager.default.removeItem(at: tempURL)
                let result = QuickLookContent.pdf(data)
                quickLookCache[file.path] = result
                if !Task.isCancelled, quickLookFile?.id == file.id {
                    quickLookContent = result
                }

            case .text, .code, .configuration:
                let content = try await fileRepository.readFileContent(at: file.path)
                let result = QuickLookContent.text(content)
                quickLookCache[file.path] = result
                if !Task.isCancelled, quickLookFile?.id == file.id {
                    quickLookContent = result
                }

            default:
                let result = QuickLookContent.unsupported
                quickLookCache[file.path] = result
                if !Task.isCancelled, quickLookFile?.id == file.id {
                    quickLookContent = result
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            let result = QuickLookContent.error(error.localizedDescription)
            quickLookCache[file.path] = result
            if quickLookFile?.id == file.id {
                quickLookContent = result
            }
        }
    }

    /// Closes the Quick Look panel.
    func closeQuickLook() {
        isShowingQuickLook = false
        quickLookTask?.cancel()
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
