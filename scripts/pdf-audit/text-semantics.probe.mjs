// Independent viewer checks: TJ grouping is not a semantic or raster difference.
import { probe, squash } from './lib.mjs';
import { vp } from './paint.probe.mjs';
import { inspect, renderPage } from '../../bench/pdf/lib/pdfjs.mjs';

for (const [id, css, value, expected, maxChannelDifference] of [
  ['tab-size', 'white-space:pre;tab-size:4', 'a\tb\tc', 'a b c', 0],
  ['pre-wrap', 'white-space:pre-wrap', 'a   b\n  c', 'a b c', 0],
  ['soft-hyphen', 'width:60px;hyphens:manual', 'extra&shy;ordinary', 'extra‐ ordinary', 0],
]) {
  probe(`text.spacing.${id}`, 'whitespace and generated hyphen viewer semantics', async t => {
    const r = await t.both(`<p style="margin:10px;font:20px Inter;${css}">${value}</p>`, vp(260, 120));
    t.ok(!r.bm.error, `bm renders${r.bm.error ? ': ' + r.bm.error : ''}`);
    if (r.bm.error) return;
    const bm = await inspect(r.bm.bytes);
    t.ok(!bm.error, 'pdf.js parses bm PDF');
    t.same('pdf.js extracted text', bm.pages?.map(p => squash(p.text)), [expected]);
    if (!r.ref || r.ref.error) {
      t.same('reference renders', r.ref?.error ?? null, null);
      return;
    }
    const ref = await inspect(r.ref.bytes);
    t.same('viewer extraction matches reference', bm.pages.map(p => p.text), ref.pages.map(p => p.text));
    const a = await renderPage(r.bm.bytes, 0, 2);
    const b = await renderPage(r.ref.bytes, 0, 2);
    t.same('raster dimensions', [a.width, a.height], [b.width, b.height]);
    let max = 0, changed = 0;
    for (let i = 0; i < a.rgba.length; i += 4) {
      let d = 0;
      for (let c = 0; c < 4; c++) d = Math.max(d, Math.abs(a.rgba[i + c] - b.rgba[i + c]));
      max = Math.max(max, d);
      changed += Number(d !== 0);
    }
    // (the generated hyphen starts at the item's width snapped to the LayoutUnit grid, as in
    // takumi: the rasters are identical)
    t.ok(max <= maxChannelDifference, `raster: ${changed} changed pixels, largest channel difference ${max}`);
    t.note('Compared with pdf.js extraction and raster output; equivalent TJ run grouping is not required.');
  });
}
