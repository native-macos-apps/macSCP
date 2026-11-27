---
id: SPEC-06
title: Transfer Engine & Batch Transfer Coordinator
status: active
last_updated: 2026-11-27
related_files:
  - MacSCP/Services/TransferCoordinator/BatchTransferCoordinator.swift
  - MacSCP/Services/TransferCoordinator/RemoteDirectoryManager.swift
  - MacSCP/Services/TransferCoordinator/StreamingFileScanner.swift
  - MacSCP/Services/TransferCoordinator/TransferRetryPolicy.swift
  - MacSCP/Services/RemoteStreamTransferEngine.swift
  - MacSCP/Services/TransferSettings.swift
  - MacSCP/Domain/Stream/FileStream.swift
  - MacSCP/Domain/Models/TransferProgress.swift
  - MacSCP/Domain/Models/BatchTransferProgress.swift
related_debt:
  - docs/technical-debt.md#13-lạm-dụng-unchecked-sendable--data-races-29-vị-trí
  - docs/technical-debt.md#31-trùng-lặp-mã-nguồn-dry-violations
  - docs/technical-debt.md#33-thiếu-nhất-quán--xử-lý-lỗi-mong-manh
---

# SPEC-06: Transfer Engine & Batch Transfer Coordinator

## 1. Tổng quan & Mục tiêu
Điều phối việc truyền tải tập tin đơn lẻ và hàng loạt (nhiều file / cây thư mục lồng nhau) giữa **Local ↔ SFTP**, **Local ↔ S3**, và **Remote ↔ Remote** (SFTP ↔ S3, SFTP ↔ SFTP, S3 ↔ S3) với độ tin cậy cao, kiểm soát đồng thời (bounded concurrency), tự động retry lỗi tạm thời và **zero-disk streaming** cho truyền giữa hai máy chủ.

---

## 2. User Flows & Hành vi chính

### Flow 1: Batch Transfer (Upload / Download / Cross-Pane)
1. **Scan cây thư mục (`StreamingFileScanner`):** Quét danh sách file (`[TransferQueueItem]`) và danh sách thư mục cần tạo (`directoriesToCreate`) theo thứ tự độ sâu.
2. **Tạo thư mục đích (`RemoteDirectoryManager`):** Tạo các thư mục đích theo thứ tự độ sâu với concurrency tối đa `3`, theo dõi lỗi từng thư mục cha để bỏ qua các file con phụ thuộc nếu thư mục cha tạo thất bại.
3. **Worker Pool giới hạn đồng thời (`BatchTransferCoordinator.executeBatch`):**
   - Số luồng đồng thời cấu hình bởi `TransferSettings.shared.maxConcurrentTransfers` (giá trị `1...8`, mặc định `3`; coordinator clamp `1...16`).
   - Sử dụng `withTaskGroup` để luôn giữ tối đa `concurrency` tác vụ chạy song song.
4. **Retry Policy (`TransferRetryPolicy`):** Tự động thử lại khi gặp lỗi mạng tạm thời với cơ chế backoff; không retry khi đã bị hủy (cancelled).
5. **Cập nhật tiến độ (`BatchProgressTracker` → `BatchProgressSnapshot`):** Phát snapshot bất đồng bộ về UI (progress tổng, số file thành công/lỗi/hủy, tốc độ, danh sách active/recent transfers).
6. **Hủy truyền tải (Cancellation):** Người dùng bấm Cancel → lan truyền hủy đến tất cả worker đang chạy, ngừng lập lịch item mới, cập nhật trạng thái `.cancelled`.

### Flow 2: Zero-Disk Remote-to-Remote Streaming (`RemoteStreamTransferEngine`)
1. Khi truyền file giữa hai remote repository (ví dụ SFTP → S3 hoặc SFTP A → SFTP B):
2. Mở `FileStreamReader` từ `sourceRepo.openStreamReader(at:)`.
3. Đẩy trực tiếp luồng byte vào `targetRepo.writeStream(from:to:totalSize:progress:)` mà **không ghi file tạm ra ổ đĩa local**.
4. Với thư mục: tạo thư mục đích và duyệt đệ quy từng phần tử, tích lũy tiến độ qua `CumulativeTransferTracker`.

---

## 3. Data Models & Contracts
- **`FileStreamReader`** (`MacSCP/Domain/Stream/FileStream.swift`): Protocol đọc dữ liệu theo chunk bất đồng bộ và đóng stream (`close()`).
- **`TransferProgress`**: Theo dõi từng file (`id`, `fileName`, `transferType`, `bytesTransferred`, `totalBytes`, `status`, `startTime`, `isDirectory`, `itemCount`).
- **`BatchTransferProgress`**: Trạng thái tổng hợp của cả batch (`totalFiles`, `completedFiles`, `failedFiles`, `totalBytes`, `completedBytes`, `fractionCompleted`, `status`, `failedTransfers`).
- **`BatchExecutionResult`**: Kết quả cuối cùng trả về sau khi `executeBatch` kết thúc.
- **`TransferSettings`**: Lưu `maxConcurrentTransfers` (`1...8`, mặc định `3`) vào `UserDefaults` (`app.settings.maxConcurrentTransfers`).

---

## 4. Kiến trúc & Entry Points
- **Coordinator:** `BatchTransferCoordinator` (`Services/TransferCoordinator/`).
- **Support Components:** `RemoteDirectoryManager`, `StreamingFileScanner`, `TransferRetryPolicy`.
- **Direct Streaming:** `RemoteStreamTransferEngine`.
- **UI Consumers:** `FileBrowserViewModel`, `CommanderViewModel`, `TransfersPopover`, `CommanderTransfersPopover`, `BatchTransferHeaderView`.

---

## 5. Edge Cases & Xử lý lỗi
| Tình huống | Hành vi mong đợi |
| :--- | :--- |
| Hủy batch trong lúc đang tạo thư mục | Dừng ngay, không chạy worker pool, trả về `BatchExecutionResult(isCancelled: true)`. |
| Tạo thư mục cha thất bại | Ghi nhận lỗi vào tracker, không đẩy file con vào vòng lặp lỗi vô ích. |
| Đã có batch đang chạy và người dùng kéo thêm batch mới | Báo đang có batch và yêu cầu người dùng chờ hoặc hủy batch trước. |
| File có kích thước 0 byte | Vẫn tạo file thành công, không chia cho 0 khi tính `fractionCompleted`. |

---

## 6. Security, Concurrency & Invariants
- **Bounded Concurrency Invariant:** Không bao giờ tạo unbounded tasks cho thư mục hàng nghìn file; luôn giới hạn qua worker pool.
- **Zero-Disk Streaming Invariant:** Truyền giữa hai remote repo không được ghi file dữ liệu tạm xuống local disk.
- **Snapshot Ordering Invariant:** UI phải bỏ qua các `BatchProgressSnapshot` có sequence cũ hơn `lastAppliedSnapshotSequence` để tránh thanh tiến độ nhảy lùi.

---

## 7. Acceptance Criteria
- [ ] Upload/Download thư mục nhiều cấp với số luồng cấu hình từ `Settings > Transfers` (1–8 streams) hoạt động ổn định.
- [ ] Cancel batch dừng toàn bộ tác vụ nhanh chóng và giải phóng tài nguyên/stream.
- [ ] Truyền file giữa hai kết nối remote khác nhau hoạt động trực tiếp qua stream không tốn dung lượng ổ đĩa tạm.

---

## 8. Known Gaps & Technical Debt
- **P0 — Ghi stream xuống đích local có thể làm mất file cũ khi ghi lỗi hoặc bị hủy.**
- **P1 — Scanner có thể bỏ mục khi buffer đầy.** Hai caller lập batch từ các sự kiện nhận được và bỏ qua tổng số mục đã quét.
- **P1 — Lỗi liệt kê thư mục remote bị bỏ qua.** Batch có thể tạo thư mục đích rỗng rồi hoàn tất dù thiếu file nguồn.
- **P1 — Scanner local có thể làm phẳng cây thư mục.** So sánh tiền tố chuỗi thất bại khi Foundation liệt kê qua alias khác với đường dẫn đầu vào.
- **P2 — Scanner local duyệt `DirectoryEnumerator` từ ngữ cảnh async.** Compiler cảnh báo đường này sẽ lỗi ở Swift 6 language mode.
- Chi tiết và đề xuất xử lý nằm trong [báo cáo nợ kỹ thuật](../technical-debt.md#các-khoản-nợ-mở-ngày-2026-11-27).
- ~~**P0 — `CancellationBox` data race**~~ (Đã xử lý — 2026-11-26: thay bằng `OSAllocatedUnfairLock` lưu `CancellationState`).
- ~~**P1 — Trùng lặp Batch state & thiếu sequence guard**~~ (Đã xử lý — 2026-11-26: gom vào `FileTransferManager` với `lastAppliedSnapshotSequence` guard cho cả `FileBrowserViewModel` và `CommanderViewModel`).
- ~~**P1 — Hardcode `transferType: .upload`**~~ (Đã xử lý — 2026-11-26: truyền tham số `transferType` qua `BatchTransferCoordinator.executeBatch`).
- ~~**P2 — Nuốt thao tác khi batch đang chạy & inconsistent `recentTransfers` limit**~~ (Đã xử lý — 2026-11-26: chuẩn hóa giới hạn `30` và thông báo lỗi khi đang có batch chạy).
