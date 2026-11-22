# Task 19–21: streaming theo chunk

Hướng đã chọn (2026-11-17): chia tài liệu thành chunk tại các điểm ngắt trang cưỡng bức an toàn; mỗi chunk được layout, emit rồi giải phóng. Nếu không an toàn thì fallback về layout toàn bộ (đường hiện tại). Đây không phải port LayoutNG: chỉ cắt được tại forced break.

## Số đo ban đầu (native, stress doc, live bytes qua `memoryTrace`)

200 trang, so với baseline: parse+CSS +8,3 MiB; style +1,5; **render nodes +29,1** (shaping nằm ở đây); layout +2,0; paginate +9,5 tạm thời (rồi giải phóng 8,9); vẽ trang và ghi file +17 → peak 59,5 MiB. Peak khoảng 280–330 KiB/trang, tăng tuyến tính. Footer counter pass không ảnh hưởng đáng kể.

Emission ổn định: live tại đầu trang 1/50/100/150/200 = 42,5/44,8/45,2/46,3/47,3 MiB (khoảng 25 KiB/trang cho stream đã nén, resource, link). Band có counter được layout lazy trong bộ nhớ trang và rewind mỗi trang. Phần giữ lại chủ yếu là layout toàn tài liệu: 42 MiB/200 trang, trong đó render nodes 29 MiB.

**Lưu ý về tiêu chí 21:** `memory_tests.rs` của takumi dùng 700 section chảy liền nhau, không có forced break, header có `totalPages` và 2 pass. Chunk tại forced break không đạt được test này. Muốn đạt phải cắt tại ranh giới trang bất kỳ: trang đã settle = mọi trang trừ 1–2 trang cuối của chunk; chunk sau bắt đầu từ token tiếp nối của trang chưa settle (cơ chế `laySegments`), nhưng token phải theo DOM chứ không theo render node id, vì frame con có cách đánh số khác. Làm sau, khi hạ tầng và forced break đã chạy đúng.

**Ranh giới (đã xác minh với takumi trên stress 3 trang):** phần tử đầu tiên sau forced break bắt đầu đúng tại đáy trang trước. Takumi và bm whole mở một vùng MCID rỗng trên trang trước cho heading của nó (`H1 [p1:49, p2:0]`), và vẽ bảng của nó như một fragment tiếp nối, nên thứ tự text khác với trang 1. Frame chunk không có con ở hai bên thì sai cả hai chỗ này; `walk_all` không phải nguyên nhân (đã thử). Cách xử lý: frame chunk k chứa thêm con cuối của chunk k−1 và con đầu của chunk k+1, nhưng chỉ vẽ các trang của chunk k, với `prev_win`/`next_win` là các trang lân cận của chính frame đó. Tag record của con chồng lấn phía sau được chuyển sang chunk k+1 (khóa theo phần tử DOM). Record rơi vào con chồng lấn phía trước, hoặc bất cứ gì không khớp, thì bỏ chunk và layout cả tài liệu.

## Lifetime

- **Document** (giữ đến cuối): source, DOM + computed style + pseudos + CSS matcher (`Frame` dừng trước `buildElement`), font registry/subset, object ID, nội dung page stream đã encode, anchor và destination đã quy ra (trang, y), cây tag đã build, outline.
- **Chunk** (một arena, giải phóng sau khi emit): render nodes, layout tree, paragraphs, pagination, page scratch.

## Điều kiện an toàn (v1, bảo thủ)

- Geometry `page`, mọi trang cùng chiều rộng.
- Có một chuỗi tổ tiên "trong suốt" từ root tới flow container: block, width/height auto, không background/border/shadow/outline/transform/position/overflow, không ::before/::after, role tag rỗng. Margin/padding trên/dưới của tổ tiên được bỏ ở chunk giữa: chunk k>0 bỏ phần trên, chunk k<last bỏ phần dưới. Cần xác nhận bằng identity test.
- Ranh giới là giữa hai con trực tiếp của flow container, với `break-after: page|left|right|recto|verso` ở con trước hoặc `break-before` ở con sau.
- Không có `position: fixed`; không có absolute nào mà containing block nằm ngoài chunk; không có float ở con trực tiếp.
- Sau layout, ink của chunk không vượt ra ngoài các trang của nó; vi phạm thì fallback.
- Content không có counter hook (`subst.hooks` rỗng); có hook thì fallback. Band động (pageNumber/totalPages) được xử lý bằng pass đếm.

## Các lát

1. **Instrumentation** (đã làm): `src/memtrace.zig`; native `memoryPeak(reset)`, `memoryTrace(on)`.
2. **Emitter incremental**: tách `writeDocument` thành `DocWriter.init / drawRun(frame, pages, windows) / finish`. Links/headings/anchors quy về (trang, y) ngay khi một run được vẽ; cây tag build theo từng run và nối lại. Byte output không được đổi (golden + audit).
3. **DOM dùng chung**: `Frame.prepareDocument` dừng trước `buildElement`; `Frame.forChunk(doc, arena, range)` copy nông các field giai đoạn style, field layout để mới; `buildElement` lọc con của flow container theo khoảng DOM.
4. **Chunk planner + vòng paged**: tìm ranh giới, pass đếm khi band động, vòng layout→paginate→vẽ→giải phóng với page offset, kiểm tra ink và fallback.
5. **Kiểm chứng**: identity giữa chunked và whole-doc trên corpus (`BM_PDF_CHUNKS=off` buộc whole-doc); memory invariant: live sau trang 200 ≤ live sau trang 50 × 1,1 (700 section); scaling 100/500 trang; full Zig, PDF API, golden, audit.

## Trạng thái 2026-11-17 (cuối phiên)

Đã làm: lát 1–5 cho trường hợp forced break.
- `Frame.prepareDocument` / `prepareLayout` / `initChunk`, `PagedState.chunk`, `markers.forChunk`.
- `emit.DocWriter` (`beginChunk` / `drawPages` / `endChunk` / `collect` / `finish`); anchor và heading được quy ra destination theo phần; `tags.Builder` theo frame với `Skip` / `Carry`; annotation được đăng ký trước.
- `chunks.plan` (flow, forced break, part ≥ 2048 phần tử, gộp phần khi có link về sau) và `paged.writeChunked`: pass đếm, seam (`origin` / `root_shift`), chồng lấn, refuse → layout whole.
- Dung sai ở cạnh trang: `Pages.pageAt` và `Window.excludes`. Cạnh do cộng float theo thứ tự khác, chỉ cỡ vài bước float; golden và audit không đổi.
- Công cụ: `scripts/pdf-chunks-check.mjs`, `scripts/pdf-hashes.mjs`; `pdf-audit` ghi report đồng bộ và không để lại PDF tạm.

Kiểm chứng: 26/26 case tương đương (chunk vs whole, native và wasm), byte-identical tới khoảng 30 trang. Corpus 159/160 trùng byte với baseline, riêng `stress/100p` giờ được chunk và tương đương. Golden 125/10/1, không đổi. Audit strict 1548/23, cùng tập fail trên cả hai backend. PDF API 399/399 mỗi backend; test plateau bỏ lần render làm nóng. Zig 682/682.

Còn lại (khi đó):
1. Cắt tại ranh giới trang bất kỳ: token tiếp nối theo phần tử DOM, để chạy được tài liệu của `memory_tests.rs`.
2. Bộ nhớ DOM + style, khoảng 55 KiB/trang ở stress doc.
3. Ghi object và ráp file theo luồng thay vì ráp cả file cuối cùng.
4. Mở rộng điều kiện plan: body có margin (cắt bỏ margin của tổ tiên ở các phần giữa), float trong phần, hộp `fixed`.

## Trạng thái 2026-11-22: cắt tại ranh giới trang bất kỳ

`chunks.plan` trả `Cut`: `.forced` (như trên, ưu tiên) hoặc `.flowing` (`chunks.Flow`) khi không có forced break hay link nối mọi phần. Điều kiện của flow giữ nguyên; thêm: mọi con của flow sinh box đều là block. `Flow.cuttable[k]`: phần có thể bắt đầu trong con k, trừ khi một link `#id` ở con ≤ k tới con ≥ k, hoặc con k chứa box positioned/transform (box được "lift" khỏi page pass tag trang khác đi khi con bị layout từ giữa: đã thấy với translate + relative).

Vòng `paged.FlowIter` (dùng cho cả pass đếm `countFlow` lẫn pass vẽ):
- Phần k: frame `initChunk` với khoảng `[kids[kid0], kids[j])`, j sao cho ≥ `chunk_elements / 4` phần tử (`flowBudget`) và ≥ 3 con; thiếu chỗ cắt thì nhân đôi và layout lại. Phần đầu mà phải chứa cả tài liệu thì refuse.
- Phần k > 0 tiếp tục từ `Resume`: `NodeKey` (phần tử gần nhất + đường đi con, như `tags.Carry`), dòng + glyph đầu dòng (kiểm tra đoạn văn ngắt giống hệt), top của trang (start_top), top trang trước (`origin`: trang 0 của frame trùng trang trước trong tài liệu, nên các pass trang lân cận như whole), top trang sau (kiểm tra trang 1 kết thúc cùng chỗ), top của con kid0 (`root_shift`). `fragment.zig`: root_shift áp trước khi tính start; trang 1 bắt đầu đúng `start_top` (`tops[1] = start_h`, không đổi gì khi origin = 0).
- Trang cắt c: trang lớn nhất ≤ len−2 có token một điểm (không branches/side flows), chuỗi box tới flow chỉ là block/list-item tĩnh/relative, con ki ≤ j−2 và cuttable. Phần vẽ trang [s, c); con ≥ ki chuyển sang phần sau (`tags.Skip.hi`), kèm anchor/heading của chúng (`handOn`/`takeOn`: chunk + render node của destination UA-2).
- Kiểm tra ink bằng `Extents.computeWith(glyphs = false)` (dòng chữ chỉ vẽ trên trang chứa nó): con < ki không vẽ xuống dưới trang c, con > kid0 không vẽ lên trên trang s.
- Token ghi ở trang 1 có thể là "không một điểm" khi nội dung kết thúc đúng tại start (walk tới trang trước khi main flow tới): khi đó chỉ dựa vào kiểm tra top trang 2.

Bộ nhớ khi vẽ (call arena là bump, không tái dùng chỗ đã free): `sanitizedText` / `clusterStarts` (cache theo trang) chuyển sang bộ nhớ trang (~800 B/trang); `Doc.finish` cấp phát file một lần (struct element đóng gói thì không tính trước).

Số đo (native, live bytes qua `memoryTrace`, `npm run test:pdf:memory`):
- 700 section (`memory_tests.rs`): 350 trang, 5 phần. Pass đếm live trang 50 / 200 = 4,48 / 4,64 MiB (×1,036); pass vẽ 5,74 / 6,10 MiB (×1,064). Peak 18,7 → 7,6 MiB. Peak theo số section: 350 / 700 / 1400 / 2800 → 5,9 / 7,6 / 12,9 / 21,9 MiB (trước: 9,9 / 18,7 / 33,4 / 61,7).
- Stress (forced break): 100 trang peak 19,6 → 19,1 MiB; 500 trang 59,6 → 53,0 MiB, live trang 50 / 200 = 35,6 / 41,0 MiB, 1,7 ms/trang, 3,7 KiB/trang.

Kiểm chứng: chunks check 55/55 tương đương (native và wasm, 22 case `flow-*` mới, phần lớn trùng byte); corpus 160/160 trùng byte với HEAD (native và wasm); golden 125/10/1 không đổi; audit (có reference) 1530 pass / 41 fail, cùng tập fail với HEAD và giữa hai backend; PDF API 399/399 mỗi backend; Zig 703/703 (`-Dprofile=pdf`) và 688/702 (14 skip).

Còn lại:
1. Cắt trong bảng / flex / grid (token có branches) và trong con có box positioned/transform.
2. DOM + style vẫn tuyến tính (stress ~55 KiB/trang); tích lũy khi emit ~11 KiB/trang ở stress (content stream, cây tag giữ đến cuối, heading), ~2–4 KiB/trang ở 700 section.
3. Ráp file: map/rows theo số object và cây tag đóng gói vẫn nằm cùng lúc với file.
4. Pass đếm + pass vẽ = layout hai lần khi band có totalPages (whole cũng vậy chỉ khi margin theo band).
