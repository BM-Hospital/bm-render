//! SVG images for the painter: `paintSvg` renders SVG markup into a destination rectangle through
//! `svg.render`, with `<text>` delegated to the font engine. Compiled out when
//! `paint.enable_svg` is false.
//!
//! Sources: image nodes carrying SVG markup (`nodeSvgSource`, lights up when `render.Node` gains
//! an `svg: ?[]const u8` field), and `url()` values that are inline `<svg ...>` markup or
//! `data:image/svg+xml` URIs (`urlSvgSource`).
const std = @import("std");
const render = @import("render.zig");
const style = @import("style/style.zig");
const font = @import("font/font.zig");
const raster = @import("raster/raster.zig");
const pm = @import("paint.zig");
const ptext = @import("paint_text.zig");
const svg = if (pm.enable_svg) @import("svg/svg.zig") else struct {};

const Painter = pm.Painter;
const Ctx = pm.Ctx;
const Node = render.Node;
const Rect = raster.Rect;
const Affine = raster.Affine;
const Pixmap = raster.Pixmap;
const Error = render.Error;

/// SVG markup of an image node, when render.zig provides it (`Node.svg`).
pub fn nodeSvgSource(n: *const Node) ?[]const u8 {
    if (comptime !pm.enable_svg) return null;
    if (comptime @hasField(Node, "svg")) {
        const v = n.svg;
        return if (@TypeOf(v) == ?[]const u8) v else if (v.len > 0) v else null;
    }
    return null;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// SVG markup behind a `url()` value: inline markup, a `data:image/svg+xml` URI (base64 or
/// percent-encoded; decoded into the per-render arena), or — when the renderer exposes
/// `svgSource` — a registered image whose bytes are SVG.
pub fn urlSvgSource(p: *Painter, url: []const u8) ?[]const u8 {
    if (comptime !pm.enable_svg) return null;
    if (std.mem.startsWith(u8, url, "data:")) {
        const comma = std.mem.indexOfScalar(u8, url, ',') orelse return null;
        const meta = url[5..comma];
        if (!std.mem.startsWith(u8, meta, "image/svg+xml")) return null;
        const payload = url[comma + 1 ..];
        const out = p.a.alloc(u8, payload.len) catch return null;
        var n: usize = 0;
        if (std.mem.endsWith(u8, meta, ";base64")) {
            var acc: u32 = 0;
            var bits: u5 = 0;
            for (payload) |c| {
                const v: u32 = switch (c) {
                    'A'...'Z' => c - 'A',
                    'a'...'z' => c - 'a' + 26,
                    '0'...'9' => c - '0' + 52,
                    '+', '-' => 62,
                    '/', '_' => 63,
                    else => continue,
                };
                acc = (acc << 6) | v;
                bits += 6;
                if (bits >= 8) {
                    bits -= 8;
                    out[n] = @truncate(acc >> bits);
                    n += 1;
                }
            }
        } else {
            var i: usize = 0;
            while (i < payload.len) : (i += 1) {
                if (payload[i] == '%' and i + 2 < payload.len) {
                    const h = hexVal(payload[i + 1]);
                    const l = hexVal(payload[i + 2]);
                    if (h != null and l != null) {
                        out[n] = h.? * 16 + l.?;
                        n += 1;
                        i += 2;
                        continue;
                    }
                }
                out[n] = payload[i];
                n += 1;
            }
        }
        return if (svg.looksLikeSvg(out[0..n])) out[0..n] else null;
    }
    if (svg.looksLikeSvg(url)) return url;
    if (comptime @hasDecl(render.Renderer, "svgSource")) return p.f.r.svgSource(url);
    return null;
}

/// Intrinsic size in device px (CSS default object size rules: missing dimension from the viewBox
/// ratio, else the positioning area `dw` x `dh` contained).
pub fn intrinsic(p: *Painter, src: []const u8, dw: f32, dh: f32) [2]f32 {
    if (comptime !pm.enable_svg) return .{ 0, 0 };
    const doc = svg.parse(p.a, src) catch return .{ 0, 0 };
    const sz = svg.intrinsicSize(&doc);
    const dpr = p.f.opts.dpr;
    if (sz.width != null and sz.height != null) return .{ sz.width.? * dpr, sz.height.? * dpr };
    var ratio: ?f32 = null;
    if (sz.view_box) |vb| {
        if (vb[2] > 0 and vb[3] > 0) ratio = vb[2] / vb[3];
    }
    if (sz.width) |w| return .{ w * dpr, if (ratio) |r| w * dpr / r else dh };
    if (sz.height) |h| return .{ if (ratio) |r| h * dpr * r else dw, h * dpr };
    if (ratio) |r| {
        // contain fit into the positioning area
        return if (dw / dh > r) .{ dh * r, dh } else .{ dw, dw / r };
    }
    return .{ dw, dh };
}

const Hook = struct {
    p: *Painter,

    fn draw(ctx: *anyopaque, req: *const svg.TextRequest) void {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        const p = self.p;
        const fill = req.fill orelse return;
        if (fill.a == 0 or !(req.font_size > 0) or req.text.len == 0) return;
        var fams: [4][]const u8 = undefined;
        var nf: usize = 0;
        var it = std.mem.splitScalar(u8, req.font_family, ',');
        while (it.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t\r\n'\"");
            if (t.len == 0 or nf == fams.len) continue;
            fams[nf] = t;
            nf += 1;
        }
        var weight: u16 = 400;
        if (std.mem.eql(u8, req.font_weight, "bold") or std.mem.eql(u8, req.font_weight, "bolder")) {
            weight = 700;
        } else {
            var w: u32 = 0;
            for (req.font_weight) |c| {
                if (c < '0' or c > '9' or w > 1000) {
                    w = 0;
                    break;
                }
                w = w * 10 + (c - '0');
            }
            if (w >= 1 and w <= 1000) weight = @intCast(w);
        }
        const runs = [1]font.Run{.{ .text = req.text, .style = .{ .families = fams[0..nf], .weight = weight, .size = req.font_size } }};
        const tl = font.layoutText(p.a, &p.f.r.fonts, &runs, .{ .white_space = .nowrap }) catch return;
        if (tl.lines.len == 0) return;
        var dx: f32 = 0;
        if (std.mem.eql(u8, req.text_anchor, "middle")) dx = -tl.lines[0].width * 0.5;
        if (std.mem.eql(u8, req.text_anchor, "end")) dx = -tl.lines[0].width;
        const base = tl.lines[0].baseline;
        const c: Ctx = .{ .dst = req.dst, .clip = req.clip, .tf = req.transform };
        const pt: raster.Paint = .{ .solid = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a } };
        for (tl.glyphs[tl.lines[0].glyph_start..tl.lines[0].glyph_end]) |*g| {
            const fc = p.f.r.fonts.face(g.face);
            const bold = weight >= 600 and fc.weight < 600;
            const gx = req.x + dx + g.x;
            const gy = req.y + g.y - base;
            if (ptext.glyphPassMask(p, &c, g, gx, gy, false, .fill, 0)) |m| raster.fillMask(c.dst, &m, &pt, c.clip);
            if (bold) {
                if (ptext.glyphPassMask(p, &c, g, gx, gy, false, .embolden, 0)) |m| raster.fillMask(c.dst, &m, &pt, c.clip);
            }
        }
    }
};

/// Renders SVG markup so that its viewport maps onto `dest` (pre-transform px), clipped to
/// `ctx.clip`. Invalid markup paints nothing. Scratch = the per-render arena.
pub noinline fn paintSvg(p: *Painter, ctx: *const Ctx, src: []const u8, dest: Rect, current: style.Color) Error!void {
    if (comptime !pm.enable_svg) return;
    if (!(dest.w > 0) or !(dest.h > 0)) return;
    const doc = svg.parse(p.a, src) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    var hook: Hook = .{ .p = p };
    const opts: svg.RenderOptions = .{
        .current_color = .{ .r = current.r, .g = current.g, .b = current.b, .a = current.a },
        .text = .{ .ctx = &hook, .draw = Hook.draw },
        .max_image_pixels = p.f.r.limits.image_pixels,
    };
    if (ctx.plain()) {
        svg.render(p.a, p.rast(), &doc, ctx.dst, dest, ctx.clip, opts) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
        return;
    }
    // Transformed: render at device scale into an offscreen, then draw it through the transform.
    const sc = std.math.clamp(Painter.tfScale(ctx.tf), 0.01, 16);
    const w: u32 = @intFromFloat(std.math.clamp(@ceil(dest.w * sc), 1, 4096));
    const h: u32 = @intFromFloat(std.math.clamp(@ceil(dest.h * sc), 1, 4096));
    var off = Pixmap.init(p.a, w, h) catch return error.OutOfMemory;
    @memset(off.data, 0);
    svg.render(p.a, p.rast(), &doc, &off, .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) }, null, opts) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    const m = ctx.tf.mul(Affine.translate(dest.x, dest.y)).mul(Affine.scale(dest.w / @as(f32, @floatFromInt(w)), dest.h / @as(f32, @floatFromInt(h))));
    raster.drawPixmap(ctx.dst, &off, m, 1, .bilinear, ctx.clip);
}
