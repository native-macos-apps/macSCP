//
//  BatchTransferHeaderView.swift
//  macSCP
//
//  Summary banner view for batch folder/multi-file transfers with detailed stats and result actions
//

import SwiftUI

struct BatchTransferHeaderView: View {
    let batch: BatchTransferProgress
    var activeCount: Int = 0
    let onCancel: () -> Void
    var onRetryFailed: (() -> Void)? = nil
    var onClear: (() -> Void)? = nil

    private var statusColor: Color {
        switch batch.status {
        case .inProgress:
            return .accentColor
        case .completed:
            return batch.hasFailures ? .orange : .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        default:
            return .accentColor
        }
    }

    private var statusIcon: String {
        switch batch.status {
        case .inProgress:
            return "folder.badge.gearshape"
        case .completed:
            return batch.hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "slash.circle"
        default:
            return "folder.badge.gearshape"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header Row: Icon, Title, Actions
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(statusColor)

                Text(batch.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if batch.isInProgress {
                    Button("Cancel Batch") {
                        onCancel()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                } else {
                    HStack(spacing: 8) {
                        if batch.hasFailures, let onRetryFailed {
                            Button("Retry Failed") {
                                onRetryFailed()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.blue)
                        }

                        if let onClear {
                            Button("Clear") {
                                onClear()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Linear Progress Bar
            ProgressView(value: batch.fractionCompleted)
                .progressViewStyle(.linear)
                .tint(statusColor)

            // Progress Text & Percentage
            HStack {
                Text(batch.progressText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(Int(batch.fractionCompleted * 100))%")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            // Stat Badges: Active, Queued, Completed, Failed
            HStack(spacing: 8) {
                if batch.isInProgress && activeCount > 0 {
                    statBadge(label: "Active", count: activeCount, color: .blue)
                }
                if batch.isInProgress && batch.queuedFiles > 0 {
                    statBadge(label: "Queued", count: batch.queuedFiles, color: .secondary)
                }
                if batch.completedFiles > 0 {
                    statBadge(label: "Done", count: batch.completedFiles, color: .green)
                }
                if batch.failedFiles > 0 {
                    statBadge(label: "Failed", count: batch.failedFiles, color: .red)
                }
                if batch.cancelledFiles > 0 {
                    statBadge(label: "Cancelled", count: batch.cancelledFiles, color: .gray)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(statusColor.opacity(0.06))
    }

    private func statBadge(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text("\(label): \(count)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
