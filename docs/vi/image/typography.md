# Typography

[English](../../en/image/typography.md) · [Tiếng Việt](typography.md)

bm-render dàn trang và vẽ chữ như thế nào: xuống dòng và `white-space`, ngắt từ dài, chiều cao dòng và
khoảng cách, căn lề, cắt bớt bằng dấu ba chấm và `line-clamp`, tiêu đề cân dòng, trang trí chữ, đổ bóng
và viền chữ, đổi hoa thường, trộn span, inline-block và ảnh trong cùng một dòng, các feature OpenType, chữ
dọc (`writing-mode`), và
[profile](../profiles-and-size.md) nào cần cho chữ hai chiều và hệ chữ phức tạp. Chữ cần một font đã đăng
ký: hãy đọc [Font](./fonts.md) trước. Mọi ví dụ đều được chạy bởi `docs/examples/typography.mjs` và ảnh
minh hoạ là kết quả của nó.

[[toc]]

## Phần chuẩn bị dùng trong trang này

Các ví dụ dùng chung một renderer và ba hàm nhỏ để tạo node. `sample()` vẽ một nhãn màu xám và một khung
viền để bạn thấy hộp chữ kết thúc ở đâu:

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

Text node hoạt động như một `<span>`: nó kế thừa `fontFamily`, `fontSize`, `color` và mọi thuộc tính chữ
khác từ các node tổ tiên, nên bạn có thể đặt chúng một lần trên container.

## Xuống dòng và `white-space`

Chữ xuống dòng ở các cơ hội ngắt (dấu cách, gạch nối, sau phần lớn dấu câu, giữa các ký tự CJK; theo
Unicode UAX #14) khi chạm tới chiều rộng của hộp. `white-space` quyết định có giữ dấu cách và ký tự xuống
dòng hay không, và có tự xuống dòng hay không:

<!-- @example typography#white-space -->
```js
const para = "Text  wraps   at spaces.\nA newline here.";
const whiteSpace = renderer.renderSync(
  page({}, ["normal", "nowrap", "pre", "pre-wrap", "pre-line"].map((ws) =>
    sample(ws, { whiteSpace: ws, width: 140, height: 110, overflow: "hidden" }, [text(para)]))),
  { width: 790, height: 160 },
);
```

![normal gộp dấu cách và tự xuống dòng; nowrap giữ một dòng; pre giữ dấu cách và xuống dòng nhưng không tự ngắt; pre-wrap giữ cả hai và tự ngắt; pre-line chỉ giữ ký tự xuống dòng](/img/guide/typography-white-space.png)

| `whiteSpace` | Gộp dấu cách | Giữ `\n` | Tự xuống dòng |
|:--|:-:|:-:|:-:|
| `normal` (mặc định) | có | không | có |
| `nowrap` | có | không | không |
| `pre` | không | có | không |
| `pre-wrap` | không | có | có |
| `pre-line` | có | có | có |

Các longhand `whiteSpaceCollapse` và `textWrapMode` cũng được hỗ trợ, và `tabSize` đặt độ rộng của ký tự
tab trong khoảng trắng được giữ nguyên.

## Ngắt từ dài và URL

Mặc định, một từ dài hơn dòng sẽ tràn ra khỏi hộp. `overflowWrap: "anywhere"` (hoặc `"break-word"`) chỉ
ngắt nó khi không vừa, `wordBreak: "break-all"` ngắt giữa hai chữ cái bất kỳ, còn dấu gạch nối mềm
(U+00AD) trong văn bản đánh dấu chỗ một từ có thể được ngắt kèm gạch nối:

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

![Một URL bị cắt, một URL ngắt ở bất kỳ đâu, các từ ngắt ở chữ cái bất kỳ, và các từ được ngắt ở dấu gạch nối mềm](/img/guide/typography-breaking.png)

`wordBreak: "keep-all"` giữ các từ CJK liền nhau. `hyphens: "auto"` được parse nhưng không có từ điển
ngắt âm tiết: chỉ dấu gạch nối mềm mới sinh ra gạch nối.

## Chiều cao dòng và khoảng cách

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

![Chiều cao dòng mặc định, đoạn văn với line height 1.8, letter spacing 4px và -0.05em, và word spacing](/img/guide/typography-spacing.png)

- `lineHeight` nhận một số (bội số của cỡ chữ, nên dùng: nó được kế thừa dưới dạng hệ số), một độ dài
  (`24`, `"1.5rem"`) hoặc `"normal"` (mặc định: ascent + descent + line gap của font, nên khác nhau giữa
  các font).
- `letterSpacing` và `wordSpacing` nhận độ dài, kể cả `em`. Tracking âm thường dùng cho tiêu đề lớn, đậm.

## Căn lề

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

![Cùng một đoạn văn căn trái, căn giữa, căn phải và căn đều hai bên](/img/guide/typography-align.png)

`textAlign` nhận `left`, `right`, `center`, `justify`, `start` và `end` (hai giá trị cuối đi theo
`direction`). Đoạn căn đều sẽ giãn mọi dòng trừ dòng cuối.

## Thụt dòng đầu

`textIndent` thụt dòng đầu tiên của block container: một độ dài, phần trăm bề rộng container, hoặc giá
trị âm (thụt ra ngoài; hãy thêm padding để chữ vẫn nằm trong). Từ khoá `hanging` (thụt mọi dòng trừ
dòng đầu) và `each-line` (thụt cả sau các lần xuống dòng bắt buộc) cũng dùng được, và trong đoạn từ phải
sang trái thì khoảng thụt nằm bên phải:

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

![Bốn đoạn văn: thụt 24 px, thụt 10 %, thụt ra ngoài 16 px, và thụt treo 24 px](/img/guide/typography-indent.png)

Chỉ dòng đầu của block được thụt. `textAlignLast` được parse nhưng không có tác dụng.

## Cắt bớt: dấu ba chấm và line clamp

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

![Dấu ba chấm trên một dòng, clamp hai dòng, clamp ba dòng theo cú pháp webkit cũ, và cắt thẳng](/img/guide/typography-truncation.png)

- **Một dòng**: `textOverflow: "ellipsis"` chỉ hoạt động khi đi kèm `overflow: "hidden"` và một dòng không
  tự xuống dòng (`whiteSpace: "nowrap"`), giống trình duyệt.
- **Nhiều dòng**: `lineClamp: n` trên một block container sẽ cắt sau `n` dòng và kết thúc dòng cuối bằng
  dấu ba chấm. Dạng cũ `display: "-webkit-box"` + `WebkitBoxOrient: "vertical"` + `WebkitLineClamp: n`
  cho cùng kết quả. Hãy đặt clamp lên một block (hoặc lên text node nằm trong flex container, vốn đã được
  blockify), không đặt lên flex container.
- Chữ bị cắt do `height` cố định thì không có dấu ba chấm; hãy dùng `lineClamp`.

### Ký hiệu tuỳ chỉnh

`textOverflow` cũng nhận một chuỗi, được vẽ thay cho dấu ba chấm: chuỗi được shape bằng font của phần tử
(và các font dự phòng) và được lật ngược trong đoạn từ phải sang trái. Chuỗi rỗng cắt chữ mà không có ký
hiệu. `lineClamp` nhận ký hiệu riêng theo dạng `<n> "<chuỗi>"` (cú pháp `block-ellipsis` của CSS; `none`
và `no-ellipsis` cũng được chấp nhận); dòng bị clamp dùng ký hiệu đó, hoặc dấu ba chấm mặc định, chứ không
dùng chuỗi của `textOverflow`. `overflow: "hidden"` cắt cả glyph của chính phần tử, nên
`textOverflow: "clip"` thật sự cắt ngang một chữ cái:

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

![Một dòng kết thúc bằng ký hiệu », một clamp hai dòng kết thúc bằng [more], một dòng bị cắt không ký hiệu, và một dòng từ phải sang trái có ký hiệu « lật ngược ở bên trái](/img/guide/typography-overflow-string.png)

## Tiêu đề cân dòng

`textWrap: "balance"` cân lại độ dài các dòng của một đoạn ngắn, tránh để một từ đứng lẻ loi ở dòng cuối
tiêu đề. Nó cần `standard` hoặc `full` (`features.textWrapBalance`); `core` xuống dòng bình thường.

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

![Xuống dòng tham lam để "browser" một mình ở dòng cuối; balance cho ba dòng đều nhau](/img/guide/typography-balance.png)

`textWrap: "pretty"` hiện thường cho kết quả xuống dòng như chế độ thông thường. Kiểm tra bằng nội dung thật nếu cần kiểm soát chính xác cách ngắt dòng.

## Trang trí chữ

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

![Gạch dưới, gạch trên kèm gạch ngang, gạch dưới lượn sóng màu đỏ, gạch dưới chấm xanh dày có khoảng cách, và gạch dưới có và không có skip-ink](/img/guide/typography-decoration.png)

`textDecoration` là shorthand của `textDecorationLine` (`underline`, `overline`, `line-through`),
`textDecorationStyle` (`solid`, `double`, `dotted`, `dashed`, `wavy`), `textDecorationColor` và
`textDecorationThickness`. `textUnderlineOffset` dịch đường gạch dưới, `textUnderlinePosition: "under"`
đặt nó dưới phần chân chữ, còn `textDecorationSkipInk` (mặc định `auto`) ngắt đường gạch quanh phần chân
chữ, như hai dòng cuối cho thấy.

## Đổ bóng, viền chữ và chữ gradient

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

![Chữ có bóng cam sắc nét, quầng sáng tím, chữ chỉ có viền, chữ tô vàng viền nâu, và chữ gradient hồng sang tím](/img/guide/typography-effects.png)

- `textShadow` nhận một hoặc nhiều lớp `offsetX offsetY blur color`, ngăn cách bằng dấu phẩy.
- `WebkitTextStroke` (`"độ-dày màu"`) vẽ viền glyph; `WebkitTextFillColor` ghi đè màu tô (dùng
  `"transparent"` để có chữ rỗng).
- Chữ gradient: một ảnh nền được cắt theo glyph bằng `backgroundClip: "text"` cùng `color` trong suốt.
  `background-clip: text` cần `standard` hoặc `full`.

::: info `paint-order` bị bỏ qua
`paintOrder: "stroke"` được parse, nhưng viền luôn được vẽ đè lên phần tô. Vì vậy viền
dày sẽ ăn vào nét chữ; hãy giữ viền mảnh hoặc dùng `textShadow` để tạo viền.
:::

## Chữ hoa, chữ thường

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

![Tiếng Việt có dấu viết hoa, viết hoa chữ cái đầu mỗi từ và viết thường](/img/guide/typography-transform.png)

`textTransform` dùng ánh xạ hoa / thường Unicode đầy đủ: tiếng Việt và các chữ có dấu khác (`đ` → `Đ`),
`ß` → `SS`, ligature như `ﬁ` → `FI`, sigma cuối từ của tiếng Hy Lạp, digraph titlecase. Chưa có: đổi
hoa / thường theo `lang` (chữ i có chấm của tiếng Thổ Nhĩ Kỳ và Azeri, dấu tiếng Hy Lạp, tiếng Litva) và
các giá trị `full-width` / `full-size-kana`.

### Chữ hoa nhỏ {#small-caps}

`fontVariantCaps` (hoặc `fontVariant`) chọn chữ hoa nhỏ: `small-caps`, `all-small-caps`, `petite-caps`,
`all-petite-caps`, `unicase` và `titling-caps`. Khi font có các feature OpenType (`smcp`, `c2sc`, ...) thì
chúng được dùng; nếu không, chữ hoa nhỏ được **tự tạo** từ chữ hoa ở 70 % cỡ chữ, giống Chrome. Petite caps
và unicase quay về small caps. `fontSynthesisSmallCaps: "none"` tắt việc tự tạo:

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

![Chữ thường, small caps tự tạo, all-small-caps, và lại là chữ thường vì đã tắt tự tạo](/img/guide/typography-small-caps.png)

## Trộn nội dung inline

Container không có `display` là **inline**, giống một `<span>`: đặt nhiều text node và inline container
vào một block (hoặc một flex item) thì chúng chảy cùng nhau trên các dòng và xuống dòng như một đoạn văn.
Inline container có thể có font, màu, nền, padding và bo góc riêng. `display: "inline-block"` tạo một hộp
nguyên khối nằm trên dòng, và image node cũng là inline:

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

![Một đoạn văn xuống dòng có chữ đậm và nghiêng, một span được tô sáng, một badge xanh, một ảnh chấm xanh lá và chữ chỉ số trên](/img/guide/typography-inline.png)

- `verticalAlign` (`baseline`, `middle`, `top`, `bottom`, `text-top`, `text-bottom`, `super`, `sub`, độ dài
  và phần trăm) định vị inline box và ảnh trên dòng.
- Padding, border và margin theo chiều ngang của span đẩy chữ bên cạnh; padding theo chiều dọc được vẽ
  nhưng không đổi chiều cao dòng (giống CSS).
- Bên trong **flex** container mọi con đều được blockify, nên một hàng text node trong flex container trở
  thành các flex item riêng chứ không phải một đoạn văn. Hãy bọc nội dung trộn lẫn trong một container
  `display: "block"`.

## Feature OpenType

Mặc định bm-render áp dụng các feature GSUB / GPOS của font (kerning, ligature, contextual alternate, định
vị dấu). CSS điều khiển chúng:

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

![Chữ số tỉ lệ và chữ số bằng nhau, số 0 có gạch và chữ số thay thế của Inter, ligature Roboto bật và tắt, kerning bật và tắt](/img/guide/typography-features.png)

| Thuộc tính | Ví dụ | Tác dụng |
|:--|:--|:--|
| `fontFeatureSettings` | `"'tnum', 'ss01' 1, 'liga' 0"` | bật hoặc tắt bất kỳ feature nào |
| `fontVariantNumeric` | `"tabular-nums"`, `"oldstyle-nums"`, `"slashed-zero"`, `"diagonal-fractions"` | feature cho chữ số |
| `fontVariantLigatures` | `"none"`, `"no-common-ligatures"`, `"discretionary-ligatures"` | ligature |
| `fontVariantCaps` | `"small-caps"`, `"all-small-caps"` | feature chữ hoa nhỏ, tự tạo khi font không có ([ở trên](#small-caps)) |
| `fontVariantPosition` | `"super"`, `"sub"` | `sups` / `subs` |
| `fontKerning` | `"none"` | tắt kerning |

Đo với Inter cỡ 40 px: `AV To Wa` rộng 181,5 px khi có kerning và 189,4 px khi không; `fi fl ffi` của
Roboto rộng 100,7 px khi có ligature và 104,5 px khi không. Feature chỉ có tác dụng khi font có nó.

## Tiếng Việt

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

![Tiếng Việt đủ sáu thanh, một đoạn văn được cân dòng và một cái tên màu đỏ](/img/guide/typography-vietnamese.png)

Tiếng Việt dựng sẵn (NFC) hoạt động trên mọi profile với bất kỳ font nào có đủ chữ (Inter, Noto Sans,
Roboto, Be Vietnam Pro, ...). Văn bản ở dạng tổ hợp (NFD, hay gặp khi nhập từ macOS) phụ thuộc vào việc
định vị dấu của font và chỉ được tự chuẩn hoá trên `full`; hãy gọi `normalize("NFC")` với dữ liệu người
dùng cho chắc. Dòng được ngắt ở dấu cách, đúng với những gì tiếng Việt cần.

## Chữ dọc

`writingMode: "vertical-rl"` (sách tiếng Nhật, tiếng Trung, tiếng Hàn) và `"vertical-lr"` (tiếng Mông Cổ,
một số tiêu đề) xoay một khối sang dọc: các dòng chạy từ trên xuống dưới và xếp từ phải sang trái
(`vertical-rl`) hoặc từ trái sang phải (`vertical-lr`). `"sideways-rl"` là `vertical-rl` với mọi ký tự
đều được xoay. Tính năng có trên mọi profile, ở đầu ra PNG / JPEG / WebP, `renderSvg` và PDF.

```js
// Noto Sans TC (hoặc font CJK bất kỳ có metric dọc) đã đăng ký với tên "Noto Sans TC"
const vertical = renderer.renderSync(
  `<!doctype html><html><body style="margin:0;font-family:'Noto Sans TC';font-size:20px">
    <div style="writing-mode:vertical-rl;height:200px;padding:10px;line-height:1.5;background:#eef">
      日本語の書き方。CSS 2024年、ABC と 123 を含む。<span style="color:#c00">赤い文字</span>
    </div>
  </body></html>`,
  { width: 300, height: 240 },
);
```

Những gì được hỗ trợ:

- **Hướng ký tự** (`textOrientation`). `mixed` (mặc định) đặt đứng các chữ Hán, kana, Hangul, ký tự
  toàn độ rộng và các ký tự khác mà Unicode cho hướng dọc đứng (UAX #50, xấp xỉ theo các khoảng mã), còn
  chữ Latin, chữ số và phần còn lại được xoay 90 độ theo chiều kim đồng hồ. `upright` đặt đứng mọi ký tự,
  `sideways` xoay mọi ký tự. Ký tự đứng được shape với feature `vert` của font (dấu câu dọc như `、` `。`
  `「」` `（）`), tiến theo độ tiến dọc (`vhea` / `vmtx`) và treo từ gốc dọc (`VORG`, nếu không có thì
  `vmtx` + hộp glyph); font không có metric dọc thì dùng chiều cao font và hộp em căn giữa dòng, như Chrome.
- **Tate-chu-yoko** (`textCombineUpright: "all"` trên một span): chữ của span (`"12"`, `"2024"`, `"!?"`)
  được đặt ngang trong một ô em đứng, bị nén theo chiều ngang khi rộng hơn, và căn giữa dòng.
- **Nội dung inline**: cỡ chữ, màu, span có nền, viền và padding, trang trí chữ (`underline` vẽ ở bên
  trái, phía dưới dòng), `text-align` dọc theo dòng (`start` = trên, `end` = dưới, `center`),
  `text-indent`, `line-height`, xuống dòng và mọi giá trị `white-space` / `word-break`, inline-block và
  ảnh trong dòng.
- **Hộp**: padding, viền, nền và margin của hộp dọc và của các khối con, xếp theo trục khối (từ phải sang
  trái với `vertical-rl`); container flex và grid bố trí theo trục logic (`flex-direction: row` chạy từ
  trên xuống dưới); `float: left` / `right` nghĩa là đầu / cuối dòng (trên / dưới). Thuộc tính logic
  (`marginBlockStart`, `paddingInlineStart`, `inlineSize`, `borderBlockEnd`, ...) được ánh xạ theo
  chế độ viết.
- **Luồng trực giao** (CSS Writing Modes 4 §7): một hộp dọc trong trang ngang (tiêu đề dọc cạnh văn bản
  ngang) rộng bằng các dòng của nó và cao bằng nội dung, tối đa bằng chiều cao xác định của phần tử cha,
  nếu không thì bằng chiều cao viewport; hộp ngang nằm trong hộp dọc lấy chiều rộng theo cách tương tự từ
  chiều rộng viewport. `writing-mode` đặt trên `<body>` áp dụng cho cả tài liệu (phần tử gốc nhận nó, như
  trình duyệt), nên `<body style="writing-mode:vertical-rl">` bắt đầu ở góc trên bên phải.
- **PDF**: các dòng xoay là văn bản theo thứ tự nội dung. Ký tự đứng được vẽ bằng đường viền glyph, phía
  trên có một bản sao vô hình của văn bản dòng theo hướng của dòng, để sao chép và trích xuất văn bản đi
  theo dòng: `pdftotext` đọc trang `vertical-rl` theo từng cột từ phải sang; với `vertical-lr`, chế độ
  đọc theo bố cục của nó cũng liệt kê các cột từ phải sang (`pdftotext -raw` giữ thứ tự logic ở cả hai
  chế độ).

So với Chrome (`npm run test:writing-mode`: Noto Sans TC, ảnh chụp Chrome ở device scale 1). Hình chữ nhật
của các phần tử trong các fixture khối, luồng trực giao và thuộc tính logic trùng với Chrome; "khác biệt"
là tỉ lệ điểm ảnh có độ sáng lệch hơn 48 sau khi làm mờ 3 x 3 (bỏ qua khử răng cưa), phần lớn do vị trí
glyph dưới mức điểm ảnh:

| Fixture | Điểm ảnh khác biệt |
|:--|--:|
| `vertical-rl`, CJK + Latin + chữ số, padding, nền | 0.47 % |
| `vertical-rl` trên `<body>` (một trang văn bản) | 2.29 % |
| `vertical-lr`, viền | 0.05 % |
| `text-orientation: upright` / `sideways` | 0.05 % / 0.00 % |
| tiêu đề dọc trong trang ngang | 0.19 % |
| span: màu, nền, gạch chân, cỡ chữ lớn hơn | 2.47 % |
| `text-align` theo từng đoạn | 0.00 % |
| `text-combine-upright` (`12`, `2024`, `!?`) | 1.16 % (xem phần giới hạn) |
| tiếng Trung với dấu câu toàn độ rộng | 3.01 % (Chrome thu gọn `。（`) |
| hộp ngang trong trang dọc | 0.90 % |
| khối con, thuộc tính logic, flex | 0.69 %, 0.38 %, 0.27 % |

Giới hạn:

- Một luồng dọc chứa bảng, hộp định vị absolute / fixed, `sideways-lr`, hoặc cả `vertical-rl` lẫn
  `vertical-lr` sẽ được bố trí theo chiều ngang (các thuộc tính logic của nó vẫn giữ ánh xạ dọc).
- Chưa hỗ trợ `textCombineUpright: "digits <n>"`, và khối kết hợp được nén bằng cách co giãn thay vì dùng các
  dạng nửa / một phần ba / một phần tư độ rộng của font (`hwid`, `twid`, `qwid`) mà Chrome thử trước; Chrome
  cũng đặt khối lệch sang phải tâm dòng vài điểm ảnh.
- `text-spacing-trim` của Chrome (dấu câu toàn độ rộng liền nhau như `。（` được đặt nửa độ rộng) không
  được áp dụng, kể cả với văn bản ngang.
- Các đoạn chạy khác font hoặc cỡ chữ trên cùng một dòng căn theo đường cơ sở alphabetic, không phải
  đường trung tâm mà Chrome dùng cho chữ dọc (lệch vài điểm ảnh với font dự phòng hoặc span lớn hơn).
- `underline` luôn ở bên trái; Chrome vẽ nó bên phải với `lang="ja"` / `"ko"`.
- Luồng dọc không được chia qua nhiều trang PDF; `text-shadow` trên ký tự đứng không được vẽ trong đầu ra
  PDF, và `background-clip: text` không theo chữ dọc.
- Padding và margin dạng phần trăm của hộp trực giao được tính theo trục inline của chính nó.
- Đường cơ sở của inline-block dọc trong dòng ngang là cạnh dưới của margin box.

## Chữ hai chiều và hệ chữ phức tạp

Profile `full` chạy thuật toán hai chiều của Unicode (UAX #9) và các bộ shaping phức tạp cho tiếng Ả Rập,
Do Thái, Devanagari, Bengali và Thái. Hướng gốc lấy từ `direction: "rtl"` trong style hoặc `dir: "rtl"`
trên node. Chữ CJK được ngắt giữa các ký tự. Repository này không có font cho các hệ chữ đó; ví dụ dùng
các file WOFF2 bạn chuẩn bị trong thư mục `fonts/`:

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

![Trên full: tiếng Ả Rập được nối chữ và đặt từ phải sang trái trong một dòng tiếng Anh, một đoạn RTL căn phải, và chữ Hán xuống dòng giữa các ký tự](/img/guide/typography-scripts.png)

Cùng cây node trên `standard`: chữ Ả Rập không được nối, không có gì được sắp xếp lại và đoạn RTL được
dàn từ trái sang phải. CJK và các hệ chữ không cần sắp xếp lại thì trông giống nhau:

![Trên standard: chữ Ả Rập rời rạc và theo thứ tự logic, đoạn RTL căn trái](/img/guide/typography-scripts-standard.png)

| Hệ chữ / tính năng | core | standard | full |
|:--|:-:|:-:|:-:|
| Latin, Kirin, Hy Lạp, tiếng Việt (NFC) | có | có | có |
| CJK (ngắt dòng giữa các ký tự) | có | có | có |
| Kerning, ligature, feature OpenType | có | có | có |
| `text-wrap: balance / pretty` | không | có | có |
| Sắp xếp hai chiều, `direction`, `dir`, `unicode-bidi` | không | không | có |
| Shaping Ả Rập / Do Thái / Ấn Độ / Thái | shaper mặc định | shaper mặc định | có |
| Chuẩn hoá Unicode (tiếng Việt NFD) | không | không | có |
| Chuỗi emoji (ZWJ, màu da, cờ, keycap) thành một glyph | không | có | có |
| Emoji màu | không | font bitmap (CBDT / sbix) | có (kèm font màu) |

`direction: rtl` cũng lật ngược hàng flex, cột grid và bảng (xem [Style](./styles.md#right-to-left)). Các
hạn chế đã biết (cũng có trong [Hỗ trợ CSS](./css-support.md#các-hạn-chế-đã-biết)): khoảng trắng treo của
chữ RTL với `white-space: pre-wrap` chưa được xử lý. Chữ dọc: xem [Chữ dọc](#chữ-dọc).

## Thuộc tính không có tác dụng trong 0.1.0

Được parse và chấp nhận nhưng không có hiệu ứng nhìn thấy: `textAlignLast`, `hyphens` (trừ dấu gạch nối
mềm trong văn bản), `lineBreak`, `fontSynthesisWeight` / `fontSynthesisStyle` và phần weight /
style của `fontSynthesis` (đậm và nghiêng luôn được tự tạo), và `paintOrder` trên chữ (bị bỏ qua; ảnh SVG thì có tôn trọng). Danh sách đầy đủ các thuộc tính được hỗ trợ
nằm ở [Hỗ trợ CSS](./css-support.md#văn-bản).

Xem thêm: [Font](./fonts.md), [measure()](./measure.md) để co chữ vừa một hộp,
[Hiệu ứng](./effects.md) cho các hiệu ứng vẽ khác.
