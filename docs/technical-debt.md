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

### 2.1. God Objects & Các hàm quá dài

| File | Số dòng | Vấn đề chính |
| --- | ---: | --- |
| `macSCP/Features/Browser/FileBrowserViewModel.swift` | 1,355 | Ôm trọn kết nối SFTP/S3/Local, navigation, CRUD, clipboard, S3 URL, download, batch upload, Quick Look + cache, window routing, sheet states |
| `macSCP/Data/S3/S3Session.swift` | 1,249 | Gom AWS SDK config, path/key normalization, URL builder, CRUD, multipart upload, stream reader, string-based error parsing |
| `macSCP/Features/Browser/Components/NativeFileTableView.swift` | 830 | AppKit `NSOutlineView` + drag/drop + context menu + transfer trigger trong một file |
| `macSCP/Features/Commander/Components/NativeServersTableView.swift` | 744 | Outline view + context menu (89 dòng) + cell views trong một file |
| `macSCP/Features/Commander/CommanderViewModel.swift` | 653 | Lặp lại gần như toàn bộ cơ chế batch transfer của `FileBrowserViewModel` |

**Các hàm dài cần tách nhỏ (>100 dòng):**
* `BatchTransferCoordinator.executeBatch` — 133 dòng (`BatchTransferCoordinator.swift:30`)
* `FileTypeService.typeDescription` — 126 dòng (`FileTypeService.swift:68`)
* `S3Session.writeStream` — 124 dòng (`S3Session.swift:897`)
* `BatchTransferCoordinator.transferSingleItemWithRetry` — 123 dòng (`BatchTransferCoordinator.swift:164`)
* `CommanderViewModel.executeCommanderBatch` — 112 dòng (`CommanderViewModel.swift:463`)
* `SFTPTransferEngine.uploadSingleFile` & `downloadSingleFile` — 104 dòng mỗi hàm (`SFTPTransferEngine.swift:100,303`)

### 2.2. Leaky Abstraction theo loại kết nối
* **Vị trí:** `macSCP/Features/Browser/FileBrowserViewModel.swift` (L122–L124, L257–L481)
* **Vấn đề:** `FileBrowserViewModel` giữ trực tiếp `sftpSession`, `s3Session` và `fileRepository`, dẫn tới các khối `if isLocal ... else if connection.connectionType == .s3 ... else ...` lặp lại ở hầu hết các method.
* **Hướng xử lý:** Trừu tượng hóa vòng đời kết nối (`connect`, `disconnect`, `currentPath`) qua một protocol chung thay vì để ViewModel phân nhánh theo giao thức.

### 2.3. Lạm dụng Singleton phá vỡ Dependency Injection
* **Vị trí:** `FileBrowserViewModel.swift`, `CommanderViewModel.swift`, `SettingsView.swift`, `AppLockManager.swift`
* **Vấn đề:**
  * Gọi trực tiếp `SSHKeyStorageService.shared`, `TransferSettings.shared`, `BatchTransferCoordinator.shared`, `WindowManager.shared`, `AppLockManager.shared`, `KnownHostsManager.shared`, `BiometricAuthService.shared` thay vì nhận qua `init` từ `DependencyContainer`.
  * `AppLockManager.init(biometricService:)` (L102) bị đánh dấu `private`, khiến không thể unit test với mock biometric service.

### 2.4. Rò rỉ Bộ nhớ & File tạm trong Quick Look
* **Vị trí:** `macSCP/Features/Browser/FileBrowserViewModel.swift` (L100, L1275–L1337)
* **Vấn đề:**
  * `quickLookCache: [String: QuickLookContent]` lưu `Data` ảnh/PDF không giới hạn dung lượng, không có chính sách eviction (LRU/`NSCache`) và không bao giờ được dọn khi `disconnect()`.
  * Lỗi mạng tạm thời cũng bị ghi vào `quickLookCache` (L1332) nên không thể preview lại trong cùng phiên.
  * Tải ảnh/PDF về file tạm (L1289–L1312) không dùng `defer` để xóa file tạm nếu `Data(contentsOf:)` ném lỗi hoặc task bị hủy.

---

## 3. Code Smells, Trùng lặp & Dead Code (P1–P2)

### 3.1. Trùng lặp mã nguồn (DRY Violations)
* **Batch Transfer State & Snapshot:** Lặp lại giữa `FileBrowserViewModel.swift` (L835–L984) và `CommanderViewModel.swift` (L463–L599). Ngoài ra, `CommanderViewModel.applyBatchSnapshot` (L577–L599) không kiểm tra `lastAppliedSnapshotSequence` nên snapshot cũ có thể ghi đè snapshot mới.
* **Keychain CRUD lặp 3 lần:**
  * `KeychainService.swift` lặp toàn bộ CRUD giữa Password (L19–L116) và S3 Credentials (L120–L217).
  * `SSHKeyStorageService.swift` lặp lại boilerplate `SecItem*` lần thứ 3, và bỏ qua `OSStatus` khi gọi `SecItemDelete` (L126) dù hàm khai báo `throws`.
* **Single Download:** `downloadFile` (L667–L756) và `downloadFileToURL` (L1041–L1088) trong `FileBrowserViewModel.swift` lặp lại logic tạo `TransferProgress`, throttle và cập nhật `recentTransfers`.
* **SFTP Connect:** Hai overload password (L23–L54) và private key (L56–L90) trong `SFTPSession.swift` lặp logic normalize host, tạo `SSHConnection`, cleanup lỗi và `getRealPath`.

### 3.2. Dead Code & API gây hiểu nhầm
* `FileBrowserViewModel.navigateWithoutHistory(to:)` (L463–L481) — không có nơi nào gọi.
* `DataStore.createWithRecovery()` (L52–L54) — comment mô tả recreate store nhưng chỉ trả về `DataStore.shared.modelContainer` và không được sử dụng.
* `DataStore.preview` (L60–L64) — khởi tạo với `isStoredInMemoryOnly: false`, khiến Xcode Preview ghi vào DB thật trên đĩa.
* `AcceptAllServerAuthDelegate` (`macSCP/Data/SFTP/Engine/SSHKeyAuth.swift:72–78`) — không được dùng ở đâu nhưng vẫn tồn tại trong production code (rủi ro tắt xác thực MITM nếu vô tình dùng lại).
* `SSHKeyParser` (`SSHKeyAuth.swift:95, 130, 201–222`) — thông báo hỗ trợ `"Ed25519, P-256"` và nhận tham số `passphrase: String?`, nhưng thực tế chỉ parse `ssh-ed25519` không mã hóa và bỏ qua hoàn toàn `passphrase`.
* `AnalyticsService.swift` (321 dòng) — chỉ gọi `logDebug`, không gửi telemetry đi đâu nhưng vẫn duy trì nhiều khóa `UserDefaults` và `NSLock`.

### 3.3. Thiếu nhất quán & Xử lý lỗi mong manh
* **Giới hạn `recentTransfers` không đồng nhất:** cắt ở `10` trong `downloadFile`/`downloadFileToURL` (L713, L1073) nhưng cắt ở `30` trong `cancelTransfer`/`cancelAllTransfers`/`completeTransfer`/`failTransfer` (L1008, L1032, L1131, L1144).
* **Hardcode `transferType: .upload`** trong `BatchTransferCoordinator.swift` (L139, L200) kể cả khi Commander đang thực hiện download (Remote → Local).
* **Stringly-typed error handling:**
  * `String(describing: error).contains("CancellationError")` ở `FileBrowserViewModel.swift:726` và `BatchTransferCoordinator.swift:251`.
  * `parseS3Error` / `parseConnectionError` ở `S3Session.swift:1177–1207` dựa trên chuỗi `.lowercased()` thay vì kiểm tra typed SDK errors.
* **Nuốt lỗi / Bỏ qua thao tác âm thầm:**
  * `CommanderViewModel.openTerminal` (L633): `_ = await TerminalLauncher.launchTerminal(...)` nuốt luôn lỗi Automation/AppleScript.
  * `FileBrowserViewModel.uploadURLs` (L783) và `CommanderViewModel.performTransfer` (L404) âm thầm bỏ qua nếu đang có batch chạy mà không thông báo cho người dùng.
  * Log category hardcode `.sftp` trong các thao tác CRUD của `FileBrowserViewModel` (L494–L541) kể cả khi đang dùng S3 hoặc Local.
* **Overhead logging không cần thiết:** `S3Session.log(_:)` (L27–L31) tạo `Task { @MainActor in logInfo(...) }` cho mọi dòng log dù `Logger.shared` đã `nonisolated`.

---

## 4. Vệ sinh Repo & Khoảng trống Kiểm thử (P2)

* **File cá nhân của Xcode bị track trong Git:**
  * `macSCP.xcodeproj/xcuserdata/nevilmacwan.xcuserdatad/xcschemes/xcschememanagement.plist` đang được commit. Cần gỡ khỏi index (`git rm --cached`) và kiểm tra `.gitignore`.
* **Khoảng trống Unit Tests ở tầng cốt lõi:**
  * Hiện chưa có unit test riêng cho: `SFTPSession`, `SFTPClient`, `SFTPTransferEngine`, `SFTPMessages`, `S3Session`, `SSHKeyParser`, `KnownHostsManager`, `TerminalLauncher`, `AppLockManager`, `ConnectionRepository`, `FolderRepository`, `LocalFileRepository`, `StreamingFileScanner`, `RemoteDirectoryManager`, `TransferRetryPolicy`.

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
- [ ] Tách `FileBrowserViewModel` thành `TransferManager` (dùng chung với `CommanderViewModel`), `QuickLookController` (dùng `NSCache` + `defer` xóa file tạm + không cache lỗi), và `FileOperationsService`.
- [ ] Gom Keychain CRUD boilerplate vào một generic/internal helper dùng chung cho `KeychainService` và `SSHKeyStorageService`.
- [ ] Tách `S3Session.swift` thành các module nhỏ hơn (path/URL builder, transfer/multipart, error mapper).
- [ ] Xóa dead code (`navigateWithoutHistory`, `createWithRecovery`, `AcceptAllServerAuthDelegate`), sửa `DataStore.preview` sang in-memory, và đồng bộ thông báo lỗi/tham số ở `SSHKeyParser`.
- [ ] Chuẩn hóa `recentTransfers` limit, `transferType` trong `BatchTransferCoordinator`, log category, và hiển thị lỗi khi mở Terminal thất bại.

### P2 — Vệ sinh Repo & Tăng độ phủ Test
- [ ] Xóa `xcuserdata` khỏi Git index và cập nhật `.gitignore`.
- [ ] Inject các dependency thay vì gọi `.shared` trực tiếp; mở `internal init(biometricService:)` cho `AppLockManager`.
- [ ] Bổ sung unit test cho `SSHKeyParser`, `KnownHostsManager`, `TerminalLauncher` (command builder), `TransferRetryPolicy`, `StreamingFileScanner`, `RemoteDirectoryManager`, và `AppLockManager`.
