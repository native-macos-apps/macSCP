//
//  TransferProgress.swift
//  macSCP
//
//  Model for tracking file transfer progress
//

import Foundation

/// Represents the progress of a file transfer operation
struct TransferProgress: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let localURL: URL?
    let remotePath: String
    let totalBytes: Int64
    let startTime: Date
    let transferType: TransferType
    var isDirectory: Bool
    var itemCount: Int

    /// Number of bytes transferred so far
    var bytesTransferred: Int64

    /// Current status of the transfer
    var status: TransferStatus

    /// Error if the transfer failed
    var error: String?

    init(
        id: UUID = UUID(),
        fileName: String,
        localURL: URL? = nil,
        remotePath: String = "",
        bytesTransferred: Int64 = 0,
        totalBytes: Int64,
        transferType: TransferType = .upload,
        status: TransferStatus = .inProgress,
        startTime: Date = Date(),
        isDirectory: Bool = false,
        itemCount: Int = 1
    ) {
        self.id = id
        self.fileName = fileName
        self.localURL = localURL
        self.remotePath = remotePath
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.transferType = transferType
        self.status = status
        self.startTime = startTime
        self.isDirectory = isDirectory
        self.itemCount = itemCount
    }

    /// Progress as a fraction (0.0 to 1.0)
    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }

    /// Progress as a percentage (0 to 100)
    var percentCompleted: Int {
        Int(fractionCompleted * 100)
    }

    /// Formatted string showing bytes transferred / total bytes
    var progressText: String {
        let transferred = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(transferred) / \(total)"
    }

    /// Whether the transfer is complete
    var isComplete: Bool {
        status == .completed
    }

    /// Whether the transfer is still in progress
    var isInProgress: Bool {
        status == .inProgress
    }

    /// Total size formatted
    var totalSizeText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

/// Status of a transfer operation
enum TransferStatus: Sendable {
    case pending
    case inProgress
    case completed
    case failed
    case cancelled
}

/// Type of transfer
enum TransferType: Sendable {
    case upload
    case download
}

/// Type alias for progress callback - receives bytes transferred
typealias TransferProgressHandler = @Sendable (_ bytesTransferred: Int64) -> Void

/// Thread-safe tracker to accumulate progress across multiple files in a recursive directory transfer
final class CumulativeTransferTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var baseOffset: Int64 = 0
    private var currentFileBytes: Int64 = 0
    private let progress: TransferProgressHandler?

    init(progress: TransferProgressHandler?) {
        self.progress = progress
    }

    func startFile() {
        lock.lock()
        baseOffset += currentFileBytes
        currentFileBytes = 0
        let total = baseOffset
        lock.unlock()
        progress?(total)
    }

    func updateCurrentFile(bytes: Int64) {
        lock.lock()
        currentFileBytes = bytes
        let total = baseOffset + currentFileBytes
        lock.unlock()
        progress?(total)
    }

    func finishFile(size: Int64) {
        lock.lock()
        baseOffset += size
        currentFileBytes = 0
        let total = baseOffset
        lock.unlock()
        progress?(total)
    }
}
