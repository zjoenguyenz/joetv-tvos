# FL-358 — CHẨN ĐOÁN CẤP DÒNG CODE: SEEK SỤP VỀ ĐIỂM BẮT ĐẦU SEGMENT

Ngày: 2026-11-21 · Phạm vi: `JoeTV/JoeYtHlsServer.swift` (chính), `JoeYtNativePlayer.swift` / `JoeYtPlayRouter.swift` (kiểm tra loại trừ).
Bằng chứng: code head hiện tại + DiagLog phiên 2.0.46/59 (`~/workspace/user/files/joetv-diag_12.txt`, Bằng Chứng Thép III tập 1, vid `_2mJ96oTdZI`, assembly itag 136+140, dur 2601s) + mục FL-358 trong `~/workspace/fault-library/FAULT-LIBRARY.md`.

---

## 1. KẾT ÁN NGẮN

**Điểm gãy nằm ở `mediaPlaylist` — `JoeYtHlsServer.swift:826-849`.** Playlist media khai
**ĐÚNG MỘT segment cho cả tập**: một `#EXTINF` bằng toàn bộ thời lượng (:841), một
`#EXT-X-BYTERANGE` phủ toàn bộ phần media của file (:842-845), một URI (:846).
Trong HLS, đơn vị tải/seek nhỏ nhất AVPlayer được phép xin là **một segment**. Khi chỉ có
một segment duy nhất phủ cả file, **mọi vị trí tua — dù ở giây 100 hay giây 2.000 — đều
map về cùng một request: byte bắt đầu của segment đó** (video `740`, audio `723` —
tức `initRange.end + 1`, tính tại :839). Server không bao giờ *nhận được* offset của
điểm tua, nên không có đường nào để nó fetch origin tại điểm tua. AVPlayer buộc phải
tải segment tuần tự từ đầu và bò tới điểm tua ở tốc độ dòng chảy thực tế (~1 MB/4 s
trong log) — đó là toàn bộ bệnh: "kéo là load khùng rồi đứng yên".

## 2. KIỂM CHỨNG TỪNG ỨNG VIÊN (theo đúng danh sách được giao)

### (a) "Server phục vụ một file tuần tự / ống producer–consumer không có truy cập ngẫu nhiên" — **ĐÚNG Ở TẦNG PLAYLIST, SAI Ở TẦNG RELAY**

- Relay **có** truy cập ngẫu nhiên đầy đủ và đã dùng nó: `handle` parse Range header
  (`JoeYtHlsServer.swift:700-712`), `originEvents` gắn nguyên văn Range đó lên request
  origin (:941-942), `relay` chuyển nguyên văn Content-Length/Content-Range của origin
  về (:1150-1165 vùng head). Log chứng minh origin trả 206 đúng offset được xin
  (`serve-head … range=bytes 740-343134550/343134551`).
- Cái "tuần tự duy nhất" là **hình dạng playlist** (một segment), không phải ống relay.
  Producer/consumer (`originEvents`, :908-1007) chỉ chảy xuôi cho *một request đã cho* —
  đúng thiết kế của một range relay; nó không phải nơi offset bị mất.

### (b) "Range header được parse nhưng bị map lên dòng tuần tự" — **MINH OAN**

Range được chuyển nguyên văn 1:1 lên origin (:941-942) và head của origin được chuyển
nguyên văn về. Không có chỗ nào trong `handle`/`relay` viết lại offset thành 0 hay
thành điểm bắt đầu segment. Bằng chứng log: AVPlayer xin `bytes=740-343134550` thì
origin head trả đúng `Content-Range: bytes 740-343134550/343134551`.

### (c) "Playlist không có EXT-X-BYTERANGE / segment là cả file" — **NỬA ĐẦU SAI, NỬA SAU LÀ KẾT ÁN**

Playlist **có** EXT-X-BYTERANGE (:844) và có EXT-X-MAP (:838) — nhưng BYTERANGE đó là
**một** dải duy nhất dài `contentLength − segmentStart` (video: 343.133.811 byte).
Chính con số này là điểm gãy: một segment = một đơn vị seek, và đơn vị đó là cả tập.

### (d) "Content-length/range handling khởi động lại producer ở mỗi kết nối mới" — **ĐÚNG NHƯNG LÀ HỆ QUẢ, KHÔNG PHẢI NGUYÊN NHÂN**

Mỗi request mới đúng là một `originEvents` mới (`relay`, :1119-1124) với bộ đếm producer
reset — nhưng nó fetch **tại đúng offset AVPlayer xin** (740), không phải byte 0 của file.
FL-358 ghi "producer khởi động lại từ byte 0" — chính xác hoá ở mức dòng: bộ đếm *byte
đã nhận* reset về 0, còn *offset fetch* là 740 (điểm bắt đầu segment), theo dòng
serve-head trong log. Kết án kiến trúc của FL-358 đứng vững ở kết luận ("không có đường
truy cập ngẫu nhiên theo byte cho seek"), nhưng cơ chế chính xác là: **đường truy cập
ngẫu nhiên tồn tại ở relay, nhưng playlist không bao giờ cho AVPlayer cơ hội dùng nó
vượt quá điểm bắt đầu segment.**

## 3. DÒNG LOG KHỚP CƠ CHẾ THẾ NÀO (diag_12)

- Phát thẳng: AVPlayer xin `bytes=0-343134550` (cả file gồm init) lúc 12:31:40.661 —
  chảy đều ~1 MB/4 s, first frame 18.264 ms… (mốc 12:31:58.806), pos chạy bình thường.
- Tua lần 1 (12:32:10.191): kết nối đang phát bị đóng (`serve-done … bytes=7375813 …
  outcome=client đóng kết nối`) và request mới là `bytes=740-343134550` (video) /
  `bytes=723-42108340` (audio) — **điểm bắt đầu segment, không phải offset điểm tua**.
  740 = `videoInitRange.end + 1`; 723 = audio tương ứng. Đây là chữ ký của playlist
  một-segment: AVPlayer chỉ còn một chỗ hợp lệ duy nhất để bắt đầu lại.
- Sau đó AVPlayer lặp lại **y hệt** request `bytes=740-…` nhiều lần (12:32:26 ×5+,
  12:34:06): phần lớn chết sau đúng **32.948 byte** — đúng chunk đầu tiên của producer
  (ngưỡng chunk đầu 32 KB, `originEvents` :979-980, cộng phần tràn block mạng) — trong
  khi một request sống sót chảy tuần tự ~1 MB/4 s (serve-done 12:34:07:
  `bytes=25470787 ms=100054`). Đọc theo cơ chế: AVPlayer nhận đầu segment (gồm sidx +
  fragment đầu) rồi huỷ và xin lại từ đầu segment, vì trong một segment BYTERANGE duy
  nhất nó không có điểm vào byte-range nào khác cho vị trí tua; request sống sót phải
  *bò* từ byte 740 tới điểm tua ở ~250 KB/s ⇒ không bao giờ tới kịp. Tiến độ lưu lúc
  12:34:14 vẫn `pos=80s` — khớp "đứng yên".
  (Phần diễn giải hành vi nội bộ của AVPlayer là **suy luận từ mẫu log**; phần kết án
  phía server — playlist một segment ⇒ request tua chỉ có thể bắt đầu ở 740/723 — là
  sự thật đọc trực tiếp từ code + log.)
- Tua lần 2 (12:34:06.762) lặp lại nguyên mẫu — bệnh cấu trúc, không phải mạng.

## 4. LOẠI TRỪ HAI FILE CÒN LẠI

- `JoeYtNativePlayer.swift`: seek là seek gốc của AVPlayerViewController (header
  :23-27 — Right/Left là native seek, không press nào bị model tiêu thụ); các
  `player.seek` trong model (:985, :1106, :1216) chỉ là seek về checkpoint/duration
  của chính AVPlayer — chúng đi qua cùng đường HLS và cùng gặp playlist một-segment.
  Không dòng nào trong model/router dịch thời-gian-tua thành byte hay chặn nó.
- `JoeYtPlayRouter.swift`: không chứa xử lý seek/Range nào (grep seek|Range = 0 kết quả
  liên quan) — chỉ định tuyến resolve → player.
⇒ Điểm sửa duy nhất: `JoeYtHlsServer.swift`, tại `mediaPlaylist` + dữ liệu segment nó cần.

## 5. HƯỚNG SỬA (đã thực hiện ở bước 2, cùng file)

Khai playlist theo **đoạn fragment thật của file fMP4**: đọc hộp `sidx` của chính origin
(nằm ngay sau init range — vị trí `segmentStart`; kiểm chứng bằng type box `sidx`, sai
thì bỏ) tại lúc `makeSession`, parse các referenced subsegment (offset / size /
duration theo timescale — ISO/IEC 14496-12 sidx v0/v1), và `mediaPlaylist` phát một
`#EXTINF` + `#EXT-X-BYTERANGE` **cho từng đoạn**. Khi đó AVPlayer tua tới thời gian T
thì xin đúng đoạn chứa T (`bytes=<offset đoạn>-…`), và relay — vốn đã chuyển Range
nguyên văn — fetch origin **tại đúng offset đó** (206). sidx không đọc/parse được ⇒
playlist giữ nguyên hình một-segment như hiện nay (phát thẳng không đổi một byte).
Relay, producer, resume — không đụng.


---

## 6. ĐÍNH CHÍNH — LỖI LAYOUT SIDX [SIDX-LAYOUT] (gate review, 2026-11-21)

**Lỗi:** bản đầu của `parseSidx` (trong `JoeYtHlsServer.swift`) bỏ qua trường
`earliest_presentation_time` (EPT) trong layout hộp sidx (ISO/IEC 14496-12), nên mọi
trường sau `timescale` bị đọc sớm một trường: v0 đọc `first_offset` tại @20 (thực ra là
EPT), `reference_count` tại @26, entries bắt đầu tại 28; v1 đọc `first_offset` tại @20
(EPT 64-bit), `reference_count` tại @30, entries tại 32. Trên file thật EPT và
first_offset thường đều bằng 0 nên count đọc sai thành 0, guard `referenceCount >= 2`
rớt, parser trả nil và playlist theo đoạn không bao giờ kích hoạt (seek quay về hình
một-segment). Comment probe ở `fetchSegmentIndex` cũng sai khi nói 32 byte đủ cho cả
hai version — v1 cần 40 byte mới tới được `reference_count`; đường fetch full-box che
lỗi này.

**Đã sửa (chỉ `JoeYtHlsServer.swift`):** offsets đúng — v0: `first_offset` u32@24,
`reference_count` u16@30, entriesStart 32 (header 32 byte); v1: `first_offset` u64@28,
`reference_count` u16@38, entriesStart 40 (header 40 byte). Guard cỡ tối thiểu theo
version (v0 ≥ 32, v1 ≥ 40) ở cả `parseSidx` và guard `boxSize` trong
`fetchSegmentIndex`; probe nay fetch 40 byte và comment đã sửa. Các fix signedness/
overflow trước đó giữ nguyên (u64 trả UInt64, v1 first_offset > Int64.max bị loại,
cursor đầu được kiểm bằng `addingReportingOverflow` trên first_offset THẬT), và hợp
đồng fallback không đổi: index không hợp lệ ⇒ nil ⇒ segments rỗng ⇒ playlist
một-segment legacy.
