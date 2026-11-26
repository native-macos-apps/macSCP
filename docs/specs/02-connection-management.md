---
id: SPEC-02
title: Quản lý Kết nối & Thư mục (Connection & Folder Management)
status: active
last_updated: 2026-11-26
related_files:
  - MacSCP/Domain/Models/Connection.swift
  - MacSCP/Domain/Models/Folder.swift
  - MacSCP/Domain/Models/ConnectionType.swift
  - MacSCP/Domain/Models/AuthMethod.swift
  - MacSCP/Data/Repositories/ConnectionRepository.swift
  - MacSCP/Data/Repositories/FolderRepository.swift
  - MacSCP/Data/Keychain/KeychainService.swift
  - MacSCP/Features/Connections/ConnectionListViewModel.swift
  - MacSCP/Features/Connections/ConnectionListView.swift
  - MacSCP/Features/Connections/Components/ConnectionFormSheet.swift
  - MacSCP/Features/Connections/Components/PasswordPromptSheet.swift
related_debt:
  - docs/technical-debt.md#31-trùng-lặp-mã-nguồn-dry-violations
---

# SPEC-02: Quản lý Kết nối & Thư mục

## 1. Tổng quan & Mục tiêu
Cho phép người dùng tạo, lưu trữ, phân loại, tìm kiếm và kết nối nhanh đến các máy chủ **SFTP** và kho lưu trữ **Amazon S3 / S3-compatible**, đảm bảo thông tin nhạy cảm (password, AWS secret access key) được lưu an toàn trong macOS Keychain.

---

## 2. User Flows & Hành vi chính

### Flow 1: Tạo / Chỉnh sửa Connection (`ConnectionFormSheet`)
1. Người dùng mở sheet tạo mới (`Cmd+N` hoặc nút `+`) hoặc chọn chỉnh sửa một kết nối sẵn có.
2. Chọn loại kết nối (`ConnectionType`: `.sftp` hoặc `.s3`).
3. Điền thông tin:
   - **Chung:** `name`, `iconName` (SF Symbols qua `IconSelectorView`), `folderId`, `description`, `tags`.
   - **SFTP:** `host`, `port` (mặc định `22`, hợp lệ `1...65535`), `username`, `authMethod` (`.password` hoặc `.privateKey`).
     - Nếu `.password`: nhập mật khẩu và tùy chọn `savePassword` (lưu vào Keychain).
     - Nếu `.privateKey`: chọn khóa từ danh sách In-App SSH Keys (`sshKeyId`), có nút "Import Key…" ngay trong form.
   - **S3:** `username` (Access Key ID), Secret Access Key (lưu Keychain), `s3Region`, `s3Bucket` (tùy chọn; để trống để duyệt danh sách bucket), `s3Endpoint` (tùy chọn cho MinIO, R2, DigitalOcean Spaces…).
4. Validate dữ liệu (`Connection.isValid` / `validationErrors`), lưu `ConnectionEntity` vào SwiftData qua `ConnectionRepository` và lưu credentials (nếu có) vào `KeychainService`.

### Flow 2: Tổ chức bằng Folder & Tìm kiếm
- Tạo, đổi tên, xóa `Folder` (`Cmd+Shift+N`); hỗ trợ kéo-thả `Connection` (`Transferable` với UTType `com.macnev2013.macSCP.connection`) vào thư mục.
- Lọc theo `SidebarSelection` (`.allConnections` hoặc `.folder(UUID)`).
- Tìm kiếm realtime (`searchText`) theo `name`, `host`, và `username` (case-insensitive).
- Hiển thị bộ đếm số lượng kết nối tổng và theo từng thư mục.

### Flow 3: Kết nối & Xác thực trước khi mở phiên
1. Nếu `AppLockManager.lockBeforeConnection` bật, yêu cầu xác thực sinh trắc học trước (`authenticateForConnection()`).
2. Với SFTP `.password`: nếu không lưu password trong Keychain (`savePassword == false` hoặc chưa có), hiển thị `PasswordPromptSheet`.
3. Với SFTP `.privateKey`: đọc private key từ `SSHKeyStorageService` theo `sshKeyId`.
4. Với S3: đọc `secretAccessKey` từ `KeychainService`.

---

## 3. Data Models & Contracts

### `Connection` (`MacSCP/Domain/Models/Connection.swift`)
- `id: UUID`, `name: String`, `host: String`, `port: Int` (default `22`), `username: String`
- `authMethod: AuthMethod` (`.password` | `.privateKey`), `sshKeyId: UUID?`, `savePassword: Bool`
- `description: String?`, `tags: [String]`, `iconName: String`, `folderId: UUID?`
- `connectionType: ConnectionType` (`.sftp` | `.s3` | `.local`)
- `s3Region: String?`, `s3Bucket: String?`, `s3Endpoint: String?`
- `createdAt: Date`, `updatedAt: Date`

### Validation Rules (`Connection.isValid`)
- **SFTP:** `!name.isBlank && !host.isBlank && !username.isBlank && (1...65535).contains(port) && (authMethod == .password || sshKeyId != nil)`
- **S3:** `!name.isBlank && !username.isBlank`
- **Local:** luôn hợp lệ.

### Persistence & Keychain
- SwiftData Entities: `ConnectionEntity`, `FolderEntity` (ánh xạ qua `ConnectionMapper`, `FolderMapper`).
- Keychain: `KeychainServiceProtocol` lưu mật khẩu SFTP và S3 Credentials tách biệt khỏi SwiftData.

---

## 4. Kiến trúc & Entry Points
- **Views:** `ConnectionListView`, `ConnectionListColumn`, `ConnectionRowView`, `ConnectionDetailView`, `SidebarView`, `ConnectionFormSheet`, `PasswordPromptSheet`, `IconSelectorView`, `CommanderServersPaneView`.
- **ViewModel:** `ConnectionListViewModel` (`@MainActor @Observable`).
- **Repositories:** `ConnectionRepositoryProtocol` (`ConnectionRepository`), `FolderRepositoryProtocol` (`FolderRepository`), `KeychainServiceProtocol` (`KeychainService`).

---

## 5. Edge Cases & Xử lý lỗi
| Tình huống | Hành vi mong đợi |
| :--- | :--- |
| Xóa Folder đang chứa Connection | Các connection trong folder cần được xử lý an toàn (chuyển về unfoldered / không mất dữ liệu) và cập nhật UI. |
| Xóa Connection | Xóa cả bản ghi SwiftData lẫn credential tương ứng trong Keychain. |
| Connection trỏ tới `sshKeyId` đã bị xóa khỏi Keychain | Báo lỗi rõ ràng khi kết nối, yêu cầu chọn lại SSH key mới. |
| SFTP dùng port khác 22 | `displayHost` hiển thị `host:port`; port 22 chỉ hiển thị `host`. |

---

## 6. Security & Invariants
- **Không bao giờ** lưu password hoặc AWS Secret Access Key vào SwiftData hoặc `UserDefaults`.
- **Không còn hỗ trợ `privateKeyPath` legacy** (đã loại bỏ theo `docs/plans/2026110502-remove-legacy-private-key-path.md`); mọi SSH key phải đi qua `sshKeyId` + `SSHKeyStorageService`.

---

## 7. Acceptance Criteria
- [ ] Tạo, sửa, xóa kết nối SFTP (password / SSH key) và S3 hoạt động đầy đủ và lưu bền vững qua các lần khởi động lại app.
- [ ] Tạo, đổi tên, xóa folder và lọc/tìm kiếm kết nối chính xác.
- [ ] Credential được lưu/xóa đồng bộ trong macOS Keychain.

---

## 8. Known Gaps & Technical Debt
- ~~`KeychainService.swift` đang trùng lặp boilerplate CRUD giữa Password và S3 Credentials~~ (Đã xử lý — 2026-11-26: gom vào `KeychainStore` dùng chung với `SSHKeyStorageService`).
