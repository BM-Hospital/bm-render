# CSS and feature support

This page lists bm-render features and the smallest profile that includes them. **Supported** means available; **partial** has the stated constraints; **no** means unavailable. For PDF output, see [CSS in PDF](../pdf/css-support.md).

- [Conventions](#conventions)
- [Layout](#layout)
- [Box model and sizing](#box-model-and-sizing)
- [Backgrounds and gradients](#backgrounds-and-gradients)
- [Borders and outline](#borders-and-outline)
- [Shadows and effects](#shadows-and-effects)
- [Transforms](#transforms)
- [Text](#text)
- [Fonts](#fonts)
- [Colours](#colours)
- [Values, units, custom properties](#values-units-custom-properties)
- [Stylesheets and selectors](#stylesheets-and-selectors)
- [Tailwind](#tailwind)
- [HTML input](#html-input)
- [Animations](#animations)
- [Images and SVG](#images-and-svg)
- [Complex scripts, bidi, emoji](#complex-scripts-bidi-emoji)
- [Paged media (`pdf` profile)](#paged-media-pdf-profile)
- [Known gaps](#known-gaps)
- [Appendix: supported property names](#appendix-supported-property-names)

## Conventions

- Inline styles use camelCase keys (`backgroundColor`); stylesheets, HTML `style=""` attributes and
  Tailwind use normal CSS syntax. Every property accepts `inherit`, `initial`, `unset`, `revert`,
  `var()` and math functions.
- **Defaults:** `display: inline`, `box-sizing: border-box`, transparent canvas. The root and flex/grid items are blockified.
- Layout runs in device pixels with 1/64 px precision (Blink `LayoutUnit`), and pixel snapping happens
  at paint time.

## Layout

| Feature | Min. profile | Status |
|:--|:--|:--|
| Block layout, margin collapsing, `flow-root` | core | supported |
| Inline formatting (text runs, `inline`, `inline-block`, `inline-flex`, `inline-grid`, `vertical-align`) | core | supported ; see [known gaps](#known-gaps) |
| Flexbox (direction, wrap, grow / shrink / basis, `gap`, alignment incl. `safe`, `order`, `-webkit-box`) | core | supported  |
| `direction: rtl` / `dir="rtl"` on boxes: flex rows, grid columns, table columns and block alignment are mirrored | core | supported; the text inside is laid out right to left only on `full` (bidi); `justify-self: left / right` is not mirrored |
| Grid: tracks, `repeat()` incl. `auto-fill` / `auto-fit`, `fr`, `minmax()`, auto-placement, spans | core | supported (4/4) |
| Grid: named lines, `grid-template-areas`, `grid-area` | core | supported (3/3) |
| `position: relative / absolute / fixed`, `inset`, `z-index` | core | supported (3/3); `fixed` is positioned against the canvas |
| `position: sticky` | core | parsed, behaves like `relative` (no scrolling) |
| `aspect-ratio`, `min-*` / `max-*`, `fit-content` / `min-content` / `max-content`, logical sizes | core | supported  |
| `overflow: hidden / clip` (incl. rounded clipping) | core | supported |
| Tables (`display: table*`, auto / fixed layout, `colspan` / `rowspan` via HTML, `border-collapse`, `border-spacing`, captions, `empty-cells`) | standard | supported  |
| Floats (`float`, `clear`) | standard (`floats` flag; also `full`) | supported; 138/138 layout oracle cases; text flows around floats  |
| `display: contents` | core | supported |
| `display: list-item` | core | laid out as a block; no list marker in raster / SVG output (the [`pdf` profile](../pdf/index.md) paints markers in PDF output) |
| Writing modes (`writing-mode: vertical-rl / vertical-lr / sideways-rl`, `text-orientation`, orthogonal flows, logical properties through the writing mode) | core | supported for block, flex and grid content with text, spans and images (compared with Chrome by `npm run test:writing-mode`); tables, absolutely / fixed positioned boxes, and `sideways-lr` are not (`text-combine-upright: all` is): see [Typography](./typography.md#vertical-text) |

On `core`, `display: table*` lays out like `block` and `float` is ignored (no error).

## Box model and sizing

| Feature | Min. profile | Status |
|:--|:--|:--|
| `width` / `height` / `min-*` / `max-*` (px, %, em, rem, vw, vh, `auto`, `fit-content`, ...) | core | supported |
| `margin` (incl. `auto`), `padding`, logical forms (`marginInline`, `paddingBlockStart`, ...) | core | supported |
| `box-sizing: border-box` (default) / `content-box` | core | supported |
| `visibility: hidden / collapse` | core | supported |
| `opacity` | core | supported (4/4) |

## Backgrounds and gradients

| Feature | Min. profile | Status |
|:--|:--|:--|
| `background-color`, `background` shorthand, multiple layers | core | supported |
| `linear-gradient`, `radial-gradient`, `conic-gradient`, `repeating-*` | core | supported  |
| `background-image: url(...)`, `background-size` / `-position` / `-repeat` (incl. `space`, `round`) / `-origin` / `-clip` | core | supported  |
| `background-clip: text` | core | supported |
| Gradient interpolation space (`linear-gradient(in oklab, ...)`) | standard | supported on standard/full; ignored on core |
| `background-blend-mode` | standard | supported |

## Borders and outline

| Feature | Min. profile | Status |
|:--|:--|:--|
| `border` widths / colours, all styles: `solid`, `dashed`, `dotted`, `double`, `groove`, `ridge`, `inset`, `outset` | core | supported (dashes on rounded corners can be ~0.1 px out of phase) |
| `border-radius` (elliptical, per corner, percentages, logical corners) | core | supported (4/4) |
| `outline`, `outline-offset` (px) | core | supported; `outline-offset` in % is not supported |

## Shadows and effects

| Feature | Min. profile | Status |
|:--|:--|:--|
| `box-shadow` (outer, inset, spread, multiple) | core | supported (4/4) |
| `text-shadow` | core | supported |
| `filter`: `blur()`, `brightness()`, `contrast()`, `grayscale()`, `hue-rotate()`, `invert()`, `opacity()`, `saturate()`, `sepia()`, `drop-shadow()` | core | supported; `filter: url(...)` is not supported |
| `backdrop-filter` | standard | supported |
| `mix-blend-mode` (16 modes + `plus-lighter`, `plus-darker`), `isolation` | standard | supported |
| `clip-path`: `inset()`, `circle()`, `ellipse()`, `polygon()` with a geometry box | standard | supported |
| `clip-path: path()` | standard (needs SVG) | supported; `clip-path: url(#id)` is not |
| `mask-image` / `mask-*` / `-webkit-mask-*` (gradients and images, `mask-mode`, `mask-type`) | standard | supported; `mask-composite` is ignored |

On `core` the effect properties of this table that need `standard` are accepted and ignored.

## Transforms

| Feature | Min. profile | Status |
|:--|:--|:--|
| 2D `transform` functions (`translate*`, `rotate`, `scale*`, `skew*`, `matrix`), `transform-origin` | core | supported (3/3) |
| Individual `translate`, `rotate`, `scale` properties | core | supported |
| 3D transforms (`rotateX`, `matrix3d`, `perspective()`) | — | not supported; inline transforms with a 3D function throw |

## Text

| Feature | Min. profile | Status |
|:--|:--|:--|
| Line breaking (UAX #14), `white-space` (all modes), `word-break`, `overflow-wrap`, `tab-size` | core | supported |
| `text-align` (incl. `justify`), `line-height`, `letter-spacing`, `word-spacing` | core | supported |
| `text-transform` | core | supported: full Unicode case mapping (`ß` → `SS`, final sigma, ligatures, titlecase digraphs); not done: `lang`-tailored casing (Turkish / Azeri, Greek, Lithuanian), `full-width`, `full-size-kana` |
| `text-indent` (lengths, %, negative, `each-line`, `hanging`, RTL) | core | indents only the block’s first line |
| `text-overflow: ellipsis` / `clip` / `"<string>"`, `line-clamp` / `-webkit-line-clamp` (incl. `<n> "<string>"`, `none`, `no-ellipsis`) | core | supported; a string marker is shaped with the element's font and fallback and mirrored in RTL (an empty string truncates without a marker); `overflow` clips the element's own glyphs |
| `text-decoration` (line, style incl. `wavy`, colour, thickness), `text-underline-offset` / `-position`, `text-decoration-skip-ink` | core | supported |
| `-webkit-text-stroke`, `-webkit-text-fill-color` | core | supported (stroke may differ by 1 level); `paint-order` is parsed but the stroke is always painted over the fill |
| Inline boxes with background / border / padding, `box-decoration-break` | core | supported; horizontal padding / border / margin of a span push the text (first / last fragment edges, `box-decoration-break: clone`) |
| `text-wrap: balance` / `pretty` | standard | supported |
| Synthetic bold / italic when the face is missing | core | supported |
| `font-feature-settings`, `font-variant-*`, `font-kerning`, ligatures (GSUB 1–8, GPOS 1–9) | core | supported |
| `font-variant-caps` (`small-caps`, `all-small-caps`, `petite-caps`, `all-petite-caps`, `unicase`, `titling-caps`), `font-synthesis-small-caps` | core | the font's OpenType features when it has them, otherwise synthesised (uppercase at 70 % of the font size); petite caps and unicase fall back to small caps; `font-synthesis-small-caps: none` turns synthesis off |
| Inline boxes: percentage `margin` / `padding`, `position: relative` | core | percentages resolve against the containing block; relative offsets shift the inline box |
| `hyphens`, `line-break`, `text-align-last` | — | parsed, no effect in 0.1.0 |

## Fonts

| Feature | Min. profile | Status |
|:--|:--|:--|
| TrueType (`glyf`), collections (`.ttc`) | core | supported |
| CFF / CFF2 (`.otf`) | standard | widths within 1/64 px |
| WOFF / WOFF2 | standard (core: [add-on](../profiles-and-size.md#the-woff-add-on)) | supported |
| Variable fonts (`fvar`, `avar`, `gvar`, `HVAR`, `MVAR`), `font-variation-settings`, `font-optical-sizing` | standard | 1 400 width comparisons within 1/64 px; on core only the default instance is drawn |
| Colour fonts: COLR v0 / v1 | full | color on full; core/standard draw plain outlines |
| Bitmap colour fonts: CBDT, sbix | standard | drawn in colour on `standard` and `full`; `core` draws nothing for a bitmap-only font |
| `@font-face` in stylesheets | — | not loaded: register fonts with `registerFont` / `fonts` |

## Colours

| Feature | Min. profile | Status |
|:--|:--|:--|
| Named colours, `#rgb[a]`, `#rrggbb[aa]`, `rgb()` / `rgba()`, `hsl()` / `hsla()`, `hwb()`, `currentColor`, `transparent` | core | supported |
| `lab()`, `lch()`, `oklab()`, `oklch()`, `color()`, `color-mix()`, `light-dark()` | standard | 495/495 colours supported at 8 bits. On core these values are invalid: in an inline style they throw |
| Relative colour syntax (`rgb(from red r g b / 50%)`) | — | no (invalid value) |

## Values, units, custom properties

| Feature | Min. profile | Status |
|:--|:--|:--|
| `px`, `%`, `em`, `rem`, `vw`, `vh`, `vmin`, `vmax`, `pt`, `pc`, `in`, `cm`, `mm`, `Q`, `ch`, `ex`, `lh`, `rlh`, `cq*` | core | supported (DPR semantics: `vw`/`vh` refer to output pixels) |
| `calc()`, `min()`, `max()`, `clamp()` and other math functions | core | supported |
| Custom properties (`--x`) and `var()` with fallbacks, in inline styles | core | supported |
| `!important` | core | supported |

## Stylesheets and selectors

Pass stylesheets through `css` or a `<style>` block in HTML. Requires `standard` or `full`.

- **Selectors**: type, universal, class, id, attribute (all 7 operators, `i` / `s` flags); combinators
  descendant, `>`, `+`, `~`; selector lists; `:root`, `:empty`, `:first-child`, `:last-child`,
  `:only-child`, `:first-of-type`, `:last-of-type`, `:only-of-type`, `:nth-child(An+B [of S])`,
  `:nth-last-child()`, `:nth-of-type()`, `:nth-last-of-type()`, `:not()`, `:is()`, `:where()`, `:has()`,
  `:lang()`, `:dir()`, `:scope`, form states (`:checked`, `:disabled`, ...). Pseudo-elements `::before` /
  `::after` (with `content`, `attr()`).
- Dynamic pseudo-classes (`:hover`, `:focus`, `:visited`, ...) and other pseudo-elements (`::marker`,
  `::placeholder`, `::first-line`, ...) parse but never match.
- **At-rules**: `@media` (`width`, `height`, `aspect-ratio`, `resolution`, `orientation`, range syntax,
  `and` / `or` / `not`; evaluated against the canvas size in CSS px), `@supports`, `@layer`, CSS Nesting
  (`&`), `@keyframes`, `@theme` (Tailwind theme variables), `@import "tailwindcss"` (enables Tailwind
  Preflight). `@font-face` descriptors are read but fonts are not fetched. `@page`, `@property`,
  `@container`, `@scope`, `@apply`, `@counter-style` and other at-rules are ignored.
- Invalid declarations are dropped one by one (CSS error recovery); a stylesheet never makes the render
  throw.
- **Cascade order**: rules in named `@layer` blocks < Tailwind utilities from `tw` <
  unlayered stylesheet rules < inline `style`; for `!important` declarations the order reverses:
  unlayered < `tw` < named layers.
- Text nodes without a `tagName` are not elements for structural pseudo-classes and sibling combinators
  (`:first-child`, `:nth-child()`, `+`, `~`, ...). Empty or whitespace-only text nodes
  are dropped unless in-flow inline content precedes them (always in flex and grid containers).
- Not supported: `counter()` / `counters()` in `content`, list markers.

## Tailwind

`tw` supports the following Tailwind v4 utility groups; unsupported classes are ignored:

- **Utility families**: layout and display (`flex`, `grid`, `block`, `hidden`, `contents`, ...),
  position and inset, sizing (`w-*`, `h-*`, `size-*`, `min-*`, `max-*`, `aspect-*`), spacing (`m*-*`,
  `p*-*`, `gap-*`), flex and grid (`basis-*`, `grow`, `shrink`, `grid-cols-*`, `col-span-*`, `items-*`,
  `justify-*`, `self-*`, ...), typography (`text-*`, `font-*`, `leading-*`, `tracking-*`, `line-clamp-*`,
  `truncate`, `whitespace-*`, decoration utilities, `uppercase`, ...), backgrounds (`bg-*`, gradients
  with `from-*` / `via-*` / `to-*`, `bg-linear-*`, `bg-radial`, `bg-conic`), borders and radius
  (`border*`, `rounded*`, `outline*`), effects (`shadow-*`, `inset-shadow-*`, `text-shadow-*`,
  `opacity-*`, `mix-blend-*`, `bg-blend-*`, `mask-*`), filters and backdrop filters, transforms
  (`translate-*`, `rotate-*`, `scale-*`, `origin-*`), `object-*`, `overflow-*`, `list-*`.
- **Values**: the default theme (spacing scale, the full colour palette with `/opacity` modifiers,
  font sizes, radii, shadows, breakpoints), arbitrary values (`w-[37px]`, `bg-[#123456]`,
  underscores as spaces), `!important` prefix.
- **`@theme` variables feed the utilities**: colours (with `/opacity`), `--spacing` and `--spacing-*`,
  `--container-*`, `--radius-*`, `--text-*` (with its `--line-height` companion), `--font-*`,
  `--font-weight-*`, `--tracking-*`, `--leading-*`, `--aspect-*`, `--animate-*`, `--breakpoint-*`.
- **`animate-*`** (`animate-spin`, `-ping`, `-pulse`, `-bounce`, `-none`, `animate-[...]`, theme names)
  on the `full` profile, which has animations.
- **Variants**: breakpoints `sm` `md` `lg` `xl` `2xl` (min-width against the canvas width),
  structural `first` `last` `only` `odd` `even` `*-of-type` `empty` `not-*` `nth-*` and `[&:...]`,
  `before:` / `after:`.
- **Not supported **: `hover:`, `focus:`, `dark:`, `group-*:`, `peer-*:`, `max-*:`
  breakpoints; `z-*`, `order-*`, `skew-*`, `ring-*`, `space-x-*` / `space-y-*`, `divide-*`, `place-*`,
  `cursor-*`, `outline-2` alone, bare `backdrop-blur`, `mask-b-from-50%`; `var()` in arbitrary values
  (`bg-[var(--x)]`) and the `(--var)` shorthand; `[prop:value]` classes; the v3 name `bg-gradient-to-*`;
  the HTML `class` attribute (only `tw` is Tailwind). Unknown classes are skipped silently.
- `style` beats `tw`; `!`-prefixed utilities beat normal inline declarations.

## HTML input

Every string source is parsed as HTML. Requires `standard` or `full`.

- Tolerant tokenizer and tree builder (the same pragmatic subset of the WHATWG algorithm):
  implied end tags for `p`, `li`, `dt`/`dd`, `option`, table parts; implied `tbody`; void elements;
  character references (numeric + 338 named); fragment and document mode.
- `<style>` elements (with `media` attributes) are applied; `style=""` attributes; `class`, `id`, other
  attributes for selectors; `dir` and `lang`.
- Chromium's user-agent styles are applied as presets (`h1`, `p`, `b`, `ul`, `table`, ...).
- `<img src>` looks up the `images` option or uses a `data:` URL; inline `<svg>` elements are rendered
  as SVG images.
- `<script>`, `<template>` content, comments and `<head>` content are not rendered; nothing is executed
  or fetched.
- Not implemented (same gaps): adoption agency / formatting-element reconstruction, foster
  parenting, MathML, form controls as widgets.

## Animations

`tw` supports the following Tailwind v4 utility groups; unsupported classes are ignored:

On `standard` the `@keyframes` rules parse but animations are not applied; on `core` the `animation`
property is ignored.

## Images and SVG

| Feature | Min. profile | Status |
|:--|:--|:--|
| PNG, JPEG (baseline and progressive) | core | supported |
| `object-fit`, `object-position`, `border-radius` clipping of images | core | supported |
| WebP lossless, GIF (first frame) | standard | supported |
| WebP lossy (VP8; bit-exact with libwebp), animated GIF / APNG / WebP sources | full | supported to the reference decoders |
| SVG images (`<svg>` markup, `data:image/svg+xml`, `url()` backgrounds and masks) | standard | supported |
| SVG coverage | standard | shapes, paths, `use` / `symbol`, gradients, patterns, `clipPath`, `mask`, markers, nested `<svg>` / `<image>`, `<style>` with simple selectors, filters `feGaussianBlur`, `feOffset`, `feFlood`, `feColorMatrix`, `feComposite`, `feMerge`, `feBlend`, `feDropShadow`, `feComponentTransfer`. `<text>` is drawn with the registered fonts in a simplified model (one run per element: `x` / `y`, `font-family`, `font-size`, `font-weight`, `text-anchor`, solid `fill`; `<tspan>` content joins the parent run with the parent style; gradient-filled or stroke-only text is not drawn; see [Charts](charts.md#what-svg-text-supports)). Not supported: `feTurbulence`, `feImage`, `feMorphology`, `feConvolveMatrix`, `feDisplacementMap`, lighting filters, `feTile`, external references |
| `image-rendering: pixelated` / `crisp-edges` | core | supported |
| Remote URLs | — | never fetched: pass bytes through `images` |

## Complex scripts, bidi, emoji

| Feature | Min. profile | Status |
|:--|:--|:--|
| Latin, Cyrillic, Greek, Vietnamese (precomposed), CJK line breaking | core | supported |
| Bidi (UAX #9), `direction`, `dir`, `unicode-bidi` isolation | full | 91 679/91 679 bidi conformance cases |
| Arabic, Hebrew, Devanagari, Bengali, Thai shaping; Unicode normalisation (decomposed Vietnamese) | full | supported; other Indic scripts use the default shaper |
| Emoji sequences: ZWJ, skin-tone modifiers, flags, tag flags, keycaps, VS15 / VS16 | standard | one cluster and one glyph each (never split by wrapping, fallback or letter spacing) |
| Colour emoji (with a registered emoji font) | standard (bitmap: CBDT / sbix), full (also COLR) | supported |

On `core` and `standard`, right-to-left and complex scripts are shaped with the default OpenType
shaper in logical order (no reordering).

## Paged media (`pdf` profile)

`break-*`, `orphans`, `widows`, `@page`, repeated table headers, `position: fixed` on every page and
`background-clip: border-area` apply only to PDF output; image renders accept and ignore them on every build.
The table is in [CSS in PDF](../pdf/css-support.md#paged-media).

## Known gaps

As of 0.1.0 (see [docs/BENCHMARK.md](../../BENCHMARK.md) for the final status):

- **Inline layout (remaining gaps)** — RTL + `white-space: pre-wrap` hanging spaces; line-clamp /
  `-webkit-box` around floats; a block inside a relatively positioned inline box is not shifted with it;
  a chain of nested inline-blocks is limited to about 255 levels (a clean "nested too deeply" error),
  although plain nesting supports 512.
- **Paint order** — raster output paints floats and positioned boxes in CSS 2.1 Appendix E order (floats
  after block backgrounds and before inline content; positioned boxes after the in-flow content of their
  stacking context); `renderSvg` still uses the older, approximate order, and negative `z-index` keeps a
  sibling-level approximation.
- **RTL** — `justify-self: left / right` is not mirrored under `direction: rtl`; on `core` and
  `standard` boxes are mirrored but the text inside them stays left to right (bidi needs `full`).
- **Structural pseudo-classes on text nodes** — a `text` node without a `tagName` is not an element for
  `:first-child`, `:nth-child()`, sibling combinators or the Tailwind `first:` / `odd:` / ... variants
  : it does not count as a sibling, so every one of several bare text siblings matches
  `first:`, `last:` and `odd:`. Give the node a `tagName` or wrap the text in a container.
- **`text-transform`** — no `lang`-tailored casing (Turkish, Azeri, Greek, Lithuanian), no `full-width` /
  `full-size-kana`.
- **Vertical writing modes** — a vertical flow holding a table, an absolutely / fixed positioned box,
  `sideways-lr` or both `vertical-rl` and `vertical-lr` is laid out horizontally;
  no `text-combine-upright: digits`; no `text-spacing-trim`; a vertical flow is not split across PDF
  pages. Details: [Typography](./typography.md#vertical-text).
- Not supported: list markers and counters, 3D transforms, `filter: url()` /
  `clip-path: url()`, relative colour syntax, `outline-offset` in %, `@apply`, animations on
  pseudo-elements. (PDF output exists only in the separate [`pdf` profile](../pdf/index.md); it paints list markers in PDF output.)
- Remaining one-level differences: gradient interior, dashed borders on rounded corners, rotated text,
  `text-stroke`.

## Appendix: supported property names

The 296 property names the style parser recognises, generated from `src/style/props.zig` (camelCase,
as used in inline `style` objects; stylesheets use the kebab-case form). Recognised does not always
mean implemented: see the notes at the end.

**Display and positioning:** `display`, `position`, `top`, `right`, `bottom`, `left`, `inset`,
`insetBlock`, `insetBlockEnd`, `insetBlockStart`, `insetInline`, `insetInlineEnd`, `insetInlineStart`,
`zIndex`, `float`, `clear`, `visibility`, `overflow`, `overflowX`, `overflowY`, `overflowBlock`,
`overflowInline`, `contain`, `verticalAlign`, `order`, `boxSizing`, `aspectRatio`.

**Sizing:** `width`, `height`, `minWidth`, `minHeight`, `maxWidth`, `maxHeight`, `inlineSize`,
`blockSize`, `minInlineSize`, `minBlockSize`, `maxInlineSize`, `maxBlockSize`.

**Spacing:** `margin`, `marginTop`, `marginRight`, `marginBottom`, `marginLeft`, `marginBlock`,
`marginBlockStart`, `marginBlockEnd`, `marginInline`, `marginInlineStart`, `marginInlineEnd`,
`padding`, `paddingTop`, `paddingRight`, `paddingBottom`, `paddingLeft`, `paddingBlock`,
`paddingBlockStart`, `paddingBlockEnd`, `paddingInline`, `paddingInlineStart`, `paddingInlineEnd`,
`gap`, `rowGap`, `columnGap`.

**Flexbox and alignment:** `flex`, `flexBasis`, `flexDirection`, `flexFlow`, `flexGrow`, `flexShrink`,
`flexWrap`, `alignContent`, `alignItems`, `alignSelf`, `justifyContent`, `justifyItems`, `justifySelf`,
`placeContent`, `placeItems`, `placeSelf`, `WebkitBoxOrient`.

**Grid:** `grid`, `gridArea`, `gridAutoColumns`, `gridAutoFlow`, `gridAutoRows`, `gridColumn`,
`gridColumnEnd`, `gridColumnStart`, `gridRow`, `gridRowEnd`, `gridRowStart`, `gridTemplate`,
`gridTemplateAreas`, `gridTemplateColumns`, `gridTemplateRows`.

**Tables:** `tableLayout`, `borderCollapse`, `borderSpacing`, `captionSide`, `emptyCells`.

**Borders and outline:** `border`, `borderTop`, `borderRight`, `borderBottom`, `borderLeft`,
`borderColor`, `borderStyle`, `borderWidth`, `borderTopColor`, `borderTopStyle`, `borderTopWidth`,
`borderRightColor`, `borderRightStyle`, `borderRightWidth`, `borderBottomColor`, `borderBottomStyle`,
`borderBottomWidth`, `borderLeftColor`, `borderLeftStyle`, `borderLeftWidth`, `borderBlock`,
`borderBlockColor`, `borderBlockStyle`, `borderBlockWidth`, `borderBlockStart`,
`borderBlockStartColor`, `borderBlockStartStyle`, `borderBlockStartWidth`, `borderBlockEnd`,
`borderBlockEndColor`, `borderBlockEndStyle`, `borderBlockEndWidth`, `borderInline`,
`borderInlineColor`, `borderInlineStyle`, `borderInlineWidth`, `borderInlineStart`,
`borderInlineStartColor`, `borderInlineStartStyle`, `borderInlineStartWidth`, `borderInlineEnd`,
`borderInlineEndColor`, `borderInlineEndStyle`, `borderInlineEndWidth`, `borderRadius`,
`borderTopLeftRadius`, `borderTopRightRadius`, `borderBottomRightRadius`, `borderBottomLeftRadius`,
`borderStartStartRadius`, `borderStartEndRadius`, `borderEndStartRadius`, `borderEndEndRadius`,
`outline`, `outlineColor`, `outlineOffset`, `outlineStyle`, `outlineWidth`.

**Backgrounds:** `background`, `backgroundAttachment`, `backgroundBlendMode`, `backgroundClip`,
`backgroundColor`, `backgroundImage`, `backgroundOrigin`, `backgroundPosition`,
`backgroundPositionX`, `backgroundPositionY`, `backgroundRepeat`, `backgroundSize`.

**Masks and clipping:** `clipPath`, `WebkitClipPath`, `mask`, `maskClip`, `maskComposite`,
`maskImage`, `maskMode`, `maskOrigin`, `maskPosition`, `maskRepeat`, `maskSize`, `maskType`,
`WebkitMask`, `WebkitMaskClip`, `WebkitMaskComposite`, `WebkitMaskImage`, `WebkitMaskOrigin`,
`WebkitMaskPosition`, `WebkitMaskRepeat`, `WebkitMaskSize`.

**Effects:** `opacity`, `boxShadow`, `filter`, `backdropFilter`, `WebkitBackdropFilter`,
`mixBlendMode`, `isolation`.

**Transforms:** `transform`, `transformOrigin`, `translate`, `rotate`, `scale`.

**Images:** `objectFit`, `objectPosition`, `imageRendering`.

**Text:** `color`, `direction`, `unicodeBidi`, `writingMode`, `textOrientation`, `textCombineUpright`, `textAlign`, `textAlignLast`,
`textIndent`, `textTransform`, `textShadow`, `textOverflow`, `textWrap`, `textWrapMode`,
`textWrapStyle`, `whiteSpace`, `whiteSpaceCollapse`, `wordBreak`, `wordSpacing`, `wordWrap`,
`overflowWrap`, `letterSpacing`, `lineHeight`, `lineBreak`, `lineClamp`, `WebkitLineClamp`,
`hyphens`, `WebkitHyphens`, `tabSize`, `textDecoration`, `textDecorationColor`,
`textDecorationLine`, `textDecorationSkipInk`, `textDecorationStyle`, `textDecorationThickness`,
`textUnderlineOffset`, `textUnderlinePosition`, `WebkitTextFillColor`, `WebkitTextStroke`,
`WebkitTextStrokeColor`, `WebkitTextStrokeWidth`, `paintOrder`, `boxDecorationBreak`,
`WebkitBoxDecorationBreak`.

**Fonts:** `font`, `fontFamily`, `fontSize`, `fontStyle`, `fontWeight`, `fontStretch`,
`fontFeatureSettings`, `fontKerning`, `fontOpticalSizing`, `fontVariant`, `fontVariantCaps`,
`fontVariantEastAsian`, `fontVariantLigatures`, `fontVariantNumeric`, `fontVariantPosition`,
`fontVariationSettings`, `fontSynthesis`, `fontSynthesisSmallCaps`, `fontSynthesisStyle`,
`fontSynthesisWeight`.

**Generated content and lists:** `content`, `counterIncrement`, `counterReset`, `counterSet`,
`listStyle`, `listStyleImage`, `listStylePosition`, `listStyleType`.

**Animation and transition:** `animation`, `animationDelay`, `animationDirection`,
`animationDuration`, `animationFillMode`, `animationIterationCount`, `animationName`,
`animationPlayState`, `animationTimingFunction`, `transition`, `transitionBehavior`,
`transitionDelay`, `transitionDuration`, `transitionProperty`, `transitionTimingFunction`.

**Interaction (accepted for compatibility):** `cursor`, `pointerEvents`, `userSelect`,
`WebkitUserSelect`, `willChange`.

Notes:

- **Accepted and ignored** (value not even parsed): `backgroundAttachment`, `willChange`,
  `pointerEvents`, `cursor`, `userSelect`, `WebkitUserSelect`, `transitionBehavior`, `maskComposite`,
  `WebkitMaskComposite`.
- **Parsed, no visible effect in 0.1.0** (found by inspecting which computed values the renderer
  reads): `hyphens` / `WebkitHyphens`, `lineBreak`, `textAlignLast`, `unicodeBidi`,
  `fontSynthesisWeight` / `fontSynthesisStyle` and the weight / style parts of `fontSynthesis` (bold /
  italic synthesis is always on; small-caps synthesis does follow `fontSynthesis` /
  `fontSynthesisSmallCaps`), `counterReset` / `counterIncrement` / `counterSet`, `listStyle*` (no
  markers), `transition*`, `paintOrder` on text (ignored).
- Properties of a feature that is compiled out of the loaded profile are accepted and ignored (for
  example `float` on `core`), except values that need a missing parser (modern colour functions on
  `core`), which are invalid.
- Any other key is ignored silently, as are kebab-case keys in inline `style` objects.


## See also

The guide pages go deeper into each topic, with runnable examples and their rendered output:
[Concepts](concepts.md) · [Styles and layout](styles.md) · [HTML and Tailwind](html-and-tailwind.md) ·
[Fonts](fonts.md) · [Typography](typography.md) · [Images](images.md) · [Tables and floats](tables.md) ·
[Effects](effects.md) · [Output formats](formats.md) · [Animation](animation.md) · [measure()](measure.md) ·
[Charts](charts.md) · [Templates](templates.md) · [Performance](performance.md)
