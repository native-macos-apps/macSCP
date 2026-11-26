//
//  TerminalStatusBar.swift
//  macSCP
//
//  Status bar for the integrated SSH terminal (mirrors EditorStatusBar).
//

import SwiftUI

struct TerminalStatusBar: View {
    @Bindable var viewModel: TerminalViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Endpoint & optional initial path
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(viewModel.endpointDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let initialPath = viewModel.initialPath, !initialPath.isEmpty {
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(initialPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Grid dimensions
            Text(viewModel.dimensionsDisplay)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)

            // Font zoom controls
            HStack(spacing: 4) {
                Button {
                    viewModel.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.fontSize <= TerminalViewModel.minFontSize)
                .help("Decrease Font Size (⌘-)")

                Text("\(Int(viewModel.fontSize))pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28)

                Button {
                    viewModel.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.fontSize >= TerminalViewModel.maxFontSize)
                .help("Increase Font Size (⌘+)")
            }

            Divider()
                .frame(height: 12)

            // Connection status indicator
            HStack(spacing: 5) {
                if viewModel.connectionState.isConnecting {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }

                Text(viewModel.connectionState.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Clear & Reconnect actions
            HStack(spacing: 6) {
                Button {
                    viewModel.clearScreen()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Clear Terminal (⌘K)")

                Button {
                    Task {
                        await viewModel.reconnect()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.connectionState.isConnecting)
                .help("Reconnect")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }

    private var statusColor: Color {
        switch viewModel.connectionState {
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .disconnected:
            return .orange
        case .failed:
            return .red
        }
    }
}
