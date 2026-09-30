//
//  BatchTransferProgress.swift
//  macSCP
//
//  Represents progress for a batch transfer (e.g. folder upload or multi-file transfer)
//

import Foundation

struct BatchTransferProgress: Identifiable, Sendable {
    let id: UUID
    var title: String
    var totalFiles: Int
    var completedFiles: Int
    var failedFiles: Int
    var cancelledFiles: Int
    var queuedFiles: Int
    var totalBytes: Int64
    var completedBytes: Int64
    var transferredBytes: Int64
    var status: TransferStatus
    var failedTransfers: [TransferProgress]
    var directoryErrors: [String: String]

    init(
        id: UUID = UUID(),
        title: String,
        totalFiles: Int,
        completedFiles: Int = 0,
        failedFiles: Int = 0,
        cancelledFiles: Int = 0,
        queuedFiles: Int? = nil,
        totalBytes: Int64,
        completedBytes: Int64 = 0,
        transferredBytes: Int64 = 0,
        status: TransferStatus = .inProgress,
        failedTransfers: [TransferProgress] = [],
        directoryErrors: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.totalFiles = totalFiles
        self.completedFiles = completedFiles
        self.failedFiles = failedFiles
        self.cancelledFiles = cancelledFiles
        self.queuedFiles = queuedFiles ?? max(0, totalFiles - (completedFiles + failedFiles + cancelledFiles))
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.transferredBytes = transferredBytes
        self.status = status
        self.failedTransfers = failedTransfers
        self.directoryErrors = directoryErrors
    }

    var fractionCompleted: Double {
        if totalBytes > 0 {
            if status == .completed { return 1.0 }
            if status == .failed || status == .cancelled {
                return min(1.0, max(0.0, Double(completedBytes) / Double(totalBytes)))
            }
            return min(1.0, max(0.0, Double(transferredBytes) / Double(totalBytes)))
        }
        if totalFiles > 0 {
            if status == .completed { return 1.0 }
            return min(1.0, max(0.0, Double(completedFiles) / Double(totalFiles)))
        }
        return 0.0
    }

    var isInProgress: Bool {
        status == .inProgress
    }

    var hasFailures: Bool {
        failedFiles > 0 || !failedTransfers.isEmpty || !directoryErrors.isEmpty
    }

    var progressText: String {
        var fileParts: [String] = []
        if status == .inProgress {
            fileParts.append("\(completedFiles) of \(totalFiles) files")
            if failedFiles > 0 {
                fileParts.append("\(failedFiles) failed")
            }
        } else {
            fileParts.append("\(completedFiles) succeeded")
            if failedFiles > 0 {
                fileParts.append("\(failedFiles) failed")
            }
            if cancelledFiles > 0 {
                fileParts.append("\(cancelledFiles) cancelled")
            }
        }
        let filesSummary = fileParts.joined(separator: ", ")

        if totalBytes > 0 {
            let currentBytes = status == .inProgress ? transferredBytes : completedBytes
            let transferred = ByteCountFormatter.string(fromByteCount: currentBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(filesSummary) • \(transferred) / \(total)"
        }
        return filesSummary
    }

    var summaryText: String {
        var parts: [String] = []
        parts.append("\(completedFiles) succeeded")
        if failedFiles > 0 {
            parts.append("\(failedFiles) failed")
        }
        if cancelledFiles > 0 {
            parts.append("\(cancelledFiles) cancelled")
        }
        return parts.joined(separator: ", ")
    }
}

/// Bundled batch progress snapshot dispatched to @MainActor at rate-limited intervals (~10fps / 0.1s).
/// Contains the atomic snapshot of active and recently completed transfers.
struct BatchProgressSnapshot: Sendable {
    let batchId: UUID
    let sequence: UInt64
    let isFinal: Bool
    let completedFiles: Int
    let failedFiles: Int
    let cancelledFiles: Int
    let queuedFiles: Int
    let completedBytes: Int64
    let totalFiles: Int
    let totalBytes: Int64
    let transferredBytes: Int64
    let activeTransfers: [UUID: TransferProgress]
    let recentTransfers: [TransferProgress]
    let failedTransfers: [TransferProgress]
    let directoryErrors: [String: String]
    let topLevelFiles: [RemoteFile]

    init(
        batchId: UUID,
        sequence: UInt64,
        isFinal: Bool,
        completedFiles: Int,
        failedFiles: Int = 0,
        cancelledFiles: Int = 0,
        queuedFiles: Int? = nil,
        completedBytes: Int64,
        totalFiles: Int,
        totalBytes: Int64,
        transferredBytes: Int64,
        activeTransfers: [UUID: TransferProgress] = [:],
        recentTransfers: [TransferProgress] = [],
        failedTransfers: [TransferProgress] = [],
        directoryErrors: [String: String] = [:],
        topLevelFiles: [RemoteFile] = []
    ) {
        self.batchId = batchId
        self.sequence = sequence
        self.isFinal = isFinal
        self.completedFiles = completedFiles
        self.failedFiles = failedFiles
        self.cancelledFiles = cancelledFiles
        self.queuedFiles = queuedFiles ?? max(0, totalFiles - (completedFiles + failedFiles + cancelledFiles + activeTransfers.count))
        self.completedBytes = completedBytes
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.activeTransfers = activeTransfers
        self.recentTransfers = recentTransfers
        self.failedTransfers = failedTransfers
        self.directoryErrors = directoryErrors
        self.topLevelFiles = topLevelFiles
    }
}

/// Thread-safe tracker that aggregates transfer progress across parallel streams
/// and throttles UI dispatches to keep the MainActor and SwiftUI rendering fluid (100ms / 10fps).
final class BatchProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    let batchId: UUID
    private(set) var totalFiles: Int
    private(set) var totalBytes: Int64
    private(set) var completedFiles: Int = 0
    private(set) var failedFiles: Int = 0
    private(set) var cancelledFiles: Int = 0
    private(set) var completedBytes: Int64 = 0
    private var sequenceNumber: UInt64 = 0

    private var activeTransfers: [UUID: TransferProgress] = [:]
    private var recentTransfers: [TransferProgress] = []
    private var allFailedTransfers: [UUID: TransferProgress] = [:]
    private var directoryErrors: [String: String] = [:]
    private var pendingTopLevelFiles: [RemoteFile] = []
    private var cancellationHandlers: [UUID: () -> Void] = [:]
    private var completedTransferIds: Set<UUID> = []
    private var cancelledTransferIds: Set<UUID> = []
    private var isCancelled: Bool = false

    var isBatchCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    private var lastUIUpdateTime: CFAbsoluteTime = 0
    private let minUIUpdateInterval: CFAbsoluteTime = 0.1 // 100ms (0.1s)

    init(batchId: UUID = UUID(), totalFiles: Int, totalBytes: Int64, initialRecent: [TransferProgress] = []) {
        self.batchId = batchId
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.recentTransfers = initialRecent
    }

    /// Dynamically updates total count & bytes during streaming discovery
    func updateTotals(additionalFiles: Int, additionalBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        totalFiles += additionalFiles
        totalBytes += additionalBytes
    }

    /// Sets the final known total count & bytes after streaming discovery completes
    func setFinalTotals(totalFiles: Int, totalBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
    }

    /// Records a directory creation error
    func recordDirectoryError(path: String, error: String) {
        lock.lock()
        defer { lock.unlock() }
        directoryErrors[path] = error
    }

    /// Registers a transfer as active. Returns a snapshot if UI should be updated.
    func registerActive(
        transfer: TransferProgress,
        onCancel: (() -> Void)? = nil
    ) -> BatchProgressSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        if isCancelled || cancelledTransferIds.contains(transfer.id) {
            cancelledTransferIds.insert(transfer.id)
            cancelledFiles += 1
            var cancelled = transfer
            cancelled.status = .cancelled
            recentTransfers.insert(cancelled, at: 0)
            if recentTransfers.count > 30 {
                recentTransfers = Array(recentTransfers.prefix(30))
            }
            return checkShouldUpdateUI(force: false)
        }

        activeTransfers[transfer.id] = transfer
        if let onCancel {
            cancellationHandlers[transfer.id] = onCancel
        }
        return checkShouldUpdateUI(force: false)
    }

    /// Updates bytes transferred for an active transfer. Returns a snapshot if UI should be updated.
    func updateActiveBytes(id: UUID, bytes: Int64) -> BatchProgressSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard activeTransfers[id] != nil else { return nil }
        activeTransfers[id]?.bytesTransferred = bytes
        return checkShouldUpdateUI(force: false)
    }

    /// Marks a transfer as completed. Returns a snapshot if UI should be updated (forced if last file).
    func completeFile(
        id: UUID,
        totalBytes: Int64,
        topLevelFile: RemoteFile? = nil
    ) -> BatchProgressSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        // Ignore late callbacks if already cancelled or already completed
        guard !cancelledTransferIds.contains(id), !completedTransferIds.contains(id) else {
            return nil
        }

        completedTransferIds.insert(id)
        if var completedTransfer = activeTransfers.removeValue(forKey: id) {
            completedTransfer.status = .completed
            completedTransfer.bytesTransferred = totalBytes
            recentTransfers.insert(completedTransfer, at: 0)
            if recentTransfers.count > 30 {
                recentTransfers = Array(recentTransfers.prefix(30))
            }
        }
        cancellationHandlers.removeValue(forKey: id)
        completedFiles += 1
        completedBytes += totalBytes

        if let topFile = topLevelFile {
            pendingTopLevelFiles.append(topFile)
        }

        let isFinished = (completedFiles + failedFiles + cancelledFiles) >= totalFiles
        return checkShouldUpdateUI(force: isFinished)
    }

    /// Marks a transfer as failed or cancelled. Returns a snapshot if UI should be updated (forced if last file).
    func failOrCancelFile(
        id: UUID,
        totalBytes: Int64,
        error: Error?,
        isCancelled: Bool
    ) -> BatchProgressSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        // Ignore late callbacks if already completed
        guard !completedTransferIds.contains(id) else {
            return nil
        }

        let transferOpt = activeTransfers.removeValue(forKey: id)
        cancellationHandlers.removeValue(forKey: id)

        if isCancelled {
            cancelledTransferIds.insert(id)
            cancelledFiles += 1
            if var transfer = transferOpt {
                transfer.status = .cancelled
                recentTransfers.insert(transfer, at: 0)
            }
        } else {
            failedFiles += 1
            if var transfer = transferOpt {
                transfer.status = .failed
                transfer.error = error?.localizedDescription
                allFailedTransfers[id] = transfer
                recentTransfers.insert(transfer, at: 0)
            }
        }

        if recentTransfers.count > 30 {
            recentTransfers = Array(recentTransfers.prefix(30))
        }

        let isFinished = (completedFiles + failedFiles + cancelledFiles) >= totalFiles
        return checkShouldUpdateUI(force: isFinished)
    }

    /// Cancels a specific active transfer if tracked
    func cancelTransfer(id: UUID) {
        lock.lock()
        cancelledTransferIds.insert(id)
        let handler = cancellationHandlers.removeValue(forKey: id)
        if var transfer = activeTransfers.removeValue(forKey: id) {
            cancelledFiles += 1
            transfer.status = .cancelled
            recentTransfers.insert(transfer, at: 0)
            if recentTransfers.count > 30 {
                recentTransfers = Array(recentTransfers.prefix(30))
            }
        }
        lock.unlock()
        handler?()
    }

    /// Cancels all tracked active transfers
    func cancelAll() {
        lock.lock()
        isCancelled = true
        let handlers = Array(cancellationHandlers.values)
        cancellationHandlers.removeAll()
        lock.unlock()

        for handler in handlers {
            handler()
        }
    }

    /// Clears completed transfers from recentTransfers history. Does NOT touch in-progress active transfers.
    func clearCompleted() {
        lock.lock()
        defer { lock.unlock() }
        recentTransfers.removeAll { $0.status == .completed }
        allFailedTransfers.removeAll()
        directoryErrors.removeAll()
    }

    /// Removes a specific transfer from recentTransfers history.
    func removeRecent(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        recentTransfers.removeAll { $0.id == id }
        allFailedTransfers.removeValue(forKey: id)
    }

    private func checkShouldUpdateUI(force: Bool) -> BatchProgressSnapshot? {
        let now = CFAbsoluteTimeGetCurrent()
        if force || (now - lastUIUpdateTime) >= minUIUpdateInterval {
            lastUIUpdateTime = now
            let isFinal = force && ((completedFiles + failedFiles + cancelledFiles) >= totalFiles)
            return makeSnapshotLocked(isFinal: isFinal)
        }
        return nil
    }

    private func makeSnapshotLocked(isFinal: Bool) -> BatchProgressSnapshot {
        sequenceNumber += 1
        let activeBytesSum = activeTransfers.values.reduce(0) { $0 + $1.bytesTransferred }
        let transferred = min(totalBytes, completedBytes + activeBytesSum)
        let topFiles = pendingTopLevelFiles
        pendingTopLevelFiles.removeAll(keepingCapacity: true)

        let processedFiles = completedFiles + failedFiles + cancelledFiles
        let queued = max(0, totalFiles - (processedFiles + activeTransfers.count))

        return BatchProgressSnapshot(
            batchId: batchId,
            sequence: sequenceNumber,
            isFinal: isFinal,
            completedFiles: completedFiles,
            failedFiles: failedFiles,
            cancelledFiles: cancelledFiles,
            queuedFiles: queued,
            completedBytes: completedBytes,
            totalFiles: totalFiles,
            totalBytes: totalBytes,
            transferredBytes: isFinal ? completedBytes : transferred,
            activeTransfers: activeTransfers,
            recentTransfers: recentTransfers,
            failedTransfers: Array(allFailedTransfers.values),
            directoryErrors: directoryErrors,
            topLevelFiles: topFiles
        )
    }

    /// Takes a final snapshot and clears in-flight state without mutating completed counts into artificial 100%.
    func drainFinal(isCancelled: Bool = false) -> BatchProgressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        cancellationHandlers.removeAll()

        let batchCancelled = isCancelled || self.isCancelled

        for (_, var transfer) in activeTransfers {
            if batchCancelled {
                transfer.status = .cancelled
                cancelledFiles += 1
                cancelledTransferIds.insert(transfer.id)
            } else {
                transfer.status = .failed
                transfer.error = transfer.error ?? "Transfer interrupted"
                failedFiles += 1
                allFailedTransfers[transfer.id] = transfer
            }
            recentTransfers.insert(transfer, at: 0)
        }
        activeTransfers.removeAll()

        if recentTransfers.count > 30 {
            recentTransfers = Array(recentTransfers.prefix(30))
        }

        let topFiles = pendingTopLevelFiles
        pendingTopLevelFiles.removeAll()

        return makeSnapshotLocked(isFinal: true)
    }
}

/// Thread-safe rate limiter for single file transfers (downloads/uploads)
/// to throttle progress callbacks to the UI thread (default: 0.1s / 10fps).
final class SingleTransferThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime: CFAbsoluteTime = 0
    private let interval: CFAbsoluteTime

    init(interval: CFAbsoluteTime = 0.1) {
        self.interval = interval
    }

    func shouldUpdate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTime >= interval {
            lastTime = now
            return true
        }
        return false
    }
}
