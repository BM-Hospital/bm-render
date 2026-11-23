// Shared helpers of the PDF audit probes (scripts/pdf-audit/*.probe.mjs, run by scripts/pdf-audit/run.mjs).
//
// A probe renders the same input with bm-render/pdf (js/node-pdf.mjs: wasm, or the native addon with
// BM_RENDER_BACKEND=native) and, when it is available, with the published takumi-pdf npm package, and compares
// structure: page count, page boxes, extracted text (poppler's `pdftotext`), catalog / Info / annotation /
// structure-tree entries. The reference package is NOT a dependency of this repo: install it somewhere else
//
//   npm install --ignore-scripts takumi-pdf@0.20.0 @takumi-rs/helpers        (in an empty directory)
//
// and point TAKUMI_PDF_REF at that directory. Without it every comparison with the reference is reported as
// "unverified" instead of pass / fail, and the bm-only checks still run.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath, pathToFileURL } from "node:url";
import { structureParts } from "../pdf-structure.mjs";
import { interchangeParts } from "../pdf-interchange.mjs";
import { REVISION } from "../takumi-test-corpus.mjs";
import { findBin } from "../../bench/pdf/lib/tools.mjs";
import { kindOf } from "./gate.mjs";

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
export const takumiSrc = path.join(root, "tests", "upstream", "takumi");
export const outDir = path.join(root, "bench", "out", "pdf-audit");
mkdirSync(outDir, { recursive: true });

// ------------------------------------------------------------------------------------------------ engines

export const bmMod = await import(pathToFileURL(path.join(root, "js", "node-pdf.mjs")).href);

const refDir = process.env.TAKUMI_PDF_REF || "";
const pinnedEntry = process.env.TAKUMI_PDF_REF_ENTRY;
const refEntry = pinnedEntry ? path.resolve(pinnedEntry) : refDir ? path.join(refDir, "node_modules", "takumi-pdf", "bundlers", "node.mjs") : "";
const pinnedProvenance = pinnedEntry ? JSON.parse(readFileSync(path.join(path.dirname(refEntry), "wasm-provenance.json"), "utf8")) : null;
if (pinnedProvenance && pinnedProvenance.revision !== REVISION) throw new Error("The probe reference revision does not match the pinned corpus");
if (pinnedProvenance) for (const [file, expected] of [["wasm/takumi_pdf_wasm_bg.wasm", pinnedProvenance.wasmSha256], ["export.mjs", pinnedProvenance.wrapperSha256]]) {
  if (!expected || createHash("sha256").update(readFileSync(path.join(path.dirname(refEntry), file))).digest("hex") !== expected) throw new Error(`The pinned oracle artifact changed: ${file}`);
}
/** The takumi-pdf module (its documented JS API), or null when TAKUMI_PDF_REF is not set / not installed. */
export const refMod = refEntry && existsSync(refEntry) ? await import(pathToFileURL(refEntry).href) : null;
export const refVersion = refMod ? pinnedProvenance ? `${pinnedProvenance.version} source ${pinnedProvenance.revision}` : JSON.parse(readFileSync(path.join(refDir, "node_modules", "takumi-pdf", "package.json"), "utf8")).version : null;

/** What the probes compare against: the pinned source build (with its hashes) or the published package. */
export const oracle = !refMod ? null : pinnedProvenance
  ? { kind: pinnedProvenance.kind, revision: pinnedProvenance.revision, version: pinnedProvenance.version, entry: path.relative(root, refEntry), wasmSha256: pinnedProvenance.wasmSha256, wrapperSha256: pinnedProvenance.wrapperSha256, cargoLockSha256: pinnedProvenance.cargoLockSha256, wasmBindgen: pinnedProvenance.wasmBindgen }
  : { kind: "published-npm (not the pinned revision)", version: refVersion, entry: refEntry };

const fontCache = new Map();
const fontFiles = new Map();
/** Font bytes by a path relative to the repo root or to tests/upstream/takumi. */
export function font(rel) {
  if (!fontCache.has(rel)) {
    const a = path.join(root, rel); const b = path.join(takumiSrc, rel);
    const file = existsSync(a) ? a : b;
    const bytes = new Uint8Array(readFileSync(file));
    fontCache.set(rel, bytes);
    fontFiles.set(rel, { file: path.relative(root, file).replaceAll(path.sep, "/"), sha256: createHash("sha256").update(bytes).digest("hex") });
  }
  return fontCache.get(rel);
}
/** The font files the probes that ran loaded through `font()`, with their hashes. */
export const fontsUsed = () => [...fontFiles.values()].sort((x, y) => x.file.localeCompare(y.file));
/** The pdftotext executable the probes run, or null. */
export const popplerBin = () => findBin("poppler", "pdftotext") || "pdftotext";
export const INTER = "assets/fonts/Inter-Regular.ttf";
export const INTER_BOLD = "assets/fonts/Inter-Bold.ttf";
export const ARCHIVO = "assets/fonts/archivo/Archivo-VariableFont_wdth,wght.ttf";
export const NOTO_TC = "assets/fonts/noto-sans/NotoSansTC-VariableFont_wght.woff2";
export const TWEMOJI = "assets/fonts/twemoji/TwemojiMozilla-colr.woff2";
/** The fonts a probe gets when it names none. */
export const DEFAULT_FONTS = [INTER];

/**
 * Renders with one engine. `fonts` (paths, or `{ name, data, ... }` objects) are registered on a fresh PdfRenderer.
 * Never throws: returns `{ error }` (the message) or `{ bytes, pdf, text, pages }`.
 */
async function renderWith(mod, source, options = {}, { fonts = DEFAULT_FONTS, method = "render" } = {}) {
  let r;
  try {
    r = new mod.PdfRenderer();
    for (const f of fonts) {
      const v = typeof f === "string" ? font(f) : f;
      const x = r.registerFont ? r.registerFont(v) : r.loadFont(v);
      if (x && typeof x.then === "function") await x;
    }
    const out = await r[method](typeof source === "function" ? source(mod) : source, typeof options === "function" ? options(mod) : options);
    if (method !== "render" && method !== "renderSync") return { value: out };
    return describe(out);
  } catch (e) {
    return { error: String((e && e.message) || e), errorName: e && e.name };
  } finally {
    try { r && r.free && r.free(); } catch { /* already freed */ }
  }
}

/** bm-render/pdf render (see renderWith). */
export const bmRender = (source, options, extra) => renderWith(bmMod, source, options, extra);
/** takumi-pdf render, or null when the reference is not installed. */
export const refRender = (source, options, extra) => (refMod ? renderWith(refMod, source, options, extra) : Promise.resolve(null));
/** Both engines on the same input: `{ bm, ref }` (`ref` null when the reference is not installed). */
export async function both(source, options, extra) {
  return { bm: await bmRender(source, options, extra), ref: await refRender(source, options, extra) };
}

// ------------------------------------------------------------------------------------------------ PDF parsing
// (the parser of scripts/pdf-compare.mjs)

const WS = new Set([0, 9, 10, 12, 13, 32]);
const DELIM = new Set("()<>[]{}/%".split("").map((c) => c.charCodeAt(0)));
export class Ref { constructor(n) { this.n = n; } }
export class Name { constructor(s) { this.s = s; } toString() { return "/" + this.s; } }

class Lexer {
  constructor(buf, pos = 0) { this.b = buf; this.i = pos; }
  ws() {
    const b = this.b;
    for (;;) {
      while (this.i < b.length && WS.has(b[this.i])) this.i++;
      if (b[this.i] === 37) { while (this.i < b.length && b[this.i] !== 10 && b[this.i] !== 13) this.i++; continue; }
      return;
    }
  }
  word() {
    const b = this.b; const s = this.i;
    while (this.i < b.length && !WS.has(b[this.i]) && !DELIM.has(b[this.i])) this.i++;
    return b.toString("latin1", s, this.i);
  }
  value(allowRef = true) {
    this.ws();
    const b = this.b; const c = b[this.i];
    if (c === undefined) return undefined;
    if (c === 60 && b[this.i + 1] === 60) {
      this.i += 2; const d = {};
      for (;;) { this.ws(); if (b[this.i] === 62 && b[this.i + 1] === 62) { this.i += 2; return d; }
        const k = this.value(); if (!(k instanceof Name)) throw new Error("dict key at " + this.i); d[k.s] = this.value(); }
    }
    if (c === 60) { const e = b.indexOf(62, this.i); const hex = b.toString("latin1", this.i + 1, e).replace(/\s/g, ""); this.i = e + 1; return { hex }; }
    if (c === 91) { this.i++; const a = []; for (;;) { this.ws(); if (b[this.i] === 93) { this.i++; return a; } a.push(this.value()); } }
    if (c === 40) {
      let depth = 0; let out = ""; this.i++;
      for (;;) { const ch = b[this.i++];
        if (ch === undefined) break;
        if (ch === 92) { out += "\\" + String.fromCharCode(b[this.i++]); continue; }
        if (ch === 40) depth++;
        if (ch === 41) { if (depth === 0) break; depth--; }
        out += String.fromCharCode(ch); }
      return { str: out };
    }
    if (c === 47) { this.i++; return new Name(this.word()); }
    if (c === 123 || c === 125) { this.i++; return { op: String.fromCharCode(c) }; }
    const w = this.word();
    if (w === "") { this.i++; return { op: String.fromCharCode(c) }; }
    if (/^[+-]?(\d+\.?\d*|\.\d+)$/.test(w)) {
      if (allowRef) {
        const save = this.i; this.ws(); const g = this.word(); this.ws();
        if (/^\d+$/.test(w) && /^\d+$/.test(g) && b[this.i] === 82 && (WS.has(b[this.i + 1]) || DELIM.has(b[this.i + 1]) || b[this.i + 1] === undefined)) { this.i++; return new Ref(+w); }
        this.i = save;
      }
      return Number(w);
    }
    if (w === "true") return true; if (w === "false") return false; if (w === "null") return null;
    return { op: w };
  }
}

/** Parses a PDF: `{ objs: Map<number, {n, dict, raw?, data?}>, resolve(v), obj(ref), pages: [{dict, ref}], catalog, trailer, header }`. */
export function parsePdf(bytes) {
  const buf = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const objs = new Map();
  const re = /(\d+) 0 obj\s/g;
  const s = buf.toString("latin1");
  let m;
  let trailer = null;
  while ((m = re.exec(s))) {
    const lx = new Lexer(buf, m.index + m[0].length);
    let dict;
    try { dict = lx.value(); } catch { continue; }
    lx.ws();
    const o = { n: +m[1], dict };
    if (s.startsWith("stream", lx.i)) {
      let p = lx.i + 6; if (s[p] === "\r") p++; if (s[p] === "\n") p++;
      const len = typeof dict.Length === "number" ? dict.Length : 0;
      const raw = buf.subarray(p, p + len);
      o.raw = raw;
      const filt = dict.Filter instanceof Name ? dict.Filter.s : Array.isArray(dict.Filter) ? dict.Filter.map((f) => f.s).join(",") : "";
      if (filt === "FlateDecode") { try { o.data = zlib.inflateSync(raw); } catch { o.data = raw; } } else o.data = raw;
      re.lastIndex = p + len;
    }
    objs.set(o.n, o);
    if (dict && dict.Type instanceof Name && dict.Type.s === "XRef") trailer = dict;
    if (dict && dict.Type instanceof Name && dict.Type.s === "ObjStm" && o.data) {
      const hdr = new Lexer(o.data, 0); const pairs = [];
      for (let k = 0; k < dict.N; k++) pairs.push([hdr.value(false), hdr.value(false)]);
      for (const [num, off] of pairs) { const l2 = new Lexer(o.data, dict.First + off); objs.set(num, { n: num, dict: l2.value(), inObjStm: true }); }
    }
  }
  if (!trailer) {
    const t = s.lastIndexOf("trailer");
    if (t >= 0) { try { trailer = new Lexer(buf, t + 7).value(); } catch { /* none */ } }
  }
  const resolve = (v) => (v instanceof Ref ? (objs.get(v.n) || {}).dict : v);
  const obj = (v) => (v instanceof Ref ? objs.get(v.n) : null);
  const catalogObj = [...objs.values()].find((o) => o.dict && o.dict.Type instanceof Name && o.dict.Type.s === "Catalog");
  const catalog = catalogObj ? catalogObj.dict : {};
  const pages = [];
  const walk = (node) => { for (const k of node.Kids) { const d = resolve(k); if (d.Type.s === "Pages") walk(d); else pages.push({ dict: d, ref: k }); } };
  if (catalog.Pages) walk(resolve(catalog.Pages));
  return { objs, resolve, obj, pages, catalog, trailer: trailer || {}, header: s.slice(0, 8), source: s };
}

/** Decodes a PDF text string value (`{hex}` or `{str}`), UTF-16BE with BOM included. */
export function pdfText(v) {
  if (v && v.hex !== undefined) {
    const b = Buffer.from(v.hex, "hex");
    if (b[0] === 0xfe && b[1] === 0xff) { let o = ""; for (let i = 2; i + 1 < b.length; i += 2) o += String.fromCharCode((b[i] << 8) | b[i + 1]); return o; }
    return b.toString("latin1");
  }
  if (v && v.str !== undefined) return v.str;
  return v === undefined ? undefined : String(v);
}

/** Canonical one-line form of a PDF value (references as `R`, numbers rounded to 3 decimals). */
export function fmt(v) {
  return typeof v === "number" ? String(Math.round(v * 1000) / 1000) : v instanceof Name ? "/" + v.s : Array.isArray(v) ? "[" + v.map(fmt).join(" ") + "]"
    : v && v.hex !== undefined ? "<" + v.hex + ">" : v && v.str !== undefined ? "(" + v.str + ")" : v instanceof Ref ? "R" : v === null ? "null"
    : v && typeof v === "object" ? "<<" + Object.entries(v).map(([k, x]) => "/" + k + " " + fmt(x)).join(" ") + ">>" : String(v);
}

let pdftotextMissing = false;
/** Text of a PDF through poppler's `pdftotext` (`-layout` off): `{ ok, text, stderr }`, or `{ skipped: true }` without poppler. */
export function pdftotext(bytes, name = "probe", args = []) {
  if (pdftotextMissing) return { skipped: true, text: "" };
  const file = path.join(outDir, name.replace(/[^\w.-]+/g, "_") + ".pdf");
  writeFileSync(file, bytes);
  const executable = findBin("poppler", "pdftotext") || "pdftotext";
  const r = spawnSync(executable, [...args, file, "-"], { encoding: "utf8", windowsHide: true });
  rmSync(file, { force: true });
  if (r.error && r.error.code === "ENOENT") { pdftotextMissing = true; return { skipped: true, text: "" }; }
  const stderr = r.stderr?.trim() || "";
  // Poppler's bbox exporter reports this for genuinely blank pages. The
  // geometry parser still requires page elements, so missing output fails.
  const blankPageWarning = args.includes("-bbox") && stderr.split(/\r?\n/).every(line => line === "no word list");
  return { ok: r.status === 0 && (!stderr || blankPageWarning), stderr, text: r.stdout || "" };
}

/** Everything a probe usually looks at in a rendered file. */
export function describe(bytes) {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const pdf = parsePdf(u8);
  const box = (d, k) => { let n = d; while (n && n[k] === undefined && n.Parent) n = pdf.resolve(n.Parent); return n && n[k] ? pdf.resolve(n[k]).map((x) => Math.round(x * 1000) / 1000) : null; };
  const info = pdf.resolve(pdf.trailer.Info) || {};
  return {
    bytes: u8,
    pdf,
    /** `%PDF-x.y` */
    version: pdf.header.slice(5, 8),
    pages: pdf.pages.map((p) => ({ media: box(p.dict, "MediaBox"), crop: box(p.dict, "CropBox"), dict: p.dict })),
    info: Object.fromEntries(Object.entries(info).map(([k, v]) => [k, pdfText(v)])),
    catalog: pdf.catalog,
    /** per page: the decoded content stream text */
    content: (i) => { const c = pdf.pages[i].dict.Contents; const list = Array.isArray(c) ? c : [c]; return list.map((r) => { const o = pdf.obj(r); return o && o.data ? o.data.toString("latin1") : ""; }).join("\n"); },
    /** text per page through pdftotext (form feed separated) */
    get text() {
      const t = pdftotext(u8, "t" + Math.random().toString(36).slice(2, 8));
      if (t.skipped || !t.ok) throw new Error(`Cannot verify PDF text: ${t.skipped ? "pdftotext is missing" : t.stderr}`);
      return t.text;
    },
    get textPages() { return this.text.split("\f").slice(0, -1).map((s) => s.trim()); },
    get structure() { return structureParts(pdf, { Name, Ref }); },
    get interchange() { return interchangeParts(pdf, { Name, Ref }); },
    /** objects by /Type (and /Subtype when given) */
    typed: (type, subtype) => [...pdf.objs.values()].filter((o) => o.dict && typeof o.dict === "object" && o.dict.Type instanceof Name && o.dict.Type.s === type && (!subtype || (o.dict.Subtype instanceof Name && o.dict.Subtype.s === subtype))),
    /** objects by /Subtype alone (annotations, images, fonts without /Type) */
    subtyped: (subtype) => [...pdf.objs.values()].filter((o) => o.dict && typeof o.dict === "object" && !Array.isArray(o.dict) && o.dict.Subtype instanceof Name && o.dict.Subtype.s === subtype),
  };
}

/** Whitespace-insensitive text, for comparing two extractions. */
export const squash = (s) => String(s || "").replace(/\s+/g, " ").trim();

// ------------------------------------------------------------------------------------------------ probes

const probes = [];
/**
 * Registers a probe. `id` is `area.feature[.case]`, `feature` is the row of docs/PDF_AUDIT.md it backs.
 * `fn(t)` uses `t.ok(cond, what)`, `t.same(what, bmValue, refValue)` (skipped as unverified without the reference),
 * `t.note(text)`, and `t.both(source, options, extra)`.
 */
export function probe(id, feature, fn) { probes.push({ id, feature, fn }); }
/** The registered probes' ids and features, in registration order (nothing is run). */
export const listProbes = () => probes.map(({ id, feature }) => ({ id, feature }));

const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/** Runs the registered probes whose id matches `filter` (substring). Returns the result rows. */
export async function runProbes(filter = []) {
  const rows = [];
  for (const p of probes) {
    if (filter.length && !filter.some((f) => p.id.includes(f))) continue;
    const row = { id: p.id, feature: p.feature, pass: 0, fail: 0, unverified: 0, notes: [], failures: [], kinds: {} };
    /** assertions per kind (scripts/pdf-audit/gate.mjs kindOf) */
    const count = (what, good) => { const k = kindOf(what); const c = (row.kinds[k] ??= { pass: 0, fail: 0 }); if (good) c.pass++; else c.fail++; };
    const t = {
      both,
      bm: bmRender,
      ref: refRender,
      hasRef: !!refMod,
      ok(cond, what) { count(what, !!cond); if (cond) row.pass++; else { row.fail++; row.failures.push(what); } return !!cond; },
      /** bm value must equal the reference value; without the reference: unverified. */
      same(what, a, b) {
        if (!refMod) { row.unverified++; return false; }
        const good = eq(a, b);
        count(what, good);
        if (good) row.pass++; else { row.fail++; row.failures.push(`${what}: bm ${JSON.stringify(a)?.slice(0, 300)} vs takumi ${JSON.stringify(b)?.slice(0, 300)}`); }
        return good;
      },
      /** A known, documented difference from the reference: counted apart from failures. */
      differs(what) { row.notes.push("differs: " + what); },
      note(text) { row.notes.push(text); },
    };
    if (process.env.PDF_AUDIT_TRACE) process.stderr.write(`start ${p.id}\n`);
    try { await p.fn(t); } catch (e) { row.fail++; row.failures.push("probe threw: " + ((e && e.stack) || e)); }
    row.status = row.fail ? "FAIL" : row.unverified ? "UNVERIFIED" : "PASS";
    rows.push(row);
  }
  return rows;
}

/** Common comparison: both render (or both fail with the same message), same page count, boxes and extracted text. */
export function sameDocument(t, r, { text = true, boxes = true } = {}) {
  const { bm, ref } = r;
  if (!ref) { t.ok(!bm.error, "bm renders" + (bm.error ? ": " + bm.error : "")); t.same("reference", 0, 0); return false; }
  if (bm.error || ref.error) { return t.same("error", bm.error || null, ref.error || null) && false; }
  let good = t.same("page count", bm.pages.length, ref.pages.length);
  if (boxes) good = t.same("page boxes", bm.pages.map((p) => p.media), ref.pages.map((p) => p.media)) && good;
  if (text) good = t.same("text per page", bm.textPages.map(squash), ref.textPages.map(squash)) && good;
  return good;
}

/** bm-render prefixes its messages with `bm-render: `; takumi-pdf's wasm glue sometimes with `Error: `. */
export const errNorm = (m) => (m == null ? m : String(m).replace(/^bm-render: /, "").replace(/^Error: /, ""));
/** Messages serde generates for a value of the wrong shape: Rust implementation detail, not part of takumi-pdf's API. */
export const isSerdeMessage = (m) => /did not match any variant|invalid type: |unknown variant|unknown field|missing field|invalid value: |invalid length|a band is a node, HTML, or false|expected .* at line \d+|EOF while parsing|key must be a string|invalid entry/.test(String(m)) || isGlueCrash(m);
/**
 * TypeErrors takumi-pdf's JS / wasm-bindgen glue throws when it dereferences an option of the wrong shape (a string
 * where it reads a list: `Reflect.get called on non-object`, `fonts.map is not a function`, ...): an accident of the
 * glue rather than a message takumi-pdf words; like serde's type errors, bm only has to reject the input too.
 */
export const isGlueCrash = (m) => /^(TypeError: )?(Reflect\.get called on non-object|Cannot use 'in' operator to search for|[\w.$]+ is not a function|Cannot read properties of (undefined|null))/.test(String(m));
/**
 * Compares the outcome of both engines when at least one failed: the messages must be equal after errNorm; when
 * takumi's message is a serde type error, bm only has to reject too (its own wording), noted as such.
 * Returns true when the caller should stop (an error was involved).
 */
export function sameError(t, label, bm, ref) {
  if (!ref) return false;
  if (!bm.error && !ref.error) return false;
  const a = errNorm(bm.error); const b = errNorm(ref.error);
  if (a && b && isSerdeMessage(b)) { t.ok(true, label); t.note(`${label}: both reject; wording differs (takumi: serde "${b.slice(0, 90)}" / bm: "${a.slice(0, 90)}")`); return true; }
  t.same(`${label}: error`, a || "(renders)", b || "(renders)");
  return true;
}

const CRC_TABLE = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
const crc32 = (buf) => { let c = 0xffffffff; for (const b of buf) c = CRC_TABLE[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
/** A valid 8-bit RGBA PNG; `pixel(x, y)` returns `[r, g, b, a]` (default: a red / blue checker, opaque). */
export function pngRgba(w, h, pixel = (x, y) => ((x + y) & 1 ? [220, 30, 30, 255] : [30, 30, 220, 255])) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) raw.set(pixel(x, y), y * (w * 4 + 1) + 1 + x * 4);
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const body = Buffer.concat([Buffer.from(type, "latin1"), data]); const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body)); return Buffer.concat([len, body, crc]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr.set([8, 6, 0, 0, 0], 8);
  return new Uint8Array(Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]));
}
/** `/Producer` is the one Info entry that names the engine: "bm-render" vs "takumi-pdf <version>". */
export const noProducer = (s) => (typeof s === "string" ? s.replace(/takumi-pdf \d+\.\d+\.\d+|bm-render(?: \d+\.\d+\.\d+)?/g, "PRODUCER") : s);
