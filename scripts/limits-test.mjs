// Tests of the `limits` option (`npm run test:limits`): per call, per Renderer, the tighten-only merge, and the
// errors / skipped images when one is exceeded. Runs against the built wasm (js/*.wasm) of the full and pdf profiles.
import assert from "node:assert/strict";
import { Renderer } from "../js/node-full.mjs";
import { PdfRenderer } from "../js/node-pdf.mjs";

const red = new Renderer();
const png = red.renderSync({ type: "container", style: { width: 10, height: 10, backgroundColor: "red" } }, { width: 10, height: 10 });
const image = { type: "image", src: "a", style: { width: 10, height: 10 } };
const raw = { width: 10, height: 10, format: "raw", images: [{ src: "a", data: png }] };
/** First pixel of `image` rendered by `r` with the extra options `o` (sync and async must agree). */
async function pixel(r, o = {}) {
  const a = r.renderSync(image, { ...raw, ...o });
  const b = await r.render(image, { ...raw, ...o });
  assert.deepEqual(a, b);
  return [...a.subarray(0, 4)];
}
const RED = [255, 0, 0, 255];
const NONE = [0, 0, 0, 0];

// per call: an image over a limit is skipped (like one that does not decode); the cache does not leak it
const r = new Renderer();
assert.deepEqual(await pixel(r), RED);
assert.deepEqual(await pixel(r, { limits: { maxImagePixels: 99 } }), NONE);
assert.deepEqual(await pixel(r, { limits: { maxImagePixels: 100 } }), RED);
assert.deepEqual(await pixel(r, { limits: { maxImageBytes: png.length - 1 } }), NONE);
assert.deepEqual(await pixel(r, { limits: { maxImageBytes: png.length } }), RED);
assert.deepEqual(await pixel(r), RED, "a call without limits is back at the built-in caps");
// values above the built-in caps are clamped, not an error
assert.deepEqual(await pixel(r, { limits: { maxImagePixels: 1e15, maxAnimationFrames: 1e9, maxCanvasPixels: 1e12, maxNodeDepth: 1e6 } }), RED);
// binary `src` values (attachments) obey them too
const bin = r.renderSync({ ...image, src: png }, { width: 10, height: 10, format: "raw", limits: { maxImageBytes: 16 } });
assert.deepEqual([...bin.subarray(0, 4)], NONE);

// per Renderer: the defaults of every call; a call can only lower them
const strict = new Renderer({ limits: { maxImagePixels: 99 } });
assert.deepEqual(await pixel(strict), NONE);
assert.deepEqual(await pixel(strict, { limits: { maxImagePixels: 1e9 } }), NONE, "a call cannot raise the renderer's limit");
assert.deepEqual(await pixel(strict, { limits: { maxImageBytes: 1e9 } }), NONE, "other limits merge with the renderer's");
const loose = new Renderer({ limits: { maxImagePixels: 1e9 } });
assert.deepEqual(await pixel(loose), RED);
assert.deepEqual(await pixel(loose, { limits: { maxImagePixels: 99 } }), NONE);
// prepared handles keep the limits of their options
const prepared = await r.prepare(image, { ...raw, limits: { maxImagePixels: 50 } });
assert.deepEqual([...(await r.render(prepared)).subarray(0, 4)], NONE);

// canvas and nesting: the call fails with the limit's name
const box = { type: "container", style: { width: 100, height: 100 } };
r.renderSync(box, { limits: { maxCanvasPixels: 10000 } });
assert.throws(() => r.renderSync(box, { limits: { maxCanvasPixels: 9999 } }), { message: "bm-render: canvas exceeds limits.maxCanvasPixels" });
await assert.rejects(r.render(box, { width: 200, height: 100, limits: { maxCanvasPixels: 10000 } }), { message: "bm-render: canvas exceeds limits.maxCanvasPixels" });
const html = "<div style='width:8px;height:8px'><section><p><b>x</b></p></section></div>";
r.renderSync(html, { limits: { maxNodeDepth: 4 } });
assert.throws(() => r.renderSync(html, { limits: { maxNodeDepth: 3 } }), { message: "bm-render: node tree exceeds limits.maxNodeDepth" });
assert.throws(() => new Renderer({ limits: { maxNodeDepth: 3 } }).measureSync(html), { message: "bm-render: node tree exceeds limits.maxNodeDepth" });

// animations: every frame's canvas
const anim = { scenes: [{ node: box, durationMs: 100 }], width: 10, height: 10, fps: 10 };
assert.ok(r.renderAnimationSync(anim).length > 0);
assert.throws(() => r.renderAnimationSync({ ...anim, limits: { maxCanvasPixels: 99 } }), { message: "bm-render: canvas exceeds limits.maxCanvasPixels" });
assert.throws(() => new Renderer({ limits: { maxCanvasPixels: 99 } }).renderAnimationSync(anim), { message: "bm-render: canvas exceeds limits.maxCanvasPixels" });

// invalid limits
assert.throws(() => new Renderer({ limits: { maxPixels: 5 } }), { name: "TypeError", message: "bm-render: unknown limit: limits.maxPixels" });
assert.throws(() => new Renderer({ limits: { maxNodeDepth: 0 } }), { name: "TypeError", message: "bm-render: limit must be a number >= 1: limits.maxNodeDepth" });
assert.throws(() => new Renderer({ limits: 5 }), { name: "TypeError", message: "bm-render: limits must be an object" });
assert.throws(() => r.renderSync(box, { limits: { maxWidth: 5 } }), { message: "bm-render: unknown limit: limits.maxWidth" });
assert.throws(() => r.renderSync(box, { limits: { maxNodeDepth: "5" } }), { message: "bm-render: limit must be a number >= 1: limits.maxNodeDepth" });
assert.throws(() => strict.renderSync(box, { limits: [] }), { message: "bm-render: limits must be an object" });

// PDF: an image source over a limit fails the document (like one that cannot be decoded)
const pdf = new PdfRenderer();
const doc = { type: "image", src: "a", style: { width: 10, height: 10 } };
const pdfOpts = { viewport: { width: 20, height: 20 }, images: [{ src: "a", data: png }] };
assert.ok((await pdf.render(doc, pdfOpts)).length > 0);
await assert.rejects(pdf.render(doc, { ...pdfOpts, limits: { maxImagePixels: 99 } }), /image exceeds limits\.maxImagePixels/);
await assert.rejects(new PdfRenderer({ limits: { maxImageBytes: 8 } }).render(doc, pdfOpts), /image exceeds limits\.maxImageBytes/);
assert.throws(() => pdf.renderSync("<div><p><b>x</b></p></div>", { viewport: { width: 20, height: 20 }, limits: { maxNodeDepth: 2 } }), { message: "bm-render: node tree exceeds limits.maxNodeDepth" });

for (const x of [red, r, strict, loose]) x.free();
pdf.free();
console.log("limits tests passed");
