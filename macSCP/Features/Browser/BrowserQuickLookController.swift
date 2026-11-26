//
//  BrowserQuickLookController.swift
//  macSCP
//
//  Bounded NSCache-backed Quick Look preview controller with guaranteed temp-file cleanup
//

import Foundation
import Observation

private final class QuickLookCacheEntry: NSObject {
    let content: QuickLookContent

    init(content: QuickLookContent) {
        self.content = content
    }
}

@MainActor
@Observable
final class BrowserQuickLookController {
    var isShowingQuickLook: Bool = false {
        didSet {
            if !isShowingQuickLook {
                loadTask?.cancel()
            }
        }
    }
    var quickLookFile: RemoteFile?
    private(set) var quickLookContent: QuickLookContent = .loading

    private let fileRepository: FileRepositoryProtocol
    private let cache = NSCache<NSString, QuickLookCacheEntry>()
    private var loadTask: Task<Void, Never>?

    init(
        fileRepository: FileRepositoryProtocol,
        maxCacheEntries: Int = 50,
        maxCacheBytes: Int = 50 * 1024 * 1024
    ) {
        self.fileRepository = fileRepository
        self.cache.countLimit = maxCacheEntries
        self.cache.totalCostLimit = maxCacheBytes
    }

    func toggle(for selectedFile: RemoteFile?) {
        if isShowingQuickLook {
            close()
        } else if let file = selectedFile {
            show(for: file)
        }
    }

    func handlePrimarySelectionChanged(_ file: RemoteFile?) {
        guard isShowingQuickLook else { return }
        if let file {
            show(for: file)
        } else {
            quickLookFile = nil
            loadTask?.cancel()
        }
    }

    func show(for file: RemoteFile) {
        isShowingQuickLook = true

        if quickLookFile?.id == file.id { return }

        quickLookFile = file
        loadTask?.cancel()

        if let cached = cache.object(forKey: file.path as NSString) {
            quickLookContent = cached.content
            return
        }

        quickLookContent = .loading
        loadTask = Task { @MainActor [weak self] in
            await self?.loadContent(for: file)
        }
    }

    func close() {
        isShowingQuickLook = false
        loadTask?.cancel()
    }

    func reset() {
        loadTask?.cancel()
        loadTask = nil
        isShowingQuickLook = false
        quickLookFile = nil
        quickLookContent = .loading
        cache.removeAllObjects()
    }

    /// Exposed for unit testing cache lookup behavior.
    func hasCachedEntry(forPath path: String) -> Bool {
        cache.object(forKey: path as NSString) != nil
    }

    /// Loads content for `file`, caching only non-error results and cleaning up temp files via `defer`.
    func loadContent(for file: RemoteFile) async {
        if file.isDirectory || file.size > FileOperationConstants.maxFilePreviewSize {
            let result = QuickLookContent.unsupported
            storeInCache(result, forPath: file.path, cost: 64)
            if quickLookFile?.id == file.id {
                quickLookContent = result
            }
            return
        }

        do {
            switch file.fileType {
            case .image:
                let data = try await downloadTemporaryData(for: file)
                let result = QuickLookContent.image(data)
                storeInCache(result, forPath: file.path, cost: data.count)
                if !Task.isCancelled, quickLookFile?.id == file.id {
                    quickLookContent = result
                }

            case .pdf:
                let data = try await downloadTemporaryData(for: file)
                let result = QuickLookContent.pdf(data)
                storeInCache(result, forPath: file.path, cost: data.count)
                if !Task.isCancelled, quickLookFile?.id == file.id {
                    quickLookContent = result
                }

            case .text, .code, .configuration:
                let content = try await fileRepository.readFileContent(at: file.path)
                let result = QuickLookContent.text(content)
                storeInCache(result, forPath: file.path, cost: content.utf8.count)
                if !Task.isCancelled, quickLookFile?.id == file.id {
                    quickLookContent = result
                }

            default:
                let result = QuickLookContent.unsupported
                storeInCache(result, forPath: file.path, cost: 64)
                if !Task.isCancelled, quickLookFile?.id == file.id {
                    quickLookContent = result
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            // Never cache transient errors so the user can retry previewing the file
            if quickLookFile?.id == file.id {
                quickLookContent = .error(error.localizedDescription)
            }
        }
    }

    private func downloadTemporaryData(for file: RemoteFile) async throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + file.name)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        try await fileRepository.download(remotePath: file.path, to: tempURL) { _ in }
        try Task.checkCancellation()
        return try Data(contentsOf: tempURL)
    }

    private func storeInCache(_ content: QuickLookContent, forPath path: String, cost: Int) {
        cache.setObject(QuickLookCacheEntry(content: content), forKey: path as NSString, cost: max(1, cost))
    }
}
