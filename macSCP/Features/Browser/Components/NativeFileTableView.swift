//
//  NativeFileTableView.swift
//  macSCP
//
//  NSViewRepresentable wrapping NSOutlineView for Finder-style tree list with
//  collapsible folders, compact row height, and native drag-and-drop support.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Tree Node

/// Wrapper that represents one row in the outline view.
/// Each node holds a RemoteFile and, once expanded, its lazily-loaded children.
final class FileTreeNode {
    let file: RemoteFile
    var children: [FileTreeNode]?   // nil = not yet loaded; [] = empty folder
    var isLoading: Bool = false

    init(file: RemoteFile) {
        self.file = file
    }

    var isExpandable: Bool { file.isDirectory }
}

// MARK: - NativeFileTableView

// MARK: - Drag & Drop Payload

struct DraggedItemPayload: Codable {
    let sourcePosition: String
    let file: RemoteFile
}

final class MacSCPFilePromiseProvider: NSFilePromiseProvider {
    var payloadData: Data?
    var localURL: URL?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        types.append(NativeFileTableView.macSCPDragType)
        if localURL != nil {
            types.append(.fileURL)
        }
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == NativeFileTableView.macSCPDragType {
            return payloadData
        }
        if type == .fileURL, let localURL = localURL {
            return localURL.absoluteString
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

// MARK: - NativeFileTableView

struct NativeFileTableView: NSViewRepresentable {
    static let macSCPDragType = NSPasteboard.PasteboardType("com.macscp.file-drag")

    @Bindable var viewModel: FileBrowserViewModel
    let files: [RemoteFile]
    let onDoubleClick: (RemoteFile) -> Void
    let onGetInfo: (RemoteFile) -> Void
    let onOpenEditor: ((RemoteFile) -> Void)?
    var panePosition: PanePosition? = nil
    var transferToOtherPaneTitle: String? = nil
    var transferToOtherPaneIcon: String = "arrow.right.circle"
    var onTransferToOtherPane: ((RemoteFile) -> Void)? = nil
    var onDropRemoteFiles: (([RemoteFile], PanePosition?) -> Void)? = nil

    init(
        viewModel: FileBrowserViewModel,
        files: [RemoteFile],
        onDoubleClick: @escaping (RemoteFile) -> Void,
        onGetInfo: @escaping (RemoteFile) -> Void,
        onOpenEditor: ((RemoteFile) -> Void)? = nil,
        panePosition: PanePosition? = nil,
        transferToOtherPaneTitle: String? = nil,
        transferToOtherPaneIcon: String = "arrow.right.circle",
        onTransferToOtherPane: ((RemoteFile) -> Void)? = nil,
        onDropRemoteFiles: (([RemoteFile], PanePosition?) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.files = files
        self.onDoubleClick = onDoubleClick
        self.onGetInfo = onGetInfo
        self.onOpenEditor = onOpenEditor
        self.panePosition = panePosition
        self.transferToOtherPaneTitle = transferToOtherPaneTitle
        self.transferToOtherPaneIcon = transferToOtherPaneIcon
        self.onTransferToOtherPane = onTransferToOtherPane
        self.onDropRemoteFiles = onDropRemoteFiles
    }

    // MARK: makeNSView

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let outlineView = ContextMenuOutlineView()

        // ── Columns ────────────────────────────────────────────────────────────

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Name"
        nameColumn.width = 260
        nameColumn.minWidth = 150
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)

        let dateColumn = NSTableColumn(identifier: .init("date"))
        dateColumn.title = "Date Modified"
        dateColumn.width = 160
        dateColumn.minWidth = 100
        dateColumn.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: true)

        let sizeColumn = NSTableColumn(identifier: .init("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 80
        sizeColumn.minWidth = 50
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)

        let kindColumn = NSTableColumn(identifier: .init("kind"))
        kindColumn.title = "Kind"
        kindColumn.width = 120
        kindColumn.minWidth = 80
        kindColumn.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true)

        outlineView.addTableColumn(nameColumn)
        outlineView.addTableColumn(dateColumn)
        outlineView.addTableColumn(sizeColumn)
        outlineView.addTableColumn(kindColumn)
        outlineView.outlineTableColumn = nameColumn

        // ── Appearance ─────────────────────────────────────────────────────────
        // Match Finder list view: compact rows, alternating backgrounds, no grid
        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.rowHeight = 20          // Finder compact row height
        outlineView.intercellSpacing = NSSize(width: 6, height: 1)
        outlineView.gridStyleMask = []
        outlineView.indentationPerLevel = 16
        outlineView.indentationMarkerFollowsCell = true
        outlineView.autoresizesOutlineColumn = false

        // ── Actions ────────────────────────────────────────────────────────────
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        // ── Drag & Drop ────────────────────────────────────────────────────────
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.registerForDraggedTypes([
            NativeFileTableView.macSCPDragType,
            .fileURL,
            NSPasteboard.PasteboardType("com.apple.NSFilePromiseProvider")
        ])

        outlineView.dataSource = context.coordinator
        outlineView.delegate   = context.coordinator
        outlineView.contextMenuDelegate = context.coordinator

        // ── ScrollView ─────────────────────────────────────────────────────────
        scrollView.documentView      = outlineView
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers    = true
        scrollView.borderType            = .noBorder

        context.coordinator.outlineView = outlineView
        return scrollView
    }

    // MARK: updateNSView

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.viewModel                 = viewModel
        coordinator.files                     = files
        coordinator.onDoubleClick             = onDoubleClick
        coordinator.onGetInfo                 = onGetInfo
        coordinator.onOpenEditor              = onOpenEditor
        coordinator.panePosition              = panePosition
        coordinator.transferToOtherPaneTitle  = transferToOtherPaneTitle
        coordinator.transferToOtherPaneIcon   = transferToOtherPaneIcon
        coordinator.onTransferToOtherPane     = onTransferToOtherPane
        coordinator.onDropRemoteFiles         = onDropRemoteFiles

        guard let outlineView = coordinator.outlineView else { return }

        coordinator.isUpdating = true
        coordinator.rebuildRootNodes()
        outlineView.reloadData()

        // Re-sync selection across all visible (expanded) rows
        let selectedIndexes = NSMutableIndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileTreeNode,
               viewModel.selectedFiles.contains(node.file.id) {
                selectedIndexes.add(row)
            }
        }
        outlineView.selectRowIndexes(selectedIndexes as IndexSet,
                                     byExtendingSelection: false)
        coordinator.isUpdating = false
    }

    // MARK: makeCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(
            viewModel: viewModel,
            files: files,
            onDoubleClick: onDoubleClick,
            onGetInfo: onGetInfo,
            onOpenEditor: onOpenEditor,
            panePosition: panePosition,
            transferToOtherPaneTitle: transferToOtherPaneTitle,
            transferToOtherPaneIcon: transferToOtherPaneIcon,
            onTransferToOtherPane: onTransferToOtherPane,
            onDropRemoteFiles: onDropRemoteFiles
        )
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject,
                       NSOutlineViewDataSource,
                       NSOutlineViewDelegate,
                       NSFilePromiseProviderDelegate,
                       ContextMenuOutlineViewDelegate {

        var viewModel: FileBrowserViewModel
        var files: [RemoteFile]
        var onDoubleClick: (RemoteFile) -> Void
        var onGetInfo: (RemoteFile) -> Void
        var onOpenEditor: ((RemoteFile) -> Void)?
        var panePosition: PanePosition?
        var transferToOtherPaneTitle: String?
        var transferToOtherPaneIcon: String
        var onTransferToOtherPane: ((RemoteFile) -> Void)?
        var onDropRemoteFiles: (([RemoteFile], PanePosition?) -> Void)?
        weak var outlineView: NSOutlineView?
        var isUpdating = false

        /// Top-level nodes mirroring viewModel.sortedFiles
        var rootNodes: [FileTreeNode] = []

        private var draggedFiles: [RemoteFile] = []
        private let filePromiseQueue = OperationQueue()

        init(
            viewModel: FileBrowserViewModel,
            files: [RemoteFile],
            onDoubleClick: @escaping (RemoteFile) -> Void,
            onGetInfo: @escaping (RemoteFile) -> Void,
            onOpenEditor: ((RemoteFile) -> Void)?,
            panePosition: PanePosition? = nil,
            transferToOtherPaneTitle: String? = nil,
            transferToOtherPaneIcon: String = "arrow.right.circle",
            onTransferToOtherPane: ((RemoteFile) -> Void)? = nil,
            onDropRemoteFiles: (([RemoteFile], PanePosition?) -> Void)? = nil
        ) {
            self.viewModel                = viewModel
            self.files                    = files
            self.onDoubleClick            = onDoubleClick
            self.onGetInfo                = onGetInfo
            self.onOpenEditor             = onOpenEditor
            self.panePosition             = panePosition
            self.transferToOtherPaneTitle = transferToOtherPaneTitle
            self.transferToOtherPaneIcon  = transferToOtherPaneIcon
            self.onTransferToOtherPane     = onTransferToOtherPane
            self.onDropRemoteFiles        = onDropRemoteFiles
            filePromiseQueue.qualityOfService = .userInitiated
        }

        // ── Helpers ────────────────────────────────────────────────────────────

        /// Rebuild root nodes from the current viewModel.sortedFiles.
        /// Existing expanded nodes keep their children so collapse state is preserved.
        func rebuildRootNodes() {
            let existingByPath = Dictionary(
                uniqueKeysWithValues: rootNodes.map { ($0.file.path, $0) }
            )
            rootNodes = files.map { file in
                if let existing = existingByPath[file.path] {
                    return existing
                }
                return FileTreeNode(file: file)
            }
        }

        private func node(for item: Any?) -> FileTreeNode? {
            item as? FileTreeNode
        }

        // ── NSOutlineViewDataSource ────────────────────────────────────────────

        func outlineView(_ outlineView: NSOutlineView,
                         numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil { return rootNodes.count }
            guard let n = node(for: item) else { return 0 }
            return n.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView,
                         child index: Int,
                         ofItem item: Any?) -> Any {
            if item == nil { return rootNodes[index] }
            guard let n = node(for: item),
                  let children = n.children,
                  index < children.count else {
                return FileTreeNode(file: .placeholder)
            }
            return children[index]
        }

        func outlineView(_ outlineView: NSOutlineView,
                         isItemExpandable item: Any) -> Bool {
            node(for: item)?.isExpandable ?? false
        }

        // ── NSOutlineViewDelegate ──────────────────────────────────────────────

        func outlineView(_ outlineView: NSOutlineView,
                         viewFor tableColumn: NSTableColumn?,
                         item: Any) -> NSView? {
            guard let n = node(for: item) else { return nil }
            let file = n.file
            let columnId = tableColumn?.identifier.rawValue ?? ""
            let cellId = NSUserInterfaceItemIdentifier("OCell_\(columnId)")

            var cell = outlineView.makeView(withIdentifier: cellId, owner: nil)
                       as? NSTableCellView

            if cell == nil {
                cell = NSTableCellView()
                cell?.identifier = cellId

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                tf.font = .systemFont(ofSize: 12)
                cell?.addSubview(tf)
                cell?.textField = tf

                if columnId == "name" {
                    let iv = NSImageView()
                    iv.translatesAutoresizingMaskIntoConstraints = false
                    iv.imageScaling = .scaleProportionallyUpOrDown
                    cell?.addSubview(iv)
                    cell?.imageView = iv

                    NSLayoutConstraint.activate([
                        iv.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 2),
                        iv.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 16),
                        iv.heightAnchor.constraint(equalToConstant: 16),
                        tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                        tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4),
                        tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
                    ])
                } else {
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                        tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4),
                        tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
                    ])
                }
            }

            switch columnId {
            case "name":
                cell?.textField?.stringValue = file.name
                cell?.textField?.textColor   = .labelColor
                cell?.imageView?.image       = FileTypeService.systemIcon(for: file)
                cell?.imageView?.contentTintColor = nil
            case "date":
                cell?.textField?.stringValue = file.modificationDate?.fileListDisplayString ?? "--"
                cell?.textField?.textColor   = .secondaryLabelColor
            case "size":
                cell?.textField?.stringValue = file.displaySize
                cell?.textField?.textColor   = .secondaryLabelColor
            case "kind":
                cell?.textField?.stringValue = FileTypeService.typeDescription(for: file)
                cell?.textField?.textColor   = .secondaryLabelColor
            default:
                break
            }

            return cell
        }

        /// Row height — match Finder list view (20 pt content + 1 pt spacing).
        func outlineView(_ outlineView: NSOutlineView,
                         heightOfRowByItem item: Any) -> CGFloat {
            20
        }

        // ── Expand / collapse with lazy child loading ──────────────────────────

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let n = notification.userInfo?["NSObject"] as? FileTreeNode,
                  n.children == nil,
                  !n.isLoading else { return }

            n.isLoading = true
            Task { @MainActor [weak self] in
                guard let self, let ov = self.outlineView else { return }
                do {
                    let children = try await self.viewModel.listChildFiles(at: n.file.path)
                    let sorted   = RemoteFile.sortedFiles(
                        children,
                        by: self.viewModel.sortCriteria,
                        ascending: self.viewModel.sortAscending
                    )
                    n.children  = sorted.map { FileTreeNode(file: $0) }
                } catch {
                    n.children = []
                }
                n.isLoading = false

                ov.reloadItem(n, reloadChildren: true)
                // NSOutlineView will finish the expand automatically because
                // numberOfChildrenOfItem now returns the correct count.
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            // Keep children cached so re-expanding is instant.
            // If you want to force-reload on next expand, set n.children = nil here.
        }

        // ── Selection ─────────────────────────────────────────────────────────

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let ov = outlineView else { return }
            var sel = Set<UUID>()
            var firstSelectedFile: RemoteFile?
            for row in ov.selectedRowIndexes {
                if let n = ov.item(atRow: row) as? FileTreeNode {
                    sel.insert(n.file.id)
                    if firstSelectedFile == nil {
                        firstSelectedFile = n.file
                    }
                }
            }
            viewModel.selectedFiles = sel
            viewModel.primarySelectedFile = firstSelectedFile
        }

        // ── Sort ──────────────────────────────────────────────────────────────

        func outlineView(_ outlineView: NSOutlineView,
                         sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let sd = outlineView.sortDescriptors.first,
                  let key = sd.key else { return }
            switch key {
            case "name": viewModel.sortCriteria = .name
            case "kind": viewModel.sortCriteria = .type
            case "date": viewModel.sortCriteria = .date
            case "size": viewModel.sortCriteria = .size
            default: break
            }
            viewModel.sortAscending = sd.ascending
        }

        // ── Double click ──────────────────────────────────────────────────────

        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0 else { return }
            guard let n = sender.item(atRow: row) as? FileTreeNode else { return }
            onDoubleClick(n.file)
        }

        // MARK: - Drag OUT (File Promise)

        func outlineView(_ outlineView: NSOutlineView,
                         pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let n = node(for: item) else { return nil }
            let file = n.file

            let utType = file.isDirectory ? UTType.folder.identifier : UTType.data.identifier
            let provider = MacSCPFilePromiseProvider(fileType: utType, delegate: self)
            provider.userInfo = ["file": file]

            let payload = DraggedItemPayload(
                sourcePosition: panePosition?.rawValue ?? "",
                file: file
            )
            provider.payloadData = try? JSONEncoder().encode(payload)

            if viewModel.isLocal {
                provider.localURL = URL(fileURLWithPath: file.path)
            }

            return provider
        }

        func outlineView(_ outlineView: NSOutlineView,
                         draggingSession session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint,
                         forItems draggedItems: [Any]) {
            draggedFiles = draggedItems.compactMap { ($0 as? FileTreeNode)?.file }
        }

        func outlineView(_ outlineView: NSOutlineView,
                         draggingSession session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
            draggedFiles = []
        }

        // MARK: NSFilePromiseProviderDelegate

        func filePromiseProvider(_ p: NSFilePromiseProvider,
                                 fileNameForType type: String) -> String {
            (p.userInfo as? [String: Any]).flatMap { $0["file"] as? RemoteFile }?.name ?? "file"
        }

        func filePromiseProvider(_ p: NSFilePromiseProvider,
                                 writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            guard let file = (p.userInfo as? [String: Any])?["file"] as? RemoteFile else {
                completionHandler(nil); return
            }
            Task { @MainActor in
                do {
                    if file.isDirectory {
                        try await RemoteStreamTransferEngine.transfer(
                            file: file,
                            from: viewModel.fileRepository,
                            to: LocalFileRepository(),
                            targetDirectory: url.deletingLastPathComponent().path
                        )
                    } else {
                        try await viewModel.downloadFileToURL(file, destinationURL: url)
                    }
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }

        func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue {
            filePromiseQueue
        }

        // MARK: - Drop IN (Upload & Inter-Pane Transfer)

        func outlineView(_ outlineView: NSOutlineView,
                         validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            // Do not drop onto the same outline view
            if info.draggingSource as? NSOutlineView == outlineView {
                return []
            }

            // Inter-pane drag (macSCPDragType)
            if info.draggingPasteboard.types?.contains(NativeFileTableView.macSCPDragType) == true {
                outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .copy
            }

            // Drop from Finder or external apps
            if info.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) {
                outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .copy
            }

            return []
        }

        func outlineView(_ outlineView: NSOutlineView,
                         acceptDrop info: NSDraggingInfo,
                         item: Any?,
                         childIndex index: Int) -> Bool {
            let pb = info.draggingPasteboard

            // 1. Inter-pane drag within macSCP
            if pb.types?.contains(NativeFileTableView.macSCPDragType) == true,
               let items = pb.pasteboardItems {
                var droppedFiles: [RemoteFile] = []
                var sourcePosition: PanePosition?

                for pbItem in items {
                    if let data = pbItem.data(forType: NativeFileTableView.macSCPDragType),
                       let payload = try? JSONDecoder().decode(DraggedItemPayload.self, from: data) {
                        droppedFiles.append(payload.file)
                        if sourcePosition == nil, let pos = PanePosition(rawValue: payload.sourcePosition) {
                            sourcePosition = pos
                        }
                    }
                }

                if !droppedFiles.isEmpty {
                    onDropRemoteFiles?(droppedFiles, sourcePosition)
                    return true
                }
            }

            // 2. Drop from Finder or external apps
            if let urls = pb.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                let valid = urls.filter { url in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path,
                                                          isDirectory: &isDir)
                }
                guard !valid.isEmpty else { return false }

                Task { @MainActor in
                    await viewModel.uploadDroppedFiles(valid)
                }
                return true
            }

            return false
        }
    }
}

// MARK: - RemoteFile placeholder

private extension RemoteFile {
    static var placeholder: RemoteFile {
        RemoteFile(name: "", path: "", isDirectory: false,
                   size: 0, permissions: "")
    }
}

// MARK: - Context Menu Support

extension NativeFileTableView.Coordinator {

    func contextMenu(for row: Int) -> NSMenu? {
        guard let ov = outlineView,
              let n = ov.item(atRow: row) as? FileTreeNode else { return nil }
        let file = n.file

        let menu = NSMenu()

        if file.isFile {
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

        addItem(menu, title: "Copy",   action: #selector(handleCopy(_:)),   image: "doc.on.doc",          object: file)
        addItem(menu, title: "Cut",    action: #selector(handleCut(_:)),    image: "scissors",             object: file)
        if viewModel.canPaste {
            addItem(menu, title: "Paste", action: #selector(handlePaste(_:)), image: "doc.on.clipboard", object: file)
        }
        if let transferTitle = transferToOtherPaneTitle, onTransferToOtherPane != nil {
            menu.addItem(.separator())
            addItem(menu, title: transferTitle,
                    action: #selector(handleTransferToOtherPane(_:)),
                    image: transferToOtherPaneIcon,
                    object: file)
        }
        menu.addItem(.separator())
        addItem(menu, title: "Rename",   action: #selector(handleRename(_:)),   image: "pencil",        object: file)
        addItem(menu, title: "Get Info", action: #selector(handleGetInfo(_:)),  image: "info.circle",   object: file)
        menu.addItem(.separator())
        if file.isFile {
            addItem(menu, title: "Download", action: #selector(handleDownload(_:)), image: "arrow.down.circle", object: file)
            menu.addItem(.separator())
        }
        addItem(menu, title: "Delete", action: #selector(handleDelete(_:)), image: "trash", object: file)

        return menu
    }

    private func addItem(_ menu: NSMenu,
                         title: String,
                         action: Selector,
                         image: String,
                         object: RemoteFile) {
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
        guard let f = s.representedObject as? RemoteFile else { return }
        viewModel.selectedFiles = [f.id]; viewModel.copySelectedFiles()
    }
    @objc func handleCut(_ s: NSMenuItem) {
        guard let f = s.representedObject as? RemoteFile else { return }
        viewModel.selectedFiles = [f.id]; viewModel.cutSelectedFiles()
    }
    @objc func handlePaste(_ s: NSMenuItem) {
        Task { @MainActor in await viewModel.paste() }
    }
    @objc func handleTransferToOtherPane(_ s: NSMenuItem) {
        guard let f = s.representedObject as? RemoteFile else { return }
        if !viewModel.selectedFiles.contains(f.id) {
            viewModel.selectedFiles = [f.id]
        }
        onTransferToOtherPane?(f)
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
        (s.representedObject as? RemoteFile).map { viewModel.confirmDelete([$0]) }
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
}
