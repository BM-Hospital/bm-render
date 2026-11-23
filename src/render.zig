//! Render pipeline: source (JSON node tree | HTML) -> element model (dom.zig) -> cascade
//! (preset < presentation hints < Tailwind < stylesheet rules < inline style, `!important`
//! reversed per CSS) -> render nodes (inline runs merged into paragraphs, `::before`/`::after`
//! boxes) -> layout -> paint -> encode.
//!
//! Optional front-end modules (css, tw, html) are referenced only behind comptime `config` flags,
//! so a `-Dprofile=core` build does not link them.
//!
//! Memory model: `Renderer.gpa` is long-lived (fonts, image + glyph caches); `Renderer.arena` holds
//! everything of one render (including the returned bytes) and is reset at the start of the next call.
const std = @import("std");
const json = @import("json.zig");
const style = @import("style/style.zig");
const layout = @import("layout/layout.zig");
const font = @import("font/font.zig");
const raster = @import("raster/raster.zig");
const codec = @import("codec/codec.zig");
const paint = @import("paint.zig");
const bump = @import("bump.zig");
const config = @import("config.zig");
const dom_mod = @import("dom.zig");
const css = @import("css/css.zig");
const twc = @import("tw/tw.zig");
const html = @import("html/html.zig");
const css_counters_mod = if (config.enable_pdf) @import("pdf/css_counters.zig") else struct {};
const CssCounters = if (config.enable_pdf) css_counters_mod.Context else void;
const animate = @import("animate.zig");
const svgm = @import("svg/svg.zig");
const mx = @import("measure_xform.zig");

const Allocator = std.mem.Allocator;
pub const CS = style.ComputedStyle;
pub const none: u32 = std.math.maxInt(u32);
/// Maximum number of node nesting levels (takumi's MAXIMUM_DOM_TREE_DEPTH: 512 levels pass, 513 fail).
/// Every phase recurses per level on the 1 MiB wasm shadow stack. Measured on a ReleaseSafe build
/// (frames larger than the shipped ReleaseSmall ones; bench/probe/layout2/deep*.mjs): paint is the
/// limit at ~320-370 B per level (Painter.paintNode / paintBox) plus ~100-140 KB used once by the
/// rasterizer's fill path; JSON parsing ~144 B per level (json.Parser.value, two JSON levels per
/// node); a 512-level heavy tree renders + measures with a 384 KiB stack (>2.5x margin). Anonymous
/// line containers add layout levels: the layout engine's own 512-level limit then fails first.
pub const max_node_depth = 512;

/// Largest output canvas (pixels) of a raster frame; one side is at most `max_canvas_side`.
pub const max_canvas_pixels: u64 = 40_000_000;
pub const max_canvas_side = 16384;

/// Per-call resource limits for untrusted inputs (the `limits` render option). Every field starts at
/// the built-in hard cap; the option can only lower them (`Limits.parse` clamps). Held by the
/// `Renderer` for the duration of one call: calls on one renderer are serialised (native.zig), and
/// different renderers share no limits.
pub const Limits = struct {
    /// width*height of one decoded raster image source (also each frame of an animated one).
    image_pixels: u64 = Renderer.max_image_pixels,
    /// Encoded byte size of one image source (raster or SVG; no built-in cap).
    image_bytes: u64 = std.math.maxInt(u64),
    /// Frames of one animated image source (GIF / WebP / APNG).
    animation_frames: u32 = codec.anim.Animator.max_frames,
    /// width*height of the output canvas (raster outputs, every frame of `renderAnimation`).
    canvas_pixels: u64 = max_canvas_pixels,
    /// Node nesting levels of the source (JSON tree or HTML).
    node_depth: u32 = max_node_depth,

    pub const Field = enum { image_pixels, image_bytes, animation_frames, canvas_pixels, node_depth };
    const keys = [_]struct { []const u8, Field }{
        .{ "maxImagePixels", .image_pixels },
        .{ "maxImageBytes", .image_bytes },
        .{ "maxAnimationFrames", .animation_frames },
        .{ "maxCanvasPixels", .canvas_pixels },
        .{ "maxNodeDepth", .node_depth },
    };

    /// The option name of `field` (for error messages).
    pub fn name(field: Field) []const u8 {
        inline for (keys) |k| if (k[1] == field) return k[0];
        unreachable;
    }

    /// Parses the `limits` option value (null / absent = the defaults). On error.Invalid `msg` and
    /// `detail` describe the problem.
    pub fn parse(v: ?json.Value, msg: *[]const u8, detail: *[]const u8) error{Invalid}!Limits {
        var l: Limits = .{};
        const obj = v orelse return l;
        if (obj == .null) return l;
        if (obj != .object) {
            msg.* = "limits must be an object";
            detail.* = "";
            return error.Invalid;
        }
        for (obj.object) |m| {
            if (m.value == .null) continue;
            const field = for (keys) |k| {
                if (std.mem.eql(u8, k[0], m.key)) break k[1];
            } else {
                msg.* = "unknown limit: limits.";
                detail.* = m.key;
                return error.Invalid;
            };
            const n: f64 = if (m.value == .number) m.value.number else std.math.nan(f64);
            if (!(n >= 1)) {
                msg.* = "limit must be a number >= 1: limits.";
                detail.* = m.key;
                return error.Invalid;
            }
            const x: u64 = if (n >= 1.0e18) std.math.maxInt(u64) else @intFromFloat(@floor(n));
            switch (field) {
                inline else => |t| {
                    const f = &@field(l, @tagName(t));
                    f.* = @intCast(@min(x, f.*));
                },
            }
        }
        return l;
    }
};

/// The layout tree with the optional features selected in config.zig (tables / floats compile out;
/// a disabled table display lays out as a block, a disabled float as an in-flow block).
pub const LTree = layout.TreeWith(.{ .tables = config.enable_tables, .floats = config.enable_floats, .inline_row = true, .inline_fn = true });

pub const Error = error{ OutOfMemory, Invalid };

/// `anon_text`: anonymous paragraph leaf (merged inline runs of its parent block; `cs` = the block's).
/// `anon_box`: anonymous inline formatting context (layout `inline_row`) of a run of inline content that
/// contains inline-level boxes: its `para` holds the text with one object per box, its children are
/// those boxes (atomic inlines, floats and out-of-flow boxes met inside the text, in document order =
/// object id order); `cs` is an initial-value style inheriting from the block, so it paints nothing.
pub const Kind = enum(u8) { container, text, image, anon_text, anon_box };

pub const Node = struct {
    kind: Kind,
    cs: *const CS,
    /// source element (dom index; none for anonymous / generated boxes)
    el: u32 = none,
    parent: u32 = none,
    first_child: u32 = none,
    last_child: u32 = none,
    next: u32 = none,
    lid: u32 = none,
    para: ?*font.Paragraph = null,
    /// Line layout of `para` (see `Frame.textLayout`): the one the layout pass produced for inline
    /// content laid out in its formatting context (`tl_w` NaN), else the last one computed for the
    /// content width `tl_w`.
    tl: ?*const font.TextLayout = null,
    tl_w: f32 = 0,
    /// First entry of `Frame.inline_boxes` that belongs to `para` (`BoxFragment.box` is relative to it).
    box_base: u32 = 0,
    /// The node is an inline-level box inside an inline box (`<span>`) of its paragraph.
    in_inline_box: bool = false,
    /// Block-in-inline: the paragraph is a part of an inline formatting context split by block-level
    /// boxes (`ifc_part`); the node is such a block (`bii`). measure() reports them like takumi: the
    /// parts as the container's inline content, the blocks inside an anonymous box.
    ifc_part: bool = false,
    bii: bool = false,
    img: ?*const raster.Pixmap = null,
    /// SVG image source: the document markup (per-render arena or renderer-owned image bytes,
    /// valid for the frame). `img` stays null; `img_w`/`img_h` hold its intrinsic size.
    svg: ?[]const u8 = null,
    /// intrinsic image size in device px (0 x 0 = no natural size)
    img_w: f32 = 0,
    img_h: f32 = 0,
    /// natural aspect ratio when there is no natural size (SVG with only a viewBox); 0 = none
    img_ratio: f32 = 0,
    /// image nodes: the `src` the image was resolved from (svg_out embeds the original bytes)
    src: ?[]const u8 = null,
};

const ImageEntry = struct {
    src: []u8,
    data: []u8,
    /// raw RGBA entries: width/height > 0
    width: u32 = 0,
    height: u32 = 0,
    premultiplied: bool = false,
};

const CachedImage = struct {
    key: u64,
    /// 0 = original decode; otherwise the resampled target size
    tw: u32,
    th: u32,
    pm: *raster.Pixmap,
};

pub const GlyphMask = struct { x: i32, y: i32, w: u32, h: u32, data: []u8 };

/// Persistent colour-glyph raster (COLR / bitmap glyph rendered once per key; `pix` owned by
/// `Renderer.gpa`). The key is chosen by the painter (face, gid, size, foreground).
pub const ColorGlyphEntry = struct { pix: raster.Pixmap, ox: i32, oy: i32 };

/// An inline box (tagged inline element or generated box) enclosing text runs of a paragraph.
/// `paint_cs`: for a box with percentage padding, a copy of `cs` with the padding resolved against the
/// percentage base (`paint_base`) of the line layout that will be painted.
/// `no_start` / `no_end`: the box continues from / into another paragraph around a block-level child
/// (block-in-inline): this part has no start / end edge.
pub const InlineBox = struct { cs: *const CS, parent: u32, paint_cs: ?*const CS = null, paint_base: f32 = 0, no_start: bool = false, no_end: bool = false };

/// Iterates the painted runs of a line layout: maximal glyph sequences of one source run and one
/// face on one line, with their horizontal extent and baseline.
pub const RunIter = struct {
    tl: *const font.TextLayout,
    line: usize = 0,
    seg: usize = 0,
    gi: u32 = 0,
    /// The line whose start was handled (lines without segments).
    entered: usize = std.math.maxInt(usize),
    /// A right-to-left line's overflow marker sits visually first but is the line's last
    /// logical item (takumi `LineTruncator`): PDF builds yield it after the line's other runs
    /// (`marker_pending`: the rest of the line is being yielded, the marker comes next).
    marker_pending: bool = false,

    pub const Run = struct { g0: u32, g1: u32, x0: f32, x1: f32, baseline: f32 };

    /// The marker range of line `li` when it starts the line, else an empty range.
    fn leadingMarker(tl: *const font.TextLayout, li: usize) [2]u32 {
        const line = tl.lines[li];
        if (comptime @TypeOf(line.marker0) == void) return .{ 0, 0 };
        if (line.rtl and line.marker1 > line.marker0 and line.marker0 == line.glyph_start and line.marker1 < line.glyph_end) return .{ line.marker0, line.marker1 };
        return .{ 0, 0 };
    }

    pub fn next(it: *RunIter) ?Run {
        const tl = it.tl;
        const gs = tl.glyphs;
        if (tl.segments.len > 0) {
            // (paragraphs with inline boxes / objects: exact segments from the text engine)
            while (it.seg < tl.segments.len) {
                const sg = tl.segments[it.seg];
                const end = @min(sg.g1, gs.len);
                if (it.gi < sg.g0) it.gi = sg.g0;
                if (it.gi >= end) {
                    it.seg += 1;
                    continue;
                }
                const g0 = it.gi;
                var ge = g0 + 1;
                while (ge < end and gs[ge].face == gs[g0].face) ge += 1;
                it.gi = ge;
                return .{ .g0 = g0, .g1 = ge, .x0 = if (g0 == sg.g0) sg.x0 else gs[g0].x, .x1 = if (ge < end) gs[ge].x else sg.x1, .baseline = sg.baseline };
            }
            return null;
        }
        while (it.line < tl.lines.len) {
            const line = tl.lines[it.line];
            const line_end = @min(line.glyph_end, gs.len);
            const mk = leadingMarker(tl, it.line);
            if (it.entered != it.line) {
                it.entered = it.line;
                if (it.gi < line.glyph_start) it.gi = line.glyph_start;
                if (mk[1] > mk[0] and it.gi <= mk[0]) {
                    it.gi = mk[1];
                    it.marker_pending = true;
                }
            }
            // (the marker's own pass ends where the content starts)
            const end = if (!it.marker_pending and mk[1] > mk[0]) mk[1] else line_end;
            if (it.gi >= end) {
                if (it.marker_pending) {
                    it.marker_pending = false;
                    it.gi = mk[0];
                    continue;
                }
                it.line += 1;
                continue;
            }
            const g0 = it.gi;
            var ge = g0 + 1;
            while (ge < end and gs[ge].user == gs[g0].user and gs[ge].face == gs[g0].face) ge += 1;
            it.gi = ge;
            return .{ .g0 = g0, .g1 = ge, .x0 = gs[g0].x, .x1 = if (ge < line_end) gs[ge].x else @max(gs[g0].x, line.x + line.width), .baseline = line.baseline };
        }
        return null;
    }
};

pub const Format = enum { png, jpeg, webp, ico, raw };

/// `renderAnimation` output formats (takumi default: webp).
pub const AnimFormat = enum { webp, apng, gif };

/// How the `source` bytes of a render are interpreted (C ABI `kind` argument).
pub const SourceKind = enum(u8) { json = 0, html = 1 };

/// Render options (takumi `RenderOptions`). JSON-valued entries live in the per-call arena.
pub const Options = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    format: Format = .png,
    quality: ?u8 = null,
    dpr: f32 = 1,
    /// `css`: array of stylesheet strings / takumi rule objects (or one string).
    css: ?json.Value = null,
    /// deprecated `stylesheets` (strings), used when `css` is absent.
    stylesheets: ?json.Value = null,
    /// deprecated `keyframes` option (KeyframesMap / KeyframesRuleList).
    keyframes: ?json.Value = null,
    /// root language (`:lang()` fallback for the root element).
    lang: []const u8 = "",
    /// root font-family fallback stack (used when the root sets no `font-family`).
    font_families: []const []const u8 = &.{},
    /// animation timeline position in ms (takumi: integer ms; default 0 = animations sampled at 0).
    time_ms: f32 = 0,
};

pub const Renderer = struct {
    gpa: Allocator,
    arena: bump.Bump,
    /// Short-lived scratch (hi-res glyph coverage), rewound after every glyph.
    scratch: bump.Bump,
    fonts: font.FontCollection = .{},
    font_blobs: std.ArrayList([]u8) = .empty,
    /// [pdf] the bundled last-resort font (`geist_ttf`) is registered (see `ensureDefaultFonts`)
    default_fonts: bool = false,
    images: std.ArrayList(ImageEntry) = .empty,
    img_cache: std.ArrayList(CachedImage) = .empty,
    img_cache_bytes: usize = 0,
    /// Content hashes of sources that failed to decode (a decoder this build lacks, e.g. a
    /// progressive JPEG): not attempted again on every render.
    img_failed: std.ArrayList(u64) = .empty,
    /// Content hashes of image sources computed during the current call (layout and the PDF
    /// emitter both key on them), by address; forgotten when the call starts or images change.
    hash_memo: [8]HashMemo = @splat(.{}),
    hash_memo_next: u8 = 0,
    rast: raster.Rasterizer,
    /// Glyph-mask cache. The key is 128 bits wide so a full 16-bit face id (variable-font
    /// instances are >= 0x8000) fits next to gid / size / subpixel phase / synthesis bits.
    glyphs: std.AutoHashMapUnmanaged(u128, GlyphMask) = .empty,
    glyph_bytes: usize = 0,
    /// Colour-glyph cache (cleared with `glyphs`; `color_glyph_bytes` counts against `glyph_budget`).
    color_glyphs: std.AutoHashMapUnmanaged(u64, ColorGlyphEntry) = .empty,
    color_glyph_bytes: usize = 0,
    /// `fonts.instanceEvictions()` at the last frame (glyph cache flushed when it changes).
    font_evictions: u32 = 0,
    /// Canvas pixels, kept between renders (so the per-render arena can be recycled before encoding).
    canvas: []u8 = &.{},
    /// Set by a host that wants `format: "raw"` frames painted straight into memory it owns
    /// (the native addon: the JS ArrayBuffer of the result), instead of copying the canvas out.
    raw_target: ?RawTarget = null,
    result: []const u8 = "",
    err: []const u8 = "",
    err_buf: [256]u8 = undefined,
    /// Timeline position of the frame being rendered (animated image sources).
    time_ms: f32 = 0,
    /// Shape-plan cache (long-lived; plans reference font data: cleared with the fonts).
    shape_cache: font.ShapeCache,
    /// Resource limits of the current call (the `limits` option; set when its options are parsed).
    limits: Limits = .{},

    pub const glyph_budget: usize = 8 << 20;
    pub const image_budget: usize = 96 << 20;

    pub fn create(gpa: Allocator) ?*Renderer {
        const self = gpa.create(Renderer) catch return null;
        self.* = .{ .gpa = gpa, .arena = bump.Bump.init(gpa), .scratch = bump.Bump.init(gpa), .rast = raster.Rasterizer.init(gpa), .shape_cache = font.ShapeCache.init(gpa) };
        self.shape_cache.keep_results = true;
        self.rast.levels16 = true;
        self.scratch.idle_limit = 255;
        return self;
    }

    pub fn destroy(self: *Renderer) void {
        self.clearFonts();
        self.clearImages();
        self.clearImageCache();
        self.fonts.deinit(self.gpa);
        self.font_blobs.deinit(self.gpa);
        self.images.deinit(self.gpa);
        self.img_cache.deinit(self.gpa);
        self.img_failed.deinit(self.gpa);
        self.glyphs.deinit(self.gpa);
        self.color_glyphs.deinit(self.gpa);
        self.shape_cache.deinit();
        self.rast.deinit();
        self.gpa.free(self.canvas);
        self.scratch.deinit();
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn setErr(self: *Renderer, prefix: []const u8, detail: []const u8) void {
        var n: usize = 0;
        for (prefix[0..@min(prefix.len, 128)]) |c| {
            self.err_buf[n] = c;
            n += 1;
        }
        const room = self.err_buf.len - n;
        const m = @min(room, detail.len);
        @memcpy(self.err_buf[n..][0..m], detail[0..m]);
        self.err = self.err_buf[0 .. n + m];
    }

    fn clearGlyphs(self: *Renderer) void {
        var it = self.glyphs.valueIterator();
        while (it.next()) |g| self.gpa.free(g.data);
        self.glyphs.clearRetainingCapacity();
        self.glyph_bytes = 0;
        if (comptime config.enable_color_fonts or config.enable_bitmap_glyphs) {
            var ci = self.color_glyphs.valueIterator();
            while (ci.next()) |g| g.pix.deinit(self.gpa);
            self.color_glyphs.clearRetainingCapacity();
            self.color_glyph_bytes = 0;
        }
    }

    fn clearImageCache(self: *Renderer) void {
        for (self.img_cache.items) |c| {
            c.pm.deinit(self.gpa);
            self.gpa.destroy(c.pm);
        }
        self.img_cache.clearRetainingCapacity();
        self.img_cache_bytes = 0;
        self.img_failed.clearRetainingCapacity();
    }

    /// Takes ownership of `data` (allocated with `gpa`): TTF/OTF/TTC (every face of a collection is
    /// registered) or, with WOFF support compiled in, WOFF/WOFF2 (decoded to sfnt, the container is
    /// freed). Returns takumi's `RegisteredFamily[]` JSON in the arena: `[{name, faces:[{weight, style,
    /// width, index}], weight, style}]` (`weight`/`style` of the first face kept for compatibility).
    pub fn registerFont(self: *Renderer, data_in: []u8, name: []const u8, weight: u16, italic: i32, unicode_range: ?[]const font.collection.UnicodeRange) Error![]const u8 {
        self.arena.reset();
        var data = data_in;
        if (comptime config.enable_woff) {
            const woff = @import("woff/woff.zig");
            switch (woff.sniff(data)) {
                .woff, .woff2 => {
                    const dec = woff.decode(self.gpa, data) catch |e| {
                        self.gpa.free(data);
                        if (e == error.OutOfMemory) return error.OutOfMemory;
                        self.setErr("invalid WOFF/WOFF2 font data", "");
                        return error.Invalid;
                    };
                    self.gpa.free(data);
                    data = dec;
                },
                else => {},
            }
        }
        const reg = self.fonts.registerAll(self.gpa, data, .{
            .family = if (name.len > 0) name else null,
            .weight = if (weight > 0) weight else null,
            .italic = if (italic < 0) null else italic != 0,
            .unicode_range = unicode_range,
        }) catch |e| blk: {
            const is_sfnt = sfntDirectoryReads(data);
            // takumi registers a named font whose tables it cannot read (truncated, no `cmap`) as
            // long as its table directory reads: it draws no character, and the text falls back
            // to the next family (in PDF output at last the bundled Geist). Here: a face of that
            // family covering nothing, on an empty font (every build alike, so the native addon
            // and every wasm build accept the same files).
            if (e != error.OutOfMemory and name.len > 0 and is_sfnt) {
                const nothing = [_]font.collection.UnicodeRange{};
                if (self.fonts.registerAll(self.gpa, &empty_font, .{
                    .family = name,
                    .weight = if (weight > 0) weight else null,
                    .italic = if (italic < 0) null else italic != 0,
                    .unicode_range = &nothing,
                })) |r| break :blk r else |e2| if (e2 == error.OutOfMemory) {
                    self.gpa.free(data);
                    return error.OutOfMemory;
                }
            }
            self.gpa.free(data);
            switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.WoffContainer, error.Woff2Container => self.setErr("WOFF/WOFF2 fonts are not supported by this build", ""),
                // (takumi's wording for bytes that are no font file, and for a format it cannot read)
                error.UnsupportedFontFormat => self.setErr("Unsupported font format", ""),
                else => self.setErr(if (is_sfnt) "invalid font data" else "Unsupported font format", ""),
            }
            return error.Invalid;
        };
        self.font_blobs.append(self.gpa, data) catch return error.OutOfMemory;
        // the families this call touched, in registration order
        const a = self.arena.allocator();
        const fams = self.fonts.families(a) catch return error.OutOfMemory;
        var out: std.ArrayList(u8) = .empty;
        try out.append(a, '[');
        var first = true;
        for (fams) |fam| {
            var touched = false;
            var k: u16 = 0;
            while (k < reg.count) : (k += 1) {
                if (std.ascii.eqlIgnoreCase(self.fonts.face(reg.first + k).family, fam.name)) touched = true;
            }
            if (!touched) continue;
            if (!first) try out.append(a, ',');
            first = false;
            try out.appendSlice(a, "{\"name\":");
            try writeJsonString(a, &out, fam.name);
            try out.appendSlice(a, ",\"faces\":[");
            for (fam.faces, 0..) |fc, i| {
                if (i != 0) try out.append(a, ',');
                try out.appendSlice(a, "{\"weight\":");
                try writeNum(a, &out, @floatFromInt(fc.weight));
                try out.appendSlice(a, if (fc.italic) ",\"style\":\"italic\"" else ",\"style\":\"normal\"");
                try out.appendSlice(a, ",\"width\":");
                try writeNum(a, &out, fc.width);
                try out.appendSlice(a, ",\"index\":");
                try writeNum(a, &out, @floatFromInt(fc.index));
                try out.append(a, '}');
            }
            try out.append(a, ']');
            if (fam.faces.len > 0) {
                try out.appendSlice(a, ",\"weight\":");
                try writeNum(a, &out, @floatFromInt(fam.faces[0].weight));
                try out.appendSlice(a, if (fam.faces[0].italic) ",\"style\":\"italic\"" else ",\"style\":\"normal\"");
            }
            try out.append(a, '}');
        }
        try out.append(a, ']');
        self.result = out.items;
        return self.result;
    }

    /// takumi `unregisterFont(family)`: removes every face of `family`; true when any was removed.
    pub fn unregisterFont(self: *Renderer, family: []const u8) bool {
        const any = self.fonts.unregisterFamily(self.gpa, family);
        if (any) {
            self.clearGlyphs();
            self.shape_cache.clear();
        }
        return any;
    }

    pub fn clearFonts(self: *Renderer) void {
        self.clearGlyphs();
        self.shape_cache.clear();
        self.fonts.clear(self.gpa);
        font.variations.invalidateCaches();
        for (self.font_blobs.items) |b| self.gpa.free(b);
        self.font_blobs.clearRetainingCapacity();
        // (the bundled fallback comes back with the next PDF call, as takumi-pdf's `clearFonts()`)
        self.default_fonts = false;
    }

    /// A TrueType font with no glyph mapped (`cmap` without subtables, one empty glyph): the face
    /// of a registered family whose own file cannot be read (`registerFont`).
    const empty_font: [196]u8 = blk: {
        var b: [196]u8 = @splat(0);
        const put16 = struct {
            fn f(buf: []u8, at: usize, v: u16) void {
                buf[at] = @intCast(v >> 8);
                buf[at + 1] = @intCast(v & 0xff);
            }
        }.f;
        const put32 = struct {
            fn f(buf: []u8, at: usize, v: u32) void {
                buf[at] = @intCast(v >> 24);
                buf[at + 1] = @intCast((v >> 16) & 0xff);
                buf[at + 2] = @intCast((v >> 8) & 0xff);
                buf[at + 3] = @intCast(v & 0xff);
            }
        }.f;
        put32(&b, 0, 0x00010000);
        put16(&b, 4, 5); // tables, in tag order: cmap head hhea hmtx maxp
        // directory
        const dir = [_][3]u32{ .{ 0x636d6170, 92, 4 }, .{ 0x68656164, 96, 54 }, .{ 0x68686561, 150, 36 }, .{ 0x686d7478, 186, 4 }, .{ 0x6d617870, 190, 6 } };
        for (dir, 0..) |d, i| {
            put32(&b, 12 + i * 16, d[0]);
            put32(&b, 12 + i * 16 + 8, d[1]);
            put32(&b, 12 + i * 16 + 12, d[2]);
        }
        // head: version 1.0, magic, unitsPerEm 1000, short loca
        put32(&b, 96, 0x00010000);
        put32(&b, 96 + 12, 0x5F0F3CF5);
        put16(&b, 96 + 18, 1000);
        // hhea: version 1.0, ascender 800, descender -200, one metric
        put32(&b, 150, 0x00010000);
        put16(&b, 150 + 4, 800);
        put16(&b, 150 + 6, 0xFF38);
        put16(&b, 150 + 34, 1);
        // hmtx: advance 500
        put16(&b, 186, 500);
        // maxp: version 0.5, one glyph
        put32(&b, 190, 0x00005000);
        break :blk b;
    };

    /// Whether `data` starts like an sfnt font (TrueType, OpenType or a collection) whose table
    /// directory lies inside it.
    fn sfntDirectoryReads(data: []const u8) bool {
        if (data.len < 12) return false;
        const rd32 = struct {
            fn f(b: []const u8, i: usize) u32 {
                return std.mem.readInt(u32, b[i..][0..4], .big);
            }
        }.f;
        var dir: usize = 0;
        if (rd32(data, 0) == 0x74746366) { // 'ttcf': the first face's directory
            if (data.len < 16) return false;
            dir = rd32(data, 12);
            if (dir > data.len - 12) return false;
        }
        const magic = rd32(data, dir);
        if (magic != 0x00010000 and magic != 0x74727565 and magic != 0x4F54544F) return false; // 1.0, 'true', 'OTTO'
        const n: usize = std.mem.readInt(u16, data[dir + 4 ..][0..2], .big);
        return dir + 12 + n * 16 <= data.len;
    }

    /// takumi-pdf's bundled last-resort font: Geist (Latin, weights 300-800; SIL OFL 1.1,
    /// src/pdf/geist/OFL.txt), the same file takumi embeds (`EMBEDDED_FONTS`). PDF builds only.
    const geist_ttf: []const u8 = if (config.enable_pdf) @embedFile("pdf/geist/geist-latin-wght-300-800.ttf") else "";

    /// Registers the bundled last-resort font for a PDF call (takumi-pdf `default_fonts`: every
    /// renderer starts with it, and `clearFonts()` goes back to it). It is tried after every
    /// registered family and claims no generic family (`sans-serif` stays with the caller's
    /// fonts); a document that names `Geist` gets it directly.
    fn ensureDefaultFonts(self: *Renderer) void {
        if (comptime !config.enable_pdf) return;
        if (self.default_fonts) return;
        self.default_fonts = true;
        _ = self.fonts.registerAll(self.gpa, geist_ttf, .{ .family = "Geist", .last_resort = true }) catch {};
    }

    pub fn putImage(self: *Renderer, src: []const u8, data: []const u8, w: u32, h: u32, premul: bool) Error!void {
        if (w != 0 and (@as(u64, w) * h * 4 != data.len)) {
            self.setErr("raw image data length must be width*height*4", "");
            return error.Invalid;
        }
        const s = try self.gpa.dupe(u8, src);
        errdefer self.gpa.free(s);
        const d = try self.gpa.dupe(u8, data);
        errdefer self.gpa.free(d);
        try self.images.append(self.gpa, .{ .src = s, .data = d, .width = w, .height = h, .premultiplied = premul });
    }

    pub fn clearImages(self: *Renderer) void {
        self.hash_memo = @splat(.{});
        for (self.images.items) |e| {
            self.gpa.free(e.src);
            self.gpa.free(e.data);
        }
        self.images.clearRetainingCapacity();
    }

    pub fn releaseResult(self: *Renderer) void {
        self.result = "";
        self.arena.reset();
    }

    pub fn beginCall(self: *Renderer) void {
        self.result = "";
        self.err = "";
        self.arena.reset();
        self.hash_memo = @splat(.{});
        self.fonts.beginFrame();
        // variable-font instance ids are recycled: cached glyph masks keyed by them go stale
        const ev = self.fonts.instanceEvictions();
        if (ev != self.font_evictions) {
            self.font_evictions = ev;
            self.clearGlyphs();
        }
        if (self.glyph_bytes + self.color_glyph_bytes > glyph_budget) self.clearGlyphs();
        if (self.img_cache_bytes > image_budget) self.clearImageCache();
    }

    /// Renders a JSON node tree (takumi `{json}` source).
    pub fn render(self: *Renderer, node_json: []const u8, opts_json: []const u8) Error![]const u8 {
        return self.renderSource(.json, node_json, opts_json);
    }

    /// Renders `source` (a JSON node tree or HTML markup) with the JSON options `opts_json`.
    pub fn renderSource(self: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
        self.beginCall();
        const a = self.arena.allocator();
        const opts = try self.parseOptions(opts_json);
        const pm = try self.renderPixels(.{ .kind = kind, .text = source }, opts, if (opts.format == .raw) self.raw_target else null);

        self.result = switch (opts.format) {
            .raw => pm.data,
            .png => codec.encodePng(a, pm.data, pm.width, pm.height, .{}) catch return error.OutOfMemory,
            .jpeg => codec.encodeJpeg(a, pm.data, pm.width, pm.height, .{ .quality = opts.quality orelse 75 }) catch return error.OutOfMemory,
            .webp => codec.encodeWebp(a, pm.data, pm.width, pm.height, .{}) catch return error.OutOfMemory,
            .ico => blk: {
                if (comptime !config.enable_extra_codecs) unreachable; // rejected by parseOptions
                if (pm.width > 256 or pm.height > 256) {
                    var buf: [64]u8 = undefined;
                    self.setErr("ICO images are 1 to 256 pixels on a side, not ", decimal(&buf, @max(pm.width, pm.height)));
                    return error.Invalid;
                }
                break :blk codec.encodeIco(a, pm.data, pm.width, pm.height) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        self.setErr("ICO encoding failed", "");
                        return error.Invalid;
                    },
                };
            },
        };
        return self.result;
    }

    /// Where one raw frame is painted instead of the renderer's canvas. `alloc(ctx, len)` is called
    /// at most once per `renderSource` call with `format: "raw"`, after layout, with the frame's
    /// byte size; it returns `len` ZERO bytes that stay valid until the host has consumed
    /// `result` (which is then that memory), or null to fall back to the canvas. The host owns
    /// the memory, also when the render fails afterwards.
    pub const RawTarget = struct { ctx: ?*anyopaque, alloc: *const fn (ctx: ?*anyopaque, len: usize) ?[*]u8 };

    /// A render source: text (JSON node tree / HTML) or an already parsed JSON node value
    /// (`renderAnimation` scenes; the value must outlive the call).
    pub const Source = struct { kind: SourceKind = .json, text: []const u8 = "", value: ?json.Value = null };

    /// Lays out and paints one frame into `self.canvas` and un-premultiplies it. The per-render
    /// arena is reset afterwards (everything of the layout / paint phase is dead), so `opts` must
    /// not reference it when the caller still needs them; scalar fields are fine.
    fn renderPixels(self: *Renderer, src: Source, opts: Options, target: ?RawTarget) Error!raster.Pixmap {
        const a = self.arena.allocator();
        self.time_ms = opts.time_ms;
        var f: Frame = .{ .r = self, .a = a, .opts = opts, .tree = LTree.init(a), .ctx = undefined, .pre = src.value };
        try f.prepare(src.kind, src.text);

        const need = @as(usize, f.canvas_w) * f.canvas_h * 4;
        var pixels: []u8 = &.{};
        // a host-provided, already zeroed frame buffer replaces the canvas (see `RawTarget`)
        if (target) |t| if (need != 0) if (t.alloc(t.ctx, need)) |p| {
            pixels = p[0..need];
        };
        if (pixels.len == 0) {
            if (self.canvas.len != need) {
                self.gpa.free(self.canvas);
                self.canvas = &.{};
                self.canvas = self.gpa.alloc(u8, need) catch return error.OutOfMemory;
            }
            @memset(self.canvas, 0);
            pixels = self.canvas;
        }
        var pm: raster.Pixmap = .{ .width = f.canvas_w, .height = f.canvas_h, .data = pixels };
        try paint.paintFrame(&f, &pm);
        unpremultiply(pm.data);
        // Recycle the arena so the encoder reuses the same chunks instead of growing memory.
        self.arena.reset();
        return pm;
    }

    // ---- renderAnimation

    /// Upper bound of the raw frames kept for one `renderAnimation` call.
    pub const max_animation_bytes: usize = 512 << 20;

    /// takumi `renderAnimation`. `json_text`: `{scenes: [{node, durationMs}], width, height, fps,
    /// format?: "webp"|"apng"|"gif" (default webp), quality?, lossless? (ignored: webp is always
    /// lossless, like takumi-wasm), css?, stylesheets?, keyframes?, devicePixelRatio?,
    /// fontFamilies?, lang?}`; a scene `node` is a node object, an HTML string or `{json}`.
    /// Frame schedule (takumi-raster `frame_spans`): total = sum of durations, frame count =
    /// ceil(total * fps / 1000), frame i starts at floor(i * 1000 / fps) ms and lasts until the next
    /// start (clamped to total; zero-length frames dropped); a frame renders the scene active at its
    /// start with that scene's local time (time restarts per scene). Result in the arena.
    pub fn renderAnimation(self: *Renderer, json_text: []const u8) Error![]const u8 {
        if (comptime !config.enable_animation) {
            self.beginCall();
            self.setErr("renderAnimation is not supported by this build", "");
            return error.Invalid;
        }
        return self.renderAnimationImpl(json_text);
    }

    noinline fn renderAnimationImpl(self: *Renderer, json_text: []const u8) Error![]const u8 {
        self.beginCall();
        // the options + scenes live in their own arena for the whole call (the render arena is
        // recycled after every frame)
        var keep = bump.Bump.init(self.gpa);
        defer keep.deinit();
        const ka = keep.allocator();
        const v = json.parse(ka, json_text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.JsonTooDeep => return self.invalid("node tree is nested too deeply"),
            else => return self.invalid("invalid animation options JSON"),
        };
        if (v != .object) return self.invalid("invalid animation options JSON");
        const opts = try self.optionsFrom(ka, v, true);
        const scenes_v = v.get("scenes") orelse return self.invalid("Expected at least one animation scene");
        if (scenes_v != .array or scenes_v.array.len == 0) return self.invalid("Expected at least one animation scene");
        const fps_n = (if (v.get("fps")) |x| x.asNumber() else null) orelse return self.invalid("missing field `fps`");
        if (!(fps_n >= 1)) return self.invalid("Expected fps to be greater than 0");
        const fps: u64 = @intFromFloat(@min(fps_n, 1.0e6));
        if (opts.width == null or opts.height == null) return self.invalid("renderAnimation needs `width` and `height`");
        var format: AnimFormat = .webp;
        if (v.get("format")) |fv| if (fv.asString()) |s| {
            if (std.mem.eql(u8, s, "webp")) format = .webp else if (std.mem.eql(u8, s, "apng")) format = .apng else if (std.mem.eql(u8, s, "gif")) format = .gif else {
                self.setErr("unsupported animation format: ", s);
                return error.Invalid;
            }
        };
        // takumi `AnimationFormat::max_fps`: GIF 20 ms, WebP / APNG 11 ms shortest frame
        const max_fps: u64 = if (format == .gif) 1000 / 20 else 1000 / 11;
        if (fps > max_fps) {
            var b1: [24]u8 = undefined;
            var b2: [24]u8 = undefined;
            var msg: [128]u8 = undefined;
            var n: usize = 0;
            for ([_][]const u8{ "Frame rate ", decimal(&b1, fps), " fps exceeds the maximum ", decimal(&b2, max_fps), " fps for this animation format" }) |part| {
                @memcpy(msg[n..][0..part.len], part);
                n += part.len;
            }
            self.setErr(msg[0..n], "");
            return error.Invalid;
        }

        // scenes
        const Scene = struct { src: Source, dur: u64 };
        const scenes = try ka.alloc(Scene, scenes_v.array.len);
        var total: u64 = 0;
        for (scenes_v.array, scenes) |sv, *sc| {
            const node = sv.get("node") orelse return self.invalid("animation scene is missing `node`");
            const d = (if (sv.get("durationMs")) |x| x.asNumber() else null) orelse return self.invalid("animation scene is missing `durationMs`");
            sc.dur = if (d >= 0 and d < 4.0e9) @intFromFloat(d) else 0;
            total += sc.dur;
            sc.src = switch (node) {
                .string => |s| .{ .kind = .html, .text = s },
                .object => if (node.get("type") == null and node.get("json") != null and node.get("json").? == .string)
                    .{ .kind = .json, .text = node.get("json").?.string }
                else
                    .{ .kind = .json, .value = node },
                else => return self.invalid("animation scene `node` must be a node, an HTML string or {json}"),
            };
        }
        if (total == 0) return self.invalid("Animation must contain at least one frame");
        const count = (total * fps + 999) / 1000;
        const w = opts.width.?;
        const h = opts.height.?;
        const frame_bytes = @as(usize, w) * h * 4;
        if (count > 1 << 20 or @as(u64, frame_bytes) * count > max_animation_bytes) return self.invalid("animation too large");

        var frames: std.ArrayList(codec.AnimFrame) = .empty;
        defer {
            for (frames.items) |fr| self.gpa.free(fr.rgba);
            frames.deinit(self.gpa);
        }
        try frames.ensureTotalCapacity(self.gpa, @intCast(count));
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            const start = i * 1000 / fps;
            const end = @min((i + 1) * 1000 / fps, total);
            if (end <= start) continue;
            // scene active at `start` (clamped to the last ms), time restarting per scene
            const at = @min(start, total - 1);
            var elapsed: u64 = 0;
            var si: usize = 0;
            while (si + 1 < scenes.len and at >= elapsed + scenes[si].dur) : (si += 1) elapsed += scenes[si].dur;
            var fo = opts;
            fo.time_ms = @floatFromInt(at - elapsed);
            fo.format = .raw;
            // per-frame housekeeping (arena, font frame, glyph / image cache budgets)
            self.beginCall();
            const pm = try self.renderPixels(scenes[si].src, fo, null);
            if (pm.width != w or pm.height != h) return self.invalid("Animation frames must share the same dimensions");
            const copy = try self.gpa.dupe(u8, pm.data);
            frames.appendAssumeCapacity(.{ .rgba = copy, .delay_ms = @intCast(end - start) });
        }
        if (frames.items.len == 0) return self.invalid("Animation must contain at least one frame");
        // the canvas is not needed any more: give its memory back before encoding
        self.gpa.free(self.canvas);
        self.canvas = &.{};
        self.arena.reset();
        const a = self.arena.allocator();
        const eo: codec.AnimOptions = .{};
        const out = switch (format) {
            .webp => codec.encodeWebpAnim(a, frames.items, w, h, eo),
            .apng => codec.encodeApng(a, frames.items, w, h, eo),
            .gif => codec.encodeGif(a, frames.items, w, h, eo),
        } catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (format == .gif and (w > 65535 or h > 65535)) return self.invalid("GIF frame dimensions must be <= 65535x65535");
                return self.invalid("animation encoding failed");
            },
        };
        self.result = out;
        return self.result;
    }

    fn invalid(self: *Renderer, msg: []const u8) Error {
        self.setErr(msg, "");
        return error.Invalid;
    }

    pub fn measure(self: *Renderer, node_json: []const u8, opts_json: []const u8) Error![]const u8 {
        return self.measureSource(.json, node_json, opts_json);
    }

    pub fn measureSource(self: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
        self.beginCall();
        const a = self.arena.allocator();
        const opts = try self.parseOptions(opts_json);
        self.time_ms = opts.time_ms;
        var f: Frame = .{ .r = self, .a = a, .opts = opts, .tree = LTree.init(a), .ctx = undefined };
        try f.prepare(kind, source);
        var out: std.ArrayList(u8) = .empty;
        try f.writeMeasured(&out, f.root, .{});
        self.result = out.items;
        return self.result;
    }

    /// takumi `renderSvg`: the frame as a vector SVG document (UTF-8, in the arena; see svg_out.zig).
    /// `format` / `quality` options are ignored. Fails with a clear error when compiled out.
    pub fn renderSvg(self: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
        if (comptime !config.enable_render_svg) {
            self.beginCall();
            self.setErr("renderSvg is not supported by this build", "");
            return error.Invalid;
        }
        return self.renderSvgImpl(kind, source, opts_json);
    }

    noinline fn renderSvgImpl(self: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
        self.beginCall();
        const a = self.arena.allocator();
        var opts = try self.parseOptions(opts_json);
        // takumi `RenderOptions::svg`: SVG output always draws at a device pixel ratio of 1
        opts.dpr = 1;
        self.time_ms = opts.time_ms;
        var f: Frame = .{ .r = self, .a = a, .opts = opts, .tree = LTree.init(a), .ctx = undefined };
        try f.prepare(kind, source);
        var out: std.ArrayList(u8) = .empty;
        try @import("svg_out.zig").write(&f, &out);
        self.result = out.items;
        return self.result;
    }

    /// takumi-pdf `render`: the frame as a PDF file (see pdf/pdf.zig). Fails with a clear error when compiled out.
    pub fn renderPdf(self: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
        if (comptime !config.enable_pdf) {
            self.beginCall();
            self.setErr("renderPdf is not supported by this build", "");
            return error.Invalid;
        }
        return self.renderPdfImpl(kind, source, opts_json);
    }

    noinline fn renderPdfImpl(self: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
        self.beginCall();
        self.ensureDefaultFonts();
        self.result = try @import("pdf/pdf.zig").render(self, kind, source, opts_json);
        return self.result;
    }

    /// takumi-pdf `measure`: `{"width","height"}` of the source laid out like a page band (pdf/pdf.zig).
    pub fn measurePdf(self: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
        if (comptime !config.enable_pdf) {
            self.beginCall();
            self.setErr("measurePdf is not supported by this build", "");
            return error.Invalid;
        }
        return self.measurePdfImpl(kind, source, opts_json);
    }

    noinline fn measurePdfImpl(self: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
        self.beginCall();
        self.ensureDefaultFonts();
        self.result = try @import("pdf/pdf.zig").measure(self, kind, source, opts_json);
        return self.result;
    }

    pub fn needsPdf(self: *Renderer, kind: SourceKind, source: []const u8, opts_json: []const u8) Error![]const u8 {
        self.beginCall();
        if (comptime !config.enable_pdf) {
            self.setErr("needsPdf is not supported by this build", "");
            return error.Invalid;
        }
        self.ensureDefaultFonts();
        self.result = try @import("pdf/pdf.zig").needs(self, kind, source, opts_json);
        return self.result;
    }

    fn parseOptions(self: *Renderer, text: []const u8) Error!Options {
        self.limits = .{};
        if (text.len == 0) return .{};
        const v = json.parse(self.arena.allocator(), text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.setErr("invalid options JSON", "");
                return error.Invalid;
            },
        };
        return self.optionsFrom(self.arena.allocator(), v, false);
    }

    /// Render options from a parsed JSON object (`a` holds the derived lists; it must live as
    /// long as `v`).
    fn optionsFrom(self: *Renderer, a: Allocator, v: json.Value, anim: bool) Error!Options {
        var o: Options = .{};
        self.limits = .{};
        if (v != .object) return o;
        try self.parseLimits(v.get("limits"));
        if (v.get("width")) |w| if (w.asNumber()) |n| {
            o.width = dimOpt(n);
        };
        if (v.get("height")) |h| if (h.asNumber()) |n| {
            o.height = dimOpt(n);
        };
        if ((o.width != null and o.width.? == 0) or (o.height != null and o.height.? == 0)) {
            self.setErr("invalid viewport: width/height must be > 0", "");
            return error.Invalid;
        }
        if (v.get("devicePixelRatio")) |d| if (d.asNumber()) |n| {
            if (n > 0 and n < 64) o.dpr = n;
        };
        if (v.get("quality")) |q| if (q.asNumber()) |n| {
            o.quality = @intFromFloat(@min(100, @max(1, n)));
        };
        if (!anim) if (v.get("format")) |fv| if (fv.asString()) |s| {
            if (std.mem.eql(u8, s, "png")) o.format = .png else if (std.mem.eql(u8, s, "jpeg") or std.mem.eql(u8, s, "jpg")) o.format = .jpeg else if (std.mem.eql(u8, s, "webp")) o.format = .webp else if (std.mem.eql(u8, s, "raw")) o.format = .raw else if (config.enable_extra_codecs and std.mem.eql(u8, s, "ico")) o.format = .ico else {
                self.setErr("unsupported format: ", s);
                return error.Invalid;
            }
        };
        if (v.get("css")) |x| if (x != .null) {
            o.css = x;
        };
        if (v.get("stylesheets")) |x| if (x != .null) {
            o.stylesheets = x;
        };
        if (v.get("keyframes")) |x| if (x != .null) {
            o.keyframes = x;
        };
        if (v.get("lang")) |x| if (x.asString()) |s| {
            o.lang = s;
        };
        if (v.get("timeMs")) |x| if (x.asNumber()) |n| {
            o.time_ms = if (n >= 0 and n < 1.0e15) @floor(n) else 0;
        };
        if (v.get("fontFamilies")) |x| switch (x) {
            .string => |s| {
                const l = try a.alloc([]const u8, 1);
                l[0] = s;
                o.font_families = l;
            },
            .array => |arr| {
                const l = try a.alloc([]const u8, arr.len);
                var n: usize = 0;
                for (arr) |e| if (e.asString()) |s| {
                    l[n] = s;
                    n += 1;
                };
                o.font_families = l[0..n];
            },
            else => {},
        };
        // `lossless` (webp is always lossless, like takumi-wasm), `drawDebugBorder` and `dithering`
        // are accepted and ignored.
        return o;
    }

    /// Sets `self.limits` from the `limits` option value (absent / null = the built-in caps).
    pub fn parseLimits(self: *Renderer, v: ?json.Value) Error!void {
        var msg: []const u8 = "";
        var detail: []const u8 = "";
        self.limits = Limits.parse(v, &msg, &detail) catch {
            self.limits = .{};
            self.setErr(msg, detail);
            return error.Invalid;
        };
    }

    /// The decoder limits of image sources under `self.limits`.
    pub fn codecLimits(self: *const Renderer) codec.Limits {
        return .{ .max_pixels = self.limits.image_pixels, .max_frames = self.limits.animation_frames };
    }

    /// The limit an encoded image source exceeds, if any: `limits.maxImageBytes`, or, read from the
    /// headers (no pixel decoding), a lowered `limits.maxImagePixels` / `limits.maxAnimationFrames`.
    /// null = within the limits (the decoders still enforce the pixel limit).
    pub fn imageOverLimit(self: *const Renderer, bytes: []const u8) ?Limits.Field {
        const lim = self.limits;
        if (bytes.len > lim.image_bytes) return .image_bytes;
        if (lim.image_pixels < max_image_pixels) if (codec.dimensions(bytes)) |d| {
            if (@as(u64, d.w) * d.h > lim.image_pixels) return .image_pixels;
        };
        if (comptime config.enable_animation and config.enable_extra_codecs) {
            if (lim.animation_frames < codec.anim.Animator.max_frames and codec.frameCount(bytes) > lim.animation_frames) return .animation_frames;
        }
        return null;
    }

    /// `imageOverLimit` for image source `src` (`bytes`: its encoded bytes, when it has any), also
    /// covering raw RGBA `images` entries.
    pub fn sourceOverLimit(self: *Renderer, src: []const u8, bytes: ?[]const u8) ?Limits.Field {
        if (bytes) |b| return self.imageOverLimit(b);
        if (std.mem.startsWith(u8, src, "data:")) return null;
        const e = self.findImage(src) orelse return null;
        if (e.width != 0 and @as(u64, e.width) * e.height > self.limits.image_pixels) return .image_pixels;
        return null;
    }

    // ---- images

    fn findImage(self: *Renderer, src: []const u8) ?*const ImageEntry {
        var i = self.images.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.images.items[i].src, src)) return &self.images.items[i];
        }
        return null;
    }

    fn cacheLookup(self: *Renderer, key: u64, tw: u32, th: u32) ?*raster.Pixmap {
        for (self.img_cache.items) |c| {
            if (c.key == key and c.tw == tw and c.th == th) return c.pm;
        }
        return null;
    }

    fn cacheStore(self: *Renderer, key: u64, tw: u32, th: u32, pm: raster.Pixmap) ?*raster.Pixmap {
        const p = self.gpa.create(raster.Pixmap) catch return null;
        p.* = pm;
        self.img_cache.append(self.gpa, .{ .key = key, .tw = tw, .th = th, .pm = p }) catch {
            self.gpa.destroy(p);
            return null;
        };
        self.img_cache_bytes += pm.data.len;
        return p;
    }

    pub const HashMemo = struct { ptr: usize = 0, len: usize = 0, hash: u64 = 0 };

    /// XxHash64 of image source bytes (seeded with their length), remembered for the call when
    /// they are the data of an `images` entry (decoded data: URIs live in the call's arena).
    pub fn contentHash(self: *Renderer, bytes: []const u8) u64 {
        for (self.hash_memo) |m| {
            if (m.len == bytes.len and m.ptr == @intFromPtr(bytes.ptr) and m.len != 0) return m.hash;
        }
        const h = std.hash.XxHash64.hash(bytes.len, bytes);
        const entry = for (self.images.items) |e| {
            if (e.data.ptr == bytes.ptr and e.data.len == bytes.len) break true;
        } else false;
        if (!entry) return h;
        self.hash_memo[self.hash_memo_next % self.hash_memo.len] = .{ .ptr = @intFromPtr(bytes.ptr), .len = bytes.len, .hash = h };
        self.hash_memo_next +%= 1;
        return h;
    }

    /// Resolves an image `src` (data: URI or a key of the `images` option) to a decoded,
    /// premultiplied pixmap (cached across renders by content hash). null = paints nothing.
    /// Animated GIF / WebP / APNG sources show the frame at the render's `timeMs` (looping over
    /// the animation's total duration, like takumi `AnimatedSource::frame_at_time`) when
    /// animation support and the animated decoders are compiled in; otherwise their first frame.
    /// SVG sources resolve to null here (see `resolveSvg`).
    pub fn resolveImage(self: *Renderer, src: []const u8) ?*const raster.Pixmap {
        var bytes: []const u8 = undefined;
        var raw: ?*const ImageEntry = null;
        if (std.mem.startsWith(u8, src, "data:")) {
            bytes = decodeDataUri(self.arena.allocator(), src) orelse return null;
        } else if (self.findImage(src)) |e| {
            bytes = e.data;
            if (e.width != 0) raw = e;
        } else return null;

        // `limits` (a source over them paints nothing, like one that fails to decode)
        const lim = self.limits;
        if (raw) |e| {
            if (@as(u64, e.width) * e.height > lim.image_pixels) return null;
        } else if (self.imageOverLimit(bytes) != null) return null;

        // (XxHash64: 64-bit multiplies only; Wyhash's 128-bit products are emulated on wasm32)
        const key = self.contentHash(bytes);
        if (comptime config.enable_animation and config.enable_extra_codecs) {
            if (raw == null and self.time_ms > 0) {
                if (self.animatedFrame(key, bytes)) |pm| return pm;
            }
        }
        if (self.cacheLookup(key, 0, 0)) |pm| {
            // (decoded by an earlier call under looser limits)
            return if (@as(u64, pm.width) * pm.height > lim.image_pixels) null else pm;
        }

        var pm: raster.Pixmap = undefined;
        if (raw) |e| {
            pm = raster.Pixmap.init(self.gpa, e.width, e.height) catch return null;
            @memcpy(pm.data, bytes);
            if (!e.premultiplied) premultiply(pm.data);
        } else {
            if (codec.sniff(bytes) == .unknown) return null; // SVG, text, unsupported formats
            if (std.mem.indexOfScalar(u64, self.img_failed.items, key) != null) return null;
            const img = codec.decodeEx(self.gpa, bytes, self.codecLimits(), codec.build_decoders) catch |err| {
                // (out of memory may pass: only a decoder's verdict on the bytes is remembered; a size
                // verdict under lowered limits is not the bytes' own)
                if (err != error.OutOfMemory and !(err == error.ImageTooLarge and lim.image_pixels < max_image_pixels)) {
                    if (self.img_failed.items.len >= 1024) self.img_failed.clearRetainingCapacity();
                    self.img_failed.append(self.gpa, key) catch {};
                }
                return null;
            };
            premultiply(img.data);
            pm = .{ .width = img.width, .height = img.height, .data = img.data };
        }
        return self.cacheStore(key, 0, 0, pm) orelse {
            pm.deinit(self.gpa);
            return null;
        };
    }

    /// Largest decoded image: one image may fill the whole decoded-image cache budget.
    pub const max_image_pixels: u64 = image_budget / 4;

    /// Frame of an animated source shown at `self.time_ms` (null: still image / frame 0 / error,
    /// the caller then decodes normally). Cached per (content, frame index).
    noinline fn animatedFrame(self: *Renderer, key: u64, bytes: []const u8) ?*const raster.Pixmap {
        const n = codec.frameCount(bytes);
        if (n <= 1) return null;
        const limits = self.codecLimits();
        // pass 1: frame delays -> total loop duration -> frame index
        var delays: std.ArrayList(u32) = .empty;
        defer delays.deinit(self.gpa);
        {
            var an = codec.anim.Animator.init(self.gpa, bytes, limits) catch return null;
            defer an.deinit();
            while (an.next() catch return null) |d| delays.append(self.gpa, d) catch return null;
        }
        var total: u64 = 0;
        for (delays.items) |d| total += d;
        if (total == 0 or delays.items.len <= 1) return null;
        const target = @as(u64, @intFromFloat(self.time_ms)) % total;
        var idx: u32 = @intCast(delays.items.len - 1);
        var acc: u64 = 0;
        for (delays.items, 0..) |d, k| {
            acc += d;
            if (target < acc) {
                idx = @intCast(k);
                break;
            }
        }
        if (idx == 0) return null;
        const fkey = key ^ (@as(u64, idx) *% 0x9E3779B97F4A7C15);
        if (self.cacheLookup(fkey, 0, 0)) |pm| return if (@as(u64, pm.width) * pm.height > limits.max_pixels) null else pm;
        const fr = codec.decodeFrame(self.gpa, bytes, idx, limits) catch return null;
        premultiply(fr.image.data);
        var pm: raster.Pixmap = .{ .width = fr.image.width, .height = fr.image.height, .data = fr.image.data };
        return self.cacheStore(fkey, 0, 0, pm) orelse {
            pm.deinit(self.gpa);
            return null;
        };
    }

    /// SVG markup behind an image `src` / `url()`: inline markup (takumi: a string that starts like
    /// `<svg`), a `data:` URI (base64 or percent-encoded, decoded into the per-render arena) or an
    /// `images` option entry, when the bytes sniff as SVG. null when SVG support is compiled out.
    /// The slice is valid for the current render.
    /// Markup over `limits.maxImageBytes` paints nothing.
    pub fn resolveSvg(self: *Renderer, src: []const u8) ?[]const u8 {
        if (comptime !config.enable_svg) return null;
        const markup = blk: {
            if (std.mem.startsWith(u8, src, "data:")) break :blk decodeDataUri(self.arena.allocator(), src) orelse return null;
            if (svgm.looksLikeSvg(src)) return if (src.len > self.limits.image_bytes) null else src;
            const e = self.findImage(src) orelse return null;
            if (e.width != 0) return null;
            break :blk e.data;
        };
        if (!svgm.looksLikeSvg(markup) or markup.len > self.limits.image_bytes) return null;
        return markup;
    }

    /// Alias of `resolveSvg` (the name paint_svg.zig probes for).
    pub fn svgSource(self: *Renderer, src: []const u8) ?[]const u8 {
        return self.resolveSvg(src);
    }

    /// Catmull-Rom (or, `nearest`, nearest-neighbour) downscaled variant of a cached image (cached as well).
    pub fn resampled(self: *Renderer, src: *const raster.Pixmap, tw: u32, th: u32, nearest: bool) *const raster.Pixmap {
        if (tw == 0 or th == 0 or (tw >= src.width and th >= src.height)) return src;
        var w = @min(tw, src.width);
        var h = @min(th, src.height);
        if (nearest) {
            // takumi `DecodeTarget::covering`: one uniform scale covering the box, never upscaling
            const sw: f32 = @floatFromInt(src.width);
            const sh: f32 = @floatFromInt(src.height);
            const s = @min(1.0, @max(@as(f32, @floatFromInt(tw)) / sw, @as(f32, @floatFromInt(th)) / sh));
            w = @intFromFloat(std.math.clamp(@round(sw * s), 1, sw));
            h = @intFromFloat(std.math.clamp(@round(sh * s), 1, sh));
            if (w >= src.width and h >= src.height) return src;
        }
        const key = @as(u64, @intFromPtr(src.data.ptr)) ^ @as(u64, if (nearest) 0x51ed270b27a4f1c3 else 0x9e3779b97f4a7c15);
        if (self.cacheLookup(key, w, h)) |pm| return pm;
        const pm = (if (nearest) raster.resampleNearest(self.gpa, src, w, h) else raster.resample(self.gpa, src, w, h)) catch return src;
        return self.cacheStore(key, w, h, pm) orelse blk: {
            // could not cache: keep it alive in the arena instead
            const a = self.arena.allocator();
            const copy = a.create(raster.Pixmap) catch break :blk src;
            copy.* = raster.Pixmap.init(a, w, h) catch break :blk src;
            @memcpy(copy.data, pm.data);
            var tmp = pm;
            tmp.deinit(self.gpa);
            break :blk copy;
        };
    }
};

pub const SvgSize = struct { w: f32, h: f32, ratio: f32 };

/// Root `width` / `height` attribute of an SVG image source in CSS px, resolved like takumi's
/// image sizing: font-relative units against 12 px (em, rem) / 6 px (ex), absolute units at
/// 96 dpi; percentages and anything else = not specified.
fn svgLength(attr: ?[]const u8) ?f32 {
    const s = std.mem.trim(u8, attr orelse return null, " \t\r\n\x0c");
    const r = json.parseNumber(s) orelse return null;
    const v: f32 = @floatCast(r.value);
    const u = s[r.len..];
    const k: f32 = if (u.len == 0 or std.ascii.eqlIgnoreCase(u, "px")) 1 else if (std.ascii.eqlIgnoreCase(u, "em") or std.ascii.eqlIgnoreCase(u, "rem")) 12 else if (std.ascii.eqlIgnoreCase(u, "ex")) 6 else if (std.ascii.eqlIgnoreCase(u, "pt")) 4.0 / 3.0 else if (std.ascii.eqlIgnoreCase(u, "pc")) 16 else if (std.ascii.eqlIgnoreCase(u, "in")) 96 else if (std.ascii.eqlIgnoreCase(u, "cm")) 96.0 / 2.54 else if (std.ascii.eqlIgnoreCase(u, "mm")) 96.0 / 25.4 else if (std.ascii.eqlIgnoreCase(u, "q")) 96.0 / 101.6 else return null;
    const px = v * k;
    return if (px > 0 and px < 1.0e7) px else null;
}

/// Natural size (device px) and ratio of an SVG image source, mirroring takumi (EMPIRICAL,
/// bench/probe/anim/svgsize*.mjs): width + height -> that size; one of them + a viewBox -> the
/// other from the viewBox ratio; one of them without a viewBox -> the other defaults to 300 / 150
/// (no natural ratio); only a viewBox -> no natural size, ratio only; nothing -> 300 x 150.
pub fn svgSizeFrom(w_attr: ?f32, h_attr: ?f32, view_box: ?[4]f32, dpr: f32) SvgSize {
    var vr: f32 = 0;
    if (view_box) |vb| {
        if (vb[2] > 0 and vb[3] > 0) vr = vb[2] / vb[3];
    }
    if (w_attr) |w| {
        if (h_attr) |h| return .{ .w = w * dpr, .h = h * dpr, .ratio = w / h };
        if (vr > 0) return .{ .w = w * dpr, .h = w / vr * dpr, .ratio = vr };
        return .{ .w = w * dpr, .h = 150 * dpr, .ratio = 0 };
    }
    if (h_attr) |h| {
        if (vr > 0) return .{ .w = h * vr * dpr, .h = h * dpr, .ratio = vr };
        return .{ .w = 300 * dpr, .h = h * dpr, .ratio = 0 };
    }
    if (vr > 0) return .{ .w = 0, .h = 0, .ratio = vr };
    return .{ .w = 300 * dpr, .h = 150 * dpr, .ratio = 0 };
}

pub fn svgIntrinsic(doc: *const svgm.Document, dpr: f32) SvgSize {
    const root = doc.root();
    return svgSizeFrom(svgLength(root.attr("width")), svgLength(root.attr("height")), svgm.intrinsicSize(doc).view_box, dpr);
}

/// Decimal text of `n` in `buf` (no std.fmt).
fn decimal(buf: []u8, n_in: u64) []const u8 {
    var n = n_in;
    var i: usize = buf.len;
    while (true) {
        i -= 1;
        buf[i] = @intCast('0' + n % 10);
        n /= 10;
        if (n == 0 or i == 0) break;
    }
    return buf[i..];
}

fn dimOpt(n: f32) u32 {
    if (!(n >= 1)) return 0;
    return @intFromFloat(@min(n, 16384));
}

/// 2^32 / (2a), rounded up: `(n * recip[a]) >> 32 == n / (2a)` for every n < 2^17.
const recip: [256]u32 = blk: {
    @setEvalBranchQuota(4000);
    var t: [256]u32 = undefined;
    t[0] = 0;
    for (1..256) |a| t[a] = @intCast(((@as(u64, 1) << 32) + 2 * @as(u64, a) - 1) / (2 * @as(u64, a)));
    break :blk t;
};

/// In-place premultiplied -> straight alpha with takumi's rounding `(c*510 + a) / (2a)`.
pub fn unpremultiply(data: []u8) void {
    var i: usize = 0;
    const n = data.len & ~@as(usize, 3);
    var lut: [256]u8 = undefined;
    var lut_a: u32 = 256; // alpha the LUT was built for
    var prev_a: u32 = 256;
    const alphas: u64 = 0xFF000000_FF000000;
    while (i < n) {
        // fast skip over fully opaque / fully transparent runs, two pixels at a time
        while (i + 8 <= n) {
            const two = @as(*align(1) const u64, @ptrCast(data[i..].ptr)).* & alphas;
            if (two != alphas and two != 0) break;
            i += 8;
            // inside a run: eight pixels at a time (a pure comparison of pixels this loop
            // would skip pair by pair; plain 64-bit words, so wasm and native do the same)
            while (i + 32 <= n) {
                const q: [*]align(1) const u64 = @ptrCast(data[i..].ptr);
                if ((q[0] & q[1] & q[2] & q[3] & alphas) != alphas and ((q[0] | q[1] | q[2] | q[3]) & alphas) != 0) break;
                i += 32;
            }
        }
        if (i >= n) break;
        const a: u32 = data[i + 3];
        if (a == 0) {
            data[i] = 0;
            data[i + 1] = 0;
            data[i + 2] = 0;
        } else if (a != 255) {
            if (a == lut_a) {
                data[i] = lut[data[i]];
                data[i + 1] = lut[data[i + 1]];
                data[i + 2] = lut[data[i + 2]];
            } else {
                const m: u64 = recip[a];
                if (a == prev_a) {
                    // a run of the same alpha: build a per-alpha table once
                    for (&lut, 0..) |*e, c| e.* = @intCast(@min(255, (@as(u64, @as(u32, @intCast(c)) * 510 + a) * m) >> 32));
                    lut_a = a;
                }
                inline for (0..3) |k| {
                    const v: u32 = @intCast((@as(u64, @as(u32, data[i + k]) * 510 + a) * m) >> 32);
                    data[i + k] = @intCast(@min(v, 255));
                }
            }
        }
        prev_a = a;
        i += 4;
    }
}

test "unpremultiply matches the division formula" {
    var buf: [4]u8 = undefined;
    var a: u32 = 1;
    while (a < 256) : (a += 1) {
        var c: u32 = 0;
        while (c < 256) : (c += 1) {
            buf = .{ @intCast(c), @intCast(c), @intCast(c), @intCast(a) };
            unpremultiply(&buf);
            const want: u32 = @min(255, (c * 510 + a) / (2 * a));
            try std.testing.expectEqual(want, @as(u32, buf[0]));
        }
    }
}

test "unpremultiply: runs of opaque / transparent / translucent pixels at every alignment" {
    // premultiplied input (c <= a), runs of random length, every buffer length around the
    // 64-byte and 8-byte skip loops; reference = the per-pixel formula
    var buf: [4 * 331]u8 = undefined;
    var ref: [4 * 331]u8 = undefined;
    var seed: u64 = 0x9E3779B97F4A7C15;
    for (0..200) |round| {
        var px: usize = 0;
        while (px < 331) {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            const kind = (seed >> 33) % 4;
            const len = @min(331 - px, 1 + (seed >> 40) % @as(u64, if (round % 2 == 0) 90 else 5));
            for (0..len) |_| {
                seed = seed *% 6364136223846793005 +% 1442695040888963407;
                const a: u32 = switch (kind) {
                    0 => 255,
                    1 => 0,
                    2 => 128,
                    else => @truncate(seed >> 44 & 0xff),
                };
                inline for (0..3) |k| buf[px * 4 + k] = @intCast((@as(u32, @truncate(seed >> (12 + 8 * k) & 0xff)) * a + 127) / 255);
                buf[px * 4 + 3] = @intCast(a);
                px += 1;
            }
        }
        const n = buf.len - 4 * (round % 23);
        for (0..n / 4) |i| {
            const a: u32 = buf[i * 4 + 3];
            inline for (0..3) |k| ref[i * 4 + k] = if (a == 0) 0 else @intCast(@min(255, (@as(u32, buf[i * 4 + k]) * 510 + a) / (2 * a)));
            ref[i * 4 + 3] = @intCast(a);
        }
        unpremultiply(buf[0..n]);
        try std.testing.expectEqualSlices(u8, ref[0..n], buf[0..n]);
    }
    unpremultiply(buf[0..0]);
    unpremultiply(buf[0..3]);
}

fn premultiply(data: []u8) void {
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        const a: u32 = data[i + 3];
        if (a == 255) continue;
        data[i] = @intCast(raster.div255(@as(u32, data[i]) * a));
        data[i + 1] = @intCast(raster.div255(@as(u32, data[i + 1]) * a));
        data[i + 2] = @intCast(raster.div255(@as(u32, data[i + 2]) * a));
    }
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// RFC 3986 percent-decoding of a non-base64 `data:` payload (malformed escapes kept literally).
/// Returns `payload` itself when it holds no escape.
fn percentDecode(a: Allocator, payload: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, payload, '%') == null) return payload;
    const out = a.alloc(u8, payload.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < payload.len) : (i += 1) {
        const c = payload[i];
        if (c == '%' and i + 2 < payload.len) {
            if (hexDigit(payload[i + 1])) |h| if (hexDigit(payload[i + 2])) |l| {
                out[n] = h * 16 + l;
                n += 1;
                i += 2;
                continue;
            };
        }
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

/// Payload bytes of a `data:` URI (base64 decoded, or percent-decoded), in `a`.
/// Base64 digit values (standard and URL-safe alphabets); 0xff: skipped.
const base64_values: [256]u8 = blk: {
    var t: [256]u8 = @splat(0xff);
    for ('A'..'Z' + 1) |c| t[c] = c - 'A';
    for ('a'..'z' + 1) |c| t[c] = c - 'a' + 26;
    for ('0'..'9' + 1) |c| t[c] = c - '0' + 52;
    t['+'] = 62;
    t['-'] = 62;
    t['/'] = 63;
    t['_'] = 63;
    break :blk t;
};

pub fn decodeDataUri(a: Allocator, src: []const u8) ?[]const u8 {
    const comma = std.mem.indexOfScalar(u8, src, ',') orelse return null;
    const meta = src[5..comma];
    const payload = src[comma + 1 ..];
    if (!std.ascii.endsWithIgnoreCase(meta, ";base64")) return percentDecode(a, payload);
    const out = a.alloc(u8, payload.len / 4 * 3 + 3) catch return null;
    var n: usize = 0;
    var acc: u32 = 0;
    var bits: u32 = 0;
    var i: usize = 0;
    // four valid characters at a time while the bit buffer is empty (the common case: no
    // whitespace or padding inside the payload)
    while (i + 4 <= payload.len) {
        const q = payload[i..][0..4];
        const v0 = base64_values[q[0]];
        const v1 = base64_values[q[1]];
        const v2 = base64_values[q[2]];
        const v3 = base64_values[q[3]];
        if (bits != 0 or (v0 | v1 | v2 | v3) >= 64) break;
        const w = (@as(u32, v0) << 18) | (@as(u32, v1) << 12) | (@as(u32, v2) << 6) | v3;
        out[n] = @truncate(w >> 16);
        out[n + 1] = @truncate(w >> 8);
        out[n + 2] = @truncate(w);
        n += 3;
        i += 4;
    }
    for (payload[i..]) |c| {
        const v: u32 = base64_values[c];
        if (v >= 64) continue;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n] = @truncate(acc >> @intCast(bits));
            n += 1;
        }
    }
    return out[0..n];
}

pub fn writeJsonString(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Error!void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    try out.appendSlice(a, "\\u00");
                    try out.append(a, hex[c >> 4]);
                    try out.append(a, hex[c & 15]);
                } else try out.append(a, c);
            },
        }
    }
    try out.append(a, '"');
}

/// `,"transform":[a,b,c,d,e,f]` of a measured node (exact f32 values).
fn writeAffine(a: Allocator, out: *std.ArrayList(u8), t: mx.Affine) Error!void {
    try out.appendSlice(a, ",\"transform\":[");
    for ([6]f32{ t.a, t.b, t.c, t.d, t.e, t.f }, 0..) |v, i| {
        if (i > 0) try out.append(a, ',');
        try mx.writeExact(a, out, v);
    }
    try out.append(a, ']');
}

/// Decimal printer (up to 6 fraction digits, trailing zeros trimmed) without std.fmt.
pub fn writeNum(a: Allocator, out: *std.ArrayList(u8), v_in: f32) Error!void {
    var v: f64 = v_in;
    if (!(v == v) or @abs(v) > 1.0e15) v = 0;
    if (v < 0) {
        try out.append(a, '-');
        v = -v;
    }
    var scaled: u64 = @intFromFloat(@floor(v * 1.0e6 + 0.5));
    const int_part = scaled / 1_000_000;
    scaled %= 1_000_000;
    var buf: [24]u8 = undefined;
    var n: usize = buf.len;
    var ip = int_part;
    while (true) {
        n -= 1;
        buf[n] = @intCast('0' + ip % 10);
        ip /= 10;
        if (ip == 0) break;
    }
    try out.appendSlice(a, buf[n..]);
    if (scaled != 0) {
        var frac: [6]u8 = undefined;
        var i: usize = 6;
        while (i > 0) {
            i -= 1;
            frac[i] = @intCast('0' + scaled % 10);
            scaled /= 10;
        }
        var end: usize = 6;
        while (end > 0 and frac[end - 1] == '0') end -= 1;
        try out.append(a, '.');
        try out.appendSlice(a, frac[0..end]);
    }
}

// ------------------------------------------------------------------------------------------------

/// Hash map contexts of the per-frame caches: the default (Wyhash) multiplies 128-bit numbers,
/// emulated on wasm32.
const AddrContext = struct {
    pub fn hash(_: AddrContext, k: usize) u64 {
        const h = @as(u64, k) *% 0x9E3779B97F4A7C15;
        return h ^ (h >> 29);
    }
    pub fn eql(_: AddrContext, a: usize, b: usize) bool {
        return a == b;
    }
};
const TextContext = struct {
    pub fn hash(_: TextContext, k: []const u8) u64 {
        return std.hash.XxHash64.hash(0, k);
    }
    pub fn eql(_: TextContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

/// The last few distinct computed styles made under one parent style (`Frame.shareStyle`).
const StyleShare = struct { recent: [8]*const CS = undefined, n: usize = 0, next: usize = 0 };

pub const Frame = struct {
    r: *Renderer,
    a: Allocator,
    opts: Options,
    ctx: style.Context,
    tree: LTree,
    nodes: std.ArrayList(Node) = .empty,
    /// TextStyle.user -> style of the run (colour, decorations)
    run_styles: std.ArrayList(*const CS) = .empty,
    lid_node: std.ArrayList(u32) = .empty,
    root: u32 = none,
    lroot: u32 = none,
    /// Resource discovery stops after the cascade and generated content, before shaping/layout.
    needs_only: bool = false,
    canvas_w: u32 = 0,
    canvas_h: u32 = 0,
    /// Source elements (JSON or HTML) with their computed styles.
    dom: dom_mod.Dom = .{},
    /// Generated boxes (`::before` / `::after`, and the own text of a text element that has them).
    pseudos: std.ArrayList(Pseudo) = .empty,
    /// Stylesheet rules are active (selector matching runs for every element).
    css_on: bool = false,
    cssx: CssState = .{},
    /// Already parsed JSON node tree (renderAnimation scenes); used instead of the source text.
    pre: ?json.Value = null,
    /// `lang` of the element being built (nearest ancestor's, else the `lang` option).
    cur_lang: []const u8 = "",
    /// Inline boxes (tagged inline elements and generated boxes whose runs join a paragraph),
    /// parents before children; `parent` = enclosing inline box index or `none`.
    inline_boxes: std.ArrayList(InlineBox) = .empty,
    /// Per run (`TextStyle.user`, parallel to `run_styles`): innermost inline box or `none`.
    run_box: std.ArrayList(u32) = .empty,
    /// Innermost inline box while collecting runs (`none` outside of one).
    cur_box: u32 = none,
    /// While collecting the runs of a paragraph: its first inline box, and the inline-level boxes met
    /// so far (built as children of the paragraph's node once it exists).
    box_base: u32 = 0,
    pend_objs: std.ArrayList(PendingObj) = .empty,
    ifc: Ifc = .{},
    /// inline boxes re-opened by block-in-inline splits so far (see `max_split_boxes`)
    split_boxes: u32 = 0,
    /// direction of the block whose paragraph is being made (`paragraphBoxes`)
    ifc_rtl: bool = false,
    /// The next paragraph made is an anonymous block that is not the first child of its container:
    /// it has no first formatted line for `text-indent` (Blink: CanContainFirstFormattedLine)
    no_indent: bool = false,
    /// A line layout could not be allocated during the layout pass.
    layout_oom: bool = false,
    /// The inputs mention a Tailwind theme variable (`--color-*`, `--spacing`, `--breakpoint-*`, ...):
    /// `tw` compiles with theme lookups (else every utility keeps its built-in value).
    tw_theme: bool = false,
    /// Computed style of the root element once styled (`--breakpoint-*` lookups).
    tw_root_cs: ?*const CS = null,
    /// The last distinct computed styles made under each parent style (`shareStyle`): an element
    /// whose style comes out equal to one of them takes the same one.
    style_share: std.HashMapUnmanaged(usize, StyleShare, AddrContext, std.hash_map.default_max_load_percentage) = .empty,
    /// The style of an anonymous line container by its block's style (`openAnonBox`): it only
    /// inherits, so one per block style.
    anon_styles: std.HashMapUnmanaged(usize, *const CS, AddrContext, std.hash_map.default_max_load_percentage) = .empty,
    /// The style `styleElement` computes into before `shareStyle` keeps or drops it.
    style_tmp: ?*CS = null,
    /// parsed inline `style` attributes by text (`parseInline`)
    inline_decls: std.HashMapUnmanaged([]const u8, []const style.Declaration, TextContext, std.hash_map.default_max_load_percentage) = .empty,
    /// (PDF frames) the CSS counters while the tree is styled (src/pdf/css_counters.zig)
    css_counters: if (config.enable_pdf) ?*CssCounters else void = if (config.enable_pdf) null else {},
    // (the paged-layout state, PDF feature only, is `tree.paged`: `layout.fragment.PagedState`. A field here,
    // even a zero-size one, perturbs the struct layout and grows the other builds.)

    pub const Pseudo = struct {
        cs: *const CS,
        text: []const u8,
        parts: ?[]const @import("generated_content.zig").Part = null,
        generated_el: ?u32 = null,
    };

    const CssState = if (config.enable_css) struct {
        m: css.Matcher = .{},
        scratch: css.Scratch = undefined,
        decls: std.ArrayList(css.Declaration) = .empty,
        vt: css.Dom = undefined,
    } else struct {};

    fn fail(f: *Frame, msg: []const u8, detail: []const u8) Error {
        f.r.setErr(msg, detail);
        return error.Invalid;
    }

    /// Keyframes of `name` from the stylesheet (`@keyframes`) or the deprecated `keyframes` option;
    /// null when undefined or when CSS support is compiled out. For the animation pass.
    pub fn keyframes(f: *const Frame, name: []const u8) ?[]const css.Keyframe {
        if (comptime !config.enable_css) return null;
        return css.keyframes(&f.cssx.m, name);
    }

    pub fn prepare(f: *Frame, kind: SourceKind, source: []const u8) Error!void {
        try f.prepareDocument(kind, source);
        if (f.needs_only) return;
        try f.prepareLayout();
    }

    /// The document part of `prepare`: the element model, the cascade, the generated content. What
    /// it makes is only read afterwards, so frames laying out parts of the document can share it
    /// (`initChunk`).
    pub fn prepareDocument(f: *Frame, kind: SourceKind, source: []const u8) Error!void {
        const o = f.opts;
        f.ctx = .{
            .dpr = o.dpr,
            .viewport_w = if (o.width) |w| @floatFromInt(w) else 0,
            .viewport_h = if (o.height) |h| @floatFromInt(h) else 0,
            .viewport_h_unbounded = o.height == null,
            .root_font_size = 16 * o.dpr,
        };
        // (the paged-output properties are computed for the frames a PDF is drawn from only)
        if (comptime layout.fragment.enabled and style.props.pdf_build) f.ctx.paged = f.tree.paged.pdf or f.tree.paged.page_h > 0;
        if (comptime layout.fragment.enabled) if (f.tree.paged.page_h > 0) {
            // paged (takumi-pdf `PageFrame::column`): viewport units take the page area, fixed boxes
            // position against it, the block size is unbounded (`opts.height` is null)
            f.ctx.viewport_w = f.tree.paged.page_w;
            f.ctx.viewport_h = f.tree.paged.page_h;
        };
        if (comptime layout.fragment.enabled) if (f.tree.paged.units) |u| {
            f.ctx.viewport_w = u[0];
            f.ctx.viewport_h = u[1];
        };
        f.dom = .{ .lang = o.lang, .max_depth = @min(max_node_depth, f.r.limits.node_depth) };
        switch (kind) {
            .json => {
                const v = f.pre orelse json.parse(f.a, source) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.JsonTooDeep => return f.tooDeep(),
                    else => return f.fail("invalid node JSON", ""),
                };
                f.dom.fromJson(f.a, v) catch |e| return f.domError(e);
            },
            .html => {
                if (comptime !config.enable_html) return f.fail("HTML input is not supported by this build", "");
                const doc = html.parse(f.a, source) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.TooDeep => return f.tooDeep(),
                };
                f.dom.fromHtml(f.a, html, &doc) catch |e| return f.domError(e);
            },
        }
        // (PDF page counters fill their class hooks here: src/pdf/counters.zig)
        if (comptime layout.fragment.enabled) if (f.tree.paged.dom_hook) |hook| try hook(f.tree.paged.dom_ctx, @ptrCast(f));
        if (comptime config.enable_css) {
            try f.prepareCss();
        } else if (nonEmpty(o.css) or nonEmpty(o.stylesheets)) {
            return f.fail("the `css` option is not supported by this build", "");
        }
        if (comptime config.enable_tw) if (hasThemeVar(source)) {
            f.tw_theme = true;
        };
        @import("memtrace.zig").mark("frame: parsed, css");
        try f.styleTree(f.dom.root, null, 0);
        @import("memtrace.zig").mark("frame: styled");
        if (comptime config.enable_svg and config.enable_css) try @import("svg/html_cascade.zig").generate(f);
        try @import("text_control.zig").generate(f);
        // (PDF list markers: src/pdf/markers.zig, gated by `listMarkers`)
        if (comptime config.enable_pdf) if (f.listMarkers()) try @import("pdf/markers.zig").generate(f);
        try @import("generated_content.zig").generate(f);
        // (PDF: named pages, the `page` property: src/pdf/page_names.zig)
        if (comptime config.enable_pdf) if (f.tree.paged.pdf) try @import("pdf/page_names.zig").collect(f);
    }

    /// The layout part of `prepare`: the render nodes and their layout.
    pub fn prepareLayout(f: *Frame) Error!void {
        const o = f.opts;
        f.cur_lang = o.lang;
        f.root = try f.buildElement(f.dom.root, none, 0);
        // (PDF: a paragraph continued on a page of another width, src/pdf/paged.zig)
        if (comptime config.enable_pdf and layout.fragment.enabled) if (f.tree.paged.cut_node < f.nodes.items.len) {
            if (f.nodes.items[f.tree.paged.cut_node].para) |p| p.cut = f.tree.paged.cut_glyph;
        };
        if (comptime config.enable_pdf and layout.fragment.enabled) for (f.tree.paged.cuts) |cut| {
            if (cut.node < f.nodes.items.len) if (f.nodes.items[cut.node].para) |p| {
                p.cut = cut.glyph;
            };
        };

        // The layout root is the root element itself; the available size is the initial containing
        // block (the engine resolves the root's percentages, margins and fixed boxes against it). Like
        // takumi, a relative offset or auto margins of the root move nothing. An out-of-flow root is
        // placed by its insets inside an explicit initial containing block node (one more layout
        // level, so such a tree reaches the layout engine's depth limit one level earlier).
        // PDF differs: takumi-pdf lays the root out as a block child of the page frame, so its relative
        // offset and its auto inline margins apply (document and header / footer bands alike); such a
        // root is placed inside the same containing block node.
        const rcs = f.nodes.items[f.root].cs;
        // (at most one layout node per render node, plus the containing block: reserved at once, see
        // `LTree.ensureCapacity`)
        f.tree.ensureCapacity(f.tree.nodes.items.len + f.nodes.items.len + 1) catch return error.OutOfMemory;
        try f.lid_node.ensureTotalCapacityPrecise(f.a, f.tree.nodes.items.len + f.nodes.items.len + 1);
        @import("memtrace.zig").mark("frame: render nodes");
        const lr = try f.buildLayout(f.root);
        f.lroot = lr;
        const out_of_flow = rcs.position == .absolute or rcs.position == .fixed;
        if (out_of_flow or f.pdfRootInFlow(lr)) {
            var icb: layout.Style = .{ .display = .block };
            // (an in-flow PDF root: an auto width stretches the block to the available width, which is
            // the page area's exact width when paged)
            if (o.width) |w| if (out_of_flow) {
                icb.size[0] = .{ .px = @floatFromInt(w) };
            };
            if (o.height) |h| icb.size[1] = .{ .px = @floatFromInt(h) };
            f.lroot = f.tree.addNode(icb) catch return error.OutOfMemory;
            f.tree.appendChild(f.lroot, lr) catch return error.OutOfMemory;
        }
        const avail: [2]layout.AvailableSpace = .{
            // (paged: the page area's exact width, takumi-pdf's `PageSizer` area, not the integral
            // viewport)
            pw: {
                if (comptime layout.fragment.enabled) if (f.tree.paged.page_h > 0) break :pw .{ .definite = f.tree.paged.page_w };
                break :pw if (o.width) |w| .{ .definite = @floatFromInt(w) } else .max_content;
            },
            if (o.height) |h| .{ .definite = @floatFromInt(h) } else .max_content,
        };
        f.tree.compute(f.lroot, avail, f, measureCb, .{ .quantize64 = true, .baseline = baselineCb, .inline_fn = inlineCb }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return f.fail("node tree is nested too deeply", ""),
        };
        if (f.layout_oom) return error.OutOfMemory;
        @import("memtrace.zig").mark("frame: laid out");
        if (comptime layout.fragment.enabled) if (f.tree.paged.page_h > 0) {
            // (any length of content, even none, makes pages: the canvas is one page area)
            f.canvas_w = o.width orelse 1;
            f.canvas_h = @intFromFloat(@max(1, @min(@ceil(f.tree.paged.page_h), 16384)));
            return;
        };
        // (an in-flow PDF root in its containing block: the content size is the block's, without the
        // root's relative offset, which moves the root but sizes nothing; see `rootBlockEnd`)
        const rl = f.tree.layout(if (f.lroot != lr and !out_of_flow) f.lroot else lr);
        const cw: f32 = if (o.width) |w| @floatFromInt(w) else @floor(rl.x + rl.w + rl.margin.right + 0.5);
        const ch: f32 = if (o.height) |h| @floatFromInt(h) else @floor(rl.y + rl.h + rl.margin.bottom + 0.5);
        if (!(cw >= 1) or !(ch >= 1)) {
            // (PDF: a content-sized page is checked by the PDF writer, takumi-pdf `InvalidPageSize`, and
            // `measurePdf` reports the zero size)
            if (comptime layout.fragment.enabled) if (f.tree.paged.pdf) {
                f.canvas_w = @intFromFloat(@max(1, @min(cw, 16384)));
                f.canvas_h = @intFromFloat(@max(1, @min(ch, 16384)));
                return;
            };
            return f.fail("invalid viewport: content has zero size and no width/height was given", "");
        }
        // (PDF: a page has no pixel canvas, takumi-pdf takes any finite viewport)
        if (comptime layout.fragment.enabled) if (f.tree.paged.pdf) {
            f.canvas_w = @intFromFloat(@min(cw, 16384));
            f.canvas_h = @intFromFloat(@min(ch, 16384));
            return;
        };
        if (cw > max_canvas_side or ch > max_canvas_side or cw * ch > @as(f32, @floatFromInt(max_canvas_pixels))) return f.fail("canvas too large", "");
        if (@as(u64, @intFromFloat(cw)) * @as(u64, @intFromFloat(ch)) > f.r.limits.canvas_pixels) return f.fail("canvas exceeds limits.", Limits.name(.canvas_pixels));
        f.canvas_w = @intFromFloat(cw);
        f.canvas_h = @intFromFloat(ch);
    }

    /// A frame laying out a part of `doc`'s document (src/pdf/chunks.zig): it shares `doc`'s element
    /// model, styles and generated content (`prepareDocument`), read only, and keeps its own render
    /// nodes and layout in `a`; `prepareLayout` lays it out (the part: `tree.paged.chunk`).
    pub fn initChunk(doc: *const Frame, a: Allocator) Error!Frame {
        var f: Frame = .{ .r = doc.r, .a = a, .opts = doc.opts, .ctx = doc.ctx, .tree = LTree.init(a), .pre = doc.pre };
        f.dom = doc.dom;
        f.pseudos = doc.pseudos;
        f.css_on = doc.css_on;
        f.cssx = doc.cssx;
        f.tw_theme = doc.tw_theme;
        f.tw_root_cs = doc.tw_root_cs;
        f.style_share = doc.style_share;
        f.inline_decls = doc.inline_decls;
        f.css_counters = doc.css_counters;
        f.style_tmp = doc.style_tmp;
        if (comptime layout.fragment.enabled) {
            const d = doc.tree.paged;
            f.tree.paged = .{ .page_w = d.page_w, .page_h = d.page_h, .pdf = d.pdf, .page_of = d.page_of, .page_names = d.page_names, .units = d.units, .skip_dom_styles = d.skip_dom_styles };
            if (comptime config.enable_pdf) f.tree.paged.markers = try @import("pdf/markers.zig").forChunk(doc, a);
        }
        return f;
    }

    /// THE gate of list markers (`display: list-item`, src/pdf/markers.zig; PDF builds only): the
    /// frames a PDF is drawn from generate them. Returning true here gives every frame of a PDF
    /// build its markers (the raster / SVG painters would then draw a symbol marker as the blank
    /// it holds: only the PDF text painter paints its shape, emit_text.zig `paintSymbol`); builds
    /// without the PDF feature also need markers.zig compiled in and its state moved out of
    /// `layout.fragment.PagedState`.
    fn listMarkers(f: *const Frame) bool {
        return f.tree.paged.pdf;
    }

    /// Where the root's margin box ends in the block direction (unrounded), without the root's relative
    /// offset, which moves the root but sizes nothing: what a content-sized PDF page or band is as tall
    /// as (an in-flow root placed in a containing block node, `pdfRootInFlow`, sizes that node).
    pub fn rootBlockEnd(f: *const Frame) f32 {
        const lid = f.nodes.items[f.root].lid;
        if (f.lroot != lid) {
            const s = f.tree.style(lid);
            if (s.position != .absolute and s.position != .fixed) {
                const c = f.tree.layout(f.lroot);
                return c.y + c.h;
            }
        }
        const l = f.tree.layout(lid);
        return l.y + l.h + l.margin.bottom;
    }

    /// PDF frames only: whether the root (layout node `lr`) has a relative offset or auto inline margins,
    /// which takumi-pdf applies (the root is a block child of its page frame) and the bare layout root
    /// would ignore.
    fn pdfRootInFlow(f: *const Frame, lr: u32) bool {
        if (comptime !layout.fragment.enabled) return false;
        if (!f.tree.paged.pdf) return false;
        const s = f.tree.style(lr);
        // (`sticky` is laid out as `relative`; takumi-pdf does not offset a sticky root)
        if (f.nodes.items[f.root].cs.position == .relative) {
            if (s.inset.left != .auto or s.inset.right != .auto or s.inset.top != .auto or s.inset.bottom != .auto) return true;
        }
        return s.margin.left == .auto or s.margin.right == .auto;
    }

    fn addNode(f: *Frame, n: Node) Error!u32 {
        try f.nodes.append(f.a, n);
        const id: u32 = @intCast(f.nodes.items.len - 1);
        const p = n.parent;
        if (p != none) {
            const pn = &f.nodes.items[p];
            if (pn.last_child == none) pn.first_child = id else f.nodes.items[pn.last_child].next = id;
            pn.last_child = id;
        }
        return id;
    }

    fn domError(f: *Frame, e: dom_mod.Error) Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Invalid => if (std.mem.eql(u8, f.dom.err_msg, too_deep)) f.tooDeep() else f.fail(f.dom.err_msg, f.dom.err_detail),
        };
    }

    const too_deep = "node tree is nested too deeply";

    /// The source nests deeper than the engine takes (or than a lowered `limits.maxNodeDepth`).
    fn tooDeep(f: *Frame) Error {
        if (f.r.limits.node_depth < max_node_depth) return f.fail("node tree exceeds limits.", Limits.name(.node_depth));
        return f.fail(too_deep, "");
    }

    fn nonEmpty(v: ?json.Value) bool {
        const x = v orelse return false;
        return switch (x) {
            .array => |arr| arr.len > 0,
            .string => |s| s.len > 0,
            .null => false,
            else => true,
        };
    }

    // ---- stylesheet (css option + HTML <style>)

    noinline fn prepareCss(f: *Frame) Error!void {
        if (comptime !config.enable_css) return;
        const a = f.a;
        const o = f.opts;
        var buf: std.ArrayList(u8) = .empty;
        // takumi: every `css` entry (or the deprecated `stylesheets` when `css` is absent) written out
        // as CSS text and concatenated, followed by the HTML source's <style> texts; parsed once.
        if (o.css orelse o.stylesheets) |list| switch (list) {
            .array => |arr| for (arr) |e| {
                if (e == .null) continue;
                css.writeCssInput(a, &buf, e) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidRule => return f.fail("invalid css rule object", ""),
                };
            },
            .string => |s| try buf.appendSlice(a, s),
            else => return f.fail("the `css` option must be an array", ""),
        };
        const own_styles = if (comptime layout.fragment.enabled) !f.tree.paged.skip_dom_styles else true;
        if (own_styles) for (f.dom.styles) |s| try buf.appendSlice(a, s);
        if (comptime config.enable_tw) if (hasThemeVar(buf.items)) {
            f.tw_theme = true;
        };
        var sheet: css.Stylesheet = .{};
        if (buf.items.len > 0) try css.parse(a, buf.items, &sheet);
        if (comptime config.enable_animation) if (o.keyframes) |k| css.addKeyframesJson(a, &sheet, k) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRule => return f.fail("invalid keyframes option", ""),
        };
        if (sheet.rules.items.len == 0 and sheet.keyframes.items.len == 0 and sheet.extra_keyframes.items.len == 0 and sheet.font_faces.items.len == 0 and !sheet.preflight) return;
        const st = &f.cssx;
        st.m = try css.prepare(a, &sheet, .{
            .viewport_w = if (o.width) |w| @floatFromInt(w) else null,
            .viewport_h = if (o.height) |h| @floatFromInt(h) else null,
            .dpr = o.dpr,
            .supports = cssSupports,
            // PDF output is print media (takumi-pdf `Viewport::with_media_target(MediaTarget::Print)`)
            .print = if (comptime layout.fragment.enabled) f.tree.paged.pdf else false,
        });
        st.scratch = css.Scratch.init(a);
        st.vt = CssDom.vtable(&f.dom);
        f.css_on = st.m.rules.len > 0;
    }

    pub fn cssSupports(name: []const u8, value: []const u8) bool {
        _ = value;
        if (name.len > 2 and name[0] == '-' and name[1] == '-') return true;
        return style.propertyId(name) != null;
    }

    /// Matched declarations of element `i` (or its pseudo-element) as style declarations, in cascade
    /// order with `important` flags (the style module orders normal < important itself).
    /// Matched stylesheet declarations with takumi's layer split points (indices into `decls`).
    const CssOut = struct { decls: []const style.Declaration = &.{}, unlayered: usize = 0, important: usize = 0, imp_layered: usize = 0 };

    fn cssDecls(f: *Frame, i: u32, pseudo: css.Pseudo, sets_content: ?*bool) Error!CssOut {
        const st = &f.cssx;
        st.decls.clearRetainingCapacity();
        const r = try css.match(&st.m, &st.scratch, &st.vt, i, pseudo, &st.decls);
        if (sets_content) |p| p.* = r.sets_content;
        return .{ .decls = try convertDecls(f.a, st.decls.items), .unlayered = r.unlayered_start, .important = r.important_start, .imp_layered = r.layered_important_start };
    }

    /// Room for preset, presentation hints, the six author parts, inline style and a keyframe layer.
    pub const max_layers = 10;

    /// Appends the author origin in takumi's cascade order (matching.rs `layer_order`): normal
    /// declarations of named `@layer`s < `tw` utilities < unlayered rules; `!important` ones
    /// unlayered < `tw` < named layers. (`tw` lists its normal declarations first.)
    fn authorLayers(layers: []style.Layer, n: *usize, tw: []const style.Declaration, c: CssOut) void {
        var k: usize = 0;
        while (k < tw.len and !tw[k].important) k += 1;
        const d = c.decls;
        const parts = [_][]const style.Declaration{ d[0..c.unlayered], tw[0..k], d[c.unlayered..c.important], d[c.important..c.imp_layered], tw[k..], d[c.imp_layered..] };
        for (parts) |p| if (p.len > 0) {
            layers[n.*] = .{ .decls = p, .lenient = true };
            n.* += 1;
        };
    }

    /// Tailwind declarations of element `i` for `target` (lenient layer).
    /// Theme lookups for `tw` (takumi `TwVarRef`): a variable is defined for element `i` when its
    /// parent's computed style has it, or the element's own inline style / matched rules declare it.
    const TwTheme = struct {
        f: *Frame,
        i: u32,
        own: []const style.Declaration,

        fn defined(ctx: *const anyopaque, name: []const u8) bool {
            const t: *const TwTheme = @ptrCast(@alignCast(ctx));
            const el = t.f.dom.at(t.i);
            if (el.parent != none) if (t.f.dom.at(el.parent).cs.customProperty(name) != null) return true;
            for (t.own) |d| if (std.mem.eql(u8, d.name, name)) return true;
            return switch (el.style) {
                .json => |v| v.get(name) != null,
                .text => |s| std.mem.indexOf(u8, s, name) != null,
                .none => false,
            };
        }

        fn breakpoint(ctx: *const anyopaque, token: []const u8) ?[]const u8 {
            const t: *const TwTheme = @ptrCast(@alignCast(ctx));
            const root = t.f.tw_root_cs orelse return null;
            var buf: [96]u8 = undefined;
            const pre = "--breakpoint-";
            if (token.len > buf.len - pre.len) return null;
            @memcpy(buf[0..pre.len], pre);
            @memcpy(buf[pre.len..][0..token.len], token);
            return root.customProperty(buf[0 .. pre.len + token.len]);
        }
    };

    /// Whether `text` mentions a Tailwind theme variable namespace (`--color-`, `--spacing`, ...).
    fn hasThemeVar(text: []const u8) bool {
        const prefixes = [_][]const u8{ "color-", "spacing", "radius-", "text-", "font-", "tracking-", "leading-", "aspect-", "container-", "animate-", "breakpoint-" };
        var k: usize = 0;
        // (each "--" in order: a scan for '-', then the next byte checked)
        while (std.mem.indexOfScalarPos(u8, text, k, '-')) |p| {
            k = p + 1;
            if (p + 1 >= text.len or text[p + 1] != '-') continue;
            k = p + 2;
            for (prefixes) |pr| if (std.mem.startsWith(u8, text[k..], pr)) return true;
        }
        return false;
    }

    fn twDecls(f: *Frame, i: u32, target: twc.Target, own_css: []const style.Declaration) Error![]const style.Declaration {
        const el = f.dom.at(i);
        var env: twc.Env = .{ .viewport_w = f.ctx.viewport_w, .viewport_h = f.ctx.viewport_h, .dpr = f.opts.dpr, .target = target };
        // every variant contains ':'; only then is the structural information needed
        if (std.mem.indexOfScalar(u8, el.tw, ':') != null) {
            const info = f.dom.elementInfo(i);
            env.element = .{ .index = info.index, .count = info.count, .type_index = info.type_index, .type_count = info.type_count, .empty = info.empty };
        }
        var th: TwTheme = .{ .f = f, .i = i, .own = own_css };
        const theme: twc.Theme = .{ .ctx = &th, .defined = TwTheme.defined, .breakpoint = TwTheme.breakpoint };
        if (f.tw_theme) env.theme = &theme;
        var out: std.ArrayList(twc.Declaration) = .empty;
        twc.compile(f.a, el.tw, env, &out) catch return error.OutOfMemory;
        return convertDecls(f.a, out.items);
    }

    // ---- style pass: every element's style exactly once, top-down

    /// Styles element `root` and its subtree (parents before children, siblings in order; the CSS
    /// counters of an element are left after its subtree). A loop over an explicit stack: wasm-opt
    /// inlines `styleElement` into its only caller whatever Zig says, and a recursion carrying
    /// that frame ran out of the engine's stack before `max_node_depth`.
    fn styleTree(f: *Frame, root: u32, parent_cs: ?*const CS, depth0: u32) Error!void {
        const Step = struct { i: u32, depth: u32, leave: bool };
        var stack: std.ArrayList(Step) = .empty;
        defer stack.deinit(f.a);
        try stack.append(f.a, .{ .i = root, .depth = depth0, .leave = false });
        while (stack.pop()) |st| {
            if (st.leave) {
                if (comptime config.enable_pdf) if (f.css_counters) |cx| try f.leaveCounters(cx, st.i);
                continue;
            }
            if (st.depth >= max_node_depth) return f.fail("node tree is nested too deeply", "");
            const pcs = if (st.i == root) parent_cs else f.dom.at(f.dom.at(st.i).parent).cs;
            try f.styleElement(st.i, pcs);
            if (pcs == null) f.tw_root_cs = f.dom.at(st.i).cs;
            try stack.append(f.a, .{ .i = st.i, .depth = st.depth, .leave = true });
            // (children pushed last to first, so they come off the stack in order)
            const mark = stack.items.len;
            var c = f.dom.at(st.i).first;
            while (c != none) : (c = f.dom.at(c).next) try stack.append(f.a, .{ .i = c, .depth = st.depth + 1, .leave = false });
            std.mem.reverse(Step, stack.items[mark..]);
        }
    }

    /// (PDF frames) The CSS counters of the frame, created on first use (takumi-pdf numbers `counter()`
    /// in generated content; image frames keep `counter()` contributing nothing).
    fn cssCounters(f: *Frame) ?*CssCounters {
        if (comptime config.enable_pdf and layout.fragment.enabled) {
            if (!f.tree.paged.pdf) return null;
            if (f.css_counters == null) {
                const cx = f.a.create(CssCounters) catch return null;
                cx.* = .{ .a = f.a };
                f.css_counters = cx;
            }
            return f.css_counters;
        }
        return null;
    }

    /// (PDF frames) After the children of element `i`: its `::after` (entered last, its content read
    /// now), then the element itself leaves the counters' scope.
    noinline fn leaveCounters(f: *Frame, cx: *CssCounters, i: u32) Error!void {
        const el = f.dom.at(i);
        if (el.run) return;
        if (el.after != none) {
            const ps = &f.pseudos.items[el.after];
            try cx.enter(ps.cs.counter_reset, ps.cs.counter_increment, ps.cs.counter_set, .none);
            ps.text = (try dom_mod.contentText(f.a, ps.cs.content, &f.dom, i, cx.hook())) orelse "";
            ps.parts = try @import("generated_content.zig").read(f.a, ps.cs.content, &f.dom, i, cx.hook());
            cx.leave(ps.cs.counter_reset, ps.cs.counter_increment, ps.cs.counter_set, .none);
        }
        const cs = el.cs;
        cx.leave(cs.counter_reset, cs.counter_increment, cs.counter_set, css_counters_mod.listItemOf(&f.dom, i, cs.display == .list_item));
    }

    fn styleFail(f: *Frame, e: style.Error, diag: *const style.Diagnostics) Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidStyleValue => f.fail("invalid value for style property ", diag.property),
        };
    }

    fn jsonOf(s: dom_mod.Src) ?json.Value {
        return switch (s) {
            .json => |v| v,
            else => null,
        };
    }

    /// Declarations of a preset / inline-style source and whether the layer is lenient.
    fn srcLayer(f: *Frame, s: dom_mod.Src, diag: *style.Diagnostics) Error!style.Layer {
        return switch (s) {
            .none => .{ .decls = &.{} },
            .json => |v| .{ .decls = style.jsonDecls(f.a, v, diag) catch |e| return f.styleFail(e, diag) },
            // CSS-text sources only come from HTML input
            .text => |t| if (comptime config.enable_html) .{ .decls = try f.parseInline(t), .lenient = true } else .{ .decls = &.{} },
        };
    }

    /// `parseBlock` of an inline `style` attribute, once per distinct text (generated documents
    /// repeat the same attribute on every row / cell: one parse and one declaration list for all).
    fn parseInline(f: *Frame, t: []const u8) Error![]const style.Declaration {
        const slot = try f.inline_decls.getOrPut(f.a, t);
        if (!slot.found_existing) {
            errdefer _ = f.inline_decls.remove(t);
            slot.value_ptr.* = try parseBlock(f.a, t);
        }
        return slot.value_ptr.*;
    }

    /// Cascade layers of element `i`: preset (UA) < presentation hints < tw utilities < stylesheet
    /// rules < inline style. Returns the count written to `layers` (room for one extra layer).
    pub fn elementLayers(f: *Frame, i: u32, diag: *style.Diagnostics, layers: *[max_layers]style.Layer) Error!usize {
        const a = f.a;
        const el = f.dom.at(i);
        var n: usize = 0;
        layers[n] = try f.srcLayer(el.preset, diag);
        n += 1;
        if (el.pres.len > 0 or el.dir != .none) {
            var list: std.ArrayList(style.Declaration) = .empty;
            if (comptime config.enable_html) if (el.pres.len > 0) try list.appendSlice(a, try parseBlock(a, el.pres));
            if (el.dir != .none) try list.append(a, .{ .name = "direction", .value = if (el.dir == .rtl) "rtl" else "ltr" });
            layers[n] = .{ .decls = list.items, .lenient = true };
            n += 1;
        }
        const cs_out: CssOut = if (comptime config.enable_css) (if (f.css_on) try f.cssDecls(i, .none, null) else .{}) else .{};
        const tw: []const style.Declaration = if (comptime config.enable_tw) (if (el.tw.len > 0) try f.twDecls(i, .element, cs_out.decls) else &.{}) else &.{};
        authorLayers(layers, &n, tw, cs_out);
        layers[n] = try f.srcLayer(el.style, diag);
        n += 1;
        return n;
    }

    /// Applies the element's CSS animations at `opts.time_ms` to `cs` in place (see animate.zig).
    noinline fn animateElement(f: *Frame, i: u32, cs: *CS, parent_cs: ?*const CS) Error!void {
        const Host = struct {
            f: *Frame,
            i: u32,
            parent: ?*const CS,
            pub fn keyframes(h: @This(), name: []const u8) ?[]const css.Keyframe {
                return h.f.keyframes(name);
            }
            /// The element's style with `decls` as the top (lenient) layer.
            pub fn keyframeStyle(h: @This(), decls: []const style.Declaration) Error!*const CS {
                var diag: style.Diagnostics = .{};
                var layers: [max_layers]style.Layer = undefined;
                var n = try h.f.elementLayers(h.i, &diag, &layers);
                layers[n] = .{ .decls = decls, .lenient = true };
                n += 1;
                const out = try h.f.a.create(CS);
                out.* = style.computeLayers(h.f.a, &h.f.ctx, h.parent, layers[0..n], &diag) catch |e| return h.f.styleFail(e, &diag);
                return out;
            }
            /// The element's style with its font size forced to `px` (device px; animated font-size).
            pub fn fontSizeStyle(h: @This(), px: f32) Error!*const CS {
                var txt: std.ArrayList(u8) = .empty;
                try writeNum(h.f.a, &txt, px / h.f.opts.dpr);
                try txt.appendSlice(h.f.a, "px");
                const decls = [1]style.Declaration{.{ .name = "font-size", .value = txt.items, .important = true }};
                return h.keyframeStyle(&decls);
            }
        };
        const r = animate.apply(f.a, cs, f.opts.time_ms, Host{ .f = f, .i = i, .parent = parent_cs }) catch |e| return e;
        if (r) |x| cs.* = x.*;
    }

    noinline fn styleElement(f: *Frame, i: u32, parent_cs: ?*const CS) Error!void {
        const a = f.a;
        const el = f.dom.at(i);
        var diag: style.Diagnostics = .{};
        if (comptime !config.enable_tw) if (el.tw.len > 0) return f.fail("Tailwind (`tw`) is not supported by this build", "");
        // (computed into the frame's reused scratch style, kept only when no element under the
        // same parent style has the same one: `shareStyle`; not on the stack, which deep trees
        // need for the recursion)
        if (f.style_tmp == null) f.style_tmp = try a.create(CS);
        const cs = f.style_tmp.?;
        const has_tw = config.enable_tw and el.tw.len > 0;
        const from_html = config.enable_html and (el.preset == .text or el.style == .text or el.pres.len > 0);
        const general = !el.run and (f.css_on or has_tw or from_html or el.dir != .none);
        if (!general) {
            // fast path (JSON source, no stylesheet, no tw): exactly the phase-1 computation
            cs.* = style.compute(a, &f.ctx, parent_cs, jsonOf(el.preset), jsonOf(el.style), &diag) catch |e| return f.styleFail(e, &diag);
        } else {
            var layers: [max_layers]style.Layer = undefined;
            const n = try f.elementLayers(i, &diag, &layers);
            cs.* = style.computeLayers(a, &f.ctx, parent_cs, layers[0..n], &diag) catch |e| return f.styleFail(e, &diag);
        }
        // CSS animations sampled at `timeMs`, before the children inherit from this style
        if (comptime config.enable_animation) if (!el.run and cs.animation_name.len > 0) try f.animateElement(i, cs, parent_cs);
        if (parent_cs == null) {
            if (f.opts.font_families.len > 0 and cs.font_family.len == 0) cs.font_family = f.opts.font_families;
            f.ctx.root_font_size = cs.font_size;
        }
        if (cs.display == .contents and !el.run) {
            // display: contents (css-display-3 §2.5; a container is skipped by `Items`): the root element
            // is a block after all, a replaced element generates nothing, a text element keeps only its
            // text (its box properties go, the inherited ones stay)
            if (parent_cs == null) {
                cs.display = .block;
            } else if (el.kind == .image) {
                cs.display = .none;
            } else if (el.kind == .text) {
                try f.textOnly(cs, &diag);
            }
        }
        el.cs = try f.shareStyle(i, cs, parent_cs);
        if (comptime config.enable_pdf) if (!el.run) if (f.cssCounters()) |cx| try cx.enter(cs.counter_reset, cs.counter_increment, cs.counter_set, css_counters_mod.listItemOf(&f.dom, i, cs.display == .list_item));
        if (el.run or el.kind == .image) return;
        if (comptime config.enable_css or config.enable_tw) {
            el.before = try f.pseudoBox(i, .before);
            el.after = try f.pseudoBox(i, .after);
            if (el.kind == .text and (el.before != none or el.after != none)) {
                // the element's own text moves into an anonymous box between the generated ones
                const own = try a.create(CS);
                own.* = style.compute(a, &f.ctx, el.cs, null, null, &diag) catch |e| return f.styleFail(e, &diag);
                try f.pseudos.append(a, .{ .cs = own, .text = el.text });
                el.own = @intCast(f.pseudos.items.len - 1);
            }
        }
    }

    /// The style element `i` keeps for the computed style `cs` (built on the stack): a sibling's
    /// equal one (same parent style, every field equal, slices by their address) when there is
    /// one, else a copy in the frame, remembered for the next siblings. A long document repeats a
    /// few styles thousands of times (table cells, list items, text runs), and each takes 2 KiB.
    /// Styles are never written once assigned. Left alone: images and elements with an `href`,
    /// which other passes find by their style's address (interactive.zig `hrefMap`, svg_out.zig
    /// `imageSrcOf`).
    fn shareStyle(f: *Frame, i: u32, cs: *const CS, parent_cs: ?*const CS) Error!*const CS {
        const el = f.dom.at(i);
        if (el.kind == .image or (!el.run and f.dom.attr(i, "href") != null)) return f.keepStyle(cs);
        const slot = try f.style_share.getOrPut(f.a, if (parent_cs) |p| @intFromPtr(p) else 0);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        const sh = slot.value_ptr;
        for (sh.recent[0..sh.n]) |cand| {
            if (std.meta.eql(cand.*, cs.*)) return cand;
        }
        const kept = try f.keepStyle(cs);
        sh.recent[sh.next] = kept;
        sh.next = (sh.next + 1) % sh.recent.len;
        if (sh.n < sh.recent.len) sh.n += 1;
        return kept;
    }

    fn keepStyle(f: *Frame, cs: *const CS) Error!*const CS {
        const kept = try f.a.create(CS);
        kept.* = cs.*;
        return kept;
    }

    /// Replaces `cs` by the style of an anonymous inline box inheriting from it.
    noinline fn textOnly(f: *Frame, cs: *CS, diag: *style.Diagnostics) Error!void {
        const inh = try f.a.create(CS);
        inh.* = cs.*;
        cs.* = style.compute(f.a, &f.ctx, inh, null, null, diag) catch |e| return f.styleFail(e, diag);
    }

    /// Creates the `::before` / `::after` box of element `i` when a stylesheet rule or a Tailwind
    /// `before:` / `after:` utility sets `content` to something other than none/normal.
    fn pseudoBox(f: *Frame, i: u32, which: enum { before, after }) Error!u32 {
        const el = f.dom.at(i);
        var layers: [6]style.Layer = undefined;
        var n: usize = 0;
        var tw: []const style.Declaration = &.{};
        if (comptime config.enable_tw) {
            const key = if (which == .before) "before:" else "after:";
            if (el.tw.len > 0 and std.mem.indexOf(u8, el.tw, key) != null) tw = try f.twDecls(i, if (which == .before) .before else .after, &.{});
        }
        var cs_out: CssOut = .{};
        if (comptime config.enable_css) if (f.css_on and (if (which == .before) f.cssx.m.has_before else f.cssx.m.has_after)) {
            var sets = false;
            const d = try f.cssDecls(i, if (which == .before) .before else .after, &sets);
            if (sets) cs_out = d;
        };
        authorLayers(&layers, &n, tw, cs_out);
        if (n == 0) return none;
        var diag: style.Diagnostics = .{};
        const pcs = try f.a.create(CS);
        pcs.* = style.computeLayers(f.a, &f.ctx, el.cs, layers[0..n], &diag) catch |e| return f.styleFail(e, &diag);
        if (pcs.display == .none) return none;
        // (PDF frames: the counters number the content, a `::before` entering their scope as a box of its
        // own; a `::after` is read again after the element's children, `leaveCounters`)
        const cx: ?*CssCounters = if (comptime config.enable_pdf) f.cssCounters() else null;
        if (comptime config.enable_pdf) if (cx) |c| if (which == .before) try c.enter(pcs.counter_reset, pcs.counter_increment, pcs.counter_set, .none);
        const parts = try @import("generated_content.zig").read(f.a, pcs.content, &f.dom, i, if (comptime config.enable_pdf) (if (cx) |c| c.hook() else null) else null);
        const text = (try dom_mod.contentText(f.a, pcs.content, &f.dom, i, if (comptime config.enable_pdf) (if (cx) |c| c.hook() else null) else null)) orelse if (parts != null) "" else {
            if (comptime config.enable_pdf) if (cx) |c| if (which == .before) c.leave(pcs.counter_reset, pcs.counter_increment, pcs.counter_set, .none);
            return none;
        };
        if (comptime config.enable_pdf) if (cx) |c| if (which == .before) c.leave(pcs.counter_reset, pcs.counter_increment, pcs.counter_set, .none);
        try f.pseudos.append(f.a, .{ .cs = pcs, .text = text, .parts = parts });
        return @intCast(f.pseudos.items.len - 1);
    }

    // ---- render nodes

    /// A child item of a box: a source element, or a generated box (index into `pseudos`).
    const Item = union(enum) { el: u32, ps: u32 };

    /// An inline-level box met while collecting the runs of a paragraph (object id = its index).
    const PendingObj = struct { item: Item, lang: []const u8, boxed: bool };

    /// Iterates `::before`, own text (text elements with generated content), children, `::after`.
    /// A `display: contents` child generates no box: its own items take its place (css-display-3 §2.5),
    /// to any depth; `own` is the element whose items are being listed (stackless: the DOM links lead
    /// back up).
    const Items = struct {
        f: *const Frame,
        el: u32,
        stage: u8 = 0,
        cur: u32 = none,
        own: u32 = none,

        fn next(it: *Items) ?Item {
            if (it.own == none) it.own = it.el;
            while (true) {
                const e = it.f.dom.at(it.own);
                switch (it.stage) {
                    0 => {
                        it.stage = 1;
                        if (e.before != none) {
                            // (PDF: a list marker goes before the `::before` box, chained, see markers.zig)
                            if (comptime config.enable_pdf) if (@import("pdf/markers.zig").chainedBefore(it.f, e.before) != none) {
                                it.cur = e.before;
                                it.stage = 5;
                            };
                            return .{ .ps = e.before };
                        }
                    },
                    1 => {
                        it.stage = 2;
                        it.cur = e.first;
                        if (e.own != none) return .{ .ps = e.own };
                    },
                    2 => {
                        if (it.cur != none) {
                            const c = it.cur;
                            const ce = it.f.dom.at(c);
                            // (a frame laying out a part of the document: the other children of the
                            // element the parts divide are not in it)
                            if (comptime config.enable_pdf and layout.fragment.enabled) if (it.f.tree.paged.chunk) |ch| if (it.own == ch.parent and (c < ch.lo or c >= ch.hi)) {
                                it.cur = ce.next;
                                continue;
                            };
                            if (ce.kind == .container and !ce.run and ce.cs.display == .contents) {
                                it.own = c;
                                it.stage = 0;
                                continue;
                            }
                            it.cur = ce.next;
                            return .{ .el = c };
                        }
                        it.stage = 3;
                    },
                    3 => {
                        it.stage = 4;
                        if (e.after != none) return .{ .ps = e.after };
                    },
                    else => {
                        if (comptime config.enable_pdf) if (it.stage == 5) {
                            const mk = @import("pdf/markers.zig");
                            const nx = mk.chainedBefore(it.f, it.cur);
                            it.cur = nx;
                            if (mk.chainedBefore(it.f, nx) == none) it.stage = 1;
                            return .{ .ps = nx };
                        };
                        if (it.own == it.el or e.parent == none) return null;
                        // back in the parent of the `display: contents` element, after it
                        it.cur = e.next;
                        it.own = e.parent;
                        it.stage = 2;
                    },
                }
            }
        }
    };

    fn hasGenerated(el: *const dom_mod.El) bool {
        return el.before != none or el.after != none;
    }

    /// True when the item joins its parent's paragraph as text / an inline box: inline, in flow, and
    /// (for boxes) holding only inline-level content. With `objects` (the paragraph is in a block
    /// container) that content may include inline-level boxes (`objectKind`).
    fn isInlineLevel(f: *const Frame, item: Item, depth: u32, objects: bool) bool {
        switch (item) {
            .ps => |p| return inFlowInline(f.pseudos.items[p].cs),
            .el => |i| {
                const el = f.dom.at(i);
                if (depth > 64 or !inFlowInline(el.cs)) return false;
                if (el.run) return true;
                // In a block container an inline box joins the paragraph whatever it holds: a block-level
                // child splits the paragraph around it (block-in-inline, see `splitForBlock`).
                if (objects and el.kind != .image) return true;
                switch (el.kind) {
                    .image => return false,
                    .text => if (!hasGenerated(el)) return true,
                    .container => {},
                }
                // (an empty inline box is inline content too: it adds no run, like takumi's empty spans)
                var it: Items = .{ .f = f, .el = i };
                while (it.next()) |c| {
                    if (f.isInlineLevel(c, depth + 1, objects)) continue;
                    if (objects and f.objectKind(c) != null) continue;
                    if (f.itemStyle(c).display == .none) continue;
                    return false;
                }
                return true;
            },
        }
    }

    /// An inline element that is an inline box (own fragments: background, border, edges): a tagged
    /// element or a container; a bare text node (and a `text` node without a tag, as in takumi) is not.
    fn isBoxed(el: *const dom_mod.El) bool {
        return !el.run and (el.tag.len > 0 or el.kind == .container);
    }

    fn hasInlineEdges(cs: *const CS) bool {
        const bw = cs.usedBorderWidths();
        for ([2]usize{ 1, 3 }) |k| {
            if (bw[k] > 0 or cs.padding[k].resolve(0) != 0 or cs.padding[k].pct != 0) return true;
            switch (cs.margin[k]) {
                .lp => |lp| if (lp.resolve(0) != 0 or lp.pct != 0) return true,
                else => {},
            }
        }
        return false;
    }

    fn itemStyle(f: *const Frame, item: Item) *const CS {
        return switch (item) {
            .ps => |p| f.pseudos.items[p].cs,
            .el => |i| f.dom.at(i).cs,
        };
    }

    /// The kind of inline-level BOX an item is inside a paragraph (null = not one): an out-of-flow
    /// box (static position at its place in the text), a float, or an atomic inline.
    fn objectKind(f: *const Frame, item: Item) ?font.Object.Kind {
        const cs = f.itemStyle(item);
        if (cs.display == .none) return null;
        if (cs.position == .absolute or cs.position == .fixed) return .out_of_flow;
        if (cs.float != .none) return if (config.enable_floats) .float else null;
        return if (f.isAtomic(item)) .atomic else null;
    }

    /// Does the item put anything on a line (text that survives white-space collapsing, an atomic
    /// inline)? A run of children without any generates no paragraph.
    fn hasLineContent(f: *const Frame, item: Item, depth: u32) bool {
        if (f.objectKind(item)) |k| return k == .atomic;
        switch (item) {
            .ps => |p| {
                const ps = f.pseudos.items[p];
                if (ps.generated_el) |el| return f.hasLineContent(.{ .el = el }, depth + 1);
                if (ps.cs.white_space_collapse != .collapse) return ps.text.len > 0;
                for (ps.text) |c| if (!isSpace(c)) return true;
                return hasInlineEdges(ps.cs);
            },
            .el => |i| {
                const el = f.dom.at(i);
                if (el.cs.display == .none or depth > 64) return false;
                // (an inline box with inline edges makes a line even when it is empty)
                if (isBoxed(el) and hasInlineEdges(el.cs)) return true;
                if (el.kind == .text and !hasGenerated(el)) {
                    if (el.tag.len == 2 and std.ascii.eqlIgnoreCase(el.tag, "br")) return true;
                    if (el.cs.white_space_collapse != .collapse) return el.text.len > 0;
                    for (el.text) |c| if (!isSpace(c)) return true;
                    return false;
                }
                var it: Items = .{ .f = f, .el = i };
                while (it.next()) |c| {
                    if (f.hasLineContent(c, depth + 1)) return true;
                }
                return false;
            },
        }
    }

    /// takumi `participates_in_inflow_inline_formatting_context` after an in-flow child; floats and
    /// out-of-flow boxes keep `prev`.
    fn afterInline(f: *const Frame, item: Item, prev: bool) bool {
        const cs = f.itemStyle(item);
        if (cs.display == .none or cs.position == .absolute or cs.position == .fixed or cs.float != .none) return prev;
        return switch (cs.display) {
            .@"inline", .inline_block, .inline_flex, .inline_grid, .inline_table, .webkit_inline_box => true,
            else => false,
        };
    }

    fn inFlowInline(cs: *const CS) bool {
        // (a float is blockified)
        return cs.display == .@"inline" and cs.position != .absolute and cs.position != .fixed and cs.float == .none;
    }

    /// Atomic inline-level box (inline-block / -flex / -grid / -table, or an image with an inline
    /// display, takumi's default for images): in a block container it becomes an item of an
    /// anonymous line container (`Kind.anon_box`) instead of being blockified.
    fn isAtomic(f: *const Frame, item: Item) bool {
        var image = false;
        const cs = switch (item) {
            .ps => |p| f.pseudos.items[p].cs,
            .el => |i| blk: {
                const el = f.dom.at(i);
                image = el.kind == .image;
                break :blk el.cs;
            },
        };
        if (cs.position == .absolute or cs.position == .fixed or cs.float != .none) return false;
        return switch (cs.display) {
            .inline_block, .inline_flex, .inline_grid, .inline_table, .webkit_inline_box => true,
            .@"inline" => image,
            else => false,
        };
    }

    /// Block containers lay inline-level children out on lines; flex / grid containers blockify
    /// them and table boxes other than cells / captions wrap them in anonymous cells (layout engine).
    fn hasLines(d: style.computed.Display) bool {
        return switch (d) {
            .flex, .inline_flex, .grid, .inline_grid, .none => false,
            .table, .inline_table, .table_row, .table_row_group, .table_header_group, .table_footer_group, .table_column, .table_column_group => !config.enable_tables,
            else => true,
        };
    }

    /// Text elements with a flex / grid / table display become a box holding their text as an
    /// anonymous leaf: takumi lays the text out as an anonymous flex / grid item (aligned by the
    /// container, reported by measure() as a child box); a measured leaf could not be aligned inside a
    /// cell by `vertical-align` either.
    fn needsTextBox(d: style.computed.Display) bool {
        return switch (d) {
            .flex, .inline_flex, .grid, .inline_grid => true,
            .table, .inline_table, .table_row, .table_row_group, .table_header_group, .table_footer_group, .table_cell, .table_caption => config.enable_tables,
            else => false,
        };
    }

    /// Collapsible white-space-only text (takumi `is_collapsible_whitespace_only_text_node`): a bare
    /// run, or with `elements` also a text element (class / style / tw ...), never `<br>`.
    fn isBlankText(f: *const Frame, item: Item, elements: bool) bool {
        const i = switch (item) {
            .el => |i| i,
            .ps => return false,
        };
        const el = f.dom.at(i);
        if (el.kind != .text or el.own != none or el.cs.white_space_collapse != .collapse) return false;
        if (!el.run and (!elements or std.ascii.eqlIgnoreCase(el.tag, "br"))) return false;
        for (el.text) |c| if (c != ' ' and c != '\n' and c != '\t' and c != '\r' and c != 0x0c) return false;
        return true;
    }

    noinline fn buildPseudo(f: *Frame, p: u32, parent: u32) Error!u32 {
        const ps = f.pseudos.items[p];
        const id = if (ps.generated_el) |el| try f.buildElement(el, parent, 0) else blk: {
            const node = try f.addNode(.{ .kind = .text, .cs = ps.cs, .parent = parent });
            f.nodes.items[node].para = try f.soloParagraph(ps.text, ps.cs);
            break :blk node;
        };
        if (comptime config.enable_pdf) try @import("pdf/markers.zig").onBuilt(f, p, id);
        return id;
    }

    /// Paragraph of a text box of its own: one run, no inline boxes.
    noinline fn soloParagraph(f: *Frame, text: []const u8, cs: *const CS) Error!*font.Paragraph {
        const saved_base = f.box_base;
        const saved_box = f.cur_box;
        defer {
            f.box_base = saved_base;
            f.cur_box = saved_box;
        }
        f.box_base = @intCast(f.inline_boxes.items.len);
        f.cur_box = none;
        var runs: [1]font.Run = .{try f.makeRun(text, cs)};
        return f.makeParagraph(&runs, cs);
    }

    fn buildItem(f: *Frame, item: Item, parent: u32, depth: u32) Error!void {
        switch (item) {
            .el => |c| _ = try f.buildElement(c, parent, depth),
            .ps => |p| _ = try f.buildPseudo(p, parent),
        }
    }

    fn buildElement(f: *Frame, i: u32, parent: u32, depth: u32) Error!u32 {
        if (depth >= max_node_depth) return f.fail("node tree is nested too deeply", "");
        const el = f.dom.at(i);
        const saved_lang = f.cur_lang;
        defer f.cur_lang = saved_lang;
        if (el.lang.len > 0) f.cur_lang = el.lang;
        const cs = el.cs;
        switch (el.kind) {
            .text => if (!hasGenerated(el)) return if (needsTextBox(cs.display)) f.buildTextBox(i, parent) else f.buildText(i, parent),
            .image => return f.buildImage(i, parent),
            else => {},
        }
        const id = try f.addNode(.{ .kind = .container, .cs = cs, .el = i, .parent = parent });
        const inline_ctx = switch (cs.display) {
            .flex, .inline_flex, .grid, .inline_grid => false,
            else => true,
        };
        const lines = hasLines(cs.display);
        // The children are split into runs of consecutive ones that take part in one inline formatting
        // context: inline-level content and, in a block container, the inline-level boxes, floats and
        // out-of-flow boxes among it (Blink's MakeChildrenNonInline). A run with line content becomes a
        // paragraph; in a run without any, floats and out-of-flow boxes stay children of the block.
        var it: Items = .{ .f = f, .el = i };
        var run_start = it;
        var run_len: u32 = 0;
        var run_content = false;
        // takumi `drop_collapsible_boundary_whitespace`: white-space-only text (bare or a text element)
        // not preceded by in-flow inline content generates nothing.
        var after_inline = cs.display == .@"inline";
        // (an inline box with children may hold a block-level one)
        var run_boxes = false;
        while (true) {
            const before = it;
            const c = it.next();
            var drop = false;
            if (c) |x| {
                drop = !after_inline and f.isBlankText(x, true);
                if (!drop) after_inline = f.afterInline(x, after_inline);
            }
            if (drop and run_len == 0) continue;
            var joins = false;
            if (c) |x| {
                if (inline_ctx) {
                    joins = f.isInlineLevel(x, 0, lines) or (lines and f.objectKind(x) != null);
                    // (PDF frames: a `display: none` child generates no box and does not split the
                    // inline formatting context around it, as takumi; a raster frame keeps its
                    // former paragraphs)
                    if (comptime config.enable_pdf) {
                        if (!joins and f.tree.paged.pdf and f.itemStyle(x).display == .none) joins = true;
                    }
                    if (joins and !run_content) run_content = f.hasLineContent(x, 0);
                    if (joins and lines and x == .el) {
                        const xe = f.dom.at(x.el);
                        if ((xe.kind == .container and !xe.run and xe.first != none) or hasGenerated(xe)) run_boxes = true;
                    }
                }
            }
            if (joins) {
                if (run_len == 0) run_start = before;
                run_len += 1;
                continue;
            }
            if (run_len > 0) {
                try f.buildInlineRun(run_start, run_len, run_content, run_boxes, cs, id, depth);
                run_len = 0;
                run_content = false;
                run_boxes = false;
            }
            const x = c orelse break;
            // white-space-only text between boxes generates nothing
            if (drop or f.isBlankText(x, !inline_ctx)) continue;
            try f.buildItem(x, id, depth + 1);
        }
        return id;
    }

    /// Builds the `count` children starting at `start_it` that form one inline formatting context
    /// of block `parent` (style `cs`).
    /// `boxes`: some child is an inline box with children (it may hold block-level ones).
    noinline fn buildInlineRun(f: *Frame, start_it: Items, count: u32, content: bool, boxes: bool, cs: *const CS, parent: u32, depth: u32) Error!void {
        var it = start_it;
        var k: u32 = 0;
        if (!content and !boxes) {
            // Empty inline elements beside block siblings still form an anonymous inline
            // formatting context. It has no line box, but owns a marked-content region.
            var target = parent;
            if (comptime config.enable_pdf) if (f.tree.paged.pdf and hasLines(cs.display)) {
                var scan = start_it;
                var inline_element = false;
                for (0..count) |_| {
                    const c = scan.next() orelse break;
                    const s = f.itemStyle(c);
                    if (c == .el and !f.dom.at(c.el).run and s.display == .@"inline" and s.position != .absolute and s.position != .fixed and s.float == .none) inline_element = true;
                }
                const el = f.nodes.items[parent].el;
                if (inline_element and el != none) {
                    var siblings: Items = .{ .f = f, .el = el };
                    while (siblings.next()) |c| {
                        const s = f.itemStyle(c);
                        if (s.display != .none and s.position != .absolute and s.position != .fixed and s.float == .none and !f.isInlineLevel(c, 0, true)) {
                            target = try f.openAnonBox(cs, parent);
                            break;
                        }
                    }
                }
            };
            // no line box: only the boxes are built
            while (k < count) : (k += 1) {
                const c = it.next() orelse break;
                if (f.objectKind(c) != null) try f.buildItem(c, target, depth + 1);
            }
            return;
        }
        var pending: std.ArrayList(font.Run) = .empty;
        const saved_base = f.box_base;
        const saved_box = f.cur_box;
        const saved_objs = f.pend_objs;
        const saved_ifc = f.ifc;
        defer {
            f.box_base = saved_base;
            f.cur_box = saved_box;
            f.pend_objs = saved_objs;
            f.ifc = saved_ifc;
        }
        f.box_base = @intCast(f.inline_boxes.items.len);
        f.cur_box = none;
        f.pend_objs = .empty;
        f.ifc = .{ .parent = parent, .cs = cs, .depth = depth };
        while (k < count) : (k += 1) {
            const c = it.next() orelse break;
            try f.collectRuns(c, &pending, depth + 1, cs);
        }
        try f.finishPart(&pending, content);
    }

    /// The inline formatting context being collected (`buildInlineRun`): the block container node, its
    /// style, its depth; `split`: a block-level box inside an inline box has split it into parts.
    const Ifc = struct { parent: u32 = none, cs: *const CS = undefined, depth: u32 = 0, split: bool = false };

    /// Ends the part of the inline formatting context collected in `pending` (all of it, or the part
    /// before / between / after block-level boxes): a paragraph when it has line content, else only its
    /// floats and out-of-flow boxes. `content`: the whole run is known to have line content.
    noinline fn finishPart(f: *Frame, pending: *std.ArrayList(font.Run), content: bool) Error!void {
        const cs = f.ifc.cs;
        const parent = f.ifc.parent;
        const depth = f.ifc.depth;
        const objs = f.pend_objs.items;
        const lang = f.cur_lang;
        const box = f.cur_box;
        defer {
            f.cur_lang = lang;
            f.cur_box = box;
            pending.* = .empty;
        }
        if (!(if (f.ifc.split or !content) f.partHasContent(pending.items) else true)) {
            // no line box: only the boxes are built
            for (objs) |o| {
                f.cur_lang = o.lang;
                try f.buildItem(o.item, parent, depth + 1);
            }
            return;
        }
        // (an anonymous block that is not the first child has no first formatted line)
        f.no_indent = f.nodes.items[parent].first_child != none;
        if (objs.len == 0) {
            const before = f.nodes.items.len;
            try f.flushRuns(pending, cs, parent);
            if (before < f.nodes.items.len) f.nodes.items[before].ifc_part = f.ifc.split;
            return;
        }
        // inline-level boxes: an anonymous inline formatting context holding them as children
        const id = try f.openAnonBox(cs, parent);
        f.nodes.items[id].ifc_part = f.ifc.split;
        // (the paragraph's own properties are the block's: alignment, wrapping, clamping)
        f.nodes.items[id].para = try f.makeParagraph(pending.items, cs);
        f.cur_box = none;
        for (objs) |o| {
            f.cur_lang = o.lang;
            const first: u32 = @intCast(f.nodes.items.len);
            try f.buildItem(o.item, id, depth + 1);
            if (first < f.nodes.items.len) f.nodes.items[first].in_inline_box = o.boxed;
        }
    }

    /// Does a part of an inline formatting context put anything on a line: text that survives
    /// white-space collapsing, a forced break, an atomic inline, an inline box edge?
    fn partHasContent(f: *const Frame, runs: []const font.Run) bool {
        for (runs) |r| {
            if (r.object) |o| {
                if (o.kind == .atomic) return true;
                continue;
            }
            if (r.hard_break_after) return true;
            const ws = r.white_space orelse .normal;
            if (ws != .normal and ws != .nowrap) {
                if (r.text.len > 0) return true;
                continue;
            }
            for (r.text) |c| if (!isSpace(c)) return true;
        }
        for (f.inline_boxes.items[@min(f.box_base, f.inline_boxes.items.len)..]) |ib| {
            const clone = ib.cs.box_decoration_break == .clone;
            const rtl = ib.cs.direction == .rtl;
            // (side 3 = left, 1 = right)
            if ((clone or !ib.no_start) and sideEdge(ib.cs, if (rtl) 1 else 3)) return true;
            if ((clone or !ib.no_end) and sideEdge(ib.cs, if (rtl) 3 else 1)) return true;
        }
        return false;
    }

    fn sideEdge(cs: *const CS, k: usize) bool {
        if (cs.usedBorderWidths()[k] > 0 or cs.padding[k].resolve(0) != 0 or cs.padding[k].pct != 0) return true;
        return switch (cs.margin[k]) {
            .lp => |lp| lp.resolve(0) != 0 or lp.pct != 0,
            else => false,
        };
    }

    const max_split_boxes = 8192;

    /// Block-in-inline (CSS 2.1 §9.2.1.1): `item` is a block-level box inside the inline boxes that are
    /// open (`cur_box` and its ancestors). The paragraph collected so far ends with those boxes open
    /// (no end edge), the block becomes a child of the block container, and a new paragraph continues
    /// the boxes (no start edge) for what follows.
    noinline fn splitForBlock(f: *Frame, out: *std.ArrayList(font.Run), item: Item) Error!void {
        const boxes = &f.inline_boxes;
        var n_open: u32 = 0;
        var b = f.cur_box;
        while (b != none and b >= f.box_base and b < boxes.items.len and n_open < max_node_depth) : (b = boxes.items[b].parent) {
            boxes.items[b].no_end = true;
            n_open += 1;
        }
        const top = f.cur_box;
        // (the innermost open box shows up in this part even when nothing is in it yet)
        if (n_open > 0) try f.appendRun(out, "", boxes.items[top].cs, false);
        f.ifc.split = true;
        try f.finishPart(out, false);
        const first_node: u32 = @intCast(f.nodes.items.len);
        try f.buildItem(item, f.ifc.parent, f.ifc.depth + 1);
        if (first_node < f.nodes.items.len) f.nodes.items[first_node].bii = true;
        // the continuation: the same chain of boxes, outer first (bounded work on hostile input: once
        // the splits of a render have re-opened this many boxes, what follows continues unboxed)
        const new_base: u32 = @intCast(boxes.items.len);
        if (f.split_boxes + n_open > max_split_boxes) n_open = 0;
        f.split_boxes += n_open;
        var k: u32 = n_open;
        var prev: u32 = none;
        while (k > 0) {
            k -= 1;
            var src = top;
            for (0..k) |_| src = boxes.items[src].parent;
            try boxes.append(f.a, .{ .cs = boxes.items[src].cs, .parent = prev, .no_start = true });
            prev = @intCast(boxes.items.len - 1);
        }
        f.box_base = new_base;
        f.cur_box = prev;
        f.pend_objs = .empty;
        if (prev != none) try f.appendRun(out, "", boxes.items[prev].cs, false);
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\n' or c == '\t' or c == '\r' or c == 0x0c;
    }

    /// Text element with a table display: a box (the cell) holding its text as an anonymous leaf.
    noinline fn buildTextBox(f: *Frame, i: u32, parent: u32) Error!u32 {
        const el = f.dom.at(i);
        const id = try f.addNode(.{ .kind = .container, .cs = el.cs, .el = i, .parent = parent });
        const t = try f.addNode(.{ .kind = .anon_text, .cs = el.cs, .parent = id });
        f.nodes.items[t].para = try f.soloParagraph(el.text, el.cs);
        return id;
    }
    /// Text element without generated content: one paragraph. (Out of line: keeps the run and the
    /// paragraph options out of buildElement's recursive stack frame.)
    noinline fn buildText(f: *Frame, i: u32, parent: u32) Error!u32 {
        const el = f.dom.at(i);
        const id = try f.addNode(.{ .kind = .text, .cs = el.cs, .el = i, .parent = parent });
        f.nodes.items[id].para = try f.soloParagraph(el.text, el.cs);
        return id;
    }

    /// Image element: raster pixmap (decoded, cached) or SVG markup with its intrinsic size.
    noinline fn buildImage(f: *Frame, i: u32, parent: u32) Error!u32 {
        const el = f.dom.at(i);
        var cs = el.cs;
        {
            var img: ?*const raster.Pixmap = null;
            var svg_src: ?[]const u8 = null;
            if (el.src) |src| {
                img = f.r.resolveImage(src);
                if (comptime config.enable_svg) if (img == null) {
                    svg_src = f.r.resolveSvg(src);
                };
            }
            // `width` / `height` attributes act as a low-priority size preset.
            const wa = el.width;
            const ha = el.height;
            if ((wa != null and cs.width == .auto) or (ha != null and cs.height == .auto)) {
                const m = try f.a.create(CS);
                m.* = cs.*;
                if (wa != null and m.width == .auto) m.width = .{ .lp = .{ .px = wa.? * f.opts.dpr } };
                if (ha != null and m.height == .auto) m.height = .{ .lp = .{ .px = ha.? * f.opts.dpr } };
                cs = m;
            }
            var n: Node = .{ .kind = .image, .cs = cs, .el = i, .parent = parent, .img = img, .src = el.src };
            if (img) |pm| {
                n.img_w = @as(f32, @floatFromInt(pm.width)) * f.opts.dpr;
                n.img_h = @as(f32, @floatFromInt(pm.height)) * f.opts.dpr;
                n.img_ratio = n.img_w / n.img_h;
            } else if (comptime config.enable_svg) if (svg_src) |s| {
                if (svgm.parse(f.a, s)) |doc| {
                    n.svg = s;
                    const sz = svgIntrinsic(&doc, f.opts.dpr);
                    n.img_w = sz.w;
                    n.img_h = sz.h;
                    n.img_ratio = sz.ratio;
                } else |e| if (e == error.OutOfMemory) return error.OutOfMemory;
            };
            // (PDF: a bitmap bm-render does not decode, a CMYK JPEG or a damaged PNG, keeps the size
            // its header gives, as takumi-core's `EncodedBitmap`; src/pdf/emit_image.zig embeds or
            // rejects its bytes)
            if (comptime config.enable_pdf) if (f.tree.paged.pdf and img == null and n.svg == null) if (el.src) |src| {
                const eimg = @import("pdf/emit_image.zig");
                if (eimg.sourceBytes(f.r, f.a, src)) |bytes| if (eimg.headerSize(bytes)) |hs| {
                    n.img_w = @as(f32, @floatFromInt(hs[0])) * f.opts.dpr;
                    n.img_h = @as(f32, @floatFromInt(hs[1])) * f.opts.dpr;
                    n.img_ratio = n.img_w / n.img_h;
                };
            };
            return f.addNode(n);
        }
    }

    /// Anonymous inline formatting context node of block `parent` (style `cs`). Out of line: the
    /// computed style temporary must not sit in the recursive frame of `buildInlineRun`.
    noinline fn openAnonBox(f: *Frame, cs: *const CS, parent: u32) Error!u32 {
        const slot = try f.anon_styles.getOrPut(f.a, @intFromPtr(cs));
        if (!slot.found_existing) {
            var diag: style.Diagnostics = .{};
            const rcs = try f.a.create(CS);
            rcs.* = style.compute(f.a, &f.ctx, cs, null, null, &diag) catch |e| {
                _ = f.anon_styles.remove(@intFromPtr(cs));
                return f.styleFail(e, &diag);
            };
            slot.value_ptr.* = rcs;
        }
        return f.addNode(.{ .kind = .anon_box, .cs = slot.value_ptr.*, .parent = parent, .box_base = f.box_base });
    }

    /// The collected runs (a run of children with line content, see `hasLineContent`) as a paragraph leaf.
    noinline fn flushRuns(f: *Frame, pending: *std.ArrayList(font.Run), cs: *const CS, parent: u32) Error!void {
        if (pending.items.len == 0) return;
        defer pending.* = .empty;
        const id = try f.addNode(.{ .kind = .anon_text, .cs = cs, .parent = parent, .box_base = f.box_base });
        f.nodes.items[id].para = try f.makeParagraph(pending.items, cs);
    }

    /// `pcs`: style of the enclosing inline box (or of the block), for the items that are boxes.
    fn collectRuns(f: *Frame, item: Item, out: *std.ArrayList(font.Run), depth: u32, pcs: *const CS) Error!void {
        if (depth >= max_node_depth) return f.fail("node tree is nested too deeply", "");
        if (f.objectKind(item)) |kind| return f.appendObject(out, item, kind, pcs);
        switch (item) {
            .ps => |p| {
                const ps = f.pseudos.items[p];
                if (ps.generated_el) |el| return f.collectRuns(.{ .el = el }, out, depth + 1, pcs);
                if (ps.cs.display == .none) return;
                if (!inFlowInline(ps.cs)) return f.splitForBlock(out, item);
                try f.openInlineBox(ps.cs);
                // (a block-in-inline split re-opens the boxes: leave through the parent link)
                defer f.closeInlineBox();
                try f.appendRun(out, ps.text, ps.cs, false);
            },
            .el => |i| {
                const el = f.dom.at(i);
                if (el.cs.display == .none) return;
                if (!el.run and !inFlowInline(el.cs)) return f.splitForBlock(out, item);
                // a real (tagged) element is an inline box; bare text nodes are not
                const br = el.tag.len == 2 and std.ascii.eqlIgnoreCase(el.tag, "br");
                const boxed = isBoxed(el) and !br;
                if (boxed) try f.openInlineBox(el.cs);
                defer if (boxed) f.closeInlineBox();
                if (el.kind == .text and !hasGenerated(el)) return f.appendRun(out, el.text, el.cs, br);
                const before = out.items.len;
                var it: Items = .{ .f = f, .el = i };
                while (it.next()) |c| try f.collectRuns(c, out, depth + 1, el.cs);
                // (an empty inline box still has its edges)
                if (boxed and out.items.len == before) try f.appendRun(out, "", el.cs, false);
            },
        }
    }

    /// An inline-level box inside the paragraph being collected: an object run now, its node later.
    noinline fn appendObject(f: *Frame, out: *std.ArrayList(font.Run), item: Item, kind: font.Object.Kind, pcs: *const CS) Error!void {
        const cs = f.itemStyle(item);
        const id: u32 = @intCast(f.pend_objs.items.len);
        // (inside an inline box that generates box fragments: border, background, padding, margin)
        var boxed = false;
        var bx = f.cur_box;
        while (bx != none and bx >= f.box_base and bx < f.inline_boxes.items.len) : (bx = f.inline_boxes.items[bx].parent) {
            const bcs = f.inline_boxes.items[bx].cs;
            if (hasInlineEdges(bcs) or bcs.resolveColor(bcs.background_color).a != 0 or bcs.background_image.len > 0) boxed = true;
        }
        try f.pend_objs.append(f.a, .{ .item = item, .lang = f.cur_lang, .boxed = boxed });
        const inline_level = switch (cs.display) {
            .@"inline", .inline_block, .inline_flex, .inline_grid, .inline_table, .webkit_inline_box => true,
            else => false,
        };
        try out.append(f.a, .{
            .text = "",
            .white_space = whiteSpaceOf(pcs),
            .box = if (f.cur_box != none and f.cur_box >= f.box_base) f.cur_box - f.box_base else font.no_box,
            .object = .{ .id = id, .kind = kind, .valign = f.valignOf(cs), .block_level = !inline_level },
        });
    }

    /// `vertical-align` for the text engine (a percentage refers to the element's own line-height).
    fn valignOf(f: *const Frame, cs: *const CS) font.VerticalAlign {
        return switch (cs.vertical_align) {
            .baseline => .baseline,
            .sub => .sub,
            .super => .super,
            .top => .top,
            .middle => .middle,
            .bottom => .bottom,
            .text_top => .text_top,
            .text_bottom => .text_bottom,
            .lp => |lp| blk: {
                var v = lp.px;
                if (lp.pct != 0 or lp.calc != null) {
                    const st = strutFrom(emMetrics(&f.r.fonts, cs), cs.font_size, cs.line_height);
                    v = lp.resolve(st[0] + st[1]);
                }
                break :blk if (v == 0 or !std.math.isFinite(v)) .baseline else .{ .length = v };
            },
        };
    }

    /// Leaves the current inline box.
    fn closeInlineBox(f: *Frame) void {
        if (f.cur_box != none and f.cur_box < f.inline_boxes.items.len) f.cur_box = f.inline_boxes.items[f.cur_box].parent;
    }

    /// Pushes an inline box nested in the current one and makes it current.
    noinline fn openInlineBox(f: *Frame, cs: *const CS) Error!void {
        try f.inline_boxes.append(f.a, .{ .cs = cs, .parent = f.cur_box });
        f.cur_box = @intCast(f.inline_boxes.items.len - 1);
    }

    /// Appends the run of a text element (HTML `<br>`: an empty run ending in a forced break, in
    /// every white-space mode). Out of line so collectRuns' recursive frame stays small.
    noinline fn appendRun(f: *Frame, out: *std.ArrayList(font.Run), text: []const u8, cs: *const CS, br: bool) Error!void {
        if (br) {
            var r = try f.makeRun("", cs);
            r.hard_break_after = true;
            return out.append(f.a, r);
        }
        try out.append(f.a, try f.makeRun(text, cs));
    }

    fn whiteSpaceOf(cs: *const CS) font.WhiteSpace {
        return switch (cs.white_space_collapse) {
            .collapse => if (cs.text_wrap_mode == .nowrap) .nowrap else .normal,
            .preserve, .preserve_spaces => if (cs.text_wrap_mode == .nowrap) .pre else .pre_wrap,
            .preserve_breaks => .pre_line,
            .break_spaces => .pre_wrap,
        };
    }

    /// The inline boxes `f.inline_boxes[f.box_base..]` for the text engine: font / line-height strut,
    /// `vertical-align` and inline edges (margin + border + padding; percentages count as 0, like
    /// takumi), on the 1/64 px grid.
    noinline fn paragraphBoxes(f: *Frame) Error![]const font.InlineBox {
        const src = f.inline_boxes.items[@min(f.box_base, f.inline_boxes.items.len)..];
        if (src.len == 0) return &.{};
        const out = try f.a.alloc(font.InlineBox, src.len);
        for (src, out) |ib, *o| {
            const cs = ib.cs;
            const bw = cs.usedBorderWidths();
            var edge: [2]f32 = undefined;
            var mar: [2]f32 = undefined;
            const rtl = cs.direction == .rtl;
            const clone = cs.box_decoration_break == .clone;
            // block-in-inline: the part of a split box has no edge where the box continues
            const drop: [2]bool = .{ ib.no_start and !clone, ib.no_end and !clone };
            // percentage margins / padding resolve against the containing block width at layout time
            // (Chrome; takumi takes them as 0)
            var parts: font.EdgeParts = .{};
            var has_pct = false;
            // (sides 3 = left, 1 = right)
            for ([2]usize{ 3, 1 }, 0..) |side, k| {
                const mlp: style.LP = switch (cs.margin[side]) {
                    .lp => |lp| lp,
                    else => .{},
                };
                const plp = cs.padding[side];
                const m = mlp.resolve(0);
                mar[k] = @trunc(m * 64) / 64;
                edge[k] = mar[k] + @trunc(bw[side] * 64) / 64 + @trunc(@max(plp.resolve(0), 0) * 64) / 64;
                // [inline start, inline end]
                const e: usize = @intFromBool((k == 1) != rtl);
                if (drop[e]) {
                    mar[k] = 0;
                    edge[k] = 0;
                    continue;
                }
                parts.margin[e] = m;
                parts.margin_pct[e] = mlp.resolve(1) - m;
                parts.padding[e] = plp.resolve(0);
                parts.padding_pct[e] = plp.resolve(1) - parts.padding[e];
                parts.border[e] = bw[side];
                if (parts.margin_pct[e] != 0 or parts.padding_pct[e] != 0) has_pct = true;
            }
            o.* = .{
                .parent = if (ib.parent == none or ib.parent < f.box_base) font.no_box else ib.parent - f.box_base,
                .style = textStyle(cs, 0),
                .line_height = switch (cs.line_height) {
                    .normal => .normal,
                    .number => |n| .{ .multiple = n },
                    .px => |p| .{ .px = p },
                },
                .valign = f.valignOf(cs),
                .start = edge[@intFromBool(rtl)],
                .end = edge[@intFromBool(!rtl)],
                .margin_start = mar[@intFromBool(rtl)],
                .rtl = rtl,
                .rel = relOffset(cs, f.ifc_rtl),
                .no_start = drop[0],
                .no_end = drop[1],
                .pct = if (has_pct) parts else null,
                .margin_end = mar[@intFromBool(!rtl)],
                .clone = cs.box_decoration_break == .clone,
                .decorated = cs.resolveColor(cs.background_color).a != 0 or cs.background_image.len > 0 or bw[0] > 0 or bw[1] > 0 or bw[2] > 0 or bw[3] > 0 or
                    // (PDF: an inline outline is drawn from the fragments, emit_text.zig `paintInlineOutlines`)
                    (comptime config.enable_pdf and layout.fragment.enabled) and f.tree.paged.pdf and cs.outline_style != .none and cs.outline_style != .hidden and cs.outline_width > 0,
            };
        }
        return out;
    }

    /// `position: relative` offset of an inline box in px (percentages of the containing block are not
    /// known to the text engine: they count as 0).
    fn relOffset(cs: *const CS, rtl: bool) [2]f32 {
        if (cs.position != .relative and cs.position != .sticky) return .{ 0, 0 };
        var v: [4]?f32 = .{ null, null, null, null };
        for (cs.inset, 0..) |d, k| switch (d) {
            .lp => |lp| v[k] = lp.resolve(0),
            else => {},
        };
        // (top, right, bottom, left; `left` wins over `right` except in a right-to-left containing block)
        const dx: f32 = if (rtl) (if (v[1]) |r| -r else v[3] orelse 0) else (v[3] orelse if (v[1]) |r| -r else 0);
        const dy: f32 = v[0] orelse if (v[2]) |b| -b else 0;
        return .{ dx, dy };
    }

    noinline fn makeRun(f: *Frame, text: []const u8, cs: *const CS) Error!font.Run {
        try f.run_styles.append(f.a, cs);
        try f.run_box.append(f.a, f.cur_box);
        var st = textStyle(cs, @intCast(f.run_styles.items.len - 1));
        // font-variant-* / font-kerning / font-feature-settings as OpenType features
        const feats = try cs.fontFeatures(f.a);
        if (feats.len > 0) {
            const out = try f.a.alloc(font.FeatureSetting, feats.len);
            for (feats, out) |x, *o| o.* = .{ .tag = x.tag, .value = @intCast(@min(x.value, 0xFFFF)) };
            st.features = out;
        }
        return .{
            .text = try transformText(f.a, text, cs.text_transform, cs.white_space_collapse == .preserve or cs.white_space_collapse == .preserve_spaces or cs.white_space_collapse == .break_spaces),
            .style = st,
            .white_space = whiteSpaceOf(cs),
            .overflow_wrap = overflowWrapOf(cs),
            .box = if (f.cur_box != none and f.cur_box >= f.box_base) f.cur_box - f.box_base else font.no_box,
        };
    }

    /// `overflow-wrap` for the text engine (the legacy `word-break: break-word` acts as `anywhere`).
    fn overflowWrapOf(cs: *const CS) font.OverflowWrap {
        if (cs.word_break == .break_word) return .anywhere;
        return switch (cs.overflow_wrap) {
            .normal => .normal,
            .break_word => .break_word,
            .anywhere => .anywhere,
        };
    }

    noinline fn makeParagraph(f: *Frame, runs: []const font.Run, cs: *const CS) Error!*font.Paragraph {
        const ws = whiteSpaceOf(cs);
        const clip = cs.overflow_x != .visible;
        const indent = !f.no_indent;
        f.no_indent = false;
        var opts: font.ParagraphOptions = .{
            .text_align = switch (cs.text_align) {
                .start => .start,
                .end => .end,
                .left => .left,
                .right => .right,
                .center => .center,
                .justify => .justify,
            },
            .text_align_last = switch (cs.text_align_last) {
                .auto, .match_parent => null,
                .start => .start,
                .end => .end,
                .left => .left,
                .right => .right,
                .center => .center,
                .justify => .justify,
            },
            .line_height = switch (cs.line_height) {
                .normal => .normal,
                .number => |n| .{ .multiple = n },
                .px => |p| .{ .px = p },
            },
            .white_space = ws,
            .word_break = switch (cs.word_break) {
                .normal, .break_word => .normal,
                .break_all => .break_all,
                .keep_all => .keep_all,
            },
            .overflow_wrap = overflowWrapOf(cs),
            .max_lines = if (cs.line_clamp > 0) cs.line_clamp else null,
            .ellipsis = cs.text_overflow != .clip and clip,
            .ellipsis_text = if (cs.text_overflow == .string) cs.text_overflow_string else null,
            .clamp_text = if (cs.block_ellipsis == .string) cs.block_ellipsis_string else null,
            .clamp_no_ellipsis = cs.block_ellipsis == .none,
            .strut = textStyle(cs, 0),
            .direction = if (cs.direction == .rtl) .rtl else .ltr,
            .lang = f.cur_lang,
            .text_wrap = switch (cs.text_wrap_style) {
                .balance => .balance,
                .pretty => .pretty,
                .auto, .stable => .wrap,
            },
            .shape_cache = &f.r.shape_cache,
            .boxes = blk: {
                f.ifc_rtl = cs.direction == .rtl;
                break :blk try f.paragraphBoxes();
            },
        };
        if (indent and (cs.text_indent.px != 0 or cs.text_indent.pct != 0 or cs.text_indent.calc != null)) {
            const ti = cs.text_indent;
            opts.indent = ti.resolve(0);
            opts.indent_pct = if (ti.calc == null) ti.pct else ti.resolve(1) - opts.indent;
            opts.indent_each_line = cs.text_indent_flags & 1 != 0;
            opts.indent_hanging = cs.text_indent_flags & 2 != 0;
        }
        if (comptime config.enable_pdf) {
            // PDF: the paragraph keeps the text its glyph clusters index (ToUnicode / ActualText)
            const pt = try f.a.create(ParaWithText);
            // (a frame a PDF is drawn from places its glyphs as takumi does: text.zig `item_origin`)
            var popts = opts;
            popts.item_origin = f.tree.paged.pdf;
            // (a PDF frame, laid out once for a whole document: the paragraph's working memory is
            // the renderer's scratch, rewound after it, not the frame's arena)
            if (f.tree.paged.pdf) popts.scratch = f.r.scratch.allocator();
            defer if (f.tree.paged.pdf) f.r.scratch.reset();
            pt.p = font.Paragraph.initWith(.{ .complex = config.enable_complex_text, .color_emoji = config.enable_color_fonts or config.enable_bitmap_glyphs }, f.a, &f.r.fonts, runs, popts) catch return error.OutOfMemory;
            var total: usize = 0;
            for (runs) |r| total += if (r.object == null) r.text.len else 0;
            const t = try f.a.alloc(u8, total);
            var at: usize = 0;
            for (runs) |r| if (r.object == null) {
                @memcpy(t[at..][0..r.text.len], r.text);
                at += r.text.len;
            };
            pt.text = t;
            return &pt.p;
        }
        const p = try f.a.create(font.Paragraph);
        p.* = font.Paragraph.initWith(.{ .complex = config.enable_complex_text, .color_emoji = config.enable_color_fonts or config.enable_bitmap_glyphs }, f.a, &f.r.fonts, runs, opts) catch return error.OutOfMemory;
        return p;
    }

    /// (PDF feature) A paragraph allocated together with its text (`paragraphText`).
    const ParaWithText = struct { p: font.Paragraph, text: []const u8 };

    /// The text a paragraph's glyph clusters are byte offsets into: the concatenated,
    /// text-transformed texts of its non-object runs, exactly as given to the text engine. Kept
    /// only with the PDF feature ("" otherwise). `para` must be a node's `para`.
    pub fn paragraphText(para: *const font.Paragraph) []const u8 {
        if (comptime !config.enable_pdf) return "";
        const pt: *const ParaWithText = @alignCast(@fieldParentPtr("p", para));
        return pt.text;
    }

    // ---- layout tree

    /// Layout node of render node `id` (style mapped, measured leaves flagged). Kept out of the
    /// recursion: `layout.Style` is large and would otherwise sit in every level's stack frame.
    noinline fn layoutNode(f: *Frame, id: u32) Error!struct { lid: u32, ordered: bool, leaf: bool } {
        const n = f.nodes.items[id];
        var st: layout.Style = switch (n.kind) {
            // (anonymous inline content: shortens beside floats)
            .anon_text => .{ .display = .block, .is_inline_content = true },
            .anon_box => .{ .display = .inline_row, .position = .static, .is_inline_content = true },
            else => mapStyle(f, n.cs),
        };
        const leaf = n.kind == .text or n.kind == .image or n.kind == .anon_text;
        if (leaf and st.display != .none) st.display = .block;
        // (a block of text: its lines shorten beside floats)
        if (n.kind == .text and (n.cs.display == .block or n.cs.display == .@"inline")) st.is_inline_content = true;
        if (n.kind == .image and st.aspect_ratio == null and n.img_ratio > 0) st.aspect_ratio = n.img_ratio;
        if (comptime layout.fragment.enabled) {
            // anonymous boxes take only the line counts of their block (never break-before / after /
            // inside); a replaced element is monolithic (takumi-core `is_monolithic`: `is_replaced`)
            if (n.kind == .anon_text or n.kind == .anon_box) {
                st.breaks.widows = n.cs.widows;
                st.breaks.orphans = n.cs.orphans;
            }
            if (n.kind == .image) st.breaks.monolithic = true;
            if (comptime config.enable_pdf) if (n.el != none and n.kind != .anon_text and n.kind != .anon_box) {
                st.breaks.page = @import("pdf/page_names.zig").idOf(f, n.el);
            };
        }
        if (comptime config.enable_pdf) {
            if (@import("pdf/markers.zig").besideBaseline(f, id)) {
                st.position = .absolute;
                st.list_marker = true;
            }
        }
        if (n.el != none) {
            if (comptime config.enable_tables) tableSpans(&f.dom, n.el, &st);
            if (n.parent != none and (st.grid_column.start == .auto or st.grid_column.end == .auto or st.grid_row.start == .auto or st.grid_row.end == .auto)) {
                const pcs = f.nodes.items[n.parent].cs;
                if (pcs.display == .grid or pcs.display == .inline_grid) gridNames(pcs, n.cs, &st);
            }
        }
        // the root element establishes a block formatting context (its margins never collapse with
        // its children's)
        if (id == f.root) st.flow_root = true;
        const lid = f.tree.addNode(st) catch return error.OutOfMemory;
        f.nodes.items[id].lid = lid;
        while (f.lid_node.items.len <= lid) try f.lid_node.append(f.a, none);
        f.lid_node.items[lid] = id;
        if (leaf) f.tree.setMeasured(lid, true);
        if (n.kind == .image) f.tree.setReplaced(lid, true);
        return .{ .lid = lid, .ordered = st.display == .flex or st.display == .grid, .leaf = leaf };
    }

    /// Children of `id` in `order` order (stable), or null when document order applies.
    noinline fn orderedChildren(f: *Frame, id: u32, ordered: bool) Error!?[]const u32 {
        if (!ordered) return null;
        var needs_order = false;
        var c = f.nodes.items[id].first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            if (f.nodes.items[c].cs.order != 0 and f.nodes.items[c].kind != .anon_text) needs_order = true;
        }
        if (!needs_order) return null;
        var list: std.ArrayList(u32) = .empty;
        c = f.nodes.items[id].first_child;
        while (c != none) : (c = f.nodes.items[c].next) try list.append(f.a, c);
        // stable insertion sort by order
        var i: usize = 1;
        while (i < list.items.len) : (i += 1) {
            const x = list.items[i];
            const ox = f.nodes.items[x].cs.order;
            var j = i;
            while (j > 0 and f.nodes.items[list.items[j - 1]].cs.order > ox) : (j -= 1) list.items[j] = list.items[j - 1];
            list.items[j] = x;
        }
        return list.items;
    }

    fn buildLayout(f: *Frame, id: u32) Error!u32 {
        const ln = try f.layoutNode(id);
        if (ln.leaf) return ln.lid;
        // children, honouring `order` for flex/grid containers
        if (try f.orderedChildren(id, ln.ordered)) |list| {
            for (list) |x| {
                const cl = try f.buildLayout(x);
                f.tree.appendChild(ln.lid, cl) catch return error.OutOfMemory;
            }
        } else {
            var c = f.nodes.items[id].first_child;
            while (c != none) : (c = f.nodes.items[c].next) {
                const cl = try f.buildLayout(c);
                f.tree.appendChild(ln.lid, cl) catch return error.OutOfMemory;
            }
        }
        return ln.lid;
    }

    fn measureCb(ctx: *anyopaque, lid: layout.NodeId, known: [2]?f32, avail: [2]layout.AvailableSpace) [2]f32 {
        const f: *Frame = @ptrCast(@alignCast(ctx));
        if (lid >= f.lid_node.items.len) return .{ 0, 0 };
        const id = f.lid_node.items[lid];
        if (id == none) return .{ 0, 0 };
        const n = &f.nodes.items[id];
        if (n.kind == .image) {
            const iw = n.img_w;
            const ih = n.img_h;
            const r = n.img_ratio;
            if (known[0]) |w| {
                if (known[1]) |h| return .{ w, h };
                return .{ w, if (r > 0) w / r else ih };
            }
            if (known[1]) |h| return .{ if (r > 0) h * r else iw, h };
            if (iw > 0 or ih > 0 or !(r > 0)) return .{ iw, ih };
            // ratio only (SVG with just a viewBox): fill the available width
            return switch (avail[0]) {
                .definite => |w| .{ w, w / r },
                else => .{ 0, 0 },
            };
        }
        const p = n.para orelse return .{ known[0] orelse 0, known[1] orelse 0 };
        // (percentage edges of inline boxes: against the width once it is known, 0 in intrinsic sizing)
        p.setPercentBase(known[0] orelse 0);
        const limit: ?f32 = known[0] orelse switch (avail[0]) {
            .definite => |v| v,
            .min_content => p.minContentWidth(),
            .max_content => null,
        };
        const sz = if (comptime config.enable_pdf) blk: {
            if (known[0] == null and avail[0] != .definite and p.cut != std.math.maxInt(u32)) break :blk p.measureIntrinsic(limit);
            break :blk p.measure(limit);
        } else p.measure(limit);
        // (the min-content width may exceed the widest line it produces: inline edges, see text.zig)
        const w = if (avail[0] == .min_content) @max(sz.width, limit orelse 0) else sz.width;
        return .{ known[0] orelse w, known[1] orelse sz.height };
    }

    /// First / last baseline of a text leaf (NaN for a leaf without line boxes, e.g. an image: the
    /// layout engine then synthesizes one from its box).
    fn baselineCb(ctx: *anyopaque, lid: layout.NodeId, content_size: [2]f32) [2]f32 {
        const f: *Frame = @ptrCast(@alignCast(ctx));
        const nan = std.math.nan(f32);
        if (lid >= f.lid_node.items.len) return .{ nan, nan };
        const id = f.lid_node.items[lid];
        if (id == none) return .{ nan, nan };
        const p = f.nodes.items[id].para orelse return .{ nan, nan };
        p.setPercentBase(content_size[0]);
        const sz = p.measure(content_size[0]);
        if (sz.line_count == 0) return .{ content_size[1], content_size[1] };
        return .{ sz.first_baseline, sz.last_baseline };
    }

    /// Bridge between the layout engine's inline formatting protocol and the text engine's `Flow`.
    const FlowCtx = struct {
        io: *layout.InlineIo,

        fn band(fl: *const font.Flow, y: f32, h: f32) font.Band {
            const c: *FlowCtx = @ptrCast(@alignCast(fl.ctx.?));
            const b = c.io.band_fn.?(c.io, y, h);
            return .{ .x0 = b.x0, .x1 = b.x1, .next_y = b.next_y };
        }
        fn float(fl: *const font.Flow, id: u32, y: f32, used: f32, avail: f32, how: font.FloatPlace) bool {
            const c: *FlowCtx = @ptrCast(@alignCast(fl.ctx.?));
            return c.io.float_fn.?(c.io, id, y, used, avail, @backingInt(how));
        }
    };

    /// `layout.InlineFn`: lines of the paragraph of node `lid` (text, inline boxes and the atomic
    /// items of `io`) in the exclusion space the engine exposes; a layout pass keeps the line layout
    /// for the painters (`Node.tl`).
    fn inlineCb(ctx: *anyopaque, lid: layout.NodeId, io: *layout.InlineIo) void {
        const f: *Frame = @ptrCast(@alignCast(ctx));
        if (lid >= f.lid_node.items.len) return;
        const id = f.lid_node.items[lid];
        if (id == none) return;
        const n = &f.nodes.items[id];
        const p = n.para orelse return;
        f.inlineLayout(n, p, io) catch {
            f.layout_oom = true;
        };
    }

    noinline fn inlineLayout(f: *Frame, n: *Node, p: *font.Paragraph, io: *layout.InlineIo) Error!void {
        var fc: FlowCtx = .{ .io = io };
        var flow: font.Flow = .{ .alloc = f.a, .ctx = &fc };
        if (io.items.len > 0) {
            const objs = try f.a.alloc(font.ObjectMetrics, io.items.len);
            for (io.items, objs) |it, *o| o.* = if (it.kind == .atomic) .{ .width = it.width, .ascent = it.baseline, .descent = it.height - it.baseline } else .{};
            flow.objects = objs;
        }
        if (io.band_fn != null) flow.band_fn = FlowCtx.band;
        if (io.float_fn != null) flow.float_fn = FlowCtx.float;
        const w = io.width;
        p.setPercentBase(w);
        if (!(@abs(w) < std.math.inf(f32))) {
            // intrinsic sizes
            const iw = if (w < 0) p.minContentWidthFlow(&flow) else p.maxContentWidthFlow(&flow);
            io.size = .{ iw, 0 };
            if (io.width_only) return;
            const sz = p.measureFlow(&flow, if (w < 0) iw else null);
            io.size[1] = sz.height;
            if (sz.line_count > 0) {
                io.first_baseline = sz.first_baseline;
                io.last_baseline = sz.last_baseline;
            }
            return;
        }
        if (!io.layout) {
            const sz = p.measureFlow(&flow, w);
            io.size = .{ sz.width, sz.height };
            if (sz.line_count > 0) {
                io.first_baseline = sz.first_baseline;
                io.last_baseline = sz.last_baseline;
            }
            return;
        }
        const tl = try f.a.create(font.TextLayout);
        tl.* = p.layoutFlow(f.a, &flow, w) catch return error.OutOfMemory;
        if (p.has_pct_edges) try f.resolveBoxPadding(n, tl);
        n.tl = tl;
        n.tl_w = std.math.nan(f32);
        io.size = .{ tl.width, tl.height };
        if (tl.lines.len > 0) {
            io.first_baseline = tl.lines[0].baseline;
            io.last_baseline = tl.lines[tl.lines.len - 1].baseline;
        }
        for (tl.objects) |o| {
            if (o.id >= io.items.len) continue;
            io.items[o.id].x = o.x;
            io.items[o.id].y = o.y;
            io.items[o.id].placed = true;
            io.items[o.id].rtl = p.rtl;
        }
    }

    /// Inline boxes with percentage padding: the painters read the padding from the style, so they get
    /// a copy with the padding resolved against the percentage base of line layout `tl`.
    noinline fn resolveBoxPadding(f: *Frame, n: *const Node, tl: *const font.TextLayout) Error!void {
        for (tl.boxes) |fr| {
            const gi = @as(u64, n.box_base) + fr.box;
            if (gi >= f.inline_boxes.items.len) continue;
            const ib = &f.inline_boxes.items[@intCast(gi)];
            var any = false;
            for (ib.cs.padding) |lp| {
                if (lp.pct != 0 or lp.calc != null) any = true;
            }
            if (!any or (ib.paint_cs != null and ib.paint_base == tl.pct_base)) continue;
            const c = try f.a.create(CS);
            c.* = ib.cs.*;
            for (&c.padding) |*lp| lp.* = .{ .px = @max(lp.resolve(tl.pct_base), 0) };
            ib.paint_cs = c;
            ib.paint_base = tl.pct_base;
        }
    }

    /// Index of a node of `f.nodes` from its pointer.
    pub fn nodeId(f: *const Frame, n: *const Node) u32 {
        return @intCast((@intFromPtr(n) - @intFromPtr(f.nodes.items.ptr)) / @sizeOf(Node));
    }

    pub const FragInfo = struct { cs: *const CS, x0: f32, x1: f32, left: bool, right: bool };

    /// Painter view of an inline box fragment of paragraph node `n`: the box's style, its CONTENT
    /// extent, and whether its left / right padding + border are present on this fragment
    /// (`box-decoration-break: clone`: always). Null for a fragment without extent or a hidden box.
    pub fn boxFragment(f: *const Frame, n: *const Node, fr: *const font.BoxFragment) ?FragInfo {
        const gi = @as(u64, n.box_base) + fr.box;
        if (gi >= f.inline_boxes.items.len or !(fr.x1 >= fr.x0)) return null;
        const ib = f.inline_boxes.items[@intCast(gi)];
        const cs = ib.paint_cs orelse ib.cs;
        if (cs.visibility != .visible) return null;
        const clone = cs.box_decoration_break == .clone;
        // (the start edge is on the right in a right-to-left fragment)
        const has_left = if (fr.rtl) fr.last else fr.first;
        const has_right = if (fr.rtl) fr.first else fr.last;
        const bw = cs.usedBorderWidths();
        const base: f32 = if (n.tl) |tl| tl.pct_base else 0;
        const el = @trunc(bw[3] * 64) / 64 + @trunc(@max(cs.padding[3].resolve(base), 0) * 64) / 64;
        const er = @trunc(bw[1] * 64) / 64 + @trunc(@max(cs.padding[1].resolve(base), 0) * 64) / 64;
        return .{
            .cs = cs,
            .x0 = if (has_left) fr.x0 + el else fr.x0,
            .x1 = if (has_right) fr.x1 - er else fr.x1,
            .left = has_left or clone,
            .right = has_right or clone,
        };
    }

    /// Line layout of paragraph node `id` for painting / reporting: the one its layout pass left
    /// (inline content in a formatting context), else computed for content width `cw` (and kept).
    pub fn textLayout(f: *Frame, id: u32, cw: f32) Error!?*const font.TextLayout {
        const n = &f.nodes.items[id];
        const p = n.para orelse return null;
        if (n.tl) |tl| {
            if (n.tl_w != n.tl_w or n.tl_w == cw) return tl;
        }
        const tl = try f.a.create(font.TextLayout);
        p.setPercentBase(cw);
        tl.* = p.layout(f.a, cw) catch return error.OutOfMemory;
        if (p.has_pct_edges) try f.resolveBoxPadding(n, tl);
        n.tl = tl;
        n.tl_w = cw;
        return tl;
    }

    // ---- paged layout (PDF feature; see layout/fragment.zig)
    //
    // Use (the PDF emitter's document loop):
    //   f.setPaged(content_w, content_h);           // before prepare
    //   try f.prepare(kind, source);                // lays out at the page width, unbounded height
    //   const pages = try f.paginate(.{ .page_height = content_h });
    //   for (pages.pages, 0..) |pg, i| {
    //       // window [pg.top, pg.top + pg.height) of the frame, its top at the page content box top,
    //       // clipped to the content box: paint the root (paintNode(f.root, 0, 0)) translated by -pg.top
    //       for (pages.repeatsOf(i)) |r| {
    //           const o = f.repeatOrigin(r);        // paint subtree o.id at (o.ox, o.oy), same translation
    //       }
    //   }
    // Text needs nothing more: `textLayout` returns the lines already moved by the pagination
    // (`lineDy`), so glyphs, decorations, inline boxes, shadows and `RunIter` follow them.
    // `paintPageRaster` is the reference implementation through the raster painter. The state lives in
    // `f.tree.paged` (`layout.fragment.PagedState`; `void` without the PDF feature); `f.paginated()` reads it.

    /// The pagination result, null before `paginate` (and always without the PDF feature).
    pub fn paginated(f: *const Frame) ?*const layout.fragment.Pages {
        if (comptime !layout.fragment.enabled) return null;
        if (f.tree.paged.pages) |*p| return p;
        return null;
    }

    pub const PageLayout = struct {
        /// block size of the page area of every page
        page_height: f32,
        /// per-page block sizes (`@page :first`, bands): overrides `page_height`
        page_height_fn: ?layout.fragment.PageHeightFn = null,
        ctx: *anyopaque = undefined,
        max_pages: u32 = 20_000,
        /// content continued from a page of another width (`layout.fragment.Options.start`)
        start: ?layout.fragment.Start = null,
        start_top: ?f32 = null,
        record_starts: bool = false,
        /// `layout.fragment.Options.origin` / `root_shift`
        origin: f32 = 0,
        root_shift: f32 = 0,
    };

    /// Before `prepare`: lay the frame out for pages whose page area (content box) is
    /// `page_w` x `page_h` px (the first page's when they vary). The layout width is `page_w`
    /// truncated to whole px (takumi's `Viewport` is integral), the block size is unbounded; `vw` /
    /// `vh` resolve against the page area and `position: fixed` boxes against the first page's area
    /// (takumi-pdf `PageFrame::column` / `page_root`).
    pub fn setPaged(f: *Frame, page_w: f32, page_h: f32) void {
        if (comptime !layout.fragment.enabled) return;
        // (takumi lays the root out in the page area truncated to the LayoutUnit grid, 1/64 px)
        f.tree.paged.page_w = @floor(page_w * 64) / 64;
        f.tree.paged.page_h = page_h;
        f.opts.width = @intFromFloat(std.math.clamp(page_w, 1, 16384));
        f.opts.height = null;
    }

    /// After `prepare` (with `setPaged`): breaks the frame into pages. Rewrites the layout in place
    /// into stitched space (page i = frame y range [pages[i].top, + height)) and moves the lines of
    /// text that a break pushed down (`textLayout` returns them moved). Call once.
    pub fn paginate(f: *Frame, o: PageLayout) Error!*const layout.fragment.Pages {
        if (comptime layout.fragment.enabled) {
            f.tree.paged.height_fn = o.page_height_fn;
            f.tree.paged.height_ctx = o.ctx;
            if (f.tree.has_floats) if (o.start) |start| if (o.start_top) |page_top| {
                // (not a first line a float continuing above it pushed onto the page: it stays below the float)
                if (start.branches.len == 0 and !(start.line == 0 and start.side_flows.len > 0) and start.node < f.lid_node.items.len) {
                    const id = f.lid_node.items[start.node];
                    if (id != none) {
                        const n = &f.nodes.items[id];
                        // A deferred float can move the first paragraph line before it is consumed.
                        const first_line = if (start.line == none) 0 else start.line;
                        if (n.tl) |tl| if (first_line < tl.lines.len) {
                            var inline_float = false;
                            var child = f.tree.nodes.items[start.node].first_child;
                            while (child < f.tree.nodes.items.len) : (child = f.tree.nodes.items[child].next_sibling) {
                                if (f.tree.nodes.items[child].style.float != .none) inline_float = true;
                            }
                            const line_top = tl.lines[first_line].top;
                            const box = f.tree.layout(start.node);
                            var absolute_top = box.y + box.border.top + box.padding.top;
                            var parent = f.tree.nodes.items[start.node].parent;
                            while (parent < f.tree.nodes.items.len) : (parent = f.tree.nodes.items[parent].parent) absolute_top += f.tree.layout(parent).y;
                            const delta = page_top - absolute_top - line_top;
                            if (!inline_float and @abs(delta) > 1.0 / 64.0) {
                                f.tree.paged.inline_resume = .{ .node = start.node, .from_y = line_top, .dy = delta };
                                try f.recomputePaged();
                            }
                        };
                    }
                }
            };
            const reflow_floats = f.tree.has_floats and o.start == null;
            const previous_y: []f32 = if (reflow_floats) try f.a.alloc(f32, f.tree.nodes.items.len) else &.{};
            const previous_h: []f32 = if (reflow_floats) try f.a.alloc(f32, f.tree.nodes.items.len) else &.{};
            // (the block offset of each paragraph's content box before the breaks move it)
            const previous_text: []f32 = if (reflow_floats) try f.a.alloc(f32, f.tree.nodes.items.len) else &.{};
            var attempts: u32 = 0;
            while (true) {
                if (reflow_floats) for (previous_text, 0..) |*y, lid| {
                    y.* = std.math.nan(f32);
                    const id = if (lid < f.lid_node.items.len) f.lid_node.items[lid] else none;
                    if (id != none and f.nodes.items[id].para != null) y.* = f.contentTop(@intCast(lid));
                };
                if (reflow_floats) for (f.tree.nodes.items, 0..) |nd, lid| {
                    if (nd.style.float != .none) {
                        const before = f.tree.layout(@intCast(lid));
                        previous_y[lid] = before.y;
                        previous_h[lid] = before.h;
                    }
                };
                var pages = layout.fragment.paginate(&f.tree, f.a, f.lroot, .{
                    .page_height = o.page_height,
                    .page_height_fn = if (o.page_height_fn != null) pageHeightCb else null,
                    .ctx = @ptrCast(f),
                    .lines_fn = linesCb,
                    .max_pages = o.max_pages,
                    .start = o.start,
                    .start_top = o.start_top,
                    .record_starts = o.record_starts,
                    .origin = o.origin,
                    .root_shift = o.root_shift,
                    .extent_fn = if (comptime config.enable_pdf) movedExtentCb else null,
                }) catch |e| return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.TooManyPages => f.fail("The content spans more than 20000 pages. Give it a height that resolves.", ""),
                    error.InvalidPageSize => f.fail("invalid page size", ""),
                };
                if (f.layout_oom) return error.OutOfMemory;
                var changed = false;
                if (reflow_floats) for (f.tree.nodes.items, 0..) |nd, lid| {
                    if (nd.style.float == .none or nd.style.breaks.before != .auto) continue;
                    const box = f.tree.layout(@intCast(lid));
                    // Pagination can insert space into a split float when its remaining children
                    // resume in the next fragmentainer. Carry that added extent into the next
                    // intrinsic layout so following lines keep the float exclusion to its end.
                    const extent = @max(box.h - previous_h[lid], 0);
                    const old_extent = if (lid < f.tree.paged.float_extents.len) f.tree.paged.float_extents[lid] else 0;
                    if (extent > old_extent + 1.0 / 64.0) {
                        if (f.tree.paged.float_extents.len == 0) {
                            f.tree.paged.float_extents = try f.a.alloc(f32, f.tree.nodes.items.len);
                            @memset(f.tree.paged.float_extents, 0);
                        }
                        f.tree.paged.float_extents[lid] = extent;
                        changed = true;
                    }
                    // Whole floats that fit one page can be placed before laying
                    // out the following lines. Split floats need continuation
                    // extents above and remain in the fragmentation algorithm.
                    var top = box.y;
                    var parent = nd.parent;
                    while (parent < f.tree.nodes.items.len) : (parent = f.tree.nodes.items[parent].parent) top += f.tree.layout(parent).y;
                    const float_page = pages.pageAt(top);
                    if (box.h + box.margin.top + box.margin.bottom > pages.pages[float_page].height) continue;
                    const delta = box.y - previous_y[lid];
                    if (delta <= 1.0 / 64.0) continue;
                    if (f.tree.paged.float_shifts.len == 0) {
                        f.tree.paged.float_shifts = try f.a.alloc(f32, f.tree.nodes.items.len);
                        @memset(f.tree.paged.float_shifts, 0);
                    }
                    f.tree.paged.float_shifts[lid] += delta;
                    changed = true;
                };
                // A paragraph moved down whole or in part (orphans / widows, a break between its
                // lines) beside floats: its moved lines wrap against the floats where they land
                // (takumi lays them out there), so they are laid out again with that offset
                // (`PagedState.inline_resume`, one paragraph per document).
                if (!changed and reflow_floats and f.tree.paged.inline_resume == null) if (try f.floatShiftedParagraph(&pages, previous_text)) |resumed| {
                    f.tree.paged.inline_resume = resumed;
                    changed = true;
                };
                if (changed) {
                    pages.deinit(f.a);
                    attempts += 1;
                    if (attempts >= o.max_pages) return f.fail("Float placement did not settle within the page limit.", "");
                    try f.recomputePaged();
                    continue;
                }
                f.tree.paged.pages = pages;
                try f.applyLineShifts(&f.tree.paged.pages.?);
                if (o.record_starts) try f.recordRowspanStarts(&f.tree.paged.pages.?);
                return &f.tree.paged.pages.?;
            }
        } else return f.fail("paged layout is not supported by this build", "");
    }

    /// The first paragraph whose lines `pages` moves down (`Pages.line_shifts`) into or out of the
    /// block range of a float beside it, as an `inline_resume` laying those lines out against the
    /// floats where they land; null: none.
    fn floatShiftedParagraph(f: *Frame, pages: *const layout.fragment.Pages, previous_text: []const f32) Error!?@TypeOf(f.tree.paged.inline_resume.?) {
        if (comptime !layout.fragment.enabled) return null;
        const eps = 1.0 / 64.0;
        const t = &f.tree;
        // (paragraphs the breaks moved whole: a box moved down with all its lines)
        var moved: std.ArrayList(layout.fragment.LineShift) = .empty;
        defer moved.deinit(f.a);
        for (previous_text, 0..) |before, lid| {
            if (!(before == before)) continue;
            const dy = f.contentTop(@intCast(lid)) - before;
            if (dy > eps) try moved.append(f.a, .{ .node = @intCast(lid), .first_line = 0, .dy = dy });
        }
        for ([_][]const layout.fragment.LineShift{ moved.items, pages.line_shifts }) |list| for (list) |sh| {
            if (!(sh.dy > eps) or sh.node >= f.lid_node.items.len) continue;
            const id = f.lid_node.items[sh.node];
            if (id == none) continue;
            const tl = f.nodes.items[id].tl orelse continue;
            if (sh.first_line >= tl.lines.len) continue;
            // (floats among the paragraph's own lines move with them)
            var own_float = false;
            var child = t.nodes.items[sh.node].first_child;
            while (child < t.nodes.items.len) : (child = t.nodes.items[child].next_sibling) {
                if (t.nodes.items[child].style.float != .none) own_float = true;
            }
            if (own_float) continue;
            const box = t.layout(sh.node);
            // (where the lines were laid out: before the breaks moved the box)
            const top = if (list.ptr == moved.items.ptr) previous_text[sh.node] else f.contentTop(sh.node);
            var left = box.x + box.border.left + box.padding.left;
            var parent = t.nodes.items[sh.node].parent;
            while (parent < t.nodes.items.len) : (parent = t.nodes.items[parent].parent) left += t.layout(parent).x;
            const right = left + box.w - box.border.left - box.border.right - box.padding.left - box.padding.right;
            for (t.nodes.items, 0..) |nd, lid| {
                if (nd.style.float == .none or nd.style.display == .none) continue;
                const fb = t.layout(@intCast(lid));
                var fy = fb.y - @max(fb.margin.top, 0);
                var fx = fb.x;
                var anc = nd.parent;
                while (anc < t.nodes.items.len) : (anc = t.nodes.items[anc].parent) {
                    fy += t.layout(anc).y;
                    fx += t.layout(anc).x;
                }
                const fy1 = fy + @max(fb.margin.top, 0) + fb.h + @max(fb.margin.bottom, 0);
                // (beside the paragraph: its inline range meets the float's)
                if (fx + fb.w <= left + eps or fx >= right - eps) continue;
                for (tl.lines[sh.first_line..]) |ln| {
                    const y0 = top + ln.top;
                    const y1 = y0 + @max(ln.height, eps);
                    const before = y1 > fy + eps and y0 < fy1 - eps;
                    const after = y1 + sh.dy > fy + eps and y0 + sh.dy < fy1 - eps;
                    if (before != after) return .{ .node = sh.node, .from_y = tl.lines[sh.first_line].top, .dy = sh.dy };
                }
            }
        };
        return null;
    }

    /// Block offset of the content box of layout node `lid` in the frame.
    fn contentTop(f: *const Frame, lid: u32) f32 {
        const t = &f.tree;
        const box = t.layout(lid);
        var top = box.y + box.border.top + box.padding.top;
        var parent = t.nodes.items[lid].parent;
        while (parent < t.nodes.items.len) : (parent = t.nodes.items[parent].parent) top += t.layout(parent).y;
        return top;
    }

    fn recomputePaged(f: *Frame) Error!void {
        for (f.nodes.items) |*node| {
            node.tl = null;
            node.tl_w = 0;
        }
        f.tree.compute(f.lroot, .{ .{ .definite = f.tree.paged.page_w }, .max_content }, f, measureCb, .{ .quantize64 = true, .baseline = baselineCb, .inline_fn = inlineCb }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => f.fail("node tree is nested too deeply", ""),
        };
        if (f.layout_oom) return error.OutOfMemory;
    }

    fn recordRowspanStarts(f: *Frame, pages: *layout.fragment.Pages) Error!void {
        var cells: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer cells.deinit(f.a);
        for (f.tree.table_geoms.items) |table| for (table.cells) |cell| {
            if (cell.rowspan > 1 and cell.node < f.tree.nodes.items.len) try cells.put(f.a, cell.node, {});
        };
        if (cells.count() == 0) return;
        var paragraphs: std.ArrayList(u32) = .empty;
        defer paragraphs.deinit(f.a);
        for (f.nodes.items, 0..) |n, id| {
            if (n.para == null or n.lid == none) continue;
            var ancestor = n.lid;
            while (ancestor < f.tree.nodes.items.len) : (ancestor = f.tree.nodes.items[ancestor].parent) {
                if (cells.contains(ancestor)) {
                    try paragraphs.append(f.a, @intCast(id));
                    break;
                }
            }
        }
        for (pages.starts, 0..) |*start, i| {
            if (i == 0) continue;
            const top = pages.pages[i].top;
            var points: std.ArrayList(layout.fragment.ResumePoint) = .empty;
            for (paragraphs.items) |id| {
                const n = &f.nodes.items[id];
                const p = n.para.?;
                if (p.cut == p.glyphs.len) {
                    try points.append(f.a, .{ .node = n.lid, .finished = true });
                    continue;
                }
                const tl = n.tl orelse continue;
                if (tl.lines.len == 0) continue;
                const box = f.tree.layout(n.lid);
                var absolute_top = box.y + box.border.top + box.padding.top;
                var parent = f.tree.nodes.items[n.lid].parent;
                while (parent < f.tree.nodes.items.len) : (parent = f.tree.nodes.items[parent].parent) absolute_top += f.tree.layout(parent).y;
                if (absolute_top > top + 1.0 / 64.0) continue;
                var line: usize = 0;
                while (line < tl.lines.len and absolute_top + tl.lines[line].top < top - 1.0 / 64.0) line += 1;
                try points.append(f.a, if (line == tl.lines.len) .{ .node = n.lid, .finished = true } else .{ .node = n.lid, .line = if (line == 0) none else @intCast(line) });
            }
            start.side_flows = try points.toOwnedSlice(f.a);
        }
    }

    fn movedExtentCb(ctx: *anyopaque) ?f32 {
        if (comptime !config.enable_pdf) return null;
        const f: *Frame = @ptrCast(@alignCast(ctx));
        return @import("pdf/emit.zig").movedExtent(f);
    }

    fn pageHeightCb(ctx: *anyopaque, page: u32, name: u32) f32 {
        const f: *Frame = @ptrCast(@alignCast(ctx));
        if (comptime !layout.fragment.enabled) return 0;
        return f.tree.paged.height_fn.?(f.tree.paged.height_ctx, page, name);
    }

    /// `layout.fragment.LinesFn`: the line boxes of a text leaf / inline formatting context, from its
    /// border-box top (none for images and other leaves without text).
    fn linesCb(ctx: *anyopaque, lid: layout.NodeId) []const layout.fragment.LineBox {
        const f: *Frame = @ptrCast(@alignCast(ctx));
        if (comptime !layout.fragment.enabled) return &.{};
        if (lid >= f.lid_node.items.len) return &.{};
        const id = f.lid_node.items[lid];
        if (id == none or f.nodes.items[id].para == null) return &.{};
        const l = f.tree.layout(lid);
        const cw = l.w - l.border.left - l.border.right - l.padding.left - l.padding.right;
        const tl = (f.textLayout(id, cw) catch {
            f.layout_oom = true;
            return &.{};
        }) orelse return &.{};
        const y0 = l.border.top + l.padding.top;
        const out = &f.tree.paged.lines;
        out.clearRetainingCapacity();
        out.ensureTotalCapacity(f.a, tl.lines.len) catch {
            f.layout_oom = true;
            return &.{};
        };
        for (tl.lines) |ln| out.appendAssumeCapacity(.{ .top = y0 + ln.top, .bottom = y0 + ln.top + ln.height });
        return out.items;
    }

    /// Replaces the line layout of every node with line shifts by a copy whose lines (and their
    /// glyphs, run segments, inline box fragments and atomic inline positions) sit `lineDy` lower.
    noinline fn applyLineShifts(f: *Frame, pages: *const layout.fragment.Pages) Error!void {
        const shifts = pages.line_shifts;
        var i: usize = 0;
        while (i < shifts.len) {
            var j = i + 1;
            while (j < shifts.len and shifts[j].node == shifts[i].node) j += 1;
            defer i = j;
            const lid = shifts[i].node;
            if (lid >= f.lid_node.items.len or f.lid_node.items[lid] == none) continue;
            const n = &f.nodes.items[f.lid_node.items[lid]];
            const src = n.tl orelse continue;
            const tl = try f.a.create(font.TextLayout);
            tl.* = src.*;
            tl.lines = try f.a.dupe(font.Line, src.lines);
            tl.glyphs = try f.a.dupe(font.PositionedGlyph, src.glyphs);
            tl.segments = try f.a.dupe(font.Segment, src.segments);
            tl.boxes = try f.a.dupe(font.BoxFragment, src.boxes);
            tl.objects = try f.a.dupe(font.ObjectPos, src.objects);
            const dys = try f.a.alloc(f32, tl.lines.len);
            for (dys, 0..) |*d, k| d.* = pages.lineDy(lid, @intCast(k));
            for (tl.lines, dys) |*ln, d| {
                if (d == 0) continue;
                ln.top += d;
                ln.baseline += d;
                const g1 = @min(ln.glyph_end, tl.glyphs.len);
                if (ln.glyph_start < g1) for (tl.glyphs[ln.glyph_start..g1]) |*g| {
                    g.y += d;
                };
                tl.height = @max(tl.height, ln.top + ln.height);
            }
            for (tl.segments) |*s| s.baseline += if (s.line < dys.len) dys[s.line] else 0;
            for (tl.boxes) |*b| b.baseline += if (b.line < dys.len) dys[b.line] else 0;
            for (tl.objects) |*ob| ob.y += if (ob.line < dys.len) dys[ob.line] else 0;
            n.tl = tl;
        }
    }

    /// Block shift of line `line` of paragraph node `id` made by `paginate` (0 when not paged).
    /// Informational: `textLayout` already returns the moved lines; painters must not add it again.
    pub fn lineDy(f: *const Frame, id: u32, line: u32) f32 {
        if (comptime !layout.fragment.enabled) return 0;
        if (f.tree.paged.pages) |*pages| return pages.lineDy(f.nodes.items[id].lid, line);
        return 0;
    }

    /// Where to paint a repeat (`Pages.repeatsOf`): render node `id` painted as a child at origin
    /// (`ox`, `oy`) = the border-box origin of its parent in stitched space, moved by `r.dy`; i.e.
    /// `paintNode(id, ox, oy)` under the same page translation as the root.
    pub fn repeatOrigin(f: *const Frame, r: layout.fragment.Repeat) struct { id: u32, ox: f32, oy: f32 } {
        var ox: f32 = 0;
        var oy: f32 = r.dy;
        var cur = f.tree.nodes.items[r.node].parent;
        var guard: u32 = 0;
        while (cur < f.tree.nodes.items.len and guard < layout.max_depth + 8) : (guard += 1) {
            const l = f.tree.layout(cur);
            ox += l.x;
            oy += l.y;
            if (cur == f.lroot) break;
            cur = f.tree.nodes.items[cur].parent;
        }
        const id = if (r.node < f.lid_node.items.len) f.lid_node.items[r.node] else none;
        return .{ .id = id, .ox = ox, .oy = oy };
    }

    /// Reference "paint a page" through the raster painter (tests, and the recipe the PDF emitter
    /// follows): page `i` of a paginated frame as a page-area-sized pixmap. The painter has no
    /// public offset entry, so the painted root's layout position is moved for the call: the frame
    /// translated by -page.top (the pixmap bounds are the page clip), then every repeat of the page
    /// (repeated table headers / footers, fixed boxes) painted at `repeatOrigin`.
    pub fn paintPageRaster(f: *Frame, i: u32) Error!raster.Pixmap {
        if (comptime !layout.fragment.enabled) return f.fail("paged layout is not supported by this build", "");
        if (f.tree.paged.pages == null) return f.fail("not paginated", "");
        const pages = &f.tree.paged.pages.?;
        if (i >= pages.pages.len) return f.fail("no such page", "");
        const pg = pages.pages[i];
        var pm = raster.Pixmap.init(f.a, f.canvas_w, @intFromFloat(@max(1, @ceil(pg.height)))) catch return error.OutOfMemory;
        @memset(pm.data, 0);
        const saved_root = f.root;
        defer f.root = saved_root;
        // the frame
        try f.paintShifted(f.root, 0, -pg.top, &pm);
        // the repeats, in the same page translation
        for (pages.repeatsOf(i)) |r| {
            const o = f.repeatOrigin(r);
            if (o.id == none) continue;
            f.root = o.id;
            try f.paintShifted(o.id, o.ox, o.oy - pg.top, &pm);
        }
        return pm;
    }

    /// `paint.paintFrame` of the subtree of render node `id` as if its parent's border-box origin
    /// were (ox, oy) (`f.root` must be `id`).
    fn paintShifted(f: *Frame, id: u32, ox: f32, oy: f32, pm: *raster.Pixmap) Error!void {
        const l = &f.tree.layouts.items[f.nodes.items[id].lid];
        const saved = l.*;
        defer l.* = saved;
        // (the root is painted at its own layout position; a wrapper ICB node sits at 0, 0)
        l.x += ox;
        l.y += oy;
        try paint.paintFrame(f, pm);
    }

    // ---- measure() output

    /// takumi's `MeasuredNode` shape: a block container's inline content is reported as the block's
    /// own `runs` (x / y relative to its content box) with its atomic inline boxes as `children`;
    /// anonymous paragraph leaves / line containers only appear as boxes of their own beside
    /// block-level siblings (takumi's anonymous block wrappers).
    /// `pt` = the parent's measured transform (takumi: parent * T(location) * own local transform).
    fn writeMeasured(f: *Frame, out: *std.ArrayList(u8), id: u32, pt: mx.Affine) Error!void {
        return f.writeMeasuredAt(out, id, pt, 0, 0);
    }

    /// `pt` is the transform of a box at (`px`, `py`) of the node's layout parent (the anonymous
    /// box takumi puts around block-in-inline boxes): the location is relative to it.
    fn writeMeasuredAt(f: *Frame, out: *std.ArrayList(u8), id: u32, pt: mx.Affine, px: f32, py: f32) Error!void {
        const a = f.a;
        const n = &f.nodes.items[id];
        const l = f.tree.layout(n.lid);
        // (an anonymous paragraph leaf shares its block's style: the transform is the block's, not its own)
        const here = mx.mul(pt, mx.Affine.translate(l.x - px, l.y - py));
        const t = if (n.kind == .anon_text) here else mx.mul(here, mx.local(n.cs, l.w, l.h));
        try out.appendSlice(a, "{\"width\":");
        try mx.writeExact(a, out, l.w);
        try out.appendSlice(a, ",\"height\":");
        try mx.writeExact(a, out, l.h);
        try writeAffine(a, out, t);
        try out.appendSlice(a, ",\"children\":[");
        // the anonymous child holding all in-flow content, reported as this box's inline content
        var inl = if (n.kind == .container and hasLines(n.cs.display)) f.soleInline(id) else none;
        // (inline content holding out-of-flow boxes is reported as takumi's anonymous block around it)
        if (inl != none and f.hasOutOfFlow(inl)) inl = none;
        var first = true;
        if (n.kind == .anon_box) try f.writePlaceholders(out, id, t, &first);
        const split = n.kind == .container and f.hasSplitInline(id);
        if (split) {
            try f.writeSplitChildren(out, id, t, &first);
        } else {
            if (inl != none and f.nodes.items[inl].kind == .anon_box) {
                const il = f.tree.layout(f.nodes.items[inl].lid);
                // (takumi locates the boxes of the inline content in the container itself: one translation)
                try f.writeChildrenAt(out, inl, t, -il.x, -il.y, none, &first);
            }
            try f.writeChildren(out, id, t, inl, &first);
        }
        try out.appendSlice(a, "],\"runs\":[");
        first = true;
        const cx = l.border.left + l.padding.left;
        const cy = l.border.top + l.padding.top;
        if (n.para != null) {
            try f.writeRuns(out, id, 0, 0, &first);
        } else if (inl != none) {
            const il = f.tree.layout(f.nodes.items[inl].lid);
            try f.writeRuns(out, inl, il.x - cx, il.y - cy, &first);
        } else if (split) {
            var c = n.first_child;
            while (c != none) : (c = f.nodes.items[c].next) {
                if (!f.nodes.items[c].ifc_part) continue;
                const il = f.tree.layout(f.nodes.items[c].lid);
                try f.writeRuns(out, c, il.x - cx, il.y - cy, &first);
            }
        }
        try out.appendSlice(a, "]}");
    }

    /// The node holds an inline formatting context split by block-in-inline boxes.
    fn hasSplitInline(f: *const Frame, id: u32) bool {
        var c = f.nodes.items[id].first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            if (f.nodes.items[c].ifc_part) return true;
        }
        return false;
    }

    /// measure() children of a container with block-in-inline content, as takumi reports them: the
    /// atomic inlines of the parts, an anonymous box of the container's width around every run of
    /// block-in-inline boxes, the other children as they are.
    /// `t` = the container's measured transform (its children's parent transform).
    noinline fn writeSplitChildren(f: *Frame, out: *std.ArrayList(u8), id: u32, t: mx.Affine, first: *bool) Error!void {
        const a = f.a;
        const n = &f.nodes.items[id];
        const l = f.tree.layout(n.lid);
        var c = n.first_child;
        while (c != none) {
            const cn = &f.nodes.items[c];
            if (cn.bii) {
                var y0: f32 = std.math.inf(f32);
                var y1: f32 = -std.math.inf(f32);
                var e = c;
                while (e != none and f.nodes.items[e].bii) : (e = f.nodes.items[e].next) {
                    const el = f.tree.layout(f.nodes.items[e].lid);
                    y0 = @min(y0, el.y);
                    y1 = @max(y1, el.y + el.h);
                }
                if (!first.*) try out.append(a, ',');
                first.* = false;
                try out.appendSlice(a, "{\"width\":");
                try mx.writeExact(a, out, l.w - l.border.left - l.border.right - l.padding.left - l.padding.right);
                try out.appendSlice(a, ",\"height\":");
                try mx.writeExact(a, out, y1 - y0);
                // (the boxes inside compose from the anonymous box, as takumi's do)
                const ax = l.border.left + l.padding.left;
                const at = mx.mul(t, mx.Affine.translate(ax, y0));
                try writeAffine(a, out, at);
                try out.appendSlice(a, ",\"children\":[");
                var k = c;
                while (k != e) : (k = f.nodes.items[k].next) {
                    if (k != c) try out.append(a, ',');
                    try f.writeMeasuredAt(out, k, at, ax, y0);
                }
                try out.appendSlice(a, "],\"runs\":[]}");
                c = e;
                continue;
            }
            if (cn.ifc_part) {
                if (cn.kind == .anon_box) {
                    const il = f.tree.layout(cn.lid);
                    // (the boxes of the inline content are located in the container itself)
                    try f.writeChildrenAt(out, c, t, -il.x, -il.y, none, first);
                }
            } else {
                if (!first.*) try out.append(a, ',');
                first.* = false;
                try f.writeMeasured(out, c, t);
            }
            c = cn.next;
        }
    }

    /// Children of `id` except `skip` (and the inline-level boxes of an inline formatting context
    /// that are on no line, e.g. cut off by a line clamp).
    fn writeChildren(f: *Frame, out: *std.ArrayList(u8), id: u32, pt: mx.Affine, skip: u32, first: *bool) Error!void {
        return f.writeChildrenAt(out, id, pt, 0, 0, skip, first);
    }

    /// (`px`, `py`: see `writeMeasuredAt`)
    fn writeChildrenAt(f: *Frame, out: *std.ArrayList(u8), id: u32, pt: mx.Affine, px: f32, py: f32, skip: u32, first: *bool) Error!void {
        const tl: ?*const font.TextLayout = if (f.nodes.items[id].kind == .anon_box) f.nodes.items[id].tl else null;
        var k: u32 = 0;
        var c = f.nodes.items[id].first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            defer k += 1;
            if (c == skip) continue;
            if (tl) |t| {
                const ccs = f.nodes.items[c].cs;
                if (ccs.float == .none and !isOutOfFlow(ccs)) {
                    var on_line = false;
                    for (t.objects) |o| {
                        if (o.id == k) on_line = true;
                    }
                    if (!on_line) continue;
                }
            }
            if (!first.*) try out.append(f.a, ',');
            first.* = false;
            try f.writeMeasuredAt(out, c, pt, px, py);
        }
    }

    fn isOutOfFlow(cs: *const CS) bool {
        return cs.display != .none and (cs.position == .absolute or cs.position == .fixed);
    }

    noinline fn hasOutOfFlow(f: *const Frame, id: u32) bool {
        if (f.nodes.items[id].kind != .anon_box) return false;
        var c = f.nodes.items[id].first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            if (isOutOfFlow(f.nodes.items[c].cs)) return true;
        }
        return false;
    }

    /// takumi reports an empty box at the static position of every out-of-flow box of an inline
    /// formatting context, before its boxes.
    noinline fn writePlaceholders(f: *Frame, out: *std.ArrayList(u8), id: u32, pt: mx.Affine, first: *bool) Error!void {
        const n = &f.nodes.items[id];
        const tl = n.tl orelse return;
        var k: u32 = 0;
        var c = n.first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            defer k += 1;
            // (only for the out-of-flow boxes that are direct children of the block)
            if (!isOutOfFlow(f.nodes.items[c].cs) or f.nodes.items[c].in_inline_box) continue;
            for (tl.objects) |o| {
                if (o.id != k) continue;
                if (!first.*) try out.append(f.a, ',');
                first.* = false;
                try out.appendSlice(f.a, "{\"width\":0,\"height\":0");
                try writeAffine(f.a, out, mx.mul(pt, mx.Affine.translate(o.x, o.y)));
                try out.appendSlice(f.a, ",\"children\":[],\"runs\":[]}");
                break;
            }
        }
    }

    /// The anonymous paragraph leaf / line container that is the only in-flow child of `id`.
    noinline fn soleInline(f: *const Frame, id: u32) u32 {
        var found: u32 = none;
        var c = f.nodes.items[id].first_child;
        while (c != none) : (c = f.nodes.items[c].next) {
            const cn = &f.nodes.items[c];
            if (cn.kind != .anon_text and cn.kind != .anon_box) {
                const cs = cn.cs;
                if (cs.display == .none or cs.position == .absolute or cs.position == .fixed or cs.float != .none) continue;
                return none;
            }
            if (found != none) return none;
            found = c;
        }
        return found;
    }

    /// Text runs of paragraph node `id` (one per line and source run); (dx, dy) = the node's
    /// border-box offset from the content box the runs are reported against.
    noinline fn writeRuns(f: *Frame, out: *std.ArrayList(u8), id: u32, dx: f32, dy: f32, first: *bool) Error!void {
        const a = f.a;
        const l = f.tree.layout(f.nodes.items[id].lid);
        const cw = l.w - l.padding.left - l.padding.right - l.border.left - l.border.right;
        const tl = (try f.textLayout(id, cw)) orelse return;
        const ox = dx + l.border.left + l.padding.left;
        const oy = dy + l.border.top + l.padding.top;
        if (tl.segments.len > 0) {
            // (inline boxes / objects: the exact extent of every run segment)
            for (tl.segments) |sg| {
                if (sg.line >= tl.lines.len) continue;
                const line = tl.lines[sg.line];
                if (!first.*) try out.append(a, ',');
                first.* = false;
                try out.appendSlice(a, "{\"x\":");
                try mx.writeExact(a, out, ox + @min(sg.x0, sg.x1));
                try out.appendSlice(a, ",\"y\":");
                try mx.writeExact(a, out, oy + line.top + (sg.baseline - line.baseline));
                try out.appendSlice(a, ",\"width\":");
                try mx.writeExact(a, out, @abs(sg.x1 - sg.x0));
                try out.appendSlice(a, ",\"height\":");
                try mx.writeExact(a, out, line.height);
                try out.append(a, '}');
            }
            return;
        }
        for (tl.lines) |line| {
            var g = line.glyph_start;
            const end = @min(line.glyph_end, tl.glyphs.len);
            // one run per source run (glyph `user`) of the line; an empty line still reports one
            while (true) {
                var x0 = line.x;
                var x1 = line.x + line.width;
                if (g < end) {
                    var e = g + 1;
                    while (e < end and tl.glyphs[e].user == tl.glyphs[g].user) e += 1;
                    if (g != line.glyph_start) x0 = tl.glyphs[g].x;
                    if (e < end) x1 = tl.glyphs[e].x;
                    g = e;
                }
                if (!first.*) try out.append(a, ',');
                first.* = false;
                try out.appendSlice(a, "{\"x\":");
                try mx.writeExact(a, out, ox + @min(x0, x1));
                try out.appendSlice(a, ",\"y\":");
                try mx.writeExact(a, out, oy + line.top);
                try out.appendSlice(a, ",\"width\":");
                try mx.writeExact(a, out, @abs(x1 - x0));
                try out.appendSlice(a, ",\"height\":");
                try mx.writeExact(a, out, line.height);
                try out.append(a, '}');
                if (g >= end) break;
            }
        }
    }
};

fn parseBlock(a: Allocator, text: []const u8) Error![]const style.Declaration {
    return style.parseDeclarationBlock(a, text) catch error.OutOfMemory;
}

/// css / tw declarations (kebab-case name, value text, important flag) -> style declarations.
fn convertDecls(a: Allocator, src: anytype) Error![]const style.Declaration {
    if (src.len == 0) return &.{};
    const out = try a.alloc(style.Declaration, src.len);
    for (src, out) |d, *o| o.* = .{ .name = d.name, .value = d.value, .important = d.important };
    return out;
}

/// `css.Dom` callbacks over the element model (only ELEMENTS are visible; bare text runs skipped).
pub const CssDom = struct {
    fn d(ctx: *const anyopaque) *const dom_mod.Dom {
        return @ptrCast(@alignCast(ctx));
    }
    fn e(x: usize) u32 {
        return @intCast(x);
    }
    fn tag(ctx: *const anyopaque, x: usize) []const u8 {
        return d(ctx).at(e(x)).tag;
    }
    fn id(ctx: *const anyopaque, x: usize) []const u8 {
        return d(ctx).at(e(x)).id;
    }
    fn classes(ctx: *const anyopaque, x: usize) []const u8 {
        return d(ctx).at(e(x)).class;
    }
    fn attr(ctx: *const anyopaque, x: usize, name: []const u8) ?[]const u8 {
        return d(ctx).attr(e(x), name);
    }
    fn parent(ctx: *const anyopaque, x: usize) ?usize {
        const p = d(ctx).at(e(x)).parent;
        return if (p == none) null else p;
    }
    fn prev(ctx: *const anyopaque, x: usize) ?usize {
        return if (d(ctx).prevEl(e(x))) |v| v else null;
    }
    fn next(ctx: *const anyopaque, x: usize) ?usize {
        return if (d(ctx).nextEl(e(x))) |v| v else null;
    }
    fn first(ctx: *const anyopaque, x: usize) ?usize {
        return if (d(ctx).firstEl(e(x))) |v| v else null;
    }
    fn empty(ctx: *const anyopaque, x: usize) bool {
        return d(ctx).isEmpty(e(x));
    }
    fn dir(ctx: *const anyopaque, x: usize) css.Dir {
        return switch (d(ctx).at(e(x)).dir) {
            .none => .none,
            .ltr => .ltr,
            .rtl => .rtl,
        };
    }
    pub fn vtable(dm: *const dom_mod.Dom) css.Dom {
        return .{ .ctx = dm, .tag = tag, .id = id, .classes = classes, .attr = attr, .parent = parent, .prev_sibling = prev, .next_sibling = next, .first_child = first, .is_empty = empty, .dir = dir };
    }
};

pub fn textStyle(cs: *const CS, user: u32) font.TextStyle {
    var ts: font.TextStyle = .{
        .unicode_bidi = @fromBackingInt(@intCast(@backingInt(cs.unicode_bidi))),
        .rtl = cs.direction == .rtl,
        .no_hyphens = cs.hyphens == .none,
        .families = cs.font_family,
        .weight = cs.font_weight,
        .italic = cs.font_style != .normal,
        .size = cs.font_size,
        .letter_spacing = cs.letter_spacing,
        .word_spacing = cs.word_spacing,
        .tab_spaces = if (cs.tab_size == .number) @intFromFloat(@min(512, @max(0, @round(cs.tab_size.number)))) else null,
        .tab_length = if (cs.tab_size == .px) cs.tab_size.px else null,
        .user = user,
        .stretch = cs.font_stretch,
        .optical_sizing = cs.font_optical_sizing != .none,
        // (same member order: normal, small, all-small, petite, all-petite, unicase, titling)
        .caps = @fromBackingInt(@intCast(@backingInt(cs.font_variant_caps))),
        .synth_small_caps = cs.font_synthesis.small_caps,
    };
    // style.FontVariation and font.AxisValue are both { tag: [4]u8, value: f32 }
    const V = @typeInfo(@TypeOf(ts.variations)).pointer.child;
    comptime std.debug.assert(@sizeOf(V) == @sizeOf(style.computed.FontVariation));
    const vs = cs.font_variation_settings;
    ts.variations = @as([*]const V, @ptrCast(vs.ptr))[0..vs.len];
    return ts;
}

fn decodeCp(s: []const u8, i: *usize) u21 {
    const b0 = s[i.*];
    var len: usize = 1;
    var cp: u21 = b0;
    if (b0 >= 0xF0 and b0 < 0xF8) {
        len = 4;
        cp = b0 & 0x07;
    } else if (b0 >= 0xE0) {
        len = 3;
        cp = b0 & 0x0F;
    } else if (b0 >= 0xC0) {
        len = 2;
        cp = b0 & 0x1F;
    } else {
        i.* += 1;
        return b0;
    }
    if (i.* + len > s.len) {
        i.* += 1;
        return 0xFFFD;
    }
    var k: usize = 1;
    while (k < len) : (k += 1) {
        const b = s[i.* + k];
        if (b & 0xC0 != 0x80) {
            i.* += 1;
            return 0xFFFD;
        }
        cp = (cp << 6) | (b & 0x3F);
    }
    i.* += len;
    return cp;
}

/// Greek final-sigma context helpers (Unicode 3.13 Final_Sigma, approximated: cased = has a
/// case mapping, case-ignorable = apostrophes and combining marks).
fn isCased(cp: u21) bool {
    return font.case.upperSimple(cp) != cp or font.case.lower(cp) != cp;
}
fn isCaseIgnorable(cp: u21) bool {
    return cp == 0x27 or cp == 0x2019 or cp == 0xB7 or (cp >= 0x300 and cp <= 0x36F);
}
fn nextCased(text: []const u8, from: usize) bool {
    var i = from;
    while (i < text.len) {
        const cp = decodeCp(text, &i);
        if (!isCaseIgnorable(cp)) return isCased(cp);
    }
    return false;
}

/// Titlecase for capitalize: uppercase, except the Latin digraphs (DŽ/Dž/dž -> Dž, ...).
fn titleCase(cp: u21) u21 {
    return switch (cp) {
        0x1C4...0x1C6 => 0x1C5,
        0x1C7...0x1C9 => 0x1C8,
        0x1CA...0x1CC => 0x1CB,
        0x1F1...0x1F3 => 0x1F2,
        else => font.case.upperSimple(cp),
    };
}

/// text-transform without a language (takumi with no `lang`): full uppercase (SpecialCasing
/// expansions: ß -> SS, ﬁ -> FI, ...), simple lowercase with the final-sigma rule and
/// U+0130 -> i + U+0307; capitalize = titlecase of a word start (a character not preceded by a
/// letter / digit, nor by an apostrophe, period, colon or middle dot between letters: UAX #29 approximated).
pub fn transformText(a: Allocator, text: []const u8, tt: style.computed.TextTransform, preserve_spaces: bool) Error![]const u8 {
    if (tt == .none) return text;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, text.len + 8);
    var i: usize = 0;
    var word_start = true;
    var prev_cased = false;
    var prev: u21 = 0;
    var prev2: u21 = 0;
    while (i < text.len) {
        const cp = decodeCp(text, &i);
        var m: [3]u21 = .{ cp, 0, 0 };
        var n: usize = 1;
        const case: style.computed.TextTransform = @fromBackingInt(@backingInt(tt) & 3);
        switch (case) {
            .uppercase => n = font.case.upper(cp, &m),
            .lowercase => {
                m[0] = font.case.lower(cp);
                if (cp == 0x3A3 and prev_cased and !nextCased(text, i)) m[0] = 0x3C2;
                if (cp == 0x130) {
                    m = .{ 'i', 0x307, 0 };
                    n = 2;
                }
            },
            .capitalize => {
                const wordy = struct {
                    fn f(c: u21) bool {
                        // letters and digits (non-ASCII: anything outside the punctuation / symbol blocks)
                        if (isCased(c) or (c >= 0x30 and c <= 0x39)) return true;
                        return c >= 0xC0 and c != 0xD7 and c != 0xF7 and !(c >= 0x2000 and c <= 0x2BFF) and !(c >= 0x3000 and c <= 0x303F) and !(c >= 0xFE10 and c <= 0xFE6F) and !(c >= 0xFF00 and c <= 0xFF20);
                    }
                }.f;
                const mid = prev == 0x27 or prev == 0x2019 or prev == 0x2E or prev == 0x3A or prev == 0xB7;
                word_start = !(wordy(prev) or (mid and wordy(prev2)));
                if (word_start) m[0] = titleCase(cp);
            },
            else => {},
        }
        if (!isCaseIgnorable(cp)) prev_cased = isCased(cp);
        prev2 = prev;
        prev = cp;
        for (m[0..n]) |original| {
            var c = original;
            const variants = @import("font/character_variants.zig");
            if (@backingInt(tt) & 4 != 0) c = if (c == ' ' and preserve_spaces) 0x3000 else variants.fullWidth(c);
            if (@backingInt(tt) & 8 != 0) c = variants.fullSizeKana(c);
            var buf: [4]u8 = undefined;
            const len = json.encodeUtf8(c, &buf);
            try out.appendSlice(a, buf[0..len]);
        }
    }
    return out.items;
}

test "text variants: compose case, width and kana while respecting preserved spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("ＡＢＳＳ", try transformText(a, "abß", @fromBackingInt(5), false));
    try std.testing.expectEqualStrings("ａ ｂ", try transformText(a, "a b", .full_width, false));
    try std.testing.expectEqualStrings("ａ　ｂ", try transformText(a, "a b", .full_width, true));
    try std.testing.expectEqualStrings("アイカ", try transformText(a, "ｧｨｶ", @fromBackingInt(12), false));
    try std.testing.expectEqualStrings("あいかアイカ", try transformText(a, "ぁぃゕァィヵ", .full_size_kana, false));
}

// ---- ComputedStyle -> layout.Style

// Non-linear math (`min()/max()/clamp()` mixing % and lengths, `lp.isCalc()`) has no layout
// representation: such values degrade to their value at a reference of 0.

fn dimLp(lp: style.LP) layout.Dim {
    if (lp.isCalc()) return .{ .px = lp.resolve(0) };
    if (lp.pct == 0) return .{ .px = lp.px };
    if (lp.px == 0) return .{ .percent = lp.pct };
    return .{ .calc = .{ .px = lp.px, .percent = lp.pct } };
}

fn dimSize(s: style.Size) layout.Dim {
    return switch (s) {
        .lp => |lp| dimLp(lp),
        .min_content => .min_content,
        .max_content => .max_content,
        // fit-content(<limit>): the layout keyword has no limit, see mapStyle
        .fit_content, .fit_content_lp => .fit_content,
        else => .auto,
    };
}

fn dimAuto(s: style.LengthAuto) layout.Dim {
    return switch (s) {
        .auto => .auto,
        .lp => |lp| dimLp(lp),
    };
}

fn lpOf(lp: style.LP) layout.LengthPercentage {
    if (lp.isCalc()) return .{ .px = lp.resolve(0) };
    if (lp.pct == 0) return .{ .px = lp.px };
    if (lp.px == 0) return .{ .percent = lp.pct };
    return .{ .calc = .{ .px = lp.px, .percent = lp.pct } };
}

fn alignOf(al: style.Align) ?layout.Align {
    return switch (al) {
        .normal, .auto => null,
        .stretch => .stretch,
        .start, .self_start, .left => .start,
        .end, .self_end, .right => .end,
        .flex_start => .flex_start,
        .flex_end => .flex_end,
        .center => .center,
        .baseline, .last_baseline => .baseline,
        .space_between => .space_between,
        .space_around => .space_around,
        .space_evenly => .space_evenly,
    };
}

fn breadth(t: style.TrackSize) layout.TrackBreadth {
    return switch (t) {
        .auto => .auto,
        .lp => |lp| if (lp.isCalc()) .{ .px = lp.resolve(0) } else if (lp.pct == 0) .{ .px = lp.px } else .{ .percent = lp.pct },
        .fr => |v| .{ .fr = v },
        .min_content => .min_content,
        .max_content => .max_content,
        .fit_content => |lp| .{ .fit_content = lpOf(lp) },
    };
}

fn tracks(f: *Frame, src: []const style.Track) []const layout.Track {
    if (src.len == 0) return &.{};
    const out = f.a.alloc(layout.Track, src.len) catch return &.{};
    for (src, 0..) |t, i| out[i] = .{ .min = breadth(t.min), .max = breadth(t.max) };
    return out;
}

fn template(f: *Frame, t: style.GridTemplate, list: *[]const layout.Track, rep: *?layout.AutoRepeat) void {
    const all = tracks(f, t.tracks);
    if (t.auto_repeat == .none or t.auto_repeat_len == 0 or @as(usize, t.auto_repeat_start) + t.auto_repeat_len > all.len) {
        list.* = all;
        return;
    }
    const s: usize = t.auto_repeat_start;
    const e: usize = s + t.auto_repeat_len;
    const rest = f.a.alloc(layout.Track, all.len - t.auto_repeat_len) catch return;
    @memcpy(rest[0..s], all[0..s]);
    @memcpy(rest[s..], all[e..]);
    list.* = rest;
    rep.* = .{ .fit = t.auto_repeat == .fit, .tracks = all[s..e], .at = @intCast(s) };
}

fn gridLine(g: style.GridLine) layout.Line {
    return switch (g) {
        .auto => .auto,
        .line => |v| .{ .line = @intCast(std.math.clamp(v, -30000, 30000)) },
        .span => |v| .{ .span = @intCast(@min(v, 30000)) },
    };
}

fn mapStyle(f: *Frame, cs: *const CS) layout.Style {
    var s: layout.Style = .{};
    const tables = config.enable_tables;
    s.display = switch (cs.display) {
        .none => .none,
        .flex, .inline_flex => .flex,
        .grid, .inline_grid => .grid,
        .table => if (tables) .table else .block,
        .inline_table => if (tables) .inline_table else .block,
        .table_row_group => if (tables) .table_row_group else .block,
        .table_header_group => if (tables) .table_header_group else .block,
        .table_footer_group => if (tables) .table_footer_group else .block,
        .table_row => if (tables) .table_row else .block,
        .table_cell => if (tables) .table_cell else .block,
        .table_caption => if (tables) .table_caption else .block,
        .table_column => if (tables) .table_column else .block,
        .table_column_group => if (tables) .table_column_group else .block,
        else => .block,
    };
    // inline-block / flow-root establish an independent formatting context
    s.flow_root = cs.display == .flow_root or cs.display == .inline_block;
    if (comptime config.enable_floats) if (cs.position != .absolute and cs.position != .fixed) {
        const rtl = cs.direction == .rtl;
        s.float = switch (cs.float) {
            .none => .none,
            .left => .left,
            .right => .right,
            .inline_start => if (rtl) .right else .left,
            .inline_end => if (rtl) .left else .right,
        };
        s.clear = switch (cs.clear) {
            .none => .none,
            .left => .left,
            .right => .right,
            .both => .both,
            .inline_start => if (rtl) .right else .left,
            .inline_end => if (rtl) .left else .right,
        };
    };
    // (sub / super / text-top / text-bottom / <length> are not supported by the layout engine)
    s.vertical_align = switch (cs.vertical_align) {
        .top => .top,
        .middle => .middle,
        .bottom => .bottom,
        else => .baseline,
    };
    if (s.display.isTablePart() or s.display.isTable()) {
        // inherited in CSS, per node in the layout engine
        s.border_spacing = cs.border_spacing;
        s.border_collapse = cs.border_collapse == .collapse;
        s.caption_bottom = cs.caption_side == .bottom;
        s.table_fixed = cs.table_layout == .fixed;
    }
    s.position = switch (cs.position) {
        .static => .static,
        .relative, .sticky => .relative,
        .absolute => .absolute,
        .fixed => .fixed,
    };
    s.box_sizing = if (cs.box_sizing == .border_box) .border_box else .content_box;
    s.order = cs.order;
    s.visibility_collapse = cs.visibility == .collapse;
    s.overflow_x = mapOverflow(cs.overflow_x);
    s.overflow_y = mapOverflow(cs.overflow_y);
    // inset properties do not apply to position: static
    if (cs.position != .static) s.inset = .{ .top = dimAuto(cs.inset[0]), .right = dimAuto(cs.inset[1]), .bottom = dimAuto(cs.inset[2]), .left = dimAuto(cs.inset[3]) };
    s.size = .{ dimSize(cs.width), dimSize(cs.height) };
    s.min_size = .{ dimSize(cs.min_width), dimSize(cs.min_height) };
    s.max_size = .{ dimSize(cs.max_width), dimSize(cs.max_height) };
    // fit-content(L) = min(max-content, max(min-content, L)), approximated as fit-content capped by
    // max-size L (the min-content floor is lost when L is smaller)
    if (cs.width == .fit_content_lp and s.max_size[0] == .auto) s.max_size[0] = dimLp(cs.width.fit_content_lp);
    if (cs.height == .fit_content_lp and s.max_size[1] == .auto) s.max_size[1] = dimLp(cs.height.fit_content_lp);
    s.aspect_ratio = cs.aspect_ratio;
    s.margin = .{ .top = dimAuto(cs.margin[0]), .right = dimAuto(cs.margin[1]), .bottom = dimAuto(cs.margin[2]), .left = dimAuto(cs.margin[3]) };
    s.padding = .{ .top = lpOf(cs.padding[0]), .right = lpOf(cs.padding[1]), .bottom = lpOf(cs.padding[2]), .left = lpOf(cs.padding[3]) };
    const bw = cs.usedBorderWidths();
    s.border = .{ .top = bw[0], .right = bw[1], .bottom = bw[2], .left = bw[3] };
    if (@hasField(layout.Style, "border_hidden")) {
        s.border_hidden = .{ .top = cs.border_style[0] == .hidden, .right = cs.border_style[1] == .hidden, .bottom = cs.border_style[2] == .hidden, .left = cs.border_style[3] == .hidden };
    }
    if (@hasDecl(CS, "alignSafe")) s.safe = @bitCast(cs.alignSafe());
    s.gap = .{ lpOf(cs.column_gap), lpOf(cs.row_gap) };
    s.flex_direction = switch (cs.flex_direction) {
        .row => .row,
        .row_reverse => .row_reverse,
        .column => .column,
        .column_reverse => .column_reverse,
    };
    s.flex_wrap = switch (cs.flex_wrap) {
        .nowrap => .nowrap,
        .wrap => .wrap,
        .wrap_reverse => .wrap_reverse,
    };
    s.flex_grow = cs.flex_grow;
    s.flex_shrink = cs.flex_shrink;
    s.flex_basis = switch (cs.flex_basis) {
        .lp => |lp| dimLp(lp),
        .min_content => .min_content,
        .max_content => .max_content,
        .fit_content => .fit_content,
        else => .auto,
    };
    s.align_items = alignOf(cs.align_items);
    s.align_self = alignOf(cs.align_self);
    s.align_content = alignOf(cs.align_content);
    s.justify_content = alignOf(cs.justify_content);
    s.justify_items = alignOf(cs.justify_items);
    s.justify_self = alignOf(cs.justify_self);
    if (cs.direction == .rtl) {
        s.rtl = true;
        // (`left` / `right` are physical: start is the right edge here)
        if (cs.justify_content == .left or cs.justify_content == .right) s.justify_content = if (cs.justify_content == .left) .end else .start;
        if (cs.justify_items == .left or cs.justify_items == .right) s.justify_items = if (cs.justify_items == .left) .end else .start;
    }
    if (s.display == .grid) {
        template(f, cs.grid_template_columns, &s.grid_template_columns, &s.grid_auto_repeat_columns);
        template(f, cs.grid_template_rows, &s.grid_template_rows, &s.grid_auto_repeat_rows);
        s.grid_auto_columns = tracks(f, cs.grid_auto_columns);
        s.grid_auto_rows = tracks(f, cs.grid_auto_rows);
        // grid-template-areas also sizes the explicit grid; the extra tracks are sized by grid-auto-*
        const ar = cs.grid_template_areas;
        padTracks(f, &s.grid_template_columns, ar.cols, s.grid_auto_columns, cs.grid_template_columns);
        padTracks(f, &s.grid_template_rows, ar.rows, s.grid_auto_rows, cs.grid_template_rows);
        s.grid_auto_flow = if (cs.grid_auto_flow.column) (if (cs.grid_auto_flow.dense) .column_dense else .column) else (if (cs.grid_auto_flow.dense) .row_dense else .row);
    }
    s.grid_column = .{ .start = gridLine(cs.grid_column_start), .end = gridLine(cs.grid_column_end) };
    s.grid_row = .{ .start = gridLine(cs.grid_row_start), .end = gridLine(cs.grid_row_end) };
    if (comptime layout.fragment.enabled) s.breaks = .{
        .before = breakBetween(cs.break_before),
        .after = breakBetween(cs.break_after),
        .avoid_inside = cs.break_inside.avoidsPage(),
        .clone = cs.box_decoration_break == .clone,
        // (takumi-core `is_monolithic`: a `line-clamp` box; replaced elements: `layoutNode`)
        .monolithic = cs.line_clamp > 0,
        .widows = @max(cs.widows, 1),
        .orphans = @max(cs.orphans, 1),
    };
    return s;
}

/// `break-before` / `break-after` for the fragmentation pass (avoid-column -> auto).
fn breakBetween(b: style.computed.BreakBetween) layout.BreakBetween {
    if (b.forcesPage()) return .page;
    if (b.avoidsPage()) return .avoid;
    return if (b == .column) .column else .auto;
}

/// grid-template-areas larger than the track list: the extra explicit tracks take grid-auto-* sizes.
fn padTracks(f: *Frame, list: *[]const layout.Track, want: u16, auto: []const layout.Track, t: style.computed.GridTemplate) void {
    if (t.auto_repeat != .none or want <= list.len) return;
    const out = f.a.alloc(layout.Track, want) catch return;
    @memcpy(out[0..list.len], list.*);
    for (out[list.len..], 0..) |*o, k| o.* = if (auto.len > 0) auto[k % auto.len] else .auto;
    list.* = out;
}

// ---- anonymous line containers

/// Font metrics in em: ascent, descent (positive down), line gap, x-height.
pub const EmMetrics = struct { ascent: f32, descent: f32, gap: f32, x_height: f32 };
/// Geist (takumi's bundled default font): the strut font when no font is registered.
pub const geist_em: EmMetrics = .{ .ascent = 1.005, .descent = 0.295, .gap = 0, .x_height = 0.53 };

/// Strut of a line container (Blink): A, D, G = ascent / descent / line gap of the primary font at
/// `size`, each rounded to whole px; L = line-height (normal = A + D + G); half-leading
/// floor((L - (A + D)) / 2) goes above. Returns [strut ascent, strut descent (may be negative),
/// distance from the baseline to the `vertical-align: middle` line (half the x-height)].
pub fn strutFrom(m: EmMetrics, size: f32, lh: style.computed.LineHeight) [3]f32 {
    const a = @round(m.ascent * size);
    const d = @round(m.descent * size);
    const g = @round(m.gap * size);
    const l: f32 = switch (lh) {
        .normal => a + d + g,
        .number => |k| @floor(k * size * 64) / 64,
        .px => |p| @floor(p * 64) / 64,
    };
    const asc = a + @floor((l - (a + d)) / 2);
    return .{ asc, l - asc, m.x_height * size / 2 };
}

/// Metrics of the primary font of `cs` (first face the font matcher returns), Geist's without fonts.
pub fn emMetrics(fonts: *const font.FontCollection, cs: *const CS) EmMetrics {
    var buf: [4]font.FaceId = undefined;
    const faces = fonts.match(cs.font_family, cs.font_weight, cs.font_style != .normal, &buf);
    if (faces.len == 0) return geist_em;
    const fo = fonts.font(faces[0]);
    const lm = fo.lineMetrics();
    const upm: f32 = @floatFromInt(@max(fo.units_per_em, 1));
    const asc = @as(f32, @floatFromInt(lm.ascent)) / upm;
    const xh = fo.xHeight();
    return .{
        .ascent = asc,
        .descent = @as(f32, @floatFromInt(lm.descent)) / upm,
        .gap = @as(f32, @floatFromInt(lm.leading)) / upm,
        // (Blink's fallback without an OS/2 x-height)
        .x_height = if (xh > 0) @as(f32, @floatFromInt(xh)) / upm else asc * 0.56,
    };
}

// ---- tables

/// HTML "rules for parsing non-negative integers", saturating (Blink's ParseHTMLClampedNonNegativeInteger).
fn parseSpanAttr(v: []const u8) ?u32 {
    var i: usize = 0;
    while (i < v.len and (v[i] == ' ' or v[i] == '\t' or v[i] == '\n' or v[i] == '\r' or v[i] == 0x0c)) i += 1;
    if (i < v.len and v[i] == '+') i += 1;
    var n: u32 = 0;
    var digits = false;
    while (i < v.len and v[i] >= '0' and v[i] <= '9') : (i += 1) {
        digits = true;
        n = @min(n *| 10 +| (v[i] - '0'), 1 << 30);
    }
    return if (digits) n else null;
}

/// takumi (`table/parts.rs`): `colspan` (1..1000) / `rowspan` (0..65534, 0 = every remaining row)
/// attributes of a `td` / `th` element, `span` (1..1000) of a `col` / `colgroup` element.
fn tableSpans(d: *const dom_mod.Dom, i: u32, st: *layout.Style) void {
    const tag = d.at(i).tag;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(tag, "td") or eq(tag, "th")) {
        if (d.attr(i, "colspan")) |v| if (parseSpanAttr(v)) |n| {
            st.col_span = @intCast(std.math.clamp(n, 1, 1000));
        };
        if (d.attr(i, "rowspan")) |v| if (parseSpanAttr(v)) |n| {
            st.row_span = if (n == 0) 65534 else @intCast(@min(n, 65534));
        };
    } else if (eq(tag, "col") or eq(tag, "colgroup")) {
        if (d.attr(i, "span")) |v| if (parseSpanAttr(v)) |n| {
            st.col_span = @intCast(std.math.clamp(n, 1, 1000));
        };
    }
}

// ---- named grid lines / areas

/// x == a ++ b
fn eqlCat(x: []const u8, a: []const u8, b: []const u8) bool {
    return x.len == a.len + b.len and std.mem.startsWith(u8, x, a) and std.mem.endsWith(u8, x, b);
}

/// a1 ++ a2 == b1 ++ b2
fn eqlCat2(a1: []const u8, a2: []const u8, b1: []const u8, b2: []const u8) bool {
    if (a1.len + a2.len != b1.len + b2.len) return false;
    var i: usize = 0;
    while (i < a1.len + a2.len) : (i += 1) {
        const x = if (i < a1.len) a1[i] else a2[i - a1.len];
        const y = if (i < b1.len) b1[i] else b2[i - b1.len];
        if (x != y) return false;
    }
    return true;
}

/// Number of explicit grid lines of an axis (template tracks, an auto-repeat group counted once, or
/// the rows / columns of grid-template-areas).
fn explicitLines(c: *const CS, col: bool) i32 {
    const t = if (col) c.grid_template_columns else c.grid_template_rows;
    const ar = if (col) c.grid_template_areas.cols else c.grid_template_areas.rows;
    return @as(i32, @intCast(@max(t.tracks.len, ar) & 0xffff)) + 1;
}

/// Sorted 1-based lines of an axis named `base ++ suffix`: names in the track list (lines inside an
/// auto-repeat group counted for one repetition) and the `<area>-start` / `<area>-end` lines that
/// grid-template-areas defines.
fn namedLines(c: *const CS, col: bool, base: []const u8, suffix: []const u8, buf: []i32) []i32 {
    var n: usize = 0;
    const t = if (col) c.grid_template_columns else c.grid_template_rows;
    for (t.line_names) |ln| {
        if (n == buf.len) break;
        if (!eqlCat(ln.name, base, suffix)) continue;
        buf[n] = @as(i32, ln.line) + 1 + (if (ln.in_repeat) @as(i32, t.auto_repeat_start) else 0);
        n += 1;
    }
    for (c.grid_template_areas.areas) |ar| {
        if (n + 2 > buf.len) break;
        if (eqlCat2(ar.name, "-start", base, suffix)) {
            buf[n] = @as(i32, if (col) ar.col_start else ar.row_start) + 1;
            n += 1;
        }
        if (eqlCat2(ar.name, "-end", base, suffix)) {
            buf[n] = @as(i32, if (col) ar.col_end else ar.row_end) + 1;
            n += 1;
        }
    }
    // sort + dedupe
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const x = buf[i];
        var j = i;
        while (j > 0 and buf[j - 1] > x) : (j -= 1) buf[j] = buf[j - 1];
        buf[j] = x;
    }
    var m: usize = 0;
    for (buf[0..n]) |x| {
        if (m > 0 and buf[m - 1] == x) continue;
        buf[m] = x;
        m += 1;
    }
    return buf[0..m];
}

/// Line of a `[<integer>] <name>` reference (CSS Grid §8.3.1): a lone name first looks for
/// `<name>-start` / `<name>-end`; the n-th line with the name (negative n counts from the end);
/// past the named lines the implicit lines count as named, so an unknown name is the first implicit
/// line after the explicit grid (EMPIRICAL, takumi). null only for n = 0.
/// (takumi's parser rejects the `<integer> <name>` forms; the style module accepts them, resolved per CSS.)
fn namedLine(c: *const CS, col: bool, name: []const u8, n: i32, is_end: bool, lines_n: i32) ?i32 {
    var buf: [64]i32 = undefined;
    if (n == 1) {
        const l = namedLines(c, col, name, if (is_end) "-end" else "-start", &buf);
        if (l.len > 0) return l[0];
    }
    const l = namedLines(c, col, name, "", &buf);
    if (n == 0) return null;
    const cnt: i32 = @intCast(l.len);
    if (n > 0) return if (n <= cnt) l[@intCast(n - 1)] else lines_n + (n - cnt);
    const k = -n;
    return if (k <= cnt) l[@intCast(cnt - k)] else 1 - (k - cnt);
}

/// Absolute line number -> layout line (1-based; lines before the first explicit line counted from
/// the end of the explicit grid).
fn toLine(v: i32, lines_n: i32) layout.Line {
    const x = if (v >= 1) v else v - lines_n - 1;
    return .{ .line = @intCast(std.math.clamp(x, -30000, 30000)) };
}

/// Resolves the named references of one axis of a grid item (`sref` / `eref` = start / end).
fn resolveNamed(c: *const CS, col: bool, sref: style.computed.GridLineRef, eref: style.computed.GridLineRef, cur: layout.Placement) layout.Placement {
    const ln = explicitLines(c, col);
    var p = cur;
    if (sref.name.len > 0 and !sref.span) p.start = if (namedLine(c, col, sref.name, sref.n, false, ln)) |v| toLine(v, ln) else .auto;
    if (eref.name.len > 0 and !eref.span) p.end = if (namedLine(c, col, eref.name, eref.n, true, ln)) |v| toLine(v, ln) else .auto;
    // `span <name>` is `span 1` in takumi (EMPIRICAL, probe/layout2/gridnames.mjs; CSS counts named lines)
    if (sref.name.len > 0 and sref.span) p.start = .{ .span = 1 };
    if (eref.name.len > 0 and eref.span) p.end = if (p.start == .span) .auto else .{ .span = 1 };
    return p;
}

/// Named lines / areas of grid item `item` resolved against its container `c`.
fn gridNames(c: *const CS, item: *const CS, st: *layout.Style) void {
    const r = item.grid_line_names; // row start, column start, row end, column end
    if (r[0].name.len > 0 or r[2].name.len > 0) st.grid_row = resolveNamed(c, false, r[0], r[2], st.grid_row);
    if (r[1].name.len > 0 or r[3].name.len > 0) st.grid_column = resolveNamed(c, true, r[1], r[3], st.grid_column);
}

fn mapOverflow(o: anytype) layout.style.Overflow {
    return switch (o) {
        .visible => .visible,
        .hidden => .hidden,
        .clip => .clip,
        .scroll, .auto => .scroll,
    };
}

test "writeNum" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try writeNum(a, &out, 12.5);
    try out.append(a, ' ');
    try writeNum(a, &out, -0.015625);
    try out.append(a, ' ');
    try writeNum(a, &out, 300);
    try std.testing.expectEqualStrings("12.5 -0.015625 300", out.items);
}

fn testRender(node: []const u8, opts: []const u8) !void {
    const gpa = std.testing.allocator;
    const r = Renderer.create(gpa).?;
    defer r.destroy();
    const font_bytes = @embedFile("font/testdata/Inter-Regular.ttf");
    _ = try r.registerFont(try gpa.dupe(u8, font_bytes), "", 0, -1, null);
    _ = r.render(node, opts) catch |e| switch (e) {
        error.Invalid => {},
        else => return e,
    };
}

test "regression: text shifted above the canvas by a relative offset" {
    const node = "{\"type\":\"container\",\"style\":{},\"children\":[{\"type\":\"container\",\"style\":{\"borderTop\":\"6px solid green\"},\"children\":[{\"type\":\"container\",\"style\":{\"bottom\":20},\"children\":[{\"type\":\"container\",\"style\":{},\"children\":[{\"type\":\"container\",\"style\":{},\"children\":[{\"type\":\"text\",\"text\":\"Xin ch\u{00e0}o Vi\u{1ec7}t Nam \u{2014} ti\u{1ebf}ng Vi\u{1ec7}t c\u{00f3} d\u{1ea5}u\",\"style\":{}}]},{\"type\":\"container\",\"style\":{},\"children\":[]}]}]}]}]}";
    try testRender(node, "{\"height\":1,\"format\":\"raw\"}");
}

// ---- front-end integration tests (cascade order, HTML mapping, generated content)

const TestFrame = struct {
    r: *Renderer,
    f: Frame,

    fn init(kind: SourceKind, src: []const u8, opts: []const u8) !*TestFrame {
        const gpa = std.testing.allocator;
        const r = Renderer.create(gpa).?;
        errdefer r.destroy();
        _ = try r.registerFont(try gpa.dupe(u8, @embedFile("font/testdata/Inter-Regular.ttf")), "", 0, -1, null);
        r.beginCall();
        const a = r.arena.allocator();
        const t = try a.create(TestFrame);
        t.r = r;
        t.f = .{ .r = r, .a = a, .opts = try r.parseOptions(opts), .tree = LTree.init(a), .ctx = undefined };
        t.f.prepare(kind, src) catch |e| {
            if (e == error.Invalid) std.debug.print("render error: {s}\n", .{r.err});
            return e;
        };
        return t;
    }
    fn deinit(t: *TestFrame) void {
        t.r.destroy();
    }
    fn el(t: *TestFrame, i: u32) *dom_mod.El {
        return t.f.dom.at(i);
    }
    /// First element with `id`.
    fn byId(t: *TestFrame, id: []const u8) *dom_mod.El {
        for (t.f.dom.els.items) |*e| if (std.mem.eql(u8, e.id, id)) return e;
        @panic("no such id");
    }
};

fn bgOf(cs: *const CS) style.Color {
    return switch (cs.background_color) {
        .rgba => |c| c,
        else => .{},
    };
}

fn pxOf(s: style.Size) f32 {
    return switch (s) {
        .lp => |lp| lp.px,
        else => -1,
    };
}

test "cascade order: preset < tw < stylesheet < inline style; !important reverses" {
    if (comptime !(config.enable_css and config.enable_tw)) return error.SkipZigTest;
    const t = try TestFrame.init(.json,
        \\{"type":"container","children":[
        \\ {"type":"container","id":"a","className":"x","tw":"bg-[#000001] w-[1px]",
        \\  "preset":{"backgroundColor":"#000002","width":2,"height":2,"opacity":0.5},"style":{"height":3}},
        \\ {"type":"container","id":"b","className":"x","style":{"height":"5px !important","backgroundColor":"#000009"}},
        \\ {"type":"container","id":"c","tw":"!w-[7px] h-[8px]","style":{"width":6,"height":9}},
        \\ {"type":"container","id":"d","className":"y bogus","style":{}}
        \\]}
    ,
        \\{"width":100,"height":100,"css":[".x{background-color:#000003;height:4px !important}",
        \\ {"selector":".y","style":{"width":"banana","height":"11px"}}]}
    );
    defer t.deinit();
    const a = t.byId("a").cs;
    try std.testing.expectEqual(@as(u8, 3), bgOf(a).b); // css beats tw beats preset
    try std.testing.expectEqual(@as(f32, 1), pxOf(a.width)); // tw beats preset
    try std.testing.expectEqual(@as(f32, 4), pxOf(a.height)); // css !important beats inline normal
    try std.testing.expectEqual(@as(f32, 0.5), a.opacity); // preset survives
    const b = t.byId("b").cs;
    try std.testing.expectEqual(@as(f32, 5), pxOf(b.height)); // inline !important beats css !important
    try std.testing.expectEqual(@as(u8, 9), bgOf(b).b); // inline normal beats css normal
    const c = t.byId("c").cs;
    try std.testing.expectEqual(@as(f32, 7), pxOf(c.width)); // tw !important beats inline normal
    try std.testing.expectEqual(@as(f32, 9), pxOf(c.height)); // inline beats tw
    const d = t.byId("d").cs;
    try std.testing.expectEqual(@as(f32, 11), pxOf(d.height)); // invalid rule value dropped alone (lenient)
    try std.testing.expect(d.width == .auto);
}

test "strict inline style still fails; tw / css / html never do" {
    const gpa = std.testing.allocator;
    const r = Renderer.create(gpa).?;
    defer r.destroy();
    try std.testing.expectError(error.Invalid, r.render("{\"type\":\"container\",\"style\":{\"width\":\"banana\"}}", "{\"width\":10,\"height\":10,\"format\":\"raw\"}"));
    try std.testing.expect(std.mem.indexOf(u8, r.err, "width") != null);
    _ = try r.render("{\"type\":\"container\",\"tw\":\"w-[banana] p-[1px_2px_3px_4px_5px]\",\"className\":\"q\"}", "{\"width\":10,\"height\":10,\"format\":\"raw\",\"css\":[\".q{width:banana}\"]}");
    if (comptime config.enable_html) _ = try r.renderSource(.html, "<div style=\"width:banana;height:5px\">x</div>", "{\"width\":10,\"height\":10,\"format\":\"raw\"}");
}

test "html -> elements: fragment collapse, document wrappers, presets, text elements" {
    if (comptime !config.enable_html) return error.SkipZigTest;
    {
        const t = try TestFrame.init(.html, "\n  <p id=\"p\">Hello <b>bold</b><br>x</p>\n  <h1 id=\"h\" style=\"color:#00ff00\">Title</h1><img src=\"\" width=\"10\" height=\"50%\"><style>.c{}</style>", "{\"width\":200,\"height\":100}");
        defer t.deinit();
        const root = t.el(t.f.dom.root);
        try std.testing.expect(root.tag.len == 0 and root.kind == .container); // several roots -> wrapper
        try std.testing.expect(root.style == .text);
        const p = t.byId("p");
        try std.testing.expectEqual(dom_mod.Kind.container, p.kind);
        try std.testing.expect(t.el(p.first).run); // "Hello "
        const h = t.byId("h");
        try std.testing.expectEqual(dom_mod.Kind.text, h.kind); // element holding only text
        try std.testing.expectEqualStrings("Title", h.text);
        try std.testing.expectEqual(@as(f32, 32), h.cs.font_size); // preset font-size: 2em
        try std.testing.expectEqual(@as(u16, 700), h.cs.font_weight);
        try std.testing.expectEqual(@as(u8, 255), h.cs.color.g); // style attribute
        try std.testing.expectEqual(style.Display.block, h.cs.display);
        // <br> is a text element "\n"; <img> an image with a px width preset and a % height hint
        var saw_br = false;
        var saw_img = false;
        for (t.f.dom.els.items) |*e| {
            if (std.mem.eql(u8, e.tag, "br")) saw_br = e.kind == .text and std.mem.eql(u8, e.text, "\n");
            if (std.mem.eql(u8, e.tag, "img")) {
                saw_img = e.kind == .image and e.width.? == 10 and e.height == null and std.mem.eql(u8, e.pres, "height:50%;");
            }
            try std.testing.expect(!std.mem.eql(u8, e.tag, "style")); // unrendered
        }
        try std.testing.expect(saw_br and saw_img);
        try std.testing.expectEqual(@as(usize, 1), t.f.dom.styles.len);
    }
    {
        const t = try TestFrame.init(.html, "<!doctype html><html lang=\"vi\"><body class=\"b\"><div>x</div></body></html>", "{\"width\":200,\"height\":100}");
        defer t.deinit();
        const root = t.el(t.f.dom.root);
        try std.testing.expectEqualStrings("html", root.tag);
        try std.testing.expectEqualStrings("vi", root.lang);
        const body = t.el(root.first);
        try std.testing.expectEqualStrings("body", body.tag);
        try std.testing.expectEqualStrings("b", body.class);
        try std.testing.expectEqual(@as(f32, 8), body.cs.margin[0].lp.px);
    }
    {
        const t = try TestFrame.init(.html, "  ", "{\"width\":20,\"height\":10}");
        defer t.deinit();
        try std.testing.expectEqual(@as(usize, 1), t.f.dom.els.items.len); // empty container
    }
}

test "pseudo-elements: ::before/::after from css and tw, content parsing, own text box" {
    if (comptime !(config.enable_css and config.enable_tw)) return error.SkipZigTest;
    const t = try TestFrame.init(.json,
        \\{"type":"container","children":[
        \\ {"type":"text","id":"t","className":"s","text":"mid","attributes":{"data-n":"7"}},
        \\ {"type":"container","id":"c","className":"s"},
        \\ {"type":"container","id":"n","className":"none"},
        \\ {"type":"image","id":"i","className":"s","src":"x"},
        \\ {"type":"container","id":"w","tw":"after:content-['tw'] after:text-[#ff0000]"}
        \\]}
    ,
        \\{"width":100,"height":100,"css":[".s::before{content:'<' attr(data-n);color:#0000ff}.s::after{content:\">\";display:block} .none::before{content:none}"]}
    );
    defer t.deinit();
    const tx = t.byId("t");
    try std.testing.expect(tx.before != none and tx.after != none and tx.own != none);
    try std.testing.expectEqualStrings("<7", t.f.pseudos.items[tx.before].text);
    try std.testing.expectEqual(@as(u8, 255), t.f.pseudos.items[tx.before].cs.color.b);
    try std.testing.expectEqualStrings(">", t.f.pseudos.items[tx.after].text);
    try std.testing.expectEqual(style.Display.block, t.f.pseudos.items[tx.after].cs.display);
    try std.testing.expectEqualStrings("mid", t.f.pseudos.items[tx.own].text);
    const c = t.byId("c");
    try std.testing.expectEqualStrings("<", t.f.pseudos.items[c.before].text);
    try std.testing.expect(t.byId("n").before == none); // content: none
    try std.testing.expect(t.byId("i").before == none); // never for images
    const w = t.byId("w");
    try std.testing.expect(w.before == none and w.after != none);
    try std.testing.expectEqualStrings("tw", t.f.pseudos.items[w.after].text);
    try std.testing.expectEqual(@as(u8, 255), t.f.pseudos.items[w.after].cs.color.r);
    // render nodes: text element "t" is an inline box of the root's paragraph (before + own text); its
    // block ::after splits that paragraph (block-in-inline) and is a child of the root
    for (t.f.nodes.items) |n| try std.testing.expect(n.cs != tx.cs);
    const first = t.f.nodes.items[t.f.root].first_child;
    try std.testing.expectEqual(Kind.anon_text, t.f.nodes.items[first].kind);
    try std.testing.expect(t.f.nodes.items[first].ifc_part);
    const second = t.f.nodes.items[first].next;
    try std.testing.expectEqual(Kind.text, t.f.nodes.items[second].kind);
    try std.testing.expect(t.f.nodes.items[second].bii and t.f.nodes.items[second].cs == t.f.pseudos.items[tx.after].cs);
}

test "stylesheet selectors see takumi's element tree; options" {
    if (comptime !config.enable_css) return error.SkipZigTest;
    const t = try TestFrame.init(.json,
        \\{"type":"container","children":[
        \\ {"type":"text","id":"t1","className":"i","text":"a"},
        \\ {"type":"container","id":"c1","className":"i"},
        \\ {"type":"container","id":"c2","className":"i","tagName":"section","lang":"vi"}
        \\]}
    ,
        \\{"width":100,"height":100,"lang":"en","fontFamilies":["Inter"],"timeMs":5,
        \\ "css":[".i:first-child{opacity:0.5} section:last-child{opacity:0.25} :root:lang(en){opacity:0.75} :lang(vi){order:3}"]}
    );
    defer t.deinit();
    try std.testing.expectEqual(@as(f32, 0.5), t.byId("t1").cs.opacity); // untagged text: its own first child
    try std.testing.expectEqual(@as(f32, 0.5), t.byId("c1").cs.opacity); // text sibling skipped
    try std.testing.expectEqual(@as(f32, 0.25), t.byId("c2").cs.opacity);
    try std.testing.expectEqual(@as(i32, 3), t.byId("c2").cs.order);
    try std.testing.expectEqual(@as(f32, 0.75), t.el(t.f.dom.root).cs.opacity); // `lang` option on the root
    try std.testing.expectEqualStrings("Inter", t.el(t.f.dom.root).cs.font_family[0]);
    try std.testing.expectEqual(@as(f32, 5), t.f.opts.time_ms);
}

test "keyframes option is parsed and exposed" {
    if (comptime !config.enable_css) return error.SkipZigTest;
    const t = try TestFrame.init(.json, "{\"type\":\"container\"}",
        \\{"width":10,"height":10,"keyframes":{"spin":{"from":{"opacity":0},"to":{"opacity":1}}},
        \\ "css":["@keyframes fade{0%{opacity:0}100%{opacity:1}}"]}
    );
    defer t.deinit();
    try std.testing.expect(t.f.keyframes("spin") != null);
    try std.testing.expect(t.f.keyframes("fade") != null);
    try std.testing.expect(t.f.keyframes("nope") == null);
}

test "animation layering at timeMs: keyframe layer, missing 100%, two animations, inheritance" {
    if (comptime !(config.enable_css and config.enable_animation)) return error.SkipZigTest;
    const t = try TestFrame.init(.json,
        \\{"type":"container","id":"p","className":"p","children":[
        \\ {"type":"container","id":"a","className":"a","style":{"opacity":0.5,"width":"10px !important"}},
        \\ {"type":"container","id":"c"}]}
    ,
        \\{"width":100,"height":100,"timeMs":250,"css":[
        \\ "@keyframes w{from{width:0px}to{width:100px}} @keyframes o{50%{opacity:1}}",
        \\ "@keyframes w2{from{width:200px}to{width:400px}} @keyframes col{from{color:#000000}to{color:#ff0000}}",
        \\ ".a{animation:w 1000ms linear, o 1000ms linear, w2 1000ms linear 500ms} .p{animation:col 500ms linear}"]}
    );
    defer t.deinit();
    const a = t.byId("a").cs;
    // keyframes beat `!important` inline; w2 (delay 500ms, fill none) has no effect yet
    try std.testing.expectApproxEqAbs(@as(f32, 25), pxOf(a.width), 0.01);
    // no 0% / 100% keyframes: 0.5 -> 1 over the first half
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), a.opacity, 0.001);
    // the parent's animated colour is inherited by the children
    const pc = t.byId("p").cs.color;
    try std.testing.expect(pc.r > 120 and pc.r < 135);
    try std.testing.expectEqual(pc.r, t.byId("c").cs.color.r);
    try std.testing.expectEqual(pc.r, a.color.r);
}

test "animation: later animation wins per property; default timeMs is 0 with backwards fill" {
    if (comptime !(config.enable_css and config.enable_animation)) return error.SkipZigTest;
    {
        const t = try TestFrame.init(.json, "{\"type\":\"container\",\"id\":\"a\",\"className\":\"a\"}",
            \\{"width":10,"height":10,"timeMs":750,"css":["@keyframes w{to{width:100px}} @keyframes w2{from{width:200px}to{width:400px}}",
            \\ ".a{width:0px;animation:w 1000ms linear, w2 1000ms linear 500ms}"]}
        );
        defer t.deinit();
        try std.testing.expectApproxEqAbs(@as(f32, 250), pxOf(t.byId("a").cs.width), 0.01);
    }
    {
        const t = try TestFrame.init(.json, "{\"type\":\"container\",\"id\":\"a\",\"className\":\"a\"}",
            \\{"width":10,"height":10,"css":["@keyframes f{from{opacity:0.2}to{opacity:1}} .a{animation:f 1s linear 1s backwards}"]}
        );
        defer t.deinit();
        try std.testing.expectApproxEqAbs(@as(f32, 0.2), t.byId("a").cs.opacity, 0.001);
    }
}

test "svg intrinsic size mapping (takumi probe values)" {
    const S = SvgSize;
    const eq = struct {
        fn f(want: S, got: S) !void {
            try std.testing.expectApproxEqAbs(want.w, got.w, 0.001);
            try std.testing.expectApproxEqAbs(want.h, got.h, 0.001);
            try std.testing.expectApproxEqAbs(want.ratio, got.ratio, 0.001);
        }
    }.f;
    const vb: [4]f32 = .{ 0, 0, 40, 20 };
    try eq(.{ .w = 40, .h = 20, .ratio = 2 }, svgSizeFrom(40, 20, null, 1));
    try eq(.{ .w = 0, .h = 0, .ratio = 2 }, svgSizeFrom(null, null, vb, 1));
    try eq(.{ .w = 80, .h = 40, .ratio = 2 }, svgSizeFrom(40, null, vb, 2));
    try eq(.{ .w = 80, .h = 40, .ratio = 2 }, svgSizeFrom(null, 40, vb, 1));
    try eq(.{ .w = 300, .h = 150, .ratio = 0 }, svgSizeFrom(null, null, null, 1));
    try eq(.{ .w = 600, .h = 60, .ratio = 0 }, svgSizeFrom(null, 30, null, 2));
    try eq(.{ .w = 40, .h = 150, .ratio = 0 }, svgSizeFrom(40, null, null, 1));
    try std.testing.expectEqual(@as(?f32, 24), svgLength("2em"));
    try std.testing.expectEqual(@as(?f32, 24), svgLength(" 2rem "));
    try std.testing.expectEqual(@as(?f32, 12), svgLength("2ex"));
    try std.testing.expectEqual(@as(?f32, 96), svgLength("1in"));
    try std.testing.expectEqual(@as(?f32, 40), svgLength("40px"));
    try std.testing.expectEqual(@as(?f32, null), svgLength("50%"));
    try std.testing.expectEqual(@as(?f32, null), svgLength("0"));
    try std.testing.expectEqual(@as(?f32, null), svgLength(null));
}

test "registerFont: unreadable sfnt fonts register as a family drawing nothing; non-fonts fail as takumi words it" {
    const gpa = std.testing.allocator;
    const r = Renderer.create(gpa).?;
    defer r.destroy();
    const inter = @embedFile("font/testdata/Inter-Regular.ttf");
    // truncated: the table directory reads, the tables do not
    _ = try r.registerFont(try gpa.dupe(u8, inter[0..4000]), "Broken", 0, -1, null);
    var out: [8]font.FaceId = undefined;
    const order = r.fonts.match(&.{"Broken"}, 400, false, &out);
    try std.testing.expectEqualStrings("Broken", r.fonts.face(order[0]).family);
    try std.testing.expect(!r.fonts.allows(order[0], 'H'));
    // unnamed, it has no family to stand for
    try std.testing.expectError(error.Invalid, r.registerFont(try gpa.dupe(u8, inter[0..4000]), "", 0, -1, null));
    try std.testing.expectEqualStrings("invalid font data", r.err);
    // bytes that are no font file at all
    try std.testing.expectError(error.Invalid, r.registerFont(try gpa.dupe(u8, "garbage!"), "X", 0, -1, null));
    try std.testing.expectEqualStrings("Unsupported font format", r.err);
}

test "data: URI decoding (base64, percent-encoded, malformed escapes)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("<svg a=\"1\">", decodeDataUri(a, "data:image/svg+xml,%3Csvg%20a=%221%22%3E").?);
    try std.testing.expectEqualStrings("<svg>", decodeDataUri(a, "data:image/svg+xml;utf8,<svg>").?);
    try std.testing.expectEqualStrings("100%zz%4", decodeDataUri(a, "data:text/plain,100%25zz%4").?);
    try std.testing.expectEqualStrings("<svg/>", decodeDataUri(a, "data:image/svg+xml;BASE64,PHN2Zy8+").?);
    try std.testing.expect(decodeDataUri(a, "data:nocomma") == null);
    // whitespace, padding and URL-safe digits inside the payload are skipped / accepted
    try std.testing.expectEqualStrings("<svg/>", decodeDataUri(a, "data:x;base64,PH N2\nZy8+").?);
    try std.testing.expectEqualStrings("ab", decodeDataUri(a, "data:x;base64,YW I=").?);
    try std.testing.expectEqualStrings("\xfb\xff", decodeDataUri(a, "data:x;base64,-_8").?);
    var prng = std.Random.DefaultPrng.init(7);
    for (0..200) |k| {
        var raw: [97]u8 = undefined;
        prng.random().bytes(&raw);
        const len = k % raw.len;
        var enc: [132]u8 = undefined;
        const e = std.base64.standard.Encoder.encode(&enc, raw[0..len]);
        const uri = try std.fmt.allocPrint(a, "data:x;base64,{s}", .{e});
        try std.testing.expectEqualSlices(u8, raw[0..len], decodeDataUri(a, uri).?);
    }
}

test "svg image sources: intrinsic size, inline markup, data URIs" {
    if (comptime !config.enable_svg) return error.SkipZigTest;
    const t = try TestFrame.init(.json,
        \\{"type":"container","style":{"display":"flex","alignItems":"flex-start"},"children":[
        \\ {"type":"image","src":"<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'/>"},
        \\ {"type":"image","src":"data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20height='10'%20viewBox='0%200%2040%2020'/%3E"},
        \\ {"type":"image","src":"<svg xmlns='http://www.w3.org/2000/svg'/>"}]}
    , "{\"width\":400,\"height\":300,\"devicePixelRatio\":2}");
    defer t.deinit();
    var seen: usize = 0;
    for (t.f.nodes.items) |n| {
        if (n.kind != .image) continue;
        try std.testing.expect(n.svg != null and n.img == null);
        const want: [2]f32 = switch (seen) {
            0 => .{ 80, 40 },
            1 => .{ 40, 20 },
            else => .{ 600, 300 },
        };
        try std.testing.expectEqual(want[0], n.img_w);
        try std.testing.expectEqual(want[1], n.img_h);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "renderAnimation: frame schedule, formats, errors; ico output" {
    if (comptime !(config.enable_animation and config.enable_extra_codecs)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const r = Renderer.create(gpa).?;
    defer r.destroy();
    const scene = "{\"type\":\"container\",\"style\":{\"width\":8,\"height\":8,\"backgroundColor\":\"red\"}}";
    for ([_][]const u8{ "webp", "apng", "gif" }) |fmt| {
        var buf: [512]u8 = undefined;
        const j = try std.fmt.bufPrint(&buf, "{{\"scenes\":[{{\"node\":{s},\"durationMs\":250}},{{\"node\":{{\"type\":\"container\",\"style\":{{\"width\":8,\"height\":8,\"backgroundColor\":\"blue\"}}}},\"durationMs\":100}}],\"width\":8,\"height\":8,\"fps\":10,\"format\":\"{s}\"}}", .{ scene, fmt });
        const out = try r.renderAnimation(j);
        // 4 frames (red 0/100/200, blue 300); identical neighbours may be merged by the encoder
        const n = codec.frameCount(out);
        try std.testing.expect(n >= 2 and n <= 4);
    }
    try std.testing.expectError(error.Invalid, r.renderAnimation("{\"scenes\":[],\"width\":8,\"height\":8,\"fps\":10}"));
    try std.testing.expectError(error.Invalid, r.renderAnimation("{\"scenes\":[{\"node\":{\"type\":\"container\"},\"durationMs\":100}],\"width\":8,\"height\":8,\"fps\":0}"));
    try std.testing.expectError(error.Invalid, r.renderAnimation("{\"scenes\":[{\"node\":{\"type\":\"container\"},\"durationMs\":100}],\"width\":8,\"height\":8,\"fps\":51,\"format\":\"gif\"}"));
    try std.testing.expect(std.mem.indexOf(u8, r.err, "maximum 50 fps") != null);
    const ico = try r.render(scene, "{\"width\":8,\"height\":8,\"format\":\"ico\"}");
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 1, 0, 8, 8 }, ico[0..8]);
    try std.testing.expectError(error.Invalid, r.render(scene, "{\"width\":300,\"height\":8,\"format\":\"ico\"}"));
}

// ---- limits option

test "limits: parsing clamps to the built-in caps; bad values and unknown names fail" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msg: []const u8 = "";
    var detail: []const u8 = "";
    const d = try Limits.parse(null, &msg, &detail);
    try std.testing.expectEqual(Renderer.max_image_pixels, d.image_pixels);
    try std.testing.expectEqual(@as(u32, 10000), d.animation_frames);
    try std.testing.expectEqual(@as(u64, 40_000_000), d.canvas_pixels);
    try std.testing.expectEqual(@as(u32, 512), d.node_depth);
    const l = try Limits.parse(try json.parse(a,
        \\{"maxImagePixels":1000.7,"maxImageBytes":5000,"maxAnimationFrames":1e12,"maxCanvasPixels":1e30,"maxNodeDepth":32,"maxImagePixels":2000}
    ), &msg, &detail);
    // (every member applies and can only lower: a duplicate keeps the lowest value)
    try std.testing.expectEqual(@as(u64, 1000), l.image_pixels);
    try std.testing.expectEqual(@as(u64, 5000), l.image_bytes);
    try std.testing.expectEqual(@as(u32, 10000), l.animation_frames);
    try std.testing.expectEqual(@as(u64, 40_000_000), l.canvas_pixels);
    try std.testing.expectEqual(@as(u32, 32), l.node_depth);
    const null_member = try Limits.parse(try json.parse(a, "{\"maxNodeDepth\":null}"), &msg, &detail);
    try std.testing.expectEqual(@as(u32, 512), null_member.node_depth);
    for ([_][2][]const u8{
        .{ "{\"maxPixels\":5}", "unknown limit: limits.maxPixels" },
        .{ "{\"maxNodeDepth\":0}", "limit must be a number >= 1: limits.maxNodeDepth" },
        .{ "{\"maxNodeDepth\":\"5\"}", "limit must be a number >= 1: limits.maxNodeDepth" },
        .{ "[1]", "limits must be an object" },
    }) |c| {
        try std.testing.expectError(error.Invalid, Limits.parse(try json.parse(a, c[0]), &msg, &detail));
        var buf: [96]u8 = undefined;
        try std.testing.expectEqualStrings(c[1], try std.fmt.bufPrint(&buf, "{s}{s}", .{ msg, detail }));
    }
    // through the render options: an invalid `limits` fails the call
    const r = Renderer.create(gpa).?;
    defer r.destroy();
    const node = "{\"type\":\"container\",\"style\":{\"width\":4,\"height\":4}}";
    try std.testing.expectError(error.Invalid, r.render(node, "{\"limits\":{\"maxWidth\":4}}"));
    try std.testing.expectEqualStrings("unknown limit: limits.maxWidth", r.err);
    _ = try r.render(node, "{\"limits\":{\"maxNodeDepth\":4}}");
    try std.testing.expectEqual(@as(u32, 4), r.limits.node_depth);
    // a call without `limits` is back at the built-in caps
    _ = try r.render(node, "{}");
    try std.testing.expectEqual(@as(u32, 512), r.limits.node_depth);
    _ = try r.render(node, "");
    try std.testing.expectEqual(@as(u32, 512), r.limits.node_depth);
}

test "limits: image sources over maxImagePixels / maxImageBytes are skipped; the cache does not leak them" {
    const gpa = std.testing.allocator;
    const r = Renderer.create(gpa).?;
    defer r.destroy();
    var rgba: [10 * 10 * 4]u8 = undefined;
    for (0..100) |i| rgba[i * 4 ..][0..4].* = .{ 255, 0, 0, 255 };
    const png = try codec.encodePng(gpa, &rgba, 10, 10, .{});
    defer gpa.free(png);
    try r.putImage("img", png, 0, 0, false);
    try r.putImage("raw", &rgba, 10, 10, false);
    const Case = struct { opts: []const u8, img: bool, raw: bool };
    for ([_]Case{
        .{ .opts = "{}", .img = true, .raw = true },
        // decoded and cached by the call above: still refused under the lower limit
        .{ .opts = "{\"limits\":{\"maxImagePixels\":99}}", .img = false, .raw = false },
        .{ .opts = "{\"limits\":{\"maxImagePixels\":100}}", .img = true, .raw = true },
        .{ .opts = "{\"limits\":{\"maxImageBytes\":10}}", .img = false, .raw = true },
        .{ .opts = "{}", .img = true, .raw = true },
    }) |c| {
        r.beginCall();
        _ = try r.parseOptions(c.opts);
        try std.testing.expectEqual(c.img, r.resolveImage("img") != null);
        try std.testing.expectEqual(c.raw, r.resolveImage("raw") != null);
    }
    // never decoded before: refused by the decoder (header check) and not remembered as broken
    const r2 = Renderer.create(gpa).?;
    defer r2.destroy();
    try r2.putImage("img", png, 0, 0, false);
    r2.beginCall();
    _ = try r2.parseOptions("{\"limits\":{\"maxImagePixels\":50}}");
    try std.testing.expect(r2.resolveImage("img") == null);
    try std.testing.expectEqual(@as(usize, 0), r2.img_failed.items.len);
    r2.beginCall();
    _ = try r2.parseOptions("{}");
    try std.testing.expect(r2.resolveImage("img") != null);
    // the image box of a skipped source stays empty, the render succeeds
    const out = try r.render("{\"type\":\"image\",\"src\":\"img\",\"style\":{\"width\":10,\"height\":10}}", "{\"width\":10,\"height\":10,\"format\":\"raw\",\"limits\":{\"maxImagePixels\":64}}");
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out[0..4]);
    const ok = try r.render("{\"type\":\"image\",\"src\":\"img\",\"style\":{\"width\":10,\"height\":10}}", "{\"width\":10,\"height\":10,\"format\":\"raw\"}");
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, ok[0..4]);
}

test "limits: maxImageBytes applies to SVG sources" {
    if (comptime !config.enable_svg) return error.SkipZigTest;
    const r = Renderer.create(std.testing.allocator).?;
    defer r.destroy();
    const svg = "<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'/>";
    r.beginCall();
    _ = try r.parseOptions("{}");
    try std.testing.expect(r.resolveSvg(svg) != null);
    _ = try r.parseOptions("{\"limits\":{\"maxImageBytes\":20}}");
    try std.testing.expect(r.resolveSvg(svg) == null);
    try std.testing.expect(r.resolveSvg("data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20width='4'%20height='4'/%3E") == null);
}

test "limits: maxAnimationFrames (header frame count)" {
    if (comptime !(config.enable_animation and config.enable_extra_codecs)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const r = Renderer.create(gpa).?;
    defer r.destroy();
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try file.appendSlice(gpa, "GIF89a\x01\x00\x01\x00\x00\x00\x00");
    for (0..5) |_| try file.appendSlice(gpa, &.{ 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 1, 0x05, 0 });
    try file.append(gpa, 0x3b);
    r.beginCall();
    _ = try r.parseOptions("{\"limits\":{\"maxAnimationFrames\":5}}");
    try std.testing.expectEqual(@as(?Limits.Field, null), r.imageOverLimit(file.items));
    _ = try r.parseOptions("{\"limits\":{\"maxAnimationFrames\":4}}");
    try std.testing.expectEqual(@as(?Limits.Field, .animation_frames), r.imageOverLimit(file.items));
    try std.testing.expectEqual(@as(u32, 4), r.codecLimits().max_frames);
}

test "limits: maxCanvasPixels and maxNodeDepth fail the render with a clear error" {
    const r = Renderer.create(std.testing.allocator).?;
    defer r.destroy();
    const node = "{\"type\":\"container\",\"style\":{\"width\":100,\"height\":100}}";
    _ = try r.render(node, "{\"limits\":{\"maxCanvasPixels\":10000}}");
    try std.testing.expectError(error.Invalid, r.render(node, "{\"limits\":{\"maxCanvasPixels\":9999}}"));
    try std.testing.expectEqualStrings("canvas exceeds limits.maxCanvasPixels", r.err);
    try std.testing.expectError(error.Invalid, r.render(node, "{\"width\":200,\"height\":100,\"limits\":{\"maxCanvasPixels\":10000}}"));
    try std.testing.expectEqualStrings("canvas exceeds limits.maxCanvasPixels", r.err);
    // 3 levels pass a limit of 3; 4 do not
    const deep = "{\"type\":\"container\",\"style\":{\"width\":4,\"height\":4},\"children\":[{\"type\":\"container\",\"children\":[{\"type\":\"container\"}]}]}";
    _ = try r.render(deep, "{\"limits\":{\"maxNodeDepth\":3}}");
    try std.testing.expectError(error.Invalid, r.render(deep, "{\"limits\":{\"maxNodeDepth\":2}}"));
    try std.testing.expectEqualStrings("node tree exceeds limits.maxNodeDepth", r.err);
    if (comptime config.enable_html) {
        try std.testing.expectError(error.Invalid, r.renderSource(.html, "<div style='width:4px;height:4px'><p><b>x</b></p></div>", "{\"limits\":{\"maxNodeDepth\":2}}"));
        try std.testing.expectEqualStrings("node tree exceeds limits.maxNodeDepth", r.err);
    }
    // (the built-in cap keeps its message)
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (0..max_node_depth + 1) |_| try buf.appendSlice(std.testing.allocator, "{\"type\":\"container\",\"children\":[");
    for (0..max_node_depth + 1) |_| try buf.appendSlice(std.testing.allocator, "]}");
    try std.testing.expectError(error.Invalid, r.render(buf.items, "{\"width\":4,\"height\":4}"));
    try std.testing.expectEqualStrings("node tree is nested too deeply", r.err);
}

test "limits: renderAnimation frames obey maxCanvasPixels" {
    if (comptime !config.enable_animation) return error.SkipZigTest;
    const r = Renderer.create(std.testing.allocator).?;
    defer r.destroy();
    const j = "{\"scenes\":[{\"node\":{\"type\":\"container\"},\"durationMs\":100}],\"width\":8,\"height\":8,\"fps\":10,\"limits\":{\"maxCanvasPixels\":63}}";
    try std.testing.expectError(error.Invalid, r.renderAnimation(j));
    try std.testing.expectEqualStrings("canvas exceeds limits.maxCanvasPixels", r.err);
}

test "limits: renderPdf fails on an image source over the limits" {
    if (comptime !config.enable_pdf) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const r = Renderer.create(gpa).?;
    defer r.destroy();
    var rgba: [10 * 10 * 4]u8 = @splat(255);
    const png = try codec.encodePng(gpa, &rgba, 10, 10, .{});
    defer gpa.free(png);
    try r.putImage("img", png, 0, 0, false);
    const node = "{\"type\":\"image\",\"src\":\"img\",\"style\":{\"width\":10,\"height\":10}}";
    _ = try r.renderPdf(.json, node, "{\"viewport\":{\"width\":20,\"height\":20}}");
    try std.testing.expectError(error.Invalid, r.renderPdf(.json, node, "{\"viewport\":{\"width\":20,\"height\":20},\"limits\":{\"maxImagePixels\":99}}"));
    try std.testing.expect(std.mem.indexOf(u8, r.err, "image exceeds limits.maxImagePixels") != null);
    try std.testing.expectError(error.Invalid, r.renderPdf(.json, node, "{\"viewport\":{\"width\":20,\"height\":20},\"limits\":{\"maxImageBytes\":8}}"));
    try std.testing.expect(std.mem.indexOf(u8, r.err, "image exceeds limits.maxImageBytes") != null);
    try std.testing.expectError(error.Invalid, r.renderPdf(.json, node, "{\"viewport\":{\"width\":20,\"height\":20},\"limits\":{\"maxNodeDepth\":-1}}"));
    try std.testing.expectEqualStrings("limit must be a number >= 1: limits.maxNodeDepth", r.err);
}

// ---- phase 2 layout integration (tables, floats, inline rows, grid names)

/// Render node of the element with `id` (`.el` set), or none.
fn nodeOfId(t: *TestFrame, id: []const u8) u32 {
    for (t.f.nodes.items, 0..) |n, k| {
        if (n.el != none and std.mem.eql(u8, t.f.dom.at(n.el).id, id)) return @intCast(k);
    }
    return none;
}

fn kindsOf(t: *TestFrame, id: u32, buf: []Kind) []Kind {
    var n: usize = 0;
    var c = t.f.nodes.items[id].first_child;
    while (c != none and n < buf.len) : (c = t.f.nodes.items[c].next) {
        buf[n] = t.f.nodes.items[c].kind;
        n += 1;
    }
    return buf[0..n];
}

fn styleOfId(t: *TestFrame, id: []const u8) *const layout.Style {
    return t.f.tree.style(t.f.nodes.items[nodeOfId(t, id)].lid);
}

test "layout2: table spans from td/th/col attributes" {
    if (comptime !config.enable_tables) return error.SkipZigTest;
    try std.testing.expectEqual(@as(?u32, 3), parseSpanAttr(" +3x"));
    try std.testing.expectEqual(@as(?u32, null), parseSpanAttr("x3"));
    try std.testing.expectEqual(@as(?u32, 1 << 30), parseSpanAttr("99999999999999"));
    const t = try TestFrame.init(.json,
        \\{"type":"container","style":{"display":"table"},"children":[
        \\ {"type":"container","tagName":"colgroup","id":"g","style":{"display":"table-column-group"},"attributes":{"span":"0"}},
        \\ {"type":"container","tagName":"col","id":"col","style":{"display":"table-column"},"attributes":{"span":"2"}},
        \\ {"type":"container","style":{"display":"table-row"},"children":[
        \\  {"type":"container","tagName":"td","id":"a","style":{"display":"table-cell"},"attributes":{"colspan":"2","rowspan":"0"}},
        \\  {"type":"text","tagName":"TH","id":"b","text":"x","style":{"display":"table-cell"},"attributes":{"colspan":"5000","rowspan":"3"}},
        \\  {"type":"container","tagName":"div","id":"c","style":{"display":"table-cell"},"attributes":{"colspan":"2"}}]}]}
    , "{\"width\":200,\"height\":100}");
    defer t.deinit();
    try std.testing.expectEqual(@as(u16, 1), styleOfId(t, "g").col_span); // clamped to 1
    try std.testing.expectEqual(@as(u16, 2), styleOfId(t, "col").col_span);
    try std.testing.expectEqual(layout.Display.table_column, styleOfId(t, "col").display);
    try std.testing.expect(styleOfId(t, "a").col_span == 2 and styleOfId(t, "a").row_span == 65534); // rowspan=0: all rows
    try std.testing.expect(styleOfId(t, "b").col_span == 1000 and styleOfId(t, "b").row_span == 3);
    try std.testing.expectEqual(@as(u16, 1), styleOfId(t, "c").col_span); // only td / th
    // a text element with a table-cell display holds its text as a child leaf
    const b = nodeOfId(t, "b");
    try std.testing.expectEqual(Kind.container, t.f.nodes.items[b].kind);
    try std.testing.expectEqual(Kind.anon_text, t.f.nodes.items[t.f.nodes.items[b].first_child].kind);
    try std.testing.expectEqual(layout.Display.table_cell, styleOfId(t, "b").display);
}

test "layout2: inline-level runs, atomic inlines and anonymous line containers" {
    const t = try TestFrame.init(.json,
        \\{"type":"container","style":{"display":"block"},"children":[
        \\ {"type":"container","id":"txt","style":{"display":"block"},"children":[{"type":"text","text":"a "},{"type":"container","children":[{"type":"text","text":"b"}]}]},
        \\ {"type":"container","id":"mix","style":{"display":"block","textAlign":"center"},"children":[{"type":"text","text":" a "},
        \\   {"type":"container","style":{"display":"inline-block","width":10,"height":10}},{"type":"text","text":" "},
        \\   {"type":"container","style":{"display":"inline-flex","width":10,"height":10}},{"type":"text","text":" b "}]},
        \\ {"type":"container","id":"blk","style":{"display":"block"},"children":[{"type":"container","style":{"display":"block"}},
        \\   {"type":"image","src":"x","width":5,"height":5},{"type":"image","src":"x","style":{"float":"left"}}]},
        \\ {"type":"container","id":"flex","style":{"display":"flex"},"children":[{"type":"container","style":{"display":"inline-block"}},{"type":"text","text":"t"}]}]}
    , "{\"width\":200,\"height\":100}");
    defer t.deinit();
    var buf: [8]Kind = undefined;
    // text only: one merged paragraph leaf, no line container
    try std.testing.expectEqualSlices(Kind, &.{.anon_text}, kindsOf(t, nodeOfId(t, "txt"), &buf));
    // mixed: one inline formatting context: its paragraph holds the text, its children are the boxes
    const mix = nodeOfId(t, "mix");
    try std.testing.expectEqualSlices(Kind, &.{.anon_box}, kindsOf(t, mix, &buf));
    const row = t.f.nodes.items[mix].first_child;
    try std.testing.expectEqualSlices(Kind, &.{ .container, .container }, kindsOf(t, row, &buf));
    const rst = t.f.tree.style(t.f.nodes.items[row].lid);
    try std.testing.expectEqual(layout.Display.inline_row, rst.display);
    try std.testing.expectEqual(layout.Position.static, rst.position);
    try std.testing.expect(rst.is_inline_content);
    const rn = &t.f.nodes.items[row];
    try std.testing.expect(rn.para != null and rn.para.?.complex);
    // the line layout of the pass is kept: two objects on one centred line, a space between them
    const tl = rn.tl.?;
    try std.testing.expectEqual(@as(usize, 1), tl.lines.len);
    try std.testing.expectEqual(@as(usize, 2), tl.objects.len);
    const gap = tl.objects[1].x - (tl.objects[0].x + 10);
    try std.testing.expect(gap > 3 and gap < 6);
    try std.testing.expect(tl.lines[0].x > 50 and tl.objects[0].x > tl.lines[0].x);
    const b0 = t.f.tree.layout(t.f.nodes.items[rn.first_child].lid);
    try std.testing.expectApproxEqAbs(tl.objects[0].x, b0.x, 0.02);
    // block + inline image + float: the image and the float share one inline formatting context
    if (config.enable_floats) {
        try std.testing.expectEqualSlices(Kind, &.{ .container, .anon_box }, kindsOf(t, nodeOfId(t, "blk"), &buf));
    } else try std.testing.expectEqualSlices(Kind, &.{ .container, .anon_box, .image }, kindsOf(t, nodeOfId(t, "blk"), &buf));
    // flex containers blockify everything
    try std.testing.expectEqualSlices(Kind, &.{ .container, .text }, kindsOf(t, nodeOfId(t, "flex"), &buf));
    // the root establishes a block formatting context
    try std.testing.expect(t.f.tree.style(t.f.nodes.items[t.f.root].lid).flow_root);
}

/// Layout width of the k-th child of render node `id`.
fn layoutWidth(t: *TestFrame, id: u32, k: usize) !f32 {
    var c = t.f.nodes.items[id].first_child;
    var i: usize = 0;
    while (c != none) : (c = t.f.nodes.items[c].next) {
        if (i == k) return t.f.tree.layout(t.f.nodes.items[c].lid).w;
        i += 1;
    }
    return error.NoSuchChild;
}

test "layout2: line container strut (Geist example and font metrics)" {
    // 16 px Geist: A = 16, D = 5, L = 21 -> strut 16 / 5; middle = x-height / 2
    const g = strutFrom(geist_em, 16, .normal);
    try std.testing.expectEqual(@as(f32, 16), g[0]);
    try std.testing.expectEqual(@as(f32, 5), g[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 4.24), g[2], 1e-4);
    // line-height 1.5: L = 24, half-leading floor(3 / 2) = 1 above, 2 below
    const h = strutFrom(geist_em, 16, .{ .number = 1.5 });
    try std.testing.expect(h[0] == 17 and h[1] == 7);
    // a line-height below the content area: negative descent
    const s = strutFrom(geist_em, 16, .{ .px = 4 });
    try std.testing.expect(s[0] == 7 and s[1] == -3);
    // with Inter registered its metrics are used (ascent 0.96875 -> 16, descent 0.2421875 -> 4)
    const t = try TestFrame.init(.json, "{\"type\":\"container\",\"style\":{\"display\":\"block\",\"fontSize\":16},\"children\":[{\"type\":\"image\",\"src\":\"x\",\"width\":4,\"height\":4}]}", "{\"width\":50,\"height\":50}");
    defer t.deinit();
    const row = t.f.nodes.items[t.f.root].first_child;
    try std.testing.expectEqual(Kind.anon_box, t.f.nodes.items[row].kind);
    // the line is the strut: image bottom on the baseline
    const il = t.f.tree.layout(t.f.nodes.items[t.f.nodes.items[row].first_child].lid);
    try std.testing.expectEqual(@as(f32, 12), il.y);
    try std.testing.expectEqual(@as(f32, 20), t.f.tree.layout(t.f.nodes.items[row].lid).h);
}

test "layout2: grid template areas and named lines" {
    const t = try TestFrame.init(.json,
        \\{"type":"container","style":{"display":"grid","gridTemplateAreas":"\"h h h\" \"s m m\"","gridTemplateColumns":"[a] 10px [b] 10px [a] 10px [a]"},"children":[
        \\ {"type":"container","id":"m","style":{"gridArea":"m"}},
        \\ {"type":"container","id":"h","style":{"gridRow":"h","gridColumn":"h-start / h-end"}},
        \\ {"type":"container","id":"n","style":{"gridColumn":"a / span a"}},
        \\ {"type":"container","id":"bk","style":{"gridColumnStart":"span a","gridColumnEnd":"-1"}},
        \\ {"type":"container","id":"u","style":{"gridColumn":"zzz","gridRow":"1"}}]}
    , "{\"width\":200,\"height\":100}");
    defer t.deinit();
    const S = struct {
        fn eq(p: layout.Placement, s: layout.Line, e: layout.Line) !void {
            try std.testing.expectEqual(s, p.start);
            try std.testing.expectEqual(e, p.end);
        }
    };
    try S.eq(styleOfId(t, "m").grid_row, .{ .line = 2 }, .{ .line = 3 });
    try S.eq(styleOfId(t, "m").grid_column, .{ .line = 2 }, .{ .line = 4 });
    // a single name in the grid-row / grid-column shorthand leaves the end auto (takumi)
    try S.eq(styleOfId(t, "h").grid_row, .{ .line = 1 }, .auto);
    try S.eq(styleOfId(t, "h").grid_column, .{ .line = 1 }, .{ .line = 4 });
    // first line named a = 1; `span <name>` is span 1 (takumi)
    try S.eq(styleOfId(t, "n").grid_column, .{ .line = 1 }, .{ .span = 1 });
    try S.eq(styleOfId(t, "bk").grid_column, .{ .span = 1 }, .{ .line = -1 });
    // unknown name: the first implicit line after the explicit grid (4 explicit lines)
    try S.eq(styleOfId(t, "u").grid_column, .{ .line = 5 }, .auto);
    // the areas size the explicit grid: two rows although grid-template-rows is none
    try std.testing.expectEqual(@as(usize, 2), t.f.tree.style(t.f.nodes.items[t.f.root].lid).grid_template_rows.len);
}

test "layout2: measure() tree shape follows takumi (inline content = the block's runs)" {
    const gpa = std.testing.allocator;
    const r = Renderer.create(gpa).?;
    defer r.destroy();
    _ = try r.registerFont(try gpa.dupe(u8, @embedFile("font/testdata/Inter-Regular.ttf")), "", 0, -1, null);
    const opts = "{\"width\":200,\"height\":100}";
    const count = std.mem.count;
    // block with text only: no child box, two runs (one per source run)
    var out = try r.measure("{\"type\":\"container\",\"style\":{\"display\":\"block\"},\"children\":[{\"type\":\"text\",\"text\":\"a \"},{\"type\":\"text\",\"text\":\"b\",\"style\":{\"color\":\"red\"}}]}", opts);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"children\":[],\"runs\":[{") != null);
    try std.testing.expectEqual(@as(usize, 2), count(u8, out, "{\"x\":"));
    // text, inline-block, text: runs on the block, the inline-block as its only child
    out = try r.measure("{\"type\":\"container\",\"style\":{\"display\":\"block\"},\"children\":[{\"type\":\"text\",\"text\":\"a \"},{\"type\":\"container\",\"style\":{\"display\":\"inline-block\",\"width\":5,\"height\":5}},{\"type\":\"text\",\"text\":\" b\"}]}", opts);
    try std.testing.expectEqual(@as(usize, 2), count(u8, out, "{\"width\":")); // block + inline-block
    try std.testing.expectEqual(@as(usize, 2), count(u8, out, "{\"x\":"));
    // a text element with display: flex reports its anonymous flex item
    out = try r.measure("{\"type\":\"text\",\"text\":\"hi\",\"style\":{\"display\":\"flex\",\"padding\":4}}", opts);
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"width\":200,\"height\":"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"children\":[{\"width\":") != null);
}
