# Implementation Plan: P0 Technical Debt Remediation (Items 1.2 – 1.6)

- **Date:** 2026-11-26
- **Related Specs:** `SPEC-00`, `SPEC-01`, `SPEC-03`, `SPEC-04`, `SPEC-06`, `SPEC-07`, `SPEC-09`
- **Related Technical Debt:** `docs/technical-debt.md` (§1.2, §1.3, §1.4, §1.5, §1.6)

## Scope

Resolve all remaining P0 technical debt items in `docs/technical-debt.md`:

1. **§1.2 — Session Race Condition & Leak in `CommanderViewModel`** (`SPEC-01`)
   - Capture `previousVM` and remote status **before** mutating `targetPane.contentType` and `targetPane.browserViewModel` in `switchToLocal`, `switchToServers`, `disconnect`, and `completeConnect`.
   - Disconnect `previousVM` asynchronously without affecting the newly assigned `browserViewModel`.

2. **§1.3 — Data Races & `@unchecked Sendable` Elimination** (`SPEC-03`, `SPEC-04`, `SPEC-06`)
   - Replace unsynchronized `CancellationBox` in `BatchTransferCoordinator.transferSingleItemWithRetry` with `OSAllocatedUnfairLock` storing both `isCancelled` and `cancelAction`, preventing both data races and cancel-before-task-start races.
   - Replace `ProgressState` `@unchecked Sendable` wrapper in `BatchTransferCoordinator.executeBatch` with a local `itemIndex` variable.
   - Convert `SFTPStreamReader`, `S3StreamReader`, `LocalFileStreamReader`, and `MemoryStreamReader` from `@unchecked Sendable` classes to `actor`s conforming to `FileStreamReader`.

3. **§1.4 — Non-UTF-8 Silent Data Loss in File Reading** (`SPEC-03`, `SPEC-07`)
   - Add `AppError.invalidFileEncoding` with clear `errorDescription` and `recoverySuggestion`.
   - Throw `AppError.invalidFileEncoding` in `SFTPSession.readFileContent`, `S3Session.readFileContent`, and `LocalFileRepository.readFileContent` when file bytes are not valid UTF-8 (instead of returning `""` or lossy U+FFFD replacement).

4. **§1.5 — Inactivity Lock Bug in `AppLockManager`** (`SPEC-09`)
   - Register a throttled `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel])` in `AppLockManager` to reset the inactivity timer on real user interaction.
   - Clean up observers and event monitor in `deinit`.
   - Expose `internal init(biometricService:userDefaults:installEventMonitor:)` for unit testing.

5. **§1.6 — Eliminate `fatalError()` & Force Unwraps** (`SPEC-00`, `SPEC-01`, `SPEC-04`)
   - `DataStore.swift`: Add in-memory `ModelContainer` fallback and expose `initializationError: String?` / `isUsingInMemoryFallback: Bool`; surface a non-blocking warning alert in `CommanderWorkspaceView` if fallback is active; update `DataStore.preview` to use `inMemoryOnly: true`.
   - `NativeServersTableView.swift`: Replace `fatalError()` in `outlineView(_:child:ofItem:)` with bounds/type guards + error logging + safe `NSNull()` fallback.
   - `S3Session.swift`: Use local `let client = S3Client(config: configuration)` instead of force-unwrapping `s3!`.

## Verification Plan

1. Add/update unit tests covering:
   - `CommanderViewModelTests`: verify previous remote session `disconnect()` is called (and new local/remote session is NOT disconnected) on `switchToLocal`, `switchToServers`, and `completeConnect`.
   - `RemoteStreamTransferEngineTests`: verify concurrent reads + `close()` on `MemoryStreamReader` and `LocalFileStreamReader`.
   - `LocalFileRepository` / `AppError`: verify `AppError.invalidFileEncoding` is thrown for non-UTF-8 files and empty files still decode to `""`.
   - `AppLockManagerTests`: verify `recordActivity()` and throttled user interaction handling reset inactivity state properly.
2. Run `xcodebuild test` for the `macSCP` scheme.
3. Run `node .gitnexus/run.cjs detect-changes --scope all --repo .`.
4. Sync `docs/technical-debt.md` and `docs/specs/{00,01,03,04,06,07,09}-*.md`.
