#!/usr/bin/env node
// Checks that a document drawn a part at a time (src/pdf/chunks.zig, paged.zig `writeChunked`) is the document
// drawn whole: every case renders with `chunks: false` and in parts (`chunks: 1`, the smallest parts, unless the case
// names a size; a document without forced breaks is cut at any page boundary, `flow-*` cases), and the two
// files must show the same
// pages (count, boxes), the same marks on each page (the audit's device-space draw lists: paths, text, images, paints,
// clips, transparency, marked content, numbers within 0.011), the same extracted text, structure tree, parent tree,
// link annotations, destinations and outline. Coordinates inside the content streams may differ (a part's frame has
// its own origin), so files are not compared byte for byte.
//
//   node scripts/pdf-chunks-check.mjs [--backend=native|wasm] [filter ...]
//
// With the native addon the number of parts each render was drawn in is reported (memory checkpoints), and a case
// marked `parts: true` fails when it was not drawn in parts. Exit code 1 on any difference.
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);
const backend = argv.find((a) => a.startsWith("--backend="))?.slice(10) ?? "native";
const filters = argv.filter((a) => !a.startsWith("--"));
process.env.BM_RENDER_BACKEND = backend;
const url = (p) => pathToFileURL(path.join(ROOT, p)).href;
const { describe } = await import(url("scripts/pdf-audit/lib.mjs"));
const { canonPages, flatten, firstDiff } = await import(url("scripts/pdf-audit/paint.probe.mjs"));
const { stressHtml, stressCorpus, INTER } = await import(url("bench/pdf/corpus/docs.mjs"));
const mod = await import(url("js/node-pdf.mjs"));
if (mod.backend !== backend) throw new Error(`backend ${backend} unavailable (loaded ${mod.backend})`);
let addon = null;
if (backend === "native") {
  // (the addon js/native.mjs loaded: native/dist/<platform>-<arch>[-libc]/bm-render.*.node)
  const dir = path.join(ROOT, "native", "dist");
  const name = existsSync(dir) ? readdirSync(dir).find((d) => d.startsWith(`${process.platform}-${process.arch}`)) : null;
  const file = name ? path.join(dir, name, `bm-render.${name}.node`) : null;
  try { addon = file ? createRequire(import.meta.url)(file) : null; if (addon && !addon.memoryTrace) addon = null; } catch { addon = null; }
  if (!addon) console.log("(native memory checkpoints unavailable: part counts are not checked)");
}

const fonts = INTER.map((f) => ({ name: f.name, data: new Uint8Array(readFileSync(f.path)), weight: f.weight, style: f.style }));
const r = new mod.PdfRenderer();
for (const f of fonts) r.registerFont(f);
const stressOpts = stressCorpus([1])[0].options();
const LOREM = "Paged output flows content across pages the way a browser prints: text wraps at the page width, a line that does not fit moves to the next page.";
const para = (n) => Array.from({ length: n }, () => `<p>${LOREM}</p>`).join("");
const sections = (n, body = (k) => `<h2>Part ${k + 1}</h2>${para(3)}`, attrs = (k) => `style="break-after:page"`) =>
  `<div style="font:12px Inter">${Array.from({ length: n }, (_, k) => `<section ${attrs(k)}>${body(k)}</section>`).join("")}</div>`;
// takumi-pdf `memory_tests.rs` (scripts/pdf-memory.mjs)
const takumiSections = (n) => `<div style="font-size: 12px">${Array.from({ length: n }, (_, i) => `<section><h2>Section ${i}</h2><p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.</p></section>`).join("")}</div>`;
const table = (rows) => `<table style="width:100%;border-collapse:collapse"><thead><tr><th style="border:1px solid #333">A</th><th style="border:1px solid #333">B</th></tr></thead><tbody>${Array.from({ length: rows }, (_, i) => `<tr><td style="border:1px solid #999">r${i}</td><td style="border:1px solid #999">${i * 7}</td></tr>`).join("")}</tbody></table>`;

const CASES = [
  { id: "stress-3", source: stressHtml(3), options: stressOpts, parts: true },
  { id: "stress-12", source: stressHtml(12), options: stressOpts, parts: true },
  { id: "stress-120-default", source: stressHtml(120), options: stressOpts, chunks: 2048, parts: true },
  { id: "stress-400-default", source: stressHtml(400), options: stressOpts, chunks: 2048, parts: true },
  { id: "sections-plain", source: sections(6), options: { size: "A5", margin: 30 }, parts: true },
  { id: "sections-long", source: sections(5, (k) => `<h2>Part ${k + 1}</h2>${para(14)}`), options: { size: "A5", margin: 30 }, parts: true },
  { id: "sections-break-before", source: sections(5, undefined, (k) => (k ? `style="break-before:page"` : "")), options: { size: "A5" }, parts: true },
  { id: "tables-across-pages", source: sections(4, (k) => `<h3>T${k}</h3>${table(45)}`), options: { size: "A5", margin: 30 }, parts: true },
  { id: "lists", source: sections(4, (k) => `<ol start="${k * 3 + 1}"><li>one</li><li>two</li><li>three</li></ol><ul><li>x</li></ul>`), options: { size: "A5" }, parts: true },
  { id: "counters", source: `<style>body{counter-reset:s} section{counter-increment:s} h2::before{content:counter(s) ". "}</style>` + sections(5), options: { size: "A5" }, parts: true },
  { id: "backward-links", source: sections(5, (k) => `<h2 id="p${k}">Part ${k + 1}</h2>${k ? `<a href="#p${k - 1}">back</a> <a href="#p0">top</a>` : ""} <a href="https://example.com/${k}">ext</a>${para(2)}`), options: { size: "A5" }, parts: true },
  { id: "forward-links-join", source: sections(5, (k) => `<h2 id="p${k}">Part ${k + 1}</h2>${k === 1 ? `<a href="#p3">ahead</a>` : ""}${para(2)}`), options: { size: "A5" }, parts: true },
  { id: "toc-forward-all", source: `<div style="font:12px Inter"><nav style="break-after:page">${[0, 1, 2, 3].map((k) => `<a href="#p${k}">p${k}</a>`).join(" ")}</nav>${[0, 1, 2, 3].map((k) => `<section style="break-after:page"><h2 id="p${k}">P${k}</h2>${para(2)}</section>`).join("")}</div>` },
  { id: "outline-ua1", source: sections(5, (k) => `<h1>Chapter ${k}</h1><h2>Sub</h2>${para(2)}<h3>Deep</h3>`), options: { size: "A5", tagged: "ua1", outline: true, lang: "en", metadata: { title: "T" } }, parts: true },
  { id: "outline-ua2-dests", source: sections(4, (k) => `<h1 id="c${k}">Chapter ${k}</h1>${k ? `<a href="#c${k - 1}">prev</a>` : ""}${para(2)}`), options: { size: "A5", tagged: "ua2", outline: true, lang: "en", metadata: { title: "T" } }, parts: true },
  { id: "dropped-part-anchors", source: sections(5, (k) => `<h2 id="p${k}">Part ${k + 1}</h2>${k ? `<a href="#p0">first</a> <a href="#p${k - 1}">back</a>` : ""}${para(2)}`), options: { size: "A5", outline: true, pageRanges: [1, 3, 4, 5] }, parts: true },
  { id: "hidden-first-id", source: `<div style="font:12px Inter"><section style="break-after:page"><a href="#x">to x</a><div id="x" style="display:none">hidden</div>${para(2)}</section><section style="break-after:page">${para(2)}</section><section><h2 id="x">X</h2>${para(2)}</section></div>`, options: { size: "A5" } },
  { id: "flat-text-children", source: `<div style="font:12px Inter">${[0, 1, 2, 3].map((k) => `<h1 style="break-before:page">Title ${k}</h1><p>${LOREM}</p><p>${LOREM}</p>`).join("")}</div>`, options: { size: "A5" }, parts: true },
  { id: "float-in-text-element", source: `<div style="font:12px Inter">${[0, 1, 2].map((k) => `<section style="break-after:page"><p style="float:left;width:80px">f${k}</p>${para(2)}</section>`).join("")}</div>`, options: { size: "A5" } },
  { id: "relative-reaches-back", source: sections(4, (k) => `<h2>P${k}</h2>${para(2)}<div style="position:relative;top:-900px;color:red">up</div>`), options: { size: "A5" } },
  { id: "hidden-between-parts", source: `<div style="font:12px Inter">${[0, 1, 2, 3].map((k) => `<section style="break-after:page"><h2>P${k}</h2>${para(2)}</section><template>t</template><div style="display:none">h</div>`).join("")}</div>`, options: { size: "A5" }, parts: true },
  { id: "untagged", source: sections(5), options: { size: "A5", tagged: false }, parts: true },
  { id: "page-ranges", source: sections(6), options: { size: "A5", pageRanges: [{ from: 2, to: 4 }, 6] }, parts: true },
  { id: "first-page-rule", source: `<style>@page:first{margin-top:120px} @page:left{margin-bottom:80px}</style>` + sections(5, (k) => `<h2>P${k}</h2>${para(6)}`), options: { size: "A5", margin: 30 }, parts: true },
  { id: "named-pages", source: `<style>@page wide{margin-top:10px;margin-bottom:60px} .w{page:wide}</style>` + sections(5, (k) => `<h2>P${k}</h2>${para(4)}`, (k) => `class="${k % 2 ? "w" : ""}" style="break-after:page"`), options: { size: "A5", margin: 40 }, parts: true },
  { id: "bands-counters", source: sections(6, (k) => `<h2>P${k}</h2>${para(5)}`), options: { size: "A5", header: `<div style="font:9px Inter">H <span class="pageNumber"></span>/<span class="totalPages"></span></div>`, footer: `<div style="font:9px Inter">F</div>` }, parts: true },
  { id: "images", source: sections(4, (k) => `<img src="icon.png" style="width:${40 + k * 10}px">${para(2)}`), options: { size: "A5", images: stressOpts.images }, parts: true },
  { id: "transforms-inside", source: sections(4, (k) => `<div style="transform:translate(${k * 10}px, 4px);width:100px;height:40px;background:#cde"></div><div style="position:relative;top:10px"><span style="position:absolute;left:5px">abs</span>rel</div>${para(2)}`), options: { size: "A5" }, parts: true },
  { id: "rotations-whole", source: sections(4, (k) => `<div style="transform:rotate(${k * 10}deg);width:100px;height:40px;background:#cde"></div>${para(2)}`), options: { size: "A5" } },
  { id: "shadow-at-top", source: sections(4, (k) => `<div style="box-shadow:0 -20px 10px #000;height:30px;margin-top:0">s</div>${para(2)}`), options: { size: "A5" } },
  { id: "full-html-body-margin", source: `<!doctype html><html><body>${sections(4)}</body></html>`, options: { size: "A5" } },
  { id: "full-html-body-zero", source: `<!doctype html><html><body style="margin:0">${sections(4)}</body></html>`, options: { size: "A5" }, parts: true },
  { id: "no-forced-breaks", source: sections(20, undefined, () => ""), options: { size: "A5" }, parts: true },
  // cut at any page boundary (paged.zig `writeFlowing`): no forced break, parts of `chunks` / 4 elements at least
  { id: "flow-takumi-memory", source: takumiSections(120), options: { size: { width: 320, height: 240 }, margin: 24, header: `<div style="font:10px Inter">Page <span class="pageNumber"></span> of <span class="totalPages"></span></div>` }, chunks: 64, parts: true },
  { id: "flow-takumi-default", source: takumiSections(700), options: { size: { width: 320, height: 240 }, margin: 24, header: `<div style="font:10px Inter">Page <span class="pageNumber"></span> of <span class="totalPages"></span></div>` }, chunks: 2048, parts: true },
  { id: "flow-long-paragraphs", source: sections(20, (k) => `<h2>Part ${k + 1}</h2>${para(9)}`, () => ""), options: { size: "A5", margin: 30 }, parts: true },
  { id: "flow-one-long-child", source: `<div style="font:12px Inter"><section><h2>Long</h2>${para(40)}</section><section>${para(3)}</section><section>${para(3)}</section><section>${para(30)}</section></div>`, options: { size: "A5" }, parts: true },
  { id: "flow-outline-ua1", source: sections(20, (k) => `<h1>Chapter ${k}</h1><h2>Sub</h2>${para(4)}<h3>Deep</h3>`, () => ""), options: { size: "A5", tagged: "ua1", outline: true, lang: "en", metadata: { title: "T" } }, parts: true },
  { id: "flow-ua2-dests", source: sections(20, (k) => `<h1 id="c${k}">Chapter ${k}</h1>${k ? `<a href="#c${k - 1}">prev</a> <a href="#c0">first</a>` : ""}${para(4)}`, () => ""), options: { size: "A5", tagged: "ua2", outline: true, lang: "en", metadata: { title: "T" } }, parts: true },
  { id: "flow-forward-links", source: sections(24, (k) => `<h2 id="p${k}">Part ${k + 1}</h2>${k === 1 ? `<a href="#p4">ahead</a>` : ""}${para(4)}`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-toc-first", source: `<div style="font:12px Inter"><nav>${[0, 1, 2, 3, 4, 5].map((k) => `<a href="#p${k}">p${k}</a>`).join(" ")}</nav>${[0, 1, 2, 3, 4, 5].map((k) => `<section><h2 id="p${k}">P${k}</h2>${para(5)}</section>`).join("")}</div>` },
  { id: "flow-inline-links", source: sections(16, (k) => `<h2>P${k}</h2><p>${LOREM} <a href="https://example.com/${k}">a link that runs ${LOREM}</a> ${LOREM} ${LOREM}</p>${para(4)}`, () => ""), options: { size: "A5", tagged: "ua1", lang: "en", metadata: { title: "T" } }, parts: true },
  { id: "flow-tables", source: sections(10, (k) => `<h3>T${k}</h3>${table(12)}${para(4)}`, () => ""), options: { size: "A5", margin: 30 }, parts: true },
  { id: "flow-lists", source: sections(20, (k) => `<ol start="${k * 3 + 1}"><li>one ${LOREM}</li><li>two</li><li>three ${LOREM}</li></ol>${para(3)}<ul><li>x</li></ul>`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-counters", source: `<style>body{counter-reset:s} section{counter-increment:s} h2::before{content:counter(s) ". "}</style>` + sections(20, (k) => `<h2>P${k}</h2>${para(4)}`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-page-ranges", source: sections(20, (k) => `<h2 id="p${k}">P${k}</h2>${k ? `<a href="#p0">first</a>` : ""}${para(4)}`, () => ""), options: { size: "A5", outline: true, pageRanges: [1, { from: 3, to: 4 }, 7] }, parts: true },
  { id: "flow-first-page-rule", source: `<style>@page:first{margin-top:120px} @page:left{margin-bottom:80px}</style>` + sections(20, (k) => `<h2>P${k}</h2>${para(5)}`, () => ""), options: { size: "A5", margin: 30 }, parts: true },
  { id: "flow-bands", source: sections(20, (k) => `<h2>P${k}</h2>${para(5)}`, () => ""), options: { size: "A5", header: `<div style="font:9px Inter">H <span class="pageNumber"></span>/<span class="totalPages"></span></div>`, footer: `<div style="font:9px Inter">F</div>`, pages: { last: { footer: `<div style="font:9px Inter">last</div>` } } }, parts: true },
  { id: "flow-margins", source: `<div style="font:12px Inter">${Array.from({ length: 30 }, (_, k) => `<section style="margin:${k * 3}px 0 ${20 - k}px"><h2 style="margin:14px 0">P${k}</h2>${para(3)}</section>`).join("")}</div>`, options: { size: "A5" }, parts: true },
  { id: "flow-decorated", source: `<div style="font:12px Inter">${Array.from({ length: 20 }, (_, k) => `<section style="border:2px solid #345;background:#eef;padding:6px;border-radius:6px"><h2>P${k}</h2>${para(4)}</section>`).join("")}</div>`, options: { size: "A5" }, parts: true },
  { id: "flow-transforms", source: sections(20, (k) => k % 3 ? para(4) : `<div style="transform:translate(${k * 10}px, 4px);width:100px;height:40px;background:#cde"></div><div style="position:relative;top:10px"><span style="position:absolute;left:5px">abs</span>rel</div>${para(3)}`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-images", source: sections(20, (k) => `<img src="icon.png" style="width:${40 + k * 10}px">${para(3)}`, () => ""), options: { size: "A5", images: stressOpts.images }, parts: true },
  { id: "flow-widows", source: `<style>p{orphans:3;widows:3} h2{break-after:avoid}</style>` + sections(24, (k) => `<h2>P${k}</h2>${para(3)}`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-body-zero", source: `<!doctype html><html><body style="margin:0">${sections(20, undefined, () => "")}</body></html>`, options: { size: "A5" }, parts: true },
  // cut inside a table (between its rows), a flex container or a grid (between its lines / rows, or inside a
  // single-column one): every page of these documents starts inside one
  { id: "flow-table-rows", source: sections(12, (k) => `<h3>T${k}</h3>${table(50)}${para(1)}`, () => ""), options: { size: "A5", margin: 30 }, parts: true },
  { id: "flow-table-rows-ua1", source: sections(12, (k) => `<h3>T${k}</h3>${table(50)}${para(1)}`, () => ""), options: { size: "A5", margin: 30, tagged: "ua1", lang: "en", metadata: { title: "T" } }, parts: true },
  { id: "flow-one-long-table", source: `<div style="font:12px Inter"><p>${LOREM}</p>${table(400)}<p>${LOREM}</p><p>end</p></div>`, options: { size: "A5" }, parts: true },
  { id: "flow-table-tall-rows", source: sections(10, (k) => `<table style="width:100%;border-collapse:collapse">${Array.from({ length: 12 }, (_, i) => `<tr><td style="border:1px solid #999;width:30%">r${k}.${i}</td><td style="border:1px solid #999">${i % 3 ? LOREM : "x"}</td></tr>`).join("")}</table>`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-table-separate", source: sections(10, (k) => `<table style="width:100%;border-spacing:4px;border:2px solid #333;background:#f4f4ff"><caption>Cap ${k}</caption><tfoot><tr><td>foot</td><td>${k}</td></tr></tfoot><tbody>${Array.from({ length: 40 }, (_, i) => `<tr><td style="background:#dde">c${i}</td><td>${i}</td></tr>`).join("")}</tbody></table>`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-flex-column", source: sections(12, (k) => `<h3>F${k}</h3><div style="display:flex;flex-direction:column;gap:6px;border:1px solid #889;padding:4px">${para(6)}</div>`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-flex-wrap", source: sections(8, (k) => `<h3>W${k}</h3><div style="display:flex;flex-wrap:wrap;gap:6px">${Array.from({ length: 40 }, (_, i) => `<div style="width:110px;height:46px;border:1px solid #567;background:#eef">${k}.${i}</div>`).join("")}</div>`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-grid-rows", source: sections(8, (k) => `<h3>G${k}</h3><div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:5px">${Array.from({ length: 60 }, (_, i) => `<div style="border:1px solid #765;padding:3px">${k}.${i} ${i % 4 ? "" : "two words"}</div>`).join("")}</div>`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-grid-one-column", source: sections(12, (k) => `<h3>C${k}</h3><div style="display:grid;gap:8px">${para(5)}</div>`, () => ""), options: { size: "A5" }, parts: true },
  // children of the flow holding positioned / transformed boxes
  { id: "flow-relative-long", source: sections(14, (k) => `<div style="position:relative;padding-right:40px">${para(7)}<span style="position:absolute;right:0;top:0">tag ${k}</span></div>`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-relative-items", source: sections(14, (k) => `<h3>R${k}</h3>${para(3)}<p style="position:relative;left:6px">${LOREM}</p>${para(3)}`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-translated-long", source: sections(14, (k) => `<div style="transform:translateX(4px)">${para(7)}</div>`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-abs-in-table", source: sections(10, (k) => `<table style="width:100%;position:relative">${Array.from({ length: 30 }, (_, i) => `<tr><td>${k}.${i}</td><td style="position:relative">v<span style="position:absolute;left:30px">a</span></td></tr>`).join("")}</table>`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-positioned-mix", source: sections(14, (k) => `<div style="position:relative">${para(3)}<div style="transform:translate(${k * 3}px, 6px);background:#cde">${para(2)}</div><div style="position:relative;top:${k % 3 * 9}px;z-index:${k % 2}">${LOREM}<span style="position:absolute;left:4px;top:${k * 5}px">abs ${k}</span></div>${para(2)}</div>`, () => ""), options: { size: "A5" }, parts: true },
  { id: "flow-rotated-long", source: sections(14, (k) => `<div>${para(3)}<div style="transform:rotate(${k * 4 - 20}deg);background:#cde;width:60%">${para(2)}</div>${para(3)}</div>`, () => ""), options: { size: "A5" } },
  { id: "flow-abs-far", source: sections(12, (k) => `<div style="position:relative">${para(6)}<span style="position:absolute;left:10px;top:${k % 2 ? 700 : -300}px;background:#fdd">far ${k}</span></div>`, () => ""), options: { size: "A5" } },
  { id: "flow-relative-tables", source: sections(10, (k) => `<div style="position:relative;left:3px">${table(40)}</div><p style="position:sticky;top:0">${LOREM}</p>`, () => ""), options: { size: "A5" }, parts: true },
  // (orders a part's start cannot be told from: equivalent whether cut or laid out whole)
  { id: "flow-flex-reversed", source: sections(8, (k) => `<div style="display:flex;flex-direction:column-reverse;gap:4px">${para(6)}</div><div style="display:flex;flex-wrap:wrap-reverse;gap:4px">${Array.from({ length: 20 }, (_, i) => `<div style="width:120px;height:40px;order:${(i * 7) % 5};border:1px solid #567">${k}.${i}</div>`).join("")}</div>`, () => ""), options: { size: "A5" } },
  { id: "flow-grid-placed", source: sections(8, (k) => `<div style="display:grid;grid-template-columns:1fr 1fr;grid-auto-flow:dense;gap:4px">${Array.from({ length: 30 }, (_, i) => `<div style="${i % 5 === 0 ? "grid-column:span 2;" : ""}${i % 7 === 3 ? `grid-row:${30 - i};` : ""}border:1px solid #765;padding:4px">${k}.${i}</div>`).join("")}</div>`, () => ""), options: { size: "A5" } },
  { id: "flow-table-rowspan", source: sections(8, (k) => `<table style="width:100%;border-collapse:collapse">${Array.from({ length: 30 }, (_, i) => `<tr>${i % 6 === 0 ? `<td rowspan="4" style="border:1px solid #999">span ${k}.${i}</td>` : i % 6 >= 4 ? "<td>-</td>" : ""}<td style="border:1px solid #999">${k}.${i}</td></tr>`).join("")}</table>`, () => ""), options: { size: "A5" } },
  { id: "flow-stress-no-breaks", source: stressHtml(30).replaceAll("break-after:page", ""), options: stressOpts, chunks: 256 },
  // (default part sizes, children of the flow of 247 elements each: a part lays out several of them, paged.zig `partEnd`)
  { id: "flow-long-tables-default", source: `<div style="font-family:Inter;font-size:11px">${Array.from({ length: 24 }, (_, t) => `<table style="width:100%;border-collapse:collapse;margin:8px 0"><thead><tr><th>Item</th><th>Qty</th><th>Amount</th></tr></thead><tbody>${Array.from({ length: 60 }, (_, r) => { const i = t * 60 + r; return `<tr><td style="border-bottom:1px solid #e2e8f0">Line ${i}</td><td style="text-align:right">${i % 23}</td><td style="text-align:right">${(i * 37) % 997}.50</td></tr>`; }).join("")}</tbody></table>`).join("")}</div>`, options: stressOpts, chunks: 2048, parts: true },
];

const round = (v, k = 100) => Math.round(v * k) / k;
function interactive(d) {
  const pdf = d.pdf;
  const pageIndex = new Map(pdf.pages.map((p, i) => [p.ref?.n ?? i, i]));
  const dest = (v) => {
    const x = pdf.resolve(v);
    if (!Array.isArray(x)) return String(x);
    const pg = x[0] && x[0].n !== undefined ? pageIndex.get(x[0].n) ?? "elem" : String(x[0]);
    return [pg, ...x.slice(1).map((y) => (typeof y === "number" ? round(y) : String(y)))].join(" ");
  };
  const annots = pdf.pages.map((p) => (pdf.resolve(p.dict.Annots) || []).map((a) => {
    const o = pdf.resolve(a);
    const act = pdf.resolve(o.A);
    return [(pdf.resolve(o.Rect) || []).map((v) => round(v)).join(" "), o.Dest ? "D:" + dest(o.Dest) : act ? "URI:" + String(act.URI?.str ?? act.URI) : "", o.StructParent ?? ""].join(" | ");
  }));
  const outline = [];
  const walk = (ref, depth) => {
    let cur = ref; let guard = 0;
    while (cur && guard++ < 10000) {
      const o = pdf.resolve(cur);
      outline.push(`${"  ".repeat(depth)}${o.Title?.str ?? o.Title} -> ${o.Dest ? dest(o.Dest) : ""} ${o.Count ?? ""}`);
      if (o.First) walk(o.First, depth + 1);
      cur = o.Next;
    }
  };
  const ol = pdf.resolve(pdf.catalog.Outlines);
  if (ol && ol.First) walk(ol.First, 0);
  return { annots, outline };
}

let failed = 0;
for (const c of CASES) {
  if (filters.length && !filters.some((f) => c.id.includes(f))) continue;
  const whole = await r.render(c.source, { ...(c.options || {}), chunks: false });
  if (addon) addon.memoryTrace(1);
  const parted = await r.render(c.source, { ...(c.options || {}), chunks: c.chunks ?? 1 });
  const trace = addon ? JSON.parse(addon.memoryTrace(0)) : [];
  const parts = addon ? trace.filter(([l]) => l === "part: drawn").length : null;
  const why = trace.map(([l]) => l).filter((l) => l.startsWith("chunks: whole: ")).map((l) => l.slice(15));
  const problems = [];
  if (c.parts && addon && (parts < 2 || why.length)) problems.push(`drawn in ${parts} part(s)${why.length ? " then whole" : ""}, expected parts`);
  const A = describe(whole); const B = describe(parted);
  if (A.pages.length !== B.pages.length) problems.push(`page count ${A.pages.length} vs ${B.pages.length}`);
  if (JSON.stringify(A.pages.map((p) => p.media)) !== JSON.stringify(B.pages.map((p) => p.media))) problems.push("page boxes differ");
  const ca = canonPages(A); const cb = canonPages(B);
  for (let i = 0; i < Math.min(ca.length, cb.length) && problems.length < 4; i++) {
    const d = firstDiff(flatten(ca[i]), flatten(cb[i]));
    if (d) problems.push(`page ${i + 1} draw list at ${d.at}:\n      whole:  ${d.bm}\n      parted: ${d.ref}`);
  }
  if (A.text !== B.text) problems.push("extracted text differs");
  for (const k of ["tree", "parents", "roots"]) if (A.structure[k] !== B.structure[k]) problems.push(`structure ${k} differs`);
  const ia = interactive(A); const ib = interactive(B);
  if (JSON.stringify(ia.annots) !== JSON.stringify(ib.annots)) problems.push(`annotations differ:\n      whole:  ${JSON.stringify(ia.annots).slice(0, 300)}\n      parted: ${JSON.stringify(ib.annots).slice(0, 300)}`);
  if (JSON.stringify(ia.outline) !== JSON.stringify(ib.outline)) problems.push(`outline differs:\n      whole:  ${ia.outline.join(" ; ").slice(0, 300)}\n      parted: ${ib.outline.join(" ; ").slice(0, 300)}`);
  const bytesSame = Buffer.compare(Buffer.from(whole), Buffer.from(parted)) === 0;
  if (problems.length) failed++;
  console.log(`${problems.length ? "FAIL" : "PASS"}  ${c.id.padEnd(24)} ${A.pages.length} pages, parts ${parts ?? "?"}${bytesSame ? ", byte-identical" : ""}${why.length ? " (whole: " + why.join("; ") + ")" : ""}`);
  for (const p of problems) console.log("      - " + p);
}
console.log(failed ? `\n${failed} case(s) differ` : "\nall cases equivalent");
process.exitCode = failed ? 1 : 0;
