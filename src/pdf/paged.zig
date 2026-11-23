//! A paged document laid out for drawing (takumi-pdf `PageDrawing::solve` / `stream` / `compose`,
//! `Counted::settle`): the bands measured, the margins resolved around them, the content laid out
//! and paginated until its counters settle, and one `PageBox` + `Window` per page kept by
//! `pageRanges`, each with its header / footer band and, when a repeating `position: fixed` box
//! holds a page counter, that page's own layout of the fixed boxes.
//!
//! Passes (takumi): the bands are measured with the counters of a one-page document, the margins
//! resolved, and the content laid out. Content holding counter hooks lays out again with the numbers
//! the previous pass gave them until they stop changing (`counter_passes` = 3, then once more with
//! the last numbers). Bands that hold a counter or differ per page (dynamic) are measured again with
//! the real page count, and when that moves an `auto` margin the content is laid out again from
//! scratch (`band_passes` = 3).
//!
//! Page geometry: the `size` / `margin` options with the document's `@page`, `:first`, `:left` and
//! `:right` rules over them, and those of the named pages (page_rules.zig), per page: its kind and
//! the name the pagination gave it (the `page` property: page_names.zig; a change of page name
//! breaks the page, fragment.zig).
//!
//! Page widths (takumi `PageStream` / `PageSizer`: each page laid out at its own page area): when
//! every page area has the same width the content lays out once. Otherwise `laySegments` lays it
//! out in runs of pages of one width: a frame at the first page's width shows the pages up to the
//! first page of another width, and the content from where that page starts (`Pages.starts`: a
//! box, or the line a paragraph broke at) is laid out again in a new frame at that width
//! (`layout.fragment.Options.start` / `start_top`, `font.Paragraph.cut`), in the same block
//! coordinates, and so on. The frames are one document (same element model and render nodes):
//! counters (`counters.Seg`), links and anchors (`interactive.Collector.beginRun`), the structure
//! tree and the emitter's neighbouring page passes (`emit.PageBox.frame` / `prev_win` / `next_win`)
//! work across them. Parallel flows broken inside (a table row's cells, a flex line's or a grid
//! row's items) resume at one point each; a flex or grid container continued on a page of another
//! width keeps laying its items out at its first fragment's width (`frozenWidths`). A page whose
//! start cannot be found again in the new frame keeps the width of the run before it.
//!
//! Memory: each layout of the content (`Pass`) has an arena of its own (`Pass.mem`), released as
//! soon as a later pass replaces it, so the counter and band passes of a long document hold one
//! layout at a time; the last one is the `Document`'s, released once the file is written
//! (`Document.release`). What a pass hands on to the next (the hooks' texts, which hooks sit in a
//! fixed box) is copied into the call's arena.
const std = @import("std");
const rt = @import("../render.zig");
const json = @import("../json.zig");
const style = @import("../style/style.zig");
const opt = @import("options.zig");
const emit = @import("emit.zig");
const bands = @import("bands.zig");
const counters = @import("counters.zig");
const layout = @import("../layout/layout.zig");
const page_rules = @import("page_rules.zig");
const bump = @import("../bump.zig");
const memtrace = @import("../memtrace.zig");
const chunks = @import("chunks.zig");

const Allocator = std.mem.Allocator;
const Frame = rt.Frame;
const Seg = counters.Seg;
const Error = rt.Error;

const counter_passes = 3;
const band_passes = 3;

/// The pages of a paged document, ready for `emit.writeDocument`.
pub const Document = struct {
    frame: *Frame,
    pages: []const emit.PageBox,
    windows: []const emit.Window,
    /// the document's page count before `pageRanges` (counters number over it)
    count: usize,
    /// the memory of the content's layout (`Pass.mem`): `frame` and the pages' frames, repeats and
    /// fixed boxes live in it until `release`
    mem: *bump.Bump,
    /// a first layout whose root changed the page rules this one was made with (`layOut`), kept as
    /// long as this one
    prev: ?*bump.Bump = null,

    /// Frees the content's layout (after the file is written: nothing may use the document then).
    pub fn release(d: *const Document, r: *rt.Renderer) void {
        freeMem(r, d.mem);
        if (d.prev) |m| freeMem(r, m);
    }
};

/// A new arena for a pass (`Pass.mem`), on the renderer's allocator.
fn newMem(r: *rt.Renderer) Error!*bump.Bump {
    const m = r.gpa.create(bump.Bump) catch return error.OutOfMemory;
    m.* = bump.Bump.init(r.gpa);
    m.release_freed = true;
    return m;
}

fn freeMem(r: *rt.Renderer, m: *bump.Bump) void {
    m.deinit();
    r.gpa.destroy(m);
}

/// One layout of the content, paginated: one frame, or one per run of pages of one width.
pub const Pass = struct {
    /// the first run's frame (every frame has the same element model and render nodes)
    frame: *Frame,
    segs: []const Seg,
    /// the counter hooks met, in document order, and the texts they were laid out with
    hooks: []const counters.Hook,
    texts: []const ?[]const u8,
    /// the repeating `position: fixed` boxes (`emit.repeatingFixed`), as a mask over the nodes, and
    /// which hooks sit inside one
    fixed: []const u32,
    mask: []const bool,
    fixed_hooks: []const bool,
    /// the pass's arena: its frames and everything above that is not `texts`
    mem: *bump.Bump,

    /// Frees the pass (its `texts` are the caller's).
    fn release(p: *const Pass, r: *rt.Renderer) void {
        freeMem(r, p.mem);
    }

    fn pageCount(p: *const Pass) usize {
        var n: usize = 0;
        for (p.segs) |s| n += s.count;
        return n;
    }
};

const Ctx = struct {
    doc: bands.Doc,
    kind: rt.SourceKind,
    source: []const u8,
};

/// The page geometry of each kind of page (`@page`, `:first`, `:left` / `:right`: page_rules.zig)
/// of the unnamed pages and of each named page, each with its margins resolved around the bands and
/// its page area.
const Geo = struct {
    pages: page_rules.Pages,
    /// per page name entry (0 = unnamed, 1 + k = `pages.named[k]`), per `page_rules.Kind`
    margin: []const [3]opt.Rect,
    areas: []const [3][2]f32,
    /// the page names of the frame being paginated (`layout.fragment.PagedState.page_names`)
    names: []const []const u8 = &.{},

    fn resolve(r: *rt.Renderer, a: Allocator, pages: page_rules.Pages, header: ?f32, footer: ?f32) Error!Geo {
        const n = 1 + pages.named.len;
        const margin = try a.alloc([3]opt.Rect, n);
        const areas = try a.alloc([3][2]f32, n);
        for (0..n) |e| {
            const kinds: [3]opt.Page = if (e == 0) .{ pages.first, pages.left, pages.right } else .{ pages.named[e - 1].first, pages.named[e - 1].left, pages.named[e - 1].right };
            for (kinds, 0..) |p, k| {
                margin[e][k] = p.resolveMargins(header, footer);
                const ar = p.contentSize(margin[e][k]) orelse return invalidPage(r);
                areas[e][k] = .{ ar.width, ar.height };
            }
        }
        return .{ .pages = pages, .margin = margin, .areas = areas };
    }

    /// The name of page name id `id` of the frame (null: unnamed).
    fn nameOf(g: *const Geo, id: u32) ?[]const u8 {
        return if (id >= 1 and id <= g.names.len) g.names[id - 1] else null;
    }
    fn entry(g: *const Geo, name: ?[]const u8) usize {
        return if (g.pages.namedIndex(name)) |k| k + 1 else 0;
    }
    fn page(g: *const Geo, i: usize, name: ?[]const u8) opt.Page {
        return g.pages.pageNamed(i, name);
    }
    fn margins(g: *const Geo, i: usize, name: ?[]const u8) opt.Rect {
        return g.margin[g.entry(name)][@backingInt(g.pages.kindOf(i))];
    }
    fn area(g: *const Geo, i: usize, name: ?[]const u8) [2]f32 {
        return g.areas[g.entry(name)][@backingInt(g.pages.kindOf(i))];
    }
    fn sameMargins(g: *const Geo, o: *const Geo) bool {
        if (g.margin.len != o.margin.len or g.pages.rtl != o.pages.rtl) return false;
        for (g.margin, o.margin) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }
    /// every page area as wide as the first page's
    fn uniformWidth(g: *const Geo) bool {
        const w = g.areas[0][0][0];
        for (g.areas) |e| for (e) |ar| if (ar[0] != w) return false;
        return true;
    }
    /// every page area as tall as the first page's
    fn uniformHeight(g: *const Geo) bool {
        const h = g.areas[0][0][1];
        for (g.areas) |e| for (e) |ar| if (ar[1] != h) return false;
        return true;
    }
    /// `layout.fragment.PageHeightFn`: page `i`'s area height, a page named `name`
    fn heightOf(ctx: *anyopaque, i: u32, name: u32) f32 {
        const g: *const Geo = @ptrCast(@alignCast(ctx));
        return g.area(i, g.nameOf(name))[1];
    }
};

/// One layout of the content, paginated, in an arena of its own (`Pass.mem`). `texts` and
/// `fixed_hooks` (the previous pass's findings) must not live in a pass's arena that is released
/// before this pass is.
fn layPass(cx: *const Ctx, geo: *const Geo, texts: []const ?[]const u8, fixed_hooks: []const bool) Error!Pass {
    const mem = try newMem(cx.doc.r);
    errdefer freeMem(cx.doc.r, mem);
    const a = mem.allocator();
    var subst: counters.Subst = .{ .a = a, .mode = .{ .flow = .{ .texts = texts, .fixed = fixed_hooks } } };
    const g = try a.create(Geo);
    g.* = geo.*;
    var segs: std.ArrayList(Seg) = .empty;
    if (geo.uniformWidth()) {
        // (every page as wide: one layout, paginated)
        const f = try bands.buildFrame(cx.doc.r, a, cx.doc.o, cx.doc.css, cx.kind, cx.source, null, geo.area(0, null), &subst);
        g.names = f.tree.paged.page_names;
        const varies = !geo.uniformHeight();
        const pages = try f.paginate(.{ .page_height = geo.area(0, null)[1], .page_height_fn = if (varies) Geo.heightOf else null, .ctx = @ptrCast(g) });
        try segs.append(a, .{ .frame = f, .first = 0, .local0 = 0, .count = @intCast(pages.pages.len) });
        memtrace.mark("pass: paginated");
    } else try laySegments(cx, a, g, &subst, &segs);
    // (laid out and paginated: the layout is only read from now on)
    for (segs.items) |s| s.frame.tree.dropCaches();
    memtrace.mark("pass: caches dropped");
    const f = segs.items[0].frame;
    const fixed = try emit.repeatingFixed(a, f);
    const mask = try counters.fixedMask(a, f, fixed);
    const hooks = try a.dupe(counters.Hook, subst.hooks.items);
    return .{
        .frame = f,
        .segs = segs.items,
        .hooks = hooks,
        .texts = texts,
        .fixed = fixed,
        .mask = mask,
        .fixed_hooks = try counters.fixedHooks(a, f, hooks, mask),
        .mem = mem,
    };
}

/// The page area heights of a run of pages laid out at one width: page `i` of its frame is page
/// `base + i - fake` of the document (`fake`: page 0 holds what earlier runs show).
const SegCtx = struct {
    g: *const Geo,
    base: u32,
    fake: u32,

    fn height(ctx: *anyopaque, i: u32, name: u32) f32 {
        const c: *const SegCtx = @ptrCast(@alignCast(ctx));
        return c.g.area(c.base + (i -| c.fake), c.g.nameOf(name))[1];
    }
};

/// The pages of the content when page areas differ in width (takumi lays each page out at its own
/// width, `PageStream` / `PageSizer`): a frame laid out at the first page's width shows the pages
/// up to the first page of another width; the content from that page's start (`Pages.starts`: a
/// box, or the line a paragraph broke at) is laid out again at that width, from that point
/// (`layout.fragment.Options.start`; a paragraph broken between lines is broken there again and
/// the rest wraps at the new width: `font.Paragraph.cut`), and so on. The frames are of one
/// document (same element model, same render nodes), so counters, links, anchors and the
/// structure tree work across them. A page whose start is not one point (parallel flows broken
/// inside) keeps the width of the run before it.
fn laySegments(cx: *const Ctx, a: Allocator, g: *Geo, subst: *counters.Subst, segs: *std.ArrayList(Seg)) Error!void {
    const no_node = layout.fragment.Start{};
    var width = g.area(0, null)[0];
    var base: u32 = 0;
    var start: ?layout.fragment.Start = null;
    var cuts: []const bands.Cut = &.{};
    var row_minimums: []const layout.fragment.RowMinimum = &.{};
    var float_shifts: []const f32 = &.{};
    var float_extents: []const f32 = &.{};
    var frozen: []const layout.fragment.FrozenWidth = &.{};
    // (the block size of each table row as laid out at the width of the page its table starts on:
    // takumi lays a table's rows out once; a row that starts on a page of another width keeps it,
    // a row broken inside goes on with the block size its last fragment's table left it,
    // `Start.row_height`. The rows of a table with a row span keep it in either case.)
    var assigned_rows: std.ArrayList(layout.fragment.RowMinimum) = .empty;
    var spanning_rows: std.ArrayList(u32) = .empty;
    var recorded_tables: std.ArrayList(u32) = .empty;
    var start_top: f32 = 0;
    var retried = false;
    while (true) {
        const f = try bands.buildFrameCuts(cx.doc.r, a, cx.doc.o, cx.doc.css, cx.kind, cx.source, null, .{ width, g.area(base, null)[1] }, subst, cuts, row_minimums, float_shifts, float_extents, frozen);
        g.names = f.tree.paged.page_names;
        if (segs.items.len > 0 and !sameNodes(segs.items[0].frame, f)) return extendLast(segs);
        if (start) |*s| {
            if (s.branches.len > 0) {
                const points = try a.dupe(layout.fragment.ResumePoint, s.branches);
                for (points) |*p| {
                    if (p.finished or p.line == no_node.line) continue;
                    for (cuts) |c| if (c.node == f.lid_node.items[p.node]) {
                        p.line = lineStarting(f, c.node, c.glyph) orelse return extendLast(segs);
                        break;
                    };
                }
                s.branches = points;
            } else if (s.line != no_node.line) {
                for (cuts) |cut| if (cut.node == f.lid_node.items[s.node]) {
                    s.line = lineStarting(f, cut.node, cut.glyph) orelse return extendLast(segs);
                    break;
                };
            }
            const side = try a.dupe(layout.fragment.ResumePoint, s.side_flows);
            for (side) |*point| {
                if (point.finished or point.line == no_node.line) continue;
                for (cuts) |cut| if (cut.node == f.lid_node.items[point.node]) {
                    point.line = lineStarting(f, cut.node, cut.glyph) orelse return extendLast(segs);
                    break;
                };
            }
            s.side_flows = side;
        }
        const sc = try a.create(SegCtx);
        sc.* = .{ .g = g, .base = base, .fake = @intFromBool(start != null) };
        // (the rows' block sizes as laid out, before pagination moves lines down inside them)
        var laid_rows: std.AutoHashMapUnmanaged(u32, f32) = .empty;
        for (f.tree.table_geoms.items) |table| for (table.rows) |row| if (row.node != no_node.node) try laid_rows.put(a, row.node, row.h);
        const pages = try f.paginate(.{ .page_height = g.area(base, null)[1], .page_height_fn = SegCtx.height, .ctx = @ptrCast(sc), .start = start, .start_top = if (start != null) start_top else null, .record_starts = true, .max_pages = max_pages + 1 });
        // (page 1 must start where the run before stopped, else the run before goes on)
        if (start) |s| if (pages.start_page == 0 or pages.pages.len < 2 or !sameStart(pages.starts[1], s)) {
            return extendLast(segs);
        };
        const fake = pages.start_page;
        // (the first run is as wide as the first page, which may be a named page)
        if (base == 0 and !retried) {
            retried = true;
            const w0 = g.area(0, g.nameOf(pages.names[0]))[0];
            if (w0 != width) {
                width = w0;
                continue;
            }
        }
        var stop: ?u32 = null;
        var i: u32 = fake + 1;
        while (i < pages.pages.len) : (i += 1) {
            const candidate_width = g.area(base + i - fake, g.nameOf(pages.names[i]))[0];
            if (candidate_width == width) continue;
            const tok = pages.starts[i];
            // A rowspan may be the only flow left on this page boundary: the main-flow token has
            // no node, while the spanning cell's paragraphs continue independently in side_flows.
            if (tok.node == no_node.node and tok.side_flows.len == 0) continue;
            // (line 0: a paragraph whose first line a float pushed onto this page resumes whole,
            // no glyph cut needed)
            if (tok.line != no_node.line and tok.line != 0 and lineGlyph(f, tok.node, tok.line) == null) continue;
            stop = i;
            break;
        }
        const end: u32 = stop orelse @intCast(pages.pages.len);
        {
            const shown_top = if (start != null) start_top else -std.math.inf(f32);
            const shown_end = if (end < pages.pages.len) pages.pages[end].top else std.math.inf(f32);
            for (f.tree.table_geoms.items) |table| {
                if (table.node == no_node.node) continue;
                const known = for (recorded_tables.items) |n| {
                    if (n == table.node) break true;
                } else false;
                if (known) continue;
                const top = absTop(f, table.node);
                if (top < shown_top - 1.0 / 64.0 or top >= shown_end) continue;
                try recorded_tables.append(a, table.node);
                const spanning = for (table.cells) |cell| {
                    if (cell.rowspan > 1) break true;
                } else false;
                for (table.rows) |row| if (row.node != no_node.node) {
                    try assigned_rows.append(a, .{ .node = row.node, .height = laid_rows.get(row.node) orelse row.h });
                    if (spanning) try spanning_rows.append(a, row.node);
                };
            }
        }
        try segs.append(a, .{ .frame = f, .first = base, .local0 = fake, .count = end - fake });
        if (base + end - fake > max_pages) {
            cx.doc.r.setErr(too_many_pages, "");
            return error.Invalid;
        }
        const s_i = stop orelse return;
        var tok = pages.starts[s_i];
        // (a row broken inside whose cells' content ends on the run's last page: their fragments
        // reach past it by their block-end decorations, which the row's rest no longer holds)
        if (tok.branches.len > 0 and tok.row_height > 0 and s_i > 0) {
            var ext: std.ArrayList(layout.fragment.Extend) = .empty;
            const cut = try cellOverflow(a, f, pages.pages, tok.node, pages.pages[s_i - 1].top, pages.pages[s_i].top, &ext);
            if (ext.items.len > 0) {
                tok.row_height -= cut;
                segs.items[segs.items.len - 1].extends = ext.items;
            }
        }
        width = g.area(base + s_i - fake, g.nameOf(pages.names[s_i]))[0];
        base += s_i - fake;
        // (the run goes on where this one's pages end, in the same block coordinates: takumi's
        // pages stack in one space)
        start_top = pages.pages[s_i].top;
        start = tok;
        float_shifts = f.tree.paged.float_shifts;
        float_extents = f.tree.paged.float_extents;
        frozen = try frozenWidths(a, f, tok, frozen);
        var rows: std.ArrayList(layout.fragment.RowMinimum) = .empty;
        for (f.tree.table_geoms.items) |table| for (table.rows) |row| {
            for (assigned_rows.items) |minimum| {
                if (row.node != minimum.node) continue;
                var absolute_top: f32 = 0;
                var ancestor = row.node;
                while (ancestor < f.tree.nodes.items.len) : (ancestor = f.tree.nodes.items[ancestor].parent) absolute_top += f.tree.layout(ancestor).y;
                const spanning = std.mem.indexOfScalar(u32, spanning_rows.items, row.node) != null;
                if (absolute_top <= start_top + 1.0 / 64.0) {
                    if (spanning) {
                        try rows.append(a, .{ .node = row.node, .height = minimum.height, .top = row.y });
                    } else if (absolute_top + row.h <= start_top + 1.0 / 64.0) {
                        // (a row that ended before the start stays where it was: the rows after it
                        // keep their offsets, whatever the new width does to its content)
                        try rows.append(a, .{ .node = row.node, .height = row.h, .top = row.y });
                    }
                } else try rows.append(a, minimum);
                break;
            }
        };
        for (assigned_rows.items) |minimum| if (std.mem.indexOfScalar(u32, spanning_rows.items, minimum.node) != null) try rows.append(a, minimum);
        if (tok.branches.len > 0 and tok.row_height > 0) {
            try rows.append(a, .{ .node = tok.node, .height = tok.row_height });
        }
        row_minimums = try rows.toOwnedSlice(a);
        var next_cuts: std.ArrayList(bands.Cut) = .empty;
        if (tok.branches.len > 0) {
            for (tok.branches) |p| {
                if (p.finished) {
                    const node = f.lid_node.items[p.node];
                    if (f.nodes.items[node].para) |para| if (para.glyphs.len > 0) {
                        try next_cuts.append(a, .{ .node = node, .glyph = @intCast(para.glyphs.len) });
                    };
                    continue;
                }
                if (p.line == no_node.line) continue;
                const glyph = lineGlyph(f, p.node, p.line) orelse return extendLast(segs);
                try next_cuts.append(a, .{ .node = f.lid_node.items[p.node], .glyph = glyph });
            }
        } else if (tok.line != no_node.line and tok.line != 0) try next_cuts.append(a, .{ .node = f.lid_node.items[tok.node], .glyph = lineGlyph(f, tok.node, tok.line).? });
        for (tok.side_flows) |point| {
            const id = f.lid_node.items[point.node];
            if (point.finished) {
                if (f.nodes.items[id].para) |paragraph| try next_cuts.append(a, .{ .node = id, .glyph = @intCast(paragraph.glyphs.len) });
            } else if (point.line != no_node.line) {
                const glyph = lineGlyph(f, point.node, point.line) orelse return extendLast(segs);
                try next_cuts.append(a, .{ .node = id, .glyph = glyph });
            }
        }
        cuts = next_cuts.items;
    }
}

/// The flex and grid containers the content from `tok` on continues in (its points' ancestors), with
/// the width their items lay out at: takumi lays a flex / grid container's items out once, so on a
/// page of another width the container's box takes that page's width while its items keep their
/// sizes and offsets (`FrozenWidth`). `prev`: the widths frame `f` was laid out with.
fn frozenWidths(a: Allocator, f: *const Frame, tok: layout.fragment.Start, prev: []const layout.fragment.FrozenWidth) Error![]const layout.fragment.FrozenWidth {
    const t = &f.tree;
    var out: std.ArrayList(layout.fragment.FrozenWidth) = .empty;
    var points: std.ArrayList(u32) = .empty;
    if (tok.node != rt.none) try points.append(a, tok.node);
    for (tok.branches) |p| try points.append(a, p.node);
    for (tok.side_flows) |p| try points.append(a, p.node);
    for (points.items) |start| {
        var n = start;
        var guard: u32 = 0;
        while (n < t.nodes.items.len and guard < layout.max_depth + 8) : (guard += 1) {
            const d = t.nodes.items[n].style.display;
            if (n != start and (d == .flex or d == .grid)) {
                const known = for (out.items) |fw| {
                    if (fw.node == n) break true;
                } else false;
                if (!known) {
                    const w = for (prev) |fw| {
                        if (fw.node == n) break fw.w;
                    } else t.layout(n).w;
                    try out.append(a, .{ .node = n, .w = w });
                }
            }
            if (n == f.lroot) break;
            n = t.nodes.items[n].parent;
        }
    }
    return out.items;
}

/// takumi lays a table cell out at its row's block size and never breaks before its block-end
/// border and padding (`should_prevent_break_before_block_end_decorations`): a cell whose content
/// ends on the page that ends at `at` (and starts at `top`) takes `max(space left, intrinsic block
/// size)` of it (Blink `FinishFragmentation`), so its fragment reaches past `at` by the decorations
/// that do not fit, as do its row's fragment (its largest cell's) and the boxes around the row
/// that `at` cuts; the row consumes that much more of its block size, the rest of it starts at the
/// next page all the same. Fills `out` with those fragments, the outermost box first and the cells
/// last (their paint order), and returns how much less of the row's block size is left past `at`
/// (0: nothing reaches past it, `out` unchanged): the row's fragment on the last page it reaches
/// (`pages`: the frame's) still holds its finished cells' block-end decorations (a finished cell's
/// fragment is at least as tall as them, and the row grows to it). Not for a row that ends there,
/// a collapsed-border table (the table draws its cells' borders) or a cell laid out as one text leaf.
fn cellOverflow(a: Allocator, f: *const Frame, pages: []const layout.fragment.Page, row: u32, top: f32, at: f32, out: *std.ArrayList(layout.fragment.Extend)) Error!f32 {
    const t = &f.tree;
    const eps = 1.0 / 64.0;
    const depth = layout.max_depth + 8;
    var anc = t.nodes.items[row].parent;
    var guard: u32 = 0;
    while (anc < t.nodes.items.len and guard < depth) : (guard += 1) {
        if (t.tableGeom(anc)) |tg| {
            if (tg.collapse) return 0;
            break;
        }
        if (anc == f.lroot) break;
        anc = t.nodes.items[anc].parent;
    }
    const row_top = absTop(f, row);
    var cells: std.ArrayList(layout.fragment.Extend) = .empty;
    var over: f32 = 0;
    var tail: f32 = 0;
    var c = t.nodes.items[row].first_child;
    while (c != rt.none) : (c = t.nodes.items[c].next_sibling) {
        const s = t.nodes.items[c].style;
        if (s.display == .none or s.position.isOut()) continue;
        if (t.nodes.items[c].measured) continue;
        const cl = t.layout(c);
        const cell_top = row_top + cl.y;
        // (a cell is a formatting context: its content's block-end margins stay in it)
        var content_end = cell_top + cl.border.top + cl.padding.top;
        var k = t.nodes.items[c].first_child;
        while (k != rt.none) : (k = t.nodes.items[k].next_sibling) {
            const ks = t.nodes.items[k].style;
            if (ks.display == .none or ks.position.isOut()) continue;
            const kl = t.layout(k);
            content_end = @max(content_end, cell_top + kl.y + kl.h + kl.margin.bottom);
        }
        // (content broken inside: the block-end decorations go with its rest)
        if (content_end > at + eps) continue;
        tail = @max(tail, cl.border.bottom + cl.padding.bottom);
        const reach = @min(@max(content_end, top) + cl.border.bottom + cl.padding.bottom, cell_top + cl.h);
        if (!(reach > at + eps)) continue;
        try cells.append(a, .{ .node = c, .at = at, .bottom = reach });
        over = @max(over, reach - at);
    }
    const row_bottom = row_top + t.layout(row).h;
    if (over == 0 or !(row_bottom > at + over + eps)) return 0;
    var bottom = row_bottom - over;
    var last_top = at;
    for (pages) |p| if (p.top > last_top and p.top < bottom - eps) {
        last_top = p.top;
    };
    bottom = @min(row_bottom, @max(bottom, last_top + tail));
    const mark = out.items.len;
    var n = row;
    guard = 0;
    while (n < t.nodes.items.len and guard < depth) : (guard += 1) {
        const nt = absTop(f, n);
        if (nt < at and nt + t.layout(n).h > at) try out.append(a, .{ .node = n, .at = at, .bottom = at + over });
        if (n == f.lroot) break;
        n = t.nodes.items[n].parent;
    }
    std.mem.reverse(layout.fragment.Extend, out.items[mark..]);
    try out.appendSlice(a, cells.items);
    return row_bottom - bottom;
}

/// Block offset of layout node `n`'s border box in the frame's stitched space.
fn absTop(f: *const Frame, n: u32) f32 {
    var y: f32 = 0;
    var cur = n;
    var guard: u32 = 0;
    while (cur < f.tree.nodes.items.len and guard < layout.max_depth + 8) : (guard += 1) {
        y += f.tree.layout(cur).y;
        if (cur == f.lroot) break;
        cur = f.tree.nodes.items[cur].parent;
    }
    return y;
}

fn sameStart(a: layout.fragment.Start, b: layout.fragment.Start) bool {
    if (a.side_flows.len != b.side_flows.len) return false;
    for (a.side_flows, b.side_flows) |x, y| if (!std.meta.eql(x, y)) return false;
    if (a.node == b.node and a.line == b.line and a.forced == b.forced and a.branches.len == b.branches.len) {
        for (a.branches, b.branches) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }
    // (parallel flows of which all but some ended resume where those go on: a band whose other
    // items a new width ended earlier is the same start as its one flow still going)
    if (a.branches.len == 0 and b.branches.len == 0) return false;
    return samePoints(a, b) and samePoints(b, a);
}

/// Every flow `a` resumes (its unfinished branches, or its one point) resumes in `b` at the same place.
fn samePoints(a: layout.fragment.Start, b: layout.fragment.Start) bool {
    const one = [_]layout.fragment.ResumePoint{.{ .node = a.node, .line = a.line, .forced = a.forced }};
    const pa: []const layout.fragment.ResumePoint = if (a.branches.len > 0) a.branches else if (a.node != rt.none) &one else &.{};
    const one_b = [_]layout.fragment.ResumePoint{.{ .node = b.node, .line = b.line, .forced = b.forced }};
    const pb: []const layout.fragment.ResumePoint = if (b.branches.len > 0) b.branches else if (b.node != rt.none) &one_b else &.{};
    for (pa) |x| {
        if (x.finished) continue;
        const found = for (pb) |y| {
            if (!y.finished and y.node == x.node and y.line == x.line and y.forced == x.forced) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

const max_pages = 20_000;
/// takumi-pdf `PdfError::TooManyPages`
const too_many_pages = "The content spans more than 20000 pages. Give it a height that resolves.";

/// The frame of the last run shows the rest of the document (a run that could not be laid out
/// again at its width).
fn extendLast(segs: *std.ArrayList(Seg)) void {
    const last = &segs.items[segs.items.len - 1];
    const pages = last.frame.paginated().?;
    last.count = @intCast(pages.pages.len - last.local0);
}

/// Two frames of the same document with the same render and layout nodes.
fn sameNodes(x: *const Frame, y: *const Frame) bool {
    return x.nodes.items.len == y.nodes.items.len and x.tree.nodes.items.len == y.tree.nodes.items.len and x.dom.els.items.len == y.dom.els.items.len;
}

/// The paragraph glyph line `line` of layout node `lid` starts at (null: the first line or none).
fn lineGlyph(f: *const Frame, lid: u32, line: u32) ?u32 {
    if (line == 0 or lid >= f.lid_node.items.len) return null;
    const id = f.lid_node.items[lid];
    if (id >= f.nodes.items.len) return null;
    const tl = f.nodes.items[id].tl orelse return null;
    if (line >= tl.lines.len) return null;
    const gl = tl.lines[line].start;
    return if (gl == 0) null else gl;
}

/// The line of render node `id`'s paragraph that starts at glyph `glyph`.
fn lineStarting(f: *Frame, id: u32, glyph: u32) ?u32 {
    if (id >= f.nodes.items.len) return null;
    const n = &f.nodes.items[id];
    if (n.para == null or n.lid == rt.none) return null;
    const l = f.tree.layout(n.lid);
    const cw = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
    const tl = (f.textLayout(id, cw) catch return null) orelse return null;
    for (tl.lines, 0..) |ln, k| if (ln.start == glyph) return @intCast(k);
    return null;
}

/// takumi `Counted::settle`: lays the content out until the numbers its hooks receive stop moving.
/// A pass that is laid out again is released first (one layout in memory at a time).
fn settle(cx: *const Ctx, geo: *const Geo) Error!Pass {
    const a = cx.doc.a;
    const r = cx.doc.r;
    var pass = try layPass(cx, geo, &.{}, &.{});
    if (pass.hooks.len == 0) return pass;
    // (`pass` holds an arena)
    var live = true;
    errdefer if (live) pass.release(r);
    // the first pass was laid out with every hook as written
    const as_written = try a.alloc(?[]const u8, pass.hooks.len);
    @memset(as_written, null);
    var used: []const ?[]const u8 = as_written;
    var k: usize = 0;
    while (k < counter_passes) : (k += 1) {
        if (k > 0) {
            const fixed_hooks = try a.dupe(bool, pass.fixed_hooks);
            pass.release(r);
            live = false;
            pass = try layPass(cx, geo, used, fixed_hooks);
            live = true;
        }
        const texts = try counters.flowTexts(a, pass.segs, pass.hooks, pass.fixed_hooks, pass.mask);
        // the pass was laid out with the numbers it gives
        if (counters.sameTexts(texts, used)) return pass;
        used = texts;
    }
    // still moving after the last pass allowed: laid out once more, so the pages show the numbers
    // they were laid out with
    const fixed_hooks = try a.dupe(bool, pass.fixed_hooks);
    pass.release(r);
    live = false;
    return layPass(cx, geo, used, fixed_hooks);
}

fn invalidPage(r: *rt.Renderer) Error {
    r.setErr("Page size must be finite and larger than zero", "");
    return error.Invalid;
}

fn same(x: ?f32, y: ?f32) bool {
    if (x == null or y == null) return x == null and y == null;
    return x.? == y.?;
}

fn heights(s: ?bands.Slot) ?f32 {
    return if (s) |x| x.height else null;
}

/// The options' page with the document's `@page` rules applied (page_rules.zig), `cx` the root
/// element's context.
pub fn pageRules(a: Allocator, o: opt.PdfOptions, kind: rt.SourceKind, source: []const u8, p: opt.Page, cx: page_rules.Context) Error!page_rules.Pages {
    var c = cx;
    c.supports = rt.Frame.cssSupports;
    return page_rules.resolve(a, p, o.css, if (kind == .html) source else null, c);
}

/// takumi `PageContext`: what the page rules take from the root element of a laid-out frame.
pub fn rootContext(f: *const Frame) page_rules.Context {
    // (takumi's tree root of a whole HTML document is its body; several top-level nodes of a
    // fragment sit in a wrapper whose custom properties takumi does not read)
    var id = f.root;
    var props = true;
    const el = f.nodes.items[id].el;
    if (el != rt.none) {
        const tag = f.dom.at(el).tag;
        if (std.ascii.eqlIgnoreCase(tag, "html")) {
            for (f.nodes.items, 0..) |n, k| {
                if (n.parent == f.root and n.el != rt.none and std.ascii.eqlIgnoreCase(f.dom.at(n.el).tag, "body")) {
                    id = @intCast(k);
                    break;
                }
            }
        } else if (tag.len == 0) props = false;
    }
    return contextOf(f.r, f.nodes.items[id].cs, f.nodes.items[f.root].cs, props);
}

/// The page rules' context of a root whose style is `cs` (the root element's: `root_cs`); `props`:
/// its custom properties are read.
fn contextOf(r: *rt.Renderer, cs: *const style.ComputedStyle, root_cs: *const style.ComputedStyle, props: bool) page_rules.Context {
    var ex: f32 = 0.5;
    var ch: f32 = 0.5;
    var font_ids: [64]@import("../font/collection.zig").FaceId = undefined;
    const matched = r.fonts.match(cs.font_family, cs.font_weight, cs.font_style != .normal, &font_ids);
    if (matched.len > 0) {
        const face = r.fonts.font(matched[0]);
        const upem = @max(face.unitsPerEm(), 1);
        const xh = face.xHeight();
        if (xh > 0) ex = @as(f32, @floatFromInt(xh)) / @as(f32, @floatFromInt(upem));
        ch = @as(f32, @floatFromInt(face.advanceWidth(face.glyphIndex('0')))) / @as(f32, @floatFromInt(upem));
    }
    const Get = struct {
        fn custom(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
            const c: *const style.ComputedStyle = @ptrCast(@alignCast(ctx));
            return c.customProperty(name);
        }
    };
    return .{ .rtl = cs.direction == .rtl, .font_size = cs.font_size, .rem = root_cs.font_size, .ex = ex, .ch = ch, .ctx = @ptrCast(cs), .custom = if (props) Get.custom else null };
}

/// Lays the paged document `o_in` (geometry `p_in`) out: `@page` rules, bands, margins, the content
/// with its counters settled, and the kept pages. Page rules that depend on the root element (its
/// direction, font size, custom properties) are resolved again from the laid-out root, and the
/// document laid out again when that changes them.
pub fn layOut(r: *rt.Renderer, a: Allocator, o_in: opt.PdfOptions, css: ?json.Value, kind: rt.SourceKind, source: []const u8, p_in: opt.Page, background: ?style.Color) Error!Document {
    const rules = try pageRules(a, o_in, kind, source, p_in, .{});
    const doc = try layOutRules(r, a, o_in, css, kind, source, rules, background);
    if (!rules.contextual) return doc;
    const again = pageRules(a, o_in, kind, source, p_in, rootContext(doc.frame)) catch |e| {
        doc.release(r);
        return e;
    };
    if (std.meta.eql(again.first, rules.first) and std.meta.eql(again.left, rules.left) and std.meta.eql(again.right, rules.right) and again.rtl == rules.rtl) return doc;
    // (the first layout lives as long as the second: the rules may refer to its root)
    errdefer doc.release(r);
    var second = try layOutRules(r, a, o_in, css, kind, source, again, background);
    second.prev = doc.mem;
    return second;
}

fn layOutRules(r: *rt.Renderer, a: Allocator, o_in: opt.PdfOptions, css: ?json.Value, kind: rt.SourceKind, source: []const u8, rules: page_rules.Pages, background: ?style.Color) Error!Document {
    var o = o_in;
    o.geometry = .{ .page = rules.rest };
    const cx: Ctx = .{ .doc = .{ .r = r, .a = a, .o = o, .css = css }, .kind = kind, .source = source };
    var header = try bands.Slot.init(a, o, true);
    var footer = try bands.Slot.init(a, o, false);
    // Bands lay out at full page width and draw inside the margin areas, like Chromium's print
    // header and footer templates; measured first with a one-page document's counters.
    if (header) |*s| try bands.measure(&cx.doc, s, 1);
    if (footer) |*s| try bands.measure(&cx.doc, s, 1);
    var geo = try Geo.resolve(r, a, rules, heights(header), heights(footer));
    var content = try settle(&cx, &geo);
    // (`content` holds an arena: the document's, or released when the content is laid out again)
    var live = true;
    errdefer if (live) content.release(r);

    // A counter band and the page count depend on each other, so the band is measured again until
    // its height settles; only a margin that follows a band can move the content.
    const dynamic = (if (header) |s| s.dynamic else false) or (if (footer) |s| s.dynamic else false);
    if (dynamic) {
        var follows = rules.first.margin.followBands() or rules.left.margin.followBands() or rules.right.margin.followBands();
        for (rules.named) |e| follows = follows or e.first.margin.followBands() or e.left.margin.followBands() or e.right.margin.followBands();
        var k: usize = 0;
        while (k < band_passes) : (k += 1) {
            const before = .{ heights(header), heights(footer) };
            const n = content.pageCount();
            if (header) |*s| try bands.measure(&cx.doc, s, n);
            if (footer) |*s| try bands.measure(&cx.doc, s, n);
            if (same(before[0], heights(header)) and same(before[1], heights(footer))) break;
            const geo2 = try Geo.resolve(r, a, rules, heights(header), heights(footer));
            if (geo.sameMargins(&geo2)) break;
            if (!follows) break;
            geo = geo2;
            content.release(r);
            live = false;
            content = try settle(&cx, &geo);
            live = true;
        }
    }

    const n = content.pageCount();
    geo.names = content.frame.tree.paged.page_names;
    // fixed boxes holding a page counter lay out again per page (takumi `FixedTemplate`)
    var fixed_counters = false;
    for (content.hooks, content.fixed_hooks) |h, fx| {
        if (fx and h.kind != .target) fixed_counters = true;
    }
    memtrace.mark("paged: content settled");
    var sel = opt.PageSelection.init(o.page_ranges);
    // (the bands of a single page are laid out when it is drawn, from this copy)
    const band_doc = try a.create(bands.Doc);
    band_doc.* = cx.doc;
    var pages: std.ArrayList(emit.PageBox) = .empty;
    var windows: std.ArrayList(emit.Window) = .empty;
    var i: usize = 0;
    var seg_i: usize = 0;
    while (i < n) : (i += 1) {
        const kept = try sel.pushPage(a);
        if (kept == null) continue;
        // (the run of pages laid out at this page's width, and this page in its frame)
        while (seg_i + 1 < content.segs.len and i >= content.segs[seg_i + 1].first) seg_i += 1;
        const sg = content.segs[seg_i];
        const paged = sg.frame.paginated().?;
        const local: usize = sg.local0 + (i - sg.first);
        const pg = paged.pages[local];
        const name = geo.nameOf(if (local < paged.names.len) paged.names[local] else 0);
        const pp = geo.page(i, name);
        const m = geo.margins(i, name);
        const area = geo.area(i, name);
        var box: emit.PageBox = .{
            .width = pp.width,
            .height = pp.height,
            .content = .{ .x = m.left, .y = m.top, .w = area[0], .h = area[1] },
            .background = background,
            .clip = true,
            .repeats = paged.repeatsOf(@intCast(local)),
            .fixed = content.fixed,
            .frame = if (seg_i > 0) sg.frame else null,
        };
        if (content.segs.len > 1) {
            // (the frame's own neighbouring pages, where the document's show another frame)
            const own = struct {
                fn win(p: layout.fragment.Page) emit.Window {
                    return .{ .top = p.top, .bottom = p.top + p.height, .lines_top = p.top, .lines_bottom = p.top + p.height };
                }
            };
            if (i == sg.first and local > 0) box.prev_win = own.win(paged.pages[local - 1]);
            if (i + 1 == sg.first + sg.count and seg_i + 1 < content.segs.len and local + 1 < paged.pages.len) box.next_win = own.win(paged.pages[local + 1]);
            // (fragments of the page before, laid out in the run before, that reach this page)
            if (i + 1 == sg.first + sg.count and seg_i + 1 < content.segs.len) box.extends = sg.extends;
            // (the next run's first page, in the same block coordinates: what reaches up here)
            if (i + 1 == sg.first + sg.count and seg_i + 1 < content.segs.len) {
                const nx = content.segs[seg_i + 1];
                const nx_pages = nx.frame.paginated().?;
                if (nx.first == i + 1 and nx.local0 < nx_pages.pages.len) {
                    box.under_frame = nx.frame;
                    box.under_win = own.win(nx_pages.pages[nx.local0]);
                }
            }
            if (i == sg.first and seg_i > 0) {
                const pv = content.segs[seg_i - 1];
                const pv_pages = pv.frame.paginated().?;
                if (pv.extends.len > 0 and pv.first + pv.count == i and pv.local0 + pv.count >= 1 and pv.local0 + pv.count - 1 < pv_pages.pages.len) {
                    box.over_frame = pv.frame;
                    box.over_extends = pv.extends;
                    box.over_win = own.win(pv_pages.pages[pv.local0 + pv.count - 1]);
                }
            }
        }
        if (header) |*s| box.header = try bands.forPage(band_doc, s, i, n, pp.width, pp.height);
        if (footer) |*s| box.footer = try bands.forPage(band_doc, s, i, n, pp.width, pp.height);
        if (fixed_counters) {
            var subst: counters.Subst = .{ .a = a, .mode = .{ .flow = .{ .texts = content.texts, .fixed = content.fixed_hooks, .page = i + 1, .pages = n } } };
            const ff = try bands.buildFrame(r, a, o, css, kind, source, null, .{ area[0], geo.area(0, null)[1] }, &subst);
            box.fixed = try emit.repeatingFixed(a, ff);
            box.fixed_frame = ff;
        }
        try pages.append(a, box);
        // takumi `PageSlice::lines`: the first page also owns the lines above it, the last the
        // lines below it
        try windows.append(a, .{
            .top = pg.top,
            .bottom = pg.top + pg.height,
            .lines_top = if (i == 0) -std.math.inf(f32) else pg.top,
            .lines_bottom = if (i + 1 == n) std.math.inf(f32) else pg.top + pg.height,
        });
    }
    var diag: opt.Diag = .{};
    sel.finish(&diag) catch {
        r.setErr(diag.message(), "");
        return error.Invalid;
    };
    return .{ .frame = content.frame, .pages = pages.items, .windows = windows.items, .count = n, .mem = content.mem };
}

/// The page area heights of a part of the document (chunks.zig) whose first page is page `base`.
const PartHeights = struct {
    g: *const Geo,
    /// the document page index of the frame's page 0 (may be before the document's first page:
    /// the part before's pages, laid out with this one, are not drawn)
    base: i64,

    fn height(ctx: *anyopaque, i: u32, name: u32) f32 {
        const c: *const PartHeights = @ptrCast(@alignCast(ctx));
        const gi: usize = @intCast(@max(0, c.base + @as(i64, i)));
        return c.g.area(gi, c.g.nameOf(name))[1];
    }
};

/// A part of the document laid out (chunks.zig): its frame and the frame's pages that are the
/// part's, [`s`, `e`) (the pages before / after hold the children of the parts around it).
const LaidPart = struct {
    f: *Frame,
    s: u32,
    e: u32,
    /// the render node of the flow (`tags.Skip.parent`)
    flow: u32,
};

/// The top of source element `el`'s box in frame `f` (laid out and paginated), null: no box.
fn elementTop(f: *const Frame, el: u32) ?f32 {
    for (f.nodes.items) |n| {
        // (the element's own box: a container, or a text / image element's node)
        if (n.el != el or n.kind == .anon_text or n.kind == .anon_box or n.lid == rt.none) continue;
        var y = f.tree.layout(n.lid).y;
        var parent = f.tree.nodes.items[n.lid].parent;
        var guard: u32 = 0;
        while (parent < f.tree.nodes.items.len and guard < 4096) : (guard += 1) {
            y += f.tree.layout(parent).y;
            parent = f.tree.nodes.items[parent].parent;
        }
        return y;
    }
    return null;
}

fn nodeOfElement(f: *const Frame, el: u32) u32 {
    for (f.nodes.items, 0..) |n, k| if (n.el == el and n.kind == .container) return @intCast(k);
    return rt.none;
}

/// Null, after a memory checkpoint naming why the document is not drawn a part at a time.
fn refuse(comptime T: type, comptime why: []const u8) ?T {
    memtrace.mark("chunks: whole: " ++ why);
    return null;
}

/// `rootContext` read from a document's element model and styles (`bands.buildDocument`), as the
/// root render node and its `body` child carry them.
fn docRootContext(doc: *const Frame) page_rules.Context {
    const d = &doc.dom;
    var el = d.root;
    const tag = d.at(el).tag;
    if (std.ascii.eqlIgnoreCase(tag, "html")) {
        var c = d.at(el).first;
        while (c != rt.none) : (c = d.at(c).next) {
            const ce = d.at(c);
            if (!ce.run and ce.cs.display != .none and std.ascii.eqlIgnoreCase(ce.tag, "body")) {
                el = c;
                break;
            }
        }
    }
    return contextOf(doc.r, d.at(el).cs, d.at(d.root).cs, tag.len > 0);
}

/// How far below a page's top a box may be computed and still start that page (`layPart`).
const seam_eps: f32 = 1.0 / 16.0;

/// Where the part before's last child, the first child a part's frame lays out, is in the
/// document: its top, and the document page it starts on (index and top).
const Seam = struct { y: f32, page: usize, top: f32 };

/// Part `k` of `doc`'s document laid out in `a` and paginated, its pages and boxes where the whole
/// document has them: the frame's first child (the part before's last one) at `seam`. Null: its
/// pages cannot be told apart from its neighbours'.
fn layPart(a: Allocator, doc: *const Frame, plan: chunks.Plan, k: usize, geo: *const Geo, seam: ?Seam, blank: bool) Error!?LaidPart {
    const pt = plan.parts[k];
    const f = try a.create(Frame);
    f.* = try Frame.initChunk(doc, a);
    f.tree.paged.chunk = .{ .parent = plan.parent, .lo = pt.lo, .hi = pt.hi };
    try f.prepareLayout();
    try @import("text.zig").requireFont(f, blank);
    var base: i64 = 0;
    var origin: f32 = 0;
    var shift: f32 = 0;
    if (seam) |sm| {
        const y0 = elementTop(f, pt.prev) orelse return refuse(LaidPart, "no seam box");
        base = @intCast(sm.page);
        origin = sm.top;
        shift = sm.y - y0;
    }
    const hc = try a.create(PartHeights);
    hc.* = .{ .g = geo, .base = base };
    const first_h = geo.area(@intCast(base), null)[1];
    const pages = try f.paginate(.{ .page_height = first_h, .page_height_fn = if (geo.uniformHeight()) null else PartHeights.height, .ctx = @ptrCast(hc), .origin = origin, .root_shift = shift });
    f.tree.dropCaches();
    // the part's pages: from the page its first child starts on to the page the next part's
    // first child starts on
    var s: u32 = 0;
    // (a box a forced break starts a page with sits at the page's top, give or take the rounding
    // of the sums that place it)
    if (pt.prev != rt.none) s = pages.pageAt((elementTop(f, pt.own_lo) orelse return refuse(LaidPart, "no first box")) + seam_eps);
    var e: u32 = @intCast(pages.pages.len);
    if (pt.next != rt.none) e = pages.pageAt((elementTop(f, pt.next) orelse return refuse(LaidPart, "no next box")) + seam_eps);
    if (pt.prev != rt.none and s == 0) return refuse(LaidPart, "part starts on the seam's page");
    if (!(s < e)) return refuse(LaidPart, "part has no page");
    const flow = nodeOfElement(f, plan.parent);
    if (flow == rt.none) return refuse(LaidPart, "no flow box");
    // What the part paints stays on its pages, but for its first child (laid out by the part
    // before too) above them and its last child (by the part after) below them: an offset,
    // transform, shadow or outline reaching further paints where only the whole document has it.
    if (pt.prev != rt.none or pt.next != rt.none) {
        const ex = try emit.Extents.compute(a, f);
        const lo = if (pt.prev != rt.none) pages.pages[s].top - seam_eps else -std.math.inf(f32);
        const hi = if (pt.next != rt.none) pages.pages[e].top + seam_eps else std.math.inf(f32);
        var c = f.nodes.items[flow].first_child;
        while (c != rt.none) : (c = f.nodes.items[c].next) {
            const el = f.nodes.items[c].el;
            if (el != rt.none and (el < pt.own_lo or el >= pt.own_hi)) continue;
            if (el != pt.own_lo and ex.lo[c] < lo) return refuse(LaidPart, "a box paints onto the part before");
            if (el != pt.last and ex.hi[c] > hi) return refuse(LaidPart, "a box paints onto the part after");
        }
        // (the neighbours' children this frame lays out paint here, on this part's pages only: the
        // part before's last child past them, the part after's first child before them, would
        // reach a part whose frame does not lay it out)
        c = f.nodes.items[flow].first_child;
        while (c != rt.none) : (c = f.nodes.items[c].next) {
            const el = f.nodes.items[c].el;
            if (el == rt.none) continue;
            if (pt.prev != rt.none and el == pt.prev and ex.hi[c] > hi) return refuse(LaidPart, "the part before paints past this part");
            if (pt.next != rt.none and el == pt.next and ex.lo[c] < lo) return refuse(LaidPart, "the part after paints before this part");
        }
    }
    // (the part starts on the page after the seam's: where the document has it)
    if (seam != null and base + s < 1) return refuse(LaidPart, "part before page 1");
    return .{ .f = f, .s = s, .e = e, .flow = flow };
}

/// Where the next part's frame starts: part `k`'s last child (laid out as `lp`, whose page `s` is
/// document page `first`).
fn seamAfter(lp: LaidPart, plan: chunks.Plan, k: usize, first: usize) ?Seam {
    if (k + 1 >= plan.parts.len) return null;
    const y = elementTop(lp.f, plan.parts[k + 1].prev) orelse return refuse(Seam, "no last box");
    const pages = lp.f.paginated().?;
    const at = pages.pageAt(y);
    if (at < lp.s or at >= lp.e) return refuse(Seam, "last box outside the part");
    return .{ .y = y, .page = first + (at - lp.s), .top = pages.pages[at].top };
}

/// The page count of `doc`'s document laid out a part at a time (each part released at once).
/// Null: the parts cannot be laid out apart.
fn countParts(r: *rt.Renderer, doc: *const Frame, plan: chunks.Plan, geo: *const Geo, blank: bool) Error!?usize {
    var n: usize = 0;
    var seam: ?Seam = null;
    for (0..plan.parts.len) |k| {
        const mem = try newMem(r);
        defer freeMem(r, mem);
        const lp = try layPart(mem.allocator(), doc, plan, k, geo, seam, blank) orelse return null;
        if (seam) |sm| if (sm.page + lp.s != n) return refuse(usize, "pages moved at a seam");
        if (k + 1 < plan.parts.len) seam = seamAfter(lp, plan, k, n) orelse return null;
        n += lp.e - lp.s;
    }
    return n;
}

/// (no node / no line: `layout.fragment.Start`)
const no_start = layout.fragment.Start{};

/// The source elements a part of a flowing document lays out at least (`chunks.Flow`): a quarter
/// of the forced-break parts' (`PdfOptions.chunk_elements`), as a part lays out its last pages
/// again with the next.
fn flowBudget(o: opt.PdfOptions) u32 {
    return @max(1, o.chunk_elements / 4);
}

/// A render node of one frame named so that another frame of the same document finds it
/// (`tags.Carry`): the nearest node at or above it with an element (that element, its kind) and
/// the child indices down from there.
const NodeKey = struct {
    el: u32,
    kind: rt.Kind,
    path: []const u32,

    fn of(a: Allocator, f: *const Frame, id: u32) Error!?NodeKey {
        var path: std.ArrayList(u32) = .empty;
        var cur = id;
        var guard: u32 = 0;
        while (f.nodes.items[cur].el == rt.none) : (guard += 1) {
            const parent = f.nodes.items[cur].parent;
            if (parent == rt.none or guard > 4096) return null;
            var idx: u32 = 0;
            var sib = f.nodes.items[parent].first_child;
            while (sib != rt.none and sib != cur) : (sib = f.nodes.items[sib].next) idx += 1;
            try path.insert(a, 0, idx);
            cur = parent;
        }
        return .{ .el = f.nodes.items[cur].el, .kind = f.nodes.items[cur].kind, .path = path.items };
    }

    fn find(k: NodeKey, f: *const Frame) ?u32 {
        var node = for (f.nodes.items, 0..) |n, i| {
            if (n.el == k.el and n.kind == k.kind) break @as(u32, @intCast(i));
        } else return null;
        for (k.path) |idx| {
            var sib = f.nodes.items[node].first_child;
            var i: u32 = 0;
            while (sib != rt.none and i < idx) : (i += 1) sib = f.nodes.items[sib].next;
            if (sib == rt.none) return null;
            node = sib;
        }
        return node;
    }
};

/// Where the next part of a flowing document (`chunks.Flow`) starts: the page break before
/// `node`'s box or line `line` of its paragraph (a `layout.fragment.Start` of the part before's
/// frame, named for the next frame), page `page` of the document at block offset `top`, laid out
/// from the flow's child `kid`, whose box starts at `y_kid`.
const Resume = struct {
    kid: usize,
    node: NodeKey,
    line: u32,
    forced: bool,
    /// the glyph line `line` starts at (the next frame must break the paragraph there too)
    glyph: u32,
    top: f32,
    /// the tops of the pages before and after it (the part before lays them out too)
    before: f32,
    after: f32,
    y_kid: f32,
    page: usize,
};

/// A part of a flowing document laid out: its frame, whose pages [`s`, `e`) are the document's
/// pages `first`.. (`s` = 1 past the first part: page 0 holds what the parts before show), the
/// render node of the flow, the flow's children it starts with (`kid0`) and hands on from
/// (`cut`: the child the next part starts in; none for the last part).
const FlowPart = struct {
    f: *Frame,
    s: u32,
    e: u32,
    first: usize,
    flow: u32,
    kid0: usize,
    cut: ?usize,
};

/// Lays a flowing document out a part at a time (`next`), each part in an arena of its own,
/// released when the next one is laid out (or on `deinit`). A part's frame lays out the flow's
/// children from the one holding its first page's start up to at least `budget` source elements
/// further (more when no page boundary of those can be cut at), and gives up all but its last
/// pages: the page it stops at is where the next part starts. The pages it keeps are those of the
/// whole document laid out at once: the content before its first page only moves the boxes, which
/// the part lays out where the document has them (`Options.root_shift`, `Options.start` /
/// `start_top`), and what follows its last kept page is laid out with it, at least a page and a
/// child of the flow past it.
const FlowIter = struct {
    r: *rt.Renderer,
    /// (what lives from one part to the next: the resume points)
    keep: Allocator,
    doc: *const Frame,
    fl: chunks.Flow,
    geo: *const Geo,
    blank: bool,
    budget: u32,
    kid0: usize = 0,
    res: ?Resume = null,
    page: usize = 0,
    done: bool = false,
    mem: ?*bump.Bump = null,

    fn deinit(it: *FlowIter) void {
        if (it.mem) |m| freeMem(it.r, m);
        it.mem = null;
    }

    /// The next part (null: the document cannot be drawn a part at a time).
    fn next(it: *FlowIter) Error!?FlowPart {
        std.debug.assert(!it.done);
        const kids = it.fl.kids;
        var budget = it.budget;
        var min_j = it.kid0 + 3;
        while (true) {
            it.deinit();
            var j = it.kid0 + 1;
            while (j < kids.len and (kids[j] - kids[it.kid0] < budget or j < min_j)) j += 1;
            // (a first part that would hold the whole document: laid out whole)
            if (j >= kids.len and it.res == null) return refuse(FlowPart, "no page boundary to cut at");
            const mem = try newMem(it.r);
            it.mem = mem;
            const got = try it.lay(mem.allocator(), j);
            switch (got) {
                .refuse => return null,
                .grow => {
                    // (a last part has nothing past it to cut at)
                    if (j >= kids.len) return refuse(FlowPart, "a last part without pages");
                    budget *|= 2;
                    min_j = j + 1;
                },
                .part => |p| {
                    it.page += p.e - p.s;
                    if (p.cut == null) it.done = true;
                    return p;
                },
            }
        }
    }

    const Laid = union(enum) { part: FlowPart, grow, refuse };

    fn no(comptime why: []const u8) Laid {
        memtrace.mark("chunks: whole: " ++ why);
        return .refuse;
    }

    /// Lays the flow's children [`kid0`, `j`) out from the resume point.
    fn lay(it: *FlowIter, a: Allocator, j: usize) Error!Laid {
        const fl = it.fl;
        const kids = fl.kids;
        const last = j >= kids.len;
        const f = try a.create(Frame);
        f.* = try Frame.initChunk(it.doc, a);
        f.tree.paged.chunk = .{ .parent = fl.parent, .lo = kids[it.kid0], .hi = if (last) std.math.maxInt(u32) else kids[j] };
        try f.prepareLayout();
        try @import("text.zig").requireFont(f, it.blank);
        var start: ?layout.fragment.Start = null;
        var shift: f32 = 0;
        var base: i64 = 0;
        if (it.res) |rs| {
            const y0 = elementTop(f, kids[it.kid0]) orelse return no("no box for a part's first child");
            shift = rs.y_kid - y0;
            const id = rs.node.find(f) orelse return no("no resume box");
            const lid = f.nodes.items[id].lid;
            if (lid == rt.none) return no("no resume box");
            if (rs.line != no_start.line) {
                const tl = paragraphLines(f, id) orelse return no("no resume paragraph");
                if (rs.line >= tl.lines.len or tl.lines[rs.line].start != rs.glyph) return no("the resume paragraph breaks elsewhere");
            }
            start = .{ .node = lid, .line = rs.line, .forced = rs.forced };
            base = @as(i64, @intCast(rs.page)) - 1;
        }
        const hc = try a.create(PartHeights);
        hc.* = .{ .g = it.geo, .base = base };
        const pages = try f.paginate(.{
            .page_height = it.geo.area(0, null)[1],
            .page_height_fn = if (it.geo.uniformHeight()) null else PartHeights.height,
            .ctx = @ptrCast(hc),
            .start = start,
            .start_top = if (it.res) |rs| rs.top else null,
            // (page 0, before the part's first page, is the page before it in the document)
            .origin = if (it.res) |rs| rs.before else 0,
            .root_shift = shift,
            .record_starts = true,
        });
        var s: u32 = 0;
        if (start) |st| {
            // (page 1 starts where the part before stopped, at the same offset)
            // and ends where the part before has it end (its start is recorded when the walk
            // first reaches the page, which content ending right at the start may do before the
            // main flow is there: no point, `layout.fragment.Pages.starts`)
            const rs = it.res.?;
            if (pages.start_page != 1 or pages.pages.len < 2) return no("a part does not start where the part before stopped");
            if (pages.pages[1].top != rs.top) return no("a part does not start where the part before stopped");
            if (pages.pages.len < 3) {
                // (its content ends on its first page: the document's, or too little laid out)
                if (!last) return .grow;
            } else if (@abs(pages.pages[2].top - rs.after) > 1.0 / 64.0) return no("a part's first page is not the part before's");
            const got = pages.starts[1];
            if (!(got.node == no_start.node and got.branches.len == 0 and got.side_flows.len == 0) and !sameStart(got, st)) return no("a part does not start where the part before stopped");
            s = 1;
        }
        const flow = nodeOfElement(f, fl.parent);
        if (flow == rt.none) return no("no flow box");
        var e: u32 = @intCast(pages.pages.len);
        var cut: ?usize = null;
        var next_res: ?Resume = null;
        if (!last) {
            // the last page boundary that can be cut at, a page and a child of the flow before
            // the frame's content ends
            var c: u32 = @intCast(pages.pages.len -| 2);
            while (c > s) : (c -= 1) {
                const tok = pages.starts[c];
                if (tok.node == no_start.node or tok.branches.len > 0 or tok.side_flows.len > 0) continue;
                if (tok.node >= f.lid_node.items.len) continue;
                const id = f.lid_node.items[tok.node];
                if (id == rt.none) continue;
                const ki = resumeKid(f, fl, flow, id) orelse continue;
                if (ki < it.kid0 or ki + 2 > j or !fl.cuttable[ki]) continue;
                var glyph: u32 = 0;
                if (tok.line != no_start.line) {
                    const tl = paragraphLines(f, id) orelse continue;
                    if (tok.line >= tl.lines.len) continue;
                    glyph = tl.lines[tok.line].start;
                }
                const y_kid = elementTop(f, kids[ki]) orelse continue;
                const key = try NodeKey.of(it.keep, f, id) orelse continue;
                next_res = .{ .kid = ki, .node = key, .line = tok.line, .forced = tok.forced, .glyph = glyph, .top = pages.pages[c].top, .before = pages.pages[c - 1].top, .after = pages.pages[c + 1].top, .y_kid = y_kid, .page = it.page + (c - s) };
                cut = ki;
                e = c;
                break;
            }
            if (cut == null) return .grow;
        }
        if (!(s < e)) return .grow;
        // What the part paints stays on its pages: the children of the flow before the one the
        // next part starts in paint above the page it starts with, those after the first child
        // below the part's first page (the frames around lay out neither).
        if (start != null or cut != null) {
            const ex = try emit.Extents.computeWith(a, f, false);
            const lo = if (start != null) pages.pages[s].top - seam_eps else -std.math.inf(f32);
            const hi = if (cut != null) pages.pages[e].top + seam_eps else std.math.inf(f32);
            var ch = f.nodes.items[flow].first_child;
            while (ch != rt.none) : (ch = f.nodes.items[ch].next) {
                const el = f.nodes.items[ch].el;
                const k = if (el == rt.none) null else fl.kidOf(it.doc, el);
                const ki = k orelse return no("a box of the flow that is no child of it");
                if (cut) |cu| if (ki < cu and ex.hi[ch] > hi) return no("a box paints onto the part after");
                if (start != null and ki > it.kid0 and ex.lo[ch] < lo) return no("a box paints onto the part before");
            }
        }
        f.tree.dropCaches();
        const part: FlowPart = .{ .f = f, .s = s, .e = e, .first = it.page, .flow = flow, .kid0 = it.kid0, .cut = cut };
        if (next_res) |nr| {
            it.res = nr;
            it.kid0 = nr.kid;
        }
        return .{ .part = part };
    }
};

/// An anchor (`id`) or heading (`heading`, an index) a part of a flowing document collected whose
/// element is in the child of the flow the next part starts in, or after it: its structure element
/// is that part's (`tags.Skip`), so its destination names that part's render node `node`.
const HandOn = struct { id: ?[]const u8 = null, heading: usize = 0, node: ?NodeKey };

/// Moves the anchors and headings part `chunk` (frame `f`) collected for the elements from kid
/// `cut` on to the next part (`HandOn`, in `out`).
fn handOn(a: Allocator, links: *@import("interactive.zig").Collector, f: *const Frame, fl: chunks.Flow, cut: usize, chunk: u32, out: *std.ArrayList(HandOn)) Error!void {
    out.clearRetainingCapacity();
    const S = struct {
        fn moves(fr: *const Frame, flow: chunks.Flow, k: usize, el: u32) bool {
            const ki = flow.kidOf(fr, el) orelse return false;
            return ki >= k;
        }
        fn key(al: Allocator, fr: *const Frame, node: u32) Error!?NodeKey {
            if (node == rt.none or node >= fr.nodes.items.len) return null;
            return NodeKey.of(al, fr, node);
        }
    };
    var it = links.anchors.iterator();
    while (it.next()) |en| {
        const an = en.value_ptr;
        if (an.chunk != chunk or !S.moves(f, fl, cut, an.el)) continue;
        try out.append(a, .{ .id = en.key_ptr.*, .node = try S.key(a, f, an.node) });
        an.chunk = chunk + 1;
    }
    for (links.headings.items, 0..) |*h, k| {
        if (h.chunk != chunk or !S.moves(f, fl, cut, h.el)) continue;
        try out.append(a, .{ .heading = k, .node = try S.key(a, f, h.node) });
        h.chunk = chunk + 1;
    }
}

/// Gives the anchors and headings `handOn` moved to part `chunk` the render nodes of its frame
/// `f`. False: one has no node there.
fn takeOn(links: *@import("interactive.zig").Collector, f: *const Frame, list: []const HandOn, chunk: u32) bool {
    for (list) |ho| {
        const node = if (ho.node) |k| k.find(f) orelse return false else rt.none;
        if (ho.id) |id| {
            const an = links.anchors.getPtr(id) orelse return false;
            retarget(&an.node, &an.dest, chunk, node);
        } else {
            const h = &links.headings.items[ho.heading];
            retarget(&h.node, &h.dest, chunk, node);
        }
    }
    return true;
}

/// (a destination naming the structure element of the node, `interactive.Dest.place`, names the
/// new one)
fn retarget(node: *u32, dest: anytype, to_chunk: u32, to_node: u32) void {
    if (dest.*) |*d| if (d.chunk + 1 == to_chunk and d.node == node.* and d.node != rt.none) {
        d.chunk = to_chunk;
        d.node = to_node;
    };
    node.* = to_node;
}

/// The lines of render node `id`'s paragraph as laid out in frame `f` (null: none).
fn paragraphLines(f: *Frame, id: u32) ?*const @import("../font/font.zig").TextLayout {
    const n = &f.nodes.items[id];
    if (n.tl) |tl| return tl;
    if (n.para == null or n.lid == rt.none) return null;
    const l = f.tree.layout(n.lid);
    const cw = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
    return f.textLayout(id, cw) catch null;
}

/// The child of the flow (index in `fl.kids`) holding render node `id` of frame `f`, when the
/// boxes from it up to the flow are boxes a page break can resume in: blocks, the row groups and
/// rows of a table, flex and grid containers and their items (null: an inline box, a cell, an
/// absolutely positioned box ...). A token that is one point never names a cell (a row broken
/// inside resumes its cells in parallel: `Start.branches`, which a part does not take), so a
/// table resumes between its rows; the part laying the table out from that row checks that its
/// pages start and end where the part before had them (`FlowIter.lay`).
fn resumeKid(f: *const Frame, fl: chunks.Flow, flow: u32, id: u32) ?usize {
    var cur = id;
    var guard: u32 = 0;
    while (guard < 4096) : (guard += 1) {
        const n = &f.nodes.items[cur];
        const parent = n.parent;
        if (parent == rt.none) return null;
        if (cur != id or n.kind == .container) {
            const pd = f.nodes.items[parent].cs.display;
            // (an item of a flex / grid container is blockified whatever its display)
            const item = parent != flow and switch (pd) {
                .flex, .grid => true,
                else => false,
            };
            if (!item) switch (n.cs.display) {
                .block, .flow_root, .list_item, .flex, .grid => {},
                // (a row group or a row of a table broken between its rows: the token is one
                // point, the row; a row broken inside is parallel flows, never one point)
                .table, .table_row_group, .table_header_group, .table_footer_group, .table_row => {},
                else => return null,
            };
        }
        if (n.cs.position != .static and n.cs.position != .relative) return null;
        if (parent == flow) {
            if (n.el == rt.none) return null;
            return fl.kidOf(f, n.el);
        }
        cur = parent;
    }
    return null;
}

/// The page count of a flowing document laid out a part at a time (each part released at once),
/// a memory checkpoint per page. Null: it cannot be drawn a part at a time.
fn countFlow(r: *rt.Renderer, a: Allocator, doc: *const Frame, fl: chunks.Flow, geo: *const Geo, blank: bool, budget: u32) Error!?usize {
    var it: FlowIter = .{ .r = r, .keep = a, .doc = doc, .fl = fl, .geo = geo, .blank = blank, .budget = budget };
    defer it.deinit();
    while (!it.done) {
        const p = try it.next() orelse return null;
        for (p.s..p.e) |_| memtrace.mark("count: page");
    }
    return it.page;
}

/// The paged document `o_in` (geometry `p_in`) laid out and drawn a part at a time when it can be
/// cut at forced page breaks, or else at page boundaries found as it is laid out (chunks.zig,
/// `FlowIter`): the same file as `layOut` + `emit.writeDocument`, with
/// one part's layout in memory at a time. Null: it cannot be (the caller lays it out whole).
pub fn writeChunked(r: *rt.Renderer, a: Allocator, o_in: opt.PdfOptions, css: ?json.Value, kind: rt.SourceKind, source: []const u8, p_in: opt.Page, background: ?style.Color, policy: emit.DocOptions) Error!?[]const u8 {
    if (comptime !layout.fragment.enabled) return null;
    if (!o_in.chunks) return null;
    // (cheap first: a document too short for two parts, or without any page break property, is
    // laid out whole without building it twice)
    const budget = flowBudget(o_in);
    if (source.len < @as(usize, budget) * 2 * 7 and o_in.chunk_elements > 1) return null;
    var rules = try pageRules(a, o_in, kind, source, p_in, .{});
    var o = o_in;
    o.geometry = .{ .page = rules.rest };
    var cx: Ctx = .{ .doc = .{ .r = r, .a = a, .o = o, .css = css }, .kind = kind, .source = source };
    var header = try bands.Slot.init(a, o, true);
    var footer = try bands.Slot.init(a, o, false);
    if (header) |*s| try bands.measure(&cx.doc, s, 1);
    if (footer) |*s| try bands.measure(&cx.doc, s, 1);
    var geo = try Geo.resolve(r, a, rules, heights(header), heights(footer));
    if (!geo.uniformWidth()) return refuse([]const u8, "page widths differ");
    // the document, shared by its parts; page counters in the content lay it out whole
    var subst: counters.Subst = .{ .a = a, .mode = .{ .flow = .{ .texts = &.{}, .fixed = &.{} } } };
    // (the element model and styles in memory of their own, freed once the file is written: the
    // file is in `a`)
    const dmem = try newMem(r);
    defer freeMem(r, dmem);
    const da = dmem.allocator();
    var doc = try bands.buildDocument(r, da, o, css, kind, source, geo.area(0, null), &subst);
    if (subst.hooks.items.len > 0) return refuse([]const u8, "page counters in the content");
    if (rules.contextual) {
        // page rules that read the root element (`layOut`): read again with the document's root;
        // other rules lay the document out with them
        const again = try pageRules(a, o_in, kind, source, p_in, docRootContext(doc));
        if (!(std.meta.eql(again.first, rules.first) and std.meta.eql(again.left, rules.left) and std.meta.eql(again.right, rules.right) and again.rtl == rules.rtl)) {
            rules = again;
            o.geometry = .{ .page = rules.rest };
            cx.doc.o = o;
            header = try bands.Slot.init(a, o, true);
            footer = try bands.Slot.init(a, o, false);
            if (header) |*s| try bands.measure(&cx.doc, s, 1);
            if (footer) |*s| try bands.measure(&cx.doc, s, 1);
            geo = try Geo.resolve(r, a, rules, heights(header), heights(footer));
            if (!geo.uniformWidth()) return refuse([]const u8, "page widths differ");
            subst = .{ .a = a, .mode = .{ .flow = .{ .texts = &.{}, .fixed = &.{} } } };
            doc = try bands.buildDocument(r, da, o, css, kind, source, geo.area(0, null), &subst);
            if (subst.hooks.items.len > 0) return refuse([]const u8, "page counters in the content");
        }
    }
    const cut = try chunks.plan(a, doc, o.chunk_elements) orelse return refuse([]const u8, "no cut");
    if (cut == .flowing) {
        // (a document too short for two parts is laid out whole)
        const kids = cut.flowing.kids;
        if (kids[kids.len - 1] - kids[0] < 2 * budget) return refuse([]const u8, "too short for two parts");
    }
    const names = doc.tree.paged.page_names;
    geo.names = names;
    const blank = o.uncovered_text == .blank;

    // A band that depends on the page count (its counters, or a rule for the last page) needs the
    // count first: the parts are laid out once to count their pages. A counter band is measured
    // again until its height settles, as `layOutRules` does.
    const dynamic = (if (header) |s| s.dynamic else false) or (if (footer) |s| s.dynamic else false);
    const varies = (if (header) |s| s.varies else false) or (if (footer) |s| s.varies else false);
    var n: usize = 0;
    if (dynamic or varies) {
        n = try countCut(r, a, doc, cut, &geo, blank, budget) orelse return null;
        if (dynamic) {
            var follows = rules.first.margin.followBands() or rules.left.margin.followBands() or rules.right.margin.followBands();
            for (rules.named) |e| follows = follows or e.first.margin.followBands() or e.left.margin.followBands() or e.right.margin.followBands();
            var k: usize = 0;
            while (k < band_passes) : (k += 1) {
                const before = .{ heights(header), heights(footer) };
                if (header) |*s| try bands.measure(&cx.doc, s, n);
                if (footer) |*s| try bands.measure(&cx.doc, s, n);
                if (same(before[0], heights(header)) and same(before[1], heights(footer))) break;
                var geo2 = try Geo.resolve(r, a, rules, heights(header), heights(footer));
                if (geo.sameMargins(&geo2)) break;
                if (!follows) break;
                geo2.names = names;
                geo = geo2;
                n = try countCut(r, a, doc, cut, &geo, blank, budget) orelse return null;
            }
        }
    }

    const dw = try emit.DocWriter.init(a, doc, policy);
    defer dw.deinit();
    // (the bands of a single page are laid out when it is drawn, from this copy)
    const band_doc = try a.create(bands.Doc);
    band_doc.* = cx.doc;
    var pd: PartDraw = .{ .a = a, .dw = dw, .sel = opt.PageSelection.init(o.page_ranges), .geo = &geo, .header = &header, .footer = &footer, .band_doc = band_doc, .n = n, .background = background };
    switch (cut) {
        .forced => |plan| {
            var i: usize = 0;
            var seam: ?Seam = null;
            for (0..plan.parts.len) |k| {
                memtrace.mark("part: start");
                const mem = try newMem(r);
                defer freeMem(r, mem);
                const pa = mem.allocator();
                const lp = try layPart(pa, doc, plan, k, &geo, seam, blank) orelse return null;
                if (seam) |sm| if (sm.page + lp.s != i) return refuse([]const u8, "pages moved at a seam");
                if (k + 1 < plan.parts.len) seam = seamAfter(lp, plan, k, i) orelse return null;
                memtrace.mark("part: laid out");
                if (!try pd.draw(pa, lp.f, lp.s, lp.e, i, k == 0, k + 1 == plan.parts.len)) return null;
                i += lp.e - lp.s;
                const pt = plan.parts[k];
                if (!chunks.ownsCollected(doc, plan.parent, pt, dw.links.anchors, dw.links.headings.items, dw.links.chunk)) return refuse([]const u8, "an anchor or heading outside its part");
                if (!try dw.endChunk(pa, .{ .parent = lp.flow, .lo = pt.own_lo, .hi = pt.own_hi })) return refuse([]const u8, "structure crosses a seam");
                memtrace.mark("part: drawn");
            }
        },
        .flowing => |fl| {
            var it: FlowIter = .{ .r = r, .keep = a, .doc = doc, .fl = fl, .geo = &geo, .blank = blank, .budget = budget };
            defer it.deinit();
            var moved: std.ArrayList(HandOn) = .empty;
            var k: usize = 0;
            while (!it.done) : (k += 1) {
                memtrace.mark("part: start");
                const p = try it.next() orelse return null;
                memtrace.mark("part: laid out");
                const pa = it.mem.?.allocator();
                const last_part = p.cut == null;
                if (!try pd.draw(pa, p.f, p.s, p.e, p.first, k == 0, last_part)) return null;
                // (the anchors and headings it collected: of the children of the flow from its
                // first one to the one the next part starts in, which both lay out)
                const own: chunks.Part = .{ .lo = fl.kids[p.kid0], .hi = 0, .own_lo = fl.kids[p.kid0], .own_hi = if (p.cut) |c| fl.kids[c] + 1 else std.math.maxInt(u32) };
                if (!chunks.ownsCollected(doc, fl.parent, own, dw.links.anchors, dw.links.headings.items, dw.links.chunk)) return refuse([]const u8, "an anchor or heading outside its part");
                // (the structure recorded for the child the next part starts in, and those after
                // it, goes to the next part, and with it the elements destinations name)
                if (!takeOn(&dw.links, p.f, moved.items, dw.links.chunk)) return refuse([]const u8, "a destination has no box");
                if (p.cut) |c| try handOn(a, &dw.links, p.f, fl, c, dw.links.chunk, &moved);
                const hi = if (p.cut) |c| fl.kids[c] else std.math.maxInt(u32);
                if (!try dw.endChunk(pa, .{ .parent = p.flow, .lo = fl.kids[p.kid0], .hi = hi })) return refuse([]const u8, "structure crosses a seam");
                memtrace.mark("part: drawn");
            }
        },
    }
    var diag: opt.Diag = .{};
    pd.sel.finish(&diag) catch {
        r.setErr(diag.message(), "");
        return error.Invalid;
    };
    return try dw.finish();
}

/// The page count of `doc`'s document laid out a part at a time. Null: it cannot be.
fn countCut(r: *rt.Renderer, a: Allocator, doc: *const Frame, cut: chunks.Cut, geo: *const Geo, blank: bool, budget: u32) Error!?usize {
    return switch (cut) {
        .forced => |plan| countParts(r, doc, plan, geo, blank),
        .flowing => |fl| countFlow(r, a, doc, fl, geo, blank, budget),
    };
}

/// Draws the pages of the parts of a document laid out a part at a time (`writeChunked`).
const PartDraw = struct {
    a: Allocator,
    dw: *emit.DocWriter,
    sel: opt.PageSelection,
    geo: *const Geo,
    header: *?bands.Slot,
    footer: *?bands.Slot,
    band_doc: *bands.Doc,
    /// the document's page count (0: no band needs it)
    n: usize,
    background: ?style.Color,

    fn win(p: layout.fragment.Page) emit.Window {
        return .{ .top = p.top, .bottom = p.top + p.height, .lines_top = p.top, .lines_bottom = p.top + p.height };
    }

    /// Draws pages [`s`, `e`) of part frame `f` (document pages `first`..; `pa`: the part's
    /// memory) that `pageRanges` keeps, or collects the part's anchors and headings when it keeps
    /// none. False: the parts cannot be drawn apart.
    fn draw(pd: *PartDraw, pa: Allocator, f: *Frame, s: u32, e: u32, first: usize, first_part: bool, last_part: bool) Error!bool {
        const geo = pd.geo;
        const paged = f.paginated().?;
        var boxes: std.ArrayList(emit.PageBox) = .empty;
        var windows: std.ArrayList(emit.Window) = .empty;
        var local: usize = s;
        while (local < e) : (local += 1) {
            const pg = paged.pages[local];
            const gi = first + (local - s);
            const kept = try pd.sel.pushPage(pd.a);
            if (kept == null) continue;
            const name = geo.nameOf(if (local < paged.names.len) paged.names[local] else 0);
            const pp = geo.page(gi, name);
            const m = geo.margins(gi, name);
            const area = geo.area(gi, name);
            var box: emit.PageBox = .{
                .width = pp.width,
                .height = pp.height,
                .content = .{ .x = m.left, .y = m.top, .w = area[0], .h = area[1] },
                .background = pd.background,
                .clip = true,
                .repeats = paged.repeatsOf(@intCast(local)),
                .fixed = &.{},
            };
            // (the frame's own pages around the part's take part as neighbouring passes)
            if (local == s and s > 0) box.prev_win = win(paged.pages[s - 1]);
            if (local + 1 == e and e < paged.pages.len) box.next_win = win(paged.pages[e]);
            if (pd.header.*) |*hs| box.header = try bands.forPage(pd.band_doc, hs, gi, pd.n, pp.width, pp.height);
            if (pd.footer.*) |*fs| box.footer = try bands.forPage(pd.band_doc, fs, gi, pd.n, pp.width, pp.height);
            try boxes.append(pa, box);
            // takumi `PageSlice::lines`: the first page also owns the lines above it, the last the
            // lines below it
            try windows.append(pa, .{
                .top = pg.top,
                .bottom = pg.top + pg.height,
                .lines_top = if (gi == 0) -std.math.inf(f32) else pg.top,
                .lines_bottom = if (last_part and local + 1 == e) std.math.inf(f32) else pg.top + pg.height,
            });
        }
        if (!try pd.dw.beginChunk(f)) return refuse(bool, "carried structure has no box") orelse false;
        // (the part's anchors and headings: those whose box starts between its first page's top and
        // the next part's first page's, as the whole document's first page collects them all)
        const bounds: [2]f32 = .{ if (first_part) -std.math.inf(f32) else paged.pages[s].top - seam_eps, if (last_part) std.math.inf(f32) else paged.pages[e].top - seam_eps };
        if (boxes.items.len > 0) {
            try pd.dw.drawPages(f, boxes.items, windows.items, pa, bounds);
        } else {
            // every page of the part dropped: its anchors and headings are still the document's
            const name = geo.nameOf(if (s < paged.names.len) paged.names[s] else 0);
            const pp = geo.page(first, name);
            const m = geo.margins(first, name);
            const area = geo.area(first, name);
            try pd.dw.collect(f, .{ .width = pp.width, .height = pp.height, .content = .{ .x = m.left, .y = m.top, .w = area[0], .h = area[1] }, .clip = true }, bounds);
        }
        return true;
    }
};

/// takumi `measure` with page options: the tree laid out like a band (the full page width, an
/// unbounded height) with three-digit counters (`999`), target counters empty; its own size.
pub fn measureBand(r: *rt.Renderer, a: Allocator, o_in: opt.PdfOptions, css: ?json.Value, kind: rt.SourceKind, source: []const u8) Error!*Frame {
    // (at the first page's width, as takumi's `with_page_rules(..).first()`)
    var o = o_in;
    o.geometry = .{ .page = (try pageRules(a, o_in, kind, source, o_in.geometry.page, .{})).first };
    var subst: counters.Subst = .{ .a = a, .mode = .{ .band = .{ .page = 999, .pages = 999 } } };
    return bands.buildFrame(r, a, o, css, kind, source, null, null, &subst);
}
