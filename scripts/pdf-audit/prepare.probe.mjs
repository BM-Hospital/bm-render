// Resource preparation against the pinned reference (todo task 26): which `fonts` subsets a render or `prepare`
// loads (takumi-bindings-js prepared.ts `collect` and takumi-core needs.rs: the families font fallback reaches),
// the `@font-face` files `prepare` fetches (in the document and in bands, a failed file moving its rule on to the
// next `src`, each file once), what a prepared document fetches again (nothing), and the fetch policy (retries,
// timeouts, `allowUrl` on redirects, `fetchCache`, `signal`). Fetches are mocked; each probe compares the calls
// both engines make. Upstream: takumi-pdf-js tests/prepare.test.ts, takumi-bindings-js tests/renderer-facade.test.ts.
import { bmMod, font, NOTO_TC, probe, refMod } from "./lib.mjs";

const inter = font("assets/fonts/Inter-Regular.ttf");
const noto = font(NOTO_TC);
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAE0lEQVR4nGP4z8AAQv8ZQASIBQBDzgf5kLRQ3gAAAABJRU5ErkJggg==", "base64");
const isPdf = (bytes) => Buffer.from(bytes.subarray(0, 5)).toString("latin1") === "%PDF-";

/** Runs `scenario(mod, log)` on both engines and compares the logs (`sorted`: as sets). */
function calls(id, feature, scenario, { sorted = false, check } = {}) {
  probe(`prepare.${id}`, feature, async (t) => {
    const run = async (mod) => {
      const log = [];
      try { await scenario(mod, log); } catch (e) { log.push("threw: " + String(e?.message ?? e).replace(/^bm-render: /, "")); }
      return sorted ? log.sort() : log;
    };
    const bm = await run(bmMod);
    t.note("bm: " + JSON.stringify(bm));
    if (check) check(t, bm);
    else t.ok(!bm.some((x) => String(x).startsWith("threw")), `bm: ${JSON.stringify(bm)}`);
    if (!refMod) { t.same("reference", 0, 0); return; }
    t.same("calls", bm, await run(refMod));
  });
}

const listed = (log, name, range, data = inter, extra = {}) => ({ name, unicodeRange: [range], ...extra, data: () => { log.push(name); return data; } });
const LATIN = [0, 0x24f];
const CYRILLIC = [0x400, 0x4ff];

// ---- fonts: the subsets font fallback reaches ------------------------------------------------------------------

calls("subsets.bands", "prepare: the font subsets the document's and its bands' text use (prepare.test.ts)", async (mod, log) => {
  const r = new mod.PdfRenderer();
  const p = await r.prepare("<p>a</p>", { footer: "<p>Ж</p>", pages: { first: { header: "<p>α</p>" } }, fonts: [listed(log, "Cyrillic", CYRILLIC), listed(log, "Greek", [0x370, 0x3ff]), listed(log, "Armenian", [0x530, 0x58f])] });
  log.push(isPdf(await r.render(p)) ? "pdf" : "no pdf");
});
calls("subsets.first-family", "fonts: only the first family whose unicodeRange claims a character loads", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<p>a</p>", { fonts: [listed(log, "A", LATIN), listed(log, "B", LATIN)] });
});
calls("subsets.element-family", "fonts: the element's font-family before the fallback stack", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<p style='font-family:B'>a</p>", { fonts: [listed(log, "A", LATIN), listed(log, "B", LATIN)] });
});
calls("subsets.per-script", "fonts: a family per script, an unreached family not loaded", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<p style='font-family:B'>Ж</p><p style='font-family:A'>a</p>", { fonts: [listed(log, "A", [0, 0x7f]), listed(log, "B", CYRILLIC), listed(log, "C", CYRILLIC)] });
});
calls("subsets.weight", "fonts: the face of a family the text's weight matches", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<p style='font-family:A'>a</p>", { fonts: [listed(log, "A400", LATIN, inter, { name: "A", weight: 400 }), listed(log, "A700", LATIN, inter, { name: "A", weight: 700 })].map((f, i) => ({ ...f, data: () => { log.push(i ? "A700" : "A400"); return inter; } })) });
});
calls("subsets.weight-bold", "fonts: bold text loads the bold face", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<p style='font-family:A'>a <b>b</b></p>", { fonts: [listed(log, "A", LATIN, inter, { weight: 400 }), listed(log, "A", LATIN, inter, { weight: 700 })].map((f, i) => ({ ...f, data: () => { log.push(i ? "A700" : "A400"); return inter; } })) });
});
calls("subsets.fontFamilies", "fonts: an explicit fontFamilies stack decides the fallback order", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<p>a</p>", { fontFamilies: ["B", "A"], fonts: [listed(log, "A", LATIN), listed(log, "B", LATIN)] });
});
calls("subsets.no-glyph", "fonts: a subset without a glyph its unicodeRange claims moves the character to the next family", async (mod, log) => {
  const r = new mod.PdfRenderer();
  const p = await r.prepare("<p>一</p>", { fonts: [listed(log, "Sans", [0x4e00, 0x9fff], inter), listed(log, "Serif", [0x4e00, 0x9fff], noto)] });
  log.push(isPdf(await r.render(p)) ? "pdf" : "no pdf");
});
calls("subsets.no-range", "fonts: entries without a unicodeRange load as they are", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<p>a</p>", { fonts: [{ name: "A", data: () => { log.push("A"); return inter; } }, { name: "B", data: () => { log.push("B"); return inter; } }] });
});
calls("subsets.render", "fonts: a render without prepare loads the subsets it reaches too", async (mod, log) => {
  await new mod.PdfRenderer().render("<p>a</p>", { fonts: [listed(log, "A", [0, 0x7f]), listed(log, "B", CYRILLIC)] });
});
calls("subsets.unused-range", "fonts: a subset no character falls in is not loaded (renderer-facade.test.ts)", async (mod, log) => {
  await new mod.PdfRenderer().render("<p>0</p>", { fonts: [listed(log, "Fam", [0x4e00, 0x4e00]), { name: "Inter", data: () => { log.push("Inter"); return inter; } }] });
});
calls("subsets.once", "fonts: a prepared document's render and measure load nothing again", async (mod, log) => {
  const r = new mod.PdfRenderer();
  const fonts = [listed(log, "A", LATIN)];
  const p = await r.prepare("<p>a</p>", { fonts });
  log.push("prepared");
  await r.render(p); await r.measure(p);
  await r.render("<p>b</p>", { fonts });
  log.push("done");
});
calls("subsets.svg-text", "fonts: the text of a fetched SVG image reaches its subset", async (mod, log) => {
  await new mod.PdfRenderer().prepare('<img src="https://example.test/text.svg">', {
    images: { fetch: async () => new Response('<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30"><text y="20">α</text></svg>') },
    fonts: [listed(log, "Latin", LATIN), listed(log, "Greek", [0x370, 0x3ff]), listed(log, "Armenian", [0x530, 0x58f])],
  });
});

// ---- @font-face files ------------------------------------------------------------------------------------------

const fetchLog = (log, answer = () => new Response(inter)) => async (url) => { log.push(String(url)); return answer(String(url)); };
const hasFontFile = (bytes) => /FontFile2|FontFile3/.test(Buffer.from(bytes).toString("latin1"));

calls("font-face.next-src", "@font-face: a file that fails moves its rule on to the next src (renderer-facade.test.ts)", async (mod, log) => {
  const r = new mod.PdfRenderer();
  const p = await r.prepare("<style>@font-face{font-family:Remote;src:url(https://fonts.test/missing.woff2),url(https://fonts.test/face.ttf)}p{font-family:Remote}</style><p>Hi</p>", { images: { fetch: fetchLog(log, (u) => (u.includes("missing") ? new Response(null, { status: 404 }) : new Response(inter))) } });
  log.push(hasFontFile(await r.render(p)) ? "embedded" : "not embedded");
});
calls("font-face.once", "@font-face: a file two rules name is fetched once", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<style>@font-face{font-family:R;font-weight:400;src:url(https://fonts.test/a.ttf)}@font-face{font-family:R;font-weight:700;src:url(https://fonts.test/a.ttf)}p{font-family:R}b{font-weight:700}</style><p>Hi <b>bold</b></p>", { images: { fetch: fetchLog(log) } });
});
calls("font-face.unicode-range", "@font-face: only the unicode-range files the text falls in", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<style>@font-face{font-family:R;src:url(https://fonts.test/latin.ttf);unicode-range:U+0000-00FF}@font-face{font-family:R;src:url(https://fonts.test/cyr.ttf);unicode-range:U+0400-04FF}@font-face{font-family:R;src:url(https://fonts.test/greek.ttf);unicode-range:U+0370-03FF}p{font-family:R}</style><p>Hi Ж</p>", { images: { fetch: fetchLog(log) } });
}, { sorted: true });
calls("font-face.band", "@font-face: a band's rule and text", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<p>body</p>", { size: "A5", header: "<style>@font-face{font-family:H;src:url(https://fonts.test/h.ttf)}</style><p style='font-family:H'>head</p>", images: { fetch: fetchLog(log) } });
});
calls("font-face.unused", "@font-face: a rule no element uses is not fetched", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<style>@font-face{font-family:U;src:url(https://fonts.test/u.ttf)}</style><p>x</p>", { images: { fetch: fetchLog(log) } });
});
calls("font-face.render", "@font-face: a render without prepare fetches no file (renderer-facade.test.ts)", async (mod, log) => {
  const original = globalThis.fetch;
  globalThis.fetch = async (u) => { log.push(String(u)); return new Response(inter); };
  try { await new mod.PdfRenderer().render("<style>@font-face{font-family:R;src:url(https://fonts.test/r.ttf)}p{font-family:R}</style><p>x</p>", { fonts: [{ name: "Inter", data: inter }] }); } finally { globalThis.fetch = original; }
});
calls("font-face.prepared", "prepare: a prepared document's render and measure fetch nothing again", async (mod, log) => {
  const r = new mod.PdfRenderer();
  const p = await r.prepare("<style>@font-face{font-family:R;src:url(https://fonts.test/r.ttf)}p{font-family:R}</style><p>x</p><img src='https://x.test/a.png' width=4 height=4>", { images: { fetch: fetchLog(log, (u) => new Response(u.endsWith(".png") ? png : inter)) } });
  log.push("prepared");
  await r.render(p); await r.measure(p); await r.render(p);
  log.push("done");
});
calls("font-face.all-fail", "@font-face: every src failing leaves the rule out, the render goes on (a 500 is retried)", async (mod, log) => {
  const r = new mod.PdfRenderer();
  const p = await r.prepare("<style>@font-face{font-family:R;src:url(https://fonts.test/r.ttf)}p{font-family:R,Inter}</style><p>x</p>", { images: { fetch: fetchLog(log, () => new Response(null, { status: 500 })) }, fonts: [{ name: "Inter", data: inter }] });
  log.push(isPdf(await r.render(p)) ? "pdf" : "no pdf");
});

// ---- fetch policy ----------------------------------------------------------------------------------------------

calls("fetch.retry", "fetch: a retryable status is retried, a 404 is not", async (mod, log) => {
  let n = 0;
  const r = new mod.PdfRenderer();
  await r.prepare("<img src='https://x.test/retry.png' width=4 height=4>", { images: { fetch: fetchLog(log, () => (++n < 3 ? new Response(null, { status: 503 }) : new Response(png))) } });
  log.push("retried");
  try { await r.prepare("<img src='https://x.test/404.png' width=4 height=4>", { images: { fetch: fetchLog(log, () => new Response(null, { status: 404 })) } }); } catch { log.push("404 rejects"); }
});
calls("fetch.network-error", "fetch: a network error (TypeError) is retried", async (mod, log) => {
  let n = 0;
  await new mod.PdfRenderer().prepare("<img src='https://x.test/n.png' width=4 height=4>", { images: { fetch: async (u) => { log.push(String(u)); if (++n < 2) throw new TypeError("network"); return new Response(png); } } });
});
calls("fetch.retry-after", "fetch: a Retry-After beyond a second ends the retries", async (mod, log) => {
  try { await new mod.PdfRenderer().prepare("<img src='https://x.test/r.png' width=4 height=4>", { images: { fetch: fetchLog(log, () => new Response(null, { status: 429, headers: { "retry-after": "5" } })) } }); } catch { log.push("rejects"); }
});
calls("fetch.redirect-allowUrl", "fetch: with allowUrl every redirect hop is checked", async (mod, log) => {
  const allowUrl = (u) => { log.push("allow? " + u); return !u.includes("evil"); };
  const fetch = fetchLog(log, (u) => (u.endsWith("/start.png") ? new Response(null, { status: 302, headers: { location: "https://evil.test/x.png" } }) : new Response(png)));
  try { await new mod.PdfRenderer().prepare("<img src='https://x.test/start.png' width=4 height=4>", { images: { fetch, allowUrl } }); log.push("resolved"); } catch (e) { log.push("rejects: " + /allowUrl/.test(e.message)); }
});
calls("fetch.cache", "fetch: a fetchCache shares one download between prepares", async (mod, log) => {
  const fetchCache = new Map();
  const r = new mod.PdfRenderer();
  const options = { images: { fetchCache, fetch: fetchLog(log, () => new Response(png)) } };
  await Promise.all([r.prepare("<img src='https://x.test/c.png'>", options), r.prepare("<img src='https://x.test/c.png'>", options)]);
  await r.prepare("<img src='https://x.test/c.png'>", options);
});
calls("fetch.throwOnError", "fetch: throwOnError false leaves a failed image out", async (mod, log) => {
  const r = new mod.PdfRenderer();
  const p = await r.prepare("<img src='https://x.test/a.png' width=4 height=4><p>x</p>", { images: { throwOnError: false, fetch: fetchLog(log, () => new Response(null, { status: 404 })) }, fonts: [{ name: "Inter", data: inter }] });
  log.push(isPdf(await r.render(p)) ? "pdf" : "no pdf");
});
calls("fetch.sources", "fetch: images given as sources are not fetched", async (mod, log) => {
  await new mod.PdfRenderer().prepare("<img src='https://x.test/given.png'><img src='https://x.test/fetched.png'>", { images: { sources: [{ src: "https://x.test/given.png", data: png }], fetch: fetchLog(log, () => new Response(png)) } });
});

// ---- signal ----------------------------------------------------------------------------------------------------

calls("signal.pre-aborted", "signal: an aborted prepare rejects before any load (prepare.test.ts)", async (mod, log) => {
  try { await new mod.PdfRenderer().prepare("<p>a</p>", { signal: AbortSignal.abort(), fonts: [listed(log, "A", LATIN)] }); log.push("resolved"); } catch { log.push("rejects"); }
});
calls("signal.render-images", "signal: an aborted render reads no image loader (prepare.test.ts)", async (mod, log) => {
  try { await new mod.PdfRenderer().render("<p>hi</p>", { signal: AbortSignal.abort(), images: [{ src: "https://example.com/a.jpeg", data: () => { log.push("data"); return png; } }] }); log.push("resolved"); } catch { log.push("rejects"); }
});
calls("signal.font-loader", "signal: aborted while a font subset loads, prepare rejects after it", async (mod, log) => {
  const c = new AbortController();
  try { await new mod.PdfRenderer().prepare("<p>a</p>", { signal: c.signal, fonts: [{ name: "A", unicodeRange: [LATIN], data: () => { log.push("A"); c.abort(); return inter; } }] }); log.push("resolved"); } catch { log.push("rejects"); }
});

// A custom fetch that never settles, with the signal aborted: bm-render's prepare rejects on the signal; takumi
// waits for the fetch (its deadline only reaches the `init.signal` the custom fetch ignores) and never settles.
probe("prepare.signal.hung-fetch", "signal: an aborted prepare does not wait for a custom fetch that ignores it", async (t) => {
  for (const html of ["<img src='https://x.test/a.png' width=4 height=4>", "<style>@font-face{font-family:R;src:url(https://fonts.test/r.ttf)}p{font-family:R}</style><p>x</p>"]) {
    const c = new AbortController();
    const fetch = () => { c.abort(new Error("stop")); return new Promise(() => {}); };
    const outcome = await Promise.race([new bmMod.PdfRenderer().prepare(html, { images: { fetch }, signal: c.signal }).then(() => "resolved", (e) => "rejects: " + e.message), new Promise((r) => setTimeout(() => r("pending"), 2000))]);
    t.ok(outcome === "rejects: stop", `bm: ${outcome}`);
  }
  t.differs("takumi never settles: a custom fetch that ignores init.signal holds its prepare");
});

// The message of a failed fetch: bm-render's own wording.
probe("prepare.fetch.error-message", "fetch: the error of a failed image fetch", async (t) => {
  const run = async (mod) => { try { await new mod.PdfRenderer().prepare("<img src='https://x.test/a.png' width=4 height=4>", { images: { fetch: async () => new Response(null, { status: 404 }) } }); return "resolved"; } catch (e) { return e.message; } };
  const bm = await run(bmMod);
  t.ok(bm === "bm-render: fetching https://x.test/a.png failed (404)", `bm: ${bm}`);
  if (refMod) t.differs(`message wording (takumi: ${JSON.stringify(await run(refMod))})`);
});
