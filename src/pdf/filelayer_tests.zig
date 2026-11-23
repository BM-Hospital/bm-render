//! File-layer behaviour checked end to end against what takumi-pdf 0.20.0 writes for the same
//! input (the cases of scripts/pdf-audit/{conformance,links,tagging,fonts}.probe.mjs): page
//! entries, validation error counts, link annotations and the structure tree.
const std = @import("std");
const config = @import("../config.zig");
const rt = @import("../render.zig");
const pdf = @import("pdf.zig");

const testing = std.testing;
const Renderer = rt.Renderer;

const inter = @embedFile("../font/testdata/Inter-Regular.ttf");

const T = struct {
    r: *Renderer,

    fn init() !T {
        const gpa = testing.allocator;
        const r = Renderer.create(gpa).?;
        errdefer r.destroy();
        _ = try r.registerFont(try gpa.dupe(u8, inter), "", 0, -1, null);
        return .{ .r = r };
    }

    fn deinit(t: T) void {
        t.r.destroy();
    }

    /// The readable PDF of `html` under the options (JSON).
    fn render(t: T, html: []const u8, opts: []const u8) ![]const u8 {
        return pdf.renderReadable(t.r, .html, html, opts);
    }

    /// The error message of a render that must fail.
    fn err(t: T, html: []const u8, opts: []const u8) ![]const u8 {
        try testing.expectError(error.Invalid, pdf.renderReadable(t.r, .html, html, opts));
        return t.r.err;
    }
};

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn expectHas(hay: []const u8, needle: []const u8) !void {
    if (!has(hay, needle)) {
        std.debug.print("missing: {s}\n", .{needle});
        return error.TestUnexpectedResult;
    }
}

const meta = "\"metadata\":{\"title\":\"T\",\"creationDate\":\"2026-08-06T01:02:03\"}";

test "page /Tabs: written for a page with a link also when the document is untagged" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const link = "<p><a href=\"https://example.com/\">x</a></p>";
    try expectHas(try t.render(link, "{\"tagged\":false}"), "/Tabs/S");
    try testing.expect(!has(try t.render("<p>x</p>", "{\"tagged\":false}"), "/Tabs"));
    try expectHas(try t.render("<p>x</p>", "{\"pdfa\":\"2a\",\"lang\":\"en\"," ++ meta ++ "}"), "/Tabs/S");
}

test "validation: one error per distinct glyph and character; string, name and q limits" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const a4 = "{\"pdfa\":\"4\",\"uncoveredText\":\"blank\"," ++ meta ++ "}";
    // (Inter draws U+E000 and U+E001; U+E002 has no glyph and "blank" leaves it out)
    try testing.expectEqualStrings("Writing the PDF failed: validation failed with 2 errors", try t.err("<p>a\u{E000}b\u{E001}c\u{E002}</p>", a4));
    try testing.expectEqualStrings("Writing the PDF failed: validation failed with 1 error", try t.err("<p>\u{E000} and \u{E000}</p>", a4));
    const a2b = "{\"pdfa\":\"2b\"," ++ meta ++ "}";
    // 40 nested clips nest q deeper than 28; 14 do not
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for ([_]usize{ 40, 14 }) |n| {
        buf.clearRetainingCapacity();
        for (0..n) |_| try buf.appendSlice(testing.allocator, "<div style=\"overflow:hidden;padding:1px\">");
        try buf.appendSlice(testing.allocator, "x");
        for (0..n) |_| try buf.appendSlice(testing.allocator, "</div>");
        if (n == 40) {
            try testing.expectEqualStrings("Writing the PDF failed: validation failed with 1 error", try t.err(buf.items, a2b));
            // PDF/A-4 has no such limit
            _ = try t.render(buf.items, "{\"pdfa\":\"4\"," ++ meta ++ "}");
        } else _ = try t.render(buf.items, a2b);
    }
    // a link URI over 32767 bytes
    buf.clearRetainingCapacity();
    try buf.appendSlice(testing.allocator, "<p><a href=\"https://e.com/");
    try buf.appendNTimes(testing.allocator, 'a', 40000);
    try buf.appendSlice(testing.allocator, "\">x</a></p>");
    try testing.expectEqualStrings("Writing the PDF failed: validation failed with 1 error", try t.err(buf.items, a2b));
    _ = try t.render(buf.items, "{}");
    // a title of 32768 bytes fails, 32767 pass
    for ([_]usize{ 32768, 32767 }) |n| {
        buf.clearRetainingCapacity();
        try buf.appendSlice(testing.allocator, "{\"pdfa\":\"2b\",\"metadata\":{\"creationDate\":\"2026-08-06\",\"title\":\"");
        try buf.appendNTimes(testing.allocator, 't', n);
        try buf.appendSlice(testing.allocator, "\"}}");
        if (n == 32768) {
            try testing.expectEqualStrings("Writing the PDF failed: validation failed with 1 error", try t.err("<p>x</p>", buf.items));
        } else _ = try t.render("<p>x</p>", buf.items);
    }
}

test "links: anonymous blocks, repeated table header and footer groups" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // inline content next to a block-level sibling sits in an anonymous block: not linked
    const anon = try t.render("<div>block</div><a href=\"https://a.example/\">a</a> <span href=\"https://s.example/\">s</span>", "{}");
    try testing.expectEqual(@as(usize, 0), count(anon, "/Subtype/Link"));
    // the inline content of an element is, whatever element carries the href
    const inl = try t.render("<p><span href=\"https://s.example/\">s</span> <a href=\"https://a.example/\">a</a></p>", "{}");
    try testing.expectEqual(@as(usize, 2), count(inl, "/Subtype/Link"));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "<table><thead><tr><th><a href=\"https://thead.example/\">head</a></th></tr></thead><tbody>");
    for (0..40) |_| try buf.appendSlice(testing.allocator, "<tr><td>row</td></tr>");
    try buf.appendSlice(testing.allocator, "</tbody><tfoot><tr><td><a href=\"https://tfoot.example/\">foot</a></td></tr></tfoot></table>");
    const doc = try t.render(buf.items, "{\"size\":\"A5\"}");
    const pages = count(doc, "/Type/Page/");
    try testing.expect(pages >= 2);
    // every page that repeats the groups annotates their links
    try testing.expectEqual(pages, count(doc, "/URI(https://thead.example/)"));
    try testing.expectEqual(pages, count(doc, "/URI(https://tfoot.example/)"));
    // only the first occurrence of each joins the structure tree
    try testing.expectEqual(@as(usize, 2), count(doc, "/StructParent "));
    try testing.expectEqual(@as(usize, 2), count(doc, "/S/Link"));
    // PDF/UA and PDF/A-2a require the alternate text the repeats lack
    try buf.insertSlice(testing.allocator, 0, "<h1>T</h1>");
    try testing.expectEqualStrings("Writing the PDF failed: validation failed with 1 error", try t.err(buf.items, "{\"size\":\"A5\",\"tagged\":\"ua1\",\"lang\":\"en\"," ++ meta ++ "}"));
    try testing.expectEqualStrings("Writing the PDF failed: validation failed with 1 error", try t.err(buf.items, "{\"size\":\"A5\",\"pdfa\":\"2a\",\"lang\":\"en\"," ++ meta ++ "}"));
}

const png1 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFElEQVR4nGP4z8DAAMIM////ZwAAHu8E/KPItPcAAAAASUVORK5CYII=";

test "tagging: heading titles, empty inline blocks, element ids" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // no text of a display:none descendant; the heading's text is its own content, no P inside
    const hidden = try t.render("<h1>seen <span style=\"display:none\">hidden</span></h1>", "{}");
    try expectHas(hidden, "/S/H1");
    try expectHas(hidden, "/T(seen)");
    try testing.expect(!has(hidden, "/S/P/"));
    // generated content is part of the title, of the outline entry too
    const gen = try t.render("<style>h2::before{content:\"1. \"}</style><h2>generated prefix</h2>", "{\"outline\":true}");
    try expectHas(gen, "/T(1. generated prefix)");
    try expectHas(gen, "/Title(1. generated prefix)");
    // a heading whose inline content puts nothing on a line keeps its element, with an empty
    // content sequence and no title (PDF/UA: MissingHeadingTitle)
    const blank = try t.render("<h1><span> </span></h1><p>x</p>", "{}");
    try expectHas(blank, "/S/H1");
    try testing.expect(!has(blank, "/T("));
    try testing.expectEqual(@as(usize, 2), count(blank, "BDC"));
    try testing.expectEqualStrings("Writing the PDF failed: validation failed with 2 errors", try t.err("<h1><span> </span></h1><p>x</p>", "{\"tagged\":\"ua1\",\"lang\":\"en\"," ++ meta ++ "}"));
    // `<div>  <span> </span>  </div>` is such a block too; `<p>   </p>` has no child at all
    const ws = try t.render("<p>   </p><p>a</p><div>  <span> </span>  </div>", "{}");
    try testing.expectEqual(@as(usize, 2), count(ws, "BDC"));
    // ids: child indices of takumi's render tree (no display:none box; a list marker first)
    try expectHas(try t.render("<p>0</p><p style=\"display:none\">n</p><ul><li>one</li><li id=\"a\">two</li></ul><p><a href=\"#a\">l</a></p>", "{}"), "/ID(Un.0.1.1)");
    try expectHas(try t.render("<p>0</p><ul><li><p>one</p></li><li><p id=\"a\">two</p></li></ul><p><a href=\"#a\">l</a></p>", "{}"), "/ID(Un.0.1.1.1)");
    // inline content next to a block sits in an anonymous block; white space inside it counts
    try expectHas(try t.render("<p>0</p><div>t <b>b</b> <img id=\"a\" alt=\"i\" width=\"5\" height=\"5\" src=\"" ++ png1 ++ "\"> y<p>q</p></div><p><a href=\"#a\">l</a></p>", "{}"), "/ID(Un.0.1.0.3)");
    // an inline element with a role around an image is an element of its own
    const il = try t.render("<p><a href=\"https://e.com/\"><img alt=\"pic\" width=\"5\" height=\"5\" src=\"" ++ png1 ++ "\"></a> <strong><img alt=\"q\" width=\"5\" height=\"5\" src=\"" ++ png1 ++ "\"></strong></p>", "{}");
    try expectHas(il, "/S/Link");
    try expectHas(il, "/S/Strong");
    try testing.expectEqual(@as(usize, 2), count(il, "/S/Figure"));
}

test "tagging: anonymous table boxes; nothing marked stays outside the tree" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // text directly in a table: an anonymous row group, row and cell of its own
    const stray = try t.render("<table>stray text<tr><td>c</td></tr></table>", "{}");
    try testing.expectEqual(@as(usize, 2), count(stray, "/S/TBody"));
    try testing.expectEqual(@as(usize, 2), count(stray, "/S/TD"));
    try testing.expect(!has(stray, "null"));
    // a row group in a block is wrapped in an anonymous table; its block child in a row and cell
    const over = try t.render("<table style=\"display:block\"><tr style=\"display:block\"><td style=\"display:inline\">not a table</td></tr></table>", "{}");
    for ([_][]const u8{ "/S/Table", "/S/TBody", "/S/TR", "/S/TD", "/S/P" }) |role| try testing.expectEqual(@as(usize, 1), count(over, role));
    // cells without a table share one anonymous table and row
    const cells = try t.render("<p>a</p><div style=\"display:table-cell\">one</div><div style=\"display:table-cell\">two</div><p>b</p>", "{}");
    try testing.expectEqual(@as(usize, 1), count(cells, "/S/Table"));
    try testing.expectEqual(@as(usize, 1), count(cells, "/S/TR"));
    try testing.expectEqual(@as(usize, 2), count(cells, "/S/TD"));
    // a row's children that are no cells share one anonymous cell
    const row = try t.render("<div style=\"display:table\"><div style=\"display:table-row\"><p>p1</p><p>p2</p>text</div></div>", "{}");
    try testing.expectEqual(@as(usize, 1), count(row, "/S/TD"));
    try testing.expectEqual(@as(usize, 3), count(row, "/S/P"));
    // flex items are blockified: no table around a table-cell item
    try testing.expect(!has(try t.render("<div style=\"display:flex\"><div style=\"display:table-cell\">x</div></div>", "{}"), "/S/Table"));
}

test "tagging: list labels and numbering" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // an inside marker is text of the item's line: no Lbl, one content sequence
    const inside = try t.render("<ul style=\"list-style-position:inside\"><li>inside</li></ul>", "{}");
    try testing.expect(!has(inside, "/S/Lbl"));
    try testing.expectEqual(@as(usize, 1), count(inside, "BDC"));
    // an item's own line: the text, then the marker's label
    const own = try t.render("<ul><li>out</li></ul>", "{}");
    try testing.expectEqual(@as(u8, 49), lblKid(own));
    // an item holding blocks: the label comes first
    const blocks = try t.render("<ul><li><p>one</p><p>two</p></li></ul>", "{}");
    try testing.expectEqual(@as(u8, 48), lblKid(blocks));
    const nested = try t.render("<ul><li>a<ul><li>a1</li></ul></li></ul>", "{}");
    try testing.expectEqual(@as(u8, 48), lblKid(nested));
    // a counter style takumi does not know: the numbering of the element (ol: decimal), and a
    // decimal marker when no font has the style's glyphs, not an uncovered-text failure
    const greek = try t.render("<ol style=\"list-style-type:lower-greek\"><li>g</li></ol>", "{}");
    try expectHas(greek, "/ListNumbering/Decimal");
    const geo = try t.render("<ol style=\"list-style-type:georgian\"><li>g</li></ol><ul style=\"list-style-type:georgian\"><li>g</li></ul>", "{}");
    try expectHas(geo, "/ListNumbering/Decimal");
    try expectHas(geo, "/ListNumbering/Disc");
}

test "tagging: an outside image marker is its item's label" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const image = "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20width='10'%20height='10'%3E%3Crect%20width='10'%20height='10'%20fill='blue'/%3E%3C/svg%3E";
    // the item's text (MCID 0), then the marker image in the Lbl (MCID 1)
    const doc = try t.render("<ul style=\"list-style-image:url(&quot;" ++ image ++ "&quot;)\"><li>Body</li></ul>", "{}");
    try testing.expectEqual(@as(usize, 1), count(doc, "/S/Lbl"));
    try testing.expectEqual(@as(u8, 49), lblKid(doc));
    try testing.expectEqual(@as(usize, 1), count(doc, "/S/P"));
}

test "list-style-image: an outside SVG without a natural width neither paints nor moves the line" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const image = "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0%200%2010%2010'%3E%3Crect%20width='10'%20height='10'%20fill='blue'/%3E%3C/svg%3E";
    const doc = try t.render("<ul style=\"margin:0;padding-left:30px;list-style-image:url(&quot;" ++ image ++ "&quot;)\"><li>Body</li></ul>", "{\"viewport\":{\"width\":200,\"height\":100},\"tagged\":false}");
    // the text starts at the item's content edge, without a TJ shift
    try expectHas(doc, "1 0 0 -1 30 ");
    try testing.expect(has(doc, "Tm[(") or has(doc, "Tm[<"));
    try testing.expect(!has(doc, "0 0 1 rg"));
}

/// The first kid (a marked-content id digit) of the first Lbl element.
fn lblKid(doc: []const u8) u8 {
    const at = std.mem.indexOf(u8, doc, "/S/Lbl") orelse return 0;
    const k = std.mem.indexOfPos(u8, doc, at, "/K[") orelse return 0;
    return doc[k + 3];
}

test "fonts: font-synthesis decides the synthetic bold stroke and the oblique skew" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // (only Inter Regular is registered: bold is a stroke `2 Tr`, italic a skewed matrix)
    const skew = "-0.1875 -0.75";
    const both = try t.render("<p style=\"font-weight:700;font-style:italic\">x</p>", "{\"tagged\":false}");
    try testing.expect(has(both, "2 Tr") and has(both, skew));
    const off = try t.render("<p style=\"font-weight:700;font-style:italic;font-synthesis:none\">x</p>", "{\"tagged\":false}");
    try testing.expect(!has(off, "2 Tr") and !has(off, skew));
    const weight = try t.render("<p style=\"font-weight:700;font-style:italic;font-synthesis:weight\">x</p>", "{\"tagged\":false}");
    try testing.expect(has(weight, "2 Tr") and !has(weight, skew));
    const slant = try t.render("<p style=\"font-weight:700;font-style:italic;font-synthesis:style\">x</p>", "{\"tagged\":false}");
    try testing.expect(!has(slant, "2 Tr") and has(slant, skew));
}

test "text: default-ignorable characters are invisible glyphs of their own" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // a zero-width space after `a`: the space glyph without advance, whose first use gives that
    // glyph the text U+200B (so the two real spaces after it carry `/ActualText( )`, exactly as
    // in takumi-pdf); `a` keeps mapping to `a` alone and needs no span
    const zwsp = try t.render("<p>a\u{200B}b a ab</p>", "{\"tagged\":false}");
    try testing.expectEqual(@as(usize, 2), count(zwsp, "/ActualText"));
    try testing.expectEqual(@as(usize, 2), count(zwsp, "/ActualText( )"));
    try testing.expect(!has(zwsp, "0061200B"));
    // a zero-width joiner continues the cluster before it: one span over both glyphs
    const zwj = try t.render("<p>j\u{200D} j</p>", "{\"tagged\":false}");
    try expectHas(zwj, "/ActualText<FEFF006A200D>");
    try testing.expect(!has(zwj, "<006A200D>"));
    // PDF/A-2u: U+FEFF after two different letters is one glyph with an invalid mapping, so one
    // error (it was one per letter)
    try testing.expectEqualStrings("Writing the PDF failed: validation failed with 1 error", try t.err("<p>a\u{FEFF} b\u{FEFF}</p>", "{\"pdfa\":\"2u\",\"uncoveredText\":\"blank\"," ++ meta ++ "}"));
    // text without such characters is untouched
    try testing.expect(!has(try t.render("<p>plain text</p>", "{\"tagged\":false}"), "/ActualText"));
}

test "root element: relative offset and auto inline margins apply, document and bands (takumi-pdf)" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // oracle: takumi-pdf 0.20.0 lays the root out as a block child of the page frame
    const box = "<div style=\"width:50px;height:30px;position:relative;top:20px;left:10px;background:#f00\"></div>";
    const page = "\"size\":{\"width\":200,\"height\":200}";
    try expectHas(try t.render(box, "{" ++ page ++ ",\"margin\":0,\"tagged\":false}"), "1 0 0 rg 10 20 50 30 re");
    try expectHas(try t.render(box, "{\"viewport\":{\"width\":200},\"tagged\":false}"), "1 0 0 rg 10 20 50 30 re");
    // the offset moves the root but sizes nothing: a content-sized page is as tall as the box (30 px = 22.5 pt)
    try expectHas(try t.render(box, "{\"viewport\":{\"width\":200},\"tagged\":false}"), "/MediaBox[0 0 150 22.5]");
    try expectHas(try t.render("<div style=\"width:50px;height:30px;position:relative;bottom:-20px;right:-10px;background:#f00\"></div>", "{" ++ page ++ ",\"margin\":0,\"tagged\":false}"), "1 0 0 rg 10 20 50 30 re");
    try expectHas(try t.render("<div></div>", "{" ++ page ++ ",\"margin\":{\"top\":0,\"right\":0,\"bottom\":60,\"left\":0},\"footer\":\"" ++
        "<div style=\\\"width:50px;height:30px;position:relative;top:20px;left:10px;background:#f00\\\"></div>\",\"tagged\":false}"), "1 0 0 rg 10 20 50 30 re");
    try expectHas(try t.render("<div style=\"width:50px;height:30px;margin:0 auto;background:#f00\"></div>", "{" ++ page ++ ",\"margin\":0,\"tagged\":false}"), "1 0 0 rg 75 0 50 30 re");
    // a sticky or static root is not offset
    try expectHas(try t.render("<div style=\"width:50px;height:30px;position:sticky;top:20px;background:#f00\"></div>", "{" ++ page ++ ",\"margin\":0,\"tagged\":false}"), "1 0 0 rg 0 0 50 30 re");
    try expectHas(try t.render("<div style=\"width:50px;height:30px;top:20px;background:#f00\"></div>", "{" ++ page ++ ",\"margin\":0,\"tagged\":false}"), "1 0 0 rg 0 0 50 30 re");
    // an absolute child of an offset root moves with it
    try expectHas(try t.render("<div style=\"position:relative;top:20px;height:50px\"><div style=\"position:absolute;left:10px;top:0;width:50px;height:30px;background:#f00\"></div></div>", "{" ++ page ++ ",\"margin\":0,\"tagged\":false}"), "1 0 0 rg 10 20 50 30 re");
}

test "paged text: a rotated line reaches the preceding page as outlines only (takumi-pdf)" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // Upstream pdf_fixtures.rs::paged_lines_under_a_transform_or_a_clip, paged-rotated-text.
    const doc = try t.render("<div style=\"height:200px\">Q3 results</div>" ++
        "<div style=\"height:200px;break-before:page\"><div style=\"transform:rotate(-15deg)\">Draft</div></div>", "{\"size\":{\"width\":400,\"height\":200},\"margin\":0,\"tagged\":false}");
    try testing.expectEqual(@as(usize, 2), count(doc, "/Type/Page/"));
    // Both pages hold one text run. The first also paints Draft as outlines, without duplicating text.
    try testing.expectEqual(@as(usize, 2), count(doc, "BT"));
    var pos: usize = 0;
    var pages: usize = 0;
    while (std.mem.indexOfPos(u8, doc, pos, "stream\n")) |start| {
        const body = start + "stream\n".len;
        const end = std.mem.indexOfPos(u8, doc, body, "endstream") orelse break;
        pos = end + "endstream".len;
        const content = doc[body..end];
        if (!has(content, "BT")) continue;
        try testing.expectEqual(@as(usize, 1), count(content, "BT"));
        if (pages == 0) try expectHas(content, " m");
        pages += 1;
    }
    try testing.expectEqual(@as(usize, 2), pages);
}

test "paged text: an overflow clip cutting away a baseline keeps visible text selectable" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const doc = try t.render("<div style=\"height:100px;overflow:hidden\">" ++
        "<div style=\"padding-top:88px;line-height:24px\">Visible</div></div>" ++
        "<div style=\"height:100px;break-before:page\"></div>", "{\"size\":{\"width\":300,\"height\":100},\"margin\":0,\"tagged\":false}");
    try testing.expectEqual(@as(usize, 2), count(doc, "/Type/Page/"));
    try testing.expectEqual(@as(usize, 1), count(doc, "BT"));
}

test "paged text: a monolithic atomic inline retains both continuation regions" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // pdf_fixtures.rs::paged_monolithic_overflow: the oversized inline paints
    // across the next page, so its original fragment still owns a content visit.
    const doc = try t.render("<div style=\"font-size:16px;line-height:24px\">" ++
        "<div>before 1</div><div>before 2</div><div>before 3</div>" ++
        "<div><span style=\"display:inline-block;width:120px;height:360px;background:red\"></span> tall line text</div>" ++
        "<div>after A</div><div>after B</div></div>", "{\"size\":{\"width\":400,\"height\":300},\"margin\":24}");
    try testing.expectEqual(@as(usize, 3), count(doc, "/Type/Page/"));
    try testing.expectEqual(@as(usize, 1), count(doc, "/P<</MCID 3"));
    try testing.expectEqual(@as(usize, 3), count(doc, "/P<</MCID 0"));
    try testing.expectEqual(@as(usize, 6), count(doc, "BT"));
}

test "paged continuation: parallel table cells survive alternating page widths" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const words = comptime blk: {
        var left: []const u8 = "";
        var right: []const u8 = "";
        for (0..45) |_| {
            left = left ++ "left word ";
            right = right ++ "right word ";
        }
        break :blk .{ left, right };
    };
    const doc = try t.render("<style>@page{size:240px 140px;margin:10px}@page:left{size:360px 140px;margin:10px}td{padding:0;vertical-align:top}table{border-spacing:0}</style>" ++
        "<div style=\"font:14px/20px Inter\"><table style=\"width:100%\"><tr><td style=\"width:50%\">" ++ words[0] ++ "</td><td>" ++ words[1] ++ "</td></tr></table><p>AFTER</p></div>", "{}");
    try testing.expectEqual(@as(usize, 6), count(doc, "/Type/Page/"));
}

test "paged continuation: completed cells keep empty regions in remaining row space" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var left: std.ArrayList(u8) = .empty;
    var right: std.ArrayList(u8) = .empty;
    for (0..45) |i| {
        try left.appendSlice(a, try std.fmt.allocPrint(a, "L{d} word ", .{i}));
        try right.appendSlice(a, try std.fmt.allocPrint(a, "R{d} word ", .{i}));
    }
    const html = try std.mem.concat(a, u8, &.{
        "<style>@page{size:240px 140px;margin:10px}@page:left{size:360px 140px;margin:10px}p{margin:0}td{padding:0;vertical-align:top}table{border-spacing:0}</style><div style=\"font:14px/20px Inter\"><table style=\"width:100%\"><tr><td style=\"width:50%\">",
        left.items,
        "</td><td>",
        right.items,
        "</td></tr></table><p>AFTER</p></div>",
    });
    const doc = try t.render(html, "{}");
    try testing.expectEqual(@as(usize, 6), count(doc, "/Type/Page/"));
    // Two cell regions on each of the first five pages, then the paragraph after the table.
    try testing.expectEqual(@as(usize, 11), count(doc, "/P<</MCID"));
}

test "text controls: input values and textarea lines reach PDF, passwords stay masked" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const doc = try t.render("<div><input value=\"Zebra\"><textarea>one&#13;&#10;two</textarea>" ++
        "<input type=\"password\" value=\"秘密\"></div>", "{\"tagged\":false}");
    try expectHas(doc, "<005A>"); // Z from the input's value, absent before the shadow editor exists
    try expectHas(doc, "<2022>"); // the password's mask, never its original characters
    try testing.expect(!has(doc, "<79D8>"));
    try testing.expect(!has(doc, "<5BC6>"));
    try testing.expect(count(doc, "BT") >= 4); // input, two textarea lines, password
}

test "paged decorations: rotated border boxes use per-fragment geometry" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const doc = try t.render("<div style=\"height:80px\"></div>" ++
        "<div style=\"box-sizing:border-box;width:60px;height:40px;transform:rotate(10deg);background:red;border:2px solid blue\"></div>", "{\"size\":{\"width\":200,\"height\":100},\"margin\":0,\"tagged\":false}");
    try testing.expectEqual(@as(usize, 2), count(doc, "/Type/Page/"));
    try testing.expect(count(doc, "0 0 60 20 re") >= 2);
    try testing.expect(!has(doc, "0 0 60 40 re"));
}

test "generated images: content url reaches the PDF with its surrounding text" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const image = "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20width='10'%20height='10'%3E%3Crect%20width='10'%20height='10'%20fill='blue'/%3E%3C/svg%3E";
    const doc = try t.render("<style>p::before{content:'Zebra' url(\"" ++ image ++ "\") 'Yak'}</style><p>Body</p>", "{\"tagged\":false}");
    try expectHas(doc, "0 0 1 rg");
    try expectHas(doc, "<005A>");
    try expectHas(doc, "<0059>");
    const marker = try t.render("<ul style=\"list-style-type:none;list-style-image:url(&quot;" ++ image ++ "&quot;)\"><li>Body</li></ul>", "{\"tagged\":false}");
    try expectHas(marker, "0 0 1 rg");
}

test "generated images: gradients fit explicit pseudo boxes and keep mixed text" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const doc = try t.render("<style>p::before{content:'Zebra' linear-gradient(red,blue) 'Yak';display:block;width:24px;height:16px}</style><p>Body</p>", "{\"viewport\":{\"width\":120,\"height\":120},\"tagged\":false}");
    try expectHas(doc, "/ShadingType 2");
    try expectHas(doc, "<005A>");
    try expectHas(doc, "<0059>");
    const inline_doc = try t.render("<style>p::before{content:linear-gradient(red,blue)}</style><p>Body</p>", "{\"viewport\":{\"width\":120,\"height\":120},\"tagged\":false}");
    try testing.expect(!has(inline_doc, "/ShadingType"));
}

test "SVG page cascade: ancestor selectors and importance reach inline descendants" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const doc = try t.render("<style>svg > g.outer rect.a{fill:blue!important}</style>" ++
        "<div><svg width=\"40\" height=\"40\"><g class=\"outer\"><rect class=\"a\" width=\"40\" height=\"40\" style=\"fill:red\"/></g></svg></div>", "{\"tagged\":false}");
    try expectHas(doc, "0 0 1 rg");
    try testing.expect(!has(doc, "1 0 0 rg"));
}

// ------------------------------------------------------------------------------------------------
// Text tails checked against the pinned takumi-pdf oracle (scripts/pdf-audit/text-tails.probe.mjs):
// form-control sizing, `unicode-bidi: plaintext`, RTL overflow markers and soft hyphens.

const naskh = @embedFile("../font/testdata/NotoNaskhArabic-Regular.ttf");

test "text controls: field width from the head bounding box, border-box search fields, centred editor" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // takumi: avg 7 * 20 + (round(head xMax - xMin) - avg) = 220 (+ 2px border, 1px 2px padding);
    // the search field adds its border and padding to the same content width (box-sizing: border-box)
    const doc = try t.render("<div><input value=\"x\" style=\"font:14px Inter\"><input type=\"search\" value=\"y\" style=\"font:14px Inter\"></div>", "{\"tagged\":false}");
    try expectHas(doc, "0 0 226 23 re");
    try expectHas(doc, "226 0 226 23 re");
    // a 50px field centres its 17px editor at 16.5px (LayoutUnit half of the free space), not 16
    const tall = try t.render("<div><input value=\"Tall\" style=\"font:14px Inter;height:50px\"></div>", "{\"tagged\":false}");
    try expectHas(tall, "1 0 0 -1 4 33.5 Tm");
}

test "unicode-bidi plaintext: each paragraph aligns by the direction of its first strong character" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    _ = try t.r.registerFont(try testing.allocator.dupe(u8, naskh), "", 0, -1, null);
    const doc = try t.render("<p style=\"margin:0;font:20px Inter,'Noto Naskh Arabic';width:260px;unicode-bidi:plaintext\">abc<br>\u{645}\u{631}\u{62d}\u{628}\u{627}</p>", "{\"tagged\":false}");
    try expectHas(doc, "1 0 0 -1 0 19 Tm[("); // the Latin paragraph starts at the left
    try expectHas(doc, "1 0 0 -1 0 45 Tm[-"); // the Arabic one is start (= right) aligned
    // no strong character: left-to-right (UAX #9 P3), whatever `direction` says
    const neutral = try t.render("<p style=\"margin:0;font:20px Inter;width:260px;direction:rtl;unicode-bidi:plaintext\">123 !</p>", "{\"tagged\":false}");
    try testing.expect(!has(neutral, "/ReversedChars"));
    try expectHas(neutral, "1 0 0 -1 0 19 Tm[(");
}

test "text-overflow: an RTL marker follows the content in paint order with the last kept item's brush" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    _ = try t.r.registerFont(try testing.allocator.dupe(u8, naskh), "", 0, -1, null);
    const doc = try t.render("<p style=\"margin:0;font:20px Inter,'Noto Naskh Arabic';width:120px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;direction:rtl\">" ++
        "\u{645}\u{631}\u{62d}\u{628}\u{627} <span style=\"color:red\">\u{628}\u{627}\u{644}\u{639}\u{627}\u{644}\u{645} \u{645}\u{631}\u{62d}\u{628}\u{627} \u{628}\u{627}\u{644}\u{639}\u{627}\u{644}\u{645}</span> \u{645}\u{631}\u{62d}\u{628}\u{627}</p>", "{\"tagged\":false}");
    // the marker (Inter's "…", font /f0) is the last text object, painted red like the cut span
    const last_bt = std.mem.lastIndexOf(u8, doc, "BT ").?;
    try testing.expect(std.mem.startsWith(u8, doc[last_bt..], "BT 0 Tr/f0 "));
    try testing.expect(std.mem.endsWith(u8, doc[0..last_bt], "1 0 0 rg\n"));
    // the marker keeps the block's font synthesis: no emboldening from a bold span it follows
    const bold = try t.render("<p style=\"margin:0;font:20px Inter;width:120px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis\">A long <span style=\"font-weight:bold;color:red\">line that does not fit</span></p>", "{\"tagged\":false}");
    try testing.expectEqual(@as(usize, 1), count(bold, " 2 Tr"));
    try expectHas(bold, "1 0 0 rg\nBT 0 Tr/f0 20 Tf 1 0 0 -1 0 19 Tm[-4957.0312");
}

test "soft hyphens: hyphens none keeps the word whole, a generated hyphen sits on the LayoutUnit grid" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const none_doc = try t.render("<p style=\"margin:0;font:20px Inter;width:60px;hyphens:none\">extra&shy;ordinary</p>", "{\"tagged\":false}");
    try testing.expect(!has(none_doc, "<2010>"));
    try testing.expect(!has(none_doc, "0 43 Tm"));
    const manual = try t.render("<p style=\"margin:0;font:20px Inter;width:60px\">extra&shy;ordinary</p>", "{\"tagged\":false}");
    try expectHas(manual, "<2010>");
    // "cal\u{ad}i" + hyphen: the hyphen starts at ceil64 of the item's width (32.546875px), as in
    // takumi, so a viewer extracts "cali\u{ad}" before the hyphen
    const multi = try t.render("<p style=\"margin:0;font:20px Inter;width:50px\">cal&shy;i&shy;fra</p>", "{\"tagged\":false}");
    try expectHas(multi, "Tm[-1627.3438(");
}

fn before(hay: []const u8, a: []const u8, b: []const u8) !void {
    const ia = std.mem.indexOf(u8, hay, a) orelse return error.TestUnexpectedResult;
    const ib = std.mem.indexOf(u8, hay, b) orelse return error.TestUnexpectedResult;
    try testing.expect(ia < ib);
}

// A transformed box at a page boundary (tasks 03 / 05; the cases of
// scripts/pdf-audit/transform-fragments.probe.mjs, against the pinned takumi-pdf).
const tf_page = "{\"size\":{\"width\":300,\"height\":200},\"margin\":10}";
fn tfDoc(comptime pre: []const u8, comptime inner: []const u8) []const u8 {
    return "<div style=\"font:14px Inter\"><div style=\"height:" ++ pre ++ "px;background:#eee\">A</div>" ++ inner ++ "<div>after</div></div>";
}

test "transformed box at a page boundary: the page it reaches paints its background, then its text" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // laid out at the top of page 2, its rotated corner reaches page 1: there its text (outlines)
    // paints with the box, after its background (it was painted in page 1's own pass, first)
    const html = "<div style=\"border:3px solid #333;padding:4px;font:14px Inter\"><div style=\"height:160px;background:#eee\">A</div><div style=\"transform:rotate(20deg);width:80px;height:40px;background:#c33\">Rot</div><div>after</div></div>";
    const out = try t.render(html, tf_page);
    try before(out, "16.856003 cm 0.8 0.2 0.2 rg 0 0 80 40 re", "16.856003 cm 0 0 0 rg");
}

test "transformed box at a page boundary: each fragment paints the lines laid out in it" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const out = try t.render(tfDoc("150", "<div style=\"transform:rotate(20deg);width:80px;height:40px;background:#c33\">Rot</div>"), tf_page);
    // page 2: the line of the first fragment as outlines in that fragment's space (not the second's)
    try expectHas(out, "174.58215 cm 0 0 0 rg 1.2304688 14 m");
    try testing.expect(!has(out, "cm 0 0 0 rg 1.2304688 -16 m"));
    // the second fragment reaches page 1: its (empty) content region opens there too
    try testing.expectEqual(@as(usize, 2), count(out, "/P<</MCID 2>>BDC"));
}

test "transformed box at a page boundary: a fragment missing a page paints nothing there" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // skewX keeps the second fragment below page 1: no fill, no empty region there
    const out = try t.render(tfDoc("100", "<div style=\"transform:skewX(15deg);width:100px;background:#9c9\">L1<br>L2<br>L3<br>L4<br>L5</div>"), tf_page);
    try testing.expectEqual(@as(usize, 1), count(out, "cm 0.6 0.8 0.6 rg 0 0 100 34 re"));
    try testing.expect(!has(out, "/MCID 2>>BDC"));
}

test "transformed box at a page boundary: boxes and links inside take the fragment holding them" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // a child block cut with its rotated parent: one piece per fragment, not the whole child twice
    const child = try t.render(tfDoc("100", "<div style=\"transform:rotate(12deg);width:120px;background:#fcc;padding:2px\"><div style=\"background:#ccf;border:2px solid #333\">C1<br>C2<br>C3<br>C4<br>C5</div></div>"), tf_page);
    try testing.expect(!has(child, "0.8 0.8 1 rg 2 2 116 114 re"));
    try expectHas(child, "0.8 0.8 1 rg 2 2 116 78 re");
    try expectHas(child, "0.8 0.8 1 rg 2 0 116 36 re");
    // a link in the first fragment: one annotation, not one per fragment pass
    const link = try t.render(tfDoc("100", "<div style=\"transform:rotate(12deg);width:120px;background:#fcc\">L1<br>L2<br><a href=\"https://example.com/x\">link</a><br>M1<br>M2</div>"), tf_page);
    try testing.expectEqual(@as(usize, 1), count(link, "/Subtype/Link"));
    // a transformed box inside, cut with it: its fragment on page 2 misses page 1 (one content
    // region there for the outer box's lines)
    const nested = try t.render(tfDoc("100", "<div style=\"transform:rotate(8deg);width:120px;background:#fcc;padding:2px\"><div style=\"transform:skewX(10deg);background:#ccf\">N1<br>N2<br>N3<br>N4</div>O1<br>O2</div>"), tf_page);
    try testing.expectEqual(@as(usize, 1), count(nested, "0.8 0.8 1 rg"));
    try testing.expect(!has(nested, "/MCID 3>>BDC"));
}

fn clipDoc(comptime pre: []const u8, comptime inner: []const u8) []const u8 {
    return "<div style=\"font:14px Inter\"><div style=\"height:" ++ pre ++ "px;background:#eee\">A</div>" ++ inner ++ "<div>after</div></div>";
}
const abs_in_clip = "<div style=\"position:relative\"><div style=\"overflow:hidden;height:70px;background:#cde\">S1<br>S2<br>S3<div style=\"position:absolute;top:40px;left:100px;background:#fc3\">E1<br>E2<br>E3<br>E4<br>E5</div></div></div>";

test "clip at a page boundary: an absolutely positioned box escaping the clip takes its own pages and text" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // its end below the last page adds a page, where its second fragment paints
    const end = try t.render(clipDoc("60", abs_in_clip), tf_page);
    try testing.expectEqual(@as(usize, 2), count(end, "/MediaBox"));
    try expectHas(end, "1 0.8 0.2 rg 100 100 17 80 re");
    try expectHas(end, "1 0.8 0.2 rg 100 180 17 34 re");
    // the clip it escapes does not narrow its text: E5 (frame y 245) is on page 2
    const cut = try t.render(clipDoc("120", abs_in_clip), tf_page);
    try expectHas(cut, "Tm[(\\000\\006\\000\\r)]TJ");
}

test "clip at a page boundary: a clipped paragraph opens no region past its block" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // the block ends at the page end, its clipped lines overflow it: one region on page 1
    const out = try t.render(clipDoc("120", "<div style=\"overflow:hidden;height:60px;background:#cde\">B1<br>B2<br>B3<br>B4<br>B5<br>B6<br>B7<br>B8</div>"), tf_page);
    try testing.expect(!has(out, "/P<</MCID 2>>BDC"));
}

fn spanDoc(comptime st: []const u8) []const u8 {
    return "<div style=\"font:16px Inter\"><div style=\"height:140px\">A</div><p style=\"margin:0;width:120px\">a <span style=\"" ++ st ++ "\">inline box that wraps over several lines here and more words to cross</span> b</p></div>";
}

test "inline span across pages: each page's fragment has its own image strip" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const out = try t.render(spanDoc("background:linear-gradient(90deg,#f00,#00f)"), tf_page);
    // page 1: two lines (190 px); page 2 starts a strip of its own at x 0
    try expectHas(out, "/Coords[13 150 203 150]");
    try expectHas(out, "/Coords[0 190 315 190]");
}

test "inline span strip: the pattern covers the strip's padding box, both end borders out" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    const out = try t.render("<p style=\"margin:20px;width:120px;font:16px Inter\">a <span style=\"background:linear-gradient(90deg,#f00,#00f);padding:2px 6px;border:2px solid #000\">inline box that wraps over several lines here</span> b</p>", tf_page);
    try expectHas(out, "scn 35 18 330 24 re");
    try expectHas(out, "scn -270 78 330 24 re");
}

test "inline span across pages: the spans' reach opens the neighbouring fragments' regions" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // padding 0 4px: takumi's `span_ink_reach` (4 px, every side) takes both fragments' paint
    // bounds over the boundary: an empty region on each page
    const out = try t.render(spanDoc("background:radial-gradient(circle,#ff0,#0a0);border-radius:6px;padding:0 4px"), tf_page);
    try expectHas(out, "/K[1 2<</Type/MCR/MCID 0/Pg");
    try testing.expectEqual(@as(usize, 1), count(out, "/P<</MCID 2>>BDC"));
}

test "transformed box at a page boundary: a box lifted from the page before's fragment paints before this page's positioned fragments" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // page 2: the moved box (laid out on page 1) before the border of its positioned parent's
    // page-2 fragment (takumi's page scene visits the root fragments page by page)
    const html = "<div style=\"height:320px\"></div><div style=\"position:relative;width:200px;height:120px;margin:10px;border:1px solid #999\"><div style=\"width:60px;height:24px;background:#c33;font:14px Inter;offset-path:ray(135deg closest-side);offset-distance:70%\">Tx</div></div>";
    const out = try t.render(html, "{\"size\":{\"width\":300,\"height\":400},\"margin\":20}");
    try before(out, "315.5691 cm 0.8 0.2 0.2 rg 0 0 60 24 re", "555 cm 0.6 0.6 0.6 rg 10 449 200 1 re");
}

test "images: a filtered PNG whose pixels do not decode stops the render, as takumi-pdf's UndrawableImage" {
    if (comptime !config.enable_pdf) return;
    const t = try T.init();
    defer t.deinit();
    // takumi-pdf `an_undecodable_image_stops_the_render`: the IHDR still reads 8x8, the IDAT is zeros
    const broken = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAD0lEQVQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAElFTkSuQmCC";
    const opts = "{\"viewport\":{\"width\":48,\"height\":48}}";
    const msg = try t.err("<img src=\"" ++ broken ++ "\" style=\"filter:grayscale(1);width:32px;height:32px\">", opts);
    try expectHas(msg, "Image could not be decoded: ");
    try expectHas(msg, ": a filter needs the image's pixels: An error occurred while decoding the image data: ");
    // without a filter the PNG is embedded as krilla decodes it, which fails too
    _ = try t.err("<img src=\"" ++ broken ++ "\" style=\"width:32px;height:32px\">", opts);
}
