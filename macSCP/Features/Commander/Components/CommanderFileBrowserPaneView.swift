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

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            // Selected item info or total item count
            if !viewModel.selectedFiles.isEmpty {
                Text("\(viewModel.selectedFiles.count) of \(viewModel.files.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let primary = viewModel.primarySelectedFile, !primary.isDirectory {
                    Text("•")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(primary.displaySize)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(viewModel.files.count) item\(viewModel.files.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Transfer to other pane button
            if !viewModel.selectedFiles.isEmpty {
                Button {
                    commanderViewModel.transfer(from: pane.position, to: pane.position.other)
                } label: {
                    HStack(spacing: 3) {
                        Text(pane.position == .left ? "Transfer to Right" : "Transfer to Left")
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: pane.position == .left ? "arrow.right.circle.fill" : "arrow.left.circle.fill")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .help("Transfer selected items to the other pane")
            }

            // Connection indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)

                Text(viewModel.isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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
