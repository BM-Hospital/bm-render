# PDF API reference

[English](api.md) · [Tiếng Việt](../../vi/pdf/api.md)

Everything `bm-render/pdf` exports, with the exact signatures of `js/pdf.d.mts` and `js/pdf-types.d.mts`
and the errors the calls throw. The node format, `registerFont` and the other parts shared with image
output are described once, in the [image API reference](../image/api.md). Every snippet is a section of
`docs/examples/pdf-api.mjs` in the repository and was executed by it on the native addon and on
WebAssembly (`BM_RENDER_BACKEND=wasm`), with the same results.

- [Module exports](#module-exports)
- [`PdfRenderer`](#pdfrenderer)
- [Sources](#sources)
- [Module-level `render`, `measure` and `prepare`](#module-level-render-measure-and-prepare)
- [`Renderer.renderPdf` and `measurePdf`](#rendererrenderpdf-and-measurepdf)
- [Render options](#render-options)
- [Measure options](#measure-options)
- [Page counters](#page-counters)
- [Errors](#errors)
- [Types](#types)

## Module exports

<!-- @example pdf-api#exports -->
```js
import * as pdfEntry from "bm-render/pdf";

pdfEntry.profile;      // "pdf"
pdfEntry.features.pdf; // true (and every other feature of the full profile)
pdfEntry.backend;      // "native" with the platform package on Node.js, else "wasm"
```

| Export | Type | Meaning |
|:--|:--|:--|
| `PdfRenderer` | class | A renderer that holds registered fonts and writes PDF files ([below](#pdfrenderer)). |
| `render`, `measure`, `prepare` | functions | The same methods on one shared, lazily created `PdfRenderer` ([below](#module-level-render-measure-and-prepare)). |
| `PageNumber`, `TotalPages`, `TargetPageNumber` | functions | Page counter nodes for headers, footers and cross references ([below](#page-counters)). |
| `init(input?)`, `default` | `Promise<WasmExports>` | Loads the wasm binary. On Node.js the entry is ready on import and `init()` returns at once; in browsers `await init()` fetches `bm_render.pdf.wasm` next to the module, or pass the binary. |
| `initSync(input)` | `WasmExports` | Synchronous `init` with bytes or a `WebAssembly.Module`. |
| `wasmUrl()` | `URL` | The URL `init()` loads by default. |
| `profile` | `"pdf"` | Build profile of the entry, also on the native backend. |
| `backend` | `"native" \| "wasm"` | Which engine serves the entry ([Native and WebAssembly](native-and-wasm.md)). |
| `features` | object | What the loaded build contains; `features.pdf` is `true` only here. |
| `Renderer`, `Prepared`, `setGlyphCacheMaxBytes`, `setWoffDecoder` | | The image API of the same module instance ([image API reference](../image/api.md)). Its `Renderer` also has [`renderPdf`](#rendererrenderpdf-and-measurepdf). |

The entry has its own module instance: fonts registered on a `Renderer` of `bm-render` are not seen by
`bm-render/pdf`. The type definitions also export every type of `bm-render` and of `pdf-types.d.mts`
([Types](#types)).

## `PdfRenderer`

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

`PdfRenderer` wraps one image `Renderer` of the `bm-render/pdf` instance; the constructor takes the same
`RendererOptions` ([image API reference](../image/api.md#constructor)). Create one, register fonts, and
reuse it for every document.

### Fonts

<!-- @example pdf-api#renderer -->
```js
import { readFileSync } from "node:fs";
import { PdfRenderer } from "bm-render/pdf";

const pdf = new PdfRenderer();
const families = pdf.registerFont({ name: "Inter", data: readFileSync("assets/fonts/Inter-Regular.ttf") });
// [{ name: "Inter", faces: [{ weight: 400, style: "normal", width: 100, index: 0 }], weight: 400, style: "normal" }]
pdf.loadFont({ name: "Inter", data: readFileSync("assets/fonts/Inter-Bold.ttf") }); // loadFont = registerFont
```

`renderPdf` is an alias for `render` on `PdfRenderer`.

<!-- @example pdf-api#fonts-admin -->
```js
pdf.unregisterFont("Inter");   // true: the family was registered
pdf.unregisterFont("Missing"); // false
pdf.clearFonts();              // removes every registered font
```

bm-render ships no font and never reads system fonts. When **no font at all** is registered, text is
not drawn and the render does not fail; with at least one font, a character that no font draws fails
the render by default ([Fonts in PDF](fonts.md#characters-no-font-covers)):

<!-- @example pdf-api#no-fonts -->
```js
const empty = new PdfRenderer(); // no font registered at all
const silent = await empty.render(`<p>Hello</p>`);
// no error, and the page has no text: register a font (or pass `fonts`) before rendering text
```

### `render` and `renderSync`

<!-- @example pdf-api#render -->
```js
const html = `<h1 style="font-family: Inter">Invoice 2041</h1><p style="font-family: Inter">Due in 30 days.</p>`;
const bytes = await pdf.render(html);      // Promise<Uint8Array>, paged A4
const same = pdf.renderSync(html);         // Uint8Array
new TextDecoder().decode(bytes.subarray(0, 5)); // "%PDF-"
```

Both return the complete PDF file as a `Uint8Array`. Without options the output is paged: A4, `"auto"`
margins (10 mm), content flowing onto as many pages as it needs ([Pagination](pagination.md)). On the
native backend `render` runs on the libuv thread pool; on WebAssembly it runs on the calling thread
either way. Only the async form awaits the `fonts` option and lazy `images`: `renderSync` ignores
`fonts`.

<!-- @example pdf-api#sync-fonts -->
```js
const viaSync = new PdfRenderer().renderSync(`<p style="font-family: Inter">Hello</p>`, {
  fonts: [{ name: "Inter", data: readFileSync("assets/fonts/Inter-Regular.ttf") }],
});
// the sync methods ignore `fonts`: this page has no text. Use registerFont, or the async render.
```

### `measure` and `measureSync`

`measure(source, options)` lays the source out without writing a PDF and returns `{ width, height }` in
CSS px. With page options (or none: A4) it lays out at the full page width with unbounded height, the
way a header or footer band is laid out, with three-digit page counters; margins never change the
result. With `viewport` it lays out at the viewport width.

<!-- @example pdf-api#measure -->
```js
const block = `<div style="height: 120px; font-family: Inter">Band</div>`;
await pdf.measure(block, { size: "a4" });                    // { width: 793, height: 120 }: full A4 width in CSS px
await pdf.measure(block, { size: "letter", landscape: true }); // { width: 1056, height: 120 }
await pdf.measure(block, { viewport: { width: 300 } });      // { width: 300, height: 120 }
pdf.measureSync(block);                                      // A4 by default; margins never change the result
```

Use it to size a band before you set a margin ([Margins and bands](headers-footers.md#margins-and-bands)).

### `prepare`

`prepare(source, options)` resolves resources once and returns a `Prepared` handle for `render` and `measure`. Render options override prepared options. Preparation discovers resources in the document and bands, loads font subsets and `@font-face` files, and fetches missing images. Configure `images.fetch` to control image downloads; see [PDF fonts](fonts.md) and register fonts explicitly to avoid missing text.

<!-- @example pdf-api#prepare -->
```js
const prepared = await pdf.prepare(html, { size: "a5" });
const a5 = await pdf.render(prepared, { margin: 24 }); // options merge over the prepare() options: A5, 24 px margins
```

### `free` and `[Symbol.dispose]`

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

## Sources

`PdfSource` is a `Source` or a `Prepared` handle. A `Source` is an HTML string, a node tree, or
`{ json: "<node tree as JSON text>" }`, exactly as for images ([Node format](../image/api.md#node-format)).
A JSX / React element is accepted too, as a document and as a header or footer band: it is converted to HTML.
Components run once without a React dispatcher, so hooks other than plain reads do not work.

<!-- @example pdf-api#sources -->
```js
const fromTree = await pdf.render({ type: "text", text: "From a node tree", style: { fontFamily: "Inter" } });
const fromJson = await pdf.render({ json: '{"type":"text","text":"From JSON text","style":{"fontFamily":"Inter"}}' });
```

## Module-level `render`, `measure` and `prepare`

`render(source, options?)`, `measure(source, options?)` and `prepare(source, options?)` call the same
methods on one shared `PdfRenderer` that is created on first use. You cannot reach it to register
fonts, so use them for documents without text, or pass the fonts in the `fonts` option:

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

Fonts passed in `fonts` stay registered on the shared renderer for later calls.

## `Renderer.renderPdf` and `measurePdf`

Every `Renderer` has `renderPdf`, `renderPdfSync`, `measurePdf` and `measurePdfSync`, with the same
parameters and results as `PdfRenderer.render` / `renderSync` / `measure` / `measureSync` (a
`PdfRenderer` is a thin wrapper over them). They work on the `Renderer` exported by `bm-render/pdf`:

<!-- @example pdf-api#renderer-methods -->
```js
import { Renderer } from "bm-render/pdf";

const r = new Renderer();
const viaRenderer = await r.renderPdf(`<div style="width: 40px; height: 40px; background: red"></div>`, {
  viewport: { width: 40 },
});
r.measurePdfSync(`<div style="width: 40px; height: 40px"></div>`, { viewport: { width: 40 } }); // { width: 40, height: 40 }
```

On every other build they throw, also on `bm-render` when it runs on the native addon:

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

## Render options

`PdfRenderOptions` is either **paged** (the default) or **viewport** (one page); the two groups are
mutually exclusive. Every option is optional.

| Option | Type | Default | Meaning | Details |
|:--|:--|:--|:--|:--|
| `size` | `PageSizeName \| { width, height }` | `"a4"` | Page size: a name (`a3`, `a4`, `a5`, `b4`, `b5`, `jis-b4`, `jis-b5`, `ledger`, `legal`, `letter`, any case, portrait) or CSS px. A document's `@page { size }` wins. | [Page size](page-size-and-viewport.md#page-size-orientation-and-margins) |
| `landscape` | `boolean` | `false` | Swaps width and height, also of an explicit size. | [Page size](page-size-and-viewport.md#page-size-orientation-and-margins) |
| `margin` | `number \| "auto" \| { top?, right?, bottom?, left? }` | `"auto"` | CSS px per side; a side left out is `"auto"`: 10 mm (37.8 px), or as tall as the band on that side needs. | [Margins and bands](headers-footers.md#margins-and-bands) |
| `header`, `footer` | `Node \| string \| false` | none | A band repeated at the top / bottom of every page; `pageNumber` / `totalPages` classes receive the counters. | [Headers and footers](headers-footers.md) |
| `pages` | `{ first?, last?, odd?, even? }` of `{ header?, footer? }` | none | Bands that replace the document's bands on some pages; `first` and `last` win over `odd` and `even`. | [Different bands](headers-footers.md#different-bands-on-some-pages) |
| `pageRanges` | `(number \| { from?, to? })[]` | all pages | The pages the file keeps, numbered from 1; counters keep the full document's numbers. | [Keeping some pages](pagination.md#keeping-some-pages) |
| `viewport` | `{ width, height? }` | none | One page of that size in CSS px, no margins or bands; without `height` the page is as tall as the content. Excludes every option above. | [One page](page-size-and-viewport.md#one-page-viewport) |
| `backgroundColor` | `string` (CSS colour) | none | Paper colour painted under everything on every page. | [Page size](page-size-and-viewport.md) |
| `css` | `string \| string[]` | none | Stylesheets applied before layout (also for node trees). | [HTML and Tailwind](../image/html-and-tailwind.md) |
| `cssVariables` | `Record<string, string>` | none | `:root` custom properties; a name without `--` gains it. | [HTML and Tailwind](../image/html-and-tailwind.md) |
| `fontFamilies` | `string[]` | none | Root font stack, the fallback chain for elements without `font-family`. | [Fallback fonts](fonts.md#fallback-fonts) |
| `fonts` | `FontLoader[] \| Promise<FontLoader[]>` | none | Fonts registered before the render (async methods only). | [Fonts in PDF](fonts.md) |
| `images` | `ImagesInput` | none | Image bytes for the `src` keys of the document and its bands. Only `prepare` fetches remote images. | [Images](../image/images.md) |
| `uncoveredText` | `"error" \| "placeholder" \| "blank"` | `"error"` | What a character no registered font draws becomes. | [Characters no font covers](fonts.md#characters-no-font-covers) |
| `lang` | `string` (BCP 47) | none | Language of the root element and of the metadata. | [Metadata](links-metadata.md#metadata) |
| `metadata` | `PdfMetadata` | none | `title`, `description`, `authors`, `keywords`, `creator`, `creationDate`, custom `xmp` schemas. | [Metadata](links-metadata.md#metadata), [Custom XMP](links-metadata.md#custom-xmp) |
| `outline` | `boolean` | `false` | Bookmarks from `h1`-`h6`. | [Bookmarks](links-metadata.md#bookmarks) |
| `attachments` | `Attachment[]` | none | Embedded files (`name`, `data`, `mimeType?`, `description?`, `relationship?`, `modificationDate?`). | [Attachments](links-metadata.md#attachments) |
| `tagged` | `boolean \| "ua1" \| "ua2"` | `true` | Structure tree; `"ua1"` / `"ua2"` also validate PDF/UA-1 / PDF/UA-2. | [Tagged PDF](accessibility.md#tagged-pdf), [PDF/UA](accessibility.md#pdfua) |
| `pdfa` | `"2a" \| "2b" \| "2u" \| "3a" \| "3b" \| "3u" \| "4" \| "4f"` | none | PDF/A level, validated; a violation fails the render. | [PDF/A](accessibility.md#pdfa) |
| `signal` | `AbortSignal` | none | Checked before the render reads and draws the document. | [Errors](#errors) |
| `limits` | `Limits` | built-in caps | bm-render resource limits for untrusted input (`maxImagePixels`, `maxImageBytes`, `maxAnimationFrames`, `maxNodeDepth`; `maxCanvasPixels` does not apply to pages). Also a `PdfRenderer` constructor option; a call can only lower it. An image over a limit fails the render with `image exceeds limits.<name>`. | [Resource limits](../image/api.md#resource-limits-for-untrusted-input) |

Combinations of `pdfa`, `tagged` and `attachments` that no PDF version allows are type errors and run
time errors; the table is in [Versions and combinations](accessibility.md#versions-and-combinations).
An unknown option name is ignored, so check spelling: `{ sise: "a4" }` renders A4.

## Measure options

`PdfMeasureOptions` takes `size` and `landscape`, or `viewport`, plus the layout resources `fonts`,
`images`, `css`, `cssVariables`, `fontFamilies`, `lang`, `limits` and `signal`. The types leave out `margin`,
bands and every output option, since they do not change the measured size; at run time a `margin` is
accepted and ignored, but `viewport` together with `size` or `landscape` throws the same "mutually
exclusive" error as `render`.

## Page counters

```ts
function PageNumber(props?: CounterProps): ContainerNode;
function TotalPages(props?: CounterProps): ContainerNode;
function TargetPageNumber(props?: CounterProps & { href?: string }): ContainerNode;
type CounterProps = { format?: CounterStyle; className?: string; style?: Style; tw?: string };
```

They return plain node objects: a `span` with the class hook (`pageNumber`, `totalPages`,
`targetPageNumber`) followed by the `format` and your `className`. In a `header` or `footer` band and in a
`position: fixed` box, `PageNumber` shows each page's number; in the content flow it shows the page it
lands on. `TargetPageNumber` shows the page number of a link target: without `href` it reads the nearest
enclosing `<a>`, with `href` it renders its own link. In HTML, write the classes yourself
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

In a flex row each text node is a flex item, and spaces at the ends of a flex item are dropped as in
CSS, so `"Page "` would print `Page1`: use `columnGap` (as here) or a block with inline children.

`CounterStyle`, the values of `format` (default `decimal`): `decimal`, `decimal-leading-zero`,
`lower-roman`, `upper-roman`, `lower-alpha`, `lower-latin`, `upper-alpha`, `upper-latin`, `lower-greek`,
`hiragana`, `katakana`, `trad-chinese-informal`, `cjk-ideographic`, `cjk-decimal`, `arabic-indic`,
`bengali`, `cambodian`, `khmer`, `devanagari`, `gujarati`, `gurmukhi`, `kannada`, `lao`, `malayalam`,
`mongolian`, `myanmar`, `oriya`, `persian`, `urdu`, `tamil`, `telugu`, `thai`, `tibetan`. CSS counters in
generated content (`content: counter(page)`, `target-counter()`) work too; see
[Headers, footers and page counters](headers-footers.md).

## Errors

Every error is an `Error` whose message starts with `bm-render:`, except an aborted render, which
rejects with the signal's reason (a `DOMException` named `AbortError` for `controller.abort()`):

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

Option values are validated before layout; the message names the option:

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

The example script checks each of these messages (the text after `bm-render: `):

| Cause | Message |
|:--|:--|
| `size: "tabloid"` | `unknown page size: tabloid` |
| `size: { width: 10 }` | `invalid size: expected a preset name or { width, height }` |
| `margin: "1in"` | `invalid margin: expected a number or "auto"` |
| margins that leave no page area | `Page size must be finite and larger than zero` |
| `landscape: "yes"` | `invalid landscape: expected a boolean` |
| `viewport` with a paged option | `viewport is mutually exclusive with the paged options (size, landscape, margin, header, footer, pages, pageRanges)` |
| `viewport: { height: 300 }` | `invalid viewport: width is required` |
| `viewport: { width: 0 }` | `invalid viewport: width/height must be > 0` |
| `viewport` without `height` and content of zero height | `invalid viewport: content has zero size and no width/height was given` |
| `header: 5` | no error: a number band is written as text-js does |
| `pages: { middle: {} }` | `unknown page rule: middle` |
| `pages: { first: { body: "x" } }` | `unknown field of pages.first: body` |
| `pageRanges: 3` | `invalid pageRanges: expected an array of page numbers or { from, to } spans` |
| `pageRanges: [0]` | `Page range is invalid: 0. Pages are numbered from 1.` |
| `pageRanges: [{ from: 5 }]` on a 1-page document | `The page ranges select none of the document's 1 pages` |
| `pdfa: "1b"` | `` unknown variant `1b`, expected one of `2a`, `3a`, `2b`, `2u`, `3b`, `3u`, `4`, `4f` `` |
| `tagged: "ua3"` | `data did not match any variant of untagged enum TaggedInput` |
| `uncoveredText: "skip"` | `unknown uncoveredText: skip` |
| `outline: "yes"` | `invalid outline: expected a boolean` |
| `lang: 5` | `invalid lang: expected a string` |
| `backgroundColor: 5` / `"paper"` | `invalid backgroundColor: expected a string` / `backgroundColor is not a color: paper` |
| `cssVariables: "x"` / `{ accent: 1 }` | `invalid cssVariables: expected an object of strings` / `invalid cssVariables: expected a string` |
| `metadata: "x"` | `invalid metadata: expected an object` |
| `metadata: { creationDate: "2026/01/01" }` | `invalid creationDate: expected YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS` |
| `attachments: {}` | `attachments takes an array` (a `TypeError`) |
| an attachment without `name` | ``missing field `name` `` |
| `data: 5` | `attachment data must be bytes or a string: <name>` |
| `relationship: "parent"` | ``unknown variant `parent`, expected one of `source`, `data`, `alternative`, `supplement`, `unspecified` `` |
| `mimeType: "plain"` | `Attachment mime type is not a type/subtype pair: plain` |
| a character no registered font draws (`uncoveredText: "error"`) | `No font the text can use draws 日 (U+65E5). Check each font's unicodeRange and the font-family stack, or register a font that draws them.` |
| `filter: blur(2px)` in the document | `A PDF cannot draw filter: blur(2px)` |
| a call on a freed renderer | `renderer has been freed` |
| `renderPdf` on another build | `renderPdf is not supported by this build (use the pdf build: import from "bm-render/pdf")` |

PDF/A and PDF/UA violations, impossible standard combinations and their messages are listed in
[Versions and combinations](accessibility.md#versions-and-combinations).

## Types

`js/pdf-types.d.mts` (re-exported by `bm-render/pdf`) defines `PdfRenderOptions`, `PdfMeasureOptions`,
`MeasuredSize` (`{ width, height }` in CSS px), `PageSizeName`, `PageSize`, `Dimensions`,
`ViewportInput`, `PageMargin`, `PageMarginSide`, `Band`, `PageOverride`, `PageRules`, `PageRange`,
`PdfMetadata`, `XmpSchema`, `XmpProperty`, `Attachment`, `ArchivalAttachment` (an attachment with the
`mimeType` and `description` the PDF/A-3 levels require), `Pdfa`, `Tagged`, `UncoveredText` and
`PdfPrepared`. `js/pdf.d.mts` adds `PdfSource`, `CounterStyle` and `CounterProps`. `render` and
`renderSync` are typed as returning `OutputBytes` (a `Uint8Array`).
