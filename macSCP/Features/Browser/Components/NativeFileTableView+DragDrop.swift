//
//  NativeFileTableView+DragDrop.swift
//  macSCP
//
//  Drag-out file promises and drop-in upload / inter-pane transfer support
//  for NativeFileTableView.
//

import AppKit
import UniformTypeIdentifiers

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

// MARK: - Drag & Drop Coordinator Support

extension NativeFileTableView.Coordinator: NSFilePromiseProviderDelegate {

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

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(_ p: NSFilePromiseProvider,
                             fileNameForType type: String) -> String {
        (p.userInfo as? [String: Any]).flatMap { $0["file"] as? RemoteFile }?.name ?? "file"
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let file = (p.userInfo as? [String: Any])?["file"] as? RemoteFile else {
            completionHandler(nil)
            return
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
