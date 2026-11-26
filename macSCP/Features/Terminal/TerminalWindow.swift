//
//  TerminalWindow.swift
//  macSCP
//
//  Window wrapper for the integrated SSH terminal (mirrors FileEditorWindow).
//

import SwiftUI

struct TerminalWindow: View {
    let windowId: String
    @State private var viewModel: TerminalViewModel?
    @State private var showMissingDataError = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if showMissingDataError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Session Expired")
                        .font(.headline)
                    Text("This terminal's session data was lost. Please reopen the terminal from the connection list or browser.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Close Window") {
                        dismiss()
                    }
                }
                .padding(32)
            } else if let viewModel = viewModel {
                TerminalScreenView(viewModel: viewModel)
                    .navigationTitle(viewModel.windowTitle)
            } else {
                LoadingView(message: "Starting terminal…")
                    .task {
                        initializeViewModel()
                    }
            }
        }
        .frame(minWidth: WindowSize.minTerminal.width, minHeight: WindowSize.minTerminal.height)
        .onDisappear {
            WindowManager.shared.removeTerminalData(for: windowId)
            let vm = viewModel
            Task {
                await vm?.disconnect()
            }
        }
    }

    @MainActor
    private func initializeViewModel() {
        guard let data = WindowManager.shared.getTerminalData(for: windowId) else {
            logError("No terminal data found for ID: \(windowId)", category: .ui)
            showMissingDataError = true
            return
        }

        let vm = TerminalViewModel(data: data)
        self.viewModel = vm
        Task {
            await vm.connect()
        }
    }
}
