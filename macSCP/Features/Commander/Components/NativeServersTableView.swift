//
//  NativeServersTableView.swift
//  macSCP
//
//  NSViewRepresentable wrapping NSOutlineView for native macOS connection list
//  with folder grouping, compact rows, smooth mouse interactions, and native context menus.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Node Model

final class ServerOutlineNode: NSObject {
    enum Kind {
        case folder(Folder)
        case ungroupedHeader
        case connection(Connection)
    }

    let kind: Kind
    var children: [ServerOutlineNode] = []

    init(kind: Kind, children: [ServerOutlineNode] = []) {
        self.kind = kind
        self.children = children
    }

    var isExpandable: Bool {
        switch kind {
        case .folder, .ungroupedHeader:
            return true
        case .connection:
            return false
        }
    }

    var idString: String {
        switch kind {
        case .folder(let f): return "folder_\(f.id.uuidString)"
        case .ungroupedHeader: return "ungrouped_header"
        case .connection(let c): return "conn_\(c.id.uuidString)"
        }
    }
}

// MARK: - NativeServersTableView

struct NativeServersTableView: NSViewRepresentable {
    let folders: [Folder]
    let connections: [Connection]
    let searchText: String

    let onConnect: (Connection) -> Void
    let onConnectInOtherPane: (Connection) -> Void
    let onOpenTerminal: (Connection) -> Void
    let onEdit: (Connection) -> Void
    let onDuplicate: (Connection) -> Void
    let onDelete: (Connection) -> Void
    let onMove: (Connection, Folder?) -> Void
    let onDeleteFolder: (Folder) -> Void
    let onNewConnection: () -> Void
    let onNewFolder: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let outlineView = ServerOutlineView()

        let column = NSTableColumn(identifier: .init("servers"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil

        // Appearance
        outlineView.style = .inset
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsMultipleSelection = false
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = true

        // Drag and Drop
        outlineView.registerForDraggedTypes([.string])

        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator
        outlineView.serverContextMenuDelegate = context.coordinator

        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.onDoubleClick(_:))

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        context.coordinator.outlineView = outlineView
        context.coordinator.rebuildNodes(folders: folders, connections: connections, searchText: searchText)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(folders: folders, connections: connections, searchText: searchText)
    }
}

// MARK: - Coordinator

extension NativeServersTableView {
    final class Coordinator: NSObject, NSOutlineViewDelegate, NSOutlineViewDataSource, ServerContextMenuDelegate {
        var parent: NativeServersTableView
        weak var outlineView: ServerOutlineView?

        var rootNodes: [ServerOutlineNode] = []
        private var collapsedFolderIds: Set<String> = []

        init(_ parent: NativeServersTableView) {
            self.parent = parent
        }

        func update(folders: [Folder], connections: [Connection], searchText: String) {
            rebuildNodes(folders: folders, connections: connections, searchText: searchText)
        }

        func rebuildNodes(folders: [Folder], connections: [Connection], searchText: String) {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            func matches(_ conn: Connection) -> Bool {
                guard !query.isEmpty else { return true }
                return conn.name.localizedCaseInsensitiveContains(query) ||
                       conn.host.localizedCaseInsensitiveContains(query) ||
                       conn.username.localizedCaseInsensitiveContains(query)
            }

            var newRoots: [ServerOutlineNode] = []

            // Folders
            for folder in folders {
                let conns = connections.filter { $0.folderId == folder.id && matches($0) }
                if !conns.isEmpty || query.isEmpty {
                    let childNodes = conns.map { ServerOutlineNode(kind: .connection($0)) }
                    let folderNode = ServerOutlineNode(kind: .folder(folder), children: childNodes)
                    newRoots.append(folderNode)
                }
            }

            // Ungrouped
            let ungrouped = connections.filter { $0.folderId == nil && matches($0) }
            if !ungrouped.isEmpty {
                let childNodes = ungrouped.map { ServerOutlineNode(kind: .connection($0)) }
                if !folders.isEmpty {
                    let headerNode = ServerOutlineNode(kind: .ungroupedHeader, children: childNodes)
                    newRoots.append(headerNode)
                } else {
                    newRoots.append(contentsOf: childNodes)
                }
            }

            self.rootNodes = newRoots
            outlineView?.reloadData()

            // Expand nodes by default unless explicitly collapsed by user
            for node in newRoots where node.isExpandable {
                if !collapsedFolderIds.contains(node.idString) {
                    outlineView?.expandItem(node)
                } else {
                    outlineView?.collapseItem(node)
                }
            }
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil {
                return rootNodes.count
            }
            guard let node = item as? ServerOutlineNode else { return 0 }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return rootNodes[index]
            }
            guard let node = item as? ServerOutlineNode else { fatalError() }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? ServerOutlineNode else { return false }
            return node.isExpandable
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? ServerOutlineNode else { return 36 }
            switch node.kind {
            case .folder, .ungroupedHeader:
                return 26
            case .connection:
                return 38
            }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? ServerOutlineNode else { return nil }

            switch node.kind {
            case .folder(let folder):
                let cellId = NSUserInterfaceItemIdentifier("FolderCell")
                var cell = outlineView.makeView(withIdentifier: cellId, owner: self) as? FolderTableCellView
                if cell == nil {
                    cell = FolderTableCellView()
                    cell?.identifier = cellId
                }
                cell?.configure(folder: folder, count: node.children.count)
                return cell

            case .ungroupedHeader:
                let cellId = NSUserInterfaceItemIdentifier("UngroupedCell")
                var cell = outlineView.makeView(withIdentifier: cellId, owner: self) as? FolderTableCellView
                if cell == nil {
                    cell = FolderTableCellView()
                    cell?.identifier = cellId
                }
                cell?.configure(title: "Ungrouped", iconName: "tray.fill", count: node.children.count)
                return cell

            case .connection(let connection):
                let cellId = NSUserInterfaceItemIdentifier("ServerCell")
                var cell = outlineView.makeView(withIdentifier: cellId, owner: self) as? ServerTableCellView
                if cell == nil {
                    cell = ServerTableCellView()
                    cell?.identifier = cellId
                }
                cell?.configure(connection: connection)
                return cell
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? ServerOutlineNode {
                collapsedFolderIds.insert(node.idString)
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? ServerOutlineNode {
                collapsedFolderIds.remove(node.idString)
            }
        }

        // MARK: - Actions

        @objc func onDoubleClick(_ sender: NSOutlineView) {
            let clickedRow = sender.clickedRow
            guard clickedRow >= 0, let node = sender.item(atRow: clickedRow) as? ServerOutlineNode else { return }

            switch node.kind {
            case .connection(let conn):
                parent.onConnect(conn)
            case .folder, .ungroupedHeader:
                if sender.isItemExpanded(node) {
                    sender.collapseItem(node)
                } else {
                    sender.expandItem(node)
                }
            }
        }

        // MARK: - Drag & Drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? ServerOutlineNode, case .connection(let conn) = node.kind else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(conn.id.uuidString, forType: .string)
            return pbItem
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let targetNode = item as? ServerOutlineNode else { return [] }
            switch targetNode.kind {
            case .folder, .ungroupedHeader:
                return .move
            case .connection:
                return []
            }
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let pbString = info.draggingPasteboard.string(forType: .string),
                  let connId = UUID(uuidString: pbString),
                  let conn = parent.connections.first(where: { $0.id == connId }),
                  let targetNode = item as? ServerOutlineNode else { return false }

            switch targetNode.kind {
            case .folder(let folder):
                parent.onMove(conn, folder)
                return true
            case .ungroupedHeader:
                parent.onMove(conn, nil)
                return true
            case .connection:
                return false
            }
        }

        // MARK: - ServerContextMenuDelegate

        func contextMenu(for node: ServerOutlineNode) -> NSMenu? {
            let menu = NSMenu()

            switch node.kind {
            case .connection(let conn):
                let connectThis = NSMenuItem(title: "Connect in this Pane", action: #selector(handleConnectInThisPane(_:)), keyEquivalent: "")
                connectThis.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
                connectThis.target = self
                connectThis.representedObject = conn
                menu.addItem(connectThis)

                let connectOther = NSMenuItem(title: "Connect in Other Pane", action: #selector(handleConnectInOtherPane(_:)), keyEquivalent: "")
                connectOther.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: nil)
                connectOther.target = self
                connectOther.representedObject = conn
                menu.addItem(connectOther)

                if conn.connectionType == .sftp {
                    let terminalItem = NSMenuItem(title: "Open in Terminal (SSH)", action: #selector(handleOpenTerminal(_:)), keyEquivalent: "")
                    terminalItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
                    terminalItem.target = self
                    terminalItem.representedObject = conn
                    menu.addItem(terminalItem)
                }

                menu.addItem(.separator())

                let editItem = NSMenuItem(title: "Edit…", action: #selector(handleEdit(_:)), keyEquivalent: "")
                editItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
                editItem.target = self
                editItem.representedObject = conn
                menu.addItem(editItem)

                let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(handleDuplicate(_:)), keyEquivalent: "")
                duplicateItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
                duplicateItem.target = self
                duplicateItem.representedObject = conn
                menu.addItem(duplicateItem)

                if !parent.folders.isEmpty {
                    let moveMenu = NSMenu()
                    let noneItem = NSMenuItem(title: "None (Ungrouped)", action: #selector(handleMoveToNone(_:)), keyEquivalent: "")
                    noneItem.target = self
                    noneItem.representedObject = conn
                    moveMenu.addItem(noneItem)
                    moveMenu.addItem(.separator())

                    for folder in parent.folders {
                        let folderItem = NSMenuItem(title: folder.name, action: #selector(handleMoveToFolder(_:)), keyEquivalent: "")
                        folderItem.target = self
                        folderItem.representedObject = (conn, folder)
                        moveMenu.addItem(folderItem)
                    }

                    let moveItem = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
                    moveItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                    moveItem.submenu = moveMenu
                    menu.addItem(moveItem)
                }

                menu.addItem(.separator())

                let deleteItem = NSMenuItem(title: "Delete", action: #selector(handleDelete(_:)), keyEquivalent: "")
                deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
                deleteItem.target = self
                deleteItem.representedObject = conn
                menu.addItem(deleteItem)

            case .folder(let folder):
                let deleteFolderItem = NSMenuItem(title: "Delete Folder", action: #selector(handleDeleteFolder(_:)), keyEquivalent: "")
                deleteFolderItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
                deleteFolderItem.target = self
                deleteFolderItem.representedObject = folder
                menu.addItem(deleteFolderItem)

            case .ungroupedHeader:
                return emptyAreaContextMenu()
            }

            return menu
        }

        func emptyAreaContextMenu() -> NSMenu? {
            let menu = NSMenu()

            let newConn = NSMenuItem(title: "New Connection…", action: #selector(handleNewConnection(_:)), keyEquivalent: "")
            newConn.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            newConn.target = self
            menu.addItem(newConn)

            let newFolder = NSMenuItem(title: "New Folder…", action: #selector(handleNewFolder(_:)), keyEquivalent: "")
            newFolder.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            newFolder.target = self
            menu.addItem(newFolder)

            return menu
        }

        // Action Handlers
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

        @objc private func handleNewConnection(_ sender: NSMenuItem) {
            parent.onNewConnection()
        }

        @objc private func handleNewFolder(_ sender: NSMenuItem) {
            parent.onNewFolder()
        }
    }
}

// MARK: - ServerOutlineView Subclass

protocol ServerContextMenuDelegate: AnyObject {
    func contextMenu(for node: ServerOutlineNode) -> NSMenu?
    func emptyAreaContextMenu() -> NSMenu?
}

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

// MARK: - Custom Cells

final class ServerTableCellView: NSTableCellView {
    private let iconImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Icon
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)

        // Labels Container
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(detailLabel)

        // Badge Container
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.boxType = .custom
        badgeContainer.borderWidth = 0
        badgeContainer.cornerRadius = 4
        badgeContainer.fillColor = NSColor.labelColor.withAlphaComponent(0.06)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 9, weight: .medium)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .center
        badgeContainer.addSubview(badgeLabel)
        addSubview(badgeContainer)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 20),
            iconImageView.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -6),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -6),

            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeContainer.heightAnchor.constraint(equalToConstant: 16),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -5),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor)
        ])
    }

    func configure(connection: Connection) {
        nameLabel.stringValue = connection.name
        detailLabel.stringValue = connection.connectionString
        badgeLabel.stringValue = connection.connectionType.displayName

        let iconName = connection.iconName
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            iconImageView.image = img.withSymbolConfiguration(config)
        }

        switch connection.connectionType {
        case .sftp:
            iconImageView.contentTintColor = .systemBlue
        case .s3:
            iconImageView.contentTintColor = .systemOrange
        case .local:
            iconImageView.contentTintColor = .systemGreen
        }
    }
}

final class FolderTableCellView: NSTableCellView {
    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 14),
            iconImageView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(folder: Folder, count: Int) {
        titleLabel.stringValue = folder.name
        countLabel.stringValue = "(\(count))"
        if let img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) {
            iconImageView.image = img
            iconImageView.contentTintColor = .controlAccentColor
        }
    }

    func configure(title: String, iconName: String, count: Int) {
        titleLabel.stringValue = title
        countLabel.stringValue = "(\(count))"
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            iconImageView.image = img
            iconImageView.contentTintColor = .secondaryLabelColor
        }
    }
}
