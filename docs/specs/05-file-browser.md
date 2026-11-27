---
id: SPEC-05
title: File Browser, Local Access, Quick Look & File Info
status: active
last_updated: 2026-11-27
related_files:
  - MacSCP/Features/Browser/FileBrowserViewModel.swift
  - MacSCP/Features/Browser/FileBrowserView.swift
  - MacSCP/Features/Browser/FileBrowserWindow.swift
  - MacSCP/Features/Browser/Components/NativeFileTableView.swift
  - MacSCP/Features/Browser/Components/NativeFileTableView+DragDrop.swift
  - MacSCP/Features/Browser/Components/NativeFileTableView+ContextMenu.swift
  - MacSCP/Features/Browser/Components/BreadcrumbView.swift
  - MacSCP/Features/Browser/Components/QuickLookPreviewView.swift
  - MacSCP/Features/Browser/Components/LocalPermissionRequestView.swift
  - MacSCP/Features/Browser/Components/TransfersPopover.swift
  - MacSCP/Features/FileInfo/FileInfoWindow.swift
  - MacSCP/Features/FileInfo/FileInfoView.swift
  - MacSCP/Features/FileInfo/FileInfoViewModel.swift
  - MacSCP/Data/Repositories/LocalFileRepository.swift
  - MacSCP/Services/LocalBookmarkService.swift
  - MacSCP/Services/ClipboardService.swift
  - MacSCP/Services/NavigationService.swift
  - MacSCP/Services/FileTypeService.swift
related_debt:
  - docs/technical-debt.md#21-god-objects--các-hàm-quá-dài
  - docs/technical-debt.md#22-leaky-abstraction-theo-loại-kết-nối
  - docs/technical-debt.md#24-rò-rỉ-bộ-nhớ--file-tạm-trong-quick-look
  - docs/technical-debt.md#32-dead-code--api-gây-hiểu-nhầm
---

# SPEC-05: File Browser, Local Access, Quick Look & File Info

## 1. Tổng quan & Mục tiêu
Cung cấp trình duyệt tập tin chuẩn Finder cho cả **Local**, **SFTP**, và **S3** (chạy nhúng trong Commander pane hoặc mở thành `FileBrowserWindow` độc lập), hỗ trợ điều hướng lịch sử, CRUD, clipboard, drag-and-drop, Quick Look xem trước và cửa sổ File Info.

---

## 2. User Flows & Hành vi chính

### Flow 1: Điều hướng & Hiển thị Danh sách File
- **Native Table (`NativeFileTableView` — AppKit `NSOutlineView`):** Hiển thị icon hệ thống (`FileTypeService.systemIcon`), tên, kích thước (`displaySize`), ngày sửa đổi, quyền Unix (`permissions`).
- **Sắp xếp & Lọc:** Thư mục luôn đứng trước file (`RemoteFile.sortedFiles`); sắp xếp theo `Name`, `Size`, `Date Modified`, `Type` (tăng/giảm dần); bật/tắt hiển thị file ẩn (`showHiddenFiles`).
- **Lịch sử & Breadcrumb:** Hỗ trợ Back / Forward (`NavigationService`), Up (`canGoUp`), Refresh (`Cmd+R`), và thanh `BreadcrumbView` (`pathComponents`) nhảy nhanh về bất kỳ thư mục cha nào.

### Flow 2: Thao tác File (CRUD & Clipboard)
- Tạo thư mục mới, tạo file rỗng, đổi tên, xóa (kèm hộp thoại xác nhận `isShowingDeleteConfirmation`).
- **Clipboard (`ClipboardService`):** Copy / Cut / Paste file & thư mục trong cùng phiên duyệt.
- **Upload / Download:** Kéo-thả file từ Finder vào bảng để upload hàng loạt; tải file đơn lẻ hoặc nhiều file về máy cục bộ; hiển thị tiến độ trong `TransfersPopover`.
- **Context Menu:** Open / Edit, Download, Copy, Cut, Paste, Rename, Delete, Get Info, Copy Public/Presigned URL (khi là S3).

### Flow 3: Quick Look Preview (`QuickLookPreviewView`)
- Nhấn Space (hoặc toggle Quick Look) trên file đang chọn (`primarySelectedFile`) để xem trước nhanh (văn bản/code, hình ảnh, PDF…).
- Khi đổi `primarySelectedFile` lúc Quick Look đang mở, tự động hủy task cũ (`quickLookTask?.cancel()`) và tải nội dung cho file mới.
- Lưu cache theo đường dẫn (`quickLookCache`) để tránh tải lại trong cùng phiên.

### Flow 4: Duyệt Local File System trong App Sandbox (`LocalBookmarkService`)
- Khi khởi động app, `MacSCPApp.init()` gọi `LocalBookmarkService.shared.restoreAccess()` để khôi phục Security-Scoped Bookmark đã cấp quyền trước đó (tự động refresh nếu bookmark bị stale).
- Nếu chưa có quyền truy cập thư mục cục bộ, hiển thị `LocalPermissionRequestView` để người dùng chọn thư mục qua `NSOpenPanel` và lưu bookmark (`saveBookmark(for:)`).

### Flow 5: Xem Thông tin Chi tiết (`FileInfoWindow`)
- Mở cửa sổ nhỏ gọn (`windowResizability(.contentSize)`) hiển thị: icon hệ thống, tên, đường dẫn đầy đủ, thư mục cha, kích thước, loại file (`FileTypeService.typeDescription`), định dạng phần mở rộng, quyền Unix dạng chuỗi & mô tả chi tiết (`formatPermissions`), ngày sửa đổi, cờ `isHidden` / `isSymlink` / `isExecutable` / `isEditable`.

---

## 3. Data Models & Contracts
- **`RemoteFile`** (`MacSCP/Domain/Models/RemoteFile.swift`): `id`, `name`, `path`, `isDirectory`, `size`, `permissions`, `modificationDate`, `owner`, `group`; kèm `FileType` enum (14 nhóm: `directory`, `text`, `code`, `configuration`, `image`, `video`, `audio`, `archive`, `document`, `spreadsheet`, `presentation`, `pdf`, `executable`, `unknown`) và `SortCriteria`.
- **`ClipboardItem`** (`MacSCP/Domain/Models/ClipboardItem.swift`).
- **`LocalFileRepository`**: Triển khai `FileRepositoryProtocol` trên `FileManager` + `LocalFileStreamReader`.

---

## 4. Kiến trúc & Entry Points
- **Views & Windows:** `FileBrowserWindow`, `FileBrowserView`, `NativeFileTableView`, `BreadcrumbView`, `QuickLookPreviewView`, `LocalPermissionRequestView`, `FileInfoWindow`, `FileInfoView`.
- **ViewModels:** `FileBrowserViewModel` (hỗ trợ 3 initializer: SFTP, S3, Local), `FileInfoViewModel`.
- **Services:** `NavigationService`, `ClipboardService`, `FileTypeService`, `LocalBookmarkService`.

---

## 5. Edge Cases & Xử lý lỗi
| Tình huống | Hành vi mong đợi |
| :--- | :--- |
| Chuyển file nhanh khi Quick Look đang tải | Hủy `quickLookTask` trước đó, không ghi đè nội dung của file cũ lên file mới. |
| Bookmark local bị stale sau khi nâng cấp macOS | Tự động tạo lại bookmark mới từ URL đã resolve hoặc hiển thị lại `LocalPermissionRequestView`. |
| Mở file không phải text/code (`!fileType.isEditable`) | Không mở bằng text editor; cho phép download hoặc Quick Look nếu hỗ trợ. |
| Upload cây thư mục qua alias của filesystem | Giữ tên thư mục người dùng chọn và đường dẫn lồng nhau. Nếu không xác định được đường dẫn tương đối thì báo lỗi trước khi upload. |
| Copy qua repository local hoặc ghi stream vào đích local thất bại | Giữ nội dung cũ của đích, nếu có. |

---

## 6. Security, Concurrency & Invariants
- Thao tác xóa file/thư mục luôn yêu cầu xác nhận người dùng trước khi gọi repository.
- Security-scoped resource phải gọi `stopAccessingSecurityScopedResource()` khi thay thế hoặc dừng truy cập.

---

## 7. Acceptance Criteria
- [ ] Duyệt, sắp xếp, lọc file ẩn, back/forward/breadcrumb hoạt động đồng nhất trên Local, SFTP và S3.
- [ ] CRUD, Copy/Cut/Paste, Drag-and-drop upload, Download, Quick Look và File Info hoạt động đầy đủ.
- [ ] Local browser xin quyền và khôi phục quyền mượt mà trong môi trường App Sandbox.

---

## 8. Known Gaps & Technical Debt
- ~~**P0/P1 — Ghi vào đích local và tính đầy đủ của cây upload**~~ (Đã xử lý — 2026-11-27: staging trước khi thay đích, bản kê quét đầy đủ và đường dẫn tương đối chuẩn hóa). Xem [SPEC-06](06-transfer-engine.md).
- ~~**P1 — God Object & Leaky Abstraction:** `FileBrowserViewModel.swift` dài 1,355 dòng và phân nhánh trực tiếp theo `sftpSession`/`s3Session`/`isLocal`~~ (Đã xử lý — 2026-11-26: tách `BrowserSessionProtocol`, `BrowserQuickLookController`, và `FileTransferManager`).
- ~~**P1 — Rò rỉ bộ nhớ & file tạm trong Quick Look**~~ (Đã xử lý — 2026-11-26: `BrowserQuickLookController` dùng `NSCache`, xóa cache khi `disconnect()`, không cache lỗi, và `defer` xóa file tạm).
- ~~**P0 — `LocalFileStreamReader` data race**~~ (Đã xử lý — 2026-11-26: chuyển sang `actor`).
- ~~**P2 — Dead code:** `navigateWithoutHistory(to:)` không được gọi; log category CRUD bị hardcode `.sftp`~~ (Đã xử lý — 2026-11-26: xóa `navigateWithoutHistory`, dùng `session.logCategory`).
