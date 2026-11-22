# Recipes

[English](recipes.md) · [Tiếng Việt](../../vi/image/recipes.md)

Task-oriented snippets for things people build with bm-render: files on disk, HTTP endpoints with proper
caching, batches, worker pools, build-time generation, rendering in the browser, high-DPI output, text
that fits, remote images, error handling and multilingual fonts. Each recipe is short and complete;
most import `getRenderer()` and `card()` from the `og.js` module described in
[Frameworks → The universal pattern](./frameworks/index.md#the-universal-pattern).

::: info Verification status
Every recipe was executed on Node 26.13 against the packed bm-render 0.1.0 tarball
(`docs/examples/frameworks/check-recipes.mjs`, `check-servers.mjs`, `check-browser.mjs`); timings are from
one Windows 11 test machine and only indicate orders of magnitude. The Web Worker recipe ran in headless
Edge 157.
:::

- [Write a PNG to disk](#write-a-png-to-disk)
- [Serve over HTTP with ETag and Cache-Control](#serve-over-http-with-etag-and-cache-control)
- [Batch-render many cards](#batch-render-many-cards)
- [Worker threads pool](#worker-threads-pool)
- [Generate at build time](#generate-at-build-time)
- [Render in a Web Worker](#render-in-a-web-worker)
- [Retina / high-DPI output](#retina--high-dpi-output)
- [Fit text with measure()](#fit-text-with-measure)
- [Embed remote images](#embed-remote-images)
- [Errors and timeouts](#errors-and-timeouts)
- [i18n: font fallback chain](#i18n-font-fallback-chain)

## Write a PNG to disk

```js
import { readFileSync, writeFileSync } from "node:fs";
import { Renderer } from "bm-render/core";

const renderer = new Renderer();
renderer.registerFont({ name: "Inter", data: readFileSync("fonts/Inter-Regular.ttf") });

const png = renderer.renderSync(
  { type: "container", style: { display: "flex", width: "100%", height: "100%", alignItems: "center", justifyContent: "center", backgroundColor: "#0f172a" },
    children: [{ type: "text", text: "Hello", style: { fontFamily: "Inter", fontSize: 96, color: "white" } }] },
  { width: 1200, height: 630 },
);
writeFileSync("og.png", png); // a Uint8Array; no Buffer conversion needed
```

`format: "jpeg"` (with `quality`), `"webp"` (lossless) and `"raw"` work the same way; see
[Output formats](./formats.md).

## Serve over HTTP with ETag and Cache-Control

Hash the **inputs**, not the output: then a conditional request is answered with `304` before anything is
rendered.

```js
import { createServer } from "node:http";
import { getRenderer, card } from "./og.js";

const TEMPLATE_VERSION = "card-v1"; // bump when the template or fonts change

async function etagFor(params) {
  const data = new TextEncoder().encode(TEMPLATE_VERSION + "\0" + JSON.stringify(params));
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  return `"${[...hash.subarray(0, 12)].map((b) => b.toString(16).padStart(2, "0")).join("")}"`;
}

createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (url.pathname !== "/og.png") return res.writeHead(404).end();
  const params = { title: url.searchParams.get("title") ?? "Hello", description: url.searchParams.get("description") ?? "Rendered with bm-render" };
  const etag = await etagFor(params);
  const headers = { etag, "cache-control": "public, max-age=3600, stale-while-revalidate=86400" };
  if (req.headers["if-none-match"] === etag) return res.writeHead(304, headers).end();
  try {
    const png = await getRenderer().render(card(params), { width: 1200, height: 630 });
    res.writeHead(200, { ...headers, "content-type": "image/png", "content-length": png.byteLength });
    res.end(png);
  } catch (error) {
    console.error(error);
    res.writeHead(500, { "content-type": "text/plain" }).end("Failed to generate image");
  }
}).listen(3000);
```

Verified: a repeated request with `If-None-Match` got `304` and the renderer ran once. `crypto.subtle` is
global in Node 18+, Deno, Bun, Workers and browsers, so `etagFor` is portable. The same logic in Hono,
Express and other frameworks is on [Hono, Express and node:http](./frameworks/hono-express.md); choosing
`cache-control` values is covered in [Frameworks → Caching headers](./frameworks/index.md#caching-headers).

## Batch-render many cards

Reuse one renderer: fonts are parsed once, and caches and wasm memory are reused across renders.

```js
import { writeFile } from "node:fs/promises";
import { getRenderer, card } from "./og.js";

const renderer = getRenderer();
for (const post of posts) {
  const png = renderer.renderSync(card(post), { width: 1200, height: 630 });
  await writeFile(`out/${post.slug}.png`, png);
}
```

Measured: 48 gradient cards (two text lines each) in about 0.7 s on one thread — about 14 ms per card —
with the wasm memory staying at 6.8 MiB. Creating a `new Renderer()` per card instead would re-register
the fonts each time. If you must create short-lived renderers, call `free()` (or `using`) when done.
More numbers: [Performance](./performance.md) and [Benchmark](../benchmark.md).

## Worker threads pool

The engine is single-threaded and a render blocks its thread. For throughput, or to keep an HTTP server's
event loop free, run one bm-render instance per worker. On the wasm backend, `new Renderer({ workers: 4 })` does
this for you: its async methods run on a built-in pool, fonts included
([details](../native-vs-wasm.md#wasm-off-the-main-thread-workers)). A hand-written pool, without dependencies, gives
you full control:

```js
// render-worker.js
import { parentPort } from "node:worker_threads";
import { getRenderer, card } from "./og.js"; // each worker imports bm-render: its own wasm instance and fonts

parentPort.on("message", ({ id, props, options }) => {
  try {
    const png = getRenderer().renderSync(card(props), options);
    parentPort.postMessage({ id, png }, [png.buffer]); // transfer, no copy
  } catch (error) {
    parentPort.postMessage({ id, error: String(error?.message ?? error) });
  }
});
```

```js
// pool.js
import { Worker } from "node:worker_threads";
import { availableParallelism } from "node:os";

export function createPool(size = Math.max(1, availableParallelism() - 1), workerUrl = new URL("./render-worker.js", import.meta.url)) {
  const idle = [];
  const queue = [];
  const pending = new Map();
  let nextId = 0;
  const workers = Array.from({ length: size }, () => {
    const w = new Worker(workerUrl);
    w.on("message", ({ id, png, error }) => {
      const p = pending.get(id);
      pending.delete(id);
      error ? p.reject(new Error(error)) : p.resolve(png);
      idle.push(w);
      pump();
    });
    idle.push(w);
    return w;
  });
  function pump() {
    while (idle.length && queue.length) idle.pop().postMessage(queue.shift().msg);
  }
  return {
    render(props, options) {
      return new Promise((resolve, reject) => {
        const id = nextId++;
        pending.set(id, { resolve, reject });
        queue.push({ msg: { id, props, options } });
        pump();
      });
    },
    close: () => Promise.all(workers.map((w) => w.terminate())),
  };
}
```

```js
const pool = createPool(4);
const pngs = await Promise.all(posts.map((p) => pool.render(p, { width: 1200, height: 630 })));
await pool.close();
```

Measured with 4 workers: the same 48 cards in 0.19–0.27 s (2.5–3.9× faster than one thread across
runs), byte-identical to the main-thread output; an invalid render rejects only its own promise. Each
worker pays for loading the wasm and fonts once (warm the pool up at startup). Send props, not node trees,
if the trees contain functions; `Renderer` objects cannot be shared between threads. The pool has no
crash recovery: production code should replace a worker that emits `error` or `exit`.

## Generate at build time

For static sites, render images once during the build and serve them as files. This script skips posts
whose inputs did not change since the last run:

```js
// scripts/build-og.mjs — node scripts/build-og.mjs public/og
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import { getRenderer, card } from "../og.js";

const TEMPLATE_VERSION = "card-v1"; // bump when the template or the fonts change

export async function buildOgImages(posts, outDir) {
  await mkdir(outDir, { recursive: true });
  const manifestPath = path.join(outDir, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8").catch(() => "{}"));
  const renderer = getRenderer();
  let rendered = 0;
  for (const post of posts) {
    const key = createHash("sha256").update(TEMPLATE_VERSION + JSON.stringify(post)).digest("hex").slice(0, 16);
    if (manifest[post.slug] === key) continue; // unchanged since the last build
    await writeFile(path.join(outDir, `${post.slug}.png`), renderer.renderSync(card(post), { width: 1200, height: 630 }));
    manifest[post.slug] = key;
    rendered++;
  }
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2));
  return { rendered, skipped: posts.length - rendered };
}
```

Verified: 5 posts → `{ rendered: 5, skipped: 0 }`; run again → `{ rendered: 0, skipped: 5 }`; change one
title → `{ rendered: 1, skipped: 4 }`. Wire it before your site build
(`"build": "node scripts/build-og.mjs public/og && astro build"`), or use your framework's prerendering
([Astro](./frameworks/astro.md), [SvelteKit](./frameworks/sveltekit.md#prerendering-at-build-time),
[Next.js](./frameworks/nextjs.md#4-the-opengraph-image-file-convention)).

## Render in a Web Worker

In the browser, run the engine in a module worker and send back the bytes (transferred, not copied):

```js
// render-worker.js
import { init, Renderer } from "bm-render/standard";

const ready = (async () => {
  await init();
  const renderer = new Renderer();
  renderer.registerFont({ name: "Inter", data: await (await fetch("/fonts/Inter-Regular.ttf")).arrayBuffer() });
  return renderer;
})();

self.onmessage = async ({ data: { id, node, options } }) => {
  try {
    const png = (await ready).renderSync(node, options);
    self.postMessage({ id, png }, [png.buffer]);
  } catch (error) {
    self.postMessage({ id, error: String(error?.message ?? error) });
  }
};
```

```js
// main thread
const worker = new Worker(new URL("./render-worker.js", import.meta.url), { type: "module" });
worker.onmessage = async ({ data: { png } }) => {
  const blob = new Blob([png], { type: "image/png" });
  img.src = URL.createObjectURL(blob);                              // as an image
  canvas.getContext("2d").drawImage(await createImageBitmap(blob), 0, 0); // or onto a canvas
};
worker.postMessage({ id: 1, node, options: { width: 1200, height: 630 } });
```

Verified in headless Edge 157 (no bundler, module worker, blob URL and `createImageBitmap` both 1200 × 630).
The request/response bookkeeping with ids and the Vite setup are on [Vite and browsers](./frameworks/vite-browser.md#render-in-a-web-worker).

## Retina / high-DPI output

Multiply the canvas **and** pass `devicePixelRatio`:

```js
const dpr = 2;
const png = renderer.renderSync(node, { width: 600 * dpr, height: 315 * dpr, devicePixelRatio: dpr });
// display it at 600 × 315 CSS px
```

Verified: the result is 1200 × 630, and measured box widths are exactly twice their 1× values.
`devicePixelRatio` alone scales the content but keeps the canvas at `width × height` (a 600 × 315
render with `devicePixelRatio: 2` is still 600 × 315, with every CSS length doubled inside it).
In the browser use `window.devicePixelRatio` (capped, e.g. at 3). See also
[Troubleshooting](../troubleshooting.md#output-is-blurry-on-high-dpi-screens).

## Fit text with measure()

Pick the largest font size at which a title fits in N lines. `measure()` lays out without painting and
returns the box height:

```js
function fitFontSize(renderer, text, { width, maxLines, max = 96, min = 32, lineHeight = 1.2, style = {} }) {
  for (let size = max; size > min; size -= 4) {
    const m = renderer.measureSync(
      { type: "container", style: { display: "block", width, fontSize: size, lineHeight, ...style }, children: [{ type: "text", text }] },
      { width },
    );
    if (m.height <= Math.ceil(size * lineHeight) * maxLines) return size;
  }
  return min;
}

const size = fitFontSize(renderer, post.title, { width: 1072, maxLines: 2, style: { fontFamily: "Inter", fontWeight: 700 } });
```

Verified: "Short title" → 96 px; a 90-character title → 48 px, laid out in 2 lines (`m.runs.length`, the
line runs of the block). Measure with the same font, weight, width and line height as the final render.
A linear scan costs one layout per step; use a binary search for wide ranges. Details of the measure output: [Measure](./measure.md). CSS alternatives that need no
measuring: `lineClamp` / `textOverflow: "ellipsis"` (see [Typography](./typography.md)).

## Embed remote images

bm-render never downloads anything: an image `src` is a key into the `images` option. Fetch the bytes
yourself (with a timeout), then render:

```js
async function fetchImages(urls, timeoutMs = 3000) {
  const entries = await Promise.all(urls.map(async (src) => {
    try {
      const res = await fetch(src, { signal: AbortSignal.timeout(timeoutMs) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return { src, data: new Uint8Array(await res.arrayBuffer()) };
    } catch (error) {
      console.warn(`image ${src} skipped: ${error.message}`);
      return null;
    }
  }));
  return entries.filter(Boolean);
}

const avatar = "https://example.com/avatar.png";
const png = renderer.renderSync(
  { type: "container", style: { display: "flex" }, children: [{ type: "image", src: avatar, width: 64, height: 64 }] },
  { width: 64, height: 64, images: await fetchImages([avatar]) },
);
```

Verified against a local server: the fetched image was painted (orange centre pixel); a 404 and a request
slower than the timeout were skipped, and the render still succeeded — a missing image paints nothing.
Cache downloaded bytes (an LRU keyed by URL) if the same images repeat; restrict which hosts you fetch from
if URLs come from users. Formats per profile (SVG and WebP need `standard`) are in [Images](./images.md).

## Errors and timeouts

```js
try {
  const png = await renderer.render(node, { width: 1200, height: 630, signal: AbortSignal.timeout(2000) });
} catch (error) {
  // "bm-render: invalid value for style property width", "bm-render: canvas too large", signal.reason, ...
}
```

What was verified:

- An invalid inline style value throws (`bm-render: invalid value for style property width`); a zero
  `width` throws. Invalid stylesheet or Tailwind input is dropped silently instead.
- `signal` is checked **before** rasterising, after the async `fonts` / lazy `images` have resolved:
  an already-aborted signal rejects with its reason, and a signal that fires while a lazy font loads also
  rejects. A render that has started cannot be interrupted — it is synchronous.
- To bound CPU time per render, render in a worker and `terminate()` it on timeout (then create a new
  worker), and limit input size: text length, number of nodes, and canvas size (at most 16384 px per side
  and 40 megapixels).
- Missing fonts and images do not throw: text is not drawn, images paint nothing. Check
  `registerFont`'s return value at startup.

Full list: [API → Errors](./api.md#errors).

## i18n: font fallback chain

A character missing from an element's fonts falls back to **every registered family, in registration
order**. Register the primary font first and broad-coverage fonts after it:

```js
renderer.registerFont(readFileSync("fonts/Inter-Regular.ttf"));       // first choice
renderer.registerFont(readFileSync("fonts/NotoSans-Regular.ttf"));    // Latin / Greek / Cyrillic extensions
renderer.registerFont(readFileSync("fonts/NotoSansJP-Regular.ttf"));  // CJK, if your text needs it (not part of the test)

renderer.renderSync({ type: "text", text: userText.normalize("NFC") }, { width: 1200, height: 630, fontFamilies: ["Inter", "Noto Sans"] });
```

Verified with Inter + Noto Sans: "Xin chào · Привет · Ԁ" rendered differently than with Inter alone
(U+0500 came from Noto Sans), while the part Inter covers was pixel-identical in both. `fontFamilies`
sets the root font stack for nodes without `fontFamily`. Normalise user input to NFC (Vietnamese and
other accented text). Colour emoji need the `full` profile and a colour emoji font; bidi and complex
scripts (Arabic, Hebrew, Indic, Thai) need `full`. More: [Fonts](./fonts.md),
[Typography](./typography.md).
