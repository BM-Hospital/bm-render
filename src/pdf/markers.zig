//! List markers (takumi-core `layout/list_marker.rs`, `style/properties/list_style.rs`,
//! `layout/inline/unpositioned_list_marker.rs`, the symbol painting of `painter/text.rs`; Blink's
//! `ListMarker`, `ListItemOrdinal`, `LayoutOutsideListMarker`).
//!
//! A `display: list-item` element gets a marker box, generated here between the cascade and the
//! render-node build (render.zig `Frame.prepare`; PDF builds, the frames a PDF is drawn from: see
//! `render.zig listMarkers`, the one gate):
//!
//! * the ordinal: Blink's `ListItemOrdinal::CalcValue` with `CSSListCounterAccounting` off, as
//!   takumi numbers items: within the nearest enclosing list owner (`ol` / `ul` / `menu`, or a box
//!   with `contain: style`), else within the parent; `ol start` / `reversed`, `li value`,
//!   `counter-set` / `counter-increment` of `list-item`; nothing inside `display: none` counts;
//! * the text: takumi's twelve counter styles (`marker_text`: a `. ` suffix, a space after a
//!   symbol), a string as written; any other counter-style name as counters.zig formats it;
//! * the box (takumi `list_marker`): it inherits from the item; outside, an atomic inline
//!   (`inline-block`, `white-space: pre`) whose margins hang it `InlineMarginsForOutside` before the
//!   item's border edge while it takes no room on the line (takumi places it beside the first
//!   line box; the margins net to zero, so the line is the same and its baseline carries the
//!   marker); inside, an inline (text) or an inline-block (a symbol) with
//!   `InlineMarginsForInside`;
//! * a symbol (`disc`, `circle`, `square`, `disclosure-*`) is no glyph: its box is
//!   `WidthOfSymbol` wide, holds a preserved space for its line, and the PDF text painter fills /
//!   strokes the shape (`paintSymbol`, Blink's `PaintSymbol`).
//!
//! An outside marker of an item whose first content is a block joins that block's first line (takumi
//! aligns it with that block's first baseline, still hung off the item). An item whose first content
//! is a flex / grid / table / replaced box has no line for it to join: the marker is then a
//! block-level box of the item that the layout takes out of flow and places with its baseline on
//! the item's first baseline (the first in-flow child with one; at the content top when none has
//! one: Blink's `PositionListMarkerBesideChild` / `PositionListMarkerWithoutLineBoxes`,
//! `layout.Style.list_marker`); it paints and is tagged in tree order, before the item's content.
//! URL marker images use their intrinsic dimensions; missing/gradient images fall back to counters.
//! Not covered: `::marker` rules (takumi matches none), floats intruding on the marker
//! (`list_marker_intruded_float_offset`).
const std = @import("std");
const render = @import("../render.zig");
const style = @import("../style/style.zig");
const dom_mod = @import("../dom.zig");
const counters = @import("counters.zig");

const Allocator = std.mem.Allocator;
const Frame = render.Frame;
const CS = render.CS;
const none = render.none;
const Error = render.Error;

/// Blink's `kCMarkerPaddingPx`.
const marker_gap_px: f32 = 7;
/// Blink's `kCUAMarkerMarginEm`.
const inside_symbol_gap_em: f32 = 1;
/// Blink's `kClosureMarkerMarginEm`.
const inside_disclosure_gap_em: f32 = 0.4;
/// Blink's `DisclosureSymbolSize`, in ems.
const disclosure_size_em: f32 = 0.66;

pub const Shape = enum { disc, circle, square, disclosure_left, disclosure_right, disclosure_down };

/// A generated marker.
pub const Info = struct {
    /// the list item element (dom index)
    item: u32,
    /// the element whose first line holds the marker (the item, or a block it starts with)
    host: u32,
    /// the host's `::before` the marker goes in front of (pseudo index, none = none)
    before: u32 = none,
    outside: bool,
    /// a symbol's shape, its box width and where it paints: the top-left offset from the start of
    /// the marker's text on its baseline, and the side of the square it fills
    shape: ?Shape = null,
    symbol_w: f32 = 0,
    image_width: ?f32 = null,
    off_x: f32 = 0,
    off_y: f32 = 0,
    side: f32 = 0,
    /// Blink's `InlineMarginsForOutside` start margin of a symbol (from the item's border edge)
    symbol_start: f32 = 0,
    /// outside: how far the content edge of the host's first line sits in from the item's border
    /// edge (the marker's margins hang it from the latter)
    inset: f32 = 0,
    /// the marker's render node (none until built)
    node: u32 = none,
    /// outside, with no line to join (the item starts with a flex / grid / table / replaced box):
    /// an absolutely positioned box of the item that the layout places with its baseline on the
    /// item's first baseline (`layout.Style.list_marker`)
    beside: bool = false,
};

/// Whether render node `id` is an outside marker placed beside its item's first baseline.
pub fn besideBaseline(f: *const Frame, id: u32) bool {
    const info = ofNode(f, id) orelse return false;
    return info.beside;
}

pub const State = struct {
    infos: std.ArrayList(Info) = .empty,
    /// pseudo index -> info index
    by_pseudo: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// render node -> info index
    by_node: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// the list items with a marker (dom indices)
    items: std.AutoHashMapUnmanaged(u32, void) = .empty,
};

/// The list markers of a frame laying out a part of `doc`'s document (`Frame.initChunk`): the
/// document's, with render node bindings of its own.
pub fn forChunk(doc: *const Frame, a: Allocator) Error!?*anyopaque {
    const s = stateOf(doc) orelse return null;
    const c = try a.create(State);
    c.* = .{ .by_pseudo = s.by_pseudo, .items = s.items };
    try c.infos.appendSlice(a, s.infos.items);
    return @ptrCast(c);
}

fn stateOf(f: *const Frame) ?*State {
    const p = f.tree.paged.markers orelse return null;
    return @ptrCast(@alignCast(p));
}

/// The info of the marker generated as pseudo `p`, if it is one.
pub fn ofPseudo(f: *const Frame, p: u32) ?*Info {
    const s = stateOf(f) orelse return null;
    const k = s.by_pseudo.get(p) orelse return null;
    return &s.infos.items[k];
}

/// The info of the marker render node `id`, if it is one.
pub fn ofNode(f: *const Frame, id: u32) ?*const Info {
    const s = stateOf(f) orelse return null;
    const k = s.by_node.get(id) orelse return null;
    return &s.infos.items[k];
}

/// The `::before` box the marker pseudo `p` displaced from its host's first generated slot (the
/// host iterates the marker, then this box), none when `p` is no marker or the host has none.
pub fn chainedBefore(f: *const Frame, p: u32) u32 {
    const info = ofPseudo(f, p) orelse return none;
    return info.before;
}

/// Whether list item element `el` generated a marker (takumi makes it the item's first child).
pub fn hasMarker(f: *const Frame, el: u32) bool {
    const s = stateOf(f) orelse return false;
    return s.items.contains(el);
}

/// The render node of the list item whose marker node `id` is (takumi `marker_tag_target`: its
/// `Lbl` holds the marker), null when `id` is no marker.
pub fn labelOwner(f: *const Frame, id: u32) ?u32 {
    if (stateOf(f) == null) return null;
    // (an image marker's content is the replaced box inside the marker box)
    var mk = id;
    var up: u32 = 0;
    const info = while (true) : (up += 1) {
        if (ofNode(f, mk)) |i| break i;
        if (up == 2 or (up == 0 and f.nodes.items[mk].kind != .image)) return null;
        mk = f.nodes.items[mk].parent;
        if (mk == none) return null;
    };
    var cur = f.nodes.items[mk].parent;
    var guard: u32 = 0;
    while (cur != none and guard < 4096) : (guard += 1) {
        const n = &f.nodes.items[cur];
        if (n.el == info.item and n.kind != .anon_text and n.kind != .anon_box) return cur;
        cur = n.parent;
    }
    return null;
}

/// Where the marker box among the children of line container `id` paints, when not after the
/// container's text (takumi's tree holds an outside marker as its item's first child, an inside
/// one as text of the line):
/// * `before_text`: an outside marker whose line is not the item's own inline layout (the item
///   holds block-level content, or the line belongs to a block the item starts with) paints
///   before that content, so its label precedes the body in the content order;
/// * `in_text`: an inside symbol paints with the line's text, in the same content sequence.
pub const Placement = struct { node: u32, how: enum { before_text, in_text } };

pub fn placement(f: *const Frame, id: u32) ?Placement {
    if (stateOf(f) == null) return null;
    const n = &f.nodes.items[id];
    var c = n.first_child;
    var guard: u32 = 0;
    while (c != none and guard < 64) : (guard += 1) {
        if (ofNode(f, c)) |info| {
            if (!info.outside) return if (info.shape != null) .{ .node = c, .how = .in_text } else null;
            if (n.parent != none and @import("tags.zig").standsForParent(f, id)) {
                const p = &f.nodes.items[n.parent];
                if (p.el == info.item and p.kind != .anon_text and p.kind != .anon_box) return null;
            }
            return .{ .node = c, .how = .before_text };
        }
        c = f.nodes.items[c].next;
    }
    return null;
}

// ---------------------------------------------------------------------------------------------
// counter styles (takumi `ListStyleType`)
// ---------------------------------------------------------------------------------------------

const Kind = enum { none, disc, circle, square, decimal, decimal_leading_zero, lower_alpha, upper_alpha, lower_roman, upper_roman, disclosure_closed, disclosure_open, string, other };

fn kindOf(t: style.computed.ListStyleType) Kind {
    return switch (t) {
        .none => .none,
        .string => .string,
        .ident => |s| blk: {
            const table = [_]struct { []const u8, Kind }{
                .{ "none", .none },                 .{ "disc", .disc },                         .{ "circle", .circle },
                .{ "square", .square },             .{ "decimal", .decimal },                   .{ "decimal-leading-zero", .decimal_leading_zero },
                .{ "lower-alpha", .lower_alpha },   .{ "lower-latin", .lower_alpha },           .{ "upper-alpha", .upper_alpha },
                .{ "upper-latin", .upper_alpha },   .{ "lower-roman", .lower_roman },           .{ "upper-roman", .upper_roman },
                .{ "disclosure-closed", .disclosure_closed }, .{ "disclosure-open", .disclosure_open },
            };
            for (table) |e| if (std.ascii.eqlIgnoreCase(s, e[0])) break :blk e[1];
            break :blk .other;
        },
    };
}

fn isSymbolic(k: Kind) bool {
    return switch (k) {
        .disc, .circle, .square, .disclosure_closed, .disclosure_open => true,
        else => false,
    };
}

const roman_digits = [_]struct { i32, []const u8, []const u8 }{
    .{ 1000, "m", "M" }, .{ 900, "cm", "CM" }, .{ 500, "d", "D" }, .{ 400, "cd", "CD" },
    .{ 100, "c", "C" },  .{ 90, "xc", "XC" },  .{ 50, "l", "L" },  .{ 40, "xl", "XL" },
    .{ 10, "x", "X" },   .{ 9, "ix", "IX" },   .{ 5, "v", "V" },   .{ 4, "iv", "IV" },
    .{ 1, "i", "I" },
};

/// takumi `ListStyleType::representation` (no suffix); null for `none` / a string.
fn representation(a: Allocator, t: style.computed.ListStyleType, k: Kind, value: i32, rtl: bool) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    switch (k) {
        .none, .string => return null,
        .disc => return "\u{2022}",
        .circle => return "\u{25e6}",
        .square => return "\u{25aa}",
        .disclosure_closed => return if (rtl) "\u{25c2}" else "\u{25b8}",
        .disclosure_open => return "\u{25be}",
        .decimal => try out.print(a, "{d}", .{value}),
        .decimal_leading_zero => if (value < 0) try out.print(a, "{d}", .{value}) else try out.print(a, "{d:0>2}", .{@as(u32, @intCast(value))}),
        .lower_alpha, .upper_alpha => {
            if (value <= 0) {
                try out.print(a, "{d}", .{value});
            } else {
                const first: u8 = if (k == .lower_alpha) 'a' else 'A';
                var rem: u32 = @intCast(value);
                var buf: [16]u8 = undefined;
                var n: usize = 0;
                while (rem > 0) {
                    rem -= 1;
                    buf[n] = first + @as(u8, @intCast(rem % 26));
                    n += 1;
                    rem /= 26;
                }
                while (n > 0) {
                    n -= 1;
                    try out.append(a, buf[n]);
                }
            }
        },
        .lower_roman, .upper_roman => {
            if (value < 1 or value > 3999) {
                try out.print(a, "{d}", .{value});
            } else {
                var rem = value;
                for (roman_digits) |d| while (rem >= d[0]) {
                    try out.appendSlice(a, if (k == .upper_roman) d[2] else d[1]);
                    rem -= d[0];
                };
            }
        },
        .other => {
            // (a counter style takumi does not parse: as counters.zig formats it, else decimal)
            const name = t.ident;
            if (value >= 1) if (counters.CounterStyle.fromName(name)) |cst| return try cst.format(a, @intCast(value));
            try out.print(a, "{d}", .{value});
        },
    }
    return out.items;
}

/// takumi `ListStyleType::marker_text`: the representation and its suffix (`. `, a space after a
/// symbol), or the string as written; null = no marker.
pub fn markerText(a: Allocator, t: style.computed.ListStyleType, value: i32, rtl: bool) Allocator.Error!?[]const u8 {
    const k = kindOf(t);
    if (k == .string) return t.string;
    const rep = (try representation(a, t, k, value, rtl)) orelse return null;
    const suffix = if (isSymbolic(k)) " " else ". ";
    return try std.mem.concat(a, u8, &.{ rep, suffix });
}

// ---------------------------------------------------------------------------------------------
// ordinals (takumi `ListItemOrdinals`)
// ---------------------------------------------------------------------------------------------

const Ordinals = struct {
    initial: ?i32 = null,
    reversed: bool = false,
    counts_items: bool = false,
    previous: ?i32 = null,
    items: i32 = 0,
};

fn saturate(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn attrNumber(f: *const Frame, el: u32, name: []const u8) ?i32 {
    const v = f.dom.attr(el, name) orelse return null;
    return std.fmt.parseInt(i32, std.mem.trim(u8, v, " \t\n\r\x0c"), 10) catch null;
}

fn isTag(f: *const Frame, el: u32, tag: []const u8) bool {
    const e = f.dom.at(el);
    return !e.run and std.ascii.eqlIgnoreCase(e.tag, tag);
}

/// Blink's `IsListOwner`.
fn isListOwner(f: *const Frame, el: u32) bool {
    return isTag(f, el, "ol") or isTag(f, el, "ul") or isTag(f, el, "menu") or f.dom.at(el).cs.contain.style;
}

/// The value `list` (a `counter-set` / `counter-increment` list: names, each with an optional
/// integer) gives the counter `list-item`, `dflt` when it names it without one; null when it does
/// not name it.
fn listItemDirective(list: []const u8, dflt: i32) ?i32 {
    var it = std.mem.tokenizeAny(u8, list, " \t\n\r\x0c");
    var found: ?i32 = null;
    var pending = false;
    while (it.next()) |tok| {
        const num = std.fmt.parseInt(i32, tok, 10) catch null;
        if (num) |v| {
            if (pending) {
                found = v;
                pending = false;
                return found;
            }
            continue;
        }
        if (pending) return found;
        if (std.mem.eql(u8, tok, "list-item")) {
            found = dflt;
            pending = true;
        }
    }
    return found;
}

fn newOrdinals(f: *const Frame, el: u32, counts: *const std.AutoHashMapUnmanaged(u32, i32)) Ordinals {
    if (!isTag(f, el, "ol")) return .{};
    const reversed = f.dom.attr(el, "reversed") != null;
    const start = attrNumber(f, el, "start");
    const initial: i32 = start orelse if (reversed) (counts.get(el) orelse 0) else 1;
    return .{ .initial = initial, .reversed = reversed, .counts_items = reversed and start == null };
}

/// Blink's `ListItemOrdinal::CalcValue`.
fn nextValue(o: *Ordinals, f: *const Frame, el: u32, cs: *const CS) i32 {
    const set = listItemDirective(cs.counter_set, 0);
    const inc = listItemDirective(cs.counter_increment, 1);
    const explicit = if (isTag(f, el, "li")) attrNumber(f, el, "value") else null;
    const value: i32 = if (set) |v| v else if (explicit) |v| v else blk: {
        const step: i64 = if (inc) |v| v else if (o.reversed) -1 else 1;
        const base: i64 = if (o.previous) |p| p else if (o.initial) |i| @as(i64, i) + @as(i64, if (o.reversed) 1 else -1) else 0;
        break :blk saturate(base + step);
    };
    o.previous = value;
    o.items +|= 1;
    return value;
}

const Walk = struct {
    f: *Frame,
    counts: std.AutoHashMapUnmanaged(u32, i32) = .empty,
    /// second pass: generate (first pass: count only)
    emit: bool,
    any_reversed: bool = false,
};

fn walk(w: *Walk, el: u32, enclosing: *Ordinals, inside_list: bool, depth: u32) Error!void {
    if (depth > render.max_node_depth) return;
    const f = w.f;
    const e = f.dom.at(el);
    if (e.run) return;
    const cs = e.cs;
    if (cs.display == .none) return;
    if (isTag(f, el, "ol") and f.dom.attr(el, "reversed") != null) w.any_reversed = true;
    const ordinal: ?i32 = if (cs.display == .list_item) nextValue(enclosing, f, el, cs) else null;
    const owner = isListOwner(f, el);
    const owns = !inside_list or owner;
    var ords: Ordinals = if (owns) newOrdinals(f, el, &w.counts) else enclosing.*;
    var c = e.first;
    while (c != none) : (c = f.dom.at(c).next) try walk(w, c, &ords, inside_list or owner, depth + 1);
    if (owns) {
        if (ords.counts_items and !w.emit) try w.counts.put(f.a, el, ords.items);
    } else enclosing.* = ords;
    if (w.emit) if (ordinal) |v| try attach(f, el, v);
}

/// Generates the markers of the frame's list items (after the cascade, before the render nodes).
pub fn generate(f: *Frame) Error!void {
    const root = f.dom.root;
    if (root == none) return;
    var w: Walk = .{ .f = f, .emit = false };
    var top: Ordinals = .{};
    // (a first pass counts the items of every `ol reversed` without `start`, Blink's
    // `InitialCounterForReversedOrderedList`)
    try walk(&w, root, &top, false, 0);
    w.emit = true;
    top = .{};
    try walk(&w, root, &top, false, 0);
}

// ---------------------------------------------------------------------------------------------
// the marker box (takumi `list_marker`)
// ---------------------------------------------------------------------------------------------

fn isBlank(f: *const Frame, el: u32) bool {
    const e = f.dom.at(el);
    if (!e.run or e.cs.white_space_collapse != .collapse) return false;
    for (e.text) |ch| if (!(ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r' or ch == 0x0c)) return false;
    return true;
}

/// Whether element `el` takes part in its parent's lines (Blink: inline-level, or out of flow /
/// floating among inline content).
fn inlineLevel(cs: *const CS) bool {
    if (cs.position == .absolute or cs.position == .fixed or cs.float != .none) return true;
    return switch (cs.display) {
        .@"inline", .inline_block, .inline_flex, .inline_grid, .inline_table, .webkit_inline_box => true,
        else => false,
    };
}

/// A block container whose first line an outside marker may join (a block flow box: not flex,
/// grid, table, replaced or establishing an independent formatting context the marker skips).
fn flowBlock(f: *const Frame, el: u32) bool {
    const e = f.dom.at(el);
    if (e.kind == .image) return false;
    return switch (e.cs.display) {
        .block, .list_item, .flow_root => true,
        else => false,
    };
}

/// The start-side border + padding of `cs` (percentages as 0), on the 1/64 px grid.
fn startEdges(cs: *const CS, rtl: bool) f32 {
    const side: usize = if (rtl) 1 else 3;
    return lu(cs.usedBorderWidths()[side]) + lu(@max(cs.padding[side].resolve(0), 0));
}

fn startMargin(cs: *const CS, rtl: bool) f32 {
    return switch (cs.margin[if (rtl) 1 else 3]) {
        .lp => |v| lu(v.resolve(0)),
        .auto => 0,
    };
}

const Host = struct { el: u32, inset: f32 };

/// The element an outside marker of item `item` joins the first line of, and how far that line's
/// content edge sits in from the item's border edge; null = none (the item starts with a box that
/// has no line of its own). takumi hangs the marker off the item's border box beside its first
/// line box, or beside the first baseline of its first block child (Blink's
/// `PositionListMarkerBesideChild`): the first line of the chain of blocks followed here.
fn outsideHost(f: *const Frame, item: u32, rtl: bool) ?Host {
    var cur = item;
    var inset = startEdges(f.dom.at(item).cs, rtl);
    var guard: u32 = 0;
    while (guard < 512) : (guard += 1) {
        const e = f.dom.at(cur);
        // its own text, or generated content (inline), is its first line's content
        if (e.kind == .text or e.before != none) return .{ .el = cur, .inset = inset };
        var c = e.first;
        while (c != none and (isBlank(f, c) or f.dom.at(c).cs.display == .none)) c = f.dom.at(c).next;
        if (c == none) return .{ .el = cur, .inset = inset }; // (empty: the marker makes the line)
        const ce = f.dom.at(c);
        if (ce.run or inlineLevel(ce.cs)) return .{ .el = cur, .inset = inset };
        if (!flowBlock(f, c)) return null;
        inset += startMargin(ce.cs, rtl) + startEdges(ce.cs, rtl);
        cur = c;
    }
    return null;
}

/// The ascent of the primary font of `cs` in whole px (Blink `FontMetrics::Ascent`).
fn primaryAscent(f: *const Frame, cs: *const CS) i32 {
    const m = render.emMetrics(&f.r.fonts, cs);
    return @intFromFloat(@round(m.ascent * cs.font_size));
}

/// Whether the fonts `cs` selects (its families, then every registered family) draw all of `text`.
fn covered(f: *const Frame, cs: *const CS, text: []const u8) bool {
    var buf: [32]@import("../font/font.zig").FaceId = undefined;
    const faces = f.r.fonts.match(cs.font_family, cs.font_weight, cs.font_style != .normal, &buf);
    var i: usize = 0;
    while (i < text.len) {
        const d = @import("../font/unicode.zig").decodeUtf8(text, i);
        i += d.len;
        if (d.cp < 0x80) continue;
        const ok = for (faces) |id| {
            if (f.r.fonts.font(id).glyphIndex(d.cp) != 0) break true;
        } else false;
        if (!ok) return false;
    }
    return true;
}

/// LayoutUnit truncation (1/64 px).
fn lu(v: f32) f32 {
    return @trunc(v * 64) / 64;
}

fn attach(f: *Frame, item: u32, ordinal: i32) Error!void {
    const a = f.a;
    const e = f.dom.at(item);
    if (e.kind == .image) return;
    const ics = e.cs;
    const rtl = ics.direction == .rtl;
    const k = kindOf(ics.list_style_type);
    const image: ?struct { url: []const u8, width: f32 } = blk: {
        if (ics.list_style_image != .url) break :blk null;
        const url = ics.list_style_image.url;
        if (f.r.resolveImage(url)) |pm| break :blk .{ .url = url, .width = @as(f32, @floatFromInt(pm.width)) * f.opts.dpr };
        if (f.r.resolveSvg(url)) |source| {
            const doc = @import("../svg/svg.zig").parse(a, source) catch break :blk null;
            const sz = render.svgIntrinsic(&doc, f.opts.dpr);
            // (no natural width: takumi's outside marker box shrinks to nothing around it; the
            // line's text keeps its place)
            break :blk .{ .url = url, .width = @max(sz.w, 0) };
        }
        break :blk null;
    };
    var text = (try markerText(a, ics.list_style_type, ordinal, rtl)) orelse if (image != null) "" else return;
    // A counter style beyond takumi's twelve is drawn when the item's fonts have its glyphs;
    // without them the marker is the decimal one takumi-pdf shows for such a list (it drops the
    // declaration), not a render failed for characters the document never wrote.
    if (k == .other and !covered(f, ics, text)) text = try std.fmt.allocPrint(a, "{d}. ", .{ordinal});
    const outside = ics.list_style_position == .outside;
    // (no line to join: the marker is the item's own out-of-flow box, placed beside the item's
    // first baseline by the layout, `layout.Style.list_marker`)
    const hosted = if (outside) outsideHost(f, item, rtl) else null;
    const beside = outside and hosted == null;
    const hp: Host = if (!outside) .{ .el = item, .inset = 0 } else hosted orelse .{ .el = item, .inset = startEdges(ics, rtl) };
    const host = hp.el;

    var diag: style.Diagnostics = .{};
    const cs = try a.create(CS);
    cs.* = style.compute(a, &f.ctx, ics, null, null, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    var info: Info = .{ .item = item, .host = host, .outside = outside, .inset = hp.inset, .beside = beside };
    const symbolic = image == null and isSymbolic(k);
    var box_text = text;
    if (image) |im| info.image_width = im.width;
    if (symbolic) {
        const asc = primaryAscent(f, ics);
        const disclosure = k == .disclosure_closed or k == .disclosure_open;
        const dsize = lu(ics.font_size * disclosure_size_em);
        info.shape = switch (k) {
            .disc => .disc,
            .circle => .circle,
            .square => .square,
            .disclosure_open => .disclosure_down,
            else => if (rtl) .disclosure_left else .disclosure_right,
        };
        // Blink `WidthOfSymbol` / `RelativeSymbolMarkerRect` (integer px arithmetic)
        const two_thirds = @divTrunc(asc * 2, 3);
        if (disclosure) {
            info.symbol_w = dsize;
            info.off_x = 0;
            info.off_y = -dsize;
            info.side = dsize;
        } else {
            info.symbol_w = @floatFromInt(@divTrunc(two_thirds + 1, 2) + 2);
            const top = @divTrunc(3 * (asc - two_thirds), 2);
            info.off_x = 1;
            info.off_y = @floatFromInt(top - asc);
            info.side = @floatFromInt(@divTrunc(two_thirds + 1, 2));
        }
        const offset: f32 = if (disclosure) dsize else @floatFromInt(two_thirds);
        info.symbol_start = -(offset + marker_gap_px + 1);
        // (a preserved space carries the line; the shape paints in its place)
        box_text = " ";
    }
    if (outside) {
        // Blink `AdjustStyleForMarker`: a block container that does not break and keeps its spaces
        cs.display = .inline_block;
        cs.white_space_collapse = .preserve;
        cs.text_wrap_mode = .nowrap;
        if (symbolic) cs.width = .{ .lp = .{ .px = info.symbol_w } };
        // (block-level, so no anonymous line wraps it among the item's block children; the layout
        // takes it out of flow: render.zig `layoutNode`. It paints and tags in tree order, before
        // the item's content, as takumi paints a marker)
        if (beside) cs.display = .block;
    } else if (image != null) {
        cs.display = .@"inline";
        cs.margin[if (rtl) 3 else 1] = .{ .lp = .{ .px = marker_gap_px } };
    } else if (symbolic) {
        // (an inside symbol: a box of the symbol's width with Blink's `InlineMarginsForInside`)
        cs.display = .inline_block;
        cs.white_space_collapse = .preserve;
        cs.text_wrap_mode = .nowrap;
        cs.width = .{ .lp = .{ .px = info.symbol_w } };
        const disclosure = k == .disclosure_closed or k == .disclosure_open;
        const start: f32 = if (disclosure) 0 else -1;
        const end = lu(ics.font_size * (if (disclosure) inside_disclosure_gap_em else inside_symbol_gap_em));
        cs.margin[if (rtl) 1 else 3] = .{ .lp = .{ .px = start } };
        cs.margin[if (rtl) 3 else 1] = .{ .lp = .{ .px = end } };
    } else {
        cs.display = .@"inline";
        // (an inside marker carries the item's text decorations: it is part of its line)
        cs.text_decoration_line = ics.text_decoration_line;
    }

    const ps: u32 = @intCast(f.pseudos.items.len);
    const parts: ?[]const @import("../generated_content.zig").Part = if (image) |im| blk: {
        const seq = try a.alloc(@import("../generated_content.zig").Part, 1);
        seq[0] = .{ .url = im.url };
        break :blk seq;
    } else null;
    try f.pseudos.append(a, .{ .cs = cs, .text = box_text, .parts = parts });
    const st = blk: {
        if (stateOf(f)) |s| break :blk s;
        const s = try a.create(State);
        s.* = .{};
        f.tree.paged.markers = s;
        break :blk s;
    };
    const he = f.dom.at(host);
    info.before = he.before;
    try st.by_pseudo.put(a, ps, @intCast(st.infos.items.len));
    try st.items.put(a, item, {});
    try st.infos.append(a, info);
    he.before = ps;
    if (he.kind == .text and he.own == none) {
        // the host's own text moves into an anonymous box after the marker
        const own = try a.create(CS);
        own.* = style.compute(a, &f.ctx, he.cs, null, null, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        try f.pseudos.append(a, .{ .cs = own, .text = he.text });
        he.own = @intCast(f.pseudos.items.len - 1);
    }
}

/// After the render node `id` of pseudo `p` is built (render.zig `buildPseudo`): a marker records
/// its node and takes the margins that hang it outside its line (they depend on its measured
/// width and the border + padding of the block whose line holds it).
pub fn onBuilt(f: *Frame, p: u32, id: u32) Error!void {
    const s = stateOf(f) orelse return;
    const k = s.by_pseudo.get(p) orelse return;
    const info = &s.infos.items[k];
    info.node = id;
    try s.by_node.put(f.a, id, k);
    if (!info.outside) return;
    const n = &f.nodes.items[id];
    const rtl = n.cs.direction == .rtl;
    const side: usize = if (rtl) 1 else 3;
    var width: f32 = undefined;
    var start: f32 = undefined;
    if (info.image_width) |w| {
        width = w;
        start = -width - marker_gap_px;
    } else if (info.shape != null) {
        width = info.symbol_w;
        start = info.symbol_start;
    } else {
        const para = n.para orelse return;
        width = para.measure(null).width;
        start = -width;
    }
    const cs = try f.a.create(CS);
    cs.* = n.cs.*;
    const m_start = lu(start - info.inset);
    cs.margin[side] = .{ .lp = .{ .px = m_start } };
    cs.margin[if (rtl) 3 else 1] = .{ .lp = .{ .px = -m_start - width } };
    n.cs = cs;
}

// ---------------------------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------------------------

test "marker text: takumi's counter styles and suffixes" {
    const T = std.testing;
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, i32, bool, []const u8 };
    const cases = [_]Case{
        .{ "decimal", 3, false, "3. " },
        .{ "decimal-leading-zero", 7, false, "07. " },
        .{ "decimal-leading-zero", -7, false, "-7. " },
        .{ "lower-alpha", 28, false, "ab. " },
        .{ "lower-latin", 0, false, "0. " },
        .{ "upper-roman", 1994, false, "MCMXCIV. " },
        .{ "lower-roman", -2, false, "-2. " },
        .{ "disclosure-closed", 1, false, "\u{25b8} " },
        .{ "disclosure-closed", 1, true, "\u{25c2} " },
        .{ "disclosure-open", 9, true, "\u{25be} " },
        .{ "disc", 1, false, "\u{2022} " },
    };
    for (cases) |c| {
        const got = (try markerText(a, .{ .ident = c[0] }, c[1], c[2])).?;
        try T.expectEqualStrings(c[3], got);
    }
    try T.expect((try markerText(a, .none, 1, false)) == null);
    try T.expectEqualStrings("-", (try markerText(a, .{ .string = "-" }, 4, false)).?);
}

test "list-item counter directives" {
    const T = std.testing;
    try T.expectEqual(@as(?i32, 7), listItemDirective("list-item 7", 0));
    try T.expectEqual(@as(?i32, 1), listItemDirective("list-item", 1));
    try T.expectEqual(@as(?i32, 5), listItemDirective("a 2 list-item 5 b", 1));
    try T.expectEqual(@as(?i32, null), listItemDirective("a 2", 1));
    try T.expectEqual(@as(?i32, null), listItemDirective("", 1));
}

/// Absolute border-box origin of layout node `lid`.
fn testAbs(f: *const Frame, lid: u32) [2]f32 {
    var p: [2]f32 = .{ 0, 0 };
    var cur = lid;
    while (cur < f.tree.nodes.items.len) {
        p[0] += f.tree.layout(cur).x;
        p[1] += f.tree.layout(cur).y;
        if (cur == f.lroot) break;
        cur = f.tree.nodes.items[cur].parent;
    }
    return p;
}

test "list markers: ordinals, texts, and boxes hung outside the line" {
    if (comptime !@import("../config.zig").enable_pdf) return;
    const T = std.testing;
    const gpa = T.allocator;
    const r = render.Renderer.create(gpa) orelse return error.OutOfMemory;
    defer r.destroy();
    _ = try r.registerFont(try gpa.dupe(u8, @embedFile("../font/testdata/Inter-Regular.ttf")), "", 0, -1, null);
    r.beginCall();
    const a = r.arena.allocator();
    var f: Frame = .{ .r = r, .a = a, .opts = .{}, .tree = render.LTree.init(a), .ctx = undefined };
    f.tree.paged.pdf = true;
    f.setPaged(400, 600);
    const src =
        \\<div style="font-size:16px;line-height:20px">
        \\<ol start="3"><li>a</li><li value="9">b</li><li>c</li></ol>
        \\<ol reversed><li>x</li><li>y</li><li><ul><li>nested</li></ul></li></ol>
        \\<ul><li>disc</li></ul>
        \\<ol style="list-style-type:upper-roman"><li style="counter-set:list-item 4">r</li></ol>
        \\<ul style="list-style:none"><li>none</li></ul>
        \\<ol><li><p style="margin:0;padding-left:5px">block</p></li></ol>
        \\</div>
    ;
    try f.prepare(.html, src);
    const st = stateOf(&f) orelse return error.TestUnexpectedResult;
    // (markers are generated post-order: the nested item before the item holding it)
    const want = [_][]const u8{ "3. ", "9. ", "10. ", "3. ", "2. ", "\u{2022} ", "1. ", "\u{2022} ", "IV. ", "1. " };
    try T.expectEqual(want.len, st.infos.items.len);
    // the pseudo text of every marker (a symbol holds a space)
    const got = try a.alloc([]const u8, st.infos.items.len);
    var it = st.by_pseudo.iterator();
    while (it.next()) |kv| got[kv.value_ptr.*] = f.pseudos.items[kv.key_ptr.*].text;
    for (want, got) |w_, g| try T.expectEqualStrings(if (std.mem.eql(u8, w_, "• ")) " " else w_, g);
    // every marker was built, hangs left of its line (its margin box takes no room) and sits on
    // the line's baseline
    for (st.infos.items) |info| {
        try T.expect(info.node != none);
        const mn = &f.nodes.items[info.node];
        const ml = f.tree.layout(mn.lid);
        const mpos = testAbs(&f, mn.lid);
        const line_box = mn.parent; // the line container
        const lpos = testAbs(&f, f.nodes.items[line_box].lid);
        try T.expect(mpos[0] + ml.w <= lpos[0] + 0.01);
        try T.expectApproxEqAbs(@as(f32, 0), ml.margin.left + ml.w + ml.margin.right, 0.02);
        if (info.shape != null) try T.expectApproxEqAbs(info.symbol_w, ml.w, 0.01);
    }
    // the item whose first content is a block hangs its marker off the item's border edge
    const last = st.infos.items[st.infos.items.len - 1];
    try T.expect(last.host != last.item);
    try T.expectApproxEqAbs(@as(f32, 5), last.inset, 0.01);
}

test "list markers: an item starting with a flex, grid or table box hangs its marker beside the first baseline" {
    if (comptime !@import("../config.zig").enable_pdf) return;
    const T = std.testing;
    const gpa = T.allocator;
    const r = render.Renderer.create(gpa) orelse return error.OutOfMemory;
    defer r.destroy();
    _ = try r.registerFont(try gpa.dupe(u8, @embedFile("../font/testdata/Inter-Regular.ttf")), "", 0, -1, null);
    r.beginCall();
    const a = r.arena.allocator();
    var f: Frame = .{ .r = r, .a = a, .opts = .{}, .tree = render.LTree.init(a), .ctx = undefined };
    f.tree.paged.pdf = true;
    f.setPaged(400, 600);
    const src =
        \\<ol style="font-size:16px;line-height:20px;padding-left:40px">
        \\<li><div style="display:flex;padding-top:7px"><span>flex</span></div></li>
        \\<li><div style="display:grid;font-size:24px;line-height:30px"><span>grid</span></div></li>
        \\<li><table><tr><td style="padding:5px">cell</td></tr></table></li>
        \\</ol>
    ;
    try f.prepare(.html, src);
    const st = stateOf(&f) orelse return error.TestUnexpectedResult;
    try T.expectEqual(@as(usize, 3), st.infos.items.len);
    // each marker's baseline is the baseline of the text its item starts with, and it hangs left
    // of the item's content box
    const texts = [_][]const u8{ "flex", "grid", "cell" };
    for (st.infos.items, texts) |info, text| {
        try T.expect(info.beside and info.node != none);
        const mn = &f.nodes.items[info.node];
        const ml = f.tree.layout(mn.lid);
        try T.expect(std.math.isFinite(ml.baseline));
        const marker_bl = testAbs(&f, mn.lid)[1] + ml.baseline;
        var found = false;
        for (f.nodes.items) |*n| {
            const p = n.para orelse continue;
            if (!std.mem.eql(u8, render.Frame.paragraphText(p), text)) continue;
            if (n.lid == none) continue;
            const l = f.tree.layout(n.lid);
            try T.expect(std.math.isFinite(l.baseline));
            const text_bl = testAbs(&f, n.lid)[1] + l.baseline;
            // (a table's first baseline is its first row's, as the layout reports it: takumi's and
            // Chrome's markers sit a few px below the cell text too)
            if (std.mem.eql(u8, text, "cell")) {
                try T.expect(marker_bl >= text_bl and marker_bl < text_bl + 8);
            } else try T.expectApproxEqAbs(text_bl, marker_bl, 0.02);
            const item_left = testAbs(&f, f.nodes.items[mn.parent].lid)[0];
            try T.expect(testAbs(&f, mn.lid)[0] + ml.w <= item_left + 0.01);
            found = true;
        }
        try T.expect(found);
    }
}
