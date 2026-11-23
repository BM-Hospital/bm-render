// Image markers and generated images against the pinned reference (todo tasks 11, 12):
// `list-style-image` (inside / outside, RTL, every page, missing / broken image, items that start
// with a flex / grid / table / replaced box, the Lbl structure) and `content: url()` in ::before /
// ::after (PNG / SVG, intrinsic size, missing image, block / inline / positioned pseudo, page
// breaks, counters next to the image, a prepared remote image). Each case compares the draw lists
// (paint.probe.mjs `cmp`: q/Q and clip grouping may differ), the text pdftotext and pdf.js
// extract, and the pdf.js raster (2x). Deliberate differences assert bm-render's own behaviour and
// are reported with `t.differs`.
import { INTER, bmMod, font, refMod, squash } from "./lib.mjs";
import { cmp, dataUri, probeAs, svgUri, vp } from "./paint.probe.mjs";
import { inspect, renderPage } from "../../bench/pdf/lib/pdfjs.mjs";

const inter = { name: "Inter", data: font(INTER) };
const PNG = dataUri("takumi-pdf/tests/images/checker.png");
const JPG = dataUri("takumi-pdf/tests/images/checker.jpg");
const SVG = svgUri(`<svg xmlns="http://www.w3.org/2000/svg" width="10" height="6" viewBox="0 0 10 6"><rect width="10" height="6" fill="#c00"/></svg>`);
const SVG_NOSIZE = svgUri(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="5" fill="#06c"/></svg>`);
const BROKEN = "data:image/png;base64,AAAA";
const PAGE = vp(200, 120);
const PAGED = { size: { width: 200, height: 100 }, margin: 0, tagged: false };
const TAGGED = { viewport: { width: 200, height: 120 } };

async function raster(a, b, pages) {
  let max = 0; let changed = 0;
  for (let p = 0; p < pages; p++) {
    const x = await renderPage(a, p, 2); const y = await renderPage(b, p, 2);
    if (x.width !== y.width || x.height !== y.height) return { max: 255, changed: -1 };
    for (let i = 0; i < x.rgba.length; i += 4) {
      let d = 0;
      for (let c = 0; c < 4; c++) d = Math.max(d, Math.abs(x.rgba[i + c] - y.rgba[i + c]));
      max = Math.max(max, d); changed += Number(d !== 0);
    }
  }
  return { max, changed };
}

/** Draw list, extracted text (pdftotext and pdf.js), raster and (tagged) structure equal to the reference. */
function same(prefix, feature, list, defaults = {}) {
  for (const [id, html, o = {}] of list) {
    probeAs(`${prefix}.${id}`, feature, async (t) => {
      const options = o.options || defaults.options || PAGE;
      const r = await cmp(t, "", html, options, { fonts: [inter] });
      if (!r.ref || r.bm.error || r.ref.error) return;
      t.same("pdftotext", squash(r.bm.text), squash(r.ref.text));
      const a = await inspect(r.bm.bytes); const b = await inspect(r.ref.bytes);
      t.same("pdf.js text (visual order)", a.pages.map((p) => p.text), b.pages.map((p) => p.text));
      const d = await raster(r.bm.bytes, r.ref.bytes, Math.min(a.pages.length, b.pages.length));
      t.ok(d.changed >= 0 && d.max <= (o.maxDiff ?? 0), `raster: ${d.changed} changed pixels, largest channel difference ${d.max}`);
      if (options.tagged !== false) t.same("structure tree", r.bm.structure.tree, r.ref.structure.tree);
      if (o.check) await o.check(t, r);
    });
  }
}

/** Images drawn per page (`Do` of an image XObject or inline image) in a render. */
const imageDraws = (r) => r.pdf.pages.map((_, i) => (r.content(i).match(/\/\w+\s+Do\b|\bBI\b/g) || []).length);
/** The page content of a render, all pages. */
const content = (r) => r.pdf.pages.map((_, i) => r.content(i)).join("\n");

/**
 * A documented difference: the same pages and extracted text as the reference (and the same draw
 * list and raster with `draw`), bm-render's own behaviour asserted by `check`, the reference's
 * output only noted.
 */
function differs(prefix, feature, list, why, defaults = {}) {
  for (const [id, html, o = {}] of list) {
    probeAs(`${prefix}.${id}`, feature, async (t) => {
      const options = o.options || defaults.options || PAGE;
      const draw = o.draw ?? defaults.draw;
      const r = draw ? await cmp(t, "", html, options, { fonts: [inter] }) : await t.both(html, options, { fonts: [inter] });
      t.ok(!r.bm.error, "bm renders" + (r.bm.error ? ": " + r.bm.error : ""));
      if (r.bm.error) return;
      await (o.check || defaults.check)(t, r.bm);
      if (!r.ref || r.ref.error) { if (r.ref) t.differs(`${why} (takumi: ${r.ref.error})`); return; }
      t.same("page count", r.bm.pages.length, r.ref.pages.length);
      if (o.text !== false) t.same("pdftotext", squash(r.bm.text), squash(r.ref.text));
      else t.note(`pdftotext: bm ${JSON.stringify(squash(r.bm.text))}, takumi ${JSON.stringify(squash(r.ref.text))}`);
      if (draw) {
        const a = await inspect(r.bm.bytes); const b = await inspect(r.ref.bytes);
        const d = await raster(r.bm.bytes, r.ref.bytes, Math.min(a.pages.length, b.pages.length));
        t.ok(d.changed === 0, `raster: ${d.changed} changed pixels, largest channel difference ${d.max}`);
      }
      t.differs(why);
    });
  }
}

/** bm draws the 8 px PNG at its natural size (6 pt). */
const naturalPng = (t, r) => { t.ok(/\b6 0 0 6 [\d.-]+ [\d.-]+ cm\s*\/\w+ Do/.test(content(r)), "generated PNG drawn at its natural 8 x 8 px"); };
/** bm draws the 10 x 6 px SVG at its natural size (7.5 x 4.5 pt). */
const naturalSvg = (t, r) => { t.ok(/ 7\.5 -4\.5 re\s+W\s+n/.test(content(r)), "generated SVG clipped to its natural 10 x 6 px"); };

// ------------------------------------------------------------------------------------------------ 11 list-style-image

const S = "font:14px Inter;margin:0;padding-left:30px";
same("lists.image", "list-style-image: image markers", [
  ["outside-png", `<ul style="${S};list-style-image:url(${PNG})"><li>one</li><li>two</li></ul>`],
  ["outside-jpeg", `<ul style="${S};list-style-image:url(${JPG})"><li>one</li></ul>`],
  ["outside-svg", `<ul style="${S};list-style-image:url(${SVG})"><li>one</li><li>two</li></ul>`],
  ["outside-svg-no-size", `<ul style="${S};list-style-image:url(${SVG_NOSIZE})"><li>one</li></ul>`],
  ["inside-png", `<ul style="${S};list-style:inside url(${PNG})"><li>one</li><li>two</li></ul>`],
  ["inside-svg", `<ul style="${S};list-style:inside url(${SVG})"><li>one</li></ul>`],
  ["big-font", `<ul style="${S};font-size:30px;list-style-image:url(${SVG})"><li>Big</li></ul>`],
  ["line-height", `<ul style="${S};line-height:40px;list-style-image:url(${PNG})"><li>tall line</li></ul>`],
  ["ol-decimal", `<ol style="${S};list-style-image:url(${PNG})"><li>one</li><li>two</li></ol>`, { check: (t, r) => { t.ok(!/\d\./.test(r.bm.text), "the image replaces the numbers"); t.ok(imageDraws(r.bm)[0] === 2, "two marker images"); } }],
  ["ol-missing", `<ol style="${S};list-style-image:url(https://example.invalid/m.png)"><li>one</li><li>two</li></ol>`, { check: (t, r) => { t.ok(squash(r.bm.text) === "1. one 2. two", "a missing image leaves the numbers"); t.ok(imageDraws(r.bm)[0] === 0, "no image"); } }],
  ["ol-broken", `<ol style="${S};list-style-image:url(${BROKEN})"><li>one</li></ol>`, { check: (t, r) => { t.ok(squash(r.bm.text) === "1. one", "an undecodable image leaves the number"); } }],
  ["type-none", `<ul style="${S};list-style:none url(${PNG})"><li>one</li></ul>`],
  ["marker-content-wins", `<style>li::marker{content:"> "}</style><ul style="${S};list-style-image:url(${PNG})"><li>one</li></ul>`],
  ["rtl-outside", `<ul dir="rtl" style="${S};padding-right:30px;list-style-image:url(${PNG})"><li>one</li><li>two</li></ul>`],
  ["rtl-inside", `<ul dir="rtl" style="${S};list-style:inside url(${SVG})"><li>one</li></ul>`],
  ["wrapped-item", `<ul style="${S};width:120px;list-style-image:url(${PNG})"><li>a long item that wraps onto more lines</li></ul>`],
  ["nested", `<ul style="${S};list-style-image:url(${PNG})"><li>one<ul style="padding-left:20px;list-style-image:url(${SVG})"><li>inner</li></ul></li></ul>`],
  ["inherited-none", `<ul style="${S};list-style-image:url(${PNG})"><li>one</li><li style="list-style-image:none">two</li></ul>`],
  ["missing-http", `<ul style="${S};list-style-image:url(https://example.invalid/m.png)"><li>one</li></ul>`],
  ["missing-http-none", `<ul style="${S};list-style:none url(https://example.invalid/m.png)"><li>one</li></ul>`],
  ["broken-data", `<ul style="${S};list-style-image:url(${BROKEN})"><li>one</li></ul>`],
  ["host-block-child", `<ul style="${S};list-style-image:url(${PNG})"><li><div>block</div></li></ul>`],
  ["host-flex", `<ul style="${S};list-style-image:url(${PNG})"><li style="display:flex"><span>flex a</span><span>b</span></li></ul>`],
  ["host-grid", `<ul style="${S};list-style-image:url(${PNG})"><li style="display:grid"><span>grid</span></li></ul>`],
  ["host-img", `<ul style="${S};list-style-image:url(${SVG})"><li><img src="${PNG}" width="20" height="20"> after</li></ul>`],
  // an item starting with a box of its own formatting context: the outside marker sits beside the item's first
  // baseline (Blink PositionListMarkerBesideChild), or at its content top when nothing has one
  ["host-flex-child", `<ul style="${S};list-style-image:url(${PNG})"><li><div style="display:flex">flex child</div></li></ul>`],
  ["host-table", `<ul style="${S};list-style-image:url(${PNG})"><li><table><tr><td>cell</td></tr></table></li></ul>`],
  ["host-img-block", `<ul style="${S};list-style-image:url(${SVG})"><li><img src="${PNG}" width="20" height="20" style="display:block">after</li></ul>`],
  ["host-flex-child-decimal", `<ol style="${S}"><li><div style="display:flex">flex child</div></li></ol>`],
  ["host-grid-child-decimal", `<ol style="${S}"><li><div style="display:grid;grid-template-columns:1fr 1fr;font-size:20px"><span style="grid-column:2">b</span><span>a</span></div></li></ol>`],
  ["host-table-margin-decimal", `<ol style="${S}"><li><table style="margin-top:6px"><tr><td style="padding:5px">cell</td></tr></table></li><li><div style="display:flex;align-items:end;height:40px"><span>b1</span><span style="font-size:30px">b2</span></div></li></ol>`],
  ["host-image-only-decimal", `<ol style="${S}"><li><img src="${PNG}" width="20" height="20" style="display:block"></li><li>next</li></ol>`],
  ["host-rtl-flex-decimal", `<ol dir="rtl" style="${S};padding-right:30px"><li><div style="display:flex">flex child</div></li></ol>`],
]);

const many = (n, style) => `<ul style="${S};${style}">${Array.from({ length: n }, (_, i) => `<li>item ${i + 1}</li>`).join("")}</ul>`;
same("lists.image.pages", "list-style-image: image markers on every page", [
  ["outside", many(12, `list-style-image:url(${PNG})`), { options: PAGED }],
  ["inside", many(12, `list-style:inside url(${SVG})`), { options: PAGED }],
  ["split-item", `<ul style="${S};width:150px;list-style-image:url(${PNG})"><li style="height:70px">first</li><li>second item with text long enough to break across the page bottom edge here</li></ul>`, { options: PAGED }],
]);

same("lists.image.tagged", "list-style-image: Lbl structure", [
  ["missing", `<ul style="${S};list-style-image:url(https://example.invalid/m.png)"><li>one</li></ul>`, { options: TAGGED }],
  ["host-flex-decimal", `<ol style="${S}"><li><div style="display:flex">flex child</div></li><li><table><tr><td>cell</td></tr></table></li></ol>`, { options: TAGGED }],
]);

/** The marked-content ids each `Lbl` of the structure tree holds. */
const labels = (r) => [...r.structure.tree.matchAll(/^\s*Lbl(?: \[([^\]]*)\])?$/gm)].map((m) => m[1] || "");
differs("lists.image.tagged", "list-style-image: Lbl structure", [
  ["outside", `<ul style="${S};list-style-image:url(${PNG})"><li>one</li><li>two</li></ul>`],
  ["ol", `<ol style="${S};list-style-image:url(${SVG})"><li>one</li></ol>`],
], "an outside image marker is the Lbl's content in bm-render; takumi tags the image as a P of the LBody and leaves two empty marked-content sequences in the Lbl", {
  options: TAGGED, draw: false,
  check: (t, r) => {
    const lbl = labels(r);
    t.ok(lbl.length > 0 && lbl.every((k) => /^mcid p\d+:\d+$/.test(k)), `every item has an Lbl holding its marker image: ${JSON.stringify(lbl)}`);
  },
});
differs("lists.image.tagged", "list-style-image: Lbl structure", [
  ["inside", `<ul style="${S};list-style:inside url(${PNG})"><li>one</li></ul>`],
], "an inside image marker stays in the P of its line (as an inside text marker does); takumi splits the image into a P of its own (docs/PDF_AUDIT.md `content: url()`)", {
  options: TAGGED, draw: true,
  check: (t, r) => { t.ok(!labels(r).length && (r.structure.tree.match(/^\s*P\b/gm) || []).length === 1, "no Lbl, one P"); },
});


// ------------------------------------------------------------------------------------------------ 12 content: url()

const D = "font:14px Inter;margin:10px";
same("generated.url", "content: url() in ::before / ::after", [
  ["before-png", `<style>.x::before{content:url(${PNG})}</style><div class="x" style="${D}">mid</div>`],
  ["after-png", `<style>.x::after{content:url(${PNG})}</style><div class="x" style="${D}">mid</div>`],
  ["before-jpeg", `<style>.x::before{content:url(${JPG})}</style><div class="x" style="${D}">mid</div>`],
  ["before-svg", `<style>.x::before{content:url(${SVG})}</style><div class="x" style="${D}">mid</div>`],
  ["before-svg-no-size", `<style>.x::before{content:url(${SVG_NOSIZE})}</style><div class="x" style="${D};width:150px">mid</div>`],
  ["both", `<style>.x::before{content:url(${PNG})}.x::after{content:url(${SVG})}</style><div class="x" style="${D}">mid</div>`],
  ["in-span", `<style>b::before{content:url(${PNG})}</style><p style="${D}">a <b>bold</b> c</p>`],
  ["line-wrap", `<style>b::after{content:url(${SVG})}</style><p style="${D};width:90px">some words <b>here</b> and more words</p>`],
  ["missing-http", `<style>.x::before{content:url(https://example.invalid/m.png)}</style><div class="x" style="${D}">mid</div>`],
  ["missing-with-text", `<style>.x::before{content:'a' url(https://example.invalid/m.png) 'b'}</style><div class="x" style="${D}">mid</div>`],
  ["broken-data", `<style>.x::before{content:url(${BROKEN})}</style><div class="x" style="${D}">mid</div>`],
  ["counter-next", `<style>ol{counter-reset:c;list-style:none}li{counter-increment:c}li::before{content:counter(c) url(${PNG}) '. '}</style><ol style="${D}"><li>one</li><li>two</li></ol>`],
  ["counter-after", `<style>body{counter-reset:s}h2{counter-increment:s;font:16px Inter}h2::after{content:url(${SVG}) ' #' counter(s)}</style><h2>A</h2><h2>B</h2>`],
  ["attr-next", `<style>a::after{content:url(${SVG}) ' (' attr(href) ')'}</style><p style="${D}"><a href="x.html">link</a></p>`],
]);

differs("generated.url", "content: url() in ::before / ::after", [
  ["block", `<style>.x::before{content:url(${PNG});display:block}</style><div class="x" style="${D}">mid</div>`, { check: naturalPng, text: false }],
  ["block-sized", `<style>.x::before{content:url(${PNG});display:block;width:30px;height:12px}</style><div class="x" style="${D}">mid</div>`, { check: naturalPng }],
  ["inline-block-sized", `<style>.x::before{content:url(${SVG});display:inline-block;width:20px;height:20px}</style><div class="x" style="${D}">mid</div>`, { check: naturalSvg }],
  ["absolute", `<style>.x{position:relative}.x::before{content:url(${PNG});position:absolute;right:0;top:0}</style><div class="x" style="${D};width:100px">mid</div>`, { check: naturalPng }],
  ["absolute-ancestor", `<style>.x::after{content:url(${SVG});position:absolute;left:5px;bottom:5px}</style><div style="position:relative;height:80px;${D}"><div class="x">mid</div></div>`, { check: naturalSvg }],
], "a generated image is an inline replaced box at its natural size on the pseudo's line, as in browsers; takumi makes it a block-level box that fills the pseudo's width (capped at its height), e.g. an 8 px PNG 180 px wide in a display:block ::before", { draw: false });

const tall = (pseudo) => `<style>.x::${pseudo}{content:url(${PNG});display:block;width:40px;height:40px}</style>`;
same("generated.url.pages", "content: url() across page breaks", [
  ["inline-every-item", `<style>p::before{content:url(${SVG})}</style>${Array.from({ length: 10 }, (_, i) => `<p style="${D}">para ${i + 1}</p>`).join("")}`, { options: PAGED }],
]);

differs("generated.url.pages", "content: url() across page breaks", [
  ["before-at-break", `${tall("before")}<div style="height:80px;${D}"></div><div class="x" style="${D}">mid</div>`],
  ["after-at-break", `${tall("after")}<div style="height:50px;${D}"></div><div class="x" style="${D}">mid text</div>`],
], "the generated image keeps its natural size in the 40 x 40 px pseudo box (takumi: fills it); the pseudo box moves to the next page as takumi's does", { options: PAGED, draw: false, check: (t, r) => { naturalPng(t, r); t.ok(imageDraws(r)[0] === 0 && imageDraws(r)[1] === 1, "the generated image is drawn once, on page 2"); } });

differs("generated.url.tagged", "content: url() structure", [
  ["before", `<style>.x::before{content:url(${PNG})}</style><div class="x" style="${D}">mid</div>`],
], "a generated image stays in the P of its line; takumi gives it a P of its own (docs/PDF_AUDIT.md `content: url()`, tagging.generated.mixed-image)", {
  options: TAGGED, draw: true,
  check: (t, r) => { t.ok((r.structure.tree.match(/^\s*P\b/gm) || []).length === 1, "one P"); },
});
differs("generated.url.tagged", "content: url() structure", [
  ["block", `<style>.x::before{content:url(${PNG});display:block}</style><div class="x" style="${D}">mid</div>`, { text: false }],
], "a generated image is an inline replaced box at its natural size; takumi fills the block pseudo's width (and pushes the text below the page)", { options: TAGGED, draw: false, check: naturalPng });

// A prepared document: the generated image and the image marker come from a fetched URL, on both engines.
probeAs("generated.url.prepared", "content: url() / list-style-image fetched by prepare", async (t) => {
  const png = Buffer.from(PNG.split(",")[1], "base64");
  const html = `<style>.x::before{content:url(https://example.test/gen.png)}</style><div class="x" style="${D}">mid</div><ul style="${S};list-style-image:url(https://example.test/marker.png)"><li>one</li></ul>`;
  const run = async (mod) => {
    const fetched = [];
    const r = new mod.PdfRenderer();
    try {
      await r.registerFont(inter);
      const p = await r.prepare(html, { ...PAGE, images: { fetch: async (url) => { fetched.push(String(url)); return new Response(png); } } });
      return { fetched: fetched.sort(), bytes: await r.render(p) };
    } finally { r.free?.(); }
  };
  const bm = await run(bmMod);
  t.ok(bm.fetched.length === 2, `bm fetches both images: ${bm.fetched.join(", ")}`);
  if (!t.hasRef) { t.same("reference", 0, 0); return; }
  const ref = await run(refMod);
  t.same("fetched urls", bm.fetched, ref.fetched);
  const a = await inspect(bm.bytes); const b = await inspect(ref.bytes);
  t.same("pdf.js text", a.pages.map((p) => p.text), b.pages.map((p) => p.text));
  const d = await raster(bm.bytes, ref.bytes, 1);
  t.ok(d.changed === 0, `raster: ${d.changed} changed pixels, largest channel difference ${d.max}`);
});

