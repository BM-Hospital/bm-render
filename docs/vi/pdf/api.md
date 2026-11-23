# Tham chiếu API PDF

[English](../../en/pdf/api.md) · [Tiếng Việt](api.md)

Mọi thứ mà `bm-render/pdf` export, với chữ ký đúng như trong `js/pdf.d.mts` và `js/pdf-types.d.mts`, cùng
các lỗi mà từng lời gọi ném ra. Định dạng node, `registerFont` và những phần dùng chung với đầu ra ảnh chỉ
được mô tả một lần, trong [tham chiếu API ảnh](../image/api.md). Mọi đoạn mã là một phần của
`docs/examples/pdf-api.mjs` trong repository và đã được chính file đó chạy trên addon native và trên
WebAssembly (`BM_RENDER_BACKEND=wasm`), cho cùng một kết quả.

- [Các export của module](#module-exports)
- [`PdfRenderer`](#pdfrenderer)
- [Nguồn đầu vào](#sources)
- [`render`, `measure` và `prepare` ở cấp module](#module-level-render-measure-and-prepare)
- [`Renderer.renderPdf` và `measurePdf`](#rendererrenderpdf-and-measurepdf)
- [Tùy chọn render](#render-options)
- [Tùy chọn measure](#measure-options)
- [Bộ đếm trang](#page-counters)
- [Lỗi](#errors)
- [Kiểu dữ liệu](#types)

## Các export của module {#module-exports}

<!-- @example pdf-api#exports -->
```js
import * as pdfEntry from "bm-render/pdf";

pdfEntry.profile;      // "pdf"
pdfEntry.features.pdf; // true (and every other feature of the full profile)
pdfEntry.backend;      // "native" with the platform package on Node.js, else "wasm"
```

| Export | Kiểu | Ý nghĩa |
|:--|:--|:--|
| `PdfRenderer` | class | Renderer giữ các font đã đăng ký và ghi ra file PDF ([bên dưới](#pdfrenderer)). |
| `render`, `measure`, `prepare` | hàm | Các method tương ứng trên một `PdfRenderer` dùng chung, được tạo khi cần ([bên dưới](#module-level-render-measure-and-prepare)). |
| `PageNumber`, `TotalPages`, `TargetPageNumber` | hàm | Node bộ đếm trang cho header, footer và tham chiếu chéo ([bên dưới](#page-counters)). |
| `init(input?)`, `default` | `Promise<WasmExports>` | Nạp binary wasm. Trên Node.js entry đã sẵn sàng ngay khi import và `init()` trả về ngay; trong trình duyệt `await init()` tải `bm_render.pdf.wasm` nằm cạnh module, hoặc bạn tự truyền binary. |
| `initSync(input)` | `WasmExports` | `init` đồng bộ với bytes hoặc một `WebAssembly.Module`. |
| `wasmUrl()` | `URL` | URL mà `init()` nạp mặc định. |
| `profile` | `"pdf"` | Profile build của entry, kể cả trên backend native. |
| `backend` | `"native" \| "wasm"` | Engine nào đang phục vụ entry ([Native và WebAssembly](native-and-wasm.md)). |
| `features` | object | Build đang nạp có những gì; `features.pdf` chỉ là `true` ở đây. |
| `Renderer`, `Prepared`, `setGlyphCacheMaxBytes`, `setWoffDecoder` | | API ảnh của cùng instance module ([tham chiếu API ảnh](../image/api.md)). `Renderer` của nó có thêm [`renderPdf`](#rendererrenderpdf-and-measurepdf). |

Entry này có instance module riêng: font đăng ký trên một `Renderer` của `bm-render` không được
`bm-render/pdf` nhìn thấy. Phần định nghĩa kiểu còn export mọi kiểu của `bm-render` và của `pdf-types.d.mts`
([Kiểu dữ liệu](#types)).

## `PdfRenderer` {#pdfrenderer}

```ts
class PdfRenderer {
  constructor(options?: RendererOptions);
  registerFont(font: ByteBuf | SyncFontDetails): RegisteredFamily[];
  registerFont(font: FontLoader | Promise<FontLoader>): RegisteredFamily[] | Promise<RegisteredFamily[]>;
  loadFont(font): /* same as registerFont */;
  unregisterFont(family: string | { name: string }): boolean;
  clearFonts(): void;
  prepare(source: Source, options?: PdfRenderOptions): Promise<Prepared>;
  render(source: PdfSource, options?: PdfRenderOptions): Promise<Uint8Array>;
  renderSync(source: PdfSource, options?: PdfRenderOptions): Uint8Array;
  measure(source: PdfSource, options?: PdfMeasureOptions): Promise<{ width: number; height: number }>;
  measureSync(source: PdfSource, options?: PdfMeasureOptions): { width: number; height: number };
  free(): void;
  [Symbol.dispose](): void;
}
```

`PdfRenderer` bọc một `Renderer` ảnh của instance `bm-render/pdf`; hàm khởi tạo nhận cùng
`RendererOptions` ([tham chiếu API ảnh](../image/api.md#hàm-khởi-tạo)). Hãy tạo một instance, đăng ký font,
rồi dùng lại nó cho mọi tài liệu.

### Font {#fonts}

<!-- @example pdf-api#renderer -->
```js
import { readFileSync } from "node:fs";
import { PdfRenderer } from "bm-render/pdf";

const pdf = new PdfRenderer();
const families = pdf.registerFont({ name: "Inter", data: readFileSync("assets/fonts/Inter-Regular.ttf") });
// [{ name: "Inter", faces: [{ weight: 400, style: "normal", width: 100, index: 0 }], weight: 400, style: "normal" }]
pdf.loadFont({ name: "Inter", data: readFileSync("assets/fonts/Inter-Bold.ttf") }); // loadFont = registerFont
```

`renderPdf` là bí danh của `render` trên `PdfRenderer`.

<!-- @example pdf-api#fonts-admin -->
```js
pdf.unregisterFont("Inter");   // true: the family was registered
pdf.unregisterFont("Missing"); // false
pdf.clearFonts();              // removes every registered font
```

bm-render không kèm font nào và không bao giờ đọc font hệ thống. Khi **chưa đăng ký font nào cả**, chữ
không được vẽ và lần render không báo lỗi; khi đã có ít nhất một font, một ký tự mà không font nào vẽ được
sẽ làm render thất bại theo mặc định ([Font trong PDF](fonts.md#ký-tự-không-font-nào-có)):

<!-- @example pdf-api#no-fonts -->
```js
const empty = new PdfRenderer(); // no font registered at all
const silent = await empty.render(`<p>Hello</p>`);
// no error, and the page has no text: register a font (or pass `fonts`) before rendering text
```

### `render` và `renderSync` {#render-and-rendersync}

<!-- @example pdf-api#render -->
```js
const html = `<h1 style="font-family: Inter">Invoice 2041</h1><p style="font-family: Inter">Due in 30 days.</p>`;
const bytes = await pdf.render(html);      // Promise<Uint8Array>, paged A4
const same = pdf.renderSync(html);         // Uint8Array
new TextDecoder().decode(bytes.subarray(0, 5)); // "%PDF-"
```

Cả hai trả về trọn file PDF dưới dạng `Uint8Array`. Không có tùy chọn thì đầu ra được phân trang: A4, lề
`"auto"` (10 mm), nội dung chảy sang bao nhiêu trang tùy nhu cầu ([Phân trang](pagination.md)). Trên backend
native, `render` chạy trên thread pool của libuv; trên WebAssembly nó chạy trên luồng gọi dù là bản nào. Chỉ
bản async mới chờ tùy chọn `fonts` và `images` nạp lười: `renderSync` bỏ qua `fonts`.

<!-- @example pdf-api#sync-fonts -->
```js
const viaSync = new PdfRenderer().renderSync(`<p style="font-family: Inter">Hello</p>`, {
  fonts: [{ name: "Inter", data: readFileSync("assets/fonts/Inter-Regular.ttf") }],
});
// the sync methods ignore `fonts`: this page has no text. Use registerFont, or the async render.
```

### `measure` và `measureSync` {#measure-and-measuresync}

`measure(source, options)` dàn trang nguồn mà không ghi PDF và trả về `{ width, height }` theo CSS px. Với
tùy chọn trang (hoặc không có gì: A4), nó dàn trang ở toàn bộ chiều rộng trang với chiều cao không giới hạn,
giống cách một band header hay footer được dàn trang, với bộ đếm trang ba chữ số; lề không bao giờ làm đổi
kết quả. Với `viewport`, nó dàn trang theo chiều rộng của viewport.

<!-- @example pdf-api#measure -->
```js
const block = `<div style="height: 120px; font-family: Inter">Band</div>`;
await pdf.measure(block, { size: "a4" });                    // { width: 793, height: 120 }: full A4 width in CSS px
await pdf.measure(block, { size: "letter", landscape: true }); // { width: 1056, height: 120 }
await pdf.measure(block, { viewport: { width: 300 } });      // { width: 300, height: 120 }
pdf.measureSync(block);                                      // A4 by default; margins never change the result
```

Dùng nó để đo một band trước khi đặt lề ([Lề và band](headers-footers.md#lề-và-band)).

### `prepare` {#prepare}

`prepare(source, options)` nạp tài nguyên một lần rồi trả về handle `Prepared` cho `render` và `measure`. Các tùy chọn của `render` được gộp đè lên tùy chọn của `prepare`. Bước này phân tích tài liệu và các band để nạp font subset, file `@font-face` và ảnh còn thiếu. Cấu hình `images.fetch` để kiểm soát việc tải ảnh; xem [font trong PDF](fonts.md) và đăng ký font rõ ràng để tránh thiếu chữ.

<!-- @example pdf-api#prepare -->
```js
const prepared = await pdf.prepare(html, { size: "a5" });
const a5 = await pdf.render(prepared, { margin: 24 }); // options merge over the prepare() options: A5, 24 px margins
```

### `free` và `[Symbol.dispose]` {#free-and-symboldispose}

<!-- @example pdf-api#free -->
```js
{
  using scoped = new PdfRenderer(); // freed at the end of the block ([Symbol.dispose])
  scoped.renderSync(`<div style="width: 10px; height: 10px"></div>`, { viewport: { width: 10 } });
}
const done = new PdfRenderer();
done.free();
// done.renderSync(...) now throws "bm-render: renderer has been freed"
```

## Nguồn đầu vào {#sources}

`PdfSource` là một `Source` hoặc một handle `Prepared`. `Source` là một chuỗi HTML, một cây node, hoặc
`{ json: "<cây node dạng văn bản JSON>" }`, y như với ảnh ([Định dạng node](../image/api.md#định-dạng-node)).
Phần tử JSX / React cũng được chấp nhận, làm tài liệu lẫn làm band header hoặc footer: nó được chuyển thành HTML.
Component chạy một lần mà không có React dispatcher, nên các hook ngoài việc đọc đơn thuần không hoạt động.

<!-- @example pdf-api#sources -->
```js
const fromTree = await pdf.render({ type: "text", text: "From a node tree", style: { fontFamily: "Inter" } });
const fromJson = await pdf.render({ json: '{"type":"text","text":"From JSON text","style":{"fontFamily":"Inter"}}' });
```

## `render`, `measure` và `prepare` ở cấp module {#module-level-render-measure-and-prepare}

`render(source, options?)`, `measure(source, options?)` và `prepare(source, options?)` gọi các method cùng
tên trên một `PdfRenderer` dùng chung, được tạo ở lần dùng đầu tiên. Bạn không chạm được vào nó để đăng ký
font, nên hãy dùng chúng cho tài liệu không có chữ, hoặc truyền font qua tùy chọn `fonts`:

<!-- @example pdf-api#module-level -->
```js
import { render, measure } from "bm-render/pdf";

const plain = await render(`<div style="width: 200px; height: 100px; background: #0ea5e9"></div>`, {
  viewport: { width: 200 },
});
const withFont = await render(`<p style="font-family: Inter">Hello</p>`, {
  fonts: [{ name: "Inter", data: readFileSync("assets/fonts/Inter-Regular.ttf") }], // registered before the render
});
await measure(`<div style="width: 200px; height: 100px"></div>`, { viewport: { width: 200 } }); // { width: 200, height: 100 }
```

Font truyền qua `fonts` vẫn được đăng ký trên renderer dùng chung cho các lần gọi sau.

## `Renderer.renderPdf` và `measurePdf` {#rendererrenderpdf-and-measurepdf}

Mọi `Renderer` đều có `renderPdf`, `renderPdfSync`, `measurePdf` và `measurePdfSync`, với tham số và kết quả
giống `PdfRenderer.render` / `renderSync` / `measure` / `measureSync` (`PdfRenderer` chỉ là một lớp bọc mỏng
quanh chúng). Chúng chạy được trên `Renderer` mà `bm-render/pdf` export:

<!-- @example pdf-api#renderer-methods -->
```js
import { Renderer } from "bm-render/pdf";

const r = new Renderer();
const viaRenderer = await r.renderPdf(`<div style="width: 40px; height: 40px; background: red"></div>`, {
  viewport: { width: 40 },
});
r.measurePdfSync(`<div style="width: 40px; height: 40px"></div>`, { viewport: { width: 40 } }); // { width: 40, height: 40 }
```

Trên mọi build khác chúng đều ném lỗi, kể cả `bm-render` khi chạy trên addon native:

<!-- @example pdf-api#other-builds -->
```js
import { Renderer as FullRenderer } from "bm-render/full";

let unsupported;
try {
  new FullRenderer().renderPdfSync(`<p>x</p>`);
} catch (e) {
  unsupported = e.message;
}
// bm-render: renderPdf is not supported by this build (use the pdf build: import from "bm-render/pdf")
```

## Tùy chọn render {#render-options}

`PdfRenderOptions` thuộc một trong hai dạng: **phân trang** (mặc định) hoặc **viewport** (một trang); hai
nhóm này loại trừ nhau. Mọi tùy chọn đều không bắt buộc.

| Tùy chọn | Kiểu | Mặc định | Ý nghĩa | Chi tiết |
|:--|:--|:--|:--|:--|
| `size` | `PageSizeName \| { width, height }` | `"a4"` | Khổ giấy: một tên (`a3`, `a4`, `a5`, `b4`, `b5`, `jis-b4`, `jis-b5`, `ledger`, `legal`, `letter`, không phân biệt hoa thường, khổ dọc) hoặc kích thước theo CSS px. `@page { size }` của tài liệu được ưu tiên. | [Khổ giấy](page-size-and-viewport.md) |
| `landscape` | `boolean` | `false` | Đổi chỗ chiều rộng và chiều cao, kể cả với kích thước tự đặt. | [Khổ giấy](page-size-and-viewport.md) |
| `margin` | `number \| "auto" \| { top?, right?, bottom?, left? }` | `"auto"` | CSS px cho từng cạnh; cạnh bỏ trống là `"auto"`: 10 mm (37.8 px), hoặc cao đúng bằng band ở cạnh đó cần. | [Lề và band](headers-footers.md#lề-và-band) |
| `header`, `footer` | `Node \| string \| false` | không có | Band lặp lại ở đầu / cuối mọi trang; các class `pageNumber` / `totalPages` nhận bộ đếm. | [Header và footer](headers-footers.md) |
| `pages` | `{ first?, last?, odd?, even? }` gồm `{ header?, footer? }` | không có | Band thay cho band của tài liệu ở một số trang; `first` và `last` thắng `odd` và `even`. | [Band khác nhau](headers-footers.md#band-khác-nhau-ở-một-số-trang) |
| `pageRanges` | `(number \| { from?, to? })[]` | mọi trang | Các trang mà file giữ lại, đánh số từ 1; bộ đếm giữ số của tài liệu đầy đủ. | [Giữ lại một số trang](pagination.md#giữ-lại-một-số-trang) |
| `viewport` | `{ width, height? }` | không có | Một trang đúng kích thước đó theo CSS px, không lề, không band; thiếu `height` thì trang cao bằng nội dung. Loại trừ mọi tùy chọn ở trên. | [Một trang](page-size-and-viewport.md) |
| `backgroundColor` | `string` (màu CSS) | không có | Màu giấy, vẽ bên dưới mọi thứ trên mọi trang. | [Khổ giấy](page-size-and-viewport.md) |
| `css` | `string \| string[]` | không có | Stylesheet áp dụng trước khi dàn trang (cả với cây node). | [HTML và Tailwind](../image/html-and-tailwind.md) |
| `cssVariables` | `Record<string, string>` | không có | Custom property của `:root`; tên thiếu `--` sẽ được thêm vào. | [HTML và Tailwind](../image/html-and-tailwind.md) |
| `fontFamilies` | `string[]` | không có | Font stack gốc, chuỗi fallback cho phần tử không có `font-family`. | [Font dự phòng](fonts.md#font-dự-phòng) |
| `fonts` | `FontLoader[] \| Promise<FontLoader[]>` | không có | Font được đăng ký trước khi render (chỉ các method async). | [Font trong PDF](fonts.md) |
| `images` | `ImagesInput` | không có | Bytes ảnh cho các khóa `src` của tài liệu và các band. Chỉ `prepare` mới tải ảnh từ xa. | [Hình ảnh](../image/images.md) |
| `uncoveredText` | `"error" \| "placeholder" \| "blank"` | `"error"` | Ký tự không font nào vẽ được sẽ thành gì. | [Ký tự không font nào có](fonts.md#ký-tự-không-font-nào-có) |
| `lang` | `string` (BCP 47) | không có | Ngôn ngữ của phần tử gốc và của metadata. | [Metadata](links-metadata.md#metadata) |
| `metadata` | `PdfMetadata` | không có | `title`, `description`, `authors`, `keywords`, `creator`, `creationDate`, các schema `xmp` tùy biến. | [Metadata](links-metadata.md#metadata), [XMP tùy biến](links-metadata.md#xmp-tùy-biến) |
| `outline` | `boolean` | `false` | Bookmark tạo từ `h1`-`h6`. | [Bookmark](links-metadata.md#bookmark) |
| `attachments` | `Attachment[]` | không có | File đính kèm (`name`, `data`, `mimeType?`, `description?`, `relationship?`, `modificationDate?`). | [Tệp đính kèm](links-metadata.md#tệp-đính-kèm) |
| `tagged` | `boolean \| "ua1" \| "ua2"` | `true` | Cây cấu trúc; `"ua1"` / `"ua2"` còn kiểm tra theo PDF/UA-1 / PDF/UA-2. | [PDF có thẻ](accessibility.md#pdf-có-thẻ), [PDF/UA](accessibility.md#pdfua) |
| `pdfa` | `"2a" \| "2b" \| "2u" \| "3a" \| "3b" \| "3u" \| "4" \| "4f"` | không có | Mức PDF/A, có kiểm tra; vi phạm làm render thất bại. | [PDF/A](accessibility.md#pdfa) |
| `signal` | `AbortSignal` | không có | Được kiểm tra trước khi render đọc và vẽ tài liệu. | [Lỗi](#errors) |
| `limits` | `Limits` | các mức trần có sẵn | Giới hạn tài nguyên của bm-render cho đầu vào không tin cậy (`maxImagePixels`, `maxImageBytes`, `maxAnimationFrames`, `maxNodeDepth`; `maxCanvasPixels` không áp dụng cho trang). Cũng là tùy chọn của hàm khởi tạo `PdfRenderer`; một lần gọi chỉ có thể hạ nó. Ảnh vượt giới hạn làm render thất bại với `image exceeds limits.<tên>`. | [Giới hạn tài nguyên](../image/api.md#giới-hạn-tài-nguyên-cho-đầu-vào-không-tin-cậy) |

Những tổ hợp `pdfa`, `tagged` và `attachments` mà không phiên bản PDF nào cho phép là lỗi kiểu và cũng là lỗi
lúc chạy; bảng đầy đủ nằm ở [Phiên bản và tổ hợp](accessibility.md#phiên-bản-và-tổ-hợp). Tên tùy chọn lạ bị
bỏ qua, nên hãy kiểm tra chính tả: `{ sise: "a4" }` vẫn render khổ A4.

## Tùy chọn measure {#measure-options}

`PdfMeasureOptions` nhận `size` và `landscape`, hoặc `viewport`, cộng với các tài nguyên dàn trang `fonts`,
`images`, `css`, `cssVariables`, `fontFamilies`, `lang`, `limits` và `signal`. Định nghĩa kiểu bỏ ra ngoài `margin`,
các band và mọi tùy chọn đầu ra, vì chúng không làm đổi kích thước đo được; lúc chạy, `margin` vẫn được nhận
và bị bỏ qua, nhưng `viewport` đi cùng `size` hoặc `landscape` ném đúng lỗi "mutually exclusive" như `render`.

## Bộ đếm trang {#page-counters}

```ts
function PageNumber(props?: CounterProps): ContainerNode;
function TotalPages(props?: CounterProps): ContainerNode;
function TargetPageNumber(props?: CounterProps & { href?: string }): ContainerNode;
type CounterProps = { format?: CounterStyle; className?: string; style?: Style; tw?: string };
```

Chúng trả về các object node bình thường: một `span` mang class móc (`pageNumber`, `totalPages`,
`targetPageNumber`), theo sau là `format` và `className` của bạn. Trong band `header` hoặc `footer` và trong
một hộp `position: fixed`, `PageNumber` hiện số của từng trang; trong luồng nội dung nó hiện số của trang mà
nó rơi vào. `TargetPageNumber` hiện số trang của đích một liên kết: không có `href` thì nó đọc thẻ `<a>`
bao quanh gần nhất, có `href` thì nó tự render liên kết của mình. Trong HTML, bạn tự viết các class này
(`<span class="pageNumber"></span>`).

<!-- @example pdf-api#counters -->
```js
import { PageNumber, TotalPages, TargetPageNumber } from "bm-render/pdf";

PageNumber({ format: "upper-roman", style: { color: "#64748b" } });
// { type: "container", tagName: "span", style: { color: "#64748b" }, className: "pageNumber upper-roman" }
TotalPages();
// { type: "container", tagName: "span", className: "totalPages" }
TargetPageNumber({ href: "#totals" });
// { type: "container", tagName: "a", attributes: { href: "#totals" },
//   children: [{ type: "container", tagName: "span", className: "targetPageNumber" }] }
```

<!-- @example pdf-api#counters-footer -->
```js
const report = Array.from({ length: 60 }, (_, k) => `<p>Line ${k + 1}</p>`).join("");
const numbered = await pdf.render(`<div style="font-family: Inter">${report}</div>`, {
  footer: {
    type: "container",
    style: { display: "flex", justifyContent: "center", columnGap: 4, fontFamily: "Inter", fontSize: 10 },
    children: [{ type: "text", text: "Page" }, PageNumber(), { type: "text", text: "of" }, TotalPages()],
  },
}); // "Page 1 of 3", "Page 2 of 3", ... (flex items: the gap makes the spaces)
```

Trong một hàng flex, mỗi node text là một flex item, và khoảng trắng ở hai đầu flex item bị bỏ đi như trong
CSS, nên `"Page "` sẽ in ra `Page1`: hãy dùng `columnGap` (như ở đây) hoặc một khối block với các con inline.

`CounterStyle`, các giá trị của `format` (mặc định `decimal`): `decimal`, `decimal-leading-zero`,
`lower-roman`, `upper-roman`, `lower-alpha`, `lower-latin`, `upper-alpha`, `upper-latin`, `lower-greek`,
`hiragana`, `katakana`, `trad-chinese-informal`, `cjk-ideographic`, `cjk-decimal`, `arabic-indic`,
`bengali`, `cambodian`, `khmer`, `devanagari`, `gujarati`, `gurmukhi`, `kannada`, `lao`, `malayalam`,
`mongolian`, `myanmar`, `oriya`, `persian`, `urdu`, `tamil`, `telugu`, `thai`, `tibetan`. Bộ đếm CSS trong nội
dung sinh ra (`content: counter(page)`, `target-counter()`) cũng hoạt động; xem
[Header, footer và bộ đếm trang](headers-footers.md).

## Lỗi {#errors}

Mọi lỗi đều là một `Error` có thông điệp bắt đầu bằng `bm-render:`, trừ một lần render bị hủy: khi đó
promise bị từ chối với lý do của signal (một `DOMException` tên `AbortError` khi gọi `controller.abort()`):

<!-- @example pdf-api#abort -->
```js
const controller = new AbortController();
controller.abort();
try {
  await pdf.render(html, { signal: controller.signal });
} catch (e) {
  e.name; // "AbortError" (a DOMException): the render did not start
}
```

Giá trị của các tùy chọn được kiểm tra trước khi dàn trang; thông điệp lỗi nêu tên tùy chọn:

<!-- @example pdf-api#errors -->
```js
const messageOf = async (options, source = html) => {
  try {
    await pdf.render(source, options);
    return "ok";
  } catch (e) {
    return e.message;
  }
};
await messageOf({ size: "tabloid" });
// bm-render: unknown page size: tabloid
await messageOf({ margin: "1in" });
// bm-render: invalid margin: expected a number or "auto"
await messageOf({ viewport: { width: 300 }, size: "a4" });
// bm-render: viewport is mutually exclusive with the paged options (size, landscape, margin, header, footer, pages, pageRanges)
await messageOf({ pageRanges: [{ from: 5, to: 2 }] });
// bm-render: Page range is invalid: 5-2. Pages are numbered from 1.
await messageOf({ pdfa: "1b" });
// bm-render: unknown variant `1b`, expected one of `2a`, `3a`, `2b`, `2u`, `3b`, `3u`, `4`, `4f`
await messageOf({ backgroundColor: "paper" });
// bm-render: backgroundColor is not a color: paper
await messageOf({ sise: "a4" });
// "ok": an unknown option name is ignored
```

Script ví dụ kiểm tra từng thông điệp dưới đây (phần chữ sau `bm-render: `):

| Nguyên nhân | Thông điệp |
|:--|:--|
| `size: "tabloid"` | `unknown page size: tabloid` |
| `size: { width: 10 }` | `invalid size: expected a preset name or { width, height }` |
| `margin: "1in"` | `invalid margin: expected a number or "auto"` |
| lề không chừa lại vùng trang nào | `Page size must be finite and larger than zero` |
| `landscape: "yes"` | `invalid landscape: expected a boolean` |
| `viewport` đi cùng một tùy chọn phân trang | `viewport is mutually exclusive with the paged options (size, landscape, margin, header, footer, pages, pageRanges)` |
| `viewport: { height: 300 }` | `invalid viewport: width is required` |
| `viewport: { width: 0 }` | `invalid viewport: width/height must be > 0` |
| `viewport` không có `height` và nội dung cao bằng 0 | `invalid viewport: content has zero size and no width/height was given` |
| `header: 5` | no error: a number band is written as text-js does |
| `pages: { middle: {} }` | `unknown page rule: middle` |
| `pages: { first: { body: "x" } }` | `unknown field of pages.first: body` |
| `pageRanges: 3` | `invalid pageRanges: expected an array of page numbers or { from, to } spans` |
| `pageRanges: [0]` | `Page range is invalid: 0. Pages are numbered from 1.` |
| `pageRanges: [{ from: 5 }]` với tài liệu 1 trang | `The page ranges select none of the document's 1 pages` |
| `pdfa: "1b"` | `` unknown variant `1b`, expected one of `2a`, `3a`, `2b`, `2u`, `3b`, `3u`, `4`, `4f` `` |
| `tagged: "ua3"` | `data did not match any variant of untagged enum TaggedInput` |
| `uncoveredText: "skip"` | `unknown uncoveredText: skip` |
| `outline: "yes"` | `invalid outline: expected a boolean` |
| `lang: 5` | `invalid lang: expected a string` |
| `backgroundColor: 5` / `"paper"` | `invalid backgroundColor: expected a string` / `backgroundColor is not a color: paper` |
| `cssVariables: "x"` / `{ accent: 1 }` | `invalid cssVariables: expected an object of strings` / `invalid cssVariables: expected a string` |
| `metadata: "x"` | `invalid metadata: expected an object` |
| `metadata: { creationDate: "2026/01/01" }` | `invalid creationDate: expected YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS` |
| `attachments: {}` | `attachments takes an array` (một `TypeError`) |
| tệp đính kèm thiếu `name` | ``missing field `name` `` |
| `data: 5` | `attachment data must be bytes or a string: <name>` |
| `relationship: "parent"` | ``unknown variant `parent`, expected one of `source`, `data`, `alternative`, `supplement`, `unspecified` `` |
| `mimeType: "plain"` | `Attachment mime type is not a type/subtype pair: plain` |
| một ký tự không font đã đăng ký nào vẽ được (`uncoveredText: "error"`) | `No font the text can use draws 日 (U+65E5). Check each font's unicodeRange and the font-family stack, or register a font that draws them.` |
| `filter: blur(2px)` trong tài liệu | `A PDF cannot draw filter: blur(2px)` |
| gọi trên renderer đã free | `renderer has been freed` |
| `renderPdf` trên build khác | `renderPdf is not supported by this build (use the pdf build: import from "bm-render/pdf")` |

Các vi phạm PDF/A và PDF/UA, những tổ hợp chuẩn không thể có và thông điệp của chúng được liệt kê ở
[Phiên bản và tổ hợp](accessibility.md#phiên-bản-và-tổ-hợp).

## Kiểu dữ liệu {#types}

`js/pdf-types.d.mts` (được `bm-render/pdf` export lại) định nghĩa `PdfRenderOptions`, `PdfMeasureOptions`,
`MeasuredSize` (`{ width, height }` theo CSS px), `PageSizeName`, `PageSize`, `Dimensions`,
`ViewportInput`, `PageMargin`, `PageMarginSide`, `Band`, `PageOverride`, `PageRules`, `PageRange`,
`PdfMetadata`, `XmpSchema`, `XmpProperty`, `Attachment`, `ArchivalAttachment` (tệp đính kèm có `mimeType` và
`description` mà các mức PDF/A-3 yêu cầu), `Pdfa`, `Tagged`, `UncoveredText` và `PdfPrepared`. `js/pdf.d.mts`
thêm `PdfSource`, `CounterStyle` và `CounterProps`. `render` và `renderSync` được khai báo kiểu trả về là
`OutputBytes` (một `Uint8Array`).
