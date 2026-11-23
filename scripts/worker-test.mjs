// Tests of `new Renderer({ workers: N })` on the wasm backend (`npm run test:workers`):
//   - byte identity with the in-thread renderer: PNG (text, `images`, binary src), SVG, measure, PDF (PdfRenderer,
//     with attachments), renderAnimation, renderAsDataUrl, prepared handles
//   - fonts reach every worker: registerFont before / after the workers started, `fonts` option entries,
//     unregisterFont, clearFonts, and a font registered after a call was made does not leak into that call
//   - `signal`: a queued job rejects with the reason, a running one rejects at once, the renderer keeps working
//   - engine errors reject with the same message as in-thread
//   - free() rejects pending calls; a process that never calls free() still exits (idle workers are unref'ed)
//   - the event loop's longest 1 ms-timer gap during a heavy 2400x2400 render and a 60-frame animation,
//     in-thread async vs workers
//
//   node scripts/worker-test.mjs [--quick]   (--quick skips the event-loop measurement)
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import * as full from "../js/full.mjs";
import * as pdf from "../js/pdf.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const js = (f) => path.join(root, "js", f);
const font = (f) => readFileSync(path.join(root, "assets", "fonts", f));
full.initSync(readFileSync(js("bm_render.wasm")));
pdf.initSync(readFileSync(js("bm_render.pdf.wasm")));

const INTER = font("Inter-Regular.ttf");
const ROBOTO = font("Roboto-Regular.ttf");
const same = (a, b, what) => {
  if (typeof a === "string" || typeof b === "string") return assert.equal(a, b, what);
  assert.ok(a instanceof Uint8Array && b instanceof Uint8Array, what + ": Uint8Array results");
  assert.ok(Buffer.from(a).equals(Buffer.from(b)), `${what}: bytes differ (${a.length} vs ${b.length})`);
};
let passed = 0;
async function test(name, fn) {
  await fn();
  passed++;
  console.log("ok   " + name);
}

const card = (family, text = "Hello workers") => ({
  type: "container",
  style: { display: "flex", width: "100%", height: "100%", alignItems: "center", justifyContent: "center", backgroundImage: "linear-gradient(135deg,#1e3a8a,#db2777)" },
  children: [
    { type: "text", text, style: { fontFamily: family, fontSize: 48, color: "white" } },
    { type: "image", src: "logo", width: 32, height: 32 },
    { type: "image", src: { width: 2, height: 2, data: new Uint8Array([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]) }, width: 16, height: 16 },
  ],
});

const inThread = new full.Renderer();
const pool = new full.Renderer({ workers: 2 });
const tiny = inThread.renderSync({ type: "container", style: { width: 4, height: 4, backgroundColor: "orange" } }, { width: 4, height: 4 });
const images = [{ src: "logo", data: tiny }];
const opts = { width: 600, height: 315, images };

await test("PNG / JPEG / WebP / raw / data URL / measure identical, fonts registered before the first call", async () => {
  for (const r of [inThread, pool]) r.registerFont({ name: "Inter", data: INTER });
  for (const format of ["png", "jpeg", "webp", "raw"]) same(await pool.render(card("Inter"), { ...opts, format }), inThread.renderSync(card("Inter"), { ...opts, format }), format);
  same(await pool.renderAsDataUrl(card("Inter"), opts), inThread.renderAsDataUrlSync(card("Inter"), opts), "data URL");
  assert.deepEqual(await pool.measure(card("Inter"), opts), inThread.measureSync(card("Inter"), opts));
  // Node Buffer (pool slab) and a subarray view as attachments
  const view = new Uint8Array(tiny.length + 10);
  view.set(tiny, 5);
  const sub = { width: 600, height: 315, images: [{ src: "logo", data: view.subarray(5, 5 + tiny.length) }] };
  same(await pool.render(card("Inter"), sub), inThread.renderSync(card("Inter"), sub), "subarray attachment");
  same(await pool.render(card("Inter"), { width: 600, height: 315, images: [{ src: "logo", data: Buffer.from(tiny) }] }), inThread.renderSync(card("Inter"), opts), "Buffer attachment");
  assert.equal(view[5], tiny[0], "the caller's bytes are left alone (copied, not transferred)");
});

await test("SVG and HTML sources identical", async () => {
  same(await pool.renderSvg(card("Inter"), opts), inThread.renderSvgSync(card("Inter"), opts), "svg");
  const html = '<div style="display:flex;width:100%;height:100%;background:#123;color:#fff;font:40px Inter">HTML <b>source</b></div>';
  same(await pool.render(html, { width: 400, height: 120 }), inThread.renderSync(html, { width: 400, height: 120 }), "html");
});

await test("parallel calls: every result identical, in any order", async () => {
  const texts = Array.from({ length: 8 }, (_, i) => "Job " + i);
  const got = await Promise.all(texts.map((t) => pool.render(card("Inter", t), opts)));
  got.forEach((g, i) => same(g, inThread.renderSync(card("Inter", texts[i]), opts), "parallel " + i));
});

await test("fonts registered after the workers started, `fonts` option, unregisterFont, clearFonts", async () => {
  for (const r of [inThread, pool]) r.registerFont({ name: "Roboto", data: ROBOTO });
  same(await pool.render(card("Roboto"), opts), inThread.renderSync(card("Roboto"), opts), "late registerFont");
  // both workers must have it: run two at once
  const [a, b] = await Promise.all([pool.render(card("Roboto", "A"), opts), pool.render(card("Roboto", "B"), opts)]);
  same(a, inThread.renderSync(card("Roboto", "A"), opts), "worker A");
  same(b, inThread.renderSync(card("Roboto", "B"), opts), "worker B");
  const bold = font("Inter-Bold.ttf");
  const fopts = { ...opts, fonts: [{ name: "InterBold", data: bold }] };
  same(await pool.render(card("InterBold"), fopts), inThread.renderSync(card("InterBold"), fopts), "fonts option");
  for (const r of [inThread, pool]) assert.equal(r.unregisterFont("Roboto"), true);
  same(await pool.render(card("Roboto"), opts), inThread.renderSync(card("Roboto"), opts), "after unregisterFont");
  for (const r of [inThread, pool]) r.clearFonts();
  same(await pool.render(card("Inter"), opts), inThread.renderSync(card("Inter"), opts), "after clearFonts");
  for (const r of [inThread, pool]) r.registerFont({ name: "Inter", data: INTER });
  same(await pool.render(card("Inter"), opts), inThread.renderSync(card("Inter"), opts), "re-registered after clearFonts");
});

await test("a call sees the fonts of the moment it was made (later registrations do not leak into it)", async () => {
  const one = new full.Renderer({ workers: 1 });
  const ref = new full.Renderer();
  one.registerFont({ name: "Inter", data: INTER });
  ref.registerFont({ name: "Inter", data: INTER });
  const expectedBefore = ref.renderSync(card("Late"), opts);
  const busy = one.render(card("Inter"), { width: 1600, height: 1600, images }); // occupies the only worker
  await new Promise((r) => setTimeout(r, 0)); // render() made its job (after awaiting its option extras)
  const before = one.render(card("Late"), opts); // queued, no "Late" font yet
  await new Promise((r) => setTimeout(r, 0));
  one.registerFont({ name: "Late", data: ROBOTO });
  ref.registerFont({ name: "Late", data: ROBOTO });
  const after = one.render(card("Late"), opts);
  await busy;
  assert.ok(!Buffer.from(expectedBefore).equals(Buffer.from(ref.renderSync(card("Late"), opts))), "the late font changes the output");
  same(await before, expectedBefore, "queued call");
  same(await after, ref.renderSync(card("Late"), opts), "later call");
  one.free();
  ref.free();
});

await test("prepare / renderAnimation / prepared animation identical", async () => {
  const p = await pool.prepare(card("Inter"), opts);
  same(await pool.render(p), inThread.renderSync(card("Inter"), opts), "prepared");
  const disc = { type: "container", style: { display: "flex", width: "100%", height: "100%", backgroundColor: "#0f172a", alignItems: "center", justifyContent: "center" },
    children: [{ type: "container", style: { width: 40, height: 40, borderRadius: 20, backgroundColor: "#fff", animation: "spin 1s linear infinite" } }] };
  const anim = { scenes: [{ node: disc, durationMs: 500 }], width: 160, height: 90, fps: 20, css: "@keyframes spin { to { transform: translateX(60px) } }" };
  for (const format of ["webp", "apng", "gif"]) same(await pool.renderAnimation({ ...anim, format }), inThread.renderAnimationSync({ ...anim, format }), "animation " + format);
  const pa = await pool.prepareAnimation(anim);
  same(await pool.renderAnimation(pa), inThread.renderAnimationSync(anim), "prepared animation");
});

await test("PDF (PdfRenderer with workers) identical, with attachments and measure", async () => {
  const a = new pdf.PdfRenderer();
  const b = new pdf.PdfRenderer({ workers: 2 });
  for (const r of [a, b]) r.registerFont({ name: "Inter", data: INTER });
  const doc = '<html><body style="font-family:Inter"><h1>Invoice</h1><p>Rendered off the main thread.</p><img src="logo" style="width:20px;height:20px"></body></html>';
  const o = { images, metadata: { title: "T", creationDate: "2020-01-01" }, attachments: [{ name: "data.json", data: new TextEncoder().encode('{"a":1}') }] };
  same(await b.render(doc, o), a.renderSync(doc, o), "pdf");
  assert.deepEqual(await b.measure(doc), a.measureSync(doc));
  a.free();
  b.free();
});

await test("signal: queued job rejects with the reason, a running one rejects, the renderer keeps working", async () => {
  const r = new full.Renderer({ workers: 1 });
  r.registerFont({ name: "Inter", data: INTER });
  const big = { width: 2000, height: 2000, images };
  const running = new AbortController();
  const queued = new AbortController();
  const pRun = r.render(card("Inter"), { ...big, signal: running.signal });
  const pQueued = r.render(card("Inter"), { ...big, signal: queued.signal });
  const pAfter = r.render(card("Inter"), opts);
  await new Promise((res) => setTimeout(res, 5));
  queued.abort(new Error("queued aborted"));
  running.abort(new Error("running aborted"));
  await assert.rejects(pQueued, { message: "queued aborted" });
  await assert.rejects(pRun, { message: "running aborted" });
  same(await pAfter, inThread.renderSync(card("Inter"), opts), "after aborts");
  const pre = new AbortController();
  pre.abort();
  await assert.rejects(r.render(card("Inter"), { ...opts, signal: pre.signal }), { name: "AbortError" });
  r.free();
});

await test("engine errors reject with the in-thread message", async () => {
  const bad = [
    [{ type: "image", src: "missing" }, { width: 10, height: 10, images: [{ src: "missing", data: new Uint8Array([1, 2, 3, 4, 5]) }] }],
    [{ json: "{ not json" }, { width: 10, height: 10 }],
    [{ type: "container" }, { width: 10, height: 10, format: "bogus" }],
  ];
  let compared = 0;
  for (const [node, o] of bad) {
    const want = await inThread.render(node, o).then(() => null, (e) => e);
    const got = await pool.render(node, o).then(() => null, (e) => e);
    if (want === null) { assert.equal(got, null); continue; }
    assert.ok(got instanceof Error, "rejects with an Error");
    assert.equal(got.constructor, want.constructor);
    assert.equal(got.message, want.message);
    compared++;
  }
  assert.ok(compared > 0, "at least one input fails in the engine");
  // pdf build missing on full: thrown on the main thread, same as in-thread
  await assert.rejects(pool.renderPdf("<p>x</p>"), { message: /renderPdf is not supported by this build/ });
});

await test("free() rejects pending calls; later calls throw; sync API unaffected before free", async () => {
  const r = new full.Renderer({ workers: 1 });
  const ref = new full.Renderer();
  same(r.renderSync(card("x"), opts), ref.renderSync(card("x"), opts), "renderSync with workers");
  ref.free();
  const p1 = r.render(card("x"), { width: 1600, height: 1600, images });
  const p2 = r.render(card("x"), opts);
  await new Promise((res) => setTimeout(res, 5));
  r.free();
  await assert.rejects(p1, { message: "bm-render: renderer has been freed" });
  await assert.rejects(p2, { message: "bm-render: renderer has been freed" });
  await assert.rejects(r.render(card("x"), opts), { message: "bm-render: renderer has been freed" });
});

await test("processes exit: without free(), after free() mid-render, workers option validated", async () => {
  const entry = pathToFileURL(js("full.mjs")).href;
  const wasm = js("bm_render.wasm");
  const child = (code) => spawnSync(process.execPath, ["--input-type=module", "-e",
    `import { readFileSync } from "node:fs"; import * as m from ${JSON.stringify(entry)}; m.initSync(readFileSync(${JSON.stringify(wasm)}));\n${code}`],
  { encoding: "utf8", timeout: 20000 });
  const node = `{ type: "container", style: { width: 50, height: 50, backgroundColor: "red" } }`;
  let c = child(`const r = new m.Renderer({ workers: 3 }); await Promise.all([1,2,3].map(() => r.render(${node}, { width: 50, height: 50 }))); console.log("done");`);
  assert.equal(c.status, 0, "no free(): " + c.stderr);
  assert.match(c.stdout, /done/);
  c = child(`const r = new m.Renderer({ workers: 2 }); const p = r.render(${node}, { width: 3000, height: 3000 }).catch((e) => console.log(e.message)); setTimeout(() => r.free(), 5); await p;`);
  assert.equal(c.status, 0, "free() mid-render: " + c.stderr);
  assert.match(c.stdout, /renderer has been freed/);
  c = child(`const r = new m.Renderer({ workers: 1 }); await r.render(${node}, { width: 50, height: 50 }); r.render(${node}, { width: 2000, height: 2000 }).catch(() => {}); r[Symbol.dispose ?? Symbol.for("nodejs.dispose")](); console.log("ok");`);
  assert.equal(c.status, 0, "Symbol.dispose: " + c.stderr);
  assert.throws(() => new full.Renderer({ workers: -1 }), TypeError);
  assert.throws(() => new full.Renderer({ workers: 1.5 }), TypeError);
  new full.Renderer({ workers: 0 }).free();
});

// ------------------------------------------------------------------ event loop
if (!process.argv.includes("--quick")) {
  const heavy = {
    type: "container",
    style: { display: "flex", flexWrap: "wrap", gap: 60, padding: 80, width: "100%", height: "100%", backgroundImage: "linear-gradient(135deg,#1e3a8a,#db2777)", fontFamily: "Inter" },
    children: Array.from({ length: 24 }, (_, i) => ({
      type: "container",
      style: { display: "flex", alignItems: "center", justifyContent: "center", width: 480, height: 300, borderRadius: 40, backgroundColor: "rgba(255,255,255,0.9)", boxShadow: "0 30px 90px rgba(0,0,0,.55), 0 0 40px rgba(124,58,237,.6)", filter: i % 3 === 0 ? "blur(6px)" : "none" },
      children: [{ type: "text", text: `Card ${i + 1}`, style: { fontSize: 64, color: "#0f172a" } }],
    })),
  };
  const disc = { type: "container", style: { display: "flex", width: "100%", height: "100%", backgroundImage: "linear-gradient(135deg,#1e3a8a,#db2777)", alignItems: "center", justifyContent: "center" },
    children: Array.from({ length: 12 }, (_, i) => ({ type: "container", style: { width: 60, height: 60, margin: 6, borderRadius: 30, backgroundColor: "#fff", boxShadow: "0 8px 30px rgba(0,0,0,.5)", filter: "blur(2px)", transform: `rotate(${i * 10}deg)` } })) };
  const jobs = {
    heavy: (r) => r.render(heavy, { width: 2400, height: 2400, format: "png" }),
    anim: (r) => r.renderAnimation({ scenes: [{ node: disc, durationMs: 2000 }], width: 800, height: 420, fps: 30, format: "webp" }),
  };
  async function maxDelay(r, job) {
    await r.render({ type: "text", text: "warm", style: { fontFamily: "Inter", fontSize: 20 } }, { width: 100, height: 40 });
    let last = performance.now();
    let max = 0;
    const timer = setInterval(() => { const now = performance.now(); max = Math.max(max, now - last); last = now; }, 1);
    const t0 = performance.now();
    const out = await jobs[job](r);
    const ms = performance.now() - t0;
    await new Promise((res) => setTimeout(res, 5));
    clearInterval(timer);
    return { ms, max, out };
  }
  const rows = [];
  for (const job of ["heavy", "anim"]) {
    const a = new full.Renderer();
    const w = new full.Renderer({ workers: 1 });
    for (const r of [a, w]) r.registerFont({ name: "Inter", data: INTER });
    const inT = await maxDelay(a, job);
    const off = await maxDelay(w, job);
    same(off.out, inT.out, job + " bytes");
    rows.push({ job, inThreadMaxDelayMs: +inT.max.toFixed(1), workersMaxDelayMs: +off.max.toFixed(1), inThreadMs: +inT.ms.toFixed(0), workersMs: +off.ms.toFixed(0) });
    a.free();
    w.free();
    assert.ok(off.max < 50, `${job}: event loop blocked ${off.max.toFixed(1)} ms with workers`);
  }
  console.table(rows);
  passed++;
  console.log("ok   event loop stays responsive with workers");
}

inThread.free();
pool.free();
console.log(`worker tests: ${passed} passed`);
