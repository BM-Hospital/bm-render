//! Vertical writing modes (`writing-mode: vertical-rl | vertical-lr | sideways-rl`, CSS Writing Modes 4).
//!
//! The layout engine only knows horizontal flow. A box in a vertical writing mode is laid out in its
//! logical space instead: inline axis = x, block axis = y, with its layout style transposed
//! (`transpose`: width <-> height, the physical edges mapped onto the logical ones), and its paragraphs
//! broken into ordinary lines (text.zig shapes the upright characters with `vert` and their vertical
//! advances). An element whose writing mode's axes differ from its parent's is an orthogonal flow root
//! (`layout.Tree.setOrtho`): the engine swaps the axes of the requests between the two spaces and sizes
//! its inline size as CSS Writing Modes 4 §7.3 asks. After layout `physicalize` maps every box laid out
//! in a vertical space to physical coordinates, so the painters draw boxes as they always do; only text
//! is drawn through a transform (`lineTransform`): the logical lines turned 90 degrees clockwise, the
//! upright glyphs turned back (`uprightOrigin`).
//!
//! `vertical-lr` stacks the lines from left to right but keeps the clockwise glyph orientation (the
//! line-over side is on the right in both vertical modes): its line layouts have their lines moved to
//! mirrored block positions (`mirrorLines`), then everything draws as `vertical-rl`.
//!
//! Unsupported (the subtree of the vertical element falls back to horizontal layout, `fallback`):
//! tables, absolutely / fixed positioned boxes, `sideways-lr`, and `vertical-lr` mixed with
//! `vertical-rl` inside one vertical flow.
const std = @import("std");
const render = @import("render.zig");
const style = @import("style/style.zig");
const layout = @import("layout/layout.zig");
const font = @import("font/font.zig");

const Frame = render.Frame;
const CS = render.CS;
const none = render.none;
const WM = style.computed.WritingMode;

/// Writing mode of a box's own content: 0 horizontal, 1 vertical-rl (and sideways-rl), 2 vertical-lr.
pub inline fn vmOf(cs: *const CS) u2 {
    return switch (cs.writing_mode) {
        .horizontal_tb, .sideways_lr => 0,
        .vertical_rl, .sideways_rl => 1,
        .vertical_lr => 2,
    };
}

/// `TextStyle.vertical` of text in style `cs`.
pub fn textOrient(cs: *const CS) font.text.VOrient {
    return switch (cs.writing_mode) {
        .horizontal_tb, .sideways_lr => .none,
        .sideways_rl => .sideways,
        .vertical_rl, .vertical_lr => switch (cs.text_orientation) {
            .mixed => .mixed,
            .upright => .upright,
            .sideways, .sideways_right => .sideways,
        },
    };
}

/// `TextStyle.combine` of text in style `cs`.
pub fn textCombine(cs: *const CS) bool {
    return cs.text_combine_upright == .all and textOrient(cs) != .none;
}

fn edgesT(comptime T: type, e: layout.Edges(T), vm: u2) layout.Edges(T) {
    return if (vm == 1)
        .{ .left = e.top, .top = e.right, .right = e.bottom, .bottom = e.left }
    else
        .{ .left = e.top, .top = e.left, .right = e.bottom, .bottom = e.right };
}

/// Logical edges of space `vm` back to physical ones (inverse of `edgesT`).
fn edgesP(e: layout.Edges(f32), vm: u2) layout.Edges(f32) {
    return if (vm == 1)
        .{ .top = e.left, .right = e.top, .bottom = e.right, .left = e.bottom }
    else
        .{ .top = e.left, .left = e.top, .bottom = e.right, .right = e.bottom };
}

/// The layout style of a box placed in a vertical space `vm` (1 or 2): sizes and edges in that
/// space's logical coordinates. Gaps, grid tracks, flex directions and alignment are logical in CSS
/// already; floats (`left` = line-left = top) too.
pub fn transpose(s: *layout.Style, vm: u2) void {
    if (vm == 0) return;
    std.mem.swap(layout.Dim, &s.size[0], &s.size[1]);
    std.mem.swap(layout.Dim, &s.min_size[0], &s.min_size[1]);
    std.mem.swap(layout.Dim, &s.max_size[0], &s.max_size[1]);
    if (s.aspect_ratio) |r| s.aspect_ratio = if (r > 0) 1 / r else r;
    std.mem.swap(layout.Overflow, &s.overflow_x, &s.overflow_y);
    s.margin = edgesT(layout.Dim, s.margin, vm);
    s.padding = edgesT(layout.LengthPercentage, s.padding, vm);
    s.border = edgesT(f32, s.border, vm);
    s.inset = edgesT(layout.Dim, s.inset, vm);
    if (@hasField(layout.Style, "border_hidden")) s.border_hidden = edgesT(bool, s.border_hidden, vm);
}

/// Writing mode of the space render node `id` is placed in (its parent's content).
pub fn spaceOf(f: *const Frame, id: u32) u2 {
    const p = f.nodes.items[id].parent;
    return if (p == none) 0 else vmOf(f.nodes.items[p].cs);
}

// ---- unsupported content: horizontal fallback

fn isVertical(cs: *const CS) bool {
    return cs.writing_mode != .horizontal_tb;
}

/// Content a vertical flow cannot hold (see the file comment).
fn unsupported(cs: *const CS, root_wm: WM) bool {
    if (cs.writing_mode == .sideways_lr) return true;
    if (cs.position == .absolute or cs.position == .fixed) return true;
    switch (cs.display) {
        .table, .inline_table, .table_row, .table_cell, .table_row_group, .table_header_group, .table_footer_group, .table_column, .table_column_group, .table_caption => return true,
        else => {},
    }
    // (one block direction per vertical flow)
    const rl = cs.writing_mode == .vertical_rl or cs.writing_mode == .sideways_rl;
    const root_rl = root_wm == .vertical_rl or root_wm == .sideways_rl;
    return rl != root_rl;
}

const Fallback = struct {
    f: *Frame,
    copies: std.AutoHashMapUnmanaged(usize, *const CS) = .empty,

    fn horizontal(x: *Fallback, cs: *const CS) render.Error!*const CS {
        if (!isVertical(cs)) return cs;
        const g = try x.copies.getOrPut(x.f.a, @intFromPtr(cs));
        if (!g.found_existing) {
            const c = try x.f.a.create(CS);
            c.* = cs.*;
            c.writing_mode = .horizontal_tb;
            g.value_ptr.* = c;
        }
        return g.value_ptr.*;
    }
};

/// Element `i`'s subtree in a vertical flow rooted at an element of writing mode `root_wm`: is all of
/// it supported? (Horizontal descendants are orthogonal flows of their own: their content is not
/// checked, except for vertical flows nested in them, which `fallback` checks separately.)
fn subtreeOk(f: *Frame, i: u32, root_wm: WM, stack: *std.ArrayList(u32)) render.Error!bool {
    stack.clearRetainingCapacity();
    try stack.append(f.a, i);
    while (stack.pop()) |e| {
        const el = f.dom.at(e);
        if (!isVertical(el.cs)) {
            // (an orthogonal flow inside: its own content is horizontal, but its box is placed in the
            // vertical flow)
            if (el.cs.position == .absolute or el.cs.position == .fixed) return false;
            continue;
        }
        if (unsupported(el.cs, root_wm)) return false;
        inline for (.{ el.before, el.after }) |pi| {
            if (pi != none and pi < f.pseudos.items.len) {
                const ps = f.pseudos.items[pi];
                if (unsupported(ps.cs, root_wm)) return false;
                if (ps.generated_el) |g| try stack.append(f.a, g);
            }
        }
        var c = el.first;
        while (c != none) : (c = f.dom.at(c).next) try stack.append(f.a, c);
    }
    return true;
}

/// Gives the vertical content of subtree `i` horizontal styles.
fn makeHorizontal(x: *Fallback, i: u32, stack: *std.ArrayList(u32)) render.Error!void {
    const f = x.f;
    stack.clearRetainingCapacity();
    try stack.append(f.a, i);
    while (stack.pop()) |e| {
        const el = f.dom.at(e);
        if (!isVertical(el.cs)) continue;
        el.cs = try x.horizontal(el.cs);
        inline for (.{ el.before, el.after }) |pi| {
            if (pi != none and pi < f.pseudos.items.len) {
                const ps = &f.pseudos.items[pi];
                ps.cs = try x.horizontal(ps.cs);
                if (ps.generated_el) |g| try stack.append(f.a, g);
            }
        }
        if (el.own != none and el.own < f.pseudos.items.len) {
            const ps = &f.pseudos.items[el.own];
            ps.cs = try x.horizontal(ps.cs);
        }
        var c = el.first;
        while (c != none) : (c = f.dom.at(c).next) try stack.append(f.a, c);
    }
}

/// CSS Writing Modes 4 §8 (principal writing mode): the `writing-mode` of an HTML document's `<body>`
/// is used for the root (and so the initial containing block) when the root has the initial one.
fn propagateBody(f: *Frame) !void {
    const root = f.dom.at(f.dom.root);
    if (isVertical(root.cs) or !std.ascii.eqlIgnoreCase(root.tag, "html")) return;
    var c = root.first;
    while (c != none) : (c = f.dom.at(c).next) {
        const el = f.dom.at(c);
        if (!std.ascii.eqlIgnoreCase(el.tag, "body")) continue;
        if (!isVertical(el.cs)) return;
        const cs = try f.a.create(CS);
        cs.* = root.cs.*;
        cs.writing_mode = el.cs.writing_mode;
        root.cs = cs;
        return;
    }
}

/// After the cascade: every vertical flow (a vertical element whose parent is horizontal, or the
/// root) holding content `unsupported` lists is laid out horizontally instead.
pub fn fallback(f: *Frame) render.Error!void {
    if (f.dom.root == none) return;
    propagateBody(f) catch return error.OutOfMemory;
    var x: Fallback = .{ .f = f };
    var walk: std.ArrayList(u32) = .empty;
    var scan: std.ArrayList(u32) = .empty;
    try walk.append(f.a, f.dom.root);
    while (walk.pop()) |e| {
        const el = f.dom.at(e);
        const parent_v = el.parent != none and isVertical(f.dom.at(el.parent).cs);
        if (isVertical(el.cs) and !parent_v) {
            if (!try subtreeOk(f, e, el.cs.writing_mode, &scan)) try makeHorizontal(&x, e, &scan);
        }
        var c = el.first;
        while (c != none) : (c = f.dom.at(c).next) try walk.append(f.a, c);
        inline for (.{ el.before, el.after }) |pi| {
            if (pi != none and pi < f.pseudos.items.len) if (f.pseudos.items[pi].generated_el) |g| try walk.append(f.a, g);
        }
    }
}

// ---- after layout

/// Maps the boxes laid out in vertical spaces to physical coordinates (parents before children:
/// a layout node's parent was added before it). A box in a `vertical-rl` space at logical (x, y)
/// sits at physical (W - y - h, x) of its parent (W: the parent's physical width); in a
/// `vertical-lr` space at (y, x), except inside an inline formatting context, whose lines were
/// mirrored (`mirrorLines`) and are turned like `vertical-rl`.
pub fn physicalize(f: *Frame) void {
    const t = &f.tree;
    const ns = t.nodes.items;
    for (ns, 0..) |*tn, lid| {
        const p = tn.parent;
        if (p == layout.tree.no_node or p >= f.lid_node.items.len) continue;
        const pid = f.lid_node.items[p];
        if (pid == none) continue;
        const pvm = vmOf(f.nodes.items[pid].cs);
        if (pvm == 0) continue;
        const pw = t.layouts.items[p].w;
        const l = &t.layouts.items[lid];
        const o = l.*;
        const turned = pvm == 1 or f.nodes.items[pid].kind == .anon_box;
        l.* = .{
            .x = if (turned) pw - o.y - o.h else o.y,
            .y = o.x,
            .w = o.h,
            .h = o.w,
            .content_w = o.content_h,
            .content_h = o.content_w,
            .padding = edgesP(o.padding, pvm),
            .border = edgesP(o.border, pvm),
            .margin = edgesP(o.margin, pvm),
            .baseline = std.math.nan(f32),
        };
    }
    // a vertical-rl root starts at the right edge of the viewport
    const rid = f.root;
    if (rid != none and f.nodes.items[rid].lid == f.lroot and vmOf(f.nodes.items[rid].cs) == 1) {
        if (f.opts.width) |w| {
            const l = &t.layouts.items[f.lroot];
            l.x = @as(f32, @floatFromInt(w)) - l.w - l.margin.right;
        }
    }
}

/// `vertical-lr`: moves every line of `tl` to the block position mirrored in [0, tl.height], so that
/// turning the layout like `vertical-rl` stacks the lines from left to right.
pub fn mirrorLines(tl: *font.TextLayout) void {
    const h = tl.height;
    for (tl.lines, 0..) |*ln, li| {
        const dy = h - 2 * ln.top - ln.height;
        ln.top += dy;
        ln.baseline += dy;
        const g1 = @min(ln.glyph_end, tl.glyphs.len);
        if (ln.glyph_start < g1) for (tl.glyphs[ln.glyph_start..g1]) |*g| {
            g.y += dy;
        };
        for (tl.segments) |*s| {
            if (s.line == li) s.baseline += dy;
        }
        for (tl.boxes) |*b| {
            if (b.line == li) b.baseline += dy;
        }
        for (tl.objects) |*o| {
            if (o.line == li) o.y += dy;
        }
    }
}

/// Content-box size of a laid-out node in its own logical space: [inline, block].
pub fn logicalContent(f: *const Frame, id: u32) [2]f32 {
    const n = &f.nodes.items[id];
    const l = f.tree.layout(n.lid);
    const cw = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
    const ch = l.h - l.border.top - l.border.bottom - l.padding.top - l.padding.bottom;
    return if (vmOf(n.cs) != 0) .{ ch, cw } else .{ cw, ch };
}

/// 2x3 affine (x' = a x + c y + e, y' = b x + d y + f), the layout of `raster.Affine`.
pub const Tf = struct { a: f32 = 1, b: f32 = 0, c: f32 = 0, d: f32 = 1, e: f32 = 0, f: f32 = 0 };

/// The transform from the line layout space of vertical paragraph node `id` (content box at `x`,
/// `y` physical, `cw` its physical content width) to the physical one: the lines turned 90 degrees
/// clockwise, the block start on the right (`vertical-rl`), or at the left for `vertical-lr`, whose
/// mirrored lines (`mirrorLines`) span `tl.height`.
pub fn lineTransform(f: *const Frame, id: u32, tl: *const font.TextLayout, x: f32, y: f32, cw: f32) Tf {
    const vm = vmOf(f.nodes.items[id].cs);
    const w = if (vm == 2) tl.height else cw;
    return .{ .a = 0, .b = 1, .c = -1, .d = 0, .e = x + w, .f = y };
}

/// Line-layout space origin of the upright glyph `g` (where its horizontal baseline origin goes)
/// when it is drawn turned back 90 degrees counter-clockwise (transform `uprightTf`): its em box is
/// centred on the line's central baseline, its vertical origin (`Font.verticalOriginY`) at the top
/// of its vertical advance.
pub fn uprightOrigin(f: *const Frame, g: *const font.PositionedGlyph) [2]f32 {
    if (g.combine > 0) return combineOrigin(f, g);
    const fnt = f.r.fonts.font(g.face);
    const upem: f32 = @floatFromInt(fnt.units_per_em);
    const s = g.size / upem;
    const lm = fnt.lineMetrics();
    const a = roundAway(@as(f32, @floatFromInt(lm.ascent)) * s);
    const d = roundAway(@as(f32, @floatFromInt(lm.descent)) * s);
    // Blink FontMetrics::FixedAscent(kCentralBaseline): height - height / 2 (LayoutUnit division)
    const hgt = a + d;
    const central = g.y - a + (hgt - @trunc(hgt * 32) / 64);
    const hadv = @as(f32, @floatFromInt(fnt.advanceWidth(g.gid))) * s;
    const vorg = @as(f32, @floatFromInt(fnt.verticalOriginY(g.gid))) * s;
    return .{ g.x + vorg, central + hadv / 2 };
}

/// `text-combine-upright` (`PositionedGlyph.combine`): the unit's em box centred in its one-em slot and on
/// the line's central baseline; `g.y` already holds the glyph's horizontal place in the unit.
fn combineOrigin(f: *const Frame, g: *const font.PositionedGlyph) [2]f32 {
    const fnt = f.r.fonts.font(g.face);
    const s = g.size / @as(f32, @floatFromInt(fnt.units_per_em));
    const lm = fnt.lineMetrics();
    const a = roundAway(@as(f32, @floatFromInt(lm.ascent)) * s);
    const d = roundAway(@as(f32, @floatFromInt(lm.descent)) * s);
    const hgt = a + d;
    return .{ g.x + (g.size - hgt) / 2 + a, g.y - a + (hgt - @trunc(hgt * 32) / 64) };
}

/// Glyph-space to line-layout-space transform of an upright glyph (see `uprightOrigin`); a combined
/// glyph is compressed horizontally by its unit's scale.
pub fn uprightTf(f: *const Frame, g: *const font.PositionedGlyph) Tf {
    const o = uprightOrigin(f, g);
    const sx: f32 = if (g.combine > 0) g.combine else 1;
    return .{ .a = 0, .b = -sx, .c = 1, .d = 0, .e = o[0], .f = o[1] };
}

inline fn roundAway(x: f32) f32 {
    return if (x >= 0) @floor(x + 0.5) else -@floor(0.5 - x);
}
