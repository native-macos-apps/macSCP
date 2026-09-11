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

/// Bundled batch progress data to dispatch to @MainActor at rate-limited intervals (~15fps)
struct BatchProgressUpdate: Sendable {
    let completedFiles: Int
    let transferredBytes: Int64
    let completedTransfers: [TransferProgress]
    let topLevelFiles: [RemoteFile]
}

/// Thread-safe tracker that aggregates transfer progress across parallel streams
/// and throttles UI dispatches to keep the MainActor and SwiftUI rendering fluid (~15fps).
final class BatchProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    let totalFiles: Int
    let totalBytes: Int64
    private(set) var completedFiles: Int = 0
    private(set) var completedBytes: Int64 = 0
    private var activeBytes: [UUID: Int64] = [:]
    private var pendingCompletedTransfers: [TransferProgress] = []
    private var pendingTopLevelFiles: [RemoteFile] = []
    private var lastUIUpdateTime: CFAbsoluteTime = 0
    private let minUIUpdateInterval: CFAbsoluteTime = 0.066 // ~15 fps

    init(totalFiles: Int, totalBytes: Int64) {
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
    }

    func registerActive(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        activeBytes[id] = 0
    }

    func updateActiveBytes(id: UUID, bytes: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        activeBytes[id] = bytes
        return checkShouldUpdateUI(force: false)
    }

    func completeFile(
        id: UUID,
        fileSize: Int64,
        completedTransfer: TransferProgress? = nil,
        topLevelFile: RemoteFile? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        completedFiles += 1
        completedBytes += fileSize
        activeBytes.removeValue(forKey: id)
        if let transfer = completedTransfer {
            pendingCompletedTransfers.append(transfer)
        }
        if let topFile = topLevelFile {
            pendingTopLevelFiles.append(topFile)
        }
        return checkShouldUpdateUI(force: completedFiles >= totalFiles)
    }

    func failOrCancelFile(
        id: UUID,
        fileSize: Int64,
        failedTransfer: TransferProgress? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        completedFiles += 1
        completedBytes += fileSize
        activeBytes.removeValue(forKey: id)
        if let transfer = failedTransfer {
            pendingCompletedTransfers.append(transfer)
        }
        return checkShouldUpdateUI(force: completedFiles >= totalFiles)
    }

    private func checkShouldUpdateUI(force: Bool) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if force || (now - lastUIUpdateTime) >= minUIUpdateInterval {
            lastUIUpdateTime = now
            return true
        }
        return false
    }

    func drainPendingUpdates() -> BatchProgressUpdate {
        lock.lock()
        defer { lock.unlock() }
        let currentActive = activeBytes.values.reduce(0, +)
        let totalTransferred = min(totalBytes, completedBytes + currentActive)
        let transfers = pendingCompletedTransfers
        let topFiles = pendingTopLevelFiles
        pendingCompletedTransfers.removeAll(keepingCapacity: true)
        pendingTopLevelFiles.removeAll(keepingCapacity: true)
        return BatchProgressUpdate(
            completedFiles: completedFiles,
            transferredBytes: totalTransferred,
            completedTransfers: transfers,
            topLevelFiles: topFiles
        )
    }

    func drainFinal() -> BatchProgressUpdate {
        lock.lock()
        defer { lock.unlock() }
        activeBytes.removeAll()
        let totalTransferred = min(totalBytes, completedBytes)
        let transfers = pendingCompletedTransfers
        let topFiles = pendingTopLevelFiles
        pendingCompletedTransfers.removeAll()
        pendingTopLevelFiles.removeAll()
        return BatchProgressUpdate(
            completedFiles: completedFiles,
            transferredBytes: totalTransferred,
            completedTransfers: transfers,
            topLevelFiles: topFiles
        )
    }
}
