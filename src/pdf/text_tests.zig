//! Tests of text.zig / font_objects.zig / type3.zig. The oracle is takumi-pdf's own output
//! (tests/upstream/takumi/takumi-pdf/tests/fixtures-generated/*.pdf, inputs in tests/pdf_fixtures.rs):
//! the same documents are laid out with bm-render (Renderer + Frame), their text drawn through
//! `drawFrameRun`, and the text operators / font objects compared. Tests that need files from
//! ref/ skip when they are missing. Set BM_PDF_TEXT_OUT to a directory to also write the PDFs
//! (for pdftotext checks).
const std = @import("std");
const testing = std.testing;
const w = @import("writer.zig");
const sf = @import("emit_surface.zig");
const geom = @import("emit_geom.zig");
const text = @import("text.zig");
const fo = @import("font_objects.zig");
const rt = @import("../render.zig");
const font = @import("../font/font.zig");
const config = @import("../config.zig");

const Allocator = std.mem.Allocator;

const archivo_vf = @embedFile("../font/testdata/Archivo-VF.ttf");

// ----------------------------------------------------------------------------- harness

const Doc = struct {
    pdf: []const u8,
    /// the page content stream (uncompressed)
    content: []const u8,
    issues: fo.FontIssues,
    uncovered: ?[]const u8,
};

/// The DOM text a paragraph node was built from (no text-transform, no generated content).
fn elText(f: *rt.Frame, a: Allocator, i: u32, out: *std.ArrayList(u8)) !void {
    const el = f.dom.at(i);
    if (el.cs.display == .none) return;
    if (el.kind == .text) return out.appendSlice(a, el.text);
    var c = el.first;
    while (c != @import("../dom.zig").none) : (c = f.dom.at(c).next) try elText(f, a, c, out);
}

fn paraText(f: *rt.Frame, a: Allocator, id: u32) ![]const u8 {
    const n = &f.nodes.items[id];
    var out: std.ArrayList(u8) = .empty;
    if (n.el != rt.none) {
        try elText(f, a, n.el, &out);
    } else if (n.parent != rt.none and f.nodes.items[n.parent].el != rt.none) {
        try elText(f, a, f.nodes.items[n.parent].el, &out);
    }
    return out.items;
}

fn walk(reg: *text.FontRegistry, s: *sf.Surface, f: *rt.Frame, a: Allocator, id: u32, ox: f32, oy: f32, pass_shadows: bool) !void {
    const n = &f.nodes.items[id];
    if (n.kind != .anon_text and n.cs.display == .none) return;
    const l = f.tree.layout(n.lid);
    const x = ox + l.x;
    const y = oy + l.y;
    if (n.para != null) {
        const cx = x + l.border.left + l.padding.left;
        const cy = y + l.border.top + l.padding.top;
        const cw = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
        if (try f.textLayout(id, cw)) |tl| {
            const t = try paraText(f, a, id);
            if (pass_shadows) {
                const cs = n.cs;
                var k = cs.text_shadow.len;
                while (k > 0) {
                    k -= 1;
                    var it: rt.RunIter = .{ .tl = tl };
                    while (it.next()) |r| try text.drawFrameRun(reg, s, f, n, tl, r, .{ cx, cy }, t, .{ .shadow = text.textShadow(cs, k) }, .{});
                }
            }
            var it: rt.RunIter = .{ .tl = tl };
            while (it.next()) |r| try text.drawFrameRun(reg, s, f, n, tl, r, .{ cx, cy }, t, .text, .{});
        }
    }
    var c = n.first_child;
    while (c != rt.none) : (c = f.nodes.items[c].next) try walk(reg, s, f, a, c, x, y, pass_shadows);
}

const Font = struct { data: []const u8 };

/// Lays out `source` (HTML or JSON) at `vw` x `vh` px with `fonts` and writes a one-page PDF
/// (uncompressed) holding its text, the way takumi-pdf would place it.
fn renderDoc(a: Allocator, fonts: []const []const u8, kind: rt.SourceKind, source: []const u8, vw: u32, vh: u32, shadows: bool, policy: fo.Uncovered.Policy) !Doc {
    // (the PDF profile is full + pdf: WOFF, colour fonts and complex text are all there)
    if (comptime !config.enable_pdf) return error.SkipZigTest;
    const r = rt.Renderer.create(testing.allocator) orelse return error.OutOfMemory;
    defer r.destroy();
    for (fonts) |data| {
        const copy = try testing.allocator.dupe(u8, data);
        _ = try r.registerFont(copy, "", 0, -1, null);
    }
    r.arena.reset();
    const fa = r.arena.allocator();
    var f: rt.Frame = .{ .r = r, .a = fa, .opts = .{ .width = vw, .height = vh }, .tree = rt.LTree.init(fa), .ctx = undefined };
    try f.prepare(kind, source);

    var doc = w.Doc.init(a, .{ .compress = false });
    var cx: sf.Ctx = .{ .a = a, .doc = &doc };
    var reg = text.FontRegistry.init(a, policy);
    const h_pt = @as(f32, @floatFromInt(vh)) * 0.75;
    var s = sf.Surface.initPage(&cx, h_pt);
    s.pushTransform(geom.Tf.scale(0.75, 0.75));
    try walk(&reg, &s, &f, a, f.root, 0, 0, shadows);
    s.pop();
    const st = s.finish();
    const issues = try reg.flush(&cx);
    const unc = try reg.uncoveredError();
    const page = doc.addPage();
    const contents = doc.alloc();
    const res = st.res.write(&doc);
    _ = doc.beginPage(page, .{ .resources = res, .media_box = .{ 0, 0, @as(f32, @floatFromInt(vw)) * 0.75, h_pt }, .contents = contents });
    doc.endDict();
    doc.contentStream(contents, st.content);
    var out: std.ArrayList(u8) = .empty;
    try doc.finish(&out, .{});
    // copy the content: it lives in the surface builder's buffer (arena `a`)
    return .{ .pdf = out.items, .content = st.content, .issues = issues, .uncovered = unc };
}

fn maybeWrite(name: []const u8, pdf: []const u8) void {
    const dir = testing.environ.getAlloc(testing.allocator, "BM_PDF_TEXT_OUT") catch return;
    defer testing.allocator.free(dir);
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}.pdf", .{ dir, name }) catch return;
    std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = pdf }) catch {};
}

/// The BT..ET blocks of a content stream with the `q`..colour prefix of each (for comparing
/// with a fixture: tagging / backgrounds are the emitter's).
fn textBlocks(a: Allocator, content: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, content, i, "BT")) |bt| {
        if (bt > 0 and content[bt - 1] != '\n' and content[bt - 1] != ' ') {
            i = bt + 2;
            continue;
        }
        const et = std.mem.indexOfPos(u8, content, bt, "\nET") orelse break;
        const q = std.mem.lastIndexOf(u8, content[0..bt], "q ") orelse bt;
        try out.appendSlice(a, content[q .. et + 3]);
        try out.append(a, '\n');
        i = et + 3;
    }
    return out.items;
}

// ----------------------------------------------------------------------------- fixtures

/// Reads a file of the vendored corpus (relative to the repository root, the test's cwd), or
/// null when it is not there.
fn readRef(a: Allocator, rel: []const u8) ?[]u8 {
    var buf: [512]u8 = undefined;
    for ([_][]const u8{ "tests/upstream/takumi/", "../tests/upstream/takumi/" }) |pre| {
        const p = std.fmt.bufPrint(&buf, "{s}{s}", .{ pre, rel }) catch return null;
        return std.Io.Dir.cwd().readFileAlloc(testing.io, p, a, .limited(64 << 20)) catch continue;
    }
    return null;
}

const Fixture = struct {
    name: []const u8,
    fonts: []const []const u8,
    kind: rt.SourceKind = .html,
    source: []const u8,
    w: u32,
    h: u32,
    shadows: bool = true,
    /// fixture file name when it differs from `name`
    ref: ?[]const u8 = null,
};

/// The family name the takumi fixtures interpolate (first registered face of a file).
fn familyOf(data: []const u8) []const u8 {
    const f = font.ttf.Font.init(data, 0) catch return "";
    var buf: [128]u8 = undefined;
    const n = f.familyName(&buf);
    return std.heap.page_allocator.dupe(u8, n) catch "";
}

// ---- reading PDFs (ours uncompressed, takumi's Flate-compressed)

const inflate = @import("../codec/inflate.zig");

/// Print every differing text object / font dict (debugging).
const verbose = false;

const PdfObj = struct { num: u32, dict: []const u8, data: ?[]const u8 };

/// The indirect objects of a PDF (object streams and the xref stream are skipped), streams
/// inflated.
fn pdfObjects(a: Allocator, pdf: []const u8) ![]PdfObj {
    var out: std.ArrayList(PdfObj) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, pdf, i, " 0 obj\n")) |p| {
        var s = p;
        while (s > 0 and std.ascii.isDigit(pdf[s - 1])) s -= 1;
        const num = std.fmt.parseInt(u32, pdf[s..p], 10) catch 0;
        const body_start = p + " 0 obj\n".len;
        const end = std.mem.indexOfPos(u8, pdf, body_start, "endobj") orelse break;
        const body = pdf[body_start..end];
        i = end;
        if (std.mem.indexOf(u8, body, "stream\n")) |si| {
            const dict = body[0..si];
            const lk = std.mem.indexOf(u8, dict, "/Length ") orelse continue;
            var le = lk + 8;
            while (le < dict.len and std.ascii.isDigit(dict[le])) le += 1;
            const len = try std.fmt.parseInt(usize, dict[lk + 8 .. le], 10);
            const raw = pdf[body_start + si + 7 ..][0..len];
            if (std.mem.indexOf(u8, dict, "/ObjStm") != null or std.mem.indexOf(u8, dict, "/XRef") != null) continue;
            const data = if (std.mem.indexOf(u8, dict, "/FlateDecode") != null) try inflate.zlibDecompressAlloc(a, raw, 64 << 20, .{}) else raw;
            try out.append(a, .{ .num = num, .dict = dict, .data = data });
        } else try out.append(a, .{ .num = num, .dict = std.mem.trim(u8, body, " \n"), .data = null });
    }
    return out.items;
}

fn objByNum(objs: []const PdfObj, n: u32) ?PdfObj {
    for (objs) |o| if (o.num == n) return o;
    return null;
}

/// The page content streams (in page-object order) joined.
fn pageContent(a: Allocator, objs: []const PdfObj) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (objs) |o| {
        if (std.mem.indexOf(u8, o.dict, "/Type/Page/") == null) continue;
        const k = std.mem.indexOf(u8, o.dict, "/Contents ") orelse continue;
        var e = k + 10;
        while (e < o.dict.len and std.ascii.isDigit(o.dict[e])) e += 1;
        const c = objByNum(objs, try std.fmt.parseInt(u32, o.dict[k + 10 .. e], 10)) orelse continue;
        try out.appendSlice(a, c.data orelse "");
        try out.append(a, '\n');
    }
    return out.items;
}

/// `dict` with every `N 0 R` written as `R`, /Length and /Filter dropped.
fn normDict(a: Allocator, dict: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < dict.len) {
        if (std.mem.startsWith(u8, dict[i..], "/Filter/FlateDecode")) {
            i += "/Filter/FlateDecode".len;
            continue;
        }
        if (std.mem.startsWith(u8, dict[i..], "/Length ")) {
            i += 8;
            while (i < dict.len and std.ascii.isDigit(dict[i])) i += 1;
            continue;
        }
        if (std.ascii.isDigit(dict[i]) and (i == 0 or !std.ascii.isDigit(dict[i - 1]) and dict[i - 1] != '.')) {
            var e = i;
            while (e < dict.len and std.ascii.isDigit(dict[e])) e += 1;
            if (std.mem.startsWith(u8, dict[e..], " 0 R")) {
                try out.append(a, 'R');
                i = e + 4;
                continue;
            }
        }
        try out.append(a, dict[i]);
        i += 1;
    }
    return out.items;
}

const FontCmp = struct { dicts: u32 = 0, dict_diffs: u32 = 0, stream_diffs: u32 = 0 };

/// Compares the font objects (dicts, ToUnicode CMaps, font programs, Type3 glyph procedures) of
/// two PDFs in order of appearance.
fn compareFonts(a: Allocator, ours: []const PdfObj, ref: []const PdfObj) !FontCmp {
    var fa: std.ArrayList(PdfObj) = .empty;
    var fb: std.ArrayList(PdfObj) = .empty;
    for (ours) |o| if (std.mem.startsWith(u8, std.mem.trimStart(u8, o.dict, "<"), "/Type/Font")) try fa.append(a, o);
    for (ref) |o| if (std.mem.startsWith(u8, std.mem.trimStart(u8, o.dict, "<"), "/Type/Font")) try fb.append(a, o);
    var r: FontCmp = .{ .dicts = @intCast(fb.items.len) };
    if (fa.items.len != fb.items.len) r.dict_diffs += 1;
    for (fa.items[0..@min(fa.items.len, fb.items.len)], fb.items[0..@min(fa.items.len, fb.items.len)]) |x, y| {
        if (!std.mem.eql(u8, try normDict(a, x.dict), try normDict(a, y.dict))) {
            r.dict_diffs += 1;
            if (verbose) std.debug.print("font dict differs:\n  ours {s}\n  ref  {s}\n", .{ x.dict, y.dict });
        }
        for ([_][]const u8{ "/ToUnicode ", "/FontFile2 ", "/FontFile3 " }) |key| {
            const sx = streamOf(ours, x.dict, key) orelse continue;
            const sy = streamOf(ref, y.dict, key) orelse continue;
            if (!std.mem.eql(u8, sx, sy)) r.stream_diffs += 1;
        }
    }
    return r;
}

fn streamOf(objs: []const PdfObj, dict: []const u8, key: []const u8) ?[]const u8 {
    const k = std.mem.indexOf(u8, dict, key) orelse return null;
    var e = k + key.len;
    while (e < dict.len and std.ascii.isDigit(dict[e])) e += 1;
    const n = std.fmt.parseInt(u32, dict[k + key.len .. e], 10) catch return null;
    return (objByNum(objs, n) orelse return null).data;
}

/// The text objects of a content stream, from `BT` to `ET` (the fill set-up before them is the
/// emitter's: colour spaces differ under PDF/A).
fn btBlocks(a: Allocator, content: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, content, i, "BT")) |bt| {
        if (bt > 0 and content[bt - 1] != '\n' and content[bt - 1] != ' ') {
            i = bt + 2;
            continue;
        }
        const et = std.mem.indexOfPos(u8, content, bt, "\nET") orelse break;
        try out.append(a, content[bt .. et + 3]);
        i = et + 3;
    }
    return out.items;
}

const FixtureResult = struct { blocks: usize, same_blocks: usize, ref_blocks: usize, fonts: FontCmp };

fn runFixture(fx: Fixture) !FixtureResult {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var datas: std.ArrayList([]const u8) = .empty;
    for (fx.fonts) |p| try datas.append(a, readRef(a, p) orelse return error.FileNotFound);
    const d = try renderDoc(a, datas.items, fx.kind, fx.source, fx.w, fx.h, fx.shadows, .@"error");
    maybeWrite(fx.name, d.pdf);
    try testing.expect(d.uncovered == null);
    var path_buf: [256]u8 = undefined;
    const ref_pdf = readRef(a, try std.fmt.bufPrint(&path_buf, "takumi-pdf/tests/fixtures-generated/{s}.pdf", .{fx.ref orelse fx.name})) orelse return error.FileNotFound;
    const ours = try pdfObjects(a, d.pdf);
    const ref = try pdfObjects(a, ref_pdf);
    const ba = try btBlocks(a, try pageContent(a, ours));
    const bb = try btBlocks(a, try pageContent(a, ref));
    var same: usize = 0;
    for (ba, 0..) |x, i| {
        if (i < bb.len and std.mem.eql(u8, x, bb[i])) same += 1 else if (i < bb.len and verbose) std.debug.print("{s} text object {d} differs:\n  ours {s}\n  ref  {s}\n", .{ fx.name, i, x, bb[i] });
    }
    return .{ .blocks = ba.len, .same_blocks = same, .ref_blocks = bb.len, .fonts = try compareFonts(a, ours, ref) };
}

fn expectFixture(r: FixtureResult, missing_blocks: usize, program_diffs: u32) !void {
    try testing.expectEqual(r.blocks, r.same_blocks);
    try testing.expectEqual(r.ref_blocks, r.blocks + missing_blocks);
    try testing.expectEqual(@as(u32, 0), r.fonts.dict_diffs);
    try testing.expectEqual(program_diffs, r.fonts.stream_diffs);
}

const archivo_path = "assets/fonts/archivo/Archivo-VariableFont_wdth,wght.ttf";
const notosc_path = "assets/fonts/noto-sans/NotoSansTC-VariableFont_wght.woff2";

test "pdf text fixture: text-ligatures" {
    try expectFixture(try runFixture(.{
        .name = "text-ligatures",
        .fonts = &.{ archivo_path, notosc_path },
        .kind = .json,
        .source = "{\"type\":\"container\",\"style\":{\"display\":\"flex\",\"width\":\"100%\",\"height\":\"100%\"},\"children\":[{\"type\":\"text\",\"text\":\"Difficult office traffic affix\",\"style\":{\"color\":\"rgb(20,20,20)\",\"fontSize\":24}}]}",
        .w = 600,
        .h = 100,
    }), 0, 0);
}

test "pdf text fixture: cluster-closing-on-a-mark" {
    try expectFixture(try runFixture(.{
        .name = "cluster-closing-on-a-mark",
        .fonts = &.{"takumi-pdf/tests/fonts/archivo-combining.subset.ttf"},
        .source = "<p style=\"font-size:16px;\">\u{015A}winouj\u{015B}cie</p>",
        .w = 240,
        .h = 48,
    }), 0, 0);
}

test "pdf text fixture: text-shadow-stroke" {
    const r = try runFixture(.{
        .name = "text-shadow-stroke",
        .fonts = &.{ archivo_path, notosc_path },
        .source =
        \\<div style="display: flex; flex-direction: column; row-gap: 8px; width: 100%; height: 100%; padding: 16px; background-color: #ffffff; font-size: 28px; color: #111827;">
        \\      <div style="text-shadow: 3px 3px 0 #f59e0b;">Sharp shadow</div>
        \\      <div style="text-shadow: 2px 2px 4px rgba(17, 24, 39, 0.5);">Blurred shadow</div>
        \\      <div style="-webkit-text-stroke: 1px #b91c1c; color: #fef3c7;">Stroked text</div>
        \\      <div style="-webkit-text-stroke: 2px rgba(185, 28, 28, 0.25); color: #fef3c7;">Faded stroke</div>
        \\      <div>Plain <span style="-webkit-text-stroke: 1px #2563eb;">span stroke</span></div>
        \\      <div style="-webkit-text-stroke: 3px #b91c1c;">Same words</div>
        \\      <div style="-webkit-text-stroke: 9px #b91c1c;">Same words</div>
        \\    </div>
        ,
        .w = 360,
        .h = 200,
    });
    // the three background-clip: text lines of the fixture are drawn by the emitter (not here)
    try testing.expectEqual(r.blocks, r.same_blocks);
    try testing.expectEqual(r.ref_blocks, r.blocks + 3);
}

test "pdf text fixture: text-decoration-shadow" {
    try expectFixture(try runFixture(.{
        .name = "text-decoration-shadow",
        .fonts = &.{ archivo_path, notosc_path },
        .source = "<div style=\"width: 100%; height: 100%; padding: 16px; background-color: #ffffff; font-size: 32px; color: #111827; text-decoration: underline 3px; text-shadow: 4px 4px 6px rgba(37, 99, 235, 0.8);\">Underlined</div>",
        .w = 260,
        .h = 90,
    }), 0, 0);
}

test "pdf text fixture: color-glyph-text-shadow" {
    if (comptime !config.enable_color_fonts) return error.SkipZigTest;
    try expectFixture(try runFixture(.{
        .name = "color-glyph-text-shadow",
        .fonts = &.{ archivo_path, notosc_path, "assets/fonts/twemoji/TwemojiMozilla-colr.woff2" },
        .source =
        \\<div style="display: flex; flex-direction: column; row-gap: 12px; width: 100%; height: 100%; padding: 16px; background-color: #ffffff; font-size: 40px; color: #111827;">
        \\      <div style="text-shadow: 6px 6px 0 #2563eb;">Party 🎉🚀</div>
        \\      <div style="text-shadow: 6px 6px 4px rgba(220, 38, 38, 0.8);">Blur 🎉🚀</div>
        \\    </div>
        ,
        .w = 320,
        .h = 150,
    }), 0, 0);
}

test "pdf text fixture: bitmap-glyph-text-shadow" {
    if (comptime !config.enable_color_fonts) return error.SkipZigTest;
    try expectFixture(try runFixture(.{
        .name = "bitmap-glyph-text-shadow",
        .fonts = &.{"assets/fonts/noto-sans/NotoColorEmoji.ttf"},
        .source =
        \\<div style="display: flex; column-gap: 24px; width: 100%; height: 100%; padding: 16px; background-color: #ffffff; font-size: 48px; line-height: 1;">
        \\      <div style="text-shadow: 8px 8px 0 rgba(37, 99, 235, 0.6);">😀</div>
        \\      <div style="text-shadow: 8px 8px 8px rgba(220, 38, 38, 0.8);">😀</div>
        \\    </div>
        ,
        .w = 180,
        .h = 100,
    }), 0, 0);
}

test "pdf text fixture: text-stroke-paint-order" {
    if (comptime !config.enable_color_fonts) return error.SkipZigTest;
    const r = try runFixture(.{
        .name = "text-stroke-paint-order",
        .fonts = &.{ archivo_path, notosc_path, "assets/fonts/twemoji/TwemojiMozilla-colr.woff2" },
        .source =
        \\<div style="padding: 16px; background-color: #3070c0; color: white; font-size: 64px; font-weight: 700; letter-spacing: -0.05em; -webkit-text-stroke: 8px black;">
        \\      <div>Stroke 🎉</div>
        \\      <div style="paint-order: stroke fill;">Stroke 🎉</div>
        \\      <div style="paint-order: stroke;"><span>Stroke 🎉</span></div>
        \\    </div>
        ,
        .w = 420,
        .h = 280,
    });
    // glyph positions under letter-spacing differ in the last f32 bits (layout), so the TJ
    // adjustments do too; the fonts (CID + Type3 COLR) are identical
    try testing.expectEqual(r.ref_blocks, r.blocks);
    try testing.expectEqual(@as(u32, 0), r.fonts.dict_diffs);
    try testing.expectEqual(@as(u32, 0), r.fonts.stream_diffs);
}

/// A4 content box (takumi `PageOptions::A4`, automatic 10 mm margins) as a viewport.
const a4_w: u32 = 718;
const a4_h: u32 = 1047;

test "pdf text fixture: font-weights" {
    if (comptime !config.enable_pdf) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = [_][]const u8{ archivo_path, notosc_path, "assets/fonts/sil/scheherazade-new-v17-arabic-regular.woff2", "assets/fonts/noto-sans/noto-sans-devanagari-v30-devanagari-regular.woff2" };
    var fams: [4][]const u8 = undefined;
    {
        const r = rt.Renderer.create(testing.allocator) orelse return error.OutOfMemory;
        defer r.destroy();
        for (paths, 0..) |p, i| {
            const data = readRef(a, p) orelse return error.FileNotFound;
            const before = r.fonts.count();
            _ = try r.registerFont(try testing.allocator.dupe(u8, data), "", 0, -1, null);
            fams[i] = try a.dupe(u8, r.fonts.face(@intCast(before)).family);
        }
    }
    var doc: std.ArrayList(u8) = .empty;
    try doc.print(a, "<main style=\"display:flex;flex-direction:column;font-family:{s};font-size:16px;color:#141414;\"><h1 style=\"font-weight:700;\">Font weights</h1>", .{fams[0]});
    const weights = [_]u32{ 100, 300, 400, 600, 700, 900 };
    for (weights) |wt| try doc.print(a, "<p style=\"font-weight:{d};\">Weight {d} · Variable axis</p>", .{ wt, wt });
    try doc.appendSlice(a, "<p style=\"font-style:italic;\">Oblique from the same variable face</p>");
    for (weights) |wt| try doc.print(a, "<p lang=\"zh-Hant\" style=\"font-family:{s};font-weight:{d};\">字重 {d} 的中文字樣</p>", .{ fams[1], wt, wt });
    try doc.print(a, "<p lang=\"ar\" style=\"font-family:{s};font-weight:700;\">نص عربي عريض</p><p lang=\"ar\" style=\"font-family:{s};\">نص عربي عادي</p>", .{ fams[2], fams[2] });
    try doc.print(a, "<p lang=\"hi\" style=\"font-family:{s};font-weight:700;\">मोटा देवनागरी</p><p lang=\"hi\" style=\"font-family:{s};font-style:italic;\">तिरछा देवनागरी</p>", .{ fams[3], fams[3] });
    try doc.appendSlice(a, "</main>");
    const r = try runFixture(.{ .name = "font-weights", .fonts = &paths, .source = doc.items, .w = a4_w, .h = a4_h });
    // (the fixture's last line, background-clip: text, is the emitter's; one Archivo instance's
    // program differs: variations.normalize, see the report)
    try testing.expectEqual(r.blocks, r.same_blocks);
    try testing.expectEqual(r.ref_blocks, r.blocks + 1);
    try testing.expectEqual(@as(u32, 0), r.fonts.dict_diffs);
    try testing.expectEqual(@as(u32, 1), r.fonts.stream_diffs);
}

test "pdf text fixture: font-formats" {
    if (comptime !config.enable_pdf or !config.enable_color_fonts) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = [_][]const u8{ archivo_path, "assets/fonts/cjk-locl-test/CJKLoclTest.woff2", "assets/fonts/ubuntu/Ubuntu.ttc", "assets/fonts/twemoji/TwemojiMozilla-colr.woff2", "assets/fonts/sil/scheherazade-new-v17-arabic-regular.woff2", "assets/fonts/noto-sans/noto-sans-devanagari-v30-devanagari-regular.woff2" };
    var fams: [6][]const u8 = undefined;
    {
        const r = rt.Renderer.create(testing.allocator) orelse return error.OutOfMemory;
        defer r.destroy();
        for (paths, 0..) |p, i| {
            const data = readRef(a, p) orelse return error.FileNotFound;
            const before = r.fonts.count();
            _ = try r.registerFont(try testing.allocator.dupe(u8, data), "", 0, -1, null);
            fams[i] = try a.dupe(u8, r.fonts.face(@intCast(before)).family);
        }
    }
    const doc = try std.fmt.allocPrint(a,
        \\<main style="display:flex;flex-direction:column;font-family:{s};font-size:16px;color:#141414;">
        \\      <h1>Font formats</h1>
        \\      <p lang="zh" style="font-family:{s};">直 骨 今 海 真 令 説 器</p>
        \\      <p style="font-family:{s};">A face out of a TrueType collection</p>
        \\      <p style="font-family:{s};">Colour glyphs 🎉 🚀</p>
        \\      <p lang="ar" style="font-family:{s};">نص عربي للتشكيل</p>
        \\      <p lang="hi" style="font-family:{s};">संयुक्ताक्षर क्षत्र</p>
        \\    </main>
    , .{ fams[0], fams[1], fams[2], fams[3], fams[4], fams[5] });
    try expectFixture(try runFixture(.{ .name = "font-formats", .ref = "font-formats-pdfa-2b", .fonts = &paths, .source = doc, .w = a4_w, .h = a4_h }), 0, 1);
}

// ----------------------------------------------------------------------------- tests

test "pdf text: text-basic (Archivo, kerning) matches takumi's operators and font objects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "{\"type\":\"container\",\"style\":{\"display\":\"flex\",\"width\":\"100%\",\"height\":\"100%\",\"backgroundColor\":\"rgb(235,244,255)\"},\"children\":[{\"type\":\"text\",\"text\":\"Hello PDF from Takumi\",\"style\":{\"color\":\"rgb(20,20,20)\",\"fontSize\":32}}]}";
    const d = try renderDoc(a, &.{archivo_vf}, .json, src, 600, 300, false, .@"error");
    maybeWrite("text-basic", d.pdf);
    const blocks = try textBlocks(a, d.content);
    try testing.expectEqualStrings("q 0.75 0 0 -0.75 0 225 cm 0.0784 0.0784 0.0784 rg\nBT 0 Tr/f0 32 Tf 1 0 0 -1 0 28 Tm" ++
        "[(\\000\\001\\000\\002\\000\\003\\000\\003\\000\\004\\000\\005\\000\\006\\000\\007\\000\\b)34.99951(\\000\\005\\000\\t\\000\\n)10(\\000\\004\\000\\013\\000\\005\\000\\f)79.99951(\\000\\r\\000\\016\\000\\017\\000\\013\\000\\020)]TJ\nET\n", blocks);
}

test "pdf text: Vietnamese (precomposed and combining marks) round-trips through ToUnicode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "Tiếng Việt có dấu" precomposed, then with combining circumflex / acute / dot below
    const src = "{\"type\":\"container\",\"style\":{\"display\":\"flex\",\"flexDirection\":\"column\",\"width\":\"100%\"},\"children\":[" ++
        "{\"type\":\"text\",\"text\":\"Ti\u{1EBF}ng Vi\u{1EC7}t c\u{00F3} d\u{1EA5}u\",\"style\":{\"fontSize\":24}}," ++
        "{\"type\":\"text\",\"text\":\"Tie\u{0302}\u{0301}ng Vie\u{0323}\u{0302}t co\u{0301} da\u{0302}\u{0301}u\",\"style\":{\"fontSize\":24}}]}";
    const d = try renderDoc(a, &.{archivo_vf}, .json, src, 400, 100, false, .@"error");
    maybeWrite("vietnamese", d.pdf);
    try testing.expect(d.uncovered == null);
    const objs = try pdfObjects(a, d.pdf);
    var cmap: []const u8 = "";
    for (objs) |o| if (std.mem.indexOf(u8, o.dict, "/Type/CMap") != null) {
        cmap = o.data.?;
    };
    // the composed letters map to their own codepoints
    for ([_][]const u8{ "<1EBF>", "<1EC7>", "<00F3>", "<1EA5>" }) |want| try testing.expect(std.mem.indexOf(u8, cmap, want) != null);
    try testing.expectEqual(@as(u32, 0), d.issues.no_codepoint_mapping);
}

test "pdf text: uncoveredText error / placeholder / blank" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // U+0915 (Devanagari KA) and U+1F600 are not in Archivo
    const src = "{\"type\":\"container\",\"style\":{\"display\":\"flex\"},\"children\":[{\"type\":\"text\",\"text\":\"A\u{0915}B\u{1F600}\",\"style\":{\"fontSize\":20}}]}";
    const e = try renderDoc(a, &.{archivo_vf}, .json, src, 200, 50, false, .@"error");
    try testing.expectEqualStrings("No font the text can use draws \u{0915} (U+0915), \u{1F600} (U+1F600). Check each font's unicodeRange and the font-family stack, or register a font that draws them.", e.uncovered.?);
    // placeholder: .notdef (CID 0) is shown, and counted for PDF/A
    const p = try renderDoc(a, &.{archivo_vf}, .json, src, 200, 50, false, .placeholder);
    try testing.expect(p.uncovered == null);
    try testing.expect(std.mem.indexOf(u8, p.content, "\\000\\000") != null);
    try testing.expectEqual(@as(u32, 2), p.issues.notdef_shown);
    // blank: dropped
    const b = try renderDoc(a, &.{archivo_vf}, .json, src, 200, 50, false, .blank);
    try testing.expect(b.uncovered == null);
    try testing.expect(std.mem.indexOf(u8, b.content, "\\000\\000") == null);
    try testing.expectEqual(@as(u32, 0), b.issues.notdef_shown);
}

test "pdf text: Type3 ToUnicode CMap (1-byte codes)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try fo.type3Cmap(arena.allocator(), &.{ "\u{1F389}", null, "", "A" });
    try testing.expect(std.mem.indexOf(u8, t, "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n2 beginbfchar\n<00> <D83CDF89>\n<03> <0041>\nendbfchar\n") != null);
}

test "Track: glyph code strings decode back from the tokens Buf.str writes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const cases = [_][]const u8{ "", "\x00\x05", "\x00(\x00)", "\x00)\x00(", "(\\)\n\r\t\x08\x0c", "\x80\x01", "\xff\xfe\x00\x00", "a(b(c)d)e", "\x00\x1f\x00\x7f" };
    for (cases) |c| {
        var b = w.Buf.init(aa);
        b.str(c);
        var out: std.ArrayList(u8) = .empty;
        try testing.expect(try fo.Track.decodeStr(aa, b.list.items, &out));
        try testing.expectEqualSlices(u8, c, out.items);
    }
}
