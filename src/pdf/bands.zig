//! Header and footer bands (takumi-pdf `bands.rs`, the band parts of `page.rs`, `options.rs`
//! `PageBand`): trees laid out on their own at the full page width with an unbounded height
//! (takumi `band_viewport`) and drawn once per page inside the top / bottom margin.
//!
//! * A band's templates (`Slot.nodes`, takumi `PageBand::nodes`): the `pages` rules' trees
//!   (`first`, `last`, `odd`, `even`) then the document's own `header` / `footer`. Each is measured
//!   with the counters of the last page of `count` pages; the tallest gives the band its height
//!   (the first of equal ones wins), which is what an `auto` margin grows to (`band height + 15pt`,
//!   at least 10mm) and the rect the band draws in: the full page width, `15pt` below the top edge
//!   (header) or above the bottom edge (footer), clipped to it (takumi `RepeatBounds::rect`).
//! * A band whose trees hold a page counter (`pageNumber` / `totalPages`) or whose pages differ
//!   (any `pages` rule) is dynamic: every page lays out the tree its rule picks (`first` / `last`
//!   win over `odd` / `even`, a rule left out falls through, `false` draws nothing) with that page's
//!   numbers, in the measured rect; otherwise the measured tree draws on every page.
//! * The header draws before the content, the footer after it (and after the repeated fixed boxes).
//!   Bands share the document's font registry and object cache: they draw through a second
//!   `Emitter` onto the page's surface.
const std = @import("std");
const rt = @import("../render.zig");
const json = @import("../json.zig");
const opt = @import("options.zig");
const emit = @import("emit.zig");
const geom = @import("emit_geom.zig");
const counters = @import("counters.zig");
const etag = @import("emit_tag.zig"); // [tagging]

const Allocator = std.mem.Allocator;
const Frame = rt.Frame;
const Error = rt.Error;

/// One band drawn on one page: `frame` laid out at the page width (null: `lazy` lays it out when
/// the page is drawn), drawn translated to (`x`, `y`) and clipped to the `w` x `h` rect there
/// (CSS px, page coordinates).
pub const Draw = struct { frame: ?*Frame, lazy: ?Lazy = null, x: f32, y: f32, w: f32, h: f32 };

/// A band laid out for one page only (its page counters, or the page's own width): laid out when
/// that page is drawn, in the page's working memory (emit.zig `writeDocument`), so a long
/// document does not keep a band frame per page.
pub const Lazy = struct {
    doc: *const Doc,
    node: opt.Band,
    /// 1-based page number and page count of the counters
    page: usize,
    pages: usize,

    /// The band laid out from `a`.
    pub fn layOut(l: Lazy, a: Allocator) Error!*Frame {
        var d = l.doc.*;
        d.a = a;
        return layOutBand(&d, l.node, l.page, l.pages, null);
    }
};

/// Paints a band on the page `e` draws (takumi `RepeatablePage::emit` / `ContentWindow::emit`).
pub fn paint(e: *emit.Emitter, band: ?Draw) Error!void {
    const b = band orelse return;
    if (!(b.w > 0 and b.h > 0)) return;
    const s = e.s;
    // [tagging] a band is an artifact, drawn untagged (takumi `RepeatablePage::emit`)
    etag.startWindow(e);
    defer etag.endWindow(e);
    const d0 = s.depth();
    defer s.popTo(d0);
    const frame = b.frame orelse try b.lazy.?.layOut(e.a);
    var be = emit.Emitter.init(frame, e.cx, s, e.fonts);
    be.path.reset();
    try be.path.addRect(be.a, .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h });
    s.pushClip(&be.path, .nonzero);
    if (b.x != 0 or b.y != 0) s.pushTransform(geom.Tf.translate(b.x, b.y));
    try be.paintNode(frame.root, 0, 0, 0);
    try be.flushOutlines(0, 0);
    if (be.fail_msg) |m| e.fail(m, be.fail_arg);
}

/// Builds and lays out a frame of the document `o` (paged geometry `o.geometry.page`): `area` set:
/// the content laid out for that page area (`Frame.setPaged`; the caller paginates); null: a band
/// (the full page width, an unbounded height). `subst` fills the page counter hooks.
pub fn buildFrame(r: *rt.Renderer, a: Allocator, o: opt.PdfOptions, css: ?json.Value, kind: rt.SourceKind, source: []const u8, pre: ?json.Value, area: ?[2]f32, subst: ?*counters.Subst) Error!*Frame {
    return buildFrameCut(r, a, o, css, kind, source, pre, area, subst, null);
}

/// A paragraph continued on a page of another width (paged.zig): render node `node`'s paragraph
/// ends a line before its shaped glyph `glyph`.
pub const Cut = @import("../layout/fragment.zig").ParagraphCut;

/// `buildFrame`, the paragraph `cut` names broken there.
pub fn buildFrameCut(r: *rt.Renderer, a: Allocator, o: opt.PdfOptions, css: ?json.Value, kind: rt.SourceKind, source: []const u8, pre: ?json.Value, area: ?[2]f32, subst: ?*counters.Subst, cut: ?Cut) Error!*Frame {
    return buildFrameCuts(r, a, o, css, kind, source, pre, area, subst, if (cut) |c| &.{c} else &.{}, &.{}, &.{}, &.{}, &.{});
}

pub fn buildFrameCuts(r: *rt.Renderer, a: Allocator, o: opt.PdfOptions, css: ?json.Value, kind: rt.SourceKind, source: []const u8, pre: ?json.Value, area: ?[2]f32, subst: ?*counters.Subst, cuts: []const Cut, rows: []const @import("../layout/fragment.zig").RowMinimum, float_shifts: []const f32, float_extents: []const f32, frozen: []const @import("../layout/fragment.zig").FrozenWidth) Error!*Frame {
    var ro: rt.Options = .{ .lang = o.lang, .font_families = o.font_families };
    switch (o.geometry) {
        .viewport => |v| {
            ro.width = v.width;
            ro.height = v.height;
        },
        .page => |p| ro.width = @intFromFloat(@max(1, @min(p.width, 16384))),
    }
    ro.css = css;
    const f = try a.create(Frame);
    f.* = .{ .r = r, .a = a, .opts = ro, .tree = rt.LTree.init(a), .ctx = undefined, .pre = pre };
    f.tree.paged.pdf = true;
    f.tree.paged.skip_dom_styles = o.pooled_styles;
    // a band's viewport units take the whole page (takumi-pdf `band_viewport`: `with_unit_reference(page.size())`)
    if (area == null) switch (o.geometry) {
        .page => |p| f.tree.paged.units = .{ p.width, p.height },
        .viewport => {},
    };
    if (area) |ar| f.setPaged(ar[0], ar[1]);
    f.tree.paged.cuts = try a.dupe(Cut, cuts);
    f.tree.paged.row_minimums = rows;
    f.tree.paged.frozen_widths = frozen;
    f.tree.paged.float_shifts = try a.dupe(f32, float_shifts);
    f.tree.paged.float_extents = try a.dupe(f32, float_extents);
    if (subst) |s| s.install(f);
    try f.prepare(kind, source);
    try @import("text.zig").requireFont(f, o.uncovered_text == .blank);
    return f;
}

/// The document of `o` for the content laid out a part at a time (paged.zig `writeChunked`): its
/// element model and styles only (`Frame.prepareDocument`), for page areas of size `area`.
pub fn buildDocument(r: *rt.Renderer, a: Allocator, o: opt.PdfOptions, css: ?json.Value, kind: rt.SourceKind, source: []const u8, area: [2]f32, subst: *counters.Subst) Error!*Frame {
    var ro: rt.Options = .{ .lang = o.lang, .font_families = o.font_families };
    ro.width = @intFromFloat(@max(1, @min(o.geometry.page.width, 16384)));
    ro.css = css;
    const f = try a.create(Frame);
    f.* = .{ .r = r, .a = a, .opts = ro, .tree = rt.LTree.init(a), .ctx = undefined };
    f.tree.paged.pdf = true;
    f.tree.paged.skip_dom_styles = o.pooled_styles;
    f.setPaged(area[0], area[1]);
    subst.install(f);
    try f.prepareDocument(kind, source);
    return f;
}

/// The laid-out height of a band frame: its root's margin box (takumi lays the band out inside a
/// page-wide flow root and takes that root's height).
pub fn frameHeight(f: *const Frame) f32 {
    return @max(0, f.rootBlockEnd());
}

/// The header (or footer) of a document: its templates and their measurement.
pub const Slot = struct {
    header: bool,
    /// every tree some page may draw: the rules' (first, last, odd, even) then the document's
    nodes: []const opt.Band,
    /// per rule (first, last, odd, even): unset (null), off (`none_node`), or an index into `nodes`
    rules: [4]?usize,
    /// the document's own tree (index into `nodes`), drawn where no rule replaces it
    default: ?usize,
    /// one page can draw something another does not (a rule is set)
    varies: bool,

    // ---- the measurement (`measure`)
    /// the tallest tree, laid out with the last page's counters
    frame: *Frame = undefined,
    height: f32 = 0,
    /// the index of that tree in `nodes`
    tallest: ?usize = null,
    /// per node: it holds a page number / page count hook
    hooked: []bool = &.{},
    /// lays out again per page
    dynamic: bool = false,
    /// per node: a frame without page hooks, laid out once and drawn on every page that picks it
    cache: []?*Frame = &.{},

    pub const none_node: usize = std.math.maxInt(usize);

    /// The slot of the header (`header`) or footer of `o`, null when no page draws one.
    pub fn init(a: Allocator, o: opt.PdfOptions, header: bool) Error!?Slot {
        var nodes: std.ArrayList(opt.Band) = .empty;
        var rules: [4]?usize = .{ null, null, null, null };
        const pr = o.pages;
        const fields = [4]opt.PageOverride{ pr.first, pr.last, pr.odd, pr.even };
        for (fields, 0..) |ov, k| {
            const b = (if (header) ov.header else ov.footer) orelse continue;
            switch (b) {
                .off => rules[k] = none_node,
                else => {
                    rules[k] = nodes.items.len;
                    try nodes.append(a, b);
                },
            }
        }
        var default: ?usize = null;
        if (if (header) o.header else o.footer) |b| if (b != .off) {
            default = nodes.items.len;
            try nodes.append(a, b);
        };
        if (nodes.items.len == 0) return null;
        const hooked = try a.alloc(bool, nodes.items.len);
        @memset(hooked, false);
        const cache = try a.alloc(?*Frame, nodes.items.len);
        @memset(cache, null);
        return .{
            .header = header,
            .nodes = nodes.items,
            .rules = rules,
            .default = default,
            .varies = rules[0] != null or rules[1] != null or rules[2] != null or rules[3] != null,
            .hooked = hooked,
            .cache = cache,
        };
    }

    /// The tree page `page` of `pages` (1-based) draws, null for none (takumi `PageBand::for_page`).
    pub fn forPage(s: *const Slot, page: usize, pages: usize) ?usize {
        const parity = if (page % 2 == 1) s.rules[2] else s.rules[3];
        const rule = (if (page == 1) s.rules[0] else null) orelse (if (page == pages) s.rules[1] else null) orelse parity;
        const chosen = rule orelse return s.default;
        return if (chosen == none_node) null else chosen;
    }
};

/// Lays out band tree `node` with the counters of page `page` of `pages`.
pub fn layOutBand(d: *const Doc, node: opt.Band, page: usize, pages: usize, hooked: ?*bool) Error!*Frame {
    var subst: counters.Subst = .{ .a = d.a, .mode = .{ .band = .{ .page = page, .pages = pages } } };
    const f = switch (node) {
        .html => |h| try buildFrame(d.r, d.a, d.o, d.css, .html, h, null, null, &subst),
        .node => |v| try buildFrame(d.r, d.a, d.o, d.css, .json, "", v, null, &subst),
        .off => unreachable,
    };
    if (hooked) |h| h.* = subst.hasPageHooks();
    return f;
}

/// What laying out a band needs: the document's renderer, options and stylesheet.
pub const Doc = struct {
    r: *rt.Renderer,
    a: Allocator,
    o: opt.PdfOptions,
    css: ?json.Value,
};

/// takumi `Repeatable::band`: measures every tree of the slot with the counters of the last of
/// `count` pages and keeps the tallest.
pub fn measure(d: *const Doc, s: *Slot, count: usize) Error!void {
    var tallest: ?*Frame = null;
    var height: f32 = 0;
    var any_hooked = false;
    s.tallest = null;
    for (s.nodes, 0..) |node, k| {
        const f = try layOutBand(d, node, count, count, &s.hooked[k]);
        any_hooked = any_hooked or s.hooked[k];
        const h = frameHeight(f);
        if (tallest == null or h > height) {
            tallest = f;
            height = h;
            s.tallest = k;
        }
    }
    s.frame = tallest.?;
    s.height = height;
    s.dynamic = s.varies or any_hooked;
}

/// The band page `page` (0-based) of `pages` draws (takumi `Repeatable::for_page`), placed for a
/// `page_w` x `page_h` page; null when its rule draws nothing. `d` must outlive the drawing (a
/// band of this page only is laid out then: `Lazy`).
pub fn forPage(d: *const Doc, s: *Slot, page: usize, pages: usize, page_w: f32, page_h: f32) Error!?Draw {
    const y = if (s.header) opt.band_edge_padding else page_h - opt.band_edge_padding - s.height;
    if (d.o.geometry == .page and page_w != d.o.geometry.page.width) {
        // a page of another width lays its band out at its own width (takumi lays the band out
        // per page box)
        const dw = try d.a.create(Doc);
        dw.* = d.*;
        dw.o.geometry.page.width = page_w;
        const k = (if (s.dynamic) s.forPage(page + 1, pages) else s.tallest) orelse return null;
        return .{ .frame = null, .lazy = .{ .doc = dw, .node = s.nodes[k], .page = page + 1, .pages = pages }, .x = 0, .y = y, .w = page_w, .h = s.height };
    }
    const frame = if (!s.dynamic) s.frame else blk: {
        const k = s.forPage(page + 1, pages) orelse return null;
        if (s.hooked[k]) return .{ .frame = null, .lazy = .{ .doc = d, .node = s.nodes[k], .page = page + 1, .pages = pages }, .x = 0, .y = y, .w = page_w, .h = s.height };
        if (s.cache[k] == null) s.cache[k] = try layOutBand(d, s.nodes[k], page + 1, pages, null);
        break :blk s.cache[k].?;
    };
    return .{ .frame = frame, .x = 0, .y = y, .w = page_w, .h = s.height };
}

test "a band's tree per page: first and last win over odd and even, false draws nothing" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const o: opt.PdfOptions = .{
        .header = .{ .html = "D" },
        .pages = .{ .first = .{ .header = .{ .html = "F" } }, .last = .{ .header = .off, .footer = .{ .html = "L" } }, .even = .{ .header = .{ .html = "E" } } },
    };
    const h = (try Slot.init(aa, o, true)).?;
    const name = struct {
        fn f(s: *const Slot, page: usize, pages: usize) []const u8 {
            const k = s.forPage(page, pages) orelse return "-";
            return s.nodes[k].html;
        }
    }.f;
    try std.testing.expectEqualStrings("F", name(&h, 1, 4));
    try std.testing.expectEqualStrings("E", name(&h, 2, 4));
    try std.testing.expectEqualStrings("D", name(&h, 3, 4));
    try std.testing.expectEqualStrings("-", name(&h, 4, 4));
    try std.testing.expectEqualStrings("F", name(&h, 1, 1));
    try std.testing.expect(h.varies);
    const f = (try Slot.init(aa, o, false)).?;
    try std.testing.expectEqualStrings("L", name(&f, 3, 3));
    try std.testing.expectEqualStrings("-", name(&f, 2, 3));
    try std.testing.expect((try Slot.init(aa, .{}, true)) == null);
}
