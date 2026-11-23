//! Text painting for the painter (`paint.zig`), mirroring takumi (takumi-raster `text_drawing.rs`,
//! takumi-core `painter/text.rs`, `painter/decoration.rs`):
//! * glyph masks: origin snapped to 1/4 px along the baseline and whole px across it
//!   (`GlyphBucket`), tiny-skia compatible AA, cached per phase for untransformed text;
//! * fake bold = the fill mask plus a second mask of the outline stroked at Skia's fake-bold
//!   width, both drawn source-over; fake italic = skew baked into the outline;
//! * `-webkit-text-stroke` / `paint-order` / `-webkit-text-fill-color`;
//! * decorations per shaped run (thickness / offsets as Blink, solid / double / dotted / dashed /
//!   wavy, skip-ink), text shadows, `background-clip: text` coverage, colour glyphs, and the
//!   box decorations of inline spans.
const std = @import("std");
const render = @import("render.zig");
const style = @import("style/style.zig");
const font = @import("font/font.zig");
const raster = @import("raster/raster.zig");
const pm = @import("paint.zig");
const pborder = @import("paint_border.zig");
const color = if (pm.enable_color_glyphs) @import("font/color.zig") else struct {};
const cex = if (pm.enable_color_glyphs) @import("font/color_example.zig") else struct {};

const Painter = pm.Painter;
const Ctx = pm.Ctx;
const Node = render.Node;
const CS = render.CS;
const none = render.none;
const Rect = raster.Rect;
const IRect = raster.IRect;
const Affine = raster.Affine;
const Paint = raster.Paint;
const Pixmap = raster.Pixmap;
const Error = render.Error;
const rcolor = pm.rcolor;

/// Builds the outline of a glyph in glyph space (origin at the pen position, y down, font size
/// applied, fake italic skew baked in) into `p.path`.
fn buildGlyph(p: *Painter, face: font.FaceId, gid: u16, size: f32, italic: bool) bool {
    const fnt = p.f.r.fonts.font(face);
    p.path.reset();
    var sink: raster.PathSink = .{ .path = &p.path, .alloc = p.a, .transform = if (italic) .{ .c = -0.25 } else Affine.identity };
    _ = font.emitGlyph(fnt, gid, size, 0, 0, &sink);
    return !sink.err;
}

/// Skia's fake-bold stroke width (takumi `synthesis_embolden_strength`).
pub fn emboldenWidth(size: f32) f32 {
    const t = std.math.clamp((size - 9) / 27, 0, 1);
    return size * (1.0 / 24.0 + t * (1.0 / 32.0 - 1.0 / 24.0));
}

/// Coverage mask of a glyph outline (`stroke` == 0) or of a centred stroke of width `stroke`
/// (glyph-space units) around it, drawn under `m`; tiny-skia compatible AA.
noinline fn glyphCoverage(p: *Painter, out: std.mem.Allocator, face: font.FaceId, gid: u16, size: f32, italic: bool, stroke: f32, m: Affine, window: IRect) ?raster.Mask {
    if (!buildGlyph(p, face, gid, size, italic)) return null;
    if (!(stroke > 0)) return p.rast().rasterizeSkia(out, &p.path, m, .nonzero, window) catch null;
    p.path2.reset();
    raster.strokePath(p.a, &p.path, .{ .width = stroke, .scale = Painter.tfScale(m) }, &p.path2) catch return null;
    return p.rast().rasterizeSkia(out, &p.path2, m, .nonzero, window) catch null;
}

/// takumi `GlyphBucket`: the glyph origin snapped to 1/4 px along the baseline and whole pixels
/// across it; `m` keeps the fractional part, (`ox`, `oy`) the whole pixels.
const Bucket = struct { m: Affine, ox: i32, oy: i32, sx: u2, sy: u2 };

fn splitSub(v: f32, steps: f32, whole: *i32, sub: *u2) f32 {
    const scaled = @round(v * steps);
    const w = @floor(scaled / steps);
    whole.* = @intFromFloat(w);
    const rem = scaled - w * steps;
    sub.* = @intFromFloat(std.math.clamp(rem, 0, 3));
    return rem / steps;
}

fn bucketOf(tf: Affine) ?Bucket {
    if (!(@abs(tf.e) < 1.0e6) or !(@abs(tf.f) < 1.0e6)) return null;
    var bk: Bucket = .{ .m = tf, .ox = 0, .oy = 0, .sx = 0, .sy = 0 };
    const xs: f32 = if (tf.b == 0 or tf.a != 0) 4 else 1;
    const ys: f32 = if (tf.b == 0) 1 else 4;
    bk.m.e = splitSub(tf.e, xs, &bk.ox, &bk.sx);
    bk.m.f = splitSub(tf.f, ys, &bk.oy, &bk.sy);
    return bk;
}

/// Cached mask of a glyph at an untransformed quarter-pixel phase. `synth` bit0 = fake italic,
/// bit1 = the fake-bold stroke mask (drawn on top of the plain fill, as takumi does).
noinline fn glyphMask(p: *Painter, face: font.FaceId, gid: u16, size: f32, sub: u2, synth: u2) ?render.GlyphMask {
    const r = p.f.r;
    // (u128: variable-font instance ids are >= 0x8000 and must not collide)
    const key: u128 = (@as(u128, synth) << 66) | (@as(u128, face) << 50) | (@as(u128, gid) << 34) | (@as(u128, sub) << 32) | @as(u32, @bitCast(size));
    if (r.glyphs.get(key)) |gm| return gm;
    const big: IRect = .{ .x = -8192, .y = -8192, .w = 16384, .h = 16384 };
    const stroke: f32 = if (synth & 2 != 0) emboldenWidth(size) else 0;
    const m = glyphCoverage(p, r.gpa, face, gid, size, synth & 1 != 0, stroke, Affine.translate(@as(f32, @floatFromInt(sub)) * 0.25, 0), big) orelse return null;
    const gm: render.GlyphMask = .{ .x = m.bounds.x, .y = m.bounds.y, .w = m.bounds.w, .h = m.bounds.h, .data = m.data };
    r.glyphs.put(r.gpa, key, gm) catch {
        if (m.data.len > 0) r.gpa.free(m.data);
        return null;
    };
    r.glyph_bytes += m.data.len + 48;
    return gm;
}

pub const Pass = enum(u2) { fill = 0, embolden = 1, stroke = 2 };

/// One glyph coverage mask in device space: the fill, the fake-bold stroke, or an arbitrary
/// centred stroke of width `stroke`. Untransformed fills / fake-bold strokes come from the
/// renderer's glyph cache; everything else is rasterized into the arena.
pub noinline fn glyphPassMask(p: *Painter, ctx: *const Ctx, g: *const font.PositionedGlyph, gx: f32, gy: f32, italic: bool, pass: Pass, stroke: f32) ?raster.Mask {
    const bk = bucketOf(ctx.tf.mul(Affine.translate(gx, gy))) orelse return null;
    if (ctx.plain() and g.size <= 400 and pass != .stroke) {
        const synth: u2 = @as(u2, @intFromBool(italic)) | (@as(u2, @intFromEnum(pass)) << 1);
        const gm = glyphMask(p, g.face, g.gid, g.size, bk.sx, synth) orelse return null;
        if (gm.w == 0 or gm.h == 0) return null;
        return .{ .bounds = .{ .x = gm.x + bk.ox, .y = gm.y + bk.oy, .w = gm.w, .h = gm.h }, .data = gm.data };
    }
    const reg = Painter.region(ctx);
    const win: IRect = .{ .x = reg.x -| bk.ox, .y = reg.y -| bk.oy, .w = reg.w, .h = reg.h };
    const sw = if (pass == .embolden) emboldenWidth(g.size) else stroke;
    var m = glyphCoverage(p, p.a, g.face, g.gid, g.size, italic, if (pass == .fill) 0 else sw, bk.m, win) orelse return null;
    if (m.bounds.isEmpty()) return null;
    m.bounds.x +|= bk.ox;
    m.bounds.y +|= bk.oy;
    return m;
}

/// takumi 2.20.0 (the oracle) always paints the text stroke after the fill, whatever `paint-order`
/// says (its current source honours it): set to true for the CSS behaviour.
const honor_paint_order = false;

const Synth = struct { italic: bool, bold: bool, colored: bool };

fn synthOf(p: *Painter, rcs: *const CS, g: *const font.PositionedGlyph) Synth {
    const fc = p.f.r.fonts.face(g.face);
    var s: Synth = .{ .italic = rcs.font_style != .normal and !fc.italic, .bold = rcs.font_weight >= 600 and fc.weight < 600, .colored = false };
    if (comptime pm.enable_color_glyphs) {
        // (the face's colour tables are cached: reading the table directory for every glyph
        // was a quarter of the render time of long text)
        const k = p.color_tables.get(g.face, &fc.font).kind(g.gid);
        // (bitmap-only builds draw COLR glyphs from their plain outlines)
        if (k == .bitmap_png or (pm.enable_color_fonts and k != .none)) s = .{ .italic = false, .bold = false, .colored = true };
    }
    return s;
}

fn runStyle(p: *Painter, n: *const Node, g: *const font.PositionedGlyph) *const CS {
    const rs = p.f.run_styles.items;
    return if (g.user < rs.len) rs[g.user] else n.cs;
}

/// acc = acc ∪ m (`a + b - a*b/255`, takumi's coverage union).
fn unionMask(acc: *raster.Mask, m: *const raster.Mask) void {
    const b = m.bounds.intersect(acc.bounds);
    if (b.isEmpty()) return;
    var yy: u32 = 0;
    while (yy < b.h) : (yy += 1) {
        const ar: usize = @intCast(@as(i64, b.y) + yy - acc.bounds.y);
        const ac: usize = @intCast(@as(i64, b.x) - acc.bounds.x);
        const mr: usize = @intCast(@as(i64, b.y) + yy - m.bounds.y);
        const mc: usize = @intCast(@as(i64, b.x) - m.bounds.x);
        const drow = acc.data[ar * acc.bounds.w + ac ..][0..b.w];
        const srow = m.data[mr * m.bounds.w + mc ..][0..b.w];
        for (drow, srow) |*dv, sv| {
            if (sv == 0) continue;
            const d: u32 = dv.*;
            dv.* = @intCast(d + sv - raster.div255(d * sv));
        }
    }
}

/// Adds the coverage of every glyph of `tl` (fill, optionally fake bold, text stroke) to `mask`.
fn addGlyphs(p: *Painter, ctx: *const Ctx, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32, mask: *raster.Mask, with_bold: bool) void {
    for (tl.glyphs) |*g| {
        const rcs = runStyle(p, n, g);
        if (rcs.visibility != .visible) continue;
        const sy = synthOf(p, rcs, g);
        if (glyphPassMask(p, ctx, g, x + g.x, y + g.y, sy.italic, .fill, 0)) |one| unionMask(mask, &one);
        if (sy.bold and with_bold) {
            if (glyphPassMask(p, ctx, g, x + g.x, y + g.y, sy.italic, .embolden, 0)) |one| unionMask(mask, &one);
        }
        if (rcs.webkit_text_stroke_width > 0 and !sy.colored) {
            if (glyphPassMask(p, ctx, g, x + g.x, y + g.y, sy.italic, .stroke, rcs.webkit_text_stroke_width)) |one| unionMask(mask, &one);
        }
    }
}

/// text-shadow: the glyph coverage of the paragraph united into one A8 mask, blurred and filled
/// (last shadow first). Fake bold is not part of the shadow (as in takumi).
noinline fn paintTextShadows(p: *Painter, ctx: *const Ctx, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32, cw: f32) Error!void {
    const cs = n.cs;
    const vis = Painter.region(ctx);
    if (vis.isEmpty()) return;
    const scale = Painter.tfScale(ctx.tf);
    var i = cs.text_shadow.len;
    while (i > 0) {
        i -= 1;
        const sh = cs.text_shadow[i];
        const col = cs.resolveColor(sh.color);
        if (col.a == 0) continue;
        const sigma = sh.blur * 0.5 * scale;
        const reach = raster.blurReach(sigma);
        const pad = cs.font_size + cs.webkit_text_stroke_width + 2;
        const sarea: Rect = .{ .x = x + sh.x - pad, .y = y + sh.y - pad, .w = @max(cw, tl.width) + 2 * pad, .h = tl.height + 2 * pad };
        const b = Painter.devBounds(ctx.tf, sarea).intersect(vis.expand(reach));
        if (b.isEmpty()) continue;
        var mask = raster.Mask.init(p.a, b) catch return error.OutOfMemory;
        @memset(mask.data, 0);
        addGlyphs(p, ctx, n, tl, x + sh.x, y + sh.y, &mask, false);
        raster.blurMaskClipped(p.a, &mask, sigma, vis) catch return error.OutOfMemory;
        raster.fillMask(ctx.dst, &mask, &.{ .solid = rcolor(col) }, ctx.clip);
    }
}

/// `background-clip: text` coverage of node `id` (border box origin x, y) and its descendants
/// within `reg`: glyph fills, fake bold and text strokes.
pub noinline fn textClipMask(p: *Painter, ctx: *const Ctx, id: u32, x: f32, y: f32, reg: IRect) Error!raster.Mask {
    var mask = raster.Mask.init(p.a, reg) catch return error.OutOfMemory;
    @memset(mask.data, 0);
    try clipMaskNode(p, ctx, id, x, y, &mask, 0);
    return mask;
}

fn clipMaskNode(p: *Painter, ctx: *const Ctx, id: u32, x: f32, y: f32, mask: *raster.Mask, depth: u32) Error!void {
    const f = p.f;
    const n = &f.nodes.items[id];
    if (depth > 64 or (n.kind != .anon_text and n.cs.display == .none)) return;
    const l = f.tree.layout(n.lid);
    if (n.para != null) {
        const cw = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
        if (try f.textLayout(id, cw)) |tl| addGlyphs(p, ctx, n, tl, x + l.border.left + l.padding.left, y + l.border.top + l.padding.top, mask, true);
    }
    var c = n.first_child;
    while (c != none) : (c = f.nodes.items[c].next) {
        const cl = f.tree.layout(f.nodes.items[c].lid);
        try clipMaskNode(p, ctx, c, x + cl.x, y + cl.y, mask, depth + 1);
    }
}

// ---- colour glyphs

/// COLR / bitmap glyph: rendered once per (face, gid, size, foreground) into a glyph-sized
/// offscreen kept in the renderer's colour-glyph cache (`Renderer.color_glyphs`, counted against
/// the glyph budget and dropped with the glyph masks), then composited (never emboldened or skewed).
noinline fn paintColorGlyph(p: *Painter, ctx: *const Ctx, g: *const font.PositionedGlyph, gx: f32, gy: f32, fg: style.Color) Error!void {
    if (comptime !pm.enable_color_glyphs) return;
    if (fg.a == 0 or !(g.size > 0) or g.size > 400) return;
    const fgbits: u32 = @as(u32, fg.r) | (@as(u32, fg.g) << 8) | (@as(u32, fg.b) << 16) | (@as(u32, fg.a) << 24);
    const r = p.f.r;
    const fnt = r.fonts.font(g.face);
    const ct = color.ColorTables.init(fnt);
    const kind = ct.kind(g.gid);
    const is_bitmap = kind == .bitmap_png;
    // key: glyph and size; the foreground only matters to COLR glyphs (an odd multiplier keeps
    // distinct foregrounds of one glyph apart)
    var key: u64 = (@as(u64, g.face) << 48) | (@as(u64, g.gid) << 32) | @as(u32, @bitCast(g.size));
    if (!is_bitmap) key ^= @as(u64, fgbits | 0xFF000000) *% 0x9E3779B97F4A7C15;
    var cg: render.ColorGlyphEntry = undefined;
    if (r.color_glyphs.get(key)) |e| {
        cg = e;
    } else {
        // box around the origin: x in [-0.5, 2] em, y in [-1.5, 0.75] em
        const ox: i32 = @intFromFloat(@ceil(g.size * 0.5) + 1);
        const oy: i32 = @intFromFloat(@ceil(g.size * 1.5) + 1);
        const w: u32 = @intCast(ox + @as(i32, @intFromFloat(@ceil(g.size * 2))) + 1);
        const h: u32 = @intCast(oy + @as(i32, @intFromFloat(@ceil(g.size * 0.75))) + 1);
        var pix = Pixmap.init(r.gpa, w, h) catch return error.OutOfMemory;
        errdefer pix.deinit(r.gpa);
        @memset(pix.data, 0);
        const fx: f32 = @floatFromInt(ox);
        const fy: f32 = @floatFromInt(oy);
        switch (kind) {
            .bitmap_png => if (ct.bitmap(g.gid, g.size)) |bm| {
                _ = cex.drawBitmapGlyph(p.a, &pix, bm, g.size, fx, fy, null) catch return error.OutOfMemory;
            },
            .colr_v0, .colr_v1 => if (comptime pm.enable_color_fonts) {
                _ = cex.drawColrGlyph(p.a, &pix, fnt, &ct, g.gid, g.size, fx, fy, 0, .{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 }, pix.bounds(), null) catch return error.OutOfMemory;
            },
            else => {},
        }
        cg = .{ .pix = pix, .ox = ox, .oy = oy };
        r.color_glyphs.put(r.gpa, key, cg) catch return error.OutOfMemory;
        r.color_glyph_bytes += pix.data.len;
    }
    const op: f32 = if (is_bitmap) 1 else @as(f32, @floatFromInt(fg.a)) / 255.0;
    var m = ctx.tf.mul(Affine.translate(gx - @as(f32, @floatFromInt(cg.ox)), gy - @as(f32, @floatFromInt(cg.oy))));
    if (ctx.plain()) {
        m.e = @round(m.e);
        m.f = @round(m.f);
    }
    raster.drawPixmap(ctx.dst, &cg.pix, m, op, if (ctx.plain()) .nearest else .bilinear, ctx.clip);
}

// ---- decorations

const DecoKind = enum { underline, overline, line_through };

/// Strokes `p.path` with `width` (optional dash) and fills it with `col` through `clip`.
fn strokeFill(p: *Painter, ctx: *const Ctx, width: f32, dash: ?pborder.Dash, col: style.Color, clip: ?*const raster.ClipMask) Error!void {
    p.path2.reset();
    var arr: [2]f32 = .{ 0, 0 };
    var o: raster.StrokeOptions = .{ .width = width, .scale = Painter.tfScale(ctx.tf) };
    if (dash) |d| {
        arr = .{ d.on, d.off };
        o.dash = &arr;
        if (d.round) o.cap = .round;
    }
    raster.strokePath(p.a, &p.path, o, &p.path2) catch return error.OutOfMemory;
    p.rast().fillPath(ctx.dst, &p.path2, ctx.tf, .nonzero, &.{ .solid = rcolor(col) }, clip) catch return error.OutOfMemory;
}

const Span = struct { a: f32, b: f32 };

/// One decoration line of one run: `top` = y of its upper edge (takumi `DecorationLine`).
noinline fn paintDecoLine(p: *Painter, ctx: *const Ctx, kind: DecoKind, st: style.computed.DecorationStyle, col: style.Color, x0: f32, x1: f32, top: f32, thickness: f32, cuts: []const Span) Error!void {
    if (col.a == 0 or !(x1 > x0)) return;
    const pt: Paint = .{ .solid = rcolor(col) };
    const h = @max(1, @floor(thickness));
    // pieces between the skip-ink cuts
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
    switch (st) {
        .solid, .double => for (pieces[0..np]) |pc| {
            const yy = @floor(top + 0.5);
            try p.fillRRect(ctx, .{ .x = pc.a, .y = yy, .w = pc.b - pc.a, .h = h }, null, &pt);
            if (st == .double) try p.fillRRect(ctx, .{ .x = pc.a, .y = @floor(top + second + 0.5), .w = pc.b - pc.a, .h = h }, null, &pt);
        },
        .dotted, .dashed => {
            const start = @floor(x0);
            const end = @floor(x1);
            const row = @floor(top + @max(thickness / 2, 0.5));
            const t = @max(1, @round(thickness));
            const yl = if (@mod(t, 2) == 1) row + 0.5 else row;
            const dash = pborder.dashPattern(if (st == .dotted) .dotted else .dashed, t, end - start, false);
            var a = start;
            var b = end;
            if (dash != null and dash.?.round) {
                a += t / 2;
                b -= t / 2;
            }
            if (!(b > a)) return;
            p.path.reset();
            p.path.moveTo(p.a, a, yl) catch return error.OutOfMemory;
            p.path.lineTo(p.a, b, yl) catch return error.OutOfMemory;
            if (cuts.len == 0) return strokeFill(p, ctx, t, dash, col, ctx.clip);
            for (pieces[0..np]) |pc| {
                const clip = try p.makeClip(ctx, .{ .x = pc.a, .y = yl - t / 2 - 1, .w = pc.b - pc.a, .h = t + 2 }, null);
                p.path.reset();
                p.path.moveTo(p.a, a, yl) catch return error.OutOfMemory;
                p.path.lineTo(p.a, b, yl) catch return error.OutOfMemory;
                try strokeFill(p, ctx, t, dash, col, clip);
            }
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
            for (pieces[0..np]) |pc| {
                const clip = try p.makeClip(ctx, .{ .x = pc.a, .y = ctop, .w = pc.b - pc.a, .h = cbot - ctop }, null);
                p.path.reset();
                var xx = x0 - wl;
                p.path.moveTo(p.a, xx, yy) catch return error.OutOfMemory;
                var guard: u32 = 0;
                while (xx < x1 + wl and guard < 20000) : (guard += 1) {
                    p.path.cubicTo(p.a, xx + wl / 2, yy + cpd, xx + wl / 2, yy - cpd, xx + wl, yy) catch return error.OutOfMemory;
                    xx += wl;
                }
                try strokeFill(p, ctx, thickness, null, col, clip);
            }
        },
    }
}

const Metrics = struct { ascent: f32, descent: f32, ul_pos: f32, ul_thick: f32, em_descent: f32 };

fn metricsOf(p: *Painter, face: font.FaceId, size: f32) Metrics {
    const fnt = p.f.r.fonts.font(face);
    const s = size / @as(f32, @floatFromInt(@max(1, fnt.unitsPerEm())));
    const lm = fnt.lineMetrics();
    const ta: f32 = @floatFromInt(fnt.typoAscender());
    const td: f32 = @floatFromInt(-@as(i32, fnt.typoDescender()));
    const a: f32 = @floatFromInt(lm.ascent);
    const d: f32 = @floatFromInt(lm.descent);
    return .{
        .ascent = @round(a * s),
        .descent = @round(d * s),
        .ul_pos = -@as(f32, @floatFromInt(fnt.underlinePosition())) * s,
        .ul_thick = @as(f32, @floatFromInt(fnt.underlineThickness())) * s,
        .em_descent = if (ta + td > 0) size * td / (ta + td) else if (a + d > 0) size * d / (a + d) else 0,
    };
}

const RunSeg = struct { g0: u32, g1: u32, x0: f32, x1: f32, baseline: f32, rcs: *const CS };

/// Decorations of one run for the phase `after` (false: underline + overline, true: line-through).
noinline fn paintRunDecos(p: *Painter, ctx: *const Ctx, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32, run: *const RunSeg, decos: []const *const CS, after: bool) Error!void {
    const g0 = &tl.glyphs[run.g0];
    const tm = metricsOf(p, g0.face, g0.size);
    const text_top = y + run.baseline - tm.ascent;
    for (decos) |dcs| {
        const dl = dcs.text_decoration_line;
        const col = dcs.resolveColor(dcs.text_decoration_color);
        const dm = metricsOf(p, g0.face, dcs.font_size);
        const auto = dcs.font_size / 10.0;
        const thickness = @max(1, if (dcs.text_decoration_thickness) |v| @round(v) else auto);
        const box_top = y + run.baseline - dm.ascent;
        const off = if (dcs.text_underline_offset) |o| o else 0;
        const lx0 = x + run.x0;
        const lx1 = x + run.x1;
        if (after) {
            if (dl.line_through) try paintDecoLine(p, ctx, .line_through, dcs.text_decoration_style, col, lx0, lx1, text_top + 2 * dm.ascent / 3 - thickness / 2, thickness, &.{});
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
                if (dcs.text_decoration_skip_ink != .none and ctx.plain()) nc = skipInk(p, ctx, n, tl, x, y, run, top, thickness, dcs.text_decoration_style, kind == .underline, &cuts);
                try paintDecoLine(p, ctx, kind, dcs.text_decoration_style, col, lx0, lx1, top, thickness, cuts[0..nc]);
            }
        }
    }
}

/// Ink intercepts of the run's glyphs with the decoration band (from the glyph coverage masks),
/// dilated by min(thickness, 13) and merged; edges snapped to whole pixels.
fn skipInk(p: *Painter, ctx: *const Ctx, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32, run: *const RunSeg, top: f32, thickness: f32, st: style.computed.DecorationStyle, underline: bool, out: *[32]Span) usize {
    _ = n;
    // decoration bounds (takumi `bounds()`), inset by 0.5 on each side
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
        const sy = synthOf(p, run.rcs, g);
        if (sy.colored) continue;
        const m = glyphPassMask(p, ctx, g, x + g.x, y + g.y, sy.italic, .fill, 0) orelse continue;
        const mb = m.bounds;
        var lo: i64 = std.math.maxInt(i64);
        var hi: i64 = std.math.minInt(i64);
        var row = @max(r0, @as(i64, mb.y));
        const row_end = @min(r1, mb.bottom());
        // one cut per connected column range with ink
        var xx: u32 = 0;
        while (xx < mb.w) : (xx += 1) {
            var ink = false;
            row = @max(r0, @as(i64, mb.y));
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

fn hasLine(cs: *const CS) bool {
    const d = cs.text_decoration_line;
    return d.underline or d.overline or d.line_through;
}

// ---- inline box decorations

/// Background / border of inline spans: one fragment per span per line, from the text engine
/// (`TextLayout.boxes`: outer spans first; border-box extents with the inline edges where the
/// fragment has them). Content area = the span font's ascent + descent (not the line height),
/// grown by the span's padding and border.
noinline fn paintInlineBoxes(p: *Painter, ctx: *const Ctx, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32) Error!void {
    const f = p.f;
    for (tl.boxes) |*fr| {
        const fi = f.boxFragment(n, fr) orelse continue;
        if (!isInlineBox(fi.cs)) continue;
        try paintFragment(p, ctx, fi.cs, fr.face, fi.x0, fi.x1, fr.baseline, fi.left, fi.right, x, y);
    }
}

/// One fragment of an inline box: content extent [x0, x1] on `baseline` (paragraph space), with
/// the box's left / right padding and border when `first` / `last`.
noinline fn paintFragment(p: *Painter, ctx: *const Ctx, cs: *const CS, face: font.FaceId, x0: f32, x1: f32, baseline: f32, first: bool, last: bool, x: f32, y: f32) Error!void {
    const m = metricsOf(p, face, cs.font_size);
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
    if (col.a != 0) try p.fillRRect(ctx, g.bx, g.outerRadii(), &.{ .solid = rcolor(col) });
    var i = cs.background_image.len;
    while (i > 0) {
        i -= 1;
        const layer = cs.bgLayer(i);
        if (layer.image == .none or layer.clip == .text) continue;
        try p.paintBgLayer(ctx, cs, &g, &layer, true);
    }
    try pborder.paintBorder(p, ctx, cs, &g);
}

fn isInlineBox(cs: *const CS) bool {
    if (cs.resolveColor(cs.background_color).a != 0) return true;
    if (cs.background_image.len > 0) return true;
    const bw = cs.usedBorderWidths();
    return bw[0] > 0 or bw[1] > 0 or bw[2] > 0 or bw[3] > 0;
}

// ---- paragraphs

noinline fn paintGlyphPhase(p: *Painter, ctx: *const Ctx, tl: *const font.TextLayout, x: f32, y: f32, run: *const RunSeg, stroke_phase: bool) Error!void {
    const rcs = run.rcs;
    if (stroke_phase) {
        const sw = rcs.webkit_text_stroke_width;
        const scol = rcs.resolveColor(rcs.webkit_text_stroke_color);
        if (!(sw > 0) or scol.a == 0) return;
        const pt: Paint = .{ .solid = rcolor(scol) };
        for (tl.glyphs[run.g0..run.g1]) |*g| {
            const sy = synthOf(p, rcs, g);
            if (sy.colored) continue;
            if (glyphPassMask(p, ctx, g, x + g.x, y + g.y, sy.italic, .stroke, sw)) |m| raster.fillMask(ctx.dst, &m, &pt, ctx.clip);
        }
        return;
    }
    const fill = if (rcs.webkit_text_fill_color) |c| rcs.resolveColor(c) else rcs.color;
    if (fill.a == 0) return;
    const pt: Paint = .{ .solid = rcolor(fill) };
    for (tl.glyphs[run.g0..run.g1]) |*g| {
        const sy = synthOf(p, rcs, g);
        if (sy.colored) {
            try paintColorGlyph(p, ctx, g, x + g.x, y + g.y, fill);
            continue;
        }
        if (glyphPassMask(p, ctx, g, x + g.x, y + g.y, sy.italic, .fill, 0)) |m| raster.fillMask(ctx.dst, &m, &pt, ctx.clip);
        if (sy.bold) {
            if (glyphPassMask(p, ctx, g, x + g.x, y + g.y, sy.italic, .embolden, 0)) |m| raster.fillMask(ctx.dst, &m, &pt, ctx.clip);
        }
    }
}

pub noinline fn paintText(p: *Painter, ctx: *const Ctx, n: *const Node, x: f32, y: f32, cw: f32) Error!void {
    const f = p.f;
    const tl = (try f.textLayout(f.nodeId(n), cw)) orelse return;
    if (tl.boxes.len > 0) try paintInlineBoxes(p, ctx, n, tl, x, y);
    if (n.cs.text_shadow.len > 0 and n.cs.visibility == .visible) try paintTextShadows(p, ctx, n, tl, x, y, cw);

    // Decorating boxes: the block (or, for a text node, its parent) and the run's own span.
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
            const rcs = runStyle(p, n, &tl.glyphs[r.g0]);
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
            if (nd > 0) try paintRunDecos(p, ctx, n, tl, x, y, &run, decos[0..nd], false);
            const stroke_first = honor_paint_order and rcs.paint_order == .stroke;
            try paintGlyphPhase(p, ctx, tl, x, y, &run, stroke_first);
            try paintGlyphPhase(p, ctx, tl, x, y, &run, !stroke_first);
            if (nd > 0) try paintRunDecos(p, ctx, n, tl, x, y, &run, decos[0..nd], true);
        }
    }
}
