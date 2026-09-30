//
//  BatchTransferCoordinator.swift
//  macSCP
//
//  Unified batch transfer coordinator providing bounded concurrency,
//  cancellation propagation, parent-directory dependency checks, and application-level retry.
//

import Foundation

struct BatchExecutionResult: Sendable {
    let completedFiles: Int
    let failedFiles: Int
    let cancelledFiles: Int
    let completedBytes: Int64
    let totalBytes: Int64
    let failedItems: [TransferQueueItem]
    let isCancelled: Bool
}

final class BatchTransferCoordinator: Sendable {
    typealias TransferExecutor = @Sendable (
        _ item: TransferQueueItem,
        _ progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteFile?

    static let shared = BatchTransferCoordinator()

    /// Executes a batch transfer of items with bounded concurrency, retry backoff, and depth-ordered directory management.
    func executeBatch(
        items: [TransferQueueItem],
        directoriesToCreate: [String],
        repository: FileRepositoryProtocol,
        maxConcurrent: Int,
        retryPolicy: TransferRetryPolicy = .default,
        tracker: BatchProgressTracker,
        executor: @escaping TransferExecutor,
        onUpdate: @escaping @Sendable (BatchProgressSnapshot) -> Void,
        onError: (@Sendable (AppError) -> Void)? = nil
    ) async -> BatchExecutionResult {
        // 1. Depth-ordered directory creation with bounded concurrency
        let directoryManager = RemoteDirectoryManager(repository: repository, maxConcurrency: 3)
        let directoryErrors = await directoryManager.createDirectories(directoriesToCreate)
        for (path, err) in directoryErrors {
            tracker.recordDirectoryError(path: path, error: err)
        }

        // Check if batch was cancelled during directory creation
        if tracker.isBatchCancelled || Task.isCancelled {
            let finalSnapshot = tracker.drainFinal(isCancelled: true)
            onUpdate(finalSnapshot)
            return BatchExecutionResult(
                completedFiles: tracker.completedFiles,
                failedFiles: tracker.failedFiles,
                cancelledFiles: tracker.cancelledFiles,
                completedBytes: tracker.completedBytes,
                totalBytes: tracker.totalBytes,
                failedItems: [],
                isCancelled: true
            )
        }

        // 2. Concurrency-bounded worker pool for file transfers
        let concurrency = max(1, min(16, maxConcurrent))
        var failedItems: [TransferQueueItem] = []
        let failedItemsLock = NSLock()

        final class ProgressState: @unchecked Sendable {
            var itemIndex = 0
        }
        let progressState = ProgressState()

        await withTaskGroup(of: Void.self) { group in
            let total = items.count
            let initialCount = min(concurrency, total)

            while progressState.itemIndex < initialCount {
                let item = items[progressState.itemIndex]
                progressState.itemIndex += 1
                group.addTask {
                    let succeeded = await self.transferSingleItemWithRetry(
                        item: item,
                        directoryManager: directoryManager,
                        retryPolicy: retryPolicy,
                        tracker: tracker,
                        executor: executor,
                        onUpdate: onUpdate,
                        onError: onError
                    )
                    if !succeeded && !tracker.isBatchCancelled {
                        failedItemsLock.lock()
                        failedItems.append(item)
                        failedItemsLock.unlock()
                    }
                }
            }

            for await _ in group {
                if Task.isCancelled || tracker.isBatchCancelled {
                    // Halt scheduling new files; active workers will receive cancellation
                    break
                }
                if progressState.itemIndex < total {
                    let nextItem = items[progressState.itemIndex]
                    progressState.itemIndex += 1
                    group.addTask {
                        let succeeded = await self.transferSingleItemWithRetry(
                            item: nextItem,
                            directoryManager: directoryManager,
                            retryPolicy: retryPolicy,
                            tracker: tracker,
                            executor: executor,
                            onUpdate: onUpdate,
                            onError: onError
                        )
                        if !succeeded && !tracker.isBatchCancelled {
                            failedItemsLock.lock()
                            failedItems.append(nextItem)
                            failedItemsLock.unlock()
                        }
                    }
                }
            }
        }

        // 3. If batch or task was cancelled, mark all remaining queued items as cancelled
        let isCancelled = tracker.isBatchCancelled || Task.isCancelled
        if isCancelled {
            let scheduledIndex = progressState.itemIndex
            if scheduledIndex < items.count {
                for item in items[scheduledIndex...] {
                    let transfer = TransferProgress(
                        id: item.id,
                        fileName: item.displayName,
                        localURL: item.localURL,
                        remotePath: item.remotePath,
                        bytesTransferred: 0,
                        totalBytes: item.fileSize,
                        transferType: .upload,
                        status: .cancelled,
                        isDirectory: false,
                        itemCount: 1
                    )
                    _ = tracker.registerActive(transfer: transfer)
                }
            }
        }

        // 4. Drain remaining in-flight state without fabricating 100% completion
        let finalSnapshot = tracker.drainFinal(isCancelled: isCancelled)
        onUpdate(finalSnapshot)

        return BatchExecutionResult(
            completedFiles: tracker.completedFiles,
            failedFiles: tracker.failedFiles,
            cancelledFiles: tracker.cancelledFiles,
            completedBytes: tracker.completedBytes,
            totalBytes: tracker.totalBytes,
            failedItems: failedItems,
            isCancelled: isCancelled
        )
    }

    private func transferSingleItemWithRetry(
        item: TransferQueueItem,
        directoryManager: RemoteDirectoryManager,
        retryPolicy: TransferRetryPolicy,
        tracker: BatchProgressTracker,
        executor: @escaping TransferExecutor,
        onUpdate: @escaping @Sendable (BatchProgressSnapshot) -> Void,
        onError: (@Sendable (AppError) -> Void)?
    ) async -> Bool {
        if Task.isCancelled || tracker.isBatchCancelled {
            if let snapshot = tracker.failOrCancelFile(id: item.id, totalBytes: item.fileSize, error: nil, isCancelled: true) {
                onUpdate(snapshot)
            }
            return false
        }

        // Check parent directory dependency
        if let ancestorError = await directoryManager.failureForAncestor(of: item.remotePath) {
            let error = NSError(
                domain: "com.macSCP.parentDirectoryFailed",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: ancestorError]
            )
            if let snapshot = tracker.failOrCancelFile(id: item.id, totalBytes: item.fileSize, error: error, isCancelled: false) {
                onUpdate(snapshot)
            }
            return false
        }

        let transfer = TransferProgress(
            id: item.id,
            fileName: item.displayName,
            localURL: item.localURL,
            remotePath: item.remotePath,
            bytesTransferred: 0,
            totalBytes: item.fileSize,
            transferType: .upload,
            status: .inProgress,
            isDirectory: false,
            itemCount: 1,
            maxRetries: retryPolicy.maxRetries
        )

        // Cancellation action reference for active transfer
        final class CancellationBox: @unchecked Sendable {
            var cancelAction: (() -> Void)?
        }
        let cancelBox = CancellationBox()

        if let snapshot = tracker.registerActive(transfer: transfer, onCancel: {
            cancelBox.cancelAction?()
        }) {
            onUpdate(snapshot)
        }

        var attempt = 0
        while true {
            attempt += 1

            if Task.isCancelled || tracker.isBatchCancelled {
                if let snapshot = tracker.failOrCancelFile(id: item.id, totalBytes: item.fileSize, error: nil, isCancelled: true) {
                    onUpdate(snapshot)
                }
                return false
            }

            let transferTask = Task<RemoteFile?, Error> {
                try Task.checkCancellation()
                return try await executor(item) { bytesTransferred in
                    if let snapshot = tracker.updateActiveBytes(id: item.id, bytes: bytesTransferred) {
                        onUpdate(snapshot)
                    }
                }
            }
            cancelBox.cancelAction = {
                transferTask.cancel()
            }

            do {
                let remoteFile = try await transferTask.value
                try Task.checkCancellation()

                if let snapshot = tracker.completeFile(id: item.id, totalBytes: item.fileSize, topLevelFile: remoteFile) {
                    onUpdate(snapshot)
                }
                return true
            } catch {
                let isCancelled = Task.isCancelled || tracker.isBatchCancelled || error is CancellationError || String(describing: error).contains("CancellationError")

                if isCancelled {
                    if let snapshot = tracker.failOrCancelFile(id: item.id, totalBytes: item.fileSize, error: nil, isCancelled: true) {
                        onUpdate(snapshot)
                    }
                    return false
                }

                // Check if transient and should retry
                if retryPolicy.shouldRetry(error: error, attempt: attempt) {
                    let delay = retryPolicy.delay(forAttempt: attempt)
                    // Sleep with cancellation support
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    } catch {
                        // Sleep was cancelled
                        if let snapshot = tracker.failOrCancelFile(id: item.id, totalBytes: item.fileSize, error: nil, isCancelled: true) {
                            onUpdate(snapshot)
                        }
                        return false
                    }
                }

                // Permanent failure or max retries exceeded
                if let snapshot = tracker.failOrCancelFile(id: item.id, totalBytes: item.fileSize, error: error, isCancelled: false) {
                    onUpdate(snapshot)
                }
                if let appError = error as? AppError {
                    onError?(appError)
                }
                return false
            }
        }
    }
}
