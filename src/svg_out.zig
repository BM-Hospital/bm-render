//! SVG output: takumi's `renderer.renderSvg(node, options)` (takumi-svg). Serialises a prepared
//! frame (styles computed, layout done) as a vector SVG document, walking the tree exactly like the
//! raster painter (`paint.zig`: same paint order, pixel snapping, radii, gradient geometry, border
//! geometry, shadow shapes, clip and group decisions) but emitting SVG elements instead of pixels:
//!
//! * boxes: `<rect>` / `<path>` (rounded corners as cubic arcs like the painter's path builder);
//!   gradients as `<linearGradient>` / `<radialGradient>` (userSpaceOnUse, `spreadMethod="repeat"`
//!   for repeating ones), conic gradients as 180 coloured wedges (takumi-svg's approximation),
//!   tiled layers as `<pattern>`;
//! * borders: the painter's border algorithm (svg_out_border.zig) with SVG primitives: filled
//!   paths, clip paths, stroked dash patterns, opacity groups;
//! * box shadows: shape + `<filter><feGaussianBlur>` clipped out of (outer) / into (inset) the box;
//! * opacity / mix-blend-mode / isolation / clip-path / mask-image / filter: one `<g>` per element
//!   with `opacity`, `style`, `clip-path`, `mask` and `filter` (filter chains as takumi-svg);
//!   overflow clips as `<clipPath>` groups; transforms as `<g transform="matrix(..)">`;
//! * images: `<image>` with the original encoded bytes as a `data:` URL (PNG re-encode for raw
//!   RGBA sources), defined once in `<defs>` and placed with `<use>`; SVG images as
//!   `data:image/svg+xml` images;
//! * text (svg_out_text.zig): glyph outlines interned once in `<defs>` and placed with `<use>`
//!   (no font embedding), fake bold as a stroke, decorations, text shadows, `-webkit-text-stroke`.
//!
//! Numbers use takumi's formatting (3 decimals, trailing zeros and leading `0` dropped; path data
//! relative with 2 decimals). Ids are deterministic (`c<n>` defs, `g<n>` glyphs, `i<n>` images).
//! * `backdrop-filter`: the scene painted before the element replayed from the root, filtered and
//!   clipped to its border box (takumi-svg); colour glyphs: PNG images of the painter's rendering.
//!
//! Not supported (painted without the effect): `clip-path: url()`.
//!
//! Allocation: everything goes into the per-render arena `Frame.a` (the output list too).
//! Recursion: one `paintNode` level per tree level (bounded by the layout depth limit, <= 600);
//! the helpers called from it are `noinline` so the recursive frame stays small.
const std = @import("std");
const render = @import("render.zig");
const style = @import("style/style.zig");
const font = @import("font/font.zig");
const raster = @import("raster/raster.zig");
const rtypes = @import("raster/types.zig");
const codec = @import("codec/codec.zig");
const pm = @import("paint.zig");
const pfx = @import("paint_fx.zig");
const psvg = @import("paint_svg.zig");
const sborder = @import("svg_out_border.zig");
const stext = @import("svg_out_text.zig");
const svg_path = if (pm.enable_svg) @import("svg/pathdata.zig") else struct {};

const Allocator = std.mem.Allocator;
const Frame = render.Frame;
const Node = render.Node;
const CS = render.CS;
const none = render.none;
const Error = render.Error;
const Rect = raster.Rect;
const Affine = raster.Affine;
const Path = raster.Path;
const Color = style.Color;
pub const Radii = pm.Radii;
pub const Geom = pm.Geom;
pub const Ctx = pm.Ctx;

/// Hard cap of the generated document.
pub const max_output: usize = 256 << 20;

/// Serialises the prepared frame (styles computed, layout done) as an SVG document into `out`
/// (allocated from `f.a`, the per-render arena).
pub fn write(f: *Frame, out: *std.ArrayList(u8)) Error!void {
    var s: S = .{
        .f = f,
        .a = f.a,
        .out = out,
        .p = .{ .f = f, .a = f.a },
        .dummy = .{ .width = f.canvas_w, .height = f.canvas_h, .data = &.{} },
    };
    // glyph masks (skip-ink) use takumi's anti-aliasing like the painter
    f.r.rast.mode = .skia_ss;
    s.raw("<svg xmlns=\"http://www.w3.org/2000/svg\"");
    s.attrNum("width", @floatFromInt(f.canvas_w));
    s.attrNum("height", @floatFromInt(f.canvas_h));
    s.raw(" viewBox=\"0 0 ");
    s.num(@floatFromInt(f.canvas_w));
    s.raw(" ");
    s.num(@floatFromInt(f.canvas_h));
    s.raw("\">\n");
    const ctx: Ctx = .{ .dst = &s.dummy };
    try s.paintNode(f.root, 0, 0, &ctx, 0);
    try s.flushOutlines(0, 0, Affine.identity);
    if (s.defs.items.len > 0) {
        s.raw("<defs>\n");
        s.raw(s.defs.items);
        s.raw("</defs>\n");
    }
    s.raw("</svg>\n");
    try s.check();
}

// ------------------------------------------------------------------------------------------------
// number / path formatting (takumi `Num`, `PathData`)

/// takumi `Num`: 3 decimals, `0` for non-finite / tiny values, no trailing zeros, no leading `0`.
pub fn fmtNum(buf: *[32]u8, v: f32) []const u8 {
    if (!std.math.isFinite(v)) return "0";
    const units = @round(v * 1000.0);
    if (units == 0 or !(@abs(units) < 1.0e15)) return "0";
    var n: usize = 0;
    var mag: u64 = @intFromFloat(@abs(units));
    if (units < 0) {
        buf[n] = '-';
        n += 1;
    }
    const whole = mag / 1000;
    var frac = mag % 1000;
    if (whole > 0) {
        var tmp: [20]u8 = undefined;
        var k: usize = tmp.len;
        var w = whole;
        while (w > 0) : (w /= 10) {
            k -= 1;
            tmp[k] = @intCast('0' + w % 10);
        }
        @memcpy(buf[n..][0 .. tmp.len - k], tmp[k..]);
        n += tmp.len - k;
    }
    if (frac > 0) {
        var digits: usize = 3;
        while (frac % 10 == 0) {
            frac /= 10;
            digits -= 1;
        }
        buf[n] = '.';
        n += 1;
        var i: usize = digits;
        while (i > 0) {
            i -= 1;
            buf[n + i] = @intCast('0' + frac % 10);
            frac /= 10;
        }
        n += digits;
    }
    mag = 0;
    return buf[0..n];
}

/// Path coordinates keep two decimals (takumi `quantize_path`).
pub fn qp(v: f32) f32 {
    return @round(v * 100.0) / 100.0;
}

/// takumi `path_data`: relative commands from the quantized pen position (rounding error carried
/// forward so contours stay closed), implicit command repetition, `h`/`v`/`s` shorthands.
const PathData = struct {
    a: Allocator,
    o: *std.ArrayList(u8),
    prev_num: bool = false,
    prev_dot: bool = false,
    last: u8 = 0,
    x: f32 = 0,
    y: f32 = 0,
    sx: f32 = 0,
    sy: f32 = 0,
    started: bool = false,
    prev_cubic: bool = false,
    pcx: f32 = 0,
    pcy: f32 = 0,

    fn command(d: *PathData, letter: u8) Error!void {
        const elide = d.last != 0 and ((d.last == letter and letter != 'M' and letter != 'm') or (d.last == 'M' and letter == 'L') or (d.last == 'm' and letter == 'l'));
        if (!elide) {
            try d.o.append(d.a, letter);
            d.prev_num = false;
        }
        d.last = letter;
    }

    fn number(d: *PathData, v: f32) Error!void {
        var buf: [32]u8 = undefined;
        const t = fmtNum(&buf, v);
        if (d.prev_num and t[0] != '-' and !(t[0] == '.' and d.prev_dot)) try d.o.append(d.a, ' ');
        try d.o.appendSlice(d.a, t);
        d.prev_num = true;
        d.prev_dot = std.mem.indexOfScalar(u8, t, '.') != null;
    }

    fn pair(d: *PathData, x: f32, y: f32) Error!void {
        try d.number(x);
        try d.number(y);
    }

    fn advance(d: *PathData, dx: f32, dy: f32) void {
        d.x = qp(d.x + dx);
        d.y = qp(d.y + dy);
    }

    fn moveTo(d: *PathData, x: f32, y: f32) Error!void {
        if (d.started) {
            const dx = qp(x - d.x);
            const dy = qp(y - d.y);
            try d.command('m');
            try d.pair(dx, dy);
            d.advance(dx, dy);
        } else {
            d.x = qp(x);
            d.y = qp(y);
            try d.command('M');
            try d.pair(d.x, d.y);
            d.started = true;
        }
        d.sx = d.x;
        d.sy = d.y;
        d.prev_cubic = false;
    }

    fn lineTo(d: *PathData, x: f32, y: f32) Error!void {
        const dx = qp(x - d.x);
        const dy = qp(y - d.y);
        if (dx == 0 and dy == 0) return;
        if (dy == 0) {
            try d.command('h');
            try d.number(dx);
        } else if (dx == 0) {
            try d.command('v');
            try d.number(dy);
        } else {
            try d.command('l');
            try d.pair(dx, dy);
        }
        d.advance(dx, dy);
        d.prev_cubic = false;
    }

    fn quadTo(d: *PathData, cx: f32, cy: f32, x: f32, y: f32) Error!void {
        const ox = d.x;
        const oy = d.y;
        try d.command('q');
        try d.pair(qp(cx - ox), qp(cy - oy));
        const dx = qp(x - ox);
        const dy = qp(y - oy);
        try d.pair(dx, dy);
        d.advance(dx, dy);
        d.prev_cubic = false;
    }

    fn cubicTo(d: *PathData, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) Error!void {
        const ox = d.x;
        const oy = d.y;
        const dx = qp(x - ox);
        const dy = qp(y - oy);
        const dc2x = qp(c2x - ox);
        const dc2y = qp(c2y - oy);
        if (d.prev_cubic and @abs(c1x - (2 * ox - d.pcx)) < 0.01 and @abs(c1y - (2 * oy - d.pcy)) < 0.01) {
            try d.command('s');
        } else {
            try d.command('c');
            try d.pair(qp(c1x - ox), qp(c1y - oy));
        }
        try d.pair(dc2x, dc2y);
        try d.pair(dx, dy);
        d.advance(dx, dy);
        d.prev_cubic = true;
        d.pcx = ox + dc2x;
        d.pcy = oy + dc2y;
    }

    fn close(d: *PathData) Error!void {
        try d.o.append(d.a, 'Z');
        d.prev_num = false;
        d.last = 0;
        d.x = d.sx;
        d.y = d.sy;
        d.prev_cubic = false;
    }
};

/// Appends the path data of `path` under `tf` to `o` (nothing for an empty path).
pub fn writePathTo(a: Allocator, o: *std.ArrayList(u8), path: *const Path, tf: Affine) Error!void {
    var d: PathData = .{ .a = a, .o = o };
    const pts = path.points.items;
    var pi: usize = 0;
    for (path.verbs.items) |v| switch (v) {
        .move => {
            if (pi >= pts.len) return;
            const q = tf.apply(pts[pi]);
            try d.moveTo(q.x, q.y);
            pi += 1;
        },
        .line => {
            if (pi >= pts.len) return;
            const q = tf.apply(pts[pi]);
            try d.lineTo(q.x, q.y);
            pi += 1;
        },
        .quad => {
            if (pi + 2 > pts.len) return;
            const c = tf.apply(pts[pi]);
            const q = tf.apply(pts[pi + 1]);
            try d.quadTo(c.x, c.y, q.x, q.y);
            pi += 2;
        },
        .cubic => {
            if (pi + 3 > pts.len) return;
            const c1 = tf.apply(pts[pi]);
            const c2 = tf.apply(pts[pi + 1]);
            const q = tf.apply(pts[pi + 2]);
            try d.cubicTo(c1.x, c1.y, c2.x, c2.y, q.x, q.y);
            pi += 3;
        },
        .close => try d.close(),
    };
}

fn hexByte(o: *[2]u8, v: u8) void {
    const hx = "0123456789abcdef";
    o[0] = hx[v >> 4];
    o[1] = hx[v & 15];
}

const huge: f32 = 1.0e6;

// ------------------------------------------------------------------------------------------------
// document state

const ClipEnt = struct { id: u32, tf: Affine };
const Deferred = struct { cs: *const CS, g: Geom, tf: Affine, clip0: u32, clip1: u32 };
const ImgDef = struct { key: u64, id: u32 };

pub const S = struct {
    f: *Frame,
    a: Allocator,
    out: *std.ArrayList(u8),
    /// trailing `<defs>` content (glyph outlines, images)
    defs: std.ArrayList(u8) = .empty,
    next_id: u32 = 0,
    /// glyph key -> def index + 1 (0 = empty outline)
    glyph_ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    n_glyphs: u32 = 0,
    images: std.ArrayList(ImgDef) = .empty,
    /// open clip groups (re-emitted for deferred outlines)
    clips: std.ArrayList(ClipEnt) = .empty,
    /// floats waiting for the in-flow content of their stacking context (painter `float_q`); here an
    /// overflow clip is a flush point as well, since clips are open groups of the document
    float_q: std.ArrayList(QueuedFloat) = .empty,
    float_now: u32 = none,
    /// `svg_out_text.synthOf`: the colour tables of the last face it looked at
    color_tables: pm.ColorTablesCache = .{},
    outlines: std.ArrayList(Deferred) = .empty,
    outline_clips: std.ArrayList(ClipEnt) = .empty,
    path: Path = .empty,
    path2: Path = .empty,
    /// backdrop replay: the walk stops (`stopped`) when it reaches node `stop_at`
    stop_at: u32 = none,
    stopped: bool = false,
    /// first output error (sticky; see `put`)
    failed: ?Error = null,
    /// raster painter used for glyph coverage (skip-ink)
    p: pm.Painter,
    /// canvas-sized pixmap without pixels (painter helpers only read its bounds)
    dummy: raster.Pixmap,

    // ---- low-level output: infallible writers with a sticky error (`failed`), checked by the
    // walk (`paintNode`) and at the end of `write`; keeps ~400 call sites free of error branches.

    fn put(s: *S, t: []const u8) void {
        if (s.failed != null) return;
        s.out.appendSlice(s.a, t) catch {
            s.failed = error.OutOfMemory;
            return;
        };
        if (s.out.items.len + s.defs.items.len > max_output) {
            s.f.r.setErr("SVG output too large", "");
            s.failed = error.Invalid;
        }
    }

    /// The first output error, if any.
    pub fn check(s: *S) Error!void {
        if (s.failed) |e| return e;
    }

    pub fn raw(s: *S, t: []const u8) void {
        s.put(t);
    }

    pub fn num(s: *S, v: f32) void {
        var buf: [32]u8 = undefined;
        s.put(fmtNum(&buf, v));
    }

    pub fn attrNum(s: *S, name: []const u8, v: f32) void {
        s.put(" ");
        s.put(name);
        s.put("=\"");
        s.num(v);
        s.put("\"");
    }

    pub fn uint(s: *S, v: u32) void {
        var tmp: [10]u8 = undefined;
        var k: usize = tmp.len;
        var w = v;
        while (true) {
            k -= 1;
            tmp[k] = @intCast('0' + w % 10);
            w /= 10;
            if (w == 0) break;
        }
        s.put(tmp[k..]);
    }

    pub fn newId(s: *S) u32 {
        const id = s.next_id;
        s.next_id +%= 1;
        return id;
    }

    /// ` name="url(#c<id>)"`
    pub fn attrRef(s: *S, name: []const u8, id: u32) void {
        s.put(" ");
        s.put(name);
        s.put("=\"url(#c");
        s.uint(id);
        s.put(")\"");
    }

    pub fn attrId(s: *S, id: u32) void {
        s.put(" id=\"c");
        s.uint(id);
        s.put("\"");
    }

    /// ` name="#rrggbb"` plus ` <opname>=".5"` when translucent.
    pub fn attrColor(s: *S, name: []const u8, opname: []const u8, c: Color) void {
        var b: [8]u8 = undefined;
        b[0] = '#';
        const collapsible = (c.r >> 4 == c.r & 15) and (c.g >> 4 == c.g & 15) and (c.b >> 4 == c.b & 15);
        var n: usize = 7;
        if (collapsible) {
            const hx = "0123456789abcdef";
            b[1] = hx[c.r & 15];
            b[2] = hx[c.g & 15];
            b[3] = hx[c.b & 15];
            n = 4;
        } else {
            hexByte(b[1..3], c.r);
            hexByte(b[3..5], c.g);
            hexByte(b[5..7], c.b);
        }
        s.put(" ");
        s.put(name);
        s.put("=\"");
        s.put(b[0..n]);
        s.put("\"");
        if (c.a < 255) s.attrNum(opname, @as(f32, @floatFromInt(c.a)) / 255.0);
    }

    pub fn attrPath(s: *S, path: *const Path, tf: Affine) void {
        s.put(" d=\"");
        if (s.failed == null) writePathTo(s.a, s.out, path, tf) catch {
            s.failed = error.OutOfMemory;
        };
        s.put("\"");
    }

    pub fn attrMatrix(s: *S, m: Affine) void {
        s.put(" transform=\"matrix(");
        const v = [6]f32{ m.a, m.b, m.c, m.d, m.e, m.f };
        for (v, 0..) |x, i| {
            if (i > 0) s.put(" ");
            s.num(x);
        }
        s.put(")\"");
    }

    /// XML attribute value text (escapes `& < > "` and line breaks / tabs).
    pub fn esc(s: *S, t: []const u8) void {
        var start: usize = 0;
        for (t, 0..) |c, i| {
            const rep: ?[]const u8 = switch (c) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\n' => "&#10;",
                '\r' => "&#13;",
                '\t' => "&#9;",
                else => null,
            };
            if (rep) |r| {
                s.put(t[start..i]);
                s.put(r);
                start = i + 1;
            }
        }
        s.put(t[start..]);
    }

    pub fn closeG(s: *S) void {
        s.put("</g>\n");
    }

    pub fn gTransform(s: *S, m: Affine) void {
        s.put("<g");
        s.attrMatrix(m);
        s.put(">\n");
    }

    // ---- shapes

    pub fn setRRect(s: *S, path: *Path, r: Rect, radii: ?Radii) Error!void {
        path.reset();
        if (radii) |rr| {
            path.addRoundRect(s.a, r, rr) catch return error.OutOfMemory;
        } else path.addRect(s.a, r) catch return error.OutOfMemory;
    }

    /// `<rect>` / rounded `<path>` filled with `paint` (a solid colour, or a `url(#c<id>)` ref).
    pub fn fillShape(s: *S, r: Rect, radii: ?Radii, paint: Paint) Error!void {
        if (!(r.w > 0) or !(r.h > 0)) return;
        if (paint == .color and paint.color.a == 0) return;
        if (radii == null) {
            s.raw("<rect");
            s.attrNum("x", r.x);
            s.attrNum("y", r.y);
            s.attrNum("width", r.w);
            s.attrNum("height", r.h);
        } else {
            try s.setRRect(&s.path, r, radii);
            s.raw("<path");
            s.attrPath(&s.path, Affine.identity);
        }
        try s.paintAttr(paint);
        s.raw("/>\n");
    }

    pub fn paintAttr(s: *S, paint: Paint) Error!void {
        switch (paint) {
            .color => |c| s.attrColor("fill", "fill-opacity", c),
            .ref => |id| s.attrRef("fill", id),
        }
    }

    pub fn fillRRect(s: *S, r: Rect, radii: ?Radii, c: Color) Error!void {
        return s.fillShape(r, radii, .{ .color = c });
    }

    /// `<clipPath>` of `path` (under `tf`); returns its id. `out` = everything outside the path.
    pub fn defClip(s: *S, path: *const Path, tf: Affine, evenodd: bool, out: bool, crisp: bool) Error!u32 {
        const id = s.newId();
        s.raw("<clipPath");
        s.attrId(id);
        s.raw("><path d=\"");
        if (out) {
            s.raw("M-1000000-1000000H1000000V1000000H-1000000Z");
        }
        try writePathTo(s.a, s.out, path, tf);
        s.raw("\"");
        if (evenodd or out) s.raw(" clip-rule=\"evenodd\"");
        if (crisp) s.raw(" shape-rendering=\"crispEdges\"");
        s.raw("/></clipPath>\n");
        return id;
    }

    pub fn defClipRRect(s: *S, r: Rect, radii: ?Radii) Error!u32 {
        try s.setRRect(&s.path2, r, radii);
        return s.defClip(&s.path2, Affine.identity, false, false, false);
    }

    /// Opens `<g clip-path>` and records it for deferred outlines.
    pub fn openClip(s: *S, id: u32, tf: Affine) Error!void {
        s.raw("<g");
        s.attrRef("clip-path", id);
        s.raw(">\n");
        try s.clips.append(s.a, .{ .id = id, .tf = tf });
    }

    pub fn closeClip(s: *S) void {
        if (s.clips.items.len > 0) s.clips.items.len -= 1;
        s.closeG();
    }

    /// Gaussian blur `<filter>` covering `r` grown by the blur reach; returns its id.
    pub fn defBlur(s: *S, sigma: f32, r: Rect) Error!u32 {
        const id = s.newId();
        const e = @ceil(3 * sigma) + 2;
        s.raw("<filter");
        s.attrId(id);
        s.raw(" filterUnits=\"userSpaceOnUse\"");
        s.attrNum("x", r.x - e);
        s.attrNum("y", r.y - e);
        s.attrNum("width", r.w + 2 * e);
        s.attrNum("height", r.h + 2 * e);
        s.raw("><feGaussianBlur");
        s.attrNum("stdDeviation", sigma);
        s.raw("/></filter>\n");
        return id;
    }

    // ---- tree walk (mirrors paint.zig). Recursion: paintNode -> paintBox -> paintNode; both
    // frames stay small, the per-node work lives in `noinline` helpers.

    const Place = struct { x: f32, y: f32, ctx: Ctx, transformed: bool };
    const QueuedFloat = struct { id: u32, ox: f32, oy: f32, ctx: Ctx, depth: u32 };
    const enable_floats = @import("config.zig").enable_floats;

    noinline fn queueFloat(s: *S, id: u32, ox: f32, oy: f32, ctx: *const Ctx, depth: u32) Error!bool {
        const n = &s.f.nodes.items[id];
        if (n.cs.float == .none or n.kind == .anon_text or id == s.float_now or id == s.f.root or n.cs.display == .none or stacks(n.cs)) return false;
        try s.float_q.append(s.a, .{ .id = id, .ox = ox, .oy = oy, .ctx = ctx.*, .depth = depth });
        return true;
    }

    noinline fn flushFloats(s: *S, q0: usize) Error!void {
        var i = q0;
        while (i < s.float_q.items.len) : (i += 1) {
            const q = s.float_q.items[i];
            const saved = s.float_now;
            s.float_now = q.id;
            defer s.float_now = saved;
            try s.paintNode(q.id, q.ox, q.oy, &q.ctx, q.depth);
        }
        s.float_q.items.len = @min(q0, s.float_q.items.len);
    }

    fn paintNode(s: *S, id: u32, ox: f32, oy: f32, ctx_in: *const Ctx, depth: u32) Error!void {
        try s.check();
        if (s.stopped) return;
        if (id == s.stop_at) {
            s.stopped = true;
            return;
        }
        if (depth > 600) return;
        if (enable_floats and try s.queueFloat(id, ox, oy, ctx_in, depth)) return;
        var pl: Place = undefined;
        if (!s.place(id, ox, oy, ctx_in, &pl)) return;
        if (s.f.nodes.items[id].kind != .anon_text and pfx.needsGroup(s.f.nodes.items[id].cs)) {
            try s.paintGroup(id, pl.x, pl.y, &pl.ctx, depth);
        } else try s.paintBox(id, pl.x, pl.y, &pl.ctx, depth);
        if (pl.transformed) s.closeG();
    }

    /// Border box origin and context of node `id` (painter `paintNode`): a translation folds into
    /// the origin of an untransformed box, any other transform opens a `<g transform>` (closed
    /// by the caller when `transformed`). False = paints nothing.
    noinline fn place(s: *S, id: u32, ox: f32, oy: f32, ctx_in: *const Ctx, pl: *Place) bool {
        const n = &s.f.nodes.items[id];
        const cs = n.cs;
        if (n.kind != .anon_text and cs.display == .none) return false;
        const l = s.f.tree.layout(n.lid);
        pl.* = .{ .x = ox + l.x, .y = oy + l.y, .ctx = ctx_in.*, .transformed = false };
        if (n.kind == .anon_text) return true;
        var m_open: ?Affine = null;
        if (localTransform(cs, pl.x, pl.y, l.w, l.h)) |m| {
            if (m.isTranslateOnly() and pl.ctx.plain()) {
                pl.x += m.e;
                pl.y += m.f;
            } else {
                pl.ctx.tf = pl.ctx.tf.mul(m);
                if (pl.ctx.tf.invert() == null) return false;
                m_open = m;
            }
        }
        if (!(cs.opacity > 0)) return false;
        if (m_open) |m| {
            s.gTransform(m);
            pl.transformed = true;
        }
        return true;
    }

    /// The element as one `<g>` with its opacity, blend mode, isolation, clip-path, mask and filter
    /// (painter `paintGroup`); a `backdrop-filter` backdrop is its first child.
    noinline fn paintGroup(s: *S, id: u32, x: f32, y: f32, ctx: *const Ctx, depth: u32) Error!void {
        try s.openGroup(id, x, y, ctx);
        const mark = s.outlines.items.len;
        const base = s.clips.items.len;
        try s.paintBox(id, x, y, ctx, depth);
        try s.flushOutlines(mark, base, ctx.tf);
        s.closeG();
    }

    noinline fn openGroup(s: *S, id: u32, x: f32, y: f32, ctx: *const Ctx) Error!void {
        const f = s.f;
        const n = &f.nodes.items[id];
        const cs = n.cs;
        const l = f.tree.layout(n.lid);
        const g = pm.Painter.geomOf(cs, l, x, y, ctx);
        var clip_id: ?u32 = null;
        if (cs.clip_path) |cp| clip_id = try s.clipPathDef(cp, cs, .{ .x = x, .y = y, .w = l.w, .h = l.h }, &g);
        var mask_id: ?u32 = null;
        if (pfx.hasMask(cs)) mask_id = try s.maskDef(ctx, cs, &g);
        var filter_id: ?u32 = null;
        if (cs.filter.len > 0) filter_id = try s.filterDef(cs.filter, cs);
        s.raw("<g");
        if (cs.opacity < 1) s.attrNum("opacity", cs.opacity);
        const mode = blendName(cs.mix_blend_mode);
        if (mode.len > 0 or cs.isolation == .isolate) {
            s.raw(" style=\"");
            if (mode.len > 0) {
                s.raw("mix-blend-mode:");
                s.raw(mode);
                if (cs.isolation == .isolate) s.raw(";");
            }
            if (cs.isolation == .isolate) s.raw("isolation:isolate");
            s.raw("\"");
        }
        if (clip_id) |c| s.attrRef("clip-path", c);
        if (mask_id) |c| s.attrRef("mask", c);
        if (filter_id) |c| s.attrRef("filter", c);
        s.raw(">\n");
        if (filter_id != null) {
            // anchors the filter region to the border box when nothing paints (takumi-svg)
            s.raw("<rect");
            s.attrNum("x", g.bx.x);
            s.attrNum("y", g.bx.y);
            s.attrNum("width", g.bx.w);
            s.attrNum("height", g.bx.h);
            s.raw(" fill=\"none\"/>\n");
        }
        if (cs.backdrop_filter.len > 0 and s.stop_at == none) try s.backdrop(id, ctx, cs, &g);
    }

    noinline fn paintBox(s: *S, id: u32, x: f32, y: f32, ctx: *const Ctx, depth: u32) Error!void {
        try s.paintOwn(id, x, y, ctx);
        const n = &s.f.nodes.items[id];
        if (n.kind == .anon_text or n.first_child == none) return;
        const clip = try s.openOverflow(id, x, y, ctx);
        if (clip == .empty) return;
        var special = false;
        var c = n.first_child;
        while (c != none) : (c = s.f.nodes.items[c].next) {
            if (s.f.nodes.items[c].kind != .anon_text and stacks(s.f.nodes.items[c].cs)) special = true;
        }
        const froot = enable_floats and (id == s.f.root or clip == .clipped or n.cs.float != .none or stacks(n.cs));
        const q0 = s.float_q.items.len;
        if (!special) {
            c = n.first_child;
            while (c != none) : (c = s.f.nodes.items[c].next) try s.paintNode(c, x, y, ctx, depth + 1);
            if (froot) try s.flushFloats(q0);
        } else {
            const sc = try s.sortedChildren(n);
            for (sc.items[0..sc.n_low]) |it| try s.paintNode(it, x, y, ctx, depth + 1);
            if (froot) try s.flushFloats(q0);
            for (sc.items[sc.n_low..]) |it| try s.paintNode(it, x, y, ctx, depth + 1);
        }
        if (clip == .clipped) s.closeClip();
    }

    /// The box's own painting (painter `paintBox` before the children): shadows, background,
    /// border, deferred outline, image, text.
    noinline fn paintOwn(s: *S, id: u32, x: f32, y: f32, ctx: *const Ctx) Error!void {
        const f = s.f;
        const n = &f.nodes.items[id];
        const cs = n.cs;
        const l = f.tree.layout(n.lid);
        const content_x = x + l.border.left + l.padding.left;
        const content_y = y + l.border.top + l.padding.top;
        const content_w = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
        if (n.kind == .anon_text) return stext.paintText(s, ctx, n, content_x, content_y, content_w);
        const g = pm.Painter.geomOf(cs, l, x, y, ctx);
        if (cs.visibility == .visible) {
            if (cs.box_shadow.len > 0) try s.paintOuterShadows(cs, &g);
            try s.paintBackground(ctx, id, &g, x, y);
            if (cs.box_shadow.len > 0) try s.paintInsetShadows(cs, &g);
            try sborder.paintBorder(s, cs, &g);
            if (cs.outline_style != .none and cs.outline_style != .hidden) try s.deferOutline(cs, &g, ctx.tf);
            if (n.kind == .image) try s.paintImage(n, &g);
        }
        if (n.kind == .text or (n.kind == .anon_box and n.para != null)) try stext.paintText(s, ctx, n, content_x, content_y, content_w);
    }

    const Overflow = enum { none, clipped, empty };

    /// `overflow` other than visible: opens a group clipped to the (rounded) padding box.
    noinline fn openOverflow(s: *S, id: u32, x: f32, y: f32, ctx: *const Ctx) Error!Overflow {
        const n = &s.f.nodes.items[id];
        const cs = n.cs;
        if (cs.overflow_x == .visible and cs.overflow_y == .visible) return .none;
        const g = pm.Painter.geomOf(cs, s.f.tree.layout(n.lid), x, y, ctx);
        const pr = g.padRect();
        if (!(pr.w > 0) or !(pr.h > 0)) return .empty;
        const cid = try s.defClipRRect(pr, g.padRadii());
        try s.openClip(cid, ctx.tf);
        return .clipped;
    }

    noinline fn sortedChildren(s: *S, n: *const Node) Error!struct { items: []u32, n_low: usize } {
        const f = s.f;
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
            try items.append(s.a, .{ .id = c, .key = (layer * 4000000 + zc) * 1000000 + seq });
            seq += 1;
        }
        var i: usize = 1;
        while (i < items.items.len) : (i += 1) {
            const it = items.items[i];
            var j = i;
            while (j > 0 and items.items[j - 1].key > it.key) : (j -= 1) items.items[j] = items.items[j - 1];
            items.items[j] = it;
        }
        const out = try s.a.alloc(u32, items.items.len);
        for (out, items.items) |*o, it| o.* = it.id;
        return .{ .items = out, .n_low = n_low };
    }

    // ---- outlines (painted at the end of their stacking context, like the painter)

    noinline fn deferOutline(s: *S, cs: *const CS, g: *const Geom, tf: Affine) Error!void {
        const c0: u32 = @intCast(s.outline_clips.items.len);
        try s.outline_clips.appendSlice(s.a, s.clips.items);
        try s.outlines.append(s.a, .{ .cs = cs, .g = g.*, .tf = tf, .clip0 = c0, .clip1 = @intCast(s.outline_clips.items.len) });
    }

    /// Paints the outlines deferred since `mark`, re-entering the clips opened (and closed again)
    /// after `base` and the transform each outline was drawn under. `cur` = current transform.
    noinline fn flushOutlines(s: *S, mark: usize, base: usize, cur_in: Affine) Error!void {
        if (s.stopped) return; // a backdrop replay ends before these
        var i = mark;
        while (i < s.outlines.items.len) : (i += 1) {
            const d = s.outlines.items[i];
            var cur = cur_in;
            var opened: u32 = 0;
            var k: usize = d.clip0 + @min(base, d.clip1 - d.clip0);
            while (k < d.clip1) : (k += 1) {
                const ce = s.outline_clips.items[k];
                if (!eqAffine(ce.tf, cur)) {
                    const rel = (cur.invert() orelse Affine.identity).mul(ce.tf);
                    s.gTransform(rel);
                    opened += 1;
                    cur = ce.tf;
                }
                s.raw("<g");
                s.attrRef("clip-path", ce.id);
                s.raw(">\n");
                opened += 1;
            }
            if (!eqAffine(d.tf, cur)) {
                s.gTransform((cur.invert() orelse Affine.identity).mul(d.tf));
                opened += 1;
            }
            try sborder.paintOutline(s, d.cs, &d.g);
            while (opened > 0) : (opened -= 1) s.closeG();
        }
        s.outlines.shrinkRetainingCapacity(mark);
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

    noinline fn paintBackground(s: *S, ctx: *const Ctx, id: u32, g: *const Geom, x: f32, y: f32) Error!void {
        const cs = s.f.nodes.items[id].cs;
        const col = cs.resolveColor(cs.background_color);
        if (col.a == 0 and cs.background_image.len == 0) return;
        var text_clip = cs.bgColorClip() == .text;
        for (cs.background_clip) |bc| {
            if (bc == .text) text_clip = true;
        }
        var masked = false;
        if (text_clip) {
            // background-clip: text — the background through the glyph coverage (an alpha mask)
            const mid = s.newId();
            s.raw("<mask");
            s.attrId(mid);
            s.raw(" maskUnits=\"userSpaceOnUse\" style=\"mask-type:alpha\"");
            s.attrNum("x", g.bx.x - 1);
            s.attrNum("y", g.bx.y - 1);
            s.attrNum("width", g.bx.w + 2);
            s.attrNum("height", g.bx.h + 2);
            s.raw(">\n");
            try stext.textClipShapes(s, ctx, id, x, y);
            s.raw("</mask>\n<g");
            s.attrRef("mask", mid);
            s.raw(">\n");
            masked = true;
        }
        var blended = false;
        for (cs.background_blend_mode) |bm| {
            if (bm != .normal) blended = true;
        }
        if (blended and cs.background_image.len > 0) {
            s.raw("<g style=\"isolation:isolate\">\n");
        } else blended = false;
        if (col.a != 0) {
            const ar = area(g, cs.bgColorClip());
            try s.fillRRect(ar.rect, ar.radii, col);
        }
        var i = cs.background_image.len;
        while (i > 0) {
            i -= 1;
            const layer = cs.bgLayer(i);
            if (layer.image == .none) continue;
            const mode = if (blended) blendName(cs.background_blend_mode[i % cs.background_blend_mode.len]) else "";
            if (mode.len > 0) {
                s.raw("<g style=\"mix-blend-mode:");
                s.raw(mode);
                s.raw("\">\n");
            }
            try s.paintBgLayer(cs, g, &layer, !blended);
            if (mode.len > 0) s.closeG();
        }
        if (blended) s.closeG();
        if (masked) s.closeG();
    }

    /// One background / mask image layer (painter `paintBgLayer`): a single tile is drawn
    /// directly, several through a `<pattern>`.
    pub noinline fn paintBgLayer(s: *S, cs: *const CS, g: *const Geom, layer: *const style.BgLayer, obscure: bool) Error!void {
        const o = area(g, layer.origin).rect;
        var pa = area(g, layer.clip);
        var outer_clip = false;
        if (obscure and layer.clip == .border_box) {
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
                const inner: Rect = .{ .x = pa.rect.x + ins[3], .y = pa.rect.y + ins[0], .w = @max(0, pa.rect.w - ins[1] - ins[3]), .h = @max(0, pa.rect.h - ins[0] - ins[2]) };
                if (!(inner.w > 0) or !(inner.h > 0)) return;
                if (pa.radii != null) {
                    const cid = try s.defClipRRect(pa.rect, pa.radii);
                    s.raw("<g");
                    s.attrRef("clip-path", cid);
                    s.raw(">\n");
                    outer_clip = true;
                }
                pa = .{ .rect = inner, .radii = null };
            }
        }
        try s.bgLayerTiles(cs, layer, o, pa);
        if (outer_clip) s.closeG();
    }

    noinline fn bgLayerTiles(s: *S, cs: *const CS, layer: *const style.BgLayer, o: Rect, pa: Area) Error!void {
        if (!(o.w > 0) or !(o.h > 0)) return;
        var iw: f32 = 0;
        var ih: f32 = 0;
        var img: Img = .none;
        if (layer.image == .url) {
            if (s.f.r.resolveImage(layer.image.url)) |im| {
                img = .{ .bitmap = .{ .pm = im, .src = layer.image.url } };
                iw = @as(f32, @floatFromInt(im.width)) * s.f.opts.dpr;
                ih = @as(f32, @floatFromInt(im.height)) * s.f.opts.dpr;
            } else if (psvg.urlSvgSource(&s.p, layer.image.url)) |src| {
                img = .{ .svg = src };
                const sz = psvg.intrinsic(&s.p, src, o.w, o.h);
                iw = sz[0];
                ih = sz[1];
            } else return;
            if (!(iw > 0) or !(ih > 0)) return;
        }
        const has_img = img != .none;
        var tw: f32 = o.w;
        var th: f32 = o.h;
        switch (layer.size) {
            .cover, .contain => if (has_img) {
                const sx = o.w / iw;
                const sy = o.h / ih;
                const sc = if (layer.size == .cover) @max(sx, sy) else @min(sx, sy);
                tw = iw * sc;
                th = ih * sc;
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

        // painted region: the clip area, limited to the tile row / column on a non-repeating axis
        var x0 = pa.rect.x;
        var y0 = pa.rect.y;
        var x1 = pa.rect.x + pa.rect.w;
        var y1 = pa.rect.y + pa.rect.h;
        if (!rep_x) {
            x0 = @max(x0, tx);
            x1 = @min(x1, tx + tw);
        }
        if (!rep_y) {
            y0 = @max(y0, ty);
            y1 = @min(y1, ty + th);
        }
        if (!(x1 > x0) or !(y1 > y0)) return;
        const reg: Rect = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
        const tile: Rect = .{ .x = tx, .y = ty, .w = tw, .h = th };
        const single = x0 >= tx and x1 <= tx + tw and y0 >= ty and y1 <= ty + th;

        var clipped = false;
        if (pa.radii != null) {
            const cid = try s.defClipRRect(pa.rect, pa.radii);
            s.raw("<g");
            s.attrRef("clip-path", cid);
            s.raw(">\n");
            clipped = true;
        }
        if (single and layer.image == .gradient) {
            // the region filled with the gradient laid out on the tile
            if (try s.gradientDef(layer.image.gradient, tile, cs.color)) |gid| try s.fillShape(reg, null, .{ .ref = gid });
        } else if (single) {
            const cover = x0 <= tx and y0 <= ty and x1 >= tx + tw and y1 >= ty + th;
            var rc = false;
            if (!cover) {
                const cid = try s.defClipRRect(reg, null);
                s.raw("<g");
                s.attrRef("clip-path", cid);
                s.raw(">\n");
                rc = true;
            }
            try s.drawImg(img, tile, cs.color);
            if (rc) s.closeG();
        } else {
            const pid = s.newId();
            // pattern content first (it may define gradients / clips of its own)
            var content: std.ArrayList(u8) = .empty;
            const saved = s.out;
            s.out = &content;
            const r = s.tileContent(cs, layer, img, .{ .x = 0, .y = 0, .w = tw, .h = th });
            s.out = saved;
            try r;
            s.raw("<pattern");
            s.attrId(pid);
            s.raw(" patternUnits=\"userSpaceOnUse\"");
            s.attrNum("x", tx);
            s.attrNum("y", ty);
            s.attrNum("width", tw);
            s.attrNum("height", th);
            s.raw(">\n");
            s.raw(content.items);
            s.raw("</pattern>\n");
            try s.fillShape(reg, null, .{ .ref = pid });
        }
        if (clipped) s.closeG();
    }

    fn tileContent(s: *S, cs: *const CS, layer: *const style.BgLayer, img: Img, tile: Rect) Error!void {
        if (layer.image == .gradient) {
            if (try s.gradientDef(layer.image.gradient, tile, cs.color)) |gid| try s.fillShape(tile, null, .{ .ref = gid });
            return;
        }
        try s.drawImg(img, tile, cs.color);
    }

    // ---- gradients

    /// Defines the gradient laid out on `tile` and returns its id (null = paints nothing).
    pub noinline fn gradientDef(s: *S, g: *const style.Gradient, tile: Rect, cur: Color) Error!?u32 {
        const w = tile.w;
        const h = tile.h;
        if (!(w > 0) or !(h > 0) or g.stops.len == 0) return null;
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
                const rs = style.gradient.resolveGradientStops(s.a, g, len, cur) catch return error.OutOfMemory;
                if (rs.len == 0) return null;
                const cx = tile.x + w * 0.5;
                const cy = tile.y + h * 0.5;
                var t0: f32 = 0;
                var t1: f32 = len;
                if (g.repeating) {
                    t0 = rs[0].offset_px;
                    t1 = rs[rs.len - 1].offset_px;
                    if (!(t1 - t0 > 1.0e-3)) return s.solidGradient(rs[rs.len - 1].color);
                }
                const stops = try s.svgStops(rs, t0, t1, g.repeating, 0);
                const id = s.newId();
                s.raw("<linearGradient");
                s.attrId(id);
                s.raw(" gradientUnits=\"userSpaceOnUse\"");
                if (g.repeating) s.raw(" spreadMethod=\"repeat\"");
                s.attrNum("x1", cx + (t0 - len * 0.5) * dx);
                s.attrNum("y1", cy + (t0 - len * 0.5) * dy);
                s.attrNum("x2", cx + (t1 - len * 0.5) * dx);
                s.attrNum("y2", cy + (t1 - len * 0.5) * dy);
                s.raw(">\n");
                try s.writeStops(stops);
                s.raw("</linearGradient>\n");
                return id;
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
                    .closest_corner, .farthest_corner => {
                        if (g.extent == .closest_corner) {
                            rx = @min(dl, dr);
                            ry = @min(dt, db);
                        } else {
                            rx = @max(dl, dr);
                            ry = @max(dt, db);
                        }
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
                const rs = style.gradient.resolveGradientStops(s.a, g, rx, cur) catch return error.OutOfMemory;
                if (rs.len == 0) return null;
                var r = rx;
                var stops: []Stop = undefined;
                if (g.repeating) {
                    const t0 = rs[0].offset_px;
                    const t1 = rs[rs.len - 1].offset_px;
                    if (!(t1 - t0 > 1.0e-3)) return s.solidGradient(rs[rs.len - 1].color);
                    r = t1 - t0;
                    // the pattern repeats from the centre: rotate the stop list by first / period
                    stops = try s.svgStops(rs, t0, t1, true, @mod(t0 / r, 1.0));
                } else stops = try s.svgStops(rs, 0, rx, false, 0);
                const cx = tile.x + px;
                const cy = tile.y + py;
                const id = s.newId();
                s.raw("<radialGradient");
                s.attrId(id);
                s.raw(" gradientUnits=\"userSpaceOnUse\"");
                if (g.repeating) s.raw(" spreadMethod=\"repeat\"");
                s.attrNum("cx", cx);
                s.attrNum("cy", cy);
                s.attrNum("r", r);
                const sy = ry / rx;
                if (@abs(sy - 1) > 1.0e-6) {
                    s.raw(" gradientTransform=\"matrix(1 0 0 ");
                    s.num(sy);
                    s.raw(" 0 ");
                    s.num(cy - sy * cy);
                    s.raw(")\"");
                }
                s.raw(">\n");
                try s.writeStops(stops);
                s.raw("</radialGradient>\n");
                return id;
            },
            .conic => return s.conicPattern(g, tile, cur),
        }
    }

    /// A one-colour paint server (degenerate repeating gradient).
    fn solidGradient(s: *S, c: Color) Error!?u32 {
        if (c.a == 0) return null;
        const id = s.newId();
        s.raw("<linearGradient");
        s.attrId(id);
        s.raw("><stop offset=\"0\"");
        s.attrColor("stop-color", "stop-opacity", c);
        s.raw("/></linearGradient>\n");
        return id;
    }

    /// Conic gradient as a pattern of 180 wedges coloured at their mid angle (takumi-svg).
    noinline fn conicPattern(s: *S, g: *const style.Gradient, tile: Rect, cur: Color) Error!?u32 {
        const w = tile.w;
        const h = tile.h;
        const rs = style.gradient.resolveGradientStops(s.a, g, 360, cur) catch return error.OutOfMemory;
        if (rs.len == 0) return null;
        const cx = tile.x + g.position[0].resolve(w);
        const cy = tile.y + g.position[1].resolve(h);
        var radius: f32 = 0;
        for ([4][2]f32{ .{ tile.x, tile.y }, .{ tile.x + w, tile.y }, .{ tile.x, tile.y + h }, .{ tile.x + w, tile.y + h } }) |c| {
            radius = @max(radius, @sqrt((c[0] - cx) * (c[0] - cx) + (c[1] - cy) * (c[1] - cy)));
        }
        radius += 1;
        const first = rs[0].offset_px;
        const period = rs[rs.len - 1].offset_px - first;
        const id = s.newId();
        s.raw("<pattern");
        s.attrId(id);
        s.raw(" patternUnits=\"userSpaceOnUse\"");
        s.attrNum("x", tile.x);
        s.attrNum("y", tile.y);
        s.attrNum("width", w);
        s.attrNum("height", h);
        // aliased wedges: anti-aliased translucent neighbours would leave seams
        s.raw(">\n<g shape-rendering=\"crispEdges\">\n");
        const wedges: u32 = 180;
        const step: f32 = 360.0 / @as(f32, @floatFromInt(wedges));
        var i: u32 = 0;
        while (i < wedges) : (i += 1) {
            const a0 = @as(f32, @floatFromInt(i)) * step;
            const a1 = a0 + step;
            var t = @mod((a0 + a1) * 0.5 - g.angle, 360.0);
            if (g.repeating and period > 1.0e-3) t = first + @mod(t - first, period);
            const c = sampleStops(rs, t);
            if (c.a == 0) continue;
            const r0 = rtypes.sinCos(a0 * (std.math.pi / 180.0));
            const r1 = rtypes.sinCos(a1 * (std.math.pi / 180.0));
            s.path.reset();
            s.path.moveTo(s.a, cx - tile.x, cy - tile.y) catch return error.OutOfMemory;
            s.path.lineTo(s.a, cx - tile.x + radius * r0[0], cy - tile.y - radius * r0[1]) catch return error.OutOfMemory;
            s.path.lineTo(s.a, cx - tile.x + radius * r1[0], cy - tile.y - radius * r1[1]) catch return error.OutOfMemory;
            s.path.close(s.a) catch return error.OutOfMemory;
            s.raw("<path");
            s.attrPath(&s.path, Affine.identity);
            s.attrColor("fill", "fill-opacity", c);
            s.raw("/>\n");
        }
        s.raw("</g></pattern>\n");
        return id;
    }

    /// SVG stop list for the resolved stops between `t0` and `t1` (px): offsets clipped to 0..1
    /// with interpolated end colours; intervals whose alpha changes are subdivided so SVG's
    /// straight-alpha interpolation follows the painter's premultiplied one. `shift` rotates a
    /// repeating list (radial gradients repeat from the centre).
    fn svgStops(s: *S, rs: []const style.gradient.ResolvedStop, t0: f32, t1: f32, repeating: bool, shift: f32) Error![]Stop {
        const span = @max(t1 - t0, 1.0e-6);
        var list: std.ArrayList(Stop) = .empty;
        // clip to [0, 1]
        var prev: ?Stop = null;
        for (rs) |r| {
            const st: Stop = .{ .o = (r.offset_px - t0) / span, .c = r.color };
            if (prev) |p| {
                if (p.o < 0 and st.o > 0) try list.append(s.a, .{ .o = 0, .c = lerpStop(p, st, 0) });
                if (p.o < 1 and st.o > 1) try list.append(s.a, .{ .o = 1, .c = lerpStop(p, st, 1) });
            }
            if (st.o >= 0 and st.o <= 1) try list.append(s.a, st);
            prev = st;
        }
        if (list.items.len == 0) {
            // every stop on one side of the range
            const c = if (rs[0].offset_px - t0 > 0) rs[0].color else rs[rs.len - 1].color;
            try list.append(s.a, .{ .o = 0, .c = c });
        }
        var items = list.items;
        if (repeating and shift > 0 and shift < 1) {
            var rot: std.ArrayList(Stop) = .empty;
            const at = 1 - shift;
            const edge = sampleList(items, at);
            try rot.append(s.a, .{ .o = 0, .c = edge });
            for (items) |st| if (st.o >= at) try rot.append(s.a, .{ .o = st.o - at, .c = st.c });
            for (items) |st| if (st.o < at) try rot.append(s.a, .{ .o = st.o + shift, .c = st.c });
            try rot.append(s.a, .{ .o = 1, .c = edge });
            items = rot.items;
        }
        // premultiplied interpolation across alpha changes
        var out: std.ArrayList(Stop) = .empty;
        for (items, 0..) |st, i| {
            if (i > 0) {
                const p = items[i - 1];
                if (p.c.a != st.c.a and st.o - p.o > 1.0e-4) {
                    const k: u32 = 8;
                    var j: u32 = 1;
                    while (j < k) : (j += 1) {
                        const t = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(k));
                        try out.append(s.a, .{ .o = p.o + (st.o - p.o) * t, .c = lerpPremul(p.c, st.c, t) });
                    }
                }
            }
            try out.append(s.a, st);
        }
        return out.items;
    }

    fn writeStops(s: *S, stops: []const Stop) Error!void {
        for (stops) |st| {
            s.raw("<stop");
            s.attrNum("offset", std.math.clamp(st.o, 0, 1));
            s.attrColor("stop-color", "stop-opacity", st.c);
            s.raw("/>\n");
        }
    }

    // ---- shadows

    noinline fn paintOuterShadows(s: *S, cs: *const CS, g: *const Geom) Error!void {
        var hole: ?u32 = null;
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
            const sigma = sh.blur * 0.5;
            if (hole == null) {
                try s.setRRect(&s.path2, g.bx, g.outerRadii());
                hole = try s.defClip(&s.path2, Affine.identity, false, true, false);
            }
            s.raw("<g");
            s.attrRef("clip-path", hole.?);
            s.raw(">\n");
            const blurred = sigma > 0.03;
            if (blurred) {
                const fid = try s.defBlur(sigma, r);
                s.raw("<g");
                s.attrRef("filter", fid);
                s.raw(">\n");
            }
            try s.fillRRect(r, radii, col);
            if (blurred) s.closeG();
            s.closeG();
        }
    }

    noinline fn paintInsetShadows(s: *S, cs: *const CS, g: *const Geom) Error!void {
        var any = false;
        for (cs.box_shadow) |sh| {
            if (sh.inset and cs.resolveColor(sh.color).a != 0) any = true;
        }
        if (!any) return;
        const pr = g.padRect();
        if (!(pr.w > 0) or !(pr.h > 0)) return;
        const prad = g.padRadii();
        const cid = try s.defClipRRect(pr, prad);
        s.raw("<g");
        s.attrRef("clip-path", cid);
        s.raw(">\n");
        var i = cs.box_shadow.len;
        while (i > 0) {
            i -= 1;
            const sh = cs.box_shadow[i];
            if (!sh.inset) continue;
            const col = cs.resolveColor(sh.color);
            if (col.a == 0) continue;
            const sigma = sh.blur * 0.5;
            const e = @ceil(3 * sigma) + 2;
            const within: Rect = .{ .x = @floor(pr.x) - e, .y = @floor(pr.y) - e, .w = @ceil(pr.w) + 2 * e + 1, .h = @ceil(pr.h) + 2 * e + 1 };
            const r: Rect = .{ .x = pr.x + sh.x + sh.spread, .y = pr.y + sh.y + sh.spread, .w = pr.w - 2 * sh.spread, .h = pr.h - 2 * sh.spread };
            s.path.reset();
            s.path.addRect(s.a, within) catch return error.OutOfMemory;
            if (r.w > 0 and r.h > 0) {
                const radii: ?Radii = if (prad) |rr| spreadRadii(rr, -sh.spread) else null;
                if (radii) |rr| {
                    s.path.addRoundRect(s.a, r, rr) catch return error.OutOfMemory;
                } else s.path.addRect(s.a, r) catch return error.OutOfMemory;
            }
            const blurred = sigma > 0.03;
            if (blurred) {
                const fid = try s.defBlur(sigma, within);
                s.raw("<g");
                s.attrRef("filter", fid);
                s.raw(">\n");
            }
            s.raw("<path");
            s.attrPath(&s.path, Affine.identity);
            s.attrColor("fill", "fill-opacity", col);
            s.raw(" fill-rule=\"evenodd\"/>\n");
            if (blurred) s.closeG();
        }
        s.closeG();
    }

    // ---- images

    noinline fn paintImage(s: *S, n: *const Node, g: *const Geom) Error!void {
        const cs = n.cs;
        const cr = g.contentRect();
        if (!(cr.w > 0) or !(cr.h > 0)) return;
        const svg_src = psvg.nodeSvgSource(n);
        if (n.img == null and svg_src == null) return;
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
                    const sc = @min(sx, sy);
                    dw = iw * sc;
                    dh = ih * sc;
                },
                .cover => {
                    const sc = @max(sx, sy);
                    dw = iw * sc;
                    dh = ih * sc;
                },
                .none => {
                    dw = iw;
                    dh = ih;
                },
                .scale_down => {
                    const sc = @min(1, @min(sx, sy));
                    dw = iw * sc;
                    dh = ih * sc;
                },
            }
        }
        const dx = cr.x + cs.object_position[0].resolve(cr.w - dw);
        const dy = cr.y + cs.object_position[1].resolve(cr.h - dh);
        const crad = g.contentRadii();
        const overflow = dx < cr.x or dy < cr.y or dx + dw > cr.x + cr.w or dy + dh > cr.y + cr.h;
        const clip = crad != null or overflow or svg_src != null;
        if (clip) {
            const cid = try s.defClipRRect(cr, crad);
            s.raw("<g");
            s.attrRef("clip-path", cid);
            s.raw(">\n");
        }
        const dest: Rect = .{ .x = dx, .y = dy, .w = dw, .h = dh };
        if (svg_src) |src| {
            try s.drawImg(.{ .svg = src }, dest, cs.color);
        } else try s.drawImg(.{ .bitmap = .{ .pm = n.img.?, .src = s.imageSrcOf(n) } }, dest, cs.color);
        if (clip) s.closeG();
    }

    /// The `src` an image node was built from (exact when render.zig records it in `Node.src`,
    /// else the DOM image element sharing its computed style; null = unknown).
    fn imageSrcOf(s: *S, n: *const Node) ?[]const u8 {
        if (comptime @hasField(Node, "src")) {
            if (n.src) |v| return v;
        }
        for (s.f.dom.els.items) |*el| {
            if (el.kind == .image and el.cs == n.cs) return el.src;
        }
        return null;
    }

    /// Draws an image stretched over `dest`.
    pub noinline fn drawImg(s: *S, img: Img, dest: Rect, current: Color) Error!void {
        if (!(dest.w > 0) or !(dest.h > 0)) return;
        switch (img) {
            .none => {},
            .svg => |src| {
                s.raw("<image");
                s.attrNum("x", dest.x);
                s.attrNum("y", dest.y);
                s.attrNum("width", dest.w);
                s.attrNum("height", dest.h);
                // the document keeps its own viewBox fitting (the painter's SVG renderer and
                // takumi lay it out in the box); without a viewBox it is stretched
                const root = svgRootTag(src);
                if (attrValue(root, "viewBox") == null) {
                    s.raw(" preserveAspectRatio=\"none\"");
                } else if (attrValue(root, "preserveAspectRatio")) |par| {
                    s.raw(" preserveAspectRatio=\"");
                    s.esc(par);
                    s.raw("\"");
                }
                s.raw(" href=\"data:image/svg+xml;base64,");
                try s.base64Svg(src, current);
                s.raw("\"/>\n");
            },
            .bitmap => |b| {
                const id = try s.imageDef(b.pm, b.src) orelse return;
                const w: f32 = @floatFromInt(b.pm.width);
                const h: f32 = @floatFromInt(b.pm.height);
                s.raw("<use href=\"#i");
                s.uint(id);
                s.raw("\"");
                s.attrMatrix(.{ .a = dest.w / w, .d = dest.h / h, .e = dest.x, .f = dest.y });
                s.raw("/>\n");
            },
        }
    }

    /// SVG markup as base64 with `currentColor` replaced by the element colour.
    fn base64Svg(s: *S, src: []const u8, current: Color) Error!void {
        var hex: [7]u8 = undefined;
        hex[0] = '#';
        hexByte(hex[1..3], current.r);
        hexByte(hex[3..5], current.g);
        hexByte(hex[5..7], current.b);
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < src.len) {
            if (src.len - i >= 12 and std.ascii.eqlIgnoreCase(src[i..][0..12], "currentcolor")) {
                try buf.appendSlice(s.a, &hex);
                i += 12;
            } else {
                try buf.append(s.a, src[i]);
                i += 1;
            }
        }
        s.base64(buf.items);
    }

    fn base64(s: *S, data: []const u8) void {
        if (s.failed != null) return;
        const enc = std.base64.standard.Encoder;
        const n = enc.calcSize(data.len);
        s.out.ensureUnusedCapacity(s.a, n) catch {
            s.failed = error.OutOfMemory;
            return;
        };
        const dst = s.out.unusedCapacitySlice()[0..n];
        _ = enc.encode(dst, data);
        s.out.items.len += n;
        s.put("");
    }

    /// Defines an image once (`<image id="i<n>">` in the trailing defs, at its pixel size) and
    /// returns its index: the original encoded bytes when known, else a PNG of the pixels.
    fn imageDef(s: *S, pmx: *const raster.Pixmap, src: ?[]const u8) Error!?u32 {
        return s.imageDefKeyed(pmx, src, if (src) |v| std.hash.Wyhash.hash(1, v) else @intFromPtr(pmx.data.ptr));
    }

    /// `imageDef` with an explicit dedupe key.
    pub noinline fn imageDefKeyed(s: *S, pmx: *const raster.Pixmap, src: ?[]const u8, key: u64) Error!?u32 {
        for (s.images.items) |d| if (d.key == key) return d.id;
        const id: u32 = @intCast(s.images.items.len);
        // write the definition into `defs`
        const saved = s.out;
        s.out = &s.defs;
        const r = s.imageDefBody(id, pmx, src);
        s.out = saved;
        if (!(try r)) return null;
        try s.images.append(s.a, .{ .key = key, .id = id });
        return id;
    }

    fn imageDefBody(s: *S, id: u32, pmx: *const raster.Pixmap, src: ?[]const u8) Error!bool {
        const mark = s.out.items.len;
        s.raw("<image id=\"i");
        s.uint(id);
        s.raw("\"");
        s.attrNum("width", @floatFromInt(pmx.width));
        s.attrNum("height", @floatFromInt(pmx.height));
        s.raw(" preserveAspectRatio=\"none\" href=\"");
        var done = false;
        if (src) |v| {
            if (std.mem.startsWith(u8, v, "data:")) {
                s.esc(v);
                done = true;
            } else {
                for (s.f.r.images.items) |*e| {
                    if (e.width != 0 or !std.mem.eql(u8, e.src, v)) continue;
                    const mime: []const u8 = switch (codec.sniff(e.data)) {
                        .png => "image/png",
                        .jpeg => "image/jpeg",
                        .webp => "image/webp",
                        .gif => "image/gif",
                        .bmp => "image/bmp",
                        .unknown => break,
                    };
                    s.raw("data:");
                    s.raw(mime);
                    s.raw(";base64,");
                    s.base64(e.data);
                    done = true;
                    break;
                }
            }
        }
        if (!done) {
            // pixels -> straight RGBA -> PNG
            const px = try s.a.dupe(u8, pmx.data);
            render.unpremultiply(px);
            const png = codec.encodePng(s.a, px, pmx.width, pmx.height, .{}) catch {
                s.out.items.len = mark;
                return false;
            };
            s.raw("data:image/png;base64,");
            s.base64(png);
        }
        s.raw("\"/>\n");
        return true;
    }

    // ---- clip-path / mask-image / filter

    /// `<clipPath>` of the element's `clip-path` (painter `clipPathMask` geometry); null = none.
    noinline fn clipPathDef(s: *S, cp: *const style.computed.ClipPath, cs: *const CS, bx: Rect, g: *const Geom) Error!?u32 {
        var box = bx;
        switch (cp.box) {
            .padding_box => box = g.padRect(),
            .content_box => box = g.contentRect(),
            else => {},
        }
        const w = box.w;
        const h = box.h;
        const path = &s.path2;
        path.reset();
        var evenodd = false;
        var tf = Affine.identity;
        const a = s.a;
        if (cp.shape) |shape| switch (shape) {
            .inset => |in| {
                const t = in.sides[0].resolve(h);
                const r = in.sides[1].resolve(w);
                const b = in.sides[2].resolve(h);
                const l = in.sides[3].resolve(w);
                const rc: Rect = .{ .x = box.x + l, .y = box.y + t, .w = w - l - r, .h = h - t - b };
                if (rc.w > 0 and rc.h > 0) {
                    var rr: Radii = undefined;
                    for (0..4) |i| {
                        rr[i] = .{ @max(0, in.radius[i][0].resolve(w)), @max(0, in.radius[i][1].resolve(h)) };
                        if (rr[i][0] <= 0 or rr[i][1] <= 0) rr[i] = .{ 0, 0 };
                    }
                    pm.scaleRadii(&rr, rc.w, rc.h);
                    try s.setRRect(path, rc, if (pm.hasAnyRadius(rr)) rr else null);
                }
            },
            .circle => |c| {
                const cx = c.at[0].resolve(w);
                const cy = c.at[1].resolve(h);
                const r: f32 = switch (c.r) {
                    .closest_side => @min(@min(@abs(cx), @abs(w - cx)), @min(@abs(cy), @abs(h - cy))),
                    .farthest_side => @max(@max(@abs(cx), @abs(w - cx)), @max(@abs(cy), @abs(h - cy))),
                    .lp => |v| v.resolve(@sqrt(w * w + h * h) / std.math.sqrt2),
                };
                try ellipsePath(a, path, box.x + cx, box.y + cy, r, r);
            },
            .ellipse => |e| {
                const cx = e.at[0].resolve(w);
                const cy = e.at[1].resolve(h);
                try ellipsePath(a, path, box.x + cx, box.y + cy, shapeRadius(e.rx, cx, w), shapeRadius(e.ry, cy, h));
            },
            .polygon => |pg| {
                evenodd = pg.rule == .evenodd;
                for (pg.points, 0..) |q, i| {
                    const px = box.x + q[0].resolve(w);
                    const py = box.y + q[1].resolve(h);
                    if (i == 0) {
                        path.moveTo(a, px, py) catch return error.OutOfMemory;
                    } else path.lineTo(a, px, py) catch return error.OutOfMemory;
                }
                if (pg.points.len > 0) path.close(a) catch return error.OutOfMemory;
            },
            .path => |pd| {
                evenodd = pd.rule == .evenodd;
                if (comptime pm.enable_svg) {
                    svg_path.parse(a, pd.d, path, null) catch return error.OutOfMemory;
                    const dpr = s.f.opts.dpr;
                    tf = Affine.translate(box.x, box.y).mul(Affine.scale(dpr, dpr));
                }
            },
        } else {
            if (cp.url.len > 0) return null;
            var rr = pm.resolveRadiiRaw(cs, w, h);
            pm.scaleRadii(&rr, w, h);
            try s.setRRect(path, box, if (pm.hasAnyRadius(rr)) rr else null);
        }
        if (path.isEmpty()) {
            // clips everything
            path.addRect(a, .{ .x = 0, .y = 0, .w = 0, .h = 0 }) catch return error.OutOfMemory;
        }
        return try s.defClip(path, tf, evenodd, false, false);
    }

    /// `<mask>` of the element's `mask-image` layers over its border box (alpha, or luminance
    /// when a layer asks for it), intersected with the rounded border box.
    noinline fn maskDef(s: *S, ctx: *const Ctx, cs: *const CS, g: *const Geom) Error!u32 {
        _ = ctx;
        var luma = false;
        for (0..cs.mask_image.len) |i| {
            if (cs.maskLayer(i).mode == .luminance and cs.mask_image[i] != .none) luma = true;
        }
        // layer content first (it defines gradients / patterns)
        var content: std.ArrayList(u8) = .empty;
        const saved = s.out;
        s.out = &content;
        const r = s.maskContent(cs, g);
        s.out = saved;
        try r;
        const id = s.newId();
        s.raw("<mask");
        s.attrId(id);
        s.raw(" maskUnits=\"userSpaceOnUse\"");
        s.raw(if (luma) " style=\"mask-type:luminance\"" else " style=\"mask-type:alpha\"");
        s.attrNum("x", g.bx.x);
        s.attrNum("y", g.bx.y);
        s.attrNum("width", g.bx.w);
        s.attrNum("height", g.bx.h);
        s.raw(">\n");
        s.raw(content.items);
        s.raw("</mask>\n");
        return id;
    }

    fn maskContent(s: *S, cs: *const CS, g: *const Geom) Error!void {
        var clipped = false;
        if (g.rounded) {
            const cid = try s.defClipRRect(g.bx, g.radii);
            s.raw("<g");
            s.attrRef("clip-path", cid);
            s.raw(">\n");
            clipped = true;
        }
        var i = cs.mask_image.len;
        while (i > 0) {
            i -= 1;
            const ml = cs.maskLayer(i);
            if (ml.image == .none) continue;
            try s.paintBgLayer(cs, g, &.{ .image = ml.image, .size = ml.size, .position = ml.position, .repeat = ml.repeat, .clip = ml.clip, .origin = ml.origin }, false);
        }
        if (clipped) s.closeG();
    }

    /// `backdrop-filter` (takumi-svg `emit_backdrop`): everything painted before the element,
    /// replayed from the root in canvas space, filtered and clipped to the (rounded) border box.
    /// Opaque alpha is restored after the filters (SVG has no mirrored edges) unless the chain
    /// changes opacity. A replay does not replay nested backdrops.
    noinline fn backdrop(s: *S, id: u32, ctx: *const Ctx, cs: *const CS, g: *const Geom) Error!void {
        if (!(g.bx.w > 0) or !(g.bx.h > 0)) return;
        var any = false;
        for (cs.backdrop_filter) |fl| {
            if (fl != .drop_shadow) any = true;
        }
        if (!any) return;
        const inv = ctx.tf.invert() orelse return;
        const cid = try s.defClipRRect(g.bx, g.outerRadii());
        const fid = try s.filterDefEx(cs.backdrop_filter, cs, g.bx);
        s.raw("<g");
        s.attrRef("clip-path", cid);
        s.raw("><g");
        s.attrRef("filter", fid);
        s.raw("><g");
        s.attrRef("clip-path", cid);
        s.raw(">\n");
        if (!ctx.tf.isIdentity()) s.gTransform(inv);
        const mark = s.outlines.items.len;
        s.stop_at = id;
        s.stopped = false;
        const root_ctx: Ctx = .{ .dst = &s.dummy };
        const r = s.paintNode(s.f.root, 0, 0, &root_ctx, 0);
        s.stop_at = none;
        s.stopped = false;
        try r;
        s.outlines.shrinkRetainingCapacity(mark);
        if (!ctx.tf.isIdentity()) s.closeG();
        s.raw("</g></g></g>\n");
    }

    /// One chained `<filter>` for the element's `filter` list (takumi-svg `function_chain_filter`).
    fn filterDef(s: *S, filters: []const style.Filter, cs: *const CS) Error!u32 {
        return s.filterDefEx(filters, cs, null);
    }

    /// `backdrop_box` != null: a backdrop-filter chain over that box (drop shadows skipped, opaque
    /// alpha restored unless an `opacity()` is part of it).
    noinline fn filterDefEx(s: *S, filters: []const style.Filter, cs: *const CS, backdrop_box: ?Rect) Error!u32 {
        const id = s.newId();
        s.raw("<filter");
        s.attrId(id);
        // bounding-box region (takumi-svg): an empty backdrop is not filtered (no alpha restore)
        s.raw(" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\" color-interpolation-filters=\"sRGB\">\n");
        var restore = backdrop_box != null;
        var prev: u32 = 0; // 0 = SourceGraphic
        for (filters, 1..) |fl, k| {
            const res: u32 = @intCast(@min(k, 1 << 20));
            if (backdrop_box != null) switch (fl) {
                .drop_shadow => continue,
                .opacity => restore = false,
                else => {},
            };
            switch (fl) {
                .blur => |r| {
                    s.raw("<feGaussianBlur");
                    s.feIn(prev);
                    s.attrNum("stdDeviation", r);
                    s.feResult(res);
                    s.raw("/>\n");
                },
                .brightness => |v| try s.transfer(prev, res, "linear", v, 0, null),
                .contrast => |v| try s.transfer(prev, res, "linear", v, 0.5 - 0.5 * v, null),
                .invert => |v_in| {
                    const v = std.math.clamp(v_in, 0, 1);
                    try s.transfer(prev, res, "table", 0, 0, .{ v, 1 - v });
                },
                .saturate => |v| {
                    s.raw("<feColorMatrix");
                    s.feIn(prev);
                    s.raw(" type=\"saturate\"");
                    s.attrNum("values", v);
                    s.feResult(res);
                    s.raw("/>\n");
                },
                .hue_rotate => |v| {
                    s.raw("<feColorMatrix");
                    s.feIn(prev);
                    s.raw(" type=\"hueRotate\"");
                    s.attrNum("values", v);
                    s.feResult(res);
                    s.raw("/>\n");
                },
                .grayscale, .sepia => |v_in| {
                    const t = 1 - std.math.clamp(v_in, 0, 1);
                    const m: [3][3]f32 = if (fl == .grayscale) .{
                        .{ 0.2126 + 0.7874 * t, 0.7152 - 0.7152 * t, 0.0722 - 0.0722 * t },
                        .{ 0.2126 - 0.2126 * t, 0.7152 + 0.2848 * t, 0.0722 - 0.0722 * t },
                        .{ 0.2126 - 0.2126 * t, 0.7152 - 0.7152 * t, 0.0722 + 0.9278 * t },
                    } else .{
                        .{ 0.393 + 0.607 * t, 0.769 - 0.769 * t, 0.189 - 0.189 * t },
                        .{ 0.349 - 0.349 * t, 0.686 + 0.314 * t, 0.168 - 0.168 * t },
                        .{ 0.272 - 0.272 * t, 0.534 - 0.534 * t, 0.131 + 0.869 * t },
                    };
                    s.raw("<feColorMatrix");
                    s.feIn(prev);
                    s.raw(" type=\"matrix\" values=\"");
                    for (m) |row| {
                        for (row) |v| {
                            s.num(v);
                            s.raw(" ");
                        }
                        s.raw("0 0 ");
                    }
                    s.raw("0 0 0 1 0\"");
                    s.feResult(res);
                    s.raw("/>\n");
                },
                .opacity => |v| {
                    s.raw("<feComponentTransfer");
                    s.feIn(prev);
                    s.feResult(res);
                    s.raw("><feFuncA type=\"linear\"");
                    s.attrNum("slope", std.math.clamp(v, 0, 1));
                    s.raw("/></feComponentTransfer>\n");
                },
                .drop_shadow => |sh| {
                    const col = cs.resolveColor(sh.color);
                    s.raw("<feGaussianBlur in=\"SourceAlpha\"");
                    s.attrNum("stdDeviation", sh.blur);
                    s.raw(" result=\"dsb\"/>\n<feOffset in=\"dsb\"");
                    s.attrNum("dx", @floor(sh.x));
                    s.attrNum("dy", @floor(sh.y));
                    s.raw(" result=\"dso\"/>\n<feFlood");
                    s.attrColor("flood-color", "flood-opacity", col);
                    s.raw(" result=\"dsc\"/>\n<feComposite in=\"dsc\" in2=\"dso\" operator=\"in\" result=\"dss\"/>\n<feMerge");
                    s.feResult(res);
                    s.raw("><feMergeNode in=\"dss\"/><feMergeNode");
                    s.feIn(prev);
                    s.raw("/></feMerge>\n");
                },
            }
            prev = res;
        }
        if (restore) {
            s.raw("<feComponentTransfer");
            s.feIn(prev);
            s.raw("><feFuncA type=\"discrete\" tableValues=\"1\"/></feComponentTransfer>\n");
        }
        s.raw("</filter>\n");
        return id;
    }

    fn feIn(s: *S, prev: u32) void {
        if (prev == 0) return s.raw(" in=\"SourceGraphic\"");
        s.raw(" in=\"f");
        s.uint(prev);
        s.raw("\"");
    }

    fn feResult(s: *S, res: u32) void {
        s.raw(" result=\"f");
        s.uint(res);
        s.raw("\"");
    }

    fn transfer(s: *S, prev: u32, res: u32, kind: []const u8, slope: f32, intercept: f32, table: ?[2]f32) Error!void {
        s.raw("<feComponentTransfer");
        s.feIn(prev);
        s.feResult(res);
        s.raw(">");
        for ([_][]const u8{ "R", "G", "B" }) |ch| {
            s.raw("<feFunc");
            s.raw(ch);
            s.raw(" type=\"");
            s.raw(kind);
            s.raw("\"");
            if (table) |t| {
                s.raw(" tableValues=\"");
                s.num(t[0]);
                s.raw(" ");
                s.num(t[1]);
                s.raw("\"");
            } else {
                s.attrNum("slope", slope);
                if (intercept != 0) s.attrNum("intercept", intercept);
            }
            s.raw("/>");
        }
        s.raw("</feComponentTransfer>\n");
    }
};

pub const Paint = union(enum) { color: Color, ref: u32 };

pub const Img = union(enum) {
    none,
    bitmap: struct { pm: *const raster.Pixmap, src: ?[]const u8 },
    svg: []const u8,
};

const Stop = struct { o: f32, c: Color };

// ------------------------------------------------------------------------------------------------
// helpers

fn eqAffine(x: Affine, y: Affine) bool {
    return x.a == y.a and x.b == y.b and x.c == y.c and x.d == y.d and x.e == y.e and x.f == y.f;
}

fn blendName(m: style.computed.BlendMode) []const u8 {
    return switch (m) {
        .normal, .plus_darker => "",
        .multiply => "multiply",
        .screen => "screen",
        .overlay => "overlay",
        .darken => "darken",
        .lighten => "lighten",
        .color_dodge => "color-dodge",
        .color_burn => "color-burn",
        .hard_light => "hard-light",
        .soft_light => "soft-light",
        .difference => "difference",
        .exclusion => "exclusion",
        .hue => "hue",
        .saturation => "saturation",
        .color => "color",
        .luminosity => "luminosity",
        .plus_lighter => "plus-lighter",
    };
}

/// The text of the root `<svg ...>` start tag of `src` ("" when not found).
fn svgRootTag(src: []const u8) []const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, "<svg")) |at| {
        const after = at + 4;
        if (after < src.len and (src[after] == ' ' or src[after] == '>' or src[after] == '\n' or src[after] == '\t' or src[after] == '\r' or src[after] == '/')) {
            const end = std.mem.indexOfScalarPos(u8, src, after, '>') orelse return src[after..];
            return src[after..end];
        }
        i = after;
    }
    return "";
}

/// Value of attribute `name` in a start tag's text (quoted with ' or ").
fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag, i, name)) |at| {
        i = at + name.len;
        if (at > 0 and !std.ascii.isWhitespace(tag[at - 1])) continue;
        var j = i;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) j += 1;
        if (j >= tag.len or (tag[j] != '"' and tag[j] != '\'')) continue;
        const q = tag[j];
        const end = std.mem.indexOfScalarPos(u8, tag, j + 1, q) orelse return null;
        return tag[j + 1 .. end];
    }
    return null;
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

/// Painted in the positioned / stacking-context phase (painter `stacks`).
fn stacks(cs: *const CS) bool {
    return cs.z_index != null or cs.position != .static or pfx.needsGroup(cs) or cs.offset_path != null or cs.transform.len > 0 or cs.rotate != 0 or cs.scale[0] != 1 or cs.scale[1] != 1;
}

/// The element's transform in absolute coordinates (painter `localTransform`).
noinline fn localTransform(cs: *const CS, x: f32, y: f32, w: f32, h: f32) ?Affine {
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

fn shapeRadius(r: style.computed.ShapeRadius, c: f32, full: f32) f32 {
    return switch (r) {
        .closest_side => @min(@abs(c), @abs(full - c)),
        .farthest_side => @max(@abs(c), @abs(full - c)),
        .lp => |v| v.resolve(full),
    };
}

fn ellipsePath(a: Allocator, path: *Path, cx: f32, cy: f32, rx: f32, ry: f32) Error!void {
    if (!(rx > 0) or !(ry > 0)) return;
    const k: f32 = 0.552_284_8;
    const ox = rx * k;
    const oy = ry * k;
    path.moveTo(a, cx + rx, cy) catch return error.OutOfMemory;
    path.cubicTo(a, cx + rx, cy + oy, cx + ox, cy + ry, cx, cy + ry) catch return error.OutOfMemory;
    path.cubicTo(a, cx - ox, cy + ry, cx - rx, cy + oy, cx - rx, cy) catch return error.OutOfMemory;
    path.cubicTo(a, cx - rx, cy - oy, cx - ox, cy - ry, cx, cy - ry) catch return error.OutOfMemory;
    path.cubicTo(a, cx + ox, cy - ry, cx + rx, cy - oy, cx + rx, cy) catch return error.OutOfMemory;
    path.close(a) catch return error.OutOfMemory;
}

fn premul(c: Color) [4]f32 {
    const af = @as(f32, @floatFromInt(c.a));
    return .{ @as(f32, @floatFromInt(c.r)) * af / 255.0, @as(f32, @floatFromInt(c.g)) * af / 255.0, @as(f32, @floatFromInt(c.b)) * af / 255.0, af };
}

/// Premultiplied lerp, demultiplied (the painter's legacy-sRGB gradient interpolation).
fn lerpPremul(x: Color, y: Color, t: f32) Color {
    const p = premul(x);
    const q = premul(y);
    var m: [4]f32 = undefined;
    for (0..4) |i| m[i] = p[i] + (q[i] - p[i]) * t;
    if (!(m[3] >= 0.5)) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    var out: Color = .{ .a = @intFromFloat(std.math.clamp(@round(m[3]), 0, 255)) };
    out.r = @intFromFloat(std.math.clamp(@round(m[0] * 255.0 / m[3]), 0, 255));
    out.g = @intFromFloat(std.math.clamp(@round(m[1] * 255.0 / m[3]), 0, 255));
    out.b = @intFromFloat(std.math.clamp(@round(m[2] * 255.0 / m[3]), 0, 255));
    return out;
}

fn lerpStop(p: Stop, q: Stop, at: f32) Color {
    const d = q.o - p.o;
    if (!(d > 0)) return q.c;
    return lerpPremul(p.c, q.c, std.math.clamp((at - p.o) / d, 0, 1));
}

fn sampleList(list: []const Stop, at: f32) Color {
    if (list.len == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (at <= list[0].o) return list[0].c;
    for (list[1..], 1..) |q, i| {
        if (at <= q.o) return lerpStop(list[i - 1], q, at);
    }
    return list[list.len - 1].c;
}

/// Colour of resolved stops at `t` px (clamped at the ends).
pub fn sampleStops(rs: []const style.gradient.ResolvedStop, t: f32) Color {
    if (t <= rs[0].offset_px) return rs[0].color;
    for (rs[1..], 1..) |q, i| {
        if (t <= q.offset_px) {
            const p = rs[i - 1];
            const d = q.offset_px - p.offset_px;
            if (!(d > 0)) return q.color;
            return lerpPremul(p.color, q.color, (t - p.offset_px) / d);
        }
    }
    return rs[rs.len - 1].color;
}

test "num formatting" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", fmtNum(&b, 0));
    try std.testing.expectEqualStrings(".5", fmtNum(&b, 0.5));
    try std.testing.expectEqualStrings("-1.25", fmtNum(&b, -1.25));
    try std.testing.expectEqualStrings("1200", fmtNum(&b, 1200));
    try std.testing.expectEqualStrings(".502", fmtNum(&b, 128.0 / 255.0));
    try std.testing.expectEqualStrings("1000000", fmtNum(&b, 1.0e6));
    try std.testing.expectEqualStrings("0", fmtNum(&b, std.math.nan(f32)));
}

test "path data (relative, quantized, shorthands)" {
    const a = std.testing.allocator;
    var path: Path = .empty;
    defer path.deinit(a);
    try path.addRoundRect(a, .{ .x = 500, .y = 265, .w = 200, .h = 100 }, .{ .{ 20, 20 }, .{ 20, 20 }, .{ 20, 20 }, .{ 20, 20 } });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writePathTo(a, &out, &path, Affine.identity);
    // takumi-svg golden `clip_path_inset_rounded.svg` writes the same outline
    try std.testing.expectEqualStrings("M520 265h160c11.05 0 20 8.95 20 20v60c0 11.05-8.95 20-20 20h-160c-11.05 0-20-8.95-20-20v-60c0-11.05 8.95-20 20-20Z", out.items);
}

test "svg root attributes" {
    const tag = svgRootTag("<?xml version=\"1.0\"?><svg xmlns=\"x\" viewBox='0 0 24 24' preserveAspectRatio=\"xMinYMin slice\"><svgx/></svg>");
    try std.testing.expectEqualStrings("0 0 24 24", attrValue(tag, "viewBox").?);
    try std.testing.expectEqualStrings("xMinYMin slice", attrValue(tag, "preserveAspectRatio").?);
    try std.testing.expect(attrValue(svgRootTag("<svg width=\"2\">"), "viewBox") == null);
}
