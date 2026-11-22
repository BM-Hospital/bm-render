//! Render-tree walk: shapes, groups, use/symbol, nested svg, paint servers, clip paths,
//! masks, filters, images, markers.
const std = @import("std");
const raster = @import("../raster/raster.zig");
const codec = @import("../codec/codec.zig");
const dom = @import("dom.zig");
const num = @import("num.zig");
const color = @import("color.zig");
const style = @import("style.zig");
const pathdata = @import("pathdata.zig");
const stroke = @import("stroke.zig");
const filter = @import("filter.zig");
const xml = @import("xml.zig");
const css = @import("css.zig");

const Allocator = std.mem.Allocator;
const Affine = raster.Affine;
const Pixmap = raster.Pixmap;
const ClipMask = raster.ClipMask;
const IRect = raster.IRect;
const Rect = raster.Rect;
const Path = raster.Path;
const Color = raster.Color;
const Node = dom.Node;
const Style = style.Style;
const NONE = dom.NONE;

pub const Error = error{ OutOfMemory, InvalidSvg };

/// Text drawing request handed to `RenderOptions.text` for each `<text>` element.
pub const TextRequest = struct {
    /// Character data of the element and its descendants, whitespace collapsed.
    text: []const u8,
    /// First glyph position (user units; `x` / `y` attributes of the text element).
    x: f32,
    y: f32,
    font_size: f32,
    font_family: []const u8,
    font_weight: []const u8,
    text_anchor: []const u8,
    /// Resolved solid fill (opacity applied); null when the fill is none or a paint server.
    fill: ?Color,
    /// user space -> `dst` pixel space
    transform: Affine,
    dst: *Pixmap,
    clip: ?*const ClipMask,
};

pub const TextHook = struct {
    ctx: *anyopaque,
    draw: *const fn (ctx: *anyopaque, req: *const TextRequest) void,
};

pub const RenderOptions = struct {
    /// Value of `currentColor` at the root (the CSS `color` of the image box).
    current_color: Color = Color.black,
    /// Optional text renderer (text is not drawn without it).
    text: ?TextHook = null,
    /// Nesting allowed for `<image href="data:image/svg+xml,...">` (0 disables nested SVG).
    max_nested_svg: u8 = 2,
    /// width*height of a decoded `<image>` (never above the built-in 16 Mi pixels).
    max_image_pixels: u64 = 16 << 20,
};

const MAX_RENDER_DEPTH = 96;
const MAX_INSTANCES = 100_000;
const MAX_PAINTED = 4_000_000;
const MAX_ACTIVE = 32;
const MAX_IMAGE_BYTES = 32 << 20;

const Ctx = struct {
    dst: *Pixmap,
    clip: ?ClipMask,
    ctm: Affine,
    vw: f32,
    vh: f32,
    st: Style,
    /// group opacity folded into a single shape's paint
    alpha: f32 = 1,

    fn region(c: *const Ctx) IRect {
        var r = c.dst.bounds();
        if (c.clip) |cl| r = r.intersect(cl.bounds);
        return r;
    }

    fn clipPtr(c: *const Ctx) ?*const ClipMask {
        return if (c.clip) |*cl| cl else null;
    }

    fn diag(c: *const Ctx) f32 {
        return @sqrt((c.vw * c.vw + c.vh * c.vh) / 2);
    }
};

/// Comptime feature switches (disabled features compile out; the element / property is then ignored).
pub const Features = struct {
    filters: bool = true,
    masks: bool = true,
    clip_paths: bool = true,
    patterns: bool = true,
    markers: bool = true,
    /// `<image>` (codec decode + nested SVG documents)
    images: bool = true,
    /// `<style>` sheets (style attributes and presentation attributes always work)
    stylesheets: bool = true,
};

pub fn Renderer(comptime F: Features) type {
    return struct {
    const Self = @This();
    a: Allocator,
    rast: *raster.Rasterizer,
    doc: *const dom.Document,
    opts: RenderOptions,
    stroker: stroke.Stroker = .{},
    tmp2: Path = .{},
    outline: Path = .{},
    verts: std.ArrayList(pathdata.Vertex) = .empty,
    cache: []?*Path = &.{},
    instances: u32 = 0,
    painted: usize = 0,
    /// device pixels covered by fills so far (bounds amplification through <use>)
    area: u64 = 0,
    area_limit: u64 = 1 << 28,
    surface_bytes: usize = 0,
    surface_limit: usize = 64 << 20,
    image_bytes: usize = 0,
    depth: u32 = 0,
    active: [MAX_ACTIVE]u32 = undefined,
    n_active: u32 = 0,
    nested_level: u8 = 0,

    // ---- entry ----------------------------------------------------------------------------

    pub fn renderRoot(r: *Self, dst: *Pixmap, dest: Rect, clip: ?*const ClipMask) Error!void {
        if (!(dest.w > 0 and dest.h > 0) or !num.finite(dest.x + dest.y + dest.w + dest.h)) return;
        if (!dst.isValid()) return;
        const area = @as(usize, dst.width) * dst.height * 4;
        r.surface_limit = @max(64 << 20, area *| 24);
        r.area_limit = @max(1 << 26, @as(u64, area) * 64);
        r.cache = try r.a.alloc(?*Path, r.doc.nodes.len);
        @memset(r.cache, null);
        const root = r.doc.root();
        const isz = intrinsic(root);
        var ctm = Affine.translate(dest.x, dest.y);
        var vw: f32 = undefined;
        var vh: f32 = undefined;
        if (isz.view_box) |vb| {
            ctm = ctm.mul(num.viewBoxTransform(vb, num.parseAspectRatio(root.attr("preserveAspectRatio")), dest.w, dest.h));
            vw = vb[2];
            vh = vb[3];
        } else {
            vw = isz.width orelse 100;
            vh = isz.height orelse 100;
            ctm = ctm.mul(Affine.scale(dest.w / vw, dest.h / vh));
        }
        var c: Ctx = .{
            .dst = dst,
            .clip = if (clip) |cl| cl.* else null,
            .ctm = ctm,
            .vw = vw,
            .vh = vh,
            .st = .{ .color = r.opts.current_color },
        };
        // the root viewport clips its content (to the rounded-out pixel rect: an anti-aliased
        // clip would attenuate edge pixels twice, content already anti-aliases its own edges)
        const vp = num.roundOut(dest).intersect(c.region());
        if (vp.isEmpty()) return;
        c.clip = if (c.clip) |cl| (if (cl.data != null) try r.intersectClip(cl, .{ .bounds = vp }) orelse return else ClipMask{ .bounds = vp }) else ClipMask{ .bounds = vp };
        try r.renderNode(&c, 0, true);
    }

    // ---- tree walk --------------------------------------------------------------------------

    fn renderChildren(r: *Self, c: *const Ctx, idx: u32) Error!void {
        var ch = r.doc.nodes[idx].first_child;
        while (ch != NONE) : (ch = r.doc.nodes[ch].next_sibling) try r.renderNode(c, ch, false);
    }

    fn isGraphic(t: dom.Tag) bool {
        return switch (t) {
            .svg, .g, .a, .@"switch", .use, .image, .text => true,
            else => t.isShape(),
        };
    }

    noinline fn renderNode(r: *Self, pc: *const Ctx, idx: u32, is_root: bool) Error!void {
        const n = &r.doc.nodes[idx];
        if (!isGraphic(n.tag)) return;
        if (r.depth >= MAX_RENDER_DEPTH or r.instances >= MAX_INSTANCES or r.painted >= MAX_PAINTED) return;
        if (n.decl(.display)) |d| if (std.mem.eql(u8, num.trim(d), "none")) return;
        r.instances += 1;
        r.depth += 1;
        defer r.depth -= 1;

        var c = pc.*;
        c.alpha = 1;
        c.st.apply(n);
        if (!is_root) {
            if (n.decl(.transform)) |ts| {
                if (num.parseTransform(ts)) |t| c.ctm = c.ctm.mul(t);
            }
        }
        if (!c.ctm.isFinite()) return;
        if (c.ctm.a * c.ctm.d - c.ctm.b * c.ctm.c == 0) return;

        const op = if (n.decl(.opacity)) |v| style.opacity(v) orelse 1 else 1;
        if (op <= 0) return;
        const clip_ref = if (F.clip_paths) refOf(n.decl(.clip_path)) else null;
        const mask_ref = if (F.masks) refOf(n.decl(.mask)) else null;
        const filter_ref = if (F.filters) refOf(n.decl(.filter)) else null;
        var bm: filter.BlendMode = .normal;
        if (F.filters) if (n.decl(.mix_blend_mode)) |v| {
            bm = filter.blendMode(v);
        };
        const isolate = F.filters and if (n.decl(.isolation)) |v| std.mem.eql(u8, num.trim(v), "isolate") else false;
        if (op >= 1 and clip_ref == null and mask_ref == null and filter_ref == null and bm == .normal and !isolate) {
            return r.renderContent(&c, idx);
        }
        // a lone shape painting only fill or only stroke: fold opacity into the paint
        if (clip_ref == null and mask_ref == null and filter_ref == null and bm == .normal and !isolate and n.tag.isShape() and r.singlePaint(&c)) {
            c.alpha = op;
            return r.renderContent(&c, idx);
        }
        return r.renderEffects(&c, idx, op, bm, isolate, clip_ref, mask_ref, filter_ref);
    }

    fn singlePaint(r: *Self, c: *const Ctx) bool {
        _ = r;
        const has_fill = c.st.fill.kind != .none;
        const has_stroke = c.st.stroke.kind != .none;
        const markers = c.st.marker_start.len + c.st.marker_mid.len + c.st.marker_end.len > 0;
        return !(has_fill and has_stroke) and !markers;
    }

    fn refOf(v: ?[]const u8) ?[]const u8 {
        const s = num.trim(v orelse return null);
        if (!std.mem.startsWith(u8, s, "url(")) return null;
        return s;
    }

    fn renderContent(r: *Self, c: *const Ctx, idx: u32) Error!void {
        const n = &r.doc.nodes[idx];
        switch (n.tag) {
            .g, .a => try r.renderChildren(c, idx),
            .svg => {
                if (idx == 0) return r.renderChildren(c, idx);
                try r.renderViewport(c, idx, idx, null, null);
            },
            .@"switch" => {
                var ch = n.first_child;
                while (ch != NONE) : (ch = r.doc.nodes[ch].next_sibling) {
                    const cn = &r.doc.nodes[ch];
                    if (!isGraphic(cn.tag) or !conditionsPass(cn)) continue;
                    try r.renderNode(c, ch, false);
                    break;
                }
            },
            .use => try r.renderUse(c, idx),
            .image => if (F.images) try r.drawImage(c, idx),
            .text => r.drawText(c, idx),
            else => try r.drawShape(c, idx),
        }
    }

    fn conditionsPass(n: *const Node) bool {
        if (n.attr("requiredExtensions")) |_| return false;
        if (n.attr("systemLanguage")) |l| {
            var it = std.mem.tokenizeAny(u8, l, ", ");
            while (it.next()) |t| if (std.mem.startsWith(u8, t, "en")) return true;
            return false;
        }
        return true;
    }

    fn push(r: *Self, idx: u32) bool {
        for (r.active[0..r.n_active]) |x| if (x == idx) return false;
        if (r.n_active >= MAX_ACTIVE) return false;
        r.active[r.n_active] = idx;
        r.n_active += 1;
        return true;
    }

    fn pop(r: *Self) void {
        r.n_active -= 1;
    }

    /// Nested `<svg>` / `<symbol>` viewport. `w_over` / `h_over` come from a referencing `<use>`.
    fn renderViewport(r: *Self, pc: *const Ctx, idx: u32, attr_src: u32, w_over: ?f32, h_over: ?f32) Error!void {
        const n = &r.doc.nodes[idx];
        const an = &r.doc.nodes[attr_src];
        var c = pc.*;
        const x = r.len(&c, an.attr("x"), .x, 0);
        const y = r.len(&c, an.attr("y"), .y, 0);
        const w = w_over orelse r.len(&c, n.attr("width"), .x, c.vw);
        const h = h_over orelse r.len(&c, n.attr("height"), .y, c.vh);
        if (!(w > 0 and h > 0)) return;
        c.ctm = c.ctm.mul(Affine.translate(x, y));
        const overflow = if (n.decl(.overflow)) |o| num.trim(o) else "hidden";
        if (!std.mem.eql(u8, overflow, "visible") and !std.mem.eql(u8, overflow, "auto")) {
            c.clip = try r.clipToRect(&c, c.ctm, .{ .x = 0, .y = 0, .w = w, .h = h }) orelse return;
        }
        if (num.parseViewBox(n.attr("viewBox") orelse "")) |vb| {
            c.ctm = c.ctm.mul(num.viewBoxTransform(vb, num.parseAspectRatio(n.attr("preserveAspectRatio")), w, h));
            c.vw = vb[2];
            c.vh = vb[3];
        } else {
            c.vw = w;
            c.vh = h;
        }
        try r.renderChildren(&c, idx);
    }

    fn renderUse(r: *Self, c: *const Ctx, idx: u32) Error!void {
        const n = &r.doc.nodes[idx];
        const href = n.attr("href") orelse return;
        const target = r.doc.byRef(href) orelse return;
        if (target == 0 or !r.push(target)) return;
        defer r.pop();
        // a <use> may not reference one of its own ancestors
        var p = n.parent;
        while (p != NONE) : (p = r.doc.nodes[p].parent) if (p == target) return;
        const tn = &r.doc.nodes[target];
        var cc = c.*;
        if (tn.tag == .symbol or tn.tag == .svg) {
            const w = if (n.attr("width")) |s| r.lenOpt(c, s, .x) else null;
            const h = if (n.attr("height")) |s| r.lenOpt(c, s, .y) else null;
            if (tn.decl(.display)) |d| if (std.mem.eql(u8, num.trim(d), "none")) return;
            cc.st.apply(tn);
            if (tn.tag == .svg) {
                if (tn.decl(.transform)) |ts| if (num.parseTransform(ts)) |t| {
                    cc.ctm = cc.ctm.mul(t);
                };
            }
            cc.ctm = cc.ctm.mul(Affine.translate(r.len(c, n.attr("x"), .x, 0), r.len(c, n.attr("y"), .y, 0)));
            return r.renderViewport(&cc, target, target, w, h);
        }
        cc.ctm = cc.ctm.mul(Affine.translate(r.len(c, n.attr("x"), .x, 0), r.len(c, n.attr("y"), .y, 0)));
        try r.renderNode(&cc, target, false);
    }

    // ---- lengths ----------------------------------------------------------------------------

    fn len(r: *Self, c: *const Ctx, s: ?[]const u8, axis: num.Axis, def: f32) f32 {
        return r.lenOpt(c, s orelse return def, axis) orelse def;
    }

    fn lenOpt(r: *Self, c: *const Ctx, s: []const u8, axis: num.Axis) ?f32 {
        _ = r;
        const l = num.parseLength(s) orelse return null;
        const ref = switch (axis) {
            .x => c.vw,
            .y => c.vh,
            .other => c.diag(),
        };
        return num.resolve(l, ref, c.st.font_size);
    }

    // ---- geometry ---------------------------------------------------------------------------

    /// Path of a shape element in its user space; null when it renders nothing.
    /// Marker vertices are collected into `r.verts` when `want_verts`.
    fn shapePath(r: *Self, c: *const Ctx, idx: u32, want_verts: bool) Error!?*const Path {
        const n = &r.doc.nodes[idx];
        const a = r.a;
        if (want_verts) r.verts.clearRetainingCapacity();
        const vp: ?*std.ArrayList(pathdata.Vertex) = if (want_verts) &r.verts else null;
        switch (n.tag) {
            .path, .polyline, .polygon => {
                if (!want_verts) if (r.cache[idx]) |p| return p;
                const p = try a.create(Path);
                p.* = .{};
                if (n.tag == .path) {
                    try pathdata.parse(a, n.attr("d") orelse "", p, vp);
                } else {
                    try pathdata.polyline(a, p, n.attr("points") orelse "", n.tag == .polygon, vp);
                }
                if (p.isEmpty()) return null;
                r.cache[idx] = p;
                return p;
            },
            else => {},
        }
        const p = try a.create(Path);
        p.* = .{};
        switch (n.tag) {
            .rect => {
                const w = r.len(c, n.attr("width"), .x, 0);
                const h = r.len(c, n.attr("height"), .y, 0);
                if (!(w > 0 and h > 0)) return null;
                var rx = if (n.attr("rx")) |s| r.lenOpt(c, s, .x) else null;
                var ry = if (n.attr("ry")) |s| r.lenOpt(c, s, .y) else null;
                if (rx != null and !(rx.? >= 0)) rx = null;
                if (ry != null and !(ry.? >= 0)) ry = null;
                const rxv = rx orelse ry orelse 0;
                const ryv = ry orelse rx orelse 0;
                try pathdata.rect(a, p, r.len(c, n.attr("x"), .x, 0), r.len(c, n.attr("y"), .y, 0), w, h, rxv, ryv);
            },
            .circle => {
                const rad = r.len(c, n.attr("r"), .other, 0);
                if (!(rad > 0)) return null;
                try pathdata.ellipse(a, p, r.len(c, n.attr("cx"), .x, 0), r.len(c, n.attr("cy"), .y, 0), rad, rad);
            },
            .ellipse => {
                var rx = if (n.attr("rx")) |s| r.lenOpt(c, s, .x) else null;
                var ry = if (n.attr("ry")) |s| r.lenOpt(c, s, .y) else null;
                if (rx == null) rx = ry;
                if (ry == null) ry = rx;
                if (rx == null or !(rx.? > 0) or !(ry.? > 0)) return null;
                try pathdata.ellipse(a, p, r.len(c, n.attr("cx"), .x, 0), r.len(c, n.attr("cy"), .y, 0), rx.?, ry.?);
            },
            .line => {
                const x1 = r.len(c, n.attr("x1"), .x, 0);
                const y1 = r.len(c, n.attr("y1"), .y, 0);
                const x2 = r.len(c, n.attr("x2"), .x, 0);
                const y2 = r.len(c, n.attr("y2"), .y, 0);
                try p.moveTo(a, x1, y1);
                try p.lineTo(a, x2, y2);
                if (vp) |v| try pathdata.lineVerts(a, v, x1, y1, x2, y2);
            },
            else => return null,
        }
        return p;
    }

    /// Geometry bounding box (no stroke) of an element in the coordinate system `t`.
    fn bbox(r: *Self, c: *const Ctx, idx: u32, t: Affine, depth: u32) Error!?Rect {
        const n = &r.doc.nodes[idx];
        if (depth > 32) return null;
        if (n.decl(.display)) |d| if (std.mem.eql(u8, num.trim(d), "none")) return null;
        if (n.tag.isShape()) {
            const p = try r.shapePath(c, idx, false) orelse return null;
            if (t.isTranslateOnly()) {
                const b = pathdata.tightBounds(p) orelse return null;
                return .{ .x = b.x + t.e, .y = b.y + t.f, .w = b.w, .h = b.h };
            }
            // tight bounds of the transformed path
            var tp: Path = .{};
            try tp.addPath(r.a, p, t);
            return pathdata.tightBounds(&tp);
        }
        var acc: ?Rect = null;
        switch (n.tag) {
            .g, .a, .svg, .@"switch", .symbol => {
                var ch = n.first_child;
                while (ch != NONE) : (ch = r.doc.nodes[ch].next_sibling) {
                    const cn = &r.doc.nodes[ch];
                    if (!isGraphic(cn.tag)) continue;
                    var ct = t;
                    if (cn.decl(.transform)) |ts| if (num.parseTransform(ts)) |m| {
                        ct = t.mul(m);
                    };
                    acc = unite(acc, try r.bbox(c, ch, ct, depth + 1));
                }
            },
            .use => {
                const target = r.doc.byRef(n.attr("href") orelse return null) orelse return null;
                if (!r.push(target)) return null;
                defer r.pop();
                var ct = t.mul(Affine.translate(r.len(c, n.attr("x"), .x, 0), r.len(c, n.attr("y"), .y, 0)));
                if (r.doc.nodes[target].decl(.transform)) |ts| if (num.parseTransform(ts)) |m| {
                    ct = ct.mul(m);
                };
                acc = try r.bbox(c, target, ct, depth + 1);
            },
            .image => {
                const x = r.len(c, n.attr("x"), .x, 0);
                const y = r.len(c, n.attr("y"), .y, 0);
                const w = r.len(c, n.attr("width"), .x, 0);
                const h = r.len(c, n.attr("height"), .y, 0);
                if (w > 0 and h > 0) acc = num.transformRect(t, .{ .x = x, .y = y, .w = w, .h = h });
            },
            else => {},
        }
        return acc;
    }

    fn unite(a: ?Rect, b: ?Rect) ?Rect {
        const x = a orelse return b;
        const y = b orelse return a;
        const x0 = @min(x.x, y.x);
        const y0 = @min(x.y, y.y);
        return .{ .x = x0, .y = y0, .w = @max(x.x + x.w, y.x + y.w) - x0, .h = @max(x.y + x.h, y.y + y.h) - y0 };
    }

    /// Conservative device-space bounds of what an element paints (null = unknown/unbounded).
    fn inkRegion(r: *Self, c: *const Ctx, idx: u32) Error!?IRect {
        const n = &r.doc.nodes[idx];
        if (r.hasUnboundedInk(idx, 0)) return null;
        const b = try r.bbox(c, idx, Affine.identity, 0) orelse return IRect.empty;
        // stroke slop: widest stroke in the subtree is unknown cheaply; use the inherited width
        // with a generous factor plus explicit widths found in the subtree
        var sw = num.resolve(c.st.stroke_width, c.diag(), c.st.font_size);
        sw = @max(sw, r.maxStrokeWidth(c, idx, 0));
        const pad = sw * @max(c.st.miter_limit, 2) * 0.5 + 1;
        _ = n;
        const dev = num.transformRect(c.ctm, .{ .x = b.x - pad, .y = b.y - pad, .w = b.w + 2 * pad, .h = b.h + 2 * pad });
        return num.roundOut(dev).expand(2);
    }

    fn maxStrokeWidth(r: *Self, c: *const Ctx, idx: u32, depth: u32) f32 {
        if (depth > 16) return 0;
        const n = &r.doc.nodes[idx];
        var m: f32 = 0;
        if (n.decl(.stroke_width)) |s| if (num.parseLength(s)) |l| {
            m = num.resolve(l, c.diag(), c.st.font_size);
        };
        var ch = n.first_child;
        var k: u32 = 0;
        while (ch != NONE and k < 4096) : ({
            ch = r.doc.nodes[ch].next_sibling;
            k += 1;
        }) m = @max(m, r.maxStrokeWidth(c, ch, depth + 1));
        return m;
    }

    /// Markers, filters, text and use of such content can paint outside the geometry bbox.
    fn hasUnboundedInk(r: *Self, idx: u32, depth: u32) bool {
        if (depth > 16) return true;
        const n = &r.doc.nodes[idx];
        if (n.tag == .text) return true;
        for (n.decls) |d| switch (d.prop) {
            .filter, .marker_start, .marker_mid, .marker_end => return true,
            else => {},
        };
        if (n.tag == .use) {
            const t = r.doc.byRef(n.attr("href") orelse return false) orelse return false;
            if (!r.push(t)) return true;
            defer r.pop();
            return r.hasUnboundedInk(t, depth + 1);
        }
        var ch = n.first_child;
        while (ch != NONE) : (ch = r.doc.nodes[ch].next_sibling) {
            if (r.hasUnboundedInk(ch, depth + 1)) return true;
        }
        return false;
    }

    // ---- clipping helpers -------------------------------------------------------------------

    /// Current clip ∩ (user rect under `t`). Returns null when nothing remains visible.
    fn clipToRect(r: *Self, c: *const Ctx, t: Affine, rect: Rect) Error!?ClipMask {
        const reg = c.region();
        if (reg.isEmpty()) return null;
        const axis_aligned = t.b == 0 and t.c == 0;
        if (axis_aligned) {
            const dr = num.transformRect(t, rect);
            const ir = num.roundOut(dr);
            const exact = @abs(dr.x - num.rnd(dr.x)) < 1e-3 and @abs(dr.y - num.rnd(dr.y)) < 1e-3 and
                @abs(dr.x + dr.w - num.rnd(dr.x + dr.w)) < 1e-3 and @abs(dr.y + dr.h - num.rnd(dr.y + dr.h)) < 1e-3;
            const inter = reg.intersect(ir);
            if (inter.isEmpty()) return null;
            if (exact) {
                if (c.clip) |cl| if (cl.data != null) {
                    return try r.intersectClip(cl, .{ .bounds = inter });
                };
                return .{ .bounds = inter };
            }
            if (!r.reserve(@as(usize, inter.w) * inter.h)) return null;
            const m = try raster.maskFromRect(r.a, dr, reg);
            return try r.combine(c, m);
        }
        var p: Path = .{};
        try p.addRect(r.a, rect);
        const b = num.roundOut(num.transformRect(t, rect)).intersect(reg);
        if (b.isEmpty() or !r.reserve(@as(usize, b.w) * b.h)) return null;
        const m = try r.rast.rasterize(r.a, &p, t, .nonzero, reg);
        return try r.combine(c, m);
    }

    /// Current clip ∩ mask (mask bounds are already within the clip region).
    fn combine(r: *Self, c: *const Ctx, m: raster.Mask) Error!?ClipMask {
        if (m.bounds.isEmpty()) return null;
        const mc = m.asClip();
        if (c.clip) |cl| {
            if (cl.data != null) return try r.intersectClip(cl, mc);
            const b = cl.bounds.intersect(mc.bounds);
            if (b.isEmpty()) return null;
            if (b.x == mc.bounds.x and b.y == mc.bounds.y and b.w == mc.bounds.w and b.h == mc.bounds.h) return mc;
            return try r.intersectClip(cl, mc);
        }
        return mc;
    }

    fn intersectClip(r: *Self, a: ClipMask, b: ClipMask) Error!?ClipMask {
        const reg = a.bounds.intersect(b.bounds);
        if (reg.isEmpty()) return null;
        if (!r.reserve(@as(usize, reg.w) * reg.h)) return null;
        const res = try raster.clipIntersect(r.a, a, b);
        if (res.bounds.isEmpty()) return null;
        return res;
    }

    /// Surface budget (bytes); false when exhausted.
    fn reserve(r: *Self, bytes: usize) bool {
        if (r.surface_bytes +| bytes > r.surface_limit) return false;
        r.surface_bytes += bytes;
        return true;
    }

    // ---- effects (opacity / clip-path / mask / filter) --------------------------------------

    noinline fn renderEffects(r: *Self, c: *Ctx, idx: u32, op: f32, bm: filter.BlendMode, isolate: bool, clip_ref: ?[]const u8, mask_ref: ?[]const u8, filter_ref: ?[]const u8) Error!void {
        const need_bbox = clip_ref != null or mask_ref != null or filter_ref != null;
        const bb: ?Rect = if (need_bbox) try r.bbox(c, idx, Affine.identity, 0) else null;

        // filter region (device)
        var fidx: ?u32 = null;
        var region = c.region();
        if (F.filters) if (filter_ref) |fr| {
            if (r.doc.byRef(fr)) |f| {
                if (r.doc.nodes[f].tag == .filter) {
                    if (r.filterRegion(c, f, bb)) |fregion| {
                        fidx = f;
                        region = fregion.intersect(c.dst.bounds());
                    } else return; // empty filter region: element not rendered
                }
            } else return; // reference to a missing filter: element not rendered (Chrome)
        };
        if (region.isEmpty()) return;

        // clip-path
        var clip = c.clip;
        if (F.clip_paths) if (clip_ref) |cr| {
            if (r.doc.byRef(cr)) |cp| {
                if (r.doc.nodes[cp].tag == .clipPath) {
                    clip = try r.clipPathMask(c, cp, bb, 0) orelse return;
                }
            }
        };
        if (fidx == null and mask_ref == null and op >= 1 and bm == .normal and !isolate) {
            var cc = c.*;
            cc.clip = clip;
            return r.renderContent(&cc, idx);
        }

        // layer bounds
        if (fidx == null) {
            if (try r.inkRegion(c, idx)) |ink| region = region.intersect(ink);
            if (clip) |cl| region = region.intersect(cl.bounds);
        }
        if (region.isEmpty()) return;
        const bytes = @as(usize, region.w) * region.h * 4;
        if (!r.reserve(bytes)) {
            // out of surface budget: draw without the layer
            var cc = c.*;
            cc.clip = clip;
            return r.renderContent(&cc, idx);
        }
        var layer = try Pixmap.init(r.a, region.w, region.h);
        const off = Affine.translate(-@as(f32, @floatFromInt(region.x)), -@as(f32, @floatFromInt(region.y)));
        {
            var cc = c.*;
            cc.dst = &layer;
            cc.ctm = off.mul(c.ctm);
            // filters see unclipped content; otherwise clip while drawing
            cc.clip = if (fidx == null) shiftClip(clip, region) else null;
            try r.renderContent(&cc, idx);
        }
        var result = layer;
        if (F.filters) if (fidx) |f| {
            if (r.reserve(bytes * 4)) {
                const fres = try filter.run(.{
                    .a = r.a,
                    .doc = r.doc,
                    .filter = f,
                    .src = &layer,
                    .ctm = off.mul(c.ctm),
                    .bbox = bb,
                    .st = r.resourceStyle(f),
                    .vw = c.vw,
                    .vh = c.vh,
                });
                if (fres) |fr| result = fr;
            }
        };
        // mask
        var comp_clip = if (fidx != null) clip else null;
        if (F.masks) if (mask_ref) |mr| {
            if (r.doc.byRef(mr)) |m| {
                if (r.doc.nodes[m].tag == .mask) {
                    var mc = c.*;
                    mc.clip = clip;
                    comp_clip = try r.maskClip(&mc, m, bb, region) orelse return;
                }
            }
        };
        const cp: ?*const ClipMask = if (comp_clip) |*cl| cl else null;
        if (F.filters and bm != .normal) {
            filter.blendOnto(c.dst, &result, region.x, region.y, bm, op, cp);
            return;
        }
        raster.drawPixmap(c.dst, &result, Affine.translate(@floatFromInt(region.x), @floatFromInt(region.y)), op, .nearest, cp);
    }

    fn shiftClip(clip: ?ClipMask, region: IRect) ?ClipMask {
        var cl = clip orelse return .{ .bounds = .{ .x = 0, .y = 0, .w = region.w, .h = region.h } };
        cl.bounds.x -%= region.x;
        cl.bounds.y -%= region.y;
        return cl;
    }

    fn unitsBBox(n: *const Node, name: []const u8, default_bbox: bool) bool {
        const u = num.trim(n.attr(name) orelse return default_bbox);
        if (std.mem.eql(u8, u, "userSpaceOnUse")) return false;
        if (std.mem.eql(u8, u, "objectBoundingBox")) return true;
        return default_bbox;
    }

    /// x/y/w/h of a filter / mask region in user space.
    fn resourceRect(r: *Self, c: *const Ctx, n: *const Node, bbox_units: bool, bb: ?Rect) ?Rect {
        if (bbox_units) {
            const b = bb orelse return null;
            if (!(b.w > 0 and b.h > 0)) return null;
            const fx = num.parseFraction(n.attr("x") orelse "-10%") orelse -0.1;
            const fy = num.parseFraction(n.attr("y") orelse "-10%") orelse -0.1;
            const fw = num.parseFraction(n.attr("width") orelse "120%") orelse 1.2;
            const fh = num.parseFraction(n.attr("height") orelse "120%") orelse 1.2;
            return .{ .x = b.x + fx * b.w, .y = b.y + fy * b.h, .w = fw * b.w, .h = fh * b.h };
        }
        return .{
            .x = r.len(c, n.attr("x"), .x, -0.1 * c.vw),
            .y = r.len(c, n.attr("y"), .y, -0.1 * c.vh),
            .w = r.len(c, n.attr("width"), .x, 1.2 * c.vw),
            .h = r.len(c, n.attr("height"), .y, 1.2 * c.vh),
        };
    }

    fn filterRegion(r: *Self, c: *const Ctx, f: u32, bb: ?Rect) ?IRect {
        const n = &r.doc.nodes[f];
        const rect = r.resourceRect(c, n, unitsBBox(n, "filterUnits", true), bb) orelse return null;
        if (!(rect.w > 0 and rect.h > 0)) return null;
        const ir = num.roundOut(num.transformRect(c.ctm, rect));
        if (ir.isEmpty()) return null;
        return ir;
    }

    /// Inherited style at a resource element (properties inherit from its own ancestors).
    fn resourceStyle(r: *Self, idx: u32) Style {
        var chain: [dom.MAX_DEPTH + 1]u32 = undefined;
        var n: usize = 0;
        var p = idx;
        while (p != NONE and n < chain.len) : (p = r.doc.nodes[p].parent) {
            chain[n] = p;
            n += 1;
        }
        var st: Style = .{ .color = r.opts.current_color };
        while (n > 0) {
            n -= 1;
            st.apply(&r.doc.nodes[chain[n]]);
        }
        return st;
    }

    /// Coverage of a `<clipPath>` ∩ current clip. Null = everything clipped.
    noinline fn clipPathMask(r: *Self, c: *const Ctx, cp: u32, bb: ?Rect, depth: u32) Error!?ClipMask {
        const n = &r.doc.nodes[cp];
        if (depth > 8 or !r.push(cp)) return null;
        defer r.pop();
        var t = c.ctm;
        if (n.decl(.transform)) |ts| if (num.parseTransform(ts)) |m| {
            t = t.mul(m);
        };
        if (unitsBBox(n, "clipPathUnits", false)) {
            const b = bb orelse return null;
            if (!(b.w > 0 and b.h > 0)) return null;
            t = t.mul(.{ .a = b.w, .d = b.h, .e = b.x, .f = b.y });
        }
        const reg = c.region();
        if (reg.isEmpty() or !r.reserve(@as(usize, reg.w) * reg.h)) return null;
        var acc = try raster.Mask.init(r.a, reg);
        const base_st = r.resourceStyle(cp);
        var ch = n.first_child;
        while (ch != NONE) : (ch = r.doc.nodes[ch].next_sibling) {
            try r.clipChild(c, &acc, ch, t, base_st, reg, 0);
        }
        var res: ClipMask = acc.asClip();
        // clip-path on the clipPath element itself
        if (refOf(n.decl(.clip_path))) |ref| {
            if (r.doc.byRef(ref)) |inner| if (r.doc.nodes[inner].tag == .clipPath) {
                const ic = try r.clipPathMask(c, inner, bb, depth + 1) orelse return null;
                res = try r.intersectClip(res, ic) orelse return null;
            };
        }
        if (c.clip) |cl| if (cl.data != null) {
            res = try r.intersectClip(res, cl) orelse return null;
        };
        return res;
    }

    fn clipChild(r: *Self, c: *const Ctx, acc: *raster.Mask, idx: u32, t_in: Affine, st_in: Style, reg: IRect, depth: u32) Error!void {
        const n = &r.doc.nodes[idx];
        if (depth > 4) return;
        if (n.decl(.display)) |d| if (std.mem.eql(u8, num.trim(d), "none")) return;
        var st = st_in;
        st.apply(n);
        if (!st.visible) return;
        var t = t_in;
        if (n.decl(.transform)) |ts| if (num.parseTransform(ts)) |m| {
            t = t.mul(m);
        };
        if (n.tag == .use) {
            const target = r.doc.byRef(n.attr("href") orelse return) orelse return;
            if (!r.push(target)) return;
            defer r.pop();
            t = t.mul(Affine.translate(r.len(c, n.attr("x"), .x, 0), r.len(c, n.attr("y"), .y, 0)));
            const tn = &r.doc.nodes[target];
            if (!tn.tag.isShape() and tn.tag != .text) return;
            return r.clipChild(c, acc, target, t, st, reg, depth + 1);
        }
        if (n.tag == .text) return;
        if (!n.tag.isShape()) return;
        const p = try r.shapePath(c, idx, false) orelse return;
        r.painted += p.verbs.items.len;
        var m = try r.rast.rasterize(r.a, p, t, st.clip_rule, reg);
        defer m.deinit(r.a);
        if (m.bounds.isEmpty()) return;
        // max-combine into acc
        var y: u32 = 0;
        while (y < m.bounds.h) : (y += 1) {
            const src = m.data[@as(usize, y) * m.bounds.w ..][0..m.bounds.w];
            const ay: usize = @intCast(@as(i64, m.bounds.y) + y - acc.bounds.y);
            const ax: usize = @intCast(@as(i64, m.bounds.x) - acc.bounds.x);
            const dst = acc.data[ay * acc.bounds.w + ax ..][0..m.bounds.w];
            for (dst, src) |*d, s| d.* = @max(d.*, s);
        }
    }

    /// Mask coverage (luminance or alpha) ∩ current clip, over `region`.
    noinline fn maskClip(r: *Self, c: *const Ctx, m: u32, bb: ?Rect, region_in: IRect) Error!?ClipMask {
        const n = &r.doc.nodes[m];
        if (!r.push(m)) return null;
        defer r.pop();
        const rect = r.resourceRect(c, n, unitsBBox(n, "maskUnits", true), bb) orelse return null;
        const region = region_in.intersect(c.region());
        if (region.isEmpty()) return null;
        if (!r.reserve(@as(usize, region.w) * region.h * 5)) return null;
        var pm = try Pixmap.init(r.a, region.w, region.h);
        const off = Affine.translate(-@as(f32, @floatFromInt(region.x)), -@as(f32, @floatFromInt(region.y)));
        var mc: Ctx = .{
            .dst = &pm,
            .clip = .{ .bounds = .{ .x = 0, .y = 0, .w = region.w, .h = region.h } },
            .ctm = off.mul(c.ctm),
            .vw = c.vw,
            .vh = c.vh,
            .st = r.resourceStyle(m),
        };
        mc.clip = try r.clipToRect(&mc, mc.ctm, rect) orelse return null;
        if (unitsBBox(n, "maskContentUnits", false)) {
            const b = bb orelse return null;
            mc.ctm = mc.ctm.mul(.{ .a = b.w, .d = b.h, .e = b.x, .f = b.y });
        }
        try r.renderChildren(&mc, m);
        const alpha_mode = if (n.decl(.mask_type)) |mt| std.mem.eql(u8, num.trim(mt), "alpha") else false;
        const mask = try raster.Mask.init(r.a, region);
        const px = pm.data;
        for (mask.data, 0..) |*d, i| {
            const p = px[i * 4 ..][0..4];
            if (alpha_mode) {
                d.* = p[3];
            } else {
                // luminance of premultiplied colour = luminance(straight) * alpha
                const l = 0.2125 * @as(f32, @floatFromInt(p[0])) + 0.7154 * @as(f32, @floatFromInt(p[1])) + 0.0721 * @as(f32, @floatFromInt(p[2]));
                d.* = @intFromFloat(@min(255, l + 0.5));
            }
        }
        var cc = c.*;
        const res = try r.combine(&cc, mask) orelse return null;
        return res;
    }

    // ---- painting ---------------------------------------------------------------------------

    noinline fn drawShape(r: *Self, c: *const Ctx, idx: u32) Error!void {
        const st = &c.st;
        const has_markers = F.markers and (r.doc.nodes[idx].tag == .path or r.doc.nodes[idx].tag == .line or
            r.doc.nodes[idx].tag == .polyline or r.doc.nodes[idx].tag == .polygon) and
            (st.marker_start.len + st.marker_mid.len + st.marker_end.len > 0);
        const p = try r.shapePath(c, idx, has_markers) orelse return;
        r.painted += p.verbs.items.len;
        if (!st.visible) return;
        const verts: []const pathdata.Vertex = if (has_markers) try r.a.dupe(pathdata.Vertex, r.verts.items) else &.{};
        var order = st.paint_order;
        var k: u32 = 0;
        while (k < 3) : (k += 1) {
            switch (order & 3) {
                0 => try r.fillShape(c, idx, p),
                1 => try r.strokeShape(c, idx, p),
                else => if (has_markers) try r.drawMarkers(c, verts),
            }
            order >>= 2;
        }
    }

    fn fillShape(r: *Self, c: *const Ctx, idx: u32, p: *const Path) Error!void {
        const st = &c.st;
        if (st.fill.kind == .none) return;
        var paint: raster.Paint = undefined;
        if (!try r.makePaint(c, idx, st.fill, st.fill_opacity * c.alpha, p, &paint)) return;
        if (!r.spendArea(c, p, c.ctm)) return;
        try r.rast.fillPath(c.dst, p, c.ctm, st.fill_rule, &paint, c.clipPtr());
    }

    fn strokeShape(r: *Self, c: *const Ctx, idx: u32, p: *const Path) Error!void {
        const st = &c.st;
        if (st.stroke.kind == .none) return;
        const w = num.resolve(st.stroke_width, c.diag(), st.font_size);
        if (!(w > 0)) return;
        var paint: raster.Paint = undefined;
        if (!try r.makePaint(c, idx, st.stroke, st.stroke_opacity * c.alpha, p, &paint)) return;
        var dashes: [32]f32 = undefined;
        var nd: usize = 0;
        if (st.dasharray.len > 0 and !std.mem.eql(u8, st.dasharray, "none")) {
            var rd: num.Reader = .{ .s = st.dasharray };
            while (nd < dashes.len) {
                rd.skipWs();
                if (rd.i >= rd.s.len) break;
                const st_i = rd.i;
                _ = rd.number() orelse break;
                // dash entries may carry units / percentages
                const tok_end = blk: {
                    var e = rd.i;
                    while (e < rd.s.len and !num.isWs(rd.s[e]) and rd.s[e] != ',') e += 1;
                    break :blk e;
                };
                const l = num.parseLength(rd.s[st_i..tok_end]) orelse break;
                dashes[nd] = num.resolve(l, c.diag(), st.font_size);
                nd += 1;
                rd.i = tok_end;
                rd.skipSep();
            }
        }
        const scale = num.maxScale(c.ctm);
        const non_scaling = if (r.doc.nodes[idx].decl(.vector_effect)) |v| std.mem.eql(u8, num.trim(v), "non-scaling-stroke") else false;
        r.outline.reset();
        if (non_scaling) {
            r.tmp2.reset();
            try r.tmp2.addPath(r.a, p, c.ctm);
            try r.stroker.stroke(r.a, &r.tmp2, .{
                .width = w,
                .cap = st.cap,
                .join = st.join,
                .miter_limit = st.miter_limit,
                .dashes = dashes[0..nd],
                .dash_offset = num.resolve(st.dashoffset, c.diag(), st.font_size),
                .tolerance = 0.1,
            }, &r.outline);
            try r.rast.fillPath(c.dst, &r.outline, Affine.identity, .nonzero, &paint, c.clipPtr());
            return;
        }
        try r.stroker.stroke(r.a, p, .{
            .width = w,
            .cap = st.cap,
            .join = st.join,
            .miter_limit = st.miter_limit,
            .dashes = dashes[0..nd],
            .dash_offset = num.resolve(st.dashoffset, c.diag(), st.font_size),
            .tolerance = 0.1 / @max(scale, 1e-6),
        }, &r.outline);
        if (!r.spendArea(c, &r.outline, c.ctm)) return;
        try r.rast.fillPath(c.dst, &r.outline, c.ctm, .nonzero, &paint, c.clipPtr());
    }

    /// Charges the device area a fill may touch; false once the render budget is spent.
    fn spendArea(r: *Self, c: *const Ctx, p: *const Path, t: Affine) bool {
        const b = num.roundOut(num.transformRect(t, p.bounds())).intersect(c.region());
        r.area += @as(u64, b.w) * b.h;
        return r.area <= r.area_limit;
    }

    /// Resolves a paint into `out`. False = paint nothing.
    fn makePaint(r: *Self, c: *const Ctx, idx: u32, sp: style.SPaint, opacity: f32, p: *const Path, out: *raster.Paint) Error!bool {
        _ = idx;
        var kind = sp.kind;
        var col = sp.color;
        if (kind == .server) {
            if (r.doc.byRef(sp.ref)) |srv| {
                const bb = pathdata.tightBounds(p);
                switch (r.doc.nodes[srv].tag) {
                    .linearGradient, .radialGradient => return r.gradientPaint(c, srv, bb, opacity, out),
                    .pattern => if (F.patterns) return r.patternPaint(c, srv, bb, opacity, out),
                    else => {},
                }
            }
            kind = sp.fallback;
        }
        switch (kind) {
            .none, .server => return false,
            .current => col = c.st.color,
            .color => {},
        }
        col.a = @intFromFloat(@as(f32, @floatFromInt(col.a)) * std.math.clamp(opacity, 0, 1) + 0.5);
        if (col.a == 0) return false;
        out.* = .{ .solid = col };
        return true;
    }

    /// Attribute through the gradient / pattern `href` chain.
    fn chainAttr(r: *Self, idx: u32, name: []const u8) ?[]const u8 {
        var cur = idx;
        var k: u32 = 0;
        while (k < 16) : (k += 1) {
            const n = &r.doc.nodes[cur];
            if (n.attr(name)) |v| return v;
            const next = r.doc.byRef(n.attr("href") orelse return null) orelse return null;
            const t = r.doc.nodes[next].tag;
            if (t != .linearGradient and t != .radialGradient and t != .pattern) return null;
            cur = next;
        }
        return null;
    }

    fn chainChildren(r: *Self, idx: u32, want: dom.Tag) ?u32 {
        var cur = idx;
        var k: u32 = 0;
        while (k < 16) : (k += 1) {
            const n = &r.doc.nodes[cur];
            var ch = n.first_child;
            while (ch != NONE) : (ch = r.doc.nodes[ch].next_sibling) {
                if (want == .unknown or r.doc.nodes[ch].tag == want) return cur;
            }
            const next = r.doc.byRef(n.attr("href") orelse return null) orelse return null;
            cur = next;
        }
        return null;
    }

    fn gradientPaint(r: *Self, c: *const Ctx, g: u32, bb: ?Rect, opacity: f32, out: *raster.Paint) Error!bool {
        const gn = &r.doc.nodes[g];
        const stop_owner = r.chainChildren(g, .stop) orelse return false;
        var stops: std.ArrayList(raster.GradientStop) = .empty;
        var last_off: f32 = 0;
        var ch = r.doc.nodes[stop_owner].first_child;
        var cnt: u32 = 0;
        while (ch != NONE and cnt < 256) : (ch = r.doc.nodes[ch].next_sibling) {
            const s = &r.doc.nodes[ch];
            if (s.tag != .stop) continue;
            cnt += 1;
            var off = std.math.clamp(num.parseFraction(s.attr("offset") orelse "0") orelse 0, 0, 1);
            off = @max(off, last_off);
            last_off = off;
            var col = Color.black;
            if (s.decl(.stop_color)) |v| {
                if (num.eqlIgnoreCase(num.trim(v), "currentColor")) {
                    col = if (s.decl(.color)) |cv| color.parse(cv) orelse c.st.color else c.st.color;
                } else if (color.parse(v)) |x| col = x;
            }
            var a = @as(f32, @floatFromInt(col.a)) * opacity;
            if (s.decl(.stop_opacity)) |v| a *= style.opacity(v) orelse 1;
            col.a = @intFromFloat(std.math.clamp(a, 0, 255) + 0.5);
            try stops.append(r.a, .{ .offset = off, .color = col });
        }
        if (stops.items.len == 0) return false;
        if (stops.items.len > 1) stops.items = try unpremulStops(r.a, stops.items);
        if (stops.items.len == 1) {
            if (stops.items[0].color.a == 0) return false;
            out.* = .{ .solid = stops.items[0].color };
            return true;
        }
        const bbox_units = unitsBBox(&r.doc.nodes[r.chainOwner(g, "gradientUnits")], "gradientUnits", true);
        var m = c.ctm;
        if (bbox_units) {
            const b = bb orelse return false;
            if (!(b.w > 0 and b.h > 0)) return false;
            m = m.mul(.{ .a = b.w, .d = b.h, .e = b.x, .f = b.y });
        }
        if (r.chainAttr(g, "gradientTransform")) |ts| if (num.parseTransform(ts)) |t| {
            m = m.mul(t);
        };
        const inv = m.invert() orelse return false;
        const spread = num.trim(r.chainAttr(g, "spreadMethod") orelse "pad");
        const reflect = std.mem.eql(u8, spread, "reflect");
        const repeat = reflect or std.mem.eql(u8, spread, "repeat");
        var sl = stops.items;
        if (repeat) sl = try normalizeStops(r.a, sl, reflect);
        // percentages: bbox units -> fraction, user space -> viewport
        const L = struct {
            fn get(rr: *Self, cc: *const Ctx, gi: u32, name: []const u8, def: []const u8, axis: num.Axis, bbu: bool) f32 {
                const s = rr.chainAttr(gi, name) orelse def;
                if (bbu) return num.parseFraction(s) orelse (num.parseFraction(def) orelse 0);
                return rr.lenOpt(cc, s, axis) orelse (rr.lenOpt(cc, def, axis) orelse 0);
            }
        };
        if (gn.tag == .linearGradient) {
            const x1 = L.get(r, c, g, "x1", "0%", .x, bbox_units);
            const y1 = L.get(r, c, g, "y1", "0%", .y, bbox_units);
            var x2 = L.get(r, c, g, "x2", "100%", .x, bbox_units);
            var y2 = L.get(r, c, g, "y2", "0%", .y, bbox_units);
            if (reflect) {
                x2 = x1 + 2 * (x2 - x1);
                y2 = y1 + 2 * (y2 - y1);
            }
            const dx = x2 - x1;
            const dy = y2 - y1;
            const dd = dx * dx + dy * dy;
            if (!(dd > 0)) {
                // zero-length vector: last stop colour
                out.* = .{ .solid = stops.items[stops.items.len - 1].color };
                return true;
            }
            // t(p) = gx*x + gy*y + g0 in device space
            const gx = (dx * inv.a + dy * inv.b) / dd;
            const gy = (dx * inv.c + dy * inv.d) / dd;
            const g0 = (dx * (inv.e - x1) + dy * (inv.f - y1)) / dd;
            const gg = gx * gx + gy * gy;
            if (!(gg > 0) or !num.finite(gg)) return false;
            const p0: raster.Point = .{ .x = -g0 * gx / gg, .y = -g0 * gy / gg };
            out.* = .{ .linear = .{
                .p0 = p0,
                .p1 = .{ .x = p0.x + gx / gg, .y = p0.y + gy / gg },
                .stops = sl,
                .repeating = repeat,
            } };
            return true;
        }
        const cx = L.get(r, c, g, "cx", "50%", .x, bbox_units);
        const cy = L.get(r, c, g, "cy", "50%", .y, bbox_units);
        var rad = L.get(r, c, g, "r", "50%", .other, bbox_units);
        if (!(rad > 0)) {
            out.* = .{ .solid = stops.items[stops.items.len - 1].color };
            return true;
        }
        if (reflect) rad *= 2;
        // express gradient space in ~device pixels so the raster LUT gets enough resolution
        const k = @max(num.maxScale(m), 1e-6);
        out.* = .{ .radial = .{
            .center = .{ .x = cx * k, .y = cy * k },
            .rx = rad * k,
            .ry = rad * k,
            .stops = sl,
            .repeating = repeat,
            .transform = Affine.scale(k, k).mul(inv),
        } };
        return true;
    }

    fn chainOwner(r: *Self, idx: u32, name: []const u8) u32 {
        var cur = idx;
        var k: u32 = 0;
        while (k < 16) : (k += 1) {
            const n = &r.doc.nodes[cur];
            if (n.attr(name) != null) return cur;
            const next = r.doc.byRef(n.attr("href") orelse return idx) orelse return idx;
            cur = next;
        }
        return idx;
    }

    /// Stops over exactly [0, 1] (for repeat), mirrored into [0, 0.5] + [0.5, 1] for reflect.
    fn normalizeStops(a: Allocator, s: []const raster.GradientStop, reflect: bool) Error![]raster.GradientStop {
        var l: std.ArrayList(raster.GradientStop) = .empty;
        if (s[0].offset > 0) try l.append(a, .{ .offset = 0, .color = s[0].color });
        try l.appendSlice(a, s);
        if (s[s.len - 1].offset < 1) try l.append(a, .{ .offset = 1, .color = s[s.len - 1].color });
        if (!reflect) return l.items;
        const n = l.items.len;
        var out = try a.alloc(raster.GradientStop, n * 2);
        for (l.items, 0..) |st, i| {
            out[i] = .{ .offset = st.offset * 0.5, .color = st.color };
            out[2 * n - 1 - i] = .{ .offset = 1 - st.offset * 0.5, .color = st.color };
        }
        return out;
    }

    noinline fn patternPaint(r: *Self, c: *const Ctx, pi: u32, bb: ?Rect, opacity: f32, out: *raster.Paint) Error!bool {
        if (!r.push(pi)) return false;
        defer r.pop();
        const content_owner = r.chainChildren(pi, .unknown) orelse return false;
        const pn = &r.doc.nodes[pi];
        _ = pn;
        const bbox_units = unitsBBox(&r.doc.nodes[r.chainOwner(pi, "patternUnits")], "patternUnits", true);
        const content_bbox = unitsBBox(&r.doc.nodes[r.chainOwner(pi, "patternContentUnits")], "patternContentUnits", false);
        var tile: Rect = undefined;
        if (bbox_units) {
            const b = bb orelse return false;
            const fx = num.parseFraction(r.chainAttr(pi, "x") orelse "0") orelse 0;
            const fy = num.parseFraction(r.chainAttr(pi, "y") orelse "0") orelse 0;
            const fw = num.parseFraction(r.chainAttr(pi, "width") orelse "0") orelse 0;
            const fh = num.parseFraction(r.chainAttr(pi, "height") orelse "0") orelse 0;
            tile = .{ .x = b.x + fx * b.w, .y = b.y + fy * b.h, .w = fw * b.w, .h = fh * b.h };
        } else {
            tile = .{
                .x = r.len(c, r.chainAttr(pi, "x"), .x, 0),
                .y = r.len(c, r.chainAttr(pi, "y"), .y, 0),
                .w = r.len(c, r.chainAttr(pi, "width"), .x, 0),
                .h = r.len(c, r.chainAttr(pi, "height"), .y, 0),
            };
        }
        if (!(tile.w > 0 and tile.h > 0)) return false;
        var pt = Affine.identity;
        if (r.chainAttr(pi, "patternTransform")) |ts| if (num.parseTransform(ts)) |t| {
            pt = t;
        };
        // tile pixel size at the device scale
        const full = c.ctm.mul(pt);
        const sx = num.hypot(full.a, full.b);
        const sy = num.hypot(full.c, full.d);
        const twf = num.rnd(tile.w * sx);
        const thf = num.rnd(tile.h * sy);
        if (!(twf >= 1 and thf >= 1)) return false;
        const area = @as(f32, @floatFromInt(c.dst.width)) * @as(f32, @floatFromInt(c.dst.height));
        if (twf > 8192 or thf > 8192 or twf * thf > @max(area * 4, 1 << 20)) return false;
        const tw: u32 = @intFromFloat(twf);
        const th: u32 = @intFromFloat(thf);
        if (!r.reserve(@as(usize, tw) * th * 4)) return false;
        var pm = try Pixmap.init(r.a, tw, th);
        // content transform: tile space (0,0)-(w,h) -> tile pixels
        // takumi (tiny-skia) quirk, kept for parity: content is drawn at the exact device scale
        // but the tile repeats with its rounded pixel size
        var ct = Affine.scale(sx, sy);
        if (num.parseViewBox(r.chainAttr(pi, "viewBox") orelse "")) |vb| {
            ct = ct.mul(num.viewBoxTransform(vb, num.parseAspectRatio(r.chainAttr(pi, "preserveAspectRatio")), tile.w, tile.h));
        } else if (content_bbox) {
            const b = bb orelse return false;
            ct = ct.mul(.{ .a = b.w, .d = b.h });
        }
        var tc: Ctx = .{
            .dst = &pm,
            .clip = null,
            .ctm = ct,
            .vw = c.vw,
            .vh = c.vh,
            .st = r.resourceStyle(content_owner),
        };
        try r.renderChildren(&tc, content_owner);
        // device -> tile pixel space
        const to_dev = full.mul(Affine.translate(tile.x, tile.y)).mul(Affine.scale(1 / sx, 1 / sy));
        const inv = to_dev.invert() orelse return false;
        const pmp = try r.a.create(Pixmap);
        pmp.* = pm;
        // tiny-skia drops to nearest sampling for translate-only pattern transforms
        const filt: raster.Filter = if (inv.isTranslateOnly()) .nearest else .bilinear;
        out.* = .{ .image = .{ .pixmap = pmp, .transform = inv, .filter = filt, .extend = .repeat, .opacity = std.math.clamp(opacity, 0, 1) } };
        return true;
    }

    // ---- markers ----------------------------------------------------------------------------

    noinline fn drawMarkers(r: *Self, c: *const Ctx, vs: []const pathdata.Vertex) Error!void {
        const st = &c.st;
        if (vs.len == 0) return;
        const sw = num.resolve(st.stroke_width, c.diag(), st.font_size);
        for (vs, 0..) |v, i| {
            const ref = if (i == 0) st.marker_start else if (i == vs.len - 1) st.marker_end else st.marker_mid;
            if (ref.len == 0) continue;
            const m = r.doc.byRef(ref) orelse continue;
            if (r.doc.nodes[m].tag != .marker) continue;
            try r.drawMarker(c, m, v, i == 0, sw);
        }
    }

    fn drawMarker(r: *Self, c: *const Ctx, m: u32, v: pathdata.Vertex, is_start: bool, sw: f32) Error!void {
        if (!r.push(m)) return;
        defer r.pop();
        const n = &r.doc.nodes[m];
        const mw = r.len(c, n.attr("markerWidth"), .x, 3);
        const mh = r.len(c, n.attr("markerHeight"), .y, 3);
        if (!(mw > 0 and mh > 0)) return;
        var angle: f32 = 0;
        const orient = num.trim(n.attr("orient") orelse "0");
        if (std.mem.eql(u8, orient, "auto") or std.mem.eql(u8, orient, "auto-start-reverse")) {
            const a_in: ?f32 = if (v.in) |d| num.atan2(d.y, d.x) else null;
            const a_out: ?f32 = if (v.out) |d| num.atan2(d.y, d.x) else null;
            if (a_in != null and a_out != null) {
                var diff = a_out.? - a_in.?;
                if (diff > std.math.pi) diff -= 2 * std.math.pi;
                if (diff < -std.math.pi) diff += 2 * std.math.pi;
                angle = a_in.? + diff / 2;
            } else angle = a_in orelse a_out orelse 0;
            if (is_start and std.mem.eql(u8, orient, "auto-start-reverse")) angle += std.math.pi;
        } else {
            var rd: num.Reader = .{ .s = orient };
            angle = (rd.number() orelse 0) * std.math.pi / 180;
        }
        var t = c.ctm.mul(Affine.translate(v.x, v.y)).mul(Affine.rotate(angle));
        const units_sw = !std.mem.eql(u8, num.trim(n.attr("markerUnits") orelse "strokeWidth"), "userSpaceOnUse");
        if (units_sw) t = t.mul(Affine.scale(sw, sw));
        var vb_t = Affine.identity;
        var clip_rect: Rect = .{ .x = 0, .y = 0, .w = mw, .h = mh };
        const refx = num.parseNumber(n.attr("refX") orelse "0") orelse 0;
        const refy = num.parseNumber(n.attr("refY") orelse "0") orelse 0;
        if (num.parseViewBox(n.attr("viewBox") orelse "")) |vb| {
            vb_t = num.viewBoxTransform(vb, num.parseAspectRatio(n.attr("preserveAspectRatio")), mw, mh);
            const rp = vb_t.apply(.{ .x = refx, .y = refy });
            t = t.mul(Affine.translate(-rp.x, -rp.y));
            clip_rect = .{ .x = 0, .y = 0, .w = mw, .h = mh };
        } else {
            t = t.mul(Affine.translate(-refx, -refy));
        }
        var mc: Ctx = .{
            .dst = c.dst,
            .clip = c.clip,
            .ctm = t,
            .vw = c.vw,
            .vh = c.vh,
            .st = r.resourceStyle(m),
        };
        const overflow = if (n.decl(.overflow)) |o| num.trim(o) else "hidden";
        if (!std.mem.eql(u8, overflow, "visible") and !std.mem.eql(u8, overflow, "auto")) {
            mc.clip = try r.clipToRect(&mc, t, clip_rect) orelse return;
        }
        mc.ctm = t.mul(vb_t);
        try r.renderChildren(&mc, m);
    }

    // ---- images and text --------------------------------------------------------------------

    noinline fn drawImage(r: *Self, c: *const Ctx, idx: u32) Error!void {
        const n = &r.doc.nodes[idx];
        if (!c.st.visible) return;
        const href = num.trim(n.attr("href") orelse return);
        if (!std.mem.startsWith(u8, href, "data:")) return;
        const comma = std.mem.indexOfScalar(u8, href, ',') orelse return;
        const meta = href[5..comma];
        const payload = href[comma + 1 ..];
        const is_b64 = std.mem.endsWith(u8, meta, ";base64");
        if (r.image_bytes +| payload.len > MAX_IMAGE_BYTES) return;
        r.image_bytes += payload.len;
        const bytes = if (is_b64) base64Decode(r.a, payload) catch return else try percentDecode(r.a, payload);
        const x = r.len(c, n.attr("x"), .x, 0);
        const y = r.len(c, n.attr("y"), .y, 0);
        const par = num.parseAspectRatio(n.attr("preserveAspectRatio"));
        if (std.mem.startsWith(u8, meta, "image/svg") or xml.looksLikeSvg(bytes)) {
            return r.drawNestedSvg(c, n, bytes, x, y);
        }
        const img = codec.decode(r.a, bytes, .{ .max_pixels = @min(16 << 20, r.opts.max_image_pixels) }) catch return;
        var pm: Pixmap = .{ .width = img.width, .height = img.height, .data = img.data };
        premultiply(pm.data);
        const iw: f32 = @floatFromInt(img.width);
        const ih: f32 = @floatFromInt(img.height);
        const w = if (n.attr("width")) |s| r.lenOpt(c, s, .x) orelse iw else iw;
        const h = if (n.attr("height")) |s| r.lenOpt(c, s, .y) orelse ih else ih;
        if (!(w > 0 and h > 0)) return;
        const vt = num.viewBoxTransform(.{ 0, 0, iw, ih }, par, w, h);
        var cc = c.*;
        if (par.slice) cc.clip = try r.clipToRect(c, c.ctm, .{ .x = x, .y = y, .w = w, .h = h }) orelse return;
        var t = c.ctm.mul(Affine.translate(x, y)).mul(vt);
        const pixelated = if (n.decl(.image_rendering)) |v| std.mem.eql(u8, num.trim(v), "pixelated") or std.mem.eql(u8, num.trim(v), "optimizeSpeed") or std.mem.eql(u8, num.trim(v), "crisp-edges") else false;
        // prefilter strong minification; magnification samples bilinearly (takumi uses tiny-skia
        // bicubic, but Catmull-Rom upsampling measured further from it than bilinear)
        const sx = num.hypot(t.a, t.b);
        const sy = num.hypot(t.c, t.d);
        if (!pixelated and (sx < 0.5 or sy < 0.5) and t.b == 0 and t.c == 0) {
            const nw: u32 = @intFromFloat(@max(1, num.rnd(iw * sx)));
            const nh: u32 = @intFromFloat(@max(1, num.rnd(ih * sy)));
            pm = raster.resample(r.a, &pm, nw, nh) catch return;
            t = t.mul(Affine.scale(iw / @as(f32, @floatFromInt(nw)), ih / @as(f32, @floatFromInt(nh))));
        }
        raster.drawPixmap(cc.dst, &pm, t, c.alpha, if (pixelated) .nearest else .bilinear, cc.clipPtr());
    }

    /// Like takumi: the nested document is rendered straight into the image viewport (its own
    /// viewBox / preserveAspectRatio apply; the image element's preserveAspectRatio does not).
    fn drawNestedSvg(r: *Self, c: *const Ctx, n: *const Node, bytes: []const u8, x: f32, y: f32) Error!void {
        if (r.nested_level >= r.opts.max_nested_svg) return;
        const doc = parseDoc(F.stylesheets, r.a, bytes) catch return;
        const isz = intrinsic(doc.root());
        const iw = isz.width orelse if (isz.view_box) |vb| vb[2] else 100;
        const ih = isz.height orelse if (isz.view_box) |vb| vb[3] else 100;
        const w = if (n.attr("width")) |s| r.lenOpt(c, s, .x) orelse iw else iw;
        const h = if (n.attr("height")) |s| r.lenOpt(c, s, .y) orelse ih else ih;
        if (!(w > 0 and h > 0)) return;
        // only axis-aligned placement is supported for nested documents
        const t = c.ctm;
        if (t.b != 0 or t.c != 0) return;
        const dest = num.transformRect(t, .{ .x = x, .y = y, .w = w, .h = h });
        var sub: Self = .{ .a = r.a, .rast = r.rast, .doc = &doc, .opts = r.opts, .nested_level = r.nested_level + 1 };
        sub.opts.current_color = c.st.color;
        sub.area_limit = r.area_limit;
        sub.depth = r.depth;
        sub.instances = r.instances;
        try sub.renderRoot(c.dst, dest, c.clipPtr());
    }

    fn drawText(r: *Self, c: *const Ctx, idx: u32) void {
        const hook = r.opts.text orelse return;
        const n = &r.doc.nodes[idx];
        var buf: std.ArrayList(u8) = .empty;
        r.collectText(idx, &buf, 0) catch return;
        // collapse whitespace
        var out: std.ArrayList(u8) = .empty;
        var ws = true;
        for (buf.items) |ch| {
            if (num.isWs(ch)) {
                if (!ws) out.append(r.a, ' ') catch return;
                ws = true;
            } else {
                out.append(r.a, ch) catch return;
                ws = false;
            }
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        var fill: ?Color = null;
        switch (c.st.fill.kind) {
            .color, .current => {
                var col = if (c.st.fill.kind == .color) c.st.fill.color else c.st.color;
                col.a = @intFromFloat(@as(f32, @floatFromInt(col.a)) * std.math.clamp(c.st.fill_opacity * c.alpha, 0, 1) + 0.5);
                fill = col;
            },
            else => {},
        }
        var rx: num.Reader = .{ .s = n.attr("x") orelse "0" };
        var ry: num.Reader = .{ .s = n.attr("y") orelse "0" };
        const req: TextRequest = .{
            .text = out.items,
            .x = rx.next() orelse 0,
            .y = ry.next() orelse 0,
            .font_size = c.st.font_size,
            .font_family = c.st.font_family,
            .font_weight = c.st.font_weight,
            .text_anchor = c.st.text_anchor,
            .fill = fill,
            .transform = c.ctm,
            .dst = c.dst,
            .clip = c.clipPtr(),
        };
        hook.draw(hook.ctx, &req);
    }

    fn collectText(r: *Self, idx: u32, buf: *std.ArrayList(u8), depth: u32) !void {
        if (depth > 8 or buf.items.len > 1 << 16) return;
        var ch = r.doc.nodes[idx].first_child;
        while (ch != NONE) : (ch = r.doc.nodes[ch].next_sibling) {
            const cn = &r.doc.nodes[ch];
            if (cn.tag == .textnode) try buf.appendSlice(r.a, cn.text);
            if (cn.tag == .tspan or cn.tag == .textPath) try r.collectText(ch, buf, depth + 1);
        }
    }
};
}

fn premultiply(d: []u8) void {
    var i: usize = 0;
    while (i + 4 <= d.len) : (i += 4) {
        const a: u32 = d[i + 3];
        if (a == 255) continue;
        for (0..3) |k| d[i + k] = @intCast(raster.div255(@as(u32, d[i + k]) * a));
    }
}

fn b64val(ch: u8) ?u8 {
    return switch (ch) {
        'A'...'Z' => ch - 'A',
        'a'...'z' => ch - 'a' + 26,
        '0'...'9' => ch - '0' + 52,
        '+', '-' => 62,
        '/', '_' => 63,
        else => null,
    };
}

pub fn base64Decode(a: Allocator, s: []const u8) ![]u8 {
    var out = try a.alloc(u8, s.len / 4 * 3 + 3);
    var acc: u32 = 0;
    var bits: u5 = 0;
    var n: usize = 0;
    for (s) |ch| {
        if (ch == '=') break;
        const v = b64val(ch) orelse {
            if (num.isWs(ch) or ch == '%') continue; // tolerate whitespace (and %0A escapes' '%')
            return error.InvalidData;
        };
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (n < out.len) out[n] = @truncate(acc >> bits);
            n += 1;
        }
    }
    return out[0..@min(n, out.len)];
}

fn percentDecode(a: Allocator, s: []const u8) ![]u8 {
    var out = try a.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                out[n] = hi.? * 16 + lo.?;
                n += 1;
                i += 3;
                continue;
            }
        }
        out[n] = s[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

pub const Intrinsic = struct { width: ?f32, height: ?f32, view_box: ?[4]f32 };

/// Root width / height (absolute lengths only; em = 16px) and viewBox.
pub fn intrinsic(root: *const Node) Intrinsic {
    const vb = num.parseViewBox(root.attr("viewBox") orelse "");
    var w: ?f32 = null;
    var h: ?f32 = null;
    if (root.attr("width")) |s| if (num.parseLength(s)) |l| if (l.unit != .percent) {
        const v = num.resolve(l, 0, 16);
        if (v > 0) w = v;
    };
    if (root.attr("height")) |s| if (num.parseLength(s)) |l| if (l.unit != .percent) {
        const v = num.resolve(l, 0, 16);
        if (v > 0) h = v;
    };
    if (vb) |v| {
        if (w != null and h == null) h = w.? * v[3] / v[2];
        if (h != null and w == null) w = h.? * v[2] / v[3];
    }
    return .{ .width = w, .height = h, .view_box = vb };
}

pub fn parseDoc(comptime stylesheets: bool, arena: Allocator, text: []const u8) Error!dom.Document {
    const res = try xml.parse(arena, text);
    var un = res.unsupported;
    try css.cascade(stylesheets, arena, res.nodes, &un);
    const ids = try dom.buildIds(arena, res.nodes);
    return .{ .nodes = res.nodes, .id_table = ids, .unsupported = un };
}

/// tiny-skia interpolates gradient colours unpremultiplied; the raster LUT interpolates
/// premultiplied. Intervals whose alpha changes get sub-stops so both agree closely.
fn unpremulStops(a: Allocator, s: []raster.GradientStop) Error![]raster.GradientStop {
    var need = false;
    for (s[1..], 0..) |st, i| {
        const p = s[i];
        if (p.color.a != st.color.a and p.color.bits() & 0xFFFFFF != st.color.bits() & 0xFFFFFF and st.offset > p.offset) need = true;
    }
    if (!need) return s;
    const SUB = 16;
    var out: std.ArrayList(raster.GradientStop) = .empty;
    try out.append(a, s[0]);
    for (s[1..], 0..) |st, i| {
        const p = s[i];
        if (p.color.a != st.color.a and st.offset > p.offset) {
            var k: u32 = 1;
            while (k < SUB) : (k += 1) {
                const t = @as(f32, @floatFromInt(k)) / SUB;
                const c0 = [4]u8{ p.color.r, p.color.g, p.color.b, p.color.a };
                const c1 = [4]u8{ st.color.r, st.color.g, st.color.b, st.color.a };
                var col: [4]u8 = undefined;
                for (&col, c0, c1) |*o, x, y| {
                    const xf: f32 = @floatFromInt(x);
                    const yf: f32 = @floatFromInt(y);
                    o.* = @intFromFloat(num.rnd(xf + (yf - xf) * t));
                }
                try out.append(a, .{ .offset = p.offset + (st.offset - p.offset) * t, .color = Color.rgba(col[0], col[1], col[2], col[3]) });
            }
        }
        try out.append(a, st);
    }
    return out.items;
}
