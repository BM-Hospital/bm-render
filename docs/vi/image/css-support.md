# Hỗ trợ CSS và tính năng

Trang này liệt kê tính năng của bm-render và profile tối thiểu cần dùng. **Hỗ trợ** nghĩa là có thể sử dụng; **một phần** có giới hạn được ghi kèm; **không** nghĩa là chưa hỗ trợ. Đối với PDF, xem [CSS trong PDF](../pdf/css-support.md).

- [Quy ước](#quy-ước)
- [Layout](#layout)
- [Box model và kích thước](#box-model-và-kích-thước)
- [Nền và gradient](#nền-và-gradient)
- [Viền và outline](#viền-và-outline)
- [Bóng đổ và hiệu ứng](#bóng-đổ-và-hiệu-ứng)
- [Transform](#transform)
- [Văn bản](#văn-bản)
- [Font](#font)
- [Màu sắc](#màu-sắc)
- [Giá trị, đơn vị, custom property](#giá-trị-đơn-vị-custom-property)
- [Stylesheet và selector](#stylesheet-và-selector)
- [Tailwind](#tailwind)
- [Đầu vào HTML](#đầu-vào-html)
- [Animation](#animation)
- [Ảnh và SVG](#ảnh-và-svg)
- [Chữ phức, bidi, emoji](#chữ-phức-bidi-emoji)
- [Trang giấy (profile `pdf`)](#trang-giấy-profile-pdf)
- [Các hạn chế đã biết](#các-hạn-chế-đã-biết)
- [Phụ lục: danh sách thuộc tính được hỗ trợ](#phụ-lục-danh-sách-thuộc-tính-được-hỗ-trợ)

## Quy ước

- Style inline dùng khoá camelCase (`backgroundColor`); stylesheet, thuộc tính `style=""` của HTML và
  Tailwind dùng cú pháp CSS bình thường. Mọi thuộc tính đều nhận `inherit`, `initial`, `unset`,
  `revert`, `var()` và các hàm toán học.
- Giá trị mặc định: **`display: inline`** cho mọi node, **`box-sizing:
  border-box`**, `object-fit: fill`, canvas trong suốt. Node gốc và các item flex / grid được
  blockify.
- Layout tính bằng điểm ảnh thiết bị với độ chính xác 1/64 px (`LayoutUnit` của Blink), việc làm tròn
  về điểm ảnh diễn ra lúc vẽ.

## Layout

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| Block layout, gộp margin (margin collapsing), `flow-root` | core | hỗ trợ |
| Định dạng inline (dòng chữ, `inline`, `inline-block`, `inline-flex`, `inline-grid`, `vertical-align`) | core | hỗ trợ ; xem [hạn chế đã biết](#các-hạn-chế-đã-biết) |
| Flexbox (direction, wrap, grow / shrink / basis, `gap`, căn chỉnh kể cả `safe`, `order`, `-webkit-box`) | core | hỗ trợ  |
| `direction: rtl` / `dir="rtl"` trên các hộp: hàng flex, cột grid, cột bảng và căn chỉnh block được lật ngược | core | hỗ trợ; chữ bên trong chỉ được dàn từ phải sang trái trên `full` (bidi); `justify-self: left / right` chưa được lật |
| Grid: track, `repeat()` kể cả `auto-fill` / `auto-fit`, `fr`, `minmax()`, tự xếp chỗ, span | core | hỗ trợ (4/4) |
| Grid: đường lưới đặt tên, `grid-template-areas`, `grid-area` | core | hỗ trợ (3/3) |
| `position: relative / absolute / fixed`, `inset`, `z-index` | core | hỗ trợ (3/3); `fixed` được định vị theo canvas |
| `position: sticky` | core | parse được, hoạt động như `relative` (không có cuộn) |
| `aspect-ratio`, `min-*` / `max-*`, `fit-content` / `min-content` / `max-content`, kích thước logic | core | hỗ trợ  |
| `overflow: hidden / clip` (kể cả cắt theo góc bo) | core | hỗ trợ |
| Bảng (`display: table*`, layout auto / fixed, `colspan` / `rowspan` qua HTML, `border-collapse`, `border-spacing`, caption, `empty-cells`) | standard | hỗ trợ  |
| Float (`float`, `clear`) | standard (cờ `floats`; cả `full`) | hỗ trợ; 138/138 ca oracle layout; chữ chảy quanh float  |
| `display: contents` | core | hỗ trợ |
| `display: list-item` | core | layout như block; không có ký hiệu đầu dòng (list marker) trong đầu ra raster / SVG ([profile `pdf`](../pdf/index.md) vẽ ký hiệu trong đầu ra PDF) |
| Chế độ viết (`writing-mode: vertical-rl / vertical-lr / sideways-rl`, `text-orientation`, luồng trực giao, thuộc tính logic theo chế độ viết) | core | hỗ trợ cho nội dung block, flex và grid có chữ, span và ảnh (so với Chrome bằng `npm run test:writing-mode`); chưa hỗ trợ bảng, hộp định vị absolute / fixed và `sideways-lr` (có hỗ trợ `text-combine-upright: all`): xem [Typography](./typography.md#chữ-dọc) |

Trên `core`, `display: table*` được layout như `block` và `float` bị bỏ qua (không báo lỗi).

## Box model và kích thước

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| `width` / `height` / `min-*` / `max-*` (px, %, em, rem, vw, vh, `auto`, `fit-content`, ...) | core | hỗ trợ |
| `margin` (kể cả `auto`), `padding`, dạng logic (`marginInline`, `paddingBlockStart`, ...) | core | hỗ trợ |
| `box-sizing: border-box` (mặc định) / `content-box` | core | hỗ trợ |
| `visibility: hidden / collapse` | core | hỗ trợ |
| `opacity` | core | hỗ trợ (4/4) |

## Nền và gradient

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| `background-color`, shorthand `background`, nhiều lớp nền | core | hỗ trợ |
| `linear-gradient`, `radial-gradient`, `conic-gradient`, `repeating-*` | core | hỗ trợ  |
| `background-image: url(...)`, `background-size` / `-position` / `-repeat` (kể cả `space`, `round`) / `-origin` / `-clip` | core | hỗ trợ  |
| `background-clip: text` | core | hỗ trợ |
| Không gian nội suy gradient (`linear-gradient(in oklab, ...)`) | standard | hỗ trợ trên standard/full; bị bỏ qua trên core |
| `background-blend-mode` | standard | hỗ trợ |

## Viền và outline

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| Độ dày / màu `border`, mọi kiểu: `solid`, `dashed`, `dotted`, `double`, `groove`, `ridge`, `inset`, `outset` | core | hỗ trợ (nét đứt trên góc bo có thể lệch pha ~0.1 px) |
| `border-radius` (elip, từng góc, phần trăm, góc logic) | core | hỗ trợ (4/4) |
| `outline`, `outline-offset` (px) | core | hỗ trợ; chưa hỗ trợ `outline-offset` theo % |

## Bóng đổ và hiệu ứng

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| `box-shadow` (ngoài, inset, spread, nhiều lớp) | core | hỗ trợ (4/4) |
| `text-shadow` | core | hỗ trợ |
| `filter`: `blur()`, `brightness()`, `contrast()`, `grayscale()`, `hue-rotate()`, `invert()`, `opacity()`, `saturate()`, `sepia()`, `drop-shadow()` | core | hỗ trợ; chưa hỗ trợ `filter: url(...)` |
| `backdrop-filter` | standard | hỗ trợ |
| `mix-blend-mode` (16 chế độ + `plus-lighter`, `plus-darker`), `isolation` | standard | hỗ trợ |
| `clip-path`: `inset()`, `circle()`, `ellipse()`, `polygon()` kèm geometry box | standard | hỗ trợ |
| `clip-path: path()` | standard (cần SVG) | có hỗ trợ; `clip-path: url(#id)` thì không |
| `mask-image` / `mask-*` / `-webkit-mask-*` (gradient và ảnh, `mask-mode`, `mask-type`) | standard | hỗ trợ; `mask-composite` bị bỏ qua |

Trên `core`, các thuộc tính hiệu ứng cần `standard` trong bảng này được chấp nhận nhưng bị bỏ qua.

## Transform

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| Các hàm `transform` 2D (`translate*`, `rotate`, `scale*`, `skew*`, `matrix`), `transform-origin` | core | hỗ trợ (3/3) |
| Các thuộc tính riêng `translate`, `rotate`, `scale` | core | có hỗ trợ |
| Transform 3D (`rotateX`, `matrix3d`, `perspective()`) | — | không hỗ trợ; transform inline dùng hàm 3D sẽ ném lỗi |

## Văn bản

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| Ngắt dòng (UAX #14), `white-space` (mọi chế độ), `word-break`, `overflow-wrap`, `tab-size` | core | hỗ trợ |
| `text-align` (kể cả `justify`), `line-height`, `letter-spacing`, `word-spacing` | core | hỗ trợ |
| `text-transform` | core | hỗ trợ: ánh xạ hoa / thường Unicode đầy đủ (`ß` → `SS`, sigma cuối từ, ligature, digraph titlecase); chưa có: đổi hoa / thường theo `lang` (Thổ Nhĩ Kỳ / Azeri, Hy Lạp, Litva), `full-width`, `full-size-kana` |
| `text-indent` (độ dài, %, số âm, `each-line`, `hanging`, RTL) | core | chỉ thụt dòng đầu của block |
| `text-overflow: ellipsis` / `clip` / `"<chuỗi>"`, `line-clamp` / `-webkit-line-clamp` (kể cả `<n> "<chuỗi>"`, `none`, `no-ellipsis`) | core | hỗ trợ; dấu cắt dạng chuỗi được shape bằng font của phần tử và font dự phòng, lật ngược trong RTL (chuỗi rỗng cắt mà không có dấu); `overflow` cắt cả glyph của chính phần tử |
| `text-decoration` (line, style kể cả `wavy`, màu, độ dày), `text-underline-offset` / `-position`, `text-decoration-skip-ink` | core | hỗ trợ |
| `-webkit-text-stroke`, `-webkit-text-fill-color` | core | hỗ trợ (nét viền có thể lệch 1 mức); `paint-order` parse được nhưng nét viền luôn vẽ đè lên phần tô |
| Hộp inline có nền / viền / padding, `box-decoration-break` | core | hỗ trợ; padding / viền / margin ngang của span đẩy chữ (mép fragment đầu / cuối, `box-decoration-break: clone`) |
| `text-wrap: balance` / `pretty` | standard | hỗ trợ |
| Tự tạo đậm / nghiêng (synthetic) khi thiếu face | core | hỗ trợ |
| `font-feature-settings`, `font-variant-*`, `font-kerning`, ligature (GSUB 1–8, GPOS 1–9) | core | hỗ trợ |
| `font-variant-caps` (`small-caps`, `all-small-caps`, `petite-caps`, `all-petite-caps`, `unicase`, `titling-caps`), `font-synthesis-small-caps` | core | dùng feature OpenType của font khi có, nếu không thì tự tạo (chữ hoa ở 70 % cỡ chữ); petite caps và unicase quay về small caps; `font-synthesis-small-caps: none` tắt việc tự tạo |
| Hộp inline: `margin` / `padding` theo %, `position: relative` | core | phần trăm tính theo containing block; độ dời relative dịch chuyển hộp inline |
| `hyphens`, `line-break`, `text-align-last` | — | parse được, chưa có tác dụng trong 0.1.0 |

## Font

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| TrueType (`glyf`), bộ sưu tập (`.ttc`) | core | hỗ trợ |
| CFF / CFF2 (`.otf`) | standard | bề rộng lệch trong 1/64 px |
| WOFF / WOFF2 | standard (core: [add-on](../profiles-and-size.md#add-on-woff)) | hỗ trợ |
| Font biến thiên (`fvar`, `avar`, `gvar`, `HVAR`, `MVAR`), `font-variation-settings`, `font-optical-sizing` | standard | 1 400 phép so bề rộng lệch trong 1/64 px; trên core chỉ vẽ instance mặc định |
| Font màu: COLR v0 / v1 | full | hỗ trợ màu trên full; core/standard chỉ vẽ outline thường |
| Font màu dạng bitmap: CBDT, sbix | standard | vẽ có màu trên `standard` và `full`; `core` không vẽ gì với font chỉ có bitmap |
| `@font-face` trong stylesheet | — | không được tải: hãy đăng ký font bằng `registerFont` / `fonts` |

## Màu sắc

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| Tên màu, `#rgb[a]`, `#rrggbb[aa]`, `rgb()` / `rgba()`, `hsl()` / `hsla()`, `hwb()`, `currentColor`, `transparent` | core | hỗ trợ |
| `lab()`, `lch()`, `oklab()`, `oklch()`, `color()`, `color-mix()`, `light-dark()` | standard | 495/495 màu trùng ở 8 bit. Trên core các giá trị này không hợp lệ: dùng trong style inline sẽ ném lỗi |
| Cú pháp màu tương đối (`rgb(from red r g b / 50%)`) | — | không (giá trị không hợp lệ) |

## Giá trị, đơn vị, custom property

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| `px`, `%`, `em`, `rem`, `vw`, `vh`, `vmin`, `vmax`, `pt`, `pc`, `in`, `cm`, `mm`, `Q`, `ch`, `ex`, `lh`, `rlh`, `cq*` | core | hỗ trợ (ngữ nghĩa DPR: `vw`/`vh` tính theo điểm ảnh đầu ra) |
| `calc()`, `min()`, `max()`, `clamp()` và các hàm toán học khác | core | hỗ trợ |
| Custom property (`--x`) và `var()` có giá trị dự phòng, trong style inline | core | hỗ trợ |
| `!important` | core | hỗ trợ |

## Stylesheet và selector

Truyền stylesheet qua `css` hoặc thẻ `<style>` trong HTML. Cần profile `standard` hoặc `full`.

- **Selector**: type, universal, class, id, thuộc tính (đủ 7 toán tử, cờ `i` / `s`); combinator
  hậu duệ, `>`, `+`, `~`; danh sách selector; `:root`, `:empty`, `:first-child`, `:last-child`,
  `:only-child`, `:first-of-type`, `:last-of-type`, `:only-of-type`, `:nth-child(An+B [of S])`,
  `:nth-last-child()`, `:nth-of-type()`, `:nth-last-of-type()`, `:not()`, `:is()`, `:where()`, `:has()`,
  `:lang()`, `:dir()`, `:scope`, trạng thái form (`:checked`, `:disabled`, ...). Pseudo-element
  `::before` / `::after` (với `content`, `attr()`).
- Các pseudo-class động (`:hover`, `:focus`, `:visited`, ...) và các pseudo-element khác (`::marker`,
  `::placeholder`, `::first-line`, ...) parse được nhưng không bao giờ khớp.
- **At-rule**: `@media` (`width`, `height`, `aspect-ratio`, `resolution`, `orientation`, cú pháp khoảng,
  `and` / `or` / `not`; so với kích thước canvas tính bằng CSS px), `@supports`, `@layer`, CSS Nesting
  (`&`), `@keyframes`, `@theme` (biến theme của Tailwind), `@import "tailwindcss"` (bật Tailwind
  Preflight). Descriptor của `@font-face` được đọc nhưng font không được tải về. `@page`, `@property`,
  `@container`, `@scope`, `@apply`, `@counter-style` và các at-rule khác bị bỏ qua.
- Khai báo không hợp lệ bị loại bỏ từng cái một (cơ chế phục hồi lỗi của CSS); stylesheet không bao
  giờ làm render ném lỗi.
- **Thứ tự cascade**: luật trong khối `@layer` có tên < utility Tailwind từ `tw` < luật
  stylesheet không thuộc layer < inline `style`; với khai báo `!important` thứ tự đảo lại: không thuộc
  layer < `tw` < layer có tên.
- Text node không có `tagName` không phải là phần tử đối với pseudo-class cấu trúc và combinator anh em
  (`:first-child`, `:nth-child()`, `+`, `~`, ...). Text node rỗng hoặc chỉ có khoảng
  trắng bị bỏ đi, trừ khi đứng sau nội dung inline in-flow (trong flex và grid container thì luôn bị bỏ).
- Chưa hỗ trợ: `counter()` / `counters()` trong `content`, ký hiệu đầu dòng của danh sách.

## Tailwind

`tw` hỗ trợ các nhóm utility Tailwind v4 sau; class chưa hỗ trợ bị bỏ qua:

- **Nhóm utility**: layout và display (`flex`, `grid`, `block`, `hidden`, `contents`, ...),
  position và inset, kích thước (`w-*`, `h-*`, `size-*`, `min-*`, `max-*`, `aspect-*`), khoảng cách
  (`m*-*`, `p*-*`, `gap-*`), flex và grid (`basis-*`, `grow`, `shrink`, `grid-cols-*`, `col-span-*`,
  `items-*`, `justify-*`, `self-*`, ...), chữ (`text-*`, `font-*`, `leading-*`, `tracking-*`,
  `line-clamp-*`, `truncate`, `whitespace-*`, các utility trang trí chữ, `uppercase`, ...), nền (`bg-*`,
  gradient với `from-*` / `via-*` / `to-*`, `bg-linear-*`, `bg-radial`, `bg-conic`), viền và bo góc
  (`border*`, `rounded*`, `outline*`), hiệu ứng (`shadow-*`, `inset-shadow-*`, `text-shadow-*`,
  `opacity-*`, `mix-blend-*`, `bg-blend-*`, `mask-*`), filter và backdrop filter, transform
  (`translate-*`, `rotate-*`, `scale-*`, `origin-*`), `object-*`, `overflow-*`, `list-*`.
- **Giá trị**: theme mặc định (thang khoảng cách, toàn bộ bảng màu với modifier `/opacity`, cỡ chữ,
  bán kính bo, bóng đổ, breakpoint), giá trị tùy ý (`w-[37px]`, `bg-[#123456]`, dấu gạch dưới thay cho
  dấu cách), tiền tố `!important`.
- **Biến `@theme` được utility đọc**: màu (kèm `/opacity`), `--spacing` và `--spacing-*`,
  `--container-*`, `--radius-*`, `--text-*` (kèm biến `--line-height` đi cùng), `--font-*`,
  `--font-weight-*`, `--tracking-*`, `--leading-*`, `--aspect-*`, `--animate-*`, `--breakpoint-*`.
- **`animate-*`** (`animate-spin`, `-ping`, `-pulse`, `-bounce`, `-none`, `animate-[...]`, tên trong theme)
  trên profile `full`, profile có animation.
- **Variant**: breakpoint `sm` `md` `lg` `xl` `2xl` (min-width so với bề rộng canvas), variant cấu trúc
  `first` `last` `only` `odd` `even` `*-of-type` `empty` `not-*` `nth-*` và `[&:...]`,
  `before:` / `after:`.
- **Chưa hỗ trợ**: `hover:`, `focus:`, `dark:`, `group-*:`, `peer-*:`, breakpoint
  `max-*:`; `z-*`, `order-*`, `skew-*`, `ring-*`, `space-x-*` / `space-y-*`, `divide-*`, `place-*`,
  `cursor-*`, `outline-2` đứng một mình, `backdrop-blur` không kèm giá trị, `mask-b-from-50%`; `var()`
  trong giá trị tùy ý (`bg-[var(--x)]`) và shorthand `(--var)`; class `[prop:value]`; tên v3
  `bg-gradient-to-*`; thuộc tính `class` của HTML (chỉ `tw` là Tailwind). Class không biết bị bỏ qua im
  lặng.
- `style` thắng `tw`; utility có tiền tố `!` thắng khai báo inline thường.

## Đầu vào HTML

Mọi chuỗi đầu vào đều được parse như HTML. Cần `standard` hoặc `full`.

- Tokenizer và bộ dựng cây chịu lỗi (cùng tập con thực dụng của thuật toán WHATWG): tự đóng
  thẻ cho `p`, `li`, `dt`/`dd`, `option`, các phần của bảng; tự thêm `tbody`; phần tử void; tham chiếu
  ký tự (dạng số + 338 tên); chế độ fragment và document.
- Áp dụng phần tử `<style>` (kể cả thuộc tính `media`); thuộc tính `style=""`; `class`, `id` và các
  thuộc tính khác cho selector; `dir` và `lang`.
- Style user-agent của Chromium được áp dụng dưới dạng preset (`h1`, `p`, `b`, `ul`, `table`, ...).
- `<img src>` tra trong tùy chọn `images` hoặc dùng URL `data:`; phần tử `<svg>` inline được vẽ như ảnh
  SVG.
- Nội dung `<script>`, `<template>`, comment và nội dung `<head>` không được vẽ; không có gì được thực
  thi hay tải về.
- Chưa cài (cùng chỗ thiếu): adoption agency / dựng lại formatting element, foster
  parenting, MathML, điều khiển form dạng widget.

## Animation

`tw` hỗ trợ các nhóm utility Tailwind v4 sau; class chưa hỗ trợ bị bỏ qua:

Trên `standard`, luật `@keyframes` parse được nhưng animation không được áp dụng; trên `core` thuộc
tính `animation` bị bỏ qua.

## Ảnh và SVG

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| PNG, JPEG (baseline và progressive) | core | hỗ trợ |
| `object-fit`, `object-position`, cắt ảnh theo `border-radius` | core | hỗ trợ |
| WebP lossless, GIF (khung đầu) | standard | có hỗ trợ |
| WebP lossy (VP8; trùng từng bit với libwebp), nguồn GIF / APNG / WebP động | full | trùng các bộ giải mã tham chiếu |
| Ảnh SVG (markup `<svg>`, `data:image/svg+xml`, nền và mask dạng `url()`) | standard | hỗ trợ |
| Phạm vi SVG | standard | hình cơ bản, path, `use` / `symbol`, gradient, pattern, `clipPath`, `mask`, marker, `<svg>` / `<image>` lồng nhau, `<style>` với selector đơn giản, filter `feGaussianBlur`, `feOffset`, `feFlood`, `feColorMatrix`, `feComposite`, `feMerge`, `feBlend`, `feDropShadow`, `feComponentTransfer`. `<text>` được vẽ bằng font đã đăng ký theo mô hình đơn giản (mỗi phần tử một run: `x` / `y`, `font-family`, `font-size`, `font-weight`, `text-anchor`, `fill` màu đặc; nội dung `<tspan>` nối vào run cha với style của cha; chữ tô gradient hoặc chỉ có stroke không được vẽ; xem [Biểu đồ](charts.md#svg-text-hỗ-trợ-những-gì)). Chưa hỗ trợ: `feTurbulence`, `feImage`, `feMorphology`, `feConvolveMatrix`, `feDisplacementMap`, filter chiếu sáng, `feTile`, tham chiếu ra ngoài |
| `image-rendering: pixelated` / `crisp-edges` | core | hỗ trợ |
| URL từ xa | — | không bao giờ tải về: truyền byte qua `images` |

## Chữ phức, bidi, emoji

| Tính năng | Profile tối thiểu | Trạng thái |
|:--|:--|:--|
| Latin, Kirin, Hy Lạp, tiếng Việt (dựng sẵn), ngắt dòng CJK | core | hỗ trợ |
| Bidi (UAX #9), `direction`, `dir`, cô lập `unicode-bidi` | full | 91 679/91 679 ca kiểm tra chuẩn bidi |
| Shaping Ả Rập, Hebrew, Devanagari, Bengali, Thái; chuẩn hoá Unicode (tiếng Việt tổ hợp) | full | hỗ trợ; các hệ chữ Ấn khác dùng shaper mặc định |
| Chuỗi emoji: ZWJ, bộ chỉnh màu da, cờ, cờ dạng tag, keycap, VS15 / VS16 | standard | mỗi chuỗi là một cluster và một glyph (không bao giờ bị tách khi xuống dòng, khi dùng font dự phòng hay khi giãn chữ) |
| Emoji màu (khi đã đăng ký font emoji) | standard (bitmap: CBDT / sbix), full (thêm COLR) | hỗ trợ |

Trên `core` và `standard`, chữ viết phải-sang-trái và chữ phức được shape bằng shaper OpenType mặc định
theo thứ tự logic (không sắp xếp lại).

## Trang giấy (profile `pdf`)

`break-*`, `orphans`, `widows`, `@page`, header bảng lặp lại, `position: fixed` trên mọi trang và
`background-clip: border-area` chỉ áp dụng cho đầu ra PDF; khi render ảnh, chúng được chấp nhận và bỏ qua trên mọi build.
Bảng chi tiết nằm ở [CSS trong PDF](../pdf/css-support.md#paged-media).

## Các hạn chế đã biết

Tình trạng ở 0.1.0 (xem [docs/BENCHMARK.md](../../BENCHMARK.md) để biết trạng thái cuối cùng):

- **Layout inline (hạn chế còn lại)** — khoảng trắng treo của RTL + `white-space: pre-wrap`; line-clamp /
  `-webkit-box` quanh float; block nằm trong một hộp inline `position: relative` không bị dời theo; chuỗi
  inline-block lồng nhau giới hạn khoảng 255 cấp (lỗi "nested too deeply" rõ ràng), trong khi lồng thường
  hỗ trợ 512.
- **Thứ tự vẽ** — đầu ra raster vẽ float và hộp được định vị theo thứ tự của CSS 2.1 Phụ lục E (float sau
  nền của block và trước nội dung inline; hộp định vị sau nội dung in-flow của stacking context của nó);
  `renderSvg` vẫn dùng thứ tự cũ, xấp xỉ, và `z-index` âm vẫn xấp xỉ ở mức anh em.
- **RTL** — `justify-self: left / right` chưa được lật dưới `direction: rtl`; trên `core` và `standard`
  các hộp được lật nhưng chữ bên trong vẫn từ trái sang phải (bidi cần `full`).
- **Pseudo-class cấu trúc trên text node** — `text` node không có `tagName` không phải là phần tử đối với
  `:first-child`, `:nth-child()`, combinator anh em hay các variant Tailwind `first:` / `odd:` / ...
 : nó không được tính là anh em, nên khi có nhiều text node trần cạnh nhau thì node nào cũng
  khớp `first:`, `last:` và `odd:`. Hãy đặt `tagName` cho node hoặc bọc chữ trong container.
- **`text-transform`** — chưa đổi hoa / thường theo `lang` (Thổ Nhĩ Kỳ, Azeri, Hy Lạp, Litva), chưa có
  `full-width` / `full-size-kana`.
- **Chế độ viết dọc** — một luồng dọc chứa bảng, hộp định vị absolute / fixed, `sideways-lr` hoặc cả
  `vertical-rl` lẫn `vertical-lr` sẽ được bố trí theo chiều ngang; chưa có `text-combine-upright: digits`;
  chưa có `text-spacing-trim`; luồng dọc không được chia qua nhiều trang PDF. Chi tiết:
  [Typography](./typography.md#chữ-dọc).
- Chưa hỗ trợ: ký hiệu đầu dòng và counter, transform 3D, `filter: url()` /
  `clip-path: url()`, cú pháp màu tương đối, `outline-offset` theo %, `@apply`, animation trên
  pseudo-element. (Đầu ra PDF chỉ có ở [profile `pdf`](../pdf/index.md) riêng; nó vẽ ký hiệu danh sách trong đầu ra PDF.)
- Các sai khác 1 mức còn lại: phần trong của gradient, viền nét đứt trên góc bo, chữ bị xoay,
  `text-stroke`.

## Phụ lục: danh sách thuộc tính được hỗ trợ

296 tên thuộc tính mà bộ parse style nhận biết, sinh ra từ `src/style/props.zig` (dạng camelCase như
dùng trong object `style` inline; stylesheet dùng dạng kebab-case). Được nhận biết không có nghĩa là
lúc nào cũng đã được cài đặt: xem phần ghi chú ở cuối.

**Display và định vị:** `display`, `position`, `top`, `right`, `bottom`, `left`, `inset`,
`insetBlock`, `insetBlockEnd`, `insetBlockStart`, `insetInline`, `insetInlineEnd`, `insetInlineStart`,
`zIndex`, `float`, `clear`, `visibility`, `overflow`, `overflowX`, `overflowY`, `overflowBlock`,
`overflowInline`, `contain`, `verticalAlign`, `order`, `boxSizing`, `aspectRatio`.

**Kích thước:** `width`, `height`, `minWidth`, `minHeight`, `maxWidth`, `maxHeight`, `inlineSize`,
`blockSize`, `minInlineSize`, `minBlockSize`, `maxInlineSize`, `maxBlockSize`.

**Khoảng cách:** `margin`, `marginTop`, `marginRight`, `marginBottom`, `marginLeft`, `marginBlock`,
`marginBlockStart`, `marginBlockEnd`, `marginInline`, `marginInlineStart`, `marginInlineEnd`,
`padding`, `paddingTop`, `paddingRight`, `paddingBottom`, `paddingLeft`, `paddingBlock`,
`paddingBlockStart`, `paddingBlockEnd`, `paddingInline`, `paddingInlineStart`, `paddingInlineEnd`,
`gap`, `rowGap`, `columnGap`.

**Flexbox và căn chỉnh:** `flex`, `flexBasis`, `flexDirection`, `flexFlow`, `flexGrow`, `flexShrink`,
`flexWrap`, `alignContent`, `alignItems`, `alignSelf`, `justifyContent`, `justifyItems`, `justifySelf`,
`placeContent`, `placeItems`, `placeSelf`, `WebkitBoxOrient`.

**Grid:** `grid`, `gridArea`, `gridAutoColumns`, `gridAutoFlow`, `gridAutoRows`, `gridColumn`,
`gridColumnEnd`, `gridColumnStart`, `gridRow`, `gridRowEnd`, `gridRowStart`, `gridTemplate`,
`gridTemplateAreas`, `gridTemplateColumns`, `gridTemplateRows`.

**Bảng:** `tableLayout`, `borderCollapse`, `borderSpacing`, `captionSide`, `emptyCells`.

**Viền và outline:** `border`, `borderTop`, `borderRight`, `borderBottom`, `borderLeft`,
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

**Nền:** `background`, `backgroundAttachment`, `backgroundBlendMode`, `backgroundClip`,
`backgroundColor`, `backgroundImage`, `backgroundOrigin`, `backgroundPosition`,
`backgroundPositionX`, `backgroundPositionY`, `backgroundRepeat`, `backgroundSize`.

**Mask và cắt:** `clipPath`, `WebkitClipPath`, `mask`, `maskClip`, `maskComposite`,
`maskImage`, `maskMode`, `maskOrigin`, `maskPosition`, `maskRepeat`, `maskSize`, `maskType`,
`WebkitMask`, `WebkitMaskClip`, `WebkitMaskComposite`, `WebkitMaskImage`, `WebkitMaskOrigin`,
`WebkitMaskPosition`, `WebkitMaskRepeat`, `WebkitMaskSize`.

**Hiệu ứng:** `opacity`, `boxShadow`, `filter`, `backdropFilter`, `WebkitBackdropFilter`,
`mixBlendMode`, `isolation`.

**Transform:** `transform`, `transformOrigin`, `translate`, `rotate`, `scale`.

**Ảnh:** `objectFit`, `objectPosition`, `imageRendering`.

**Văn bản:** `color`, `direction`, `unicodeBidi`, `writingMode`, `textOrientation`, `textCombineUpright`, `textAlign`, `textAlignLast`,
`textIndent`, `textTransform`, `textShadow`, `textOverflow`, `textWrap`, `textWrapMode`,
`textWrapStyle`, `whiteSpace`, `whiteSpaceCollapse`, `wordBreak`, `wordSpacing`, `wordWrap`,
`overflowWrap`, `letterSpacing`, `lineHeight`, `lineBreak`, `lineClamp`, `WebkitLineClamp`,
`hyphens`, `WebkitHyphens`, `tabSize`, `textDecoration`, `textDecorationColor`,
`textDecorationLine`, `textDecorationSkipInk`, `textDecorationStyle`, `textDecorationThickness`,
`textUnderlineOffset`, `textUnderlinePosition`, `WebkitTextFillColor`, `WebkitTextStroke`,
`WebkitTextStrokeColor`, `WebkitTextStrokeWidth`, `paintOrder`, `boxDecorationBreak`,
`WebkitBoxDecorationBreak`.

**Font:** `font`, `fontFamily`, `fontSize`, `fontStyle`, `fontWeight`, `fontStretch`,
`fontFeatureSettings`, `fontKerning`, `fontOpticalSizing`, `fontVariant`, `fontVariantCaps`,
`fontVariantEastAsian`, `fontVariantLigatures`, `fontVariantNumeric`, `fontVariantPosition`,
`fontVariationSettings`, `fontSynthesis`, `fontSynthesisSmallCaps`, `fontSynthesisStyle`,
`fontSynthesisWeight`.

**Nội dung sinh ra và danh sách:** `content`, `counterIncrement`, `counterReset`, `counterSet`,
`listStyle`, `listStyleImage`, `listStylePosition`, `listStyleType`.

**Animation và transition:** `animation`, `animationDelay`, `animationDirection`,
`animationDuration`, `animationFillMode`, `animationIterationCount`, `animationName`,
`animationPlayState`, `animationTimingFunction`, `transition`, `transitionBehavior`,
`transitionDelay`, `transitionDuration`, `transitionProperty`, `transitionTimingFunction`.

**Tương tác (nhận để tương thích):** `cursor`, `pointerEvents`, `userSelect`,
`WebkitUserSelect`, `willChange`.

Ghi chú:

- **Nhận nhưng bỏ qua** (giá trị thậm chí không được parse): `backgroundAttachment`, `willChange`,
  `pointerEvents`, `cursor`, `userSelect`, `WebkitUserSelect`, `transitionBehavior`, `maskComposite`,
  `WebkitMaskComposite`.
- **Parse được nhưng chưa có tác dụng thấy được trong 0.1.0** (xác định bằng cách kiểm tra renderer đọc
  những giá trị computed nào): `hyphens` / `WebkitHyphens`, `lineBreak`, `textAlignLast`,
  `unicodeBidi`, `fontSynthesisWeight` / `fontSynthesisStyle` và phần weight / style của `fontSynthesis`
  (luôn tự tạo đậm / nghiêng; việc tự tạo small caps thì theo `fontSynthesis` / `fontSynthesisSmallCaps`), `counterReset` / `counterIncrement` / `counterSet`,
  `listStyle*` (không có ký hiệu đầu dòng), `transition*`, `paintOrder` trên chữ (bị bỏ qua).
- Thuộc tính của một tính năng bị loại khỏi profile đang nạp được chấp nhận và bỏ qua (ví dụ `float`
  trên `core`), trừ các giá trị cần bộ parse không có mặt (hàm màu hiện đại trên `core`), vốn bị coi là
  không hợp lệ.
- Mọi khoá khác đều bị bỏ qua im lặng, kể cả khoá kebab-case trong object `style` inline.


## Xem thêm

Các trang hướng dẫn đi sâu vào từng chủ đề, kèm ví dụ chạy được và ảnh kết quả:
[Khái niệm](concepts.md) · [Style và layout](styles.md) · [HTML và Tailwind](html-and-tailwind.md) ·
[Font](fonts.md) · [Typography](typography.md) · [Ảnh](images.md) · [Bảng và float](tables.md) ·
[Hiệu ứng](effects.md) · [Định dạng đầu ra](formats.md) · [Animation](animation.md) · [measure()](measure.md) ·
[Biểu đồ](charts.md) · [Mẫu](templates.md) · [Hiệu năng](performance.md)
