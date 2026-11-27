---
id: SPEC-07
title: Built-in File Editor
status: active
last_updated: 2026-11-27
related_files:
  - MacSCP/Features/Editor/FileEditorWindow.swift
  - MacSCP/Features/Editor/FileEditorView.swift
  - MacSCP/Features/Editor/FileEditorViewModel.swift
  - MacSCP/Features/Editor/Components/EditorHeaderView.swift
  - MacSCP/Features/Editor/Components/EditorContentView.swift
  - MacSCP/Features/Editor/Components/EditorStatusBar.swift
  - MacSCP/Features/Editor/Components/SearchReplaceBar.swift
  - MacSCP/Features/Editor/Components/EditorWindowAccessor.swift
related_debt:
  - docs/technical-debt.md#14-mất-dữ-liệu-âm-thầm-khi-đọc-file-non-utf-8
---

# SPEC-07: Built-in File Editor

## 1. Tổng quan & Mục tiêu
Cho phép người dùng mở và chỉnh sửa trực tiếp các file văn bản, mã nguồn và cấu hình (`FileType.isEditable`: `.text`, `.code`, `.configuration`) trên máy chủ SFTP, S3 hoặc Local trong một cửa sổ riêng biệt (`FileEditorWindow`) mà không cần tải xuống và upload lại thủ công.

---

## 2. User Flows & Hành vi chính

### Flow 1: Mở & Chỉnh sửa File
1. Người dùng chọn mở/chỉnh sửa một file từ File Browser.
2. Nội dung file được đọc qua `fileRepository.readFileContent(at:)` và nạp vào `FileEditorViewModel` trong cửa sổ `FileEditorWindow` (hỗ trợ mở nhiều cửa sổ song song).
3. Theo dõi trạng thái thay đổi (`hasChanges = content != savedContent`) để hiển thị chỉ báo chưa lưu trên `EditorHeaderView` / tiêu đề cửa sổ.
4. `EditorStatusBar` hiển thị thời gian thực: số dòng (`lineCount`), số từ (`wordCount`), số ký tự (`characterCount`).

### Flow 2: Lưu, Tải lại & Hoàn tác
- **Save (`save()`):** Chụp snapshot buffer, ghi qua repository và cập nhật `savedContent` bằng snapshot đã ghi thành công. Chỉnh sửa phát sinh trong khi ghi vẫn được đánh dấu chưa lưu.
- **Reload (`reload()`):** Đọc phiên bản mới nhất và áp dụng nếu buffer chưa đổi trong lúc đọc. Mỗi cửa sổ thực hiện tối đa một Save hoặc Reload tại một thời điểm.
- **Revert (`revertChanges()`):** Hoàn tác toàn bộ chỉnh sửa cục bộ về `savedContent` mà không cần gọi mạng.

### Flow 3: Tìm kiếm & Thay thế (`SearchReplaceBar`)
- Bật/tắt thanh tìm kiếm (`toggleSearch()`).
- Hỗ trợ tùy chọn `isCaseSensitive` và `isWholeWord` (kiểm tra ranh giới từ trước/sau bằng `!isLetter`).
- Điều hướng kết quả vòng tròn (`findNext()`, `findPrevious()`), hiển thị trạng thái `"X of Y"` hoặc `"No results"`.
- Hỗ trợ `replaceCurrent()` và `replaceAll()` (có tôn trọng `isCaseSensitive` và `isWholeWord`).

### Flow 4: Đóng cửa sổ & Dọn dẹp Session
- Khi đóng `FileEditorWindow`, gọi `cleanup()` để ngắt kết nối `sftpSession` hoặc `s3Session` riêng (nếu editor tự sở hữu session).
- Nếu người dùng chọn lưu trong hộp thoại xác nhận, chỉ tự đóng khi lưu thành công và buffer đã sạch.

---

## 3. Data Models & Contracts
- **`FileEditorViewModel`** (`@MainActor @Observable`): quản lý `content`, `savedContent`, `state: ViewState<Void>`, `error: AppError?`, trạng thái search/replace, và `fileRepository: FileRepositoryProtocol`.
- **Editable extensions (`RemoteFile.swift`):**
  - `.text`: `txt`, `md`, `markdown`, `rtf`, `log`
  - `.code`: `swift`, `js`, `ts`, `jsx`, `tsx`, `py`, `rb`, `go`, `rs`, `java`, `kt`, `c`, `cpp`, `h`, `hpp`, `m`, `mm`, `cs`, `php`, `html`, `htm`, `css`, `scss`, `sass`, `less`, `sql`, `sh`, `bash`, `zsh`, `fish`, `ps1`, `bat`, `cmd`
  - `.configuration`: `json`, `yaml`, `yml`, `xml`, `plist`, `ini`, `conf`, `config`, `env`, `gitignore`, `dockerfile`, `makefile`, `toml`

---

## 4. Kiến trúc & Entry Points
- **Window & Root View:** `FileEditorWindow` (Scene `WindowID.fileEditor`), `FileEditorView`.
- **Components:** `EditorHeaderView`, `EditorContentView`, `EditorStatusBar`, `SearchReplaceBar`, `EditorWindowAccessor`.
- **ViewModel:** `FileEditorViewModel`.

---

## 5. Edge Cases & Xử lý lỗi
| Tình huống | Hành vi mong đợi |
| :--- | :--- |
| Lưu file thất bại (mất mạng / không có quyền ghi) | Giữ nguyên `content` và `hasChanges == true`, hiển thị `AppError` để người dùng thử lại. |
| File có encoding không phải UTF-8 | **Cần chặn mở/lưu** với lỗi encoding rõ ràng để tránh ghi đè làm mất dữ liệu (xem Known Gaps). |
| Tìm kiếm với `searchText` rỗng | Reset `searchResults = []`, `currentSearchIndex = 0`, không vòng lặp vô hạn. |

---

## 6. Security, Concurrency & Invariants
- Không bao giờ mất nội dung người dùng đang soạn khi thao tác `save()` thất bại.
- Đóng cửa sổ editor phải giải phóng session mạng đã cấp riêng cho cửa sổ đó.

---

## 7. Acceptance Criteria
- [ ] Mở, sửa, lưu, reload, revert file trên cả SFTP, S3 và Local hoạt động chính xác.
- [ ] Find, Find Next/Previous, Replace, Replace All với Case Sensitive & Whole Word trả về kết quả đúng.
- [ ] Mở nhiều cửa sổ Editor cùng lúc hoạt động độc lập.

---

## 8. Known Gaps & Technical Debt
- ~~**P0 — Editor có thể đánh dấu đã lưu các chỉnh sửa phát sinh trong lúc chờ ghi**~~ (Đã xử lý — 2026-11-27: dùng snapshot và kiểm tra buffer khi tự đóng).
- ~~**P0 — Nguy cơ mất dữ liệu với file non-UTF-8**~~ (Đã xử lý — 2026-11-26: `SFTPSession`, `S3Session`, và `LocalFileRepository` đều throw `AppError.invalidFileEncoding` khi file không phải UTF-8 hợp lệ).
