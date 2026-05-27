//
//  FileBrowserView.swift
//  macSCP
//
//  Main file browser view
//

import SwiftUI

struct FileBrowserView: View {
    @Bindable var viewModel: FileBrowserViewModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var isSearchFieldFocused: Bool
    @State private var searchText = ""
    @State private var isShowingSearch = false

    init(viewModel: FileBrowserViewModel) {
        self.viewModel = viewModel
    }

    private var filteredFiles: [RemoteFile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.sortedFiles }

        return viewModel.sortedFiles.filter {
            $0.name.localizedStandardContains(query)
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Breadcrumb path bar
            BreadcrumbView(
                components: viewModel.pathComponents,
                onNavigate: { path in
                    Task {
                        await viewModel.navigateTo(path)
                    }
                }
            )

            Divider()

            if isShowingSearch {
                fileSearchBar
                Divider()
            }

            // Content
            contentView

            Divider()

            // Status Bar
            statusBar
        }
        .frame(minWidth: WindowSize.minFileBrowser.width, minHeight: WindowSize.minFileBrowser.height)
        .navigationTitle(viewModel.currentPath == "/" ? viewModel.connection.name : (viewModel.currentPath as NSString).lastPathComponent)
        .navigationSubtitle(viewModel.isConnected ? viewModel.connection.connectionString : "Disconnected")
        .toolbar(id: "browserToolbar") {
            // Navigation group
            ToolbarItem(id: "back", placement: .navigation) {
                Button {
                    Task { await viewModel.goBack() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!viewModel.canGoBack)
                .help("Go Back")
            }

            ToolbarItem(id: "forward", placement: .navigation) {
                Button {
                    Task { await viewModel.goForward() }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!viewModel.canGoForward)
                .help("Go Forward")
            }

            // Primary actions
            ToolbarItem(id: "newItem", placement: .primaryAction) {
                Menu {
                    Button {
                        viewModel.isShowingNewFolderSheet = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }

                    Button {
                        viewModel.isShowingNewFileSheet = true
                    } label: {
                        Label("New File", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("New File or Folder")
            }

            ToolbarItem(id: "upload", placement: .primaryAction) {
                Button {
                    Task { await viewModel.uploadFiles() }
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                .help("Upload Files")
            }

            ToolbarItem(id: "delete", placement: .primaryAction) {
                Button {
                    viewModel.confirmDeleteSelected()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(viewModel.selectedFiles.isEmpty)
                .help("Delete Selected")
            }

            ToolbarItem(id: "spacer1", placement: .primaryAction) {
                Spacer()
            }

            // Transfers
            ToolbarItem(id: "transfers", placement: .primaryAction) {
                TransfersToolbarButton(viewModel: viewModel)
            }

            // View options
            ToolbarItem(id: "hiddenFiles", placement: .primaryAction) {
                Toggle(isOn: $viewModel.showHiddenFiles) {
                    Label(
                        viewModel.showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files",
                        systemImage: viewModel.showHiddenFiles ? "eye.fill" : "eye.slash"
                    )
                }
                .help("Toggle Hidden Files")
            }

            ToolbarItem(id: "sort", placement: .primaryAction) {
                Menu {
                    ForEach(RemoteFile.SortCriteria.allCases, id: \.self) { criteria in
                        Button {
                            if viewModel.sortCriteria == criteria {
                                viewModel.sortAscending.toggle()
                            } else {
                                viewModel.sortCriteria = criteria
                                viewModel.sortAscending = true
                            }
                        } label: {
                            HStack {
                                Text(criteria.rawValue)
                                if viewModel.sortCriteria == criteria {
                                    Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort Options")
            }

            ToolbarItem(id: "search", placement: .primaryAction) {
                Button {
                    showSearch()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Search Files")
            }
        }
        .task {
            await viewModel.connect()
        }
        .onKeyPress(.escape) {
            guard isShowingSearch else { return .ignored }
            closeSearch(clearText: true)
            return .handled
        }
        .onChange(of: isShowingSearch) { _, isShowing in
            if isShowing {
                isSearchFieldFocused = true
            }
        }
        .onChange(of: viewModel.currentPath) { _, _ in
            closeSearch(clearText: true)
        }
        .sheet(isPresented: $viewModel.isShowingNewFolderSheet) {
            NameInputSheet.newFolder(
                onConfirm: { name in
                    Task {
                        await viewModel.createFolder(name: name)
                    }
                },
                onCancel: {
                    viewModel.isShowingNewFolderSheet = false
                }
            )
        }
        .sheet(isPresented: $viewModel.isShowingNewFileSheet) {
            NameInputSheet.newFile(
                onConfirm: { name in
                    Task {
                        await viewModel.createFile(name: name)
                    }
                },
                onCancel: {
                    viewModel.isShowingNewFileSheet = false
                }
            )
        }
        .sheet(isPresented: $viewModel.isShowingRenameSheet) {
            if let file = viewModel.fileToRename {
                NameInputSheet.rename(
                    currentName: file.name,
                    onConfirm: { newName in
                        Task {
                            await viewModel.renameFile(file, to: newName)
                        }
                    },
                    onCancel: {
                        viewModel.isShowingRenameSheet = false
                        viewModel.fileToRename = nil
                    }
                )
            }
        }
        .alert("Delete Files", isPresented: $viewModel.isShowingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteFiles(viewModel.filesToDelete)
                }
            }
        } message: {
            let count = viewModel.filesToDelete.count
            Text("Are you sure you want to delete \(count) item\(count == 1 ? "" : "s")? This cannot be undone.")
        }
        .errorAlert($viewModel.error)
        .onDisappear {
            Task {
                await viewModel.disconnect()
            }
        }
        .onChange(of: viewModel.pendingFileInfoWindowId) { _, windowId in
            if let windowId = windowId {
                openWindow(id: WindowID.fileInfo, value: windowId)
                viewModel.clearPendingFileInfoWindow()
            }
        }
        .onChange(of: viewModel.pendingEditorWindowId) { _, windowId in
            if let windowId = windowId {
                openWindow(id: WindowID.fileEditor, value: windowId)
                viewModel.clearPendingEditorWindow()
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.state {
        case .idle, .loading:
            LoadingView(message: viewModel.isConnected ? "Loading..." : "Connecting...")

        case .success:
            if filteredFiles.isEmpty, isSearching {
                EmptyStateView.noSearchResults
            } else {
                FileListView(
                    viewModel: viewModel,
                    files: filteredFiles,
                    onOpenEditor: openFileInEditor,
                    onGetInfo: showFileInfo
                )
            }

        case .error(let error):
            ErrorView(error: error) {
                Task {
                    if viewModel.isConnected {
                        await viewModel.refresh()
                    } else {
                        await viewModel.connect()
                    }
                }
            }
        }
    }

    private var fileSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search files by name", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }

            Button("Done") {
                closeSearch(clearText: true)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            // Connection status
            HStack(spacing: 5) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 7, height: 7)

                Text(viewModel.isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Active transfers indicator (clicking opens the popover)
            if viewModel.hasActiveTransfers {
                ActiveTransfersIndicator(viewModel: viewModel)
            }

            // Clipboard status
            if viewModel.hasClipboardItems && !viewModel.hasActiveTransfers {
                ClipboardStatusView(displayText: viewModel.clipboardDisplayText)
            }

            Spacer()

            // File count
            HStack(spacing: 6) {
                Text(fileCountText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if !viewModel.selectedFiles.isEmpty {
                    Text("\(viewModel.selectedFiles.count) selected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var fileCountText: String {
        if isSearching {
            return "\(filteredFiles.count) of \(viewModel.sortedFiles.count) items"
        }
        return "\(viewModel.sortedFiles.count) items"
    }

    private func openFileInEditor(_ file: RemoteFile) {
        Task {
            do {
                let content = try await viewModel.getFileContent(file)
                viewModel.openEditor(for: file, content: content)
            } catch {
                viewModel.error = AppError.from(error)
            }
        }
    }

    private func showFileInfo(_ file: RemoteFile) {
        viewModel.showFileInfo(file)
    }

    private func showSearch() {
        isShowingSearch = true
        isSearchFieldFocused = true
    }

    private func closeSearch(clearText: Bool) {
        isShowingSearch = false
        isSearchFieldFocused = false
        if clearText {
            searchText = ""
        }
    }
}

// MARK: - Clipboard Status View
struct ClipboardStatusView: View {
    let displayText: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(displayText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Active Transfers Indicator
struct ActiveTransfersIndicator: View {
    @Bindable var viewModel: FileBrowserViewModel

    var body: some View {
        Button {
            viewModel.isShowingTransfersPopover = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, options: .repeating)

                ProgressView(value: viewModel.overallProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 50)

                Text("\(Int(viewModel.overallProgress * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview
#Preview {
    FileBrowserView(
        viewModel: DependencyContainer.shared.makeFileBrowserViewModel(
            connection: Connection(name: "Test", host: "localhost", username: "user"),
            sftpSession: SFTPSession(),
            password: "test"
        )
    )
}
