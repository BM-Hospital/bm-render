//! CSS Flexbox (css-flexbox-1 §9), structured after taffy's implementation, axis-indexed (m = main, x = cross).
const std = @import("std");
const st = @import("style.zig");
const tr = @import("tree.zig");


const In = tr.In;
const Out = tr.Out;
const Box = tr.Box;
const Error = tr.Error;
const NONE = tr.NONE;
const MAXC = tr.MAXC;
const MINC = tr.MINC;
const has = tr.has;
const orElse = tr.orElse;
const minO = tr.minO;
const maxO = tr.maxO;
const clampO = tr.clampO;
const isDef = tr.isDef;
const no_node = tr.no_node;

const Item = struct {
    node: u32,
    box: Box,
    /// relative-position offset (already combined from inset)
    rel: [2]f32,
    al: st.Align,
    grow: f32,
    shrink: f32,
    basis: f32,
    inner_basis: f32,
    violation: f32,
    /// share of the remaining free space (Blink's free_space_fraction)
    frac: f64,
    min_main: f32,
    /// hypothetical border-box size
    hyp: [2]f32,
    target: [2]f32,
    baseline: f32,
    off_main: f32,
    off_cross: f32,
    frozen: bool,
    indef: bool,
    cross_auto: bool,
    basis_definite: bool,
    /// definite cross size used when measuring the item (NaN = none)
    ck: f32,
    cross_avail: f32,
    scroll_main: bool,
};

const Line = struct {
    start: u32,
    end: u32,
    cross: f32 = 0,
    off: f32 = 0,
    /// how much of `cross` only the rows a page break grew in a stretched table make up: the other
    /// items stretch to `cross - excess` (fragment.zig `TableStretch`)
    excess: f32 = 0,
};

/// The block size a table stretched in a row flex line had before pagination grew its rows on later
/// pages (fragment.zig `TableStretch`); NONE: no such table.
fn stretchBase(t: anytype, node: u32) f32 {
    if (comptime !@import("style.zig").frag_enabled) return NONE;
    for (t.paged.table_stretches) |ts| if (ts.node == node and ts.segs.len > 1) return ts.h0;
    return NONE;
}

/// Blink's LayoutUnitDiffuser: `size` split into `n` buckets that differ by at most one layout unit
/// (exact division when not laying out on the 1/64 px grid).
pub const Diffuser = struct {
    q: bool = false,
    base: f32 = 0,
    dx: u64 = 0,
    dy: u64 = 0,
    x: u64 = 0,
    y: u64 = 0,

    pub fn init(q: bool, size: f32, n: usize) Diffuser {
        if (n == 0 or !(size > 0)) return .{};
        if (!q) return .{ .base = size / @as(f32, @floatFromInt(n)) };
        const raw: u64 = @intFromFloat(@min(@trunc(size * 64), 2.0e9));
        return .{ .q = true, .base = @as(f32, @floatFromInt(raw / n)) / 64, .dx = (raw % n) * 2, .dy = n * 2, .y = n };
    }
    pub fn next(d: *Diffuser) f32 {
        if (!d.q) return d.base;
        d.x += d.dx;
        if (d.x >= d.y) {
            d.y += d.dy;
            return d.base + 1.0 / 64.0;
        }
        return d.base;
    }
};

/// Blink's InitialContentPositionOffset: offset of the first item/line for a content alignment.
pub fn firstOffset(t: anytype, free: f32, n: usize, mode: st.Align, reversed: bool) f32 {
    const flow_start: f32 = if (reversed) free else 0;
    const nf: f32 = @floatFromInt(n);
    return switch (mode) {
        .space_between => if (free > 0 and n > 1) 0 else flow_start,
        .space_around => if (free > 0 and n > 0) t.div(free, 2 * nf) else @max(t.div(free, 2), 0),
        .space_evenly => if (free > 0 and n > 0) t.div(free, nf + 1) else @max(t.div(free, 2), 0),
        .center => t.div(free, 2),
        .start => 0,
        .end => free,
        .flex_end => if (reversed) 0 else free,
        else => flow_start,
    };
}

/// Blink's ContentDistributionSpace: the extra space between adjacent items/lines.
pub fn spacing(t: anytype, free: f32, n: usize, mode: st.Align) Diffuser {
    if (!(free > 0) or n <= 1) return .{};
    return switch (mode) {
        .space_between => Diffuser.init(t.q64, free, n - 1),
        .space_evenly => Diffuser.init(t.q64, free, n + 1),
        .space_around => Diffuser.init(t.q64, free, n),
        else => .{},
    };
}

fn gapSum(gap: f32, n: usize) f32 {
    return if (n > 1) gap * @as(f32, @floatFromInt(n - 1)) else 0;
}

/// Per-container algorithm state. Lives in the tree's scratch arena, not on the call stack: flex containers
/// nest hundreds of levels deep and every level re-enters `Tree.computeNode` from the functions below.
const S = struct {
    node: u32,
    in: In,
    box: Box,
    items: []Item,
    lines: []Line,
    /// node inner (content-box) size; NaN = not yet determined
    inner: [2]f32,
    /// percentage basis for the items
    pct: [2]f32,
    gap: [2]f32,
    avail: [2]f32,
    min_inner: [2]f32,
    max_inner: [2]f32,
    inset: [4]f32,
    size: [2]f32,
    content: [2]f32,
    /// request / result of the child computation in progress
    ci: In,
    co: Out,
    area: [4]f32,
    sp: tr.StaticPos,
    total_cross: f32,
    cross_gap_total: f32,
    first_bl: f32,
    first_bl_fallback: f32,
    m: u8,
    x: u8,
    reverse: bool,
    wrap: bool,
    wrap_rev: bool,
    def_cross: bool,
    /// single-line row whose aspect-ratio block size is only a floor for the line's cross size
    cross_floor: bool,
    align_items: st.Align,
    align_content: st.Align,
    justify: st.Align,
    safe: st.AlignSafe,
};

pub noinline fn compute(t: anytype, node: u32, in_: *const In, out: *Out) Error!void {
    const mark = t.scratch.mark();
    defer t.scratch.release(mark);
    const c = try t.scratch.create(t.alloc, S);
    c.node = node;
    c.cross_floor = false;
    c.in = in_.*;
    const in = &c.in;
    const s = t.nodes.items[node].style;
    t.sbox(&c.box, s, in);
    const box = &c.box;
    in.known = tr.styledKnown(in, box);
    out.* = .{ .size = in.known };
    if (!in.layout and has(in.known[0]) and has(in.known[1])) return;
    // width from a definite height through the aspect ratio; under a min-content request the automatic
    // content-based minimum still applies, so the content width is computed as well
    const ratio_w = t.ratioWidth(s, box, in);
    if (!has(in.known[0])) {
        // The inline size is always resolved before layout (fit-content of the intrinsic sizes).
        const a0 = in.avail[0] - box.marginSum(0) - box.pb[0];
        if (s.flex_direction == .row or s.flex_direction == .row_reverse) {
            in.known[0] = try impl(t, c, true, false);
        } else {
            // column: widest item; a wrapping column is as wide as its columns (fit-content)
            var w: f32 = NONE;
            const wrapping = s.flex_wrap != .nowrap and a0 != MINC;
            if (wrapping) {
                w = try impl(t, c, false, false);
                if (w - box.pb[0] <= a0) in.known[0] = w;
            }
            if (!has(in.known[0])) {
                const ph: f32 = if (in.indef_h) NONE else maxO(in.known[1] - box.pb[1], 0);
                var mw: f32 = 0;
                var ch = t.firstChild(node);
                while (ch != no_node) : (ch = t.nextSibling(ch)) {
                    const cs = t.nodes.items[ch].style;
                    if (cs.display == .none or cs.position.isOut()) continue;
                    c.ci = .{ .parent = .{ NONE, ph }, .avail = .{ if (wrapping) MINC else a0, MAXC } };
                    const cw = try t.measureChild(ch, &c.ci, 0);
                    mw = @max(mw, cw + t.marginSumOf(cs, 0, NONE));
                }
                mw = @max(clampO(mw + box.pb[0], box.min[0], box.max[0]), box.pb[0]);
                in.known[0] = if (wrapping) @min(w, @max(mw, a0 + box.pb[0])) else mw;
            }
        }
    }
    in.known[0] = maxO(in.known[0], ratio_w);
    out.* = .{ .size = .{ in.known[0], NONE } };
    if (in.width_only and has(in.known[0])) return;
    const floor_h = t.applyRatio(s, box, &in.known);
    if (has(floor_h)) {
        // The aspect-ratio block size is definite for the flex algorithm, but only a floor under the
        // content-based automatic minimum (Blink: max(ratio size, intrinsic block size)). The intrinsic
        // block size is the sum of the hypothetical item sizes of a column / of the content-sized lines of
        // a wrapping row, with percentages unresolved; a single-line row takes its cross size from the ratio.
        if (in.flex_main or s.flex_wrap != .nowrap or s.flex_direction == .column or s.flex_direction == .column_reverse) {
            _ = try impl(t, c, false, false);
            var content_h = c.size[1];
            if (in.flex_main) content_h = clampO(content_h, t.ratio(s, box, 1, box.min[0]), t.ratio(s, box, 1, box.max[0]));
            in.known[1] = @max(floor_h, content_h);
        } else {
            // (stretched items take the ratio size, the others may still make the line taller)
            in.known[1] = floor_h;
            c.cross_floor = true;
        }
    }
    _ = try impl(t, c, false, in.layout);
    out.* = .{ .size = c.size };
    if (!in.layout) return;
    out.content = c.content;
    out.baseline = orElse(c.first_bl, c.first_bl_fallback);
}

/// Runs the algorithm on `c.in` / `c.box`; returns the container's border-box width and leaves the full
/// result in `c.size` (+ `c.content`, `c.first_bl*` after a layout pass). `phase_a` stops after the inline
/// size of a row container has been resolved.
fn impl(t: anytype, c: *S, phase_a: bool, layout: bool) Error!f32 {
    const mark = t.scratch.mark();
    defer t.scratch.release(mark);
    try setup(t, c);
    try baseSizes(t, c);
    if (!has(c.inner[c.m]) and c.m == 0) try rowIntrinsic(t, c);
    if (phase_a) return orElse(c.inner[0], 0) + c.box.pb[0];
    collectLines(t, c);
    resolveFlexible(t, c);
    try crossSizes(t, c);
    try baselines(t, c);
    lineCross(t, c);
    try usedCross(t, c);
    alignItems(t, c);

    // 15. Container cross size
    const x = c.x;
    if (!c.def_cross) c.inner[x] = @max(clampO(c.total_cross + c.cross_gap_total, c.min_inner[x], c.max_inner[x]), 0);
    c.size = .{ c.inner[0] + c.box.pb[0], c.inner[1] + c.box.pb[1] };
    if (layout) try finalPass(t, c);
    return c.size[0];
}

/// Derived container values and step 1 (generate flex items).
noinline fn setup(t: anytype, c: *S) Error!void {
    const node = c.node;
    const s = t.nodes.items[node].style;
    const box = &c.box;
    const in = &c.in;
    const known = in.known;

    const m: usize = @intFromBool(s.flex_direction == .column or s.flex_direction == .column_reverse);
    const x: usize = 1 - m;
    c.m = @intCast(m);
    c.x = @intCast(x);
    c.reverse = s.flex_direction == .row_reverse or s.flex_direction == .column_reverse;
    c.wrap = s.flex_wrap != .nowrap;
    c.wrap_rev = s.flex_wrap == .wrap_reverse;
    c.safe = s.safe;
    c.align_items = s.align_items orelse .stretch;
    c.align_content = s.align_content orelse .stretch;
    c.justify = switch (s.justify_content orelse .flex_start) {
        .stretch, .baseline => .flex_start,
        else => |v| v,
    };

    for (0..4) |i| c.inset[i] = box.padding[i] + box.border[i];
    const pb = box.pb;
    c.inner = .{ maxO(known[0] - pb[0], 0), maxO(known[1] - pb[1], 0) };
    c.pct = .{ c.inner[0], if (in.indef_h) NONE else c.inner[1] };
    const pct = c.pct;
    c.gap = .{ t.lp(s.gap[0], pct[0]), t.lp(s.gap[1], pct[1]) };
    for (0..2) |a| c.avail[a] = if (has(c.inner[a])) c.inner[a] else in.avail[a] - box.marginSum(a) - pb[a];
    // an auto block size is always content-based: the available height never constrains it
    if (!has(c.inner[1])) c.avail[1] = MAXC;
    // min/max of the content box
    c.min_inner = .{ box.min[0] - pb[0], box.min[1] - pb[1] };
    c.max_inner = .{ box.max[0] - pb[0], box.max[1] - pb[1] };

    // 1. Generate flex items (in order-modified document order)
    const ids = try t.orderedItems(node);
    const count = ids.len;
    c.items = try t.scratch.alloc(t.alloc, Item, count);
    c.lines = try t.scratch.alloc(t.alloc, Line, @max(count, 1));
    for (ids, c.items) |ch, *it| {
        const cs = t.nodes.items[ch].style;
        it.node = ch;
        t.rbox(&it.box, cs, pct);
        var al = cs.align_self orelse c.align_items;
        if (@backingInt(al) >= @backingInt(st.Align.space_between)) al = .start;
        if (al == .baseline and (it.box.margin_auto[x] or it.box.margin_auto[x + 2])) al = .start;
        it.al = al;
        it.rel = .{
            t.relX(cs, pct[0], false),
            orElse(t.dim(cs.inset.top, pct[1]), -orElse(t.dim(cs.inset.bottom, pct[1]), 0)),
        };
        it.grow = @max(cs.flex_grow, 0);
        it.shrink = @max(cs.flex_shrink, 0);
        it.cross_auto = cs.size[x] == .auto;
        it.scroll_main = (if (m == 0) cs.overflow_x else cs.overflow_y) != .visible;
        it.frozen = false;
        it.violation = 0;
        it.baseline = 0;
        it.off_main = 0;
        it.off_cross = 0;
        it.hyp = .{ 0, 0 };
        it.target = .{ 0, 0 };
    }
}

/// 3. Flex base size and hypothetical main size
noinline fn baseSizes(t: anytype, c: *S) Error!void {
    const m: usize = c.m;
    const x: usize = c.x;
    for (c.items) |*it| {
        const cs = t.nodes.items[it.node].style;
        const b = &it.box;
        const cmargin_x = b.marginSum(x);
        // available cross space for the child, clamped by its min/max
        var cross_avail = c.avail[x];
        if (isDef(cross_avail)) {
            cross_avail = clampO(cross_avail, b.min[x] + cmargin_x, b.max[x] + cmargin_x);
        } else if (cross_avail < 0) {
            if (has(b.min[x])) cross_avail = b.min[x] + cmargin_x;
        } else if (has(b.max[x])) cross_avail = b.max[x] + cmargin_x;

        var ckx: f32 = b.size[x];
        if (it.al == .stretch and !has(ckx) and !c.wrap and has(c.inner[x]) and !b.margin_auto[x] and !b.margin_auto[x + 2]) {
            ckx = @max(clampO(c.inner[x] - cmargin_x, b.min[x], b.max[x]), b.pb[x]);
        }
        ckx = clampO(ckx, b.min[x], b.max[x]);

        const adj: f32 = if (cs.box_sizing == .content_box) b.pb[m] else 0;
        var basis = t.dim(cs.flex_basis, c.pct[m]) + adj;
        // a percentage basis against an indefinite main size behaves as `content`
        if (!has(basis) and !cs.flex_basis.hasPercent()) basis = b.size[m];
        it.basis_definite = has(basis);
        // is the item height a definite size for the percentages of its own children?
        it.indef = cs.aspect_ratio == null and (if (m == 1) !has(c.pct[1]) and !has(basis) else !has(b.size[1]));
        it.ck = ckx;
        it.cross_avail = cross_avail;
        if (!has(basis)) {
            c.ci = .{ .parent = c.pct, .content_sizing = true, .cs_axis = @intCast(m), .flex_main = m == 1 };
            c.ci.known[x] = ckx;
            c.ci.avail[m] = if (c.avail[m] == MINC) MINC else MAXC;
            c.ci.avail[x] = cross_avail;
            basis = try t.measureChild(it.node, &c.ci, m);
        }
        basis = @max(basis, b.pb[m]);
        it.basis = basis;
        it.inner_basis = basis - b.pb[m];

        // automatic minimum size (§4.5); a minimum transferred through the aspect ratio (min-height ->
        // min-width) is only a lower bound of it
        var min_main = b.min[m];
        if (!has(t.dim(cs.min_size[m], c.pct[m]))) {
            if (it.scroll_main) {
                min_main = orElse(min_main, 0);
            } else {
                c.ci = .{ .parent = c.pct, .content_sizing = true, .cs_axis = @intCast(m), .flex_main = m == 1 };
                c.ci.known[x] = ckx;
                c.ci.avail[m] = MINC;
                c.ci.avail[x] = cross_avail;
                const mc = try t.measureChild(it.node, &c.ci, m);
                min_main = maxO(minO(minO(mc, b.size[m]), b.max[m]), min_main);
            }
        }
        min_main = @max(min_main, b.pb[m]);
        it.min_main = min_main;
        it.hyp[m] = @max(minO(basis, b.max[m]), min_main);
    }
}

/// 4. Main size of a row container whose inline size is not known: intrinsic sizes (Blink's
///    ComputeMinMaxSizeOfRowContainer), then fit-content against the available space.
noinline fn rowIntrinsic(t: anytype, c: *S) Error!void {
    const s = t.nodes.items[c.node].style;
    const need_min = c.avail[0] != MAXC;
    const need_max = c.avail[0] != MINC;
    var sum_min: f32 = 0;
    var sum_max: f32 = 0;
    var largest_min: f32 = 0;
    for (c.items) |*it| {
        const ms = it.box.marginSum(0);
        for (0..2) |k| {
            if ((k == 0 and !need_min) or (k == 1 and !need_max)) continue;
            c.ci = .{ .known = .{ NONE, it.ck }, .parent = .{ NONE, c.pct[1] }, .avail = .{ if (k == 0) MINC else MAXC, it.cross_avail } };
            var v = try t.measureChild(it.node, &c.ci, 0);
            if (k == 0 and c.wrap) {
                largest_min = @max(largest_min, v + ms);
                continue;
            }
            if (it.basis_definite and ((v > it.basis and it.grow == 0) or (v < it.basis and it.shrink == 0))) v = it.hyp[0];
            if (k == 0) sum_min += v + ms else sum_max += v + ms;
        }
    }
    const g = gapSum(c.gap[0], c.items.len);
    const mn = if (c.wrap) largest_min else sum_min + g;
    const mx = @max(sum_max + g, mn);
    const main = if (!need_max) mn else if (!need_min) mx else @min(mx, @max(mn, c.avail[0]));
    c.inner[0] = @max(clampO(main, c.min_inner[0], c.max_inner[0]), 0);
    c.gap[0] = t.lp(s.gap[0], c.inner[0]);
}

/// 5. Collect flex lines (and the main size of a column container with auto height).
noinline fn collectLines(t: anytype, c: *S) void {
    const m: usize = c.m;
    const items = c.items;
    const lines_buf = c.lines;
    var n_lines: usize = 0;
    {
        var wrap_at: f32 = if (!c.wrap) MAXC else orElse(c.inner[m], orElse(c.max_inner[m], MAXC));
        if (c.wrap and m == 1 and !has(c.inner[1]) and c.in.content_sizing) {
            // intrinsic block size of a wrapping column: its columns still break against the styled height
            var own: Box = undefined;
            // (a column parent measures its items without block constraints: percentages stay unresolved)
            t.rbox(&own, t.nodes.items[c.node].style, .{ c.in.parent[0], if (c.in.flex_main) NONE else c.in.parent[1] });
            wrap_at = orElse(maxO(orElse(clampO(own.size[1], own.min[1], own.max[1]), own.max[1]) - c.box.pb[1], 0), MAXC);
        }
        var start: usize = 0;
        var len: f32 = 0;
        const g = c.gap[m];
        for (items, 0..) |*it, i| {
            const outer = it.hyp[m] + it.box.marginSum(m);
            if (i > start) {
                if (len + g + outer > wrap_at + 0.001) {
                    lines_buf[n_lines] = .{ .start = @intCast(start), .end = @intCast(i) };
                    n_lines += 1;
                    start = i;
                    len = outer;
                    continue;
                }
                len += g + outer;
            } else len = outer;
        }
        lines_buf[n_lines] = .{ .start = @intCast(start), .end = @intCast(items.len) };
        n_lines += 1;
    }
    c.lines = lines_buf[0..n_lines];

    // Main size of a column container with auto height: the longest line of hypothetical sizes
    if (!has(c.inner[m])) {
        var main: f32 = 0;
        for (c.lines) |ln| {
            var sum: f32 = gapSum(c.gap[m], ln.end - ln.start);
            for (items[ln.start..ln.end]) |*it| sum += it.hyp[m] + it.box.marginSum(m);
            main = @max(main, sum);
        }
        c.inner[m] = @max(clampO(main, c.min_inner[m], c.max_inner[m]), 0);
    }
}

/// 6. Resolve flexible lengths (after Blink's LineFlexer, which distributes in layout units)
noinline fn resolveFlexible(t: anytype, c: *S) void {
    const m: usize = c.m;
    const inner_main = c.inner[m];
    const gap_m = c.gap[m];
    for (c.lines) |ln| {
        const li = c.items[ln.start..ln.end];
        var hyp_sum: f32 = gapSum(gap_m, li.len);
        for (li) |*it| hyp_sum += it.hyp[m] + it.box.marginSum(m);
        const growing = hyp_sum < inner_main;
        for (li) |*it| {
            const factor = if (growing) it.grow else it.shrink;
            it.frozen = factor == 0 or (if (growing) it.basis > it.hyp[m] else it.basis < it.hyp[m]);
            it.target[m] = it.hyp[m];
        }
        var initial_free: f32 = 0;
        var round: usize = 0;
        while (round <= li.len) : (round += 1) {
            // sums over the unfrozen items; each takes its fraction of what the items after it leave
            var total_factor: f64 = 0;
            var total_weighted: f64 = 0;
            var free: f32 = inner_main;
            for (li) |*it| {
                const ms = it.box.marginSum(m);
                if (it.frozen) {
                    free -= it.target[m] + ms + gap_m;
                    continue;
                }
                it.target[m] = it.hyp[m];
                const factor: f64 = if (growing) it.grow else it.shrink;
                total_factor += factor;
                if (growing) {
                    it.frac = factor / total_factor;
                } else {
                    const w = factor * @as(f64, it.inner_basis);
                    total_weighted += w;
                    it.frac = w / total_weighted;
                }
                free -= it.basis + ms + gap_m;
            }
            free += gap_m;
            if (round == 0) initial_free = free;
            if (total_factor > 0 and total_factor < 1) {
                const fractional = t.qt(@floatCast(@as(f64, initial_free) * total_factor));
                if (@abs(fractional) < @abs(free)) free = fractional;
            }
            if (if (growing) free <= 0 else free >= 0) break;

            var total_violation: f32 = 0;
            var i = li.len;
            while (i > 0) {
                i -= 1;
                const it = &li[i];
                if (it.frozen) continue;
                var extra: f32 = free;
                if (it.frac != 1.0) {
                    const e = @as(f64, free) * it.frac;
                    extra = if (std.math.isFinite(e)) (if (t.q64) @floatCast(@round(e * 64) / 64) else @floatCast(e)) else 0;
                }
                free -= extra;
                const size = it.basis + extra;
                const clamped = @max(minO(size, it.box.max[m]), it.min_main);
                it.target[m] = clamped;
                it.violation = clamped - size;
                total_violation += it.violation;
            }
            if (total_violation == 0) break;
            for (li) |*it| {
                if (!it.frozen and it.violation != 0 and (it.violation < 0) == (total_violation < 0)) it.frozen = true;
            }
        }
    }
}

/// 7. Hypothetical cross size of each item
noinline fn crossSizes(t: anytype, c: *S) Error!void {
    const m: usize = c.m;
    const x: usize = c.x;
    for (c.items) |*it| {
        const b = &it.box;
        var cross = @as(f32, NONE);
        if (has(b.size[x])) cross = @max(clampO(b.size[x], b.min[x], b.max[x]), b.pb[x]);
        if (!has(cross) and !c.wrap and has(c.inner[x]) and it.al == .stretch and it.cross_auto and !b.margin_auto[x] and !b.margin_auto[x + 2]) {
            // will be stretched to the definite line anyway: no need to measure
            cross = c.inner[x] - b.marginSum(x);
        }
        if (!has(cross)) {
            c.ci = .{ .parent = c.pct, .content_sizing = true, .cs_axis = @intCast(x), .indef_h = it.indef };
            c.ci.known[m] = it.target[m];
            c.ci.avail[m] = c.inner[m];
            c.ci.avail[x] = c.avail[x];
            cross = try t.measureChild(it.node, &c.ci, x);
        }
        it.hyp[x] = @max(clampO(cross, b.min[x], b.max[x]), b.pb[x]);
    }
}

noinline fn baselines(t: anytype, c: *S) Error!void {
    if (c.m == 0) {
        // rows: the first baseline of the laid out items
        for (c.lines) |ln| {
            const li = c.items[ln.start..ln.end];
            var nb: usize = 0;
            for (li) |*it| nb += @intFromBool(it.al == .baseline);
            if (nb <= 1) continue;
            for (li) |*it| {
                if (it.al != .baseline) continue;
                c.ci = .{
                    .known = .{ it.target[0], it.hyp[1] },
                    .parent = c.pct,
                    .avail = .{ c.inner[0], c.avail[1] },
                    .layout = true,
                    .content_sizing = true,
                    .indef_h = it.indef,
                };
                try t.computeNode(it.node, &c.ci, &c.co);
                const bl = orElse(c.co.baseline, c.co.size[1]);
                it.baseline = if (c.wrap_rev) it.box.margin[3] + c.co.size[1] - bl else it.box.margin[1] + bl;
            }
        }
    } else {
        // column: baselines are synthesized at the cross-start edge
        for (c.items) |*it| {
            if (it.al == .baseline) it.baseline = if (c.wrap_rev) it.box.margin[2] + it.hyp[0] else it.box.margin[0];
        }
    }
}

/// 8. Cross size of each line; 9. align-content: stretch
noinline fn lineCross(t: anytype, c: *S) void {
    const x: usize = c.x;
    const lines = c.lines;
    c.def_cross = has(c.inner[x]);
    if (!c.wrap and c.def_cross and !c.cross_floor) {
        lines[0].cross = c.inner[x];
    } else {
        for (lines) |*ln| {
            const li = c.items[ln.start..ln.end];
            var max_bl: f32 = 0;
            for (li) |*it| max_bl = @max(max_bl, it.baseline);
            var v: f32 = 0;
            // (the line as it was before a page break grew the rows of a stretched table in it:
            // what the other items stretch to, Blink's line before `row_cross_size_updates`)
            var v_base: f32 = 0;
            for (li) |*it| {
                const outer = it.hyp[x] + it.box.marginSum(x);
                const is_bl = it.al == .baseline and !it.box.margin_auto[x] and !it.box.margin_auto[x + 2];
                v = @max(v, if (is_bl) max_bl - it.baseline + outer else outer);
                const base = if (x == 1) stretchBase(t, it.node) else NONE;
                const outer_base = if (has(base)) @min(outer, base + it.box.marginSum(x)) else outer;
                v_base = @max(v_base, if (is_bl) max_bl - it.baseline + outer_base else outer_base);
            }
            ln.cross = v;
            ln.excess = v - v_base;
        }
        if (!c.wrap) lines[0].cross = @max(clampO(lines[0].cross, c.min_inner[x], c.max_inner[x]), 0);
        if (c.cross_floor) {
            lines[0].cross = @max(lines[0].cross, c.inner[x]);
            c.inner[x] = lines[0].cross;
        }
    }

    c.cross_gap_total = gapSum(c.gap[x], lines.len);
    var total_cross: f32 = 0;
    for (lines) |ln| total_cross += ln.cross;
    // stretch lines against the definite cross size, or against a min-size that exceeds the content
    const target_inner = if (c.def_cross) c.inner[x] else orElse(c.min_inner[x], 0);
    if (c.wrap and c.align_content == .stretch and total_cross + c.cross_gap_total < target_inner) {
        var add = Diffuser.init(t.q64, target_inner - total_cross - c.cross_gap_total, lines.len);
        // (in visual order: Blink has applied the wrap-reverse reversal by now)
        for (0..lines.len) |i| lines[if (c.wrap_rev) lines.len - 1 - i else i].cross += add.next();
        total_cross = target_inner - c.cross_gap_total;
    }
    c.total_cross = total_cross;
}

/// 11. Used cross size of each item
noinline fn usedCross(t: anytype, c: *S) Error!void {
    const m: usize = c.m;
    const x: usize = c.x;
    for (c.lines) |ln| {
        for (c.items[ln.start..ln.end]) |*it| {
            const b = &it.box;
            if (it.al == .stretch and !b.margin_auto[x] and !b.margin_auto[x + 2] and it.cross_auto) {
                it.target[x] = @max(clampO(ln.cross - ln.excess - b.marginSum(x), b.min[x], b.max[x]), b.pb[x]);
                if (m == 0) it.indef = false;
            } else {
                it.target[x] = it.hyp[x];
                if (m == 1 and it.cross_auto and !has(b.size[0]) and @abs(ln.cross - c.avail[0]) > 0.01) {
                    // a column item is fitted against its (multi-line) line, not the whole container
                    c.ci = .{ .known = .{ NONE, it.target[1] }, .parent = c.pct, .avail = .{ ln.cross, MAXC }, .content_sizing = true, .indef_h = it.indef };
                    const v = try t.measureChild(it.node, &c.ci, 0);
                    it.target[0] = @max(clampO(v, b.min[0], b.max[0]), b.pb[0]);
                }
            }
        }
    }
}

/// 12. Main-axis alignment; 13/14. cross-axis auto margins and alignment
noinline fn alignItems(t: anytype, c: *S) void {
    const m: usize = c.m;
    const x: usize = c.x;
    const reverse = c.reverse;
    const wrap_rev = c.wrap_rev;
    const gap_m = c.gap[m];
    for (c.lines) |ln| {
        const li = c.items[ln.start..ln.end];
        var used: f32 = gapSum(gap_m, li.len);
        var n_auto: f32 = 0;
        for (li) |*it| {
            used += it.target[m] + it.box.marginSum(m);
            n_auto += @floatFromInt(@as(u8, @intFromBool(it.box.margin_auto[m])) + @intFromBool(it.box.margin_auto[m + 2]));
        }
        const free = c.inner[m] - used;
        if (free > 0 and n_auto > 0) {
            var mg = Diffuser.init(t.q64, free, @intFromFloat(n_auto));
            for (0..li.len) |i| {
                const it = &li[if (reverse) li.len - 1 - i else i];
                if (it.box.margin_auto[m]) it.box.margin[m] = mg.next();
                if (it.box.margin_auto[m + 2]) it.box.margin[m + 2] = mg.next();
            }
            // items pack from the main-start edge
            for (li, 0..) |*it, i| it.off_main = if (i == (if (reverse) li.len - 1 else 0)) 0 else gap_m;
        } else {
            // (`safe`: overflowing content is start-aligned)
            const jc: st.Align = if (free < 0 and c.safe.justify_content) .start else c.justify;
            var between = spacing(t, free, li.len, jc);
            for (0..li.len) |i| {
                const it = &li[if (reverse) li.len - 1 - i else i];
                it.off_main = if (i == 0) firstOffset(t, free, li.len, jc, reverse) else gap_m + between.next();
            }
        }
    }

    for (c.lines) |ln| {
        const li = c.items[ln.start..ln.end];
        var max_bl: f32 = 0;
        for (li) |*it| max_bl = @max(max_bl, it.baseline);
        for (li) |*it| {
            const b = &it.box;
            const free = ln.cross - it.target[x] - b.marginSum(x);
            const sa = b.margin_auto[x];
            const ea = b.margin_auto[x + 2];
            if (sa or ea) {
                const f = @max(free, 0);
                if (sa and ea) {
                    b.margin[x] = t.div(f, 2);
                    b.margin[x + 2] = t.div(f, 2);
                } else if (sa) {
                    b.margin[x] = f;
                } else b.margin[x + 2] = f;
                continue;
            }
            const cs = t.nodes.items[it.node].style;
            if (free < 0 and (if (cs.align_self != null) cs.safe.align_self else c.safe.align_items)) continue;
            it.off_cross = switch (it.al) {
                .start => 0,
                .end => free,
                .flex_end => if (wrap_rev) 0 else free,
                .center => t.div(free, 2),
                .baseline => if (wrap_rev) free - (max_bl - it.baseline) else max_bl - it.baseline,
                else => if (wrap_rev) free else 0,
            };
        }
    }
}

/// 16. align-content, the final layout of the items, absolutely positioned and hidden children.
noinline fn finalPass(t: anytype, c: *S) Error!void {
    const m: usize = c.m;
    const x: usize = c.x;
    const node = c.node;
    const lines = c.lines;
    const wrap_rev = c.wrap_rev;
    const reverse = c.reverse;
    {
        const free = c.inner[x] - c.total_cross - c.cross_gap_total;
        const mode: st.Align = if (!c.wrap) .stretch else if (free < 0 and c.safe.align_content) .start else c.align_content;
        var between = spacing(t, free, lines.len, mode);
        for (0..lines.len) |i| {
            const ln = &lines[if (wrap_rev) lines.len - 1 - i else i];
            ln.off = if (i == 0) firstOffset(t, free, lines.len, mode, wrap_rev) else c.gap[x] + between.next();
        }
    }

    c.content = .{ 0, 0 };
    c.first_bl = NONE;
    c.first_bl_fallback = NONE;
    {
        var cross_pos = c.inset[x];
        for (0..lines.len) |k| {
            const lidx = if (wrap_rev) lines.len - 1 - k else k;
            const ln = &lines[lidx];
            const li = c.items[ln.start..ln.end];
            var main_pos = c.inset[m];
            cross_pos += ln.off;
            for (0..li.len) |i| {
                const it = &li[if (reverse) li.len - 1 - i else i];
                const b = &it.box;
                c.ci = .{ .known = it.target, .parent = c.pct, .avail = c.inner, .layout = true, .content_sizing = true, .indef_h = it.indef };
                try t.computeNode(it.node, &c.ci, &c.co);
                const o = &c.co;
                main_pos += it.off_main + b.margin[m];
                const pos = &c.ci.known;
                pos[m] = main_pos;
                pos[x] = cross_pos + it.off_cross + b.margin[x];
                if (k == 0) {
                    const bl = pos[1] + orElse(o.baseline, o.size[1]);
                    // the first item in visual (reversal-applied) order, preferring baseline-aligned ones in a row
                    if (i == 0) c.first_bl_fallback = bl;
                    if ((m == 1 and i == 0) or (m == 0 and it.al == .baseline and !has(c.first_bl))) c.first_bl = bl;
                }
                pos[0] += it.rel[0];
                pos[1] += it.rel[1];
                t.setLayout(it.node, pos.*, o, b);
                t.accumContent(&c.content, it.node);
                main_pos += o.size[m] + b.margin[m + 2];
            }
            cross_pos += ln.cross;
        }
    }

    // Absolutely positioned and hidden children
    if (c.items.len != t.nodes.items[node].child_count) {
        const box = &c.box;
        const s = t.nodes.items[node].style;
        c.area = .{
            box.border[0],                             box.border[1],
            c.size[0] - box.border[0] - box.border[2], c.size[1] - box.border[1] - box.border[3],
        };
        var ch = t.firstChild(node);
        while (ch != no_node) : (ch = t.nextSibling(ch)) {
            const cs = t.nodes.items[ch].style;
            if (cs.display == .none) {
                t.hide(ch);
                continue;
            }
            if (!cs.position.isOut()) continue;
            c.sp = .{ .rect = .{ c.inset[0], c.inset[1], c.inner[0], c.inner[1] } };
            c.sp.al[m] = switch (c.justify) {
                .start => 0,
                .end => 2,
                .flex_end => if (reverse) 0 else 2,
                .center, .space_around, .space_evenly => 1,
                else => if (reverse) 2 else 0,
            };
            c.sp.al[x] = switch (cs.align_self orelse (s.align_items orelse .stretch)) {
                .start, .baseline => 0,
                .end => 2,
                .center => 1,
                .flex_end => if (wrap_rev) 0 else 2,
                else => if (wrap_rev) 2 else 0,
            };
            try t.placeAbsolute(node, ch, &c.area, &c.sp);
            t.accumContent(&c.content, ch);
        }
    }
}
