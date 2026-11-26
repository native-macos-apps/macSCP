//
//  BatchTransferCoordinator.swift
//  macSCP
//
//  Unified batch transfer coordinator providing bounded concurrency,
//  cancellation propagation, parent-directory dependency checks, and application-level retry.
//

import Foundation
import os

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
        transferType: TransferType = .upload,
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
        let failedItemsLock = OSAllocatedUnfairLock<[TransferQueueItem]>(initialState: [])
        var itemIndex = 0

        await withTaskGroup(of: Void.self) { group in
            let total = items.count
            let initialCount = min(concurrency, total)

            while itemIndex < initialCount {
                let item = items[itemIndex]
                itemIndex += 1
                group.addTask {
                    let succeeded = await self.transferSingleItemWithRetry(
                        item: item,
                        transferType: transferType,
                        directoryManager: directoryManager,
                        retryPolicy: retryPolicy,
                        tracker: tracker,
                        executor: executor,
                        onUpdate: onUpdate,
                        onError: onError
                    )
                    if !succeeded && !tracker.isBatchCancelled {
                        failedItemsLock.withLock { $0.append(item) }
                    }
                }
            }

            for await _ in group {
                if Task.isCancelled || tracker.isBatchCancelled {
                    // Halt scheduling new files; active workers will receive cancellation
                    break
                }
                if itemIndex < total {
                    let nextItem = items[itemIndex]
                    itemIndex += 1
                    group.addTask {
                        let succeeded = await self.transferSingleItemWithRetry(
                            item: nextItem,
                            transferType: transferType,
                            directoryManager: directoryManager,
                            retryPolicy: retryPolicy,
                            tracker: tracker,
                            executor: executor,
                            onUpdate: onUpdate,
                            onError: onError
                        )
                        if !succeeded && !tracker.isBatchCancelled {
                            failedItemsLock.withLock { $0.append(nextItem) }
                        }
                    }
                }
            }
        }

        // 3. If batch or task was cancelled, mark all remaining queued items as cancelled
        let isCancelled = tracker.isBatchCancelled || Task.isCancelled
        if isCancelled {
            let scheduledIndex = itemIndex
            if scheduledIndex < items.count {
                for item in items[scheduledIndex...] {
                    let transfer = TransferProgress(
                        id: item.id,
                        fileName: item.displayName,
                        localURL: item.localURL,
                        remotePath: item.remotePath,
                        bytesTransferred: 0,
                        totalBytes: item.fileSize,
                        transferType: transferType,
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

        let failedItems = failedItemsLock.withLock { $0 }

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
        transferType: TransferType,
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
            transferType: transferType,
            status: .inProgress,
            isDirectory: false,
            itemCount: 1,
            maxRetries: retryPolicy.maxRetries
        )

        // Thread-safe cancellation state shared between worker task and UI cancellation callback
        struct CancellationState: Sendable {
            var isCancelled = false
            var cancelAction: (@Sendable () -> Void)?
        }
        let cancellationLock = OSAllocatedUnfairLock(initialState: CancellationState())

        if let snapshot = tracker.registerActive(transfer: transfer, onCancel: {
            let action = cancellationLock.withLock { state -> (@Sendable () -> Void)? in
                state.isCancelled = true
                let action = state.cancelAction
                state.cancelAction = nil
                return action
            }
            action?()
        }) {
            onUpdate(snapshot)
        }

        var attempt = 0
        while true {
            attempt += 1

            let isItemCancelled = cancellationLock.withLock { $0.isCancelled }
            if Task.isCancelled || tracker.isBatchCancelled || isItemCancelled {
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
            let cancelledBeforeStart = cancellationLock.withLock { state -> Bool in
                if state.isCancelled {
                    return true
                }
                state.cancelAction = {
                    transferTask.cancel()
                }
                return false
            }
            if cancelledBeforeStart {
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
                let isCancelled = Task.isCancelled || tracker.isBatchCancelled || error is CancellationError

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
