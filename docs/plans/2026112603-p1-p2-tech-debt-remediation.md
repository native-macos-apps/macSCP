# Implementation Plan: P1 & P2 Technical Debt Remediation

- **Date:** 2026-11-26
- **Related Specs:** `SPEC-00`, `SPEC-01`, `SPEC-02`, `SPEC-03`, `SPEC-04`, `SPEC-05`, `SPEC-06`, `SPEC-09`
- **Related Technical Debt:** `docs/technical-debt.md` (§2.1–§2.4, §3.1–§3.3, §4)

## Scope

Resolve the interconnected P1 (Architecture, Modularization, DRY, Consistency, Dead Code) and P2 (Repo Hygiene, Dependency Injection, Unit Test Coverage) technical debt items in `docs/technical-debt.md`:

### 1. Repo Hygiene (§4)
- Remove tracked `macSCP.xcodeproj/xcuserdata/nevilmacwan.xcuserdatad/xcschemes/xcschememanagement.plist` from the Git index (`git rm --cached`); `.gitignore` already ignores `xcuserdata/`.

### 2. Keychain Consolidation & SFTP/S3 Modularization (§2.1, §3.1, §3.3)
- **Keychain (`SPEC-02`, `SPEC-03`):** Extract `KeychainStore` (`macSCP/Data/Keychain/KeychainStore.swift`) to unify `SecItem*` CRUD and `OSStatus` validation across `KeychainService` (passwords + S3 credentials) and `SSHKeyStorageService` (SSH private keys, fixing ignored `SecItemDelete` status).
- **SFTP (`SPEC-03`):** Deduplicate `SFTPSession.connect` password and private-key overloads via a shared `establishConnection` helper.
- **S3 (`SPEC-04`):** Split `S3Session.swift` into focused modules:
  - `macSCP/Data/S3/S3PathResolver.swift` — key/prefix normalization, list/object target resolution, AWS hosted-style & path-style URL builders.
  - `macSCP/Data/S3/S3ErrorMapper.swift` — typed AWS SDK / Smithy error mapping before string fallback.
  - `macSCP/Data/S3/S3Session+Transfers.swift` — file/directory download & upload, multipart upload, `writeStream` helpers, and `S3StreamReader`.
  - Remove unnecessary `Task { @MainActor in logInfo(...) }` wrapper in `S3Session.log(_:)`.

### 3. FileBrowser & Commander Refactoring (§2.1, §2.2, §2.4, §3.1, §3.3)
- **`BrowserSessionProtocol` (`macSCP/Features/Browser/BrowserSession.swift` — `SPEC-05`):** Eliminate protocol-branching (`if isLocal ... else if .s3 ... else ...`) in `FileBrowserViewModel` by encapsulating `connect`, `disconnect`, `currentPath`, `logCategory`, and S3 URL helpers behind `LocalBrowserSession`, `SFTPBrowserSession`, and `S3BrowserSession`.
- **`BrowserQuickLookController` (`macSCP/Features/Browser/BrowserQuickLookController.swift` — `SPEC-05`):**
  - Replace unbounded `[String: QuickLookContent]` dictionary with `NSCache` (bounded count and byte cost).
  - Clear cache on `reset()` (invoked on `disconnect()`).
  - Use `defer` to always clean up temporary image/PDF files on error or cancellation.
  - Never cache `.error(...)` results so transient failures can be retried.
- **`FileTransferManager` (`macSCP/Services/TransferCoordinator/FileTransferManager.swift` — `SPEC-01`, `SPEC-05`, `SPEC-06`):**
  - Unify single-file download, drag-out download, and batch transfer state/snapshot handling shared by `FileBrowserViewModel` and `CommanderViewModel`.
  - Enforce `lastAppliedSnapshotSequence` monotonicity in both `FileBrowserViewModel` and `CommanderViewModel`.
  - Standardize `recentTransfers` cap to `30` everywhere.
  - Propagate `transferType` (`.upload` / `.download`) through `BatchTransferCoordinator.executeBatch`.
  - Replace `String(describing: error).contains("CancellationError")` with typed cancellation checks (`error is CancellationError || Task.isCancelled`).
  - Surface a clear user-facing error instead of silently dropping concurrent batch transfer requests.
  - Use protocol-accurate `LogCategory` (`.local`, `.s3`, `.sftp`) in `FileBrowserViewModel` CRUD operations.

### 4. Dead Code Cleanup & Dependency Injection (§2.3, §3.2)
- Remove dead code: `FileBrowserViewModel.navigateWithoutHistory(to:)`, `DataStore.createWithRecovery()`, `AcceptAllServerAuthDelegate`.
- Align `SSHKeyParser` error messaging with actual Ed25519 support.
- Wire `TransferSettings`, `BatchTransferCoordinator`, `KnownHostsManager`, `BiometricAuthService`, `SSHKeyRepositoryProtocol`, `WindowManager`, and `AppLockManager` through `DependencyContainer` and constructor injection in `FileBrowserViewModel`, `CommanderViewModel`, and `SettingsView`.
- Expose `internal init(userDefaults:)` on `KnownHostsManager` and `SSHKeyStorageService` for isolated testing.

### 5. Unit Tests (§4)
Add dedicated test suites covering:
- `SSHKeyParserTests`
- `KnownHostsManagerTests`
- `TransferRetryPolicyTests`
- `StreamingFileScannerTests`
- `RemoteDirectoryManagerTests`
- `S3PathResolverTests` & `S3ErrorMapperTests`
- `BrowserQuickLookControllerTests`
- `FileTransferManagerTests`
- Expanded `AppLockManager` tests (`enableBiometricLock`, `disableBiometricLock`, `authenticateForConnection`)

## Verification Plan
1. Run `xcodebuild test -project macSCP.xcodeproj -scheme macSCP -destination 'platform=macOS'` and confirm all tests pass.
2. Run `node .gitnexus/run.cjs detect-changes --scope all --repo .`.
3. Update `docs/technical-debt.md` and affected specs in `docs/specs/`.
