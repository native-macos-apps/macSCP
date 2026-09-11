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
