// Font embedding: font dictionaries, subsets, widths, ToUnicode, Type3 (colour / bitmap glyphs), formats (TTF, CFF, CFF2,
// variable, WOFF, WOFF2, TTC), uncovered text. Font PROGRAM bytes are compared by shape (tables, glyph count), the
// dictionaries / CMaps / widths exactly (subset tags replaced unless the probe is about the tag).
import { readFileSync } from "node:fs";
import path from "node:path";
import { probe, root, font, INTER, INTER_BOLD, ARCHIVO, NOTO_TC, TWEMOJI } from "./lib.mjs";
import { outcome, fontShape, sameText, sameWithin, META } from "./filelayer.util.mjs";
import { canonPages } from "./paint.probe.mjs";

const local = (rel) => new Uint8Array(readFileSync(path.join(root, rel)));

// Derive an actual SVG-in-OpenType font from the licensed Inter fixture. Preserve its outlines
// and add a conspicuous red SVG document for every glyph; rebuild sfnt checksums, including head.
function svgOutlineFont() {
  const original = Buffer.from(font(INTER));
  const tables = new Map();
  for (let i = 0; i < original.readUInt16BE(4); i++) {
    const at = 12 + i * 16;
    const name = original.toString("ascii", at, at + 4);
    tables.set(name, Buffer.from(original.subarray(original.readUInt32BE(at + 8), original.readUInt32BE(at + 8) + original.readUInt32BE(at + 12))));
  }
  const svg = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2048 2048"><rect width="2048" height="2048" fill="red"/></svg>');
  const table = Buffer.alloc(26 + svg.length);
  table.writeUInt32BE(10, 2); table.writeUInt16BE(1, 10);
  table.writeUInt16BE(tables.get("maxp").readUInt16BE(4) - 1, 14);
  table.writeUInt32BE(16, 16); table.writeUInt32BE(svg.length, 20); svg.copy(table, 26);
  tables.set("SVG ", table); tables.delete("DSIG");
  tables.get("head").writeUInt32BE(0, 8);
  const entries = [...tables].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
  const size = 12 + 16 * entries.length + entries.reduce((n, [, bytes]) => n + ((bytes.length + 3) & ~3), 0);
  const out = Buffer.alloc(size); out.writeUInt32BE(original.readUInt32BE(0), 0); out.writeUInt16BE(entries.length, 4);
  const power = Math.floor(Math.log2(entries.length));
  out.writeUInt16BE(16 * 2 ** power, 6); out.writeUInt16BE(power, 8); out.writeUInt16BE(entries.length * 16 - 16 * 2 ** power, 10);
  const checksum = (bytes) => { let sum = 0; for (let i = 0; i < bytes.length; i += 4) sum = (sum + bytes.readUInt32BE(i)) >>> 0; return sum; };
  let offset = 12 + entries.length * 16; let headOffset = 0;
  entries.forEach(([name, bytes], i) => {
    const at = 12 + i * 16; const padded = Buffer.alloc((bytes.length + 3) & ~3); bytes.copy(padded);
    out.write(name, at, 4, "ascii"); out.writeUInt32BE(checksum(padded), at + 4); out.writeUInt32BE(offset, at + 8); out.writeUInt32BE(bytes.length, at + 12);
    padded.copy(out, offset); if (name === "head") headOffset = offset; offset += padded.length;
  });
  out.writeUInt32BE((0xB1B0AFBA - checksum(out)) >>> 0, headOffset + 8);
  return new Uint8Array(out);
}

probe("fonts.svg-opentype-outline-fallback", "Pinned public PDF API leaves SVG glyph callback unset and falls back to outlines", async (t) => {
  const source = '<p style="font-family:SvgOutline;font-size:24px">SVG font A</p>';
  const modified = await t.both(source, { viewport: { width: 240, height: 70 } }, { fonts: [{ name: "SvgOutline", data: svgOutlineFont() }] });
  t.same("outcome", outcome(modified.bm), outcome(modified.ref));
  if (!modified.ref || modified.bm.error || modified.ref.error) return;
  sameText(t, "SVG-table font extraction", modified.bm.text, modified.ref.text);
  for (const [name, result] of [["bm", modified.bm], ["pinned public Takumi", modified.ref]]) {
    const paint = canonPages(result)[0].join(" ");
    t.ok(fontShape(result).some((f) => f.subtype === "Type3"), `${name}: SVG-table font uses the color-glyph Type3 path`);
    t.ok(/\bc\b/.test(paint) && !/\b1\s+0\s+0\s+rg\b/.test(paint), `${name}: glyph curves are drawn while the red SVG rectangle is absent`);
  }
});
const F = {
  cffOtf: () => ({ name: "SourceSans", data: local("src/font/testdata/SourceSans3-Regular.otf") }),
  cffItalicOtf: () => ({ name: "SourceSerifIt", data: local("src/font/testdata/SourceSerif4-It.otf") }),
  cff2Var: () => ({ name: "SourceSansVF", data: local("src/font/testdata/SourceSans3VF-Upright.otf") }),
  cffWoff2: () => ({ name: "CJKLocl", data: font("assets/fonts/cjk-locl-test/CJKLoclTest.woff2") }),
  woff1: () => ({ name: "GeistWoff", data: local("src/woff/testdata/geist.woff") }),
  geistVarTtf: () => ({ name: "GeistVar", data: font("assets/fonts/geist/geist-latin-wght-300-800.ttf") }),
  geistVarWoff2: () => ({ name: "GeistVarW2", data: font("assets/fonts/geist/geist-latin-wght-300-800.woff2") }),
  interOpsz: () => ({ name: "InterOpsz", data: font("assets/fonts/inter/inter-latin-opsz-wght-normal.woff2") }),
  ttcGeist: () => font("assets/fonts/geist/GeistDuo.ttc"),
  ttcUbuntu: () => font("assets/fonts/ubuntu/Ubuntu.ttc"),
  notoColorEmoji: () => ({ name: "NotoEmoji", data: font("assets/fonts/noto-sans/NotoColorEmoji.ttf") }),
  notoColrSubset: () => ({ name: "NotoCOLR", data: font("takumi-pdf/tests/fonts/NotoColorEmoji.COLR.subset.ttf") }),
  arabic: () => ({ name: "Scheherazade", data: font("assets/fonts/sil/scheherazade-new-v17-arabic-regular.woff2") }),
  devanagari: () => ({ name: "NotoDeva", data: font("assets/fonts/noto-sans/noto-sans-devanagari-v30-devanagari-regular.woff2") }),
  mono: () => ({ name: "GSCode", data: font("assets/fonts/google-sans-code/GoogleSansCode-VariableFont_wght.woff2") }),
};

/** Font dictionaries without the program-shape and the raw (tagged) names. */
const dicts = (d) => (fontShape(d) || []).map(({ fontProgram, rawBaseFont, toUnicodeText, ...rest }) => rest);
const programs = (d) => (fontShape(d) || []).map((f) => ({ base: f.baseFont || f.name, file: f.fontFile, sub: f.fontFileSubtype, keys: f.fontFileKeys, program: f.fontProgram }));

async function fonts(t, html, options, fontList, { id = "", program = true, widthsTol = 0 } = {}) {
  const r = await t.both(html, options || {}, { fonts: fontList });
  const p = id ? id + " " : "";
  if (!t.same(p + "outcome", outcome(r.bm), outcome(r.ref)) || !r.ref || r.bm.error) return r;
  t.same(p + "font object kinds", (fontShape(r.bm) || []).map((f) => f.subtype + ":" + (f.cidSubtype || "") + ":" + (f.fontFile || "") + ":" + (f.fontFileSubtype || "") + ":" + (f.baseFont || f.name)), (fontShape(r.ref) || []).map((f) => f.subtype + ":" + (f.cidSubtype || "") + ":" + (f.fontFile || "") + ":" + (f.fontFileSubtype || "") + ":" + (f.baseFont || f.name)));
  if (widthsTol) sameWithin(t, p + "font dictionaries, widths, descriptors, ToUnicode", dicts(r.bm), dicts(r.ref), widthsTol); else sameText(t, p + "font dictionaries, widths, descriptors, ToUnicode", dicts(r.bm), dicts(r.ref));
  if (program) sameText(t, p + "font program shape (container, tables kept, numGlyphs, fsType)", programs(r.bm), programs(r.ref));
  t.same(p + "extracted text", r.bm.text.replace(/\s+/g, " ").trim(), r.ref.text.replace(/\s+/g, " ").trim());
  return r;
}

probe("fonts.truetype.basic", "TrueType (glyf) -> Type0 + CIDFontType2 + FontFile2, /CIDToGIDMap /Identity, /W, descriptor flags, ToUnicode", async (t) => {
  const r = await fonts(t, `<p>Hello, World! 0123456789 — ÄÖÜ ß</p>`, {}, [INTER]);
  if (r.ref && !r.bm.error) t.note("takumi font: " + JSON.stringify(dicts(r.ref)[0]).slice(0, 900));
});

probe("fonts.truetype.program-bytes", "embedded TrueType subset: byte identity of the font program", async (t) => {
  const r = await t.both(`<p>Hello, World!</p>`, {}, { fonts: [INTER] });
  if (!r.ref || r.bm.error || r.ref.error) { t.same("outcome", outcome(r.bm), outcome(r.ref)); return; }
  const prog = (d) => { const o = [...d.pdf.objs.values()].find((x) => x.raw && x.dict.Length1 !== undefined) || [...d.pdf.objs.values()].find((x) => x.raw && !x.dict.Type && !x.dict.Subtype && x.data && x.data.readUInt32BE(0) === 0x00010000); return o ? o.data : null; };
  const a = prog(r.bm); const b = prog(r.ref);
  t.ok(!!a && !!b, "font program streams found");
  if (a && b) { t.same("font program length", a.length, b.length); t.same("font program bytes identical", Buffer.compare(a, b) === 0, true); }
  const keys = (d) => { const o = [...d.pdf.objs.values()].find((x) => x.raw && x.data && x.data.length > 4 && x.data.readUInt32BE(0) === 0x00010000); return o ? Object.keys(o.dict).sort().join(",") : null; };
  t.same("font stream dictionary keys (/Length1?)", keys(r.bm), keys(r.ref));
});

probe("fonts.subset-tag", "subset tag: 6 letters, deterministic, value equal to takumi's (hash of the glyph remapper)", async (t) => {
  const a = await t.both(`<p>Hello</p>`, {}, { fonts: [INTER] }); const b = await t.both(`<p>Hello</p>`, {}, { fonts: [INTER] }); const c = await t.both(`<p>Hello!</p>`, {}, { fonts: [INTER] });
  if (a.bm.error) { t.ok(false, a.bm.error); return; }
  const tagOf = (d) => fontShape(d)[0].rawBaseFont;
  t.ok(/^[A-Z]{6}\+/.test(tagOf(a.bm)), "bm BaseFont has a 6-letter subset tag: " + tagOf(a.bm));
  t.ok(tagOf(a.bm) === tagOf(b.bm), "bm tag is deterministic");
  t.ok(tagOf(a.bm) !== tagOf(c.bm), "bm tag changes with the glyph set");
  if (a.ref && !a.ref.error) { t.same("BaseFont with tag (same glyph set)", tagOf(a.bm), tagOf(a.ref)); t.same("BaseFont with tag (other glyph set)", tagOf(c.bm), tagOf(c.ref)); }
});

probe("fonts.same-font-many-uses", "one font at several sizes / colours / synthetic styles -> one font object? bold + italic faces", async (t) => {
  await fonts(t, `<p style="font-size:10px">small</p><p style="font-size:40px;color:red">large</p><p style="letter-spacing:2px">spaced</p>`, {}, [INTER], { id: "sizes" });
  await fonts(t, `<p>regular <b>bold</b> <i>italic</i> <b><i>both</i></b></p>`, {}, [INTER], { id: "synthetic bold+italic (only regular registered)" });
  await fonts(t, `<p>regular <b>bold</b> <i>italic</i></p>`, {}, [INTER, INTER_BOLD, "assets/fonts/Inter-Italic.ttf"], { id: "real bold+italic faces" });
  await fonts(t, `<p style="font-weight:600">semi</p><p style="font-weight:100">thin</p><p style="font-weight:900">black</p>`, {}, [INTER, INTER_BOLD], { id: "weight matching" });
});

probe("fonts.synthetic.drawing", "synthetic bold / italic: how the glyphs are drawn (text render mode, stroke width, matrix)", async (t) => {
  for (const [name, html] of [["bold", `<p><b>bold</b></p>`], ["italic", `<p><i>italic</i></p>`], ["bold italic", `<p><b><i>both</i></b></p>`], ["font-synthesis none", `<p style="font-synthesis:none"><b>b</b> <i>i</i></p>`], ["oblique angle", `<p style="font-style:oblique 20deg">o</p>`]]) {
    const r = await t.both(html, { tagged: false }, { fonts: [INTER] });
    if (!t.same(name + " outcome", outcome(r.bm), outcome(r.ref)) || !r.ref || r.bm.error) continue;
    const ops = (d) => d.content(0).replace(/\(((?:[^()\\]|\\.)*)\)/g, "(…)").replace(/\s+/g, " ").trim();
    sameWithin(t, name + " content stream", ops(r.bm), ops(r.ref), 0.01);
  }
});

probe("fonts.cff.otf", "CFF OpenType -> Type0 (BaseFont + -Identity-H) + CIDFontType0 + FontFile3 /CIDFontType0C, no /CIDToGIDMap", async (t) => {
  const r = await fonts(t, `<p style="font-family:SourceSans">Hello CFF fi fl 0123</p>`, {}, [F.cffOtf()]);
  if (r.ref && !r.ref.error) t.note("takumi: " + JSON.stringify(programs(r.ref)));
  await fonts(t, `<p style="font-family:SourceSerifIt">Italic CFF</p>`, {}, [F.cffItalicOtf()], { id: "italic cff" });
  await fonts(t, `<p style="font-family:CJKLocl" lang="zh">直 骨 今 海</p>`, {}, [F.cffWoff2()], { id: "cff in woff2 (CID-keyed?)" });
});

probe("fonts.cff2.variable", "CFF2 variable font: instanced to a static CFF? weights 200 / 400 / 900", async (t) => {
  const r = await fonts(t, `<p style="font-family:SourceSansVF;font-weight:400">Regular</p><p style="font-family:SourceSansVF;font-weight:900">Black</p><p style="font-family:SourceSansVF;font-weight:200">Light</p>`, {}, [F.cff2Var()], { widthsTol: 1 });
  if (r.ref && !r.ref.error) t.note("takumi: " + JSON.stringify(programs(r.ref)));
});

probe("fonts.variable.truetype", "variable TrueType (gvar): one static instance per used axis position; wght / wdth; tables kept (no fvar/gvar?)", async (t) => {
  const css = `font-family:Archivo`;
  const r = await fonts(t, `<p style="${css};font-weight:400">Regular</p><p style="${css};font-weight:700">Bold</p><p style="${css};font-weight:650">W650</p><p style="${css};font-stretch:75%">Condensed</p><p style="${css};font-stretch:125%;font-weight:900">Wide Black</p>`, {}, [{ name: "Archivo", data: font(ARCHIVO) }], { widthsTol: 1 });
  if (r.ref && !r.ref.error) t.note("takumi: " + JSON.stringify(programs(r.ref)));
  await fonts(t, `<p style="${css};font-variation-settings:'wght' 333, 'wdth' 88">custom axes</p><p style="${css};font-variation-settings:'wght' 5000">clamped</p>`, {}, [{ name: "Archivo", data: font(ARCHIVO) }], { id: "font-variation-settings", widthsTol: 1 });
  await fonts(t, `<p style="font-family:InterOpsz;font-size:10px">small opsz</p><p style="font-family:InterOpsz;font-size:40px">large opsz</p><p style="font-family:InterOpsz;font-size:40px;font-optical-sizing:none">no opsz</p>`, {}, [F.interOpsz()], { id: "opsz", widthsTol: 1 });
  await fonts(t, `<p style="font-family:GeistVar;font-weight:300">a</p><p style="font-family:GeistVar;font-weight:800">a</p><p style="font-family:GeistVar;font-weight:800;font-style:italic">synthetic italic on a variable font</p>`, {}, [F.geistVarTtf()], { id: "geist wght", widthsTol: 1 });
});

probe("fonts.containers", "WOFF / WOFF2 / TTC inputs: decoded and embedded as sfnt subsets", async (t) => {
  // BM supports WOFF1. The pinned Takumi build does not, so treat that as a BM capability
  // check instead of reporting the expected unsupported-format difference as a regression.
  const woff1 = await t.both(`<p style="font-family:GeistWoff">Woff one</p>`, {}, { fonts: [F.woff1()] });
  t.ok(!woff1.bm.error && fontShape(woff1.bm)?.length === 1, "woff1 decodes and embeds in bm");
  if (woff1.ref?.error === "Unsupported font format") t.differs("bm supports WOFF1; pinned Takumi does not");
  else if (woff1.ref && !woff1.ref.error) fonts(t, `<p style="font-family:GeistWoff">Woff one</p>`, {}, [F.woff1()], { id: "woff1", widthsTol: 1 });
  await fonts(t, `<p style="font-family:GeistVarW2">Woff two</p>`, {}, [F.geistVarWoff2()], { id: "woff2", widthsTol: 1 });
  const ttcHtml = `<p style="font-family:Geist">Geist face</p><p style="font-family:'Geist Mono'">Mono face</p>`;
  const ttc = await t.both(ttcHtml, {}, { fonts: [F.ttcGeist()] });
  if (!t.same("ttc geist outcome", outcome(ttc.bm), outcome(ttc.ref)) || !ttc.ref || ttc.bm.error) return;
  const bmFonts = fontShape(ttc.bm) || [];
  const refFonts = fontShape(ttc.ref) || [];
  const withoutBBox = (fonts) => fonts.map((f) => {
    const copy = structuredClone(f);
    if (copy.descriptor) delete copy.descriptor.FontBBox;
    delete copy.rawBaseFont; // subset tags are intentionally engine-specific
    return copy;
  });
  // The source TTC's head tables specify these boxes. Takumi reports a different yMin
  // (-220 for Geist-Regular); preserve an independent source-of-truth check for BM here.
  t.same("ttc geist dictionaries excluding FontBBox", withoutBBox(bmFonts), withoutBBox(refFonts));
  t.same("ttc geist face names", bmFonts.map((f) => f.baseFont), ["TAGTAG+Geist-Regular", "TAGTAG+GeistMono-Regular"]);
  t.same("ttc geist FontBBox from face head tables", bmFonts.map((f) => f.descriptor?.FontBBox), ["[-200 -240 2338 940]", "[-1738 -394 654 1041]"]);
  t.same("ttc geist extracted text", ttc.bm.text.replace(/\s+/g, " ").trim(), ttc.ref.text.replace(/\s+/g, " ").trim());
  await fonts(t, `<p style="font-family:Ubuntu">Ubuntu face</p><p style="font-family:Ubuntu;font-weight:700">bold</p><p style="font-family:Ubuntu;font-style:italic">italic</p>`, {}, [F.ttcUbuntu()], { id: "ttc ubuntu", widthsTol: 1 });
});

probe("fonts.tounicode", "ToUnicode CMaps: ligatures, many-to-one, surrogate pairs, combining marks, RTL, complex scripts, PUA", async (t) => {
  await fonts(t, `<p>office affluent ﬁ ﬂ fi fl ffi</p>`, {}, [INTER], { id: "latin ligatures" });
  await fonts(t, `<p>a a a A A  spaces nbsp</p>`, {}, [INTER], { id: "repeats / space / nbsp" });
  await fonts(t, `<p>é é ñ ǻ</p>`, {}, [INTER], { id: "combining marks" });
  await fonts(t, `<p style="font-family:Scheherazade" dir="rtl" lang="ar">نص عربي للتشكيل لا</p>`, {}, [F.arabic()], { id: "arabic (rtl, lam-alef)" });
  await fonts(t, `<p style="font-family:NotoDeva" lang="hi">संयुक्ताक्षर क्षत्र कि</p>`, {}, [F.devanagari()], { id: "devanagari (reordering, conjuncts)" });
  await fonts(t, `<p style="font-family:NotoTC" lang="zh">漢字𠀀測試</p>`, { uncoveredText: "blank" }, [{ name: "NotoTC", data: font(NOTO_TC) }], { id: "cjk + supplementary plane", widthsTol: 1 });
  await fonts(t, `<p>frac 1/2 sup x² № ™ … ‘’ “” – —</p><p style="font-feature-settings:'frac','smcp','tnum'">1/2 Small Caps 0123</p>`, {}, [INTER], { id: "features (frac, smcp, tnum)" });
  await fonts(t, `<p style="font-variant:small-caps">Small Caps</p><p style="font-variant-ligatures:none">office fi</p><p style="font-kerning:none">AVATAR</p>`, {}, [INTER], { id: "font-variant" });
  await fonts(t, `<p>tab\there zwj‍ zwnj‌ lrm‎ shy­ bom﻿</p>`, {}, [INTER], { id: "default-ignorable characters" });
});

probe("fonts.widths", "/W array and /DW: grouping, rounding, most common width, monospaced font flags", async (t) => {
  await fonts(t, `<p>iiiiii mmmmmm WWWW .... 1111</p>`, {}, [INTER], { id: "proportional" });
  await fonts(t, `<p style="font-family:GSCode">mono iiii WWWW 0000</p>`, {}, [F.mono()], { id: "monospaced (FIXED_PITCH flag, /DW)", widthsTol: 1 });
  await fonts(t, `<p style="font-family:Roboto">Roboto</p><p style="font-family:Roboto;font-style:italic">Italic (ITALIC flag, /ItalicAngle)</p><p style="font-family:Roboto;font-weight:700">Bold (/StemV)</p>`, {}, ["assets/fonts/Roboto-Regular.ttf", "assets/fonts/Roboto-Italic.ttf", "assets/fonts/Roboto-Bold.ttf"], { id: "descriptor flags" });
  await fonts(t, `<p style="font-family:'Noto Sans'">Noto Sans</p><p style="font-family:'Noto Sans';font-weight:700">Bold</p>`, {}, ["assets/fonts/NotoSans-Regular.ttf", "assets/fonts/NotoSans-Bold.ttf"], { id: "noto sans" });
});

const ASCII = Array.from({ length: 95 }, (_, i) => String.fromCharCode(32 + i).replace("<", "&lt;").replace("&", "&amp;")).join("");
/** The embedded TrueType program of a render (the first one), or null. */
const sfnt = (d) => [...d.pdf.objs.values()].find((x) => x.raw && x.data && x.data.length > 4 && x.data.readUInt32BE(0) === 0x00010000)?.data ?? null;
probe("fonts.subset.glyph-closure", "subset contents: composite glyphs pull components, .notdef kept, glyph count", async (t) => {
  // (all ASCII on one line: a line break before `@` is a shaping difference, below; an nbsp-only paragraph
  // inside a block: at the top level of a fragment takumi drops it, below)
  for (const [name, html] of [["accented composites", `<p>Àéîõü Å ç ñ</p>`], ["one glyph", `<p>x</p>`], ["all ASCII", `<p style="white-space:nowrap">${ASCII}</p>`], ["space only", `<div><p>&nbsp;</p></div>`]]) {
    const r = await t.both(html, {}, { fonts: [INTER] });
    if (!t.same(name + " outcome", outcome(r.bm), outcome(r.ref)) || !r.ref || r.bm.error) continue;
    sameText(t, name + " program shape", programs(r.bm), programs(r.ref));
    t.same(name + " subset size (bytes)", sfnt(r.bm)?.length ?? null, sfnt(r.ref)?.length ?? null);
  }
});

// Two takumi defects the subset size showed, bm-render keeping the browser's result (docs/PDF_AUDIT.md "Glyph subset
// closure"). (1) A line that starts with `@` before capitals after a break: Inter's contextual alternate raises the
// `@` (the composite `@.case`, whose component is the default `@`) as it does on an unbroken line, which both
// engines draw; takumi draws the default `@` once the break falls before it. (2) An nbsp-only paragraph at the top
// level of an HTML fragment: takumi drops its text (U+00A0 read as collapsible white space) and with it the line,
// so `<p>&nbsp;</p><p>x</p>` draws `x` a line higher; bm-render keeps the line, as browsers do.
probe("fonts.subset.line-start-alternate", "subset contents: a contextual alternate at the start of a wrapped line", async (t) => {
  const r = await t.both(`<p style="width:20px">?@AB</p>`, {}, { fonts: [INTER] });
  t.ok(!r.bm.error, "bm renders");
  if (r.bm.error) return;
  const glyphs = programs(r.bm)?.[0]?.program?.numGlyphs;
  t.ok(glyphs === 6, `bm draws the raised @ (composite) on the second line, as on one line: notdef, ?, @.case, A, B and the @ component (${glyphs} glyphs)`);
  const one = await t.both(`<p>?@AB</p>`, {}, { fonts: [INTER] });
  t.same("unbroken line: same glyphs", programs(one.bm), programs(one.ref));
  if (r.ref && !r.ref.error) t.differs(`takumi draws the default @ after the break (${programs(r.ref)?.[0]?.program?.numGlyphs} glyphs)`);
});
probe("fonts.subset.nbsp-paragraph", "subset contents: an nbsp-only paragraph at the top level", async (t) => {
  const r = await t.both(`<p>&nbsp;</p><p>x</p>`, {}, { fonts: [INTER] });
  t.ok(!r.bm.error, "bm renders");
  if (r.bm.error) return;
  const lines = [...r.bm.content(0).matchAll(/1 0 0 -1 [\d.]+ ([\d.]+) Tm/g)].map((m) => Number(m[1]));
  t.ok(lines.length === 2 && lines[1] > lines[0], `bm draws the nbsp line, x below it: ${JSON.stringify(lines)}`);
  if (r.ref && !r.ref.error) t.differs(`takumi drops the nbsp text and its line (lines ${JSON.stringify([...r.ref.content(0).matchAll(/1 0 0 -1 [\d.]+ ([\d.]+) Tm/g)].map((m) => Number(m[1])))})`);
});

probe("fonts.type3.colr", "colour glyphs: COLR v0 (Twemoji) / COLR v1 (Noto) -> Type3 fonts? char procs, resources, ToUnicode", async (t) => {
  const tw = [{ name: "Twemoji", data: font(TWEMOJI) }];
  const r = await fonts(t, `<p style="font-family:Twemoji">🎉🚀😀</p>`, {}, [INTER, ...tw], { id: "COLR v0", program: false });
  if (r.ref && !r.ref.error) t.note("takumi font kinds: " + (fontShape(r.ref) || []).map((f) => f.subtype + "/" + (f.baseFont || f.name)).join(", "));
  await fonts(t, `<p>text <span style="font-family:Twemoji">🎉</span> mixed <span style="font-family:Twemoji">👨‍👩‍👧 🇯🇵 👍🏽</span></p>`, {}, [INTER, ...tw], { id: "COLR v0 sequences (zwj, flags, skin tone)", program: false });
  await fonts(t, `<p style="font-family:NotoCOLR">😀🎉</p>`, { uncoveredText: "blank" }, [INTER, F.notoColrSubset()], { id: "COLR v1 (gradients)", program: false });
  await fonts(t, `<p style="font-family:Twemoji;color:red;opacity:.5;font-size:40px;transform:rotate(10deg)">🎉</p>`, {}, [INTER, ...tw], { id: "COLR with colour / opacity / transform", program: false });
  await fonts(t, `<p style="font-family:Twemoji">🎉</p>`, { pdfa: "2b", metadata: META }, [INTER, ...tw], { id: "COLR under PDF/A-2b", program: false });
  await fonts(t, `<h1 style="font-family:Twemoji">🎉</h1>`, { tagged: "ua1", lang: "en", metadata: META }, [INTER, ...tw], { id: "COLR under PDF/UA-1", program: false });
});

probe("fonts.type3.bitmap", "bitmap colour glyphs (CBDT NotoColorEmoji): Type3 with image XObjects? or page-level images", async (t) => {
  const r = await fonts(t, `<p style="font-family:NotoEmoji;font-size:32px">😀🎉</p>`, { uncoveredText: "blank" }, [INTER, F.notoColorEmoji()], { program: false });
  if (r.ref && !r.ref.error && !r.bm.error) {
    const imgs = (d) => d.subtyped("Image").map((o) => `${o.dict.Width}x${o.dict.Height} ${String(o.dict.ColorSpace)} ${String(o.dict.Filter)} smask=${o.dict.SMask !== undefined}`).sort();
    sameText(t, "image XObjects", imgs(r.bm), imgs(r.ref));
    t.note("takumi font kinds: " + (fontShape(r.ref) || []).map((f) => f.subtype + "/" + (f.baseFont || f.name)).join(", ") + "; images " + imgs(r.ref).length);
  }
});

probe("fonts.uncovered", "uncoveredText error | placeholder | blank: messages (codepoint naming, several characters, order), output", async (t) => {
  const cases = [
    ["one char", `<p>a中b</p>`],
    ["several chars, repeated, in order of appearance", `<p>中文 字中 😀 文</p>`],
    ["supplementary plane", `<p>𠀀</p>`],
    ["control / format chars are not reported", `<p>a​b­c‍d️e</p>`],
    ["variation selector after covered char", `<p>☺️ ❤️</p>`],
    ["PUA", `<p></p>`],
    ["in a band", `<p>x</p>`, { size: "A5", header: `<p>中</p>` }],
    ["in alt text only (not drawn)", `<img alt="中" width="5" height="5" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='5' height='5'/%3E">`],
    ["in metadata only", `<p>x</p>`, { metadata: { title: "中" } }],
    ["in display:none", `<p style="display:none">中</p><p>x</p>`],
    ["in visibility:hidden", `<p style="visibility:hidden">中</p><p>x</p>`],
    ["list marker (cjk-decimal)", `<ol style="list-style-type:cjk-decimal"><li>x</li></ol>`],
    ["generated content", `<style>p::before{content:"中"}</style><p>x</p>`],
    ["whitespace kinds", `<p>a b c　d</p>`],
  ];
  for (const [name, html, extra] of cases) for (const mode of [undefined, "error", "placeholder", "blank"]) {
    const r = await t.both(html, { ...(extra || {}), uncoveredText: mode }, { fonts: [INTER] });
    const id = `${name} [${mode ?? "default"}]`;
    if (!t.same(id + " outcome", outcome(r.bm), outcome(r.ref)) || !r.ref || r.bm.error) continue;
    sameText(t, id + " font dictionaries", dicts(r.bm), dicts(r.ref));
    t.same(id + " text", r.bm.text.replace(/\s+/g, " ").trim(), r.ref.text.replace(/\s+/g, " ").trim());
  }
  for (const mode of ["Error", "none", "", 1, true]) { const r = await t.both(`<p>a</p>`, { uncoveredText: mode }); t.same("invalid uncoveredText " + JSON.stringify(mode), outcome(r.bm), outcome(r.ref)); }
});

probe("fonts.fallback", "fallback across families, unicodeRange, per-render fonts: which font object each character lands in", async (t) => {
  const tc = { name: "NotoTC", data: font(NOTO_TC) };
  await fonts(t, `<p style="font-family:Inter, NotoTC">Latin 漢字 mixed 文字 text</p>`, {}, [INTER, tc], { id: "family stack", widthsTol: 1 });
  await fonts(t, `<p style="font-family:Inter">Latin 漢字</p>`, {}, [INTER, tc], { id: "not in the stack (registered font as last resort?)", widthsTol: 1 });
  await fonts(t, `<p style="font-family:Missing, sans-serif">generic family</p>`, {}, [INTER], { id: "missing family + generic" });
  await fonts(t, `<p style="font-family:A, B">abc ABC</p>`, {}, [{ name: "A", data: font(INTER), unicodeRange: [[0x41, 0x5a]] }, { name: "B", data: font("assets/fonts/Roboto-Regular.ttf") }], { id: "unicodeRange split" });
  await fonts(t, `<p style="font-family:A">abc ABC</p>`, {}, [{ name: "A", data: font(INTER), unicodeRange: [[0x41, 0x5a]] }], { id: "unicodeRange excludes, no other font" });
  await fonts(t, `<p>no font registered at all</p>`, {}, [], { id: "no fonts" });
});

probe("fonts.unicode-range", "registered unicodeRange restricts a face and falls back to another family", async (t) => {
  const r = await t.bm(`<p style="font-family:A, B">abc ABC</p>`, {}, { fonts: [
    { name: "A", data: font(INTER), unicodeRange: "U+41-5A" },
    { name: "B", data: font("assets/fonts/Roboto-Regular.ttf") },
  ] });
  t.ok(!r.error, "CSS unicodeRange string renders: " + (r.error || ""));
  if (r.error) return;
  const embedded = fontShape(r).map((f) => f.baseFont || f.name).join(" ");
  t.ok(embedded.includes("Inter-Regular"), "uppercase A range uses the Inter face: " + embedded);
  t.ok(embedded.includes("Roboto-Regular"), "lowercase text falls back to Roboto: " + embedded);
  t.same("extracted text", r.text.replace(/\s+/g, " ").trim(), "abc ABC");
});

probe("fonts.broken", "fonts that cannot be embedded: garbage, truncated, no cmap, bitmap-only -> error text", async (t) => {
  const inter = Buffer.from(font(INTER));
  const drop = (tag) => { const b = Buffer.from(inter); const n = b.readUInt16BE(4); for (let i = 0; i < n; i++) { const o = 12 + i * 16; if (b.toString("latin1", o, o + 4) === tag) b.write("zzzz", o, "latin1"); } return new Uint8Array(b); };
  for (const [name, data] of [["garbage bytes", new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])], ["empty", new Uint8Array(0)], ["truncated", new Uint8Array(inter.subarray(0, 4000))], ["no cmap table", drop("cmap")], ["no glyf table", drop("glyf")], ["no OS/2 table", drop("OS/2")], ["no post table", drop("post")], ["no name table", drop("name")], ["no hmtx table", drop("hmtx")]]) {
    const r = await t.both(`<p style="font-family:Broken">Hello</p>`, {}, { fonts: [{ name: "Broken", data }] });
    t.same(name + " outcome", outcome(r.bm), outcome(r.ref));
    if (r.ref) t.note(`${name} => bm: ${outcome(r.bm)} | takumi: ${outcome(r.ref)}`);
    if (r.ref && !r.bm.error && !r.ref.error) sameText(t, name + " font dictionaries", dicts(r.bm), dicts(r.ref));
  }
});

probe("fonts.text-drawing-modes", "text that is not drawn with a font: clipped background-clip:text, stroke, shadow, rotated across pages (outlines)", async (t) => {
  for (const [name, html, o] of [["-webkit-text-stroke", `<p style="-webkit-text-stroke:1px red">stroke</p>`], ["text-shadow blur", `<p style="text-shadow:2px 2px 3px #000">shadow</p>`], ["background-clip:text", `<p style="background:linear-gradient(red,blue);-webkit-background-clip:text;color:transparent">clip</p>`], ["transparent text", `<p style="color:transparent">invisible</p>`], ["opacity text", `<p style="opacity:.4">faded</p>`], ["vertical writing", `<p style="writing-mode:vertical-rl;height:100px">vertical</p>`]]) {
    const r = await t.both(html, { ...(o || {}), tagged: false }, { fonts: [INTER] });
    if (!t.same(name + " outcome", outcome(r.bm), outcome(r.ref)) || !r.ref || r.bm.error) continue;
    sameText(t, name + " font dictionaries", dicts(r.bm), dicts(r.ref));
    const tr = (d) => (d.content(0).match(/\b\d Tr\b/g) || []).join(" ");
    t.same(name + " text render modes", tr(r.bm), tr(r.ref));
    t.same(name + " text", r.bm.text.replace(/\s+/g, " ").trim(), r.ref.text.replace(/\s+/g, " ").trim());
  }
});
