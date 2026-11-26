//
//  NativeServersTableView+ContextMenu.swift
//  macSCP
//
//  Context menu construction, action handlers, and ServerOutlineView subclass
//  for NativeServersTableView.
//

import AppKit

// MARK: - ServerContextMenuDelegate

protocol ServerContextMenuDelegate: AnyObject {
    func contextMenu(for node: ServerOutlineNode) -> NSMenu?
    func emptyAreaContextMenu() -> NSMenu?
}

// MARK: - Coordinator Context Menu Support

extension NativeServersTableView.Coordinator: ServerContextMenuDelegate {

    func contextMenu(for node: ServerOutlineNode) -> NSMenu? {
        let menu = NSMenu()

        switch node.kind {
        case .connection(let conn):
            buildConnectionMenu(menu, for: conn)
        case .folder(let folder):
            addMenuItem(menu, title: "Rename…", action: #selector(handleRenameFolder(_:)), image: "pencil", object: folder)
            menu.addItem(.separator())
            addMenuItem(menu, title: "Delete Folder", action: #selector(handleDeleteFolder(_:)), image: "trash", object: folder)
        case .ungroupedHeader:
            return emptyAreaContextMenu()
        }

        return menu
    }

    func emptyAreaContextMenu() -> NSMenu? {
        let menu = NSMenu()
        addMenuItem(menu, title: "New Connection…", action: #selector(handleNewConnection(_:)), image: "plus")
        addMenuItem(menu, title: "New Folder…", action: #selector(handleNewFolder(_:)), image: "folder.badge.plus")
        return menu
    }

    private func buildConnectionMenu(_ menu: NSMenu, for conn: Connection) {
        addMenuItem(menu, title: "Connect in this Pane", action: #selector(handleConnectInThisPane(_:)), image: "bolt.fill", object: conn)
        addMenuItem(menu, title: "Connect in Other Pane", action: #selector(handleConnectInOtherPane(_:)), image: "arrow.right.circle", object: conn)

        if conn.connectionType == .sftp {
            addMenuItem(menu, title: "Open in Terminal (SSH)", action: #selector(handleOpenTerminal(_:)), image: "terminal", object: conn)
        }

        menu.addItem(.separator())
        addMenuItem(menu, title: "Edit…", action: #selector(handleEdit(_:)), image: "pencil", object: conn)
        addMenuItem(menu, title: "Duplicate", action: #selector(handleDuplicate(_:)), image: "doc.on.doc", object: conn)

        if !parent.folders.isEmpty {
            let moveMenu = NSMenu()
            addMenuItem(moveMenu, title: "None (Ungrouped)", action: #selector(handleMoveToNone(_:)), object: conn)
            moveMenu.addItem(.separator())

            for folder in parent.folders {
                addMenuItem(moveMenu, title: folder.name, action: #selector(handleMoveToFolder(_:)), object: (conn, folder))
            }

            let moveItem = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
            moveItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            moveItem.submenu = moveMenu
            menu.addItem(moveItem)
        }

        menu.addItem(.separator())
        addMenuItem(menu, title: "Delete", action: #selector(handleDelete(_:)), image: "trash", object: conn)
    }

    private func addMenuItem(
        _ menu: NSMenu,
        title: String,
        action: Selector,
        image: String? = nil,
        object: Any? = nil
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        if let image {
            item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
        }
        menu.addItem(item)
    }

    // MARK: - Action Handlers

    @objc private func handleConnectInThisPane(_ sender: NSMenuItem) {
        guard let conn = sender.representedObject as? Connection else { return }
        parent.onConnect(conn)
    }

    @objc private func handleConnectInOtherPane(_ sender: NSMenuItem) {
        guard let conn = sender.representedObject as? Connection else { return }
        parent.onConnectInOtherPane(conn)
    }

    @objc private func handleOpenTerminal(_ sender: NSMenuItem) {
        guard let conn = sender.representedObject as? Connection else { return }
        parent.onOpenTerminal(conn)
    }

    @objc private func handleEdit(_ sender: NSMenuItem) {
        guard let conn = sender.representedObject as? Connection else { return }
        parent.onEdit(conn)
    }

    @objc private func handleDuplicate(_ sender: NSMenuItem) {
        guard let conn = sender.representedObject as? Connection else { return }
        parent.onDuplicate(conn)
    }

    @objc private func handleDelete(_ sender: NSMenuItem) {
        guard let conn = sender.representedObject as? Connection else { return }
        parent.onDelete(conn)
    }

    @objc private func handleMoveToNone(_ sender: NSMenuItem) {
        guard let conn = sender.representedObject as? Connection else { return }
        parent.onMove(conn, nil)
    }

    @objc private func handleMoveToFolder(_ sender: NSMenuItem) {
        guard let (conn, folder) = sender.representedObject as? (Connection, Folder) else { return }
        parent.onMove(conn, folder)
    }

    @objc private func handleDeleteFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? Folder else { return }
        parent.onDeleteFolder(folder)
    }

    @objc private func handleRenameFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? Folder else { return }
        parent.onRenameFolder(folder)
    }

    @objc private func handleNewConnection(_ sender: NSMenuItem) {
        parent.onNewConnection()
    }

    @objc private func handleNewFolder(_ sender: NSMenuItem) {
        parent.onNewFolder()
    }
}

// MARK: - ServerOutlineView Subclass

final class ServerOutlineView: NSOutlineView {
    weak var serverContextMenuDelegate: ServerContextMenuDelegate?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            guard let node = item(atRow: row) as? ServerOutlineNode else { return nil }
            return serverContextMenuDelegate?.contextMenu(for: node)
        } else {
            return serverContextMenuDelegate?.emptyAreaContextMenu()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Return key
            if selectedRow >= 0, let node = item(atRow: selectedRow) as? ServerOutlineNode {
                switch node.kind {
                case .connection(let conn):
                    (delegate as? NativeServersTableView.Coordinator)?.parent.onConnect(conn)
                    return
                case .folder, .ungroupedHeader:
                    if isItemExpanded(node) {
                        collapseItem(node)
                    } else {
                        expandItem(node)
                    }
                    return
                }
            }
        }
        super.keyDown(with: event)
    }
}
