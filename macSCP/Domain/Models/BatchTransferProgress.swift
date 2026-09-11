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
    var totalBytes: Int64
    var completedBytes: Int64
    var transferredBytes: Int64
    var status: TransferStatus

    init(
        id: UUID = UUID(),
        title: String,
        totalFiles: Int,
        completedFiles: Int = 0,
        totalBytes: Int64,
        completedBytes: Int64 = 0,
        transferredBytes: Int64 = 0,
        status: TransferStatus = .inProgress
    ) {
        self.id = id
        self.title = title
        self.totalFiles = totalFiles
        self.completedFiles = completedFiles
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.transferredBytes = transferredBytes
        self.status = status
    }

    var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(1.0, max(0.0, Double(transferredBytes) / Double(totalBytes)))
        }
        if totalFiles > 0 {
            return min(1.0, max(0.0, Double(completedFiles) / Double(totalFiles)))
        }
        return 0.0
    }

    var isInProgress: Bool {
        status == .inProgress
    }

    var progressText: String {
        let filesText = "\(completedFiles) of \(totalFiles) files"
        if totalBytes > 0 {
            let transferred = ByteCountFormatter.string(fromByteCount: transferredBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(filesText) • \(transferred) / \(total)"
        }
        return filesText
    }
}

/// Bundled batch progress snapshot dispatched to @MainActor at rate-limited intervals (~10fps / 0.1s).
/// Contains the atomic snapshot of active and recently completed transfers.
struct BatchProgressSnapshot: Sendable {
    let completedFiles: Int
    let completedBytes: Int64
    let totalFiles: Int
    let totalBytes: Int64
    let transferredBytes: Int64
    let activeTransfers: [UUID: TransferProgress]
    let recentTransfers: [TransferProgress]
    let topLevelFiles: [RemoteFile]
}

/// Thread-safe tracker that aggregates transfer progress across parallel streams
/// and throttles UI dispatches to keep the MainActor and SwiftUI rendering fluid (100ms / 10fps).
final class BatchProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    let totalFiles: Int
    let totalBytes: Int64
    private(set) var completedFiles: Int = 0
    private(set) var completedBytes: Int64 = 0

    private var activeTransfers: [UUID: TransferProgress] = [:]
    private var recentTransfers: [TransferProgress] = []
    private var pendingTopLevelFiles: [RemoteFile] = []
    private var cancellationHandlers: [UUID: () -> Void] = [:]

    private var lastUIUpdateTime: CFAbsoluteTime = 0
    private let minUIUpdateInterval: CFAbsoluteTime = 0.1 // 100ms (0.1s)

    init(totalFiles: Int, totalBytes: Int64, initialRecent: [TransferProgress] = []) {
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.recentTransfers = initialRecent
    }

    /// Registers a transfer as active. Returns a snapshot if UI should be updated.
    func registerActive(
        transfer: TransferProgress,
        onCancel: (() -> Void)? = nil
    ) -> BatchProgressSnapshot? {
        lock.lock()
        defer { lock.unlock() }
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
        let isLastFile = completedFiles >= totalFiles
        return checkShouldUpdateUI(force: isLastFile)
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
        if var transfer = activeTransfers.removeValue(forKey: id) {
            transfer.status = isCancelled ? .cancelled : .failed
            transfer.error = isCancelled ? nil : error?.localizedDescription
            recentTransfers.insert(transfer, at: 0)
            if recentTransfers.count > 30 {
                recentTransfers = Array(recentTransfers.prefix(30))
            }
        }
        cancellationHandlers.removeValue(forKey: id)
        completedFiles += 1
        completedBytes += totalBytes
        let isLastFile = completedFiles >= totalFiles
        return checkShouldUpdateUI(force: isLastFile)
    }

    /// Cancels a specific active transfer if tracked
    func cancelTransfer(id: UUID) {
        lock.lock()
        let handler = cancellationHandlers.removeValue(forKey: id)
        lock.unlock()
        handler?()
    }

    /// Cancels all tracked active transfers
    func cancelAll() {
        lock.lock()
        let handlers = Array(cancellationHandlers.values)
        cancellationHandlers.removeAll()
        lock.unlock()
        for handler in handlers {
            handler()
        }
    }

    private func checkShouldUpdateUI(force: Bool) -> BatchProgressSnapshot? {
        let now = CFAbsoluteTimeGetCurrent()
        if force || (now - lastUIUpdateTime) >= minUIUpdateInterval {
            lastUIUpdateTime = now
            return makeSnapshotLocked()
        }
        return nil
    }

    private func makeSnapshotLocked() -> BatchProgressSnapshot {
        let activeBytesSum = activeTransfers.values.reduce(0) { $0 + $1.bytesTransferred }
        let transferred = min(totalBytes, completedBytes + activeBytesSum)
        let topFiles = pendingTopLevelFiles
        pendingTopLevelFiles.removeAll(keepingCapacity: true)
        return BatchProgressSnapshot(
            completedFiles: completedFiles,
            completedBytes: completedBytes,
            totalFiles: totalFiles,
            totalBytes: totalBytes,
            transferredBytes: transferred,
            activeTransfers: activeTransfers,
            recentTransfers: recentTransfers,
            topLevelFiles: topFiles
        )
    }

    /// Takes a final snapshot and clears in-flight state.
    func drainFinal(isCancelled: Bool = false) -> BatchProgressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        cancellationHandlers.removeAll()
        for (_, var transfer) in activeTransfers {
            transfer.status = isCancelled ? .cancelled : .completed
            recentTransfers.insert(transfer, at: 0)
        }
        activeTransfers.removeAll()
        if recentTransfers.count > 30 {
            recentTransfers = Array(recentTransfers.prefix(30))
        }
        if !isCancelled {
            completedFiles = totalFiles
            completedBytes = totalBytes
        }
        let topFiles = pendingTopLevelFiles
        pendingTopLevelFiles.removeAll()
        return BatchProgressSnapshot(
            completedFiles: completedFiles,
            completedBytes: completedBytes,
            totalFiles: totalFiles,
            totalBytes: totalBytes,
            transferredBytes: totalBytes,
            activeTransfers: [:],
            recentTransfers: recentTransfers,
            topLevelFiles: topFiles
        )
    }
}
