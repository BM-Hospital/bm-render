//! SVG images as vector operators: takumi-core's `SvgLayout` (svg/layout/*.rs: Blink's SVG layout
//! into containers, shapes and pictures) and its `SvgPainter` (painter.rs: the containers as
//! `SvgOp`s), drawn the way takumi-pdf's `SvgPainter` (svg.rs) draws those ops onto a krilla
//! surface. takumi-pdf builds takumi-core without `svg-raster`, so SVG filters are not laid out at
//! all: a filtered element draws unfiltered. A CSS colour filter recolours every colour, gradient
//! stop and bitmap (svg.rs `filtered_color`).
//!
//! Ported: the root (`viewBox` / `preserveAspectRatio`; an image's root without a `viewBox` takes
//! one from its `width` / `height`, stretched), `g` / `a` / `switch` / nested `svg` / `use` (of
//! elements, `symbol` and `svg`, with their viewport clips), every shape, `image` (PNG / JPEG /
//! WebP embedded as krilla takes them, SVG laid out as a nested document), markers, element
//! transforms, `opacity`, `mix-blend-mode`, `isolation`, `clip-path` (as clip paths when simple,
//! else an alpha mask), `mask` (luminance / alpha soft masks), fills and strokes with colours,
//! `currentColor`, linear / radial gradients and patterns (`href` chains, both unit systems),
//! `paint-order`, `vector-effect: non-scaling-stroke`, `visibility`, `display`.
//!
//! Text uses shaped glyph outlines, inherited position lists, per-character rotation about the
//! cluster origin, anchors over the advances, letter / word spacing, dominant / alignment
//! baselines and `baseline-shift`, synthetic oblique, textPath placement, text decorations with
//! their declaring element's paint, and `tspan` opacity groups.
//! Not ported:
//! `context-fill` / `context-stroke`, `transform-origin`, the root's `background-color`, synthetic
//! bold and COLR layers of text glyphs, and takumi's op budget. Markup that is not SVG makes
//! `draw` return false (nothing drawn).
const std = @import("std");
const sf = @import("emit_surface.zig");
const geom = @import("emit_geom.zig");
const dev = @import("emit_device.zig");
const eimg = @import("emit_image.zig");
const raster = @import("../raster/raster.zig");
const dom = @import("../svg/dom.zig");
const num = @import("../svg/num.zig");
const scolor = @import("../svg/color.zig");
const sstyle = @import("../svg/style.zig");
const pathdata = @import("../svg/pathdata.zig");
const render_svg = @import("../svg/render.zig");
const cssc = @import("../style/color.zig");
const codec = @import("../codec/codec.zig");
const render = @import("../render.zig");
const font = @import("../font/font.zig");
const type3 = @import("type3.zig");
const text_position = @import("../svg/text_position.zig");
const path_measure = @import("../raster/path_measure.zig");

const Allocator = std.mem.Allocator;
const Tf = geom.Tf;
const Path = raster.Path;
const Affine = raster.Affine;
const Rect = raster.Rect;
const Node = dom.Node;
const NONE = dom.NONE;

const Error = error{OutOfMemory};

pub const Options = struct {
    /// `currentColor` of the host
    current: raster.Color,
    /// the CSS colour filter in effect (takumi-pdf `SvgPainter::new(filter)`)
    filter: ?*const dev.ColorFilter = null,
    /// an `<img>` / `url()` (takumi `SvgHost::Image`: a root without a `viewBox` synthesizes one),
    /// not an inline `<svg>`
    image_host: bool = true,
    /// the fonts `text` draws with (none: text draws nothing)
    fonts: ?*const font.FontCollection = null,
};

/// Draws SVG markup `src` laid out at its displayed size `w` x `h` with its top-left corner at
/// (`x`, `y`) (takumi `draw_svg` with the viewport = the size), clipped to that canvas. False
/// (nothing drawn) when the markup is not valid SVG.
pub fn draw(a: Allocator, s: *sf.Surface, src: []const u8, x: f32, y: f32, w: f32, h: f32, o: Options) Error!bool {
    if (!(w > 0) or !(h > 0)) return false;
    const doc = render_svg.parseDoc(true, a, src) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    if (doc.nodes.len == 0 or doc.nodes[0].tag != .svg) return false;
    var l: Layout = .{ .a = a, .doc = &doc, .current = o.current, .image_host = o.image_host, .fonts = o.fonts };
    const root = try l.layoutRoot(w, h);
    const depth0 = s.depth();
    s.pushTransform(Tf.translate(x, y));
    var canvas: Path = .{};
    try canvas.addRect(a, .{ .x = 0, .y = 0, .w = w, .h = h });
    s.pushClip(&canvas, .nonzero);
    var p: Painter = .{ .a = a, .filter = o.filter };
    try p.container(s, root);
    s.setFill(null);
    s.setStroke(null);
    s.popTo(depth0);
    return true;
}

// ---------------------------------------------------------------------------------------------
// The laid out tree (takumi `object.rs`)
// ---------------------------------------------------------------------------------------------

const Obj = union(enum) {
    group: *Group,
    shape: *Shape,
    picture: *Picture,

    /// takumi `bounds_in_parent`
    fn boundsInParent(o: Obj) ?Rect {
        return switch (o) {
            .group => |g| if (g.bbox) |b| num.transformRect(g.tf, b) else null,
            .shape => |sh| sh.bounds,
            .picture => |pc| .{ .x = 0, .y = 0, .w = pc.w, .h = pc.h },
        };
    }
};

const Group = struct {
    tf: Affine = .identity,
    abs: Affine = .identity,
    opacity: f32 = 1,
    blend: sf.Blend = .normal,
    isolate: bool = false,
    clip: ?*const Clip = null,
    mask: ?*const Mask = null,
    kids: std.ArrayList(Obj) = .empty,
    bbox: ?Rect = null,

    fn unionOfChildren(g: *const Group) ?Rect {
        var u: ?Rect = null;
        for (g.kids.items) |k| {
            const b = k.boundsInParent() orelse continue;
            u = if (u) |x| unite(x, b) else b;
        }
        return u;
    }

    fn objectBoundingBox(g: *const Group) ?Rect {
        const u = g.unionOfChildren() orelse return null;
        return if (u.w > 0 and u.h > 0) u else null;
    }

    fn finish(g: *Group) void {
        if (g.unionOfChildren()) |b| g.bbox = b;
    }
};

fn unite(x: Rect, y: Rect) Rect {
    const x0 = @min(x.x, y.x);
    const y0 = @min(x.y, y.y);
    const x1 = @max(x.x + x.w, y.x + y.w);
    const y1 = @max(x.y + x.h, y.y + y.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

const Grad = struct {
    linear: bool,
    /// x1 y1 x2 y2 (linear), cx cy r fx fy fr (radial)
    v: [6]f32,
    bbox_units: bool,
    tf: Affine,
    spread: sf.Spread,
    stops: []const sf.Stop,
};

const Pattern = struct {
    bbox_units: bool,
    content_bbox: bool,
    tf: Affine,
    rect: Rect,
    vb: ?struct { box: [4]f32, par: num.AspectRatio },
    root: *Group,
};

const PaintV = union(enum) {
    color: [3]u8,
    grad: *const Grad,
    pattern: *const Pattern,

    fn bboxUnits(p: PaintV) bool {
        return switch (p) {
            .color => false,
            .grad => |g| g.bbox_units,
            .pattern => |pt| pt.bbox_units or pt.content_bbox,
        };
    }
};

const FillV = struct { paint: PaintV, opacity: f32, evenodd: bool };
const StrokeV = struct {
    paint: PaintV,
    opacity: f32,
    width: f32,
    miter: f32,
    cap: sf.LineCap,
    join: sf.LineJoin,
    dash: ?sf.Dash,
};

const Shape = struct {
    path: Path,
    bounds: Rect,
    visible: bool,
    fill: ?FillV,
    stroke: ?StrokeV,
    stroke_first: bool,
};

const Picture = struct {
    content: union(enum) { bitmap: []const u8, svg: struct { root: *Group, w: f32, h: f32 } },
    w: f32,
    h: f32,
    visible: bool,
};

const Clip = struct { tf: Affine, nested: ?*const Clip, root: *Group };
const Mask = struct { rect: Rect, luminance: bool, nested: ?*const Mask, root: *Group };

// ---------------------------------------------------------------------------------------------
// Layout (takumi `svg/layout/mod.rs` and its submodules)
// ---------------------------------------------------------------------------------------------

const Scope = struct {
    in_clip: bool = false,
    in_markers: []const u32 = &.{},
    /// the nearest viewport (x, y, w, h), which percentages are of
    vb: [4]f32,
    use_w: ?f32 = null,
    use_h: ?f32 = null,

    fn diag(sc: *const Scope) f32 {
        return @sqrt((sc.vb[2] * sc.vb[2] + sc.vb[3] * sc.vb[3]) / 2);
    }
};

const max_depth = 48;
const max_instances = 100_000;

const Layout = struct {
    a: Allocator,
    doc: *const dom.Document,
    current: raster.Color,
    image_host: bool,
    active: std.ArrayList(u32) = .empty,
    depth: u32 = 0,
    instances: u32 = 0,
    image_depth: u32 = 0,
    fonts: ?*const font.FontCollection = null,
    text_paths: std.AutoHashMapUnmanaged(u64, ?*const path_measure.Measure) = .empty,

    fn node(l: *const Layout, i: u32) *const Node {
        return &l.doc.nodes[i];
    }

    fn isActive(l: *const Layout, i: u32) bool {
        return std.mem.indexOfScalar(u32, l.active.items, i) != null;
    }

    fn newGroup(l: *Layout, abs: Affine) Error!*Group {
        const g = try l.a.create(Group);
        g.* = .{ .abs = abs };
        return g;
    }

    /// takumi `layout_root`.
    fn layoutRoot(l: *Layout, vw: f32, vh: f32) Error!*Group {
        const tree = try l.newGroup(.identity);
        const root = l.node(0);
        var vb: [4]f32 = .{ 0, 0, vw, vh };
        var par: num.AspectRatio = .{};
        if (num.parseViewBox(root.attr("viewBox") orelse "")) |b| {
            if (b[2] > 0 and b[3] > 0) {
                vb = b;
                par = num.parseAspectRatio(root.attr("preserveAspectRatio"));
            }
        } else if (l.image_host) {
            // Blink `SVGSVGElement::ShouldSynthesizeViewBox`: the root's width / height, stretched
            const isz = render_svg.intrinsic(root);
            const side = struct {
                fn f(n: *const Node, name: []const u8, abs: ?f32, viewport: f32) f32 {
                    if (abs) |v| return v;
                    if (n.attr(name)) |t| if (num.parseLength(t)) |lv| if (lv.unit == .percent) return viewport * lv.v / 100;
                    return viewport;
                }
            }.f;
            vb = .{ 0, 0, side(root, "width", isz.width, vw), side(root, "height", isz.height, vh) };
            if (!(vb[2] > 0) or !(vb[3] > 0)) return tree;
            par = .{ .x = .none, .y = .none };
        }
        const scope: Scope = .{ .vb = vb };
        const root_tf = num.viewBoxTransform(vb, par, vw, vh);
        var st: sstyle.Style = .{ .color = l.current };
        if (isIdentity(root_tf)) {
            try l.element(0, &st, &scope, tree);
        } else {
            const g = try l.newGroup(root_tf);
            g.tf = root_tf;
            try l.element(0, &st, &scope, g);
            g.finish();
            try tree.kids.append(l.a, .{ .group = g });
        }
        tree.finish();
        return tree;
    }

    fn isGraphic(t: dom.Tag) bool {
        return switch (t) {
            .use, .image, .text => true,
            else => t.isShape(),
        };
    }

    /// The element's style: the inherited properties of `parent` with its own declarations
    /// (colours bm-render's SVG parser does not read go through the CSS parser).
    fn styleOf(l: *const Layout, n: *const Node, parent: *const sstyle.Style) sstyle.Style {
        var st = parent.*;
        st.apply(n);
        for (n.decls) |d| {
            const v = num.trim(d.value);
            switch (d.prop) {
                .fill, .stroke => {
                    if (sstyle.parsePaint(v) != null) continue;
                    const c = cssColor(v) orelse continue;
                    const sp: sstyle.SPaint = .{ .kind = .color, .color = c };
                    if (d.prop == .fill) st.fill = sp else st.stroke = sp;
                },
                .color => {
                    if (scolor.parse(v) != null or num.eqlIgnoreCase(v, "currentColor")) continue;
                    st.color = cssColor(v) orelse continue;
                },
                else => {},
            }
        }
        _ = l;
        return st;
    }

    fn display(n: *const Node) bool {
        if (n.decl(.display)) |d| if (std.mem.eql(u8, num.trim(d), "none")) return false;
        return true;
    }

    /// The element's `transform` (none when it is not renderable).
    fn transformOf(n: *const Node) Affine {
        const ts = n.decl(.transform) orelse return .identity;
        const t = num.parseTransform(ts) orelse return .identity;
        if (!renderable(t)) return .identity;
        return t;
    }

    fn renderable(t: Affine) bool {
        // Takumi tests row scales rather than invertibility: a rank-one transform with
        // both rows nonzero still reaches its paint (notably repeating SVG gradients).
        const sx = @sqrt(@as(f64, t.a) * t.a + @as(f64, t.c) * t.c);
        const sy = @sqrt(@as(f64, t.b) * t.b + @as(f64, t.d) * t.d);
        return t.isFinite() and sx > std.math.floatEps(f32) and sy > std.math.floatEps(f32);
    }

    /// takumi `is_visible_element`.
    fn visibleElement(n: *const Node) bool {
        if (!display(n)) return false;
        if (n.decl(.transform)) |ts| if (num.parseTransform(ts)) |t| if (!renderable(t)) return false;
        return passesConditions(n);
    }

    fn passesConditions(n: *const Node) bool {
        if (n.attr("requiredExtensions") != null) return false;
        const langs = n.attr("systemLanguage") orelse return true;
        var it = std.mem.splitScalar(u8, langs, ',');
        while (it.next()) |raw| {
            const t = num.trim(raw);
            if (std.mem.eql(u8, t, "en") or std.mem.startsWith(u8, t, "en-")) return true;
        }
        return false;
    }

    fn len(l: *const Layout, n: *const Node, name: []const u8, axis: num.Axis, def: f32, sc: *const Scope, fs: f32) f32 {
        _ = l;
        const t = n.attr(name) orelse return def;
        const v = num.parseLength(t) orelse return def;
        return resolveLen(v, axis, sc, fs);
    }

    fn deeper(l: *Layout) bool {
        if (l.depth >= max_depth or l.instances >= max_instances) return false;
        l.depth += 1;
        l.instances += 1;
        return true;
    }

    /// takumi `lay_out_element`.
    fn element(l: *Layout, idx: u32, parent: *const sstyle.Style, sc: *const Scope, out: *Group) Error!void {
        if (!l.deeper()) return;
        defer l.depth -= 1;
        const n = l.node(idx);
        switch (n.tag) {
            .g, .a, .@"switch", .svg => {},
            else => if (!isGraphic(n.tag)) return,
        }
        if (!visibleElement(n)) return;
        const st = l.styleOf(n, parent);
        switch (n.tag) {
            .use => return l.convertUse(idx, &st, sc, out),
            .@"switch" => {
                var ch = n.first_child;
                while (ch != NONE) : (ch = l.node(ch).next_sibling) {
                    const c = l.node(ch);
                    if (c.tag == .unknown or c.tag == .style or c.tag == .foreignObject or c.tag == .textnode) continue;
                    if (!passesConditions(c)) continue;
                    const g = try l.group(idx, &st, sc, false, out, .{ .child = ch });
                    if (g) |gg| try out.kids.append(l.a, .{ .group = gg });
                    return;
                }
                return;
            },
            .svg => if (idx != 0) return l.nestedSvg(idx, &st, sc, out),
            else => {},
        }
        const g = try l.group(idx, &st, sc, false, out, .content);
        if (g) |gg| try out.kids.append(l.a, .{ .group = gg });
    }

    const Collect = union(enum) {
        content,
        child: u32,
        children_of: struct { idx: u32, tf: Affine },
        clip_child: u32,
        use_target: struct { target: u32, tf: Affine },
    };

    /// takumi `convert_group`: the container an element makes, or null when it needs none (its
    /// children then go to `out`) or does not draw (a clip path or mask that resolves to nothing).
    fn group(l: *Layout, idx: u32, st: *const sstyle.Style, sc: *const Scope, force: bool, out: *Group, what: Collect) Error!?*Group {
        const n = l.node(idx);
        const opacity: f32 = if (sc.in_clip) 1 else if (n.decl(.opacity)) |v| sstyle.opacity(v) orelse 1 else 1;
        var tf = transformOf(n);
        const blend = if (n.decl(.mix_blend_mode)) |v| blendOf(num.trim(v)) else .normal;
        const isolate = if (n.decl(.isolation)) |v| std.mem.eql(u8, num.trim(v), "isolate") else false;
        const g_or_use = n.tag == .g or n.tag == .use;
        const g = try l.newGroup(out.abs.mul(tf));
        g.tf = tf;
        g.opacity = opacity;
        g.blend = blend;
        g.isolate = isolate;
        switch (what) {
            .content => try l.content(idx, st, sc, g),
            .child => |c| try l.element(c, st, sc, g),
            .children_of => |co| {
                tf = co.tf;
                g.tf = co.tf;
                g.abs = out.abs.mul(co.tf);
                try l.children(co.idx, st, sc, g);
            },
            .clip_child => |c| try l.clipChild(c, st, sc, g),
            .use_target => |ut| {
                tf = ut.tf;
                g.tf = ut.tf;
                g.abs = out.abs.mul(ut.tf);
                if (sc.in_clip) try l.clipChild(ut.target, st, sc, g) else try l.element(ut.target, st, sc, g);
            },
        }
        const obb = g.objectBoundingBox();
        if (refOf(n.decl(.clip_path))) |r| if (l.doc.byRef(r)) |link| if (!l.isActive(link)) {
            g.clip = (try l.clipPath(link, sc, obb)) orelse return null;
        };
        if (!sc.in_clip) if (refOf(n.decl(.mask))) |r| if (l.doc.byRef(r)) |link| if (!l.isActive(link)) {
            g.mask = (try l.mask(link, sc, obb)) orelse return null;
        };
        const required = opacity != 1 or g.clip != null or g.mask != null or !isIdentity(tf) or blend != .normal or isolate or g_or_use or force;
        if (!required) {
            try out.kids.appendSlice(l.a, g.kids.items);
            return null;
        }
        g.finish();
        return g;
    }

    fn children(l: *Layout, idx: u32, st: *const sstyle.Style, sc: *const Scope, out: *Group) Error!void {
        var ch = l.node(idx).first_child;
        while (ch != NONE) : (ch = l.node(ch).next_sibling) try l.element(ch, st, sc, out);
    }

    fn content(l: *Layout, idx: u32, st: *const sstyle.Style, sc: *const Scope, out: *Group) Error!void {
        const n = l.node(idx);
        switch (n.tag) {
            .svg, .g, .a => try l.children(idx, st, sc, out),
            .image => try l.image(idx, st, sc, out),
            .text => try l.text(idx, st, sc, out),
            else => if (n.tag.isShape()) try l.shape(idx, st, sc, out),
        }
    }

    // ---- use, nested svg (use_element.rs) ----------------------------------------------------

    fn convertUse(l: *Layout, idx: u32, st: *const sstyle.Style, sc: *const Scope, out: *Group) Error!void {
        const n = l.node(idx);
        const href = num.trim(n.attr("href") orelse return);
        if (href.len < 2 or href[0] != '#') return;
        const target = l.doc.byId(href[1..]) orelse return;
        if (target == idx or l.isActive(idx)) return;
        const tn = l.node(target);
        switch (tn.tag) {
            .unknown, .style, .foreignObject, .textnode => return,
            else => {},
        }
        // a `use` inside its target, or a target that uses it back
        {
            var stack: std.ArrayList(u32) = .empty;
            var ch = tn.first_child;
            while (ch != NONE) : (ch = l.node(ch).next_sibling) try stack.append(l.a, ch);
            while (stack.pop()) |d| {
                const dn = l.node(d);
                if (dn.tag == .use) if (dn.attr("href")) |h| {
                    const t = num.trim(h);
                    if (t.len > 1 and t[0] == '#') if (l.doc.byId(t[1..])) |inner| if (inner == idx or inner == target) return;
                };
                var c2 = dn.first_child;
                while (c2 != NONE) : (c2 = l.node(c2).next_sibling) try stack.append(l.a, c2);
            }
        }
        if (sc.in_clip and tn.tag == .symbol) return;
        try l.active.append(l.a, idx);
        defer _ = l.active.pop();
        if (!l.deeper()) return;
        defer l.depth -= 1;
        var us = sc.*;
        const fs = st.font_size;
        const x = l.len(n, "x", .x, 0, sc, fs);
        const y = l.len(n, "y", .y, 0, sc, fs);
        const own = transformOf(n);
        var new_tf = Affine.translate(x, y);
        if (tn.tag == .symbol) {
            const w = if (n.attr("width") != null) l.len(n, "width", .x, sc.vb[2], sc, fs) else sc.vb[2];
            const h = if (n.attr("height") != null) l.len(n, "height", .y, sc.vb[3], sc, fs) else sc.vb[3];
            if (w > 0 and h > 0) us.vb = .{ sc.vb[0], sc.vb[1], w, h };
            const sst = l.styleOf(tn, st);
            const vw = if (n.attr("width") != null) l.len(n, "width", .x, sc.vb[2], sc, fs) else sc.vb[2];
            const vh = if (n.attr("height") != null) l.len(n, "height", .y, sc.vb[3], sc, fs) else sc.vb[3];
            if (vw > 0 and vh > 0 and std.math.isFinite(vw) and std.math.isFinite(vh)) {
                if (num.parseViewBox(tn.attr("viewBox") orelse "")) |vb| if (vb[2] > 0 and vb[3] > 0) {
                    new_tf = new_tf.mul(num.viewBoxTransform(vb, num.parseAspectRatio(tn.attr("preserveAspectRatio")), vw, vh));
                };
            }
            if (overflowClips(tn) and vw > 0 and vh > 0 and std.math.isFinite(vw) and std.math.isFinite(vh)) {
                // the viewport clip, outside the use's own transform
                const clipped = try l.newGroup(out.abs);
                clipped.tf = own;
                clipped.abs = out.abs.mul(own);
                clipped.clip = try l.rectClip(.{ .x = x, .y = y, .w = vw, .h = vh });
                // (the use group holds the symbol's content under `new_tf`)
                const ug = try l.useGroup(idx, st, &us, clipped, target, &sst, new_tf, true);
                if (ug) |g| {
                    g.tf = .identity;
                    try clipped.kids.append(l.a, .{ .group = g });
                }
                if (clipped.kids.items.len == 0) return;
                clipped.finish();
                try out.kids.append(l.a, .{ .group = clipped });
                return;
            }
            const ug = try l.useGroup(idx, st, &us, out, target, &sst, own.mul(new_tf), false);
            if (ug) |g| {
                g.tf = .identity;
                try out.kids.append(l.a, .{ .group = g });
            }
            return;
        }
        if (tn.tag == .svg) {
            us.use_w = if (n.attr("width") != null) l.len(n, "width", .x, sc.vb[2], sc, fs) else null;
            us.use_h = if (n.attr("height") != null) l.len(n, "height", .y, sc.vb[3], sc, fs) else null;
        }
        const tf = own.mul(new_tf);
        const g = try l.group(idx, st, &us, !isIdentity(tf), out, .{ .use_target = .{ .target = target, .tf = tf } });
        if (g) |gg| try out.kids.append(l.a, .{ .group = gg });
    }

    /// The use's group around a symbol's children drawn under `tf` (takumi `convert_use_content`
    /// inside `convert_group`).
    fn useGroup(l: *Layout, idx: u32, st: *const sstyle.Style, sc: *const Scope, out: *Group, symbol: u32, sst: *const sstyle.Style, tf: Affine, force: bool) Error!?*Group {
        const n = l.node(idx);
        const opacity: f32 = if (sc.in_clip) 1 else if (n.decl(.opacity)) |v| sstyle.opacity(v) orelse 1 else 1;
        const g = try l.newGroup(out.abs);
        g.opacity = opacity;
        g.blend = if (n.decl(.mix_blend_mode)) |v| blendOf(num.trim(v)) else .normal;
        g.isolate = if (n.decl(.isolation)) |v| std.mem.eql(u8, num.trim(v), "isolate") else false;
        // the symbol's content group (`convert_use_group`, required when it transforms)
        const inner = try l.newGroup(out.abs.mul(tf));
        inner.tf = tf;
        if (sc.in_clip) {
            var ch = l.node(symbol).first_child;
            while (ch != NONE) : (ch = l.node(ch).next_sibling) try l.clipChild(ch, sst, sc, inner);
        } else try l.children(symbol, sst, sc, inner);
        if (!isIdentity(tf)) {
            inner.finish();
            try g.kids.append(l.a, .{ .group = inner });
        } else try g.kids.appendSlice(l.a, inner.kids.items);
        _ = st;
        const obb = g.objectBoundingBox();
        if (refOf(n.decl(.clip_path))) |r| if (l.doc.byRef(r)) |link| if (!l.isActive(link)) {
            g.clip = (try l.clipPath(link, sc, obb)) orelse return null;
        };
        if (!sc.in_clip) if (refOf(n.decl(.mask))) |r| if (l.doc.byRef(r)) |link| if (!l.isActive(link)) {
            g.mask = (try l.mask(link, sc, obb)) orelse return null;
        };
        _ = force;
        g.finish();
        return g;
    }

    /// Blink's UA style: a nested `svg`, `symbol`, `image`, `marker` and `pattern` hide their
    /// overflow.
    fn overflowClips(n: *const Node) bool {
        const o = num.trim(n.decl(.overflow) orelse "hidden");
        return !std.mem.eql(u8, o, "visible") and !std.mem.eql(u8, o, "auto");
    }

    /// takumi `convert_nested_svg`.
    fn nestedSvg(l: *Layout, idx: u32, st: *const sstyle.Style, sc: *const Scope, out: *Group) Error!void {
        const n = l.node(idx);
        const fs = st.font_size;
        const own = transformOf(n);
        const x = l.len(n, "x", .x, 0, sc, fs);
        const y = l.len(n, "y", .y, 0, sc, fs);
        var w = l.len(n, "width", .x, sc.vb[2], sc, fs);
        var h = l.len(n, "height", .y, sc.vb[3], sc, fs);
        w = sc.use_w orelse w;
        h = sc.use_h orelse h;
        var new_tf = Affine.translate(x, y);
        var inner = sc.*;
        const vb = num.parseViewBox(n.attr("viewBox") orelse "");
        if (w > 0 and h > 0 and std.math.isFinite(w) and std.math.isFinite(h)) {
            if (vb) |b| if (b[2] > 0 and b[3] > 0) {
                new_tf = new_tf.mul(num.viewBoxTransform(b, num.parseAspectRatio(n.attr("preserveAspectRatio")), w, h));
            };
        }
        if (vb) |b| {
            if (b[2] > 0 and b[3] > 0) inner.vb = b;
        } else if (w > 0 and h > 0) inner.vb = .{ x, y, w, h };
        const sized = (sc.use_w != null or sc.use_h != null) or (n.attr("width") != null and n.attr("height") != null);
        if (overflowClips(n) and sized and w > 0 and h > 0 and std.math.isFinite(w) and std.math.isFinite(h)) {
            const clipped = try l.newGroup(out.abs.mul(own));
            clipped.tf = own;
            clipped.clip = try l.rectClip(.{ .x = x, .y = y, .w = w, .h = h });
            const g = try l.group(idx, st, &inner, !isIdentity(new_tf), clipped, .{ .children_of = .{ .idx = idx, .tf = new_tf } });
            if (g) |gg| try clipped.kids.append(l.a, .{ .group = gg });
            clipped.finish();
            try out.kids.append(l.a, .{ .group = clipped });
            return;
        }
        const tf = own.mul(new_tf);
        const g = try l.group(idx, st, &inner, !isIdentity(tf), out, .{ .children_of = .{ .idx = idx, .tf = tf } });
        if (g) |gg| try out.kids.append(l.a, .{ .group = gg });
    }

    /// A clip to `r` (takumi `clip_container`'s `filled_rectangle`).
    fn rectClip(l: *Layout, r: Rect) Error!*const Clip {
        const root = try l.newGroup(.identity);
        const sh = try l.a.create(Shape);
        sh.* = .{ .path = .{}, .bounds = r, .visible = true, .fill = .{ .paint = .{ .color = .{ 0, 0, 0 } }, .opacity = 1, .evenodd = false }, .stroke = null, .stroke_first = false };
        try sh.path.addRect(l.a, r);
        try root.kids.append(l.a, .{ .shape = sh });
        root.finish();
        const c = try l.a.create(Clip);
        c.* = .{ .tf = .identity, .nested = null, .root = root };
        return c;
    }

    // ---- clip paths and masks (clip_mask.rs) ---------------------------------------------------

    fn clipChild(l: *Layout, idx: u32, parent: *const sstyle.Style, sc: *const Scope, out: *Group) Error!void {
        const n = l.node(idx);
        if (!isGraphic(n.tag)) return;
        if (!l.deeper()) return;
        defer l.depth -= 1;
        if (!visibleElement(n)) return;
        const st = l.styleOf(n, parent);
        if (n.tag == .use) return l.convertUse(idx, &st, sc, out);
        const g = try l.groupClipShape(idx, &st, sc, out);
        if (g) |gg| try out.kids.append(l.a, .{ .group = gg });
    }

    fn groupClipShape(l: *Layout, idx: u32, st: *const sstyle.Style, sc: *const Scope, out: *Group) Error!?*Group {
        const n = l.node(idx);
        // a `line` has no area to clip to; `text` is not ported
        if (n.tag == .line or n.tag == .text) return null;
        return l.group(idx, st, sc, false, out, .content);
    }

    fn clipPath(l: *Layout, link: u32, sc: *const Scope, obb: ?Rect) Error!?*const Clip {
        if (l.isActive(link)) return null;
        const n = l.node(link);
        if (n.tag != .clipPath) return null;
        if (n.decl(.transform)) |ts| if (num.parseTransform(ts)) |t| if (!renderable(t)) return null;
        try l.active.append(l.a, link);
        defer _ = l.active.pop();
        if (!l.deeper()) return null;
        defer l.depth -= 1;
        var tf = transformOf(n);
        if (std.mem.eql(u8, num.trim(n.attr("clipPathUnits") orelse ""), "objectBoundingBox")) {
            const b = obb orelse return null;
            tf = tf.mul(unitSquare(b));
        }
        var nested: ?*const Clip = null;
        if (refOf(n.decl(.clip_path))) |r| if (l.doc.byRef(r)) |nl| if (!l.isActive(nl)) {
            nested = (try l.clipPath(nl, sc, obb)) orelse return null;
        };
        var cs = sc.*;
        cs.in_clip = true;
        const root = try l.newGroup(.identity);
        var st: sstyle.Style = l.resourceStyle(link);
        var ch = n.first_child;
        while (ch != NONE) : (ch = l.node(ch).next_sibling) try l.clipChild(ch, &st, &cs, root);
        if (root.kids.items.len == 0) return null;
        root.finish();
        const c = try l.a.create(Clip);
        c.* = .{ .tf = tf, .nested = nested, .root = root };
        return c;
    }

    /// The inherited style a resource's children start from: the resource's own place in the
    /// document (takumi `styled_in_place`).
    fn resourceStyle(l: *Layout, idx: u32) sstyle.Style {
        var chain: [64]u32 = undefined;
        var n: usize = 0;
        var p = idx;
        while (p != NONE and n < chain.len) : (p = l.node(p).parent) {
            chain[n] = p;
            n += 1;
        }
        var st: sstyle.Style = .{ .color = l.current };
        while (n > 0) {
            n -= 1;
            st = l.styleOf(l.node(chain[n]), &st);
        }
        return st;
    }

    fn mask(l: *Layout, link: u32, sc: *const Scope, obb: ?Rect) Error!?*const Mask {
        if (l.isActive(link)) return null;
        const n = l.node(link);
        if (n.tag != .mask) return null;
        try l.active.append(l.a, link);
        defer _ = l.active.pop();
        if (!l.deeper()) return null;
        defer l.depth -= 1;
        const user = std.mem.eql(u8, num.trim(n.attr("maskUnits") orelse ""), "userSpaceOnUse");
        const content_bbox = std.mem.eql(u8, num.trim(n.attr("maskContentUnits") orelse ""), "objectBoundingBox");
        const st = l.resourceStyle(link);
        const fs = st.font_size;
        const coord = struct {
            fn f(ll: *const Layout, nn: *const Node, name: []const u8, axis: num.Axis, def: f32, u: bool, s: *const Scope, f_s: f32) f32 {
                const t = nn.attr(name);
                const v: num.Length = if (t) |x| num.parseLength(x) orelse .{ .v = def, .unit = .percent } else .{ .v = def, .unit = .percent };
                if (!u) return if (v.unit == .percent) v.v / 100 else num.resolve(v, 1, f_s);
                _ = ll;
                return resolveLen(v, axis, s, f_s);
            }
        }.f;
        var rect: Rect = .{
            .x = coord(l, n, "x", .x, -10, user, sc, fs),
            .y = coord(l, n, "y", .y, -10, user, sc, fs),
            .w = coord(l, n, "width", .x, 120, user, sc, fs),
            .h = coord(l, n, "height", .y, 120, user, sc, fs),
        };
        if (!(rect.w > 0) or !(rect.h > 0)) return null;
        if (!user) {
            if (obb) |b| {
                rect = .{ .x = b.x + rect.x * b.w, .y = b.y + rect.y * b.h, .w = rect.w * b.w, .h = rect.h * b.h };
                if (!(rect.w > 0) or !(rect.h > 0)) return null;
            } else {
                // masks everything
                const m = try l.a.create(Mask);
                m.* = .{ .rect = rect, .luminance = true, .nested = null, .root = try l.newGroup(.identity) };
                return m;
            }
        }
        var nested: ?*const Mask = null;
        if (refOf(n.decl(.mask))) |r| if (l.doc.byRef(r)) |nl| if (!l.isActive(nl)) {
            nested = (try l.mask(nl, sc, obb)) orelse return null;
        };
        const root = try l.newGroup(.identity);
        var real = root;
        if (content_bbox) {
            const b = obb orelse return null;
            real = try l.newGroup(unitSquare(b));
            real.tf = unitSquare(b);
        }
        try l.children(link, &st, sc, real);
        if (real.kids.items.len == 0) return null;
        if (content_bbox) {
            real.finish();
            try root.kids.append(l.a, .{ .group = real });
        }
        root.finish();
        const mt = num.trim(n.decl(.mask_type) orelse "luminance");
        const m = try l.a.create(Mask);
        m.* = .{ .rect = rect, .luminance = !std.mem.eql(u8, mt, "alpha"), .nested = nested, .root = root };
        return m;
    }

    // ---- shapes (shape.rs), markers (marker.rs) ------------------------------------------------

    fn shapePath(l: *Layout, n: *const Node, sc: *const Scope, fs: f32, verts: ?*std.ArrayList(pathdata.Vertex)) Error!?Path {
        var path: Path = .{};
        const a = l.a;
        switch (n.tag) {
            .path => pathdata.parse(a, n.attr("d") orelse "", &path, verts) catch return error.OutOfMemory,
            .polyline, .polygon => {
                pathdata.polyline(a, &path, n.attr("points") orelse "", n.tag == .polygon, verts) catch return error.OutOfMemory;
                if (path.points.items.len < 2) return null;
            },
            .rect => {
                const w = l.len(n, "width", .x, 0, sc, fs);
                const h = l.len(n, "height", .y, 0, sc, fs);
                if (!(w > 0 and h > 0) or !std.math.isFinite(w) or !std.math.isFinite(h)) return null;
                var rx: ?f32 = if (n.attr("rx") != null) @max(0, l.len(n, "rx", .x, 0, sc, fs)) else null;
                var ry: ?f32 = if (n.attr("ry") != null) @max(0, l.len(n, "ry", .y, 0, sc, fs)) else null;
                if (rx != null and !std.math.isFinite(rx.?)) rx = null;
                if (ry != null and !std.math.isFinite(ry.?)) ry = null;
                const x = l.len(n, "x", .x, 0, sc, fs);
                const y = l.len(n, "y", .y, 0, sc, fs);
                pathdata.rect(a, &path, x, y, w, h, rx orelse ry orelse 0, ry orelse rx orelse 0) catch return error.OutOfMemory;
                if (verts) |v| try rectVerts(a, v, x, y, w, h);
            },
            .circle => {
                const r = l.len(n, "r", .other, 0, sc, fs);
                if (!(r > 0) or !std.math.isFinite(r)) return null;
                pathdata.ellipse(a, &path, l.len(n, "cx", .x, 0, sc, fs), l.len(n, "cy", .y, 0, sc, fs), r, r) catch return error.OutOfMemory;
            },
            .ellipse => {
                var rx: ?f32 = if (n.attr("rx") != null) l.len(n, "rx", .x, 0, sc, fs) else null;
                var ry: ?f32 = if (n.attr("ry") != null) l.len(n, "ry", .y, 0, sc, fs) else null;
                if (rx == null) rx = ry;
                if (ry == null) ry = rx;
                if (rx == null or !(rx.? > 0) or !(ry.? > 0)) return null;
                pathdata.ellipse(a, &path, l.len(n, "cx", .x, 0, sc, fs), l.len(n, "cy", .y, 0, sc, fs), rx.?, ry.?) catch return error.OutOfMemory;
            },
            .line => {
                const x1 = l.len(n, "x1", .x, 0, sc, fs);
                const y1 = l.len(n, "y1", .y, 0, sc, fs);
                const x2 = l.len(n, "x2", .x, 0, sc, fs);
                const y2 = l.len(n, "y2", .y, 0, sc, fs);
                try path.moveTo(a, x1, y1);
                try path.lineTo(a, x2, y2);
                if (verts) |v| pathdata.lineVerts(a, v, x1, y1, x2, y2) catch return error.OutOfMemory;
            },
            else => return null,
        }
        if (path.verbs.items.len < 2) return null;
        return path;
    }

    fn rectVerts(a: Allocator, v: *std.ArrayList(pathdata.Vertex), x: f32, y: f32, w: f32, h: f32) Error!void {
        _ = a;
        _ = v;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
    }

    /// takumi `convert_shape`.
    fn shape(l: *Layout, idx: u32, st: *const sstyle.Style, sc: *const Scope, out: *Group) Error!void {
        const n = l.node(idx);
        const fs = st.font_size;
        var verts: std.ArrayList(pathdata.Vertex) = .empty;
        const markers = !sc.in_clip and st.visible and l.hasMarkers(st);
        var path = (try l.shapePath(n, sc, fs, if (markers) &verts else null)) orelse return;
        const cb = path.bounds();
        const has_bbox = cb.w > 0 and cb.h > 0;
        const bounds = pathdata.tightBounds(&path) orelse cb;
        var fill = try l.resolveFill(st, sc, has_bbox);
        var stroke = try l.resolveStroke(n, st, sc, has_bbox);
        var visible = st.visible;
        if (fill == null and stroke == null) visible = false;
        // `settle_paints`: bounding-box paints in user units of the shape's bounds
        if (fill) |*f| if (f.paint.bboxUnits()) {
            if (try l.inUserUnits(f.paint, bounds)) |p| f.paint = p else fill = null;
        };
        if (stroke) |*s| if (s.paint.bboxUnits()) {
            if (try l.inUserUnits(s.paint, bounds)) |p| s.paint = p else stroke = null;
        };
        var mk: ?*Group = null;
        if (markers) {
            const g = try l.newGroup(out.abs);
            try l.convertMarkers(n, st, verts.items, sc, g);
            g.finish();
            mk = g;
        }
        const stroke_first = (st.paint_order & 3) == 1;
        const sh: Shape = .{ .path = path, .bounds = bounds, .visible = visible, .fill = fill, .stroke = stroke, .stroke_first = stroke_first };
        const nss = if (n.decl(.vector_effect)) |v| std.mem.eql(u8, num.trim(v), "non-scaling-stroke") else false;
        const phases = [3]u8{ st.paint_order & 3, (st.paint_order >> 2) & 3, (st.paint_order >> 4) & 3 };
        if (mk) |m| {
            if (phases[0] == 2) {
                try out.kids.append(l.a, .{ .group = m });
                try l.objects(sh, nss, out);
            } else if (phases[1] == 2) {
                try l.singlePhase(sh, phases[0], nss, out);
                try out.kids.append(l.a, .{ .group = m });
                try l.singlePhase(sh, phases[2], nss, out);
            } else {
                try l.objects(sh, nss, out);
                try out.kids.append(l.a, .{ .group = m });
            }
        } else try l.objects(sh, nss, out);
    }

    fn singlePhase(l: *Layout, sh: Shape, phase: u8, nss: bool, out: *Group) Error!void {
        var one = sh;
        switch (phase) {
            0 => if (one.fill != null) {
                one.stroke = null;
            } else return,
            1 => if (one.stroke != null) {
                one.fill = null;
            } else return,
            else => return,
        }
        try l.objects(one, nss, out);
    }

    /// The shape, or with `vector-effect: non-scaling-stroke` its fill and its stroke drawn in the
    /// host's space (takumi `with_non_scaling_stroke`).
    fn objects(l: *Layout, sh: Shape, nss: bool, out: *Group) Error!void {
        if (!nss or sh.stroke == null) {
            const p = try l.a.create(Shape);
            p.* = sh;
            return out.kids.append(l.a, .{ .shape = p });
        }
        const t = out.abs;
        const inv = t.invert() orelse {
            if (sh.fill == null) return;
            const p = try l.a.create(Shape);
            p.* = sh;
            p.stroke = null;
            return out.kids.append(l.a, .{ .shape = p });
        };
        const stroked = try l.a.create(Shape);
        stroked.* = sh;
        stroked.fill = null;
        stroked.path = .{};
        try stroked.path.addPath(l.a, &sh.path, t);
        stroked.bounds = num.transformRect(t, sh.bounds);
        stroked.stroke.?.paint = try l.transformedPaint(sh.stroke.?.paint, t);
        const host = try l.newGroup(.identity);
        host.tf = inv;
        try host.kids.append(l.a, .{ .shape = stroked });
        host.finish();
        var filled: ?*Shape = null;
        if (sh.fill != null) {
            filled = try l.a.create(Shape);
            filled.?.* = sh;
            filled.?.stroke = null;
        }
        if (sh.stroke_first) {
            try out.kids.append(l.a, .{ .group = host });
            if (filled) |f| try out.kids.append(l.a, .{ .shape = f });
        } else {
            if (filled) |f| try out.kids.append(l.a, .{ .shape = f });
            try out.kids.append(l.a, .{ .group = host });
        }
    }

    fn hasMarkers(l: *const Layout, st: *const sstyle.Style) bool {
        for ([_][]const u8{ st.marker_start, st.marker_mid, st.marker_end }) |m| {
            if (refOf(m)) |r| if (l.doc.byRef(r) != null) return true;
        }
        return false;
    }

    fn convertMarkers(l: *Layout, n: *const Node, st: *const sstyle.Style, vs: []const pathdata.Vertex, sc: *const Scope, out: *Group) Error!void {
        if (vs.len == 0) return;
        const refs = [3][]const u8{ st.marker_start, st.marker_mid, st.marker_end };
        for (refs, 0..) |ref, kind| {
            const r = refOf(ref) orelse continue;
            const link = l.doc.byRef(r) orelse continue;
            if (l.node(link).tag != .marker) continue;
            if (std.mem.indexOfScalar(u32, sc.in_markers, link) != null) continue;
            if (!l.deeper()) continue;
            defer l.depth -= 1;
            try l.marker(n, st, vs, link, kind, sc, out);
        }
    }

    fn marker(l: *Layout, shape_n: *const Node, st: *const sstyle.Style, vs: []const pathdata.Vertex, link: u32, kind: usize, sc: *const Scope, out: *Group) Error!void {
        const m = l.node(link);
        const mst = l.resourceStyle(link);
        const fs = mst.font_size;
        // `stroke_scale`
        var scale: f32 = 1;
        if (!std.mem.eql(u8, num.trim(m.attr("markerUnits") orelse ""), "userSpaceOnUse")) {
            var w = resolveLen(st.stroke_width, .other, sc, st.font_size);
            if (shape_n.decl(.vector_effect)) |v| if (std.mem.eql(u8, num.trim(v), "non-scaling-stroke")) {
                w /= rmsScale(out.abs);
            };
            if (!(w > 0) or !std.math.isFinite(w)) return;
            scale = w;
        }
        const rect: Rect = .{
            .x = l.len(m, "refX", .x, 0, sc, fs),
            .y = l.len(m, "refY", .y, 0, sc, fs),
            .w = l.len(m, "markerWidth", .x, 3, sc, fs),
            .h = l.len(m, "markerHeight", .y, 3, sc, fs),
        };
        if (!(rect.w > 0) or !(rect.h > 0)) return;
        const vb = num.parseViewBox(m.attr("viewBox") orelse "");
        var clip: ?*const Clip = null;
        if (overflowClips(m)) {
            const cr: Rect = if (vb) |b| .{ .x = b[0], .y = b[1], .w = b[2], .h = b[3] } else .{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };
            if (!(cr.w > 0) or !(cr.h > 0)) return;
            clip = try l.rectClip(cr);
        }
        const orient = num.trim(m.attr("orient") orelse "");
        var ms = sc.*;
        var list: std.ArrayList(u32) = .empty;
        try list.appendSlice(l.a, sc.in_markers);
        try list.append(l.a, link);
        ms.in_markers = list.items;
        for (vs, 0..) |v, i| {
            const want: usize = if (i == 0) 0 else if (i == vs.len - 1) 2 else 1;
            if (want != kind) continue;
            var angle: f32 = 0;
            if (std.mem.eql(u8, orient, "auto") or std.mem.eql(u8, orient, "auto-start-reverse")) {
                const a_in: ?f32 = if (v.in) |d| num.atan2(d.y, d.x) else null;
                const a_out: ?f32 = if (v.out) |d| num.atan2(d.y, d.x) else null;
                var rad: f32 = 0;
                if (a_in != null and a_out != null) {
                    var diff = a_out.? - a_in.?;
                    if (diff > std.math.pi) diff -= 2 * std.math.pi;
                    if (diff < -std.math.pi) diff += 2 * std.math.pi;
                    rad = a_in.? + diff / 2;
                } else rad = a_in orelse a_out orelse 0;
                angle = rad * 180 / std.math.pi;
                if (i == 0 and std.mem.eql(u8, orient, "auto-start-reverse")) angle = @mod(angle + 180, 360);
            } else if (orient.len > 0) {
                var rd: num.Reader = .{ .s = orient };
                angle = rd.number() orelse 0;
            }
            var t = Affine.translate(v.x, v.y);
            if (@abs(angle) > 1e-6) t = t.mul(Affine.rotate(angle * std.math.pi / 180));
            if (vb) |b| {
                const sw = rect.w * scale;
                const shh = rect.h * scale;
                if (!(sw > 0 and shh > 0) or !std.math.isFinite(sw) or !std.math.isFinite(shh)) return;
                const vt = num.viewBoxTransform(b, num.parseAspectRatio(m.attr("preserveAspectRatio")), sw, shh);
                t = t.mul(Affine.scale(@sqrt(vt.a * vt.a + vt.c * vt.c), @sqrt(vt.b * vt.b + vt.d * vt.d)));
            } else t = t.mul(Affine.scale(scale, scale));
            t = t.mul(Affine.translate(-rect.x, -rect.y));
            const g = try l.newGroup(out.abs.mul(t));
            g.tf = t;
            g.clip = clip;
            try l.children(link, &mst, &ms, g);
            g.finish();
            if (g.kids.items.len > 0) try out.kids.append(l.a, .{ .group = g });
        }
    }

    // ---- paint (paint.rs, paint_server.rs) ------------------------------------------------------

    fn colorPaint(c: raster.Color) FillV {
        return .{ .paint = .{ .color = .{ c.r, c.g, c.b } }, .opacity = @as(f32, @floatFromInt(c.a)) / 255, .evenodd = false };
    }

    /// takumi `convert_paint`: the paint and the colour's opacity; null for none.
    fn convertPaint(l: *Layout, sp: sstyle.SPaint, st: *const sstyle.Style, sc: *const Scope, has_bbox: bool) Error!?FillV {
        const fallback: ?FillV = switch (sp.fallback) {
            .color => colorPaint(sp.color),
            .current => colorPaint(st.color),
            else => null,
        };
        switch (sp.kind) {
            .none => return null,
            .color => return colorPaint(sp.color),
            .current => return colorPaint(st.color),
            .server => {
                const link = l.doc.byRef(sp.ref) orelse return fallback;
                const t = l.node(link).tag;
                if (t != .linearGradient and t != .radialGradient and t != .pattern) return fallback;
                const srv = (try l.paintServer(link, sc)) orelse return fallback;
                switch (srv) {
                    .paint => |p| {
                        if (!has_bbox and p.bboxUnits()) return fallback;
                        return .{ .paint = p, .opacity = 1, .evenodd = false };
                    },
                    .color => |c| return .{ .paint = .{ .color = c.rgb }, .opacity = c.opacity, .evenodd = false },
                }
            },
        }
    }

    fn resolveFill(l: *Layout, st: *const sstyle.Style, sc: *const Scope, has_bbox: bool) Error!?FillV {
        if (sc.in_clip) return .{ .paint = .{ .color = .{ 0, 0, 0 } }, .opacity = 1, .evenodd = st.clip_rule == .evenodd };
        var f = (try l.convertPaint(st.fill, st, sc, has_bbox)) orelse return null;
        f.opacity *= std.math.clamp(st.fill_opacity, 0, 1);
        f.evenodd = st.fill_rule == .evenodd;
        return f;
    }

    fn resolveStroke(l: *Layout, n: *const Node, st: *const sstyle.Style, sc: *const Scope, has_bbox: bool) Error!?StrokeV {
        _ = n;
        if (sc.in_clip) return null;
        const p = (try l.convertPaint(st.stroke, st, sc, has_bbox)) orelse return null;
        const w = resolveLen(st.stroke_width, .other, sc, st.font_size);
        if (!(w > 0) or !std.math.isFinite(w)) return null;
        return .{
            .paint = p.paint,
            .opacity = p.opacity * std.math.clamp(st.stroke_opacity, 0, 1),
            .width = w,
            .miter = st.miter_limit,
            .cap = switch (st.cap) {
                .butt => .butt,
                .round => .round,
                .square => .square,
            },
            .join = switch (st.join) {
                .miter => .miter,
                .round => .round,
                .bevel => .bevel,
            },
            .dash = try l.dashes(st, sc),
        };
    }

    /// takumi `dash_pattern`.
    fn dashes(l: *Layout, st: *const sstyle.Style, sc: *const Scope) Error!?sf.Dash {
        const v = num.trim(st.dasharray);
        if (v.len == 0 or std.mem.eql(u8, v, "none")) return null;
        var list: std.ArrayList(f32) = .empty;
        var it = std.mem.tokenizeAny(u8, v, " ,\t\r\n");
        var sum: f32 = 0;
        while (it.next()) |t| {
            const len_ = num.parseLength(t) orelse return null;
            const d = resolveLen(len_, .other, sc, st.font_size);
            if (d < 0 or std.math.signbit(d) or !std.math.isFinite(d)) return null;
            sum += d;
            try list.append(l.a, d);
        }
        if (@as(u32, @bitCast(sum)) <= 4) return null;
        if (list.items.len % 2 == 1) try list.appendSlice(l.a, try l.a.dupe(f32, list.items));
        return .{ .array = list.items, .offset = resolveLen(st.dashoffset, .other, sc, st.font_size) };
    }

    const Server = union(enum) { paint: PaintV, color: struct { rgb: [3]u8, opacity: f32 } };

    fn hrefTarget(l: *const Layout, idx: u32) ?u32 {
        const h = num.trim(l.node(idx).attr("href") orelse return null);
        if (h.len < 2 or h[0] != '#') return null;
        return l.doc.byId(h[1..]);
    }

    fn hrefChain(l: *Layout, idx: u32) Error![]const u32 {
        var chain: std.ArrayList(u32) = .empty;
        try chain.append(l.a, idx);
        var cur = idx;
        while (l.hrefTarget(cur)) |link| {
            if (link == cur or std.mem.indexOfScalar(u32, chain.items, link) != null or chain.items.len > 64) break;
            try chain.append(l.a, link);
            cur = link;
        }
        return chain.items;
    }

    fn isGradient(t: dom.Tag) bool {
        return t == .linearGradient or t == .radialGradient;
    }

    /// takumi `resolve_attr`: the element along the href chain that sets `name`.
    fn resolveAttr(l: *Layout, idx: u32, name: []const u8) Error!u32 {
        const n = l.node(idx);
        if (n.attr(name) != null) return idx;
        const kind = n.tag;
        const geom_l = std.mem.eql(u8, name, "x1") or std.mem.eql(u8, name, "y1") or std.mem.eql(u8, name, "x2") or std.mem.eql(u8, name, "y2");
        const geom_r = std.mem.eql(u8, name, "cx") or std.mem.eql(u8, name, "cy") or std.mem.eql(u8, name, "r") or std.mem.eql(u8, name, "fx") or std.mem.eql(u8, name, "fy") or std.mem.eql(u8, name, "fr");
        const shared = std.mem.eql(u8, name, "gradientUnits") or std.mem.eql(u8, name, "spreadMethod") or std.mem.eql(u8, name, "gradientTransform");
        for (try l.hrefChain(idx)) |link| {
            const src = l.node(link).tag;
            const ok = switch (kind) {
                .linearGradient => (geom_l and src == .linearGradient) or (shared and isGradient(src)),
                .radialGradient => (geom_r and src == .radialGradient) or (shared and isGradient(src)),
                .pattern => src == .pattern,
                else => false,
            };
            if (!ok) break;
            if (l.node(link).attr(name) != null) return link;
        }
        return idx;
    }

    fn unitsOf(l: *Layout, idx: u32, name: []const u8, default_bbox: bool) Error!bool {
        const v = num.trim(l.node(try l.resolveAttr(idx, name)).attr(name) orelse "");
        if (std.mem.eql(u8, v, "userSpaceOnUse")) return false;
        if (std.mem.eql(u8, v, "objectBoundingBox")) return true;
        return default_bbox;
    }

    /// The element's `transform` presentation (a gradient's `gradientTransform`, a pattern's
    /// `patternTransform`, along the chain).
    fn ownTransform(l: *Layout, idx: u32, attr_name: []const u8) Error!Affine {
        const src = try l.resolveAttr(idx, attr_name);
        const ts = l.node(src).attr(attr_name) orelse return .identity;
        const t = num.parseTransform(ts) orelse return .identity;
        return if (renderable(t)) t else .identity;
    }

    fn number(l: *Layout, idx: u32, name: []const u8, bbox_units: bool, sc: *const Scope, def: num.Length) Error!f32 {
        const src = try l.resolveAttr(idx, name);
        const v = if (l.node(src).attr(name)) |t| num.parseLength(t) orelse def else def;
        const fs: f32 = 16;
        if (bbox_units) return if (v.unit == .percent) v.v / 100 else num.resolve(v, 1, fs);
        const axis: num.Axis = if (std.mem.eql(u8, name, "x") or std.mem.eql(u8, name, "x1") or std.mem.eql(u8, name, "x2") or std.mem.eql(u8, name, "cx") or std.mem.eql(u8, name, "fx") or std.mem.eql(u8, name, "width"))
            .x
        else if (std.mem.eql(u8, name, "y") or std.mem.eql(u8, name, "y1") or std.mem.eql(u8, name, "y2") or std.mem.eql(u8, name, "cy") or std.mem.eql(u8, name, "fy") or std.mem.eql(u8, name, "height"))
            .y
        else
            .other;
        return resolveLen(v, axis, sc, fs);
    }

    fn spreadOf(l: *Layout, idx: u32) Error!sf.Spread {
        const v = num.trim(l.node(try l.resolveAttr(idx, "spreadMethod")).attr("spreadMethod") orelse "");
        if (std.mem.eql(u8, v, "reflect")) return .reflect;
        if (std.mem.eql(u8, v, "repeat")) return .repeat;
        return .pad;
    }

    fn paintServer(l: *Layout, idx: u32, sc: *const Scope) Error!?Server {
        const n = l.node(idx);
        if (n.tag == .pattern) {
            if (l.isActive(idx)) return null;
            try l.active.append(l.a, idx);
            defer _ = l.active.pop();
            if (!l.deeper()) return null;
            defer l.depth -= 1;
            return l.pattern(idx, sc);
        }
        // `gradient_with_stops`
        var with_stops: ?u32 = null;
        for (try l.hrefChain(idx)) |link| {
            if (!isGradient(l.node(link).tag)) return null;
            var ch = l.node(link).first_child;
            var has = false;
            while (ch != NONE) : (ch = l.node(ch).next_sibling) {
                if (l.node(ch).tag == .stop) has = true;
            }
            if (has) {
                with_stops = link;
                break;
            }
        }
        const stops = try l.gradientStops(with_stops orelse return null);
        if (stops.len < 2) {
            if (stops.len == 0) return null;
            return .{ .color = .{ .rgb = stops[0].color, .opacity = stops[0].opacity } };
        }
        const bbox_units = try l.unitsOf(idx, "gradientUnits", true);
        const g = try l.a.create(Grad);
        g.* = .{ .linear = n.tag == .linearGradient, .v = undefined, .bbox_units = bbox_units, .tf = try l.ownTransform(idx, "gradientTransform"), .spread = try l.spreadOf(idx), .stops = stops };
        if (n.tag == .linearGradient) {
            g.v = .{
                try l.number(idx, "x1", bbox_units, sc, .{ .v = 0 }),
                try l.number(idx, "y1", bbox_units, sc, .{ .v = 0 }),
                try l.number(idx, "x2", bbox_units, sc, .{ .v = 100, .unit = .percent }),
                try l.number(idx, "y2", bbox_units, sc, .{ .v = 0 }),
                0,
                0,
            };
        } else {
            const r = try l.number(idx, "r", bbox_units, sc, .{ .v = 50, .unit = .percent });
            const fr = try l.number(idx, "fr", bbox_units, sc, .{ .v = 0 });
            if (!(r > 0) or !std.math.isFinite(r)) {
                const last = stops[stops.len - 1];
                return .{ .color = .{ .rgb = last.color, .opacity = last.opacity } };
            }
            const cx = try l.number(idx, "cx", bbox_units, sc, .{ .v = 50, .unit = .percent });
            const cy = try l.number(idx, "cy", bbox_units, sc, .{ .v = 50, .unit = .percent });
            const fx = if (l.node(try l.resolveAttr(idx, "fx")).attr("fx") != null) try l.number(idx, "fx", bbox_units, sc, .{ .v = 0 }) else cx;
            const fy = if (l.node(try l.resolveAttr(idx, "fy")).attr("fy") != null) try l.number(idx, "fy", bbox_units, sc, .{ .v = 0 }) else cy;
            g.v = .{ cx, cy, r, fx, fy, if (fr > 0 and std.math.isFinite(fr)) fr else 0 };
        }
        return .{ .paint = .{ .grad = g } };
    }

    /// takumi `gradient_stops` + `spread_equal_offsets`.
    fn gradientStops(l: *Layout, gi: u32) Error![]sf.Stop {
        var out: std.ArrayList(sf.Stop) = .empty;
        var prev: f32 = 0;
        const base = l.resourceStyle(gi);
        var ch = l.node(gi).first_child;
        while (ch != NONE) : (ch = l.node(ch).next_sibling) {
            const n = l.node(ch);
            if (n.tag != .stop) continue;
            var off = prev;
            if (n.attr("offset")) |o| {
                const t = num.trim(o);
                if (t.len > 0 and t[t.len - 1] == '%') {
                    if (num.parseNumber(t[0 .. t.len - 1])) |v| off = v / 100;
                } else if (num.parseNumber(t)) |v| off = v;
            }
            prev = off;
            const sst = l.styleOf(n, &base);
            var c: raster.Color = raster.Color.black;
            if (n.decl(.stop_color)) |v| {
                const t = num.trim(v);
                if (num.eqlIgnoreCase(t, "currentColor")) c = sst.color else if (scolor.parse(t)) |x| c = x else if (cssColor(t)) |x| c = x;
            }
            var so: f32 = 1;
            if (n.decl(.stop_opacity)) |v| so = sstyle.opacity(v) orelse 1;
            try out.append(l.a, .{
                .offset = std.math.clamp(off, 0, 1),
                .color = .{ c.r, c.g, c.b },
                .opacity = @as(f32, @floatFromInt(c.a)) / 255 * so,
            });
        }
        var s = out.items;
        const eq = struct {
            fn f(x: f32, y: f32) bool {
                return @abs(x - y) <= std.math.floatEps(f32) * @max(@max(@abs(x), @abs(y)), 1);
            }
        }.f;
        if (s.len >= 3) {
            var i: usize = 0;
            while (i + 2 < s.len) {
                if (eq(s[i].offset, s[i + 1].offset) and eq(s[i + 1].offset, s[i + 2].offset)) {
                    std.mem.copyForwards(sf.Stop, s[i + 1 ..], s[i + 2 ..]);
                    s = s[0 .. s.len - 1];
                } else i += 1;
            }
        }
        if (s.len >= 2) for (0..s.len - 1) |i| {
            if (eq(s[i].offset, 0) and eq(s[i + 1].offset, 0)) s[i + 1].offset = std.math.clamp(s[i].offset + std.math.floatEps(f32), 0, 1);
        };
        if (s.len >= 2) for (1..s.len) |i| {
            const pv = s[i - 1].offset;
            const cur = s[i].offset;
            if (pv > cur or eq(pv, cur)) {
                s[i - 1].offset = std.math.clamp(pv - std.math.floatEps(f32), 0, 1);
                s[i].offset = std.math.clamp(pv, 0, 1);
            }
        };
        return s;
    }

    /// takumi `pattern`.
    fn pattern(l: *Layout, idx: u32, sc: *const Scope) Error!?Server {
        var with_children: ?u32 = null;
        for (try l.hrefChain(idx)) |link| {
            if (l.node(link).tag != .pattern) return null;
            if (l.node(link).first_child != NONE) {
                with_children = link;
                break;
            }
        }
        const wc = with_children orelse return null;
        const vb_src = l.node(try l.resolveAttr(idx, "viewBox"));
        const par_src = l.node(try l.resolveAttr(idx, "preserveAspectRatio"));
        const bbox_units = try l.unitsOf(idx, "patternUnits", true);
        const content_bbox = try l.unitsOf(idx, "patternContentUnits", false);
        const p = try l.a.create(Pattern);
        p.* = .{
            .bbox_units = bbox_units,
            .content_bbox = content_bbox,
            .tf = try l.ownTransform(idx, "patternTransform"),
            .rect = .{
                .x = try l.number(idx, "x", bbox_units, sc, .{ .v = 0 }),
                .y = try l.number(idx, "y", bbox_units, sc, .{ .v = 0 }),
                .w = try l.number(idx, "width", bbox_units, sc, .{ .v = 0 }),
                .h = try l.number(idx, "height", bbox_units, sc, .{ .v = 0 }),
            },
            .vb = null,
            .root = undefined,
        };
        if (!(p.rect.w > 0) or !(p.rect.h > 0)) return null;
        if (num.parseViewBox(vb_src.attr("viewBox") orelse "")) |b| if (b[2] > 0 and b[3] > 0) {
            p.vb = .{ .box = b, .par = num.parseAspectRatio(par_src.attr("preserveAspectRatio")) };
        };
        const st = l.resourceStyle(wc);
        const root = try l.newGroup(.identity);
        if (p.vb != null and !bbox_units and !content_bbox) {
            const vt = num.viewBoxTransform(p.vb.?.box, p.vb.?.par, p.rect.w, p.rect.h);
            const g = try l.newGroup(vt);
            g.tf = vt;
            try l.children(wc, &st, sc, g);
            if (g.kids.items.len == 0) return null;
            g.finish();
            try root.kids.append(l.a, .{ .group = g });
        } else {
            try l.children(wc, &st, sc, root);
            if (root.kids.items.len == 0) return null;
        }
        root.finish();
        p.root = root;
        return .{ .paint = .{ .pattern = p } };
    }

    /// takumi `Paint::in_user_units`.
    fn inUserUnits(l: *Layout, p: PaintV, b: Rect) Error!?PaintV {
        if (!(b.w > 0) or !(b.h > 0)) return null;
        switch (p) {
            .color => return p,
            .grad => |g| {
                const ng = try l.a.create(Grad);
                ng.* = g.*;
                ng.bbox_units = false;
                ng.tf = unitSquare(b).mul(g.tf);
                return .{ .grad = ng };
            },
            .pattern => |pt| {
                const rect: Rect = if (pt.bbox_units) .{ .x = b.x + pt.rect.x * b.w, .y = b.y + pt.rect.y * b.h, .w = pt.rect.w * b.w, .h = pt.rect.h * b.h } else pt.rect;
                if (!(rect.w > 0) or !(rect.h > 0)) return null;
                var root = pt.root;
                if (pt.content_bbox and pt.vb == null) root = try l.wrapped(root, Affine.scale(b.w, b.h));
                if (pt.vb) |v| root = try l.wrapped(root, num.viewBoxTransform(v.box, v.par, rect.w, rect.h));
                const np = try l.a.create(Pattern);
                np.* = .{ .bbox_units = false, .content_bbox = false, .tf = pt.tf, .rect = rect, .vb = pt.vb, .root = root };
                return .{ .pattern = np };
            },
        }
    }

    fn wrapped(l: *Layout, g: *Group, t: Affine) Error!*Group {
        const inner = try l.a.create(Group);
        inner.* = g.*;
        inner.tf = t;
        inner.abs = t;
        const root = try l.newGroup(.identity);
        try root.kids.append(l.a, .{ .group = inner });
        root.finish();
        return root;
    }

    fn transformedPaint(l: *Layout, p: PaintV, t: Affine) Error!PaintV {
        switch (p) {
            .color => return p,
            .grad => |g| {
                const ng = try l.a.create(Grad);
                ng.* = g.*;
                ng.tf = t.mul(g.tf);
                return .{ .grad = ng };
            },
            .pattern => |pt| {
                const np = try l.a.create(Pattern);
                np.* = pt.*;
                np.tf = t.mul(pt.tf);
                return .{ .pattern = np };
            },
        }
    }

    // ---- text (text/*.rs, simplified) -----------------------------------------------------------

    const Seg = struct {
        text: std.ArrayList(u8) = .empty,
        positions: std.ArrayList(text_position.Position) = .empty,
        st: sstyle.Style,
        flow: u32 = NONE,
        span: SpanCtx = .{},
        /// `alignment-baseline` of the element holding the characters (not inherited).
        alignment: []const u8 = "",
    };
    /// What a `tspan` / `textPath` / `a` passes to the characters below it (takumi `TextElement`):
    /// the product of their opacities and their stacked `baseline-shift`s. The `text` element's own
    /// opacity groups the whole text and its `baseline-shift` does not apply.
    const SpanCtx = struct {
        opacity: f32 = 1,
        /// `baseline-shift` lengths, in user units
        shift: f32 = 0,
        /// superscripts less subscripts, each half the height of the font
        supers: i32 = 0,

        fn enter(ctx: SpanCtx, n: *const dom.Node, font_size: f32, in_clip: bool) SpanCtx {
            var out = ctx;
            if (!in_clip) if (n.decl(.opacity)) |v| {
                out.opacity *= sstyle.opacity(v) orelse 1;
            };
            const v = num.trim(n.decl(.baseline_shift) orelse return out);
            if (std.mem.eql(u8, v, "sub")) {
                out.supers -= 1;
            } else if (std.mem.eql(u8, v, "super")) {
                out.supers += 1;
            } else if (num.parseLength(v)) |length| {
                const px = num.resolve(length, font_size, font_size);
                if (std.math.isFinite(px)) out.shift += px;
            }
            return out;
        }
    };

    /// How far a span's text moves down: its stacked `baseline-shift`, and the baseline that
    /// `alignment-baseline` (else `dominant-baseline`) names put where the alphabetic one was
    /// (takumi `SpanStyle::baseline_shift`, Blink `FontMetrics::FloatAscent`).
    fn baselineShift(face: *const font.Font, size: f32, sg: *const Seg) f32 {
        const m = face.lineMetrics();
        const upem: f32 = @floatFromInt(@max(face.units_per_em, 1));
        const ascent = @round(@as(f32, @floatFromInt(m.ascent)) * size / upem);
        const descent = @round(@as(f32, @floatFromInt(@abs(m.descent))) * size / upem);
        const height = ascent + descent;
        const xh_units = face.xHeight();
        const x_height = if (xh_units > 0) @as(f32, @floatFromInt(xh_units)) * size / upem else ascent * 0.56;
        const Baseline = enum { alphabetic, central, under, x_middle, math, hanging, over };
        const keyword = struct {
            fn of(v: []const u8, alignment: bool) ?Baseline {
                const t = num.trim(v);
                const eq = std.mem.eql;
                if (alignment and (eq(u8, t, "before-edge") or eq(u8, t, "text-before-edge"))) return .over;
                if (alignment and (eq(u8, t, "after-edge") or eq(u8, t, "text-after-edge"))) return .under;
                if (alignment) {
                    if (eq(u8, t, "alphabetic")) return .alphabetic;
                } else if (eq(u8, t, "text-before-edge")) return .over else if (eq(u8, t, "text-after-edge")) return .under;
                if (eq(u8, t, "middle")) return .x_middle;
                if (eq(u8, t, "central")) return .central;
                if (eq(u8, t, "ideographic")) return .under;
                if (eq(u8, t, "hanging")) return .hanging;
                if (eq(u8, t, "mathematical")) return .math;
                return if (alignment) null else .alphabetic;
            }
        };
        const baseline = keyword.of(sg.alignment, true) orelse keyword.of(sg.st.dominant_baseline, false).?;
        const float_ascent = switch (baseline) {
            .alphabetic => ascent,
            .central => height / 2,
            .under => height,
            .x_middle => ascent - x_height / 2,
            .math => ascent * 0.5,
            .hanging => ascent * 0.2,
            .over => 0,
        };
        const shift = sg.span.shift + @as(f32, @floatFromInt(sg.span.supers)) * height / 2;
        return -shift + (ascent - float_ascent);
    }
    const DecorationSpan = struct { seg: usize, face: font.FaceId, size: f32, width: f32, tf: Affine, dx: f32, dy: f32, rotate: f32 };

    fn collectText(l: *Layout, idx: u32, st: *const sstyle.Style, sc: *const Scope, segs: *std.ArrayList(Seg), prev_space: *bool, scopes: *[17]text_position.Scope, flow: u32, depth: u32, span: SpanCtx) Error!void {
        if (depth > 16) return;
        scopes[depth] = text_position.Scope.init(l.node(idx), st.font_size);
        const alignment = l.node(idx).decl(.alignment_baseline) orelse "";
        var ch = l.node(idx).first_child;
        while (ch != NONE) : (ch = l.node(ch).next_sibling) {
            const c = l.node(ch);
            if (c.tag == .textnode) {
                var seg: Seg = .{ .st = st.*, .flow = flow, .span = span, .alignment = alignment };
                var at: usize = 0;
                while (at < c.text.len) {
                    const b = c.text[at];
                    const char_len: usize = std.unicode.utf8ByteSequenceLength(b) catch 1;
                    const end = @min(at + char_len, c.text.len);
                    const bytes = c.text[at..end];
                    at = end;
                    if (b == '\n' or b == '\r') continue;
                    const ch2: u8 = if (b == '\t') ' ' else b;
                    if (ch2 == ' ') {
                        if (prev_space.*) continue;
                        prev_space.* = true;
                    } else prev_space.* = false;
                    var pos = text_position.next(scopes[0 .. depth + 1], sc.vb[2], sc.vb[3]);
                    // An absolute character position starts a separately anchored text chunk.
                    if ((pos.x != null or pos.y != null) and seg.text.items.len > 0) {
                        try segs.append(l.a, seg);
                        seg = .{ .st = st.*, .flow = flow, .span = span, .alignment = alignment };
                    }
                    pos.byte = @intCast(seg.text.items.len);
                    try seg.positions.append(l.a, pos);
                    if (char_len == 1) try seg.text.append(l.a, ch2) else try seg.text.appendSlice(l.a, bytes);
                }
                if (seg.text.items.len > 0) {
                    try segs.append(l.a, seg);
                }
            } else if (c.tag == .tspan or c.tag == .a or (c.tag == .textPath and depth == 0)) {
                if (!display(c)) continue;
                const cst = l.styleOf(c, st);
                try l.collectText(ch, &cst, sc, segs, prev_space, scopes, if (c.tag == .textPath) ch else flow, depth + 1, span.enter(c, cst.font_size, sc.in_clip));
            }
        }
    }

    /// A `text` element's glyph outlines, one shape per span of characters, in chunks that start
    /// at an absolute position and are aligned by `text-anchor` (takumi `convert_text`, with
    /// per-character position lists inherited through tspans. The font engine keeps the source
    /// clusters; outline transforms apply positioning and rotation after shaping.
    fn text(l: *Layout, idx: u32, st: *const sstyle.Style, sc: *const Scope, out: *Group) Error!void {
        const fonts = l.fonts orelse return;
        const n = l.node(idx);
        var segs: std.ArrayList(Seg) = .empty;
        var prev_space = true;
        var scopes: [17]text_position.Scope = undefined;
        try l.collectText(idx, st, sc, &segs, &prev_space, &scopes, NONE, 0, .{});
        // strip the trailing space
        while (segs.items.len > 0) {
            const last = &segs.items[segs.items.len - 1];
            if (last.text.items.len > 0 and last.text.items[last.text.items.len - 1] == ' ') last.text.items.len -= 1;
            if (last.text.items.len > 0) break;
            _ = segs.pop();
        }
        if (segs.items.len == 0) return;
        var pen_x: f32 = 0;
        var pen_y: f32 = 0;
        var i: usize = 0;
        while (i < segs.items.len) {
            // a chunk: from a segment with an absolute position to the next one
            var j = i + 1;
            while (j < segs.items.len) : (j += 1) {
                const pos = segs.items[j].positions.items[0];
                if (pos.x != null or pos.y != null or segs.items[j].flow != segs.items[i].flow) break;
            }
            const chunk = segs.items[i..j];
            const flow = if (chunk[0].flow != NONE) (try l.textFlow(chunk[0].flow, st, sc)) orelse {
                i = j;
                continue;
            } else null;
            if (flow != null and (i == 0 or segs.items[i - 1].flow != chunk[0].flow)) {
                pen_x = 0;
                pen_y = 0;
            }
            if (chunk[0].positions.items[0].x) |v| pen_x = v;
            if (chunk[0].positions.items[0].y) |v| pen_y = v;
            const runs = try l.a.alloc(font.Run, chunk.len);
            const fams = try l.a.alloc([8][]const u8, chunk.len);
            for (chunk, 0..) |*sg, k| {
                var nf: usize = 0;
                var it = std.mem.splitScalar(u8, sg.st.font_family, ',');
                while (it.next()) |raw| {
                    const t = std.mem.trim(u8, raw, " \t\r\n'\"");
                    if (t.len == 0 or nf == 8) continue;
                    fams[k][nf] = t;
                    nf += 1;
                }
                // Spans of one font shape as one run, so kerning joins characters across a span
                // boundary; positioned characters keep their ligatures (takumi `TextChunk::shape`).
                runs[k] = .{ .text = sg.text.items, .style = .{
                    .families = fams[k][0..nf],
                    .weight = weightOf(sg.st.font_weight),
                    .italic = italicOf(sg.st.font_style),
                    .stretch = stretchOf(sg.st.font_stretch),
                    .caps = if (std.mem.eql(u8, num.trim(sg.st.font_variant), "small-caps")) .small else .normal,
                    .size = sg.st.font_size,
                    .user = @intCast(k),
                    .letter_spacing = sg.st.letter_spacing,
                    .word_spacing = sg.st.word_spacing,
                } };
            }
            const tl = font.layoutText(l.a, fonts, runs, .{ .white_space = .pre, .item_origin = true }) catch return;
            if (tl.lines.len == 0) {
                i = j;
                continue;
            }
            const line = tl.lines[0];
            // Source byte clusters index the accumulated per-character offsets, including
            // UTF-8 text. Position list indices count scalar characters rather than bytes.
            var bytes: usize = 0;
            for (chunk) |sg| bytes += sg.text.items.len;
            const off = try l.a.alloc(text_position.Position, bytes);
            var acc: [2]f32 = .{ 0, 0 };
            var byte_base: usize = 0;
            for (chunk) |sg| {
                for (sg.positions.items, 0..) |p, pi| {
                    if (p.byte >= sg.text.items.len) break;
                    acc[0] += p.dx;
                    acc[1] += p.dy;
                    var resolved = p;
                    resolved.dx = acc[0];
                    resolved.dy = acc[1];
                    const end = if (pi + 1 < sg.positions.items.len) @min(sg.positions.items[pi + 1].byte, sg.text.items.len) else sg.text.items.len;
                    @memset(off[byte_base + p.byte .. byte_base + end], resolved);
                }
                byte_base += sg.text.items.len;
            }
            var shift: f32 = 0;
            const anchor = num.trim(chunk[0].st.text_anchor);
            // The anchor aligns the advances of the chunk's clusters, without their `dx`
            // (takumi `clusters_length`).
            const width = line.width;
            if (std.mem.eql(u8, anchor, "middle")) shift = -width / 2 else if (std.mem.eql(u8, anchor, "end")) shift = -width;
            // each span's baseline shift, from the primary face of its first glyph
            const baseline = try l.a.alloc(?f32, chunk.len);
            @memset(baseline, null);
            const paths = try l.a.alloc(Path, chunk.len);
            for (paths) |*p| p.* = .{};
            var decoration_spans: std.ArrayList(DecorationSpan) = .empty;
            var next_pen: ?[2]f32 = null;
            const glyphs = tl.glyphs[line.glyph_start..line.glyph_end];
            var cluster_start: usize = 0;
            var cluster_end: usize = 0;
            var cluster_tf: ?Affine = null;
            var cluster_advance: f32 = 0;
            for (glyphs, 0..) |g, gi| {
                const k: usize = @min(g.user, chunk.len - 1);
                const face = fonts.face(g.face);
                const s = g.size / @as(f32, @floatFromInt(face.font.units_per_em));
                const pos = off[@min(g.cluster, off.len - 1)];
                const bs = baseline[k] orelse blk: {
                    const v = baselineShift(&face.font, chunk[k].st.font_size, &chunk[k]);
                    baseline[k] = v;
                    break :blk v;
                };
                if (gi >= cluster_end) {
                    cluster_start = gi;
                    cluster_end = gi + 1;
                    while (cluster_end < glyphs.len and glyphs[cluster_end].cluster == g.cluster) cluster_end += 1;
                    const end_x = if (cluster_end < glyphs.len) glyphs[cluster_end].x else line.width;
                    cluster_advance = @max(0, end_x - g.x);
                }
                // A rotated cluster turns around its own origin, carrying the offsets of its later
                // glyphs (marks, decomposed parts) with it (takumi `cluster.transform`).
                // (the pen before the cluster: its first glyph's own offset turns with it)
                const pen_before = if (cluster_start > 0) glyphs[cluster_start - 1].x_end else line.x;
                const cluster_x = if (std.math.isFinite(pen_before)) pen_before else glyphs[cluster_start].x;
                var tf = Affine.translate(pen_x + shift + cluster_x + pos.dx, pen_y + pos.dy + bs)
                    .mul(Affine.rotate(pos.rotate * (std.math.pi / 180.0)))
                    .mul(Affine.translate(g.x - cluster_x, g.y - line.baseline)).mul(Affine.scale(s, -s));
                if (flow) |along| {
                    if (gi == cluster_start) {
                        const advance = cluster_advance;
                        const half = advance / 2;
                        if (along.path.sampleSvg(pen_x + shift + along.offset + g.x + pos.dx + half)) |sample| {
                            cluster_tf = Affine.translate(sample.x, sample.y).mul(Affine.rotate(sample.angle)).mul(Affine.translate(-half, pos.dy + bs)).mul(Affine.rotate(pos.rotate * (std.math.pi / 180.0)));
                            next_pen = .{ sample.x + advance, sample.y };
                        } else cluster_tf = null;
                    }
                    const placed = cluster_tf orelse continue;
                    tf = placed.mul(Affine.translate(g.x - glyphs[cluster_start].x, g.y - line.baseline)).mul(Affine.scale(s, -s));
                }
                if (gi == cluster_start and s > 0) {
                    const count = decoration_spans.items.len;
                    if (count > 0 and flow == null and decoration_spans.items[count - 1].seg == k and decoration_spans.items[count - 1].face == g.face and decoration_spans.items[count - 1].size == g.size and
                        decoration_spans.items[count - 1].dx == pos.dx and decoration_spans.items[count - 1].dy == pos.dy and decoration_spans.items[count - 1].rotate == 0 and pos.rotate == 0)
                    {
                        decoration_spans.items[count - 1].width += cluster_advance;
                    } else try decoration_spans.append(l.a, .{ .seg = k, .face = g.face, .size = g.size, .width = cluster_advance, .tf = tf.mul(Affine.scale(1 / s, -1 / s)), .dx = pos.dx, .dy = pos.dy, .rotate = pos.rotate });
                }
                var gp: Path = .{};
                var raw: Path = .empty;
                var sink: raster.PathSink = .{ .path = &raw, .alloc = l.a };
                _ = face.font.outlineResolved(g.gid, g.size, &sink);
                if (sink.err) return error.OutOfMemory;
                // synthetic oblique of a face that is not italic (the shear of text runs,
                // emit_text.zig `synthetic_italic`, in the outline's y-up units)
                const oblique = runs[k].style.italic and !face.italic;
                try gp.addPath(l.a, &raw, if (oblique) tf.mul(.{ .c = 0.25 }) else tf);
                try paths[k].addPath(l.a, &gp, .identity);
            }
            var bounds: ?Rect = null;
            for (paths) |*p| if (pathdata.tightBounds(p)) |b| {
                bounds = if (bounds) |x| unite(x, b) else b;
            };
            const decorations = try l.a.alloc([3]Path, chunk.len);
            for (decorations) |*p| p.* = @splat(.empty);
            for (decoration_spans.items) |span| {
                const metrics = fonts.face(span.face).font.lineMetrics();
                const upem: f32 = @floatFromInt(fonts.face(span.face).font.units_per_em);
                const ascent = @round(@as(f32, @floatFromInt(metrics.ascent)) * span.size / upem);
                const thickness = @max(1, span.size / 10);
                const centers = [3]f32{ -ascent - @floor(thickness) + thickness / 2, @max(1, @ceil(thickness / 2)) + thickness / 2, -ascent / 3 };
                for (chunk[span.seg].st.decorations, 0..) |paint, d| if (paint != null and span.width > 0) {
                    var box: Path = .empty;
                    try box.addRect(l.a, .{ .x = 0, .y = centers[d] - thickness / 2, .w = span.width, .h = thickness });
                    try decorations[span.seg][d].addPath(l.a, &box, span.tf);
                    if (pathdata.tightBounds(&decorations[span.seg][d])) |b| bounds = if (bounds) |x| unite(x, b) else b;
                };
            }
            for (chunk, paths, decorations) |*sg, *glyph_path, *lines| {
                if (!sg.st.visible or sg.span.opacity <= 0) continue;
                const b = bounds orelse continue;
                // A span under a translucent `tspan` / `textPath` / `a` paints its decorations and
                // glyphs as one group with that opacity (takumi `TextPainter::paint_span`).
                const target = if (sg.span.opacity < 1) blk: {
                    const g = try l.newGroup(out.abs);
                    g.opacity = sg.span.opacity;
                    break :blk g;
                } else out;
                for (0..4) |part| {
                    var text_style = sg.st;
                    const p = if (part == 2) glyph_path else &lines[if (part == 3) 2 else part];
                    if (p.isEmpty()) continue;
                    if (part != 2) {
                        const paint = sg.st.decorations[if (part == 3) 2 else part] orelse continue;
                        text_style.fill = paint.fill;
                        text_style.stroke = paint.stroke;
                        text_style.color = paint.color;
                        text_style.fill_opacity = paint.fill_opacity;
                        text_style.stroke_opacity = paint.stroke_opacity;
                        text_style.stroke_width = paint.stroke_width;
                    }
                    const has_bbox = b.w > 0 and b.h > 0;
                    var fill = try l.resolveFill(&text_style, sc, has_bbox);
                    var stroke = try l.resolveStroke(n, &text_style, sc, has_bbox);
                    if (fill) |*f| if (f.paint.bboxUnits()) {
                        if (try l.inUserUnits(f.paint, b)) |pp| f.paint = pp else fill = null;
                    };
                    if (stroke) |*s2| if (s2.paint.bboxUnits()) {
                        if (try l.inUserUnits(s2.paint, b)) |pp| s2.paint = pp else stroke = null;
                    };
                    if (fill == null and stroke == null) continue;
                    const sh = try l.a.create(Shape);
                    sh.* = .{ .path = p.*, .bounds = b, .visible = true, .fill = fill, .stroke = stroke, .stroke_first = (sg.st.paint_order & 3) == 1 };
                    try target.kids.append(l.a, .{ .shape = sh });
                }
                if (target != out and target.kids.items.len > 0) {
                    target.finish();
                    try out.kids.append(l.a, .{ .group = target });
                }
            }
            if (next_pen) |p| {
                pen_x = p[0];
                pen_y = p[1];
            } else {
                pen_x += shift + width + acc[0];
                pen_y += acc[1];
            }
            i = j;
        }
    }

    const TextFlow = struct { path: *const path_measure.Measure, offset: f32 };
    fn textFlow(l: *Layout, id: u32, st: *const sstyle.Style, sc: *const Scope) Error!?TextFlow {
        const n = l.node(id);
        const href = num.trim(n.attr("href") orelse return null);
        if (href.len < 2 or href[0] != '#') return null;
        const target = l.doc.byId(href[1..]) orelse return null;
        var hash = std.hash.Wyhash.init(target);
        hash.update(std.mem.asBytes(&sc.vb));
        hash.update(std.mem.asBytes(&st.font_size));
        const key = hash.final();
        const measured: ?*const path_measure.Measure = if (l.text_paths.get(key)) |cached| cached else blk: {
            const target_node = l.node(target);
            const outline = (try l.shapePath(target_node, sc, st.font_size, null)) orelse {
                try l.text_paths.put(l.a, key, null);
                return null;
            };
            var transformed: Path = .empty;
            try transformed.addPath(l.a, &outline, transformOf(target_node));
            const measure = try l.a.create(path_measure.Measure);
            measure.* = .{ .svg_lines = true };
            const valid = try measure.build(l.a, &transformed);
            const result: ?*const path_measure.Measure = if (valid) measure else null;
            try l.text_paths.put(l.a, key, result);
            break :blk result;
        };
        const measure = measured orelse return null;
        const offset = num.parseLength(n.attr("startOffset") orelse "0") orelse num.Length.px(0);
        return .{ .path = measure, .offset = num.resolve(offset, @floatCast(measure.length), st.font_size) };
    }

    fn italicOf(v: []const u8) bool {
        const t = num.trim(v);
        return std.mem.eql(u8, t, "italic") or std.mem.startsWith(u8, t, "oblique");
    }

    /// `font-stretch` in percent (keywords as CSS Fonts 4 maps them).
    fn stretchOf(v: []const u8) f32 {
        const t = num.trim(v);
        const keywords = [_]struct { []const u8, f32 }{
            .{ "ultra-condensed", 50 },  .{ "extra-condensed", 62.5 }, .{ "condensed", 75 },
            .{ "semi-condensed", 87.5 }, .{ "normal", 100 },           .{ "semi-expanded", 112.5 },
            .{ "expanded", 125 },        .{ "extra-expanded", 150 },   .{ "ultra-expanded", 200 },
        };
        for (keywords) |kw| if (std.mem.eql(u8, t, kw[0])) return kw[1];
        if (std.mem.endsWith(u8, t, "%")) if (num.parseNumber(t[0 .. t.len - 1])) |p| if (p > 0) return p;
        return 100;
    }

    fn weightOf(v: []const u8) u16 {
        const t = num.trim(v);
        if (std.mem.eql(u8, t, "bold") or std.mem.eql(u8, t, "bolder")) return 700;
        if (std.mem.eql(u8, t, "lighter")) return 300;
        const w = std.fmt.parseInt(u16, t, 10) catch return 400;
        return if (w >= 1 and w <= 1000) w else 400;
    }

    // ---- images (image.rs) ---------------------------------------------------------------------

    fn image(l: *Layout, idx: u32, st: *const sstyle.Style, sc: *const Scope, out: *Group) Error!void {
        const n = l.node(idx);
        const href = num.trim(n.attr("href") orelse return);
        if (!std.mem.startsWith(u8, href, "data:")) return;
        const bytes = render.decodeDataUri(l.a, href) orelse return;
        const comma = std.mem.indexOfScalar(u8, href, ',') orelse return;
        var mime = href[5..comma];
        if (std.mem.indexOfScalar(u8, mime, ';')) |k| mime = mime[0..k];
        const Kind = enum { bitmap, gif, svg };
        const kind: Kind = if (std.mem.eql(u8, mime, "image/jpg") or std.mem.eql(u8, mime, "image/jpeg") or std.mem.eql(u8, mime, "image/png") or std.mem.eql(u8, mime, "image/webp"))
            .bitmap
        else if (std.mem.eql(u8, mime, "image/gif"))
            .gif
        else if (std.mem.eql(u8, mime, "image/svg+xml"))
            .svg
        else if (std.mem.eql(u8, mime, "text/plain")) switch (codec.sniff(bytes)) {
            .gif => .gif,
            .unknown, .bmp => .svg,
            else => .bitmap,
        } else return;
        var natural: [2]f32 = undefined;
        var sub: ?dom.Document = null;
        switch (kind) {
            .gif => return, // (takumi-pdf's takumi-core decodes no GIF)
            .bitmap => {
                const d = switch (codec.sniff(bytes)) {
                    .png, .jpeg, .webp => codec.dimensions(bytes) orelse return,
                    else => return,
                };
                if (d.w == 0 or d.h == 0) return;
                natural = .{ @floatFromInt(d.w), @floatFromInt(d.h) };
            },
            .svg => {
                if (l.image_depth >= 8) return;
                const doc = render_svg.parseDoc(true, l.a, bytes) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return,
                };
                if (doc.nodes.len == 0 or doc.nodes[0].tag != .svg) return;
                const isz = render_svg.intrinsic(doc.root());
                const iw = isz.width orelse if (isz.view_box) |vb| vb[2] else 100;
                const ih = isz.height orelse if (isz.view_box) |vb| vb[3] else 100;
                if (!(iw > 0) or !(ih > 0)) return;
                natural = .{ iw, ih };
                sub = doc;
            },
        }
        const fs = st.font_size;
        const x = l.len(n, "x", .x, 0, sc, fs);
        const y = l.len(n, "y", .y, 0, sc, fs);
        const ws = n.attr("width") != null and !std.mem.eql(u8, num.trim(n.attr("width").?), "auto");
        const hs = n.attr("height") != null and !std.mem.eql(u8, num.trim(n.attr("height").?), "auto");
        var w = if (ws) l.len(n, "width", .x, natural[0], sc, fs) else natural[0];
        var h = if (hs) l.len(n, "height", .y, natural[1], sc, fs) else natural[1];
        if (ws and !hs) h = natural[1] * (w / natural[0]);
        if (hs and !ws) w = natural[0] * (h / natural[1]);
        if (!(w > 0) or !(h > 0)) return;
        const par = num.parseAspectRatio(n.attr("preserveAspectRatio"));
        const rect: Rect = .{ .x = x, .y = y, .w = w, .h = h };
        const pic = try l.a.create(Picture);
        var size = natural;
        if (sub) |*doc| {
            // `picture_content`: the nested document laid out at its container size
            const container: [2]f32 = if (par.x == .none) natural else .{ w, h };
            var nl: Layout = .{ .a = l.a, .doc = doc, .current = st.color, .image_host = true, .image_depth = l.image_depth + 1, .fonts = l.fonts };
            const root = try nl.layoutRoot(container[0], container[1]);
            pic.* = .{ .content = .{ .svg = .{ .root = root, .w = container[0], .h = container[1] } }, .w = container[0], .h = container[1], .visible = st.visible };
            size = container;
        } else pic.* = .{ .content = .{ .bitmap = bytes }, .w = natural[0], .h = natural[1], .visible = st.visible };
        // `fit_image`
        var aw = w;
        var ah = h;
        if (par.x != .none) {
            const sx = w / size[0];
            const sy = h / size[1];
            const k = if (par.slice) @max(sx, sy) else @min(sx, sy);
            aw = size[0] * k;
            ah = size[1] * k;
        }
        var ax = x;
        var ay = y;
        switch (par.x) {
            .mid => ax += (w - aw) / 2,
            .max => ax += w - aw,
            else => {},
        }
        switch (par.y) {
            .mid => ay += (h - ah) / 2,
            .max => ay += h - ah,
            else => {},
        }
        if (par.x == .none) {
            ax = x;
            ay = y;
        }
        if (!(aw > 0) or !(ah > 0)) return;
        const it: Affine = .{ .a = aw / size[0], .d = ah / size[1], .e = ax, .f = ay };
        const g = try l.newGroup(out.abs.mul(it));
        g.tf = it;
        try g.kids.append(l.a, .{ .picture = pic });
        g.finish();
        if (par.slice) {
            const cropped = try l.newGroup(out.abs);
            cropped.clip = try l.rectClip(rect);
            try cropped.kids.append(l.a, .{ .group = g });
            cropped.finish();
            try out.kids.append(l.a, .{ .group = cropped });
        } else try out.kids.append(l.a, .{ .group = g });
    }
};

fn refOf(v: ?[]const u8) ?[]const u8 {
    const s = num.trim(v orelse return null);
    if (!std.mem.startsWith(u8, s, "url(")) return null;
    return s;
}

fn isIdentity(t: Affine) bool {
    return t.a == 1 and t.b == 0 and t.c == 0 and t.d == 1 and t.e == 0 and t.f == 0;
}

fn unitSquare(b: Rect) Affine {
    return .{ .a = b.w, .d = b.h, .e = b.x, .f = b.y };
}

fn rmsScale(t: Affine) f32 {
    return @sqrt((t.a * t.a + t.b * t.b + t.c * t.c + t.d * t.d) / 2);
}

fn resolveLen(v: num.Length, axis: num.Axis, sc: *const Scope, fs: f32) f32 {
    const ref = switch (axis) {
        .x => sc.vb[2],
        .y => sc.vb[3],
        .other => sc.diag(),
    };
    return num.resolve(v, ref, fs);
}

fn blendOf(v: []const u8) sf.Blend {
    const names = [_]struct { []const u8, sf.Blend }{
        .{ "multiply", .multiply },     .{ "screen", .screen },         .{ "overlay", .overlay },
        .{ "darken", .darken },         .{ "lighten", .lighten },       .{ "color-dodge", .color_dodge },
        .{ "color-burn", .color_burn }, .{ "hard-light", .hard_light }, .{ "soft-light", .soft_light },
        .{ "difference", .difference }, .{ "exclusion", .exclusion },   .{ "hue", .hue },
        .{ "saturation", .saturation }, .{ "color", .color },           .{ "luminosity", .luminosity },
    };
    for (names) |e| if (std.mem.eql(u8, v, e[0])) return e[1];
    return .normal;
}

/// A colour the CSS parser reads (oklch(), lab(), ... which bm-render's SVG parser does not).
fn cssColor(v: []const u8) ?raster.Color {
    const parsed = cssc.parse(v) catch return null;
    return switch (parsed) {
        .rgba => |c| .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a },
        .current => null,
    };
}

// ---------------------------------------------------------------------------------------------
// Painter (takumi-core `painter.rs` + takumi-pdf `svg.rs`)
// ---------------------------------------------------------------------------------------------

const Painter = struct {
    a: Allocator,
    filter: ?*const dev.ColorFilter,

    fn container(p: *Painter, s: *sf.Surface, g: *const Group) Error!void {
        const depth0 = s.depth();
        if (!isIdentity(g.tf)) s.pushTransform(Tf.fromAffine(g.tf));
        if (g.clip) |c| try p.pushClipPath(s, c);
        if (g.mask) |m| try p.pushMask(s, m);
        if (g.blend != .normal) s.pushBlend(g.blend) else if (g.isolate and g.opacity >= 1) s.pushIsolated();
        if (g.opacity < 1) s.pushOpacity(g.opacity);
        for (g.kids.items) |k| switch (k) {
            .group => |c| try p.container(s, c),
            .shape => |sh| try p.shape(s, sh),
            .picture => |pc| try p.picture(s, pc),
        };
        s.popTo(depth0);
    }

    fn collectRules(g: *const Group, rules: *std.ArrayList(bool), a: Allocator) Error!void {
        for (g.kids.items) |k| switch (k) {
            .shape => |sh| if (sh.fill) |f| try rules.append(a, f.evenodd),
            .group => |c| try collectRules(c, rules, a),
            .picture => {},
        };
    }

    fn simpleClip(g: *const Group) bool {
        for (g.kids.items) |k| switch (k) {
            .group => |c| if (c.clip != null or !simpleClip(c)) return false,
            else => {},
        };
        return true;
    }

    fn clipCommands(g: *const Group, t: Affine, out: *Path, a: Allocator) Error!void {
        for (g.kids.items) |k| switch (k) {
            .shape => |sh| if (sh.visible) try out.addPath(a, &sh.path, t),
            .group => |c| try clipCommands(c, t.mul(c.tf), out, a),
            .picture => {},
        };
    }

    /// takumi `push_clip_path`.
    fn pushClipPath(p: *Painter, s: *sf.Surface, c: *const Clip) Error!void {
        var rules: std.ArrayList(bool) = .empty;
        try collectRules(c.root, &rules, p.a);
        var all_nonzero = true;
        for (rules.items) |r| if (r) {
            all_nonzero = false;
        };
        const simple = simpleClip(c.root) and ((rules.items.len == 1 and rules.items[0]) or all_nonzero);
        if (simple) {
            const evenodd = rules.items.len > 0 and rules.items[0];
            return p.simpleClips(s, c, evenodd);
        }
        const st = try p.complexClipStream(s.cx, c);
        s.pushMask(.{ .stream = st, .kind = .alpha });
    }

    fn simpleClips(p: *Painter, s: *sf.Surface, c: *const Clip, evenodd: bool) Error!void {
        if (c.nested) |n| try p.simpleClips(s, n, evenodd);
        var path: Path = .{};
        try clipCommands(c.root, c.tf, &path, p.a);
        if (path.isEmpty()) {
            // a clip path with only hidden children still hides everything
            try path.moveTo(p.a, 0, 0);
            try path.lineTo(p.a, 0, 0);
        }
        s.pushClip(&path, if (evenodd) .even_odd else .nonzero);
    }

    fn complexClipStream(p: *Painter, cx: *sf.Ctx, c: *const Clip) Error!sf.Stream {
        var ms = sf.Surface.initStream(cx);
        if (c.nested) |n| {
            const st = try p.complexClipStream(cx, n);
            ms.pushMask(.{ .stream = st, .kind = .alpha });
        }
        if (!isIdentity(c.tf)) ms.pushTransform(Tf.fromAffine(c.tf));
        // (the mask's colours stay as drawn: no filter)
        var mp: Painter = .{ .a = p.a, .filter = null };
        try mp.container(&ms, c.root);
        ms.setFill(null);
        ms.setStroke(null);
        ms.popTo(0);
        return ms.finish();
    }

    /// takumi `mask_op`.
    fn pushMask(p: *Painter, s: *sf.Surface, m: *const Mask) Error!void {
        const st = try p.maskStream(s.cx, m);
        s.pushMask(.{ .stream = st, .kind = if (m.luminance) .luminosity else .alpha });
    }

    fn maskStream(p: *Painter, cx: *sf.Ctx, m: *const Mask) Error!sf.Stream {
        var ms = sf.Surface.initStream(cx);
        if (m.nested) |n| {
            const nst = try p.maskStream(cx, n);
            ms.pushMask(.{ .stream = nst, .kind = if (n.luminance) .luminosity else .alpha });
        }
        var r: Path = .{};
        try r.addRect(p.a, m.rect);
        ms.pushClip(&r, .nonzero);
        var mp: Painter = .{ .a = p.a, .filter = null };
        try mp.container(&ms, m.root);
        ms.setFill(null);
        ms.setStroke(null);
        ms.popTo(0);
        return ms.finish();
    }

    fn shape(p: *Painter, s: *sf.Surface, sh: *const Shape) Error!void {
        if (!sh.visible or sh.path.isEmpty()) return;
        const fill: ?sf.Fill = if (sh.fill) |f| blk: {
            const pp = try p.paint(s, f.paint, f.opacity);
            break :blk .{ .paint = pp.paint, .opacity = pp.opacity, .rule = if (f.evenodd) .even_odd else .nonzero };
        } else null;
        const stroke: ?sf.Stroke = if (sh.stroke) |st| blk: {
            const pp = try p.paint(s, st.paint, st.opacity);
            break :blk .{ .paint = pp.paint, .opacity = pp.opacity, .width = st.width, .miter_limit = st.miter, .cap = st.cap, .join = st.join, .dash = st.dash };
        } else null;
        if (fill == null and stroke == null) return;
        if (sh.stroke_first) {
            if (stroke) |st| {
                s.setFill(null);
                s.setStroke(st);
                s.drawPath(&sh.path);
            }
            if (fill) |f| {
                s.setFill(f);
                s.setStroke(null);
                s.drawPath(&sh.path);
            }
            return;
        }
        s.setFill(fill);
        s.setStroke(stroke);
        s.drawPath(&sh.path);
    }

    const PaintOut = struct { paint: sf.Paint, opacity: f32 };

    /// `color` and `opacity` as the filter leaves them (svg.rs `filtered_color`).
    fn filtered(p: *const Painter, c: [3]u8, opacity: f32) PaintOut {
        const f = p.filter orelse return .{ .paint = .{ .color = c }, .opacity = opacity };
        const o = f.apply(.{ c[0], c[1], c[2], 255 });
        return .{ .paint = .{ .color = .{ o[0], o[1], o[2] } }, .opacity = opacity * @as(f32, @floatFromInt(o[3])) / 255 };
    }

    fn stops(p: *Painter, in: []const sf.Stop) Error![]const sf.Stop {
        const f = p.filter orelse return in;
        const out = try p.a.alloc(sf.Stop, in.len);
        for (in, out) |st, *o| {
            const c = f.apply(.{ st.color[0], st.color[1], st.color[2], 255 });
            o.* = .{ .offset = st.offset, .color = .{ c[0], c[1], c[2] }, .opacity = std.math.clamp(st.opacity * @as(f32, @floatFromInt(c[3])) / 255, 0, 1) };
        }
        return out;
    }

    fn paint(p: *Painter, s: *sf.Surface, v: PaintV, opacity: f32) Error!PaintOut {
        switch (v) {
            .color => |c| return p.filtered(c, opacity),
            .grad => |g| {
                const st = try p.stops(g.stops);
                const tf = Tf.fromAffine(g.tf);
                if (g.linear) return .{ .paint = .{ .linear = .{ .x1 = g.v[0], .y1 = g.v[1], .x2 = g.v[2], .y2 = g.v[3], .transform = tf, .spread = g.spread, .stops = st } }, .opacity = opacity };
                return .{ .paint = .{ .radial = .{ .cx = g.v[0], .cy = g.v[1], .cr = g.v[2], .fx = g.v[3], .fy = g.v[4], .fr = g.v[5], .transform = tf, .spread = g.spread, .stops = st } }, .opacity = opacity };
            },
            .pattern => |pt| {
                var ts = sf.Surface.initStream(s.cx);
                try p.container(&ts, pt.root);
                ts.setFill(null);
                ts.setStroke(null);
                const pat = try p.a.create(sf.Pattern);
                pat.* = .{ .stream = ts.finish(), .transform = Tf.fromAffine(pt.tf.mul(Affine.translate(pt.rect.x, pt.rect.y))), .width = pt.rect.w, .height = pt.rect.h };
                return .{ .paint = .{ .pattern = pat }, .opacity = opacity };
            },
        }
    }

    fn picture(p: *Painter, s: *sf.Surface, pc: *const Picture) Error!void {
        if (!pc.visible) return;
        switch (pc.content) {
            .svg => |d| {
                const depth0 = s.depth();
                var r: Path = .{};
                try r.addRect(p.a, .{ .x = 0, .y = 0, .w = d.w, .h = d.h });
                s.pushClip(&r, .nonzero);
                try p.container(s, d.root);
                s.popTo(depth0);
            },
            .bitmap => |bytes| {
                const ref = p.bitmap(s.cx, bytes) orelse return;
                s.drawImage(ref, pc.w, pc.h);
            },
        }
    }

    /// svg.rs `SvgPainter::image`: the bytes as krilla takes them, unless the filter recolours
    /// them; then decoded (PNG only in takumi-pdf's takumi-core).
    fn bitmap(p: *Painter, cx: *sf.Ctx, bytes: []const u8) ?sf.Ref {
        if (p.filter == null) switch (eimg.draw(cx, bytes, 0, null, null, "")) {
            .ref => |r| return r,
            else => {},
        };
        if (codec.sniff(bytes) != .png) return null;
        const img = codec.decode(p.a, bytes, .{ .max_pixels = render.Renderer.max_image_pixels }) catch return null;
        var i: usize = 0;
        while (i + 4 <= img.data.len) : (i += 4) {
            const al: u16 = img.data[i + 3];
            for (0..3) |k| img.data[i + k] = @intCast((@as(u16, img.data[i + k]) * al + 127) / 255);
        }
        const pm: raster.Pixmap = .{ .width = img.width, .height = img.height, .data = img.data };
        const pf: ?eimg.PixelFilter = if (p.filter) |f| .{ .ctx = f, .apply = struct {
            fn ap(c: *const anyopaque, rgba: [4]u8) [4]u8 {
                const fl: *const dev.ColorFilter = @ptrCast(@alignCast(c));
                return fl.apply(rgba);
            }
        }.ap, .key = f.key() } else null;
        return eimg.regPixmap(cx, &pm, std.hash.Wyhash.hash(7, bytes), pf);
    }
};

test "draws the svg-vector-image fixture as operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = @import("writer.zig");
    var doc = w.Doc.init(a, .{ .compress = false });
    var cx: sf.Ctx = .{ .a = a, .doc = &doc };
    var s = sf.Surface.initPage(&cx, 45);
    const src = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" width=\"24\" height=\"24\">\n  <defs><linearGradient id=\"g\" x1=\"0\" y1=\"0\" x2=\"24\" y2=\"24\" gradientUnits=\"userSpaceOnUse\">\n <stop offset=\"0\" stop-color=\"#ff0044\"/><stop offset=\"1\" stop-color=\"#0044ff\"/>\n </linearGradient></defs>\n <circle cx=\"12\" cy=\"12\" r=\"10\" fill=\"url(#g)\"/>\n <path d=\"M6 12 L11 17 L18 7\" stroke=\"#fff\" stroke-width=\"2.5\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n</svg>";
    try std.testing.expect(try draw(a, &s, src, 0, 8, 22, 22, .{ .current = raster.Color.black }));
    const st = s.finish();
    try std.testing.expect(std.mem.indexOf(u8, st.content, "1 J") != null);
}

test "SVG rank-one transforms reach paint while collapsed rows do not" {
    try std.testing.expect(Layout.renderable(.{ .a = 1, .b = 1, .c = 0, .d = 0 }));
    try std.testing.expect(!Layout.renderable(Affine.scale(0, 0)));
    try std.testing.expect(!Layout.renderable(Affine.scale(1, 0)));
    try std.testing.expect(!Layout.renderable(.{ .a = std.math.inf(f32) }));
}

test "an image's root without a viewBox stretches its width and height over the viewport" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try render_svg.parseDoc(true, a, "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'><rect width='10' height='10'/></svg>");
    var l: Layout = .{ .a = a, .doc = &doc, .current = raster.Color.black, .image_host = true };
    const root = try l.layoutRoot(40, 40);
    const g = root.kids.items[0].group;
    try std.testing.expectEqual(@as(f32, 2), g.tf.a);
    try std.testing.expectEqual(@as(f32, 4), g.tf.d);
}

test "clip paths, masks, use and symbols lay out as containers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try render_svg.parseDoc(true, a, "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 40 40'><defs><clipPath id='c'><circle cx='20' cy='20' r='12'/></clipPath><mask id='m'><rect width='40' height='40' fill='#fff'/></mask><symbol id='s' viewBox='0 0 10 10'><circle cx='5' cy='5' r='5'/></symbol></defs><rect width='40' height='40' clip-path='url(#c)' mask='url(#m)'/><use href='#s' x='5' y='5' width='20' height='20'/></svg>");
    var l: Layout = .{ .a = a, .doc = &doc, .current = raster.Color.black, .image_host = true };
    const root = try l.layoutRoot(40, 40);
    const svg_g = root.kids.items[0].group; // the root `svg` (a `g`-like container is not required)
    _ = svg_g;
    var found_clip = false;
    var found_mask = false;
    const Walk = struct {
        fn f(g: *const Group, c: *bool, m: *bool) void {
            if (g.clip != null) c.* = true;
            if (g.mask != null) m.* = true;
            for (g.kids.items) |k| if (k == .group) f(k.group, c, m);
        }
    };
    Walk.f(root, &found_clip, &found_mask);
    try std.testing.expect(found_clip);
    try std.testing.expect(found_mask);
}
