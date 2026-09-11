//
//  CommanderServersPaneView.swift
//  macSCP
//
//  Servers/Connections view organized directly by folders using native NSTableView / NSOutlineView
//

import SwiftUI

struct CommanderServersPaneView: View {
    @Bindable var commanderViewModel: CommanderViewModel
    let pane: CommanderPaneState

    private var viewModel: ConnectionListViewModel {
        commanderViewModel.connectionListViewModel
    }

    private func matchesSearch(_ conn: Connection) -> Bool {
        let query = pane.serverSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return conn.name.localizedCaseInsensitiveContains(query) ||
               conn.host.localizedCaseInsensitiveContains(query) ||
               conn.username.localizedCaseInsensitiveContains(query)
    }

    private var hasAnyMatchingConnections: Bool {
        viewModel.connections.contains(where: matchesSearch)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main content organized directly by folders
            if viewModel.connections.isEmpty {
                emptyAllConnectionsView
            } else if !hasAnyMatchingConnections {
                emptySearchResultsView
            } else {
                connectionsList
            }

            Divider()

            // Bottom action bar
            bottomBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Connections List (Native NSTableView / NSOutlineView)

    private var connectionsList: some View {
        NativeServersTableView(
            folders: viewModel.folders,
            connections: viewModel.connections,
            searchText: pane.serverSearchText,
            onConnect: { conn in
                commanderViewModel.connect(to: conn, in: pane.position)
            },
            onConnectInOtherPane: { conn in
                commanderViewModel.connect(to: conn, in: pane.position.other)
            },
            onOpenTerminal: { conn in
                commanderViewModel.openTerminal(for: conn)
            },
            onEdit: { conn in
                viewModel.editConnection(conn)
            },
            onDuplicate: { conn in
                Task { await viewModel.duplicateConnection(conn) }
            },
            onDelete: { conn in
                Task { await viewModel.deleteConnection(conn) }
            },
            onMove: { conn, folder in
                Task { await viewModel.moveConnection(conn, to: folder) }
            },
            onDeleteFolder: { folder in
                viewModel.folderToDelete = folder
                viewModel.isShowingDeleteFolderAlert = true
            },
            onRenameFolder: { folder in
                viewModel.confirmRenameFolder(folder)
            },
            onNewConnection: {
                viewModel.isShowingNewConnectionSheet = true
            },
            onNewFolder: {
                viewModel.isShowingNewFolderSheet = true
            }
        )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.connections.count) server\(viewModel.connections.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if !viewModel.folders.isEmpty {
                Text("•")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("\(viewModel.folders.count) folder\(viewModel.folders.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Empty States

    private var emptyAllConnectionsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)

            Text("No Connections")
                .font(.system(size: 13, weight: .medium))

            Text("Add an SFTP or S3 server to connect.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button {
                viewModel.isShowingNewConnectionSheet = true
            } label: {
                Label("Add Connection", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptySearchResultsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)

            Text("No Matching Servers")
                .font(.system(size: 13, weight: .medium))

            Text("No servers match \"\(pane.serverSearchText)\".")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button("Clear Search") {
                pane.serverSearchText = ""
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
