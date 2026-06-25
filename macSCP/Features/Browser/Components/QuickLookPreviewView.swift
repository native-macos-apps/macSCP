//
//  QuickLookPreviewView.swift
//  macSCP
//
//  Quick Look preview panel shown in the file browser sidebar.
//

import SwiftUI
import PDFKit
import AppKit

// MARK: - QuickLookContent

/// The loaded content for the Quick Look panel.
enum QuickLookContent {
    case loading
    case image(Data)
    case text(String)
    case pdf(Data)
    case unsupported   // Shows metadata only
    case error(String)
}

// MARK: - QuickLookPreviewView

struct QuickLookPreviewView: View {
    @Bindable var viewModel: FileBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let file = viewModel.quickLookFile {
                VSplitView {
                    // ── Top: Resizable Preview content ──────────────────────────────
                    previewContentContainer(for: file)
                        .frame(minHeight: 120, idealHeight: 200, maxHeight: 600)
                        .frame(maxWidth: .infinity)
                        .background(Color(.controlBackgroundColor))

                    // ── Bottom: Scrollable info details (matches Get Info) ──────────
                    ScrollView {
                        infoSection(for: file)
                            .padding(.top, 12)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Top Preview Zone

    @ViewBuilder
    private func previewContentContainer(for file: RemoteFile) -> some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                switch viewModel.quickLookContent {
                case .loading:
                    ZStack {
                        iconBox(for: file)
                        ProgressView()
                            .scaleEffect(0.8)
                            .background(Color(.controlBackgroundColor).opacity(0.3))
                    }

                case .image(let data):
                    if let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(6)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            .padding(12)
                    } else {
                        iconBox(for: file)
                    }

                case .text(let content):
                    TextPreviewView(text: content)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(.separatorColor), lineWidth: 0.5)
                        )
                        .padding(12)

                case .pdf(let data):
                    PDFPreviewView(data: data)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(.separatorColor), lineWidth: 0.5)
                        )
                        .padding(12)

                case .unsupported, .error:
                    iconBox(for: file)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer()
        }
    }

    private func iconBox(for file: RemoteFile) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.windowBackgroundColor))
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)

            Image(systemName: FileTypeService.iconName(for: file))
                .font(.system(size: 36))
                .foregroundStyle(FileTypeService.iconColor(for: file))
        }
    }

    // MARK: - Info Details Section (matches FileInfoView)

    @ViewBuilder
    private func infoSection(for file: RemoteFile) -> some View {
        let info = FileInfoViewModel(file: file, connectionName: viewModel.connection.name)

        VStack(alignment: .leading, spacing: 12) {
            // General Info
            InfoSection(title: "General") {
                InfoRow(label: "Name", value: info.fileName)
                InfoRow(label: "Kind", value: info.fileType)
                InfoRow(label: "Size", value: info.fileSize)
                if !info.isDirectory {
                    InfoRow(label: "Extension", value: info.fileExtension)
                }
                InfoRow(label: "Modified", value: info.modificationDate)
            }

            // Location Info
            InfoSection(title: "Location") {
                InfoRow(label: "Path", value: info.filePath)
                InfoRow(label: "Parent", value: info.parentDirectory)
                InfoRow(label: "Server", value: info.connectionName)
            }

            // Permissions Info
            InfoSection(title: "Permissions") {
                InfoRow(label: "Mode", value: info.permissions)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Details")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(info.permissionsDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(.primary)
                }
            }

            // Directory / File Info
            if info.isDirectory {
                InfoSection(title: "Directory Info") {
                    InfoRow(label: "Type", value: "Folder")
                }
            } else {
                InfoSection(title: "File Info") {
                    InfoRow(label: "Hidden", value: info.isHidden ? "Yes" : "No")
                    InfoRow(label: "Executable", value: info.isExecutable ? "Yes" : "No")
                    InfoRow(label: "Editable", value: info.isEditable ? "Yes" : "No")
                    if info.isSymlink {
                        InfoRow(label: "Symlink", value: "Yes")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Select a file to preview")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helper Layout Views for Info Sections

private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                content
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Text Preview

private struct TextPreviewView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textColor = .labelColor
            textView.backgroundColor = NSColor.textBackgroundColor
            textView.string = text
            textView.textContainerInset = NSSize(width: 8, height: 8)
        }
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let textView = scrollView.documentView as? NSTextView {
            if textView.string != text {
                textView.string = text
            }
        }
    }
}

// MARK: - PDF Preview

private struct PDFPreviewView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.backgroundColor = NSColor.textBackgroundColor
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        let doc = PDFDocument(data: data)
        if pdfView.document == nil || pdfView.document?.dataRepresentation() != data {
            pdfView.document = doc
        }
    }
}
