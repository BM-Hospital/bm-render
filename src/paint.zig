//! Painter: walks the laid-out node tree and draws boxes, text and images in takumi / Blink paint
//! order: outer shadows -> background -> inset shadows -> border -> content -> children, outlines
//! at the end of their stacking context.
//!
//! * Anti-aliasing is takumi's (tiny-skia supersampling, `Rasterizer.mode = .skia_ss`) for every
//!   shape, clip and glyph; untransformed boxes are pixel-snapped, transformed plain boxes are
//!   filled without AA (as takumi does).
//! * Elements with opacity / filter / backdrop-filter / mix-blend-mode / isolation / clip-path /
//!   mask-image paint into a canvas-sized offscreen layer (one per nesting level, only the affected
//!   region is cleared and composited): see `paintGroup`.
//! * Companion files: paint_border.zig (border styles, outline), paint_text.zig (glyphs,
//!   decorations, text stroke, colour glyphs, inline boxes), paint_fx.zig (clip-path, masks,
//!   drop-shadow, backdrop), paint_svg.zig (SVG images).
//! * Everything is allocated from the per-render arena (`Frame.a`); the only long-lived state
//!   touched is the renderer's glyph cache, image cache and rasterizer scratch.
const std = @import("std");
const render = @import("render.zig");
const style = @import("style/style.zig");
const font = @import("font/font.zig");
const raster = @import("raster/raster.zig");
const rtypes = @import("raster/types.zig");
const ptext = @import("paint_text.zig");
const pborder = @import("paint_border.zig");
const pfx = @import("paint_fx.zig");
const psvg = @import("paint_svg.zig");
const ptable = @import("paint_table.zig");

/// Optional features (the integrator points these at `config.zig`).
pub const enable_color_fonts = @import("config.zig").enable_color_fonts;
/// Colour glyphs of some kind are drawn (COLR needs `enable_color_fonts`, bitmaps either flag).
pub const enable_color_glyphs = enable_color_fonts or @import("config.zig").enable_bitmap_glyphs;
/// The colour tables of one face, cached by `paint_text.synthOf` / `svg_out_text.synthOf`.
pub const ColorTablesCache = struct {
    const T = if (enable_color_glyphs) @import("font/color.zig").ColorTables else void;
    face: u32 = 0xffff_ffff,
    tables: T = if (enable_color_glyphs) .{} else {},
    /// times the tables were read
    reads: u32 = 0,
    /// The colour tables of `fnt` (face id `id`), read once per face in a row of glyphs.
    pub fn get(c: *ColorTablesCache, id: u32, fnt: anytype) *const T {
        if (c.face != id) {
            c.tables = T.init(fnt);
            c.face = id;
            c.reads +%= 1;
        }
        return &c.tables;
    }
};

test "glyph synthesis reads a face's colour tables once per run of its glyphs" {
    if (comptime !enable_color_glyphs) return;
    const inter = try font.Font.init(@embedFile("font/testdata/Inter-Regular.ttf"), 0);
    const roboto = try font.Font.init(@embedFile("font/testdata/Roboto-Regular.ttf"), 0);
    var c: ColorTablesCache = .{};
    for (0..1000) |g| try std.testing.expectEqual(.none, c.get(0, &inter).kind(@intCast(g)));
    try std.testing.expectEqual(@as(u32, 1), c.reads);
    try std.testing.expect(!c.get(1, &roboto).hasColor());
    try std.testing.expectEqual(@as(u32, 2), c.reads);
}
pub const enable_svg = @import("config.zig").enable_svg;
/// clip-path, mask-image, mix-/background-blend-mode, backdrop-filter, isolation.
pub const enable_effects = @import("config.zig").enable_effects;
pub const enable_floats = @import("config.zig").enable_floats;
pub const enable_tables = @import("config.zig").enable_tables;

const Frame = render.Frame;
const Node = render.Node;
const CS = render.CS;
const none = render.none;
const Rect = raster.Rect;
const IRect = raster.IRect;
const Affine = raster.Affine;
const Pixmap = raster.Pixmap;
const ClipMask = raster.ClipMask;
const Paint = raster.Paint;
const Error = render.Error;
pub const Radii = [4][2]f32;
pub const zero_radii: Radii = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };

pub const Ctx = struct {
    dst: *Pixmap,
    clip: ?*const ClipMask = null,
    tf: Affine = Affine.identity,

    pub fn plain(c: *const Ctx) bool {
        return c.tf.isIdentity();
    }
};

pub fn rcolor(c: style.Color) raster.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

pub inline fn roundHalfUp(v: f32) f32 {
    return @floor(v + 0.5);
}

/// Blink `SnapSizeToPixel`.
fn snapSize(pos: f32, size: f32) f32 {
    const frac = pos - @floor(pos);
    const s = roundHalfUp(frac + size) - roundHalfUp(frac);
    if (s == 0 and @abs(size) > 4.0 / 64.0) return if (size > 0) 1 else -1;
    return s;
}

pub fn snapRect(x: f32, y: f32, w: f32, h: f32) Rect {
    return .{ .x = roundHalfUp(x), .y = roundHalfUp(y), .w = @max(0, snapSize(x, w)), .h = @max(0, snapSize(y, h)) };
}

fn insetRect(r: Rect, t: f32, rg: f32, b: f32, l: f32) Rect {
    return .{ .x = r.x + l, .y = r.y + t, .w = @max(0, r.w - l - rg), .h = @max(0, r.h - t - b) };
}

pub fn hasAnyRadius(r: Radii) bool {
    return hasRadii(r);
}

fn hasRadii(r: Radii) bool {
    for (r) |c| if (c[0] > 0 and c[1] > 0) return true;
    return false;
}

fn insetRadii(r: Radii, t: f32, rg: f32, b: f32, l: f32) Radii {
    return .{
        .{ @max(0, r[0][0] - l), @max(0, r[0][1] - t) },
        .{ @max(0, r[1][0] - rg), @max(0, r[1][1] - t) },
        .{ @max(0, r[2][0] - rg), @max(0, r[2][1] - b) },
        .{ @max(0, r[3][0] - l), @max(0, r[3][1] - b) },
    };
}

fn spreadRadii(r: Radii, spread: f32) Radii {
    var out = r;
    for (&out) |*c| {
        if (c[0] > 0 and c[1] > 0) {
            c[0] = @max(0, c[0] + spread);
            c[1] = @max(0, c[1] + spread);
        } else c.* = .{ 0, 0 };
    }
    return out;
}

pub fn resolveRadiiRaw(cs: *const CS, w: f32, h: f32) Radii {
    var r: Radii = undefined;
    for (0..4) |i| {
        r[i] = .{ @max(0, cs.border_radius[i][0].resolve(w)), @max(0, cs.border_radius[i][1].resolve(h)) };
        if (r[i][0] <= 0 or r[i][1] <= 0) r[i] = .{ 0, 0 };
    }
    return r;
}

/// CSS corner overlap: scale all radii by the smallest ratio.
pub fn scaleRadii(r: *Radii, w: f32, h: f32) void {
    var f: f32 = 1;
    const sums = [4][2]f32{ .{ r[0][0] + r[1][0], w }, .{ r[3][0] + r[2][0], w }, .{ r[0][1] + r[3][1], h }, .{ r[1][1] + r[2][1], h } };
    for (sums) |e| if (e[0] > e[1] and e[0] > 0) {
        f = @min(f, e[1] / e[0]);
    };
    if (f < 1) for (r) |*c| {
        c[0] *= f;
        c[1] *= f;
    };
}

fn resolveRadii(cs: *const CS, w: f32, h: f32) Radii {
    var r = resolveRadiiRaw(cs, w, h);
    scaleRadii(&r, w, h);
    return r;
}

/// Composites the `reg` part of a canvas-sized premultiplied layer onto `dst` exactly like
/// takumi's `end_layer`: the layer is first scaled by the clip coverage (`mul_div_255`), then
/// blended source-over; with `opacity` < 1 in f32 (`source_over_at_opacity`: per channel
/// `(d/255) * (1 - sa/255 * opacity) + s/255 * opacity`, scaled by 255, rounded ties-to-even).
pub noinline fn compositeLayer(dst: *Pixmap, src: *const Pixmap, reg: IRect, opacity: f32, clip: ?*const ClipMask) void {
    var r = reg.intersect(dst.bounds()).intersect(src.bounds());
    if (clip) |c| r = r.intersect(c.bounds);
    if (r.isEmpty() or src.width != dst.width) return;
    const stride = @as(usize, dst.width) * 4;
    const unit: f32 = 1.0 / 255.0;
    const shift: f32 = 8_388_608.0;
    const translucent = opacity < 1;
    // k/255 and k/255 * opacity, exactly as the reference computes them
    var du: [256]f32 = undefined;
    var sv: [256]f32 = undefined;
    if (translucent) {
        for (0..256) |k| {
            du[k] = @as(f32, @floatFromInt(k)) * unit;
            sv[k] = du[k] * opacity;
        }
    }
    const P = *align(1) u32;
    var last_s: u32 = 0;
    var last_d: u32 = 0;
    var last_o: u32 = 0;
    var yy: u32 = 0;
    while (yy < r.h) : (yy += 1) {
        const off = (@as(usize, @intCast(r.y)) + yy) * stride + @as(usize, @intCast(r.x)) * 4;
        const drow = dst.data[off..][0 .. @as(usize, r.w) * 4];
        const srow = src.data[off..][0 .. @as(usize, r.w) * 4];
        var crow: ?[]const u8 = null;
        if (clip) |c| if (c.data) |cd| {
            const co = (@as(usize, @intCast(@as(i64, r.y) - c.bounds.y)) + yy) * c.bounds.w + @as(usize, @intCast(@as(i64, r.x) - c.bounds.x));
            crow = cd[co..][0..r.w];
        };
        var x: usize = 0;
        while (x < r.w) : (x += 1) {
            var s32: u32 = @as(P, @ptrCast(srow.ptr + x * 4)).*;
            if (s32 == 0) continue;
            if (crow) |cr| {
                const cv: u32 = cr[x];
                if (cv == 0) continue;
                if (cv != 255) {
                    var sp: [4]u8 = @bitCast(s32);
                    inline for (0..4) |k| sp[k] = @intCast(raster.div255(@as(u32, sp[k]) * cv));
                    s32 = @bitCast(sp);
                    if (s32 == 0) continue;
                }
            }
            const dp: P = @ptrCast(drow.ptr + x * 4);
            const d32 = dp.*;
            if (s32 == last_s and d32 == last_d) {
                dp.* = last_o;
                continue;
            }
            const sp: [4]u8 = @bitCast(s32);
            const d: [4]u8 = @bitCast(d32);
            var o: [4]u8 = undefined;
            if (translucent) {
                const behind = 1.0 - sv[sp[3]];
                inline for (0..4) |k| {
                    const bl = du[d[k]] * behind + sv[sp[k]];
                    o[k] = @intFromFloat((@min(bl, 1.0) * 255.0 + shift) - shift);
                }
            } else if (sp[3] == 255 or d[3] == 0) {
                o = sp;
            } else {
                const inv: u32 = 255 - @as(u32, sp[3]);
                inline for (0..4) |k| o[k] = @intCast(@min(255, @as(u32, sp[k]) + raster.div255(@as(u32, d[k]) * inv)));
            }
            last_s = s32;
            last_d = d32;
            last_o = @bitCast(o);
            dp.* = last_o;
        }
    }
}

pub const Geom = struct {
    /// pixel-snapped border box
    bx: Rect,
    /// border widths top, right, bottom, left
    bw: [4]f32,
    /// layout padding top, right, bottom, left
    pad: [4]f32,
    radii: Radii,
    rounded: bool,
    snapped: bool = true,
    /// the border box before pixel snapping (snapped geometry only)
    raw: ?Rect = null,

    pub fn padRect(g: *const Geom) Rect {
        return insetRect(g.bx, g.bw[0], g.bw[1], g.bw[2], g.bw[3]);
    }
    /// The padding box an `overflow` clip clips to (takumi `OverflowClip::of`, Blink's
    /// `PixelSnappedContouredInnerBorder`): with a border, the unsnapped border box inset by it and
    /// then snapped, so a half-pixel border (a collapsed table cell's) rounds the edge instead of
    /// moving it by half a pixel; without one, the snapped border box.
    pub fn overflowRect(g: *const Geom) Rect {
        const r = g.raw orelse return g.padRect();
        if (g.bw[0] == 0 and g.bw[1] == 0 and g.bw[2] == 0 and g.bw[3] == 0) return g.padRect();
        const q = struct {
            fn u(v: f32) f32 {
                return roundAway64(v * 64) / 64;
            }
            fn roundAway64(v: f32) f32 {
                return if (v >= 0) @floor(v + 0.5) else -@floor(0.5 - v);
            }
            /// Blink `SnapSizeToPixelAllowingZero`
            fn size(s: f32, at: f32) f32 {
                const frac = at - @floor(at);
                return roundHalfUp(frac + s) - roundHalfUp(frac);
            }
        };
        const x = q.u(r.x) + q.u(g.bw[3]);
        const y = q.u(r.y) + q.u(g.bw[0]);
        const w = @max(0, q.u(r.w) - q.u(g.bw[1]) - q.u(g.bw[3]));
        const h = @max(0, q.u(r.h) - q.u(g.bw[0]) - q.u(g.bw[2]));
        return .{ .x = q.roundAway64(x), .y = q.roundAway64(y), .w = @max(0, q.size(w, x)), .h = @max(0, q.size(h, y)) };
    }
    pub fn padRadii(g: *const Geom) ?Radii {
        if (!g.rounded) return null;
        const r = insetRadii(g.radii, g.bw[0], g.bw[1], g.bw[2], g.bw[3]);
        return if (hasRadii(r)) r else null;
    }
    pub fn contentRect(g: *const Geom) Rect {
        const p = g.padRect();
        if (!g.snapped) return insetRect(p, g.pad[0], g.pad[1], g.pad[2], g.pad[3]);
        const x0 = roundHalfUp(p.x + g.pad[3]);
        const y0 = roundHalfUp(p.y + g.pad[0]);
        const x1 = roundHalfUp(p.x + p.w - g.pad[1]);
        const y1 = roundHalfUp(p.y + p.h - g.pad[2]);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }
    pub fn contentRadii(g: *const Geom) ?Radii {
        if (!g.rounded) return null;
        const r = insetRadii(g.radii, g.bw[0] + g.pad[0], g.bw[1] + g.pad[1], g.bw[2] + g.pad[2], g.bw[3] + g.pad[3]);
        return if (hasRadii(r)) r else null;
    }
    pub fn outerRadii(g: *const Geom) ?Radii {
        return if (g.rounded) g.radii else null;
    }
};

pub const Painter = struct {
    f: *Frame,
    a: std.mem.Allocator,
    path: raster.Path = .empty,
    path2: raster.Path = .empty,
    /// reusable full-canvas offscreen layers, one per opacity nesting level
    layers: std.ArrayList(*Pixmap) = .empty,
    /// outlines waiting for the end of their stacking context
    outlines: std.ArrayList(Deferred) = .empty,
    layer_depth: usize = 0,
    /// table parts by render node id (allocated when the first table is painted; paint_table.zig)
    tparts: []ptable.Part = &.{},
    /// Paint order inside a stacking context (CSS 2.1 appendix E): the backgrounds / borders of the
    /// in-flow block-level boxes in tree order, then the floats, then the inline content (text, inline
    /// box decorations, atomic inlines), then the positioned descendants and z-index 0 stacking contexts
    /// in tree order, then the positive z-indexes. The in-flow walk paints the first layer and queues the
    /// rest (with the origin and clip / transform context they were met in):
    ///  * `float_q` and `text_q` are flushed at the end of every box that is painted atomically (the
    ///    root, a float, an atomic inline, a flex / grid item, a positioned box or stacking context);
    ///  * `pos_q` at the end of a positioned box or stacking context (its own positioned descendants
    ///    follow it in tree order), `zpos_q` (sorted by z-index) at the end of a stacking context.
    /// Negative z-indexes are painted before the in-flow siblings of their parent (an approximation of
    /// "before the in-flow content of the stacking context"). `float_now` / `pos_now`: the box being
    /// painted from a queue.
    float_q: std.ArrayList(Queued) = .empty,
    text_q: std.ArrayList(Queued) = .empty,
    pos_q: std.ArrayList(Queued) = .empty,
    zpos_q: std.ArrayList(Queued) = .empty,
    float_now: u32 = none,
    pos_now: u32 = none,
    /// `paint_text.synthOf`: the colour tables of the last face it looked at
    color_tables: ColorTablesCache = .{},

    /// `text`: the inline content of paragraph node `id` whose box origin is (ox, oy); else the node
    /// `id` as a whole, with its parent's origin.
    const Queued = struct { id: u32, ox: f32, oy: f32, ctx: Ctx, depth: u32, z: i32 = 0, text: bool = false };

    pub fn rast(p: *Painter) *raster.Rasterizer {
        return &p.f.r.rast;
    }

    pub fn setRRect(p: *Painter, r: Rect, radii: ?Radii) Error!void {
        p.path.reset();
        if (radii) |rr| {
            p.path.addRoundRect(p.a, r, rr) catch return error.OutOfMemory;
        } else p.path.addRect(p.a, r) catch return error.OutOfMemory;
    }

    pub noinline fn fillRRect(p: *Painter, ctx: *const Ctx, r: Rect, radii: ?Radii, pt: *const Paint) Error!void {
        if (!(r.w > 0) or !(r.h > 0)) return;
        if (radii == null and ctx.plain()) {
            raster.fillRect(ctx.dst, r, pt, ctx.clip);
            return;
        }
        if (radii == null) return p.fillRectAliased(ctx, r, pt);
        try p.setRRect(r, radii);
        if (radii != null and ctx.plain() and r.w * r.h >= 4096 and @floor(r.x) == r.x and @floor(r.y) == r.y and @floor(r.w) == r.w and @floor(r.h) == r.h) {
            // Large rounded rect: only the four corner cells go through the path rasterizer.
            const rr = radii.?;
            const a = @ceil(rr[0][0]);
            const b = @ceil(rr[1][0]);
            const d = @ceil(rr[2][0]);
            const c = @ceil(rr[3][0]);
            const top = @max(@ceil(rr[0][1]), @ceil(rr[1][1]));
            const bot = @max(@ceil(rr[2][1]), @ceil(rr[3][1]));
            if (top + bot <= r.h and a + b <= r.w and c + d <= r.w) {
                raster.fillRect(ctx.dst, .{ .x = r.x, .y = r.y + top, .w = r.w, .h = r.h - top - bot }, pt, ctx.clip);
                raster.fillRect(ctx.dst, .{ .x = r.x + a, .y = r.y, .w = r.w - a - b, .h = top }, pt, ctx.clip);
                raster.fillRect(ctx.dst, .{ .x = r.x + c, .y = r.y + r.h - bot, .w = r.w - c - d, .h = bot }, pt, ctx.clip);
                const cells = [4]Rect{
                    .{ .x = r.x, .y = r.y, .w = a, .h = top },
                    .{ .x = r.x + r.w - b, .y = r.y, .w = b, .h = top },
                    .{ .x = r.x + r.w - d, .y = r.y + r.h - bot, .w = d, .h = bot },
                    .{ .x = r.x, .y = r.y + r.h - bot, .w = c, .h = bot },
                };
                for (cells) |cell| {
                    if (!(cell.w > 0) or !(cell.h > 0)) continue;
                    var cc = ClipMask.fromRect(toIRect(cell));
                    if (ctx.clip) |outer| cc = raster.clipIntersect(p.a, outer.*, cc) catch return error.OutOfMemory;
                    if (cc.bounds.isEmpty()) continue;
                    p.rast().fillPath(ctx.dst, &p.path, ctx.tf, .nonzero, pt, &cc) catch return error.OutOfMemory;
                }
                return;
            }
        }
        p.rast().fillPath(ctx.dst, &p.path, ctx.tf, .nonzero, pt, ctx.clip) catch return error.OutOfMemory;
    }

    /// takumi fills a transformed, non-rounded box without anti-aliasing: a pixel is painted when
    /// its centre lies inside the transformed rectangle.
    noinline fn fillRectAliased(p: *Painter, ctx: *const Ctx, r: Rect, pt: *const Paint) Error!void {
        const inv = ctx.tf.invert() orelse return;
        const b = devBounds(ctx.tf, r).intersect(region(ctx));
        if (b.isEmpty()) return;
        var m = raster.Mask.init(p.a, b) catch return error.OutOfMemory;
        const x1 = r.x + r.w;
        const y1 = r.y + r.h;
        var yy: u32 = 0;
        while (yy < b.h) : (yy += 1) {
            const cy = @as(f32, @floatFromInt(@as(i64, b.y) + yy)) + 0.5;
            const row = m.data[@as(usize, yy) * b.w ..][0..b.w];
            for (row, 0..) |*v, xx| {
                const cx = @as(f32, @floatFromInt(@as(i64, b.x) + @as(i64, @intCast(xx)))) + 0.5;
                const lx = inv.a * cx + inv.c * cy + inv.e;
                const ly = inv.b * cx + inv.d * cy + inv.f;
                v.* = if (lx >= r.x and lx < x1 and ly >= r.y and ly < y1) 255 else 0;
            }
        }
        raster.fillMask(ctx.dst, &m, pt, ctx.clip);
    }

    pub fn region(ctx: *const Ctx) IRect {
        var reg = ctx.dst.bounds();
        if (ctx.clip) |c| reg = reg.intersect(c.bounds);
        return reg;
    }

    pub fn toIRect(r: Rect) IRect {
        const lim: f32 = 1.0e6;
        const x0 = std.math.clamp(r.x, -lim, lim);
        const y0 = std.math.clamp(r.y, -lim, lim);
        const x1 = std.math.clamp(r.x + r.w, -lim, lim);
        const y1 = std.math.clamp(r.y + r.h, -lim, lim);
        return .{
            .x = @intFromFloat(@floor(x0)),
            .y = @intFromFloat(@floor(y0)),
            .w = @intFromFloat(@max(0, @ceil(x1) - @floor(x0))),
            .h = @intFromFloat(@max(0, @ceil(y1) - @floor(y0))),
        };
    }

    /// Coverage mask of a (rounded) rect clipped to `window`. Large pixel-aligned shapes are
    /// assembled from solid spans plus four small corner rasterizations, so neither time nor the
    /// rasterizer's scratch memory scale with the box area.
    pub noinline fn rrectMask(p: *Painter, ctx: *const Ctx, r: Rect, radii: ?Radii, window: IRect) Error!raster.Mask {
        fast: {
            if (!ctx.plain() or !(r.w * r.h >= 4096)) break :fast;
            if (@floor(r.x) != r.x or @floor(r.y) != r.y or @floor(r.w) != r.w or @floor(r.h) != r.h) break :fast;
            if (@abs(r.x) > 1.0e6 or @abs(r.y) > 1.0e6 or r.w > 1.0e6 or r.h > 1.0e6) break :fast;
            const rr: Radii = radii orelse .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
            const ca = @ceil(rr[0][0]);
            const cb = @ceil(rr[1][0]);
            const cd = @ceil(rr[2][0]);
            const cc = @ceil(rr[3][0]);
            const top = @max(@ceil(rr[0][1]), @ceil(rr[1][1]));
            const bot = @max(@ceil(rr[2][1]), @ceil(rr[3][1]));
            if (top + bot > r.h or ca + cb > r.w or cc + cd > r.w) break :fast;
            const full = toIRect(r);
            const b = full.intersect(window);
            if (b.isEmpty()) return raster.Mask.empty;
            var m = raster.Mask.init(p.a, b) catch return error.OutOfMemory;
            const itop: i64 = @intFromFloat(top);
            const ibot: i64 = @intFromFloat(bot);
            var yy: u32 = 0;
            while (yy < b.h) : (yy += 1) {
                const ry: i64 = @as(i64, b.y) + yy - full.y;
                var xs: i64 = full.x;
                var xe: i64 = @as(i64, full.x) + full.w;
                if (ry < itop) {
                    xs += @intFromFloat(ca);
                    xe -= @intFromFloat(cb);
                } else if (ry >= @as(i64, full.h) - ibot) {
                    xs += @intFromFloat(cc);
                    xe -= @intFromFloat(cd);
                }
                xs = @max(xs, b.x);
                xe = @min(xe, @as(i64, b.x) + b.w);
                if (xe > xs) @memset(m.data[@as(usize, yy) * b.w + @as(usize, @intCast(xs - b.x)) ..][0..@intCast(xe - xs)], 255);
            }
            if (radii != null) {
                try p.setRRect(r, radii);
                const cells = [4]Rect{
                    .{ .x = r.x, .y = r.y, .w = ca, .h = top },
                    .{ .x = r.x + r.w - cb, .y = r.y, .w = cb, .h = top },
                    .{ .x = r.x + r.w - cd, .y = r.y + r.h - bot, .w = cd, .h = bot },
                    .{ .x = r.x, .y = r.y + r.h - bot, .w = cc, .h = bot },
                };
                for (cells) |cell| {
                    if (!(cell.w > 0) or !(cell.h > 0)) continue;
                    const cw = toIRect(cell).intersect(b);
                    if (cw.isEmpty()) continue;
                    const cm = p.rast().rasterize(p.a, &p.path, Affine.identity, .nonzero, cw) catch return error.OutOfMemory;
                    const cbd = cm.bounds;
                    var cy: u32 = 0;
                    while (cy < cbd.h) : (cy += 1) {
                        const drow: usize = @intCast(@as(i64, cbd.y) + cy - b.y);
                        const dcol: usize = @intCast(@as(i64, cbd.x) - b.x);
                        @memcpy(m.data[drow * b.w + dcol ..][0..cbd.w], cm.data[@as(usize, cy) * cbd.w ..][0..cbd.w]);
                    }
                }
            }
            return m;
        }
        try p.setRRect(r, radii);
        return p.rast().rasterize(p.a, &p.path, ctx.tf, .nonzero, window) catch return error.OutOfMemory;
    }

    /// New clip = current clip ∩ (rounded) rect, allocated in the arena.
    pub noinline fn makeClip(p: *Painter, ctx: *const Ctx, r: Rect, radii: ?Radii) Error!*const ClipMask {
        var c: ClipMask = undefined;
        if (radii == null and ctx.plain()) {
            c = ClipMask.fromRect(toIRect(r).intersect(ctx.dst.bounds()));
        } else {
            const m = try p.rrectMask(ctx, r, radii, region(ctx));
            c = m.asClip();
        }
        if (ctx.clip) |cc| c = raster.clipIntersect(p.a, cc.*, c) catch return error.OutOfMemory;
        const out = try p.a.create(ClipMask);
        out.* = c;
        return out;
    }

    // ---- gradients

    fn convertStops(p: *Painter, g: *const style.Gradient, len: f32, cur: style.Color) Error![]raster.GradientStop {
        const rs = style.gradient.resolveGradientStops(p.a, g, len, cur) catch return error.OutOfMemory;
        const out = try p.a.alloc(raster.GradientStop, rs.len);
        const inv: f32 = if (len > 0) 1.0 / len else 0;
        for (rs, 0..) |s, i| out[i] = .{ .offset = s.offset_px * inv, .color = rcolor(s.color) };
        return out;
    }

    pub noinline fn gradientPaint(p: *Painter, g: *const style.Gradient, tile: Rect, cur: style.Color, tf: Affine) Error!?Paint {
        const w = tile.w;
        const h = tile.h;
        if (!(w > 0) or !(h > 0) or g.stops.len == 0) return null;
        const plain = tf.isIdentity();
        switch (g.kind) {
            .linear => {
                var dx: f32 = 0;
                var dy: f32 = 0;
                if (g.corner_x != 0 or g.corner_y != 0) {
                    dx = @as(f32, @floatFromInt(g.corner_x)) * h;
                    dy = @as(f32, @floatFromInt(g.corner_y)) * w;
                    const nrm = @sqrt(dx * dx + dy * dy);
                    if (!(nrm > 0)) return null;
                    dx /= nrm;
                    dy /= nrm;
                } else {
                    const deg = @mod(g.angle, 360);
                    if (deg == 0) {
                        dy = -1;
                    } else if (deg == 90) {
                        dx = 1;
                    } else if (deg == 180) {
                        dy = 1;
                    } else if (deg == 270) {
                        dx = -1;
                    } else {
                        const sc = rtypes.sinCos(deg * (std.math.pi / 180.0));
                        dx = sc[0];
                        dy = -sc[1];
                    }
                }
                const len = @abs(w * dx) + @abs(h * dy);
                if (!(len > 0)) return null;
                const cx = tile.x + w * 0.5;
                const cy = tile.y + h * 0.5;
                var p0: raster.Point = .{ .x = cx - dx * len * 0.5, .y = cy - dy * len * 0.5 };
                var p1: raster.Point = .{ .x = cx + dx * len * 0.5, .y = cy + dy * len * 0.5 };
                if (!plain) {
                    p0 = tf.apply(p0);
                    p1 = tf.apply(p1);
                }
                return .{ .linear = .{ .p0 = p0, .p1 = p1, .stops = try p.convertStops(g, len, cur), .repeating = g.repeating } };
            },
            .radial => {
                const px = g.position[0].resolve(w);
                const py = g.position[1].resolve(h);
                const dl = @abs(px);
                const dr = @abs(w - px);
                const dt = @abs(py);
                const db = @abs(h - py);
                var rx: f32 = 0;
                var ry: f32 = 0;
                const circle = g.shape == .circle;
                switch (g.extent) {
                    .closest_side => {
                        rx = @min(dl, dr);
                        ry = @min(dt, db);
                        if (circle) {
                            rx = @min(rx, ry);
                            ry = rx;
                        }
                    },
                    .farthest_side => {
                        rx = @max(dl, dr);
                        ry = @max(dt, db);
                        if (circle) {
                            rx = @max(rx, ry);
                            ry = rx;
                        }
                    },
                    .closest_corner => {
                        rx = @min(dl, dr);
                        ry = @min(dt, db);
                        if (circle) {
                            rx = @sqrt(rx * rx + ry * ry);
                            ry = rx;
                        } else {
                            rx *= std.math.sqrt2;
                            ry *= std.math.sqrt2;
                        }
                    },
                    .farthest_corner => {
                        rx = @max(dl, dr);
                        ry = @max(dt, db);
                        if (circle) {
                            rx = @sqrt(rx * rx + ry * ry);
                            ry = rx;
                        } else {
                            rx *= std.math.sqrt2;
                            ry *= std.math.sqrt2;
                        }
                    },
                    .explicit => {
                        rx = g.radius[0].resolve(w);
                        ry = if (circle) rx else g.radius[1].resolve(h);
                    },
                }
                rx = @max(rx, 1.0e-3);
                ry = @max(ry, 1.0e-3);
                return .{ .radial = .{
                    .center = .{ .x = tile.x + px, .y = tile.y + py },
                    .rx = rx,
                    .ry = ry,
                    .stops = try p.convertStops(g, rx, cur),
                    .repeating = g.repeating,
                    .transform = if (plain) null else (tf.invert() orelse return null),
                } };
            },
            .conic => {
                const px = g.position[0].resolve(w);
                const py = g.position[1].resolve(h);
                const mx = @max(@abs(px), @abs(w - px));
                const my = @max(@abs(py), @abs(h - py));
                var c: raster.Point = .{ .x = tile.x + px, .y = tile.y + py };
                if (!plain) c = tf.apply(c);
                return .{ .conic = .{
                    .center = c,
                    .start_angle = g.angle * (std.math.pi / 180.0),
                    .stops = try p.convertStops(g, 360, cur),
                    .repeating = g.repeating,
                    .max_radius = @sqrt(mx * mx + my * my),
                } };
            },
        }
    }

    // ---- images

    /// `ir`: `image-rendering` of the element (pixelated / crisp-edges = nearest-neighbour resize and
    /// sampling, takumi `ImageScalingAlgorithm::Pixelated`).
    pub noinline fn drawImage(p: *Painter, ctx: *const Ctx, pm: *const Pixmap, dest: Rect, ir: style.computed.ImageRendering) void {
        if (!(dest.w > 0) or !(dest.h > 0) or pm.width == 0 or pm.height == 0) return;
        const nearest = ir == .pixelated or ir == .crisp_edges;
        const tw: u32 = @intFromFloat(@min(16384, @max(1, roundHalfUp(dest.w))));
        const th: u32 = @intFromFloat(@min(16384, @max(1, roundHalfUp(dest.h))));
        const src = p.f.r.resampled(pm, tw, th, nearest);
        const sx = dest.w / @as(f32, @floatFromInt(src.width));
        const sy = dest.h / @as(f32, @floatFromInt(src.height));
        const tf = ctx.tf;
        if (nearest and tf.a == 1 and tf.b == 0 and tf.c == 0 and tf.d == 1)
            return raster.drawPixmapNearestRect(ctx.dst, src, tf.e + dest.x, tf.f + dest.y, dest.w, dest.h, ctx.clip);
        const m = tf.mul(Affine.translate(dest.x, dest.y)).mul(Affine.scale(sx, sy));
        raster.drawPixmap(ctx.dst, src, m, 1, if (nearest) .nearest else .bilinear, ctx.clip);
    }

    // ---- background

    const Area = struct { rect: Rect, radii: ?Radii };

    fn area(g: *const Geom, box: anytype) Area {
        return switch (box) {
            .padding_box => .{ .rect = g.padRect(), .radii = g.padRadii() },
            .content_box => .{ .rect = g.contentRect(), .radii = g.contentRadii() },
            else => .{ .rect = g.bx, .radii = g.outerRadii() },
        };
    }

    pub noinline fn paintBackground(p: *Painter, ctx_in: *const Ctx, id: u32, g: *const Geom, x: f32, y: f32) Error!void {
        const cs = p.f.nodes.items[id].cs;
        const col = cs.resolveColor(cs.background_color);
        if (col.a == 0 and cs.background_image.len == 0) return;
        var ctx = ctx_in.*;
        var text_clip = cs.bgColorClip() == .text;
        for (cs.background_clip) |bc| {
            if (bc == .text) text_clip = true;
        }
        if (text_clip) {
            // background-clip: text — the whole background goes through the text coverage.
            const reg = devBounds(ctx.tf, g.bx).intersect(region(&ctx));
            if (reg.isEmpty()) return;
            const m = try ptext.textClipMask(p, &ctx, id, x, y, reg);
            var cm: ClipMask = m.asClip();
            if (ctx.clip) |c| cm = raster.clipIntersect(p.a, c.*, cm) catch return error.OutOfMemory;
            const cp = try p.a.create(ClipMask);
            cp.* = cm;
            ctx.clip = cp;
            if (cm.bounds.isEmpty()) return;
        }
        var blended = false;
        if (comptime enable_effects) for (cs.background_blend_mode) |bm| {
            if (bm != .normal) blended = true;
        };
        if (blended and cs.background_image.len > 0) return p.paintBackgroundBlended(&ctx, cs, g, col);
        if (col.a != 0) {
            const ar = area(g, cs.bgColorClip());
            try p.fillRRect(&ctx, ar.rect, ar.radii, &.{ .solid = rcolor(col) });
        }
        var i = cs.background_image.len;
        while (i > 0) {
            i -= 1;
            const layer = cs.bgLayer(i);
            if (layer.image == .none) continue;
            try p.paintBgLayer(&ctx, cs, g, &layer, true);
        }
    }

    /// background-blend-mode (takumi's "isolated" background): colour and layers are blended with
    /// each other in an offscreen, bottom first, then drawn source-over.
    noinline fn paintBackgroundBlended(p: *Painter, ctx: *const Ctx, cs: *const CS, g: *const Geom, col: style.Color) Error!void {
        const reg = devBounds(ctx.tf, g.bx).intersect(region(ctx));
        if (reg.isEmpty()) return;
        const base = try p.beginLayer(ctx, reg);
        defer p.endLayer();
        const rc = ClipMask.fromRect(reg);
        var lctx: Ctx = .{ .dst = base, .tf = ctx.tf, .clip = &rc };
        if (col.a != 0) {
            const ar = area(g, cs.bgColorClip());
            try p.fillRRect(&lctx, ar.rect, ar.radii, &.{ .solid = rcolor(col) });
        }
        var i = cs.background_image.len;
        while (i > 0) {
            i -= 1;
            const layer = cs.bgLayer(i);
            if (layer.image == .none) continue;
            const mode = pfx.blendMode(cs.background_blend_mode[i % cs.background_blend_mode.len]);
            if (mode == .normal) {
                lctx.dst = base;
                try p.paintBgLayer(&lctx, cs, g, &layer, true);
                continue;
            }
            const top = try p.beginLayer(ctx, reg);
            defer p.endLayer();
            lctx.dst = top;
            try p.paintBgLayer(&lctx, cs, g, &layer, true);
            raster.drawPixmapBlend(base, top, 0, 0, 1, mode, &rc);
        }
        compositeLayer(ctx.dst, base, reg, 1, ctx.clip);
    }

    /// One background / mask image layer (gradient or image tiles) positioned in its origin box
    /// and clipped to its clip box.
    pub noinline fn paintBgLayer(p: *Painter, ctx_in: *const Ctx, cs: *const CS, g: *const Geom, layer: *const style.BgLayer, obscure: bool) Error!void {
        const o = area(g, layer.origin).rect;
        var pa = area(g, layer.clip);
        var ctx_buf = ctx_in.*;
        const ctx = &ctx_buf;
        if (obscure and layer.clip == .border_box) {
            // Blink `ObscuredBorderOutsets`: an opaque, gap-free border side hides the background, so
            // image layers are not painted under it (no colour bleeding at the outer edge).
            var ins: [4]f32 = .{ 0, 0, 0, 0 };
            var any = false;
            for (0..4) |i| {
                const st = cs.border_style[i];
                const w = g.bw[i];
                if (!(w > 0) or cs.resolveColor(cs.border_color[i]).a != 255) continue;
                const eff: style.computed.BorderStyle = if (st == .double and w < 3) .solid else st;
                if (eff == .hidden or eff == .none or eff == .dotted or eff == .dashed or eff == .double) continue;
                ins[i] = w;
                any = true;
            }
            if (any) {
                const inner = insetRect(pa.rect, ins[0], ins[1], ins[2], ins[3]);
                if (!(inner.w > 0) or !(inner.h > 0)) return;
                if (pa.radii != null) ctx_buf.clip = try p.makeClip(ctx_in, pa.rect, pa.radii);
                pa = .{ .rect = inner, .radii = null };
            }
        }
        if (!(o.w > 0) or !(o.h > 0)) return;

        var iw: f32 = 0;
        var ih: f32 = 0;
        var pm: ?*const Pixmap = null;
        var svg_src: ?[]const u8 = null;
        if (layer.image == .url) {
            if (p.f.r.resolveImage(layer.image.url)) |im| {
                pm = im;
                iw = @as(f32, @floatFromInt(im.width)) * p.f.opts.dpr;
                ih = @as(f32, @floatFromInt(im.height)) * p.f.opts.dpr;
            } else if (psvg.urlSvgSource(p, layer.image.url)) |src| {
                svg_src = src;
                const sz = psvg.intrinsic(p, src, o.w, o.h);
                iw = sz[0];
                ih = sz[1];
            } else return;
            if (!(iw > 0) or !(ih > 0)) return;
        }
        const has_img = pm != null or svg_src != null;
        var tw: f32 = o.w;
        var th: f32 = o.h;
        switch (layer.size) {
            .cover, .contain => if (has_img) {
                const sx = o.w / iw;
                const sy = o.h / ih;
                const s = if (layer.size == .cover) @max(sx, sy) else @min(sx, sy);
                tw = iw * s;
                th = ih * s;
            },
            .size => |sz| {
                const a0: ?f32 = if (sz[0] == .lp) sz[0].lp.resolve(o.w) else null;
                const a1: ?f32 = if (sz[1] == .lp) sz[1].lp.resolve(o.h) else null;
                if (a0 == null and a1 == null) {
                    if (has_img) {
                        tw = iw;
                        th = ih;
                    }
                } else if (a0 != null and a1 != null) {
                    tw = a0.?;
                    th = a1.?;
                } else if (a0) |v| {
                    tw = v;
                    th = if (has_img) v * ih / iw else o.h;
                } else {
                    th = a1.?;
                    tw = if (has_img) th * iw / ih else o.w;
                }
            },
        }
        if (!(tw > 0) or !(th > 0)) return;
        const tx = o.x + layer.position[0].resolve(o.w - tw);
        const ty = o.y + layer.position[1].resolve(o.h - th);
        const rep_x = layer.repeat[0] != .no_repeat;
        const rep_y = layer.repeat[1] != .no_repeat;

        // The clip box sticks out of the positioning area (e.g. border-box clip, padding-box origin):
        // the tile repeats into the border area.
        const inside = pa.rect.x >= o.x and pa.rect.y >= o.y and pa.rect.x + pa.rect.w <= o.x + o.w and pa.rect.y + pa.rect.h <= o.y + o.h;
        if (layer.image == .gradient and tw == o.w and th == o.h and tx == o.x and ty == o.y and (inside or (!rep_x and !rep_y))) {
            // Single tile covering the positioning area (the overwhelmingly common case).
            const pt = (try p.gradientPaint(layer.image.gradient, o, cs.color, ctx.tf)) orelse return;
            if (rep_x and rep_y) {
                try p.fillRRect(ctx, pa.rect, pa.radii, &pt);
            } else {
                var c2 = ctx.*;
                c2.clip = try p.makeClip(ctx, pa.rect, pa.radii);
                try p.fillRRect(&c2, o, null, &pt);
            }
            return;
        }

        var c2 = ctx.*;
        c2.clip = try p.makeClip(ctx, pa.rect, pa.radii);
        var px0 = pa.rect.x;
        var py0 = pa.rect.y;
        var px1 = pa.rect.x + pa.rect.w;
        var py1 = pa.rect.y + pa.rect.h;
        {
            // only the tiles that can reach the visible region (its bounds mapped back into the box's space):
            // a huge clip box would otherwise spend the tile budget far off-canvas
            const reg = region(&c2);
            if (reg.isEmpty()) return;
            const inv = ctx.tf.invert() orelse return;
            const rx0: f32 = @floatFromInt(reg.x);
            const ry0: f32 = @floatFromInt(reg.y);
            const rx1: f32 = rx0 + @as(f32, @floatFromInt(reg.w));
            const ry1: f32 = ry0 + @as(f32, @floatFromInt(reg.h));
            var vx0: f32 = std.math.floatMax(f32);
            var vy0: f32 = vx0;
            var vx1: f32 = -vx0;
            var vy1: f32 = -vx0;
            for ([4]raster.Point{ .{ .x = rx0, .y = ry0 }, .{ .x = rx1, .y = ry0 }, .{ .x = rx1, .y = ry1 }, .{ .x = rx0, .y = ry1 } }) |q| {
                const l = inv.apply(q);
                vx0 = @min(vx0, l.x);
                vy0 = @min(vy0, l.y);
                vx1 = @max(vx1, l.x);
                vy1 = @max(vy1, l.y);
            }
            if (!(vx1 >= vx0) or !(vy1 >= vy0)) return;
            px0 = @max(px0, vx0 - 1);
            py0 = @max(py0, vy0 - 1);
            px1 = @min(px1, vx1 + 1);
            py1 = @min(py1, vy1 + 1);
            if (!(px1 > px0) or !(py1 > py0)) return;
        }
        var yy = if (rep_y) ty - @ceil((ty - py0) / th) * th else ty;
        var count: u32 = 0;
        while (yy < py1 and count < 20000) : (yy += th) {
            var xx = if (rep_x) tx - @ceil((tx - px0) / tw) * tw else tx;
            while (xx < px1 and count < 20000) : (xx += tw) {
                count += 1;
                const tile: Rect = .{ .x = xx, .y = yy, .w = tw, .h = th };
                if (pm) |im| {
                    p.drawImage(&c2, im, tile, cs.image_rendering);
                } else if (svg_src) |src| {
                    try psvg.paintSvg(p, &c2, src, tile, cs.color);
                } else {
                    const pt = (try p.gradientPaint(layer.image.gradient, tile, cs.color, ctx.tf)) orelse break;
                    try p.fillRRect(&c2, tile, null, &pt);
                }
                if (!rep_x) break;
            }
            if (!rep_y) break;
        }
    }

    // ---- shadows

    pub fn tfScale(tf: Affine) f32 {
        const det = @abs(tf.a * tf.d - tf.b * tf.c);
        return if (det > 0) @sqrt(det) else 1;
    }

    pub noinline fn paintOuterShadows(p: *Painter, ctx: *const Ctx, cs: *const CS, g: *const Geom) Error!void {
        var i = cs.box_shadow.len;
        while (i > 0) {
            i -= 1;
            const sh = cs.box_shadow[i];
            if (sh.inset) continue;
            const col = cs.resolveColor(sh.color);
            if (col.a == 0) continue;
            const r: Rect = .{ .x = g.bx.x + sh.x - sh.spread, .y = g.bx.y + sh.y - sh.spread, .w = g.bx.w + 2 * sh.spread, .h = g.bx.h + 2 * sh.spread };
            if (!(r.w > 0) or !(r.h > 0)) continue;
            const radii: ?Radii = if (g.rounded) spreadRadii(g.radii, sh.spread) else null;
            const sigma = sh.blur * 0.5 * tfScale(ctx.tf);
            const reach = raster.blurReach(sigma);
            const visible = region(ctx);
            if (visible.isEmpty()) continue;
            var mask = try p.rrectMask(ctx, r, radii, visible.expand(reach));
            if (mask.bounds.isEmpty()) continue;
            raster.blurMaskClipped(p.a, &mask, sigma, visible) catch return error.OutOfMemory;
            if (mask.bounds.isEmpty()) continue;
            // Clip the shadow out of the border box.
            if (!g.rounded and ctx.plain()) {
                const hole = toIRect(g.bx).intersect(mask.bounds);
                if (!hole.isEmpty()) {
                    var yy: u32 = 0;
                    while (yy < hole.h) : (yy += 1) {
                        const row: usize = @intCast(@as(i64, hole.y) + yy - mask.bounds.y);
                        const col0: usize = @intCast(@as(i64, hole.x) - mask.bounds.x);
                        @memset(mask.data[row * mask.bounds.w + col0 ..][0..hole.w], 0);
                    }
                }
            } else {
                const box = try p.rrectMask(ctx, g.bx, g.outerRadii(), mask.bounds);
                const bb = box.bounds;
                var yy: u32 = 0;
                while (yy < bb.h) : (yy += 1) {
                    const row: usize = @intCast(@as(i64, bb.y) + yy - mask.bounds.y);
                    const col0: usize = @intCast(@as(i64, bb.x) - mask.bounds.x);
                    const dstrow = mask.data[row * mask.bounds.w + col0 ..][0..bb.w];
                    const srow = box.data[@as(usize, yy) * bb.w ..][0..bb.w];
                    for (dstrow, srow) |*d, s| d.* = @intCast(raster.div255(@as(u32, d.*) * (255 - @as(u32, s))));
                }
            }
            raster.fillMask(ctx.dst, &mask, &.{ .solid = rcolor(col) }, ctx.clip);
        }
    }

    pub noinline fn paintInsetShadows(p: *Painter, ctx: *const Ctx, cs: *const CS, g: *const Geom) Error!void {
        var any = false;
        for (cs.box_shadow) |sh| {
            if (sh.inset) any = true;
        }
        if (!any) return;
        const pr = g.padRect();
        if (!(pr.w > 0) or !(pr.h > 0)) return;
        const prad = g.padRadii();
        const clip = try p.makeClip(ctx, pr, prad);
        // Device-space bounds of the padding box.
        var pb: IRect = undefined;
        if (ctx.plain()) {
            pb = toIRect(pr).intersect(region(ctx));
        } else {
            pb = clip.bounds;
        }
        if (pb.isEmpty()) return;
        var i = cs.box_shadow.len;
        while (i > 0) {
            i -= 1;
            const sh = cs.box_shadow[i];
            if (!sh.inset) continue;
            const col = cs.resolveColor(sh.color);
            if (col.a == 0) continue;
            const sigma = sh.blur * 0.5 * tfScale(ctx.tf);
            const reach = raster.blurReach(sigma);
            const within = pb.expand(reach + 1);
            const r: Rect = .{ .x = pr.x + sh.x + sh.spread, .y = pr.y + sh.y + sh.spread, .w = pr.w - 2 * sh.spread, .h = pr.h - 2 * sh.spread };
            var shape: raster.Mask = raster.Mask.empty;
            if (r.w > 0 and r.h > 0) {
                const radii: ?Radii = if (prad) |rr| spreadRadii(rr, -sh.spread) else null;
                shape = try p.rrectMask(ctx, r, radii, within);
            }
            var inv = raster.maskInvertWithin(p.a, &shape, within) catch return error.OutOfMemory;
            raster.blurMaskClipped(p.a, &inv, sigma, pb) catch return error.OutOfMemory;
            raster.fillMask(ctx.dst, &inv, &.{ .solid = rcolor(col) }, clip);
        }
    }

    // ---- layers

    /// Device-space integer bounds of `r` under `tf`.
    pub fn devBounds(tf: Affine, r: Rect) IRect {
        if (tf.isIdentity()) return toIRect(r);
        var x0: f32 = std.math.floatMax(f32);
        var y0: f32 = x0;
        var x1: f32 = -x0;
        var y1: f32 = -x0;
        const cs = [4]raster.Point{ .{ .x = r.x, .y = r.y }, .{ .x = r.x + r.w, .y = r.y }, .{ .x = r.x + r.w, .y = r.y + r.h }, .{ .x = r.x, .y = r.y + r.h } };
        for (cs) |c| {
            const q = tf.apply(c);
            x0 = @min(x0, q.x);
            y0 = @min(y0, q.y);
            x1 = @max(x1, q.x);
            y1 = @max(y1, q.y);
        }
        if (!(x1 >= x0) or !(y1 >= y0)) return IRect.empty;
        return toIRect(.{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 });
    }

    /// Hands out the canvas-sized offscreen layer of the current nesting level with `reg` cleared
    /// to transparent. `reg` must lie inside the canvas. Pair with `endLayer`.
    pub noinline fn beginLayer(p: *Painter, ctx: *const Ctx, reg_in: IRect) Error!*Pixmap {
        const reg = reg_in.intersect(ctx.dst.bounds());
        if (p.layer_depth >= p.layers.items.len) {
            const lp = try p.a.create(Pixmap);
            const data = p.a.alloc(u8, ctx.dst.data.len) catch return error.OutOfMemory;
            lp.* = .{ .width = ctx.dst.width, .height = ctx.dst.height, .data = data };
            try p.layers.append(p.a, lp);
        }
        const layer = p.layers.items[p.layer_depth];
        p.layer_depth += 1;
        const stride = @as(usize, layer.width) * 4;
        if (!reg.isEmpty()) {
            var row: usize = @intCast(reg.y);
            const row_end = row + reg.h;
            while (row < row_end) : (row += 1) {
                const off = row * stride + @as(usize, @intCast(reg.x)) * 4;
                @memset(layer.data[off..][0 .. @as(usize, reg.w) * 4], 0);
            }
        }
        return layer;
    }

    pub fn endLayer(p: *Painter) void {
        p.layer_depth -= 1;
    }

    // ---- nodes

    fn localTransform(cs: *const CS, x: f32, y: f32, w: f32, h: f32) ?Affine {
        const has = cs.offset_path != null or cs.transform.len > 0 or cs.rotate != 0 or cs.scale[0] != 1 or cs.scale[1] != 1 or cs.translate[0].px != 0 or cs.translate[0].pct != 0 or cs.translate[1].px != 0 or cs.translate[1].pct != 0 or cs.translate[0].calc != null or cs.translate[1].calc != null;
        if (!has) return null;
        const d2r: f32 = std.math.pi / 180.0;
        const ox = x + cs.transform_origin[0].resolve(w);
        const oy = y + cs.transform_origin[1].resolve(h);
        var m = Affine.translate(ox, oy);
        m = m.mul(Affine.translate(cs.translate[0].resolve(w), cs.translate[1].resolve(h)));
        if (cs.rotate != 0) m = m.mul(Affine.rotate(cs.rotate * d2r));
        if (cs.scale[0] != 1 or cs.scale[1] != 1) m = m.mul(Affine.scale(cs.scale[0], cs.scale[1]));
        if (@import("style/motion_path.zig").transform(cs, w, h)) |motion| m = m.mul(motion);
        for (cs.transform) |op| {
            const t: Affine = switch (op) {
                .translate => |v| Affine.translate(v[0].resolve(w), v[1].resolve(h)),
                .scale => |v| Affine.scale(v[0], v[1]),
                .rotate => |deg| Affine.rotate(deg * d2r),
                .skew => |v| Affine.skew(v[0] * d2r, v[1] * d2r),
                .matrix => |v| .{ .a = v[0], .b = v[1], .c = v[2], .d = v[3], .e = v[4], .f = v[5] },
            };
            m = m.mul(t);
        }
        m = m.mul(Affine.translate(-ox, -oy));
        if (!m.isFinite()) return null;
        return m;
    }

    fn unionRect(a: Rect, b: Rect) Rect {
        if (!(a.w > 0) or !(a.h > 0)) return b;
        if (!(b.w > 0) or !(b.h > 0)) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.w, b.x + b.w);
        const y1 = @max(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// `r` grown by `pad` local px on every side, as device-space bounds under `tf`. `smax` = the
    /// largest stretch of `tf` (>= `tfScale`), so both local ink (text overhang, outlines) and
    /// device-isotropic ink (blurred shadows: sigma * tfScale) are covered.
    fn devRectF(tf: *const Affine, smax: f32, r: Rect, pad: f32) Rect {
        if (tf.isIdentity()) return .{ .x = r.x - pad, .y = r.y - pad, .w = r.w + 2 * pad, .h = r.h + 2 * pad };
        var x0: f32 = std.math.floatMax(f32);
        var y0: f32 = x0;
        var x1: f32 = -x0;
        var y1: f32 = -x0;
        const cs = [4]raster.Point{ .{ .x = r.x, .y = r.y }, .{ .x = r.x + r.w, .y = r.y }, .{ .x = r.x + r.w, .y = r.y + r.h }, .{ .x = r.x, .y = r.y + r.h } };
        for (cs) |c| {
            const q = tf.apply(c);
            x0 = @min(x0, q.x);
            y0 = @min(y0, q.y);
            x1 = @max(x1, q.x);
            y1 = @max(y1, q.y);
        }
        const e = pad * smax + 1;
        return .{ .x = x0 - e, .y = y0 - e, .w = x1 - x0 + 2 * e, .h = y1 - y0 + 2 * e };
    }

    /// Largest singular value of the linear part of `tf` (how much it can stretch a length).
    fn tfStretch(tf: *const Affine) f32 {
        if (tf.isTranslateOnly()) return 1;
        const s = tf.a * tf.a + tf.b * tf.b + tf.c * tf.c + tf.d * tf.d;
        const det = tf.a * tf.d - tf.b * tf.c;
        const disc = @sqrt(@max(0, s * s - 4 * det * det));
        return @sqrt(@max(0, (s + disc) * 0.5));
    }

    /// How far the filters of `cs` spread ink, in device px at transform scale `scale`.
    fn filterReach(cs: *const CS, scale: f32) f32 {
        var reach: f32 = 0;
        for (cs.filter) |fl| switch (fl) {
            .blur => |r| reach += @floatFromInt(raster.blurReach(r * scale)),
            .drop_shadow => |sh| reach += (@ceil(3 * sh.blur) + @max(@abs(sh.x), @abs(sh.y)) + 1) * scale,
            else => {},
        };
        return reach;
    }

    /// Conservative visual bounds, in device space, of a subtree whose border box origin is (x, y)
    /// in the space of `tf`; null = unknown. Transformed descendants are followed with their own
    /// matrix (composed as `paintNode` does), filtered descendants grow by their filters' reach.
    fn subtreeBounds(p: *Painter, id: u32, x: f32, y: f32, tf: *const Affine, depth: u32) ?Rect {
        const f = p.f;
        const n = &f.nodes.items[id];
        const cs = n.cs;
        const l = f.tree.layout(n.lid);
        if (depth > 600) return null;
        const smax = tfStretch(tf);
        if (!std.math.isFinite(smax)) return null;
        const box: Rect = .{ .x = x, .y = y, .w = l.w, .h = l.h };
        var r: Rect = devRectF(tf, smax, box, 0);
        if (n.kind == .anon_text or n.kind == .text or n.para != null) {
            var m = cs.font_size + cs.webkit_text_stroke_width;
            for (cs.text_shadow) |sh| m = @max(m, cs.font_size + @max(@abs(sh.x), @abs(sh.y)) + @ceil(sh.blur * 1.5) + 2);
            // text may overflow its box (nowrap, an unbreakable word, more lines than the box is
            // tall), to either side depending on the alignment: the laid out size decides
            var tb = box;
            const cw = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
            const ch = l.h - l.border.top - l.border.bottom - l.padding.top - l.padding.bottom;
            if (f.textLayout(id, cw) catch return null) |tl| {
                const ox = @max(0, tl.width - cw);
                const oy = @max(0, tl.height - ch);
                tb = .{ .x = x - ox, .y = y - oy, .w = l.w + 2 * ox, .h = l.h + 2 * oy };
            }
            r = devRectF(tf, smax, tb, m);
        }
        if (n.kind == .anon_text) return r;
        if (cs.display == .none) return .{ .x = x, .y = y, .w = 0, .h = 0 };
        for (cs.box_shadow) |sh| {
            if (sh.inset) continue;
            const e = @max(0, sh.spread) + @ceil(sh.blur * 1.5) + 2;
            r = unionRect(r, devRectF(tf, smax, .{ .x = x + sh.x, .y = y + sh.y, .w = l.w, .h = l.h }, e));
        }
        if (cs.outline_style != .none and cs.outline_style != .hidden) {
            const e = @max(0, @abs(cs.outline_offset) + cs.outline_width) + 1;
            r = unionRect(r, devRectF(tf, smax, box, e));
        }
        if (cs.overflow_x != .visible and cs.overflow_y != .visible) return r;
        var c = n.first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            const cn = &f.nodes.items[c];
            const cl = f.tree.layout(cn.lid);
            var ctf = tf;
            var composed: Affine = undefined;
            if (cn.kind != .anon_text) {
                if (localTransform(cn.cs, x + cl.x, y + cl.y, cl.w, cl.h)) |m| {
                    composed = tf.mul(m);
                    if (!composed.isFinite()) return null;
                    if (composed.invert() == null) continue; // not painted (paintNode)
                    ctf = &composed;
                }
            }
            var cb = p.subtreeBounds(c, x + cl.x, y + cl.y, ctf, depth + 1) orelse return null;
            if (cn.kind != .anon_text and cn.cs.filter.len > 0 and cb.w > 0 and cb.h > 0) {
                // a filtered group of its own: its ink spreads by the filters' reach
                const fr = filterReach(cn.cs, tfScale(ctf.*)) + 2;
                cb = .{ .x = cb.x - fr, .y = cb.y - fr, .w = cb.w + 2 * fr, .h = cb.h + 2 * fr };
            }
            r = unionRect(r, cb);
        }
        return r;
    }

    fn paintNode(p: *Painter, id: u32, ox: f32, oy: f32, ctx_in: *const Ctx, depth: u32) Error!void {
        const f = p.f;
        const n = &f.nodes.items[id];
        const cs = n.cs;
        if (n.kind != .anon_text and cs.display == .none) return;
        if (depth > 600) return;
        if (enable_tables and id < p.tparts.len and p.tparts[id].hidden) return;
        if (enable_floats and cs.float != .none and n.kind != .anon_text and id != p.float_now and id != f.root and !stacks(cs)) {
            return p.enqueue(&p.float_q, id, ox, oy, ctx_in, depth, 0, false);
        }
        if (n.kind != .anon_text and id != p.pos_now and id != f.root and stacks(cs)) {
            // positioned boxes and stacking contexts: after the in-flow content of the stacking context
            const z: i64 = cs.z_index orelse 0;
            if (z >= 0) return p.enqueue(if (z > 0) &p.zpos_q else &p.pos_q, id, ox, oy, ctx_in, depth, @intCast(std.math.clamp(z, 0, 0x7fffffff)), false);
        }
        const l = f.tree.layout(n.lid);
        var x = ox + l.x;
        var y = oy + l.y;
        if (n.kind == .anon_text) return p.paintBox(id, x, y, ctx_in, depth);
        var ctx = ctx_in.*;
        if (localTransform(cs, x, y, l.w, l.h)) |m| {
            if (m.isTranslateOnly() and ctx.plain()) {
                x += m.e;
                y += m.f;
            } else {
                ctx.tf = ctx.tf.mul(m);
                if (ctx.tf.invert() == null) return;
            }
        }
        if (!(cs.opacity > 0)) return;
        if (pfx.needsGroup(cs)) return p.paintGroup(id, x, y, &ctx, depth);
        try p.paintBox(id, x, y, &ctx, depth);
    }

    /// The element as an offscreen group (takumi `EffectKind::Group` + `Filter`): content ->
    /// filter -> combined coverage (ancestor clips ∩ clip-path ∩ mask-image) -> opacity + blend.
    noinline fn paintGroup(p: *Painter, id: u32, x: f32, y: f32, ctx: *const Ctx, depth: u32) Error!void {
        const f = p.f;
        const n = &f.nodes.items[id];
        const cs = n.cs;
        const l = f.tree.layout(n.lid);
        const scale = tfScale(ctx.tf);
        var reg = region(ctx);
        const reach = filterReach(cs, scale);
        if (p.subtreeBounds(id, x, y, &ctx.tf, 0)) |b| {
            // (a non-finite rect or reach keeps the whole clip region)
            if (std.math.isFinite(b.x + b.y + b.w + b.h) and std.math.isFinite(reach)) reg = reg.intersect(toIRect(b).expand(2 + @as(u32, @intFromFloat(std.math.clamp(reach, 0, 65536)))));
        }
        if (reg.isEmpty()) return;
        const g = geomOf(cs, l, x, y, ctx);
        var comp = ClipMask.fromRect(reg);
        if (ctx.clip) |c| comp = raster.clipIntersect(p.a, c.*, comp) catch return error.OutOfMemory;
        if (comptime enable_effects) if (cs.clip_path) |cp| {
            if (try pfx.clipPathMask(p, ctx, cp, cs, .{ .x = x, .y = y, .w = l.w, .h = l.h }, &g, reg)) |m| comp = try pfx.clipAnd(p, comp, &m);
        };
        if (pfx.hasMask(cs)) {
            const m = try pfx.maskImageMask(p, ctx, cs, &g, reg);
            comp = try pfx.clipAnd(p, comp, &m);
            if (g.rounded) {
                const rm = try p.rrectMask(ctx, g.bx, g.radii, reg);
                comp = try pfx.clipAnd(p, comp, &rm);
            }
        }
        if (comp.bounds.isEmpty()) return;
        const mark = p.outlines.items.len;
        const layer = try p.beginLayer(ctx, reg);
        defer p.endLayer();
        const reg_clip = ClipMask.fromRect(reg);
        var lctx: Ctx = .{ .dst = layer, .tf = ctx.tf, .clip = &reg_clip };
        if ((comptime enable_effects) and cs.backdrop_filter.len > 0) {
            try pfx.backdrop(p, ctx, cs, &g, layer, reg);
            const content = try p.beginLayer(ctx, reg);
            defer p.endLayer();
            lctx.dst = content;
            try p.paintBox(id, x, y, &lctx, depth);
            try p.flushOutlines(mark, content);
            compositeLayer(layer, content, reg, 1, null);
        } else {
            try p.paintBox(id, x, y, &lctx, depth);
            try p.flushOutlines(mark, layer);
        }
        if (cs.filter.len > 0) {
            // Filters run on a copy of the group region.
            var sub = Pixmap.init(p.a, reg.w, reg.h) catch return error.OutOfMemory;
            const stride = @as(usize, layer.width) * 4;
            const rb = @as(usize, reg.w) * 4;
            var ry: usize = 0;
            while (ry < reg.h) : (ry += 1) {
                const off = (@as(usize, @intCast(reg.y)) + ry) * stride + @as(usize, @intCast(reg.x)) * 4;
                @memcpy(sub.data[ry * rb ..][0..rb], layer.data[off..][0..rb]);
            }
            try p.applyFilters(&sub, cs.filter, cs, scale, false);
            ry = 0;
            while (ry < reg.h) : (ry += 1) {
                const off = (@as(usize, @intCast(reg.y)) + ry) * stride + @as(usize, @intCast(reg.x)) * 4;
                @memcpy(layer.data[off..][0..rb], sub.data[ry * rb ..][0..rb]);
            }
        }
        const mode: raster.BlendMode = if (comptime enable_effects) pfx.blendMode(cs.mix_blend_mode) else .normal;
        const op = @min(cs.opacity, 1);
        if (mode == .normal) {
            compositeLayer(ctx.dst, layer, reg, op, &comp);
        } else raster.drawPixmapBlend(ctx.dst, layer, 0, 0, op, mode, &comp);
    }

    const Deferred = struct { cs: *const CS, g: Geom, tf: Affine, clip: ?*const ClipMask };

    /// Paints the outlines deferred since `mark` (takumi paints a stacking context's outlines
    /// after all of its other phases).
    pub noinline fn flushOutlines(p: *Painter, mark: usize, dst: *Pixmap) Error!void {
        var i = mark;
        while (i < p.outlines.items.len) : (i += 1) {
            const d = p.outlines.items[i];
            try pborder.paintOutline(p, &.{ .dst = dst, .tf = d.tf, .clip = d.clip }, d.cs, &d.g);
        }
        p.outlines.shrinkRetainingCapacity(mark);
    }

    /// CSS filter functions on a premultiplied pixmap.
    pub noinline fn applyFilters(p: *Painter, pm: *Pixmap, filters: []const style.Filter, cs: *const CS, scale: f32, is_backdrop: bool) Error!void {
        for (filters) |fl| {
            // colour matrix rows (r, g, b) + offset, applied to straight colour; alpha factor
            var m: [3][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } };
            var alpha: f32 = 1;
            switch (fl) {
                .blur => |r| {
                    raster.blurPixmap(p.a, pm, r * scale) catch return error.OutOfMemory;
                    continue;
                },
                .drop_shadow => |sh| {
                    if (!is_backdrop) try pfx.dropShadow(p, pm, sh, cs.resolveColor(sh.color), scale);
                    continue;
                },
                .opacity => |a| alpha = std.math.clamp(a, 0, 1),
                .brightness => |b| m = .{ .{ b, 0, 0, 0 }, .{ 0, b, 0, 0 }, .{ 0, 0, b, 0 } },
                .contrast => |c| {
                    const o = 0.5 - 0.5 * c;
                    m = .{ .{ c, 0, 0, o }, .{ 0, c, 0, o }, .{ 0, 0, c, o } };
                },
                .invert => |a_in| {
                    const a = std.math.clamp(a_in, 0, 1);
                    const k = 1 - 2 * a;
                    m = .{ .{ k, 0, 0, a }, .{ 0, k, 0, a }, .{ 0, 0, k, a } };
                },
                .grayscale => |a_in| {
                    const t = 1 - std.math.clamp(a_in, 0, 1);
                    m = .{
                        .{ 0.2126 + 0.7874 * t, 0.7152 - 0.7152 * t, 0.0722 - 0.0722 * t, 0 },
                        .{ 0.2126 - 0.2126 * t, 0.7152 + 0.2848 * t, 0.0722 - 0.0722 * t, 0 },
                        .{ 0.2126 - 0.2126 * t, 0.7152 - 0.7152 * t, 0.0722 + 0.9278 * t, 0 },
                    };
                },
                .sepia => |a_in| {
                    const t = 1 - std.math.clamp(a_in, 0, 1);
                    m = .{
                        .{ 0.393 + 0.607 * t, 0.769 - 0.769 * t, 0.189 - 0.189 * t, 0 },
                        .{ 0.349 - 0.349 * t, 0.686 + 0.314 * t, 0.168 - 0.168 * t, 0 },
                        .{ 0.272 - 0.272 * t, 0.534 - 0.534 * t, 0.131 + 0.869 * t, 0 },
                    };
                },
                .saturate => |sv| m = .{
                    .{ 0.213 + 0.787 * sv, 0.715 - 0.715 * sv, 0.072 - 0.072 * sv, 0 },
                    .{ 0.213 - 0.213 * sv, 0.715 + 0.285 * sv, 0.072 - 0.072 * sv, 0 },
                    .{ 0.213 - 0.213 * sv, 0.715 - 0.715 * sv, 0.072 + 0.928 * sv, 0 },
                },
                .hue_rotate => |deg| {
                    const sc = rtypes.sinCos(deg * (std.math.pi / 180.0));
                    const sn = sc[0];
                    const cn = sc[1];
                    m = .{
                        .{ 0.213 + cn * 0.787 - sn * 0.213, 0.715 - cn * 0.715 - sn * 0.715, 0.072 - cn * 0.072 + sn * 0.928, 0 },
                        .{ 0.213 - cn * 0.213 + sn * 0.143, 0.715 + cn * 0.285 + sn * 0.140, 0.072 - cn * 0.072 - sn * 0.283, 0 },
                        .{ 0.213 - cn * 0.213 - sn * 0.787, 0.715 - cn * 0.715 + sn * 0.715, 0.072 + cn * 0.928 + sn * 0.072, 0 },
                    };
                },
            }
            var i: usize = 0;
            const d = pm.data;
            while (i + 4 <= d.len) : (i += 4) {
                const a8 = d[i + 3];
                if (a8 == 0) continue;
                const af = @as(f32, @floatFromInt(a8));
                const inv = 1.0 / af;
                const r0 = @as(f32, @floatFromInt(d[i])) * inv;
                const g0 = @as(f32, @floatFromInt(d[i + 1])) * inv;
                const b0 = @as(f32, @floatFromInt(d[i + 2])) * inv;
                const na = af * alpha;
                inline for (0..3) |k| {
                    const v = std.math.clamp(m[k][0] * r0 + m[k][1] * g0 + m[k][2] * b0 + m[k][3], 0, 1);
                    d[i + k] = @intFromFloat(v * na + 0.5);
                }
                d[i + 3] = @intFromFloat(na + 0.5);
            }
        }
    }

    pub fn geomOf(cs: *const CS, l: anytype, x: f32, y: f32, ctx: *const Ctx) Geom {
        var g: Geom = .{
            .bx = if (ctx.plain()) snapRect(x, y, l.w, l.h) else .{ .x = x, .y = y, .w = l.w, .h = l.h },
            .bw = .{ l.border.top, l.border.right, l.border.bottom, l.border.left },
            .pad = .{ l.padding.top, l.padding.right, l.padding.bottom, l.padding.left },
            .radii = undefined,
            .rounded = false,
            .snapped = ctx.plain(),
            .raw = if (ctx.plain()) .{ .x = x, .y = y, .w = l.w, .h = l.h } else null,
        };
        g.radii = resolveRadii(cs, g.bx.w, g.bx.h);
        g.rounded = hasRadii(g.radii);
        return g;
    }

    noinline fn paintImage(p: *Painter, ctx: *const Ctx, n: *const Node, g: *const Geom) Error!void {
        const cs = n.cs;
        const cr = g.contentRect();
        if (!(cr.w > 0) or !(cr.h > 0)) return;
        const svg_src = psvg.nodeSvgSource(n);
        const pmx = n.img;
        if (pmx == null and svg_src == null) return;
        const iw = n.img_w;
        const ih = n.img_h;
        var dw = cr.w;
        var dh = cr.h;
        if (iw > 0 and ih > 0) {
            const sx = cr.w / iw;
            const sy = cr.h / ih;
            switch (cs.object_fit) {
                .fill => {},
                .contain => {
                    const s = @min(sx, sy);
                    dw = iw * s;
                    dh = ih * s;
                },
                .cover => {
                    const s = @max(sx, sy);
                    dw = iw * s;
                    dh = ih * s;
                },
                .none => {
                    dw = iw;
                    dh = ih;
                },
                .scale_down => {
                    const s = @min(1, @min(sx, sy));
                    dw = iw * s;
                    dh = ih * s;
                },
            }
        }
        const dx = cr.x + cs.object_position[0].resolve(cr.w - dw);
        const dy = cr.y + cs.object_position[1].resolve(cr.h - dh);
        const crad = g.contentRadii();
        const overflow = dx < cr.x or dy < cr.y or dx + dw > cr.x + cr.w or dy + dh > cr.y + cr.h;
        var c2 = ctx.*;
        if (crad != null or overflow or svg_src != null) c2.clip = try p.makeClip(ctx, cr, crad);
        const dest: Rect = .{ .x = dx, .y = dy, .w = dw, .h = dh };
        if (svg_src) |src| {
            try psvg.paintSvg(p, &c2, src, dest, cs.color);
        } else p.drawImage(&c2, pmx.?, dest, cs.image_rendering);
    }

    fn paintBox(p: *Painter, id: u32, x: f32, y: f32, ctx: *const Ctx, depth: u32) Error!void {
        const f = p.f;
        const n = &f.nodes.items[id];
        const cs = n.cs;
        const l = f.tree.layout(n.lid);
        if (n.kind == .anon_text) {
            // inline content: after the floats of the box that is painted atomically
            return p.enqueue(&p.text_q, id, x, y, ctx, depth, 0, true);
        }
        const marks: [4]usize = .{ p.float_q.items.len, p.text_q.items.len, p.pos_q.items.len, p.zpos_q.items.len };

        const g = geomOf(cs, l, x, y, ctx);

        // a table, or a part of the table painted around it, paints its decorations as one
        var tg: ?*const ptable.TG = null;
        var as_part = false;
        if (enable_tables) {
            tg = f.tree.tableGeom(n.lid);
            if (tg != null or p.tparts.len != 0) as_part = try ptable.decorations(p, ctx, id, x, y, &g, tg);
        }
        if (cs.visibility == .visible) {
            if (!as_part) {
                if (cs.box_shadow.len > 0) try p.paintOuterShadows(ctx, cs, &g);
                try p.paintBackground(ctx, id, &g, x, y);
                if (cs.box_shadow.len > 0) try p.paintInsetShadows(ctx, cs, &g);
                try pborder.paintBorder(p, ctx, cs, &g);
            }
            if (cs.outline_style != .none and cs.outline_style != .hidden) {
                try p.outlines.append(p.a, .{ .cs = cs, .g = g, .tf = ctx.tf, .clip = ctx.clip });
            }
            if (n.kind == .image) try p.paintImage(ctx, n, &g);
        }
        // (an anonymous inline formatting context: its text, then its inline-level boxes)
        // (overflow clips the element's own text too, as in takumi: text-overflow: clip — the queued
        // text carries the clipped context; nothing inside an empty clip is painted or queued, but the
        // scope still ends and the collapsed borders still follow)
        const has_text = n.kind == .text or (n.kind == .anon_box and n.para != null);
        if (has_text or n.first_child != none) children: {
            var cctx = ctx.*;
            if (cs.overflow_x != .visible or cs.overflow_y != .visible) {
                cctx.clip = try p.makeClip(ctx, g.overflowRect(), g.padRadii());
                if (cctx.clip.?.bounds.isEmpty()) break :children;
            }
            if (has_text) try p.enqueue(&p.text_q, id, x, y, &cctx, depth, 0, true);
            if (n.first_child == none) break :children;

            // Negative z-indexes first; the walk queues the floats, positioned boxes and stacking contexts.
            var special = false;
            var c = n.first_child;
            while (c != none) : (c = f.nodes.items[c].next) {
                const ccs = f.nodes.items[c].cs;
                if (f.nodes.items[c].kind != .anon_text and stacks(ccs)) special = true;
            }
            if (n.kind == .anon_box) {
                // the atomic inlines of a paragraph are inline content, painted as a whole each
                c = n.first_child;
                while (c != none) : (c = f.nodes.items[c].next) {
                    const ccs = f.nodes.items[c].cs;
                    if (ccs.float != .none or stacks(ccs)) {
                        try p.paintNode(c, x, y, &cctx, depth + 1);
                    } else try p.enqueue(&p.text_q, c, x, y, &cctx, depth + 1, 0, false);
                }
            } else if (!special) {
                c = n.first_child;
                while (c != none) : (c = f.nodes.items[c].next) try p.paintNode(c, x, y, &cctx, depth + 1);
            } else {
                const sc = try p.sortedChildren(n);
                for (sc.items) |it| try p.paintNode(it, x, y, &cctx, depth + 1);
            }
        }
        // the end of a box that is painted atomically: the layers queued inside it follow in order (see
        // `float_q`; flushed from here, so that the recursion through a queue costs no extra frame)
        const end = p.scopeEnd(id);
        if (end != 0) {
            if (enable_floats) try p.flushFloats(marks[0]);
            try p.flushText(marks[1]);
            if (end & 2 != 0) try p.flushPos(&p.pos_q, marks[2]);
            if (end & 4 != 0) try p.flushZ(marks[3]);
        }
        // collapsed borders follow every box inside the table
        if (enable_tables) {
            if (tg) |t| if (t.collapse) try ptable.paintCollapsed(p, ctx, id, x, y, t);
        }
    }

    /// Painted in the positioned / stacking-context phase.
    fn stacks(cs: *const CS) bool {
        return cs.z_index != null or cs.position != .static or pfx.needsGroup(cs) or cs.offset_path != null or cs.transform.len > 0 or cs.rotate != 0 or cs.scale[0] != 1 or cs.scale[1] != 1;
    }

    /// Stacking context in the strict sense (z-index ordering is local to it).
    fn isContext(cs: *const CS) bool {
        return cs.z_index != null or pfx.needsGroup(cs) or cs.offset_path != null or cs.transform.len > 0 or cs.rotate != 0 or cs.scale[0] != 1 or cs.scale[1] != 1;
    }

    /// Appends a box (or the inline content of one) to a paint queue. Out of line: the queued context
    /// is not a temporary in the recursive frames of `paintNode` / `paintBox`.
    noinline fn enqueue(p: *Painter, list: *std.ArrayList(Queued), id: u32, ox: f32, oy: f32, ctx: *const Ctx, depth: u32, z: i32, text: bool) Error!void {
        try list.append(p.a, .{ .id = id, .ox = ox, .oy = oy, .ctx = ctx.*, .depth = depth, .z = z, .text = text });
    }

    /// What the end of the box `id` flushes: 0 = nothing (it is not painted atomically), else bit 0 = the
    /// floats and the inline content, bit 1 = the positioned boxes, bit 2 = the positive z-indexes.
    noinline fn scopeEnd(p: *const Painter, id: u32) u8 {
        const f = p.f;
        const n = &f.nodes.items[id];
        const cs = n.cs;
        const root = id == f.root;
        const st = stacks(cs);
        var atomic = root or st or (enable_floats and cs.float != .none);
        if (!atomic and n.parent != none) {
            const pn = &f.nodes.items[n.parent];
            atomic = pn.kind == .anon_box or pn.cs.display == .flex or pn.cs.display == .inline_flex or pn.cs.display == .grid or pn.cs.display == .inline_grid;
        }
        if (!atomic) return 0;
        if (!root and !st) return 1;
        if (!root and !isContext(cs)) return 3;
        return 7;
    }

    /// Positive z-indexes queued since `z0`: by z-index, tree order among equals.
    noinline fn flushZ(p: *Painter, z0: usize) Error!void {
        const zs = p.zpos_q.items[@min(z0, p.zpos_q.items.len)..];
        var i: usize = 1;
        while (i < zs.len) : (i += 1) {
            const it = zs[i];
            var j = i;
            while (j > 0 and zs[j - 1].z > it.z) : (j -= 1) zs[j] = zs[j - 1];
            zs[j] = it;
        }
        try p.flushPos(&p.zpos_q, z0);
    }

    noinline fn flushText(p: *Painter, t0: usize) Error!void {
        const f = p.f;
        var i = t0;
        while (i < p.text_q.items.len) : (i += 1) {
            const q = p.text_q.items[i];
            if (!q.text) {
                try p.paintNode(q.id, q.ox, q.oy, &q.ctx, q.depth);
                continue;
            }
            const n = &f.nodes.items[q.id];
            const l = f.tree.layout(n.lid);
            try ptext.paintText(p, &q.ctx, n, q.ox + l.border.left + l.padding.left, q.oy + l.border.top + l.padding.top, l.w - l.border.left - l.border.right - l.padding.left - l.padding.right);
        }
        p.text_q.items.len = @min(t0, p.text_q.items.len);
    }

    noinline fn flushPos(p: *Painter, list: *std.ArrayList(Queued), q0: usize) Error!void {
        var i = q0;
        while (i < list.items.len) : (i += 1) {
            const q = list.items[i];
            const saved = p.pos_now;
            p.pos_now = q.id;
            defer p.pos_now = saved;
            try p.paintNode(q.id, q.ox, q.oy, &q.ctx, q.depth);
        }
        list.items.len = @min(q0, list.items.len);
    }

    noinline fn flushFloats(p: *Painter, q0: usize) Error!void {
        var i = q0;
        while (i < p.float_q.items.len) : (i += 1) {
            const q = p.float_q.items[i];
            const saved = p.float_now;
            p.float_now = q.id;
            defer p.float_now = saved;
            try p.paintNode(q.id, q.ox, q.oy, &q.ctx, q.depth);
        }
        p.float_q.items.len = @min(q0, p.float_q.items.len);
    }

    /// Children in paint order; the first `n_low` are painted before the positioned ones.
    noinline fn sortedChildren(p: *Painter, n: *const Node) Error!struct { items: []u32, n_low: usize } {
        const f = p.f;
        const Item = struct { id: u32, key: i64 };
        var items: std.ArrayList(Item) = .empty;
        var c = n.first_child;
        var seq: i64 = 0;
        var n_low: usize = 0;
        while (c != none) : (c = f.nodes.items[c].next) {
            const cn = &f.nodes.items[c];
            var layer: i64 = 0;
            var z: i64 = 0;
            if (cn.kind != .anon_text) {
                z = cn.cs.z_index orelse 0;
                if (z < 0) {
                    layer = -1;
                } else if (z > 0) {
                    layer = 2;
                } else if (stacks(cn.cs)) layer = 1;
            }
            const zc = std.math.clamp(z, -1000000, 1000000);
            if (layer <= 0) n_low += 1;
            try items.append(p.a, .{ .id = c, .key = (layer * 4000000 + zc) * 1000000 + seq });
            seq += 1;
        }
        var i: usize = 1;
        while (i < items.items.len) : (i += 1) {
            const it = items.items[i];
            var j = i;
            while (j > 0 and items.items[j - 1].key > it.key) : (j -= 1) items.items[j] = items.items[j - 1];
            items.items[j] = it;
        }
        const out = try p.a.alloc(u32, items.items.len);
        for (out, items.items) |*o, it| o.* = it.id;
        return .{ .items = out, .n_low = n_low };
    }
};

pub fn paintFrame(f: *Frame, pm: *Pixmap) Error!void {
    var p: Painter = .{ .f = f, .a = f.a };
    // takumi's anti-aliasing (tiny-skia supersampling) for every shape, clip and glyph.
    f.r.rast.mode = .skia_ss;
    const ctx: Ctx = .{ .dst = pm };
    try p.paintNode(f.root, 0, 0, &ctx, 0);
    try p.flushOutlines(0, pm);
}
