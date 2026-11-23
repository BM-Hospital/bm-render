//! Fuzz targets for every component that parses untrusted input (docs/en/building-from-source.md,
//! "Fuzzing").
//!
//! * `zig build test` runs every target once per seed (the `std.testing.fuzz` corpus) plus the
//!   empty input: a cheap smoke test.
//! * `zig build test --fuzz=<N> -Dtest-filter="fuzz: png"` runs Zig's coverage-guided fuzzer
//!   on one target (crashes are saved under `.zig-cache/f/`).
//! * `zig build fuzz -- <target...|all> [--seconds S] [--seed N] [--slow-ms MS]` runs the
//!   deterministic mutation driver (src/fuzz_main.zig, ReleaseSafe) on the same targets;
//!   `--replay FILE` re-runs one input.
//!
//! A target must never panic, trip a safety check, leak, or take more than `slow_ns` for one
//! input; errors are expected and ignored. Memory is capped by `Limited` (exceeding it is plain
//! `error.OutOfMemory`, never a crash) and images by `limits`. Inputs that once failed live in
//! src/testdata/fuzz/regress/ and are replayed by the "fuzz regressions" test.
const std = @import("std");
const builtin = @import("builtin");
const codec = @import("codec/codec.zig");
const woff = @import("woff/woff.zig");
const brotli = @import("woff/brotli.zig");
const font = @import("font/font.zig");
const html = @import("html/html.zig");
const css = @import("css/css.zig");
const json = @import("json.zig");
const svg = @import("svg/svg.zig");
const raster = @import("raster/raster.zig");
const render = @import("render.zig");

pub const Target = enum {
    png,
    jpeg,
    gif,
    webp,
    inflate,
    brotli,
    woff,
    font,
    html,
    css,
    json,
    svg,
    render_html,
    render_json,
};

/// Largest input a target is fed (the fuzzer never generates more; bigger seeds are skipped).
pub const max_input = 256 << 10;
/// Memory cap for one input (live bytes).
pub const max_memory: usize = 512 << 20;
/// Image limits used by the codec targets (the renderer uses its own defaults).
pub const limits: codec.Limits = .{ .max_pixels = 4 << 20 };
/// One input taking longer than this is reported as a failure (DoS-style slowness). Debug
/// builds are ~10x slower than ReleaseSafe, so they get more room.
pub const slow_ns: u64 = if (builtin.mode == .debug) 8 * std.time.ns_per_s else 1 * std.time.ns_per_s;

/// Allocator wrapper that fails once more than `limit` bytes are live.
pub const Limited = struct {
    inner: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *Limited) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn grow(self: *Limited, old: usize, new: usize) bool {
        if (new > old and new - old > self.limit - self.used) return false;
        self.used = self.used - old + new;
        self.peak = @max(self.peak, self.used);
        return true;
    }
    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        if (!self.grow(0, len)) return null;
        return self.inner.rawAlloc(len, al, ra) orelse {
            self.used -= len;
            return null;
        };
    }
    fn resize(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        if (!self.grow(mem.len, new_len)) return false;
        if (self.inner.rawResize(mem, al, new_len, ra)) return true;
        self.used = self.used - new_len + mem.len;
        return false;
    }
    fn remap(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        if (!self.grow(mem.len, new_len)) return null;
        return self.inner.rawRemap(mem, al, new_len, ra) orelse {
            self.used = self.used - new_len + mem.len;
            return null;
        };
    }
    fn free(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, ra: usize) void {
        const self: *Limited = @ptrCast(@alignCast(ctx));
        self.used -= mem.len;
        self.inner.rawFree(mem, al, ra);
    }
};

/// Runs one input through `target`. Every error of the code under test is swallowed (bad input
/// is expected to fail); only a panic, safety check, leak (with a leak-checking `gpa`) or
/// `error.SlowInput` from the caller's timer is a finding.
pub fn run(target: Target, gpa: std.mem.Allocator, input: []const u8) void {
    var lim: Limited = .{ .inner = gpa, .limit = max_memory };
    const a = lim.allocator();
    switch (target) {
        .png, .jpeg, .gif, .webp => image(a, input),
        .inflate => inflateTarget(a, input),
        .brotli => if (brotli.decompressAlloc(a, input, 8 << 20)) |r| a.free(r) else |_| {},
        .woff => if (woff.decode(a, input)) |sf| {
            defer a.free(sf);
            fontTarget(a, sf);
        } else |_| {},
        .font => fontTarget(a, input),
        .html => {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            _ = html.parse(arena.allocator(), input) catch {};
        },
        .json => {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            _ = json.parse(arena.allocator(), input) catch {};
        },
        .css => cssTarget(a, input),
        .svg => svgTarget(a, input),
        .render_html => renderTarget(a, .html, input, null),
        .render_json => renderTarget(a, .json, input, null),
    }
    // Leak check that also works with a non-checking `gpa` (the mutation driver).
    if (lim.used != 0) std.debug.panic("fuzz {t}: {d} bytes leaked", .{ target, lim.used });
}

/// Decode, then walk every frame of an animation.
fn image(a: std.mem.Allocator, input: []const u8) void {
    if (codec.decode(a, input, limits)) |img| img.deinit(a) else |_| {}
    _ = codec.dimensions(input);
    if (codec.frameCount(input) > 1) {
        var an = codec.anim.Animator.init(a, input, limits) catch return;
        defer an.deinit();
        while (an.next() catch null) |_| {}
    }
}

fn inflateTarget(a: std.mem.Allocator, input: []const u8) void {
    if (codec.inflate.zlibDecompressAlloc(a, input, 4 << 20, .{ .verify_checksum = true })) |r| a.free(r) else |_| {}
    if (codec.inflate.inflateAlloc(a, input, 4 << 20)) |r| a.free(r) else |_| {}
    var small: [512]u8 = undefined;
    _ = codec.inflate.zlibDecompressInto(input, &small, .{}) catch {};
}

const OutlineSink = struct {
    n: u32 = 0,
    pub fn moveTo(s: *OutlineSink, x: f32, y: f32) void {
        s.pt(x, y);
    }
    pub fn lineTo(s: *OutlineSink, x: f32, y: f32) void {
        s.pt(x, y);
    }
    pub fn quadTo(s: *OutlineSink, cx: f32, cy: f32, x: f32, y: f32) void {
        s.pt(cx, cy);
        s.pt(x, y);
    }
    pub fn cubicTo(s: *OutlineSink, ax: f32, ay: f32, bx: f32, by: f32, x: f32, y: f32) void {
        s.pt(ax, ay);
        s.pt(bx, by);
        s.pt(x, y);
    }
    pub fn close(_: *OutlineSink) void {}
    fn pt(s: *OutlineSink, x: f32, y: f32) void {
        std.mem.doNotOptimizeAway(x + y);
        s.n += 1;
        // an outline of millions of points from a few KiB of font is a decoding runaway
        if (s.n > 4_000_000) @panic("runaway glyph outline");
    }
};

/// Parses a TrueType / CFF / collection, reads metrics, extracts outlines of a few glyph ids,
/// shapes and lays out a short paragraph.
fn fontTarget(a: std.mem.Allocator, data: []const u8) void {
    var fc: font.FontCollection = .{};
    defer fc.deinit(a);
    const reg = fc.registerAll(a, data, .{}) catch return;
    const cps = [_]u21{ 'A', 'g', 'O', 'f', 'i', 0xe9, 0x1ec7, 0x5d0, 0xe01, 0x4e2d, 0x1f600 };
    var fi: u32 = 0;
    while (fi < @min(reg.count, 4)) : (fi += 1) {
        const f = fc.font(reg.first + @as(font.FaceId, @intCast(fi)));
        var nb: [64]u8 = undefined;
        _ = f.familyName(&nb);
        _ = f.lineMetrics();
        _ = .{ f.xHeight(), f.capHeight(), f.underlinePosition(), f.strikeoutPosition(), f.isItalic() };
        var ab: [4]font.Axis = undefined;
        _ = f.axes(&ab);
        var prev: u16 = 0;
        for (cps) |cp| {
            const g = f.glyphIndex(cp);
            _ = f.advanceWidth(g);
            _ = f.glyphBounds(g);
            _ = f.kerning(prev, g);
            var s: OutlineSink = .{};
            _ = font.emitGlyph(f, g, 24, 3, 40, &s);
            prev = g;
        }
        var g: u32 = 0;
        while (g < @min(@as(u32, f.numGlyphs()), 24)) : (g += 1) {
            var s: OutlineSink = .{};
            _ = f.outline(@intCast(g), &s);
        }
        g = 24;
        while (g < 0x10000) : (g += 4093) {
            var s: OutlineSink = .{};
            _ = f.outline(@intCast(g), &s);
        }
        if (f.isVariable()) {
            const v = f.withVariations(&.{ .{ .tag = "wght".*, .value = 650 }, .{ .tag = "wdth".*, .value = 80 } });
            var s: OutlineSink = .{};
            _ = v.outline(v.glyphIndex('O'), &s);
            _ = v.advanceWidth(v.glyphIndex('O'));
        }
    }
    var p = font.Paragraph.init(a, &fc, &.{.{ .text = "AV To office fi Việt שלום ไทย 中 \u{1f600}", .style = .{ .size = 20 } }}, .{ .max_lines = 2, .ellipsis = true }) catch return;
    defer p.deinit();
    var lay = p.layout(a, 60) catch return;
    defer lay.deinit(a);
    for (lay.glyphs) |pg| {
        var s: OutlineSink = .{};
        _ = font.emitGlyph(fc.font(pg.face), pg.gid, pg.size, pg.x, pg.y, &s);
    }
}

fn cssTarget(a: std.mem.Allocator, input: []const u8) void {
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ar = arena.allocator();
        var sheet: css.Stylesheet = .{};
        css.parse(ar, input, &sheet) catch return;
        _ = css.prepare(ar, &sheet, .{ .viewport_w = 64, .viewport_h = 64 }) catch return;
        _ = css.parseDeclarations(ar, input) catch return;
        _ = css.selector.parseList(ar, input, 0, input.len, .{}, null) catch return;
    }
    // Cascade + selector matching + computed values through the renderer.
    renderTarget(a, .html, css_doc, input);
}

const css_doc =
    \\<div id=root class="a b" lang=en dir=ltr><p class=a>Text <b>bold</b> <a href="#x">link</a></p>
    \\<ul><li>one</li><li class=b>two</li><li data-x="1">three</li></ul><span></span><input type=checkbox checked>
    \\<table><tr><td>1</td><td>2</td></tr></table><img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" alt=x></div>
;

fn svgTarget(a: std.mem.Allocator, input: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const doc = svg.parse(ar, input) catch return;
    _ = svg.intrinsicSize(&doc);
    var pm = raster.Pixmap.init(ar, 64, 64) catch return;
    var rast = raster.Rasterizer.init(a);
    defer rast.deinit();
    svg.render(ar, &rast, &doc, &pm, .{ .x = -1.5, .y = 0.25, .w = 66, .h = 60 }, null, .{}) catch {};
}

/// The renderer with one small font (Geist, static); renders `source` to a 64x64 raw frame.
/// `css_text`: extra stylesheet passed through the `css` option.
fn renderTarget(a: std.mem.Allocator, kind: render.SourceKind, source: []const u8, css_text: ?[]const u8) void {
    const r = render.Renderer.create(a) orelse @panic("fuzz harness: Renderer.create failed");
    defer r.destroy();
    const fdata = a.dupe(u8, @embedFile("woff/testdata/geist.ttf")) catch @panic("fuzz harness: OOM");
    // a setup failure would silently turn the target into a no-op
    _ = r.registerFont(fdata, "", 0, -1, null) catch @panic("fuzz harness: font registration failed");
    var opts: std.ArrayList(u8) = .empty;
    defer opts.deinit(a);
    opts.appendSlice(a, "{\"width\":64,\"height\":64,\"format\":\"raw\"") catch return;
    if (css_text) |c| {
        opts.appendSlice(a, ",\"css\":[") catch return;
        render.writeJsonString(a, &opts, c) catch return;
        opts.appendSlice(a, "]") catch return;
    }
    opts.appendSlice(a, "}") catch return;
    _ = r.renderSource(kind, source, opts.items) catch {};
}

// ---------------------------------------------------------------- seeds

fn embedAll(comptime dir: []const u8, comptime names: []const []const u8) [names.len][]const u8 {
    var out: [names.len][]const u8 = undefined;
    inline for (names, 0..) |n, i| out[i] = @embedFile(dir ++ n);
    return out;
}

const seed_png = embedAll("codec/testdata/", &.{
    "yeecord.png",            "png_suite/rgba8_i.png", "png_suite/rgb16.png", "png_suite/p4_i.png",
    "png_suite/ga16_i.png",   "png_suite/g1.png",      "png_suite/p8.png",    "png_suite/rgb8key.png",
    "png_suite/g16key_i.png", "png_suite/tiny_i.png",
});
const seed_jpeg = embedAll("codec/testdata/", &.{
    "jpeg_b411.jpg",      "jpeg_b420.jpg", "jpeg_b420r.jpg", "jpeg_b422.jpg",  "jpeg_b440.jpg",    "jpeg_b444.jpg",
    "jpeg_gray.jpg",      "jpeg_p333.jpg", "jpeg_p420.jpg",  "jpeg_pgray.jpg", "jpeg_mozb420.jpg", "jpeg_p444.jpg",
    "jpeg_luma_prog.jpg",
});
const seed_gif = embedAll("codec/testdata/", &.{ "anim.gif", "gif_takumi.gif" });
const seed_webp = embedAll("codec/testdata/", &.{
    "webp_takumi.webp",    "webp_lib_pal.webp",  "webp_lib_mix.webp", "webp_lib_photo.webp",
    "vp8_q75.webp",        "vp8_tiny.webp",      "vp8_alpha_ll.webp", "vp8_alpha_raw.webp",
    "vp8_alpha_fast.webp", "vp8_q50simple.webp", "vp8_q85part.webp",  "anim_ll.webp",
    "anim_lossy.webp",     "anim_mixed.webp",    "anim_gif.webp",
});
const seed_inflate = embedAll("testdata/fuzz/", &.{ "text.zlib", "fixed.zlib", "stored.zlib" });
const seed_brotli = embedAll("", &.{
    "woff/testdata/bomb.br",     "testdata/fuzz/brotli_0.br", "testdata/fuzz/brotli_1.br", "testdata/fuzz/brotli_2.br",
    "testdata/fuzz/brotli_3.br", "testdata/fuzz/brotli_4.br", "testdata/fuzz/brotli_5.br",
});
const seed_woff = embedAll("woff/testdata/", &.{ "geist.woff2", "geist.woff", "collection.woff2" });
const seed_font = embedAll("", &.{
    "pdf/testdata/takumi-archivo-wght700.ttf", "font/testdata/CJKLoclTest.otf", "font/testdata/NotoSansHebrew-Regular.ttf",
    "font/testdata/NotoSansThai-Regular.ttf",  "font/testdata/Geist-VF.ttf",
});
const seed_html = embedAll("html/testdata/", &.{
    "font_language_override.html", "image_svg_text.html",    "showcase_grid_hero.html", "style_background_color.html",
    "style_position.html",         "svg_color_filters.html", "table_baseline.html",     "text_align.html",
    "text_basic.html",
});
const seed_svg = embedAll("svg/testdata/", &.{
    "avatar.svg", "effects.svg", "features.svg", "grinning-squinting-face.svg", "hamburger.svg",
    "luma.svg",   "sticker.svg", "takumi.svg",   "waving-hand.svg",
});

/// At most this many seeds come from a JSON fixture file (keeps `zig build test` fast).
const max_extracted = 12;

/// The raw (unprefixed) seed inputs of `target`, allocated from `arena`.
pub fn seeds(arena: std.mem.Allocator, target: Target) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    switch (target) {
        .png => {
            try list.appendSlice(arena, &seed_png);
            // an APNG (2 frames, blend + dispose) built with the encoder
            var px: [4 * 4 * 4]u8 = @splat(0x80);
            var px2: [4 * 4 * 4]u8 = @splat(0x20);
            px2[3] = 0;
            const frames = [_]codec.AnimFrame{ .{ .rgba = &px, .delay_ms = 10 }, .{ .rgba = &px2, .delay_ms = 20 } };
            try list.append(arena, try codec.encodeApng(arena, &frames, 4, 4, .{}));
        },
        .jpeg => try list.appendSlice(arena, &seed_jpeg),
        .gif => try list.appendSlice(arena, &seed_gif),
        .webp => try list.appendSlice(arena, &seed_webp),
        .inflate => try list.appendSlice(arena, &seed_inflate),
        .brotli => try list.appendSlice(arena, &seed_brotli),
        .woff => try list.appendSlice(arena, &seed_woff),
        .font => try list.appendSlice(arena, &seed_font),
        .html, .render_html => try list.appendSlice(arena, &seed_html),
        .svg => try list.appendSlice(arena, &seed_svg),
        .css => try extract(arena, &list, @embedFile("css/testdata/oracle.json"), "cases", "css"),
        .json, .render_json => {
            try extract(arena, &list, @embedFile("layout/testdata/oracle_misc.json"), null, "node");
            try extract(arena, &list, @embedFile("layout/testdata/oracle_inline.json"), null, "node");
            try list.append(arena,
                \\{"type":"container","style":{"display":"flex","width":"100%","height":"100%","backgroundImage":"linear-gradient(red,blue)","padding":4},
                \\"children":[{"type":"text","text":"Hi there","style":{"fontSize":12,"color":"white"}},
                \\{"type":"image","src":"data:image/gif;base64,R0lGODlhAQABAAAAACw=","width":8,"height":8}]}
            );
        },
    }
    return list.items;
}

/// Pulls `field` out of each case of a JSON fixture (`root_key`: object member holding the case
/// array, null = the root is the array) and re-serialises it as a seed. CSS strings are joined.
fn extract(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), text: []const u8, root_key: ?[]const u8, field: []const u8) !void {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const cases = if (root_key) |k| root.object.get(k).?.array.items else root.array.items;
    var n: usize = 0;
    for (cases) |c| {
        if (n == max_extracted) break;
        const v = c.object.get(field) orelse continue;
        const s: []const u8 = switch (v) {
            .array => |arr| blk: {
                var buf: std.ArrayList(u8) = .empty;
                for (arr.items) |e| if (e == .string) {
                    try buf.appendSlice(arena, e.string);
                    try buf.append(arena, '\n');
                };
                break :blk buf.items;
            },
            .string => |s| s,
            else => blk: {
                var node = v;
                try typeNodes(arena, &node);
                break :blk try std.json.Stringify.valueAlloc(arena, node, .{});
            },
        };
        if (s.len == 0) continue;
        try list.append(arena, s);
        n += 1;
    }
}

/// Layout fixtures omit the node `type`: containers have children, text nodes have `text`.
fn typeNodes(arena: std.mem.Allocator, v: *std.json.Value) !void {
    if (v.* != .object) return;
    const o = &v.object;
    if (o.get("type") == null) try o.put(arena, "type", .{ .string = if (o.get("text") != null) "text" else "container" });
    if (o.getPtr("children")) |c| if (c.* == .array) for (c.array.items) |*ch| try typeNodes(arena, ch);
}

// ---------------------------------------------------------------- std.testing.fuzz entry points

var input_buf: [max_input]u8 = undefined;

fn testOne(target: Target, smith: *std.testing.Smith) anyerror!void {
    const n = smith.slice(&input_buf);
    const io = std.testing.io;
    const t0 = std.Io.Clock.awake.now(io);
    run(target, std.testing.allocator, input_buf[0..n]);
    const dt = t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    if (dt > slow_ns) {
        std.debug.print("fuzz {t}: one input of {d} bytes took {d} ms\n", .{ target, n, @divTrunc(dt, std.time.ns_per_ms) });
        return error.SlowInput;
    }
}

/// `std.testing.fuzz` with `target`'s seeds as the corpus (Smith's encoding: u32 LE length + bytes).
fn fuzzTarget(comptime target: Target) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try seeds(a, target);
    var corpus: std.ArrayList([]const u8) = .empty;
    for (raw) |s| {
        if (s.len > max_input) continue;
        const e = try a.alloc(u8, 4 + s.len);
        std.mem.writeInt(u32, e[0..4], @intCast(s.len), .little);
        @memcpy(e[4..], s);
        try corpus.append(a, e);
    }
    try std.testing.fuzz(target, testOne, .{ .corpus = corpus.items });
}

test "fuzz: png" {
    try fuzzTarget(.png);
}
test "fuzz: jpeg" {
    try fuzzTarget(.jpeg);
}
test "fuzz: gif" {
    try fuzzTarget(.gif);
}
test "fuzz: webp" {
    try fuzzTarget(.webp);
}
test "fuzz: inflate" {
    try fuzzTarget(.inflate);
}
test "fuzz: brotli" {
    try fuzzTarget(.brotli);
}
test "fuzz: woff" {
    try fuzzTarget(.woff);
}
test "fuzz: font" {
    try fuzzTarget(.font);
}
test "fuzz: html" {
    try fuzzTarget(.html);
}
test "fuzz: css" {
    try fuzzTarget(.css);
}
test "fuzz: json" {
    try fuzzTarget(.json);
}
test "fuzz: svg" {
    try fuzzTarget(.svg);
}
test "fuzz: render_html" {
    try fuzzTarget(.render_html);
}
test "fuzz: render_json" {
    try fuzzTarget(.render_json);
}

/// Inputs that once crashed / hung a target (src/testdata/fuzz/regress/), replayed by `zig build test`.
const regressions = [_]struct { target: Target, data: []const u8 }{
    // GSUB with damaged lookup / subtable counts: shape-plan digests were cubic (1.3 s in ReleaseSafe)
    .{ .target = .font, .data = @embedFile("testdata/fuzz/regress/font-gsub-digest.bin") },
    // GSUB LangSys claiming 0xffff features: collectLookups was quadratic (0.5 s in ReleaseSafe)
    .{ .target = .font, .data = @embedFile("testdata/fuzz/regress/font-gsub-lookups.bin") },
    // lossy WebP with corrupt coefficients: i32 overflow in the VP8 inverse transform (panic)
    .{ .target = .webp, .data = @embedFile("testdata/fuzz/regress/webp-vp8-transform-overflow.webp") },
};

test "fuzz regressions" {
    const io = std.testing.io;
    for (regressions) |r| {
        const t0 = std.Io.Clock.awake.now(io);
        run(r.target, std.testing.allocator, r.data);
        const dt = t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        if (dt > slow_ns) return error.SlowInput;
    }
}

test "long text runs render in linear time (fuzz regression)" {
    // One run full of ligatures: each ligature used to shift the whole shaping buffer, and the
    // paint-order sort of the box fragments was an insertion sort (150 KB took 4.3 s in
    // ReleaseSafe). 4x the text must now cost well under 16x the time.
    const short = try renderMs(1000);
    const long = try renderMs(4000);
    if (long > 8 * short + 100) {
        std.debug.print("text run: 19 KB took {d} ms, 76 KB took {d} ms\n", .{ short, long });
        return error.SlowInput;
    }
}

test "long unspaced Thai and CJK runs shape in linear time (fuzz regression)" {
    // No spaces outside Latin: the run was never split into shaping segments, and every SARA AM
    // (decomposed with an insertion into the shaping buffer) moved the rest of the run. 4x the
    // text must cost well under 16x the time.
    inline for (.{ "\u{0e01}\u{0e33}", "\u{6f22}\u{5b57}\u{304b}\u{306a}" }) |unit| {
        const short = try renderUnitMs(unit, 18_000 / unit.len * 3);
        const long = try renderUnitMs(unit, 72_000 / unit.len * 3);
        if (long > 8 * short + 100) {
            std.debug.print("unspaced run {s}: {d} ms, 4x as long: {d} ms\n", .{ unit, short, long });
            return error.SlowInput;
        }
    }
}

fn renderUnitMs(comptime unit: []const u8, reps: usize) !i64 {
    const a = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "<p>");
    for (0..reps) |_| try src.appendSlice(a, unit);
    try src.appendSlice(a, "</p>");
    const io = std.testing.io;
    const t0 = std.Io.Clock.awake.now(io);
    run(.render_html, a, src.items);
    return t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
}

fn renderMs(reps: usize) !i64 {
    const a = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "<p><span style=\"background-color:red\">");
    for (0..reps) |_| try src.appendSlice(a, "office fifl affine ");
    try src.appendSlice(a, "</span></p>");
    const io = std.testing.io;
    const t0 = std.Io.Clock.awake.now(io);
    run(.render_html, a, src.items);
    return t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
}

test "Limited: exceeding the cap is OutOfMemory" {
    var lim: Limited = .{ .inner = std.testing.allocator, .limit = 1000 };
    const a = lim.allocator();
    const x = try a.alloc(u8, 600);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 600));
    const y = try a.realloc(x, 900);
    try std.testing.expectEqual(@as(usize, 900), lim.used);
    a.free(y);
    try std.testing.expectEqual(@as(usize, 0), lim.used);
}
