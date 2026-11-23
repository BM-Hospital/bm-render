// Case-level ports of takumi-pdf's own Rust tests (tests/upstream/takumi/takumi-pdf/tests/pdf_fixtures.rs at the
// pinned revision) that no golden fixture covers. Each probe is named `upstream.<rust test function>`, renders the
// test's input (HTML for the Rust node builders; the test's page size, margins, fonts, tagging and standard) with
// both engines, and checks the facet the Rust test asserts: the value bm computes must equal takumi's, and where
// the Rust test pins a constant, bm must reach it too. scripts/pdf-coverage.mjs maps the Rust declaration to the
// probe by this name.
import { Buffer } from "node:buffer";
import { readFileSync } from "node:fs";
import path from "node:path";
import { probe, squash, sameError, takumiSrc, font, ARCHIVO, NOTO_TC, pngRgba } from "./lib.mjs";
import { wordBoxes } from "./paged-helpers.mjs";

/** takumi-pdf's `fonts()` (Archivo + Noto Sans TC) and `latin_font()`. */
const FONTS = [ARCHIVO, NOTO_TC];
const LATIN = [ARCHIVO];
const ARABIC = "assets/fonts/sil/scheherazade-new-v17-arabic-regular.woff2";
const DEVANAGARI = "assets/fonts/noto-sans/noto-sans-devanagari-v30-devanagari-regular.woff2";
const COMBINING = "takumi-pdf/tests/fonts/archivo-combining.subset.ttf";
const TC_CAPS = "takumi-pdf/tests/fonts/noto-sans-tc-caps.subset.ttf";
const page = (width, height, margin) => ({ size: { width, height }, margin });
const A4 = { size: "a4" };
const META = (title, month, day) => ({ title, creationDate: `2026-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}T00:00:00Z` });
/** `text(content, size)` of the Rust tests. */
const text = (content, size = 16) => `<div style="font-size:${size}px">${content}</div>`;
const dataUrl = (mime, bytes) => `data:${mime};base64,${Buffer.from(bytes).toString("base64")}`;

/** Every stream decoded plus the file itself: the Rust tests' `inflated_text`. */
const hay = (r) => Buffer.from(r.bytes).toString("latin1") + "\n" + [...r.pdf.objs.values()].map((o) => (o.data ? o.data.toString("latin1") : "")).join("\n");
const contents = (r) => r.pages.map((_, i) => r.content(i));
/** Text-showing operators (`Tj` / `TJ`) over every page: the Rust tests' `text_show_operators`. */
const shows = (r) => contents(r).reduce((n, c) => n + (c.match(/(?:\)|\]|>)\s*T[jJ]\b/g) || []).length, 0);
const showsPerPage = (r) => contents(r).map((c) => (c.match(/(?:\)|\]|>)\s*T[jJ]\b/g) || []).length);
/** Curve operators (`c`, `v`, `y`) over every page. */
const curves = (r) => contents(r).reduce((n, c) => n + (c.match(/(?:^|\s)[-\d.]+\s+[-\d.]+\s+[-\d.]+\s+[-\d.]+(?:\s+[-\d.]+\s+[-\d.]+)?\s+[cvy](?=\s|$)/g) || []).length, 0);
const count = (s, re) => (s.match(re) || []).length;
const structElems = (r, role) => [...r.pdf.objs.values()].filter((o) => o.dict && o.dict.S && o.dict.S.s === role && (o.dict.P || o.dict.K !== undefined)).length;

/** Renders on both engines; false when an engine failed (recorded as a failure, or the same error). */
async function render(t, source, options, fonts = FONTS, label = "render") {
  const r = await t.both(source, options, { fonts });
  if (!r.ref) { t.ok(!r.bm.error, `${label}: bm renders`); t.same(label, 0, 0); return null; }
  if (r.bm.error || r.ref.error) { t.same(`${label}: error`, r.bm.error || null, r.ref.error || null); return null; }
  return r;
}
/** The same value from both engines, and (when given) the constant the Rust test asserts. */
function check(t, what, f, r, expected) {
  const a = f(r.bm); const b = f(r.ref);
  t.same(what, a, b);
  if (expected !== undefined) t.ok(JSON.stringify(a) === JSON.stringify(expected), `${what}: bm ${JSON.stringify(a)}, the Rust test asserts ${JSON.stringify(expected)}`);
  return a;
}
const pagesAndText = (t, r, label = "") => {
  t.same(`${label}page count`, r.bm.pages.length, r.ref.pages.length);
  t.same(`${label}text per page`, r.bm.textPages.map(squash), r.ref.textPages.map(squash));
};
/** Page content of two bm renders must be the same (the Rust tests compare file bytes; bm's ids hash the file). */
const sameContent = (t, what, a, b) => t.ok(JSON.stringify(contents(a)) === JSON.stringify(contents(b)) && a.pages.length === b.pages.length, what);

// ---- page ranges ------------------------------------------------------------------------------------------------

probe("upstream.page_ranges_drop_destinations_to_dropped_pages", "pageRanges drop links and outline entries to dropped pages", async (t) => {
  const src = `<div style="display: flex; flex-direction: column; width: 100%; font-size: 14px; color: #141414;">
    <a href="#alpha" style="display: flex;">see alpha</a>
    <h1 style="font-size: 18px; margin: 0;">First</h1>
    <div id="alpha" style="display: flex; break-before: page;"><h1 style="font-size: 18px; margin: 0;">Alpha</h1></div>
  </div>`;
  const opts = { ...page(320, 240, 24), outline: true, tagged: false };
  const links = (r) => r.subtyped("Link").length;
  const titles = (r) => count(hay(r), /\/Title\s*[(<]/g);
  const full = await render(t, src, opts, FONTS, "full");
  const first = await render(t, src, { ...opts, pageRanges: [1] }, FONTS, "first page");
  if (full) { check(t, "full: links", links, full, 1); check(t, "full: outline titles", titles, full, 2); }
  if (first) { check(t, "first only: links", links, first, 0); check(t, "first only: outline titles", titles, first, 1); }
});

probe("upstream.page_ranges_selecting_no_page_reject_the_render", "pageRanges past the last page reject the render", async (t) => {
  const r = await t.both(text("short"), { ...A4, pageRanges: [{ from: 99 }] }, { fonts: FONTS });
  t.ok(!!r.bm.error, "bm rejects");
  sameError(t, "out of bounds", r.bm, r.ref);
});

// ---- tables -------------------------------------------------------------------------------------------------------

const rows30 = Array.from({ length: 30 }, (_, i) => `<tr><td>Item ${i + 1}</td><td>${(i + 1) * 3}</td></tr>`).join("");
const table = (head = "<thead><tr><th>Name</th><th>Qty</th></tr></thead>", before = "") => `<table style="width: 100%; font-size: 12px; color: #141414">
        ${before}${head}
        <tbody>${rows30}</tbody>
      </table>`;
const P400 = { ...page(400, 300, 24), tagged: false };

probe("upstream.a_table_header_repeats_on_every_page", "a thead repeats on every page; a table-row-group header does not", async (t) => {
  const repeating = await render(t, table(), P400, FONTS, "thead");
  const plain = await render(t, table(`<thead style="display: table-row-group"><tr><th>Name</th><th>Qty</th></tr></thead>`), P400, FONTS, "row group");
  if (!repeating || !plain) return;
  pagesAndText(t, repeating, "thead: "); pagesAndText(t, plain, "row group: ");
  const n = repeating.bm.pages.length;
  t.ok(n > 1, "the table paginates");
  t.ok(shows(repeating.bm) === shows(plain.bm) + 2 * (n - 1), `each continuation page repeats the two header cells (bm ${shows(repeating.bm)} vs ${shows(plain.bm)} + ${2 * (n - 1)})`);
});

probe("upstream.content_beside_a_table_does_not_replay_with_its_header", "content beside a table does not replay with its header", async (t) => {
  const doc = (beside) => `<div style="display: flex; font-size: 12px; color: #141414">
        <table style="width: 280px">
          <thead><tr><th>Name</th><th>Qty</th></tr></thead>
          <tbody>${rows30}</tbody>
        </table>
        ${beside}
      </div>`;
  const side = await render(t, doc("<div>Beside</div>"), P400, FONTS, "sidebar");
  const plain = await render(t, doc(""), P400, FONTS, "plain");
  if (!side || !plain) return;
  pagesAndText(t, side, "sidebar: ");
  t.ok(shows(side.bm) === shows(plain.bm) + 1, `the sidebar paints once (bm ${shows(side.bm)} vs ${shows(plain.bm)} + 1)`);
});

probe("upstream.a_tagged_rowspan_stays_in_its_row_group", "a tagged RowSpan stops at the end of its row group", async (t) => {
  const html = `<table>
    <thead><tr><th rowspan="0">Name</th><th>Qty</th></tr></thead>
    <tbody><tr><td>Item</td><td>3</td></tr><tr><td rowspan="5">Last</td><td>4</td></tr></tbody>
  </table>`;
  const r = await render(t, html, { ...A4, tagged: true });
  if (!r) return;
  check(t, "a RowSpan attribute", (x) => /\/RowSpan/.test(hay(x)), r, false);
  t.same("structure tree", r.bm.structure.tree, r.ref.structure.tree);
});

probe("upstream.a_header_rowspan_stays_in_its_row_group", "a header cell's rowspan ends with its group, so the header still repeats", async (t) => {
  const spanned = await render(t, table(`<thead><tr><th rowspan="2">Name</th><th>Qty</th></tr></thead>`), P400, FONTS, "rowspan");
  const plain = await render(t, table(), P400, FONTS, "plain");
  if (!spanned || !plain) return;
  pagesAndText(t, spanned, "rowspan: ");
  t.ok(shows(spanned.bm) === shows(plain.bm), `same text shows with and without the rowspan (bm ${shows(spanned.bm)} vs ${shows(plain.bm)})`);
});

probe("upstream.a_top_caption_does_not_repeat_with_the_header", "a top caption does not repeat with the header", async (t) => {
  const cap = await render(t, table(undefined, "<caption>Inventory</caption>"), P400, FONTS, "caption");
  const plain = await render(t, table(), P400, FONTS, "plain");
  if (!cap || !plain) return;
  pagesAndText(t, cap, "caption: ");
  t.ok(shows(cap.bm) === shows(plain.bm) + 1, `the caption paints once (bm ${shows(cap.bm)} vs ${shows(plain.bm)} + 1)`);
});

probe("upstream.a_repeated_table_header_replays_as_an_artifact", "a replayed header is an artifact; the table is one Table element", async (t) => {
  const r = await render(t, table(), { ...page(400, 300, 24), tagged: true });
  if (!r) return;
  check(t, "artifact marked content", (x) => /\/Artifact/.test(hay(x)), r, true);
  check(t, "Table elements", (x) => structElems(x, "Table"), r, 1);
  t.same("structure tree", r.bm.structure.tree, r.ref.structure.tree);
});

probe("upstream.an_image_in_a_repeated_table_header_is_tagged_once", "an image in a repeated header is tagged on the first page only", async (t) => {
  const html = `<table style="width: 100%; font-size: 12px; color: #141414">
      <thead><tr><th>Name <img src="pixel" alt="logo" style="width: 8px; height: 8px" /></th><th>Qty</th></tr></thead>
      <tbody>${rows30}</tbody>
    </table>`;
  const png = pngRgba(4, 4, () => [128, 128, 128, 128]);
  const r = await render(t, html, { ...page(400, 300, 24), tagged: true, images: [{ src: "pixel", data: png }] });
  if (!r) return;
  // An image drawn inside BDC ... EMC is tagged content, inside BMC ... EMC an artifact.
  const tagged = (x) => contents(x).reduce((n, c) => {
    const stack = [];
    for (const m of c.matchAll(/\b(BDC|BMC|EMC|Do)\b/g)) {
      if (m[1] === "BDC" || m[1] === "BMC") stack.push(m[1]); else if (m[1] === "EMC") stack.pop();
      else if (stack.includes("BDC") && !stack.includes("BMC")) n++;
    }
    return n;
  }, 0);
  t.ok(r.bm.pages.length > 1, "the table paginates");
  check(t, "tagged images", tagged, r, 1);
});

// ---- breaks -------------------------------------------------------------------------------------------------------

probe("upstream.a_long_paragraph_starts_on_the_first_page", "a long paragraph starts on the first page; no page is blank", async (t) => {
  const r = await render(t, `<p>${"Lorem ipsum dolor sit amet. ".repeat(200)}</p>`, page(400, 300, 20));
  if (!r) return;
  pagesAndText(t, r);
  t.ok(r.bm.pages.length > 1 && showsPerPage(r.bm).every((n) => n > 0), `every page shows text (bm ${showsPerPage(r.bm)})`);
});

probe("upstream.break_after_a_padded_box_cuts_once", "break-after on a padded box cuts once", async (t) => {
  const r = await render(t, `<div style="display: flex; flex-direction: column;">
    <div style="display: flex; padding-bottom: 64px; break-after: page;">One</div>
    <div style="display: flex;">Two</div>
  </div>`, A4);
  if (r) { check(t, "page count", (x) => x.pages.length, r, 2); pagesAndText(t, r); }
});

probe("upstream.a_forced_break_on_a_node_that_opens_a_page_adds_no_empty_page", "a forced break at the top of a page adds no empty page", async (t) => {
  const doc = (spacer, list, first, second) => `<div style="display: flex; flex-direction: column;">
        <div style="height: ${spacer}px; width: 100px;"><span style="font-size: 10px;">A</span></div>
        <div style="display: flex; flex-direction: column; ${list}">
          <div style="display: flex; flex-direction: column; break-inside: avoid; ${first}"><span style="font-size: 10px; line-height: 1.4;">B1</span></div>
          <div style="display: flex; flex-direction: column; break-inside: avoid; ${second}"><span style="font-size: 10px; line-height: 1.4;">B2</span></div>
        </div>
      </div>`;
  for (const [label, args, pages] of [
    ["plain", [235, "gap: 16px;", "", ""], 2],
    ["gap + break-before", [235, "gap: 16px;", "", "break-before: page;"], 2],
    ["margin + break-before", [235, "", "", "margin-top: 16px; break-before: page;"], 2],
    ["padding + break-before first", [245, "padding-top: 16px;", "break-before: page;", ""], 3],
  ]) {
    const r = await render(t, doc(...args), page(400, 300, 20), FONTS, label);
    if (r) { check(t, `${label}: page count`, (x) => x.pages.length, r, pages); pagesAndText(t, r, `${label}: `); }
  }
});

probe("upstream.forced_breaks_beside_spacing_break_as_blink_separates_them", "forced breaks beside margins and padding break as Blink separates them", async (t) => {
  for (const [label, html, pages] of [
    ["leading", `<div style="display: flex; flex-direction: column;">
      <div style="display: flex; margin-top: 16px; break-before: page;">One</div>
    </div>`, 2],
    ["trailing", `<div style="display: flex; flex-direction: column; padding-bottom: 16px;">
      <div style="display: flex; break-after: page;">One</div>
    </div>`, 1],
    ["doubled", `<div style="display: flex; flex-direction: column;">
      <div style="display: flex; break-after: page;">One</div>
      <div style="display: flex; margin-top: 16px; break-before: page;">Two</div>
    </div>`, 2],
  ]) {
    const r = await render(t, html, A4, FONTS, label);
    if (r) check(t, `${label}: page count`, (x) => x.pages.length, r, pages);
  }
});

probe("upstream.trailing_padding_past_the_page_end_goes_to_the_next_page", "trailing padding past the page end goes to the next page", async (t) => {
  const r = await render(t, `<div style="display: flex; flex-direction: column; padding-bottom: 40px;">
            <div style="height: 240px;"><span style="font-size: 10px;">A</span></div>
          </div>`, page(400, 300, 20));
  if (r) check(t, "page count", (x) => x.pages.length, r, 2);
});

probe("upstream.inline_box_pagination", "an inline-block line is not repeated across pages", async (t) => {
  const doc = `<p style="font-size:16px;line-height:20px;margin:0;">one<br><span style="display:inline-block">boxed</span><br>three<br>four<br>five<br>six<br>seven<br>eight</p>`;
  const opts = { ...page(240, 75, 0), tagged: false };
  const boxed = await render(t, doc, opts, FONTS, "boxed");
  const plain = await render(t, doc.replace(`<span style="display:inline-block">boxed</span>`, "boxed"), opts, FONTS, "plain");
  if (!boxed || !plain) return;
  pagesAndText(t, boxed, "boxed: ");
  t.ok(shows(boxed.bm) === shows(plain.bm), `same text shows (bm ${shows(boxed.bm)} vs ${shows(plain.bm)})`);
});

probe("upstream.an_overflowing_inline_block_emits_its_text_once", "an inline-block taller than the page emits its text once", async (t) => {
  const src = `<div style="font-size: 16px; line-height: 24px">
    <div>Before</div>
    <div><span style="display: inline-block; width: 200px; height: 360px">First inside<br>Second inside<br>Third inside</span> after</div>
  </div>`;
  const short = await render(t, src, page(400, 300, 24), FONTS, "300px pages");
  const tall = await render(t, src, page(400, 1000, 24), FONTS, "1000px pages");
  if (!short || !tall) return;
  pagesAndText(t, short);
  t.ok(shows(tall.bm) > 0 && shows(short.bm) === shows(tall.bm), `text shows on short pages equal tall pages (bm ${shows(short.bm)} vs ${shows(tall.bm)})`);
});

probe("upstream.a_glyph_taller_than_a_page_runs_on_as_outlines", "a glyph taller than a page shows text once and continues as outlines", async (t) => {
  const r = await render(t, `<div style="font-size: 400px; line-height: 1">g</div>`, page(400, 300, 24));
  if (!r) return;
  check(t, "page count", (x) => x.pages.length, r, 2);
  check(t, "text shows", shows, r, 1);
  t.ok(curves(r.bm) > 0, "the continuation draws outlines");
});

probe("upstream.a_fractional_column_paints_the_lines_layout_reserved", "a fractional-width column paints the lines layout reserved", async (t) => {
  const src = `<div style="display: flex; flex-direction: column; width: 217.25px;"><span style="font-size: 11px; line-height: 1.5;">Ihre Begleitung für diesen Tag ist Zahraa, die Ihnen ihre Heimatstadt aus ihrer ganz persönlichen Perspektive zeigen wird. Freuen Sie sich auf ein authentisches Oman-Erlebnis jenseits der typischen Reiseführer.</span></div>`;
  const m = await t.both(src, { viewport: { width: 800 } }, { fonts: FONTS, method: "measure" });
  if (m.ref && !m.bm.error && !m.ref.error) t.same("measured height", Math.round(m.bm.value.height * 100) / 100, Math.round(m.ref.value.height * 100) / 100);
  const r = await render(t, src, A4);
  if (!r || m.bm.error) return;
  const reserved = Math.round(m.bm.value.height / 16.5);
  const baselines = (x) => new Set(wordBoxes(x.bytes).flat().map((w) => Math.round(w[4] * 10))).size;
  check(t, "painted lines", baselines, r, reserved);
  pagesAndText(t, r);
});

// ---- counters -----------------------------------------------------------------------------------------------------

const tocDocument = (cells) => {
  const entry = (id, title, cell) => `<a href="#${id}" style="display: flex; column-gap: 4px;"><span>${title}</span>${cell}</a>`;
  const section = (id, title) => `<div id="${id}" style="display: flex; flex-direction: column; break-before: page; font-size: 18px;">${title}</div>`;
  return `<div style="display: flex; flex-direction: column; width: 100%; font-size: 14px; color: #141414;">
      <div style="display: flex; flex-direction: column;">${entry("alpha", "Alpha", cells[0])}${entry("beta", "Beta", cells[1])}${entry("gamma", "Gamma", cells[2])}</div>
      ${section("alpha", "Alpha")}${section("beta", "Beta")}${section("gamma", "Gamma")}
    </div>`;
};
const wrappingToc = (cells) => {
  const entries = cells.map((cell, i) => `<a href="#s${i + 1}" style="display: flex; flex-wrap: wrap; width: 100%;"><span style="width: 268px;">Section ${i + 1}</span>${cell}</a>`).join("");
  const sections = cells.map((_, i) => `<div id="s${i + 1}" style="display: flex; break-before: page; font-size: 18px;">Section ${i + 1}</div>`).join("");
  return `<div style="display: flex; flex-direction: column; width: 100%; font-size: 14px; color: #141414;">${entries}${sections}</div>`;
};
const TOC = page(320, 240, 24);
/** A hooked document must draw like the same document numbered by hand, on both engines. */
async function sameAsNumbered(t, hooked, numbered, options, fonts = FONTS) {
  const a = await render(t, hooked, options, fonts, "hooked");
  const b = await render(t, numbered, options, fonts, "numbered");
  if (!a || !b) return null;
  sameContent(t, "bm: hooked draws like numbered", a.bm, b.bm);
  sameContent(t, "takumi: hooked draws like numbered", a.ref, b.ref);
  pagesAndText(t, a);
  return a;
}

probe("upstream.target_counters_settle_after_they_move_their_own_page", "target counters settle after rewrapping moves their own targets", async (t) => {
  await sameAsNumbered(t, wrappingToc(Array(8).fill(`<span class="targetPageNumber"></span>`)), wrappingToc([3, 4, 5, 6, 7, 8, 9, 10].map((n) => `<span>${n}</span>`)), TOC);
});

probe("upstream.an_inline_page_counter_follows_the_flow_that_precedes_it", "an inline page counter names the page its line sits on, even under a transformed block", async (t) => {
  const doc = (p, tf = "") => `<main>
        <div style="height: 1100px;${tf}"></div>
        <span style="font-size: 12px;">${p}</span>
      </main>`;
  await sameAsNumbered(t, doc(`<span class="pageNumber"></span>`), doc("2"), A4);
  await sameAsNumbered(t, doc(`<span class="pageNumber"></span>`, " transform: translateY(-1100px);"), doc("2", " transform: translateY(-1100px);"), A4);
});

probe("upstream.a_repeated_table_header_does_not_move_the_counters_after_it", "a repeated table header does not move the counters after it", async (t) => {
  const doc = (p) => `<table style="width: 100%; font-size: 12px; color: #141414">
        <thead><tr><th>Name</th></tr></thead>
        <tbody><tr><td>Page <span>${p}</span></td></tr>${Array.from({ length: 59 }, (_, i) => `<tr><td>Item ${i + 2}</td></tr>`).join("")}</tbody>
      </table>`;
  const r = await sameAsNumbered(t, doc(`<span class="pageNumber"></span>`), doc("1"), A4);
  if (r) t.ok(r.bm.pages.length > 1, "the table paginates");
});

probe("upstream.a_page_counter_renumbers_the_target_it_moves", "a page counter that moves a target renumbers the target counter", async (t) => {
  const doc = (p, target) => `<div style="display: flex; flex-direction: column; width: 100%; font-size: 14px; color: #141414;">
        <a href="#target" style="display: flex; column-gap: 4px;">see${target}</a>
        <div style="display: flex; flex-wrap: wrap; width: 100%;"><span style="width: 268px;">Body</span>${p}</div>
        <div style="height: 136px;"></div>
        <div id="target" style="display: flex;">Target</div>
      </div>`;
  await sameAsNumbered(t, doc(`<span class="pageNumber"></span>`, `<span class="targetPageNumber"></span>`), doc("<span>1</span>", "<span>2</span>"), TOC);
});

probe("upstream.target_counter_in_a_band_drops_its_placeholder", "a target counter in a band renders empty, without its placeholder", async (t) => {
  const band = (cell) => `<div style="display: flex; column-gap: 3px; font-size: 12px; color: #141414;">Page <span class="pageNumber"></span>, section ${cell}</div>`;
  const body = tocDocument(["", "", ""]);
  const a = await render(t, body, { ...TOC, footer: band(`<a href="#alpha"><span class="targetPageNumber">99</span></a>`) }, FONTS, "hooked band");
  const b = await render(t, body, { ...TOC, footer: band(`<a href="#alpha"><span></span></a>`) }, FONTS, "empty band");
  if (a && b) { sameContent(t, "bm: hooked band draws like an empty one", a.bm, b.bm); sameContent(t, "takumi: hooked band draws like an empty one", a.ref, b.ref); }
});

probe("upstream.target_counter_without_a_target_renders_empty", "a target counter naming no element renders empty", async (t) => {
  const dangling = (cells) => tocDocument(cells).replace("#alpha", "#missing").replace("#beta", "#missing-too");
  await sameAsNumbered(t, dangling(Array(3).fill(`<span class="targetPageNumber"></span>`)), dangling(["<span></span>", "<span></span>", "<span>4</span>"]), TOC);
});

probe("upstream.counter_style_needs_a_covering_font", "a counter style no font covers stops the render; a covering font renders it", async (t) => {
  const doc = `<div style="display:flex;flex-direction:column;width:100%">${Array.from({ length: 60 }, (_, i) => `<div style="font-size:16px">Row ${i + 1}</div>`).join("")}</div>`;
  const footer = `<div style="display:flex;font-size:12px"><span class="totalPages trad-chinese-informal"></span></div>`;
  const opts = { ...page(400, 300, 24), footer };
  const latin = await t.both(doc, opts, { fonts: LATIN });
  t.ok(!!latin.bm.error, "latin only: bm rejects");
  sameError(t, "latin only", latin.bm, latin.ref);
  const covered = await render(t, doc, opts, FONTS, "with a CJK face");
  if (covered) pagesAndText(t, covered);
});

// ---- paint --------------------------------------------------------------------------------------------------------

probe("upstream.svg_embedded_jpeg_passes_through", "a JPEG inside an SVG image passes through as DCTDecode", async (t) => {
  const jpeg = readFileSync(path.join(takumiSrc, "assets", "images", "luma-cover-0dfbf65d-0f58-4941-947c-d84a5b131dc0.jpeg"));
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 24" width="48" height="24">
  <image x="0" y="0" width="48" height="24" href="${dataUrl("image/jpeg", jpeg)}"/>
</svg>`;
  const r = await render(t, `<div style="display:flex"><img src="${dataUrl("image/svg+xml", Buffer.from(svg))}" style="width:96px;height:48px"></div>`, { viewport: { width: 120, height: 60 } });
  if (r) check(t, "DCTDecode", (x) => /DCTDecode/.test(hay(x)), r, true);
});

probe("upstream.svg_color_filter_leaves_masks_alone", "a CSS color filter on an SVG image leaves its masks alone", async (t) => {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
  <defs><mask id="m"><rect width="24" height="24" fill="#ffffff"/></mask></defs>
  <rect width="24" height="24" fill="#e11d48" mask="url(#m)"/>
</svg>`;
  const r = await render(t, `<img src="${dataUrl("image/svg+xml", Buffer.from(svg))}" style="width: 48px; height: 48px; filter: invert(1);">`, { viewport: { width: 64, height: 64 } });
  if (r) check(t, "a white mask fill", (x) => /(?:^|\s)1 1 1 rg\b/.test(hay(x)), r, true);
});

/** The first axial / radial shading pattern: its Coords and pattern Matrix. */
function shading(r) {
  for (const o of r.pdf.objs.values()) {
    const d = o.dict;
    if (!d || d.PatternType !== 2) continue;
    const sh = r.pdf.resolve(d.Shading);
    return { coords: (sh && r.pdf.resolve(sh.Coords)) || null, matrix: r.pdf.resolve(d.Matrix) || [1, 0, 0, 1, 0, 0] };
  }
  return null;
}
const r2 = (v) => Math.round(v * 100) / 100;

probe("upstream.a_gradient_axis_is_measured_in_page_units", "a linear gradient's axis is 225 pt for a 300 px box", async (t) => {
  const r = await render(t, `<div style="width: 300px; height: 120px; background-image: linear-gradient(to right, #ff5f6d, #3a1c71);"></div>`, { viewport: { width: 300, height: 120 } });
  if (!r) return;
  const axis = (x) => { const s = shading(x); if (!s?.coords) return null; const [x1, y1, x2, y2] = s.coords; const [a, b, c, d] = s.matrix; const dx = x2 - x1, dy = y2 - y1; return r2(Math.hypot(a * dx + c * dy, b * dx + d * dy)); };
  const v = axis(r.bm);
  t.ok(v != null && Math.abs(v - 225) < 0.5, `bm axis ${v} pt (225)`);
  t.same("axis", v, axis(r.ref));
});

probe("upstream.a_radial_gradient_is_centred_in_page_units", "a radial gradient is centred at (45, 45) pt and reaches the farthest corner", async (t) => {
  const r = await render(t, `<div style="width: 120px; height: 120px; background-image: radial-gradient(circle, #fddb92, #4481eb);"></div>`, { viewport: { width: 120, height: 120 } });
  if (!r) return;
  const geo = (x) => { const s = shading(x); if (!s?.coords || s.coords.length < 6) return null; const [, , , cx, cy, rad] = s.coords; const [a, b, c, d, e, f] = s.matrix; return [r2(a * cx + c * cy + e), r2(b * cx + d * cy + f), r2(rad * Math.hypot(a, b))]; };
  const v = geo(r.bm);
  t.ok(v && Math.abs(v[0] - 45) < 0.5 && Math.abs(v[1] - 45) < 0.5 && Math.abs(v[2] - 45 * Math.SQRT2) < 0.5, `bm centre and reach ${v}`);
  t.same("centre and reach", v, geo(r.ref));
});

probe("upstream.a_conic_gradient_is_placed_in_page_units", "a conic gradient's pattern scales by 0.75 pt per px", async (t) => {
  const r = await render(t, `<div style="width: 120px; height: 120px; background-image: conic-gradient(from 0deg, red, lime, blue, red);"></div>`, { viewport: { width: 120, height: 120 } });
  if (!r) return;
  const scale = (x) => { for (const o of x.pdf.objs.values()) if (o.dict && o.dict.PatternType !== undefined && Array.isArray(x.pdf.resolve(o.dict.Matrix))) { const [a, b] = x.pdf.resolve(o.dict.Matrix); return r2(Math.hypot(a, b)); } return null; };
  check(t, "pattern scale", scale, r, 0.75);
});

probe("upstream.a_rounded_image_is_clipped_to_its_corner_curve", "a rounded image is clipped to its corner curves only", async (t) => {
  const png = pngRgba(8, 8, () => [64, 64, 64, 64]);
  const doc = (radius) => `<div style="display:flex;padding:20px;background-color:#ffffff;"><img src="photo" style="width:200px;height:200px;border-radius:${radius};" /></div>`;
  const rounded = await render(t, doc("60px"), { ...A4, images: [{ src: "photo", data: png }] }, FONTS, "rounded");
  const square = await render(t, doc("0"), { ...A4, images: [{ src: "photo", data: png }] }, FONTS, "square");
  if (!rounded || !square) return;
  check(t, "an image is drawn", (x) => /\bDo\b/.test(contents(x).join("\n")), rounded, true);
  check(t, "square: curves", curves, square, 0);
  t.same("rounded: curves", curves(rounded.bm), curves(rounded.ref));
  t.ok(curves(rounded.bm) > 0, `rounded: bm clips to curves (${curves(rounded.bm)})`);
});

probe("upstream.scaled_overflow_clip_keeps_what_it_shows", "a scaled overflow clip keeps the fill it shows", async (t) => {
  const r = await render(t, `<div style="display: block; width: 100px; height: 40px; overflow: hidden; transform: scale(2); transform-origin: 0 0"><div style="display: block; height: 30px"></div><div style="display: block; height: 10px; background-color: #123456"></div></div>`, page(300, 200, 10));
  if (r) check(t, "the shown fill", (x) => /0\.0706 0\.2039 0\.3373 rg/.test(hay(x)), r, true);
});

probe("upstream.paged_inline_span_background_paints_once", "an inline span background in a paragraph over pages paints once", async (t) => {
  const words = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod ".repeat(30);
  const r = await render(t, `<p style="margin: 0; font-size: 16px; color: #141414">${words}<span style="background-color: #fee2e2; padding: 2px 8px; border-radius: 9999px">soon</span> ${words}</p>`, page(400, 300, 24));
  if (!r) return;
  t.ok(r.bm.pages.length > 1, "the document paginates");
  check(t, "badge fills", (x) => count(contents(x).join("\n"), /0\.9961 0\.8863 0\.8863 rg/g), r, 1);
  pagesAndText(t, r);
});

probe("upstream.a_clipped_away_line_reaches_no_page", "text an overflow clip cuts away embeds no font", async (t) => {
  const r = await render(t, `<div style="width:700px">
    <div style="overflow:hidden;height:40px;background:#eee">
      <div style="height:2600px">
        <div style="margin-top:1500px;font-size:24px">裁掉的秘密</div>
      </div>
    </div>
    <div style="font-size:24px;height:2200px">visible after box</div>
  </div>`, A4);
  if (!r) return;
  const fonts = (x) => { const s = hay(x); return { archivo: count(s, /\/BaseFont\s*\/[A-Z]{6}\+Archivo/g) > 0, noto: count(s, /\/BaseFont\s*\/[A-Z]{6}\+NotoSansTC/g) }; };
  check(t, "embedded subsets", fonts, r, { archivo: true, noto: 0 });
});

// ---- tagging ------------------------------------------------------------------------------------------------------

probe("upstream.a_link_target_without_meaning_still_gets_an_element", "a link target without semantics still gets a structure element", async (t) => {
  for (const target of [`<div id="target">plain target div</div>`, `<div id="target"></div>`]) {
    const doc = `<div style="width:700px;font-size:20px">
        <p><a href="#target">jump to target</a></p>
        <h1>heading for the outline</h1>
        ${target}
      </div>`;
    const r = await render(t, doc, { ...A4, tagged: "ua2", pdfa: "4", lang: "en", metadata: META("Anchors", 8, 7) }, FONTS, target);
    if (!r) continue;
    t.same(`${target}: structure tree`, r.bm.structure.tree, r.ref.structure.tree);
    t.same(`${target}: parent and id trees`, [r.bm.structure.parents, r.bm.structure.roots], [r.ref.structure.parents, r.ref.structure.roots]);
  }
});

probe("upstream.a_programmatic_list_item_reads_its_marker_first", "a display:list-item reads its marker before its content", async (t) => {
  const r = await render(t, `<div style="display:list-item;list-style-type:decimal;font-size:16px;">item text</div>`, { ...page(240, 120, 0), tagged: true });
  if (!r) return;
  t.same("structure tree", r.bm.structure.tree, r.ref.structure.tree);
  pagesAndText(t, r);
});

probe("upstream.a_link_on_a_table_row_or_row_group_joins_the_structure_tree", "a link on thead / tbody / tfoot / tr joins the structure tree", async (t) => {
  for (const tag of ["thead", "tbody", "tfoot", "tr"]) {
    const link = (name) => (name === tag ? ` href="https://example.com"` : "");
    const doc = `<div style="font-size:14px"><h1>Rows</h1><table>
        <thead${link("thead")}><tr><th>Head</th></tr></thead>
        <tbody${link("tbody")}><tr${link("tr")} style="background:#eee"><td>a</td></tr></tbody>
        <tfoot${link("tfoot")}><tr><td>Foot</td></tr></tfoot>
      </table></div>`;
    for (const [label, std] of [["tagged", { tagged: true }], ["ua2 + pdfa 4", { tagged: "ua2", pdfa: "4" }]]) {
      const r = await render(t, doc, { ...A4, ...std, lang: "en", metadata: META("Rows", 11, 2) }, FONTS, `<${tag}> ${label}`);
      if (!r) continue;
      check(t, `<${tag}> ${label}: Link element and annotation`, (x) => [structElems(x, "Link") > 0, /https:\/\/example\.com/.test(hay(x))], r, [true, true]);
      t.same(`<${tag}> ${label}: structure tree`, r.bm.structure.tree, r.ref.structure.tree);
    }
  }
});

probe("upstream.tagged_ua2_needs_lang", "PDF/UA-2 without a document language is rejected", async (t) => {
  const r = await t.both("<main><h1>No language</h1></main>", { ...A4, pdfa: "4", tagged: "ua2", metadata: META("No language", 8, 8) }, { fonts: FONTS });
  t.ok(!!r.bm.error, "bm rejects");
  sameError(t, "no lang", r.bm, r.ref);
});

// ---- fonts and text -----------------------------------------------------------------------------------------------

probe("upstream.an_uncovered_mark_survives_in_the_text_layer", "an uncovered combining mark under uncoveredText blank stays in ToUnicode", async (t) => {
  const blank = await render(t, text("é"), { viewport: { width: 200, height: 100 }, uncoveredText: "blank" }, LATIN, "blank");
  const bare = await render(t, text("e"), { viewport: { width: 200, height: 100 } }, LATIN, "bare");
  if (blank) check(t, "blank: U+0301 in the text layer", (x) => /0301/i.test(hay(x)), blank, true);
  if (bare) check(t, "bare: no U+0301", (x) => /<0301>/i.test(hay(x)), bare, false);
});

probe("upstream.cid_default_width_is_an_integer", "/DW is an integer and /W keeps the glyphs it displaced", async (t) => {
  const doc = `<main style="display:flex;flex-direction:column;font-size:16px;color:#141414;">
      <p lang="ar">نص عربي عادي بحروف متكررة</p>
    </main>`;
  const r = await render(t, doc, { ...A4, lang: "ar" }, [ARABIC]);
  if (!r) return;
  const dws = (x) => [...x.pdf.objs.values()].filter((o) => o.dict && o.dict.DW !== undefined).map((o) => o.dict.DW);
  t.ok(dws(r.bm).length > 0 && dws(r.bm).every(Number.isInteger), `bm /DW ${dws(r.bm)} are integers`);
  t.same("/DW", dws(r.bm), dws(r.ref));
  pagesAndText(t, r);
});

probe("upstream.a_ranged_subset_keeps_a_latin_run_whole", "a unicodeRange subset whose cmap reaches past its range keeps a Latin run in one text object", async (t) => {
  const fonts = [
    { name: "Grouped", weight: 400, unicodeRange: [[0x4e00, 0x9fff]], data: font(TC_CAPS) },
    { name: "Grouped", weight: 400, unicodeRange: [[0x0000, 0x00ff]], data: font(ARCHIVO) },
  ];
  const r = await render(t, `<main style="font-family:Grouped;font-size:16px;">
    <p>Average App Rating</p>
  </main>`, A4, fonts);
  if (!r) return;
  check(t, "text objects", shows, r, 1);
  pagesAndText(t, r);
});

probe("upstream.a_clustered_glyph_maps_to_its_own_character", "a decomposed cluster maps each glyph to its own character", async (t) => {
  const r = await render(t, "<p>Świnoujście Sopot</p>", { viewport: { width: 240, height: 48 } }, [COMBINING]);
  if (!r) return;
  check(t, "ToUnicode targets", (x) => ["0053", "0301", "015A", "015B"].map((c) => new RegExp(`> *<${c}>`, "i").test(hay(x))), r, [true, true, false, false]);
  pagesAndText(t, r);
});

probe("upstream.a_glyph_without_a_codepoint_maps_to_the_rest_of_its_cluster", "a reordered matra maps to its own character", async (t) => {
  const r = await render(t, `<p lang="hi">तिरछा</p>`, { viewport: { width: 240, height: 48 } }, [DEVANAGARI]);
  if (!r) return;
  check(t, "matra mapping", (x) => [/> *<093F>/i.test(hay(x)), /> *<0924093F>/i.test(hay(x))], r, [true, false]);
});

probe("upstream.persian_zero_width_non_joiners_keep_their_own_glyph", "U+200C keeps its own ToUnicode entry", async (t) => {
  const r = await render(t, `<p dir="rtl" lang="fa" style="font-size:24px">سه‌ماهه می‌دهد لپ‌تاپ‌ها</p>`, A4, [ARABIC]);
  if (!r) return;
  const zwnj = (x) => {
    const out = [];
    for (const line of hay(x).split(/\n/)) if (/200C/i.test(line) && /beginbfchar|^\s*<[0-9A-Fa-f]+>\s*<[0-9A-Fa-f]+>\s*$/.test(line) || /^\s*<[0-9A-Fa-f]+>\s*<[0-9A-Fa-f]*200C[0-9A-Fa-f]*>\s*$/i.test(line)) out.push(line.trim().split("<").pop().replace(">", "").toUpperCase());
    return out;
  };
  const m = zwnj(r.bm);
  t.ok(m.length > 0 && m.every((d) => d === "200C"), `bm maps U+200C alone: ${m}`);
  t.same("U+200C mappings", [...new Set(m)], [...new Set(zwnj(r.ref))]);
  pagesAndText(t, r);
});

probe("upstream.synthesized_italic_leans_right_about_the_baseline", "synthesized italic shears about the baseline", async (t) => {
  const r = await render(t, `<p style="margin:0">one <i>two</i> three</p><p style="margin:40px 0 0">one <i>two</i> three</p>`, A4, LATIN);
  if (!r) return;
  pagesAndText(t, r);
  // The shear: a `cm` (or text matrix) whose c entry is positive leans the glyph tops right.
  const shears = (x) => [...contents(x).join("\n").matchAll(/([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+) (?:cm|Tm)\b/g)].filter((m) => Number(m[3]) !== 0 && Number(m[2]) === 0).map((m) => Math.sign(Number(m[3]) / Number(m[4])));
  t.ok(shears(r.bm).length > 0, "bm shears the italic run");
  t.same("shear direction", [...new Set(shears(r.bm))], [...new Set(shears(r.ref))]);
});

probe("upstream.type3_more_than_256_glyphs", "more than 256 colour glyphs split over several Type3 fonts (krilla type3.rs)", async (t) => {
  const TWEMOJI = "assets/fonts/twemoji/TwemojiMozilla-colr.woff2";
  const cps = [...Array.from({ length: 80 }, (_, i) => 0x1f600 + i), ...Array.from({ length: 256 }, (_, i) => 0x1f300 + i)];
  const html = `<p style="font-family:'Twemoji Mozilla';font-size:12px;word-break:break-all">${cps.map((c) => String.fromCodePoint(c)).join("")}</p>`;
  const r = await render(t, html, { ...A4, uncoveredText: "blank" }, [ARCHIVO, TWEMOJI]);
  if (!r) return;
  const type3 = (x) => x.subtyped("Type3").map((o) => Object.keys(x.pdf.resolve(o.dict.CharProcs) || {}).length).sort((a, b) => a - b);
  const t3 = type3(r.bm);
  t.ok(t3.length > 1 && t3.every((n) => n <= 256), `bm Type3 fonts of at most 256 glyphs: ${t3}`);
  t.same("Type3 fonts and glyph counts", t3, type3(r.ref));
  pagesAndText(t, r);
});

// ---- errors -------------------------------------------------------------------------------------------------------

probe("upstream.an_unsupported_filter_stops_the_render", "filter: blur() stops the render with UnsupportedFilter", async (t) => {
  const r = await t.both(`<div style="filter: blur(4px); width: 40px; height: 40px; background: #000;"></div>`, { viewport: { width: 80, height: 80 } }, { fonts: FONTS });
  t.ok(!!r.bm.error, "bm rejects");
  sameError(t, "blur", r.bm, r.ref);
});

probe("upstream.an_undecodable_image_stops_the_render", "an image whose pixels do not inflate stops the render", async (t) => {
  const png = Buffer.from(pngRgba(8, 8, () => [255, 255, 255, 255]));
  const idat = png.indexOf("IDAT") + 4;
  png.fill(0, idat, png.length - 12);
  const r = await t.both(`<img src="broken" style="filter: grayscale(1); width: 32px; height: 32px;" />`, { viewport: { width: 48, height: 48 }, images: [{ src: "broken", data: new Uint8Array(png) }] }, { fonts: FONTS });
  t.ok(!!r.bm.error, `bm rejects${r.bm.error ? "" : " (rendered)"}`);
  // the decoder's own words after the prefix differ (bm's PNG decoder vs the image crate)
  const stable = (m) => (m ? String(m).replace(/^bm-render: /, "").replace(/(decoding the image data: ).*$/, "$1…") : "(renders)");
  if (r.ref) t.same("broken png: error", stable(r.bm.error), stable(r.ref.error));
});

probe("upstream.a_table_taller_than_one_grid_keeps_every_row", "a table of 10,051 rows keeps every row (measure and TR elements)", async (t) => {
  const ROWS = 10050;
  const doc = `<table style="table-layout:fixed;width:100px;border-spacing:0">
      <thead><tr><th style="height:4px;padding:0"></th></tr></thead>
      <tbody>${`<tr><td style="height:4px;padding:0"></td></tr>`.repeat(ROWS)}</tbody>
    </table>`;
  const m = await t.both(doc, { viewport: { width: 100, height: 100 } }, { fonts: FONTS, method: "measure" });
  t.ok(!m.bm.error && m.bm.value.height === (ROWS + 1) * 4, `bm measures ${m.bm.value?.height} (${(ROWS + 1) * 4})`);
  if (m.ref && !m.ref.error) t.same("measured height", m.bm.value?.height, m.ref.value.height);
  const r = await render(t, doc, { ...A4, tagged: true });
  if (r) check(t, "TR elements", (x) => structElems(x, "TR"), r, ROWS + 1);
});

probe("upstream.uncovered_character_stops_the_render", "a character no font covers stops the render and names it", async (t) => {
  const ok = await render(t, text("covered"), { viewport: { width: 200, height: 100 } }, LATIN, "covered");
  if (ok) pagesAndText(t, ok, "covered: ");
  const r = await t.both(text("uncovered 直"), { viewport: { width: 200, height: 100 } }, { fonts: LATIN });
  t.ok(!!r.bm.error && r.bm.error.includes("直 (U+76F4)"), `bm names the character: ${r.bm.error}`);
  sameError(t, "uncovered", r.bm, r.ref);
});

probe("upstream.uncovered_character_renders_under_an_uncovered_text_policy", "uncoveredText placeholder draws glyph 0, blank does not", async (t) => {
  const opts = (uncoveredText) => ({ viewport: { width: 200, height: 100 }, uncoveredText });
  const e = await t.both(text("uncovered 直"), opts("error"), { fonts: LATIN });
  t.ok(!!e.bm.error, "error: bm rejects");
  sameError(t, "error policy", e.bm, e.ref);
  // glyph 0 in a two-byte CID string: `\000\000` literal or `0000` hex
  const gid0 = (x) => contents(x).some((c) => /\\000\\000|<(?:[0-9A-Fa-f]{4})*0000(?:[0-9A-Fa-f]{4})*>/.test(c));
  const ph = await render(t, text("uncovered 直"), opts("placeholder"), LATIN, "placeholder");
  if (ph) check(t, "placeholder: glyph 0", gid0, ph, true);
  const bl = await render(t, text("uncovered 直"), opts("blank"), LATIN, "blank");
  if (bl) check(t, "blank: glyph 0", gid0, bl, false);
});

probe("upstream.a_forbidden_placeholder_names_the_standard", "a standard that forbids the placeholder glyph names itself in the error", async (t) => {
  const base = { viewport: { width: 200, height: 100 }, lang: "en", metadata: META("T", 1, 1) };
  for (const [label, opts, rejects] of [
    ["placeholder + pdfa 2b", { ...base, uncoveredText: "placeholder", pdfa: "2b", tagged: true }, true],
    ["placeholder + ua1", { ...base, uncoveredText: "placeholder", tagged: "ua1" }, true],
    ["blank + pdfa 2b", { ...base, uncoveredText: "blank", pdfa: "2b" }, false],
  ]) {
    const r = await t.both(text("uncovered 直"), opts, { fonts: LATIN });
    t.ok(!!r.bm.error === rejects, `${label}: bm ${r.bm.error ? "rejects: " + r.bm.error : "renders"}`);
    if (!sameError(t, label, r.bm, r.ref) && r.ref) t.same(`${label}: pages`, r.bm.pages.length, r.ref.pages.length);
  }
});

// ---- measure ------------------------------------------------------------------------------------------------------

/** measure() on both engines: the size each reports (or the same error). */
async function measured(t, label, source, options, expected) {
  const r = await t.both(source, options, { fonts: FONTS, method: "measure" });
  if (!r.ref) { t.ok(!r.bm.error, `${label}: bm measures`); t.same(label, 0, 0); return r.bm.value; }
  if (sameError(t, label, r.bm, r.ref)) return null;
  const round = (v) => ({ width: r2(v.width), height: r2(v.height) });
  t.same(`${label}: size`, round(r.bm.value), round(r.ref.value));
  if (expected) for (const [k, v] of Object.entries(expected)) t.ok(r.bm.value[k] === v, `${label}: bm ${k} ${r.bm.value[k]} (${v})`);
  return r.bm.value;
}

probe("upstream.measure_band_at_page_width", "measure() of a band with page options spans the page width", async (t) => {
  const v = await measured(t, "band", `<div style="display: flex; justify-content: center; font-size: 12px;">
      Page <span class="pageNumber"></span> of <span class="totalPages"></span>
    </div>`, A4, { width: Math.floor(793.7007874015749) });
  if (v) t.ok(v.height >= 12, `band height ${v.height} >= 12`);
});

probe("upstream.measure_reports_content_width", "measure() reports the content box, at a page and at a viewport", async (t) => {
  const src = `<div style="border: 1px solid #000; width: 100px; height: 100px;">A</div>`;
  await measured(t, "at page", src, A4, { width: 100, height: 100 });
  await measured(t, "at viewport", src, { viewport: { width: 600, height: 400 } }, { width: 100, height: 100 });
});

probe("upstream.measure_blockifies_the_root_node", "measure() blockifies an inline root", async (t) => {
  await measured(t, "inline root", `<span style="width:200px;height:100px;font-size:16px">Hello PDF</span>`, { viewport: { width: 600, height: 300 } }, { width: 200, height: 100 });
});

probe("upstream.measure_encloses_a_float_in_the_root_node", "measure() encloses a float in the root", async (t) => {
  await measured(t, "float", `<div><div style="float: left; width: 50px; height: 80px"></div></div>`, { viewport: { width: 600, height: 300 } }, { height: 80 });
});

probe("upstream.measure_viewport_and_missing_viewport", "measure() wraps at its viewport width", async (t) => {
  const src = `<div style="font-size: 16px;">A line of wrapped text that needs several rows at a narrow width</div>`;
  const narrow = await measured(t, "narrow", src, { viewport: { width: 120 } });
  const wide = await measured(t, "wide", src, { viewport: { width: 600 } });
  t.ok(narrow && wide && narrow.height > wide.height, "narrow is taller");
  // The Rust API errors without a viewport (MissingViewport); the JS API defaults to paged A4 instead
  // (takumi-pdf-js render.test.ts "measure defaults to paged A4"): compare the JS default.
  await measured(t, "no viewport (JS default)", src, {});
});

// ---- window scenes and page summaries (takumi-pdf tests/window_scenes.rs, src/pagination.rs) ---------------------
// takumi paints each page from the window of a layout that reached only the pages before it, and summarizes the
// anchors / headings page by page; both must equal the whole scene. bm-render has no window scenes (it draws parts
// of a document at page boundaries: scripts/pdf-chunks-check.mjs): what is compared here is the output, on the same
// fixtures and page sizes.

const fixture = (name) => readFileSync(path.join(takumiSrc, "takumi-pdf", "fixtures", name), "utf8");
const HTML_FIXTURES = ["certificate.html", "invoice-footer.html", "invoice.html", "report.html"];
const WINDOW_SIZES = [[523, 770], [400, 300], [300, 120], [250, 90]];
/** Fill operators per page: where boxes paint. */
const fillsPerPage = (x) => contents(x).map((c) => (c.match(/(?:^|\s)(?:f\*?|B\*?|b\*?)(?=\s|$)/g) || []).length);

probe("upstream.html_fixtures_paint_from_their_windows", "the HTML fixtures paint each page like the whole document, at four page sizes (window_scenes.rs)", async (t) => {
  for (const name of HTML_FIXTURES) for (const [w, h] of WINDOW_SIZES) {
    const r = await render(t, fixture(name), page(w, h, 0), FONTS, `${name} ${w}x${h}`);
    if (!r) continue;
    pagesAndText(t, r, `${name} ${w}x${h}: `);
    t.same(`${name} ${w}x${h}: paint fills per page`, fillsPerPage(r.bm), fillsPerPage(r.ref));
  }
});

probe("upstream.positioned_box_of_a_parent_on_every_page_paints_from_its_page", "a box positioned in a parent broken over every page paints on its own page (window_scenes.rs)", async (t) => {
  const r = await render(t, fixture("positioned-in-fragmented-parent.html"), page(400, 300, 0));
  if (!r) return;
  t.ok(r.bm.pages.length > 3, `more than three pages (bm ${r.bm.pages.length})`);
  pagesAndText(t, r);
  t.same("paint fills per page", fillsPerPage(r.bm), fillsPerPage(r.ref));
});

probe("upstream.page_summaries_add_up_to_the_summary_of_the_whole_scene", "anchors and headings per page: link destinations and outline over the fixtures at four page sizes (pagination.rs)", async (t) => {
  const dests = (x) => x.pages.map((p) => (x.pdf.resolve(p.dict.Annots) || []).map((a) => { const o = x.pdf.resolve(a); const d = x.pdf.resolve(o.Dest); return Array.isArray(d) ? x.pages.findIndex((q) => q.ref?.n === d[0]?.n) : o.A ? "uri" : "?"; }));
  const outline = (x) => count(hay(x), /\/Title\s*[(<]/g);
  for (const name of HTML_FIXTURES) for (const [w, h] of WINDOW_SIZES) {
    const r = await render(t, fixture(name), { ...page(w, h, 12), outline: true }, FONTS, `${name} ${w}x${h}`);
    if (!r) continue;
    t.same(`${name} ${w}x${h}: page count`, r.bm.pages.length, r.ref.pages.length);
    t.same(`${name} ${w}x${h}: link destinations per page`, dests(r.bm), dests(r.ref));
    t.same(`${name} ${w}x${h}: outline titles`, outline(r.bm), outline(r.ref));
  }
});
