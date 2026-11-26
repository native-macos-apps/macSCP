---
id: SPEC-01
title: Dual-Pane Commander Workspace
status: active
last_updated: 2026-11-26
related_files:
  - MacSCP/Features/Commander/CommanderWorkspaceView.swift
  - MacSCP/Features/Commander/CommanderViewModel.swift
  - MacSCP/Features/Commander/Components/CommanderPaneView.swift
  - MacSCP/Features/Commander/Components/CommanderPaneHeaderView.swift
  - MacSCP/Features/Commander/Components/CommanderFileBrowserPaneView.swift
  - MacSCP/Features/Commander/Components/CommanderServersPaneView.swift
  - MacSCP/Features/Commander/Components/CommanderTransfersPopover.swift
  - MacSCP/Features/Commander/Components/NativeServersTableView.swift
related_debt:
  - docs/technical-debt.md#12-race-condition--rò-rỉ-session-ở-commanderviewmodel
  - docs/technical-debt.md#16-rủi-ro-crash-từ-fatalerror--force-unwrap
  - docs/technical-debt.md#21-god-objects--các-hàm-quá-dài
  - docs/technical-debt.md#33-thiếu-nhất-quán--xử-lý-lỗi-mong-manh
---

# SPEC-01: Dual-Pane Commander Workspace

## 1. Tổng quan & Mục tiêu
Không gian làm việc chính của MacSCP thiết kế theo mô hình **Dual-Pane Commander** (phong cách Transmit 5), cho phép người dùng mở đồng thời hai khung duyệt độc lập (Trái / Phải) với bất kỳ tổ hợp nguồn nào: **Local ↔ Remote**, **Remote ↔ Remote**, hoặc **Local ↔ Servers**, hỗ trợ kéo-thả và truyền tải trực tiếp giữa hai khung.

---

## 2. User Flows & Hành vi chính

### Flow 1: Khởi tạo & Chuyển đổi nguồn của từng Pane
- Mặc định khi mở ứng dụng:
  - **Left Pane (`leftPane`):** `.local` (thư mục home của người dùng).
  - **Right Pane (`rightPane`):** `.servers` (danh sách kết nối & thư mục từ `ConnectionListViewModel`).
- Người dùng có thể chuyển đổi nguồn của bất kỳ pane nào qua `CommanderPaneHeaderView`:
  - **Local:** Chuyển sang duyệt máy cục bộ (`switchToLocal`).
  - **Servers:** Hiển thị danh sách kết nối (`switchToServers`) kèm tìm kiếm nhanh (`serverSearchText`).
  - **Remote (`Connection`):** Kết nối SFTP hoặc S3 trực tiếp ngay trong pane đó.
- Hỗ trợ bật/tắt chế độ 2 khung (`isDualPane`) và theo dõi khung đang active (`activePanePosition`: `.left` / `.right`).

### Flow 2: Truyền tải chéo giữa hai Pane (Cross-Pane Transfer)
1. Người dùng chọn file/thư mục ở pane nguồn và kéo-thả sang pane đích (hoặc dùng nút hành động transfer).
2. `CommanderViewModel` xác định cặp `(sourceRepo, targetRepo)`:
   - **Local → Remote (Upload):** Quét cây thư mục và thực thi qua `BatchTransferCoordinator`.
   - **Remote → Local (Download):** Tải file/thư mục về đường dẫn hiện tại của Local pane.
   - **Remote → Remote (Direct Streaming):** Streaming trực tiếp giữa hai máy chủ qua `FileStreamReader`/`writeStream` không tạo file tạm local.
3. Sau khi hoàn tất, tự động làm mới danh sách file ở pane đích.

### Flow 3: Tổng hợp Tiến độ Truyền tải (Aggregated Transfers)
- Thanh công cụ hiển thị badge tổng số transfer đang chạy trên cả 2 pane (`activeTransferBadgeText`, hiển thị `"99+"` nếu > 99) và tiến độ tổng (`overallProgress`).
- Nhấn vào biểu tượng transfer mở `CommanderTransfersPopover` để xem chi tiết active/recent transfers, hủy batch (`cancelBatch`), xóa lịch sử (`clearCompletedTransfers`) hoặc xóa từng mục (`removeTransfer`).

### Flow 4: Mở Terminal nhanh từ Commander
- Cho phép mở macOS Terminal cho kết nối SFTP đang mở tại pane hoặc từ danh sách server trong `CommanderServersPaneView`.

---

## 3. Data Models & Contracts
- **`PanePosition`**: `.left`, `.right` (với thuộc tính `.other`).
- **`PaneContentType`**: `.local`, `.remote(Connection)`, `.servers`.
- **`CommanderPaneState`**: `@MainActor @Observable` lưu `position`, `contentType`, `browserViewModel: FileBrowserViewModel?`, `serverSearchText`.

---

## 4. Kiến trúc & Entry Points
- **Root View:** `CommanderWorkspaceView` (Main `WindowGroup` trong `MacSCPApp.swift`).
- **ViewModel:** `CommanderViewModel` (giữ `leftPane`, `rightPane`, `connectionListViewModel`, và `DependencyContainer`).
- **AppKit Bridges:** `NativeServersTableView` (`NSOutlineView` cho danh sách folder/server trong Servers pane).

---

## 5. Edge Cases & Xử lý lỗi
| Tình huống | Hành vi mong đợi |
| :--- | :--- |
| Chuyển từ Remote sang Local/Servers hoặc sang Remote khác | Phải ngắt kết nối (`disconnect()`) **session cũ** trước khi giải phóng, không ngắt nhầm session mới. |
| Kết nối SFTP chưa lưu mật khẩu | Lưu `pendingConnection` + `pendingPanePosition` và bật `PasswordPromptSheet`. |
| Mở Terminal bị từ chối quyền Automation | Hiển thị lỗi `TerminalLauncherError.automationNotAuthorized` cho người dùng. |

---

## 6. Security, Concurrency & Invariants
- **Session Cleanup Invariant:** Khi thay thế `browserViewModel` của một pane, **luôn capture `let previousVM = targetPane.browserViewModel` trước** khi gán mới, sau đó mới `Task { await previousVM?.disconnect() }`.
- Toàn bộ trạng thái pane và UI binding chạy trên `@MainActor`.

---

## 7. Acceptance Criteria
- [ ] Khởi động app hiển thị Left = Local, Right = Servers; chuyển đổi qua lại giữa Local / Servers / SFTP / S3 ở cả hai pane mượt mà.
- [ ] Kéo-thả file và thư mục giữa 2 pane (Local ↔ SFTP, Local ↔ S3, SFTP ↔ S3) hoạt động và cập nhật tiến độ chính xác.
- [ ] Không rò rỉ kết nối mạng khi chuyển pane liên tục.

---

## 8. Known Gaps & Technical Debt
- ~~**P0 — Race condition & rò rỉ session:** `switchToLocal`, `switchToServers`, `completeConnect` trong `CommanderViewModel.swift`~~ (Đã xử lý — 2026-11-26).
- ~~**P0 — `fatalError()` ở `NativeServersTableView.swift:197`**~~ (Đã xử lý — 2026-11-26).
- **P1 — Trùng lặp batch transfer state với `FileBrowserViewModel`** (`docs/technical-debt.md#2.1`, `#3.1`, `#3.3`).
