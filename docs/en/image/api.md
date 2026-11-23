# API reference

[English](api.md) · [Tiếng Việt](../../vi/image/api.md)

The public API of bm-render: initialization, `Renderer`, node objects, render options, errors and memory. Type declarations ship in `js/index.d.mts` and the profile-specific `.d.mts` files. Byte results are fresh `Uint8Array` values that can be passed to `Response` or `Blob`.

- [Module exports](#module-exports): [`init`](#init), [`initSync`](#initsync), [`features`](#features), [`profile` / `wasmUrl`](#profile-and-wasmurl), [`setGlyphCacheMaxBytes`](#setglyphcachemaxbytes)
- [`Renderer`](#renderer): [constructor](#constructor), [`registerFont`](#registerfont), [`unregisterFont`](#unregisterfont), [`clearFonts`](#clearfonts), [`render`](#render--rendersync), [`renderAsDataUrl`](#renderasdataurl--renderasdataurlsync), [`renderSvg`](#rendersvg--rendersvgsync), [`measure`](#measure--measuresync), [`renderAnimation`](#renderanimation--renderanimationsync), [`prepare`](#prepare--prepareanimation), [`memoryBytes`](#memorybytes), [`free`](#free--symboldispose)
- [Node format](#node-format)
- [Render options](#render-options)
- [Errors](#errors)
- [Limits](#limits)
- [Memory, instances and threads](#memory-instances-and-threads)
- [WOFF add-on (`bm-render/woff`)](#woff-add-on)

## Module exports

Every entry (`bm-render`, `bm-render/core`, `bm-render/standard`, `bm-render/full`, `bm-render/pdf`, `bm-render/native`) exports
the same names and owns one engine instance (a wasm instance; on Node.js, `bm-render` may run the native addon
instead, and `bm-render/native` always does); `bm-render/pdf` adds `PdfRenderer` and the page counter helpers
([PDF output](../pdf/index.md)). See [Package entry points](../getting-started.md#package-entry-points).

| Export | Kind |
|:--|:--|
| `init` (also the default export) | `async (input?) => WebAssembly.Exports` |
| `initSync` | `(input) => WebAssembly.Exports` |
| `Renderer` | class |
| `features` | `Readonly<Features>` |
| `Prepared` | opaque class of `prepare()` handles (not constructible by you) |
| `setGlyphCacheMaxBytes` | no-op, accepted for API compatibility; ignored |
| `backend` | `"wasm" \| "native"`: which engine build serves this entry (`"native"` only for `bm-render`, `bm-render/native` and `bm-render/pdf` on Node.js with the platform package installed); same API and output either way, see [Native on Node.js](../getting-started.md#native-on-nodejs-webassembly-everywhere-else) |
| `profile` | `"core" \| "standard" \| "full" \| "pdf"` (profile entries only) |
| `wasmUrl` | `() => URL` (profile entries only) |

### `init`

```ts
init(input?: InitInput | Promise<InitInput> | { module_or_path: InitInput | Promise<InitInput> }): Promise<WebAssembly.Exports>
type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;
```

Instantiates the binary. Strings, `URL`s and `Request`s are fetched; a `Response` with content type
`application/wasm` is compiled with `WebAssembly.instantiateStreaming`, any other `Response` through
`arrayBuffer()`. `init` is idempotent: once an entry is initialised, further calls resolve to the same
instance and their argument is ignored; concurrent calls share one instantiation; a failed call can be
retried. The profile entries default to their own binary (`wasmUrl()`); the generic `bm-render` entry
in browsers needs the argument. On Node.js every entry is already initialised when the import resolves.

### `initSync`

```ts
initSync(input: BufferSource | WebAssembly.Module | { module: BufferSource | WebAssembly.Module }): WebAssembly.Exports
```

Synchronous instantiation from bytes or a compiled module (what Cloudflare Workers give you for a
`.wasm` import). Same idempotence rule as `init`.

### `features`

A frozen-shape object of booleans describing the loaded binary; all `false` before initialisation.

| Key | Meaning | core | standard | full |
|:--|:--|:-:|:-:|:-:|
| `css` | stylesheets (`css` option, HTML `<style>`), selectors, `@keyframes` parsing | | ✓ | ✓ |
| `tw` | Tailwind `tw` utilities | | ✓ | ✓ |
| `html` | HTML string sources | | ✓ | ✓ |
| `svg` | SVG images | | ✓ | ✓ |
| `woff` | built-in WOFF / WOFF2 | | ✓ | ✓ |
| `variableFonts` | variable font instances | | ✓ | ✓ |
| `cff` | CFF / CFF2 outlines (`.otf`) | | ✓ | ✓ |
| `effects` | clip-path, masks, blend modes, backdrop-filter, isolation | | ✓ | ✓ |
| `modernColor` | `lab()`, `lch()`, `oklab()`, `oklch()`, `color()`, `color-mix()`, `light-dark()`, gradient `in <space>` | | ✓ | ✓ |
| `tables` | table layout | | ✓ | ✓ |
| `floats` | floats | | ✓ | ✓ |
| `webpGifDecode` | WebP (lossless) and GIF image sources | | ✓ | ✓ |
| `textWrapBalance` | `text-wrap: balance / pretty` | | ✓ | ✓ |
| `colorFonts` | COLR v0/v1 colour glyphs (bitmap CBDT / sbix glyphs are drawn in colour on `standard` too) | | | ✓ |
| `complexText` | bidi, Arabic / Hebrew / Indic / Thai shaping, normalisation | | | ✓ |
| `animation` | CSS animations (`timeMs`), `renderAnimation`, animated image sources | | | ✓ |
| `extraCodecs` | lossy WebP decode, animated GIF / APNG / WebP decode and encode, ICO output | | | ✓ |
| `renderSvg` | `renderSvg()` | | | ✓ |
| `pdf` | `renderPdf()` / `measurePdf()` (PDF output) | | | `false` in `full` and on `bm-render` (also on the native addon); `true` only in `bm-render/pdf` (native or wasm), which has every other feature too |

### `profile` and `wasmUrl`

Only on `bm-render/core`, `/standard`, `/full` and `/pdf`: `profile` is the entry's profile name; `wasmUrl()`
returns the URL `init()` loads by default (`new URL("./bm_render[.<profile>].wasm", import.meta.url)`)
and throws where `import.meta.url` is not usable.

### `setGlyphCacheMaxBytes`

`setGlyphCacheMaxBytes(bytes: number): void`: accepted and ignored. The glyph-mask cache has a fixed
8 MiB budget.

## `Renderer`

A renderer owns its registered fonts, a decoded-image cache and a glyph cache. Create one per set of
fonts and reuse it; creating a renderer is cheap, registering fonts is not.

Every rendering method exists twice: `xxxSync()` returns the result, `xxx()` returns a `Promise`.
On WebAssembly, both variants perform rendering on the calling thread. On the native backend, async methods use the libuv thread pool. Async methods also resolve `fonts`, lazy `images[].data` and promises.

### Constructor

```ts
new Renderer(options?: { limits?: Limits; cacheMaxBytes?: number; fontCacheMaxBytes?: number })
```

Throws `bm-render: call init()/initSync() before creating a Renderer` before initialisation.
`limits` sets the default [resource limits](#resource-limits-for-untrusted-input) of every call on
this renderer. `cacheMaxBytes` and `fontCacheMaxBytes` are accepted and ignored (fixed budgets: 96 MiB
of decoded images, 8 MiB of glyph masks).

### `registerFont`

```ts
registerFont(font: ByteBuf | { name?, data: ByteBuf, weight?, style? }): RegisteredFamily[]
registerFont(font: string | URL | Promise<...> | { data: () => ByteBuf | Promise<ByteBuf> }): Promise<RegisteredFamily[]>
loadFont(...)  // alias
type RegisteredFamily = { name: string; faces: { weight: number; style: string; width: number; index: number }[]; weight?: number; style?: string };
```

- `data`: TTF, OTF, TTC/OTC (every face is registered), and WOFF / WOFF2 when the build has them or the
  [add-on](#woff-add-on) is loaded. `ByteBuf` is `Uint8Array | ArrayBuffer | ArrayBufferView` (Node
  `Buffer`s work).
- `name` overrides the family name, `weight` (number) and `style` (`"normal"`, `"italic"`, `"oblique"`)
  override what the font's tables say.
- Synchronous for bytes and `{ data: bytes }`. A URL string or `URL` is fetched (`fetch`, so `http(s):`
  in Node, not `file:`), and a `data` function / promise is awaited: the call then returns a `Promise`.
- `unicodeRange`, `subsetOf` and `generic` are accepted and ignored; every face is registered eagerly.
- The bytes are copied into wasm memory once and parsed in place.

```js
r.registerFont(readFileSync("Inter-Regular.ttf"));
// [{ name: "Inter", faces: [{ weight: 400, style: "normal", width: 100, index: 0 }], weight: 400, style: "normal" }]
r.registerFont({ name: "Brand", data: readFileSync("Inter-Bold.ttf"), weight: 700 });
// [{ name: "Brand", faces: [{ weight: 700, ... }], weight: 700, style: "normal" }]
```

Errors: `bm-render: invalid font data`, `bm-render: unsupported font format` (for example CFF on `core`),
and for WOFF on a build without it: `bm-render: this build has no WOFF/WOFF2 font support (use the
standard / full build, or load the WOFF add-on: ...)`.

### `unregisterFont`

`unregisterFont(family: string | { name: string }): boolean`: removes every face of the family. Returns
`true` when something was removed.

### `clearFonts`

`clearFonts(): void`: removes every registered font. There is no built-in font left
afterwards: text renders as nothing until you register a font again.

### `render` / `renderSync`

```ts
renderSync(source: Source | Prepared, options?: RenderOptions): Uint8Array
render(source: Source | Prepared, options?: RenderOptions): Promise<Uint8Array>
```

`source` is a [node](#node-format), `{ json: string }` (a node tree as JSON text), an **HTML string**
(every JS string is treated as HTML; needs `features.html`) or a `Prepared` handle.
Returns a fresh `Uint8Array`: the encoded image, or straight RGBA8 for `format: "raw"`. See
[Render options](#render-options).

```js
const png = r.renderSync({ type: "container", style: { width: 100, height: 50, backgroundColor: "red" } }, { width: 100, height: 50 });
const raw = r.renderSync(node, { width: 100, height: 50, format: "raw" }); // 100 * 50 * 4 bytes
const fromJson = r.renderSync({ json: JSON.stringify(node) }, { width: 100, height: 50 });
const fromHtml = r.renderSync("<div style='display:flex;width:100px;height:50px;background:red'></div>", { width: 100, height: 50 });
```

### `renderAsDataUrl` / `renderAsDataUrlSync`

Same arguments as `render`. Returns `data:image/png;base64,...` (or `image/jpeg`, `image/webp`,
`image/x-icon`). `format: "raw"` throws `bm-render: renderAsDataUrl needs an encoded format` (`"jpg"` is accepted as an alias of `"jpeg"`).

### `renderSvg` / `renderSvgSync`

Returns an SVG document string (needs `features.renderSvg`, i.e. the `full` profile; otherwise throws
`bm-render: this build has no renderSvg support ...`). Boxes become `<rect>`/`<path>`, gradients
`<linearGradient>`/`<radialGradient>` (conic gradients as wedges), shadows `<filter>`s, images are
embedded as `data:` URLs, text becomes glyph outlines (`<use>` of paths in `<defs>`; no font embedding,
the text is not selectable). `format`, `quality` and `devicePixelRatio` are ignored (always ratio 1).

```js
const svg = r.renderSvgSync(node, { width: 400, height: 200 });
// '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200" viewBox="0 0 400 200">...'
```

### `renderPdf` / `measurePdf` and the `*Sync` twins

Every `Renderer` has `renderPdf(source, options)` and `measurePdf(source, options)`, but only `bm-render/pdf` exposes the
PDF writer; on any other build, including `bm-render` on the native addon, they throw `bm-render: renderPdf is not supported by this build (use the pdf build: import from "bm-render/pdf")`.
On Node.js, `bm-render/pdf` runs on the native addon when it is installed (the same PDF bytes as the wasm `pdf` profile), and then the async twins run off the main thread on the libuv thread pool.
The options are described in [PDF output](../pdf/index.md); `PdfRenderer` in `bm-render/pdf` is the usual way to call them.

### `measure` / `measureSync`

Lays out without painting and returns a `MeasuredNode` tree:

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

`transform` is the node’s 2D matrix relative to the canvas. Text run positions are relative to the node’s content box. Runs have no `text` field, and run heights describe line height. See [measure()](measure.md).

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

Needs `features.animation` (`full`). Encodes an animated WebP (lossless), APNG or GIF (palette
quantised per frame).

**Frame schedule**: with `total = sum(durationMs)`, the animation has
`ceil(total × fps / 1000)` frames; frame *i* starts at `floor(i × 1000 / fps)` ms and lasts until the
next frame's start (clamped to `total`; zero-length frames are dropped). A frame shows the scene active
at its start time, rendered at that scene's **local** time (CSS animations restart in every scene).
Maximum `fps`: 50 for GIF, 90 for WebP / APNG.

```js
const gif = r.renderAnimationSync({
  scenes: [{ node, durationMs: 1000 }, { node: doneNode, durationMs: 1000 }],
  width: 200, height: 200, fps: 20, format: "gif",
  css: ["@keyframes spin { to { transform: rotate(360deg) } } .dot { animation: spin 1s linear infinite }"],
}); // 40 frames
```

Errors: `Expected at least one animation scene`, `renderAnimation needs \`width\` and \`height\``,
`missing field \`fps\``, `Expected fps to be greater than 0`,
`Frame rate 60 fps exceeds the maximum 50 fps for this animation format`,
`unsupported animation format: mp4`. Total raw frame data is capped at 512 MiB per call.

To render a single frame of a CSS animation as a still image, use `render(..., { timeMs })` instead.

### `prepare` / `prepareAnimation`

```ts
prepare(source: Source, options?: RenderOptions): Promise<Prepared>
prepareAnimation(options: RenderAnimationOptions): Promise<Prepared>
```

Resolves the asynchronous parts of the options once (registers `fonts`, awaits lazy `images`) and
returns a handle. `render*`, `renderAsDataUrl*`, `renderSvg*` and `measure*` accept a `prepare` handle
and merge their own options over the prepared ones; `renderAnimation*` accepts a `prepareAnimation`
handle. Passing the wrong kind throws `bm-render: this prepared handle is for renderAnimation` (or
`... for render`).

`prepare` **does not fetch anything**: there is no "needs" pass that discovers remote
images or `@font-face` files. Provide image bytes through `images` and fonts through `fonts` /
`registerFont`.

```js
const prepared = await r.prepare(node, { width: 400, height: 112, images: [{ src: "avatar", data: () => readFile("logo.png") }] });
const png = r.renderSync(prepared);
const jpeg = await r.renderAsDataUrl(prepared, { format: "jpeg", quality: 90 });
```

### `memoryBytes`

`memoryBytes(): number` (also `Renderer.memoryBytes()`, `0` before init): the current size of the
entry's wasm linear memory, shared by all renderers of that entry. See [Memory](#memory-instances-and-threads).

### `free` / `[Symbol.dispose]`

`free()` releases the renderer's fonts, caches and canvas inside the wasm heap (the memory is reused by
later allocations; the linear memory itself never shrinks). Calling methods afterwards throws
`bm-render: renderer has been freed`; calling `free()` twice is harmless. `using r = new Renderer()`
calls it automatically where explicit resource management is available.

## Node format

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

- `type` is required (`bm-render: node is missing \`type\``); a text node needs `text`
  (`bm-render: text node is missing \`text\``). Unknown keys are ignored. `null` / `undefined`
  children are skipped.
- **Style keys are camelCase** (`backgroundColor`, `WebkitLineClamp`). Kebab-case keys
  (`"background-color"`) and unknown property names are ignored silently. Custom
  properties keep their dashes: `{ "--accent": "#7c3aed", color: "var(--accent)" }`.
- **Values** are CSS strings or numbers. A number is a length in px where the property takes a length
  (`width: 100`), and a plain number otherwise (`opacity: 0.5`, `lineHeight: 1.4`, `fontWeight: 700`).
  `!important` inside a string value is honoured.
- **Precedence** (low → high): `preset` < stylesheet rules (`css`) and `tw` utilities < inline `style`;
  `!important` follows CSS rules.
- **Defaults:** `display` is **`inline`** for every node (the
  root and flex/grid children are blockified); `boxSizing` is **`border-box`**; `objectFit` is `fill`;
  `transformOrigin` is `50% 50%`; the canvas starts fully transparent.
- A text node behaves like `<span>text</span>`. An image node's `width` / `height` are presentational
  hints (lowest priority).

The [CSS support](css-support.md) page lists every supported property and value.

## Render options

| Option | Type | Default | Notes |
|:--|:--|:--|:--|
| `width`, `height` | number | root's laid-out size | Canvas size in **output pixels** (also the viewport for `%`, `vw`, `vh`, `@media`). Values above 16384 are clamped to 16384; `0` throws. Omitted: the root is laid out at max-content on that axis and the canvas takes its size. |
| `format` | `"png" \| "jpeg" \| "jpg" \| "webp" \| "ico" \| "raw"` | `"png"` | `ico` needs `full`. Anything else throws `unsupported format: <x>`. |
| `quality` | number | 75 | JPEG only, clamped to 1–100. |
| `devicePixelRatio` | number | 1 | Scales CSS px lengths, font sizes and image intrinsic sizes; does **not** change the canvas size. Values outside (0, 64) are ignored. |
| `images` | `ImageSource[] \| { sources: ImageSource[] }` | | `{ src, data }` pairs that `src` / `url()` references look up. `data` may be lazy (async API only). |
| `css` | `(string \| rule object)[] \| string` | | Stylesheets (standard / full). Rule objects use `{ selector, style }`. |
| `stylesheets` | `string[]` | | Deprecated alias of `css` (used when `css` is absent). |
| `keyframes` | `{ [name]: { [offset]: Style } }` or a rule list | | Deprecated top-level keyframes. |
| `timeMs` | number | 0 | Position on the CSS animation timeline (floored to whole ms). Animations are applied at t = 0 when omitted. `full` only. |
| `fontFamilies` | `string[] \| string` | | Root font stack: the `font-family` of elements that set none. Fallback still walks every registered family. |
| `lang` | string | | Root language for `:lang()` and OpenType language systems. |
| `fonts` | `FontLoader[] \| Promise<FontLoader[]>` | | Async API only: registered before rendering; without `fontFamilies` their families become the root font stack. |
| `signal` | `AbortSignal` | | Checked before rendering (throws `signal.reason`). Rendering itself cannot be interrupted. |
| `limits` | `Limits` | built-in caps | Lower resource limits for this call; see [Resource limits](#resource-limits-for-untrusted-input). Also taken by `renderAnimation`, `measure`, `renderSvg` and `renderPdf`. |
| `lossless` | boolean | | Accepted, ignored: WebP is always lossless. |
| `drawDebugBorder`, `dithering` | | | Accepted, ignored. |

## Errors

All errors are plain `Error`s whose message starts with `bm-render: `.

| Situation | Behaviour |
|:--|:--|
| Invalid value in an inline `style` (or `preset`) | **throws**: `invalid value for style property width` |
| Invalid declaration in a stylesheet (`css`, HTML `<style>`) | the declaration is dropped, the rest of the rule applies (CSS error recovery) |
| Unparseable stylesheet text | the broken rules are dropped; no error |
| Unknown or invalid Tailwind class | skipped silently |
| Unknown style property, kebab-case key | ignored |
| Image `src` not found / not decodable | paints nothing; the image has 0 × 0 intrinsic size |
| Text with no usable font | not drawn; no error |
| Feature compiled out of the loaded binary | throws for the input forms that need it: HTML string (`this build has no HTML input support ...`), `css` (`this build has no stylesheet (\`css\` option) support ...`), `tw` (`Tailwind (\`tw\`) is not supported by this build`), `format: "ico"`, `renderSvg`, `renderAnimation`, WOFF fonts, CFF fonts, modern colour functions in inline styles (`invalid value for style property ...`). Other properties of a missing feature are accepted and have no effect (see [Profiles](../profiles-and-size.md#what-a-smaller-profile-does-with-unsupported-input)). |
| Raw image with wrong length | throws `raw image data length must be width*height*4` |
| Malformed `{ json }` | throws `invalid node JSON` |
| Lazy `images[].data` with a sync method | throws `lazy images[].data() needs the async API` |

The engine never traps on malformed input; the whole pipeline is fuzzed on a safety-checked build for
all three profiles.

## Limits

| Limit | Value |
|:--|:--|
| Node nesting depth | 512 levels (513 throws `node tree is nested too deeply`) |
| Canvas | at most 16384 px per side and 40 megapixels (`canvas too large`) |
| Empty content without `width`/`height` | throws `invalid viewport: content has zero size and no width/height was given` |
| ICO output | 1–256 px per side |
| Animation | GIF ≤ 50 fps, WebP / APNG ≤ 90 fps; ≤ 512 MiB of raw frames per call |
| Decoded images | the per-renderer image cache is cleared when it exceeds 96 MiB; one decoded image may have at most 24 megapixels (larger images are not drawn) |
| Glyph mask cache | 8 MiB per renderer |
| wasm shadow stack | 1 MiB (custom builds: `-Dstack-kib=`) |

### Resource limits for untrusted input

A server that renders user-supplied HTML, node trees or images can lower some of the limits above, so
that one request cannot make the engine decode a huge image or lay out a huge canvas. Pass `limits` to
the `Renderer` constructor (the default of every call) and/or to a single call:

```ts
const r = new Renderer({ limits: { maxImagePixels: 4_000_000, maxImageBytes: 5 << 20, maxNodeDepth: 64 } });
await r.render(userHtml, { width: 1200, height: 630, limits: { maxCanvasPixels: 1200 * 630 } });
```

| Limit | Applies to | Built-in cap (default) | When exceeded |
|:--|:--|:--|:--|
| `maxImagePixels` | width × height of one raster image source (encoded or raw RGBA), every frame of an animated one, and `<image>`s inside SVG images | 25,165,824 (24 megapixels; 16 Mi inside SVG) | the image is skipped |
| `maxImageBytes` | encoded byte size of one image source: PNG / JPEG / WebP / GIF bytes, decoded `data:` URIs, SVG markup | none | the image is skipped |
| `maxAnimationFrames` | frames of one animated GIF / WebP / APNG source | 10,000 | the image is skipped |
| `maxCanvasPixels` | width × height of the output canvas, each frame of `renderAnimation` included (not PDF pages) | 40,000,000 | throws `canvas exceeds limits.maxCanvasPixels` |
| `maxNodeDepth` | nesting levels of the node tree or the HTML document | 512 | throws `node tree exceeds limits.maxNodeDepth` |

Rules:

- A limit can only be **lowered**. A value above the built-in cap is clamped to the cap; a call's
  `limits` cannot raise the renderer's (the smaller value wins per limit; the others are merged).
- Values must be numbers ≥ 1 (fractions are floored). An unknown name, a value that is not a number ≥ 1,
  or a `limits` that is not an object throws (`unknown limit: limits.maxPixels`,
  `limit must be a number >= 1: limits.maxNodeDepth`, `limits must be an object`); the constructor
  throws these as `TypeError`s.
- An image over a limit is handled like an image that cannot be decoded: it paints nothing and has a
  0 × 0 intrinsic size, and the render succeeds. Sizes and frame counts are read from the file
  headers, before any pixel is decoded. An image already decoded by an earlier call with looser limits
  is still refused. `renderPdf` / `measurePdf` fail instead, with
  `image exceeds limits.maxImagePixels` (or the name of the limit), as they do for an undecodable image.
- Limits hold per call and per renderer: concurrent renders on different renderers (native addon
  thread pool, worker threads) never see each other's limits.
- Font files and the stylesheet size are not limited by this option: register fonts yourself and bound
  the source size before calling the renderer.

## Memory, instances and threads

- **One wasm instance per entry.** All renderers created from the same entry share its linear memory.
  `bm-render`, `bm-render/core`, `/standard` and `/full` each have their own instance, so different
  profiles can coexist in one process.
- **Linear memory only grows.** WebAssembly memory cannot shrink. A typical session (Inter registered,
  50 renders at 1200 × 630) uses about 6 MiB; one 3000 × 2000 render grows it to about 29 MiB, and that
  size stays even after `free()` — freed space is reused by later renders. In long-running processes,
  keep a small number of long-lived renderers instead of creating one per request, and avoid occasional
  giant canvases in the same instance as everyday work.
- **What lives where.** Per renderer: fonts (the bytes you registered), the decoded-image cache (cleared
  above 96 MiB), the glyph cache (cleared above 8 MiB), and one canvas sized like the last render. Per render: a bump arena
  that is reused across renders. `free()` returns all of a renderer's memory to the wasm allocator.
- **Native backend (Node.js).** `init()` / `initSync()` are no-ops, `memoryBytes()` is the addon's live
  allocation in the process (it returns to 0 after everything is freed; garbage collection sees it), and
  the async methods (`render`, `renderAsDataUrl`, `renderSvg`, `measure`, `renderAnimation`) run on the
  libuv thread pool with their inputs copied at the call. Calls on **one** renderer run one at a time, in
  call order; different renderers run in parallel (up to `UV_THREADPOOL_SIZE`, default 4). The addon also
  loads in `worker_threads`. Details: [docs/NATIVE.md](../../NATIVE.md).
- **Threads (wasm).** The binary is single-threaded and the API is synchronous: a render blocks the calling
  thread (a 1200 × 630 card takes a few ms; see [Benchmark](../benchmark.md)). For parallelism, run one
  instance per worker thread (`node:worker_threads`, Web Workers); each worker imports bm-render and
  registers its own fonts (verified with `node:worker_threads`: four workers rendering in parallel).
  Renderers and `Prepared` handles cannot be shared between workers; transfer the output bytes.

## WOFF add-on

```ts
import { loadWoff, decodeWoff } from "bm-render/woff";
loadWoff(input?: ByteBuf | WebAssembly.Module | URL | string | Request | Response | Promise<...>): Promise<{ builtIn: boolean }>
decodeWoff(bytes: ByteBuf): Uint8Array   // WOFF / WOFF2 -> TTF / OTF, after loadWoff()
```

`loadWoff()` instantiates `bm_woff.wasm` (84 KiB, no imports) and installs it as the WOFF converter for
every entry in the process; afterwards `registerFont` accepts WOFF / WOFF2 even on `core`. Without an
argument it reads the file next to the module (Node) or fetches it relative to the module (browsers and
bundlers). On Workers pass the module: `import woff from "bm-render/woff.wasm"`. The returned
`builtIn` reports `features.woff` of the generic `bm-render` entry. `decodeWoff` throws
`bm-render: invalid WOFF/WOFF2 font data` on bad input.

There is no other add-on: see [Profiles and size](../profiles-and-size.md#why-there-are-no-other-lazy-add-ons).


## See also

The guide pages go deeper into each topic, with runnable examples and their rendered output:
[Concepts](concepts.md) · [Styles and layout](styles.md) · [HTML and Tailwind](html-and-tailwind.md) ·
[Fonts](fonts.md) · [Typography](typography.md) · [Images](images.md) · [Tables and floats](tables.md) ·
[Effects](effects.md) · [Output formats](formats.md) · [Animation](animation.md) · [measure()](measure.md) ·
[Charts](charts.md) · [Templates](templates.md) · [Performance](performance.md)
