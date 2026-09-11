//
//  CommanderTransfersPopover.swift
//  macSCP
//
//  Global transfers popover for the Commander window
//

import SwiftUI

struct CommanderTransfersPopover: View {
    @Bindable var viewModel: CommanderViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let batch = viewModel.currentActiveBatch, batch.isInProgress {
                BatchTransferHeaderView(batch: batch) {
                    viewModel.cancelBatch()
                }
                Divider()
            }

            if viewModel.allActiveTransfers.isEmpty && viewModel.allRecentTransfers.isEmpty && viewModel.currentActiveBatch == nil {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.allActiveTransfers + viewModel.allRecentTransfers) { transfer in
                            TransferItemView(
                                transfer: transfer,
                                onCancel: {
                                    cancelTransfer(transfer)
                                },
                                onRemove: {
                                    removeTransfer(transfer)
                                }
                            )

                            Divider()
                                .padding(.leading, 54)
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
        viewModel.leftPane.browserViewModel?.removeTransfer(transfer)
        viewModel.rightPane.browserViewModel?.removeTransfer(transfer)
    }
}
