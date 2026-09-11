//
//  CommanderWorkspaceView.swift
//  macSCP
//
//  Main window workspace view offering Transmit 5 style Dual-Pane Commander experience
//

import SwiftUI

struct CommanderWorkspaceView: View {
    @State private var viewModel: CommanderViewModel
    @State private var newFolderName = ""
    @State private var renameFolderName = ""

    init(container: DependencyContainer) {
        self._viewModel = State(initialValue: CommanderViewModel(container: container))
    }

    init() {
        self.init(container: DependencyContainer.shared)
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

            // Toolbar Actions
            ToolbarItemGroup(placement: .primaryAction) {
                // New Connection
                Button {
                    viewModel.connectionListViewModel.isShowingNewConnectionSheet = true
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .help("Add New Connection")

                // New Folder
                Button {
                    viewModel.connectionListViewModel.isShowingNewFolderSheet = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .help("Add New Folder")

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
        // New Folder Alert
        .alert("New Folder", isPresented: $viewModel.connectionListViewModel.isShowingNewFolderSheet) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmed
                if !name.isEmpty {
                    Task { await viewModel.connectionListViewModel.createFolder(name: name) }
                }
                newFolderName = ""
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                newFolderName = ""
            }
        } message: {
            Text("Enter a name for the new folder.")
        }
        // Delete Folder Alert
        .alert("Delete Folder", isPresented: $viewModel.connectionListViewModel.isShowingDeleteFolderAlert) {
            Button("Delete", role: .destructive) {
                if let folder = viewModel.connectionListViewModel.folderToDelete {
                    Task { await viewModel.connectionListViewModel.deleteFolder(folder) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let folder = viewModel.connectionListViewModel.folderToDelete {
                Text("Are you sure you want to delete \"\(folder.name)\"? Connections inside this folder will not be deleted.")
            }
        }
        // Rename Folder Alert
        .alert("Rename Folder", isPresented: $viewModel.connectionListViewModel.isShowingRenameFolderAlert) {
            TextField("Folder name", text: $renameFolderName)
            Button("Rename") {
                let name = renameFolderName.trimmed
                if !name.isEmpty, let folder = viewModel.connectionListViewModel.folderToRename {
                    Task { await viewModel.connectionListViewModel.renameFolder(folder, to: name) }
                }
                viewModel.connectionListViewModel.cancelRenameFolder()
                renameFolderName = ""
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                viewModel.connectionListViewModel.cancelRenameFolder()
                renameFolderName = ""
            }
        } message: {
            Text("Enter a new name for the folder.")
        }
        .onChange(of: viewModel.connectionListViewModel.isShowingRenameFolderAlert) { _, isShowing in
            if isShowing, let folder = viewModel.connectionListViewModel.folderToRename {
                renameFolderName = folder.name
            } else if !isShowing {
                renameFolderName = ""
            }
        }
        .errorAlert($viewModel.error)
    }
}
