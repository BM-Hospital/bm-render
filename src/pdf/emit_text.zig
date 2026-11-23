//! Text of the PDF emitter: everything a paragraph paints except the glyphs themselves, plus the
//! one seam the glyph emission (font subsetting, `Tj`/`TJ`, ToUnicode) plugs into:
//!
//! * inline box fragments (`<span>` backgrounds, borders), as the painter / svg_out_text.zig;
//! * text decorations (underline / overline / line-through: solid and double as filled rects,
//!   dotted / dashed as stroked dashed lines, wavy as a stroked curve, skip-ink cuts from the
//!   painter's glyph coverage), through the paint device;
//! * glyph runs (`emitTextRun`): one call per run of one face / size, per text-shadow pass, with
//!   everything takumi-pdf's `paint_glyph_run` needs, drawn by text.zig (`drawSeamRun`: font
//!   subsetting, `BT .. TJ .. ET`, ToUnicode, Type3 colour glyphs); with `debug_glyph_outlines`
//!   the glyph outlines are filled as plain paths instead;
//! * pagination: a run is drawn on a page that shows its line (takumi-pdf window.rs
//!   `shows_line_item`), as text only on the page that owns the line (`disowns_line`: the page
//!   holding its baseline), as outlines on the others;
//! * `background-clip: text` (`paintClipText`): the box's background fills seen through the glyphs
//!   of its subtree (takumi `fill_text_clip`).
const std = @import("std");
const render = @import("../render.zig");
const style = @import("../style/style.zig");
const font = @import("../font/font.zig");
const raster = @import("../raster/raster.zig");
const pm = @import("../paint.zig");
const ptext = @import("../paint_text.zig");
const pborder = @import("../paint_border.zig");
const emit = @import("emit.zig");
const border = @import("emit_border.zig");
const dev = @import("emit_device.zig");
const sf = @import("emit_surface.zig");
const text = @import("text.zig");
const etag = @import("emit_tag.zig"); // [tagging]
const markers = @import("markers.zig");

const Emitter = emit.Emitter;
const Node = render.Node;
const CS = render.CS;
const none = render.none;
const Rect = raster.Rect;
const Affine = raster.Affine;
const Path = raster.Path;
const Error = render.Error;
const Color = style.Color;

/// Fill glyph outlines as plain paths (no text layer, no fonts) instead of real text (debugging).
pub const debug_glyph_outlines = false;

// ---------------------------------------------------------------------------------------------
// THE TEXT SEAM
// ---------------------------------------------------------------------------------------------

/// A `-webkit-text-stroke`.
pub const TextStroke = struct { width: f32, color: Color };

/// A `text-shadow` pass: the run drawn again, offset, in the shadow colour `color` (after colour
/// filters; takumi-pdf `TextDevice` with `shadow` set; a blur steps through `Band`s like box
/// shadows).
pub const ShadowPass = struct { dx: f32, dy: f32, blur: f32, color: Color };

/// One glyph run as takumi-pdf's `paint_glyph_run` receives it (krilla `draw_glyphs` input).
pub const TextRun = struct {
    /// the text node / paragraph owner, and the run's own style (a `<span>`'s inside a paragraph)
    node: *const Node,
    style: *const CS,
    /// bm-render font registry face (`Renderer.fonts.font(face)`: the sfnt to subset) and size
    face: font.FaceId,
    size: f32,
    /// the run's glyphs: one face and size, in visual order (both bidi directions possible). `gid` is the glyph id in `face`;
    /// (`x`, `y`) the glyph origin on the baseline in paragraph space (px, y down), so glyph i
    /// lands at (`x + glyphs[i].x`, `y + glyphs[i].y`) in the current user space (CSS px; the
    /// surface's transform maps it to the page); `cluster` is the byte offset of its source
    /// character in the paragraph's concatenated run texts (`text` below, when known); `user`
    /// indexes `Frame.run_styles`.
    glyphs: []const font.PositionedGlyph,
    x: f32,
    y: f32,
    /// the paragraph's source text the clusters index (ToUnicode / ActualText;
    /// `Frame.paragraphText`); empty: a stand-in from the glyphs' cmap codepoints
    text: []const u8 = "",
    /// the run's baseline (paragraph space, px): the faux oblique shears about it
    baseline: f32 = 0,
    /// fill colour after colour filters (`-webkit-text-fill-color` or `color`); alpha 0 = no fill.
    /// Also in a shadow pass (colour glyph silhouettes take it as their context colour).
    fill: Color,
    /// `-webkit-text-stroke` after colour filters (null: none)
    stroke: ?TextStroke = null,
    /// `paint-order: stroke ...`: the stroke pass goes under the fill
    stroke_first: bool = false,
    /// synthetic bold: an extra stroke of this width in the fill colour (0 = none)
    synthetic_bold: f32 = 0,
    /// synthetic oblique: shear by -0.25 about the run's baseline
    synthetic_italic: bool = false,
    /// a colour (COLR / bitmap) glyph run: drawn as the font paints it, not stroked
    colored: bool = false,
    /// set for a text-shadow pass; (`x`, `y`) is then the unshifted origin
    shadow: ?ShadowPass = null,
    /// this page owns the run's line (its text belongs in this page's text layer); false =
    /// outlines only (a line cut by the page edge, drawn as text on the page that owns it)
    owned: bool = true,
    /// `background-clip: text` fills painted through the glyphs (before the glyphs' own paint)
    fills: []const text.GlyphBackground = &.{},
    /// draw the glyphs' own paint (false: the fills only, a `background-clip: text` pass)
    with_paint: bool = true,
};

/// THE TEXT SEAM: draws one glyph run onto `e.s` (the current surface) with the document's font
/// registry `e.fonts` (text.zig `drawSeamRun`: krilla `draw_glyphs` through takumi-pdf's
/// `paint_glyph_run`).
pub fn emitTextRun(e: *Emitter, run: *const TextRun) Error!void {
    if (comptime !debug_glyph_outlines) return text.drawSeamRun(e.fonts, e.s, e.f, run) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            e.fail("PDF text error: ", @errorName(err));
            return;
        },
    };
    if (run.colored or !run.with_paint) return;
    const fnt = e.f.r.fonts.font(run.face);
    var path: Path = .empty;
    var ox = run.x;
    var oy = run.y;
    if (run.shadow) |sh| {
        ox += sh.dx;
        oy += sh.dy;
    }
    for (run.glyphs) |*g| {
        var sink: raster.PathSink = .{ .path = &path, .alloc = e.a, .transform = if (run.synthetic_italic) .{ .c = -0.25 } else Affine.identity };
        const base = path.points.items.len;
        _ = font.emitGlyph(fnt, g.gid, run.size, 0, 0, &sink);
        if (sink.err) return error.OutOfMemory;
        for (path.points.items[base..]) |*q| {
            q.x += ox + g.x;
            q.y += oy + g.y;
        }
    }
    if (path.isEmpty()) return;
    const col = if (run.shadow) |sh| sh.color else run.fill;
    if (col.a != 0) e.d.fillPath(&path, 0, 0, .nonzero, col);
    if (run.stroke) |st| e.d.strokePath(&path, 0, 0, st.width, null, false, if (run.shadow) |sh| sh.color else st.color);
}

// ---------------------------------------------------------------------------------------------
// paragraphs (painter `paintText`, svg_out_text.zig)
// ---------------------------------------------------------------------------------------------

const Synth = struct { italic: bool, bold: bool, colored: bool };

fn synthOf(e: *Emitter, rcs: *const CS, g: *const font.PositionedGlyph) Synth {
    const fc = e.f.r.fonts.face(g.face);
    // (font-synthesis: a face is emboldened / slanted only where the style allows it)
    var sy: Synth = .{ .italic = rcs.font_synthesis.style and rcs.font_style != .normal and !fc.italic, .bold = rcs.font_synthesis.weight and rcs.font_weight >= 600 and fc.weight < 600, .colored = false };
    if (comptime pm.enable_color_fonts) {
        const color = @import("../font/color.zig");
        if (color.glyphKind(&fc.font, g.gid) != .none) sy = .{ .italic = false, .bold = false, .colored = true };
    }
    return sy;
}

fn runStyle(e: *Emitter, n: *const Node, g: *const font.PositionedGlyph) *const CS {
    const rs = e.f.run_styles.items;
    return if (g.user < rs.len) rs[g.user] else n.cs;
}

const Metrics = struct { ascent: f32, descent: f32, ul_pos: f32, ul_thick: f32, em_descent: f32 };

fn metricsOf(e: *Emitter, face: font.FaceId, size: f32) Metrics {
    const fnt = e.f.r.fonts.font(face);
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

const RunSeg = struct { g0: u32, g1: u32, x0: f32, x1: f32, baseline: f32, rcs: *const CS };

/// How a run is drawn on this page (pagination, `background-clip: text`).
const PassOpts = struct {
    shadow: ?ShadowPass = null,
    owned: bool = true,
    fills: []const text.GlyphBackground = &.{},
    with_paint: bool = true,
};

/// Whether the face paints its own colours (colour faces never synthesise bold / oblique).
fn coloredFace(e: *Emitter, face: font.FaceId) bool {
    if (comptime !pm.enable_color_fonts) return false;
    const color = @import("../font/color.zig");
    return color.ColorTables.init(&e.f.r.fonts.face(face).font).hasColor();
}

/// Hands `glyphs[g0..g1]` (one face: a takumi `ShapedRun`) to the seam, split only where the
/// size changes. Synthesis is the run's (face and style), as in takumi: colour and outline
/// glyphs of one run stay in one text object (the seam switches fonts inside it).
fn glyphPass(e: *Emitter, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32, run: *const RunSeg, o: PassOpts) Error!void {
    const rcs = run.rcs;
    const fill_raw = if (rcs.webkit_text_fill_color) |c| rcs.resolveColor(c) else rcs.color;
    const sw = rcs.webkit_text_stroke_width;
    const scol = rcs.resolveColor(rcs.webkit_text_stroke_color);
    const para_text = if (n.para) |pp| render.Frame.paragraphText(pp) else "";
    // the line's overflow marker is a run of its own whose text is its glyphs' characters, not
    // the hidden text it stands in for (takumi-pdf draws it as a separate text run)
    var mk0: u32 = 0;
    var mk1: u32 = 0;
    if (lineOf(tl, run.g0)) |li| {
        mk0 = tl.lines[li].marker0;
        mk1 = tl.lines[li].marker1;
    }
    // An RTL overflow marker is visually first but follows the surviving content in
    // logical paint/text order, just as a line's final ellipsis item does in Takumi.
    const marker_prefix = mk1 > mk0 and run.g0 == mk0 and mk1 <= run.g1;
    var marker_pending = marker_prefix;
    var i = if (marker_prefix) mk1 else run.g0;
    while (i < run.g1 or marker_pending) {
        if (i >= run.g1) {
            i = run.g0;
            marker_pending = false;
        }
        const g0 = &tl.glyphs[i];
        const in_marker = i >= mk0 and i < mk1;
        const stop = if (in_marker) mk1 else if (mk1 > mk0 and i < mk0) mk0 else run.g1;
        var j = i + 1;
        while (j < run.g1 and j < stop and tl.glyphs[j].size == g0.size) j += 1;
        const fc = e.f.r.fonts.face(g0.face);
        const colored = coloredFace(e, g0.face);
        const syn = if (in_marker) n.cs else rcs;
        const tr: TextRun = .{
            .node = n,
            .style = rcs,
            .face = g0.face,
            .size = g0.size,
            .glyphs = tl.glyphs[i..j],
            .x = x,
            .y = y,
            .text = if (o.with_paint and !in_marker) para_text else "",
            .baseline = run.baseline,
            .fill = dev.filtered(e.filter, fill_raw),
            // (a transparent stroke keeps its width: `background-clip: text` strokes the background
            // with it, takumi `background_stroke`; the stroke itself draws nothing, `text_stroke`)
            .stroke = if (sw > 0) .{ .width = sw, .color = dev.filtered(e.filter, scol) } else null,
            .stroke_first = rcs.paint_order == .stroke,
            // (the marker is shaped with the block's font, takumi `LineTruncator`: its paint
            // comes from the last item, its synthesis from the block style it was shaped for)
            .synthetic_bold = if (!colored and syn.font_synthesis.weight and syn.font_weight >= 600 and fc.weight < 600) ptext.emboldenWidth(g0.size) else 0,
            .synthetic_italic = !colored and syn.font_synthesis.style and syn.font_style != .normal and !fc.italic,
            .colored = colored,
            .shadow = if (o.shadow) |sh| .{ .dx = sh.dx, .dy = sh.dy, .blur = sh.blur, .color = dev.filtered(e.filter, sh.color) } else null,
            .owned = o.owned,
            .fills = o.fills,
            .with_paint = o.with_paint,
        };
        try emitTextRun(e, &tr);
        i = j;
        if (marker_prefix and !marker_pending) break;
    }
}

// ---- pagination (takumi-pdf window.rs)

/// A run or line on its line (takumi-core `LineItem`), in the frame's coordinates.
const LineItem = struct { baseline: f32, top: f32, bottom: f32, l0: f32, l1: f32 };

/// The line box index holding glyph `gi`.
fn lineOf(tl: *const font.TextLayout, gi: u32) ?usize {
    for (tl.lines, 0..) |ln, k| {
        if (gi >= ln.glyph_start and gi < ln.glyph_end) return k;
    }
    return null;
}

/// `it` (current user space) in frame coordinates: through the walk's transform when one is open,
/// its extent across the horizontal span `x0..x1` and its baseline at the span's middle
/// (takumi `LineFrame::map`).
fn mapItem(e: *const Emitter, it: LineItem, x0: f32, x1: f32) LineItem {
    if (e.tf.isIdentity()) return it;
    const t = e.tf;
    const yAt = struct {
        fn f(m: Affine, px: f32, py: f32) f32 {
            return m.b * px + m.d * py + m.f;
        }
    }.f;
    const ext = struct {
        fn f(m: Affine, a: f32, b: f32, top: f32, bottom: f32) [2]f32 {
            const c = [4]f32{ yAt(m, a, top), yAt(m, b, top), yAt(m, a, bottom), yAt(m, b, bottom) };
            return .{ @min(@min(c[0], c[1]), @min(c[2], c[3])), @max(@max(c[0], c[1]), @max(c[2], c[3])) };
        }
    }.f;
    const span = e.line_span orelse [2]f32{ x0, x1 };
    const tb = ext(t, span[0], span[1], it.top, it.bottom);
    const lb = ext(t, span[0], span[1], it.l0, it.l1);
    return .{ .baseline = yAt(t, (span[0] + span[1]) / 2, it.baseline), .top = tb[0], .bottom = tb[1], .l0 = lb[0], .l1 = lb[1] };
}

/// takumi `Window::disowns`: the line belongs to another page.
fn disowns(e: *const Emitter, it: LineItem) bool {
    // If overflow clips away the baseline, the visible part of the item owns its text.
    // Otherwise a line cut at a page edge can disappear from every page's text layer.
    const height = if (it.baseline < e.clip_y[0] or it.baseline >= e.clip_y[1])
        (@max(it.top, e.clip_y[0]) + @min(it.bottom, e.clip_y[1])) / 2
    else
        it.baseline;
    return height < e.window.lines_top or height >= e.window.lines_bottom;
}

/// takumi `Window::shows_line_item`: this page draws the item (on the page owning its line, and
/// on every other page its line box reaches), unless the overflow clips around it cut it away
/// (`Emitter.clip_y`, takumi's narrowed window).
fn showsItem(e: *const Emitter, it: LineItem) bool {
    if (e.clipExcludes(it.top, it.bottom)) return false;
    return !e.window.excludes(it.top, it.bottom) and (!disowns(e, it) or !e.window.excludes(it.l0, it.l1));
}

/// The line item of a run of `tl` at content origin `y` (current user space, mapped to the frame).
fn runItem(e: *Emitter, tl: *const font.TextLayout, x: f32, y: f32, r: anytype) LineItem {
    const g0 = &tl.glyphs[r.g0];
    const m = metricsOf(e, g0.face, g0.size);
    const base = y + r.baseline;
    var it: LineItem = .{ .baseline = base, .top = base - m.ascent, .bottom = base + m.descent, .l0 = base - m.ascent, .l1 = base + m.descent };
    if (lineOf(tl, r.g0)) |k| {
        const ln = tl.lines[k];
        it.l0 = y + ln.top;
        it.l1 = y + ln.top + ln.height;
    }
    return mapItem(e, it, x + r.x0, x + r.x1);
}

/// Whether this page shows the run (and as text: `owned`). Unpaginated windows show everything.
fn runOnPage(e: *Emitter, tl: *const font.TextLayout, x: f32, y: f32, r: anytype) struct { shows: bool, owned: bool } {
    if (!e.window.paged()) return .{ .shows = true, .owned = true };
    const it = runItem(e, tl, x, y, r);
    return .{ .shows = showsItem(e, it), .owned = !disowns(e, it) };
}

// ---- decorations (painter geometry, svg_out_text.zig)

const DecoKind = enum { underline, overline, line_through };
const Span = struct { a: f32, b: f32 };

/// Strokes the centre line `path`, through one clip of every piece the skip-ink cuts leave
/// (`y`, `h`: the band of the clip rectangles).
fn strokeLine(e: *Emitter, sh: ?ShadowPass, path: *const Path, width: f32, dash: ?pborder.Dash, col: Color, pieces: ?[]const Span, y: f32, h: f32) Error!void {
    const depth0 = e.d.depth();
    defer e.d.restore(depth0);
    const dx: f32 = if (sh) |v| v.dx else 0;
    const dy: f32 = if (sh) |v| v.dy else 0;
    if (pieces) |ps| {
        var clip: Path = .empty;
        for (ps) |pc| try clip.addRect(e.a, .{ .x = pc.a, .y = y, .w = pc.b - pc.a, .h = h });
        // (a clip opened inside a shadow moves with it: takumi `shadow_moved`)
        e.d.pushClip(&clip, dx, dy, .nonzero);
    }
    const ds: ?[2]f32 = if (dash) |d| .{ d.on, d.off } else null;
    const round = if (dash) |d| d.round else false;
    const v = sh orelse return e.d.strokePath(path, 0, 0, width, ds, round, col);
    shadowBands(e, v, struct {
        fn draw(em: *Emitter, c: Color, spread: f32, pth: *const Path, w0: f32, ox: f32, oy: f32, d: ?[2]f32, r: bool) void {
            em.d.strokePath(pth, ox, oy, w0 + spread, d, r, c);
        }
    }.draw, .{ path, width, dx, dy, ds, round });
}

/// takumi `TextDevice::in_shadow_bands`: `draw` once in the shadow colour, or, for a blurred
/// shadow, once per band (an opacity group each, the spread passed on; a translucent colour in an
/// outer group).
fn shadowBands(e: *Emitter, sh: ShadowPass, comptime draw: anytype, args: anytype) void {
    if (!(sh.blur > 0)) return @call(.auto, draw, .{ e, sh.color, @as(f32, 0) } ++ args);
    var opaque_col = sh.color;
    opaque_col.a = 255;
    const translucent = sh.color.a < 255;
    if (translucent) e.d.beginLayer(@as(f32, @floatFromInt(sh.color.a)) / 255.0);
    var buf: [9]emit.Band = undefined;
    for (emit.bandsOf(sh.blur, &buf)) |b| {
        e.d.beginLayer(b.alpha);
        @call(.auto, draw, .{ e, opaque_col, 2 * b.spread } ++ args);
        e.d.endLayer();
    }
    if (translucent) e.d.endLayer();
}

/// A decoration rectangle, or its shadow (takumi `TextDevice::fill_shape`: in the shadow colour,
/// moved by its offset; a blurred one stroked by each band's spread as well).
fn decoFill(e: *Emitter, sh: ?ShadowPass, r: Rect, col: Color) Error!void {
    const v = sh orelse return e.d.fillRRect(r, null, col);
    const rr: Rect = .{ .x = r.x + v.dx, .y = r.y + v.dy, .w = r.w, .h = r.h };
    var path: Path = .empty;
    try path.addRect(e.a, rr);
    shadowBands(e, v, struct {
        fn draw(em: *Emitter, c: Color, spread: f32, rect: Rect, pth: *const Path) void {
            em.d.fillRRect(rect, null, c);
            if (spread > 0) em.d.strokePath(pth, 0, 0, spread, null, false, c);
        }
    }.draw, .{ rr, &path });
}

fn paintDecoLine(e: *Emitter, sh: ?ShadowPass, kind: DecoKind, st: style.computed.DecorationStyle, col: Color, x0: f32, x1: f32, top: f32, thickness: f32, cuts: []const Span) Error!void {
    if (col.a == 0 or !(x1 > x0)) return;
    const h = @max(1, @floor(thickness));
    var pieces: [33]Span = undefined;
    // (what skip-ink leaves of the line's bounds: a dotted / dashed line's run between its snapped
    // ends, takumi `DecorationLine::pieces` of `bounds`)
    const dashed_line = st == .dotted or st == .dashed;
    const np = piecesOf(cuts, if (dashed_line) @floor(x0) else x0, if (dashed_line) @floor(x1) else x1, &pieces);
    const second: f32 = switch (kind) {
        .underline => thickness + 1,
        .overline => -(thickness + 1),
        .line_through => @floor(thickness + 1),
    };
    const a = e.a;
    var path: Path = .empty;
    switch (st) {
        .solid, .double => {
            // (the pieces of the first line, then those of the second, takumi `DecorationLine::fill`)
            for (pieces[0..np]) |pc| try decoFill(e, sh, .{ .x = pc.a, .y = @floor(top + 0.5), .w = pc.b - pc.a, .h = h }, col);
            if (st == .double) for (pieces[0..np]) |pc| try decoFill(e, sh, .{ .x = pc.a, .y = @floor(top + second + 0.5), .w = pc.b - pc.a, .h = h }, col);
        },
        .dotted, .dashed => {
            const start = @floor(x0);
            const end = @floor(x1);
            const row = @floor(top + @max(thickness / 2, 0.5));
            const t = @max(1, @round(thickness));
            // an odd thickness (`t` is a whole number >= 1; every f32 from 2^24 up is even), tested on the
            // integer: `@mod(t, 2)` compiles to a fused multiply-add on arm64 (`t - 2 * trunc(t / 2)`: exact, so
            // the result is the same, but scripts/build-native.mjs counts every fused instruction)
            const odd = t < 16777216 and (@as(u32, @intFromFloat(t)) & 1) == 1;
            const yl = if (odd) row + 0.5 else row;
            const dash = pborder.dashPattern(if (st == .dotted) .dotted else .dashed, t, end - start, false);
            var la = start;
            var lb = end;
            if (dash != null and dash.?.round) {
                la += t / 2;
                lb -= t / 2;
            }
            if (!(lb > la)) return;
            try path.moveTo(a, la, yl);
            try path.lineTo(a, lb, yl);
            if (cuts.len == 0) return strokeLine(e, sh, &path, t, dash, col, null, 0, 0);
            try strokeLine(e, sh, &path, t, dash, col, pieces[0..np], row - t / 2 - 1, t + 2);
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
            var xx = x0 - wl;
            try path.moveTo(a, xx, yy);
            var guard: u32 = 0;
            while (xx < x1 + wl and guard < 20000) : (guard += 1) {
                try path.cubicTo(a, xx + wl / 2, yy + cpd, xx + wl / 2, yy - cpd, xx + wl, yy);
                xx += wl;
            }
            try strokeLine(e, sh, &path, thickness, null, col, pieces[0..np], ctop, cbot - ctop);
        },
    }
}

/// Where a run's decorations end (takumi: the run's origin plus its advance, unsnapped): its last
/// glyph's pen position when the text engine kept it, else the start of what follows it.
fn runRight(tl: *const font.TextLayout, run: *const RunSeg) f32 {
    if (run.g1 == 0 or run.g1 > tl.glyphs.len) return run.x1;
    const end = tl.glyphs[run.g1 - 1].x_end;
    return if (std.math.isFinite(end) and end >= run.x0) end else run.x1;
}

/// The spans of `left`..`right` the skip-ink `cuts` leave (takumi `remaining_spans`).
fn piecesOf(cuts: []const Span, left: f32, right: f32, out: *[33]Span) usize {
    var np: usize = 0;
    var cur = left;
    for (cuts) |c| {
        if (np >= out.len - 1) break;
        if (c.a > cur) {
            out[np] = .{ .a = cur, .b = @min(c.a, right) };
            np += 1;
        }
        cur = @max(cur, c.b);
        if (cur >= right) break;
    }
    if (cur < right) {
        out[np] = .{ .a = cur, .b = right };
        np += 1;
    }
    return np;
}

fn paintRunDecos(e: *Emitter, sh: ?ShadowPass, tl: *const font.TextLayout, x: f32, y: f32, run: *const RunSeg, decos: []const *const CS, after: bool) Error!void {
    const g0 = &tl.glyphs[run.g0];
    const tm = metricsOf(e, g0.face, g0.size);
    const text_top = y + run.baseline - tm.ascent;
    for (decos) |dcs| {
        const dl = dcs.text_decoration_line;
        // (in a `background-clip: text` mask: opaque black, whatever the colour, takumi `paint_mask`)
        const col: Color = if (e.d.through != null) .{ .r = 0, .g = 0, .b = 0, .a = 255 } else dcs.resolveColor(dcs.text_decoration_color);
        const dm = metricsOf(e, g0.face, dcs.font_size);
        const auto = dcs.font_size / 10.0;
        // (`from-font`: the font's underline thickness, unrounded, takumi `BoxFont::thickness`)
        const thickness = @max(1, if (dcs.text_decoration_thickness) |v| @round(v) else if (dcs.text_decoration_from_font and dm.ul_thick > 0) dm.ul_thick else auto);
        const box_top = y + run.baseline - dm.ascent;
        const off = if (dcs.text_underline_offset) |o| o else 0;
        const lx0 = x + run.x0;
        const lx1 = x + runRight(tl, run);
        if (after) {
            if (dl.line_through) try paintDecoLine(e, sh, .line_through, dcs.text_decoration_style, col, lx0, lx1, text_top + 2 * dm.ascent / 3 - thickness / 2, thickness, &.{});
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
                if (dcs.text_decoration_skip_ink != .none and e.plain()) nc = skipInk(e, tl, x, y, run, top, thickness, dcs.text_decoration_style, kind == .underline, &cuts);
                try paintDecoLine(e, sh, kind, dcs.text_decoration_style, col, lx0, lx1, top, thickness, cuts[0..nc]);
            }
        }
    }
}

/// Ink intercepts of the run's glyphs with the decoration band (takumi `skip_ink_ranges`: each glyph's
/// outline flattened, nonzero-filled spans along 9 scanlines across the band inset by 0.5 px, dilated
/// by the thickness up to 13 px), each cut snapped to whole device pixels (CSS px) as Blink's
/// `ClipOut` (takumi `DecorationLine::device_pixel_x`).
fn skipInk(e: *Emitter, tl: *const font.TextLayout, x: f32, y: f32, run: *const RunSeg, top: f32, thickness: f32, st: style.computed.DecorationStyle, underline: bool, out: *[32]Span) usize {
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
    // (nothing to skip when the band is no taller than the 2 x 0.5 px inset, i.e. a decoration up to
    // 1 px thick)
    if (!(b1 - b0 > 0)) return 0;
    const grow = @min(thickness, 13);
    var spans: std.ArrayList(Span) = .empty;
    var path: Path = .empty;
    for (tl.glyphs[run.g0..run.g1]) |*g| {
        const sy = synthOf(e, run.rcs, g);
        if (sy.colored) continue;
        const fnt = e.f.r.fonts.font(g.face);
        const sc = g.size / @as(f32, @floatFromInt(@max(1, fnt.units_per_em)));
        // (glyph space: px from the origin, y down)
        const drawn = text.glyphOutlinePx(e.a, fnt, g.gid, sc, &path) catch return 0;
        if (!drawn) continue;
        const ox = x + g.x;
        const oy = y + g.y;
        const n0 = spans.items.len;
        intercepts(e.a, &path, b0 - oy, b1 - oy, &spans) catch return 0;
        for (spans.items[n0..]) |*sp| sp.* = .{ .a = ox + sp.a - grow, .b = ox + sp.b + grow };
    }
    mergeSpans(spans.items);
    // whole device pixels: the page transform back in CSS px (takumi `TextDevice::transform`:
    // `scale(1 / 0.75) * page_transform`), unrotated and unskewed only
    const m = e.s.bd().ctmRoot();
    const k: f32 = 1.0 / 0.75;
    const da = k * m.sx;
    const dx = k * m.tx;
    var nc: usize = 0;
    for (spans.items) |sp| {
        if (sp.a > sp.b) continue;
        if (nc >= out.len) break;
        out[nc] = if (m.ky == 0 and m.kx == 0 and da != 0) .{ .a = (@floor(da * sp.a + dx + 0.5) - dx) / da, .b = (@floor(da * sp.b + dx + 0.5) - dx) / da } else sp;
        nc += 1;
    }
    return nc;
}

/// takumi `text_intercepts`: the x spans `path` fills (nonzero winding) along 9 scanlines from
/// `top` to `bottom`, appended to `out` (unmerged).
fn intercepts(a: std.mem.Allocator, path: *const Path, top: f32, bottom: f32, out: *std.ArrayList(Span)) !void {
    if (!(bottom > top)) return;
    // takumi `reaches_band`: any point, control points included, in the band
    var lo = std.math.inf(f32);
    var hi = -std.math.inf(f32);
    for (path.points.items) |pt| {
        lo = @min(lo, pt.y);
        hi = @max(hi, pt.y);
    }
    if (!(hi >= top and lo <= bottom)) return;
    // takumi `flatten`: straight edges, curves in 16 steps, every contour closed
    const Edge = struct { ax: f32, ay: f32, bx: f32, by: f32 };
    var edges: std.ArrayList(Edge) = .empty;
    const pts = path.points.items;
    var k: usize = 0;
    var sx: f32 = 0;
    var sy: f32 = 0;
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (path.verbs.items) |v| switch (v) {
        .move => {
            if (cx != sx or cy != sy) try edges.append(a, .{ .ax = cx, .ay = cy, .bx = sx, .by = sy });
            sx = pts[k].x;
            sy = pts[k].y;
            cx = sx;
            cy = sy;
            k += 1;
        },
        .line => {
            try edges.append(a, .{ .ax = cx, .ay = cy, .bx = pts[k].x, .by = pts[k].y });
            cx = pts[k].x;
            cy = pts[k].y;
            k += 1;
        },
        .quad, .cubic => {
            const cubic = v == .cubic;
            const c1 = pts[k];
            const c2 = if (cubic) pts[k + 1] else pts[k];
            const to = if (cubic) pts[k + 2] else pts[k + 1];
            k += if (cubic) 3 else 2;
            var step: u32 = 1;
            while (step <= 16) : (step += 1) {
                const t = @as(f32, @floatFromInt(step)) / 16.0;
                const inv = 1.0 - t;
                var nx: f32 = undefined;
                var ny: f32 = undefined;
                if (cubic) {
                    const w0 = inv * inv * inv;
                    const w1 = 3.0 * inv * inv * t;
                    const w2 = 3.0 * inv * t * t;
                    const w3 = t * t * t;
                    nx = w0 * cx + w1 * c1.x + w2 * c2.x + w3 * to.x;
                    ny = w0 * cy + w1 * c1.y + w2 * c2.y + w3 * to.y;
                } else {
                    nx = inv * inv * cx + 2.0 * inv * t * c1.x + t * t * to.x;
                    ny = inv * inv * cy + 2.0 * inv * t * c1.y + t * t * to.y;
                }
                try edges.append(a, .{ .ax = cx, .ay = cy, .bx = nx, .by = ny });
                cx = nx;
                cy = ny;
            }
        },
        .close => {
            try edges.append(a, .{ .ax = cx, .ay = cy, .bx = sx, .by = sy });
            cx = sx;
            cy = sy;
        },
    };
    if (cx != sx or cy != sy) try edges.append(a, .{ .ax = cx, .ay = cy, .bx = sx, .by = sy });
    // takumi `filled_at` on each scanline
    const Cross = struct { x: f32, w: i32 };
    var cr: std.ArrayList(Cross) = .empty;
    var step: u32 = 0;
    while (step <= 8) : (step += 1) {
        const yy = top + (bottom - top) * @as(f32, @floatFromInt(step)) / 8.0;
        cr.clearRetainingCapacity();
        for (edges.items) |ed| {
            // (half-open in y: a vertex two segments share counts once)
            const w: i32 = if (ed.ay <= yy and ed.by > yy) 1 else if (ed.by <= yy and ed.ay > yy) -1 else continue;
            try cr.append(a, .{ .x = ed.ax + (ed.bx - ed.ax) * (yy - ed.ay) / (ed.by - ed.ay), .w = w });
        }
        // (stable insertion sort by x, as takumi's stable `sort_by_key`)
        var i: usize = 1;
        while (i < cr.items.len) : (i += 1) {
            const it = cr.items[i];
            var j = i;
            while (j > 0 and cr.items[j - 1].x > it.x) : (j -= 1) cr.items[j] = cr.items[j - 1];
            cr.items[j] = it;
        }
        var wind: i32 = 0;
        var entered: f32 = 0;
        for (cr.items) |c| {
            const was = wind != 0;
            wind += c.w;
            if (!was and wind != 0) entered = c.x else if (was and wind == 0) try out.append(a, .{ .a = entered, .b = c.x });
        }
    }
}

/// takumi `merge`: sorted by start (stably), touching spans unioned; the merged spans are compacted
/// to the front and the rest marked empty (`a > b`).
fn mergeSpans(sp: []Span) void {
    var i: usize = 1;
    while (i < sp.len) : (i += 1) {
        const it = sp[i];
        var j = i;
        while (j > 0 and sp[j - 1].a > it.a) : (j -= 1) sp[j] = sp[j - 1];
        sp[j] = it;
    }
    if (sp.len < 2) return;
    var n: usize = 0;
    for (sp[1..]) |s| {
        if (s.a <= sp[n].b) {
            sp[n].b = @max(sp[n].b, s.b);
        } else {
            n += 1;
            sp[n] = s;
        }
    }
    for (sp[n + 1 ..]) |*s| s.* = .{ .a = 1, .b = 0 };
}

// ---- inline box decorations (painter `paintInlineBoxes`)

fn isInlineBox(cs: *const CS) bool {
    if (cs.resolveColor(cs.background_color).a != 0) return true;
    if (cs.background_image.len > 0) return true;
    const bw = cs.usedBorderWidths();
    return bw[0] > 0 or bw[1] > 0 or bw[2] > 0 or bw[3] > 0;
}

fn paintInlineBoxes(e: *Emitter, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32) Error!void {
    const f = e.f;
    for (tl.boxes) |*fr| {
        const fi = f.boxFragment(n, fr) orelse continue;
        if (!isInlineBox(fi.cs)) continue;
        // a fragment is drawn on the pages that show its line (takumi `background_fragments`)
        if (e.window.paged() and fr.line < tl.lines.len) {
            const ln = tl.lines[fr.line];
            const it = mapItem(e, .{ .baseline = y + ln.baseline, .top = y + ln.top, .bottom = y + ln.top + ln.height, .l0 = y + ln.top, .l1 = y + ln.top + ln.height }, x + fi.x0, x + fi.x1);
            if (!showsItem(e, it)) continue;
        }
        const mask: FragmentMask = .{ .n = n, .tl = tl, .x = x, .y = y, .box = n.box_base + fr.box, .line = fr.line };
        try paintFragment(e, fi.cs, fr.face, fi.x0, fi.x1, fr.baseline, fi.left, fi.right, x, y, &mask);
    }
}

/// The runs of an inline box's fragment, which its `background-clip: text` background shows
/// through (takumi `PaintedRun::lies_in`: inside the span, on the fragment's line).
pub const FragmentMask = struct {
    /// the paragraph and its content origin
    n: *const Node,
    tl: *const font.TextLayout,
    x: f32,
    y: f32,
    /// the inline box (`Frame.inline_boxes` index) and the line of the fragment
    box: u32,
    line: u32,
};

/// Whether run style `user` lies inside inline box `box` (`Frame.run_box`, then the boxes' parents).
fn runInBox(e: *const Emitter, user: u32, box: u32) bool {
    const f = e.f;
    if (user >= f.run_box.items.len) return false;
    var b = f.run_box.items[user];
    var guard: u32 = 0;
    while (b != none and b < f.inline_boxes.items.len and guard < 256) : (guard += 1) {
        if (b == box) return true;
        b = f.inline_boxes.items[b].parent;
    }
    return false;
}

/// takumi `fill_text_clip` of an inline box's fragment: `fills` seen through the decorations and
/// glyphs of the runs `m` holds (`PaintedRun::paint_mask`).
pub fn paintFragmentClip(e: *Emitter, m: *const FragmentMask, fills: []const text.GlyphBackground) Error!void {
    const n = m.n;
    const tl = m.tl;
    const block_deco = blockDecoOf(e, n);
    var it: render.RunIter = .{ .tl = tl };
    while (it.next()) |r| {
        const g0 = &tl.glyphs[r.g0];
        if (!runInBox(e, g0.user, m.box)) continue;
        if ((lineOf(tl, r.g0) orelse continue) != m.line) continue;
        const rcs = runStyle(e, n, g0);
        if (rcs.visibility != .visible) continue;
        const on = runOnPage(e, tl, m.x, m.y, r);
        if (!on.shows) continue;
        const run: RunSeg = .{ .g0 = r.g0, .g1 = r.g1, .x0 = r.x0, .x1 = r.x1, .baseline = r.baseline, .rcs = rcs };
        try maskRun(e, n, tl, m.x, m.y, &run, block_deco, on.owned, fills);
    }
}

/// A run in a `background-clip: text` mask (takumi `PaintedRun::paint_mask`): its decorations,
/// whatever their colour, then its glyphs and their stroke, all filled with `fills`.
fn maskRun(e: *Emitter, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32, run: *const RunSeg, block_deco: ?*const CS, owned: bool, fills: []const text.GlyphBackground) Error!void {
    var decos: [max_decos]*const CS = undefined;
    const nd = decosOf(e, n, tl.glyphs[run.g0].user, run.rcs, block_deco, &decos);
    if (nd > 0) {
        const outer = e.d.through;
        e.d.through = fills;
        defer e.d.through = outer;
        try paintRunDecos(e, null, tl, x, y, run, decos[0..nd], false);
        try paintRunDecos(e, null, tl, x, y, run, decos[0..nd], true);
    }
    try glyphPass(e, n, tl, x, y, run, .{ .owned = owned, .fills = fills, .with_paint = false });
}

/// The block whose decorations a paragraph's runs draw: its own, or, for an anonymous text node or
/// box (the inline content around an atomic inline), that of the nearest element above it.
fn blockDecoOf(e: *const Emitter, n: *const Node) ?*const CS {
    var cur = n;
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        if (hasLine(cur.cs)) return cur.cs;
        // (an element stops the walk: an atomic inline does not take its block's decorations)
        if (cur.el != none or cur.kind == .container or cur.kind == .image or cur.parent == none) return null;
        cur = &e.f.nodes.items[cur.parent];
    }
    return null;
}

/// A fragment's border box (relative to the paragraph), its border widths and padding.
const FragBox = struct { r: Rect, bw: [4]f32, pad: [4]f32 };

fn fragmentBox(e: *Emitter, cs: *const CS, face: font.FaceId, x0: f32, x1: f32, baseline: f32, first: bool, last: bool) FragBox {
    const m = metricsOf(e, face, cs.font_size);
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
    return .{
        .r = .{
            .x = x0 - pad[3] - bw[3],
            .y = baseline - m.ascent - pad[0] - bw[0],
            .w = (x1 - x0) + pad[3] + bw[3] + pad[1] + bw[1],
            .h = m.ascent + m.descent + pad[0] + bw[0] + pad[2] + bw[2],
        },
        .bw = bw,
        .pad = pad,
    };
}

fn paintFragment(e: *Emitter, cs: *const CS, face: font.FaceId, x0: f32, x1: f32, baseline: f32, first: bool, last: bool, x: f32, y: f32, mask: ?*const FragmentMask) Error!void {
    const fb = fragmentBox(e, cs, face, x0, x1, baseline, first, last);
    const bw = fb.bw;
    const pad = fb.pad;
    const fx = x + fb.r.x;
    const fy = y + fb.r.y;
    const fw = fb.r.w;
    const fh = fb.r.h;
    const plain = e.plain();
    var g: pm.Geom = .{
        .bx = if (plain) pm.snapRect(fx, fy, fw, fh) else .{ .x = fx, .y = fy, .w = fw, .h = fh },
        .bw = bw,
        .pad = pad,
        .radii = undefined,
        .rounded = false,
        .snapped = plain,
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
    const saved_strip = e.background_strip;
    defer e.background_strip = saved_strip;
    e.background_strip = null;
    if (mask) |fm| if (cs.box_decoration_break == .slice) {
        var width: f32 = 0;
        var before: f32 = 0;
        var current = false;
        for (fm.tl.boxes) |*fr| {
            if (fm.n.box_base + fr.box != fm.box) continue;
            const fi = e.f.boxFragment(fm.n, fr) orelse continue;
            const b = fragmentBox(e, cs, fr.face, fi.x0, fi.x1, fr.baseline, fi.left, fi.right);
            if (fr.line == fm.line and !current) current = true;
            if (!current) before += b.r.w;
            width += b.r.w;
        }
        var strip = g;
        strip.bx.x = if (cs.direction == .rtl) fx + fw + before - width else fx - before;
        strip.bx.w = width;
        strip.bw = cs.usedBorderWidths();
        for (cs.padding, 0..) |p, k| strip.pad[k] = p.resolve(cs.font_size);
        if (plain) strip.bx = pm.snapRect(strip.bx.x, strip.bx.y, strip.bx.w, strip.bx.h);
        e.background_strip = strip;
    };
    try e.paintBackground(cs, &g, g.bx.x, g.bx.y);
    if (mask) |fm| if (emit.textClipped(cs)) try e.paintTextClip(0, cs, &g, g.bx.x, g.bx.y, fm);
    try border.paintBorder(&e.d, cs, &g);
}

/// The outlines of the paragraph's inline elements, after its text (takumi `InlineLines::paint`:
/// `OutlineIsland::of(outline_rects)`), each element's line fragments in line order; only the
/// fragments of the lines this page shows.
fn paintInlineOutlines(e: *Emitter, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32) Error!void {
    const f = e.f;
    var rects: std.ArrayList(border.InlineOutlineRect) = .empty;
    for (tl.boxes) |*fr| {
        const fi = f.boxFragment(n, fr) orelse continue;
        if (!border.hasInlineOutline(fi.cs)) continue;
        const fb = fragmentBox(e, fi.cs, fr.face, fi.x0, fi.x1, fr.baseline, fi.left, fi.right);
        if (e.window.paged()) {
            // (takumi keeps a rect whose middle is on a line the page shows)
            const top = y + fb.r.y;
            const it = mapItem(e, .{ .baseline = top + fb.r.h / 2, .top = top, .bottom = top + fb.r.h, .l0 = top, .l1 = top + fb.r.h }, x + fb.r.x, x + fb.r.x + fb.r.w);
            if (!showsItem(e, it)) continue;
        }
        try rects.append(e.a, .{ .owner = @as(u64, n.box_base) + fr.box, .line = fr.line, .x = fb.r.x, .y = fb.r.y, .w = fb.r.w, .h = fb.r.h, .cs = fi.cs });
    }
    if (rects.items.len == 0) return;
    const order = struct {
        fn lt(_: void, a: border.InlineOutlineRect, b: border.InlineOutlineRect) bool {
            return if (a.owner != b.owner) a.owner < b.owner else a.line < b.line;
        }
    }.lt;
    std.sort.insertion(border.InlineOutlineRect, rects.items, {}, order);
    try border.paintInlineOutlines(&e.d, rects.items, x, y);
}

/// A text node's paragraph at content origin (`x`, `y`) laid out at width `cw`: inline boxes,
/// text shadows, then per run: underline / overline, glyphs (fill + stroke), line-through. Only
/// the runs this page shows (pagination).
pub fn paintText(e: *Emitter, n: *const Node, x: f32, y: f32, cw: f32) Error!void {
    const f = e.f;
    const saved_span = e.line_span;
    defer e.line_span = saved_span;
    const box = f.tree.layout(n.lid);
    const left = x - box.border.left - box.padding.left;
    e.line_span = .{ left, left + box.w };
    const tl = (try f.textLayout(f.nodeId(n), cw)) orelse {
        if (e.tagged and textRegions(e, n, null, x, y).shows) etag.end(e, etag.begin(e, f.nodeId(n))); // [tagging]
        return;
    };
    if (e.links) |lk| lk.onText(e, n, tl, x, y); // [interactive] links of the runs
    // [tagging] the paragraph's region, on the pages its box or one of its runs reaches
    const regions: TextRegions = if (e.tagged) textRegions(e, n, tl, x, y) else .{ .shows = false };
    for (0..regions.before) |_| etag.end(e, etag.begin(e, f.nodeId(n)));
    const began = if (regions.shows) etag.begin(e, f.nodeId(n)) else false;
    // (the text belongs to an earlier fragment's line: the later fragments' empty regions follow
    // the line's last atomic inline, else this text)
    var trailing = regions.after;
    if (regions.deferred > 0) {
        if (lastAtomicInline(e, n, tl)) |child| {
            try e.pending_regions.append(e.a, .{ .node = f.nodeId(n), .child = child, .count = regions.deferred });
        } else trailing += regions.deferred;
    }
    defer for (0..trailing) |_| etag.end(e, etag.begin(e, f.nodeId(n)));
    defer etag.end(e, began);
    // a symbol list marker paints its shape, no glyph (takumi `TextFragmentPainter::Paint`)
    if (markers.ofNode(f, f.nodeId(n))) |mk| if (mk.shape) |shape| return paintSymbol(e, n, tl, x, y, mk, shape);
    if (tl.boxes.len > 0) try paintInlineBoxes(e, n, tl, x, y);
    // [lists] an inside symbol marker is text of this line: it paints here, in the line's content
    // sequence (no label of its own)
    if (e.takeInlineMarker(f.nodeId(n))) |im| {
        const was_tagged = e.tagged;
        e.tagged = false;
        defer e.tagged = was_tagged;
        try e.paintNode(im.node, im.x, im.y, im.depth);
    }

    const block_deco = blockDecoOf(e, n);

    // text shadows under all of the text: each run casts its own style's (`text-shadow` is
    // inherited, a span may set its own); neighbouring runs casting the same list share each
    // shadow pass, last listed first (takumi `InlineLines::paint`)
    try paintShadows(e, n, tl, x, y, block_deco);

    var it: render.RunIter = .{ .tl = tl };
    while (it.next()) |r| {
        const rcs = runStyle(e, n, &tl.glyphs[r.g0]);
        const run: RunSeg = .{ .g0 = r.g0, .g1 = r.g1, .x0 = r.x0, .x1 = r.x1, .baseline = r.baseline, .rcs = rcs };
        if (rcs.visibility != .visible) continue;
        const on = runOnPage(e, tl, x, y, r);
        if (!on.shows) continue;
        // (an inline span's `opacity`: its runs in a group of their own, takumi `with_opacity`)
        const op = runOpacity(e, n, tl.glyphs[r.g0].user, rcs);
        if (!(op > 0)) continue;
        if (op < 1) e.s.pushOpacity(op);
        var decos: [max_decos]*const CS = undefined;
        const nd = decosOf(e, n, tl.glyphs[r.g0].user, rcs, block_deco, &decos);
        if (nd > 0) try paintRunDecos(e, null, tl, x, y, &run, decos[0..nd], false);
        try glyphPass(e, n, tl, x, y, &run, .{ .owned = on.owned });
        if (nd > 0) try paintRunDecos(e, null, tl, x, y, &run, decos[0..nd], true);
        if (op < 1) e.s.pop();
    }
    if (tl.boxes.len > 0) try paintInlineOutlines(e, n, tl, x, y);
}

fn paintShadows(e: *Emitter, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32, block_deco: ?*const CS) Error!void {
    const Painted = struct { run: RunSeg, owned: bool };
    var runs: std.ArrayList(Painted) = .empty;
    var any = false;
    var it: render.RunIter = .{ .tl = tl };
    while (it.next()) |r| {
        const rcs = runStyle(e, n, &tl.glyphs[r.g0]);
        if (rcs.visibility != .visible) continue;
        const on = runOnPage(e, tl, x, y, r);
        if (!on.shows) continue;
        if (rcs.text_shadow.len > 0) any = true;
        try runs.append(e.a, .{ .run = .{ .g0 = r.g0, .g1 = r.g1, .x0 = r.x0, .x1 = r.x1, .baseline = r.baseline, .rcs = rcs }, .owned = on.owned });
    }
    if (!any) return;
    var b0: usize = 0;
    while (b0 < runs.items.len) {
        const shadows = runs.items[b0].run.rcs.text_shadow;
        var b1 = b0 + 1;
        while (b1 < runs.items.len and sameShadows(runs.items[b1].run.rcs.text_shadow, shadows)) b1 += 1;
        defer b0 = b1;
        var si = shadows.len;
        while (si > 0) {
            si -= 1;
            const sh = shadows[si];
            for (runs.items[b0..b1]) |*pr| {
                const run = &pr.run;
                const col = run.rcs.resolveColor(sh.color);
                if (col.a == 0) continue;
                const pass: ShadowPass = .{ .dx = sh.x, .dy = sh.y, .blur = sh.blur, .color = col };
                const op = runOpacity(e, n, tl.glyphs[run.g0].user, run.rcs);
                if (!(op > 0)) continue;
                if (op < 1) e.s.pushOpacity(op);
                // the run's decorations cast the shadow too (takumi's text painter under `begin_shadow`)
                var decos: [max_decos]*const CS = undefined;
                const nd = decosOf(e, n, tl.glyphs[run.g0].user, run.rcs, block_deco, &decos);
                if (nd > 0) try paintRunDecos(e, pass, tl, x, y, run, decos[0..nd], false);
                try glyphPass(e, n, tl, x, y, run, .{ .shadow = pass, .owned = pr.owned });
                if (nd > 0) try paintRunDecos(e, pass, tl, x, y, run, decos[0..nd], true);
                if (op < 1) e.s.pop();
            }
        }
    }
}

fn sameShadows(a: anytype, b: @TypeOf(a)) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

/// takumi `SymbolMarker::paint` (Blink's `PaintSymbol`): the shape of a symbol marker whose box
/// holds the line `tl` at content origin (`x`, `y`), at its offset from the text start on the
/// baseline; the disc / circle / square in the box pixel-snapped there, the disclosure triangle
/// in the unsnapped one. No shadow, no decoration.
fn paintSymbol(e: *Emitter, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32, mk: *const markers.Info, shape: markers.Shape) Error!void {
    var it: render.RunIter = .{ .tl = tl };
    const r = it.next() orelse return;
    const cs = n.cs;
    if (cs.visibility != .visible) return;
    if (!runOnPage(e, tl, x, y, r).shows) return;
    const col = if (cs.webkit_text_fill_color) |c| cs.resolveColor(c) else cs.color;
    const ox = x + r.x0 + mk.off_x;
    const oy = y + r.baseline + mk.off_y;
    const plain = e.plain();
    const bx: Rect = if (plain) pm.snapRect(ox, oy, mk.side, mk.side) else .{ .x = ox, .y = oy, .w = mk.side, .h = mk.side };
    var path: Path = .empty;
    const a = e.a;
    switch (shape) {
        .disc, .circle => {
            const rx = bx.w / 2;
            const ry = bx.h / 2;
            if (!(rx > 0) or !(ry > 0)) return;
            // (built about the box's origin, then moved there: takumi's `at_snapped` transform)
            const cx = rx;
            const cy = ry;
            const k: f32 = 0.552_284_8;
            try path.moveTo(a, cx + rx, cy);
            try path.cubicTo(a, cx + rx, cy + ry * k, cx + rx * k, cy + ry, cx, cy + ry);
            try path.cubicTo(a, cx - rx * k, cy + ry, cx - rx, cy + ry * k, cx - rx, cy);
            try path.cubicTo(a, cx - rx, cy - ry * k, cx - rx * k, cy - ry, cx, cy - ry);
            try path.cubicTo(a, cx + rx * k, cy - ry, cx + rx, cy - ry * k, cx + rx, cy);
            try path.close(a);
            if (shape == .disc) e.d.fillPath(&path, bx.x, bx.y, .nonzero, col) else e.d.strokePath(&path, bx.x, bx.y, 1, null, false, col);
        },
        .square => e.d.fillRRect(bx, null, col),
        .disclosure_left, .disclosure_right, .disclosure_down => {
            const pts: [3][2]f32 = switch (shape) {
                .disclosure_left => .{ .{ 1, 0 }, .{ 0.14, 0.5 }, .{ 1, 1 } },
                .disclosure_right => .{ .{ 0, 0 }, .{ 0.86, 0.5 }, .{ 0, 1 } },
                else => .{ .{ 0, 0.07 }, .{ 0.5, 0.93 }, .{ 1, 0.07 } },
            };
            try path.moveTo(a, pts[0][0] * mk.side, pts[0][1] * mk.side);
            try path.lineTo(a, pts[1][0] * mk.side, pts[1][1] * mk.side);
            try path.lineTo(a, pts[2][0] * mk.side, pts[2][1] * mk.side);
            try path.close(a);
            e.d.fillPath(&path, ox, oy, .nonzero, col);
        },
    }
}

/// [tagging] The paragraph's regions on this page (takumi: one per fragment of the box whose
/// content chunk is visible; a chunk is visible when the node's paint bounds, its box and its
/// glyphs' ascent / descent in whole pixels, meet the page's window). `before` / `after`:
/// the empty regions of the box's fragments on other pages, around this page's own.
/// How far the text shadows reach above (negative) and below the glyphs.
fn shadowReach(cs: *const CS) [2]f32 {
    var r = [2]f32{ 0, 0 };
    for (cs.text_shadow) |sh| {
        r[0] = @min(r[0], sh.y - sh.blur);
        r[1] = @max(r[1], sh.y + sh.blur);
    }
    return r;
}

/// The regions of a paragraph on this page: `before` empty ones, the text's (`shows`), `after`
/// empty ones, then `deferred` empty ones that open after the paragraph's atomic inlines paint.
const TextRegions = struct { shows: bool, before: u32 = 0, after: u32 = 0, deferred: u32 = 0 };

/// The last in-flow atomic inline of line container `n` (none: null).
fn lastAtomicInline(e: *Emitter, n: *const Node, tl: *const font.TextLayout) ?u32 {
    if (n.kind != .anon_box) return null;
    var last: ?u32 = null;
    var last_index: u32 = 0;
    for (tl.objects) |obj| {
        if (last != null and obj.id < last_index) continue;
        var child = n.first_child;
        var index: u32 = 0;
        while (child != none and index < obj.id) : (index += 1) child = e.f.nodes.items[child].next;
        if (child == none) continue;
        const cn = &e.f.nodes.items[child];
        if (cn.lid == none or cn.cs.position == .absolute or cn.cs.position == .fixed or cn.cs.float != .none) continue;
        last = child;
        last_index = obj.id;
    }
    return last;
}

/// The page (of paginated `pg`) the line box holding glyph `g` starts on.
fn linePage(e: *Emitter, pg: anytype, tl: *const font.TextLayout, y: f32, g: u32) ?usize {
    for (tl.lines) |ln| {
        if (g >= ln.glyph_start and g < ln.glyph_end) return pg.pageAt(y - e.plain_dy + ln.top);
    }
    return null;
}

/// Inline decorations belong to their line's fragment, while their paint bounds can reach
/// a neighbouring page. Such a visit still opens that fragment's (empty) content region.
fn inlineRegionBounds(e: *Emitter, n: *const Node, tl: *const font.TextLayout, y: f32, page: ?usize, lo: *f32, hi: *f32) void {
    const pg = e.f.paginated();
    // Atomic inlines belong to the fragment where their margin box starts. An
    // oversized object's paint can reach later pages even when its line's text
    // baseline belongs there; both fragment content visits still own regions.
    if (n.kind == .anon_box) for (tl.objects) |obj| {
        var child = n.first_child;
        var index: u32 = 0;
        while (child != none and index < obj.id) : (index += 1) child = e.f.nodes.items[child].next;
        if (child == none) continue;
        const cn = &e.f.nodes.items[child];
        if (cn.lid == none or cn.cs.position == .absolute or cn.cs.position == .fixed or cn.cs.float != .none) continue;
        if (page) |wanted| if (pg == null or pg.?.pageAt(y - e.plain_dy + obj.y) != wanted) continue;
        const l = e.f.tree.layout(cn.lid);
        const top = y + obj.y + l.margin.top;
        lo.* = @min(lo.*, top);
        hi.* = @max(hi.*, top + l.h);
    };
    for (tl.boxes) |*fr| {
        if (page) |wanted| if (pg == null or pg.?.pageAt(y - e.plain_dy + fr.baseline) != wanted) continue;
        const fi = e.f.boxFragment(n, fr) orelse continue;
        if (!border.hasInlineOutline(fi.cs)) continue;
        const box = fragmentBox(e, fi.cs, fr.face, fi.x0, fi.x1, fr.baseline, fi.left, fi.right).r;
        const reach = @max(0, @trunc(fi.cs.outline_width) + @trunc(fi.cs.outline_offset));
        lo.* = @min(lo.*, y + box.y - reach);
        hi.* = @max(hi.*, y + box.y + box.h + reach);
    }
}

/// An anonymous image-only generated line hands its content region directly to
/// the image; there is no separate empty paragraph to open or reopen around it.
pub fn onlyGeneratedImages(f: *const render.Frame, n: *const Node) bool {
    if (n.kind != .anon_box) return false;
    const para = n.para orelse return false;
    if (render.Frame.paragraphText(para).len != 0) return false;
    var child = n.first_child;
    var any = false;
    while (child != none) : (child = f.nodes.items[child].next) {
        const c = &f.nodes.items[child];
        if (c.cs.display == .none) continue;
        if (c.kind != .image or c.el == none or !f.dom.at(c.el).generated) return false;
        any = true;
    }
    return any;
}

fn textRegions(e: *Emitter, n: *const Node, tl_in: ?*const font.TextLayout, x: f32, y: f32) TextRegions {
    if (onlyGeneratedImages(e.f, n)) return .{ .shows = false };
    if (!e.window.paged() or !e.plain()) return .{ .shows = true };
    const l = e.f.tree.layout(n.lid);
    var region_top = y - l.border.top - l.padding.top;
    var region_height = l.h;
    // The sole anonymous paragraph stands for the cell's own inline layout.
    // Its content can finish before the row's remaining block space; those cell
    // fragments still own empty content regions, just as the original cell does.
    if (n.parent != none and e.f.nodes.items[n.parent].cs.display == .table_cell and
        @import("tags.zig").standsForParent(e.f, e.f.nodeId(n)))
    {
        const parent = e.f.tree.layout(e.f.nodes.items[n.parent].lid);
        region_top -= l.y;
        region_height = parent.h;
    }
    var top = region_top;
    var bottom = top + region_height;
    var run_shows = false;
    if (tl_in) |tl| {
        var it: render.RunIter = .{ .tl = tl };
        while (it.next()) |r| {
            if (runOnPage(e, tl, x, y, r).shows) run_shows = true;
            const g = &tl.glyphs[r.g0];
            const fnt = e.f.r.fonts.font(g.face);
            const sc = g.size / @as(f32, @floatFromInt(@max(1, fnt.unitsPerEm())));
            const lm = fnt.lineMetrics();
            top = @min(top, y + r.baseline - @as(f32, @floatFromInt(lm.ascent)) * sc);
            bottom = @max(bottom, y + r.baseline + @as(f32, @floatFromInt(lm.descent)) * sc);
        }
        inlineRegionBounds(e, n, tl, y, null, &top, &bottom);
    }
    const ext = shadowReach(n.cs);
    top = @floor(top + ext[0]);
    bottom = @ceil(bottom + ext[1]);
    const shows = run_shows or !(e.window.excludes(top, bottom) or e.clipExcludes(top, bottom));
    if (!shows) return .{ .shows = false };
    // the box's fragments (one per page it reaches), each with its part of the box and the
    // glyphs of its lines; those this page's window meets each open a region
    const pg = e.f.paginated() orelse return .{ .shows = true };
    // (the fragments of the layout box: a translated box's are where its layout box is, `dy`
    // above where they paint)
    const dy = e.plain_dy;
    const box_top = region_top - dy;
    const box_bottom = box_top + region_height;
    // (only the pages the box reaches: a scan of every page made each box cost the page count)
    const p0: usize = pg.pageAt(box_top);
    const p1: usize = @min(pg.pages.len, @as(usize, pg.pageAt(box_bottom)) + 1);
    var cur: ?usize = null;
    var count: u32 = 0;
    for (pg.pages[p0..p1], p0..) |p, i| {
        if (box_bottom <= p.top or box_top >= p.top + p.height) continue;
        count += 1;
        if (p.top == e.window.top) cur = i;
    }
    const here = cur orelse return .{ .shows = true };
    if (count <= 1) return .{ .shows = true };
    var out: TextRegions = .{ .shows = true };
    // the fragment whose line box holds the runs this page shows (a monolithic line placed on an
    // earlier page that overflows onto this one)
    var text_page: ?usize = null;
    if (tl_in) |tl| {
        var it: render.RunIter = .{ .tl = tl };
        while (it.next()) |r| {
            if (!runOnPage(e, tl, x, y, r).shows) continue;
            const lp = linePage(e, pg, tl, y, r.g0) orelse continue;
            text_page = if (text_page) |tp| @min(tp, lp) else lp;
        }
    }
    var lead: u32 = 0;
    var text_before = false;
    for (pg.pages[p0..p1], p0..) |p, i| {
        if (i == here or box_bottom <= p.top or box_top >= p.top + p.height) continue;
        var lo = @max(box_top, p.top) + dy;
        // (a page breaks its content at the page height truncated to 1/64 px, takumi's
        // `LayoutUnit` fragmentainer size: a box sliced there ends at that height on this page)
        var hi = @min(box_bottom, p.top + @floor(p.height * 64) / 64) + dy;
        if (tl_in) |tl| {
            var it: render.RunIter = .{ .tl = tl };
            while (it.next()) |r| {
                if (pg.pageAt(y - dy + r.baseline) != i) continue;
                const g = &tl.glyphs[r.g0];
                const fnt = e.f.r.fonts.font(g.face);
                const sc = g.size / @as(f32, @floatFromInt(@max(1, fnt.unitsPerEm())));
                const lm = fnt.lineMetrics();
                lo = @min(lo, y + r.baseline - @as(f32, @floatFromInt(lm.ascent)) * sc);
                hi = @max(hi, y + r.baseline + @as(f32, @floatFromInt(lm.descent)) * sc);
            }
            inlineRegionBounds(e, n, tl, y, i, &lo, &hi);
        }
        if (e.window.excludes(@floor(lo + ext[0]), @ceil(hi + ext[1])) or e.clipExcludes(@floor(lo + ext[0]), @ceil(hi + ext[1]))) continue;
        if (i < here) out.before += 1 else out.after += 1;
        if (text_page) |tp| {
            if (i < tp) lead += 1;
            if (i == tp) text_before = true;
        }
    }
    if (text_before and text_page.? < here) {
        // empty regions of the fragments before the text's, the text's, then the rest (this
        // page's own fragment included) after the line's atomic inlines
        out.deferred = (out.before - lead - 1) + 1 + out.after;
        out.before = lead;
        out.after = 0;
    }
    return out;
}

const max_decos = 8;

/// The decorations a run (style `user`) draws: the block's, then those of the inline boxes around
/// it, outermost first, then its own span's (takumi: the decorations a run's brush carries, which
/// every box of its chain propagates to it).
fn decosOf(e: *const Emitter, n: *const Node, user: u32, rcs: *const CS, block_deco: ?*const CS, out: *[max_decos]*const CS) usize {
    var nd: usize = 0;
    if (block_deco) |d| {
        out[nd] = d;
        nd += 1;
    }
    const f = e.f;
    if (user < f.run_box.items.len) {
        // the chain, innermost first
        var chain: [max_decos]*const CS = undefined;
        var nc: usize = 0;
        var b = f.run_box.items[user];
        var guard: u32 = 0;
        // (the paragraph's own boxes: those before `box_base` belong to the paragraph around it)
        while (b != none and b >= n.box_base and b < f.inline_boxes.items.len and guard < 256) : (guard += 1) {
            const bcs = f.inline_boxes.items[b].cs;
            if (hasLine(bcs) and nc < chain.len) {
                chain[nc] = bcs;
                nc += 1;
            }
            b = f.inline_boxes.items[b].parent;
        }
        while (nc > 0) {
            nc -= 1;
            if (!hasDeco(out[0..nd], chain[nc]) and nd < out.len) {
                out[nd] = chain[nc];
                nd += 1;
            }
        }
    }
    if (rcs != n.cs and hasLine(rcs) and !hasDeco(out[0..nd], rcs) and nd < out.len) {
        out[nd] = rcs;
        nd += 1;
    }
    return nd;
}

/// The opacity a run paints with (takumi `SizedFontStyle::brush`): its inline element's, the
/// innermost inline box around it or its own style; 1 for a block's own text.
fn runOpacity(e: *const Emitter, n: *const Node, user: u32, rcs: *const CS) f32 {
    const f = e.f;
    if (user < f.run_box.items.len) {
        const b = f.run_box.items[user];
        if (b != none and b >= n.box_base and b < f.inline_boxes.items.len) {
            const bcs = f.inline_boxes.items[b].cs;
            return if (bcs.display == .@"inline") bcs.opacity else 1;
        }
    }
    if (rcs != n.cs and rcs.display == .@"inline") return rcs.opacity;
    return 1;
}

fn hasDeco(list: []const *const CS, cs: *const CS) bool {
    for (list) |x| if (x == cs) return true;
    return false;
}

/// `background-clip: text` (takumi `fill_text_clip`): `fills` seen through the glyphs of node
/// `id` (border box at `x`, `y`) and of its descendants, no own paint.
pub fn paintClipText(e: *Emitter, id: u32, x: f32, y: f32, fills: []const text.GlyphBackground) Error!void {
    return clipNode(e, id, id, x, y, fills, 0);
}

fn clipNode(e: *Emitter, owner: u32, id: u32, x: f32, y: f32, fills: []const text.GlyphBackground, depth: u32) Error!void {
    const f = e.f;
    const n = &f.nodes.items[id];
    if (depth > 64 or (n.kind != .anon_text and n.cs.display == .none)) return;
    const l = f.tree.layout(n.lid);
    if (n.para != null) {
        const cw = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
        const cx = x + l.border.left + l.padding.left;
        const cy = y + l.border.top + l.padding.top;
        if (try f.textLayout(id, cw)) |tl| {
            const block_deco = blockDecoOf(e, n);
            var it: render.RunIter = .{ .tl = tl };
            while (it.next()) |r| {
                const rcs = runStyle(e, n, &tl.glyphs[r.g0]);
                if (rcs.visibility != .visible) continue;
                const on = runOnPage(e, tl, cx, cy, r);
                if (!on.shows) continue;
                const run: RunSeg = .{ .g0 = r.g0, .g1 = r.g1, .x0 = r.x0, .x1 = r.x1, .baseline = r.baseline, .rcs = rcs };
                try maskRun(e, n, tl, cx, cy, &run, block_deco, on.owned, fills);
            }
        }
    }
    var c = n.first_child;
    while (c != none) : (c = f.nodes.items[c].next) {
        if (!e.reachesTextClip(c, owner)) continue;
        const cn = &f.nodes.items[c];
        // An inline formatting context contributes only its inline content boxes; floats
        // and positioned boxes met among its runs are not part of that content mask.
        if (n.para != null and (cn.cs.float != .none or cn.cs.position == .absolute or cn.cs.position == .fixed)) continue;
        const cl = f.tree.layout(f.nodes.items[c].lid);
        try clipNode(e, owner, c, x + cl.x, y + cl.y, fills, depth + 1);
    }
}
