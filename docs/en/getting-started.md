# Getting started

[English](getting-started.md) · [Tiếng Việt](../vi/getting-started.md)

This page installs bm-render and explains what you get: the native addon on Node.js and WebAssembly
everywhere else, the package entry points, bundlers, edge runtimes, Deno and Bun, and the build
profiles. It applies to both outputs. When the package is installed, continue with the quick start of
the output you need:

- **[Image quick start](image/index.md)**: PNG, JPEG, WebP, SVG and animations (`bm-render`).
- **[PDF quick start](pdf/index.md)**: paged documents (`bm-render/pdf`).

Every Node.js snippet on this page was executed against bm-render 0.1.0 with package resolution;
snippets for runtimes that could not be run here are marked as such.

- [Install](#install)
- [Package entry points](#package-entry-points)
- [Bundlers (Vite, webpack, Rollup, esbuild, Next.js)](#bundlers)
- [Cloudflare Workers and other edge runtimes, Deno, Bun](#edge-runtimes-deno-bun)
- [Choosing a profile](#choosing-a-profile)
- [Next steps](#next-steps)

## Install

```sh
npm install bm-render
```

The package has no dependencies and no install scripts. It contains four prebuilt WebAssembly
binaries (`core`, `standard`, `full` and `pdf`, which adds PDF output), the optional WOFF add-on, a dependency-free ESM wrapper and
TypeScript declarations. The package is ES modules only (see [CommonJS](#commonjs)).

It also lists eight **optional dependencies**, one per platform: `@hunghg255/bm-render-win32-x64-msvc`,
`@hunghg255/bm-render-linux-x64-gnu`, ... (table below). Each holds only the native Node-API build of the same engine
(about 1 MB compressed) and declares `os`, `cpu` and, on Linux, `libc`, so your package manager installs
the one that matches the machine and skips the others. Nothing is compiled or downloaded at install time or
at run time; there is no postinstall script.

### Native on Node.js, WebAssembly everywhere else

On Node.js, `import ... from "bm-render"` uses the native addon when its platform package is installed and
loads, and otherwise falls back to the `full` WebAssembly binary **automatically and silently**. The API is
the same and the output is the same, byte for byte; natively the engine is faster and the async methods
(`render`, `renderSvg`, `measure`, `renderAnimation`, ...) run on the libuv thread pool instead of blocking
the event loop. Browsers, bundlers for the browser, workers and edge runtimes never see the native code.

```js
import { backend } from "bm-render";
console.log(backend); // "native" or "wasm"
```

| To force | Use |
|:--|:--|
| WebAssembly on Node | `BM_RENDER_BACKEND=wasm`, or import `bm-render/full` (always wasm) |
| native, or fail loudly | `BM_RENDER_BACKEND=native` (the import throws and says why), or import `bm-render/native` |

Why the addon was not used is in the error of `BM_RENDER_BACKEND=native node app.mjs`, for example
`bm-render: BM_RENDER_BACKEND=native, but the native addon is not available (@hunghg255/bm-render-linux-x64-gnu: not
installed)`.

| Platform package | `os` / `cpu` / `libc` | Status |
|:--|:--|:--|
| `@hunghg255/bm-render-win32-x64-msvc` | win32 / x64 | **executed**: byte identity with wasm on 250 fixtures, thread / memory / fuzz tests, install tests |
| `@hunghg255/bm-render-win32-arm64-msvc` | win32 / arm64 | built and structurally verified, **never executed** |
| `@hunghg255/bm-render-linux-x64-gnu` | linux / x64 / glibc 2.17+ | built and structurally verified, **never executed** |
| `@hunghg255/bm-render-linux-x64-musl` | linux / x64 / musl (Alpine) | built and structurally verified, **never executed** |
| `@hunghg255/bm-render-linux-arm64-gnu` | linux / arm64 / glibc 2.17+ | built and structurally verified, **never executed** |
| `@hunghg255/bm-render-linux-arm64-musl` | linux / arm64 / musl | built and structurally verified, **never executed** |
| `@hunghg255/bm-render-darwin-x64` | darwin / x64 (macOS 10.15+) | built and structurally verified, **never executed** |
| `@hunghg255/bm-render-darwin-arm64` | darwin / arm64 (macOS 11+) | built and structurally verified, **never executed** |

"Structurally verified" means the build script checked each binary without running it (format, CPU,
exported and imported symbols, glibc symbol versions, no math-library imports). Until a platform is
executed, rely on the fallback: if its addon does not load, `bm-render` uses WebAssembly. The x64 builds
need an x86-64-v2 CPU (SSE4.2, 2009 onwards); older CPUs get WebAssembly. Node.js 20 or newer.

### Package managers, Docker, serverless

- **npm, pnpm, Yarn, Bun** honour `os` and `cpu` (only npm was tested here). `libc` (glibc or musl) is honoured by current npm
  (tested: npm 11) and, per their documentation, pnpm and Yarn 3.2+; a manager that ignores it may install both Linux variants of your
  architecture, which is harmless: `bm-render` detects musl and loads the right one.
- **`npm install --omit=optional`** (`--no-optional`, Yarn `--ignore-optional`, ...) installs no platform
  package: you get WebAssembly (tested with npm).
- **Lockfiles created on another OS.** With npm 11 the lockfile written on Windows lists all eight packages
  with their `os` / `cpu` / `libc`, and `npm ci` for Linux x64 installs `@hunghg255/bm-render-linux-x64-gnu` (tested).
  Some older npm versions dropped the other platforms' optional packages from the lockfile when
  `node_modules` already existed (npm/cli#4828), the classic native-package pitfall. Here it is not fatal:
  the missing addon means WebAssembly, not an error. To repair, delete `node_modules` and the lockfile and
  install again, and check `backend` in CI.
- **Docker.** Run `npm ci` inside the image, on the image's platform; do not copy a `node_modules` built
  on your Windows or macOS host into a Linux image (you would get WebAssembly). Multi-arch builds
  (`docker buildx --platform linux/amd64,linux/arm64`) install the right package per architecture. Alpine
  images get the `-musl` package.
- **Installing for another machine** (e.g. building a Linux deployment on a Mac): npm can be told the
  target, and then needs all three flags (without `--libc` it installed neither Linux package on Windows):

  ```sh
  npm ci --os=linux --cpu=x64 --libc=glibc     # AWS Lambda x86_64, most Linux servers
  npm ci --os=linux --cpu=arm64 --libc=glibc   # Lambda arm64 (Graviton)
  npm ci --os=linux --cpu=x64 --libc=musl      # Alpine
  ```

  pnpm and Yarn use `supportedArchitectures` in their configuration instead.
- **Serverless (AWS Lambda, Vercel Functions, Netlify Functions, ...).** The binary is chosen when
  dependencies are installed, on the build machine: a platform that builds on Linux x64 (Vercel, Netlify,
  most CI) gets `@hunghg255/bm-render-linux-x64-gnu`; a zip of `node_modules` made on a Mac or on Windows carries the
  wrong one (WebAssembly at run time). Bundling deployers must also ship the platform package; see
  [Next.js](./image/frameworks/nextjs.md#native-addon-in-deployments) for `outputFileTracingIncludes`. Log
  `backend` once at startup to know what runs. None of these deployments was tested.
- **Bun, Deno, Electron** load the `node` entry and may load the addon; not tested. If it does not load,
  they get WebAssembly.

## Package entry points

| Import | Node.js (`node` condition) | Everywhere else (browsers, bundlers, workers, Deno) |
|:--|:--|:--|
| `bm-render` | the native addon if installed, else the `full` binary, ready on import (`BM_RENDER_BACKEND`, `BM_PROFILE`, `BM_WASM` override it) | wrapper only: call `init(wasm)` with the binary yourself |
| `bm-render/native` | the native addon, or the import throws | not available |
| `bm-render/full` | `full`, initialised on import | `await init()` locates `bm_render.wasm` next to the module (or pass it) |
| `bm-render/standard` | `standard`, initialised on import | `await init()` locates `bm_render.standard.wasm` |
| `bm-render/core` | `core`, initialised on import | `await init()` locates `bm_render.core.wasm` |
| `bm-render/pdf` | the native addon when installed, else the wasm `pdf` profile (= `full` + PDF output), initialised on import; see [PDF output](pdf/index.md) | `await init()` locates `bm_render.pdf.wasm` |
| `bm-render/woff` | `loadWoff()` / `decodeWoff()` — the WOFF add-on | same |
| `bm-render/full.wasm`, `/standard.wasm`, `/core.wasm`, `/woff.wasm` (`bm-render/wasm` = full) | the raw binaries, for bundler asset imports and Workers module imports; each also as `...wasm?module` for Next.js Edge | same |

Every entry exposes the same API (`init`, `initSync`, `Renderer`, `features`, `backend`, ...; the profile entries
also export `profile` and `wasmUrl()`). Each entry has **its own module instance**, so several profiles
can be loaded side by side in one process; within one entry the first successful `init` wins and later
calls return the same instance. `bm-render` and `bm-render/full` are separate instances too: importing
both on Node loads the full binary twice, so pick one.

### CommonJS

bm-render is published as ES modules. Because the Node entries have no top-level `await`, Node versions
with `require(esm)` support (22.12+, 20.19+) can load them from CommonJS:

```js
const { Renderer } = require("bm-render");
```

This was verified on Node 26.13. On older Node versions use `const { Renderer } = await import("bm-render")`.

## Bundlers

Import a profile entry and call `init()` without an argument. The entries locate their binary with
`new URL("./bm_render.wasm", import.meta.url)`, a pattern Vite, webpack 5, Rollup and Parcel recognise
and emit as an asset:

```js
import { init, Renderer } from "bm-render/full"; // or bm-render/standard, bm-render/core

await init();
const renderer = new Renderer();
```

If your bundler does not handle that pattern, import the binary's URL yourself and pass it:

```js
import { init, Renderer } from "bm-render/full";
import wasmUrl from "bm-render/full.wasm?url"; // Vite

await init(wasmUrl);
```

| Bundler | Notes | Tested |
|:--|:--|:--|
| Vite | `await init()` emits the `.wasm` as an asset; `?url` imports also work; no extra configuration | yes: Vite 8.3.8 build and dev server, pages run in headless Edge 157 |
| webpack 5 | `new URL(..., import.meta.url)` is emitted as an asset module by default | no |
| Rollup | needs an asset plugin that handles `new URL(..., import.meta.url)` (for example `@web/rollup-plugin-import-meta-assets`), or pass the URL yourself | no |
| esbuild | bundles cleanly (browser and `workerd` conditions) but does not copy `new URL()` assets: copy the `.wasm` file next to your bundle, or use `--loader:.wasm=file` and pass the imported URL to `init` | bundling only (esbuild 0.28) |

**Bundling a Node.js program** (esbuild `--platform=node`, Rollup, webpack with `target: "node"`). The
simplest is to keep the package out of the bundle: `esbuild app.mjs --bundle --platform=node
--external:bm-render`, and ship `node_modules`. Bundled anyway, the `bm-render` Node entry still works as
long as `node_modules/bm-render` (and the platform package) exist at run time: it looks for its wasm file
next to itself, then through package resolution, then in `<cwd>/node_modules/bm-render/js/`, and requires
the platform package at run time (no `--loader:.node` is needed: the `.node` file is never part of the
bundle). Tested with esbuild 0.28: ESM and CommonJS bundles ran natively; the CommonJS bundle copied to a
directory without `node_modules` failed at import with `bm-render: cannot find bm_render.wasm (...). This
happens when a bundler moved bm-render's Node.js entry away from its package: keep the package external
...`, and worked with `BM_WASM=/path/to/bm_render.wasm`.

Do **not** enable a bundler's WebAssembly-ESM integration for these files (`experiments.asyncWebAssembly`,
`vite-plugin-wasm`): bm-render instantiates the module itself and expects a URL, bytes or a
`WebAssembly.Module`.

**Next.js.** In Route Handlers on the Node.js runtime, import `bm-render` and read fonts with `fs` as in
the Node example. With Next.js 16.4.6 (Turbopack and webpack builders) this works without any
configuration under `next start`, natively when the platform package is installed. For self-contained
output (`output: "standalone"`, Vercel) add `serverExternalPackages: ["bm-render"]` and
`outputFileTracingIncludes: { "/*": ["./node_modules/bm-render-*/**"] }` so that the wasm files and the
platform package are copied; without them a webpack build fails at run time and a Turbopack build falls
back to wasm. On the Edge runtime, `import wasm from "bm-render/core.wasm?module"` and
`initSync(wasm)` (from `bm-render/core`). bm-render has no `ImageResponse` helper; return
`new Response(png, { headers: { "content-type": "image/png" } })`. See [Next.js](./image/frameworks/nextjs.md)
for the full setup and exactly what was verified.

Verification status of this section: the Vite and esbuild rows were exercised by the package test
(`npm run test:pack`: `npm pack`, install the tarball, build, run in headless Edge); webpack and Rollup
were not tested; Next.js is covered on its [own page](./image/frameworks/nextjs.md).

## Edge runtimes, Deno, Bun

**Cloudflare Workers / workerd** compile `.wasm` imports ahead of time and hand you a
`WebAssembly.Module` (runtime compilation from bytes is not allowed there). Import the binary and pass it
to `init` or `initSync`:

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

What was tested: `initSync(new WebAssembly.Module(bytes))` was executed in Node, and the package test
resolves the entries with `node --conditions=workerd` and initialises them from a `WebAssembly.Module`;
the snippet was **not** run under wrangler / workerd. The compressed size of each profile (gzip -9: core 229.5 KiB,
standard 465.1 KiB, full 560.0 KiB) is what counts against the Workers script-size limit of your plan. The
WOFF add-on works the same way: `import woff from "bm-render/woff.wasm"; await loadWoff(woff)`.

- **Bun**: the `node` condition applies, so `import { Renderer } from "bm-render"` tries the native
  addon and otherwise loads the wasm binary with `node:fs`. Not tested.
- **Deno**: `import { Renderer } from "npm:bm-render"` uses the same Node entry. Not tested.

## Choosing a profile

| Profile | wasm raw / brotli | Pick it when |
|:--|:--|:--|
| `core` | 489.6 / 195.3 KiB | Inputs are node trees with inline `style`, static TTF fonts and PNG/JPEG images (typical OG cards). |
| `standard` | 936.5 / 398.6 KiB | You need stylesheets (`css`), Tailwind (`tw`), HTML input, SVG images, WOFF2, variable or CFF fonts, effects (clip-path, masks, blend modes, backdrop-filter), modern colours, tables or floats. |
| `full` | 1 143.6 / 470.8 KiB | You also need bidi / complex scripts (Arabic, Hebrew, Indic, Thai), colour emoji, CSS animations / `renderAnimation`, `renderSvg`, lossy-WebP or animated image input, or ICO output. |

Details, and what a smaller profile does with input it cannot handle, are in
[Profiles and size](profiles-and-size.md). At runtime `features` tells you what the loaded binary has:

```js
import { features } from "bm-render/standard";
features.css;         // true
features.complexText; // false (full only)
```

## Next steps

| Output | Start here | Then |
|:--|:--|:--|
| Images | [Image quick start](image/index.md): render in Node.js and in a browser, fonts, images, output formats | [Concepts](image/concepts.md), [API reference](image/api.md), [CSS support](image/css-support.md) |
| PDF | [PDF quick start](pdf/index.md): `bm-render/pdf`, a first document, options | [Pagination](pdf/pagination.md), [PDF API reference](pdf/api.md), [Recipes](pdf/recipes.md) |
