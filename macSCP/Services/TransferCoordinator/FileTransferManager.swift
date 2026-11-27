//
//  FileTransferManager.swift
//  macSCP
//
//  Shared @Observable transfer state and batch snapshot manager for FileBrowserViewModel and CommanderViewModel
//

import Foundation
import Observation

@MainActor
@Observable
final class FileTransferManager {
    static let maxRecentTransfers = 30

    private(set) var activeTransfers: [UUID: TransferProgress] = [:]
    private(set) var recentTransfers: [TransferProgress] = []
    private(set) var lastFailedItems: [TransferQueueItem] = []
    private(set) var isBatchInProgress: Bool = false

    var activeBatch: BatchTransferProgress?
    var isShowingTransfersPopover: Bool = false

    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private var batchScanTask: Task<TransferScan, Error>?
    private var currentBatchTracker: BatchProgressTracker?
    private var lastAppliedSnapshotSequence: UInt64 = 0
    private var isBatchCancelled: Bool = false

    private let coordinator: BatchTransferCoordinator
    private let transferSettings: TransferSettings

    init(
        coordinator: BatchTransferCoordinator = .shared,
        transferSettings: TransferSettings = .shared
    ) {
        self.coordinator = coordinator
        self.transferSettings = transferSettings
    }

    // MARK: - Computed State

    var hasActiveTransfers: Bool {
        !activeTransfers.isEmpty || (activeBatch?.isInProgress ?? false)
    }

    var activeTransferCount: Int {
        if let batch = activeBatch, batch.isInProgress {
            return activeTransfers.count
        }
        return activeTransfers.values.reduce(0) { $0 + ($1.isDirectory ? max($1.itemCount, 1) : 1) }
    }

    var activeTransferBadgeText: String {
        let count = activeTransferCount
        return count > 99 ? "99+" : "\(count)"
    }

    var allTransfers: [TransferProgress] {
        let active = activeTransfers.values.sorted { $0.startTime > $1.startTime }
        let recentIds = Set(recentTransfers.map { $0.id })
        let extraFailed = (activeBatch?.failedTransfers ?? []).filter { !recentIds.contains($0.id) }
        return active + extraFailed + recentTransfers
    }

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

    var isCurrentBatchCancelled: Bool {
        isBatchCancelled
    }

    // MARK: - Single File Download

    /// Starts an asynchronous single-file download tracked in `activeTransfers` and `transferTasks`.
    func startDownload(
        file: RemoteFile,
        to destinationURL: URL,
        repository: FileRepositoryProtocol,
        connectionType: ConnectionType,
        logCategory: LogCategory,
        onError: @escaping @MainActor (AppError) -> Void
    ) {
        let transferId = registerDownloadTransfer(file: file, destinationURL: destinationURL)
        let throttler = SingleTransferThrottler(interval: 0.1)

        let downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await repository.download(remotePath: file.path, to: destinationURL) { [weak self] bytesTransferred in
                    guard let self else { return }
                    if throttler.shouldUpdate() {
                        Task { @MainActor in
                            self.updateTransferProgress(id: transferId, bytesTransferred: bytesTransferred)
                        }
                    }
                }
                try Task.checkCancellation()

                self.completeTransfer(id: transferId, totalBytes: file.size)
                AnalyticsService.trackFileDownloaded(protocol: .init(from: connectionType), fileCount: 1, totalBytes: file.size)
                logInfo("Downloaded: \(file.name)", category: logCategory)
            } catch {
                let isCancellation = error is CancellationError || Task.isCancelled
                self.failTransfer(id: transferId, error: error, isCancelled: isCancellation)
                if isCancellation {
                    logInfo("Download cancelled: \(file.name)", category: logCategory)
                } else {
                    logError("Download failed: \(error)", category: logCategory)
                    onError(AppError.from(error))
                }
            }
        }

        transferTasks[transferId] = downloadTask
    }

    /// Awaits a single-file download to a specific URL (e.g., Finder drag-out promise), rethrowing errors.
    func downloadToURL(
        file: RemoteFile,
        destinationURL: URL,
        repository: FileRepositoryProtocol,
        connectionType: ConnectionType,
        logCategory: LogCategory
    ) async throws {
        let transferId = registerDownloadTransfer(file: file, destinationURL: destinationURL)
        let throttler = SingleTransferThrottler(interval: 0.1)

        do {
            try await repository.download(remotePath: file.path, to: destinationURL) { [weak self] bytesTransferred in
                guard let self else { return }
                if throttler.shouldUpdate() {
                    Task { @MainActor in
                        self.updateTransferProgress(id: transferId, bytesTransferred: bytesTransferred)
                    }
                }
            }

            completeTransfer(id: transferId, totalBytes: file.size)
            AnalyticsService.trackFileDownloaded(protocol: .init(from: connectionType), fileCount: 1, totalBytes: file.size)
            logInfo("Downloaded via drag: \(file.name)", category: logCategory)
        } catch {
            let isCancellation = error is CancellationError || Task.isCancelled
            failTransfer(id: transferId, error: error, isCancelled: isCancellation)
            throw error
        }
    }

    private func registerDownloadTransfer(file: RemoteFile, destinationURL: URL) -> UUID {
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
        return transferId
    }

    // MARK: - Batch Execution & Snapshots

    func beginBatchSession() -> Bool {
        guard !isBatchInProgress else { return false }
        isBatchInProgress = true
        isBatchCancelled = false
        lastAppliedSnapshotSequence = 0
        isShowingTransfersPopover = true
        return true
    }

    func endBatchSession() {
        isBatchInProgress = false
    }

    func prepareScan(_ scan: @escaping @Sendable () async throws -> TransferScan) async throws -> TransferScan {
        let task = Task { try await scan() }
        batchScanTask = task
        defer { batchScanTask = nil }

        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        if isCurrentBatchCancelled { throw CancellationError() }
        return result
    }

    func executeBatch(
        title: String,
        items: [TransferQueueItem],
        directoriesToCreate: [String],
        repository: FileRepositoryProtocol,
        transferType: TransferType,
        initialRecent: [TransferProgress]? = nil,
        executor: @escaping BatchTransferCoordinator.TransferExecutor,
        onSnapshot: @escaping @MainActor (BatchProgressSnapshot) -> Void,
        onError: @escaping @MainActor (AppError) -> Void
    ) async -> BatchExecutionResult {
        let totalFilesCount = items.count
        let totalBytesSum = items.reduce(0) { $0 + $1.fileSize }
        let batchId = UUID()

        self.lastAppliedSnapshotSequence = 0
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
            initialRecent: initialRecent ?? recentTransfers
        )
        self.currentBatchTracker = tracker

        let maxConcurrent = transferSettings.maxConcurrentTransfers
        let result = await coordinator.executeBatch(
            items: items,
            directoriesToCreate: directoriesToCreate,
            repository: repository,
            maxConcurrent: maxConcurrent,
            transferType: transferType,
            retryPolicy: .default,
            tracker: tracker,
            executor: executor,
            onUpdate: { snapshot in
                Task { @MainActor in
                    onSnapshot(snapshot)
                }
            },
            onError: { appError in
                Task { @MainActor in
                    onError(appError)
                }
            }
        )

        self.lastFailedItems = result.failedItems
        self.currentBatchTracker = nil
        return result
    }

    /// Applies an atomic throttled snapshot from `BatchProgressTracker`, discarding stale or out-of-order snapshots.
    @discardableResult
    func applyBatchSnapshot(
        _ snapshot: BatchProgressSnapshot,
        updateTransferLists: Bool = true
    ) -> Bool {
        if let batch = self.activeBatch, batch.id != snapshot.batchId {
            return false
        }
        guard snapshot.sequence > self.lastAppliedSnapshotSequence else {
            return false
        }
        self.lastAppliedSnapshotSequence = snapshot.sequence

        if updateTransferLists {
            self.activeTransfers = snapshot.activeTransfers
            self.recentTransfers = Array(snapshot.recentTransfers.prefix(Self.maxRecentTransfers))
        }

        if var batch = self.activeBatch {
            batch.completedFiles = snapshot.completedFiles
            batch.failedFiles = snapshot.failedFiles
            batch.cancelledFiles = snapshot.cancelledFiles
            batch.queuedFiles = snapshot.queuedFiles
            batch.completedBytes = snapshot.completedBytes
            batch.transferredBytes = snapshot.transferredBytes
            batch.failedTransfers = snapshot.failedTransfers
            batch.directoryErrors = snapshot.directoryErrors
            if snapshot.isFinal {
                if self.isBatchCancelled || (snapshot.cancelledFiles > 0 && snapshot.completedFiles == 0 && snapshot.failedFiles == 0) {
                    batch.status = .cancelled
                } else if snapshot.failedFiles > 0 || !snapshot.failedTransfers.isEmpty || !snapshot.directoryErrors.isEmpty {
                    batch.status = .failed
                } else {
                    batch.status = .completed
                }
            }
            self.activeBatch = batch
        }

        return true
    }

    // MARK: - Cancellation & Cleanup

    func cancelBatch() {
        isBatchCancelled = true
        activeBatch?.status = .cancelled
        currentBatchTracker?.cancelAll()
        cancelAllTransfers()
    }

    func cancelTransfer(_ transfer: TransferProgress) {
        guard transfer.isInProgress else { return }
        currentBatchTracker?.cancelTransfer(id: transfer.id)
        transferTasks[transfer.id]?.cancel()

        if var cancelledTransfer = activeTransfers.removeValue(forKey: transfer.id) {
            cancelledTransfer.status = .cancelled
            appendRecentTransfer(cancelledTransfer)
        }
        transferTasks.removeValue(forKey: transfer.id)
    }

    func cancelAllTransfers() {
        isBatchCancelled = true
        batchScanTask?.cancel()
        activeBatch?.status = .cancelled
        currentBatchTracker?.cancelAll()

        for (id, task) in transferTasks {
            task.cancel()
            if var cancelledTransfer = activeTransfers.removeValue(forKey: id) {
                cancelledTransfer.status = .cancelled
                appendRecentTransfer(cancelledTransfer)
            }
        }
        for (_, var cancelledTransfer) in activeTransfers {
            cancelledTransfer.status = .cancelled
            appendRecentTransfer(cancelledTransfer)
        }
        activeTransfers.removeAll()
        transferTasks.removeAll()
    }

    func clearCompletedTransfers() {
        currentBatchTracker?.clearCompleted()
        recentTransfers.removeAll()
        if activeBatch?.status == .completed || activeBatch?.status == .cancelled || activeBatch?.status == .failed {
            activeBatch = nil
        }
    }

    func removeTransfer(_ transfer: TransferProgress) {
        currentBatchTracker?.removeRecent(id: transfer.id)
        recentTransfers.removeAll { $0.id == transfer.id }
    }

    // MARK: - Manual Transfer Tracking

    func trackTransfer(_ transfer: TransferProgress, task: Task<Void, Never>? = nil) {
        activeTransfers[transfer.id] = transfer
        if let task {
            transferTasks[transfer.id] = task
        }
        isShowingTransfersPopover = true
    }

    func updateTransferProgress(id: UUID, bytesTransferred: Int64) {
        guard activeTransfers[id] != nil else { return }
        activeTransfers[id]?.bytesTransferred = bytesTransferred
    }

    func completeTransfer(id: UUID, totalBytes: Int64) {
        if var completedTransfer = activeTransfers.removeValue(forKey: id) {
            completedTransfer.status = .completed
            completedTransfer.bytesTransferred = totalBytes
            appendRecentTransfer(completedTransfer)
        }
        transferTasks.removeValue(forKey: id)
    }

    func failTransfer(id: UUID, error: Error?, isCancelled: Bool) {
        if var transfer = activeTransfers.removeValue(forKey: id) {
            transfer.status = isCancelled ? .cancelled : .failed
            transfer.error = isCancelled ? nil : error?.localizedDescription
            appendRecentTransfer(transfer)
        }
        transferTasks.removeValue(forKey: id)
    }

    private func appendRecentTransfer(_ transfer: TransferProgress) {
        recentTransfers.insert(transfer, at: 0)
        if recentTransfers.count > Self.maxRecentTransfers {
            recentTransfers = Array(recentTransfers.prefix(Self.maxRecentTransfers))
        }
    }
}
