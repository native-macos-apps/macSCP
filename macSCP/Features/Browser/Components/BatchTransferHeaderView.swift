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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)

                Text(batch.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(batch.title)

                Spacer(minLength: 4)

                Text("\(Int(batch.fractionCompleted * 100))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(statusColor)
                    .fixedSize()

                if batch.isInProgress {
                    Button("Cancel Batch") {
                        onCancel()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize()
                } else if batch.hasFailures, let onRetryFailed {
                    Button("Retry Failed", action: onRetryFailed)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                        .fixedSize()
                }
            }

            Text(progressSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if batch.isInProgress {
                ProgressView(value: batch.fractionCompleted)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(statusColor)
                    .accessibilityLabel("Batch progress")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.06))
    }

    private var progressSummary: String {
        var parts = [batch.progressText]
        if batch.isInProgress && activeCount > 0 {
            parts.append("\(activeCount) active")
        }
        if batch.isInProgress && batch.queuedFiles > 0 {
            parts.append("\(batch.queuedFiles) queued")
        }
        return parts.joined(separator: " • ")
    }
}
