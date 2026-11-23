//! Phase-2 text tests: OpenType layout engine, script shapers, normalisation, bidi, UAX #14,
//! text-wrap strategies, fuzzing. Expected advances come from the takumi oracle
//! (`@takumi-rs/wasm` 2.20.0) with the same font files.
const std = @import("std");
const t = std.testing;
const font = @import("font.zig");
const ot = @import("ot.zig");
const uni = @import("unicode.zig");
const bidi = @import("bidi.zig");
const text = @import("text.zig");
const shp = @import("shape.zig");

const inter = @embedFile("testdata/Inter-Regular.ttf");
const noto = @embedFile("testdata/NotoSans-Regular.ttf");
const roboto = @embedFile("testdata/Roboto-Regular.ttf");
const naskh = @embedFile("testdata/NotoNaskhArabic-Regular.ttf");
const hebrew = @embedFile("testdata/NotoSansHebrew-Regular.ttf");
const thai = @embedFile("testdata/NotoSansThai-Regular.ttf");
const deva = @embedFile("testdata/NotoSansDevanagari-Regular.ttf");
const beng = @embedFile("testdata/NotoSansBengali-Regular.ttf");

fn collection(a: std.mem.Allocator) !font.FontCollection {
    var fc: font.FontCollection = .{};
    errdefer fc.deinit(a);
    for ([_][]const u8{ inter, noto, roboto, naskh, hebrew, thai, deva, beng }) |d| _ = try fc.register(a, d, .{});
    return fc;
}

fn widthOf(fc: *const font.FontCollection, s: []const u8, fam: []const u8, size: f32, rtl: bool) !f32 {
    var p = try font.Paragraph.init(t.allocator, fc, &.{.{ .text = s, .style = .{ .families = &.{fam}, .size = size } }}, .{ .direction = if (rtl) .rtl else .ltr });
    defer p.deinit();
    return p.maxContentWidth();
}

test "complex scripts: advances vs oracle" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    const Case = struct { s: []const u8, fam: []const u8, size: f32, rtl: bool, w: f32 };
    const cases = [_]Case{
        .{ .s = "Hello AV To WA fi ffl Việt office", .fam = "Inter", .size = 48, .rtl = false, .w = 699.422 },
        .{ .s = "Vie\u{323}\u{302}t Nam đa\u{302}\u{301}t nu\u{31b}o\u{31b}\u{301}c tu\u{31b}o\u{31b}i đe\u{323}p", .fam = "Inter", .size = 48, .rtl = false, .w = 616.500 },
        .{ .s = "Vie\u{323}\u{302}t Nam đa\u{302}\u{301}t nu\u{31b}o\u{31b}\u{301}c tu\u{31b}o\u{31b}i đe\u{323}p", .fam = "Noto Sans", .size = 48, .rtl = false, .w = 622.609 },
        .{ .s = "السلام عليكم ورحمة الله", .fam = "Noto Naskh Arabic", .size = 48, .rtl = true, .w = 406.766 },
        .{ .s = "بِسْمِ ٱللَّٰهِ ٱلرَّحْمَٰنِ ٱلرَّحِيمِ", .fam = "Noto Naskh Arabic", .size = 56, .rtl = true, .w = 455.953 },
        .{ .s = "שלום עולם", .fam = "Noto Sans Hebrew", .size = 48, .rtl = true, .w = 220.656 },
        .{ .s = "בְּרֵאשִׁית בָּרָא אֱלֹהִים", .fam = "Noto Sans Hebrew", .size = 56, .rtl = true, .w = 466.938 },
        .{ .s = "नमस्ते दुनिया हिन्दी", .fam = "Noto Sans Devanagari", .size = 48, .rtl = false, .w = 321.844 },
        .{ .s = "क्षत्रिय श्री कर्म धर्म विद्या द्वार कृष्ण", .fam = "Noto Sans Devanagari", .size = 48, .rtl = false, .w = 574.766 },
        .{ .s = "বাংলা ভাষা কর্ম ক্ষত্রিয় শ্রী", .fam = "Noto Sans Bengali", .size = 48, .rtl = false, .w = 480.969 },
        .{ .s = "สวัสดีครับ น้ำ ที่ ปั้น ผู้", .fam = "Noto Sans Thai", .size = 48, .rtl = false, .w = 407.625 },
    };
    for (cases) |c| try t.expectApproxEqAbs(c.w, try widthOf(&fc, c.s, c.fam, c.size, c.rtl), 0.01);
}

fn shapeGids(fc: *const font.FontCollection, s: []const u8, fam: []const u8, out: []u16) !usize {
    const gs = try font.shape(t.allocator, fc, s, .{ .families = &.{fam}, .size = 100 });
    defer t.allocator.free(gs);
    for (gs, 0..) |g, i| out[i] = g.gid;
    return gs.len;
}

test "normalisation: decomposed input maps to the precomposed glyphs" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    var a: [32]u16 = undefined;
    var b: [32]u16 = undefined;
    for ([_][]const u8{ "Inter", "Noto Sans", "Roboto" }) |fam| {
        const na = try shapeGids(&fc, "Việt đất nước ở", fam, &a);
        const nb = try shapeGids(&fc, "Vie\u{323}\u{302}t đa\u{302}\u{301}t nu\u{31b}o\u{31b}\u{301}c o\u{31b}\u{309}", fam, &b);
        try t.expectEqualSlices(u16, a[0..na], b[0..nb]);
    }
    // a base the font has no precomposed glyph for keeps base + mark, mark has no advance
    const gs = try font.shape(t.allocator, &fc, "q\u{301}x", .{ .families = &.{"Inter"}, .size = 100 });
    defer t.allocator.free(gs);
    try t.expectEqual(@as(usize, 3), gs.len);
    try t.expectEqual(@as(f32, 0), gs[1].x_advance);
    try t.expect(gs[1].x_offset != 0 or gs[1].y_offset != 0); // GPOS mark attachment
    try t.expect(gs[1].flags & font.ShapedGlyph.NO_SPLIT != 0);
    try t.expectEqual(gs[0].cluster, gs[1].cluster);
}

test "arabic: joining forms, lam-alef, marks, visual order" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    // isolated beh differs from initial / medial / final beh (the font may split a letter
    // into base + dots, so sequences are compared)
    var iso: [8]u16 = undefined;
    var g: [24]u16 = undefined;
    const ni = try shapeGids(&fc, "ب", "Noto Naskh Arabic", &iso);
    const n3 = try shapeGids(&fc, "ببب", "Noto Naskh Arabic", &g);
    try t.expect(n3 >= 3);
    try t.expect(!std.mem.eql(u16, iso[0..ni], g[0..@min(ni, n3)])); // initial form first
    try t.expect(!std.mem.eql(u16, iso[0..ni], g[n3 - @min(ni, n3) .. n3])); // final form last
    // ZWNJ breaks joining (two isolated forms), ZWJ forces it; neither leaves a glyph
    const nz = try shapeGids(&fc, "ب\u{200c}ب", "Noto Naskh Arabic", &g);
    try t.expectEqual(ni * 2, nz);
    try t.expectEqualSlices(u16, iso[0..ni], g[0..ni]);
    try t.expectEqualSlices(u16, iso[0..ni], g[ni..nz]);
    const nj = try shapeGids(&fc, "ب\u{200d}", "Noto Naskh Arabic", &g);
    try t.expect(!std.mem.eql(u16, iso[0..ni], g[0..nj]));
    // lam-alef: contextual forms / ligature, not the two isolated glyphs
    var lam: [4]u16 = undefined;
    const n_lam = try shapeGids(&fc, "ل", "Noto Naskh Arabic", &lam);
    const n_la = try shapeGids(&fc, "لا", "Noto Naskh Arabic", &g);
    try t.expect(n_la < n_lam or !std.mem.eql(u16, lam[0..n_lam], g[0..n_lam]));
    // marks: zero advance, attached
    const gs = try font.shape(t.allocator, &fc, "بَ", .{ .families = &.{"Noto Naskh Arabic"}, .size = 100 });
    defer t.allocator.free(gs);
    try t.expectEqual(ni + 1, gs.len);
    try t.expectEqual(@as(f32, 0), gs[ni].x_advance);
    try t.expect(gs[ni].y_offset != 0 or gs[ni].x_offset != 0);
    try t.expectEqual(@as(u8, 1), gs[0].level);

    // layout: logical order is right to left on screen
    var p = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "ابج دهو", .style = .{ .families = &.{"Noto Naskh Arabic"}, .size = 40 } }}, .{ .direction = .rtl, .text_align = .start });
    defer p.deinit();
    var lay = try p.layout(t.allocator, 500);
    defer lay.deinit(t.allocator);
    try t.expect(lay.lines[0].rtl);
    // start-aligned = flush right
    try t.expectApproxEqAbs(@as(f32, 500), lay.lines[0].x + text.ceil64(lay.lines[0].width), 0.02);
    var prev_cluster: u32 = 0xffff_ffff;
    for (lay.glyphs) |pg| {
        // glyphs are emitted left to right = last character first
        try t.expect(pg.cluster <= prev_cluster);
        prev_cluster = pg.cluster;
        try t.expectEqual(@as(u8, 1), pg.bidi_level);
    }
}

test "devanagari: conjuncts, reph, matra reordering" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    const f = fc.font(6);
    var g: [16]u16 = undefined;
    // क्ष is one conjunct glyph
    try t.expectEqual(@as(usize, 1), try shapeGids(&fc, "क्ष", "Noto Sans Devanagari", &g));
    // कि: the i-matra glyph comes first
    try t.expectEqual(@as(usize, 2), try shapeGids(&fc, "कि", "Noto Sans Devanagari", &g));
    try t.expectEqual(f.glyphIndex(0x915), g[1]);
    try t.expect(g[0] != f.glyphIndex(0x915));
    // र्क: reph moves after the base
    try t.expectEqual(@as(usize, 2), try shapeGids(&fc, "र्क", "Noto Sans Devanagari", &g));
    try t.expectEqual(f.glyphIndex(0x915), g[0]);
    // न्दी: half na + da + ii
    const n = try shapeGids(&fc, "न्दी", "Noto Sans Devanagari", &g);
    try t.expectEqual(@as(usize, 3), n);
    try t.expect(g[0] != f.glyphIndex(0x928)); // half form
    // explicit halant with ZWNJ keeps the full form + visible halant
    try t.expectEqual(@as(usize, 3), try shapeGids(&fc, "क्\u{200c}ष", "Noto Sans Devanagari", &g));
    try t.expectEqual(f.glyphIndex(0x915), g[0]);
    // reordered / ligated parts share a cluster: no emergency break inside
    const gs = try font.shape(t.allocator, &fc, "र्कि", .{ .families = &.{"Noto Sans Devanagari"}, .size = 50 });
    defer t.allocator.free(gs);
    try t.expectEqual(@as(usize, 3), gs.len);
    for (gs[1..]) |x| {
        try t.expectEqual(gs[0].cluster, x.cluster);
        try t.expect(x.flags & font.ShapedGlyph.NO_SPLIT != 0);
    }
}

test "thai: sara am decomposition and stacked marks" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    var g: [16]u16 = undefined;
    // น้ำ = no nu + mai tho + sara am -> no nu, nikhahit, mai tho, sara aa
    const n = try shapeGids(&fc, "น้ำ", "Noto Sans Thai", &g);
    try t.expectEqual(@as(usize, 4), n);
    const gs = try font.shape(t.allocator, &fc, "ปั้น", .{ .families = &.{"Noto Sans Thai"}, .size = 100 });
    defer t.allocator.free(gs);
    try t.expectEqual(@as(usize, 4), gs.len);
    try t.expectEqual(@as(f32, 0), gs[1].x_advance);
    try t.expectEqual(@as(f32, 0), gs[2].x_advance);
}

test "bidi: levels, mirroring, brackets, numbers" {
    const a = t.allocator;
    const Case = struct { s: []const u21, base: u8, want: []const u8 };
    const cases = [_]Case{
        .{ .s = &.{ 'a', ' ', 0x5d0, 0x5d1, ' ', 'b' }, .base = 0, .want = &.{ 0, 0, 1, 1, 0, 0 } },
        .{ .s = &.{ 'a', ' ', 0x5d0, 0x5d1, ' ', 'b' }, .base = 1, .want = &.{ 2, 1, 1, 1, 1, 2 } },
        .{ .s = &.{ 0x5d0, ' ', '1', '2', ' ', 0x5d1 }, .base = 1, .want = &.{ 1, 1, 2, 2, 1, 1 } },
        .{ .s = &.{ 0x627, ' ', '1', '2', '.', '5', '%' }, .base = 1, .want = &.{ 1, 1, 2, 2, 2, 2, 1 } }, // digits after AL are AN: '%' does not join them
        // N0: brackets around RTL text in an LTR paragraph follow the content
        .{ .s = &.{ 'a', '(', 0x5d0, ')', 'b' }, .base = 0, .want = &.{ 0, 0, 1, 0, 0 } },
        .{ .s = &.{ 0x5d0, '(', 'a', ')', 0x5d1 }, .base = 1, .want = &.{ 1, 1, 2, 1, 1 } },
        // explicit override and isolate
        .{ .s = &.{ 0x202e, 'a', 'b', 0x202c, 'c' }, .base = 0, .want = &.{ 0, 1, 1, 1, 0 } },
        .{ .s = &.{ 'a', 0x2067, 0x5d0, 'b', 0x2069, 'c' }, .base = 0, .want = &.{ 0, 0, 1, 2, 0, 0 } },
    };
    for (cases) |c| {
        var lv: [16]u8 = undefined;
        try bidi.resolve(a, c.s, lv[0..c.s.len], c.base);
        try t.expectEqualSlices(u8, c.want, lv[0..c.s.len]);
    }
    try t.expect(!bidi.needsBidi(&.{ 'a', 0xe9, 0x4e2d }));
    try t.expect(bidi.needsBidi(&.{ 'a', 0x5d0 }));
    try t.expectEqual(@as(u21, ')'), uni.mirror('('));
    try t.expectEqual(@as(u21, 0xab), uni.mirror(0xbb));
    try t.expectEqual(@as(u21, 'a'), uni.mirror('a'));

    var fc = try collection(a);
    defer fc.deinit(a);
    // "(" in a Hebrew run is drawn with the ")" glyph
    var p = try font.Paragraph.init(a, &fc, &.{.{ .text = "א(ב)ג", .style = .{ .families = &.{"Noto Sans Hebrew"}, .size = 40 } }}, .{ .direction = .rtl });
    defer p.deinit();
    const f = fc.font(p.glyphs[1].face);
    try t.expectEqual(f.glyphIndex(')'), p.glyphs[1].gid);
    try t.expectEqual(f.glyphIndex('('), p.glyphs[3].gid);

    // mixed paragraph: an LTR word keeps its internal order inside an RTL line
    var q = try font.Paragraph.init(a, &fc, &.{.{ .text = "שלום abc עולם", .style = .{ .families = &.{ "Inter", "Noto Sans Hebrew" }, .size = 40 } }}, .{ .direction = .rtl });
    defer q.deinit();
    var lay = try q.layout(a, null);
    defer lay.deinit(a);
    var xa: f32 = 0;
    var xc: f32 = 0;
    var x_first: f32 = 0;
    var x_last: f32 = 0;
    for (lay.glyphs) |pg| {
        if (pg.cluster == 9) xa = pg.x; // 'a'
        if (pg.cluster == 11) xc = pg.x; // 'c'
        if (pg.cluster == 0) x_first = pg.x;
        if (pg.cluster == 19) x_last = pg.x;
    }
    try t.expect(xa < xc);
    try t.expect(x_first > xc and x_last < xa);
}

test "UAX #14: full rules behind Blink's overrides" {
    const B = struct {
        fn at(s: []const u21, i: usize, mode: uni.WordBreak) bool {
            var cls: [32]u8 = undefined;
            for (s, 0..) |c, k| cls[k] = uni.lbByte(c);
            uni.lineBreaks(cls[0..s.len], mode);
            return cls[i] & 0x80 != 0;
        }
    };
    try t.expect(B.at(&.{ 0x4e2d, 0x6587 }, 1, .normal)); // ID ÷ ID
    try t.expect(!B.at(&.{ 0x4e2d, 0x3002 }, 1, .normal)); // × CL
    try t.expect(!B.at(&.{ 0x300c, 0x4e2d }, 1, .normal)); // OP ×
    try t.expect(!B.at(&.{ 0x4e2d, 0x6587 }, 1, .keep_all));
    try t.expect(B.at(&.{ 0xe9, 0xe8 }, 1, .break_all));
    try t.expect(!B.at(&.{ 0xe9, 0xe8 }, 1, .normal));
    try t.expect(!B.at(&.{ 0xe9, 0x301 }, 1, .break_all)); // × CM
    try t.expect(!B.at(&.{ 0x1f468, 0x200d, 0x1f469 }, 1, .normal)); // × ZWJ
    try t.expect(!B.at(&.{ 0x1f468, 0x200d, 0x1f469 }, 2, .normal)); // ZWJ ×
    try t.expect(!B.at(&.{ 0x1f44d, 0x1f3fd }, 1, .normal)); // EB × EM
    try t.expect(B.at(&.{ 0x1f44d, 0x1f44d }, 1, .normal));
    try t.expect(!B.at(&.{ 0x1f1ef, 0x1f1f5, 0x1f1ef, 0x1f1f5 }, 1, .normal)); // RI × RI
    try t.expect(B.at(&.{ 0x1f1ef, 0x1f1f5, 0x1f1ef, 0x1f1f5 }, 2, .normal)); // pairs
    try t.expect(!B.at(&.{ 0x1f1ef, 0x1f1f5, 0x1f1ef, 0x1f1f5 }, 3, .normal));
    try t.expect(!B.at(&.{ 0x915, 0x94d, 0x937 }, 1, .normal)); // Devanagari conjunct stays whole
    try t.expect(!B.at(&.{ 0x915, 0x94d, 0x937 }, 2, .normal));
    try t.expect(!B.at(&.{ 0xe01, 0xe32 }, 1, .normal)); // Thai: no dictionary, no breaks inside
    try t.expect(B.at(&.{ 0xe01, 0xe32, '.' }, 2, .normal)); // ... but always after a run (ICU4X)
    try t.expect(!B.at(&.{ 'x', 0xe01, 'x' }, 2, .normal)); // a single SA character is plain AL
    try t.expect(!B.at(&.{ 0x5d0, '-', 0x5d1 }, 2, .normal)); // LB21a (15.0 form)
    try t.expect(!B.at(&.{ ')', '%' }, 1, .normal)); // LB25 pair form
    try t.expect(!B.at(&.{ 0x5d0, 0x5d1 }, 1, .normal)); // HL × HL
    try t.expect(!B.at(&.{ 0x20ac, 0x4e2d }, 1, .normal)); // PR × ID
    try t.expect(!B.at(&.{ 0xac00, 0x11a8 }, 1, .normal)); // H2 × JT
    try t.expect(B.at(&.{ 0xac00, 0xac01 }, 1, .normal)); // Hangul syllables break
    try t.expect(!B.at(&.{ 0x2014, 0x2014 }, 1, .normal)); // B2 × B2

    // through the paragraph: emoji ZWJ sequence stays on one line even with anywhere-wrapping
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    var p = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "ab 👨‍👩‍👧 cd", .style = .{ .families = &.{"Inter"}, .size = 20 } }}, .{ .overflow_wrap = .anywhere });
    defer p.deinit();
    var lay = try p.layout(t.allocator, 1);
    defer lay.deinit(t.allocator);
    for (lay.lines) |ln| {
        // no line starts inside the emoji sequence (bytes 3..21)
        const c = lay.glyphs[ln.glyph_start].cluster;
        try t.expect(c <= 3 or c >= 21);
    }
}

test "simple path (complex = false) equals the complex path for Latin" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    const s = "The quick brown fox — office AVATAR Tô yêu Việt Nam; “quotes” (kerning) well-known f\u{200c}i";
    for ([_][]const u8{ "Inter", "Noto Sans", "Roboto" }) |fam| {
        for ([_]f32{ 0, 1.5 }) |ls| {
            const runs = [_]font.Run{.{ .text = s, .style = .{ .families = &.{fam}, .size = 17, .letter_spacing = ls } }};
            var a = try font.Paragraph.initEx(true, t.allocator, &fc, &runs, .{});
            defer a.deinit();
            var b = try font.Paragraph.initEx(false, t.allocator, &fc, &runs, .{});
            defer b.deinit();
            try t.expectEqual(a.glyphs.len, b.glyphs.len);
            for (a.glyphs, b.glyphs) |x, y| {
                try t.expectEqual(x.gid, y.gid);
                try t.expectEqual(x.x_advance, y.x_advance);
                try t.expectEqual(x.flags, y.flags);
            }
            for ([_]f32{ 80, 200, 333 }) |w| try t.expectEqual(a.measure(w), b.measure(w));
        }
    }
}

test "text-overflow hides what overflows at the visual end of a line that mixes directions" {
    // "abc <ar1> <ar2> def ghi" in a left-to-right line shows "abc <ar2> <ar1> def ghi": the
    // right end goes first, so <ar1> (logically first, visually right) goes before <ar2>
    // (CSS Overflow 3; Blink LineTruncator, takumi). A logical cut kept <ar1> instead.
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    const st: font.TextStyle = .{ .families = &.{ "Inter", "Noto Naskh Arabic" }, .size = 20 };
    const s = "abc \u{645}\u{631}\u{62d}\u{628}\u{627} \u{628}\u{627}\u{644}\u{639}\u{627}\u{644}\u{645} def ghi";
    const ar1: [2]u32 = .{ 4, 14 };
    const ar2: [2]u32 = .{ 15, 29 };
    var inside = false;
    var w: f32 = 40;
    while (w < 260) : (w += 4) {
        var l = try font.layoutText(t.allocator, &fc, &.{.{ .text = s, .style = st }}, .{ .max_width = w, .white_space = .nowrap, .ellipsis = true });
        defer l.deinit(t.allocator);
        var kept1 = false;
        var kept2: usize = 0;
        var n2: usize = 0;
        // (the last glyph is the marker)
        for (l.glyphs[0 .. l.glyphs.len - 1]) |g| {
            if (g.cluster >= ar1[0] and g.cluster < ar1[1]) kept1 = true;
            if (g.cluster >= ar2[0] and g.cluster < ar2[1]) kept2 += 1;
        }
        var full = try font.layoutText(t.allocator, &fc, &.{.{ .text = s, .style = st }}, .{ .white_space = .nowrap });
        defer full.deinit(t.allocator);
        for (full.glyphs) |g| if (g.cluster >= ar2[0] and g.cluster < ar2[1]) {
            n2 += 1;
        };
        if (kept1) try t.expectEqual(n2, kept2);
        if (kept2 != 0 and !kept1) inside = true;
    }
    try t.expect(inside);
}

test "letter-spacing in a cursive script still applies at its word separators" {
    // CSS Text 4 §8.2.1 (Blink / takumi ShapeResultSpacing): none between Arabic letters, but
    // the space (and a no-break space) between two Arabic words is spaced
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    const st: font.TextStyle = .{ .families = &.{"Noto Naskh Arabic"}, .size = 36, .rtl = true };
    var spaced = st;
    spaced.letter_spacing = 10;
    for ([_][]const u8{ "\u{645}\u{631}\u{62d}\u{628}\u{627} \u{628}\u{627}\u{644}\u{639}\u{627}\u{644}\u{645}", "\u{645}\u{631}\u{62d}\u{628}\u{627}\u{a0}\u{628}\u{627}" }) |s| {
        var a = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = s, .style = st }}, .{});
        defer a.deinit();
        var b = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = s, .style = spaced }}, .{});
        defer b.deinit();
        try t.expectEqual(a.glyphs.len, b.glyphs.len);
        var spaces: usize = 0;
        for (a.glyphs, b.glyphs) |x, y| {
            const sep = s[x.cluster] == ' ' or std.mem.startsWith(u8, s[x.cluster..], "\u{a0}");
            if (sep) spaces += 1;
            try t.expectApproxEqAbs(x.x_advance + @as(f32, if (sep) 10 else 0), y.x_advance, 0.01);
        }
        try t.expectEqual(@as(usize, 1), spaces);
    }
}

test "features: user settings, letter-spacing, language" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    const st: font.TextStyle = .{ .families = &.{"Roboto"}, .size = 100 };
    var a = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "fi AV", .style = st }}, .{});
    defer a.deinit();
    try t.expectEqual(@as(usize, 4), a.glyphs.len); // fi ligature
    try t.expect(a.glyphs[2].kern != 0); // AV kerned
    var b = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "fi AV", .style = st }}, .{ .features = &.{ .{ .tag = "liga".*, .value = 0 }, .{ .tag = "kern".*, .value = 0 } } });
    defer b.deinit();
    try t.expectEqual(@as(usize, 5), b.glyphs.len);
    try t.expectEqual(@as(f32, 0), b.glyphs[3].kern);
    try t.expect(b.maxContentWidth() > a.maxContentWidth());
    // per-run features
    var st2 = st;
    st2.features = &.{.{ .tag = "liga".*, .value = 0 }};
    var c = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "fi AV", .style = st2 }}, .{});
    defer c.deinit();
    try t.expectEqual(@as(usize, 5), c.glyphs.len);
    // letter-spacing switches ligatures off and is added once per cluster
    var st3 = st;
    st3.letter_spacing = 10;
    var d = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "fi", .style = st3 }}, .{});
    defer d.deinit();
    try t.expectEqual(@as(usize, 2), d.glyphs.len);
    try t.expectEqual(@as(u32, ot.tag("VIT ")), shp.languageTag("vi"));
    try t.expectEqual(@as(u32, ot.tag("ZHT ")), shp.languageTag("zh-Hant-TW"));
    try t.expectEqual(@as(u32, ot.tag("ZHS ")), shp.languageTag("zh"));
    try t.expectEqual(@as(u32, 0), shp.languageTag(""));
    // a long-lived cache gives identical results
    var cache = font.ShapeCache.init(t.allocator);
    defer cache.deinit();
    for (0..3) |_| {
        var e = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "fi AV", .style = st }}, .{ .shape_cache = &cache });
        defer e.deinit();
        try t.expectEqual(a.maxContentWidth(), e.maxContentWidth());
    }
    try t.expectEqual(@as(usize, 1), cache.plans.items.len);
}

test "text-wrap: balance and pretty" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    const s = "The quick brown fox jumps over the lazy dog and keeps running far";
    const runs = [_]font.Run{.{ .text = s, .style = .{ .families = &.{"Inter"}, .size = 20 } }};
    var w = try font.Paragraph.init(t.allocator, &fc, &runs, .{});
    defer w.deinit();
    var b = try font.Paragraph.init(t.allocator, &fc, &runs, .{ .text_wrap = .balance });
    defer b.deinit();
    var pr = try font.Paragraph.init(t.allocator, &fc, &runs, .{ .text_wrap = .pretty });
    defer pr.deinit();
    for ([_]f32{ 260, 330, 420, 520 }) |width| {
        const gw = w.measure(width);
        const gb = b.measure(width);
        const gp = pr.measure(width);
        try t.expectEqual(gw.line_count, gb.line_count);
        try t.expectEqual(gw.line_count, gp.line_count);
        try t.expect(gb.width <= gw.width);
        var lw = try w.layout(t.allocator, width);
        defer lw.deinit(t.allocator);
        var lb = try b.layout(t.allocator, width);
        defer lb.deinit(t.allocator);
        if (gw.line_count > 1) {
            // balancing never makes the last line shorter
            try t.expect(lb.lines[lb.lines.len - 1].width >= lw.lines[lw.lines.len - 1].width - 0.01);
            for (lb.lines) |ln| try t.expect(text.ceil64(ln.width) <= width + 1.0 / 64.0);
        }
    }
}

test "rtl: justify, ellipsis, clamp, soft hyphen stay sane" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    const s = "اللغة العربية هي أكثر اللغات السامية تحدثاً وإحدى أكثر اللغات انتشاراً في العالم";
    const runs = [_]font.Run{.{ .text = s, .style = .{ .families = &.{"Noto Naskh Arabic"}, .size = 20 } }};
    var j = try font.Paragraph.init(t.allocator, &fc, &runs, .{ .direction = .rtl, .text_align = .justify });
    defer j.deinit();
    var lay = try j.layout(t.allocator, 200);
    defer lay.deinit(t.allocator);
    try t.expect(lay.lines.len > 2);
    for (lay.lines[0 .. lay.lines.len - 1]) |ln| try t.expectApproxEqAbs(@as(f32, 200), ln.width, 0.05);
    // last line: start (= right) aligned
    const last = lay.lines[lay.lines.len - 1];
    try t.expectApproxEqAbs(@as(f32, 200), last.x + text.ceil64(last.width), 0.02);
    for (lay.glyphs) |g| try t.expect(g.x > -1 and g.x < 201);

    var c = try font.Paragraph.init(t.allocator, &fc, &runs, .{ .direction = .rtl, .text_align = .start, .max_lines = 2 });
    defer c.deinit();
    var lc = try c.layout(t.allocator, 200);
    defer lc.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), lc.lines.len);
    // the ellipsis is the leftmost glyph of the clamped line
    const l2 = lc.lines[1];
    try t.expectEqual(c.ell.gid, lc.glyphs[l2.glyph_start].gid);
    try t.expectApproxEqAbs(l2.x, lc.glyphs[l2.glyph_start].x, 0.01);
}

test "fuzz: random unicode never crashes, glyphs stay finite" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    const pools = [_][2]u21{ .{ 0x20, 0x7e }, .{ 0xa0, 0x24f }, .{ 0x300, 0x36f }, .{ 0x590, 0x5ff }, .{ 0x600, 0x6ff }, .{ 0x900, 0x97f }, .{ 0x980, 0x9ff }, .{ 0xe00, 0xe7f }, .{ 0x2000, 0x206f }, .{ 0x1f1e6, 0x1f1ff }, .{ 0x1f400, 0x1f4ff }, .{ 0xfe00, 0xfe0f }, .{ 0, 0x10ffff } };
    var buf: [400]u8 = undefined;
    var iter: u32 = 0;
    while (iter < 600) : (iter += 1) {
        var n: usize = 0;
        const want = r.uintLessThan(usize, 60) + 1;
        var k: usize = 0;
        while (k < want and n + 4 <= buf.len) : (k += 1) {
            const pool = pools[r.uintLessThan(usize, pools.len)];
            var cp: u21 = pool[0] + r.uintLessThan(u21, pool[1] - pool[0] + 1);
            if (cp >= 0xd800 and cp < 0xe000) cp = 0x200d;
            if (r.uintLessThan(u8, 12) == 0) cp = ([_]u21{ 0x200d, 0x200c, 0x94d, 0x9cd, 0x202e, 0x2067, 0x2069, 0x202c, '\n', '\t', 0xad, ' ' })[r.uintLessThan(usize, 12)];
            var tmp: [4]u8 = undefined;
            const l = font.ttf.encodeUtf8(cp, &tmp);
            @memcpy(buf[n..][0..l], tmp[0..l]);
            n += l;
        }
        const opts: font.ParagraphOptions = .{
            .direction = if (r.boolean()) .rtl else .ltr,
            .white_space = r.enumValue(font.WhiteSpace),
            .word_break = r.enumValue(font.WordBreak),
            .overflow_wrap = r.enumValue(font.OverflowWrap),
            .text_align = r.enumValue(font.TextAlign),
            .text_wrap = r.enumValue(font.TextWrap),
            .max_lines = if (r.uintLessThan(u8, 4) == 0) 2 else null,
            .ellipsis = r.boolean(),
        };
        const split = r.uintLessThan(usize, n + 1);
        const runs = [_]font.Run{
            .{ .text = buf[0..split], .style = .{ .size = 10 + @as(f32, @floatFromInt(r.uintLessThan(u8, 40))), .letter_spacing = if (r.boolean()) 1 else 0 } },
            .{ .text = buf[split..n], .style = .{ .families = &.{"Noto Sans Devanagari"}, .size = 22 } },
        };
        inline for (.{ true, false }) |complex| {
            var p = try font.Paragraph.initEx(complex, t.allocator, &fc, &runs, opts);
            defer p.deinit();
            for ([_]?f32{ null, 0, 37.5, 200 }) |w| {
                const m = p.measure(w);
                try t.expect(std.math.isFinite(m.width) and std.math.isFinite(m.height));
                var lay = try p.layout(t.allocator, w);
                defer lay.deinit(t.allocator);
                try t.expectEqual(m.line_count, @as(u32, @intCast(lay.lines.len)));
                for (lay.glyphs) |g| try t.expect(std.math.isFinite(g.x) and std.math.isFinite(g.y));
                for (lay.lines) |ln| try t.expect(ln.glyph_end >= ln.glyph_start and ln.glyph_end <= lay.glyphs.len);
            }
        }
    }
}

test "fuzz: corrupted GSUB / GPOS / GDEF never crash" {
    const a = t.allocator;
    const samples = [_]struct { data: []const u8, s: []const u8, rtl: bool }{
        .{ .data = inter, .s = "office AVATAR fi q\u{301} Việt e\u{302}\u{301}", .rtl = false },
        .{ .data = naskh, .s = "بِسْمِ ٱللَّٰهِ لا إله 123", .rtl = true },
        .{ .data = deva, .s = "क्षत्रिय श्री कर्म किर्ति स्त्री", .rtl = false },
        .{ .data = beng, .s = "বাংলা ক্ষত্রিয় কো র্কি", .rtl = false },
        .{ .data = thai, .s = "น้ำ ปั้น ผู้", .rtl = false },
        .{ .data = hebrew, .s = "בְּרֵאשִׁית (בָּרָא)", .rtl = true },
    };
    var prng = std.Random.DefaultPrng.init(0xbad5eed);
    const r = prng.random();
    for (samples) |smp| {
        const copy = try a.dupe(u8, smp.data);
        defer a.free(copy);
        const f0 = try font.Font.init(smp.data, 0);
        const gdef = ot.findTable(&f0, ot.tag("GDEF"));
        const tables = [_][]const u8{ f0.gsub, f0.gpos, gdef };
        var iter: u32 = 0;
        while (iter < 220) : (iter += 1) {
            @memcpy(copy, smp.data);
            // corrupt a few bytes (or a 16-bit field) of one of the layout tables
            const tb = tables[r.uintLessThan(usize, 3)];
            if (tb.len == 0) continue;
            const base = @intFromPtr(tb.ptr) - @intFromPtr(smp.data.ptr);
            const hits = r.uintLessThan(usize, 12) + 1;
            for (0..hits) |_| {
                // bias towards the header / lists at the start of the table
                const span = if (r.boolean()) @min(tb.len, 2048) else tb.len;
                const off = base + r.uintLessThan(usize, span);
                copy[off] = switch (r.uintLessThan(u8, 4)) {
                    0 => 0,
                    1 => 0xff,
                    2 => copy[off] +% 1,
                    else => r.int(u8),
                };
            }
            var fc: font.FontCollection = .{};
            defer fc.deinit(a);
            _ = fc.register(a, copy, .{}) catch continue;
            var p = try font.Paragraph.init(a, &fc, &.{.{ .text = smp.s, .style = .{ .size = 24 } }}, .{ .direction = if (smp.rtl) .rtl else .ltr });
            defer p.deinit();
            var lay = try p.layout(a, 120);
            defer lay.deinit(a);
            for (lay.glyphs) |g| try t.expect(std.math.isFinite(g.x) and std.math.isFinite(g.y));
        }
    }
}

test "colour-emoji preference path compiles and keeps clusters whole" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    const runs = [_]font.Run{.{ .text = "a 👨‍👩‍👧 1️⃣ 🇯🇵 ❤️ b", .style = .{ .families = &.{"Inter"}, .size = 20 } }};
    var a = try font.Paragraph.initWith(.{ .complex = true, .color_emoji = true }, t.allocator, &fc, &runs, .{});
    defer a.deinit();
    var b = try font.Paragraph.initWith(.{ .complex = false, .color_emoji = true }, t.allocator, &fc, &runs, .{});
    defer b.deinit();
    var c = try font.Paragraph.init(t.allocator, &fc, &runs, .{});
    defer c.deinit();
    // no colour face registered: same result as without the preference
    try t.expectEqual(c.glyphs.len, a.glyphs.len);
    try t.expectEqual(c.maxContentWidth(), a.maxContentWidth());
    try t.expect(b.glyphs.len != 0);
}

test "forced breaks: U+2028 and Run.hard_break_after in every white-space mode" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    const st: font.TextStyle = .{ .families = &.{"Inter"}, .size = 16 };
    for ([_]font.WhiteSpace{ .normal, .nowrap, .pre, .pre_wrap, .pre_line }) |ws| {
        var a = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "one \u{2028} two", .style = st }}, .{ .white_space = ws });
        defer a.deinit();
        try t.expectEqual(@as(u32, 2), a.measure(null).line_count);
        var b = try font.Paragraph.init(t.allocator, &fc, &.{ .{ .text = "one ", .style = st, .hard_break_after = true }, .{ .text = " two", .style = st } }, .{ .white_space = ws });
        defer b.deinit();
        try t.expectEqual(@as(u32, 2), b.measure(null).line_count);
        // an empty <br> run between two text runs
        var c = try font.Paragraph.init(t.allocator, &fc, &.{ .{ .text = "one", .style = st }, .{ .text = "", .style = st, .hard_break_after = true }, .{ .text = "two", .style = st } }, .{ .white_space = ws });
        defer c.deinit();
        try t.expectEqual(@as(u32, 2), c.measure(null).line_count);
        if (ws == .normal) {
            // collapsible spaces around the break vanish
            var plain = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "one", .style = st }}, .{});
            defer plain.deinit();
            var lay = try b.layout(t.allocator, null);
            defer lay.deinit(t.allocator);
            try t.expectEqual(plain.maxContentWidth(), text.ceil64(lay.lines[0].width));
        }
    }
}

// ---- inline formatting: inline boxes, objects, bands (values from the takumi oracle, Inter 16 px)

const inl_st: font.TextStyle = .{ .families = &.{"Inter"}, .size = 16 };

test "inline boxes: edges take inline space on the first / last fragment" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    // <span style="padding:0 8px; border:1px solid; margin:0 4px"> around the middle run
    const boxes = [_]font.InlineBox{.{ .style = inl_st, .start = 13, .end = 13, .margin_start = 4, .margin_end = 4 }};
    var p = try font.Paragraph.init(t.allocator, &fc, &.{
        .{ .text = "The quick ", .style = inl_st },
        .{ .text = "brown fox jumps over the lazy", .style = inl_st, .box = 0 },
        .{ .text = " dog and keeps running", .style = inl_st },
    }, .{ .boxes = &boxes });
    defer p.deinit();
    try t.expect(p.complex);
    try t.expectEqual(@as(u32, 2), p.measure(300).line_count);
    var tl = try p.layout(t.allocator, 300);
    defer tl.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), tl.segments.len);
    try t.expectApproxEqAbs(@as(f32, 79.17 + 13.0), tl.segments[1].x0, 0.02);
    try t.expectApproxEqAbs(@as(f32, 0), tl.segments[2].x0, 0.02);
    try t.expectApproxEqAbs(@as(f32, 30.69 + 13.0), tl.segments[3].x0, 0.02);
    // two fragments: the first has the start edge (border box starts after the margin), the second the end edge
    try t.expectEqual(@as(usize, 2), tl.boxes.len);
    try t.expect(tl.boxes[0].first and !tl.boxes[0].last and !tl.boxes[1].first and tl.boxes[1].last);
    try t.expectApproxEqAbs(@as(f32, 79.17 + 4.0), tl.boxes[0].x0, 0.02);
    try t.expectApproxEqAbs(@as(f32, 30.69 + 9.0), tl.boxes[1].x1, 0.02);
    // intrinsic sizes count the edges
    var plain = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "The quick brown fox jumps over the lazy dog and keeps running", .style = inl_st }}, .{});
    defer plain.deinit();
    try t.expectApproxEqAbs(plain.maxContentWidth() + 26, p.maxContentWidth(), 0.05);
    // box-decoration-break: clone: every fragment has both edges, lines reserve room for them
    const cl = [_]font.InlineBox{.{ .style = inl_st, .start = 8, .end = 8, .clone = true }};
    var c = try font.Paragraph.init(t.allocator, &fc, &.{ .{ .text = "The ", .style = inl_st }, .{ .text = "quick brown fox jumps over", .style = inl_st, .box = 0 }, .{ .text = " dog", .style = inl_st } }, .{ .boxes = &cl });
    defer c.deinit();
    var ctl = try c.layout(t.allocator, 120);
    defer ctl.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), ctl.lines.len);
    try t.expectApproxEqAbs(@as(f32, 8), ctl.segments[2].x0, 0.02);
    for (ctl.boxes) |b| try t.expect(b.first and b.last);
}

test "inline boxes: nowrap runs, forced breaks, struts and vertical-align" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    // a nowrap span moves to the next line as a whole
    var nw = try font.Paragraph.init(t.allocator, &fc, &.{
        .{ .text = "The quick brown ", .style = inl_st },
        .{ .text = "fox jumps over the", .style = inl_st, .white_space = .nowrap },
        .{ .text = " lazy dog", .style = inl_st },
    }, .{});
    defer nw.deinit();
    var ntl = try nw.layout(t.allocator, 200);
    defer ntl.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), ntl.lines.len);
    try t.expectApproxEqAbs(@as(f32, 126.58), ntl.lines[0].width, 0.02);
    try t.expectApproxEqAbs(@as(f32, 175.05), ntl.lines[1].width, 0.05);
    // sub / super / lengths shift baselines and grow the line: "E = mc<sup>2</sup> ... <span +10px> <span -6px>"
    const small: font.TextStyle = .{ .families = &.{"Inter"}, .size = 13.333333 };
    const boxes = [_]font.InlineBox{
        .{ .style = small, .valign = .super },
        .{ .style = small, .valign = .sub },
        .{ .style = inl_st, .valign = .{ .length = 10 } },
        .{ .style = inl_st, .valign = .{ .length = -6 } },
    };
    var va = try font.Paragraph.init(t.allocator, &fc, &.{
        .{ .text = "E = mc", .style = inl_st },
        .{ .text = "2", .style = small, .box = 0 },
        .{ .text = " H", .style = inl_st },
        .{ .text = "2", .style = small, .box = 1 },
        .{ .text = "O ", .style = inl_st },
        .{ .text = "up", .style = inl_st, .box = 2 },
        .{ .text = " ", .style = inl_st },
        .{ .text = "down", .style = inl_st, .box = 3 },
    }, .{ .boxes = &boxes });
    defer va.deinit();
    const sz = va.measure(300);
    try t.expectEqual(@as(f32, 36), sz.height);
    try t.expectEqual(@as(f32, 26), sz.first_baseline);
    var vtl = try va.layout(t.allocator, 300);
    defer vtl.deinit(t.allocator);
    try t.expectApproxEqAbs(@as(f32, 26.0 - 6.328125), vtl.segments[1].baseline, 0.001);
    try t.expectApproxEqAbs(@as(f32, 26.0 + 4.1875), vtl.segments[3].baseline, 0.001);
    try t.expectApproxEqAbs(@as(f32, 16), vtl.segments[5].baseline, 0.001);
    try t.expectApproxEqAbs(@as(f32, 32), vtl.segments[7].baseline, 0.001);
    // a span with its own line-height / font size makes a strut (line-height: 1.5 block, 32 px span -> 48)
    const big: font.TextStyle = .{ .families = &.{"Inter"}, .size = 32 };
    const bb = [_]font.InlineBox{.{ .style = big }};
    var lh = try font.Paragraph.init(t.allocator, &fc, &.{ .{ .text = "aaa ", .style = inl_st }, .{ .text = "big", .style = big, .box = 0 }, .{ .text = " bbb", .style = inl_st } }, .{ .boxes = &bb, .line_height = .{ .multiple = 1.5 } });
    defer lh.deinit();
    try t.expectEqual(@as(f32, 48), lh.measure(300).height);
    // closing edges after a forced break stay on its line; an empty span without edges makes no line
    const eb = [_]font.InlineBox{ .{ .style = inl_st, .start = 3, .end = 3 }, .{ .style = inl_st } };
    var br = try font.Paragraph.init(t.allocator, &fc, &.{ .{ .text = "a", .style = inl_st, .box = 0, .hard_break_after = true }, .{ .text = "", .style = inl_st, .box = 1 } }, .{ .boxes = &eb });
    defer br.deinit();
    const bs = br.measure(300);
    try t.expectEqual(@as(u32, 1), bs.line_count);
    try t.expectEqual(@as(f32, 20), bs.height);
}

const FlowTest = struct {
    /// a left float of 80 x 50 at the top
    fn band(_: *const font.Flow, y: f32, h: f32) font.Band {
        _ = h;
        return if (y < 50) .{ .x0 = 80, .x1 = 300, .next_y = 50 } else .{ .x0 = 0, .x1 = 300 };
    }
    var calls: [8]struct { id: u32, y: f32, how: font.FloatPlace } = undefined;
    var n_calls: usize = 0;
    fn float(_: *const font.Flow, id: u32, y: f32, used: f32, avail: f32, how: font.FloatPlace) bool {
        if (n_calls < calls.len) calls[n_calls] = .{ .id = id, .y = y, .how = how };
        n_calls += 1;
        // a 200 px float: beside the line only when it fits
        return how != .beside or used + 200 <= avail;
    }
};

test "flow: atomic objects, bands and floats" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    const obj: [4]font.ObjectMetrics = @splat(.{ .width = 40, .ascent = 10, .descent = 0 });
    // aaaa[]bbbb cccc[][][] at 120 px: an object breaks before and after
    var p = try font.Paragraph.init(t.allocator, &fc, &.{
        .{ .text = "aaaa", .style = inl_st },
        .{ .text = "", .object = .{ .id = 0 } },
        .{ .text = "bbbb cccc", .style = inl_st },
        .{ .text = "", .object = .{ .id = 1 } },
        .{ .text = "", .object = .{ .id = 2 } },
        .{ .text = "", .object = .{ .id = 3 } },
    }, .{ .strut = inl_st });
    defer p.deinit();
    const flow: font.Flow = .{ .alloc = t.allocator, .objects = &obj };
    var tl = try p.layoutFlow(t.allocator, &flow, 120);
    defer tl.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), tl.lines.len);
    try t.expectEqual(@as(usize, 4), tl.objects.len);
    const want = [_][2]f32{ .{ 35.94, 6 }, .{ 36.56, 26 }, .{ 76.56, 26 }, .{ 0, 46 } };
    for (tl.objects, want) |o, w| {
        try t.expectApproxEqAbs(w[0], o.x, 0.02);
        try t.expectApproxEqAbs(w[1], o.y, 0.02);
    }
    try t.expectEqual(@as(f32, 60), p.measureFlow(&flow, 120).height);
    try t.expectApproxEqAbs(@as(f32, 40), p.minContentWidthFlow(&flow), 0.02);

    // vertical-align of 20 x 30 boxes: baseline, top, bottom, middle, text-top, text-bottom -> line height 44
    const o2: [6]font.ObjectMetrics = @splat(.{ .width = 20, .ascent = 30, .descent = 0 });
    var v = try font.Paragraph.init(t.allocator, &fc, &.{
        .{ .text = "x ", .style = inl_st },
        .{ .text = "", .object = .{ .id = 0 } },
        .{ .text = "", .object = .{ .id = 1, .valign = .top } },
        .{ .text = "", .object = .{ .id = 2, .valign = .bottom } },
        .{ .text = "", .object = .{ .id = 3, .valign = .middle } },
        .{ .text = "", .object = .{ .id = 4, .valign = .text_top } },
        .{ .text = "", .object = .{ .id = 5, .valign = .text_bottom } },
    }, .{ .strut = inl_st });
    defer v.deinit();
    const f2: font.Flow = .{ .alloc = t.allocator, .objects = &o2 };
    var vtl = try v.layoutFlow(t.allocator, &f2, 300);
    defer vtl.deinit(t.allocator);
    try t.expectEqual(@as(f32, 44), vtl.height);
    const ys = [_]f32{ 0, 0, 14, 10.640625, 14, 3.859375 };
    for (vtl.objects, ys) |o, y| try t.expectApproxEqAbs(y, o.y, 0.02);

    // lines beside a float are shortened and offset, the line below it has the full width again
    const words = "The quick brown fox jumps over the lazy dog and keeps running through the forest until night falls";
    var w = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = words, .style = inl_st }}, .{});
    defer w.deinit();
    const f3: font.Flow = .{ .alloc = t.allocator, .band_fn = FlowTest.band };
    var wtl = try w.layoutFlow(t.allocator, &f3, 300);
    defer wtl.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), wtl.lines.len);
    try t.expectEqual(@as(f32, 80), wtl.lines[0].x);
    try t.expectEqual(@as(f32, 80), wtl.lines[2].x);
    try t.expectEqual(@as(f32, 0), wtl.lines[3].x);
    try t.expectApproxEqAbs(@as(f32, 204.59), wtl.lines[0].width, 0.02);
    try t.expectEqual(@as(f32, 80), w.measureFlow(&f3, 300).height);
    // without a band function the flow layout equals the plain one
    var plain = try w.layout(t.allocator, 300);
    defer plain.deinit(t.allocator);
    var same = try w.layoutFlow(t.allocator, &.{ .alloc = t.allocator }, 300);
    defer same.deinit(t.allocator);
    try t.expectEqual(plain.lines.len, same.lines.len);
    try t.expectEqual(plain.height, same.height);
    for (plain.glyphs, same.glyphs) |a, b| try t.expect(a.x == b.x and a.y == b.y and a.gid == b.gid);
    // a word that does not fit beside the float moves below it
    var lw = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "Supercalifragilisticexpialidocious word", .style = inl_st }}, .{});
    defer lw.deinit();
    var ltl = try lw.layoutFlow(t.allocator, &f3, 300);
    defer ltl.deinit(t.allocator);
    try t.expectEqual(@as(f32, 50), ltl.lines[0].top);
    try t.expectEqual(@as(f32, 0), ltl.lines[0].x);

    // a float inside the text: asked beside its line (does not fit), then placed below the finished line
    var fl = try font.Paragraph.init(t.allocator, &fc, &.{
        .{ .text = "The quick brown fox ", .style = inl_st },
        .{ .text = "", .object = .{ .id = 0, .kind = .float } },
        .{ .text = "jumps over the lazy dog", .style = inl_st },
    }, .{});
    defer fl.deinit();
    FlowTest.n_calls = 0;
    const f4: font.Flow = .{ .alloc = t.allocator, .float_fn = FlowTest.float };
    const fs = fl.measureFlow(&f4, 300);
    try t.expectEqual(@as(u32, 2), fs.line_count);
    try t.expectEqual(@as(usize, 2), FlowTest.n_calls);
    try t.expect(FlowTest.calls[0].how == .beside and FlowTest.calls[0].y == 0);
    try t.expect(FlowTest.calls[1].how == .below and FlowTest.calls[1].y == 20);
    // a float before any content is placed first
    var lead = try font.Paragraph.init(t.allocator, &fc, &.{ .{ .text = "", .object = .{ .id = 0, .kind = .float } }, .{ .text = "text", .style = inl_st } }, .{});
    defer lead.deinit();
    FlowTest.n_calls = 0;
    _ = lead.measureFlow(&f4, 300);
    try t.expect(FlowTest.n_calls == 1 and FlowTest.calls[0].how == .leading);
    // out-of-flow boxes report their static position; a paragraph of only such boxes has no line
    var oof = try font.Paragraph.init(t.allocator, &fc, &.{ .{ .text = "hello ", .style = inl_st }, .{ .text = "", .object = .{ .id = 0, .kind = .out_of_flow } }, .{ .text = "world", .style = inl_st } }, .{});
    defer oof.deinit();
    var otl = try oof.layoutFlow(t.allocator, &.{ .alloc = t.allocator }, 300);
    defer otl.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), otl.objects.len);
    try t.expectApproxEqAbs(@as(f32, 40.64), otl.objects[0].x, 0.02);
    var only = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = "", .object = .{ .id = 0, .kind = .out_of_flow } }}, .{ .strut = inl_st });
    defer only.deinit();
    try t.expectEqual(@as(f32, 0), only.measure(300).height);
}

test "flow: random runs, boxes and objects never crash and stay finite" {
    var fc = try collection(t.allocator);
    defer fc.deinit(t.allocator);
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    const texts = [_][]const u8{ "", " ", "word", "two words ", " lead", "a\u{ad}b", "x\ty", "\u{5e9}\u{5dc}\u{5d5}\u{5dd} \u{5e2}\u{5d5}\u{5dc}\u{5dd} ", "long-unbreakable-token" };
    var round: usize = 0;
    while (round < 300) : (round += 1) {
        var boxes: [6]font.InlineBox = undefined;
        const nb = r.uintLessThan(usize, boxes.len + 1);
        for (boxes[0..nb], 0..) |*b, k| b.* = .{
            .parent = if (k > 0 and r.boolean()) r.uintLessThan(u32, @intCast(k)) else if (r.uintLessThan(u8, 8) == 0) 99 else font.no_box,
            .style = .{ .families = &.{"Inter"}, .size = @floatFromInt(r.intRangeAtMost(u8, 0, 40)) },
            .valign = switch (r.uintLessThan(u8, 9)) {
                0 => .sub,
                1 => .super,
                2 => .top,
                3 => .bottom,
                4 => .middle,
                5 => .text_top,
                6 => .text_bottom,
                7 => .{ .length = (r.float(f32) - 0.5) * 60 },
                else => .baseline,
            },
            .start = if (r.boolean()) (r.float(f32) - 0.2) * 20 else 0,
            .end = if (r.boolean()) (r.float(f32) - 0.2) * 20 else if (r.uintLessThan(u8, 20) == 0) std.math.nan(f32) else 0,
            .clone = r.uintLessThan(u8, 4) == 0,
            .line_height = switch (r.uintLessThan(u8, 4)) {
                0 => .{ .px = r.float(f32) * 50 },
                1 => .{ .multiple = r.float(f32) * 3 },
                else => null,
            },
        };
        var runs: [12]font.Run = undefined;
        const nr = r.uintLessThan(usize, runs.len + 1);
        var n_obj: u32 = 0;
        for (runs[0..nr]) |*run| {
            run.* = .{ .text = texts[r.uintLessThan(usize, texts.len)], .style = .{ .families = &.{"Inter"}, .size = @floatFromInt(r.intRangeAtMost(u8, 1, 30)) } };
            run.box = if (r.boolean()) r.uintLessThan(u32, 8) else font.no_box;
            if (r.uintLessThan(u8, 5) == 0) run.white_space = r.enumValue(font.WhiteSpace);
            run.hard_break_after = r.uintLessThan(u8, 8) == 0;
            if (r.uintLessThan(u8, 4) == 0) {
                run.object = .{ .id = if (r.uintLessThan(u8, 10) == 0) 1000 else n_obj, .kind = r.enumValue(font.Object.Kind), .block_level = r.boolean(), .valign = if (r.boolean()) .middle else .top };
                n_obj += 1;
            }
        }
        var objs: [12]font.ObjectMetrics = undefined;
        for (&objs) |*o| o.* = .{ .width = (r.float(f32) - 0.1) * 80, .ascent = r.float(f32) * 40, .descent = if (r.uintLessThan(u8, 10) == 0) std.math.inf(f32) else r.float(f32) * 10 };
        var p = try font.Paragraph.init(t.allocator, &fc, runs[0..nr], .{
            .boxes = boxes[0..nb],
            .white_space = r.enumValue(font.WhiteSpace),
            .text_align = r.enumValue(font.TextAlign),
            .direction = if (r.boolean()) .rtl else .ltr,
            .overflow_wrap = r.enumValue(font.OverflowWrap),
            .max_lines = if (r.uintLessThan(u8, 6) == 0) r.intRangeAtMost(u32, 0, 3) else null,
            .ellipsis = r.boolean(),
            .line_height = if (r.boolean()) .normal else .{ .px = 18 },
        });
        defer p.deinit();
        const flow: font.Flow = .{ .alloc = t.allocator, .objects = objs[0..@min(n_obj, objs.len)], .band_fn = if (r.boolean()) FlowTest.band else null, .float_fn = if (r.boolean()) FlowTest.float else null };
        const width: ?f32 = switch (r.uintLessThan(u8, 5)) {
            0 => null,
            1 => 0,
            else => r.float(f32) * 300,
        };
        const sz = p.measureFlow(&flow, width);
        try t.expect(std.math.isFinite(sz.width) and std.math.isFinite(sz.height));
        _ = p.minContentWidthFlow(&flow);
        _ = p.maxContentWidthFlow(&flow);
        _ = p.measure(width);
        var tl = try p.layoutFlow(t.allocator, &flow, width);
        defer tl.deinit(t.allocator);
        for (tl.glyphs) |g| try t.expect(std.math.isFinite(g.x) and std.math.isFinite(g.y));
        for (tl.objects) |o| try t.expect(std.math.isFinite(o.x) and std.math.isFinite(o.y));
        for (tl.segments) |s| try t.expect(s.g0 <= s.g1 and s.g1 <= tl.glyphs.len and s.line < tl.lines.len);
        for (tl.boxes) |b| try t.expect(b.box < nb and b.line < tl.lines.len);
        var tl2 = try p.layout(t.allocator, width);
        tl2.deinit(t.allocator);
    }
}
