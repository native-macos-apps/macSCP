//
//  CommanderServersPaneView.swift
//  macSCP
//
//  Servers/Connections view organized directly by folders (Transmit 5 style)
//

import SwiftUI

struct CommanderServersPaneView: View {
    @Bindable var commanderViewModel: CommanderViewModel
    let pane: CommanderPaneState

    @State private var selectedConnectionId: UUID?
    @State private var collapsedFolderIds: Set<UUID> = []
    @State private var isShowingNewFolderAlert = false
    @State private var newFolderName = ""

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

    private var unfolderedConnections: [Connection] {
        viewModel.connections.filter { $0.folderId == nil && matchesSearch($0) }
    }

    private func connections(for folder: Folder) -> [Connection] {
        viewModel.connections.filter { $0.folderId == folder.id && matchesSearch($0) }
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
        .alert("New Folder", isPresented: $isShowingNewFolderAlert) {
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
    }

    // MARK: - Connections List (Organized by Folders)

    private var connectionsList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                // 1. Folders sections
                ForEach(viewModel.folders) { folder in
                    let conns = connections(for: folder)
                    let isCollapsed = collapsedFolderIds.contains(folder.id)
                    let shouldShow = !conns.isEmpty || pane.serverSearchText.isEmpty

                    if shouldShow {
                        folderSection(folder: folder, connections: conns, isCollapsed: isCollapsed)
                    }
                }

                // 2. Unfoldered / Other Connections
                if !unfolderedConnections.isEmpty {
                    if !viewModel.folders.isEmpty {
                        unfolderedHeader
                    }

                    ForEach(unfolderedConnections) { connection in
                        serverRow(connection)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Folder Section

    private func folderSection(folder: Folder, connections: [Connection], isCollapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Folder Header Row
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isCollapsed {
                        collapsedFolderIds.remove(folder.id)
                    } else {
                        collapsedFolderIds.insert(folder.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tint)

                    Text(folder.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("(\(connections.count))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    viewModel.folderToDelete = folder
                    viewModel.isShowingDeleteFolderAlert = true
                } label: {
                    Label("Delete Folder", systemImage: "trash")
                }
            }

            // Folder Connections
            if !isCollapsed {
                VStack(spacing: 4) {
                    if connections.isEmpty {
                        Text("No connections in this folder")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 24)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(connections) { connection in
                            serverRow(connection)
                                .padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    private var unfolderedHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Ungrouped")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("(\(unfolderedConnections.count))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: - Server Row

    private func serverRow(_ connection: Connection) -> some View {
        let isSelected = selectedConnectionId == connection.id

        return HStack(spacing: 10) {
            Image(systemName: connection.iconName)
                .font(.system(size: 17))
                .foregroundStyle(iconColor(for: connection))
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(connection.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)

                    Spacer()

                    Text(connection.connectionType.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            isSelected ? Color.white.opacity(0.2) : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                }

                Text(connection.connectionString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }

            // Quick Connect Button
            Button {
                commanderViewModel.connect(to: connection, in: pane.position)
            } label: {
                Text("Connect")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(isSelected ? .white.opacity(0.3) : .accentColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.02))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedConnectionId = connection.id
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                commanderViewModel.connect(to: connection, in: pane.position)
            }
        )
        .contextMenu {
            Button {
                commanderViewModel.connect(to: connection, in: pane.position)
            } label: {
                Label("Connect in this Pane", systemImage: "bolt.fill")
            }

            Button {
                commanderViewModel.connect(to: connection, in: pane.position.other)
            } label: {
                Label("Connect in Other Pane", systemImage: "arrow.right.circle")
            }

            Divider()

            Button {
                viewModel.editConnection(connection)
            } label: {
                Label("Edit…", systemImage: "pencil")
            }

            Button {
                Task { await viewModel.duplicateConnection(connection) }
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }

            if !viewModel.folders.isEmpty {
                Menu("Move to Folder") {
                    Button("None (Ungrouped)") {
                        Task { await viewModel.moveConnection(connection, to: nil) }
                    }
                    Divider()
                    ForEach(viewModel.folders) { folder in
                        Button(folder.name) {
                            Task { await viewModel.moveConnection(connection, to: folder) }
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                Task { await viewModel.deleteConnection(connection) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func iconColor(for connection: Connection) -> Color {
        switch connection.connectionType {
        case .sftp: return .blue
        case .s3:   return .orange
        case .local: return .green
        }
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

            Button {
                isShowingNewFolderAlert = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            Button {
                viewModel.isShowingNewConnectionSheet = true
            } label: {
                Label("New Connection", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
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
