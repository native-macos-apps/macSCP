//
//  ConnectionListView.swift
//  macSCP
//
//  Main view for managing SSH connections
//

import SwiftUI

struct ConnectionListView: View {
    @Bindable var viewModel: ConnectionListViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var newFolderName = ""

    init(viewModel: ConnectionListViewModel) {
        self.viewModel = viewModel
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let connection = viewModel.selectedConnection {
            ConnectionDetailView(
                connection: connection,
                onConnect: {
                    viewModel.connectToServer(connection)
                },
                onOpenTerminal: {
                    viewModel.requestTerminal(for: connection)
                },
                onEdit: {
                    viewModel.editConnection(connection)
                },
                onDuplicate: {
                    Task {
                        await viewModel.duplicateConnection(connection)
                    }
                },
                onDelete: {
                    Task {
                        await viewModel.deleteConnection(connection)
                    }
                }
            )
        } else {
            ContentUnavailableView(
                "No Connection Selected",
                systemImage: "server.rack",
                description: Text("Select a connection to view its details.")
            )
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } content: {
            ConnectionListColumn(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } detail: {
            detailColumn
        }
        .navigationTitle("")
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .searchable(text: $viewModel.searchText, prompt: "Search connections")
        .onChange(of: viewModel.selectedSidebarItem) {
            viewModel.selectedConnectionId = nil
        }
        .task {
            await viewModel.loadData()
        }
        .sheet(isPresented: $viewModel.isShowingNewConnectionSheet) {
            ConnectionFormSheet(
                mode: .create,
                folders: viewModel.folders,
                onSave: { connection, password in
                    Task {
                        await viewModel.saveConnection(connection, password: password)
                    }
                },
                onCancel: {
                    viewModel.isShowingNewConnectionSheet = false
                }
            )
        }
        .sheet(isPresented: $viewModel.isShowingEditConnectionSheet) {
            if let connection = viewModel.connectionToEdit {
                ConnectionFormSheet(
                    mode: .edit(connection),
                    savedPassword: viewModel.getSavedPassword(for: connection),
                    folders: viewModel.folders,
                    onSave: { updatedConnection, password in
                        Task {
                            await viewModel.updateConnection(updatedConnection, password: password)
                        }
                    },
                    onCancel: {
                        viewModel.isShowingEditConnectionSheet = false
                        viewModel.connectionToEdit = nil
                    }
                )
            }
        }
        .alert("New Folder", isPresented: $viewModel.isShowingNewFolderSheet) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmed
                if !name.isEmpty {
                    Task { await viewModel.createFolder(name: name) }
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
        .sheet(isPresented: $viewModel.isShowingPasswordPrompt) {
            if let connection = viewModel.connectionToConnect {
                PasswordPromptSheet(
                    connectionName: connection.name,
                    onConnect: { password in
                        viewModel.connectWithPassword(password)
                    },
                    onCancel: {
                        viewModel.cancelConnect()
                    }
                )
            }
        }
        .alert("Delete Folder", isPresented: $viewModel.isShowingDeleteFolderAlert) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelDeleteFolder()
            }
            Button("Delete", role: .destructive) {
                if let folder = viewModel.folderToDelete {
                    Task {
                        await viewModel.deleteFolder(folder)
                    }
                }
            }
        } message: {
            if let folder = viewModel.folderToDelete {
                let count = viewModel.connectionCount(for: folder.id)
                Text("Are you sure you want to delete \"\(folder.name)\"? \(count > 0 ? "The \(count) connection(s) in this folder will be moved to All Connections." : "")")
            }
        }
        .errorAlert($viewModel.error)
        .onChange(of: viewModel.pendingWindowId) { _, windowId in
            if let windowId = windowId {
                logInfo("Opening file browser window with ID: \(windowId)", category: .ui)
                openWindow(id: WindowID.fileBrowser, value: windowId)
                viewModel.clearPendingWindow()
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ConnectionListView(viewModel: DependencyContainer.shared.makeConnectionListViewModel())
}
