---
id: SPEC-08
title: Native macOS Terminal Integration
status: active
last_updated: 2026-11-26
related_files:
  - MacSCP/Core/Utilities/TerminalLauncher.swift
  - MacSCP/Features/Commander/CommanderViewModel.swift
  - MacSCP/Features/Connections/ConnectionListViewModel.swift
related_debt:
  - docs/technical-debt.md#11-bảo-mật--rò-rỉ-private-key-trong-terminallauncher
  - docs/technical-debt.md#33-thiếu-nhất-quán--xử-lý-lỗi-mong-manh
---

# SPEC-08: Native macOS Terminal Integration

## 1. Tổng quan & Mục tiêu
Cho phép người dùng mở phiên SSH trực tiếp trong ứng dụng **Terminal** mặc định của macOS (`com.apple.Terminal`) chỉ bằng một cú nhấp chuột từ danh sách kết nối hoặc từ thư mục đang duyệt trong File Browser/Commander, tự động truyền `host`, `port`, `username`, SSH key (nếu có) và thư mục làm việc hiện tại (`initialPath`).

---

## 2. User Flows & Hành vi chính

### Flow 1: Khởi chạy Terminal SSH (`TerminalLauncher.launchTerminal`)
1. Người dùng nhấn nút mở Terminal trên một kết nối SFTP (có thể kèm `initialPath` là thư mục đang mở).
2. `TerminalLauncher` dựng câu lệnh `ssh`:
   - `ssh -p <port>`
   - Nếu có `sshKeyId`: lấy nội dung key từ `SSHKeyStorageService`, ghi ra file tạm quyền `0600` và thêm `-i <tempKeyPath>`.
   - Thêm `<username>@<host>`.
   - Nếu có `initialPath` (khác `/`, `~`, rỗng): thêm `-t "cd \"<initialPath>\" ; exec $SHELL -l"`.
3. Kiểm tra `Terminal.app` đã chạy chưa (`ensureTerminalIsRunning`, timeout `5s`); nếu chưa, khởi chạy qua `NSWorkspace.shared.openApplication`.
4. Kích hoạt cửa sổ Terminal và chạy lệnh thông qua `NSAppleScript` (`do script "..."`).
5. Nếu lần chạy đầu gặp lỗi `"application isn't running"`, chờ `250ms` và retry 1 lần.

---

## 3. Data Models & Contracts
- **`TerminalLauncherError`**:
  - `.appleScriptInitializationFailed`
  - `.executionFailed(String)`
  - `.automationNotAuthorized` — thông báo hướng dẫn mở *System Settings > Privacy & Security > Automation*.

---

## 4. Kiến trúc & Entry Points
- **Utility:** `TerminalLauncher` (`MacSCP/Core/Utilities/TerminalLauncher.swift`).
- **Callers:** `CommanderViewModel.openTerminal`, `ConnectionListViewModel`, `FileBrowserViewModel`.

---

## 5. Edge Cases & Xử lý lỗi
| Tình huống | Hành vi mong đợi |
| :--- | :--- |
| Chưa cấp quyền Automation cho Terminal | Trả về `.automationNotAuthorized` và hiển thị thông báo hướng dẫn người dùng cấp quyền. |
| Terminal chưa khởi động sẵn | Mở Terminal qua `NSWorkspace`, chờ tối đa 5 giây cho tới khi tiến trình sẵn sàng. |
| Kết nối là S3 hoặc Local | Không áp dụng SSH Terminal launch. |

---

## 6. Security, Concurrency & Invariants
- **Strict Shell & AppleScript Escaping (Target Invariant):** Mọi tham số đầu vào (`host`, `username`, `initialPath`, `keyPath`) phải được escape an toàn theo chuẩn POSIX single-quote trước khi escape sang AppleScript để triệt tiêu Command Injection.
- **Ephemeral Private Key Hygiene (Target Invariant):** File private key tạm phải được tạo với quyền `0600` nguyên tử ngay lúc tạo và được dọn dẹp an toàn sau khi SSH handshake hoàn tất.

---

## 7. Acceptance Criteria
- [ ] Mở Terminal thành công cho kết nối SFTP dùng cả Password và In-App SSH Key.
- [ ] Khi mở từ File Browser, shell tự động `cd` vào đúng `initialPath`.
- [ ] Lỗi quyền Automation được hiển thị rõ ràng tới người dùng ở mọi entry point (kể cả Commander).

---

## 8. Known Gaps & Technical Debt
- **P0 — Rò rỉ file private key tạm & Command Injection:** File `macscp_ssh_<uuid>.pem` hiện không bao giờ bị xóa, có race condition quyền tạo file, và `username`/`host`/`initialPath` chưa được escape POSIX đầy đủ (`docs/technical-debt.md#1.1`).
- **P1 — Nuốt lỗi ở Commander:** `CommanderViewModel.openTerminal` (L633) đang bỏ qua `Result` trả về của `TerminalLauncher.launchTerminal` (`docs/technical-debt.md#3.3`).
