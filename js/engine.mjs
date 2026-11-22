// bm-render internal: the JS binding around one engine backend (a bm_render.wasm instance, or the native
// Node-API addon: see "backend" in createBinding and docs/NATIVE.md).
/** True for a WebAssembly.Module from any realm (Next.js Edge, vm contexts, iframes), where `instanceof` fails. */
const isWasmModule = (x) => Object.prototype.toString.call(x) === "[object WebAssembly.Module]";
//
// `createBinding(defaultWasm?)` returns `{ init, initSync, Renderer, features, ... }` bound to its own
// module instance. Every public entry creates exactly one binding when it is first evaluated:
//   js/index.mjs  (bm-render, explicit init)      js/node.mjs   (bm-render on Node: index.mjs + auto-init)
//   js/core.mjs / standard.mjs / full.mjs          js/node-core.mjs / node-standard.mjs / node-full.mjs
//   (bm-render/<profile>, init() finds the wasm)    (bm-render/<profile> on Node: same binding + auto-init)
// so one process can load several profiles side by side; within one binding the first successful
// init wins (later calls return the same instance). This file is not part of the public API.

/** Optional features in `bm_features()` bit order (src/config.zig `feature_bits`). */
const FEATURE_NAMES = ["css", "tw", "html", "svg", "woff", "variableFonts", "cff", "effects", "modernColor", "tables",
  "floats", "webpGifDecode", "textWrapBalance", "colorFonts", "complexText", "animation", "extraCodecs", "renderSvg", "pdf"];
const FEATURE_LABELS = { css: "stylesheet (`css` option)", html: "HTML input", woff: "WOFF/WOFF2 font", renderSvg: "renderSvg", pdf: "renderPdf",
  animation: "animation", extraCodecs: "ICO output" };

import { WorkerPool } from "./worker-pool.mjs";

const enc = new TextEncoder();
const dec = new TextDecoder();
const DISPOSE = typeof Symbol.dispose === "symbol" ? Symbol.dispose : Symbol.for("nodejs.dispose");

/** sfnt converter installed by js/addons.mjs (`loadWoff`) for builds without WOFF support (shared by every binding). */
let woffDecoder = null;
/** WOFF decoder of the native addon when it is loaded (js/native.mjs): `loadWoff()` is then a no-op. */
let builtInWoff = null;

/** @internal used by js/addons.mjs */
export function setWoffDecoder(fn) {
  woffDecoder = fn;
}

/** @internal used by js/native.mjs (sets) and js/addons.mjs (reads): the process-wide built-in WOFF decoder, or null */
export function builtInWoffDecoder(fn) {
  if (fn !== undefined) {
    builtInWoff = fn;
    woffDecoder = fn;
  }
  return builtInWoff;
}

function isWoff(b) {
  return b.length >= 4 && b[0] === 0x77 && b[1] === 0x4f && b[2] === 0x46 && (b[3] === 0x46 || b[3] === 0x32); // wOFF / wOF2
}

function toBytes(data) {
  if (data instanceof Uint8Array) return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  throw new TypeError("expected Uint8Array or ArrayBuffer");
}

function isBinary(v) {
  return v instanceof Uint8Array || v instanceof ArrayBuffer || ArrayBuffer.isView(v);
}

function normalizeUnicodeRange(value) {
  if (value == null) return null;
  const input = Array.isArray(value) ? value : typeof value === "string" ? value.split(",").map((part) => {
    const m = /^\s*U\+([0-9a-f?]{1,6})(?:-([0-9a-f]{1,6}))?\s*$/i.exec(part);
    if (!m) throw new TypeError(`bm-render: invalid unicodeRange: ${part}`);
    return [parseInt(m[1].replaceAll("?", "0"), 16), parseInt(m[2] ?? m[1].replaceAll("?", "f"), 16)];
  }) : null;
  if (!input) throw new TypeError("bm-render: unicodeRange must be ranges or a CSS unicode-range string");
  return input.map((range) => {
    if (!Array.isArray(range) || range.length !== 2 || !Number.isInteger(range[0]) || !Number.isInteger(range[1]) ||
        range[0] < 0 || range[1] > 0x10ffff || range[0] > range[1]) throw new TypeError("bm-render: invalid unicodeRange bounds");
    return [range[0], range[1]];
  });
}

function unsupported(what) {
  return new Error(`bm-render: ${what} is not supported in bm-render`);
}

const PREPARED = Symbol.for("bm-render.prepared");
/** @internal key of a binding's backend (js/worker.mjs runs serialised calls on it) */
export const BACKEND = Symbol("bm-render.backend");

/** Handle returned by `prepare` / `prepareAnimation` (opaque, like takumi's `Prepared`). */
export class Prepared {
  constructor(kind, source, options) {
    // `signal` belongs to the prepare call only: kept, an abort (or an AbortSignal.timeout firing)
    // after preparing would reject every later render of the handle.
    const { signal: _s, ...rest } = options ?? {};
    this[PREPARED] = { kind, source, options: rest };
  }
}

function unwrap(source, options, kind) {
  const p = source && source[PREPARED];
  if (!p) return [source, options];
  if (p.kind !== kind) throw new TypeError(`bm-render: this prepared handle is for ${p.kind === "anim" ? "renderAnimation" : "render"}`);
  return [p.source, { ...p.options, ...options }];
}

function throwIfAborted(signal) {
  if (signal && signal.aborted) throw signal.reason ?? new Error("bm-render: aborted");
}

function imageList(images) {
  return Array.isArray(images) ? images : images && images.sources ? images.sources : [];
}

/** Resolves lazy `images[].data()` entries (async paths only). */
async function resolveImages(images) {
  const list = imageList(images);
  if (!list.some((i) => typeof i.data === "function" || (i.data && typeof i.data.then === "function"))) return images;
  return Promise.all(list.map(async (i) => ({ ...i, data: await (typeof i.data === "function" ? i.data() : i.data) })));
}

/** Reads a `file:` URL without a static `node:fs` import (keeps browser bundlers happy). */
export async function readFileUrl(url) {
  const name = "node:fs/promises";
  const fs = await import(/* @vite-ignore */ /* webpackIgnore: true */ name);
  return new Uint8Array(await fs.readFile(url));
}

const MIME = { png: "image/png", jpeg: "image/jpeg", jpg: "image/jpeg", webp: "image/webp", ico: "image/x-icon" };

function dataUrl(format, bytes) {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return `data:${MIME[format || "png"]};base64,${btoa(bin)}`;
}

function mimeCheck(options) {
  if (!MIME[options.format || "png"]) throw new Error("bm-render: renderAsDataUrl needs an encoded format");
}

const NEEDS_INPUT = "bm-render: init() needs the wasm binary: bytes, a URL / Request / Response, or a WebAssembly.Module " +
  "(e.g. `import wasm from \"bm-render/full.wasm\"` on Cloudflare Workers). The profile entries bm-render/core, " +
  "bm-render/standard and bm-render/full locate their wasm file themselves.";

/**
 * @param {(() => URL) | undefined} defaultWasm  where `init()` without an argument loads the wasm from
 *   (called lazily, so a runtime without a usable `import.meta.url` only fails when it is actually needed)
 * @param {object} [external]  a ready backend to use instead of a wasm instance (js/native.mjs passes the
 *   native addon's); see the backend interface below. init() / initSync() are then no-ops.
 */
export function createBinding(defaultWasm, external) {
  /** @type {WebAssembly.Exports & Record<string, any>} */
  let wasm = null;
  /** in-flight `init()` (concurrent callers share it) */
  let pending = null;
  /** the compiled module behind `wasm`, and the URL it was loaded from if any (for `workers`, js/worker-pool.mjs) */
  let wasmModule = null;
  let wasmSourceUrl = null;

  /**
   * Optional features of the loaded wasm binary (all false before init). Binaries older than the
   * `bm_features` export report every feature as available.
   * @type {Record<string, boolean>}
   */
  const features = Object.fromEntries(FEATURE_NAMES.map((n) => [n, false]));

  function setFeatures(m = typeof wasm.bm_features === "function" ? wasm.bm_features() >>> 0 : 0xffffffff) {
    FEATURE_NAMES.forEach((n, i) => { features[n] = ((m >>> i) & 1) === 1; });
  }

  const FULL_ONLY = new Set(["renderSvg", "animation", "extraCodecs", "colorFonts", "complexText"]);
  function requireFeature(name) {
    if (!features[name]) {
      if (name === "pdf") throw new Error("bm-render: renderPdf is not supported by this build (use the pdf build: import from \"bm-render/pdf\")");
      throw new Error(`bm-render: this build has no ${FEATURE_LABELS[name] || name} support (use the ${FULL_ONLY.has(name) ? "full" : "standard / full"} build${name === "woff" ? ", or load the WOFF add-on: import { loadWoff } from \"bm-render/woff\"; await loadWoff()" : ""})`);
    }
  }

  function u8() {
    return new Uint8Array(wasm.memory.buffer);
  }

  /** Copies bytes into wasm memory; returns [ptr, len]. Caller frees unless ownership is transferred. */
  function copyIn(bytes) {
    const len = bytes.length;
    const ptr = wasm.bm_alloc(len || 1);
    if (!ptr) throw new Error("bm-render: out of memory");
    u8().set(bytes, ptr);
    return [ptr, len];
  }

  function copyInString(str) {
    // Worst case 3 bytes per UTF-16 unit; encodeInto avoids an intermediate buffer.
    const cap = str.length * 3 || 1;
    const ptr = wasm.bm_alloc(cap);
    if (!ptr) throw new Error("bm-render: out of memory");
    const { written } = enc.encodeInto(str, u8().subarray(ptr, ptr + cap));
    return [ptr, written, cap];
  }

  function lastError() {
    const ptr = wasm.bm_last_error_ptr();
    const len = wasm.bm_last_error_len();
    return dec.decode(u8().subarray(ptr, ptr + len));
  }

  function check(status) {
    if (status !== 0) throw new Error("bm-render: " + (lastError() || "error " + status));
  }

  function adopt(instance, module) {
    if (!wasm) {
      wasmModule = module;
      wasm = instance.exports;
      setFeatures();
    }
    return wasm;
  }

  // ---- backend -----------------------------------------------------------------------------------------
  // Everything below this block talks to the engine only through `backend`:
  //
  //   name                 "wasm" | "native"
  //   ready()              false until the engine can be used (wasm: before init)
  //   has(op)              whether the build provides the operation
  //   create() -> handle   a renderer (truthy);  destroy(handle)
  //   run(handle, op, arg0, arg1, input, options, attachments, text) -> Uint8Array | string
  //       One engine operation. `op`: "render" | "measure" | "svg" | "pdf" | "pdfMeasure" (arg0 = source kind:
  //       0 JSON tree, 1 HTML; input = the source text, options = options JSON), "animation" (input = options JSON),
  //       "registerFont" (arg0 = weight, arg1 = italic -1 | 0 | 1 as u32, input = family name, attachments =
  //       the font file), "unregisterFont" (input = family; result [0 | 1]), "clearFonts".
  //       `attachments`: null or a flat array of [key, bytes, flags, width, height] groups; for the source
  //       ops they are the call's image sources (flags bit 0 = raw RGBA width x height, bit 1 = premultiplied).
  //       Returns a fresh Uint8Array, or with `text` the result decoded as UTF-8. Throws Error("bm-render: ...").
  //   runAsync?(same) -> Promise   optional: the same off the calling thread, inputs snapshotted at the call
  //                        (native). Without it the async API runs `run`.
  //   memoryBytes()        bytes the engine currently holds
  //
  // A new output kind (e.g. PDF) = one more `op` here (the wasm export to call) + its entry in
  // src/native/ops.zig + the public method below. See docs/NATIVE.md.

  /** The result of the last call on `h`: a copy of the bytes, or the decoded text. */
  function take(h, text, release) {
    const ptr = wasm.bm_result_ptr(h);
    const len = wasm.bm_result_len(h);
    const out = text ? dec.decode(u8().subarray(ptr, ptr + len)) : u8().slice(ptr, ptr + len);
    if (release) wasm.bm_release_result(h);
    return out;
  }

  /** Replaces the renderer's image sources with `atts` (copied into wasm memory). */
  function putImages(h, atts) {
    wasm.bm_clear_images(h);
    for (let i = 0; atts && i < atts.length; i += 5) {
      const [sptr, slen, scap] = copyInString(atts[i]);
      const [dptr, dlen] = copyIn(atts[i + 1]);
      const status = atts[i + 2] & 1
        ? wasm.bm_put_rgba(h, sptr, slen, dptr, dlen, atts[i + 3], atts[i + 4], atts[i + 2] & 2 ? 1 : 0)
        : wasm.bm_put_image(h, sptr, slen, dptr, dlen);
      wasm.bm_free(sptr, scap);
      wasm.bm_free(dptr, dlen || 1);
      check(status);
    }
  }

  /** Source ops: the export taking (handle, kind, source, options); [1] = pre-`*_src` export (JSON only). */
  const SOURCE_OPS = { render: ["bm_render_src", "bm_render"], measure: ["bm_measure_src", "bm_measure"], svg: ["bm_render_svg"],
    pdf: ["bm_render_pdf"], pdfMeasure: ["bm_measure_pdf"], pdfNeeds: ["bm_needs_pdf"] };

  const backend = external || {
    name: "wasm",
    ready: () => wasm !== null,
    has: (op) => (op === "animation" ? !!wasm.bm_render_animation : true),
    create: () => wasm.bm_renderer_new(),
    destroy: (h) => wasm.bm_renderer_free(h),
    memoryBytes: () => wasm.memory.buffer.byteLength,
    run(h, op, arg0, arg1, input, options, atts, text) {
      if (SOURCE_OPS[op]) {
        putImages(h, atts);
        const [jptr, jlen, jcap] = copyInString(input);
        const [optr, olen, ocap] = copyInString(options);
        const [name, legacy] = SOURCE_OPS[op];
        // (older binaries without the *_src exports accept JSON only)
        const status = wasm[name] ? wasm[name](h, arg0, jptr, jlen, optr, olen)
          : arg0 === 0 && legacy ? wasm[legacy](h, jptr, jlen, optr, olen)
          : -1;
        wasm.bm_free(jptr, jcap);
        wasm.bm_free(optr, ocap);
        if (status === -1) throw new Error("bm-render: this wasm build does not accept HTML sources");
        check(status);
        return take(h, text, true);
      }
      if (op === "animation") {
        putImages(h, atts);
        const [ptr, len, cap] = copyInString(input);
        const status = wasm.bm_render_animation(h, ptr, len);
        wasm.bm_free(ptr, cap);
        check(status);
        return take(h, text, true);
      }
      if (op === "registerFont") {
        const [ptr, len] = copyIn(atts[1]);
        const [nptr, nlen, ncap] = copyInString(input);
        const [optr, olen, ocap] = copyInString(options || "");
        // Ownership of the font bytes moves to the renderer (zero-copy parsing inside wasm).
        const status = wasm.bm_register_font_options
          ? wasm.bm_register_font_options(h, ptr, len, nptr, nlen, arg0, arg1, optr, olen)
          : wasm.bm_register_font(h, ptr, len, nptr, nlen, arg0, arg1);
        wasm.bm_free(nptr, ncap);
        wasm.bm_free(optr, ocap);
        check(status);
        return take(h, text, false);
      }
      if (op === "unregisterFont") {
        const [nptr, nlen, ncap] = copyInString(input);
        const r = wasm.bm_unregister_font(h, nptr, nlen);
        wasm.bm_free(nptr, ncap);
        return Uint8Array.of(r !== 0 ? 1 : 0);
      }
      if (op === "clearFonts") {
        wasm.bm_clear_fonts(h);
        return new Uint8Array(0);
      }
      throw unsupported(op);
    },
  };
  if (external) setFeatures(external.featureBits());

  /** Synchronously instantiate from bytes or a compiled WebAssembly.Module (or `{ module }`). */
  function initSync(input) {
    if (external) return external.exports;
    if (wasm) return wasm;
    if (input && typeof input === "object" && "module" in input && !isWasmModule(input)) input = input.module;
    if (input == null) throw new Error(NEEDS_INPUT.replace("init()", "initSync()"));
    const mod = isWasmModule(input) ? input : new WebAssembly.Module(input);
    return adopt(new WebAssembly.Instance(mod, {}), mod);
  }

  async function load(input) {
    input = await input;
    if (input && typeof input === "object" && "module_or_path" in input) input = await input.module_or_path;
    if (input == null) {
      if (!defaultWasm) throw new Error(NEEDS_INPUT);
      let url;
      try {
        url = defaultWasm();
      } catch (e) {
        throw new Error("bm-render: cannot locate the wasm file in this runtime (no usable import.meta.url); pass it to init() " +
          "explicitly, e.g. `import wasm from \"bm-render/core.wasm\"; await init(wasm)` (" + (e && e.message) + ")");
      }
      wasmSourceUrl = url.href;
      input = url.protocol === "file:" ? await readFileUrl(url) : url;
    }
    if (typeof input === "string" || (typeof URL !== "undefined" && input instanceof URL) ||
        (typeof Request !== "undefined" && input instanceof Request)) {
      try { wasmSourceUrl = new URL(input.url ?? String(input), globalThis.location?.href).href; } catch {}
      const res = await fetch(input);
      if (!res.ok) throw new Error(`bm-render: failed to fetch the wasm (${res.status} ${res.statusText || ""}): ${res.url || input}`);
      input = res;
    }
    if (typeof Response !== "undefined" && input instanceof Response) {
      if (WebAssembly.instantiateStreaming && (input.headers.get("content-type") || "").startsWith("application/wasm")) {
        const { instance, module } = await WebAssembly.instantiateStreaming(input, {});
        return adopt(instance, module);
      }
      input = await input.arrayBuffer();
    }
    if (isWasmModule(input)) return adopt(await WebAssembly.instantiate(input, {}), input);
    const { instance, module } = await WebAssembly.instantiate(input, {});
    return adopt(instance, module);
  }

  /**
   * Instantiate from a URL / Request / Response / Promise<Response> / bytes / WebAssembly.Module
   * (or `{ module_or_path }`). Idempotent: once initialised, every call resolves to the same instance and
   * ignores its argument; concurrent calls share one instantiation; a failed call can be retried.
   */
  function init(input) {
    if (external) return Promise.resolve(external.exports);
    if (wasm) return Promise.resolve(wasm);
    if (!pending) {
      pending = load(input).finally(() => { pending = null; });
    }
    return pending;
  }

  class Renderer {
    #h = 0;
    #resSeq = 0;
    /** `fonts` entries of renders registered so far (takumi dedupes them across calls), by the loader's
     * bytes / object and its name, weight and style; stale once a font is unregistered or cleared */
    #fontsSeen = new WeakMap();
    #fontsByUrl = new Map();
    #fontsGen = 0;
    /** attachments of the call being prepared: flat [key, bytes, flags, width, height] groups */
    #atts = [];
    /** `workers` option on the wasm backend: the async API runs on these (js/worker-pool.mjs) */
    #pool = null;

    constructor(options = {}) {
      if (!backend.ready()) throw new Error("bm-render: call init()/initSync() before creating a Renderer");
      const workers = options && options.workers;
      if (workers != null && workers !== false && (!Number.isInteger(workers) || workers < 0)) {
        throw new TypeError("bm-render: workers must be a non-negative integer");
      }
      this.#h = backend.create();
      if (!this.#h) throw new Error("bm-render: out of memory");
      // (native: the async API already runs on the libuv thread pool, so `workers` is ignored)
      if (workers > 0 && !backend.runAsync) this.#pool = new WorkerPool(workers, () => ({ module: wasmModule, url: wasmSourceUrl }));
    }

    #handle() {
      if (!this.#h) throw new Error("bm-render: renderer has been freed");
      return this.#h;
    }

    /**
     * Register a font: TTF/OTF/TTC (every face of a collection), variable fonts, and WOFF/WOFF2 when the
     * build includes them. Accepts raw bytes or `{ name, data, weight, style }`. Returns takumi's
     * `RegisteredFamily[]`: `[{ name, faces: [{ weight, style, width, index }], weight, style }]`.
     * A URL string, or `data` given as a function / promise, makes it async (returns a Promise).
     */
    registerFont(font) {
      if (typeof font === "string" || (typeof URL !== "undefined" && font instanceof URL)) {
        return fetch(font).then((res) => {
          if (!res.ok) throw new Error(`bm-render: failed to fetch font ${font}: ${res.status}`);
          return res.arrayBuffer();
        }).then((buf) => this.registerFont(new Uint8Array(buf)));
      }
      if (font && typeof font.then === "function") return font.then((f) => this.registerFont(f));
      const details = isBinary(font) ? { data: font } : font;
      if (!details || details.data == null) throw new TypeError("bm-render: registerFont expects bytes or { data }");
      if (typeof details.data === "function" || typeof details.data.then === "function") {
        return Promise.resolve(typeof details.data === "function" ? details.data() : details.data)
          .then((data) => this.registerFont({ ...details, data }));
      }
      const h = this.#handle();
      let bytes = toBytes(details.data);
      if (!features.woff && isWoff(bytes)) {
        if (!woffDecoder) requireFeature("woff");
        bytes = woffDecoder(bytes);
      }
      const italic = details.style == null ? -1 : /italic|oblique/.test(String(details.style)) ? 1 : 0;
      const unicodeRange = normalizeUnicodeRange(details.unicodeRange);
      const fontOptions = unicodeRange == null ? null : JSON.stringify({ unicodeRange });
      const weight = (details.weight | 0) >>> 0;
      const name = details.name || "";
      const out = JSON.parse(backend.run(h, "registerFont", weight, italic >>> 0, name, fontOptions, ["", bytes, 0, 0, 0], true));
      if (this.#pool) this.#pool.font("registerFont", weight, italic >>> 0, name, fontOptions, bytes);
      return out;
    }

    /** takumi-compatible alias. */
    loadFont(font) {
      return this.registerFont(font);
    }

    /** Removes every face of `family` (a name or `{ name }`). Returns true when something was removed. */
    unregisterFont(family) {
      this.#fontsGen++;
      const name = family && typeof family === "object" ? family.name : family;
      const removed = backend.run(this.#handle(), "unregisterFont", 0, 0, String(name), null, null, false)[0] !== 0;
      if (removed && this.#pool) this.#pool.font("unregisterFont", 0, 0, String(name), null, null);
      return removed;
    }

    clearFonts() {
      this.#fontsGen++;
      backend.run(this.#handle(), "clearFonts", 0, 0, null, null, null, false);
      if (this.#pool) this.#pool.font("clearFonts", 0, 0, null, null, null);
    }

    /** Runs a prepared call (`#call` / `#animation`) on the calling thread; `text`: decode the result as UTF-8. */
    #run(job, text = false) {
      return backend.run(this.#handle(), job.op, job.kind, 0, job.text, job.opts, job.atts, text);
    }

    /**
     * Like #run for the async API: off the calling thread when the backend can (native) or on a worker
     * (`workers` option), else the same call. `job.signal` (worker pool only) drops a queued job.
     */
    #runAsync(job, text = false) {
      if (this.#pool) return this.#pool.run(job, text, job.signal);
      return backend.runAsync ? backend.runAsync(this.#handle(), job.op, job.kind, job.rawBytes || 0, job.text, job.opts, job.atts, text) : this.#run(job, text);
    }

    /** Attaches encoded image bytes to the call being prepared, as the image source `src`. */
    #putImage(src, data) {
      this.#atts.push(String(src), toBytes(data), 0, 0, 0);
    }

    /** Attaches raw RGBA pixels to the call being prepared, as the image source `src`. */
    #putRgba(src, img) {
      this.#atts.push(String(src), toBytes(img.data), img.premultiplied ? 3 : 1, img.width >>> 0, img.height >>> 0);
    }

    /** JSON.stringify where binary / RGBA image `src` values become attachments and are replaced by ids. */
    #stringify(value) {
      const self = this;
      return JSON.stringify(value, function (key, v) {
        // `this[key]` is the raw value: a Node Buffer reaches the replacer already converted by Buffer#toJSON.
        if (key === "src" && this && this[key] && typeof this[key] === "object") v = this[key];
        if (key === "src" && v && typeof v === "object") {
          const id = "bm-res:" + self.#resSeq++;
          if (isBinary(v)) self.#putImage(id, v);
          else if (v.data && v.width) self.#putRgba(id, v);
          else return v;
          return id;
        }
        return v;
      });
    }

    /** Attaches the `images` option entries the source text references. */
    #putImages(images, text, own) {
      for (const img of imageList(images)) {
        if (typeof img.data === "function") throw new TypeError("bm-render: lazy images[].data() needs the async API");
        const needle = JSON.stringify(String(img.src)).slice(1, -1);
        if (!own || text.includes(needle)) this.#putImage(img.src, img.data);
      }
    }

    /**
     * Serialises the source; binary image sources become attachments of the call and are replaced by ids.
     * Returns [text, kind] with kind 0 = JSON node tree, 1 = HTML markup.
     */
    #prepareSource(node, options, extra) {
      this.#handle();
      this.#atts = [];
      let json;
      let kind = 0;
      let own = false; // true when we produced the JSON ourselves (so escaping is predictable)
      // takumi semantics: every JS string is HTML; a JSON tree as text is passed as { json }.
      if (typeof node === "string") { requireFeature("html"); json = node; kind = 1; }
      else if (node && typeof node === "object" && typeof node.json === "string" && node.type === undefined) json = node.json;
      else { own = true; json = this.#stringify(node); }
      // `extra` (renderPdf): produces more text that may reference images (header / footer bands) and attaches
      // its own blobs to the call (after the reset above).
      const more = extra ? extra() : "";
      // Only images the tree actually references are passed to the engine.
      this.#putImages(options.images, more ? json + "\n" + more : json, own);
      return [json, kind];
    }

    /** Validates and serialises one render / svg / measure call; returns the job for #run / #runAsync. */
    #call(which, node, options) {
      [node, options] = unwrap(node, options, "render");
      throwIfAborted(options.signal);
      if ((options.css != null && options.css.length !== 0) || (options.stylesheets != null && options.stylesheets.length !== 0)) requireFeature("css");
      if (options.format === "ico") requireFeature("extraCodecs");
      if (which === "svg") requireFeature("renderSvg");
      const [json, kind] = this.#prepareSource(node, options);
      // `images` were attached above; `fonts`/`signal` are JS-side takumi options.
      const { images: _i, fonts: _f, signal: _s, ...rest } = options;
      // (native async: the byte size of a raw frame whose size is given, so its buffer can be made up front)
      const { width: w, height: h } = rest;
      const rawBytes = which === "render" && rest.format === "raw" && Number.isInteger(w) && Number.isInteger(h) && w > 0 && h > 0 && w * h <= 40e6 ? w * h * 4 : 0;
      return { op: which, kind, text: json, opts: JSON.stringify(rest), atts: this.#atts, rawBytes, signal: options.signal };
    }

    /** Async option extras (takumi `RenderExtras`): `fonts` loaders and lazy `images`. */
    async #extras(options) {
      let o = options;
      if (o.fonts) {
        const loaders = await o.fonts;
        const names = [];
        for (const f of loaders) {
          const fams = await this.#registerOnce(f);
          for (const fam of fams || []) if (!names.includes(fam.name)) names.push(fam.name);
        }
        const { fonts: _f, ...rest } = o;
        o = o.fontFamilies || names.length === 0 ? rest : { ...rest, fontFamilies: names };
      }
      if (o.images) o = { ...o, images: await resolveImages(o.images) };
      return o;
    }

    /** Registers one `fonts` entry of a render unless this renderer already holds it (a Promise when the entry is lazy). */
    #registerOnce(f) {
      let map = this.#fontsByUrl;
      let obj = null;
      let sub = "";
      if (f !== null && typeof f === "object" && !(typeof URL !== "undefined" && f instanceof URL) && typeof f.then !== "function") {
        obj = isBinary(f) || f.data == null || (typeof f.data !== "object" && typeof f.data !== "function") ? f : f.data;
        if (obj !== f) sub = JSON.stringify([f.name ?? "", f.weight ?? null, f.style ?? null, f.key ?? null, f.unicodeRange ?? null]);
        map = this.#fontsSeen.get(obj);
        if (!map) this.#fontsSeen.set(obj, (map = new Map()));
      } else if (typeof f === "string" || (typeof URL !== "undefined" && f instanceof URL)) sub = String(f);
      else return this.registerFont(f);
      const hit = map.get(sub);
      if (hit && hit.gen === this.#fontsGen) return hit.fams;
      const gen = this.#fontsGen;
      const keep = (fams) => { map.set(sub, { gen, fams }); return fams; };
      const r = this.registerFont(f);
      return r && typeof r.then === "function" ? r.then(keep) : keep(r);
    }

    /**
     * #extras for the sync API: registers `fonts` given as bytes or `{ data: bytes }` (a URL, a promise
     * or a lazy `data()` loader needs the async API and throws). Lazy images throw later, in #putImages.
     */
    #extrasSync(options) {
      if (!options.fonts) return options;
      const loaders = options.fonts;
      if (typeof loaders.then === "function" || !loaders[Symbol.iterator]) throw new TypeError("bm-render: a fonts promise needs the async API");
      for (const f of loaders) {
        const lazy = typeof f === "string" || (typeof URL !== "undefined" && f instanceof URL) || (f && typeof f.then === "function") ||
          (f && !isBinary(f) && (typeof f.data === "function" || (f.data && typeof f.data.then === "function")));
        if (lazy) throw new TypeError("bm-render: fonts[] entries given as a URL, a promise or a lazy data() loader need the async API");
      }
      const names = [];
      for (const f of loaders) {
        for (const fam of this.#registerOnce(f) || []) if (!names.includes(fam.name)) names.push(fam.name);
      }
      const { fonts: _f, ...rest } = options;
      return options.fontFamilies || names.length === 0 ? rest : { ...rest, fontFamilies: names };
    }

    /**
     * Render synchronously. Returns a fresh Uint8Array (PNG by default; `format: "raw"` = straight RGBA8).
     *
     * `source`: a takumi node object, `{ json: string }` (a node tree as JSON text), a STRING = HTML
     * markup (`<style>` elements are honoured), or a handle from `prepare()`.
     * `options` (takumi RenderOptions): `width`, `height`, `format` ("png"|"jpeg"|"webp"|"ico"|"raw"),
     * `quality` (jpeg), `lossless` (ignored: webp is always lossless), `devicePixelRatio`, `images`
     * ([{src, data}] or {sources}), `css` (stylesheet strings and/or takumi rule objects), `stylesheets`
     * (deprecated), `keyframes` (deprecated keyframes map/list), `timeMs` (CSS animation timeline, default 0),
     * `fontFamilies`, `lang`, `drawDebugBorder` / `dithering` (accepted, ignored).
     */
    renderSync(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      return this.#run(this.#call("render", node, this.#extrasSync(options)));
    }

    /**
     * takumi-compatible async signature. On the wasm backend rendering itself is synchronous (on a worker with
     * the `workers` option); the native backend renders on a thread-pool thread (inputs snapshotted at the call).
     */
    async render(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      return this.#runAsync(this.#call("render", node, await this.#extras(options)));
    }

    renderAsDataUrlSync(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      mimeCheck(options);
      return dataUrl(options.format, this.renderSync(node, options));
    }

    async renderAsDataUrl(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      options = await this.#extras(options);
      mimeCheck(options);
      return dataUrl(options.format, await this.#runAsync(this.#call("render", node, options)));
    }

    /**
     * takumi `renderSvg`: the source as an SVG document string (vector boxes, gradients, borders,
     * shadows as filters, images embedded as data URLs, text as glyph outlines). Needs a build with
     * `render_svg` (the full profile); `format` / `quality` are ignored.
     */
    renderSvgSync(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      return this.#run(this.#call("svg", node, this.#extrasSync(options)), true);
    }

    async renderSvg(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      return this.#runAsync(this.#call("svg", node, await this.#extras(options)), true);
    }

    /** renderPdf / measurePdf options as JSON text; attachment bytes and band images become attachments of the call. */
    #pdfOptionsText(options) {
      const { images: _i, fonts: _f, signal: _s, attachments, ...rest } = options;
      const o = { ...rest };
      if (attachments != null) {
        if (!Array.isArray(attachments)) throw new TypeError("bm-render: attachments takes an array");
        o.attachments = attachments.map((a) => {
          if (a == null || typeof a !== "object") return a;
          let { data, ...meta } = a;
          // takumi-pdf (serde ByteBuf) also takes a plain array of byte values
          if (Array.isArray(data) && data.every((v) => Number.isInteger(v) && v >= 0 && v <= 255)) data = Uint8Array.from(data);
          if (isBinary(data)) {
            const id = "bm-att:" + this.#resSeq++;
            this.#putImage(id, data);
            return { ...meta, dataRef: id };
          }
          return data === undefined ? meta : { ...meta, data };
        });
      }
      return this.#stringify(o);
    }

    /** Validates and serialises one renderPdf / measurePdf call; returns the job for #run / #runAsync. */
    #callPdf(which, node, options) {
      [node, options] = unwrap(node, options, "render");
      throwIfAborted(options.signal);
      requireFeature("pdf");
      if ((options.css != null && options.css.length !== 0) || (options.stylesheets != null && options.stylesheets.length !== 0)) requireFeature("css");
      let text;
      const [json, kind] = this.#prepareSource(node, options, () => (text = this.#pdfOptionsText(options)));
      return { op: which === "render" ? "pdf" : which === "needs" ? "pdfNeeds" : "pdfMeasure", kind, text: json, opts: text, atts: this.#atts, signal: options.signal };
    }

    /**
     * takumi-pdf `render`: the source as a PDF file. Needs a build with `pdf` (bm-render/pdf). Options: takumi-pdf's
     * `PdfRenderOptions` (`viewport` | `size` / `landscape` / `margin` / `header` / `footer` / `pages` /
     * `pageRanges`, `metadata`, `outline`, `pdfa`, `tagged`, `attachments`, `uncoveredText`, `backgroundColor`,
     * `css`, `cssVariables`, `fontFamilies`, `lang`, `images`, `fonts`, `signal`); see js/pdf-types.d.mts.
     */
    renderPdfSync(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      return this.#run(this.#callPdf("render", node, this.#extrasSync(options)));
    }

    async renderPdf(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      return this.#runAsync(this.#callPdf("render", node, await this.#extras(options)));
    }

    /** takumi-pdf `measure`: `{ width, height }` in CSS px, laid out like a header / footer band (see pdf.d.mts). */
    measurePdfSync(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      return JSON.parse(this.#run(this.#callPdf("measure", node, this.#extrasSync(options)), true));
    }

    async measurePdf(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      return JSON.parse(await this.#runAsync(this.#callPdf("measure", node, await this.#extras(options)), true));
    }

    /** Internal cascade-only resource discovery; no font loaders or image fetches run here. */
    needsPdfSync(node, options = {}) {
      return JSON.parse(this.#run(this.#callPdf("needs", node, options), true));
    }

    /** Lay out only. Returns `{ width, height, transform, children, runs }` like takumi's `measure`. */
    measureSync(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      return JSON.parse(this.#run(this.#call("measure", node, this.#extrasSync(options)), true));
    }

    async measure(node, options = {}) {
      [node, options] = unwrap(node, options, "render");
      return JSON.parse(await this.#runAsync(this.#call("measure", node, await this.#extras(options)), true));
    }

    /**
     * takumi `prepare`: resolves `fonts` / lazy `images` and returns a handle for `render`,
     * `renderAsDataUrl` and `measure` (whose options are merged over the prepared ones). bm-render does
     * not fetch remote resources here (no `needs` pass): pass image bytes via `images`.
     */
    async prepare(source, options = {}) {
      return new Prepared("render", source, await this.#extras(options));
    }

    /** takumi `prepareAnimation`: like `prepare`, for `renderAnimation`. */
    async prepareAnimation(options = {}) {
      const { scenes, ...rest } = options;
      return new Prepared("anim", scenes, await this.#extras(rest));
    }

    /**
     * takumi `renderAnimation`: `{ scenes: [{ node, durationMs }], width, height, fps, format?: "webp" |
     * "apng" | "gif" (default webp, always lossless), css?, stylesheets?, keyframes?, images?,
     * devicePixelRatio?, fontFamilies?, lang? }` -> encoded animation. Frame schedule as takumi-raster:
     * ceil(total * fps / 1000) frames, frame i at floor(i * 1000 / fps) ms (time restarts per scene).
     * Max fps: 50 for gif, 90 for webp / apng.
     */
    renderAnimationSync(options) {
      return this.#run(this.#animation(options && !options[PREPARED] ? this.#extrasSync(options) : options));
    }

    /** Validates and serialises one renderAnimation call; returns the job for #run / #runAsync. */
    #animation(options) {
      let scenes = options.scenes;
      if (options[PREPARED]) {
        const p = options[PREPARED];
        if (p.kind !== "anim") throw new TypeError("bm-render: this prepared handle is for render");
        scenes = p.source;
        options = { ...p.options };
      }
      throwIfAborted(options.signal);
      if (!backend.has("animation")) throw unsupported("renderAnimation (this wasm build)");
      requireFeature("animation");
      this.#handle();
      this.#atts = [];
      const { images, fonts: _f, signal: _s, scenes: _sc, ...rest } = options;
      const text = this.#stringify({ ...rest, scenes: scenes || [] });
      this.#putImages(images, text, true);
      return { op: "animation", kind: 0, text, opts: null, atts: this.#atts, signal: options.signal };
    }

    async renderAnimation(options, extra = {}) {
      if (options && options[PREPARED]) {
        throwIfAborted(extra.signal);
        return this.#runAsync({ ...this.#animation(options), signal: extra.signal });
      }
      return this.#runAsync(this.#animation(await this.#extras(options)));
    }

    /**
     * Bytes the engine currently holds: the wasm linear memory size (shared by all renderers of this module
     * instance), or on the native backend the bytes allocated by the addon in this process.
     */
    memoryBytes() {
      return backend.memoryBytes();
    }

    static memoryBytes() {
      return backend.ready() ? backend.memoryBytes() : 0;
    }

    /** Releases the renderer; with `workers`, terminates them and rejects the async calls still pending. */
    free() {
      if (this.#pool) this.#pool.terminate();
      this.#pool = null;
      if (this.#h) backend.destroy(this.#h);
      this.#h = 0;
    }

    [DISPOSE]() {
      this.free();
    }
  }

  /** takumi module function. bm-render's glyph-mask budget is fixed (8 MiB): accepted and ignored. */
  function setGlyphCacheMaxBytes(bytes) {
    void bytes;
  }

  /** Where `init()` without an argument loads the wasm from (profile entries), else undefined. */
  function wasmUrl() {
    return defaultWasm ? defaultWasm() : undefined;
  }

  return { init, initSync, Renderer, Prepared, features, setGlyphCacheMaxBytes, wasmUrl, backend: backend.name, [BACKEND]: backend };
}
