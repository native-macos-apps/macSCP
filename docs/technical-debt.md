# Báo cáo Nợ Kỹ thuật & Code Smells — MacSCP

> **Ngày review:** 2026-11-25  
> **Quy mô mã nguồn:** ~26,507 dòng Swift (`macSCP/`, `macSCPTests/`, `macSCPUITests/`)

## Tổng quan

Codebase MacSCP có nền tảng cấu trúc rõ ràng (`Core`, `Data`, `Domain`, `Features`, `Services`), đã áp dụng Swift Concurrency (`actor`, `async/await`, `@Observable`), có `DependencyContainer`, và có bộ unit test tương đối tốt ở tầng ViewModel/Service.

Tuy nhiên, quá trình phát triển tích lũy một số khoản nợ kỹ thuật ở các nhóm sau:
1. **Bảo mật, Bug runtime & Data Races (P0)** — Cần ưu tiên xử lý ngay.
2. **Nợ kiến trúc & God Objects (P1)** — Ảnh hưởng trực tiếp đến khả năng mở rộng và bảo trì.
3. **Code Smells, Trùng lặp & Dead Code (P1–P2)** — Tăng chi phí sửa lỗi và dễ gây không nhất quán.
4. **Vệ sinh Repo & Khoảng trống Kiểm thử (P2)** — Ảnh hưởng độ tin cậy khi refactor.

---

## 1. Mức độ Nghiêm trọng Cao (P0 — Bảo mật, Bug & Data Races)

### 1.1. ~~Bảo mật & Rò rỉ Private Key trong `TerminalLauncher`~~ (Đã xử lý — 2026-11-26)
* **Giải pháp đã triển khai:** Xóa bỏ hoàn toàn `TerminalLauncher.swift`, quyền Apple Events (`com.apple.security.temporary-exception.apple-events`) và `NSAppleEventsUsageDescription`. Thay thế bằng cửa sổ **Integrated SSH Terminal** (`macSCP/Features/Terminal/`, `SSHTerminalSession`, `SSHConnection.connectShell`) dùng `SwiftTerm` + `swift-nio-ssh`: private key được parse trực tiếp trong RAM (zero-disk), host key được xác thực qua `KnownHostsManager`, và `initialPath` được escape chuẩn POSIX single-quote (xem `SPEC-08` và `docs/plans/2026112601-integrated-swiftterm-terminal.md`).

### 1.2. ~~Race Condition & Rò rỉ Session ở `CommanderViewModel`~~ (Đã xử lý — 2026-11-26)
* **Giải pháp đã triển khai:** Capture `previousRemoteVM` qua `detachRemoteViewModel(from:)` trước khi cập nhật `targetPane.contentType` / `targetPane.browserViewModel` trong `switchToLocal`, `switchToServers`, `disconnect`, và `completeConnect` (`CommanderViewModel.swift`). Đã bổ sung unit tests xác nhận session cũ được disconnect đúng và session mới không bị ngắt nhầm.

### 1.3. ~~Lạm dụng `@unchecked Sendable` & Data Races (29 vị trí)~~ (Đã xử lý các điểm nóng P0 — 2026-11-26)
* **Giải pháp đã triển khai:**
  * Thay `CancellationBox` và `ProgressState` (`@unchecked Sendable`) trong `BatchTransferCoordinator.swift` bằng `OSAllocatedUnfairLock` (`CancellationState` theo dõi cả `isCancelled` lẫn `cancelAction`) và biến local `itemIndex`.
  * Chuyển toàn bộ 4 `FileStreamReader` (`SFTPStreamReader`, `S3StreamReader`, `LocalFileStreamReader`, `MemoryStreamReader`) sang `actor`, loại bỏ hoàn toàn `@unchecked Sendable` và data race khi `readNextChunk()` / `close()` chạy đồng thời.

### 1.4. ~~Mất dữ liệu âm thầm khi đọc file non-UTF-8~~ (Đã xử lý — 2026-11-26)
* **Giải pháp đã triển khai:** Bổ sung `AppError.invalidFileEncoding` (`AppError.swift`) và kiểm tra strict UTF-8 trong `SFTPSession.readFileContent`, `S3Session.readFileContent` và `LocalFileRepository.readFileContent`; throw `AppError.invalidFileEncoding` thay vì trả về `""` hay decode lossy `U+FFFD`, ngăn ghi đè mất dữ liệu gốc.

### 1.5. ~~Bug Inactivity Lock ở `AppLockManager`~~ (Đã xử lý — 2026-11-26)
* **Giải pháp đã triển khai:** Đăng ký `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel])` với cơ chế throttle (`5s`) qua `handleUserInteraction(now:)`, dọn dẹp observers/monitor trong `deinit`, và mở `internal init(biometricService:userDefaults:activityThrottleInterval:installObservers:)` để unit test độc lập.

### 1.6. ~~Rủi ro Crash từ `fatalError()` & Force Unwrap~~ (Đã xử lý — 2026-11-26)
* **Giải pháp đã triển khai:**
  * `DataStore.swift`: Bổ sung fallback in-memory `ModelContainer`, lưu `isUsingInMemoryFallback` / `initializationError`, hiển thị cảnh báo cho người dùng tại `CommanderWorkspaceView`, và cập nhật `DataStore.preview` dùng `inMemoryOnly: true`.
  * `NativeServersTableView.swift`: Thay `fatalError()` trong `outlineView(_:child:ofItem:)` bằng kiểm tra kiểu + biên mảng an toàn, ghi log lỗi và trả về `NSNull()`.
  * `S3Session.swift`: Thay force unwrap `s3!` bằng biến local `let client = S3Client(config: configuration)`.

---

## 2. Nợ Kỹ thuật Kiến trúc (P1 — Architecture Debt)

### 2.1. God Objects & Các hàm quá dài (Đã xử lý các điểm nóng chính — 2026-11-26)

| File | Trạng thái | Ghi chú |
| --- | :--- | --- |
| `macSCP/Features/Browser/FileBrowserViewModel.swift` | Đã tách (~610 dòng) | Đã tách `BrowserSessionProtocol`, `BrowserQuickLookController`, `FileTransferManager` |
| `macSCP/Data/S3/S3Session.swift` | Đã tách (~410 dòng) | Đã tách `S3PathResolver`, `S3ErrorMapper`, `S3Session+Transfers` (`writeStream` đã tách nhỏ) |
| `macSCP/Features/Commander/CommanderViewModel.swift` | Đã giảm (~550 dòng) | Đã dùng chung `FileTransferManager` thay vì lặp logic batch transfer |
| `macSCP/Features/Browser/Components/NativeFileTableView.swift` | Đã tách (~462 dòng) | Đã tách `NativeFileTableView+DragDrop.swift` (197 dòng) & `NativeFileTableView+ContextMenu.swift` (204 dòng) |
| `macSCP/Features/Commander/Components/NativeServersTableView.swift` | Đã tách (~327 dòng) | Đã tách `NativeServersTableView+ContextMenu.swift` (192 dòng) & `ServerTableCellViews.swift` (214 dòng) |

**Các hàm dài đã tách nhỏ (2026-11-26):**
* ~~`BatchTransferCoordinator.executeBatch` & `transferSingleItemWithRetry`~~ — đã tách `runWorkerPool`, `markRemainingItemsCancelled`, `executeTransferWithRetries`, `emitFailureOrCancel` (`BatchTransferCoordinator.swift`).
* ~~`FileTypeService.typeDescription`~~ — đã chuyển sang bảng tra cứu `extensionDescriptions` / `fileTypeDescriptions` (`FileTypeService.swift`).
* ~~`SFTPTransferEngine.uploadSingleFile` & `downloadSingleFile`~~ — đã tách `prepareLocalDestinationFile`, `downloadSmallFile`, `downloadWithSlidingWindow`, `uploadSmallFile`, `uploadWithSlidingWindow` (`SFTPTransferEngine.swift`).

### 2.2. ~~Leaky Abstraction theo loại kết nối~~ (Đã xử lý — 2026-11-26)
* **Giải pháp đã triển khai:** Giới thiệu `BrowserSessionProtocol` (`macSCP/Features/Browser/BrowserSession.swift`) với 3 triển khai `LocalBrowserSession`, `SFTPBrowserSession`, và `S3BrowserSession`. `FileBrowserViewModel` không còn giữ trực tiếp `sftpSession`/`s3Session` hay phân nhánh theo giao thức.

### 2.3. ~~Lạm dụng Singleton phá vỡ Dependency Injection~~ (Đã xử lý — 2026-11-26)
* **Giải pháp đã triển khai:** Bổ sung `transferSettings`, `batchTransferCoordinator`, `knownHostsManager`, `biometricAuthService` vào `DependencyContainer`; inject qua `init` tại `FileBrowserViewModel`, `CommanderViewModel`, và `SettingsView`; mở `internal init(userDefaults:)` cho `KnownHostsManager` và `SSHKeyStorageService` (cùng với `AppLockManager` đã mở ở P0).

### 2.4. ~~Rò rỉ Bộ nhớ & File tạm trong Quick Look~~ (Đã xử lý — 2026-11-26)
* **Giải pháp đã triển khai:** Tách `BrowserQuickLookController` (`macSCP/Features/Browser/BrowserQuickLookController.swift`) sử dụng `NSCache` giới hạn bộ nhớ (50 entries / 50 MB), gọi `reset()` xóa cache khi `disconnect()`, không cache kết quả `.error(...)`, và dùng `defer` xóa file tạm ảnh/PDF trong mọi trường hợp lỗi/hủy.

---

## 3. Code Smells, Trùng lặp & Dead Code (P1–P2)

### 3.1. ~~Trùng lặp mã nguồn (DRY Violations)~~ (Đã xử lý — 2026-11-26)
* **Batch Transfer State & Snapshot:** Đã gom vào `FileTransferManager` dùng chung cho cả `FileBrowserViewModel` và `CommanderViewModel`, bảo vệ `lastAppliedSnapshotSequence` đồng nhất.
* **Keychain CRUD:** Đã gom vào `KeychainStore` (`macSCP/Data/Keychain/KeychainStore.swift`) dùng chung cho `KeychainService` và `SSHKeyStorageService` (kiểm tra đầy đủ `OSStatus` cho `SecItemDelete`).
* **Single Download:** Đã gom `startDownload` và `downloadToURL` trong `FileTransferManager`.
* **SFTP Connect:** Đã gom logic khởi tạo/cleanup chung vào `SFTPSession.establishConnection`.

### 3.2. ~~Dead Code & API gây hiểu nhầm~~ (Đã xử lý phần lớn — 2026-11-26)
* Đã xóa `FileBrowserViewModel.navigateWithoutHistory(to:)`, `DataStore.createWithRecovery()`, `AcceptAllServerAuthDelegate`.
* `DataStore.preview` đã dùng `inMemoryOnly: true` (từ P0).
* `SSHKeyParser.KeyError.unsupportedKeyType` đã đồng bộ thông báo chỉ hỗ trợ `Ed25519 (unencrypted OpenSSH format)`.
* **Còn tồn đọng (P2):** `AnalyticsService.swift` (321 dòng) chỉ ghi debug log cục bộ nhưng vẫn duy trì nhiều khóa `UserDefaults` và `NSLock` — giữ nguyên để không ảnh hưởng thống kê local hiện có, có thể đơn giản hóa sau.

### 3.3. ~~Thiếu nhất quán & Xử lý lỗi mong manh~~ (Đã xử lý — 2026-11-26)
* **Giới hạn `recentTransfers`:** Chuẩn hóa đồng nhất `FileTransferManager.maxRecentTransfers = 30`.
* **`transferType` trong `BatchTransferCoordinator`:** Truyền tham số `transferType` (`.download` khi Commander truyền Remote → Local, `.upload` cho các trường hợp khác).
* **Cancellation & S3 error mapping:** Bỏ kiểm tra `String(describing: error).contains("CancellationError")`; tách `S3ErrorMapper` ưu tiên ánh xạ typed AWS/URLError trước khi fallback chuỗi.
* **Không bỏ qua batch âm thầm & Log category chuẩn:** Hiển thị `AppError` rõ ràng khi có batch đang chạy; dùng `session.logCategory` (`.local`/`.s3`/`.sftp`) cho toàn bộ thao tác CRUD. (Lỗi mở Terminal đã được xử lý khi chuyển sang Integrated SSH Terminal ở P0).
* **Bỏ overhead logging ở `S3Session`:** Gọi trực tiếp `logInfo(..., category: .s3)` thay vì bọc `Task { @MainActor ... }`.

---

## 4. Vệ sinh Repo & Khoảng trống Kiểm thử (P2)

* ~~**File cá nhân của Xcode bị track trong Git:**~~ (Đã xử lý — 2026-11-26: đã `git rm --cached` `xcschememanagement.plist`; `.gitignore` đã chứa `xcuserdata/`).
* **Độ phủ Unit Tests:** Đã bổ sung unit tests cho `SSHKeyParser`, `KnownHostsManager`, `TransferRetryPolicy`, `StreamingFileScanner`, `RemoteDirectoryManager`, `S3PathResolver`, `S3ErrorMapper`, `BrowserQuickLookController`, `FileTransferManager`, `AppLockManager`, `FileTypeService`, `ConnectionRepository`, `FolderRepository`, `LocalFileRepository`, `SFTPMessages`, `SFTPFileAttributes`, `SFTPClient`, `SFTPTransferEngine`, và `SFTPSession` (tổng **176/176** unit tests pass).
  * *Ghi chú tùy chọn (Low Priority):* `S3Session` tích hợp trực tiếp với AWS SDK client mock và đơn giản hóa `AnalyticsService.swift` có thể thực hiện khi có thay đổi liên quan.

---

## 5. Lộ trình Xử lý Đề xuất

### P0 — Sửa ngay (Bảo mật, Bug runtime & Data Races)
- [x] ~~Fix shell/AppleScript escaping và tạo/dọn dẹp an toàn file private key tạm trong `TerminalLauncher.swift`.~~ (Thay thế hoàn toàn bằng Integrated SSH Terminal với `SwiftTerm` + `swift-nio-ssh`)
- [x] ~~Fix race condition & rò rỉ session trong `CommanderViewModel` (`switchToLocal`, `switchToServers`, `completeConnect`).~~ (2026-11-26)
- [x] ~~Đồng bộ hóa an toàn (`actor` hoặc lock) cho `CancellationBox`, `SFTPStreamReader`, `S3StreamReader`, `LocalFileStreamReader`.~~ (2026-11-26 — thêm cả `MemoryStreamReader`)
- [x] ~~Throw lỗi encoding thay vì trả về `""` trong `SFTPSession.readFileContent`.~~ (2026-11-26 — áp dụng `AppError.invalidFileEncoding` đồng nhất cho SFTP, S3 và Local)
- [x] ~~Gắn sự kiện tương tác người dùng cho `AppLockManager.recordActivity()`.~~ (2026-11-26 — `NSEvent.addLocalMonitorForEvents` có throttle 5s)
- [x] ~~Loại bỏ `fatalError()` ở `DataStore.swift` / `NativeServersTableView.swift` và force unwrap `s3!` ở `S3Session.swift`.~~ (2026-11-26)

### P1 — Giảm nợ Kiến trúc & Dọn dẹp
- [x] ~~Tách `FileBrowserViewModel` thành `FileTransferManager` (dùng chung với `CommanderViewModel`), `BrowserQuickLookController` (dùng `NSCache` + `defer` xóa file tạm + không cache lỗi), và `BrowserSessionProtocol`.~~ (2026-11-26)
- [x] ~~Gom Keychain CRUD boilerplate vào `KeychainStore` dùng chung cho `KeychainService` và `SSHKeyStorageService`.~~ (2026-11-26)
- [x] ~~Tách `S3Session.swift` thành `S3PathResolver`, `S3ErrorMapper`, và `S3Session+Transfers` (+ bỏ logging overhead `Task { @MainActor }`).~~ (2026-11-26)
- [x] ~~Xóa dead code (`navigateWithoutHistory`, `createWithRecovery`, `AcceptAllServerAuthDelegate`), sửa `DataStore.preview` sang in-memory, và đồng bộ thông báo lỗi ở `SSHKeyParser`.~~ (2026-11-26)
- [x] ~~Chuẩn hóa `recentTransfers` limit (`30`), `transferType` trong `BatchTransferCoordinator`, log category (`.local`/`.s3`/`.sftp`), và thông báo lỗi khi đang có batch chạy.~~ (2026-11-26)

### P2 — Vệ sinh Repo & Tăng độ phủ Test
- [x] ~~Xóa `xcuserdata` khỏi Git index (`.gitignore` đã có `xcuserdata/`).~~ (2026-11-26)
- [x] ~~Inject các dependency qua `DependencyContainer` (`FileBrowserViewModel`, `CommanderViewModel`, `SettingsView`); mở `internal init` cho `AppLockManager`, `KnownHostsManager`, `SSHKeyStorageService`.~~ (2026-11-26)
- [x] ~~Bổ sung unit test cho `SSHKeyParser`, `KnownHostsManager`, `TransferRetryPolicy`, `StreamingFileScanner`, `RemoteDirectoryManager`, `S3PathResolver`, `S3ErrorMapper`, `BrowserQuickLookController`, `FileTransferManager`, và `AppLockManager`.~~ (2026-11-26 — 155/155 tests passed)
- [x] ~~(Deferred P2) Tách nhỏ `NativeFileTableView.swift`, `NativeServersTableView.swift`, `FileTypeService.typeDescription`, các hàm dài trong `SFTPTransferEngine` / `BatchTransferCoordinator`, và bổ sung unit test sâu cho tầng SFTP/Local/SwiftData (`SFTPSession`, `SFTPClient`, `SFTPTransferEngine`, `SFTPMessages`, `ConnectionRepository`, `FolderRepository`, `LocalFileRepository`, `FileTypeService`).~~ (2026-11-26 — 176/176 tests passed; xem `docs/plans/2026112604-deferred-p2-remediation.md`)
