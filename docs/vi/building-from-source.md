# Build từ mã nguồn

[English](../en/building-from-source.md) · [Tiếng Việt](building-from-source.md)

Trang này hướng dẫn build thư viện, chạy kiểm tra và tìm mã nguồn theo chức năng. Chỉ cần build khi sửa engine hoặc tùy chỉnh profile; package npm đã có binary sẵn.

## Yêu cầu

- **Zig 0.17.x** (phát triển với 0.17.1). Không cần khi chỉ dùng package.
- **Node.js ≥ 20** cho script build (nó chạy `wasm-opt`), benchmark và playground.
- `wasm-opt` từ binaryen: được cài bằng `npm install` ở thư mục gốc repository (dev dependency
  `binaryen`) hoặc trong `bench/`. Nếu thiếu, script build sẽ cảnh báo và xuất binary chưa tối ưu.

Script build tìm Zig qua biến môi trường `ZIG`, nếu không có thì dùng `zig` trên `PATH`.

## Các lệnh

```sh
npm install                        # root dev dependency: binaryen (wasm-opt)

node scripts/build.mjs             # core + standard + full + pdf + WOFF add-on: zig build (optimize=small) + wasm-opt -Oz
node scripts/build.mjs --profile=core          # one profile (core | standard | full | pdf)
node scripts/build.mjs -- -Dtables=false       # extra zig options for every profile (marked "custom" in the manifest)
node scripts/build.mjs --manifest  # rewrite js/build-manifest.json from the wasm files in js/
node scripts/build.mjs --verify    # check js/*.wasm against the manifest (run by prepublishOnly)
node scripts/build.mjs --test      # zig build test (also: npm test)
```

Đầu ra: `js/bm_render.core.wasm`, `js/bm_render.standard.wasm`, `js/bm_render.wasm` (full),
`js/bm_render.pdf.wasm` (full + đầu ra PDF), `js/bm_woff.wasm`, `zig-out/bin/bm_render.wasm` (full, đã tối ưu), `js/build-manifest.json` (profile,
kích thước, sha256 và bit tính năng của từng file) và một bảng kích thước ghi vào `bench/out/sizes.json`.

Lệnh Zig trực tiếp:

```sh
zig build                                   # full profile, optimize=small -> zig-out/bin/bm_render.wasm (+ bm_woff.wasm)
zig build -Dprofile=standard -Dcss=false    # any profile + single-feature flags
zig build -Dwasm-optimize=safe -Dstrip=false  # safety-checked build (for fuzzing / debugging)
zig build addons                            # only the add-on modules
zig build test --summary all                # native unit tests of every module
```

Tùy chọn: `-Dprofile=core|standard|full|pdf`, mỗi tính năng một cờ `-D<feature>=true|false` (danh sách ở
[Profile và kích thước](profiles-and-size.md#build-tùy-biến)), `-Dwasm-optimize=small|fast|safe|debug`,
`-Dstrip=false`, `-Dstack-kib=<n>` (shadow stack, mặc định 1024).

Trong một bản checkout mã nguồn, `import "bm-render"` trỏ về repository (hoặc import thẳng `js/node.mjs`)
sẽ ưu tiên file `zig-out/bin/bm_render.wasm` vừa build hơn file `js/bm_render.wasm` đóng gói sẵn.
`BM_WASM=<path>` nạp một binary bất kỳ.

## Kiểm thử

| Nội dung | Lệnh | Ghi chú |
|:--|:--|:--|
| Unit test (native, mọi module) | `zig build test --summary all` | dữ liệu test nằm cạnh từng module trong `testdata/` |
| Một module | `zig test src/<module>/<module>.zig` | module import module anh em được test qua một file gốc `src/test_*.zig` |
| Smoke test package | `npm run test:pack` | `scripts/pack-test.mjs`: đóng gói tarball npm rồi import nó |
| Thăm dò tính năng theo profile | `node bench/probe/profiles.mjs` | mỗi binary xử lý đầu vào của tính năng bị thiếu ra sao; thất bại nếu có trap |
| Trình duyệt thật | `cd bench && npm run browser:quick` | Edge / Chrome headless qua puppeteer-core; đầu ra raw phải trùng với Node |
| Fuzz (toàn pipeline) | xem bên dưới | chạy trên bản build có kiểm tra an toàn |
| Fuzz (parser, bộ giải mã) | `zig build test -Dtest-filter="fuzz: png" --fuzz=200K` | dẫn hướng theo độ phủ; xem [Fuzz các bộ phân tích cú pháp](#fuzz-các-bộ-phân-tích-cú-pháp) |

Fuzz toàn pipeline bằng cây node ngẫu nhiên trên bản ReleaseSafe (vi phạm an toàn sẽ thành trap của
wasm thay vì âm thầm làm hỏng bộ nhớ):

```sh
zig build -Dwasm-optimize=safe -Dstrip=false -p /tmp/bmsafe
cd bench
BM_WASM=/tmp/bmsafe/bin/bm_render.wasm node probe/fuzz.mjs 1 3000   # seed, iterations
```

### Fuzz các bộ phân tích cú pháp

`src/fuzz.zig` có một target `std.testing.fuzz` cho mỗi thành phần đọc dữ liệu không tin cậy: `png`,
`jpeg`, `gif`, `webp` (giải mã + duyệt các khung hình động), `inflate`, `brotli`, `woff` (WOFF/WOFF2
+ font giải mã ra), `font` (TrueType / CFF / collection: metric, outline, shaping), `html`, `css`
(parser, selector, cascade), `json`, `svg` (parse + render ra 64x64), `render_html` và
`render_json` (toàn bộ renderer trên canvas 64x64). Dữ liệu mồi (seed) lấy từ các thư mục
`testdata/` (cùng `src/testdata/fuzz/`).

`zig build test` thông thường chạy mỗi target một lần cho mỗi seed (tổng cộng chưa tới một giây).
Để fuzz một target bằng fuzzer dẫn hướng theo độ phủ của Zig (không có CI nào chạy việc này):

```sh
zig build test -Dtest-filter="fuzz: png" --fuzz=200K   # số lần lặp; bỏ con số để mở web UI
```

Lỗi được tính là: panic, vi phạm kiểm tra an toàn, rò rỉ bộ nhớ, hoặc một đầu vào chạy quá 8 giây
(bản Debug; lỗi `SlowInput`). Lỗi do parser trả về là bình thường và bị bỏ qua. Bộ nhớ cho mỗi đầu
vào bị giới hạn 512 MiB (`error.OutOfMemory`, không phải crash). Đầu vào gây lỗi được lưu vào
`.zig-cache/f/crash`: 4 byte đầu là tiền tố độ dài, phần còn lại là đầu vào. Bỏ 4 byte đó, lưu đầu
vào vào `src/testdata/fuzz/regress/` và thêm vào bảng `regressions` trong `src/fuzz.zig` cùng với
bản sửa. Corpus mà một lần chạy tạo ra được giữ trong `.zig-cache/f/` và dùng lại ở lần sau. Mỗi
lệnh chỉ nên fuzz một target: hai lần chạy `--fuzz` trong cùng một bản checkout dùng chung cache đó.

`zig build fuzz` là bộ đột biến (mutation driver) tất định cho cùng các target (ReleaseSafe, không
cần runtime fuzzing). Các phép đột biến của nó lặp một đoạn byte tới hàng nghìn lần, nhờ vậy tìm ra
các trường hợp chạy bậc hai hoặc cấp phát bùng nổ mà fuzz dẫn hướng theo độ phủ hiếm khi chạm tới:

```sh
zig build fuzz -- all --seconds 60                  # mọi target, mỗi target 60 giây (seed mặc định 1)
zig build fuzz -- font css --seconds 300 --slow-ms 200 --seed 7
zig build fuzz -- font --replay path/to/input.bin   # chạy lại một đầu vào, in thời gian chạy
```

Đầu vào chạy lâu hơn `--slow-ms` (mặc định 1000) được lưu thành `zig-out/fuzz/slow-<target>-<n>.bin`;
khi panic hoặc treo (20 giây), đầu vào được lưu thành `zig-out/fuzz/crash-<target>.bin` (Linux).

## Kiểm tra kết quả

Xem [Benchmark](benchmark.md) để thiết lập và chạy các phép so sánh. Các ví dụ trong `docs/examples/` kiểm tra hành vi API được mô tả trong hướng dẫn.

## Cấu trúc mã nguồn

| Thư mục | Nội dung |
|:--|:--|
| `src/` | Layout, chữ, vẽ, codec và PDF |
| `js/` | API JavaScript, khai báo kiểu và WebAssembly |
| `scripts/` | Build và kiểm tra package |
| `bench/` | Fixture, đo hiệu năng và kiểm tra kết quả |
| `docs/` | Hướng dẫn, ví dụ và trang tài liệu |

## Trang tài liệu

`docs/` đồng thời là một trang [VitePress](https://vitepress.dev/) (cấu hình ở `docs/.vitepress/`) có nhúng
playground. Cần Node.js ≥ 18 và `npm install` ở thư mục gốc repository, nhưng không cần Zig: trang dùng các
tệp `js/*.wasm` đã build sẵn.

```sh
npm run docs:dev        # = npm run docs; build playground vào docs/public/playground-app, server phát triển ở :5173
npm run docs:build      # trang tĩnh trong docs/.vitepress/dist
npm run docs:preview    # phục vụ bản build ở :4173
```

`vercel.json` ở thư mục gốc repository triển khai trang lên Vercel (import repository; không cần thiết lập
hay biến môi trường nào).

## Tài liệu cho nhà phát triển

- [ARCHITECTURE.md](../ARCHITECTURE.md): thiết kế, sơ đồ module, pipeline render, ABI của wasm.
- [CONVENTIONS.md](../CONVENTIONS.md): quy tắc kỹ thuật (không `std.Io` / libc trong mã thư viện, kỷ luật
  với đầu vào không tin cậy, kỷ luật kích thước, quyền sở hữu file).
- [BENCHMARK.md](../BENCHMARK.md), [RESULTS_FULL.md](../RESULTS_FULL.md), [results.json](../results.json):
  số liệu đo.

## Đóng góp

- Đọc [CONVENTIONS.md](../CONVENTIONS.md) trước: mã thư viện nhận allocator tường minh, không bao giờ
  trap với đầu vào không tin cậy (kiểm tra biên, không `unreachable`, đệ quy có giới hạn: shadow stack của
  wasm chỉ 1 MiB), và báo cáo chi phí kích thước wasm của mình.
- Mọi tính năng tùy chọn phải được bảo vệ bằng một cờ trong `src/config.zig` để có thể loại khỏi các
  profile nhỏ; chạy `node bench/probe/profiles.mjs` sau khi động vào ranh giới tính năng.
- Khi đổi hành vi render, thêm fixture tái hiện và chạy kiểm tra tương ứng. Xem [Benchmark](benchmark.md) để đo lại kết quả.
