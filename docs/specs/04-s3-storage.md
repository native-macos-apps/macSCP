---
id: SPEC-04
title: Amazon S3 & S3-Compatible Storage
status: active
last_updated: 2026-11-26
related_files:
  - MacSCP/Data/S3/S3Session.swift
  - MacSCP/Data/S3/S3SessionProtocol.swift
  - MacSCP/Data/Repositories/S3FileRepository.swift
  - MacSCP/Domain/Models/S3Credentials.swift
related_debt:
  - docs/technical-debt.md#13-lạm-dụng-unchecked-sendable--data-races-29-vị-trí
  - docs/technical-debt.md#16-rủi-ro-crash-từ-fatalerror--force-unwrap
  - docs/technical-debt.md#21-god-objects--các-hàm-quá-dài
  - docs/technical-debt.md#33-thiếu-nhất-quán--xử-lý-lỗi-mong-manh
---

# SPEC-04: Amazon S3 & S3-Compatible Storage

## 1. Tổng quan & Mục tiêu
Cho phép người dùng duyệt và thao tác đối tượng trên **Amazon S3** cũng như các dịch vụ tương thích S3 (**MinIO, DigitalOcean Spaces, Cloudflare R2, Backblaze B2…**) với trải nghiệm giống hệ thống thư mục truyền thống, hỗ trợ streaming upload/download và tạo liên kết chia sẻ (Public / Presigned URL).

---

## 2. User Flows & Hành vi chính

### Flow 1: Kết nối S3 / S3-Compatible
1. Đọc `accessKeyId` (`connection.username`), `secretAccessKey` (Keychain), `region` (`s3Region`), `bucket` (`s3Bucket`), và `endpoint` (`s3Endpoint`).
2. `S3Session.connect(...)` khởi tạo `AWSS3.S3Client` (hỗ trợ custom endpoint & path-style/virtual-hosted addressing).
3. Nếu không chỉ định `bucket`, cho phép liệt kê danh sách buckets (mỗi bucket hiển thị như thư mục đặc biệt với `RemoteFile.isBucket == true`, `permissions` bắt đầu bằng `"b"`).

### Flow 2: Duyệt Prefix & CRUD Object
- Giả lập cấu trúc thư mục qua delimiter `/` và prefix:
  - `listFiles(at:)`: trả về cả CommonPrefixes (thư mục ảo) lẫn Objects.
  - `createDirectory(at:)`: tạo marker object có dấu `/` ở cuối.
  - `createFile(at:)`: tạo object rỗng.
  - `deleteDirectory(at:)`: xóa đệ quy toàn bộ object dưới prefix.
  - `rename` / `move`: thực hiện tổ hợp Copy + Delete (do S3 không có rename nguyên tử).
  - `copyFile` / `copyDirectory`: sao chép server-side giữa các key.

### Flow 3: Upload, Download & Streaming
- Upload/Download có báo cáo tiến độ (`TransferProgressHandler`).
- Hỗ trợ streaming qua `openStreamReader(at:)` (`S3StreamReader`) và `writeStream(from:to:totalSize:progress:)` (bao gồm multipart upload cho file lớn).

### Flow 4: Chia sẻ URL Object
- **Public URL (`publicURL(for:)`):** Tạo URL trực tiếp đến object (hỗ trợ cả AWS chuẩn và custom endpoint).
- **Presigned URL (`presignedURL(for:expiresIn:)`):** Tạo URL có chữ ký tạm thời với thời hạn cấu hình được để copy vào clipboard.

---

## 3. Data Models & Contracts
- **`S3Credentials`**: Thông tin xác thực AWS (`accessKeyId`, `secretAccessKey`, `region`, `bucket`, `endpoint`).
- **`S3SessionProtocol`**: Giao diện bất đồng bộ cho toàn bộ thao tác S3, bao gồm `publicURL`, `presignedURL`, `openStreamReader`, `writeStream`.
- **`S3FileRepository`**: Adapter chuyển đổi `S3SessionProtocol` sang `FileRepositoryProtocol`.

---

## 4. Kiến trúc & Entry Points
- **Session:** `S3Session` (`MacSCP/Data/S3/S3Session.swift`).
- **Repository:** `S3FileRepository` (`MacSCP/Data/Repositories/S3FileRepository.swift`).
- **UI Consumer:** `FileBrowserViewModel` (kích hoạt chế độ S3, cung cấp menu Copy Public URL / Copy Presigned URL).

---

## 5. Edge Cases & Xử lý lỗi
| Tình huống | Hành vi mong đợi |
| :--- | :--- |
| Access Denied / Invalid Credentials | Trả về `AppError` rõ ràng, gợi ý kiểm tra quyền IAM (`s3:ListBucket`, `s3:GetObject`, `s3:PutObject`). |
| Bucket không tồn tại hoặc sai Region | Báo lỗi kết nối cụ thể. |
| Rename/Move thư mục có nhiều object | Copy toàn bộ prefix đích trước rồi mới xóa prefix nguồn để tránh mất dữ liệu giữa chừng. |
| Custom Endpoint (MinIO / R2) | Giữ nguyên scheme/host/port của endpoint khi build request và URL. |

---

## 6. Security, Concurrency & Invariants
- Mọi kết nối S3 sử dụng HTTPS (trừ khi người dùng chủ động cấu hình custom endpoint nội bộ).
- Secret Access Key chỉ lưu trong macOS Keychain, không log ra console.

---

## 7. Acceptance Criteria
- [ ] Kết nối thành công với AWS S3 và ít nhất một S3-compatible endpoint (MinIO/R2/Spaces).
- [ ] Duyệt bucket/prefix, upload/download, tạo/xóa/đổi tên/copy file & thư mục hoạt động chính xác.
- [ ] Copy Public URL và Presigned URL hoạt động đúng và mở được object hợp lệ.

---

## 8. Known Gaps & Technical Debt
- ~~**P0 — Force unwrap & Data race:** Force unwrap `s3!` ở `S3Session.swift:64,67` và `S3StreamReader` là `@unchecked Sendable` không lock~~ (Đã xử lý — 2026-11-26: dùng biến local `client` và chuyển `S3StreamReader` sang `actor`).
- **P1 — God Object:** `S3Session.swift` dài 1,249 dòng, cần tách thành path/URL builder, transfer/multipart, và typed error mapper thay vì parse lỗi theo chuỗi `.lowercased()` (`docs/technical-debt.md#2.1`, `#3.3`).
- **P2 — Logging overhead:** `S3Session.log(_:)` tạo `Task { @MainActor ... }` không cần thiết cho từng dòng log (`docs/technical-debt.md#3.3`).
