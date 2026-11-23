//! PDF output (takumi-pdf). This file is the single plug-in point of the PDF pipeline:
//!
//!   * `render`  -> `Renderer.renderPdf`  / wasm `bm_render_pdf`  : the document as PDF bytes
//!   * `measure` -> `Renderer.measurePdf` / wasm `bm_measure_pdf` : `{"width":..,"height":..}` in CSS px
//!
//! Both are called by src/render.zig *after* `beginCall()` (per-call arena reset), and only when
//! `config.enable_pdf` is true, so builds without the flag carry none of this. Everything is allocated
//! from `r.arena` and the result lives there (render.zig stores it in `r.result`).
//!
//! `render` parses and validates the options (options.zig), lays the document out (viewport: one page;
//! paged: at the page area's width with an unbounded height, broken into pages by layout/fragment.zig)
//! and writes it through the emitter (emit.zig: graphics, text with embedded font subsets; one page per
//! page kept by `pageRanges`). Paged documents go through paged.zig: `@page` rules (page_rules.zig,
//! page_names.zig), header / footer bands (bands.zig: measured, reserved in the `auto` margins, drawn in
//! the margins per page), page counters (counters.zig, settled over up to three passes) and list markers
//! (markers.zig). Links, outline and attachments are in interactive.zig / attach.zig, Info and XMP in
//! metadata.zig, the structure tree in tags.zig / tagdoc.zig, PDF/A and PDF/UA in conform.zig.
const std = @import("std");
const rt = @import("../render.zig");
const json = @import("../json.zig");
const style = @import("../style/style.zig");
const opt = @import("options.zig");
const emitter = @import("emit.zig");
const paged = @import("paged.zig");

const Renderer = rt.Renderer;
const Frame = rt.Frame;
const SourceKind = rt.SourceKind;
const Error = rt.Error;
const Allocator = std.mem.Allocator;

pub fn needs(r: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
    const a = r.arena.allocator();
    var o = try parseOptions(r, opts_json);
    try poolStyles(a, &o, kind, source);
    const listed = blk: {
        if (opts_json.len == 0) break :blk &.{};
        const v = json.parse(a, opts_json) catch break :blk &.{};
        break :blk try @import("needs.zig").parseListed(a, v.get("listedFonts"));
    };
    var collector: @import("needs.zig").Collector = .{ .a = a, .listed = listed };
    const main = try buildFrameEx(r, a, o, kind, source, .needs, null, null);
    try collector.collect(&main);
    const p = o.pages;
    for ([_]?opt.Band{ o.header, o.footer, p.first.header, p.first.footer, p.last.header, p.last.footer, p.odd.header, p.odd.footer, p.even.header, p.even.footer }) |band| if (band) |b| {
        const f = switch (b) {
            .off => continue,
            .html => |h| try buildFrameEx(r, a, o, .html, h, .needs, null, null),
            .node => |n| try buildFrameEx(r, a, o, .json, "", .needs, null, n),
        };
        try collector.collect(&f);
    };
    return collector.finish();
}

pub const options = opt;

/// Everything `emit` needs besides the frame.
pub const Input = struct {
    r: *Renderer,
    opts: opt.PdfOptions,
    kind: SourceKind,
    source: []const u8,
    /// Flate-compress the streams (off: readable output for tests)
    compress: bool = true,
};

/// (tests) `render` with readable output: no stream is compressed, so content streams and the
/// structure elements can be searched as text.
pub fn renderReadable(r: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
    r.beginCall();
    const o = try parseOptions(r, opts_json);
    return emit(r.arena.allocator(), .{ .r = r, .opts = o, .kind = kind, .source = source, .compress = false });
}

/// takumi-pdf `render`: `source` (JSON node tree or HTML, per `kind`) -> PDF bytes in the call arena.
///
/// Errors: `error.Invalid` after `r.setErr(message, "")` (options / layout problems),
/// `error.OutOfMemory`. Binary resources of the call (images, attachment bytes) are in `r.images`
/// (looked up by id; attachments are already resolved into `PdfOptions.attachments[i].data`).
pub fn render(r: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
    // (a long document's lists grow large in the call arena: their old buffers go back at once)
    r.arena.release_freed = true;
    defer r.arena.release_freed = false;
    const a = r.arena.allocator();
    var o = try parseOptions(r, opts_json);
    try poolStyles(a, &o, kind, source);
    const input: Input = .{ .r = r, .opts = o, .kind = kind, .source = source };
    return emit(a, input);
}

/// takumi-pdf-js `read_document`: the `<style>` sheets of the HTML document and of every HTML band (header,
/// footer, then the `pages` rules' first / last / odd / even header and footer) are appended to `css`, so
/// every one of them styles the document and every band alike (and an `@page` rule in a band's sheet is a
/// page rule). Skipped when it changes nothing: no band, or no `<style>` anywhere.
pub fn poolStyles(a: Allocator, o: *opt.PdfOptions, kind: SourceKind, source: []const u8) Error!void {
    if (comptime !@import("../config.zig").enable_html) return;
    const p = o.pages;
    const bands = [_]?opt.Band{ o.header, o.footer, p.first.header, p.first.footer, p.last.header, p.last.footer, p.odd.header, p.odd.footer, p.even.header, p.even.footer };
    var any_band = false;
    var styled = kind == .html and hasStyleTag(source);
    for (bands) |b| if (b) |x| switch (x) {
        .off => {},
        .node => any_band = true,
        .html => |h| {
            any_band = true;
            styled = styled or hasStyleTag(h);
        },
    };
    if (!any_band or !styled) return;
    const html = @import("../html/html.zig");
    var items: std.ArrayList(json.Value) = .empty;
    if (o.css) |c| switch (c) {
        .array => |arr| try items.appendSlice(a, arr),
        else => try items.append(a, c),
    };
    const sources = [_]?[]const u8{if (kind == .html) source else null} ++ blk: {
        var hs: [bands.len]?[]const u8 = undefined;
        for (bands, 0..) |b, i| hs[i] = if (b) |x| switch (x) {
            .html => |h| h,
            else => null,
        } else null;
        break :blk hs;
    };
    for (sources) |s0| {
        const s = s0 orelse continue;
        if (!hasStyleTag(s)) continue;
        const doc = html.parse(a, s) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue, // (the frame reports it)
        };
        for (doc.styles) |t| try items.append(a, .{ .string = t });
    }
    o.css = .{ .array = items.items };
    o.pooled_styles = true;
}

/// Bytes some image decoder may read: a raster format bm-render sniffs, SVG / XML text, or the magic of
/// ICO, TIFF, AVIF / HEIF (ISO-BMFF), QOI, DDS, farbfeld, PNM.
fn looksLikeImage(d: []const u8) bool {
    if (@import("../codec/codec.zig").sniff(d) != .unknown) return true;
    const t = std.mem.trimStart(u8, d, " \t\r\n\xEF\xBB\xBF");
    if (t.len > 0 and t[0] == '<') return true;
    if (d.len >= 4 and std.mem.eql(u8, d[0..4], "\x00\x00\x01\x00")) return true;
    if (d.len >= 4 and (std.mem.eql(u8, d[0..4], "II*\x00") or std.mem.eql(u8, d[0..4], "MM\x00*"))) return true;
    if (d.len >= 12 and std.mem.eql(u8, d[4..8], "ftyp")) return true;
    if (d.len >= 4 and (std.mem.eql(u8, d[0..4], "qoif") or std.mem.eql(u8, d[0..4], "DDS "))) return true;
    if (d.len >= 8 and std.mem.eql(u8, d[0..8], "farbfeld")) return true;
    if (d.len >= 2 and d[0] == 'P' and d[1] >= '1' and d[1] <= '7') return true;
    return false;
}

fn hasStyleTag(s: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '<')) |k| : (i = k + 1) {
        if (k + 6 <= s.len and std.ascii.eqlIgnoreCase(s[k + 1 .. k + 6], "style")) return true;
    }
    return false;
}

/// takumi-pdf `measure`: the laid-out size of `source` in CSS px as `{"width":w,"height":h}`.
/// Page options lay out at the full page width with unbounded height (how a header / footer band is
/// measured, its `pageNumber` / `totalPages` hooks holding three-digit counters, target hooks empty);
/// a viewport lays out at the viewport, hooks untouched. Margins do not matter.
pub fn measure(r: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
    const a = r.arena.allocator();
    const o = try parseOptions(r, opts_json);
    // (page options: like a band, with three-digit page counters: paged.zig)
    var vf: Frame = undefined;
    const f: *const Frame = if (o.geometry == .page) try paged.measureBand(r, a, o, try cssWithVariables(a, o), kind, source) else blk: {
        vf = try buildFrame(r, a, o, kind, source, .band);
        break :blk &vf;
    };
    const l = f.tree.layout(f.nodes.items[f.root].lid);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"width\":");
    try rt.writeNum(a, &out, l.w);
    try out.appendSlice(a, ",\"height\":");
    try rt.writeNum(a, &out, l.h);
    try out.append(a, '}');
    return out.items;
}

fn parseOptions(r: *Renderer, opts_json: []const u8) Error!opt.PdfOptions {
    const a = r.arena.allocator();
    // Binary resources the JS binding moved into the renderer (attachment `dataRef`s).
    const blobs = try a.alloc(opt.Blob, r.images.items.len);
    for (r.images.items, 0..) |e, i| blobs[i] = .{ .id = e.src, .data = e.data };
    var diag: opt.Diag = .{};
    r.limits = .{};
    var o = blk: {
        if (opts_json.len == 0) break :blk opt.PdfOptions{};
        const v = json.parse(a, opts_json) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                r.setErr("invalid options JSON", "");
                return error.Invalid;
            },
        };
        // (`limits`: bm-render's own option, src/render.zig `Limits`)
        if (v == .object) try r.parseLimits(v.get("limits"));
        break :blk opt.fromValue(a, v, blobs, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => {
                r.setErr(diag.message(), "");
                return error.Invalid;
            },
        };
    };
    // takumi-pdf-js `decode_images`: every `images` entry is decoded before layout, and one in no image format
    // fails the render (bm-render decodes when an image is drawn: only bytes that are no image at all are
    // rejected here, so a format bm reads and takumi does not, or the other way round, is not)
    for (r.images.items) |e| {
        if (e.width != 0 or std.mem.startsWith(u8, e.src, "bm-att:")) continue;
        if (!looksLikeImage(e.data)) {
            r.setErr("An error occurred while decoding the image data: the image format is not supported", "");
            return error.Invalid;
        }
    }
    if (o.background_color) |c| {
        // (takumi-pdf-js `page_background`: only `ColorInput::Value` is a colour, `currentColor` is
        // not; the colour is the value's first component, what follows it is not read)
        const first = firstComponent(c);
        const parsed = style.color.parse(first) catch null;
        o.background_color = first;
        if (parsed == null or parsed.? == .current) {
            r.setErr("backgroundColor is not a color: ", c);
            return error.Invalid;
        }
    }
    return o;
}

/// The first component value of `s` (a token, or a function with its arguments), trimmed.
fn firstComponent(s_in: []const u8) []const u8 {
    const s = std.mem.trim(u8, s_in, " \t\r\n\x0c");
    var depth: usize = 0;
    for (s, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        ' ', '\t', '\r', '\n', '\x0c' => if (depth == 0) return s[0..i],
        else => {},
    };
    return s;
}

const Mode = enum {
    needs,
    /// the main document: paged content width / viewport
    document,
    /// a band or `measure`: full page width, unbounded height
    band,
};

/// Builds and lays out the frame for `source` under `o`, like `renderSvgImpl`. Paged documents
/// (`.document` mode with page geometry) are laid out for a page area of `area` (the content box
/// of the first page: `Frame.setPaged`; `paginate` is the caller's); bands and `measure` at the
/// full page width with an unbounded height (takumi `band_viewport`).
pub fn buildFrame(r: *Renderer, a: Allocator, o: opt.PdfOptions, kind: SourceKind, source: []const u8, mode: Mode) Error!Frame {
    return buildFrameEx(r, a, o, kind, source, mode, null, null);
}

const Area = struct { width: f32, height: f32 };

/// `buildFrame` with the page area of a paged document and `pre`, an already parsed JSON node (a
/// band given as a node).
fn buildFrameEx(r: *Renderer, a: Allocator, o: opt.PdfOptions, kind: SourceKind, source: []const u8, mode: Mode, area: ?Area, pre: ?json.Value) Error!Frame {
    var ro: rt.Options = .{ .lang = o.lang, .font_families = o.font_families };
    switch (o.geometry) {
        .viewport => |v| {
            ro.width = v.width;
            ro.height = v.height;
        },
        .page => |p| ro.width = @intFromFloat(@max(1, @min(p.width, 16384))),
    }
    ro.css = try cssWithVariables(a, o);
    var f: Frame = .{ .r = r, .a = a, .opts = ro, .tree = rt.LTree.init(a), .ctx = undefined, .pre = pre, .needs_only = mode == .needs };
    f.tree.paged.pdf = true;
    f.tree.paged.skip_dom_styles = o.pooled_styles;
    if (o.geometry == .page and mode != .band) {
        const ar = area orelse blk: {
            const p = o.geometry.page;
            const m = p.resolveMargins(null, null);
            break :blk Area{ .width = @max(1, p.width - m.left - m.right), .height = @max(1, p.height - m.top - m.bottom) };
        };
        f.setPaged(ar.width, ar.height);
    }
    try f.prepare(kind, source);
    if (mode != .needs) try @import("text.zig").requireFont(&f, o.uncovered_text == .blank);
    return f;
}

/// `css` plus the `cssVariables` as one `:root { ... }` rule.
pub fn cssWithVariables(a: Allocator, o: opt.PdfOptions) Error!?json.Value {
    if (o.css_variables.len == 0) return o.css;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, ":root{");
    for (o.css_variables) |kv| {
        try buf.appendSlice(a, kv[0]);
        try buf.append(a, ':');
        try buf.appendSlice(a, kv[1]);
        try buf.append(a, ';');
    }
    try buf.append(a, '}');
    const vars: json.Value = .{ .string = buf.items };
    var items: std.ArrayList(json.Value) = .empty;
    if (o.css) |c| switch (c) {
        .array => |arr| try items.appendSlice(a, arr),
        else => try items.append(a, c),
    };
    try items.append(a, vars);
    return .{ .array = items.items };
}

/// THE PLUG-IN POINT. Contract: allocate from `a` (the call arena), return the complete PDF file,
/// report problems with `input.r.setErr(msg, "")` + `error.Invalid`. Options are fully validated
/// already (options.zig).
///
/// Viewport: one page of the viewport's size (its height, or the content's when it has none), the
/// whole frame on it. Paged (takumi-pdf `PageDrawing`): margins resolved against the measured
/// header / footer bands, the content laid out at the page area's width with an unbounded height,
/// broken into pages (`Frame.paginate`); every page kept by `pageRanges` shows its window of the
/// frame in its content box, plus its repeats. The paper colour (`backgroundColor`) fills every
/// page (the root element's own background is not propagated, as in takumi-pdf).
fn emit(a: Allocator, input: Input) Error![]const u8 {
    const r = input.r;
    const o = input.opts;

    var background: ?style.Color = null;
    if (o.background_color) |c| background = (style.color.parse(c) catch unreachable).resolve(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
    const policy: emitter.DocOptions = .{ .uncovered = switch (o.uncovered_text) {
        .@"error" => .@"error",
        .placeholder => .placeholder,
        .blank => .blank,
    }, .opts = &o, .compress = input.compress }; // [interactive] `.opts`: metadata, outline, attachments, lang

    switch (o.geometry) {
        .viewport => |v| {
            var f = try buildFrame(r, a, o, input.kind, input.source, .document);
            // A viewport render is one page, so the ranges only have page 1 to keep.
            var sel = opt.PageSelection.init(o.page_ranges);
            _ = try sel.pushPage(a);
            try finishSelection(r, &sel);
            const w: f32 = @floatFromInt(v.width);
            // takumi-pdf `SinglePage::compose`: without a height the page is as tall as the root's
            // margin box reaches, unrounded (an out-of-flow root reaches nothing); a page without
            // height is `InvalidPageSize`
            const h: f32 = if (v.height) |vh| @floatFromInt(vh) else blk: {
                const rn = f.nodes.items[f.root];
                if (rn.cs.position == .absolute or rn.cs.position == .fixed) break :blk 0;
                break :blk f.rootBlockEnd();
            };
            if (!(h > 0) or !std.math.isFinite(h)) {
                r.setErr("Page size must be finite and larger than zero", "");
                return error.Invalid;
            }
            const pages = [_]emitter.PageBox{.{ .width = w, .height = h, .content = .{ .x = 0, .y = 0, .w = w, .h = h }, .background = background }};
            const windows = [_]emitter.Window{.{}};
            return emitter.writeDocument(a, &f, &pages, &windows, policy);
        },
        .page => |p| {
            // bands, margins, pagination and page counters (paged.zig / bands.zig / counters.zig);
            // `doc.frame` is the content, paginated (`counters.anchor` / `anchorPage`: the page an
            // element with an `id` landed on)
            // (a long document cut at forced page breaks: a part at a time, chunks.zig)
            if (try paged.writeChunked(r, a, o, try cssWithVariables(a, o), input.kind, input.source, p, background, policy)) |bytes| return bytes;
            const doc = try paged.layOut(r, a, o, try cssWithVariables(a, o), input.kind, input.source, p, background);
            @import("../memtrace.zig").mark("pdf: laid out, pages listed");
            // (the layout is freed once the file is written: the result is in `a`)
            defer doc.release(r);
            return emitter.writeDocument(a, doc.frame, doc.pages, doc.windows, policy);
        },
    }
}

fn finishSelection(r: *Renderer, sel: *const opt.PageSelection) Error!void {
    var diag: opt.Diag = .{};
    sel.finish(&diag) catch {
        r.setErr(diag.message(), "");
        return error.Invalid;
    };
}

// ---- tests (page geometry, document structure, layout and option errors; the graphics pass)

const config = @import("../config.zig");

test "PDF needs uses computed styles and all bands before font loading or layout" {
    if (comptime !@import("../config.zig").enable_pdf) return;
    const r = Renderer.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer r.destroy();
    const result = try r.needsPdf(.html,
        \\<style>.used{background:url(body.png)}.unused{background:url(unused.png)}@font-face{font-family:Band;src:url(band.woff2)}</style><p class="used">body</p><div style="display:none"><img src="hidden.png"></div>
    ,
        \\{"footer":"<p style='font-family:Band'>Ж</p>","pages":{"first":{"header":"<img src='header.png'>"}}}
    );
    const value = try json.parse(r.arena.allocator(), result);
    const images = value.get("images").?.array;
    try std.testing.expectEqual(@as(usize, 2), images.len);
    try std.testing.expect(std.mem.indexOf(u8, result, "body.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "header.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "hidden.png") == null);
    try std.testing.expect(std.mem.indexOf(u8, value.get("text").?.string, "Ж") != null);
    try std.testing.expect(value.get("faces").?.array.len > 0);
}

test "PDF needs: the listed font subsets font fallback reaches (takumi needs.rs)" {
    if (comptime !@import("../config.zig").enable_pdf) return;
    const r = Renderer.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer r.destroy();
    const Case = struct { html: []const u8, opts: []const u8, fonts: []const u8 };
    const latin = "\"ranges\":[[0,591]]";
    const cyr = "\"ranges\":[[1024,1279]]";
    const cases = [_]Case{
        // only the first family that claims a character
        .{ .html = "<p style='font-family:A,B'>Hello</p>", .opts = "{\"listedFonts\":[{\"id\":0,\"name\":\"A\"," ++ latin ++ "},{\"id\":1,\"name\":\"B\"," ++ latin ++ "}]}", .fonts = "[0]" },
        // a later family for a character only it claims
        .{ .html = "<p style='font-family:A,B'>HiЖ</p>", .opts = "{\"listedFonts\":[{\"id\":0,\"name\":\"A\"," ++ latin ++ "},{\"id\":1,\"name\":\"B\"," ++ cyr ++ "}]}", .fonts = "[0,1]" },
        // the weight the text matches
        .{ .html = "<p style='font-family:A'>a<b>b</b></p>", .opts = "{\"listedFonts\":[{\"id\":0,\"name\":\"A\",\"weight\":[400,400]," ++ latin ++ "},{\"id\":1,\"name\":\"A\",\"weight\":[700,700]," ++ latin ++ "}]}", .fonts = "[0,1]" },
        .{ .html = "<p style='font-family:A'>a</p>", .opts = "{\"listedFonts\":[{\"id\":0,\"name\":\"A\",\"weight\":[400,400]," ++ latin ++ "},{\"id\":1,\"name\":\"A\",\"weight\":[700,700]," ++ latin ++ "}]}", .fonts = "[0]" },
        // the unicode-range subsets the text falls in
        .{ .html = "<p style='font-family:A'>Ж</p>", .opts = "{\"listedFonts\":[{\"id\":0,\"name\":\"A\"," ++ latin ++ "},{\"id\":1,\"name\":\"A\"," ++ cyr ++ "}]}", .fonts = "[1]" },
        // the render's fontFamilies after the element's families; a family nothing uses: nothing
        .{ .html = "<p style='font-family:Missing'>a</p>", .opts = "{\"fontFamilies\":[\"B\"],\"listedFonts\":[{\"id\":0,\"name\":\"A\"," ++ latin ++ "},{\"id\":1,\"name\":\"B\"," ++ latin ++ "}]}", .fonts = "[1]" },
        // in a band too
        .{ .html = "<p style='font-family:A'>a</p>", .opts = "{\"footer\":\"<p style='font-family:A'>Ж</p>\",\"listedFonts\":[{\"id\":0,\"name\":\"A\"," ++ latin ++ "},{\"id\":1,\"name\":\"A\"," ++ cyr ++ "},{\"id\":2,\"name\":\"A\",\"ranges\":[[1328,1423]]}]}", .fonts = "[0,1]" },
        // a page counter hook draws its style's numerals, which no text of the document holds
        // (takumi-pdf-js render.test.ts: keeps a face the page counter needs but the document never uses)
        .{ .html = "<p style='font-family:A'>a</p>", .opts = "{\"footer\":\"<div style='font-family:A'><span class='totalPages trad-chinese-informal'></span></div>\",\"listedFonts\":[{\"id\":0,\"name\":\"A\"," ++ latin ++ "},{\"id\":1,\"name\":\"A\",\"ranges\":[[19968,40959]]},{\"id\":2,\"name\":\"A\"," ++ cyr ++ "}]}", .fonts = "[0,1]" },
        .{ .html = "<p style='font-family:A'>a <span class='pageNumber upper-roman'></span></p>", .opts = "{\"listedFonts\":[{\"id\":0,\"name\":\"A\",\"ranges\":[[97,97]]},{\"id\":1,\"name\":\"A\",\"ranges\":[[65,90]]}]}", .fonts = "[0,1]" },
    };
    for (cases) |c| {
        const result = try r.needsPdf(.html, c.html, c.opts);
        const value = try json.parse(r.arena.allocator(), result);
        var got: std.ArrayList(u8) = .empty;
        try got.append(r.arena.allocator(), '[');
        for (value.get("fonts").?.array, 0..) |id, k| {
            if (k != 0) try got.append(r.arena.allocator(), ',');
            try got.print(r.arena.allocator(), "{d}", .{@as(u32, @intFromFloat(id.asNumber().?))});
        }
        try got.append(r.arena.allocator(), ']');
        std.testing.expectEqualStrings(c.fonts, got.items) catch |err| {
            std.debug.print("case {s} {s}\n", .{ c.html, c.opts });
            return err;
        };
    }
    // a registered face that draws the character ends the walk
    _ = try r.registerFont(try std.testing.allocator.dupe(u8, @embedFile("../font/testdata/Inter-Regular.ttf")), "A", 0, -1, null);
    const drawn = try r.needsPdf(.html, "<p style='font-family:A,B'>a</p>", "{\"listedFonts\":[{\"id\":1,\"name\":\"B\"," ++ latin ++ "}]}");
    try std.testing.expect(std.mem.indexOf(u8, drawn, "\"fonts\":[]") != null);
    // ... unless it lacks the glyph: the walk moves on
    const missing = try r.needsPdf(.html, "<p style='font-family:A,B'>\u{4e2d}</p>", "{\"listedFonts\":[{\"id\":1,\"name\":\"B\",\"ranges\":[[19968,40959]]}]}");
    try std.testing.expect(std.mem.indexOf(u8, missing, "\"fonts\":[1]") != null);
}

test "renderPdf: not supported without the flag, a page of the requested size with it" {
    const gpa = std.testing.allocator;
    const r = Renderer.create(gpa).?;
    defer r.destroy();
    const node = "{\"type\":\"container\",\"style\":{\"width\":50,\"height\":40}}";
    if (comptime !config.enable_pdf) {
        try std.testing.expectError(error.Invalid, r.renderPdf(.json, node, ""));
        try std.testing.expectEqualStrings("renderPdf is not supported by this build", r.err);
        try std.testing.expectError(error.Invalid, r.measurePdf(.json, node, ""));
        return;
    }
    const pdf = try r.renderPdf(.json, node, "{\"viewport\":{\"width\":600,\"height\":300}}");
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.7\n"));
    try std.testing.expect(std.mem.endsWith(u8, pdf, "%%EOF"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/MediaBox[0 0 450 225]") != null);
    // paged A4 by default: ~595.276 x 841.89 pt
    const a4 = try r.renderPdf(.json, node, "");
    try std.testing.expect(std.mem.indexOf(u8, a4, "/MediaBox[0 0 595.27") != null);
    // the cross-reference stream is where startxref says
    const sx = std.mem.lastIndexOf(u8, a4, "startxref\n").? + "startxref\n".len;
    const xref_at = try std.fmt.parseInt(usize, a4[sx..std.mem.indexOfPos(u8, a4, sx, "\n").?], 10);
    try std.testing.expect(std.mem.indexOf(u8, a4[xref_at..@min(a4.len, xref_at + 200)], "/Type/XRef") != null);
    // content-sized viewport page (no height): the node's height
    const fit = try r.renderPdf(.json, node, "{\"viewport\":{\"width\":100}}");
    try std.testing.expect(std.mem.indexOf(u8, fit, "/MediaBox[0 0 75 30]") != null);
    // ... unrounded, the root's margin box; none at all is takumi-pdf's InvalidPageSize
    const frac = try r.renderPdf(.json, "{\"type\":\"container\",\"style\":{\"height\":10.2,\"margin\":5}}", "{\"viewport\":{\"width\":100}}");
    try std.testing.expect(std.mem.indexOf(u8, frac, "/MediaBox[0 0 75 15.140625]") != null);
    try std.testing.expectError(error.Invalid, r.renderPdf(.json, "{\"type\":\"container\"}", "{\"viewport\":{\"width\":100}}"));
    try std.testing.expectEqualStrings("Page size must be finite and larger than zero", r.err);
    try std.testing.expectEqualStrings("{\"width\":100,\"height\":0}", try r.measurePdf(.json, "{\"type\":\"container\"}", "{\"viewport\":{\"width\":100}}"));
    // measure
    const m = try r.measurePdf(.json, node, "{\"size\":\"letter\"}");
    try std.testing.expectEqualStrings("{\"width\":50,\"height\":40}", m);
    // option and layout errors
    try std.testing.expectError(error.Invalid, r.renderPdf(.json, node, "{\"size\":\"x\"}"));
    try std.testing.expectEqualStrings("unknown page size: x", r.err);
    try std.testing.expectError(error.Invalid, r.renderPdf(.json, "{\"type\":\"container\",\"style\":{\"width\":\"banana\"}}", ""));
    try std.testing.expectError(error.Invalid, r.renderPdf(.json, node, "{\"backgroundColor\":\"notacolor\"}"));
    try std.testing.expectEqualStrings("backgroundColor is not a color: notacolor", r.err);
}

test "renderPdf: the bundled Geist draws text no registered font covers; without any font the render fails" {
    if (comptime !config.enable_pdf) return;
    const r = Renderer.create(std.testing.allocator).?;
    defer r.destroy();
    const node = "{\"type\":\"text\",\"text\":\"Hi\"}";
    const vp = "{\"viewport\":{\"width\":100,\"height\":50}}";
    // takumi-pdf: every renderer starts with the last-resort Geist, and `clearFonts()` goes back to it
    _ = try r.renderPdf(.json, node, vp);
    try std.testing.expectEqualStrings("Geist", r.fonts.faces.items[0].family);
    try std.testing.expect(r.fonts.faces.items[0].last_resort);
    r.clearFonts();
    _ = try r.measurePdf(.json, node, "");
    _ = try r.renderPdf(.json, node, vp);
    // a registered family comes before it, whatever order they were registered in
    var out: [8]@import("../font/collection.zig").FaceId = undefined;
    _ = try r.registerFont(try std.testing.allocator.dupe(u8, @embedFile("../font/testdata/Inter-Regular.ttf")), "Inter", 0, -1, null);
    const order = r.fonts.match(&.{"sans-serif"}, 400, false, &out);
    try std.testing.expectEqualStrings("Inter", r.fonts.face(order[0]).family);
    try std.testing.expectEqualStrings("Geist", r.fonts.face(order[order.len - 1]).family);
    // with Geist unregistered too, text fails, naming it
    r.clearFonts();
    _ = try r.renderPdf(.json, "{\"type\":\"text\",\"text\":\" \"}", vp);
    _ = r.unregisterFont("Geist");
    try std.testing.expectError(error.Invalid, r.renderPdf(.json, node, vp));
    try std.testing.expect(std.mem.indexOf(u8, r.err, "No font is registered to draw H (U+0048), i (U+0069).") != null);
    try std.testing.expectError(error.Invalid, r.measurePdf(.json, node, ""));
    // `uncoveredText: "blank"` asked for nothing to be drawn; a tree without text needs no font
    _ = try r.renderPdf(.json, node, "{\"viewport\":{\"width\":100,\"height\":50},\"uncoveredText\":\"blank\"}");
    _ = try r.renderPdf(.json, "{\"type\":\"text\",\"text\":\" \\n \"}", vp);
}

/// Renders `node` (JSON) on a viewport page with uncompressed streams (tests).
fn testRender(r: *Renderer, node: []const u8, vw: u32, vh: u32) Error![]const u8 {
    r.beginCall();
    const a = r.arena.allocator();
    const o: opt.PdfOptions = .{ .geometry = .{ .viewport = .{ .width = vw, .height = vh } } };
    var f = try buildFrame(r, a, o, .json, node, .document);
    const w: f32 = @floatFromInt(vw);
    const h: f32 = @floatFromInt(vh);
    const pages = [_]emitter.PageBox{.{ .width = w, .height = h, .content = .{ .x = 0, .y = 0, .w = w, .h = h } }};
    const windows = [_]emitter.Window{.{}};
    return emitter.writeDocument(a, &f, &pages, &windows, .{ .compress = false });
}

fn expectHas(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing: {s}\nin:\n{s}\n", .{ needle, hay[0..@min(hay.len, 4000)] });
        return error.TestUnexpectedResult;
    }
}

test "graphics pass: backgrounds, borders, opacity groups, gradients (takumi-pdf operators)" {
    if (comptime !config.enable_pdf) return;
    const gpa = std.testing.allocator;
    const r = Renderer.create(gpa).?;
    defer r.destroy();
    // box-chrome.pdf without its text: page background, rounded bordered card in an opacity group
    const chrome = try testRender(r,
        \\{"type":"container","style":{"display":"flex","width":"100%","height":"100%","padding":24,"backgroundColor":"#ebf0fa"},
        \\ "children":[{"type":"container","style":{"display":"flex","width":300,"height":120,"padding":16,"backgroundColor":"#ffffff",
        \\   "border":"3px solid #b42828","borderRadius":16,"opacity":0.8}}]}
    , 400, 200);
    try expectHas(chrome, "q 0.75 0 0 -0.75 0 150 cm 0.9216 0.9412 0.9804 rg 0 0 400 200 re\nf\nQ\nq 0.75 0 0 -0.75 0 150 cm/g0 gs/x0 Do\nQ");
    try expectHas(chrome, "<</Type/ExtGState/ca 0.8/CA 0.8>>");
    try expectHas(chrome, "/Subtype/Form/Resources");
    try expectHas(chrome, "/Group<</Type/Group/S/Transparency/I true/CS/DeviceRGB>>");
    try expectHas(chrome, "q 1 1 1 rg 40 24 m 308 24 l");
    try expectHas(chrome, "0.7059 0.1569 0.1569 rg 40 24 m 308 24 l");
    try expectHas(chrome, "h\nf*\nQ");
    // gradients: an axial shading pattern placed through the page matrix
    const grad = try testRender(r,
        \\{"type":"container","style":{"display":"flex","width":"100%","height":"100%","padding":20},
        \\ "children":[{"type":"container","style":{"width":110,"height":110,"backgroundImage":"linear-gradient(135deg, #ff5f6d, #3a1c71)"}}]}
    , 440, 160);
    try expectHas(grad, "q 15 105 82.5 -82.5 re\nW\nn\nq 0.75 0 0 -0.75 0 120 cm/Pattern cs/p0 scn 20 20 110 110 re\nf\nQ\nQ");
    try expectHas(grad, "<</FunctionType 2/Range[0 1 0 1 0 1]/C0[1 0.3725 0.4275]/C1[0.2275 0.1098 0.4431]/Domain[0 1]/N 1>>");
    try expectHas(grad, "<</ShadingType 2/ColorSpace/DeviceRGB/AntiAlias false/Function 3 0 R/Coords[20 20 130 130]/Extend[true true]>>");
    try expectHas(grad, "<</Type/Pattern/PatternType 2/Shading 4 0 R/Matrix[0.75 0 0 -0.75 0 120]>>");
    // a blur filter has no PDF equivalent: the render stops, naming it (takumi-pdf UnsupportedFilter)
    try std.testing.expectError(error.Invalid, testRender(r,
        \\{"type":"container","style":{"width":10,"height":10,"backgroundColor":"red","filter":"blur(2px)"}}
    , 20, 20));
    try std.testing.expectEqualStrings("A PDF cannot draw filter: blur(2px)", r.err);
}
