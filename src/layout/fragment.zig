//! Block fragmentation (pagination) for paged output: a post-layout pass over a tree that `Tree.compute`
//! laid out once at page width with an unbounded height.
//!
//! Model. The pages stack in the block direction of ONE coordinate space ("stitched" space, as takumi's
//! `PageSizes` / `PageWindows`): page `i` is the window `[pages[i].top, pages[i].top + pages[i].height)`.
//! `paginate` chooses the page breaks by Blink LayoutNG's rules and moves the content after each break
//! down to the start of the next page by rewriting `Layout.y` / `Layout.h` in place. Afterwards a page is
//! painted by painting the whole tree translated by `-pages[i].top` and clipped to the page: a box that
//! spans a page boundary is cut by the clip, which is `box-decoration-break: slice`.
//! What the boxes alone cannot say is returned in `Pages`:
//!  * `line_shifts`: the line boxes of a text node are owned by the caller; the lines from `first_line`
//!    on sit `dy` lower than in the caller's line layout (a line never splits);
//!  * `repeats`: subtrees painted again on other pages (repeated table header / footer groups,
//!    `position: fixed` boxes), translated by `dy`.
//!
//! Break decisions follow Blink's `fragmentation_utils.cc` / `block_layout_algorithm.cc` as ported by
//! takumi-core (class A / B / C break opportunities, break appeal, early breaks, forced breaks,
//! `break-inside: avoid`, `orphans` / `widows`, monolithic content, margins truncated at unforced breaks,
//! parallel flows for table cells / flex rows / grid rows / floats / overflowing content of boxes that end
//! on the page). Blink lays every page out again from a break token; here one page at a time is "probed"
//! on the finished layout (pure, no mutation: `probe`) and the break it finds is then applied (`apply`).
//! PDF pagination may rebuild the full layout when a deferred float moves or a split float gains exclusion
//! extent; this is still whole-document re-layout, not incremental per-page layout.
//!
//! Usage (see tests_fragment.zig):
//!   try t.compute(root, .{ .{ .definite = page_w }, .{ .definite = page_h } }, ctx, measure, opts);
//!   var pages = try fragment.paginate(&t, arena, root, .{ .page_height = page_h, .lines_fn = linesFn, .ctx = ctx });
//!   for (pages.pages, 0..) |pg, i| {
//!       // clip to the page, translate by -pg.top, paint the tree: text lines at their y + pages.lineDy(node, line);
//!       // then for (pages.repeatsOf(i)) |r| paint the subtree of r.node translated by a further r.dy
//!   }
//!
//! Limits of a post-layout fragmentation pass:
//!  * float placement can trigger a whole-frame retry, but split floats do not yet have a general
//!    page-local exclusion model; percentages and stretching never saw a page size; a box with a definite
//!    `height` keeps it (its content overflows, as in Blink), any other box grows by what a break pushed down;
//!  * the page inline size cannot change within one pagination (block sizes can: `Options.page_height_fn`);
//!    pages of another width are a new layout at that width, paginated from where the content continues
//!    (`Options.start`: page 0 then holds what earlier pages showed and ends exactly at the start, page 1
//!    starts with it at `Options.start_top`; `Pages.starts` says where each page's content starts; the
//!    caller, src/pdf/paged.zig, chains the layouts);
//!  * a cell that spans rows is not fragmented; anonymous table rows / cells keep their `TableGeom`;
//!    `position: relative` offsets take part in the break positions.
//! takumi-pdf 0.20.0 behaviours ported here: `box-decoration-break: clone` breaks the content above
//! the repeated block-end decorations and resumes it below the block-start ones (`clonePg`);
//! monolithic content overflowing the page carries its overflow over only through a box that ends
//! with it (`overflowStays`), and adds no page unless on the root's last page (`extentOf`); content
//! transformed past the end adds pages (`Options.extent_fn`); middle / bottom aligned cells of a
//! row the page end cuts start at their top (`cellRealign`).
const std = @import("std");
const sty = @import("style.zig");
const tr = @import("tree.zig");

const Allocator = std.mem.Allocator;
const no_node = tr.no_node;
const BB = sty.BreakBetween;

pub const enabled = sty.frag_enabled;
pub const Breaks = sty.Breaks;
pub const BreakBetween = sty.BreakBetween;

/// A line box of a text node: block offsets from the node's border-box top.
pub const LineBox = struct { top: f32, bottom: f32 };
/// The line boxes of `node` in block order, valid until the next call. Empty: the node has none (an image,
/// or inline content the caller cannot split): it is monolithic. Called for measured leaves and
/// `Display.inline_row` nodes.
pub const LinesFn = *const fn (ctx: *anyopaque, node: tr.NodeId) []const LineBox;
/// Block size of the page area of page `page` (0-based), a page named `name` (`Breaks.page` ids, 0 =
/// unnamed: the used page name of the content that starts the page, as Blink's
/// `PageNameForChildFragment`).
pub const PageHeightFn = *const fn (ctx: *anyopaque, page: u32, name: u32) f32;

pub const Options = struct {
    /// block size of the page area (inside the page margins) of every page
    page_height: f32,
    /// per-page block sizes (named pages / `@page`); overrides `page_height`. The inline size cannot vary
    /// within one pagination (see `start`).
    page_height_fn: ?PageHeightFn = null,
    lines_fn: ?LinesFn = null,
    ctx: *anyopaque = undefined,
    /// `error.TooManyPages` beyond this (takumi-pdf's MAX_PAGES)
    max_pages: u32 = 20_000,
    /// Content continued from a page of another width (src/pdf/paged.zig): page 0 holds everything
    /// before `start` and ends exactly there (it is not asked of `page_height_fn`), page 1 starts
    /// with it. Null: page 0 starts the content.
    start: ?Start = null,
    /// With `start`: the block offset page 1 starts at (the break before the start moves it there;
    /// the content moves up when it would reach past it). Null: where the start is.
    start_top: ?f32 = null,
    /// Fill `Pages.starts`.
    record_starts: bool = false,
    /// Where page 0 starts, and how far the root moves down first (a part of a document laid out on
    /// its own, src/pdf/paged.zig: its pages and boxes where the whole document has them).
    origin: f32 = 0,
    root_shift: f32 = 0,
    /// How far down the boxes paint once transformed (called with `ctx` once the breaks are applied),
    /// null when no box is transformed or relatively offset: takumi (`PagedLayout::overflow_end`,
    /// `moves_boxes`) then measures the boxes of every page, else only those of the root's last page.
    extent_fn: ?*const fn (ctx: *anyopaque) ?f32 = null,
};

/// Where a page's content starts in the main flow: before the in-flow box `node` (a forced break
/// keeps its block-start margin), or before line `line` of the text node `node`. `node == no_node`:
/// not one point (parallel flows broken inside, a box broken in its block-end space, the first
/// page, the pages below the end of the flow).
pub const ResumePoint = struct { node: u32, line: u32 = no_node, forced: bool = false, finished: bool = false };
pub const Start = struct {
    node: u32 = no_node,
    line: u32 = no_node,
    forced: bool = false,
    /// Independent flows of a table row, a flex line or a grid row (whose items keep the width of
    /// their first fragment on a page of another width: `FrozenWidth`).
    branches: []const ResumePoint = &.{},
    row_height: f32 = 0,
    /// Rowspanning cell paragraphs continue independently of the current row.
    side_flows: []const ResumePoint = &.{},
};
pub const ParagraphCut = struct { node: u32, glyph: u32 };
pub const RowMinimum = struct { node: u32, height: f32, top: ?f32 = null };
/// A flex or grid container continued on a page of another width keeps laying its items out at the
/// border-box width `w` of its first fragment (takumi: the container's box takes the page's width,
/// its items keep the sizes and offsets the flex / grid algorithm gave them).
pub const FrozenWidth = struct { node: u32, w: f32 };
/// A table stretched to its row flex line (`align-self: stretch`) whose fragments grew past the
/// line's end. Blink's flex fragmentation grows the line by what the item reaches past it, in the
/// fragment where the line ends (`row_cross_size_updates`: to the item's end when the item ends
/// there, else to the fragmentainer's end), and lays the stretched items out again at the grown
/// size; the table shares that larger block size among its rows (`DistributeTableBlockSizeToSections`,
/// proportionally to their minimum block sizes), and only the rows of that fragment and later ones
/// show it: the earlier fragments are done. Rows from table row `segs[i].row` (table.zig row order)
/// take the block sizes they get when the table box is `segs[i].size` tall; `segs[0]` is the size
/// the table was first laid out at. `line`: where the line ends, from the table's border-box
/// block start; `next_page`: the first page not looked at yet; `h0`: the table's border-box block
/// size in that first layout, which the other items of the line stretch to as before (the line
/// grows in the fragment where it ends, after they were laid out: their content stays, their boxes
/// reach its grown end; flex.zig, `applyBand`).
pub const TableStretch = struct { node: u32, line: f32, next_page: u32, h0: f32, segs: []StretchSeg };
pub const StretchSeg = struct { row: u32, size: f32 };

pub const Page = struct { top: f32, height: f32 };
/// Lines `first_line..` of `node` (up to the next entry of the same node) are painted `dy` lower.
pub const LineShift = struct { node: u32, first_line: u32, dy: f32 };
/// Paint the subtree of `node` once more on page `page`, translated by `dy` in stitched space.
pub const Repeat = struct { node: u32, page: u32, dy: f32 };

pub const BoxFragment = struct { y: f32, h: f32, from_prev: bool, to_next: bool };
/// The fragment of layout node `node` on the page that ends at stitched offset `at` reaches down
/// to `bottom` past it, its block-end edge still cut (takumi lays a table cell out without a break
/// before its block-end decorations: a cell whose content ends on the page keeps its trailing
/// border and padding in that fragment, and its row and their ancestors grow with it; src/pdf/paged.zig).
pub const Extend = struct { node: u32, at: f32, bottom: f32 };

pub const Pages = struct {
    pages: []Page = &.{},
    /// the page name of each page (`Breaks.page` ids, 0 = unnamed)
    names: []u32 = &.{},
    /// sorted by (node, first_line)
    line_shifts: []LineShift = &.{},
    /// sorted by page
    repeats: []Repeat = &.{},
    /// where each page's content starts (`Options.record_starts`; else empty)
    starts: []Start = &.{},
    /// 1 when page 0 holds the content before `Options.start` (it was found), else 0
    start_page: u32 = 0,

    pub fn deinit(p: *Pages, a: Allocator) void {
        a.free(p.pages);
        a.free(p.names);
        for (p.starts) |s| {
            a.free(s.branches);
            a.free(s.side_flows);
        }
        a.free(p.starts);
        a.free(p.line_shifts);
        a.free(p.repeats);
        p.* = .{};
    }
    /// Index of the page that holds stitched block offset `y` (the last page for anything below).
    pub fn pageAt(p: *const Pages, y: f32) u32 {
        // (binary search: the last page whose top is at or above `y`, the first page for anything
        // above it; a linear walk made per-box lookups quadratic in the page count)
        if (p.pages.len < 2) return 0;
        // A position a page's top places (a forced break moves a box there) sums offsets in a
        // different order than the page tops do, so far down a long document it can land a few
        // float steps above that top: it is on that page. Far below the LayoutUnit grid (1/64 px)
        // that layout positions keep from a page's top, so no position on the page before moves.
        const tol = @max(1.0 / 256.0, @abs(y) * (1.0 / 1048576.0));
        var lo: usize = 0;
        var hi: usize = p.pages.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (y + tol >= p.pages[mid].top) lo = mid else hi = mid - 1;
        }
        return @intCast(lo);
    }
    /// The part of a box (stitched border-box block start `top`, block size `h`) that is on page `page`:
    /// null when the page shows none of it. `y` is relative to the page start; `from_prev` / `to_next`:
    /// the box continues from the page before / onto the page after (its block-start / block-end edge
    /// is not on this page: where `box-decoration-break: slice` leaves the border out).
    pub fn boxOnPage(p: *const Pages, page: u32, top: f32, h: f32) ?BoxFragment {
        if (page >= p.pages.len) return null;
        const pg = p.pages[page];
        const last = page + 1 == p.pages.len;
        const s = @max(top, pg.top);
        const e = if (last) top + h else @min(top + h, pg.top + pg.height);
        if (h > 0) {
            if (!(e > s)) return null;
        } else if (!(top >= pg.top and (last or top < pg.top + pg.height))) return null;
        return .{ .y = s - pg.top, .h = @max(e - s, 0), .from_prev = top < pg.top, .to_next = !last and top + h > pg.top + pg.height };
    }
    /// The shifts of the lines of `node` (ascending `first_line`).
    pub fn lineShifts(p: *const Pages, node: u32) []const LineShift {
        var lo: usize = 0;
        var hi: usize = p.line_shifts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (p.line_shifts[mid].node < node) lo = mid + 1 else hi = mid;
        }
        var end = lo;
        while (end < p.line_shifts.len and p.line_shifts[end].node == node) end += 1;
        return p.line_shifts[lo..end];
    }
    /// Block shift of line `line` of `node`.
    pub fn lineDy(p: *const Pages, node: u32, line: u32) f32 {
        var dy: f32 = 0;
        for (p.lineShifts(node)) |s| {
            if (s.first_line > line) break;
            dy = s.dy;
        }
        return dy;
    }
    /// The repeats of page `page`.
    pub fn repeatsOf(p: *const Pages, page: u32) []const Repeat {
        var lo: usize = 0;
        while (lo < p.repeats.len and p.repeats[lo].page < page) lo += 1;
        var end = lo;
        while (end < p.repeats.len and p.repeats[end].page == page) end += 1;
        return p.repeats[lo..end];
    }
};

pub const Error = error{ OutOfMemory, TooManyPages, InvalidPageSize };

/// Paged-layout state a tree carries with the PDF feature (`Tree.paged`; `void` without it, so the
/// other builds do not change). Filled by the caller (render.zig `Frame.setPaged` / `paginate`).
pub const PagedState = struct {
    /// A rebuilt paragraph queries float exclusions at its fragmentainer
    /// position, while its consumed prefix remains in stitched layout space.
    inline_resume: ?struct { node: u32, from_y: f32, dy: f32 } = null,
    /// page area (content box) size in px when laid out for pages; 0 = not paged. `page_h` is also the
    /// block size of the initial containing block of `position: fixed` boxes (tree.zig)
    page_w: f32 = 0,
    page_h: f32 = 0,
    /// the result of `paginate`
    pages: ?Pages = null,
    /// the caller's `LinesFn` result buffer and per-page heights
    lines: std.ArrayList(LineBox) = .empty,
    height_fn: ?PageHeightFn = null,
    height_ctx: *anyopaque = undefined,
    /// called by `Frame.prepare` with (`dom_ctx`, the frame) once the element model is built, before
    /// the cascade (PDF page counters: src/pdf/counters.zig). Any frame, paged or not.
    dom_hook: ?*const fn (ctx: *anyopaque, frame: *anyopaque) error{OutOfMemory}!void = null,
    dom_ctx: *anyopaque = undefined,
    /// The frame is laid out for PDF output (set by src/pdf before `Frame.prepare`, paged or not):
    /// list markers, takumi's glyph placement (render.zig `listMarkers`, `makeParagraph`).
    pdf: bool = false,
    /// The frame's list markers (`src/pdf/markers.zig` `State`, opaque here); null = none generated.
    markers: ?*anyopaque = null,
    /// Named pages (src/pdf/page_names.zig): the page name id of each source element (0 = `auto`,
    /// empty when no element names a page) and the names (id `k` is `page_names[k - 1]`).
    page_of: []const u32 = &.{},
    page_names: []const []const u8 = &.{},
    /// A paragraph continued on a page of another width (src/pdf/paged.zig): render node
    /// `cut_node`'s paragraph ends a line right before its shaped glyph `cut_glyph`
    /// (`font.Paragraph.cut`); `no_node`: none.
    cut_node: u32 = no_node,
    cut_glyph: u32 = 0,
    cuts: []const ParagraphCut = &.{},
    row_minimums: []const RowMinimum = &.{},
    /// Tables stretched in a row flex line that pagination made reach past the line's end (filled
    /// by src/render.zig `Frame.stretchRowFlexTables`, read by table.zig).
    table_stretches: []TableStretch = &.{},
    /// Flex / grid containers whose items lay out at another width than the container's own
    /// (src/pdf/paged.zig, tree.zig).
    frozen_widths: []const FrozenWidth = &.{},
    /// Placement shifts of whole floats deferred to another fragmentainer.
    /// Recomputed inline layout consumes these through the BFC exclusion space.
    float_shifts: []f32 = &.{},
    /// Extra block extent introduced when pagination splits a float across a fragmentainer.
    /// The BFC uses it on the next layout pass so following lines avoid the whole float.
    float_extents: []f32 = &.{},
    /// What viewport units resolve against when set (a header / footer band: the whole page, takumi-pdf
    /// `band_viewport`'s unit reference), whatever the frame's own viewport.
    units: ?[2]f32 = null,
    /// The HTML source's own `<style>` texts are already in the frame's `css` option (a PDF pools the
    /// document's and its bands' `<style>` sheets into one stylesheet, src/pdf/pdf.zig `poolStyles`).
    skip_dom_styles: bool = false,
    /// A frame laying out a part of the document (src/pdf/chunks.zig): of the children of source
    /// element `parent`, only those with an index in [`lo`, `hi`) (source order) are built.
    chunk: ?struct { parent: u32, lo: u32, hi: u32 } = null,
};

/// Paginates the subtree of `root` (laid out by `t.compute`, normally with a definite available width =
/// the page area's width and an unbounded height). Rewrites the layouts of `t` in place (stitched space,
/// see the module doc) and returns the pages; the slices of the result come from `a`.
pub fn paginate(t: anytype, a: Allocator, root: tr.NodeId, opts: Options) Error!Pages {
    if (!enabled) @compileError("fragment.paginate needs the PDF feature (config.enable_pdf)");
    const E = Engine(@TypeOf(t.*));
    var e: E = .{ .t = t, .a = a, .opts = opts };
    defer e.deinit();
    return e.run(root);
}

/// The box clips its block-axis overflow: `overflow-y` other than `visible`, or `visible` computing to
/// `auto` because `overflow-x` is neither `visible` nor `clip` (CSS Overflow 3 §3.1).
fn clipsY(s: anytype) bool {
    return s.overflow_y != .visible or (s.overflow_x != .visible and s.overflow_x != .clip);
}

/// Blink's BreakAppeal, worst first.
const Appeal = enum(u8) { last_resort, violating_avoid, violating_orphans_widows, perfect };
inline fn rank(x: Appeal) u8 {
    return @backingInt(x);
}
inline fn worse(x: Appeal, y: Appeal) Appeal {
    return if (rank(x) < rank(y)) x else y;
}
/// Blink's JoinFragmentainerBreakValues (the second value wins a tie).
inline fn join(first: BB, second: BB) BB {
    return if (@backingInt(second) >= @backingInt(first)) second else first;
}

const eps: f32 = 1.0 / 128.0;
const ninf: f32 = -std.math.inf(f32);

/// The window of the current page for a flow: content may use `[start, end)`, and what breaks continues at
/// `next` (a table shrinks the window by its repeated header / footer).
const Pg = struct { start: f32, end: f32, next: f32 };

/// How a node's content is walked.
const K = enum(u8) {
    /// never split
    mono,
    /// line boxes (`LinesFn`)
    text,
    /// children in document order, one after the other (floats / static-position boxes ride along)
    block,
    /// captions and row groups in block order
    table,
    /// rows in document order
    group,
    /// cells side by side: one band of parallel flows
    row,
    /// flex / grid: items grouped into bands (rows) of parallel flows, bands in block order
    bands,
};

const Kind = enum(u8) { none, before, inside, line, span, push };
/// The breakpoint a probe chose inside a node for the current page (`brk`), or the best one it saw while
/// the node fit (an "early break" an ancestor may come back to). `arg`: item index / line index.
const Slot = struct {
    stamp: u32 = 0,
    arg: u32 = 0,
    /// trailing margin cut where the page ends (the node fits once shortened by it)
    trim: f32 = 0,
    kind: Kind = .none,
    brk: bool = false,
    forced: bool = false,
    /// the node itself ends on the page: its break continues in a parallel flow
    par: bool = false,
    /// the break `Options.start` asks for after an unforced one: the margin after it is truncated
    trunc: bool = false,
};
const State = struct {
    /// item index of the band to resume at (containers) / line index (text)
    @"resume": u32 = 0,
    seq: u32 = no_node,
    /// text: block shift of the lines from `resume` on
    shift: f32 = 0,
    /// broke inside on an earlier page
    started: bool = false,
    /// the band at `resume` is being continued (it broke inside), not started
    child_inside: bool = false,
    /// item of a parallel band whose content ended on an earlier page
    done: bool = false,
    queued: bool = false,
    /// the break before the band at `resume` was a forced one (its margin stays below the page start)
    forced_resume: bool = false,
    /// scratch of `applyBand`: the item reached the band's block end
    full: bool = false,
    /// block start a forced break moves this float / static-position box to (while `pushed`)
    push_y: f32 = 0,
    pushed: bool = false,
    /// broke in its block-end space (`Kind.span`): the next page resumes inside no content of it
    spanned: bool = false,
    /// a table cell's content moved by this (up) when its row breaks on this page (`cellRealign`)
    realign: f32 = 0,
};
const Item = struct {
    node: u32,
    /// in-flow (false: a float / static-position box that only rides along with the flow)
    flow: bool,
    /// starts a band
    first: bool,
};
const Seq = struct {
    items: []Item,
    /// free block space below the content of the box (min-height, stretching): absorbs growth
    slack: f32,
    /// block size before pagination
    h0: f32,
    /// block shift not yet written to `items[lazy_from..]`
    lazy: f32 = 0,
    lazy_from: u32 = 0,
    dirty: bool = false,
    /// has `position: absolute` children anchored to the block end
    bottom_abs: bool = false,
};
const Early = struct {
    has: bool = false,
    appeal: Appeal = .perfect,
    kind: Kind = .none,
    item: u32 = 0,
    /// a box on the path to the breakpoint has `break-inside: avoid`
    avoid: bool = false,
};
/// Result of probing a node (or a band) on one page.
const R = struct {
    /// border-box block end reached on this page
    end: f32,
    /// the same with block-end margins (bands only)
    mend: f32 = 0,
    brk: bool = false,
    par: bool = false,
    forced: bool = false,
    /// `brk`: appeal of the break as the container rates it
    appeal: Appeal = .perfect,
    early: bool = false,
    early_appeal: Appeal = .perfect,
    early_avoid: bool = false,
    /// break values propagated from the first / last child
    first: BB = .auto,
    last: BB = .auto,
};
const TableInfo = struct {
    hdr: u32 = no_node,
    hdr_idx: u32 = 0,
    hdr_block: f32 = 0,
    ftr: u32 = no_node,
    ftr_idx: u32 = 0,
    ftr_block: f32 = 0,
    /// border-spacing after a section (0 when collapsed)
    spacing: f32 = 0,
};
const RepeatRaw = struct { node: u32, page: u32, y: f32 };

fn Engine(comptime T: type) type {
    return struct {
        const Self = @This();
        const tables_on: bool = T.config.tables;
        const floats_on: bool = T.config.floats;

        t: *T,
        a: Allocator,
        opts: Options,
        st: []State = &.{},
        slot: []Slot = &.{},
        seqs: std.ArrayList(Seq) = .empty,
        dirty: std.ArrayList(u32) = .empty,
        queue: std.ArrayList(u32) = .empty,
        /// page tops, one more than the pages known
        tops: std.ArrayList(f32) = .empty,
        /// the name of each page of `tops` (named pages), and whether any box names a page
        names: std.ArrayList(u32) = .empty,
        any_names: bool = false,
        shifts: std.ArrayList(LineShift) = .empty,
        reps: std.ArrayList(RepeatRaw) = .empty,
        /// per `PagedState.table_stretches` entry: how much taller than in its first layout the
        /// table is before the breaks (`stretchExcess`)
        stretch_excess: []f32 = &.{},
        fixed: std.ArrayList(u32) = .empty,
        pushes: std.ArrayList(u32) = .empty,
        stamp: u32 = 0,
        page: u32 = 0,
        page_h: f32 = 0,
        /// `Options.start`: its block offset (the height of page 0), null: none
        start_h: ?f32 = null,
        /// how far `Options.start_top` moved the content (up)
        shift: f32 = 0,
        /// `Pages.starts`, one per page of `tops`; the main flow has been laid out
        starts: std.ArrayList(Start) = .empty,
        main_done: bool = false,

        fn deinit(e: *Self) void {
            for (e.starts.items) |s| {
                e.a.free(s.branches);
                e.a.free(s.side_flows);
            }
            e.starts.deinit(e.a);
            for (e.seqs.items) |s| e.a.free(s.items);
            e.seqs.deinit(e.a);
            e.dirty.deinit(e.a);
            e.queue.deinit(e.a);
            e.tops.deinit(e.a);
            e.names.deinit(e.a);
            e.shifts.deinit(e.a);
            e.reps.deinit(e.a);
            e.fixed.deinit(e.a);
            e.pushes.deinit(e.a);
            e.a.free(e.st);
            e.a.free(e.slot);
            e.a.free(e.stretch_excess);
        }

        inline fn lay(e: *Self, n: u32) *tr.Layout {
            return &e.t.layouts.items[n];
        }
        inline fn style(e: *Self, n: u32) *const sty.Style {
            return e.t.nodes.items[n].style;
        }

        // ------------------------------------------------------------------------------------ pages

        fn pageHeight(e: *Self, page: u32) Error!f32 {
            const name = if (!e.any_names) 0 else if (page == 0) e.startName(e.t.root, 0) else e.resumeName();
            try e.names.append(e.a, name);
            if (e.opts.record_starts) {
                const token: Start = if (page == 0 or e.main_done) .{} else try e.startToken();
                errdefer e.a.free(token.branches);
                try e.starts.append(e.a, token);
            }
            // (page 0 ends at the start: `Options.origin` is where it starts)
            if (page == 0) if (e.start_h) |h0| return h0 - e.opts.origin;
            const h = if (e.opts.page_height_fn) |f| f(e.opts.ctx, page, name) else e.opts.page_height;
            if (!(h >= 1) or !(h < 16_777_216)) return error.InvalidPageSize;
            return h;
        }
        /// Makes `tops[page + 1]` exist.
        fn need(e: *Self, page: u32) Error!void {
            if (page >= e.opts.max_pages) return error.TooManyPages;
            while (e.tops.items.len < @as(usize, page) + 2) {
                const k: u32 = @intCast(e.tops.items.len - 1);
                const h = try e.pageHeight(k);
                // (page 1 of `Options.start` starts exactly at `start_top`)
                try e.tops.append(e.a, if (k == 0 and e.start_h != null) e.start_h.? else e.tops.items[k] + h);
            }
        }
        fn window(e: *Self, page: u32) Error!Pg {
            try e.need(page);
            const s = e.tops.items[page];
            const en = e.tops.items[page + 1];
            e.page = page;
            // takumi `BlockFragmentation::fragmentainer_block_size`: the content breaks at the page
            // area truncated to the LayoutUnit grid (`LayoutUnit::from_float`, 1/64 px), the pages
            // stack at their exact size (`PageSizes::top`)
            // (page 0 of `Options.start` ends exactly at the start)
            const h = if (page == 0 and e.start_h != null) en - s else @floor((en - s) * 64) / 64;
            e.page_h = h;
            return .{ .start = s, .end = s + h, .next = en };
        }
        fn pageAt(e: *Self, y: f32) Error!u32 {
            // the first page whose end is below `y`: pages are added until one is, then a binary
            // search over those known (a walk from the first page made pagination quadratic)
            try e.need(0);
            var n: u32 = @intCast(e.tops.items.len - 2);
            if (!(y < e.tops.items[n + 1] - eps)) {
                while (true) {
                    n += 1;
                    try e.need(n);
                    if (y < e.tops.items[n + 1] - eps) return n;
                }
            }
            var lo: u32 = 0;
            var hi: u32 = n;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (y < e.tops.items[mid + 1] - eps) hi = mid else lo = mid + 1;
            }
            return lo;
        }

        // ------------------------------------------------------------------------------------ tree access

        fn kindOf(e: *Self, n: u32) K {
            const nd = &e.t.nodes.items[n];
            const s = nd.style;
            if (s.breaks.monolithic) return .mono;
            if (nd.measured or s.display == .inline_row) return .text;
            return switch (s.display) {
                .flex, .grid => .bands,
                .table, .inline_table => if (tables_on) .table else .block,
                .table_row_group, .table_header_group, .table_footer_group => if (tables_on) .group else .block,
                .table_row => if (tables_on) .row else .block,
                else => .block,
            };
        }
        fn heightDefinite(e: *Self, n: u32) bool {
            const s = e.style(n);
            if (tables_on and (s.display.isTable() or s.display.isTablePart())) return false;
            return switch (s.size[1]) {
                .px => true,
                .calc => |c| c.percent == 0,
                else => false,
            };
        }
        /// Blink's "block size is bounded" (`max_block_size != LayoutUnit::Max`).
        fn bounded(e: *Self, n: u32) bool {
            if (e.heightDefinite(n)) return true;
            const s = e.style(n);
            if (tables_on and (s.display.isTable() or s.display.isTablePart())) return false;
            return s.max_size[1] == .px;
        }
        fn linesOf(e: *Self, n: u32) []const LineBox {
            return if (e.opts.lines_fn) |f| f(e.opts.ctx, n) else &.{};
        }
        /// Block offset of `n`'s border box in stitched space (no shift may be pending above it).
        fn absTopOf(e: *Self, n: u32) f32 {
            var y: f32 = 0;
            var cur = n;
            var guard: u32 = 0;
            while (cur != no_node and guard < tr.max_depth + 8) : (guard += 1) {
                y += e.lay(cur).y;
                if (cur == e.t.root) break;
                cur = e.t.nodes.items[cur].parent;
            }
            return y;
        }

        // ------------------------------------------------------------------------------------ page names

        /// An in-flow child (named pages look through the others).
        fn inFlow(e: *Self, c: u32) bool {
            const s = e.style(c);
            return s.display != .none and !s.position.isOut() and (!floats_on or s.float == .none);
        }
        fn leafish(e: *Self, n: u32) bool {
            const nd = &e.t.nodes.items[n];
            return nd.measured or nd.first_child == no_node or e.kindOf(n) == .mono or e.kindOf(n) == .text;
        }
        /// The used page name of `n`: its own, else `inherited` (`page: auto`).
        fn usedName(e: *Self, n: u32, inherited: u32) u32 {
            const own = e.style(n).breaks.page;
            return if (own != 0) own else inherited;
        }
        /// The used page name of `n` from its ancestors.
        fn usedNameUp(e: *Self, n: u32) u32 {
            var cur = n;
            var guard: u32 = 0;
            while (cur != no_node and guard < tr.max_depth + 8) : (guard += 1) {
                const own = e.style(cur).breaks.page;
                if (own != 0) return own;
                if (cur == e.t.root) break;
                cur = e.t.nodes.items[cur].parent;
            }
            return 0;
        }
        /// CSS's start page value of `n`: its first in-flow child's, else its used page name.
        fn startName(e: *Self, n: u32, inherited: u32) u32 {
            var cur = n;
            var name = e.usedName(n, inherited);
            var guard: u32 = 0;
            while (guard < tr.max_depth + 8 and !e.leafish(cur)) : (guard += 1) {
                var c = e.t.nodes.items[cur].first_child;
                while (c != no_node and !e.inFlow(c)) c = e.t.nodes.items[c].next_sibling;
                if (c == no_node) break;
                name = e.usedName(c, name);
                cur = c;
            }
            return name;
        }
        /// CSS's end page value of `n`: its last in-flow child's, else its used page name.
        fn endName(e: *Self, n: u32, inherited: u32) u32 {
            var cur = n;
            var name = e.usedName(n, inherited);
            var guard: u32 = 0;
            while (guard < tr.max_depth + 8 and !e.leafish(cur)) : (guard += 1) {
                var last: u32 = no_node;
                var c = e.t.nodes.items[cur].first_child;
                while (c != no_node) : (c = e.t.nodes.items[c].next_sibling) {
                    if (e.inFlow(c)) last = c;
                }
                if (last == no_node) break;
                name = e.usedName(last, name);
                cur = last;
            }
            return name;
        }

        /// The page name of the page the main flow resumes on (asked for when that page opens, right
        /// after the break before it is applied): the used page name of the content it resumes with,
        /// down the chain of boxes broken inside (Blink's `PageNameForChildFragment`).
        fn resumeName(e: *Self) u32 {
            var cur = e.t.root;
            var name = e.usedName(cur, 0);
            var guard: u32 = 0;
            while (guard < tr.max_depth + 8) : (guard += 1) {
                const st = &e.st[cur];
                if (!st.started or st.seq == no_node) return name;
                const sq = &e.seqs.items[st.seq];
                if (st.@"resume" >= sq.items.len) return name;
                const c = sq.items[st.@"resume"].node;
                // (a box that starts on the page: its start page value)
                if (!st.child_inside) return e.startName(c, name);
                name = e.usedName(c, name);
                cur = c;
            }
            return name;
        }

        /// Where the page that opens now starts (`Start`), down the chain of boxes broken inside, as
        /// `resumeName` walks it.
        fn startToken(e: *Self) Error!Start {
            var cur = e.t.root;
            var guard: u32 = 0;
            while (guard < tr.max_depth + 8) : (guard += 1) {
                const st = &e.st[cur];
                if (!st.started) return .{};
                var k = e.kindOf(cur);
                if (st.spanned) {
                    // (a cell whose content ended while its row goes on: the row resumes with
                    // every cell finished, as a row whose cells all ended does)
                    if (k != .row and cur != e.t.root and e.kindOf(e.t.nodes.items[cur].parent) == .row) {
                        cur = e.t.nodes.items[cur].parent;
                        k = .row;
                    }
                    if (k != .row) return .{};
                    const row_st = &e.st[cur];
                    var points: std.ArrayList(ResumePoint) = .empty;
                    defer points.deinit(e.a);
                    var child = e.t.nodes.items[cur].first_child;
                    while (child != no_node) : (child = e.t.nodes.items[child].next_sibling) {
                        if (e.style(child).display == .none or e.style(child).position.isOut()) continue;
                        // (a cell that spans rows is a side flow of its own, as in `seqOf`)
                        if (e.t.layouts.items[child].h > e.lay(cur).h + eps) continue;
                        if (!try e.finishedPoints(child, &points, 0)) return .{};
                    }
                    return .{ .node = cur, .branches = try points.toOwnedSlice(e.a), .row_height = if (row_st.seq != no_node) e.seqs.items[row_st.seq].h0 else e.lay(cur).h };
                }
                if (k == .text) return .{ .node = cur, .line = st.@"resume" };
                if (st.seq == no_node) return .{};
                const sq = &e.seqs.items[st.seq];
                if (st.@"resume" >= sq.items.len) return .{};
                const c = sq.items[st.@"resume"].node;
                if (!sq.items[st.@"resume"].flow) return .{};
                if (!st.child_inside) return .{ .node = c, .forced = st.forced_resume };
                // (parallel flows broken inside resume at more than one point)
                if ((k == .row or k == .bands) and bandEnd(sq, st.@"resume") != st.@"resume" + 1) {
                    // (a flex line or grid row: its items keep their layout on the next page, `FrozenWidth`)
                    var points: std.ArrayList(ResumePoint) = .empty;
                    defer points.deinit(e.a);
                    const end = bandEnd(sq, st.@"resume");
                    for (sq.items[st.@"resume"..end]) |item| {
                        if (!item.flow or !try e.resumePoints(item.node, &points, 0)) return .{};
                    }
                    return .{ .node = cur, .branches = try points.toOwnedSlice(e.a), .row_height = if (k == .row) sq.h0 else 0 };
                }
                cur = c;
            }
            return .{};
        }

        /// Adds an in-progress float to the page-start token after its fragment breaks.
        /// The main flow token and parallel float tokens are independent: a width change
        /// rebuilds both from their own continuation points.
        fn recordFloatResume(e: *Self, page: u32, n: u32) Error!void {
            if (!e.opts.record_starts) return;
            try e.need(page);
            var points: std.ArrayList(ResumePoint) = .empty;
            defer points.deinit(e.a);
            if (!try e.resumePoints(n, &points, 0)) return;
            for (points.items) |point| if (!point.finished) {
                var merged: std.ArrayList(ResumePoint) = .empty;
                errdefer merged.deinit(e.a);
                const token = &e.starts.items[page];
                try merged.appendSlice(e.a, token.side_flows);
                var found = false;
                for (merged.items) |*existing| if (existing.node == point.node) {
                    existing.* = point;
                    found = true;
                    break;
                };
                if (!found) try merged.append(e.a, point);
                const side_flows = try merged.toOwnedSlice(e.a);
                e.a.free(token.side_flows);
                token.side_flows = side_flows;
            };
        }

        fn resumePoints(e: *Self, n: u32, points: *std.ArrayList(ResumePoint), depth: u32) Error!bool {
            if (depth >= tr.max_depth) return false;
            const st = &e.st[n];
            if (st.done) {
                return e.finishedPoints(n, points, depth);
            }
            if (!st.started) {
                try points.append(e.a, .{ .node = n });
                return true;
            }
            if (st.spanned) return e.finishedPoints(n, points, depth);
            if (e.kindOf(n) == .text) {
                try points.append(e.a, .{ .node = n, .line = if (st.@"resume" == 0) no_node else st.@"resume" });
                return true;
            }
            if (st.seq == no_node) return false;
            const sq = &e.seqs.items[st.seq];
            if (st.@"resume" >= sq.items.len) {
                try points.append(e.a, .{ .node = n, .finished = true });
                return true;
            }
            const end = if (st.child_inside) bandEnd(sq, st.@"resume") else st.@"resume" + 1;
            for (sq.items[st.@"resume"..end]) |item| {
                if (!item.flow) return false;
                if (st.child_inside) {
                    if (!try e.resumePoints(item.node, points, depth + 1)) return false;
                } else try points.append(e.a, .{ .node = item.node, .forced = st.forced_resume });
            }
            return true;
        }

        fn finishedPoints(e: *Self, n: u32, points: *std.ArrayList(ResumePoint), depth: u32) Error!bool {
            if (depth >= tr.max_depth) return false;
            const node = &e.t.nodes.items[n];
            if (e.kindOf(n) == .text or node.first_child == no_node) {
                try points.append(e.a, .{ .node = n, .finished = true });
                return true;
            }
            var child = node.first_child;
            while (child != no_node) : (child = e.t.nodes.items[child].next_sibling) {
                if (e.style(child).display == .none or e.style(child).position.isOut()) continue;
                if (!try e.finishedPoints(child, points, depth + 1)) return false;
            }
            return true;
        }

        /// Whether `Options.start` asks for a break before the box `c` here (page 0).
        inline fn startsAt(e: *const Self, c: u32) bool {
            const s = e.opts.start orelse return false;
            for (s.side_flows) |p| if (!p.finished and p.line == no_node and p.node == c) return e.start_h != null and e.page == 0;
            if (s.branches.len > 0) {
                if (e.start_h == null or e.page != 0) return false;
                for (s.branches) |p| if (!p.finished and p.line == no_node and p.node == c) return true;
                return false;
            }
            return e.start_h != null and e.page == 0 and s.line == no_node and s.node == c;
        }
        /// Whether `Options.start` says the parallel flow `c` (or a box in it) ended before the
        /// start: on page 0 it stays where the pages laid out before had it, not pushed past it.
        fn startFinished(e: *const Self, c: u32) bool {
            const s = e.opts.start orelse return false;
            if (e.start_h == null or e.page != 0) return false;
            for ([_][]const ResumePoint{ s.branches, s.side_flows }) |points| for (points) |p| {
                if (!p.finished) continue;
                var n = p.node;
                var guard: u32 = 0;
                while (n < e.t.nodes.items.len and guard < tr.max_depth + 8) : (guard += 1) {
                    if (n == c) return true;
                    if (n == e.t.root) break;
                    n = e.t.nodes.items[n].parent;
                }
            };
            return false;
        }
        fn startForced(e: *const Self, c: u32) bool {
            const s = e.opts.start orelse return false;
            for (s.side_flows) |p| if (!p.finished and p.node == c) return p.forced;
            for (s.branches) |p| if (!p.finished and p.node == c) return p.forced;
            return s.forced;
        }
        /// The block offset `Options.start` names (null: no point to break at): the earliest of its
        /// flows' points, where the page starts (a float continued above a paragraph line it pushed
        /// onto the page: the page starts at the float, the line stays below it).
        fn startY(e: *Self, s: Start) ?f32 {
            var y = e.mainStartY(s);
            for (s.side_flows) |p| {
                if (p.finished) continue;
                const side = e.mainStartY(.{ .node = p.node, .line = p.line, .forced = p.forced }) orelse return null;
                y = if (y) |main| @min(main, side) else side;
            }
            return y;
        }
        fn mainStartY(e: *Self, s: Start) ?f32 {
            if (s.branches.len > 0) {
                var end: f32 = 0;
                for (s.branches) |p| {
                    if (p.finished) continue;
                    if (p.node >= e.t.nodes.items.len) return null;
                    const y = e.startY(.{ .node = p.node, .line = p.line, .forced = p.forced }) orelse return null;
                    end = @max(end, y);
                }
                return end;
            }
            if (s.node >= e.t.nodes.items.len) return null;
            const top = e.absTopOf(s.node);
            if (s.line != no_node) {
                const lines = e.linesOf(s.node);
                if (s.line >= lines.len) return null;
                return top + lines[s.line].top;
            }
            return top - (if (s.forced) @max(e.lay(s.node).margin.top, 0) else 0);
        }

        fn seqOf(e: *Self, n: u32, k: K) Error!u32 {
            if (e.st[n].seq != no_node) return e.st[n].seq;
            const ns = e.t.nodes.items;
            var list: std.ArrayList(Item) = .empty;
            errdefer list.deinit(e.a);
            var bottom_abs = false;
            var ch = ns[n].first_child;
            while (ch != no_node) : (ch = ns[ch].next_sibling) {
                const cs = ns[ch].style;
                if (cs.display == .none) continue;
                if (cs.position.isOut()) {
                    if (cs.position != .absolute) continue;
                    if (cs.inset.top == .auto and cs.inset.bottom != .auto) bottom_abs = true;
                    // (a static-position box follows the content it sits after)
                    if (k == .block and cs.inset.top == .auto and cs.inset.bottom == .auto) try list.append(e.a, .{ .node = ch, .flow = false, .first = true });
                    continue;
                }
                if (k == .table and (cs.display == .table_column or cs.display == .table_column_group)) continue;
                // (a cell that spans rows reaches past its row: it is not fragmented, it moves with the row)
                if (k == .row and e.t.layouts.items[ch].h > e.lay(n).h + eps) continue;
                const side = floats_on and k == .block and cs.float != .none;
                try list.append(e.a, .{ .node = ch, .flow = !side, .first = true });
            }
            const items = try list.toOwnedSlice(e.a);
            errdefer e.a.free(items);
            const lays = e.t.layouts.items;
            if (k == .table or k == .bands or k == .group) {
                // block order: the items are sorted already unless `order`, a reversed direction or a
                // header / footer group placed them elsewhere
                var sorted = true;
                var si: usize = 1;
                while (si < items.len) : (si += 1) {
                    if (lays[items[si - 1].node].y > lays[items[si].node].y) sorted = false;
                }
                if (!sorted) std.sort.heap(Item, items, lays, itemLess);
            }
            if (k == .row) {
                for (items, 0..) |*it, i| it.first = i == 0;
            } else if (k != .block) {
                // a band = the items whose block extents overlap (a flex line, a grid row)
                // (an item starting where the band starts belongs to it even when what came before is
                // empty: an empty flex item at the start of a row is no content of its own before the
                // row's other items, which would make the row breakable after it)
                var band_end: f32 = ninf;
                var band_top: f32 = ninf;
                for (items) |*it| {
                    const l = &lays[it.node];
                    it.first = l.y >= band_end - eps and !(l.y <= band_top + eps);
                    if (it.first) band_top = l.y;
                    band_end = if (it.first) l.y + l.h else @max(band_end, l.y + l.h);
                }
            }
            const l = e.lay(n);
            var ce: f32 = l.border.top + l.padding.top;
            for (items) |it| {
                if (!it.flow) continue;
                const cl = &lays[it.node];
                ce = @max(ce, cl.y + cl.h + @max(cl.margin.bottom, 0));
            }
            ce += l.padding.bottom + l.border.bottom;
            const idx: u32 = @intCast(e.seqs.items.len);
            try e.seqs.append(e.a, .{ .items = items, .slack = if (k == .table) 0 else @max(l.h - ce, 0), .h0 = l.h, .bottom_abs = bottom_abs });
            e.st[n].seq = idx;
            return idx;
        }
        fn bandEnd(sq: *const Seq, i: u32) u32 {
            var j = i + 1;
            while (j < sq.items.len and !sq.items[j].first) j += 1;
            return j;
        }
        inline fn itemTop(e: *Self, sq: *const Seq, k: u32, top: f32) f32 {
            return top + e.lay(sq.items[k].node).y + (if (k >= sq.lazy_from) sq.lazy else 0);
        }
        /// Block start of the band `[i, j)`: its highest item that still has content to place.
        fn bandTop(e: *Self, sq: *const Seq, i: u32, j: u32, top: f32) f32 {
            var y: f32 = std.math.inf(f32);
            var any: f32 = std.math.inf(f32);
            var k = i;
            while (k < j) : (k += 1) {
                const it = sq.items[k];
                const ty = e.itemTop(sq, k, top);
                any = @min(any, ty);
                if (it.flow and !e.st[it.node].done) y = @min(y, ty);
            }
            return if (y < std.math.inf(f32)) y else any;
        }
        /// Border-box block end of the last in-flow band before item `i` (-inf: none); `trim`: apply the
        /// margin cuts recorded for its items.
        fn prevReach(e: *Self, sq: *const Seq, i: u32, top: f32, trim: bool) f32 {
            var p = i;
            while (p > 0 and !sq.items[p - 1].flow) p -= 1;
            if (p == 0) return ninf;
            var b = p - 1;
            while (b > 0 and !sq.items[b].first) b -= 1;
            var reach: f32 = ninf;
            var k = b;
            while (k < p) : (k += 1) {
                const c = sq.items[k].node;
                if (!sq.items[k].flow) continue;
                if (trim) e.applyTrim(c);
                reach = @max(reach, e.itemTop(sq, k, top) + e.lay(c).h);
            }
            return reach;
        }

        /// Monolithic content without line boxes (a replaced element, a `line-clamp` box).
        /// Whether an overflow clip of an ancestor (below `root`) cuts `n` away: a clipping box on
        /// its containing block chain. An absolutely positioned box escapes the clipping boxes
        /// between it and its containing block (CSS Overflow 3: the clip applies to the descendants
        /// it contains), and so does what it holds; a fixed box escapes them all. `started`: a
        /// clipping box that broke on an earlier page counts too (else it clips nothing here).
        fn clippedOut(e: *Self, n: u32, root: u32, started: bool) bool {
            const ns = e.t.nodes.items;
            var abs = ns[n].style.position == .absolute;
            if (ns[n].style.position == .fixed) return false;
            var p = ns[n].parent;
            var guard: u32 = 0;
            while (p != no_node and p != root and guard < tr.max_depth + 8) : (guard += 1) {
                const ps = ns[p].style;
                const clips = clipsY(ps) and (started or !e.st[p].started);
                if (abs) {
                    if (ps.position != .static) {
                        if (clips) return true;
                        if (ps.position == .fixed) return false;
                        abs = ps.position == .absolute;
                    }
                } else {
                    if (clips) return true;
                    if (ps.position == .fixed) return false;
                    if (ps.position == .absolute) abs = true;
                }
                p = ns[p].parent;
            }
            return false;
        }

        /// Whether `n` is inside a clipping box (below `root`) that did not break on an earlier page.
        fn insideClip(e: *Self, n: u32, root: u32) bool {
            const ns = e.t.nodes.items;
            var p = ns[n].parent;
            var guard: u32 = 0;
            while (p != no_node and p != root and guard < tr.max_depth + 8) : (guard += 1) {
                if (clipsY(ns[p].style) and !e.st[p].started) return true;
                p = ns[p].parent;
            }
            return false;
        }

        fn monoLeaf(e: *Self, n: u32) bool {
            return switch (e.kindOf(n)) {
                .mono => true,
                .text => e.linesOf(n).len == 0,
                else => false,
            };
        }
        /// Whether the in-flow content before item `i` reaches past the page end `pg_end` and is left
        /// behind there: what follows starts at the next page's start, not below that content.
        /// takumi (Blink's `ReserveSpaceForMonolithicOverflow`, applied in `ComputeChildData`) carries
        /// the overflow onto the next page only through a box that ends with it on its last line or its
        /// last in-flow child, monolithic, and then ends: its container places the box's next-page
        /// fragment that far down. Monolithic content overflowing right in this container (the root
        /// too: takumi's page area does not apply the root's overflow), a box whose block-end padding
        /// or border moves on, or overflow deeper than one box down move nothing.
        fn overflowStays(e: *Self, sq: *const Seq, i: u32, top: f32, pg_end: f32) bool {
            var p = i;
            while (p > 0 and !sq.items[p - 1].flow) p -= 1;
            if (p == 0) return false;
            const c = sq.items[p - 1].node;
            const ct = e.itemTop(sq, p - 1, top);
            const cl = e.lay(c);
            if (!(ct + cl.h > pg_end + eps)) return false;
            if (e.monoLeaf(c)) return true;
            if (e.kindOf(c) != .block) return false;
            if (cl.padding.bottom + cl.border.bottom > 0) return true;
            const ns = e.t.nodes.items;
            var last: u32 = no_node;
            var ch = ns[c].first_child;
            while (ch != no_node) : (ch = ns[ch].next_sibling) {
                if (e.inFlow(ch)) last = ch;
            }
            if (last == no_node) return false;
            const ll = e.lay(last);
            return !(e.monoLeaf(last) and ct + ll.y + ll.h > pg_end + eps);
        }

        fn lazyShift(e: *Self, sq_i: u32, from_in: u32, d: f32) Error!void {
            const sq = &e.seqs.items[sq_i];
            const from: u32 = @min(from_in, @as(u32, @intCast(sq.items.len)));
            if (from > sq.lazy_from) {
                if (sq.lazy != 0) for (sq.items[sq.lazy_from..from]) |it| {
                    e.lay(it.node).y += sq.lazy;
                };
                sq.lazy_from = from;
            } else if (from < sq.lazy_from) {
                // (does not happen: breaks only move forward; keep the positions consistent anyway)
                for (sq.items[from..sq.lazy_from]) |it| e.lay(it.node).y -= sq.lazy;
                sq.lazy_from = from;
            }
            sq.lazy += d;
            if (!sq.dirty) {
                sq.dirty = true;
                try e.dirty.append(e.a, sq_i);
            }
        }
        fn flush(e: *Self) void {
            for (e.dirty.items) |sq_i| {
                const sq = &e.seqs.items[sq_i];
                if (sq.lazy != 0) for (sq.items[sq.lazy_from..]) |it| {
                    e.lay(it.node).y += sq.lazy;
                };
                sq.lazy = 0;
                sq.dirty = false;
            }
            e.dirty.clearRetainingCapacity();
        }

        fn tableInfo(e: *Self, n: u32, sq: *const Seq) TableInfo {
            var info: TableInfo = .{};
            const s = e.style(n);
            const spacing: f32 = if (s.border_collapse) 0 else @max(s.border_spacing[1], 0);
            const quarter = e.page_h / 4;
            info.spacing = spacing;
            for (sq.items, 0..) |it, i| {
                const cs = e.style(it.node);
                const is_h = cs.display == .table_header_group and info.hdr == no_node;
                const is_f = cs.display == .table_footer_group and info.ftr == no_node;
                if (!is_h and !is_f) continue;
                const h = e.lay(it.node).h;
                // a group repeats when it avoids breaking inside and is at most a quarter of the page
                const ok = cs.breaks.avoid_inside and h > 0 and h <= quarter + eps;
                if (is_h) {
                    info.hdr = it.node;
                    info.hdr_idx = @intCast(i);
                    if (ok) info.hdr_block = h + spacing;
                } else {
                    info.ftr = it.node;
                    info.ftr_idx = @intCast(i);
                    if (ok) info.ftr_block = h + spacing;
                }
            }
            return info;
        }
        /// The page window of a table's rows: past its repeated header, short of its repeated footer.
        fn tablePg(e: *Self, n: u32, info: *const TableInfo, pg: Pg) Pg {
            var out = pg;
            const stt = &e.st[n];
            if (info.hdr_block > 0) {
                if (stt.started and stt.@"resume" > info.hdr_idx) out.start += info.hdr_block;
                out.next += info.hdr_block;
            }
            if (info.ftr_block > 0 and (!stt.started or stt.@"resume" <= info.ftr_idx)) out.end -= info.ftr_block;
            if (!(out.end > out.start + 1)) out.end = pg.end;
            return out;
        }

        /// The page window of the content of `n`: with `box-decoration-break: clone` every fragment
        /// repeats the block-start and block-end border and padding, so the content breaks above the
        /// block-end ones and resumes below the block-start ones (takumi `fragmentainer_capacity(true)`
        /// / `cloned_block_start_decoration`).
        fn clonePg(e: *Self, n: u32, pg: Pg) Pg {
            if (!e.style(n).breaks.clone) return pg;
            const l = e.lay(n);
            const t = l.border.top + l.padding.top;
            const b = l.padding.bottom + l.border.bottom;
            const s = if (e.st[n].started) pg.start + t else pg.start;
            if (!(pg.end - b > s + 1)) return pg;
            return .{ .start = s, .end = pg.end - b, .next = pg.next + t };
        }

        // ------------------------------------------------------------------------------------ probe

        fn setBreak(e: *Self, n: u32, kind: Kind, arg: u32, forced: bool, appeal: Appeal, known_fit: bool, bottom: f32, pg_end: f32) Error!R {
            const sl = &e.slot[n];
            sl.kind = kind;
            sl.arg = arg;
            sl.brk = true;
            sl.forced = forced;
            sl.par = known_fit;
            var ap: Appeal = if (forced) .perfect else appeal;
            // Blink's CalculateBreakAppealInside
            if (!forced and e.style(n).breaks.avoid_inside and rank(ap) > rank(Appeal.violating_avoid)) ap = .violating_avoid;
            if (known_fit) {
                // the box ends on this page: what broke goes on in a parallel flow (`runFlow` later)
                if (!e.st[n].queued) {
                    e.st[n].queued = true;
                    try e.queue.append(e.a, n);
                }
                return .{ .end = bottom, .brk = true, .par = true, .forced = forced, .appeal = ap };
            }
            return .{ .end = pg_end, .brk = true, .forced = forced, .appeal = ap };
        }
        fn useEarly(e: *Self, n: u32, early: Early, known_fit: bool, bottom: f32, pg_end: f32) Error!R {
            // (Blink re-lays out to break at the early breakpoint with a perfect appeal; a box on the way
            // that avoids breaks lowers it)
            return try e.setBreak(n, early.kind, early.item, false, if (early.avoid) .violating_avoid else .perfect, known_fit, bottom, pg_end);
        }

        /// Finds what happens to `n` (border-box block start `top`) on the page `pg`: it fits, or it breaks
        /// (the breakpoint goes to `slot[n]`). Does not change any layout.
        noinline fn probe(e: *Self, n: u32, top: f32, pg: Pg, requires: bool) Error!R {
            const bottom = top + e.lay(n).h;
            e.slot[n] = .{ .stamp = e.stamp };
            const k = e.kindOf(n);
            if (k == .mono) return .{ .end = bottom };
            if (k == .text) return e.probeText(n, top, pg, requires);
            // Blink's is_known_to_fit_in_fragmentainer: a box of bounded block size that ends on this page
            const known_fit = e.bounded(n) and bottom <= pg.end + eps;
            // (a clipping box that fits is not fragmented for its content: Blink's DisableFragmentation)
            if (known_fit and clipsY(e.style(n)) and n != e.t.root) return .{ .end = bottom };
            var first: BB = .auto;
            var r = try e.probeSeq(n, top, pg, k, known_fit, requires, &first);
            // (the break value before the first child reaches the container even where the box breaks)
            if (r.brk and !e.st[n].started) r.first = first;
            return r;
        }

        noinline fn probeSeq(e: *Self, n: u32, top: f32, pg_in: Pg, k: K, known_fit: bool, requires_in: bool, first_out: *BB) Error!R {
            const sq_i = try e.seqOf(n, k);
            const stt = &e.st[n];
            const l = e.lay(n);
            const bottom0 = top + l.h;
            var pg = pg_in;
            var info: TableInfo = .{};
            if (k == .table) {
                info = e.tableInfo(n, &e.seqs.items[sq_i]);
                pg = e.tablePg(n, &info, pg_in);
            }
            // (the content's window: `box-decoration-break: clone` keeps the decorations on every page)
            const cpg = e.clonePg(n, pg);
            // Blink's MustStayInCurrentFragmentainer
            var requires = requires_in or (known_fit and !stt.started);
            var opp = false;
            const first_sep = k == .bands and (e.style(n).display == .grid or e.style(n).flex_direction == .column or e.style(n).flex_direction == .column_reverse);
            var early: Early = .{};
            var prev_after: BB = .auto;
            var first_bb: ?BB = null;
            // (named pages: the used page name here, and the end page value of the sibling before)
            const names_here = e.any_names and (k == .block or k == .bands or k == .group or k == .table);
            const used_here: u32 = if (names_here) e.usedNameUp(n) else 0;
            var prev_name: ?u32 = null;
            var flow_end: f32 = top + l.border.top + l.padding.top;
            var last_end: f32 = ninf;
            var i: u32 = if (stt.started) stt.@"resume" else 0;
            while (true) {
                const sq = &e.seqs.items[sq_i];
                if (i >= sq.items.len) break;
                const j = bandEnd(sq, i);
                const it0 = sq.items[i];
                if (!it0.flow) {
                    // a float / out-of-flow box after a forced break value goes to the next page on its
                    // own (a parallel flow: this box goes on, and the value still applies to what follows)
                    if (prev_after == .page and !(e.start_h != null and e.page == 0)) try e.push(it0.node, pg_in.next);
                    i = j;
                    continue;
                }
                const resumed = stt.started and i == stt.@"resume";
                const resumed_band = resumed and stt.child_inside;
                if (!resumed and e.startsAt(it0.node)) {
                    // (`Options.start`: page 0 ends right before this box)
                    const r = try e.setBreak(n, .before, i, true, .perfect, known_fit, bottom0, pg.end);
                    e.slot[n].trunc = !e.startForced(it0.node);
                    return r;
                }
                const band_top = e.bandTop(sq, i, j, top);
                // pushed below monolithic content of an earlier page: as if after a perfect breakpoint
                if (resumed and !stt.child_inside and !stt.forced_resume and band_top > cpg.start + eps) opp = true;
                // Blink's flex columns and grids: anything before the first item / row (padding, its own
                // margin, an alignment offset) separates it from the start of its container
                if (first_sep and !stt.started and i == 0 and band_top > top + eps) opp = true;
                var bpg = cpg;
                // (the repeated footer itself is placed in the space reserved for it)
                if (k == .table and it0.node == info.ftr and info.ftr_block > 0) bpg.end = @max(pg.end, pg_in.end);
                const single = j == i + 1;
                var rb: R = undefined;
                var cb: Breaks = .{};
                if (single) {
                    rb = try e.probe(it0.node, band_top, bpg, requires);
                    cb = e.style(it0.node).breaks;
                    rb.mend = rb.end + @max(e.lay(it0.node).margin.bottom, 0);
                } else rb = try e.probeBand(sq_i, i, j, top, band_top, bpg, requires);
                if (!resumed_band) {
                    const child_first = join(rb.first, cb.before);
                    var between = join(prev_after, child_first);
                    // Blink: siblings whose page names differ are separated by a forced break
                    if (names_here and single) {
                        if (prev_name) |pn| if (pn != e.startName(it0.node, used_here)) {
                            between = .page;
                        };
                    }
                    // (page 0 of `Options.start` holds what pages laid out before showed: it breaks
                    // nowhere but at the start)
                    if (e.start_h != null and e.page == 0 and between == .page) between = .auto;
                    if (first_bb == null) {
                        first_bb = child_first;
                        first_out.* = child_first;
                    }
                    if (opp and between == .page and !resumed) return try e.setBreak(n, .before, i, true, .perfect, known_fit, bottom0, pg.end);
                    // Blink's CalculateBreakAppealBefore
                    const appeal_before: Appeal = if (!opp) .last_resort else if (between == .avoid) .violating_avoid else .perfect;
                    // Blink's MovePastBreakpoint
                    const space_left = bpg.end - band_top;
                    var mp = false;
                    if (!(space_left < -eps or (space_left <= eps and rb.brk and !rb.par))) {
                        // (breaking at the page start makes no progress)
                        mp = band_top <= bpg.start + eps;
                        if (!mp) {
                            if (rb.brk) {
                                // breaking inside is better than before only where it is as good
                                mp = rank(rb.appeal) >= rank(appeal_before) and (!early.has or rank(rb.appeal) >= rank(early.appeal));
                            } else if (rb.end <= bpg.end + eps) {
                                mp = true;
                            } else if (appeal_before == .last_resort and requires) mp = true;
                        }
                        if (mp) {
                            if (single) {
                                // Blink's UpdateEarlyBreakAtBlockChild
                                var ai: Appeal = .last_resort;
                                var done = false;
                                if (rb.early and !rb.brk) {
                                    ai = if (cb.avoid_inside and rank(rb.early_appeal) > rank(Appeal.violating_avoid)) .violating_avoid else rb.early_appeal;
                                    if (!early.has or rank(early.appeal) <= rank(rb.early_appeal))
                                        early = .{ .has = true, .appeal = ai, .kind = .inside, .item = i, .avoid = cb.avoid_inside or rb.early_avoid };
                                }
                                if (rank(appeal_before) <= rank(ai)) done = true;
                                if (!done and early.has and rank(early.appeal) > rank(appeal_before)) done = true;
                                if (!done) early = .{ .has = true, .appeal = appeal_before, .kind = .before, .item = i };
                            } else if (opp and (!early.has or rank(appeal_before) >= rank(early.appeal))) {
                                // Blink's MovePastRowBreakPoint
                                early = .{ .has = true, .appeal = appeal_before, .kind = .before, .item = i };
                            }
                        }
                    }
                    if (!mp) {
                        // Blink's AttemptSoftBreak
                        if (early.has and rank(early.appeal) > rank(appeal_before)) return try e.useEarly(n, early, known_fit, bottom0, pg.end);
                        return try e.setBreak(n, .before, i, false, appeal_before, known_fit, bottom0, pg.end);
                    }
                }
                if (rb.brk and !rb.par) return try e.setBreak(n, .inside, i, rb.forced, rb.appeal, known_fit, bottom0, pg.end);
                requires = false;
                // (a repeated header takes no part in breaking: no breakpoint between it and the rows)
                if (!(k == .table and it0.node == info.hdr and info.hdr_block > 0)) opp = true;
                prev_after = join(rb.last, cb.after);
                if (names_here and single) prev_name = e.endName(it0.node, used_here);
                last_end = rb.end;
                flow_end = @max(flow_end, rb.mend);
                i = j;
            }

            // every child that is left fits on this page
            const sl = &e.slot[n];
            var bottom = bottom0;
            const inset_b = l.padding.bottom + l.border.bottom;
            if (k == .block and e.style(n).display != .table_cell and !e.bounded(n) and bottom > pg.end + eps and last_end > ninf) {
                // Blink's AdjustedMarginAfterFinalChildFragment: the last child's block-end margin stops
                // at the page end
                const ce = bottom - inset_b;
                if (last_end <= pg.end + eps and ce > pg.end + eps) {
                    sl.trim = ce - @max(last_end, pg.end);
                    bottom -= sl.trim;
                }
            }
            // (a table whose footer was placed fits the page, not the rows' window short of the footer)
            // (a table with a repeated header lays its last table box out again with
            // `should_prevent_break_before_block_end_decorations`: once its rows fit, its block-end
            // border, padding and spacing overflow the page instead of breaking before them; takumi
            // table/layout.rs `relayout_as_last_table_box`, Blink's FinishFragmentation)
            // (the box then reaches its container's page only as far as its content)
            const fit_end = (if (k == .table) pg_in.end else pg.end) + eps;
            const end_decorations_hang = k == .table and info.hdr_block > 0 and bottom > fit_end and flow_end <= fit_end and bottom <= flow_end + info.spacing + inset_b + eps;
            if (end_decorations_hang or bottom <= fit_end) {
                var r: R = .{ .end = if (end_decorations_hang) flow_end else bottom, .first = first_bb orelse .auto, .last = prev_after };
                if (early.has and !known_fit) {
                    sl.kind = early.kind;
                    sl.arg = early.item;
                    r.early = true;
                    r.early_appeal = early.appeal;
                    r.early_avoid = early.avoid;
                }
                return r;
            }
            // the box itself reaches past the page end (Blink's FinishFragmentation): in the free space
            // below its content that is a perfect break; inside its block-end padding / border it goes
            // back to an earlier breakpoint, or is a last resort
            if (bottom > flow_end + inset_b + eps) return try e.setBreak(n, .span, 0, false, .perfect, false, bottom0, pg.end);
            // content that overflows the page unbroken (monolithic) and nothing after it: the box ends
            // here (takumi's `is_at_block_end` with monolithic overflow), its container goes on
            if (k == .block and inset_b <= eps and n != e.t.root) return .{ .end = bottom, .first = first_bb orelse .auto, .last = prev_after };
            if (early.has) return try e.useEarly(n, early, false, bottom0, pg.end);
            // (the block-end padding / border alone does not fit: Blink breaks before it)
            // (also when content overflowing the page unbroken (monolithic) ends there: takumi moves the
            // block-end padding / border to the next page and what follows comes after it)
            const push_end = inset_b > 0 and (bottom - inset_b <= pg.end + eps or k == .block) and !e.heightDefinite(n) and e.style(n).display != .table_cell;
            return try e.setBreak(n, .span, @intFromBool(push_end), false, .last_resort, false, bottom0, pg.end);
        }

        /// A band of parallel flows (table cells, the items of a flex line / grid row) as one child.
        noinline fn probeBand(e: *Self, sq_i: u32, i: u32, j: u32, top: f32, band_top: f32, pg: Pg, requires: bool) Error!R {
            var agg: R = .{ .end = ninf, .mend = ninf };
            var k = i;
            while (k < j) : (k += 1) {
                const sq = &e.seqs.items[sq_i];
                const it = sq.items[k];
                if (!it.flow) continue;
                const c = it.node;
                const ct = e.itemTop(sq, k, top);
                const cl = e.lay(c);
                const aligned_grid_item = tr.has(cl.grid_block_start) and cl.y > cl.grid_block_start + eps;
                if (e.st[c].done) {
                    agg.end = @max(agg.end, ct + cl.h);
                    agg.mend = @max(agg.mend, ct + cl.h + @max(cl.margin.bottom, 0));
                    continue;
                }
                // (a middle / bottom aligned cell of a row the page end cuts aligns in its fragment)
                const ra = e.cellRealign(c, ct, pg.end);
                e.st[c].realign = ra;
                if (ra != 0) e.shiftKids(c, ra);
                const rc = try e.probe(c, ct, pg, requires);
                if (ra != 0) e.shiftKids(c, -ra);
                const cb = e.style(c).breaks;
                agg.first = join(agg.first, join(rc.first, cb.before));
                agg.last = join(agg.last, join(rc.last, cb.after));
                var end = rc.end;
                const sep0 = ct > band_top + eps;
                // (an item the pages before ended stays on page 0 of `Options.start`)
                const kept = e.startFinished(c);
                if (!kept and rc.brk and !rc.par and !rc.forced and sep0 and ct > pg.start + eps and e.breaksAtStart(c)) {
                    // it breaks before all its content and sits lower than its row: the break before
                    // it is as good as one before a monolithic item (Blink's flex / grid items are
                    // parallel flows, whose block-start breakpoint is a class A one)
                    e.slot[c] = .{ .stamp = e.stamp, .kind = .push, .brk = true };
                    agg.brk = true;
                    if (aligned_grid_item) agg.appeal = .last_resort;
                    end = pg.end;
                } else if (rc.brk and !rc.par) {
                    agg.brk = true;
                    agg.forced = agg.forced or rc.forced;
                    agg.appeal = worse(agg.appeal, rc.appeal);
                    end = pg.end;
                } else if (!rc.brk and rc.end > pg.end + eps) {
                    // unbreakable and too tall: it stays where a break before it makes no progress, else
                    // it goes to the next page alone (a last resort unless it sits lower than its row)
                    const sep = ct > band_top + eps;
                    if (!(kept or ct <= pg.start + eps or (requires and !sep))) {
                        e.slot[c] = .{ .stamp = e.stamp, .kind = .push, .brk = true };
                        agg.brk = true;
                        agg.appeal = worse(agg.appeal, if (sep) .perfect else .last_resort);
                        if (aligned_grid_item) agg.appeal = .last_resort;
                        end = pg.end;
                    }
                }
                agg.end = @max(agg.end, end);
                agg.mend = @max(agg.mend, end + @max(cl.margin.bottom, 0));
            }
            if (agg.forced) agg.appeal = .perfect;
            return agg;
        }

        /// How far the content of the table cell `c` (border-box block start `ct`) moves when its row
        /// breaks at `pg_end` (0: not at all): a `vertical-align: middle` / `bottom` cell of a row
        /// the page end cuts starts its content at its top (takumi-pdf 0.20.0, probes
        /// pagination.table.rows: its fragment's free space is none, `table_cell_content_offset`).
        fn cellRealign(e: *Self, c: u32, ct: f32, pg_end: f32) f32 {
            if (!tables_on) return 0;
            const cs = e.style(c);
            if (cs.display != .table_cell or e.st[c].started) return 0;
            if (cs.vertical_align != .middle and cs.vertical_align != .bottom) return 0;
            const l = e.lay(c);
            if (!(ct + l.h > pg_end + eps)) return 0;
            var lo: f32 = std.math.inf(f32);
            var hi: f32 = ninf;
            const ns = e.t.nodes.items;
            var ch = ns[c].first_child;
            while (ch != no_node) : (ch = ns[ch].next_sibling) {
                if (!e.inFlow(ch)) continue;
                const kl = e.lay(ch);
                lo = @min(lo, kl.y - @max(kl.margin.top, 0));
                hi = @max(hi, kl.y + kl.h + @max(kl.margin.bottom, 0));
            }
            if (!(hi > ninf)) return 0;
            const inset_t = l.border.top + l.padding.top;
            const off = lo - inset_t;
            if (!(off > eps)) return 0;
            return -off;
        }
        /// The break the probe chose inside `n` comes before any of its content (its first line, its
        /// first in-flow child, down the chain).
        fn breaksAtStart(e: *Self, n: u32) bool {
            var cur = n;
            var guard: u32 = 0;
            while (guard < tr.max_depth + 8) : (guard += 1) {
                const sl = e.slot[cur];
                if (sl.stamp != e.stamp or !sl.brk or e.st[cur].started) return false;
                switch (sl.kind) {
                    .line => {
                        const lines = e.linesOf(cur);
                        return sl.arg <= nthLine(lines, 0, 0);
                    },
                    .before, .inside => {
                        const sq_i = e.st[cur].seq;
                        if (sq_i == no_node) return false;
                        const sq = &e.seqs.items[sq_i];
                        if (sl.arg >= sq.items.len) return false;
                        var p: u32 = 0;
                        while (p < sl.arg) : (p += 1) {
                            if (sq.items[p].flow) return false;
                        }
                        if (sl.kind == .before) return true;
                        if (bandEnd(sq, sl.arg) != sl.arg + 1) return false;
                        cur = sq.items[sl.arg].node;
                    },
                    else => return false,
                }
            }
            return false;
        }
        fn shiftKids(e: *Self, c: u32, d: f32) void {
            const ns = e.t.nodes.items;
            var ch = ns[c].first_child;
            while (ch != no_node) : (ch = ns[ch].next_sibling) {
                if (ns[ch].style.display == .none) continue;
                e.lay(ch).y += d;
            }
        }

        /// Index of the line that has `count` non-empty lines of `lines[from..]` before it.
        fn nthLine(lines: []const LineBox, from: u32, count: u32) u32 {
            var seen: u32 = 0;
            var i = from;
            while (i < lines.len) : (i += 1) {
                const empty = !(lines[i].bottom - lines[i].top > 0);
                if (empty) continue;
                if (seen == count) return i;
                seen += 1;
            }
            return @intCast(lines.len);
        }

        noinline fn probeText(e: *Self, n: u32, top: f32, pg: Pg, requires: bool) Error!R {
            const l = e.lay(n);
            const stt = &e.st[n];
            const bottom = top + l.h;
            const lines = e.linesOf(n);
            // (no line boxes: an image, or inline content that cannot be split)
            if (lines.len == 0) return .{ .end = bottom };
            const br = e.style(n).breaks;
            const widows: u32 = @max(br.widows, 1);
            const orphans: u32 = @max(br.orphans, 1);
            const start: u32 = if (stt.started) stt.@"resume" else 0;
            const shift = stt.shift;
            // Blink's line_count / first_overflowing_line_ (0 = none) / fit_all_lines_
            var lc: u32 = 0;
            var first_over: u32 = 0;
            var fit_all = false;
            var opp = false;
            var brk_line: u32 = no_node;
            var brk_appeal: Appeal = .perfect;
            var last_bottom: f32 = top + l.border.top + l.padding.top;
            // (the lines' window: `box-decoration-break: clone`)
            const lpg = e.clonePg(n, pg);
            // (`Options.start`: page 0 ends right before one of these lines)
            const cut_line: u32 = blk: {
                const s = e.opts.start orelse break :blk no_node;
                if (e.start_h == null or e.page != 0) break :blk no_node;
                for (s.side_flows) |p| if (!p.finished and p.node == n) break :blk p.line;
                if (s.branches.len > 0) {
                    for (s.branches) |p| if (!p.finished and p.node == n) break :blk p.line;
                    break :blk no_node;
                }
                break :blk if (s.node == n) s.line else no_node;
            };
            var i = start;
            while (i < lines.len) : (i += 1) {
                if (i == cut_line and i > start) return try e.setBreak(n, .line, i, true, .perfect, false, bottom, pg.end);
                const lt = top + lines[i].top + shift;
                const lb = top + lines[i].bottom + shift;
                const empty = !(lb - lt > 0);
                var appeal_before: Appeal = if (opp) .perfect else .last_resort;
                var mp: bool = undefined;
                if (lpg.end - lt < -eps) {
                    mp = false;
                } else if (lt <= lpg.start + eps or lb <= lpg.end + eps) {
                    mp = true;
                } else mp = appeal_before == .last_resort and requires;
                // (the paragraph's first line placed below a float that reaches past the page end,
                // on a later page whole: the empty space before it breaks, nothing moves; takumi lays
                // the line out on the page the float leaves room on)
                if (!mp and lc == 0 and i == start and !stt.started and lines[i].top > eps and lt >= pg.next - eps)
                    return try e.setBreak(n, .line, i, false, .perfect, false, bottom, pg.end);
                if (!mp) {
                    var go_on = false;
                    if (lc != 0) {
                        if (first_over == 0) first_over = lc;
                        // (widows before an earlier break are orphans after it)
                        const min_lines = if (stt.started) @max(orphans, widows) else orphans;
                        if (lc < min_lines) {
                            appeal_before = worse(appeal_before, .violating_orphans_widows);
                        } else if (lc - first_over + 1 < widows or empty) {
                            // lay out on to find where to break so the next page gets its widows
                            go_on = true;
                        }
                        if (!go_on) fit_all = true;
                    }
                    if (!go_on) {
                        brk_line = i;
                        brk_appeal = appeal_before;
                        break;
                    }
                } else last_bottom = @max(last_bottom, lb);
                if (!empty) {
                    lc += 1;
                    opp = true;
                }
            }
            if (first_over != 0 and first_over < lc) {
                // every line that overflows has been seen: break so that `widows` lines move on, keeping
                // `orphans` (which wins)
                const ln = if (fit_all) first_over else @max(lc -| widows, @min(lc, orphans));
                brk_line = nthLine(lines, start, ln);
                brk_appeal = .perfect;
            }
            if (brk_line != no_node and brk_line < lines.len) return try e.setBreak(n, .line, brk_line, false, brk_appeal, false, bottom, pg.end);

            var r: R = .{ .end = bottom };
            const sl = &e.slot[n];
            if (lc >= 2 and first_over == 0) {
                // Blink's UpdateEarlyBreakBetweenLines
                var ln = @max(lc -| widows, @min(lc - 1, orphans));
                var ap: Appeal = .perfect;
                if (ln < orphans or lc - ln < widows) {
                    ln = lc - 1;
                    ap = .violating_orphans_widows;
                }
                sl.kind = .line;
                sl.arg = nthLine(lines, start, ln);
                r.early = true;
                r.early_appeal = ap;
            }
            if (bottom <= pg.end + eps) return r;
            const inset_b = l.padding.bottom + l.border.bottom;
            if (bottom > last_bottom + inset_b + eps) return try e.setBreak(n, .span, 0, false, .perfect, false, bottom, pg.end);
            if (r.early) return try e.setBreak(n, .line, sl.arg, false, .perfect, false, bottom, pg.end);
            return try e.setBreak(n, .span, 0, false, .last_resort, false, bottom, pg.end);
        }

        // ------------------------------------------------------------------------------------ apply

        fn applyTrim(e: *Self, n: u32) void {
            var cur = n;
            var guard: u32 = 0;
            while (guard < tr.max_depth + 8) : (guard += 1) {
                const sl = &e.slot[cur];
                if (sl.stamp != e.stamp or sl.brk or sl.trim == 0) return;
                const l = e.lay(cur);
                l.h = @max(l.h - sl.trim, 0);
                sl.trim = 0;
                // the cut margin is that of the last in-flow child, which may have been cut the same way
                const sq_i = e.st[cur].seq;
                if (sq_i == no_node) return;
                const sq = &e.seqs.items[sq_i];
                var p = sq.items.len;
                while (p > 0 and !sq.items[p - 1].flow) p -= 1;
                if (p == 0) return;
                cur = sq.items[p - 1].node;
            }
        }

        /// Where the content of `n` ends on the current page once its break is applied (for the repeated
        /// table footer). Call before `apply`.
        fn cutY(e: *Self, n: u32, top: f32, pg_end: f32) f32 {
            const sl = e.slot[n];
            if (sl.stamp != e.stamp or e.st[n].seq == no_node) return pg_end;
            const sq = &e.seqs.items[e.st[n].seq];
            if (sl.arg >= sq.items.len) return pg_end;
            switch (sl.kind) {
                .before => {
                    const reach = e.prevReach(sq, sl.arg, top, false);
                    return if (reach > ninf) @min(reach, pg_end) else @min(top, pg_end);
                },
                .inside => {
                    if (bandEnd(sq, sl.arg) != sl.arg + 1) return pg_end;
                    return e.cutY(sq.items[sl.arg].node, e.itemTop(sq, sl.arg, top), pg_end);
                },
                else => return pg_end,
            }
        }

        /// Applies the breakpoint `slot[n]` of the current page: moves what follows it to `pg.next`.
        /// Returns the growth of `n`'s block size.
        noinline fn apply(e: *Self, n: u32, top: f32, pg: Pg) Error!f32 {
            const sl = e.slot[n];
            const stt = &e.st[n];
            if (sl.stamp != e.stamp) return 0;
            switch (sl.kind) {
                .none, .push => return 0,
                .span => {
                    stt.started = true;
                    stt.spanned = true;
                    if (stt.seq != no_node) _ = e.prevReach(&e.seqs.items[stt.seq], @intCast(e.seqs.items[stt.seq].items.len), top, true);
                    if (sl.arg == 0) return 0;
                    // the block-end padding and border start the next page
                    const l = e.lay(n);
                    // (above the content's end when that overflows the page: the box ends shorter)
                    const g = pg.next - (top + l.h - l.padding.bottom - l.border.bottom);
                    l.h += g;
                    return g;
                },
                .line => return e.applyText(n, top, pg, sl.arg),
                .before, .inside => return e.applySeq(n, top, pg, sl),
            }
        }

        noinline fn applySeq(e: *Self, n: u32, top: f32, pg_in: Pg, sl: Slot) Error!f32 {
            const stt = &e.st[n];
            const sq_i = stt.seq;
            if (sq_i == no_node) return 0;
            const k = e.kindOf(n);
            const i = sl.arg;
            if (i >= e.seqs.items[sq_i].items.len) return 0;
            const j = bandEnd(&e.seqs.items[sq_i], i);
            var pg = pg_in;
            var next = pg_in.next;
            if (k == .table) {
                const info = e.tableInfo(n, &e.seqs.items[sq_i]);
                pg = e.tablePg(n, &info, pg_in);
                const past_hdr = info.hdr_block > 0 and i > info.hdr_idx;
                if (past_hdr) {
                    // the header goes at the start of the next page, the rows below it
                    next = pg.next;
                    try e.reps.append(e.a, .{ .node = info.hdr, .page = e.page + 1, .y = pg_in.next });
                } else pg.next = pg_in.next;
                // the footer follows the last row of the page (unless it is what moves on, or no row
                // of the table is on the page)
                if (info.ftr_block > 0 and i < info.ftr_idx and (sl.kind == .inside or e.prevReach(&e.seqs.items[sq_i], i, top, false) > ninf))
                    // (Blink's AddPendingRepeatedFooter: at the offset past the last row and its border spacing,
                    // at most where it ends exactly at the page end, i.e. the start of its reserved space)
                    try e.reps.append(e.a, .{ .node = info.ftr, .page = e.page, .y = @min(e.cutY(n, top, pg.end) + info.spacing, pg.end) });
            }
            if (e.style(n).breaks.clone) {
                const cp = e.clonePg(n, pg);
                next += cp.next - pg.next;
                pg = cp;
            }
            if (tables_on and k == .group) {
                // the cells spanning rows that the break cuts align their content at their top too
                const sq = &e.seqs.items[sq_i];
                const lim = if (sl.kind == .inside) i + 1 else i;
                // (from the row this page resumed at: one cutting an earlier page end was aligned then)
                var p: u32 = if (stt.started) @min(stt.@"resume", lim) else 0;
                while (p < lim) : (p += 1) {
                    const r = sq.items[p].node;
                    const rt = e.itemTop(sq, p, top);
                    const ns = e.t.nodes.items;
                    var c = ns[r].first_child;
                    while (c != no_node) : (c = ns[c].next_sibling) {
                        if (ns[c].style.display != .table_cell or !(e.lay(c).h > e.lay(r).h + eps)) continue;
                        const ra = e.cellRealign(c, rt + e.lay(c).y, pg_in.end);
                        if (ra != 0) e.shiftKids(c, ra);
                    }
                }
            }
            var d: f32 = 0;
            if (sl.kind == .before) {
                const sq = &e.seqs.items[sq_i];
                const reach = e.prevReach(sq, i, top, true);
                const band_top = e.bandTop(sq, i, j, top);
                // content resumes at the page start, below what an earlier page left overflowing; the
                // margins (and row gap) adjoining an unforced break are truncated, any other distance
                // to the content before (clearance) stays; the margin after a forced break stays
                var gap: f32 = 0;
                if (sq.items[i].flow) gap = @max(e.lay(sq.items[i].node).margin.top, 0);
                var p = i;
                while (p > 0 and !sq.items[p - 1].flow) p -= 1;
                if (p > 0) gap = @max(gap, e.lay(sq.items[p - 1].node).margin.bottom);
                if (k == .bands) gap += @max(tr.resolveLp(e.style(n).gap[1], 0), 0);
                // (a column flex container never pulls an item up: Blink's flex fragmentation moves an
                // item down to the page start only when it began before it, so an item that the gap
                // carried past the page end keeps its distance; takumi golden paged-header-footer)
                const ns = e.style(n);
                if (k == .bands and ns.display == .flex and (ns.flex_direction == .column or ns.flex_direction == .column_reverse)) {
                    // (but the block-end margin of the item before, where it reaches past the page
                    // start, is truncated there: the item's own margin and the gap stay; takumi
                    // window_scenes.rs report.html on 90 px pages, Chrome likewise)
                    gap = 0;
                    if (p > 0 and reach < next) {
                        const mb = @max(e.lay(sq.items[p - 1].node).margin.bottom, 0);
                        gap = std.math.clamp(reach + mb - next, 0, mb);
                    }
                }
                var target = @max(@max(next, reach), band_top - gap);
                // (content that overflows the page and is left behind: what follows starts the next page)
                const stays = k == .block and e.overflowStays(sq, i, top, pg_in.end);
                if (stays) target = next;
                if (sl.forced and !sl.trunc and sq.items[i].flow) {
                    // (a flex container keeps the row gap before an item resumed after a forced break:
                    // takumi / Blink's flex fragmentation offsets it from the break by its unfragmented offset)
                    var fgap: f32 = 0;
                    if (k == .bands and i > 0 and e.style(n).display == .flex) fgap = @max(tr.resolveLp(e.style(n).gap[1], 0), 0);
                    target = (if (stays) next else @max(next, reach)) + @max(e.lay(sq.items[i].node).margin.top, 0) + fgap;
                }
                d = target - band_top;
                try e.lazyShift(sq_i, i, d);
                if (sl.forced and !sl.trunc and k == .block and sq.items[i].flow and i + 1 < sq.items.len and sq.items[i + 1].flow) {
                    // an empty box the margins collapsed through: after the forced break before it the
                    // margins of the box after it no longer collapse with those above, it keeps its
                    // block-start margin below the empty box (Blink: the margin strut restarts at the break)
                    const el = e.lay(sq.items[i].node);
                    const nl = e.lay(sq.items[i + 1].node);
                    if (el.h == 0) {
                        const want = @max(@max(el.margin.bottom, 0), @max(nl.margin.top, 0));
                        const extra = want - (nl.y - el.y);
                        if (extra > eps) {
                            try e.lazyShift(sq_i, i + 1, extra);
                            d += extra;
                        }
                    }
                }
                stt.child_inside = false;
                stt.forced_resume = sl.forced and !sl.trunc;
            } else {
                if (j == i + 1) {
                    const sq = &e.seqs.items[sq_i];
                    const c = sq.items[i].node;
                    d = try e.apply(c, e.itemTop(sq, i, top), pg);
                    // (a column flex container counts the block decorations a broken
                    // `box-decoration-break: clone` item clones as none of the item's content: the items
                    // after it move by its growth less them; takumi / Blink flex fragmentation
                    // `cloned_block_decorations`)
                    const ns = e.style(n);
                    if (k == .bands and e.style(c).breaks.clone and ns.display == .flex and (ns.flex_direction == .column or ns.flex_direction == .column_reverse)) {
                        const cl = e.lay(c);
                        d = @max(d - (cl.border.top + cl.border.bottom + cl.padding.top + cl.padding.bottom), 0);
                    }
                } else d = try e.applyBand(sq_i, i, j, top, pg);
                try e.lazyShift(sq_i, j, d);
                stt.child_inside = true;
            }
            stt.@"resume" = i;
            stt.started = true;
            return e.grow(n, sq_i, d);
        }

        noinline fn applyBand(e: *Self, sq_i: u32, i: u32, j: u32, top: f32, pg: Pg) Error!f32 {
            var old_bottom: f32 = ninf;
            // (the end of the line the stretched items reach: without what the rows a page break
            // grew in a stretched table add, `TableStretch`)
            var old_line: f32 = ninf;
            var k = i;
            while (k < j) : (k += 1) {
                const sq = &e.seqs.items[sq_i];
                if (!sq.items[k].flow) continue;
                const c = sq.items[k].node;
                old_bottom = @max(old_bottom, e.itemTop(sq, k, top) + e.lay(c).h);
                old_line = @max(old_line, e.itemTop(sq, k, top) + e.lay(c).h - e.stretchExcess(c));
            }
            var new_bottom: f32 = ninf;
            var new_line: f32 = ninf;
            k = i;
            while (k < j) : (k += 1) {
                var sq = &e.seqs.items[sq_i];
                if (!sq.items[k].flow) continue;
                const c = sq.items[k].node;
                const ct = e.itemTop(sq, k, top);
                const cst = &e.st[c];
                if (cst.realign != 0 and !cst.done) {
                    e.shiftKids(c, cst.realign);
                    cst.realign = 0;
                }
                const excess = e.stretchExcess(c);
                cst.full = ct + e.lay(c).h - excess >= old_line - eps;
                if (!cst.done) {
                    const cs = e.slot[c];
                    if (cs.stamp == e.stamp and cs.brk and !cs.par) {
                        if (cs.kind == .push) {
                            // A grid item which broke before its first content has an empty
                            // fragment on this page. Its continuation starts at the next
                            // fragment's block start, without its original row alignment
                            // offset (GridLayoutAlgorithm::PlaceGridItemsForFragmentation).
                            const cl = e.lay(c);
                            const resumed_grid_item = tr.has(cl.grid_block_start) and cl.y > cl.grid_block_start + eps;
                            e.lay(c).y += if (resumed_grid_item) pg.next - ct else @max(pg.next - ct, 0);
                            cst.full = false;
                        } else _ = try e.apply(c, ct, pg);
                    } else cst.done = true;
                }
                sq = &e.seqs.items[sq_i];
                new_bottom = @max(new_bottom, e.itemTop(sq, k, top) + e.lay(c).h);
                new_line = @max(new_line, e.itemTop(sq, k, top) + e.lay(c).h - excess);
            }
            // (the band shrinks too: an item whose block-start margin a break truncated ends higher, and
            // when no other item reaches the old end the band ends with it; takumi / Blink flex rows
            // with `align-items: flex-start`)
            const g = if (new_bottom > ninf and old_bottom > ninf) new_bottom - old_bottom else 0;
            if (g > 0) {
                // the items that reached the end of the row keep reaching it (table cells, stretched items)
                k = i;
                while (k < j) : (k += 1) {
                    const sq = &e.seqs.items[sq_i];
                    if (!sq.items[k].flow) continue;
                    const c = sq.items[k].node;
                    if (!e.st[c].full or e.heightDefinite(c)) continue;
                    const cl = e.lay(c);
                    // (a grid item spanning more than one row keeps the block size the grid gave
                    // it: takumi / Blink grow only the rows a break moves content down in)
                    if (comptime @TypeOf(cl.grid_row_span) != void) if (cl.grid_row_span > 1) continue;
                    cl.h = @max(cl.h, new_line - e.itemTop(sq, k, top));
                }
            }
            return g;
        }

        /// How much taller than in its first layout a table stretched in a row flex line is, the
        /// rows a page break grew on a later page (`TableStretch`); 0 for any other box.
        fn stretchExcess(e: *Self, n: u32) f32 {
            for (e.t.paged.table_stretches, e.stretch_excess) |ts, x| if (ts.node == n and ts.segs.len > 1) return x;
            return 0;
        }

        fn grow(e: *Self, n: u32, sq_i: u32, d: f32) f32 {
            if (d == 0) return 0;
            const l = e.lay(n);
            const sq = &e.seqs.items[sq_i];
            l.content_h += d;
            var g: f32 = 0;
            if (!e.heightDefinite(n)) {
                if (sq.slack > 0) {
                    if (d <= sq.slack) {
                        sq.slack -= d;
                    } else {
                        g = d - sq.slack;
                        sq.slack = 0;
                    }
                } else g = d;
            }
            if (g == 0) return 0;
            if (l.h + g < 0) g = -l.h;
            l.h += g;
            if (sq.bottom_abs) {
                const ns = e.t.nodes.items;
                var ch = ns[n].first_child;
                while (ch != no_node) : (ch = ns[ch].next_sibling) {
                    const cs = ns[ch].style;
                    if (cs.display != .none and cs.position == .absolute and cs.inset.top == .auto and cs.inset.bottom != .auto) e.lay(ch).y += g;
                }
            }
            return g;
        }

        noinline fn applyText(e: *Self, n: u32, top: f32, pg_in: Pg, k: u32) Error!f32 {
            const pg = e.clonePg(n, pg_in);
            const stt = &e.st[n];
            const l = e.lay(n);
            const lines = e.linesOf(n);
            stt.started = true;
            if (k >= lines.len) return 0;
            const old = stt.shift;
            const d = @max(pg.next - (top + lines[k].top + old), 0);
            stt.shift = old + d;
            stt.@"resume" = k;
            const nd = &e.t.nodes.items[n];
            if (d != 0 and !nd.measured) {
                // the inline-level boxes on the lines that move
                const cut = lines[k].top + old - eps;
                var ch = nd.first_child;
                while (ch != no_node) : (ch = e.t.nodes.items[ch].next_sibling) {
                    const cs = e.style(ch);
                    if (cs.display == .none) continue;
                    if (cs.position.isOut() and (cs.position == .fixed or cs.inset.top != .auto or cs.inset.bottom != .auto)) continue;
                    const cl = e.lay(ch);
                    // Floats have their own parallel continuation. Move one with the text
                    // only when its anchor starts after the break; its height must not make
                    // a float anchored before the break look like a later inline box.
                    const after_cut = if (floats_on and cs.float != .none) cl.y >= cut else cl.y + cl.h * 0.5 >= cut;
                    if (after_cut) cl.y += d;
                }
            }
            try e.shifts.append(e.a, .{ .node = n, .first_line = k, .dy = stt.shift });
            l.content_h += d;
            if (e.heightDefinite(n)) return 0;
            const ce = lines[lines.len - 1].bottom + stt.shift + l.padding.bottom + l.border.bottom;
            const g = @max(ce - l.h, 0);
            l.h += g;
            return g;
        }

        // ------------------------------------------------------------------------------------ driver

        /// Fragments the flow rooted at `f` over the pages from the one its block start is on.
        fn runFlow(e: *Self, f: u32) Error!void {
            const top = e.absTopOf(f);
            var page = try e.pageAt(top);
            while (true) {
                const pg = try e.window(page);
                e.stamp += 1;
                const r = try e.probe(f, top, pg, false);
                if (!r.brk) {
                    e.applyTrim(f);
                    break;
                }
                _ = try e.apply(f, top, pg);
                if (floats_on and e.style(f).float != .none) try e.recordFloatResume(page + 1, f);
                page += 1;
            }
            e.flush();
        }
        fn drain(e: *Self, qi: *[2]usize) Error!void {
            while (qi[0] < e.pushes.items.len or qi[1] < e.queue.items.len) {
                while (qi[0] < e.pushes.items.len) : (qi[0] += 1) {
                    const n = e.pushes.items[qi[0]];
                    const d = e.st[n].push_y - e.absTopOf(n);
                    if (d > 0) e.lay(n).y += d;
                    e.st[n].pushed = false;
                }
                if (qi[1] < e.queue.items.len) {
                    const n = e.queue.items[qi[1]];
                    qi[1] += 1;
                    // (a box the main flow went on to break itself is done)
                    if (!e.st[n].started) try e.runFlow(n);
                }
            }
        }
        fn push(e: *Self, n: u32, y: f32) Error!void {
            e.st[n].push_y = y;
            if (e.st[n].pushed) return;
            e.st[n].pushed = true;
            try e.pushes.append(e.a, n);
        }

        /// A float that neither fits nor breaks well moves to the next page on its own (Blink positions it
        /// in a parallel flow; the lines beside it are not re-flowed here).
        fn pushFloat(e: *Self, n: u32) Error!void {
            const top = e.absTopOf(n);
            const pg = try e.window(try e.pageAt(top));
            if (top <= pg.start + eps) return;
            e.stamp += 1;
            const r = try e.probe(n, top, pg, false);
            const l = e.lay(n);
            const fits = !r.brk and r.end <= pg.end + eps;
            if (fits or (r.brk and (r.forced or r.appeal == .perfect))) return;
            l.y += pg.next + @max(l.margin.top, 0) - top;
        }

        fn run(e: *Self, root: u32) Error!Pages {
            const ns = e.t.nodes.items;
            if (root >= ns.len) return .{};
            e.st = try e.a.alloc(State, ns.len);
            @memset(e.st, .{});
            e.slot = try e.a.alloc(Slot, ns.len);
            @memset(e.slot, .{});
            const stretches = e.t.paged.table_stretches;
            e.stretch_excess = try e.a.alloc(f32, stretches.len);
            for (stretches, e.stretch_excess) |ts, *x| x.* = if (ts.node < ns.len) @max(e.lay(ts.node).h - ts.h0, 0) else 0;
            for (ns) |*nd| {
                if (nd.style.breaks.page != 0) e.any_names = true;
            }
            // (the root moves first: a start is where the moved content has it)
            if (e.opts.root_shift != 0) e.lay(root).y += e.opts.root_shift;
            if (e.opts.start) |s| if (e.startY(s)) |y| {
                const h = e.opts.start_top orelse y;
                if (h >= 1 and h < 16_777_216) {
                    e.start_h = h;
                    // (the content before the start stays where it is unless it reaches past
                    // page 0, the break moves the start to page 1)
                    e.shift = @min(h - y, 0);
                    e.lay(root).y += e.shift;
                }
            };
            try e.tops.append(e.a, e.opts.origin);
            try e.need(0);
            // (a fixed box keeps where it was laid out against the first page, whatever moves its
            // parent: takumi lays each out on its own against the page area, `FixedTemplate`)
            var fixed_at: std.AutoHashMapUnmanaged(u32, f32) = .empty;
            defer fixed_at.deinit(e.a);
            for (ns, 0..) |*nd, k| {
                if (nd.style.position != .fixed or nd.style.display == .none or k == root) continue;
                try fixed_at.put(e.a, @intCast(k), e.absTopOf(@intCast(k)));
            }

            // 1. the main flow, 2. the flows it left behind, 3. floats and out-of-flow boxes (document order)
            try e.runFlow(root);
            e.main_done = true;
            var qi: [2]usize = .{ 0, 0 };
            try e.drain(&qi);
            if (ns[root].first_child != no_node and !ns[root].measured and ns[root].style.display != .none) {
                var cur = ns[root].first_child;
                walk: while (true) {
                    const s = ns[cur].style;
                    const pk = e.kindOf(ns[cur].parent);
                    const is_abs = s.position == .absolute;
                    const is_float = floats_on and !is_abs and s.float != .none and (pk == .block or pk == .text);
                    const parent_seq = e.st[ns[cur].parent].seq;
                    const row_height = if (parent_seq != no_node) e.seqs.items[parent_seq].h0 else e.lay(ns[cur].parent).h;
                    const is_rowspan = pk == .row and e.lay(cur).h > row_height + eps;
                    // (a clipping box is walked for the absolutely positioned boxes escaping it)
                    var descend = s.display != .none and !ns[cur].measured and e.kindOf(cur) != .mono;
                    // (an atomic inline box is monolithic)
                    if (pk == .text and !is_abs and !is_float) descend = false;
                    const clipped = if (s.position == .fixed) e.insideClip(cur, root) else (is_abs or is_float or is_rowspan) and e.clippedOut(cur, root, false);
                    if (s.display != .none and !clipped) {
                        if (s.position == .fixed) {
                            try e.fixed.append(e.a, cur);
                            // where it was laid out, or, with no block offsets (its static position),
                            // at the top of the page area (takumi-pdf 0.20.0: alone in its page's
                            // layout it starts the page; probe pagination.fixed)
                            if (fixed_at.get(cur)) |y0| {
                                const want = if (s.inset.top == .auto and s.inset.bottom == .auto) @max(e.lay(cur).margin.top, 0) + e.shift else y0;
                                e.lay(cur).y += want - e.absTopOf(cur);
                            }
                            // (laid out against the first page: not moved by `Options.start_top`)
                            e.lay(cur).y -= e.shift;
                            descend = false;
                        } else if (is_abs or is_float or is_rowspan) {
                            if (is_float) try e.pushFloat(cur);
                            if (!e.st[cur].started) try e.runFlow(cur);
                            try e.drain(&qi);
                        }
                    }
                    if (descend and ns[cur].first_child != no_node) {
                        cur = ns[cur].first_child;
                        continue;
                    }
                    while (true) {
                        if (ns[cur].next_sibling != no_node) {
                            cur = ns[cur].next_sibling;
                            break;
                        }
                        cur = ns[cur].parent;
                        if (cur == root or cur == no_node) break :walk;
                    }
                }
            }
            if (tables_on) e.syncTables();

            // the pages: down to the block end of everything that paints
            var extent: f32 = 0;
            const moved: ?f32 = if (e.opts.extent_fn) |f| f(e.opts.ctx) else null;
            if (moved) |v| {
                extent = v;
                try e.extentOf(root, &extent, ninf);
            } else {
                // (takumi measures the boxes of the page the root ends on: monolithic content that a
                // page before left overflowing adds no page)
                // (the top of the last page known that starts above the root's end; no page is added)
                const rl = e.lay(root);
                const y_end = @max(rl.y + rl.h - eps, rl.y);
                var lo: usize = 0;
                var hi: usize = e.tops.items.len - 2;
                while (lo < hi) {
                    const mid = lo + (hi - lo + 1) / 2;
                    if (e.tops.items[mid] <= y_end) lo = mid else hi = mid - 1;
                }
                try e.extentOf(root, &extent, e.tops.items[lo]);
            }
            var count: u32 = 1;
            while (true) {
                try e.need(count - 1);
                if (!(e.tops.items[count] < extent - eps)) break;
                count += 1;
            }

            var out: Pages = .{};
            errdefer out.deinit(e.a);
            out.pages = try e.a.alloc(Page, count);
            for (out.pages, 0..) |*p, i| p.* = .{ .top = e.tops.items[i], .height = e.tops.items[i + 1] - e.tops.items[i] };
            out.names = try e.a.alloc(u32, count);
            for (out.names, 0..) |*nm, i| nm.* = e.names.items[i];
            if (e.opts.record_starts) {
                out.starts = try e.a.dupe(Start, e.starts.items[0..count]);
                for (e.starts.items[0..count]) |*s| {
                    s.branches = &.{};
                    s.side_flows = &.{};
                }
            }
            out.start_page = @intFromBool(e.start_h != null);
            std.sort.heap(LineShift, e.shifts.items, {}, shiftLess);
            out.line_shifts = try e.a.dupe(LineShift, e.shifts.items);
            var n_rep: usize = 0;
            for (e.reps.items) |r| n_rep += @intFromBool(r.page < count);
            n_rep += e.fixed.items.len * (count - 1);
            out.repeats = try e.a.alloc(Repeat, n_rep);
            var w: usize = 0;
            for (e.reps.items) |r| {
                if (r.page >= count) continue;
                out.repeats[w] = .{ .node = r.node, .page = r.page, .dy = r.y - e.absTopOf(r.node) };
                w += 1;
            }
            // a fixed box is laid out against the first page and painted on every page
            for (e.fixed.items) |f| {
                var p: u32 = 1;
                while (p < count) : (p += 1) {
                    out.repeats[w] = .{ .node = f, .page = p, .dy = e.tops.items[p] };
                    w += 1;
                }
            }
            std.sort.heap(Repeat, out.repeats, {}, repeatLess);
            return out;
        }

        /// Block end of everything painted in the subtree of `root` (clipped content and fixed boxes aside).
        /// Monolithic content (one fragment) that starts above `last_top` (the top of the page the root
        /// ends on) counts for nothing.
        fn extentOf(e: *Self, root: u32, extent: *f32, last_top: f32) Error!void {
            const ns = e.t.nodes.items;
            const stack = try e.a.alloc(f32, tr.max_depth + 8);
            defer e.a.free(stack);
            var sp: usize = 0;
            var base: f32 = 0;
            var cur = root;
            while (true) {
                const s = ns[cur].style;
                const l = e.lay(cur);
                var descend = false;
                const early_mono = cur != root and base + l.y < last_top - eps and e.monoLeaf(cur);
                if (s.display != .none and (s.position != .fixed or cur == root) and !early_mono) {
                    const y = base + l.y;
                    // (the content of a clipping box adds nothing, but the absolutely positioned
                    // boxes escaping it do)
                    if (cur == root or !e.clippedOut(cur, root, true)) extent.* = @max(extent.*, y + l.h);
                    descend = !ns[cur].measured and ns[cur].first_child != no_node and sp < stack.len;
                    if (descend) {
                        stack[sp] = base;
                        sp += 1;
                        base = y;
                        cur = ns[cur].first_child;
                        continue;
                    }
                }
                while (true) {
                    if (cur == root) return;
                    if (ns[cur].next_sibling != no_node) {
                        cur = ns[cur].next_sibling;
                        break;
                    }
                    cur = ns[cur].parent;
                    if (cur == no_node or sp == 0) return;
                    sp -= 1;
                    base = stack[sp];
                }
            }
        }

        /// Brings the paint geometry of the tables that were fragmented (`Tree.tableGeom`) in line with the
        /// moved rows (parts with a node of their own; anonymous rows / cells keep their geometry).
        fn syncTables(e: *Self) void {
            const ns = e.t.nodes.items;
            for (e.t.table_geoms.items) |*g| {
                if (g.node >= ns.len or e.st[g.node].seq == no_node) continue;
                g.grid_h += e.lay(g.node).h - e.seqs.items[e.st[g.node].seq].h0;
                for (g.secs) |*sec| {
                    if (sec.node == no_node or sec.node == g.node or ns[sec.node].parent != g.node) continue;
                    sec.y = e.lay(sec.node).y;
                    sec.h = e.lay(sec.node).h;
                }
                for (g.rows) |*row| {
                    if (row.node == no_node or row.node == g.node or row.sec >= g.secs.len) continue;
                    const sec = g.secs[row.sec];
                    const in_sec = sec.node != no_node and ns[row.node].parent == sec.node;
                    row.y = if (in_sec) e.lay(row.node).y else e.lay(row.node).y - sec.y;
                    row.h = e.lay(row.node).h;
                }
                for (g.cells) |*cell| {
                    if (cell.anon or cell.node == no_node or cell.node >= ns.len) continue;
                    var y: f32 = 0;
                    var cur = cell.node;
                    var guard: u32 = 0;
                    while (cur != g.node and cur != no_node and guard < 4) : (guard += 1) {
                        y += e.lay(cur).y;
                        cur = ns[cur].parent;
                    }
                    if (cur != g.node) continue;
                    cell.y = y;
                    cell.h = e.lay(cell.node).h;
                }
            }
        }
    };
}

fn shiftLess(_: void, a: LineShift, b: LineShift) bool {
    return if (a.node != b.node) a.node < b.node else a.first_line < b.first_line;
}
fn repeatLess(_: void, a: Repeat, b: Repeat) bool {
    return if (a.page != b.page) a.page < b.page else a.node < b.node;
}
fn itemLess(lays: []const tr.Layout, a: Item, b: Item) bool {
    const ya = lays[a.node].y;
    const yb = lays[b.node].y;
    return if (ya != yb) ya < yb else a.node < b.node;
}
