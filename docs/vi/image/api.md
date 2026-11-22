# Tham chiếu API

[English](../../en/image/api.md) · [Tiếng Việt](api.md)

Tham chiếu API bm-render: khởi tạo, `Renderer`, định dạng node, tùy chọn render, lỗi và bộ nhớ. Khai báo kiểu nằm trong `js/index.d.mts` và các file `.d.mts` của từng profile. Kết quả dạng byte là một `Uint8Array` mới, có thể truyền vào `Response` hoặc `Blob`.

- [Các export của module](#các-export-của-module): [`init`](#init), [`initSync`](#initsync), [`features`](#features), [`profile` / `wasmUrl`](#profile-và-wasmurl), [`setGlyphCacheMaxBytes`](#setglyphcachemaxbytes)
- [`Renderer`](#renderer): [hàm khởi tạo](#hàm-khởi-tạo), [`registerFont`](#registerfont), [`unregisterFont`](#unregisterfont), [`clearFonts`](#clearfonts), [`render`](#render--rendersync), [`renderAsDataUrl`](#renderasdataurl--renderasdataurlsync), [`renderSvg`](#rendersvg--rendersvgsync), [`measure`](#measure--measuresync), [`renderAnimation`](#renderanimation--renderanimationsync), [`prepare`](#prepare--prepareanimation), [`memoryBytes`](#memorybytes), [`free`](#free--symboldispose)
- [Định dạng node](#định-dạng-node)
- [Tùy chọn render](#tùy-chọn-render)
- [Lỗi](#lỗi)
- [Giới hạn](#giới-hạn)
- [Bộ nhớ, instance và luồng](#bộ-nhớ-instance-và-luồng)
- [Add-on WOFF (`bm-render/woff`)](#add-on-woff)

## Các export của module

Mọi điểm vào (`bm-render`, `bm-render/core`, `bm-render/standard`, `bm-render/full`, `bm-render/pdf`, `bm-render/native`)
export cùng các tên và sở hữu một instance engine (một instance wasm; trên Node.js, `bm-render` có thể chạy
addon native thay vào đó, còn `bm-render/native` thì luôn như vậy); `bm-render/pdf` thêm `PdfRenderer` và các hàm tạo bộ đếm trang ([Đầu ra PDF](../pdf/index.md)). Xem [Các điểm vào của package](../getting-started.md#các-điểm-vào-của-package).

| Export | Loại |
|:--|:--|
| `init` (cũng là default export) | `async (input?) => WebAssembly.Exports` |
| `initSync` | `(input) => WebAssembly.Exports` |
| `Renderer` | lớp |
| `features` | `Readonly<Features>` |
| `Prepared` | lớp mờ (opaque) của các handle do `prepare()` trả về (bạn không tự tạo được) |
| `setGlyphCacheMaxBytes` | không làm gì, để tương thích API |
| `backend` | `"wasm" \| "native"`: bản build engine nào phục vụ điểm vào này (`"native"` chỉ với `bm-render` / `bm-render/native` trên Node.js khi đã cài platform package); API và output như nhau, xem [Native trên Node.js](../getting-started.md#native-trên-nodejs-webassembly-ở-mọi-nơi-khác) |
| `profile` | `"core" \| "standard" \| "full" \| "pdf"` (chỉ có ở điểm vào theo profile) |
| `wasmUrl` | `() => URL` (chỉ có ở điểm vào theo profile) |

### `init`

```ts
init(input?: InitInput | Promise<InitInput> | { module_or_path: InitInput | Promise<InitInput> }): Promise<WebAssembly.Exports>
type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;
```

Khởi tạo binary. Chuỗi, `URL` và `Request` sẽ được fetch; một `Response` có content type
`application/wasm` được biên dịch bằng `WebAssembly.instantiateStreaming`, các `Response` khác đi qua
`arrayBuffer()`. `init` là idempotent: khi một điểm vào đã khởi tạo xong, các lần gọi sau trả về cùng
instance và bỏ qua đối số; các lần gọi đồng thời dùng chung một lần khởi tạo; lần gọi thất bại có thể
thử lại. Các điểm vào theo profile mặc định dùng binary của chính chúng (`wasmUrl()`); điểm vào chung
`bm-render` trong trình duyệt bắt buộc phải có đối số. Trên Node.js, mọi điểm vào đã được khởi tạo sẵn khi
import hoàn tất.

### `initSync`

```ts
initSync(input: BufferSource | WebAssembly.Module | { module: BufferSource | WebAssembly.Module }): WebAssembly.Exports
```

Khởi tạo đồng bộ từ bytes hoặc từ module đã biên dịch (thứ Cloudflare Workers đưa cho bạn khi import một
file `.wasm`). Quy tắc idempotent giống `init`.

### `features`

Một object gồm các giá trị boolean mô tả binary đang nạp; tất cả là `false` trước khi khởi tạo.

| Khoá | Ý nghĩa | core | standard | full |
|:--|:--|:-:|:-:|:-:|
| `css` | stylesheet (tùy chọn `css`, `<style>` trong HTML), selector, phân tích `@keyframes` | | ✓ | ✓ |
| `tw` | utility Tailwind `tw` | | ✓ | ✓ |
| `html` | nguồn là chuỗi HTML | | ✓ | ✓ |
| `svg` | ảnh SVG | | ✓ | ✓ |
| `woff` | WOFF / WOFF2 tích hợp sẵn | | ✓ | ✓ |
| `variableFonts` | instance của font biến thiên | | ✓ | ✓ |
| `cff` | outline CFF / CFF2 (`.otf`) | | ✓ | ✓ |
| `effects` | clip-path, mask, blend mode, backdrop-filter, isolation | | ✓ | ✓ |
| `modernColor` | `lab()`, `lch()`, `oklab()`, `oklch()`, `color()`, `color-mix()`, `light-dark()`, gradient `in <space>` | | ✓ | ✓ |
| `tables` | layout bảng | | ✓ | ✓ |
| `floats` | float | | ✓ | ✓ |
| `webpGifDecode` | ảnh nguồn WebP (lossless) và GIF | | ✓ | ✓ |
| `textWrapBalance` | `text-wrap: balance / pretty` | | ✓ | ✓ |
| `colorFonts` | glyph màu COLR v0/v1 (glyph bitmap CBDT / sbix cũng được vẽ có màu trên `standard`) | | | ✓ |
| `complexText` | bidi, shaping Ả Rập / Hebrew / Ấn Độ / Thái, chuẩn hoá Unicode | | | ✓ |
| `animation` | CSS animation (`timeMs`), `renderAnimation`, ảnh nguồn động | | | ✓ |
| `extraCodecs` | giải mã WebP lossy, giải mã và mã hoá GIF / APNG / WebP động, xuất ICO | | | ✓ |
| `renderSvg` | `renderSvg()` | | | ✓ |
| `pdf` | `renderPdf()` / `measurePdf()` (đầu ra PDF) | | | `false` ở `full` và ở `bm-render` (kể cả trên addon native); `true` chỉ ở `bm-render/pdf` (native hoặc wasm), nơi mọi tính năng khác cũng có |

### `profile` và `wasmUrl`

Chỉ có trên `bm-render/core`, `/standard`, `/full` và `/pdf`: `profile` là tên profile của điểm vào; `wasmUrl()`
trả về URL mà `init()` nạp theo mặc định (`new URL("./bm_render[.<profile>].wasm", import.meta.url)`) và
ném lỗi ở nơi không dùng được `import.meta.url`.

### `setGlyphCacheMaxBytes`

`setGlyphCacheMaxBytes(bytes: number): void`: nhận nhưng bỏ qua. Cache mask glyph có ngân sách cố định
8 MiB.

## `Renderer`

Một renderer sở hữu các font đã đăng ký, một cache ảnh đã giải mã và một cache glyph. Hãy tạo một renderer
cho mỗi bộ font và dùng lại; tạo renderer rất rẻ, còn đăng ký font thì không.

Mỗi method render đều có hai bản: `xxxSync()` trả về kết quả, `xxx()` trả về một `Promise`. Ở cả hai bản,
việc render đều đồng bộ và chặn luồng đang gọi; bản async chỉ làm thêm việc chờ các tùy chọn bất đồng bộ
(`fonts`, `images[].data` nạp lười, promise).

### Hàm khởi tạo

```ts
new Renderer(options?: { limits?: Limits; cacheMaxBytes?: number; fontCacheMaxBytes?: number })
```

Ném `bm-render: call init()/initSync() before creating a Renderer` nếu chưa khởi tạo. `limits` đặt
[giới hạn tài nguyên](#giới-hạn-tài-nguyên-cho-đầu-vào-không-tin-cậy) mặc định cho mọi lần gọi trên
renderer này. `cacheMaxBytes` và `fontCacheMaxBytes` được nhận nhưng bỏ qua (ngân sách cố định: 96 MiB
ảnh đã giải mã, 8 MiB mask glyph).

### `registerFont`

```ts
registerFont(font: ByteBuf | { name?, data: ByteBuf, weight?, style? }): RegisteredFamily[]
registerFont(font: string | URL | Promise<...> | { data: () => ByteBuf | Promise<ByteBuf> }): Promise<RegisteredFamily[]>
loadFont(...)  // alias
type RegisteredFamily = { name: string; faces: { weight: number; style: string; width: number; index: number }[]; weight?: number; style?: string };
```

- `data`: TTF, OTF, TTC/OTC (mọi face đều được đăng ký), và WOFF / WOFF2 khi bản build có hỗ trợ hoặc đã
  nạp [add-on](#add-on-woff). `ByteBuf` là `Uint8Array | ArrayBuffer | ArrayBufferView` (`Buffer` của
  Node dùng được).
- `name` ghi đè tên family, `weight` (số) và `style` (`"normal"`, `"italic"`, `"oblique"`) ghi đè giá trị
  trong các bảng của font.
- Đồng bộ với bytes và `{ data: bytes }`. Chuỗi URL hoặc `URL` sẽ được tải (bằng `fetch`, nên trong Node
  là `http(s):`, không phải `file:`), và hàm / promise ở `data` sẽ được chờ: khi đó lời gọi trả về một
  `Promise`.
- `unicodeRange`, `subsetOf` và `generic` được nhận nhưng bỏ qua; mọi face được đăng ký ngay lập tức.
- Bytes được chép vào bộ nhớ wasm một lần và phân tích tại chỗ.

```js
r.registerFont(readFileSync("Inter-Regular.ttf"));
// [{ name: "Inter", faces: [{ weight: 400, style: "normal", width: 100, index: 0 }], weight: 400, style: "normal" }]
r.registerFont({ name: "Brand", data: readFileSync("Inter-Bold.ttf"), weight: 700 });
// [{ name: "Brand", faces: [{ weight: 700, ... }], weight: 700, style: "normal" }]
```

Lỗi: `bm-render: invalid font data`, `bm-render: unsupported font format` (ví dụ CFF trên `core`), và với
WOFF trên bản build không hỗ trợ: `bm-render: this build has no WOFF/WOFF2 font support (use the
standard / full build, or load the WOFF add-on: ...)`.

### `unregisterFont`

`unregisterFont(family: string | { name: string }): boolean`: gỡ mọi face của family. Trả về `true` khi
có gì đó bị gỡ.

### `clearFonts`

`clearFonts(): void`: gỡ mọi font đã đăng ký. Sau đó không còn font tích hợp nào: chữ sẽ
không được vẽ cho tới khi bạn đăng ký lại font.

### `render` / `renderSync`

```ts
renderSync(source: Source | Prepared, options?: RenderOptions): Uint8Array
render(source: Source | Prepared, options?: RenderOptions): Promise<Uint8Array>
```

`source` là một [node](#định-dạng-node), `{ json: string }` (cây node dưới dạng văn bản JSON), một
**chuỗi HTML** (mọi chuỗi JS đều được coi là HTML; cần `features.html`) hoặc một handle
`Prepared`. Trả về một `Uint8Array` mới: ảnh đã mã hoá, hoặc RGBA8 thẳng với `format: "raw"`. Xem
[Tùy chọn render](#tùy-chọn-render).

```js
const png = r.renderSync({ type: "container", style: { width: 100, height: 50, backgroundColor: "red" } }, { width: 100, height: 50 });
const raw = r.renderSync(node, { width: 100, height: 50, format: "raw" }); // 100 * 50 * 4 bytes
const fromJson = r.renderSync({ json: JSON.stringify(node) }, { width: 100, height: 50 });
const fromHtml = r.renderSync("<div style='display:flex;width:100px;height:50px;background:red'></div>", { width: 100, height: 50 });
```

### `renderAsDataUrl` / `renderAsDataUrlSync`

Đối số giống `render`. Trả về `data:image/png;base64,...` (hoặc `image/jpeg`, `image/webp`,
`image/x-icon`). `format: "raw"` ném `bm-render: renderAsDataUrl needs an encoded format` (`"jpg"` được chấp nhận như bí danh của `"jpeg"`).

### `renderSvg` / `renderSvgSync`

Trả về một chuỗi tài liệu SVG (cần `features.renderSvg`, tức profile `full`; nếu không sẽ ném
`bm-render: this build has no renderSvg support ...`). Hộp thành `<rect>`/`<path>`, gradient thành
`<linearGradient>`/`<radialGradient>` (gradient conic thành các hình quạt), đổ bóng thành `<filter>`,
ảnh được nhúng dưới dạng URL `data:`, chữ thành outline glyph (`<use>` trỏ tới path trong `<defs>`; không
nhúng font, chữ không chọn/copy được). `format`, `quality` và `devicePixelRatio` bị bỏ qua (luôn là tỉ lệ 1,
).

```js
const svg = r.renderSvgSync(node, { width: 400, height: 200 });
// '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200" viewBox="0 0 400 200">...'
```

### `renderPdf` / `measurePdf` và các bản `*Sync`

Mọi `Renderer` đều có `renderPdf(source, options)` và `measurePdf(source, options)`, nhưng chỉ `bm-render/pdf` cung cấp bộ ghi PDF;
ở mọi build khác, kể cả `bm-render` trên addon native, chúng ném `bm-render: renderPdf is not supported by this build (use the pdf build: import from "bm-render/pdf")`.
Các tùy chọn được mô tả ở [Đầu ra PDF](../pdf/index.md); `PdfRenderer` trong `bm-render/pdf` là cách gọi thông thường.
Trên Node.js, `bm-render/pdf` chạy trên addon native khi đã cài (byte PDF giống hệt profile wasm `pdf`), và khi đó các bản async chạy ngoài main thread, trên thread pool của libuv.

### `measure` / `measureSync`

Chỉ dàn layout, không vẽ, và trả về cây `MeasuredNode`:

```ts
type MeasuredNode = {
  width: number; height: number;                                  // border box, device px (1/64 px precision)
  transform: [a: number, b: number, c: number, d: number, e: number, f: number]; // 2D matrix of the node relative to the canvas
  children: MeasuredNode[];
  runs: { x: number; y: number; width: number; height: number; text?: string }[]; // text line runs, relative to the node
};
```

```js
r.measureSync(
  { type: "container", style: { display: "flex", width: 200, padding: 10, gap: 10, fontFamily: "Inter" },
    children: [{ type: "text", text: "Hello world" }, { type: "container", style: { width: 20, height: 20 } }] },
  { width: 300, height: 100 },
);
// { width: 200, height: 40, transform: [1,0,0,1,0,0], runs: [], children: [
//   { width: 85.40625, height: 20, transform: [1,0,0,1,10,10], children: [], runs: [{ x: 0, y: 0, width: 85.40625, height: 20 }] },
//   { width: 20, height: 20, transform: [1,0,0,1,105.40625,10], children: [], runs: [] } ] }
```

`transform` là ma trận 2D tương đối với canvas. Vị trí `runs` tương đối với content box của node. Run không có trường `text`; chiều cao run là chiều cao dòng. Xem [measure()](measure.md).

### `renderAnimation` / `renderAnimationSync`

```ts
renderAnimationSync(options: RenderAnimationOptions | Prepared): Uint8Array
renderAnimation(options: RenderAnimationOptions): Promise<Uint8Array>
renderAnimation(prepared: Prepared, options?: { signal?: AbortSignal }): Promise<Uint8Array>

type RenderAnimationOptions = CommonOptions & {
  scenes: { node: Source; durationMs: number }[];
  width: number; height: number;      // required
  fps: number;                        // required, >= 1
  format?: "webp" | "apng" | "gif";   // default "webp" (lossless)
  quality?: number; lossless?: boolean; // accepted, ignored
};
```

Cần `features.animation` (`full`). Mã hoá ra WebP động (lossless), APNG hoặc GIF (bảng màu lượng tử hoá
theo từng khung).

**Lịch khung hình**: với `total = sum(durationMs)`, animation có
`ceil(total × fps / 1000)` khung; khung *i* bắt đầu ở `floor(i × 1000 / fps)` ms và kéo dài tới lúc khung
kế tiếp bắt đầu (cắt ở `total`; khung dài 0 bị bỏ). Mỗi khung hiển thị scene đang hoạt động tại thời điểm
bắt đầu của nó, render ở thời gian **cục bộ** của scene đó (CSS animation bắt đầu lại ở mỗi scene).
`fps` tối đa: 50 với GIF, 90 với WebP / APNG.

```js
const gif = r.renderAnimationSync({
  scenes: [{ node, durationMs: 1000 }, { node: doneNode, durationMs: 1000 }],
  width: 200, height: 200, fps: 20, format: "gif",
  css: ["@keyframes spin { to { transform: rotate(360deg) } } .dot { animation: spin 1s linear infinite }"],
}); // 40 frames
```

Lỗi: `Expected at least one animation scene`, `renderAnimation needs \`width\` and \`height\``,
`missing field \`fps\``, `Expected fps to be greater than 0`,
`Frame rate 60 fps exceeds the maximum 50 fps for this animation format`,
`unsupported animation format: mp4`. Tổng dữ liệu khung thô bị giới hạn 512 MiB cho mỗi lần gọi.

Muốn render một khung của CSS animation thành ảnh tĩnh, hãy dùng `render(..., { timeMs })`.

### `prepare` / `prepareAnimation`

```ts
prepare(source: Source, options?: RenderOptions): Promise<Prepared>
prepareAnimation(options: RenderAnimationOptions): Promise<Prepared>
```

Xử lý một lần các phần bất đồng bộ của tùy chọn (đăng ký `fonts`, chờ `images` nạp lười) rồi trả về một
handle. `render*`, `renderAsDataUrl*`, `renderSvg*` và `measure*` nhận handle của `prepare` và gộp tùy
chọn riêng của chúng đè lên tùy chọn đã chuẩn bị; `renderAnimation*` nhận handle của `prepareAnimation`.
Truyền nhầm loại sẽ ném `bm-render: this prepared handle is for renderAnimation` (hoặc `... for render`).

`prepare` **không tải gì cả**: không có bước "needs" để tìm ảnh từ xa hay file
`@font-face`. Hãy cung cấp bytes ảnh qua `images` và font qua `fonts` / `registerFont`.

```js
const prepared = await r.prepare(node, { width: 400, height: 112, images: [{ src: "avatar", data: () => readFile("logo.png") }] });
const png = r.renderSync(prepared);
const jpeg = await r.renderAsDataUrl(prepared, { format: "jpeg", quality: 90 });
```

### `memoryBytes`

`memoryBytes(): number` (cũng có `Renderer.memoryBytes()`, bằng `0` trước khi init): kích thước hiện tại
của bộ nhớ tuyến tính wasm của điểm vào, dùng chung cho mọi renderer của điểm vào đó. Xem
[Bộ nhớ](#bộ-nhớ-instance-và-luồng).

### `free` / `[Symbol.dispose]`

`free()` giải phóng font, cache và canvas của renderer bên trong heap wasm (vùng nhớ được dùng lại cho các
lần cấp phát sau; bản thân bộ nhớ tuyến tính không bao giờ co lại). Gọi method sau đó sẽ ném
`bm-render: renderer has been freed`; gọi `free()` hai lần thì vô hại. `using r = new Renderer()` tự gọi
nó ở nơi có hỗ trợ explicit resource management.

## Định dạng node

```ts
type Node = ContainerNode | TextNode | ImageNode;
type ContainerNode = Meta & { type: "container"; children?: (Node | null | undefined)[] };
type TextNode      = Meta & { type: "text"; text: string };
type ImageNode     = Meta & { type: "image"; src: string | ByteBuf | { width, height, data, premultiplied? }; width?: number; height?: number };
type Meta = {
  style?: Style;      // inline CSS declarations, camelCase keys
  preset?: Style;     // user-agent layer: lowest priority
  tw?: string;        // Tailwind classes (standard / full)
  tagName?: string;   // element name, only for matching type selectors in `css` (none by default: a node without it matches no type selector); it does NOT apply HTML user-agent default styles to node trees
  className?: string; // for stylesheet selectors
  id?: string;
  attributes?: Record<string, string>; // for attribute selectors, `attr()`
  dir?: "ltr" | "rtl" | "auto";
  lang?: string;      // :lang(), OpenType language system
};
```

- `type` là bắt buộc (`bm-render: node is missing \`type\``); node chữ cần `text`
  (`bm-render: text node is missing \`text\``). Khoá lạ bị bỏ qua. Con là `null` / `undefined` bị bỏ qua.
- **Khoá style viết camelCase** (`backgroundColor`, `WebkitLineClamp`). Khoá kebab-case
  (`"background-color"`) và tên thuộc tính lạ bị bỏ qua mà không báo. Custom property giữ
  nguyên dấu gạch: `{ "--accent": "#7c3aed", color: "var(--accent)" }`.
- **Giá trị** là chuỗi CSS hoặc số. Số được hiểu là độ dài tính bằng px khi thuộc tính nhận độ dài
  (`width: 100`), và là số thuần trong các trường hợp khác (`opacity: 0.5`, `lineHeight: 1.4`,
  `fontWeight: 700`). `!important` bên trong chuỗi giá trị được tôn trọng.
- **Thứ tự ưu tiên** (thấp → cao): `preset` < luật stylesheet (`css`) và utility `tw` < `style` inline;
  `!important` theo quy tắc CSS.
- **Giá trị mặc định:** `display` là **`inline`** với mọi node (node gốc
  và con của flex/grid được chuyển thành block); `boxSizing` là **`border-box`**; `objectFit` là `fill`;
  `transformOrigin` là `50% 50%`; canvas ban đầu hoàn toàn trong suốt.
- Node chữ hoạt động như `<span>text</span>`. `width` / `height` của node ảnh là gợi ý trình bày (ưu
  tiên thấp nhất).

Trang [Hỗ trợ CSS](css-support.md) liệt kê mọi thuộc tính và giá trị được hỗ trợ.

## Tùy chọn render

| Tùy chọn | Kiểu | Mặc định | Ghi chú |
|:--|:--|:--|:--|
| `width`, `height` | number | kích thước sau layout của node gốc | Kích thước canvas tính bằng **pixel đầu ra** (cũng là viewport cho `%`, `vw`, `vh`, `@media`). Giá trị trên 16384 bị kẹp về 16384; `0` ném lỗi. Nếu bỏ trống: node gốc được dàn ở max-content theo trục đó và canvas lấy kích thước của nó. |
| `format` | `"png" \| "jpeg" \| "jpg" \| "webp" \| "ico" \| "raw"` | `"png"` | `ico` cần `full`. Giá trị khác ném `unsupported format: <x>`. |
| `quality` | number | 75 | Chỉ cho JPEG, kẹp trong 1–100. |
| `devicePixelRatio` | number | 1 | Nhân các độ dài px của CSS, cỡ chữ và kích thước gốc của ảnh; **không** đổi kích thước canvas. Giá trị ngoài khoảng (0, 64) bị bỏ qua. |
| `images` | `ImageSource[] \| { sources: ImageSource[] }` | | Các cặp `{ src, data }` mà tham chiếu `src` / `url()` tra cứu. `data` có thể nạp lười (chỉ với API async). |
| `css` | `(string \| rule object)[] \| string` | | Stylesheet (standard / full). Rule object có dạng `{ selector, style }`. |
| `stylesheets` | `string[]` | | Bí danh đã lỗi thời của `css` (dùng khi không có `css`). |
| `keyframes` | `{ [name]: { [offset]: Style } }` hoặc danh sách rule | | Keyframes cấp cao nhất kiểu cũ (đã lỗi thời). |
| `timeMs` | number | 0 | Vị trí trên dòng thời gian CSS animation (làm tròn xuống ms). Khi bỏ trống, animation được áp dụng ở t = 0. Chỉ `full`. |
| `fontFamilies` | `string[] \| string` | | Chồng `font-family` của node gốc. |
| `lang` | string | | Ngôn ngữ gốc cho `:lang()` và hệ ngôn ngữ OpenType. |
| `fonts` | `FontLoader[] \| Promise<FontLoader[]>` | | Chỉ với API async: được đăng ký trước khi render; nếu không có `fontFamilies`, chúng trở thành chồng font gốc. |
| `signal` | `AbortSignal` | | Được kiểm tra trước khi render (ném `signal.reason`). Bản thân việc render không thể ngắt giữa chừng. |
| `limits` | `Limits` | các mức trần có sẵn | Hạ giới hạn tài nguyên cho lần gọi này; xem [Giới hạn tài nguyên](#giới-hạn-tài-nguyên-cho-đầu-vào-không-tin-cậy). Cũng dùng được với `renderAnimation`, `measure`, `renderSvg` và `renderPdf`. |
| `lossless` | boolean | | Nhận nhưng bỏ qua: WebP luôn là lossless. |
| `drawDebugBorder`, `dithering` | | | Nhận nhưng bỏ qua. |

## Lỗi

Mọi lỗi đều là `Error` thông thường với thông báo bắt đầu bằng `bm-render: `.

| Tình huống | Hành vi |
|:--|:--|
| Giá trị không hợp lệ trong `style` inline (hoặc `preset`) | **ném lỗi**: `invalid value for style property width` |
| Khai báo không hợp lệ trong stylesheet (`css`, `<style>` của HTML) | khai báo đó bị bỏ, phần còn lại của luật vẫn áp dụng (cơ chế phục hồi lỗi của CSS) |
| Văn bản stylesheet không phân tích được | các luật hỏng bị bỏ; không báo lỗi |
| Class Tailwind lạ hoặc không hợp lệ | bỏ qua, không báo |
| Thuộc tính style lạ, khoá kebab-case | bỏ qua |
| `src` ảnh không tìm thấy / không giải mã được | không vẽ gì; ảnh có kích thước gốc 0 × 0 |
| Chữ không có font dùng được | không được vẽ; không báo lỗi |
| Tính năng không có trong binary đang nạp | ném lỗi với các dạng đầu vào cần nó: chuỗi HTML (`this build has no HTML input support ...`), `css` (`this build has no stylesheet (\`css\` option) support ...`), `tw` (`Tailwind (\`tw\`) is not supported by this build`), `format: "ico"`, `renderSvg`, `renderAnimation`, font WOFF, font CFF, hàm màu hiện đại trong style inline (`invalid value for style property ...`). Các thuộc tính khác của tính năng bị thiếu được nhận nhưng không có tác dụng (xem [Profile](../profiles-and-size.md#profile-nhỏ-xử-lý-đầu-vào-không-hỗ-trợ-thế-nào)). |
| Ảnh thô sai độ dài | ném `raw image data length must be width*height*4` |
| `{ json }` sai định dạng | ném `invalid node JSON` |
| `images[].data` nạp lười với method sync | ném `lazy images[].data() needs the async API` |

Engine không bao giờ trap với đầu vào hỏng; toàn bộ pipeline đã được fuzz trên bản build có bật kiểm tra
an toàn cho cả ba profile.

## Giới hạn

| Giới hạn | Giá trị |
|:--|:--|
| Độ sâu lồng node | 512 cấp (cấp 513 ném `node tree is nested too deeply`) |
| Canvas | tối đa 16384 px mỗi cạnh và 40 megapixel (`canvas too large`) |
| Nội dung rỗng mà không có `width`/`height` | ném `invalid viewport: content has zero size and no width/height was given` |
| Xuất ICO | 1–256 px mỗi cạnh |
| Animation | GIF ≤ 50 fps, WebP / APNG ≤ 90 fps; ≤ 512 MiB khung thô mỗi lần gọi |
| Ảnh đã giải mã | cache ảnh của mỗi renderer bị xoá khi vượt 96 MiB; một ảnh đã giải mã tối đa 24 megapixel (ảnh lớn hơn không được vẽ) |
| Cache mask glyph | 8 MiB mỗi renderer |
| Shadow stack của wasm | 1 MiB (build tùy biến: `-Dstack-kib=`) |

### Giới hạn tài nguyên cho đầu vào không tin cậy

Server render HTML, cây node hoặc ảnh do người dùng gửi lên có thể hạ một số giới hạn ở trên, để một
request không thể bắt engine giải mã một ảnh khổng lồ hay dàn một canvas khổng lồ. Truyền `limits` cho
hàm khởi tạo `Renderer` (mặc định của mọi lần gọi) và/hoặc cho từng lần gọi:

```ts
const r = new Renderer({ limits: { maxImagePixels: 4_000_000, maxImageBytes: 5 << 20, maxNodeDepth: 64 } });
await r.render(userHtml, { width: 1200, height: 630, limits: { maxCanvasPixels: 1200 * 630 } });
```

| Giới hạn | Áp dụng cho | Mức trần có sẵn (mặc định) | Khi vượt |
|:--|:--|:--|:--|
| `maxImagePixels` | rộng × cao của một nguồn ảnh raster (đã mã hoá hoặc RGBA thô), từng khung của ảnh động, và các `<image>` bên trong ảnh SVG | 25.165.824 (24 megapixel; 16 Mi bên trong SVG) | ảnh bị bỏ qua |
| `maxImageBytes` | số byte đã mã hoá của một nguồn ảnh: byte PNG / JPEG / WebP / GIF, `data:` URI sau khi giải mã, mã SVG | không có | ảnh bị bỏ qua |
| `maxAnimationFrames` | số khung của một nguồn GIF / WebP / APNG động | 10.000 | ảnh bị bỏ qua |
| `maxCanvasPixels` | rộng × cao của canvas đầu ra, kể cả từng khung của `renderAnimation` (không áp dụng cho trang PDF) | 40.000.000 | ném `canvas exceeds limits.maxCanvasPixels` |
| `maxNodeDepth` | số cấp lồng của cây node hoặc tài liệu HTML | 512 | ném `node tree exceeds limits.maxNodeDepth` |

Quy tắc:

- Giới hạn chỉ có thể **hạ xuống**. Giá trị lớn hơn mức trần có sẵn bị kẹp về mức trần; `limits` của
  một lần gọi không thể nâng giới hạn của renderer (với mỗi giới hạn, giá trị nhỏ hơn thắng; các giới
  hạn khác được gộp lại).
- Giá trị phải là số ≥ 1 (phần lẻ bị làm tròn xuống). Tên lạ, giá trị không phải số ≥ 1, hoặc `limits`
  không phải object sẽ ném lỗi (`unknown limit: limits.maxPixels`,
  `limit must be a number >= 1: limits.maxNodeDepth`, `limits must be an object`); hàm khởi tạo ném
  các lỗi này dưới dạng `TypeError`.
- Ảnh vượt giới hạn được xử lý như ảnh không giải mã được: không vẽ gì, kích thước gốc 0 × 0, và lần
  render vẫn thành công. Kích thước và số khung được đọc từ header của file, trước khi giải mã bất kỳ
  pixel nào. Ảnh đã được giải mã ở một lần gọi trước với giới hạn lỏng hơn vẫn bị từ chối.
  `renderPdf` / `measurePdf` thì báo lỗi, với `image exceeds limits.maxImagePixels` (hoặc tên giới hạn
  tương ứng), giống như với ảnh không giải mã được.
- Giới hạn gắn với từng lần gọi và từng renderer: các lần render đồng thời trên các renderer khác nhau
  (thread pool của native addon, worker thread) không bao giờ thấy giới hạn của nhau.
- Tùy chọn này không giới hạn file font và kích thước stylesheet: hãy tự đăng ký font và giới hạn kích
  thước nguồn trước khi gọi renderer.

## Bộ nhớ, instance và luồng

- **Một instance wasm cho mỗi điểm vào.** Mọi renderer tạo từ cùng một điểm vào dùng chung bộ nhớ tuyến
  tính của nó. `bm-render`, `bm-render/core`, `/standard` và `/full` mỗi cái có instance riêng, nên các
  profile khác nhau có thể cùng tồn tại trong một tiến trình.
- **Bộ nhớ tuyến tính chỉ tăng.** Bộ nhớ WebAssembly không thể co lại. Một phiên điển hình (đăng ký
  Inter, 50 lần render 1200 × 630) dùng khoảng 6 MiB; một lần render 3000 × 2000 đẩy lên khoảng 29 MiB và
  giữ nguyên mức đó kể cả sau `free()` — vùng đã giải phóng được các lần render sau dùng lại. Trong tiến
  trình chạy lâu, hãy giữ một số ít renderer sống lâu thay vì tạo mới cho mỗi request, và tránh thỉnh
  thoảng render canvas khổng lồ trong cùng instance với công việc hằng ngày.
- **Thứ gì nằm ở đâu.** Theo từng renderer: font (bytes bạn đã đăng ký), cache ảnh đã giải mã (bị xoá
  khi vượt 96 MiB), cache glyph (bị xoá khi vượt 8 MiB) và một canvas có kích thước của lần render gần
  nhất. Theo từng lần render: một bump arena được dùng lại giữa các lần render. `free()` trả toàn bộ bộ
  nhớ của renderer về bộ cấp phát của wasm.
- **Backend native (Node.js).** `init()` / `initSync()` không làm gì, `memoryBytes()` là lượng bộ nhớ addon
  đang cấp phát trong tiến trình (về 0 khi mọi thứ đã được giải phóng; garbage collector nhìn thấy nó), và
  các method async (`render`, `renderAsDataUrl`, `renderSvg`, `measure`, `renderAnimation`) chạy trên thread
  pool của libuv, đầu vào được sao chép ngay lúc gọi. Các lệnh trên **một** renderer chạy lần lượt, đúng thứ
  tự gọi; các renderer khác nhau chạy song song (tối đa `UV_THREADPOOL_SIZE`, mặc định 4). Addon cũng nạp
  được trong `worker_threads`. Chi tiết: [docs/NATIVE.md](../../NATIVE.md).
- **Luồng (wasm).** Binary là đơn luồng và API là đồng bộ: một lần render chặn luồng đang gọi (một thẻ
  1200 × 630 mất vài ms; xem [Benchmark](../benchmark.md)). Để chạy song song, hãy dùng một instance cho mỗi
  worker thread (`node:worker_threads`, Web Workers); mỗi worker tự import bm-render và đăng ký font riêng
  (đã kiểm chứng với `node:worker_threads`: bốn worker render song song). Không thể chia sẻ renderer và
  handle `Prepared` giữa các worker; hãy chuyển byte đầu ra.

## Add-on WOFF

```ts
import { loadWoff, decodeWoff } from "bm-render/woff";
loadWoff(input?: ByteBuf | WebAssembly.Module | URL | string | Request | Response | Promise<...>): Promise<{ builtIn: boolean }>
decodeWoff(bytes: ByteBuf): Uint8Array   // WOFF / WOFF2 -> TTF / OTF, after loadWoff()
```

`loadWoff()` khởi tạo `bm_woff.wasm` (84 KiB, không có import) và cài nó làm bộ chuyển đổi WOFF cho mọi
điểm vào trong tiến trình; sau đó `registerFont` nhận WOFF / WOFF2 kể cả trên `core`. Không có đối số thì
nó đọc file nằm cạnh module (Node) hoặc tải tương đối theo module (trình duyệt và bundler). Trên Workers
hãy truyền module: `import woff from "bm-render/woff.wasm"`. Giá trị `builtIn` trả về phản ánh
`features.woff` của điểm vào chung `bm-render`. `decodeWoff` ném `bm-render: invalid WOFF/WOFF2 font data`
khi đầu vào hỏng.

Không có add-on nào khác: xem [Profile và kích thước](../profiles-and-size.md#vì-sao-không-có-add-on-tải-lười-nào-khác).


## Xem thêm

Các trang hướng dẫn đi sâu vào từng chủ đề, kèm ví dụ chạy được và ảnh kết quả:
[Khái niệm](concepts.md) · [Style và layout](styles.md) · [HTML và Tailwind](html-and-tailwind.md) ·
[Font](fonts.md) · [Typography](typography.md) · [Ảnh](images.md) · [Bảng và float](tables.md) ·
[Hiệu ứng](effects.md) · [Định dạng đầu ra](formats.md) · [Animation](animation.md) · [measure()](measure.md) ·
[Biểu đồ](charts.md) · [Mẫu](templates.md) · [Hiệu năng](performance.md)
