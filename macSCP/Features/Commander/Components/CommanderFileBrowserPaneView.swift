//
//  CommanderFileBrowserPaneView.swift
//  macSCP
//
//  File browser view for a Commander pane
//

import SwiftUI

struct CommanderFileBrowserPaneView: View {
    @Bindable var viewModel: FileBrowserViewModel
    @Bindable var commanderViewModel: CommanderViewModel
    let pane: CommanderPaneState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            contentView

            Divider()

            statusBar
        }
        .sheet(isPresented: $viewModel.isShowingNewFolderSheet) {
            NameInputSheet.newFolder(
                onConfirm: { name in
                    Task { await viewModel.createFolder(name: name) }
                },
                onCancel: {
                    viewModel.isShowingNewFolderSheet = false
                }
            )
        }
        .sheet(isPresented: $viewModel.isShowingNewFileSheet) {
            NameInputSheet.newFile(
                onConfirm: { name in
                    Task { await viewModel.createFile(name: name) }
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
                        Task { await viewModel.renameFile(file, to: newName) }
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

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.state {
        case .idle, .loading:
            LoadingView(message: viewModel.isConnected ? "Loading…" : "Connecting…")

        case .success:
            if viewModel.files.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "Empty Folder",
                    message: "This folder contains no files."
                )
            } else {
                HSplitView {
                    FileListView(
                        viewModel: viewModel,
                        files: viewModel.sortedFiles,
                        onOpenEditor: openFileInEditor,
                        onGetInfo: showFileInfo
                    )
                    .frame(minWidth: 280, maxWidth: .infinity)

                    if viewModel.isShowingQuickLook {
                        QuickLookPreviewView(viewModel: viewModel)
                            .frame(minWidth: 220, idealWidth: 280, maxWidth: 450)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: viewModel.isShowingQuickLook)
            }

        case .error(let error):
            VStack(spacing: 14) {
                ErrorView(error: error) {
                    Task {
                        if viewModel.isConnected {
                            await viewModel.refresh()
                        } else {
                            await viewModel.connect()
                        }
                    }
                }

                if viewModel.isLocal {
                    HStack(spacing: 10) {
                        Button {
                            chooseLocalFolder()
                        } label: {
                            Label("Choose Folder…", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            Task {
                                await viewModel.navigateTo(LocalFileRepository.userHomeDirectory)
                            }
                        } label: {
                            Label("Go to Home (~)", systemImage: "house")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Folder"
        panel.directoryURL = URL(fileURLWithPath: LocalFileRepository.userHomeDirectory)
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task {
                    await viewModel.navigateTo(url.path)
                }
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            // Path / Breadcrumb Bar at footer
            BreadcrumbView(
                components: viewModel.pathComponents,
                onNavigate: { path in
                    Task { await viewModel.navigateTo(path) }
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if !viewModel.isLocal {
                // Connection indicator for remote servers
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.isConnected ? Color.green : Color.red)
                        .frame(width: 6, height: 6)

                    Text(viewModel.isConnected ? "Connected" : "Disconnected")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.bar)
    }

    // MARK: - Helper Actions

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
}
