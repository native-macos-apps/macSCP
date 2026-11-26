# Kế hoạch Triển khai: Terminal SSH Tích hợp với SwiftTerm (Xử lý Nợ Kỹ thuật 1.1)

> **Ngày:** 2026-11-26  
> **Tham chiếu Spec:** `SPEC-08` (`docs/specs/08-terminal-integration.md`), `SPEC-07` (`docs/specs/07-file-editor.md`), `SPEC-00` (`docs/specs/00-architecture.md`)  
> **Tham chiếu Tech Debt:** `docs/technical-debt.md#1.1`, `docs/technical-debt.md#3.3`

## 1. Mục tiêu
Thay thế hoàn toàn `TerminalLauncher.swift` (dùng `NSAppleScript` + `Terminal.app` + ghi plaintext private key tạm ra ổ đĩa) bằng cửa sổ **Integrated SSH Terminal** (`WindowID.terminal`) tương tự kiến trúc `FileEditorWindow`:
- **UI Emulator:** `SwiftTerm` (`https://github.com/migueldeicaza/SwiftTerm.git`) qua `NSViewRepresentable`.
- **Transport & Auth:** Native `swift-nio-ssh` (`SSHConnection.connectShell`, `SSHShellChannelHandler`, `SSHTerminalSession`), đọc & parse private key trực tiếp trong RAM từ Keychain (`SSHKeyStorageService` + `SSHKeyParser`), xác thực host key qua `KnownHostsManager`.
- **Sandbox Hygiene:** Gỡ bỏ `com.apple.security.temporary-exception.apple-events` trong `macSCP.entitlements` và `NSAppleEventsUsageDescription` trong `Info.plist`.

## 2. Các thành phần chính
1. **SPM & Sandbox:** Thêm `SwiftTerm` vào `macSCP.xcodeproj/project.pbxproj`; xóa quyền Apple Events khỏi `macSCP.entitlements` & `Info.plist`.
2. **SSH Shell Engine:**
   - `macSCP/Data/SFTP/Engine/SSHShellChannelHandler.swift` (`SSHShellChannel` + `SSHShellChannelHandler`).
   - `macSCP/Data/SFTP/Engine/SSHConnection.swift` (tách `connectTransport`, thêm `connectShell`).
   - `macSCP/Domain/RepositoryProtocols/SSHTerminalSessionProtocol.swift`.
   - `macSCP/Data/SFTP/SSHTerminalSession.swift` (kèm `makeInitialDirectoryCommand(for:)` chuẩn POSIX single-quote).
3. **Multi-Window & DI:** `Constants.swift` (`WindowID.terminal`, `WindowSize.terminal`), `WindowManager.swift` (`TerminalWindowData`), `DependencyContainer.swift`, `MacSCPApp.swift`.
4. **Terminal Feature (`macSCP/Features/Terminal/`):** `TerminalWindow.swift`, `TerminalViewModel.swift`, `TerminalScreenView.swift`, `Components/SwiftTermRepresentable.swift`, `Components/TerminalStatusBar.swift`.
5. **Callers & Cleanup:** Xóa `TerminalLauncher.swift`; cập nhật `CommanderViewModel`, `CommanderWorkspaceView`, `ConnectionListViewModel`, `ConnectionListView`.
6. **Tests & Docs:** Thêm `macSCPTests/Features/TerminalViewModelTests.swift`; đồng bộ `SPEC-08`, `SPEC-00`, `docs/specs/README.md`, `docs/technical-debt.md`.
