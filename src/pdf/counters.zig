//! Page counters (takumi-pdf `counters.rs`, the counter parts of `pagination.rs` / `tree.rs`):
//!
//! * the class hooks Chromium's print templates use: an element classed `pageNumber` / `totalPages`
//!   receives the page number / page count, `targetPageNumber` the page of the element its own or
//!   nearest enclosing `href="#id"` names; another class naming a `@counter-style` picks the
//!   format (`CounterStyle`; `decimal` when none does);
//! * the substitution itself works on a frame's element model (dom.zig) between the DOM build and
//!   the cascade, through the `Frame.prepare` hook (`layout.fragment.PagedState.dom_hook`): a text
//!   element takes the text, a container's children are replaced by one text run (takumi
//!   `write_counter`); an empty target counter empties its container;
//! * `flowTexts` fills the content's hooks from one laid-out, paginated pass (takumi
//!   `FlowCounters` + `substitute_target_counters`): a hook takes the page its own box starts on,
//!   or, without a box of its own (inline content), its nearest boxed ancestor's page or the page
//!   the flow before it reached, whichever is later; hooks inside a repeating `position: fixed` box
//!   are left to the per-page layout of that box.
//!
//! Also the page a box landed on, for internal links (`boxTop`, `elementPage`, `anchorPage`).
//!
//! CSS `counter(page)` / `counter(pages)` / `target-counter()` in generated content are not page
//! counters in takumi (`content: counter(page)` reads a CSS counter named `page`;
//! `target-counter()` does not parse), so they are not here either.
const std = @import("std");
const rt = @import("../render.zig");
const dom_mod = @import("../dom.zig");
const layout = @import("../layout/layout.zig");
const mx = @import("../measure_xform.zig");

const Allocator = std.mem.Allocator;
const Frame = rt.Frame;
const Dom = dom_mod.Dom;
const none = dom_mod.none;

// ---- counter styles

/// Styles that write a decimal number in another script's digits, zero first (10 code points).
const digit_styles = [_]struct { []const u8, []const u8 }{
    .{ "cjk-decimal", chinese_digits },
    .{ "arabic-indic", "٠١٢٣٤٥٦٧٨٩" },
    .{ "bengali", "০১২৩৪৫৬৭৮৯" },
    .{ "cambodian", "០១២៣៤៥៦៧៨៩" },
    .{ "khmer", "០១២៣៤៥៦៧៨៩" },
    .{ "devanagari", "०१२३४५६७८९" },
    .{ "gujarati", "૦૧૨૩૪૫૬૭૮૯" },
    .{ "gurmukhi", "੦੧੨੩੪੫੬੭੮੯" },
    .{ "kannada", "೦೧೨೩೪೫೬೭೮೯" },
    .{ "lao", "໐໑໒໓໔໕໖໗໘໙" },
    .{ "malayalam", "൦൧൨൩൪൫൬൭൮൯" },
    .{ "mongolian", "᠐᠑᠒᠓᠔᠕᠖᠗᠘᠙" },
    .{ "myanmar", "၀၁၂၃၄၅၆၇၈၉" },
    .{ "oriya", "୦୧୨୩୪୫୬୭୮୯" },
    .{ "persian", "۰۱۲۳۴۵۶۷۸۹" },
    .{ "urdu", "۰۱۲۳۴۵۶۷۸۹" },
    .{ "tamil", "௦௧௨௩௪௫௬௭௮௯" },
    .{ "telugu", "౦౧౨౩౪౫౬౭౮౯" },
    .{ "thai", "๐๑๒๓๔๕๖๗๘๙" },
    .{ "tibetan", "༠༡༢༣༤༥༦༧༨༩" },
};

/// Styles that count through an alphabet: a, b, ..., z, aa, ab, and so on.
const alphabet_styles = [_]struct { []const u8, []const u8 }{
    .{ "lower-alpha", "abcdefghijklmnopqrstuvwxyz" },
    .{ "lower-latin", "abcdefghijklmnopqrstuvwxyz" },
    .{ "upper-alpha", "ABCDEFGHIJKLMNOPQRSTUVWXYZ" },
    .{ "upper-latin", "ABCDEFGHIJKLMNOPQRSTUVWXYZ" },
    .{ "lower-greek", "αβγδεζηθικλμνξοπρστυφχψω" },
    .{ "hiragana", "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわゐゑをん" },
    .{ "katakana", "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヰヱヲン" },
};

const chinese_digits = "零一二三四五六七八九";

/// A `@counter-style` the page counters format in (takumi `CounterStyle`).
pub const CounterStyle = union(enum) {
    decimal,
    decimal_leading_zero,
    lower_roman,
    upper_roman,
    /// reading-style Chinese numerals (`trad-chinese-informal`, `cjk-ideographic`)
    chinese_informal,
    /// a decimal number in another script's digits (10 code points, zero first)
    digits: []const u8,
    /// counting through an alphabet (its code points)
    alphabet: []const u8,

    pub fn fromName(name: []const u8) ?CounterStyle {
        for (digit_styles) |d| if (std.mem.eql(u8, d[0], name)) return .{ .digits = d[1] };
        for (alphabet_styles) |s| if (std.mem.eql(u8, s[0], name)) return .{ .alphabet = s[1] };
        if (std.mem.eql(u8, name, "decimal")) return .decimal;
        if (std.mem.eql(u8, name, "decimal-leading-zero")) return .decimal_leading_zero;
        if (std.mem.eql(u8, name, "lower-roman")) return .lower_roman;
        if (std.mem.eql(u8, name, "upper-roman")) return .upper_roman;
        if (std.mem.eql(u8, name, "trad-chinese-informal") or std.mem.eql(u8, name, "cjk-ideographic")) return .chinese_informal;
        return null;
    }

    /// The style a hook's class list names, `decimal` when none does (the first known name wins).
    pub fn fromClasses(classes: []const u8) CounterStyle {
        var it = std.mem.tokenizeAny(u8, classes, " \t\n\r\x0c");
        while (it.next()) |c| if (fromName(c)) |s| return s;
        return .decimal;
    }

    /// Every character a value of this style can be written with (for resource discovery: the
    /// characters a page hook may draw before its value is known).
    pub fn symbols(self: CounterStyle) []const u8 {
        return switch (self) {
            .decimal, .decimal_leading_zero => "0123456789",
            .digits => |d| d,
            .alphabet => |alpha| alpha,
            .chinese_informal => chinese_digits ++ "十百千",
            .lower_roman => "ivxlcdm",
            .upper_roman => "IVXLCDM",
        };
    }

    pub fn format(self: CounterStyle, a: Allocator, value: usize) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        switch (self) {
            .decimal => try appendInt(a, &out, value, 1),
            .decimal_leading_zero => try appendInt(a, &out, value, 2),
            .digits => |d| {
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
                for (s) |c| try out.appendSlice(a, codepoint(d, c - '0'));
            },
            .alphabet => |alpha| {
                const n = codepointCount(alpha);
                if (value == 0 or n == 0) {
                    try appendInt(a, &out, value, 1);
                } else {
                    var letters: [64]usize = undefined;
                    var k: usize = 0;
                    var rem = value;
                    while (rem > 0) {
                        rem -= 1;
                        letters[k] = rem % n;
                        k += 1;
                        rem /= n;
                    }
                    while (k > 0) {
                        k -= 1;
                        try out.appendSlice(a, codepoint(alpha, letters[k]));
                    }
                }
            },
            .chinese_informal => try chineseInformal(a, &out, value),
            .lower_roman, .upper_roman => {
                const numerals = [_]struct { usize, []const u8 }{
                    .{ 1000, "M" }, .{ 900, "CM" }, .{ 500, "D" }, .{ 400, "CD" }, .{ 100, "C" }, .{ 90, "XC" }, .{ 50, "L" },
                    .{ 40, "XL" },  .{ 10, "X" },   .{ 9, "IX" },  .{ 5, "V" },    .{ 4, "IV" },  .{ 1, "I" },
                };
                var rem = value;
                for (numerals) |nm| while (rem >= nm[0]) {
                    try out.appendSlice(a, nm[1]);
                    rem -= nm[0];
                };
                if (self == .lower_roman) for (out.items) |*c| {
                    c.* = std.ascii.toLower(c.*);
                };
            },
        }
        return out.items;
    }
};

fn appendInt(a: Allocator, out: *std.ArrayList(u8), value: usize, min_digits: usize) Allocator.Error!void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    var pad = min_digits -| s.len;
    while (pad > 0) : (pad -= 1) try out.append(a, '0');
    try out.appendSlice(a, s);
}

/// The `i`-th code point of UTF-8 `s` (as bytes).
fn codepoint(s: []const u8, i: usize) []const u8 {
    var k: usize = 0;
    var at: usize = 0;
    while (at < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[at]) catch 1;
        if (k == i) return s[at..@min(s.len, at + len)];
        at += len;
        k += 1;
    }
    return "";
}

fn codepointCount(s: []const u8) usize {
    var k: usize = 0;
    var at: usize = 0;
    while (at < s.len) : (k += 1) at += std.unicode.utf8ByteSequenceLength(s[at]) catch 1;
    return k;
}

/// Reading-style Chinese numerals (一, 十二, 一百零三) up to 9999; larger values in positional digits.
fn chineseInformal(a: Allocator, out: *std.ArrayList(u8), value: usize) Allocator.Error!void {
    if (value >= 10_000) {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        for (s) |c| try out.appendSlice(a, codepoint(chinese_digits, c - '0'));
        return;
    }
    if (value == 0) return out.appendSlice(a, codepoint(chinese_digits, 0));
    var needs_zero = false;
    const units = [_]struct { usize, []const u8 }{ .{ 1000, "千" }, .{ 100, "百" }, .{ 10, "十" }, .{ 1, "" } };
    for (units) |u| {
        const digit = value / u[0] % 10;
        if (digit == 0) {
            needs_zero = out.items.len > 0;
            continue;
        }
        if (needs_zero) {
            try out.appendSlice(a, codepoint(chinese_digits, 0));
            needs_zero = false;
        }
        // 10-19 reads 十 not 一十
        if (!(u[0] == 10 and digit == 1 and value < 20)) try out.appendSlice(a, codepoint(chinese_digits, digit));
        try out.appendSlice(a, u[1]);
    }
}

// ---- class hooks

pub const Kind = enum { page, pages, target };

fn hasClass(classes: []const u8, class: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, classes, " \t\n\r\x0c");
    while (it.next()) |c| if (std.mem.eql(u8, c, class)) return true;
    return false;
}

/// The hook a class list requests: a target counter (written last in takumi, so it wins), else the
/// page number (which wins over the page count), else the page count.
pub fn hookOf(classes: []const u8) ?Kind {
    if (classes.len == 0) return null;
    if (hasClass(classes, "targetPageNumber")) return .target;
    if (hasClass(classes, "pageNumber")) return .page;
    if (hasClass(classes, "totalPages")) return .pages;
    return null;
}

/// One hook element of a frame's element model, in document order.
pub const Hook = struct {
    /// element index in the frame's `Dom`
    el: u32,
    kind: Kind,
    style: CounterStyle,
    /// the element's own `href`, else its nearest ancestor's (target counters)
    href: ?[]const u8,
};

/// What a frame's hooks receive (installed on a frame before `prepare`), and the hooks it met.
pub const Subst = struct {
    a: Allocator,
    mode: Mode = .none,
    hooks: std.ArrayList(Hook) = .empty,

    pub const Mode = union(enum) {
        /// leave every hook as it is
        none,
        /// a band or `measure` (takumi `prepare_band`): page hooks read `page` of `pages`, target
        /// hooks name no page and empty
        band: struct { page: usize, pages: usize },
        /// the content: hook k receives `texts[k]` (null: as it is); a hook flagged in `fixed`
        /// (inside a repeating `position: fixed` box) receives `page` of `pages` instead when
        /// `page` > 0 (the per-page layout of that box)
        flow: struct { texts: []const ?[]const u8 = &.{}, fixed: []const bool = &.{}, page: usize = 0, pages: usize = 0 },
    };

    pub fn install(s: *Subst, f: *Frame) void {
        if (comptime !layout.fragment.enabled) return;
        f.tree.paged.dom_hook = domHook;
        f.tree.paged.dom_ctx = @ptrCast(s);
    }

    /// Whether a page number or page count hook was met (the frame lays out again per page).
    pub fn hasPageHooks(s: *const Subst) bool {
        for (s.hooks.items) |h| if (h.kind != .target) return true;
        return false;
    }

    fn walk(s: *Subst, d: *const Dom, i: u32, href_in: ?[]const u8, depth: u32) Allocator.Error!void {
        if (depth > 600) return;
        const el = d.at(i);
        const href = d.attr(i, "href") orelse href_in;
        if (!el.run) if (hookOf(el.class)) |k| {
            try s.hooks.append(s.a, .{ .el = i, .kind = k, .style = CounterStyle.fromClasses(el.class), .href = href });
            return; // takumi writes the hook and does not look inside it
        };
        var c = el.first;
        while (c != none) : (c = d.at(c).next) try s.walk(d, c, href, depth + 1);
    }

    fn textFor(s: *const Subst, k: usize, h: Hook) Allocator.Error!?[]const u8 {
        switch (s.mode) {
            .none => return null,
            .band => |b| return switch (h.kind) {
                .page => try h.style.format(s.a, b.page),
                .pages => try h.style.format(s.a, b.pages),
                .target => "",
            },
            .flow => |fl| {
                if (h.kind != .target and fl.page > 0 and k < fl.fixed.len and fl.fixed[k])
                    return try h.style.format(s.a, if (h.kind == .page) fl.page else fl.pages);
                return if (k < fl.texts.len) fl.texts[k] else null;
            },
        }
    }
};

/// `layout.fragment.PagedState.dom_hook`: collects the hooks of the freshly built element model and
/// writes what `Subst.mode` gives them.
fn domHook(ctx: *anyopaque, fp: *anyopaque) Allocator.Error!void {
    const s: *Subst = @ptrCast(@alignCast(ctx));
    const f: *Frame = @ptrCast(@alignCast(fp));
    s.hooks.clearRetainingCapacity();
    const d = &f.dom;
    if (d.root == none) return;
    try s.walk(d, d.root, null, 0);
    for (s.hooks.items, 0..) |h, k| {
        const text = (try s.textFor(k, h)) orelse continue;
        try writeCounter(d, s.a, h.el, text);
    }
}

/// takumi `write_counter`: a text element takes the text, a container holds it as its only child
/// (none when it is empty: an unresolved target counter empties its container).
fn writeCounter(d: *Dom, a: Allocator, i: u32, text: []const u8) Allocator.Error!void {
    const el = d.at(i);
    switch (el.kind) {
        .text => el.text = text,
        .container => {
            el.first = none;
            el.last = none;
            if (text.len > 0) _ = d.add(a, .{ .kind = .text, .run = true, .text = text }, i) catch return error.OutOfMemory;
        },
        .image => {},
    }
}

// ---- where boxes landed (paginated frames)

/// The block offset of the border-box top of layout node `lid` in the frame's coordinates (after
/// `Frame.paginate`: stitched space, so `Pages.pageAt` of it is the page the box starts on).
pub fn boxTop(f: *const Frame, lid: u32) f32 {
    var y = f.tree.layout(lid).y;
    if (lid == f.lroot) return y;
    var cur = f.tree.nodes.items[lid].parent;
    var guard: u32 = 0;
    while (cur < f.tree.nodes.items.len and guard < layout.max_depth + 8) : (guard += 1) {
        y += f.tree.layout(cur).y;
        if (cur == f.lroot) break;
        cur = f.tree.nodes.items[cur].parent;
    }
    return y;
}

const BoxPosition = struct { top: f32, flow_bottom: ?f32 };

/// Interactive::BoxExtent: the first painted box owns the counter, while the
/// flow it leaves behind excludes only that box's own transform. Ancestor
/// transforms still affect both edges.
fn boxPosition(f: *const Frame, id: u32) ?BoxPosition {
    const n = &f.nodes.items[id];
    var chain: [layout.max_depth + 8]u32 = undefined;
    var len: usize = 0;
    var cur = n.lid;
    while (cur < f.tree.nodes.items.len and len < chain.len) {
        chain[len] = cur;
        len += 1;
        if (cur == f.lroot) break;
        cur = f.tree.nodes.items[cur].parent;
    }
    var matrix = mx.Affine.identity;
    var flow = matrix;
    var own_invertible = true;
    while (len > 0) {
        len -= 1;
        const lid = chain[len];
        const l = f.tree.layout(lid);
        matrix = mx.mul(matrix, mx.Affine.translate(l.x, l.y));
        if (lid == n.lid) flow = matrix;
        if (lid < f.lid_node.items.len) {
            const node = f.lid_node.items[lid];
            if (node < f.nodes.items.len and f.nodes.items[node].kind != .anon_text) {
                const local = mx.local(f.nodes.items[node].cs, l.w, l.h);
                if (lid == n.lid) own_invertible = local.invert() != null;
                matrix = mx.mul(matrix, local);
            }
        }
    }
    const l = f.tree.layout(n.lid);
    var top = std.math.inf(f32);
    var bottom = -std.math.inf(f32);
    for ([4][2]f32{ .{ 0, 0 }, .{ l.w, 0 }, .{ 0, l.h }, .{ l.w, l.h } }) |p| {
        top = @min(top, matrix.b * p[0] + matrix.d * p[1] + matrix.f);
        bottom = @max(bottom, flow.b * p[0] + flow.d * p[1] + flow.f);
    }
    if (!std.math.isFinite(top)) return null;
    const in_flow = n.cs.position != .absolute and n.cs.position != .fixed;
    return .{ .top = top, .flow_bottom = if (own_invertible and std.math.isFinite(bottom) and in_flow) bottom else null };
}

/// Render node ids inside a repeating `position: fixed` subtree (`fixed`: the roots, from
/// `emit.repeatingFixed`), as a mask over `f.nodes`.
pub fn fixedMask(a: Allocator, f: *const Frame, fixed: []const u32) Allocator.Error![]bool {
    const mask = try a.alloc(bool, f.nodes.items.len);
    @memset(mask, false);
    for (f.nodes.items, 0..) |n, id| {
        var p: u32 = @intCast(id);
        var guard: u32 = 0;
        while (p != none and guard < 1024) : (guard += 1) {
            if (std.mem.indexOfScalar(u32, fixed, p) != null) {
                mask[id] = true;
                break;
            }
            p = f.nodes.items[p].parent;
        }
        _ = n;
    }
    return mask;
}

/// The pages (0-based) a box covers: the one it starts on, and the one the flow continues on after
/// it (none for an out-of-flow box). takumi `BoxPages`.
pub const BoxPages = struct { start: u32, next: ?u32 };

/// Per element of the frame's `Dom`: the pages its box covers, null without a box of its own (inline
/// content, `display: none`, or inside a masked (repeating fixed) subtree).
pub fn elementBoxes(a: Allocator, f: *const Frame, pages: *const layout.fragment.Pages, mask: ?[]const bool) Allocator.Error![]?BoxPages {
    const out = try a.alloc(?BoxPages, f.dom.els.items.len);
    @memset(out, null);
    for (f.nodes.items, 0..) |n, id| {
        if (n.el == none or n.lid == none or n.el >= out.len) continue;
        if (mask) |m| if (m[id]) continue;
        if (n.cs.display == .none) continue;
        const position = boxPosition(f, @intCast(id)) orelse continue;
        const top = position.top;
        const next: ?u32 = if (position.flow_bottom) |bottom| pages.pageAt(bottom) else null;
        if (out[n.el]) |*b| {
            if (next) |x| b.next = if (b.next) |y| @max(x, y) else x;
        } else out[n.el] = .{ .start = pages.pageAt(top), .next = next };
    }
    return out;
}

/// The page (0-based) the box of `el` (an element of the frame's `Dom`) starts on, null when it has
/// no box of its own. For a single lookup; `elementBoxes` maps every element at once.
pub fn elementPage(f: *const Frame, el: u32) ?u32 {
    const pages = f.paginated() orelse return null;
    for (f.nodes.items, 0..) |n, id| {
        if (n.el != el or n.lid == none or n.cs.display == .none) continue;
        return pages.pageAt((boxPosition(f, @intCast(id)) orelse continue).top);
    }
    return null;
}

/// The anchor `href="#id"` names: the first box (document order) of an element with that `id`.
pub const Anchor = struct { node: u32, top: f32, page: u32 };

/// Where the element with `id` landed (first box wins, as the first paint does in takumi), null when
/// no element with a box carries it. `mask` leaves out repeating fixed subtrees. The frame must be
/// paginated. (Internal links and target counters.)
pub fn anchor(f: *const Frame, id: []const u8, mask: ?[]const bool) ?Anchor {
    const pages = f.paginated() orelse return null;
    for (f.nodes.items, 0..) |n, k| {
        if (n.el == none or n.lid == none or n.cs.display == .none) continue;
        if (mask) |m| if (m[k]) continue;
        if (!std.mem.eql(u8, f.dom.at(n.el).id, id)) continue;
        const top = (boxPosition(f, @intCast(k)) orelse continue).top;
        return .{ .node = @intCast(k), .top = top, .page = pages.pageAt(top) };
    }
    return null;
}

/// The page (0-based) the element with `id` starts on; see `anchor`.
pub fn anchorPage(f: *const Frame, id: []const u8) ?u32 {
    return if (anchor(f, id, null)) |x| x.page else null;
}

/// takumi `percent_decode`: `%XX` escapes decoded (an invalid one, or one cut short, kept as
/// written); a result that is not UTF-8 keeps the whole fragment as written.
pub fn percentDecode(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(a, b);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(a, s[i]);
        i += 1;
    }
    if (!std.unicode.utf8ValidateSlice(out.items)) return s;
    return out.items;
}

/// A run of pages laid out at one width (paged.zig: one frame per run of page widths, every
/// frame of the same document with the same render nodes): document pages `first ..< first +
/// count` are pages `local0 ..` of `frame`'s pagination.
/// `extends`: the fragments of its last page reaching past that page's end (paged.zig `cellOverflow`).
pub const Seg = struct { frame: *Frame, first: u32, local0: u32, count: u32, extends: []const layout.fragment.Extend = &.{} };

/// The document page block offset `top` of segment `s`'s frame is on, null when that is not a page
/// the segment shows (an earlier or a later segment shows it).
fn segPage(segs: []const Seg, s: usize, top: f32) ?u32 {
    const sg = segs[s];
    const pages = sg.frame.paginated() orelse return null;
    const k = pages.pageAt(top);
    if (k < sg.local0) return if (s == 0) sg.first else null;
    if (k >= sg.local0 + sg.count and s + 1 < segs.len) return null;
    return sg.first + @min(k - sg.local0, sg.count -| 1);
}

/// `elementBoxes` over the segments: a box starts on the page of the segment that shows its top,
/// the flow goes on after it on the page of the segment that shows its bottom.
fn segBoxes(a: Allocator, segs: []const Seg, mask: ?[]const bool) Allocator.Error![]?BoxPages {
    const f0 = segs[0].frame;
    if (segs.len == 1) return elementBoxes(a, f0, f0.paginated().?, mask);
    const out = try a.alloc(?BoxPages, f0.dom.els.items.len);
    @memset(out, null);
    for (segs, 0..) |sg, s| {
        const f = sg.frame;
        for (f.nodes.items, 0..) |n, id| {
            if (n.el == none or n.lid == none or n.el >= out.len) continue;
            if (mask) |m| if (id < m.len and m[id]) continue;
            if (n.cs.display == .none) continue;
            const position = boxPosition(f, @intCast(id)) orelse continue;
            const top = position.top;
            const next: ?u32 = if (position.flow_bottom) |bottom| segPage(segs, s, bottom) else null;
            if (out[n.el]) |*b| {
                if (next) |x| b.next = if (b.next) |y| @max(x, y) else x;
            } else if (segPage(segs, s, top)) |p| {
                out[n.el] = .{ .start = p, .next = next };
            }
        }
    }
    return out;
}

/// The document page the element with `id` starts on over the segments (see `anchor`).
fn segAnchorPage(segs: []const Seg, id: []const u8, mask: ?[]const bool) ?u32 {
    if (segs.len == 1) return if (anchor(segs[0].frame, id, mask)) |t| t.page else null;
    for (segs, 0..) |sg, s| {
        const f = sg.frame;
        for (f.nodes.items, 0..) |n, k| {
            if (n.el == none or n.lid == none or n.cs.display == .none) continue;
            if (mask) |m| if (k < m.len and m[k]) continue;
            if (!std.mem.eql(u8, f.dom.at(n.el).id, id)) continue;
            if (segPage(segs, s, (boxPosition(f, @intCast(k)) orelse continue).top)) |p| return p;
            break;
        }
    }
    return null;
}

/// The texts one laid-out, paginated pass gives the content's hooks (`hooks`, as that pass's
/// `Subst` met them), by hook: page counters from where their boxes landed (takumi `FlowCounters`),
/// target counters from the page their target starts on ("" when none), null for a page hook
/// without a page or one in `fixed` (left to the per-page layout of its repeating fixed box).
pub fn flowTexts(a: Allocator, segs: []const Seg, hooks: []const Hook, fixed: []const bool, mask: []const bool) Allocator.Error![]?[]const u8 {
    const texts = try a.alloc(?[]const u8, hooks.len);
    @memset(texts, null);
    if (segs.len == 0) return texts;
    const f = segs[0].frame;
    if (f.paginated() == null) return texts;
    var count: usize = 0;
    for (segs) |s| count += s.count;
    const boxes = try segBoxes(a, segs, mask);
    const page_of = try a.alloc(?u32, f.dom.els.items.len);
    @memset(page_of, null);
    var w: FlowWalk = .{ .d = &f.dom, .boxes = boxes, .page = page_of };
    if (f.dom.root != none) w.visit(f.dom.root, null, 0);
    for (hooks, 0..) |h, k| switch (h.kind) {
        .page, .pages => {
            if (k < fixed.len and fixed[k]) continue;
            const page = page_of[h.el] orelse continue;
            texts[k] = try h.style.format(a, if (h.kind == .page) page + 1 else count);
        },
        .target => {
            var text: []const u8 = "";
            if (h.href) |href| if (href.len > 1 and href[0] == '#') {
                const id = try percentDecode(a, href[1..]);
                if (segAnchorPage(segs, id, mask)) |p| text = try h.style.format(a, p + 1);
            };
            texts[k] = text;
        },
    };
    return texts;
}

const FlowWalk = struct {
    d: *const Dom,
    boxes: []const ?BoxPages,
    page: []?u32,
    reached: ?u32 = null,

    fn visit(w: *FlowWalk, i: u32, inherited: ?u32, depth: u32) void {
        if (depth > 600) return;
        const own = w.boxes[i];
        const inherit = if (own) |b| b.start else inherited;
        var c = w.d.at(i).first;
        while (c != none) : (c = w.d.at(c).next) w.visit(c, inherit, depth + 1);
        w.page[i] = if (own) |b| b.start else if (inherit) |p| (if (w.reached) |r| @max(p, r) else p) else null;
        if (own) |b| if (b.next) |n| {
            w.reached = n;
        };
    }
};

/// For each hook, whether it sits inside a repeating fixed box (`mask` over the frame's nodes).
pub fn fixedHooks(a: Allocator, f: *const Frame, hooks: []const Hook, mask: []const bool) Allocator.Error![]bool {
    const out = try a.alloc(bool, hooks.len);
    @memset(out, false);
    // elements whose box is a repeating fixed root (the subtree's elements are its DOM descendants)
    const fixed_el = try a.alloc(bool, f.dom.els.items.len);
    @memset(fixed_el, false);
    for (f.nodes.items, 0..) |n, k| {
        if (!mask[k] or n.el == none or n.el >= fixed_el.len) continue;
        if (n.parent != none and mask[n.parent]) continue;
        fixed_el[n.el] = true;
    }
    for (hooks, 0..) |h, k| {
        var p = h.el;
        var guard: u32 = 0;
        while (p != none and guard < 1024) : (guard += 1) {
            if (fixed_el[p]) {
                out[k] = true;
                break;
            }
            p = f.dom.at(p).parent;
        }
    }
    return out;
}

/// Whether two hook text lists are the same (the counters settled).
pub fn sameTexts(x: []const ?[]const u8, y: []const ?[]const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if ((p == null) != (q == null)) return false;
        if (p) |s| if (!std.mem.eql(u8, s, q.?)) return false;
    }
    return true;
}

test "counter styles (takumi counters.rs tests and the headers.mdx tables)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const fmt = struct {
        fn f(x: Allocator, v: usize, classes: []const u8) []const u8 {
            return CounterStyle.fromClasses(classes).format(x, v) catch unreachable;
        }
    }.f;
    try std.testing.expectEqualStrings("२०२६", fmt(aa, 2026, "devanagari"));
    try std.testing.expectEqualStrings("๒๐๒๖", fmt(aa, 2026, "thai"));
    try std.testing.expectEqualStrings("٢٠٢٦", fmt(aa, 2026, "arabic-indic"));
    try std.testing.expectEqualStrings(fmt(aa, 7, "cambodian"), fmt(aa, 7, "khmer"));
    try std.testing.expectEqualStrings("a", fmt(aa, 1, "lower-alpha"));
    try std.testing.expectEqualStrings("z", fmt(aa, 26, "lower-alpha"));
    try std.testing.expectEqualStrings("aa", fmt(aa, 27, "lower-alpha"));
    try std.testing.expectEqualStrings("AB", fmt(aa, 28, "upper-latin"));
    try std.testing.expectEqualStrings("α", fmt(aa, 1, "lower-greek"));
    try std.testing.expectEqualStrings("μ", fmt(aa, 12, "lower-greek"));
    try std.testing.expectEqualStrings("ア", fmt(aa, 1, "katakana"));
    try std.testing.expectEqualStrings("し", fmt(aa, 12, "hiragana"));
    try std.testing.expectEqualStrings("42", fmt(aa, 42, "no-such-style"));
    try std.testing.expectEqualStrings("07", fmt(aa, 7, "decimal-leading-zero"));
    try std.testing.expectEqualStrings("12", fmt(aa, 12, "decimal-leading-zero"));
    try std.testing.expectEqualStrings("vii", fmt(aa, 7, "pageNumber muted lower-roman"));
    try std.testing.expectEqualStrings("XII", fmt(aa, 12, "upper-roman"));
    try std.testing.expectEqualStrings("七", fmt(aa, 7, "cjk-decimal"));
    try std.testing.expectEqualStrings("一二", fmt(aa, 12, "cjk-decimal"));
    try std.testing.expectEqualStrings("十二", fmt(aa, 12, "trad-chinese-informal"));
    try std.testing.expectEqualStrings("十二", fmt(aa, 12, "cjk-ideographic"));
    try std.testing.expectEqualStrings("一百零三", fmt(aa, 103, "trad-chinese-informal"));
    try std.testing.expectEqualStrings("一零零零零", fmt(aa, 10000, "trad-chinese-informal"));
    try std.testing.expectEqualStrings("١٢", fmt(aa, 12, "arabic-indic"));
    try std.testing.expectEqualStrings("༡༢", fmt(aa, 12, "tibetan"));
    try std.testing.expect(hookOf("pageNumber totalPages").? == .page);
    try std.testing.expect(hookOf("x totalPages").? == .pages);
    try std.testing.expect(hookOf("pagenumber") == null);
    try std.testing.expectEqualStrings("section 1", try percentDecode(aa, "section%201"));
    try std.testing.expectEqualStrings("a ", try percentDecode(aa, "a%20"));
    try std.testing.expectEqualStrings("a%2", try percentDecode(aa, "a%2"));
}
