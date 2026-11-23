// Helpers shared by pagination.probe.mjs, bands.probe.mjs and counters.probe.mjs (not a probe file: run.mjs only
// loads *.probe.mjs). Everything here is built on lib.mjs.
import { pdftotext, sameDocument, squash } from "./lib.mjs";

/** A 300 x 200 px page with 10 px margins: a 280 x 180 page area = nine 20 px lines. */
export const SMALL = { size: { width: 300, height: 200 }, margin: 10 };
export const pad = (n) => String(n).padStart(2, "0");
/** Numbered 20 px lines `L<from>`..`L<to>` (class `l`); `attrs(i)` adds attributes to line i. */
export const lines = (from, to, attrs = () => "", prefix = "L") => {
  let s = "";
  for (let i = from; i <= to; i++) s += `<div class="l" ${attrs(i) || ""}>${prefix}${pad(i)}</div>`;
  return s;
};
/** The document shell every probe uses: no UA margins, 12px/20px Inter lines. */
export const doc = (body, css = "") =>
  `<style>html,body{margin:0;padding:0} body{font:12px/20px Inter} .l{height:20px} p{margin:0} ${css}</style>${body}`;

/** Word boxes per page through `pdftotext -bbox`: [[word, x, y, x2, y2], ...] in pt, rounded to 0.1. */
export function wordBoxes(bytes) {
  const r = pdftotext(bytes, "bbox" + Math.random().toString(36).slice(2, 8), ["-bbox"]);
  if (r.skipped || !r.ok) throw new Error(`Cannot verify PDF word positions: ${r.skipped ? "pdftotext is missing" : r.stderr}`);
  return parseWordBoxes(r.text);
}

/** Reject missing/malformed extraction instead of treating two empty results as equal. */
export function parseWordBoxes(text) {
  const pages = [];
  for (const pg of text.split("<page ").slice(1)) {
    const words = [];
    const re = /<word xMin="([\d.-]+)" yMin="([\d.-]+)" xMax="([\d.-]+)" yMax="([\d.-]+)">([^<]*)<\/word>/g;
    let m;
    while ((m = re.exec(pg))) words.push([m[5], +(+m[1]).toFixed(1), +(+m[2]).toFixed(1), +(+m[3]).toFixed(1), +(+m[4]).toFixed(1)]);
    pages.push(words);
  }
  if (!pages.length) throw new Error("Cannot verify PDF word positions: extraction contains no page elements");
  return pages;
}

/** Same words at the same place (within `tol` pt) on every page. */
export function sameGeometry(t, r, tol = 0.75) {
  const { bm, ref } = r;
  if (!ref) return t.same("geometry", 0, 0);
  if (bm.error || ref.error) return t.same("error (geometry)", bm.error || null, ref.error || null);
  const a = wordBoxes(bm.bytes); const b = wordBoxes(ref.bytes);
  const diffs = [];
  if (a.length !== b.length) diffs.push(`pages ${a.length} vs ${b.length}`);
  for (let p = 0; p < Math.min(a.length, b.length); p++) {
    if (a[p].length !== b[p].length) { diffs.push(`page ${p + 1}: ${a[p].length} words vs ${b[p].length}`); continue; }
    for (let i = 0; i < a[p].length; i++) {
      const x = a[p][i]; const y = b[p][i];
      if (x[0] !== y[0] || Math.abs(x[1] - y[1]) > tol || Math.abs(x[2] - y[2]) > tol) { diffs.push(`page ${p + 1} word ${i}: bm ${JSON.stringify(x)} vs takumi ${JSON.stringify(y)}`); break; }
    }
  }
  return t.ok(diffs.length === 0, "word positions: " + diffs.slice(0, 3).join("; "));
}

/** Renders with both, compares pages / boxes / text (and word positions with `geom`), returns the pair. */
export async function check(t, html, options = {}, { geom = false, extra, text = true } = {}) {
  const r = await t.both(html, options, extra);
  sameDocument(t, r, { text });
  if (geom) sameGeometry(t, r);
  return r;
}

/** Text per page, squashed, of one render result (`[]` on error). */
export const pagesOf = (x) => (x && !x.error ? x.textPages.map(squash) : []);
/** Notes what each engine printed (kept in results.json as evidence). */
export function noteBoth(t, r, label = "") {
  const one = (x) => (!x ? "n/a" : x.error ? "ERROR " + x.error : JSON.stringify(pagesOf(x)).slice(0, 400));
  t.note(`${label} bm: ${one(r.bm)}`);
  t.note(`${label} takumi: ${one(r.ref)}`);
}
/** Drop bm-render's binding prefix and Takumi's wasm-bindgen `Error: ` wrapper before comparing messages. */
export const stripPrefix = (m) => (m == null ? m : String(m).replace(/^bm-render: /, "").replace(/^Error: /, ""));
/** One line describing a render result: the error, or page count, page sizes (pt) and the text of each page. */
export const summary = (x) => (!x ? "n/a" : x.error ? "ERROR " + stripPrefix(x.error)
  : `${x.pages.length}p ${[...new Set(x.pages.map((p) => p.media.slice(2).join("x")))].join(",")} ${JSON.stringify(pagesOf(x))}`);

/**
 * The labelled comparison every probe uses: both engines must give the same outcome on the same input, i.e. the
 * the same error message for unclassified failures; when `expect: error` is supplied, both engines must reject but
 * error wording may differ; for successful renders, the same page count, page boxes and text per page (and, with
 * `geom`, the same word positions; with `paint`, the same content-stream operators on every page). A failure
 * message carries the label and both summaries.
 * `expect`: "error" (both must fail), "render" (both must render), or undefined (either).
 */
export async function cmp(t, label, html, options = {}, { geom = false, paint = false, extra, expect } = {}) {
  const r = await t.both(html, options, extra);
  const a = summary(r.bm);
  if (!r.ref) { t.note(`${label}: bm ${a.slice(0, 200)}`); t.same(label, 0, 0); return r; }
  const b = summary(r.ref);
  const bothReject = expect === "error" && a.startsWith("ERROR ") && b.startsWith("ERROR ");
  if (r.bm.error || r.ref.error) t.ok(bothReject || a === b, `${label}: outcome: bm ${a.slice(0, 700)} | takumi ${b.slice(0, 700)}`);
  else {
    // page count, page boxes and text are separate assertions (and kinds of the strict gate)
    const boxes = (x) => [...new Set(x.pages.map((p) => p.media.slice(2).join("x")))].join(",");
    t.ok(r.bm.pages.length === r.ref.pages.length, `${label}: page count: bm ${r.bm.pages.length} | takumi ${r.ref.pages.length} (${a.slice(0, 500)} | ${b.slice(0, 500)})`);
    t.ok(boxes(r.bm) === boxes(r.ref), `${label}: page boxes: bm ${boxes(r.bm)} | takumi ${boxes(r.ref)}`);
    const ta = JSON.stringify(pagesOf(r.bm)); const tb = JSON.stringify(pagesOf(r.ref));
    t.ok(ta === tb, `${label}: text per page: bm ${ta.slice(0, 600)} | takumi ${tb.slice(0, 600)}`);
  }
  if (bothReject && a !== b) t.note(`${label}: both reject; error wording differs (bm ${a.slice(0, 180)} | takumi ${b.slice(0, 180)})`);
  if (expect === "error") t.ok(!!r.ref.error, `${label}: expected an error from takumi, got ${b.slice(0, 120)}`);
  if (expect === "render") t.ok(!r.ref.error, `${label}: expected takumi to render, got ${b.slice(0, 200)}`);
  if (geom && a === b && !r.bm.error) {
    const g = geometryDiff(r);
    t.ok(!g, `${label}: word positions differ: ${g}`);
  }
  if (paint && a === b && !r.bm.error) {
    const g = paintDiff(r);
    t.ok(!g, `${label}: painted shapes differ: ${g}`);
  }
  return r;
}
/** A page's content stream as tokens: numbers rounded to 0.1, resource names replaced by `/N`, text strings by `<>`. */
export const paintTokens = (x, i) => x.content(i).replace(/<[0-9a-fA-F\s]*>/g, "<>").replace(/\/[^\s/<>[\]()]+/g, "/N").split(/\s+/).filter(Boolean)
  .map((tok) => (/^[+-]?(\d+\.?\d*|\.\d+)$/.test(tok) ? String(Math.round(+tok * 10) / 10 + 0) : tok));
/**
 * The filled / stroked shapes a page paints, in page coordinates and whatever their order: a small content-stream
 * interpreter (q / Q / cm, fill colour, path construction, paint operators; text is skipped, form XObjects are
 * only counted) returns one entry per painted path, "x0 y0 x1 y1 colour" = its bounding box in pt clipped to the
 * current clip (the bounding box of every `W n` path, starting from the MediaBox) and rounded to 0.5 pt. Shapes
 * that fall outside the clip are dropped, so an engine that paints a whole box and lets the page clip cut it
 * compares equal to one that paints only the visible slice.
 */
export function paintShapes(x, i) {
  const media = x.pages[i].media;
  const toks = x.content(i).replace(/\((?:\\.|[^\\)])*\)/g, "()").replace(/<[0-9a-fA-F\s]*>/g, "()").split(/\s+|(?=[\[\]\/])|(?<=[\[\]])/).filter(Boolean);
  let ctm = [1, 0, 0, 1, 0, 0]; let fill = "0"; let stroke = "0"; let clip = media.slice(); let clipNext = false;
  const stack = []; let args = []; let box = null; let inText = false; let forms = 0;
  const out = [];
  const pt = (px, py) => { const X = ctm[0] * px + ctm[2] * py + ctm[4]; const Y = ctm[1] * px + ctm[3] * py + ctm[5]; box = box ? [Math.min(box[0], X), Math.min(box[1], Y), Math.max(box[2], X), Math.max(box[3], Y)] : [X, Y, X, Y]; };
  const r = (v) => Math.round(v * 2) / 2;
  const emit = (kind, colour) => {
    if (!box) return;
    const c = [Math.max(box[0], clip[0]), Math.max(box[1], clip[1]), Math.min(box[2], clip[2]), Math.min(box[3], clip[3])];
    if (c[2] - c[0] > 0.05 && c[3] - c[1] > 0.05) out.push(`${r(c[0])} ${r(c[1])} ${r(c[2])} ${r(c[3])} ${kind}${colour}`);
    box = null;
  };
  for (const tok of toks) {
    if (/^[+-]?(\d+\.?\d*|\.\d+)$/.test(tok)) { args.push(+tok); continue; }
    if (tok === "BT") inText = true;
    else if (tok === "ET") inText = false;
    else if (inText) { /* text state and showing operators */ }
    else if (tok === "q") stack.push([ctm, fill, stroke, clip]);
    else if (tok === "Q") { const top = stack.pop(); if (top) [ctm, fill, stroke, clip] = top; }
    else if (tok === "cm" && args.length >= 6) { const m = args.slice(-6); ctm = [m[0] * ctm[0] + m[1] * ctm[2], m[0] * ctm[1] + m[1] * ctm[3], m[2] * ctm[0] + m[3] * ctm[2], m[2] * ctm[1] + m[3] * ctm[3], m[4] * ctm[0] + m[5] * ctm[2] + ctm[4], m[4] * ctm[1] + m[5] * ctm[3] + ctm[5]]; }
    else if (tok === "rg" || tok === "g" || tok === "k") fill = args.map((v) => Math.round(v * 20) / 20).join(",");
    else if (tok === "RG" || tok === "G" || tok === "K") stroke = args.map((v) => Math.round(v * 20) / 20).join(",");
    else if (tok === "re" && args.length >= 4) { const [rx, ry, rw, rh] = args.slice(-4); pt(rx, ry); pt(rx + rw, ry); pt(rx, ry + rh); pt(rx + rw, ry + rh); }
    else if ((tok === "m" || tok === "l") && args.length >= 2) pt(...args.slice(-2));
    else if (tok === "c" && args.length >= 6) { pt(args[args.length - 6], args[args.length - 5]); pt(args[args.length - 4], args[args.length - 3]); pt(args[args.length - 2], args[args.length - 1]); }
    else if ((tok === "v" || tok === "y") && args.length >= 4) { pt(args[args.length - 4], args[args.length - 3]); pt(args[args.length - 2], args[args.length - 1]); }
    else if (clipNext && box && ["n", "f", "F", "f*", "B", "B*", "b", "b*", "S", "s"].includes(tok)) { clip = [Math.max(box[0], clip[0]), Math.max(box[1], clip[1]), Math.min(box[2], clip[2]), Math.min(box[3], clip[3])]; clipNext = false; box = null; }
    else if (["f", "F", "f*", "B", "B*", "b", "b*"].includes(tok)) emit("fill ", fill);
    else if (tok === "S" || tok === "s") emit("stroke ", stroke);
    else if (tok === "W" || tok === "W*") clipNext = true;
    else if (tok === "n") box = null;
    else if (tok === "Do") forms++;
    if (tok !== "/" && !tok.startsWith("/")) args = [];
  }
  if (forms) out.push("form-xobjects " + forms);
  return out.sort();
}
/** First difference of the painted shapes of the two renders ("" when every page paints the same shapes). */
export function paintDiff(r) {
  for (let i = 0; i < Math.min(r.bm.pages.length, r.ref.pages.length); i++) {
    const a = paintShapes(r.bm, i); const b = paintShapes(r.ref, i);
    const ua = [...new Set(a)]; const ub = [...new Set(b)];
    const onlyA = ua.filter((s) => !ub.includes(s)); const onlyB = ub.filter((s) => !ua.includes(s));
    if (onlyA.length || onlyB.length) return `page ${i + 1} (${ua.length} vs ${ub.length} distinct shapes): only bm [${onlyA.slice(0, 5).join(" | ")}] only takumi [${onlyB.slice(0, 5).join(" | ")}]`;
  }
  return "";
}
/** First differences of the word positions of the two renders ("" when equal within `tol` pt). */
export function geometryDiff(r, tol = 0.75) {
  const a = wordBoxes(r.bm.bytes); const b = wordBoxes(r.ref.bytes);
  const diffs = [];
  if (a.length !== b.length) diffs.push(`pages ${a.length} vs ${b.length}`);
  for (let p = 0; p < Math.min(a.length, b.length); p++) {
    if (a[p].length !== b[p].length) { diffs.push(`page ${p + 1}: ${a[p].length} words vs ${b[p].length}`); continue; }
    for (let i = 0; i < a[p].length; i++) {
      const x = a[p][i]; const y = b[p][i];
      if (x[0] !== y[0] || Math.abs(x[1] - y[1]) > tol || Math.abs(x[2] - y[2]) > tol) { diffs.push(`page ${p + 1}: bm ${JSON.stringify(x.slice(0, 3))} vs takumi ${JSON.stringify(y.slice(0, 3))}`); break; }
    }
  }
  return diffs.slice(0, 3).join("; ");
}
/** `cmp` over a list of `[label, html, options, opts?]`. */
export async function cmpAll(t, list, common = {}) {
  for (const [label, html, options, opts] of list) await cmp(t, label, html, options, { ...common, ...(opts || {}) });
}
