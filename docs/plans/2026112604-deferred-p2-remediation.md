# Implementation Plan: Deferred P2 Technical Debt Remediation

- **Date:** 2026-11-26
- **Related Specs:** `SPEC-01`, `SPEC-02`, `SPEC-03`, `SPEC-05`, `SPEC-06`
- **Related Technical Debt:** `docs/technical-debt.md` (§2.1, §4, §5 Deferred P2)

## Scope

Resolve the remaining Deferred P2 items in `docs/technical-debt.md`:

### 1. Split Large AppKit Outline Views (§2.1)
- **`NativeFileTableView` (`SPEC-05`):**
  - Keep `NativeFileTableView.swift` focused on `FileTreeNode`, `NativeFileTableView` (`NSViewRepresentable`), and core `Coordinator` (`NSOutlineViewDataSource`, `NSOutlineViewDelegate`, cell configuration, lazy folder expansion, selection, sorting, double-click).
  - Extract `NativeFileTableView+DragDrop.swift` (`DraggedItemPayload`, `MacSCPFilePromiseProvider`, `NSFilePromiseProviderDelegate`, drag-out and drop-in handlers).
  - Extract `NativeFileTableView+ContextMenu.swift` (`ContextMenuOutlineViewDelegate`, `ContextMenuOutlineView`, context menu construction and `@objc` menu handlers).
- **`NativeServersTableView` (`SPEC-01`):**
  - Keep `NativeServersTableView.swift` focused on `ServerOutlineNode`, `NativeServersTableView` (`NSViewRepresentable`), and core `Coordinator` (node building, data source, delegate, double-click, drag-and-drop).
  - Extract `NativeServersTableView+ContextMenu.swift` (`ServerContextMenuDelegate`, `ServerOutlineView`, context menu construction with helper, and `@objc` menu handlers).
  - Extract `ServerTableCellViews.swift` (`ServerTableCellView`, `FolderTableCellView`).

### 2. Refactor Long Methods (§2.1)
- **`FileTypeService.typeDescription` (`SPEC-05`):** Replace the 126-line nested `switch` with a static extension lookup dictionary and concise `FileType` fallback mapping.
- **`SFTPTransferEngine` (`SPEC-03`):** Decompose `downloadSingleFile` and `uploadSingleFile` into focused helpers (`prepareLocalDestinationFile`, `downloadSmallFile`, `downloadWithSlidingWindow`, `uploadSmallFile`, `uploadWithSlidingWindow`).
- **`BatchTransferCoordinator` (`SPEC-06`):** Decompose `executeBatch` and `transferSingleItemWithRetry` into focused helpers (`runWorkerPool`, `markRemainingItemsCancelled`, `executeTransferWithRetries`).

### 3. Deep Unit Test Coverage (§4)
- **`FileTypeServiceTests`:** Cover `typeDescription`, `mimeType`, `isPreviewable`, `formatPermissions`, `groupByType`, and `filter`.
- **`SwiftDataRepositoryTests`:** Cover `ConnectionRepository` and `FolderRepository` CRUD, folder filtering, search, counts, display ordering, folder deletion nullify behavior, and `entityNotFound` errors against an isolated in-memory `DataStore(inMemoryOnly: true)`.
- **`LocalFileRepositoryTests`:** Cover directory/file CRUD, permissions formatting, UTF-8 and non-UTF-8 (`invalidFileEncoding`) reads, upload/download progress, and `LocalFileStreamReader` / `writeStream`.
- **`SFTPEngineTests`:**
  - `SFTPMessages` & `SFTPFileAttributes` serialization/deserialization round-trips and malformed/partial packet handling.
  - In-process `NIOPosix` loopback `MockSFTPServer` exercising `SFTPClient`, `SFTPTransferEngine` (empty, small fast-path, multi-chunk sliding window, recursive directory upload/download), and `SFTPSession` (via `internal init(client:currentPath:)` for CRUD, streaming, UTF-8 validation, and `parseError` mapping).

## Verification Plan
1. Run `xcodebuild test -project macSCP.xcodeproj -scheme macSCP -destination 'platform=macOS'` and confirm all unit tests pass.
2. Run `node .gitnexus/run.cjs detect-changes --scope all --repo .`.
3. Update `docs/technical-debt.md` and affected specs in `docs/specs/`.
