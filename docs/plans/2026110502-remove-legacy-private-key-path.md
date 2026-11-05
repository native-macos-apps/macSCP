# Remove Legacy `privateKeyPath` and Unify SSH Key Management

**Date**: 2026-11-05
**Status**: Completed

## Objective
Completely eradicate legacy `privateKeyPath` and `securityScopedBookmarkData` across the entire codebase to unify all SSH private key operations under the in-app Keychain-backed key manager (`SSHKeyStorageService` & `sshKeyId`).

## Affected Components
1. **Core Utilities**:
   - `macSCP/Core/Utilities/WindowManager.swift`: Remove `privateKeyPath` and `securityScopedBookmarkData` from `FileBrowserWindowData` and `FileEditorWindowData`.
   - `macSCP/Core/Utilities/TerminalLauncher.swift`: Replace `privateKeyPath: String?` with `sshKeyId: UUID?`. Export Keychain key to a secure temporary `0600` file for Terminal.app SSH sessions.
2. **SFTP Engine**:
   - `macSCP/Data/SFTP/SFTPSessionProtocol.swift`: Remove legacy `connect(..., privateKeyPath:bookmarkData:passphrase:)`.
   - `macSCP/Data/SFTP/SFTPSession.swift`: Remove legacy `connect(..., privateKeyPath:bookmarkData:passphrase:)`.
3. **Data & Persistence**:
   - `macSCP/Domain/Models/Connection.swift`: Remove `privateKeyPath` and `securityScopedBookmarkData`.
   - `macSCP/Data/SwiftData/Entities/ConnectionEntity.swift`: Remove `privateKeyPath` and `securityScopedBookmarkData`.
   - `macSCP/Data/SwiftData/Mappers/ConnectionMapper.swift`: Remove mapping for `privateKeyPath` and `securityScopedBookmarkData`.
4. **Features & ViewModels**:
   - `macSCP/Features/Browser/FileBrowserViewModel.swift`: Remove references in `openEditor`.
   - `macSCP/Features/Browser/FileBrowserWindow.swift`: Remove references in connection construction.
   - `macSCP/Features/Connections/ConnectionListViewModel.swift`: Remove references in `openFileBrowser`, `duplicateConnection`, and `openTerminal`.
   - `macSCP/Features/Commander/CommanderViewModel.swift`: Pass `sshKeyId` to `TerminalLauncher`.
   - `macSCP/Features/Connections/Components/ConnectionFormSheet.swift`: Clean up unused initializers.
5. **Tests & Mocks**:
   - `macSCPTests/Mocks/MockSFTPSession.swift`: Remove legacy connect overload.
   - `macSCPTests/Services/SecurityAndTransferTests.swift`: Remove legacy parameters.

## Verification
- Run `xcodebuild build` to verify clean compilation with zero deprecated parameters.
- Run `xcodebuild test` to ensure all tests pass.
- Check `git grep privateKeyPath` returns 0 hits in app codebase.
