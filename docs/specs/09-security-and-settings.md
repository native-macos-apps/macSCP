---
id: SPEC-09
title: Bảo mật Ứng dụng (App Lock), Cài đặt & Tự động Cập nhật
status: active
last_updated: 2026-11-26
related_files:
  - MacSCP/Services/AppLockManager.swift
  - MacSCP/Services/BiometricAuthService.swift
  - MacSCP/Features/AppLock/AppLockView.swift
  - MacSCP/Features/AppLock/AppLockOverlayModifier.swift
  - MacSCP/Features/Settings/SettingsView.swift
  - MacSCP/Features/Settings/Components/ImportKeySheet.swift
  - MacSCP/Features/Settings/CheckForUpdatesView.swift
  - MacSCP/Features/Settings/CheckForUpdatesViewModel.swift
  - MacSCP/Services/TransferSettings.swift
  - MacSCP/Data/SFTP/Engine/KnownHostsManager.swift
related_debt:
  - docs/technical-debt.md#15-bug-inactivity-lock-ở-applockmanager
  - docs/technical-debt.md#23-lạm-dụng-singleton-phá-vỡ-dependency-injection
---

# SPEC-09: Bảo mật Ứng dụng (App Lock), Cài đặt & Tự động Cập nhật

## 1. Tổng quan & Mục tiêu
Bảo vệ toàn bộ cửa sổ và kết nối trong MacSCP bằng **Touch ID / xác thực thiết bị macOS**, cung cấp trung tâm cấu hình thống nhất (`SettingsView`, phím tắt `Cmd+,`) và cơ chế tự động cập nhật phần mềm qua **Sparkle**.

---

## 2. User Flows & Hành vi chính

### Flow 1: App Lock & Xác thực Sinh trắc học (`AppLockManager`)
- Toàn bộ 5 Scene trong `MacSCPApp` đều được phủ modifier `.appLockOverlay()` (`AppLockOverlayModifier`). Khi `isLocked == true`, che nội dung cửa sổ bằng `AppLockView`.
- **Bật khóa (`enableBiometricLock`):** Không yêu cầu xác thực trước, lưu vào `UserDefaults` (`com.macSCP.biometricLockEnabled`).
- **Tắt khóa (`disableBiometricLock`):** **Bắt buộc** xác thực sinh trắc học thành công trước khi tắt.
- **Các chế độ kích hoạt khóa:**
  1. **Khi khởi động app (`lockIfNeeded`):** Tự động khóa nếu `isBiometricLockEnabled == true`.
  2. **Khi ứng dụng nền/quay lại (`lockOnAppResume`):** Lắng nghe `NSApplication.didResignActiveNotification` để khóa khi app rời foreground.
  3. **Trước khi kết nối server (`lockBeforeConnection`):** Gọi `authenticateForConnection()` trước mỗi lần mở kết nối mới.
  4. **Sau thời gian không hoạt động (`lockAfterInactivity`):** Hẹn giờ tự động khóa với các mốc `InactivityTimeout`: `1m` (60s), `5m` (300s — mặc định), `15m` (900s), `30m` (1800s), `1h` (3600s).

### Flow 2: Cài đặt Ứng dụng (`SettingsView` — `Cmd+,`, 560×420)
Gồm 4 tab (`SettingsTab`):
1. **Transfers:** Chọn số luồng truyền tải đồng thời (`TransferSettings.maxConcurrentTransfers`, từ `1` đến `8` streams, mặc định `3`).
2. **SSH Keys:** Danh sách khóa trong Keychain (tên, loại khóa, `shortFingerprint`), nút **Import Key…** (`ImportKeySheet`), copy Public Key, và xóa khóa (có `confirmationDialog`).
3. **Known Hosts:** Danh sách các host đã tin cậy (`host:port` + SHA256 fingerprint) từ `KnownHostsManager`, cho phép xóa từng host khi server đổi khóa.
4. **Security:** Cấu hình bật/tắt Touch ID Lock và các tùy chọn `lockOnAppResume`, `lockBeforeConnection`, `lockAfterInactivity`, `inactivityTimeout` (kiểm tra khả dụng phần cứng qua `BiometricAuthService.isBiometricAvailable()`).

### Flow 3: Tự động Cập nhật (Sparkle)
- `MacSCPApp` khởi tạo `SPUStandardUpdaterController(startingUpdater: true, ...)`.
- Thêm menu item **Check for Updates…** (`CheckForUpdatesView` + `CheckForUpdatesViewModel`) ngay sau `.appInfo` trong thanh menu ứng dụng, đối chiếu phiên bản từ `appcast.xml`.

---

## 3. Data Models & Contracts
- **`InactivityTimeout`**: Enum `Int` (`60`, `300`, `900`, `1800`, `3600`).
- **`BiometricAuthServiceProtocol`**: Trừu tượng hóa `LAContext` để kiểm tra khả dụng sinh trắc học và thực hiện `authenticate(reason:)`.
- **`UserDefaults` Keys:**
  - `com.macSCP.biometricLockEnabled`
  - `com.macSCP.lockOnAppResume`
  - `com.macSCP.lockBeforeConnection`
  - `com.macSCP.lockAfterInactivity`
  - `com.macSCP.inactivityTimeout`
  - `app.settings.maxConcurrentTransfers`
  - `com.macSCP.knownHosts`

---

## 4. Kiến trúc & Entry Points
- **App Lock:** `AppLockManager`, `BiometricAuthService`, `AppLockView`, `AppLockOverlayModifier`.
- **Settings:** `SettingsView`, `ImportKeySheet`, `TransferSettings`.
- **Updates:** `CheckForUpdatesView`, `CheckForUpdatesViewModel`, `SPUStandardUpdaterController`.

---

## 5. Edge Cases & Xử lý lỗi
| Tình huống | Hành vi mong đợi |
| :--- | :--- |
| Người dùng bấm Cancel trên hộp thoại Touch ID | Ghi log, giữ nguyên trạng thái khóa, không hiển thị chuỗi lỗi đỏ khó chịu (`authenticationError = nil`). |
| Gọi `performAuthentication` khi đang có phiên xác thực chạy | Guard `!isAuthenticating` để tránh hiện chồng nhiều popup hệ thống. |
| Máy Mac không có Touch ID | `BiometricAuthService` kiểm tra khả dụng và fallback theo chính sách thiết bị / ẩn tùy chọn không hỗ trợ. |

---

## 6. Security, Concurrency & Invariants
- **Disable Guard Invariant:** Không bao giờ tắt `isBiometricLockEnabled` mà chưa xác thực thành công.
- **Multi-Window Coverage Invariant:** Mọi Scene mới thêm vào `MacSCPApp` **bắt buộc** phải gắn `.appLockOverlay()` để không bị lộ dữ liệu khi app đang khóa.

---

## 7. Acceptance Criteria
- [ ] Bật App Lock khóa toàn bộ cửa sổ khi mở lại app; tắt App Lock yêu cầu xác thực thành công.
- [ ] Cả 4 tab trong Settings lưu và áp dụng thay đổi ngay lập tức.
- [ ] Menu "Check for Updates…" hoạt động với Sparkle updater.

---

## 8. Known Gaps & Technical Debt
- **P0 — Bug Inactivity Lock:** `recordActivity()` hiện chỉ được gọi từ `NSApplication.didBecomeActiveNotification`, chưa theo dõi tương tác chuột/bàn phím trong ứng dụng nên người dùng làm việc liên tục vẫn bị khóa khi hết timeout (`docs/technical-debt.md#1.5`).
- **P2 — Khó unit test:** `AppLockManager.init(biometricService:)` đang là `private`, cần mở thành `internal` để test với mock (`docs/technical-debt.md#2.3`).
