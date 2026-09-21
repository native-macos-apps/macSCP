//
//  FileEditorView.swift
//  macSCP
//
//  Main file editor view
//

import SwiftUI

struct FileEditorView: View {
    @Bindable var viewModel: FileEditorViewModel

    init(viewModel: FileEditorViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Divider separating titlebar from editor content
            Divider()

            // Search bar (conditional, slides in directly under titlebar like TextEdit find banner)
            if viewModel.isShowingSearch {
                SearchReplaceBar(viewModel: viewModel)
                Divider()
            }

            // Editor content
            EditorContentView(viewModel: viewModel)
                .contextMenu {
                    Button {
                        Task {
                            await viewModel.save()
                        }
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!viewModel.hasChanges)

                    Button {
                        viewModel.toggleSearch()
                    } label: {
                        Label("Find…", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    Divider()

                    Button {
                        Task {
                            await viewModel.reload()
                        }
                    } label: {
                        Label("Reload from Server", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                    Button {
                        viewModel.revertChanges()
                    } label: {
                        Label("Revert to Saved", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!viewModel.hasChanges)
                }

            Divider()

            // Status bar
            EditorStatusBar(viewModel: viewModel)
        }
        .frame(minWidth: WindowSize.fileEditor.width, minHeight: WindowSize.fileEditor.height)
        .errorAlert($viewModel.error)
        .background {
            // Keyboard shortcuts
            Group {
                Button("Save") {
                    Task {
                        await viewModel.save()
                    }
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Find") {
                    viewModel.toggleSearch()
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Reload") {
                    Task {
                        await viewModel.reload()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }
}

// MARK: - Preview
#Preview {
    FileEditorView(viewModel: FileEditorViewModel(
        filePath: "/home/user/test.txt",
        fileName: "test.txt",
        initialContent: "Hello, World!\n\nThis is a test file.",
        fileRepository: FileRepository(sftpSession: SFTPSession())
    ))
}
