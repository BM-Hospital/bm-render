// Compares bm-render's PDF graphics output with takumi-pdf's golden fixtures
// (tests/upstream/takumi/takumi-pdf/tests/fixtures-generated/*.pdf, inputs from tests/pdf_fixtures.rs).
//
//   node scripts/pdf-compare.mjs [--verbose] [--dump=<fixture>] [name ...]
//
// Renders each fixture's input with js/node-pdf.mjs (build it first: `npm run build:pdf`), parses both
// PDFs with a small built-in parser (Flate streams inflated), and flattens each page into a canonical
// operator list: resource names and object numbers are replaced by what they point at (ExtGState
// entries, soft masks with their group content, shading / tiling patterns with their shadings,
// functions and tile content, form XObjects with their content, image dictionaries, fonts by their
// first-use number and kind), so two files compare equal when they draw the same thing the same way.
// Every page is compared (page count and MediaBox included). Text objects (BT..ET) are compared with
// the rest, marked content included (tagging: `/Artifact BMC`, `/P<</MCID n>>BDC`, the text's own
// `/Span <</ActualText ..>> BDC` and `/ReversedChars BMC`); q..Q groups painting nothing are dropped.
// The structure tree and its parent tree are compared with the interchange parts
// (scripts/pdf-structure.mjs).
//
// Fonts are compared on their own: per font in first-use order, the Type0 / CIDFont / descriptor
// entries (subset tag, widths, metrics, flags), the ToUnicode CMap, and the font program (length +
// hash), or for a Type3 font its matrix, widths, CMap and glyph procedures.
//
// Verdicts per fixture: IDENTICAL (same operators and numbers), CLOSE (same operators, numbers within
// 0.01 absolute or 1e-4 relative), DIFFER (first difference shown), plus a font verdict (same / which
// part differs). Missing inputs, uncovered goldens and rendering failures exit nonzero. --strict
// also rejects any CLOSE / DIFFER page content, interchange part or font dictionary / CMap that
// scripts/pdf-audit/exceptions.json ("golden") does not list for that fixture, and a listed one that is
// gone (stale); font program byte differences are informational.
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { createHash } from "node:crypto";
import { REVISION } from "./takumi-test-corpus.mjs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { taggingFixtures } from "./pdf-tagging-fixtures.mjs"; // [tagging]
import { moreFixtures } from "./pdf-compare-more.mjs"; // [more] goldens the lists above leave out
import { interchangeParts, compareInterchange, printInterchange, INTERCHANGE_FIXTURES } from "./pdf-interchange.mjs"; // [interchange]

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ref = path.join(root, "tests", "upstream", "takumi");
const argv = process.argv.slice(2);
for (const arg of argv) if (arg.startsWith("--") && !["--verbose", "--strict"].includes(arg) && !arg.startsWith("--dump=") && !arg.startsWith("--golden-dir=")) throw new Error(`Unknown option: ${arg}`);
const goldenOverride = argv.find((a) => a.startsWith("--golden-dir="))?.slice(13);
const goldenDir = goldenOverride ? path.resolve(goldenOverride) : path.join(ref, "takumi-pdf", "tests", "fixtures-generated");
const provenance = goldenOverride ? JSON.parse(readFileSync(path.join(goldenDir, "..", "provenance.json"), "utf8")) : { revision: REVISION, kind: "committed-fixtures" };
if (provenance.revision !== REVISION) throw new Error("Golden reference revision does not match the vendored inputs");
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const verbose = argv.includes("--verbose");
const dumpName = (argv.find((a) => a.startsWith("--dump=")) || "").slice(7);
const only = argv.filter((a) => !a.startsWith("--"));
if (!existsSync(goldenDir)) throw new Error("Missing Takumi PDF goldens. Run node scripts/fetch-takumi-tests.mjs first.");

// ------------------------------------------------------------------------------------------------
// PDF parsing
// ------------------------------------------------------------------------------------------------

const WS = new Set([0, 9, 10, 12, 13, 32]);
const DELIM = new Set("()<>[]{}/%".split("").map((c) => c.charCodeAt(0)));

class Ref { constructor(n) { this.n = n; } }
class Name { constructor(s) { this.s = s; } toString() { return "/" + this.s; } }

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
  // one token or composite value; `allowRef` turns `n 0 R` into a Ref
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

function parsePdf(buf) {
  const objs = new Map();
  const re = /(\d+) 0 obj\s/g;
  const s = buf.toString("latin1");
  let m;
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
    if (dict && dict.Type instanceof Name && dict.Type.s === "ObjStm" && o.data) {
      const hdr = new Lexer(o.data, 0); const pairs = [];
      for (let k = 0; k < dict.N; k++) pairs.push([hdr.value(false), hdr.value(false)]);
      for (const [num, off] of pairs) { const l2 = new Lexer(o.data, dict.First + off); objs.set(num, { n: num, dict: l2.value() }); }
    }
  }
  const resolve = (v) => (v instanceof Ref ? (objs.get(v.n) || {}).dict : v);
  const obj = (v) => (v instanceof Ref ? objs.get(v.n) : null);
  const catalog = [...objs.values()].find((o) => o.dict && o.dict.Type instanceof Name && o.dict.Type.s === "Catalog");
  const pagesRoot = resolve(catalog.dict.Pages);
  const pages = [];
  const walk = (node) => { for (const k of node.Kids) { const d = resolve(k); if (d.Type.s === "Pages") walk(d); else pages.push({ dict: d, ref: k }); } };
  walk(pagesRoot);
  return { objs, resolve, obj, pages };
}

function contentOps(data) {
  const lx = new Lexer(data, 0); const ops = []; let args = [];
  for (;;) {
    const v = lx.value(false);
    if (v === undefined) break;
    if (v && v.op !== undefined) { ops.push({ op: v.op, args }); args = []; } else args.push(v);
  }
  return ops;
}

// ------------------------------------------------------------------------------------------------
// canonical flattening
// ------------------------------------------------------------------------------------------------

const fmt = (v) => (typeof v === "number" ? String(v) : v instanceof Name ? v.toString() : Array.isArray(v) ? "[" + v.map(fmt).join(" ") + "]" : v && v.hex !== undefined ? "<" + v.hex + ">" : v && v.str !== undefined ? "(" + v.str + ")" : v instanceof Ref ? "R" : JSON.stringify(v));
const PAINT = new Set(["f", "f*", "F", "B", "B*", "b", "b*", "S", "s", "sh", "Do", "Tj", "TJ", "'", "\""]);

/** Font object number -> first-use index across the document (`fontIds` shared by every page). */
function fontKey(pdf, ref, fontIds) {
  const n = ref instanceof Ref ? ref.n : -1;
  if (!fontIds.has(n)) fontIds.set(n, fontIds.size);
  const d = pdf.resolve(ref) || {};
  return `f${fontIds.get(n)}:${d.Subtype ? d.Subtype.s : "?"}`;
}

function decodeText(v) {
  if (v && v.hex !== undefined) {
    const b = Buffer.from(v.hex, "hex");
    if (b[0] === 0xfe && b[1] === 0xff) { let o = ""; for (let i = 2; i + 1 < b.length; i += 2) o += String.fromCharCode((b[i] << 8) | b[i + 1]); return o; }
    return b.toString("latin1");
  }
  if (v && v.str !== undefined) return v.str;
  return fmt(v);
}

function flatten(pdf, pageIdx, fontIds = new Map()) {
  const out = [];
  const seen = new Set();
  const res = (r, kind, name) => { const rd = pdf.resolve(r) || {}; const sub = pdf.resolve(rd[kind]) || {}; return sub[name]; };
  const fnDump = (fr, d) => {
    const o = pdf.obj(fr); const f = o ? o.dict : pdf.resolve(fr);
    const t = f.FunctionType;
    if (t === 2) return `fn2(C0=${fmt(f.C0)} C1=${fmt(f.C1)} N=${f.N} D=${fmt(f.Domain)} R=${fmt(f.Range)})`;
    if (t === 3) return `fn3(D=${fmt(f.Domain)} B=${fmt(f.Bounds)} E=${fmt(f.Encode)} F=[${f.Functions.map((x) => fnDump(x, d + 1)).join(" ")}])`;
    if (t === 4) return `fn4(D=${fmt(f.Domain)} R=${fmt(f.Range)} code=${o.data.toString("latin1").replace(/\s+/g, " ")})`;
    return "fn?";
  };
  const shDump = (sr) => {
    const s = pdf.resolve(sr);
    return `shading(T=${s.ShadingType} CS=${fmt(s.ColorSpace)} C=${fmt(s.Coords)} D=${fmt(s.Domain)} M=${fmt(s.Matrix)} E=${fmt(s.Extend)} F=${fnDump(s.Function, 0)})`;
  };
  const emitStream = (o, resources, depth) => {
    if (depth > 30) { out.push("<too deep>"); return; }
    const ops = contentOps(o.data);
    const marks = [];
    for (const { op, args } of ops) {
      if (op === "MP" || op === "DP") continue;
      if (op === "BDC" || op === "BMC") {
        const tag = args[0] instanceof Name ? args[0].s : "";
        const props = args[1] && typeof args[1] === "object" && !(args[1] instanceof Name) ? args[1] : null;
        if (op === "BDC" && props && props.ActualText !== undefined) { marks.push(true); out.push(`ActualText(${JSON.stringify(decodeText(props.ActualText))})`); continue; }
        if (op === "BMC" && tag === "ReversedChars") { marks.push(true); out.push("ReversedChars"); continue; }
        // tagging: artifacts and marked-content sequences (MCID and property list)
        marks.push(true);
        out.push(`${op} /${tag}${props ? " " + Object.entries(props).map(([k, v]) => `${k}=${k === "MCID" ? v : JSON.stringify(decodeText(v))}`).join(" ") : ""}`);
        continue;
      }
      if (op === "EMC") { if (marks.pop()) out.push("EMC"); continue; }
      if (op === "Tf") { out.push(`${fontKey(pdf, res(resources, "Font", args[0].s), fontIds)} ${fmt(args[1])} Tf`); continue; }
      if (op === "Do") {
        const xr = res(resources, "XObject", args[0].s); const x = pdf.obj(xr);
        if (x.dict.Subtype.s === "Image") {
          const d = x.dict; const sm = d.SMask ? pdf.obj(d.SMask) : null;
          const crc = (b) => zlib.crc32 ? zlib.crc32(b).toString(16) : b.length;
          out.push(`Do(image ${d.Width}x${d.Height} ${fmt(d.ColorSpace)} bpc=${d.BitsPerComponent} filter=${fmt(d.Filter)} decode=${fmt(d.Decode)} px=${d.Filter && d.Filter.s === "DCTDecode" ? "dct:" + crc(x.raw) : crc(x.data)}${sm ? " smask=" + crc(sm.data) : ""})`);
        } else {
          const d = x.dict; const g = pdf.resolve(d.Group);
          out.push(`Do(form bbox=${fmt(d.BBox)} m=${fmt(d.Matrix)} group=${g ? (g.I ? "I" : "") + (g.CS ? fmt(g.CS) : "") : "-"}){`);
          emitStream(x, d.Resources, depth + 1);
          out.push("}");
        }
        continue;
      }
      if (op === "gs") {
        const g = pdf.resolve(res(resources, "ExtGState", args[0].s));
        let s = `gs(ca=${g.ca ?? "-"} CA=${g.CA ?? "-"} BM=${g.BM ? fmt(g.BM) : "-"}`;
        if (g.SMask instanceof Ref) {
          const m = pdf.resolve(g.SMask);
          out.push(s + ` smask=${fmt(m.S)}){`);
          const x = pdf.obj(m.G);
          out.push(`group bbox=${fmt(x.dict.BBox)}{`);
          emitStream(x, x.dict.Resources, depth + 1);
          out.push("}}");
          continue;
        }
        out.push(s + ")");
        continue;
      }
      if ((op === "scn" || op === "SCN") && args.length === 1 && args[0] instanceof Name) {
        const pr = res(resources, "Pattern", args[0].s); const p = pdf.obj(pr);
        if (p.dict.PatternType === 2) { out.push(`${op}(pattern2 m=${fmt(p.dict.Matrix)} ${shDump(p.dict.Shading)})`); continue; }
        out.push(`${op}(pattern1 bbox=${fmt(p.dict.BBox)} m=${fmt(p.dict.Matrix)} step=${p.dict.XStep},${p.dict.YStep}){`);
        emitStream(p, p.dict.Resources, depth + 1);
        out.push("}");
        continue;
      }
      if (op === "sh") { out.push(`sh(${shDump(res(resources, "Shading", args[0].s))})`); continue; }
      if (op === "cs" || op === "CS") { out.push(args.map(fmt).join(" ") + " " + op); continue; }
      out.push((args.length ? args.map(fmt).join(" ") + " " : "") + op);
    }
  };
  const page = pdf.pages[pageIdx];
  const cont = page.dict.Contents;
  const streams = Array.isArray(cont) ? cont.map((c) => pdf.obj(c)) : [pdf.obj(cont)];
  for (const st of streams) emitStream(st, page.dict.Resources, 0);
  return { ops: normalize(out), mediaBox: page.dict.MediaBox };
}

/** Every page flattened (one font numbering for the document). */
function flattenAll(pdf) {
  const fontIds = new Map();
  const pages = pdf.pages.map((_, i) => flatten(pdf, i, fontIds));
  return { pages, fontIds };
}

/** Drops q..Q groups and BT..ET objects (and {..} blocks) that paint nothing. */
function normalize(lines) {
  // tree of groups: q..Q, BT..ET and X{ .. }
  const rootN = { items: [] }; const stack = [rootN];
  for (const l of lines) {
    const top = stack[stack.length - 1];
    if (l === "q") { const g = { open: "q", close: "Q", items: [] }; top.items.push(g); stack.push(g); continue; }
    if (l === "BT") { const g = { open: "BT", close: "ET", items: [] }; top.items.push(g); stack.push(g); continue; }
    if (l === "Q" || l === "ET" || l === "}" || l === "}}") { if (stack.length > 1) stack.pop(); continue; }
    if (l.endsWith("{")) { const g = { open: l, close: l.includes("smask=") ? "}}" : "}", items: [] }; top.items.push(g); stack.push(g); continue; }
    top.items.push(l);
  }
  const paints = (g) => g.items.some((it) => typeof it === "string" ? PAINT.has(it.split(/[ (]/).pop()) || /^(Do|sh)\(/.test(it) : paints(it));
  const out = [];
  const emit = (g) => {
    for (const it of g.items) {
      if (typeof it === "string") { out.push(it); continue; }
      if ((it.open === "q" || it.open === "BT") && !paints(it)) continue;
      if (it.open !== "q" && /^(Do\(form|group )/.test(it.open) && !paints(it)) { out.push(it.open.replace(/\{$/, "{<empty>}")); continue; }
      out.push(it.open); emit(it); out.push(it.close);
    }
  };
  emit(rootN);
  return out;
}

/** Object kinds in file (= numbering) order, leaving out what the later waves own (tagging, metadata,
 *  annotations, outline, catalog / info / xref). Two files with the same list number their objects alike. */
function objectLayout(pdf) {
  const kinds = [];
  for (const o of [...pdf.objs.values()].sort((a, b) => a.n - b.n)) {
    const d = o.dict;
    if (Array.isArray(d)) continue; // parent-tree arrays
    if (!d || typeof d !== "object") continue;
    const t = d.Type instanceof Name ? d.Type.s : "";
    if (["StructTreeRoot", "StructElem", "Metadata", "Catalog", "XRef", "ObjStm", "OutputIntent", "Annot", "Outlines", "MarkInfo", "Filespec", "EmbeddedFile"].includes(t)) continue;
    if (d.Producer !== undefined || d.Nums !== undefined || d.Names !== undefined || (d.Subtype instanceof Name && d.Subtype.s === "Link") || (d.Title !== undefined && d.Parent !== undefined)) continue;
    if (t === "Font") { kinds.push("Font(" + d.Subtype.s + ")"); continue; }
    if (o.data && !t && d.FunctionType === undefined && d.Subtype === undefined && pdf.pages.every((p) => !(p.dict.Contents instanceof Ref && p.dict.Contents.n === o.n))) { kinds.push(d.Length1 !== undefined ? "FontFile2" : "Stream"); continue; }
    if (o.data && !t && d.Subtype instanceof Name && /Type0C|Type1C|OpenType/.test(d.Subtype.s)) { kinds.push("FontFile3"); continue; }
    if (t === "XObject") { kinds.push(d.Subtype.s === "Image" ? (d.ColorSpace instanceof Name && d.ColorSpace.s === "DeviceGray" && !d.SMask ? "Image(gray)" : "Image") : "Form"); continue; }
    if (t === "Pattern") { kinds.push("Pattern" + d.PatternType); continue; }
    if (t) { kinds.push(t); continue; }
    if (d.ProcSet) { kinds.push("Resources"); continue; }
    if (d.FunctionType !== undefined) { kinds.push("Function" + d.FunctionType); continue; }
    if (d.ShadingType !== undefined) { kinds.push("Shading" + d.ShadingType); continue; }
    if (o.data) { kinds.push("Contents"); continue; }
    kinds.push("?");
  }
  return kinds;
}

/** Per font (first-use order of `fontIds`), its parts as comparable lines: `dict` (Type0 / CIDFont /
 *  descriptor entries or the Type3 dictionary), `cmap` (ToUnicode), `program` (font file length + hash)
 *  and `procs` (Type3 glyph procedures). */
function fontParts(pdf, fontIds) {
  const hash = (b) => (b ? `${b.length}:${zlib.crc32 ? zlib.crc32(b).toString(16) : crc32(b).toString(16)}` : "-");
  const cmap = (r) => { const o = pdf.obj(r); return o && o.data ? o.data.toString("latin1").replace(/\s+/g, " ").trim() : "-"; };
  const keys = (d, ks) => ks.map((k) => `${k}=${d[k] === undefined ? "-" : fmt(d[k])}`).join(" ");
  const fonts = [];
  for (const [n] of [...fontIds.entries()].sort((a, b) => a[1] - b[1])) {
    const o = pdf.objs.get(n); if (!o) { fonts.push({ dict: "?", cmap: "-", program: "-", procs: "-" }); continue; }
    const d = o.dict;
    if (d.Subtype.s === "Type0") {
      const cid = pdf.resolve(d.DescendantFonts[0]);
      const fd = pdf.resolve(cid.FontDescriptor);
      const ffKey = ["FontFile2", "FontFile3", "FontFile"].find((k) => fd[k] !== undefined);
      const ff = ffKey ? pdf.obj(fd[ffKey]) : null;
      fonts.push({
        dict: `Type0 ${keys(d, ["BaseFont", "Encoding"])} | ${keys(cid, ["Subtype", "BaseFont", "DW", "CIDToGIDMap"])} CIDSystemInfo=${fmt(Object.values(pdf.resolve(cid.CIDSystemInfo) || {}))} W=${fmt(cid.W)} | ${keys(fd, ["FontName", "Flags", "FontBBox", "ItalicAngle", "Ascent", "Descent", "CapHeight", "StemV"])} ${ffKey}${ff && ff.dict.Subtype ? "/" + ff.dict.Subtype.s : ""}`,
        cmap: cmap(d.ToUnicode),
        program: hash(ff && ff.data),
        procs: "-",
      });
    } else {
      const procs = pdf.resolve(d.CharProcs) || {};
      fonts.push({
        dict: `${d.Subtype.s} ${keys(d, ["FontBBox", "FontMatrix", "FirstChar", "LastChar", "Widths"])} Encoding=${fmt(Object.values(pdf.resolve(d.Encoding) || {}))}`,
        cmap: cmap(d.ToUnicode),
        program: "-",
        procs: Object.entries(procs).map(([k, r]) => { const po = pdf.obj(r); return `${k}:${po && po.data ? po.data.toString("latin1").replace(/\s+/g, " ").trim() : "?"}${po && po.dict && po.dict.Resources ? " +res" : ""}`; }).join(" | "),
      });
    }
  }
  return fonts;
}

/** Font verdict: "same", or the parts that differ ("f1.program" ...); count mismatch first. */
function compareFonts(mine, gold) {
  if (mine.length !== gold.length) return { same: false, what: `${mine.length} vs ${gold.length} fonts` };
  const diffs = [];
  for (let i = 0; i < mine.length; i++) for (const k of ["dict", "cmap", "program", "procs"]) if (mine[i][k] !== gold[i][k]) diffs.push(`f${i}.${k}`);
  return { same: diffs.length === 0, what: diffs.join(" ") };
}

// ------------------------------------------------------------------------------------------------
// comparison
// ------------------------------------------------------------------------------------------------

const NUM = /-?\d*\.?\d+(?:e[+-]?\d+)?/gi;
function sameShape(a, b) { return a.replace(NUM, "#") === b.replace(NUM, "#"); }
function closeNums(a, b) {
  const x = a.match(NUM) || []; const y = b.match(NUM) || [];
  if (x.length !== y.length) return false;
  return x.every((v, i) => { const p = +v; const q = +y[i]; const d = Math.abs(p - q); return d <= 0.01 || d <= 1e-4 * Math.max(Math.abs(p), Math.abs(q)); });
}

/** A TJ array with its sub-0.05 adjustments (float noise of the glyph positions, < 0.05 / 1000 em)
 *  dropped and the strings around them joined; other lines unchanged. */
function tjLoose(l) {
  if (!l.endsWith("] TJ")) return l;
  const lx = new Lexer(Buffer.from(l, "latin1"), 0);
  const arr = lx.value(false);
  if (!Array.isArray(arr)) return l;
  const out = [];
  for (const v of arr) {
    if (typeof v === "number") { if (Math.abs(v) >= 0.05) out.push(Math.round(v * 100) / 100); continue; }
    const s = v.str !== undefined ? Buffer.from(v.str, "latin1").toString("hex") : v.hex;
    if (out.length && typeof out[out.length - 1] === "string") out[out.length - 1] += s; else out.push(s);
  }
  return "[" + out.join(" ") + "] TJ";
}

function compare(mine, gold) {
  if (mine.length === gold.length && mine.every((l, i) => l === gold[i])) return { verdict: "IDENTICAL" };
  if (mine.length === gold.length && mine.every((l, i) => l === gold[i] || tjLoose(l) === tjLoose(gold[i]) || (sameShape(tjLoose(l), tjLoose(gold[i])) && closeNums(tjLoose(l), tjLoose(gold[i]))))) {
    const textOnly = mine.every((l, i) => l === gold[i] || l.endsWith("] TJ"));
    if (textOnly) return { verdict: "CLOSE" };
  }
  let firstDiff = -1; let close = mine.length === gold.length;
  for (let i = 0; i < Math.max(mine.length, gold.length); i++) {
    const a = mine[i] ?? ""; const b = gold[i] ?? "";
    if (a === b) continue;
    if (firstDiff < 0 && !(sameShape(a, b) && closeNums(a, b))) firstDiff = i;
    if (!(sameShape(a, b) && closeNums(a, b))) close = false;
  }
  if (close) return { verdict: "CLOSE" };
  return { verdict: "DIFFER", at: firstDiff };
}

// ------------------------------------------------------------------------------------------------
// fixtures (inputs from tests/pdf_fixtures.rs)
// ------------------------------------------------------------------------------------------------

function checkerRgba() {
  const px = [];
  for (let r = 0; r < 8; r++) for (let c = 0; c < 8; c++) px.push(...(((r >> 1) + (c >> 1)) % 2 === 0 ? [220, 60, 60, 255] : [60, 60, 220, 255]));
  return new Uint8Array(px);
}
function crcTable() { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; }
const CRC = crcTable();
function crc32(buf) { let c = 0xffffffff; for (const b of buf) c = CRC[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
/** RGBA pixels as a PNG (filter 0, zlib). */
function png(rgba, w, h) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 4 + 1)] = 0; Buffer.from(rgba.subarray(y * w * 4, (y + 1) * w * 4)).copy(raw, y * (w * 4 + 1) + 1); }
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type, "latin1"), data]); const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td)); return Buffer.concat([len, td, crc]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return new Uint8Array(Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]));
}
/**
 * 16 pixels of alpha `a` and colour `c`. A takumi fixture's `ImageBuffer::from_rgba_bytes` premultiplies straight
 * pixels, which the PDF writer demultiplies again: (192, 192) comes out as colour 193. bm-render gets the fixture's
 * bitmap as a PNG, which krilla embeds as it is, so the PNG holds the colour takumi's bitmap stands for.
 */
const rgbaOver = (a, c) => Uint8Array.from({ length: 64 }, (_, i) => (i % 4 === 3 ? a : c));
const timg = (f) => new Uint8Array(readFileSync(path.join(ref, "takumi-pdf", "tests", "images", f)));
const cells = (f, list) => list.map(f).join("\n");

const ARCHIVO = "assets/fonts/archivo/Archivo-VariableFont_wdth,wght.ttf";
const NOTO_TC = "assets/fonts/noto-sans/NotoSansTC-VariableFont_wght.woff2";
const TWEMOJI = "assets/fonts/twemoji/TwemojiMozilla-colr.woff2";
const DEFAULT_FONTS = [ARCHIVO, NOTO_TC];
/** pdf_fixtures.rs `text(content, size)` / `column(children)` / `wrapping_rows(count)`. */
const jtext = (text, size) => ({ type: "text", text, style: { color: "rgb(20, 20, 20)", fontSize: size } });
const jcolumn = (children) => ({ type: "container", style: { display: "flex", flexDirection: "column", width: "100%" }, children });
const wrappingRows = (n) => jcolumn(Array.from({ length: n }, (_, k) => jtext(`Paragraph ${k + 1}: text long enough to wrap onto several lines when the page gets narrow, exercising line breaking against the page width`, 13)));

const FIXTURES = [
  { name: "box-chrome", vp: [400, 200], html: `<div style="display: flex; width: 100%; height: 100%; padding: 24px; background-color: #ebf0fa;">
      <div style="display: flex; width: 300px; height: 120px; padding: 16px; background-color: #ffffff; border: 3px solid #b42828; border-radius: 16px; opacity: 0.8; font-size: 20px; color: #14143c;">Chrome card</div>
    </div>` },
  { name: "gradients", vp: [440, 160], html: `<div style="display: flex; width: 100%; height: 100%; padding: 20px; column-gap: 20px; background-color: #ffffff;">
      <div style="width: 110px; height: 110px; background-image: linear-gradient(135deg, #ff5f6d, #3a1c71);"></div>
      <div style="width: 110px; height: 110px; background-image: radial-gradient(circle, #fddb92, #4481eb);"></div>
      <div style="width: 110px; height: 110px; background-image: conic-gradient(from 0deg, red, yellow, lime, cyan, blue, magenta, red);"></div>
    </div>` },
  { name: "repeating-gradients", vp: [440, 160], html: `<div style="display: flex; width: 100%; height: 100%; padding: 20px; column-gap: 20px; background-color: #ffffff;">
      <div style="width: 110px; height: 110px; background-image: repeating-linear-gradient(45deg, #0f172a 0px, #0f172a 8px, #f8fafc 8px, #f8fafc 16px);"></div>
      <div style="width: 110px; height: 110px; background-image: repeating-radial-gradient(circle, #7c3aed 0px, #7c3aed 10px, #ede9fe 10px, #ede9fe 20px);"></div>
      <div style="width: 110px; height: 110px; background-image: linear-gradient(180deg, rgba(255, 0, 0, 0.5), rgba(255, 0, 0, 0)), conic-gradient(from 45deg, #fbbf24, #10b981, #fbbf24);"></div>
    </div>` },
  { name: "box-shadows", vp: [450, 150], html: `<div style="display: flex; width: 100%; height: 100%; padding: 8px; background-color: #f4f4f5;">
        ${cells((s) => `<div style="width: 90px; height: 90px; margin: 20px; border-radius: 12px; background-color: #ffffff; box-shadow: ${s};"></div>`, ["6px 6px 0 0 #111827", "0 8px 16px rgba(17, 24, 39, 0.45)", "inset 0 0 0 8px #111827", "inset 0 0 0 6px rgba(17, 24, 39, 0.4); border: 10px solid transparent"])}
      </div>` },
  { name: "blend-opacity", vp: [320, 160], html: `<div style="display: flex; width: 100%; height: 100%; padding: 20px; background-color: #ffffff;">
      <div style="display: flex; isolation: isolate; opacity: 0.9;">
        <div style="width: 110px; height: 110px; border-radius: 50%; background-color: #ef4444; mix-blend-mode: multiply;"></div>
        <div style="width: 110px; height: 110px; border-radius: 50%; margin-left: -40px; background-color: #3b82f6; mix-blend-mode: multiply;"></div>
        <div style="width: 110px; height: 110px; border-radius: 50%; margin-left: -40px; background-color: #22c55e; mix-blend-mode: screen; opacity: 0.6;"></div>
      </div>
    </div>` },
  { name: "overflow-clip", vp: [360, 150], html: `<div style="display: flex; width: 100%; height: 100%; padding: 16px; column-gap: 24px; background-color: #ffffff;">
      <div style="overflow: hidden; border-radius: 24px; width: 140px; height: 110px; border: 2px solid #333333;">
        <div style="width: 300px; height: 300px; background-image: linear-gradient(45deg, #f97316, #0ea5e9);"></div>
      </div>
      <div style="overflow-x: clip; width: 120px; height: 110px; border: 2px solid #999999;">
        <div style="width: 300px; height: 80px; background-color: #a3e635;"></div>
      </div>
    </div>` },
  { name: "transformed-overflow-clip", vp: [240, 240], html: `<div style="display: block; width: 100%; height: 100%; background-color: #ffffff;">
      <div style="width: 100px; height: 100px; transform: scale(2); transform-origin: 0 0; overflow: hidden; background-color: #e2e8f0;">
        <div style="width: 10px; height: 10px; background-color: #ff0000;"></div>
      </div>
    </div>` },
  { name: "clip-path-shapes", vp: [800, 150], html: `<div style="display: flex; width: 100%; height: 100%; padding: 16px; column-gap: 16px; background-color: #ffffff;">
        ${cells((c) => `<div style="width: 110px; height: 110px; background-image: linear-gradient(135deg, #ff5f6d, #3a1c71); border: 4px solid #111827; clip-path: ${c};"></div>`, ["inset(10px 12px round 16px)", "ellipse(45px 30px at 55px 55px)", "polygon(50% 0%, 100% 100%, 0% 100%)", "path('M 10 10 H 100 V 100 H 10 Z')", "inset(50% 0)", "polygon(evenodd, 55px 5px, 105px 105px, 5px 105px, 105px 40px, 5px 40px); clip-rule: nonzero"])}
      </div>` },
  { name: "mask-image", vp: [550, 110], html: `<div style="display: flex; width: 100%; height: 100%; padding: 12px; column-gap: 12px; background-color: #ffffff;">
      <div style="width: 120px; height: 80px; background-color: #1d4ed8; mask-image: linear-gradient(to right, rgba(0,0,0,1), rgba(0,0,0,0));"></div>
      <div style="width: 120px; height: 80px; background-image: linear-gradient(135deg, #ff5f6d, #3a1c71); mask-image: radial-gradient(circle, rgba(0,0,0,1), rgba(0,0,0,0));"></div>
      <div style="width: 120px; height: 80px; background-color: #047857; mask-image: radial-gradient(circle, rgba(0,0,0,1), rgba(0,0,0,0)); mask-size: 30px 20px; mask-repeat: repeat;"></div>
      <div style="width: 120px; height: 80px; background-color: #b91c1c; filter: opacity(0.5); mask-image: linear-gradient(to bottom, rgba(0,0,0,1), rgba(0,0,0,0));"></div>
    </div>` },
  { name: "color-filters", vp: [520, 100], html: `<div style="display: flex; width: 100%; height: 100%; padding: 10px; column-gap: 10px; background-color: #ffffff;">
        ${cells((f) => `<div style="width: 70px; height: 70px; background-color: #e11d48; filter: ${f};"></div>`, ["none", "grayscale(1)", "sepia(1)", "invert(1)", "hue-rotate(180deg)", "hue-rotate(90deg)"])}<div style="width: 70px; height: 70px; background-color: #ffffff; box-shadow: 4px 4px 0 0 #e11d48; filter: grayscale(1);"></div>
      </div>` },
  { name: "outlines", vp: [420, 150], html: `<div style="display: flex; width: 100%; height: 100%; padding: 8px; background-color: #ffffff;">
        ${cells((s) => `<div style="width: 90px; height: 90px; margin: 24px; background-color: #e0e7ff; border-radius: 10px; ${s}"></div>`, ["outline: 4px solid #4338ca;", "outline: 4px solid #4338ca; outline-offset: 6px;", "outline: 3px dashed #b91c1c; outline-offset: -12px;"])}
      </div>` },
  { name: "background-boxes", vp: [600, 130], html: `<div style="display: flex; width: 100%; height: 100%; padding: 10px; column-gap: 10px; background-color: #ffffff;">
        ${cells((s) => `<div style="width: 100px; height: 100px; padding: 14px; border: 8px solid rgba(17, 24, 39, 0.35); background-color: #fef3c7; background-image: linear-gradient(135deg, #ff5f6d, #3a1c71); background-size: 40px 40px; background-repeat: no-repeat; ${s}"></div>`, ["background-origin: border-box;", "background-origin: content-box;", "background-clip: content-box;", "background-clip: border-area;", "background-blend-mode: multiply;"])}
      </div>` },
  { name: "background-placement", vp: [720, 160], html: `<div style="display: flex; width: 100%; height: 100%; padding: 16px; column-gap: 16px; background-color: #ffffff;">
        ${cells((s) => `<div style="width: 120px; height: 120px; background-color: #f4f4f5; background-image: linear-gradient(135deg, #ff5f6d, #3a1c71); background-size: 50px 35px; ${s}"></div>`, ["background-repeat: no-repeat; background-position: right bottom;", "background-repeat: repeat; background-size: 120px 120px; background-position: 20px 0;", "background-repeat: repeat;", "background-repeat: space;", "background-repeat: round; background-position: center;"])}
      </div>` },
  { name: "url-layers", vp: [460, 120], images: () => [{ src: "checker", data: png(checkerRgba(), 8, 8) }], html: `<div style="display: flex; width: 100%; height: 100%; padding: 12px; column-gap: 12px; background-color: #ffffff;">
        ${cells((s) => `<div style="width: 96px; height: 96px; background-color: #f4f4f5; ${s}"></div>`, ["background-image: url(checker); background-repeat: no-repeat;", "background-image: url(checker); background-size: 24px 24px;", "background-image: url(checker); background-size: cover;", "background-color: #1d4ed8; mask-image: url(checker); mask-size: 48px 48px; mask-repeat: repeat;"])}
      </div>` },
  { name: "edge-degenerate", vp: [300, 260], html: `<div style="display: flex; flex-direction: column; width: 100%; height: 100%; padding: 12px; row-gap: 6px; background-color: #ffffff;">
      <div style="width: 0px; height: 40px; background-color: #ef4444;"></div>
      <div style="width: 120px; height: 0px; background-color: #22c55e;"></div>
      <div style="font-size: 14px;"> </div>
      <div style="font-size: 0px;">Zero font size</div>
      <div style="opacity: 0; font-size: 14px;">Fully transparent text</div>
      <div style="width: 80px; height: 20px; background-color: rgba(0, 0, 0, 0); border: 2px solid rgba(255, 0, 0, 0);"></div>
      <div style="width: 1px; height: 1px; background-color: #3b82f6;"></div>
      <div style="width: 40px; height: 40px; border-radius: 50%; border: 1px solid #111111; background-color: #d4d4d8;"></div>
      <div style="font-size: 13px; color: #111111;">Visible sentinel after the degenerates</div>
    </div>` },
  { name: "image-object-fit", vp: [460, 90], node: () => ({ type: "container", style: { display: "flex", width: "100%", height: "100%", paddingTop: 16 },
      children: ["fill", "contain", "cover", "scale-down", "none"].map((fit) => ({ type: "image", src: { data: checkerRgba(), width: 8, height: 8 }, width: 72, height: 48, style: { objectFit: fit, marginLeft: 12 } })) }) },
  { name: "encoded-bitmaps", vp: [120, 48], images: () => [{ src: "jpeg", data: timg("checker.jpg") }, { src: "webp", data: timg("checker.webp") }], html: `<div style="display: flex; column-gap: 8px; padding: 8px;">
      <img src="jpeg" style="width: 32px; height: 32px;" />
      <img src="webp" style="width: 32px; height: 32px;" />
    </div>` },
  { name: "png-streams", vp: [120, 48], images: () => [{ src: "rgb", data: timg("checker.png") }, { src: "indexed", data: timg("checker-indexed.png") }], html: `<div style="display: flex; column-gap: 8px; padding: 8px;">
      <img src="rgb" style="width: 32px; height: 32px;" />
      <img src="indexed" style="width: 32px; height: 32px;" />
    </div>` },
  { name: "border-mixed-sides", page: { size: { width: 420, height: 170 }, margin: 24 }, html: `<div style="display: flex; gap: 24px">
      <div style="width: 140px; height: 90px; border-width: 8px; border-style: dashed dotted solid double; border-color: #dc2626 #2563eb #16a34a #9333ea"></div>
      <div style="width: 140px; height: 90px; border-width: 10px; border-style: dotted solid dashed groove; border-color: #0f172a #f59e0b #0f172a #64748b; border-radius: 24px"></div>
    </div>` },
  { name: "inline-span-background", vp: [420, 200], html: `<div style="display: flex; flex-direction: column; row-gap: 10px; width: 100%; height: 100%; padding: 12px; background-color: #ffffff; font-size: 18px; color: #141414">
      <p style="margin: 0">Due <span style="background-color: #fee2e2; color: #991b1b; padding: 2px 8px; border-radius: 9999px">August 31</span> at noon.</p>
      <p style="margin: 0; width: 190px">Wraps: <span style="background-color: #dcfce7; padding: 2px 6px; border-radius: 6px">green badge text long enough to wrap</span> done.</p>
    </div>` },
  { name: "inline-span-border", vp: [320, 140], html: `<div style="width: 100%; height: 100%; padding: 12px; background-color: #ffffff; font-size: 18px; line-height: 2; color: #141414">
      Due <span style="border: 2px solid #16a34a">August 31</span> at noon, <span style="border: 2px dashed #e11d48; padding: 0 4px; background-color: #fee2e2">a dashed border long enough to wrap</span> done.
    </div>` },
  { name: "inline-images", page: { size: "a4" }, images: () => [{ src: "wrapped", data: png(new Uint8Array(64).fill(64), 4, 4) }, { src: "inline", data: png(rgbaOver(192, 193), 4, 4) }], html: `<main style="display:flex;flex-direction:column;font-size:14px;color:#141414;">
    <div><img src="wrapped" alt="wrapped in a div" style="width:40px;height:40px;" /></div>
    <div style="display:block">Text before <img src="inline" alt="between words" style="width:20px;height:20px;opacity:0.5;" /> and after.</div>
  </main>` },
  { name: "inline-image-decorations", page: { size: "a4" }, images: () => [{ src: "inline", data: png(new Uint8Array(64).fill(128), 4, 4) }], html: `<div style="display:block;font-size:14px;">Text before <img src="inline" alt="decorated" style="width:20px;height:20px;background-color:#00f;border:2px solid #f00;box-shadow:2px 2px #0f0;" /> and a faded <img src="inline" alt="faded" style="width:20px;height:20px;opacity:0.5;border:2px solid #f00;box-shadow:2px 2px #0f0;" /> after.</div>` },
  { name: "page-background", page: { size: "a4", backgroundColor: "rgb(239, 231, 213)" }, html: `<main>
      <div style="position: fixed; top: 100px; left: 100px; width: 60px; height: 60px; z-index: -1; background: #123456;"></div>
      <p style="height: 900px;">first</p>
      <p style="height: 900px;">second</p>
    </main>` },
  { name: "svg-background-image", vp: [100, 100], html: ((url) => `<div style="width: 80px; height: 40px; background-image: url('${url}'); background-size: 100% 100%;"></div>
      <div style="font-size: 28px; background-image: url('${url}'); background-clip: text; color: transparent;">Clip</div>`)("data:image/svg+xml;base64," + Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
  <circle cx="12" cy="12" r="10" fill="#16a34a"/>
</svg>`).toString("base64")) },
  { name: "collapsed-table", page: { size: { width: 300, height: 320 }, margin: 24 }, html: ((cell) => `<div style="font-size: 12px; color: #141414; display: flex; flex-direction: column; gap: 16px">
        <table style="border-collapse: collapse">
          <thead><tr><th style="${cell}; border-bottom-width: 3px; background: #e2e8f0">Name</th><th style="${cell}; border-bottom-width: 3px; background: #e2e8f0">Qty</th></tr></thead>
          <tbody>
            <tr><td style="${cell}">alpha</td><td style="${cell}">1</td></tr>
            <tr style="border-top: 2px solid #dc2626"><td style="${cell}">beta</td><td style="${cell}">2</td></tr>
          </tbody>
        </table>
        <table style="border-collapse: collapse; border: 4px solid #2563eb">
          <tr><td style="${cell}" colspan="2">spans both columns</td><td style="${cell}" rowspan="2">tall</td></tr>
          <tr><td style="${cell}">left</td><td style="${cell}; border-right-style: hidden">right</td></tr>
        </table>
        <table style="border-collapse: collapse">
          <tr><td style="${cell}; border-bottom: 4px solid #dc2626">thick</td><td style="${cell}">thin</td></tr>
          <tr><td style="${cell}" colspan="2">one winner spans both segments</td></tr>
        </table>
      </div>`)("border: 1px solid #94a3b8; padding: 4px 8px") },
  { name: "text-decorations", vp: [360, 220], html: `<div style="display: flex; flex-direction: column; width: 100%; height: 100%; padding: 16px; row-gap: 8px; background-color: #ffffff; font-size: 18px; color: #111111;">
      <div style="text-decoration-line: underline; text-decoration-color: #dc2626;">Underlined in red</div>
      <div style="text-decoration-line: line-through;">Struck through</div>
      <div style="text-decoration-line: overline underline;">Over and under</div>
      <div style="letter-spacing: 4px;">Wide tracking</div>
      <div style="font-weight: 700;">Bold weight text</div>
    </div>` },
  { name: "text-decoration-styles", vp: [360, 240], html: `<div style="width: 100%; height: 100%; padding: 24px; background-color: #ffffff; font-size: 24px; color: #0f172a; display: flex; flex-direction: column; gap: 12px;">
      <div style="text-decoration: underline double;">double</div>
      <div style="text-decoration: underline dotted;">dotted</div>
      <div style="text-decoration: underline dashed #16a34a 2px;">dashed</div>
      <div style="text-decoration: underline wavy #e11d48;">Typing wavy</div>
    </div>` },
  { name: "svg-vector-image", vp: [120, 60], node: () => ({ type: "container", style: { display: "flex", paddingTop: 8 }, children: [{ type: "image", src: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
  <defs><linearGradient id="g" x1="0" y1="0" x2="24" y2="24" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#ff0044"/><stop offset="1" stop-color="#0044ff"/>
  </linearGradient></defs>
  <circle cx="12" cy="12" r="10" fill="url(#g)"/>
  <path d="M6 12 L11 17 L18 7" stroke="#fff" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`, width: 22, height: 22 }] }) },
  // ---- text (fonts: Archivo + Noto Sans TC unless a fixture names its own, as pdf_fixtures.rs)
  { name: "text-basic", vp: [600, 300], node: () => ({ type: "container", style: { display: "flex", width: "100%", height: "100%", backgroundColor: "rgb(235, 244, 255)" }, children: [jtext("Hello PDF from Takumi", 32)] }) },
  { name: "text-ligatures", vp: [600, 100], node: () => ({ type: "container", style: { display: "flex", width: "100%", height: "100%" }, children: [jtext("Difficult office traffic affix", 24)] }) },
  { name: "text-decoration-shadow", vp: [260, 90], html: `<div style="width: 100%; height: 100%; padding: 16px; background-color: #ffffff; font-size: 32px; color: #111827; text-decoration: underline 3px; text-shadow: 4px 4px 6px rgba(37, 99, 235, 0.8);">Underlined</div>` },
  { name: "text-shadow-stroke", vp: [360, 200], html: `<div style="display: flex; flex-direction: column; row-gap: 8px; width: 100%; height: 100%; padding: 16px; background-color: #ffffff; font-size: 28px; color: #111827;">
      <div style="text-shadow: 3px 3px 0 #f59e0b;">Sharp shadow</div>
      <div style="text-shadow: 2px 2px 4px rgba(17, 24, 39, 0.5);">Blurred shadow</div>
      <div style="-webkit-text-stroke: 1px #b91c1c; color: #fef3c7;">Stroked text</div>
      <div style="-webkit-text-stroke: 2px rgba(185, 28, 28, 0.25); color: #fef3c7;">Faded stroke</div>
      <div>Plain <span style="-webkit-text-stroke: 1px #2563eb;">span stroke</span></div>
      <div style="-webkit-text-stroke: 3px #b91c1c;">Same words</div>
      <div style="-webkit-text-stroke: 9px #b91c1c;">Same words</div>
      <div style="background-image: linear-gradient(90deg, #ff5f6d, #3a1c71); background-clip: text; color: transparent;">Gradient text</div>
      <div style="background-image: linear-gradient(90deg, #ff5f6d, #3a1c71); background-clip: text; color: transparent; -webkit-text-stroke: 6px transparent;">Ringed text</div>
      <div style="background-image: url('data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%228%22 height=%228%22%3E%3Crect width=%228%22 height=%228%22 fill=%22%2316a34a%22/%3E%3C/svg%3E'); background-clip: text; color: transparent;">Image text</div>
    </div>` },
  { name: "color-glyph-text-shadow", vp: [320, 150], fonts: [...DEFAULT_FONTS, TWEMOJI], html: `<div style="display: flex; flex-direction: column; row-gap: 12px; width: 100%; height: 100%; padding: 16px; background-color: #ffffff; font-size: 40px; color: #111827;">
      <div style="text-shadow: 6px 6px 0 #2563eb;">Party 🎉🚀</div>
      <div style="text-shadow: 6px 6px 4px rgba(220, 38, 38, 0.8);">Blur 🎉🚀</div>
    </div>` },
  { name: "bitmap-glyph-text-shadow", vp: [180, 100], fonts: ["assets/fonts/noto-sans/NotoColorEmoji.ttf"], html: `<div style="display: flex; column-gap: 24px; width: 100%; height: 100%; padding: 16px; background-color: #ffffff; font-size: 48px; line-height: 1;">
      <div style="text-shadow: 8px 8px 0 rgba(37, 99, 235, 0.6);">😀</div>
      <div style="text-shadow: 8px 8px 8px rgba(220, 38, 38, 0.8);">😀</div>
    </div>` },
  { name: "text-stroke-paint-order", vp: [420, 280], fonts: [...DEFAULT_FONTS, TWEMOJI], html: `<div style="padding: 16px; background-color: #3070c0; color: white; font-size: 64px; font-weight: 700; letter-spacing: -0.05em; -webkit-text-stroke: 8px black;">
      <div>Stroke 🎉</div>
      <div style="paint-order: stroke fill;">Stroke 🎉</div>
      <div style="paint-order: stroke;"><span>Stroke 🎉</span></div>
    </div>` },
  { name: "cluster-closing-on-a-mark", vp: [240, 48], fonts: ["takumi-pdf/tests/fonts/archivo-combining.subset.ttf"], html: `<p style="font-size:16px;">Świnoujście</p>` },
  { name: "font-weights", page: { size: "a4", lang: "en" }, fonts: [ARCHIVO, NOTO_TC, "assets/fonts/sil/scheherazade-new-v17-arabic-regular.woff2", "assets/fonts/noto-sans/noto-sans-devanagari-v30-devanagari-regular.woff2"], html: ([latin, chinese, arabic, devanagari]) => {
    const weights = [100, 300, 400, 600, 700, 900];
    return `<main style="display:flex;flex-direction:column;font-family:${latin};font-size:16px;color:#141414;">
      <h1 style="font-weight:700;">Font weights</h1>
      ${weights.map((w) => `<p style="font-weight:${w};">Weight ${w} · Variable axis</p>`).join("")}
      <p style="font-style:italic;">Oblique from the same variable face</p>
      ${weights.map((w) => `<p lang="zh-Hant" style="font-family:${chinese};font-weight:${w};">字重 ${w} 的中文字樣</p>`).join("")}
      <p lang="ar" style="font-family:${arabic};font-weight:700;">نص عربي عريض</p>
      <p lang="ar" style="font-family:${arabic};">نص عربي عادي</p>
      <p lang="hi" style="font-family:${devanagari};font-weight:700;">मोटा देवनागरी</p>
      <p lang="hi" style="font-family:${devanagari};font-style:italic;">तिरछा देवनागरी</p>
      <p lang="hi" style="font-family:${devanagari};font-weight:700;background-image:linear-gradient(90deg,#ff5f6d,#3a1c71);background-clip:text;color:transparent;">मोटा देवनागरी</p>
    </main>`;
  } },
  { name: "certificate", vp: [1123, 794], htmlFile: "certificate.html" },
  // ---- paged
  { name: "paged-lines", page: { size: { width: 400, height: 300 }, margin: 24 }, node: () => jcolumn(Array.from({ length: 40 }, (_, k) => jtext(`Line ${k + 1} of the paginated report body`, 16))) },
  { name: "paged-page-ranges", page: { size: { width: 400, height: 300 }, margin: 24, pageRanges: [1, { from: 3, to: 3 }], footer: `<div style="display: flex; column-gap: 3px; font-size: 12px; color: #141414;">Page <span class="pageNumber"></span> of <span class="totalPages"></span></div>` }, node: () => jcolumn(Array.from({ length: 40 }, (_, k) => jtext(`Row ${k + 1}`, 16))) },
  { name: "paged-table", page: { size: { width: 400, height: 300 }, margin: 24 }, html: `<table style="width: 100%; font-size: 12px; color: #141414">
        <tfoot><tr><td colspan="2">Total</td><td>1395</td></tr></tfoot>
        <tbody>${Array.from({ length: 30 }, (_, k) => `<tr><td>Item ${k + 1}</td><td>Description of item ${k + 1}</td><td>${(k + 1) * 3}</td></tr>`).join("")}</tbody>
        <thead><tr style="background: #e2e8f0"><th>Name</th><th>Description</th><th style="width: 48px">Qty</th></tr></thead>
      </table>` },
  { name: "paged-breaks", page: { size: { width: 400, height: 400 }, margin: 24 }, node: () => jcolumn(["Alpha", "Beta"].map((t) => ({ ...jcolumn([1, 2, 3].map((k) => jtext(`${t} row ${k}`, 14))), style: { display: "flex", flexDirection: "column", breakBefore: "page" } }))) },
  { name: "paged-widows-orphans", page: { size: { width: 400, height: 300 }, margin: 20 }, node: () => jcolumn([...Array.from({ length: 12 }, (_, k) => jtext(`Row ${k + 1}`, 16)), { type: "text", text: "The closing paragraph runs long enough to wrap into several lines and straddle the page boundary, which is exactly where the widow and orphan minimums earn their keep in a paginated report.", style: { color: "rgb(20, 20, 20)", fontSize: 16, lineHeight: 1.8 } }]) },
  { name: "paged-narrow", page: { size: { width: 200, height: 420 }, margin: 16 }, node: () => wrappingRows(10) },
  { name: "paged-landscape", page: { size: "letter", landscape: true, margin: 60 }, node: () => wrappingRows(60) },
  { name: "legacy-page-break", page: { size: { width: 300, height: 160 }, margin: 20 }, html: `<div style="font-size: 12px; color: #141414">
        <div style="page-break-after: always">first page</div>
        <div>${Array.from({ length: 8 }, (_, k) => `<p style="margin: 0">line ${k + 1}</p>`).join("")}</div>
        <div style="page-break-inside: avoid; background: #e2e8f0; padding: 8px">
          <p style="margin: 0">kept together</p>
          <p style="margin: 0">across the break</p>
          <p style="margin: 0">by page-break-inside</p>
        </div>
      </div>` },
  { name: "text-shadow-page-cut", page: { size: { width: 400, height: 300 }, margin: 24 }, html: `<div style="font-size:16px;line-height:20px;">
    <div style="height:225px"></div>
    <div style="color:#00f;text-shadow:0 20px 0 #0f0;">shadowed</div>
    <div style="color:#f00;">next page</div>
  </div>` },
  { name: "fixed-repeats-per-page", page: { size: "a4" }, html: `<main>
      <div style="position: fixed; inset: 0; display: flex; align-items: center; justify-content: center;">
        <span style="font-size: 48px;">DRAFT</span>
      </div>
      <div style="position: fixed; top: 20px; left: 30px; width: 40px; height: 40px; background: #000;"></div>
      <a href="https://takumi.kane.tw" style="position: fixed; bottom: 10px; left: 10px;">source</a>
      <div style="position: fixed; top: 200px; left: 200px; width: 50px; height: 50px; z-index: -1; background: #eee;"></div>
      <p style="height: 900px;">first</p>
      <p style="height: 900px;">second</p>
    </main>` },
  { name: "invoice", page: { size: "a4", margin: { top: 36, right: 36, bottom: "auto", left: 36 }, footerFile: "invoice-footer.html" }, htmlFile: "invoice.html" },
  { name: "report-links-outline", page: { size: "a4", outline: true, metadata: { title: "Annual report", description: "Fixture exercising metadata, links, and outline", authors: ["Takumi"], keywords: ["report", "fixture"], creator: "takumi-pdf fixtures" } }, htmlFile: "report.html" },
  // ---- bands and page counters (pdf_fixtures.rs)
  { name: "paged-footer", page: { size: { width: 400, height: 300 }, margin: 24, footer: `<div style="display: flex; column-gap: 3px; font-size: 12px; color: #141414;">
            Page <span class="pageNumber"></span> of <span class="totalPages"></span>,
            page <span class="pageNumber muted trad-chinese-informal"></span> in Chinese,
            <span class="pageNumber lower-roman"></span> in roman
          </div>` }, node: () => jcolumn(Array.from({ length: 40 }, (_, k) => jtext(`Row ${k + 1}`, 16))) },
  { name: "paged-band-remeasure", page: { size: { width: 320, height: 240 }, footer: `<div style="width: 90px; font-size: 14px;">Page <span class="pageNumber"></span> of <span class="totalPages"></span></div>` }, node: () => jcolumn(Array.from({ length: 12 }, (_, k) => jtext(`Row ${k + 1}`, 16))) },
  ...((band) => [{ name: "paged-header-footer", page: { size: { width: 400, height: 320 }, margin: 24, header: band("Quarterly report"), footer: band("Confidential") }, html: `<div style="display: flex; flex-direction: column; width: 100%; row-gap: 4px;">
        <div style="font-size: 14px; break-after: page;">Section one ends here</div>
        <div style="display: flex; flex-direction: column; row-gap: 4px; break-inside: avoid; background-color: #f5f5f4;">
          ${Array.from({ length: 30 }, (_, k) => `<div style="font-size: 12px;">Overflowing row ${k + 1}</div>`).join("")}
        </div>
        <div style="font-size: 14px;">Trailing content</div>
      </div>` }])((label) => `<div style="display: flex; width: 100%; justify-content: space-between; font-size: 11px; color: #57534e; padding: 6px 0;">
            <div>${label}</div>
            <div style="display: flex; column-gap: 3px">Page <span class="pageNumber"></span> of <span class="totalPages"></span></div>
          </div>`),
  ...((band) => [{ name: "auto-margin-bands", page: { size: { width: 400, height: 320 }, header: band("Header", 3), footer: band("Footer", 2) }, html: `<div style="display: flex; flex-direction: column; width: 100%; row-gap: 4px;">${Array.from({ length: 24 }, (_, k) => `<div style="font-size: 12px;">Row ${k + 1}</div>`).join("")}</div>` }])((label, lines) => `<div style="display: flex; flex-direction: column; width: 100%; row-gap: 2px; padding: 6px 12px; background-color: #f5f5f4;">
            ${Array.from({ length: lines }, (_, k) => `<div style="font-size: 11px;">${label} line ${k + 1}</div>`).join("")}
            <div style="display: flex; column-gap: 3px; font-size: 11px;">Page <span class="pageNumber"></span> of <span class="totalPages"></span></div>
          </div>`),
  { name: "page-rules", page: { size: { width: 300, height: 200 }, header: jtext("Running header", 10), footer: jtext("Page footer", 10), pages: { first: { header: false }, last: { footer: jcolumn([jtext("Thank you for your business.", 12), jtext("Terms: net 30.", 12)]) } } },
    html: `<div style="font-size: 12px; color: #141414">${Array.from({ length: 40 }, (_, k) => `<p style="margin: 0">line ${k + 1}</p>`).join("")}</div>` },
  { name: "paged-target-counters", page: { size: { width: 320, height: 240 }, margin: 24 }, html: ((cells) => {
    const entry = (id, title, cell) => `<a href="#${id}" style="display: flex; column-gap: 4px;"><span>${title}</span>${cell}</a>`;
    const section = (id, title) => `<div id="${id}" style="display: flex; flex-direction: column; break-before: page; font-size: 18px;">${title}</div>`;
    return `<div style="display: flex; flex-direction: column; width: 100%; font-size: 14px; color: #141414;">
      <div style="display: flex; flex-direction: column;">${entry("alpha", "Alpha", cells[0])}${entry("beta", "Beta", cells[1])}${entry("gamma", "Gamma", cells[2])}</div>
      ${section("alpha", "Alpha")}${section("beta", "Beta")}${section("gamma", "Gamma")}
    </div>`;
  })([`<span class="targetPageNumber"></span>`, `<span class="targetPageNumber"></span>`, `<span class="targetPageNumber upper-roman"></span>`]) },
  { name: "content-page-counters", page: { size: "a4" }, html: `<main>
        <p style="height: 1100px;"></p>
        <p style="font-size: 12px;">page <span class="pageNumber"></span> of <span class="totalPages"></span></p>
      </main>` },
  { name: "fixed-page-counters", page: { size: "a4" }, html: `<main>
      <div style="position: fixed; bottom: 10px; left: 10px; display: flex; column-gap: 4px; font-size: 12px;">
        <span class="pageNumber"></span><span class="totalPages"></span>
      </div>
      <p style="height: 900px;"></p>
      <p style="height: 900px;"></p>
    </main>` },
  ...((section, doc) => [
    { name: "stream-total-pages-band", page: { size: { width: 320, height: 240 }, margin: { top: "auto", right: 24, bottom: 24, left: 24 }, header: `<div style="font-size: 30px;">Page <span class="pageNumber"></span> of <span class="totalPages"></span></div>` },
      html: doc(`<div class="fixed-count" style="position: fixed; right: 4px; bottom: 4px; font-size: 10px;">of <span class="totalPages"></span></div>`, [["a", "Alpha", 6], ["b", "Beta", 6], ["c", "Gamma", 6]], "") },
    { name: "stream-content-counters", page: { size: { width: 320, height: 240 }, margin: 24 },
      html: doc(`<a href="#c" style="display: flex; column-gap: 4px;">Chapter <span class="targetPageNumber"></span></a>
      <div>This report has <span class="totalPages"></span> pages, and this is page <span class="pageNumber"></span>.</div>`, [["a", "Alpha", 5], ["b", "Beta", 5], ["c", "Gamma", 5]], `<div>End of page <span class="pageNumber"></span> of <span class="totalPages"></span></div>`) },
    { name: "stream-page-ranges-middle", page: { size: { width: 320, height: 240 }, margin: 24, outline: true, pageRanges: [1, 3, 5] },
      html: doc(`<h1 id="top" style="font-size: 22px; margin: 0;">Report</h1>`, [["b", "Beta", 4], ["c", "Gamma", 4], ["d", "Delta", 4], ["e", "Epsilon", 4]], "") },
  ])((id, title, lines) => `<div id="${id}" style="display: flex; flex-direction: column; break-before: page;"><h2 style="font-size: 18px; margin: 0;">${title}</h2>${Array.from({ length: lines }, (_, k) => `<div>${title}, line ${k + 1}</div>`).join("")}</div>`,
    (head, sections, tail) => `<div style="display: flex; flex-direction: column; width: 100%; font-size: 14px; color: #141414;">${head}${sections.map(([i, t, n]) => `<div id="${i}" style="display: flex; flex-direction: column; break-before: page;"><h2 style="font-size: 18px; margin: 0;">${t}</h2>${Array.from({ length: n }, (_, k) => `<div>${t}, line ${k + 1}</div>`).join("")}</div>`).join("")}${tail}</div>`),
  // `@page` rules and named pages (takumi page_kinds.rs): not supported by bm-render (pages keep the size / margin options)
  { name: "at-page-first-left-right", page: { size: "a4", css: `
    @page { size: A5; margin: 10mm }
    @page :first { size: A5 landscape; margin-top: 20mm }
    @page :left { margin-left: 25mm }
    @page :right { margin-right: 25mm }
    p { margin: 0 0 6px; font-size: 11px; line-height: 15px }
    .rule { position: fixed; top: 0; left: 0; right: 0; height: 2px; background: #2f6fde }
  `, footer: `<div style="text-align: center; font-size: 10px; color: #141414; border-top: 1px solid #b4b4b4">
            Page <span class="pageNumber"></span> of <span class="totalPages"></span>
          </div>` }, html: `<div class="rule"></div>` + Array.from({ length: 75 }, (_, k) => `<p>Paragraph ${k + 1} runs long enough to wrap, so the width of each page decides where its lines break.</p>`).join("") },
  { name: "at-page-root-element", page: { size: "a4", css: `
    html { direction: rtl; font-size: 20px; --inner: 3em }
    @page { size: A5; margin: 1em }
    @page :left { margin-left: var(--inner) }
    @page :right { margin-right: var(--inner) }
    p { margin: 0 0 6px; font-size: 11px; line-height: 15px }
  ` }, html: `<html><body>${Array.from({ length: 90 }, (_, k) => `<p>Paragraph ${k + 1} wraps across the width each page leaves it.</p>`).join("")}</body></html>` },
  // named pages of different widths: not supported by bm-render (page_rules.zig), kept to track the gap
  { name: "named-pages", page: { size: "a4", css: `
    @page { size: A5; margin: 15mm }
    @page cover { margin: 40mm 20mm }
    @page wide { size: A5 landscape; margin: 10mm }
    .cover { page: cover; font-size: 28px; font-weight: 700 }
    .wide { page: wide }
    p { margin: 0 0 6px; font-size: 11px; line-height: 15px }
    table { width: 100%; border-collapse: collapse; font-size: 10px }
    td { border: 1px solid #b4b4b4; padding: 2px 4px }
  `, footer: `<div style="text-align: center; font-size: 10px; color: #141414">
            Page <span class="pageNumber"></span> of <span class="totalPages"></span>
          </div>` }, html: `<div class="cover">Named pages</div>${Array.from({ length: 6 }, (_, k) => `<p>Paragraph ${k + 1} sits on the body pages, between the cover and the wide table.</p>`).join("")}<div class="wide"><table>${Array.from({ length: 12 }, (_, r) => `<tr>${Array.from({ length: 8 }, (_, c) => `<td>Row ${r + 1}, column ${c + 1}</td>`).join("")}</tr>`).join("")}</table></div>${Array.from({ length: 6 }, (_, k) => `<p>Paragraph ${k + 7} sits on the body pages, between the cover and the wide table.</p>`).join("")}` },
];

// ------------------------------------------------------------------------------------------------
// run
// ------------------------------------------------------------------------------------------------

const pdfMod = await import(pathToFileURL(path.join(root, "js", "node-pdf.mjs")).href);
/** One renderer per font set (fixtures register different fonts, as pdf_fixtures.rs). */
const renderers = new Map();
function rendererFor(fonts) {
  const key = fonts.join("|");
  if (!renderers.has(key)) {
    const r = new pdfMod.PdfRenderer();
    const families = [];
    for (const f of fonts) {
      const reg = r.registerFont(new Uint8Array(readFileSync(path.join(ref, f))));
      families.push(reg && reg[0] ? reg[0].name : "");
    }
    renderers.set(key, { r, families });
  }
  return renderers.get(key);
}
const outDir = path.join(root, "bench", "out", "pdf-compare");
mkdirSync(outDir, { recursive: true });
const fixtureFile = (f) => readFileSync(path.join(ref, "takumi-pdf", "fixtures", f), "utf8");

const counts = { IDENTICAL: 0, CLOSE: 0, DIFFER: 0, ERROR: 0, OBJ: 0, FONTS: 0, TEXT: 0 };
// [interchange] links, outline, Info, XMP, /ID, attachments, catalog (scripts/pdf-interchange.mjs)
FIXTURES.push(...INTERCHANGE_FIXTURES);
FIXTURES.push(...taggingFixtures({ png })); // [tagging] PDF/A, PDF/UA, structure fixtures
FIXTURES.push(...moreFixtures({ jtext, jcolumn })); // [more]
const names = new Set(FIXTURES.map((f) => f.name));
if (names.size !== FIXTURES.length) throw new Error("Duplicate Takumi fixture names");
for (const name of only) if (!names.has(name)) throw new Error(`Unknown Takumi fixture: ${name}`);
const uncovered = readdirSync(goldenDir).filter((f) => f.endsWith(".pdf") && !names.has(f.slice(0, -4)));
const missing = FIXTURES.filter((f) => (!only.length || only.includes(f.name)) && !existsSync(path.join(goldenDir, f.name + ".pdf"))).map((f) => f.name);
if (uncovered.length) console.error(`UNCOVERED Takumi goldens: ${uncovered.join(", ")}`);
if (missing.length) console.error(`MISSING Takumi goldens: ${missing.join(", ")}`);
const ixCounts = {};
const rows = [];
for (const fx of FIXTURES) {
  if (only.length && !only.includes(fx.name)) continue;
  const goldPath = path.join(goldenDir, fx.name + ".pdf");
  if (!existsSync(goldPath)) { console.log(`SKIP   ${fx.name}: no golden`); continue; }
  const { r, families } = rendererFor(fx.fonts || DEFAULT_FONTS);
  const opts = fx.page ? { ...fx.page } : { viewport: { width: fx.vp[0], height: fx.vp[1] } };
  if (opts.footerFile) { opts.footer = fixtureFile(opts.footerFile); delete opts.footerFile; }
  if (fx.images) opts.images = fx.images();
  const source = fx.node ? fx.node() : fx.htmlFile ? fixtureFile(fx.htmlFile) : typeof fx.html === "function" ? fx.html(families) : fx.html;
  let bytes;
  try { bytes = await r.render(source, opts); }
  catch (e) { counts.ERROR++; rows.push({ name: fx.name, verdict: "ERROR", error: e.message }); console.log(`ERROR  ${fx.name}: ${e.message}`); continue; }
  writeFileSync(path.join(outDir, fx.name + ".pdf"), bytes);
  const minePdf = parsePdf(Buffer.from(bytes));
  const goldPdf = parsePdf(readFileSync(goldPath));
  const mineAll = flattenAll(minePdf);
  const goldAll = flattenAll(goldPdf);
  // the pages one after the other, each behind a marker with its MediaBox
  const join = (all) => all.pages.flatMap((pg, k) => [`--- page ${k + 1} ${fmt(pg.mediaBox)}`, ...pg.ops]);
  const mine = join(mineAll);
  const gold = join(goldAll);
  const lm = objectLayout(minePdf).join(" "); const lg = objectLayout(goldPdf).join(" ");
  const objs = lm === lg ? "objects same" : "objects differ";
  if (lm === lg) counts.OBJ++;
  let res = compare(mine, gold);
  if (res.verdict === "DIFFER" && fx.name === "color-glyph-text-shadow") {
    const { fixtureEquivalence } = await import('./pdf-fixture-equivalence.mjs');
    const equivalence = await fixtureEquivalence(fx.name, bytes, readFileSync(goldPath), mine, gold, compare);
    if (equivalence) res = { verdict: "CLOSE", equivalence };
  }
  const fm = fontParts(minePdf, mineAll.fontIds); const fg = fontParts(goldPdf, goldAll.fontIds);
  const fonts = compareFonts(fm, fg);
  if (fonts.same) counts.FONTS++;
  if (gold.some((l) => /T[Jj]$/.test(l))) counts.TEXT++;
  const pc = minePdf.pages.length === goldPdf.pages.length ? "" : `  PAGES ${minePdf.pages.length} vs ${goldPdf.pages.length}`;
  counts[res.verdict]++;
  const row = { name: fx.name, ...res, mine: mine.length, gold: gold.length, objects: lm === lg, fonts: fonts.same, fontParts: fonts.same ? [] : String(fonts.what).split(/\s+/),
    inputFonts: (fx.fonts || DEFAULT_FONTS).map((file) => ({ file, sha256: sha256(readFileSync(path.join(ref, file))) })),
    goldenSha256: sha256(readFileSync(goldPath)), pages: { bm: minePdf.pages.length, takumi: goldPdf.pages.length } };
  rows.push(row);
  console.log(`${res.verdict.padEnd(9)} ${fx.name.padEnd(28)} ops ${String(mine.length).padStart(5)} / ${String(gold.length).padStart(5)}  ${objs}; fonts ${fonts.same ? "same" : "differ (" + fonts.what + ")"}${pc}`);
  if (res.equivalence) console.log(`          equivalence: ${res.equivalence.kind}; extraction matches; ${res.equivalence.evidence.filter(e => e.changedPixels === 0).length}/${res.equivalence.evidence.length} raster checks identical, remaining check within the documented fixture bound`);
  { // [interchange]
    const im = interchangeParts(minePdf, { Name, Ref }); const ig = interchangeParts(goldPdf, { Name, Ref });
    const ix = compareInterchange(im, ig);
    row.interchange = ix;
    for (const [k, v] of Object.entries(ix)) { ixCounts[k] = ixCounts[k] || { same: 0, close: 0, differ: 0 }; ixCounts[k][v]++; }
    const bad = Object.entries(ix).filter(([, v]) => v !== "same");
    console.log(`          interchange: ${bad.length ? bad.map(([k, v]) => k + " " + v).join(", ") : "same"}`);
    if (bad.length && (verbose || only.length)) for (const [k] of bad) printInterchange(k, im, ig);
  }
  if (lm !== lg && (verbose || only.length)) { console.log("   bm:     " + lm); console.log("   takumi: " + lg); }
  if (res.verdict === "DIFFER" && (verbose || only.length)) {
    const i = res.at;
    for (let k = Math.max(0, i - 2); k < Math.min(Math.max(mine.length, gold.length), i + 4); k++) {
      console.log(`   ${k === i ? ">" : " "} bm:     ${(mine[k] ?? "<end>").slice(0, 220)}`);
      console.log(`   ${k === i ? ">" : " "} takumi: ${(gold[k] ?? "<end>").slice(0, 220)}`);
    }
  }
  if (!fonts.same && (verbose || only.length)) {
    for (let k = 0; k < Math.max(fm.length, fg.length); k++) for (const part of ["dict", "cmap", "program", "procs"]) {
      const a = fm[k] ? fm[k][part] : "<none>"; const b = fg[k] ? fg[k][part] : "<none>";
      if (a !== b) { console.log(`   f${k}.${part} bm:     ${a.slice(0, 400)}`); console.log(`   f${k}.${part} takumi: ${b.slice(0, 400)}`); }
    }
  }
  if (dumpName === fx.name) {
    writeFileSync(path.join(outDir, fx.name + ".bm.txt"), mine.join("\n"));
    writeFileSync(path.join(outDir, fx.name + ".takumi.txt"), gold.join("\n"));
    writeFileSync(path.join(outDir, fx.name + ".fonts.bm.txt"), fm.map((f, k) => `f${k}\n` + Object.entries(f).map(([a, b]) => `  ${a}: ${b}`).join("\n")).join("\n"));
    writeFileSync(path.join(outDir, fx.name + ".fonts.takumi.txt"), fg.map((f, k) => `f${k}\n` + Object.entries(f).map(([a, b]) => `  ${a}: ${b}`).join("\n")).join("\n"));
    console.log(`   dumped to ${path.relative(root, outDir)}/${fx.name}.{bm,takumi,fonts.bm,fonts.takumi}.txt`);
  }
}
console.log(`\n${rows.length} compared (${counts.TEXT} with text): ${counts.IDENTICAL} identical, ${counts.CLOSE} close (numeric tolerance or verified fixture equivalence), ${counts.DIFFER} differ, ${counts.ERROR} errors; object layout identical in ${counts.OBJ}; fonts identical in ${counts.FONTS}`);
console.log(`interchange (same / close / differ): ${Object.entries(ixCounts).map(([k, c]) => `${k} ${c.same}/${c.close}/${c.differ}`).join(", ")}`); // [interchange]
writeFileSync(path.join(outDir, "results.json"), JSON.stringify({ backend: pdfMod.backend, reference: provenance, node: process.version,
  wasmSha256: pdfMod.backend === "wasm" ? sha256(readFileSync(path.join(root, "js", "bm_render.pdf.wasm"))) : null,
  counts, uncovered, missing, interchange: ixCounts, rows }, null, 2) + "\n");
// [gate] every fixture difference must be listed, by fixture and part, in scripts/pdf-audit/exceptions.json
// ("golden"): page content CLOSE / DIFFER, an interchange part close / differ, font dictionaries / CMaps /
// Type3 procedures (font program bytes are informational: another subsetter). An unlisted difference, or a listed
// one a fixture that ran no longer shows (stale), fails --strict. No tolerance applies to unlisted fixtures beyond
// the comparison's own float noise (0.01 absolute / 1e-4 relative, reported as CLOSE and therefore listed too).
const goldenList = JSON.parse(readFileSync(process.env.PDF_AUDIT_EXCEPTIONS || path.join(root, "scripts", "pdf-audit", "exceptions.json"), "utf8")).golden || [];
for (const [i, e] of goldenList.entries()) if (!e.fixture || !e.part || !e.verdict || !["deliberate", "open", "noise"].includes(e.status) || !(e.reason?.length >= 40)) throw new Error(`exceptions.json golden ${i}: fixture, part, verdict, status (deliberate | open | noise) and a reason are required`);
const observed = [];
for (const row of rows) {
  if (row.verdict === "CLOSE" || row.verdict === "DIFFER") observed.push({ fixture: row.name, part: "content", verdict: row.verdict });
  for (const [k, v] of Object.entries(row.interchange || {})) if (v !== "same") observed.push({ fixture: row.name, part: k, verdict: v.toUpperCase() });
  if (row.fontParts && row.fontParts.some((w) => !/\.program$/.test(w))) observed.push({ fixture: row.name, part: "fonts", verdict: "DIFFER" });
}
const listedKey = (e) => `${e.fixture} ${e.part} ${String(e.verdict).toUpperCase()}`;
const listed = new Set(goldenList.map(listedKey));
const unexpectedGolden = observed.filter((o) => !listed.has(listedKey(o)));
const ran = new Set(rows.map((r) => r.name));
const seen = new Set(observed.map(listedKey));
const staleGolden = goldenList.filter((e) => ran.has(e.fixture) && !seen.has(listedKey(e)));
for (const o of unexpectedGolden) console.log(`UNLISTED  ${o.fixture} ${o.part} ${o.verdict} (not in scripts/pdf-audit/exceptions.json "golden")`);
for (const e of staleGolden) console.log(`STALE     ${e.fixture} ${e.part} ${e.verdict}: listed in exceptions.json, no longer observed`);
console.log(`gate: ${observed.length} differences, ${observed.length - unexpectedGolden.length} listed, ${unexpectedGolden.length} unlisted, ${staleGolden.length} stale`);
if (counts.ERROR || missing.length || uncovered.length || (argv.includes("--strict") && (unexpectedGolden.length || staleGolden.length))) process.exitCode = 1;
