# 9router Autostart & CLI Control Panel Attach Patch (Linux / systemd)

Giải pháp tự động khởi động **9router** mỗi khi máy chủ Linux reboot qua `systemd`, đồng thời khắc phục triệt để lỗi **tự thoát (`Killed` / `Exiting...`)** hoặc **tự kill/restart server đang chạy** khi gọi lệnh `9router` để mở **CLI Control Panel**.

---

## 📌 Nguyên Nhân Gốc Rễ (Root Causes)

Khi cấu hình `9router` chạy tự động bằng `systemd` trên Linux server (headless / không có GUI), có **3 lỗi trong mã nguồn gốc của `9router`** khiến dịch vụ hoặc lệnh `9router` bị lỗi:

1. **Vòng lặp bắn `SIGKILL` qua lại giữa `9router` CLI và `systemd` (`Restart=always`)**:
   - Trong `cli.js`, mỗi lần người dùng gõ `9router` trên terminal để mở **CLI Control Panel**, `cli.js` luôn gọi `killAllAppProcesses(port)` → bắn `kill -9` (`SIGKILL`) vào tiến trình `9router` đang chạy ngầm của `systemd` (`9router.service`) rồi khởi động lại `next-server` (gây downtime API `:20128`).
   - Đúng **5 giây sau** (`RestartSec=5`), `systemd` phát hiện `9router.service` bị `SIGKILL` nên tự động khởi động lại `9router.service`.
   - Tiến trình `9router.service` mới khởi động lại lập tức chạy `killAllAppProcesses(port)` và **bắn `kill -9` ngược lại vào giao diện `9router` CLI mà người dùng vừa mở**, khiến lệnh `9router` tự thoát (`Killed`) chỉ sau 5 giây.

2. **Tự thoát ngay lập tức khi không có TTY (`src/cli/utils/input.js`)**:
   - Hàm `selectMenu()` có kiểm tra `if (!process.stdin.isTTY) { resolve(-1); return; }`. Khi chạy trong môi trường không có TTY (hoặc systemd service không truyền đủ cả `--skip-update` lẫn `--tray`), `selectMenu` trả về `-1` → `showInterfaceMenu` trả về `"exit"` → in `Exiting...`, tắt server và tự thoát.

3. **Xung đột `npm install --no-save` xoá chéo nhau mỗi lần khởi động**:
   - `~/.9router/runtime/package.json` mặc định chỉ lưu `sql.js`. Mỗi lần `9router` chạy, `ensureSqliteRuntime()` cài `better-sqlite3 --no-save` (làm npm xoá `systray2`), ngay dòng sau `ensureTrayRuntime()` cài `systray2 --no-save` (làm npm xoá ngược lại `better-sqlite3`), làm chậm mọi lần gọi `9router` thêm 3–4 giây.

---

## ⚡ Giải Pháp Của Bản Vá

- **Attach trực tiếp vào server đang chạy (`attachControlPanel`)**:
  - Khi gọi binary `9router`, nếu cổng `20128` đã mở sẵn, `9router` **không gọi `killAllAppProcesses` và không restart `next-server`**, mà kết nối thẳng vào server đang chạy và mở ngay **CLI Control Panel** (`Choose Interface` → `Web UI`, `Terminal UI`, `Hide to Tray`, `Exit`).
  - Khi người dùng chọn `Exit`, `Hide to Tray` hoặc nhấn `Ctrl+C`, chỉ đóng giao diện CLI, giữ nguyên tiến trình `9router` ngầm hoạt động liên tục (0ms downtime).
- **Giữ CLI Control Panel hoạt động trên cả TTY và non-TTY (`input.js`)**:
  - Luôn hiển thị giao diện menu và giữ event loop thay vì trả về `-1` tự thoát.
- **Cố định dependencies trong `~/.9router/runtime/package.json`**:
  - Giữ đồng thời `better-sqlite3`, `sql.js`, `systray2` để khởi động tức thì (~9ms).
- **Bền vững sau khi `reboot` và cả khi `npm i -g 9router@latest`**:
  - Gắn `ExecStartPre` vào `~/.config/systemd/user/9router.service` (kèm `loginctl enable-linger`) và cài wrapper tại `~/.local/bin/9router` & `/usr/local/bin/9router` để tự động áp lại bản vá ngay cả khi nâng cấp package `9router`.

---

## 🚀 Hướng Dẫn Cài Đặt

### Cách 1: Chạy trực tiếp một dòng lệnh (`curl | bash`)
```bash
curl -fsSL https://raw.githubusercontent.com/arcrek/9router-autostart/main/install.sh | bash
```

### Cách 2: Clone repository
```bash
git clone https://github.com/arcrek/9router-autostart.git
cd 9router-autostart
chmod +x install.sh
./install.sh
```

---

## 🧪 Cách Kiểm Tra

1. **Mở CLI Control Panel**:
   ```bash
   9router
   ```
   - Hiển thị ngay bảng điều khiển `Choose Interface` (`Web UI`, `Terminal UI`, `Hide to Tray`, `Exit`).
   - Không tự exit sau 5 giây.
   - Không làm kill hay restart tiến trình `9router` / `next-server` đang chạy ngầm.
2. **Kiểm tra trạng thái service**:
   ```bash
   systemctl --user status 9router.service
   curl -I http://127.0.0.1:20128/
   ```

---

## 📄 License
MIT License.
