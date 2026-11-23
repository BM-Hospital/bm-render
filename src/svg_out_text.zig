//! SVG output of text (svg_out.zig), mirroring the raster text painter (paint_text.zig) and
//! takumi-svg (`text.rs`): glyph outlines are interned once in the trailing `<defs>` (glyph space:
//! origin at the pen position, fake italic skew baked in) and placed with `<use x y>` at the exact
//! layout position, grouped per run under one `fill`; fake bold adds a `stroke` of Skia's
//! fake-bold width in the fill colour; `-webkit-text-stroke` is a second, unfilled pass; text
//! shadows are the glyphs (plus stroke) in the shadow colour under a blur filter; decorations
//! follow the painter's geometry (rects, stroked dashes / dots, wavy cubic curves, skip-ink
//! cuts from the painter's glyph coverage); colour glyphs (COLR / bitmap) are embedded as PNG
//! images rendered by the painter's colour glyph code; inline span boxes reuse the box painters.
const std = @import("std");
const render = @import("render.zig");
const style = @import("style/style.zig");
const font = @import("font/font.zig");
const raster = @import("raster/raster.zig");
const codec = @import("codec/codec.zig");
const pm = @import("paint.zig");
const ptext = @import("paint_text.zig");
const pborder = @import("paint_border.zig");
const so = @import("svg_out.zig");
const sborder = @import("svg_out_border.zig");
const wmode = @import("writing_mode.zig");
const color = if (pm.enable_color_glyphs) @import("font/color.zig") else struct {};
const cex = if (pm.enable_color_glyphs) @import("font/color_example.zig") else struct {};

const S = so.S;
const Ctx = pm.Ctx;
const Node = render.Node;
const CS = render.CS;
const none = render.none;
const Rect = raster.Rect;
const Affine = raster.Affine;
const Path = raster.Path;
const Error = render.Error;
const Color = style.Color;

// ---- glyph definitions

/// Interned glyph outline id (`g<n>` in the trailing defs); null = empty outline.
noinline fn glyphDef(s: *S, face: font.FaceId, gid: u16, size: f32, italic: bool) Error!?u32 {
    const key: u64 = (@as(u64, @intFromBool(italic)) << 63) | (@as(u64, face & 0x7FFF) << 48) | (@as(u64, gid) << 32) | @as(u32, @bitCast(size));
    const gop = try s.glyph_ids.getOrPut(s.a, key);
    if (gop.found_existing) return if (gop.value_ptr.* == 0) null else gop.value_ptr.* - 1;
    gop.value_ptr.* = 0;
    const fnt = s.f.r.fonts.font(face);
    var path: Path = .empty;
    var sink: raster.PathSink = .{ .path = &path, .alloc = s.a, .transform = if (italic) .{ .c = -0.25 } else Affine.identity };
    _ = font.emitGlyph(fnt, gid, size, 0, 0, &sink);
    if (sink.err or path.isEmpty()) return null;
    const id = s.n_glyphs;
    s.n_glyphs += 1;
    const d = &s.defs;
    try d.appendSlice(s.a, "<path id=\"g");
    var tmp: [10]u8 = undefined;
    try d.appendSlice(s.a, decimal(&tmp, id));
    try d.appendSlice(s.a, "\" d=\"");
    try so.writePathTo(s.a, d, &path, Affine.identity);
    try d.appendSlice(s.a, "\"/>\n");
    gop.value_ptr.* = id + 1;
    return id;
}

fn decimal(buf: *[10]u8, v_in: u32) []const u8 {
    var k: usize = buf.len;
    var v = v_in;
    while (true) {
        k -= 1;
        buf[k] = @intCast('0' + v % 10);
        v /= 10;
        if (v == 0) break;
    }
    return buf[k..];
}

/// `<use href="#g<id>" x y` (left open for extra attributes).
fn useOpen(s: *S, id: u32, x: f32, y: f32) Error!void {
    s.raw("<use href=\"#g");
    s.uint(id);
    s.raw("\"");
    s.attrNum("x", so.qp(x));
    s.attrNum("y", so.qp(y));
}

/// `useOpen` for glyph `g` at (`x`, `y`); an upright glyph of vertical text is turned back against
/// its line's turn (writing_mode.zig).
fn useGlyph(s: *S, id: u32, g: *const font.PositionedGlyph, x: f32, y: f32) Error!void {
    if (!g.upright) return useOpen(s, id, x, y);
    const t = wmode.uprightTf(s.f, g);
    s.raw("<use href=\"#g");
    s.uint(id);
    s.raw("\"");
    s.attrMatrix(.{ .a = t.a, .b = t.b, .c = t.c, .d = t.d, .e = so.qp(t.e + x - g.x), .f = so.qp(t.f + y - g.y) });
}

// ---- painter mirrors

const Synth = struct { italic: bool, bold: bool, colored: bool };

fn synthOf(s: *S, rcs: *const CS, g: *const font.PositionedGlyph) Synth {
    const fc = s.f.r.fonts.face(g.face);
    var sy: Synth = .{ .italic = rcs.font_style != .normal and !fc.italic, .bold = rcs.font_weight >= 600 and fc.weight < 600, .colored = false };
    if (comptime pm.enable_color_glyphs) {
        const k = s.color_tables.get(g.face, &fc.font).kind(g.gid);
        // (bitmap-only builds draw COLR glyphs from their plain outlines)
        if (k == .bitmap_png or (pm.enable_color_fonts and k != .none)) sy = .{ .italic = false, .bold = false, .colored = true };
    }
    return sy;
}

fn runStyle(s: *S, n: *const Node, g: *const font.PositionedGlyph) *const CS {
    const rs = s.f.run_styles.items;
    return if (g.user < rs.len) rs[g.user] else n.cs;
}

const Metrics = struct { ascent: f32, descent: f32, ul_pos: f32, ul_thick: f32, em_descent: f32 };

fn metricsOf(s: *S, face: font.FaceId, size: f32) Metrics {
    const fnt = s.f.r.fonts.font(face);
    const sc = size / @as(f32, @floatFromInt(@max(1, fnt.unitsPerEm())));
    const lm = fnt.lineMetrics();
    const ta: f32 = @floatFromInt(fnt.typoAscender());
    const td: f32 = @floatFromInt(-@as(i32, fnt.typoDescender()));
    const a: f32 = @floatFromInt(lm.ascent);
    const d: f32 = @floatFromInt(lm.descent);
    return .{
        .ascent = @round(a * sc),
        .descent = @round(d * sc),
        .ul_pos = -@as(f32, @floatFromInt(fnt.underlinePosition())) * sc,
        .ul_thick = @as(f32, @floatFromInt(fnt.underlineThickness())) * sc,
        .em_descent = if (ta + td > 0) size * td / (ta + td) else if (a + d > 0) size * d / (a + d) else 0,
    };
}

fn hasLine(cs: *const CS) bool {
    const d = cs.text_decoration_line;
    return d.underline or d.overline or d.line_through;
}

// ---- glyph passes

/// Every glyph of `tl` (fill, optionally fake bold, text stroke) as `<use>`s in the current
/// fill (shadows: the shadow colour; `background-clip: text`: the mask colour).
noinline fn glyphUses(s: *S, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32, with_bold: bool) Error!void {
    for (tl.glyphs) |*g| {
        const rcs = runStyle(s, n, g);
        if (rcs.visibility != .visible) continue;
        const sy = synthOf(s, rcs, g);
        const id = (try glyphDef(s, g.face, g.gid, g.size, sy.italic)) orelse continue;
        try useGlyph(s, id, g, x + g.x, y + g.y);
        const sw = rcs.webkit_text_stroke_width;
        const bold_w: f32 = if (sy.bold and with_bold) ptext.emboldenWidth(g.size) else 0;
        const stroke_w = @max(bold_w, if (sw > 0 and !sy.colored) sw else 0);
        if (stroke_w > 0) {
            s.raw(" stroke=\"currentColor\"");
            s.attrNum("stroke-width", stroke_w);
        }
        s.raw("/>\n");
    }
}

noinline fn paintTextShadows(s: *S, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32, cw: f32) Error!void {
    const cs = n.cs;
    var i = cs.text_shadow.len;
    while (i > 0) {
        i -= 1;
        const sh = cs.text_shadow[i];
        const col = cs.resolveColor(sh.color);
        if (col.a == 0) continue;
        const sigma = sh.blur * 0.5;
        const blurred = sigma > 0.03;
        if (blurred) {
            const pad = cs.font_size + cs.webkit_text_stroke_width + 2;
            const area: Rect = .{ .x = x + sh.x - pad, .y = y + sh.y - pad, .w = @max(cw, tl.width) + 2 * pad, .h = tl.height + 2 * pad };
            const fid = try s.defBlur(sigma, area);
            s.raw("<g");
            s.attrRef("filter", fid);
            s.raw(">\n");
        }
        // the glyph coverage united (painter: one mask): opaque glyphs in a group carrying the alpha
        const opaque_col: Color = .{ .r = col.r, .g = col.g, .b = col.b, .a = 255 };
        s.raw("<g");
        s.attrColor("fill", "fill-opacity", opaque_col);
        s.attrColor("color", "opacity", opaque_col);
        if (col.a < 255) s.attrNum("opacity", @as(f32, @floatFromInt(col.a)) / 255.0);
        s.raw(">\n");
        try glyphUses(s, n, tl, x + sh.x, y + sh.y, false);
        s.closeG();
        if (blurred) s.closeG();
    }
}

/// Glyph shapes of node `id` and its descendants (fill, fake bold, text stroke) for the
/// `background-clip: text` mask (painter `textClipMask`).
pub noinline fn textClipShapes(s: *S, ctx: *const Ctx, id: u32, x: f32, y: f32) Error!void {
    _ = ctx;
    s.raw("<g fill=\"#000\" color=\"#000\">\n");
    try clipNode(s, id, x, y, 0);
    s.closeG();
}

fn clipNode(s: *S, id: u32, x: f32, y: f32, depth: u32) Error!void {
    const f = s.f;
    const n = &f.nodes.items[id];
    if (depth > 64 or (n.kind != .anon_text and n.cs.display == .none)) return;
    const l = f.tree.layout(n.lid);
    if (n.para != null) {
        const cw = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
        if (try f.textLayout(id, cw)) |tl| try glyphUses(s, n, tl, x + l.border.left + l.padding.left, y + l.border.top + l.padding.top, true);
    }
    var c = n.first_child;
    while (c != none) : (c = f.nodes.items[c].next) {
        const cl = f.tree.layout(f.nodes.items[c].lid);
        try clipNode(s, c, x + cl.x, y + cl.y, depth + 1);
    }
}

const RunSeg = struct { g0: u32, g1: u32, x0: f32, x1: f32, baseline: f32, rcs: *const CS };

noinline fn paintGlyphPhase(s: *S, tl: *const font.TextLayout, x: f32, y: f32, run: *const RunSeg, stroke_phase: bool) Error!void {
    const rcs = run.rcs;
    if (stroke_phase) {
        const sw = rcs.webkit_text_stroke_width;
        const scol = rcs.resolveColor(rcs.webkit_text_stroke_color);
        if (!(sw > 0) or scol.a == 0) return;
        s.raw("<g fill=\"none\"");
        s.attrColor("stroke", "stroke-opacity", scol);
        s.attrNum("stroke-width", sw);
        s.raw(">\n");
        for (tl.glyphs[run.g0..run.g1]) |*g| {
            const sy = synthOf(s, rcs, g);
            if (sy.colored) continue;
            const id = (try glyphDef(s, g.face, g.gid, g.size, sy.italic)) orelse continue;
            try useGlyph(s, id, g, x + g.x, y + g.y);
            s.raw("/>\n");
        }
        return s.closeG();
    }
    const fill = if (rcs.webkit_text_fill_color) |c| rcs.resolveColor(c) else rcs.color;
    if (fill.a == 0) return;
    s.raw("<g");
    s.attrColor("fill", "fill-opacity", fill);
    s.raw(">\n");
    for (tl.glyphs[run.g0..run.g1]) |*g| {
        const sy = synthOf(s, rcs, g);
        if (sy.colored) {
            try paintColorGlyph(s, g, x + g.x, y + g.y, fill);
            continue;
        }
        const id = (try glyphDef(s, g.face, g.gid, g.size, sy.italic)) orelse continue;
        try useGlyph(s, id, g, x + g.x, y + g.y);
        if (sy.bold) {
            s.attrColor("stroke", "stroke-opacity", fill);
            s.attrNum("stroke-width", ptext.emboldenWidth(g.size));
        }
        s.raw("/>\n");
    }
    s.closeG();
}

/// COLR / bitmap glyph: rendered like the painter (glyph-sized pixmap) and embedded as a PNG.
noinline fn paintColorGlyph(s: *S, g: *const font.PositionedGlyph, gx: f32, gy: f32, fg: Color) Error!void {
    if (comptime !pm.enable_color_glyphs) return;
    if (fg.a == 0 or !(g.size > 0) or g.size > 400) return;
    const fnt = s.f.r.fonts.font(g.face);
    const ct = color.ColorTables.init(fnt);
    const kind = ct.kind(g.gid);
    const ox: i32 = @intFromFloat(@ceil(g.size * 0.5) + 1);
    const oy: i32 = @intFromFloat(@ceil(g.size * 1.5) + 1);
    const w: u32 = @intCast(ox + @as(i32, @intFromFloat(@ceil(g.size * 2))) + 1);
    const h: u32 = @intCast(oy + @as(i32, @intFromFloat(@ceil(g.size * 0.75))) + 1);
    var pix = raster.Pixmap.init(s.a, w, h) catch return error.OutOfMemory;
    @memset(pix.data, 0);
    const fx: f32 = @floatFromInt(ox);
    const fy: f32 = @floatFromInt(oy);
    switch (kind) {
        .bitmap_png => if (ct.bitmap(g.gid, g.size)) |bm| {
            _ = cex.drawBitmapGlyph(s.a, &pix, bm, g.size, fx, fy, null) catch return error.OutOfMemory;
        },
        .colr_v0, .colr_v1 => if (comptime pm.enable_color_fonts) {
            _ = cex.drawColrGlyph(s.a, &pix, fnt, &ct, g.gid, g.size, fx, fy, 0, .{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 }, pix.bounds(), null) catch return error.OutOfMemory;
        },
        else => return,
    }
    const op: f32 = if (kind == .bitmap_png) 1 else @as(f32, @floatFromInt(fg.a)) / 255.0;
    const key = (@as(u64, g.face) << 48) ^ (@as(u64, g.gid) << 32) ^ @as(u32, @bitCast(g.size)) ^ (@as(u64, @as(u32, @bitCast([4]u8{ fg.r, fg.g, fg.b, 0 }))) << 7) ^ 0xC010_0000_0000_0000;
    const id = (try s.imageDefKeyed(&pix, null, key)) orelse return;
    if (op < 1) {
        s.raw("<g");
        s.attrNum("opacity", op);
        s.raw(">");
    }
    s.raw("<use href=\"#i");
    s.uint(id);
    s.raw("\"");
    s.attrMatrix(Affine.translate(gx - fx, gy - fy));
    s.raw("/>\n");
    if (op < 1) s.closeG();
}

// ---- decorations

const DecoKind = enum { underline, overline, line_through };
const Span = struct { a: f32, b: f32 };

/// Stroked centre line (`s.path`) with an optional dash, through an optional clip rect.
fn strokeLine(s: *S, width: f32, dash: ?pborder.Dash, col: Color, clip: ?Rect) Error!void {
    if (clip) |r| {
        const cid = try s.defClipRRect(r, null);
        s.raw("<g");
        s.attrRef("clip-path", cid);
        s.raw(">");
    }
    s.raw("<path");
    s.attrPath(&s.path, Affine.identity);
    s.raw(" fill=\"none\"");
    s.attrColor("stroke", "stroke-opacity", col);
    s.attrNum("stroke-width", width);
    if (dash) |d| {
        s.raw(" stroke-dasharray=\"");
        s.num(d.on);
        s.raw(" ");
        s.num(d.off);
        s.raw("\"");
        if (d.round) s.raw(" stroke-linecap=\"round\"");
    }
    s.raw("/>\n");
    if (clip != null) s.closeG();
}

noinline fn paintDecoLine(s: *S, kind: DecoKind, st: style.computed.DecorationStyle, col: Color, x0: f32, x1: f32, top: f32, thickness: f32, cuts: []const Span) Error!void {
    if (col.a == 0 or !(x1 > x0)) return;
    const h = @max(1, @floor(thickness));
    var pieces: [33]Span = undefined;
    var np: usize = 0;
    var cur = x0;
    for (cuts) |c| {
        if (np >= pieces.len - 1) break;
        if (c.a > cur) {
            pieces[np] = .{ .a = cur, .b = @min(c.a, x1) };
            np += 1;
        }
        cur = @max(cur, c.b);
        if (cur >= x1) break;
    }
    if (cur < x1) {
        pieces[np] = .{ .a = cur, .b = x1 };
        np += 1;
    }
    const second: f32 = switch (kind) {
        .underline => thickness + 1,
        .overline => -(thickness + 1),
        .line_through => @floor(thickness + 1),
    };
    const a = s.a;
    switch (st) {
        .solid, .double => for (pieces[0..np]) |pc| {
            try s.fillRRect(.{ .x = pc.a, .y = @floor(top + 0.5), .w = pc.b - pc.a, .h = h }, null, col);
            if (st == .double) try s.fillRRect(.{ .x = pc.a, .y = @floor(top + second + 0.5), .w = pc.b - pc.a, .h = h }, null, col);
        },
        .dotted, .dashed => {
            const start = @floor(x0);
            const end = @floor(x1);
            const row = @floor(top + @max(thickness / 2, 0.5));
            const t = @max(1, @round(thickness));
            const yl = if (@mod(t, 2) == 1) row + 0.5 else row;
            const dash = pborder.dashPattern(if (st == .dotted) .dotted else .dashed, t, end - start, false);
            var la = start;
            var lb = end;
            if (dash != null and dash.?.round) {
                la += t / 2;
                lb -= t / 2;
            }
            if (!(lb > la)) return;
            s.path.reset();
            s.path.moveTo(a, la, yl) catch return error.OutOfMemory;
            s.path.lineTo(a, lb, yl) catch return error.OutOfMemory;
            if (cuts.len == 0) return strokeLine(s, t, dash, col, null);
            for (pieces[0..np]) |pc| try strokeLine(s, t, dash, col, .{ .x = pc.a, .y = yl - t / 2 - 1, .w = pc.b - pc.a, .h = t + 2 });
        },
        .wavy => {
            const t = @max(thickness, 1);
            const wl = 1 + 2 * @round(2 * t + 0.5);
            const cpd = 0.5 + @round(3 * t + 0.5);
            const wavy_off: f32 = switch (kind) {
                .underline => thickness + 1,
                .overline => -(thickness + 1),
                .line_through => 0,
            };
            const yy = top + wavy_off + 0.5;
            const reach = cpd / (2 * @sqrt(3.0)) + thickness / 2;
            const mid = top + wavy_off;
            const ctop = mid + @floor(0.5 - reach);
            const cbot = mid + @ceil(0.5 + reach);
            s.path.reset();
            var xx = x0 - wl;
            s.path.moveTo(a, xx, yy) catch return error.OutOfMemory;
            var guard: u32 = 0;
            while (xx < x1 + wl and guard < 20000) : (guard += 1) {
                s.path.cubicTo(a, xx + wl / 2, yy + cpd, xx + wl / 2, yy - cpd, xx + wl, yy) catch return error.OutOfMemory;
                xx += wl;
            }
            for (pieces[0..np]) |pc| try strokeLine(s, thickness, null, col, .{ .x = pc.a, .y = ctop, .w = pc.b - pc.a, .h = cbot - ctop });
        },
    }
}

noinline fn paintRunDecos(s: *S, ctx: *const Ctx, tl: *const font.TextLayout, x: f32, y: f32, run: *const RunSeg, decos: []const *const CS, after: bool) Error!void {
    const g0 = &tl.glyphs[run.g0];
    const tm = metricsOf(s, g0.face, g0.size);
    const text_top = y + run.baseline - tm.ascent;
    for (decos) |dcs| {
        const dl = dcs.text_decoration_line;
        const col = dcs.resolveColor(dcs.text_decoration_color);
        const dm = metricsOf(s, g0.face, dcs.font_size);
        const auto = dcs.font_size / 10.0;
        const thickness = @max(1, if (dcs.text_decoration_thickness) |v| @round(v) else auto);
        const box_top = y + run.baseline - dm.ascent;
        const off = if (dcs.text_underline_offset) |o| o else 0;
        const lx0 = x + run.x0;
        const lx1 = x + run.x1;
        if (after) {
            if (dl.line_through) try paintDecoLine(s, .line_through, dcs.text_decoration_style, col, lx0, lx1, text_top + 2 * dm.ascent / 3 - thickness / 2, thickness, &.{});
            continue;
        }
        inline for (.{ DecoKind.underline, DecoKind.overline }) |kind| {
            if (if (kind == .underline) dl.underline else dl.overline) {
                var top: f32 = undefined;
                if (kind == .overline) {
                    top = text_top - @floor(thickness);
                } else if (dcs.text_underline_position.under) {
                    top = box_top + @floor(@round((dm.ascent + dm.em_descent) * 64) / 64 + @round(off * 64) / 64) + 1;
                } else if (dcs.text_underline_position.from_font and dm.ul_thick > 0) {
                    top = box_top + @round(dm.ascent + dm.ul_pos + off);
                } else {
                    const gap: f32 = if (dcs.text_underline_offset != null) 0 else @max(1, @ceil(thickness / 2));
                    top = box_top + @trunc(dm.ascent + gap + @round(off));
                }
                var cuts: [32]Span = undefined;
                var nc: usize = 0;
                if (dcs.text_decoration_skip_ink != .none and ctx.plain()) nc = skipInk(s, tl, x, y, run, top, thickness, dcs.text_decoration_style, kind == .underline, &cuts);
                try paintDecoLine(s, kind, dcs.text_decoration_style, col, lx0, lx1, top, thickness, cuts[0..nc]);
            }
        }
    }
}

/// Ink intercepts of the run's glyphs with the decoration band, from the painter's glyph
/// coverage masks (paint_text.zig `skipInk`).
fn skipInk(s: *S, tl: *const font.TextLayout, x: f32, y: f32, run: *const RunSeg, top: f32, thickness: f32, st: style.computed.DecorationStyle, underline: bool, out: *[32]Span) usize {
    const pctx: Ctx = .{ .dst = &s.dummy };
    var b0 = @floor(top + 0.5);
    var b1 = b0 + thickness;
    if (st == .double) {
        if (underline) b1 += thickness + 1 else b0 -= thickness + 1;
    } else if (st == .wavy) {
        const cpd = 0.5 + @round(3 * @max(thickness, 1) + 0.5);
        const reach = cpd / (2 * @sqrt(3.0)) + thickness / 2;
        const mid = top + (if (underline) thickness + 1 else -(thickness + 1));
        b0 = mid + @floor(0.5 - reach);
        b1 = mid + @ceil(0.5 + reach);
    }
    b0 += 0.5;
    b1 -= 0.5;
    if (!(b1 - b0 > 1)) return 0;
    const r0: i64 = @intFromFloat(std.math.clamp(@floor(b0), -1.0e6, 1.0e6));
    const r1: i64 = @intFromFloat(std.math.clamp(@ceil(b1), -1.0e6, 1.0e6));
    const grow = @min(thickness, 13);
    var nc: usize = 0;
    for (tl.glyphs[run.g0..run.g1]) |*g| {
        const sy = synthOf(s, run.rcs, g);
        if (sy.colored) continue;
        const m = ptext.glyphPassMask(&s.p, &pctx, g, x + g.x, y + g.y, sy.italic, .fill, 0) orelse continue;
        const mb = m.bounds;
        var lo: i64 = std.math.maxInt(i64);
        var hi: i64 = std.math.minInt(i64);
        const row_end = @min(r1, mb.bottom());
        var xx: u32 = 0;
        while (xx < mb.w) : (xx += 1) {
            var ink = false;
            var row = @max(r0, @as(i64, mb.y));
            while (row < row_end) : (row += 1) {
                if (m.data[@as(usize, @intCast(row - mb.y)) * mb.w + xx] != 0) {
                    ink = true;
                    break;
                }
            }
            const col: i64 = @as(i64, mb.x) + xx;
            if (ink) {
                if (lo > hi) lo = col;
                hi = col;
            }
            if ((!ink or xx + 1 == mb.w) and lo <= hi) {
                const a = @floor(@as(f32, @floatFromInt(lo)) - grow + 0.5);
                const b = @floor(@as(f32, @floatFromInt(hi + 1)) + grow + 0.5);
                if (nc > 0 and a <= out[nc - 1].b) {
                    out[nc - 1].b = @max(out[nc - 1].b, b);
                } else if (nc < out.len) {
                    out[nc] = .{ .a = a, .b = b };
                    nc += 1;
                }
                lo = std.math.maxInt(i64);
                hi = std.math.minInt(i64);
            }
        }
    }
    return nc;
}

// ---- inline box decorations (painter `paintInlineBoxes`)

fn isInlineBox(cs: *const CS) bool {
    if (cs.resolveColor(cs.background_color).a != 0) return true;
    if (cs.background_image.len > 0) return true;
    const bw = cs.usedBorderWidths();
    return bw[0] > 0 or bw[1] > 0 or bw[2] > 0 or bw[3] > 0;
}


noinline fn paintInlineBoxes(s: *S, ctx: *const Ctx, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32) Error!void {
    const f = s.f;
    for (tl.boxes) |*fr| {
        const fi = f.boxFragment(n, fr) orelse continue;
        if (!isInlineBox(fi.cs)) continue;
        try paintFragment(s, ctx, fi.cs, fr.face, fi.x0, fi.x1, fr.baseline, fi.left, fi.right, x, y);
    }
}

noinline fn paintFragment(s: *S, ctx: *const Ctx, cs: *const CS, face: font.FaceId, x0: f32, x1: f32, baseline: f32, first: bool, last: bool, x: f32, y: f32) Error!void {
    const m = metricsOf(s, face, cs.font_size);
    var bw = cs.usedBorderWidths();
    const fs = cs.font_size;
    var pad = [4]f32{ cs.padding[0].resolve(fs), cs.padding[1].resolve(fs), cs.padding[2].resolve(fs), cs.padding[3].resolve(fs) };
    if (!first) {
        bw[3] = 0;
        pad[3] = 0;
    }
    if (!last) {
        bw[1] = 0;
        pad[1] = 0;
    }
    const fx = x + x0 - pad[3] - bw[3];
    const fy = y + baseline - m.ascent - pad[0] - bw[0];
    const fw = (x1 - x0) + pad[3] + bw[3] + pad[1] + bw[1];
    const fh = m.ascent + m.descent + pad[0] + bw[0] + pad[2] + bw[2];
    var g: pm.Geom = .{
        .bx = if (ctx.plain()) pm.snapRect(fx, fy, fw, fh) else .{ .x = fx, .y = fy, .w = fw, .h = fh },
        .bw = bw,
        .pad = pad,
        .radii = undefined,
        .rounded = false,
        .snapped = ctx.plain(),
    };
    g.radii = pm.resolveRadiiRaw(cs, g.bx.w, g.bx.h);
    if (!first) {
        g.radii[0] = .{ 0, 0 };
        g.radii[3] = .{ 0, 0 };
    }
    if (!last) {
        g.radii[1] = .{ 0, 0 };
        g.radii[2] = .{ 0, 0 };
    }
    pm.scaleRadii(&g.radii, g.bx.w, g.bx.h);
    g.rounded = pm.hasAnyRadius(g.radii);
    const col = cs.resolveColor(cs.background_color);
    if (col.a != 0) try s.fillRRect(g.bx, g.outerRadii(), col);
    var i = cs.background_image.len;
    while (i > 0) {
        i -= 1;
        const layer = cs.bgLayer(i);
        if (layer.image == .none or layer.clip == .text) continue;
        try s.paintBgLayer(cs, &g, &layer, true);
    }
    try sborder.paintBorder(s, cs, &g);
}

// ---- paragraphs

/// A text node's paragraph at content origin (`x`, `y`) laid out at width `cw` (painter
/// `paintText`): inline boxes, shadows, then per run: underline / overline, fill, stroke,
/// line-through.
pub noinline fn paintText(s: *S, ctx: *const Ctx, n: *const Node, x: f32, y: f32, cw: f32) Error!void {
    const f = s.f;
    if (wmode.vmOf(n.cs) != 0) {
        // vertical text: the logical lines in a group turned 90 degrees clockwise
        const id = f.nodeId(n);
        const tl = (try f.textLayout(id, cw)) orelse return;
        const t = wmode.lineTransform(f, id, tl, x, y, cw);
        const m: Affine = .{ .a = t.a, .b = t.b, .c = t.c, .d = t.d, .e = t.e, .f = t.f };
        var vc = ctx.*;
        vc.tf = ctx.tf.mul(m);
        s.gTransform(m);
        try paintLines(s, &vc, n, tl, 0, 0, wmode.logicalContent(f, id)[0]);
        return s.closeG();
    }
    const tl = (try f.textLayout(f.nodeId(n), cw)) orelse return;
    return paintLines(s, ctx, n, tl, x, y, cw);
}

noinline fn paintLines(s: *S, ctx: *const Ctx, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32, cw: f32) Error!void {
    const f = s.f;
    if (tl.boxes.len > 0) try paintInlineBoxes(s, ctx, n, tl, x, y);
    if (n.cs.text_shadow.len > 0 and n.cs.visibility == .visible) try paintTextShadows(s, n, tl, x, y, cw);

    var block_deco: ?*const CS = null;
    if (hasLine(n.cs)) {
        block_deco = n.cs;
    } else if (n.parent != none and (n.kind == .text or n.kind == .anon_text)) {
        const pcs = f.nodes.items[n.parent].cs;
        if (hasLine(pcs)) block_deco = pcs;
    }

    {
        var it: render.RunIter = .{ .tl = tl };
        while (it.next()) |r| {
            const rcs = runStyle(s, n, &tl.glyphs[r.g0]);
            const run: RunSeg = .{ .g0 = r.g0, .g1 = r.g1, .x0 = r.x0, .x1 = r.x1, .baseline = r.baseline, .rcs = rcs };
            if (rcs.visibility != .visible) continue;
            var decos: [2]*const CS = undefined;
            var nd: usize = 0;
            if (block_deco) |d| {
                decos[nd] = d;
                nd += 1;
            }
            if (rcs != n.cs and (block_deco == null or rcs != block_deco.?) and hasLine(rcs)) {
                decos[nd] = rcs;
                nd += 1;
            }
            if (nd > 0) try paintRunDecos(s, ctx, tl, x, y, &run, decos[0..nd], false);
            try paintGlyphPhase(s, tl, x, y, &run, false);
            try paintGlyphPhase(s, tl, x, y, &run, true);
            if (nd > 0) try paintRunDecos(s, ctx, tl, x, y, &run, decos[0..nd], true);
        }
    }
}
