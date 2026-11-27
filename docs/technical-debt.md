# Báo cáo Nợ Kỹ thuật & Code Smells — MacSCP

> **Ngày review gần nhất:** 2026-11-27, tại commit `c453374`
>
> **Quy mô mã nguồn:** 30.223 dòng Swift được Git theo dõi

## Các khoản nợ mở ngày 2026-11-27

### P0 — Ghi stream lỗi làm mất nội dung file đích local

- [x] **Vị trí lúc review:** [LocalFileRepository.swift:290–312](../macSCP/Data/Repositories/LocalFileRepository.swift#L290-L312), [CommanderViewModel.swift:529–545](../macSCP/Features/Commander/CommanderViewModel.swift#L529-L545). `writeStream` xóa file đích rồi ghi thẳng vào đường dẫn cuối. Khi reader ném lỗi hoặc transfer bị hủy giữa chừng, file cũ đã mất và dữ liệu dở dang có thể xuất hiện ở đích. Thử nghiệm với mã repository và reader giả lập xác nhận sau lỗi, file `original` chỉ còn `partial`. Các đường copy local trực tiếp cũng xóa đích trước khi copy ([LocalFileRepository.swift:176–203](../macSCP/Data/Repositories/LocalFileRepository.swift#L176-L203)).
- **Đã xử lý — 2026-11-27.** Repository local ghi stream và copy vào vùng staging cùng volume. Chỉ thay đích nguyên tử sau khi thao tác thành công. Kiểm thử giữ nguyên đích cũ, không để lại đích mới khi lỗi, hủy giữa chừng và thay thế thư mục.

### P0 — Editor đánh dấu đã lưu các chỉnh sửa chưa được ghi

- [x] **Vị trí lúc review:** [FileEditorViewModel.swift:103–117](../macSCP/Features/Editor/FileEditorViewModel.swift#L103-L117), [EditorWindowAccessor.swift:86–96](../macSCP/Features/Editor/Components/EditorWindowAccessor.swift#L86-L96). `save()` gửi `content` vào repository, rồi đọc lại `content` sau `await` để cập nhật `savedContent`. Thử nghiệm với repository giả lập trì hoãn ghi cho thấy repository nhận bản cũ, buffer chứa bản mới và `hasChanges == false`. Luồng Save khi đóng cửa sổ chỉ kiểm tra `error`, nên cũng có thể đóng khi còn chỉnh sửa.
- **Đã xử lý — 2026-11-27.** Editor cập nhật bản đã lưu bằng đúng snapshot gửi cho repository. Chỉnh sửa trong lúc lưu hoặc reload được giữ lại. Luồng xác nhận đóng chờ kết quả lưu và chỉ đóng khi buffer sạch.

### P1 — Scanner bỏ file khi buffer đầy

- [x] **Vị trí lúc review:** [StreamingFileScanner.swift:50–55](../macSCP/Services/TransferCoordinator/StreamingFileScanner.swift#L50-L55), [StreamingFileScanner.swift:149–155](../macSCP/Services/TransferCoordinator/StreamingFileScanner.swift#L149-L155), [FileBrowserViewModel.swift:585–618](../macSCP/Features/Browser/FileBrowserViewModel.swift#L585-L618), [CommanderViewModel.swift:460–500](../macSCP/Features/Commander/CommanderViewModel.swift#L460-L500). Hai producer dùng `.bufferingNewest(100)` và bỏ qua kết quả `yield`. Hai caller lập batch từ các mục nhận được và bỏ qua tổng trong `.finished`. Thử nghiệm với 250 file và consumer đọc chậm chỉ nhận 99 sự kiện file, dù scanner báo tổng 250. Batch có thể hoàn tất theo danh sách thiếu.
- **Đã xử lý — 2026-11-27.** Hai entry point dùng chung kết quả `TransferScan`. Kế hoạch truyền chứa toàn bộ mục đã quét và không còn hàng đợi làm rơi sự kiện. Kiểm thử 251 file trong cùng batch.

### P1 — Lỗi liệt kê thư mục nguồn bị coi như thư mục rỗng

- [x] **Vị trí lúc review:** [StreamingFileScanner.swift:175–187](../macSCP/Services/TransferCoordinator/StreamingFileScanner.swift#L175-L187), [StreamingFileScanner.swift:203–226](../macSCP/Services/TransferCoordinator/StreamingFileScanner.swift#L203-L226), [CommanderViewModel.swift:472–492](../macSCP/Features/Commander/CommanderViewModel.swift#L472-L492). `try?` bỏ lỗi `listFiles` sau khi scanner đã phát sự kiện tạo thư mục đích. Với repository giả lập trả lỗi quyền truy cập, stream vẫn kết thúc bình thường, có một sự kiện thư mục và tổng 0 file. Các nhánh khác vẫn có thể được chuyển, khiến kết quả trông đầy đủ.
- **Đã xử lý — 2026-11-27.** Lỗi liệt kê được trả kèm đường dẫn. Browser và Commander dừng trước khi ghi đích nếu chưa có kết quả quét hợp lệ.

### P1 — Scanner local có thể làm phẳng cây thư mục khi upload

- [x] **Vị trí lúc review:** [StreamingFileScanner.swift:96–118](../macSCP/Services/TransferCoordinator/StreamingFileScanner.swift#L96-L118), [TransferCoreTests.swift:141–178](../macSCPTests/Services/TransferCoreTests.swift#L141-L178). Scanner tính đường dẫn tương đối bằng tiền tố chuỗi và rơi về `lastPathComponent` nếu đường dẫn gốc và đường dẫn do Foundation liệt kê khác cách biểu diễn. XCTest xác nhận file lẽ ra vào `/remote/folder/sub/leaf.txt` bị gửi đến `/remote/leaf.txt`. Thử nghiệm Foundation xác nhận trường hợp `/var` so với `/private/var`.
- **Đã xử lý — 2026-11-27.** Chuẩn hóa URL gốc và tính đường dẫn tương đối theo thành phần, giữ tên thư mục được chọn. Test alias, đường dẫn lồng nhau và file trùng tên ở hai nhánh đều đạt.

### P1 — S3 bỏ lỗi xóa theo từng object

- [x] **Vị trí lúc review:** [S3Session.swift:241–274](../macSCP/Data/S3/S3Session.swift#L241-L274), [S3Session.swift:277–303](../macSCP/Data/S3/S3Session.swift#L277-L303), [S3Session.swift:367–381](../macSCP/Data/S3/S3Session.swift#L367-L381). `deleteDirectory` bỏ toàn bộ `DeleteObjectsOutput`, trong khi SDK trả lỗi riêng cho từng key qua `errors`. Lỗi xóa marker cũng bị bỏ qua. Xóa, đổi tên hoặc di chuyển thư mục có thể báo thành công dù một phần nguồn vẫn còn.
- **Đã xử lý — 2026-11-27.** Kiểm tra `DeleteObjectsOutput.errors` ở từng trang. Prefix marker được xử lý trong cùng batch và lỗi trả về bao gồm số key lỗi cùng các key đầu tiên. Kiểm thử response hỗn hợp qua nhiều trang.

### P1 — SwiftData và Keychain lệch trạng thái khi ghi hoặc xóa thất bại

- [x] **Vị trí lúc review:** [ConnectionListViewModel.swift:136–206](../macSCP/Features/Connections/ConnectionListViewModel.swift#L136-L206). Các thao tác lưu và cập nhật ghi bản ghi trước khi cập nhật Keychain. Nếu Keychain thất bại, metadata mới vẫn tồn tại với credential cũ hoặc thiếu credential. Khi bỏ lưu mật khẩu hoặc xóa kết nối, `try?` che lỗi xóa Keychain và UI có thể báo thành công trong khi credential vẫn còn.
- **Đã xử lý — 2026-11-27.** `ConnectionPersistence` phân biệt credential thiếu với lỗi đọc, bù trừ thay đổi Keychain nếu commit thất bại và báo lỗi nếu không thể khôi phục. Thay đổi cùng một profile được điều phối giữa các cửa sổ. Thao tác thay credential không xóa bản cũ trước khi ghi.

### P2 — Unit tests chưa được chạy tự động trên pull request

- [x] **Vị trí lúc review:** [release.yml:1–12](../.github/workflows/release.yml#L1-L12), [release.yml:49–67](../.github/workflows/release.yml#L49-L67). Workflow duy nhất được theo dõi chạy theo tag hoặc thủ công và archive ứng dụng mà không chạy XCTest. Các lỗi kiểm thử có thể lọt vào nhánh chính.
- **Đã xử lý — 2026-11-27.** Thêm workflow chạy `macSCPTests` trên pull request và push vào `main`. Đã kiểm tra YAML và chạy lệnh tương đương trên máy.

### P2 — Scanner local dùng API duyệt thư mục đồng bộ trong ngữ cảnh async

- [x] **Vị trí lúc review:** [StreamingFileScanner.swift:96–106](../macSCP/Services/TransferCoordinator/StreamingFileScanner.swift#L96-L106), [project.pbxproj:541](../macSCP.xcodeproj/project.pbxproj#L541). Swift compiler cảnh báo `DirectoryEnumerator.makeIterator` không dùng được từ ngữ cảnh async và sẽ là lỗi khi chuyển sang Swift 6 language mode. Target hiện dùng Swift 5 language mode.
- **Đã xử lý — 2026-11-27.** Vòng duyệt đồng bộ chạy trong tác vụ nền. Scanner và các kiểu dữ liệu truyền qua actor qua kiểm tra kiểu với Swift 6 và MainActor default isolation.

**Kiểm chứng.** Chạy target `macSCPTests` bằng Xcode 27.2. Kết quả 175/176 test case đạt. `testStreamingFileScanner_LocalURLsTreeAndHiddenSkip` thất bại ở hai assertion tại dòng 174 và 176. Các lần chạy được ghi ở phần lịch sử bên dưới phản ánh môi trường tại thời điểm đó.

GitNexus đã được lập chỉ mục tại `c453374`. Impact ghi nhận `CRITICAL` cho `S3Session.deleteDirectory` qua các luồng xóa, dán và đổi tên. Impact ghi nhận `HIGH` cho Editor `save` và các thao tác cập nhật/xóa kết nối qua các entry point UI. Hai scanner và `LocalFileRepository.writeStream` có mức `LOW` theo call graph, với đường gọi qua protocol được đối chiếu thêm trong mã nguồn. Chỉ mục có giới hạn số execution trace nên các số liệu flow phản ánh phần đồ thị truy vấn được.

### Phát hiện khi triển khai

- [x] **P0 — Prefix S3 chồng lấn khi đổi tên hoặc di chuyển.** Copy thư mục vào prefix chồng lấn có thể đặt bản mới trong phạm vi xóa nguồn. [S3Session.swift:357–376](../macSCP/Data/S3/S3Session.swift#L357-L376) kiểm tra trước khi copy/xóa. Test còn xác nhận đường dẫn thư mục giữ được ngữ nghĩa trong chế độ duyệt toàn tài khoản.
- [ ] **P2 — Khôi phục sau khi app dừng giữa hai lần ghi.** [ConnectionPersistence.swift:52–90](../macSCP/Data/Repositories/ConnectionPersistence.swift#L52-L90) bù trừ khi nhận lỗi trong tiến trình hiện hành. Nếu app bị dừng đột ngột giữa thao tác Keychain và SwiftData thì lần khởi động sau chưa tự đối soát được. Đề xuất dùng journal trong Keychain kèm trạng thái đối soát để khôi phục theo profile.
- [ ] **P2 — Swift 6 cho toàn bộ target.** [S3Session.swift:19,48](../macSCP/Data/S3/S3Session.swift#L19), [TransferCoreTests.swift:70–74](../macSCPTests/Services/TransferCoreTests.swift#L70-L74). Build Swift 5 vẫn cảnh báo về actor isolation và API khóa đồng bộ trong phần mã cũ ngoài scanner. Đề xuất chuyển từng module, khai báo isolation phù hợp và thay chỗ khóa đồng bộ trong hàm async bằng thao tác scoped.

**Kiểm chứng bản sửa.** Xcode 27.2 chạy 189/189 unit test đạt. Scanner qua kiểm tra kiểu Swift 6 riêng. S3 kiểm thử bằng response giả lập và các lỗi persistence được chèn qua mock.

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
* [ ] **P2 — Danh sách file cấp cao nhất trong snapshot cuối:** `macSCP/Domain/Models/BatchTransferProgress.swift:465-468` gán `topFiles` nhưng bỏ qua biến này và xóa các mục đang chờ trước khi tạo snapshot. Kiểm tra hợp đồng của snapshot cuối, rồi chuyển tiếp danh sách hoặc bỏ biến thừa nếu việc xóa là chủ ý.

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
