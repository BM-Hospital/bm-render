//! The PDF emitter's graphics pass: walks a prepared frame (styles computed, layout done) in the
//! raster painter's paint order (paint.zig / svg_out.zig: shadows -> background -> inset
//! shadows -> border -> content -> children, z-order, floats, outlines at the end of their
//! stacking context) and draws it onto a krilla-model surface (emit_surface.zig) the way
//! takumi-pdf's `Emitter` does (takumi-pdf `emitter.rs`, `paint.rs`, `shadow.rs`, `filter.rs`):
//!
//! * CSS px user space under the page transform `0.75 0 0 -0.75 0 h` (`1 0 0 -1 0 h` root +
//!   a `0.75` scale); pure translations fold into coordinates, other transforms are pushed;
//! * backgrounds: colour fill of the `background-clip` shape, then the image layers inside that
//!   shape's clip, each a single tile (clipped to its paint area when it overflows it) or a tiling
//!   pattern; gradients as shadings (emit_shading.zig): conic gradients as 64-stop sweeps sampled
//!   from the painter's LUT;
//! * box shadows: one clip-out of the border box, each shadow a filled shape, blur faked by eight
//!   fainter spread bands (takumi `Band`); inset shadows as even-odd rings inside the padding box;
//! * borders / outlines: emit_border.zig; images: emit_image.zig (SVG images rasterised by the
//!   painter: takumi draws them as vector ops);
//! * opacity / isolation: transparency-group XObjects; `mix-blend-mode`: `/BM` in the graphics
//!   state; `clip-path`, overflow: clip paths; `mask-image`: an alpha soft mask drawn from the
//!   mask layers; colour `filter`s: folded into every colour and image pixel; `blur()` and
//!   `drop-shadow()` fail the render as in takumi-pdf; `backdrop-filter` is ignored;
//! * text: emit_text.zig (decorations, inline box decorations; glyph runs through the text seam
//!   into text.zig with the document's font registry); `background-clip: text`: the background
//!   fills seen through the glyphs (takumi `fill_text_clip`).
//!
//! `paintPage` paints the frame restricted to a window of its y axis into a page's content box,
//! then the page's repeats (repeated table header / footer groups, `position: fixed` boxes); the
//! document loop (`writeDocument`) calls it once per page (viewport mode: one page, the whole
//! frame), then writes the fonts and the pages.
const std = @import("std");
const render = @import("../render.zig");
const style = @import("../style/style.zig");
const raster = @import("../raster/raster.zig");
const rpaint = @import("../raster/paint.zig");
const rtypes = @import("../raster/types.zig");
const pm = @import("../paint.zig");
const pfx = @import("../paint_fx.zig");
const psvg = @import("../paint_svg.zig");
const w = @import("writer.zig");
const sf = @import("emit_surface.zig");
const bump = @import("../bump.zig");
const geom = @import("emit_geom.zig");
const dev = @import("emit_device.zig");
const border = @import("emit_border.zig");
const eimg = @import("emit_image.zig");
const esvg = @import("emit_svg.zig");
const etext = @import("emit_text.zig");
const etable = @import("emit_table.zig");
const shading = @import("emit_shading.zig");
const text = @import("text.zig");
const layout = @import("../layout/layout.zig");
const svg_path = if (pm.enable_svg) @import("../svg/pathdata.zig") else struct {};
const pdf_bands = @import("bands.zig");
const interactive = @import("interactive.zig");
const metadata = @import("metadata.zig");
const etag = @import("emit_tag.zig"); // [tagging]
const tagsm = @import("tags.zig"); // [tagging]
const conform = @import("conform.zig"); // [tagging] PDF/A, PDF/UA

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
const Geom = pm.Geom;
const Radii = pm.Radii;
const Tf = geom.Tf;
const LRect = geom.LRect;

pub const pt_per_px: f32 = 0.75;

/// The part of the frame one page shows: frame y range [`top`, `bottom`) in CSS px, and the
/// range of baselines whose lines this page owns (takumi-pdf `Window { y, lines }`; the
/// `PageSlice::lines` of a paginated document: open above on the first page, below on the last).
pub const Window = struct {
    top: f32 = -std.math.inf(f32),
    bottom: f32 = std.math.inf(f32),
    lines_top: f32 = -std.math.inf(f32),
    lines_bottom: f32 = std.math.inf(f32),

    pub fn excludes(win: Window, y0: f32, y1: f32) bool {
        // (an edge a page's top or bottom places lands within a few float steps of it far down a
        // long document: see `layout.fragment.Pages.pageAt`)
        return y1 <= win.top + edgeTol(win.top) or y0 >= win.bottom - edgeTol(win.bottom);
    }

    fn edgeTol(y: f32) f32 {
        if (!std.math.isFinite(y)) return 0;
        return @max(1.0 / 256.0, @abs(y) * (1.0 / 1048576.0));
    }

    /// The window cuts the frame (a page of a paginated document).
    pub fn paged(win: Window) bool {
        return std.math.isFinite(win.top) or std.math.isFinite(win.bottom) or std.math.isFinite(win.lines_top) or std.math.isFinite(win.lines_bottom);
    }
};

/// One page: its size and content box in CSS px, the paper colour.
pub const PageBox = struct {
    width: f32,
    height: f32,
    /// the page's content box (margins removed); the window's top lands at its top edge
    content: Rect,
    background: ?Color = null,
    /// clip the frame to the content box (paged mode)
    clip: bool = false,
    /// subtrees painted again on this page (`Pages.repeatsOf`): repeated table header / footer
    /// groups, `position: fixed` boxes (those with a negative `z-index` under the content, as
    /// takumi's `RepeatBounds::Content { below }`)
    repeats: []const layout.fragment.Repeat = &.{},
    /// the repeating `position: fixed` boxes (`repeatingFixed`), painted on every page in windows
    /// of their own and skipped by the frame's walk
    fixed: []const u32 = &.{},
    // ---- bands and per-page counters (bands.zig, paged.zig)
    /// the header band (drawn before the content) and the footer band (after it)
    header: ?pdf_bands.Draw = null,
    footer: ?pdf_bands.Draw = null,
    /// the frame `fixed` indexes into when it is not the document's: this page's own layout of its
    /// repeating fixed boxes (they hold page counters)
    fixed_frame: ?*Frame = null,
    /// the frame this page shows when it is not the document's (a page laid out at another width
    /// than the first: paged.zig); its windows are those of the neighbouring pages that show it
    frame: ?*Frame = null,
    /// (`frame` set, the first / last page showing it) the window of the frame's own page before /
    /// after this one: the neighbouring pass that paints what reaches this page (the page before /
    /// after it in the document shows another frame)
    prev_win: ?Window = null,
    next_win: ?Window = null,
    /// fragments of this page that reach past its end (`layout.fragment.Extend`, paged.zig
    /// `cellOverflow`); in the frame this page shows
    extends: []const layout.fragment.Extend = &.{},
    /// (the page before laid out in another frame) that frame, its fragments on the page before
    /// that reach this one and the window of that page in it: their decorations paint here first
    over_frame: ?*Frame = null,
    over_extends: []const layout.fragment.Extend = &.{},
    over_win: Window = .{},
    /// (the page after laid out in another frame, in the same block coordinates) that frame and
    /// the window of that page in it: what its fragments paint into this page's window (the
    /// collapsed borders of a table starting it) paints here after this page's decorations
    under_frame: ?*Frame = null,
    under_win: Window = .{},
};

const Deferred = struct { cs: *const CS, g: Geom, ctm: Tf, clip0: u32, clip1: u32 };
/// A clip the walk opened; `overflow_of`: the box whose `overflow` clip it is (an absolutely
/// positioned descendant escapes it when the box is not in its containing block chain).
const ClipRec = struct { path: Path, rule: sf.FillRule, ctm: Tf, overflow_of: u32 = none };
/// A transformed box is decorated in its layout fragment's local coordinate space.
const BoxFragment = struct { id: u32, window: Window };
/// A box (`whole`: a float or an atomic in-flow box, at its parent's origin) or the content of a
/// box (its text / replaced content, at its own origin) waiting for the paint phase of its context
/// (CSS 2.1 appendix E as takumi's `StackingContextNode::paint_phases`), with what the walk was in
/// where it met it (the clips are re-entered as for a lift).
const Queued = struct {
    fragment: ?BoxFragment = null,
    id: u32,
    ox: f32,
    oy: f32,
    tf: Affine,
    ctm: Tf,
    clip0: u32,
    clip1: u32,
    depth: u32,
    pass: ?u32,
    tpage: bool,
    in_repeat: bool,
    tphase: Emitter.Phase,
    whole: bool,
    /// [interactive] the place of its links in the page's link order (`interactive.Collector.reserve`)
    lgroup: u32 = none,
    clip_y: [2]f32,
    plain_dy: f32 = 0,
};
/// A positioned / stacking box lifted to the end of its stacking context (`liftOf`), with what
/// the walk was in where it met it.
const Lift = struct {
    fragment: ?BoxFragment = null,
    id: u32,
    ox: f32,
    oy: f32,
    tf: Affine,
    ctm: Tf,
    clip0: u32,
    clip1: u32,
    depth: u32,
    z: i64,
    pre: u32,
    pass: ?u32,
    tpage: bool,
    in_repeat: bool,
    clip_y: [2]f32,
    plain_dy: f32 = 0,
};

pub const Emitter = struct {
    f: *Frame,
    /// the document's fonts (text.zig; one registry for every page)
    fonts: *text.FontRegistry,
    /// working memory of the page (`sf.Ctx.work`: rewound after the page)
    a: Allocator,
    /// memory for what outlives the page (`tparts`, kept over a run of pages; image bytes the
    /// document embeds): the frame's
    keep: Allocator,
    cx: *sf.Ctx,
    s: *sf.Surface,
    d: dev.Device,
    filter: ?*const dev.ColorFilter = null,
    /// absolute transform of the current coordinates (snapping: only untransformed boxes snap)
    tf: Affine = Affine.identity,
    window: Window = .{},
    /// The vertical extent the overflow clips around the current box leave, in frame coordinates
    /// (takumi-pdf `Window::narrow`): a page's walk paints nothing those clips cut away, text
    /// included, which a clip would hide from view but not from the text layer. Narrowed by an
    /// untransformed overflow clip on a page of a paginated document only.
    clip_y: [2]f32 = .{ -std.math.inf(f32), std.math.inf(f32) },
    /// The paragraph box's horizontal span for transformed line ownership (takumi LineFrame).
    line_span: ?[2]f32 = null,
    box_fragment: ?BoxFragment = null,
    /// Inline slice backgrounds position image layers on the concatenated strip while
    /// their outer clip and border still use the current line's fragment.
    background_strip: ?Geom = null,
    path: Path = .empty,
    path2: Path = .empty,
    outlines: std.ArrayList(Deferred) = .empty,
    /// clips opened by the walk (overflow, clip-path), for re-entering them around deferred outlines
    clips: std.ArrayList(ClipRec) = .empty,
    outline_clips: std.ArrayList(ClipRec) = .empty,
    /// the paint phases of a context (takumi `paint_phases`): a context (the root, a stacking
    /// context, a positioned box, a float, an atomic inline, a flex / grid item: `contextScope`)
    /// paints the decorations of the in-flow boxes inside it as the walk meets them, then its floats
    /// (`float_q`), then the content of those boxes and its atomic in-flow boxes whole
    /// (`content_q`), in tree order; `defer_on`: a context is open, `float_now` / `queue_now`: the
    /// box painted from a queue
    float_q: std.ArrayList(Queued) = .empty,
    content_q: std.ArrayList(Queued) = .empty,
    float_now: u32 = none,
    queue_now: u32 = none,
    defer_on: bool = false,
    /// positioned / stacking boxes waiting for the end of their stacking context (takumi's
    /// `PaintBucket::Positioned` / `Positive`: a box lifts past the in-flow content of every box up
    /// to its stacking context), whether a stacking context collects them, the box painted from
    /// the queue, the clips each was met under, tree order by node id (`preorder`)
    lift_q: std.ArrayList(Lift) = .empty,
    lift_on: bool = false,
    lift_now: u32 = none,
    lift_clips: std.ArrayList(ClipRec) = .empty,
    /// boxes with a negative `z-index` their stacking context painted before its in-flow content
    /// on this page (`paintNegatives`: the walk then skips them), and the one being painted
    neg_done: std.AutoHashMapUnmanaged(u32, void) = .empty,
    neg_now: u32 = none,
    /// whether the frame holds any box with a negative `z-index` at all (else `paintNegatives` walks nothing)
    neg_any: bool = true,
    pre: []u32 = &.{},
    /// the document's subtree extents (`Extents`): a page's walk skips the subtrees that miss its
    /// window (null: bands, fixed boxes, tests)
    ext: ?*const Extents = null,
    /// `PageBox.extends` of the page (or `over_extends` while its decorations paint), and the window
    /// the boxes are cut to instead of this page's (`paintOverflow`: the page before's)
    extends: []const layout.fragment.Extend = &.{},
    slice_win: ?Window = null,
    /// a paginated document's page windows, this page's index among them, and the page whose
    /// fragments the current pass paints (takumi's page scene visits the root fragments of the
    /// pages reaching the page, in page order; null: one pass over the whole frame), and whether
    /// the transformed box around the current coordinates belongs to that pass
    windows: []const Window = &.{},
    win_page: u32 = 0,
    /// the first of `windows` reaches up to the frame's top / the last down to its bottom (false:
    /// they continue from or onto pages laid out at another width, from another frame: paged.zig)
    win_open_top: bool = true,
    win_open_bottom: bool = true,
    /// the walk visits every box (the first page of a run of pages showing one frame: the
    /// document-wide collections are made during its walk)
    walk_all: bool = true,
    pass: ?u32 = null,
    tpage: bool = true,
    /// the block offset translate-only transforms of the boxes being painted add to their layout
    /// position (a box's fragments are where its layout box is, not where it paints: `windowSlice`)
    plain_dy: f32 = 0,
    /// the painter (glyph masks, SVG rasteriser) over a canvas-sized dummy pixmap
    p: pm.Painter,
    dummy: raster.Pixmap,
    /// first failure that stops the render (message for `Renderer.setErr`)
    fail_msg: ?[]const u8 = null,
    fail_arg: []const u8 = "",
    /// this page's repeats (table header / footer groups painted in their table) and which are done
    repeats: []const layout.fragment.Repeat = &.{},
    rep_done: []bool = &.{},
    /// untransformed images already painted on this page (fragment passes can revisit them)
    page_images: []bool = &.{},
    /// inside a table: which pass (`paintCollapsedTable`)
    tphase: Phase = .all,
    /// skip `fixed` boxes in the walk (they paint in windows of their own)
    skip_fixed: bool = false,
    /// table parts by render node id (emit_table.zig)
    tparts: []etable.Part = &.{},
    /// [interactive] link / anchor collection (interactive.zig); null: none (bands, tests)
    links: ?*interactive.Collector = null,
    // [tagging] emit_tag.zig: the document's marked-content collector (null: untagged output),
    // whether this walk marks content (false inside bands / repeated fixed boxes), a repeated
    // table header / footer being painted (an artifact), the output page, the document language
    tags: ?*tagsm.Collector = null,
    tagged: bool = false,
    in_repeat: bool = false,
    page_index: u32 = 0,
    doc_lang: []const u8 = "",
    /// [lists] an inside symbol marker the text of its line container paints (emit_text.zig)
    inline_markers: std.ArrayList(InlineMarker) = .empty,
    /// [tagging] empty content regions of paragraph `node` that open after its atomic inline
    /// `child` paints (emit_text.zig `paintText`: a line placed on an earlier page fragment owns
    /// the text, the later fragments' regions follow that line's atomic inlines, as in takumi's
    /// page scene, where the earlier page's root fragment paints whole first)
    pending_regions: std.ArrayList(PendingRegions) = .empty,
    /// paint decorations only, no text or image content (`paintUnder`)
    no_content: bool = false,

    pub const InlineMarker = struct { host: u32, node: u32, x: f32, y: f32, depth: u32 };

    pub const PendingRegions = struct { node: u32, child: u32, count: u32 };

    /// Opens the pending regions waiting for `child` (`none`: all of them).
    pub fn flushPendingRegions(e: *Emitter, child: u32) void {
        var i: usize = 0;
        while (i < e.pending_regions.items.len) {
            const p = e.pending_regions.items[i];
            if (child != none and p.child != child) {
                i += 1;
                continue;
            }
            _ = e.pending_regions.orderedRemove(i);
            for (0..p.count) |_| etag.end(e, etag.begin(e, p.node));
        }
    }

    /// Takes the inside marker waiting for the text of line container `host` (null: none).
    pub fn takeInlineMarker(e: *Emitter, host: u32) ?InlineMarker {
        for (e.inline_markers.items, 0..) |im, i| if (im.host == host) return e.inline_markers.swapRemove(i);
        return null;
    }

    fn dropInlineMarker(e: *Emitter, host: u32) void {
        _ = e.takeInlineMarker(host);
    }

    pub fn init(f: *Frame, cx: *sf.Ctx, s: *sf.Surface, fonts: *text.FontRegistry) Emitter {
        const wa = cx.page orelse f.a;
        return .{
            .f = f,
            .fonts = fonts,
            .a = wa,
            .keep = f.a,
            .cx = cx,
            .s = s,
            .d = .{ .s = s, .a = wa },
            .p = .{ .f = f, .a = wa },
            .dummy = .{ .width = f.canvas_w, .height = f.canvas_h, .data = &.{} },
        };
    }

    pub fn ctx(e: *const Emitter) pm.Ctx {
        return .{ .dst = @constCast(&e.dummy), .tf = e.tf };
    }

    /// The painter context box geometry snaps in: always (takumi `SnappedBox` in the current
    /// paint space, transformed or not).
    pub fn snapCtx(e: *const Emitter) pm.Ctx {
        return .{ .dst = @constCast(&e.dummy), .tf = Affine.identity };
    }

    pub fn plain(e: *const Emitter) bool {
        return e.tf.isIdentity();
    }

    /// The overflow clips around the current box cut frame y range `y0`..`y1` away (`clip_y`).
    pub fn clipExcludes(e: *const Emitter, y0: f32, y1: f32) bool {
        return y1 <= e.clip_y[0] or y0 >= e.clip_y[1];
    }

    /// takumi-pdf `push_clip` -> `Window::narrow`: the vertical extent of the overflow clip of a box
    /// (`overflowPath`'s shape: none for a band unbounded vertically) narrows `clip_y`, when the clip
    /// is in page space (no transform) on a page of a paginated document.
    fn narrowClip(e: *Emitter, cs: *const CS, g: *const Geom) void {
        if (!e.plain() or !e.window.paged()) return;
        if (cs.overflow_x == .clip and cs.overflow_y == .visible) return;
        const pr = g.overflowRect();
        e.clip_y = .{ @max(e.clip_y[0], pr.y), @min(e.clip_y[1], pr.y + pr.h) };
    }

    pub noinline fn fail(e: *Emitter, msg: []const u8, arg: []const u8) void {
        if (e.fail_msg == null) {
            e.fail_msg = msg;
            e.fail_arg = arg;
        }
    }

    /// Draws onto `s` for the duration of a callback-free section (pattern tiles, masks).
    pub fn swapSurface(e: *Emitter, s: *sf.Surface) *sf.Surface {
        const old = e.s;
        e.s = s;
        e.d.s = s;
        return old;
    }

    // ------------------------------------------------------------------------------------------
    // walk
    //
    // Stack discipline: `paintNode` -> `paintBox` -> `paintNode` recurses once per nesting level (up to
    // `render.max_node_depth`), through `paintTable` / `paintTableChild` in tables and through the float
    // and lift queues. Everything else those functions call is `noinline` and nothing large is a local of
    // theirs, so a level costs a small fixed frame on wasm's 1 MiB stack and on a native thread
    // (bench/native-tests.mjs "pdf-stack" measures it).
    // ------------------------------------------------------------------------------------------

    /// `cs.filter` folded over the colour filter in effect (`e.filter`), when it changes it.
    noinline fn composeFilter(e: *Emitter, cs: *const CS) Error!void {
        if (dev.ColorFilter.compose(e.filter, cs.filter)) |cf| {
            const p = try e.a.create(dev.ColorFilter);
            p.* = cf;
            e.filter = p;
        }
    }

    /// The first filter of `cs` a PDF cannot draw: fails the render and returns true.
    noinline fn unsupportedFilter(e: *Emitter, cs: *const CS) bool {
        if (dev.unsupported(e.a, cs.filter)) |name| {
            e.fail("A PDF cannot draw filter: ", name);
            return true;
        }
        return false;
    }

    /// The overflow clip of the box of node `n` at (`x`, `y`), if it has one; false = nothing inside is visible.
    noinline fn pushOverflowOf(e: *Emitter, n: *const Node, x: f32, y: f32) Error!bool {
        const cs = n.cs;
        if (cs.overflow_x == .visible and cs.overflow_y == .visible) return true;
        const c = e.ctx();
        const g = pm.Painter.geomOf(cs, e.f.tree.layout(n.lid), x, y, &c);
        if (!try e.pushOverflow(cs, &g)) return false;
        e.clips.items[e.clips.items.len - 1].overflow_of = e.f.nodeId(n);
        e.narrowClip(cs, &g);
        return true;
    }

    /// Whether the overflow clip of box `owner` leaves out the absolutely positioned / fixed box
    /// `id`: `owner` sits between it and its containing block (the nearest positioned or
    /// transformed ancestor; for a fixed box, the nearest transformed one), as CSS 2.1 §11.1.1
    /// clips only the descendants whose containing block chain passes through the box (takumi
    /// takes a positioned box's clips from its containing block).
    noinline fn escapesClip(e: *const Emitter, id: u32, owner: u32) bool {
        const f = e.f;
        const fixed = f.nodes.items[id].cs.position == .fixed;
        var a = f.nodes.items[id].parent;
        var guard: u32 = 0;
        while (a != none and guard < 4096) : (guard += 1) {
            const an = &f.nodes.items[a];
            if (an.kind != .anon_text) {
                if (hasTransform(an.cs)) return false;
                if (!fixed and an.cs.position != .static) return false;
            }
            // (the root's own overflow clip is outside the initial containing block too)
            if (a == owner) return true;
            if (a == f.root) return false;
            a = an.parent;
        }
        return false;
    }

    /// The transform of a box pushed onto the surface: the box then paints at its own origin.
    noinline fn pushBoxTransform(e: *Emitter, m: Affine, bx: *f32, by: *f32) void {
        const t = m.mul(Affine.translate(bx.*, by.*));
        e.s.pushTransform(Tf.fromAffine(t));
        e.tf = e.tf.mul(t);
        bx.* = 0;
        by.* = 0;
    }

    noinline fn queueFloat(e: *Emitter, id: u32, ox: f32, oy: f32, depth: u32) Error!bool {
        const n = &e.f.nodes.items[id];
        if (n.cs.float == .none or n.kind == .anon_text or id == e.float_now or id == e.f.root or n.cs.display == .none or stacks(n.cs)) return false;
        try e.enqueue(&e.float_q, id, ox, oy, depth, true);
        return true;
    }

    /// An atomic in-flow box (an atomic inline: inline-block / -flex / -grid / -table, an inline
    /// image; a flex or grid item) inside an open context: queued whole for the context's content
    /// phase (takumi `PaintItem::part_in`: an atomic context paints whole with the content).
    noinline fn queueAtomic(e: *Emitter, id: u32, ox: f32, oy: f32, depth: u32) Error!bool {
        if (!e.defer_on or id == e.queue_now or id == e.f.root) return false;
        const n = &e.f.nodes.items[id];
        if (n.kind == .anon_text or n.cs.display == .none or n.cs.float != .none or n.cs.position != .static) return false;
        if (e.stackingContext(id) or e.partKind(id) != .none) return false;
        if (!e.atomic(n) and !(n.kind == .image and n.cs.display == .@"inline")) return false;
        // (a collapsed table's decorations pass: the content pass meets it again)
        if (e.tphase == .decorations) return true;
        try e.enqueue(&e.content_q, id, ox, oy, depth, true);
        return true;
    }

    /// The content of the box at (`x`, `y`), queued for its context's content phase, under the
    /// box's own overflow clip (takumi's `contents` property state; none visible: nothing).
    noinline fn queueContent(e: *Emitter, id: u32, x: f32, y: f32) Error!void {
        const n = &e.f.nodes.items[id];
        const saved = e.clips.items.len;
        const saved_cy = e.clip_y;
        defer {
            e.clips.items.len = saved;
            e.clip_y = saved_cy;
        }
        if (n.kind != .anon_text and (n.cs.overflow_x != .visible or n.cs.overflow_y != .visible)) {
            const c = e.ctx();
            const g = pm.Painter.geomOf(n.cs, e.f.tree.layout(n.lid), x, y, &c);
            if (!try e.overflowPath(n.cs, &g)) return;
            try e.recordClip(&e.path, .nonzero);
            e.clips.items[e.clips.items.len - 1].overflow_of = id;
            e.narrowClip(n.cs, &g);
        }
        try e.enqueue(&e.content_q, id, x, y, 0, false);
    }

    noinline fn enqueue(e: *Emitter, list: *std.ArrayList(Queued), id: u32, ox: f32, oy: f32, depth: u32, whole: bool) Error!void {
        const c0: u32 = @intCast(e.lift_clips.items.len);
        try e.lift_clips.appendSlice(e.a, e.clips.items);
        try list.append(e.a, .{
            .fragment = e.box_fragment,
            .id = id,
            .ox = ox,
            .oy = oy,
            .tf = e.tf,
            .ctm = e.s.bd().ctm(),
            .clip0 = c0,
            .clip1 = @intCast(e.lift_clips.items.len),
            .depth = depth,
            .pass = e.pass,
            .tpage = e.tpage,
            .in_repeat = e.in_repeat,
            .tphase = e.tphase,
            .whole = whole,
            // [interactive] takumi collects links in tree order: content painted later keeps its place
            .lgroup = if (e.links) |lk| (if (list == &e.content_q) lk.reserve() else none) else none,
            .clip_y = e.clip_y,
            .plain_dy = e.plain_dy,
        });
    }

    /// Whether box `id` is a context whose floats and content paint at its end (takumi's
    /// `StackingContextNode`s: the root, stacking contexts and atomic boxes; an `overflow` clip
    /// is none). The root opens one only when no context is open (a page's passes share one).
    noinline fn contextScope(e: *const Emitter, id: u32) bool {
        if (id == e.f.root) return !e.defer_on;
        const n = &e.f.nodes.items[id];
        if (n.kind == .anon_text) return false;
        if (n.cs.position != .static or e.stackingContext(id) or e.atomic(n)) return true;
        return n.kind == .image and n.cs.display == .@"inline";
    }

    /// Paints the items queued on `list` since `q0` (those they queue in turn are painted by their
    /// own contexts), re-entering the clips opened after `base` they were met under.
    noinline fn flushQueue(e: *Emitter, list: *std.ArrayList(Queued), q0: usize, base: usize) Error!void {
        var i = q0;
        while (i < list.items.len) : (i += 1) {
            if (e.fail_msg != null) break;
            try e.paintQueued(list.items[i], base);
        }
        list.items.len = @min(q0, list.items.len);
    }

    noinline fn paintQueued(e: *Emitter, it: Queued, base: usize) Error!void {
        const saved_fragment = e.box_fragment;
        e.box_fragment = it.fragment;
        defer e.box_fragment = saved_fragment;
        const depth0 = e.s.depth();
        const saved_clips = e.clips.items.len;
        const saved_tf = e.tf;
        const saved_pass = e.pass;
        const saved_tpage = e.tpage;
        const saved_rep = e.in_repeat;
        const saved_phase = e.tphase;
        const saved_float = e.float_now;
        const saved_now = e.queue_now;
        const saved_defer = e.defer_on;
        const saved_group = if (e.links) |lk| lk.enter(it.lgroup) else none;
        const saved_cy = e.clip_y;
        const saved_dy = e.plain_dy;
        defer {
            if (e.links) |lk| lk.leave(saved_group);
            e.s.popTo(depth0);
            e.clips.items.len = saved_clips;
            e.clip_y = saved_cy;
            e.plain_dy = saved_dy;
            e.tf = saved_tf;
            e.pass = saved_pass;
            e.tpage = saved_tpage;
            e.in_repeat = saved_rep;
            e.tphase = saved_phase;
            e.float_now = saved_float;
            e.queue_now = saved_now;
            e.defer_on = saved_defer;
        }
        const cur = e.s.bd().ctm();
        const inv = cur.invert() orelse Tf.identity;
        var k: usize = it.clip0 + @min(base, it.clip1 - it.clip0);
        while (k < it.clip1) : (k += 1) {
            const ce = e.lift_clips.items[k];
            try geom.transformed(e.a, &ce.path, inv.pre(ce.ctm), &e.path);
            e.s.pushClip(&e.path, ce.rule);
            try e.clips.append(e.a, ce);
        }
        if (!it.ctm.eql(cur)) e.s.pushTransform(inv.pre(it.ctm));
        e.tf = it.tf;
        e.clip_y = it.clip_y;
        e.plain_dy = it.plain_dy;
        e.pass = it.pass;
        e.tpage = it.tpage;
        e.in_repeat = it.in_repeat;
        e.tphase = it.tphase;
        if (!it.whole) {
            e.defer_on = false;
            return e.paintOwn(it.id, it.ox, it.oy, .content);
        }
        if (e.f.nodes.items[it.id].cs.float != .none) e.float_now = it.id else e.queue_now = it.id;
        try e.paintNode(it.id, it.ox, it.oy, it.depth);
    }

    pub fn paintNode(e: *Emitter, id: u32, ox: f32, oy: f32, depth: u32) Error!void {
        if (e.fail_msg != null or depth > 600) return;
        if (e.skip_fixed and depth > 0 and e.f.nodes.items[id].kind != .anon_text and e.f.nodes.items[id].cs.position == .fixed and repeats(e.f, id)) return;
        if (id != e.neg_now and e.neg_done.count() > 0 and e.neg_done.contains(id)) return;
        if (try e.liftOf(id, ox, oy, depth)) return;
        if (pm.enable_floats and try e.queueFloat(id, ox, oy, depth)) return;
        if (try e.queueAtomic(id, ox, oy, depth)) return;
        defer if (e.pending_regions.items.len > 0) e.flushPendingRegions(id); // [tagging]
        if (pm.enable_tables and id < e.tparts.len and e.tparts[id].hidden) return;
        const f = e.f;
        const n = &f.nodes.items[id];
        const cs = n.cs;
        if (n.kind != .anon_text and cs.display == .none) return;
        const l = f.tree.layout(n.lid);
        var x = ox + l.x;
        var y = oy + l.y;
        // a subtree that paints nothing into this page's window is not walked (a paginated
        // document's pages each walk the frame: without this a page costs the whole document)
        if (e.ext) |ex| if (ex.misses(e, id, y)) return;
        if (n.kind == .anon_text) return e.paintBox(id, x, y, depth);
        var m_open: ?Affine = null;
        var fragment: ?BoxFragment = null;
        var fragment_offset: f32 = 0;
        const saved_dy = e.plain_dy;
        defer e.plain_dy = saved_dy;
        if (localTransform(cs, x, y, l.w, l.h)) |m| {
            if (m.isTranslateOnly() and e.plain()) {
                x += m.e;
                y += m.f;
                e.plain_dy += m.f;
            } else {
                if (e.tf.mul(m).invert() == null) return;
                m_open = m;
                if (e.plain() and e.pass != null) if (e.passFragment(y, y + l.h)) |fr| {
                    const height = fr.s1 - fr.s0;
                    if (height > 0 and (fr.s0 != y or height != l.h)) {
                        fragment_offset = fr.s0 - y;
                        y = fr.s0;
                        m_open = localTransform(cs, x, y, l.w, height);
                        fragment = .{ .id = id, .window = .{ .top = 0, .bottom = height } };
                    }
                };
            }
        }
        if (!(cs.opacity > 0)) return;

        const base = e.s.depth();
        const saved_tf = e.tf;
        const saved_filter = e.filter;
        const saved_clips = e.clips.items.len;
        const saved_tpage = e.tpage;
        const saved_fragment = e.box_fragment;
        defer {
            e.s.popTo(base);
            e.tf = saved_tf;
            e.filter = saved_filter;
            e.clips.items.len = saved_clips;
            e.tpage = saved_tpage;
            e.box_fragment = saved_fragment;
        }
        // a transformed box paints with the page its layout box starts on (a pass of a paginated page)
        if (m_open != null and e.plain() and e.pass != null) e.tpage = fragment != null or e.passFragment(y, y) != null;
        if (fragment) |fr| e.box_fragment = fr;
        // a transform moves the box into its own space: the box paints at its origin
        var pushed_tf = false;
        const pushTf = pushBoxTransform;

        const effects = pm.enable_effects;
        const group = cs.opacity < 1 or (effects and (cs.mix_blend_mode != .normal or cs.isolation == .isolate or pfx.hasMask(cs)));
        if (cs.filter.len > 0 and e.unsupportedFilter(cs)) return;
        if (effects and cs.clip_path != null) {
            if (m_open) |m| {
                pushTf(e, m, &x, &y);
                y -= fragment_offset;
                if (fragment != null) e.plain_dy = 0;
                pushed_tf = true;
            }
            try e.pushClipPath(cs.clip_path.?, cs, x, y, l);
        }
        const mark = e.outlines.items.len;
        if (group) {
            if (effects and cs.mix_blend_mode != .normal) e.s.pushBlend(blendOf(cs.mix_blend_mode));
            if (effects and cs.isolation == .isolate) e.s.pushIsolated();
            if (cs.opacity < 1) e.s.pushOpacity(std.math.clamp(cs.opacity, 0, 1));
        }
        if (m_open != null and !pushed_tf) {
            pushTf(e, m_open.?, &x, &y);
            y -= fragment_offset;
            if (fragment != null) e.plain_dy = 0;
        }
        if (group and pfx.hasMask(cs)) try e.pushMaskImage(cs, x, y, l);
        if (cs.filter.len > 0) try e.composeFilter(cs);
        e.d.filter = e.filter;
        defer e.d.filter = saved_filter;
        // a stacking context paints the positioned boxes lifted to it after everything else inside
        // it (a frame's root: unless the page's walk collects them over its passes)
        const scope = e.stackingContext(id) or (id == e.f.root and !e.lift_on);
        const lq0 = e.lift_q.items.len;
        const lbase = e.clips.items.len;
        const saved_on = e.lift_on;
        defer e.lift_on = saved_on;
        if (scope) e.lift_on = true;
        // a context paints its floats, then the content of its in-flow boxes, after their
        // decorations (takumi `paint_phases`)
        // (a root that opens a group, a filter, a clip or a transform paints its content inside
        // them: its own context, not the page's one over the passes)
        const context = e.contextScope(id) or (id == e.f.root and (group or cs.filter.len > 0 or cs.clip_path != null or m_open != null));
        const fq0 = e.float_q.items.len;
        const cq0 = e.content_q.items.len;
        const saved_defer = e.defer_on;
        defer e.defer_on = saved_defer;
        if (context) e.defer_on = true;
        try e.paintBox(id, x, y, depth);
        if (context) try e.flushContext(fq0, cq0, lbase);
        if (scope) try e.flushLifts(lq0, lbase);
        // outlines close the stacking context, and every box Blink paints atomically (flex / grid
        // items, inline-blocks, floats, positioned boxes: takumi's per-item outline chunks)
        if (group or cs.clip_path != null or stacks(cs) or e.atomic(n)) try e.flushOutlines(mark, saved_clips);
    }

    /// Whether the subtree of `id`, met at frame y `y` of an untransformed walk, misses this
    /// paginated page's window (the lines a first / last page owns above / below it included).
    fn missesWindow(e: *const Emitter, lo: f32, hi: f32) bool {
        const win = e.window;
        if (!win.paged() or !e.plain()) return false;
        const top = @min(win.top, win.lines_top);
        const bottom = @max(win.bottom, win.lines_bottom);
        return hi < top or lo > bottom;
    }

    /// The end of a context: its floats, then its content.
    pub noinline fn flushContext(e: *Emitter, fq0: usize, cq0: usize, base: usize) Error!void {
        if (pm.enable_floats) try e.flushQueue(&e.float_q, fq0, base);
        try e.flushQueue(&e.content_q, cq0, base);
    }

    noinline fn atomic(e: *const Emitter, n: *const Node) bool {
        const cs = n.cs;
        if (cs.float != .none) return true;
        switch (cs.display) {
            .inline_block, .inline_flex, .inline_grid, .inline_table, .webkit_inline_box => return true,
            else => {},
        }
        if (n.parent != none) switch (e.f.nodes.items[n.parent].cs.display) {
            .flex, .inline_flex, .grid, .inline_grid, .webkit_box, .webkit_inline_box => return true,
            else => {},
        };
        return false;
    }

    // ------------------------------------------------------------------------------------------
    // stacking contexts (takumi-core `scene.rs` `build_layers`, `paint_chunk.rs`; CSS 2.1 appendix E)
    // ------------------------------------------------------------------------------------------

    noinline fn flexItem(e: *const Emitter, n: *const Node) bool {
        if (n.parent == none) return false;
        return switch (e.f.nodes.items[n.parent].cs.display) {
            .flex, .inline_flex, .grid, .inline_grid, .webkit_box, .webkit_inline_box => true,
            else => false,
        };
    }

    /// takumi `creates_stacking_context`: fixed, `z-index` where it applies, a transform, an
    /// effect group (opacity, blend, isolation, clip-path, mask, filter).
    noinline fn stackingContext(e: *const Emitter, id: u32) bool {
        const n = &e.f.nodes.items[id];
        if (n.kind == .anon_text) return false;
        const cs = n.cs;
        if (cs.position == .fixed or pfx.needsGroup(cs) or hasTransform(cs)) return true;
        return cs.z_index != null and (cs.position != .static or e.flexItem(n));
    }

    /// TextMask follows only containing blocks recorded inside its owner. A float with a
    /// self-painting layer contributes its own text paint, but not its ancestor's text mask.
    pub fn reachesTextClip(e: *const Emitter, id: u32, owner: u32) bool {
        const n = &e.f.nodes.items[id];
        if (n.cs.display == .none) return false;
        if (n.cs.float != .none and !e.flexItem(n) and
            (n.cs.position != .static or e.stackingContext(id))) return false;
        if ((n.cs.position == .absolute or n.cs.position == .fixed) and e.escapesClip(id, owner)) return false;
        return true;
    }

    /// A positioned box or a stacking context at `z-index` >= 0 met inside a stacking context:
    /// queued, it paints after the context's in-flow content, floats and the positioned boxes
    /// before it (takumi `PaintBucket::Positioned` / `Positive`, which belong to the nearest
    /// stacking context, not to the box's parent). Negative `z-index` paints in place.
    noinline fn liftOf(e: *Emitter, id: u32, ox: f32, oy: f32, depth: u32) Error!bool {
        if (!e.lift_on or id == e.lift_now or id == e.f.root) return false;
        const n = &e.f.nodes.items[id];
        if (n.kind == .anon_text or n.cs.display == .none) return false;
        const cs = n.cs;
        if (cs.position == .static and !e.stackingContext(id)) return false;
        const z: i64 = if (cs.position != .static or e.flexItem(n)) (cs.z_index orelse 0) else 0;
        if (z < 0 or e.partKind(id) != .none) return false;
        // (a collapsed table's decorations pass: the content pass meets it again)
        if (e.tphase == .decorations) return true;
        if (e.pre.len == 0) try e.preorder();
        const c0: u32 = @intCast(e.lift_clips.items.len);
        if (cs.position == .absolute or cs.position == .fixed) {
            for (e.clips.items) |ce| {
                if (ce.overflow_of != none and e.escapesClip(id, ce.overflow_of)) continue;
                try e.lift_clips.append(e.a, ce);
            }
        } else try e.lift_clips.appendSlice(e.a, e.clips.items);
        try e.lift_q.append(e.a, .{
            .fragment = e.box_fragment,
            .id = id,
            .ox = ox,
            .oy = oy,
            .tf = e.tf,
            .ctm = e.s.bd().ctm(),
            .clip0 = c0,
            .clip1 = @intCast(e.lift_clips.items.len),
            .depth = depth,
            .z = z,
            .pre = if (id < e.pre.len) e.pre[id] else 0,
            .pass = e.pass,
            .tpage = e.tpage,
            .in_repeat = e.in_repeat,
            .clip_y = e.clip_y,
            .plain_dy = e.plain_dy,
        });
        return true;
    }

    /// A box with a negative `z-index` (painted by its stacking context, `paintNegatives`).
    fn negativeZ(e: *const Emitter, n: *const Node) bool {
        if (n.kind == .anon_text) return false;
        const z = n.cs.z_index orelse return false;
        return z < 0 and (n.cs.position != .static or e.flexItem(n));
    }

    const Neg = struct { id: u32, ox: f32, oy: f32, z: i64, pre: u32, c0: u32, c1: u32 };

    /// CSS 2.1 appendix E step 3 (takumi's `PaintBucket::Negative`): the descendants of stacking
    /// context `ctx_id` (at `x`, `y`, its own decorations painted) with a negative `z-index` whose
    /// stacking context it is, by `z-index` then tree order, under the overflow clips of the boxes
    /// between (those their containing block chain passes through), before its in-flow content.
    noinline fn paintNegatives(e: *Emitter, ctx_id: u32, x: f32, y: f32, depth: u32) Error!void {
        if (!e.neg_any) return;
        var found: std.ArrayList(Neg) = .empty;
        var stack: std.ArrayList(ClipRec) = .empty;
        var kept: std.ArrayList(ClipRec) = .empty;
        const rcs = e.f.nodes.items[ctx_id].cs;
        if (ctx_id == e.f.root and (rcs.overflow_x != .visible or rcs.overflow_y != .visible)) {
            const ctx_ = e.ctx();
            const g = pm.Painter.geomOf(rcs, e.f.tree.layout(e.f.nodes.items[ctx_id].lid), x, y, &ctx_);
            if (try e.overflowPath(rcs, &g)) {
                var copy: Path = .empty;
                try copy.verbs.appendSlice(e.a, e.path.verbs.items);
                try copy.points.appendSlice(e.a, e.path.points.items);
                try stack.append(e.a, .{ .path = copy, .rule = .nonzero, .ctm = e.s.bd().ctm(), .overflow_of = ctx_id });
            }
        }
        try e.collectNegatives(ctx_id, x, y, &found, &stack, &kept, 0);
        if (found.items.len == 0) return;
        if (e.pre.len == 0) try e.preorder();
        for (found.items) |*it| it.pre = if (it.id < e.pre.len) e.pre[it.id] else 0;
        std.sort.insertion(Neg, found.items, {}, struct {
            fn lt(_: void, a: Neg, b: Neg) bool {
                return a.z < b.z or (a.z == b.z and a.pre < b.pre);
            }
        }.lt);
        for (found.items) |it| {
            if (e.fail_msg != null) return;
            const depth0 = e.s.depth();
            const saved_clips = e.clips.items.len;
            const saved_now = e.neg_now;
            defer {
                e.s.popTo(depth0);
                e.clips.items.len = saved_clips;
                e.neg_now = saved_now;
            }
            for (kept.items[it.c0..it.c1]) |ce| {
                e.s.pushClip(&ce.path, ce.rule);
                try e.clips.append(e.a, ce);
            }
            try e.neg_done.put(e.a, it.id, {});
            e.neg_now = it.id;
            try e.paintNode(it.id, it.ox, it.oy, depth + 1);
        }
    }

    noinline fn collectNegatives(e: *Emitter, v: u32, vx: f32, vy: f32, found: *std.ArrayList(Neg), stack: *std.ArrayList(ClipRec), kept: *std.ArrayList(ClipRec), level: u32) Error!void {
        if (level > 600) return;
        const f = e.f;
        var c = f.nodes.items[v].first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            const cn = &f.nodes.items[c];
            if (cn.kind == .anon_text or cn.cs.display == .none) continue;
            if (e.negativeZ(cn)) {
                const c0: u32 = @intCast(kept.items.len);
                for (stack.items) |ce| {
                    if (ce.overflow_of != none and e.escapesClip(c, ce.overflow_of)) continue;
                    try kept.append(e.a, ce);
                }
                try found.append(e.a, .{ .id = c, .ox = vx, .oy = vy, .z = cn.cs.z_index.?, .pre = 0, .c0 = c0, .c1 = @intCast(kept.items.len) });
                continue;
            }
            if (e.stackingContext(c)) continue;
            const l = f.tree.layout(cn.lid);
            const cx = vx + l.x;
            const cy = vy + l.y;
            const pushed = cn.cs.overflow_x != .visible or cn.cs.overflow_y != .visible;
            if (pushed) {
                const ctx_ = e.ctx();
                const g = pm.Painter.geomOf(cn.cs, l, cx, cy, &ctx_);
                if (!try e.overflowPath(cn.cs, &g)) continue;
                var copy: Path = .empty;
                try copy.verbs.appendSlice(e.a, e.path.verbs.items);
                try copy.points.appendSlice(e.a, e.path.points.items);
                try stack.append(e.a, .{ .path = copy, .rule = .nonzero, .ctm = e.s.bd().ctm(), .overflow_of = c });
            }
            try e.collectNegatives(c, cx, cy, found, stack, kept, level + 1);
            if (pushed) stack.items.len -= 1;
        }
    }

    /// Tree order of the frame's nodes (the order takumi numbers its paint items in).
    noinline fn preorder(e: *Emitter) Error!void {
        const f = e.f;
        e.pre = try e.a.alloc(u32, f.nodes.items.len);
        @memset(e.pre, 0);
        var stack: std.ArrayList(u32) = .empty;
        try stack.append(e.a, f.root);
        var k: u32 = 0;
        while (stack.pop()) |id| {
            e.pre[id] = k;
            k += 1;
            const mark = stack.items.len;
            var c = f.nodes.items[id].first_child;
            while (c != none) : (c = f.nodes.items[c].next) try stack.append(e.a, c);
            std.mem.reverse(u32, stack.items[mark..]);
        }
    }

    /// Paints the boxes lifted since `q0` by `z-index`, then tree order (those they lift in turn
    /// join the queue), re-entering the clips opened after `base` they were met under.
    noinline fn flushLifts(e: *Emitter, q0: usize, base: usize) Error!void {
        while (e.lift_q.items.len > q0) {
            if (e.fail_msg != null) {
                e.lift_q.items.len = q0;
                return;
            }
            var best = q0;
            for (e.lift_q.items[q0 + 1 ..], q0 + 1..) |it, i| {
                const b = e.lift_q.items[best];
                if (it.z < b.z or (it.z == b.z and it.pre < b.pre)) best = i;
            }
            const it = e.lift_q.orderedRemove(best);
            try e.paintLift(it, base);
        }
    }

    noinline fn paintLift(e: *Emitter, it: Lift, base: usize) Error!void {
        const saved_fragment = e.box_fragment;
        e.box_fragment = it.fragment;
        defer e.box_fragment = saved_fragment;
        const depth0 = e.s.depth();
        const saved_clips = e.clips.items.len;
        const saved_tf = e.tf;
        const saved_now = e.lift_now;
        const saved_pass = e.pass;
        const saved_tpage = e.tpage;
        const saved_rep = e.in_repeat;
        const saved_phase = e.tphase;
        const saved_cy = e.clip_y;
        const saved_dy = e.plain_dy;
        defer {
            e.s.popTo(depth0);
            e.clips.items.len = saved_clips;
            e.clip_y = saved_cy;
            e.plain_dy = saved_dy;
            e.tf = saved_tf;
            e.lift_now = saved_now;
            e.pass = saved_pass;
            e.tpage = saved_tpage;
            e.in_repeat = saved_rep;
            e.tphase = saved_phase;
        }
        const cur = e.s.bd().ctm();
        const inv = cur.invert() orelse Tf.identity;
        var k: usize = it.clip0 + @min(base, it.clip1 - it.clip0);
        while (k < it.clip1) : (k += 1) {
            const ce = e.lift_clips.items[k];
            try geom.transformed(e.a, &ce.path, inv.pre(ce.ctm), &e.path);
            e.s.pushClip(&e.path, ce.rule);
            try e.clips.append(e.a, ce);
        }
        if (!it.ctm.eql(cur)) e.s.pushTransform(inv.pre(it.ctm));
        e.tf = it.tf;
        e.lift_now = it.id;
        e.clip_y = it.clip_y;
        e.plain_dy = it.plain_dy;
        e.pass = it.pass;
        e.tpage = it.tpage;
        e.in_repeat = it.in_repeat;
        e.tphase = .all;
        try e.paintNode(it.id, it.ox, it.oy, it.depth);
    }

    // ------------------------------------------------------------------------------------------
    // page passes
    // ------------------------------------------------------------------------------------------

    /// The pass that paints this page's own fragments (and its text, links, repeats).
    fn home(e: *const Emitter) bool {
        return if (e.pass) |r| r == e.win_page else true;
    }

    /// Whether frame y range `y0`..`y1` meets page `r` (the first page reaching up, the last down).
    noinline fn onPage(e: *const Emitter, r: u32, y0: f32, y1: f32) bool {
        const pw = e.windows[r];
        const top = if (r == 0 and e.win_open_top) -std.math.inf(f32) else pw.top;
        const bottom = if (r + 1 == e.windows.len and e.win_open_bottom) std.math.inf(f32) else pw.bottom;
        if (y1 > y0) return y0 < bottom and y1 > top;
        return y0 >= top and y0 < bottom;
    }

    /// `layout_win`: `win` is the page window of the layout box's fragment (not this page's).
    const PassFragment = struct { win: Window, s0: f32, s1: f32, layout_win: bool = false };

    /// The fragment of a box (frame y range `y0`..`y1`) the current pass paints: its part on the
    /// pass's page, or, on this page's own pass, a box on none of the pages the passes visit;
    /// null: none.
    /// Whether a piece of paint spanning frame y range `y0`..`y1` (untransformed) is drawn by this
    /// pass on this page: its part on the pass's page, inside this page's window (takumi paints a
    /// table's collapsed borders per fragment, so a page draws only the borders it shows).
    pub noinline fn pieceShows(e: *const Emitter, y0: f32, y1: f32) bool {
        if (!e.plain()) return true;
        if (e.pass == null) return !e.window.excludes(@floor(y0), @ceil(y1));
        const fr = e.passFragment(y0, y1) orelse return false;
        return !e.window.excludes(@floor(fr.s0), @ceil(fr.s1));
    }

    noinline fn passFragment(e: *const Emitter, y0_in: f32, y1_in: f32) ?PassFragment {
        const r = e.pass orelse return .{ .win = e.window, .s0 = y0_in, .s1 = y1_in };
        // (the fragments are those of the layout box: a translated box's are where its layout box
        // is, painted moved by the translation)
        const dy = e.plain_dy;
        const y0 = y0_in - dy;
        const y1 = y1_in - dy;
        if (e.onPage(r, y0, y1)) {
            const pw = e.windows[r];
            return .{
                .win = pw,
                .s0 = (if (r == 0 and e.win_open_top) y0 else @max(y0, pw.top)) + dy,
                .s1 = (if (r + 1 == e.windows.len and e.win_open_bottom) y1 else @min(y1, pw.bottom)) + dy,
                .layout_win = true,
            };
        }
        if (r != e.win_page) return null;
        var q: u32 = if (r > 0) r - 1 else 0;
        while (q <= r + 1 and q < e.windows.len) : (q += 1) {
            if (e.onPage(q, y0, y1)) return null;
        }
        return .{ .win = e.window, .s0 = y0_in, .s1 = y1_in };
    }

    /// Whether a box of the current transformed space (`x`, `y`, `wd`, `h`, ink reaching `reach`
    /// past it) misses this page's window in whole pixels (takumi `SceneBounds::of_rect`,
    /// `outset_bounds`, `excludes_bounds`).
    noinline fn tfExcludes(e: *const Emitter, x: f32, y: f32, wd: f32, h: f32, reach: f32) bool {
        const t = e.tf;
        var lo = std.math.inf(f32);
        var hi = -std.math.inf(f32);
        for ([4][2]f32{ .{ x, y }, .{ x + wd, y }, .{ x, y + h }, .{ x + wd, y + h } }) |p| {
            const yy = t.b * p[0] + t.d * p[1] + t.f;
            lo = @min(lo, yy);
            hi = @max(hi, yy);
        }
        const pad = if (reach > 0) @ceil(reach * (@abs(t.b) + @abs(t.d))) else 0;
        return e.window.excludes(@floor(lo) - pad, @ceil(hi) + pad);
    }

    fn paintBox(e: *Emitter, id: u32, x: f32, y: f32, depth: u32) Error!void {
        const f = e.f;
        const n = &f.nodes.items[id];
        const kind = e.partKind(id);
        // a collapsed-border table pass: the decorations pass paints the parts' own decorations
        // and stops at the cells; the content pass paints the cells' insides as usual
        if (e.tphase == .decorations and kind == .none and n.kind != .anon_text) return;
        if (e.tphase == .decorations and n.kind == .anon_text) return;
        // [interactive] links / anchors / headings (once per box: table parts in their decorations pass)
        if (e.links) |lk| if ((e.tphase != .content or kind == .none) and e.home()) lk.onBox(e, id, x, y);
        // [lists] the marker box of a line container, where takumi's tree order paints it (an
        // inside marker paints with its line's text, which inside a context waits for the context's
        // content phase: it is kept by host until then)
        var marker: u32 = none;
        if (n.kind == .anon_box) if (@import("markers.zig").placement(f, id)) |pl| {
            marker = pl.node;
            switch (pl.how) {
                .before_text => try e.paintNode(pl.node, x, y, depth + 1),
                .in_text => {
                    e.dropInlineMarker(id);
                    try e.inline_markers.append(e.a, .{ .host = id, .node = pl.node, .x = x, .y = y, .depth = depth + 1 });
                },
            }
        };
        // (a frame's root that is no stacking context of its own is an in-flow box of takumi's root
        // context: the negative layer paints under its decorations, through its overflow clip)
        if (id == f.root and e.tphase == .all and n.kind != .anon_text and !e.stackingContext(id)) try e.paintNegatives(id, x, y, depth);
        const own_mode: Own = if (e.defer_on) .decorations else .all;
        try e.paintOwn(id, x, y, own_mode);
        // (the text did not paint on this page: neither does the marker inside it)
        if (marker != none and own_mode == .all) e.dropInlineMarker(id);
        if (n.kind == .anon_text or n.first_child == none) return;
        if (e.tphase == .decorations and kind == .cell) return;
        const saved_phase = e.tphase;
        defer e.tphase = saved_phase;
        if (kind == .cell or kind == .none) e.tphase = .all;
        if (pm.enable_tables and e.tphase == .all and n.kind != .anon_text) {
            if (f.tree.tableGeom(n.lid)) |tg| if (tg.is_table) return e.paintTable(id, x, y, depth);
        }
        const base = e.s.depth();
        const saved_clips = e.clips.items.len;
        const saved_cy = e.clip_y;
        defer {
            e.s.popTo(base);
            e.clips.items.len = saved_clips;
            e.clip_y = saved_cy;
        }
        if (!try e.pushOverflowOf(n, x, y)) return;
        if (e.stackingContext(id)) try e.paintNegatives(id, x, y, depth);
        var special = false;
        var c = n.first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            if (f.nodes.items[c].kind != .anon_text and stacks(f.nodes.items[c].cs)) special = true;
        }
        if (!special) {
            c = n.first_child;
            while (c != none) : (c = f.nodes.items[c].next) {
                if (c != marker) try e.paintNode(c, x, y, depth + 1);
            }
        } else {
            const sc = try e.sortedChildren(n);
            for (sc.items) |it| {
                if (it != marker) try e.paintNode(it, x, y, depth + 1);
            }
        }
        if (pm.enable_tables) try etable.collapsedAfter(e, id, x, y);
    }

    const Phase = enum { all, decorations, content };

    /// A table's children in paint order when its first header group or first footer group is out
    /// of place in the source: the header group first, the footer group last (Blink paints the
    /// sections in table order); null otherwise.
    noinline fn tableOrder(e: *Emitter, n: *const Node) Error!?[]const u32 {
        if (!pm.enable_tables or (n.cs.display != .table and n.cs.display != .inline_table)) return null;
        const f = e.f;
        var head: u32 = none;
        var foot: u32 = none;
        var count: usize = 0;
        var c = n.first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            count += 1;
            const cn = &f.nodes.items[c];
            if (cn.kind == .anon_text) continue;
            if (cn.cs.display == .table_header_group and head == none) head = c;
            if (cn.cs.display == .table_footer_group and foot == none) foot = c;
        }
        if (head == none and foot == none) return null;
        const out = try e.a.alloc(u32, count);
        var k: usize = 0;
        if (head != none) {
            out[k] = head;
            k += 1;
        }
        c = n.first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            if (c == head or c == foot) continue;
            out[k] = c;
            k += 1;
        }
        if (foot != none) {
            out[k] = foot;
            k += 1;
        }
        return out[0..k];
    }

    noinline fn partKind(e: *const Emitter, id: u32) etable.Kind {
        if (!pm.enable_tables or id >= e.tparts.len) return .none;
        return e.tparts[id].kind;
    }

    /// A table's inside, as takumi (Blink's table painters) paints it: the row groups', rows' and
    /// cells' decorations in table order (header group first, footer group last), then the
    /// collapsed borders, then the cells' content in document order.
    fn paintTable(e: *Emitter, id: u32, x: f32, y: f32, depth: u32) Error!void {
        const f = e.f;
        const n = &f.nodes.items[id];
        const base = e.s.depth();
        const saved_clips = e.clips.items.len;
        const saved_cy = e.clip_y;
        defer {
            e.s.popTo(base);
            e.clips.items.len = saved_clips;
            e.clip_y = saved_cy;
        }
        if (!try e.pushOverflowOf(n, x, y)) return;
        inline for (.{ Phase.decorations, Phase.content }) |ph| {
            e.tphase = ph;
            const order: ?[]const u32 = if (ph == .decorations) try e.tableOrder(n) else null;
            if (order) |o| {
                for (o) |it| try e.paintTableChild(it, x, y, depth + 1);
            } else {
                var c = n.first_child;
                while (c != none) : (c = f.nodes.items[c].next) try e.paintTableChild(c, x, y, depth + 1);
            }
            e.tphase = .all;
            if (ph == .decorations) try etable.collapsedAfter(e, id, x, y);
        }
    }

    /// A table section, and where this page repeats it (a repeated header / footer group, painted in
    /// its place in the table's order as takumi's scene holds it).
    fn paintTableChild(e: *Emitter, c: u32, x: f32, y: f32, depth: u32) Error!void {
        // [tagging] a footer group repeats from the page its table begins on: that first
        // occurrence carries the tags (Blink lays the footer out there first), the footer at the
        // table's end is a repeated fragment, as are the header's occurrences after the first
        const cn = &e.f.nodes.items[c];
        const footer = cn.kind != .anon_text and cn.cs.display == .table_footer_group;
        const began_before = e.plain() and y < e.window.top;
        {
            const saved_rep = e.in_repeat;
            defer e.in_repeat = saved_rep;
            if (footer and began_before) {
                for (e.repeats) |r| {
                    if (r.node == cn.lid) break;
                } else e.in_repeat = true;
            }
            try e.paintNode(c, x, y, depth);
        }
        if (!e.home()) return;
        const lid = cn.lid;
        for (e.repeats, 0..) |r, k| {
            if (r.node != lid) continue;
            e.rep_done[k] = true;
            const o = e.f.repeatOrigin(r);
            const saved_rep = e.in_repeat; // [tagging] a repeated fragment is an artifact
            e.in_repeat = !(footer and !began_before);
            defer e.in_repeat = saved_rep;
            if (o.id != none) try e.paintNode(o.id, o.ox, o.oy, depth);
        }
    }

    /// The box's own painting: shadows, background, inset shadows, border, deferred outline,
    /// image, text.
    /// What `paintOwn` paints: everything, or (inside a context) the decorations, queueing the
    /// content for the context's content phase, or that content.
    const Own = enum { all, decorations, content };

    noinline fn paintOwn(e: *Emitter, id: u32, x: f32, y: f32, mode: Own) Error!void {
        const f = e.f;
        const n = &f.nodes.items[id];
        if (e.no_content and (n.kind == .anon_text or (n.kind == .anon_box and n.para != null))) return;
        const cs = n.cs;
        const l = f.tree.layout(n.lid);
        const content_x = x + l.border.left + l.padding.left;
        const content_y = y + l.border.top + l.padding.top;
        const content_w = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
        if (n.kind == .anon_text) {
            if (mode == .decorations) return e.queueContent(id, x, y);
            return if (e.home()) etext.paintText(e, n, content_x, content_y, content_w);
        }
        // a collapsed table's content pass: the parts' decorations are painted already
        if (e.tphase == .content and e.partKind(id) != .none) {
            if (mode == .decorations) return e.queueContent(id, x, y);
            if (e.no_content) return;
            if (e.home() and (n.kind == .text or (n.kind == .anon_box and n.para != null))) {
                try etext.paintText(e, n, content_x, content_y, content_w);
            } else if (e.home() and e.in_repeat and e.partKind(id) != .cell) {
                // [tagging] each box of a repeated fragment draws its content in an artifact, an
                // empty one when it draws none (takumi `emit_tagged_content`)
                etag.end(e, etag.begin(e, id));
            }
            return;
        }
        // (takumi snaps a box in its paint space, a transformed one's included: Blink's paint
        // offset translation, `SnappedBox::new`)
        const c = e.snapCtx();
        const g = pm.Painter.geomOf(cs, l, x, y, &c);
        var as_part = false;
        const own = e.home();
        // a box whose paint (shadows, outline included) misses this page's window: nothing to draw
        // (takumi `excludes_bounds`; the page clip would drop it anyway). A table still registers its
        // parts; a row group / row / cell off the page paints nothing into its cells either.
        // A box a page boundary cuts paints its fragment on this page (takumi-pdf / Blink); a pass
        // over another page's fragments paints the box's fragment on that page, when its bounds in
        // whole pixels meet this page's window (tables: on this page's own pass only).
        var gd = g;
        const excluded = if (e.pass == null) blk: {
            const ex = e.plain() and (e.window.excludes(g.bx.y - paintReach(cs), g.bx.y + g.bx.h + paintReach(cs)) or e.clipExcludes(g.bx.y - paintReach(cs), g.bx.y + g.bx.h + paintReach(cs)));
            if (!ex and e.plain() and e.window.paged()) gd = e.windowSlice(id, cs, l, x, y, g, e.slice_win orelse e.window, false);
            break :blk ex;
        } else blk: {
            const reach = @ceil(paintReach(cs));
            if (!own and pm.enable_tables and (e.partKind(id) != .none or f.tree.tableGeom(n.lid) != null)) break :blk true;
            if (!e.plain()) {
                if (e.box_fragment) |fr| {
                    if (fr.id == id) gd = e.windowSlice(id, cs, l, x, y, g, fr.window, true);
                }
                break :blk !e.tpage or e.tfExcludes(x, y, l.w, l.h, reach);
            }
            const fr = e.passFragment(y, y + l.h) orelse break :blk true;
            gd = e.windowSlice(id, cs, l, x, y, g, fr.win, fr.layout_win);
            break :blk e.window.excludes(@floor(fr.s0) - reach, @ceil(fr.s1) + reach);
        };
        if (pm.enable_tables and mode != .content) {
            if (!excluded) {
                as_part = try etable.decorations(e, id, x, y, &g);
            } else try etable.registerParts(e, id);
        }
        // (inside a context the content waits for its phase; a collapsed table's decorations pass
        // has none)
        if (mode == .decorations and e.tphase != .decorations and (n.kind == .image or n.kind == .text or n.kind == .anon_box or (e.tagged and n.kind == .container and tagsm.emptyInlineBlock(f, id)))) try e.queueContent(id, x, y);
        if (excluded) {
            if (mode != .decorations and own and !e.no_content and (n.kind == .text or (n.kind == .anon_box and n.para != null))) try etext.paintText(e, n, content_x, content_y, content_w);
            return;
        }
        if (cs.visibility == .visible) {
            if (mode != .content) {
                if (!as_part) try e.paintDecorations(id, &gd, x, y);
                if (cs.outline_style != .none and cs.outline_style != .hidden) try e.deferOutline(cs, if (e.pass != null) &gd else &g);
            }
            if (n.kind == .image and mode != .decorations and !e.no_content) {
                // Fragment passes can revisit the same untransformed image on a page. Keep the
                // first draw: overlaying it again darkens translucent pixels and duplicates its
                // marked-content sequence. Transformed/repeated images have distinct paint roles.
                const deduplicate = e.plain() and !e.in_repeat and id < e.page_images.len;
                const duplicate = deduplicate and e.page_images[id];
                if (!duplicate) {
                    if (deduplicate) e.page_images[id] = true;
                    const began = etag.begin(e, id); // [tagging] the image's region
                    try e.paintImage(n, &g);
                    etag.end(e, began);
                    // Inline replaced content borrows its line container's region. Reopen that
                    // region after handing it to the image, even when no text follows the image.
                    if (n.el != none and f.dom.at(n.el).generated and n.parent != none and
                        f.nodes.items[n.parent].kind == .anon_box and e.home() and
                        !etext.onlyGeneratedImages(f, &f.nodes.items[n.parent])) etag.reopen(e, n.parent);
                }
            }
        }
        if (e.tphase == .decorations or !own or mode == .decorations or e.no_content) return;
        if (n.kind == .text or (n.kind == .anon_box and n.para != null)) try etext.paintText(e, n, content_x, content_y, content_w);
        // [tagging] a line container holding only boxes still opens its (empty) region
        if (n.kind == .anon_box and n.para == null) etag.end(e, etag.begin(e, id));
        // [tagging] so does a block whose inline content puts nothing on a line (takumi: every box
        // with an inline layout draws in a region, `draws(OwnContent::Inline)`)
        if (e.tagged and n.kind == .container and tagsm.emptyInlineBlock(f, id)) etag.end(e, etag.begin(e, id));
    }

    /// The geometry of the fragment of a box (border-box origin `x`, `y`) that this page's window
    /// shows, when a page boundary cuts the box: its border box cut to the window; with
    /// `box-decoration-break: slice` (the initial value) the cut edges lose their border, padding
    /// and corner radii, with `clone` every fragment keeps all of them. `g` when nothing cuts it.
    noinline fn windowSlice(e: *const Emitter, id: u32, cs: *const CS, l: anytype, x: f32, y_in: f32, g: Geom, win_in: Window, layout_win: bool) Geom {
        // Atomic inline boxes and the contents of an overflow clip are laid out whole.
        // Their paint may reach another page, but it must keep the original image/gradient
        // geometry instead of resizing the paint to that page's visible window.
        var ancestor = id;
        var ancestor_y = y_in - e.plain_dy;
        var mono_guard: u32 = 0;
        while (ancestor != none and mono_guard < 512) : (mono_guard += 1) {
            const an = &e.f.nodes.items[ancestor];
            if (an.parent != none and e.f.nodes.items[an.parent].kind == .anon_box) switch (an.cs.display) {
                .inline_block, .inline_flex, .inline_grid, .inline_table, .webkit_inline_box => return g,
                else => {},
            };
            if (ancestor != id and an.lid != none and (an.cs.overflow_y == .hidden or an.cs.overflow_y == .clip)) {
                const height = e.f.tree.layout(an.lid).h;
                // Only an unfragmented clip keeps its contents monolithic. A clip spanning
                // pages still gives its descendants page fragments in stitched space.
                for (e.windows) |pw| if (ancestor_y >= pw.top and ancestor_y + height <= pw.bottom) return g;
            }
            if (an.lid != none) ancestor_y -= e.f.tree.layout(an.lid).y;
            ancestor = an.parent;
        }
        // (in layout space: a translated box is cut where its layout box crosses a page boundary,
        // and its fragment paints where the translation puts it; `layout_win`: `win_in` is already
        // the page window of the layout fragment)
        const dy = e.plain_dy;
        const y = y_in - dy;
        var win = win_in;
        if (!layout_win) {
            win.top -= dy;
            win.bottom -= dy;
        }
        if (dy != 0 and !layout_win) {
            // (a layout box inside one page is one fragment, wherever it paints)
            for (e.windows) |pw| {
                if (y >= pw.top and y < pw.bottom) {
                    if (y + l.h <= pw.bottom) return g;
                    break;
                }
            }
        }
        const from_prev = y < win.top;
        const to_next = y + l.h > win.bottom;
        if (!from_prev and !to_next) return g;
        // inside boxes with `box-decoration-break: clone` that the boundary cuts too, the fragment
        // starts below and ends above their cloned border and padding (takumi: the content of a
        // cloned fragment is laid out inside its decorations)
        var t_in: f32 = 0;
        var b_in: f32 = 0;
        var p = e.f.nodes.items[id].parent;
        var guard: u32 = 0;
        while (p != none and guard < 512) : (guard += 1) {
            const pn = &e.f.nodes.items[p];
            if (pn.cs.box_decoration_break == .clone and pn.lid != none) {
                const pl = e.f.tree.layout(pn.lid);
                t_in += pl.border.top + pl.padding.top;
                b_in += pl.border.bottom + pl.padding.bottom;
            }
            p = pn.parent;
        }
        const s0 = @max(y, win.top + (if (from_prev) t_in else 0));
        var s1 = @min(y + l.h, win.bottom - (if (to_next) b_in else 0));
        // (a fragment that reaches past the page end: paged.zig `cellOverflow`)
        if (to_next and dy == 0 and e.extends.len > 0) {
            const lid = e.f.nodes.items[id].lid;
            for (e.extends) |xt| if (xt.node == lid and @abs(xt.at - win.bottom) < 1.0 / 64.0) {
                s1 = @min(y + l.h, xt.bottom);
                break;
            };
        }
        if (!(s1 > s0)) return g;
        const clone = cs.box_decoration_break == .clone;
        const Frag = struct { w: f32, h: f32, border: @TypeOf(l.border), padding: @TypeOf(l.padding) };
        var fr: Frag = .{ .w = l.w, .h = s1 - s0, .border = l.border, .padding = l.padding };
        if (!clone) {
            if (from_prev) {
                fr.border.top = 0;
                fr.padding.top = 0;
            }
            if (to_next) {
                fr.border.bottom = 0;
                fr.padding.bottom = 0;
            }
        }
        const c = e.ctx();
        var out = pm.Painter.geomOf(cs, &fr, x, s0 + dy, &c);
        if (!clone and out.rounded) {
            if (from_prev) {
                out.radii[0] = .{ 0, 0 };
                out.radii[1] = .{ 0, 0 };
            }
            if (to_next) {
                out.radii[2] = .{ 0, 0 };
                out.radii[3] = .{ 0, 0 };
            }
            var any = false;
            for (out.radii) |r| {
                if (r[0] > 0 and r[1] > 0) any = true;
            }
            out.rounded = any;
        }
        return out;
    }

    /// Shadows, background and border of a box (takumi `emit_box`).
    pub fn paintDecorations(e: *Emitter, id: u32, g: *const Geom, x: f32, y: f32) Error!void {
        const cs = e.f.nodes.items[id].cs;
        if (cs.box_shadow.len > 0) try e.paintOuterShadows(cs, g);
        try e.paintBackground(cs, g, x, y);
        if (textClipped(cs)) try e.paintTextClip(id, cs, g, x, y, null);
        if (cs.box_shadow.len > 0) try e.paintInsetShadows(cs, g);
        try border.paintBorder(&e.d, cs, g);
    }

    noinline fn sortedChildren(e: *Emitter, n: *const Node) Error!struct { items: []u32, n_low: usize } {
        const f = e.f;
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
            try items.append(e.a, .{ .id = c, .key = (layer * 4000000 + zc) * 1000000 + seq });
            seq += 1;
        }
        var i: usize = 1;
        while (i < items.items.len) : (i += 1) {
            const it = items.items[i];
            var j = i;
            while (j > 0 and items.items[j - 1].key > it.key) : (j -= 1) items.items[j] = items.items[j - 1];
            items.items[j] = it;
        }
        const out = try e.a.alloc(u32, items.items.len);
        for (out, items.items) |*o, it| o.* = it.id;
        return .{ .items = out, .n_low = n_low };
    }

    // ------------------------------------------------------------------------------------------
    // clips
    // ------------------------------------------------------------------------------------------

    noinline fn recordClip(e: *Emitter, path: *const Path, rule: sf.FillRule) Error!void {
        var copy: Path = .empty;
        try copy.verbs.appendSlice(e.a, path.verbs.items);
        try copy.points.appendSlice(e.a, path.points.items);
        try e.clips.append(e.a, .{ .path = copy, .rule = rule, .ctm = e.s.bd().ctm() });
    }

    /// Pushes a clip path (and records it for deferred outlines).
    noinline fn clipTo(e: *Emitter, path: *const Path, rule: sf.FillRule) Error!void {
        try e.recordClip(path, rule);
        e.s.pushClip(path, rule);
    }

    /// `overflow` other than visible: the (rounded) padding box, or a band unbounded along an
    /// axis that does not clip (takumi `ClipKind::Shape`). False: nothing inside can show.
    noinline fn pushOverflow(e: *Emitter, cs: *const CS, g: *const Geom) Error!bool {
        if (!try e.overflowPath(cs, g)) return false;
        try e.clipTo(&e.path, .nonzero);
        return true;
    }

    /// The overflow clip of a box as `e.path`; false = nothing inside is visible.
    noinline fn overflowPath(e: *Emitter, cs: *const CS, g: *const Geom) Error!bool {
        const pr = g.overflowRect();
        const xclip = cs.overflow_x != .visible;
        const yclip = cs.overflow_y != .visible;
        const unb: f32 = 1_000_000;
        e.path.reset();
        if (xclip and !yclip and cs.overflow_x == .clip) {
            if (!(pr.w > 0)) return false;
            try e.path.addRect(e.a, .{ .x = pr.x, .y = g.bx.y - unb, .w = pr.w, .h = g.bx.h + 2 * unb });
        } else if (yclip and !xclip and cs.overflow_y == .clip) {
            if (!(pr.h > 0)) return false;
            try e.path.addRect(e.a, .{ .x = g.bx.x - unb, .y = pr.y, .w = g.bx.w + 2 * unb, .h = pr.h });
        } else {
            if (!(pr.w > 0) or !(pr.h > 0)) return false;
            try dev.addRRectAt(e.a, &e.path, pr, g.padRadii(), g.bx.x, g.bx.y);
        }
        return true;
    }

    /// `clip-path` (painter `clipPathMask` geometry); a shape with no area clips everything.
    noinline fn pushClipPath(e: *Emitter, cp: *const style.computed.ClipPath, cs: *const CS, x: f32, y: f32, l: anytype) Error!void {
        const c = e.ctx();
        const gg = pm.Painter.geomOf(cs, l, x, y, &c);
        var box: Rect = .{ .x = x, .y = y, .w = l.w, .h = l.h };
        switch (cp.box) {
            .padding_box => box = gg.padRect(),
            .content_box => box = gg.contentRect(),
            else => {},
        }
        const bw = box.w;
        const bh = box.h;
        const path = &e.path2;
        path.reset();
        var rule: sf.FillRule = .nonzero;
        const a = e.a;
        if (cp.shape) |shape| switch (shape) {
            .inset => |in| {
                const t = in.sides[0].resolve(bh);
                const r = in.sides[1].resolve(bw);
                const b = in.sides[2].resolve(bh);
                const lf = in.sides[3].resolve(bw);
                const rc: Rect = .{ .x = box.x + lf, .y = box.y + t, .w = bw - lf - r, .h = bh - t - b };
                if (rc.w > 0 and rc.h > 0) {
                    var rr: Radii = undefined;
                    for (0..4) |i| {
                        rr[i] = .{ @max(0, in.radius[i][0].resolve(bw)), @max(0, in.radius[i][1].resolve(bh)) };
                        if (rr[i][0] <= 0 or rr[i][1] <= 0) rr[i] = .{ 0, 0 };
                    }
                    pm.scaleRadii(&rr, rc.w, rc.h);
                    try dev.addRRect(a, path, rc, if (pm.hasAnyRadius(rr)) rr else null);
                }
            },
            .circle => |cc| {
                const ccx = cc.at[0].resolve(bw);
                const ccy = cc.at[1].resolve(bh);
                const r: f32 = switch (cc.r) {
                    .closest_side => @min(@min(@abs(ccx), @abs(bw - ccx)), @min(@abs(ccy), @abs(bh - ccy))),
                    .farthest_side => @max(@max(@abs(ccx), @abs(bw - ccx)), @max(@abs(ccy), @abs(bh - ccy))),
                    .lp => |v| v.resolve(@sqrt(bw * bw + bh * bh) / std.math.sqrt2),
                };
                try ellipsePath(a, path, box.x + ccx, box.y + ccy, r, r);
            },
            .ellipse => |el| {
                const ecx = el.at[0].resolve(bw);
                const ecy = el.at[1].resolve(bh);
                try ellipsePath(a, path, box.x + ecx, box.y + ecy, shapeRadius(el.rx, ecx, bw), shapeRadius(el.ry, ecy, bh));
            },
            .polygon => |pg| {
                if (pg.rule == .evenodd) rule = .even_odd;
                for (pg.points, 0..) |q, i| {
                    const px = box.x + q[0].resolve(bw);
                    const py = box.y + q[1].resolve(bh);
                    if (i == 0) try path.moveTo(a, px, py) else try path.lineTo(a, px, py);
                }
                if (pg.points.len > 0) try path.close(a);
            },
            .path => |pd| {
                if (pd.rule == .evenodd) rule = .even_odd;
                if (comptime pm.enable_svg) {
                    var raw: Path = .empty;
                    svg_path.parse(a, pd.d, &raw, null) catch return error.OutOfMemory;
                    const dpr = e.f.opts.dpr;
                    try path.addPath(a, &raw, Affine.translate(box.x, box.y).mul(Affine.scale(dpr, dpr)));
                }
            },
        } else {
            if (cp.url.len > 0) return; // url() references: not supported (painted unclipped)
            var rr = pm.resolveRadiiRaw(cs, bw, bh);
            pm.scaleRadii(&rr, bw, bh);
            try dev.addRRect(a, path, box, if (pm.hasAnyRadius(rr)) rr else null);
        }
        if (geom.bounds(path) == null) {
            // no area: the degenerate path at the box origin hides everything (takumi `empty_path`)
            path.reset();
            try path.moveTo(a, x, y);
            try path.lineTo(a, x, y);
            try path.close(a);
        }
        try e.clipTo(path, rule);
    }

    // ------------------------------------------------------------------------------------------
    // outlines (painted at the end of their stacking context)
    // ------------------------------------------------------------------------------------------

    noinline fn deferOutline(e: *Emitter, cs: *const CS, g: *const Geom) Error!void {
        const c0: u32 = @intCast(e.outline_clips.items.len);
        try e.outline_clips.appendSlice(e.a, e.clips.items);
        try e.outlines.append(e.a, .{ .cs = cs, .g = g.*, .ctm = e.s.bd().ctm(), .clip0 = c0, .clip1 = @intCast(e.outline_clips.items.len) });
    }

    /// Paints the outlines deferred since `mark`, re-entering the clips opened after `base` and
    /// the transform each was drawn under.
    pub noinline fn flushOutlines(e: *Emitter, mark: usize, base: usize) Error!void {
        var i = mark;
        while (i < e.outlines.items.len) : (i += 1) {
            const dd = e.outlines.items[i];
            const depth0 = e.s.depth();
            const cur = e.s.bd().ctm();
            const inv = cur.invert() orelse Tf.identity;
            var k: usize = dd.clip0 + @min(base, dd.clip1 - dd.clip0);
            while (k < dd.clip1) : (k += 1) {
                const ce = e.outline_clips.items[k];
                // the clip path in the current user space
                const t = inv.pre(ce.ctm);
                try geom.transformed(e.a, &ce.path, t, &e.path);
                e.s.pushClip(&e.path, ce.rule);
            }
            if (!dd.ctm.eql(cur)) e.s.pushTransform(inv.pre(dd.ctm));
            try border.paintOutline(&e.d, dd.cs, &dd.g);
            e.s.popTo(depth0);
        }
        e.outlines.shrinkRetainingCapacity(mark);
    }

    // ------------------------------------------------------------------------------------------
    // backgrounds
    // ------------------------------------------------------------------------------------------

    const Area = struct { rect: Rect, radii: ?Radii };

    fn area(g: *const Geom, box: anytype) Area {
        return switch (box) {
            .padding_box => .{ .rect = g.padRect(), .radii = g.padRadii() },
            .content_box => .{ .rect = g.contentRect(), .radii = g.contentRadii() },
            else => .{ .rect = g.bx, .radii = g.outerRadii() },
        };
    }

    /// takumi `emit_background`: the colour over the `background-clip` shape, then the layers
    /// inside it.
    pub fn paintBackground(e: *Emitter, cs: *const CS, g: *const Geom, x: f32, y: f32) Error!void {
        _ = x;
        _ = y;
        const col = cs.resolveColor(cs.background_color);
        if (col.a == 0 and cs.background_image.len == 0) return;
        const clip_box = cs.bgColorClip();
        // Each background layer has its own clip. Text-clipped layers are painted with the glyph
        // coverage below; box-clipped layers and the background color still paint here.
        const ar = area(g, if (clip_box == .text) .border_box else clip_box);
        // background-clip: border-area (PDF build): the border ring, outer and padding edges filled
        // even-odd (takumi `FillShape::border_ring`); a dashed / dotted / double border, which leaves
        // gaps, masks the background with the painted border instead (takumi `border_mask`)
        const ring = comptime @hasField(style.computed.BgBox, "border_area");
        const is_ring = ring and clip_box == .border_area;
        const masked = is_ring and border.borderAreaGaps(cs, g);
        if (masked) {
            if (col.a != 0 and g.bx.w > 0 and g.bx.h > 0) {
                e.d.beginMask(.{ .stream = try e.borderMaskStream(cs, g), .kind = .alpha });
                e.d.fillRRect(g.bx, null, col);
                e.d.endLayer();
            }
        } else if (is_ring) {
            e.path.reset();
            try dev.addRRectAt(e.a, &e.path, g.bx, g.outerRadii(), g.bx.x, g.bx.y);
            try dev.addRRectAt(e.a, &e.path, g.padRect(), g.padRadii(), g.bx.x, g.bx.y);
            if (col.a != 0 and ar.rect.w > 0 and ar.rect.h > 0) e.d.fillPath(&e.path, 0, 0, .even_odd, col);
        } else if (clip_box != .text and col.a != 0 and ar.rect.w > 0 and ar.rect.h > 0) dev.fillRRectAt(&e.d, ar.rect, ar.radii, g.bx.x, g.bx.y, col);
        // only layers painted here count: a `background-clip: text` layer is painted through the
        // glyphs (`paintTextClip`), so it must not open an empty artifact section
        var any = false;
        for (cs.background_image, 0..) |im, li| {
            if (im != .none and cs.bgLayer(li).clip != .text) any = true;
        }
        if (!any or !(ar.rect.w > 0) or !(ar.rect.h > 0)) return;
        e.s.startArtifact();
        defer e.s.endArtifact(); // [tagging] after the clip is popped (takumi `in_artifact`)
        const base = e.s.depth();
        defer e.s.popTo(base);
        if (masked) {
            e.s.pushMask(.{ .stream = try e.borderMaskStream(cs, g), .kind = .alpha });
        } else if (is_ring) {
            e.s.pushClip(&e.path, .even_odd);
        } else {
            e.path.reset();
            try dev.addRRectAt(e.a, &e.path, ar.rect, ar.radii, g.bx.x, g.bx.y);
            e.s.pushClip(&e.path, .nonzero);
        }
        var i = cs.background_image.len;
        while (i > 0) {
            i -= 1;
            const layer = cs.bgLayer(i);
            if (layer.image == .none or layer.clip == .text) continue;
            var bm: style.computed.BlendMode = .normal;
            if (pm.enable_effects and cs.background_blend_mode.len > 0) bm = cs.background_blend_mode[i % cs.background_blend_mode.len];
            const blended = blendOf(bm) != .normal;
            if (blended) e.s.pushBlend(blendOf(bm));
            try e.paintLayer(e.s, cs, g, &layer, .background);
            if (blended) e.s.pop();
        }
    }

    /// takumi `border_mask_stream`: the box's border painted in black into a stream of its own.
    noinline fn borderMaskStream(e: *Emitter, cs: *const CS, g: *const Geom) Error!sf.Stream {
        var ms = sf.Surface.initStream(e.cx);
        const old = e.swapSurface(&ms);
        const saved_art = e.d.artifact;
        const saved_filter = e.d.filter;
        const saved_stack = e.d.stack;
        e.d.artifact = false;
        e.d.filter = null;
        e.d.stack = .empty;
        defer {
            _ = e.swapSurface(old);
            e.d.artifact = saved_art;
            e.d.filter = saved_filter;
            e.d.stack = saved_stack;
        }
        try border.paintBorderMask(&e.d, cs, g);
        return ms.finish();
    }

    /// takumi `fill_text_clip` + `background_fills`: inside the border box, the background's
    /// colour (clipped to the border box) and each image layer (a pattern clipped to its paint
    /// area) seen through the glyphs of the box's subtree, or of the runs of an inline box's
    /// fragment `frag` (takumi `FragmentBackground::paint`).
    pub fn paintTextClip(e: *Emitter, id: u32, cs: *const CS, g: *const Geom, x: f32, y: f32, frag: ?*const etext.FragmentMask) Error!void {
        var fills: std.ArrayList(text.GlyphBackground) = .empty;
        const rectPath = struct {
            fn f(em: *Emitter, r: LRect) Error!*const Path {
                const pth = try em.a.create(Path);
                pth.* = .empty;
                try geom.rectPath(em.a, pth, r);
                return pth;
            }
        }.f;
        const bx = LRect.ltrb(g.bx.x, g.bx.y, g.bx.x + g.bx.w, g.bx.y + g.bx.h) orelse return;
        const col = cs.resolveColor(cs.background_color);
        if (cs.bgColorClip() == .text and col.a != 0) try fills.append(e.a, .{ .fill = dev.fillOf(dev.filtered(e.filter, col), 1, .nonzero), .clip = try rectPath(e, bx) });
        var i = cs.background_image.len;
        while (i > 0) {
            i -= 1;
            const layer = cs.bgLayer(i);
            if (layer.image == .none or layer.clip != .text) continue;
            const t = e.layerTiling(cs, g, &layer, .background) orelse continue;
            // takumi `layer_pattern`: an axis with one tile repeats it farther apart than `dest` reaches
            const lone = struct {
                fn f(start: f32, end: f32, tile: f32, first: f32) f32 {
                    return end - start + tile + @abs(first - start);
                }
            }.f;
            const pw = if (t.nx > 1) t.tw + t.gap_x else lone(t.dest.l, t.dest.r, t.tw, t.xs[0]);
            const ph = if (t.ny > 1) t.th + t.gap_y else lone(t.dest.t, t.dest.b, t.th, t.ys[0]);
            var ts = sf.Surface.initStream(e.cx);
            try e.tileContent(&ts, cs, &layer, t.im, 0, 0, t.tw, t.th, Tf.scale(pt_per_px, pt_per_px));
            const pat = try e.a.create(sf.Pattern);
            pat.* = .{ .stream = ts.finish(), .transform = Tf.translate(t.xs[0], t.ys[0]), .width = pw, .height = ph };
            try fills.append(e.a, .{ .fill = .{ .paint = .{ .pattern = pat } }, .clip = try rectPath(e, t.dest) });
        }
        if (fills.items.len == 0) return;
        // (through the device: the clip opens the artifact the fills share, takumi `TextDevice`)
        const depth0 = e.d.depth();
        defer e.d.restore(depth0);
        e.d.pushClip(try rectPath(e, bx), 0, 0, .nonzero);
        if (frag) |m| return etext.paintFragmentClip(e, m, fills.items);
        try etext.paintClipText(e, id, x, y, fills.items);
    }

    const LayerKind = enum { background, mask };

    const Img = union(enum) {
        none,
        bitmap: struct { pm: ?*const raster.Pixmap, src: []const u8 },
        svg: []const u8,
    };

    /// Where a layer's tiles go (takumi `ImageTiling`): the image, the paint area `dest`, the
    /// first (up to two) tile origins per axis (`n` = 2: more than one tile), tile size and gaps.
    const Tiling = struct { im: Img, dest: LRect, xs: [2]f32, ys: [2]f32, nx: usize, ny: usize, tw: f32, th: f32, gap_x: f32, gap_y: f32 };

    fn layerTiling(e: *Emitter, cs: *const CS, g: *const Geom, layer: *const style.BgLayer, kind: LayerKind) ?Tiling {
        const image_geom = if (kind == .background) &(e.background_strip orelse g.*) else g;
        const o = area(image_geom, layer.origin).rect;
        var pa = area(image_geom, layer.clip);
        if (kind == .background and layer.clip == .border_box) {
            // Blink `ObscuredBorderOutsets`: an opaque, gap-free border side hides the background
            var ins: [4]f32 = .{ 0, 0, 0, 0 };
            for (0..4) |i| {
                const st = cs.border_style[i];
                const bw = g.bw[i];
                if (!(bw > 0) or cs.resolveColor(cs.border_color[i]).a != 255) continue;
                const eff: style.computed.BorderStyle = if (st == .double and bw < 3) .solid else st;
                if (eff == .hidden or eff == .none or eff == .dotted or eff == .dashed or eff == .double) continue;
                ins[i] = bw;
            }
            pa = .{ .rect = .{ .x = pa.rect.x + ins[3], .y = pa.rect.y + ins[0], .w = @max(0, pa.rect.w - ins[1] - ins[3]), .h = @max(0, pa.rect.h - ins[0] - ins[2]) }, .radii = null };
        }
        if (!(o.w > 0) or !(o.h > 0)) return null;
        var iw: f32 = 0;
        var ih: f32 = 0;
        var im: Img = .none;
        if (layer.image == .url) {
            if (e.f.r.resolveImage(layer.image.url)) |pmx| {
                im = .{ .bitmap = .{ .pm = pmx, .src = layer.image.url } };
                iw = @as(f32, @floatFromInt(pmx.width)) * e.f.opts.dpr;
                ih = @as(f32, @floatFromInt(pmx.height)) * e.f.opts.dpr;
            } else if (psvg.urlSvgSource(&e.p, layer.image.url)) |src| {
                im = .{ .svg = src };
                const sz = psvg.intrinsic(&e.p, src, o.w, o.h);
                iw = sz[0];
                ih = sz[1];
            } else if (eimg.sourceBytes(e.f.r, e.a, layer.image.url)) |bytes| {
                // a bitmap bm-render does not decode (a CMYK JPEG): its header size (takumi-core
                // `EncodedBitmap`), the bytes embedded as krilla takes them
                const hs = eimg.headerSize(bytes) orelse return null;
                im = .{ .bitmap = .{ .pm = null, .src = layer.image.url } };
                iw = @as(f32, @floatFromInt(hs[0])) * e.f.opts.dpr;
                ih = @as(f32, @floatFromInt(hs[1])) * e.f.opts.dpr;
            } else return null;
            if (!(iw > 0) or !(ih > 0)) return null;
        }
        const has_img = im != .none;
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
        if (!(tw > 0) or !(th > 0)) return null;
        // `round`: whole tiles (positioned with the tile size before rounding, as takumi does);
        // `space`: whole tiles spread to the area's edges, one tile placed like `no-repeat`
        const pos_w = tw;
        const pos_h = th;
        if (layer.repeat[0] == .round) tw = o.w / @max(1, @round(o.w / tw));
        if (layer.repeat[1] == .round) th = o.h / @max(1, @round(o.h / th));
        var tx = o.x + layer.position[0].resolve(o.w - pos_w);
        var ty = o.y + layer.position[1].resolve(o.h - pos_h);
        var rep_x = layer.repeat[0] != .no_repeat;
        var rep_y = layer.repeat[1] != .no_repeat;
        var gap_x: f32 = 0;
        var gap_y: f32 = 0;
        if (layer.repeat[0] == .space) {
            const n = @floor(o.w / tw);
            if (n >= 2) {
                gap_x = (o.w - n * tw) / (n - 1);
                tx = o.x;
            } else rep_x = false;
        }
        if (layer.repeat[1] == .space) {
            const n = @floor(o.h / th);
            if (n >= 2) {
                gap_y = (o.h - n * th) / (n - 1);
                ty = o.y;
            } else rep_y = false;
        }
        // the paint area (`dest`): the clip area, limited to the tile on a non-repeating axis
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
        if (!(x1 > x0) or !(y1 > y0)) return null;
        const dest = LRect.ltrb(x0, y0, x1, y1) orelse return null;
        var xs: [2]f32 = undefined;
        var ys: [2]f32 = undefined;
        const nx = if (rep_x) axisOrigins(tx, tw, tw + gap_x, x0, x1, &xs) else blk: {
            xs[0] = tx;
            break :blk @as(usize, 1);
        };
        const ny = if (rep_y) axisOrigins(ty, th, th + gap_y, y0, y1, &ys) else blk: {
            ys[0] = ty;
            break :blk @as(usize, 1);
        };
        if (nx == 0 or ny == 0) return null;
        return .{ .im = im, .dest = dest, .xs = xs, .ys = ys, .nx = nx, .ny = ny, .tw = tw, .th = th, .gap_x = gap_x, .gap_y = gap_y };
    }

    /// One background / mask layer (takumi `layer`): a single tile drawn directly (clipped to its
    /// paint area when it overflows it), several through a tiling pattern.
    fn paintLayer(e: *Emitter, s: *sf.Surface, cs: *const CS, g: *const Geom, layer: *const style.BgLayer, kind: LayerKind) Error!void {
        const t = e.layerTiling(cs, g, layer, kind) orelse return;
        const im = t.im;
        const dest = t.dest;
        const xs = t.xs;
        const ys = t.ys;
        const tw = t.tw;
        const th = t.th;
        const gap_x = t.gap_x;
        const gap_y = t.gap_y;
        const nx = t.nx;
        const ny = t.ny;
        if (nx == 1 and ny == 1) {
            const covers = dest.l <= xs[0] and dest.t <= ys[0] and dest.r >= xs[0] + tw and dest.b >= ys[0] + th;
            const depth0 = s.depth();
            if (!covers) {
                e.path.reset();
                try geom.rectPath(e.a, &e.path, dest);
                s.pushClip(&e.path, .nonzero);
            }
            try e.tileContent(s, cs, layer, im, xs[0], ys[0], tw, th, .identity);
            s.popTo(depth0);
            return;
        }
        // a tiling pattern of one tile at the origin, phased to the first tile
        var ts = sf.Surface.initStream(e.cx);
        const tile_space: Tf = if (kind == .background) Tf.scale(pt_per_px, pt_per_px) else .identity;
        try e.tileContent(&ts, cs, layer, im, 0, 0, tw, th, tile_space);
        const pat = try e.a.create(sf.Pattern);
        pat.* = .{ .stream = ts.finish(), .transform = Tf.translate(xs[0], ys[0]), .width = tw + gap_x, .height = th + gap_y };
        e.path.reset();
        try geom.rectPath(e.a, &e.path, dest);
        s.setFill(.{ .paint = .{ .pattern = pat } });
        s.drawPath(&e.path);
    }

    /// takumi `background_layer`: one tile at (`x`, `y`) of `tw` x `th`.
    fn tileContent(e: *Emitter, s: *sf.Surface, cs: *const CS, layer: *const style.BgLayer, im: Img, x: f32, y: f32, tw: f32, th: f32, pattern_space: Tf) Error!void {
        switch (im) {
            .bitmap => |b| {
                const ref = (try e.imageRef(b.pm, b.src)) orelse return;
                s.pushTransform(Tf.translate(x, y));
                s.drawImage(ref, tw, th);
                s.pop();
            },
            .svg => |src| try e.drawSvg(s, src, x, y, tw, th, cs.color, true),
            .none => {
                if (layer.image != .gradient) return;
                const paint = (try e.gradientPaint(layer.image.gradient, x, y, tw, th, cs.color, pattern_space)) orelse return;
                e.path.reset();
                try e.path.addRect(e.a, .{ .x = x, .y = y, .w = tw, .h = th });
                s.setFill(.{ .paint = paint });
                s.drawPath(&e.path);
            },
        }
    }

    /// Tile origins `phase + k * step` whose tiles meet `start..end` (takumi `axis_origins`);
    /// writes at most two (more = a pattern is needed).
    fn axisOrigins(phase: f32, tile: f32, step: f32, start: f32, end: f32, out: *[2]f32) usize {
        const ph: f64 = phase;
        const st: f64 = step;
        const first: i64 = @as(i64, @intFromFloat(@floor((@as(f64, start) - @as(f64, tile) - ph) / st))) + 1;
        const last: i64 = @as(i64, @intFromFloat(@ceil((@as(f64, end) - ph) / st))) - 1;
        if (last < first) return 0;
        const count: usize = @intCast(@min(last - first + 1, 2));
        var k: usize = 0;
        while (k < count) : (k += 1) out[k] = @floatCast(ph + @as(f64, @floatFromInt(first + @as(i64, @intCast(k)))) * st);
        return if (last - first + 1 > 2) 2 else count;
    }

    // ---- gradients (takumi `gradient_paint`)

    fn stopOf(e: *const Emitter, offset: f32, c: Color) sf.Stop {
        const fc = dev.filtered(e.filter, c);
        return .{ .offset = std.math.clamp(offset, 0, 1), .color = .{ fc.r, fc.g, fc.b }, .opacity = std.math.clamp(@as(f32, @floatFromInt(fc.a)) / 255.0, 0, 1) };
    }

    pub fn gradientPaint(e: *Emitter, gr: *const style.Gradient, x: f32, y: f32, tw: f32, th: f32, cur: Color, pattern_space: Tf) Error!?sf.Paint {
        if (!(tw > 0) or !(th > 0) or gr.stops.len == 0) return null;
        const a = e.a;
        switch (gr.kind) {
            .linear => {
                var dx: f32 = 0;
                var dy: f32 = 0;
                if (gr.corner_x != 0 or gr.corner_y != 0) {
                    dx = @as(f32, @floatFromInt(gr.corner_x)) * th;
                    dy = @as(f32, @floatFromInt(gr.corner_y)) * tw;
                    const nrm = @sqrt(dx * dx + dy * dy);
                    if (!(nrm > 0)) return null;
                    dx /= nrm;
                    dy /= nrm;
                } else {
                    const deg = @mod(gr.angle, 360);
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
                const len = @abs(tw * dx) + @abs(th * dy);
                if (!(len > 0)) return null;
                const rs = style.gradient.resolveGradientStops(a, gr, len, cur) catch return error.OutOfMemory;
                if (rs.len == 0) return null;
                const half = len / 2.0;
                const ccx = x + tw / 2.0;
                const ccy = y + th / 2.0;
                var t0: f32 = 0;
                var t1: f32 = len;
                var base: f32 = 0;
                var span: f32 = @max(len, 1.0e-6);
                if (gr.repeating) {
                    t0 = rs[0].offset_px;
                    t1 = rs[rs.len - 1].offset_px;
                    base = t0;
                    span = @max(t1 - t0, 1.0e-6);
                }
                const stops = try a.alloc(sf.Stop, rs.len);
                for (rs, 0..) |r, i| stops[i] = e.stopOf((r.offset_px - base) / span, r.color);
                return .{ .linear = .{
                    .x1 = ccx + (t0 - half) * dx,
                    .y1 = ccy + (t0 - half) * dy,
                    .x2 = ccx + (t1 - half) * dx,
                    .y2 = ccy + (t1 - half) * dy,
                    .transform = pattern_space,
                    .spread = if (gr.repeating) .repeat else .pad,
                    .stops = stops,
                } };
            },
            .radial => {
                const px = gr.position[0].resolve(tw);
                const py = gr.position[1].resolve(th);
                const dl = @abs(px);
                const dr = @abs(tw - px);
                const dt = @abs(py);
                const db = @abs(th - py);
                var rx: f32 = 0;
                var ry: f32 = 0;
                const circle = gr.shape == .circle;
                switch (gr.extent) {
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
                        if (gr.extent == .closest_corner) {
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
                        rx = gr.radius[0].resolve(tw);
                        ry = if (circle) rx else gr.radius[1].resolve(th);
                    },
                }
                rx = @max(rx, 1.0e-3);
                ry = @max(ry, 1.0e-3);
                const extent = @max(@max(rx, ry), 1.0e-6);
                const rs = style.gradient.resolveGradientStops(a, gr, rx, cur) catch return error.OutOfMemory;
                if (rs.len == 0) return null;
                // stop positions along the gradient ray, in px of the longer radius
                const pos = try a.alloc(f32, rs.len);
                for (rs, 0..) |r, i| pos[i] = r.offset_px / rx * extent;
                var stops: []sf.Stop = undefined;
                if (gr.repeating) {
                    stops = try e.expandedRadialStops(rs, pos, extent);
                } else {
                    stops = try a.alloc(sf.Stop, rs.len);
                    for (rs, 0..) |r, i| stops[i] = e.stopOf(pos[i] / extent, r.color);
                }
                const sx = @max(rx / extent, 1.0e-6);
                const sy = @max(ry / extent, 1.0e-6);
                return .{ .radial = .{
                    .fx = 0,
                    .fy = 0,
                    .fr = 0,
                    .cx = 0,
                    .cy = 0,
                    .cr = extent,
                    .transform = pattern_space.pre(Tf.row(sx, 0, 0, sy, x + px, y + py)),
                    .spread = .pad,
                    .stops = stops,
                } };
            },
            .conic => return e.conicPaint(gr, x, y, tw, th, cur, pattern_space),
        }
    }

    /// takumi `expanded_radial_stops`: one period of repeating stops tiled across the radius.
    fn expandedRadialStops(e: *const Emitter, rs: []const style.gradient.ResolvedStop, pos: []const f32, extent: f32) Error![]sf.Stop {
        const first = pos[0];
        const last = pos[pos.len - 1];
        var period = @max(last - first, 1.0e-6);
        const max_cycles: f32 = 512.0;
        const span = extent - first;
        const requested = @max(@ceil(span / period), 1.0);
        const cycles = @min(requested, max_cycles);
        const sc: f32 = if (cycles < requested) (span / cycles) / period else 1.0;
        period = period * sc;
        const nc: usize = @intFromFloat(cycles);
        var out: std.ArrayList(sf.Stop) = .empty;
        for (0..nc) |cyc| {
            const off = first + @as(f32, @floatFromInt(cyc)) * period;
            for (rs, 0..) |r, i| try out.append(e.a, e.stopOf((off + (pos[i] - first) * sc) / extent, r.color));
        }
        return out.items;
    }

    /// takumi's conic gradient: a sweep of 64 stops sampled from the painter's LUT.
    fn conicPaint(e: *Emitter, gr: *const style.Gradient, x: f32, y: f32, tw: f32, th: f32, cur: Color, pattern_space: Tf) Error!?sf.Paint {
        const rp = (try e.p.gradientPaint(gr, .{ .x = 0, .y = 0, .w = @trunc(tw), .h = @trunc(th) }, cur, Affine.identity)) orelse return null;
        const sh = try e.a.create(rpaint.Shader);
        sh.init(&rp);
        const tau: f32 = std.math.tau;
        const n_stops = 64;
        const stops = try e.a.alloc(sf.Stop, n_stops + 1);
        for (0..n_stops + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, n_stops);
            var px: u32 = 0;
            if (sh.kind == .solid) {
                px = sh.color;
            } else if (sh.lut_len > 0) {
                const mi = sh.lut_len - 1;
                const adj = t * tau;
                var idx: u32 = 0;
                if (sh.rep and sh.rep_period > 1.0e-6) {
                    const deg = adj / tau * 360.0;
                    const v = deg - sh.rep_start;
                    const wrapped = v - @floor(v / sh.rep_period) * sh.rep_period;
                    const scaled = wrapped * (@as(f32, @floatFromInt(mi)) / sh.rep_period);
                    const fl = @floor(scaled);
                    const smp = if (scaled - fl >= 0.5 - 0.001) fl + 1 else fl;
                    idx = @min(@as(u32, @intFromFloat(@max(smp, 0))), mi);
                } else {
                    const scaled = adj * (@as(f32, @floatFromInt(sh.lut_len)) / tau);
                    const nearest = @round(scaled);
                    const smp = if (@abs(scaled - nearest) <= 0.001) nearest else @floor(scaled);
                    idx = @min(@as(u32, @intFromFloat(@max(smp, 0))), mi);
                }
                px = sh.lut[idx];
            } else return null;
            var c4: [4]u8 = @bitCast(px);
            render.unpremultiply(&c4);
            stops[i] = e.stopOf(t, .{ .r = c4[0], .g = c4[1], .b = c4[2], .a = c4[3] });
        }
        const ccx = x + gr.position[0].resolve(@trunc(tw));
        const ccy = y + gr.position[1].resolve(@trunc(th));
        const pi_f: f32 = std.math.pi;
        var start_rad = gr.angle * (pi_f / 180.0);
        start_rad = start_rad - @floor(start_rad / tau) * tau;
        const rot = shading.toDegrees(start_rad) - 90.0;
        return .{ .sweep = .{
            .cx = ccx,
            .cy = ccy,
            .start = 0,
            .end = 360,
            .transform = pattern_space.pre(Tf.rotateAt(rot, ccx, ccy)),
            .spread = .pad,
            .stops = stops,
        } };
    }

    // ------------------------------------------------------------------------------------------
    // images
    // ------------------------------------------------------------------------------------------

    fn pixelFilter(e: *const Emitter) ?eimg.PixelFilter {
        const fl = e.filter orelse return null;
        return .{ .ctx = fl, .apply = struct {
            fn ap(c: *const anyopaque, rgba: [4]u8) [4]u8 {
                const f: *const dev.ColorFilter = @ptrCast(@alignCast(c));
                return f.apply(rgba);
            }
        }.ap, .key = fl.key() };
    }

    /// The image XObject for the image source `src` (decoded to `pmx` when bm-render decodes it):
    /// emit_image.zig `draw`; null when nothing is drawn (a failure is kept: `fail`).
    fn imageRef(e: *Emitter, pmx: ?*const raster.Pixmap, src: []const u8) Error!?w.Ref {
        // (`keep`: an embedded JPEG / PNG stream refers to these bytes until the file is written)
        const bytes = if (src.len > 0) eimg.sourceBytes(e.f.r, e.keep, src) else null;
        // (a source over the `limits` option fails the document, like one that cannot be decoded)
        if (src.len > 0) if (e.f.r.sourceOverLimit(src, bytes)) |fld| {
            e.fail("image exceeds limits.", render.Limits.name(fld));
            return null;
        };
        return switch (eimg.draw(e.cx, bytes, if (bytes) |b| e.f.r.contentHash(b) else 0, pmx, e.pixelFilter(), src)) {
            .ref => |r| r,
            .none => null,
            .fail => |f| blk: {
                e.fail(f.msg, f.arg);
                break :blk null;
            },
        };
    }

    /// takumi `draw_svg`: an SVG image as vector operators (emit_svg.zig), in the colours the CSS
    /// filter leaves them; `image_host` false for an inline `<svg>`.
    fn drawSvg(e: *Emitter, s: *sf.Surface, src: []const u8, x: f32, y: f32, dw: f32, dh: f32, current: Color, image_host: bool) Error!void {
        if (!(dw > 0) or !(dh > 0)) return;
        // (`keep`: the images an SVG holds are embedded from the bytes it decodes)
        if (comptime pm.enable_svg) _ = try esvg.draw(e.keep, s, src, x, y, dw, dh, .{
            .current = .{ .r = current.r, .g = current.g, .b = current.b, .a = current.a },
            .filter = e.filter,
            .image_host = image_host,
            .fonts = &e.f.r.fonts,
        });
    }

    /// takumi `emit_image`: the image placed by object-fit / object-position in the content box,
    /// clipped to it when it overflows or the box is rounded.
    fn paintImage(e: *Emitter, n: *const Node, g: *const Geom) Error!void {
        const cs = n.cs;
        const cr = g.contentRect();
        if (!(cr.w > 0) or !(cr.h > 0)) return;
        const svg_src = psvg.nodeSvgSource(n);
        if (n.img == null and svg_src == null and !(n.img_w > 0 and n.img_h > 0)) return;
        var iw = n.img_w;
        var ih = n.img_h;
        // an SVG with only a `viewBox` keeps its ratio under object-fit (takumi `source.size`)
        if (comptime pm.enable_svg) if (svg_src != null and !(iw > 0 and ih > 0)) {
            if (@import("../svg/svg.zig").parse(e.a, svg_src.?)) |doc| {
                if (@import("../svg/svg.zig").intrinsicSize(&doc).view_box) |vb| if (vb[2] > 0 and vb[3] > 0) {
                    iw = vb[2] * e.f.opts.dpr;
                    ih = vb[3] * e.f.opts.dpr;
                };
            } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        };
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
        if (!(dw > 0) or !(dh > 0)) return;
        var dx = cr.x + cs.object_position[0].resolve(cr.w - dw);
        var dy = cr.y + cs.object_position[1].resolve(cr.h - dh);
        const crad = g.contentRadii();
        const overflow = dx < cr.x or dy < cr.y or dx + dw > cr.x + cr.w or dy + dh > cr.y + cr.h;
        // takumi `replaced_content`: the placement is pixel-snapped (Blink `PixelSnappedIntRect`),
        // like the box itself (`geomOf`)
        if (e.plain()) {
            const sn = pm.snapRect(dx, dy, dw, dh);
            dx = sn.x;
            dy = sn.y;
            dw = sn.w;
            dh = sn.h;
            if (!(dw > 0) or !(dh > 0)) return;
        }
        const depth0 = e.s.depth();
        defer e.s.popTo(depth0);
        // (an SVG image clips itself to its canvas: emit_svg.zig, takumi `draw_svg`)
        if (crad != null or overflow) {
            e.path.reset();
            try dev.addRRectAt(e.a, &e.path, cr, crad, g.bx.x, g.bx.y);
            e.s.pushClip(&e.path, .nonzero);
        }
        if (svg_src) |src| return e.drawSvg(e.s, src, dx, dy, dw, dh, cs.color, n.el == render.none or !std.mem.eql(u8, e.f.dom.at(n.el).tag, "svg"));
        const ref = (try e.imageRef(n.img, n.src orelse "")) orelse return;
        e.s.pushTransform(Tf.translate(dx, dy));
        e.s.drawImage(ref, dw, dh);
        e.s.pop();
    }

    // ------------------------------------------------------------------------------------------
    // mask-image
    // ------------------------------------------------------------------------------------------

    /// takumi `mask`: the mask layers drawn into their own stream (colour filters off), pushed as
    /// an alpha soft mask (luminosity with `mask-mode: luminance`).
    noinline fn pushMaskImage(e: *Emitter, cs: *const CS, x: f32, y: f32, l: anytype) Error!void {
        var ms = sf.Surface.initStream(e.cx);
        const saved_filter = e.filter;
        e.filter = null;
        defer e.filter = saved_filter;
        const c = e.ctx();
        const g = pm.Painter.geomOf(cs, l, x, y, &c);
        var luma = false;
        var i = cs.mask_image.len;
        while (i > 0) {
            i -= 1;
            const ml = cs.maskLayer(i);
            if (ml.image == .none) continue;
            if (ml.mode == .luminance) luma = true;
            const bl: style.BgLayer = .{ .image = ml.image, .size = ml.size, .position = ml.position, .repeat = ml.repeat, .clip = ml.clip, .origin = ml.origin };
            try e.paintLayer(&ms, cs, &g, &bl, .mask);
        }
        e.s.pushMask(.{ .stream = ms.finish(), .kind = if (luma) .luminosity else .alpha });
    }

    // ------------------------------------------------------------------------------------------
    // box shadows (takumi painter/shadow.rs + takumi-pdf shadow.rs, `fill_shadow`)
    // ------------------------------------------------------------------------------------------

    pub fn paintOuterShadows(e: *Emitter, cs: *const CS, g: *const Geom) Error!void {
        var any = false;
        for (cs.box_shadow) |sh| {
            if (!sh.inset and cs.resolveColor(sh.color).a != 0) any = true;
        }
        if (!any) return;
        const radii: Radii = if (g.rounded) g.radii else pm.zero_radii;
        const bb: ClipBox = .{ .x = 0, .y = 0, .w = g.bx.w, .h = g.bx.h, .radii = radii };
        const d = &e.d;
        const depth0 = d.depth();
        e.path.reset();
        try bb.addTo(e.a, &e.path);
        d.pushClipOut(&e.path, g.bx.x, g.bx.y);
        var i = cs.box_shadow.len;
        while (i > 0) {
            i -= 1;
            const sh = cs.box_shadow[i];
            if (sh.inset) continue;
            const col = cs.resolveColor(sh.color);
            if (col.a == 0) continue;
            const rect = bb.outset(sh.spread);
            if (rect.empty()) continue;
            try e.fillShadow(.{ .inside = rect }, sh, col, g.bx.x, g.bx.y);
        }
        d.restore(depth0);
    }

    pub fn paintInsetShadows(e: *Emitter, cs: *const CS, g: *const Geom) Error!void {
        var any = false;
        for (cs.box_shadow) |sh| {
            if (sh.inset and cs.resolveColor(sh.color).a != 0) any = true;
        }
        if (!any) return;
        const pr = g.padRect();
        const pad: ClipBox = .{ .x = pr.x - g.bx.x, .y = pr.y - g.bx.y, .w = pr.w, .h = pr.h, .radii = g.padRadii() orelse pm.zero_radii };
        if (pad.empty()) return;
        const d = &e.d;
        const depth0 = d.depth();
        e.path.reset();
        try pad.addTo(e.a, &e.path);
        d.pushClip(&e.path, g.bx.x, g.bx.y, .nonzero);
        var i = cs.box_shadow.len;
        while (i > 0) {
            i -= 1;
            const sh = cs.box_shadow[i];
            if (!sh.inset) continue;
            const col = cs.resolveColor(sh.color);
            if (col.a == 0) continue;
            const hole = pad.outset(-sh.spread);
            if (hole.empty()) {
                e.path.reset();
                try pad.addTo(e.a, &e.path);
                d.fillPath(&e.path, g.bx.x, g.bx.y, .nonzero, col);
                continue;
            }
            const reach = sh.blur * 1.5 + 1.0;
            const px0 = pad.x - sh.x;
            const py0 = pad.y - sh.y;
            const bounds: LRect = .{
                .l = @min(px0, hole.x) - reach,
                .t = @min(py0, hole.y) - reach,
                .r = @max(px0 + pad.w, hole.x + hole.w) + reach,
                .b = @max(py0 + pad.h, hole.y + hole.h) + reach,
            };
            try e.fillShadow(.{ .outside = .{ .hole = hole, .bounds = bounds } }, sh, col, g.bx.x, g.bx.y);
        }
        d.restore(depth0);
    }

    const ShadowShape = union(enum) {
        inside: ClipBox,
        outside: struct { hole: ClipBox, bounds: LRect },

        fn spread(s: ShadowShape, by: f32) ShadowShape {
            return switch (s) {
                .inside => |r| .{ .inside = r.outset(by) },
                .outside => |o| .{ .outside = .{ .hole = o.hole.outset(-by), .bounds = o.bounds } },
            };
        }
    };

    /// takumi-pdf `fill_shadow`: the shape in the shadow colour, a blur as eight spread bands
    /// under one opacity group for a translucent colour.
    fn fillShadow(e: *Emitter, shape: ShadowShape, sh: style.Shadow, col_in: Color, ox: f32, oy: f32) Error!void {
        const d = &e.d;
        const col = dev.filtered(e.filter, col_in);
        const at_x = sh.x + ox;
        const at_y = sh.y + oy;
        var bands_buf: [9]Band = undefined;
        const bands = bandsOf(sh.blur, &bands_buf);
        const grouped = bands.len > 1 and col.a < 255;
        var band_col = col;
        if (grouped) {
            band_col.a = 255;
            d.beginLayer(@as(f32, @floatFromInt(col.a)) / 255.0);
        }
        for (bands) |band| {
            const bs = shape.spread(band.spread);
            e.path.reset();
            var rule: sf.FillRule = .nonzero;
            switch (bs) {
                .inside => |r| try r.addTo(e.a, &e.path),
                .outside => |o| {
                    try e.path.addRect(e.a, .{ .x = o.bounds.l, .y = o.bounds.t, .w = o.bounds.r - o.bounds.l, .h = o.bounds.b - o.bounds.t });
                    if (!o.hole.empty()) try o.hole.addTo(e.a, &e.path);
                    rule = .even_odd;
                },
            }
            const fill = dev.fillOf(band_col, band.alpha, rule);
            e.path2.reset();
            try geom.translated(e.a, &e.path, at_x, at_y, &e.path2);
            if (!d.isHidden()) {
                const art = d.artifact and d.depth() == 0;
                if (art) e.s.startArtifact();
                e.s.setFill(fill);
                e.s.drawPath(&e.path2);
                if (art) e.s.endArtifact();
            }
        }
        if (grouped) d.endLayer();
    }
};

/// A rounded rectangle relative to a box (takumi `ClipBox`).
const ClipBox = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radii: Radii,

    fn empty(c: ClipBox) bool {
        return c.w <= 0 or c.h <= 0;
    }

    /// takumi `ClipBox::outset`: radii by css-backgrounds-3's outset-adjusted radius when it
    /// grows, plain shrink when it does not.
    fn outset(c: ClipBox, spread: f32) ClipBox {
        var r = c.radii;
        if (spread > 0) {
            var used = c.radii;
            pm.scaleRadii(&used, c.w, c.h);
            for (&r, used) |*corner, u| {
                if (u[0] <= 0 and u[1] <= 0) {
                    corner.* = .{ 0, 0 };
                    continue;
                }
                const cov = 2.0 * @min(u[0] / c.w, u[1] / c.h);
                inline for (0..2) |k| {
                    const radius = u[k];
                    corner[k] = if (radius > spread or cov > 1.0) radius + spread else blk: {
                        const q = 1.0 - radius / spread;
                        break :blk radius + spread * (1.0 - q * q * q * (1.0 - cov * cov * cov));
                    };
                }
            }
        } else if (spread != 0) {
            for (&r) |*corner| {
                if (corner[0] > 0) corner[0] = @max(corner[0] + spread, 0);
                if (corner[1] > 0) corner[1] = @max(corner[1] + spread, 0);
            }
        }
        return .{ .x = c.x - spread, .y = c.y - spread, .w = @max(c.w + 2 * spread, 0), .h = @max(c.h + 2 * spread, 0), .radii = r };
    }

    fn addTo(c: ClipBox, a: Allocator, p: *Path) error{OutOfMemory}!void {
        const rect: Rect = .{ .x = c.x, .y = c.y, .w = c.w, .h = c.h };
        var rr = c.radii;
        pm.scaleRadii(&rr, c.w, c.h);
        try dev.addRRect(a, p, rect, if (pm.hasAnyRadius(rr)) rr else null);
    }
};

// ---- blur bands (takumi-pdf shadow.rs)

pub const Band = struct { spread: f32, alpha: f32 };

fn erfc(x_in: f32) f32 {
    const coef = [5]f32{ 0.254_829_6, -0.284_496_74, 1.421_413_7, -1.453_152, 1.061_405_4 };
    const sign: f32 = if (x_in < 0) -1.0 else 1.0;
    const x = @abs(x_in);
    const t = 1.0 / (1.0 + 0.327_591_1 * x);
    var poly: f32 = 0;
    var i: usize = coef.len;
    while (i > 0) {
        i -= 1;
        poly = (poly + coef[i]) * t;
    }
    // expf as glibc rounds it (correctly rounded through f64)
    // (the engine's own f64 exp, not `@exp`: on macOS that binds to libSystem's libm; see emit_geom.zig `Tf.rotate`)
    const ex: f32 = @floatCast(@import("../style/cmath.zig").exp(@as(f64, -x * x)));
    const erf = 1.0 - poly * ex;
    return 1.0 - sign * erf;
}

fn coverage(distance: f32) f32 {
    return 0.5 * erfc(std.math.sqrt2 * distance);
}

/// The bands, outermost first, compositing to the blur's coverage; the opaque core last.
pub fn bandsOf(blur: f32, out: *[9]Band) []Band {
    if (!(blur > 0)) {
        out[0] = .{ .spread = 0, .alpha = 1 };
        return out[0..1];
    }
    var covered: f32 = 0;
    for (0..8) |idx| {
        const t = (@as(f32, @floatFromInt(idx)) + 1.0) / 8.0;
        const target = coverage(1.0 - t);
        const alpha = std.math.clamp((target - covered) / (1.0 - covered), 0, 1);
        covered = target;
        out[idx] = .{ .spread = blur * (1.0 - t), .alpha = alpha };
    }
    out[8] = .{ .spread = 0, .alpha = 1 };
    return out[0..9];
}

// ---- helpers

fn blendOf(m: style.computed.BlendMode) sf.Blend {
    return switch (m) {
        .normal, .plus_darker, .plus_lighter => .normal,
        .multiply => .multiply,
        .screen => .screen,
        .overlay => .overlay,
        .darken => .darken,
        .lighten => .lighten,
        .color_dodge => .color_dodge,
        .color_burn => .color_burn,
        .hard_light => .hard_light,
        .soft_light => .soft_light,
        .difference => .difference,
        .exclusion => .exclusion,
        .hue => .hue,
        .saturation => .saturation,
        .color => .color,
        .luminosity => .luminosity,
    };
}

/// How far a box's own paint reaches past its border box (box shadows, outline).
/// Per frame, once per document: each node's border-box y as the page walk meets it (`paintNode`,
/// before its transform; NaN under a transform that is not a translation, where the walk is not
/// culled), the y range its subtree can paint into (its boxes with their shadow / outline reach
/// and a font size for glyphs overflowing their line), and the tree order (`Emitter.pre`).
pub const Extents = struct {
    y: []f32,
    lo: []f32,
    hi: []f32,
    pre: []u32,

    pub fn compute(a: Allocator, f: *const Frame) Error!Extents {
        return computeWith(a, f, true);
    }

    /// `compute` without the font size a glyph may overflow its line by (`glyphs` false): what
    /// the boxes paint, a line of text being painted on the page that holds it only.
    pub fn computeWith(a: Allocator, f: *const Frame, glyphs: bool) Error!Extents {
        const nn = f.nodes.items.len;
        const ex: Extents = .{ .y = try a.alloc(f32, nn), .lo = try a.alloc(f32, nn), .hi = try a.alloc(f32, nn), .pre = try a.alloc(u32, nn) };
        @memset(ex.y, std.math.nan(f32));
        @memset(ex.lo, std.math.inf(f32));
        @memset(ex.hi, -std.math.inf(f32));
        @memset(ex.pre, 0);
        if (nn == 0) return ex;
        // the children's origin (the parent's y after a translation), tree order
        const org = try a.alloc(f32, nn);
        @memset(org, std.math.nan(f32));
        const order = try a.alloc(u32, nn);
        var stack: std.ArrayList(u32) = .empty;
        try stack.append(a, f.root);
        var k: u32 = 0;
        while (stack.pop()) |id| {
            ex.pre[id] = k;
            order[k] = id;
            k += 1;
            const mark = stack.items.len;
            var c = f.nodes.items[id].first_child;
            while (c != none) : (c = f.nodes.items[c].next) try stack.append(a, c);
            std.mem.reverse(u32, stack.items[mark..]);
        }
        for (order[0..k]) |id| {
            const n = &f.nodes.items[id];
            const cs = n.cs;
            if (n.kind != .anon_text and cs.display == .none) continue;
            const l = f.tree.layout(n.lid);
            const oy: f32 = if (id == f.root) 0 else if (n.parent != none) org[n.parent] else std.math.nan(f32);
            var y = oy + l.y;
            ex.y[id] = y;
            if (n.kind != .anon_text) if (localTransform(cs, 0, y, l.w, l.h)) |m| {
                y = if (m.isTranslateOnly()) y + m.f else std.math.nan(f32);
            };
            org[id] = y;
            if (y != y) {
                ex.lo[id] = -std.math.inf(f32);
                ex.hi[id] = std.math.inf(f32);
                continue;
            }
            var reach = paintReach(cs);
            if (glyphs) {
                reach += cs.font_size;
                for (cs.text_shadow) |sh| reach = @max(reach, cs.font_size + @abs(sh.y) + 3 * @max(sh.blur, 0));
            }
            ex.lo[id] = y - reach;
            ex.hi[id] = y + @max(l.h, 0) + reach;
            if (n.parent != none and f.nodes.items[n.parent].cs.display == .table_cell and tagsm.standsForParent(f, id)) {
                const cell = f.tree.layout(f.nodes.items[n.parent].lid);
                ex.lo[id] = @min(ex.lo[id], org[n.parent] - reach);
                ex.hi[id] = @max(ex.hi[id], org[n.parent] + cell.h + reach);
            }
        }
        // subtrees: children before their parents
        var i = k;
        while (i > 1) {
            i -= 1;
            const id = order[i];
            const p = f.nodes.items[id].parent;
            if (p == none) continue;
            ex.lo[p] = @min(ex.lo[p], ex.lo[id]);
            ex.hi[p] = @max(ex.hi[p], ex.hi[id]);
        }
        return ex;
    }

    /// Whether the walk can skip node `id`, met at frame y `y`, on this page. The first page walks
    /// everything: the document-wide collections (headings, anchors, link runs: interactive.zig)
    /// are made during its walk.
    fn misses(ex: *const Extents, e: *const Emitter, id: u32, y: f32) bool {
        if (id >= ex.y.len or e.in_repeat or e.walk_all) return false;
        const want = ex.y[id];
        if (!(@abs(want - y) < 0.001)) return false;
        return e.missesWindow(ex.lo[id], ex.hi[id]);
    }
};

fn paintReach(cs: *const CS) f32 {
    var r: f32 = 0;
    for (cs.box_shadow) |sh| {
        if (!sh.inset) r = @max(r, sh.blur * 1.5 + @max(sh.spread, 0) + @max(@abs(sh.x), @abs(sh.y)));
    }
    if (cs.outline_style != .none and cs.outline_style != .hidden) r = @max(r, @max(cs.outline_width, 0) + @abs(cs.outline_offset));
    return r;
}

/// A fixed box `repeatingFixed` takes out of the flow.
noinline fn repeats(f: *const Frame, id: u32) bool {
    var p = f.nodes.items[id].parent;
    while (p != none) : (p = f.nodes.items[p].parent) {
        const pcs = f.nodes.items[p].cs;
        if (pcs.display == .none or pcs.position == .fixed or hasTransform(pcs) or pcs.filter.len > 0) return false;
    }
    return true;
}

/// `background-clip: text` on the colour or any layer.
pub fn textClipped(cs: *const CS) bool {
    if (cs.bgColorClip() == .text) return true;
    for (cs.background_clip) |bc| {
        if (bc == .text) return true;
    }
    return false;
}

fn stacks(cs: *const CS) bool {
    return cs.z_index != null or cs.position != .static or pfx.needsGroup(cs) or cs.offset_path != null or cs.transform.len > 0 or cs.rotate != 0 or cs.scale[0] != 1 or cs.scale[1] != 1;
}

/// `layout.fragment.Options.extent_fn` of a paginated frame: how far down its boxes reach once
/// transformed (takumi `scrollable_block_end` over every page, `transformed_rect_extents` of the
/// border boxes; the boxes inside one clipping its overflow and the fixed boxes left out), null
/// when no box is transformed or relatively offset (takumi `moves_boxes`).
pub fn movedExtent(f: *Frame) ?f32 {
    var moves = false;
    for (f.nodes.items) |*n| {
        if (n.kind == .anon_text) continue;
        if (n.cs.position == .relative or hasTransform(n.cs)) {
            moves = true;
            break;
        }
    }
    if (!moves or f.root == none) return null;
    const Item = struct { id: u32, ox: f32, oy: f32, m: Affine };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(f.a);
    var end: f32 = 0;
    stack.append(f.a, .{ .id = f.root, .ox = 0, .oy = 0, .m = Affine.identity }) catch return end;
    while (stack.pop()) |it| {
        const n = &f.nodes.items[it.id];
        if (n.kind == .anon_text or n.lid == none) continue;
        const cs = n.cs;
        if (cs.display == .none or (cs.position == .fixed and it.id != f.root)) continue;
        const l = f.tree.layout(n.lid);
        const x = it.ox + l.x;
        const y = it.oy + l.y;
        var m = it.m;
        if (localTransform(cs, x, y, l.w, l.h)) |t| m = m.mul(t);
        for ([4][2]f32{ .{ x, y }, .{ x + l.w, y }, .{ x, y + l.h }, .{ x + l.w, y + l.h } }) |p| {
            const yy = m.b * p[0] + m.d * p[1] + m.f;
            if (yy == yy) end = @max(end, yy);
        }
        // (what a box clipping its block overflow clips adds nothing)
        if (it.id != f.root and (cs.overflow_y != .visible or (cs.overflow_x != .visible and cs.overflow_x != .clip))) continue;
        var c = n.first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            stack.append(f.a, .{ .id = c, .ox = x, .oy = y, .m = m }) catch return end;
        }
    }
    return end;
}

/// `transform`, `rotate`, `scale` or `translate` (takumi `has_transform_related_property`).
pub fn hasTransform(cs: *const CS) bool {
    return cs.offset_path != null or cs.transform.len > 0 or cs.rotate != 0 or cs.scale[0] != 1 or cs.scale[1] != 1 or cs.translate[0].px != 0 or cs.translate[0].pct != 0 or cs.translate[1].px != 0 or cs.translate[1].pct != 0 or cs.translate[0].calc != null or cs.translate[1].calc != null;
}

pub noinline fn localTransform(cs: *const CS, x: f32, y: f32, wd: f32, h: f32) ?Affine {
    if (!hasTransform(cs)) return null;
    const d2r: f32 = std.math.pi / 180.0;
    const ox = x + cs.transform_origin[0].resolve(wd);
    const oy = y + cs.transform_origin[1].resolve(h);
    var m = Affine.translate(ox, oy);
    m = m.mul(Affine.translate(cs.translate[0].resolve(wd), cs.translate[1].resolve(h)));
    if (cs.rotate != 0) m = m.mul(Affine.rotate(cs.rotate * d2r));
    if (cs.scale[0] != 1 or cs.scale[1] != 1) m = m.mul(Affine.scale(cs.scale[0], cs.scale[1]));
    if (@import("../style/motion_path.zig").transform(cs, wd, h)) |motion| m = m.mul(motion);
    for (cs.transform) |op| {
        const t: Affine = switch (op) {
            .translate => |v| Affine.translate(v[0].resolve(wd), v[1].resolve(h)),
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
    try path.moveTo(a, cx + rx, cy);
    try path.cubicTo(a, cx + rx, cy + oy, cx + ox, cy + ry, cx, cy + ry);
    try path.cubicTo(a, cx - ox, cy + ry, cx - rx, cy + oy, cx - rx, cy);
    try path.cubicTo(a, cx - rx, cy - oy, cx - ox, cy - ry, cx, cy - ry);
    try path.cubicTo(a, cx + ox, cy - ry, cx + rx, cy - oy, cx + rx, cy);
    try path.close(a);
}

// ---------------------------------------------------------------------------------------------
// pages and the document
// ---------------------------------------------------------------------------------------------

/// Paints the frame restricted to `win` onto `e.s`, a page of `page` (CSS px): the window's top
/// lands at the top of the page's content box (takumi-pdf `PageComposer::compose` /
/// `ContentWindow::emit`): the paper colour over the whole page; the repeated `position: fixed`
/// boxes with a negative `z-index`, each in a window of its own (clipped to the content box,
/// translated to it, unwindowed: takumi `RepeatBounds::Content { below: true }`); the frame
/// (clipped to the content box in paged mode, translated so the window's top meets it) with the
/// page's other repeats (repeated table header / footer groups) after it; then the other fixed
/// boxes. Text lines of a paginated frame are already at their page positions
/// (`Frame.textLayout`).
pub fn paintPage(e: *Emitter, page: PageBox, win: Window) Error!void {
    const s = e.s;
    const depth0 = s.depth();
    defer s.popTo(depth0);
    s.pushTransform(Tf.scale(pt_per_px, pt_per_px));
    // (a transparent paper colour is still painted, as takumi-pdf fills the page with it)
    if (page.background) |bg| {
        e.path.reset();
        try e.path.addRect(e.a, .{ .x = 0, .y = 0, .w = page.width, .h = page.height });
        s.setFill(dev.fillOf(bg, 1, .nonzero));
        s.drawPath(&e.path);
    }
    const top = if (std.math.isFinite(win.top)) win.top else 0;
    try pdf_bands.paint(e, page.header);
    try paintFixed(e, page, top, true);
    {
        const d1 = s.depth();
        defer s.popTo(d1);
        if (page.clip) {
            e.path.reset();
            try e.path.addRect(e.a, page.content);
            s.pushClip(&e.path, .nonzero);
        }
        const dy = page.content.y - top;
        if (page.content.x != 0 or dy != 0) s.pushTransform(Tf.translate(page.content.x, dy));
        e.window = win;
        e.repeats = page.repeats;
        e.rep_done = try e.a.alloc(bool, page.repeats.len);
        @memset(e.rep_done, false);
        e.page_images = try e.a.alloc(bool, e.f.nodes.items.len);
        @memset(e.page_images, false);
        e.skip_fixed = page.fixed.len > 0;
        defer e.skip_fixed = false;
        try paintOverflow(e, page, win, .decorations);
        {
            // the frame's root is the page's stacking context; a paginated page paints the
            // fragments of the pages next to it that reach it, page by page (takumi's page scene of
            // the root fragments `pages_reaching` the page), before their positioned boxes
            const lq0 = e.lift_q.items.len;
            const lbase = e.clips.items.len;
            e.lift_on = true;
            defer e.lift_on = false;
            // (one context over the passes: their floats and content follow all their in-flow
            // decorations, as takumi's one stacking context of the page's root fragments)
            const fq0 = e.float_q.items.len;
            const cq0 = e.content_q.items.len;
            e.defer_on = true;
            defer e.defer_on = false;
            if ((e.windows.len > 1 or !e.win_open_top or !e.win_open_bottom) and win.paged()) {
                const p = e.win_page;
                var r: u32 = if (p > 0) p - 1 else 0;
                while (r <= p + 1 and r < e.windows.len) : (r += 1) {
                    e.pass = r;
                    try e.paintNode(e.f.root, 0, 0, 0);
                }
            } else try e.paintNode(e.f.root, 0, 0, 0);
            try paintUnder(e, page, win);
            try paintOverflow(e, page, win, .content);
            try e.flushContext(fq0, cq0, lbase);
            // [tagging] (a paragraph's atomic inline this page never painted)
            e.flushPendingRegions(none);
            e.defer_on = false;
            try e.flushLifts(lq0, lbase);
            e.pass = null;
        }
        try e.flushOutlines(0, 0);
        for (page.repeats, 0..) |r, k| {
            if (e.rep_done[k]) continue;
            const o = e.f.repeatOrigin(r);
            if (o.id == none or e.f.nodes.items[o.id].cs.position == .fixed) continue;
            e.in_repeat = true; // [tagging]
            defer e.in_repeat = false;
            try e.paintNode(o.id, o.ox, o.oy, 0);
            try e.flushOutlines(0, 0);
        }
    }
    try paintFixed(e, page, top, false);
    try pdf_bands.paint(e, page.footer);
}

/// The fragments of the page before that reach this page from the layout of another width
/// (`PageBox.over_frame`): the page's scene holds the root fragment of the page before as well
/// (takumi `pages_reaching`), so a table cell whose trailing decorations reach past that page
/// (paged.zig `cellOverflow`) shows them at the top of this one. Their content ends on the page
/// before: `.content` only opens the (empty) regions of the cells' inline content, after this
/// page's decorations as in takumi's one stacking context of the page's root fragments.
fn paintOverflow(e: *Emitter, page: PageBox, win: Window, mode: Emitter.Own) Error!void {
    const of = page.over_frame orelse return;
    var sub = Emitter.init(of, e.cx, e.s, e.fonts);
    sub.links = e.links;
    sub.tags = e.tags;
    sub.tagged = e.tagged;
    sub.page_index = e.page_index;
    sub.doc_lang = e.doc_lang;
    sub.window = win;
    sub.slice_win = page.over_win;
    sub.extends = page.over_extends;
    for (page.over_extends) |x| {
        if (x.node >= of.lid_node.items.len) continue;
        const id = of.lid_node.items[x.node];
        if (id >= of.nodes.items.len or id == of.root) continue;
        const n = &of.nodes.items[id];
        // (rows, row groups and tables paint into their cells: the cells carry them)
        switch (n.cs.display) {
            .table, .inline_table, .table_row, .table_row_group, .table_header_group, .table_footer_group => continue,
            else => {},
        }
        const o = of.repeatOrigin(.{ .node = x.node, .page = 0, .dy = 0 });
        const l = of.tree.layout(x.node);
        const bx = o.ox + l.x;
        const by = o.oy + l.y;
        if (mode == .decorations) {
            try sub.paintOwn(id, bx, by, .decorations);
            continue;
        }
        if (n.cs.display != .table_cell) continue;
        var c = n.first_child;
        while (c != none) : (c = of.nodes.items[c].next) {
            const cn = &of.nodes.items[c];
            if (cn.lid == none or cn.para == null or !(cn.kind == .text or cn.kind == .anon_text or cn.kind == .anon_box)) continue;
            const cl = of.tree.layout(cn.lid);
            try sub.paintOwn(c, bx + cl.x, by + cl.y, .content);
        }
    }
    if (mode == .decorations) try sub.flushOutlines(0, 0);
    if (sub.fail_msg) |m| e.fail(m, sub.fail_arg);
}

/// The fragments of the page after, laid out in another frame (`PageBox.under_frame`), that
/// reach this page: takumi's page scene holds the root fragment of the page after as well
/// (`pages_reaching`), so the half of a collapsed border above a table that starts that page
/// paints here (outside this page's clip). One pass over that page's fragments, as for the
/// neighbouring pages of a frame (`paintPage`); this page's window filters them.
fn paintUnder(e: *Emitter, page: PageBox, win: Window) Error!void {
    const uf = page.under_frame orelse return;
    if (!win.paged()) return;
    var sub = Emitter.init(uf, e.cx, e.s, e.fonts);
    sub.tags = e.tags; // [tagging] (decorations: artifacts; no content of this page)
    sub.tagged = false;
    sub.page_index = e.page_index;
    sub.doc_lang = e.doc_lang;
    sub.window = win;
    // (that page is the pass's own page, so its table parts paint; what the frame holds above it,
    // the content the runs before show, belongs to the window before and is left out)
    const above: Window = .{ .top = -std.math.inf(f32), .bottom = page.under_win.top, .lines_top = -std.math.inf(f32), .lines_bottom = page.under_win.top };
    const wins = [2]Window{ above, page.under_win };
    sub.windows = &wins;
    sub.win_page = 1;
    sub.win_open_top = true;
    sub.win_open_bottom = false;
    sub.walk_all = false;
    sub.no_content = true;
    sub.pass = 1;
    try sub.paintNode(uf.root, 0, 0, 0);
    try sub.flushOutlines(0, 0);
    if (sub.fail_msg) |m| e.fail(m, sub.fail_arg);
}

/// The page's repeating `position: fixed` boxes under (`below`) or over the content, each in its
/// own content window at its place in the page area (takumi `Repeatable::emit`).
fn paintFixed(e: *Emitter, page: PageBox, top: f32, below: bool) Error!void {
    if (page.fixed_frame) |ff| if (ff != e.f) {
        // this page's own layout of the fixed boxes (page counters; paged.zig), not paginated
        var sub = Emitter.init(ff, e.cx, e.s, e.fonts);
        sub.links = e.links; // [interactive] the fixed boxes' links annotate every page
        sub.tags = e.tags; // [tagging] (untagged walk: only the window's artifact)
        try paintFixed(&sub, page, 0, below);
        if (sub.fail_msg) |m| e.fail(m, sub.fail_arg);
        return;
    };
    const f = e.f;
    const s = e.s;
    for (page.fixed) |id| {
        const cs = f.nodes.items[id].cs;
        if (((cs.z_index orelse 0) < 0) != below) continue;
        const o = f.repeatOrigin(.{ .node = f.nodes.items[id].lid, .page = 0, .dy = top });
        // [tagging] a repeated box is an artifact, drawn untagged (takumi `Repeatable::emit`)
        etag.startWindow(e);
        defer etag.endWindow(e);
        const saved_tagged = e.tagged;
        e.tagged = false;
        defer e.tagged = saved_tagged;
        const d1 = s.depth();
        defer s.popTo(d1);
        e.path.reset();
        try e.path.addRect(e.a, page.content);
        s.pushClip(&e.path, .nonzero);
        if (page.content.x != 0 or page.content.y != 0) s.pushTransform(Tf.translate(page.content.x, page.content.y));
        e.window = .{};
        try e.paintNode(id, o.ox, o.oy - top, 0);
        try e.flushOutlines(0, 0);
    }
}

/// The `position: fixed` boxes takumi-pdf takes out of the flow and repeats on every page
/// (`take_repeating_fixed`): fixed boxes with no fixed or transformed ancestor (a transform makes
/// a containing block that keeps them in the flow).
pub fn repeatingFixed(a: Allocator, f: *const Frame) Error![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    for (f.nodes.items, 0..) |*n, i| {
        if (n.kind == .anon_text or n.cs.position != .fixed or n.cs.display == .none) continue;
        var ok = true;
        var p = n.parent;
        while (p != none) : (p = f.nodes.items[p].parent) {
            const pcs = f.nodes.items[p].cs;
            if (pcs.display == .none or pcs.position == .fixed or hasTransform(pcs) or pcs.filter.len > 0) {
                ok = false;
                break;
            }
        }
        if (ok) try out.append(a, @intCast(i));
    }
    return out.items;
}

pub const DocOptions = struct {
    producer: []const u8 = "bm-render",
    /// Flate-compress content streams (off: readable output for tests / debugging)
    compress: bool = true,
    /// the `uncoveredText` option: characters no font draws fail the render, or draw as
    /// `.notdef` placeholders, or nothing
    uncovered: text.Uncovered.Policy = .@"error",
    /// [interactive] the options behind the document-level pass (metadata, outline, attachments,
    /// lang); null: defaults (tests)
    opts: ?*const @import("options.zig").PdfOptions = null,
    /// [interactive] the tagging / PDF/A wave's hook into the document-level pass
    hook: ?interactive.DocHook = null,
};

/// What a drawn page leaves for its page object: its content stream (`w.Doc.encode`d), its
/// resources and whether its content nests `q` too deep.
const PageOut = struct { content: w.Encoded, res: w.Resources, q_over: bool };

/// Writes a document of the frame drawn on `pages` (each with its window) and returns the PDF.
/// Object order as krilla's: what the pages' content refers to as it is drawn, then the fonts
/// (`FontRegistry.flush`: after every page is drawn, before the page objects), then the pages.
pub fn writeDocument(a: Allocator, f: *Frame, pages: []const PageBox, windows: []const Window, o: DocOptions) Error![]const u8 {
    const dw = try DocWriter.init(a, f, o);
    defer dw.deinit();
    _ = try dw.beginChunk(f);
    try dw.drawPages(f, pages, windows, a, null);
    {
        // (the structure tree's working memory: what it keeps is copied to `a`)
        var scratch = bump.Bump.init(f.r.gpa);
        defer scratch.deinit();
        scratch.release_freed = true;
        _ = try dw.endChunk(scratch.allocator(), null);
    }
    return dw.finish();
}

/// A document written a group of pages at a time (`writeDocument`, or paged.zig drawing a long
/// document a part at a time): `init`, `drawPages` for each group in output order, `finish`.
/// What a group leaves is its pages' encoded content streams and resources, the links on them and
/// the destinations of the anchors and headings it holds: nothing refers to its frames afterwards.
pub const DocWriter = struct {
    a: Allocator,
    r: *render.Renderer,
    o: DocOptions,
    default_opts: @import("options.zig").PdfOptions = .{},
    popts: *const @import("options.zig").PdfOptions = undefined,
    cfg: conform.Config = undefined,
    tagged: bool = false,
    doc: w.Doc = undefined,
    cx: sf.Ctx = undefined,
    fonts: text.FontRegistry,
    // Memory: a page's drawing (the walk, its surfaces) works in `page_mem`, rewound after the
    // page; what the page leaves is its content stream, encoded into `a` at once, and its
    // resources (`PageOut`). The compressor's tables are rewound after every stream (`zmem`).
    page_mem: bump.Bump,
    zmem: bump.Bump,
    page_mem_live: bool = true,
    outs: std.ArrayList(PageOut) = .empty,
    /// per output page: its size (CSS px)
    sizes: std.ArrayList([2]f32) = .empty,
    links: interactive.Collector = undefined,
    td: @import("tagdoc.zig").TagDoc = undefined,
    /// the first output page of the part of the document being drawn (`beginChunk`)
    chunk_first: usize = 0,

    /// `f`: the document's frame (tests and viewport pages: the only one).
    pub fn init(a: Allocator, f: *Frame, o: DocOptions) Error!*DocWriter {
        const dw = try a.create(DocWriter);
        dw.* = .{ .a = a, .r = f.r, .o = o, .fonts = text.FontRegistry.init(a, o.uncovered), .page_mem = bump.Bump.init(f.r.gpa), .zmem = bump.Bump.init(f.r.gpa) };
        dw.popts = o.opts orelse &dw.default_opts;
        // [tagging] validators and PDF version (krilla `ConfigurationBuilder`); tests (`o.opts`
        // null) write untagged output
        dw.cfg = conform.Config.of(dw.popts) orelse {
            dw.deinit();
            f.r.setErr("The requested archival standard is not available", "");
            return error.Invalid;
        };
        dw.tagged = o.opts != null and (dw.popts.writesStructure() or dw.cfg.requiresTagging());
        dw.doc = w.Doc.init(a, .{ .compress = o.compress, .version = dw.cfg.version });
        dw.cx = .{ .a = a, .doc = &dw.doc, .no_device_cs = dw.cfg.archival(), .version = dw.cfg.version };
        dw.fonts.uncovered.forbidden_by = dw.cfg.forbidsPlaceholder();
        dw.page_mem.release_freed = true;
        dw.doc.scratch = &dw.zmem;
        dw.links = interactive.Collector.init(a, f); // [interactive]
        dw.td = @import("tagdoc.zig").TagDoc.init(a, &dw.cx, dw.cfg, dw.popts, dw.tagged, f, &dw.links);
        return dw;
    }

    /// Frees the working memory (the result of `finish` lives in `a`).
    pub fn deinit(dw: *DocWriter) void {
        if (dw.page_mem_live) dw.page_mem.deinit();
        dw.page_mem_live = false;
        dw.zmem.deinit();
    }

    /// Starts a part of the document laid out on its own, in frame `f` (and the frames its pages
    /// name): `drawPages` for its pages, then `endChunk`.
    pub fn beginChunk(dw: *DocWriter, f: *Frame) Error!bool {
        dw.links.f = f;
        dw.links.chunk = dw.td.chunk;
        dw.chunk_first = dw.outs.items.len;
        return dw.td.beginChunk(f);
    }

    /// The pages of the part are drawn: its structure joins the tree and its links are registered;
    /// nothing refers to its frames afterwards (`scratch`: temporary memory). `skip`: what its
    /// frame lays out of the parts around it (chunks.zig). False: the parts cannot be drawn apart
    /// (the caller draws the document whole).
    pub fn endChunk(dw: *DocWriter, scratch: Allocator, skip: ?@import("tags.zig").Skip) Error!bool {
        const ok = try dw.td.endChunk(dw.chunk_first, scratch, skip);
        dw.links.endChunk();
        return ok;
    }

    /// Draws the next output pages: `pages` (each with its window) show `f`, or `PageBox.frame`.
    /// `ra`: memory for what only these pages use (the caller may release it after this call).
    /// `bounds`: the span of the frame whose anchors and headings these pages collect (null: from
    /// the first page's top, or above it when it is the first, to the last page's bottom, or
    /// below it when it is the last).
    pub fn drawPages(dw: *DocWriter, f: *Frame, pages: []const PageBox, windows: []const Window, ra: Allocator, bounds: ?[2]f32) Error!void {
        const a = dw.a;
        const cx = &dw.cx;
        const links = &dw.links;
        const td = &dw.td;
        const popts = dw.popts;
        const tagged = dw.tagged;
        const first: u32 = @intCast(dw.outs.items.len);
        try dw.outs.ensureUnusedCapacity(a, pages.len);
        try dw.sizes.ensureUnusedCapacity(a, pages.len);
        // (a paginated document: computed once, shared by the pages, as are the table parts and the tree
        // order; per page they would cost the whole document every page)
        // (pages laid out at different widths: each run of pages showing one frame is drawn from it
        // with the windows of that run, paged.zig)
        var ext: ?Extents = null;
        var neg_any = true;
        var tparts: []etable.Part = &.{};
        var run0: usize = 0;
        var run1: usize = 0;
        var run_wins: []const Window = windows;
        var run_off: usize = 0;
        for (pages, windows, 0..) |page, win, i| {
            const pf = page.frame orelse f;
            if (i == run1) {
                run0 = i;
                run1 = i + 1;
                while (run1 < pages.len and (pages[run1].frame orelse f) == pf) run1 += 1;
                ext = if (run1 - run0 > 1) try Extents.compute(ra, pf) else null;
                // (one look over the frame: a page walk of the whole tree for negative z-index boxes
                // would cost every page the whole document)
                neg_any = for (pf.nodes.items) |*nn| {
                    if (nn.kind != .anon_text) if (nn.cs.z_index) |z| if (z < 0) break true;
                } else false;
                tparts = &.{};
                // (the frame's own pages around the run take part as neighbouring passes)
                const pw = pages[run0].prev_win;
                const nw = pages[run1 - 1].next_win;
                if (pw != null or nw != null) {
                    var list: std.ArrayList(Window) = .empty;
                    if (pw) |x| try list.append(ra, x);
                    try list.appendSlice(ra, windows[run0..run1]);
                    if (nw) |x| try list.append(ra, x);
                    run_wins = list.items;
                    run_off = @intFromBool(pw != null);
                } else {
                    run_wins = windows[run0..run1];
                    run_off = 0;
                }
                // [interactive] anchors and headings of this frame: those in its run of pages (the
                // first and last pages drawn also own what is above / below them, unless the frame
                // has pages of its own there: a part of the document, paged.zig)
                const lo = if (bounds) |b| b[0] else if (run0 == 0) -std.math.inf(f32) else win.top;
                const hi = if (bounds) |b| b[1] else if (run1 == pages.len) std.math.inf(f32) else windows[run1 - 1].bottom;
                links.beginRun(pf, lo, hi);
            }
            const out_i: u32 = first + @as(u32, @intCast(i));
            dw.page_mem.reset();
            cx.page = dw.page_mem.allocator();
            defer cx.page = null;
            dw.fonts.forgetPage();
            links.page_a = cx.page;
            defer {
                // [interactive] the page's links leave its memory before it is rewound
                links.endPage();
                links.page_a = null;
            }
            var s = sf.Surface.initPage(cx, page.height * pt_per_px);
            s.tagging = tagged;
            var e = Emitter.init(pf, cx, &s, &dw.fonts);
            e.neg_any = neg_any;
            if (ext) |*x| {
                e.ext = x;
                e.pre = x.pre;
            }
            e.tparts = tparts;
            defer tparts = e.tparts;
            try links.beginPage(out_i, page, win); // [interactive]
            e.links = links;
            e.windows = run_wins;
            e.extends = page.extends;
            e.win_page = @intCast(i - run0 + run_off);
            e.walk_all = i == run0;
            if (tagged) {
                e.tags = &td.collector;
                e.tagged = true;
                e.page_index = out_i;
                e.doc_lang = popts.lang;
            }
            @import("../memtrace.zig").mark("emit: page start");
            try paintPage(&e, page, win);
            @import("../memtrace.zig").mark("emit: page painted");
            if (e.fail_msg) |msg| {
                dw.r.setErr(msg, e.fail_arg);
                // a message longer than the renderer's buffer (an image's data: URI) is kept whole in
                // the arena, which lives until the next call
                if (msg.len + e.fail_arg.len > dw.r.err.len) {
                    if (std.mem.concat(dw.r.arena.allocator(), u8, &.{ msg, e.fail_arg })) |m| dw.r.err = m else |_| {}
                }
                return error.Invalid;
            }
            const st = s.finish();
            dw.outs.appendAssumeCapacity(.{ .content = dw.doc.encode(st.content, .content), .res = try st.res.dupe(a), .q_over = st.limits.q_over });
            dw.sizes.appendAssumeCapacity(.{ page.width, page.height });
            try td.addPage(s.mcid);
            @import("../memtrace.zig").mark("emit: page done");
        }
        @import("../memtrace.zig").mark("emit: pages drawn");
        // [interactive] the anchors and headings become destinations: nothing needs the frames after this
        links.resolve(f, pages, windows, first, popts.tagged == .ua2);
    }

    /// Collects the anchors and headings of frame `f` in the span `bounds` (as the first page of a
    /// run does) without drawing a page: a part of the document whose pages `pageRanges` drops
    /// (paged.zig). `page`: one of its pages (its size and content box).
    pub fn collect(dw: *DocWriter, f: *Frame, page: PageBox, bounds: [2]f32) Error!void {
        const cx = &dw.cx;
        const links = &dw.links;
        dw.page_mem.reset();
        cx.page = dw.page_mem.allocator();
        defer cx.page = null;
        dw.fonts.forgetPage();
        links.page_a = cx.page;
        links.collect_only = true;
        defer {
            links.collect_only = false;
            links.groups = .empty;
            links.group = 0;
            links.page_a = null;
        }
        links.beginRun(f, bounds[0], bounds[1]);
        links.run_first = true;
        links.run_begun = false;
        var s = sf.Surface.initPage(cx, page.height * pt_per_px);
        s.tagging = false;
        var e = Emitter.init(f, cx, &s, &dw.fonts);
        e.links = links;
        // (a window far below the content: the walk visits every box, nothing is painted)
        const far: Window = .{ .top = 1e30, .bottom = 1e30, .lines_top = 1e30, .lines_bottom = 1e30 };
        const windows = [_]Window{far};
        e.windows = &windows;
        e.win_page = 0;
        e.walk_all = true;
        var bare = page;
        bare.background = null;
        bare.header = null;
        bare.footer = null;
        bare.repeats = &.{};
        bare.fixed = &.{};
        bare.prev_win = null;
        bare.next_win = null;
        try paintPage(&e, bare, far);
        if (e.fail_msg) |msg| {
            dw.r.setErr(msg, e.fail_arg);
            return error.Invalid;
        }
        // (their pages are dropped: no destination; nothing refers to `f` afterwards)
        links.resolve(f, &.{}, &.{}, @intCast(dw.outs.items.len), dw.popts.tagged == .ua2);
    }

    /// Writes the document-level objects and the pages, and returns the file (in `a`).
    pub fn finish(dw: *DocWriter) Error![]const u8 {
        const a = dw.a;
        const cx = &dw.cx;
        const td = &dw.td;
        const doc = &dw.doc;
        const popts = dw.popts;
        const page_count = dw.outs.items.len;
        // (the pages are drawn: their working memory goes before the document-level objects are made)
        if (dw.page_mem_live) dw.page_mem.deinit();
        dw.page_mem_live = false;
        // takumi: `UncoveredCharacters` is reported once the document is drawn
        if (dw.fonts.uncoveredError() catch return error.OutOfMemory) |msg| {
            dw.r.setErr("", msg); // (as detail: a prefix is cut at 128 bytes)
            return error.Invalid;
        }
        const issues = dw.fonts.flush(cx) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                dw.r.setErr("PDF font error: ", @errorName(err));
                return error.Invalid;
            },
        };
        td.fontIssues(issues);
        @import("../memtrace.zig").mark("emit: fonts flushed");
        // [interactive] outline, annotations, destinations, attachments; catalog / Info / XMP parts
        const page_refs = try a.alloc(w.Ref, page_count);
        for (page_refs) |*pr| pr.* = doc.addPage();
        td.page_refs = page_refs;
        const fin = try interactive.finishDocument(&dw.links, doc, a, page_count, page_refs, popts, dw.o.producer, dw.o.hook orelse (if (dw.o.opts != null) td.hook() else null));
        // pages are serialised last, in page order (krilla `serialize_pages`)
        for (dw.sizes.items, dw.outs.items, page_refs, fin.annots, 0..) |size, *st, pref, annots, i| {
            const cref = doc.alloc();
            doc.contentStreamEncoded(cref, st.content);
            if (st.q_over) cx.q_over = true;
            const rref = st.res.write(doc);
            const pe = td.pageEntries(i);
            _ = doc.beginPage(pref, .{ .resources = rref, .media_box = .{ 0, 0, size[0] * pt_per_px, size[1] * pt_per_px }, .contents = cref, .annots = annots, .struct_parents = pe.struct_parents, .tabs = pe.tabs });
            doc.endDict();
        }
        @import("../memtrace.zig").mark("emit: objects written");
        var out: std.ArrayList(u8) = .empty;
        const finished = metadata.finish(doc, &out, &fin.parts);
        @import("../memtrace.zig").mark("emit: file assembled");
        // krilla `check_validator_limits` (after the file is assembled) and the q/Q nesting of the
        // content streams
        if (doc.tooManyObjects()) td.report.add(.too_many_indirect_objects, 0);
        if (doc.limits.str_len > w.Limits.max_str_len) td.report.add(.too_long_string, 0);
        if (doc.limits.name_len > w.Limits.max_name_len) td.report.add(.too_long_name, 0);
        if (cx.q_over) td.report.add(.too_high_q_nesting, 0);
        // [conformance] what the validators prohibit fails the render (krilla `KrillaError::Validation`)
        if (td.report.failed) return error.OutOfMemory;
        if (try td.report.message(a)) |msg| {
            dw.r.setErr("", msg);
            return error.Invalid;
        }
        finished catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                dw.r.setErr("PDF writer error: ", @errorName(err));
                return error.Invalid;
            },
        };
        return out.items;
    }
};
