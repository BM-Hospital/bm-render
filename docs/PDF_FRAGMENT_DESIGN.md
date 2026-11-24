# PDF fragments and page lifetime

Design record for `.agents/plans/pdf-takumi-parity` task 02, written against the code as it is on
2026-11-23 (`src/layout/fragment.zig`, `src/pdf/paged.zig`, `src/pdf/chunks.zig`, `src/pdf/emit.zig`).
Reference: Takumi `ff9a5d411310c8cdd1ac76a4f106c123d309e0a4` (`takumi-pdf/src/streaming_tests.rs`,
`tests/window_scenes.rs`, `src/memory_tests.rs`). The implementation history is in
`.agents/plans/pdf-takumi-parity/streaming-chunks.md`; this file describes the model and its limits.

## 1. Coordinates: one stitched space, page windows

Layout runs once per frame at the page-area width with an unbounded height. `fragment.paginate`
then chooses breaks (Blink LayoutNG rules as ported by takumi-core: break classes and appeal,
forced and avoid breaks, orphans/widows, monolithic content, parallel flows) by probing one page at
a time on the finished layout and applying the break: content after a break moves down to the next
page by rewriting `Layout.y` / `Layout.h`. The result is one coordinate space where page `i` is the
half-open window `[pages[i].top, pages[i].top + pages[i].height)` (takumi's `PageSizes` /
`PageWindows`).

What boxes alone cannot express is returned in `fragment.Pages` and never patched into shared
nodes by the painter:

| Field | Meaning |
|:--|:--|
| `pages: []Page` | the windows (`top`, `height`), per page the page name (`@page` named pages) |
| `line_shifts: []LineShift` | lines `first_line..` of a text node painted `dy` lower (a line never splits) |
| `repeats: []Repeat` | subtrees painted again on another page (repeated `thead`/`tfoot`, `position: fixed`) |
| `starts` | where each page's content starts (`Start`, below), for continuation at another width |
| `Extend` | a fragment reaching past the page end (a cell keeps its block-end border/padding, takumi) |
| `BoxFragment` | per box: `y`, `h`, `from_prev`, `to_next` (clone / slice decoration) |

A page is painted by translating the whole tree by `-pages[i].top` and clipping to the window
(`box-decoration-break: slice`); `clone` re-applies the decorations per fragment.

## 2. Fragments under transforms and clips (tasks 03–07, 25)

Painting never moves a layout node. `emit.BoxFragment { id, window, tf, first, last }` is the
fragment of a box being painted: its window in stitched space, the transform of that fragment
(origin resolved against the fragment's own size), and whether it is the first / last fragment.
Rules, each with probes in `scripts/pdf-audit/page-fragments.probe.mjs`:

- The content of a transformed box is painted in the pass of the fragment that contains it
  (`Emitter.ownsContent`, `tpage` in the transformed space), not in the pass of the page being
  drawn: a box laid out on page 2 whose rotated corner reaches page 1 paints its background on
  page 1 and its text after it, on the page that owns the line.
- Lines, links (`inOtherFragment`), child boxes (`windowSlice`) and nested transformed boxes are
  painted only in the fragment holding them; a fragment that reaches no page paints nothing and
  opens no structure region (`tfExcludes`, `tfRegionShows`).
- Text ownership: the page owning a line emits selectable text; neighbouring pages reached by its
  geometry emit outlines only (no duplicated extraction). A line whose baseline a clip removed but
  whose ink shows keeps its visible extent.
- Positioned / lifted boxes are ordered as takumi's scene: z-index, then page pass, then tree order.
- Inline span backgrounds use one image strip (sum of the span's line fragments); each line clips
  the strip at its cumulative offset; `clone` places the image per fragment. Neighbouring pages
  reached by a span's ink open their marked-content regions (`prev_win` / `next_win`).

## 3. Continuation tokens (tasks 16–18)

A frame cannot change its inline size during pagination. Pages of another width (`@page :first`,
`:left`/`:right`, named pages) are a new layout at that width, continued from a token:

- `fragment.Start { node, line, forced, branches, row_height, side_flows }`: one point (a box or a
  paragraph line), or parallel `ResumePoint`s for a table row's cells, a flex line's or grid row's
  items (`branches`), and rowspanning cells continuing independently (`side_flows`).
- `ParagraphCut { node, glyph }`: a paragraph resumes at a glyph cut of its shaped text, so the next
  frame breaks the paragraph at the same place.
- `FrozenWidth { node, w }`: a flex/grid container continued at another width keeps its items'
  first-fragment widths (takumi keeps the flex/grid algorithm's sizes).
- `paged.laySegments` chains the frames in the same block coordinates (`Options.start`,
  `start_top`); counters (`counters.Seg`), links/anchors (`interactive.Collector.beginRun`), the
  structure tree and the emitter's neighbouring passes work across frames. A page whose start cannot
  be found again keeps the previous run's width.
- A paragraph whose first line a float pushed onto the page (its box started on the page before)
  resumes at line 0; the page starts at the earliest of its flows' points (`startY`: the float's
  continuation above the line), and the line is not first moved to the page top
  (`Frame.paginate`'s float re-flow is for lines resumed after a cut).

Tokens refer to layout node ids of a frame that shares the element model; across independently
built frames (section 5) they are re-keyed by DOM element (`paged.NodeKey`: nearest element plus
child path, the same key `tags.Carry` uses).

## 4. Layout passes for counters and bands

`paged.layOutRules` (whole document) measures bands with the counters of a one-page document,
resolves margins, lays the content out, and repeats while counter hooks change
(`counter_passes` = 3, then once more with the last numbers); dynamic bands are measured again with
the real page count and an `auto` margin that moves restarts the content layout
(`band_passes` = 3). Each pass owns an arena (`Pass.mem`) released as soon as the next pass replaces
it; the last pass belongs to the `Document` and is released after the file is written.

## 5. Emitting and releasing pages (tasks 19–21)

There are three lifetimes:

| Lifetime | Holds | Released |
|:--|:--|:--|
| Document | source, element model + computed styles + pseudos + CSS matcher (`Frame.prepareDocument`), fonts and subsets in use, object ids, encoded page streams, resolved anchors/destinations, structure tree, outline | after `DocWriter.finish` |
| Part | render nodes, layout tree, paragraphs, pagination, its pages' paint scratch (`Frame.initChunk`, its own arena) | after its pages are drawn (`DocWriter.endChunk`) |
| Page | paths, masks, patterns, paint queues, content builder | after each page (`emit` page scratch reset) |

`paged.writeChunked` draws a document a part at a time when `chunks.plan` can cut it:

- **`.forced`** — cuts between two block children of the flow element where a page break is forced;
  parts of at least `chunk_elements` (2048) source elements. Each part's frame also lays out the last
  child of the part before and the first of the part after, so the boxes at the seams break and open
  their regions exactly as in the whole document; only the part's own pages are drawn, its
  neighbours serving as `prev_win` / `next_win`. The frame is placed where the whole document has it
  (`Options.origin`, `Options.root_shift`).
- **`.flowing`** (`paged.FlowIter`) — cuts at any page boundary when there is no usable forced
  break: a part lays out the flow's children from the one holding its first page's start up to at
  least `chunk_elements / 4` elements (`flowBudget`), and at least six times its last two children
  when those are big, up to `2 × chunk_elements` elements (`partEnd`: the next part lays out again
  the child it starts in and the one after it, so parts of one or two big children — a long table
  each — laid every table out about three times a pass), keeps every page but its last, and hands a
  `Resume` (`NodeKey`, line + first glyph, page tops before/at/after, the child's top) to the next
  part, which must reproduce the same break. The start may be inside blocks, between the rows of a
  table, before a line / row / item of a flex or grid container (`paged.resumeKid`: any start that
  is one point), and inside a child holding positioned or transformed boxes (both parts lay that
  child out whole; ink crossing the seam is refused).
- `DocWriter`: `beginChunk` → `drawPages` (pages of that part, link annotations registered up front)
  → `endChunk` (structure tree built per part and copied compactly, `tags.Skip` / `tags.Carry` hand
  records over a seam, anchors/headings resolved to destinations: `handOn` / `takeOn`) → `finish`
  (one allocation for the file). A part whose pages `pageRanges` drops still collects its anchors
  and headings (`DocWriter.collect`).
- **Bands that show the page count** (a `pageNumber` / `totalPages` counter, a rule for the last
  page) are drawn once the count is known, in one layout of the parts (`paged.ChunkDraw`,
  `emit.Later`, `text.Track`). The difficulty is the font subsets: a CID font numbers its glyphs in
  the order they are first drawn, and the count's digits in the first page's band are among the
  first, so every later glyph code depends on the count. So:
  1. Every page is drawn with its bands for a provisional count (999; a tree with counters is laid
     out once for all pages, `bands.forPageProvisional`) in place: what a band adds to its page and
     to the document (resource names and their order, a font's first use, objects it writes) comes
     where the band does. `paintPage` marks the bands' spans (`Later.mark`: the page's root
     content stream, between operators, no marked content open) and their resources before and
     after; the content stream is kept compressed (`.fastest`) instead of encoded. `Track` records,
     per page, the glyphs its content draws first (`log`) and where it writes glyph code strings
     (`strs`); the provisional bands' glyphs are only noted.
  2. With the count known (and a counter band measured with it, as after a counting pass), the
     fonts start a second numbering (`Track.begin`), and page by page, in order
     (`DocWriter.settleLater`): its header is drawn again with the count on a fresh surface in the
     page's state at that point (after the same byte, at the page's scale, from the resources before
     it), its content's first glyphs are added in their order (`Track.replay`), its footer drawn
     likewise; the content's code strings are rewritten with the final codes (`Track.rewrite`) and
     the page's stream, bands spliced in, encoded. The fonts' code order is then the one of the
     document drawn with the count, glyph for glyph, so the file is byte-identical to the one the
     counting pass gives.
  3. What this cannot reproduce makes the caller count the pages first and draw again (memory
     checkpoint `chunks: count first: <why>`, after the first part that shows it): a Type3
     (colour) glyph or text in a stream of its own (an opacity group, a pattern: their codes are
     in objects already written); a band that adds other resources than its provisional one, writes
     an object (an image laid out per page), ends differently (its last byte decides the next
     operator's separator) or draws a character no font has; a glyph of a band drawn with different
     texts (its `/ActualText` spans would depend on the order); a counter band whose height changes
     with the count when the page areas follow the bands.
  The extra memory is the compressed streams, the band resources per page and the glyph records
  (about the size of the encoded streams, which the document keeps anyway); the extra time is a
  fast compression and decompression per page and the bands laid out and drawn twice.
- **Groups that draw nothing on a page.** A page's walk meets boxes that have nothing on it: the
  first page of a run of pages visits the whole frame (it collects the document-wide anchors and
  headings), and a neighbouring page's pass meets the boxes reaching into it. A box opening a
  group there (opacity, mask, isolation) used to leave an empty transparency-group XObject on the
  page, so a part's frame (fewer boxes) and the whole document gave different draw lists
  (`flow-bands-opacity-text`, `bands-opacity-text`: an `<h2>` with `opacity`, already at
  `9deac8f`). Such a box (outside the page's window, or met by another page's pass) now leaves its
  group out when it drew nothing (`emit.paintNode`, `Surface.popToDroppingEmpty`); a box on the
  page keeps its group even when empty, as takumi / krilla write it.

### When a page may be emitted, and when it must be held

A page is emitted (its part released) only when nothing later can change it. bm decides this per
cut, conservatively, before or while laying a part out; anything it cannot prove makes `chunks.plan`
refuse, and the document is laid out whole (memory checkpoint `chunks: whole: <why>`). The page is
held — i.e. the whole document waits — when:

| Condition | Why the page cannot be settled | takumi behaviour (`streaming_tests.rs`) |
|:--|:--|:--|
| a box of the flow paints past the seam (a transform or a positioned box reaching an earlier or later part's page: `Extents.computeWith`) | it would be painted by the wrong part | holds pages back to the reach of the transform / positioned box |
| `position: fixed`, floats among the flow's children, an absolute box whose containing block is outside its child | repeats on every page / exclusions cross the seam / its page is unknown | holds the containing block's pages until the box is found |
| page counters or target counters in the content, page rules depending on the root, pages of different widths | page numbers or geometry settle only after the whole layout | numbers again (bounded passes) before drawing |
| a `#fragment` link to a later part | its annotation is decided when its part is drawn: the parts between are joined | draws before layout ends and fixes the link later |
| the seam check fails (the next frame breaks differently, or ink crosses the cut: `Extents.computeWith`) | the part would not equal the whole document | n/a |
| a start with parallel flows: a table row, flex line or grid row broken inside (`Start.branches`), a rowspan running on (`side_flows`) | no single-point resume token (that page is no cut; the part grows to the next one) | resumes inside |
| one very long child of the flow (a single long table) | cut, but each part lays the whole child out again: no memory gain | lays out a page at a time |

Fonts, destinations and structure objects are finalized after the page streams; streams only
reference stable document object ids. No pointer into a part's arena survives `endChunk` (records
crossing a seam are copied with element keys).

## 6. Fixed interfaces

The interfaces later tasks build on, and which must not be bypassed by local coordinate offsets:
`fragment.Options` (`page_height_fn`, `start`, `start_top`, `origin`, `root_shift`, `extent_fn`),
`fragment.Pages` / `Start` / `ResumePoint` / `ParagraphCut` / `FrozenWidth` / `Extend` /
`BoxFragment`, `emit.BoxFragment`, `chunks.Plan` / `Part` / `Flow` / `Cut`, `paged.NodeKey` /
`Resume` / `FlowIter`, `emit.DocWriter` / `Later`, `text.Track`, `tags.Carry` / `tags.Skip`, and
the memtrace checkpoints (`count: page`, `emit: page done`, `part: drawn`, `chunks: whole: <why>`,
`chunks: count first: <why>`).

## 7. Measurements

Live bytes are the native addon's allocation counter (`src/memtrace.zig`; `memoryTrace`
checkpoints minus the baseline before the render), not RSS or the wasm memory size. Each render runs
in a fresh process. `node scripts/pdf-memory.mjs --stress` (native `linux-x64-gnu`, ReleaseFast,
2026-11-23, this checkout; the stress document of `bench/pdf/corpus`: per A4 page a heading,
paragraphs, a 14-row collapsed table and an image, page-counter footer, forced page breaks):

| Pages | ms/page | Peak | Live after page 1 | after page 50 | after page 200 | after last page | Parts | PDF KiB/page |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 4.55 | 2.37 MiB | 2.12 MiB | – | – | 2.12 MiB | whole (1 page) | 26.9 |
| 10 | 2.31 | 5.81 MiB | 5.80 MiB | – | – | 4.73 MiB | whole (too short for two parts) | 6.0 |
| 100 | 1.88 | 20.11 MiB | 16.48 MiB | 13.97 MiB | – | 12.32 MiB | 4 | 3.9 |
| 500 | 1.84 | 52.96 MiB | 38.13 MiB | 35.62 MiB | 41.62 MiB | 40.21 MiB | 18 | 3.7 |

The same documents laid out whole (`BM_PDF_CHUNKS=off`): peak 34.76 MiB at 100 pages and
160.36 MiB at 500 pages (live after page 200: 109.06 MiB).

`memory_tests.rs` document (700 sections, no forced break, `Page n of N` header, 350 pages, cut at
any page boundary in 5 parts): live after page 50 / 200 = 4.48 / 4.64 MiB in the counting pass
(x1.036) and 5.74 / 6.10 MiB in the drawing pass (x1.064), within takumi's x1.1 invariant; peak
7.61 MiB (17.37 MiB laid out whole). Timing figures are from one run on a shared 4-core container
and are indicative only; live bytes and peaks are deterministic.

What still grows with the page count (task 21): the shared element model and styles (about
55 KiB per stress page), encoded page streams and the structure tree kept until `finish` (about
11 KiB per stress page), and the object map built when the file is assembled. The stress document
is cut at its forced breaks; its peak is the element model, not its tables.

Long tables without forced breaks (`--stress`, 60-row tables on the stress page, cut between table
rows since 2026-11-23): 200 tables / 201 pages, peak 186.93 MiB laid out whole (before: no page
boundary could be cut at) → 70.82 MiB in 198 parts, live after page 50 / 200 = 43.60 / 49.34 MiB;
4.17 → 8.58 ms/page, as each part lays out again the table the next part starts in.

Since `partEnd` (2026-11-23), a part of such a document lays out about twelve tables instead of
three (wasm, 60-row tables on the stress page with its `Page n of N` footer, median of 5): 50
tables 790 → 460 ms (laid out whole 346 ms), wasm memory 27.3 → 38.9 MiB (whole 61.1 MiB); 100
tables 1572 → 966 ms (whole 668 ms), 47.8 → 53.2 MiB (whole 113 MiB). Each table was laid out
5.8 times (2.9 a pass: 48 parts of about one page for 51 pages); now 2.3 times (1.16 a pass, 5
parts). What remains over the whole layout is the counting pass the footer's page count needs
(one more layout of the document, about a third of the time drawn whole) and the 16 % laid out
again at the seams. The stress documents (cut at forced breaks) and documents of small children
(`memory_tests.rs` sections: the budget decides first) are cut as before. Native
(`pdf-memory.mjs --stress`): 200 tables in 20 parts instead of 198, 8.58 → 4.87 ms/page, peak
70.84 MiB (as before), live after page 50 / 200 = 46.36 / 51.57 MiB; 50 tables 4.37 ms/page,
peak 24.98 MiB, 5 parts.

Since the bands showing the page count are drawn once it is known (2026-11-24, no counting pass;
with word-wise cache-key comparison, a font-match cache, an ASCII glyph table and a colour-face
memo in shaping), wasm, median of 5, old and new runs interleaved on the same (loaded) container:

| Document | chunked before | chunked after | whole before | whole after |
|:--|--:|--:|--:|--:|
| 10 tables | 98.6 ms, 19.3 MiB | 94.3 ms, 19.4 MiB | 80.2 ms, 19.3 MiB | 76.3 ms, 19.4 MiB |
| 50 tables | 550.7 ms, 38.9 MiB | 389.1 ms, 38.4 MiB | 375.7 ms, 61.1 MiB | 359.8 ms, 58.5 MiB |
| 100 tables | 1152.7 ms, 53.2 MiB | 781.7 ms, 52.4 MiB | 759.8 ms, 113.0 MiB | 713.8 ms, 113.1 MiB |
| stress 100 pages | 387.6 ms, 30.1 MiB | 289.4 ms, 33.6 MiB | | |
| stress 500 pages | 1967.2 ms, 68.3 MiB | 1375.8 ms, 66.2 MiB | | |

(60-row tables on the stress page, its `Page n of N` footer; files byte-identical before and
after.) The 21 documents of `pdf-docs` 107.0 → 104.9 ms and the 245 image cases 759.7 → 744.9 ms
(png) are within noise. A chunked long-table document now costs about 1.1 times its whole layout
(the seams laid out again), at under half its memory.

## 8. Open items

- Cutting where a page starts with parallel flows (a table row, flex line or grid row broken
  inside, a running rowspan), and inside one very long child of the flow without laying it out
  again per part (rows of an auto-layout table depend on every row's content).
- Pages with forward links are joined instead of drawn early; page / target counters in the content
  and fixed boxes lay out the whole document.
- Bands showing the page count still need a counting pass (`chunks: count first`) when the document
  draws Type3 (colour) glyphs or text inside an opacity group / pattern (their codes are in
  objects written while drawing; renumbering them would mean holding those objects too), or when a
  band holds an image (laid out per page, each page's band writes its own image object).
- Streaming adapters of `streaming_tests.rs` compare output equivalence and part emission
  (`npm run test:pdf:chunks`, 80 cases); takumi's layout-pass counts and "laid at first page"
  instrumentation have no bm counterpart. The case-by-case status is in
  `scripts/pdf-coverage-map.json`.
- `window_scenes.rs` fixtures at small page sizes paginate differently from takumi (open
  exceptions of `upstream.html_fixtures_paint_from_their_windows` in `scripts/pdf-audit/exceptions.json`).
