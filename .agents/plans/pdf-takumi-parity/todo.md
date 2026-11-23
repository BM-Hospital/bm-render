# Task list: bm-engine PDF / Takumi parity

Trạng thái tổng: **needs review — chưa hoàn tất**. Đã có implementation và regression checks cho nhiều nhóm; task 16–17 đang triển khai một phần, task 18–21 chưa hoàn tất. Không đánh dấu hoàn thành theo số golden render thành công.

Checkpoint 2026-11-13: Zig 664/664; PDF API 389/389 và focused source-reference 73/73 trên cả native/WASM; 136 golden gồm 123 IDENTICAL, 9 CLOSE, 4 DIFFER, 0 render error, structure/parent tree 136/136. Validator chọn 16 tài liệu: byte identity 16/16, semantics 16/16, veraPDF 14/14 mỗi backend, 0 bm-only issue (6 pdfcpu issue giống reference). Gate parity tổng chưa sạch. Chưa chạy benchmark theo yêu cầu chỉ đo sau khi hoàn tất implementation và gate pass.

## 00 — Lập bảng ánh xạ test và chức năng (P0)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Đối chiếu toàn bộ test PDF upstream với adapter Zig/JS; phân loại implementation, partial, missing, deliberate và chưa kiểm chứng.

**Tiêu chí nghiệm thu:**

- [ ] Không dùng 136 golden làm mẫu số toàn bộ tính năng PDF; kiểm kê cả 272 khai báo test Rust trong takumi-pdf, test JS và window/stream/memory.
- [ ] Mỗi case có nguồn, runner tương ứng hoặc lý do không áp dụng; không còn case chưa phân loại.
- [ ] Cập nhật trạng thái cũ: paged-rotated-text đã sửa, named pages đã có; giữ lịch sử audit riêng.

**Kiểm tra:** Kiểm tra manifest và coverage map; đối chiếu tên test/fixture với corpus; runner phải báo case chưa ánh xạ.

**Phụ thuộc:** Không. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** scripts/takumi-test-corpus.mjs; docs/PDF_AUDIT.md; scripts/pdf-coverage-map.json (mới).

## 01 — Cố định oracle và cơ chế kiểm tra sai khác (P0)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Đảm bảo các case ngoài golden so với đúng Takumi ff9a5d4, không lấy npm 0.20.0 làm oracle duy nhất.

**Tiêu chí nghiệm thu:**

- [ ] Ghi revision, backend, font và phiên bản công cụ trong báo cáo; khi thiếu reference phải báo UNVERIFIED.
- [ ] Ngoại lệ chỉ theo fixture và loại sai khác, có lý do; không miễn trừ toàn bộ PDF hoặc nới tolerance chung.
- [ ] --strict phải thất bại khi có lỗi mới; kiểm tra page content, page count/box, text, links, tags, font mapping riêng.

**Kiểm tra:** Chạy baseline 136 golden trên wasm; đối chiếu một số case với native; thử một sai khác mới để chứng minh gate thất bại.

**Phụ thuộc:** 00. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** scripts/pdf-compare.mjs; scripts/pdf-audit/lib.mjs; scripts/pdf-audit/run.mjs; scripts/pdf-coverage-map.json.

## 02 — Thiết kế fragment và vòng đời trang (P0)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Làm spike thiết kế cho phần rủi ro cao trước khi port sâu: tọa độ layout/paint, fragment decorations, trang ổn định, lifetime metadata và bộ nhớ.

**Tiêu chí nghiệm thu:**

- [ ] Có mô hình fragment xuyên transform/clip và cách tiếp tục layout của table/flex/grid/float; tránh sửa tọa độ bằng offset cục bộ theo fixture.
- [ ] Xác định khi nào được emit/release một trang, khi nào phải giữ trang vì transform, positioned descendants hoặc counter chưa ổn định.
- [ ] Ghi benchmark 1/10/100/500 trang và instrument live bytes; chốt các interface trước task 03, 16–21.

**Kiểm tra:** Review thiết kế bằng window_scenes.rs, streaming_tests.rs, memory_tests.rs; thử prototype nhỏ, chưa thay kiến trúc toàn bộ.

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** docs/PDF_FRAGMENT_DESIGN.md (mới); src/pdf/paged.zig; src/layout/fragment.zig; scripts/pdf-scaling.mjs.

## 03 — Chia decoration của box transform qua trang (P0)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Port per-fragment box geometry và transform origin cho rotate/skew/scale; bảo toàn paint order và nội dung con.

**Tiêu chí nghiệm thu:**

- [ ] paged-transforms hết sai khác chưa được chấp nhận; giữ paged-rotated-text ở CLOSE hoặc IDENTICAL.
- [ ] Box có border/radius, nested transform, clone/slice được cắt đúng và không mất hoặc vẽ lặp text/link.
- [ ] Không ghi tạm layout toàn cục hoặc special-case theo tên fixture.

**Kiểm tra:** Golden paged-transforms, paged-rotated-text, translated/overflow/clip stitched; thêm nested transform và border-radius.

**Phụ thuộc:** 02. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit.zig; src/layout/fragment.zig; src/pdf/filelayer_tests.zig; scripts/pdf-compare-more.mjs.

## 04 — Sửa clip ở ranh giới trang (P0)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Đối chiếu phần overflow/clip còn lệch, nhất là clip của stitched box và descendant thoát containing block.

**Tiêu chí nghiệm thu:**

- [ ] paged-clipped-overflow hết sai khác chưa được chấp nhận; không làm hỏng các golden clipped-line đã qua.
- [ ] Pixel và text layer thống nhất: phần bị che không lộ trong text layer, phần còn thấy vẫn selectable.
- [ ] Có case nested clip, transformed ancestor và line bị cắt baseline.

**Kiểm tra:** Chạy golden overflow/clip, extracted-text và raster diff dưới cùng rasterizer; chọn file probe thực tế theo coverage map.

**Phụ thuộc:** 03. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit.zig; src/pdf/emit_text.zig; src/pdf/filelayer_tests.zig; scripts/pdf-audit/pagination-layout.probe.mjs.

## 05 — Sửa marked content và structure parent qua trang (P0)

**Trạng thái:** needs review — structure/parent mapping đã khớp; còn thứ tự region rỗng của monolithic overflow.

Port quy tắc mở/đóng region theo fragment thay vì sinh region rỗng không cần thiết.

**Tiêu chí nghiệm thu:**

- [ ] paged-monolithic-overflow khớp structure tree/parent tree hoặc có chứng cứ ngoại lệ cụ thể.
- [ ] MCID không trùng, parent mapping hợp lệ cho split box, repeats, empty inline và out-of-flow.
- [ ] PDF/UA, ActualText và thứ tự đọc giữ nguyên trên các fixture trước đó đã qua.

**Kiểm tra:** Compare struct/parents, pdf.js extraction/structure; chạy các fixture tagged UA1/UA2/A2a và validator khi có tool.

**Phụ thuộc:** 04. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_tag.zig; src/pdf/tags.zig; src/pdf/emit_text.zig; src/pdf/filelayer_tests.zig.

## 06 — Sửa fragment background của inline span (P0)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Sửa extents và cách chia nền ảnh/gradient của inline box qua nhiều dòng.

**Tiêu chí nghiệm thu:**

- [ ] inline-span-background-image hết sai khác ngoài tolerance.
- [ ] slice/clone, span có padding/border và span qua trang có case riêng.
- [ ] Không tạo thêm hoặc làm mất vùng nền ở line break.

**Kiểm tra:** Golden inline-span-background-image, inline-span-border, box-decoration-break-clone; raster diff các case mới.

**Phụ thuộc:** 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_text.zig; src/paint_text.zig; scripts/pdf-audit/paint.probe.mjs.

## 07 — Sửa mask background-clip text (P0)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Đối chiếu glyph placement của span lồng nhau và độ vươn của mask.

**Tiêu chí nghiệm thu:**

- [ ] inline-span-background-clip-text-nested và background-clip-text-reach hết sai khác chưa được chấp nhận.
- [ ] Mask áp đúng descendant, decoration và clip ancestor; không ảnh hưởng ToUnicode/ActualText.
- [ ] Không đổi glyph advance chỉ để khớp mask; kiểm tra riêng layout và paint.

**Kiểm tra:** Golden hai case mục tiêu; regression clip-text-stroke, nested spans, opacity, transform và page cut.

**Phụ thuộc:** 06. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_text.zig; src/pdf/text.zig; scripts/pdf-audit/paint.probe.mjs.

## 08 — Port text của input (P0)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Đưa value, placeholder và password presentation qua DOM → text layout → PDF.

**Tiêu chí nghiệm thu:**

- [ ] Input có value, input rỗng có placeholder và password khớp behavior upstream; font/color/clip đúng.
- [ ] Text extraction được kiểm tra theo policy upstream, kể cả không lộ giá trị gốc của password qua text/ActualText.
- [ ] Giữ nguyên sizing, disabled/readonly và style preset hiện có.

**Kiểm tra:** Chuyển case từ takumi/tests/form_control_tests.rs và fixture form controls sang render PDF + text/raster assertions.

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/dom.zig; src/html/html.zig; src/render.zig; src/pdf/filelayer_tests.zig.

## 09 — Port textarea và select presentation (P0)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Hoàn thiện text nhiều dòng, lựa chọn được chọn và vị trí nội dung form control.

**Tiêu chí nghiệm thu:**

- [ ] Textarea giữ newline/rows/cols và placeholder; không thiếu dòng hoặc lặp text qua trang.
- [ ] Select hiển thị đúng selected option và alignment/padding; hidden option không lộ ra text layer trái với oracle.
- [ ] Có case disabled, style override, wrapping và control nằm ở page boundary.

**Kiểm tra:** Test form_control_tests.rs tương ứng; ảnh so sánh và extracted-text cho textarea/select.

**Phụ thuộc:** 08. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/dom.zig; src/html/html.zig; src/render.zig; src/pdf/filelayer_tests.zig.

## 10 — Port unicode-bidi override (P1)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Nối unicode_bidi đã parse vào bidi segmentation/shaping và PDF text mapping.

**Tiêu chí nghiệm thu:**

- [ ] bidi-override và isolate-override có tác dụng với LTR/RTL và span lồng nhau theo upstream.
- [ ] Không phá Arabic shaping, emoji/combining clusters hoặc ActualText/ToUnicode.
- [ ] Test phân biệt visual order, logical extraction và direction inherited.

**Kiểm tra:** Chuyển unicode_bidi fixture; PDF rendering/extraction cùng RTL/Arabic regression.

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/font/bidi.zig; src/font/text.zig; src/render.zig; src/font/tests_shaping.zig; src/pdf/text_tests.zig.

## 11 — Port list-style-image (P1)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Đưa marker ảnh vào layout và PDF, giữ numbering/label semantics.

**Tiêu chí nghiệm thu:**

- [ ] Ảnh marker đúng kích thước/alignment cho inside/outside, lặp trang và RTL.
- [ ] Thiếu hoặc lỗi ảnh theo đúng fallback đã xác định; không render cả marker ảnh và marker chữ.
- [ ] Có Lbl/structure và test host bắt đầu bằng flex/grid/table/replaced box để xác định phần còn thiếu trước khi sửa.

**Kiểm tra:** Fixture list_markers, list_outside_marker_position; ảnh, baseline và structure assertions.

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/markers.zig; src/pdf/emit_text.zig; src/render.zig; src/pdf/filelayer_tests.zig.

## 12 — Port generated content url (P1)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Hỗ trợ ảnh trong ::before/::after qua content:url() dùng cùng resource lifecycle với ảnh thường.

**Tiêu chí nghiệm thu:**

- [ ] Ảnh được resolve ở prepare/render, có intrinsic sizing và fallback theo oracle.
- [ ] Hoạt động với inline/block pseudo, positioned ancestor và page break.
- [ ] Không làm hỏng counters hoặc generated text hiện có.

**Kiểm tra:** Case content:url PNG/SVG, missing image, prepared image và counter đặt cạnh ảnh.

**Phụ thuộc:** 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/render.zig; src/dom.zig; src/style/props.zig; js/pdf-api.mjs; scripts/pdf-audit/paint.probe.mjs.

## 13 — Port SVG position lists và rotation của text (P1)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Thay cách chỉ lấy phần tử đầu x/y/dx/dy bằng xử lý theo character/cluster.

**Tiêu chí nghiệm thu:**

- [ ] Danh sách x/y/dx/dy và rotate được áp đúng cho text/tspan và inheritance.
- [ ] Tôn trọng text-anchor, spacing, baseline và shaping; không tách sai cluster phức tạp.
- [ ] Text layer hoặc outlines tuân theo upstream trong các trường hợp transform.

**Kiểm tra:** Fixture svg_text_spacing, svg_text_glyphs, svg_text_shaping; thêm list ngắn/dài và rotate cuối lặp.

**Phụ thuộc:** 01, 10. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_svg.zig; src/svg/dom.zig; src/svg/render.zig; src/pdf/text_tests.zig.

## 14 — Port SVG textPath và text decoration (P1)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Hỗ trợ chữ bám path và decoration còn thiếu sau khi position lists ổn định.

**Tiêu chí nghiệm thu:**

- [ ] textPath/href/startOffset và hướng path được xử lý theo phạm vi upstream thực sự hỗ trợ.
- [ ] Underline/overline/line-through của SVG text/tspan có test với transform và opacity.
- [ ] Không dùng raster fallback cho toàn bộ SVG chỉ để che thiếu vector implementation.

**Kiểm tra:** Fixture svg_text_path_rotate; đối chiếu outline/glyph placement và raster cùng reference.

**Phụ thuộc:** 13. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_svg.zig; src/svg/render.zig; src/raster/path.zig; scripts/pdf-audit/images.probe.mjs.

## 15 — Port stylesheet bên trong inline SVG (P1)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Cho style/selector bên trong inline SVG tham gia cascade đúng scope.

**Tiêu chí nghiệm thu:**

- [ ] Case images.svg-inline.css-fill có style thay đổi paint thật sự.
- [ ] Test selector specificity, inherited/currentColor, SVG lồng nhau và không rò CSS ra HTML ngoài SVG.
- [ ] Phân biệt inline SVG với SVG nguồn ảnh độc lập và CSS của trang theo oracle.

**Kiểm tra:** Probe images.svg-inline.css-fill và fixture svg_inline_page_styles/svg_style_selectors.

**Phụ thuộc:** 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_svg.zig; src/svg/xml.zig; src/svg/dom.zig; scripts/pdf-audit/images.probe.mjs.

## 16 — Hoàn thiện continuation qua thay đổi chiều rộng trang (P1)

**Trạng thái:** in progress — `pagination.continuation.rowspan-width-reflow` đã pass (5/5) từ trước; lần này đối chiếu oracle pinned (build lại từ `ff9a5d4`) trên 52 case trang đổi width (240/360 px xen kẽ và named pages): baseline 24 case lệch text/vị trí chữ, nay còn 2, cả hai ghi lại bên dưới. Đã sửa (`src/pdf/paged.zig`, `src/layout/fragment.zig`, `src/layout/tree.zig`, `src/pdf/bands.zig`):
- Container flex/grid bị cắt giữa chừng: box của nó lấy width trang mới, còn item giữ size/offset của fragment đầu (`FrozenWidth`, đúng như takumi đo bằng raster: nền container rộng theo trang, nền item giữ width cũ); start token qua flex column / grid một cột / flex line và grid row nhiều item (branches) giờ biểu diễn được, nên nội dung sau container lấy width của trang mới thay vì giữ width cũ cả trang (trước đây text bị cắt mất ở mép trang hẹp).
- Ô của row đã hết nội dung nhưng row còn chạy (row đứng trước một rowspan): token cấp row với mọi ô finished; ô rowspan không lọt vào branches (là side flow). Trước đây trang đó giữ width cũ và mất chữ (`table-rowspan-tall-rows`).
- Block size của row: lấy theo layout của bảng ở trang bảng bắt đầu (trước pagination), áp cho row bắt đầu sau điểm cắt; row đã xong trước điểm cắt giữ vị trí (`top`). Row bị cắt giữa vẫn theo `Start.row_height`. Bảng có rowspan giữ cách cũ.
- `sameStart` so sánh theo tập điểm chưa xong (band mà item khác đã kết thúc sớm hơn ở width mới vẫn là cùng điểm bắt đầu); item đã xong theo token không bị đẩy qua trang 0 của start (`startFinished`).
Regression: Zig `paged continuation: …` (6 test mới, đều fail trước fix) và probe `pagination.continuation.{flex-column, flex-column-between, grid-column, flex-row-after, grid-rows-after, table-rowspan-tall-rows, table-rowspan3, table-two-rows, grid-align-end-after, table-spacing-borders}` (8 fail trên baseline). Còn lệch, chưa sửa: (1) đoạn văn có dòng đầu bị float đẩy sang trang sau (token dòng 0 không biểu diễn được) — trang đó vẫn giữ width cũ; (2) `thead` lặp lại: takumi vẽ bản sao header ở width cũ (lệch cột so với body ở width mới) và đẩy row 2 sang trang sau, bm layout lại header theo width mới — không bắt chước. Chưa đo links/tags trên toàn bộ case mới (chỉ rowspan-width-reflow có assertion link).

Bổ sung restart token/continuation cho row table hoặc flex line đang chạy qua named page đổi width.

**Tiêu chí nghiệm thu:**

- [ ] Không giữ width cũ ngoài các trường hợp oracle cũng giữ; có case row/line đang dang dở.
- [ ] Nội dung và links/tags không mất hoặc lặp khi chuyển frame.
- [x] Golden named-pages không được ép khớp các nét ngoài clip vô hình; đánh giá riêng output thấy được. (named-pages IDENTICAL, không thêm nét vô hình; output thấy được của các case mới so bằng raster màu + vị trí chữ.)

**Kiểm tra:** Page widths alternating, named pages, table rowspan và flex row continuation; compare page count/text/geometry.

**Phụ thuộc:** 02, 05. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/paged.zig; src/layout/fragment.zig; src/layout/flow.zig; src/layout/table.zig; src/test_paged.zig.

## 17 — Port grid-row fragments (P1)

**Trạng thái:** in progress — 25 probe `pagination.grid-fragments.*` (break-before/after item và row dưới align-items start/center/end/stretch, row cao hơn trang, nested grid, item span 2/3 row, text, bảng trong grid, row-gap, explicit rows, align-self:end, padding/border) khớp oracle pinned về text, vị trí chữ và paint. Sửa: item span nhiều row không giãn theo row bị break đẩy nội dung xuống (takumi chỉ giãn row đó; `Layout.grid_row_span`, `src/layout/grid.zig`, `src/layout/fragment.zig`); Zig `paged grid: an item spanning rows keeps its block size …` fail trước fix. Chưa hỗ trợ / lệch đã biết: row align-items:end cao hơn trang lệch paint dưới 1 px ở fragment tiếp theo của container (`tall-row-end`, text/vị trí chữ khớp); grid qua trang đổi width dùng cơ chế item giữ width của task 16.

Bổ sung fragment của grid row cho item break và alignment qua trang.

**Tiêu chí nghiệm thu:**

- [x] Case align-items:end có item break-before khớp oracle. (`pagination.grid-fragments.break-before-item-end`, cùng start/center/stretch.)
- [x] Có nested grid, row span và nội dung text/table qua trang; định nghĩa rõ trường hợp chưa hỗ trợ. (Ngoại lệ: paint sub-pixel của `tall-row-end`, ghi ở trạng thái.)
- [x] Không đổi layout của grid không phân trang. (`grid_row_span` chỉ được đọc khi phân trang; `zig build test` 719 pass/21 skip, golden 125/10/1 như baseline.)

**Kiểm tra:** Probe grid pagination và các fixture có grid break; đo layout không paged để bắt regression.

**Phụ thuộc:** 02, 16. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/layout/grid.zig; src/layout/fragment.zig; src/pdf/paged.zig; src/test_paged.zig.

## 18 — Port reflow cạnh float bị chuyển trang (P1)

**Trạng thái:** in progress — đã ánh xạ 8 test float của `takumi-core/src/layout/fragmentation_tests.rs` thành probe `pagination.float.upstream.*` (assert đúng fragment page/offset/size như upstream trên nền màu, rồi so oracle), thêm nhóm `pagination.float.{clear, oversized, rtl, nested, widows-orphans}` (widows/orphans 2/3/4 cạnh float bị cắt và float bị hoãn; mỗi nhóm trên trang một width và trang đổi width xen kẽ). Baseline lệch 8/38 case, nay còn 1. Sửa: (1) dòng đầu của đoạn nằm dưới float rộng hơn container và chạy qua trang sau không làm cả đoạn bị dời trang (`src/layout/fragment.zig`); (2) đoạn bị dời xuống (orphans/widows, break giữa dòng) cạnh float được layout lại với float ở vị trí mới (`Frame.floatShiftedParagraph` → `inline_resume`, `src/render.zig`) — trước đây chữ đè lên float; (3) phần văn bản trước điểm cắt của đoạn tiếp tục ở width mới không bị đẩy xuống dưới float, nên float `clear` sau float bị cắt không còn mất ở trang width mới (`src/font/text.zig`). Zig: 3 test `paged floats: …` mới, đều fail trước fix. Còn lệch: float rộng hơn container + trang đổi width (thuộc giới hạn token dòng 0 của task 16). Các test float upstream không phân trang (inline_layout_algorithm, line_breaker, min_max_sizes, measure_tests) chưa ánh xạ case-level.

Chuyển việc đặt float và line wrapping vào vòng lặp layout theo trang.

**Tiêu chí nghiệm thu:**

- [x] Float nguyên khối bị đẩy sang trang kế và split float cập nhật vùng exclusion để text wrap lại; strict float reflow probes pass 24/24, gồm run đổi page width.
- [x] Mở rộng ánh xạ case clear, oversized float, RTL và nested block tới đủ test upstream; widows/orphans 2/3/4 cạnh float bị cắt / bị hoãn, trên trang một width và đổi width. (Ngoại lệ đã ghi: float rộng hơn container ở trang đổi width.)
- [x] Không giải bằng dịch pixel của một layout đã hoàn tất; pagination ghi nhận extent/resume state rồi layout lại.

**Kiểm tra:** `pagination.float*` 17/17 probe pass (oracle pinned); Zig `paged floats` 3 test mới + test cũ pass. Các test float không phân trang của upstream (measure/inline) chưa map case-level.

**Phụ thuộc:** 02, 16. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/layout/floats.zig; src/layout/inline.zig; src/layout/fragment.zig; src/font/text.zig; src/test_paged.zig.

## 19 — Emit trang ổn định khi layout còn tiếp tục (P1)

**Trạng thái:** in progress — emit từng phần chạy cho cả hai kiểu cắt: tại forced page break (`chunks.plan` → `.forced`), và tại ranh giới trang bất kỳ khi không có forced break (`.flowing`, `paged.FlowIter`): mỗi phần layout các con của flow từ con chứa điểm bắt đầu trang đầu của nó, giữ mọi trang trừ trang cuối (cắt ở trang còn ít nhất một trang và một con của flow phía sau), phần sau tiếp tục bằng token theo phần tử DOM (`NodeKey` + dòng + glyph). Trường hợp không an toàn thì layout cả tài liệu. Output tương đương bản whole: 55/55 case (`npm run test:pdf:chunks`, native và wasm, 22 case `flow-*` mới), corpus 160/160 trùng byte. Còn thiếu: cắt trong bảng/flex/grid, trong con của flow có box positioned/transform; port các case của streaming_tests.rs/window_scenes.rs. Xem `streaming-chunks.md`.

Port settled-page lifecycle của upstream; đây là streaming nội bộ, không tự thêm public streaming API.

**Tiêu chí nghiệm thu:**

- [x] Plain long document emit trang đầu trước khi layout toàn bộ xong (`flow-*`, `flow-takumi-default`: 350 trang, 5 phần).
- [ ] Transform nhìn ngược nhiều trang và positioned descendant chưa biết đích phải giữ đúng các trang cần giữ.
- [ ] window_scenes so sánh paint chunks/paint order giữa incremental và after-layout tương đương.

**Kiểm tra:** Các case plain/transform/relative-root/positioned trong streaming_tests.rs và window_scenes.rs; instrumentation thời điểm emit.

**Phụ thuộc:** 02, 03, 16. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/paged.zig; src/pdf/emit.zig; src/layout/fragment.zig; src/pdf/page_names.zig; src/test_paged.zig.

## 20 — Giữ counters và metadata đúng trong pipeline incremental (P1)

**Trạng thái:** in progress — trên đường từng phần: band có pageNumber/totalPages (pass đếm rồi pass vẽ, đo lại chiều cao band như `layOutRules`), link trước/sau (link tới phần sau thì gộp các phần), outline, tag UA-1/UA-2 (destination theo phần + node), pageRanges (phần bị bỏ hết trang vẫn thu anchor/heading) đều cho output giống bản whole. Counter trang trong nội dung và target-counter thì vẫn layout cả tài liệu.

Port pass đếm/settle và dữ liệu document-level cần sống qua release trang.

**Tiêu chí nghiệm thu:**

- [ ] PageNumber/TotalPages/target-counter và band đổi chiều cao settle đúng trước khi emit.
- [ ] Forward/back/dropped links, outline, tags và pageRanges khớp after-layout; invalid range lỗi trước layout.
- [ ] Trường hợp counter không hội tụ hoặc transform về trang trước có fallback có giới hạn và test tương ứng.

**Kiểm tra:** Chuyển nhóm counters/bands/links/ranges từ streaming_tests.rs; compare bytes/normalized semantics với after-layout.

**Phụ thuộc:** 19, 05. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/counters.zig; src/pdf/bands.zig; src/pdf/interactive.zig; src/pdf/paged.zig; src/pdf/tags.zig.

## 21 — Giới hạn live memory của tài liệu dài (P1)

**Trạng thái:** in progress — có instrumentation allocator (native `memoryPeak`, `memoryTrace`, `src/memtrace.zig`) và `npm run test:pdf:memory` (`scripts/pdf-memory.mjs`). Case `memory_tests.rs` (700 section, không forced break, header totalPages, 2 pass) giờ được cắt tại ranh giới trang bất kỳ: pass đếm live trang 50 / 200 = 4,48 / 4,64 MiB (×1,036), pass vẽ 5,74 / 6,10 MiB (×1,064) — đạt; peak 18,7 → 7,6 MiB (350 trang), 61,7 → 21,9 MiB (1400 trang). Đã giảm tích lũy khi vẽ: text đã chuẩn hóa và cluster starts của đoạn văn nằm trong bộ nhớ trang thay vì bộ nhớ tài liệu (~800 B/trang), và file được cấp phát một lần khi ráp (`Doc.finish`). Stress doc (forced break), native: 100 trang peak 19,6 → 19,1 MiB, 500 trang 59,6 → 53,0 MiB, 1,7–3,0 ms/trang, 3,7–3,9 KiB/trang. Vẫn tuyến tính: DOM + style dùng chung, ~11 KiB/trang tích lũy khi emit ở stress doc (content stream, cây tag, heading), map/rows khi ráp file.

Release layout/shaping/page allocations khi trang không còn được tham chiếu; tách memory đang sống với wasm capacity.

**Tiêu chí nghiệm thu:**

- [x] Port invariant memory_tests.rs: live bytes sau trang 200 không quá live bytes trang 50 ×1,1 trong từng pass của case 700 section (`scripts/pdf-memory.mjs`, native; ×1,036 và ×1,064).
- [x] Không dùng RSS hoặc WebAssembly.Memory.buffer.byteLength đơn lẻ làm bằng chứng live memory đã giảm (bộ đếm allocator của addon native).
- [ ] Benchmark 100/500 trang báo time/page, peak, live bytes và kích thước PDF; không có dữ liệu sống trỏ vào arena đã giải phóng.

**Kiểm tra:** Memory/stress tests có instrumentation allocator, native sanitizer phù hợp và wasm; so sánh cùng workload/reference.

**Phụ thuộc:** 19, 20. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/paged.zig; src/pdf/emit.zig; src/pdf/interactive.zig; scripts/pdf-scaling.mjs; src/pdf/filelayer_tests.zig.

## 22 — Chốt SVG-in-OpenType là N/A hay tính năng cần port (P2 audit)

**Trạng thái:** done — N/A đã xác minh bằng public source-reference probe.

Không suy từ việc krilla có helper SVG glyph rằng public takumi-pdf đã vẽ SVG font. Callback mặc định trả None và source PDF không cấu hình lại.

**Tiêu chí nghiệm thu:**

- [x] Coverage map ghi rõ SerializeSettings.render_svg_glyph_fn mặc định None; kiểm tra public reference với font SVG cụ thể.
- [x] Nếu pinned public PDF vẫn fallback outline thì đánh dấu N/A/extension, không triển khai SVG glyph paint chỉ để đạt parity.
- [x] Chỉ mở task implementation riêng nếu có test/reference chứng minh đường SVG glyph đang hoạt động; task mới phải có font, semantic mapping và validator criteria.

**Kiểm tra:** Source trace từ krilla/text/glyph/svg.rs đến serialize settings và một probe font SVG trên public PDF API.

**Phụ thuộc:** 00, 01. **Phạm vi:** S, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** docs/PDF_AUDIT.md; scripts/pdf-coverage-map.json; scripts/pdf-audit/fonts.probe.mjs.

## 23 — Port relative colors (P2)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Bổ sung relative color syntax mà upstream có, bắt đầu rgb(from ...).

**Tiêu chí nghiệm thu:**

- [ ] Có probe chứng minh syntax và phép channel/calc được pinned Takumi hỗ trợ.
- [ ] Chuyển đúng alpha, clipping và currentColor/variables; unsupported syntax có policy rõ.
- [ ] Không thay đổi hành vi gradient interpolation theo CSS hiện đang đúng chỉ để bắt chước hạn chế upstream.

**Kiểm tra:** Case relative colors upstream, test màu numeric và raster PDF với nguồn currentColor/var().

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/style/color.zig; src/style/props.zig; src/style/style.zig; scripts/pdf-audit/paint.probe.mjs.

## 24 — Port offset-path (P2)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Port phạm vi motion-path upstream thực sự hỗ trợ vào shared transform pipeline.

**Tiêu chí nghiệm thu:**

- [ ] Coverage map liệt kê path/ray/shape và offset-distance/rotate/anchor được reference chấp nhận trước khi code.
- [ ] Box, glyph và link rectangle dùng cùng transform, kể cả page boundary.
- [ ] Không thêm các cú pháp mà Takumi không hỗ trợ vào phạm vi parity bắt buộc.

**Kiểm tra:** Fixture offset_path_ray_burst và các fixture offset_path khác; compare visual bounds, text ownership và links.

**Phụ thuộc:** 00, 03. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/style/computed.zig; src/style/props.zig; src/pdf/emit.zig; src/paint.zig; src/test_paged.zig.

## 25 — Hoàn thiện multi-line inline outline (P2)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Port các outline island non-solid và corner radius hiện còn bị vẽ solid/square.

**Tiêu chí nghiệm thu:**

- [ ] Multi-line inline outline giữ đúng dash/dot/double và radii trong phạm vi reference hỗ trợ.
- [ ] Có case inline box qua nhiều dòng và qua trang, với transform hoặc clip.
- [ ] Không đổi paint order và stacking của các inline-outlines golden đã qua.

**Kiểm tra:** Golden inline-outlines và các biến thể non-solid/radii; normalized path và raster diff.

**Phụ thuộc:** 00, 01, 06. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_text.zig; src/pdf/emit_border.zig; scripts/pdf-audit/paint.probe.mjs.

## 26 — Port resource needs và font subsets trong prepare (P1)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Pinned PdfRenderer.prepare gọi native needs rồi prepareSource để tải font subsets và @font-face files; bm mới scan/fetch ảnh. Port phần thiếu ở pipeline preparation.

**Tiêu chí nghiệm thu:**

- [ ] @font-face/fontFiles trong document và bands được resolve/register đúng khi prepare; fonts loader chỉ tải subset được dùng theo unicodeRange như reference.
- [ ] AbortSignal, fetch/cache/dedup, remote-font failure và failedFontFiles có test; prepared handle render/measure không fetch lại ngoài policy.
- [ ] Giữ hỗ trợ fonts option hiện có và no-font policy; không bundle Geist mặc định. Fallback font là quyết định độc lập.

**Kiểm tra:** Upstream pdf-js prepare.test.ts và bindings-js renderer-facade fontFiles/subsets/failure tests; mocked fetch và wasm/native parity.

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** js/pdf-api.mjs; js/engine.mjs; src/render.zig; src/wasm.zig; scripts/pdf-audit/api.probe.mjs.

## 27 — Nghiệm thu và cập nhật audit theo từng đợt (P0 gate)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Chạy cùng case trên wasm/native, đối chiếu rendering/text/file semantics và chặn regression.

**Tiêu chí nghiệm thu:**

- [ ] PDF API 373+ và nhóm Zig PDF 130+ không có fail/skip không giải thích; mọi task mới thêm case tự động có mapping.
- [ ] 0 unexpected differences, render errors hoặc missing goldens; known differences phải có ngoại lệ hẹp đã giải thích, không hứa mọi file byte-identical.
- [ ] Chạy qpdf/pdfcpu/pdf.js và veraPDF cho conformance fixtures bị ảnh hưởng; 7 lỗi codec baseline được theo dõi riêng, không được tăng.

**Kiểm tra:** Build PDF + native hiện tại; 136 goldens, probes reference, API, Zig PDF, targeted full-suite check; ghi tool versions và kết quả máy đọc được.

**Phụ thuộc:** Sau từng nhóm task liên quan; hoàn tất sau 03–26 hoặc có quyết định hoãn được ghi rõ. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** scripts/pdf-compare.mjs; scripts/pdf-audit/run.mjs; bench/pdf/validate.mjs; bench/pdf/visual.mjs; docs/PDF_AUDIT.md.

## 28 — Sửa ellipsis và RTL presentation (P2)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Đối chiếu màu ellipsis và thứ tự paint khi text-overflow/line-clamp với span cuối và RTL.

**Tiêu chí nghiệm thu:**

- [ ] Có case cho màu ellipsis kế thừa từ span theo pinned reference, với clipping và line-clamp.
- [ ] Visual order và extracted logical text được assert riêng; hidden text không lọt vào PDF layer.
- [ ] Không thay đổi ordinary bidi/Arabic hoặc width metrics để sửa paint-order.

**Kiểm tra:** Probes text overflow/RTL và fixture text_ellipsis/text_line_clamp; phân tích source trước nếu golden không phủ.

**Phụ thuộc:** 01, 10. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/font/text.zig; src/pdf/emit_text.zig; scripts/pdf-audit/text-paint.probe.mjs.

## 29 — Rà tabs pre-wrap và soft-hyphen trong PDF text layer (P2)

**Trạng thái:** needs review — có triển khai/checkpoint; chưa đóng toàn bộ tiêu chí nghiệm thu.

Phân loại run grouping thuần biểu diễn với khác biệt extraction có ý nghĩa; chỉ sửa phần semantic còn lệch.

**Tiêu chí nghiệm thu:**

- [ ] Tabs, pre-wrap spaces và soft-hyphen có extracted-text assertions trên cả hai backend và pinned reference.
- [ ] Không ép TJ grouping giống byte khi glyph position và text semantics tương đương; ghi ngoại lệ hẹp cho grouping-only.
- [ ] ToUnicode/ActualText không làm lặp ký tự, mất soft-hyphen cần giữ hoặc lộ text đã clip.

**Kiểm tra:** Targeted whitespace/soft-hyphen probes và pdftotext/pdf.js cùng font; chọn source fixture từ coverage map.

**Phụ thuộc:** 01, 10. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/text.zig; src/pdf/emit_text.zig; src/pdf/text_tests.zig; scripts/pdf-audit/text-paint.probe.mjs.

## Checkpoint

- [ ] Sau 00–02: coverage map có traceability và reference revision; thiết kế fragment/lifetime được rà trước implementation.
- [ ] Sau 03–05: transform/clip/MCID không còn unexpected mismatch; text layer và PDF/UA không regression.
- [ ] Sau 06–09: inline background/mask và form text có regression cases, gate PDF qua.
- [ ] Sau mỗi 2–3 task trong 10–15/23–26/28–29: chạy gate 27 theo phạm vi, shared engine regressions được kiểm tra.
- [ ] Sau 16–18: page widths/grid/float có oracle và no duplicate/missing content.
- [ ] Sau 19–21: settled-page tests pass, live memory invariant pass trong cả hai pass, benchmark cùng reference.
- [ ] Task 22: SVG font được xác nhận N/A hoặc có task implementation riêng dựa trên public reference, không port theo suy đoán.
- [ ] Cuối: audit không còn unknown/unmapped case không giải thích; expected differences và deferred policies được ghi rõ; báo cáo cuối để người dùng review.


## Checkpoint continuation và resolved glyphs

Table-cell continuation khi đổi width: 6/8 probe qua, gồm text, ô dài/ngắn và links; còn painted-cell overflow và rowspan. Grid start/center/end với prefix, flex và grid regression: 9/9. Full Zig tại mốc continuation/grid: 668/668, exit 0; chưa phải full run của thay đổi glyph mới hơn. PDF API WASM 389/389. Resolved glyf dùng ppem + integer 26.6 midpoint, shadow/SVG 123/123 source probes; golden 123 IDENTICAL, 10 CLOSE, 3 DIFFER, 0 errors, structure/parent 136/136. CLOSE của color-glyph-text-shadow có gate riêng kiểm tra extraction và 6 raster comparisons mỗi run; mutation gate tests 5/5. Native/optimized artifact và full suite mới nhất đang kiểm tra tiếp. Task 18–21 và case-level mapping vẫn chưa hoàn tất; chưa benchmark.


## Checkpoint resource discovery, text variants and float reflow

Full Zig tại mốc generated images: 671/671, exit 0; trước sửa SVG needs/variants/float. API optimized WASM hiện tại: 393/393, Poppler bắt buộc. SVG needs theo CSS font family/weight và use, bỏ defs chưa dùng/display none/hidden, giới hạn vòng tham chiếu; font-face-only stylesheet không còn bị bỏ qua; fetched SVG có thể tải font-face mà không cần khai báo font subsets. Generated URL/gradient + tag ownership và text-transform full-width/full-size-kana đã có oracle probes. Focused 32/32 và native text variants 10/10. Float whole-box placement được đưa lại vào BFC exclusions rồi layout lại dòng; float group 54 assertions, nested BFC/RTL/variable-height 12 assertions; native float regression 13/13. Task 18 mới một phần, không đóng width-changing continuation hay split-float state. Audit tổng mới: 1559 probes, 1480 pass, 79 fail, 0 unverified; chưa có phân loại/ngoại lệ đủ cho mọi fail. Gate regression 6/6; missing/malformed Poppler output không thể pass bằng hai mảng rỗng, blank page warning có kiểm chứng page elements. Native artifact mới và full Zig mới hơn đang chạy; task 16/17 và 19–21 còn việc. Chưa benchmark runtime, chưa commit.

## Current verification checkpoint (2026-11-14)

`pagination.continuation.rowspan-width-reflow` passes 5/5 on native and WASM; `pagination.continuation` passes 18/18 on each. Full PDF Zig passes 676/676. Public PDF API passes 393/393 on each backend. Native and WASM strict audits match: 1,499/1,567 probes pass, 68 probes (128 assertions) fail, 0 unverified. The map has 121/272 Rust declarations mapped/verified and 0/69 JS declarations mapped/verified; remaining mapping is not equivalent to unsupported feature count. Correctness and source-coverage gates are still open; do not benchmark until both are clean.


## 2026-11-14 image sizing follow-up

Auto-sized replaced images at the layout root now keep intrinsic dimensions. The pinned root PNG/SVG probes pass 3/3 on native and WASM. Full PDF Zig passes 676/676; public PDF API passes 393/393 on both backends. Full strict audit matches on native and WASM at 1,499/1,567 probes, with 68 failing and 0 unverified. These failures remain to triage and resolve; no new runtime benchmark is claimed while the strict parity gate is red.


`@page` now resolves `ch` / `ex` from the root font metrics; its pinned probe passes on native and WASM. Latest full native audit: 1,499/1,567 pass, 68 fail, 0 unverified. WASM full-audit rerun is pending.


## Latest audit checkpoint (2026-11-14)

The full pinned Takumi strict audit now matches across native and WASM: 1,501/1,567 probes pass, 66 probes (121 assertions) fail, 0 unverified. PDF Zig tests pass 676/676 and public PDF API tests pass 393/393 on both backends. Attachment compression checks now compare decoded payloads rather than implementation-dependent Deflate lengths. This remains incomplete; do not claim full Takumi parity or run the final benchmark gate.


## 2026-11-15 focused PDF rendering fixes

CSS `filter:url(...)` references are now treated as identity operations when SVG filter rasterization is unavailable, while later filter functions in the list still run. Text `paint-order` now skips the irrelevant markers phase when deciding fill/stroke order, so `markers stroke` strokes before filling text. Regression tests cover URL-only/URL-plus-grayscale parsing and text paint-order resolution. Full PDF Zig passed 676/676 before the paint-order change; its focused style test passed 10/10 afterward. The `paint.filter` + `text.stroke` audit groups pass 45/45 on both native and WASM. The fresh pinned full audit matches across backends: 1,505/1,568 probes pass, 63 probes (115 assertions) fail, 0 unverified. Remaining failures are still a mixture of policy/diagnostic differences and possible PDF rendering, link, font and tagging defects; they are not all classified. Goal and final benchmark gate remain open.

## 2026-11-17 phân loại audit strict

Full strict audit (pinned `ff9a5d4`), HEAD `67c0f36`: **1.571 probe, 1.548 pass, 23 fail, 0 unverified**, giống hệt nhau trên wasm và native, và giống hệt danh sách ngày 15/11. Số 63 ở trên đã cũ.

- **Khác biệt có chủ đích, bm theo CSS (19):** 4 `paint.gradient.linear-in-*` (takumi bỏ qua interpolation space); `paint.box-shadow.current-color` (takumi không vẽ shadow thiếu màu); 9 `paint.clip-path*` (takumi không parse `ellipse()`/keyword position/`inset() round a / b`/geometry box nên bỏ clip; `margin-box` bm thừa một clip trùng border box, hình giống nhau); 3 `paint.mask.*` (takumi không hỗ trợ `mask-mode`/`mask-clip`/`mask-origin`); `paint.stacking.sticky` (bm vẽ như positioned). Đều có dòng trong `docs/PDF_AUDIT.md`.
- **Chính sách API (3):** `api.size.invalid` (bm từ chối trang quá lớn), `api.input.kinds` (`{ json }` là extension; takumi in `[object Object]`), `page.at-page.var.no-root-element` (bm áp `cssVariables` vào `@page` của full document).
- **Ranh giới P có chủ đích (1):** `tagging.generated.mixed-image` (`PDF_AUDIT.md` dòng `content: url()`): takumi biến ảnh thành block nên mỗi phần có một P riêng; bm giữ inline nên chỉ có một P `[0, 1, 3, 2]`. Thứ tự leaf vẫn theo quy ước của takumi: region rỗng mở lại sau ảnh (`emit_tag.reopen`) đứng trước ảnh, giống case `::before` inline của takumi (`P[0, 2] / P[1]`), và `<img>` inline thường cho cấu trúc giống hệt nhau.
- **Khác biệt shaping, không phải subset closure (1):** `fonts.subset.glyph-closure`: với ASCII, bm vẽ `@` (gid 32) bằng biến thể nâng cao trước `A` (contextual alternate của Inter) và một biến thể `J` khác (gid 42); takumi vẽ glyph mặc định. bm giữ cả glyph cmap gốc của `@` nên thừa 1 glyph (+40 byte). Text trích xuất giống nhau. Đoạn chỉ có `&nbsp;` vẫn nhúng font 6 KB + một P, còn takumi không vẽ gì; muốn khớp thì phải bỏ run chỉ có khoảng trắng, việc này sẽ đổi cấu trúc tag của các ô bảng chỉ chứa `&nbsp;`, nên cần quyết định trước.
- **Đã kiểm tra, không phải lỗi:** với fragment source (không có phần tử `<html>`), mọi nguồn biến `:root` (`<style>`, `css`, `cssVariables`) đều không tới `@page`, ở cả bm lẫn takumi. bm nhất quán: `cssVariables` ≡ `css: [":root{…}"]`.
- **Kết luận:** 0 lỗi thật của bm trong 23 probe fail.
- **Tooling đã sửa:** `run.mjs` dùng `process.exit()` làm mất report trên pipe Windows, đổi sang `process.exitCode`; `pdftotext()` trong `lib.mjs` không xoá PDF tạm (~395.000 file trong `bench/out/pdf-audit`), giờ đã xoá sau mỗi lần gọi; thêm `PDF_AUDIT_TRACE=1` để in id probe trước khi chạy.

## 2026-11-23 continuation đổi width, grid-row fragments, float reflow (task 16–18)

Oracle pinned build lại cục bộ từ `ff9a5d4` (rustc 1.97, wasm-bindgen 0.2.129, không docker; `bench/out/pdf-oracle`, provenance ghi `source-build-wasm-local-rustc-1.97`). Baseline (HEAD `1f40d98`, wasm): strict audit 1.571 probe, 1.548 pass, 23 fail; golden 125 IDENTICAL / 10 CLOSE / 1 DIFFER; PDF Zig 732/732. Sau thay đổi: audit 1.619 probe (+48 mới), 1.596 pass, cùng 23 fail như baseline, giống hệt trên wasm và native; golden không đổi (125/10/1, cùng từng fixture); PDF Zig 741/741 (+9 test mới, mỗi test fail trước fix); `zig build test` 719 pass / 21 skip; `test:pdf` 399/399 trên wasm và native; `test:pdf:chunks` tương đương cả hai backend; `test:pdf:memory` pass (×1,036 / ×1,064). Khám phá ngoài audit (scratch, so text từng trang + vị trí chữ với oracle): 52 case đổi width 24 → 2 lệch, 27 case grid 0 lệch (paint: 1 lệch sub-pixel), 38 case float 8 → 1 lệch. Chi tiết và phần còn lại ở trạng thái task 16, 17, 18.
