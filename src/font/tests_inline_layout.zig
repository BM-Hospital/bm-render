//! Tests for inline layout features of `text.zig` that are driven by the block's style: text-indent,
//! right-to-left inline box edges, balanced wrapping of paragraphs with inline boxes.
//! Expected numbers marked "oracle" were measured with @takumi-rs/wasm 2.20.0.
const std = @import("std");
const font = @import("font.zig");
const t = std.testing;

const inter = @embedFile("testdata/Inter-Regular.ttf");
const fam: []const []const u8 = &.{"Inter"};

const Fx = struct {
    fc: font.FontCollection = .{},
    fn init() !Fx {
        var fx: Fx = .{};
        errdefer fx.fc.deinit(t.allocator);
        _ = try fx.fc.register(t.allocator, inter, .{});
        return fx;
    }
    fn deinit(fx: *Fx) void {
        fx.fc.deinit(t.allocator);
    }
    fn para(fx: *Fx, text: []const u8, opts: font.ParagraphOptions) !font.Paragraph {
        return font.Paragraph.init(t.allocator, &fx.fc, &.{.{ .text = text, .style = .{ .families = fam, .size = 16 } }}, opts);
    }
};

test "text-indent: first line, each-line, hanging, percentages, intrinsic sizes" {
    var fx = try Fx.init();
    defer fx.deinit();
    const s = "The quick brown fox jumps over the lazy dog";
    var plain = try fx.para(s, .{});
    defer plain.deinit();
    const max0 = plain.maxContentWidth();
    const min0 = plain.minContentWidth();
    {
        var p = try fx.para(s, .{ .indent = 40 });
        defer p.deinit();
        // the indent is part of the first line: max-content grows by it, min-content only when the
        // first word is the widest piece
        try t.expectEqual(max0 + 40, p.maxContentWidth());
        try t.expect(p.minContentWidth() >= min0 and p.minContentWidth() <= min0 + 40);
        var l = try p.layout(t.allocator, 150);
        defer l.deinit(t.allocator);
        var l0 = try plain.layout(t.allocator, 150);
        defer l0.deinit(t.allocator);
        try t.expectEqual(@as(f32, 40), l.lines[0].x);
        try t.expectEqual(@as(f32, 0), l.lines[1].x);
        // 150 - 40 px for the first line: "The quick" (oracle 88.5 with the ellipsis: 3 words do not fit)
        try t.expect(l.lines[0].width <= 110);
        try t.expect(l.lines.len >= l0.lines.len);
        try t.expectEqual(l.lines.len, @as(usize, p.measure(150).line_count));
    }
    {
        // negative: the first line starts left of the content box and has more room
        var p = try fx.para(s, .{ .indent = -30 });
        defer p.deinit();
        try t.expectEqual(max0 - 30, p.maxContentWidth());
        var l = try p.layout(t.allocator, 150);
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(f32, -30), l.lines[0].x);
        try t.expect(l.lines[0].width > 150 - 30 and l.lines[0].width <= 180);
    }
    {
        // hanging: every line but the first; a percentage refers to the width broken at (and to nothing
        // in intrinsic sizing)
        var p = try fx.para(s, .{ .indent_pct = 0.2, .indent_hanging = true });
        defer p.deinit();
        try t.expectEqual(max0, p.maxContentWidth());
        var l = try p.layout(t.allocator, 150);
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(f32, 0), l.lines[0].x);
        try t.expectEqual(@as(f32, 30), l.lines[1].x);
        try t.expectEqual(@as(f32, 30), l.lines[l.lines.len - 1].x);
    }
    {
        // each-line: also after a forced break; centred lines are centred in what the indent leaves
        var p = try fx.para("ab\ncd ef gh\nij", .{ .indent = 20, .indent_each_line = true, .white_space = .pre_line, .text_align = .center });
        defer p.deinit();
        var l = try p.layout(t.allocator, 60);
        defer l.deinit(t.allocator);
        var q = try fx.para("ab\ncd ef gh\nij", .{ .white_space = .pre_line, .text_align = .center });
        defer q.deinit();
        var l0 = try q.layout(t.allocator, 40);
        defer l0.deinit(t.allocator);
        try t.expectEqual(l0.lines[0].x + 20, l.lines[0].x);
        try t.expectEqual(l0.lines[l0.lines.len - 1].x + 20, l.lines[l.lines.len - 1].x);
    }
    {
        // right-to-left paragraphs keep the indent on the right
        var p = try fx.para("abc def", .{ .indent = 25, .direction = .rtl, .text_align = .start });
        defer p.deinit();
        var l = try p.layout(t.allocator, 200);
        defer l.deinit(t.allocator);
        try t.expectApproxEqAbs(@as(f32, 200 - 25), l.lines[0].x + l.lines[0].width, 1.0 / 64.0 + 0.001);
    }
}

test "inline box edges are placed visually: rtl box around ltr text, box split by bidi reordering" {
    var fx = try Fx.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = fam, .size = 16 };
    {
        // direction: rtl box (start edge = right side, 6 px; end edge = left side, 22 px with an 8 px
        // margin) in a left-to-right line: the left side stays on the left
        const boxes = [_]font.InlineBox{.{ .style = st, .start = 6, .end = 22, .margin_end = 8, .rtl = true, .decorated = true }};
        var p = try font.Paragraph.init(t.allocator, &fx.fc, &.{ .{ .text = "ab ", .style = st }, .{ .text = "cd", .style = st, .box = 0 }, .{ .text = " ef", .style = st } }, .{ .boxes = &boxes });
        defer p.deinit();
        var l = try p.layout(t.allocator, 400);
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 1), l.boxes.len);
        const f = l.boxes[0];
        try t.expect(f.rtl and f.first and f.last);
        // glyphs: a b space | c d | space e f
        const x_c = l.glyphs[3].x;
        const x_sp = l.glyphs[5].x;
        try t.expectApproxEqAbs(x_c - 22 + 8, f.x0, 0.02);
        // (the border box ends where the text after it starts: the right side has no margin)
        try t.expectApproxEqAbs(x_sp, f.x1, 0.02);
        try t.expectApproxEqAbs(l.segments[0].x1 + 22, x_c, 0.02);
    }
    {
        // an ltr box whose content is cut in two by an override: two fragments, the left edge on the
        // leftmost, the right edge on the rightmost
        const boxes = [_]font.InlineBox{.{ .style = st, .start = 5, .end = 7, .decorated = true }};
        var p = try font.Paragraph.init(t.allocator, &fx.fc, &.{ .{ .text = "a ", .style = st }, .{ .text = "in \u{202e}REV", .style = st, .box = 0 }, .{ .text = " ERSED\u{202c} out", .style = st } }, .{ .boxes = &boxes });
        defer p.deinit();
        var l = try p.layout(t.allocator, 400);
        defer l.deinit(t.allocator);
        try t.expectEqual(@as(usize, 2), l.boxes.len);
        const a = l.boxes[0];
        const b = l.boxes[1];
        try t.expect(a.x1 < b.x0);
        try t.expect(a.first and !a.last and !b.first and b.last);
        // line width: all the text plus both edges, as when the box is contiguous
        try t.expectApproxEqAbs(p.maxContentWidth(), l.lines[0].width, 1.0 / 64.0 + 0.001);
    }
}

test "text-wrap: balance with inline boxes and atomic inlines (flow layout)" {
    var fx = try Fx.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = fam, .size = 14 };
    const boxes = [_]font.InlineBox{.{ .style = st, .start = 7, .end = 7, .decorated = true }};
    const runs = [_]font.Run{
        .{ .text = "A headline ", .style = st },
        .{ .text = "that should", .style = st, .box = 0 },
        .{ .text = " be balanced across its lines nicely ", .style = st },
        .{ .text = "", .style = st, .object = .{ .id = 0 } },
        .{ .text = " ok", .style = st },
    };
    const objs = [_]font.ObjectMetrics{.{ .width = 30, .ascent = 10, .descent = 2 }};
    var greedy = try font.Paragraph.init(t.allocator, &fx.fc, &runs, .{ .boxes = &boxes });
    defer greedy.deinit();
    var bal = try font.Paragraph.init(t.allocator, &fx.fc, &runs, .{ .boxes = &boxes, .text_wrap = .balance });
    defer bal.deinit();
    try t.expect(bal.complex);
    const flow: font.Flow = .{ .alloc = t.allocator, .objects = &objs };
    var lg = try greedy.layoutFlow(t.allocator, &flow, 300);
    defer lg.deinit(t.allocator);
    var lb = try bal.layoutFlow(t.allocator, &flow, 300);
    defer lb.deinit(t.allocator);
    // same number of lines; the greedy last line is short, the balanced lines are even
    try t.expectEqual(lg.lines.len, lb.lines.len);
    try t.expect(lg.lines.len >= 2);
    const gl = lg.lines[lg.lines.len - 1].width;
    const bl = lb.lines[lb.lines.len - 1].width;
    try t.expect(bl > gl);
    try t.expect(lb.lines[0].width < lg.lines[0].width);
    // measuring agrees with layout
    const sz = bal.measureFlow(&flow, 300);
    try t.expectEqual(@as(usize, sz.line_count), lb.lines.len);
    try t.expectEqual(sz.width, lb.width);
    // a float inside the text takes balancing away (Blink: no line widths, no bisection)
    const runs_f = [_]font.Run{
        .{ .text = "A headline that ", .style = st },
        .{ .text = "", .style = st, .object = .{ .id = 0, .kind = .float } },
        .{ .text = "should be balanced across its lines nicely ok", .style = st },
    };
    var gf = try font.Paragraph.init(t.allocator, &fx.fc, &runs_f, .{});
    defer gf.deinit();
    var bf = try font.Paragraph.init(t.allocator, &fx.fc, &runs_f, .{ .text_wrap = .balance });
    defer bf.deinit();
    var l1 = try gf.layoutFlow(t.allocator, &.{ .alloc = t.allocator }, 200);
    defer l1.deinit(t.allocator);
    var l2 = try bf.layoutFlow(t.allocator, &.{ .alloc = t.allocator }, 200);
    defer l2.deinit(t.allocator);
    try t.expectEqual(l1.lines.len, l2.lines.len);
    for (l1.lines, l2.lines) |a, b| try t.expectEqual(a.width, b.width);
}

test "inline box edges with percentages resolve against the percentage base" {
    var fx = try Fx.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = fam, .size = 16 };
    // padding-left 10 % + 2 px border, margin-right 5 %
    const boxes = [_]font.InlineBox{.{ .style = st, .decorated = true, .pct = .{ .padding_pct = .{ 0.1, 0 }, .border = .{ 2, 0 }, .margin_pct = .{ 0, 0.05 } } }};
    const runs = [_]font.Run{ .{ .text = "ab ", .style = st }, .{ .text = "cd", .style = st, .box = 0 }, .{ .text = " ef", .style = st } };
    var p = try font.Paragraph.init(t.allocator, &fx.fc, &runs, .{ .boxes = &boxes });
    defer p.deinit();
    try t.expect(p.complex and p.has_pct_edges);
    // intrinsic sizing: the percentages are 0
    const w0 = p.maxContentWidth();
    p.setPercentBase(300);
    try t.expectEqual(w0 + 30 + 15, p.maxContentWidth());
    var l = try p.layout(t.allocator, 300);
    defer l.deinit(t.allocator);
    try t.expectEqual(@as(f32, 300), l.pct_base);
    try t.expectEqual(@as(usize, 1), l.boxes.len);
    // border box: 2 px border + 30 px padding + the text; the 15 px margin lies outside it
    const x_c = l.glyphs[3].x;
    try t.expectApproxEqAbs(x_c - 32, l.boxes[0].x0, 0.02);
    try t.expectApproxEqAbs(l.glyphs[5].x - 15, l.boxes[0].x1, 0.02);
    p.setPercentBase(0);
    try t.expectEqual(w0, p.maxContentWidth());
    p.setPercentBase(std.math.inf(f32));
    try t.expectEqual(w0, p.maxContentWidth());
}

test "relatively positioned inline box: its glyphs, fragments and atomic inlines move, the lines do not" {
    var fx = try Fx.init();
    defer fx.deinit();
    const st: font.TextStyle = .{ .families = fam, .size = 16 };
    const runs = [_]font.Run{
        .{ .text = "ab ", .style = st },
        .{ .text = "cd ", .style = st, .box = 0 },
        .{ .text = "", .style = st, .box = 0, .object = .{ .id = 0 } },
        .{ .text = "ef", .style = st, .box = 1 },
        .{ .text = " gh", .style = st },
    };
    const objs = [_]font.ObjectMetrics{.{ .width = 20, .ascent = 10, .descent = 0 }};
    const flow: font.Flow = .{ .alloc = t.allocator, .objects = &objs };
    const plain = [_]font.InlineBox{ .{ .style = st, .decorated = true }, .{ .style = st, .parent = 0, .decorated = true } };
    const moved = [_]font.InlineBox{ .{ .style = st, .decorated = true, .rel = .{ 5, 3 } }, .{ .style = st, .parent = 0, .decorated = true, .rel = .{ -2, 1 } } };
    var p0 = try font.Paragraph.init(t.allocator, &fx.fc, &runs, .{ .boxes = &plain });
    defer p0.deinit();
    var p1 = try font.Paragraph.init(t.allocator, &fx.fc, &runs, .{ .boxes = &moved });
    defer p1.deinit();
    var a = try p0.layoutFlow(t.allocator, &flow, 400);
    defer a.deinit(t.allocator);
    var b = try p1.layoutFlow(t.allocator, &flow, 400);
    defer b.deinit(t.allocator);
    try t.expectEqual(a.glyphs.len, b.glyphs.len);
    try t.expectEqual(a.lines[0].width, b.lines[0].width);
    try t.expectEqual(a.height, b.height);
    // "ab " stays; "cd " moves by the outer box; "ef" by both; " gh" stays
    try t.expectEqual(a.glyphs[0].x, b.glyphs[0].x);
    try t.expectEqual(a.glyphs[3].x + 5, b.glyphs[3].x);
    try t.expectEqual(a.glyphs[3].y + 3, b.glyphs[3].y);
    try t.expectEqual(a.glyphs[6].x + 3, b.glyphs[6].x);
    try t.expectEqual(a.glyphs[6].y + 4, b.glyphs[6].y);
    try t.expectEqual(a.glyphs[a.glyphs.len - 1].x, b.glyphs[b.glyphs.len - 1].x);
    try t.expectEqual(a.objects[0].x + 5, b.objects[0].x);
    try t.expectEqual(a.objects[0].y + 3, b.objects[0].y);
    try t.expectEqual(a.boxes[0].x0 + 5, b.boxes[0].x0);
    try t.expectEqual(a.boxes[1].x0 + 3, b.boxes[1].x0);
    try t.expectEqual(a.boxes[1].baseline + 4, b.boxes[1].baseline);
}

// ---- vertical text (writing-mode / text-orientation, src/writing_mode.zig)

const cjk = @embedFile("testdata/CJKLoclTest.otf");

test "vertical text: Unicode vertical orientation (UAX #50 subset)" {
    const up = font.text.isUprightMixed;
    try t.expect(!up('A') and !up('1') and !up(' ') and !up(0x2014) and !up(0x0410));
    try t.expect(up(0x3042) and up(0x30ab) and up(0x76f4) and up(0xac00) and up(0xff21) and up(0x3001) and up(0x20000));
    try t.expect(up(0xa9) and up(0xd7) and !up(0xab));
}

test "vertical text: orientation per character, vertical advances, upright segments" {
    var fc: font.FontCollection = .{};
    defer fc.deinit(t.allocator);
    _ = try fc.register(t.allocator, inter, .{});
    _ = try fc.register(t.allocator, cjk, .{});
    const txt = "A\u{76f4}B";
    const Case = struct { o: font.text.VOrient, up: [3]bool };
    for ([_]Case{
        .{ .o = .none, .up = .{ false, false, false } },
        .{ .o = .mixed, .up = .{ false, true, false } },
        .{ .o = .upright, .up = .{ true, true, true } },
        .{ .o = .sideways, .up = .{ false, false, false } },
    }) |c| {
        var p = try font.Paragraph.init(t.allocator, &fc, &.{.{ .text = txt, .style = .{ .size = 20, .vertical = c.o } }}, .{});
        defer p.deinit();
        try t.expectEqual(@as(usize, 3), p.glyphs.len);
        for (p.glyphs, c.up) |g, want| try t.expectEqual(want, g.upright);
        var tl = try p.layout(t.allocator, null);
        defer tl.deinit(t.allocator);
        for (tl.glyphs, c.up) |g, want| try t.expectEqual(want, g.upright);
        // an upright glyph advances by its vertical advance (`vmtx`), not its horizontal one
        const f = fc.font(p.glyphs[1].face);
        const s: f32 = 20 / @as(f32, @floatFromInt(f.units_per_em));
        const vadv = @as(f32, @floatFromInt(f.advanceHeight(p.glyphs[1].gid))) * s;
        const hadv = @as(f32, @floatFromInt(f.advanceWidth(p.glyphs[1].gid))) * s;
        try t.expectApproxEqAbs(if (c.up[1]) vadv else hadv, p.glyphs[1].x_advance, 0.01);
    }
}

test "vertical metrics fall back without vhea / vmtx / VORG" {
    const f = try font.Font.init(inter, 0);
    try t.expect(!f.hasVerticalMetrics());
    const lm = f.lineMetrics();
    const g = f.glyphIndex('A');
    try t.expectEqual(@as(u16, @intCast(lm.ascent + lm.descent)), f.advanceHeight(g));
    try t.expectEqual(lm.ascent, f.verticalOriginY(g));
}

test "vertical text: text-combine-upright sets a unit upright in one em" {
    var fc: font.FontCollection = .{};
    defer fc.deinit(t.allocator);
    _ = try fc.register(t.allocator, inter, .{});
    const v: font.TextStyle = .{ .size = 20, .vertical = .mixed };
    var c = v;
    c.combine = true;
    var p = try font.Paragraph.init(t.allocator, &fc, &.{ .{ .text = "ab", .style = v }, .{ .text = "2024", .style = c }, .{ .text = "cd", .style = v } }, .{});
    defer p.deinit();
    try t.expectEqual(@as(usize, 8), p.glyphs.len);
    // the unit: upright, compressed to one em, advancing by one em in all
    var adv: f32 = 0;
    for (p.glyphs[2..6]) |g| {
        try t.expect(g.upright and g.combine > 0 and g.combine < 1);
        adv += g.x_advance;
    }
    try t.expectEqual(@as(f32, 20), adv);
    for (p.glyphs[3..6]) |g| try t.expect(g.flags & font.text.ShapedGlyph.NO_SPLIT != 0);
    var tl = try p.layout(t.allocator, null);
    defer tl.deinit(t.allocator);
    // its glyphs share the unit's start, set left to right across the line (decreasing y offsets)
    for (tl.glyphs[3..6], tl.glyphs[2..5]) |g, prev| {
        try t.expectEqual(prev.x, g.x);
        try t.expect(g.y < prev.y);
    }
    try t.expectEqual(tl.glyphs[2].x + 20, tl.glyphs[6].x);
    for ([_]usize{ 0, 1, 6, 7 }) |k| try t.expect(!tl.glyphs[k].upright and tl.glyphs[k].combine == 0);
}
