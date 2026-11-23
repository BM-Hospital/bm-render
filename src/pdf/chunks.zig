//! Long documents drawn a part at a time (paged.zig `writeChunked`): the content is cut at forced
//! page breaks between the block children of one element (the flow), each part is laid out in a
//! frame of its own (`Frame.initChunk`, sharing the document's element model and styles), drawn,
//! and released before the next part is laid out, so the live layout memory is one part's.
//!
//! `plan` decides where the document may be cut so that the parts laid out on their own give
//! exactly the pages, links, outline and structure tree of the whole document laid out at once,
//! and refuses (null: the document is laid out whole) when it cannot tell:
//!
//! * the flow is the root element, or the only block child of a flow candidate, down the tree,
//!   while the element is a plain block (no box decoration, size, offset, effect, generated
//!   content, structure role or anchor): such an element looks the same around any part;
//! * a cut sits between two block-level in-flow element children of the flow, where one breaks
//!   the page (`break-after` of the first, `break-before` of the second: `page`, `left`, `right`,
//!   `recto`, `verso`, `always`);
//! * no `position: fixed` box (it repeats on every page), no float, no absolutely positioned box
//!   whose containing block is outside its child of the flow;
//! * a `#fragment` link to an element of a later part joins the parts between them (the link's
//!   annotation is decided when its part is drawn: paged.zig).
//!
//! What the caller checks too: uniform page width, no page counter in the content, no page rules
//! that depend on the root.
//!
//! A document with no such forced break (or whose parts links join) may still be cut at any page
//! boundary (`Flow`, paged.zig `FlowIter`): the same flow and the same conditions, every child of
//! the flow a block; a part lays out the children of the flow from the one holding its first
//! page's start, and the page it stops at is chosen as it is laid out. A child may hold a part's
//! start (`Flow.cuttable`) unless a `#fragment` link in it or before it reaches it or a later
//! child. The start may be inside a table (between its rows), a flex container or a grid (before
//! a line, a row or an item of a single flow) as well as inside blocks: any start that is one point
//! (paged.zig `resumeKid`); a row broken inside (parallel flows) is no start a part can take.
const std = @import("std");
const render = @import("../render.zig");
const style = @import("../style/style.zig");
const counters = @import("counters.zig");
const memtrace = @import("../memtrace.zig");

const Allocator = std.mem.Allocator;
const Frame = render.Frame;
const CS = style.ComputedStyle;
const none = render.none;
const Error = render.Error;

/// Where a document is cut: the parts are the children of source element `parent` from
/// `starts[k]` (a child's element index) to the next part's start.
pub const Plan = struct {
    parent: u32,
    starts: []const u32,
    parts: []const Part = &.{},
};

/// A part's children of the flow, as element index ranges [lo, hi) in source order: its own, and
/// those its frame lays out: the last child of the part before (`prev`) and the first child of
/// the part after (`next`) too, so the pages at its edges are broken and drawn as in the whole
/// document (a box starting a page also has an empty fragment at the bottom of the page before,
/// where its content regions open: takumi, and `emit` drawing the whole document).
pub const Part = struct {
    lo: u32,
    hi: u32,
    own_lo: u32,
    own_hi: u32,
    prev: u32 = none,
    next: u32 = none,
    /// its last child (none: the last part, whose content ends the document)
    last: u32 = none,
};

/// The child before `i` that generates a box (no blank text, no `display: none` element).
fn prevElement(f: *const Frame, i: u32) u32 {
    var c = f.dom.at(i).prev;
    while (c != none and (blankText(f, c) or hidden(f, c))) c = f.dom.at(c).prev;
    return c;
}

fn hidden(f: *const Frame, i: u32) bool {
    return !bareText(f, i) and f.dom.at(i).cs.display == .none;
}

/// Text that is no element (an element holding only text, `<p>text</p>`, is `kind == .text` too).
fn bareText(f: *const Frame, i: u32) bool {
    const e = f.dom.at(i);
    return e.run or (e.kind == .text and e.tag.len == 0);
}

fn parts(a: Allocator, f: *const Frame, starts: []const u32) Error![]const Part {
    const out = try a.alloc(Part, starts.len);
    const max = std.math.maxInt(u32);
    for (starts, 0..) |s, k| {
        const own_hi = if (k + 1 < starts.len) starts[k + 1] else max;
        var pt: Part = .{ .lo = s, .hi = own_hi, .own_lo = s, .own_hi = own_hi };
        if (k > 0) {
            pt.prev = prevElement(f, s);
            pt.lo = pt.prev;
        }
        if (k + 1 < starts.len) {
            pt.last = prevElement(f, starts[k + 1]);
            pt.next = starts[k + 1];
            const after = f.dom.at(pt.next).next;
            pt.hi = if (after == none) max else after;
        }
        out[k] = pt;
    }
    return out;
}

fn no(comptime why: []const u8) void {
    memtrace.mark("chunks: whole: " ++ why);
}

fn zeroLp(v: style.computed.LP) bool {
    return v.calc == null and v.px == 0 and v.pct == 0;
}

fn zeroMargin(v: style.computed.LengthAuto) bool {
    return switch (v) {
        .auto => false,
        .lp => |x| zeroLp(x),
    };
}

/// An element that looks the same around any part of its content: a block box without anything
/// that draws, sizes, moves or names it.
fn plainBlock(f: *const Frame, i: u32) bool {
    const e = f.dom.at(i);
    if (e.kind != .container or e.run or e.generated) return false;
    if (e.before != none or e.after != none or e.own != none) return false;
    if (e.id.len > 0) return false;
    if (!plainTag(e.tag)) return false;
    const cs = e.cs;
    if (!(cs.display == .block or cs.display == .flow_root)) return false;
    if (cs.position != .static or cs.float != .none) return false;
    if (cs.overflow_x != .visible or cs.overflow_y != .visible) return false;
    if (cs.height != .auto or cs.max_height != .auto) return false;
    switch (cs.min_height) {
        .auto => {},
        .lp => |x| if (!zeroLp(x)) return false,
        else => return false,
    }
    // (what the parts would repeat or cut: the block's own edges)
    for ([_]usize{ 0, 2 }) |side| {
        if (!zeroMargin(cs.margin[side]) or !zeroLp(cs.padding[side])) return false;
    }
    for (cs.border_style) |b| if (b != .none) return false;
    if (cs.outline_style != .none) return false;
    switch (cs.background_color) {
        .rgba => |c| if (c.a != 0) return false,
        .current => return false,
    }
    if (cs.background_image.len > 0 or cs.box_shadow.len > 0 or cs.filter.len > 0 or cs.backdrop_filter.len > 0 or cs.transform.len > 0) return false;
    if (cs.opacity != 1 or cs.mix_blend_mode != .normal or cs.isolation != .auto) return false;
    if (cs.clip_path != null or cs.mask_image.len > 0 or cs.offset_path != null) return false;
    if (cs.rotate != 0 or cs.scale[0] != 1 or cs.scale[1] != 1 or !zeroLp(cs.translate[0]) or !zeroLp(cs.translate[1])) return false;
    return true;
}

/// Tags without a structure role (tags.zig `roleOf`) or a meaning of their own.
fn plainTag(tag: []const u8) bool {
    if (tag.len == 0) return true;
    for ([_][]const u8{ "div", "body", "html", "main" }) |t| if (std.ascii.eqlIgnoreCase(tag, t)) return true;
    return false;
}

fn forced(b: style.computed.BreakBetween) bool {
    return switch (b) {
        .page, .always, .left, .right, .recto, .verso => true,
        else => false,
    };
}

/// A child of the flow a part may start or end at: an in-flow block-level element.
fn blockChild(f: *const Frame, i: u32) bool {
    const e = f.dom.at(i);
    if (bareText(f, i) or e.generated) return false;
    const cs = e.cs;
    if (cs.position != .static and cs.position != .relative) return false;
    if (cs.float != .none) return false;
    return switch (cs.display) {
        .block, .flow_root, .list_item, .table, .flex, .grid => true,
        else => false,
    };
}

fn blankText(f: *const Frame, i: u32) bool {
    const e = f.dom.at(i);
    if (!bareText(f, i)) return false;
    return std.mem.trim(u8, e.text, " \t\r\n\x0c").len == 0;
}

/// The flow: from the root down the plain blocks that hold one element child (null: a box around
/// the content draws, sizes or names itself).
fn findFlow(f: *const Frame) ?u32 {
    const d = &f.dom;
    var flow = d.root;
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        if (!plainBlock(f, flow)) return null;
        var only: u32 = none;
        var count: u32 = 0;
        var c = d.at(flow).first;
        while (c != none) : (c = d.at(c).next) {
            if (blankText(f, c)) continue;
            count += 1;
            only = c;
        }
        if (count == 1 and d.at(only).kind == .container and !d.at(only).run) {
            flow = only;
            continue;
        }
        break;
    }
    return flow;
}

/// Whether the elements of the document stay in their child of `flow`: nothing that repeats on
/// every page, floats or escapes its part (false after a memory checkpoint naming it).
fn staysInParts(f: *const Frame, flow: u32) bool {
    for (f.dom.els.items, 0..) |*e, idx| {
        if (bareText(f, @intCast(idx))) continue;
        const cs = e.cs;
        if (cs.display == .none) continue;
        if (cs.position == .fixed) {
            no("a fixed box");
            return false;
        }
        if (cs.float != .none) {
            no("a float");
            return false;
        }
        if (cs.position == .absolute and !containedBelow(f, @intCast(idx), flow)) {
            no("an absolute box escapes its part");
            return false;
        }
    }
    return true;
}

/// A document cut at any page boundary (paged.zig `writeFlowing`): its parts start at the page
/// boundaries found as the document is laid out, a part's frame laying out the children of the
/// flow from the one holding its first page's start (chunks.zig file comment).
pub const Flow = struct {
    parent: u32,
    /// the flow's children that generate a box (element indices, source order)
    kids: []const u32,
    /// per kid: a part may start inside it or at it (no `#fragment` link in it or before it
    /// reaches it or a kid after it: the link's annotation is decided when its part is drawn)
    cuttable: []const bool,

    /// The index in `kids` of the child of the flow holding element `el` (null: none).
    pub fn kidOf(fl: *const Flow, f: *const Frame, el: u32) ?usize {
        var cur = el;
        var guard: u32 = 0;
        while (cur != none and guard < 4096) : (guard += 1) {
            const up = f.dom.at(cur).parent;
            if (up == fl.parent) {
                const k = std.sort.lowerBound(u32, fl.kids, cur, struct {
                    fn order(x: u32, y: u32) std.math.Order {
                        return std.math.order(x, y);
                    }
                }.order);
                return if (k < fl.kids.len and fl.kids[k] == cur) k else null;
            }
            cur = up;
        }
        return null;
    }
};

/// The flowing plan of `f`'s document, whose flow (`findFlow`) is `flow`: every child of the flow
/// that generates a box is a block (an inline child would sit in an anonymous block spanning
/// several of them). Null: it cannot be cut.
fn flowPlan(a: Allocator, f: *const Frame, flow: u32) Error!?Flow {
    const d = &f.dom;
    var kids: std.ArrayList(u32) = .empty;
    var c = d.at(flow).first;
    while (c != none) : (c = d.at(c).next) {
        if (blankText(f, c) or hidden(f, c)) continue;
        if (!blockChild(f, c)) {
            no("a child of the flow is not a block");
            return null;
        }
        try kids.append(a, c);
    }
    if (kids.items.len < 2) {
        no("the flow has fewer than two children");
        return null;
    }
    var fl: Flow = .{ .parent = flow, .kids = kids.items, .cuttable = &.{} };
    const cuttable = try a.alloc(bool, kids.items.len);
    @memset(cuttable, true);
    // per element id, the last kid holding an element with it (interactive.zig takes the first
    // box with the id: an earlier element may have no box)
    var ids: std.StringHashMapUnmanaged(usize) = .empty;
    for (d.els.items, 0..) |*e, idx| {
        if (e.run or e.id.len == 0) continue;
        const k = fl.kidOf(f, @intCast(idx)) orelse continue;
        const gop = try ids.getOrPut(a, e.id);
        if (!gop.found_existing or k > gop.value_ptr.*) gop.value_ptr.* = k;
    }
    // (a kid holding a positioned or transformed box may hold a start too: both parts lay the
    // whole kid out, so its lifted boxes are painted and tagged in the same page passes; a box
    // that paints onto a page of the part before or after is refused when the part is laid out,
    // paged.zig `FlowIter.lay`)
    for (d.els.items, 0..) |*e, idx| {
        if (e.run) continue;
        const href = d.attr(@intCast(idx), "href") orelse continue;
        if (href.len < 2 or href[0] != '#') continue;
        const id = try counters.percentDecode(a, href[1..]);
        const to = ids.get(id) orelse continue;
        const from = fl.kidOf(f, @intCast(idx)) orelse continue;
        if (to >= from) @memset(cuttable[from .. to + 1], false);
    }
    fl.cuttable = cuttable;
    return fl;
}

/// How a document is cut: at its forced page breaks (`Plan`), or at page boundaries found as it is
/// laid out (`Flow`).
pub const Cut = union(enum) { forced: Plan, flowing: Flow };

/// Where `f`'s document (its element model and styles: `Frame.prepareDocument`) may be cut, or
/// null when it cannot be cut safely (see the file comment): at forced page breaks when it has at
/// least two parts of `min_elements` there, else at any page boundary between or inside the
/// children of the flow (`flowPlan`).
pub fn plan(a: Allocator, f: *const Frame, min_elements: u32) Error!?Cut {
    const d = &f.dom;
    if (d.root == none) return null;
    const flow = findFlow(f) orelse {
        no("the flow or a box around it draws, sizes or names itself");
        return null;
    };
    if (!staysInParts(f, flow)) return null;
    if (try forcedPlan(a, f, flow, min_elements)) |p| return .{ .forced = p };
    const fl = try flowPlan(a, f, flow) orelse return null;
    return .{ .flowing = fl };
}

/// A forced-break plan not taken (the document may still be cut at other page boundaries).
fn soft(comptime why: []const u8) ?Plan {
    memtrace.mark("chunks: no forced cut: " ++ why);
    return null;
}

fn forcedPlan(a: Allocator, f: *const Frame, flow: u32, min_elements: u32) Error!?Plan {
    const d = &f.dom;
    // the cuts
    var starts: std.ArrayList(u32) = .empty;
    var prev: u32 = none;
    var c = d.at(flow).first;
    while (c != none) : (c = d.at(c).next) {
        if (blankText(f, c)) continue;
        const e = d.at(c);
        if (hidden(f, c)) continue;
        if (!blockChild(f, c)) {
            prev = none;
            if (starts.items.len == 0) try starts.append(a, c);
            continue;
        }
        if (starts.items.len == 0) {
            try starts.append(a, c);
        } else if (prev != none and (forced(d.at(prev).cs.break_after) or forced(e.cs.break_before))) {
            try starts.append(a, c);
        }
        prev = c;
    }
    if (starts.items.len < 2) return soft("no forced page break between the flow's blocks");
    var p: Plan = .{ .parent = flow, .starts = starts.items };
    // a link to a later part joins the parts from the link's to the target's
    try joinForwardLinks(a, f, &p, &starts);
    // parts of at least `min_elements` source elements (a part's frame also lays out a child of
    // each neighbour: small parts would lay most of the document out three times)
    {
        var kept: std.ArrayList(u32) = .empty;
        for (starts.items) |st| {
            if (kept.items.len == 0 or st - kept.items[kept.items.len - 1] >= min_elements) try kept.append(a, st);
        }
        starts = kept;
    }
    if (starts.items.len < 2) return soft("links ahead join every part");
    p.starts = starts.items;
    // (a part's edge children are block elements: a start is one, and the child before it ended
    // the part before)
    for (p.starts[1..]) |st| {
        const pv = prevElement(f, st);
        if (pv == none or !blockChild(f, pv)) return soft("a part does not follow a block");
    }
    p.parts = try parts(a, f, p.starts);
    return p;
}

/// Whether the anchors and headings collected for part `chunk` (laid out as `pt`) are elements of
/// it (a box moved past the part's edge would be collected by the wrong part).
pub fn ownsCollected(f: *const Frame, parent: u32, pt: Part, anchors: anytype, headings: anytype, chunk: u32) bool {
    const own = struct {
        fn of(fr: *const Frame, flow: u32, part: Part, el: u32) bool {
            var cur = el;
            var guard: u32 = 0;
            while (cur != none and guard < 4096) : (guard += 1) {
                const up = fr.dom.at(cur).parent;
                if (up == flow) return cur >= part.own_lo and cur < part.own_hi;
                cur = up;
            }
            return false;
        }
    };
    var it = anchors.valueIterator();
    while (it.next()) |an| if (an.chunk == chunk and !own.of(f, parent, pt, an.el)) return false;
    for (headings) |h| if (h.chunk == chunk and !own.of(f, parent, pt, h.el)) return false;
    return true;
}

/// Whether absolutely positioned element `i` has its containing block inside its child of `flow`.
fn containedBelow(f: *const Frame, i: u32, flow: u32) bool {
    const d = &f.dom;
    var cur = d.at(i).parent;
    var guard: u32 = 0;
    while (cur != none and cur != flow and guard < 4096) : (guard += 1) {
        const e = d.at(cur);
        // (the child of the flow itself may be the containing block)
        if (e.cs.position != .static) return true;
        if (e.cs.transform.len > 0) return true;
        cur = e.parent;
    }
    return false;
}

/// The part element `i` is in (`p.parent`'s child holding it; none: outside the parts).
fn partOf(f: *const Frame, p: *const Plan, i: u32) ?usize {
    const d = &f.dom;
    var cur = i;
    var guard: u32 = 0;
    while (cur != none and guard < 4096) : (guard += 1) {
        const parent = d.at(cur).parent;
        if (parent == p.parent) {
            var k: usize = p.starts.len;
            while (k > 0) {
                k -= 1;
                if (cur >= p.starts[k]) return k;
            }
            return null;
        }
        cur = parent;
    }
    return null;
}

fn joinForwardLinks(a: Allocator, f: *const Frame, p: *Plan, starts: *std.ArrayList(u32)) Error!void {
    const d = &f.dom;
    // per element id, the last part holding an element with it (interactive.zig takes the first
    // box with the id: an earlier element may have no box, so any of them may be the anchor)
    var ids: std.StringHashMapUnmanaged(usize) = .empty;
    for (d.els.items, 0..) |*e, idx| {
        if (e.run or e.id.len == 0) continue;
        const part = partOf(f, p, @intCast(idx)) orelse continue;
        const gop = try ids.getOrPut(a, e.id);
        if (!gop.found_existing or part > gop.value_ptr.*) gop.value_ptr.* = part;
    }
    // per part: the last part a link in it reaches
    const reach = try a.alloc(usize, p.starts.len);
    for (reach, 0..) |*r, k| r.* = k;
    for (d.els.items, 0..) |*e, idx| {
        if (e.run) continue;
        const href = d.attr(@intCast(idx), "href") orelse continue;
        if (href.len < 2 or href[0] != '#') continue;
        const id = try counters.percentDecode(a, href[1..]);
        const to = ids.get(id) orelse continue;
        const from = partOf(f, p, @intCast(idx)) orelse continue;
        if (to > reach[from]) reach[from] = to;
    }
    // keep a start only when no earlier part links past it
    var out: std.ArrayList(u32) = .empty;
    var farthest: usize = 0;
    for (p.starts, 0..) |s, k| {
        if (k == 0 or k > farthest) try out.append(a, s);
        farthest = @max(farthest, reach[k]);
    }
    starts.* = out;
}
