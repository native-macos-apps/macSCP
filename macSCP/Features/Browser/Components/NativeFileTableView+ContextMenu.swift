//
//  NativeFileTableView+ContextMenu.swift
//  macSCP
//
//  Context menu construction, action handlers, and keyboard shortcut subclass
//  for NativeFileTableView.
//

import AppKit

// MARK: - Context Menu Support

extension NativeFileTableView.Coordinator: ContextMenuOutlineViewDelegate {

    func targetFiles(for row: Int) -> [RemoteFile] {
        guard let ov = outlineView else { return [] }
        if ov.selectedRowIndexes.contains(row) {
            let files = ov.selectedRowIndexes.compactMap { (ov.item(atRow: $0) as? FileTreeNode)?.file }
            if !files.isEmpty {
                return files
            }
        }
        if let n = ov.item(atRow: row) as? FileTreeNode {
            return [n.file]
        }
        return []
    }

    func contextMenu(for row: Int) -> NSMenu? {
        guard let ov = outlineView,
              let n = ov.item(atRow: row) as? FileTreeNode else { return nil }
        let file = n.file
        let targetFiles = self.targetFiles(for: row)
        let isMultiple = targetFiles.count > 1

        let menu = NSMenu()

        if !isMultiple && file.isFile {
            addItem(menu, title: "Open in Editor",
                    action: #selector(handleOpenInEditor(_:)),
                    image: "pencil.and.outline", object: file)
            if viewModel.connection.connectionType == .s3 {
                menu.addItem(.separator())
                addItem(menu, title: "Copy URL",
                        action: #selector(handleCopyURL(_:)),
                        image: "link", object: file)
                addItem(menu, title: "Copy Presigned URL",
                        action: #selector(handleCopyPresignedURL(_:)),
                        image: "timer", object: file)
            }
            menu.addItem(.separator())
        }

        let copyTitle = isMultiple ? "Copy \(targetFiles.count) Items" : "Copy"
        let cutTitle  = isMultiple ? "Cut \(targetFiles.count) Items" : "Cut"
        addItem(menu, title: copyTitle, action: #selector(handleCopy(_:)), image: "doc.on.doc",  object: targetFiles)
        addItem(menu, title: cutTitle,  action: #selector(handleCut(_:)),  image: "scissors",    object: targetFiles)

        if viewModel.canPaste {
            addItem(menu, title: "Paste", action: #selector(handlePaste(_:)), image: "doc.on.clipboard", object: file)
        }
        if let transferTitle = transferToOtherPaneTitle, onTransferToOtherPane != nil {
            menu.addItem(.separator())
            let title = isMultiple ? "\(transferTitle) (\(targetFiles.count))" : transferTitle
            addItem(menu, title: title,
                    action: #selector(handleTransferToOtherPane(_:)),
                    image: transferToOtherPaneIcon,
                    object: targetFiles)
        }

        if !isMultiple {
            menu.addItem(.separator())
            addItem(menu, title: "Rename",   action: #selector(handleRename(_:)),   image: "pencil",        object: file)
            addItem(menu, title: "Get Info", action: #selector(handleGetInfo(_:)),  image: "info.circle",   object: file)
        }

        if !isMultiple && file.isFile {
            menu.addItem(.separator())
            addItem(menu, title: "Download", action: #selector(handleDownload(_:)), image: "arrow.down.circle", object: file)
        }

        menu.addItem(.separator())
        let deleteTitle = isMultiple ? "Delete \(targetFiles.count) Items" : "Delete"
        addItem(menu, title: deleteTitle, action: #selector(handleDelete(_:)), image: "trash", object: targetFiles)

        return menu
    }

    private func addItem(_ menu: NSMenu,
                         title: String,
                         action: Selector,
                         image: String,
                         object: Any?) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
        menu.addItem(item)
    }

    @objc func handleOpenInEditor(_ s: NSMenuItem) {
        (s.representedObject as? RemoteFile).map { onOpenEditor?($0) }
    }

    @objc func handleCopyURL(_ s: NSMenuItem) {
        guard let f = s.representedObject as? RemoteFile else { return }
        Task { @MainActor in await viewModel.copyS3ObjectURL(for: f) }
    }

    @objc func handleCopyPresignedURL(_ s: NSMenuItem) {
        guard let f = s.representedObject as? RemoteFile else { return }
        Task { @MainActor in await viewModel.copyS3PresignedURL(for: f, expiresIn: 600) }
    }

    @objc func handleCopy(_ s: NSMenuItem) {
        if let files = s.representedObject as? [RemoteFile], !files.isEmpty {
            viewModel.copyFiles(files)
        } else if let file = s.representedObject as? RemoteFile {
            viewModel.copyFiles([file])
        }
    }

    @objc func handleCut(_ s: NSMenuItem) {
        if let files = s.representedObject as? [RemoteFile], !files.isEmpty {
            viewModel.cutFiles(files)
        } else if let file = s.representedObject as? RemoteFile {
            viewModel.cutFiles([file])
        }
    }

    @objc func handlePaste(_ s: NSMenuItem) {
        Task { @MainActor in await viewModel.paste() }
    }

    @objc func handleTransferToOtherPane(_ s: NSMenuItem) {
        let files: [RemoteFile]
        if let list = s.representedObject as? [RemoteFile], !list.isEmpty {
            files = list
        } else if let file = s.representedObject as? RemoteFile {
            files = [file]
        } else {
            return
        }
        viewModel.selectedFiles = Set(files.map { $0.id })
        if let first = files.first {
            onTransferToOtherPane?(first)
        }
    }

    @objc func handleRename(_ s: NSMenuItem) {
        (s.representedObject as? RemoteFile).map { viewModel.startRename($0) }
    }

    @objc func handleGetInfo(_ s: NSMenuItem) {
        (s.representedObject as? RemoteFile).map { onGetInfo($0) }
    }

    @objc func handleDownload(_ s: NSMenuItem) {
        guard let f = s.representedObject as? RemoteFile else { return }
        Task { @MainActor in await viewModel.downloadFile(f) }
    }

    @objc func handleDelete(_ s: NSMenuItem) {
        if let files = s.representedObject as? [RemoteFile], !files.isEmpty {
            viewModel.confirmDelete(files)
        } else if let file = s.representedObject as? RemoteFile {
            viewModel.confirmDelete([file])
        }
    }
}

// MARK: - ContextMenuOutlineView

protocol ContextMenuOutlineViewDelegate: AnyObject {
    func contextMenu(for row: Int) -> NSMenu?
}

class ContextMenuOutlineView: NSOutlineView {
    weak var contextMenuDelegate: ContextMenuOutlineViewDelegate?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return contextMenuDelegate?.contextMenu(for: row)
        }
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        // Cmd+Delete (keyCode 51 is Backspace on Mac) or forward delete (keyCode 117)
        if (event.keyCode == 51 && event.modifierFlags.contains(.command)) || event.keyCode == 117 {
            let files = selectedRowIndexes.compactMap { (item(atRow: $0) as? FileTreeNode)?.file }
            if !files.isEmpty {
                (contextMenuDelegate as? NativeFileTableView.Coordinator)?.viewModel.confirmDelete(files)
                return
            }
        }
        super.keyDown(with: event)
    }
}
