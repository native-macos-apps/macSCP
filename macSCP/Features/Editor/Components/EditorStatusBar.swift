//
//  EditorStatusBar.swift
//  macSCP
//
//  Status bar for the file editor
//

import SwiftUI

struct EditorStatusBar: View {
    @Bindable var viewModel: FileEditorViewModel

    var body: some View {
        HStack {
            // File path
            Text(viewModel.filePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Statistics
            HStack(spacing: UIConstants.spacing) {
                StatItem(label: "Lines", value: "\(viewModel.lineCount)")
                StatItem(label: "Words", value: "\(viewModel.wordCount)")
                StatItem(label: "Characters", value: "\(viewModel.characterCount)")
            }

            // Status and actions
            HStack(spacing: UIConstants.smallSpacing) {
                if viewModel.state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if viewModel.hasChanges {
                    Button {
                        Task {
                            await viewModel.save()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.orange)
                                .frame(width: 6, height: 6)
                            Text("Save")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Save changes (⌘S)")
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task {
                        await viewModel.reload()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.state.isLoading)
                .help("Reload from server (⇧⌘R)")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }
}

// MARK: - Stat Item
private struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview
#Preview {
    EditorStatusBar(viewModel: FileEditorViewModel(
        filePath: "/home/user/documents/test.txt",
        fileName: "test.txt",
        initialContent: "Hello, World!",
        fileRepository: FileRepository(sftpSession: SFTPSession())
    ))
}
