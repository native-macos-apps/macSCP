---
id: SPEC-XX
title: <Tên tính năng>
status: draft # draft | active | deprecated
last_updated: YYYY-MM-DD
related_files:
  - MacSCP/...
related_debt: [] # Tham chiếu mục trong docs/technical-debt.md (vd: TD-1.1)
---

# SPEC-XX: <Tên tính năng>

## 1. Tổng quan & Mục tiêu
Mô tả ngắn gọn bài toán người dùng cần giải quyết, giá trị mang lại và phạm vi (in-scope / out-of-scope).

## 2. User Flows & Hành vi chính
Liệt kê từng luồng thao tác chính từ góc nhìn người dùng (trigger → hệ thống xử lý → kết quả UI/state).

### Flow 1: <Tên luồng>
1. ...
2. ...

## 3. Data Models & Contracts
Liệt kê các Domain Models, Protocols, Persistence Entities hoặc Settings keys liên quan.

## 4. Kiến trúc & Entry Points
- **Views / Windows:** ...
- **ViewModels:** ...
- **Services / Repositories:** ...

## 5. Edge Cases & Xử lý lỗi
| Tình huống | Hành vi mong đợi | Error / State |
| :--- | :--- | :--- |
| ... | ... | ... |

## 6. Security, Concurrency & Invariants
Những bất biến (invariants) không được phép phá vỡ khi AI/dev chỉnh sửa tính năng này:
- ...

## 7. Acceptance Criteria
- [ ] ...
- [ ] ...

## 8. Known Gaps & Technical Debt
Tham chiếu các mục liên quan trong `docs/technical-debt.md` hoặc phần chưa hoàn thiện.
