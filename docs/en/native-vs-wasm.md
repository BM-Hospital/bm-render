# Native and WebAssembly

Choose the backend for your runtime. On Node.js, the package prefers the native addon and falls back to WebAssembly when the addon is unavailable. See [Benchmark](benchmark.md) for timing and memory measurements.

## Which backend to use

| Where your code runs | Backend | How |
|:--|:--|:--|
| Node.js, Bun, Deno (servers, CLIs, build scripts) | **native**, with an automatic fallback to wasm | `import { Renderer, backend } from "bm-render"`; `backend` is `"native"` or `"wasm"` |
| Browsers, Web Workers | wasm (the only option) | `bm-render` resolves to the wasm build there |
| Cloudflare Workers, Vercel / Netlify Edge, Deno Deploy and other edge runtimes | wasm (the only option) | same import |
| Node.js, but you want wasm anyway (for example to reproduce a browser render bit for bit, or on a host whose addon has not been tested yet) | wasm | `import ... from "bm-render/full"` or `BM_RENDER_BACKEND=wasm` |
| Node.js, Bun, Deno, and you want PDF output | **native**, with an automatic fallback to the wasm `pdf` profile | `import { PdfRenderer, backend } from "bm-render/pdf"`; see [PDF output](./pdf/native-and-wasm.md#native-backend-on-nodejs) |
| Node.js, and you want an error rather than a silent fallback | native | `import ... from "bm-render/native"` or `BM_RENDER_BACKEND=native` |

The fallback is silent: if no addon is installed for the platform, if the CPU is older than x86-64-v2
(SSE4.2), or if the addon fails its load-time floating-point check, `bm-render` loads the wasm build and
everything keeps working, only slower and with async calls on the main thread. Log `backend` once at startup
if you need to know.

`bm-render/pdf` follows the same rules: on Node.js it uses the addon when it is installed and otherwise the wasm
`pdf` profile, produces identical PDF bytes on both, and runs its async methods on the libuv thread pool when native.
`bm-render` itself exposes no PDF on either backend, although the addon binary contains the PDF writer.


## Threading model

What runs where with the native backend:

- `renderSync`, `measureSync`, `renderSvgSync`, `renderAnimationSync`, `registerFont`: on the calling thread.
  They block the event loop for the duration of the call, exactly like the wasm build.
- `render`, `renderAsDataUrl`, `renderSvg`, `measure`, `renderAnimation`: the inputs are copied, then the
  engine runs on a **libuv thread-pool thread** and the promise settles on the JavaScript thread. The event
  loop keeps serving requests while a render is in progress.
- **One renderer handles one call at a time.** Calls on the same `Renderer` are queued in order
  (first in, first out). To render in parallel, create several renderers (each with its fonts registered) and
  spread the work over them:

```js
import { Renderer } from "bm-render";

const fonts = [/* { name, data, weight, style } ... */];
const renderers = Array.from({ length: 4 }, () => {
  const r = new Renderer();
  for (const f of fonts) r.registerFont(f);
  return r;
});
let next = 0;
export function renderPng(node, options) {
  const r = renderers[next++ % renderers.length]; // round robin
  return r.render(node, options); // runs on the libuv pool, does not block the event loop
}
```

- **Parallelism is capped by the libuv pool**, `UV_THREADPOOL_SIZE`, **4 by default**. The same pool also
  serves `fs`, `dns.lookup`, `crypto` and `zlib`. To render on more threads, set it in the environment before
  Node starts, e.g. `UV_THREADPOOL_SIZE=8 node server.js` (setting `process.env.UV_THREADPOOL_SIZE` inside the
  program only works if nothing has used the pool yet). More renderers than pool threads do not help.
- Different renderers share no state (each owns its fonts, caches and memory), so they never wait for each
  other. The addon can be loaded in
  `worker_threads` too, but on the native backend a pool of renderers in one thread does the same job without
  workers.
- With the **wasm** backend, async methods run on the calling thread by default; pass `workers` to run them
  on worker threads instead ([below](#wasm-off-the-main-thread-workers)).

## wasm off the main thread: `workers`

On the wasm backend (browsers, Deno, Bun, edge runtimes with workers, or Node.js without the addon), a render
blocks the thread it runs on: in [the benchmark](benchmark.md), a heavy 2400×2400 render stalls the event loop
for about 0.5 s and a 60-frame animation for about 0.9 s, even through the async methods. Opt in to a worker
pool per renderer:

```js
import { Renderer } from "bm-render/full";

const renderer = new Renderer({ workers: 2 }); // up to 2 workers, started on the first async call
renderer.registerFont({ name: "Inter", data: interBytes }); // reaches every worker
const png = await renderer.render(node, { width: 1200, height: 630 }); // runs in a worker
renderer.free(); // terminates the workers
```

`PdfRenderer` takes the same option: `new PdfRenderer({ workers: 2 })`.

| | |
|:--|:--|
| Runs in a worker | `render`, `renderAsDataUrl`, `renderSvg`, `measure`, `renderPdf`, `measurePdf`, `renderAnimation` (and `PdfRenderer` `render` / `measure`) |
| Stays on the calling thread | every `*Sync` method, `registerFont` / `unregisterFont` / `clearFonts`, `prepare` (it only resolves `fonts` / `images`), PDF resource discovery |
| Output | byte for byte the same as the in-thread renderer (each worker runs the same compiled wasm module) |
| Fonts | registered on the renderer, by `registerFont` or by the `fonts` option, and replayed in each worker before its next call, so a call sees the fonts of the moment it was made; `unregisterFont` / `clearFonts` too |
| Images, attachments | copied once and the copy transferred to the worker; your buffers are never detached; results are transferred back |
| Errors | reject with the same `Error` message as in-thread |
| `signal` | a queued call is dropped and rejects with `signal.reason`; a running call rejects at once and the worker finishes it, discarding the result |
| `free()` / `Symbol.dispose` | terminates the workers; pending calls reject with `bm-render: renderer has been freed` |
| Node.js process exit | idle workers are `unref`ed, so a renderer you never free does not keep the process alive |
| Native backend | `workers` is ignored: the addon already renders on the libuv thread pool |

Measured on Linux x64 with Node.js 22 (`npm run test:workers`), longest gap of a 1 ms timer while one call runs:

| Job | wasm, in-thread async | wasm, `workers: 1` |
|:--|--:|--:|
| 2400×2400 PNG (24 blurred, shadowed cards) | 440–720 ms | 5–10 ms |
| 60-frame 800×420 WebP animation | 830–1300 ms | 5–10 ms |

The render itself takes about as long (a worker adds a few ms of message passing), and calls run in parallel
up to `workers`. Each worker holds its own wasm instance: its memory, and a copy of every registered font
(the renderer also keeps one copy on the calling thread to replay fonts into workers started later).
`memoryBytes()` reports the calling thread's instance only.

Where the worker comes from:

- **Browsers, Deno, Bun**: a module Web Worker created with
  `new Worker(new URL("./worker.mjs", import.meta.url), { type: "module" })`. Vite, webpack 5 and Parcel
  recognise this form and emit the worker as its own chunk. The worker receives the compiled
  `WebAssembly.Module` that `init()` produced, so it works with any `init()` argument (bytes, a URL, a
  `Response`, a module); a runtime that cannot send a module to a worker loads the wasm from the URL `init()`
  fetched instead (or rejects, when the module was given as bytes).
- **Node.js**: `worker_threads`, with `js/worker.mjs` next to the module. When you bundle for Node.js, keep
  `bm-render` external (as for its wasm files).
- Cloudflare Workers and other runtimes without a `Worker` constructor cannot use the option.
