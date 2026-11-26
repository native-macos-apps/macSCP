# MacSCP — Feature Specifications (`docs/specs/`)

Thư mục này là **Single Source of Truth (SSOT)** mô tả toàn bộ kiến trúc và đặc tả tính năng của **MacSCP**, được thiết kế tối ưu cho **AI-Driven Development Workflow (Spec-Driven Development)**.

---

## Quy trình phát triển theo AI Workflow

Mọi tác vụ phát triển tính năng mới, sửa lỗi hoặc refactor trong MacSCP tuân theo vòng đời 4 bước:

```mermaid
flowchart LR
    A["1. Spec (docs/specs/)"] --> B["2. Plan (docs/plans/)"]
    B --> C["3. Implement & Test"]
    C --> D["4. Sync Spec & Debt"]
```

1. **Đọc Spec trước khi lập kế hoạch / sửa code:**
   - AI Agent chỉ cần nạp file spec liên quan từ bảng danh mục bên dưới (giảm nhiễu context) kết hợp tra cứu call-graph bằng GitNexus (`query`, `context`, `impact`).
   - Kiểm tra mục **Invariants / Constraints** và **Known Gaps / Tech Debt** trong spec trước khi thay đổi thiết kế.
2. **Tạo Implementation Plan trong `docs/plans/`:**
   - Tuân thủ quy ước đặt tên `YYYYMMDDSeq-<artifact-name>.md` (xem `AGENTS.md`).
   - Tham chiếu ngược lại mã spec (ví dụ: `SPEC-03`, `SPEC-06`).
3. **Triển khai & Kiểm thử:**
   - Chạy impact analysis trước khi sửa symbol; kiểm tra build & unit tests sau khi hoàn tất.
4. **Đồng bộ ngược tài liệu:**
   - Nếu hành vi tính năng, data model, hoặc acceptance criteria thay đổi: **bắt buộc cập nhật file spec tương ứng** trong `docs/specs/` trong cùng PR/commit.
   - Nếu phát sinh hoặc xử lý xong nợ kỹ thuật: cập nhật `docs/technical-debt.md` và đồng bộ mục *Known Gaps* của spec liên quan.

---

## Danh mục Đặc tả (Spec Index)

| Mã | Tài liệu | Phạm vi | Trạng thái |
| :--- | :--- | :--- | :---: |
| `SPEC-00` | [00-architecture.md](00-architecture.md) | Kiến trúc tổng thể, Layers, DI, Multi-Window, Persistence, Dependencies | Active |
| `SPEC-01` | [01-commander-workspace.md](01-commander-workspace.md) | Dual-Pane Commander Workspace (Local / Remote / Servers), cross-pane transfer | Active |
| `SPEC-02` | [02-connection-management.md](02-connection-management.md) | Quản lý Connection & Folder, CRUD, tìm kiếm, Keychain credentials | Active |
| `SPEC-03` | [03-sftp-engine.md](03-sftp-engine.md) | Native SFTP Engine (`swift-nio-ssh`), RFC 4254 handshake, Known Hosts, In-App SSH Key Manager | Active |
| `SPEC-04` | [04-s3-storage.md](04-s3-storage.md) | Amazon S3 & S3-Compatible storage, bucket/prefix, multipart stream, public/presigned URL | Active |
| `SPEC-05` | [05-file-browser.md](05-file-browser.md) | File Browser, Navigation, CRUD, Clipboard, Quick Look, Local Sandbox Bookmarks, File Info | Active |
| `SPEC-06` | [06-transfer-engine.md](06-transfer-engine.md) | Batch Transfer Coordinator, bounded concurrency, retry policy, zero-disk remote streaming | Active |
| `SPEC-07` | [07-file-editor.md](07-file-editor.md) | Built-in Text/Code File Editor, Find & Replace, Save/Reload/Revert | Active |
| `SPEC-08` | [08-terminal-integration.md](08-terminal-integration.md) | Integrated SSH Terminal (`SwiftTerm` + `swift-nio-ssh`) | Active |
| `SPEC-09` | [09-security-and-settings.md](09-security-and-settings.md) | App Lock (Touch ID / Passcode), Settings (4 tabs), Sparkle Auto-Updates | Active |

---

## Tạo Spec cho Tính năng mới

Khi đề xuất tính năng mới (ví dụ: File Sync, Import/Export Connections, iCloud Sync):
1. Sao chép mẫu từ [`_template.md`](_template.md) thành `docs/specs/XX-<feature-name>.md`.
2. Điền đầy đủ frontmatter, User Flows, Data Contracts, Edge Cases, Invariants và Acceptance Criteria với `status: draft`.
3. Sau khi hoàn tất triển khai, đổi `status: active` và cập nhật bảng **Spec Index** ở trên.
