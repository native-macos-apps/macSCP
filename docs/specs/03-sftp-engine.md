---
id: SPEC-03
title: Native SFTP Engine & Bảo mật SSH
status: active
last_updated: 2026-11-26
related_files:
  - MacSCP/Data/SFTP/SFTPSession.swift
  - MacSCP/Data/SFTP/SFTPSessionProtocol.swift
  - MacSCP/Data/SFTP/Engine/SSHConnection.swift
  - MacSCP/Data/SFTP/Engine/SFTPClient.swift
  - MacSCP/Data/SFTP/Engine/SFTPChannelHandler.swift
  - MacSCP/Data/SFTP/Engine/SFTPTransferEngine.swift
  - MacSCP/Data/SFTP/Engine/SFTPMessages.swift
  - MacSCP/Data/SFTP/Engine/SSHKeyAuth.swift
  - MacSCP/Data/SFTP/Engine/KnownHostsManager.swift
  - MacSCP/Data/Keychain/SSHKeyStorageService.swift
  - MacSCP/Domain/Models/SSHKeyItem.swift
  - MacSCP/Domain/RepositoryProtocols/SSHKeyRepositoryProtocol.swift
  - MacSCP/Data/Repositories/FileRepository.swift
related_debt:
  - docs/technical-debt.md#13-lạm-dụng-unchecked-sendable--data-races-29-vị-trí
  - docs/technical-debt.md#14-mất-dữ-liệu-âm-thầm-khi-đọc-file-non-utf-8
  - docs/technical-debt.md#31-trùng-lặp-mã-nguồn-dry-violations
  - docs/technical-debt.md#32-dead-code--api-gây-hiểu-nhầm
---

# SPEC-03: Native SFTP Engine & Bảo mật SSH

## 1. Tổng quan & Mục tiêu
Cung cấp tầng kết nối SSHv2 & SFTP thuần Swift dựa trên **Apple `swift-nio-ssh`** và **SwiftNIO**, tương thích cả máy chủ OpenSSH cũ (6.x–8.x) lẫn mới (OpenSSH 9.8p1+ / 10.x), bảo vệ chống tấn công MITM qua **Known Hosts (TOFU)** và quản lý khóa riêng an toàn trong **macOS Keychain**.

---

## 2. User Flows & Hành vi chính

### Flow 1: Thiết lập phiên SFTP (RFC 4254 Handshake)
1. Chuẩn hóa `host` và mở kết nối TCP/SSHv2 qua `SSHConnection`.
2. Xác thực Host Key của server qua `KnownHostsManager.verify(host:port:hostKey:)`:
   - Lần đầu gặp host: ghi nhận SHA256 fingerprint (**Trust On First Use — TOFU**) → `.newHostAdded`.
   - Khớp fingerprint đã lưu → `.trusted`.
   - Sai lệch fingerprint → `.hostKeyMismatch` → từ chối kết nối, cảnh báo nguy cơ MITM.
3. Xác thực người dùng: Password hoặc Private Key (nạp nội dung key từ `SSHKeyStorageService` theo `sshKeyId`).
4. Mở child session channel và gửi `SubsystemRequest("sftp", wantReply: true)`.
5. **Đồng bộ bắt buộc (RFC 4254):** Chờ `ChannelSuccessEvent` từ `SFTPChannelHandler` trước khi gửi gói `SSH_FXP_INIT` (v3). Nếu nhận `ChannelFailureEvent`, fail-fast với thông báo kiểm tra `Subsystem sftp` trong `sshd_config`.
6. Gọi `getRealPath(at: ".")` để xác định thư mục khởi đầu (`currentPath`).

### Flow 2: Quản lý In-App SSH Key (`SSHKeyStorageService`)
1. Người dùng import private key bằng cách chọn file hoặc dán nội dung PEM (`ImportKeySheet`).
2. `SSHKeyParser.inspectKey(from:)` kiểm tra tính hợp lệ, trích xuất `keyType`, SHA256 `fingerprint` và `publicKeyString`.
3. Lưu nội dung private key được mã hóa vào macOS Keychain (`kSecClassGenericPassword`, service `com.macSCP.sshKeys`, `kSecAttrAccessibleWhenUnlocked`).
4. Lưu metadata (`SSHKeyItem`) vào `UserDefaults` (`com.macSCP.sshKeyItems`).
5. Người dùng có thể xem danh sách, copy public key hoặc xóa key trong `SettingsView > SSH Keys`.

### Flow 3: Thao tác File & Pipelined Transfer (`SFTPTransferEngine`)
- Hỗ trợ đầy đủ `SFTPSessionProtocol`: `listFiles`, `getFileInfo`, `createDirectory`, `createFile`, `deleteFile`, `deleteDirectory` (đệ quy), `rename`, `copyFile`, `copyDirectory`, `move`, `executeCommand` (`SSHExecHandler`), `readFileContent`, `writeFileContent`.
- Upload/Download pipelined qua `SFTPTransferEngine` với progress callback (`TransferProgressHandler`).
- Hỗ trợ streaming không ghi đĩa trung gian: `openStreamReader(at:)` (`SFTPStreamReader`) và `writeStream(from:to:totalSize:progress:)`.

---

## 3. Data Models & Contracts
- **`SSHKeyItem`**: `id: UUID`, `name: String`, `keyType: String`, `fingerprint: String`, `publicKeyString: String?`, `createdAt: Date`.
- **`SSHKeyRepositoryProtocol`**: `getAllKeys()`, `getKey(by:)`, `getPrivateKeyContent(for:)`, `saveKey(name:privateKeyContent:)`, `deleteKey(id:)`.
- **`HostKeyVerificationResult`**: `.trusted`, `.newHostAdded(fingerprint:)`, `.hostKeyMismatch(expectedFingerprint:actualFingerprint:)`.
- **`SFTPSessionProtocol`**: Hợp đồng bất đồng bộ cho toàn bộ phiên SFTP, được bọc bởi `FileRepository` để implement `FileRepositoryProtocol`.

---

## 4. Kiến trúc & Entry Points
- **Session & Repo:** `SFTPSession` (`actor`), `FileRepository`.
- **Engine:** `SSHConnection`, `SFTPClient`, `SFTPChannelHandler`, `SFTPTransferEngine`, `SFTPMessages`, `SFTPFileAttributes`, `SFTPByteBuffer+SSH`, `SSHExecHandler`, `SSHKeyAuth`.
- **Security:** `KnownHostsManager`, `SSHKeyStorageService`.

---

## 5. Edge Cases & Xử lý lỗi
| Tình huống | Hành vi mong đợi |
| :--- | :--- |
| Server đóng kết nối sớm (`ChannelError.eof` / `ioOnClosedChannel`) | Ánh xạ sang `AppError` thân thiện thay vì raw `NIOCore.ChannelError error 9`. |
| Server từ chối subsystem SFTP | Fail-fast với thông báo hướng dẫn bật `Subsystem sftp`. |
| Host key thay đổi (MITM / rebuild server) | Chặn kết nối; người dùng có thể xóa entry cũ trong `Settings > Known Hosts`. |
| Nội dung private key rỗng hoặc sai định dạng | `SSHKeyStorageService.saveKey` throw lỗi trước khi ghi Keychain. |

---

## 6. Security, Concurrency & Invariants
- **RFC 4254 Handshake Invariant:** Không bao giờ gửi `SSH_FXP_INIT` trước khi nhận `ChannelSuccessEvent` cho `SubsystemRequest("sftp")`.
- **Host Key Verification Invariant:** Luôn xác thực host key qua `KnownHostsManager`; không bao giờ bỏ qua xác thực host key trong production.
- **Keychain Protection:** Private key luôn lưu với `kSecAttrAccessibleWhenUnlocked`.

---

## 7. Acceptance Criteria
- [ ] Kết nối thành công với OpenSSH 7.x/8.x/9.8+/10.x bằng cả password và Ed25519 SSH key từ Keychain.
- [ ] Host key mismatch bị chặn và hiển thị lỗi rõ ràng; xóa trong Known Hosts cho phép kết nối lại.
- [ ] Upload/Download file lớn ổn định với báo cáo tiến độ chính xác.

---

## 8. Known Gaps & Technical Debt
- **P0 — `SFTPStreamReader` data race:** Đang khai báo `@unchecked Sendable` với state mutable không lock (`docs/technical-debt.md#1.3`).
- **P0 — Non-UTF-8 silent data loss:** `SFTPSession.readFileContent` (L373) trả về `""` khi decode UTF-8 thất bại thay vì throw lỗi (`docs/technical-debt.md#1.4`).
- **P1/P2 — Dead code & giới hạn parser:** `AcceptAllServerAuthDelegate` vẫn tồn tại trong `SSHKeyAuth.swift`; `SSHKeyParser` hiện chỉ parse `ssh-ed25519` không mã hóa và bỏ qua `passphrase` dù thông báo đề cập P-256 (`docs/technical-debt.md#3.2`).
- **P1 — Trùng lặp connect:** Hai overload `connect` trong `SFTPSession.swift` lặp logic khởi tạo/cleanup (`docs/technical-debt.md#3.1`).
