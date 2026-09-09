//
//  CommanderWorkspaceView.swift
//  macSCP
//
//  Main window workspace view offering Transmit 5 style Dual-Pane Commander experience
//

import SwiftUI

struct CommanderWorkspaceView: View {
    @State private var viewModel: CommanderViewModel

    init(container: DependencyContainer) {
        self._viewModel = State(initialValue: CommanderViewModel(container: container))
    }

    init() {
        self.init(container: DependencyContainer.shared)
    }

    private var canTransferToRight: Bool {
        guard let leftVM = viewModel.leftPane.browserViewModel,
              viewModel.rightPane.browserViewModel != nil else { return false }
        return !leftVM.selectedFiles.isEmpty
    }

    private var canTransferToLeft: Bool {
        guard let rightVM = viewModel.rightPane.browserViewModel,
              viewModel.leftPane.browserViewModel != nil else { return false }
        return !rightVM.selectedFiles.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isDualPane {
                HSplitView {
                    CommanderPaneView(
                        commanderViewModel: viewModel,
                        pane: viewModel.leftPane
                    )
                    .frame(minWidth: 320, maxWidth: .infinity)

                    CommanderPaneView(
                        commanderViewModel: viewModel,
                        pane: viewModel.rightPane
                    )
                    .frame(minWidth: 320, maxWidth: .infinity)
                }
            } else {
                CommanderPaneView(
                    commanderViewModel: viewModel,
                    pane: viewModel.activePane
                )
                .frame(minWidth: 500, maxWidth: .infinity)
            }
        }
        .frame(minWidth: WindowSize.minCommander.width, minHeight: WindowSize.minCommander.height)
        .toolbar {
            // View Mode Toggle (Dual-Pane vs Single-Pane)
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.isDualPane.toggle()
                    }
                } label: {
                    Label(
                        viewModel.isDualPane ? "Single Pane" : "Dual Pane",
                        systemImage: viewModel.isDualPane ? "rectangle.split.2x1" : "rectangle"
                    )
                }
                .help(viewModel.isDualPane ? "Switch to Single Pane" : "Switch to Dual Pane")
            }

            if !viewModel.isDualPane {
                ToolbarItem(placement: .navigation) {
                    Picker("Active Pane", selection: $viewModel.activePanePosition) {
                        Text(viewModel.leftPane.contentType.title).tag(PanePosition.left)
                        Text(viewModel.rightPane.contentType.title).tag(PanePosition.right)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }

            // Transfer Actions
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.transfer(from: .left, to: .right)
                } label: {
                    Label("Upload to Right", systemImage: "arrow.right")
                }
                .disabled(!canTransferToRight)
                .help("Transfer selected files from Left to Right")

                Button {
                    viewModel.transfer(from: .right, to: .left)
                } label: {
                    Label("Download to Left", systemImage: "arrow.left")
                }
                .disabled(!canTransferToLeft)
                .help("Transfer selected files from Right to Left")

                // New Connection
                Button {
                    viewModel.connectionListViewModel.isShowingNewConnectionSheet = true
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .help("Add New Connection")

                // Terminal
                Button {
                    viewModel.openTerminalForActivePane()
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .disabled(!isActiveRemoteSFTP)
                .help("Open Terminal for Active Server")

                // Global Transfers
                Button {
                    viewModel.isShowingTransfersPopover.toggle()
                } label: {
                    Label(
                        "Transfers",
                        systemImage: viewModel.hasActiveTransfers ? "arrow.up.circle.fill" : "arrow.up.arrow.down.circle"
                    )
                    .symbolEffect(.pulse, options: .repeating, isActive: viewModel.hasActiveTransfers)
                }
                .overlay(alignment: .topTrailing) {
                    if viewModel.activeTransferCount > 0 {
                        Text("\(viewModel.activeTransferCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.blue))
                            .offset(x: 4, y: -4)
                            .allowsHitTesting(false)
                    }
                }
                .popover(isPresented: $viewModel.isShowingTransfersPopover, arrowEdge: .bottom) {
                    CommanderTransfersPopover(viewModel: viewModel)
                }
                .help("Transfers")
            }
        }
        // Password Prompt Sheet
        .sheet(isPresented: $viewModel.isShowingPasswordPrompt) {
            if let conn = viewModel.pendingConnection {
                PasswordPromptSheet(
                    connectionName: conn.name,
                    onConnect: { password in
                        viewModel.connectWithPassword(password)
                    },
                    onCancel: {
                        viewModel.cancelPasswordPrompt()
                    }
                )
            }
        }
        // New Connection Sheet
        .sheet(isPresented: $viewModel.connectionListViewModel.isShowingNewConnectionSheet) {
            ConnectionFormSheet(
                mode: .create,
                folders: viewModel.connectionListViewModel.folders,
                onSave: { connection, password in
                    Task {
                        await viewModel.connectionListViewModel.saveConnection(connection, password: password)
                    }
                },
                onCancel: {
                    viewModel.connectionListViewModel.isShowingNewConnectionSheet = false
                }
            )
        }
        // Edit Connection Sheet
        .sheet(isPresented: $viewModel.connectionListViewModel.isShowingEditConnectionSheet) {
            if let connection = viewModel.connectionListViewModel.connectionToEdit {
                ConnectionFormSheet(
                    mode: .edit(connection),
                    savedPassword: viewModel.connectionListViewModel.getSavedPassword(for: connection),
                    folders: viewModel.connectionListViewModel.folders,
                    onSave: { updatedConnection, password in
                        Task {
                            await viewModel.connectionListViewModel.updateConnection(updatedConnection, password: password)
                        }
                    },
                    onCancel: {
                        viewModel.connectionListViewModel.isShowingEditConnectionSheet = false
                        viewModel.connectionListViewModel.connectionToEdit = nil
                    }
                )
            }
        }
        .errorAlert($viewModel.error)
    }

    private var isActiveRemoteSFTP: Bool {
        if case .remote(let conn) = viewModel.activePane.contentType {
            return conn.connectionType == .sftp
        }
        return false
    }
}
