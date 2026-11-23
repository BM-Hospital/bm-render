//! Paged layout through the real pipeline (source -> Frame -> `setPaged` / `prepare` / `paginate`):
//! line placement with real fonts, widows / orphans, forced and avoided breaks, images, repeated table
//! headers, flex columns, the takumi-pdf pagination fixtures (`tests/upstream/takumi/takumi-pdf/tests/pdf_fixtures.rs`,
//! page counts read from its `tests/fixtures-generated/*.pdf`), and pages painted by the raster painter.
//! Only with the PDF feature (`zig build test -Dpdf=true`); the fonts are read from `tests/upstream/takumi/assets`
//! (Archivo, the font takumi's fixtures render with) or `assets/fonts`, falling back to the embedded Inter.
const std = @import("std");
const rt = @import("render.zig");
const layout = @import("layout/layout.zig");
const frag = layout.fragment;
const T = std.testing;

const enabled = frag.enabled;
/// The PDF document pipeline (`pdf/paged.zig`: runs of pages laid out at their own widths, which
/// continue a paragraph through `Paragraph.cut`, a PDF build feature).
const pdf_enabled = enabled and @import("config.zig").enable_pdf;

fn readFile(path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, T.allocator, .limited(64 << 20)) catch null;
}

fn newRenderer() !*rt.Renderer {
    const gpa = T.allocator;
    const r = rt.Renderer.create(gpa) orelse return error.OutOfMemory;
    errdefer r.destroy();
    var any = false;
    for ([_][]const u8{ "tests/upstream/takumi/assets/fonts/archivo/Archivo-VariableFont_wdth,wght.ttf", "assets/fonts/Roboto-Regular.ttf" }) |p| {
        if (readFile(p)) |bytes| {
            _ = try r.registerFont(bytes, "", 0, -1, null);
            any = true;
            break;
        }
    }
    if (!any) _ = try r.registerFont(try gpa.dupe(u8, @embedFile("font/testdata/Inter-Regular.ttf")), "", 0, -1, null);
    return r;
}

const Doc = struct {
    r: *rt.Renderer,
    f: rt.Frame,
    pages: *const frag.Pages,

    fn deinit(d: *Doc) void {
        d.r.destroy();
    }
    fn count(d: *const Doc) usize {
        return d.pages.pages.len;
    }
};

/// `src` laid out on pages of `page_w` x `page_h` px with uniform `margin`s (or `margins` t, r, b, l).
fn openM(kind: rt.SourceKind, src: []const u8, page_w: f32, page_h: f32, m: [4]f32) !*Doc {
    const r = try newRenderer();
    errdefer r.destroy();
    r.beginCall();
    const a = r.arena.allocator();
    const d = try a.create(Doc);
    d.r = r;
    d.f = .{ .r = r, .a = a, .opts = .{}, .tree = rt.LTree.init(a), .ctx = undefined };
    const cw = page_w - m[1] - m[3];
    const ch = page_h - m[0] - m[2];
    d.f.setPaged(cw, ch);
    d.f.prepare(kind, src) catch |e| {
        if (e == error.Invalid) std.debug.print("render error: {s}\n", .{r.err});
        return e;
    };
    d.pages = try d.f.paginate(.{ .page_height = ch });
    return d;
}
fn open(kind: rt.SourceKind, src: []const u8, page_w: f32, page_h: f32, margin: f32) !*Doc {
    return openM(kind, src, page_w, page_h, .{ margin, margin, margin, margin });
}

/// Border-box block start of layout node `lid` in stitched space.
fn absTop(f: *const rt.Frame, lid: u32) f32 {
    var y: f32 = 0;
    var cur = lid;
    while (cur < f.tree.nodes.items.len) {
        y += f.tree.layout(cur).y;
        if (cur == f.lroot) break;
        cur = f.tree.nodes.items[cur].parent;
    }
    return y;
}

/// Not painted, or inside monolithic content (a `line-clamp` box, an atomic inline), whose lines
/// are not fragmented.
fn skipped(f: *const rt.Frame, id: u32) bool {
    var cur = id;
    while (cur != rt.none) {
        const n = &f.nodes.items[cur];
        if (n.kind != .anon_text) {
            const d = n.cs.display;
            if (d == .none or n.cs.line_clamp > 0) return true;
            if (cur != id and (d == .inline_block or d == .inline_flex or d == .inline_grid or d == .inline_table)) return true;
        }
        cur = n.parent;
    }
    return false;
}

const Stats = struct { lines: u32 = 0, split: u32 = 0 };

/// Every line of every paragraph: on one page (no line cut by a page boundary, as far as the line fits
/// a page), and a paragraph split across pages leaves `orphans` lines before and `widows` after.
fn checkLines(d: *Doc) !Stats {
    const f = &d.f;
    const pages = d.pages;
    var st: Stats = .{};
    var counts: std.ArrayList(u32) = .empty;
    defer counts.deinit(T.allocator);
    for (f.nodes.items, 0..) |*n, i| {
        if (n.para == null or n.lid == rt.none) continue;
        if (skipped(f, @intCast(i))) continue;
        const l = f.tree.layout(n.lid);
        if (!(l.w > 0)) continue;
        const cw = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
        const tl = (try f.textLayout(@intCast(i), cw)) orelse continue;
        const top0 = absTop(f, n.lid) + l.border.top + l.padding.top;
        counts.clearRetainingCapacity();
        var last_page: u32 = std.math.maxInt(u32);
        for (tl.lines, 0..) |ln, k| {
            if (!(ln.height > 0)) continue;
            const t = top0 + ln.top;
            const b = t + ln.height;
            const pi = pages.pageAt(t + 0.01);
            const pg = pages.pages[pi];
            st.lines += 1;
            if (ln.height <= pg.height and pi + 1 < pages.pages.len and b > pg.top + pg.height + 0.02) {
                std.debug.print("node {d} line {d}: [{d:.2}, {d:.2}) cut by the end of page {d} at {d:.2}\n", .{ i, k, t, b, pi, pg.top + pg.height });
                return error.LineCutByPage;
            }
            if (pi != last_page) {
                try counts.append(T.allocator, 0);
                last_page = pi;
            }
            counts.items[counts.items.len - 1] += 1;
        }
        if (counts.items.len > 1) {
            st.split += 1;
            const w: u32 = n.cs.widows;
            const o: u32 = n.cs.orphans;
            var total: u32 = 0;
            for (counts.items) |c| total += c;
            if (total >= w + o and (counts.items[0] < o or counts.items[counts.items.len - 1] < w)) {
                std.debug.print("node {d}: lines per page {any}, orphans {d}, widows {d}\n", .{ i, counts.items, o, w });
                return error.WidowsOrphans;
            }
        }
    }
    return st;
}

/// Page of the border-box block start of the first element with `id`.
fn pageOfId(d: *Doc, id: []const u8) !u32 {
    const f = &d.f;
    for (f.nodes.items) |*n| {
        if (n.el == rt.none) continue;
        if (!std.mem.eql(u8, f.dom.at(n.el).id, id)) continue;
        return d.pages.pageAt(absTop(f, n.lid) + 0.01);
    }
    return error.NoSuchId;
}
fn nodeOfId(d: *Doc, id: []const u8) !*const rt.Node {
    for (d.f.nodes.items) |*n| {
        if (n.el != rt.none and std.mem.eql(u8, d.f.dom.at(n.el).id, id)) return n;
    }
    return error.NoSuchId;
}

const lorem = "Paged media splits the flow of a document into pages. A paragraph that does not fit on " ++
    "the current page continues on the next one, and its lines are never cut by the page edge. The " ++
    "orphans and widows properties set how many lines must stay together at the bottom and at the top of a page.";

test "paged floats: deferred whole floats rebuild the line exclusion space" {
    if (!enabled) return error.SkipZigTest;
    for ([_]u32{ 10, 30 }) |margin| {
        const src = try std.fmt.allocPrint(T.allocator, "<style>html,body{{margin:0}}.l{{height:20px}}</style><div style=\"font:12px/20px Inter\"><div style=\"height:140px\"></div><div id=\"float\" style=\"float:left;width:100px;margin-top:{d}px;break-inside:avoid\"><div class=\"l\">F1</div><div class=\"l\">F2</div><div class=\"l\">F3</div><div class=\"l\">F4</div></div><div id=\"before\" class=\"l\">L8</div><div class=\"l\">L9</div><div id=\"beside\" class=\"l\">L10</div><div class=\"l\">L11</div><div class=\"l\">L12</div><div id=\"last\" class=\"l\">L13</div><div class=\"l\">L14</div></div>", .{margin});
        defer T.allocator.free(src);
        const d = try open(.html, src, 300, 200, 10);
        defer d.deinit();
        try T.expectEqual(@as(usize, 2), d.count());
        const floating = try nodeOfId(d, "float");
        try T.expectApproxEqAbs(@as(f32, 180) + @as(f32, @floatFromInt(margin)), absTop(&d.f, floating.lid), 0.02);
        for ([_][]const u8{ "before", "beside", "last" }, [_]f32{ 0, 100, 100 }) |id, expected_x| {
            var node = try nodeOfId(d, id);
            while (node.para == null and node.first_child != rt.none) node = &d.f.nodes.items[node.first_child];
            const tl = node.tl orelse return error.MissingText;
            try T.expectApproxEqAbs(expected_x, tl.lines[0].x, 0.02);
        }
    }
}

test "paged floats: resumed exclusions and clearance follow alternating page widths" {
    if (!pdf_enabled) return error.SkipZigTest;
    const r = rt.Renderer.create(T.allocator) orelse return error.OutOfMemory;
    defer r.destroy();
    const bytes = readFile("assets/fonts/Inter-Regular.ttf") orelse return error.FileNotFound;
    _ = try r.registerFont(bytes, "Inter", 0, -1, null);
    r.beginCall();
    const a = r.arena.allocator();
    const prefix = comptime blk: {
        var s: []const u8 = "";
        for (0..7) |_| s = s ++ "<div style=\"height:20px\">L</div>";
        break :blk s;
    };
    const text = comptime blk: {
        var s: []const u8 = "";
        for (0..40) |_| s = s ++ "following words ";
        break :blk s;
    };
    const src = "<style>@page{size:300px 200px;margin:10px}@page:left{size:360px 200px}html,body{margin:0;padding:0}body{font:12px/20px Inter}p{margin:0}</style>" ++ prefix ++ "<div id=\"float\" style=\"float:left;width:100px;margin-top:10px;break-inside:avoid\"><div style=\"height:20px\">F1</div><div style=\"height:20px\">F2</div><div style=\"height:20px\">F3</div><div style=\"height:20px\">F4</div></div><p>" ++ text ++ "</p><div id=\"clear\" style=\"height:20px;clear:both\">CLEAR</div>";
    const pg = @import("pdf/paged.zig");
    const d = try pg.layOut(r, a, .{}, null, .html, src, @import("pdf/options.zig").Page.a4, null);
    defer d.release(r);
    try T.expectEqual(@as(usize, 4), d.pages.len);
    for (d.pages, [_]f32{ 300, 360, 300, 360 }) |page, width| try T.expectEqual(width, page.width);
    const f = d.pages[3].frame orelse d.frame;
    var found = false;
    for (f.nodes.items) |n| if (n.para) |p| {
        if (!std.mem.eql(u8, rt.Frame.paragraphText(p), "CLEAR")) continue;
        try T.expectApproxEqAbs(@as(f32, 560), absTop(f, n.lid), 0.02);
        found = true;
    };
    try T.expect(found);
}

test "paged rowspans: independent cell continuations preserve assigned rows" {
    if (!pdf_enabled) return error.SkipZigTest;
    const r = rt.Renderer.create(T.allocator) orelse return error.OutOfMemory;
    defer r.destroy();
    const bytes = readFile("assets/fonts/Inter-Regular.ttf") orelse return error.FileNotFound;
    _ = try r.registerFont(bytes, "Inter", 0, -1, null);
    r.beginCall();
    const a = r.arena.allocator();
    var words: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty };
    for ("LRB", &words) |letter, *out| for (0..45) |i| try out.appendSlice(a, try std.fmt.allocPrint(a, "{c}{d} word{s}", .{ letter, i, if (i == 44) "" else " " }));
    const src = try std.fmt.allocPrint(a, "<style>@page{{size:240px 140px;margin:10px}}@page:left{{size:360px 140px;margin:10px}}p{{margin:0}}td{{padding:0;vertical-align:top}}table{{border-spacing:0}}</style><div style=\"font:14px/20px Inter\"><table style=\"width:100%\"><tr><td rowspan=\"2\" style=\"width:50%\">{s}</td><td>{s}</td></tr><tr><td>{s}</td></tr></table><p>AFTER</p></div>", .{ words[0].items, words[1].items[0..130], words[2].items });
    const pg = @import("pdf/paged.zig");
    const d = try pg.layOut(r, a, .{}, null, .html, src, @import("pdf/options.zig").Page.a4, null);
    defer d.release(r);
    try T.expectEqual(@as(usize, 8), d.pages.len);
    for (d.pages, 0..) |page, i| {
        const f = page.frame orelse d.frame;
        // The seventh source page is empty row space; it can reuse a scene,
        // provided no glyph line is placed on that page.
        if (i == 6) {
            for (f.nodes.items) |n| if (n.tl) |tl| {
                const box = f.tree.layout(n.lid);
                const top = absTop(f, n.lid) + box.border.top + box.padding.top;
                for (tl.lines) |line| {
                    if (line.glyph_start == line.glyph_end) continue;
                    const baseline = top + line.baseline;
                    try T.expect(baseline < d.windows[i].top or baseline >= d.windows[i].bottom);
                }
            };
            continue;
        }
        try T.expectEqual(page.content.w, f.tree.paged.page_w);
    }
}

/// Absolute left edge of layout node `lid`'s border box in its frame.
fn absLeft(f: *const rt.Frame, lid: u32) f32 {
    var x: f32 = 0;
    var cur = lid;
    while (cur < f.tree.nodes.items.len) {
        x += f.tree.layout(cur).x;
        if (cur == f.lroot) break;
        cur = f.tree.nodes.items[cur].parent;
    }
    return x;
}

/// Lays `src` out through the PDF pipeline (pages of their own widths) with Inter as the only font.
fn pdfLayOut(r: *rt.Renderer, src: []const u8) !@import("pdf/paged.zig").Document {
    const bytes = readFile("assets/fonts/Inter-Regular.ttf") orelse return error.FileNotFound;
    _ = try r.registerFont(bytes, "Inter", 0, -1, null);
    r.beginCall();
    const pg = @import("pdf/paged.zig");
    return pg.layOut(r, r.arena.allocator(), .{}, null, .html, src, @import("pdf/options.zig").Page.a4, null);
}

/// Every text line a page shows (its baseline in the page's window) was laid out in a frame as wide
/// as that page's area and lies inside it: no page keeps the width of the run before it.
fn expectLinesFitPages(d: *const @import("pdf/paged.zig").Document) !void {
    for (d.pages, 0..) |page, i| {
        const f = page.frame orelse d.frame;
        const win = d.windows[i];
        for (f.nodes.items) |n| if (n.tl) |tl| {
            if (n.lid == rt.none) continue;
            const box = f.tree.layout(n.lid);
            const top = absTop(f, n.lid) + box.border.top + box.padding.top;
            const left = absLeft(f, n.lid) + box.border.left + box.padding.left;
            for (tl.lines) |line| {
                if (line.glyph_start == line.glyph_end) continue;
                const baseline = top + line.baseline;
                if (baseline < win.top or baseline >= win.bottom) continue;
                if (f.tree.paged.page_w != page.content.w or left + line.x + line.width > page.content.w + 0.5) {
                    std.debug.print("page {d}: a line at x {d:.1}..{d:.1} (frame width {d:.1}) on a page area {d:.1} wide\n", .{ i, left + line.x, left + line.x + line.width, f.tree.paged.page_w, page.content.w });
                    return error.LineOutsidePageWidth;
                }
            }
        };
    }
}

fn wordList(a: std.mem.Allocator, prefix: []const u8, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |i| try out.appendSlice(a, try std.fmt.allocPrint(a, "{s}{d} word{s}", .{ prefix, i, if (i + 1 == n) "" else " " }));
    return out.items;
}

const alternating = "<style>@page{size:240px 140px;margin:10px}@page:left{size:360px 140px;margin:10px}p{margin:0}td{padding:0;vertical-align:top}table{border-spacing:0}</style>";

test "paged continuation: a row resumed below a rowspan's finished rows takes the new page width" {
    if (!pdf_enabled) return error.SkipZigTest;
    const r = rt.Renderer.create(T.allocator) orelse return error.OutOfMemory;
    defer r.destroy();
    const a = r.arena.allocator();
    const src = try std.fmt.allocPrint(T.allocator, "{s}<div style=\"font:14px/20px Inter\"><table style=\"width:100%\"><tr><td rowspan=\"2\" style=\"width:35%\">{s}</td><td>{s}</td></tr><tr><td>{s}</td></tr></table><p>AFTER</p></div>", .{ alternating, try wordList(a, "S", 10), try wordList(a, "R1", 30), try wordList(a, "R2", 30) });
    defer T.allocator.free(src);
    const d = try pdfLayOut(r, src);
    defer d.release(r);
    try T.expectEqual(@as(usize, 6), d.pages.len);
    try expectLinesFitPages(&d);
}

test "paged continuation: a rowspan still running past its first row's end takes each page width" {
    if (!pdf_enabled) return error.SkipZigTest;
    const r = rt.Renderer.create(T.allocator) orelse return error.OutOfMemory;
    defer r.destroy();
    const a = r.arena.allocator();
    const src = try std.fmt.allocPrint(T.allocator, "{s}<div style=\"font:14px/20px Inter\"><table style=\"width:100%\"><tr><td rowspan=\"3\" style=\"width:40%\">{s}</td><td>{s}</td></tr><tr><td>{s}</td></tr><tr><td>{s}</td></tr></table><p>AFTER</p></div>", .{ alternating, try wordList(a, "S", 40), try wordList(a, "R1", 8), try wordList(a, "R2", 8), try wordList(a, "R3", 8) });
    defer T.allocator.free(src);
    const d = try pdfLayOut(r, src);
    defer d.release(r);
    try T.expectEqual(@as(usize, 7), d.pages.len);
    try expectLinesFitPages(&d);
}

/// `body` after the alternating 240 / 360 px page sheet, in 14px/20px Inter, followed by a long paragraph.
fn alternatingDoc(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}<div style=\"font:14px/20px Inter\">{s}<p>{s}</p></div>", .{ alternating, body, try wordList(a, "AFTER", 40) });
}

test "paged continuation: flex and grid containers continue at each page width, their items at their first width" {
    if (!pdf_enabled) return error.SkipZigTest;
    // (pinned takumi: the container's box and the content after it take each page's width; the
    // items of a container broken inside keep the sizes and offsets of its first fragment)
    const bodies = [_][]const u8{
        "<div id=\"c\" style=\"display:flex;flex-direction:column\"><div id=\"i\">{s}</div><div>{s}</div></div>",
        "<div id=\"c\" style=\"display:grid\"><div id=\"i\">{s}</div><div>{s}</div></div>",
        "<div id=\"c\" style=\"display:flex\"><div id=\"i\" style=\"flex:1\">{s}</div><div style=\"flex:1\">{s}</div></div>",
        "<div id=\"c\" style=\"display:grid;grid-template-columns:1fr 1fr\"><div id=\"i\">{s}</div><div>x</div><div>{s}</div><div>y</div></div>",
    };
    inline for (bodies) |body| {
        const r = rt.Renderer.create(T.allocator) orelse return error.OutOfMemory;
        defer r.destroy();
        var arena = std.heap.ArenaAllocator.init(T.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const src = try alternatingDoc(a, try std.fmt.allocPrint(a, body, .{ try wordList(a, "A", 30), try wordList(a, "B", 30) }));
        const d = try pdfLayOut(r, src);
        defer d.release(r);
        try expectLinesFitPages(&d);
        // page 1 (360 px) continues the container: its box is 340 px wide, the first item as on page 0
        const f0 = d.pages[0].frame orelse d.frame;
        const f1 = d.pages[1].frame orelse d.frame;
        try T.expect(f1 != f0);
        const c1 = (try nodeOfFrameId(f1, "c")).lid;
        try T.expectApproxEqAbs(@as(f32, 340), f1.tree.layout(c1).w, 0.01);
        try T.expectApproxEqAbs(f0.tree.layout((try nodeOfFrameId(f0, "i")).lid).w, f1.tree.layout((try nodeOfFrameId(f1, "i")).lid).w, 0.01);
    }
}

test "paged continuation: a table row starting on a page of another width keeps the block size its table gave it" {
    if (!pdf_enabled) return error.SkipZigTest;
    // (pinned takumi: the second row starts on a 360 px page but keeps the block size of the table
    // laid out at the 240 px page it starts on, so AFTER lands on page 7)
    const r = rt.Renderer.create(T.allocator) orelse return error.OutOfMemory;
    defer r.destroy();
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try std.fmt.allocPrint(a, "{s}<div style=\"font:14px/20px Inter\"><table style=\"width:100%\"><tr><td style=\"width:50%\">{s}</td><td>{s}</td></tr><tr><td>{s}</td><td>{s}</td></tr></table><p id=\"after\">AFTER</p></div>", .{ alternating, try wordList(a, "A", 30), try wordList(a, "B", 20), try wordList(a, "C", 30), try wordList(a, "D", 30) });
    const d = try pdfLayOut(r, src);
    defer d.release(r);
    try expectLinesFitPages(&d);
    try T.expectEqual(@as(usize, 7), d.pages.len);
}

test "paged continuation: the content after an end-aligned grid row takes each page width" {
    if (!pdf_enabled) return error.SkipZigTest;
    const r = rt.Renderer.create(T.allocator) orelse return error.OutOfMemory;
    defer r.destroy();
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try alternatingDoc(a, try std.fmt.allocPrint(a, "<div style=\"display:grid;grid-template-columns:1fr 1fr;align-items:end\"><div>{s}</div><div>{s}</div></div>", .{ try wordList(a, "A", 30), try wordList(a, "B", 4) }));
    const d = try pdfLayOut(r, src);
    defer d.release(r);
    try expectLinesFitPages(&d);
    try T.expectEqual(@as(usize, 6), d.pages.len);
}

test "paged floats: a paragraph moved by orphans beside a deferred float wraps against it where it lands" {
    if (!enabled) return error.SkipZigTest;
    const rows = comptime blk: {
        var out: [2][]const u8 = .{ "", "" };
        for (&out, [_]usize{ 7, 4 }) |*o, n| {
            for (0..n) |_| o.* = o.* ++ "<div style=\"height:20px\">LINE</div>";
        }
        break :blk out;
    };
    const words = comptime blk: {
        @setEvalBranchQuota(100000);
        var s: []const u8 = "";
        for (0..36) |i| s = s ++ std.fmt.comptimePrint("w{d} ", .{i});
        break :blk s;
    };
    // (the float does not fit below the seven lines and moves to page 2; two lines of the paragraph
    // would stay on page 1, fewer than its orphans, so it moves too: pinned takumi wraps its first
    // lines beside the float there, not across it)
    const src = "<style>html,body{margin:0;padding:0} p{margin:0}</style>" ++ rows[0] ++ "<div id=\"f\" style=\"float:left;width:100px;break-inside:avoid\">" ++ rows[1] ++ "</div><p id=\"p\" style=\"widows:4;orphans:4\">" ++ words ++ "</p>";
    const d = try open(.html, src, 300, 200, 10);
    defer d.deinit();
    try T.expectEqual(@as(usize, 2), d.count());
    const f = try nodeOfId(d, "f");
    try T.expectApproxEqAbs(@as(f32, 180), absTop(&d.f, f.lid), 0.02);
    var q = try nodeOfId(d, "p");
    try T.expectApproxEqAbs(@as(f32, 180), absTop(&d.f, q.lid), 0.02);
    while (q.para == null and q.first_child != rt.none) q = &d.f.nodes.items[q.first_child];
    const tl = q.tl orelse return error.MissingText;
    try T.expect(tl.lines.len > 1);
    // (every line in the float's block range starts right of it)
    for (tl.lines) |ln| if (ln.top + ln.height <= 80) try T.expect(ln.x >= 100 - 0.02);
}

test "paged floats: the first line below a float wider than its container stays where the float leaves room" {
    if (!enabled) return error.SkipZigTest;
    const rows = comptime blk: {
        var out: [2][]const u8 = .{ "", "" };
        for (&out, [_]usize{ 3, 10 }) |*o, n| {
            for (0..n) |_| o.* = o.* ++ "<div style=\"height:20px\">LINE</div>";
        }
        break :blk out;
    };
    // (pinned takumi: the float runs to 260 px on page 2, the paragraph's first line follows it
    // there; the paragraph itself is not moved to page 2 first)
    const src = "<style>html,body{margin:0;padding:0} body{font:12px/20px Inter} p{margin:0}</style>" ++ rows[0] ++ "<div id=\"f\" style=\"float:left;width:400px\">" ++ rows[1] ++ "</div><p id=\"p\">w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 w16 w17 w18 w19 w20</p>";
    const d = try open(.html, src, 300, 200, 10);
    defer d.deinit();
    try T.expectEqual(@as(usize, 2), d.count());
    const p = try nodeOfId(d, "p");
    try T.expectApproxEqAbs(@as(f32, 60), absTop(&d.f, p.lid), 0.02);
}

test "paged floats: a clearing float after a split float shows on the page of another width it lands on" {
    if (!pdf_enabled) return error.SkipZigTest;
    const r = rt.Renderer.create(T.allocator) orelse return error.OutOfMemory;
    defer r.destroy();
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ls: std.ArrayList(u8) = .empty;
    for (1..6) |i| try ls.appendSlice(a, try std.fmt.allocPrint(a, "<div class=\"l\">L{d}</div>", .{i}));
    var fs: std.ArrayList(u8) = .empty;
    for (1..9) |i| try fs.appendSlice(a, try std.fmt.allocPrint(a, "<div class=\"l\">F{d}</div>", .{i}));
    // (F runs from 100 to 260 px, G clears it to 260..300 px on the 360 px page 2; the paragraph
    // beside them continues there from a cut, whose text before the cut is one line that must not
    // move below the floats and with it the start of page 2)
    const src = try std.fmt.allocPrint(a, "<style>@page{{size:300px 200px;margin:10px}}@page:left{{size:360px 200px;margin:10px}}html,body{{margin:0;padding:0}} body{{font:12px/20px Inter}} .l{{height:20px}} p{{margin:0}}</style>{s}<div style=\"float:left;width:100px\">{s}</div><div id=\"g\" style=\"float:left;width:100px;clear:left\"><div class=\"l\">G1</div><div class=\"l\">G2</div></div><p>{s}</p>", .{ ls.items, fs.items, try wordList(a, "w", 30) });
    const d = try pdfLayOut(r, src);
    defer d.release(r);
    try T.expectEqual(@as(usize, 2), d.pages.len);
    try expectLinesFitPages(&d);
    const f = d.pages[1].frame orelse d.frame;
    const g = try nodeOfFrameId(f, "g");
    try T.expectApproxEqAbs(@as(f32, 260), absTop(f, g.lid), 0.02);
    try T.expect(absTop(f, g.lid) >= d.windows[1].top);
}

test "paged flex column: the block-end margin of the item before a break is truncated at the page start" {
    if (!enabled) return error.SkipZigTest;
    // (66 px page areas: A ends at 50, its 30 px margin reaches 80, past the page end at 66; B's
    // own 10 px margin stays: B starts at 66 + 10, not at 90 with the rest of A's margin above it.
    // takumi window_scenes.rs report.html at 250x90, Chrome likewise)
    const src = "<style>html,body{margin:0;padding:0}</style><main style=\"display:flex;flex-direction:column\"><div style=\"height:50px;margin-bottom:30px\">A</div><div id=\"b\" style=\"height:20px;margin-top:10px\">B</div></main>";
    const d = try open(.html, src, 250, 90, 12);
    defer d.deinit();
    try T.expectEqual(@as(usize, 2), d.count());
    const b = try nodeOfId(d, "b");
    try T.expectApproxEqAbs(@as(f32, 76), absTop(&d.f, b.lid), 0.02);
}

test "paged floats: a first line pushed below a float onto a page of another width wraps at that width" {
    if (!pdf_enabled) return error.SkipZigTest;
    const r = rt.Renderer.create(T.allocator) orelse return error.OutOfMemory;
    defer r.destroy();
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ls: std.ArrayList(u8) = .empty;
    for (1..4) |i| try ls.appendSlice(a, try std.fmt.allocPrint(a, "<div class=\"l\">L{d}</div>", .{i}));
    var fs: std.ArrayList(u8) = .empty;
    for (1..11) |i| try fs.appendSlice(a, try std.fmt.allocPrint(a, "<div class=\"l\">F{d}</div>", .{i}));
    // (the float, wider than its container, runs from 60 to 260 px; the paragraph's box starts
    // beside it on page 1, its first line below it on the 360 px page 2: pinned takumi wraps the
    // paragraph there at 340 px, three lines from 260 px, after the float's last line)
    const src = try std.fmt.allocPrint(a, "<style>@page{{size:300px 200px;margin:10px}}@page:left{{size:360px 200px;margin:10px}}html,body{{margin:0;padding:0}} body{{font:12px/20px Inter}} .l{{height:20px}} p{{margin:0}}</style>{s}<div style=\"float:left;width:400px\">{s}</div><p id=\"p\">{s}</p>", .{ ls.items, fs.items, try wordList(a, "w", 15) });
    const d = try pdfLayOut(r, src);
    defer d.release(r);
    try T.expectEqual(@as(usize, 2), d.pages.len);
    try expectLinesFitPages(&d);
    const f = d.pages[1].frame orelse d.frame;
    const p = try nodeOfFrameId(f, "p");
    const tl = p.tl orelse return error.MissingText;
    const top = absTop(f, p.lid);
    try T.expectApproxEqAbs(@as(f32, 260), top + tl.lines[0].top, 0.02);
}

fn nodeOfFrameId(f: *const rt.Frame, id: []const u8) !*const rt.Node {
    for (f.nodes.items) |*n| {
        if (n.el != rt.none and std.mem.eql(u8, f.dom.at(n.el).id, id)) return n;
    }
    return error.NoSuchId;
}

test "paged grid: an item spanning rows keeps its block size when a break moves a row's content down" {
    if (!enabled) return error.SkipZigTest;
    const rows = comptime blk: {
        var out: [3][]const u8 = .{ "", "", "" };
        for (&out, [_]usize{ 14, 3, 4 }) |*o, n| {
            for (0..n) |_| o.* = o.* ++ "<div style=\"height:20px\">LINE</div>";
        }
        break :blk out;
    };
    // (pinned takumi: C's first line would cross the page end and moves down 10px, its row grows;
    // the stretched B in one row grows with it, S spanning both rows ends where its content does)
    const src = "<div style=\"height:40px\"></div><div style=\"display:grid;grid-template-columns:1fr 1fr\"><div id=\"s\" style=\"grid-row:span 2\">" ++ rows[0] ++ "</div><div id=\"b\">" ++ rows[1] ++ "</div><div id=\"c\">" ++ rows[2] ++ "</div></div>";
    const d = try open(.html, src, 300, 200, 10);
    defer d.deinit();
    try T.expectEqual(@as(usize, 2), d.count());
    const s = try nodeOfId(d, "s");
    const c = try nodeOfId(d, "c");
    try T.expectApproxEqAbs(@as(f32, 40), absTop(&d.f, s.lid), 0.02);
    try T.expectApproxEqAbs(@as(f32, 280), d.f.tree.layout(s.lid).h, 0.02);
    // (C starts at the top of page 2, the grid ends 10px below S)
    try T.expectApproxEqAbs(@as(f32, 180), absTop(&d.f, c.lid), 0.02);
    const grid = d.f.tree.nodes.items[s.lid].parent;
    try T.expectApproxEqAbs(@as(f32, 330), absTop(&d.f, grid) + d.f.tree.layout(grid).h, 0.02);
}

test "paged continuation: aligned grid items resume without repeating the row offset" {
    if (!enabled) return error.SkipZigTest;
    const rows = comptime blk: {
        var s: []const u8 = "";
        for (0..24) |_| s = s ++ "<div style=\"height:20px\">LINE</div>";
        break :blk s;
    };
    for ([_][]const u8{ "start", "center", "end" }) |alignment| {
        for ([_]u32{ 0, 60 }) |prefix| {
            const src = try std.fmt.allocPrint(T.allocator, "<div style=\"height:{d}px\"></div><div id=\"grid\" style=\"display:grid;grid-template-columns:1fr 1fr;align-items:{s}\"><div>{s}</div><div id=\"aligned\" style=\"height:20px\">ALIGNED</div></div>", .{ prefix, alignment, rows });
            defer T.allocator.free(src);
            const d = try open(.html, src, 300, 200, 10);
            defer d.deinit();
            const grid = try nodeOfId(d, "grid");
            const item = try nodeOfId(d, "aligned");
            const start = std.mem.eql(u8, alignment, "start");
            const grid_top: f32 = if (prefix == 0 or start) @floatFromInt(prefix) else 180;
            try T.expectEqual(grid_top, absTop(&d.f, grid.lid));
            try T.expectEqual(if (start) grid_top else grid_top + 180, absTop(&d.f, item.lid));
            try T.expect(std.math.isFinite(d.f.tree.layout(item.lid).grid_block_start));
        }
    }
}

test "page counters: painted ownership excludes only the own transform from the flow edge" {
    if (!enabled) return error.SkipZigTest;
    const counters = @import("pdf/counters.zig");
    for ([_]bool{ false, true }) |on_parent| {
        const src = try std.fmt.allocPrint(T.allocator, "<div><div style=\"height:60px\"></div><div style=\"{s}\"><div id=\"target\" style=\"height:20px;{s}\">COUNTER</div></div><div style=\"height:400px\"></div></div>", .{ if (on_parent) "transform:translateY(180px)" else "", if (on_parent) "" else "transform:translateY(180px)" });
        defer T.allocator.free(src);
        const d = try open(.html, src, 300, 200, 10);
        defer d.deinit();
        const target = try nodeOfId(d, "target");
        const boxes = try counters.elementBoxes(T.allocator, &d.f, d.pages, null);
        defer T.allocator.free(boxes);
        try T.expectEqual(@as(?u32, 1), counters.elementPage(&d.f, target.el));
        try T.expectEqual(@as(?u32, 1), counters.anchorPage(&d.f, "target"));
        try T.expectEqual(@as(u32, 1), boxes[target.el].?.start);
        try T.expectEqual(@as(?u32, if (on_parent) 1 else 0), boxes[target.el].?.next);
    }
}

test "paged: paragraphs with real fonts break between lines, widows / orphans respected" {
    if (!enabled) return error.SkipZigTest;
    inline for (.{ "", "widows: 4; orphans: 3;" }) |wo| {
        const para = "<p style=\"margin: 0 0 10px\">" ++ lorem ++ " " ++ lorem ++ "</p>";
        const src = "<div style=\"font-size: 16px; line-height: 22px; color: #111; " ++ wo ++ "\">" ++
            para ++ para ++ para ++ para ++ para ++ para ++ "</div>";
        const d = try open(.html, src, 400, 300, 24);
        defer d.deinit();
        const st = try checkLines(d);
        try T.expect(d.count() >= 4);
        try T.expect(st.lines > 40);
        // most page ends fall inside a paragraph
        try T.expect(st.split >= 2);
        // the moved lines are what text painting uses: every line's glyphs sit inside its line box
        const f = &d.f;
        for (f.nodes.items) |*n| {
            const tl = n.tl orelse continue;
            for (tl.lines) |ln| for (tl.glyphs[ln.glyph_start..ln.glyph_end]) |g| {
                try T.expect(g.y >= ln.top - 0.01 and g.y <= ln.top + ln.height + 0.01);
            };
        }
    }
}

test "paged: inline rows with atomic inlines and inline boxes, text beside a float" {
    if (!enabled) return error.SkipZigTest;
    const badge = "<span style=\"display: inline-block; padding: 2px 6px; background: #dcfce7\">badge</span>";
    const span = "<span style=\"background: #fee2e2; text-decoration: underline\">an inline box that wraps over several lines of the paragraph</span>";
    const para = "<p style=\"margin: 0 0 8px\">Text with a " ++ badge ++ " and " ++ span ++ ", then " ++ lorem ++ " " ++ badge ++ " end.</p>";
    const src = "<div style=\"font-size: 14px; line-height: 20px; color: #111\"><div style=\"float: left; width: 80px; height: 150px; background: #93c5fd\"></div>" ++
        para ++ para ++ para ++ para ++ para ++ "</div>";
    const d = try open(.html, src, 360, 220, 20);
    defer d.deinit();
    const st = try checkLines(d);
    try T.expect(d.count() >= 3);
    try T.expect(st.split >= 1);
    // the atomic inlines moved with their lines: each badge sits inside a line box of its row
    const f = &d.f;
    for (f.nodes.items) |*n| {
        if (n.kind != .anon_box) continue;
        const tl = n.tl orelse continue;
        const rl = f.tree.layout(n.lid);
        var c = n.first_child;
        while (c != rt.none) : (c = f.nodes.items[c].next) {
            const cl = f.tree.layout(f.nodes.items[c].lid);
            const mid = cl.y + cl.h / 2 - rl.border.top - rl.padding.top;
            var inside = false;
            for (tl.lines) |ln| inside = inside or (mid >= ln.top and mid <= ln.top + ln.height);
            try T.expect(inside);
        }
    }
    for (0..d.count()) |i| _ = try d.f.paintPageRaster(@intCast(i));
}

test "paged: forced breaks, break-inside: avoid, legacy page-break-* (takumi fixtures)" {
    if (!enabled) return error.SkipZigTest;
    const filler = "<p style=\"margin: 0\">line 1</p><p style=\"margin: 0\">line 2</p><p style=\"margin: 0\">line 3</p><p style=\"margin: 0\">line 4</p>" ++
        "<p style=\"margin: 0\">line 5</p><p style=\"margin: 0\">line 6</p><p style=\"margin: 0\">line 7</p><p style=\"margin: 0\">line 8</p>";
    {
        // legacy-page-break.pdf: 3 pages
        const src = "<div style=\"font-size: 12px; color: #141414\"><div id=\"first\" style=\"page-break-after: always\">first page</div><div id=\"filler\">" ++ filler ++
            "</div><div id=\"kept\" style=\"page-break-inside: avoid; background: #e2e8f0; padding: 8px\"><p style=\"margin: 0\">kept together</p><p style=\"margin: 0\">across the break</p><p style=\"margin: 0\">by page-break-inside</p></div></div>";
        const d = try open(.html, src, 300, 160, 20);
        defer d.deinit();
        _ = try checkLines(d);
        try T.expectEqual(@as(usize, 3), d.count());
        try T.expectEqual(@as(u32, 0), try pageOfId(d, "first"));
        try T.expectEqual(@as(u32, 1), try pageOfId(d, "filler"));
        // the avoiding box moved whole to the third page
        const kept = try nodeOfId(d, "kept");
        const kt = absTop(&d.f, kept.lid);
        try T.expectEqual(@as(u32, 2), d.pages.pageAt(kt + 0.01));
        try T.expect(d.pages.boxOnPage(2, kt, d.f.tree.layout(kept.lid).h).?.to_next == false);
    }
    {
        // sided-avoid-page-breaks.pdf: 3 pages
        const src = "<div style=\"font-size: 12px; color: #141414\"><div>first page</div><div id=\"filler\" style=\"break-before: recto\">" ++ filler ++
            "</div><div id=\"kept\" style=\"break-inside: avoid-page; background: #e2e8f0; padding: 8px\"><p style=\"margin: 0\">kept together</p><p style=\"margin: 0\">across the break</p><p style=\"margin: 0\">by avoid-page</p></div></div>";
        const d = try open(.html, src, 300, 160, 20);
        defer d.deinit();
        try T.expectEqual(@as(usize, 3), d.count());
        try T.expectEqual(@as(u32, 1), try pageOfId(d, "filler"));
        try T.expectEqual(@as(u32, 2), try pageOfId(d, "kept"));
    }
    {
        // avoid-break-out-of-flow-overflow.pdf: 2 pages (the avoiding box stays, the badge goes on)
        const src = "<div style=\"font-size: 12px; color: #141414\"><p style=\"margin: 0\">line 1</p><p style=\"margin: 0\">line 2</p><p style=\"margin: 0\">line 3</p><p style=\"margin: 0\">line 4</p><p style=\"margin: 0\">line 5</p>" ++
            "<div id=\"kept\" style=\"position: relative; break-inside: avoid; background: #e2e8f0; padding: 8px\">kept on the first page<div style=\"position: absolute; left: 0; bottom: -40px; color: #b91c1c\">badge</div></div></div>";
        const d = try open(.html, src, 300, 160, 20);
        defer d.deinit();
        try T.expectEqual(@as(usize, 2), d.count());
        try T.expectEqual(@as(u32, 0), try pageOfId(d, "kept"));
    }
    {
        // break-after-with-running-absolute.pdf: 2 pages
        const src = "<div style=\"font-size: 12px; color: #141414\"><div style=\"height: 80px\">before the box</div><div style=\"position: relative; break-after: page; background: #e2e8f0\">the box" ++
            "<div style=\"position: absolute; top: 110px; background: #fca5a5\">absolute, next page</div></div><div id=\"fl\" style=\"float: left; background: #93c5fd\">float after the box, next page</div></div>";
        const d = try open(.html, src, 300, 160, 10);
        defer d.deinit();
        try T.expectEqual(@as(usize, 2), d.count());
        try T.expectEqual(@as(u32, 1), try pageOfId(d, "fl"));
    }
}

test "paged: an image that does not fit moves to the next page whole" {
    if (!enabled) return error.SkipZigTest;
    // img-without-source-past-page.pdf: 2 pages
    const src = "<div style=\"font-size: 12px; color: #141414\"><div style=\"height: 60px\">before the image</div>" ++
        "<img id=\"img\" width=\"120\" height=\"110\" style=\"display: block; background: #93c5fd\"><div id=\"after\">after the image</div></div>";
    const d = try open(.html, src, 300, 160, 10);
    defer d.deinit();
    try T.expectEqual(@as(usize, 2), d.count());
    const img = try nodeOfId(d, "img");
    try T.expectEqual(rt.Kind.image, img.kind);
    const t = absTop(&d.f, img.lid);
    try T.expectApproxEqAbs(d.pages.pages[1].top, t, 0.01);
    try T.expectEqual(@as(u32, 1), try pageOfId(d, "after"));
}

test "paged: flex rows and columns (takumi fixtures)" {
    if (!enabled) return error.SkipZigTest;
    const Case = struct { src: []const u8, pages: usize, id: []const u8, page: u32 };
    const cases = [_]Case{
        // flex-item-margin-past-page.pdf
        .{ .src = "<div style=\"font-size: 12px; color: #141414\"><div style=\"height: 40px\">before the row</div><div id=\"row\" style=\"display: flex; gap: 8px; background: #e2e8f0\">" ++
            "<div style=\"height: 80px; margin-bottom: 30px; background: #93c5fd\">item</div><div style=\"height: 50px; background: #fca5a5\">short item</div></div></div>", .pages = 2, .id = "row", .page = 1 },
        // flex-item-child-break-after.pdf
        .{ .src = "<div style=\"font-size: 12px; color: #141414\"><div style=\"display: flex; gap: 8px\"><div style=\"background: #e2e8f0\"><div>first item</div>" ++
            "<div style=\"break-after: page\">ends with a forced break</div></div><div style=\"background: #fde68a\">second item</div></div><div id=\"after\">after the row, on the next page</div></div>", .pages = 2, .id = "after", .page = 1 },
        // flex-item-table-row-break-after.pdf
        .{ .src = "<div style=\"font-size: 12px; color: #141414\"><div style=\"display: flex\"><table style=\"border-collapse: collapse\"><tr><td style=\"background: #e2e8f0\">first row</td></tr>" ++
            "<tr style=\"break-after: page\"><td style=\"background: #fde68a\">last row</td></tr></table></div><div id=\"after\">after the table, on the next page</div></div>", .pages = 2, .id = "after", .page = 1 },
        // floated-flex-item-break-after.pdf (a flex column)
        .{ .src = "<div style=\"font-size: 12px; color: #141414\"><div style=\"display: flex; flex-direction: column; background: #e2e8f0\">" ++
            "<div style=\"float: left; width: 120px; background: #93c5fd; break-after: page\">floated item</div><div id=\"next\" style=\"background: #fde68a\">next item, on the next page</div></div></div>", .pages = 2, .id = "next", .page = 1 },
    };
    for (cases) |c| {
        const d = try open(.html, c.src, 300, 160, 10);
        defer d.deinit();
        T.expectEqual(c.pages, d.count()) catch |e| {
            std.debug.print("case {s}\n", .{c.src[0..80]});
            return e;
        };
        try T.expectEqual(c.page, try pageOfId(d, c.id));
    }
}

test "paged: a flex column of text lines (paged-lines.pdf: 3 pages)" {
    if (!enabled) return error.SkipZigTest;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(T.allocator);
    try buf.appendSlice(T.allocator, "{\"type\":\"container\",\"style\":{\"display\":\"flex\",\"flexDirection\":\"column\",\"width\":\"100%\"},\"children\":[");
    for (1..41) |i| {
        if (i > 1) try buf.append(T.allocator, ',');
        try buf.print(T.allocator, "{{\"type\":\"text\",\"text\":\"Line {d} of the paginated report body\",\"style\":{{\"color\":\"#141414\",\"fontSize\":16}}}}", .{i});
    }
    try buf.appendSlice(T.allocator, "]}");
    const d = try open(.json, buf.items, 400, 300, 24);
    defer d.deinit();
    const st = try checkLines(d);
    try T.expectEqual(@as(u32, 40), st.lines);
    try T.expectEqual(@as(usize, 3), d.count());
}

fn tableSrc(a: std.mem.Allocator, thead_style: []const u8, rows: u32) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a, "<table style=\"width: 100%; font-size: 12px; color: #141414\"><thead id=\"head\"{s}><tr style=\"background: #e2e8f0\"><th>Name</th><th>Qty</th></tr></thead><tbody>", .{thead_style});
    for (1..rows + 1) |i| try buf.print(a, "<tr><td>Item {d}</td><td>{d}</td></tr>", .{ i, i * 3 });
    try buf.appendSlice(a, "</tbody></table>");
    return buf.items;
}

test "paged: a long table repeats its header group on every continuation page" {
    if (!enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const d = try open(.html, try tableSrc(arena.allocator(), "", 30), 400, 300, 24);
    defer d.deinit();
    const n = d.count();
    try T.expect(n > 1);
    _ = try checkLines(d);
    const head = try nodeOfId(d, "head");
    var reps: usize = 0;
    for (d.pages.repeats) |r| {
        if (r.node == head.lid) {
            reps += 1;
            const o = d.f.repeatOrigin(r);
            try T.expect(o.id == d.f.nodeId(head));
            // the repeated header sits at the top of its page
            const l = d.f.tree.layout(head.lid);
            try T.expectApproxEqAbs(d.pages.pages[r.page].top, o.oy + l.y, 0.5);
        }
    }
    try T.expectEqual(n - 1, reps);
    // every row is below the header of its page
    // (a `table-row-group` header is not a header group: nothing repeats)
    const plain = try open(.html, try tableSrc(arena.allocator(), " style=\"display: table-row-group\"", 30), 400, 300, 24);
    defer plain.deinit();
    try T.expectEqual(@as(usize, 0), plain.pages.repeats.len);

    // painted through the raster painter: page 2 starts with the header's background (sampled right of
    // the short texts)
    var pm = try d.f.paintPageRaster(1);
    const at: usize = 4 * pm.width + pm.width - 6;
    const px = pm.data[at * 4 ..][0..4];
    try T.expect(px[3] == 255 and px[0] == 0xe2 and px[1] == 0xe8 and px[2] == 0xf0);
    pm = try plain.f.paintPageRaster(1);
    try T.expect(pm.data[at * 4 + 3] == 0);
}

/// A table of `rows` body rows (ids `r1`..; rows `tall` hold two lines) beside a short item (`b`) in a
/// flex row container (`c`) styled `flex_style`, a block (`after`) below.
fn stretchSrc(a: std.mem.Allocator, flex_style: []const u8, rows: u32, tall: []const u32) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a, "<html><body style=\"margin: 0\"><div id=\"c\" style=\"display: flex; font-size: 12px; {s}\"><table id=\"t\" style=\"width: 280px\"><thead><tr><th>Name</th><th>Qty</th></tr></thead><tbody>", .{flex_style});
    for (1..rows + 1) |i| {
        const two = std.mem.indexOfScalar(u32, tall, @intCast(i)) != null;
        try buf.print(a, "<tr id=\"r{d}\"><td>Item {d}{s}</td><td>{d}</td></tr>", .{ i, i, if (two) "<br>x" else "", i * 3 });
    }
    try buf.appendSlice(a, "</tbody></table><div id=\"b\">Beside</div></div><div id=\"after\">After</div></body></html>");
    return buf.items;
}

/// Laid out once at `width` px for the raster / SVG output: not paged.
fn openFlat(src: []const u8, width: u32) !*Doc {
    const r = try newRenderer();
    errdefer r.destroy();
    r.beginCall();
    const a = r.arena.allocator();
    const d = try a.create(Doc);
    d.r = r;
    d.f = .{ .r = r, .a = a, .opts = .{ .width = width }, .tree = rt.LTree.init(a), .ctx = undefined };
    try d.f.prepare(.html, src);
    d.pages = undefined;
    return d;
}

fn rowH(d: *Doc, i: u32) !f32 {
    var buf: [8]u8 = undefined;
    return d.f.tree.layout((try nodeOfId(d, try std.fmt.bufPrint(&buf, "r{d}", .{i}))).lid).h;
}

test "paged: a table stretched in a flex row gives its last fragment's rows the line's growth (Blink / Chrome / takumi)" {
    if (!enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows: u32 = 30;
    const tall = [_]u32{ 27, 29 };
    // 400 x 300 pages, 24px margins (upstream.content_beside_a_table_does_not_replay_with_its_header):
    // the table breaks over three pages; its pushed rows and repeated headers make it end past the
    // line it was stretched to. The flex line grows there by that much, the table stretched to it
    // shares the larger block size among its body rows in proportion to their minimum block sizes
    // (Blink's DistributeTableBlockSizeToSections), and the rows of its last fragment show it.
    const st = try open(.html, try stretchSrc(a, "", rows, &tall), 400, 300, 24);
    defer st.deinit();
    const start = try open(.html, try stretchSrc(a, "align-items: start", rows, &tall), 400, 300, 24);
    defer start.deinit();
    const flat = try openFlat(try stretchSrc(a, "", rows, &tall), 352);
    defer flat.deinit();
    try T.expectEqual(@as(usize, 3), st.count());
    try T.expectEqual(@as(usize, 3), start.count());
    const last_page: u32 = 2;
    const t_st = (try nodeOfId(st, "t")).lid;
    const t_top = absTop(&st.f, t_st);
    // unpaged, the rows keep their minimum block sizes: the table is as tall as the line
    const b0 = flat.f.tree.layout((try nodeOfId(flat, "t")).lid).h;
    var min_sum: f32 = 0;
    var growth: f32 = 0;
    var last_min: f32 = 0;
    var i: u32 = 1;
    while (i <= rows) : (i += 1) {
        const h0 = try rowH(flat, i);
        try T.expectApproxEqAbs(h0, try rowH(start, i), 0.001);
        min_sum += h0;
        const lid = (try nodeOfId(st, try std.fmt.allocPrint(a, "r{d}", .{i}))).lid;
        const on_last = st.pages.pageAt(absTop(&st.f, lid) + 0.01) == last_page;
        const h = try rowH(st, i);
        if (!on_last) {
            // the rows of the earlier fragments keep their block sizes
            try T.expectApproxEqAbs(h0, h, 0.001);
        } else {
            try T.expect(h > h0 + 0.5);
            growth += h - h0;
            last_min += h0;
        }
    }
    try T.expectApproxEqAbs(b0, flat.f.tree.layout((try nodeOfId(flat, "c")).lid).h, 0.001);
    // in proportion: the two-line rows grow by twice as much (and a bit) as the one-line rows
    // (row 30, the last, also takes what the 1/64 px rounding of the shares leaves)
    const g_one = try rowH(st, 28) - try rowH(flat, 28);
    const g_two = try rowH(st, 29) - try rowH(flat, 29);
    try T.expectApproxEqAbs((try rowH(flat, 29)) / (try rowH(flat, 28)), g_two / g_one, 0.02);
    // the line grew by what the table reached past it, X = its end before the rows grew less the
    // line's end; every body row took its share of X
    const t_end = t_top + st.f.tree.layout(t_st).h;
    const x = (t_end - growth) - (t_top + b0);
    try T.expect(x > 1);
    try T.expectApproxEqAbs(x * last_min / min_sum, growth, @as(f32, @floatFromInt(rows)) / 64);
    // the other item reaches the grown line's end, the container and what follows the table's
    const b = (try nodeOfId(st, "b")).lid;
    try T.expectApproxEqAbs(t_end - growth, absTop(&st.f, b) + st.f.tree.layout(b).h, 0.02);
    const c = (try nodeOfId(st, "c")).lid;
    try T.expectApproxEqAbs(t_end, absTop(&st.f, c) + st.f.tree.layout(c).h, 0.02);
    try T.expectApproxEqAbs(t_end, absTop(&st.f, (try nodeOfId(st, "after")).lid), 0.02);

    // a column flex container does not stretch the table in the block axis: nothing grows
    const col = try open(.html, try stretchSrc(a, "flex-direction: column", rows, &tall), 400, 300, 24);
    defer col.deinit();
    i = 1;
    while (i <= rows) : (i += 1) try T.expectApproxEqAbs(try rowH(flat, i), try rowH(col, i), 0.001);
}

test "paged: a flex row shrinks with an item whose truncated margin moved it up (align-items: flex-start)" {
    if (!enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    // page area 280px: B (after a 23px margin) starts at 293 and moves to page 2, the 13px of its margin
    // past the page end truncated. The row ends with B, so "end" follows B by its 20px line and the
    // 10px block, whatever the spacer (oracle: Chromium, takumi); before, the row kept its unbroken
    // height and "end" sat lower by the truncated part of the margin.
    for ([_]u32{ 250, 254 }) |spacer| {
        const src = try std.fmt.allocPrint(arena.allocator(), "<html><body style=\"margin: 0; font-size: 16px; line-height: 20px\"><div style=\"height: {d}px\"></div><div style=\"display: flex; align-items: flex-start\"><div style=\"width: 50%\"><div>A</div><div id=\"b\" style=\"margin-top: 23px\">B</div></div><div style=\"width: 50%\"><div>C</div></div></div><div style=\"height: 10px\"></div><div id=\"end\">E</div></body></html>", .{spacer});
        const d = try open(.html, src, 300, 300, 10);
        defer d.deinit();
        try T.expectEqual(@as(u32, 1), try pageOfId(d, "b"));
        const b = try nodeOfId(d, "b");
        const end = try nodeOfId(d, "end");
        try T.expectApproxEqAbs(@as(f32, 30), absTop(&d.f, end.lid) - absTop(&d.f, b.lid), 0.01);
    }
}

test "paged: a flex row starting with an empty item moves whole, keeping its min-height" {
    if (!enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    // page area 280px: the row starts at 265, its text line does not fit. The empty first item is no
    // content of its own: the row moves to page 2 whole (not split after the empty item with part of
    // its min-height spent on page 1), "end" follows it by the full 40px (oracle: Chromium, takumi)
    const src = "<html><body style=\"margin: 0; font-size: 16px; line-height: 20px\"><div style=\"height: 265px\"></div><div style=\"display: flex; align-items: flex-start; min-height: 40px\"><div style=\"width: 20%\"></div><div style=\"width: 60%\"><div id=\"a\" style=\"white-space: nowrap; overflow: hidden\">A</div></div><div style=\"width: 20%\"></div></div><div id=\"end\">E</div></body></html>";
    const d = try open(.html, src, 300, 300, 10);
    defer d.deinit();
    try T.expectEqual(@as(u32, 1), try pageOfId(d, "a"));
    const a = try nodeOfId(d, "a");
    const end = try nodeOfId(d, "end");
    try T.expectApproxEqAbs(@as(f32, 40), absTop(&d.f, end.lid) - absTop(&d.f, a.lid), 0.01);
}

test "paged: a table with a repeated header lets its block-end border overflow the page (takumi / Blink)" {
    if (!enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    // collapsed 4px borders: the table's rows end 2px (half the bottom edge) above its border box. The
    // last table box of a table with a repeated header does not break before its block-end decorations
    // (takumi `relayout_as_last_table_box`, Blink's FinishFragmentation): its row moves to page 2 only
    // once the rows themselves no longer fit, 2px later than with a header that does not repeat
    // (`table-row-group`), whose block-end border has to fit
    var first_moved: [2]u32 = .{ 0, 0 };
    for ([_][]const u8{ "", " style=\"display: table-row-group\"" }, 0..) |head, v| {
        var spacer: u32 = 40;
        while (spacer <= 70) : (spacer += 1) {
            const src = try std.fmt.allocPrint(arena.allocator(), "<html><body style=\"margin: 0\"><div style=\"height: {d}px\"></div><table style=\"border-collapse: collapse; width: 100%\"><thead{s}><tr><th style=\"border: 4px solid #000; height: 20px; padding: 0\">h</th></tr></thead><tbody><tr style=\"break-inside: avoid\"><td id=\"row\" style=\"border: 4px solid #000; height: 200px; padding: 0\">a</td></tr></tbody></table></body></html>", .{ spacer, head });
            const d = try open(.html, src, 300, 300, 10);
            defer d.deinit();
            if (try pageOfId(d, "row") == 1) break;
        }
        first_moved[v] = spacer;
    }
    try T.expect(first_moved[1] > 40 and first_moved[0] <= 70);
    try T.expectEqual(first_moved[1] + 2, first_moved[0]);
}

test "paged: paged-table.pdf (thead / tfoot reordered, 3 pages)" {
    if (!enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "<table style=\"width: 100%; font-size: 12px; color: #141414\"><tfoot><tr><td colspan=\"2\">Total</td><td>1395</td></tr></tfoot><tbody>");
    for (1..31) |i| try buf.print(a, "<tr><td>Item {d}</td><td>Description of item {d}</td><td>{d}</td></tr>", .{ i, i, i * 3 });
    try buf.appendSlice(a, "</tbody><thead><tr style=\"background: #e2e8f0\"><th>Name</th><th>Description</th><th style=\"width: 48px\">Qty</th></tr></thead></table>");
    const d = try open(.html, buf.items, 400, 300, 24);
    defer d.deinit();
    _ = try checkLines(d);
    try T.expectEqual(@as(usize, 3), d.count());
}

test "paged: vh, percentages and fixed boxes resolve against the page area" {
    if (!enabled) return error.SkipZigTest;
    const src = "<div id=\"root\" style=\"font-size: 12px; height: 100%\"><div id=\"vh\" style=\"height: 50vh; width: 50vw; background: #e2e8f0\"></div>" ++
        "<div style=\"background: #fca5a5\">text</div>" ++
        "<div id=\"fixed\" style=\"position: fixed; bottom: 0; left: 0; height: 10px; width: 10px; background: #2563eb\"></div>" ++
        "<div style=\"height: 400px\"></div></div>";
    const d = try open(.html, src, 300, 200, 20);
    defer d.deinit();
    const vh = d.f.tree.layout((try nodeOfId(d, "vh")).lid);
    try T.expectApproxEqAbs(@as(f32, 80), vh.h, 0.02);
    try T.expectApproxEqAbs(@as(f32, 130), vh.w, 0.02);
    // the root's `height: 100%` has no definite page-height to resolve against: auto (takumi's
    // `fill_root` column), so the root holds all of its content
    const root = d.f.tree.layout((try nodeOfId(d, "root")).lid);
    try T.expect(root.h > 480);
    // a fixed box: at the bottom of the first page area, repeated on every other page
    const fx = try nodeOfId(d, "fixed");
    try T.expectApproxEqAbs(@as(f32, 150), absTop(&d.f, fx.lid), 0.02);
    try T.expect(d.count() >= 3);
    var reps: usize = 0;
    for (d.pages.repeats) |r| reps += @intFromBool(r.node == fx.lid);
    try T.expectEqual(d.count() - 1, reps);
    const pm = try d.f.paintPageRaster(2);
    // (bottom-left corner of the page area)
    try T.expect(pm.data[((pm.height - 5) * pm.width + 5) * 4 + 3] == 255);
}

test "paged: lines moved to the next page are painted there" {
    if (!enabled) return error.SkipZigTest;
    const src = "<div style=\"font-size: 16px; line-height: 20px; color: #000\"><div style=\"height: 50px\"></div><p id=\"p\" style=\"margin: 0\">" ++ lorem ++ "</p></div>";
    const d = try open(.html, src, 300, 140, 20);
    defer d.deinit();
    // page area 100 px: lines 1-2 at 50..90 stay, line 3 (90..110) crosses the page end and moves 10 px
    _ = try checkLines(d);
    try T.expect(d.count() >= 2);
    var p_id: u32 = rt.none;
    for (d.f.nodes.items, 0..) |*n, i| if (n.para != null) {
        p_id = @intCast(i);
    };
    try T.expect(p_id != rt.none);
    try T.expectEqual(@as(f32, 0), d.f.lineDy(p_id, 1));
    try T.expectApproxEqAbs(@as(f32, 10), d.f.lineDy(p_id, 2), 0.02);
    const tl = d.f.nodes.items[p_id].tl.?;
    try T.expectApproxEqAbs(tl.lines[1].top + 30, tl.lines[2].top, 0.02);
    // painting page 2 draws the moved lines there
    const pm = try d.f.paintPageRaster(1);
    var ink: usize = 0;
    var k: usize = 3;
    while (k < pm.data.len) : (k += 4) ink += @intFromBool(pm.data[k] != 0);
    try T.expect(ink > 100);
}

// The takumi-pdf HTML fixtures at A4 (Chromium's default 10 mm margins, `PageOptions::A4`), and the
// invoice with takumi's invoice margins (36 px, the bottom as tall as the footer band). Prints the page
// counts; takumi's: invoice 2 (invoice.pdf, invoice margins), report 3 (report-*.pdf, A4),
// certificate 1 (certificate.pdf: a 1123 x 794 viewport, not paged).
test "paged: takumi-pdf HTML fixtures at A4" {
    if (!enabled) return error.SkipZigTest;
    const mm: f32 = 96.0 / 25.4;
    const a4_w = 210 * mm;
    const a4_h = 297 * mm;
    const m0 = 10 * mm;
    const dir = "tests/upstream/takumi/takumi-pdf/fixtures/";
    inline for (.{ "invoice", "report", "certificate" }) |name| {
        if (readFile(dir ++ name ++ ".html")) |src| {
            defer T.allocator.free(src);
            const d = try open(.html, src, a4_w, a4_h, m0);
            defer d.deinit();
            _ = try checkLines(d);
            std.debug.print("takumi-pdf fixture {s}.html at A4, 10 mm margins: {d} pages\n", .{ name, d.count() });
            if (comptime std.mem.eql(u8, name, "report")) try T.expectEqual(@as(usize, 3), d.count());
        } else return error.FileNotFound;
    }
    // invoice.pdf: 36 px margins, the bottom one = footer band height + 15 pt (>= 10 mm)
    const src = readFile(dir ++ "invoice.html") orelse return;
    defer T.allocator.free(src);
    const footer = readFile(dir ++ "invoice-footer.html") orelse return;
    defer T.allocator.free(footer);
    const band_h = blk: {
        const r = try newRenderer();
        defer r.destroy();
        r.beginCall();
        const a = r.arena.allocator();
        var f: rt.Frame = .{ .r = r, .a = a, .opts = .{ .width = @intFromFloat(a4_w) }, .tree = rt.LTree.init(a), .ctx = undefined };
        try f.prepare(.html, footer);
        break :blk f.tree.layout(f.nodes.items[f.root].lid).h;
    };
    const bottom = @max(band_h + 20, m0);
    const d = try openM(.html, src, a4_w, a4_h, .{ 36, 36, bottom, 36 });
    defer d.deinit();
    _ = try checkLines(d);
    std.debug.print("takumi-pdf fixture invoice.html, invoice margins (footer band {d:.2} px, bottom margin {d:.2}): {d} pages (takumi: 2)\n", .{ band_h, bottom, d.count() });
    try T.expectEqual(@as(usize, 2), d.count());
}
