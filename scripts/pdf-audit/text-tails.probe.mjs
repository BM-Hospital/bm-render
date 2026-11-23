// Text tails against the pinned reference (todo tasks 08–10, 28, 29): text-control presentation
// (input / textarea / select), `unicode-bidi` overrides and `plaintext`, `text-overflow` /
// `line-clamp` markers with spans and right-to-left text, tabs / pre-wrap spaces / soft hyphens.
// Each case compares the draw lists (paint.probe.mjs `cmp`: q/Q and clip grouping may differ),
// the text pdftotext and pdf.js extract, and the pdf.js raster (2x). Deliberate differences
// assert bm-render's own behaviour and are reported with `t.differs`.
import { INTER, font, squash } from "./lib.mjs";
import { canonPages, cmp, probeAs, vp } from "./paint.probe.mjs";
import { inspect, renderPage } from "../../bench/pdf/lib/pdfjs.mjs";

const inter = { name: "Inter", data: font(INTER) };
const arabic = { name: "Scheherazade New", data: font("assets/fonts/sil/scheherazade-new-v17-arabic-regular.woff2") };
/** Page 1 of a render as one string of canonical content tokens. */
const ops = (r) => canonPages(r)[0].map((x) => (typeof x === "object" ? JSON.stringify(x) : String(x))).join(" ");
const BIDI = [inter, arabic];
const PAGE = vp(300, 140);
const PAGED = { size: { width: 200, height: 100 }, margin: 0, tagged: false };

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

/** Draw list, extracted text (pdftotext and pdf.js) and raster equal to the reference. */
function same(prefix, feature, list, defaults = {}) {
  for (const [id, html, o = {}] of list) {
    probeAs(`${prefix}.${id}`, feature, async (t) => {
      const fonts = o.fonts || defaults.fonts || [inter];
      const options = o.options || defaults.options || PAGE;
      const grouping = o.grouping || defaults.grouping;
      let r;
      if (grouping) {
        // run grouping only (task 29): the same glyphs at the same positions (raster below), the
        // same extracted text; the TJ / text-object split is not compared
        r = await t.both(html, options, { fonts });
        t.ok(!r.bm.error, "bm renders" + (r.bm.error ? ": " + r.bm.error : ""));
        if (!r.ref || r.bm.error || r.ref.error) { t.same("error", r.bm.error ?? null, r.ref?.error ?? null); return; }
        t.same("page count", r.bm.pages.length, r.ref.pages.length);
        t.differs(`run grouping only: ${grouping}`);
      } else r = await cmp(t, "", html, options, { fonts });
      if (!r.ref || r.bm.error || r.ref.error) return;
      t.same("pdftotext", squash(r.bm.text), squash(r.ref.text));
      const a = await inspect(r.bm.bytes); const b = await inspect(r.ref.bytes);
      t.same("pdf.js text (visual order)", a.pages.map((p) => p.text), b.pages.map((p) => p.text));
      const d = await raster(r.bm.bytes, r.ref.bytes, Math.min(a.pages.length, b.pages.length));
      t.ok(d.changed >= 0 && d.max <= (o.maxDiff ?? 0), `raster: ${d.changed} changed pixels, largest channel difference ${d.max}`);
      for (const secret of o.hidden || []) t.ok(!r.bm.text.includes(secret) && !a.pages.some((p) => p.text.includes(secret)), `"${secret}" stays out of the text layer`);
    });
  }
}

/** A documented difference: bm-render's own expectations, the reference's output only noted. */
function differs(id, feature, html, why, check, { fonts = [inter], options = PAGE } = {}) {
  probeAs(id, feature, async (t) => {
    const r = await t.both(html, options, { fonts });
    t.ok(!r.bm.error, "bm renders" + (r.bm.error ? ": " + r.bm.error : ""));
    if (r.bm.error) return;
    const bm = await inspect(r.bm.bytes);
    await check(t, r.bm, bm);
    if (r.ref && !r.ref.error) {
      const ref = await inspect(r.ref.bytes);
      t.differs(`${why} (takumi text: ${JSON.stringify(ref.pages.map((p) => p.text))})`);
    } else if (r.ref) t.differs(`${why} (takumi: ${r.ref.error})`);
  });
}

// ------------------------------------------------------------------------------------------------ 08 input text

const S = "margin:10px;font:14px Inter";
const input = (attrs, style = "") => `<div><input ${attrs} style="${S};${style}"></div>`;
same("text.form.input", "form-control text: input value / placeholder / password", [
  ["value", input(`value="Hello world"`)],
  ["value-root", `<input value="Root" style="${S}">`],
  ["placeholder", input(`placeholder="Your name"`), { hidden: ["Your name"] }],
  ["value-and-placeholder", input(`value="Val" placeholder="Ph"`), { hidden: ["Ph"] }],
  ["password", input(`type="password" value="secret"`), { hidden: ["secret"] }],
  ["password-unicode", input(`type="password" value="秘密é"`), { hidden: ["秘", "é"] }],
  ["password-placeholder", input(`type="password" placeholder="pw"`), { hidden: ["pw"] }],
  ["color", input(`value="Red text"`, "color:#c00")],
  ["clip", input(`value="A very long value that is clipped by the field"`, "width:80px")],
  ["ellipsis", input(`value="A very long value that is clipped"`, "width:80px;text-overflow:ellipsis")],
  ["disabled", input(`value="Disabled" disabled`)],
  ["readonly", input(`value="Read only" readonly`)],
  ["fieldset-disabled", `<fieldset disabled style="${S}"><input value="fs"></fieldset>`],
  ["number", input(`type="number" value="-1.5e3"`)],
  ["number-invalid", input(`type="number" value="abc"`), { hidden: ["abc"] }],
  ["email-trimmed", input(`type="email" value=" a@b.co "`)],
  ["url-trimmed", input(`type="url" value="  http://x.y  "`)],
  ["line-breaks-stripped", input(`value="a&#10;b&#13;c"`)],
  ["search-border-box", input(`type="search" value="find"`)],
  ["tel-ltr", `<div dir="rtl">${input(`type="tel" value="+1 234"`)}</div>`],
  ["unknown-type", input(`type="foo" value="unknown"`)],
  ["hidden", `<p style="${S}">x<input type="hidden" value="secret">y</p>`, { hidden: ["secret"] }],
  ["checkbox-value", input(`type="checkbox" value="nope"`), { hidden: ["nope"] }],
  ["styled", input(`value="Styled"`, "border:3px solid blue;padding:6px;background:#eef;font-weight:bold;text-align:center;width:150px")],
  ["text-align-right", input(`value="Right"`, "text-align:right")],
  ["padding", input(`value="Pad"`, "padding:10px 20px")],
  ["letter-spacing", input(`value="Spaced"`, "letter-spacing:3px")],
  ["size-attribute", input(`value="Sized" size="5"`)],
  ["height-centred", input(`value="Tall"`, "height:50px")],
  ["height-short", input(`value="x"`, "height:4px")],
  ["border-box-height", input(`value="BB"`, "box-sizing:border-box;width:100px;height:40px")],
  ["line-height", input(`value="LH"`, "line-height:40px")],
  ["font-large", input(`value="Big"`, "font-size:30px")],
  ["inline-baseline", `<p style="${S}">Before <input value="Mid" style="font:14px Inter"> after</p>`],
  ["rtl", input(`value="Hello world" dir="rtl"`, "width:150px")],
  ["tagged", `<p style="font:14px Inter">Name <input value="Zed" style="font:14px Inter"> <input type="password" value="hunter2" style="font:14px Inter"></p>`, { options: { ...PAGE, tagged: true }, hidden: ["hunter2"] }],
]);

// takumi lets a block-level / flex text field fill its container (form_control_tests.rs
// `a_text_field_lays_out_as_a_block_container_whatever_its_display`); Blink's
// `LayoutBox::AutoWidthShouldFitContent` keeps the intrinsic width of a block-level input, as bm-render does.
differs("text.form.input.display-block-width", "form-control text: input value / placeholder / password",
  `<div style="width:300px"><input value="Block" style="${S};display:block"><input value="Flex" style="${S};display:flex"></div>`,
  "block-level / flex text field: bm keeps the intrinsic 226px width (Blink AutoWidthShouldFitContent), takumi stretches it",
  (t, bm) => { t.ok(bm.text.includes("Block") && bm.text.includes("Flex"), "values painted"); t.ok((ops(bm).match(/ 226 23 re /g) || []).length >= 2, "both fields keep the 226px intrinsic width"); });

// ------------------------------------------------------------------------------------------------ 09 textarea / select

same("text.form.textarea", "form-control text: textarea lines and select options", [
  ["lines", `<div><textarea style="${S}">one\ntwo\nthree</textarea></div>`],
  ["rows-cols", `<div><textarea rows="4" cols="10" style="${S}">one\ntwo</textarea></div>`],
  ["crlf", `<div><textarea style="${S}">one&#13;&#10;two&#13;three</textarea></div>`],
  ["final-newline", `<div><textarea style="${S}">one\n</textarea></div>`],
  ["placeholder", `<div><textarea placeholder="Write here" style="${S}"></textarea></div>`, { hidden: ["Write here"] }],
  ["wrap", `<div><textarea cols="8" style="${S}">a long line of words that wraps around</textarea></div>`, { grouping: "takumi splits tabs / preserved spaces into runs of their own" }],
  ["wrap-off", `<div><textarea cols="8" wrap="off" style="${S}">a long line of words that wraps around</textarea></div>`],
  ["long-word", `<div><textarea cols="5" style="${S}">Supercalifragilistic</textarea></div>`],
  ["overflow-rows", `<div><textarea rows="2" style="${S}">1\n2\n3\n4\n5</textarea></div>`],
  ["spaces-editable", `<div><textarea style="${S};white-space:normal">a    b</textarea></div>`],
  ["spaces-readonly", `<div><textarea readonly style="${S};white-space:normal">a    b</textarea></div>`],
  ["tabs", `<div><textarea style="${S}">a\tb\tc</textarea></div>`, { grouping: "takumi splits tabs / preserved spaces into runs of their own" }],
  ["disabled", `<div><textarea disabled style="${S}">dis\nabled</textarea></div>`],
  ["styled", `<div><textarea style="${S};color:#060;border:2px dashed red;padding:8px;width:140px;height:60px;text-align:center">styled\ntext</textarea></div>`],
  ["inherit", `<div style="font:14px Inter;color:#060"><textarea style="font:inherit;color:inherit">inh\nerit</textarea></div>`],
  ["page-boundary", `<div style="height:60px"></div><textarea rows="3" style="font:14px Inter">l1\nl2\nl3</textarea>`, { options: PAGED }],
  ["tagged", `<textarea style="font:14px Inter">a\nb</textarea>`, { options: { ...PAGE, tagged: true } }],
]);

// A textarea taller than the page: takumi-pdf (pinned) paints none of its lines on any page, or
// loops to its 20 000-page limit when it starts a page; bm-render slices it like any monolithic
// box, every line once.
differs("text.form.textarea.taller-than-page", "form-control text: textarea lines and select options",
  `<div style="height:60px"></div><textarea rows="6" style="font:14px Inter">l1\nl2\nl3\nl4\nl5\nl6</textarea>`,
  "textarea taller than the page: takumi loses every line, bm keeps each line once",
  (t, _bm, j) => t.ok(JSON.stringify(j.pages.map((p) => p.text)) === JSON.stringify(["", "l1 l2 l3 l4 l5", "l6"]), `lines once each: ${JSON.stringify(j.pages.map((p) => p.text))}`),
  { options: PAGED });
differs("text.form.textarea.taller-than-page-top", "form-control text: textarea lines and select options",
  `<textarea rows="8" style="font:14px Inter">l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8</textarea>`,
  "textarea taller than the page at the page top: takumi fails after 20 000 pages, bm slices it",
  (t, _bm, j) => t.ok(j.pages.length <= 3 && j.pages.map((p) => p.text).join(" ").split(/\s+/).filter(Boolean).join(" ") === "l1 l2 l3 l4 l5 l6 l7 l8", `lines once each: ${JSON.stringify(j.pages.map((p) => p.text))}`),
  { options: PAGED });

// takumi has no select presentation: options lay out as content, hidden ones included.
same("text.form.select", "form-control text: textarea lines and select options", [
  ["selected", `<select style="${S}"><option>One</option><option selected>Two</option></select>`],
  ["first", `<select style="${S}"><option>One</option><option>Two</option></select>`],
  ["disabled-first", `<select style="${S}"><option disabled>One</option><option>Two</option></select>`],
  ["hidden-option", `<select style="${S}"><option hidden>Hidden</option><option selected>Shown</option></select>`],
  ["multiple", `<select multiple style="${S}"><option>One</option><option selected>Two</option><option>Three</option></select>`],
  ["size", `<select size="3" style="${S}"><option>One</option><option>Two</option><option>Three</option><option>Four</option></select>`],
  ["optgroup", `<select style="${S}"><optgroup label="G"><option>A</option></optgroup><option selected>B</option></select>`],
  ["disabled", `<select disabled style="${S}"><option>One</option></select>`],
  ["styled", `<select style="${S};padding:6px;border:2px solid blue;text-align:center;width:120px"><option>One</option><option selected>Two</option></select>`],
  ["option-styled", `<select style="${S}"><option style="font-weight:bold;color:blue;padding:4px" selected>Bold</option></select>`],
  ["narrow", `<select style="${S};width:60px"><option>A very long option text</option></select>`],
  ["rtl", `<select dir="rtl" style="${S};width:120px"><option>Hello</option></select>`],
  ["inherit-font", `<div style="font:14px Inter"><select style="font:inherit"><option>One</option><option style="color:red" selected>Two</option></select></div>`],
  ["empty", `<select style="${S}"></select>`],
  ["page-boundary", `<div style="height:70px"></div><select style="font:14px Inter;display:block"><option>One</option><option selected>Two</option></select><p style="font:14px Inter;margin:0">after</p>`, { options: PAGED }],
  ["tagged", `<select style="font:14px Inter"><option>One</option><option selected>Two</option></select>`, { options: { ...PAGE, tagged: true } }],
]);

// ------------------------------------------------------------------------------------------------ 10 unicode-bidi

const bp = (style, html) => `<p style="margin:10px;font:20px Inter,'Scheherazade New';${style}">${html}</p>`;
same("text.bidi-override", "unicode-bidi overrides and plaintext", [
  ["span-rtl", bp("", `override: <span style="direction:rtl;unicode-bidi:bidi-override">hello world</span>`)],
  ["block-rtl", bp("direction:rtl;unicode-bidi:bidi-override", "block override")],
  ["block-ltr-arabic", bp("direction:ltr;unicode-bidi:bidi-override", "مرحبا بالعالم")],
  ["span-ltr-arabic", bp("", `x <span style="direction:ltr;unicode-bidi:bidi-override">مرحبا بالعالم</span> y`)],
  ["embed", bp("", `embed: <span style="direction:rtl;unicode-bidi:embed">1 2 3</span> end`)],
  ["isolate", bp("", `isolate: <span style="direction:rtl;unicode-bidi:isolate">1 2 3</span> end`)],
  ["isolate-override-span", bp("", `a <span style="direction:rtl;unicode-bidi:isolate-override">hello 12</span> b`)],
  ["isolate-override-block", bp("direction:rtl;unicode-bidi:isolate-override", "hello 12 world")],
  ["nested", bp("", `a <span style="direction:rtl;unicode-bidi:bidi-override">abc <span style="direction:ltr;unicode-bidi:bidi-override">def</span> ghi</span> z`)],
  ["nested-in-rtl", bp("direction:rtl", `a <span style="unicode-bidi:bidi-override">abc <span style="direction:ltr;unicode-bidi:isolate-override">def</span> ghi</span> z`)],
  ["inherited-direction", `<div style="direction:rtl"><p style="margin:10px;font:20px Inter;unicode-bidi:bidi-override">inherited rtl</p></div>`],
  ["inherited-span", `<div style="direction:rtl;font:20px Inter;margin:10px">x <span style="unicode-bidi:bidi-override">inherit span</span> y</div>`],
  ["bdo-ltr-arabic", bp("", `a <bdo dir="ltr">مرحبا</bdo> b`)],
  ["arabic-rtl", bp("direction:rtl;unicode-bidi:bidi-override", "مرحبا بالعالم")],
  ["mixed", bp("direction:rtl;unicode-bidi:bidi-override", "abc مرحبا 123")],
  ["ligature", bp("direction:rtl;unicode-bidi:bidi-override", "office fifty")],
  ["wrap", bp("direction:rtl;unicode-bidi:bidi-override;width:120px", "one two three four five")],
  ["decorated", bp("direction:rtl;unicode-bidi:bidi-override;text-decoration:underline", "under line")],
  ["colored-spans", bp("direction:rtl;unicode-bidi:bidi-override", `ab<span style="color:red">cd</span>ef`)],
  ["emoji", `<p style="margin:10px;font:20px Inter,Twemoji;direction:rtl;unicode-bidi:bidi-override">a😀b👍🏽c</p>`, { fonts: [inter, { name: "Twemoji", data: font("assets/fonts/twemoji/TwemojiMozilla-colr.woff2") }] }],
  ["combining", `<p style="margin:10px;font:20px 'Archivo Combining';direction:rtl;unicode-bidi:bidi-override">éáb</p>`, { fonts: [{ name: "Archivo Combining", data: font("takumi-pdf/tests/fonts/archivo-combining.subset.ttf") }] }],
  ["plaintext-fixture", bp("unicode-bidi:plaintext", "plaintext paragraph<br>مرحبا بالعالم")],
  ["plaintext-arabic", bp("unicode-bidi:plaintext;width:260px", "مرحبا بالعالم")],
  ["plaintext-arabic-then-latin", bp("unicode-bidi:plaintext;width:260px", "مرحبا بالعالم<br>latin line")],
  ["plaintext-rtl-latin", bp("unicode-bidi:plaintext;direction:rtl;width:260px", "latin first")],
  ["plaintext-pre", bp("unicode-bidi:plaintext;white-space:pre;width:260px", "abc\nمرحبا\ndef")],
  ["plaintext-neutral", bp("unicode-bidi:plaintext;direction:rtl;width:260px", "123 !")],
  ["plaintext-wrap", bp("unicode-bidi:plaintext;width:80px", "مرحبا بالعالم مرحبا بالعالم")],
  ["plaintext-end", bp("unicode-bidi:plaintext;text-align:end;width:260px", "abc<br>مرحبا")],
  ["plaintext-center", bp("unicode-bidi:plaintext;text-align:center;width:260px", "abc<br>مرحبا")],
  ["plaintext-span", bp("width:260px", `x <span style="unicode-bidi:plaintext">مرحبا</span> y`)],
  ["plaintext-numbers", bp("unicode-bidi:plaintext;width:260px", "مرحبا 123 abc")],
  ["ordinary-arabic", bp("", "مرحبا بالعالم")],
  ["ordinary-mixed-rtl", bp("direction:rtl", "abc مرحبا def 123")],
], { fonts: BIDI });

// ------------------------------------------------------------------------------------------------ 28 ellipsis / RTL

const narrow = "width:120px;white-space:nowrap;overflow:hidden;";
const clamp = "width:120px;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden;";
same("text.overflow-tail", "text-overflow / line-clamp markers: brush, paint order, RTL", [
  ["span-color", bp(narrow + "text-overflow:ellipsis", `A long <span style="color:red">line that does not fit</span>`)],
  ["span-before-cut", bp(narrow + "text-overflow:ellipsis", `A <span style="color:red">lo</span>ng line that does not fit`)],
  ["span-cut-inside", bp(narrow + "text-overflow:ellipsis", `A lo<span style="color:red">ng line</span> that does not fit`)],
  ["span-alpha", bp(narrow + "text-overflow:ellipsis", `A long <span style="color:rgba(255,0,0,.5)">line that does not fit</span>`)],
  ["span-bold", bp(narrow + "text-overflow:ellipsis", `A long <span style="font-weight:bold;color:red">line that does not fit</span>`)],
  ["span-nested", bp(narrow + "text-overflow:ellipsis", `A <span style="color:red">long <span style="color:blue">line that</span> does</span> not fit`)],
  ["custom-string", bp(narrow + "text-overflow:'>>'", `A long <span style="color:red">line that does not fit</span>`)],
  ["padding-clip", bp(narrow + "text-overflow:ellipsis;padding:0 5px", `A long <span style="color:red">line that does not fit</span>`)],
  ["hidden-text", bp(narrow + "text-overflow:ellipsis", "Visible start then hidden SECRETWORD"), { hidden: ["SECRETWORD"] }],
  ["rtl-latin", bp(narrow + "text-overflow:ellipsis;direction:rtl", "A long line that does not fit")],
  ["rtl-span", bp(narrow + "text-overflow:ellipsis;direction:rtl", `A long <span style="color:red">line that does not fit</span>`)],
  ["rtl-arabic", bp(narrow + "text-overflow:ellipsis;direction:rtl", "مرحبا بالعالم مرحبا بالعالم مرحبا")],
  ["rtl-arabic-span", bp(narrow + "text-overflow:ellipsis;direction:rtl", `مرحبا <span style="color:red">بالعالم مرحبا بالعالم</span> مرحبا`)],
  ["clamp-span", bp(clamp, `Clamped text <span style="color:red">over many many lines</span> of text`)],
  ["clamp-span-tail", bp(clamp, `Clamped text over <span style="color:red">many many lines of text</span>`)],
  ["clamp-standard-span", bp("width:120px;line-clamp:2;overflow:hidden", `Clamped text <span style="color:red">over many many lines</span> of text`)],
  ["clamp-rtl", bp(clamp + "direction:rtl", "Clamped text over many many lines of text")],
  ["clamp-arabic", bp(clamp + "direction:rtl", "مرحبا بالعالم مرحبا بالعالم مرحبا بالعالم مرحبا بالعالم")],
  // takumi paints one underline per run (content, then marker); bm one across both: the seam
  // between the two rectangles antialiases differently (6 pixels at 2x, channel difference 55)
  ["span-underline", bp(narrow + "text-overflow:ellipsis", `A long <span style="text-decoration:underline;color:green">line that does not fit</span>`), { maxDiff: 60, grouping: "takumi draws the underline per run, content then marker" }],
], { fonts: BIDI });

// takumi-pdf places the marker 10px below the line's baseline when a taller span precedes it;
// bm-render keeps it on the baseline (Blink `LineTruncator::PlaceEllipsisNextTo`).
differs("text.overflow-tail.taller-span-baseline", "text-overflow / line-clamp markers: brush, paint order, RTL",
  bp(narrow + "text-overflow:ellipsis", `A long <span style="font-size:30px;color:blue">line that</span> does not fit`),
  "a marker after a taller span: bm keeps it on the line's baseline, takumi drops it by the span's extra ascent",
  (t, bm, j) => {
    t.ok(j.pages[0].text.endsWith("…"), "marker extracted after the content");
    // every text object of the line, the marker included, on one baseline (y 29 in the 0.75 cm space)
    const ys = [...ops(bm).matchAll(/ 1 0 0 -1 \S+ (\S+) Tm/g)].map((m) => m[1]);
    t.ok(ys.length >= 3 && ys.every((y) => y === ys[0]), `one baseline: ${ys.join(", ")}`);
  },
  { fonts: BIDI });
// Bidi text in a line of the other direction: what overflows is hidden at the line's visual end
// (CSS Overflow 3; Blink's LineTruncator works in visual order, as takumi), so the visual-left,
// logically last Arabic words of a left-to-right line stay.
same("text.overflow-tail", "text-overflow / line-clamp markers: brush, paint order, RTL", [
  ["visual-truncation-ltr-arabic", bp(narrow + "text-overflow:ellipsis", "مرحبا بالعالم مرحبا بالعالم مرحبا")],
  ["visual-truncation-ltr-mixed", bp(narrow + "text-overflow:ellipsis", "abc مرحبا بالعالم def ghi")],
  ["visual-truncation-ltr-mixed-span", bp(narrow + "text-overflow:ellipsis", `abc <span style="color:red">مرحبا</span> بالعالم def ghi`)],
  ["visual-truncation-rtl-latin-run", bp(narrow + "text-overflow:ellipsis;direction:rtl", "مرحبا abc def ghi jkl بالعالم")],
  ["visual-truncation-rtl-digits", bp(narrow + "text-overflow:ellipsis;direction:rtl", "مرحبا 12345 67890 بالعالم")],
], { fonts: BIDI });

// ------------------------------------------------------------------------------------------------ 29 tabs / pre-wrap / soft hyphen

const tp = (style, html) => `<p style="margin:10px;font:20px Inter;${style}">${html}</p>`;
same("text.whitespace", "tabs, pre-wrap spaces and soft hyphens in the text layer", [
  ["tab-normal", tp("", "a\tb")],
  ["pre-line", tp("white-space:pre-line", "a   b\n  c")],
  ["pre", tp("white-space:pre", "  x  y  ")],
  ["nbsp-pre-wrap", tp("white-space:pre-wrap", "a&nbsp;&nbsp; b")],
  ["soft-hyphen-break", tp("width:60px;hyphens:manual", "extra&shy;ordinary")],
  ["soft-hyphen-no-break", tp("hyphens:manual", "extra&shy;ordinary")],
  ["soft-hyphen-none", tp("width:60px;hyphens:none", "extra&shy;ordinary")],
  ["soft-hyphen-multi", tp("width:50px;hyphens:manual", "su&shy;per&shy;cal&shy;i&shy;fra")],
  ["soft-hyphen-clipped", tp("width:60px;hyphens:manual;height:24px;overflow:hidden", "extra&shy;ordinary words")],
  ["soft-hyphen-rtl", tp("width:60px;hyphens:manual;direction:rtl", "extra&shy;ordinary")],
  ["hyphens-auto", `<p lang="en" style="margin:10px;font:20px Inter;width:70px;hyphens:auto">extraordinary</p>`],
  ["clipped-text", tp("width:60px;height:24px;overflow:hidden", "visible HIDDENWORD below")],
]);
same("text.whitespace", "tabs, pre-wrap spaces and soft hyphens in the text layer", [
  ["tab-size", tp("white-space:pre;tab-size:4", "a\tb\tc")],
  ["tab-pre-wrap", tp("white-space:pre-wrap;width:120px", "a\tbb\tccc\tdddd\te")],
  ["tab-leading", tp("white-space:pre", "\tlead")],
  ["tab-trailing", tp("white-space:pre-wrap", "trail\t")],
  ["tab-span", tp("white-space:pre", `a\t<span style="color:red">b</span>\tc`)],
  ["pre-wrap", tp("white-space:pre-wrap", "a   b\n  c")],
  ["pre-wrap-wrap", tp("white-space:pre-wrap;width:80px", "aaa    bbb    ccc")],
  ["pre-wrap-trailing", tp("white-space:pre-wrap;width:80px", "aaaa      ")],
  ["break-spaces", tp("white-space:break-spaces;width:80px", "aaa    bbb")],
], { grouping: "takumi splits tabs / preserved spaces into runs of their own" });

// takumi's `tab-size` is a number of spaces only (TabSize::spaces); a <length> resolves to other
// stops there (22.5px apart for 30px). bm-render follows CSS Text 3: stops every 30px.
differs("text.whitespace.tab-size-length", "tabs, pre-wrap spaces and soft hyphens in the text layer",
  tp("white-space:pre;tab-size:30px", "a\tb\tc"), "tab-size <length>: bm puts stops every 30px, takumi 22.5px apart",
  (t, _bm, j) => t.ok(j.pages[0].text.replace(/\s+/g, " ") === "a b c", "text a b c"));
// The hyphen of a soft hyphen at the start of a span: the line ends in the span's item, so the
// hyphen takes the span's style (Blink, Firefox and takumi), not the preceding text's.
same("text.whitespace", "tabs, pre-wrap spaces and soft hyphens in the text layer", [
  ["soft-hyphen-span-color", tp("width:60px;hyphens:manual", `extra<span style="color:red">&shy;ordinary</span>`)],
  ["soft-hyphen-span-size", tp("width:60px;hyphens:manual", `extra<span style="color:red;font-size:26px">&shy;ordinary</span>`)],
  ["soft-hyphen-before-span", tp("width:60px;hyphens:manual", `extra&shy;<span style="color:red">ordinary</span>`)],
  // not broken there: the pair kerning across the soft hyphen stays
  ["soft-hyphen-span-kern", tp("hyphens:manual", `AV A<span style="color:red">&shy;V</span> T<span style="color:red">&shy;o</span>`)],
  ["soft-hyphen-span-kern-break", tp("width:30px;hyphens:manual", `TA<span style="color:red">&shy;VA</span>`)],
  ["soft-hyphen-kern-break", tp("width:30px;hyphens:manual", `TA&shy;VA`)],
]);
