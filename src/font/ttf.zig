//! Zero-copy sfnt parser: TrueType (`glyf`) and OpenType/CFF ('OTTO': `CFF ` / `CFF2`) faces,
//! collections (.ttc / .otc) and variable fonts (fvar/avar/gvar/HVAR/MVAR).
//!
//! All accessors are bounds-checked against the table slices and return 0 / empty on malformed
//! data. Offsets are `u32` combined with saturating arithmetic so behaviour is identical on
//! wasm32 and 64-bit hosts.
//!
//! Optional formats live in their own files and are reached only through the call sites
//! guarded by the two constants below (grep `enable_cff` / `enable_variations`):
//!  * cff.zig        — `cff.parse` in `Font.init`, `cff.outline` in `Font.outlineErased`;
//!  * variations.zig — `Font.withVariations`, `Font.varAdvance`, `Font.mvar`,
//!                     `Font.outlineErased` (varied glyf), `Font.itemVariationDelta`,
//!                     `Font.axis` / `Font.namedInstance`.
const std = @import("std");
const ot = @import("ot.zig");
const cff = @import("cff.zig");
const variations = @import("variations.zig");

/// Wired to the build flags through the root module (`pub const bm_config = @import("config.zig")`
/// in src/wasm.zig / src/root.zig): `config.enable_cff` / `config.enable_variable_fonts`. With
/// `false` the corresponding file is not referenced at all: CFF fonts are then rejected with
/// `error.UnsupportedFontFormat`, variable fonts render as their default instance. A root without
/// `bm_config` (standalone `zig test src/font/font.zig`) enables both.
const root_mod = @import("root");
pub const enable_cff = if (@hasDecl(root_mod, "bm_config")) root_mod.bm_config.enable_cff else true;
pub const enable_variations = if (@hasDecl(root_mod, "bm_config")) root_mod.bm_config.enable_variable_fonts else true;
/// PDF output is compiled in (`PathOut.round_points`).
pub const enable_pdf = if (@hasDecl(root_mod, "bm_config")) root_mod.bm_config.enable_pdf else true;

pub const Error = error{
    /// Recognised but not supported: CFF outlines when CFF support is compiled out, Type 1
    /// charstrings, fonts with neither `glyf` nor `CFF `/`CFF2`.
    UnsupportedFontFormat,
    /// WOFF 1 container: decode it to sfnt first (src/woff).
    WoffContainer,
    /// WOFF 2 container: decode it to sfnt first (src/woff).
    Woff2Container,
    /// Not an sfnt, or the table directory is out of bounds.
    InvalidFont,
    /// One of head/hhea/maxp/hmtx/cmap is missing.
    MissingTable,
};

pub const AxisValue = variations.AxisValue;
pub const Axis = variations.Axis;
pub const NamedInstance = variations.NamedInstance;
pub const max_axes = variations.max_axes;

/// Number of faces in a font file: the `ttcf` count for collections, else 1 (0 when the data
/// is too short to be a font).
pub fn faceCount(data: []const u8) u32 {
    if (data.len < 12) return 0;
    if (rd32(data, 0) == tag("ttcf")) return @min(rd32(data, 8), 4096);
    return 1;
}

pub inline fn rd8(t: []const u8, off: u32) u8 {
    if (off >= t.len) return 0;
    return t[off];
}
pub inline fn rd16(t: []const u8, off: u32) u16 {
    if (t.len < 2 or off > t.len - 2) return 0;
    return (@as(u16, t[off]) << 8) | t[off + 1];
}
pub inline fn rdi16(t: []const u8, off: u32) i16 {
    return @bitCast(rd16(t, off));
}
pub inline fn rd32(t: []const u8, off: u32) u32 {
    if (t.len < 4 or off > t.len - 4) return 0;
    return (@as(u32, t[off]) << 24) | (@as(u32, t[off + 1]) << 16) | (@as(u32, t[off + 2]) << 8) | t[off + 3];
}
/// Sub-slice starting at `off` (empty when out of range).
pub inline fn tail(t: []const u8, off: u32) []const u8 {
    if (off >= t.len) return t[0..0];
    return t[off..];
}

fn tag(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | s[3];
}

pub const Bounds = struct { x_min: i16 = 0, y_min: i16 = 0, x_max: i16 = 0, y_max: i16 = 0 };

/// Ascent/descent/leading in font units, chosen the way skrifa's `Metrics` does (which is what
/// takumi feeds into its Blink-style line metrics):
///  * hhea ascender/descender/lineGap by default;
///  * OS/2 sTypo* when fsSelection bit 7 (USE_TYPO_METRICS) is set, or when hhea ascender and
///    descender are both 0 — falling back to usWinAscent/usWinDescent if the typo values are 0.
/// `descent` is positive-down (i.e. `-hhea.descender`).
pub const LineMetrics = struct { ascent: i32, descent: i32, leading: i32 };

/// 2x3 affine used for composite glyphs: x' = a*x + c*y + e, y' = b*x + d*y + f.
pub const Xf = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,
    ident: bool = true,
};

/// Type-erased path sink. The CFF interpreter and the gvar outline code are written against
/// this (one copy in the binary) instead of being instantiated per `sink` type; `of` wraps
/// any duck-typed sink pointer (`moveTo/lineTo/quadTo/cubicTo/close`).
pub const PathOut = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, verb: Verb, p: *const [6]f32) void,
    /// (PDF builds) gvar-varied points rounded to whole font units, as skrifa draws an unscaled
    /// outline (krilla / takumi-pdf); the raster and SVG paths keep them exact
    round_points: if (enable_pdf) bool else void = if (enable_pdf) false else {},
    point_quant: if (enable_pdf) ?PointQuant else void = if (enable_pdf) null else {},

    pub const Verb = enum(u8) { move, line, quad, cubic, close };

    pub fn of(sink: anytype) PathOut {
        const P = @TypeOf(sink);
        const Thunk = struct {
            fn emit(ctx: *anyopaque, verb: Verb, p: *const [6]f32) void {
                const s: P = @ptrCast(@alignCast(ctx));
                switch (verb) {
                    .move => s.moveTo(p[0], p[1]),
                    .line => s.lineTo(p[0], p[1]),
                    .quad => s.quadTo(p[0], p[1], p[2], p[3]),
                    .cubic => s.cubicTo(p[0], p[1], p[2], p[3], p[4], p[5]),
                    .close => s.close(),
                }
            }
        };
        return .{ .ctx = @ptrCast(@constCast(sink)), .emit = Thunk.emit };
    }
    pub fn moveTo(o: *const PathOut, x: f32, y: f32) void {
        o.emit(o.ctx, .move, &.{ x, y, 0, 0, 0, 0 });
    }
    pub fn lineTo(o: *const PathOut, x: f32, y: f32) void {
        o.emit(o.ctx, .line, &.{ x, y, 0, 0, 0, 0 });
    }
    pub fn quadTo(o: *const PathOut, cx: f32, cy: f32, x: f32, y: f32) void {
        o.emit(o.ctx, .quad, &.{ cx, cy, x, y, 0, 0 });
    }
    pub fn cubicTo(o: *const PathOut, ax: f32, ay: f32, bx: f32, by: f32, x: f32, y: f32) void {
        o.emit(o.ctx, .cubic, &.{ ax, ay, bx, by, x, y });
    }
    pub fn close(o: *const PathOut) void {
        o.emit(o.ctx, .close, &.{ 0, 0, 0, 0, 0, 0 });
    }
};

/// Font-unit coordinates of a glyf outline resolved at a particular ppem.
/// Quantize encoded points before constructing implied on-curve midpoints.
pub const PointQuant = struct {
    mul: f32,
    div: f32,

    pub fn apply(q: PointQuant, value: f32) f32 {
        return @round(value * q.mul) / q.div;
    }

    pub fn midpoint(q: PointQuant, a: f32, b: f32) f32 {
        // FreeType constructs implied points with integer 26.6 arithmetic.
        return @trunc((@round(a * q.div) + @round(b * q.div)) * 0.5) / q.div;
    }
};

/// Control-point bounding box collector (used for CFF / varied glyph bounds).
const BoundsSink = struct {
    x0: f32 = std.math.inf(f32),
    y0: f32 = std.math.inf(f32),
    x1: f32 = -std.math.inf(f32),
    y1: f32 = -std.math.inf(f32),
    fn add(s: *BoundsSink, x: f32, y: f32) void {
        s.x0 = @min(s.x0, x);
        s.x1 = @max(s.x1, x);
        s.y0 = @min(s.y0, y);
        s.y1 = @max(s.y1, y);
    }
    fn emit(ctx: *anyopaque, verb: PathOut.Verb, p: *const [6]f32) void {
        const s: *BoundsSink = @ptrCast(@alignCast(ctx));
        const n: usize = switch (verb) {
            .move, .line => 1,
            .quad => 2,
            .cubic => 3,
            .close => 0,
        };
        for (0..n) |i| s.add(p[i * 2], p[i * 2 + 1]);
    }
};

pub const max_feature_lookups = 24;

pub const Font = struct {
    data: []const u8,
    head: []const u8 = &.{},
    hhea: []const u8 = &.{},
    hmtx: []const u8 = &.{},
    cmap_sub: []const u8 = &.{},
    loca: []const u8 = &.{},
    glyf: []const u8 = &.{},
    name: []const u8 = &.{},
    os2: []const u8 = &.{},
    post: []const u8 = &.{},
    kern: []const u8 = &.{},
    gpos: []const u8 = &.{},
    gsub: []const u8 = &.{},
    /// Vertical metrics (empty when absent): `vhea`, `vmtx`, `VORG`.
    vhea: []const u8 = &.{},
    vmtx: []const u8 = &.{},
    vorg: []const u8 = &.{},
    units_per_em: u16 = 1000,
    num_glyphs: u16 = 0,
    num_hmetrics: u16 = 0,
    cmap_format: u16 = 0,
    loca_long: bool = false,
    /// GPOS lookups of the `kern` feature (ascending lookup index).
    n_kern: u8 = 0,
    kern_lookups: [max_feature_lookups]u16 = undefined,
    /// GSUB lookups (ascending); bit 15 of an entry marks a "discretionary" (liga/clig) lookup
    /// that is switched off when letter-spacing is non-zero.
    n_gsub: u8 = 0,
    gsub_lookups: [max_feature_lookups]u16 = undefined,
    /// First-glyph digests of the lookups above (fast rejection while shaping).
    kern_digests: [max_feature_lookups]ot.Digest = undefined,
    gsub_digests: [max_feature_lookups]ot.Digest = undefined,

    /// `CFF ` or `CFF2` table (empty for glyf fonts) and the offsets parsed from it.
    cff: []const u8 = &.{},
    cff_info: cff.Info = .{},
    /// Variation tables (empty when absent).
    fvar: []const u8 = &.{},
    avar: []const u8 = &.{},
    gvar: []const u8 = &.{},
    hvar: []const u8 = &.{},
    mvar: []const u8 = &.{},
    /// Normalised variation coordinates (F2Dot14) of this instance, `n_axes` valid entries
    /// (0 for static fonts; at most `max_axes`).
    coords: [max_axes]i16 = @splat(0),
    n_axes: u8 = 0,
    /// True when any coordinate is non-zero, i.e. this is not the default instance.
    varied: bool = false,

    /// Parses the table directory. `data` must outlive the Font. `face_index` selects a face of
    /// a .ttc / .otc (must be 0 for a single-face file). Accepts TrueType and CFF/CFF2
    /// flavoured sfnt; WOFF/WOFF2 must be decoded first (`error.WoffContainer`,
    /// `error.Woff2Container`). A variable font starts at its default instance, see
    /// `withVariations`.
    pub fn init(data: []const u8, face_index: u32) Error!Font {
        var f: Font = .{ .data = data };
        try f.parse(face_index);
        return f;
    }

    /// (Separate from `init` so that the error paths return a bare error code instead of
    /// materialising a whole `Error!Font` per error site.)
    noinline fn parse(f: *Font, face_index: u32) Error!void {
        const data = f.data;
        if (data.len < 12 or data.len > 0x7fff_ffff) return error.InvalidFont;
        var dir: u32 = 0;
        var magic = rd32(data, 0);
        if (magic == tag("ttcf")) {
            const n = rd32(data, 8);
            if (face_index >= n) return error.InvalidFont;
            dir = rd32(data, 12 +| face_index *| 4);
            if (dir == 0 or dir > data.len - 12) return error.InvalidFont;
            magic = rd32(data, dir);
        } else if (face_index != 0) return error.InvalidFont;
        if (magic == tag("wOFF")) return error.WoffContainer;
        if (magic == tag("wOF2")) return error.Woff2Container;
        if (magic != 0x00010000 and magic != tag("true") and magic != tag("OTTO")) return error.InvalidFont;

        const num_tables: u32 = rd16(data, dir + 4);
        if (dir + 12 + num_tables * 16 > data.len) return error.InvalidFont;

        var maxp: []const u8 = &.{};
        var cmap: []const u8 = &.{};
        var cff1: []const u8 = &.{};
        var cff2: []const u8 = &.{};
        var i: u32 = 0;
        while (i < num_tables) : (i += 1) {
            const rec = dir + 12 + i * 16;
            const off = rd32(data, rec + 8);
            const len = rd32(data, rec + 12);
            if (off > data.len or len > data.len - off) continue; // table out of bounds: ignore it
            const t = data[off..][0..len];
            switch (rd32(data, rec)) {
                tag("head") => f.head = t,
                tag("hhea") => f.hhea = t,
                tag("maxp") => maxp = t,
                tag("hmtx") => f.hmtx = t,
                tag("cmap") => cmap = t,
                tag("loca") => f.loca = t,
                tag("glyf") => f.glyf = t,
                tag("name") => f.name = t,
                tag("OS/2") => f.os2 = t,
                tag("post") => f.post = t,
                tag("kern") => f.kern = t,
                tag("GPOS") => f.gpos = t,
                tag("GSUB") => f.gsub = t,
                tag("vhea") => f.vhea = t,
                tag("vmtx") => f.vmtx = t,
                tag("VORG") => f.vorg = t,
                tag("CFF ") => cff1 = t,
                tag("CFF2") => cff2 = t,
                tag("fvar") => f.fvar = t,
                tag("avar") => f.avar = t,
                tag("gvar") => f.gvar = t,
                tag("HVAR") => f.hvar = t,
                tag("MVAR") => f.mvar = t,
                else => {},
            }
        }
        if (f.head.len < 54 or f.hhea.len < 36 or maxp.len < 6 or cmap.len < 4) return error.MissingTable;
        if (f.glyf.len == 0 and (cff1.len != 0 or cff2.len != 0)) {
            if (!enable_cff) return error.UnsupportedFontFormat;
            f.cff = if (cff2.len != 0) cff2 else cff1;
            f.cff_info = cff.parse(f.cff, cff2.len != 0) catch return error.UnsupportedFontFormat;
        }
        if (enable_variations) {
            f.n_axes = @intCast(@min(variations.axisCount(f.fvar), max_axes));
        }

        f.units_per_em = rd16(f.head, 18);
        if (f.units_per_em == 0) f.units_per_em = 1000;
        f.loca_long = rd16(f.head, 50) != 0;
        f.num_glyphs = rd16(maxp, 4);
        f.num_hmetrics = rd16(f.hhea, 34);
        f.pickCmap(cmap);
        f.n_kern = @intCast(ot.collectLookups(f.gpos, &.{.{ .tag = tag("kern"), .flag = 0 }}, &f.kern_lookups));
        f.n_gsub = @intCast(ot.collectLookups(f.gsub, &.{
            .{ .tag = tag("ccmp"), .flag = 0 },
            .{ .tag = tag("locl"), .flag = 0 },
            .{ .tag = tag("rlig"), .flag = 0 },
            .{ .tag = tag("liga"), .flag = 0x8000 },
            .{ .tag = tag("clig"), .flag = 0x8000 },
            .{ .tag = tag("calt"), .flag = 0x8000 },
        }, &f.gsub_lookups));
        for (f.kern_lookups[0..f.n_kern], 0..) |li, k| f.kern_digests[k] = ot.lookupDigest(f.gpos, li, 9);
        for (f.gsub_lookups[0..f.n_gsub], 0..) |li, k| f.gsub_digests[k] = ot.lookupDigest(f.gsub, li & 0x7fff, 7);
    }

    fn pickCmap(f: *Font, cmap: []const u8) void {
        const n: u32 = rd16(cmap, 2);
        var best: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const rec = 4 + i * 8;
            const pid = rd16(cmap, rec);
            const eid = rd16(cmap, rec + 2);
            const sub = tail(cmap, rd32(cmap, rec + 4));
            const format = rd16(sub, 0);
            var score: u32 = 0;
            const unicode = pid == 0 or (pid == 3 and (eid == 1 or eid == 10));
            if (unicode) {
                score = switch (format) {
                    12 => if (pid == 3) 6 else 5,
                    4 => if (pid == 3) 4 else 3,
                    13 => 2,
                    6 => 1,
                    else => 0,
                };
            } else if (pid == 3 and eid == 0 and format == 4) score = 1;
            if (score > best) {
                best = score;
                f.cmap_sub = sub;
                f.cmap_format = format;
            }
        }
    }

    // ------------------------------------------------------------------ cmap

    /// Glyph id for a Unicode codepoint, 0 (.notdef) when unmapped.
    pub fn glyphIndex(f: *const Font, cp: u21) u16 {
        const t = f.cmap_sub;
        const c: u32 = cp;
        var gid: u32 = 0;
        switch (f.cmap_format) {
            4 => {
                if (c > 0xffff) return 0;
                const seg_x2: u32 = rd16(t, 6) & 0xfffe;
                const ends: u32 = 14;
                const starts = 16 + seg_x2;
                const deltas = starts + seg_x2;
                const ranges = deltas + seg_x2;
                var lo: u32 = 0;
                var hi: u32 = seg_x2 / 2;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (rd16(t, ends + mid * 2) < c) lo = mid + 1 else hi = mid;
                }
                if (lo >= seg_x2 / 2) return 0;
                const start: u32 = rd16(t, starts + lo * 2);
                if (start > c) return 0;
                const delta: u32 = rd16(t, deltas + lo * 2);
                const ro: u32 = rd16(t, ranges + lo * 2);
                if (ro == 0) {
                    gid = (c + delta) & 0xffff;
                } else {
                    const g: u32 = rd16(t, ranges + lo * 2 + ro + (c - start) * 2);
                    gid = if (g == 0) 0 else (g + delta) & 0xffff;
                }
            },
            12, 13 => {
                const avail: u32 = if (t.len > 16) @intCast((t.len - 16) / 12) else 0;
                var hi: u32 = @min(rd32(t, 12), avail);
                var lo: u32 = 0;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (rd32(t, 16 + mid * 12 + 4) < c) lo = mid + 1 else hi = mid;
                }
                const g = 16 +| lo *| 12;
                const start = rd32(t, g);
                if (g + 12 > t.len or start > c or rd32(t, g + 4) < c) return 0;
                gid = rd32(t, g + 8);
                if (f.cmap_format == 12) gid +|= c - start;
            },
            6 => {
                const first: u32 = rd16(t, 6);
                if (c < first or c - first >= rd16(t, 8)) return 0;
                gid = rd16(t, 10 + (c - first) * 2);
            },
            else => return 0,
        }
        return if (gid < f.num_glyphs) @intCast(gid) else 0;
    }

    // --------------------------------------------------------------- metrics

    pub fn unitsPerEm(f: *const Font) u16 {
        return f.units_per_em;
    }
    pub fn numGlyphs(f: *const Font) u16 {
        return f.num_glyphs;
    }
    pub fn hheaAscender(f: *const Font) i16 {
        return rdi16(f.hhea, 4);
    }
    pub fn hheaDescender(f: *const Font) i16 {
        return rdi16(f.hhea, 6);
    }
    pub fn hheaLineGap(f: *const Font) i16 {
        return rdi16(f.hhea, 8);
    }
    pub fn typoAscender(f: *const Font) i16 {
        return rdi16(f.os2, 68);
    }
    pub fn typoDescender(f: *const Font) i16 {
        return rdi16(f.os2, 70);
    }
    pub fn typoLineGap(f: *const Font) i16 {
        return rdi16(f.os2, 72);
    }
    pub fn winAscent(f: *const Font) u16 {
        return rd16(f.os2, 74);
    }
    pub fn winDescent(f: *const Font) u16 {
        return rd16(f.os2, 76);
    }
    pub fn fsSelection(f: *const Font) u16 {
        return rd16(f.os2, 62);
    }
    pub fn useTypoMetrics(f: *const Font) bool {
        return f.os2.len >= 78 and f.fsSelection() & 0x80 != 0;
    }
    /// MVAR delta of a metric at this instance (0 for static fonts / the default instance).
    noinline fn mvarDelta(f: *const Font, mtag: *const [4]u8) i32 {
        if (!enable_variations or !f.varied or f.mvar.len == 0) return 0;
        return variations.mvarDelta(f.mvar, mtag, f.coordSlice());
    }
    inline fn sat16(v: i32) i16 {
        return @intCast(std.math.clamp(v, -32768, 32767));
    }
    /// OS/2 sxHeight (0 when the table is older than version 2), MVAR `xhgt` applied.
    pub fn xHeight(f: *const Font) i16 {
        return if (rd16(f.os2, 0) >= 2) sat16(@as(i32, rdi16(f.os2, 86)) + f.mvarDelta("xhgt")) else 0;
    }
    /// OS/2 sCapHeight, MVAR `cpht` applied.
    pub fn capHeight(f: *const Font) i16 {
        return if (rd16(f.os2, 0) >= 2) sat16(@as(i32, rdi16(f.os2, 88)) + f.mvarDelta("cpht")) else 0;
    }
    /// OS/2 usWeightClass; 700/400 from macStyle when there is no OS/2 table.
    pub fn weightClass(f: *const Font) u16 {
        if (f.os2.len >= 6) {
            const w = rd16(f.os2, 4);
            if (w >= 1 and w <= 1000) return w;
        }
        return if (rd16(f.head, 44) & 1 != 0) 700 else 400;
    }
    /// OS/2 usWidthClass (1..9, 5 = normal); 5 when there is no OS/2 table.
    pub fn widthClass(f: *const Font) u16 {
        if (f.os2.len >= 8) return rd16(f.os2, 6);
        return 5;
    }
    pub fn isItalic(f: *const Font) bool {
        return (f.os2.len >= 64 and f.fsSelection() & 0x201 != 0) or rd16(f.head, 44) & 2 != 0;
    }
    /// post.underlinePosition (y-up font units, usually negative).
    pub fn underlinePosition(f: *const Font) i16 {
        return sat16(@as(i32, rdi16(f.post, 8)) + f.mvarDelta("undo"));
    }
    pub fn underlineThickness(f: *const Font) i16 {
        return sat16(@as(i32, rdi16(f.post, 10)) + f.mvarDelta("unds"));
    }
    /// OS/2 yStrikeoutPosition (y-up font units).
    pub fn strikeoutPosition(f: *const Font) i16 {
        return sat16(@as(i32, rdi16(f.os2, 28)) + f.mvarDelta("stro"));
    }
    pub fn strikeoutThickness(f: *const Font) i16 {
        return sat16(@as(i32, rdi16(f.os2, 26)) + f.mvarDelta("strs"));
    }

    /// See `LineMetrics`. For a varied instance the MVAR `hasc` / `hdsc` / `hlgp` deltas
    /// (rounded to whole units, like skrifa) are added whichever table the base values came
    /// from. The raw `hhea*` / `typo*` / `win*` accessors above are never varied.
    pub fn lineMetrics(f: *const Font) LineMetrics {
        var m = f.staticLineMetrics();
        if (enable_variations and f.varied and f.mvar.len != 0) {
            const a = m.ascent +| f.mvarDelta("hasc");
            const d = -m.descent +| f.mvarDelta("hdsc");
            m.ascent = @intCast(@min(@abs(a), 0x7fff_ffff));
            m.descent = @intCast(@min(@abs(d), 0x7fff_ffff));
            m.leading +|= f.mvarDelta("hlgp");
        }
        return m;
    }

    fn staticLineMetrics(f: *const Font) LineMetrics {
        const has_os2 = f.os2.len >= 78;
        const use_typo = f.useTypoMetrics();
        var m: LineMetrics = .{ .ascent = 0, .descent = 0, .leading = 0 };
        if (!use_typo) {
            m = .{ .ascent = f.hheaAscender(), .descent = -@as(i32, f.hheaDescender()), .leading = f.hheaLineGap() };
        }
        if (has_os2 and ((m.ascent == 0 and m.descent == 0) or use_typo)) {
            const a: i32 = f.typoAscender();
            const d: i32 = f.typoDescender();
            if (a != 0 or d != 0) {
                m = .{ .ascent = a, .descent = -d, .leading = f.typoLineGap() };
            } else {
                m.ascent = f.winAscent();
                m.descent = f.winDescent();
            }
        }
        return m;
    }

    /// Advance width in font units. For a varied instance the HVAR delta (or, without HVAR,
    /// the gvar phantom-point delta) is added, rounded to a whole unit and clamped at 0 —
    /// the same integer advance skrifa / HarfBuzz use.
    pub fn advanceWidth(f: *const Font, gid: u16) u16 {
        if (f.num_hmetrics == 0) return 0;
        const i: u32 = @min(gid, f.num_hmetrics - 1);
        const base = rd16(f.hmtx, i * 4);
        if (enable_variations and f.varied) return f.varAdvance(gid, base);
        return base;
    }

    noinline fn varAdvance(f: *const Font, gid: u16, base: u16) u16 {
        if (gid >= f.num_glyphs) return base;
        const v = @as(i32, base) +| variations.advanceDelta(f, gid);
        return @intCast(std.math.clamp(v, 0, 0xffff));
    }

    /// Whether the face has vertical metrics (`vhea` + `vmtx`).
    pub fn hasVerticalMetrics(f: *const Font) bool {
        return f.vhea.len >= 36 and rd16(f.vhea, 34) != 0 and f.vmtx.len >= 4;
    }

    /// Vertical advance in font units (Blink `OpenTypeVerticalData::AdvanceHeight`): the `vmtx`
    /// advance height, else the font height (ascent + descent of `lineMetrics`).
    pub fn advanceHeight(f: *const Font, gid: u16) u16 {
        if (f.hasVerticalMetrics()) {
            const n = rd16(f.vhea, 34);
            const i: u32 = @min(gid, n - 1);
            if (i * 4 + 2 <= f.vmtx.len) return rd16(f.vmtx, i * 4);
        }
        const m = f.lineMetrics();
        return @intCast(std.math.clamp(m.ascent + m.descent, 0, 0xffff));
    }

    /// Y of the vertical origin above the horizontal baseline, font units (y-up), as Blink's
    /// `OpenTypeVerticalData::GetVerticalTranslationsForGlyphs`: `VORG` when present, else the
    /// top side bearing from `vmtx` plus the glyph's yMax, else the font ascent. An upright
    /// glyph in vertical text hangs its horizontal baseline this far below the pen position.
    pub fn verticalOriginY(f: *const Font, gid: u16) i32 {
        if (f.vorg.len >= 8) {
            // VORG: version, defaultVertOriginY, numVertOriginYMetrics, {glyphIndex, vertOriginY}[]
            const n: u32 = rd16(f.vorg, 6);
            var lo: u32 = 0;
            var hi: u32 = @min(n, (@as(u32, @intCast(f.vorg.len)) - 8) / 4);
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const g = rd16(f.vorg, 8 + mid * 4);
                if (g == gid) return rdi16(f.vorg, 8 + mid * 4 + 2);
                if (g < gid) lo = mid + 1 else hi = mid;
            }
            return rdi16(f.vorg, 4);
        }
        if (f.hasVerticalMetrics()) {
            const n: u32 = rd16(f.vhea, 34);
            const off: u32 = if (gid < n) @as(u32, gid) * 4 + 2 else n * 4 + (@as(u32, gid) - n) * 2;
            if (off + 2 <= f.vmtx.len) {
                const tsb: i32 = rdi16(f.vmtx, off);
                return tsb + f.headerBoundsOf(gid).y_max;
            }
        }
        return f.lineMetrics().ascent;
    }

    /// Bounding box stored for `gid` (glyf header), else the outline bounds (CFF).
    fn headerBoundsOf(f: *const Font, gid: u16) Bounds {
        if (f.cff.len != 0) return f.outlineBounds(gid);
        return f.headerBounds(gid);
    }

    /// Left side bearing from hmtx (default instance), font units.
    pub fn leftSideBearing(f: *const Font, gid: u16) i16 {
        if (gid < f.num_hmetrics) return rdi16(f.hmtx, @as(u32, gid) * 4 + 2);
        return rdi16(f.hmtx, @as(u32, f.num_hmetrics) * 4 + (@as(u32, gid) - f.num_hmetrics) * 2);
    }

    // ------------------------------------------------------------ variations

    /// Normalised coordinates of this instance (F2Dot14, one per fvar axis, at most
    /// `max_axes`); empty for static fonts. All zeros = default instance.
    pub fn normalizedCoords(f: *const Font) []const i16 {
        return f.coords[0..f.n_axes];
    }
    /// Alias of `normalizedCoords` used inside the module.
    pub inline fn coordSlice(f: *const Font) []const i16 {
        return f.coords[0..f.n_axes];
    }
    pub fn isVariable(f: *const Font) bool {
        return f.n_axes != 0;
    }
    /// Number of fvar axes (may exceed `max_axes`; the excess axes stay at their default).
    pub fn axisCount(f: *const Font) u32 {
        if (!enable_variations) return 0;
        return variations.axisCount(f.fvar);
    }
    /// Axis `i` in user units (min / default / max), null when out of range.
    pub fn axis(f: *const Font, i: u32) ?Axis {
        if (!enable_variations) return null;
        return variations.axisAt(f.fvar, i);
    }
    /// The axis with the given tag ("wght", "wdth", "opsz", "slnt", "ital", ...).
    pub fn findAxis(f: *const Font, axis_tag: *const [4]u8) ?Axis {
        if (!enable_variations) return null;
        return variations.findAxis(f.fvar, axis_tag);
    }
    /// Writes up to `buf.len` axes and returns the filled prefix.
    pub fn axes(f: *const Font, buf: []Axis) []Axis {
        var n: usize = 0;
        while (n < buf.len) : (n += 1) buf[n] = f.axis(@intCast(n)) orelse break;
        return buf[0..n];
    }
    pub fn namedInstanceCount(f: *const Font) u32 {
        if (!enable_variations) return 0;
        return variations.instanceCount(f.fvar);
    }
    /// Named instance `i`; its user-space coordinates are written to `buf` (axis order).
    /// Use `nameString(inst.subfamily_name_id, ...)` for its name.
    pub fn namedInstance(f: *const Font, i: u32, buf: []f32) ?NamedInstance {
        if (!enable_variations) return null;
        return variations.instanceAt(f.fvar, i, buf);
    }

    /// A copy of this font instanced at the given user-space axis values (unknown tags are
    /// ignored, values are clamped to the axis range, the last setting of a tag wins, axes
    /// that are not mentioned sit at their default; `avar` is applied). No allocation: the
    /// copy carries the normalised coordinates inline and shares the font bytes. All metric,
    /// advance and outline accessors of the copy honour the coordinates. Calling it on an
    /// instance re-instances from scratch (settings do not accumulate).
    pub fn withVariations(self: *const Font, settings: []const AxisValue) Font {
        var f = self.*;
        if (enable_variations and f.n_axes != 0) {
            _ = variations.normalize(f.fvar, f.avar, settings, &f.coords);
            f.varied = false;
            for (f.coords[0..f.n_axes]) |c| {
                if (c != 0) f.varied = true;
            }
        }
        return f;
    }

    /// A copy of this font at explicit normalised coordinates (F2Dot14, axis order; missing
    /// trailing axes are 0, extra ones ignored).
    pub fn withNormalizedCoords(self: *const Font, coords: []const i16) Font {
        var f = self.*;
        f.varied = false;
        for (f.coords[0..f.n_axes], 0..) |*c, i| {
            c.* = if (i < coords.len) std.math.clamp(coords[i], -16384, 16384) else 0;
            if (c.* != 0) f.varied = true;
        }
        return f;
    }

    /// Delta of ItemVariationStore item (`outer`, `inner`) at this instance, in font units
    /// (unrounded). `table` is any table of this font and `store_offset` the offset of the
    /// store inside it (GDEF: its itemVarStoreOffset; for GPOS/GSUB device tables with
    /// deltaFormat 0x8000 pass the GDEF table and the two u16 of the VariationIndex).
    /// Returns 0 for static fonts, the default instance and malformed data.
    pub fn itemVariationDelta(f: *const Font, table: []const u8, store_offset: u32, outer: u16, inner: u16) f32 {
        if (!enable_variations or !f.varied) return 0;
        return variations.itemDelta(tail(table, store_offset), outer, inner, f.coordSlice());
    }

    // ------------------------------------------------------------------ name

    /// UTF-8 family name (name id 16, else 1) written into `buf`; truncated to fit.
    pub fn familyName(f: *const Font, buf: []u8) []const u8 {
        const s = f.nameString(16, buf);
        return if (s.len != 0) s else f.nameString(1, buf);
    }
    /// UTF-8 subfamily ("Regular", "Bold Italic", ...; name id 17, else 2).
    pub fn subfamilyName(f: *const Font, buf: []u8) []const u8 {
        const s = f.nameString(17, buf);
        return if (s.len != 0) s else f.nameString(2, buf);
    }

    /// Decodes a `name` record to UTF-8. Prefers Windows/en-US, then any Windows or Unicode
    /// record, then Macintosh Roman (non-ASCII bytes become '?').
    pub fn nameString(f: *const Font, name_id: u16, buf: []u8) []const u8 {
        const t = f.name;
        const count: u32 = rd16(t, 2);
        const strings = tail(t, rd16(t, 4));
        var best: u32 = 0;
        var best_rec: u32 = 0;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const rec = 6 + i * 12;
            if (rec + 12 > t.len) break;
            if (rd16(t, rec + 6) != name_id) continue;
            const pid = rd16(t, rec);
            const lang = rd16(t, rec + 4);
            const score: u32 = switch (pid) {
                3 => if (lang == 0x409) 4 else 3,
                0 => 2,
                1 => if (lang == 0) 1 else 0,
                else => 0,
            };
            if (score > best) {
                best = score;
                best_rec = rec;
            }
        }
        if (best == 0) return buf[0..0];
        const len: u32 = rd16(t, best_rec + 8);
        const off: u32 = rd16(t, best_rec + 10);
        if (off > strings.len or len > strings.len - off) return buf[0..0];
        const s = strings[off..][0..len];
        var n: usize = 0;
        if (best == 1) {
            for (s) |ch| {
                if (n >= buf.len) break;
                buf[n] = if (ch < 0x80) ch else '?';
                n += 1;
            }
            return buf[0..n];
        }
        var k: u32 = 0;
        while (k + 1 < s.len) : (k += 2) {
            var cp: u21 = rd16(s, k);
            if (cp >= 0xd800 and cp < 0xdc00 and k + 3 < s.len) {
                const lo = rd16(s, k + 2);
                if (lo >= 0xdc00 and lo < 0xe000) {
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                    k += 2;
                }
            }
            if (cp >= 0xd800 and cp < 0xe000) cp = 0xfffd;
            var tmp: [4]u8 = undefined;
            const l = encodeUtf8(cp, &tmp);
            if (n + l > buf.len) break;
            @memcpy(buf[n..][0..l], tmp[0..l]);
            n += l;
        }
        return buf[0..n];
    }

    // --------------------------------------------------------------- kerning

    /// Pair kerning in font units (added to the advance of `left`): GPOS `kern` feature when the
    /// font has one, else the legacy `kern` table (format 0).
    pub fn kerning(f: *const Font, left: u16, right: u16) i16 {
        const v = f.pairAdjust(left, right).adv1;
        return @intCast(std.math.clamp(v, -32768, 32767));
    }

    /// Full pair adjustment (x advance / x placement of both glyphs), font units.
    pub fn pairAdjust(f: *const Font, left: u16, right: u16) ot.PairAdjust {
        if (f.n_kern != 0) {
            var r: ot.PairAdjust = .{};
            for (f.kern_lookups[0..f.n_kern], 0..) |li, k| {
                if (f.kern_digests[k].mayHave(left)) ot.pairLookup(f.gpos, li, left, right, &r);
            }
            return r;
        }
        return .{ .adv1 = f.kernTable(left, right) };
    }

    fn kernTable(f: *const Font, left: u16, right: u16) i32 {
        const t = f.kern;
        if (t.len < 4 or rd16(t, 0) != 0) return 0;
        const n: u32 = rd16(t, 2);
        const key: u32 = (@as(u32, left) << 16) | right;
        var off: u32 = 4;
        var sum: i32 = 0;
        var i: u32 = 0;
        while (i < n and off + 14 <= t.len) : (i += 1) {
            const len: u32 = rd16(t, off + 2);
            const cov = rd16(t, off + 4);
            // format 0, horizontal, not minimum / cross-stream
            if (cov >> 8 == 0 and cov & 0x7 == 1) {
                const avail: u32 = @intCast((t.len - off - 14) / 6);
                var hi: u32 = @min(rd16(t, off + 6), avail);
                var lo: u32 = 0;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    const k = rd32(t, off + 14 + mid * 6);
                    if (k < key) lo = mid + 1 else hi = mid;
                }
                const p = off + 14 + lo * 6;
                if (p + 6 <= t.len and rd32(t, p) == key) sum += rdi16(t, p + 4);
            }
            if (len < 6) break;
            off += len;
        }
        return sum;
    }

    // ---------------------------------------------------------------- glyphs

    /// Raw `glyf` record of a glyph (empty for CFF fonts, empty glyphs and bad ids).
    pub fn glyphData(f: *const Font, gid: u16) []const u8 {
        if (gid >= f.num_glyphs) return &.{};
        var a: u32 = undefined;
        var b: u32 = undefined;
        if (f.loca_long) {
            if ((@as(u32, gid) + 2) * 4 > f.loca.len) return &.{};
            a = rd32(f.loca, @as(u32, gid) * 4);
            b = rd32(f.loca, @as(u32, gid) * 4 + 4);
        } else {
            if ((@as(u32, gid) + 2) * 2 > f.loca.len) return &.{};
            a = @as(u32, rd16(f.loca, @as(u32, gid) * 2)) * 2;
            b = @as(u32, rd16(f.loca, @as(u32, gid) * 2 + 2)) * 2;
        }
        if (b <= a or b > f.glyf.len) return &.{};
        return f.glyf[a..b];
    }

    /// Bounding box in font units (y-up); zeros for empty glyphs.
    ///  * static glyf fonts: the box stored in the glyf header (O(1));
    ///  * CFF/CFF2 fonts and varied instances: computed by running the outline — the box of
    ///    all on- and off-curve control points (may slightly exceed the tight curve box),
    ///    rounded outwards. Not cached: callers that need it repeatedly should cache it.
    pub fn glyphBounds(f: *const Font, gid: u16) Bounds {
        if (f.cff.len != 0 or f.varied) return f.outlineBounds(gid);
        return f.headerBounds(gid);
    }

    fn headerBounds(f: *const Font, gid: u16) Bounds {
        const g = f.glyphData(gid);
        if (g.len < 10) return .{};
        return .{ .x_min = rdi16(g, 2), .y_min = rdi16(g, 4), .x_max = rdi16(g, 6), .y_max = rdi16(g, 8) };
    }

    fn outlineBounds(f: *const Font, gid: u16) Bounds {
        var b: BoundsSink = .{};
        const po: PathOut = .{ .ctx = &b, .emit = BoundsSink.emit };
        const drawn = f.outlineErased(gid, &po) orelse return f.headerBounds(gid);
        if (!drawn or !(b.x0 <= b.x1)) return .{};
        return .{ .x_min = satF(@floor(b.x0)), .y_min = satF(@floor(b.y0)), .x_max = satF(@ceil(b.x1)), .y_max = satF(@ceil(b.y1)) };
    }
    fn satF(v: f32) i16 {
        return @intFromFloat(std.math.clamp(v, -32768, 32767));
    }

    /// Outline paths that go through the type-erased sink: CFF charstrings and gvar-varied
    /// glyf outlines. Returns false when neither applies or the glyph is empty.
    /// Null: the glyph has to be drawn through the static glyf path instead.
    fn outlineErased(f: *const Font, gid: u16, out: *const PathOut) ?bool {
        if (enable_cff and f.cff.len != 0)
            return cff.outline(f.cff, f.cff_info, if (enable_variations) f.coordSlice() else &.{}, gid, out);
        if (enable_variations and f.varied and f.gvar.len != 0)
            return variations.glyfOutline(f, gid, out);
        return null;
    }

    /// Emits the outline of `gid` in font units (y-up) to `sink`, which needs
    /// `moveTo(x,y)`, `lineTo(x,y)`, `quadTo(cx,cy,x,y)`, `cubicTo(c1x,c1y,c2x,c2y,x,y)`, `close()`
    /// (f32 args, void result; glyf outlines emit quads, CFF outlines cubics). Every contour
    /// is a moveTo ... close sequence. Returns false when the glyph has no outline.
    /// Honours the instance coordinates (gvar deltas with IUP / CFF2 blends).
    ///
    /// Like FreeType and skrifa the outline is shifted so that the glyph origin sits at the
    /// first phantom point, i.e. by `lsb - xMin` (0 for nearly every font).
    pub fn outline(f: *const Font, gid: u16, sink: anytype) bool {
        return f.outlineWith(gid, sink, false);
    }

    /// `outline`; `round_points` (PDF builds): varied points on whole font units (`PathOut`).
    pub fn outlineWith(f: *const Font, gid: u16, sink: anytype, comptime round_points: bool) bool {
        return f.outlineQuant(gid, sink, round_points, null);
    }

    /// Outline in font units, resolved as Skrifa's unhinted ppem outline.
    /// CFF retains floating-point coordinates; glyf uses its 26.6 point grid.
    pub fn outlineResolved(f: *const Font, gid: u16, size: f32, sink: anytype) bool {
        if (!(size > 0) or !std.math.isFinite(size)) return false;
        const divisor = size * 64 / @as(f32, @floatFromInt(@max(1, f.units_per_em)));
        if (!(divisor > 0) or !std.math.isFinite(divisor)) return false;
        return f.outlineQuant(gid, sink, true, .{ .mul = if (size < 30000) scale26_6(size, f.units_per_em) else divisor, .div = divisor });
    }

    fn outlineQuant(f: *const Font, gid: u16, sink: anytype, comptime round_points: bool, quant: ?PointQuant) bool {
        if ((enable_cff and f.cff.len != 0) or (enable_variations and f.varied and f.gvar.len != 0)) {
            var po = PathOut.of(sink);
            if (comptime enable_pdf and round_points) po.round_points = true;
            if (comptime enable_pdf) po.point_quant = quant;
            if (f.outlineErased(gid, &po)) |drawn| return drawn;
        }
        var budget: u32 = 256;
        var xf: Xf = .{};
        const g = f.glyphData(gid);
        if (g.len >= 10) {
            const sh = @as(i32, rdi16(g, 2)) - f.leftSideBearing(gid);
            if (sh != 0) xf = .{ .e = @floatFromInt(-sh), .ident = false };
        }
        return f.outlineRec(gid, xf, 0, &budget, sink, comptime enable_pdf and round_points, quant);
    }

    /// `ft_start` (PDF builds): contours start where FreeType / skrifa start them (`simpleOutlineFt`).
    fn outlineRec(f: *const Font, gid: u16, xf: Xf, depth: u32, budget: *u32, sink: anytype, comptime ft_start: bool, quant: ?PointQuant) bool {
        const g = f.glyphData(gid);
        if (g.len < 10) return false;
        const nc = rdi16(g, 0);
        if (nc >= 0) return if (ft_start) simpleOutlineFtQuant(g, @intCast(nc), xf, sink, quant) else simpleOutline(g, @intCast(nc), xf, sink);
        if (depth >= 8) return false;
        var any = false;
        var off: u32 = 10;
        while (off + 4 <= g.len) {
            if (budget.* == 0) break;
            budget.* -= 1;
            const flags = rd16(g, off);
            const child = rd16(g, off + 2);
            off += 4;
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (flags & 1 != 0) {
                if (flags & 2 != 0) {
                    dx = @floatFromInt(rdi16(g, off));
                    dy = @floatFromInt(rdi16(g, off + 2));
                }
                off += 4;
            } else {
                if (flags & 2 != 0) {
                    dx = @floatFromInt(@as(i8, @bitCast(rd8(g, off))));
                    dy = @floatFromInt(@as(i8, @bitCast(rd8(g, off + 1))));
                }
                off += 2;
            }
            var c: Xf = .{};
            if (flags & 0x8 != 0) {
                c.a = f2dot14(g, off);
                c.d = c.a;
                off += 2;
            } else if (flags & 0x40 != 0) {
                c.a = f2dot14(g, off);
                c.d = f2dot14(g, off + 2);
                off += 4;
            } else if (flags & 0x80 != 0) {
                c.a = f2dot14(g, off);
                c.b = f2dot14(g, off + 2);
                c.c = f2dot14(g, off + 4);
                c.d = f2dot14(g, off + 6);
                off += 8;
            }
            // combined = xf ∘ (c, translate(dx, dy))
            const m: Xf = .{
                .a = xf.a * c.a + xf.c * c.b,
                .b = xf.b * c.a + xf.d * c.b,
                .c = xf.a * c.c + xf.c * c.d,
                .d = xf.b * c.c + xf.d * c.d,
                .e = xf.a * dx + xf.c * dy + xf.e,
                .f = xf.b * dx + xf.d * dy + xf.f,
                .ident = false,
            };
            if (f.outlineRec(child, m, depth + 1, budget, sink, ft_start, quant)) any = true;
            if (flags & 0x20 == 0) break;
        }
        return any;
    }
};

fn f2dot14(t: []const u8, off: u32) f32 {
    return @as(f32, @floatFromInt(rdi16(t, off))) * (1.0 / 16384.0);
}

const Pt = struct { x: f32, y: f32 };

pub fn simpleOutline(g: []const u8, nc: u32, xf: Xf, sink: anytype) bool {
    if (nc == 0) return false;
    const end_pts: u32 = 10;
    const npts: u32 = @as(u32, rd16(g, end_pts + (nc - 1) * 2)) + 1;
    const ins_len: u32 = rd16(g, end_pts + nc * 2);
    const flags_off = end_pts + nc * 2 + 2 + ins_len;
    if (flags_off >= g.len) return false;

    // Pass 1: size of the flag and x-coordinate arrays.
    var fo = flags_off;
    var x_bytes: u32 = 0;
    var y_bytes: u32 = 0;
    var n: u32 = 0;
    while (n < npts) {
        if (fo >= g.len) return false;
        const fl = g[fo];
        fo += 1;
        var rep: u32 = 1;
        if (fl & 8 != 0) {
            rep += rd8(g, fo);
            fo += 1;
        }
        const xs: u32 = if (fl & 2 != 0) 1 else if (fl & 0x10 != 0) 0 else 2;
        const ys: u32 = if (fl & 4 != 0) 1 else if (fl & 0x20 != 0) 0 else 2;
        x_bytes += xs * rep;
        y_bytes += ys * rep;
        n += rep;
    }
    var xo = fo;
    var yo = xo + x_bytes;
    if (yo + y_bytes > g.len) return false;

    // Pass 2: stream points through the contour state machine.
    fo = flags_off;
    var fl: u8 = 0;
    var rep: u32 = 0;
    var x: i32 = 0;
    var y: i32 = 0;
    var pi: u32 = 0;
    var ci: u32 = 0;
    var any = false;
    while (ci < nc) : (ci += 1) {
        const end: u32 = rd16(g, end_pts + ci * 2);
        if (end < pi or end >= npts) return any;
        var started = false;
        var start: Pt = undefined;
        var first_off: ?Pt = null;
        var pending: ?Pt = null;
        var k: u32 = 0;
        while (pi <= end) : ({
            pi += 1;
            k += 1;
        }) {
            if (rep == 0) {
                fl = rd8(g, fo);
                fo += 1;
                if (fl & 8 != 0) {
                    rep = rd8(g, fo);
                    fo += 1;
                }
            } else rep -= 1;
            if (fl & 2 != 0) {
                const d: i32 = rd8(g, xo);
                xo += 1;
                x +%= if (fl & 0x10 != 0) d else -d;
            } else if (fl & 0x10 == 0) {
                x +%= rdi16(g, xo);
                xo += 2;
            }
            if (fl & 4 != 0) {
                const d: i32 = rd8(g, yo);
                yo += 1;
                y +%= if (fl & 0x20 != 0) d else -d;
            } else if (fl & 0x20 == 0) {
                y +%= rdi16(g, yo);
                yo += 2;
            }
            var p: Pt = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
            if (!xf.ident) p = .{ .x = xf.a * p.x + xf.c * p.y + xf.e, .y = xf.b * p.x + xf.d * p.y + xf.f };
            const on = fl & 1 != 0;
            if (!started) {
                if (on) {
                    start = p;
                } else if (k == 0) {
                    first_off = p;
                    continue;
                } else {
                    start = midPt(first_off.?, p);
                    pending = p;
                }
                sink.moveTo(start.x, start.y);
                started = true;
            } else if (on) {
                if (pending) |c| sink.quadTo(c.x, c.y, p.x, p.y) else sink.lineTo(p.x, p.y);
                pending = null;
            } else {
                if (pending) |c| {
                    const m = midPt(c, p);
                    sink.quadTo(c.x, c.y, m.x, m.y);
                }
                pending = p;
            }
        }
        if (!started) continue;
        if (first_off) |p| {
            if (pending) |c| {
                const m = midPt(c, p);
                sink.quadTo(c.x, c.y, m.x, m.y);
            }
            pending = p;
        }
        if (pending) |c| sink.quadTo(c.x, c.y, start.x, start.y);
        sink.close();
        any = true;
    }
    return any;
}

/// The glyf point decoder of `simpleOutlineFt` (a copy reads ahead).
const GlyfPoints = struct {
    g: []const u8,
    fo: u32,
    xo: u32,
    yo: u32,
    fl: u8 = 0,
    rep: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    quant: ?PointQuant = null,

    const Point = struct { p: Pt, on: bool };

    fn next(d: *GlyfPoints, xf: Xf) Point {
        const g = d.g;
        if (d.rep == 0) {
            d.fl = rd8(g, d.fo);
            d.fo += 1;
            if (d.fl & 8 != 0) {
                d.rep = rd8(g, d.fo);
                d.fo += 1;
            }
        } else d.rep -= 1;
        const fl = d.fl;
        if (fl & 2 != 0) {
            const v: i32 = rd8(g, d.xo);
            d.xo += 1;
            d.x +%= if (fl & 0x10 != 0) v else -v;
        } else if (fl & 0x10 == 0) {
            d.x +%= rdi16(g, d.xo);
            d.xo += 2;
        }
        if (fl & 4 != 0) {
            const v: i32 = rd8(g, d.yo);
            d.yo += 1;
            d.y +%= if (fl & 0x20 != 0) v else -v;
        } else if (fl & 0x20 == 0) {
            d.y +%= rdi16(g, d.yo);
            d.yo += 2;
        }
        var p: Pt = .{ .x = @floatFromInt(d.x), .y = @floatFromInt(d.y) };
        if (!xf.ident) p = .{ .x = xf.a * p.x + xf.c * p.y + xf.e, .y = xf.b * p.x + xf.d * p.y + xf.f };
        if (d.quant) |q| p = .{ .x = q.apply(p.x), .y = q.apply(p.y) };
        return .{ .p = p, .on = fl & 1 != 0 };
    }
};

/// `simpleOutline` with each contour started where FreeType's `FT_Outline_Decompose` (and skrifa,
/// which krilla / takumi-pdf draw glyphs with) starts it: at the first point when it is on the
/// curve; else at the last point when that one is; else midway between the first and the last.
/// The same shape as `simpleOutline` (which starts at the first on-curve point, or midway between
/// the first two), with the path operators in the order takumi-pdf writes them. PDF builds only
/// (`Font.outlineWith(.., true)`).
pub fn simpleOutlineFt(g: []const u8, nc: u32, xf: Xf, sink: anytype) bool {
    return simpleOutlineFtQuant(g, nc, xf, sink, null);
}

fn simpleOutlineFtQuant(g: []const u8, nc: u32, xf: Xf, sink: anytype, quant: ?PointQuant) bool {
    if (nc == 0) return false;
    const end_pts: u32 = 10;
    const npts: u32 = @as(u32, rd16(g, end_pts + (nc - 1) * 2)) + 1;
    const ins_len: u32 = rd16(g, end_pts + nc * 2);
    const flags_off = end_pts + nc * 2 + 2 + ins_len;
    if (flags_off >= g.len) return false;

    // the sizes of the flag and x-coordinate arrays (as `simpleOutline`)
    var fo = flags_off;
    var x_bytes: u32 = 0;
    var y_bytes: u32 = 0;
    var n: u32 = 0;
    while (n < npts) {
        if (fo >= g.len) return false;
        const fl = g[fo];
        fo += 1;
        var rep: u32 = 1;
        if (fl & 8 != 0) {
            rep += rd8(g, fo);
            fo += 1;
        }
        const xs: u32 = if (fl & 2 != 0) 1 else if (fl & 0x10 != 0) 0 else 2;
        const ys: u32 = if (fl & 4 != 0) 1 else if (fl & 0x20 != 0) 0 else 2;
        x_bytes += xs * rep;
        y_bytes += ys * rep;
        n += rep;
    }
    if (fo + x_bytes + y_bytes > g.len) return false;

    var d: GlyfPoints = .{ .g = g, .fo = flags_off, .xo = fo, .yo = fo + x_bytes, .quant = quant };
    var pi: u32 = 0;
    var ci: u32 = 0;
    var any = false;
    while (ci < nc) : (ci += 1) {
        const end: u32 = rd16(g, end_pts + ci * 2);
        if (end < pi or end >= npts) return any;
        // the points after the first
        const rest = end - pi;
        pi = end + 1;
        const first = d.next(xf);
        var start = first.p;
        var pending: ?Pt = null;
        // the points walked after the first (all of them, but the last when it is the start)
        var walk = rest;
        if (!first.on) {
            pending = first.p;
            if (rest > 0) {
                var ahead = d;
                var last = first;
                var k: u32 = 0;
                while (k < rest) : (k += 1) last = ahead.next(xf);
                if (last.on) {
                    start = last.p;
                    walk -= 1;
                } else start = midPtResolved(first.p, last.p, quant);
            }
        }
        sink.moveTo(start.x, start.y);
        var k: u32 = 0;
        while (k < walk) : (k += 1) {
            const q = d.next(xf);
            if (q.on) {
                if (pending) |c| sink.quadTo(c.x, c.y, q.p.x, q.p.y) else sink.lineTo(q.p.x, q.p.y);
                pending = null;
            } else {
                if (pending) |c| {
                    const m = midPtResolved(c, q.p, quant);
                    sink.quadTo(c.x, c.y, m.x, m.y);
                }
                pending = q.p;
            }
        }
        // the last point, when it is the start
        if (walk < rest) _ = d.next(xf);
        if (pending) |c| sink.quadTo(c.x, c.y, start.x, start.y);
        sink.close();
        any = true;
    }
    return any;
}

inline fn midPt(a: Pt, b: Pt) Pt {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

inline fn midPtResolved(a: Pt, b: Pt, quant: ?PointQuant) Pt {
    const q = quant orelse return midPt(a, b);
    return .{ .x = q.midpoint(a.x, b.x), .y = q.midpoint(a.y, b.y) };
}

/// Encodes `cp` as UTF-8 into `out`, returning the length (1..4).
pub fn encodeUtf8(cp: u21, out: *[4]u8) u8 {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        out[0] = @intCast(0xc0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3f));
        return 2;
    } else if (cp < 0x10000) {
        out[0] = @intCast(0xe0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3f));
        out[2] = @intCast(0x80 | (cp & 0x3f));
        return 3;
    }
    out[0] = @intCast(0xf0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3f));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3f));
    out[3] = @intCast(0x80 | (cp & 0x3f));
    return 4;
}

fn ScaleSink(comptime S: type) type {
    return struct {
        inner: S,
        /// 64 * px per font unit.
        s: f32,
        ox: f32,
        oy: f32,
        /// Scales a font-unit coordinate to px on the 26.6 grid (round half away from zero),
        /// which is where FreeType / skrifa place every unhinted outline point.
        inline fn q(self: *const @This(), v: f32) f32 {
            const t = v * self.s;
            const r = @floor(@abs(t) + 0.5) * (1.0 / 64.0);
            return if (t < 0) -r else r;
        }
        pub fn moveTo(self: *@This(), x: f32, y: f32) void {
            self.inner.moveTo(self.ox + self.q(x), self.oy - self.q(y));
        }
        pub fn lineTo(self: *@This(), x: f32, y: f32) void {
            self.inner.lineTo(self.ox + self.q(x), self.oy - self.q(y));
        }
        pub fn quadTo(self: *@This(), cx: f32, cy: f32, x: f32, y: f32) void {
            self.inner.quadTo(self.ox + self.q(cx), self.oy - self.q(cy), self.ox + self.q(x), self.oy - self.q(y));
        }
        pub fn cubicTo(self: *@This(), ax: f32, ay: f32, bx: f32, by: f32, x: f32, y: f32) void {
            self.inner.cubicTo(self.ox + self.q(ax), self.oy - self.q(ay), self.ox + self.q(bx), self.oy - self.q(by), self.ox + self.q(x), self.oy - self.q(y));
        }
        pub fn close(self: *@This()) void {
            self.inner.close();
        }
    };
}

/// The 16.16 scale factor skrifa / FreeType derive for a pixel size: `trunc(size * 64)`
/// 26.6 px per em, divided (rounded) by unitsPerEm. Returned as 64 * px per font unit.
pub fn scale26_6(size_px: f32, units_per_em: u16) f32 {
    const sz: f32 = if (size_px > 0 and size_px < 30000.0) size_px else 0;
    const a: u64 = @intFromFloat(sz * 64.0);
    const upem: u64 = @max(1, units_per_em);
    const bits = ((a << 16) + upem / 2) / upem;
    return @as(f32, @floatFromInt(bits)) * (1.0 / 65536.0);
}

/// Emits glyph `gid` scaled to `size_px` with its origin (baseline, pen position) at
/// (`origin_x`, `origin_y`) in a y-DOWN device space. `sink` is the same duck type as for
/// `Font.outline` (pass a pointer). No hinting. Returns false for empty glyphs.
///
/// To be pixel-compatible with takumi (skrifa in FreeType mode) every coordinate is snapped
/// to 1/64 px relative to the glyph origin, using FreeType's 16.16 scale factor (see
/// `scale26_6`; e.g. 13.33 px is rendered at 853/64 px).
pub fn emitGlyph(face: *const Font, gid: u16, size_px: f32, origin_x: f32, origin_y: f32, sink: anytype) bool {
    var s: ScaleSink(@TypeOf(sink)) = .{
        .inner = sink,
        .s = scale26_6(size_px, face.units_per_em),
        .ox = origin_x,
        .oy = origin_y,
    };
    return face.outline(gid, &s);
}

/// Test hook: decodes a raw simple-glyph record (as stored in `glyf`).
/// Test hook: `testSimpleOutline` with the contours started as FreeType starts them.
pub fn testSimpleOutlineFt(glyph: []const u8, sink: anytype) bool {
    const nc = rdi16(glyph, 0);
    if (nc <= 0) return false;
    return simpleOutlineFt(glyph, @intCast(nc), .{}, sink);
}

pub fn testSimpleOutlineResolved(glyph: []const u8, quant: PointQuant, sink: anytype) bool {
    const nc = rdi16(glyph, 0);
    if (nc <= 0) return false;
    return simpleOutlineFtQuant(glyph, @intCast(nc), .{}, sink, quant);
}

pub fn testSimpleOutline(glyph: []const u8, sink: anytype) bool {
    const nc = rdi16(glyph, 0);
    if (nc <= 0) return false;
    return simpleOutline(glyph, @intCast(nc), .{}, sink);
}
