// Boxes at page boundaries (tasks 03–07, 25), compared with the pinned reference: draw list per
// page, extracted text per page, structure / parent trees and link annotations.
//
// * paint.transform-fragment.*: a rotated, skewed or scaled box a page boundary cuts paints each
//   fragment in its own transformed space, with the lines, child boxes, nested transformed boxes
//   and links laid out in it; a transformed box reaching another page paints there with the pass
//   of the page it is laid out on (decorations, then its content: as text on the page owning the
//   line, outlines elsewhere); a fragment whose box and lines miss a page opens no (empty)
//   content region there.
// * paint.clip-fragment.*: overflow clips at a page boundary: nested clips, an absolutely
//   positioned box escaping a clip (its own pages, fragments and text), a line the clip cuts above
//   its baseline, a clip under a transform.
// * paint.inline-fragment.*: inline span backgrounds / borders / outlines wrapping over lines and
//   pages: the image strip of a sliced span is the span's fragments in the paragraph's fragment on
//   that page, positioned in the strip's padding box; a span's fragment paints on every page its
//   border box reaches; the paragraph's regions follow its spans' reach (`span_ink_reach`).
// * text.background-clip-fragment.*: `background-clip: text` with nested spans, opacity,
//   transforms, clip ancestors, decorations and ligatures (ToUnicode / ActualText).
import { probe } from "./lib.mjs";
import { cmp } from "./paint.probe.mjs";
import { annots, sameWithin } from "./filelayer.util.mjs";

const P = { size: { width: 300, height: 200 }, margin: 10 };
const V = { viewport: { width: 260, height: 160 } };
const F = "font:14px Inter";
const lines = (n, p = "L") => Array.from({ length: n }, (_, i) => `${p}${i + 1}`).join("<br>");
// `pre` px of content before the box: the boundary (180 px) cuts it, or it starts on the next
// page and its corner reaches back
const wrap = (pre, inner, parent = "") => `<div style="${F};${parent}"><div style="height:${pre}px;background:#eee">A</div>${inner}<div>after</div></div>`;

const compare = (id, feature, html, options = P) => probe(id, feature, async (t) => {
  const r = await cmp(t, "paint", html, options);
  if (!r.bm || !r.ref || r.bm.error || r.ref.error) return;
  t.same("text per page", r.bm.textPages, r.ref.textPages);
  t.same("structure", r.bm.structure, r.ref.structure);
  sameWithin(t, "link annotations", annots(r.bm), annots(r.ref));
});

// ------------------------------------------------------------------------------------------------ transforms

for (const pre of [100, 150, 165, 185]) {
  for (const [id, html] of [
    [`rotate-fixed-height-${pre}`, wrap(pre, `<div style="transform:rotate(20deg);width:80px;height:40px;background:#c33">Rot</div>`)],
    [`rotate-auto-height-${pre}`, wrap(pre, `<div style="transform:rotate(15deg);width:90px;background:#c33">${lines(5)}</div>`)],
    [`rotate-in-bordered-parent-${pre}`, wrap(pre, `<div style="transform:rotate(15deg);width:90px;background:#c33">${lines(4)}</div>`, "border:3px solid #333;padding:4px")],
    [`rotate-clone-radius-${pre}`, wrap(pre, `<div style="transform:rotate(10deg);width:100px;border:4px solid #06c;border-radius:12px;box-decoration-break:clone;-webkit-box-decoration-break:clone;background:#fc3;padding:3px">${lines(5)}</div>`)],
    [`skew-${pre}`, wrap(pre, `<div style="transform:skewX(15deg);width:100px;background:#9c9">${lines(5)}</div>`)],
    [`scale-${pre}`, wrap(pre, `<div style="transform:scale(.8);width:100px;background:#9cf">${lines(5)}</div>`)],
    [`nested-${pre}`, wrap(pre, `<div style="transform:rotate(8deg);width:120px;background:#fcc;padding:2px"><div style="transform:skewX(10deg);background:#ccf">${lines(4, "N")}</div>${lines(2, "O")}</div>`)],
    [`child-box-${pre}`, wrap(pre, `<div style="transform:rotate(12deg);width:120px;background:#fcc;padding:2px"><div style="background:#ccf;border:2px solid #333">${lines(5, "C")}</div></div>`)],
    [`link-${pre}`, wrap(pre, `<div style="transform:rotate(12deg);width:120px;background:#fcc">${lines(2)}<br><a href="https://example.com/x">link</a><br>${lines(2, "M")}</div>`)],
  ]) compare(`paint.transform-fragment.${id}`, "Rotated / skewed boxes cut by a page boundary", html);
}

// a motion-path / rotated box in a positioned, bordered parent cut by the boundary: the box lifted
// from the page before's root fragment paints before the parent's fragment on this page
{
  const PM = { size: { width: 300, height: 400 }, margin: 20 };
  const mp = (s) => `<div style="position:relative;width:200px;height:120px;margin:10px;border:1px solid #999"><div style="width:60px;height:24px;background:#c33;font:14px Inter;${s}">Tx</div></div>`;
  for (const pre of [250, 290, 320, 340]) {
    compare(`paint.transform-fragment.positioned-parent-ray-${pre}`, "Rotated / skewed boxes cut by a page boundary", `<div style="height:${pre}px"></div>${mp("offset-path:ray(135deg closest-side);offset-distance:70%")}`, PM);
    compare(`paint.transform-fragment.positioned-parent-path-${pre}`, "Rotated / skewed boxes cut by a page boundary", `<div style="height:${pre}px"></div>${mp("offset-path:path('M0 0 L100 50');offset-distance:60%;offset-rotate:auto")}`, PM);
    compare(`paint.transform-fragment.positioned-parent-rotate-${pre}`, "Rotated / skewed boxes cut by a page boundary", `<div style="height:${pre}px"></div>${mp("transform:rotate(30deg);height:80px")}`, PM);
  }
}

// ------------------------------------------------------------------------------------------------ clips

const clipDoc = (pre, inner) => `<div style="${F}"><div style="height:${pre}px;background:#eee">A</div>${inner}<div>after</div></div>`;
const absIn = (ov, top, body) => `<div style="position:relative"><div style="${ov}height:70px;background:#cde">${lines(3, "S")}<div style="position:absolute;top:${top}px;left:100px;background:#fc3">${body}</div></div></div>`;
for (const [id, html] of [
  ["nested-120", clipDoc(120, `<div style="overflow:hidden;height:150px;border:2px solid #333"><div style="overflow:hidden;height:100px;margin:5px;background:#cde">${lines(20, "I")}</div>${lines(5, "O")}</div>`)],
  ["nested-150", clipDoc(150, `<div style="overflow:hidden;height:150px;border:2px solid #333"><div style="overflow:hidden;height:100px;margin:5px;background:#cde">${lines(20, "I")}</div>${lines(5, "O")}</div>`)],
  ["in-rotated-120", clipDoc(120, `<div style="transform:rotate(5deg);width:200px"><div style="overflow:hidden;height:90px;background:#cde">${lines(12, "R")}</div></div>`)],
  ["rotated-clip-120", clipDoc(120, `<div style="transform:rotate(5deg);width:200px;overflow:hidden;height:90px;background:#cde">${lines(12, "R")}</div>`)],
  ["baseline-cut-150", clipDoc(150, `<div style="overflow:hidden;height:60px;background:#cde">${lines(8, "B")}</div>`)],
  ["x-only-120", clipDoc(120, `<div style="overflow-x:hidden;height:80px;width:30px;background:#cde">${lines(10, "WIDEWORD")}</div>`)],
  // an absolutely positioned box escaping the clip: its own fragments on the pages it reaches
  ["abs-escapes-60", clipDoc(60, absIn("overflow:hidden;", 40, lines(5, "E")))],
  ["abs-escapes-blocks-60", clipDoc(60, absIn("overflow:hidden;", 40, "<div>E1</div><div>E2</div><div>E3</div><div>E4</div><div>E5</div>"))],
  ["abs-escapes-80", clipDoc(80, absIn("overflow:hidden;", 40, lines(5, "E")))],
  ["abs-escapes-120", clipDoc(120, absIn("overflow:hidden;", 40, lines(5, "E")))],
  ["abs-escapes-150", clipDoc(150, absIn("overflow:hidden;", 40, lines(5, "E")))],
  ["abs-no-clip-60", clipDoc(60, absIn("", 40, lines(5, "E")))],
]) compare(`paint.clip-fragment.${id}`, "overflow clipping across pages", html);

// A clip box ending at the page end, its lines overflowing it: same text and structure. takumi
// also repaints the box on the next page, above the page (nothing shows: its paint bounds count
// the clipped lines).
probe("paint.clip-fragment.baseline-cut-120", "overflow clipping across pages", async (t) => {
  const r = await t.both(clipDoc(120, `<div style="overflow:hidden;height:60px;background:#cde">${lines(8, "B")}</div>`), P);
  if (!r.ref) return t.same("reference", 0, 0);
  t.same("pages", r.bm.pages?.length, r.ref.pages?.length);
  if (r.bm.error || r.ref.error) return;
  t.same("text per page", r.bm.textPages, r.ref.textPages);
  t.same("structure", r.bm.structure, r.ref.structure);
  t.differs("takumi repaints the clip box on page 2 outside the page (its paint bounds include the clipped lines); bm-render does not");
});

// ------------------------------------------------------------------------------------------------ inline spans

const txt = "inline box that wraps over several lines here";
const spanV = (st) => `<p style="margin:20px;width:120px;font:16px Inter">a <span style="${st}">${txt}</span> b</p>`;
const spanP = (st) => `<div style="font:16px Inter"><div style="height:140px">A</div><p style="margin:0;width:120px">a <span style="${st}">${txt} and more words to cross</span> b</p></div>`;
const G = "background:linear-gradient(90deg,#f00,#00f)";
const CLONE = "box-decoration-break:clone;-webkit-box-decoration-break:clone";
for (const [id, st] of [
  ["gradient-slice", G],
  ["gradient-clone", `${G};${CLONE}`],
  ["radial-radius-slice", "background:radial-gradient(circle,#ff0,#0a0);border-radius:6px;padding:0 4px"],
  ["radial-radius-clone", `background:radial-gradient(circle,#ff0,#0a0);border-radius:6px;padding:0 4px;${CLONE}`],
  ["color-shadow", "background:#fc3;box-shadow:2px 2px 0 #333"],
]) {
  compare(`paint.inline-fragment.${id}`, "inline span backgrounds across lines", spanV(st), V);
  compare(`paint.inline-fragment.paged-${id}`, "inline span backgrounds across lines and pages", spanP(st));
}
// padding and border: the strip keeps the span's end borders (a pattern over its padding box)
compare("paint.inline-fragment.gradient-padding-border-slice", "inline span backgrounds across lines", spanV(`${G};padding:2px 6px;border:2px solid #000`), V);
compare("paint.inline-fragment.gradient-padding-border-clone", "inline span backgrounds across lines", spanV(`${G};padding:2px 6px;border:2px solid #000;${CLONE}`), V);
const inRotated = (st, body) => `<div style="${F}"><div style="height:100px">A</div><div style="transform:rotate(8deg);width:140px"><span style="${st}">${body}</span></div></div>`;
compare("paint.inline-fragment.rotated-background-paged", "inline span backgrounds across lines and pages", inRotated(`${G};padding:0 4px`, "inline background box that wraps over many lines across the page boundary here"));
compare("paint.inline-fragment.rotated-outline-paged", "Outlines of inline elements (one or several lines)", inRotated("outline:3px dashed #06c;border-radius:5px", "inline outline box that wraps over many lines across the page boundary here"));
compare("paint.inline-fragment.outline-dotted-paged", "Outlines of inline elements (one or several lines)", `<div style="${F}"><div style="height:120px">A</div><p style="margin:0;width:120px"><span style="outline:3px dotted #06c;border-radius:6px">inline outline box that wraps over many lines across the page boundary</span></p></div>`);

// ------------------------------------------------------------------------------------------------ background-clip: text

const CT = "background:linear-gradient(90deg,#f00,#00f);-webkit-background-clip:text;background-clip:text;color:transparent";
const words = "Gradient text that wraps over several lines in the block";
for (const [id, html, options] of [
  ["nested-spans", `<p style="margin:10px;font:20px Inter;width:200px;${CT}">One <span style="font-size:28px">big <b>bold</b></span> <i>it</i> end</p>`, V],
  ["span-nested", `<p style="margin:10px;font:20px Inter;width:220px">a <span style="${CT}">outer <span style="font-size:26px;letter-spacing:2px">inner</span> tail</span> b</p>`, V],
  ["opacity", `<p style="margin:10px;font:20px Inter;width:200px;opacity:.5;${CT}">${words}</p>`, V],
  ["transform", `<p style="margin:20px;font:20px Inter;width:200px;transform:rotate(6deg);${CT}">${words}</p>`, V],
  ["clip-ancestor", `<div style="overflow:hidden;height:50px;margin:10px"><p style="margin:0;font:20px Inter;width:200px;${CT}">${words}</p></div>`, V],
  ["decorations", `<p style="margin:10px;font:20px Inter;width:200px;text-decoration:underline overline;${CT}">${words}</p>`, V],
  ["ligatures", `<p style="margin:10px;font:20px Inter;${CT}">\u{FB01} office \u{FB02}ow</p>`, V],
  ["page-cut-span", `<div style="height:140px">A</div><p style="margin:0;font:20px Inter;width:200px">x <span style="${CT}">${words}</span> y</p>`, P],
]) compare(`text.background-clip-fragment.${id}`, "background-clip: text (blocks and inline spans, decorations in the mask)", html, options);
