# Bắt đầu

[English](../en/getting-started.md) · [Tiếng Việt](getting-started.md)

Trang này cài đặt bm-render và giải thích những gì bạn nhận được: addon native trên Node.js và
WebAssembly ở mọi nơi khác, các điểm vào của package, bundler, edge runtime, Deno và Bun, và các profile
build. Nội dung ở đây dùng chung cho cả hai loại đầu ra. Cài xong package, hãy tiếp tục với phần bắt đầu
nhanh của loại đầu ra bạn cần:

- **[Bắt đầu nhanh với ảnh](image/index.md)**: PNG, JPEG, WebP, SVG và ảnh động (`bm-render`).
- **[Bắt đầu nhanh với PDF](pdf/index.md)**: tài liệu phân trang (`bm-render/pdf`).

Mọi đoạn mã Node.js trên trang này đều đã được chạy thật với bm-render 0.1.0 thông qua cơ chế phân giải
package; những đoạn dành cho runtime không chạy thử được ở đây đều được ghi chú rõ.

- [Cài đặt](#cài-đặt)
- [Các điểm vào của package](#các-điểm-vào-của-package)
- [Bundler (Vite, webpack, Rollup, esbuild, Next.js)](#bundler)
- [Cloudflare Workers và các edge runtime khác, Deno, Bun](#edge-runtime-deno-bun)
- [Chọn profile](#chọn-profile)
- [Bước tiếp theo](#bước-tiếp-theo)

## Cài đặt

```sh
npm install bm-render
```

Package không có dependency và không có install script. Bên trong gồm bốn binary WebAssembly build sẵn
(`core`, `standard`, `full` và `pdf`, thêm đầu ra PDF), add-on WOFF tùy chọn, một wrapper ESM không phụ thuộc gì và các khai báo
TypeScript. Package chỉ phát hành dạng ES module (xem [CommonJS](#commonjs)).

Package cũng khai báo tám **optional dependency**, mỗi nền tảng một cái: `@hunghg255/bm-render-win32-x64-msvc`,
`@hunghg255/bm-render-linux-x64-gnu`, ... (bảng bên dưới). Mỗi package chỉ chứa bản build Node-API native của cùng
engine (khoảng 1 MB sau nén) và khai báo `os`, `cpu` và, trên Linux, `libc`, nên package manager chỉ cài
đúng cái khớp với máy và bỏ qua những cái còn lại. Không có gì được biên dịch hay tải về lúc cài hoặc lúc
chạy; không có postinstall script.

### Native trên Node.js, WebAssembly ở mọi nơi khác

Trên Node.js, `import ... from "bm-render"` dùng addon native khi platform package của nó được cài và nạp
được; nếu không, nó **tự động và lặng lẽ** chuyển sang binary WebAssembly `full`. API giống hệt và output
giống hệt, đến từng byte; ở dạng native engine chạy nhanh hơn và các method async (`render`, `renderSvg`,
`measure`, `renderAnimation`, ...) chạy trên thread pool của libuv thay vì chặn event loop. Trình duyệt,
bundler cho trình duyệt, worker và edge runtime không bao giờ thấy code native.

```js
import { backend } from "bm-render";
console.log(backend); // "native" or "wasm"
```

| Muốn ép | Dùng |
|:--|:--|
| WebAssembly trên Node | `BM_RENDER_BACKEND=wasm`, hoặc import `bm-render/full` (luôn là wasm) |
| native, hoặc báo lỗi rõ ràng | `BM_RENDER_BACKEND=native` (lệnh import ném lỗi và nói lý do), hoặc import `bm-render/native` |

Lý do addon không được dùng nằm trong thông báo lỗi của `BM_RENDER_BACKEND=native node app.mjs`, ví dụ
`bm-render: BM_RENDER_BACKEND=native, but the native addon is not available (@hunghg255/bm-render-linux-x64-gnu: not
installed)`.

| Platform package | `os` / `cpu` / `libc` | Trạng thái |
|:--|:--|:--|
| `@hunghg255/bm-render-win32-x64-msvc` | win32 / x64 | **đã chạy**: giống hệt từng byte với wasm trên 250 fixture, test luồng / bộ nhớ / fuzz, test cài đặt |
| `@hunghg255/bm-render-win32-arm64-msvc` | win32 / arm64 | đã build và kiểm tra cấu trúc, **chưa từng chạy** |
| `@hunghg255/bm-render-linux-x64-gnu` | linux / x64 / glibc 2.17+ | đã build và kiểm tra cấu trúc, **chưa từng chạy** |
| `@hunghg255/bm-render-linux-x64-musl` | linux / x64 / musl (Alpine) | đã build và kiểm tra cấu trúc, **chưa từng chạy** |
| `@hunghg255/bm-render-linux-arm64-gnu` | linux / arm64 / glibc 2.17+ | đã build và kiểm tra cấu trúc, **chưa từng chạy** |
| `@hunghg255/bm-render-linux-arm64-musl` | linux / arm64 / musl | đã build và kiểm tra cấu trúc, **chưa từng chạy** |
| `@hunghg255/bm-render-darwin-x64` | darwin / x64 (macOS 10.15+) | đã build và kiểm tra cấu trúc, **chưa từng chạy** |
| `@hunghg255/bm-render-darwin-arm64` | darwin / arm64 (macOS 11+) | đã build và kiểm tra cấu trúc, **chưa từng chạy** |

"Kiểm tra cấu trúc" nghĩa là script build đã kiểm tra từng binary mà không chạy nó (định dạng, CPU, các
symbol export và import, phiên bản symbol của glibc, không import thư viện toán). Cho tới khi một nền tảng
được chạy thật, hãy dựa vào cơ chế fallback: nếu addon của nó không nạp được, `bm-render` dùng WebAssembly.
Các bản build x64 cần CPU x86-64-v2 (SSE4.2, từ 2009 trở đi); CPU cũ hơn dùng WebAssembly. Cần Node.js 20
trở lên.

### Package manager, Docker, serverless

- **npm, pnpm, Yarn, Bun** tôn trọng `os` và `cpu` (ở đây chỉ npm được kiểm thử). `libc` (glibc hay musl) được npm hiện tại (đã kiểm
  thử: npm 11) và, theo tài liệu của chúng, pnpm và Yarn 3.2+ tôn trọng; một package manager bỏ qua nó có thể cài cả hai biến thể
  Linux cho kiến trúc của bạn, điều này vô hại: `bm-render` phát hiện musl và nạp đúng cái.
- **`npm install --omit=optional`** (`--no-optional`, Yarn `--ignore-optional`, ...) không cài platform
  package nào: bạn nhận WebAssembly (đã kiểm thử với npm).
- **Lockfile tạo trên hệ điều hành khác.** Với npm 11, lockfile ghi trên Windows liệt kê đủ tám package
  cùng `os` / `cpu` / `libc` của chúng, và `npm ci` cho Linux x64 cài `@hunghg255/bm-render-linux-x64-gnu` (đã kiểm
  thử). Một số phiên bản npm cũ hơn làm rơi optional package của các nền tảng khác khỏi lockfile khi
  `node_modules` đã tồn tại (npm/cli#4828), cái bẫy kinh điển của package native. Ở đây nó không gây lỗi:
  thiếu addon nghĩa là WebAssembly, không phải lỗi. Để sửa, xóa `node_modules` và lockfile rồi cài lại, và
  kiểm tra `backend` trong CI.
- **Docker.** Chạy `npm ci` bên trong image, trên nền tảng của image; đừng chép `node_modules` được build
  trên máy Windows hay macOS vào một image Linux (bạn sẽ nhận WebAssembly). Build đa kiến trúc
  (`docker buildx --platform linux/amd64,linux/arm64`) cài đúng package cho từng kiến trúc. Image Alpine
  nhận package `-musl`.
- **Cài cho một máy khác** (ví dụ build bản deploy Linux trên máy Mac): có thể báo cho npm biết nền tảng
  đích, và khi đó cần đủ cả ba cờ (không có `--libc`, trên Windows npm không cài package Linux nào):

  ```sh
  npm ci --os=linux --cpu=x64 --libc=glibc     # AWS Lambda x86_64, most Linux servers
  npm ci --os=linux --cpu=arm64 --libc=glibc   # Lambda arm64 (Graviton)
  npm ci --os=linux --cpu=x64 --libc=musl      # Alpine
  ```

  pnpm và Yarn dùng `supportedArchitectures` trong cấu hình của chúng.
- **Serverless (AWS Lambda, Vercel Functions, Netlify Functions, ...).** Binary được chọn lúc cài
  dependency, trên máy build: nền tảng build trên Linux x64 (Vercel, Netlify, đa số CI) nhận
  `@hunghg255/bm-render-linux-x64-gnu`; một file zip `node_modules` tạo trên Mac hoặc Windows mang theo binary sai
  (lúc chạy là WebAssembly). Các công cụ deploy có bundle cũng phải mang theo platform package; xem
  [Next.js](./image/frameworks/nextjs.md#addon-native-khi-triển-khai) về `outputFileTracingIncludes`. Hãy log
  `backend` một lần khi khởi động để biết thứ gì đang chạy. Chưa kiểm thử kiểu deploy nào trong số này.
- **Bun, Deno, Electron** nạp điểm vào `node` và có thể nạp được addon; chưa kiểm thử. Nếu không nạp
  được, chúng dùng WebAssembly.

## Các điểm vào của package

| Import | Node.js (điều kiện `node`) | Mọi nơi khác (trình duyệt, bundler, worker, Deno) |
|:--|:--|:--|
| `bm-render` | addon native nếu đã cài, nếu không thì binary `full`, sẵn sàng ngay khi import (`BM_RENDER_BACKEND`, `BM_PROFILE`, `BM_WASM` ghi đè) | chỉ có wrapper: bạn tự gọi `init(wasm)` với binary |
| `bm-render/native` | addon native, nếu không có thì lệnh import ném lỗi | không có |
| `bm-render/full` | `full`, tự khởi tạo khi import | `await init()` tự tìm `bm_render.wasm` nằm cạnh module (hoặc truyền vào) |
| `bm-render/standard` | `standard`, tự khởi tạo khi import | `await init()` tự tìm `bm_render.standard.wasm` |
| `bm-render/core` | `core`, tự khởi tạo khi import | `await init()` tự tìm `bm_render.core.wasm` |
| `bm-render/pdf` | addon native khi đã cài, nếu không thì profile wasm `pdf` (= `full` + đầu ra PDF), tự khởi tạo khi import; xem [Đầu ra PDF](pdf/index.md) | `await init()` tự tìm `bm_render.pdf.wasm` |
| `bm-render/woff` | `loadWoff()` / `decodeWoff()` — add-on WOFF | như bên trái |
| `bm-render/full.wasm`, `/standard.wasm`, `/core.wasm`, `/woff.wasm` (`bm-render/wasm` = full) | các binary thô, dùng cho import asset của bundler và import module trên Workers; mỗi file còn có dạng `...wasm?module` cho Next.js Edge | như bên trái |

Mọi điểm vào đều có cùng API (`init`, `initSync`, `Renderer`, `features`, `backend`, ...; các điểm vào theo
profile còn export thêm `profile` và `wasmUrl()`). Mỗi điểm vào có **instance module riêng**, nên có thể
nạp nhiều profile song song trong một tiến trình; trong cùng một điểm vào, lần `init` thành công đầu
tiên được giữ và các lần gọi sau trả về đúng instance đó. `bm-render` và `bm-render/full` cũng là hai
instance riêng: import cả hai trên Node sẽ nạp binary full hai lần, nên chỉ chọn một.

### CommonJS

bm-render được phát hành dưới dạng ES module. Vì các điểm vào Node không dùng top-level `await`, những
phiên bản Node hỗ trợ `require(esm)` (22.12+, 20.19+) có thể nạp chúng từ CommonJS:

```js
const { Renderer } = require("bm-render");
```

Điều này đã được kiểm chứng trên Node 26.13. Với Node cũ hơn, dùng `const { Renderer } = await import("bm-render")`.

## Bundler

Import một điểm vào theo profile và gọi `init()` không đối số. Các điểm vào này định vị binary bằng
`new URL("./bm_render.wasm", import.meta.url)`, một mẫu mà Vite, webpack 5, Rollup và Parcel nhận ra và
xuất thành asset:

```js
import { init, Renderer } from "bm-render/full"; // hoặc bm-render/standard, bm-render/core

await init();
const renderer = new Renderer();
```

Nếu bundler của bạn không xử lý mẫu đó, hãy tự import URL của binary rồi truyền vào:

```js
import { init, Renderer } from "bm-render/full";
import wasmUrl from "bm-render/full.wasm?url"; // Vite

await init(wasmUrl);
```

| Bundler | Ghi chú | Đã kiểm thử |
|:--|:--|:--|
| Vite | `await init()` xuất file `.wasm` thành asset; import `?url` cũng được; không cần cấu hình thêm | có: Vite 8.3.8, cả build lẫn dev server, các trang chạy trong Edge 157 headless |
| webpack 5 | `new URL(..., import.meta.url)` mặc định được xuất thành asset module | không |
| Rollup | cần một plugin asset xử lý `new URL(..., import.meta.url)` (ví dụ `@web/rollup-plugin-import-meta-assets`), hoặc tự truyền URL | không |
| esbuild | bundle được (điều kiện browser và `workerd`) nhưng không chép asset của `new URL()`: hãy chép file `.wasm` cạnh bundle, hoặc dùng `--loader:.wasm=file` rồi truyền URL đã import cho `init` | chỉ bước bundle (esbuild 0.28) |

**Bundle một chương trình Node.js** (esbuild `--platform=node`, Rollup, webpack với `target: "node"`). Cách
đơn giản nhất là để package nằm ngoài bundle: `esbuild app.mjs --bundle --platform=node
--external:bm-render`, rồi mang theo `node_modules`. Nếu vẫn bundle, điểm vào Node của `bm-render` vẫn chạy
miễn là `node_modules/bm-render` (và platform package) tồn tại lúc chạy: nó tìm file wasm ngay cạnh nó, sau
đó qua package resolution, sau đó trong `<cwd>/node_modules/bm-render/js/`, và require platform package lúc
chạy (không cần `--loader:.node`: file `.node` không bao giờ nằm trong bundle). Đã kiểm thử với esbuild
0.28: bundle ESM và CommonJS chạy native; bundle CommonJS chép sang một thư mục không có `node_modules` lỗi
ngay khi import với `bm-render: cannot find bm_render.wasm (...). This happens when a bundler moved
bm-render's Node.js entry away from its package: keep the package external ...`, và chạy được với
`BM_WASM=/path/to/bm_render.wasm`.

**Đừng** bật cơ chế tích hợp WebAssembly-ESM của bundler cho các file này (`experiments.asyncWebAssembly`,
`vite-plugin-wasm`): bm-render tự instantiate module và chờ nhận một URL, bytes hoặc một
`WebAssembly.Module`.

**Next.js.** Trong Route Handler chạy trên runtime Node.js, import `bm-render` và đọc font bằng `fs` như ví
dụ Node. Với Next.js 16.4.6 (builder Turbopack và webpack), cách này chạy mà không cần cấu hình gì khi dùng
`next start`, ở dạng native nếu platform package đã được cài. Với output tự chứa (`output: "standalone"`,
Vercel), thêm `serverExternalPackages: ["bm-render"]` và
`outputFileTracingIncludes: { "/*": ["./node_modules/bm-render-*/**"] }` để các file wasm và platform package
được chép theo; thiếu chúng, bản build webpack lỗi lúc chạy và bản build Turbopack lùi về wasm. Trên Edge
runtime, dùng `import wasm from "bm-render/core.wasm?module"` và `initSync(wasm)` (từ `bm-render/core`).
bm-render không có helper `ImageResponse`; hãy trả về
`new Response(png, { headers: { "content-type": "image/png" } })`. Xem trang [Next.js](./image/frameworks/nextjs.md)
để biết cấu hình đầy đủ và chính xác những gì đã được kiểm chứng.

Tình trạng kiểm chứng của mục này: các dòng Vite và esbuild đã được chạy trong bài test package
(`npm run test:pack`: `npm pack`, cài tarball, build, chạy trong Edge headless); webpack và Rollup
chưa được kiểm thử; Next.js có [trang riêng](./image/frameworks/nextjs.md).

## Edge runtime, Deno, Bun

**Cloudflare Workers / workerd** biên dịch các import `.wasm` từ trước và đưa cho bạn một
`WebAssembly.Module` (ở đó không được phép biên dịch từ bytes lúc chạy). Import binary rồi truyền cho
`init` hoặc `initSync`:

```js
import { initSync, Renderer } from "bm-render/full";
import wasm from "bm-render/full.wasm"; // a WebAssembly.Module under wrangler

initSync(wasm);
let renderer; // reuse one renderer per isolate

export default {
  async fetch() {
    renderer ??= new Renderer(); // + registerFont(...) with font bytes from an asset / KV / fetch
    const png = renderer.renderSync({ type: "container", style: { width: "100%", height: "100%", backgroundColor: "#7c3aed" } },
                                    { width: 1200, height: 630 });
    return new Response(png, { headers: { "content-type": "image/png" } });
  },
};
```

Những gì đã kiểm thử: `initSync(new WebAssembly.Module(bytes))` đã chạy trong Node, và bài test package
resolve các điểm vào với `node --conditions=workerd` rồi khởi tạo chúng từ một `WebAssembly.Module`;
đoạn mã trên **chưa** được chạy dưới wrangler / workerd. Kích thước nén của từng profile (gzip -9: core
200 KiB, standard 465.1 KiB, full 560.0 KiB) là con số tính vào giới hạn kích thước script Workers theo gói
của bạn. Add-on WOFF dùng tương tự: `import woff from "bm-render/woff.wasm"; await loadWoff(woff)`.

- **Bun**: điều kiện `node` được áp dụng, nên `import { Renderer } from "bm-render"` thử addon native và
  nếu không có thì nạp binary wasm bằng `node:fs`. Chưa kiểm thử.
- **Deno**: `import { Renderer } from "npm:bm-render"` dùng cùng điểm vào Node. Chưa kiểm thử.

## Chọn profile

| Profile | wasm thô / brotli | Chọn khi |
|:--|:--|:--|
| `core` | 489.6 / 195.3 KiB | Đầu vào là cây node với `style` inline, font TTF tĩnh và ảnh PNG/JPEG (ảnh OG điển hình). |
| `standard` | 936.5 / 398.6 KiB | Bạn cần stylesheet (`css`), Tailwind (`tw`), đầu vào HTML, ảnh SVG, WOFF2, font biến thiên hoặc CFF, hiệu ứng (clip-path, mask, blend mode, backdrop-filter), màu hiện đại, bảng hoặc float. |
| `full` | 1 143.6 / 470.8 KiB | Bạn cần thêm bidi / chữ phức tạp (Ả Rập, Hebrew, Ấn Độ, Thái), emoji màu, CSS animation / `renderAnimation`, `renderSvg`, ảnh vào WebP lossy hoặc ảnh động, hoặc xuất ICO. |

Chi tiết, kể cả việc profile nhỏ xử lý ra sao với đầu vào nó không hỗ trợ, nằm ở
[Profile và kích thước](profiles-and-size.md). Lúc chạy, `features` cho biết binary đang nạp có gì:

```js
import { features } from "bm-render/standard";
features.css;         // true
features.complexText; // false (full only)
```

## Bước tiếp theo

| Đầu ra | Bắt đầu ở đây | Sau đó |
|:--|:--|:--|
| Ảnh | [Bắt đầu nhanh với ảnh](image/index.md): render trên Node.js và trong trình duyệt, font, ảnh, định dạng đầu ra | [Khái niệm](image/concepts.md), [Tham chiếu API](image/api.md), [Hỗ trợ CSS](image/css-support.md) |
| PDF | [Bắt đầu nhanh với PDF](pdf/index.md): `bm-render/pdf`, tài liệu đầu tiên, các tùy chọn | [Phân trang](pdf/pagination.md), [Tham chiếu API PDF](pdf/api.md), [Công thức](pdf/recipes.md) |
