//! krilla's drawing model (`surface.rs`, `content.rs`, `graphics_state.rs`, `xobject.rs`,
//! `mask.rs`, `paint.rs`) on top of the low-level writer (writer.zig / content.zig), so the
//! emitter produces the operators and objects takumi-pdf produces:
//!
//! * a stack of content builders: the page (or pattern / mask) stream at the bottom, one more
//!   per open opacity group, isolated group and mask; popping one turns it into a transparency
//!   group Form XObject drawn into the builder below (`/gN gs /xN Do`);
//! * a simulated graphics state (CTM + ExtGState) per builder: transforms and blend modes are
//!   never written when pushed, every draw is wrapped `q [cm] [/gN gs] ... Q` with the full
//!   transform (krilla `apply_isolated_op`); clip paths are written pre-transformed into the
//!   stream's coordinates (`q path W n` ... `Q`);
//! * paints: RGB colours (4-decimal components), axial / radial shadings and PostScript
//!   function shadings with soft masks for stop opacities (emit_shading.zig), tiling patterns;
//! * every object is deduplicated by content hash (krilla `register_cacheable`) through
//!   `Doc.cacheGet / cachePut`, and written when it is first registered, children first, so the
//!   writer's category ordering numbers the objects like takumi-pdf.
const std = @import("std");
const w = @import("writer.zig");
const ct = @import("content.zig");
const geom = @import("emit_geom.zig");
const shading = @import("emit_shading.zig");

const Allocator = std.mem.Allocator;
pub const Tf = geom.Tf;
pub const LRect = geom.LRect;
pub const Path = geom.Path;
pub const Ref = w.Ref;
pub const FillRule = ct.FillRule;

/// Document-wide emitter state shared by every surface of one PDF.
pub const Ctx = struct {
    a: Allocator,
    /// The working memory of the page being drawn (`work`), rewound after each page (emit.zig
    /// `writeDocument`); null: `a`.
    page: ?Allocator = null,
    doc: *w.Doc,
    /// PDF/A: colours in the ICC-based sRGB space instead of DeviceRGB (krilla `no_device_cs`)
    no_device_cs: bool = false,
    /// the `[/ICCBased ..]` colour space and the profile stream, once registered (conform.zig)
    icc_rgb: ?Ref = null,
    icc_profile: ?Ref = null,
    /// the PDF version written (profile choice; conform.zig)
    version: w.Version = .v1_7,
    /// a PostScript calculator function was written (krilla `ContainsPostScript`)
    postscript: bool = false,
    /// a page, XObject or tiling pattern content stream nests `q` deeper than 28 (krilla
    /// `TooHighQNestingLevel`, registered where those streams are serialised)
    q_over: bool = false,
    /// scratch for transformed clip paths
    tmp: Path = .empty,

    /// Memory for what lives only while a page is drawn (its surfaces' content and resources, the
    /// walk's queues, paths and runs): nothing in it may outlive the page. A stream written to the
    /// document is encoded into `a` (`w.Doc.encode`).
    pub fn work(cx: *const Ctx) Allocator {
        return cx.page orelse cx.a;
    }
};

/// What a marked-content section is (krilla `ContentTag`: takumi uses `Artifact(Other)`, `Other`
/// and `Span` with a language).
pub const ContentTag = union(enum) {
    artifact,
    other,
    span: []const u8,
};

/// krilla `color::component`: an 8-bit channel as a PDF number with four decimals.
pub fn component(v: u8) f32 {
    return @round(@as(f32, @floatFromInt(v)) / 255.0 * 10_000.0) / 10_000.0;
}

pub const Blend = enum(u8) {
    normal,
    multiply,
    screen,
    overlay,
    darken,
    lighten,
    color_dodge,
    color_burn,
    hard_light,
    soft_light,
    difference,
    exclusion,
    hue,
    saturation,
    color,
    luminosity,

    pub fn pdfName(b: Blend) []const u8 {
        return switch (b) {
            .normal => "Normal",
            .multiply => "Multiply",
            .screen => "Screen",
            .overlay => "Overlay",
            .darken => "Darken",
            .lighten => "Lighten",
            .color_dodge => "ColorDodge",
            .color_burn => "ColorBurn",
            .hard_light => "HardLight",
            .soft_light => "SoftLight",
            .difference => "Difference",
            .exclusion => "Exclusion",
            .hue => "Hue",
            .saturation => "Saturation",
            .color => "Color",
            .luminosity => "Luminosity",
        };
    }
};

pub const Spread = enum(u8) { pad, reflect, repeat };

/// A gradient stop: offset 0..1, RGB colour, opacity 0..1 (krilla `Stop`).
pub const Stop = struct { offset: f32, color: [3]u8, opacity: f32 };

pub const Linear = struct { x1: f32, y1: f32, x2: f32, y2: f32, transform: Tf = .identity, spread: Spread = .pad, stops: []const Stop };
pub const Radial = struct { fx: f32, fy: f32, fr: f32, cx: f32, cy: f32, cr: f32, transform: Tf = .identity, spread: Spread = .pad, stops: []const Stop };
pub const Sweep = struct { cx: f32, cy: f32, start: f32, end: f32, transform: Tf = .identity, spread: Spread = .pad, stops: []const Stop };

/// A content stream drawn by a stream surface (`Surface.initStream` / `finishStream`).
pub const Stream = struct {
    content: []const u8,
    /// bounds of what was drawn ((0, 0, 1, 1) when nothing was)
    bbox: LRect,
    res: w.Resources,
    uses_mask: bool,
    /// string / name lengths and the q nesting fact of the content (conformance limits)
    limits: w.Limits = .{},
};

pub const Pattern = struct { stream: Stream, transform: Tf, width: f32, height: f32 };

pub const Paint = union(enum) {
    color: [3]u8,
    linear: Linear,
    radial: Radial,
    sweep: Sweep,
    pattern: *const Pattern,

    fn hasTranslucentStop(p: Paint) bool {
        const stops: []const Stop = switch (p) {
            .linear => |g| g.stops,
            .radial => |g| g.stops,
            .sweep => |g| g.stops,
            else => return false,
        };
        for (stops) |s| if (s.opacity != 1) return true;
        return false;
    }
};

pub const Fill = struct { paint: Paint, opacity: f32 = 1, rule: FillRule = .nonzero };

pub const LineCap = enum(u8) { butt, round, square };
pub const LineJoin = enum(u8) { miter, round, bevel };
pub const Dash = struct { array: []const f32, offset: f32 = 0 };

pub const Stroke = struct {
    paint: Paint,
    width: f32 = 1,
    miter_limit: f32 = 10,
    cap: LineCap = .butt,
    join: LineJoin = .miter,
    opacity: f32 = 1,
    dash: ?Dash = null,
};

pub const MaskType = enum(u8) { alpha, luminosity };

pub const Mask = struct { stream: Stream, kind: MaskType, custom_bbox: ?LRect = null };

/// krilla ExtGState `Repr`.
pub const Gs = struct {
    ca: ?f32 = null,
    CA: ?f32 = null,
    bm: ?Blend = null,
    smask: ?Ref = null,

    pub fn empty(g: Gs) bool {
        return g.ca == null and g.CA == null and g.bm == null and g.smask == null;
    }

    pub fn combine(g: *Gs, o: Gs) void {
        if (o.CA) |v| g.CA = v;
        if (o.ca) |v| g.ca = v;
        if (o.bm) |v| g.bm = v;
        if (o.smask) |v| g.smask = v;
    }
};

const GState = struct { ext: Gs = .{}, ctm: Tf = .identity };

// ---------------------------------------------------------------------------------------------
// hashing (cache keys)
// ---------------------------------------------------------------------------------------------

pub const Hasher = struct {
    // (XxHash64: 64-bit multiplies only; Wyhash's 128-bit products are emulated on wasm32)
    h: std.hash.XxHash64,

    pub fn init(tag: u8) Hasher {
        return .{ .h = std.hash.XxHash64.init(@as(u64, tag) *% 0x9E37_79B9_7F4A_7C15) };
    }
    pub fn bytes(h: *Hasher, b: []const u8) void {
        h.u64_(b.len);
        h.h.update(b);
    }
    pub fn u64_(h: *Hasher, v: u64) void {
        h.h.update(std.mem.asBytes(&v));
    }
    pub fn f(h: *Hasher, v: f32) void {
        h.u64_(@as(u32, @bitCast(v)));
    }
    pub fn tf(h: *Hasher, t: Tf) void {
        for (t.pdf()) |v| h.f(v);
    }
    pub fn rect(h: *Hasher, r: LRect) void {
        h.f(r.l);
        h.f(r.t);
        h.f(r.r);
        h.f(r.b);
    }
    pub fn stops(h: *Hasher, s: []const Stop) void {
        h.u64_(s.len);
        for (s) |x| {
            h.f(x.offset);
            h.h.update(&x.color);
            h.f(x.opacity);
        }
    }
    pub fn stream(h: *Hasher, s: *const Stream) void {
        h.bytes(s.content);
        h.rect(s.bbox);
        for (s.res.lists) |l| {
            h.u64_(l.items.len);
            for (l.items) |r| h.u64_(r);
        }
        h.u64_(@intFromBool(s.uses_mask));
    }
    pub fn final(h: *Hasher) u64 {
        return h.h.final();
    }
};

// ---------------------------------------------------------------------------------------------
// object registration (krilla Cacheable::serialize)
// ---------------------------------------------------------------------------------------------

pub fn regExtGState(cx: *Ctx, g: Gs) Ref {
    var h = Hasher.init('G');
    inline for (.{ g.ca, g.CA }) |v| {
        h.u64_(@intFromBool(v != null));
        if (v) |x| h.f(x);
    }
    h.u64_(if (g.bm) |b| @as(u64, @intFromEnum(b)) + 1 else 0);
    h.u64_(g.smask orelse 0);
    const key = h.final();
    if (cx.doc.cacheGet(key)) |r| return r;
    const r = cx.doc.alloc();
    cx.doc.extGState(r, .{ .fill_alpha = g.ca, .stroke_alpha = g.CA, .blend_mode = if (g.bm) |b| b.pdfName() else null, .smask = g.smask });
    cx.doc.cachePut(key, r);
    return r;
}

/// krilla `XObject::new` + `serialize`: a transparency group when isolated or when the
/// content uses a soft mask (Preview bug workaround).
pub fn regXObject(cx: *Ctx, s: *const Stream, isolated: bool, tgcs_in: bool, custom_bbox: ?LRect) Ref {
    const tgcs = tgcs_in or s.uses_mask;
    var h = Hasher.init('X');
    h.stream(s);
    h.u64_(@intFromBool(isolated));
    h.u64_(@intFromBool(tgcs));
    if (custom_bbox) |b| h.rect(b) else h.u64_(7);
    const key = h.final();
    if (cx.doc.cacheGet(key)) |r| return r;
    const r = cx.doc.alloc();
    if (s.limits.q_over) cx.q_over = true;
    const res = s.res.write(cx.doc);
    const bbox = custom_bbox orelse s.bbox;
    cx.doc.formXObject(r, s.content, .{
        .resources = res,
        .bbox = bbox.pdf(),
        .group = if (isolated or tgcs) .{ .isolated = isolated } else null,
    });
    cx.doc.cachePut(key, r);
    return r;
}

/// krilla `Mask::serialize`: the mask content as a group XObject, then `/Type/Mask/S/../G`.
pub fn regMask(cx: *Ctx, m: *const Mask) Ref {
    var h = Hasher.init('M');
    h.stream(&m.stream);
    h.u64_(@intFromEnum(m.kind));
    if (m.custom_bbox) |b| h.rect(b) else h.u64_(7);
    const key = h.final();
    if (cx.doc.cacheGet(key)) |r| return r;
    const r = cx.doc.alloc();
    const x = regXObject(cx, &m.stream, false, true, m.custom_bbox);
    cx.doc.softMask(r, if (m.kind == .alpha) "Alpha" else "Luminosity", x, null);
    cx.doc.cachePut(key, r);
    return r;
}

// ---------------------------------------------------------------------------------------------
// content builder (krilla ContentBuilder)
// ---------------------------------------------------------------------------------------------

pub const Builder = struct {
    c: ct.Content,
    res: w.Resources,
    root: Tf,
    states: std.ArrayList(GState) = .empty,
    bbox: ?LRect = null,
    uses_mask: bool = false,
    /// XObject / pattern streams need their bbox; the page does not
    bbox_important: bool,
    /// open marked-content sections (only the outermost is written)
    marked: u32 = 0,

    pub fn init(a: Allocator, root: Tf, important: bool) Builder {
        var b: Builder = .{ .c = ct.Content.init(a), .res = w.Resources.init(a), .root = root, .bbox_important = important };
        b.states.append(a, .{}) catch {
            b.c.b.failed = true;
        };
        return b;
    }

    fn alloc(b: *Builder) Allocator {
        return b.c.b.a;
    }

    pub fn cur(b: *Builder) *GState {
        return &b.states.items[b.states.items.len - 1];
    }

    pub fn ctm(b: *Builder) Tf {
        return b.cur().ctm;
    }

    /// `cur_transform_with_root_transform`
    pub fn ctmRoot(b: *Builder) Tf {
        return b.root.pre(b.ctm());
    }

    pub fn saveGs(b: *Builder) void {
        const s = b.cur().*;
        b.states.append(b.alloc(), s) catch {
            b.c.b.failed = true;
        };
    }

    pub fn restoreGs(b: *Builder) void {
        if (b.states.items.len > 1) b.states.items.len -= 1;
    }

    pub fn concat(b: *Builder, t: Tf) void {
        const s = b.cur();
        s.ctm = s.ctm.pre(t);
    }

    pub fn combine(b: *Builder, g: Gs) void {
        b.cur().ext.combine(g);
    }

    pub fn expandBbox(b: *Builder, r: LRect) void {
        const t = r.transform(b.ctm()) orelse return;
        if (b.bbox) |*x| x.expand(t) else b.bbox = t;
    }

    pub fn finish(b: *Builder) Stream {
        return .{ .content = b.c.bytes(), .bbox = b.bbox orelse LRect{ .l = 0, .t = 0, .r = 1, .b = 1 }, .res = b.res, .uses_mask = b.uses_mask, .limits = b.c.b.limits };
    }

    /// krilla `ContentBuilder::finish`: the stream, its limits registered with the document.
    fn finishIn(b: *Builder, cx: *Ctx) Stream {
        const st = b.finish();
        cx.doc.noteLimits(st.limits);
        return st;
    }

    fn setFillOpacity(b: *Builder, v: f32) void {
        if (v != 1) b.combine(.{ .ca = v });
    }
    fn setStrokeOpacity(b: *Builder, v: f32) void {
        if (v != 1) b.combine(.{ .CA = v });
    }

    // -- apply_isolated_op, split around the caller's prep / op
    pub fn isoBegin(b: *Builder) void {
        b.saveGs();
        b.c.save();
    }
    pub fn isoMid(b: *Builder, cx: *Ctx) void {
        const t = b.ctmRoot();
        if (!t.isIdentity()) b.c.transform(t.pdf());
        const st = b.cur().ext;
        if (!st.empty()) {
            const n = b.res.add(.ext_g_state, regExtGState(cx, st));
            b.c.extGState(n.slice());
        }
    }
    pub fn isoEnd(b: *Builder) void {
        b.c.restore();
        b.restoreGs();
    }

    pub fn drawXObject(b: *Builder, cx: *Ctx, x: Ref, xbbox: LRect, state: Gs) void {
        b.isoBegin();
        b.combine(state);
        b.expandBbox(xbbox);
        b.isoMid(cx);
        const n = b.res.add(.x_object, x);
        b.c.xObject(n.slice());
        b.isoEnd();
    }

    fn drawOpacified(b: *Builder, cx: *Ctx, opacity: f32, s: *const Stream) void {
        const x = regXObject(cx, s, true, false, null);
        b.drawXObject(cx, x, s.bbox, .{ .ca = opacity, .CA = opacity });
    }

    fn drawIsolated(b: *Builder, cx: *Ctx, s: *const Stream) void {
        const x = regXObject(cx, s, true, false, null);
        b.drawXObject(cx, x, s.bbox, .{});
    }

    fn drawMasked(b: *Builder, cx: *Ctx, m: *const Mask, s: *const Stream) void {
        const mr = regMask(cx, m);
        b.uses_mask = true;
        const bbox = s.bbox;
        const x = regXObject(cx, s, false, true, null);
        b.drawXObject(cx, x, bbox, .{ .smask = mr });
    }

    /// An sRGB colour: `r g b rg`, or under PDF/A `/cN cs r g b scn` in the ICC-based space
    /// (krilla `set_fill_color` with `no_device_cs`).
    pub fn setColor(b: *Builder, cx: *Ctx, c: [3]u8, stroke: bool) void {
        const comps = [3]f32{ component(c[0]), component(c[1]), component(c[2]) };
        if (@import("conform.zig").rgbSpace(cx)) |space| {
            const n = b.res.add(.color_space, space);
            if (stroke) {
                b.c.strokeColorSpace(n.slice());
                b.c.strokeColor(&comps);
            } else {
                b.c.fillColorSpace(n.slice());
                b.c.fillColor(&comps);
            }
            return;
        }
        if (stroke) b.c.strokeRgb(comps[0], comps[1], comps[2]) else b.c.fillRgb(comps[0], comps[1], comps[2]);
    }

    /// Sets the fill (`stroke` false) or stroke colour / pattern for `paint` over a shape of
    /// `bounds` (krilla `content_set_fill_stroke_properties`).
    pub fn setPaint(b: *Builder, cx: *Ctx, bounds: LRect, paint: Paint, opacity: f32, stroke: bool) void {
        switch (paint) {
            .color => |c| b.setColor(cx, c, stroke),
            .linear, .radial, .sweep => {
                const gp = shading.properties(cx.a, paint, bounds) catch {
                    b.c.b.failed = true;
                    return;
                };
                if (gp.props.singleStop()) |st| {
                    // one stop: a solid colour (its opacity lands in the simulated state only,
                    // after the state was written, exactly like krilla)
                    b.setFillOpacity(st.opacity);
                    b.setColor(cx, st.color, stroke);
                    return;
                }
                const mask = shading.maskFromShading(cx, gp.props, gp.transform, bounds);
                const pat = shading.regShadingPattern(cx, gp.props, b.ctmRoot().pre(gp.transform));
                const pn = b.res.add(.pattern, pat);
                if (mask) |m| {
                    const mr = regMask(cx, &m);
                    b.uses_mask = true;
                    const n = b.res.add(.ext_g_state, regExtGState(cx, .{ .smask = mr }));
                    b.c.extGState(n.slice());
                }
                if (stroke) {
                    b.c.strokeColorSpace("Pattern");
                    b.c.strokePattern(pn.slice());
                } else {
                    b.c.fillColorSpace("Pattern");
                    b.c.fillPattern(pn.slice());
                }
            },
            .pattern => |p| {
                const t = p.transform.post(b.ctmRoot());
                const r = shading.regTilingPattern(cx, &p.stream, t, opacity, p.width, p.height);
                const pn = b.res.add(.pattern, r);
                if (stroke) {
                    b.c.strokeColorSpace("Pattern");
                    b.c.strokePattern(pn.slice());
                } else {
                    b.c.fillColorSpace("Pattern");
                    b.c.fillPattern(pn.slice());
                }
            },
        }
    }

    pub fn setStrokeProps(b: *Builder, cx: *Ctx, bounds: LRect, s: *const Stroke) void {
        b.setPaint(cx, bounds, s.paint, s.opacity, true);
        if (s.width != 1) b.c.lineWidth(s.width);
        if (s.miter_limit != 10) b.c.miterLimit(s.miter_limit);
        if (s.cap != .butt) b.c.lineCap(@intFromEnum(s.cap));
        if (s.join != .miter) b.c.lineJoin(@intFromEnum(s.join));
        if (s.dash) |d| b.c.dash(d.array, d.offset);
    }

    /// krilla `ContentBuilder::draw_path`.
    pub fn drawPath(b: *Builder, cx: *Ctx, path: *const Path, fill_in: ?*const Fill, stroke: ?*const Stroke) void {
        var fill = fill_in;
        if (fill == null and stroke == null) return;
        const pb = geom.bounds(path) orelse return;
        if (pb.width() == 0 and pb.height() == 0) return;
        const verbs = path.verbs.items;
        const is_line = verbs.len == 2 and verbs[0] == .move and verbs[1] == .line;
        if (pb.width() == 0 or pb.height() == 0 or is_line) {
            if (stroke == null) return;
            fill = null;
        }
        var sbox = pb;
        if (stroke) |s| {
            // krilla strokes the path to measure it (`calculate_stroke_bbox`: the tight bounds
            // of the stroke outline): the half width around the path's tight bounds (curve
            // extrema, not control points), exact for round joins and for the boxes this
            // emitter strokes
            if (b.bbox_important or s.paint != .color) {
                const hw = s.width / 2;
                const tb = tightBounds(path) orelse pb;
                sbox = LRect.ltrb(tb.l - hw, tb.t - hw, tb.r + hw, tb.b + hw) orelse pb;
                // a single segment with butt caps reaches the half width across it only (a
                // dashed outline edge: takumi strokes each one on its own)
                if (is_line and s.cap == .butt) {
                    const p0 = path.points.items[0];
                    const p1 = path.points.items[1];
                    const len = @sqrt((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y));
                    if (len > 0) {
                        const nx = -(p1.y - p0.y) / len * hw;
                        const ny = (p1.x - p0.x) / len * hw;
                        sbox = LRect.ltrb(
                            @min(@min(p0.x - nx, p0.x + nx), @min(p1.x - nx, p1.x + nx)),
                            @min(@min(p0.y - ny, p0.y + ny), @min(p1.y - ny, p1.y + ny)),
                            @max(@max(p0.x - nx, p0.x + nx), @max(p1.x - nx, p1.x + nx)),
                            @max(@max(p0.y - ny, p0.y + ny), @max(p1.y - ny, p1.y + ny)),
                        ) orelse sbox;
                    }
                }
            }
        }
        b.isoBegin();
        if (fill) |f| {
            b.expandBbox(pb);
            if (f.paint != .pattern) b.setFillOpacity(f.opacity);
        }
        if (stroke) |s| {
            b.expandBbox(sbox);
            if (s.paint != .pattern) b.setStrokeOpacity(s.opacity);
        }
        b.isoMid(cx);
        if (fill) |f| b.setPaint(cx, pb, f.paint, f.opacity, false);
        if (stroke) |s| b.setStrokeProps(cx, sbox, s);
        geom.writePath(&b.c, path);
        if (fill) |f| {
            if (stroke != null) b.c.fillStroke(f.rule) else b.c.fill(f.rule);
        } else b.c.stroke();
        b.isoEnd();
    }

    /// krilla `push_clip_path`: the path in the stream's coordinates.
    pub fn pushClip(b: *Builder, cx: *Ctx, path: *const Path, rule: FillRule) void {
        b.c.save();
        geom.transformed(cx.a, path, b.ctmRoot(), &cx.tmp) catch {
            b.c.b.failed = true;
            return;
        };
        geom.writePath(&b.c, &cx.tmp);
        b.c.clip(rule);
        b.c.endPath();
    }

    /// krilla `draw_image`: the unit square image scaled to `width` x `height` at the origin.
    pub fn drawImage(b: *Builder, cx: *Ctx, img: Ref, width: f32, height: f32) void {
        b.isoBegin();
        b.concat(Tf.row(width, 0, 0, -height, 0, height));
        b.expandBbox(.{ .l = 0, .t = 0, .r = 1, .b = 1 });
        b.isoMid(cx);
        const n = b.res.add(.x_object, img);
        b.c.xObject(n.slice());
        b.isoEnd();
    }

    /// krilla `draw_shading`.
    pub fn drawShading(b: *Builder, cx: *Ctx, sh: Ref) void {
        b.isoBegin();
        b.isoMid(cx);
        const n = b.res.add(.shading, sh);
        b.c.shading(n.slice());
        b.isoEnd();
    }
};

// ---------------------------------------------------------------------------------------------
// surface (krilla Surface)
// ---------------------------------------------------------------------------------------------

const Push = union(enum) {
    transform,
    opacity: f32,
    clip,
    blend,
    mask: Mask,
    isolated,
};

pub const Surface = struct {
    cx: *Ctx,
    fill: ?Fill = null,
    stroke: ?Stroke = null,
    builders: std.ArrayList(Builder) = .empty,
    pushes: std.ArrayList(Push) = .empty,
    /// a page surface of a tagged document (krilla's `page_identifier`): marked content is written
    tagging: bool = false,
    /// the page's next marked-content id
    mcid: i32 = 0,

    /// A page surface: root transform `1 0 0 -1 0 height` (pt).
    pub fn initPage(cx: *Ctx, height_pt: f32) Surface {
        return init(cx, Tf.row(1, 0, 0, -1, 0, height_pt), false);
    }

    /// A stream surface (pattern tile, mask content): identity root, bbox tracked.
    pub fn initStream(cx: *Ctx) Surface {
        return init(cx, .identity, true);
    }

    fn init(cx: *Ctx, root: Tf, important: bool) Surface {
        var s: Surface = .{ .cx = cx };
        s.builders.append(cx.work(), Builder.init(cx.work(), root, important)) catch {
            cx.doc.b.failed = true;
        };
        return s;
    }

    pub fn bd(s: *Surface) *Builder {
        return &s.builders.items[s.builders.items.len - 1];
    }

    pub fn failed(s: *const Surface) bool {
        for (s.builders.items) |b| if (b.c.failed() or b.res.failed) return true;
        return false;
    }

    /// The finished root stream (pair of `initStream` / `initPage`).
    pub fn finish(s: *Surface) Stream {
        while (s.pushes.items.len > 0) s.pop();
        if (s.failed()) s.cx.doc.b.failed = true;
        return s.builders.items[0].finishIn(s.cx);
    }

    pub fn setFill(s: *Surface, f: ?Fill) void {
        s.fill = f;
    }

    pub fn setStroke(s: *Surface, st: ?Stroke) void {
        s.stroke = st;
    }

    fn complex(s: *const Surface) bool {
        if (s.stroke) |st| if (st.opacity != 1 or st.paint.hasTranslucentStop()) return true;
        if (s.fill) |f| if (f.paint.hasTranslucentStop()) return true;
        return false;
    }

    /// Draws `path` with the current fill and / or stroke (krilla `Surface::draw_path`).
    pub fn drawPath(s: *Surface, path: *const Path) void {
        const b = s.bd();
        if (s.fill == null and s.stroke == null) {
            const black: Fill = .{ .paint = .{ .color = .{ 0, 0, 0 } } };
            return b.drawPath(s.cx, path, &black, null);
        }
        if (s.complex()) {
            if (s.fill) |*f| b.drawPath(s.cx, path, f, null);
            if (s.stroke) |*st| b.drawPath(s.cx, path, null, st);
            return;
        }
        b.drawPath(s.cx, path, if (s.fill) |*f| f else null, if (s.stroke) |*st| st else null);
    }

    pub fn pushTransform(s: *Surface, t: Tf) void {
        s.pushes.append(s.cx.work(), .transform) catch return s.oom();
        s.bd().saveGs();
        s.bd().concat(t);
    }

    pub fn pushBlend(s: *Surface, bm: Blend) void {
        s.pushes.append(s.cx.work(), .blend) catch return s.oom();
        s.bd().saveGs();
        if (bm != .normal) s.bd().combine(.{ .bm = bm });
    }

    pub fn pushClip(s: *Surface, path: *const Path, rule: FillRule) void {
        s.pushes.append(s.cx.work(), .clip) catch return s.oom();
        s.bd().pushClip(s.cx, path, rule);
    }

    pub fn pushMask(s: *Surface, m: Mask) void {
        s.pushes.append(s.cx.work(), .{ .mask = m }) catch return s.oom();
        s.builders.append(s.cx.work(), Builder.init(s.cx.work(), .identity, true)) catch return s.oom();
    }

    pub fn pushOpacity(s: *Surface, o: f32) void {
        s.pushes.append(s.cx.work(), .{ .opacity = o }) catch return s.oom();
        if (o != 1) s.builders.append(s.cx.work(), Builder.init(s.cx.work(), .identity, true)) catch return s.oom();
    }

    pub fn pushIsolated(s: *Surface) void {
        s.pushes.append(s.cx.work(), .isolated) catch return s.oom();
        s.builders.append(s.cx.work(), Builder.init(s.cx.work(), .identity, true)) catch return s.oom();
    }

    pub fn depth(s: *const Surface) usize {
        return s.pushes.items.len;
    }

    /// Pops pushes until `n` remain.
    pub fn popTo(s: *Surface, n: usize) void {
        while (s.pushes.items.len > n) s.pop();
    }

    pub fn pop(s: *Surface) void {
        s.popGroup(false);
    }

    /// Pops pushes until `n` remain, leaving out a group (opacity, mask, isolation) that drew
    /// nothing: a box the walk of a page meets outside the page's window (emit.zig `paintNode`)
    /// draws nothing in it, and whether its empty group were drawn would depend on how much of
    /// the document the page's walk visits (a part's frame or the whole document).
    pub fn popToDroppingEmpty(s: *Surface, n: usize) void {
        while (s.pushes.items.len > n) s.popGroup(true);
    }

    fn popGroup(s: *Surface, drop_empty: bool) void {
        const p = s.pushes.pop() orelse return;
        switch (p) {
            .transform, .blend => s.bd().restoreGs(),
            .clip => s.bd().c.restore(),
            .opacity => |o| if (o != 1) {
                var sub = s.builders.pop().?;
                const st = sub.finishIn(s.cx);
                if (drop_empty and st.content.len == 0) return;
                s.bd().drawOpacified(s.cx, o, &st);
            },
            .mask => |m| {
                var sub = s.builders.pop().?;
                const st = sub.finishIn(s.cx);
                if (drop_empty and st.content.len == 0) return;
                s.bd().drawMasked(s.cx, &m, &st);
            },
            .isolated => {
                var sub = s.builders.pop().?;
                const st = sub.finishIn(s.cx);
                if (drop_empty and st.content.len == 0) return;
                s.bd().drawIsolated(s.cx, &st);
            },
        }
    }

    /// Draws an image XObject over `width` x `height` at the current origin.
    pub fn drawImage(s: *Surface, img: Ref, width: f32, height: f32) void {
        if (!(width > 0) or !(height > 0)) return;
        s.bd().drawImage(s.cx, img, width, height);
    }

    pub fn drawShading(s: *Surface, sh: Ref) void {
        s.bd().drawShading(s.cx, sh);
    }

    /// Draws a finished stream as an opacified group (krilla `draw_opacified_stream`).
    pub fn drawOpacifiedStream(s: *Surface, opacity: f32, st: *const Stream) void {
        s.bd().drawOpacified(s.cx, opacity, st);
    }

    /// `/Artifact BMC` (only on a tagged page surface: krilla's `start_tagged(Artifact)`). Marked
    /// content does not nest: a section opened inside an open one writes nothing (its end neither).
    pub fn startArtifact(s: *Surface) void {
        _ = s.startTagged(.artifact);
    }

    pub fn endArtifact(s: *Surface) void {
        s.endTagged();
    }

    /// krilla `Surface::start_tagged`: an artifact (`/Artifact BMC`, no identifier) or a content
    /// sequence (`/P<</MCID n>>BDC`, `/Span<</MCID n/Lang(..)>>BDC`) whose marked-content id is
    /// returned. Null when the surface is not a tagged page (stream surfaces, untagged output) or
    /// when a section is already open in the current stream.
    pub fn startTagged(s: *Surface, tag: ContentTag) ?i32 {
        if (!s.tagging) return null;
        const b = s.bd();
        b.marked += 1;
        if (b.marked > 1) return null;
        switch (tag) {
            .artifact => {
                b.c.beginMarked("Artifact");
                return null;
            },
            .other => {
                b.c.beginMarkedMcid("P", s.mcid);
            },
            .span => |lang| {
                b.c.bdcBegin("Span");
                b.c.b.pairInt("MCID", s.mcid);
                b.c.b.pairText("Lang", lang);
                b.c.bdcEnd();
            },
        }
        s.mcid += 1;
        return s.mcid - 1;
    }

    /// krilla `Surface::end_tagged`.
    pub fn endTagged(s: *Surface) void {
        if (!s.tagging) return;
        const b = s.bd();
        if (b.marked == 0) return;
        b.marked -= 1;
        if (b.marked == 0) b.c.endMarked();
    }

    /// Whether the current stream has a marked-content section open.
    pub fn inMarked(s: *Surface) bool {
        return s.tagging and s.bd().marked > 0;
    }

    fn oom(s: *Surface) void {
        s.cx.doc.b.failed = true;
    }
};

/// Tight bounds of a path: its end points and the extrema of its curves (tiny-skia
/// `Path::compute_tight_bounds`); null when the path would not finish (`geom.bounds`).
pub fn tightBounds(p: *const Path) ?LRect {
    if (p.verbs.items.len <= 1 or p.points.items.len == 0) return null;
    const pts = p.points.items;
    var l = std.math.inf(f32);
    var t = std.math.inf(f32);
    var r = -std.math.inf(f32);
    var b = -std.math.inf(f32);
    var i: usize = 0;
    var cur: [2]f32 = .{ pts[0].x, pts[0].y };
    for (p.verbs.items) |v| {
        // the segment's control polygon, per axis (2 to 4 values)
        var xs: [4]f32 = undefined;
        var ys: [4]f32 = undefined;
        var n: usize = 0;
        switch (v) {
            .close => continue,
            .move => {
                cur = .{ pts[i].x, pts[i].y };
                i += 1;
                n = 1;
                xs[0] = cur[0];
                ys[0] = cur[1];
            },
            .line, .quad, .cubic => {
                const k: usize = switch (v) {
                    .line => 1,
                    .quad => 2,
                    else => 3,
                };
                xs[0] = cur[0];
                ys[0] = cur[1];
                for (0..k) |j| {
                    xs[j + 1] = pts[i + j].x;
                    ys[j + 1] = pts[i + j].y;
                }
                i += k;
                n = k + 1;
                cur = .{ xs[k], ys[k] };
            },
        }
        // end points
        l = @min(l, xs[n - 1]);
        r = @max(r, xs[n - 1]);
        t = @min(t, ys[n - 1]);
        b = @max(b, ys[n - 1]);
        if (n < 3) continue;
        // curve extrema: the roots of the derivative, per axis
        var roots: [4]f32 = undefined;
        var nr: usize = 0;
        for ([2]*const [4]f32{ &xs, &ys }) |c| {
            if (n == 3) {
                const den = c[0] - 2 * c[1] + c[2];
                if (den != 0) {
                    roots[nr] = (c[0] - c[1]) / den;
                    nr += 1;
                }
            } else {
                // B'(t) / 3 = qa t^2 + qb t + qc
                const qa = -c[0] + 3 * c[1] - 3 * c[2] + c[3];
                const qb = 2 * (c[0] - 2 * c[1] + c[2]);
                const qc = c[1] - c[0];
                if (qa == 0) {
                    if (qb != 0) {
                        roots[nr] = -qc / qb;
                        nr += 1;
                    }
                } else {
                    const disc = qb * qb - 4 * qa * qc;
                    if (disc >= 0) {
                        const sq = @sqrt(disc);
                        roots[nr] = (-qb + sq) / (2 * qa);
                        roots[nr + 1] = (-qb - sq) / (2 * qa);
                        nr += 2;
                    }
                }
            }
        }
        for (roots[0..nr]) |u| {
            if (!(u > 0 and u < 1)) continue;
            const mu = 1 - u;
            var px: f32 = undefined;
            var py: f32 = undefined;
            if (n == 3) {
                px = mu * mu * xs[0] + 2 * mu * u * xs[1] + u * u * xs[2];
                py = mu * mu * ys[0] + 2 * mu * u * ys[1] + u * u * ys[2];
            } else {
                const k0 = mu * mu * mu;
                const k1 = 3 * mu * mu * u;
                const k2 = 3 * mu * u * u;
                const k3 = u * u * u;
                px = k0 * xs[0] + k1 * xs[1] + k2 * xs[2] + k3 * xs[3];
                py = k0 * ys[0] + k1 * ys[1] + k2 * ys[2] + k3 * ys[3];
            }
            l = @min(l, px);
            r = @max(r, px);
            t = @min(t, py);
            b = @max(b, py);
        }
    }
    if (!std.math.isFinite(l) or !std.math.isFinite(t) or !std.math.isFinite(r) or !std.math.isFinite(b)) return null;
    return LRect.ltrb(l, t, r, b);
}

const testing = std.testing;

test "surface: lazy transforms, isolated ops, opacity groups (box-chrome.pdf shape)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = w.Doc.init(a, .{ .compress = false });
    var cx: Ctx = .{ .a = a, .doc = &doc };
    var s = Surface.initPage(&cx, 150);
    s.pushTransform(Tf.scale(0.75, 0.75));
    var p: Path = .empty;
    try p.addRect(a, .{ .x = 0, .y = 0, .w = 400, .h = 200 });
    s.setFill(.{ .paint = .{ .color = .{ 235, 240, 250 } } });
    s.drawPath(&p);
    s.pushOpacity(0.8);
    p.reset();
    try p.addRect(a, .{ .x = 24, .y = 24, .w = 300, .h = 120 });
    s.setFill(.{ .paint = .{ .color = .{ 255, 255, 255 } } });
    s.drawPath(&p);
    s.pop();
    // a clip in page space
    p.reset();
    try p.addRect(a, .{ .x = 20, .y = 20, .w = 110, .h = 110 });
    s.pushClip(&p, .nonzero);
    s.pop();
    s.pop();
    const st = s.finish();
    try testing.expectEqualStrings("q 0.75 0 0 -0.75 0 150 cm 0.9216 0.9412 0.9804 rg 0 0 400 200 re\nf\nQ\n" ++
        "q 0.75 0 0 -0.75 0 150 cm/g0 gs/x0 Do\nQ\nq 15 135 82.5 -82.5 re\nW\nn\nQ", st.content);
    try testing.expectEqual(@as(usize, 1), st.res.lists[@intFromEnum(w.ResKind.x_object)].items.len);
}
