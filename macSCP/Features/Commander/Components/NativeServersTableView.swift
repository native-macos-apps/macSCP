//
//  NativeServersTableView.swift
//  macSCP
//
//  NSViewRepresentable wrapping NSOutlineView for native macOS connection list
//  with folder grouping, compact rows, smooth mouse interactions, and native context menus.
//

import SwiftUI
import AppKit

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
    let onRenameFolder: (Folder) -> Void
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
    final class Coordinator: NSObject, NSOutlineViewDelegate, NSOutlineViewDataSource {
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
                guard index >= 0, index < rootNodes.count else {
                    logError("Server outline requested out-of-bounds root index \(index) (count: \(rootNodes.count))", category: .ui)
                    return NSNull()
                }
                return rootNodes[index]
            }
            guard let node = item as? ServerOutlineNode, index >= 0, index < node.children.count else {
                logError("Server outline requested invalid child index \(index) for item \(String(describing: item))", category: .ui)
                return NSNull()
            }
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
                return 28
            case .connection:
                return 38
            }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? ServerOutlineNode else { return nil }

            switch node.kind {
            case .folder(let folder):
                let cell = dequeueFolderCell(in: outlineView, identifier: "FolderCell")
                cell.configure(folder: folder, count: node.children.count)
                return cell

            case .ungroupedHeader:
                let cell = dequeueFolderCell(in: outlineView, identifier: "UngroupedCell")
                cell.configure(title: "Ungrouped", iconName: "tray.fill", count: node.children.count)
                return cell

            case .connection(let connection):
                let cellId = NSUserInterfaceItemIdentifier("ServerCell")
                let cell = (outlineView.makeView(withIdentifier: cellId, owner: self) as? ServerTableCellView) ?? {
                    let created = ServerTableCellView()
                    created.identifier = cellId
                    return created
                }()
                cell.configure(connection: connection)
                return cell
            }
        }

        private func dequeueFolderCell(in outlineView: NSOutlineView, identifier: String) -> FolderTableCellView {
            let cellId = NSUserInterfaceItemIdentifier(identifier)
            if let existing = outlineView.makeView(withIdentifier: cellId, owner: self) as? FolderTableCellView {
                return existing
            }
            let created = FolderTableCellView()
            created.identifier = cellId
            return created
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
    }
}
