//! Tests for the font module. Expected numbers marked "oracle" were measured with
//! @takumi-rs/wasm 2.20.0 (`renderer.measure`), see bench/probe/font/*.mjs.
const std = @import("std");
const font = @import("font.zig");
const t = std.testing;

const inter = @embedFile("testdata/Inter-Regular.ttf");
const inter_bold = @embedFile("testdata/Inter-Bold.ttf");
const noto = @embedFile("testdata/NotoSans-Regular.ttf");
const roboto = @embedFile("testdata/Roboto-Regular.ttf");
const z60: [60]u8 = @splat(0);
const all_fonts = [_][]const u8{ inter, inter_bold, noto, roboto };

/// Path sink that tracks contours and the exact bounding box (quad extrema included).
const Stats = struct {
    moves: u32 = 0,
    closes: u32 = 0,
    ops: u32 = 0,
    open: bool = false,
    bad: bool = false,
    cx: f32 = 0,
    cy: f32 = 0,
    min_x: f32 = std.math.inf(f32),
    min_y: f32 = std.math.inf(f32),
    max_x: f32 = -std.math.inf(f32),
    max_y: f32 = -std.math.inf(f32),

    fn pt(s: *Stats, x: f32, y: f32) void {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) s.bad = true;
        s.min_x = @min(s.min_x, x);
        s.max_x = @max(s.max_x, x);
        s.min_y = @min(s.min_y, y);
        s.max_y = @max(s.max_y, y);
        s.cx = x;
        s.cy = y;
        s.ops += 1;
    }
    pub fn moveTo(s: *Stats, x: f32, y: f32) void {
        if (s.open) s.bad = true;
        s.open = true;
        s.moves += 1;
        s.pt(x, y);
    }
    pub fn lineTo(s: *Stats, x: f32, y: f32) void {
        if (!s.open) s.bad = true;
        s.pt(x, y);
    }
    fn extremum(p0: f32, c: f32, p2: f32) ?f32 {
        const d = p0 - 2 * c + p2;
        if (d == 0) return null;
        const u = (p0 - c) / d;
        if (u <= 0 or u >= 1) return null;
        return (1 - u) * (1 - u) * p0 + 2 * u * (1 - u) * c + u * u * p2;
    }
    pub fn quadTo(s: *Stats, cx: f32, cy: f32, x: f32, y: f32) void {
        if (!s.open) s.bad = true;
        if (extremum(s.cx, cx, x)) |ex| {
            s.min_x = @min(s.min_x, ex);
            s.max_x = @max(s.max_x, ex);
        }
        if (extremum(s.cy, cy, y)) |ey| {
            s.min_y = @min(s.min_y, ey);
            s.max_y = @max(s.max_y, ey);
        }
        s.pt(x, y);
    }
    pub fn cubicTo(s: *Stats, _: f32, _: f32, _: f32, _: f32, x: f32, y: f32) void {
        s.pt(x, y);
    }
    pub fn close(s: *Stats) void {
        if (!s.open) s.bad = true;
        s.open = false;
        s.closes += 1;
    }
};

test "parse all fonts: names, metrics" {
    const Exp = struct { family: []const u8, sub: []const u8, upem: u16, weight: u16, asc: i32, desc: i32 };
    const exp = [_]Exp{
        .{ .family = "Inter", .sub = "Regular", .upem = 2048, .weight = 400, .asc = 1984, .desc = 494 },
        .{ .family = "Inter", .sub = "Bold", .upem = 2048, .weight = 700, .asc = 1984, .desc = 494 },
        .{ .family = "Noto Sans", .sub = "Regular", .upem = 1000, .weight = 400, .asc = 1069, .desc = 293 },
        .{ .family = "Roboto", .sub = "Regular", .upem = 2048, .weight = 400, .asc = 2146, .desc = 555 },
    };
    for (all_fonts, exp) |d, e| {
        const f = try font.Font.init(d, 0);
        var buf: [64]u8 = undefined;
        try t.expectEqualStrings(e.family, f.familyName(&buf));
        try t.expectEqualStrings(e.sub, f.subfamilyName(&buf));
        try t.expectEqual(e.upem, f.unitsPerEm());
        try t.expectEqual(e.weight, f.weightClass());
        try t.expect(!f.isItalic());
        try t.expect(f.numGlyphs() > 2000);
        const lm = f.lineMetrics();
        try t.expectEqual(e.asc, lm.ascent);
        try t.expectEqual(e.desc, lm.descent);
        try t.expectEqual(@as(i32, 0), lm.leading);
        try t.expect(f.xHeight() > 0 and f.capHeight() > f.xHeight());
        try t.expect(f.underlineThickness() > 0 and f.underlinePosition() < 0);
        try t.expect(f.strikeoutThickness() > 0 and f.strikeoutPosition() > 0);
        try t.expect(f.typoAscender() > 0 and f.typoDescender() < 0 and f.winAscent() > 0 and f.winDescent() > 0);
        // tiny output buffers truncate instead of overflowing
        var tiny: [3]u8 = undefined;
        try t.expect(f.familyName(&tiny).len <= 3);
    }
}

test "cmap, advances, kerning" {
    const fi = try font.Font.init(inter, 0);
    const fnn = try font.Font.init(noto, 0);
    const fr = try font.Font.init(roboto, 0);
    for ([_]font.Font{ fi, fnn, fr }) |f| {
        try t.expect(f.glyphIndex('A') != 0);
        try t.expect(f.glyphIndex(0xe9) != 0); // é
        try t.expect(f.glyphIndex(0x1ec7) != 0); // ệ
        try t.expectEqual(@as(u16, 0), f.glyphIndex(0x4e2d));
        try t.expectEqual(@as(u16, 0), f.glyphIndex(0x10ffff));
        try t.expect(f.glyphIndex(' ') != 0);
    }
    // oracle: "A" at 100px = 68.994140625 (Inter), 63.9 (Noto), 65.234375 (Roboto)
    try t.expectEqual(@as(u16, 1413), fi.advanceWidth(fi.glyphIndex('A')));
    try t.expectEqual(@as(u16, 639), fnn.advanceWidth(fnn.glyphIndex('A')));
    try t.expectEqual(@as(u16, 1336), fr.advanceWidth(fr.glyphIndex('A')));
    try t.expectEqual(@as(u16, 758), fi.advanceWidth(fi.glyphIndex('f'))); // 37.01171875 px @100
    // out-of-range glyph ids are harmless
    _ = fi.advanceWidth(0xffff);
    try t.expectEqual(@as(i16, 0), fi.kerning(0xffff, 0xfffe));
    // oracle: "AV" at 100px: Inter 131.15234375, Noto 119.9, Roboto 124.609375
    try t.expectEqual(@as(i16, -140), fi.kerning(fi.glyphIndex('A'), fi.glyphIndex('V')));
    try t.expectEqual(@as(i16, -40), fnn.kerning(fnn.glyphIndex('A'), fnn.glyphIndex('V')));
    try t.expectEqual(@as(i16, -87), fr.kerning(fr.glyphIndex('A'), fr.glyphIndex('V')));
    try t.expect(fi.kerning(fi.glyphIndex('T'), fi.glyphIndex('o')) < 0);
    try t.expect(fi.kerning(fi.glyphIndex('W'), fi.glyphIndex('A')) < 0);
    try t.expectEqual(@as(i16, 0), fi.kerning(fi.glyphIndex('H'), fi.glyphIndex('H')));
}

test "outlines: O, composites, emitGlyph" {
    for (all_fonts) |d| {
        const f = try font.Font.init(d, 0);
        {
            var s: Stats = .{};
            const gid = f.glyphIndex('O');
            try t.expect(f.outline(gid, &s));
            try t.expect(!s.bad and !s.open);
            try t.expectEqual(@as(u32, 2), s.moves);
            try t.expectEqual(@as(u32, 2), s.closes);
            const b = f.glyphBounds(gid);
            try t.expectApproxEqAbs(@as(f32, @floatFromInt(b.x_min)), s.min_x, 0.51);
            try t.expectApproxEqAbs(@as(f32, @floatFromInt(b.x_max)), s.max_x, 0.51);
            try t.expectApproxEqAbs(@as(f32, @floatFromInt(b.y_min)), s.min_y, 0.51);
            try t.expectApproxEqAbs(@as(f32, @floatFromInt(b.y_max)), s.max_y, 0.51);
        }
        for ([_]u21{ 0xe9, 0x1ec7, 0x1ee3, 'i', 'B', '8', '%' }) |cp| {
            var s: Stats = .{};
            const gid = f.glyphIndex(cp);
            try t.expect(f.outline(gid, &s));
            try t.expect(!s.bad and !s.open and s.moves >= 2 and s.moves == s.closes);
            const b = f.glyphBounds(gid);
            try t.expect(s.min_x >= @as(f32, @floatFromInt(b.x_min)) - 1.01 and s.max_x <= @as(f32, @floatFromInt(b.x_max)) + 1.01);
            try t.expect(s.min_y >= @as(f32, @floatFromInt(b.y_min)) - 1.01 and s.max_y <= @as(f32, @floatFromInt(b.y_max)) + 1.01);
            try t.expect(s.max_x - s.min_x > 10 and s.max_y - s.min_y > 10);
        }
        // space: no outline
        var s: Stats = .{};
        try t.expect(!f.outline(f.glyphIndex(' '), &s));
        try t.expectEqual(@as(u32, 0), s.ops);
        try t.expect(!f.outline(0xffff, &s));
        // every glyph decodes into well-formed contours
        var g: u32 = 0;
        while (g < f.numGlyphs()) : (g += 1) {
            var a: Stats = .{};
            _ = f.outline(@intCast(g), &a);
            try t.expect(!a.bad and !a.open and a.moves == a.closes);
        }
        // device-space emission: y flipped, scaled, translated
        var dev: Stats = .{};
        const gid = f.glyphIndex('O');
        try t.expect(font.emitGlyph(&f, gid, 100, 10, 200, &dev));
        const b = f.glyphBounds(gid);
        const k = 100.0 / @as(f32, @floatFromInt(f.unitsPerEm()));
        try t.expectApproxEqAbs(10 + @as(f32, @floatFromInt(b.x_min)) * k, dev.min_x, 0.05);
        try t.expectApproxEqAbs(200 - @as(f32, @floatFromInt(b.y_max)) * k, dev.min_y, 0.05);
        try t.expectApproxEqAbs(200 - @as(f32, @floatFromInt(b.y_min)) * k, dev.max_y, 0.05);
        var large: Stats = .{};
        try t.expect(f.outlineResolved(gid, 40000, &large));
        try t.expect(!large.bad and large.max_x > large.min_x and large.max_y > large.min_y);
    }
}

test "contour starting off-curve and implied points" {
    // Hand-made glyf: one contour of 4 off-curve points (a "circle" made only of control points).
    var g: [64]u8 = @splat(0);
    const hdr = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 100, 0, 100, 0, 3, 0, 0 }; // nContours=1, bbox, endPt=3, insLen=0
    @memcpy(g[0..hdr.len], &hdr);
    // flags: 4 x (off-curve, x short, y short, positive) = 0x36
    @memset(g[14..18], 0x36);
    const xs = [_]u8{ 0, 100, 0, 0 }; // deltas: (0,0) (100,0) (100,100) (0,100) -> x: 0,+100,+0,-100
    const ys = [_]u8{ 0, 0, 100, 0 };
    @memcpy(g[18..22], &xs);
    @memcpy(g[22..26], &ys);
    g[17] = 0x26; // 4th point: x short NEGATIVE, y same... y short positive with delta 0
    g[21] = 100;
    var s: Stats = .{};
    try t.expect(font.ttf.testSimpleOutline(g[0..26], &s));
    try t.expect(!s.bad and !s.open);
    try t.expectEqual(@as(u32, 1), s.moves);
    try t.expectEqual(@as(u32, 1), s.closes);
    try t.expectEqual(@as(u32, 5), s.ops); // moveTo + 4 quads
    // curve stays inside the control polygon and touches the edge midpoints
    try t.expectApproxEqAbs(@as(f32, 0), s.min_x, 0.01);
    try t.expectApproxEqAbs(@as(f32, 100), s.max_x, 0.01);
    try t.expectApproxEqAbs(@as(f32, 0), s.min_y, 0.01);
    try t.expectApproxEqAbs(@as(f32, 100), s.max_y, 0.01);
}

test "resolved glyf: implied midpoints stay on the integer 26.6 grid" {
    var g: [26]u8 = @splat(0);
    const header = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 100, 0, 100, 0, 3, 0, 0 };
    @memcpy(g[0..header.len], &header);
    @memset(g[14..18], 0x36);
    g[17] = 0x26;
    g[19] = 100;
    g[21] = 100;
    g[24] = 100;
    const Recorder = struct {
        start: [2]f32 = .{ 0, 0 },
        first_end: ?[2]f32 = null,
        pub fn moveTo(r: *@This(), x: f32, y: f32) void {
            r.start = .{ x, y };
        }
        pub fn lineTo(_: *@This(), _: f32, _: f32) void {}
        pub fn quadTo(r: *@This(), _: f32, _: f32, x: f32, y: f32) void {
            if (r.first_end == null) r.first_end = .{ x, y };
        }
        pub fn cubicTo(_: *@This(), _: f32, _: f32, _: f32, _: f32, _: f32, _: f32) void {}
        pub fn close(_: *@This()) void {}
    };
    var r: Recorder = .{};
    // At 13 ppem in a 2048-upem font, 100 font units resolve to 41/64 px.
    // FreeType's implied midpoint is 20/64 px, rather than 20.5/64 px.
    try t.expect(font.ttf.testSimpleOutlineResolved(&g, .{ .mul = 13.0 / 32.0, .div = 13.0 / 32.0 }, &r));
    const scale: f32 = 13.0 / 2048.0;
    try t.expectApproxEqAbs(@as(f32, 20.0 / 64.0), r.start[1] * scale, 0.000001);
    try t.expectApproxEqAbs(@as(f32, 20.0 / 64.0), r.first_end.?[0] * scale, 0.000001);
    // Below the baseline, integer division truncates toward zero as well.
    for (g[14..18]) |*flag| flag.* &= ~@as(u8, 0x20);
    r = .{};
    try t.expect(font.ttf.testSimpleOutlineResolved(&g, .{ .mul = 13.0 / 32.0, .div = 13.0 / 32.0 }, &r));
    try t.expectApproxEqAbs(@as(f32, -20.0 / 64.0), r.start[1] * scale, 0.000001);
}

test "FreeType contour start: an off-curve first point starts at the last on-curve one" {
    // one contour: (10,0) off, (20,10) on, (0,10) on
    var g: [64]u8 = @splat(0);
    const hdr = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 20, 0, 10, 0, 2, 0, 0 };
    @memcpy(g[0..hdr.len], &hdr);
    g[14] = 0x00; // off, x / y int16
    g[15] = 0x01; // on
    g[16] = 0x01;
    const xs = [_]u8{ 0, 10, 0, 10, 0xff, 0xec }; // +10, +10, -20
    const ys = [_]u8{ 0, 0, 0, 10, 0, 0 }; // 0, +10, 0
    @memcpy(g[17..23], &xs);
    @memcpy(g[23..29], &ys);
    const Rec = struct {
        ops: [8][5]f32 = undefined,
        n: usize = 0,
        fn put(r: *@This(), v: [5]f32) void {
            if (r.n < r.ops.len) r.ops[r.n] = v;
            r.n += 1;
        }
        pub fn moveTo(r: *@This(), x: f32, y: f32) void {
            r.put(.{ 0, x, y, 0, 0 });
        }
        pub fn lineTo(r: *@This(), x: f32, y: f32) void {
            r.put(.{ 1, x, y, 0, 0 });
        }
        pub fn quadTo(r: *@This(), cx: f32, cy: f32, x: f32, y: f32) void {
            r.put(.{ 2, cx, cy, x, y });
        }
        pub fn cubicTo(r: *@This(), a: f32, b: f32, c: f32, d: f32, x: f32, y: f32) void {
            _ = .{ a, b, c, d, x, y };
            r.put(.{ 3, 0, 0, 0, 0 });
        }
        pub fn close(r: *@This()) void {
            r.put(.{ 4, 0, 0, 0, 0 });
        }
    };
    var r: Rec = .{};
    try t.expect(font.ttf.testSimpleOutlineFt(g[0..29], &r));
    // move to the last point, quad through the first to the second, line to the start, close
    try t.expectEqual(@as(usize, 3), r.n);
    try t.expectEqual([5]f32{ 0, 0, 10, 0, 0 }, r.ops[0]);
    try t.expectEqual([5]f32{ 2, 10, 0, 20, 10 }, r.ops[1]);
    try t.expectEqual([5]f32{ 4, 0, 0, 0, 0 }, r.ops[2]);
    // the reader of the raster path starts at the first on-curve point instead
    var q: Rec = .{};
    try t.expect(font.ttf.testSimpleOutline(g[0..29], &q));
    try t.expectEqual([5]f32{ 0, 20, 10, 0, 0 }, q.ops[0]);
}

test "unsupported and invalid containers, ttc" {
    try t.expectError(error.MissingTable, font.Font.init("OTTO" ++ z60, 0));
    try t.expectError(error.WoffContainer, font.Font.init("wOFF" ++ z60, 0));
    try t.expectError(error.Woff2Container, font.Font.init("wOF2" ++ z60, 0));
    try t.expectError(error.InvalidFont, font.Font.init("", 0));
    try t.expectError(error.InvalidFont, font.Font.init("hello world, not a font", 0));
    try t.expectError(error.InvalidFont, font.Font.init(inter, 1));
    try t.expectError(error.MissingTable, font.Font.init("\x00\x01\x00\x00\x00\x00" ++ z60, 0));

    // wrap Roboto into a one-face collection
    const pre = 16;
    const buf = try t.allocator.alloc(u8, roboto.len + pre);
    defer t.allocator.free(buf);
    @memcpy(buf[0..12], "ttcf\x00\x01\x00\x00\x00\x00\x00\x01");
    std.mem.writeInt(u32, buf[12..16], pre, .big);
    @memcpy(buf[pre..], roboto);
    const n = std.mem.readInt(u16, buf[pre + 4 ..][0..2], .big);
    for (0..n) |i| {
        const p = buf[pre + 12 + i * 16 + 8 ..][0..4];
        std.mem.writeInt(u32, p, std.mem.readInt(u32, p, .big) + pre, .big);
    }
    const f = try font.Font.init(buf, 0);
    const r = try font.Font.init(roboto, 0);
    try t.expectEqual(r.glyphIndex('A'), f.glyphIndex('A'));
    try t.expectEqual(r.advanceWidth(40), f.advanceWidth(40));
    try t.expectError(error.InvalidFont, font.Font.init(buf, 1));
}

fn exercise(d: []const u8, alloc: std.mem.Allocator) !void {
    const f = font.Font.init(d, 0) catch return;
    var buf: [40]u8 = undefined;
    _ = f.familyName(&buf);
    _ = f.subfamilyName(&buf);
    _ = f.lineMetrics();
    _ = .{ f.xHeight(), f.capHeight(), f.weightClass(), f.isItalic(), f.underlinePosition(), f.strikeoutPosition() };
    const cps = [_]u21{ 'A', 'V', 'f', 'i', 'o', 0xe9, 0x1ec7, 0x3a9, 0x4e2d, 0x1f600, '-', '>' };
    var prev: u16 = 0;
    for (cps) |cp| {
        const g = f.glyphIndex(cp);
        _ = f.advanceWidth(g);
        _ = f.kerning(prev, g);
        _ = f.glyphBounds(g);
        var s: Stats = .{};
        _ = f.outline(g, &s);
        if (s.ops > 2_000_000) return error.RunawayOutline;
        prev = g;
    }
    var g: u32 = 0;
    while (g < 0x10000) : (g += 2731) {
        var s: Stats = .{};
        _ = f.outline(@intCast(g), &s);
        _ = f.kerning(@intCast(g), @intCast(g ^ 0x55));
        if (s.ops > 2_000_000) return error.RunawayOutline;
    }
    // shaping + layout through the mutated font
    var fc: font.FontCollection = .{};
    defer fc.deinit(alloc);
    _ = fc.register(alloc, d, .{}) catch return;
    var p = try font.Paragraph.init(alloc, &fc, &.{.{ .text = "AV To office -> 1:2 Việt fi ffl\u{ad}x", .style = .{ .size = 20 } }}, .{ .max_lines = 2, .ellipsis = true });
    defer p.deinit();
    var lay = try p.layout(alloc, 60);
    defer lay.deinit(alloc);
    for (lay.glyphs) |pg| {
        var s: Stats = .{};
        _ = font.emitGlyph(fc.font(pg.face), pg.gid, pg.size, pg.x, pg.y, &s);
    }
}

test "fuzz: truncated and corrupted fonts never crash" {
    const alloc = t.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed_f00d);
    const rnd = prng.random();
    for (all_fonts) |orig| {
        // truncation at every 97th byte offset
        var cut: usize = 0;
        while (cut < orig.len) : (cut += 97) try exercise(orig[0..cut], alloc);

        const buf = try alloc.dupe(u8, orig);
        defer alloc.free(buf);
        const f = try font.Font.init(orig, 0);
        const tables = [_][]const u8{ f.head, f.hhea, f.hmtx, f.cmap_sub, f.loca, f.glyf, f.name, f.os2, f.post, f.gpos, f.gsub, orig[0..512] };
        var iter: usize = 0;
        while (iter < 1500) : (iter += 1) {
            var saved: [8]struct { off: usize, val: u8 } = undefined;
            const flips = rnd.intRangeAtMost(usize, 1, saved.len);
            for (saved[0..flips]) |*s| {
                const tb = tables[rnd.uintLessThan(usize, tables.len)];
                if (tb.len == 0) {
                    s.* = .{ .off = 0, .val = buf[0] };
                    continue;
                }
                const base = @intFromPtr(tb.ptr) - @intFromPtr(orig.ptr);
                // bias towards table headers, where offsets and counts live
                const span = if (rnd.boolean()) @min(tb.len, 64) else tb.len;
                const off = base + rnd.uintLessThan(usize, span);
                s.* = .{ .off = off, .val = buf[off] };
                buf[off] = if (rnd.boolean()) rnd.int(u8) else buf[off] ^ (@as(u8, 1) << rnd.int(u3));
            }
            try exercise(buf, alloc);
            var k = flips;
            while (k > 0) {
                k -= 1;
                buf[saved[k].off] = saved[k].val;
            }
        }
        try t.expectEqualSlices(u8, orig, buf);
    }
}

// ----------------------------------------------------------------- text

const Fixture = struct {
    fc: font.FontCollection = .{},
    fn init() !Fixture {
        var fx: Fixture = .{};
        errdefer fx.fc.deinit(t.allocator);
        for (all_fonts) |d| _ = try fx.fc.register(t.allocator, d, .{});
        return fx;
    }
    fn deinit(fx: *Fixture) void {
        fx.fc.deinit(t.allocator);
    }
    fn lay(fx: *Fixture, text: []const u8, style: font.TextStyle, opts: font.ParagraphOptions) !font.TextLayout {
        return font.layoutText(t.allocator, &fx.fc, &.{.{ .text = text, .style = style }}, opts);
    }
};

fn lineText(text: []const u8, l: font.TextLayout, i: usize) []const u8 {
    const ln = l.lines[i];
    if (ln.glyph_end == ln.glyph_start) return "";
    const a = l.glyphs[ln.glyph_start].cluster;
    var b: usize = a;
    for (l.glyphs[ln.glyph_start..ln.glyph_end]) |g| b = @max(b, g.cluster);
    b += 1;
    while (b < text.len and text[b] & 0xc0 == 0x80) b += 1;
    return text[a..b];
}

fn expectLines(text: []const u8, l: font.TextLayout, expected: []const []const u8) !void {
    try t.expectEqual(expected.len, l.lines.len);
    for (expected, 0..) |e, i| try t.expectEqualStrings(e, lineText(text, l, i));
}

const inter_fam: []const []const u8 = &.{"Inter"};
const noto_fam: []const []const u8 = &.{"Noto Sans"};
const roboto_fam: []const []const u8 = &.{"Roboto"};

test "collection matching and fallback" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var buf: [8]font.FaceId = undefined;
    // ids: 0 Inter 400, 1 Inter 700, 2 Noto Sans, 3 Roboto
    try t.expectEqualSlices(font.FaceId, &.{ 0, 2, 3 }, fx.fc.match(&.{"inter"}, 400, false, &buf));
    try t.expectEqualSlices(font.FaceId, &.{ 1, 2, 3 }, fx.fc.match(&.{"INTER"}, 600, false, &buf));
    try t.expectEqualSlices(font.FaceId, &.{ 0, 2, 3 }, fx.fc.match(&.{"Inter"}, 500, true, &buf));
    try t.expectEqualSlices(font.FaceId, &.{ 3, 2, 0 }, fx.fc.match(&.{ "Roboto", "Missing", "Noto Sans" }, 400, false, &buf));
    try t.expectEqualSlices(font.FaceId, &.{ 0, 2, 3 }, fx.fc.match(&.{"Nope"}, 400, false, &buf));
    try t.expectEqualSlices(font.FaceId, &.{ 1, 2, 3 }, fx.fc.match(&.{}, 900, false, &buf));
    var one: [1]font.FaceId = undefined;
    try t.expectEqual(@as(usize, 1), fx.fc.match(&.{}, 400, false, &one).len);
    // explicit registration overrides + unregister
    const id = try fx.fc.register(t.allocator, roboto, .{ .family = "Brand", .weight = 300, .italic = true });
    try t.expectEqual(id, fx.fc.match(&.{"brand"}, 400, false, &buf)[0]);
    try t.expectEqual(@as(u16, 300), fx.fc.face(id).weight);
    fx.fc.unregister(t.allocator, id);
    try t.expectEqualSlices(font.FaceId, &.{ 0, 2, 3 }, fx.fc.match(&.{"brand"}, 400, false, &buf));

    // faces registered with the same name, weight and style are one composite face (unicode-range
    // subsets): all of them are candidates, the last registered first (oracle: takumi-pdf 0.20);
    // a face of another weight in the family is not
    const s1 = try fx.fc.register(t.allocator, noto, .{ .family = "Subset", .weight = 400 });
    const s2 = try fx.fc.register(t.allocator, inter, .{ .family = "Subset", .weight = 400 });
    const s3 = try fx.fc.register(t.allocator, roboto, .{ .family = "Subset", .weight = 700 });
    const subset = fx.fc.match(&.{"Subset"}, 400, false, &buf);
    try t.expectEqualSlices(font.FaceId, &.{ s2, s1 }, subset[0..2]);
    try t.expect(std.mem.indexOfScalar(font.FaceId, subset, s3) == null);
    // `a` from the last registered face; U+2C60 (Noto Sans only) from the other face of the family,
    // before the fallback to other families (face 2, the "Noto Sans" family)
    const sg = try font.shape(t.allocator, &fx.fc, "a\u{2c60}", .{ .families = &.{"Subset"}, .size = 100 });
    defer t.allocator.free(sg);
    try t.expectEqual(s2, sg[0].face);
    try t.expectEqual(s1, sg[1].face);

    // per-codepoint fallback: U+2C60 is in Noto Sans but not in Inter; U+4E2D is nowhere
    const gl = try font.shape(t.allocator, &fx.fc, "a\u{2c60}\u{4e2d}", .{ .families = inter_fam, .size = 100 });
    defer t.allocator.free(gl);
    try t.expectEqual(@as(usize, 3), gl.len);
    try t.expectEqual(@as(font.FaceId, 0), gl[0].face);
    try t.expectEqual(@as(font.FaceId, 2), gl[1].face);
    try t.expectApproxEqAbs(@as(f32, 52.4), gl[1].x_advance, 0.001); // oracle
    try t.expectEqual(@as(font.FaceId, 0), gl[2].face);
    try t.expectEqual(@as(u16, 0), gl[2].gid);
    try t.expectEqual(@as(u32, 4), gl[2].cluster);
}

test "shaping: paint-only runs preserve pair kerning and ligatures" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = roboto_fam, .size = 32 };
    var other = st;
    other.user = 7;
    var whole = try font.Paragraph.init(t.allocator, &fx.fc, &.{.{ .text = "over fi V", .style = st }}, .{});
    defer whole.deinit();
    var split = try font.Paragraph.init(t.allocator, &fx.fc, &.{ .{ .text = "over", .style = st }, .{ .text = " f", .style = other }, .{ .text = "i V", .style = st } }, .{});
    defer split.deinit();
    try t.expectEqual(whole.glyphs.len, split.glyphs.len);
    for (whole.glyphs, split.glyphs) |a, b| {
        try t.expectEqual(a.gid, b.gid);
        try t.expectApproxEqAbs(a.x_advance, b.x_advance, 0.0001);
    }
    var painted = false;
    for (split.glyphs) |g| if (split.metrics[g.metric].user == 7) {
        painted = true;
    };
    try t.expect(painted);
}

test "shaping: widths vs oracle" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const Case = struct { fam: []const []const u8, text: []const u8, size: f32, ls: f32 = 0, ws: f32 = 0, w: f32 };
    const cases = [_]Case{
        // oracle run widths (exact advance sums)
        .{ .fam = inter_fam, .text = "Hello AV To WA fi ffl", .size = 16, .w = 151.5078125 },
        .{ .fam = noto_fam, .text = "Hello AV To WA fi ffl", .size = 16, .w = 145.488037109375 },
        .{ .fam = roboto_fam, .text = "Hello AV To WA fi ffl", .size = 16, .w = 141.8984375 },
        .{ .fam = inter_fam, .text = "AV", .size = 100, .w = 131.15234375 },
        .{ .fam = inter_fam, .text = "To", .size = 100, .w = 116.69921875 },
        .{ .fam = inter_fam, .text = "WA", .size = 100, .w = 161.865234375 },
        .{ .fam = noto_fam, .text = "AV", .size = 100, .w = 119.89999389648438 },
        .{ .fam = roboto_fam, .text = "To", .size = 100, .w = 111.865234375 },
        .{ .fam = inter_fam, .text = "ệ", .size = 100, .w = 58.30078125 },
        // GSUB: Roboto fi / ffi ligatures, Inter "->" contextual arrow
        .{ .fam = roboto_fam, .text = "fi", .size = 100, .w = 55.37109375 },
        .{ .fam = roboto_fam, .text = "ffi", .size = 100, .w = 90.087890625 },
        .{ .fam = roboto_fam, .text = "ffl", .size = 100, .w = 91.50390625 },
        .{ .fam = inter_fam, .text = "fi", .size = 100, .w = 61.23046875 },
        .{ .fam = inter_fam, .text = "->", .size = 100, .w = 95.41015625 },
        .{ .fam = noto_fam, .text = "->", .size = 100, .w = 89.39999389648438 },
        // letter-spacing after every glyph, disables ligatures; word-spacing on spaces
        .{ .fam = roboto_fam, .text = "fi", .size = 100, .ls = 2, .w = 62.984375 },
        .{ .fam = inter_fam, .text = "AV", .size = 100, .ls = 2, .w = 135.15234375 },
        .{ .fam = inter_fam, .text = "a b", .size = 100, .ls = 2, .w = 151.5078125 },
        .{ .fam = inter_fam, .text = "a b", .size = 100, .ws = 5, .w = 150.5078125 },
        // zero-width characters, combining mark, nbsp
        .{ .fam = inter_fam, .text = "a\u{200b}b", .size = 100, .w = 117.3828125 },
        .{ .fam = inter_fam, .text = "a\u{ad}b", .size = 100, .w = 117.3828125 },
        .{ .fam = inter_fam, .text = "a\u{200d}b", .size = 100, .w = 117.3828125 },
        .{ .fam = inter_fam, .text = "a\u{a0}b", .size = 100, .w = 145.5078125 },
        .{ .fam = inter_fam, .text = "ệ\u{301}", .size = 100, .w = 58.30078125 },
    };
    for (cases) |c| {
        const gl = try font.shape(t.allocator, &fx.fc, c.text, .{ .families = c.fam, .size = c.size, .letter_spacing = c.ls, .word_spacing = c.ws });
        defer t.allocator.free(gl);
        var w: f32 = 0;
        for (gl) |g| w += g.x_advance;
        t.expectApproxEqAbs(c.w, w, 0.002) catch |e| {
            std.debug.print("case '{s}' size {d}: got {d}\n", .{ c.text, c.size, w });
            return e;
        };
    }
    // invalid UTF-8 -> U+FFFD (one per bad byte), control characters dropped, clusters = byte offsets
    const gl = try font.shape(t.allocator, &fx.fc, "a\xff\x01é\xe1\xbbz", .{ .families = inter_fam });
    defer t.allocator.free(gl);
    try t.expectEqual(@as(usize, 6), gl.len);
    const fi = fx.fc.font(0);
    try t.expect(gl[1].gid != 0 and gl[1].gid == fx.fc.font(gl[1].face).glyphIndex(0xfffd));
    try t.expectEqual(fi.glyphIndex(0xe9), gl[2].gid);
    try t.expectEqual(@as(u32, 3), gl[2].cluster);
    try t.expectEqual(gl[1].gid, gl[3].gid);
    try t.expectEqual(gl[1].gid, gl[4].gid);
    try t.expectEqual(@as(u32, 7), gl[5].cluster);
}

test "vertical metrics vs oracle" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const sizes = [_]f32{ 16, 24, 44, 64 };
    const lhs = [_]font.LineHeight{ .normal, .{ .multiple = 1.2 }, .{ .multiple = 1.5 }, .{ .px = 40 } };
    // oracle node heights [family][size][line-height: normal, 1.2, 1.5, 40px]
    const heights = [3][4][4]f32{
        .{ .{ 20, 19.1875, 24, 40 }, .{ 29, 28.796875, 36, 40 }, .{ 54, 52.796875, 66, 40 }, .{ 77, 76.796875, 96, 40 } },
        .{ .{ 22, 19.1875, 24, 40 }, .{ 33, 28.796875, 36, 40 }, .{ 60, 52.796875, 66, 40 }, .{ 87, 76.796875, 96, 40 } },
        .{ .{ 21, 19.1875, 24, 40 }, .{ 32, 28.796875, 36, 40 }, .{ 58, 52.796875, 66, 40 }, .{ 84, 76.796875, 96, 40 } },
    };
    // oracle run y (= baseline - exact ascent) for Inter
    const inter_y = [4][4]f32{ .{ 0.5, -0.5, 2.5, 10.5 }, .{ -0.25, -1.25, 2.75, 4.75 }, .{ 0.375, -0.625, 6.375, -6.625 }, .{ 0, -1, 9, -19 } };
    const fams = [_][]const []const u8{ inter_fam, noto_fam, roboto_fam };
    for (fams, 0..) |fam, fi| for (sizes, 0..) |size, si| for (lhs, 0..) |lh, li| {
        var l = try fx.lay("Hello AV To WA fi ffl", .{ .families = fam, .size = size }, .{ .line_height = lh });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 1), l.lines.len);
        try t.expectApproxEqAbs(heights[fi][si][li], l.height, 0.0001);
        try t.expectApproxEqAbs(l.height, l.lines[0].height, 0.0001);
        if (fi == 0) try t.expectApproxEqAbs(inter_y[si][li], l.lines[0].baseline - 1984.0 / 2048.0 * size, 0.0001);
    };
    // fallback font metrics join the line box only for line-height: normal (oracle: 136 / 121)
    var a = try fx.lay("a\u{2c60}b", .{ .families = inter_fam, .size = 100 }, .{});
    defer a.deinit(t.allocator);
    try t.expectApproxEqAbs(@as(f32, 136), a.height, 0.0001);
    var b = try fx.lay("ab", .{ .families = inter_fam, .size = 100 }, .{});
    defer b.deinit(t.allocator);
    try t.expectApproxEqAbs(@as(f32, 121), b.height, 0.0001);
}

const para = "The quick brown fox jumps over the lazy dog. Tô yêu Việt Nam — đất nước tươi đẹp; WAVE To AVATAR (kerning) well-known state-of-the-art.";

test "line breaking fixtures (oracle)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = inter_fam, .size = 16 };
    {
        var l = try fx.lay(para, st, .{ .max_width = 200 });
        defer l.deinit(t.allocator);
        try expectLines(para, l, &.{ "The quick brown fox", "jumps over the lazy dog.", "Tô yêu Việt Nam — đất", "nước tươi đẹp; WAVE To", "AVATAR (kerning) well-", "known state-of-the-art." });
        const widths = [_]f32{ 154.5, 185.4296875, 173.1875, 181.4140625, 174.40625, 178 };
        for (widths, l.lines, 0..) |w, ln, i| {
            try t.expectApproxEqAbs(w, ln.width, 0.01);
            try t.expectApproxEqAbs(@as(f32, @floatFromInt(i)) * 20, ln.top, 0.0001);
            try t.expectApproxEqAbs(@as(f32, @floatFromInt(i)) * 20 + 16, ln.baseline, 0.0001);
            try t.expectEqual(@as(f32, 0), ln.x);
        }
        try t.expectApproxEqAbs(@as(f32, 120), l.height, 0.0001);
        try t.expectApproxEqAbs(@as(f32, 185.4375), l.width, 0.0001); // ceil to 1/64
        // glyph origins: on the baseline, monotonic in x within a line
        for (l.lines) |ln| {
            var x: f32 = -1;
            for (l.glyphs[ln.glyph_start..ln.glyph_end]) |g| {
                try t.expectEqual(ln.baseline, g.y);
                try t.expect(g.x > x);
                x = g.x;
                try t.expectEqual(@as(f32, 16), g.size);
            }
        }
    }
    {
        const s = "The quick brown fox";
        var l = try fx.lay(s, st, .{ .max_width = 120 });
        defer l.deinit(t.allocator);
        try expectLines(s, l, &.{ "The quick", "brown fox" });
        try t.expectApproxEqAbs(@as(f32, 74.671875), l.lines[0].width, 0.01);
        try t.expectApproxEqAbs(@as(f32, 75.328125), l.lines[1].width, 0.01);
    }
    {
        // soft hyphen shows a hyphen when broken there; ZWSP breaks silently; NBSP never breaks
        const s = "nbsp\u{a0}joined words and soft\u{ad}hyphen\u{ad}ated zero\u{200b}width\u{200b}space";
        var l = try fx.lay(s, .{ .families = inter_fam, .size = 18 }, .{ .max_width = 150 });
        defer l.deinit(t.allocator);
        try expectLines(s, l, &.{ "nbsp\u{a0}joined", "words and soft", "hyphen\u{ad}ated zero", "width\u{200b}space" });
        try t.expectApproxEqAbs(@as(f32, 126.31640625 + 6.451171875), l.lines[1].width, 0.01);
        const hy = l.glyphs[l.lines[1].glyph_end - 1];
        try t.expectEqual(fx.fc.font(0).glyphIndex(0x2010), hy.gid);
        // kerning o|w is undone at the ZWSP break: oracle 143.1298828125
        try t.expectApproxEqAbs(@as(f32, 143.1298828125), l.lines[2].width, 0.01);
    }
    {
        // overflow-wrap / word-break
        const s = "Supercalifragilisticexpialidocious and pneumonoultramicroscopicsilicovolcanoconiosis https://example.com/a/very/long/path/that-never-ends?x=1";
        var l = try fx.lay(s, st, .{ .max_width = 120 });
        defer l.deinit(t.allocator);
        try expectLines(s, l, &.{ "Supercalifragilisticexpialidocious", "and", "pneumonoultramicroscopicsilicovolcanoconiosis", "https://example.com/a/very/long/path/that-", "never-ends?x=1" });
        var l2 = try fx.lay(s, st, .{ .max_width = 120, .word_break = .break_all });
        defer l2.deinit(t.allocator);
        try expectLines(s, l2, &.{ "Supercalifragili", "sticexpialidocio", "us and pneumo", "noultramicrosc", "opicsilicovolca", "noconiosis http", "s://example.co", "m/a/very/long/", "path/that-neve", "r-ends?x=1" });
        var l3 = try fx.lay(s, st, .{ .max_width = 120, .overflow_wrap = .anywhere });
        defer l3.deinit(t.allocator);
        try t.expectEqualStrings("Supercalifragili", lineText(s, l3, 0));
        for (l3.lines) |ln| try t.expect(ln.width <= 120);
    }
    {
        // CJK: break between ideographs, never before closing / after opening punctuation
        const s = "\u{4e2d}\u{6587}\u{3002}\u{300c}\u{4e2d}\u{300d}\u{4e2d}";
        var p = try font.Paragraph.init(t.allocator, &fx.fc, &.{.{ .text = s, .style = st }}, .{});
        defer p.deinit();
        const B = font.ShapedGlyph.BREAK_BEFORE;
        const expect = [_]bool{ false, true, false, true, false, false, true };
        for (expect, p.glyphs) |e, g| try t.expectEqual(e, g.flags & B != 0);
    }
}

test "tabs use the run's CSS count and generated hyphens keep a character mapping" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = inter_fam, .size = 20, .tab_spaces = 4 };
    var tabs = try fx.lay("a\tb\tc", st, .{ .white_space = .pre });
    defer tabs.deinit(t.allocator);
    const ft = fx.fc.font(tabs.glyphs[0].face);
    const interval = @as(f32, @floatFromInt(ft.advanceWidth(ft.glyphIndex(' ')))) * 20 / @as(f32, @floatFromInt(ft.units_per_em)) * 4;
    try t.expectApproxEqAbs(interval, tabs.glyphs[2].x, 0.02);
    try t.expectApproxEqAbs(2 * interval, tabs.glyphs[4].x, 0.02);
    var wrapped = try fx.lay("extra\u{ad}ordinary", st, .{ .max_width = 60 });
    defer wrapped.deinit(t.allocator);
    var found = false;
    for (wrapped.glyphs) |g| if (g.generated) |cp| {
        try t.expect(cp == 0x2010 or cp == '-');
        try t.expect(g.gid != 0);
        found = true;
    };
    try t.expect(found);
}

test "the hyphen of a soft hyphen that opens a span takes the span's style" {
    // `extra<span style="color:red; font-size:30px">&shy;ordinary</span>` broken at the soft hyphen:
    // the line ends in the span's item, so its hyphen is the span's (Blink, Firefox, takumi)
    var fx = try Fixture.init();
    defer fx.deinit();
    const outer: font.TextStyle = .{ .families = inter_fam, .size = 20, .user = 1 };
    var span = outer;
    span.user = 2;
    for ([_]f32{ 20, 30 }) |size| {
        span.size = size;
        var l = try font.layoutText(t.allocator, &fx.fc, &.{ .{ .text = "extra", .style = outer }, .{ .text = "\u{ad}ordinary", .style = span } }, .{ .max_width = 60 });
        defer l.deinit(t.allocator);
        var found = false;
        for (l.glyphs) |g| if (g.generated != null) {
            try t.expectEqual(@as(u32, 2), g.user);
            try t.expectEqual(size, g.size);
            found = true;
        };
        try t.expect(found);
    }
}

test "continuation cuts do not enlarge intrinsic text widths" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = inter_fam, .size = 14 };
    var p = try font.Paragraph.init(t.allocator, &fx.fc, &.{.{ .text = "left word left word left word left word", .style = st }}, .{});
    defer p.deinit();
    if (comptime @TypeOf(p.cut) != void) {
        const min_width = p.minContentWidth();
        const max_width = p.maxContentWidth();
        const before = p.measure(90);
        p.cut = 20;
        try t.expectEqual(min_width, p.minContentWidth());
        try t.expectEqual(max_width, p.maxContentWidth());
        const intrinsic = p.measureIntrinsic(90);
        try t.expectEqual(before.height, intrinsic.height);
        try t.expectEqual(before.width, intrinsic.width);
        p.cut = @intCast(p.glyphs.len);
        try t.expectEqual(@as(f32, 0), p.measure(90).height);
        try t.expectEqual(@as(u32, 0), p.measure(90).line_count);
        try t.expectEqual(before.height, p.measureIntrinsic(90).height);
    }
}

test "white-space modes" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = inter_fam, .size = 16 };
    const s = "  leading and   multiple    spaces \t tab\there  \n  second line\n\nfourth   line  ";
    {
        var l = try fx.lay(s, st, .{ .max_width = 200 });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 3), l.lines.len);
        try t.expectEqualStrings("leading and   multiple", lineText(s, l, 0));
        try t.expectApproxEqAbs(@as(f32, 152.2109375), l.lines[0].width, 0.01); // oracle (collapsed)
    }
    {
        var l = try fx.lay(s, st, .{ .max_width = 200, .white_space = .nowrap });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 1), l.lines.len);
        try t.expect(l.width > 200);
    }
    {
        var l = try fx.lay(s, st, .{ .max_width = 90, .white_space = .pre });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 4), l.lines.len); // forced breaks only; blank 3rd line
        try t.expectEqual(l.lines[2].glyph_start, l.lines[2].glyph_end);
        try t.expectApproxEqAbs(@as(f32, 80), l.height, 0.0001);
        try t.expectApproxEqAbs(@as(f32, 330.875), l.width, 0.02); // oracle, tabs + trailing spaces
        try t.expectApproxEqAbs(@as(f32, 95.7890625), l.lines[1].width, 0.01);
    }
    {
        var l = try fx.lay(s, st, .{ .max_width = 200, .white_space = .pre_line });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 5), l.lines.len);
        try t.expectApproxEqAbs(@as(f32, 100), l.height, 0.0001);
        try t.expectEqualStrings("second line", lineText(s, l, 2));
        try t.expectEqualStrings("", lineText(s, l, 3));
        try t.expectApproxEqAbs(@as(f32, 76.5078125), l.lines[4].width, 0.01);
    }
    {
        var l = try fx.lay(s, st, .{ .max_width = 200, .white_space = .pre_wrap });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 5), l.lines.len);
        // oracle: hanging spaces are part of the reported run width
        try t.expectApproxEqAbs(@as(f32, 188.21875), l.lines[0].width, 0.01);
        try t.expectApproxEqAbs(@as(f32, 150.875), l.lines[1].width, 0.01);
    }
    {
        var l = try fx.lay("   \n\t ", st, .{});
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 0), l.lines.len);
        try t.expectEqual(@as(f32, 0), l.height);
        var e = try fx.lay("", st, .{ .max_width = 10, .ellipsis = true, .max_lines = 1 });
        defer e.deinit(t.allocator);
        try t.expectEqual(@as(usize, 0), e.glyphs.len);
    }
}

test "clamp, ellipsis, alignment, justify" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = inter_fam, .size = 16, .user = 7 };
    const s = "The quick brown fox jumps over the lazy dog";
    const ell = fx.fc.font(0).glyphIndex(0x2026);
    const Case = struct { w: f32, text: []const u8, width: f32 };
    // oracle: lineClamp 1
    for ([_]Case{ .{ .w = 150, .text = "The quick brown", .width = 140.40625 }, .{ .w = 120, .text = "The quick", .width = 88.5 }, .{ .w = 85, .text = "The quic", .width = 79.71875 } }) |c| {
        var l = try fx.lay(s, st, .{ .max_width = c.w, .max_lines = 1 });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 1), l.lines.len);
        try t.expectApproxEqAbs(c.width, l.lines[0].width, 0.01);
        try t.expectApproxEqAbs(@as(f32, 20), l.height, 0.0001);
        const last = l.glyphs[l.glyphs.len - 1];
        try t.expectEqual(ell, last.gid);
        try t.expectEqual(@as(u32, 7), last.user);
        const before = l.glyphs[l.glyphs.len - 2];
        try t.expectEqual(c.text[c.text.len - 1], s[before.cluster]);
        try t.expectEqual(c.text.len - 1, before.cluster);
    }
    {
        // oracle: nowrap + text-overflow: ellipsis at 150 -> "The quick brown …" 144.90625
        var l = try fx.lay(s, st, .{ .max_width = 150, .white_space = .nowrap, .ellipsis = true });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 1), l.lines.len);
        try t.expectApproxEqAbs(@as(f32, 144.90625), l.lines[0].width, 0.01);
        // wide enough: untouched
        var l2 = try fx.lay(s, st, .{ .max_width = 1000, .white_space = .nowrap, .ellipsis = true });
        defer l2.deinit(t.allocator);
        try t.expect(l2.glyphs[l2.glyphs.len - 1].gid != ell);
        // no clamp needed: no ellipsis
        var l3 = try fx.lay(s, st, .{ .max_width = 150, .max_lines = 5 });
        defer l3.deinit(t.allocator);
        try t.expectEqual(@as(usize, 3), l3.lines.len);
        try t.expect(l3.glyphs[l3.glyphs.len - 1].gid != ell);
    }
    {
        const a = "aaa bbb ccc ddd";
        // oracle x offsets at width 60: right 33.046875 / 30.609375, center 16.515625 / 15.296875
        var r = try fx.lay(a, st, .{ .max_width = 60, .text_align = .right });
        defer r.deinit(t.allocator);
        try t.expectEqual(@as(usize, 4), r.lines.len);
        try t.expectApproxEqAbs(@as(f32, 33.046875), r.lines[0].x, 0.01);
        try t.expectApproxEqAbs(@as(f32, 30.609375), r.lines[1].x, 0.01);
        try t.expectApproxEqAbs(r.lines[0].x, r.glyphs[0].x, 0.0001);
        var c = try fx.lay(a, st, .{ .max_width = 60, .text_align = .center });
        defer c.deinit(t.allocator);
        try t.expectApproxEqAbs(@as(f32, 16.515625), c.lines[0].x, 0.01);
        try t.expectApproxEqAbs(@as(f32, 15.296875), c.lines[1].x, 0.01);
        var e = try fx.lay(a, st, .{ .max_width = 60, .text_align = .end });
        defer e.deinit(t.allocator);
        try t.expectApproxEqAbs(r.lines[2].x, e.lines[2].x, 0.0001);
        // overflowing line stays at x = 0 when centred (oracle)
        var o = try fx.lay("aaaaaaaaaaaaaaa bbb", st, .{ .max_width = 60, .text_align = .center });
        defer o.deinit(t.allocator);
        try t.expectEqual(@as(f32, 0), o.lines[0].x);
        try t.expectApproxEqAbs(@as(f32, 15.296875), o.lines[1].x, 0.01);
    }
    {
        // oracle: justify at 100 -> first line 100 wide, last line natural 82.890625
        const j = "aaa bbb ccc ddd eee fff";
        var l = try fx.lay(j, st, .{ .max_width = 100, .text_align = .justify });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 2), l.lines.len);
        try t.expectApproxEqAbs(@as(f32, 100), l.lines[0].width, 0.01);
        try t.expectApproxEqAbs(@as(f32, 82.890625), l.lines[1].width, 0.01);
    }
}

test "multiple runs (oracle)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const a: font.TextStyle = .{ .families = inter_fam, .size = 16, .user = 1 };
    const b: font.TextStyle = .{ .families = noto_fam, .size = 28, .user = 2 };
    const runs = [_]font.Run{ .{ .text = "Hello small ", .style = a }, .{ .text = "BIG World", .style = b }, .{ .text = " and small again to wrap lines", .style = a } };
    {
        var l = try font.layoutText(t.allocator, &fx.fc, &runs, .{ .max_width = 400 });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 2), l.lines.len);
        try t.expectApproxEqAbs(@as(f32, 58), l.height, 0.0001);
        try t.expectApproxEqAbs(@as(f32, 30), l.lines[0].baseline, 0.0001);
        try t.expectApproxEqAbs(@as(f32, 38), l.lines[1].top, 0.0001);
        try t.expectApproxEqAbs(@as(f32, 220.5625 + 141.2109375), l.lines[0].width, 0.01);
        // run origins snap to 1/64: "BIG" starts at 86.765625, " and" at 220.5625
        try t.expectApproxEqAbs(@as(f32, 86.765625), l.glyphs[12].x, 0.0001);
        try t.expectEqual(@as(u32, 2), l.glyphs[12].user);
        try t.expectEqual(@as(f32, 28), l.glyphs[12].size);
        try t.expectEqual(@as(u32, 12), l.glyphs[12].cluster);
        try t.expectApproxEqAbs(@as(f32, 220.5625), l.glyphs[21].x, 0.0001);
    }
    {
        var l = try font.layoutText(t.allocator, &fx.fc, &runs, .{ .max_width = 150 });
        defer l.deinit(t.allocator);
        try t.expectApproxEqAbs(@as(f32, 116), l.height, 0.0001);
        var l2 = try font.layoutText(t.allocator, &fx.fc, &runs, .{ .max_width = 150, .line_height = .{ .multiple = 1.5 } });
        defer l2.deinit(t.allocator);
        try t.expectApproxEqAbs(@as(f32, 96), l2.height, 0.0001);
        var l3 = try font.layoutText(t.allocator, &fx.fc, &runs, .{ .max_width = 150, .line_height = .{ .px = 30 } });
        defer l3.deinit(t.allocator);
        try t.expectApproxEqAbs(@as(f32, 120), l3.height, 0.0001);
    }
}

test "line-height: Blink ComputedLineHeightAsFixed rounding (takumi font_style.rs)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    // 9.5pt: the font size rounds to 811/64 px, times 1.3 truncates to 1054/64 (not 1053/64 from
    // truncating 12.667 * 1.3); a length rounds to the nearest 1/64 px (4.6mm = 1112.69/64 -> 1113/64)
    const st: font.TextStyle = .{ .families = inter_fam, .size = 38.0 / 3.0 };
    var a = try fx.lay("a", st, .{ .line_height = .{ .multiple = 1.3 } });
    defer a.deinit(t.allocator);
    try t.expectEqual(@as(f32, 1054.0 / 64.0), a.lines[0].height);
    var b = try fx.lay("a", st, .{ .line_height = .{ .px = 4.6 * 96.0 / 25.4 } });
    defer b.deinit(t.allocator);
    try t.expectEqual(@as(f32, 1113.0 / 64.0), b.lines[0].height);
    // 12px: no rounding either way
    var c = try fx.lay("a", .{ .families = inter_fam, .size = 12 }, .{ .line_height = .{ .multiple = 1.3 } });
    defer c.deinit(t.allocator);
    try t.expectEqual(@as(f32, 998.0 / 64.0), c.lines[0].height);
}

test "measure: cached paragraph, monotonic, min/max content" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var p = try font.Paragraph.init(t.allocator, &fx.fc, &.{.{ .text = para, .style = .{ .families = roboto_fam, .size = 17 } }}, .{});
    defer p.deinit();
    const max = p.maxContentWidth();
    const min = p.minContentWidth();
    try t.expect(min > 0 and min < max);
    try t.expectEqual(max, p.measure(null).width);
    try t.expectEqual(@as(u32, 1), p.measure(max).line_count); // fits exactly at its own ceiled width
    // one layout unit short still fits (Blink `AvailableWidthToFit` adds an epsilon), two do not
    try t.expectEqual(@as(u32, 1), p.measure(max - 1.0 / 64.0).line_count);
    try t.expect(p.measure(max - 2.0 / 64.0).line_count == 2);
    var prev = p.measure(1);
    var w: f32 = 1;
    while (w < max + 40) : (w += 3.7) {
        const s = p.measure(w);
        try t.expect(s.height <= prev.height);
        try t.expect(s.line_count <= prev.line_count);
        try t.expect(s.width <= @max(w, min) + 0.001);
        try t.expect(s.width >= min - 0.001 or s.line_count == 1);
        prev = s;
        // layout agrees with measure
        var l = try p.layout(t.allocator, w);
        defer l.deinit(t.allocator);
        try t.expectEqual(s.width, l.width);
        try t.expectEqual(s.height, l.height);
        try t.expectEqual(@as(usize, s.line_count), l.lines.len);
    }
    try t.expectEqual(@as(u32, 1), prev.line_count);
    // min-content is the widest unbreakable piece
    try t.expectEqual(min, p.measure(0).width);
}

test "empty collection and degenerate input" {
    var fc: font.FontCollection = .{};
    defer fc.deinit(t.allocator);
    var l = try font.layoutText(t.allocator, &fc, &.{.{ .text = "hello", .style = .{} }}, .{ .max_width = 10, .ellipsis = true });
    defer l.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), l.glyphs.len);
    try t.expectEqual(@as(f32, 0), l.height);
    var l2 = try font.layoutText(t.allocator, &fc, &.{}, .{});
    defer l2.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), l2.lines.len);
    try t.expectError(error.InvalidFont, fc.register(t.allocator, "nope", .{}));
}

test "a line of default ignorables only is a line box (takumi / HarfBuzz)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = inter_fam, .size = 16 };
    var ref = try fx.lay("a", st, .{});
    defer ref.deinit(t.allocator);
    // ZWSP, word joiner, ZWJ, soft hyphen, BOM, LRM (oracle: takumi gives each one line of `a`'s height)
    for ([_][]const u8{ "\u{200b}", "\u{2060}", "\u{200d}", "\u{ad}", "\u{feff}", "\u{200e}", "\u{200b}\u{200b}" }) |s| {
        var l = try fx.lay(s, st, .{});
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 1), l.lines.len);
        try t.expectEqual(ref.height, l.height);
        try t.expectEqual(@as(f32, 0), l.lines[0].width);
    }
    // the part after a forced break
    var two = try fx.lay("a\n\u{200b}", st, .{ .white_space = .pre });
    defer two.deinit(t.allocator);
    var two_ref = try fx.lay("a\nb", st, .{ .white_space = .pre });
    defer two_ref.deinit(t.allocator);
    try t.expectEqual(two_ref.lines.len, two.lines.len);
    try t.expectEqual(two_ref.height, two.height);
    // a line with other glyphs gets no extra glyph
    var ab = try fx.lay("a\u{200b}b", st, .{});
    defer ab.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), ab.glyphs.len);
}

test "overflow-wrap of a run, soft hyphen after spaces, fallback widths of Unicode spaces (takumi / HarfBuzz)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = inter_fam, .size = 16 };
    const long = "0V0VNAT008002000000000000BMCKHH02350HTTPS";
    // an `anywhere` span splits its overflowing word; the paragraph's own `normal` does not
    var plain = try font.layoutText(t.allocator, &fx.fc, &.{ .{ .text = "x ", .style = st }, .{ .text = long, .style = st } }, .{ .max_width = 80 });
    defer plain.deinit(t.allocator);
    try t.expect(plain.width > 80);
    var span = try font.layoutText(t.allocator, &fx.fc, &.{ .{ .text = "x ", .style = st }, .{ .text = long, .style = st, .overflow_wrap = .anywhere } }, .{ .max_width = 80 });
    defer span.deinit(t.allocator);
    try t.expect(span.lines.len > 2);
    for (span.lines) |ln| try t.expect(ln.width <= 80);
    var bw = try font.layoutText(t.allocator, &fx.fc, &.{.{ .text = long, .style = st, .overflow_wrap = .break_word }}, .{ .max_width = 80 });
    defer bw.deinit(t.allocator);
    try t.expect(bw.lines.len > 1);

    // "aaaa \u{ad}bbbb" broken at the soft hyphen: the hyphen follows the space (oracle: Chromium, takumi)
    var w1 = try fx.lay("aaaa ", st, .{});
    defer w1.deinit(t.allocator);
    var sh = try fx.lay("aaaa \u{ad}bbbb", st, .{ .max_width = w1.lines[0].width + 12 });
    defer sh.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), sh.lines.len);
    const f0 = fx.fc.font(0);
    const hy = if (f0.glyphIndex(0x2010) != 0) f0.glyphIndex(0x2010) else f0.glyphIndex('-');
    const first = sh.glyphs[sh.lines[0].glyph_start..sh.lines[0].glyph_end];
    try t.expectEqual(hy, first[first.len - 1].gid);

    // a soft hyphen after spaces, the line too narrow for "aaaa" with its hyphen (Blink: the break
    // before the space run, then a line holding only the hyphen; oracle: Chromium, takumi)
    {
        var wa = try fx.lay("aaaa", st, .{});
        defer wa.deinit(t.allocator);
        var l = try fx.lay("aaaa \u{ad}bbbb", st, .{ .max_width = wa.lines[0].width + 1 });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 3), l.lines.len);
        try t.expectEqual(hy, l.glyphs[l.lines[1].glyph_end - 1].gid);
        // a hyphen that does not fit shrinks the width for the earlier breakpoints too: "xx" breaks
        // off at the zero width space, as "xx\u{200b}aaaa" fits only without the hyphen
        // (as wide as "xxaaaa " with its space, which the hyphen then overflows)
        var wx = try fx.lay("xxaaaa b", st, .{});
        defer wx.deinit(t.allocator);
        var wb = try fx.lay("b", st, .{});
        defer wb.deinit(t.allocator);
        var z = try fx.lay("xx\u{200b}aaaa \u{ad}bbbb", st, .{ .max_width = wx.lines[0].width - wb.lines[0].width + 1 });
        defer z.deinit(t.allocator);
        var xx = try fx.lay("xx", st, .{});
        defer xx.deinit(t.allocator);
        try t.expectApproxEqAbs(xx.lines[0].width, z.lines[0].width, 0.01);
    }

    // U+3000 without a glyph: the space glyph, one em wide (HarfBuzz `_hb_ot_shape_fallback_spaces`)
    if (f0.glyphIndex(0x3000) == 0) {
        const ab = try font.shape(t.allocator, &fx.fc, "ab", .{ .families = inter_fam, .size = 100 });
        defer t.allocator.free(ab);
        const ideo = try font.shape(t.allocator, &fx.fc, "a\u{3000}b", .{ .families = inter_fam, .size = 100 });
        defer t.allocator.free(ideo);
        var wa: f32 = 0;
        for (ab) |g| wa += g.x_advance;
        var wi: f32 = 0;
        for (ideo) |g| wi += g.x_advance;
        try t.expectApproxEqAbs(@as(f32, 100), wi - wa, 0.01);
    }

    // U+3000 at the line end hangs, also with overflow-wrap: anywhere (oracle: Chromium, takumi):
    // "aaaa\u{3000}bb" in a line wide enough for "aaaa" only breaks after U+3000, not before it.
    // U+2003 does not hang (Blink `IsOtherSpaceSeparator` is U+3000 only).
    var wa4 = try fx.lay("aaaa", st, .{});
    defer wa4.deinit(t.allocator);
    const narrow = wa4.lines[0].width + 4;
    for ([_]font.OverflowWrap{ .normal, .anywhere }) |ow| {
        for ([_]font.WhiteSpace{ .normal, .pre_wrap }) |ws| {
            var l = try fx.lay("aaaa\u{3000}bb", st, .{ .max_width = narrow, .overflow_wrap = ow, .white_space = ws });
            defer l.deinit(t.allocator);
            try t.expectEqual(@as(usize, 2), l.lines.len);
            try t.expectEqual(f0.glyphIndex('b'), l.glyphs[l.lines[1].glyph_start].gid);
            // (pre-wrap: the line width includes its hanging spaces, see `Paragraph.fin`)
            if (ws == .normal) try t.expect(l.lines[0].width <= narrow);
        }
    }
    // a glyph fits where the line could end after it without its pair kerning with the next glyph:
    // "MATR" as wide as "MA" (unkerned) less a little breaks after "M" (oracle: Chromium, takumi)
    {
        var ma = try fx.lay("MA", st, .{});
        defer ma.deinit(t.allocator);
        var mat = try fx.lay("MAT", st, .{});
        defer mat.deinit(t.allocator);
        var tt = try fx.lay("T", st, .{});
        defer tt.deinit(t.allocator);
        // (the font kerns A-T: the case is meaningful)
        try t.expect(mat.lines[0].width < ma.lines[0].width + tt.lines[0].width - 0.1);
        var l = try fx.lay("MATR", st, .{ .max_width = ma.lines[0].width - 2.0 / 64.0, .overflow_wrap = .anywhere });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(u32, 1), l.lines[0].glyph_end - l.lines[0].glyph_start);
    }
    var em = try fx.lay("aaaa\u{2003}bb", st, .{ .max_width = narrow, .overflow_wrap = .anywhere });
    defer em.deinit(t.allocator);
    try t.expect(em.lines.len >= 2);
    try t.expect(em.glyphs[em.lines[1].glyph_start].gid != f0.glyphIndex('b'));
}

test "text-overflow: custom marker string, block-ellipsis, rtl truncation side" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = inter_fam, .size = 16, .user = 7 };
    const s = "The quick brown fox jumps over the lazy dog";
    const f = fx.fc.font(0);
    const raquo = f.glyphIndex(0xBB);
    const ell = f.glyphIndex(0x2026);
    {
        // " »" replaces "…": the line ends with a space + », content + marker fit
        var l = try fx.lay(s, st, .{ .max_width = 150, .white_space = .nowrap, .ellipsis = true, .ellipsis_text = " \u{bb}" });
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 1), l.lines.len);
        const g = l.glyphs[l.lines[0].glyph_end - 1];
        try t.expectEqual(raquo, g.gid);
        try t.expectEqual(@as(u32, 7), g.user);
        try t.expectEqual(f.glyphIndex(' '), l.glyphs[l.lines[0].glyph_end - 2].gid);
        try t.expect(l.lines[0].width <= 150);
        for (l.glyphs) |x| try t.expect(x.gid != ell);
        // CSS escape + forced breaks collapse to one space: "\bb" == "»", "a\n\nb" == "a b"
        var l2 = try fx.lay(s, st, .{ .max_width = 150, .white_space = .nowrap, .ellipsis = true, .ellipsis_text = "\\bb" });
        defer l2.deinit(t.allocator);
        try t.expectEqual(raquo, l2.glyphs[l2.glyphs.len - 1].gid);
        var l3 = try fx.lay(s, st, .{ .max_width = 150, .white_space = .nowrap, .ellipsis = true, .ellipsis_text = "a\n\n\u{2028}b" });
        defer l3.deinit(t.allocator);
        const n = l3.glyphs.len;
        try t.expectEqual(f.glyphIndex('a'), l3.glyphs[n - 3].gid);
        try t.expectEqual(f.glyphIndex(' '), l3.glyphs[n - 2].gid);
        try t.expectEqual(f.glyphIndex('b'), l3.glyphs[n - 1].gid);
        // empty marker: truncated, nothing appended
        var l4 = try fx.lay(s, st, .{ .max_width = 150, .white_space = .nowrap, .ellipsis = true, .ellipsis_text = "" });
        defer l4.deinit(t.allocator);
        try t.expect(l4.lines[0].width <= 150);
        for (l4.glyphs) |x| try t.expect(x.gid != ell);
        // hostile escapes never crash
        var l5 = try fx.lay(s, st, .{ .max_width = 150, .white_space = .nowrap, .ellipsis = true, .ellipsis_text = "\\0\\110000\\d800\\\xff\xc3\\" });
        defer l5.deinit(t.allocator);
    }
    {
        // line-clamp uses block-ellipsis, not text-overflow's string (takumi LineTruncator)
        var l = try fx.lay(s, st, .{ .max_width = 150, .max_lines = 1, .ellipsis = true, .ellipsis_text = "--", .clamp_text = " >" });
        defer l.deinit(t.allocator);
        try t.expectEqual(f.glyphIndex('>'), l.glyphs[l.glyphs.len - 1].gid);
        var l2 = try fx.lay(s, st, .{ .max_width = 150, .max_lines = 1, .ellipsis = true, .ellipsis_text = "--" });
        defer l2.deinit(t.allocator);
        try t.expectEqual(ell, l2.glyphs[l2.glyphs.len - 1].gid);
        var l3 = try fx.lay(s, st, .{ .max_width = 150, .max_lines = 1, .clamp_no_ellipsis = true });
        defer l3.deinit(t.allocator);
        try t.expectEqual(@as(usize, 1), l3.lines.len);
        for (l3.glyphs) |x| try t.expect(x.gid != ell);
    }
    {
        // a left-to-right line in a right-to-left paragraph keeps its end, the marker sits left
        var l = try fx.lay(s, st, .{ .max_width = 150, .white_space = .nowrap, .ellipsis = true, .direction = .rtl });
        defer l.deinit(t.allocator);
        const gs = l.glyphs[l.lines[0].glyph_start..l.lines[0].glyph_end];
        try t.expectEqual(ell, gs[0].gid);
        try t.expectEqual(f.glyphIndex('g'), gs[gs.len - 1].gid);
        for (gs[1..]) |x| try t.expect(x.x > gs[0].x);
    }
}

test "font-variant-caps: OpenType caps or synthesized small caps (Blink rules)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const f = fx.fc.font(0); // Inter: no smcp
    {
        var l = try fx.lay("a\u{df}B", .{ .families = inter_fam, .size = 20, .caps = .small }, .{});
        defer l.deinit(t.allocator);
        // a -> A at round(20 * 0.7) = 14, ß -> SS at 14, B unchanged at 20
        try t.expectEqual(@as(usize, 4), l.glyphs.len);
        try t.expectEqual(f.glyphIndex('A'), l.glyphs[0].gid);
        try t.expectEqual(@as(f32, 14), l.glyphs[0].size);
        try t.expectEqual(f.glyphIndex('S'), l.glyphs[1].gid);
        try t.expectEqual(f.glyphIndex('S'), l.glyphs[2].gid);
        try t.expectEqual(l.glyphs[1].cluster, l.glyphs[2].cluster);
        try t.expectEqual(f.glyphIndex('B'), l.glyphs[3].gid);
        try t.expectEqual(@as(f32, 20), l.glyphs[3].size);
    }
    {
        // font-synthesis-small-caps: none leaves the text alone
        var l = try fx.lay("aB", .{ .families = inter_fam, .size = 20, .caps = .small, .synth_small_caps = false }, .{});
        defer l.deinit(t.allocator);
        try t.expectEqual(f.glyphIndex('a'), l.glyphs[0].gid);
        try t.expectEqual(@as(f32, 20), l.glyphs[0].size);
    }
    {
        // all-small-caps also shrinks capitals
        var l = try fx.lay("aB", .{ .families = inter_fam, .size = 20, .caps = .all_small }, .{});
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(f32, 14), l.glyphs[1].size);
    }
    {
        // Noto Sans has smcp: its own small-cap glyphs, full size; petite-caps falls back to smcp
        var plain = try fx.lay("a", .{ .families = noto_fam, .size = 20 }, .{});
        defer plain.deinit(t.allocator);
        for ([_]font.Caps{ .small, .petite }) |cv| {
            var l = try fx.lay("a", .{ .families = noto_fam, .size = 20, .caps = cv }, .{});
            defer l.deinit(t.allocator);
            try t.expect(l.glyphs[0].gid != plain.glyphs[0].gid);
            try t.expectEqual(@as(f32, 20), l.glyphs[0].size);
        }
    }
}

test "fuzz: caps synthesis and overflow markers on truncated / corrupted fonts never crash" {
    var seed: u32 = 12345;
    var k: usize = 0;
    while (k < 60) : (k += 1) {
        const buf = try t.allocator.dupe(u8, noto);
        defer t.allocator.free(buf);
        seed = seed *% 1103515245 +% 12345;
        const len = 12 + (seed >> 8) % @as(u32, @intCast(buf.len - 12));
        // corrupt a few bytes inside the (likely GSUB-heavy) tail as well
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            seed = seed *% 1103515245 +% 12345;
            buf[(seed >> 4) % len] = @truncate(seed >> 16);
        }
        var fc: font.FontCollection = .{};
        defer fc.deinit(t.allocator);
        _ = fc.register(t.allocator, buf[0..len], .{}) catch continue;
        for ([_]font.Caps{ .small, .all_small, .petite, .unicase, .titling }) |cv| {
            var l = font.layoutText(t.allocator, &fc, &.{.{ .text = "a\u{df}B \u{1F469}\u{200D}\u{1F4BB} x", .style = .{ .size = 20, .caps = cv } }}, .{ .max_width = 30, .white_space = .nowrap, .ellipsis = true, .ellipsis_text = " \u{bb}x" }) catch continue;
            l.deinit(t.allocator);
        }
    }
}
