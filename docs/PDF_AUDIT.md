# PDF port audit: bm-render/pdf versus takumi-pdf

This document records, feature by feature, how complete bm-render's PDF output is compared with
takumi-pdf, the Rust library it is a port of. It is a developer document: it names source files, tests
and probes. The user documentation is in `docs/en/pdf/`.

- [Scope and method](#scope-and-method)
- [Status words](#status-words)
- [Summary](#summary)
- [Golden coverage map](#golden-coverage-map)
- [JS API surface](#js-api-surface)
- [Page model, pagination, bands and counters](#page-model-pagination-bands-and-counters)
- [Painting](#painting)
- [Text and fonts](#text-and-fonts)
- [Images and SVG](#images-and-svg)
- [File layer](#file-layer)
- [krilla validation errors](#krilla-validation-errors)
- [Not applicable](#not-applicable)
- [Not ported, and why](#not-ported-and-why)
- [How to re-run the evidence](#how-to-re-run-the-evidence)

## Scope and method

**Reference.** `ref/takumi` at commit `33eed4a` (2026-11-11): the crate `takumi-pdf` 0.20.0 (which vendors
a modified krilla and a font subsetter), the JS package `takumi-pdf-js` 0.20.0, the layout core
`takumi-core` 0.36.0 (block fragmentation is its `fragmentation` feature) and the docs in
`docs/content/docs/pdf/*.mdx`. The published npm package `takumi-pdf@0.20.0` was installed outside the
repository and driven through its documented JS API.

**Published package versus source tree.** Both say 0.20.0, but the source tree is newer than the package
in a few places. The table columns say `0.20.0` when the published package has the behaviour (established
by running it) and `HEAD` when only the source tree and its golden files have it. Seven golden fixtures
are HEAD-only: `avoid-break-out-of-flow-overflow`, `img-without-source-past-page`,
`flex-item-margin-past-page`, `flex-item-child-break-after`, `flex-item-table-row-break-after`,
`floated-flex-item-break-after` and `break-after-with-running-absolute`. bm-render matches the golden on
all seven, so it is ahead of the published package there.

**Evidence.** Three kinds, all runnable:

1. `node scripts/pdf-compare.mjs`: renders the input of each of takumi-pdf's 136 golden fixtures
   (`takumi-pdf/tests/fixtures-generated/*.pdf`) and compares every page operator by operator, plus fonts,
   structure tree, annotations, outline, Info, XMP, ids and attachments. Before this audit the script covered
   89 of the 136 goldens; the other 47 are now in `scripts/pdf-compare-more.mjs`.
2. `node scripts/pdf-audit/run.mjs`: probes (`scripts/pdf-audit/*.probe.mjs`). A probe renders one input with
   bm-render and with the published takumi-pdf package and compares page count, page boxes, text per page
   (`pdftotext`), content-stream operators, catalog / Info / XMP entries, structure tree, annotations, fonts,
   or the error message.
3. Zig unit tests (`zig build test -Dpdf=true`) and `npm run test:pdf`.

A row is `ported+equivalent` only when one of these passes for it. Anything read from the sources but not
run is marked `unverified`.

**Normalised differences.** Three differences are by design and are normalised before comparing:
bm-render prefixes error messages with `bm-render: `; `/Producer` is `bm-render` instead of
`takumi-pdf 0.20.0` (and the ids hashed from the file differ with it); and Flate streams hold the same data
compressed by a different encoder, so their byte lengths differ. When takumi-pdf's message is a serde
type error (`data did not match any variant of untagged enum SizeInput`), bm-render only has to reject the
same input; its wording is its own.

## Status words

| Status | Meaning |
|:--|:--|
| ported+equivalent | Implemented, and a golden or probe shows the same result as takumi-pdf. |
| ported+differs | Implemented, and the result differs in a way the row states. |
| partial | Some cases are implemented and others are not; the row says which. |
| missing | No implementation. |
| extension | bm-render has it and takumi-pdf does not. |
| n/a | takumi-pdf's API cannot reach it, so there is nothing to port. |

## Summary

Counts are features (rows of the tables below), not probes. Probe and golden counts are the evidence
behind them.

| Status | Features |
|:--|--:|
| ported+equivalent | 75 |
| ported+differs | 44 |
| partial | 1 |
| missing | 6 |
| extension | 8 |
| n/a | 4 |

| Evidence | Before the audit (main `664fb3f`) | Now |
|:--|:--|:--|
| Probes vs published takumi-pdf 0.20.0 (`scripts/pdf-audit/run.mjs`, 1458) | 1168 pass / 290 fail | 1347 pass / 111 fail (every remaining failure is a row below) |
| Latest full probe audit (2026-11-23, pinned takumi-pdf source `ff9a5d4`, `scripts/pdf-audit/run.mjs --strict`, wasm) | — | 2037 probes: 2015 pass / 22 strict parity differences; these include intentional CSS/API differences and are not a count of bm-render defects |
| Golden fixtures (`scripts/pdf-compare.mjs`, 136) | 105 identical / 2 close / 29 differ / 0 errors | 125 identical / 10 close / 1 differ / 0 errors (`list-marker-pagination`, deliberate) |
| `npm run test:pdf` | 367 passed | 393 passed on each backend (WASM and native) |

What was missing at the start of this audit and is ported now: pages of different widths (`@page :first` /
`:left` / `:right` and named pages of other sizes), the `@page` cascade (inside `@media` / `@layer` /
`@supports`, `!important`, layers, specificity), `@page` lengths (`calc()`, viewport units, font-relative
units), CSS counters in generated content, JSX input for documents and bands, `prepare` fetching images,
raster images embedded the way krilla takes them (PNG / JPEG passthrough, 16-bit, gray, ICC, CMYK), SVG drawn
as vectors with clip paths / masks / patterns / markers / text, inline outlines, `background-clip: text` of
inline spans, per-run opacity and shadows of inline elements, the negative z-index layer, link annotations in
tree order, inline role elements ending the paragraph run (invoice `P, P`), and linear time per page on long
documents. Every remaining difference is listed in the tables with its cause.

## Golden coverage map

All 136 golden fixtures of `ref/takumi/takumi-pdf/tests/fixtures-generated` are compared (89 in
`scripts/pdf-compare.mjs`, 47 in `scripts/pdf-compare-more.mjs`). The ones that are not identical:

| Fixture | Result | Cause |
|:--|:--|:--|
| `text-stroke-paint-order` | close | f32 sums of advances added in another order (`50.000122` vs `50.00006`) |
| `content-page-counters` | close | takumi stacks pages at the exact height but breaks at the height truncated to 1/64 px; content after a sliced box is 0.0073 px higher in bm-render |
| `report-links-outline`, `report-tagged-ua1`, `report-tagged-a2a` | close | outline destination of a heading on page 2 0.005 pt off (same cause as `content-page-counters`); the link / decoration edges are identical now |
| `at-page-first-left-right` | close | pages of different widths now laid out at their own width (was 1944 / 1734 ops); numbers within 0.01 |
| `svg-filters-masks-and-patterns` | close | numbers within 0.01 (was a raster fallback) |
| `color-glyph-text-shadow` | differ | only a form `/BBox` (124.51 vs 124.546): takumi measures it on tiny-skia's stroked outline |
| `inline-span-background-image` | differ | inline-span background extents: 3 gradient fragments vs 2 |
| `inline-span-background-clip-text-nested` | differ | the glyphs of a nested span inside the outer span's text mask sit 41/64 px further left in takumi; the visible text is identical |
| `background-clip-text-reach` | differ | 1723 / 1102 ops: how far the clip-text mask reaches past the box |
| `svg-singular-gradient-transform` | differ | `gradientTransform="scale(0)"`: a degenerate pattern matrix written differently, nothing visible |
| `paged-transforms`, `paged-rotated-text` | differ | takumi slices a rotated box cut by a page boundary per fragment; bm-render paints it whole in its first page's pass |
| `paged-monolithic-overflow`, `paged-clipped-overflow` | differ | layout identical; marked-content regions and clip details at the page boundary |
| `list-marker-pagination` | differ | deliberate: the marker of a split item stays on its first line (Chrome); takumi moves it to the last fragment |

## JS API surface

| Feature (takumi-pdf-js 0.20.0) | Status | Notes / evidence |
|:--|:--|:--|
| `PdfRenderer` class: `registerFont`, `unregisterFont({ name })`, `render`, `renderSync`, `measure`, `prepare` | ported+equivalent | probes `api.*`; `unregisterFont` takes takumi's `{ name }` |
| module functions `render`, `measure`, `prepare` | ported+equivalent | `js/pdf-api.mjs` |
| Source kinds: HTML string, node tree, `Prepared` | ported+equivalent | `api.input.*` |
| JSX / React element as document and as band | ported+differs | converted to HTML; components run once without a React dispatcher, so hooks other than plain reads do not work |
| `{ json }` source | extension | bm-render's node-tree source; takumi-pdf has no such kind (`api.input.kinds` keeps failing on purpose) |
| `fonts` option (bytes, URL, loader, promise) | ported+equivalent | the PDF builds bundle takumi-pdf's last-resort Geist (Latin subset; no Vietnamese tone marks) |
| `images` option | ported+equivalent | data that is no image now fails the render, as takumi's eager decode |
| `css`, `stylesheets`, `<style>` pooled across document and bands | ported+equivalent | `bands.styles` |
| `cssVariables` | extension | declared in takumi-pdf's d.ts but ignored by its Rust options; bm-render applies it (`api.css`) |
| `fontFamilies` | ported+equivalent | |
| `lang` (validated and canonicalised like `Lang::parse`) | ported+equivalent | |
| `signal` (render and prepare; `measure` ignores it as takumi) | ported+equivalent | `api.signal` |
| `prepare` | ported+differs | `prepare.*` (pinned `ff9a5d4`, mocked fetch, wasm and native): the engine's cascade-only needs pass (document and bands) finds the images, the `@font-face` files and the `fonts` subsets font fallback reaches (the element's families, then `fontFamilies`, faces already registered first, CSS weight / style matching; a subset that lacks a glyph its `unicodeRange` claims moves the character to the next family at the next read), each loaded once; a failed `@font-face` file moves its rule to the next `src` (`failedFontFiles`); a prepared document fetches nothing again. Fetch policy as takumi helpers `fetchOk`: 30 s default timeout, three attempts on 408 / 429 / 5xx or a network error (a `Retry-After` over 1 s ends them), with `allowUrl` every redirect hop checked, `fetchCache` shared. Differences: the error text of a failed fetch (`prepare.fetch.error-message`); an aborted `prepare` rejects even while a custom `fetch` that ignores `init.signal` never settles (takumi waits for it forever, `prepare.signal.hung-fetch`) |
| `uncoveredText: error / placeholder / blank` | ported+equivalent | with no font registered the bundled Geist draws, as in takumi-pdf |
| `backgroundColor` | ported+equivalent | first component only, transparent painted, `currentColor` rejected |
| Error messages | ported+differs | same text with a `bm-render: ` prefix (`file.error-prefix`, `page.error-prefix`); serde type errors only need to reject (wording differs) |
| Option validation of wrong types / NaN | ported+differs | all rejected except a NaN `margin`, which `JSON.stringify` turns into `null` (default margin) where takumi errors (`page.margin.nan`) |
| Huge sizes (750 000 000 pt page, 100 000 px viewport) | ported+differs | takumi renders them; bm-render rejects pages beyond its limits (`api.size.invalid`) |

## Page model, pagination, bands and counters

| Feature | Status | Notes / evidence |
|:--|:--|:--|
| `size` names, dimensions, CSS strings, `landscape` | ported+equivalent | `page.size.*` |
| `margin` numbers / `auto` / per side; `auto` margins around bands | ported+equivalent | `page.margin.*` |
| `viewport` mode (single page), exclusivity with paged options | ported+equivalent | `page.viewport.*`; `header: false` next to `viewport` renders, as takumi-pdf-js drops it |
| Viewports above 16384 px | ported+equivalent | PDF frames have no pixel-canvas limit |
| `pageRanges` | ported+equivalent | `api.pageRanges` |
| Page limit (20 000 pages) with takumi's message | ported+equivalent | `page.limit.too-many-pages` |
| `@page` `size` / `margin` | ported+equivalent | |
| `@page :first`, `:left`, `:right` (same width) | ported+equivalent | |
| `@page :first` / `:left` / `:right` of **another width** | ported+equivalent | was missing; `src/pdf/paged.zig` `laySegments` lays each run of same-width pages out at its own width, a paragraph broken across the change is cut at the same glyph and re-wraps; golden `at-page-first-left-right` close (1734/1734 ops, structure identical) |
| Named pages (`page` property, `@page name`, `name:first`) | ported+equivalent | breaks between blocks, flex items and table rows |
| Named pages of **another width** | ported+equivalent | was missing; now laid out at their own width, structure tree identical; golden `named-pages` identical: the last page of a width run also paints what the next run's first page reaches up into it (the collapsed borders above a table starting that page, `paintUnder`) |
| A page boundary inside a table row or a flex line across a width change | ported+differs | the continued row / line keeps the previous width |
| `@page` inside `@media` / `@layer` / `@supports`; `!important`, layer and specificity cascade | ported+equivalent | was missing; `src/css/sheet.zig`, `src/pdf/page_rules.zig` follow `PageRule::cascade` |
| `@page` lengths: any unit, `calc()` / `min()` / `max()` / `clamp()`, viewport units, `em` / `ex` / `ch` / `rem`, unitless px | ported+equivalent | was partial |
| `var()` in page descriptors, unresolved `var()` resets the descriptor | ported+equivalent | |
| `cssVariables` reaching the page context of a whole HTML document | ported+differs | bm-render applies them there too (`page.at-page.var.no-root-element`) |
| Page-margin boxes (`@top-center` ...) | n/a | takumi-pdf skips them too; bm-render parses and skips |
| Header / footer bands (HTML, nodes, JSX, `true` / numbers / objects as text, `false`) | ported+equivalent | `bands.*` |
| Band viewport units (the whole page) | ported+equivalent | |
| `pages` rules (`first` / `last` / `odd` / `even` overrides) | ported+equivalent | |
| Bands on pages of another width | ported+equivalent | laid out at that page's width |
| `PageNumber`, `TotalPages`, `TargetPageNumber` (class hooks and helpers) | ported+equivalent | `counters.*` |
| CSS counters in generated content (`counter()`, `counters()`, `counter-reset/increment/set`, `counter(page)`, `target-counter()`) | ported+equivalent | was missing; `src/pdf/css_counters.zig` (takumi-core `layout/counters.rs`), PDF frames only |
| A page counter inside a box moved by a transform | ported+differs | shows the page of the box's layout position (`counters.flow`) |
| Forced breaks, `break-inside: avoid`, orphans / widows, margins truncated at breaks | ported+equivalent | goldens `stream-*`, `content-*` |
| A forced break through an empty box (the next margin kept), `break-*` on `display: contents` | ported+equivalent | was differing (`tagging.paged.forced-breaks`) |
| Tailwind `break-before-*` / `break-after-*` / `break-inside-*` utilities | extension | takumi has no such utilities; bm-render keeps them as Tailwind defines them (`pagination.break.tailwind`) |
| Monolithic content taller than a page (overflow carried only through the box it ends, no extra page for overflow) | ported+equivalent | was differing; `src/layout/fragment.zig` `overflowStays`, `extentOf` |
| An inline-block taller than a page | ported+differs | takumi paints none of its text on later pages (looks like a takumi bug) |
| `box-decoration-break: clone` / `slice` of blocks | ported+equivalent | golden `paged-clone-decorations` identical; slice with border radius has a bbox difference |
| `box-decoration-break` of inline boxes reaching the next page by their border | ported+differs | |
| Tables: repeated `thead` / `tfoot`, row splitting, rowspan, cell re-alignment at a cut row | ported+equivalent | was differing |
| Table captions across pages | ported+differs | takumi drops caption lines on page 1 (looks like a takumi bug) |
| Collapsed table borders per fragment | ported+differs | repeated header/footer borders replay at their fragment `dy`, and rows cut by a page window paint their winning block-start/end edges; the block-start edge of a row a page break moved to the next page is painted on that page only, as Chromium does (takumi also paints its upper half at the end of the page before, a second rule under the last row when that row stops short of the page end: his-print Mps000338, `pagination.table.borders`); when the break falls between two row groups, the group above keeps the shared edge under its last row and the group below paints it again at its first row on the next page, as Chromium does (it was missing there); repeated-header borders rasterize equivalently within 1 CSS px |
| Flex rows across pages (align-items, perfect breaks) | ported+equivalent | an item whose margin overflows the page: takumi keeps it on the page (its own test says the opposite) |
| Grid rows across pages | ported+differs | basic rows, forced breaks, and aligned items resuming from an empty first fragment pass (`pagination.grid`, `pagination.continuation.grid-aligned-*`); arbitrary spanning-row / track continuation remains incomplete (`docs/PDF_FRAGMENT_DESIGN.md`) |
| Floats across pages | ported+differs | whole floats deferred to a later page trigger full layout retries so following lines re-flow; tested nested / RTL / variable page-size cases and split-float extents pass (`pagination.float.*`). Split floats still lack a general page-local exclusion model, especially for arbitrary continuations across width runs (`docs/PDF_FRAGMENT_DESIGN.md`) |
| Absolute / fixed boxes across pages | ported+equivalent | an absolute box without a positioned ancestor uses the first page area |
| Content transformed / relatively moved past the last page (extra pages) | ported+equivalent | goldens `paged-transform-past-the-last-page`, `paged-translated-text-*` identical |
| Rotated / skewed boxes cut by a page boundary | ported+equivalent | goldens `paged-transforms` (194 operators) and `paged-rotated-text` (203 operators) compare CLOSE with matching page counts and interchange trees; nested non-translation transforms remain a follow-up case |
| List markers of an item split across pages | ported+differs | deliberate: the marker stays on the item's first line (Chrome); takumi puts it on the first line of the last fragment |
| Overflow clips across pages | ported+equivalent | golden `paged-overflow-clip-stitched` identical |
| Marked-content regions of boxes cut by a page boundary | ported+differs | bm-render opens an extra empty region on the neighbouring page in some cases (`tagging.paged.*`); no single rule found that matches both these probes and the goldens |
| Tall translucent images crossing page boundaries | ported+equivalent | fixed duplicate draws from adjacent fragment passes; native and WASM regression probe checks one image draw per intersecting page, and a 4-page alpha raster matches Takumi pixel-for-pixel |
| Long documents: linear time and bounded memory | ported+differs | time per page flat (3.1 ms/page at 100 and 500 pages, wasm), files 0.81-0.87x takumi's; engine memory 260 MiB at 500 pages on wasm vs 76 MiB for takumi-pdf (layout passes and page drawing are freed now; the laid-out document itself remains) |

## Painting

| Feature | Status | Notes / evidence |
|:--|:--|:--|
| Backgrounds, gradients (linear / radial / conic, repeating), borders, radii, box shadows | ported+equivalent | goldens; `paint.*` |
| Gradients with an interpolation space (`in oklch`, `in oklab`, `in hsl longer`, `in srgb-linear`) | ported+differs | bm-render samples in the space asked for; takumi-pdf 0.20.0 writes sRGB stops and ignores the space |
| `background-clip: border-area` (dotted / dashed / double borders) | ported+equivalent | was differing; golden `background-clip-border-area-gaps` identical |
| `box-shadow` without a colour | ported+differs | bm-render uses `currentColor` (CSS); takumi makes it transparent |
| Outlines of block boxes | ported+equivalent | |
| Outlines of inline elements (one or several lines) | ported+differs | was missing; takumi's `OutlineIsland` ported, golden `inline-outlines` identical; a multi-line island in a non-solid style or with radii is drawn solid and square |
| Opacity, blend modes, isolation, filters (CSS functions, `drop-shadow`) | ported+equivalent | |
| `filter: url(#missing) ...` chains | ported+differs | CSS ignores the whole chain (bm-render); takumi drops the missing part |
| A JPEG under a filter | ported+differs | takumi fails to decode it and errors; bm-render renders |
| `clip-path` basic shapes, `path()`, `url()` | ported+equivalent | |
| `clip-path` `ellipse()` without radii, keyword positions, `inset() round a / b`, geometry boxes | extension | takumi's parser rejects these and drops the clip; bm-render follows CSS |
| `mask-image` / `mask-*` layers, composite, `mask-type` | ported+equivalent | |
| `mask-mode`, `mask-clip`, `mask-origin` | extension | takumi does not support them |
| `overflow: hidden / clip` | ported+equivalent | an absolute / fixed box escapes the clips between it and its containing block (was a bug) |
| `overflow: scroll / auto` clipping | extension | takumi only knows visible / clip / hidden and does not clip |
| Stacking: z-index layers, negative z-index layer, positioned boxes, CSS 2.1 appendix E paint phases | ported+equivalent | negative layer was a bug |
| `position: sticky` | ported+differs | bm-render paints it as positioned; takumi as static |
| Transforms (2D, 3D flattened), `transform-origin` | ported+equivalent | decorations snap in the transformed space (golden `outline-under-transform` identical) |
| `rotate: z 30deg` | extension | `rotate: z` is not parsed by takumi |
| `offset-path` (`path()`, `ray()` with size / `contain` / `at`, basic shapes, a coordinate box; `offset-distance` / `-rotate` / `-anchor` / `-position`) | ported+equivalent | the pinned syntax only (`url()` is not a motion path in either). The box, its text and its link take one transform (`paint.motion.*`). The reference box is the viewport; paged output has no viewport height (takumi-pdf's unbounded column), so the element's own height stands in (`paint.motion.paged-*`). A rotated box whose fragment starts on a later page still opens an empty marked-content region on the earlier page, and a transformed box continued on the next page paints after its parent's border fragment there: both come from transforms across pages in general (`transform: rotate()` does the same), not from motion paths |
| Relative colour syntax (`rgb(from ...)`, `hsl` / `hwb` / `lab` / `lch` / `oklab` / `oklch`) | ported+equivalent | keyword channels, numbers, percentages, hue units, `none`, `alpha`, nested origins (`paint.color-relative.*`). As in takumi a `calc()` channel, `color(from ...)` and a `currentColor` origin are invalid and drop the declaration. A relative colour is not a legacy colour: a gradient with one interpolates in Oklab (takumi-core does the same; takumi-pdf writes every gradient in sRGB, the `linear-in-*` difference above) |
| Form controls (`input` value / placeholder / password, `textarea`, `select`) | ported+differs | `text.form.*` (pinned `ff9a5d4`): value, masked password (never its characters), sanitised types, textarea lines / rows / cols, select options laid out as content (takumi has no select presentation; hidden options show in both engines); same draw list, text and raster. Placeholders are painted by neither engine. Differences: a block-level / flex text field keeps its intrinsic width in bm-render (Blink `AutoWidthShouldFitContent`), takumi stretches it; a textarea taller than a page loses its lines (or loops to 20 000 pages) in takumi, bm-render slices it with each line once; empty editors and atomic inlines with `overflow` write their clip once / twice (no visible difference) |
| `::before` / `::after` content | ported+equivalent | an empty pseudo block opens an empty `P` region in bm-render (`paint.pseudo.before-after`) |
| `content: url()` | ported+differs | `generated.url.*` (pinned `ff9a5d4`): PNG / JPEG / SVG in `::before` / `::after`, in spans, wrapped lines, next to counters / `attr()`, missing or undecodable images (nothing drawn, as takumi), on every page, fetched by `prepare`: same draw list, text and raster. Generated URL items in mixed `::before` content stay inline with surrounding text; `paint.pseudo.content-url-mixed` checks that following pseudo text does not gain an extra block line. Takumi's box split differs from browser inline flow (it makes the URL item a block: inside an `inline-block` pseudo the text before and after it lands on separate lines and in separate `P` elements, `tagging.generated.mixed-image`; an inline image alone gets a `P` of its own, `generated.url.tagged.before`). For the same reason a generated image in a `display: block` / `inline-block` / absolutely positioned pseudo keeps its natural size in bm-render (browsers); takumi stretches it to the pseudo's width, capped at its height (an 8 px PNG becomes 180 px wide in a block `::before`, `generated.url.block*`, `generated.url.pages.*`) |
| List markers (counter styles, symbols, inside / outside, `start`, `reversed`, `value`, `Lbl`) | ported+equivalent | |
| `list-style-image` | ported+differs | `lists.image.*` (pinned `ff9a5d4`): PNG / JPEG / SVG markers inside and outside, RTL, nested, wrapped and split items, every page, `ol` (the image replaces the number), `::marker` content winning, a missing or undecodable image leaving the counter style (never both): same draw list, text and raster. An outside SVG without a natural width draws nothing and leaves the line where it is, as takumi. Differences: an outside image marker is the content of its item's `Lbl` (takumi tags the image as a `P` of the `LBody` and leaves two empty sequences in the `Lbl`, `lists.image.tagged.outside`); an inside one stays in its line's `P` (takumi: a `P` of its own). Not ported: an item that starts with a box of its own formatting context (flex / grid / table child, block image) loses its outside marker, text or image; takumi hangs it beside that child's first baseline or the next line's (Blink `PositionListMarkerBesideChild`, `lists.image.host-*`) |

## Text and fonts

| Feature | Status | Notes / evidence |
|:--|:--|:--|
| Font embedding as CID Type0 (TrueType / CFF / CFF2, variable instances), subsetting, ToUnicode, `/W` | ported+equivalent | font programs are not byte-identical (different subsetter) but draw the same glyphs; 71/136 goldens byte-identical fonts |
| Glyph subset closure | ported+equivalent | composites pull their components, `.notdef` kept, same glyph count and program size (`fonts.subset.glyph-closure`). The two cases that used to differ are takumi defects, not closure: an nbsp-only paragraph at the top level of an HTML fragment loses its text and its line in takumi (U+00A0 read as collapsible white space: `<p>&nbsp;</p><p>x</p>` draws `x` a line higher), bm-render keeps it as browsers do (`fonts.subset.nbsp-paragraph`); a line that starts after a break with `@` before capitals draws Inter's raised `@.case` in bm-render as on an unbroken line (both engines raise it there), takumi the default `@`; `@.case` is a composite of the default `@`, hence one more glyph (`fonts.subset.line-start-alternate`) |
| TTC face selection with a family override; TTC `FontBBox` | ported+differs | takumi picks the last face and writes −220 as the descender bound |
| WOFF1 fonts | extension | takumi-pdf rejects them |
| WOFF2 | ported+equivalent | |
| Truncated / no-cmap fonts | ported+equivalent | registered as a family drawing nothing when the table directory reads (text falls back), as takumi; bytes that are no font: "Unsupported font format" |
| Fallback font | ported+equivalent | the PDF builds bundle the same last-resort Geist file as takumi-pdf (src/pdf/geist), tried after every registered family; `clearFonts()` goes back to it |
| Default-ignorable characters as invisible glyphs (ZWSP, ZWJ, marks, U+FEFF) | ported+equivalent | ToUnicode / ActualText like HarfBuzz |
| Control characters raising the uncovered-text error | ported+equivalent | was differing |
| Fill text, synthetic bold (`2 Tr` stroke) and oblique, `font-synthesis` | ported+equivalent | |
| `-webkit-text-stroke`, `paint-order` | ported+differs | bm-render follows the goldens (a takumi newer than 0.20.0): separate fill and stroke passes; 0.20.0 writes one `2 Tr` object and ignores `paint-order` (all `text.stroke.*` probes) |
| COLR v0 / v1 glyphs (Type3), bitmap glyphs (CBDT / sbix) | ported+equivalent | contour start as FreeType / skrifa, COLR v1 colour lines normalised |
| SVG-in-OpenType glyphs | ported+differs | drawn as their outline |
| Text shadows (per run, blurred, colour glyphs) | ported+equivalent | golden `color-glyph-text-shadow` differs only by a form BBox (124.51 vs 124.546) measured on tiny-skia's stroker |
| Decorations (underline / overline / line-through, styles, thickness incl. `from-font`, offset, skip-ink, propagation through inline boxes) | ported+equivalent | run ends at origin + exact advance (goldens `report-*` close) |
| `background-clip: text` (blocks and inline spans, decorations in the mask) | ported+differs | each background layer keeps its own clip; mixed `text,border-box` paints the box color and sends only the text layer through glyph coverage (`text.background-clip.border-box-and-text`); Takumi paints this case as a gradient box and omits the box color |
| `text-overflow: ellipsis`, `line-clamp` | ported+differs | `text.overflow-tail.*`: the marker takes the last kept item's colour (also in RTL lines), the block's font synthesis, and follows the content in paint / extraction order on RTL lines, as takumi. Differences: takumi drops the marker below the baseline after a taller span (bm keeps the baseline, Blink `PlaceEllipsisNextTo`); an RTL run inside an LTR line is truncated in logical order by bm-render, in visual order by takumi; takumi draws an underline per run (content, marker), bm one across both |
| Tabs, `pre-wrap` spaces, soft hyphen | ported+differs | `text.whitespace.*`: same glyphs, positions (raster identical), pdftotext and pdf.js text; takumi splits tabs / preserved spaces into runs of their own (TJ grouping only, not compared). The generated hyphen sits at the item's snapped width and `hyphens: none` ignores soft hyphens, as takumi. Differences: `tab-size: <length>` (takumi takes a space count only), the hyphen of a soft hyphen opening a span takes the preceding text's colour in bm-render |
| `unicode-bidi` (`embed`, `isolate`, `bidi-override`, `isolate-override`, `plaintext`) | ported+equivalent | `text.bidi-override.*`: nested spans, inherited direction, Arabic / emoji / combining / ligatures under an override; `plaintext` takes each paragraph's direction (alignment, reordering) from its first strong character, else left-to-right |
| Bidi, Arabic shaping, CJK, emoji | ported+equivalent | Arabic text extraction (`معٕا`): identical text from bm-render and takumi-pdf in pdftotext and pdf.js; the separate U+0655 item comes from the font's decomposition, not from either engine |
| Text extraction order (`text.order.*`) | ported+equivalent | |

## Images and SVG

| Feature | Status | Notes / evidence |
|:--|:--|:--|
| PNG passthrough (predictors, indexed, ICC) | ported+equivalent | was decoded and re-encoded; `src/pdf/png_krilla.zig` |
| PNG decode as krilla's png crate (gray stays DeviceGray, 16-bit kept, straight alpha, tRNS, interlace, CRC / EOF errors) | ported+equivalent | `images.png.*` (21) |
| PNG errors raised before the first IDAT | ported+differs | fall back to bm-render's decoder instead of takumi's error |
| JPEG passthrough, CMYK / YCCK (`/Decode`), Adobe transform 0, ICC (`ICCBased`) | ported+equivalent | `images.jpeg.*` |
| WebP (first frame, alpha only when declared), GIF (draws nothing), APNG (decoded) | ported+equivalent | WebP decode error messages are generic |
| PDF/A gray images | ported+differs | DeviceGray; takumi uses an ICC-based sGrey |
| Image dedup, resampling, `image-rendering`, object-fit / object-position snapping | ported+equivalent | |
| An `<img>` that is the only top-level element | ported+differs | stretched to the viewport by bm-render (no `<html>` / `<body>` wrapper around a fragment); takumi keeps its intrinsic size (`images.root-img.*`) |
| An `<img>` without a source | ported+differs | an empty marked-content region (`images.other-formats.*`) |
| SVG as vectors (`use`, `symbol`, nested `svg`, `switch`, `image`, markers, patterns, gradient chains, `paint-order`, non-scaling stroke, clip paths, masks, blend, isolation, colour filter) | ported+equivalent | was a vector subset with raster fallback; `src/pdf/emit_svg.zig` ports SvgLayout / SvgPainter |
| SVG filters | ported+equivalent | takumi-pdf's build does not lay them out: a filtered element draws unfiltered, in both |
| SVG text | ported+differs | per-character x / y / dx / dy / rotate lists inherited through `tspan` (a list with an entry that does not parse is dropped), anchors over the advances, `letter-spacing` / `word-spacing`, `dominant-baseline` / `alignment-baseline` / `baseline-shift`, rotation about the cluster origin, kerning across spans, `font-style` (synthetic oblique), `font-stretch`, `font-variant: small-caps`, `textPath` (`href`, `startOffset`, anchors, path direction and transform), decorations with their declaring element's paint, `tspan` opacity groups (`images.svg-text*`, `images.svg-fixture.*`). Differs: `dx` / `dy` in a right-to-left chunk accumulate in logical order (SVG 2 / Blink); takumi adds them in visual order. Open: synthetic bold and COLR layers of SVG glyphs (`svg_text_glyphs`), and letter-spacing at a space inside cursive (Arabic) text, which the shared text engine leaves out |
| Page CSS inside an inline `<svg>` | ported+equivalent | page rules and the SVG's own sheets in one cascade, specificity, `!important`, structural / attribute selectors, nested `svg`; the root inherits the SVG properties of its HTML ancestors (rules and `style` attributes), their font and custom properties; `var()` in rules, `style` and presentation attributes; nothing leaks into the HTML, and an `<img>` SVG stays isolated (`images.svg-inline-css.*`). A standalone SVG's own `<style>` still uses the minimal SVG selector set (`svg_style_selectors`: pseudo-classes and sibling combinators are dropped) |
| `gradientTransform="scale(0)"` | ported+differs | degenerate matrix written differently, nothing visible (golden `svg-singular-gradient-transform`) |

## File layer

| Feature | Status | Notes / evidence |
|:--|:--|:--|
| Object layout, xref, object streams, ids | ported+equivalent | object layout identical in 132/136 goldens |
| Compression | ported+differs | same data, a different Flate encoder: stream sizes differ (`file.streams.sizes`) |
| Info dictionary, XMP (dates, custom schemas, UA / A identification) | ported+equivalent | `metadata.*` |
| Outline from headings (`outline: true`) | ported+equivalent | |
| Links (external, internal, `TargetPageNumber`), anchors, repeated table header links | ported+equivalent | annotations in tree order (was paint order) |
| Inline link rectangle in a padded block | ported+differs | `links.inline-rect-in-padded-block` checks tagged and untagged PDF bounds against Poppler's text bbox; bm-render covers the linked text, while takumi offsets the rectangle into the block padding |
| Tagged PDF: structure tree, roles, `Lbl`, tables, figures with alt, artifacts, `ActualText` | ported+equivalent | `tagging.*` |
| Inline role elements (`b`, `strong`, `em`, `code` ...) ending the paragraph run | ported+equivalent | was missing (invoice `P` vs `P, P`) |
| Marked content of boxes straddling a page boundary | ported+equivalent | a box sliced by a page boundary ends at the page height truncated to 1/64 px (takumi's fragmentainer), so its fragment no longer opens an empty region on the next page (`links.outline.paged`, `tagging.paged.*`) |
| PDF/UA-1, PDF/UA-2 (incl. structure destinations in outline items, as takumi-pdf 0.20.0 writes them) | ported+equivalent | |
| PDF/A-2a/2b/2u, 3a/3b/3u, 4, 4f validation (krilla rules incl. string / name / nesting limits) | ported+equivalent | `conformance.*` (100 probes) |
| Attachments (PDF/A-3 / 4f associated files) | ported+equivalent | compressed size differs (encoder) |
| Forms (AcroForm) | n/a | takumi-pdf writes none |
| Encryption | n/a | takumi-pdf has none |
| Linearization | n/a | neither engine linearizes |

## krilla validation errors

bm-render raises the krilla validation errors takumi-pdf can reach: fonts (missing / glyph 0 / invalid
mapping, deduplicated by value as krilla does), missing language / title / alt text, heading titles,
annotation alt text, `TooLongString`, `TooLongName`, `TooManyIndirectObjects`, `TooHighQNestingLevel` (PDF/A-2
and A-3), dates, attachment media types. Evidence: `conformance.*` and `metadata.*` probes, all passing; the
count in the message (`validation failed with N errors`) matches.

## Not applicable

Forms, encryption, digital signatures, linearization and page-margin boxes are not features of takumi-pdf
0.20.0, so there is nothing to port. PDF/A-1 is not offered by either engine.

## Not ported, and why

| Item | Why |
|:--|:--|
| Outside list marker beside a child with its own formatting context | an item that starts with a flex / grid / table box or a block image drops its outside marker; Blink and takumi place it beside that child's first baseline (or the next line's), which needs the marker positioned after the child's layout (`lists.image.host-*`) |
| Visual-order `dx` / `dy` in right-to-left SVG text | takumi accumulates the shifts over clusters in visual order; SVG 2 and Blink's `SvgTextLayoutAlgorithm` accumulate them per addressable character in logical order, which bm-render keeps |
| takumi-pdf 0.20.0 single-pass `2 Tr` stroked text | the goldens (newer takumi) draw separate passes; bm-render follows the goldens |
| Gradients interpolated in sRGB regardless of the space asked for, dropped clip-paths / masks / overflow modes takumi cannot parse | takumi limitations; bm-render follows CSS |
| Rotated boxes sliced per page fragment; lines re-flowed beside a float moved to another page | bm-render paginates one finished layout (src/layout/fragment.zig); both need a layout per fragment |
| Memory of the laid-out document on long documents (~0.48 MiB / page on wasm vs ~0.15 MiB for takumi-pdf) | takumi lays out and releases a page at a time; bm-render keeps the whole laid-out document (computed styles, shaped paragraphs, layout nodes) until the file is written. Layout passes and page drawing are freed already |

## How to re-run the evidence

```sh
npm run build:pdf                                  # js/bm_render.pdf.wasm
TAKUMI_PDF_REF=bench/pdf node scripts/pdf-audit/run.mjs --quiet   # probes vs takumi-pdf 0.20.0 (npm run pdf:setup first)
node scripts/pdf-compare.mjs                       # the 136 goldens (needs ref/takumi)
npm run test:pdf                                   # PDF tests, wasm and native
node scripts/pdf-scaling.mjs --takumi              # 100 vs 500 pages: time, bytes and memory per page
zig build test -Dpdf=true                          # unit tests
```

`BM_RENDER_BACKEND=wasm|native` picks the backend; both give byte-identical files (`node bench/native-identity.mjs`).
