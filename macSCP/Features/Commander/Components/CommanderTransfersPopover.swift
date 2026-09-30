//
//  CommanderTransfersPopover.swift
//  macSCP
//
//  Global transfers popover for the Commander window
//

import SwiftUI

struct CommanderTransfersPopover: View {
    @Bindable var viewModel: CommanderViewModel

    private var allTransfersList: [TransferProgress] {
        let active = viewModel.allActiveTransfers
        let recent = viewModel.allRecentTransfers
        let recentIds = Set(recent.map { $0.id })
        let extraFailed = (viewModel.currentActiveBatch?.failedTransfers ?? []).filter { !recentIds.contains($0.id) }
        return Array((active + extraFailed + recent).prefix(60))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let batch = viewModel.currentActiveBatch {
                BatchTransferHeaderView(
                    batch: batch,
                    activeCount: viewModel.allActiveTransfers.count,
                    onCancel: {
                        viewModel.cancelBatch()
                    },
                    onRetryFailed: {
                        Task { await viewModel.retryFailedTransfers() }
                    },
                    onClear: {
                        viewModel.clearCompletedTransfers()
                    }
                )
                Divider()
            }

            if allTransfersList.isEmpty && viewModel.currentActiveBatch == nil {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(allTransfersList) { transfer in
                            TransferItemView(
                                transfer: transfer,
                                onCancel: {
                                    cancelTransfer(transfer)
                                },
                                onRemove: {
                                    removeTransfer(transfer)
                                }
                            )

                            if transfer.id != allTransfersList.last?.id {
                                Divider()
                                    .padding(.leading, 54)
                            }
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Transfers")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            if viewModel.hasActiveTransfers {
                Button("Cancel All") {
                    viewModel.cancelBatch()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.red)
            }

            if !viewModel.allRecentTransfers.isEmpty || (viewModel.currentActiveBatch != nil && !(viewModel.currentActiveBatch?.isInProgress ?? false)) {
                Button("Clear") {
                    viewModel.clearCompletedTransfers()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)

            Text("No transfers")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func cancelTransfer(_ transfer: TransferProgress) {
        viewModel.leftPane.browserViewModel?.cancelTransfer(transfer)
        viewModel.rightPane.browserViewModel?.cancelTransfer(transfer)
    }

    private func removeTransfer(_ transfer: TransferProgress) {
        viewModel.removeTransfer(transfer)
    }
}
