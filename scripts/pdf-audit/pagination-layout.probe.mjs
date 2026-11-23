// Audit probes: block fragmentation, part 2: tables, flex, grid, multi-column, floats, absolutely / fixed
// positioned boxes, transforms and position:relative, overflow clipping, list markers. Method: see
// page-options.probe.mjs; page = 300 x 200 px, 10 px margins, nine 20 px lines per page.
import { probe } from "./lib.mjs";
import { outcome } from "./filelayer.util.mjs";
import { SMALL, cmp, cmpAll, doc, lines, pad, paintShapes, wordBoxes } from "./paged-helpers.mjs";

const G = { geom: true, expect: "render" };
const P = { ...SMALL, tagged: false };
const GP = { geom: true, paint: true, expect: "render" };

// ------------------------------------------------------------------------------------------------ tables

const TCSS = `table{border-spacing:0;width:100%} td,th{padding:0;height:20px;font:12px/20px Inter;text-align:left;font-weight:400}`;
const rows = (from, to, f = (i) => `<td>R${pad(i)}</td><td>v${i}</td>`) => { let s = ""; for (let i = from; i <= to; i++) s += `<tr>${f(i)}</tr>`; return s; };
const table = (inner, css = "", attrs = "") => doc(`<table ${attrs}>${inner}</table>`, TCSS + css);
probe("pagination.table.thead-repeat", "tables: a thead repeats at the top of every page", async (t) => {
  await cmpAll(t, [
    ["thead + 20 rows", table(`<thead><tr><th>HEAD</th><th>H2</th></tr></thead><tbody>${rows(1, 20)}</tbody>`), SMALL],
    ["thead after two lines of text", doc(lines(1, 2) + `<table><thead><tr><th>HEAD</th></tr></thead><tbody>${rows(1, 20, (i) => `<td>R${pad(i)}</td>`)}</tbody></table>` + lines(3, 4), TCSS), SMALL],
    ["two header rows", table(`<thead><tr><th>HA</th></tr><tr><th>HB</th></tr></thead><tbody>${rows(1, 20, (i) => `<td>R${pad(i)}</td>`)}</tbody>`), SMALL],
    ["thead written after tbody in the source", table(`<tbody>${rows(1, 20, (i) => `<td>R${pad(i)}</td>`)}</tbody><thead><tr><th>HEAD</th></tr></thead>`), SMALL],
    ["display:table-header-group on a div", doc(`<div style="display:table;width:100%"><div style="display:table-header-group"><div style="display:table-row"><div style="display:table-cell;height:20px">HEAD</div></div></div>` + Array.from({ length: 20 }, (_, i) => `<div style="display:table-row"><div style="display:table-cell;height:20px">R${pad(i + 1)}</div></div>`).join("") + `</div>`), SMALL],
    ["two theads: only the first is a header group", table(`<thead><tr><th>HEAD1</th></tr></thead><thead><tr><th>HEAD2</th></tr></thead><tbody>${rows(1, 20, (i) => `<td>R${pad(i)}</td>`)}</tbody>`), SMALL],
  ], G);
});
probe("pagination.table.thead-no-repeat", "tables: a thead does not repeat when it is tall or may break inside", async (t) => {
  const body = `<tbody>${rows(1, 20, (i) => `<td>R${pad(i)}</td>`)}</tbody>`;
  await cmpAll(t, [
    ["thead exactly a quarter of the page (45px) repeats", table(`<thead><tr><th style="height:45px">HEAD</th></tr></thead>` + body), SMALL],
    ["thead taller than a quarter of the page (46px)", table(`<thead><tr><th style="height:46px">HEAD</th></tr></thead>` + body), SMALL],
    ["thead with break-inside:auto", table(`<thead style="break-inside:auto"><tr><th>HEAD</th></tr></thead>` + body), SMALL],
    ["thead with page-break-inside:auto", table(`<thead style="page-break-inside:auto"><tr><th>HEAD</th></tr></thead>` + body), SMALL],
    ["tbody with break-inside:avoid is not a header", table(`<tbody style="break-inside:avoid">${rows(1, 3, (i) => `<td>A${pad(i)}</td>`)}</tbody>` + body), SMALL],
    ["table that fits one page", table(`<thead><tr><th>HEAD</th></tr></thead><tbody>${rows(1, 5, (i) => `<td>R${pad(i)}</td>`)}</tbody>`), SMALL],
  ], G);
});
probe("pagination.table.tfoot-repeat", "tables: a tfoot repeats at the bottom of every page", async (t) => {
  const body = `<tbody>${rows(1, 20, (i) => `<td>R${pad(i)}</td>`)}</tbody>`;
  await cmpAll(t, [
    ["tfoot + 20 rows", table(body + `<tfoot><tr><td>FOOT</td></tr></tfoot>`), SMALL],
    ["thead + tfoot", table(`<thead><tr><th>HEAD</th></tr></thead>` + body + `<tfoot><tr><td>FOOT</td></tr></tfoot>`), SMALL],
    ["tfoot written before tbody", table(`<tfoot><tr><td>FOOT</td></tr></tfoot>` + body), SMALL],
    ["tfoot taller than a quarter page does not repeat", table(body + `<tfoot><tr><td style="height:50px">FOOT</td></tr></tfoot>`), SMALL],
    ["tfoot with break-inside:auto", table(body + `<tfoot style="break-inside:auto"><tr><td>FOOT</td></tr></tfoot>`), SMALL],
    ["thead + tfoot together taller than... each 40px", table(`<thead><tr><th style="height:40px">HEAD</th></tr></thead>` + body + `<tfoot><tr><td style="height:40px">FOOT</td></tr></tfoot>`), SMALL],
    ["content after a table with a repeated footer", doc(`<table>` + body + `<tfoot><tr><td>FOOT</td></tr></tfoot></table>` + lines(1, 3), TCSS), SMALL],
  ], G);
});
probe("pagination.table.rows", "tables: rows break between pages; a row splits unless it avoids it", async (t) => {
  const tall = (style = "") => `<tr style="${style}"><td>` + Array.from({ length: 6 }, (_, i) => "T" + (i + 1)).join("<br>") + `</td><td>side</td></tr>`;
  await cmpAll(t, [
    ["plain rows across pages", table(rows(1, 20)), SMALL],
    ["a tall row splits between its lines", table(rows(1, 6) + tall() + rows(7, 8)), SMALL],
    ["a tall row with break-inside:avoid moves", table(rows(1, 6) + tall("break-inside:avoid") + rows(7, 8)), SMALL],
    ["break-inside:avoid on the cell", table(rows(1, 6) + `<tr><td style="break-inside:avoid">` + Array.from({ length: 6 }, (_, i) => "T" + (i + 1)).join("<br>") + `</td></tr>` + rows(7, 8)), SMALL],
    ["a row taller than a page", table(rows(1, 2) + `<tr><td>` + Array.from({ length: 14 }, (_, i) => "T" + (i + 1)).join("<br>") + `</td><td>side</td></tr>` + rows(3, 4)), SMALL],
    ["a row with a fixed-height cell (60px) at the page end", table(rows(1, 7) + `<tr><td style="height:60px">TALL</td><td>s</td></tr>` + rows(8, 9)), SMALL],
    ["break-before:page on a row", table(rows(1, 3) + `<tr style="break-before:page"><td>BRK</td><td>x</td></tr>` + rows(4, 5)), SMALL],
    ["break-after:page on a row", table(rows(1, 3) + `<tr style="break-after:page"><td>BRK</td><td>x</td></tr>` + rows(4, 5)), SMALL],
    ["break-before:page on a tbody", table(`<tbody>${rows(1, 3)}</tbody><tbody style="break-before:page">${rows(4, 6)}</tbody>`), SMALL],
    ["break-after:avoid on a row keeps it with the next", table(rows(1, 8) + `<tr style="break-after:avoid"><td>KEEP</td><td>x</td></tr>` + rows(9, 12)), SMALL],
    ["widows / orphans in a cell", table(rows(1, 8) + `<tr><td>` + Array.from({ length: 4 }, (_, i) => "T" + (i + 1)).join("<br>") + `</td></tr>`), SMALL],
    ["cells of different heights in the split row", table(rows(1, 6) + `<tr><td>A1<br>A2<br>A3<br>A4<br>A5<br>A6</td><td>B1<br>B2</td></tr>` + rows(7, 8)), SMALL],
    ["vertical-align:middle / bottom cells in a split row", table(rows(1, 6) + `<tr><td>A1<br>A2<br>A3<br>A4<br>A5<br>A6</td><td style="vertical-align:middle">MID</td><td style="vertical-align:bottom">BOT</td></tr>` + rows(7, 8)), SMALL],
  ], G);
  const parallel = await t.bm(
    table(rows(1, 3) + `<tr><td><div class="l">C1</div><div class="l" style="break-before:page">C2</div></td><td>side</td></tr>` + rows(4, 5)),
    SMALL,
  );
  t.ok(!parallel.error, "forced break inside a cell renders");
  if (!parallel.error) {
    const words = wordBoxes(parallel.bytes);
    const onPage = (word) => words.findIndex((page) => page.some((entry) => entry[0] === word));
    t.ok(onPage("C1") === 0 && onPage("side") === 0 && onPage("C2") === 1,
      "forced break fragments one cell while the parallel cell stays with the first fragment");
  }
  t.differs("bm follows independent table-cell fragmentation; pinned Takumi moves the parallel cell");
});
probe("pagination.table.rowspan", "tables: a cell that spans rows across a page break", async (t) => {
  await cmpAll(t, [
    ["rowspan=4 crossing the page end", table(rows(1, 7) + `<tr><td rowspan="4">SPAN</td><td>a1</td></tr><tr><td>a2</td></tr><tr><td>a3</td></tr><tr><td>a4</td></tr>` + rows(8, 9)), SMALL],
    ["rowspan with lines of text crossing the page end", table(rows(1, 7) + `<tr><td rowspan="4">S1<br>S2<br>S3<br>S4</td><td>a1</td></tr><tr><td>a2</td></tr><tr><td>a3</td></tr><tr><td>a4</td></tr>` + rows(8, 9)), SMALL],
    ["rowspan cell vertical-align:middle", table(rows(1, 7) + `<tr><td rowspan="4" style="vertical-align:middle">SPAN</td><td>a1</td></tr><tr><td>a2</td></tr><tr><td>a3</td></tr><tr><td>a4</td></tr>`), SMALL],
    ["rowspan over 12 rows (more than a page)", table(`<tr><td rowspan="12">S1<br>S2<br>S3<br>S4<br>S5<br>S6<br>S7<br>S8<br>S9<br>S10<br>S11<br>S12</td><td>a01</td></tr>` + Array.from({ length: 11 }, (_, i) => `<tr><td>a${pad(i + 2)}</td></tr>`).join("")), SMALL],
  ], G);
});
probe("pagination.table.caption", "tables: captions", async (t) => {
  await cmpAll(t, [
    ["top caption", table(`<caption style="font:12px/20px Inter;text-align:left">CAP</caption>` + rows(1, 20)), SMALL],
    ["bottom caption", table(`<caption style="font:12px/20px Inter;text-align:left;caption-side:bottom">CAP</caption>` + rows(1, 20)), SMALL],
    ["top caption + thead (the caption is not repeated)", table(`<caption style="font:12px/20px Inter;text-align:left">CAP</caption><thead><tr><th>HEAD</th></tr></thead><tbody>${rows(1, 20, (i) => `<td>R${pad(i)}</td>`)}</tbody>`), SMALL],
  ], G);
  const longCaption = await t.bm(
    doc(lines(1, 7) + `<table><caption style="font:12px/20px Inter;text-align:left">C1<br>C2<br>C3<br>C4</caption>${rows(1, 3)}</table>`, TCSS),
    SMALL,
  );
  t.ok(!longCaption.error, "caption crossing a page break renders");
  if (!longCaption.error) {
    const first = longCaption.textPages[0] || "";
    const second = longCaption.textPages[1] || "";
    t.ok(longCaption.textPages.length === 2 && first.includes("C1") && first.includes("C2") &&
      second.includes("C3") && second.includes("C4"), "all caption lines are preserved across pages");
  }
  t.differs("bm preserves the first caption fragment; pinned Takumi drops it");
});
probe("pagination.table.borders", "tables: collapsed / separate borders and spacing at the break", async (t) => {
  await cmpAll(t, [
    ["border-collapse:collapse, 1px borders", table(rows(1, 20), `table{border-collapse:collapse} td{border:1px solid #000}`), P],
    ["separate borders with border-spacing 6px", table(rows(1, 20), `table{border-spacing:6px;border:2px solid #000} td{border:1px solid #f00}`), P, { paint: false }], // (a frame path vs four edge rectangles: not comparable by shapes)
    ["table border + padding split by the page", table(rows(1, 20), `table{border:5px solid #000;border-collapse:separate}`), P, { paint: false }],
    ["row backgrounds across the break", table(rows(1, 20), `tr:nth-child(odd){background:#eee} tbody{background:#ffe}`), P],
    ["table box-decoration-break:clone", table(rows(1, 20), `table{border:5px solid #000;box-decoration-break:clone}`), P],
  ], GP);

  const hasBlackRule = (shapes, y, width_min) => shapes.some((shape) => {
    if (!shape.endsWith("fill 0,0,0")) return false;
    const [x0, y0, x1, y1] = shape.split(" ", 4).map(Number);
    return x1 - x0 >= width_min && y1 - y0 <= 2 && Math.abs(y0 - y) <= 1.5;
  });
  const fourPx = await t.bm(table(rows(1, 20), `table{border-collapse:collapse} td{border:4px solid #000}`), P);
  t.ok(!fourPx.error, "4px collapsed-border table renders");
  if (!fourPx.error) {
    const firstPage = paintShapes(fourPx, 0);
    // (the last row on page 1, R07, ends 13.5 pt above the page bottom; the content box ends at 7.5 pt)
    const isRule = (shape, y) => { const [x0, y0, x1, y1] = shape.split(" ", 4).map(Number); return shape.endsWith("fill 0,0,0") && x1 - x0 >= 100 && Math.abs(y0 - y) <= 1.5; };
    t.ok(firstPage.some((s) => isRule(s, 13.5)), "the row separator stays under the last row of the page");
    // Chromium: the next row's block-start edge belongs to its own page, not to a strip under this one
    t.ok(!firstPage.some((s) => isRule(s, 7.5)), "no second rule at the page end from the row moved to the next page");
  }
  // The same break between two row groups (R01-R07 | R08-R20): the group above paints the edge they share under R07,
  // the group below at R08's start on the next page (Chromium; his-print Mps000338, a thead shown as a row group
  // above its tbody, lost the rule at the top of the next page).
  const twoGroups = await t.bm(table(`<tbody>${rows(1, 7)}</tbody><tbody>${rows(8, 20)}</tbody>`, `table{border-collapse:collapse} td{border:4px solid #000}`), P);
  t.ok(!twoGroups.error, "4px collapsed-border table with two row groups renders");
  if (!twoGroups.error) {
    const isRule = (shape, y) => { const [x0, y0, x1, y1] = shape.split(" ", 4).map(Number); return shape.endsWith("fill 0,0,0") && x1 - x0 >= 100 && Math.abs(y0 - y) <= 1.5; };
    const firstPage = paintShapes(twoGroups, 0);
    const secondPage = paintShapes(twoGroups, 1);
    t.ok(twoGroups.textPages[1]?.startsWith("R08"), "row groups: R08 starts the next page");
    t.ok(firstPage.some((s) => isRule(s, 13.5)), "row groups: the shared edge stays under the last row of the page");
    t.ok(!firstPage.some((s) => isRule(s, 7.5)), "row groups: no second rule at the page end");
    t.ok(secondPage.some((s) => isRule(s, 141)), `row groups: R08 has its block-start edge at the top of the next page (${secondPage.filter((s) => s.endsWith("fill 0,0,0")).slice(0, 4).join(" | ")})`);
  }

  const repeated = await t.both(
    table(`<thead><tr><th>HEAD</th><th>H2</th></tr></thead><tbody>${rows(1, 20)}</tbody>`, `table{border-collapse:collapse} td,th{border:2px solid #000}`),
    P,
  );
  if (!t.same("collapsed borders + repeated thead outcome", outcome(repeated.bm), outcome(repeated.ref)) || repeated.bm.error) return;
  t.same("collapsed borders + repeated thead text", repeated.bm.textPages, repeated.ref.textPages);
  const secondPage = paintShapes(repeated.bm, 1);
  t.ok(hasBlackRule(secondPage, 10, 100), "repeated thead has a collapsed top border");
  t.ok(hasBlackRule(secondPage, 26.5, 100), "repeated thead has a collapsed bottom border");
  t.differs("repeated header border coordinates differ by under 1 CSS px from pinned Takumi");
});
probe("pagination.table.misc", "tables: nested tables, margins, anonymous table boxes", async (t) => {
  await cmpAll(t, [
    ["nested table in a cell", table(rows(1, 5) + `<tr><td><table>${rows(1, 8, (i) => `<td>N${pad(i)}</td>`)}</table></td><td>side</td></tr>` + rows(6, 7)), SMALL],
    ["nested table with a thead", table(rows(1, 5) + `<tr><td><table><thead><tr><th>NH</th></tr></thead>${rows(1, 8, (i) => `<td>N${pad(i)}</td>`)}</table></td></tr>`), SMALL],
    ["table with margin-top after a break", doc(lines(1, 9) + `<table style="margin-top:30px">${rows(1, 3)}</table>`, TCSS), SMALL],
    ["table with break-inside:avoid", doc(lines(1, 6) + `<table style="break-inside:avoid">${rows(1, 5)}</table>`, TCSS), SMALL],
    ["table with break-before:page", doc(lines(1, 3) + `<table style="break-before:page">${rows(1, 3)}</table>`, TCSS), SMALL],
    ["anonymous rows (display:table-cell children)", doc(lines(1, 7) + `<div style="display:table"><div style="display:table-cell">A1<br>A2<br>A3<br>A4</div><div style="display:table-cell">B1</div></div>`), SMALL],
    ["inline-table is monolithic", doc(lines(1, 7) + `<table style="display:inline-table">${rows(1, 4)}</table>`, TCSS), SMALL],
    ["thead only table across a break", doc(lines(1, 8) + `<table><thead><tr><th>H1</th></tr><tr><th>H2</th></tr></thead></table>`, TCSS), SMALL],
    ["60 rows with thead and tfoot", table(`<thead><tr><th>HEAD</th></tr></thead><tbody>${rows(1, 60, (i) => `<td>R${pad(i)}</td>`)}</tbody><tfoot><tr><td>FOOT</td></tr></tfoot>`), SMALL],
  ], G);
});

// ------------------------------------------------------------------------------------------------ flex

const fx = (style, inner) => `<div style="display:flex;${style}">${inner}</div>`;
const col = (from, to, style = "") => `<div style="${style}">` + lines(from, to) + `</div>`;
probe("pagination.flex.column", "flex column containers fragment between and inside items", async (t) => {
  await cmpAll(t, [
    ["items are lines", doc(fx("flex-direction:column", lines(1, 20))), SMALL],
    ["an item splits inside", doc(fx("flex-direction:column", lines(1, 5) + col(6, 12) + lines(13, 14))), SMALL],
    ["item with break-inside:avoid", doc(fx("flex-direction:column", lines(1, 6) + col(7, 11, "break-inside:avoid") + lines(12, 13))), SMALL],
    ["break-before:page on an item", doc(fx("flex-direction:column", lines(1, 3) + col(4, 5, "break-before:page") + lines(6, 7))), SMALL],
    ["break-after:page on an item", doc(fx("flex-direction:column", lines(1, 3) + col(4, 5, "break-after:page") + lines(6, 7))), SMALL],
    ["break-after on the last item breaks after the container", doc(fx("flex-direction:column", lines(1, 3) + col(4, 5, "break-after:page")) + lines(6, 7)), SMALL],
    ["break-before on the first item breaks before the container", doc(lines(1, 2) + fx("flex-direction:column", col(3, 4, "break-before:page") + lines(5, 6))), SMALL],
    ["forced break on a nested child of an item", doc(fx("flex-direction:column", lines(1, 3) + `<div><div class="l">A</div><div class="l" style="break-before:page">B</div></div>` + lines(4, 5))), SMALL],
    ["column-reverse", doc(fx("flex-direction:column-reverse", lines(1, 14))), SMALL],
    ["gap 10px", doc(fx("flex-direction:column;gap:10px", lines(1, 14))), SMALL],
    ["justify-content:space-between in a fixed-height column (400px)", doc(fx("flex-direction:column;justify-content:space-between;height:400px", lines(1, 6))), SMALL],
    ["flex-grow item in a fixed-height column", doc(fx("flex-direction:column;height:400px", lines(1, 2) + `<div style="flex:1">GROW</div>` + lines(3, 4))), SMALL],
    ["nested flex columns", doc(fx("flex-direction:column", lines(1, 4) + fx("flex-direction:column", lines(5, 14)) + lines(15, 16))), SMALL],
    ["monolithic item (image-like fixed 100px overflow hidden) moves", doc(fx("flex-direction:column", lines(1, 6) + `<div style="height:100px;overflow:hidden;flex:none">MONO</div>` + lines(7, 8))), SMALL],
    ["order property", doc(fx("flex-direction:column", `<div class="l" style="order:2">B</div><div class="l" style="order:1">A</div>` + lines(1, 10).replace(/class="l"/g, 'class="l" style="order:3"'))), SMALL],
  ], G);
});
probe("pagination.flex.row", "flex row containers: items are parallel flows", async (t) => {
  await cmpAll(t, [
    ["two columns of lines side by side", doc(lines(1, 5) + fx("", col(6, 13, "flex:1") + `<div style="flex:1">` + lines(1, 8, () => "", "S") + `</div>`) + lines(14, 15)), SMALL],
    ["columns of different lengths", doc(lines(1, 5) + fx("", col(6, 15, "flex:1") + `<div style="flex:1">` + lines(1, 2, () => "", "S") + `</div>`)), SMALL],
    ["a row that avoids breaking inside moves", doc(lines(1, 6) + fx("break-inside:avoid", col(7, 11, "flex:1") + `<div style="flex:1">S</div>`) + lines(12, 13)), SMALL],
    ["an item that avoids breaking inside", doc(lines(1, 6) + fx("", col(7, 11, "flex:1;break-inside:avoid") + `<div style="flex:1">` + lines(1, 5, () => "", "S") + `</div>`)), SMALL],
    ["break-before:page inside one item", doc(lines(1, 3) + fx("", `<div style="flex:1"><div class="l">A1</div><div class="l" style="break-before:page">A2</div></div><div style="flex:1">` + lines(1, 4, () => "", "S") + `</div>`) + lines(4, 5)), SMALL],
    ["break-before:page on an item (row)", doc(lines(1, 3) + fx("", `<div class="l" style="flex:1">A</div><div class="l" style="flex:1;break-before:page">B</div>`) + lines(4, 5)), SMALL],
    ["wrapping row: lines of items", doc(fx("flex-wrap:wrap", Array.from({ length: 30 }, (_, i) => `<div class="l" style="width:140px">W${pad(i + 1)}</div>`).join(""))), SMALL],
    ["wrapping row with a forced break on an item", doc(fx("flex-wrap:wrap", Array.from({ length: 8 }, (_, i) => `<div class="l" style="width:140px;${i === 4 ? "break-before:page" : ""}">W${pad(i + 1)}</div>`).join(""))), SMALL],
    ["align-items:center with a tall sibling across the break", doc(lines(1, 5) + fx("align-items:center", col(6, 13, "flex:1") + `<div class="l" style="flex:1">MID</div>`)), SMALL],
    ["align-items:flex-end", doc(lines(1, 5) + fx("align-items:flex-end", col(6, 13, "flex:1") + `<div class="l" style="flex:1">END</div>`)), SMALL],
    ["stretched item with a background across pages", doc(lines(1, 5) + fx("", col(6, 13, "flex:1") + `<div style="flex:1;background:#cde">S</div>`)), P, { paint: true }],
    ["row-reverse", doc(lines(1, 5) + fx("flex-direction:row-reverse", col(6, 13, "flex:1") + `<div style="flex:1">` + lines(1, 3, () => "", "S") + `</div>`)), SMALL],
    ["margin of an item overflows the page", doc(lines(1, 7) + fx("", `<div class="l" style="margin-bottom:60px">A</div>`) + lines(8, 9)), SMALL],
    ["inline-flex is monolithic", doc(lines(1, 6) + `<div style="display:inline-flex">` + col(7, 11) + `</div>`), SMALL],
  ], G);
});

// ------------------------------------------------------------------------------------------------ grid

const grid = (style, inner) => `<div style="display:grid;${style}">${inner}</div>`;
probe("pagination.grid", "grid containers fragment between rows and inside items", async (t) => {
  const cells = (n, extra = () => "") => Array.from({ length: n }, (_, i) => `<div class="l" style="${extra(i)}">G${pad(i + 1)}</div>`).join("");
  await cmpAll(t, [
    ["one column of rows", doc(grid("", cells(20))), SMALL],
    ["two columns", doc(grid("grid-template-columns:1fr 1fr", cells(40))), SMALL],
    ["an item splits inside", doc(lines(1, 5) + grid("grid-template-columns:1fr 1fr", col(6, 13) + `<div>` + lines(1, 3, () => "", "S") + `</div>`) + lines(14, 15)), SMALL],
    ["a row whose items avoid breaking inside moves", doc(lines(1, 6) + grid("grid-template-columns:1fr 1fr", col(7, 11, "break-inside:avoid") + `<div style="break-inside:avoid">S</div>`) + lines(12, 13)), SMALL],
    ["grid with break-inside:avoid", doc(lines(1, 6) + grid("break-inside:avoid", cells(5)) + lines(7, 8)), SMALL],
    ["break-before:page on an item starts a new page for its row", doc(grid("grid-template-columns:1fr 1fr", cells(8, (i) => (i === 4 ? "break-before:page" : "")))), SMALL],
    ["align-items:end item with a forced page break and a split sibling", doc(lines(1, 7) + grid("grid-template-columns:1fr 1fr;align-items:end", `<div class="l" style="break-before:page">END</div><div>${lines(1, 12, () => '', 'T')}</div>`)), SMALL],
    ["break-after:page on an item", doc(grid("grid-template-columns:1fr 1fr", cells(8, (i) => (i === 3 ? "break-after:page" : "")))), SMALL],
    ["break-after on the last item breaks after the grid", doc(grid("", cells(3, (i) => (i === 2 ? "break-after:page" : ""))) + lines(1, 2)), SMALL],
    ["row gap 10px", doc(grid("row-gap:10px", cells(14))), SMALL],
    ["fixed row heights 50px", doc(grid("grid-auto-rows:50px", cells(8))), SMALL],
    ["an item spanning two rows across the break", doc(grid("grid-template-columns:1fr 1fr;grid-auto-rows:20px", cells(16) + `<div style="grid-row:span 4;grid-column:1">SPAN</div>` + cells(6))), SMALL],
    ["align-items:end in rows", doc(grid("grid-template-columns:1fr 1fr;align-items:end", col(1, 12) + `<div class="l">END</div>`)), SMALL],
    ["nested grid", doc(grid("", cells(5) + grid("", cells(8, () => "color:#333")) + cells(3))), SMALL],
    ["inline-grid is monolithic", doc(lines(1, 6) + `<div style="display:inline-grid">` + lines(7, 11) + `</div>`), SMALL],
    ["template rows with fr in a fixed height (400px)", doc(grid("grid-template-rows:1fr 1fr;height:400px", `<div>TOP</div><div>BOTTOM</div>`)), SMALL],
  ], G);
});

// ------------------------------------------------------------------------------------------------ multi-column

probe("pagination.multicol", "multi-column containers (column-count / columns)", async (t) => {
  await cmpAll(t, [
    ["column-count:2, one page", doc(`<div style="column-count:2">` + lines(1, 8) + `</div>`), SMALL],
    ["column-count:2 across pages", doc(`<div style="column-count:2">` + lines(1, 30) + `</div>`), SMALL],
    ["columns:2 with break-before:column", doc(`<div style="columns:2">` + lines(1, 2) + `<div class="l" style="break-before:column">C</div>` + lines(3, 4) + `</div>`), SMALL],
    ["column-width:100px", doc(`<div style="column-width:100px">` + lines(1, 12) + `</div>`), SMALL],
  ], G);
});

// ------------------------------------------------------------------------------------------------ floats

const fl = (style, inner) => `<div style="float:left;width:100px;${style}">${inner}</div>`;
probe('pagination.float.resume-margin', 'unforced float continuation drops the block-start margin', async t => {
  await cmpAll(t, [10, 30].flatMap(margin => [false, true].map(avoid => [
    `margin ${margin}, avoid ${avoid}`,
    doc(lines(1, 7) + fl(`margin-top:${margin}px;${avoid ? 'break-inside:avoid' : ''}`, lines(1, 4, () => '', 'F')) + lines(8, 14)),
    SMALL,
  ])), G);
});
probe('pagination.float.reflow-contexts', 'deferred floats reflow nested, RTL and variable-height page contexts', async t => {
  const body = (side = 'left') => lines(1, 7) + `<div style="float:${side};width:100px;margin-top:10px;break-inside:avoid">${lines(1, 4, () => '', 'F')}</div><p>${'following words '.repeat(40)}</p><div class="l" style="clear:both">CLEAR</div>`;
  await cmpAll(t, [
    ['nested formatting context', doc(`<div style="display:flow-root">${body()}</div>`), SMALL],
    ['RTL left float', doc(`<div dir="rtl">${body()}</div>`), SMALL],
    ['RTL right float', doc(`<div dir="rtl">${body('right')}</div>`), SMALL],
    ['variable page heights', doc(body(), '@page{size:300px 220px;margin:10px}@page:first{size:300px 200px}'), {}],
    ['variable page widths', doc(body(), '@page{size:300px 200px;margin:10px}@page:left{size:360px 200px}'), {}],
    ['deferred float at the first changed-width boundary reflows following text', doc(lines(1, 8) + `<div style="float:left;width:100px;height:80px;break-inside:avoid;background:#f00">F</div><p>${'following words '.repeat(45)}</p><div style="clear:both">CLEAR</div>`, '@page{size:300px 200px;margin:10px}@page:left{size:360px 200px;margin:10px}'), {}],
    ['whole float deferred inside a later width run reflows following text', doc(lines(1, 24) + `<div style="float:left;width:100px;height:100px;margin-top:10px;break-inside:avoid">LATE FLOAT</div><p>${'following words '.repeat(40)}</p><div class="l" style="clear:both">CLEAR</div>`, '@page{size:300px 200px;margin:10px}@page:left{size:360px 200px}'), {}],
    ['split float after a long prefix reflows following text at one width', doc(lines(1, 24) + `<div style="float:left;width:100px">${lines(1, 8, () => '', 'LATE FLOAT')}</div><p>${'following words '.repeat(60)}</p><div class="l" style="clear:both">CLEAR</div>`), SMALL],
    ['split float crossing a later width run keeps adjacent text in its exclusion', doc(lines(1, 24) + `<div style="float:left;width:100px">${lines(1, 8, () => '', 'LATE FLOAT')}</div><p>${'following words '.repeat(60)}</p><div class="l" style="clear:both">CLEAR</div>`, '@page{size:300px 200px;margin:10px}@page:left{size:360px 200px}'), {}],
  ], G);
});
probe("pagination.float", "floats across pages", async (t) => {
  await cmpAll(t, [
    ["float taller than the rest of the page breaks", doc(lines(1, 5) + fl("", lines(1, 8, () => "", "F")) + lines(6, 16)), SMALL],
    ["float taller than a page", doc(fl("", lines(1, 20, () => "", "F")) + lines(1, 4)), SMALL],
    ["float with break-inside:avoid moves to the next page", doc(lines(1, 6) + fl("break-inside:avoid", lines(1, 5, () => "", "F")) + lines(7, 16)), SMALL],
    ["monolithic float (fixed height, overflow hidden)", doc(lines(1, 6) + fl("height:100px;overflow:hidden", "FM") + lines(7, 16)), SMALL],
    ["text wraps beside a float that continues on the next page", doc(lines(1, 6) + fl("", lines(1, 8, () => "", "F")) + `<p>` + "word ".repeat(60) + `</p>`), SMALL],
    ["text beside a float pushed to the next page (lines re-flow?)", doc(lines(1, 6) + fl("break-inside:avoid;height:100px", "FA") + `<p>` + "word ".repeat(60) + `</p>`), SMALL],
    ["clear:both after a broken float follows it", doc(lines(1, 5) + fl("", lines(1, 8, () => "", "F")) + `<div class="l" style="clear:both">CLR</div>` + lines(6, 7)), SMALL],
    ["float:right", doc(lines(1, 5) + `<div style="float:right;width:100px">` + lines(1, 8, () => "", "F") + `</div>` + lines(6, 16)), SMALL],
    ["break-before:page on a float", doc(lines(1, 3) + fl("break-before:page", lines(1, 2, () => "", "F")) + lines(4, 6)), SMALL],
    ["float with margin-top at a page top (resumed float drops its margin)", doc(lines(1, 7) + fl("margin-top:30px", lines(1, 4, () => "", "F")) + lines(8, 14)), SMALL],
    ["float among the lines of a paragraph", doc(lines(1, 6) + `<p>a1 a2 <span style="float:left;width:60px">` + "f ".repeat(1) + `F1<br>F2<br>F3<br>F4<br>F5</span>` + "word ".repeat(30) + `</p>`), SMALL],
    ["two floats side by side of different heights", doc(lines(1, 5) + fl("", lines(1, 8, () => "", "F")) + fl("", lines(1, 3, () => "", "E")) + `<div style="clear:both"></div>` + lines(6, 7)), SMALL],
    ["a container that only holds a tall float (height 0)", doc(lines(1, 5) + `<div>` + fl("", lines(1, 8, () => "", "F")) + `</div>` + lines(6, 16)), SMALL],
    ["display:flow-root container with a float", doc(lines(1, 5) + `<div style="display:flow-root">` + fl("", lines(1, 8, () => "", "F")) + `</div>` + lines(6, 8)), SMALL],
  ], G);
});
probe("pagination.float.source-fit-split", "pinned upstream float fit/split assertion", async (t) => {
  const heights = [];
  for (const height of [65, 120]) {
    const html = `<p style="font-size:16px;line-height:20px;margin:0;"><span style="float:right;width:40px;height:${height}px;background:#f00;"></span>one<br>two<br>three<br>four<br>five<br>six</p>`;
    const r = await t.both(html, { size: { width: 240, height: 75 }, margin: 0, tagged: false });
    t.ok(!r.bm.error && !r.ref?.error, `height ${height}: both engines render`);
    const redHeights = (render) => render.pages.flatMap((_, page) => paintShapes(render, page)
      .filter((shape) => shape.endsWith("fill 1,0,0"))
      .map((shape) => {
        const box = shape.split(" ").slice(0, 4).map(Number);
        return Math.round(Math.abs(box[3] - box[1]) * 4 / 3 * 2) / 2;
      }));
    const actual = redHeights(r.bm);
    const expected = height === 65 ? [65] : [75, 45];
    const within_source_rounding = actual.length === expected.length && actual.every((n, i) => Math.abs(n - expected[i]) <= 0.75);
    t.ok(within_source_rounding, `upstream asserts height ${height} produces red float fragments ${JSON.stringify(expected)}: bm ${JSON.stringify(actual)}`);
    if (r.ref) t.same(`bm and pinned oracle agree on float height ${height}`, actual, redHeights(r.ref));
    heights.push({ requested: height, actual, expected });
  }
  const source = (style = "", before = "", after = "") =>
    `${before}<p ${style ? `style="${style}"` : ""}><span style="float:right;width:40px;height:120px;background:#f00;"></span>one<br>two<br>three<br>four<br>five<br>six</p>${after}`;
  const options = { size: { width: 240, height: 75 }, margin: 0, tagged: false };
  for (const [label, html] of [
    ["widows/orphans", source("font-size:16px;line-height:20px;margin:0;widows:2;orphans:2")],
    ["RTL paragraph", `<div dir="rtl">${source("font-size:16px;line-height:20px;margin:0;")}</div>`],
    ["nested flow-root", `<div style="display:flow-root">${source("font-size:16px;line-height:20px;margin:0;")}</div>`],
    ["clear after the float paragraph", source("font-size:16px;line-height:20px;margin:0;", "", `<div style="clear:both">CLEAR</div>`)],
  ]) await cmp(t, `source split with ${label}`, html, options, { geom: true, paint: true, expect: "render" });
  t.note(`source test: a_float_breaks_only_when_it_does_not_fit_its_page; ${JSON.stringify(heights)}`);
});

// Floats split or deferred by a page, by kind (task 18): clearance after a split float, floats wider or
// taller than the page, RTL, nested blocks and floats, widows / orphans beside a split or deferred
// float; on pages of one width and of alternating widths.
{
  const W = (n, p = 'w') => Array.from({ length: n }, (_, i) => `${p}${i}`).join(' ');
  const side = (s, style, inner) => `<div style="float:${s};width:100px;${style}">${inner}</div>`;
  const F = (from, to, p) => lines(from, to, () => '', p);
  const alt = '@page{size:300px 200px;margin:10px}@page:left{size:360px 200px;margin:10px}';
  const groups = {
    clear: (css) => [
      ...['left', 'right', 'both'].map((c) => [`clear:${c} after a split float`, doc(lines(1, 5) + side('left', '', F(1, 8, 'F')) + side('right', '', F(1, 3, 'R')) + `<p>${W(30)}</p><div class="l" style="clear:${c}">CLR</div>` + lines(6, 8), css)]),
      ['a clearing float after a split float', doc(lines(1, 5) + side('left', '', F(1, 8, 'F')) + side('left', 'clear:left', F(1, 2, 'G')) + `<p>${W(30)}</p>` + lines(6, 8), css)],
    ],
    oversized: (css) => [
      ['a float wider than its container and taller than the page', doc(lines(1, 3) + `<div style="float:left;width:400px">${F(1, 10, 'F')}</div><p>${W(30)}</p>`, css)],
      // (the paragraph's first line, pushed below the float onto a page of another width, wraps at that width: task 16/18)
      ['a float wider than its container pushes the first line to a later page', doc(lines(1, 7) + `<div style="float:left;width:400px">${F(1, 4, 'F')}</div><p>${W(40)}</p>`, css)],
      ['a wide float over two pages before a paragraph', doc(lines(1, 3) + `<div style="float:left;width:400px">${F(1, 18, 'F')}</div><p>${W(60)}</p>`, css)],
      ['a monolithic float taller than the page', doc(lines(1, 3) + `<div style="float:left;width:80px;height:400px;overflow:hidden">M</div><p>${W(60)}</p>`, css)],
      ['a float of text taller than the page', doc(lines(1, 3) + side('left', '', F(1, 25, 'F')) + `<p>${W(80)}</p>`, css)],
    ],
    rtl: (css) => [
      ['RTL right float split', doc(`<div dir="rtl">` + lines(1, 5) + side('right', '', F(1, 8, 'F')) + `<p>${W(40)}</p></div>`, css)],
      ['RTL left float split', doc(`<div dir="rtl">` + lines(1, 5) + side('left', '', F(1, 8, 'F')) + `<p>${W(40)}</p></div>`, css)],
    ],
    nested: (css) => [
      ['nested paragraphs beside a split float', doc(lines(1, 5) + side('left', '', F(1, 8, 'F')) + `<div><div style="margin-left:10px"><p>${W(15)}</p><p>${W(15, 'v')}</p></div><p>${W(20, 'u')}</p></div>`, css)],
      ['a split float in nested blocks', doc(lines(1, 5) + `<div style="padding-left:10px"><div>` + side('left', '', F(1, 8, 'F')) + `<p>${W(40)}</p></div></div>`, css)],
      ['a float in a split float', doc(lines(1, 5) + side('left', 'width:140px', side('left', 'width:60px', F(1, 6, 'I')) + F(1, 9, 'O')) + `<p>${W(40)}</p>`, css)],
      ['floats on both sides', doc(lines(1, 4) + side('left', '', F(1, 9, 'F')) + side('right', '', F(1, 6, 'R')) + `<p>${W(50)}</p>`, css)],
    ],
    'widows-orphans': (css) => [2, 3, 4].flatMap((wo) => [
      [`widows / orphans ${wo} beside a split float`, doc(lines(1, 6) + side('left', '', F(1, 6, 'F')) + `<p style="widows:${wo};orphans:${wo}">${W(36)}</p>`, css)],
      [`widows / orphans ${wo} beside a deferred float`, doc(lines(1, 7) + side('left', 'break-inside:avoid', F(1, 4, 'F')) + `<p style="widows:${wo};orphans:${wo}">${W(36)}</p>`, css)],
    ]),
  };
  for (const [name, make] of Object.entries(groups)) {
    probe(`pagination.float.${name}`, `floats across pages: ${name}`, async (t) => {
      await cmpAll(t, [
        ...make('', false).map(([label, html]) => [label, html, SMALL]),
        ...make(alt, true).map(([label, html]) => [`${label} (alternating page widths)`, html, {}]),
      ], G);
    });
  }
}

// The float cases of takumi-core/src/layout/fragmentation_tests.rs (pinned upstream), on 200 px pages:
// each upstream assertion on a box's fragments (page, block offset, block size) is checked against
// the painted background of that box, then the two engines are compared.
{
  const FLOAT_CSS = `html,body{margin:0;padding:0} .block{display:block} p{display:block;margin:0;font:16px/20px Inter;white-space:pre-line}
    .float{float:left;width:50px} .h10{height:10px;width:10px} .h20{height:20px} .h80{height:80px} .h110{height:110px} .h150{height:150px} .h300{height:300px}
    .avoid{break-inside:avoid} .clear{clear:both} .m30{margin-top:30px} .after{break-after:page} .border{border-bottom:10px solid #000}
    .rel{position:relative} .abs{position:absolute;top:150px;height:10px;width:10px} .forced-after{break-after:page}
    #float,#next{background:#f00} #b,#c,#wrap{background:#0f0}`;
  const page = { size: { width: 300, height: 200 }, margin: 0, tagged: false };
  const box = (id, cls, inner = '') => `<div id="${id}" class="block ${cls}">${inner}</div>`;
  // fragments of the box painted in `colour`: [page, block offset, block size] in px
  const fragmentsOf = (render, colour) => render.pages.flatMap((p, i) => paintShapes(render, i)
    .filter((shape) => shape.endsWith(`fill ${colour}`))
    .map((shape) => { const [, y0, , y1] = shape.split(' ').map(Number); const top = p.media[3]; return [i, Math.round((top - y1) * 4 / 3), Math.round((y1 - y0) * 4 / 3)]; }));
  const cases = [
    ['a_resumed_float_drops_its_block_start_margin', box('float', 'float h300 m30'), { '1,0,0': [[0, 30, 170], [1, 0, 130]] }],
    ['a_forced_break_before_a_float_leaves_the_container_unbroken_by_inflow_content', `<div id="wrap" class="block border">${box('a', 'h20 after')}${box('float', 'float h20')}</div>`, { '1,0,0': [[1, 0, 20]] }],
    ['a_float_taller_than_a_page_breaks_across_pages', box('float', 'float h300'), { '1,0,0': [[0, 0, 200], [1, 0, 100]] }, 2],
    ['a_float_that_avoids_breaking_moves_to_the_next_page_alone', box('a', 'h150') + box('float', 'float h80 avoid') + box('b', 'h20'), { '1,0,0': [[1, 0, 80]], '0,1,0': [[0, 150, 20]] }],
    ['a_block_that_clears_a_broken_float_follows_it_to_the_next_page', box('float', 'float h300') + box('c', 'h20 clear'), { '0,1,0': [[1, 100, 20]] }],
    ['a_float_among_lines_breaks_across_pages', `<p id="p">${box('float', 'float h300')}a</p>`, { '1,0,0': [[0, 0, 200], [1, 0, 100]] }, 2],
    ['a_float_among_lines_that_avoids_breaking_moves_to_the_next_page_alone', box('a', 'h150') + `<p id="p">${box('float', 'float h80 avoid')}x</p>`, { '1,0,0': [[1, 0, 80]] }],
    ['a_forced_break_after_a_box_whose_absolute_child_runs_on_puts_the_next_float_on_the_next_page', box('a', 'h110') + `<div id="rel" class="block rel forced-after">${box('abs', 'abs')}</div>` + box('next', 'h10 float'), { '1,0,0': [[1, 0, 10]] }, 2],
  ];
  for (const [name, body, expected, count] of cases) {
    probe(`pagination.float.upstream.${name.replace(/_/g, '-')}`, `takumi-core fragmentation_tests.rs: ${name}`, async (t) => {
      const html = `<style>${FLOAT_CSS}</style><div class="block">${body}</div>`;
      const r = await cmp(t, name, html, page, { geom: true, paint: true, expect: 'render' });
      if (r.bm.error) return;
      if (count) t.same(`${name}: page count`, r.bm.pages.length, count);
      // (the forced-break container keeps its block-end border on its first fragment: 20 + 10 px)
      if (name.startsWith('a_forced_break_before_a_float')) t.ok(paintShapes(r.bm, 0).some((s) => s.endsWith('fill 0,1,0') && Math.round((s.split(' ')[3] - s.split(' ')[1]) * 4 / 3) === 30), `${name}: wrap's first fragment is 30 px tall`);
      for (const [colour, frags] of Object.entries(expected)) t.same(`${name}: fragments of the box filled ${colour}`, fragmentsOf(r.bm, colour), frags);
      if (name === 'a_float_among_lines_that_avoids_breaking_moves_to_the_next_page_alone') t.ok(r.bm.textPages[0].includes('x'), `${name}: the line beside the float stays on page 1`);
    });
  }
}

// ------------------------------------------------------------------------------------------------ positioned boxes

const rel = (inner, style = "") => `<div style="position:relative;${style}">${inner}</div>`;
const abs = (style, inner = "ABS") => `<div style="position:absolute;${style}">${inner}</div>`;
probe("pagination.absolute", "position:absolute boxes across pages", async (t) => {
  await cmpAll(t, [
    ["top:0 in a container that spans two pages", doc(rel(lines(1, 14) + abs("top:0;right:0"))), SMALL],
    ["bottom:0 waits for the container's last fragment", doc(rel(lines(1, 14) + abs("bottom:0;right:0"))), SMALL],
    ["top:200px lands on the second page", doc(rel(lines(1, 14) + abs("top:200px;right:0"))), SMALL],
    ["taller than a page: breaks across pages", doc(rel(lines(1, 3) + abs("top:0;right:0;width:100px", lines(1, 14, () => "", "A")))), SMALL],
    ["as tall as its container (top:0;bottom:0)", doc(rel(lines(1, 14) + abs("top:0;bottom:0;right:0;width:100px;background:#cde", "A"))), SMALL],
    ["past the last page adds pages", doc(rel(lines(1, 3) + abs("top:500px;right:0"))), SMALL],
    ["past the last page, no positioned ancestor (initial containing block)", doc(lines(1, 3) + abs("top:500px;right:0")), SMALL],
    ["bottom:0 against the initial containing block = bottom of the first page", doc(lines(1, 14) + abs("bottom:0;right:0")), SMALL],
    ["initial containing block box taller than a page", doc(lines(1, 3) + abs("top:0;right:0;width:100px", lines(1, 14, () => "", "A"))), SMALL],
    ["static position (no offsets) among lines", doc(lines(1, 12) + abs("", "STATIC") + lines(13, 14)), SMALL],
    ["static position after a forced break", doc(lines(1, 3) + abs("break-before:page", "STATIC") + lines(4, 5)), SMALL],
    ["inside overflow:hidden container adds no pages", doc(`<div style="position:relative;overflow:hidden;height:100px">` + lines(1, 3) + abs("top:500px") + `</div>` + lines(4, 5)), SMALL],
    ["negative top above the first page", doc(rel(lines(1, 3) + abs("top:-50px;right:0"))), SMALL],
    ["in a flex container spanning pages", doc(`<div style="position:relative;display:flex;flex-direction:column">` + lines(1, 14) + abs("top:0;right:0;width:100px", lines(1, 12, () => "", "A")) + `</div>`), SMALL],
    ["in a table cell spanning pages", doc(`<table style="border-spacing:0;position:relative"><tr><td style="padding:0">` + lines(1, 14) + abs("bottom:0;right:0") + `</td></tr></table>`), SMALL],
    ["break-inside:avoid abs box at the page end moves", doc(rel(lines(1, 14) + abs("top:140px;right:0;break-inside:avoid", lines(1, 4, () => "", "A")))), SMALL],
    ["z-index:-1 box behind the content", doc(rel(lines(1, 14) + abs("top:0;left:0;width:100%;height:100%;background:#cde;z-index:-1", ""))), P],
  ], G);
  const straddling = await t.both(doc(rel(lines(1, 14) + abs("top:170px;right:0"))), SMALL);
  if (straddling.bm.error) t.ok(false, `straddling absolute box renders: ${straddling.bm.error}`);
  else {
    const word = wordBoxes(straddling.bm.bytes)[1]?.find((w) => w[0] === "ABS");
    t.ok(!!word && Math.abs(word[2] - 7.5) <= 1, `absolute fragment starts in the page content area: ${JSON.stringify(word)}`);
    t.note("pinned Takumi paints the surviving fragment in the top margin; bm-render clips it to the page content area");
  }
});
probe("pagination.fixed", "position:fixed boxes repeat on every page", async (t) => {
  const fixed = (style, inner = "FIX") => `<div style="position:fixed;${style}">${inner}</div>`;
  await cmpAll(t, [
    ["top:0 right:0", doc(fixed("top:0;right:0") + lines(1, 20)), SMALL],
    ["bottom:0 right:0", doc(fixed("bottom:0;right:0") + lines(1, 20)), SMALL],
    ["written at the end of the document", doc(lines(1, 20) + fixed("top:0;right:0")), SMALL],
    ["inside a container pushed to page 2 by a forced break (takumi-pdf: on every page, at the top)", doc(lines(1, 3) + `<div style="break-before:page">` + fixed("top:0;right:0") + lines(4, 20) + `</div>`), SMALL],
    ["static position (no offsets)", doc(lines(1, 3) + fixed("", "FIXS") + lines(4, 20)), SMALL],
    ["top:50% (of the page area)", doc(fixed("top:50%;right:0") + lines(1, 20)), SMALL],
    ["width:100% height:100% background (a page frame)", doc(fixed("inset:0;border:2px solid #f00", "") + lines(1, 20)), P, { paint: true }],
    ["z-index:-1 paints under the content", doc(fixed("inset:0;background:#cde;z-index:-1", "") + lines(1, 20)), P, { paint: true }],
    ["fixed inside a transformed ancestor is not fixed", doc(`<div style="transform:translateX(0)">` + fixed("top:0;right:0") + lines(1, 20) + `</div>`), SMALL],
    ["fixed inside a fixed", doc(fixed("top:0;right:0;width:100px", "OUT" + fixed("top:20px;right:0", "IN")) + lines(1, 20)), SMALL],
    ["fixed taller than the page area is clipped", doc(fixed("top:0;right:0;width:60px", lines(1, 14, () => "", "F")) + lines(1, 12)), SMALL],
    ["fixed with a link", doc(fixed("top:0;right:0", `<a href="https://example.com/">LINK</a>`) + lines(1, 20)), SMALL],
    ["fixed on the pages an absolute box adds", doc(fixed("top:0;right:0") + lines(1, 3) + abs("top:400px", "FAR")), SMALL],
    ["two fixed boxes", doc(fixed("top:0;right:0", "FA") + fixed("bottom:0;right:0", "FB") + lines(1, 20)), SMALL],
    ["display:none fixed", doc(fixed("top:0;right:0;display:none") + lines(1, 20)), SMALL],
    ["fixed in viewport mode is not repeated", doc(fixed("top:0;right:0") + lines(1, 5)), { viewport: { width: 300, height: 200 } }],
  ], G);
});
probe("pagination.sticky", "position:sticky is laid out in flow", async (t) => {
  await cmp(t, "sticky header", doc(`<div class="l" style="position:sticky;top:0">STICKY</div>` + lines(1, 20)), SMALL, G);
});

// ------------------------------------------------------------------------------------------------ relative / transform

probe("pagination.relative", "position:relative offsets move paint across pages, not the break positions", async (t) => {
  await cmpAll(t, [
    ["top:30px near the page end (painted across the edge)", doc(lines(1, 8) + `<div class="l" style="position:relative;top:30px">REL</div>` + lines(9, 12)), SMALL],
    ["top:200px moves the box one page down", doc(lines(1, 3) + `<div class="l" style="position:relative;top:200px">REL</div>` + lines(4, 20)), SMALL],
    ["top:-200px moves the box to the previous page", doc(lines(1, 12) + `<div class="l" style="position:relative;top:-200px;left:100px">REL</div>` + lines(13, 14)), SMALL],
    ["past the last page adds pages", doc(lines(1, 3) + `<div class="l" style="position:relative;top:500px">REL</div>`), SMALL],
    ["above the first page", doc(`<div class="l" style="position:relative;top:-50px">REL</div>` + lines(1, 3)), SMALL],
  ], G);
  const translated = await t.both(doc(lines(1, 5) + `<div style="position:relative;top:10px">` + lines(6, 14) + `</div>`), SMALL);
  if (translated.bm.error) t.ok(false, `relative container across pages renders: ${translated.bm.error}`);
  else {
    const word = wordBoxes(translated.bm.bytes)[1]?.find((w) => w[0] === "L09");
    t.ok(!!word && Math.abs(word[2] - 7.5) <= 1, `relative content starts in the page content area: ${JSON.stringify(word)}`);
    t.note("pinned Takumi paints the surviving fragment in the top margin; bm-render keeps it in the page content area");
  }
});
probe("pagination.transform", "transforms move paint across pages; a box moved past the end adds pages", async (t) => {
  await cmpAll(t, [
    ["translateY(30px) near the page end", doc(lines(1, 8) + `<div class="l" style="transform:translateY(30px)">TRN</div>` + lines(9, 12)), SMALL],
    ["translateY(200px): one page down", doc(lines(1, 3) + `<div class="l" style="transform:translateY(200px)">TRN</div>` + lines(4, 20)), SMALL],
    ["translateY(-200px): to the previous page", doc(lines(1, 12) + `<div class="l" style="transform:translate(100px,-200px)">TRN</div>` + lines(13, 14)), SMALL],
    ["translateY(500px) past the last page adds pages", doc(lines(1, 3) + `<div class="l" style="transform:translateY(500px)">TRN</div>`), SMALL],
    ["translateY(-300px) above the first page", doc(`<div class="l" style="transform:translateY(-300px)">TRN</div>` + lines(1, 3)), SMALL],
    ["rotate(90deg) box across a page edge", doc(lines(1, 7) + `<div class="l" style="transform:rotate(90deg);width:100px;margin-left:60px">ROT</div>` + lines(8, 12)), SMALL],
    ["scale(2) box near the page end", doc(lines(1, 8) + `<div class="l" style="transform:scale(2);transform-origin:0 0;width:60px">SCL</div>` + lines(9, 12)), SMALL],
    ["a transformed container that itself spans a break", doc(lines(1, 5) + `<div style="transform:translateX(20px)">` + lines(6, 14) + `</div>`), SMALL],
    ["transform on an avoid-break box", doc(lines(1, 7) + `<div style="transform:translateX(20px);break-inside:avoid">` + lines(8, 11) + `</div>`), SMALL],
    ["a shadow past the last page adds no page", doc(lines(1, 8) + `<div class="l" style="box-shadow:0 100px 0 #f00">SH</div>`), SMALL],
    ["translate property", doc(lines(1, 3) + `<div class="l" style="translate:0 200px">TRN</div>` + lines(4, 20)), SMALL],
  ], G);
});

// ------------------------------------------------------------------------------------------------ overflow clipping

probe("pagination.overflow", "overflow clipping across pages", async (t) => {
  const clip = (ov, h, n = 14, extra = "") => `<div style="overflow:${ov};height:${h}px;${extra}">` + lines(1, n, () => "", "C") + `</div>`;
  await cmpAll(t, [
    ["overflow:hidden box clips its content: no extra pages", doc(lines(1, 2) + clip("hidden", 60) + lines(3, 4)), SMALL],
    ["overflow:clip box", doc(lines(1, 2) + clip("clip", 60) + lines(3, 4)), SMALL],
    ["overflow:visible box: the overflow continues on later pages", doc(lines(1, 2) + clip("visible", 60) + lines(3, 4)), SMALL],
    ["a clipping box taller than a page breaks, and stops where it ends", doc(lines(1, 2) + clip("hidden", 260, 30) + lines(3, 4)), SMALL],
    ["clipping box at the page end (60px in 40px of room)", doc(lines(1, 7) + clip("hidden", 60) + lines(3, 4)), SMALL],
    ["overflow:hidden flex container", doc(lines(1, 2) + `<div style="display:flex;flex-direction:column;overflow:hidden;height:60px">` + lines(1, 14, () => "", "C") + `</div>` + lines(3, 4)), SMALL],
    ["overflow:hidden grid container", doc(lines(1, 2) + `<div style="display:grid;overflow:hidden;height:60px">` + lines(1, 14, () => "", "C") + `</div>` + lines(3, 4)), SMALL],
    ["rounded clip across pages", doc(lines(1, 2) + clip("hidden", 260, 30, "border-radius:20px;background:#cde") + lines(3, 4)), P, { paint: true }],
    ["overflow-x:hidden only (y visible)", doc(lines(1, 2) + `<div style="overflow-x:hidden;height:60px">` + lines(1, 14, () => "", "C") + `</div>` + lines(3, 4)), SMALL],
    ["visible overflow of a fixed-height box followed by a forced break", doc(`<div style="height:40px;break-after:page">` + lines(1, 12, () => "", "C") + `</div>` + lines(1, 2)), SMALL],
    ["clip-path box across pages", doc(lines(1, 5) + `<div style="clip-path:inset(0 0 0 0)">` + lines(6, 14) + `</div>`), SMALL],
    ["opacity group across pages", doc(lines(1, 5) + `<div style="opacity:0.5">` + lines(6, 14) + `</div>`), SMALL],
  ], G);
});

// ------------------------------------------------------------------------------------------------ lists, misc

probe("pagination.list-markers", "list markers across pages", async (t) => {
  const li = (n, f = (i) => `I${pad(i)}`) => Array.from({ length: n }, (_, i) => `<li class="l">${f(i + 1)}</li>`).join("");
  const css = `ol,ul{margin:0;padding-left:40px}`;
  await cmpAll(t, [
    ["ol of 20 items", doc(`<ol>${li(20)}</ol>`, css), SMALL],
    ["ul of 20 items", doc(`<ul>${li(20)}</ul>`, css), SMALL],
    ["ol start=8 reversed", doc(`<ol start="30" reversed>${li(20)}</ol>`, css), SMALL],
    ["list-style-position:inside", doc(`<ol style="list-style-position:inside">${li(20)}</ol>`, css), SMALL],
    ["lower-roman", doc(`<ol style="list-style-type:lower-roman">${li(20)}</ol>`, css), SMALL],
    ["nested lists", doc(`<ol>${li(5)}<li><ol>${li(10, (i) => `N${pad(i)}`)}</ol></li>${li(3, (i) => `Z${pad(i)}`)}</ol>`, css), SMALL],
    ["break-before:page on an item", doc(`<ol>${li(3)}<li class="l" style="break-before:page">BRK</li>${li(2, (i) => `Z${pad(i)}`)}</ol>`, css), SMALL],
  ], G);

  // A list item's marker belongs to its first fragment. The pinned oracle moves it to the second
  // page when the item itself splits, separating the number from the item's first lines.
  const split = await t.both(doc(lines(1, 6) + `<ol><li>M1<br>M2<br>M3<br>M4<br>M5<br>M6</li><li class="l">NEXT</li></ol>`, css), SMALL);
  if (split.bm.error) t.ok(false, `fragmented list item renders: ${split.bm.error}`);
  else {
    const pages = wordBoxes(split.bm.bytes).map((p) => p.map((w) => w[0]));
    t.ok(pages[0]?.includes("1.") && !pages.slice(1).flat().includes("1."), `the list marker appears once on the item's first fragment: ${JSON.stringify(pages)}`);
    t.ok(pages[0]?.includes("M1") && pages[1]?.includes("M6") && pages[1]?.includes("NEXT"), `item content remains in document order across pages: ${JSON.stringify(pages)}`);
    t.note("pinned Takumi moves the marker to the later fragment; bm-render keeps it with the item's first content");
  }
});
probe("pagination.misc", "display:contents, visibility, empty pages, long documents", async (t) => {
  await cmpAll(t, [
    ["display:contents wrapper", doc(`<div style="display:contents">` + lines(1, 12) + `</div>`), SMALL],
    ["display:contents with break-before", doc(lines(1, 3) + `<div style="display:contents;break-before:page">` + lines(4, 5) + `</div>`), SMALL],
    ["visibility:hidden block still takes space", doc(lines(1, 8) + `<div style="visibility:hidden;height:60px">HID</div>` + lines(9, 10)), SMALL],
    ["300 lines", doc(lines(1, 99) + lines(1, 99, () => "", "M") + lines(1, 99, () => "", "N")), SMALL],
    ["deeply nested containers with padding", doc(`<div style="padding:5px"><div style="padding:5px"><div style="padding:5px">` + lines(1, 20) + `</div></div></div>`), SMALL],
    ["a block exactly one page tall then lines", doc(`<div style="height:180px">B</div>` + lines(1, 3)), SMALL],
    ["a block of 180.5px", doc(`<div style="height:180.5px">B</div>` + lines(1, 3)), SMALL],
    ["fractional line heights (17.3px lines)", doc(Array.from({ length: 40 }, (_, i) => `<div style="height:17.3px;line-height:17.3px">Q${pad(i + 1)}</div>`).join("")), SMALL],
    ["wrapped paragraph text over three pages", doc(`<p style="font:12px/20px Inter">` + Array.from({ length: 150 }, (_, i) => "w" + i).join(" ") + `</p>`), SMALL],
    ["body with padding and border", `<style>html{margin:0} body{margin:0;padding:15px;border:5px solid #000;font:12px/20px Inter} .l{height:20px}</style>` + lines(1, 20), SMALL],
    ["body margin (UA default 8px) is kept", `<style>body{font:12px/20px Inter} .l{height:20px}</style>` + lines(1, 20), SMALL],
    ["html with a fixed height smaller than the content", `<style>html,body{margin:0;height:100px} body{font:12px/20px Inter} .l{height:20px}</style>` + lines(1, 20), SMALL],
    ["body min-height:100vh on a short document (one page)", `<style>html,body{margin:0} body{min-height:100vh;font:12px/20px Inter} .l{height:20px}</style>` + lines(1, 3), SMALL],
    ["body height:100vh with content of two pages", `<style>html,body{margin:0} body{height:100vh;font:12px/20px Inter} .l{height:20px}</style>` + lines(1, 14), SMALL],
  ], G);
});
