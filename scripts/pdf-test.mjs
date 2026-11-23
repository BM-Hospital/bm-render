// Tests of the PDF plumbing (renderPdf / measurePdf, options, JS API) against the pdf build profile.
//
//   node scripts/pdf-test.mjs [--no-build]      (npm run test:pdf)
//   BM_RENDER_BACKEND=wasm | native selects the backend of bm-render/pdf (default: the native addon when it is built /
//   installed, else wasm); the checks are the same and must pass on both.
//
// Builds js/bm_render.pdf.wasm first (`node scripts/build.mjs --profile=pdf`; --no-build reuses the file in js/),
// then drives the public entries on Node: bm-render/pdf (js/node-pdf.mjs) for node-tree and HTML input, option
// validation errors, attachments, prepare handles and measure; checks every produced PDF with `pdftotext`
// (poppler; skipped with a note if not installed); and checks that bm-render/full (no `pdf` feature) rejects
// renderPdf with the "not supported by this build" error, both from the JS wrapper and from the raw wasm export.
import { spawnSync } from "node:child_process";
import { findBin } from "../bench/pdf/lib/tools.mjs";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = new Set(process.argv.slice(2));

if (!args.has("--no-build")) {
  const r = spawnSync(process.execPath, [path.join(root, "scripts", "build.mjs"), "--profile=pdf"], { cwd: root, stdio: "inherit" });
  if (r.status !== 0) { console.error("FAIL  build of the pdf profile"); process.exit(1); }
}

const pdfMod = await import(pathToFileURL(path.join(root, "js", "node-pdf.mjs")).href);
const fullMod = await import(pathToFileURL(path.join(root, "js", "node-full.mjs")).href);
const { PdfRenderer, PageNumber, TotalPages, TargetPageNumber } = pdfMod;
console.log(`bm-render/pdf backend: ${pdfMod.backend} (BM_RENDER_BACKEND=wasm | native selects one; both must pass)`);

let fails = 0;
let passes = 0;
const check = (cond, msg) => { console.log(`${cond ? "PASS" : "FAIL"}  ${msg}`); cond ? passes++ : fails++; };
async function rejects(promiseFn, re, msg) {
  try { await promiseFn(); check(false, `${msg} (did not throw)`); }
  catch (e) { check(re.test(String(e && e.message)), `${msg}: ${String(e && e.message).slice(0, 150)}`); }
}

const popplerText = findBin("poppler", "pdftotext") || "pdftotext";
const tmp = mkdtempSync(path.join(os.tmpdir(), "bm-pdf-test-"));
let pdftotextMissing = false;
/** Opens the PDF with poppler's pdftotext: exit status 0 and nothing on stderr. */
function pdftotext(bytes, name) {
  const file = path.join(tmp, name + ".pdf");
  writeFileSync(file, bytes);
  const r = spawnSync(popplerText, [file, "-"], { encoding: "utf8", windowsHide: true });
  if (r.error && r.error.code === "ENOENT") { pdftotextMissing = true; return { skipped: true }; }
  return { ok: r.status === 0 && r.stderr.trim() === "", stderr: r.stderr.trim(), text: r.stdout };
}
const latin1 = (b) => new TextDecoder("latin1").decode(b);
const mediaBox = (b) => { const m = /\/MediaBox\[0 0 ([\d.]+) ([\d.]+)\]/.exec(latin1(b)); return m ? [Number(m[1]), Number(m[2])] : null; };
function isPdf(bytes, name, box) {
  check(bytes instanceof Uint8Array && latin1(bytes.subarray(0, 5)) === "%PDF-", `${name}: starts with %PDF-`);
  if (box) {
    const mb = mediaBox(bytes);
    check(mb && Math.abs(mb[0] - box[0]) < 0.01 && Math.abs(mb[1] - box[1]) < 0.01, `${name}: MediaBox ${mb} ~ ${box}`);
  }
  const t = pdftotext(bytes, name.replace(/\W+/g, "_"));
  if (!t.skipped) check(t.ok, `${name}: pdftotext opens it${t.ok ? "" : " (" + t.stderr + ")"}`);
}

const PX = 72 / 96;
const node = { type: "container", style: { display: "flex", width: "100%", height: "100%", backgroundColor: "#fff" },
  children: [{ type: "text", text: "Hello PDF", style: { fontSize: 32 } }] };
const sized = { type: "container", style: { width: 120, height: 30 } };
const html = `<style>.title { font-size: 32px }</style><div class="title">Hello PDF</div>`;

// ---- features of the loaded binaries
check(pdfMod.profile === "pdf" && pdfMod.features.pdf === true, "pdf build: profile 'pdf', features.pdf");
check(Object.values(pdfMod.features).every(Boolean), "pdf build: every feature on (full + pdf)");
check(fullMod.features.pdf === false && fullMod.features.renderSvg === true, "full build: features.pdf is off");
{
  const { features: fc } = await import(pathToFileURL(path.join(root, "js", "node-core.mjs")).href);
  const { features: fs_ } = await import(pathToFileURL(path.join(root, "js", "node-standard.mjs")).href);
  check(!fc.pdf && !fs_.pdf, "core and standard builds: features.pdf is off");
}

const r = new PdfRenderer();
// text is drawn now: a render whose text no registered font covers fails (uncoveredText "error")
const refRoot = path.join(root, "tests", "upstream", "takumi");
const refFont = (f) => new Uint8Array(readFileSync(path.join(refRoot, f)));
r.registerFont(refFont("assets/fonts/archivo/Archivo-VariableFont_wdth,wght.ttf"));
r.registerFont(refFont("assets/fonts/noto-sans/NotoSansTC-VariableFont_wght.woff2"));

// ---- node input
isPdf(await r.render(node, { viewport: { width: 600, height: 300 } }), "node tree, viewport 600x300", [600 * PX, 300 * PX]);
isPdf(await r.render(node), "node tree, default paged A4", [595.2756, 841.8898]);
isPdf(await r.render(node, { size: "letter", landscape: true, margin: 24 }), "node tree, letter landscape", [11 * 72, 8.5 * 72]);
isPdf(await r.render(node, { size: { width: 400, height: 300 } }), "node tree, explicit size", [300, 225]);
isPdf(await r.render(node, { size: "A3" }), "node tree, size 'A3' (case-insensitive)", [297 / 25.4 * 72, 420 / 25.4 * 72]);
isPdf(r.renderSync(sized, { viewport: { width: 200 } }), "node tree, viewport without height = content height", [200 * PX, 30 * PX]);
isPdf(await r.render({ json: JSON.stringify(sized) }, { viewport: { width: 100, height: 50 } }), "{ json } source", [75, 37.5]);

// ---- HTML input
isPdf(await r.render(html, { viewport: { width: 600, height: 300 } }), "HTML, viewport", [450, 225]);
isPdf(await r.render(html), "HTML, default paged A4", [595.2756, 841.8898]);
isPdf(await r.render(`<div class="x">x</div>`, { viewport: { width: 100, height: 100 }, css: ".x { color: red }", cssVariables: { accent: "red" } }), "HTML + css + cssVariables");

// ---- the graphics pass (content streams inflated; takumi-pdf's operators and objects)
{
  const { inflateSync } = await import("node:zlib");
  /** Every stream of the file, inflated when Flate-encoded, as latin1 text. */
  const streams = (bytes) => {
    const s = latin1(bytes); const out = [];
    let at = 0;
    for (;;) {
      const i = s.indexOf("stream\n", at); if (i < 0) break;
      const j = s.indexOf("\nendstream", i); if (j < 0) break;
      const dict = s.slice(s.lastIndexOf("obj", i), i);
      const data = Buffer.from(bytes.subarray(i + 7, j));
      let text = data.toString("latin1");
      if (/FlateDecode/.test(dict) && !/Subtype\/Image|XRef|ObjStm/.test(dict)) { try { text = inflateSync(data).toString("latin1"); } catch {} }
      out.push(dict + "\n" + text);
      at = j + 10;
    }
    return out.join("\n");
  };
  const has = (bytes, needle, msg) => check(streams(bytes).includes(needle) || latin1(bytes).includes(needle), `${msg}: ${needle.replace(/\n/g, "\\n")}`);
  const box = (style) => ({ type: "container", style: { display: "flex", width: "100%", height: "100%", padding: 20, backgroundColor: "#fff" }, children: [{ type: "container", style: { width: 100, height: 60, ...style } }] });
  const vp = { viewport: { width: 200, height: 100 } };

  const solid = await r.render(box({ backgroundColor: "#e11d48" }), vp);
  isPdf(solid, "graphics: solid box", [150, 75]);
  has(solid, "q 0.75 0 0 -0.75 0 75 cm 1 1 1 rg 0 0 200 100 re\nf\nQ", "page transform + white page box");
  has(solid, "0.8824 0.1137 0.2824 rg 20 20 100 60 re\nf", "box fill in CSS px");
  const rounded = await r.render(box({ backgroundColor: "#e11d48", border: "4px solid #111827", borderRadius: 12 }), vp);
  has(rounded, "\nf*\nQ", "border ring as an even-odd fill");
  const faded = await r.render(box({ backgroundColor: "#e11d48", opacity: 0.5 }), vp);
  has(faded, "/Type/ExtGState/ca 0.5/CA 0.5", "opacity group state");
  has(faded, "/Group<</Type/Group/S/Transparency/I true/CS/DeviceRGB>>", "transparency group XObject");
  const grad = await r.render(box({ backgroundImage: "linear-gradient(90deg, #ff0000, rgba(0, 0, 255, 0.5))" }), vp);
  has(grad, "/ShadingType 2/ColorSpace/DeviceRGB", "axial shading");
  has(grad, "/Type/Mask/S/Luminosity", "stop opacity soft mask");
  const conic = await r.render(box({ backgroundImage: "conic-gradient(red, blue, red)" }), vp);
  has(conic, "/FunctionType 4", "conic gradient as a PostScript function");
  const shadow = await r.render(box({ backgroundColor: "#fff", boxShadow: "0 4px 12px rgba(0,0,0,0.4)" }), vp);
  has(shadow, "W*\nn", "outer shadow clipped out of the box");
  const clipped = await r.render(box({ backgroundColor: "#e11d48", clipPath: "circle(30px)" }), vp);
  has(clipped, "\nW\nn", "clip-path as a clip path");
  const filtered = await r.render(box({ backgroundColor: "#e11d48", filter: "grayscale(1)" }), vp);
  has(filtered, "0.2902 0.2902 0.2902 rg", "colour filter folded into the fill");
  await rejects(() => r.render(box({ backgroundColor: "red", filter: "blur(2px)" }), vp), /A PDF cannot draw filter: blur\(2px\)/, "blur filter fails the render (takumi-pdf)");
  const jpeg = readFileSync(path.join(refRoot, "takumi-pdf", "tests", "images", "checker.jpg"));
  const photo = await r.render({ type: "image", src: "photo", width: 40, height: 40 }, { viewport: { width: 40, height: 40 }, images: [{ src: "photo", data: new Uint8Array(jpeg) }] });
  has(photo, "/Filter/DCTDecode", "JPEG embedded as is");
  check(latin1(photo).includes(latin1(jpeg.subarray(0, 64))), "the original JPEG bytes are in the file");
  const tile = await r.render(box({ backgroundImage: "linear-gradient(#f00, #00f)", backgroundSize: "20px 20px" }), vp);
  has(tile, "/PatternType 1", "repeated layer as a tiling pattern");
  isPdf(tile, "graphics: tiling pattern file opens");
}

// ---- options that parse end to end (the first pages of the effect: graphics only)
const bandNode = { type: "container", style: { fontSize: 10 }, children: [{ type: "text", text: "page" }, PageNumber(), TotalPages({ format: "lower-roman" })] };
isPdf(await r.render(node, {
  size: "a4", margin: { top: "auto", bottom: 30 }, header: bandNode, footer: "<p>footer</p>",
  pages: { first: { header: false }, even: { footer: bandNode }, last: { footer: "<b>end</b>" } },
  pageRanges: [1, { from: 3 }], backgroundColor: "#eee", outline: true, lang: "en",
  fontFamilies: ["Inter"], metadata: { title: "T", authors: ["A"], keywords: ["k"], creationDate: "2026-08-06T01:02:03" },
}), "paged with bands, page rules, ranges, metadata");
check(TargetPageNumber({ href: "#a" }).tagName === "a" && TargetPageNumber({}).className === "targetPageNumber", "primitives build nodes");
const att = new Uint8Array([0, 1, 2, 255]);
isPdf(await r.render(node, { attachments: [{ name: "a.bin", data: att, mimeType: "application/octet-stream" }, { name: "b.xml", data: "<x/>" }] }), "binary + text attachments (plain PDF)");
isPdf(await r.render("<h1>Report</h1><p>body</p>", { pdfa: "3b", metadata: { title: "T", creationDate: "2026-01-01" }, tagged: "ua1",
  attachments: [{ name: "factur-x.xml", data: att.buffer, mimeType: "application/xml", description: "invoice", relationship: "data" }] }), "pdfa 3b + ua1 + ArrayBuffer attachment");
isPdf(await r.render("<h1>Report</h1><p>body</p>", { pdfa: "4", tagged: "ua2", lang: "en", metadata: { title: "T", creationDate: "2026-01-01" } }), "pdfa 4 + ua2");
isPdf(await r.render(node, { uncoveredText: "blank", tagged: false }), "uncoveredText blank, untagged");
{
  const prepared = await r.prepare(html, { viewport: { width: 300, height: 100 } });
  isPdf(await r.render(prepared), "prepared handle", [225, 75]);
  isPdf(await r.render(prepared, { viewport: { width: 400, height: 100 } }), "prepared handle, options merged over it", [300, 75]);
}
{
  const logo = Uint8Array.from(Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==", "base64"));
  isPdf(await r.render({ type: "container", children: [{ type: "image", src: "https://x/logo.png", width: 10, height: 10 }] },
    { images: [{ src: "https://x/logo.png", data: logo }], header: { type: "container", children: [{ type: "image", src: logo, width: 5, height: 5 }] } }), "images by key and a binary band image");
}

// ---- text and pages (fonts subset into the file; pagination; text extraction with pdftotext -f N -l N)
{
  const pageCount = (b) => (latin1(b).match(/\/Type\/Page[^s]/g) || []).length;
  /** The text of page `n` (1-based) as pdftotext extracts it, white space collapsed. */
  const pageText = (bytes, name, n) => {
    const file = path.join(tmp, name + ".pdf");
    writeFileSync(file, bytes);
    const t = spawnSync(popplerText, ["-f", String(n), "-l", String(n), "-enc", "UTF-8", file, "-"], { encoding: "utf8", windowsHide: true });
    if (t.error && t.error.code === "ENOENT") { pdftotextMissing = true; return null; }
    return t.stdout.replace(/\s+/g, " ").trim();
  };
  /** Every string of `want[i]` is on page i + 1, in that order. */
  const pagesSay = (bytes, name, want) => {
    want.forEach((strings, i) => {
      const t = pageText(bytes, name, i + 1);
      if (t === null) return;
      let at = 0; let ok = true; let missing = "";
      for (const s of strings) { const k = t.indexOf(s, at); if (k < 0) { ok = false; missing = s; break; } at = k + s.length; }
      check(ok, `${name}: page ${i + 1} reads ${JSON.stringify(strings)}${ok ? "" : ` (missing ${JSON.stringify(missing)} in ${JSON.stringify(t.slice(0, 200))})`}`);
    });
  };
  const fixture = (f) => readFileSync(path.join(refRoot, "takumi-pdf", "fixtures", f), "utf8");

  // takumi-pdf's HTML fixtures through the public API (page counts as takumi's goldens)
  const invoice = await r.render(fixture("invoice.html"), { size: "a4", margin: { top: 36, right: 36, bottom: "auto", left: 36 }, footer: fixture("invoice-footer.html") });
  isPdf(invoice, "invoice.html (A4, 36 px margins, footer band)", [595.2756, 841.8898]);
  check(pageCount(invoice) === 2, `invoice.html: ${pageCount(invoice)} pages (takumi: 2)`);
  pagesSay(invoice, "invoice", [["RIDGELINE", "Project \"atlas\" (07/2026)", "RX41 Cloud Server"], ["Project \"atlas-analytics\" (07/2026)", "RX52 Cloud Server", "Volume 120 GB"]]);
  const report = await r.render(fixture("report.html"), { size: "a4" });
  check(pageCount(report) === 3, `report.html: ${pageCount(report)} pages (takumi: 3)`);
  pagesSay(report, "report", [["Annual report", "Revenue", "Revenue grew across all segments."], ["Costs", "Costs stayed flat."], ["Appendix", "Raw data lives at example.com/data."]]);

  // a long table repeats its header group on every page
  const rows = Array.from({ length: 30 }, (_, k) => `<tr><td>Item ${k + 1}</td><td>Description of item ${k + 1}</td><td>${(k + 1) * 3}</td></tr>`).join("");
  const table = await r.render(`<table style="width: 100%; font-size: 12px; color: #141414"><thead><tr style="background: #e2e8f0"><th>Name</th><th>Description</th><th>Qty</th></tr></thead><tbody>${rows}</tbody></table>`, { size: { width: 400, height: 300 }, margin: 24 });
  check(pageCount(table) === 3, `long table: ${pageCount(table)} pages (3)`);
  pagesSay(table, "table", [["Name", "Item 1 ", "Qty"], ["Name", "Item 14", "Qty"], ["Name", "Item 30", "Qty"]]);

  // lines: every line on exactly one page, as text
  const lines = { type: "container", style: { display: "flex", flexDirection: "column", width: "100%" }, children: Array.from({ length: 40 }, (_, k) => ({ type: "text", text: `Line ${k + 1} of the paginated report body`, style: { fontSize: 16, color: "#141414" } })) };
  const paged = await r.render(lines, { size: { width: 400, height: 300 }, margin: 24 });
  check(pageCount(paged) === 3, `40 lines on 400 x 300 pages: ${pageCount(paged)} pages (takumi paged-lines: 3)`);
  {
    const all = [1, 2, 3].map((n) => pageText(paged, "lines", n));
    if (all[0] !== null) {
      const seen = all.map((t) => (t.match(/Line \d+ /g) || []).length);
      check(seen[0] + seen[1] + seen[2] === 40 && all.every((t, i) => i === 0 || !t.includes("Line 1 ")), `every line extracted once across the pages (${seen.join(" + ")})`);
    }
  }
  // pageRanges keep pages 1 and 3
  const ranged = await r.render(lines, { size: { width: 400, height: 300 }, margin: 24, pageRanges: [1, { from: 3, to: 3 }] });
  check(pageCount(ranged) === 2, `pageRanges [1, 3]: ${pageCount(ranged)} pages`);
  pagesSay(ranged, "ranged", [["Line 1 of"], ["Line 40 of"]]);
  await rejects(() => r.render(lines, { size: { width: 400, height: 300 }, margin: 24, pageRanges: [{ from: 5 }] }), /The page ranges select none of the document's 3 pages/, "pageRanges past the end");

  // ---- header / footer bands and page counters (takumi-pdf headers.mdx, pagination.mdx)
  {
    const geo = { size: { width: 400, height: 300 }, margin: 24 };
    const footer = `<div style="display: flex; column-gap: 3px; font-size: 12px; color: #141414;">Page <span class="pageNumber"></span> / <span class="totalPages"></span></div>`;
    const banded = await r.render(lines, { ...geo, footer });
    check(pageCount(banded) === 3, `footer band: ${pageCount(banded)} pages (3)`);
    pagesSay(banded, "footer-n-of-m", [["Line 1 of", "Page 1 / 3"], ["Page 2 / 3"], ["Line 40 of", "Page 3 / 3"]]);
    // the footer is not drawn in the content area: the text of every line is still there once
    {
      const t = [1, 2, 3].map((n) => pageText(banded, "footer-lines", n));
      if (t[0] !== null) check(t.reduce((s, x) => s + (x.match(/Line \d+ /g) || []).length, 0) === 40, "footer band: the 40 body lines are all still drawn");
    }
    // pageRanges keep the full-output numbers
    const rangedBand = await r.render(lines, { ...geo, footer, pageRanges: [1, { from: 3, to: 3 }] });
    check(pageCount(rangedBand) === 2, `footer band + pageRanges [1, 3]: ${pageCount(rangedBand)} pages`);
    pagesSay(rangedBand, "footer-ranged", [["Page 1 / 3"], ["Page 3 / 3"]]);
    // node-tree bands from the primitives, with counter styles, and a header in the top margin
    const nodeBand = { type: "container", style: { display: "flex", columnGap: 4, fontSize: 10 }, children: [{ type: "text", text: "Sheet" }, PageNumber({ format: "upper-roman" }), { type: "text", text: "of" }, TotalPages({ format: "lower-alpha" })] };
    const headed = await r.render(lines, { ...geo, header: nodeBand });
    pagesSay(headed, "header-node-band", [["Sheet I of c", "Line 1 of"], ["Sheet II of c"], ["Sheet III of c"]]);
    // per-page rules: first / last win over odd / even, a field left out falls through, false = none
    const many = { type: "container", style: { display: "flex", flexDirection: "column", width: "100%" }, children: Array.from({ length: 5 }, (_, k) => ({ type: "text", text: `Chapter ${k + 1}`, style: { fontSize: 16, breakBefore: k ? "page" : "auto" } })) };
    const ruled = await r.render(many, { size: geo.size, header: "<b>DOCHEAD</b>", footer: "<i>DOCFOOT</i>",
      pages: { first: { header: false }, last: { footer: "<i>LASTFOOT</i>" }, even: { header: "<b>EVENHEAD</b>" }, odd: { footer: false } } });
    check(pageCount(ruled) === 5, `page rules document: ${pageCount(ruled)} pages (5)`);
    {
      const t = [1, 2, 3, 4, 5].map((n) => pageText(ruled, "page-rules", n));
      if (t[0] !== null) {
        const has = (n, s) => t[n - 1].includes(s);
        check(!has(1, "HEAD") && !has(1, "DOCFOOT"), `page 1: first.header false, odd.footer false (${JSON.stringify(t[0])})`);
        check(has(2, "EVENHEAD") && has(2, "DOCFOOT"), `page 2: even.header, the document's footer (${JSON.stringify(t[1])})`);
        check(has(3, "DOCHEAD") && !has(3, "FOOT"), `page 3: the document's header (odd sets none), odd.footer false (${JSON.stringify(t[2])})`);
        check(has(4, "EVENHEAD") && has(4, "DOCFOOT"), `page 4: even rules (${JSON.stringify(t[3])})`);
        check(has(5, "DOCHEAD") && has(5, "LASTFOOT") && !has(5, "DOCFOOT"), `page 5: last.footer wins over odd.footer false (${JSON.stringify(t[4])})`);
      }
    }
    // a band image (bytes) is drawn
    {
      const logo = Uint8Array.from(Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==", "base64"));
      const imaged = await r.render(lines, { ...geo, footer: { type: "container", children: [{ type: "image", src: logo, width: 16, height: 16 }] } });
      check(/\/Subtype\/Image/.test(latin1(imaged)) && pageCount(imaged) === 3, "band image: an image XObject, one per document (deduplicated across 3 pages)");
      check((latin1(imaged).match(/\/Subtype\/Image/g) || []).length === 1, "band image: one image object for every page");
    }
    // counters in the content flow: the page they land on
    const flow = await r.render(`<main><p style="height: 1100px;"></p><p style="font-size: 12px;">page <span class="pageNumber"></span> of <span class="totalPages"></span></p></main>`, { size: "a4" });
    pagesSay(flow, "content-counters", [[], ["page 2 of 2"]]);
    // counters in a repeating fixed box: each page's own numbers
    const fixedBox = await r.render(`<main><div style="position: fixed; bottom: 10px; left: 10px; font-size: 12px;">sheet <span class="pageNumber"></span>/<span class="totalPages"></span></div><p style="height: 900px;"></p><p style="height: 900px;"></p></main>`, { size: "a4" });
    pagesSay(fixedBox, "fixed-counters", [["sheet 1/2"], ["sheet 2/2"]]);
    // TargetPageNumber: the page an anchor lands on (a table of contents)
    const toc = { type: "container", style: { display: "flex", flexDirection: "column", width: "100%", fontSize: 14 }, children: [
      ...["alpha", "beta", "gamma"].map((id) => ({ type: "container", tagName: "a", attributes: { href: `#${id}` }, style: { display: "flex", columnGap: 4 }, children: [{ type: "text", text: `TOC ${id}` }, TargetPageNumber()] })),
      { type: "container", style: { display: "flex", columnGap: 4 }, children: [{ type: "text", text: "TOC direct" }, TargetPageNumber({ href: "#gamma", format: "upper-roman" })] },
      ...["alpha", "beta", "gamma"].map((id) => ({ type: "text", id, text: `Section ${id}`, style: { breakBefore: "page", fontSize: 18 } })),
    ] };
    const tocPdf = await r.render(toc, geo);
    pagesSay(tocPdf, "target-counters", [["TOC alpha 2", "TOC beta 3", "TOC gamma 4", "TOC direct IV"], ["Section alpha"]]);
    // @page rules: size / margins for every page, :first margins (same width); :left / :right are not supported
    {
      const css = "@page { size: A5 landscape; margin: 12mm } @page :first { margin-top: 40mm }";
      const styled = await r.render(lines, { css, footer });
      isPdf(styled, "@page size A5 landscape", [210 / 25.4 * 72, 148 / 25.4 * 72]);
      const plain = await r.render(lines, { css: "@page { size: A5 landscape; margin: 12mm }", footer });
      const firstText = pageText(styled, "at-page-first", 1); const plainText = pageText(plain, "at-page-plain", 1);
      const n1 = firstText === null ? 0 : (firstText.match(/Line \d+ /g) || []).length;
      const n0 = plainText === null ? 0 : (plainText.match(/Line \d+ /g) || []).length;
      if (firstText !== null) check(n1 > 0 && n0 > n1, `@page :first margin-top: fewer lines on page 1 (${n1}) than without the :first rule (${n0})`);
      const viaHtml = await r.render(`<style>@page { size: 300px 200px; margin: 0 }</style><p>x</p>`);
      isPdf(viaHtml, "@page in an HTML <style>", [225, 150]);
    }
    // measure: a band with three-digit counters, the height an auto margin reserves (+ 15pt)
    {
      const narrow = `<div style="width: 90px; font-size: 14px;">Page <span class="pageNumber"></span> of <span class="totalPages"></span></div>`;
      const m3 = await r.measure(narrow, { size: { width: 320, height: 240 } });
      const m1 = await r.measure(`<div style="width: 90px; font-size: 14px;">Page 1 of 1</div>`, { size: { width: 320, height: 240 } });
      check(m3.height > m1.height, `measure fills three-digit counters (wraps: ${m3.height} > ${m1.height})`);
      const tall = `<div style="height: 64px; font-size: 12px;">Page <span class="pageNumber"></span></div>`;
      const mt = await r.measure(tall, { size: { width: 400, height: 300 } });
      const auto = await r.render(lines, { size: { width: 400, height: 300 }, header: tall });
      const manual = await r.render(lines, { size: { width: 400, height: 300 }, header: tall, margin: { top: mt.height + 20 } });
      check(mt.height === 64 && latin1(auto) === latin1(manual), `measure agrees with render: auto margin = measured ${mt.height} + 20`);
    }
  }

  // ligatures, Vietnamese, Arabic: ToUnicode / ActualText extract the source text
  const scripts = new PdfRenderer();
  scripts.registerFont(refFont("assets/fonts/archivo/Archivo-VariableFont_wdth,wght.ttf"));
  scripts.registerFont(refFont("assets/fonts/sil/scheherazade-new-v17-arabic-regular.woff2"));
  const multi = await scripts.render(`<div style="font-size: 24px">
      <p>Difficult office traffic affix</p>
      <p>Tiếng Việt có dấu: Nguyễn Trãi</p>
      <p lang="ar" dir="rtl" style="font-family: 'Scheherazade New'">نص عربي</p>
    </div>`, { viewport: { width: 500, height: 260 } });
  isPdf(multi, "ligatures + Vietnamese + Arabic");
  {
    const t = pageText(multi, "scripts", 1);
    if (t !== null) {
      check(t.includes("Difficult office traffic affix"), `ligatures extract as their letters: ${JSON.stringify(t.slice(0, 40))}`);
      check(t.includes("Tiếng Việt có dấu: Nguyễn Trãi"), "Vietnamese extracts with its diacritics");
      check(t.includes("نص عربي") || t.includes("يبرع صن"), `Arabic extracts: ${JSON.stringify(t.slice(-20))}`);
    }
  }
  check(/\/Type\/Font\/Subtype\/Type0/.test(latin1(multi)) || /Type0/.test(latin1(multi)), "CID fonts embedded");

  // uncoveredText: a character no font draws
  const deva = { type: "text", text: "abक", style: { fontSize: 20 } };
  await rejects(() => r.render(deva, { viewport: { width: 100, height: 40 } }), /No font the text can use draws क \(U\+0915\)/, "uncoveredText error (default)");
  // (met in a band and on later pages, whose drawing memory is rewound before the message is made)
  await rejects(() => r.render("<p>one</p><p style=\"break-before:page\">two</p><p style=\"break-before:page\">three</p>", { size: "a5", footer: "<div>ख क ग</div>" }), /No font the text can use draws ख \(U\+0916\), क \(U\+0915\), ग \(U\+0917\)\./, "uncoveredText error from a band on several pages names the right characters");
  const ph = await r.render(deva, { viewport: { width: 100, height: 40 }, uncoveredText: "placeholder" });
  isPdf(ph, "uncoveredText placeholder");
  const bl = await r.render(deva, { viewport: { width: 100, height: 40 }, uncoveredText: "blank" });
  isPdf(bl, "uncoveredText blank");
  {
    const tp = pageText(ph, "placeholder", 1); const tb = pageText(bl, "blank", 1);
    if (tp !== null) check(tb.startsWith("ab") && tp.startsWith("ab") && latin1(ph).length !== latin1(bl).length, `placeholder draws .notdef, blank draws nothing ("${tp}" / "${tb}")`);
  }
}

// ---- [interactive] links, outline, metadata / XMP, attachments (src/pdf/interactive.zig, metadata.zig, attach.zig)
{
  const { inflateSync } = await import("node:zlib");
  /** Top-level objects: number -> { body (latin1 text before any stream), data (stream bytes, inflated) }. */
  const objects = (bytes) => {
    const s = latin1(bytes); const out = new Map(); const re = /(\d+) 0 obj\n/g; let m;
    while ((m = re.exec(s))) {
      const start = m.index + m[0].length; const end = s.indexOf("\nendobj", start);
      const si = s.indexOf("\nstream\n", start);
      if (si >= 0 && si < end) {
        const body = s.slice(start, si); const len = +(/\/Length (\d+)/.exec(body) || [0, 0])[1];
        let data = Buffer.from(bytes.subarray(si + 8, si + 8 + len));
        if (/\/Filter\/FlateDecode/.test(body)) data = inflateSync(data);
        out.set(+m[1], { body, data }); re.lastIndex = si + 8 + len;
      } else out.set(+m[1], { body: s.slice(start, end) });
    }
    return out;
  };
  const refOf = (body, key) => { const m = new RegExp(`/${key} (\\d+) 0 R`).exec(body); return m ? +m[1] : null; };
  /** Page object numbers in /Kids order, and each page's annotations parsed. */
  const annotsOf = (bytes) => {
    const objs = objects(bytes);
    const tree = [...objs.values()].find((o) => o.body.startsWith("<</Type/Pages"));
    const kids = [...tree.body.matchAll(/(\d+) 0 R/g)].map((k) => +k[1]);
    return kids.map((pn, pi) => {
      const pb = objs.get(pn).body; const am = /\/Annots\[([^\]]*)\]/.exec(pb);
      return (am ? [...am[1].matchAll(/(\d+) 0 R/g)].map((k) => +k[1]) : []).map((an) => {
        const b = objs.get(an).body;
        const rect = /\/Rect\[([^\]]*)\]/.exec(b)[1].split(" ").map(Number);
        const uri = /\/URI\(([^)]*)\)/.exec(b);
        const dn = refOf(b, "Dest"); let dest = null;
        if (dn) { const d = /\[(\d+) 0 R\/XYZ ([-\d.]+) ([-\d.]+) 0\]/.exec(objs.get(dn).body); dest = { page: kids.indexOf(+d[1]), x: +d[2], y: +d[3] }; }
        return { page: pi, body: b, rect, uri: uri ? uri[1] : null, dest };
      });
    }).flat();
  };
  const textOf = (v) => v.startsWith("<FEFF") ? Buffer.from(v.slice(5, -1), "hex").swap16().toString("utf16le") : v.slice(1, -1);

  // external links: a block link (whole box) and an inline one (per line run)
  const ext = await r.render(`<div style="font-size: 14px; width: 300px">
      <a href="https://example.com/block" style="display: block; height: 40px">Block link</a>
      <p>Read <a href="https://example.com/inline">the inline link</a> and <a href="ftp://ignored">not this</a> or <a href="#none">this</a>.</p>
    </div>`, { viewport: { width: 400, height: 200 } });
  isPdf(ext, "links: external");
  {
    const an = annotsOf(ext);
    check(an.length === 2, `links: two annotations (block + inline; ftp and a missing #id dropped): ${an.length}`);
    check(an[0] && an[0].uri === "https://example.com/block" && /\/Border\[0 0 0\]/.test(an[0].body) && /\/F 4/.test(an[0].body) && /\/A<<\/Type\/Action\/S\/URI\/URI\(/.test(an[0].body), "links: block link is a URI action with /Border[0 0 0] /F 4");
    check(an[0] && Math.abs(an[0].rect[2] - an[0].rect[0] - 300 * PX) < 0.01 && Math.abs(an[0].rect[3] - an[0].rect[1] - 40 * PX) < 0.01, `links: block link covers the box (300 x 40 px): ${an[0] && an[0].rect}`);
    check(an[1] && an[1].uri === "https://example.com/inline" && an[1].rect[2] - an[1].rect[0] < 200 * PX && an[1].rect[3] <= 150, `links: inline link covers its run: ${an[1] && an[1].rect}`);
  }
  // internal links across pages, a link box broken over a page break, the outline
  const doc = `<div style="font-size: 14px">
      <h1>Report</h1>
      <a href="#target" style="display: block">Jump to the target</a>
      <a href="https://example.com/tall" style="display: block; height: 400px; background: #eee">tall link</a>
      <h2>Part one</h2><h3>Detail A</h3><h3>Detail B</h3>
      <h2 style="break-before: page">Part two</h2>
      <h1 id="target" style="break-before: page; margin: 0">Appendix</h1>
    </div>`;
  const paged = await r.render(doc, { size: { width: 400, height: 300 }, margin: 20, outline: true });
  isPdf(paged, "links + outline: paged");
  {
    const an = annotsOf(paged);
    const internal = an.filter((a) => a.dest);
    const tall = an.filter((a) => a.uri === "https://example.com/tall");
    const pages = (latin1(paged).match(/\/Type\/Page[^s]/g) || []).length;
    check(internal.length === 1 && internal[0].page === 0 && internal[0].dest.page === pages - 1, `links: #target from page 1 lands on the last page (${pages}): ${JSON.stringify(internal.map((a) => a.dest))}`);
    check(internal[0] && Math.abs(internal[0].dest.x - 20 * PX) < 0.01 && Math.abs(internal[0].dest.y - (300 - 20) * PX) < 0.5, `links: destination at the content box's top-left (15, 210 pt): ${internal[0] && JSON.stringify(internal[0].dest)}`);
    check(tall.length === 2 && tall[0].page === 0 && tall[1].page === 1, `links: a link broken over a page break annotates both pages: ${tall.map((a) => a.page)}`);
    const objs = objects(paged);
    const items = [...objs.values()].filter((o) => /^<<\/Parent \d+ 0 R/.test(o.body) && /\/Title/.test(o.body));
    const title = (o) => textOf(/\/Title(\([^)]*\)|<[^>]*>)/.exec(o.body)[1]);
    const root = [...objs.values()].find((o) => o.body.startsWith("<</Type/Outlines"));
    const byNum = new Map([...objs.entries()].map(([n, o]) => [o, n]));
    const kids = (parentNum) => items.filter((o) => refOf(o.body, "Parent") === parentNum);
    const rootNum = byNum.get(root);
    const tree = (num) => kids(num).map((o) => ({ t: title(o), c: (/\/Count (-?\d+)/.exec(o.body) || [0, "0"])[1], k: tree(byNum.get(o)) }));
    const t = root ? tree(rootNum) : [];
    check(root && /\/Count 2/.test(root.body) && t.length === 2 && t[0].t === "Report" && t[1].t === "Appendix", `outline: two h1 at the top: ${JSON.stringify(t.map((x) => x.t))}`);
    check(t[0] && t[0].c === "-2" && t[0].k.map((x) => x.t).join("|") === "Part one|Part two" && t[0].k[0].c === "-2" && t[0].k[0].k.map((x) => x.t).join("|") === "Detail A|Detail B", `outline: h2 under h1, h3 under h2, closed counts: ${JSON.stringify(t[0])}`);
    check(/\/Outlines \d+ 0 R/.test(latin1(paged)), "outline: catalog /Outlines");
    const noOutline = await r.render(doc, { size: { width: 400, height: 300 }, margin: 20 });
    check(!/\/Outlines/.test(latin1(noOutline)), "outline: none without outline: true");
  }
  // metadata: Info (UTF-16 for non-ASCII), XMP (UTF-8, escaped), dates, /Lang, the derived document id
  const md = await r.render(node, { viewport: { width: 200, height: 100 }, lang: "vi", metadata: { title: "Báo cáo 年报 & <more>", description: "Mô tả", authors: ["Ann", "Bé"], keywords: ["a", "b"], creator: "unit test", creationDate: "2026-08-06T01:02:03" } });
  isPdf(md, "metadata: document");
  {
    const s = latin1(md); const u = Buffer.from(md).toString("utf8");
    const info = /<<\/Producer\(bm-render\)[^\n]*>>/.exec(s);
    check(!!info, "metadata: Info with /Producer(bm-render)");
    const ti = info && /\/Title(<[^>]*>|\([^)]*\))/.exec(info[0]);
    check(ti && textOf(ti[1]) === "Báo cáo 年报 & <more>", `metadata: Info /Title round-trips (UTF-16): ${ti && JSON.stringify(textOf(ti[1]))}`);
    check(info && /\/Author<FEFF/.test(info[0]) && /\/Keywords\(a, b\)/.test(info[0]) && /\/Creator\(unit test\)/.test(info[0]), "metadata: /Author (joined), /Keywords (joined), /Creator");
    check(info && /\/ModDate\(D:20260806010203Z\)\/CreationDate\(D:20260806010203Z\)/.test(info[0]), "metadata: /ModDate + /CreationDate");
    check(u.includes("<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">Báo cáo 年报 &amp; &lt;more&gt;</rdf:li></rdf:Alt></dc:title>"), "metadata: XMP dc:title (UTF-8, escaped)");
    check(u.includes("<dc:creator><rdf:Seq><rdf:li>Ann, Bé</rdf:li></rdf:Seq></dc:creator>") && u.includes("<xmp:CreateDate>2026-08-06T01:02:03+00:00</xmp:CreateDate>") && u.includes("<dc:language><rdf:Bag><rdf:li>vi</rdf:li></rdf:Bag></dc:language>"), "metadata: XMP creator, dates, language");
    check(/\/Type\/Metadata\/Subtype\/XML/.test(s) && /\/Metadata \d+ 0 R\/Lang\(vi\)/.test(s), "metadata: catalog /Metadata + /Lang(vi)");
    const id = /\/ID\[\(([^)]*)\)\(([^)]*)\)\]/.exec(s);
    check(id && id[1] !== id[2] && u.includes(`<xmpMM:DocumentID>${id[1]}</xmpMM:DocumentID>`) && u.includes(`<xmpMM:InstanceID>${id[2]}</xmpMM:InstanceID>`), "metadata: document id derived from title + authors, both ids in the XMP");
    const plain = await r.render(node, { viewport: { width: 200, height: 100 }, tagged: false, lang: "en" });
    check(/<pdf:Producer>bm-render<\/pdf:Producer><xmpTPg:NPages>1<\/xmpTPg:NPages>/.test(latin1(plain)) && !/\/Lang/.test(latin1(plain)), "metadata: an XMP packet without metadata; no /Lang untagged without metadata");
  }
  // attachments: binary and text data, bytes recovered from the streams
  const bin = Uint8Array.from({ length: 256 }, (_, k) => k);
  const att = await r.render(node, { viewport: { width: 200, height: 100 }, metadata: { creationDate: "2026-01-02" }, attachments: [
    { name: "z-data.bin", data: bin, mimeType: "application/octet-stream", description: "Bytes 0..255" },
    { name: "a-note.txt", data: "hello, attachment ".repeat(40), mimeType: "text/plain", modificationDate: "2025-12-31T23:59:58" },
  ] });
  isPdf(att, "attachments: document");
  {
    const objs = objects(att);
    const specs = [...objs.values()].filter((o) => o.body.startsWith("<</Type/Filespec"));
    const file = (name) => { const sp = specs.find((o) => o.body.includes(`/F(${name})`)); return sp && objs.get(refOf(sp.body, "F")); };
    const zb = file("z-data.bin"); const at = file("a-note.txt");
    check(specs.length === 2, `attachments: two file specifications: ${specs.length}`);
    check(zb && Buffer.compare(zb.data, Buffer.from(bin)) === 0, "attachments: binary bytes recovered identical");
    check(at && at.data.toString("latin1") === "hello, attachment ".repeat(40) && /\/Filter\/FlateDecode/.test(at.body), "attachments: text bytes recovered identical (compressed)");
    check(zb && /\/Type\/EmbeddedFile\/Subtype\/application#2Foctet-stream\/Params<<\/Size 256\/ModDate\(D:20260102000000Z\)>>/.test(zb.body), `attachments: mime subtype, size, fallback date: ${zb && zb.body}`);
    check(at && /\/ModDate\(D:20251231235958Z\)/.test(at.body), "attachments: own modification date");
    check(/\/Names<<\/EmbeddedFiles<<\/Names\[\(a-note\.txt\)\d+ 0 R\(z-data\.bin\)\d+ 0 R\]>>>>/.test(latin1(att)) && !/\/AF\[/.test(latin1(att)) && !/AFRelationship/.test(latin1(att)), "attachments: name tree sorted by name; no /AF outside PDF/A-3");
    check(specs.some((o) => /\/Desc\(Bytes 0\.\.255\)/.test(o.body)), "attachments: /Desc");
  }
  // deterministic output
  const again = await r.render(doc, { size: { width: 400, height: 300 }, margin: 20, outline: true });
  check(Buffer.compare(Buffer.from(again), Buffer.from(paged)) === 0, "interactive: deterministic output (same bytes twice)");
  const att2 = await r.render(node, { viewport: { width: 200, height: 100 }, metadata: { creationDate: "2026-01-02" }, attachments: [
    { name: "z-data.bin", data: bin, mimeType: "application/octet-stream", description: "Bytes 0..255" },
    { name: "a-note.txt", data: "hello, attachment ".repeat(40), mimeType: "text/plain", modificationDate: "2025-12-31T23:59:58" },
  ] });
  check(Buffer.compare(Buffer.from(att2), Buffer.from(att)) === 0, "attachments: deterministic output");
}

// ---- measure
{
  const m = await r.measure(sized, { size: "letter" });
  check(m.width === 120 && m.height === 30, `measure (page options): ${JSON.stringify(m)}`);
  const v = r.measureSync(sized, { viewport: { width: 500, height: 400 } });
  check(v.width === 120 && v.height === 30, `measure (viewport): ${JSON.stringify(v)}`);
  const h = await r.measure(`<div style="width: 120px; height: 30px"></div>`);
  check(h.width === 120 && h.height === 30, `measure (HTML): ${JSON.stringify(h)}`);
}

// ---- module-level API
{
  const { render, measure, prepare } = pdfMod;
  isPdf(await render(sized, { viewport: { width: 50, height: 50 } }), "module-level render", [37.5, 37.5]);
  check((await measure(sized)).height === 30, "module-level measure");
  check((await prepare(html)) instanceof pdfMod.Prepared, "module-level prepare");
}

// ---- option validation errors (takumi-pdf's messages)
const bad = (opts, re, msg) => rejects(() => r.render(node, opts), re, msg);
await bad({ size: "tabloid" }, /unknown page size: tabloid/, "unknown page size");
await bad({ viewport: { width: 600 }, size: "a4" }, /viewport is mutually exclusive with the paged options/, "viewport + size");
await bad({ viewport: { width: 600 }, pageRanges: [1] }, /mutually exclusive/, "viewport + pageRanges");
await bad({ viewport: { width: 0 } }, /Page size must be finite and larger than zero/, "viewport width 0");
await bad({ pageRanges: [0] }, /Page range is invalid: 0\. Pages are numbered from 1\./, "page range 0");
await bad({ pageRanges: [{ from: 5, to: 2 }] }, /Page range is invalid: 5-2/, "backwards page range");
await bad({ viewport: { width: 100, height: 100 }, pageRanges: undefined, backgroundColor: "nope" }, /backgroundColor is not a color: nope/, "bad backgroundColor");
await rejects(() => r.render(node, { viewport: { width: 100, height: 100 }, header: true }), /mutually exclusive/, "viewport + header (viewport first)");
// (takumi-pdf hands a band that is neither HTML nor a node to fromJsx, which writes `true` as text)
check((await r.render(node, { header: true })).length > 0, "band true renders (the text \"true\", as takumi-pdf)");
await bad({ pages: { middle: {} } }, /unknown page rule: middle/, "unknown page rule");
await bad({ pages: { first: { body: 1 } } }, /unknown field of pages\.first: body/, "unknown page override field");
await bad({ margin: "wide" }, /invalid margin/, "bad margin");
await bad({ size: { width: 100, height: 100 }, margin: 60 }, /Page size must be finite and larger than zero/, "margins eat the page");
await bad({ metadata: { creationDate: "2026-02-30" } }, /invalid creationDate: expected YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS/, "bad creationDate");
await bad({ attachments: [{ name: "a", data: "x", modificationDate: "yesterday" }] }, /invalid modificationDate/, "bad modificationDate");
await bad({ attachments: [{ name: "a", data: "x" }, { name: "a", data: "y" }] }, /Two attachments are named a/, "duplicate attachment");
await bad({ attachments: [{ name: "a", data: "x", mimeType: "plain" }] }, /Attachment mime type is not a type\/subtype pair: plain/, "bad mime type");
await bad({ pdfa: "1b" }, /unknown variant `1b`/, "unknown pdfa level");
// (pdfa / tagged / attachment / date / placeholder combinations: takumi fails them while writing; see the tagging section)
await bad({ uncoveredText: "skip" }, /unknown variant `skip`, expected one of `error`, `placeholder`, `blank`/, "unknown uncoveredText");
await bad({ tagged: "ua3" }, /untagged enum TaggedInput/, "bad tagged");
await bad({ attachments: [{ name: "a" }] }, /missing field `data`/, "attachment without data");
await rejects(() => r.render({ type: "container", style: { width: "banana" } }), /width/, "layout error surfaces");
await rejects(() => r.render(node, { signal: AbortSignal.abort() }), /abort/i, "aborted signal");
// ---- tagged PDF, PDF/A, PDF/UA (tags.zig, conform.zig, tagdoc.zig)
{
  const zlib = await import("node:zlib");
  /** Every object body of the file, object streams unpacked and Flate streams inflated, as latin1 text. */
  const bodies = (bytes) => {
    const buf = Buffer.from(bytes); const s = buf.toString("latin1"); const out = [];
    const re = /(\d+) 0 obj\s/g; let m;
    while ((m = re.exec(s))) {
      const end = s.indexOf("endobj", m.index); const body = s.slice(m.index, end);
      const si = body.indexOf("stream");
      if (si < 0) { out.push(body); continue; }
      const len = +(/\/Length (\d+)/.exec(body) || [0, 0])[1];
      let p = m.index + si + 6; if (s[p] === "\r") p++; if (s[p] === "\n") p++;
      let data = buf.subarray(p, p + len);
      if (/FlateDecode/.test(body.slice(0, si))) { try { data = zlib.inflateSync(data); } catch {} }
      const text = data.toString("latin1");
      if (/\/Type\/ObjStm/.test(body)) { const first = +/\/First (\d+)/.exec(body)[1]; out.push(...text.slice(first).split(/\n(?=<<)/)); }
      else out.push(body.slice(0, si) + "\n" + text);
    }
    return out;
  };
  const doc = `<main><h1>Report</h1><p>Intro paragraph</p><ul><li>one</li><li>two</li></ul>
    <table><thead><tr><th>Name</th><th>Qty</th></tr></thead><tbody><tr><td>a</td><td>1</td></tr></tbody></table>
    <img src="pix" alt="a grey square" style="width:20px;height:20px" /><p><a href="https://example.com/x">link</a></p></main>`;
  // a 4 x 4 grey PNG (RGBA, filter 0)
  const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t, "latin1"), d]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(4, 0); ihdr.writeUInt32BE(4, 4); ihdr[8] = 8; ihdr[9] = 6;
  const raw = Buffer.alloc(4 * 17); for (let y = 0; y < 4; y++) raw.fill(128, y * 17 + 1, y * 17 + 17);
  const pix = new Uint8Array(Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]));
  const images = [{ src: "pix", data: pix }];
  const tagged = await r.render(doc, { images, lang: "en" });
  const tb = bodies(tagged);
  const elems = tb.filter((b) => b.includes("/Type/StructElem"));
  const roles = new Set(elems.map((b) => (/\/S\/(\w+)/.exec(b) || [])[1]));
  for (const role of ["Document", "H1", "P", "L", "LI", "Lbl", "LBody", "Table", "THead", "TBody", "TR", "TH", "TD", "Figure", "Link"]) check(roles.has(role), `tagged: a ${role} structure element`);
  check(elems.filter((b) => /\/S\/Lbl\b/.test(b)).length === 2, "tagged: each list item's marker is its Lbl (2 items, 2 Lbl)");
  check(elems.some((b) => /\/S\/Figure.*\/Alt\(a grey square\)/.test(b)), "tagged: the Figure carries the image's alt text");
  check(elems.some((b) => /\/S\/TH.*\/A\[<<\/O\/Table\/Scope\/Column>>\]/.test(b)), "tagged: a header cell scoped to its column");
  check(elems.some((b) => /\/S\/Link.*\/Type\/OBJR/.test(b)), "tagged: the Link element holds its annotation (OBJR)");
  check(elems.some((b) => /\/S\/Document.*\/Lang\(en\)/.test(b)), "tagged: the Document element carries the language");
  check(tb.some((b) => /\/Subtype\/Link.*\/StructParent \d+\/Contents\(https:\/\/example.com\/x\)/.test(b)), "tagged: the link annotation has /StructParent and its URI as /Contents");
  check(tb.some((b) => /\/Type\/StructTreeRoot.*\/ParentTree<<\/Nums\[/.test(b)), "tagged: struct tree root with a parent tree");
  check(tb.some((b) => /\/Type\/Catalog.*\/StructTreeRoot \d+ 0 R\/MarkInfo<<\/Marked true\/Suspects false>>/.test(b)), "tagged: catalog /StructTreeRoot + /MarkInfo");
  check(tb.some((b) => /\/Type\/Page\/.*\/StructParents \d+\/Tabs\/S/.test(b)), "tagged: the page has /StructParents and /Tabs /S");
  // every painting operator of the page stream sits in marked content (a content sequence or an artifact)
  const page = tb.find((b) => b.includes("BDC"));
  let depth = 0; let loose = 0;
  for (const line of page.split(/\n/)) for (const tok of line.match(/\/[A-Za-z]+<<[^>]*>>BDC|BDC|BMC|EMC|\b(?:f\*?|S|Do|TJ|Tj|sh)\b/g) || []) {
    if (/BDC|BMC/.test(tok)) depth++; else if (tok === "EMC") depth--; else if (depth === 0) loose++;
  }
  check(depth === 0 && loose === 0, `tagged: every painted item is in marked content (unbalanced ${depth}, outside ${loose})`);
  const mcids = (page.match(/MCID (\d+)/g) || []).length;
  const ptree = tb.find((b) => /\/Type\/StructTreeRoot/.test(b));
  check(mcids > 0 && ptree, `tagged: ${mcids} marked-content sequences`);
  // tagged: false writes none of it
  const plain = await r.render(doc, { images, lang: "en", tagged: false });
  const pb = bodies(plain).join("\n");
  check(!/BDC|BMC|StructTreeRoot|StructParents|MarkInfo/.test(pb), "tagged: false writes no marked content and no structure tree");
  // tagged: false output is the same file whichever tagging-related option rides along
  check(Buffer.compare(Buffer.from(plain), Buffer.from(await r.render(doc, { images, lang: "en", tagged: false }))) === 0, "tagged: false output is deterministic");

  // PDF/A levels: version, OutputIntent with the sRGB profile, XMP identification
  const meta = { title: "Archive", creationDate: "2026-08-06" };
  for (const [level, ver, part, conf] of [["2a", "1.7", "2", "A"], ["2b", "1.7", "2", "B"], ["2u", "1.7", "2", "U"], ["3a", "1.7", "3", "A"], ["3b", "1.7", "3", "B"], ["3u", "1.7", "3", "U"], ["4", "2.0", "4", null], ["4f", "2.0", "4", "F"]]) {
    const a = await r.render(doc, { images, lang: "en", pdfa: level, metadata: meta });
    const s = latin1(a); const ab = bodies(a).join("\n");
    check(s.startsWith(`%PDF-${ver}`), `pdfa ${level}: PDF ${ver}`);
    check(/\/OutputIntents \d+ 0 R/.test(ab) && /\/Type\/OutputIntent\/DestOutputProfile \d+ 0 R\/S\/GTS_PDFA1/.test(ab) && /\[\/ICCBased \d+ 0 R\]/.test(ab), `pdfa ${level}: sRGB OutputIntent and ICC-based colour space`);
    check(ab.includes(`<pdfaid:part>${part}</pdfaid:part>`) && (conf ? ab.includes(`<pdfaid:conformance>${conf}</pdfaid:conformance>`) : !ab.includes("pdfaid:conformance")), `pdfa ${level}: XMP pdfaid part ${part}${conf ? " conformance " + conf : ""}`);
    check(part === "4" ? ab.includes("<pdfaid:rev>2020</pdfaid:rev>") && !/\/Producer\(/.test(ab) : ab.includes("<pdfaExtension:schemas>") && /\/Producer\(/.test(ab), `pdfa ${level}: ${part === "4" ? "rev 2020, no Info dictionary" : "extension schemas, Info dictionary"}`);
    check(!/ \d+(\.\d+)? \d+(\.\d+)? \d+(\.\d+)? rg/.test(ab), `pdfa ${level}: no DeviceRGB colour operators`);
    check(ab.includes("<xmpMM:History>"), `pdfa ${level}: XMP history`);
    if (level === "4f") check(/\/EmbeddedFiles<<\/Names\[\]>>/.test(ab), "pdfa 4f: an empty EmbeddedFiles name tree");
    isPdf(a, `pdfa ${level}`);
  }
  const ua1 = await r.render(doc, { images, lang: "en", tagged: "ua1", metadata: meta });
  const ub = bodies(ua1).join("\n");
  check(ub.includes("<pdfuaid:part>1</pdfuaid:part>") && ub.includes("/ViewerPreferences<</DisplayDocTitle true>>") && /\/Outlines \d+ 0 R/.test(ub), "ua1: pdfuaid, DisplayDocTitle, outline");
  const ua2 = await r.render(doc, { images, lang: "en", tagged: "ua2", pdfa: "4", metadata: meta });
  const u2 = bodies(ua2).join("\n");
  check(latin1(ua2).startsWith("%PDF-2.0") && u2.includes("<pdfuaid:rev>2024</pdfuaid:rev>") && /\/NS \d+ 0 R/.test(u2) && u2.includes("/Type/Namespace/NS(http://iso.org/pdf2/ssn)"), "ua2 + pdfa 4: PDF 2.0, pdfuaid rev, structure namespaces");

  // validation failures: takumi's message (krilla `validation failed with N errors`)
  const v = /(?:^|: )Writing the PDF failed: validation failed with (\d+) errors?$/;
  const count = async (opts, n, msg) => {
    try { await r.render(opts.doc || doc, { images, lang: "en", ...opts, doc: undefined }); check(false, `${msg} (did not throw)`); }
    catch (e) { const m = v.exec(e.message); check(m && +m[1] === n, `${msg}: ${e.message}`); }
  };
  const att = [{ name: "a.txt", data: new Uint8Array([65]), mimeType: "text/plain", description: "a", modificationDate: "2026-08-06" }];
  await count({ pdfa: "2b", metadata: meta, attachments: att }, 1, "pdfa 2b: an attachment is a violation");
  await count({ pdfa: "4", metadata: meta, attachments: att }, 1, "pdfa 4: an attachment is a violation (4f takes them)");
  await count({ pdfa: "3b", metadata: meta, attachments: [{ name: "b.bin", data: new Uint8Array([1]) }] }, 2, "pdfa 3b: an attachment without mimeType and description");
  await count({ pdfa: "2b", metadata: { title: "x" } }, 1, "pdfa 2b: metadata without creationDate");
  await count({ tagged: "ua1", metadata: meta, doc: `<main><h1>T</h1><img src="pix" style="width:20px;height:20px" /></main>` }, 1, "ua1: an image without alt text");
  await count({ tagged: "ua1", doc: `<main><h1>T</h1><p>x</p></main>` }, 1, "ua1: no document title");
  await count({ tagged: "ua1", metadata: meta, doc: `<main><p>no heading</p></main>` }, 1, "ua1: no headings, so no outline");
  await count({ pdfa: "2b", metadata: meta, doc: `<div style="width:40px;height:40px;background-image:conic-gradient(red, blue)"></div>` }, 1, "pdfa 2b: a conic gradient needs a PostScript function");
  await rejects(() => r.render(doc, { images, pdfa: "4", tagged: "ua1" }), /(?:^|: )The requested archival standard is not available$/, "pdfa 4 + ua1: no common PDF version");
  await rejects(() => r.render(doc, { images, pdfa: "2b", tagged: "ua2" }), /(?:^|: )The requested archival standard is not available$/, "pdfa 2b + ua2: no common PDF version");
  await rejects(() => r.render(`<p>x \u{e000}\u{10ffff}</p>`, { pdfa: "2b", metadata: meta, uncoveredText: "placeholder" }), /, and PDF\/A-2b forbids the placeholder glyph\. Register a font that draws them, or set uncoveredText to "blank"\.$/, "pdfa 2b: the placeholder glyph is forbidden");
  await rejects(() => r.render(`<p>x \u{10ffff}</p>`, { tagged: "ua1", metadata: meta, uncoveredText: "placeholder" }), /PDF\/UA-1 forbids the placeholder glyph/, "ua1: the placeholder glyph is forbidden");
  const blank = await r.render(`<h1>x \u{10ffff}</h1>`, { pdfa: "2b", metadata: meta, uncoveredText: "blank" });
  isPdf(blank, "pdfa 2b + uncoveredText blank renders");
  const ok2a = await r.render(doc, { images, lang: "en", pdfa: "2a", tagged: false, metadata: meta });
  check(bodies(ok2a).some((b) => b.includes("/Type/StructTreeRoot")), "pdfa 2a: tagged even with tagged: false (takumi writes_structure)");
}

// ---- list markers (src/pdf/markers.zig) and named pages (page_names.zig, page_rules.zig)
{
  const zlib = await import("node:zlib");
  /** The page content streams of the file, inflated, in file order. */
  const contents = (bytes) => {
    const buf = Buffer.from(bytes); const str = buf.toString("latin1"); const out = [];
    const re = /\d+ 0 obj\s*<<([^]*?)>>\s*stream\r?\n/g; let m;
    while ((m = re.exec(str))) {
      const len = +(/\/Length (\d+)/.exec(m[1]) || [0, 0])[1];
      if (/\/Subtype|\/Type\/(XRef|ObjStm|Metadata)|\/Length1/.test(m[1])) continue;
      let data = buf.subarray(m.index + m[0].length, m.index + m[0].length + len);
      if (/FlateDecode/.test(m[1])) { try { data = zlib.inflateSync(data); } catch { continue; } }
      out.push(data.toString("latin1"));
    }
    return out.join("\n");
  };
  const tj = (bytes) => (contents(bytes).match(/\bTJ\b/g) || []).length;
  const page = { width: 240, height: 200, margin: 0 };
  const ol = `<ol start="3" style="font-size:16px;line-height:20px;margin:0"><li>alpha</li><li value="9">beta</li><li>gamma</li></ol>`;
  const withMarkers = await r.render(ol, { page, tagged: false });
  const without = await r.render(ol.replace("font-size:16px", "list-style:none;font-size:16px"), { page, tagged: false });
  isPdf(withMarkers, "markers: ordered list");
  check(tj(withMarkers) === tj(without) + 3, `markers: one text run per ordered marker (${tj(withMarkers)} vs ${tj(without)} without)`);
  const t = pdftotext(withMarkers, "markers_ordered");
  if (!t.skipped) check(/3\.\s*alpha/.test(t.text) && /9\.\s*beta/.test(t.text) && /10\.\s*gamma/.test(t.text), `markers: start / value numbering in the text (${JSON.stringify(t.text.trim())})`);
  const disc = await r.render(`<ul style="font-size:14px;margin:0"><li>one</li></ul>`, { page, tagged: false });
  check(/ m(?:(?: [-\d.]+){6} c){4}\s+h\s+f\b/.test(contents(disc)), "markers: a disc marker is a filled ellipse, no glyph");
  check(tj(disc) === tj(await r.render(`<ul style="list-style:none;font-size:14px;margin:0"><li>one</li></ul>`, { page, tagged: false })), "markers: a disc marker adds no text run");
  // the marker hangs left of the item's content: its text starts left of the item's
  const pos = (bytes) => [...contents(bytes).matchAll(/1 0 0 -1 ([-\d.]+) [-\d.]+ Tm/g)].map((x) => +x[1]);
  const xs = pos(await r.render(`<ol style="font-size:16px;margin:0;padding-left:40px"><li>x</li></ol>`, { page, tagged: false }));
  check(xs.length === 2 && xs[1] < 40 && xs[0] === 40, `markers: an outside marker hangs before the item (text at ${xs})`);
  // named pages: a change of page name breaks the page; each page takes its name's @page rules
  const mediaBoxes = (b) => [...latin1(b).matchAll(/\/MediaBox\[0 0 ([\d.]+) ([\d.]+)\]/g)].map((x) => [Math.round(+x[1]), Math.round(+x[2])]);
  const named = await r.render(`<style>@page { size: A5; margin: 10mm } @page wide { size: A5 landscape } .w { page: wide }</style><p>body one</p><div class="w">wide</div><p>body two</p>`);
  const boxes = mediaBoxes(named);
  isPdf(named, "named pages");
  check(JSON.stringify(boxes) === JSON.stringify([[420, 595], [595, 420], [420, 595]]), `named pages: A5, A5 landscape (named), A5: ${JSON.stringify(boxes)}`);
  const same = await r.render(`<style>@page { size: A5 } .w { page: auto }</style><p>one</p><div class="w">two</div>`);
  check(mediaBoxes(same).length === 1, "named pages: page: auto does not break");
}

// ---- regressions of known bugs (behaviour checked against the published takumi-pdf 0.20.0)
{
  const { inflateSync } = await import("node:zlib");
  /** The page content streams of the file, inflated, as latin1 text. */
  const content = (bytes) => {
    const s = latin1(bytes); const out = [];
    let at = 0;
    for (;;) {
      const i = s.indexOf("stream\n", at); if (i < 0) break;
      const j = s.indexOf("\nendstream", i); if (j < 0) break;
      const dict = s.slice(s.lastIndexOf("obj", i), i);
      if (/FlateDecode/.test(dict) && !/Subtype|Length1|Type\/|XRef|ObjStm/.test(dict)) {
        try { const t = inflateSync(Buffer.from(bytes.subarray(i + 7, j))).toString("latin1"); if (!t.slice(0, 64).includes("\0")) out.push(t); } catch {}
      }
      at = j + 10;
    }
    return out.join("\n");
  };
  const textOf = (bytes, name) => {
    const file = path.join(tmp, name + ".pdf");
    writeFileSync(file, bytes);
    const t = spawnSync(popplerText, ["-raw", "-enc", "UTF-8", file, "-"], { encoding: "utf8", windowsHide: true });
    if (t.error && t.error.code === "ENOENT") { pdftotextMissing = true; return null; }
    return t.stdout.replace(/\s+/g, " ").trim();
  };
  const inter = new Uint8Array(readFileSync(path.join(root, "assets", "fonts", "Inter-Regular.ttf")));
  const vp = { viewport: { width: 320, height: 120 } };

  // 1. no font registered: as takumi-pdf, the bundled last-resort Geist (Latin) draws the text; characters it
  //    lacks (Vietnamese tone marks) fail the render naming them, unless uncoveredText says otherwise
  {
    const t = textOf(await new PdfRenderer().render("<p>Hello</p>", vp), "geist_default");
    if (t !== null) check(t === "Hello", `no font: the bundled Geist draws the text (${JSON.stringify(t)})`);
    isPdf(await pdfMod.render("<p>Hello</p>"), "no font: module-level render draws with Geist");
    isPdf(new PdfRenderer().renderSync("<p>Hello</p>"), "no font: renderSync draws with Geist");
    check((await new PdfRenderer().measure("<p>Hello</p>")).height > 0, "no font: measure uses Geist");
    isPdf(await new PdfRenderer().render("<p>x</p>", { footer: "<p>Hello</p>" }), "no font: text in a band draws with Geist");
    const cleared = new PdfRenderer();
    cleared.registerFont({ name: "Inter", data: inter });
    cleared.clearFonts();
    isPdf(await cleared.render("<p>Hello</p>", vp), "clearFonts goes back to the bundled Geist");
    await rejects(() => new PdfRenderer().render("<p>Phạm Đức</p>", vp), /No font the text can use draws ạ \(U\+1EA1\), Đ \(U\+0110\)/, "no font: Vietnamese that Geist lacks fails, naming the characters");
  }
  isPdf(await new PdfRenderer().render("<p>Hello</p>", { ...vp, uncoveredText: "blank" }), "no font: uncoveredText blank draws nothing");
  isPdf(await new PdfRenderer().render(`<div style="width:10px;height:10px;background:red"> </div>`, vp), "no font: a document without text renders");

  // 2. per-call `fonts` on the sync methods (registered as on the async ones; lazy loaders need the async API)
  {
    const t = textOf(new PdfRenderer().renderSync("<p>Hello sync</p>", { ...vp, fonts: [inter] }), "sync_fonts");
    if (t !== null) check(t === "Hello sync", `renderSync fonts option: text drawn (${JSON.stringify(t)})`);
    check(new PdfRenderer().measureSync("<p>Hello</p>", { fonts: [{ name: "Inter", data: inter }] }).height > 0, "measureSync fonts option: text measured");
    try { new PdfRenderer().renderSync("<p>x</p>", { fonts: [{ name: "Lazy", data: () => inter }] }); check(false, "renderSync lazy font throws"); }
    catch (e) { check(/need the async API/.test(e.message), "renderSync lazy font throws: " + e.message); }
    const img = new fullMod.Renderer();
    check(img.measureSync("<p>Hello</p>", { width: 200, fonts: [inter] }).height > 0, "image Renderer.measureSync fonts option: text measured");
    // a render's `fonts` are registered once per renderer, as takumi-pdf dedupes them across calls
    const once = new PdfRenderer();
    for (let k = 0; k < 3; k++) await once.render("<p>x</p>", { ...vp, fonts: [inter, { name: "Inter Again", data: inter }] });
    once.renderSync("<p>x</p>", { ...vp, fonts: [inter] });
    const faces = once.registerFont(inter).find((fam) => fam.name === "Inter").faces.length;
    check(faces === 2, `fonts option: registered once across renders (Inter faces after 4 renders + registerFont: ${faces})`);
  }

  // 3. a content-sized page of no height: takumi-pdf's InvalidPageSize; measure reports the zero size; the
  //    page is as tall as the root's margin box, unrounded
  await rejects(() => r.render("<div></div>", { viewport: { width: 300 } }), /^bm-render: Page size must be finite and larger than zero$/, "empty content, viewport without height");
  {
    const m = await r.measure("<div></div>", { viewport: { width: 300 } });
    check(m.width === 300 && m.height === 0, `measure of empty content: ${JSON.stringify(m)}`);
    isPdf(await r.render(`<div style="height:10.2px;margin:5px"></div>`, { viewport: { width: 300 } }), "content-sized page keeps the fractional height", [225, 15.140625]);
  }

  // 4. paint order (CSS 2.1 appendix E, as takumi-pdf: in-flow backgrounds, floats, in-flow content, positioned)
  {
    const order = (bytes, needles) => { const c = content(bytes); return needles.map((s) => c.indexOf(s)); };
    const fl = await r.render(`<div style="width:300px;background:#eee"><p style="margin:0;background:#cfc">Hello text</p><div style="float:left;width:100px;height:40px;margin-top:-30px;background:#f00"></div><div style="position:relative;width:50px;height:20px;background:#00f;margin-top:-10px"></div></div>`, { ...vp, tagged: false });
    const [bg, flt, txt, pos] = order(fl, ["0.8 1 0.8 rg", "1 0 0 rg", "BT", "0 0 1 rg"]);
    check(bg >= 0 && bg < flt && flt < txt && txt < pos, `paint order: block background < float < text < positioned (${[bg, flt, txt, pos]})`);
    const fx = await r.render(`<div style="width:300px"><div style="display:flex"><div style="background:#f00;width:50px;height:20px">A</div></div><div style="background:#00f;height:20px;margin-top:-10px"></div></div>`, { ...vp, tagged: false });
    const [blue, red] = order(fx, ["0 0 1 rg", "1 0 0 rg"]);
    check(blue >= 0 && blue < red, "paint order: a flex item paints with the content, after a later block's background");
    const ib = await r.render(`<p style="margin:0">Hi <span style="display:inline-block;width:40px;height:20px;background:#f00"></span> yo</p><div style="background:#00f;height:20px;margin-top:-10px"></div>`, { ...vp, tagged: false });
    const [b2, t2, r2] = order(ib, ["0 0 1 rg", "BT", "1 0 0 rg"]);
    check(b2 >= 0 && b2 < t2 && t2 < r2, "paint order: block background < text < inline-block");
  }

  // 5. image-rendering: takumi-pdf writes every image without /Interpolate (viewers choose), whatever the value
  {
    const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAE0lEQVR4nGP4z8AAQv8ZQASIBQBDzgf5kLRQ3gAAAABJRU5ErkJggg==", "base64");
    for (const mode of ["auto", "smooth", "pixelated", "crisp-edges"]) {
      const b = await r.render(`<img src="c.png" style="width:100px;height:100px;image-rendering:${mode}">`, { ...vp, images: [{ src: "c.png", data: png }] });
      check(/\/Subtype\/Image/.test(latin1(b)) && !/\/Interpolate/.test(latin1(b)), `image-rendering ${mode}: image without /Interpolate`);
    }
  }

  // 6. text-overflow markers are text of their own (extractable as the marker), the hidden text is not drawn
  {
    const W = (s) => `<div style="padding:4px"><div style="width:120px;white-space:nowrap;overflow:hidden;font-family:Inter;text-overflow:${s}">Hello wonderful world of text</div></div>`;
    const ir = new PdfRenderer();
    ir.registerFont({ name: "Inter", data: inter });
    const t1 = textOf(await ir.render(W("ellipsis"), { viewport: { width: 200, height: 80 } }), "ellipsis");
    if (t1 !== null) check(/^Hello wonder(…|\.\.\.)$/.test(t1), `text-overflow ellipsis extracts as the marker: ${JSON.stringify(t1)}`);
    const t2 = textOf(await ir.render(W("'[more]'"), { viewport: { width: 200, height: 80 } }), "custom_marker");
    if (t2 !== null) check(t2 === "Hello wo[more]", `text-overflow string extracts as the marker: ${JSON.stringify(t2)}`);
    const clip = content(await ir.render(W("ellipsis"), { viewport: { width: 200, height: 80 }, tagged: false }));
    check(/re\nW\nn/.test(clip), "an overflow box clips its own text");
  }

  // 7. long documents: a page draws only what is on it, time and memory grow linearly with the pages
  {
    const perPage = (bytes) => {
      const s = latin1(bytes); const out = []; let at = 0;
      for (;;) {
        const i = s.indexOf("stream\n", at); if (i < 0) break;
        const j = s.indexOf("\nendstream", i); if (j < 0) break;
        const dict = s.slice(s.lastIndexOf("obj", i), i);
        if (/FlateDecode/.test(dict) && !/Subtype|Length1|Type\/|XRef|ObjStm/.test(dict)) {
          try { const t = inflateSync(Buffer.from(bytes.subarray(i + 7, j))).toString("latin1"); if (/ cm[ \n]/.test(t) &&!t.slice(0, 64).includes("\0")) out.push(t); } catch {}
        }
        at = j + 10;
      }
      return out;
    };
    const lr = new PdfRenderer();
    lr.registerFont({ name: "Inter", data: inter });
    const rows = Array.from({ length: 70 }, (_, k) => `<tr style="background:${k % 2 ? "#f1f5f9" : "#fff"}"><td>Row ${k}</td><td>Item ${k}</td><td>${k * 3}</td></tr>`).join("");
    const table = await lr.render(`<style>body{font-family:Inter;font-size:11px} table{width:100%;border-collapse:collapse} td,th{border:1px solid #cbd5e1;padding:4px}</style><table><thead><tr><th>A</th><th>B</th><th>C</th></tr></thead><tbody>${rows}</tbody></table>`, { size: "a5" });
    const res = perPage(table).map((t) => (t.match(/ re\n/g) || []).length);
    check(res.length >= 3 && Math.max(...res) < 450, `a 70-row collapsed table: rectangles per page ${res.join("/")} (takumi-pdf 288/339/326/59; was ~900 a page)`);
    const sec = (k) => `<section style="break-after:page"><h2>Section ${k + 1}</h2><p>${"Lorem ipsum dolor sit amet, consectetur adipiscing elit. ".repeat(8)}</p>` +
      `<table style="width:100%;border-collapse:collapse"><tbody>${Array.from({ length: 14 }, (_, r) => `<tr><td style="border-bottom:1px solid #e2e8f0">Line ${k * 14 + r}</td><td>${r}</td></tr>`).join("")}</tbody></table></section>`;
    const doc = (n) => `<div style="font-family:Inter;font-size:11px">${Array.from({ length: n }, (_, k) => sec(k)).join("")}</div>`;
    const footer = `<div style="font:9px Inter;text-align:center">Page <span class="pageNumber"></span> of <span class="totalPages"></span></div>`;
    const t0 = performance.now();
    const big = await lr.render(doc(500), { size: "a4", margin: 40, footer });
    const ms = performance.now() - t0;
    const streams = perPage(big);
    const ops = streams.map((t) => t.length);
    check(streams.length === 500 && ms < 60000, `500 pages render (${streams.length} pages in ${Math.round(ms)} ms; was out of memory)`);
    check(ops.length === 500 && Math.max(...ops) < 3 * Math.min(...ops.slice(0, -1)), `500 pages: each page's content is its own (bytes per page ${Math.min(...ops)}..${Math.max(...ops)})`);
    const mem = [];
    const rr = new pdfMod.Renderer();
    rr.registerFont({ name: "Inter", data: inter });
    // (the first render may still grow the memory the 500-page document left fragmented: a warm-up)
    for (let k = 0; k < 4; k++) { await rr.renderPdf(doc(60), { size: "a4", margin: 40, footer }); mem.push(rr.memoryBytes()); }
    check(mem[3] <= mem[1] * 1.1, `memory plateaus over renders (${mem.map((m) => Math.round(m / 2 ** 20)).join(" / ")} MiB)`);
  }
}

// ---- takumi-pdf wrapper inputs: JSX trees, fromJsx values as bands, pooled <style> sheets
{
  const el = (type, props) => ({ $$typeof: Symbol.for("react.transitional.element"), type, props, key: null });
  const Comp = ({ label }) => el("b", { children: label });
  const jsx = el("div", { style: { fontSize: 20, padding: 4 }, children: ["JSX ", el(Comp, { label: "comp" })] });
  const bytes = await r.render(jsx, { size: { width: 300, height: 200 }, footer: el("div", { children: ["F", el("span", { className: "pageNumber" })] }) });
  isPdf(bytes, "JSX document and footer", [225, 150]);
  const t = pdftotext(bytes, "jsx_text");
  if (!t.skipped) check(/JSX comp/.test(t.text) && /F1/.test(t.text), `JSX document and footer text: ${JSON.stringify(t.text.trim())}`);
  const pooled = await r.render(`<div class="x">DOCX</div><p>doc</p>`, { size: { width: 300, height: 200 }, header: `<style>.x{display:none}</style><p>head</p>` });
  const t2 = pdftotext(pooled, "pooled_styles");
  if (!t2.skipped) check(!/DOCX/.test(t2.text) && /head/.test(t2.text), "a band's <style> styles the document too (takumi-pdf pools the <style> sheets)");
}

const rendererAfterErrors = await r.render(node, { viewport: { width: 40, height: 40 } });
isPdf(rendererAfterErrors, "renderer still works after errors", [30, 30]);

// ---- builds without the pdf feature
{
  const f = new fullMod.Renderer();
  const expect = /renderPdf is not supported by this build/;
  await rejects(() => f.renderPdf(node), expect, "full build: renderPdf rejects");
  try { f.renderPdfSync(node); check(false, "full build: renderPdfSync throws"); } catch (e) { check(expect.test(e.message), "full build: renderPdfSync throws: " + e.message); }
  try { f.measurePdfSync(node); check(false, "full build: measurePdfSync throws"); } catch (e) { check(/renderPdf/.test(e.message), "full build: measurePdfSync throws"); }
  // the wasm export itself (no JS feature gate): the Zig-side error
  // (BM_FULL_WASM overrides the file, e.g. a fresh `zig build` output while js/bm_render.wasm predates the export)
  const fullPath = process.env.BM_FULL_WASM || path.join(root, "js", "bm_render.wasm");
  const { instance } = await WebAssembly.instantiate(readFileSync(fullPath), {});
  const w = instance.exports;
  if (typeof w.bm_render_pdf === "function") {
    const h = w.bm_renderer_new();
    const src = Buffer.from(JSON.stringify(node));
    const p = w.bm_alloc(src.length);
    new Uint8Array(w.memory.buffer).set(src, p);
    const status = w.bm_render_pdf(h, 0, p, src.length, p, 0);
    const msg = new TextDecoder().decode(new Uint8Array(w.memory.buffer, w.bm_last_error_ptr(), w.bm_last_error_len()));
    check(status !== 0 && /renderPdf is not supported by this build/.test(msg), `full wasm bm_render_pdf: status ${status}, "${msg}"`);
  } else console.log(`SKIP  ${fullPath} predates bm_render_pdf (rebuild it: npm run build:full, or set BM_FULL_WASM)`);
}

// ---- resource discovery: pinned takumi-pdf-js prepare.test.ts, with extra cascade/failure cases
{
  const inter = new Uint8Array(readFileSync(path.join(root, "assets/fonts/Inter-Regular.ttf")));
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAE0lEQVR4nGP4z8AAQv8ZQASIBQBDzgf5kLRQ3gAAAABJRU5ErkJggg==", "base64");
  const called = [];
  const r = new PdfRenderer();
  const fetch = async (url) => { called.push(url); return new Response(png); };
  const prepared = await r.prepare(`<style>.used{width:10px;height:10px;background-image:url(https://example.com/body.png)}.unused{background:url(https://example.com/unused.png)}@font-face{font-family:Unused;src:url(https://example.com/unused.woff2)}</style><div class="used"></div><div style="display:none"><img src="https://example.com/hidden.png"></div>`, {
    header: `<img src="https://example.com/header.png" width="10" height="10">`, images: { fetch },
  });
  check(called.sort().join("|") === ["https://example.com/body.png", "https://example.com/header.png"].join("|"), "prepare needs: fetches drawn body/band images and skips unmatched/hidden resources and unused font files");
  isPdf(await r.render(prepared), "prepare discovered resources");
  r.free();

  const subsetCalls = [0, 0, 0];
  const subset = (index, range) => ({ name: "Band Subset", key: String(index), unicodeRange: [range], data: () => { subsetCalls[index]++; return inter; } });
  const subsets = new PdfRenderer();
  const p = await subsets.prepare("<p>a</p>", { footer: "<p>Ж</p>", pages: { first: { header: "<p>α</p>" } }, fonts: [subset(0, [0x400, 0x4ff]), subset(1, [0x370, 0x3ff]), subset(2, [0x530, 0x58f])] });
  check(subsetCalls.join(",") === "1,1,0", "prepare needs: loads only subsets used by body and every band's text");
  isPdf(await subsets.render(p), "prepare band font subsets");
  check(subsetCalls.join(",") === "1,1,0", "prepared render reuses loaded subsets");
  subsets.free();

  // font fallback decides which listed subsets load (takumi needs.rs): the element's families, then the stack
  const reached = [];
  const family = (name, range) => ({ name, unicodeRange: [range], data: () => { reached.push(name); return inter; } });
  const fallback = new PdfRenderer();
  await fallback.prepare("<p style='font-family:B'>a</p><p>Ж</p>", { fonts: [family("A", [0, 0x24f]), family("B", [0, 0x24f]), family("C", [0x400, 0x4ff]), family("D", [0x400, 0x4ff])] });
  check(reached.join(",") === "B,C", `prepare needs: only the subsets font fallback reaches load (${reached.join(",")})`);
  fallback.free();

  const files = new PdfRenderer();
  const fontCalls = [];
  const fp = await files.prepare(`<style>@font-face{font-family:Remote;src:url(https://example.com/broken.woff2),url(https://example.com/font.ttf)}p{font-family:Remote}</style><p>Font fallback file</p>`, {
    images: { fetch: async (url) => { fontCalls.push(url); return new Response(url.includes("broken") ? new Uint8Array([0]) : inter); } },
  });
  check(fontCalls.join("|") === "https://example.com/broken.woff2|https://example.com/font.ttf", "prepare needs: font files retry the next src after invalid bytes");
  isPdf(await files.render(fp), "prepare CSS font face fallback");
  files.free();

  const cached = new PdfRenderer();
  const cache = new Map(); let downloads = 0;
  const cachedOptions = { images: { fetchCache: cache, fetch: async () => { downloads++; return new Response(png); } } };
  await Promise.all([cached.prepare('<img src="https://example.com/cache.png">', cachedOptions), cached.prepare('<img src="https://example.com/cache.png">', cachedOptions)]);
  check(downloads === 1, "prepare fetchCache: concurrent requests share one download");
  await cached.prepare('<img src="https://example.com/cache.png">', cachedOptions);
  check(downloads === 1, "prepare fetchCache: later preparation reuses cached bytes");
  let attempts = 0;
  // (a 404: not retried within one download, as takumi helpers fetchOk retries only 408 / 429 / 5xx)
  const retryOptions = { images: { fetchCache: cache, throwOnError: false, fetch: async () => new Response(++attempts === 1 ? "failed" : png, { status: attempts === 1 ? 404 : 200 }) } };
  await cached.prepare('<img src="https://example.com/retry.png">', retryOptions);
  check(!cache.has("https://example.com/retry.png"), "prepare fetchCache: failed download is evicted");
  await cached.prepare('<img src="https://example.com/retry.png">', retryOptions);
  check(attempts === 2, "prepare fetchCache: failed URL can be retried");
  let flaky = 0;
  await cached.prepare('<img src="https://example.com/flaky.png">', { images: { fetch: async () => new Response(++flaky < 3 ? "busy" : png, { status: flaky < 3 ? 503 : 200 }) } });
  check(flaky === 3, "prepare fetch: a 503 is retried, at most three attempts (takumi helpers fetchOk)");
  const abort = new AbortController();
  const pending = cached.prepare('<img src="https://example.com/pending.png">', { signal: abort.signal, images: { fetch: () => new Promise(() => {}) } });
  abort.abort(new Error("resource preparation cancelled"));
  await rejects(() => pending, /resource preparation cancelled/, "prepare aborts while custom fetch is pending");
  cached.free();

  const svgFonts = new PdfRenderer(); let greek = 0; let unused = 0;
  await svgFonts.prepare('<img src="https://example.com/text.svg">', {
    images: { fetch: async () => new Response('<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30"><text y="20">α</text></svg>') },
    fonts: [
      { name: "SVG Subset", unicodeRange: "U+0370-03FF", data: () => { greek++; return inter; } },
      { name: "Unused Subset", unicodeRange: "U+0530-058F", data: () => { unused++; return inter; } },
    ],
  });
  check(greek === 1 && unused === 0, "prepare needs: downloaded SVG text adds only its required font subset");
  const needsSvg = `<svg xmlns="http://www.w3.org/2000/svg"><style>.used{font-family:'SVG Face';font-weight:700}</style><defs><text id="used" class="used">α</text><text>Ա</text><g id="cycle"><use href="#cycle"/></g></defs><g display="none"><text>Ա</text></g><text visibility="hidden">Ա<tspan visibility="visible">β</tspan></text><use href="#used"/><use href="#cycle"/></svg>`;
  const needsRenderer = new pdfMod.Renderer();
  const svgNeeds = needsRenderer.needsPdfSync('<img src="text.svg">', { images: [{ src: 'text.svg', data: new TextEncoder().encode(needsSvg) }] });
  check(svgNeeds.text.includes('α') && svgNeeds.text.includes('β') && !svgNeeds.text.includes('Ա'), "SVG needs: resolve use, skip unused defs/hidden text, allow visible descendants, bound cycles");
  check(svgNeeds.requests.some(request => request.text === 'α' && request.families.includes('SVG Face') && request.weight === 700), "SVG needs: use cascaded font family and weight");
  needsRenderer.free();
  const svgFetches = [];
  await svgFonts.prepare(`<style>@font-face{font-family:'SVG Face';font-weight:700;src:url(https://example.com/svg-font.ttf)}</style><img src="https://example.com/face.svg">`, {
    images: { fetch: async url => {
      svgFetches.push(url);
      return new Response(url.endsWith('.svg') ? needsSvg : inter);
    } },
  });
  check(svgFetches.join('|') === 'https://example.com/face.svg|https://example.com/svg-font.ttf', `prepare SVG: downloaded text requests font-face files without font subsets (${svgFetches.join('|')})`);
  svgFonts.free();
}

rmSync(tmp, { recursive: true, force: true });
check(!pdftotextMissing, "Poppler text checks ran (pdftotext required)");
console.log(`\n${passes} passed, ${fails} failed`);
process.exit(fails ? 1 : 0);
