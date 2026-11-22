// Regression tests for the JS wrapper's abort handling (`npm run test:js`):
//   - a `signal` given to prepare() must not reject later renders of the handle
//   - one caller aborting must not fail other callers sharing a `fetchCache` download
//   - images.timeout + signal must work without AbortSignal.any (Node < 18.17)
import assert from "node:assert/strict";
import { Renderer } from "../js/node.mjs";
import { PdfRenderer } from "../js/node-pdf.mjs";

const r = new Renderer();
const ac = new AbortController();
const prepared = await r.prepare({ type: "container", style: { width: 10, height: 10, backgroundColor: "red" } }, { width: 10, height: 10, signal: ac.signal });
ac.abort();
const png = await r.render(prepared);
assert.ok(png.length > 0, "render of a prepared handle after its prepare signal aborted");

let calls = 0;
const fetch = (url, init) => { calls++; return new Promise((resolve, reject) => {
  const t = setTimeout(() => resolve(new Response(png, { headers: { "content-type": "image/png" } })), 100);
  init?.signal?.addEventListener("abort", () => { clearTimeout(t); reject(init.signal.reason); });
}); };
const pdf = new PdfRenderer();
const html = '<img src="https://example.test/a.png" style="width:10px;height:10px">';

const fetchCache = new Map();
const a = new AbortController();
const pa = pdf.prepare(html, { images: { fetch, fetchCache }, signal: a.signal });
const pb = pdf.prepare(html, { images: { fetch, fetchCache } });
setTimeout(() => a.abort(new Error("A aborted")), 20);
const [ra, rb] = await Promise.allSettled([pa, pb]);
assert.equal(ra.status, "rejected");
assert.equal(ra.reason.message, "A aborted");
assert.equal(rb.status, "fulfilled", "the other caller of a shared download is unaffected");
assert.equal(calls, 1, "the download is shared");

const any = AbortSignal.any;
AbortSignal.any = undefined;
try {
  await pdf.prepare(html, { images: { fetch, timeout: 5000 }, signal: new AbortController().signal });
  await assert.rejects(pdf.prepare(html, { images: { fetch, timeout: 30 }, signal: new AbortController().signal }), { name: "TimeoutError" });
} finally {
  AbortSignal.any = any;
}
console.log("js abort tests: ok");
