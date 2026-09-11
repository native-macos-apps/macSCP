//
//  BatchTransferHeaderView.swift
//  macSCP
//
//  Summary banner view for batch folder/multi-file transfers
//

import SwiftUI

struct BatchTransferHeaderView: View {
    let batch: BatchTransferProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.blue)

                Text(batch.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Cancel Batch") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red)
            }

            ProgressView(value: batch.fractionCompleted)
                .progressViewStyle(.linear)
                .tint(.accentColor)

            HStack {
                Text(batch.progressText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(Int(batch.fractionCompleted * 100))%")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.06))
    }
}
