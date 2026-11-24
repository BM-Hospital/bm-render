//! PDF text: takumi-pdf's glyph.rs and the text half of emitter.rs (`TextDevice::paint_glyph_run`)
//! plus krilla's text drawing (`Surface::draw_glyphs`, `ContentBuilder::draw_glyphs` and the
//! glyph-run encoders of content.rs, the `GlyphSpanner` / `GlyphGrouper` of text/group.rs),
//! on the emitter's surface (emit_surface.zig) and the document font registry
//! (font_objects.zig).
//!
//! Layers, bottom up:
//!   * `builderDrawGlyphs` — krilla `ContentBuilder::draw_glyphs`: `q [cm] [gs] colour BT
//!     ([/Span<</ActualText ..>>BDC] Tr /fN size Tf 1 0 0 -1 x y Tm [..]TJ | <..>Tj [EMC]) ET Q`.
//!   * `drawGlyphs` — krilla `Surface::draw_glyphs`: text with the surface's fill / stroke, or the
//!     glyphs as paths (`outlined`).
//!   * `paintGlyphRun` — takumi `TextDevice::paint_glyph_run`: clip-text fills, shadow passes
//!     (blur bands), `-webkit-text-stroke` with `paint-order`, faux bold (stroke) and faux oblique
//!     (shear about the baseline), colour-glyph silhouettes in shadows.
//!   * `drawFrameRun` — the adapter the emitter's text seam calls with what svg_out_text.zig has
//!     per run (Frame, node, line layout, `RunIter.Run`, content origin).
//! Plus `runGlyphs` / `Uncovered` (takumi glyph.rs: cluster ranges, `.notdef` handling and the
//! `uncoveredText` policy).
const std = @import("std");
const w = @import("writer.zig");
const ct = @import("content.zig");
const sf = @import("emit_surface.zig");
const geom = @import("emit_geom.zig");
const ed = @import("emit_device.zig");
const fe = @import("font_embed.zig");
const fo = @import("font_objects.zig");
const type3 = @import("type3.zig");
const ttf = @import("../font/ttf.zig");
const uni = @import("../font/unicode.zig");
const style = @import("../style/style.zig");

const Allocator = std.mem.Allocator;
const Tf = geom.Tf;
const LRect = geom.LRect;
const Path = geom.Path;
const Color = style.Color;

pub const FontRegistry = fo.FontRegistry;
pub const Track = fo.Track;
pub const FontContainer = fo.FontContainer;
pub const FontIssues = fo.FontIssues;
pub const FontId = fo.FontId;
pub const PdfGlyph = fo.PdfGlyph;

const enable_color_fonts = fo.enable_color_fonts;
const color_mod = if (enable_color_fonts) @import("../font/color.zig") else struct {};

/// takumi's faux-italic angle (Blink `SetupSkFont`: Skia's -1/4 skew), degrees.
pub const synthetic_italic_skew: f32 = -14.036243;

// ===================================================================== glyphs and runs

/// takumi `PdfGlyph`: a glyph of a run with em-normalised offsets from the run origin (krilla
/// scales them by the size it asks with; the advances are always 0) and the bytes of the run
/// text its cluster covers.
pub const Glyph = struct {
    gid: u16,
    /// glyph x / font size (x from the run origin, px)
    x: f32,
    /// -(glyph y) / font size (y down in px: positive = above the origin)
    y: f32,
    start: u32,
    end: u32,
    /// px position from the run origin (y down), for colour-glyph silhouettes
    px: f32 = 0,
    py: f32 = 0,
};

/// A shaped glyph as the layout hands it over: position from the run origin (px, y down) and
/// the byte range of its own (unmerged) cluster in the run text.
pub const ShapedGlyph = struct { gid: u16, x: f32, y: f32, start: u32, end: u32 };

/// The font instance of a run (bm-render: `fonts.font(face)` and `fonts.face(face).index`).
pub const FontRef = struct { font: *const ttf.Font, face_index: u32 = 0, variant: u32 = 0 };

/// What krilla's `draw_glyphs` needs about a run.
pub const Run = struct {
    font: FontRef,
    glyphs: []const Glyph,
    /// the text the glyph ranges index (takumi: the run's text; any superset with absolute ranges
    /// gives the same output)
    text: []const u8,
    size: f32,
};

pub const Uncovered = fo.Uncovered;

/// takumi `run_glyphs`: the run's glyphs with their text ranges (overlapping clusters merged so
/// krilla spans them together), `.notdef` glyphs recorded in `uncovered` and dropped unless a
/// placeholder is drawn. `text.len` bounds the ranges.
pub fn runGlyphs(a: Allocator, keep: Allocator, shaped: []const ShapedGlyph, size: f32, text: []const u8, uncovered: *Uncovered) ![]Glyph {
    const out = try a.alloc(Glyph, shaped.len);
    for (shaped, out) |g, *o| {
        const s0 = @min(g.start, text.len);
        const e0 = @min(g.end, text.len);
        const ok = s0 <= e0;
        o.* = .{ .gid = g.gid, .x = g.x / size, .y = -g.y / size, .start = if (ok) @intCast(s0) else 0, .end = if (ok) @intCast(e0) else 0, .px = g.x, .py = g.y };
        if (g.gid == 0) {
            var i: usize = o.start;
            while (i < o.end) {
                const d = uni.decodeUtf8(text, i);
                i += d.len;
                try uncovered.record(keep, d.cp); // (the document's memory: page memory is rewound)
            }
        }
    }
    // merge_overlapping_spans
    var group: usize = 0;
    var i: usize = 1;
    while (i < out.len) : (i += 1) {
        const g = out[group];
        const n = out[i];
        if (!(g.start < n.end and n.start < g.end)) {
            group = i;
            continue;
        }
        const s = @min(g.start, n.start);
        const e = @max(g.end, n.end);
        for (out[group .. i + 1]) |*x| {
            x.start = s;
            x.end = e;
        }
    }
    if (uncovered.drawsPlaceholder()) return out;
    var n: usize = 0;
    for (out) |g| {
        if (g.gid == 0) continue;
        out[n] = g;
        n += 1;
    }
    return out[0..n];
}

fn sameRange(x: Glyph, y: Glyph) bool {
    return x.start == y.start and x.end == y.end;
}

/// The glyphs are in reverse text order (krilla writes `/ReversedChars`).
fn isReversed(gs: []const Glyph) bool {
    if (gs.len <= 1) return false;
    for (gs[0 .. gs.len - 1], gs[1..]) |p, n| if (!(p.start >= n.end)) return false;
    return true;
}

fn approxZero(v: f32) bool {
    return @abs(v) <= 0.001;
}

// ============================================================ krilla text/group.rs (spanning)

/// krilla `use_text_spanner` over a font container (CID and Type3 glyphs).
fn useTextSpanner(fc: *FontContainer, gs: []const Glyph, text: []const u8, color: [3]u8) !bool {
    if (gs.len == 0) return false;
    var span = false;
    for (gs, 0..) |g, i| {
        if (i + 1 < gs.len and sameRange(g, gs[i + 1])) span = true;
        if (span) continue;
        const ad = try fc.addGlyph(g.gid, color);
        const t = text[g.start..g.end];
        if (fc.getCodepoints(ad.font, ad.glyph)) |cps| {
            if (!std.mem.eql(u8, cps, t)) {
                span = true;
                fc.noteConflict(g.gid);
            }
        } else try fc.setCodepoints(ad.font, ad.glyph, t);
    }
    return span;
}

const Fragment = struct { glyphs: []const Glyph, actual: ?[2]u32 };

/// krilla `GlyphSpanner` over a font container.
const Spanner = struct {
    fc: *FontContainer,
    gs: []const Glyph,
    text: []const u8,
    reversed: bool,
    color: [3]u8,
    unicode: []const ?[]const u8,
    off: usize = 0,

    fn init(a: Allocator, fc: *FontContainer, gs: []const Glyph, text: []const u8, reversed: bool, color: [3]u8) !Spanner {
        const sg = try a.alloc(fe.SpanGlyph, gs.len);
        for (gs, sg) |g, *o| o.* = .{ .gid = g.gid, .start = g.start, .end = g.end };
        return .{ .fc = fc, .gs = gs, .text = text, .reversed = reversed, .color = color, .unicode = try fe.clusterUnicode(a, &fc.cid, sg, text) };
    }

    fn visit(s: *Spanner, g: Glyph, prev: ?Glyph, unicode: ?[]const u8) !bool {
        const ad = try s.fc.addGlyph(g.gid, s.color);
        const t = unicode orelse s.text[g.start..g.end];
        const cps = s.fc.getCodepoints(ad.font, ad.glyph);
        const incompatible = if (cps) |x| !std.mem.eql(u8, x, t) else false;
        // takumi always forbids invalid codepoints, so a compatible glyph takes the text unless
        // it has it already
        _ = prev;
        if (!incompatible and cps == null) try s.fc.setCodepoints(ad.font, ad.glyph, t);
        if (incompatible) s.fc.noteConflict(g.gid);
        return incompatible;
    }

    fn next(s: *Spanner) !?Fragment {
        const rest = s.gs[s.off..];
        if (rest.len == 0) return null;
        const uni_rest = s.unicode[s.off..];
        var use_span: ?bool = null;
        var count: usize = 1;
        const first_inc = try s.visit(rest[0], null, uni_rest[0]);
        var prev = rest[0];
        var i: usize = 1;
        while (i < rest.len) : (i += 1) {
            const inc = try s.visit(rest[i], prev, uni_rest[i]);
            const same = sameRange(prev, rest[i]);
            if (use_span) |u| {
                if (u) {
                    if (!same) break;
                } else {
                    if (same) {
                        count -= 1;
                        break;
                    }
                    if (inc) break;
                }
            } else if (same) {
                use_span = true;
            } else {
                use_span = first_inc;
                if (first_inc or inc) break;
            }
            prev = rest[i];
            count += 1;
            if (s.reversed and count > 1 and std.mem.eql(u8, s.text[prev.start..prev.end], " ")) break;
        }
        if (count == 1) use_span = first_inc;
        s.off += count;
        return .{ .glyphs = rest[0..count], .actual = if (use_span orelse false) .{ rest[0].start, rest[0].end } else null };
    }
};

// ===================================================================== krilla content.rs

/// Font bbox (head) in font units, as krilla `Font::bbox` (left, top=yMin, right, bottom=yMax).
fn fontBox(font: *const ttf.Font) LRect {
    const upem: f32 = @floatFromInt(@max(1, font.units_per_em));
    const b = [4]f32{
        @floatFromInt(ttf.rdi16(font.head, 36)), @floatFromInt(ttf.rdi16(font.head, 38)),
        @floatFromInt(ttf.rdi16(font.head, 40)), @floatFromInt(ttf.rdi16(font.head, 42)),
    };
    if (b[0] <= b[2] and b[1] <= b[3]) return .{ .l = b[0], .t = b[1], .r = b[2], .b = b[3] };
    return .{ .l = 0, .t = 0, .r = upem, .b = upem };
}

/// krilla `get_glyphs_bbox`.
fn glyphsBbox(run: Run, x0: f32, y0: f32) LRect {
    const font = run.font.font;
    const upem: f32 = @floatFromInt(@max(1, font.units_per_em));
    const fb = fontBox(font).transform(Tf.scale(run.size / upem, -run.size / upem)) orelse LRect{ .l = 0, .t = 0, .r = 1, .b = 1 };
    var bl = x0 + fb.l;
    var bt = y0 + fb.t;
    var br = x0 + fb.r;
    var bb = y0 + fb.b;
    for (run.glyphs) |g| {
        const gx = x0 + g.x * run.size;
        const gy = y0 - g.y * run.size;
        bl = @min(bl, gx + fb.l);
        br = @max(br, gx + fb.r);
        bt = @min(bt, gy + fb.t);
        bb = @max(bb, gy + fb.b);
    }
    return LRect.ltrb(bl, bt, br, bb) orelse .{ .l = bl, .t = bt, .r = br, .b = bb };
}

fn hasTranslucentStop(p: sf.Paint) bool {
    const stops: []const sf.Stop = switch (p) {
        .linear => |g| g.stops,
        .radial => |g| g.stops,
        .sweep => |g| g.stops,
        else => return false,
    };
    for (stops) |s| if (s.opacity != 1) return true;
    return false;
}

/// Text rendering modes (krilla `TextRenderingMode`).
const Mode = enum(u8) { fill = 0, stroke = 1, fill_stroke = 2 };

/// krilla `ContentBuilder::draw_glyphs`: the run as text at (`x`, `y`) (surface space of the
/// builder) with `fill` and / or `stroke`. `ctx_color` is the context colour of colour glyphs.
pub fn builderDrawGlyphs(reg: *FontRegistry, cx: *sf.Ctx, b: *sf.Builder, x: f32, y: f32, fill: ?*const sf.Fill, stroke: ?*const sf.Stroke, ctx_color: [3]u8, run: Run) !void {
    if (fill == null and stroke == null) return;
    b.saveGs();
    defer b.restoreGs();
    if (fill) |f| {
        if (f.paint != .pattern and f.opacity != 1) b.combine(.{ .ca = f.opacity });
    }
    if (stroke) |s| {
        if (s.paint != .pattern) {
            if (s.opacity != 1) b.combine(.{ .CA = s.opacity });
            // krilla also sets the fill opacity from the stroke
            if (s.opacity != 1) b.combine(.{ .ca = s.opacity });
        }
    }
    const mode: Mode = if (fill != null and stroke != null) .fill_stroke else if (fill != null) .fill else .stroke;
    try fillStrokeGlyphRun(reg, cx, b, x, y, mode, fill, stroke, ctx_color, run);
}

fn fillStrokeGlyphRun(reg: *FontRegistry, cx: *sf.Ctx, b: *sf.Builder, x: f32, y: f32, mode: Mode, fill: ?*const sf.Fill, stroke: ?*const sf.Stroke, ctx_color: [3]u8, run: Run) !void {
    if (run.glyphs.len == 0) return;
    b.isoBegin();
    b.isoMid(cx);
    // fill_action / stroke_action
    const unit: LRect = .{ .l = 0, .t = 0, .r = 1, .b = 1 };
    if (fill) |f| {
        var bounds = unit;
        if (b.bbox_important or f.paint != .color) {
            bounds = glyphsBbox(run, x, y);
            b.expandBbox(bounds);
        }
        b.setPaint(cx, bounds, f.paint, f.opacity, false);
    }
    if (stroke) |s| {
        var bounds = unit;
        if (b.bbox_important or s.paint != .color) {
            bounds = glyphsBbox(run, x, y);
            b.expandBbox(bounds);
        }
        b.setStrokeProps(cx, bounds, s);
    }
    b.c.beginText();
    const fc = try reg.container(run.font.font, run.font.face_index, run.font.variant);
    var cur_x = x;
    var cur_y = y;
    const reversed = isReversed(run.glyphs);
    const do_span = reversed or try useTextSpanner(fc, run.glyphs, run.text, ctx_color);
    if (do_span) {
        var sp = try Spanner.init(cx.work(), fc, run.glyphs, run.text, reversed, ctx_color);
        while (try sp.next()) |frag| try glyphSpan(reg, cx, b, &cur_x, &cur_y, frag, mode, fc, ctx_color, run, reversed);
    } else try glyphSpan(reg, cx, b, &cur_x, &cur_y, .{ .glyphs = run.glyphs, .actual = null }, mode, fc, ctx_color, run, reversed);
    b.c.endText();
    b.isoEnd();
}

/// krilla `closing_spacing`.
fn closingSpacing(gs: []const Glyph, fc: *const FontContainer, x: f32, size: f32) ?f32 {
    const pen = x;
    var furthest = -std.math.floatMax(f32);
    var last = x;
    for (gs) |g| {
        const adv = (fc.advance(g.gid) orelse 0) / fc.upem;
        last = pen + g.x * size + adv * size;
        furthest = @max(furthest, last);
    }
    const spacing = furthest - last;
    return if (spacing > 0.001) spacing else null;
}

/// krilla `fill_stroke_glyph_span` (+ `GlyphGrouper`).
fn glyphSpan(reg: *FontRegistry, cx: *sf.Ctx, b: *sf.Builder, cur_x: *f32, cur_y: *f32, frag: Fragment, mode: Mode, fc: *FontContainer, ctx_color: [3]u8, run: Run, reversed: bool) !void {
    if (frag.actual) |r| {
        b.c.bdcBegin("Span");
        b.c.b.pairText("ActualText", run.text[r[0]..r[1]]);
        b.c.bdcEnd();
    }
    if (reversed) b.c.beginMarked("ReversedChars");
    const closing: ?f32 = if (frag.actual != null) closingSpacing(frag.glyphs, fc, cur_x.*, run.size) else null;
    // GlyphGrouper: same font and y offset (advances are always 0)
    var i: usize = 0;
    const gs = frag.glyphs;
    while (i < gs.len) {
        const id = fc.fontIdOf(gs[i].gid, ctx_color).?;
        const yo = gs[i].y * 1.0;
        var e = i + 1;
        while (e < gs.len and fc.fontIdOf(gs[e].gid, ctx_color).?.eql(id) and gs[e].y * 1.0 == yo) e += 1;
        try glyphGroup(reg, cx, b, cur_x, cur_y, gs[i..e], id, yo, mode, fc, ctx_color, run, if (e == gs.len) closing else null);
        i = e;
    }
    if (reversed) b.c.endMarked();
    if (frag.actual != null) b.c.endMarked();
}

/// krilla `fill_stroke_glyph_group`.
fn glyphGroup(reg: *FontRegistry, cx: *sf.Ctx, b: *sf.Builder, cur_x: *f32, cur_y: *f32, gs: []const Glyph, id: FontId, y_offset: f32, mode: Mode, fc: *FontContainer, ctx_color: [3]u8, run: Run, closing: ?f32) !void {
    const tr: u8 = if (mode == .fill or FontContainer.forceFill(id)) 0 else if (mode == .fill_stroke) 2 else 1;
    b.c.textRenderMode(tr);
    const y = cur_y.* - y_offset * run.size;
    const body = if (closing != null and gs.len > 0) gs[0 .. gs.len - 1] else gs;
    if (body.len > 0) try encodeRun(reg, cx, b, cur_x, y, id, fc, ctx_color, body, run);
    if (closing) |spacing| {
        if (gs.len > 0) {
            b.c.charSpacing(spacing);
            try encodeRun(reg, cx, b, cur_x, y, id, fc, ctx_color, gs[gs.len - 1 ..], run);
            b.c.charSpacing(0);
        }
    }
}

/// krilla `encode_consecutive_glyph_run` (+ `encode_single_glyph`,
/// `encode_glyphs_with_individual_positioning`).
fn encodeRun(reg: *FontRegistry, cx: *sf.Ctx, b: *sf.Builder, cur_x: *f32, y: f32, id: FontId, fc: *FontContainer, ctx_color: [3]u8, gs: []const Glyph, run: Run) !void {
    const name = b.res.add(.font, fc.ref(cx.doc, id));
    b.c.font(name.slice(), run.size);
    b.c.textMatrix(.{ 1, 0, 0, -1, cur_x.*, y });
    for (gs) |g| {
        if (g.gid == 0 or fc.last_resort) reg.notdef_shown += 1;
    }
    const a = cx.work();
    var enc: std.ArrayList(u8) = .empty;
    if (gs.len == 1 and approxZero(gs[0].x * 1.0)) {
        try fc.pdfGlyph(id, gs[0].gid, ctx_color).?.encodeInto(a, &enc);
        const at = b.c.bytes().len;
        b.c.b.str(enc.items);
        try wrote(reg, fc, b, at);
        b.c.operands = true;
        b.c.op("Tj");
        return;
    }
    const upem = fc.unitsPerEm(id);
    var adjustment: f32 = 0;
    b.c.tjBegin();
    for (gs) |g| {
        const pg = fc.pdfGlyph(id, g.gid, ctx_color).?;
        const x_advance: f32 = 0 * upem;
        const font_advance: ?f32 = if (fc.advance(g.gid)) |n| (n / fc.upem) * upem else null;
        const x_offset = (g.x * 1.0) * upem;
        adjustment += x_offset;
        if (!approxZero(adjustment)) {
            if (enc.items.len > 0) {
                const at = b.c.bytes().len;
                b.c.tjStr(enc.items);
                try wrote(reg, fc, b, at);
                enc.clearRetainingCapacity();
            }
            b.c.tjAdjust(-(adjustment / upem * fe.pdf_units_per_em));
            adjustment = 0;
        }
        try pg.encodeInto(a, &enc);
        if (font_advance) |fa| adjustment += x_advance - fa;
        adjustment -= x_offset;
    }
    if (enc.items.len > 0) {
        const at = b.c.bytes().len;
        b.c.tjStr(enc.items);
        try wrote(reg, fc, b, at);
    }
    b.c.tjEnd();
}

/// (`FontRegistry.track`) a string of glyph codes written at `at` of `b`'s content.
fn wrote(reg: *FontRegistry, fc: *const FontContainer, b: *const sf.Builder, at: usize) !void {
    const t = reg.track orelse return;
    try t.wrote(fc, b, at, b.c.bytes().len);
}

// ===================================================================== krilla surface.rs

/// krilla `Surface::context_color`.
fn contextColor(s: *const sf.Surface) [3]u8 {
    if (s.fill) |f| if (f.paint == .color) return f.paint.color;
    if (s.stroke) |st| if (st.paint == .color) return st.paint.color;
    return .{ 0, 0, 0 };
}

fn complexFillOrStroke(s: *const sf.Surface) bool {
    if (s.stroke) |st| if (st.opacity != 1 or hasTranslucentStop(st.paint)) return true;
    if (s.fill) |f| if (hasTranslucentStop(f.paint)) return true;
    return false;
}

/// krilla `Surface::draw_glyphs`: the run at (`x`, `y`) with the surface's current fill and
/// stroke, as text, or as glyph paths when `outlined`.
pub fn drawGlyphs(reg: *FontRegistry, s: *sf.Surface, x: f32, y: f32, run: Run, outlined: bool) !void {
    const cc = contextColor(s);
    if (outlined) return outlineGlyphs(s, run, cc, x, y);
    const b = s.bd();
    if (s.fill) |*f| {
        if (s.stroke) |*st| {
            if (complexFillOrStroke(s)) {
                try builderDrawGlyphs(reg, s.cx, b, x, y, f, null, cc, run);
                return outlineGlyphs(s, run, cc, x, y);
            }
            return builderDrawGlyphs(reg, s.cx, b, x, y, f, st, cc, run);
        }
        return builderDrawGlyphs(reg, s.cx, b, x, y, f, null, cc, run);
    }
    if (s.stroke) |*st| return builderDrawGlyphs(reg, s.cx, b, x, y, null, st, cc, run);
    const black: sf.Fill = .{ .paint = .{ .color = .{ 0, 0, 0 } } };
    return builderDrawGlyphs(reg, s.cx, b, x, y, &black, null, cc, run);
}

/// krilla `Surface::outline_glyphs`.
fn outlineGlyphs(s: *sf.Surface, run: Run, cc: [3]u8, x: f32, y: f32) !void {
    const font = run.font.font;
    const upem: f32 = @floatFromInt(@max(1, font.units_per_em));
    for (run.glyphs) |g| {
        const base = Tf.translate(x + g.x * run.size, y - g.y * run.size).pre(Tf.scale(run.size / upem, -run.size / upem));
        try type3.drawGlyph(s.cx, s, font, cc, g.gid, base);
    }
}

// ===================================================================== takumi emitter.rs

/// Blurred-shadow bands (takumi shadow.rs `Band`), shared with the box shadows.
const Band = @import("emit.zig").Band;
const bandsOf = @import("emit.zig").bandsOf;

/// A `text-shadow` while it paints (takumi `SizedShadow`): colour, offset, blur radius (px).
pub const Shadow = struct { color: Color, x: f32 = 0, y: f32 = 0, blur: f32 = 0 };

/// A fill glyphs are painted with for `background-clip: text` (takumi `GlyphBackground`).
pub const GlyphBackground = struct { fill: sf.Fill, clip: ?*const Path = null };

/// The paint of a run (takumi's `ShapedRun` brush + synthesis).
pub const RunPaint = struct {
    /// `color` / `-webkit-text-fill-color`
    color: Color,
    stroke_width: f32 = 0,
    stroke_color: Color = .{},
    /// `paint-order` puts the stroke before the fill
    stroke_first: bool = false,
    /// faux-bold stroke width (px)
    synthetic_bold: ?f32 = null,
    /// faux-oblique skew, degrees (`synthetic_italic_skew`)
    synthetic_skew: ?f32 = null,
    /// the run's baseline (paragraph space, px): the oblique shears about it
    baseline: f32 = 0,
    /// this page owns the run's line (false: outlines only, pagination)
    owned: bool = true,
    /// the emitter's colour filter (CSS `filter` colour functions)
    filter: ?*const ed.ColorFilter = null,
};

fn fillFromRgba(c: Color) sf.Fill {
    return ed.fillOf(c, 1, .nonzero);
}

fn syntheticStroke(p: RunPaint, f: sf.Fill) ?sf.Stroke {
    const width = p.synthetic_bold orelse return null;
    return .{ .paint = f.paint, .opacity = f.opacity, .width = width };
}

fn backgroundStroke(p: RunPaint, f: sf.Fill) ?sf.Stroke {
    const width = @max(p.synthetic_bold orelse 0, p.stroke_width);
    if (!(width > 0)) return null;
    return .{ .paint = f.paint, .opacity = f.opacity, .width = width };
}

/// takumi `TextDevice::text_stroke`.
fn textStroke(p: RunPaint, shadow_color: ?Color) ?sf.Stroke {
    if (p.stroke_width <= 0 or p.stroke_color.a == 0) return null;
    const f = fillFromRgba(ed.filtered(p.filter, shadow_color orelse p.stroke_color));
    return .{ .paint = f.paint, .opacity = f.opacity, .width = p.stroke_width };
}

/// Whether `gid` paints in the font's own colours (takumi `ColorGlyphs::contains`).
fn isColorGlyph(font: *const ttf.Font, gid: u16) bool {
    if (comptime !enable_color_fonts) return false;
    return color_mod.glyphKind(font, gid) != .none;
}

/// takumi `TextDevice::paint_glyph_run`: `fills` seen through the run's glyphs, then the glyphs
/// `with_paint` (or their shadow while `shadow` is set). `origin` is the content-box origin the
/// glyph positions are relative to (px, before any shadow offset).
pub fn paintGlyphRun(reg: *FontRegistry, s: *sf.Surface, run_in: Run, origin_in: [2]f32, p: RunPaint, shadow: ?Shadow, fills: []const GlyphBackground, with_paint: bool) !void {
    if (run_in.glyphs.len == 0 or run_in.size == 0) return;
    const a = s.cx.work();
    var origin = origin_in;
    if (shadow) |sh| {
        origin[0] += sh.x;
        origin[1] += sh.y;
    }
    const shadow_color: ?Color = if (shadow) |sh| sh.color else null;
    const rgba = ed.filtered(p.filter, shadow_color orelse p.color);
    const paint = fillFromRgba(rgba);
    var run = run_in;
    const font = run.font.font;

    // colour glyphs in a shadow: drawn as silhouettes, not as glyphs
    var sil: std.ArrayList(type3.Silhouette) = .empty;
    var opaque_sil: Path = .empty;
    var bitmaps: std.ArrayList(Glyph) = .empty;
    const colored = coloredFace(reg, font);
    if (shadow != null and colored) {
        var kept: std.ArrayList(Glyph) = .empty;
        for (run.glyphs) |g| {
            if (!isColorGlyph(font, g.gid)) {
                try kept.append(a, g);
                continue;
            }
            const at = [2]f32{ origin[0] + g.px, origin[1] + g.py };
            if (type3.bitmapKind(font, g.gid) == .bitmap_png) {
                var bg = g;
                bg.px = at[0];
                bg.py = at[1];
                try bitmaps.append(a, bg);
            } else try type3.colrSilhouette(a, font, g.gid, .{ p.color.r, p.color.g, p.color.b, p.color.a }, run.size, at, &opaque_sil, &sil);
        }
        if (geom.bounds(&opaque_sil) != null) try sil.append(a, .{ .alpha = 1, .path = opaque_sil });
        run.glyphs = kept.items;
    }
    const ts = textStroke(p, shadow_color);
    const stroke: ?sf.Stroke = ts orelse syntheticStroke(p, paint);
    const text_stroke: ?sf.Stroke = if (shadow_color == null) ts else null;

    // push_oblique
    var oblique = false;
    if (p.synthetic_skew) |deg| {
        // (the engine's own sin / cos, not `@tan`: see emit_geom.zig `Tf.rotate`)
        const sc = @import("../measure_xform.zig").sinCos64(deg * (std.math.pi / 180.0));
        const tangent: f32 = @floatCast(sc[0] / sc[1]);
        s.pushTransform(Tf.row(1, 0, tangent, 1, -tangent * (origin[1] + p.baseline), 0));
        oblique = true;
    }

    if (shadow_color == null) {
        for (fills) |bg| {
            if (bg.clip) |c| s.pushClip(c, .nonzero);
            s.setFill(bg.fill);
            s.setStroke(backgroundStroke(p, bg.fill));
            try drawGlyphs(reg, s, origin[0], origin[1], run, true);
            if (bg.clip != null) s.pop();
        }
    }

    if (with_paint) {
        if (shadow != null and shadow.?.blur > 0) {
            const translucent = paint.opacity != 1;
            if (translucent) s.pushOpacity(paint.opacity);
            var buf: [9]Band = undefined;
            for (bandsOf(shadow.?.blur, &buf)) |band| {
                const width = 2.0 * band.spread + (if (stroke) |st| st.width else 0);
                s.pushOpacity(std.math.clamp(band.alpha, 0, 1));
                var f = paint;
                f.opacity = 1;
                s.setFill(f);
                s.setStroke(if (width > 0) sf.Stroke{ .paint = paint.paint, .opacity = 1, .width = width, .join = .round } else null);
                try drawGlyphs(reg, s, origin[0], origin[1], run, true);
                drawSilhouettes(s, sil.items);
                s.pop();
            }
            for (bitmaps.items) |g| try blurredBitmapSilhouette(s, font, g.gid, run.size, .{ g.px, g.py }, shadow.?.blur, rgba);
            if (translucent) s.pop();
        } else if (text_stroke) |tst| {
            const phases: [2]bool = if (p.stroke_first) .{ true, false } else .{ false, true };
            for (phases) |is_stroke| {
                if (!is_stroke) {
                    s.setFill(paint);
                    s.setStroke(syntheticStroke(p, paint));
                    try drawGlyphs(reg, s, origin[0], origin[1], run, !p.owned);
                } else {
                    var outl: std.ArrayList(Glyph) = .empty;
                    for (run.glyphs) |g| if (!colored or !isColorGlyph(font, g.gid)) try outl.append(a, g);
                    var r2 = run;
                    r2.glyphs = outl.items;
                    s.setFill(null);
                    s.setStroke(tst);
                    try drawGlyphs(reg, s, origin[0], origin[1], r2, true);
                }
            }
        } else {
            s.setFill(paint);
            s.setStroke(stroke);
            try drawGlyphs(reg, s, origin[0], origin[1], run, shadow_color != null or !p.owned);
            if (shadow != null) {
                drawSilhouettes(s, sil.items);
                for (bitmaps.items) |g| try bitmapSilhouette(s, font, g.gid, run.size, .{ g.px, g.py }, rgba);
            }
        }
    }
    if (oblique) s.pop();
    s.setStroke(null);
}

/// takumi `ColorGlyphs::draw_outlines`.
fn drawSilhouettes(s: *sf.Surface, sil: []const type3.Silhouette) void {
    for (sil) |*x| {
        const translucent = x.alpha != 1;
        if (translucent) s.pushOpacity(x.alpha);
        s.drawPath(&x.path);
        if (translucent) s.pop();
    }
}

const raster = @import("../raster/raster.zig");
const eimg = @import("emit_image.zig");

/// takumi `draw_alpha`: every pixel the silhouette colour, its alpha scaled by the colour's.
fn silhouettePixel(ctx: *const anyopaque, p: [4]u8) [4]u8 {
    const c: *const Color = @ptrCast(@alignCast(ctx));
    return .{ c.r, c.g, c.b, p[3] };
}

/// Registers an alpha mask (`alpha`, w x h) filled with `c` as an image (krilla
/// `Image::from_rgba8` of takumi's `draw_alpha` data: straight colour, alpha * c.a).
fn alphaImage(cx: *sf.Ctx, alpha: []const u8, iw: u32, ih: u32, c: *const Color) !sf.Ref {
    const px = try cx.a.alloc(u8, alpha.len * 4);
    for (alpha, 0..) |al, i| {
        const v: u8 = @intCast((@as(u16, al) * c.a + 127) / 255);
        // premultiplied for regPixmap; the filter restores the exact colour
        px[i * 4 ..][0..4].* = .{ v, v, v, v };
    }
    const pm: raster.Pixmap = .{ .width = iw, .height = ih, .data = px };
    const key = std.hash.Wyhash.hash(@as(u64, @as(u32, @bitCast([4]u8{ c.r, c.g, c.b, c.a }))), alpha);
    return eimg.regPixmap(cx, &pm, key, .{ .ctx = c, .apply = silhouettePixel, .key = @as(u32, @bitCast([4]u8{ c.r, c.g, c.b, c.a })) });
}

/// takumi `draw_silhouettes` (sharp) for one bitmap glyph: the image's alpha in colour `c`,
/// drawn under the glyph image's own placement transform.
fn bitmapSilhouette(s: *sf.Surface, font: *const ttf.Font, gid: u16, size: f32, at: [2]f32, c: Color) !void {
    if (comptime !enable_color_fonts) return;
    const cx = s.cx;
    const tables = color_mod.ColorTables.init(font);
    const bm = tables.bitmap(gid, size) orelse return;
    const codec = @import("../codec/codec.zig");
    const img = codec.decode(cx.a, bm.data, .{ .max_pixels = 4 << 20 }) catch return;
    const alpha = try cx.a.alloc(u8, @as(usize, img.width) * img.height);
    for (alpha, 0..) |*o, i| o.* = img.data[i * 4 + 3];
    const col = try cx.a.create(Color);
    col.* = c;
    const ref = try alphaImage(cx, alpha, img.width, img.height, col);
    const sx = if (bm.ppem_x > 0) size / bm.ppem_x else 1;
    const sy = if (bm.ppem > 0) size / bm.ppem else 1;
    const left = @round(bm.bearing_x * sx);
    const top = @round(bm.bearing_y * sy);
    s.pushTransform(Tf.row(sx, 0, 0, sy, at[0] + left, at[1] - top));
    s.drawImage(ref, @floatFromInt(img.width), @floatFromInt(img.height));
    s.pop();
}

/// takumi `draw_blurred_silhouettes` for one bitmap glyph: its alpha at the device size, sampled
/// nearest-neighbour from the bitmap (takumi `ResolvedBitmapGlyph::write_alpha_mask`), padded by
/// 3 sigma and blurred as premultiplied RGBA (`blur_rgba`), in `c`.
fn blurredBitmapSilhouette(s: *sf.Surface, font: *const ttf.Font, gid: u16, size: f32, at: [2]f32, blur: f32, c: Color) !void {
    if (comptime !enable_color_fonts) return;
    const cx = s.cx;
    const sigma = blur * 0.5;
    const pad: u32 = @intFromFloat(@ceil(3 * sigma));
    const tables = color_mod.ColorTables.init(font);
    const bm = tables.bitmap(gid, size) orelse return;
    if (bm.format != .png) return;
    const codec = @import("../codec/codec.zig");
    const img = codec.decode(cx.a, bm.data, .{ .max_pixels = 4 << 20 }) catch return;
    if (img.width == 0 or img.height == 0) return;
    const sx = if (bm.ppem_x > 0) size / bm.ppem_x else 1;
    const sy = if (bm.ppem > 0) size / bm.ppem else 1;
    const left = @round(bm.bearing_x * sx);
    const top = @round(bm.bearing_y * sy);
    const iw: u32 = if (bm.width > 0) bm.width else 1;
    const ih: u32 = if (bm.height > 0) bm.height else 1;
    const pw: u32 = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(iw)) * sx)));
    const ph: u32 = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(ih)) * sy)));
    const bw = pw + 2 * pad;
    const bh = ph + 2 * pad;
    var pix = try raster.Pixmap.init(cx.a, bw, bh);
    @memset(pix.data, 0);
    const same = img.width == pw and img.height == ph;
    const mx: f32 = @floatFromInt(img.width - 1);
    const my: f32 = @floatFromInt(img.height - 1);
    var yy: u32 = 0;
    while (yy < ph) : (yy += 1) {
        const src_y: u32 = if (same) yy else @intFromFloat(std.math.clamp(@round((@as(f32, @floatFromInt(yy)) + 0.5) / sy - 0.5), 0, my));
        var xx: u32 = 0;
        while (xx < pw) : (xx += 1) {
            const src_x: u32 = if (same) xx else @intFromFloat(std.math.clamp(@round((@as(f32, @floatFromInt(xx)) + 0.5) / sx - 0.5), 0, mx));
            pix.data[(@as(usize, yy + pad) * bw + xx + pad) * 4 + 3] = img.data[(@as(usize, src_y) * img.width + src_x) * 4 + 3];
        }
    }
    try raster.blurPixmap(cx.a, &pix, sigma);
    const alpha = try cx.a.alloc(u8, @as(usize, bw) * bh);
    for (alpha, 0..) |*o, i| o.* = pix.data[i * 4 + 3];
    const col = try cx.a.create(Color);
    col.* = .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
    const ref = try alphaImage(cx, alpha, bw, bh, col);
    const fp: f32 = @floatFromInt(pad);
    s.pushTransform(Tf.translate(at[0] + left - fp, at[1] - top - fp));
    s.drawImage(ref, @floatFromInt(bw), @floatFromInt(bh));
    s.pop();
}

// ===================================================================== bm-render adapter

const rt = @import("../render.zig");
const font_mod = @import("../font/font.zig");
const ptext = @import("../paint_text.zig");

/// The outline of `gid` at `sc` px per font unit, in px from the glyph origin with y down (the
/// skip-ink intercepts of emit_text.zig); false when the glyph has none.
pub fn glyphOutlinePx(a: Allocator, font: *const ttf.Font, gid: u16, sc: f32, out: *Path) !bool {
    return type3.glyphPath(a, font, gid, geom.Tf.row(sc, 0, 0, -sc, 0, 0), out);
}

/// A PDF renderer starts with the bundled last-resort font (Geist, `Renderer.ensureDefaultFonts`),
/// as takumi-pdf's. Should no font be registered at all (Geist unregistered by family name), the
/// text engine shapes nothing, so text would vanish without a trace. A frame whose paragraphs hold text other than white space then fails the render (or
/// measure), naming the first characters; `blank` (`uncoveredText: "blank"`) asked for nothing to
/// be drawn and keeps going.
pub fn requireFont(f: *const rt.Frame, blank: bool) rt.Error!void {
    if (blank) return;
    for (f.r.fonts.faces.items) |fc| if (fc.active) return;
    var u: Uncovered = .{};
    for (f.nodes.items) |n| {
        const p = n.para orelse continue;
        const t = rt.Frame.paragraphText(p);
        var i: usize = 0;
        while (i < t.len) {
            const d = uni.decodeUtf8(t, i);
            i += d.len;
            const cp = d.cp;
            if (cp <= 0x20 or cp == 0x7f or cp == 0x85 or cp == 0xa0 or (cp >= 0x2000 and cp <= 0x200a) or
                cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000 or uni.isZeroWidth(cp)) continue;
            try u.record(f.a, cp);
        }
    }
    if (try u.noFontMessage(f.a)) |msg| {
        f.r.setErr("", msg); // (as detail: a prefix is cut at 128 bytes)
        return error.Invalid;
    }
}

/// Which pass of a run the seam draws (takumi: `begin_shadow` / glyphs / `background-clip`
/// mask).
pub const Pass = union(enum) {
    /// the glyphs themselves
    text,
    /// one `text-shadow` (resolved colour, offset, blur radius)
    shadow: Shadow,
    /// `background-clip: text`: the fills seen through the glyphs (no own paint)
    clip_fills: []const GlyphBackground,
};

pub const FrameRunOptions = struct {
    filter: ?*const ed.ColorFilter = null,
    /// the page owns the run's line (pagination)
    owned: bool = true,
    /// fills painted through the glyphs before the text pass (`background-clip: text` of a
    /// containing box seen through this run)
    fills: []const GlyphBackground = &.{},
};

/// Byte offset where the cluster starting at `start` ends: the next cluster start of the
/// paragraph, cut after one character when the cluster is white space (collapsed white space is
/// dropped by bm-render's text engine but still lies between the cluster starts).
fn clusterEnd(text: []const u8, starts: []const u32, start: u32) u32 {
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (starts[mid] <= start) lo = mid + 1 else hi = mid;
    }
    var end: u32 = if (lo < starts.len) starts[lo] else @intCast(text.len);
    if (start < text.len) {
        const d = uni.decodeUtf8(text, start);
        const ws = d.cp == ' ' or d.cp == '\t' or d.cp == '\n' or d.cp == '\r' or d.cp == 0x0c;
        if (ws) end = @min(end, start + @as(u32, @intCast(d.len)));
        // a non-space cluster never takes the white space that follows it
        var i: usize = start;
        while (i < end) {
            const e = uni.decodeUtf8(text, i);
            if (i > start and (e.cp == ' ' or e.cp == '\t' or e.cp == '\n' or e.cp == '\r' or e.cp == 0x0c)) {
                end = @intCast(i);
                break;
            }
            i += e.len;
        }
    }
    return @max(end, start);
}

/// Sorted distinct cluster starts of a paragraph's shaped glyphs (cached per paragraph).
/// The paragraph text with the white space the text engine turns into spaces (segment breaks,
/// tabs, form feeds) written as U+0020, so a space glyph maps to " " as in takumi's collapsed
/// text (same byte offsets; cached per text).
fn sanitizedText(reg: *FontRegistry, a: Allocator, text: []const u8) ![]const u8 {
    if (reg.text_src.ptr == text.ptr and reg.text_src.len == text.len) return reg.text_clean;
    const t = try a.dupe(u8, text);
    for (t) |*ch| switch (ch.*) {
        '\n', '\r', '\t', 0x0c => ch.* = ' ',
        else => {},
    };
    reg.text_src = text;
    reg.text_clean = t;
    return t;
}

fn clusterStarts(reg: *FontRegistry, a: Allocator, para: *const font_mod.Paragraph) ![]const u32 {
    if (reg.cluster_para == @as(?*const anyopaque, para)) return reg.cluster_starts;
    var list: std.ArrayList(u32) = .empty;
    for (para.glyphs) |g| {
        if (g.flags & font_mod.ShapedGlyph.SPECIAL != 0) continue;
        try list.append(a, g.cluster);
    }
    std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
    var n: usize = 0;
    for (list.items) |v| {
        if (n > 0 and list.items[n - 1] == v) continue;
        list.items[n] = v;
        n += 1;
    }
    reg.cluster_para = para;
    reg.cluster_starts = list.items[0..n];
    return reg.cluster_starts;
}

/// The seam adapter: draws one painted run (`r`, from `render.RunIter` over `tl`) of paragraph
/// node `n` whose content box starts at `origin` (px, the surface's space), for `pass`.
/// `para_text` is the paragraph's text exactly as it was given to the text engine (the
/// concatenated, text-transformed run texts: glyph clusters are byte offsets into it).
/// Mirrors svg_out_text.zig's per-run data: the run style (`run_styles[glyph.user]`), its face,
/// size, fill (`-webkit-text-fill-color` / `color`), `-webkit-text-stroke`, `paint-order`,
/// faux bold / italic (face weight < 600 under weight >= 600; italic style on an upright face;
/// colour faces never synthesise). The run is split where the bidi direction changes (takumi's
/// runs never mix directions).
pub fn drawFrameRun(reg: *FontRegistry, s: *sf.Surface, f: *rt.Frame, n: *const rt.Node, tl: *const font_mod.TextLayout, r: rt.RunIter.Run, origin: [2]f32, para_text: []const u8, pass: Pass, o: FrameRunOptions) !void {
    const para = n.para orelse return;
    const all = tl.glyphs[@min(r.g0, tl.glyphs.len)..@min(r.g1, tl.glyphs.len)];
    if (all.len == 0) return;
    _ = para;
    var i: usize = 0;
    while (i < all.len) {
        var e = i + 1;
        while (e < all.len and (all[e].bidi_level & 1) == (all[i].bidi_level & 1)) e += 1;
        try drawSubRun(reg, s, f, n, all[i..e], r.baseline, origin, para_text, pass, o);
        i = e;
    }
}

/// Unicode Default_Ignorable_Code_Point (the ranges HarfBuzz hides).
fn defaultIgnorable(cp: u32) bool {
    return switch (cp) {
        0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0x3164, 0xFE00...0xFE0F, 0xFEFF, 0xFFA0, 0xFFF0...0xFFF8, 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0000...0xE0FFF => true,
        else => false,
    };
}

/// A default-ignorable character that continues the cluster before it in HarfBuzz
/// (`hb_set_unicode_props`): the zero-width joiner, and the marks among them (variation
/// selectors, the combining grapheme joiner, tag characters).
fn ignorableContinues(cp: u32) bool {
    return switch (cp) {
        0x200D, 0x034F, 0x180B...0x180D, 0x180F, 0xFE00...0xFE0F, 0xE0020...0xE007F, 0xE0100...0xE01EF => true,
        else => false,
    };
}

/// takumi shapes with HarfBuzz, which keeps a default-ignorable character (soft hyphen, zero-width
/// space / joiner, direction marks, variation selectors, U+FEFF) as a glyph: the font's space
/// glyph with no advance, in a cluster of its own unless the character continues the cluster
/// before it. bm-render's shaper drops the character and leaves its bytes at the end of the
/// cluster before it, which would give that cluster's glyph the character as text (ToUnicode
/// `a` -> `a` + U+200B, an /ActualText span around every plain `a`). This puts the invisible
/// glyphs back (a font without a space glyph gets none, as in HarfBuzz). In a right-to-left run
/// (glyphs in visual order) they go before the cluster, at its left edge: Persian `پ` + ZWNJ
/// maps `<067E>` and `<200C>` apart, so pdftotext extracts the ZWNJ after its letter.
fn hideIgnorables(a: Allocator, font: *const ttf.Font, size: f32, gs: []const font_mod.PositionedGlyph, shaped: []ShapedGlyph, text: []const u8) ![]ShapedGlyph {
    var any = false;
    for (shaped) |g| {
        var i: usize = g.start;
        while (i < g.end and i < text.len) {
            const d = uni.decodeUtf8(text, i);
            i += d.len;
            if (d.cp >= 0xAD and defaultIgnorable(d.cp)) any = true;
        }
    }
    if (!any) return shaped;
    const rtl = gs.len != 0 and gs[0].bidi_level & 1 != 0;
    const space = font.glyphIndex(' ');
    const hyphen = font.glyphIndex('-');
    const hyphen2 = font.glyphIndex(0x2010);
    const upm: f32 = @floatFromInt(@max(1, font.units_per_em));
    var out: std.ArrayList(ShapedGlyph) = .empty;
    var i: usize = 0;
    while (i < shaped.len) {
        var j = i + 1;
        while (j < shaped.len and shaped[j].start == shaped[i].start and shaped[j].end == shaped[i].end) j += 1;
        const st = shaped[i].start;
        const en = @min(shaped[i].end, @as(u32, @intCast(text.len)));
        // where the trailing run of default-ignorable characters starts
        var tail: u32 = st;
        var p: u32 = st;
        while (p < en) {
            const d = uni.decodeUtf8(text, p);
            p += @intCast(d.len);
            if (!defaultIgnorable(d.cp)) tail = p;
        }
        if (tail >= en or tail == st) {
            try out.appendSlice(a, shaped[i..j]);
            i = j;
            continue;
        }
        // the glyph a soft hyphen shows at a line break stays the hyphen's (takumi draws it as a
        // run of its own, without text)
        var base_end = j;
        const soft_break = j - i >= 2 and (shaped[j - 1].gid == hyphen or shaped[j - 1].gid == hyphen2) and shaped[j - 1].gid != 0 and uni.decodeUtf8(text, tail).cp == 0xAD;
        if (soft_break) base_end = j - 1;
        if (rtl and soft_break) {
            // (a right-to-left soft break keeps its hyphen glyph's mapping)
            try out.appendSlice(a, shaped[i..j]);
            i = j;
            continue;
        }
        // the pen after the cluster: where the next glyph of the run starts (right-to-left: the
        // cluster's left edge, the pen of its base glyph, the last one with an advance)
        const last = shaped[base_end - 1];
        const pen_x = if (rtl) blk: {
            var k = j;
            while (k > i) {
                k -= 1;
                if (font.advanceWidth(shaped[k].gid) != 0) break :blk shaped[k].x;
            }
            break :blk shaped[i].x;
        } else if (base_end < shaped.len) shaped[base_end].x else last.x + @as(f32, @floatFromInt(font.advanceWidth(last.gid))) * size / upm;
        const pen_y = shaped[i].y;
        const group0 = out.items.len;
        var first = out.items.len;
        try out.appendSlice(a, shaped[i..base_end]);
        var cur: [2]u32 = .{ st, tail };
        p = tail;
        while (p < en) {
            const d = uni.decodeUtf8(text, p);
            const next: u32 = p + @as(u32, @intCast(d.len));
            if (ignorableContinues(d.cp)) {
                cur[1] = next;
            } else {
                for (out.items[first..]) |*g| {
                    g.start = cur[0];
                    g.end = cur[1];
                }
                first = out.items.len;
                cur = .{ p, next };
            }
            if (space != 0) try out.append(a, .{ .gid = space, .x = pen_x, .y = pen_y, .start = 0, .end = 0 });
            p = next;
        }
        for (out.items[first..]) |*g| {
            g.start = cur[0];
            g.end = cur[1];
        }
        if (rtl) {
            // visual order: the invisible glyphs (last character first), then the cluster's own
            const added = out.items[group0 + (j - i) ..];
            std.mem.reverse(ShapedGlyph, added);
            std.mem.rotate(ShapedGlyph, out.items[group0..], j - i);
        }
        if (soft_break) {
            var h = shaped[j - 1];
            h.start = en;
            h.end = en;
            try out.append(a, h);
        }
        i = j;
    }
    return out.items;
}

/// takumi-pdf keys a font by the variation values the text asked for, not by the coordinates
/// they clamp to: text at two sizes beyond the range of an `opsz` axis draws from two font
/// objects with the same outlines, while `font-optical-sizing: none` (the axis default) shares
/// the font of text at the default size. The value asked for when it lies outside the axis
/// range (inside it the instance's coordinates differ already), as bits; 0 otherwise.
fn opszVariant(f: *rt.Frame, g0: *const font_mod.PositionedGlyph, font: *const ttf.Font) u32 {
    const ax = font.findAxis("opsz") orelse return 0;
    if (g0.user >= f.run_styles.items.len) return 0;
    const cs = f.run_styles.items[g0.user];
    var v: f32 = if (cs.font_optical_sizing != .none) cs.font_size else ax.default;
    for (cs.font_variation_settings) |fv| {
        if (std.mem.eql(u8, &fv.tag, "opsz")) v = fv.value;
    }
    if (!(v < ax.min or v > ax.max)) return 0;
    return @bitCast(v);
}

/// The krilla run of bm-render glyphs `gs` (one face and size): cluster ranges from the
/// paragraph's cluster starts; without the paragraph text, a stand-in text made of each glyph's
/// lowest cmap codepoint (so ToUnicode still maps simple text).
fn buildRun(reg: *FontRegistry, a: Allocator, f: *rt.Frame, para: ?*const font_mod.Paragraph, gs: []const font_mod.PositionedGlyph, text_in: []const u8) !?Run {
    const g0 = &gs[0];
    const face = f.r.fonts.face(g0.face);
    const font = &face.font;
    const size = g0.size;
    if (!(size > 0)) return null;
    const shaped = try a.alloc(ShapedGlyph, gs.len);
    var text = text_in;
    const variant = opszVariant(f, g0, font);
    if (text.len == 0) {
        const fc = try reg.container(font, face.index, variant);
        var t: std.ArrayList(u8) = .empty;
        for (gs, shaped) |g, *sg| {
            const st: u32 = @intCast(t.items.len);
            if (g.generated orelse try fc.cid.codepoint(g.gid)) |cp| {
                var b: [4]u8 = undefined;
                try t.appendSlice(a, b[0..ttf.encodeUtf8(cp, &b)]);
            }
            sg.* = .{ .gid = g.gid, .x = g.x, .y = g.y, .start = st, .end = @intCast(t.items.len) };
        }
        text = t.items;
    } else {
        const starts: []const u32 = if (para) |p| try clusterStarts(reg, a, p) else &.{};
        text = try sanitizedText(reg, a, text);
        for (gs, shaped) |g, *sg| {
            const st: u32 = @min(g.cluster, @as(u32, @intCast(text.len)));
            sg.* = .{ .gid = g.gid, .x = g.x, .y = g.y, .start = st, .end = clusterEnd(text, starts, st) };
        }
        const shown = try hideIgnorables(a, font, size, gs, shaped, text);
        const glyphs = try runGlyphs(a, reg.a, shown, size, text, &reg.uncovered);
        return .{ .font = .{ .font = font, .face_index = face.index, .variant = variant }, .glyphs = glyphs, .text = text, .size = size };
    }
    const glyphs = try runGlyphs(a, reg.a, shaped, size, text, &reg.uncovered);
    return .{ .font = .{ .font = font, .face_index = face.index, .variant = variant }, .glyphs = glyphs, .text = text, .size = size };
}

/// Whether the face has colour glyph tables (the last face asked about is remembered: a page asks
/// for every text run).
pub fn coloredFace(reg: *FontRegistry, font: *const ttf.Font) bool {
    if (comptime !enable_color_fonts) return false;
    if (reg.color_face) |k| if (k[0] == font.data.ptr and k[1] == font.head.ptr) return reg.color_has;
    reg.color_has = color_mod.ColorTables.init(font).hasColor();
    reg.color_face = .{ font.data.ptr, font.head.ptr };
    return reg.color_has;
}

fn drawSubRun(reg: *FontRegistry, s: *sf.Surface, f: *rt.Frame, n: *const rt.Node, gs: []const font_mod.PositionedGlyph, baseline: f32, origin: [2]f32, text: []const u8, pass: Pass, o: FrameRunOptions) !void {
    const g0 = &gs[0];
    const rs = f.run_styles.items;
    const rcs = if (g0.user < rs.len) rs[g0.user] else n.cs;
    if (rcs.visibility != .visible) return;
    const run = (try buildRun(reg, s.cx.work(), f, n.para, gs, text)) orelse return;
    const face = f.r.fonts.face(g0.face);
    const colored_face = coloredFace(reg, &face.font);
    const fill_col = if (rcs.webkit_text_fill_color) |c| rcs.resolveColor(c) else rcs.color;
    const p: RunPaint = .{
        .color = fill_col,
        .stroke_width = rcs.webkit_text_stroke_width,
        .stroke_color = rcs.resolveColor(rcs.webkit_text_stroke_color),
        .stroke_first = rcs.paint_order == .stroke,
        .synthetic_bold = if (!colored_face and rcs.font_synthesis.weight and rcs.font_weight >= 600 and face.weight < 600) ptext.emboldenWidth(run.size) else null,
        .synthetic_skew = if (!colored_face and rcs.font_synthesis.style and rcs.font_style != .normal and !face.italic) synthetic_italic_skew else null,
        .baseline = baseline,
        .owned = o.owned,
        .filter = o.filter,
    };
    switch (pass) {
        .text => try paintGlyphRun(reg, s, run, origin, p, null, o.fills, true),
        .shadow => |sh| try paintGlyphRun(reg, s, run, origin, p, sh, &.{}, true),
        .clip_fills => |fl| try paintGlyphRun(reg, s, run, origin, p, null, fl, false),
    }
}

/// The adapter for emit_text.zig's seam (`emitTextRun(e, run: *const TextRun)`):
///   `try text.drawSeamRun(e.fonts, e.s, e.f, run);`
/// `run` is that `TextRun` (read by field name: node, glyphs, x, y, text, baseline, fill, stroke,
/// stroke_first, synthetic_bold, synthetic_italic, shadow, owned, fills, with_paint). Its colours
/// are already filtered; `x` / `y` is the unshifted origin, a shadow pass carries its offset,
/// blur and colour in `shadow` (`fill` stays the text colour: the context colour of colour
/// glyph silhouettes). The run is split where the bidi direction changes. Empty `text`: a
/// stand-in text from the glyphs' cmap codepoints.
pub fn drawSeamRun(reg: *FontRegistry, s: *sf.Surface, f: *rt.Frame, run: anytype) !void {
    const all: []const font_mod.PositionedGlyph = run.glyphs;
    if (all.len == 0) return;
    const origin = [2]f32{ run.x, run.y };
    var shadow: ?Shadow = null;
    if (run.shadow) |sh| shadow = .{ .color = sh.color, .x = sh.dx, .y = sh.dy, .blur = sh.blur };
    // (transparent text is still drawn, at fill opacity 0: it stays selectable, as in takumi)
    if (shadow == null and !run.with_paint and run.fills.len == 0) return;
    var i: usize = 0;
    while (i < all.len) {
        var e = i + 1;
        while (e < all.len and (all[e].bidi_level & 1) == (all[i].bidi_level & 1) and all[e].generated == all[i].generated) e += 1;
        const gs = all[i..e];
        i = e;
        const r = (try buildRun(reg, s.cx.work(), f, run.node.para, gs, if (gs[0].generated != null) "" else run.text)) orelse continue;
        var p: RunPaint = .{
            .color = run.fill,
            .stroke_first = run.stroke_first,
            .synthetic_bold = if (run.synthetic_bold > 0) run.synthetic_bold else null,
            .synthetic_skew = if (run.synthetic_italic) synthetic_italic_skew else null,
            .baseline = run.baseline,
            .owned = run.owned,
        };
        if (run.stroke) |st| {
            p.stroke_width = st.width;
            p.stroke_color = st.color;
        }
        try paintGlyphRun(reg, s, r, origin, p, shadow, if (shadow == null) run.fills else &.{}, run.with_paint);
    }
}

/// The resolved `text-shadow`s of a style, painted last-to-first (CSS order: the first shadow
/// is on top).
pub fn textShadow(cs: *const rt.CS, i: usize) Shadow {
    const sh = cs.text_shadow[i];
    return .{ .color = cs.resolveColor(sh.color), .x = sh.x, .y = sh.y, .blur = sh.blur };
}

test {
    _ = @import("text_tests.zig");
}
