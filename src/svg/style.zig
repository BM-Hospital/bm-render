//! Computed (inherited) style used while walking the render tree.
const std = @import("std");
const raster = @import("../raster/raster.zig");
const dom = @import("dom.zig");
const num = @import("num.zig");
const color = @import("color.zig");
const stroke = @import("stroke.zig");
const Color = raster.Color;

pub const PaintKind = enum(u8) { none, color, current, server };

pub const SPaint = struct {
    kind: PaintKind,
    color: Color = Color.black,
    /// `url(...)` text for servers
    ref: []const u8 = "",
    /// fallback after the url (`none`, a colour or currentColor); null = none
    fallback: PaintKind = .none,
};

pub fn parsePaint(s_in: []const u8) ?SPaint {
    const s = num.trim(s_in);
    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "none")) return .{ .kind = .none };
    if (num.eqlIgnoreCase(s, "currentColor")) return .{ .kind = .current };
    if (std.mem.startsWith(u8, s, "url(")) {
        const e = std.mem.indexOfScalar(u8, s, ')') orelse return null;
        var p: SPaint = .{ .kind = .server, .ref = s[0 .. e + 1] };
        const rest = num.trim(s[e + 1 ..]);
        if (rest.len > 0) {
            if (num.eqlIgnoreCase(rest, "currentColor")) {
                p.fallback = .current;
            } else if (color.parse(rest)) |c| {
                p.fallback = .color;
                p.color = c;
            }
        }
        return p;
    }
    if (std.mem.startsWith(u8, s, "context-")) return .{ .kind = .none };
    const c = color.parse(s) orelse return null;
    return .{ .kind = .color, .color = c };
}

pub const DecorationPaint = struct { fill: SPaint, stroke: SPaint, color: Color, fill_opacity: f32, stroke_opacity: f32, stroke_width: num.Length };
pub const Style = struct {
    fill: SPaint = .{ .kind = .color },
    stroke: SPaint = .{ .kind = .none },
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    fill_rule: raster.FillRule = .nonzero,
    clip_rule: raster.FillRule = .nonzero,
    stroke_width: num.Length = .{ .v = 1 },
    miter_limit: f32 = 4,
    cap: stroke.Cap = .butt,
    join: stroke.Join = .miter,
    dasharray: []const u8 = "",
    dashoffset: num.Length = .{ .v = 0 },
    color: Color = Color.black,
    visible: bool = true,
    /// paint order: 3 x 2-bit codes (0 fill, 1 stroke, 2 markers), first in low bits
    paint_order: u8 = 0 | (1 << 2) | (2 << 4),
    marker_start: []const u8 = "",
    marker_mid: []const u8 = "",
    marker_end: []const u8 = "",
    font_size: f32 = 16,
    font_family: []const u8 = "",
    font_weight: []const u8 = "",
    font_style: []const u8 = "",
    font_stretch: []const u8 = "",
    font_variant: []const u8 = "",
    text_anchor: []const u8 = "",
    /// `letter-spacing` / `word-spacing` in user units, resolved where declared (`normal` = 0).
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    dominant_baseline: []const u8 = "",
    /// Decoration paint belongs to its declaring element, even when a child changes fill.
    decorations: [3]?DecorationPaint = @splat(null),
    linear_rgb_filters: bool = true,

    /// Applies the inherited properties declared on `n` (unknown / invalid values are ignored,
    /// which keeps the inherited value, as CSS does for invalid declarations).
    pub fn apply(st: *Style, n: *const dom.Node) void {
        for (n.decls) |d| {
            if (!d.prop.inherited()) continue;
            const v = num.trim(d.value);
            if (std.mem.eql(u8, v, "inherit")) continue;
            st.applyOne(d.prop, v);
        }
        for (n.decls) |d| if (d.prop == .text_decoration or d.prop == .text_decoration_line) {
            var words = std.mem.tokenizeAny(u8, d.value, " \t\r\n");
            while (words.next()) |word| {
                const index: usize = if (std.mem.eql(u8, word, "overline")) 0 else if (std.mem.eql(u8, word, "underline")) 1 else if (std.mem.eql(u8, word, "line-through")) 2 else continue;
                st.decorations[index] = .{ .fill = st.fill, .stroke = st.stroke, .color = st.color, .fill_opacity = st.fill_opacity, .stroke_opacity = st.stroke_opacity, .stroke_width = st.stroke_width };
            }
        };
    }

    fn applyOne(st: *Style, p: dom.Prop, v: []const u8) void {
        switch (p) {
            .fill => st.fill = parsePaint(v) orelse return,
            .stroke => st.stroke = parsePaint(v) orelse return,
            .fill_opacity => st.fill_opacity = opacity(v) orelse return,
            .stroke_opacity => st.stroke_opacity = opacity(v) orelse return,
            .fill_rule => st.fill_rule = rule(v) orelse return,
            .clip_rule => st.clip_rule = rule(v) orelse return,
            .stroke_width => {
                const l = num.parseLength(v) orelse return;
                if (l.v < 0) return;
                st.stroke_width = l;
            },
            .stroke_miterlimit => {
                const m = num.parseNumber(v) orelse return;
                if (m < 1) return;
                st.miter_limit = m;
            },
            .stroke_linecap => st.cap = std.meta.stringToEnum(stroke.Cap, v) orelse return,
            .stroke_linejoin => st.join = if (std.mem.eql(u8, v, "miter-clip") or std.mem.eql(u8, v, "arcs")) .miter else std.meta.stringToEnum(stroke.Join, v) orelse return,
            .stroke_dasharray => st.dasharray = v,
            .stroke_dashoffset => st.dashoffset = num.parseLength(v) orelse return,
            .color => {
                if (num.eqlIgnoreCase(v, "currentColor")) return;
                st.color = color.parse(v) orelse return;
            },
            .visibility => st.visible = std.mem.eql(u8, v, "visible"),
            .paint_order => st.paint_order = paintOrder(v) orelse return,
            .marker_start => st.marker_start = v,
            .marker_mid => st.marker_mid = v,
            .marker_end => st.marker_end = v,
            .font_size => {
                const l = num.parseLength(v) orelse return;
                const fs = switch (l.unit) {
                    .percent => l.v * st.font_size / 100,
                    .em => l.v * st.font_size,
                    .ex => l.v * st.font_size / 2,
                    else => num.resolve(l, 0, st.font_size),
                };
                if (fs >= 0 and fs < 1e5) st.font_size = fs;
            },
            .font_family => st.font_family = v,
            .font_weight => st.font_weight = v,
            .font_style => st.font_style = v,
            .font_stretch => st.font_stretch = v,
            .font_variant => st.font_variant = v,
            .text_anchor => st.text_anchor = v,
            .letter_spacing => st.letter_spacing = spacing(v, st.font_size) orelse return,
            .word_spacing => st.word_spacing = spacing(v, st.font_size) orelse return,
            // `no-change` keeps the parent's value, which is what inheriting it already gives
            .dominant_baseline => if (!std.mem.eql(u8, v, "no-change")) {
                st.dominant_baseline = v;
            },
            .color_interpolation_filters => {
                if (std.mem.eql(u8, v, "sRGB")) st.linear_rgb_filters = false else if (std.mem.eql(u8, v, "linearRGB") or std.mem.eql(u8, v, "auto")) st.linear_rgb_filters = true;
            },
            else => {},
        }
    }
};

/// A `letter-spacing` / `word-spacing` value in user units; `normal` is 0, `em` takes the
/// font size of the element that declares it.
fn spacing(v: []const u8, font_size: f32) ?f32 {
    if (std.mem.eql(u8, v, "normal")) return 0;
    const l = num.parseLength(v) orelse return null;
    if (l.unit == .percent) return null;
    const px = num.resolve(l, 0, font_size);
    return if (std.math.isFinite(px)) px else null;
}

pub fn opacity(v: []const u8) ?f32 {
    const f = num.parseFraction(v) orelse return null;
    return std.math.clamp(f, 0, 1);
}

fn rule(v: []const u8) ?raster.FillRule {
    if (std.mem.eql(u8, v, "nonzero")) return .nonzero;
    if (std.mem.eql(u8, v, "evenodd")) return .evenodd;
    return null;
}

fn paintOrder(v: []const u8) ?u8 {
    if (std.mem.eql(u8, v, "normal")) return 0 | (1 << 2) | (2 << 4);
    var order: [3]u8 = undefined;
    var n: usize = 0;
    var seen: [3]bool = .{ false, false, false };
    var it = std.mem.tokenizeAny(u8, v, " \t\r\n");
    while (it.next()) |t| {
        const k: u8 = if (std.mem.eql(u8, t, "fill")) 0 else if (std.mem.eql(u8, t, "stroke")) 1 else if (std.mem.eql(u8, t, "markers")) 2 else return null;
        if (seen[k] or n >= 3) return null;
        seen[k] = true;
        order[n] = k;
        n += 1;
    }
    for (0..3) |k| if (!seen[k]) {
        order[n] = @intCast(k);
        n += 1;
    };
    return order[0] | (order[1] << 2) | (order[2] << 4);
}

test "style" {
    var st: Style = .{};
    const decls = [_]dom.Decl{
        .{ .prop = .fill, .value = "url(#g) red" },
        .{ .prop = .stroke_linejoin, .value = "round" },
        .{ .prop = .paint_order, .value = "stroke" },
        .{ .prop = .font_size, .value = "2em" },
        .{ .prop = .opacity, .value = "0.5" },
        .{ .prop = .fill_opacity, .value = "150%" },
    };
    const n: dom.Node = .{ .tag = .g, .decls = &decls };
    st.apply(&n);
    try std.testing.expectEqual(PaintKind.server, st.fill.kind);
    try std.testing.expectEqual(PaintKind.color, st.fill.fallback);
    try std.testing.expectEqual(stroke.Join.round, st.join);
    try std.testing.expectEqual(@as(u8, 1 | (0 << 2) | (2 << 4)), st.paint_order);
    try std.testing.expectEqual(@as(f32, 32), st.font_size);
    try std.testing.expectEqual(@as(f32, 1), st.fill_opacity);
}
