---
id: SPEC-08
title: Integrated SSH Terminal (SwiftTerm)
status: active
last_updated: 2026-11-26
related_files:
  - macSCP/Data/SFTP/Engine/SSHConnection.swift
  - macSCP/Data/SFTP/Engine/SSHShellChannelHandler.swift
  - macSCP/Data/SFTP/SSHTerminalSession.swift
  - macSCP/Domain/RepositoryProtocols/SSHTerminalSessionProtocol.swift
  - macSCP/Features/Terminal/TerminalWindow.swift
  - macSCP/Features/Terminal/TerminalViewModel.swift
  - macSCP/Features/Terminal/TerminalScreenView.swift
  - macSCP/Features/Terminal/Components/SwiftTermRepresentable.swift
  - macSCP/Features/Terminal/Components/TerminalStatusBar.swift
  - macSCP/Features/Commander/CommanderViewModel.swift
  - macSCP/Features/Connections/ConnectionListViewModel.swift
related_debt: []
---

# SPEC-08: Integrated SSH Terminal (SwiftTerm)

## 1. Tổng quan & Mục tiêu
Cho phép người dùng mở phiên SSH tương tác trực tiếp ngay bên trong **MacSCP** trong một cửa sổ riêng biệt (`TerminalWindow`, kiến trúc tương đồng `FileEditorWindow`), sử dụng **SwiftTerm** làm terminal emulator và **`swift-nio-ssh`** làm tầng vận chuyển SSHv2.

Thiết kế này loại bỏ hoàn toàn phụ thuộc `Terminal.app` / `NSAppleScript`, không bao giờ ghi SSH private key ra ổ đĩa, và kế thừa trực tiếp xác thực `KnownHostsManager`, Keychain và App Lock.

---

## 2. User Flows & Hành vi chính

### Flow 1: Mở cửa sổ Terminal từ Commander hoặc Connection List
1. Người dùng chọn mở Terminal trên một kết nối SFTP (có thể kèm `initialPath` là thư mục đang mở trong File Browser).
2. Xác thực sinh trắc học qua `AppLockManager.shared.authenticateForConnection()` nếu được bật.
3. Lấy thông tin xác thực:
   - Nếu có mật khẩu đã lưu trong Keychain → dùng trực tiếp.
   - Nếu `authMethod == .privateKey` → mở cửa sổ ngay (key sẽ được đọc từ `SSHKeyStorageService` trong RAM khi kết nối).
   - Nếu `authMethod == .password` và chưa lưu mật khẩu → hiển thị `PasswordPromptSheet`.
4. Lưu `TerminalWindowData` vào `WindowManager` và mở Scene `WindowID.terminal` (hỗ trợ mở nhiều cửa sổ độc lập).

### Flow 2: Phiên SSH tương tác (`SSHTerminalSession` + `SwiftTerm`)
1. `TerminalWindow` khởi tạo `TerminalViewModel` và gọi `connect()`.
2. `SSHTerminalSession` thiết lập kết nối TCP + `NIOSSHHandler` (`KnownHostsServerAuthDelegate`), yêu cầu cấp phát PTY (`xterm-256color`, `cols × rows`) và khởi chạy login shell (`ShellRequest`).
3. Nếu có `initialPath` hợp lệ, gửi lệnh `cd '<posix-escaped-path>' && clear\n` vào PTY.
4. Dữ liệu stdout/stderr từ remote được đẩy vào `SwiftTerm.TerminalView.feed(byteArray:)`; phím bấm/paste của người dùng đi qua `TerminalViewDelegate.send` tới `SSHShellChannel.write`.
5. Khi thay đổi kích thước cửa sổ, `sizeChanged` gửi `SSHChannelRequestEvent.WindowChangeRequest` để cập nhật kích thước PTY trên server.
6. Hỗ trợ phím tắt `⌘K` (Clear), `⌘+`/`⌘-`/`⌘0` (Zoom font `9...28pt`), và nút **Reconnect** khi ngắt kết nối hoặc lỗi.

### Flow 3: Đóng cửa sổ & Dọn dẹp Session
- Khi đóng `TerminalWindow`, `.onDisappear` xóa `TerminalWindowData` khỏi `WindowManager` và gọi `viewModel.disconnect()` để đóng SSH child channel cùng `MultiThreadedEventLoopGroup`.

---

## 3. Data Models & Contracts
- **`TerminalWindowData`** (`WindowManager.swift`): `connectionId`, `connectionName`, `host`, `port`, `username`, `password`, `authMethod`, `sshKeyId`, `initialPath`.
- **`SSHTerminalSessionProtocol`** (`macSCP/Domain/RepositoryProtocols/SSHTerminalSessionProtocol.swift`): giao diện bất đồng bộ cho `connect` (password & private key), `send`, `resize`, `disconnect`.
- **`TerminalConnectionState`**: `.connecting`, `.connected`, `.disconnected(exitCode: Int?)`, `.failed(AppError)`.

---

## 4. Kiến trúc & Entry Points
- **Window & Root View:** `TerminalWindow` (Scene `WindowID.terminal`), `TerminalScreenView`.
- **Components:** `SwiftTermRepresentable`, `TerminalStatusBar`.
- **ViewModel:** `TerminalViewModel`.
- **SSH Engine:** `SSHConnection.connectShell`, `SSHShellChannelHandler`, `SSHShellChannel`, `SSHTerminalSession`.
- **Callers:** `CommanderViewModel.openTerminal`, `ConnectionListViewModel.requestTerminal` / `openTerminal`.

---

## 5. Edge Cases & Xử lý lỗi
| Tình huống | Hành vi mong đợi |
| :--- | :--- |
| Kết nối là S3 hoặc Local | Không áp dụng SSH Terminal. |
| SSH Private Key bị xóa khỏi Keychain | Hiển thị banner lỗi rõ ràng trong cửa sổ Terminal, không crash. |
| Host key thay đổi (nghi ngờ MITM) | `KnownHostsServerAuthDelegate` từ chối kết nối và hiển thị chi tiết fingerprint mismatch. |
| `initialPath` chứa ký tự đặc biệt hoặc `\n`/`\r`/`\0` | Ký tự điều khiển bị từ chối (`nil`); đường dẫn hợp lệ được escape single-quote chuẩn POSIX. |
| Mất mạng / server đóng phiên | Chuyển trạng thái sang `.disconnected` hoặc `.failed`, giữ nguyên màn hình output cuối và hiển thị nút **Reconnect**. |

---

## 6. Security, Concurrency & Invariants
- **Zero-Disk Private Key:** SSH private key không bao giờ được ghi ra file tạm trên ổ đĩa; toàn bộ quá trình parse và ký diễn ra trong RAM.
- **No AppleScript / No External Process Injection:** Không sử dụng `NSAppleScript` hay quyền `com.apple.security.temporary-exception.apple-events`.
- **POSIX Single-Quote Escaping:** Mọi `initialPath` trước khi gửi vào PTY đều qua `SSHTerminalSession.makeInitialDirectoryCommand(for:)`.
- **App Lock Compliance:** Scene `WindowID.terminal` được bọc bởi `.appLockOverlay()`.

---

## 7. Acceptance Criteria
- [x] Mở Terminal tích hợp thành công cho kết nối SFTP dùng cả Password và In-App SSH Key (không tạo file `.pem` tạm).
- [x] Khi mở từ File Browser, shell tự động `cd` an toàn vào `initialPath`.
- [x] Thay đổi kích thước cửa sổ gửi `WindowChangeRequest` đồng bộ kích thước PTY.
- [x] Mở nhiều cửa sổ Terminal song song hoạt động độc lập và giải phóng tài nguyên khi đóng.
- [x] Unit tests bao phủ escaping chống injection và vòng đời `TerminalViewModel`.

---

## 8. Known Gaps & Technical Debt
- Hiện chưa có khoản nợ kỹ thuật mở nào (đã xử lý xong `docs/technical-debt.md#1.1` và lỗi nuốt kết quả trong `#3.3`).
