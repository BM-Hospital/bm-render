//! Block layout: vertical stacking of block-level children with margin collapsing (CSS 2.1 §8.3.1, §10) and,
//! with `Config.floats`, floats (§9.5): placement in the exclusion space of the block formatting context,
//! `clear`, formatting-context roots and measured leaves avoiding floats, BFC roots growing to contain them.
//! Next to floats a formatting context root (flex/grid/table boxes, `overflow` != visible, `flow_root`) and a
//! measured leaf are fitted into the band that is free at their top edge and keep that width for their whole
//! height. Inline content (`Style.is_inline_content`, with `Config.inline_fn`) keeps its full width instead and
//! has every line shortened by the floats beside it (flow.zig).
const std = @import("std");
const st = @import("style.zig");
const tr = @import("tree.zig");
const fl = @import("floats.zig");

const In = tr.In;
const Out = tr.Out;
const Box = tr.Box;
const Error = tr.Error;
const MarginSet = tr.MarginSet;
const NONE = tr.NONE;
const MAXC = tr.MAXC;
const has = tr.has;
const orElse = tr.orElse;
const clampO = tr.clampO;
const maxO = tr.maxO;
const no_node = tr.no_node;

const AbsItem = struct { node: u32, y: f32 };

/// Per-container state kept in the tree's scratch arena (see `Tree.computeNode` on stack discipline).
const S = struct {
    in: In,
    box: Box,
    /// box of the child being placed
    cb: Box,
    known: [2]f32,
    inset: [4]f32,
    parent: [2]f32,
    content: [2]f32,
    ci: In,
    co: Out,
    area: [4]f32,
    sp: tr.StaticPos,
    first_set: MarginSet,
    active: MarginSet,
    // floats
    /// border-box origin of this box in the coordinates of its block formatting context
    org: [2]f32,
    bfc: fl.Bfc,
    prev_bfc: ?*fl.Bfc,
    /// result of `avoidFloats`: x shift, band width, y push
    av: [3]f32,
    frq: FloatReq,
    /// Fragmentainer offset of the preceding resumed in-flow child.
    resume_dy: f32,
};

/// Where a float is placed from: its containing block and the position it occurs at.
pub const FloatReq = struct {
    /// content-box size of the containing block (percentage basis)
    parent: [2]f32,
    /// border-box origin of the box the float is positioned in, in formatting context coordinates
    org: [2]f32,
    /// distance from that origin to the left content edge of the containing block
    inset_left: f32,
    /// local y (from `org`) the float may not be placed above
    y_top: f32,
    do_layout: bool,
    /// The float occurs on a line: [width of the content before it, width of the line's free range]. It is
    /// then only placed when it fits beside that content at `y_top` (Blink's ShouldPushFloatAfterLine).
    fit: ?[2]f32 = null,
};

const FloatS = struct { cb: Box, ci: In, co: Out };

/// Does a block container establish a new block formatting context?
pub fn isRoot(s: *const st.Style, in: *const In) bool {
    return !in.collapse or s.position.isOut() or s.float != .none or s.flow_root or
        s.overflow_x == .hidden or s.overflow_x == .scroll or s.overflow_y == .hidden or s.overflow_y == .scroll;
}

fn inFlow(s: *const st.Style) bool {
    return s.display != .none and !s.position.isOut() and s.float == .none;
}

/// Static test for a box whose own margins collapse through it: an empty auto-height block.
fn selfCollapsing(t: anytype, node: u32) bool {
    const n = &t.nodes.items[node];
    const s = n.style;
    if (n.measured or s.display != .block or s.flow_root or s.overflow_x != .visible or s.overflow_y != .visible) return false;
    if (s.border.top > 0 or s.border.bottom > 0 or tr.resolveLp(s.padding.top, 0) > 0 or tr.resolveLp(s.padding.bottom, 0) > 0) return false;
    if (orElse(tr.resolveDim(s.size[1], 0), 0) > 0 or orElse(tr.resolveDim(s.min_size[1], 0), 0) > 0 or s.aspect_ratio != null) return false;
    var k = n.first_child;
    while (k != no_node) : (k = t.nextSibling(k)) {
        if (inFlow(t.nodes.items[k].style)) return false;
    }
    return true;
}

/// Static estimate of the margins that collapse at the top of in-flow child `ch` (its own top margin, those
/// of its first in-flow descendants and of the empty blocks before them), needed to know where the box
/// starts before it is laid out.
fn topSetEst(t: anytype, ch: u32, own: f32) MarginSet {
    var set = (MarginSet{}).with(own);
    var cur = ch;
    var guard: u32 = 0;
    while (guard < tr.max_depth) : (guard += 1) {
        const n = &t.nodes.items[cur];
        const s = n.style;
        if (n.measured or n.child_count == 0 or s.display != .block or s.float != .none or s.flow_root or s.position.isOut() or
            s.overflow_x != .visible or s.overflow_y != .visible or s.border.top > 0 or tr.resolveLp(s.padding.top, 0) > 0) break;
        var k = n.first_child;
        while (k != no_node) : (k = t.nextSibling(k)) {
            const ks = t.nodes.items[k].style;
            if (!inFlow(ks)) continue;
            set = set.with(orElse(tr.resolveDim(ks.margin.top, 0), 0));
            if (ks.clear != .none or !selfCollapsing(t, k)) break;
            set = set.with(orElse(tr.resolveDim(ks.margin.bottom, 0), 0));
        }
        if (k == no_node) break;
        cur = k;
    }
    return set;
}

/// Places float `ch` (CSS 2.1 §9.5.1): shrink-to-fit size, then as high as possible at or below `rq.y_top`
/// and as far to its side as the earlier floats allow. Returns false (nothing placed) when `rq.fit` is set
/// and the float does not fit on its line. `content` grows by the laid out float.
pub noinline fn placeFloat(t: anytype, ch: u32, rq: *const FloatReq, content: *[2]f32) Error!bool {
    const mark = t.scratch.mark();
    defer t.scratch.release(mark);
    const c = try t.scratch.create(t.alloc, FloatS);
    const cs = t.nodes.items[ch].style;
    const inner_w = rq.parent[0];
    t.rbox(&c.cb, cs, rq.parent);
    const cb = &c.cb;
    // (takumi parity: percentage margins of a float compute to 0 there, unlike in Blink)
    inline for (.{ "left", "top", "right", "bottom" }, 0..) |f, i| {
        if (@field(cs.margin, f).hasPercent()) cb.margin[i] = 0;
    }
    const ms = cb.marginSum(0);
    const kh = maxO(clampO(cb.size[1], cb.min[1], cb.max[1]), cb.pb[1]);
    var w = clampO(cb.size[0], cb.min[0], cb.max[0]);
    if (!has(w) and !cs.size[0].isKeyword() and !has(t.ratio(cs, cb, 0, kh))) {
        // shrink-to-fit: min(max-content, max(min-content, available))
        c.ci = .{ .known = .{ NONE, kh }, .parent = rq.parent, .avail = .{ MAXC, MAXC } };
        w = try t.measureChild(ch, &c.ci, 0);
        if (w + ms > inner_w) {
            c.ci = .{ .known = .{ NONE, kh }, .parent = rq.parent, .avail = .{ tr.MINC, MAXC } };
            const mn = try t.measureChild(ch, &c.ci, 0);
            w = @max(mn, inner_w - ms);
        }
        w = clampO(w, cb.min[0], cb.max[0]);
    }
    c.ci = .{ .known = .{ maxO(w, cb.pb[0]), kh }, .parent = rq.parent, .avail = .{ inner_w, MAXC }, .layout = true };
    try t.computeNode(ch, &c.ci, &c.co);

    const bf = t.bfc orelse return true;
    const rects = t.float_rects.items[@min(bf.start, t.float_rects.items.len)..];
    const mw = @max(c.co.size[0] + ms, 0);
    const extra_h: f32 = if (comptime st.frag_enabled) if (ch < t.paged.float_extents.len) t.paged.float_extents[ch] else 0 else 0;
    const mh = @max(c.co.size[1] + cb.margin[1] + cb.margin[3] + extra_h, 0);
    const lo = rq.org[0] + rq.inset_left;
    if (rq.fit) |f| {
        const line_top = rq.org[1] + rq.y_top;
        if (f[0] + mw > f[1] + 1.0 / 128.0 or bf.last_top > line_top + 1.0 / 128.0 or fl.clearY(rects, cs.clear) > line_top + 1.0 / 128.0) return false;
    }
    var top = @max(rq.org[1] + rq.y_top, bf.last_top);
    if (comptime st.frag_enabled) if (ch < t.paged.float_shifts.len) {
        top = @max(top, rq.org[1] + rq.y_top + t.paged.float_shifts[ch]);
    };
    top = @max(top, fl.clearY(rects, cs.clear));
    const p = fl.place(rects, cs.float == .left, mw, mh, top, lo, lo + inner_w);
    bf.last_top = p[1];
    try t.float_rects.append(t.alloc, .{ .x0 = p[0], .y0 = p[1], .x1 = p[0] + mw, .y1 = p[1] + mh, .left = cs.float == .left });
    if (rq.do_layout) {
        const rel: [2]f32 = if (cs.position == .relative) .{
            orElse(t.dim(cs.inset.left, inner_w), -orElse(t.dim(cs.inset.right, inner_w), 0)),
            orElse(t.dim(cs.inset.top, rq.parent[1]), -orElse(t.dim(cs.inset.bottom, rq.parent[1]), 0)),
        } else .{ 0, 0 };
        t.setLayout(ch, .{ p[0] - rq.org[0] + cb.margin[0] + rel[0], p[1] - rq.org[1] + cb.margin[1] + rel[1] }, &c.co, cb);
        t.accumContent(content, ch);
    }
    return true;
}

/// Fits the border box of in-flow child `ch` (a formatting context root or a measured leaf, box already in
/// `c.cb`) next to the floats, after Blink's layout opportunities: at the first position at or below local y
/// `top` where the box fits for its whole height (a box of definite width / a measured leaf needs that width /
/// its min-content width, any other box takes whatever is left). Stores the x shift, the width available to
/// the margin box and the y push in `c.av`.
noinline fn avoidFloats(t: anytype, c: *S, ch: u32, top: f32) Error!void {
    const inner_w = c.parent[0];
    c.av = .{ 0, inner_w, 0 };
    const bf = t.bfc orelse return;
    const rects = t.float_rects.items[@min(bf.start, t.float_rects.items.len)..];
    if (rects.len == 0) return;
    const cb = &c.cb;
    const lo = c.org[0] + c.inset[0];
    const hi = lo + inner_w;
    const kw = clampO(cb.size[0], cb.min[0], cb.max[0]);
    const kh = clampO(cb.size[1], cb.min[1], cb.max[1]);
    var y = c.org[1] + top;
    // minimum border-box width: a definite width, the min-content width of a measured leaf, else anything
    var need = kw;
    if (!has(need) and t.nodes.items[ch].measured) {
        c.ci = .{ .known = .{ NONE, kh }, .parent = c.parent, .avail = .{ tr.MINC, MAXC } };
        need = try t.measureChild(ch, &c.ci, 0);
    }
    need = orElse(need, 0);
    var guard: usize = 0;
    while (guard <= rects.len) : (guard += 1) {
        const e0 = fl.edges(rects, y, 0);
        // (the margins overlap the floats, only the border box avoids them; an opportunity squeezed out of
        // the containing block still exists with zero width, one between overlapping floats does not)
        const left = @max(e0[0], lo + cb.margin[0]);
        const right = @max(@min(e0[1], hi - cb.margin[2]), left);
        c.av = .{ left - lo - cb.margin[0], right - left + cb.marginSum(0), y - c.org[1] - top };
        if (e0[0] <= lo and e0[1] >= hi) return;
        if (e0[0] <= e0[1] and right - left >= need) {
            var bh = kh;
            if (!has(bh)) {
                c.ci = .{ .known = .{ @max(orElse(kw, clampO(right - left, cb.min[0], cb.max[0])), cb.pb[0]), NONE }, .parent = c.parent, .avail = .{ inner_w, MAXC } };
                bh = try t.measureChild(ch, &c.ci, 1);
            }
            // the opportunity must stay free over the whole height of the box, or narrow to one that does
            const e1 = fl.edges(rects, y, bh);
            if (e1[0] == e0[0] and e1[1] == e0[1]) return;
            const l1 = @max(e1[0], lo + cb.margin[0]);
            const r1 = @min(e1[1], hi - cb.margin[2]);
            if (r1 > l1 and r1 - l1 >= need) {
                c.av = .{ l1 - lo - cb.margin[0], r1 - l1 + cb.marginSum(0), y - c.org[1] - top };
                return;
            }
        }
        const nb = fl.nextBottom(rects, y, 0);
        if (!(nb > y)) return;
        y = nb;
    }
}

pub noinline fn compute(t: anytype, node: u32, in_: *const In, out: *Out) Error!void {
    const mark = t.scratch.mark();
    defer t.scratch.release(mark);
    const c = try t.scratch.create(t.alloc, S);
    c.in = in_.*;
    const in = &c.in;
    const n = &t.nodes.items[node];
    const s = n.style;
    t.sbox(&c.box, s, in);
    const box = &c.box;
    c.known = tr.styledKnown(in, box);
    const known = &c.known;
    out.* = .{ .size = known.* };
    if (!in.layout and has(known[0]) and has(known[1])) return;
    in.known = known.*;
    const ratio_w = t.ratioWidth(s, box, in);
    known[0] = in.known[0];

    const inset = &c.inset;
    for (0..4) |i| inset[i] = box.padding[i] + box.border[i];
    const pb = box.pb;
    var inner_h: f32 = if (in.indef_h) NONE else maxO(known[1] - pb[1], 0);

    // container width
    var outer_w = known[0];
    if (!has(outer_w)) {
        const avail_w = in.avail[0] - box.marginSum(0) - pb[0];
        var max_w: f32 = 0;
        // floats sit side by side under a max-content constraint
        var float_w: f32 = 0;
        var ch = n.first_child;
        while (ch != no_node) : (ch = t.nextSibling(ch)) {
            const cs = t.nodes.items[ch].style;
            if (cs.display == .none or cs.position.isOut()) continue;
            const side = (comptime @TypeOf(t.*).config.floats) and cs.float != .none and avail_w != tr.MINC;
            t.rbox(&c.cb, cs, .{ NONE, inner_h });
            const cb = &c.cb;
            const ms = cb.marginSum(0);
            // (a width through the aspect ratio is left to the child: its automatic minimum may apply)
            var w = clampO(cb.size[0], cb.min[0], cb.max[0]);
            if (!has(w)) {
                c.ci = .{
                    .known = .{ NONE, clampO(cb.size[1], cb.min[1], cb.max[1]) },
                    .parent = .{ NONE, inner_h },
                    .avail = .{ if (side) MAXC else avail_w, MAXC },
                };
                w = try t.measureChild(ch, &c.ci, 0);
            }
            w = @max(w, c.cb.pb[0]) + ms;
            if (side) {
                if (cs.clear != .none) float_w = 0;
                float_w += w;
                w = float_w;
            }
            max_w = @max(max_w, w);
        }
        outer_w = maxO(@max(clampO(max_w + pb[0], box.min[0], box.max[0]), pb[0]), ratio_w);
    }
    known[0] = outer_w;
    out.* = .{ .size = .{ outer_w, NONE } };
    if (in.width_only) return;
    {
        const floor_h = t.applyRatio(s, box, known);
        if (has(floor_h)) {
            box.min[1] = floor_h;
            inner_h = @max(floor_h - pb[1], 0);
        } else if (!in.indef_h) inner_h = maxO(known[1] - pb[1], 0);
    }
    out.* = .{ .size = .{ outer_w, known[1] } };
    if (!in.layout and has(known[1])) return;

    const bfc = isRoot(s, in);
    // floats: enter / leave this box's formatting context
    const fl_on = (comptime @TypeOf(t.*).config.floats) and t.has_floats;
    c.prev_bfc = null;
    if (fl_on) {
        c.prev_bfc = t.bfc;
        c.org = t.bfc_org;
        if (bfc or t.bfc == null) {
            c.org = .{ 0, 0 };
            c.bfc = .{ .start = @intCast(t.float_rects.items.len) };
            t.bfc = &c.bfc;
        }
    }
    defer if (fl_on and t.bfc == &c.bfc) {
        t.float_rects.items.len = @min(c.bfc.start, t.float_rects.items.len);
        t.bfc = c.prev_bfc;
    };
    const collapse_top = !bfc and inset[1] == 0;
    var collapse_bottom = !bfc and inset[3] == 0 and !has(known[1]);
    const prevents_collapse_through = bfc or inset[1] > 0 or inset[3] > 0 or known[1] > 0 or box.min[1] > 0;

    const inner_w = @max(outer_w - pb[0], 0);
    c.parent = .{ inner_w, inner_h };

    var n_abs: usize = 0;
    var abs: []AbsItem = &.{};
    if (in.layout) {
        var ch = n.first_child;
        while (ch != no_node) : (ch = t.nextSibling(ch)) {
            const cs = t.nodes.items[ch].style;
            if (cs.display != .none and cs.position.isOut()) n_abs += 1;
        }
        if (n_abs > 0) abs = try t.scratch.alloc(t.alloc, AbsItem, n_abs);
        n_abs = 0;
    }

    c.content = .{ 0, 0 };
    var y = inset[1];
    c.resume_dy = 0;
    var y_abs = y;
    c.first_set = .{};
    c.active = .{};
    var with_first = true;
    var all_through = true;
    var first_bl: f32 = NONE;
    var last_bl: f32 = NONE;

    var ch = n.first_child;
    while (ch != no_node) : (ch = t.nextSibling(ch)) {
        const cs = t.nodes.items[ch].style;
        if (cs.display == .none) {
            if (in.layout) t.hide(ch);
            continue;
        }
        if (cs.position.isOut()) {
            if (in.layout) {
                abs[n_abs] = .{ .node = ch, .y = y_abs };
                n_abs += 1;
            }
            continue;
        }
        if (fl_on and cs.float != .none) {
            c.frq = .{ .parent = c.parent, .org = .{ c.org[0], c.org[1] + c.resume_dy }, .inset_left = inset[0], .y_top = y + (if (with_first and collapse_top) 0 else c.active.resolve()), .do_layout = in.layout };
            _ = try placeFloat(t, ch, &c.frq, &c.content);
            continue;
        }
        t.rbox(&c.cb, cs, c.parent);
        const cb = &c.cb;
        const ms = cb.marginSum(0);
        const ckh = maxO(clampO(cb.size[1], cb.min[1], cb.max[1]), cb.pb[1]);
        // floats: clearance, the band left free by the floats, the child's origin in the formatting context
        var fx: f32 = 0;
        var band_w = inner_w;
        if (fl_on) {
            const cn = &t.nodes.items[ch];
            const est: f32 = if (with_first and collapse_top) 0 else c.active.merge(topSetEst(t, ch, cb.margin[1])).resolve();
            if (cs.clear != .none) {
                const cy = fl.clearY(t.float_rects.items[@min(t.bfc.?.start, t.float_rects.items.len)..], cs.clear) - c.org[1] - c.resume_dy;
                if (cy > y + est) y = cy - est;
            }
            // (inline content keeps its box and has its lines shortened instead: flow.zig)
            const lines = (comptime @TypeOf(t.*).config.inline_fn) and t.inline_fn != null and cs.is_inline_content and
                (cn.measured or cs.display == .inline_row) and !isRoot(cs, &.{ .collapse = true });
            if (!lines and (cn.measured or cs.display != .block or isRoot(cs, &.{ .collapse = true }))) {
                try avoidFloats(t, c, ch, y + est + c.resume_dy);
                fx = c.av[0];
                band_w = c.av[1];
                y += c.av[2];
            } else {
                var ml = cb.margin[0];
                if (cb.margin_auto[0] and has(cb.size[0])) {
                    const free = @max(inner_w - clampO(cb.size[0], cb.min[0], cb.max[0]) - ms, 0);
                    ml = if (cb.margin_auto[2]) t.div(free, 2) else free;
                } else if (s.rtl and !cb.margin_auto[2] and has(cb.size[0])) {
                    ml += inner_w - clampO(cb.size[0], cb.min[0], cb.max[0]) - ms;
                }
                t.bfc_org = .{ c.org[0] + inset[0] + ml, c.org[1] + y + est + c.resume_dy };
            }
        }
        // width: explicit, else from a definite height through the aspect ratio, else fill the container
        const ckw = orElse(cb.size[0], band_w - ms);
        // (width: min-/max-/fit-content does not fill: the child sizes itself against the available width;
        // so does a child whose width follows from its height through the aspect ratio)
        const self_sized = cs.size[0].isKeyword() or t.nodes.items[ch].replaced or (!has(cb.size[0]) and has(t.ratio(cs, cb, 0, ckh)));
        c.ci = .{
            .known = .{ if (self_sized) NONE else @max(clampO(ckw, cb.min[0], cb.max[0]), cb.pb[0]), ckh },
            .parent = c.parent,
            .avail = .{ band_w, MAXC },
            .layout = true,
            .collapse = true,
        };
        try t.computeNode(ch, &c.ci, &c.co);
        const o = &c.co;

        const top_set = o.top_margin.with(cb.margin[1]);
        const bottom_set = o.bottom_margin.with(cb.margin[3]);

        // auto horizontal margins
        const free_x = @max(band_w - o.size[0] - ms, 0);
        const n_auto: f32 = @floatFromInt(@as(u8, @intFromBool(cb.margin_auto[0])) + @intFromBool(cb.margin_auto[2]));
        if (n_auto > 0) {
            if (cb.margin_auto[0]) cb.margin[0] = t.div(free_x, n_auto);
            if (cb.margin_auto[2]) cb.margin[2] = t.div(free_x, n_auto);
        }
        // right-to-left: an over-constrained box keeps its right margin (the left one takes the rest)
        if (s.rtl and n_auto == 0) fx += band_w - o.size[0] - ms;
        cb.margin[1] = top_set.resolve();
        cb.margin[3] = bottom_set.resolve();

        const y_margin: f32 = if (with_first and collapse_top) 0 else c.active.merge(top_set).resolve();
        if (in.layout) {
            const rel: [2]f32 = .{
                t.relX(cs, inner_w, s.rtl),
                orElse(t.dim(cs.inset.top, inner_h), -orElse(t.dim(cs.inset.bottom, inner_h), 0)),
            };
            t.setLayout(ch, .{ inset[0] + fx + cb.margin[0] + rel[0], y + y_margin + rel[1] }, o, cb);
            t.accumContent(&c.content, ch);
            if (!has(first_bl) and has(o.baseline)) first_bl = y + y_margin + o.baseline;
            if (has(o.last_baseline) or has(o.baseline)) last_bl = y + y_margin + orElse(o.last_baseline, o.baseline);
        }

        if (with_first) {
            c.first_set = c.first_set.merge(top_set);
            if (o.collapse_through) c.first_set = c.first_set.merge(bottom_set) else with_first = false;
        }
        if (o.collapse_through) {
            c.active = c.active.merge(top_set).merge(bottom_set);
            y_abs = y + o.size[1] + y_margin;
        } else {
            all_through = false;
            y += o.size[1] + y_margin;
            c.active = bottom_set;
            y_abs = y + c.active.resolve();
        }
        if (comptime st.frag_enabled) if (t.paged.inline_resume) |continuation| {
            var ancestor = continuation.node;
            while (ancestor < t.nodes.items.len) : (ancestor = t.nodes.items[ancestor].parent) {
                if (ancestor == ch) {
                    c.resume_dy = continuation.dy;
                    break;
                }
            }
        };
    }

    if (fl_on and t.bfc == &c.bfc) {
        // a formatting context root grows to contain its floats
        const fb = fl.bottom(t.float_rects.items[@min(c.bfc.start, t.float_rects.items.len)..]) - c.resume_dy;
        if (fb > y + c.active.resolve()) {
            y = fb;
            c.active = .{};
        }
    }
    y += inset[3];
    if (collapse_bottom and box.min[1] > y) {
        // min-height enlarges the box: the last child's margin stays inside and is not propagated
        collapse_bottom = false;
        c.active = .{};
    }
    // (when every child collapsed through and the top collapses, these margins already left through the top)
    if (!collapse_bottom and !(with_first and collapse_top)) y += c.active.resolve();
    const outer_h = @max(orElse(known[1], clampO(@max(y, 0), box.min[1], box.max[1])), pb[1]);
    out.* = .{ .size = .{ outer_w, outer_h } };
    if (!in.layout) return;

    if (n_abs > 0) {
        c.area = .{ box.border[0], box.border[1], outer_w - box.border[0] - box.border[2], outer_h - box.border[1] - box.border[3] };
        for (abs[0..n_abs]) |a| {
            c.sp = .{ .rect = .{ inset[0], a.y, inner_w, 0 }, .al = .{ if (s.rtl) 2 else 0, 0 } };
            // (an outside list marker beside the first baseline of the item's content)
            if (t.nodes.items[a.node].style.list_marker and has(first_bl)) {
                c.sp.rect[1] = first_bl;
                c.sp.al[1] = 3;
            }
            try t.placeAbsolute(node, a.node, &c.area, &c.sp);
            t.accumContent(&c.content, a.node);
        }
    }
    out.content = c.content;
    out.baseline = first_bl;
    out.last_baseline = last_bl;
    if (collapse_top) out.top_margin = c.first_set;
    if (collapse_bottom) out.bottom_margin = c.active;
    out.collapse_through = !prevents_collapse_through and all_through and outer_h == 0;
}
