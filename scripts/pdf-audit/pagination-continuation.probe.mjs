// Named-page inline-size changes while parallel formatting contexts are unfinished.
import { probeAs, cmp } from './paint.probe.mjs';
import { squash } from './lib.mjs';
import { SMALL, cmp as comparePaged, doc, lines } from './paged-helpers.mjs';
import { rasterise } from '../../bench/pdf/lib/raster.mjs';

const words = (prefix, n = 45) => Array.from({ length: n }, (_, i) => `${prefix}${i} word`).join(' ');
const sheet = `<style>@page{size:240px 140px;margin:10px}@page:left{size:360px 140px;margin:10px}p{margin:0}td{padding:0;vertical-align:top}table{border-spacing:0}</style>`;
probeAs('pagination.continuation.rowspan-fixed-width', 'rowspanning cells retain an independent continuation flow', async t => {
  const html = `<style>@page{size:240px 140px;margin:10px}p{margin:0}td{padding:0;vertical-align:top}table{border-spacing:0}</style><div style="font:14px/20px Inter"><table style="width:100%"><tr><td rowspan="2" style="width:50%">${words('L')}</td><td>${words('R').slice(0,130)}</td></tr><tr><td>${words('B')}</td></tr></table><p>AFTER</p></div>`;
  const r = await cmp(t, '', html, {});
  if (r.ref && !r.bm.error && !r.ref.error) t.same('text per page', r.bm.textPages.map(squash), r.ref.textPages.map(squash));
});
probeAs('pagination.continuation.rowspan-width-reflow', 'rowspanning cells resume against each named-page width', async t => {
  const html = `${sheet}<div style="font:14px/20px Inter"><table style="width:100%"><tr><td rowspan="2" style="width:35%"><a href="#end">${words('SPAN', 20)}</a></td><td style="width:65%"><a href="#end">${words('ROW1', 12)}</a></td></tr><tr><td><a href="#end">${words('ROW2', 12)}</a></td></tr></table><p id="end">END</p></div>`;
  const r = await comparePaged(t, 'rowspan width change', html, {}, { geom: true });
  if (r.ref && !r.bm.error && !r.ref.error) {
    t.same('rowspan text per page', r.bm.textPages.map(squash), r.ref.textPages.map(squash));
    t.same('rowspan page boxes', r.bm.pages.map(p => p.media), r.ref.pages.map(p => p.media));
    const { inspect } = await import('../../bench/pdf/lib/pdfjs.mjs');
    const a = await inspect(r.bm.bytes), b = await inspect(r.ref.bytes);
    t.same('rowspan links per page', a.pages.map(p => p.links), b.pages.map(p => p.links));
  }
});
for (const [id, content] of [
  ['table-row', `<table style="width:100%"><tr><td style="width:50%">${words('L')}</td><td>${words('R')}</td></tr></table>`],
  ['table-plain', `<table style="width:100%"><tr><td style="width:50%">${'left word '.repeat(45)}</td><td>${'right word '.repeat(45)}</td></tr></table>`],
  ['table-unequal', `<table style="width:100%"><tr><td style="width:50%">${'short word '.repeat(8)}</td><td>${'long word '.repeat(55)}</td></tr></table>`],
  ['table-painted', `<table style="width:100%"><tr><td style="width:50%;background:#cde;border:1px solid blue">${words('L')}</td><td style="background:#edc;border:1px solid red">${words('R')}</td></tr></table>`],
  // a cell whose content ends at the page end keeps its block-end padding and border in that
  // fragment, past the page; the row's rest shrinks by it but still holds them on its last page
  ['table-painted-padded', `<table style="width:100%"><tr><td style="width:50%;background:#cde;border:1px solid blue;padding-bottom:3px">${words('L')}</td><td style="background:#edc;border:1px solid red;padding-bottom:3px">${words('R')}</td></tr></table>`],
  ['table-painted-unequal', `<table style="width:100%"><tr><td style="width:50%;background:#cde;border:1px solid blue">${words('L')}</td><td style="background:#edc;border:1px solid red">${words('R', 30)}</td></tr></table>`],
  ['table-links', `<table style="width:100%"><tr><td style="width:50%"><a href="https://example.com/left">${words('L')}</a></td><td><a href="#after">${words('R')}</a></td></tr></table><p id="after">Destination</p>`],
  ['table-rowspan', `<table style="width:100%"><tr><td rowspan="2" style="width:50%">${words('L')}</td><td>${words('R').slice(0, 130)}</td></tr><tr><td>${words('B')}</td></tr></table>`],
  ['flex-row', `<div style="display:flex"><div style="flex:1;min-width:0">${words('L')}</div><div style="flex:1;min-width:0">${words('R')}</div></div>`],
  ['grid-row', `<div style="display:grid;grid-template-columns:1fr 1fr"><div>${words('L')}</div><div>${words('R')}</div></div>`],
  // a flex / grid container broken inside takes the next page's width; its items keep the sizes
  // and offsets of its first fragment, the content after it takes each page's width
  ['flex-column', `<div style="display:flex;flex-direction:column;background:#fdd"><div style="background:#ddf">${words('A', 30)}</div><div>${words('B', 30)}</div></div><p>${words('AFTER', 30)}</p>`],
  ['flex-column-between', `<div style="display:flex;flex-direction:column"><div>${Array.from({ length: 6 }, (_, i) => `<div style="height:20px">L${i}</div>`).join('')}</div><div>${words('B', 30)}</div></div><p>${words('AFTER', 30)}</p>`],
  ['grid-column', `<div style="display:grid;background:#fdd"><div>${words('A', 30)}</div><div>${words('B', 30)}</div></div><p>${words('AFTER', 30)}</p>`],
  ['flex-row-after', `<div style="display:flex;background:#fdd"><div style="flex:1">${words('A', 12)}</div><div style="flex:1">${words('B', 8)}</div></div><p>${words('AFTER', 30)}</p>`],
  ['grid-rows-after', `<div style="display:grid;grid-template-columns:1fr 1fr"><div>${words('A', 30)}</div><div>x</div><div>${words('B', 30)}</div><div>y</div></div><p>${words('AFTER', 30)}</p>`],
  // a row resumed below a rowspan's finished rows, a rowspan running past its first row
  ['table-rowspan-tall-rows', `<table style="width:100%"><tr><td rowspan="2" style="width:35%">${words('S', 10)}</td><td>${words('R1', 30)}</td></tr><tr><td>${words('R2', 30)}</td></tr></table>`],
  ['table-rowspan3', `<table style="width:100%"><tr><td rowspan="3" style="width:40%">${words('S', 40)}</td><td>${words('R1', 8)}</td></tr><tr><td>${words('R2', 8)}</td></tr><tr><td>${words('R3', 8)}</td></tr></table>`],
  // a row that starts on a page of another width keeps the block size its table gave it
  ['table-two-rows', `<table style="width:100%"><tr><td style="width:50%">${words('A', 30)}</td><td>${words('B', 20)}</td></tr><tr><td>${words('C', 30)}</td><td>${words('D', 30)}</td></tr></table>`],
]) {
  probeAs(`pagination.continuation.${id}`, 'parallel continuation across alternating page widths', async t => {
    const r = await cmp(t, '', `${sheet}<div style="font:14px/20px Inter">${content}<p>AFTER</p></div>`, {});
    if (r.ref && !r.bm.error && !r.ref.error) {
      t.same('text per page', r.bm.textPages.map(squash), r.ref.textPages.map(squash));
      t.same('page boxes', r.bm.pages.map(p => p.media), r.ref.pages.map(p => p.media));
      if (id === 'table-links') {
        const { inspect } = await import('../../bench/pdf/lib/pdfjs.mjs');
        const a = await inspect(r.bm.bytes), b = await inspect(r.ref.bytes);
        t.same('links per page', a.pages.map(p => p.links), b.pages.map(p => p.links));
      }
    }
  });
}

// Text and word geometry only: the paint of these differs for reasons of their own (takumi splits a
// paragraph's marked content at an aligned grid row's page end; it paints a sliced table border
// side by side, bm as one clipped ring).
for (const [id, content] of [
  ['grid-align-end-after', `<div style="display:grid;grid-template-columns:1fr 1fr;align-items:end"><div>${words('A', 30)}</div><div>${words('B', 4)}</div></div>`],
  ['table-spacing-borders', `<table style="width:100%;border:2px solid red;border-spacing:3px"><tr><td style="width:50%;border:1px solid blue;padding:2px">${words('A', 30)}</td><td style="border:1px solid blue">${words('B', 10)}</td></tr><tr><td>${words('C', 30)}</td><td>${words('D', 30)}</td></tr></table>`],
]) {
  probeAs(`pagination.continuation.${id}`, 'continuation across alternating page widths (text and geometry)', async t => {
    await comparePaged(t, id, `${sheet}<div style="font:14px/20px Inter">${content}<p>${words('AFTER', 30)}</p></div>`, {}, { geom: true, expect: 'render' });
  });
}

probeAs('pagination.continuation.collapsed-border-overflow', 'collapsed table borders and cell backgrounds continue across a page cut', async t => {
  const html = `${sheet}<style>table{border-collapse:collapse}td{padding:0 2px 4px;border-left:3px solid #1673c9;border-right:3px solid #1673c9;border-top:3px solid red;border-bottom:3px solid blue}td:first-child{background:#cde}td:last-child{background:#edc}</style><div style="font:14px/20px Inter"><div style="height:40px"></div><table style="width:100%"><tr><td>${words('SHORT', 12)}</td><td>${words('LONG', 42)}</td></tr></table><p>AFTER</p></div>`;
  const r = await comparePaged(t, 'collapsed border overflow', html, {}, { geom: true, expect: 'render' });
  if (!r.bm.error && r.ref && !r.ref.error) {
    const [bmFirst, bmSecond, refFirst, refSecond] = await Promise.all([
      rasterise('pdfium', r.bm.bytes, 0, 144), rasterise('pdfium', r.bm.bytes, 1, 144),
      rasterise('pdfium', r.ref.bytes, 0, 144), rasterise('pdfium', r.ref.bytes, 1, 144),
    ]);
    const hasColorAtX = (page, x, ys, rgb) => ys.some(y => {
      const i = (y * page.width + x) * 4;
      return page.rgba[i] === rgb[0] && page.rgba[i + 1] === rgb[1] && page.rgba[i + 2] === rgb[2];
    });
    for (const [name, first, second] of [['bm', bmFirst, bmSecond], ['takumi', refFirst, refSecond]]) {
      t.ok(hasColorAtX(first, 100, Array.from({ length: 12 }, (_, i) => 188 + i), [0, 0, 255]), `${name}: collapsed block-end border paints at page 1 bottom`);
      t.ok(hasColorAtX(second, 100, Array.from({ length: 12 }, (_, i) => 10 + i), [255, 0, 0]), `${name}: collapsed block-start border paints at page 2 top`);
    }
  }
});

// An aligned item can have an empty first fragment while its sibling already
// paints. On resumption the original row alignment offset must not be repeated.
for (const align of ['start', 'center', 'end']) {
  for (const prefix of [0, 3]) {
    probeAs(`pagination.continuation.grid-aligned-${align}-${prefix}`, 'aligned grid items resume at the fragment start', async t => {
      const html = doc(lines(1, prefix) + `<div style="display:grid;grid-template-columns:1fr 1fr;align-items:${align}"><div>${lines(1, 24)}</div><div class="l">ALIGNED</div></div>` + lines(1, 2, () => '', 'AFTER'));
      await comparePaged(t, '', html, SMALL, { geom: true, expect: 'render' });
    });
  }
}

// Grid row fragments (task 17): forced breaks before / after an item under each row alignment,
// a row taller than the page, nested grids, items spanning rows, text and table content. Text and
// word geometry, then the paint (the items carry backgrounds, so their fragments are compared).
const gridOf = (style, inner) => `<div style="display:grid;${style}">${inner}</div>`;
const bg = (c) => `background:${c}`;
const tagged = (from, to, p) => lines(from, to, () => '', p);
const gridCases = [];
for (const al of ['start', 'center', 'end', 'stretch']) {
  gridCases.push([`break-before-item-${al}`, lines(1, 3) + gridOf(`grid-template-columns:1fr 1fr;align-items:${al};${bg('#fdd')}`, `<div style="${bg('#ddf')}">${tagged(1, 4, 'A')}</div><div style="break-before:page;${bg('#dfd')}">${tagged(1, 2, 'B')}</div>`)]);
  gridCases.push([`break-before-row-${al}`, lines(1, 3) + gridOf(`grid-template-columns:1fr 1fr;align-items:${al}`, `<div>${tagged(1, 2, 'A')}</div><div>${tagged(1, 1, 'B')}</div><div style="break-before:page">${tagged(1, 3, 'C')}</div><div>${tagged(1, 1, 'D')}</div>`)]);
  gridCases.push([`break-after-item-${al}`, lines(1, 3) + gridOf(`grid-template-columns:1fr 1fr;align-items:${al}`, `<div style="break-after:page">${tagged(1, 2, 'A')}</div><div>${tagged(1, 3, 'B')}</div><div>${tagged(1, 2, 'C')}</div>`)]);
  gridCases.push([`tall-row-${al}`, lines(1, 2) + gridOf(`grid-template-columns:1fr 1fr;align-items:${al}`, `<div>${tagged(1, 14, 'A')}</div><div>${tagged(1, 3, 'B')}</div>`)]);
}
gridCases.push(['nested', lines(1, 2) + gridOf('grid-template-columns:1fr 1fr', `<div>${gridOf(`grid-template-columns:1fr 1fr;${bg('#fdd')}`, `<div style="${bg('#ddf')}">${tagged(1, 12, 'N')}</div><div>${tagged(1, 3, 'M')}</div>`)}</div><div style="${bg('#dfd')}">${tagged(1, 5, 'B')}</div>`)]);
// (C's first line moves down past the page end and its row grows; S spanning both rows keeps the
// block size the grid gave it)
gridCases.push(['row-span-pushed', lines(1, 2) + gridOf(`grid-template-columns:1fr 1fr;${bg('#fdd')}`, `<div style="grid-row:span 2;${bg('#ddf')}">${tagged(1, 14, 'S')}</div><div style="${bg('#dfd')}">${tagged(1, 3, 'B')}</div><div>${tagged(1, 4, 'C')}</div>`)]);
gridCases.push(['row-span-3', lines(1, 2) + gridOf('grid-template-columns:1fr 1fr', `<div style="grid-row:span 3">${tagged(1, 10, 'S')}</div><div>${tagged(1, 5, 'B')}</div><div>${tagged(1, 5, 'C')}</div><div>${tagged(1, 5, 'D')}</div>`)]);
gridCases.push(['text', gridOf('grid-template-columns:1fr 1fr', `<div>${words('A', 60)}</div><div>${words('B', 20)}</div>`)]);
gridCases.push(['table', gridOf('grid-template-columns:1fr 1fr', `<div><table style="border-spacing:0">${Array.from({ length: 14 }, (_, i) => `<tr><td style="padding:0;height:20px">T${i}</td></tr>`).join('')}</table></div><div>${tagged(1, 3, 'B')}</div>`)]);
gridCases.push(['row-gap', gridOf('grid-template-columns:1fr 1fr;row-gap:30px', `<div>${tagged(1, 5, 'A')}</div><div>${tagged(1, 2, 'B')}</div><div>${tagged(1, 6, 'C')}</div><div>${tagged(1, 2, 'D')}</div>`)]);
gridCases.push(['explicit-rows', lines(1, 2) + gridOf('grid-template-columns:1fr 1fr;grid-template-rows:100px 100px 100px', `<div>${tagged(1, 3, 'A')}</div><div>${tagged(1, 2, 'B')}</div><div>${tagged(1, 3, 'C')}</div><div>${tagged(1, 2, 'D')}</div><div>E</div>`)]);
gridCases.push(['align-self-end', lines(1, 3) + gridOf('grid-template-columns:1fr 1fr', `<div>${tagged(1, 12, 'A')}</div><div style="align-self:end">${tagged(1, 2, 'B')}</div>`)]);
gridCases.push(['padded', lines(1, 3) + gridOf('grid-template-columns:1fr 1fr;padding:15px;border:2px solid red', `<div>${tagged(1, 12, 'A')}</div><div>${tagged(1, 2, 'B')}</div>`)]);
for (const [id, body] of gridCases) {
  probeAs(`pagination.grid-fragments.${id}`, 'grid row fragments across pages', async t => {
    const html = doc(body + tagged(1, 2, 'AFTER'));
    await comparePaged(t, id, html, SMALL, { geom: true, expect: 'render' });
    // (paint: an end-aligned row taller than the page is the one known difference, a sub-pixel
    // offset of the container's continuation fragment)
    if (id !== 'tall-row-end') await cmp(t, `${id} paint`, html, SMALL);
  });
}
