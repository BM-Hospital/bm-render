//! Links, anchors, headings and the outline (takumi-pdf `interactive.rs`, the parts of `lib.rs` /
//! `page.rs` that place destinations, and krilla's `annotation.rs`, `action.rs`, `destination.rs`,
//! `outline.rs`), plus the document-level pass that writes them with the metadata and attachments.
//!
//! Collection runs inside the emitter's walk (`Collector`, hooked into `Emitter.paintBox` and
//! `emit_text.paintText` through `Emitter.links`), so every box is seen where it is painted, under
//! its transform, on each page it is painted on:
//!
//! * a box whose element has an allowed `href` (a non-empty `#fragment`, or an `http`, `https`,
//!   `mailto` or `tel` URI) is one link over its border box (the axis-aligned bounds of the box under
//!   its transform); otherwise, in a paragraph, each painted run (one line, one face) inside an
//!   element with an `href` (the innermost one counts) is a link over the run's advance and the
//!   face's ascent + descent;
//! * a link is clipped to the page's span of the content (paged: the window; a viewport page: the
//!   page) and becomes one Link annotation per page it reaches: `/Rect` in PDF user space,
//!   `/Border[0 0 0]`, `/F 4` (print), and a URI action or, for `#id`, an XYZ destination (the
//!   fragment percent-decoded; a fragment naming no element, or one on a page `pageRanges` drops,
//!   writes nothing);
//! * repeated `position: fixed` boxes annotate every page, against the page area, after the page's
//!   own links (takumi `RepeatablePage::links`); header / footer bands never annotate (takumi:
//!   "Bands never annotate links"), which is why a band's emitter has no collector;
//! * anchors (`id`) and headings (`h1`..`h6` with non-empty text) are taken from the first page's
//!   walk, with the top of their box in the frame's coordinates; destinations land on the page
//!   holding that top (`Pages.pageAt`), at `(margin-left, margin-top + top - page top)`
//!   (viewport: `(0, top)`), XYZ with zoom 0, deduplicated, in registration order (outline first,
//!   then the annotations page by page);
//! * the outline (`outline: true`, or tagged `ua1` / `ua2`): headings sorted by top, nested by
//!   level, closed (`/Count -n`), a heading whose page is dropped yielding its place to its
//!   children.
//!
//! Hooks for the tagging wave: `AnnotRecord` (each annotation's ref, page, render node and element)
//! and `DocHook.annot` (a /StructParent and /Contents per annotation), `DocHook.run` (catalog,
//! Info and XMP parts before the file is finished), `Collector.anchor` / `.headings`.
const std = @import("std");
const render = @import("../render.zig");
const raster = @import("../raster/raster.zig");
const font = @import("../font/font.zig");
const w = @import("writer.zig");
const opt = @import("options.zig");
const meta = @import("metadata.zig");
const attach = @import("attach.zig");
const emit = @import("emit.zig");
const counters = @import("counters.zig");
const tags = @import("tags.zig");
const markers = @import("markers.zig");

const Allocator = std.mem.Allocator;
const Frame = render.Frame;
const Node = render.Node;
const none = render.none;
const Affine = raster.Affine;
const Error = render.Error;
const pt_per_px = emit.pt_per_px;

/// A link on a page: its rectangle in PDF user space (pt, y up) and what it points at.
pub const Link = struct {
    rect: [4]f32,
    uri: []const u8,
    /// the render node painting it (of `frame`) and the element carrying the `href`
    node: u32,
    el: u32,
    frame: *const Frame,
    /// a repeated fragment (a table header / footer group on a later page) paints it (takumi
    /// `LinkTarget.repeated`): annotated on every page that repeats it, outside the structure tree
    repeated: bool = false,
};

/// `top`: in the coordinates of `frame` (null: the document's), the `run`-th frame of the document
/// (pages laid out at different widths: paged.zig). `Collector.resolve` turns it into `dest` (null:
/// its page is dropped) once the pages showing that frame are drawn, so nothing needs the frame
/// after that (`frame` is cleared then). `chunk`: the part of the document laid out on its own
/// whose render nodes `node` numbers (paged.zig).
pub const Anchor = struct { top: f32, node: u32, el: u32, frame: ?*const Frame = null, run: u32 = 0, chunk: u32 = 0, dest: ?Dest = null, resolved: bool = false };
pub const Heading = struct { level: u8, text: []const u8, top: f32, el: u32, node: u32 = none, frame: ?*const Frame = null, run: u32 = 0, chunk: u32 = 0, dest: ?Dest = null, resolved: bool = false };

/// A written link: its destination (null: a URI action).
pub const LinkTarget = struct { dest: ?Dest };

pub const PageLinks = struct {
    content: std.ArrayList(Link) = .empty,
    /// repeated `position: fixed` boxes (annotated after the page's own links)
    fixed: std.ArrayList(Link) = .empty,
};

const TextKey = struct { f: usize, id: u32, x: u32, y: u32 };

/// The href map of an element model (`Frame.dom`, shared by the frames laying out parts of one
/// document), keyed by its element array.
const HrefMap = struct { dom: usize, map: std.AutoHashMapUnmanaged(usize, u32) = .empty };

/// A page's links in tree order: a link, or the place of a box (content) the emitter queued for
/// its context's content phase, whose links land there when it is painted (`Collector.reserve`).
const Entry = union(enum) { link: Link, group: u32 };

/// Collects links, anchors and headings during the paint walk (see the file comment).
pub const Collector = struct {
    a: Allocator,
    /// the document's frame (anchors and headings come from it)
    f: *Frame,
    /// per output page drawn so far
    pages: std.ArrayList(PageLinks) = .empty,
    cur: usize = 0,
    page: emit.PageBox = undefined,
    win: emit.Window = .{},
    anchors: std.StringHashMapUnmanaged(Anchor) = .empty,
    headings: std.ArrayList(Heading) = .empty,
    heading_els: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// per frame: computed style -> element, for the elements with an `href`
    href_maps: std.ArrayList(HrefMap) = .empty,
    /// paragraphs already collected on this page, by frame, node and place (a repeated table
    /// header / footer group paints its paragraphs again, somewhere else)
    text_seen: std.AutoHashMapUnmanaged(TextKey, void) = .empty,
    /// this page's links before they are flattened into `pages[cur].content`: takumi collects
    /// links in its scene's bucket order (`SceneView::for_each_paint`), where the content of an
    /// in-flow box and an atomic box sit at their place in the tree, while the emitter paints
    /// them later, in the content phase of their context; `groups[0]` is the page, `group` the
    /// list the links go to
    groups: std.ArrayList(std.ArrayList(Entry)) = .empty,
    group: u32 = 0,
    /// the memory of the page being drawn, where `groups` live until `endPage` (null: `a`); the
    /// emitter ends the page before that memory is rewound
    page_a: ?Allocator = null,
    failed: bool = false,
    /// the run of pages showing one frame being drawn (`beginRun`): its frame, its index, the span
    /// of the frame its pages show, and whether this is the run's first page
    run_frame: ?*const Frame = null,
    run: u32 = 0,
    runs: u32 = 0,
    run_lo: f32 = -std.math.inf(f32),
    run_hi: f32 = std.math.inf(f32),
    run_first: bool = false,
    run_begun: bool = false,
    /// the part of the document whose frames are being drawn (see `Anchor.chunk`)
    chunk: u32 = 0,
    /// a walk that only collects anchors and headings (`emit.DocWriter.collect`): no link
    collect_only: bool = false,

    pub fn init(a: Allocator, f: *Frame) Collector {
        return .{ .a = a, .f = f };
    }

    /// Starts output page `i` (painted with `page` / `win`), the pages before it started already.
    pub fn beginPage(c: *Collector, i: usize, page: emit.PageBox, win: emit.Window) Error!void {
        c.endPage();
        while (c.pages.items.len <= i) try c.pages.append(c.a, .{});
        c.run_first = c.run_begun;
        c.run_begun = false;
        c.cur = i;
        c.page = page;
        c.win = win;
        c.text_seen.clearRetainingCapacity();
    }

    /// Starts a run of output pages that show `f` (one frame per page width: paged.zig), its
    /// pages showing the frame's block range [`lo`, `hi`): its first page's walk collects the
    /// anchors and headings in that range.
    pub fn beginRun(c: *Collector, f: *const Frame, lo: f32, hi: f32) void {
        c.run_frame = f;
        c.run = c.runs;
        c.runs += 1;
        c.run_lo = lo;
        c.run_hi = hi;
        c.run_begun = true;
    }

    /// Flattens the page's link groups into `pages[cur].content`, in tree order.
    pub fn endPage(c: *Collector) void {
        if (c.groups.items.len > 0) c.flatten(0) catch {
            c.failed = true;
        };
        // (groups in a page's memory go with it)
        if (c.page_a != null) c.groups = .empty else c.groups.clearRetainingCapacity();
        c.group = 0;
    }

    fn flatten(c: *Collector, g: u32) Error!void {
        for (c.groups.items[g].items) |en| switch (en) {
            .link => |lk| try c.pages.items[c.cur].content.append(c.a, lk),
            .group => |sub| try c.flatten(sub),
        };
    }

    fn current(c: *Collector) Error!*std.ArrayList(Entry) {
        if (c.groups.items.len == 0) try c.groups.append(c.groupMem(), .empty);
        return &c.groups.items[c.group];
    }

    fn groupMem(c: *const Collector) Allocator {
        return c.page_a orelse c.a;
    }

    /// The place of a box queued now and painted later: its group, to `enter` while painting it
    /// (`none` when out of memory: its links then go where the walk is).
    pub fn reserve(c: *Collector) u32 {
        const list = c.current() catch return none;
        const g: u32 = @intCast(c.groups.items.len);
        list.append(c.groupMem(), .{ .group = g }) catch return none;
        c.groups.append(c.groupMem(), .empty) catch {
            c.groups.items[c.group].items.len -= 1;
            return none;
        };
        return g;
    }

    /// Sends the links that follow to group `g` (from `reserve`); returns the group to `leave` to.
    pub fn enter(c: *Collector, g: u32) u32 {
        const prev = c.group;
        if (g != none) c.group = g;
        return prev;
    }

    pub fn leave(c: *Collector, prev: u32) void {
        c.group = prev;
    }

    /// Turns the anchors and headings found so far into destinations: the frames they were found in
    /// are shown by output pages `pages` / `windows` (the drawn pages since the last call), which
    /// are output pages `offset`.. of the document. `f`: the frame of an anchor without one.
    pub fn resolve(c: *Collector, f: *const Frame, pages: []const emit.PageBox, windows: []const emit.Window, offset: u32, structural: bool) void {
        const place: Place = .{ .f = f, .pages = pages, .windows = windows };
        var it = c.anchors.valueIterator();
        while (it.next()) |an| if (!an.resolved) {
            an.dest = place.destination(an.frame, an.top);
            if (an.dest) |*d| d.place(offset, an.chunk, an.node, structural);
            an.resolved = true;
            an.frame = null;
        };
        for (c.headings.items) |*h| if (!h.resolved) {
            h.dest = place.destination(h.frame, h.top);
            if (h.dest) |*d| d.place(offset, h.chunk, h.node, structural);
            h.resolved = true;
            h.frame = null;
        };
    }

    /// Whether link `lk` is written as an annotation, and its destination (null: a URI action): a
    /// `#fragment` naming no anchor, or one whose page is dropped, writes nothing. The anchors must
    /// be resolved.
    pub fn linkTarget(c: *const Collector, a: Allocator, lk: Link) Error!?LinkTarget {
        if (lk.uri[0] != '#') return .{ .dest = null };
        const id = try counters.percentDecode(a, lk.uri[1..]);
        const an = c.anchor(id) orelse return null;
        return .{ .dest = an.dest orelse return null };
    }

    /// The frames of the part of the document drawn so far go: forgets what refers to them.
    pub fn endChunk(c: *Collector) void {
        c.text_seen.clearRetainingCapacity();
        c.run_frame = null;
    }

    /// The anchor `id` names (first box wins), from the first page's walk.
    pub fn anchor(c: *const Collector, id: []const u8) ?Anchor {
        return c.anchors.get(id);
    }

    // ---- hooks (called by the emitter)

    /// A box painted at (`x`, `y`) of the emitter's current coordinates (`Emitter.paintBox`).
    pub noinline fn onBox(c: *Collector, e: *const emit.Emitter, id: u32, x: f32, y: f32) void {
        c.box(e, id, x, y) catch {
            c.failed = true;
        };
    }

    fn box(c: *Collector, e: *const emit.Emitter, id: u32, x: f32, y: f32) Error!void {
        const f = e.f;
        const n = &f.nodes.items[id];
        if (n.kind == .anon_text or n.el == none or n.lid == none) return;
        const fixed = c.inFixed(e);
        const l = f.tree.layout(n.lid);
        const r = aabb(e.tf, x, y, l.w, l.h) orelse return;
        if (!fixed and f == c.run_frame and c.run_first and r[1] >= c.run_lo and r[1] < c.run_hi) try c.summarize(n.el, id, r[1]);
        const href = f.dom.attr(n.el, "href") orelse return;
        if (!allowedUri(href)) return;
        try c.add(e, r, href, id, n.el);
    }

    /// The runs of paragraph node `n` laid out as `tl` at content origin (`x`, `y`)
    /// (`emit_text.paintText`).
    pub fn onText(c: *Collector, e: *const emit.Emitter, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32) void {
        c.text(e, n, tl, x, y) catch {
            c.failed = true;
        };
    }

    fn text(c: *Collector, e: *const emit.Emitter, n: *const Node, tl: *const font.TextLayout, x: f32, y: f32) Error!void {
        const f = e.f;
        const hm = try c.hrefMap(f);
        if (hm.count() == 0) return;
        const host: u32 = if (n.el != none) n.el else if (n.parent != none) f.nodes.items[n.parent].el else none;
        // a box that links as a whole is not linked again per run
        if (host != none) if (f.dom.attr(host, "href")) |h| if (allowedUri(h)) return;
        const id = f.nodeId(n);
        // takumi `collect_paint_links` reads the runs of a painted box that has a source node
        // (`PaintedBox::of`): the inline content of an anonymous block (text and inline elements
        // next to block-level siblings) is never linked, whatever element carries the `href`
        if ((n.kind == .anon_text or n.kind == .anon_box) and !tags.standsForParent(f, id)) return;
        const key: TextKey = .{ .f = @intFromPtr(f), .id = id, .x = @bitCast(x), .y = @bitCast(y) };
        if ((try c.text_seen.getOrPut(c.a, key)).found_existing) return;
        var it: render.RunIter = .{ .tl = tl };
        while (it.next()) |r| {
            const g = &tl.glyphs[r.g0];
            const el = runLink(f, hm, n, g.user) orelse continue;
            const href = f.dom.attr(el, "href") orelse continue;
            if (!allowedUri(href)) continue;
            const fnt = f.r.fonts.font(g.face);
            const sc = g.size / @as(f32, @floatFromInt(@max(1, fnt.unitsPerEm())));
            const lm = fnt.lineMetrics();
            const asc = @as(f32, @floatFromInt(lm.ascent)) * sc;
            const desc = @as(f32, @floatFromInt(lm.descent)) * sc;
            // (a fragment of a transformed box a page boundary cuts links the runs laid out in it)
            if (@import("emit_text.zig").inOtherFragment(e, x + r.x0, x + r.x1, y + r.baseline - asc, y + r.baseline + desc)) continue;
            const rect = aabb(e.tf, x + r.x0, y + r.baseline - asc, r.x1 - r.x0, asc + desc) orelse continue;
            try c.add(e, rect, href, id, el);
        }
    }

    /// Whether the emitter is painting a repeated `position: fixed` box (`emit.paintFixed` paints
    /// them unwindowed, in page-area coordinates).
    fn inFixed(c: *const Collector, e: *const emit.Emitter) bool {
        return c.win.paged() and !e.window.paged();
    }

    fn add(c: *Collector, e: *const emit.Emitter, r: [4]f32, uri: []const u8, node: u32, el: u32) Error!void {
        if (c.collect_only) return;
        const page = c.page;
        const fixed = c.inFixed(e);
        var y0: f32 = 0;
        var y1: f32 = page.height;
        if (fixed) {
            y1 = page.content.h;
        } else if (c.win.paged()) {
            y0 = c.win.top;
            y1 = c.win.bottom;
        }
        const ox = page.content.x;
        const oy = page.content.y;
        // takumi `add_link_annotations`: clipped to the page's span, offset by the margins, in pt
        const top = @max(r[1], y0);
        const bottom = @min(r[3], y1);
        if (!(bottom > top)) return;
        const l = (r[0] + ox) * pt_per_px;
        const t = (top - y0 + oy) * pt_per_px;
        const rr = (r[2] + ox) * pt_per_px;
        const b = (bottom - y0 + oy) * pt_per_px;
        if (!(rr >= l) or !std.math.isFinite(l + t + rr + b)) return;
        const h = page.height * pt_per_px;
        const link: Link = .{ .rect = .{ l, h - b, rr, h - t }, .uri = uri, .node = node, .el = el, .frame = e.f, .repeated = e.in_repeat };
        if (fixed) return c.pages.items[c.cur].fixed.append(c.a, link);
        try (try c.current()).append(c.groupMem(), .{ .link = link });
    }

    fn summarize(c: *Collector, el: u32, node: u32, top: f32) Error!void {
        const f = c.f;
        const id = f.dom.at(el).id;
        if (id.len > 0) {
            const gop = try c.anchors.getOrPut(c.a, id);
            if (!gop.found_existing) gop.value_ptr.* = .{ .top = top, .node = node, .el = el, .frame = c.run_frame, .run = c.run, .chunk = c.chunk };
        }
        // the nearest heading at or above the element
        var cur = el;
        while (cur != none) : (cur = f.dom.at(cur).parent) {
            const lvl = headingLevel(f.dom.at(cur).tag) orelse continue;
            if ((try c.heading_els.getOrPut(c.a, cur)).found_existing) return;
            const t = try textContent(c.a, f, cur);
            if (t.len > 0) try c.headings.append(c.a, .{ .level = lvl, .text = t, .top = top, .el = cur, .node = if (cur == el) node else nodeOf(f, cur), .frame = c.run_frame, .run = c.run, .chunk = c.chunk });
            return;
        }
    }

    fn hrefMap(c: *Collector, f: *const Frame) Error!*const std.AutoHashMapUnmanaged(usize, u32) {
        const key = @intFromPtr(f.dom.els.items.ptr);
        for (c.href_maps.items) |*m| if (m.dom == key) return &m.map;
        var m: HrefMap = .{ .dom = key };
        for (f.dom.els.items, 0..) |*el, i| {
            if (el.run) continue;
            const h = f.dom.attr(@intCast(i), "href") orelse continue;
            if (h.len == 0) continue;
            try m.map.put(c.a, @intFromPtr(el.cs), @intCast(i));
        }
        try c.href_maps.append(c.a, m);
        return &c.href_maps.items[c.href_maps.items.len - 1].map;
    }
};

/// The element whose `href` a run of paragraph `n` sits in: its own element, then its inline boxes
/// outwards (takumi `link_of(node).or(link)`), then the paragraph's block.
fn runLink(f: *const Frame, hm: *const std.AutoHashMapUnmanaged(usize, u32), n: *const Node, user: u32) ?u32 {
    if (user < f.run_styles.items.len) {
        if (hm.get(@intFromPtr(f.run_styles.items[user]))) |el| return el;
        var bx = if (user < f.run_box.items.len) f.run_box.items[user] else none;
        var guard: u32 = 0;
        while (bx != none and bx >= n.box_base and bx < f.inline_boxes.items.len and guard < 1024) : (guard += 1) {
            if (hm.get(@intFromPtr(f.inline_boxes.items[bx].cs))) |el| return el;
            bx = f.inline_boxes.items[bx].parent;
        }
    }
    if (hm.get(@intFromPtr(n.cs))) |el| return el;
    return null;
}

/// The axis-aligned bounds of the rect (`x`, `y`, `wd`, `h`) under `tf`: `[left, top, right, bottom]`.
fn aabb(tf: Affine, x: f32, y: f32, wd: f32, h: f32) ?[4]f32 {
    if (tf.isTranslateOnly()) {
        const r = [4]f32{ x + tf.e, y + tf.f, x + wd + tf.e, y + h + tf.f };
        return if (std.math.isFinite(r[0] + r[1] + r[2] + r[3])) r else null;
    }
    const pts = [4]raster.Point{
        tf.apply(.{ .x = x, .y = y }),
        tf.apply(.{ .x = x + wd, .y = y }),
        tf.apply(.{ .x = x, .y = y + h }),
        tf.apply(.{ .x = x + wd, .y = y + h }),
    };
    var r = [4]f32{ pts[0].x, pts[0].y, pts[0].x, pts[0].y };
    for (pts[1..]) |p| {
        r[0] = @min(r[0], p.x);
        r[1] = @min(r[1], p.y);
        r[2] = @max(r[2], p.x);
        r[3] = @max(r[3], p.y);
    }
    return if (std.math.isFinite(r[0] + r[1] + r[2] + r[3])) r else null;
}

/// takumi `allowed_link_uri`: a non-empty `#fragment`, or an `http`, `https`, `mailto` or `tel` URI.
pub fn allowedUri(uri: []const u8) bool {
    if (uri.len > 0 and uri[0] == '#') return uri.len > 1;
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
    const scheme = uri[0..colon];
    for ([_][]const u8{ "http", "https", "mailto", "tel" }) |s| {
        if (std.ascii.eqlIgnoreCase(scheme, s)) return true;
    }
    return false;
}

pub fn nodeOf(f: *const Frame, el: u32) u32 {
    for (f.nodes.items, 0..) |*n, i| if (n.el == el and n.kind != .anon_text and n.kind != .anon_box) return @intCast(i);
    return none;
}

pub fn headingLevel(tag: []const u8) ?u8 {
    if (tag.len != 2 or (tag[0] != 'h' and tag[0] != 'H')) return null;
    if (tag[1] < '1' or tag[1] > '6') return null;
    return tag[1] - '0';
}

/// takumi `text_content`: the text of the element's subtree in the render tree, trimmed (Unicode
/// white space): the source text as written (no `text-transform`), the generated text of
/// `::before` / `::after`, nothing of a `display: none` descendant (it has no box).
pub fn textContent(a: Allocator, f: *const Frame, el: u32) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try collectText(a, f, el, &out, 0);
    return trimUnicode(out.items);
}

fn pseudoText(a: Allocator, f: *const Frame, p: u32, out: *std.ArrayList(u8)) Error!void {
    if (p == none or p >= f.pseudos.items.len) return;
    const ps = &f.pseudos.items[p];
    if (ps.cs.display == .none) return;
    try out.appendSlice(a, ps.text);
}

fn collectText(a: Allocator, f: *const Frame, el: u32, out: *std.ArrayList(u8), depth: u32) Error!void {
    if (depth > 512) return;
    const e = f.dom.at(el);
    if (depth > 0 and !e.run and e.cs.display == .none) return;
    // (a list marker is generated in the `::before` slot, the real `::before` chained to it;
    // the marker's text is not the element's)
    const before = if (markers.ofPseudo(f, e.before) != null) markers.chainedBefore(f, e.before) else e.before;
    try pseudoText(a, f, before, out);
    if (e.kind == .text) try out.appendSlice(a, e.text);
    var c = e.first;
    while (c != none) : (c = f.dom.at(c).next) try collectText(a, f, c, out, depth + 1);
    try pseudoText(a, f, e.after, out);
}

fn isUnicodeSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn trimUnicode(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[start]) catch break;
        if (start + len > s.len) break;
        const cp = std.unicode.utf8Decode(s[start .. start + len]) catch break;
        if (!isUnicodeSpace(cp)) break;
        start += len;
    }
    var end = s.len;
    while (end > start) {
        var k = end - 1;
        while (k > start and s[k] & 0xC0 == 0x80) k -= 1;
        const cp = std.unicode.utf8Decode(s[k..end]) catch break;
        if (!isUnicodeSpace(cp)) break;
        end = k;
    }
    return s[start..end];
}

// ---------------------------------------------------------------------------------------------
// The document-level pass
// ---------------------------------------------------------------------------------------------

/// An annotation written, for the tagging wave (Link structure elements, /StructParent).
pub const AnnotRecord = struct { ref: w.Ref, page: u32, node: u32, el: u32, uri: []const u8, repeated: bool };

/// What a tagging pass adds to an annotation (written after /F, as krilla does).
pub const AnnotExtra = struct { struct_parent: ?i32 = null, alt: ?[]const u8 = null };

/// The tagging / PDF/A wave's entry: `annot` is asked for every annotation as it is written,
/// `run` gets the document parts (catalog, Info, XMP) and the annotations before the file is
/// finished.
pub const DocHook = struct {
    ctx: *anyopaque,
    annot: ?*const fn (ctx: *anyopaque, rec: AnnotRecord) AnnotExtra = null,
    run: ?*const fn (ctx: *anyopaque, d: *w.Doc, parts: *meta.Parts, annots: []const AnnotRecord) Error!void = null,
    /// [tagging] after the annotations, before the destinations are written: the structure tree
    tree: ?*const fn (ctx: *anyopaque, d: *w.Doc) Error!void = null,
    /// [tagging] the structure element a destination at render node `node` (of part `chunk` of the
    /// document) names (PDF/UA-2)
    dest: ?*const fn (ctx: *anyopaque, chunk: u32, node: u32) ?w.Ref = null,
};

/// A destination in output coordinates (pt, y up).
/// An XYZ destination on output page `page`; `node` / `chunk`: the render node (of that part of
/// the document) whose structure element a PDF/UA-2 destination names (`none`: the page).
pub const Dest = struct {
    page: u32,
    x: f32,
    y: f32,
    node: u32 = none,
    chunk: u32 = 0,

    fn place(d: *Dest, offset: u32, chunk: u32, node: u32, structural: bool) void {
        d.page += offset;
        if (structural) {
            d.node = node;
            d.chunk = chunk;
        }
    }
};

const Dests = struct {
    items: std.ArrayList(struct { d: Dest, ref: w.Ref }) = .empty,

    fn register(ds: *Dests, a: Allocator, doc: *w.Doc, d: Dest) Error!w.Ref {
        for (ds.items.items) |it| {
            if (it.d.page == d.page and it.d.node == d.node and it.d.chunk == d.chunk and @as(u32, @bitCast(it.d.x)) == @as(u32, @bitCast(d.x)) and @as(u32, @bitCast(it.d.y)) == @as(u32, @bitCast(d.y))) return it.ref;
        }
        const r = doc.alloc();
        try ds.items.append(a, .{ .d = d, .ref = r });
        return r;
    }
};

/// Where a frame position lands in the output.
const Place = struct {
    f: *const Frame,
    pages: []const emit.PageBox,
    windows: []const emit.Window,

    /// takumi `Destinations::destination` / `SinglePage::destination`: null when the page holding
    /// `top` is dropped by `pageRanges`.
    fn destination(p: Place, frame: ?*const Frame, top: f32) ?Dest {
        const f = frame orelse p.f;
        if (p.pages.len == 0) return null;
        var k: usize = 0;
        var y: f32 = undefined;
        var x: f32 = 0;
        const paged = f.paginated();
        if (paged != null and p.windows.len > 0 and p.windows[0].paged() and paged.?.pages.len > 0) {
            const pg = paged.?.pages[paged.?.pageAt(top)];
            k = for (p.windows, 0..) |win, i| {
                if (win.top == pg.top and (p.pages[i].frame orelse p.f) == f) break i;
            } else return null;
            const pb = p.pages[k];
            x = pb.content.x;
            y = pb.content.y + @max(top - pg.top, 0);
        } else {
            y = @max(top, 0);
        }
        const h = p.pages[k].height * pt_per_px;
        return .{ .page = @intCast(k), .x = x * pt_per_px, .y = h - y * pt_per_px };
    }
};

const OutlineNode = struct { text: []const u8, dest: Dest, children: []OutlineNode };

/// takumi `PageSummary::outline`: nests the sorted headings, a heading without a destination
/// yielding its place to its children.
fn take(a: Allocator, hs: []const Heading, idx: *usize, level: u8) Error![]OutlineNode {
    var nodes: std.ArrayList(OutlineNode) = .empty;
    while (idx.* < hs.len) {
        const h = hs[idx.*];
        if (h.level < level) break;
        idx.* += 1;
        const children = try take(a, hs, idx, h.level + 1);
        if (h.dest) |d| {
            try nodes.append(a, .{ .text = h.text, .dest = d, .children = children });
        } else try nodes.appendSlice(a, children);
    }
    return nodes.items;
}

const Serialized = struct { first: w.Ref, last: w.Ref, count: usize };

/// krilla `serialize_children`: each child's own children first, then the child (closed).
fn writeOutlineChildren(a: Allocator, doc: *w.Doc, dests: *Dests, nodes: []const OutlineNode, parent: w.Ref) Error!?Serialized {
    if (nodes.len == 0) return null;
    const refs = try a.alloc(w.Ref, nodes.len);
    for (refs) |*r| r.* = doc.alloc();
    for (nodes, 0..) |nd, i| {
        const kids = try writeOutlineChildren(a, doc, dests, nd.children, refs[i]);
        const dref = try dests.register(a, doc, nd.dest);
        const b = doc.beginDict(refs[i], .outline);
        b.pairRef("Parent", parent);
        if (i + 1 < nodes.len) b.pairRef("Next", refs[i + 1]);
        if (i > 0) b.pairRef("Prev", refs[i - 1]);
        if (kids) |k| {
            b.pairRef("First", k.first);
            b.pairRef("Last", k.last);
            b.pairInt("Count", -@as(i64, @intCast(k.count)));
        }
        b.pairText("Title", nd.text);
        b.pairRef("Dest", dref);
        doc.endDict();
    }
    return .{ .first = refs[0], .last = refs[refs.len - 1], .count = nodes.len };
}

/// The result of `finishDocument`: per output page its /Annots, and the parts `metadata.finish`
/// writes.
pub const Finished = struct {
    annots: []const []const w.Ref,
    records: []const AnnotRecord,
    parts: meta.Parts,
};

/// Writes the outline, the annotations, their destinations and the attachments, and assembles the
/// catalog / Info / XMP parts. `page_refs`: the page objects, in output order.
/// The anchors and headings must be resolved (`Collector.resolve`).
pub fn finishDocument(c: *Collector, doc: *w.Doc, a: Allocator, page_count: usize, page_refs: []const w.Ref, o: *const opt.PdfOptions, producer: []const u8, hook: ?DocHook) Error!Finished {
    c.endPage();
    if (c.failed) return error.OutOfMemory;
    var dests: Dests = .{};
    var parts: meta.Parts = .{ .producer = producer, .metadata = meta.Metadata.forOptions(o) };
    if (parts.metadata) |m| parts.catalog.lang = m.language;

    // outline (krilla serializes it before the pages, so its destinations come first)
    const wants_outline = o.outline or o.tagged == .ua1 or o.tagged == .ua2;
    if (wants_outline and c.headings.items.len > 0) {
        const hs = try a.dupe(Heading, c.headings.items);
        std.mem.sort(Heading, hs, {}, struct {
            fn lt(_: void, x: Heading, y: Heading) bool {
                return if (x.run != y.run) x.run < y.run else x.top < y.top;
            }
        }.lt);
        var idx: usize = 0;
        const tree = try take(a, hs, &idx, 1);
        if (tree.len > 0) {
            const root = doc.alloc();
            const kids = try writeOutlineChildren(a, doc, &dests, tree, root);
            const b = doc.beginDict(root, .outline);
            b.pairName("Type", "Outlines");
            if (kids) |k| {
                b.pairRef("First", k.first);
                b.pairRef("Last", k.last);
                b.pairInt("Count", @intCast(k.count));
            }
            doc.endDict();
            parts.catalog.outlines = root;
        }
    }

    // annotations, page by page: the page's own links, then the repeated boxes'
    const annots = try a.alloc([]const w.Ref, page_count);
    var records: std.ArrayList(AnnotRecord) = .empty;
    for (c.pages.items, 0..) |*pl, pi| {
        var refs: std.ArrayList(w.Ref) = .empty;
        for ([_][]const Link{ pl.content.items, pl.fixed.items }, 0..) |list, which| {
            for (list) |lk| {
                const target = try c.linkTarget(a, lk) orelse continue;
                const dref: ?w.Ref = if (target.dest) |d| try dests.register(a, doc, d) else null;
                const ref = doc.alloc();
                const rec: AnnotRecord = .{ .ref = ref, .page = @intCast(pi), .node = lk.node, .el = lk.el, .uri = lk.uri, .repeated = which == 1 or lk.repeated };
                const b = doc.beginDict(ref, .annotations);
                b.pairName("Type", "Annot");
                b.pairName("Subtype", "Link");
                b.pairRect("Rect", lk.rect);
                b.raw("/Border[0 0 0]");
                if (dref) |r| {
                    b.pairRef("Dest", r);
                } else {
                    b.raw("/A<</Type/Action/S/URI");
                    b.pairStr("URI", lk.uri);
                    b.raw(">>");
                }
                b.pairInt("F", 4);
                if (hook) |hk| if (hk.annot) |f| {
                    const x = f(hk.ctx, rec);
                    if (x.struct_parent) |sp| b.pairInt("StructParent", sp);
                    if (x.alt) |alt| b.pairText("Contents", alt);
                };
                doc.endDict();
                try refs.append(a, ref);
                try records.append(a, rec);
            }
        }
        annots[pi] = refs.items;
    }

    // [tagging] the structure tree (PDF/UA-2 destinations name its elements)
    if (hook) |hk| if (hk.tree) |f| try f(hk.ctx, doc);

    // destinations, in registration order
    for (dests.items.items) |it| {
        const b = doc.begin(it.ref, .destinations);
        b.arr();
        const se: ?w.Ref = if (hook) |hk| (if (hk.dest) |f| f(hk.ctx, it.d.chunk, it.d.node) else null) else null;
        b.ref(se orelse page_refs[it.d.page]);
        b.name("XYZ");
        b.real(it.d.x);
        b.real(it.d.y);
        b.int(0);
        b.arrEnd();
        doc.end();
    }

    const files = try attach.write(doc, a, o);
    parts.catalog.embedded_files = files.names;
    parts.catalog.af = files.af;

    if (hook) |hk| if (hk.run) |f| try f(hk.ctx, doc, &parts, records.items);
    return .{ .annots = annots, .records = records.items, .parts = parts };
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

test "allowed link URIs (takumi allowed_link_uri)" {
    try testing.expect(allowedUri("#a"));
    try testing.expect(!allowedUri("#"));
    try testing.expect(allowedUri("HTTPS://x"));
    try testing.expect(allowedUri("mailto:a@b"));
    try testing.expect(allowedUri("tel:+1"));
    try testing.expect(!allowedUri("javascript:alert(1)"));
    try testing.expect(!allowedUri("page.html"));
    try testing.expect(!allowedUri(""));
}

test "heading levels and trimmed text" {
    try testing.expectEqual(@as(?u8, 3), headingLevel("H3"));
    try testing.expectEqual(@as(?u8, null), headingLevel("h7"));
    try testing.expectEqual(@as(?u8, null), headingLevel("header"));
    try testing.expectEqualStrings("a b", trimUnicode("\u{a0} \na b\u{3000}\t"));
    try testing.expectEqualStrings("", trimUnicode(" \u{2003} "));
}
