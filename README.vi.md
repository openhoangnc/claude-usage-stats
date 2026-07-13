[English](README.md) · [日本語](README.ja.md) · **Tiếng Việt** · [中文](README.zh.md)

# Claude Usage Stats

Một ứng dụng nhỏ trên thanh menu macOS hiển thị mức sử dụng Claude Code của bạn
ngay trong tầm mắt — cùng những con số như lệnh `claude /usage`, luôn hiển thị.

- **Dòng trên** — % mức sử dụng **phiên (session)** hiện tại
- **Dòng dưới** — % mức sử dụng **tuần (tất cả mô hình)** hiện tại
- **Nhấp chuột** — một bảng chi tiết với cả ba khung thời gian (phiên, tuần tất cả
  mô hình, và giới hạn tuần của mô hình bạn đang dùng), mỗi khung có một thanh
  tiến trình và một dòng đặt lại (reset) hiển thị giờ địa phương cùng thời gian
  còn lại đến khi đặt lại.

![Ảnh chụp màn hình Claude Usage Stats](screenshot.png)

Hai tỷ lệ phần trăm được **tự động tô màu theo khoảng mức sử dụng**, dùng các màu
đã được kiểm chứng đạt chuẩn **WCAG AAA** (độ tương phản ≥ 7:1) trên cả thanh menu
sáng lẫn tối:

| Khoảng | < 50 | 50–69 | 70–84 | 85–94 | ≥ 95 |
|--------|------|-------|-------|-------|------|
| Màu    | xanh lá | xanh chanh | vàng | cam | đỏ |

## Cài đặt

```bash
curl -fsSL https://raw.githubusercontent.com/openhoangnc/claude-usage-stats/main/install.sh | bash
```

Tải bản phát hành dựng sẵn mới nhất, cài vào `/Applications` và khởi chạy — không
cần Xcode. (Nếu chưa có bản phát hành nào, nó sẽ chuyển sang dựng từ mã nguồn,
việc này cần Xcode command-line tools.) Bật **Launch at Login** (khởi chạy khi
đăng nhập) từ menu (nhấp vào chỉ báo → Launch at Login).

## Gỡ cài đặt

```bash
curl -fsSL https://raw.githubusercontent.com/openhoangnc/claude-usage-stats/main/uninstall.sh | bash
```

## Cách hoạt động

Ứng dụng lấy giới hạn mức sử dụng từ công cụ CLI `claude` cục bộ, ưu tiên nguồn nhẹ nhất
trước:

1. Định vị `claude` trên `PATH` của login shell tương tác (`/bin/zsh -ilc`, để nvm/fnm/volta
   và các prefix tùy chỉnh được phân giải).
2. Chạy `claude -p /usage` (không giao diện). Nếu đầu ra đó đã chứa các thanh giới hạn thì
   phân tích và hiển thị — xong.
3. Nếu không (các phiên bản CLI gần đây đã bỏ các thanh này khỏi đầu ra không giao diện),
   ứng dụng chuyển sang điều khiển màn hình `/usage` tương tác qua một pseudo-terminal, đọc
   các thanh đã hiển thị, rồi thoát trước khi bắt đầu bất kỳ lượt hội thoại nào — nên không
   có gì được lưu xuống đĩa và số liệu sử dụng của bạn không bị ảnh hưởng.

Việc lấy dữ liệu được giới hạn một luồng (không bao giờ có hai tiến trình `claude` cùng lúc),
và khi endpoint sử dụng bị giới hạn tần suất thì được coi là tạm hoãn (back-off), không phải lỗi.

Không cần truy cập Keychain. Ứng dụng không đụng đến thông tin đăng nhập của bạn.

**Lần khởi chạy đầu tiên:** Ứng dụng hoạt động ngay mà không cần quyền bổ sung,
miễn là `claude` đã được cài trên máy và bạn đã đăng nhập.

**Không tìm thấy lệnh:** Nếu lệnh `claude` không khả dụng, ứng dụng hiển thị một
bảng cảnh báo gợi ý cài đặt nó.

## Dựng và cài đặt từ mã nguồn

Muốn tự dựng? Sao chép (clone) kho mã và chạy trình cài đặt. Khi chạy từ một bản
checkout cục bộ, `install.sh` biên dịch mã nguồn hiện tại của bạn thành một tệp
nhị phân universal, cài ứng dụng vào `/Applications` và khởi chạy — không tải gì
về, nên bạn chạy đúng mã đang có trong tay.

```bash
git clone https://github.com/openhoangnc/claude-usage-stats.git
cd claude-usage-stats
./install.sh
```

Sau khi ứng dụng đã chạy, bật **Launch at Login** (khởi chạy khi đăng nhập) từ
menu (nhấp vào chỉ báo → Launch at Login).

## Yêu cầu

- macOS 11 trở lên
- Đã cài Claude CLI (`claude`) trên máy này và đã đăng nhập
- Xcode command-line tools (`swiftc`) để dựng

## Gỡ lỗi

```bash
# In ra những gì thanh menu / bảng sẽ hiển thị, không cần GUI.
./ClaudeUsageStats.app/Contents/MacOS/ClaudeUsageStats --selftest

# Kết xuất lại ảnh chụp màn hình cho README từ các view thật.
./ClaudeUsageStats.app/Contents/MacOS/ClaudeUsageStats --screenshot screenshot.png
```

Việc làm mới chạy mỗi 5 phút và mỗi khi bạn mở menu, và giãn dần khi gặp lỗi liên tiếp.
Phần chân của bảng hiển thị thời điểm dữ liệu được cập nhật lần cuối.
