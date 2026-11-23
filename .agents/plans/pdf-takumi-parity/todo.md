# Task list: bm-engine PDF / Takumi parity

Trạng thái tổng: **needs review — chưa hoàn tất**. Task 00, 01 done; 02 và 27 needs review (xem trạng thái từng task và checkpoint “2026-11-23 gate 00/01/02/27” cuối file); 19–21 còn mở. Gate strict (audit pinned, golden, coverage map) xanh với 22 khác biệt có chủ đích và 4 khác biệt mở được liệt kê trong `scripts/pdf-audit/exceptions.json`. Không đánh dấu hoàn thành theo số golden render thành công.

Checkpoint 2026-11-13: Zig 664/664; PDF API 389/389 và focused source-reference 73/73 trên cả native/WASM; 136 golden gồm 123 IDENTICAL, 9 CLOSE, 4 DIFFER, 0 render error, structure/parent tree 136/136. Validator chọn 16 tài liệu: byte identity 16/16, semantics 16/16, veraPDF 14/14 mỗi backend, 0 bm-only issue (6 pdfcpu issue giống reference). Gate parity tổng chưa sạch. Chưa chạy benchmark theo yêu cầu chỉ đo sau khi hoàn tất implementation và gate pass.

## 00 — Lập bảng ánh xạ test và chức năng (P0)

**Trạng thái:** done (2026-11-23) — `scripts/pdf-coverage.mjs` sinh và kiểm tra `scripts/pdf-coverage-map.json`: 272 khai báo `#[test]` Rust (pdf_fixtures.rs 183, streaming_tests.rs 21, window_scenes.rs 2, memory_tests.rs 1, unit test của src/ 28, krilla/ 25, subsetter/ 12) và 69 `test()` Bun (takumi-pdf-js prepare/render, renderer-facade của bindings-js/helpers, prepare-images). Mỗi case có trạng thái `golden-adapter` 122 / `verified` 125 / `partial` 12 / `differs` 1 / `open` 1 / `not-applicable` 11 (Rust) và `verified` 60 / `not-applicable` 9 (JS); 0 case chưa phân loại. `--strict` thất bại khi còn case `pending-adapter`/`internal-review` hoặc khi adapter không trỏ tới thứ có thật (tên golden, probe khớp filter, tên test Zig, thông điệp check của `npm run test:pdf`, id case của chunks-check); `--audit=<results.json>` thêm điều kiện probe của case `verified` phải PASS/EXPECTED trong audit đủ với oracle pinned. Golden được nhận cả khi tên fixture nằm trong `format!` hoặc biến (trước bỏ sót `font_format_standards`, `paged_lines_under_a_transform_or_a_clip`). Case nào chưa có adapter thì được port: `scripts/pdf-audit/upstream.probe.mjs` (60 probe `upstream.<tên test Rust>`: input và điều test khẳng định, so oracle và so hằng số của test) và `scripts/pdf-audit/upstream-js.probe.mjs` (6 probe `upstream.js.*`). Port này tìm ra 2 lỗi thật của bm (đã sửa, xem checkpoint cuối) và 4 khác biệt mở (ZWNJ và bảng là flex item — đều đã sửa ngày 2026-11-23, xem các checkpoint cuối —, fixture HTML trên trang rất nhỏ).

Đối chiếu toàn bộ test PDF upstream với adapter Zig/JS; phân loại implementation, partial, missing, deliberate và chưa kiểm chứng.

**Tiêu chí nghiệm thu:**

- [x] Không dùng 136 golden làm mẫu số toàn bộ tính năng PDF; kiểm kê cả 272 khai báo test Rust trong takumi-pdf, test JS và window/stream/memory. (272 Rust + 69 JS trong `pdf-coverage-map.json`; golden chỉ là 122 case.)
- [x] Mỗi case có nguồn, runner tương ứng hoặc lý do không áp dụng; không còn case chưa phân loại. (`node scripts/pdf-coverage.mjs --strict --audit=…`: 0 vấn đề; 12 case `partial` ghi rõ phần chưa phủ — chủ yếu streaming_tests.rs về thời điểm emit.)
- [x] Cập nhật trạng thái cũ: paged-rotated-text đã sửa, named pages đã có; giữ lịch sử audit riêng. (`PDF_AUDIT.md`: bảng golden hiện tại — paged-rotated-text CLOSE do bước float cuối, named pages ported+equivalent; phần tham chiếu cũ 33eed4a giữ dưới “Reference (history)”.)

**Kiểm tra:** Kiểm tra manifest và coverage map; đối chiếu tên test/fixture với corpus; runner phải báo case chưa ánh xạ.

**Phụ thuộc:** Không. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** scripts/takumi-test-corpus.mjs; docs/PDF_AUDIT.md; scripts/pdf-coverage-map.json (mới).

## 01 — Cố định oracle và cơ chế kiểm tra sai khác (P0)

**Trạng thái:** done (2026-11-23) — `scripts/pdf-audit/gate.mjs` + `scripts/pdf-audit/exceptions.json`. Audit (`run.mjs`) ghi provenance vào `bench/out/pdf-audit/results.json` và in một dòng tóm tắt: revision bm và có thay đổi cục bộ hay không, backend và sha256 của binary đã chạy (addon native của gói npm đã publish được gọi đúng tên), oracle (kind, revision, version, sha256 wasm/wrapper/Cargo.lock, wasm-bindgen), các file font đã nạp kèm sha256, sha256 của danh sách ngoại lệ, phiên bản node/pdftotext/pdfjs-dist/@napi-rs/canvas. Không có reference → UNVERIFIED; `--strict` thất bại khi thiếu `TAKUMI_PDF_REF_ENTRY` pinned (npm 0.20.0 không được chấp nhận), khi còn unverified, khi có fail không nằm trong danh sách, hoặc khi một ngoại lệ không còn khớp (stale). Mỗi ngoại lệ chỉ một probe + một loại assertion + một mẫu của dòng lỗi, trạng thái `deliberate`/`open` và lý do (không wildcard, không prefix, không khớp-tất-cả). Assertion được đếm theo loại: error, page-count, page-box, tags, links, font-mapping, text, metadata, page-content. `cmp` của paged-helpers tách page count / page boxes / text thành ba assertion. Golden (`pdf-compare.mjs --strict`): mọi CLOSE/DIFFER của page content, phần interchange khác `same`, và khác biệt dict/CMap font phải có dòng `golden` (fixture + phần + verdict + lý do) trong cùng file; dòng không còn quan sát được là stale.

Đảm bảo các case ngoài golden so với đúng Takumi ff9a5d4, không lấy npm 0.20.0 làm oracle duy nhất.

**Tiêu chí nghiệm thu:**

- [x] Ghi revision, backend, font và phiên bản công cụ trong báo cáo; khi thiếu reference phải báo UNVERIFIED. (`results.json.provenance`; test `strict audit rejects missing reference…`.)
- [x] Ngoại lệ chỉ theo fixture và loại sai khác, có lý do; không miễn trừ toàn bộ PDF hoặc nới tolerance chung. (44 dòng probe + 18 dòng golden; lưu ý: so golden vẫn có ngưỡng nhiễu float 0,01 tuyệt đối / 1e-4 tương đối, nhưng mọi CLOSE đều phải được liệt kê theo fixture với lý do, nên ngưỡng này không cho qua fixture nào ngầm.)
- [x] --strict phải thất bại khi có lỗi mới; kiểm tra page content, page count/box, text, links, tags, font mapping riêng. (`node --test scripts/pdf-audit/gates.test.mjs` 11/11: ngoại lệ không phủ probe/loại khác, ngoại lệ stale, cùng sai khác của `paint.stacking.sticky` không có trong danh sách → exit 1, CLOSE golden không liệt kê → exit 1.)

**Kiểm tra:** Chạy baseline 136 golden trên wasm; đối chiếu một số case với native; thử một sai khác mới để chứng minh gate thất bại.

**Phụ thuộc:** 00. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** scripts/pdf-compare.mjs; scripts/pdf-audit/lib.mjs; scripts/pdf-audit/run.mjs; scripts/pdf-coverage-map.json.

## 02 — Thiết kế fragment và vòng đời trang (P0)

**Trạng thái:** needs review — tài liệu thiết kế `docs/PDF_FRAGMENT_DESIGN.md` viết lại theo code hiện tại (không gian stitched + cửa sổ trang, `emit.BoxFragment` qua transform/clip, token tiếp nối `Start`/`ResumePoint`/`ParagraphCut`/`FrozenWidth`, pass counter/band, ba lifetime document/part/page, `chunks.plan` `.forced`/`.flowing`, `DocWriter`, bảng điều kiện giữ trang so với streaming_tests.rs, danh sách interface cố định) và benchmark 1/10/100/500 trang có live bytes. Hai tiêu chí đầu chỉ đóng ở mức “thiết kế đã ghi và khớp code”; phần chưa có (cắt trong bảng/flex/grid, emit sớm khi có transform/positioned/fixed/counter) là việc của task 19–21, nên task giữ needs review.

Làm spike thiết kế cho phần rủi ro cao trước khi port sâu: tọa độ layout/paint, fragment decorations, trang ổn định, lifetime metadata và bộ nhớ.

**Tiêu chí nghiệm thu:**

- [x] Có mô hình fragment xuyên transform/clip và cách tiếp tục layout của table/flex/grid/float; tránh sửa tọa độ bằng offset cục bộ theo fixture. (`PDF_FRAGMENT_DESIGN.md` §1–3: `Pages` không vá node dùng chung, `emit.BoxFragment`, token có `branches`/`side_flows`/`FrozenWidth`; float: retry toàn frame, chưa có mô hình exclusion theo trang — ghi ở giới hạn.)
- [x] Xác định khi nào được emit/release một trang, khi nào phải giữ trang vì transform, positioned descendants hoặc counter chưa ổn định. (§5: bảng điều kiện; bm giữ bằng cách từ chối cắt — thô hơn takumi, giữ cả tài liệu.)
- [x] Ghi benchmark 1/10/100/500 trang và instrument live bytes; chốt các interface trước task 03, 16–21. (§6–7; `node scripts/pdf-memory.mjs --stress`, native: 500 trang peak 52,96 MiB, live sau trang 50/200 = 35,62/41,62 MiB, 1,84 ms/trang; layout cả tài liệu 160,36 MiB. Interface “chốt” là mô tả cái đang có — task 03 và 16–18 đã làm trước khi tài liệu này được viết lại.)

**Kiểm tra:** Review thiết kế bằng window_scenes.rs, streaming_tests.rs, memory_tests.rs; thử prototype nhỏ, chưa thay kiến trúc toàn bộ.

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** docs/PDF_FRAGMENT_DESIGN.md (mới); src/pdf/paged.zig; src/layout/fragment.zig; scripts/pdf-scaling.mjs.

## 03 — Chia decoration của box transform qua trang (P0)

**Trạng thái:** done (2026-11-23) — đối chiếu oracle pinned `ff9a5d4` bằng 48 probe `paint.transform-fragment.*` (`scripts/pdf-audit/page-fragments.probe.mjs`: draw list từng trang, text từng trang, structure/parent tree, link annotation; rotate/skew/scale/offset-path, chiều cao cố định và auto, cha có border hoặc `position:relative`, clone + radius, transform lồng nhau, block con, link; box bị ranh giới cắt hoặc nằm ở trang sau nhưng góc xoay chạm trang trước). Ở HEAD 34/36 probe đầu và 4/12 probe cha positioned fail. Sửa (`src/pdf/emit.zig`, `src/pdf/emit_text.zig`, `src/pdf/interactive.zig`): (1) nội dung của box transform vẽ ở pass của fragment chứa nó (`Emitter.ownsContent` = `tpage` trong không gian transform) chứ không ở pass của trang hiện tại — trước đó box nằm ở trang 2 mà góc chạm trang 1 thì chữ (outline) vẽ trước nền, tức bị nền che; (2) `BoxFragment` mang transform của fragment và cờ first/last; dòng chữ, link (`inOtherFragment`), box con (cắt bằng `windowSlice` theo cửa sổ fragment) và box transform lồng nhau (fragment riêng, cắt cùng chỗ) chỉ vẽ trong fragment chứa chúng; (3) fragment không chạm trang thì không vẽ nền và không mở region rỗng (`tfExcludes` theo phần box của fragment, `tfRegionShows` theo box của khối + dòng của fragment); line frame của đoạn ẩn danh duy nhất là border box của khối (takumi `LineFrame`); (4) box positioned/lift xếp theo thứ tự scene của takumi: z-index, rồi pass (trang) rồi tree order. Zig: 5 test `transformed box at a page boundary: …` trong `src/pdf/filelayer_tests.zig`, đều fail trước fix. Khác biệt có chủ đích: fragment `slice` có `border-radius` — takumi bo cả góc bị cắt (kể cả không transform, `pagination.box-decoration-break.block`), bm cắt vuông theo CSS. Golden `paged-transforms`/`paged-rotated-text` CLOSE (chỉ lệch bước float cuối của `cm`).

Port per-fragment box geometry và transform origin cho rotate/skew/scale; bảo toàn paint order và nội dung con.

**Tiêu chí nghiệm thu:**

- [x] paged-transforms hết sai khác chưa được chấp nhận; giữ paged-rotated-text ở CLOSE hoặc IDENTICAL. (Cả hai CLOSE: `22.560555` vs `22.560556`.)
- [x] Box có border/radius, nested transform, clone/slice được cắt đúng và không mất hoặc vẽ lặp text/link. (48 probe; slice + radius là khác biệt có chủ đích đã ghi.)
- [x] Không ghi tạm layout toàn cục hoặc special-case theo tên fixture. (Trạng thái fragment nằm trong `BoxFragment` của lượt vẽ; layout không bị sửa.)

**Kiểm tra:** Golden paged-transforms, paged-rotated-text, translated/overflow/clip stitched; thêm nested transform và border-radius.

**Phụ thuộc:** 02. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit.zig; src/layout/fragment.zig; src/pdf/filelayer_tests.zig; scripts/pdf-compare-more.mjs.

## 04 — Sửa clip ở ranh giới trang (P0)

**Trạng thái:** needs review — 2/3 tiêu chí đóng (2026-11-23). Golden `paged-clipped-overflow` IDENTICAL. 13 probe `paint.clip-fragment.*` (clip lồng nhau, clip dưới transform, dòng bị cắt trên baseline, box `absolute` thoát clip) khớp oracle; 8 fail ở HEAD. Sửa: (1) `src/layout/fragment.zig`: box `absolute` thoát overflow clip (containing block nằm ngoài box clip) nay được phân trang như flow riêng và tính vào extent (`clippedOut`, `insideClip` giữ hành vi cũ cho `fixed`) — trước đó thiếu trang, phần dưới bị vẽ ra ngoài trang; (2) `src/pdf/emit.zig`: clip box đó thoát không còn thu hẹp `clip_y` (chữ E3–E5 bị mất khỏi text layer) và không còn làm box thành monolithic trong `windowSlice` (`outOfClip`); (3) `src/pdf/emit_text.zig`: đoạn ẩn danh của khối clip kết thúc ở đáy khối nên dòng bị clip không mở region rỗng ở trang sau. Zig: `clip at a page boundary: …` (2 test, fail trước fix). Khác biệt có chủ đích (dòng trong `PDF_AUDIT.md`): takumi thêm một trang trắng khi line box của box `overflow:hidden/clip` tràn qua trang cuối (con là block thì không) và vẽ lại box đó phía trên trang sau (không thấy); bm theo Chrome. Còn mở: clip dưới transform không thu hẹp text layer ở cả hai engine (dòng bị che vẫn trích xuất được).

Đối chiếu phần overflow/clip còn lệch, nhất là clip của stitched box và descendant thoát containing block.

**Tiêu chí nghiệm thu:**

- [x] paged-clipped-overflow hết sai khác chưa được chấp nhận; không làm hỏng các golden clipped-line đã qua. (IDENTICAL; golden 125/10/1 không đổi.)
- [ ] Pixel và text layer thống nhất: phần bị che không lộ trong text layer, phần còn thấy vẫn selectable. (Đúng với clip không transform và box `absolute` thoát clip; clip dưới transform vẫn để lộ dòng bị che, takumi cũng vậy.)
- [x] Có case nested clip, transformed ancestor và line bị cắt baseline. (`paint.clip-fragment.nested-*`, `in-rotated-120`, `rotated-clip-120`, `baseline-cut-*`.)

**Kiểm tra:** Chạy golden overflow/clip, extracted-text và raster diff dưới cùng rasterizer; chọn file probe thực tế theo coverage map.

**Phụ thuộc:** 03. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit.zig; src/pdf/emit_text.zig; src/pdf/filelayer_tests.zig; scripts/pdf-audit/pagination-layout.probe.mjs.

## 05 — Sửa marked content và structure parent qua trang (P0)

**Trạng thái:** done (2026-11-23) — golden `paged-monolithic-overflow` IDENTICAL (structure/parent 136/136). Region theo paint bounds của takumi: fragment transform không chạm trang thì không mở `/P` rỗng (lỗi còn lại của task 24), đoạn của khối clip dừng ở đáy khối, và bounds của đoạn được nới theo `span_ink_reach` (padding + border lớn nhất của span, cộng outline, mọi phía: `spanReach`). Zig `inline span across pages: the spans' reach opens …` và `clip at a page boundary: a clipped paragraph …` fail trước fix. Còn lệch không thấy được: span có padding/border dọc — takumi vẽ nền của fragment bên cạnh (viền thừa) trong region rỗng của fragment đó.

Port quy tắc mở/đóng region theo fragment thay vì sinh region rỗng không cần thiết.

**Tiêu chí nghiệm thu:**

- [x] paged-monolithic-overflow khớp structure tree/parent tree hoặc có chứng cứ ngoại lệ cụ thể. (IDENTICAL.)
- [x] MCID không trùng, parent mapping hợp lệ cho split box, repeats, empty inline và out-of-flow. (structure/parent golden 136/136; mọi probe `tagging.*` pass trừ `mixed-image` có chủ đích; 101 probe `page-fragments` so structure tree.)
- [x] PDF/UA, ActualText và thứ tự đọc giữ nguyên trên các fixture trước đó đã qua. (Golden `report-tagged-ua1/a2a` vẫn CLOSE, interchange same; `test:pdf` 399/399; veraPDF không chạy lại ở mốc này.)

**Kiểm tra:** Compare struct/parents, pdf.js extraction/structure; chạy các fixture tagged UA1/UA2/A2a và validator khi có tool.

**Phụ thuộc:** 04. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_tag.zig; src/pdf/tags.zig; src/pdf/emit_text.zig; src/pdf/filelayer_tests.zig.

## 06 — Sửa fragment background của inline span (P0)

**Trạng thái:** done (2026-11-23) — golden `inline-span-background-image` IDENTICAL; 15 probe `paint.inline-fragment.*` (slice/clone, gradient/radial, radius, padding + border, shadow, qua trang, trong box xoay qua trang) khớp oracle; 7 fail ở HEAD. Sửa (`src/pdf/emit_text.zig`, `src/pdf/emit.zig`): strip ảnh của span `slice` chỉ gồm các fragment trong fragment đoạn trên cùng trang (takumi lay out fragment items theo từng trang); pattern phủ padding box của strip với border hai đầu span (`image_geom.bw`, trước dùng border của fragment dòng); fragment được snap cả trong không gian transform (`SnappedBox`). Zig `inline span across pages: each page's fragment has its own image strip`, `inline span strip: the pattern covers …` fail trước fix. Khác biệt có chủ đích: takumi vẽ fragment của dòng sang trang sau khi padding/border vượt đáy trang (viền thừa, `pagination.box-decoration-break.inline`), bm chỉ vẽ ở trang chứa dòng.

Sửa extents và cách chia nền ảnh/gradient của inline box qua nhiều dòng.

**Tiêu chí nghiệm thu:**

- [x] inline-span-background-image hết sai khác ngoài tolerance. (IDENTICAL.)
- [x] slice/clone, span có padding/border và span qua trang có case riêng. (`paint.inline-fragment.*`, `pagination.box-decoration-break.inline`.)
- [x] Không tạo thêm hoặc làm mất vùng nền ở line break. (strip theo trang; viền thừa của takumi ở trang sau không chép.)

**Kiểm tra:** Golden inline-span-background-image, inline-span-border, box-decoration-break-clone; raster diff các case mới.

**Phụ thuộc:** 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_text.zig; src/paint_text.zig; scripts/pdf-audit/paint.probe.mjs.

## 07 — Sửa mask background-clip text (P0)

**Trạng thái:** needs review — 3/3 tiêu chí đóng, còn 1 case mở (2026-11-23). Golden `inline-span-background-clip-text-nested` và `background-clip-text-reach` IDENTICAL (đã khớp ở HEAD, bảng golden trong `PDF_AUDIT.md` cũ). 8 probe mới `text.background-clip-fragment.*` (span lồng nhau, opacity, transform, clip tổ tiên, decoration, ligature/ActualText, span qua trang) khớp oracle ở HEAD lẫn sau thay đổi. Còn mở: khối `background-clip:text` xoay bị ranh giới trang cắt — hình clip của mask và cách chia glyph (text/outline) khác takumi (pdftotext `sev\nera\n\nl` vs `sev\neral`); khối không transform qua trang chỉ lệch một nhóm artifact rỗng.

Đối chiếu glyph placement của span lồng nhau và độ vươn của mask.

**Tiêu chí nghiệm thu:**

- [x] inline-span-background-clip-text-nested và background-clip-text-reach hết sai khác chưa được chấp nhận. (IDENTICAL.)
- [x] Mask áp đúng descendant, decoration và clip ancestor; không ảnh hưởng ToUnicode/ActualText. (`text.background-clip.*` 20 + `text.background-clip-fragment.*` 8: draw list, text từng trang, structure.)
- [x] Không đổi glyph advance chỉ để khớp mask; kiểm tra riêng layout và paint. (Không đổi glyph advance; golden khớp cả vị trí `Tm`/glyph, text probe so layout riêng.)

**Kiểm tra:** Golden hai case mục tiêu; regression clip-text-stroke, nested spans, opacity, transform và page cut.

**Phụ thuộc:** 06. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_text.zig; src/pdf/text.zig; scripts/pdf-audit/paint.probe.mjs.

## 08 — Port text của input (P0)

**Trạng thái:** done (2026-11-23) — đối chiếu oracle pinned `ff9a5d4` bằng 37 probe `text.form.input.*` (`scripts/pdf-audit/text-tails.probe.mjs`: draw list, pdftotext, pdf.js text, raster 2x không lệch pixel nào). Trước khi sửa 30/37 probe fail. Đã sửa trong `src/text_control.zig`: (1) độ rộng mặc định lấy `max_char_width` từ bounding box của bảng `head` (làm tròn px) thay vì `hhea.advanceWidthMax`; avg = 0 thì lấy advance của `x` rồi x-height; áp danh sách `kFontFamiliesWithInvalidCharWidth` theo family đầu tiên (field Inter 14px: 217 → 226 px như takumi); (2) host `box-sizing: border-box` (`input[type=search]`) cộng border + padding vào size mặc định (trước 218×17 thay vì 226×23); (3) editor căn giữa bằng nửa free space của content box theo LayoutUnit (1/64, cắt về 0) thay vì `floor`, trừ border/padding khi chiều cao tác giả là border-box; `removes_line_height` theo giá trị tác giả (phần trăm luôn true, calc false). Zig `text controls: field width from the head bounding box, …` fail trước fix. Placeholder: cả hai engine đều không vẽ (pinned `TextControl::value` không đọc placeholder) — probe assert nó không lọt vào text layer. Khác biệt có chủ đích (`text.form.input.display-block-width`): input `display:block`/`flex` giữ width intrinsic theo Blink `LayoutBox::AutoWidthShouldFitContent`, takumi kéo giãn theo container (test upstream `a_text_field_lays_out_as_a_block_container_whatever_its_display`). Khác biệt chỉ ở nhóm lệnh: editor rỗng — takumi ghi một clip rỗng, bm không ghi (không thấy được; `cmp` so draw list chấp nhận).

Đưa value, placeholder và password presentation qua DOM → text layout → PDF.

**Tiêu chí nghiệm thu:**

- [x] Input có value, input rỗng có placeholder và password khớp behavior upstream; font/color/clip đúng. (37 probe; ngoại lệ block-level width đã ghi.)
- [x] Text extraction được kiểm tra theo policy upstream, kể cả không lộ giá trị gốc của password qua text/ActualText. (pdftotext + pdf.js, tagged và untagged; assert password/placeholder/number sai không xuất hiện.)
- [x] Giữ nguyên sizing, disabled/readonly và style preset hiện có. (disabled, readonly, fieldset disabled, size, border/padding, line-height, font lớn, baseline trong dòng.)

**Kiểm tra:** Chuyển case từ takumi/tests/form_control_tests.rs và fixture form controls sang render PDF + text/raster assertions.

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/dom.zig; src/html/html.zig; src/render.zig; src/pdf/filelayer_tests.zig.

## 09 — Port textarea và select presentation (P0)

**Trạng thái:** done (2026-11-23) — 33 probe `text.form.textarea.*`/`text.form.select.*` khớp oracle pinned (draw list hoặc grouping-only, pdftotext, pdf.js, raster 0 px). Pinned takumi không có select presentation: option được layout như nội dung (mọi option hiện ra, kể cả `hidden`); bm khớp đúng như vậy, text layer trùng nội dung vẽ nên không có text ẩn bị lộ. Textarea: newline CR/CRLF, dòng cuối rỗng, rows/cols, wrap/`wrap=off`, từ dài, tràn rows (clip), khoảng trắng editable/readonly, tab, disabled, style override, inherit, tagged, qua ranh giới trang. Khác biệt có chủ đích (lỗi upstream, không bắt chước): textarea cao hơn trang — takumi không vẽ dòng nào (3 trang trống) hoặc, nếu bắt đầu ở đầu trang, báo vượt 20 000 trang; bm cắt như box monolithic, mỗi dòng đúng một lần (`text.form.textarea.taller-than-page*`). Grouping-only: atomic inline có overflow (textarea) bm ghi clip của host hai lần (một lần rỗng); wrap/tab takumi tách run riêng — raster giống hệt.

Hoàn thiện text nhiều dòng, lựa chọn được chọn và vị trí nội dung form control.

**Tiêu chí nghiệm thu:**

- [x] Textarea giữ newline/rows/cols và placeholder; không thiếu dòng hoặc lặp text qua trang.
- [x] Select hiển thị đúng selected option và alignment/padding; hidden option không lộ ra text layer trái với oracle. (oracle vẽ mọi option; bm giống hệt.)
- [x] Có case disabled, style override, wrapping và control nằm ở page boundary.

**Kiểm tra:** Test form_control_tests.rs tương ứng; ảnh so sánh và extracted-text cho textarea/select.

**Phụ thuộc:** 08. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/dom.zig; src/html/html.zig; src/render.zig; src/pdf/filelayer_tests.zig.

## 10 — Port unicode-bidi override (P1)

**Trạng thái:** done (2026-11-23) — 34 probe `text.bidi-override.*` khớp oracle pinned (draw list, pdftotext = thứ tự logic qua ToUnicode/ActualText, pdf.js = thứ tự hiển thị, raster 0 px): override/isolate-override cho span và block, LTR/RTL, lồng nhau, direction kế thừa, `bdo`, Arabic/emoji/combining/ligature dưới override, fixture `unicode_bidi.html`. Override đã có từ trước; lỗi còn lại là `unicode-bidi: plaintext` (9 probe fail trước fix): mỗi đoạn bidi (tách bởi forced break) lấy hướng từ ký tự strong đầu tiên, không có thì LTR (UAX #9 P3) bất kể `direction`, và dòng dùng hướng đó cho căn lề start/end, overflow, indent, mức nền khi reorder và phía của ellipsis (`Paragraph.plain_paras`, `lineRtl` trong `src/font/text.zig`; như `ComputeBaseDirection` của takumi/Blink). Zig `unicode-bidi plaintext: …` fail trước fix.

Nối unicode_bidi đã parse vào bidi segmentation/shaping và PDF text mapping.

**Tiêu chí nghiệm thu:**

- [x] bidi-override và isolate-override có tác dụng với LTR/RTL và span lồng nhau theo upstream.
- [x] Không phá Arabic shaping, emoji/combining clusters hoặc ActualText/ToUnicode.
- [x] Test phân biệt visual order, logical extraction và direction inherited.

**Kiểm tra:** Chuyển unicode_bidi fixture; PDF rendering/extraction cùng RTL/Arabic regression.

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/font/bidi.zig; src/font/text.zig; src/render.zig; src/font/tests_shaping.zig; src/pdf/text_tests.zig.

## 11 — Port list-style-image (P1)

**Trạng thái:** needs review — tiêu chí đã đạt, còn 1 phần chưa port và 2 khác biệt tag ghi rõ. Probe mới `scripts/pdf-audit/generated-images.probe.mjs` (`lists.image.*`, 36 probe; draw list + pdftotext + pdf.js + raster 2x + structure tree) khớp oracle pinned trên wasm và native: PNG/JPEG/SVG inside/outside, RTL, nested, item xuống dòng / bị chia trang, marker ở mọi trang, `ol` (ảnh thay số), `::marker` content thắng, ảnh thiếu/hỏng giữ counter style (không bao giờ vẽ cả hai). Đã sửa (3 probe fail trước fix): (1) marker ảnh ngoài là nội dung của `Lbl` (`markers.labelOwner` lần từ node ảnh lên node marker; trước đó ảnh rơi vào `P` của `LBody` và item không có `Lbl`); (2) SVG không có width tự nhiên ở marker ngoài: rộng 0, không vẽ và không đẩy dòng (trước lấy 300 px làm TJ dịch chữ 300 px). Zig `tagging: an outside image marker is its item's label` và `list-style-image: an outside SVG without a natural width …` fail trước fix. Khác oracle (probe `differs`, dòng `list-style-image` trong `PDF_AUDIT.md`): takumi gắn ảnh marker vào `P` của `LBody` và để hai sequence rỗng trong `Lbl` (bm: ảnh trong `Lbl`); marker ảnh inside: takumi tách `P` riêng (cùng loại `content: url()`). Đã port (2026-11-23): item bắt đầu bằng box có formatting context riêng (flex/grid/table con, ảnh block) trước đây mất marker ngoài; nay marker là box block-level của item mà layout đưa ra khỏi flow (`layout.Style.list_marker`, `src/layout/block.zig`, căn `StaticPos.al = 3` trong `src/layout/tree.zig`) và đặt baseline của nó lên baseline đầu của item (con in-flow đầu tiên có baseline; sau ảnh block là dòng kế; không con nào có thì ở đầu content box — Blink `PositionListMarkerBesideChild` / `PositionListMarkerWithoutLineBoxes`); vẽ và gắn tag theo tree order, trước nội dung của item như takumi. Grid container nay báo baseline đầu (item đầu theo grid order của row đầu, CSS Align 3 §9.3; `src/layout/grid.zig`). 9 probe `lists.image.host-*` + `lists.image.tagged.host-flex-decimal` khớp oracle (draw list, text, structure; 4 probe `differs` cũ chuyển thành `same`); Zig `list markers: an item starting with a flex, grid or table box …` fail trước fix. Ghi chú: marker cạnh bảng nằm thấp hơn chữ của ô vài px ở cả takumi lẫn Chrome, bm giống takumi.

Đưa marker ảnh vào layout và PDF, giữ numbering/label semantics.

**Tiêu chí nghiệm thu:**

- [x] Ảnh marker đúng kích thước/alignment cho inside/outside, lặp trang và RTL.
- [x] Thiếu hoặc lỗi ảnh theo đúng fallback đã xác định; không render cả marker ảnh và marker chữ.
- [x] Có Lbl/structure và test host bắt đầu bằng flex/grid/table/replaced box để xác định phần còn thiếu trước khi sửa. (đã port 2026-11-23: marker cạnh baseline đầu của item.)

**Kiểm tra:** Fixture list_markers, list_outside_marker_position; ảnh, baseline và structure assertions.

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/markers.zig; src/pdf/emit_text.zig; src/render.zig; src/pdf/filelayer_tests.zig.

## 12 — Port generated content url (P1)

**Trạng thái:** needs review — tiêu chí đã đạt, khác biệt sizing/tag ghi rõ. Probe `generated.url.*` (25 probe trong `generated-images.probe.mjs`) khớp oracle pinned trên wasm và native: PNG/JPEG/SVG trong `::before`/`::after`, trong span, dòng xuống hàng, cạnh `counter()`/`attr()`, ảnh thiếu/hỏng (không vẽ gì, như takumi), mỗi đoạn ở nhiều trang, và ảnh lấy qua `prepare` (`generated.url.prepared`: cùng URL được fetch, cùng raster). Không cần sửa code. Khác oracle (probe `differs`, dòng `content: url()` trong `PDF_AUDIT.md`): pseudo `display:block` / `inline-block` / absolute giữ ảnh ở kích thước tự nhiên như trình duyệt, takumi kéo ảnh full chiều rộng pseudo (PNG 8 px thành 180 px trong `::before` block, đẩy chữ khỏi trang); ảnh inline đứng một mình: takumi cho `P` riêng (cùng loại `tagging.generated.mixed-image`). `open-quote url()` bị takumi bỏ cả khai báo (lỗi quotes của takumi, không thuộc task này; không đưa vào probe).

Hỗ trợ ảnh trong ::before/::after qua content:url() dùng cùng resource lifecycle với ảnh thường.

**Tiêu chí nghiệm thu:**

- [x] Ảnh được resolve ở prepare/render, có intrinsic sizing và fallback theo oracle. (sizing trong pseudo block/inline-block: khác có chủ đích, theo trình duyệt.)
- [x] Hoạt động với inline/block pseudo, positioned ancestor và page break.
- [x] Không làm hỏng counters hoặc generated text hiện có.

**Kiểm tra:** Case content:url PNG/SVG, missing image, prepared image và counter đặt cạnh ảnh.

**Phụ thuộc:** 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/render.zig; src/dom.zig; src/style/props.zig; js/pdf-api.mjs; scripts/pdf-audit/paint.probe.mjs.

## 13 — Port SVG position lists và rotation của text (P1)

**Trạng thái:** needs review — 2/3 tiêu chí đóng. 37 probe `images.svg-text.*` (gồm `arabic-x-list-rotate`) và 4 fixture upstream (`images.svg-fixture.{svg_text_shaping, svg_text_baselines, svg_text_path_rotate, image_svg_text}`) khớp oracle pinned; 20 probe trong số đó fail ở HEAD `a8a41d4`. Sửa (`src/svg/text_position.zig`, `src/svg/dom.zig`, `src/svg/style.zig`, `src/pdf/emit_svg.zig`): list có phần tử không parse được bị bỏ cả list (như `length_list`/`number_list`); text-anchor căn theo tổng advance, không cộng `dx` (`clusters_length`); `letter-spacing`/`word-spacing`; `dominant-baseline`/`alignment-baseline`/`baseline-shift` (sub/super/length cộng dồn qua tspan, `FloatAscent` theo metric làm tròn); cluster xoay quanh gốc pen của cluster (offset GPOS của glyph đầu xoay theo, cần `item_origin`); kerning nối qua ranh giới tspan (bỏ việc tắt liga/clig khi có vị trí, takumi không tắt); `font-style` (oblique tổng hợp), `font-stretch`, `font-variant: small-caps`. Zig: `SVG text position lists with an invalid entry are dropped whole` (fail trước fix). Còn mở: (1) ~~`svg_text_spacing` lệch 1 dòng: letter-spacing tại khoảng trắng trong văn bản Arabic~~ — đã sửa 2026-11-23 (`src/font/text.zig` cộng letter-spacing ở word separator của script cursive như Blink/takumi `ComputeSpacing`; probe `images.svg-fixture.svg_text_spacing` khớp oracle, test Zig `letter-spacing in a cursive script still applies at its word separators` fail trước fix); (2) `svg_text_glyphs`: synthetic bold (takumi stroke outline bằng fill) và layer COLR của glyph trong SVG text chưa port; (3) khác biệt có chủ đích: `dx`/`dy` trong chunk RTL cộng dồn theo thứ tự logic (SVG 2 / Blink `SvgTextLayoutAlgorithm`), takumi cộng theo thứ tự visual — ghi ở `docs/PDF_AUDIT.md`.

Thay cách chỉ lấy phần tử đầu x/y/dx/dy bằng xử lý theo character/cluster.

**Tiêu chí nghiệm thu:**

- [x] Danh sách x/y/dx/dy và rotate được áp đúng cho text/tspan và inheritance. (list dài/ngắn, rotate lặp phần tử cuối, tspan ghi đè/kế thừa/chỉ tspan có rotate, x lồng, đơn vị em/%, list sai bị bỏ.)
- [ ] Tôn trọng text-anchor, spacing, baseline và shaping; không tách sai cluster phức tạp. (Anchor, spacing Latin, baseline, ligature, dấu kết hợp, cluster Arabic với x/rotate đã khớp; còn letter-spacing tại khoảng trắng Arabic và synthetic bold/COLR, xem trạng thái.)
- [x] Text layer hoặc outlines tuân theo upstream trong các trường hợp transform. (SVG text là outline như takumi-pdf; `transform-rotate`, rotate trong `g`, skew/scale khớp.)

**Kiểm tra:** Fixture svg_text_spacing, svg_text_glyphs, svg_text_shaping; thêm list ngắn/dài và rotate cuối lặp.

**Phụ thuộc:** 01, 10. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_svg.zig; src/svg/dom.zig; src/svg/render.zig; src/pdf/text_tests.zig.

## 14 — Port SVG textPath và text decoration (P1)

**Trạng thái:** done (chờ review) — 34 probe `images.svg-text-path.*` (19 textPath: `xlink:href`, path đảo chiều, path có transform, circle/rect, nhiều subpath, href thiếu, startOffset âm/quá cuối/%, anchor middle/end, dx/dy/rotate trên path, chữ tiếp sau textPath, 2 textPath, letter-spacing, `x` của text, `method`/`spacing`/`side` bị bỏ qua như upstream; 15 decoration) và fixture `images.svg-fixture.svg_text_path_rotate` khớp oracle pinned. Sửa: opacity của `tspan`/`textPath`/`a` (tích các opacity, không tính `text`) nhóm decoration + glyph của span thành một group như takumi `TextPainter::paint_span` (`deco-opacity-tspan` fail ở HEAD); letter-spacing trên path đi theo task 13.

Hỗ trợ chữ bám path và decoration còn thiếu sau khi position lists ổn định.

**Tiêu chí nghiệm thu:**

- [x] textPath/href/startOffset và hướng path được xử lý theo phạm vi upstream thực sự hỗ trợ. (`images.svg-text-path.*`; `method`, `spacing`, `side`, thuộc tính `path` không có trong phạm vi takumi và cho cùng kết quả.)
- [x] Underline/overline/line-through của SVG text/tspan có test với transform và opacity. (`deco-line-through-transform`, `deco-skewed-text`, `deco-opacity-text`, `deco-opacity-tspan`, `deco-fill-opacity`, `deco-path`, …)
- [x] Không dùng raster fallback cho toàn bộ SVG chỉ để che thiếu vector implementation. (So sánh draw list với oracle: glyph và decoration là path vector, không có image XObject.)

**Kiểm tra:** Fixture svg_text_path_rotate; đối chiếu outline/glyph placement và raster cùng reference.

**Phụ thuộc:** 13. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_svg.zig; src/svg/render.zig; src/raster/path.zig; scripts/pdf-audit/images.probe.mjs.

## 15 — Port stylesheet bên trong inline SVG (P1)

**Trạng thái:** needs review — 3/3 tiêu chí đóng; còn fixture `svg_style_selectors`. 36 probe `images.svg-inline-css.*`, `images.svg-inline.css-fill-paints` và fixture `images.svg-fixture.svg_inline_page_styles` khớp oracle pinned; 13 trong số đó fail ở HEAD. Sửa (`src/svg/html_cascade.zig`, `src/style/style.zig`): root của inline SVG kế thừa thuộc tính SVG (fill, stroke, stroke-width, fill-opacity, text-anchor, …) mà tổ tiên HTML khai báo qua rule hoặc thuộc tính `style`, cùng font đã tính của host (takumi layout SVG trong style context của host); `var()` trong rule, `style` và presentation attribute được thay theo custom property của host và của các phần tử SVG phía trên (`style.substituteVars`); cascade chạy cả khi trang không có rule CSS. Zig: `var() substitution for declarations outside the cascade (inline SVG)`. Còn mở: `svg_style_selectors` là SVG nguồn ảnh độc lập (`<img>`) với `<style>` riêng dùng `:nth-child`, `:not`, `:lang`, `~`, `:is`, `:nth-last-of-type` — bộ selector tối giản của `src/svg/css.zig` bỏ các rule đó; cần cascade đầy đủ cho SVG độc lập (cũng ảnh hưởng render ảnh), chưa làm.

Cho style/selector bên trong inline SVG tham gia cascade đúng scope.

**Tiêu chí nghiệm thu:**

- [x] Case images.svg-inline.css-fill có style thay đổi paint thật sự. (`images.svg-inline.css-fill-paints`: rect không có fill được tô `#0a0`, không phải đen.)
- [x] Test selector specificity, inherited/currentColor, SVG lồng nhau và không rò CSS ra HTML ngoài SVG. (`images.svg-inline-css.*`: specificity class/id, rule sau thắng, rule thắng presentation attribute, kế thừa qua `g`/root/tổ tiên HTML, currentColor, `svg svg`, `svg > svg > rect`, `<style>` trong SVG không tác động HTML trước/sau.)
- [x] Phân biệt inline SVG với SVG nguồn ảnh độc lập và CSS của trang theo oracle. (`page-css-not-in-img-svg`, `img-svg-own-style`, `images.svg-inline.css-image-isolation`.)

**Kiểm tra:** Probe images.svg-inline.css-fill và fixture svg_inline_page_styles/svg_style_selectors.

**Phụ thuộc:** 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_svg.zig; src/svg/xml.zig; src/svg/dom.zig; scripts/pdf-audit/images.probe.mjs.

## 16 — Hoàn thiện continuation qua thay đổi chiều rộng trang (P1)

**Trạng thái:** in progress — `pagination.continuation.rowspan-width-reflow` đã pass (5/5) từ trước; lần này đối chiếu oracle pinned (build lại từ `ff9a5d4`) trên 52 case trang đổi width (240/360 px xen kẽ và named pages): baseline 24 case lệch text/vị trí chữ, nay còn 2, cả hai ghi lại bên dưới. Đã sửa (`src/pdf/paged.zig`, `src/layout/fragment.zig`, `src/layout/tree.zig`, `src/pdf/bands.zig`):
- Container flex/grid bị cắt giữa chừng: box của nó lấy width trang mới, còn item giữ size/offset của fragment đầu (`FrozenWidth`, đúng như takumi đo bằng raster: nền container rộng theo trang, nền item giữ width cũ); start token qua flex column / grid một cột / flex line và grid row nhiều item (branches) giờ biểu diễn được, nên nội dung sau container lấy width của trang mới thay vì giữ width cũ cả trang (trước đây text bị cắt mất ở mép trang hẹp).
- Ô của row đã hết nội dung nhưng row còn chạy (row đứng trước một rowspan): token cấp row với mọi ô finished; ô rowspan không lọt vào branches (là side flow). Trước đây trang đó giữ width cũ và mất chữ (`table-rowspan-tall-rows`).
- Block size của row: lấy theo layout của bảng ở trang bảng bắt đầu (trước pagination), áp cho row bắt đầu sau điểm cắt; row đã xong trước điểm cắt giữ vị trí (`top`). Row bị cắt giữa vẫn theo `Start.row_height`. Bảng có rowspan giữ cách cũ.
- `sameStart` so sánh theo tập điểm chưa xong (band mà item khác đã kết thúc sớm hơn ở width mới vẫn là cùng điểm bắt đầu); item đã xong theo token không bị đẩy qua trang 0 của start (`startFinished`).
Regression: Zig `paged continuation: …` (6 test mới, đều fail trước fix) và probe `pagination.continuation.{flex-column, flex-column-between, grid-column, flex-row-after, grid-rows-after, table-rowspan-tall-rows, table-rowspan3, table-two-rows, grid-align-end-after, table-spacing-borders}` (8 fail trên baseline). Còn lệch, chưa sửa: (1) ~~đoạn văn có dòng đầu bị float đẩy sang trang sau~~ — đã sửa 2026-11-23: token dòng 0 nay tiếp tục được (`fragment.mainStartY`, `paged.laySegments` không cần glyph cut cho dòng 0), trang bắt đầu tại điểm sớm nhất của các luồng (`startY` lấy min thay vì max: float tiếp tục ở trên dòng bị nó đẩy) và dòng đó không bị kéo lên đầu trang (`Frame.paginate`); Zig `paged floats: a first line pushed below a float onto a page of another width …` và 3 case `pagination.float.oversized` (alternating widths) fail trước fix; (2) `thead` lặp lại: takumi vẽ bản sao header ở width cũ (lệch cột so với body ở width mới) và đẩy row 2 sang trang sau, bm layout lại header theo width mới — không bắt chước. Chưa đo links/tags trên toàn bộ case mới (chỉ rowspan-width-reflow có assertion link).

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

**Trạng thái:** in progress — đã ánh xạ 8 test float của `takumi-core/src/layout/fragmentation_tests.rs` thành probe `pagination.float.upstream.*` (assert đúng fragment page/offset/size như upstream trên nền màu, rồi so oracle), thêm nhóm `pagination.float.{clear, oversized, rtl, nested, widows-orphans}` (widows/orphans 2/3/4 cạnh float bị cắt và float bị hoãn; mỗi nhóm trên trang một width và trang đổi width xen kẽ). Baseline lệch 8/38 case, nay còn 1. Sửa: (1) dòng đầu của đoạn nằm dưới float rộng hơn container và chạy qua trang sau không làm cả đoạn bị dời trang (`src/layout/fragment.zig`); (2) đoạn bị dời xuống (orphans/widows, break giữa dòng) cạnh float được layout lại với float ở vị trí mới (`Frame.floatShiftedParagraph` → `inline_resume`, `src/render.zig`) — trước đây chữ đè lên float; (3) phần văn bản trước điểm cắt của đoạn tiếp tục ở width mới không bị đẩy xuống dưới float, nên float `clear` sau float bị cắt không còn mất ở trang width mới (`src/font/text.zig`). Zig: 3 test `paged floats: …` mới, đều fail trước fix. ~~Còn lệch: float rộng hơn container + trang đổi width~~ — đã sửa 2026-11-23 cùng token dòng 0 của task 16 (case alternating widths của `pagination.float.oversized` trước bị loại khỏi probe, nay có và khớp oracle; thêm 2 case: float rộng đẩy dòng đầu sang trang sau, float rộng qua hai trang). Các test float upstream không phân trang (inline_layout_algorithm, line_breaker, min_max_sizes, measure_tests) chưa ánh xạ case-level.

Chuyển việc đặt float và line wrapping vào vòng lặp layout theo trang.

**Tiêu chí nghiệm thu:**

- [x] Float nguyên khối bị đẩy sang trang kế và split float cập nhật vùng exclusion để text wrap lại; strict float reflow probes pass 24/24, gồm run đổi page width.
- [x] Mở rộng ánh xạ case clear, oversized float, RTL và nested block tới đủ test upstream; widows/orphans 2/3/4 cạnh float bị cắt / bị hoãn, trên trang một width và đổi width. (Float rộng hơn container ở trang đổi width: đã sửa 2026-11-23.)
- [x] Không giải bằng dịch pixel của một layout đã hoàn tất; pagination ghi nhận extent/resume state rồi layout lại.

**Kiểm tra:** `pagination.float*` 17/17 probe pass (oracle pinned); Zig `paged floats` 3 test mới + test cũ pass. Các test float không phân trang của upstream (measure/inline) chưa map case-level.

**Phụ thuộc:** 02, 16. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/layout/floats.zig; src/layout/inline.zig; src/layout/fragment.zig; src/font/text.zig; src/test_paged.zig.

## 19 — Emit trang ổn định khi layout còn tiếp tục (P1)

**Trạng thái:** in progress — emit từng phần chạy cho cả hai kiểu cắt: tại forced page break (`chunks.plan` → `.forced`), và tại ranh giới trang bất kỳ khi không có forced break (`.flowing`, `paged.FlowIter`): mỗi phần layout các con của flow từ con chứa điểm bắt đầu trang đầu của nó, giữ mọi trang trừ trang cuối (cắt ở trang còn ít nhất một trang và một con của flow phía sau), phần sau tiếp tục bằng token theo phần tử DOM (`NodeKey` + dòng + glyph). Trường hợp không an toàn thì layout cả tài liệu. Output tương đương bản whole: 55/55 case (`npm run test:pdf:chunks`, native và wasm, 22 case `flow-*` mới), corpus 160/160 trùng byte. 2026-11-23: cắt được giữa các row của bảng, trước line/row/item của flex/grid (token một điểm, `paged.resumeKid`) và trong con của flow có box positioned/transform (bỏ điều kiện `Flow.cuttable` đó; box vẽ qua seam vẫn bị kiểm tra ink từ chối); 75/75 case tương đương trên native và wasm (+20 case, 12 case `parts: true` mới fail ở HEAD). Còn thiếu: trang bắt đầu bằng row/line bị cắt giữa (token có nhánh) hoặc rowspan đang chạy; một con của flow rất dài (một bảng) vẫn layout lại ở mỗi phần; port các case của streaming_tests.rs/window_scenes.rs. Xem `streaming-chunks.md`.

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

**Trạng thái:** in progress — có instrumentation allocator (native `memoryPeak`, `memoryTrace`, `src/memtrace.zig`) và `npm run test:pdf:memory` (`scripts/pdf-memory.mjs`). Case `memory_tests.rs` (700 section, không forced break, header totalPages, 2 pass) giờ được cắt tại ranh giới trang bất kỳ: pass đếm live trang 50 / 200 = 4,48 / 4,64 MiB (×1,036), pass vẽ 5,74 / 6,10 MiB (×1,064) — đạt; peak 18,7 → 7,6 MiB (350 trang), 61,7 → 21,9 MiB (1400 trang). Đã giảm tích lũy khi vẽ: text đã chuẩn hóa và cluster starts của đoạn văn nằm trong bộ nhớ trang thay vì bộ nhớ tài liệu (~800 B/trang), và file được cấp phát một lần khi ráp (`Doc.finish`). Stress doc (forced break), native: 100 trang peak 19,6 → 19,1 MiB, 500 trang 59,6 → 53,0 MiB, 1,7–3,0 ms/trang, 3,7–3,9 KiB/trang. Vẫn tuyến tính: DOM + style dùng chung, ~11 KiB/trang tích lũy khi emit ở stress doc (content stream, cây tag, heading), map/rows khi ráp file. 2026-11-23: peak của stress doc 500 trang (52,96 MiB) không đổi — nó cắt tại forced break và phần lớn là DOM + style (~25 MiB sau `frame: styled`), không phải bảng; tài liệu bảng dài không forced break (dòng mới của `--stress`) 200 bảng / 201 trang: 186,9 → 70,8 MiB (trước đó layout whole), đổi lại 4,2 → 8,6 ms/trang.

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

**Trạng thái:** done (chờ review) — 32 probe `paint.color-relative.*` khớp oracle pinned (đã khớp từ HEAD: parser `parseRelative` trong `src/style/color.zig` theo đúng `parse_relative_color`), thêm 2 probe chỉ kiểm bm: `paint.color-relative.values` (giá trị kênh ghi ra) và `paint.color-relative.gradient-interpolation` (fail ở HEAD). Policy: kênh keyword/số/%/góc hue (deg/grad/rad/turn)/`none`/`alpha`, origin lồng nhau, alpha clamp, gamut clip; `calc()` trong kênh, `color(from …)`, origin `currentColor` và token thừa là không hợp lệ → bỏ khai báo (như takumi). Sửa một chỗ: màu relative không phải màu legacy, nên gradient có nó nội suy trong Oklab như takumi-core (`peeks_modern_color_function`); takumi-pdf vẫn ghi mọi gradient bằng sRGB (khác biệt có chủ đích `linear-in-*`), nên probe này so bm với gradient `in oklab` tường minh. Zig: `relative colour syntax counts as a modern colour for gradient interpolation` (fail trước fix).

Bổ sung relative color syntax mà upstream có, bắt đầu rgb(from ...).

**Tiêu chí nghiệm thu:**

- [x] Có probe chứng minh syntax và phép channel/calc được pinned Takumi hỗ trợ. (`paint.color-relative.*`; `calc()` không được pinned takumi hỗ trợ: `calc-channel-invalid` khớp.)
- [x] Chuyển đúng alpha, clipping và currentColor/variables; unsupported syntax có policy rõ. (alpha keyword/%/clamp, `oklch-out-of-gamut-clipped`, `var-origin`/`var-channel`/`var-whole-colour`, `inherited-as-current-color`, `current-color-origin-invalid`; policy ở trạng thái và `docs/PDF_AUDIT.md`.)
- [x] Không thay đổi hành vi gradient interpolation theo CSS hiện đang đúng chỉ để bắt chước hạn chế upstream. (4 probe `paint.gradient.linear-in-*` giữ nguyên là khác biệt có chủ đích.)

**Kiểm tra:** Case relative colors upstream, test màu numeric và raster PDF với nguồn currentColor/var().

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/style/color.zig; src/style/props.zig; src/style/style.zig; scripts/pdf-audit/paint.probe.mjs.

## 24 — Port offset-path (P2)

**Trạng thái:** done (2026-11-23; hai lỗi ở ranh giới trang sửa ở task 03/05) — 20 probe mới `paint.motion.*` (box + text + link annotation so oracle; 12 viewport, 8 phân trang) cùng 10 probe cũ và 4 fixture `images.svg-fixture.offset_path_*` khớp oracle pinned; 7 probe phân trang fail ở HEAD. Sửa (`src/style/motion_path.zig`, `src/style/values.zig`, `src/style/style.zig`, `src/style/computed.zig`, `src/render.zig`): takumi lấy reference box là query container, rồi kích thước viewport, rồi chính phần tử (`local_transform`); takumi-pdf layout trên column không có chiều cao, nên khi phân trang (hoặc render không có height) chiều cao reference là border box của phần tử: ray dùng chiều cao phần tử, shape/coord box được đo lười theo từng chiều cao (`motion_path.Lazy`). Trước fix bm dùng chiều cao vùng trang (vd `ray(… farthest-side)` đẩy box sang trang sau, thừa 1 trang). Zig: `motion paths without a viewport height take the element's height as the reference box` (fail trước fix). Còn lệch ở ranh giới trang, chung cho mọi transform xoay chứ không riêng offset-path (`transform: rotate()` cho cùng kết quả): box xoay có fragment bắt đầu ở trang sau vẫn mở một region marked-content rỗng `/P` ở trang trước; box transform chạy tiếp sang trang sau được vẽ sau fragment border của cha thay vì trước — thuộc task 03/05. Link rect `circle()` lệch 0,02 pt (làm tròn cung).

Port phạm vi motion-path upstream thực sự hỗ trợ vào shared transform pipeline.

**Tiêu chí nghiệm thu:**

- [x] Coverage map liệt kê path/ray/shape và offset-distance/rotate/anchor được reference chấp nhận trước khi code. (`scripts/pdf-coverage-map.json` chỉ chứa khai báo test Rust của takumi-pdf, không có case offset-path; phạm vi cú pháp pinned — `offset_path.rs`: `ray()` với size/`contain`/`at`, `path()`, basic shape, coord box, `offset-position`/`-anchor`/`-rotate`/`-distance` — ghi ở `docs/PDF_AUDIT.md` và có probe từng loại.)
- [x] Box, glyph và link rectangle dùng cùng transform, kể cả page boundary. (Hai lỗi còn lại đã sửa ở task 03/05, 2026-11-23: fragment không chạm trang không mở `/P` rỗng; box lift từ fragment của trang trước vẽ trước fragment border của cha positioned ở trang sau — `paint.transform-fragment.positioned-parent-*` 12/12, ở HEAD 4 fail. Còn: link rect `circle()` lệch 0,02 pt.)
- [x] Không thêm các cú pháp mà Takumi không hỗ trợ vào phạm vi parity bắt buộc. (`url()` không phải motion path ở cả hai, `paint.motion.url-not-a-path`.)

**Kiểm tra:** Fixture offset_path_ray_burst và các fixture offset_path khác; compare visual bounds, text ownership và links.

**Phụ thuộc:** 00, 03. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/style/computed.zig; src/style/props.zig; src/pdf/emit.zig; src/paint.zig; src/test_paged.zig.

## 25 — Hoàn thiện multi-line inline outline (P2)

**Trạng thái:** done (2026-11-23) — xác minh với oracle pinned: island nhiều dòng dashed/dotted/double/groove/ridge/inset/outset có radii (`paint.outline.inline-*`, 32 probe) giữ dash và cung bo như takumi (ghi chú "vẽ solid và vuông" trong `PDF_AUDIT.md` đã cũ). Qua trang/transform/clip: `paint.outline.inline-paged`, `inline-transformed-clip`, `paint.inline-fragment.rotated-outline-paged` (fail ở HEAD, pass sau sửa task 03), `outline-dotted-paged` (region rỗng sửa theo `span_ink_reach`). Golden `inline-outlines` IDENTICAL.

Port các outline island non-solid và corner radius hiện còn bị vẽ solid/square.

**Tiêu chí nghiệm thu:**

- [x] Multi-line inline outline giữ đúng dash/dot/double và radii trong phạm vi reference hỗ trợ.
- [x] Có case inline box qua nhiều dòng và qua trang, với transform hoặc clip.
- [x] Không đổi paint order và stacking của các inline-outlines golden đã qua.

**Kiểm tra:** Golden inline-outlines và các biến thể non-solid/radii; normalized path và raster diff.

**Phụ thuộc:** 00, 01, 06. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/pdf/emit_text.zig; src/pdf/emit_border.zig; scripts/pdf-audit/paint.probe.mjs.

## 26 — Port resource needs và font subsets trong prepare (P1)

**Trạng thái:** needs review — tiêu chí đã đạt, còn 2 khác biệt ghi rõ. Probe mới `scripts/pdf-audit/prepare.probe.mjs` (33 probe, fetch giả lập, so lời gọi `data()`/`fetch` của hai engine; port prepare.test.ts và renderer-facade.test.ts) khớp oracle pinned trên wasm và native; 10 probe fail ở HEAD. Đã sửa: (1) subset của `fonts` theo font fallback như takumi needs.rs: needs pass của engine nhận `listedFonts` (font có `unicodeRange` chưa load) và báo `fonts` = id các subset được với tới — family của phần tử rồi `fontFamilies`, face đã đăng ký vẽ được glyph thì dừng, so weight/style theo CSS; JS lặp load → đọc lại, nên subset thiếu glyph mà range khai báo có thì ký tự chuyển sang family sau (`src/pdf/needs.zig`, `src/pdf/pdf.zig`, `js/pdf-resources.mjs`, `Renderer.loadFontsOnce` trong `js/engine.mjs` để mỗi entry chỉ load một lần trên renderer). Trước đây bm load mọi font có range giao với text của cả tài liệu, bất kể family. (2) Chính sách fetch như takumi helpers `fetchOk`: timeout mặc định 30 s, tối đa 3 lần thử với 408/429/5xx hoặc lỗi mạng (Retry-After > 1 s thì dừng), `allowUrl` kiểm từng redirect. (3) `signal` được kiểm sau mỗi lần load font. Zig `PDF needs: the listed font subsets font fallback reaches` (8 trường hợp từ needs.rs). Khác oracle (probe `differs`): câu lỗi khi fetch hỏng; `prepare` bị abort vẫn reject khi `fetch` tùy biến bỏ qua `init.signal` (takumi treo mãi — lỗi upstream).

Pinned PdfRenderer.prepare gọi native needs rồi prepareSource để tải font subsets và @font-face files; bm mới scan/fetch ảnh. Port phần thiếu ở pipeline preparation.

**Tiêu chí nghiệm thu:**

- [x] @font-face/fontFiles trong document và bands được resolve/register đúng khi prepare; fonts loader chỉ tải subset được dùng theo unicodeRange như reference.
- [x] AbortSignal, fetch/cache/dedup, remote-font failure và failedFontFiles có test; prepared handle render/measure không fetch lại ngoài policy.
- [x] Giữ hỗ trợ fonts option hiện có và no-font policy; không bundle Geist mặc định. Fallback font là quyết định độc lập. (fonts không có `unicodeRange` vẫn load ngay như trước; không đổi Geist.)

**Kiểm tra:** Upstream pdf-js prepare.test.ts và bindings-js renderer-facade fontFiles/subsets/failure tests; mocked fetch và wasm/native parity.

**Phụ thuộc:** 00, 01. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** js/pdf-api.mjs; js/engine.mjs; src/render.zig; src/wasm.zig; scripts/pdf-audit/api.probe.mjs.

## 27 — Nghiệm thu và cập nhật audit theo từng đợt (P0 gate)

**Trạng thái:** needs review — gate chạy đủ ngày 2026-11-23 (số ở checkpoint cuối): PDF API 401/401 (wasm, native), Zig PDF 763/763, `zig build test` 741 pass / 21 skip, golden 125/10/1 với `--strict` exit 0 (18 khác biệt đều được liệt kê), strict audit 0 unexpected trên wasm và native, chunks 55/55, memory pass, coverage `--strict` 0 vấn đề. Cả ba tiêu chí đã tick, nhưng task vẫn needs review: phụ thuộc “hoàn tất sau 03–26 hoặc có quyết định hoãn được ghi rõ” chưa thỏa (19–21 còn in progress, chưa có quyết định hoãn), và các khác biệt `open` trong `exceptions.json` (fixture HTML trên trang rất nhỏ; ZWNJ và bảng là flex item đã sửa 2026-11-23, còn 2 probe open) mới được liệt kê, chưa được giải quyết.

Chạy cùng case trên wasm/native, đối chiếu rendering/text/file semantics và chặn regression.

**Tiêu chí nghiệm thu:**

- [x] PDF API 373+ và nhóm Zig PDF 130+ không có fail/skip không giải thích; mọi task mới thêm case tự động có mapping. (401/401 mỗi backend; Zig PDF 763/763, 0 skip; 21 skip của `zig build test` mặc định là test cần `-Dpdf`/css/tw/html hoặc so màu tiny-skia, không phải lỗi; mapping: `pdf-coverage.mjs --strict`.)
- [x] 0 unexpected differences, render errors hoặc missing goldens; known differences phải có ngoại lệ hẹp đã giải thích, không hứa mọi file byte-identical. (audit: 2.187 probe, 2.161 pass, 26 expected = 22 deliberate + 4 open, 0 unexpected/unverified/stale; golden 0 error, 0 missing, 18 khác biệt liệt kê. Lưu ý 4 probe `open` là khác biệt đã biết nhưng chưa sửa, không phải đã chấp nhận vĩnh viễn.)
- [x] Chạy qpdf/pdfcpu/pdf.js và veraPDF cho conformance fixtures bị ảnh hưởng; 7 lỗi codec baseline được theo dõi riêng, không được tăng. (`node bench/pdf/validate.mjs --gate=bm-only`, 161 tài liệu × bm-native / bm-wasm / takumi-pdf: 0 render error, 0 issue bm-only, 163 issue mỗi engine đều giống hệt takumi (pdfinfo “Suspects object is wrong type” 151, pdfcpu 12: AF/AFRelationship của PDF 2.0 và đích outline là StructElem), veraPDF 45/45 compliant mỗi engine, native == wasm byte-identical 161/161, pdf.js semantics giống takumi npm 0.20.0 ở 152/161 (so với gói đã publish, không phải oracle pinned). Công cụ trên Linux: qpdf 11.9.0 (apt; pin 12.4.2 là bản Windows), pdfcpu 0.16.4, poppler 24.02.0, OpenJDK 21.0.13, veraPDF 1.28.2 (sha256 khớp pin), pdf.js 6.5.438, MuPDF 1.28.6; `VALIDATION.md` ghi đúng phiên bản đã chạy. Lỗi codec: 0 — 7 lỗi PNG/WebP cũ đã được sửa trước đó (`PDF_TEST_PORT.md`), `zig build test` không còn test nào fail.)

**Kiểm tra:** Build PDF + native hiện tại; 136 goldens, probes reference, API, Zig PDF, targeted full-suite check; ghi tool versions và kết quả máy đọc được.

**Phụ thuộc:** Sau từng nhóm task liên quan; hoàn tất sau 03–26 hoặc có quyết định hoãn được ghi rõ. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** scripts/pdf-compare.mjs; scripts/pdf-audit/run.mjs; bench/pdf/validate.mjs; bench/pdf/visual.mjs; docs/PDF_AUDIT.md.

## 28 — Sửa ellipsis và RTL presentation (P2)

**Trạng thái:** needs review — tiêu chí đã đạt, còn 3 khác biệt ghi rõ. 21 probe `text.overflow-tail.*` khớp oracle pinned (draw list, pdftotext, pdf.js, raster). Đã sửa (4 probe fail trước fix): (1) dòng RTL: ellipsis được vẽ và trích xuất SAU nội dung (item logic cuối của `LineTruncator`) — segment của marker xếp cuối dòng (`src/font/text.zig`, chỉ PDF build) và `RunIter` trả marker sau phần còn lại của dòng (`src/render.zig`); (2) màu marker RTL lấy theo item logic cuối còn giữ (trước lấy item đầu); (3) marker dùng synthesis của style block (font của strut), không lấy synthetic bold của span cuối (`src/pdf/emit_text.zig`). Màu ellipsis theo span cuối ở dòng LTR đã đúng từ trước; có case clip/padding, line-clamp (webkit và chuẩn), custom string, text bị ẩn không lọt vào text layer. Zig `text-overflow: an RTL marker follows …` fail trước fix. Còn khác (ghi trong `docs/PDF_AUDIT.md`): (a) takumi hạ marker 10 px dưới baseline khi trước nó là span cao hơn — lỗi upstream, bm giữ baseline (`taller-span-baseline`); (b) ~~run RTL trong dòng LTR: takumi cắt theo thứ tự hiển thị (Blink), bm cắt theo thứ tự logic~~ — đã sửa 2026-11-23: dòng trộn hướng (không có inline box) được cắt ở đầu cuối visual khi đặt dòng (CSS Overflow 3, Blink `LineTruncator`), 5 probe `visual-truncation-*` (LTR chứa Arabic, dòng RTL chứa run Latin / chữ số) khớp oracle; dòng có inline box (layout complex) vẫn cắt theo logic; (c) takumi vẽ underline từng run (nội dung, marker), bm một lần — seam lệch 6 px AA (chấp nhận `maxDiff` 60 chỉ cho case này).

Đối chiếu màu ellipsis và thứ tự paint khi text-overflow/line-clamp với span cuối và RTL.

**Tiêu chí nghiệm thu:**

- [x] Có case cho màu ellipsis kế thừa từ span theo pinned reference, với clipping và line-clamp.
- [x] Visual order và extracted logical text được assert riêng; hidden text không lọt vào PDF layer.
- [x] Không thay đổi ordinary bidi/Arabic hoặc width metrics để sửa paint-order. (probe `ordinary-*`, `text.bidi.*` và golden không đổi.)

**Kiểm tra:** Probes text overflow/RTL và fixture text_ellipsis/text_line_clamp; phân tích source trước nếu golden không phủ.

**Phụ thuộc:** 01, 10. **Phạm vi:** M, tối đa 5 file logic mỗi lát; tách tiếp nếu vượt.

**File dự kiến:** src/font/text.zig; src/pdf/emit_text.zig; scripts/pdf-audit/text-paint.probe.mjs.

## 29 — Rà tabs pre-wrap và soft-hyphen trong PDF text layer (P2)

**Trạng thái:** needs review — tiêu chí đã đạt, còn 2 khác biệt ghi rõ. 21 probe `text.whitespace.*` + 3 probe `text.spacing.*` (text-semantics) khớp oracle pinned về pdftotext, pdf.js và raster 0 px, trên wasm và native; 9 case tab/pre-wrap/break-spaces chỉ khác cách chia TJ/text object (takumi tách tab và khoảng trắng giữ lại thành run riêng) nên dùng chế độ `grouping` có lý do ghi trong probe, không so draw list. Đã sửa (5 probe fail trước fix): (1) hyphen sinh ra đặt tại width của item làm tròn lên lưới LayoutUnit (`ceil64`, như takumi) — trước lệch 1/128 px làm pdftotext đọc `cal­i‐­` thay vì `cal­i­‐` và raster lệch 6 px; tolerance riêng của `text.spacing.soft-hyphen` hạ về 0; (2) `hyphens: none` bỏ cơ hội ngắt sau soft hyphen (CSS Text 3; trước đây vẫn ngắt và vẽ hyphen) — `TextStyle.no_hyphens`. Soft hyphen giữ trong trích xuất (`extra­‐`), không lặp ký tự; text bị clip bởi overflow vẫn nằm trong content stream ở cả hai engine (giống oracle). Zig `soft hyphens: hyphens none …` fail trước fix. Còn khác: `tab-size: <length>` (takumi chỉ nhận số space, 30px thành stop cách 22,5 px; bm theo CSS). ~~Hyphen của soft hyphen mở đầu một span lấy màu của chữ trước nó~~ — đã sửa 2026-11-23: soft hyphen mở đầu run giữ glyph vô hình riêng trong run của span (không chia segment shaping, kerning giữ nguyên), hyphen lấy màu và cỡ chữ của span như Blink/Firefox/takumi (`soft-hyphen-span-*`).

Phân loại run grouping thuần biểu diễn với khác biệt extraction có ý nghĩa; chỉ sửa phần semantic còn lệch.

**Tiêu chí nghiệm thu:**

- [x] Tabs, pre-wrap spaces và soft-hyphen có extracted-text assertions trên cả hai backend và pinned reference.
- [x] Không ép TJ grouping giống byte khi glyph position và text semantics tương đương; ghi ngoại lệ hẹp cho grouping-only.
- [x] ToUnicode/ActualText không làm lặp ký tự, mất soft-hyphen cần giữ hoặc lộ text đã clip. (text clip theo overflow vẫn trích xuất được ở cả hai engine, giống oracle.)

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

## 2026-11-23 form-control text, unicode-bidi, ellipsis/RTL, tabs/soft hyphen (task 08–10, 28, 29)

Oracle pinned build lại cục bộ từ `ff9a5d4` (rustc 1.97, wasm-bindgen 0.2.129, provenance `source-build-wasm-local-rustc-1.97`). Lưu ý: chạy audit phải đặt `BM_RENDER_BACKEND=wasm` khi chưa build native trong worktree — nếu không `js/node-pdf.mjs` lấy addon native của gói npm đã publish (bản cũ) và báo 36 fail thay vì 23. Baseline (HEAD `a8a41d4`, wasm): strict audit 1.619 probe, 1.596 pass, 23 fail; golden 125 IDENTICAL / 10 CLOSE / 1 DIFFER. Probe mới `scripts/pdf-audit/text-tails.probe.mjs` (151 probe: `text.form.*`, `text.bidi-override.*`, `text.overflow-tail.*`, `text.whitespace.*`; draw list + pdftotext + pdf.js + raster 2x): 103/151 pass trên wasm baseline, 151/151 sau sửa. Sau thay đổi: audit 1.770 probe, 1.747 pass, cùng 23 fail như baseline, giống hệt trên wasm và native; golden không đổi (125/10/1 trên cả hai backend); PDF Zig 745/745 (+4 test mới trong `src/pdf/filelayer_tests.zig`, mỗi test fail trước fix); `zig build test` 723 pass / 21 skip; `test:pdf` 399/399 trên wasm và native; `test:pdf:chunks` tương đương cả hai backend; `test:pdf:memory` pass (×1,036 / ×1,064). File đổi: `src/text_control.zig`, `src/font/text.zig`, `src/render.zig`, `src/pdf/emit_text.zig`, `src/pdf/filelayer_tests.zig`, `scripts/pdf-audit/text-tails.probe.mjs` (mới), `scripts/pdf-audit/text-semantics.probe.mjs` (tolerance soft hyphen về 0), `docs/PDF_AUDIT.md`. Khác biệt còn lại (đều có probe `differs` và dòng trong `PDF_AUDIT.md`): width của text field block-level/flex (bm theo Blink), textarea cao hơn trang (lỗi upstream), marker sau span cao hơn (lỗi upstream), truncate run RTL trong dòng LTR (chưa sửa), `tab-size: <length>` (takumi không hỗ trợ), màu hyphen của soft hyphen mở đầu span (chưa sửa).

## 2026-11-23 SVG text, textPath, CSS của inline SVG, relative colors, offset-path (task 13–15, 23–24)

Oracle pinned build lại từ `ff9a5d4` như mốc trên (rustc 1.97, wasm-bindgen 0.2.129). Baseline (HEAD `a8a41d4`, wasm): strict audit 1.619 probe, 1.596 pass, 23 fail; golden 125 IDENTICAL / 10 CLOSE / 1 DIFFER; PDF Zig 741/741; `zig build test` 719 pass / 21 skip; `test:pdf` 399/399; `test:pdf:chunks` tương đương. Sau thay đổi: audit 1.790 probe (+171 mới), 1.767 pass, cùng đúng 23 fail của baseline (không fail mới); 44 probe mới fail ở HEAD (đo bằng cùng file probe trên wasm build từ HEAD), nay pass. Golden không đổi (125/10/1, cùng từng fixture); PDF Zig 745/745 (+4 test mới, mỗi test fail trước fix); `zig build test` 723 pass / 21 skip (oracle ảnh 850/850); `test:pdf` 399/399; `test:pdf:chunks` tương đương. Renderer ảnh: bench equivalence với `@takumi-rs/wasm` 250 case, không case nào đổi verdict (81 identical, còn lại equivalent). Chỉ đo wasm; native chưa build lại ở mốc này. Phần còn mở ghi ở trạng thái task 13, 15, 24: letter-spacing tại khoảng trắng Arabic (engine chữ chung), synthetic bold / COLR trong SVG text, selector đầy đủ cho `<style>` của SVG độc lập, region rỗng và thứ tự vẽ của box xoay ở ranh giới trang (task 03/05).

## 2026-11-23 list-style-image, content url(), prepare resources, glyph closure (task 11, 12, 26)

Oracle pinned build lại từ `ff9a5d4` (rustc 1.97, wasm-bindgen 0.2.129, provenance `source-build-wasm-local-rustc-1.97`). Baseline (HEAD `c6aac32`, wasm): strict audit 1.941 probe, 1.918 pass, 23 fail; golden 125 IDENTICAL / 10 CLOSE / 1 DIFFER; PDF Zig 749/749; `zig build test` 727 pass / 21 skip; `test:pdf` 399/399. Probe mới: `generated-images.probe.mjs` (61: `lists.image.*`, `generated.url.*`), `prepare.probe.mjs` (33: `prepare.*`), `fonts.subset.line-start-alternate`, `fonts.subset.nbsp-paragraph`. Sau thay đổi: audit 2.037 probe, 2.015 pass, 22 fail — đúng 23 fail baseline trừ `fonts.subset.glyph-closure` (không fail mới); probe mới chạy cả native (99/99). `fonts.subset.glyph-closure`: không phải lỗi closure của bm — (a) đoạn chỉ có `&nbsp;` ở cấp trên cùng của fragment: takumi bỏ text (coi U+00A0 là khoảng trắng gộp được) và mất cả dòng (`<p>&nbsp;</p><p>x</p>` vẽ `x` cao hơn một dòng), bm giữ như trình duyệt; (b) dòng bắt đầu bằng `@` trước chữ hoa sau khi ngắt dòng: cả hai engine nâng `@` (calt của Inter, `@.case` là composite của `@` mặc định) trên dòng liền, takumi vẽ `@` mặc định khi ngắt trước nó, bm giữ `@.case` (Blink cũng ra `@.case` dù dùng lại hay shape lại đầu dòng). Probe closure giờ so trên dòng không ngắt và `&nbsp;` lồng trong block (12/12 khớp); hai lỗi takumi thành probe `differs`. Golden không đổi (125/10/1); PDF Zig 752/752 (+3, mỗi test fail trước fix); `zig build test` 730 pass / 21 skip; `test:pdf` 401/401 trên wasm và native (+2: chọn subset theo fallback, retry 503; test eviction dùng 404 vì 500 giờ được retry); `test:pdf:chunks` tương đương; `test:js`, `test:limits`, `test:workers` pass. File đổi: `src/pdf/markers.zig`, `src/pdf/needs.zig`, `src/pdf/pdf.zig`, `src/font/collection.zig` (`weightDistance` pub), `src/pdf/filelayer_tests.zig`, `js/pdf-resources.mjs`, `js/engine.mjs`, `scripts/pdf-test.mjs`, `scripts/pdf-audit/fonts.probe.mjs`, 2 probe mới, `docs/PDF_AUDIT.md`. Còn mở: marker ngoài cạnh box con có formatting context riêng (task 11).

## 2026-11-23 fragment ở ranh giới trang: transform, clip, inline span, clip-text, outline (task 03–07, 25; lỗi còn lại của task 24)

Oracle pinned build lại cục bộ từ `ff9a5d4` (rustc 1.97, wasm-bindgen 0.2.129, esbuild wrapper; provenance `source-build-wasm-local-rustc-1.97`). Baseline (HEAD `c6aac32`, wasm): strict audit 1.941 probe, 1.918 pass, 23 fail; golden 125 IDENTICAL / 10 CLOSE / 1 DIFFER; PDF Zig 749/749; `zig build test` 727 pass / 21 skip. Probe mới `scripts/pdf-audit/page-fragments.probe.mjs` (113 probe: `paint.transform-fragment.*` 48, `paint.clip-fragment.*` 13, `paint.inline-fragment.*` 15, `text.background-clip-fragment.*` 8; draw list, text từng trang, structure/parent tree, link annotation): ở HEAD 53/113 fail, nay 113/113. Sau thay đổi: audit 2.025 probe, 2.002 pass, cùng đúng 23 fail của baseline (toàn khác biệt có chủ đích đã phân loại; không fail mới); golden không đổi (125/10/1, cùng từng fixture; `paged-transforms`/`paged-rotated-text` CLOSE chỉ do bước float cuối); PDF Zig 759/759 (+10 test mới trong `src/pdf/filelayer_tests.zig`, mỗi test fail trước fix); `zig build test` 737 pass / 21 skip; `test:pdf` 399/399 (wasm); `test:pdf:chunks` tương đương (wasm + native build lại `linux-x64-gnu`); `test:pdf:memory` pass (×1,036 / ×1,064). Audit chỉ chạy trên wasm. File đổi: `src/pdf/emit.zig`, `src/pdf/emit_text.zig`, `src/pdf/interactive.zig`, `src/layout/fragment.zig`, `src/pdf/filelayer_tests.zig`, `scripts/pdf-audit/page-fragments.probe.mjs` (mới), `docs/PDF_AUDIT.md`. Chi tiết và phần còn mở ở trạng thái task 03, 04, 05, 06, 07, 24, 25: clip dưới transform để lộ dòng bị che trong text layer (cả hai engine), khối `background-clip:text` xoay qua trang, region của nền fragment bên cạnh khi span có padding/border dọc (không thấy được).

## 2026-11-23 gate 00/01/02/27: ánh xạ test, oracle và ngoại lệ, thiết kế fragment, nghiệm thu

Baseline (HEAD `24ba1bf`, wasm, oracle pinned `ff9a5d4` build lại cục bộ: rustc 1.97, wasm-bindgen 0.2.129, provenance `source-build-wasm-local-rustc-1.97`): strict audit 2.121 probe, 2.099 pass, 22 fail (đều là khác biệt có chủ đích đã phân loại; khi đó `--strict` luôn exit 1); golden 125/10/1; PDF Zig 762/762; `zig build test` 740 pass / 21 skip; `test:pdf` 401/401.

- **Task 00:** `scripts/pdf-coverage.mjs` viết lại: nhận golden cả qua `format!`/biến, xác thực từng adapter (golden, probe, test Zig, check của `test:pdf`, case chunks), `--strict` và `--audit=`. 272 case Rust + 69 case Bun đều đã phân loại (xem trạng thái task 00). Probe mới: `scripts/pdf-audit/upstream.probe.mjs` (60) và `upstream-js.probe.mjs` (6) port input và điều khẳng định của các test chưa có adapter.
- **Task 01:** `scripts/pdf-audit/gate.mjs` (loại assertion, ngoại lệ, provenance), `scripts/pdf-audit/exceptions.json` (44 dòng probe: 25 deliberate + 19 open; 18 dòng golden), `run.mjs` (EXPECTED / STALE, đếm theo loại, provenance), `paged-helpers.mjs` (`cmp` tách page count / boxes / text), `pdf-compare.mjs --strict` (khác biệt golden phải được liệt kê), `gates.test.mjs` 11/11 (trước 5).
- **Task 02:** `docs/PDF_FRAGMENT_DESIGN.md` viết lại theo code; `scripts/pdf-memory.mjs --stress` đo 1/10/100/500 trang (live bytes sau trang 1/50/200/cuối, peak, ms/trang, KiB/trang).
- **Lỗi thật tìm thấy khi port (đã sửa, mỗi lỗi có test Zig fail trước khi sửa):** (1) `src/pdf/emit_image.zig`: ảnh PNG có `filter` mà pixel không giải mã được bị bỏ qua im lặng; takumi báo `Image could not be decoded: <src>: a filter needs the image's pixels: …` — nay bm báo lỗi như vậy (test `images: a filtered PNG whose pixels do not decode…`; probe `upstream.an_undecodable_image_stops_the_render`). (2) `src/pdf/needs.zig` + `CounterStyle.symbols` (`src/pdf/counters.zig`): face `unicodeRange` chỉ cần cho chữ số của counter trang (`totalPages trad-chinese-informal` trong footer) không được nạp nên render lỗi “No font the text can use draws 五”; nay needs thêm các ký tự của kiểu counter (2 case mới trong test `PDF needs: …`; probe `upstream.js.counter-face`).
- **Khác biệt mở mới (status `open` trong `exceptions.json`, dòng trong `PDF_AUDIT.md`):** ZWNJ (U+200C) tiếng Ba Tư nằm trong cluster của chữ trước nên ToUnicode `<067E200C>` và pdftotext đặt ZWNJ sai chỗ trong RTL (takumi: `<200C>` riêng); trang cuối của bảng là flex item bị cắt qua trang: hàng của takumi cao 14,3–14,4 px, bm giữ 13,5 px như các trang trước; 4 fixture HTML của `window_scenes.rs` trên trang rất nhỏ (400x300 → 250x90, margin 0/12) phân trang khác takumi (report 250x90: 24 so với 23 trang); dòng chữ giãn ký tự của certificate chạm mép trang 523x770.

Sau thay đổi:
- Strict audit (pinned `ff9a5d4`): **2.187 probe, 2.161 pass, 0 fail, 26 expected (22 deliberate + 4 open), 0 unverified, 0 stale; exit 0**, giống hệt trên wasm và native (addon build lại `linux-x64-gnu` trong worktree). Theo loại (pass / unexpected / expected): error 1102/0/2, page-count 2878/0/3, page-box 1395/0/0, tags 1480/0/2, links 464/0/2, font-mapping 265/0/2, text 2825/0/11, metadata 326/0/0, page-content 2088/0/22.
- Golden `npm run test:pdf:takumi`: 125 IDENTICAL / 10 CLOSE / 1 DIFFER, 0 error (không đổi, cùng từng fixture); `pdf-compare.mjs --strict` exit 0: 18 khác biệt (content/annots/outline/fonts) đều liệt kê, 0 unlisted, 0 stale.
- PDF Zig `zig build test -Dpdf=true` 763/763 (+1 test mới); `zig build test` 741 pass / 21 skip (+1; skip là test cần `-Dpdf`/css/tw/html hoặc phép so màu của tiny-skia, không có codec nào).
- **7 lỗi codec baseline:** 0 — đã được sửa trước đó (`docs/PDF_TEST_PORT.md`: giữ bit kênh không dấu thay vì bão hòa SIMD có dấu); `zig build test` không còn test PNG/WebP/animation nào fail.
- `npm run test:pdf` 401/401 trên wasm và native; `npm run test:pdf:chunks` 55/55 tương đương trên native và wasm; `npm run test:pdf:memory` pass (×1,036 / ×1,064); coverage `--strict --audit` 0 vấn đề với results của cả hai backend; `gates.test.mjs` 11/11.
- Benchmark (native, `pdf-memory.mjs --stress`): 1 trang 4,55 ms/trang, peak 2,37 MiB; 10 trang 2,31 ms, 5,81 MiB (layout cả tài liệu: quá ngắn để cắt); 100 trang 1,88 ms, peak 20,11 MiB, live sau trang 50 13,97 MiB, 4 phần; 500 trang 1,84 ms, peak 52,96 MiB, live sau trang 50/200 = 35,62/41,62 MiB, 18 phần, 3,7 KiB/trang. `BM_PDF_CHUNKS=off`: 100 trang peak 34,76 MiB, 500 trang 160,36 MiB.
- Validator (`node bench/pdf/validate.mjs --gate=bm-only`, công cụ Linux, xem tiêu chí 3 của task 27): 161 tài liệu, 0 render error, 0 issue bm-only (163 issue mỗi engine, đều giống takumi), veraPDF 45/45 compliant mỗi engine, native == wasm 161/161 byte-identical; gate pass. `bench/pdf/lib/tools.mjs` nay tìm được binary không đuôi `.exe` / symlink; `validate.mjs` ghi phiên bản thật của công cụ từ `.ok.json` khi công cụ không do `setup.mjs` cài.
- File đổi: `src/pdf/emit_image.zig`, `src/pdf/needs.zig`, `src/pdf/counters.zig`, `src/pdf/pdf.zig`, `src/pdf/filelayer_tests.zig`; `scripts/pdf-coverage.mjs`, `scripts/pdf-coverage-map.json`, `scripts/pdf-compare.mjs`, `scripts/pdf-memory.mjs`, `scripts/pdf-audit/{run,lib,paged-helpers,gates.test}.mjs`, mới: `scripts/pdf-audit/{gate.mjs,exceptions.json,upstream.probe.mjs,upstream-js.probe.mjs}`; `bench/pdf/lib/tools.mjs` (tìm binary không đuôi `.exe` và symlink ngoài Windows), `bench/pdf/validate.mjs` (phiên bản công cụ thật); `package.json` (`test:pdf:coverage`, `test:pdf:gate`); `docs/PDF_AUDIT.md`, `docs/PDF_FRAGMENT_DESIGN.md`.

## 2026-11-23 các lỗi chữ còn mở: ZWNJ, letter-spacing cursive, ellipsis visual, màu hyphen, synthOf, segment dài

Baseline (HEAD `f4fb567`, wasm, oracle pinned `ff9a5d4`): strict audit 2.187 probe, 26 expected, exit 0; golden 125/10/1; PDF Zig 763/763; `zig build test` 741 pass / 21 skip; `test:pdf` 401/401. Mỗi sửa đổi có test Zig fail trước fix (đã kiểm bằng cách tắt fix rồi chạy lại).

- **ZWNJ (U+200C) trong RTL (khác biệt open đã đóng):** `hideIgnorables` (`src/pdf/text.zig`) trước bỏ qua run RTL nên ZWNJ nằm trong cluster của chữ trước (`<067E200C>`). Nay run RTL (glyph theo thứ tự visual) cũng nhận glyph vô hình riêng, đặt trước cluster tại mép trái của nó (pen của glyph gốc), ToUnicode `<200C>` riêng như HarfBuzz/takumi; pdftotext đặt ZWNJ sau chữ của nó. Probe `upstream.persian_zero_width_non_joiners_keep_their_own_glyph` PASS, 3 ngoại lệ `open` bị xóa khỏi `exceptions.json`, coverage map: case chuyển `verified`. Test Zig `a zero-width non-joiner in right-to-left text keeps its own invisible glyph and mapping`.
- **Letter-spacing trong script cursive (task 13, `svg_text_spacing`):** `shapeOut` (`src/font/text.zig`) bỏ letter-spacing cho cả run Arabic; nay vẫn cộng ở word separator (space, NBSP) như Blink/takumi `ShapeResultSpacing::ComputeSpacing` (CSS Text 4 §8.2.1). Probe mới `images.svg-fixture.svg_text_spacing` khớp oracle. Test Zig `letter-spacing in a cursive script still applies at its word separators`.
- **Ellipsis cắt theo thứ tự visual (task 28):** Chrome/Blink `LineTruncator` và CSS Overflow 3 ẩn phần tràn ở mép cuối *visual* của dòng; bm cắt theo logic. Nay dòng trộn hướng (có glyph khác level của dòng, layout không complex) được đánh dấu `vis_cut` trong `clampLine`, và khi đặt dòng: tính thứ tự visual trước, giữ tiền tố visual vừa `avail - ellipsis` (độ rộng mỗi item làm tròn lên lưới LayoutUnit như lúc đặt), giữ nguyên cluster, bỏ qua glyph bị ẩn; brush của marker RTL theo item kề nó bên trái. 2 probe `differs` cũ thành `same` + 3 probe mới (`visual-truncation-ltr-mixed-span`, `-rtl-latin-run`, `-rtl-digits`), cả 5 khớp oracle (draw list, pdftotext, pdf.js, raster 0). Dòng có inline box (complex) vẫn cắt theo logic. Test Zig `text-overflow hides what overflows at the visual end of a line that mixes directions`.
- **Màu hyphen của soft hyphen mở đầu span (task 29):** theo Blink/Firefox dòng kết thúc trong item của span nên hyphen mang style của span (takumi cũng vậy) — bm sai. Nay soft hyphen mở đầu một run khác giữ glyph vô hình riêng (space, advance 0) trong run đó, chèn khi shape segment chứa nó (không chia segment: kerning qua nó giữ nguyên, khi ngắt tại đó kerning của item trước vẫn giữ như Blink). 1 probe `differs` thành `same` + 5 probe mới (`soft-hyphen-span-size`, `-before-span`, `-span-kern`, `-span-kern-break`, `-kern-break`), đều khớp oracle. Test Zig `the hyphen of a soft hyphen that opens a span takes the span's style`.
- **Hiệu năng `synthOf`:** `pm.ColorTablesCache` (`src/paint.zig`) giữ bảng màu của face cuối cùng; dùng trong `paint_text.synthOf`, `svg_out_text.synthOf`, `pdf/emit_text.synthOf`; `pdf/text.zig` chỉ hỏi `isColorGlyph` khi face có bảng màu. Đo wasm full, PNG 1200x2400 khoảng 30k ký tự Inter: 85 → 74 ms/render (−13%). Test Zig `glyph synthesis reads a face's colour tables once per run of its glyphs`.
- **DoS segment dài ngoài Latin:** `longSegmentBreak` sau 4×`max_segment` (16K ký tự) nay còn cắt giữa hai ký tự CJK/kana/Hangul/dấu câu CJK/full-width, hoặc trước phụ âm Thái/Lào (không sau nguyên âm đứng trước). Văn bản Thái không dấu cách 72K ký tự: 2019 ms → 352 ms (debug), tỉ lệ 4x độ dài ≈ 3,8x thời gian. Test `long unspaced Thai and CJK runs shape in linear time (fuzz regression)` (`src/fuzz.zig`, fail trước fix: 120 → 2019 ms).

Sau thay đổi (wasm): strict audit **2.196 probe, 2.171 pass, 0 fail, 25 expected (22 deliberate + 3 open), 0 unverified, 0 stale; exit 0**; golden 125 IDENTICAL / 10 CLOSE / 1 DIFFER, `--strict` 18 khác biệt đều liệt kê; PDF Zig 769/769 (+6); `zig build test` 747 pass / 21 skip (+6; oracle fixture 850/850); `test:pdf` 401/401; `test:pdf:chunks` 55/55 tương đương; coverage `--strict` 0 vấn đề (verified 126); `test:pdf:gate` 11/11 (cần `bench/out/pdf-oracle` trong worktree); `test:js`, `test:limits` (wasm) pass. Native chưa build lại trong lượt này.
File đổi: `src/font/text.zig`, `src/pdf/text.zig`, `src/paint.zig`, `src/paint_text.zig`, `src/svg_out.zig`, `src/svg_out_text.zig`, `src/pdf/emit.zig`, `src/pdf/emit_text.zig`, `src/fuzz.zig`, test: `src/font/tests.zig`, `src/font/tests_shaping.zig`, `src/pdf/filelayer_tests.zig`; `scripts/pdf-audit/{exceptions.json,text-tails.probe.mjs,images.probe.mjs}`, `scripts/pdf-coverage-map.json`, `docs/PDF_AUDIT.md`.

## 2026-11-23 cắt trong bảng/flex/grid, dòng đầu bị float đẩy, marker cạnh box con, report trên trang nhỏ (task 11, 16, 18, 19–21, gate 27)

Baseline (HEAD `f4fb567`): strict audit 2.187 probe, 26 expected, exit 0; golden 125/10/1; PDF Zig 763/763; `zig build test` 741 pass / 21 skip; `test:pdf` 401/401; chunks 55/55.

- **Task 19–21 (cắt từng phần):** `paged.resumeKid` nhận token một điểm đi qua row group / row của bảng, container flex / grid và item của chúng; `chunks.flowPlan` bỏ điều kiện con có box positioned/transform. Chunks 75/75 tương đương (native, wasm; +20 case, 12 case `parts: true` fail ở HEAD). Bộ nhớ (native): stress 500 trang không đổi (peak 52,96 MiB: DOM + style, cắt tại forced break); 700 section không đổi (×1,036 / ×1,064, 7,61 MiB); bảng dài không forced break 200 bảng: 186,93 → 70,82 MiB, 4,17 → 8,58 ms/trang. Chưa làm: token có nhánh (row/line bị cắt giữa), rowspan đang chạy, một bảng rất dài (mỗi phần layout lại cả bảng). Chi tiết: `streaming-chunks.md`, `docs/PDF_FRAGMENT_DESIGN.md` §5/§7/§8.
- **Task 16/18:** token dòng 0 (dòng đầu bị float đẩy sang trang sau, kể cả float rộng hơn container trên trang đổi width) nay tiếp tục ở width mới (`src/layout/fragment.zig` `startY` lấy min các luồng, `mainStartY` nhận dòng 0; `src/pdf/paged.zig`; `src/render.zig`). Zig + `pagination.float.oversized` (3 case alternating mới) fail trước fix.
- **Task 11:** marker ngoài của item bắt đầu bằng flex/grid/table/ảnh block (`src/pdf/markers.zig`, `src/layout/{style,block,tree,grid}.zig`, `src/render.zig`); 9 probe `lists.image.host-*` + 1 tagged khớp oracle (4 probe `differs` cũ thành `same`); Zig mới fail trước fix.
- **Bảng là flex item, trang cuối (exception `upstream.content_beside_a_table…`):** đã đối chiếu Chrome (Playwright Chromium in PDF): Chrome giống takumi — bảng bị stretch theo flex line (`align-items: stretch`) và phần block size dư của chiều cao xác định đó dồn cho các row của fragment cuối; với `align-items: start` cả ba engine giữ chiều cao row. Lỗi của bm, chưa sửa (cần mang block size xác định của bảng stretch qua các fragment); reason trong `exceptions.json` đã cập nhật.
- **window_scenes trang nhỏ:** report 250x90 (24 vs 23 trang) đã sửa — trong flex column, margin cuối của item trước điểm break bị mang sang trang sau; nay bị cắt tại đầu trang (margin của chính item và `gap` giữ nguyên), như takumi và Chrome (`src/layout/fragment.zig`; Zig `paged flex column: …` fail trước fix); 2 exception `report.html 250x90` của `page_summaries…` bỏ (stale). Còn mở: report 300x120 (đoạn appendix kết thúc trong trang 13 nhưng margin cuối thì không: takumi và Chrome giữ ở trang 13 và thêm trang trống, bm chuyển sang trang 14), invoice trên trang 120/90 px, certificate (glyph ở mép trang 523x770, trang nhỏ) — chưa điều tra tiếp.

Sau thay đổi: strict audit (pinned `ff9a5d4`) **2.192 probe, 2.166 pass, 0 fail, 26 expected, 0 unverified, 0 stale; exit 0** trên wasm và native; golden 125/10/1, `pdf-compare.mjs --strict` 18 khác biệt đều liệt kê; PDF Zig 766/766 (+3, mỗi test fail trước fix — đã chạy trên bản sao HEAD + test mới); `zig build test` 743 pass / 22 skip; `test:pdf` 401/401 (wasm, native); `test:pdf:chunks` 75/75 (native, wasm); `test:pdf:memory` pass; coverage `--strict --audit` 0 vấn đề; `gates.test.mjs` 11/11. Không đụng `src/font/text.zig`, `src/pdf/emit_text.zig`, paint_text, SVG text (agent khác đang sửa).

## 2026-11-23 bảng stretch trong flex row bị cắt qua trang (khác biệt open `upstream.content_beside_a_table…` đã đóng)

Baseline (HEAD `b1ffdc1`, wasm, oracle pinned `ff9a5d4`): strict audit 2.201 probe, 25 expected, exit 0; golden 125/10/1; PDF Zig 772/772; `zig build test` 749 pass / 22 skip; `test:pdf` 401/401.

- **Quy tắc của Chrome / Blink / takumi (đã đo bằng Playwright Chromium in PDF và oracle):** không phải “dồn phần dư cho fragment cuối” theo chiều cao cũ. Blink `FlexLayoutAlgorithm` (`row_cross_size_updates`): ở trang mà flex line kết thúc, item kết thúc ở trang đó mà vượt quá line thì line lớn thêm đúng phần vượt (X = đáy item − đáy line; item còn tiếp sang trang sau thì line lớn tới cuối trang), rồi các item stretch được layout lại với line mới. Bảng stretch tới B + X chia lại block size cho các row của tbody **theo tỉ lệ block size tối thiểu của từng row** (`DistributeTableBlockSizeToSections` → `DistributeExcessBlockSizeToRows`, không chia đều; phần dư làm tròn 1/64 px vào row cuối); chỉ các row của fragment đó và sau đó nhận kích thước mới (fragment trước đã xong). Khi line kết thúc một trang trước bảng (header lặp lại đẩy bảng sang thêm trang) thì xảy ra hai lần: lần đầu tới cuối trang, lần sau trên trang kế. Item khác của line giữ nội dung như cũ, box của nó tới đáy line mới (ngắn hơn bảng đúng phần row lớn thêm); container kết thúc cùng bảng. Đo: hàng 2 dòng (30 px) lớn thêm 1,875 lần hàng 1 dòng (16 px); trường hợp item cao 900 px, header cao, footer lặp lại đều khớp takumi tới 0,01 px và Chrome (snap pixel).
- **Sửa:** `src/render.zig` `Frame.stretchedTables` / `stretchRowFlexTables`: sau khi phân trang, với bảng là item của flex row (align-self stretch, `height: auto`, container không phải single-line có chiều cao xác định), tìm trang chứa đáy line, tính X, thêm một `layout.fragment.TableStretch` (`segs`: từ row nào, bảng cao bao nhiêu) rồi layout lại cả frame và phân trang lại (vòng lặp giống float, mỗi bảng một trang mỗi lượt). `src/layout/table.zig`: bảng có `TableStretch` chia lần lượt từng kích thước cho các row (mỗi lần trên các row lần trước để lại, như break token của Blink giữ rows), row thuộc đoạn nào lấy chiều cao của đoạn đó; grid = các row. `src/layout/flex.zig`: `Line.excess` — item khác stretch tới line cũ (`h0`). `src/layout/fragment.zig`: `TableStretch`/`StretchSeg`; `applyBand` tính “full” và đáy mới theo line (bỏ phần row lớn thêm của bảng, `stretch_excess` đo trước khi cắt). Output không phân trang không đổi (không có `TableStretch`).
- **Test (fail trước fix — đã chạy lại với nguồn HEAD):** Zig `paged: a table stretched in a flex row gives its last fragment's rows the line's growth (Blink / Chrome / takumi)` (row các trang trước giữ chiều cao, row trang cuối lớn theo tỉ lệ, tổng = phần của X, item bên cạnh tới đáy line, container/`After` theo bảng, flex column và layout không phân trang không đổi). Probe mới `pagination.flex.stretched-table` 11 case (stretch 3 trang / 2 trang, `align-items:start`, hàng hai chiều cao, item cao hơn bảng, rowspan ở fragment cuối, header cao làm line kết thúc trước bảng một trang, tfoot lặp lại, nền để so box, flex column, container cao xác định): HEAD 10 fail, sau fix 56/56 assertion pass. Exception `open` của `upstream.content_beside_a_table…` bị xóa (probe PASS); coverage map giữ `verified`, reason cập nhật; `docs/PDF_AUDIT.md` dòng tương ứng thành ported+equivalent.
- **Khác biệt có sẵn, ngoài phạm vi (không do sửa này, có cả với `align-items:start` hoặc bảng block):** bảng không có thead: bm giữ border-spacing 2 px ở đầu trang tiếp theo, takumi/Chrome bỏ; row có rowspan nằm ngay ranh giới trang được đẩy khác takumi; row cao (đã được chia block size) bị cắt giữa trang thì phần còn lại trên trang sau ngắn hơn takumi (bảng `height` lớn, Inter 12px/16px, trang 300x220). Probe mới tránh các trường hợp đó. Đã sửa 2026-11-23: xem checkpoint “phân trang bảng: border-spacing ở chỗ ngắt…” bên dưới.

Sau thay đổi (wasm): strict audit **2.202 probe, 2.178 pass, 0 fail, 24 expected, 0 unverified, 0 stale; exit 0**; golden 125 IDENTICAL / 10 CLOSE / 1 DIFFER, `--strict` 18 khác biệt đều liệt kê; PDF Zig 773/773 (+1); `zig build test` 750 pass / 22 skip (+1); `test:pdf` 401/401; `pdf-chunks-check --backend=wasm` tất cả tương đương; coverage `--strict` 0 vấn đề; `test:pdf:gate` 11/11 (oracle symlink vào `bench/out/pdf-oracle` của worktree rồi gỡ). Native chưa build lại.
File đổi: `src/render.zig`, `src/layout/{fragment,table,flex}.zig`, test `src/test_paged.zig`; `scripts/pdf-audit/{exceptions.json,pagination-layout.probe.mjs}`, `scripts/pdf-coverage-map.json`, `docs/PDF_AUDIT.md`.

## 2026-11-23 phân trang bảng: border-spacing ở chỗ ngắt, rowspan qua ranh giới trang, row cao do `height` của bảng

Baseline (HEAD `d1eb50c`, wasm, oracle pinned `ff9a5d4`): strict audit 2.202 probe, 24 expected, exit 0; golden 125/10/1; PDF Zig 773/773; `zig build test` 750 pass / 22 skip; `test:pdf` 401/401. Ba khác biệt ghi ở checkpoint trước (xảy ra cả với bảng block thường), đã đối chiếu từng case với Playwright Chromium in PDF và oracle; quy tắc theo Blink TableNG / CSS Fragmentation 3. Tất cả sửa trong `src/layout/fragment.zig`.

- **(1) Bảng không có thead giữ border-spacing 2 px ở đầu trang tiếp theo:** Chrome và takumi bỏ. Ở ngắt không bắt buộc, spacing trước row (giữa các row trong row group và giữa các row group) bị cắt như margin (`applySeq` `.before`, `rowSpacing`); trước đây row nằm ở vị trí stitched (spacing vắt qua cuối trang). Spacing sau row cuối khi row kết thúc đúng cuối trang cũng bị cắt (`probeSeq`: `trim` của bảng không có header/footer lặp lại, block-end border/padding sang trang sau); nội dung sau một bảng vượt cuối trang chỉ bằng spacing đó, hoặc bằng phần trang trí cuối đang "treo" của bảng có thead lặp lại, bắt đầu ở đầu trang sau (`reach` cắt tại cuối trang). Bảng có `height` xác định giữ chiều cao khi row bị kéo lên (`grow`).
- **(2) Rowspan ở ranh giới trang:** Chrome/takumi: khi một ô rowspan từ row phía trên đi qua chỗ ngắt, Blink tiếp tục row đó trước (fragment rỗng ở đầu trang) rồi mới đến spacing và row kế: row sau ở `spacing` (hoặc `thead + 2×spacing`), row bị cắt giữa cũng lùi theo (`spanCrosses`). Lỗi "đẩy sang trang khác": row chỉ có một ô của riêng nó (các ô khác là rowspan) đi đường `single` nên ô middle/bottom không được dời lên đầu fragment (`cellRealign`) → dòng chữ bị cuối trang cắt → cả row bị đẩy sang trang sau; nay `probeSeq`/`applySeq` realign như row nhiều ô.
- **(3) Row cao (được chia block size từ `height` của bảng) bị cắt khác chỗ:** (a) ngắt trong khoảng trống của ô chỉ là perfect khi nội dung và padding cuối của ô vừa trang; nếu không thì last resort và row sang trang sau nguyên khối (Blink `FinishFragmentation`; trước đây bm cắt row); (b) phần còn lại của ô bị cắt trong khoảng trống tiếp tục dưới thead lặp lại và spacing của nó (`.span` apply lớn thêm `pg.next - pg.end`; trước đây nằm ở offset cũ, dưới thead).
- **Chrome khác takumi (theo Chrome, exception `deliberate`):** bảng `height` xác định có thead lặp lại, row cuối bị cắt trong khoảng trống: Chrome đặt fragment cuối dưới thead rồi mới đến block sau bảng; takumi đặt block đó ở đầu trang cuối, đè lên thead. Còn lại (bm = takumi, Chrome khác, không sửa vì ngoài phạm vi): block sau bảng có rowspan / border cuối vẫn vừa trang thì Chrome giữ lại, bm và takumi đẩy sang trang sau; bảng 700 px spacing 10 px có thead: Chrome ít hơn một trang.
- **Test (fail trước fix — chạy với `fragment.zig` của HEAD):** Zig `paged tables: the border spacing at a break is truncated like a margin (Chrome, takumi)`, `paged tables: a cell spanning rows over a break resumes its row first, the spacing after it stays (Chrome, takumi)`, `paged tables: rows grown by a definite table height break like Chrome and takumi` (15 vị trí kiểm tra fail ở HEAD). Probe mới `pagination.table.spacing-breaks` 16 case (HEAD: 16 fail; sau fix 15 khớp oracle, 1 là exception theo Chrome); cả 16 case cũng khớp Chrome.

Sau thay đổi (wasm): strict audit **2.203 probe, 2.178 pass, 0 fail, 25 expected, 0 unverified, 0 stale; exit 0**; golden 125 IDENTICAL / 10 CLOSE / 1 DIFFER, `--strict` 18 khác biệt đều liệt kê; PDF Zig 776/776 (+3); `zig build test` 753 pass / 22 skip (+3); `test:pdf` 401/401; `pdf-chunks-check --backend=wasm` tất cả tương đương; coverage `--strict` 0 vấn đề; `test:pdf:gate` 11/11 (oracle symlink rồi gỡ). Native chưa build lại.
File đổi: `src/layout/fragment.zig`, test `src/test_paged.zig`; `scripts/pdf-audit/{exceptions.json,pagination-layout.probe.mjs}`, `docs/PDF_AUDIT.md`.
