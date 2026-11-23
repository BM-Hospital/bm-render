# Xử lý sự cố và câu hỏi thường gặp

[English](../en/troubleshooting.md) · [Tiếng Việt](troubleshooting.md)

Những triệu chứng bạn dễ gặp với bm-render, nguyên nhân và cách khắc phục. Phần lớn xuất phát từ
hai mặc định của thư viện (`display` mặc định là `inline`; đầu vào không bao giờ được tải
về) và một quyết định riêng của bm-render (không kèm font).

- [Chữ không hiện, hoặc hiện thành ô vuông](#chữ-không-hiện-hoặc-hiện-thành-ô-vuông)
- [Khối chứa bị co về chiều cao 0](#khối-chứa-bị-co-về-chiều-cao-0)
- ["this build has no ... support"](#this-build-has-no--support)
- [Ảnh không hiện](#ảnh-không-hiện)
- [Không tìm thấy file .wasm (bundler, worker)](#không-tìm-thấy-file-wasm)
- [Addon native (Node.js)](#addon-native-nodejs)
- [Bộ nhớ tăng mãi](#bộ-nhớ-tăng-mãi)
- [Ảnh bị mờ trên màn hình DPI cao](#ảnh-bị-mờ-trên-màn-hình-dpi-cao)
- [Tiếng Việt](#tiếng-việt)
- [Emoji không có màu](#emoji-không-có-màu)
- [Một style bị bỏ qua](#một-style-bị-bỏ-qua)
- ["invalid value for style property"](#invalid-value-for-style-property)
- [Các lỗi khác](#các-lỗi-khác)

## Chữ không hiện, hoặc hiện thành ô vuông

- **Hoàn toàn không vẽ gì**: chưa có font nào được đăng ký trên `Renderer` này (hoặc đã gọi
  `clearFonts()`). bm-render không kèm font và không bao giờ đọc font hệ thống. Hãy đăng ký một font:
  `renderer.registerFont(readFileSync("Inter-Regular.ttf"))`. Font được giữ riêng theo từng renderer.
- **Một số ký tự thành ô vuông (tofu)**: không font nào đã đăng ký chứa các ký tự đó; chúng được vẽ bằng
  glyph `.notdef`. Hãy đăng ký font phủ hệ chữ đó (ví dụ Noto Sans JP cho tiếng Nhật). Font dự phòng vốn
  đã duyệt mọi family đã đăng ký theo thứ tự đăng ký (kể cả khi bạn truyền `fontFamilies`, tùy chọn này
  chỉ đặt bộ font gốc).
- **Sai font**: tên family dùng trong `fontFamily` phải trùng với tên đã đăng ký — tức `name` bạn truyền
  vào, hoặc tên family của chính font (`registerFont` trả về tên này).
- **Font `.woff2` / `.otf` ném lỗi**: `core` không có WOFF và CFF; dùng `standard` / `full`, hoặc add-on
  WOFF cho WOFF (outline CFF vẫn cần `standard`).

## Khối chứa bị co về chiều cao 0

`display` mặc định là `inline` cho mọi node. Một container inline bỏ qua
`width` / `height`, nên hai con có kích thước bên trong một block container sẽ nằm trên một dòng rỗng:

```js
r.measureSync({ type: "container", style: { display: "block" }, children: [
  { type: "container", style: { width: 50, height: 50 } },
  { type: "container", style: { width: 50, height: 50 } },
] }, { width: 200, height: 200 });
// -> { width: 200, height: 0, ... }
```

Hãy đặt `display: "flex"`, `"block"` hoặc `"grid"` tường minh cho các container. Con của flex hoặc grid
container được blockify tự động, nên chỉ chính các container cần đặt. Node chữ trong flex container
không cần gì thêm.

## "this build has no ... support"

Profile đang nạp không có tính năng đó. Các thông báo và profile nhỏ nhất có tính năng:

| Thông báo (tiền tố `bm-render: `) | Cần |
|:--|:--|
| `this build has no HTML input support` | `standard` |
| `this build has no stylesheet (\`css\` option) support` | `standard` |
| `Tailwind (\`tw\`) is not supported by this build` | `standard` |
| `this build has no WOFF/WOFF2 font support` | `standard`, hoặc `loadWoff()` từ `bm-render/woff` |
| `unsupported font format` (một file `.otf`) | `standard` (CFF) |
| `invalid value for style property backgroundColor` với `oklch()` / `lab()` / `color-mix()` trên core | `standard` |
| `this build has no ICO output support`, `... renderSvg support`, `... animation support` | `full` (thông báo ghi "use the full build") |

Kiểm tra `features` khi khởi động, import profile lớn hơn (`bm-render/standard`, `bm-render/full`), hoặc
xem [Profile và kích thước](profiles-and-size.md).

## Ảnh không hiện

- **URL không bao giờ được tải về.** `src: "https://..."` chỉ dùng để tra một mục trong tùy chọn `images`.
  Hãy tự tải byte rồi truyền `images: [{ src: "https://...", data: bytes }]`.
- **`Buffer` của Node truyền thẳng vào `src`** dùng được; không cần bọc `new Uint8Array(buffer)` (chuỗi URL vẫn cần tùy chọn `images`).
- **SVG, WebP hoặc GIF trên `core`**: không được giải mã ở đó; dùng `standard`.
- **WebP lossy hoặc nguồn ảnh động trên `standard`**: cần `full`.
- **`images[].data` dạng lười với phương thức sync** sẽ ném lỗi `lazy images[].data() needs the async
  API`; dùng `render()` / `prepare()`.
- **Node ảnh không có kích thước**: ảnh có `src` không biết hoặc không giải mã được có kích thước nội tại
  0 × 0; đặt `width` / `height` nếu layout không được phụ thuộc vào nó.

## Không tìm thấy file .wasm

- **Trình duyệt / bundler**: import một entry theo profile (`bm-render/full`, `/standard`, `/core`) rồi
  gọi `await init()`. Các entry này tham chiếu binary bằng `new URL("./bm_render....wasm",
  import.meta.url)`, được Vite, webpack 5, Rollup (kèm plugin asset) và Parcel xuất thành asset. Nếu
  bundler của bạn không làm vậy, hãy import URL của binary một cách tường minh (`import wasmUrl from
  "bm-render/full.wasm?url"` trong Vite) hoặc chép file vào thư mục public rồi gọi
  `init("/bm_render.wasm")`.
- **Entry chung `bm-render` bên ngoài Node** không có vị trí mặc định: `init()` không đối số sẽ ném lỗi
  `bm-render: init() needs the wasm binary ...`. Hãy truyền byte, URL / `Response` hoặc
  `WebAssembly.Module`, hoặc chuyển sang entry theo profile.
- **Cloudflare Workers** không cho biên dịch WebAssembly từ byte lúc chạy: hãy import module
  (`import wasm from "bm-render/full.wasm"`) rồi truyền vào `init` / `initSync`.
- **Sai content type**: nếu server không gửi `application/wasm`, `init` chuyển sang đường không
  streaming. Cách đó vẫn chạy, nhưng một trang HTML 404 sẽ không biên dịch được — hãy kiểm tra URL.
- **Node trong môi trường tùy biến**: `BM_WASM=/path/to/bm_render.wasm` thay binary của entry
  `bm-render`.

## Addon native (Node.js)

Trên Node.js, `bm-render` chạy addon native từ optional platform package `@hunghg255/bm-render-<platform>` khi nó
được cài và nạp được, nếu không thì chạy WebAssembly (xem
[Cài đặt](getting-started.md#native-trên-nodejs-webassembly-ở-mọi-nơi-khác)). Cơ chế fallback được thiết kế
để chạy lặng lẽ, nên bước đầu tiên luôn là hỏi xem backend nào đang chạy:

```sh
node --input-type=module -e 'import("bm-render").then((m) => console.log(m.backend))'
BM_RENDER_BACKEND=native node app.mjs   # throws and says why the addon was not used
```

- **Không có binary cho nền tảng này, hoặc nó không được cài** (hệ điều hành / CPU không có platform
  package, ví dụ FreeBSD, Linux trên ARM 32-bit hay ppc64; `--omit=optional`; một `node_modules` chép từ
  hệ điều hành khác; một lockfile làm mất optional package): bạn nhận WebAssembly, với output giống hệt.
  Lỗi khi ép native ghi `@hunghg255/bm-render-<platform>: not installed`. Hãy cài lại trên máy đích, xem
  [Package manager, Docker, serverless](getting-started.md#package-manager-docker-serverless).
- **Tới nay chỉ `win32-x64-msvc` đã được chạy thật.** Bảy platform package còn lại đã được build và kiểm
  tra cấu trúc nhưng chưa từng chạy; nếu một cái không nạp được trên máy bạn, `bm-render` dùng
  WebAssembly. Hãy báo lại kèm thông báo lỗi khi ép native.
- **`BM_RENDER_BACKEND`**: `wasm` không bao giờ thử addon; `native` khiến lệnh import ném lỗi khi addon không
  dùng được; giá trị khác ném lỗi `BM_RENDER_BACKEND must be "wasm" or "native"`. `BM_WASM` và `BM_PROFILE`
  cũng chọn WebAssembly. `bm-render/native` là native hoặc lỗi khi import; `bm-render/full`, `/standard`,
  `/core` luôn là WebAssembly.
- **CPU x64 đời cũ.** Các addon x64 cần x86-64-v2 (SSE4.2, POPCNT: Intel từ 2008, AMD từ 2011). Trên CPU cũ
  hơn, addon từ chối đăng ký và bạn nhận WebAssembly.
- **Electron, Bun, Deno** dùng điểm vào Node và có thể nạp được addon; chưa cái nào được kiểm thử. Nếu addon
  không nạp được, chúng nhận WebAssembly.
- **Render không nhanh hơn khi thêm `await`.** Một renderer chỉ thực thi một lệnh tại một thời điểm (các
  lệnh trên nó được xếp hàng theo thứ tự). Để có thông lượng song song trên backend native, hãy tạo vài
  renderer với cùng bộ font, tối đa khoảng bằng kích thước pool của libuv (`UV_THREADPOOL_SIZE`, mặc định
  4), rồi chia việc. Trên WebAssembly mọi thứ vẫn chạy trên luồng gọi.
- **Server đã bundle không tìm thấy file wasm**: `bm-render: cannot find bm_render.wasm (...)`. Bundler đã
  chuyển điểm vào Node ra khỏi package của nó và lúc chạy không có `node_modules`. Hãy để package ở dạng
  external (Next.js `serverExternalPackages: ["bm-render"]`, esbuild `--external:bm-render`), hoặc đặt
  `BM_WASM=/path/to/bm_render.wasm`. Xem [Next.js](image/frameworks/nextjs.md) về deploy.

## Bộ nhớ tăng mãi

Bộ nhớ WebAssembly chỉ tăng chứ không bao giờ co lại. bm-render tái sử dụng bộ nhớ giữa các lần render
(một arena cho mỗi lần render, các cache có ngân sách cố định: ảnh đã giải mã bị xoá khi vượt 96 MiB,
glyph khi vượt 8 MiB), nên một tải ổn định sẽ dừng ở một mức — khoảng 6 MiB với thẻ 1200 × 630 và một
font. Những gì làm nó tăng:

- **Canvas lớn**: một lần render 3000 × 2000 đẩy instance lên khoảng 29 MiB và giữ nguyên ở đó. Nếu điều
  này quan trọng, hãy render ảnh lớn trong một instance riêng (worker).
- **Nhiều renderer**: mỗi renderer giữ font và cache riêng. Dùng lại một renderer cho mỗi bộ font; gọi
  `free()` (hoặc `using`) khi không dùng nữa. Bộ nhớ đã giải phóng được tái sử dụng cho lần render sau
  nhưng không trả lại cho hệ điều hành.
- **Nhiều ảnh lớn**: mỗi renderer cache tới 96 MiB ảnh đã giải mã.

`renderer.memoryBytes()` cho biết kích thước bộ nhớ tuyến tính hiện tại. Muốn reset hoàn toàn, hãy bỏ cả
instance (một worker thread hoặc một isolate mới).

## Ảnh bị mờ trên màn hình DPI cao

Render nhiều điểm ảnh hơn mà giữ nguyên layout CSS: đặt canvas bằng kích thước thiết bị và
`devicePixelRatio` bằng hệ số tỉ lệ. `devicePixelRatio` nhân các độ dài CSS px và cỡ chữ nhưng không đổi
kích thước canvas:

```js
// a 1200 × 630 design rendered for a 2× screen
const png = renderer.renderSync(node, { width: 2400, height: 1260, devicePixelRatio: 2 });
```

`%`, `vw` và `vh` vốn đã tính theo canvas nên không cần đổi. Sau đó hiển thị ảnh ở một nửa kích thước
điểm ảnh (`<img width="1200">`).

## Tiếng Việt

- Chọn font có glyph tiếng Việt; kiểm tra cả chữ dựng sẵn và chữ có dấu tổ hợp khi nhận nội dung người dùng.

## Emoji không có màu

Emoji màu cần một font emoji màu đã đăng ký (COLR, CBDT hoặc sbix, ví dụ Noto Color Emoji) và một profile
vẽ được nó: font bitmap (CBDT, sbix — Noto Color Emoji) trên `standard` và `full`, font COLR
(`features.colorFonts`) chỉ trên `full`. Không có font, emoji hiện thành ô vuông hoặc glyph của font khác;
font COLR trên `core` / `standard` được vẽ không màu, còn `core` không vẽ gì với font chỉ có bitmap. Chỉ cần đăng ký font là đủ — font dự phòng
duyệt mọi family đã đăng ký.

## Một style bị bỏ qua

- Khoá của `style` inline phải là **camelCase**: `backgroundColor`, không phải `"background-color"` (khoá
  kebab-case bị bỏ qua im lặng). Trong stylesheet, HTML và `tw` thì dùng cú pháp CSS bình
  thường.
- Thuộc tính cần profile lớn hơn (ví dụ `float`, `clipPath` hay `mixBlendMode` trên `core` được chấp
  nhận nhưng bị bỏ qua).
- Khai báo trong stylesheet hoặc Tailwind có giá trị không hợp lệ bị loại im lặng. Hãy thử nó dưới dạng
  style inline, vốn ném lỗi với giá trị không hợp lệ.
- Các variant Tailwind ngoài breakpoint, variant cấu trúc và `before:` / `after:` (`hover:`, `dark:`,
  `group-*:`) không bao giờ được áp dụng —. Utility `animate-*` cần profile `full`.
- Xem danh sách [thuộc tính parse được nhưng chưa cài đặt](image/css-support.md#phụ-lục-danh-sách-thuộc-tính-được-hỗ-trợ).

## "invalid value for style property"

Một giá trị trong `style` (hoặc `preset`) inline không parse được; toàn bộ lần render ném lỗi. Nguyên nhân thường gặp: gõ sai (`"10 px"`), transform 3D (`rotateX()`), cú pháp màu tương đối,
hàm màu hiện đại trên `core`. Khai báo trong stylesheet không ném lỗi; chúng bị loại bỏ.

## Các lỗi khác

| Thông báo (tiền tố `bm-render: `) | Nguyên nhân |
|:--|:--|
| `call init()/initSync() before creating a Renderer` | ngoài Node, entry chưa được khởi tạo |
| `BM_RENDER_BACKEND=native, but the native addon is not available (...)` | ép native nhưng không có addon dùng được; lý do nằm trong ngoặc ([Addon native](#addon-native-nodejs)) |
| `bm-render/native: the native addon is not available (...)` | import `bm-render/native` khi chưa cài platform package |
| `BM_RENDER_BACKEND must be "wasm" or "native", not "..."` | gõ sai biến môi trường |
| `cannot find bm_render.wasm (...)` | bundler đã chuyển điểm vào Node ra khỏi `node_modules` ([Addon native](#addon-native-nodejs)) |
| `renderer has been freed` | dùng renderer sau khi đã `free()` |
| `invalid viewport: width/height must be > 0` | `width` hoặc `height` bằng 0 |
| `invalid viewport: content has zero size and no width/height was given` | không có kích thước canvas và không có gì để đo |
| `canvas too large` | hơn 16384 px mỗi cạnh hoặc 40 megapixel |
| `node tree is nested too deeply` | lồng quá 512 cấp |
| `node is missing \`type\`` / `text node is missing \`text\`` | node sai định dạng |
| `invalid node JSON` | nguồn `{ json }` sai định dạng |
| `unsupported format: <x>` | `format` không phải png / jpeg / webp / raw / ico |
| `raw image data length must be width*height*4` | object ảnh RGBA có độ dài sai |
| `renderAsDataUrl needs an encoded format` | `format: "raw"` với `renderAsDataUrl` (`"jpg"` vẫn dùng được: đó là bí danh của `"jpeg"`) |
| `Frame rate N fps exceeds the maximum ...` | GIF > 50 fps, WebP / APNG > 90 fps |
| `invalid font data` | không phải file font |
