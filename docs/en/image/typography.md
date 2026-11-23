# Typography

[English](typography.md) · [Tiếng Việt](../../vi/image/typography.md)

How bm-render lays out and paints text: wrapping and `white-space`, breaking long words, line height and
spacing, alignment, truncation with ellipsis and `line-clamp`, balanced headlines, decorations, shadows
and strokes, case transforms, mixing spans, inline-blocks and images in a line, OpenType features,
vertical text (`writing-mode`, `text-combine-upright`), and
which [profile](../profiles-and-size.md) you need for bidirectional and complex scripts. Text needs a
registered font: see [Fonts](./fonts.md) first. Every example was run by `docs/examples/typography.mjs`
and the images are its output.

[[toc]]

## Setup used on this page

The examples share a renderer and three tiny helpers that build nodes. `sample()` draws a grey caption and
a framed box so you can see where the text box ends:

<!-- @example typography#setup -->
```js
import { readFileSync } from "node:fs";
import { Renderer } from "bm-render";

const renderer = new Renderer();
for (const file of ["Inter-Regular", "Inter-SemiBold", "Inter-Bold", "Inter-Italic", "Roboto-Regular"]) {
  renderer.registerFont(readFileSync(`assets/fonts/${file}.ttf`));
}

// Small helpers used by the examples on this page.
const text = (t, style = {}) => ({ type: "text", text: t, style });
const box = (style, children) => ({ type: "container", style: { display: "block", ...style }, children });
const page = (style, children) => ({
  type: "container",
  style: { display: "flex", width: "100%", height: "100%", padding: 16, gap: 12, backgroundColor: "#fff",
           color: "#111827", fontFamily: "Inter", fontSize: 16, ...style },
  children,
});
// A labelled sample: grey caption + a framed box (170 px wide unless style.width says otherwise).
const sample = (label, { width = 170, ...style }, children) => box({ width }, [
  box({ fontSize: 12, color: "#6b7280", marginBottom: 4 }, [text(label)]),
  box({ border: "1px solid #cbd5e1", padding: 6, ...style }, children),
]);
```

A text node behaves like a `<span>`: it inherits `fontFamily`, `fontSize`, `color` and every other text
property from its ancestors, so you can set them once on a container.

## Wrapping and `white-space`

Text wraps at break opportunities (spaces, hyphens, after most punctuation, between CJK characters;
Unicode UAX #14) when it reaches the width of its box. `white-space` decides whether spaces and newlines
are kept and whether lines wrap:

<!-- @example typography#white-space -->
```js
const para = "Text  wraps   at spaces.\nA newline here.";
const whiteSpace = renderer.renderSync(
  page({}, ["normal", "nowrap", "pre", "pre-wrap", "pre-line"].map((ws) =>
    sample(ws, { whiteSpace: ws, width: 140, height: 110, overflow: "hidden" }, [text(para)]))),
  { width: 790, height: 160 },
);
```

![normal collapses spaces and wraps; nowrap keeps one line; pre keeps spaces and newlines without wrapping; pre-wrap keeps them and wraps; pre-line keeps newlines only](/img/guide/typography-white-space.png)

| `whiteSpace` | Collapses spaces | Keeps `\n` | Wraps |
|:--|:-:|:-:|:-:|
| `normal` (default) | yes | no | yes |
| `nowrap` | yes | no | no |
| `pre` | no | yes | no |
| `pre-wrap` | no | yes | yes |
| `pre-line` | yes | yes | yes |

The longhands `whiteSpaceCollapse` and `textWrapMode` are supported as well, and `tabSize` sets the
width of tab characters in preserved white space.

## Breaking long words and URLs

A word longer than the line overflows its box by default. `overflowWrap: "anywhere"` (or
`"break-word"`) breaks it only when it does not fit, `wordBreak: "break-all"` breaks between any two
letters, and a soft hyphen (U+00AD) in the text marks where a word may be hyphenated:

<!-- @example typography#breaking -->
```js
const url = "https://example.com/a/very/long/path/without-any-spaces";
const breaking = renderer.renderSync(
  page({}, [
    sample("normal (overflow hidden)", { overflow: "hidden" }, [text(url)]),
    sample("overflowWrap: anywhere", { overflowWrap: "anywhere" }, [text(url)]),
    sample("wordBreak: break-all", { wordBreak: "break-all" }, [text("Break all of these words")]),
    sample("soft hyphen U+00AD", {}, [text("Extra­ordinary inter­nationalisation")]),
  ]),
  { width: 790, height: 140 },
);
```

![A clipped URL, a URL broken anywhere, words broken at any letter, and words hyphenated at soft hyphens](/img/guide/typography-breaking.png)

`wordBreak: "keep-all"` keeps CJK words together. `hyphens: "auto"` is parsed but there is no
hyphenation dictionary: only soft hyphens produce hyphens.

## Line height and spacing

<!-- @example typography#spacing -->
```js
const spacing = renderer.renderSync(
  page({ flexDirection: "column", gap: 6 }, [
    text("Default: lineHeight normal (from the font's metrics), no extra spacing"),
    box({ lineHeight: 1.8, backgroundColor: "#f1f5f9", width: 520 }, [text("lineHeight: 1.8 adds half-leading above and below every line of this wrapped paragraph.")]),
    text("letterSpacing: 4px", { letterSpacing: 4 }),
    text("LETTERSPACING -0.05em", { letterSpacing: "-0.05em", fontWeight: 700, fontSize: 24 }),
    text("wordSpacing: 16px puts more room between words", { wordSpacing: 16 }),
  ]),
  { width: 560, height: 210 },
);
```

![Default line height, a 1.8 line height paragraph, letter spacing of 4px and -0.05em, and word spacing](/img/guide/typography-spacing.png)

- `lineHeight` takes a number (a multiple of the font size, recommended: it inherits as a factor), a
  length (`24`, `"1.5rem"`) or `"normal"` (the default: ascent + descent + line gap of the font, so it
  differs between fonts).
- `letterSpacing` and `wordSpacing` take lengths, including `em`. Negative tracking is common for large
  bold headlines.

## Alignment

<!-- @example typography#align -->
```js
const words = "The quick brown fox jumps over the lazy dog and keeps running far away.";
const align = renderer.renderSync(
  page({}, [
    sample("left", { textAlign: "left" }, [text(words)]),
    sample("center", { textAlign: "center" }, [text(words)]),
    sample("right", { textAlign: "right" }, [text(words)]),
    sample("justify", { textAlign: "justify" }, [text(words)]),
  ]),
  { width: 790, height: 150 },
);
```

![The same paragraph aligned left, centered, right and justified](/img/guide/typography-align.png)

`textAlign` accepts `left`, `right`, `center`, `justify`, `start` and `end` (the last two follow
`direction`). A justified paragraph stretches every line except the last.

## First-line indent

`textIndent` indents the first line of a block container: a length, a percentage of the container's
width, or a negative value (an outdent; add padding so the text stays inside). The keywords `hanging`
(indent every line except the first) and `each-line` (also indent after forced line breaks) work too,
and in a right-to-left paragraph the indent is on the right:

<!-- @example typography#indent -->
```js
const indentText = "The first line of this paragraph starts further in than the lines that follow it.";
const indent = renderer.renderSync(
  page({}, [
    sample("textIndent: 24", { textIndent: 24 }, [text(indentText)]),
    sample("textIndent: \"10%\"", { textIndent: "10%" }, [text(indentText)]),
    sample("textIndent: -16 (+ padding)", { textIndent: -16, paddingLeft: 22 }, [text(indentText)]),
    sample("\"24px hanging\"", { textIndent: "24px hanging" }, [text(indentText)]),
  ]),
  { width: 790, height: 150 },
);
```

![Four paragraphs: indented by 24 px, by 10 %, outdented by 16 px, and with a 24 px hanging indent](/img/guide/typography-indent.png)

Only the first line of the block is indented.

## Truncation: ellipsis and line clamp

<!-- @example typography#truncation -->
```js
const long = "bm-render renders node trees, HTML and Tailwind to images without a browser, in a few milliseconds.";
const truncation = renderer.renderSync(
  page({}, [
    sample("textOverflow: ellipsis", { whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }, [text(long)]),
    sample("lineClamp: 2", { lineClamp: 2 }, [text(long)]),
    sample("-webkit-line-clamp: 3", { display: "-webkit-box", WebkitBoxOrient: "vertical", WebkitLineClamp: 3, overflow: "hidden" }, [text(long)]),
    sample("textOverflow: clip", { whiteSpace: "nowrap", overflow: "hidden" }, [text(long)]),
  ]),
  { width: 790, height: 130 },
);
```

![An ellipsis on one line, a two-line clamp, a three-line clamp with the legacy webkit syntax, and plain clipping](/img/guide/typography-truncation.png)

- **One line**: `textOverflow: "ellipsis"` works only together with `overflow: "hidden"` and a line that
  does not wrap (`whiteSpace: "nowrap"`), as in browsers.
- **Several lines**: `lineClamp: n` on a block container cuts after `n` lines and ends the last one with
  an ellipsis. The legacy form `display: "-webkit-box"` + `WebkitBoxOrient: "vertical"` +
  `WebkitLineClamp: n` gives the same result. Put the clamp on a block (or on a text node inside a flex
  container, which is blockified), not on a flex container.
- Text cut off by a fixed `height` gets no ellipsis; use `lineClamp`.

### Custom markers

`textOverflow` also takes a string, which is drawn instead of the ellipsis: it is shaped with the
element's font (and fallback fonts) and mirrored in a right-to-left paragraph. An empty string cuts
the text without a marker. `lineClamp` takes its own marker as `<n> "<string>"` (the CSS
`block-ellipsis` syntax; `none` and `no-ellipsis` are accepted too); a clamped line uses that marker, or
the default ellipsis, not the `textOverflow` string. `overflow: "hidden"` clips the element's own
glyphs, so `textOverflow: "clip"` really cuts through a letter:

<!-- @example typography#overflow-string -->
```js
// A string as the overflow marker: text-overflow on one line, line-clamp's block-ellipsis
// form on several lines, and an empty string to cut without any marker.
const overflowString = renderer.renderSync(
  page({}, [
    sample("textOverflow: '\" »\"'", { whiteSpace: "nowrap", overflow: "hidden", textOverflow: '" »"' }, [text(long)]),
    sample("lineClamp: '2 \" [more]\"'", { lineClamp: '2 " [more]"' }, [text(long)]),
    sample("textOverflow: '\"\"'", { whiteSpace: "nowrap", overflow: "hidden", textOverflow: '""' }, [text(long)]),
    // in a right-to-left paragraph the marker sits on the left and is mirrored (» becomes «)
    sample("direction: rtl", { direction: "rtl", whiteSpace: "nowrap", overflow: "hidden", textOverflow: '" »"' }, [text("Faster PNG encoding and a smaller core build")]),
  ]),
  { width: 790, height: 110 },
);
```

![A line ending in a » marker, a two-line clamp ending in [more], a line cut without marker, and a right-to-left line with a mirrored « marker on the left](/img/guide/typography-overflow-string.png)

## Balanced headlines

`textWrap: "balance"` evens out the line lengths of a short paragraph, which avoids a lone word on the
last line of a headline. It needs `standard` or `full` (`features.textWrapBalance`); `core` wraps
normally.

<!-- @example typography#balance -->
```js
// text-wrap: balance / pretty need the standard or full profile.
const headline = "Render Open Graph images at the edge without a headless browser";
const balance = renderer.renderSync(
  page({}, ["wrap", "balance", "pretty"].map((mode) =>
    sample(`textWrap: ${mode}`, { width: 240, textWrap: mode, fontSize: 20, fontWeight: 700 }, [text(headline)]))),
  { width: 790, height: 165 },
);
```

![Greedy wrapping leaves "browser" alone on the last line; balance gives three even lines](/img/guide/typography-balance.png)

`textWrap: "pretty"` gives the same lines as normal wrapping in
this example (the last line still holds a single word). Balancing falls back to normal wrapping in
paragraphs that contain inline boxes or atomic inlines, or sit beside a float.

## Decorations

<!-- @example typography#decoration -->
```js
const decoration = renderer.renderSync(
  page({ flexDirection: "column", gap: 8, fontSize: 20 }, [
    text("underline", { textDecoration: "underline" }),
    text("overline + line-through", { textDecorationLine: "overline line-through" }),
    text("wavy red underline", { textDecoration: "underline wavy #ef4444" }),
    text("dotted, 3px thick, offset 6px", { textDecoration: "underline dotted 3px #2563eb", textUnderlineOffset: 6 }),
    text("Skip ink: gjpqy", { textDecoration: "underline 2px", textDecorationSkipInk: "auto" }),
    text("No skip: gjpqy", { textDecoration: "underline 2px", textDecorationSkipInk: "none" }),
  ]),
  { width: 560, height: 240 },
);
```

![Underline, overline with line-through, a wavy red underline, a thick dotted blue underline with an offset, and underlines with and without skip-ink](/img/guide/typography-decoration.png)

`textDecoration` is a shorthand for `textDecorationLine` (`underline`, `overline`, `line-through`),
`textDecorationStyle` (`solid`, `double`, `dotted`, `dashed`, `wavy`), `textDecorationColor` and
`textDecorationThickness`. `textUnderlineOffset` moves the underline, `textUnderlinePosition: "under"`
puts it below the descenders, and `textDecorationSkipInk` (`auto` by default) interrupts the underline
around descenders, as the last two lines show.

## Shadows, strokes and gradient text

<!-- @example typography#effects -->
```js
const effects = renderer.renderSync(
  page({ flexDirection: "column", gap: 10, fontSize: 40, fontWeight: 700, backgroundColor: "#f8fafc" }, [
    text("Drop shadow", { textShadow: "3px 3px 0 #f59e0b" }),
    text("Soft glow", { color: "#fff", textShadow: "0 0 8px #7c3aed, 0 0 2px #7c3aed" }),
    text("Outlined", { color: "#fff", WebkitTextStroke: "2px #111827" }),
    text("Fill + stroke", { WebkitTextFillColor: "#fde68a", WebkitTextStroke: "1.5px #92400e" }),
    text("Gradient text", { backgroundImage: "linear-gradient(90deg, #ec4899, #8b5cf6)", backgroundClip: "text", color: "transparent" }),
  ]),
  { width: 560, height: 320 },
);
```

![Text with a hard orange shadow, a purple glow, an outline, a yellow fill with a brown stroke, and pink-to-purple gradient text](/img/guide/typography-effects.png)

- `textShadow` takes one or more `offsetX offsetY blur color` layers, separated by commas.
- `WebkitTextStroke` (`"width color"`) outlines the glyphs; `WebkitTextFillColor` overrides the fill
  colour (use `"transparent"` for hollow text).
- Gradient text: a background image clipped to the glyphs with `backgroundClip: "text"` and a
  transparent `color`. `background-clip: text` needs `standard` or `full`.

::: info `paint-order` is ignored
`paintOrder: "stroke"` is parsed, but the stroke is always painted over the fill. A
thick stroke therefore eats into the letters; keep strokes thin or use a `textShadow` outline.
:::

## Case

<!-- @example typography#transform -->
```js
const transform = renderer.renderSync(
  page({ flexDirection: "column", gap: 4, fontSize: 20 }, [
    text("uppercase: đường phố hà nội", { textTransform: "uppercase" }),
    text("CAPITALIZE: every word gets a capital", { textTransform: "capitalize" }),
    text("LOWERCASE: ĐƯỜNG PHỐ", { textTransform: "lowercase" }),
    text("uppercase, full case mapping: straße ﬁx", { textTransform: "uppercase" }), // STRASSE FIX
  ]),
  { width: 560, height: 140 },
);
```

![Uppercase Vietnamese text with diacritics, capitalised words and lowercase text](/img/guide/typography-transform.png)

`textTransform` uses the full Unicode case mapping: Vietnamese and other accented letters (`đ` → `Đ`),
`ß` → `SS`, ligatures such as `ﬁ` → `FI`, a final sigma in Greek, titlecase digraphs. Not done yet:
casing tailored by `lang` (Turkish and Azeri dotted i, Greek accents, Lithuanian) and the `full-width` /
`full-size-kana` values.

### Small caps

`fontVariantCaps` (or `fontVariant`) picks small capitals: `small-caps`, `all-small-caps`,
`petite-caps`, `all-petite-caps`, `unicase` and `titling-caps`. When the font has the OpenType features
(`smcp`, `c2sc`, ...), they are used; otherwise the small capitals are **synthesised** from uppercase
letters at 70 % of the font size, as in Chrome. Petite caps and unicase fall back to small caps.
`fontSynthesisSmallCaps: "none"` turns synthesis off:

<!-- @example typography#small-caps -->
```js
// Inter has no small-caps glyphs (no 'smcp' / 'c2sc' features), so the small capitals are
// synthesised: uppercase letters at 70 % of the font size, as in Chrome.
const smallCaps = renderer.renderSync(
  page({ flexDirection: "column", gap: 4, fontSize: 26 }, [
    text("normal: Release Notes 2026"),
    text("small-caps: Release Notes 2026", { fontVariantCaps: "small-caps" }),
    text("all-small-caps: Release Notes 2026", { fontVariantCaps: "all-small-caps" }),
    text("no synthesis: Release Notes 2026", { fontVariantCaps: "small-caps", fontSynthesisSmallCaps: "none" }),
  ]),
  { width: 560, height: 170 },
);
```

![Normal text, synthesised small caps, all-small-caps and the normal text again because synthesis is off](/img/guide/typography-small-caps.png)

## Mixing inline content

A container without `display` is **inline**, like a `<span>`: put several text nodes and inline
containers in a block (or a flex item) and they flow together on the same lines, wrapping as one
paragraph. Inline containers can have their own font, colour, background, padding and border radius.
`display: "inline-block"` makes an atomic box that sits on the line, and image nodes are inline too:

<!-- @example typography#inline -->
```js
// A container without `display` is inline (like a <span>), so it flows with the text around it.
const span = (style, children) => ({ type: "container", style, children });
const avatar = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><circle cx="10" cy="10" r="10" fill="#22c55e"/></svg>';
const inline = renderer.renderSync(
  page({ fontSize: 20 }, [
    box({ width: 520, lineHeight: 1.6 }, [
      text("Mix "),
      span({ fontWeight: 700 }, [text("bold")]),
      text(", "),
      span({ fontStyle: "italic", color: "#7c3aed" }, [text("italic")]),
      text(" and "),
      span({ backgroundColor: "#fef08a", padding: "0 4px", borderRadius: 4 }, [text("highlighted spans")]),
      text(" with an inline-block "),
      span({ display: "inline-block", padding: "0 8px", borderRadius: 999, backgroundColor: "#dbeafe", color: "#1d4ed8", fontSize: 14 }, [text("badge")]),
      text(", an inline image "),
      { type: "image", src: avatar, width: 20, height: 20, style: { verticalAlign: "middle" } },
      text(" and "),
      span({ fontSize: 12, verticalAlign: "super" }, [text("superscript")]),
      text(" text that wraps onto the next line."),
    ]),
  ]),
  { width: 560, height: 130 },
);
```

![A wrapped paragraph with bold and italic words, a highlighted span, a blue badge, a green dot image and superscript text](/img/guide/typography-inline.png)

- `verticalAlign` (`baseline`, `middle`, `top`, `bottom`, `text-top`, `text-bottom`, `super`, `sub`,
  lengths and percentages) positions inline boxes and images on the line.
- Horizontal padding, border and margin of an inline span push the neighbouring text; vertical padding
  paints but does not change the line height (as in CSS).
- Inside a **flex** container every child is blockified, so a row of text nodes in a flex container
  becomes separate flex items, not one paragraph. Wrap mixed content in a `display: "block"` container.

## OpenType features

bm-render applies the font's GSUB / GPOS features (kerning, ligatures, contextual alternates, mark
positioning) by default. CSS controls them:

<!-- @example typography#features -->
```js
const features = renderer.renderSync(
  page({ flexDirection: "column", gap: 4, fontSize: 22 }, [
    text("Proportional 1111 / 8888"),
    text("tabular-nums 1111 / 8888", { fontVariantNumeric: "tabular-nums" }),
    text("'zero' 0 O 10 — 'ss01' 1 4 6 9", { fontFeatureSettings: "'zero', 'ss01'" }),
    text("Roboto ligatures: fi fl ffi", { fontFamily: "Roboto" }),
    text("no ligatures: fi fl ffi", { fontFamily: "Roboto", fontVariantLigatures: "none" }),
    text("kerning on: AV To Wa", { fontSize: 28 }),
    text("kerning off: AV To Wa", { fontSize: 28, fontKerning: "none" }),
  ]),
  { width: 560, height: 260 },
);
```

![Proportional and tabular digits, Inter's slashed zero and alternate digits, Roboto ligatures on and off, and kerning on and off](/img/guide/typography-features.png)

| Property | Example | Effect |
|:--|:--|:--|
| `fontFeatureSettings` | `"'tnum', 'ss01' 1, 'liga' 0"` | turn any feature on or off |
| `fontVariantNumeric` | `"tabular-nums"`, `"oldstyle-nums"`, `"slashed-zero"`, `"diagonal-fractions"` | numeric features |
| `fontVariantLigatures` | `"none"`, `"no-common-ligatures"`, `"discretionary-ligatures"` | ligatures |
| `fontVariantCaps` | `"small-caps"`, `"all-small-caps"` | caps features, synthesised when missing ([above](#small-caps)) |
| `fontVariantPosition` | `"super"`, `"sub"` | `sups` / `subs` |
| `fontKerning` | `"none"` | disables kerning |

Measured with Inter at 40 px: `AV To Wa` is 181.5 px wide with kerning and 189.4 px without; Roboto's
`fi fl ffi` is 100.7 px with ligatures and 104.5 px without. Features only work when the font has them.

## Vietnamese

<!-- @example typography#vietnamese -->
```js
const vietnamese = renderer.renderSync(
  page({ flexDirection: "column", gap: 6, fontSize: 22 }, [
    text("Tiếng Việt có sáu thanh: ngang, huyền, sắc, hỏi, ngã, nặng.", { fontWeight: 700 }),
    box({ width: 520, lineHeight: 1.5, textWrap: "balance" }, [
      text("Phở bò Hà Nội, bánh mì Sài Gòn và cà phê sữa đá — những món ăn đường phố nổi tiếng nhất."),
    ]),
    // User input may arrive decomposed (NFD): normalise it to NFC before rendering.
    text("Nguyễn Thị Ánh".normalize("NFC"), { color: "#be123c" }),
  ]),
  { width: 560, height: 150 },
);
```

![Vietnamese text with all six tones, a balanced paragraph and a name in red](/img/guide/typography-vietnamese.png)

Precomposed (NFC) Vietnamese works on every profile with any font that has the letters (Inter, Noto
Sans, Roboto, Be Vietnam Pro, ...). Text in decomposed form (NFD, common in input from macOS) relies on
the font's mark positioning and is normalised automatically only on `full`; call `normalize("NFC")`
on user input to be safe. Lines break at spaces, which is what Vietnamese needs.

## Vertical text

`writingMode: "vertical-rl"` (Japanese, Chinese and Korean books) and `"vertical-lr"` (Mongolian, some
headings) turn a block on its side: the lines run from top to bottom, and they stack from right to left
(`vertical-rl`) or from left to right (`vertical-lr`). `"sideways-rl"` is `vertical-rl` with every
character turned. It works on every profile, in PNG / JPEG / WebP, `renderSvg` and PDF output.

```js
// Noto Sans TC (or any CJK font with vertical metrics) registered as "Noto Sans TC"
const vertical = renderer.renderSync(
  `<!doctype html><html><body style="margin:0;font-family:'Noto Sans TC';font-size:20px">
    <div style="writing-mode:vertical-rl;height:200px;padding:10px;line-height:1.5;background:#eef">
      日本語の書き方。CSS 2024年、ABC と 123 を含む。<span style="color:#c00">赤い文字</span>
    </div>
  </body></html>`,
  { width: 300, height: 240 },
);
```

What is supported:

- **Orientation** (`textOrientation`). `mixed` (the default) sets CJK ideographs, kana, Hangul,
  full-width forms and the other characters Unicode gives an upright vertical orientation (UAX #50,
  approximated by ranges) upright, and turns Latin letters, digits and the rest 90 degrees clockwise.
  `upright` sets every character upright, `sideways` turns every character. Upright characters are shaped
  with the font's `vert` feature (vertical punctuation such as `、` `。` `「」` `（）`), advance by their
  vertical advance (`vhea` / `vmtx`) and hang from their vertical origin (`VORG`, else `vmtx` + the glyph
  box); a font without vertical metrics falls back to its height and an em box centred on the line, as
  Chrome does.
- **Tate-chu-yoko** (`textCombineUpright: "all"` on a span): the span's text (`"12"`, `"2024"`, `"!?"`)
  is set horizontally in one upright em, compressed horizontally when it is wider, and centred on the line.
- **Inline content**: font sizes, colours, spans with backgrounds, borders and padding, decorations
  (`underline` is drawn on the left, the line-under side), `text-align` along the line (`start` = top,
  `end` = bottom, `center`), `text-indent`, `line-height`, wrapping and every `white-space` /
  `word-break` value, inline-blocks and images in the line.
- **Boxes**: padding, borders, backgrounds and margins of the vertical box and of its block children,
  which stack along the block axis (right to left in `vertical-rl`); flex and grid containers lay out
  along the logical axes (a `flex-direction: row` runs top to bottom); `float: left` / `right` mean
  line-left / line-right (top / bottom). Logical properties (`marginBlockStart`, `paddingInlineStart`,
  `inlineSize`, `borderBlockEnd`, ...) map through the writing mode.
- **Orthogonal flows** (CSS Writing Modes 4 §7): a vertical box in a horizontal page (a vertical heading
  beside horizontal text) is as wide as its lines and as tall as its content, at most the parent's
  definite height, else the viewport height; a horizontal box inside a vertical one takes its width the
  same way from the viewport width. A `writing-mode` on `<body>` applies to the whole document (the root
  takes it, as in browsers), so `<body style="writing-mode:vertical-rl">` starts at the top right corner.
- **PDF**: the turned lines are text in content order. Upright characters are drawn as outlines with an
  invisible copy of the line's text in the line's direction on top, so that copying and text extraction
  follow the line: `pdftotext` reads a `vertical-rl` page column by column from the right; in
  `vertical-lr` its reading-order mode lists the columns from the right as well (`pdftotext -raw` keeps
  the logical order in both modes).

Compared with Chrome (`npm run test:writing-mode`: Noto Sans TC, Chrome screenshots at device scale 1).
The element rectangles of the block, orthogonal-flow and logical-property fixtures are the same as
Chrome's; "differing" is the share of pixels whose luma differs by more than 48 after a 3 x 3 blur (it
leaves anti-aliasing out), mostly sub-pixel glyph positions:

| Fixture | Differing pixels |
|:--|--:|
| `vertical-rl`, CJK + Latin + digits, padding, background | 0.47 % |
| `vertical-rl` on `<body>` (a page of text) | 2.29 % |
| `vertical-lr`, border | 0.05 % |
| `text-orientation: upright` / `sideways` | 0.05 % / 0.00 % |
| vertical heading in a horizontal page | 0.19 % |
| spans: colour, background, underline, larger font | 2.47 % |
| `text-align` per paragraph | 0.00 % |
| `text-combine-upright` (`12`, `2024`, `!?`) | 1.16 % (see the limits) |
| Chinese with full-width punctuation | 3.01 % (Chrome trims `。（`) |
| horizontal box in a vertical page | 0.90 % |
| block children, logical properties, flex | 0.69 %, 0.38 %, 0.27 % |

Limits:

- A vertical flow holding a table, an absolutely / fixed positioned box, `sideways-lr`, or both
  `vertical-rl` and `vertical-lr` is laid out horizontally instead (its logical properties keep their
  vertical mapping).
- `textCombineUpright: "digits <n>"` is not supported, and a combined unit is compressed by scaling rather
  than with the font's half / third / quarter-width forms (`hwid`, `twid`, `qwid`) Chrome tries first;
  Chrome also sets the unit a few pixels right of the line's centre.
- Chrome's `text-spacing-trim` (adjacent full-width punctuation such as `。（` set half-width) is not
  applied, in horizontal text either.
- Runs of different fonts or sizes on one line align on the alphabetic baseline, not on the central one
  Chrome uses for vertical text (a few pixels with a fallback font or a larger span).
- `underline` is always on the left; Chrome draws it on the right for `lang="ja"` / `"ko"`.
- A vertical flow is not split across PDF pages; `text-shadow` on upright characters is not drawn in PDF
  output, and `background-clip: text` does not follow vertical text.
- Percentage padding and margins of an orthogonal box resolve against its own inline axis.
- The baseline of a vertical inline-block in a horizontal line is its bottom margin edge.

## Bidirectional text and complex scripts

The `full` profile runs the Unicode bidirectional algorithm (UAX #9) and the complex shapers for Arabic,
Hebrew, Devanagari, Bengali and Thai. Base direction comes from `direction: "rtl"` in the style or
`dir: "rtl"` on a node. CJK text breaks between characters. Fonts for these scripts are not in this
repository; the example uses WOFF2 files from font files you provide:

<!-- @example typography#scripts -->
```js
// Arabic (Scheherazade New) and Traditional Chinese (Noto Sans TC) WOFF2 fonts from
renderer.registerFont(readFileSync("./fonts/ScheherazadeNew.woff2"));
renderer.registerFont(readFileSync("./fonts/NotoSansTC.woff2"));

const scripts = page({ flexDirection: "column", gap: 6, fontSize: 24 }, [
  text("Mixed: Hello مرحبا بالعالم 123 world"),
  box({ direction: "rtl", backgroundColor: "#f1f5f9", padding: "0 8px" }, [text("RTL paragraph: مرحبا بالعالم (Hello) 2026")]),
  text("中文排版：繁體中文的換行規則與標點符號。"),
  box({ width: 300, backgroundColor: "#f1f5f9" }, [text("中文排版會在任何漢字之間換行，不需要空格。")]),
]);
const scriptsPng = renderer.renderSync(scripts, { width: 560, height: 250 });
```

![On full: Arabic joined and placed right-to-left inside an English line, a right-aligned RTL paragraph, and Chinese text wrapping between characters](/img/guide/typography-scripts.png)

The same tree on `standard`: Arabic letters are not joined, nothing is reordered and the RTL paragraph is
laid out left to right. CJK and other scripts that need no reordering look the same:

![On standard: Arabic letters isolated and in logical order, RTL paragraph left-aligned](/img/guide/typography-scripts-standard.png)

| Script / feature | core | standard | full |
|:--|:-:|:-:|:-:|
| Latin, Cyrillic, Greek, Vietnamese (NFC) | yes | yes | yes |
| CJK (line breaking between characters) | yes | yes | yes |
| Kerning, ligatures, OpenType features | yes | yes | yes |
| `text-wrap: balance / pretty` | no | yes | yes |
| Bidi reordering, `direction`, `dir`, `unicode-bidi` | no | no | yes |
| Arabic / Hebrew / Indic / Thai shaping | default shaper | default shaper | yes |
| Unicode normalisation (NFD Vietnamese) | no | no | yes |
| Emoji sequences (ZWJ, skin tones, flags, keycaps) as one glyph | no | yes | yes |
| Colour emoji | no | bitmap fonts (CBDT / sbix) | yes (with a colour font) |

`direction: rtl` also mirrors flex rows, grid columns and tables (see [Styles](./styles.md#right-to-left)).
Known gap (also in [CSS support](./css-support.md#known-gaps)): hanging spaces of RTL text with
`white-space: pre-wrap` are not handled. Vertical text: see [Vertical text](#vertical-text).

## Properties that do nothing in 0.1.0

Parsed and accepted, without visible effect: `textAlignLast`, `hyphens` (except soft hyphens in the
text), `lineBreak`, `fontSynthesisWeight` / `fontSynthesisStyle` and the weight / style parts
of `fontSynthesis` (bold and italic are always synthesised), and `paintOrder` on text (ignored; SVG images
honour it). The full list of supported properties is in
[CSS support](./css-support.md#text).

See also: [Fonts](./fonts.md), [measure()](./measure.md) for fitting text into a box,
[Effects](./effects.md) for more paint effects.
