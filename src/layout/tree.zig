//! Node storage, per-node measurement cache, node dispatch, leaf layout, absolute positioning and rounding.
//!
//! Internal conventions (shared by flex.zig / block.zig / grid.zig):
//!  * axis index 0 = horizontal (width), 1 = vertical (height)
//!  * rects are `[4]f32` ordered left, top, right, bottom so `r[axis]` is the start edge and `r[axis + 2]` the end
//!  * "optional" lengths are plain f32 with NaN meaning "none" (NaN propagates through + and -, which gives
//!    taffy's `maybe_add`/`maybe_sub` for free)
//!  * available space is an f32: finite = definite, +inf = max-content, -inf = min-content
const std = @import("std");
const st = @import("style.zig");
const flex = @import("flex.zig");
const block = @import("block.zig");
const grid = @import("grid.zig");
const table = @import("table.zig");
const inline_row = @import("inline.zig");
const flow = @import("flow.zig");
const fl = @import("floats.zig");

const Style = st.Style;
pub const NodeId = u32;

pub const NONE: f32 = std.math.nan(f32);
pub const MAXC: f32 = std.math.inf(f32);
pub const MINC: f32 = -std.math.inf(f32);
pub const no_node: u32 = std.math.maxInt(u32);
/// Maximum nesting depth of the node tree; deeper trees make `compute` fail with `error.TooDeep`.
pub const max_depth = 512;

pub const Error = error{ OutOfMemory, TooDeep };

pub inline fn has(v: f32) bool {
    return v == v;
}
pub inline fn orElse(v: f32, d: f32) f32 {
    return if (v == v) v else d;
}
/// min(v, o) where a NaN `o` is ignored (NaN `v` stays NaN).
pub inline fn minO(v: f32, o: f32) f32 {
    return if (o < v) o else v;
}
pub inline fn maxO(v: f32, o: f32) f32 {
    return if (o > v) o else v;
}
pub inline fn clampO(v: f32, lo: f32, hi: f32) f32 {
    return maxO(minO(v, hi), lo);
}
pub inline fn isDef(a: f32) bool {
    return @abs(a) < MAXC;
}
/// definite available space -> value, otherwise none
pub inline fn defOrNone(a: f32) f32 {
    return if (isDef(a)) a else NONE;
}
inline fn same(a: f32, b: f32) bool {
    return a == b or (a != a and b != b);
}

/// Non-finite inputs (untrusted styles) count as "none".
pub inline fn fin(v: f32) f32 {
    return if (std.math.isFinite(v)) v else NONE;
}

pub fn resolveDim(d: st.Dim, base: f32) f32 {
    return switch (d) {
        .px => |v| fin(v),
        .percent => |p| fin(p * base),
        .calc => |c| fin(if (c.percent != 0) c.px + c.percent * base else c.px),
        else => NONE,
    };
}
pub fn resolveLp(d: st.LengthPercentage, base: f32) f32 {
    return switch (d) {
        .px => |v| orElse(fin(v), 0),
        .percent => |p| orElse(fin(p * base), 0),
        .calc => |c| orElse(fin(c.px + orElse(c.percent * base, 0)), 0),
    };
}

pub const MarginSet = struct {
    pos: f32 = 0,
    neg: f32 = 0,
    pub fn with(a: MarginSet, m: f32) MarginSet {
        return if (m >= 0) .{ .pos = @max(a.pos, m), .neg = a.neg } else .{ .pos = a.pos, .neg = @min(a.neg, m) };
    }
    pub fn merge(a: MarginSet, b: MarginSet) MarginSet {
        return .{ .pos = @max(a.pos, b.pos), .neg = @min(a.neg, b.neg) };
    }
    pub fn resolve(a: MarginSet) f32 {
        return a.pos + a.neg;
    }
};

/// Inputs of a node computation (taffy's LayoutInput).
pub const In = struct {
    /// border-box size forced by the parent (NaN = not known)
    known: [2]f32 = .{ NONE, NONE },
    /// parent content-box size, for percentage resolution (NaN = indefinite)
    parent: [2]f32 = .{ NONE, NONE },
    /// available space for the margin box
    avail: [2]f32 = .{ MAXC, MAXC },
    /// true = perform layout (positions children), false = only compute this node's size
    layout: bool = false,
    /// taffy SizingMode::ContentSize: ignore the node's own `size` style (parent already applied it)
    content_sizing: bool = false,
    /// with content_sizing: the axis being measured (its min/max are ignored as well)
    cs_axis: u8 = 0,
    /// size-only requests: true = only the width is needed (the returned height is then NaN)
    width_only: bool = false,
    /// block layout only: may this node's top/bottom margins collapse with its children's
    collapse: bool = false,
    /// `known[1]` is a flexed size that is not definite for the percentages of the children
    indef_h: bool = false,
    /// The request measures the main size of a column flex item: the intrinsic block size of an
    /// aspect-ratio box is then clamped by its transferred inline min/max sizes (Blink's flex
    /// `BlockSizeFunc`), and its initial block size is indefinite.
    flex_main: bool = false,
};

pub const Out = struct {
    size: [2]f32,
    /// extent of content measured from the border-box origin
    content: [2]f32 = .{ 0, 0 },
    /// first baseline, distance from border-box top (NaN = none)
    baseline: f32 = NONE,
    /// baseline of the last line box of a block container / inline content (NaN = none): what an
    /// inline-block sits on
    last_baseline: f32 = NONE,
    top_margin: MarginSet = .{},
    bottom_margin: MarginSet = .{},
    collapse_through: bool = false,
};

/// Computed geometry of a node.
pub const Layout = struct {
    /// Unaligned grid-area block start, relative to the grid, for PDF continuation.
    grid_block_start: if (st.frag_enabled) f32 else void = if (st.frag_enabled) NONE else {},
    /// Grid rows the item's area spans (0: not a grid item), for PDF continuation.
    grid_row_span: if (st.frag_enabled) u16 else void = if (st.frag_enabled) 0 else {},
    /// border-box position relative to the parent's border-box origin
    x: f32 = 0,
    y: f32 = 0,
    /// border-box size
    w: f32 = 0,
    h: f32 = 0,
    /// extent of the node's content (in-flow + absolute descendants) measured from its border-box origin;
    /// compare against w/h to detect overflow
    content_w: f32 = 0,
    content_h: f32 = 0,
    padding: st.Edges(f32) = .all(0),
    border: st.Edges(f32) = .all(0),
    /// used margins (auto margins resolved; block margins after collapsing)
    margin: st.Edges(f32) = .all(0),
    /// first baseline as distance from the border-box top; NaN when the node has no baseline
    baseline: f32 = NONE,
};

/// Sizes a measured leaf. `known`: content-box dimensions that are already fixed (null = to be determined);
/// `available`: content-box space for the dimensions that are not known (min_content / max_content ask for
/// the intrinsic sizes). Returns the content-box size. Results are cached per node and request, so for a
/// text leaf in a flex row the typical calls are: max-content, min-content, then the final known width.
/// The available height is always reported as max_content (an auto height is content-based).
pub const MeasureFn = *const fn (ctx: *anyopaque, node: NodeId, known: [2]?f32, available: [2]st.AvailableSpace) [2]f32;
/// Optional: first and last baseline offsets from the content-box top for a measured leaf of the given
/// content size (NaN = the leaf has no baseline, e.g. an image).
pub const BaselineFn = *const fn (ctx: *anyopaque, node: NodeId, content_size: [2]f32) [2]f32;

/// An inline-level child of an inline formatting context (`Display.inline_row` node), see `InlineFn`.
pub const InlineItem = struct {
    node: NodeId,
    kind: Kind,
    /// atomic, set by the engine before the callback: margin-box size and the baseline as a distance from
    /// the margin-box top (the bottom margin edge when the box has no baseline)
    width: f32 = 0,
    height: f32 = 0,
    baseline: f32 = 0,
    /// set by the callback, relative to the content-box origin: the margin-box position of an atomic item,
    /// the static position of an out-of-flow one (`placed` = false: the item is hidden)
    x: f32 = 0,
    y: f32 = 0,
    placed: bool = false,
    /// out-of-flow, set by the callback: the static position is the inline END of the box (right-to-left
    /// content: the box's right edge sits at `x`)
    rtl: bool = false,
    /// (engine) left / top margin
    margin: [2]f32 = .{ 0, 0 },

    pub const Kind = enum(u8) { atomic, float, out_of_flow };
};

pub const InlineBand = struct { x0: f32, x1: f32, next_y: f32 };

/// Request / result of an `InlineFn` call.
pub const InlineIo = struct {
    /// content-box width the lines are broken at: definite, `+inf` (max-content) or `-inf` (min-content)
    width: f32,
    /// a layout pass: item positions are wanted (and the caller should keep its line layout for painting);
    /// false = only `size`
    layout: bool = false,
    /// only `size[0]` is needed
    width_only: bool = false,
    /// the children of the node that are not `display: none`, in document order (empty for a measured leaf)
    items: []InlineItem = &.{},
    /// results: content size (widest line, bottom of the last line), first / last baseline from the
    /// content-box top (NaN = no line box)
    size: [2]f32 = .{ 0, 0 },
    first_baseline: f32 = NONE,
    last_baseline: f32 = NONE,
    /// Exclusion space of the block formatting context (both null when no float can affect the lines).
    /// `band`: the inline range [x0, x1] free for a line box spanning [y, y + h) (from the content-box
    /// origin) and the y below which it may widen (NaN: it is the full width already).
    /// `float`: place float item `item` for a line at `y` holding `used` px of content in a range of
    /// `avail` px; `how`: 0 = at or below y, 1 = beside the line if it fits (false = it does not: call
    /// again with 2 once the line is finished), 2 = below (y = the line's bottom), 3 = take back the
    /// float the last call placed (nothing else was placed since).
    band_fn: ?*const fn (io: *const InlineIo, y: f32, h: f32) InlineBand = null,
    float_fn: ?*const fn (io: *const InlineIo, item: u32, y: f32, used: f32, avail: f32, how: u8) bool = null,
    /// (engine)
    host: *anyopaque = undefined,
};

/// Lays out the inline content (text + `io.items`) of an inline formatting context: breaks lines of
/// `io.width`, aligns the atomic items on them and reports sizes / positions through `io`. Called for
/// `Display.inline_row` nodes, and for measured leaves flagged `Style.is_inline_content` when floats may
/// intrude (such a leaf is otherwise sized by the `MeasureFn`). Needs `Config.inline_fn`.
pub const InlineFn = *const fn (ctx: *anyopaque, node: NodeId, io: *InlineIo) void;

pub const Options = struct {
    /// taffy-style rounding to whole pixels (edges are rounded in absolute space, sizes derived from them)
    round: bool = false,
    /// Lay out on Blink's 1/64 px LayoutUnit grid, reproducing its arithmetic where it rounds: lengths and
    /// percentages truncate toward zero, flex free space is distributed in rounded units with the remainder
    /// carried (LineFlexer), centring halves by integer division, distributed alignment spreads remainders
    /// (LayoutUnitDiffuser), grid fr tracks truncate and carry. Ignored when `round` is set.
    /// Measured sizes are used as returned: return them on the 1/64 grid for exact parity.
    quantize64: bool = false,
    /// called for measured leaves during the final layout pass; without it a leaf's baseline is its bottom
    baseline: ?BaselineFn = null,
    /// inline formatting driver (see `InlineFn`)
    inline_fn: ?InlineFn = null,
};

const Node = struct {
    /// shared between nodes with equal styles (`internStyle`): never written through
    style: *const Style,
    parent: u32 = no_node,
    first_child: u32 = no_node,
    last_child: u32 = no_node,
    next_sibling: u32 = no_node,
    child_count: u32 = 0,
    measured: bool = false,
    /// Replaced elements with auto width use their intrinsic width instead of filling a block.
    replaced: bool = false,
    /// index into Tree.pending of the latest deferred absolute layout of this node
    pending: u32 = no_node,
    /// style contains percentages that resolve against the parent size (part of the cache key then)
    pct: bool = false,
    /// no size/min/max/aspect-ratio styles: content sizing == inherent sizing
    plain: bool = false,
    ratio: bool = false,
    /// the subtree contains a float (or a box with `clear`): its layout depends on the exclusion space
    float_sub: bool = false,
    /// set by table.zig for a `border-collapse: collapse` table it laid out: `Layout.border` / `.padding`
    /// hold the used (collapsed) values it wrote, which `setLayout` then keeps
    table_box: bool = false,
    /// index into Tree.table_geoms of this table's record (validated by `tableGeom`)
    table_geom: u32 = no_node,
};

const Entry = struct {
    known: [2]f32,
    avail: [2]f32,
    parent: [2]f32,
    size: [2]f32,
    /// bit0 content_sizing, bit1 collapse, bit2 indef_h
    flags: u8,
};

const n_slots = 9;
const flag_width_only: u8 = 16;
const Cache = struct {
    /// bit i = measure slot i valid; bit 15 = final valid
    valid: u16 = 0,
    slots: [n_slots]Entry = undefined,
    final: Entry = undefined,
    final_out: Out = undefined,
};

/// Bump allocator with stack discipline whose blocks never move (so slices stay valid across recursion).
pub const Scratch = struct {
    chunks: std.ArrayList([]align(16) u8) = .empty,
    cur: u32 = 0,
    off: usize = 0,

    pub const Mark = struct { cur: u32, off: usize };

    pub fn mark(s: *Scratch) Mark {
        return .{ .cur = s.cur, .off = s.off };
    }
    pub fn release(s: *Scratch, m: Mark) void {
        s.cur = m.cur;
        s.off = m.off;
    }
    /// One uninitialised `T` (for per-node algorithm state that must not live on the call stack).
    pub fn create(s: *Scratch, a: std.mem.Allocator, comptime T: type) Error!*T {
        return @ptrCast(@alignCast(try s.raw(a, @sizeOf(T))));
    }
    pub fn alloc(s: *Scratch, a: std.mem.Allocator, comptime T: type, n: usize) Error![]T {
        const bytes = std.math.mul(usize, n, @sizeOf(T)) catch return error.OutOfMemory;
        const p = try s.raw(a, bytes);
        return @as([*]T, @ptrCast(@alignCast(p)))[0..n];
    }
    fn raw(s: *Scratch, a: std.mem.Allocator, bytes_in: usize) Error![*]align(16) u8 {
        const bytes = std.mem.alignForward(usize, bytes_in, 16);
        while (true) {
            if (s.cur < s.chunks.items.len) {
                const c = s.chunks.items[s.cur];
                if (c.len - s.off >= bytes) {
                    const p: [*]align(16) u8 = @alignCast(c.ptr + s.off);
                    s.off += bytes;
                    return p;
                }
                s.cur += 1;
                s.off = 0;
                continue;
            }
            const want = @max(bytes, @as(usize, 32 * 1024));
            const mem = try a.alignedAlloc(u8, .@"16", want);
            errdefer a.free(mem);
            try s.chunks.append(a, mem);
        }
    }
    fn deinit(s: *Scratch, a: std.mem.Allocator) void {
        for (s.chunks.items) |c| a.free(c);
        s.chunks.deinit(a);
    }
};

const default_style: Style = .{};
const zero_layout: Layout = .{};

/// Resolved box model of a node against a containing size.
pub const Box = struct {
    padding: [4]f32,
    border: [4]f32,
    /// auto margins resolve to 0 here
    margin: [4]f32,
    margin_auto: [4]bool,
    /// padding + border per axis
    pb: [2]f32,
    /// border-box sizes (NaN = auto / none), aspect-ratio applied
    size: [2]f32,
    min: [2]f32,
    max: [2]f32,

    pub inline fn marginSum(b: *const Box, axis: usize) f32 {
        return b.margin[axis] + b.margin[axis + 2];
    }
};

fn rect(comptime T: type, e: st.Edges(T)) [4]T {
    return .{ e.left, e.top, e.right, e.bottom };
}
pub fn toEdges(r: [4]f32) st.Edges(f32) {
    return .{ .left = r[0], .top = r[1], .right = r[2], .bottom = r[3] };
}

/// aspect-ratio transfer: border-box size of `axis` derived from the border-box size `other` of the other
/// axis (the ratio applies to the box selected by box-sizing). NaN when there is no ratio.
pub fn ratioTransfer(s: *const Style, b: *const Box, axis: usize, other: f32) f32 {
    const r = s.aspect_ratio orelse return NONE;
    if (!(r > 0) or !has(other)) return NONE;
    const cbx = s.box_sizing == .content_box;
    const v = if (cbx) @max(other - b.pb[1 - axis], 0) else other;
    const tv = if (axis == 0) v * r else v / r;
    return if (cbx) tv + b.pb[axis] else tv;
}

/// Resolve padding/border/margin/size/min/max of `s`. Percent padding & margin resolve against `basis[0]`
/// (inline size, 0 when indefinite), sizes against `basis` per axis (auto when indefinite).
pub fn resolveBox(b: *Box, s: *const Style, basis: [2]f32) void {
    const pad = rect(st.LengthPercentage, s.padding);
    const mar = rect(st.Dim, s.margin);
    b.border = rect(f32, s.border);
    for (0..4) |i| {
        b.padding[i] = @max(resolveLp(pad[i], basis[0]), 0);
        b.border[i] = @max(b.border[i], 0);
        b.margin_auto[i] = mar[i] == .auto;
        b.margin[i] = orElse(resolveDim(mar[i], basis[0]), 0);
    }
    if (s.rtl or s.mirror_out) mirrorBox(b, s);
    b.pb = .{ b.padding[0] + b.padding[2] + b.border[0] + b.border[2], b.padding[1] + b.padding[3] + b.border[1] + b.border[3] };
    const adj: [2]f32 = if (s.box_sizing == .content_box) b.pb else .{ 0, 0 };
    const raw: [3]*const [2]st.Dim = .{ &s.size, &s.min_size, &s.max_size };
    const dst: [3]*[2]f32 = .{ &b.size, &b.min, &b.max };
    for (raw, dst) |r, d| {
        const v: [2]f32 = .{ resolveDim(r[0], basis[0]), resolveDim(r[1], basis[1]) };
        d.* = .{ v[0] + adj[0], v[1] + adj[1] };
    }
    if (s.aspect_ratio != null and !has(b.size[0]) and !has(b.size[1])) {
        // both dimensions automatic: block-axis min/max transfer to the inline axis through the ratio
        if (!has(b.min[0])) b.min[0] = ratioTransfer(s, b, 0, b.min[1]);
        if (!has(b.max[0])) b.max[0] = ratioTransfer(s, b, 0, b.max[1]);
    }
}

/// True for a container laid out in mirrored space (see `Style.rtl`).
pub inline fn mirrors(s: *const Style) bool {
    return s.rtl and (s.display == .flex or s.display == .grid);
}

/// Mirrored space: the box of a mirrored container has its left / right padding and border swapped, the
/// box of one of its children the left / right margins.
noinline fn mirrorBox(b: *Box, s: *const Style) void {
    if (mirrors(s)) {
        std.mem.swap(f32, &b.padding[0], &b.padding[2]);
        std.mem.swap(f32, &b.border[0], &b.border[2]);
    }
    if (s.mirror_out) swapMargins(b);
}
pub fn swapMargins(b: *Box) void {
    std.mem.swap(f32, &b.margin[0], &b.margin[2]);
    std.mem.swap(bool, &b.margin_auto[0], &b.margin_auto[2]);
}

/// Size of a container fixed by its styles (taffy "styled_based_known_dimensions").
pub fn styledKnown(in: *const In, b: *const Box) [2]f32 {
    var k = in.known;
    for (0..2) |a| {
        if (has(k[a])) continue;
        if (has(b.min[a]) and has(b.max[a]) and b.max[a] <= b.min[a]) {
            k[a] = b.min[a];
        } else if (!in.content_sizing) {
            k[a] = clampO(b.size[a], b.min[a], b.max[a]);
        }
        k[a] = maxO(k[a], b.pb[a]);
    }
    // aspect ratio transfer after clamping (width known through min/max or known dims, height auto)
    return k;
}

fn stylePlain(s: *const Style) bool {
    inline for (.{ s.size, s.min_size, s.max_size }) |v| {
        if (v[0] != .auto or v[1] != .auto) return false;
    }
    return s.aspect_ratio == null;
}

fn stylePct(s: *const Style) bool {
    inline for (.{ s.size, s.min_size, s.max_size }) |v| {
        if (v[0].hasPercent() or v[1].hasPercent()) return true;
    }
    inline for (.{ "top", "right", "bottom", "left" }) |f| {
        if (@field(s.margin, f).hasPercent() or @field(s.padding, f).hasPercent()) return true;
    }
    return false;
}

pub const Pending = struct { node: u32, parent: u32, sp: StaticPos };

/// How a display value is laid out when it is reached through `computeNode`.
const Algo = enum { flex, block, grid, table, inline_row, none };
fn algoOf(d: st.Display) Algo {
    return switch (d) {
        .flex => .flex,
        .grid => .grid,
        .none => .none,
        // (a stray row / row group is wrapped in an anonymous table; other stray table parts are blocks)
        .table, .inline_table, .table_row, .table_row_group, .table_header_group, .table_footer_group => .table,
        .inline_row => .inline_row,
        .block, .table_cell, .table_caption, .table_column, .table_column_group => .block,
    };
}

pub const StaticPos = struct {
    /// static-position rectangle relative to the container's border-box origin: x, y, w, h
    rect: [4]f32,
    /// alignment inside the rectangle per axis: 0 = start, 1 = center, 2 = end
    al: [2]u8 = .{ 0, 0 },
    /// stretch to the rectangle when size is auto and insets are auto (grid areas)
    stretch: [2]bool = .{ false, false },
    /// (engine) the rectangle is in the mirrored space of its container
    mirrored: bool = false,
};

/// Compile-time feature selection: code of a disabled feature is not referenced (and so not emitted).
/// With a feature off its display values degrade: table displays lay out as `block`, floats as in-flow
/// blocks, `inline_row` as `block`.
pub const Config = struct {
    tables: bool = true,
    floats: bool = true,
    inline_row: bool = true,
    /// `inline_row` nodes are inline formatting contexts driven by `Options.inline_fn` (flow.zig: real
    /// lines of text and atomic inlines, lines shortened by floats) instead of the built-in rows of atomic
    /// boxes (inline.zig, then not compiled).
    inline_fn: bool = false,
};

pub const Tree = TreeWith(.{});

pub fn TreeWith(comptime cfg: Config) type {
    return struct {
        const Self = @This();
        pub const config = cfg;
        pub const Static = StaticPos;

        alloc: std.mem.Allocator,
        nodes: std.ArrayList(Node) = .empty,
        /// the styles added last (`internStyle`): siblings of a generated document mostly repeat
        /// them, and a node keeps a pointer to one instead of a copy of its own
        style_recent: [8]*const Style = undefined,
        style_n: u8 = 0,
        style_next: u8 = 0,
        /// every stored style (freed by `deinit`)
        styles: std.ArrayList(*Style) = .empty,
        layouts: std.ArrayList(Layout) = .empty,
        caches: std.ArrayList(Cache) = .empty,
        scratch: Scratch = .{},
        pending: std.ArrayList(Pending) = .empty,
        root: u32 = no_node,
        /// lay out on Blink's 1/64 px LayoutUnit grid (Options.quantize64)
        q64: bool = false,
        ctx: *anyopaque = undefined,
        measure_fn: ?MeasureFn = null,
        baseline_fn: ?BaselineFn = null,
        inline_fn: ?InlineFn = null,
        depth: u32 = 0,
        /// result slot of size-only requests (`measureChild`)
        tmp_out: Out = undefined,
        // floats (see block.zig): any float / clear in the tree, the current block formatting context, the
        // border-box origin (in BFC coordinates) handed to the block child about to be computed
        has_floats: bool = false,
        /// a style with float / clear was added since the last scan (cheap pre-filter for `markFloats`)
        float_seen: bool = false,
        bfc: ?*fl.Bfc = null,
        bfc_org: [2]f32 = .{ 0, 0 },
        float_rects: std.ArrayList(fl.Rect) = .empty,
        /// paint geometry of the tables laid out by the last `compute` (see `tableGeom`)
        table_geoms: std.ArrayList(table.Geom) = .empty,
        /// statistics of the last `compute`: number of MeasureFn invocations / node computations (cache misses)
        measure_calls: u32 = 0,
        node_computes: u32 = 0,
        /// Paged output (PDF feature only, else `void`): see `fragment.PagedState`. While `paged.page_h` > 0,
        /// `position: fixed` boxes resolve against an initial containing block that tall (the page area)
        /// although the tree is laid out with an unbounded available height.
        paged: if (st.frag_enabled) @import("fragment.zig").PagedState else void = if (st.frag_enabled) .{} else {},

        /// All memory (nodes, layouts, caches, scratch) comes from `alloc`; a per-render arena is the expected choice.
        pub fn init(alloc: std.mem.Allocator) Self {
            return .{ .alloc = alloc };
        }

        pub fn deinit(self: *Self) void {
            for (self.styles.items) |sp| self.alloc.destroy(sp);
            self.styles.deinit(self.alloc);
            self.nodes.deinit(self.alloc);
            self.layouts.deinit(self.alloc);
            self.caches.deinit(self.alloc);
            self.pending.deinit(self.alloc);
            self.float_rects.deinit(self.alloc);
            self.clearTableGeoms();
            self.table_geoms.deinit(self.alloc);
            self.scratch.deinit(self.alloc);
            self.* = undefined;
        }

        /// Pre-size the node arrays for `n` nodes in all (optional). The node, layout and cache lists
        /// grow side by side, so in a bump arena none of them can grow in place and every growth
        /// leaves the old buffers behind (about twice the final size for a large tree).
        pub fn ensureCapacity(self: *Self, n: usize) !void {
            try self.nodes.ensureTotalCapacityPrecise(self.alloc, n);
            try self.layouts.ensureTotalCapacityPrecise(self.alloc, n);
            try self.caches.ensureTotalCapacityPrecise(self.alloc, n);
        }

        /// Frees the per-node measure caches of the last `compute` (a laid-out tree whose layout is
        /// only read from now on; a later `compute` makes them again).
        pub fn dropCaches(self: *Self) void {
            self.caches.clearAndFree(self.alloc);
        }

        /// Adds a node. The style is copied; slices inside it (grid track lists) stay caller-owned.
        pub fn addNode(self: *Self, s: Style) !NodeId {
            const id: u32 = @intCast(self.nodes.items.len);
            if (id == no_node) return error.OutOfMemory;
            try self.nodes.append(self.alloc, .{ .style = try self.internStyle(&s), .pct = stylePct(&s), .plain = stylePlain(&s), .ratio = s.aspect_ratio != null });
            if (s.float != .none or s.clear != .none) self.float_seen = true;
            errdefer self.nodes.items.len -= 1;
            try self.layouts.append(self.alloc, .{});
            errdefer self.layouts.items.len -= 1;
            try self.caches.append(self.alloc, .{});
            return id;
        }

        /// Appends `child` (which must not have a parent yet) to `parent`'s child list.
        /// Fails with `error.InvalidNode` for unknown ids, a child that already has a parent, or a cycle.
        pub fn appendChild(self: *Self, parent: NodeId, child: NodeId) !void {
            const n = self.nodes.items;
            if (parent >= n.len or child >= n.len or parent == child or n[child].parent != no_node) return error.InvalidNode;
            // `child` has no parent, so a cycle is only possible when it is the root of `parent`'s tree
            var up = parent;
            while (n[up].parent != no_node) up = n[up].parent;
            if (up == child) return error.InvalidNode;
            n[child].parent = parent;
            try self.setMirrorOut(child, mirrors(n[parent].style));
            n[child].next_sibling = no_node;
            if (n[parent].last_child == no_node) n[parent].first_child = child else n[n[parent].last_child].next_sibling = child;
            n[parent].last_child = child;
            n[parent].child_count += 1;
        }

        /// Marks a leaf as having intrinsic content provided by the MeasureFn (text, images).
        /// Measured nodes are always treated as leaves.
        pub fn setMeasured(self: *Self, node: NodeId, measured: bool) void {
            if (node < self.nodes.items.len) self.nodes.items[node].measured = measured;
        }

        /// Marks a measured replaced element such as an image.
        pub fn setReplaced(self: *Self, node: NodeId, replaced: bool) void {
            if (node < self.nodes.items.len) self.nodes.items[node].replaced = replaced;
        }

        /// Style of `node` (the default style for an unknown id).
        pub fn style(self: *const Self, node: NodeId) *const Style {
            return if (node < self.nodes.items.len) self.nodes.items[node].style else &default_style;
        }

        /// A stored copy of `s`: one of the recently stored styles when equal to it, else a new one.
        pub fn internStyle(self: *Self, s: *const Style) error{OutOfMemory}!*const Style {
            for (self.style_recent[0..self.style_n]) |cand| {
                if (std.meta.eql(cand.*, s.*)) return cand;
            }
            try self.styles.ensureUnusedCapacity(self.alloc, 1);
            const kept = try self.alloc.create(Style);
            kept.* = s.*;
            self.styles.appendAssumeCapacity(kept);
            self.style_recent[self.style_next] = kept;
            self.style_next = @intCast((self.style_next + 1) % self.style_recent.len);
            if (self.style_n < self.style_recent.len) self.style_n += 1;
            return kept;
        }

        /// Sets the engine-owned `Style.mirror_out` of `node`.
        fn setMirrorOut(self: *Self, node: NodeId, mo: bool) error{OutOfMemory}!void {
            const n = &self.nodes.items[node];
            if (n.style.mirror_out == mo) return;
            var cp = n.style.*;
            cp.mirror_out = mo;
            n.style = try self.internStyle(&cp);
        }

        pub fn setStyle(self: *Self, node: NodeId, s_in: Style) error{OutOfMemory}!void {
            if (node >= self.nodes.items.len) return;
            var s = s_in;
            s.mirror_out = self.nodes.items[node].style.mirror_out;
            self.nodes.items[node].style = try self.internStyle(&s);
            var ch = self.nodes.items[node].first_child;
            while (ch != no_node) : (ch = self.nodes.items[ch].next_sibling) try self.setMirrorOut(ch, mirrors(&s));
            self.nodes.items[node].pct = stylePct(&s);
            self.nodes.items[node].plain = stylePlain(&s);
            self.nodes.items[node].ratio = s.aspect_ratio != null;
            if (s.float != .none or s.clear != .none) self.float_seen = true;
        }

        /// Result of the last `compute` for `node` (zeroed for display:none subtrees and nodes outside the root's subtree).
        pub fn layout(self: *const Self, node: NodeId) *const Layout {
            return if (node < self.layouts.items.len) &self.layouts.items[node] else &zero_layout;
        }

        fn clearTableGeoms(self: *Self) void {
            for (self.table_geoms.items) |*g| {
                self.alloc.free(g.cols);
                self.alloc.free(g.colels);
                self.alloc.free(g.secs);
                self.alloc.free(g.rows);
                self.alloc.free(g.cells);
            }
            self.table_geoms.clearRetainingCapacity();
        }

        /// Paint geometry of the table laid out at `node` by the last `compute`: a table / inline-table node, or a
        /// row / row-group node that is not inside a table (the anonymous table around it). Null for any other
        /// node, when tables are compiled out, and for tables no final layout pass reached.
        pub fn tableGeom(self: *const Self, node: NodeId) ?*const table.Geom {
            if (!cfg.tables or node >= self.nodes.items.len) return null;
            const gi = self.nodes.items[node].table_geom;
            if (gi >= self.table_geoms.items.len) return null;
            const g = &self.table_geoms.items[gi];
            return if (g.node == node) g else null;
        }

        pub inline fn firstChild(self: *const Self, node: u32) u32 {
            return self.nodes.items[node].first_child;
        }
        pub inline fn nextSibling(self: *const Self, node: u32) u32 {
            return self.nodes.items[node].next_sibling;
        }

        /// Lays out the subtree of `root`. The root is treated as a block-level box in a containing block of
        /// `available` size: auto width stretches to a definite available width, auto height is content-sized,
        /// percentages resolve against definite available sizes.
        /// `measure` is called (with `ctx`) for nodes flagged with `setMeasured`; it receives the known content-box
        /// dimensions and the available content-box space and returns the content-box size.
        pub fn compute(self: *Self, root: NodeId, available: [2]st.AvailableSpace, ctx: *anyopaque, measure: MeasureFn, opts: Options) !void {
            if (root >= self.nodes.items.len) return error.InvalidNode;
            // (after `dropCaches`)
            if (self.caches.items.len < self.nodes.items.len) try self.caches.appendNTimes(self.alloc, .{}, self.nodes.items.len - self.caches.items.len);
            for (self.caches.items) |*c| c.valid = 0;
            self.pending.clearRetainingCapacity();
            self.clearTableGeoms();
            self.root = root;
            self.ctx = ctx;
            self.measure_fn = measure;
            self.baseline_fn = opts.baseline;
            self.inline_fn = opts.inline_fn;
            self.depth = 0;
            if (cfg.floats) self.markFloats();
            self.measure_calls = 0;
            self.node_computes = 0;
            self.scratch.release(.{ .cur = 0, .off = 0 });

            var av: [2]f32 = undefined;
            for (0..2) |a| av[a] = switch (available[a]) {
                .definite => |v| if (std.math.isFinite(v)) v else MAXC,
                .min_content => MINC,
                .max_content => MAXC,
            };
            const parent: [2]f32 = .{ defOrNone(av[0]), defOrNone(av[1]) };
            const s = self.nodes.items[root].style;
            if (s.display == .none) {
                self.hide(root);
                return;
            }
            self.q64 = opts.quantize64 and !opts.round;
            var b: Box = undefined;
            self.rbox(&b, s, parent);
            var in: In = .{ .parent = parent, .avail = av, .layout = true };
            in.known = styledKnown(&in, &b);
            if (!has(in.known[0]) and has(parent[0]) and !s.size[0].isKeyword()) {
                // block-level stretch fit (the root is blockified)
                if (has(in.known[1])) in.known[0] = clampO(self.ratio(s, &b, 0, in.known[1]), b.min[0], b.max[0]);
                if (!has(in.known[0])) in.known[0] = clampO(parent[0] - b.marginSum(0), b.min[0], b.max[0]);
                in.known[0] = @max(in.known[0], b.pb[0]);
            }
            var out: Out = undefined;
            try self.computeNode(root, &in, &out);
            self.setLayout(root, .{ b.margin[0], b.margin[1] }, &out, &b);
            try self.flushPending(parent);
            if (opts.round or opts.quantize64) try self.roundAll(root, if (opts.round) 1 else 64);
        }

        /// The in-flow children of a flex / grid container (not `display: none`, not out of flow) in
        /// order-modified document order (`Style.order`, stable), allocated in the scratch arena.
        pub fn orderedItems(self: *Self, node: u32) Error![]u32 {
            const ns = self.nodes.items;
            var count: usize = 0;
            var ch = ns[node].first_child;
            while (ch != no_node) : (ch = ns[ch].next_sibling) {
                const cs = ns[ch].style;
                if (cs.display != .none and !cs.position.isOut()) count += 1;
            }
            const buf = try self.scratch.alloc(self.alloc, u32, count * 2);
            var a = buf[0..count];
            var any = false;
            var i: usize = 0;
            ch = ns[node].first_child;
            while (ch != no_node) : (ch = ns[ch].next_sibling) {
                const cs = ns[ch].style;
                if (cs.display == .none or cs.position.isOut()) continue;
                a[i] = ch;
                i += 1;
                any = any or cs.order != 0;
            }
            if (!any or count < 2) return a;
            // bottom-up merge sort (stable, O(n log n) whatever the input)
            var b = buf[count..];
            var width: usize = 1;
            while (width < count) : (width *= 2) {
                var lo: usize = 0;
                while (lo < count) : (lo += 2 * width) {
                    const mid = @min(lo + width, count);
                    const hi = @min(lo + 2 * width, count);
                    var l = lo;
                    var r = mid;
                    var k = lo;
                    while (k < hi) : (k += 1) {
                        if (l < mid and (r >= hi or ns[a[l]].style.order <= ns[a[r]].style.order)) {
                            b[k] = a[l];
                            l += 1;
                        } else {
                            b[k] = a[r];
                            r += 1;
                        }
                    }
                }
                const tmp = a;
                a = b;
                b = tmp;
            }
            return a;
        }

        /// Flags the ancestors of floats / cleared boxes (their layout depends on the exclusion space).
        fn markFloats(self: *Self) void {
            self.bfc = null;
            self.has_floats = false;
            if (!self.float_seen) return;
            self.float_rects.clearRetainingCapacity();
            const ns = self.nodes.items;
            var any = false;
            for (ns) |*n| {
                n.float_sub = false;
                any = any or n.style.float != .none or n.style.clear != .none;
            }
            self.has_floats = any;
            if (!any) {
                self.float_seen = false;
                return;
            }
            for (ns) |*n| {
                if (n.style.float == .none and n.style.clear == .none) continue;
                var p = n.parent;
                while (p != no_node and !ns[p].float_sub) : (p = ns[p].parent) ns[p].float_sub = true;
            }
        }

        // ------------------------------------------------------------------------------------------------
        // internals shared with the algorithm files

        /// float -> LayoutUnit: truncation toward zero onto the 1/64 px grid (no-op unless quantize64).
        pub inline fn qt(self: *const Self, v: f32) f32 {
            return if (self.q64) @trunc(v * 64) / 64 else v;
        }
        /// LayoutUnit / integer: integer division of 1/64 units (truncating toward zero).
        pub inline fn div(self: *const Self, v: f32, k: f32) f32 {
            return if (self.q64) @trunc(@trunc(v * 64) / k) / 64 else v / k;
        }
        pub fn dim(self: *const Self, d: st.Dim, base: f32) f32 {
            return self.qt(resolveDim(d, base));
        }
        pub fn lp(self: *const Self, d: st.LengthPercentage, base: f32) f32 {
            return self.qt(resolveLp(d, base));
        }
        pub fn ratio(self: *const Self, s: *const Style, b: *const Box, axis: usize, other: f32) f32 {
            return self.qt(ratioTransfer(s, b, axis, other));
        }
        /// `resolveBox` on the layout-unit grid.
        pub fn rbox(self: *const Self, b: *Box, s: *const Style, basis: [2]f32) void {
            resolveBox(b, s, basis);
            if (self.q64) {
                for (0..4) |i| {
                    b.padding[i] = self.qt(b.padding[i]);
                    b.border[i] = self.qt(b.border[i]);
                    b.margin[i] = self.qt(b.margin[i]);
                }
                const pb: [2]f32 = .{ b.padding[0] + b.padding[2] + b.border[0] + b.border[2], b.padding[1] + b.padding[3] + b.border[1] + b.border[3] };
                const adj: [2]f32 = if (s.box_sizing == .content_box) .{ pb[0] - b.pb[0], pb[1] - b.pb[1] } else .{ 0, 0 };
                b.pb = pb;
                for (0..2) |a| {
                    b.size[a] = self.qt(b.size[a] + adj[a]);
                    b.min[a] = self.qt(b.min[a] + adj[a]);
                    b.max[a] = self.qt(b.max[a] + adj[a]);
                }
            }
        }

        /// Box of the node being computed: like `rbox` against `in.parent`, but under content sizing the
        /// min/max constraints of the axis being measured are dropped (the parent applies them itself).
        pub fn sbox(self: *const Self, b: *Box, s: *const Style, in: *const In) void {
            self.rbox(b, s, in.parent);
            if (in.content_sizing and !has(in.known[in.cs_axis & 1])) {
                b.min[in.cs_axis & 1] = NONE;
                b.max[in.cs_axis & 1] = NONE;
            }
        }

        /// Inline size of a container through its aspect ratio from a known block size (Blink's
        /// ComputeInlineSizeForFragment with `may_apply_aspect_ratio`). Returns NaN when there is no transfer.
        /// With visible overflow and `min-width: auto` the automatic minimum (css-sizing-4 §5.1.2) applies: the
        /// result is then only a floor, `in.avail[0]` is switched to min-content and the caller takes the
        /// larger of its min-content width and the returned value. Otherwise `in.known[0]` is set.
        pub fn ratioWidth(self: *const Self, s: *const Style, b: *const Box, in: *In) f32 {
            if (s.aspect_ratio == null or has(in.known[0]) or !has(in.known[1])) return NONE;
            const w = self.ratio(s, b, 0, in.known[1]);
            if (!has(w)) return NONE;
            const rw = @max(clampO(w, b.min[0], b.max[0]), b.pb[0]);
            // (a flex parent asking for the max-content flex base size takes the pure ratio size: the
            // automatic minimum enters through its own min-content request)
            const flex_basis = in.content_sizing and in.cs_axis == 0 and in.avail[0] == MAXC;
            if (s.overflow_x == .visible and s.min_size[0] == .auto and !flex_basis) {
                in.avail[0] = MINC;
            } else in.known[0] = rw;
            return rw;
        }

        /// Applies the aspect ratio to a container's known border-box dimensions (call again once the inline size
        /// is settled). A ratio-determined height of a box with visible overflow and automatic min-height is only
        /// a floor (the automatic content-based minimum still applies): it is then returned instead of being
        /// stored in `known[1]`; NaN otherwise.
        pub fn applyRatio(self: *const Self, s: *const Style, b: *const Box, known: *[2]f32) f32 {
            if (s.aspect_ratio == null) return NONE;
            if (has(known[1]) and !has(known[0])) {
                const w = self.ratio(s, b, 0, known[1]);
                if (has(w)) known[0] = @max(clampO(w, b.min[0], b.max[0]), b.pb[0]);
            } else if (has(known[0]) and !has(known[1])) {
                const h = self.ratio(s, b, 1, known[0]);
                if (!has(h)) return NONE;
                const rh = @max(clampO(h, b.min[1], b.max[1]), b.pb[1]);
                if (s.overflow_x == .visible and s.overflow_y == .visible and s.min_size[1] == .auto) return rh;
                known[1] = rh;
            }
            return NONE;
        }

        pub fn setLayout(self: *Self, node: u32, pos: [2]f32, out: *const Out, b: *const Box) void {
            if (cfg.tables) {
                // a collapsing table reports its used border (half of its outer collapsed edges) and no padding
                const n = &self.nodes.items[node];
                if (n.table_box and n.style.border_collapse and n.style.display.isTable()) {
                    const l = &self.layouts.items[node];
                    l.* = .{ .x = pos[0], .y = pos[1], .w = out.size[0], .h = out.size[1], .content_w = out.content[0], .content_h = out.content[1], .padding = l.padding, .border = l.border, .margin = toEdges(b.margin), .baseline = out.baseline };
                    return;
                }
            }
            self.layouts.items[node] = .{
                .x = pos[0],
                .y = pos[1],
                .w = out.size[0],
                .h = out.size[1],
                .content_w = out.content[0],
                .content_h = out.content[1],
                .padding = toEdges(b.padding),
                .border = toEdges(b.border),
                .margin = toEdges(b.margin),
                .baseline = out.baseline,
            };
            if (mirrors(self.nodes.items[node].style)) {
                // (the box was resolved in the node's mirrored space)
                const l = &self.layouts.items[node];
                std.mem.swap(f32, &l.padding.left, &l.padding.right);
                std.mem.swap(f32, &l.border.left, &l.border.right);
            }
        }

        /// Mirrored container `node` (border-box width `w`) has just placed its children in mirrored
        /// space: converts them to physical coordinates (and the static positions of the absolutely
        /// positioned children it deferred).
        noinline fn flipChildren(self: *Self, node: u32, w: f32) void {
            const ns = self.nodes.items;
            var ch = ns[node].first_child;
            while (ch != no_node) : (ch = ns[ch].next_sibling) {
                const cs = ns[ch].style;
                if (cs.display == .none) continue;
                if (cs.position.isOut()) {
                    const pi = ns[ch].pending;
                    if (pi < self.pending.items.len and self.pending.items[pi].node == ch and self.pending.items[pi].parent == node) {
                        const sp = &self.pending.items[pi].sp;
                        if (sp.mirrored) {
                            sp.mirrored = false;
                            sp.rect[0] = w - sp.rect[0] - sp.rect[2];
                            sp.al[0] = 2 - @min(sp.al[0], 2);
                        }
                        continue;
                    }
                }
                const l = &self.layouts.items[ch];
                l.x = w - l.x - l.w;
                std.mem.swap(f32, &l.margin.left, &l.margin.right);
            }
        }

        /// Grow `content` (extent from the container's border-box origin) by a laid-out child.
        pub fn accumContent(self: *const Self, content: *[2]f32, child: u32) void {
            const l = &self.layouts.items[child];
            const s = self.nodes.items[child].style;
            const ex = if (s.overflow_x == .visible) @max(l.w, l.content_w) else l.w;
            const ey = if (s.overflow_y == .visible) @max(l.h, l.content_h) else l.h;
            content[0] = @max(content[0], l.x + ex);
            content[1] = @max(content[1], l.y + ey);
        }

        /// Zero the layout of a display:none subtree.
        pub fn hide(self: *Self, root: u32) void {
            const n = self.nodes.items;
            var cur = root;
            while (true) {
                self.layouts.items[cur] = .{};
                if (n[cur].first_child != no_node) {
                    cur = n[cur].first_child;
                    continue;
                }
                while (true) {
                    if (cur == root) return;
                    if (n[cur].next_sibling != no_node) {
                        cur = n[cur].next_sibling;
                        break;
                    }
                    cur = n[cur].parent;
                    if (cur == no_node) return;
                }
            }
        }

        /// Size-only request: border-box size of `node` along `axis` (mutates the request flags of `in`).
        pub inline fn measureChild(self: *Self, node: u32, in: *In, axis: usize) Error!f32 {
            in.layout = false;
            in.width_only = axis == 0;
            try self.computeNode(node, in, &self.tmp_out);
            return self.tmp_out.size[axis];
        }
        /// Horizontal offset of a relatively positioned box in the space its parent places it in: `left` wins
        /// over `right`; in an `rtl` block container `right` wins; in mirrored space the two swap roles.
        pub fn relX(self: *const Self, cs: *const Style, base: f32, rtl: bool) f32 {
            const l = self.dim(cs.inset.left, base);
            const r = self.dim(cs.inset.right, base);
            if (cs.mirror_out) return orElse(r, -orElse(l, 0));
            if (rtl and has(r)) return -r;
            return orElse(l, -orElse(r, 0));
        }
        /// Sum of the two margins of `s` along `axis` (auto = 0; percentages against `base`, 0 when indefinite).
        pub fn marginSumOf(self: *const Self, s: *const Style, axis: usize, base: f32) f32 {
            const a = if (axis == 0) s.margin.left else s.margin.top;
            const b = if (axis == 0) s.margin.right else s.margin.bottom;
            return self.qt(orElse(resolveDim(a, base), 0)) + self.qt(orElse(resolveDim(b, base), 0));
        }

        fn slotOf(in: *const In) u4 {
            const kw = has(in.known[0]);
            const kh = has(in.known[1]);
            if (kw and kh) return 0;
            if (kw) return @as(u4, 1) + @intFromBool(in.avail[1] == MINC);
            if (kh) return @as(u4, 3) + @intFromBool(in.avail[0] == MINC);
            return @as(u4, 5) + @intFromBool(in.avail[1] == MINC) + 2 * @as(u4, @intFromBool(in.avail[0] == MINC));
        }

        fn matches(e: *const Entry, in: *const In, pct: bool, flags: u8, has_ratio: bool) bool {
            // (a full result also answers a width-only request)
            if (e.flags != flags and e.flags != (flags & ~flag_width_only)) return false;
            inline for (0..2) |a| {
                // (a known dimension equal to the cached result is the same request, unless it would newly
                // trigger an aspect-ratio transfer)
                if (!(same(in.known[a], e.known[a]) or (in.known[a] == e.size[a] and !has_ratio))) return false;
                if (!has(in.known[a]) and in.avail[a] != e.avail[a]) return false;
                if (pct and !same(in.parent[a], e.parent[a])) return false;
            }
            return true;
        }

        /// Cached node computation (taffy's compute_cached_layout + dispatch).
        /// Recursion discipline (the wasm shadow stack is small): this function and the per-display algorithms
        /// it dispatches to are `noinline` and keep their aggregate state in `scratch`, so one nesting level
        /// costs a few hundred bytes of stack.
        /// `in` is normalised in place (callers must not rely on its flags / available space afterwards);
        /// the result is written to `out`.
        pub noinline fn computeNode(self: *Self, node: u32, in: *In, out: *Out) Error!void {
            const n = &self.nodes.items[node];
            const c = &self.caches.items[node];
            if (n.plain) in.content_sizing = false;
            if (!has(in.known[0])) {
                // width: min-content / max-content size the box under that constraint whatever the space is
                switch (n.style.size[0]) {
                    .min_content => in.avail[0] = MINC,
                    .max_content => in.avail[0] = MAXC,
                    else => {},
                }
            }
            if (!in.content_sizing or (has(in.known[0]) and has(in.known[1]))) in.cs_axis = 0;
            if (!has(in.known[1])) in.indef_h = false;
            if (!(n.ratio or n.pct) or has(in.known[1])) in.flex_main = false;
            // The available height never influences a result (auto heights are content-based) and a known
            // dimension makes its available space irrelevant: normalise both for better cache hits.
            in.avail[1] = MAXC;
            if (has(in.known[0])) in.avail[0] = MAXC;
            if (in.layout or has(in.known[0])) in.width_only = false;
            const flags: u8 = @as(u8, @intFromBool(in.content_sizing)) | (@as(u8, @intFromBool(in.collapse)) << 1) | (@as(u8, @intFromBool(in.indef_h)) << 2) |
                ((in.cs_axis & 1) << 3) | (if (in.width_only) flag_width_only else 0) | (@as(u8, @intFromBool(in.flex_main)) << 5);
            var leaf = n.child_count == 0 or n.measured;
            const algo = algoOf(n.style.display);
            // floats: a block container inside a formatting context with floats depends on the exclusion
            // space and on its position in it, which are not part of the cache key; so does inline content
            // (its lines are shortened by the floats)
            const in_floats = cfg.floats and self.has_floats and in.collapse and self.bfc != null and
                !block.isRoot(n.style, in) and (n.float_sub or self.float_rects.items.len > self.bfc.?.start);
            const ictx = cfg.inline_fn and in_floats and n.style.is_inline_content and (n.measured or algo == .inline_row) and has(in.known[0]);
            const fctx = ictx or (in_floats and !leaf and algo == .block);
            const as_flow = cfg.inline_fn and self.inline_fn != null and (ictx or (algo == .inline_row and !n.measured));
            if (as_flow) leaf = false;
            if (!fctx and c.valid & 0x8000 != 0 and matches(&c.final, in, n.pct, flags, n.ratio)) {
                out.* = c.final_out;
                return;
            }
            if (!in.layout) {
                var bits = c.valid & 0x1ff;
                while (bits != 0) {
                    const i: u4 = @intCast(@ctz(bits));
                    bits &= bits - 1;
                    if (matches(&c.slots[i], in, n.pct, flags, n.ratio)) {
                        out.* = .{ .size = c.slots[i].size };
                        return;
                    }
                }
            }
            if (self.depth >= max_depth) return error.TooDeep;
            self.depth += 1;
            defer self.depth -= 1;
            self.node_computes += 1;

            // (a flex / grid container continued at another page width: its items keep the layout
            // they had at its first fragment's width, its own box takes the new one)
            var frozen_in: In = undefined;
            const frozen_w: ?f32 = if (comptime st.frag_enabled) blk: {
                if (algo != .flex and algo != .grid or as_flow or leaf or !has(in.known[0])) break :blk null;
                for (self.paged.frozen_widths) |fw| if (fw.node == node) break :blk fw.w;
                break :blk null;
            } else null;
            const in_used: *const In = if (frozen_w) |w| blk: {
                frozen_in = in.*;
                frozen_in.known[0] = w;
                break :blk &frozen_in;
            } else in;
            if (as_flow) {
                try flow.compute(self, node, in, out, ictx);
            } else if (leaf) {
                self.computeLeaf(node, in, out);
            } else switch (algo) {
                .flex => try flex.compute(self, node, in_used, out),
                .block => try block.compute(self, node, in, out),
                .grid => try grid.compute(self, node, in_used, out),
                .table => if (cfg.tables) try table.compute(self, node, in, out) else try block.compute(self, node, in, out),
                .inline_row => if (cfg.inline_row and !cfg.inline_fn) try inline_row.compute(self, node, in, out) else try block.compute(self, node, in, out),
                .none => out.* = .{ .size = .{ 0, 0 } },
            }
            if (in.layout and n.style.rtl and !leaf and !as_flow and mirrors(self.nodes.items[node].style)) self.flipChildren(node, out.size[0]);
            if (frozen_w != null) out.size[0] = in.known[0];

            if (fctx) return;
            var e: *Entry = &c.final;
            if (in.layout) {
                c.final_out = out.*;
                c.valid |= 0x8000;
            } else {
                const i = slotOf(in);
                e = &c.slots[i];
                c.valid |= @as(u16, 1) << i;
            }
            e.known = in.known;
            e.avail = in.avail;
            e.parent = in.parent;
            e.size = out.size;
            e.flags = flags;
        }

        noinline fn computeLeaf(self: *Self, node: u32, in: *const In, out: *Out) void {
            const n = &self.nodes.items[node];
            const s = n.style;
            var b: Box = undefined;
            self.sbox(&b, s, in);
            var size = in.known;
            const mn = b.min;
            const mx = b.max;
            // The root can arrive with the initial containing block's width as a known size. That
            // fills ordinary block boxes, but an auto-sized replaced element keeps its intrinsic
            // width (subject to its min/max constraints) instead of inheriting that fill width.
            if (n.replaced and !has(b.size[0])) size[0] = NONE;
            if (!in.content_sizing) {
                for (0..2) |a| size[a] = orElse(size[a], b.size[a]);
            }
            if (has(size[0]) != has(size[1])) {
                // aspect-ratio transfer from the definite (clamped) dimension
                const a: usize = @intFromBool(has(size[0]));
                const tv = self.ratio(s, &b, a, clampO(size[1 - a], mn[1 - a], mx[1 - a]));
                if (has(tv)) size[a] = tv;
            }
            if (n.measured and n.child_count != 0) {
                // children of a measured node are not laid out
                var ch = n.first_child;
                while (ch != no_node) : (ch = self.nodes.items[ch].next_sibling) self.hide(ch);
            }
            const prevents_collapse = s.display != .block or s.overflow_x != .visible or s.overflow_y != .visible or
                s.position.isOut() or b.padding[1] > 0 or b.padding[3] > 0 or b.border[1] > 0 or b.border[3] > 0 or
                size[1] > 0 or mn[1] > 0 or n.measured;

            var measured: [2]f32 = .{ 0, 0 };
            var content_known: [2]f32 = .{ NONE, NONE };
            for (0..2) |a| {
                if (has(size[a])) content_known[a] = @max(clampO(size[a], mn[a], mx[a]) - b.pb[a], 0);
            }
            if (n.measured and !(has(content_known[0]) and has(content_known[1]))) {
                if (self.measure_fn) |mf| {
                    var kn: [2]?f32 = undefined;
                    var av: [2]st.AvailableSpace = undefined;
                    for (0..2) |a| {
                        kn[a] = if (has(content_known[a])) content_known[a] else null;
                        if (has(content_known[a])) {
                            av[a] = .{ .definite = content_known[a] };
                        } else {
                            var v = in.avail[a] - b.marginSum(a);
                            if (has(mx[a])) v = mx[a];
                            if (isDef(v)) {
                                av[a] = .{ .definite = @max(clampO(v, mn[a], mx[a]) - b.pb[a], 0) };
                            } else av[a] = if (v < 0) .min_content else .max_content;
                        }
                    }
                    self.measure_calls += 1;
                    measured = mf(self.ctx, node, kn, av);
                    for (0..2) |a| {
                        if (!(measured[a] >= 0) or measured[a] == MAXC) measured[a] = 0;
                    }
                }
            }
            out.* = .{ .size = undefined };
            for (0..2) |a| {
                const c = if (has(content_known[a])) content_known[a] else measured[a];
                if (has(content_known[a])) measured[a] = content_known[a];
                out.size[a] = @max(clampO(orElse(size[a], c + b.pb[a]), mn[a], mx[a]), b.pb[a]);
            }
            if (!n.measured and !has(size[0]) and !has(size[1])) {
                // an empty box with an aspect ratio: the block size follows the (content-based) inline size
                const rh = self.ratio(s, &b, 1, out.size[0]);
                if (has(rh)) out.size[1] = @max(clampO(rh, mn[1], mx[1]), b.pb[1]);
            }
            out.content = .{ b.border[0] + b.padding[0] + measured[0], b.border[1] + b.padding[1] + measured[1] };
            if (n.measured and in.layout) {
                if (self.baseline_fn) |bf| {
                    const cb: [2]f32 = .{ @max(out.size[0] - b.pb[0], 0), @max(out.size[1] - b.pb[1], 0) };
                    const bl = bf(self.ctx, node, cb);
                    if (has(bl[0])) out.baseline = b.border[1] + b.padding[1] + bl[0];
                    if (has(bl[1])) out.last_baseline = b.border[1] + b.padding[1] + bl[1];
                }
            }
            out.collapse_through = !prevents_collapse and out.size[1] == 0;
        }

        /// Lays out an absolutely positioned child of `container` now, or defers it when the container is not the
        /// child's containing block (`position: static`): it is then resolved against the nearest positioned
        /// ancestor (or the viewport) once the whole tree has been laid out.
        pub fn placeAbsolute(self: *Self, container: u32, child: u32, area: *const [4]f32, sp: *const Static) Error!void {
            const mir = mirrors(self.nodes.items[container].style);
            if (self.nodes.items[container].style.position != .static and self.nodes.items[child].style.position != .fixed) return self.layoutAbsolute(child, area, sp, mir);
            self.hide(child);
            self.nodes.items[child].pending = @intCast(self.pending.items.len);
            try self.pending.append(self.alloc, .{ .node = child, .parent = container, .sp = sp.* });
            self.pending.items[self.pending.items.len - 1].sp.mirrored = mir;
        }

        fn flushPending(self: *Self, viewport: [2]f32) Error!void {
            var i: usize = 0;
            while (i < self.pending.items.len) : (i += 1) {
                const e = self.pending.items[i];
                if (self.nodes.items[e.node].pending != i) continue;
                var off: [2]f32 = .{ 0, 0 };
                var a = e.parent;
                var area: [4]f32 = undefined;
                while (true) {
                    const l = &self.layouts.items[a];
                    if (self.nodes.items[a].style.position != .static and self.nodes.items[e.node].style.position != .fixed) {
                        area = .{ l.border.left - off[0], l.border.top - off[1], l.w - l.border.left - l.border.right, l.h - l.border.top - l.border.bottom };
                        break;
                    }
                    off[0] += l.x;
                    off[1] += l.y;
                    if (a == self.root or self.nodes.items[a].parent == no_node) {
                        // initial containing block
                        var vw = viewport[0];
                        var vh = viewport[1];
                        if (comptime st.frag_enabled) {
                            // takumi-pdf lays a repeated fixed box out on its own against the page area as an
                            // integral `Viewport` (`print_viewport`: width and height truncated to whole px)
                            if (self.paged.page_h > 0 and self.nodes.items[e.node].style.position == .fixed) {
                                vw = @trunc(self.paged.page_w);
                                vh = @trunc(self.paged.page_h);
                            } else if (self.paged.page_h > 0 and !(vh > 0 and std.math.isFinite(vh))) {
                                // (an absolute box: the initial containing block is the first page's area,
                                // takumi `PagedLayout::page_space` / Blink's page area)
                                vh = self.paged.page_h;
                            }
                        }
                        area = .{ -off[0], -off[1], orElse(vw, l.w), orElse(vh, l.h) };
                        break;
                    }
                    a = self.nodes.items[a].parent;
                }
                try self.layoutAbsolute(e.node, &area, &e.sp, false);
            }
        }

        /// Lays out one `position:absolute` child. `area` = containing block (x, y, w, h relative to the container's
        /// border-box origin; normally its padding box).
        const AbsState = struct { b: Box, ins: [4]f32, known: [2]f32, avail: [2]f32, cb: [2]f32, pos: [2]f32, in: In, out: Out };

        pub noinline fn layoutAbsolute(self: *Self, child: u32, area: *const [4]f32, sp: *const Static, mirrored: bool) Error!void {
            const mark = self.scratch.mark();
            defer self.scratch.release(mark);
            const c = try self.scratch.create(self.alloc, AbsState);
            const s = self.nodes.items[child].style;
            c.cb = .{ area[2], area[3] };
            const cb = &c.cb;
            self.rbox(&c.b, s, cb.*);
            const b = &c.b;
            const ins = &c.ins;
            const known = &c.known;
            const avail = &c.avail;
            {
                const ins_raw = rect(st.Dim, s.inset);
                for (0..4) |i| ins[i] = self.dim(ins_raw[i], cb[i & 1]);
            }
            // `mirrored`: `area` and `sp` are in the mirrored space of the child's parent (which flips the
            // child afterwards); else they are physical and the margin swap of `rbox` is undone
            if (mirrored) std.mem.swap(f32, &ins[0], &ins[2]);
            if (s.mirror_out and !mirrored) swapMargins(b);

            known.* = .{ clampO(b.size[0], b.min[0], b.max[0]), clampO(b.size[1], b.min[1], b.max[1]) };
            for (0..2) |a| {
                const both = has(ins[a]) and has(ins[a + 2]);
                const room = if (both or !sp.stretch[a]) cb[a] - orElse(ins[a], 0) - orElse(ins[a + 2], 0) - b.marginSum(a) else sp.rect[a + 2] - b.marginSum(a);
                avail[a] = @max(room, 0);
                if (!has(known[a]) and (both or (sp.stretch[a] and !has(ins[a]) and !has(ins[a + 2])))) {
                    // stretch between the insets unless the other axis + aspect ratio determines this one
                    const o = 1 - a;
                    if ((s.aspect_ratio != null and has(known[o])) or s.size[a].isKeyword()) continue;
                    known[a] = clampO(avail[a], b.min[a], b.max[a]);
                }
            }
            if (has(known[0]) != has(known[1])) {
                const a: usize = @intFromBool(has(known[0]));
                known[a] = clampO(self.ratio(s, b, a, known[1 - a]), b.min[a], b.max[a]);
            }
            for (0..2) |a| known[a] = maxO(known[a], b.pb[a]);
            c.in = .{ .known = known.*, .parent = cb.*, .avail = .{ avail[0] + b.marginSum(0), avail[1] + b.marginSum(1) } };
            if (!has(known[0]) or !has(known[1])) {
                try self.computeNode(child, &c.in, &c.out);
                for (0..2) |a| {
                    if (!has(known[a])) known[a] = @max(clampO(c.out.size[a], b.min[a], b.max[a]), b.pb[a]);
                }
                c.in.known = known.*;
            }
            c.in.layout = true;
            try self.computeNode(child, &c.in, &c.out);
            const size = &c.out.size;

            const pos = &c.pos;
            for (0..2) |a| {
                const e = a + 2;
                if (has(ins[a]) and has(ins[e])) {
                    const free = cb[a] - ins[a] - ins[e] - size[a] - b.marginSum(a);
                    const cnt: f32 = @floatFromInt(@as(u8, @intFromBool(b.margin_auto[a])) + @intFromBool(b.margin_auto[e]));
                    if (cnt > 0) {
                        if (free >= 0 or a == 1) {
                            if (b.margin_auto[a]) b.margin[a] = self.div(free, cnt);
                            if (b.margin_auto[e]) b.margin[e] = self.div(free, cnt);
                        } else if (b.margin_auto[e]) b.margin[e] = free;
                    }
                }
                if (has(ins[a])) {
                    pos[a] = area[a] + ins[a] + b.margin[a];
                } else if (has(ins[e])) {
                    pos[a] = area[a] + cb[a] - ins[e] - b.margin[e] - size[a];
                } else {
                    const r0 = sp.rect[a];
                    const rs = sp.rect[a + 2];
                    pos[a] = switch (sp.al[a]) {
                        0 => r0 + b.margin[a],
                        1 => r0 + self.div(rs - size[a] + b.margin[a] - b.margin[e], 2),
                        else => r0 + rs - size[a] - b.margin[e],
                    };
                }
            }
            self.setLayout(child, pos.*, &c.out, b);
        }

        fn roundAll(self: *Self, root: u32, scale: f32) Error!void {
            const n = self.nodes.items;
            const k = scale;
            const stack = try self.scratch.alloc(self.alloc, [2]f32, max_depth + 2);
            var sp: usize = 0;
            var cum: [2]f32 = .{ 0, 0 };
            var cur = root;
            while (true) {
                // enter
                const l = &self.layouts.items[cur];
                const o: [2]f32 = .{ cum[0] + l.x, cum[1] + l.y };
                const rx = rnd(o[0], k);
                const ry = rnd(o[1], k);
                const r: Layout = .{
                    .grid_block_start = if (comptime st.frag_enabled) (if (has(l.grid_block_start)) rnd(cum[1] + l.grid_block_start, k) - rnd(cum[1], k) else NONE) else {},
                    .grid_row_span = l.grid_row_span,
                    .x = rx - rnd(cum[0], k),
                    .y = ry - rnd(cum[1], k),
                    .w = rnd(o[0] + l.w, k) - rx,
                    .h = rnd(o[1] + l.h, k) - ry,
                    .content_w = rnd(o[0] + l.content_w, k) - rx,
                    .content_h = rnd(o[1] + l.content_h, k) - ry,
                    .padding = .{
                        .left = rnd(o[0] + l.border.left + l.padding.left, k) - rnd(o[0] + l.border.left, k),
                        .top = rnd(o[1] + l.border.top + l.padding.top, k) - rnd(o[1] + l.border.top, k),
                        .right = rnd(o[0] + l.w - l.border.right, k) - rnd(o[0] + l.w - l.border.right - l.padding.right, k),
                        .bottom = rnd(o[1] + l.h - l.border.bottom, k) - rnd(o[1] + l.h - l.border.bottom - l.padding.bottom, k),
                    },
                    .border = .{
                        .left = rnd(o[0] + l.border.left, k) - rx,
                        .top = rnd(o[1] + l.border.top, k) - ry,
                        .right = rnd(o[0] + l.w, k) - rnd(o[0] + l.w - l.border.right, k),
                        .bottom = rnd(o[1] + l.h, k) - rnd(o[1] + l.h - l.border.bottom, k),
                    },
                    .margin = l.margin,
                    .baseline = if (has(l.baseline)) rnd(o[1] + l.baseline, k) - ry else NONE,
                };
                l.* = r;
                if (n[cur].first_child != no_node and sp < stack.len) {
                    stack[sp] = cum;
                    sp += 1;
                    cum = o;
                    cur = n[cur].first_child;
                    continue;
                }
                while (true) {
                    if (cur == root) return;
                    if (n[cur].next_sibling != no_node) {
                        cur = n[cur].next_sibling;
                        break;
                    }
                    cur = n[cur].parent;
                    if (cur == no_node or sp == 0) return;
                    sp -= 1;
                    cum = stack[sp];
                }
            }
        }
    };
}

fn rnd(v: f32, k: f32) f32 {
    return @round(v * k) / k;
}
