# Troubleshooting and FAQ

[English](troubleshooting.md) · [Tiếng Việt](../vi/troubleshooting.md)

Symptoms you are likely to hit with bm-render, their cause and the fix. Most of them come from
two defaults (`display` defaults to `inline`; inputs are never fetched)
and one of bm-render's own (no bundled font).

- [Text is missing, or shows as boxes](#text-is-missing-or-shows-as-boxes)
- [Containers collapse to zero height](#containers-collapse-to-zero-height)
- ["this build has no ... support"](#this-build-has-no--support)
- [Images do not appear](#images-do-not-appear)
- [The .wasm file is not found (bundlers, workers)](#the-wasm-file-is-not-found)
- [Native addon (Node.js)](#native-addon-nodejs)
- [Memory keeps growing](#memory-keeps-growing)
- [Output is blurry on high-DPI screens](#output-is-blurry-on-high-dpi-screens)
- [Vietnamese text](#vietnamese-text)
- [Emoji are not in colour](#emoji-are-not-in-colour)
- [A style is ignored](#a-style-is-ignored)
- ["invalid value for style property"](#invalid-value-for-style-property)
- [Other errors](#other-errors)

## Text is missing, or shows as boxes

- **Nothing at all is drawn**: no font is registered on this `Renderer` (or `clearFonts()` was called).
  bm-render does not bundle a font and never reads system fonts. Register one:
  `renderer.registerFont(readFileSync("Inter-Regular.ttf"))`. Fonts are per renderer.
- **Boxes (tofu) for some characters**: no registered font contains those characters; they are drawn
  with the `.notdef` glyph. Register a font that covers the script (for example Noto Sans JP for
  Japanese). Fallback already walks every registered family in registration order (also when you pass
  `fontFamilies`, which only sets the root font stack).
- **Wrong font**: the family name you use in `fontFamily` must match the registered name — the `name`
  you passed, or the font's own family name (`registerFont` returns it).
- **A `.woff2` / `.otf` font throws**: `core` lacks WOFF and CFF; use `standard` / `full`, or the WOFF
  add-on for WOFF (CFF outlines still need `standard`).

## Containers collapse to zero height

`display` defaults to `inline` for every node. An inline container ignores
`width` / `height`, so two sized children of a block container end up on an empty line:

```js
r.measureSync({ type: "container", style: { display: "block" }, children: [
  { type: "container", style: { width: 50, height: 50 } },
  { type: "container", style: { width: 50, height: 50 } },
] }, { width: 200, height: 200 });
```

Give containers an explicit `display: "flex"`, `"block"` or `"grid"`. Children of a flex or grid
container are blockified automatically, so only the containers themselves need it. Text nodes inside
flex containers need nothing.

## "this build has no ... support"

The loaded profile does not contain the feature. Messages and the smallest profile that has it:

| Message (prefix `bm-render: `) | Needs |
|:--|:--|
| `this build has no HTML input support` | `standard` |
| `this build has no stylesheet (\`css\` option) support` | `standard` |
| `Tailwind (\`tw\`) is not supported by this build` | `standard` |
| `this build has no WOFF/WOFF2 font support` | `standard`, or `loadWoff()` from `bm-render/woff` |
| `unsupported font format` (an `.otf`) | `standard` (CFF) |
| `invalid value for style property backgroundColor` with `oklch()` / `lab()` / `color-mix()` on core | `standard` |
| `this build has no ICO output support`, `... renderSvg support`, `... animation support` | `full` (the message says "use the full build") |

Check `features` at startup, import a larger profile (`bm-render/standard`, `bm-render/full`), or see
[Profiles and size](profiles-and-size.md).

## Images do not appear

- **A URL is never downloaded.** `src: "https://..."` only looks up an entry of the `images` option.
  Fetch the bytes yourself and pass `images: [{ src: "https://...", data: bytes }]`.
- **Node `Buffer` passed directly as `src`** works; no `new Uint8Array(buffer)` wrapper is needed (a URL string still needs the `images` option).
- **SVG, WebP or GIF on `core`**: not decoded there; use `standard`.
- **Lossy WebP or animated sources on `standard`**: need `full`.
- **Lazy `images[].data` with a sync method** throws `lazy images[].data() needs the async API`; use
  `render()` / `prepare()`.
- **The image node has no size**: an image with an unknown or undecodable `src` has a 0 × 0 intrinsic
  size; set `width` / `height` if the layout must not depend on it.

## The .wasm file is not found

- **Browser / bundler**: import a profile entry (`bm-render/full`, `/standard`, `/core`) and call
  `await init()`. These entries reference their binary with `new URL("./bm_render....wasm",
  import.meta.url)`, which Vite, webpack 5, Rollup (with an asset plugin) and Parcel emit as an asset.
  If your bundler does not, import the binary URL explicitly (`import wasmUrl from
  "bm-render/full.wasm?url"` in Vite) or copy the file to your public directory and call
  `init("/bm_render.wasm")`.
- **The generic `bm-render` entry outside Node** has no default location: `init()` without an argument
  throws `bm-render: init() needs the wasm binary ...`. Pass bytes, a URL / `Response` or a
  `WebAssembly.Module`, or switch to a profile entry.
- **Cloudflare Workers** do not allow compiling WebAssembly from bytes at runtime: import the module
  (`import wasm from "bm-render/full.wasm"`) and pass it to `init` / `initSync`.
- **Wrong content type**: if the server does not send `application/wasm`, `init` falls back to the
  non-streaming path. That works, but a 404 HTML page will fail to compile — check the URL.
- **Node in a custom setup**: `BM_WASM=/path/to/bm_render.wasm` overrides the binary of the `bm-render`
  entry.

## Native addon (Node.js)

On Node.js, `bm-render` runs the native addon from the optional platform package
`@hunghg255/bm-render-<platform>` when it is installed and loads, and WebAssembly otherwise (see
[Install](getting-started.md#native-on-nodejs-webassembly-everywhere-else)). The fallback is silent by
design, so the first step is always to ask which backend runs:

```sh
node --input-type=module -e 'import("bm-render").then((m) => console.log(m.backend))'
BM_RENDER_BACKEND=native node app.mjs   # throws and says why the addon was not used
```

- **No binary for this platform, or it was not installed** (an OS / CPU without a platform package, e.g.
  FreeBSD, Linux on 32-bit ARM or ppc64; `--omit=optional`; a `node_modules` copied from another OS; a
  lockfile that lost the optional packages): you get WebAssembly, with the same output. The forced error
  says `@hunghg255/bm-render-<platform>: not installed`. Reinstall on the target machine, see
  [Package managers, Docker, serverless](getting-started.md#package-managers-docker-serverless).
- **Only `win32-x64-msvc` has been executed so far.** The seven other platform packages are built and
  structurally verified but have never run; if one fails to load on your machine, `bm-render` uses
  WebAssembly. Please report it with the forced error message.
- **`BM_RENDER_BACKEND`**: `wasm` never tries the addon; `native` makes the import throw when the addon is not
  available; anything else throws `BM_RENDER_BACKEND must be "wasm" or "native"`. `BM_WASM` and `BM_PROFILE`
  select WebAssembly too. `bm-render/native` is native or an import error; `bm-render/full`, `/standard`,
  `/core` are always WebAssembly.
- **Old x64 CPUs.** The x64 addons need x86-64-v2 (SSE4.2, POPCNT: Intel since 2008, AMD since 2011). On an
  older CPU the addon refuses to register and you get WebAssembly.
- **Electron, Bun, Deno** use the Node entry and may load the addon; none of them was tested. If the addon
  does not load, they get WebAssembly.
- **Rendering does not get faster with more `await`s.** One renderer executes one call at a time (calls
  on it are queued in order). For parallel throughput on the native backend create several renderers with
  the same fonts, at most about the libuv pool size (`UV_THREADPOOL_SIZE`, default 4), and spread the work.
  On WebAssembly everything runs on the calling thread anyway.
- **A bundled server cannot find the wasm file**: `bm-render: cannot find bm_render.wasm (...)`. A bundler
  moved the Node entry away from its package and `node_modules` is not there at run time. Keep the package
  external (Next.js `serverExternalPackages: ["bm-render"]`, esbuild `--external:bm-render`), or set
  `BM_WASM=/path/to/bm_render.wasm`. See [Next.js](image/frameworks/nextjs.md) for deployments.

## Memory keeps growing

WebAssembly memory can grow but never shrink. bm-render reuses memory between renders (a per-render
arena, fixed-budget caches: decoded images cleared above 96 MiB, glyphs above 8 MiB), so a steady
workload plateaus — about 6 MiB for 1200 × 630 cards with one font. What makes it grow:

- **A large canvas**: one 3000 × 2000 render raises the instance to about 29 MiB, and it stays there.
  Render big images in a separate instance (worker) if that matters.
- **Many renderers**: each one keeps its own fonts and caches. Reuse one renderer per font set; call
  `free()` (or `using`) when you are done with one. Freed memory is reused by later renders but not
  returned to the operating system.
- **Many large images**: up to 96 MiB of decoded images are cached per renderer.

`renderer.memoryBytes()` reports the current linear memory size. For a hard reset, drop the whole
instance (a worker thread or a new isolate).

## Output is blurry on high-DPI screens

Render more pixels and keep the CSS layout: set the canvas to the device size and `devicePixelRatio` to
the scale factor. `devicePixelRatio` multiplies CSS px lengths and font sizes but does not change the
canvas size:

```js
// a 1200 × 630 design rendered for a 2× screen
const png = renderer.renderSync(node, { width: 2400, height: 1260, devicePixelRatio: 2 });
```

`%`, `vw` and `vh` already refer to the canvas, so they need no change. Then display the image at half
its pixel size (`<img width="1200">`).

## Vietnamese text

- Use a font containing Vietnamese glyphs and test both precomposed and decomposed text when accepting user input.

## Emoji are not in colour

Colour emoji need a registered colour emoji font (COLR, CBDT or sbix, e.g. Noto Color Emoji) and a
profile that draws it: bitmap fonts (CBDT, sbix — Noto Color Emoji) on `standard` and `full`, COLR fonts
(`features.colorFonts`) only on `full`. Without the font, emoji show as boxes or as glyphs of another
font; a COLR font on `core` / `standard` is drawn without colour, and `core` draws nothing for a
bitmap-only font. Registering the font is
enough — fallback walks every registered family.

## A style is ignored

- Inline `style` keys must be **camelCase**: `backgroundColor`, not `"background-color"` (kebab-case keys
  are ignored silently). In stylesheets, HTML and `tw` use normal CSS syntax.
- The property needs a larger profile (for example `float`, `clipPath` or `mixBlendMode` on `core`
  are accepted and ignored).
- A stylesheet or Tailwind declaration with an invalid value is dropped silently. Check it as an inline
  style, which throws on invalid values.
- Tailwind variants other than breakpoints, structural variants and `before:` / `after:`
  (`hover:`, `dark:`, `group-*:`) never apply —. `animate-*` utilities need the `full`
  profile.
- See the list of [parsed-but-not-implemented properties](image/css-support.md#appendix-supported-property-names).

## "invalid value for style property"

An inline `style` (or `preset`) value could not be parsed; the whole render throws. Typical
causes: a typo (`"10 px"`), a 3D transform (`rotateX()`), relative colour syntax, modern colour
functions on `core`. Stylesheet declarations do not throw; they are dropped.

## Other errors

| Message (prefix `bm-render: `) | Cause |
|:--|:--|
| `call init()/initSync() before creating a Renderer` | outside Node, the entry was not initialised |
| `renderer has been freed` | the renderer was used after `free()` |
| `BM_RENDER_BACKEND=native, but the native addon is not available (...)` | native forced, no usable addon; the reason is in parentheses ([Native addon](#native-addon-nodejs)) |
| `bm-render/native: the native addon is not available (...)` | `bm-render/native` imported without an installed platform package |
| `BM_RENDER_BACKEND must be "wasm" or "native", not "..."` | a typo in the environment variable |
| `cannot find bm_render.wasm (...)` | a bundler moved the Node entry away from `node_modules` ([Native addon](#native-addon-nodejs)) |
| `invalid viewport: width/height must be > 0` | `width` or `height` is 0 |
| `invalid viewport: content has zero size and no width/height was given` | no canvas size and nothing to measure |
| `canvas too large` | more than 16384 px per side or 40 megapixels |
| `node tree is nested too deeply` | more than 512 levels |
| `node is missing \`type\`` / `text node is missing \`text\`` | malformed node |
| `invalid node JSON` | malformed `{ json }` source |
| `unsupported format: <x>` | `format` is not png / jpeg / webp / raw / ico |
| `raw image data length must be width*height*4` | RGBA image object with the wrong length |
| `renderAsDataUrl needs an encoded format` | `format: "raw"` with `renderAsDataUrl` (`"jpg"` works: it is an alias of `"jpeg"`) |
| `Frame rate N fps exceeds the maximum ...` | GIF > 50 fps, WebP / APNG > 90 fps |
| `invalid font data` | not a font file |
