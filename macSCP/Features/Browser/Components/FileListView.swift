//
//  FileListView.swift
//  macSCP
//
//  List view for displaying files in the browser - Finder style with native drag and drop
//

import SwiftUI

struct FileListView: View {
    @Bindable var viewModel: FileBrowserViewModel
    let files: [RemoteFile]
    let onOpenEditor: (RemoteFile) -> Void
    let onGetInfo: (RemoteFile) -> Void

    var body: some View {
        NativeFileTableView(
            viewModel: viewModel,
            files: files,
            onDoubleClick: handleDoubleClick,
            onGetInfo: onGetInfo,
            onOpenEditor: onOpenEditor
        )
    }

    private func handleDoubleClick(_ file: RemoteFile) {
        Task {
            if file.isDirectory {
                await viewModel.navigateTo(file.path)
            } else if FileTypeService.isPreviewable(file) {
                onOpenEditor(file)
            }
        }
    }
}

// MARK: - Preview
#Preview {
    FileListView(
        viewModel: DependencyContainer.shared.makeFileBrowserViewModel(
            connection: Connection(name: "Test", host: "localhost", username: "user"),
            sftpSession: SFTPSession(),
            password: "test"
        ),
        files: [],
        onOpenEditor: { _ in },
        onGetInfo: { _ in }
    )
}
