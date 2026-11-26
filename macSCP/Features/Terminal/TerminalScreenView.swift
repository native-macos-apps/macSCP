//
//  TerminalScreenView.swift
//  macSCP
//
//  Main integrated SSH terminal view (mirrors FileEditorView).
//

import SwiftUI

struct TerminalScreenView: View {
    @Bindable var viewModel: TerminalViewModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            ZStack(alignment: .bottom) {
                SwiftTermRepresentable(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.connectionState.isConnecting {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Connecting to \(viewModel.endpointDisplay)…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if case .failed(let error) = viewModel.connectionState {
                    statusBanner(
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .red,
                        title: error.localizedDescription,
                        subtitle: error.recoverySuggestion
                    )
                } else if case .disconnected(let exitCode) = viewModel.connectionState {
                    statusBanner(
                        icon: "bolt.slash.fill",
                        iconColor: .orange,
                        title: exitCode.map { "Session closed (exit code \($0))." } ?? "SSH session disconnected.",
                        subtitle: nil
                    )
                }
            }

            Divider()

            TerminalStatusBar(viewModel: viewModel)
        }
        .frame(minWidth: WindowSize.minTerminal.width, minHeight: WindowSize.minTerminal.height)
        .background {
            Group {
                Button("Clear") {
                    viewModel.clearScreen()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Zoom In") {
                    viewModel.zoomIn()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    viewModel.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Zoom") {
                    viewModel.resetZoom()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    @ViewBuilder
    private func statusBanner(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(3)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button("Reconnect") {
                Task {
                    await viewModel.reconnect()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .padding(12)
    }
}
