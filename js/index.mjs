// bm-render — dependency-free ESM wrapper around bm_render.wasm (the environment-neutral entry,
// `import ... from "bm-render"` everywhere except Node.js). Works in browsers, Node.js, Bun, Deno and edge
// runtimes. The wasm module has NO imports. You pass the wasm binary to init() yourself:
//
//   import { init, Renderer } from "bm-render";
//   await init(wasm);  // bytes | URL | Request | Response | Promise<Response> | WebAssembly.Module
//   const r = new Renderer();
//   r.registerFont(fontBytes);
//   const png = r.renderSync(node, { width: 1200, height: 630 });
//
// (bm-render/core, bm-render/standard, bm-render/full find their wasm file themselves: `await init()`;
// on Node.js `bm-render` and every profile entry are initialised on import.)
//
// The node format and render options follow takumi (`@takumi-rs/wasm` 2.20), so the same input renders on
// both: a source is a node object, `{ json: string }`, or a string of HTML; `css`, `tw`, `className` etc. are
// honoured when the wasm build includes them. Typings: ./index.d.mts. Implementation: ./engine.mjs.
//
// takumi `Renderer` API parity (async methods resolve immediately; every one has a *Sync twin here):
//
//   takumi                         bm-render
//   ----------------------------   ---------------------------------------------------------------------------
//   new Renderer(options)          works; `cacheMaxBytes` / `fontCacheMaxBytes` accepted and ignored (fixed
//                                  budgets: 96 MiB decoded images, 8 MiB glyph masks); bm-render adds
//                                  `workers: N` (async methods on Web Workers / worker_threads, js/worker-pool.mjs)
//   registerFont(font)             works for bytes, `{ name, data, weight, style }` (data may be a function /
//                                  promise -> async) and URL strings (fetched); `unicodeRange`, `subsetOf`,
//                                  `generic` ignored (every face is registered eagerly)
//   unregisterFont(family)         works (`{ name }` or a string)
//   clearFonts()                   works
//   render(source, options)        works: png | jpeg | webp (always lossless, like takumi-wasm) | ico | raw;
//                                  `timeMs` samples CSS animations; `fonts` (FontLoader[]) registers the fonts
//                                  and, without `fontFamilies`, makes them the fallback stack; `images`
//                                  (array or `{ sources }`, lazy `data()` allowed); `signal` checked before
//                                  rendering. Remote image URLs are NOT fetched (as in takumi without prepare)
//   renderAsDataUrl                works (raw rejected)
//   renderSvg                      works (builds with `render_svg`: the full profile); renderSvgSync twin
//   measure                        works
//   (takumi-pdf)                   renderPdf / measurePdf (+ Sync twins): builds with `pdf`, i.e. bm-render/pdf (js/pdf.mjs)
//   prepare(source, options)       returns a prepared handle; `render`/`renderAsDataUrl`/`measure` accept it and
//                                  merge its options. NOTE: unlike takumi it fetches nothing (no `needs` pass):
//                                  remote images / @font-face files must be passed as `images` / fonts
//   prepareAnimation(options)      same, for renderAnimation
//   renderAnimation(options)       works: webp (default, lossless) | apng | gif; takumi's frame schedule
//   read / readAnimation           private in takumi: not provided
//   free / [Symbol.dispose]        works
//   setGlyphCacheMaxBytes(bytes)   module function accepted and ignored (fixed 8 MiB glyph budget)
//
// Build profiles (scripts/build.mjs): bm_render.core.wasm (JSON nodes + inline styles, flex/grid/block,
// static TTF, PNG/JPEG in), bm_render.standard.wasm (+ css, tw, html, svg images, woff2, variable fonts,
// cff, effects, modern colours, tables, floats, webp/gif in, text-wrap balance) and bm_render.wasm = full
// (+ complex text, colour emoji, animation, extra codecs, renderSvg). `features` (filled by init) tells
// which optional features the loaded binary has; using a missing one throws a clear error.
//
// One module instance per entry: this entry (and js/node.mjs, which initialises it on Node) share one;
// bm-render/core, /standard and /full each have their own, so several profiles can coexist in a process.
// Within one entry the first successful init wins; later init() calls return the same instance.
import { createBinding } from "./engine.mjs";

const binding = createBinding();

export const { init, initSync, Renderer, features, setGlyphCacheMaxBytes } = binding;
/** Which engine build is active: "wasm" here; "native" when Node.js loaded the Node-API addon (js/node.mjs). */
export const backend = "wasm";
export { Prepared, setWoffDecoder } from "./engine.mjs";
export default init;
