# Xử lý nợ kỹ thuật từ review ngày 2026-11-27

- **Phạm vi** — 9 mục của [báo cáo review](../technical-debt.md#các-khoản-nợ-mở-ngày-2026-11-27).
- **Spec liên quan** — SPEC-00, SPEC-01, SPEC-02, SPEC-04, SPEC-05, SPEC-06 và SPEC-07.
- **Baseline** — bản review tại `c453374`, ghi vào repo ở `447a614`. Xcode 27.2 chạy 176 unit test, một test scanner local thất bại ở hai assertion.

## Công việc và tiêu chí nghiệm thu

- [x] **P0 — Đích local.** Chuẩn bị bản thay thế trên cùng volume, chỉ đưa vào vị trí đích sau khi ghi hoặc copy hoàn tất. Lỗi nguồn và hủy giữ nguyên đích cũ. Kiểm thử cả đích hiện có, đích mới và copy thư mục.
- [x] **P0 — Editor.** Ghi một snapshot và chỉ cập nhật bản đã lưu bằng snapshot đó. Điều phối Save/Reload đang chạy và chỉ đóng khi lưu thành công và buffer sạch. Kiểm thử chỉnh sửa trong khi chờ ghi.
- [x] **P1/P2 — Scanner và batch.** Hai entry point lập một manifest trước khi chạy worker pool. Duyệt local đồng bộ ngoài MainActor, tính đường dẫn theo thành phần đã chuẩn hóa, báo lỗi thư mục nguồn kèm đường dẫn và dừng trước khi ghi đích nếu quét thất bại. Kiểm thử batch lớn, alias, trùng tên giữa hai nhánh, lỗi thư mục và hủy.
- [x] **P1 — S3.** Kiểm tra lỗi theo key của mọi trang xóa, kể cả marker. Xóa, đổi tên và di chuyển nhận lỗi khi nguồn chỉ bị xóa một phần.
- [x] **P1 — SwiftData và Keychain.** Lưu snapshot credential trước thao tác, thực hiện thay đổi Keychain trước SwiftData và khôi phục credential nếu SwiftData thất bại. Hiển thị cả lỗi bù trừ nếu khôi phục thất bại. Kiểm thử lỗi tại cả hai kho.
- [x] **P2 — CI.** Thêm workflow chạy target `macSCPTests` trên pull request và push vào `main`.
- [x] **Xác minh.** Xcode 27.2 chạy 189/189 unit test đạt. Scanner qua kiểm tra kiểu Swift 6 riêng. `git diff --check`, kiểm tra YAML và GitNexus detect-changes đã chạy. S3 và lỗi persistence được kiểm thử qua mock. Workflow GitHub Actions đã được kiểm tra ở workspace.

## Phạm vi ảnh hưởng từ GitNexus

| Thay đổi | Mức | Caller và luồng cần kiểm thử |
| --- | --- | --- |
| Ghi đích local | LOW cho stream, UNKNOWN cho overload copy | Commander và stream engine, Browser upload/download, Finder file promise. Các overload được gọi động qua `FileRepositoryProtocol`. |
| Editor Save/Reload | HIGH | Editor view, header, status bar và xác nhận đóng cửa sổ. |
| Scanner | HIGH cho kiểu dữ liệu và đệ quy remote, LOW cho hai entry point | Upload từ Browser và transfer giữa các pane trong Commander. |
| Xóa và copy thư mục S3 | CRITICAL cho xóa, HIGH cho copy | Xóa, đổi tên và dán khi di chuyển object. |
| Thay đổi kết nối | HIGH cho CRUD, CRITICAL cho helper Keychain chung | Workspace, connection list, server pane, luồng duplicate và lưu SSH key. |

Trong luồng S3, đã chặn thêm thao tác lên object trùng hoặc prefix chồng lấn trước bước copy/xóa. Giới hạn khôi phục khi tiến trình bị dừng giữa hai lần ghi và việc chuyển cả target sang Swift 6 được ghi trong [báo cáo nợ kỹ thuật](../technical-debt.md#phát-hiện-khi-triển-khai).
