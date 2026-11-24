//! Shaping driver in the manner of HarfBuzz's `hb-ot-shape`: Unicode properties, cluster
//! formation, normalisation, feature plan per (font, script, language, features), GSUB with the
//! shaper's pauses, GPOS and attachment resolution.
//!
//! `comptime complex` selects what is compiled in:
//!  * false: default shaper only (Latin / Greek / Cyrillic / CJK ...), script tag from a tiny
//!    range test, no normalisation, no Unicode tables;
//!  * true: script-specific shapers (Arabic family, Hebrew, Thai / Lao, Indic), mirroring,
//!    HarfBuzz normalisation (compose / decompose against the font).
//!
//! Plans are cached in a `Cache`. The cache is keyed by the font's table addresses, so it may
//! outlive paragraphs: `Paragraph` uses a caller-provided long-lived cache when
//! `ParagraphOptions.shape_cache` is set and otherwise a private one living in its allocator
//! (plans are then rebuilt per paragraph, ~10-40 us per font / script).
const std = @import("std");
const ttf = @import("ttf.zig");
const ot = @import("ot.zig");
const uni = @import("unicode.zig");
const ucd = @import("ucd.zig");
const norm = @import("normalize.zig");
const arabic = @import("shaper_arabic.zig");
const indic = @import("shaper_indic.zig");
const Font = ttf.Font;
const Glyph = ot.Glyph;
const tag = ot.tag;

/// A user feature (`font-feature-settings` entry): value 0 = off, 1 = on, n = alternate n.
pub const FeatureSetting = struct { tag: [4]u8, value: u16 = 1 };

pub const Shaper = enum(u8) { default, arabic, hebrew, thai, indic };

pub const Run = struct {
    /// Script id: `ucd.sc_*` in complex mode, `simple_*` in simple mode.
    script: u8 = 0,
    rtl: bool = false,
    /// BCP 47 language tag ("" = default language system).
    lang: []const u8 = "",
    /// letter-spacing != 0: liga / clig / calt / dlig / hlig are switched off (Blink).
    spaced: bool = false,
    features: []const FeatureSetting = &.{},
};

pub const simple_common: u8 = 0;
pub const simple_latin: u8 = 1;
pub const simple_greek: u8 = 2;
pub const simple_cyrillic: u8 = 3;

/// Script of `cp` for the simple path.
pub fn simpleScript(cp: u21) u8 {
    return switch (cp) {
        'A'...'Z', 'a'...'z', 0xaa, 0xba, 0xc0...0xd6, 0xd8...0xf6, 0xf8...0x2b8, 0x1e00...0x1eff, 0x2c60...0x2c7f, 0xa720...0xa7ff, 0xfb00...0xfb06, 0xff21...0xff3a, 0xff41...0xff5a => simple_latin,
        0x370...0x373, 0x375...0x377, 0x37a...0x37d, 0x37f, 0x384, 0x386, 0x388...0x3e1, 0x3f0...0x3ff, 0x1f00...0x1fff => simple_greek,
        0x400...0x484, 0x487...0x52f, 0x1c80...0x1c8f, 0x2de0...0x2dff, 0xa640...0xa69f => simple_cyrillic,
        else => simple_common,
    };
}

fn shaperFor(script: u8) Shaper {
    return switch (script) {
        ucd.sc_arabic, ucd.sc_syriac, ucd.sc_nko, ucd.sc_mandaic => .arabic,
        ucd.sc_hebrew => .hebrew,
        ucd.sc_thai, ucd.sc_lao => .thai,
        else => if (indic.isIndicScript(script)) .indic else .default,
    };
}

fn isRtlScript(script: u8) bool {
    return switch (script) {
        ucd.sc_arabic, ucd.sc_hebrew, ucd.sc_syriac, ucd.sc_nko, ucd.sc_mandaic => true,
        else => false,
    };
}

/// Reverses the order of the clusters, keeping the glyph order inside each cluster.
fn reverseClusters(b: *ot.Buffer) void {
    const gs = b.g();
    std.mem.reverse(Glyph, gs);
    var i: usize = 0;
    while (i < gs.len) {
        var j = i + 1;
        while (j < gs.len and gs[j].cluster == gs[i].cluster) j += 1;
        std.mem.reverse(Glyph, gs[i..j]);
        i = j;
    }
}

/// Scripts that never take letter-spacing (Blink: cursive scripts).
pub fn isCursiveScript(script: u8) bool {
    return switch (script) {
        ucd.sc_arabic, ucd.sc_syriac, ucd.sc_nko, ucd.sc_mandaic, ucd.sc_mongolian, ucd.sc_phags_pa => true,
        else => false,
    };
}

/// The face's GSUB lists feature `t` for `script` (default language system; DFLT / latn fallback).
pub fn hasGsubFeature(comptime complex: bool, font: *const Font, script: u8, t: u32) bool {
    var tags: [3]u32 = undefined;
    const n = scriptTags(complex, script, &tags);
    return ot.langSysHasFeature(font.gsub, tags[0..n], t);
}

fn scriptTags(comptime complex: bool, script: u8, out: *[3]u32) usize {
    if (!complex) {
        out[0] = switch (script) {
            simple_latin => tag("latn"),
            simple_greek => tag("grek"),
            simple_cyrillic => tag("cyrl"),
            else => return 0,
        };
        return 1;
    }
    if (indic.isIndicScript(script)) {
        out.* = indic.scriptTags(script);
        return 3;
    }
    switch (script) {
        ucd.sc_common, ucd.sc_inherited, ucd.sc_unknown => return 0,
        ucd.sc_hiragana, ucd.sc_katakana => out[0] = tag("kana"),
        ucd.sc_lao => out[0] = tag("lao "),
        ucd.sc_nko => out[0] = tag("nko "),
        else => {
            if (script >= ucd.script_count) return 0;
            const s = ucd.script_iso[@as(usize, script) * 4 ..][0..4];
            out[0] = (@as(u32, s[0] | 0x20) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | s[3];
        },
    }
    return 1;
}

fn hasSub(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// OpenType language tag for a BCP 47 tag (common languages; else the upper-cased 2-3 letter
/// primary subtag padded with a space).
pub fn languageTag(lang: []const u8) u32 {
    if (lang.len < 2) return 0;
    var p: [3]u8 = .{ ' ', ' ', ' ' };
    var n: usize = 0;
    while (n < lang.len and n < 3 and lang[n] != '-' and lang[n] != '_') : (n += 1) p[n] = std.ascii.toLower(lang[n]);
    if (n < lang.len and lang[n] != '-' and lang[n] != '_') return 0;
    const key = (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2];
    const k = struct {
        fn k(comptime s: *const [3]u8) u32 {
            return (@as(u32, s[0]) << 16) | (@as(u32, s[1]) << 8) | s[2];
        }
    }.k;
    const map = [_][2]u32{
        .{ k("en "), tag("ENG ") }, .{ k("vi "), tag("VIT ") }, .{ k("tr "), tag("TRK ") }, .{ k("az "), tag("AZE ") },
        .{ k("ro "), tag("ROM ") }, .{ k("mo "), tag("MOL ") }, .{ k("sr "), tag("SRB ") }, .{ k("mk "), tag("MKD ") },
        .{ k("bg "), tag("BGR ") }, .{ k("ru "), tag("RUS ") }, .{ k("uk "), tag("UKR ") }, .{ k("pl "), tag("PLK ") },
        .{ k("nl "), tag("NLD ") }, .{ k("de "), tag("DEU ") }, .{ k("fr "), tag("FRA ") }, .{ k("es "), tag("ESP ") },
        .{ k("ca "), tag("CAT ") }, .{ k("pt "), tag("PTG ") }, .{ k("it "), tag("ITA ") }, .{ k("el "), tag("ELL ") },
        .{ k("he "), tag("IWR ") }, .{ k("ar "), tag("ARA ") }, .{ k("fa "), tag("FAR ") }, .{ k("ur "), tag("URD ") },
        .{ k("sd "), tag("SND ") }, .{ k("hi "), tag("HIN ") }, .{ k("mr "), tag("MAR ") }, .{ k("ne "), tag("NEP ") },
        .{ k("bn "), tag("BEN ") }, .{ k("th "), tag("THA ") }, .{ k("ja "), tag("JAN ") }, .{ k("ko "), tag("KOR ") },
        .{ k("lt "), tag("LTH ") }, .{ k("kk "), tag("KAZ ") }, .{ k("tt "), tag("TAT ") }, .{ k("crh"), tag("CRT ") },
    };
    for (map) |m| if (m[0] == key) return m[1];
    if (key == k("zh ")) {
        // script / region decide between simplified, traditional and Hong Kong forms
        if (hasSub(lang, "hant") or hasSub(lang, "-tw")) return tag("ZHT ");
        if (hasSub(lang, "-hk") or hasSub(lang, "-mo")) return tag("ZHH ");
        return tag("ZHS ");
    }
    return (@as(u32, std.ascii.toUpper(p[0])) << 24) | (@as(u32, std.ascii.toUpper(p[1])) << 16) | (@as(u32, std.ascii.toUpper(p[2])) << 8) | ' ';
}

const Key = struct {
    gsub: usize,
    gpos: usize,
    data: usize,
    lang: u32,
    feat_hash: u32,
    script: u8,
    flags: u8,

    fn eql(a: Key, b: Key) bool {
        return a.gsub == b.gsub and a.gpos == b.gpos and a.data == b.data and a.lang == b.lang and a.feat_hash == b.feat_hash and a.script == b.script and a.flags == b.flags;
    }
};

const ShapePlan = struct {
    key: Key,
    ot: ot.Plan,
    shaper: Shaper = .default,
    kern_table: bool = false,
    rtlm: u32 = 0,
    arabic_masks: [7]u32 = @splat(0),
    indic: indic.IndicPlan = .{},
};

/// Shape-plan cache. Long-lived use: create one next to the `FontCollection` and pass it via
/// `ParagraphOptions.shape_cache`; call `clear` whenever a font is unregistered (plans hold
/// slices into the font data). Not thread-safe.
pub const Cache = struct {
    alloc: std.mem.Allocator,
    plans: std.ArrayList(ShapePlan) = .empty,
    /// Shaped runs (`shapeCached`), kept when `keep_results`: generated documents repeat the
    /// same labels, headers, footers and boilerplate on every row and page.
    keep_results: bool = false,
    results: std.AutoHashMapUnmanaged(u64, Result) = .empty,
    result_glyphs: usize = 0,
    key_buf: std.ArrayList(u8) = .empty,

    /// A shaped run: the key bytes it was shaped from (`resultKey`) and its output glyphs.
    const Result = struct { key: []const u8, out: []const Shaped };
    /// What a shaped glyph gives its caller (cluster relative to the run's first input glyph).
    const Shaped = struct { gid: u16, cluster: u32, x_adv: i32, x_off: i32, y_off: i32, kern: i32 };
    /// bound of the stored output glyphs (the cache is cleared beyond it)
    const max_result_glyphs = 1 << 18;
    /// runs longer than this are shaped every time (long paragraphs rarely repeat)
    const max_run = 2048;

    pub fn init(alloc: std.mem.Allocator) Cache {
        return .{ .alloc = alloc };
    }
    pub fn clear(c: *Cache) void {
        for (c.plans.items) |*p| p.ot.deinit(c.alloc);
        c.plans.clearRetainingCapacity();
        c.clearResults();
    }
    fn clearResults(c: *Cache) void {
        var it = c.results.valueIterator();
        while (it.next()) |r| {
            c.alloc.free(r.key);
            c.alloc.free(r.out);
        }
        c.results.clearRetainingCapacity();
        c.result_glyphs = 0;
    }
    pub fn deinit(c: *Cache) void {
        c.clear();
        c.plans.deinit(c.alloc);
        c.results.deinit(c.alloc);
        c.key_buf.deinit(c.alloc);
    }

    /// Everything the shaped output of `b` depends on, as bytes (in `key_buf`): the font (its
    /// data and variation instance), the run, and the input glyphs (clusters relative to the
    /// first one's).
    fn resultKey(c: *Cache, comptime complex: bool, font: *const Font, b: *const ot.Buffer, run: Run) ![]const u8 {
        const k = &c.key_buf;
        k.clearRetainingCapacity();
        const in = b.list.items;
        try k.ensureTotalCapacity(c.alloc, 64 + run.lang.len + run.features.len * 6 + in.len * 10 + @as(usize, font.n_axes) * 2);
        const put = struct {
            fn v(list: *std.ArrayList(u8), x: anytype) void {
                list.appendSliceAssumeCapacity(std.mem.asBytes(&x));
            }
        }.v;
        put(k, @as(u8, @intFromBool(complex)));
        put(k, @intFromPtr(font.data.ptr));
        put(k, font.data.len);
        put(k, @as(u8, @intFromBool(font.varied)));
        put(k, font.n_axes);
        for (font.coords[0..font.n_axes]) |cv| put(k, cv);
        put(k, run.script);
        put(k, @as(u8, @intFromBool(run.rtl)));
        put(k, @as(u8, @intFromBool(run.spaced)));
        put(k, @as(u32, @intCast(run.lang.len)));
        k.appendSliceAssumeCapacity(run.lang);
        put(k, @as(u32, @intCast(run.features.len)));
        for (run.features) |f| {
            k.appendSliceAssumeCapacity(&f.tag);
            put(k, f.value);
        }
        const base = in[0].cluster;
        for (in) |g| {
            put(k, @as(u32, g.cp));
            put(k, g.cluster -% base);
            put(k, g.gid);
        }
        return k.items;
    }

    fn get(c: *Cache, comptime complex: bool, font: *const Font, run: Run) !*const ShapePlan {
        var h: u32 = 2166136261;
        for (run.features) |f| {
            for (f.tag) |ch| h = (h ^ ch) *% 16777619;
            h = (h ^ f.value) *% 16777619;
        }
        const lang = languageTag(run.lang);
        const key: Key = .{
            .gsub = @intFromPtr(font.gsub.ptr),
            .gpos = @intFromPtr(font.gpos.ptr),
            .data = @intFromPtr(font.data.ptr) +% font.gsub.len,
            .lang = lang,
            .feat_hash = h,
            .script = run.script,
            .flags = @as(u8, @intFromBool(run.rtl)) | (@as(u8, @intFromBool(run.spaced)) << 1) | (@as(u8, @intFromBool(complex)) << 2),
        };
        for (c.plans.items) |*p| if (p.key.eql(key)) return p;
        // bound the memory of a long-lived cache
        if (c.plans.items.len >= 64) c.clear();
        const sp = try compile(complex, c.alloc, font, run, lang, key);
        try c.plans.append(c.alloc, sp);
        return &c.plans.items[c.plans.items.len - 1];
    }
};

fn compile(comptime complex: bool, alloc: std.mem.Allocator, font: *const Font, run: Run, lang: u32, key: Key) !ShapePlan {
    const R = ot.FeatureReq;
    const G = ot.F_GLOBAL;
    var feats: [96]R = undefined;
    var n: usize = 0;
    const add = struct {
        fn add(list: *[96]R, len: *usize, r: R) void {
            if (len.* < list.len) {
                list[len.*] = r;
                len.* += 1;
            }
        }
    }.add;
    const shaper: Shaper = if (complex) shaperFor(run.script) else .default;
    add(&feats, &n, .{ .tag = tag("rvrn") });
    if (run.rtl) {
        add(&feats, &n, .{ .tag = tag("rtla"), .stage = 1 });
        add(&feats, &n, .{ .tag = tag("rtlm"), .flags = 0, .stage = 1 });
    } else {
        add(&feats, &n, .{ .tag = tag("ltra"), .stage = 1 });
        add(&feats, &n, .{ .tag = tag("ltrm"), .stage = 1 });
    }
    var last: u8 = 1;
    if (complex) switch (shaper) {
        .arabic => {
            const Z = ot.F_MANUAL_ZWJ;
            add(&feats, &n, .{ .tag = tag("ccmp"), .flags = G | Z, .stage = 2 });
            add(&feats, &n, .{ .tag = tag("locl"), .flags = G | Z, .stage = 2 });
            for (arabic.form_tags, 0..) |t, i| add(&feats, &n, .{ .tag = t, .flags = Z, .stage = @intCast(3 + i) });
            add(&feats, &n, .{ .tag = tag("rlig"), .flags = G | Z, .stage = 10 });
            add(&feats, &n, .{ .tag = tag("calt"), .flags = G | Z, .stage = if (run.script == ucd.sc_arabic) 11 else 10 });
            last = 12;
            for ([_]u32{ tag("rclt"), tag("liga"), tag("clig"), tag("mset") }) |t| add(&feats, &n, .{ .tag = t, .flags = G | Z, .stage = last });
        },
        .indic => {
            for (indic.features) |f| add(&feats, &n, f);
            last = indic.stage_final;
        },
        else => {},
    };
    const J = ot.F_MANUAL_JOINERS;
    for ([_]R{
        .{ .tag = tag("abvm") }, .{ .tag = tag("blwm") }, .{ .tag = tag("ccmp") }, .{ .tag = tag("locl") },
        .{ .tag = tag("mark"), .flags = G | J }, .{ .tag = tag("mkmk"), .flags = G | J }, .{ .tag = tag("rlig") },
        .{ .tag = tag("calt") }, .{ .tag = tag("clig") }, .{ .tag = tag("curs") }, .{ .tag = tag("dist") },
        .{ .tag = tag("kern") }, .{ .tag = tag("liga") }, .{ .tag = tag("rclt") },
    }) |f| {
        var r = f;
        r.stage = last;
        add(&feats, &n, r);
    }
    if (complex and shaper == .indic) add(&feats, &n, .{ .tag = tag("liga"), .value = 0, .stage = last });
    if (run.spaced) {
        for ([_]u32{ tag("liga"), tag("clig"), tag("calt"), tag("dlig"), tag("hlig") }) |t| add(&feats, &n, .{ .tag = t, .value = 0, .stage = last });
    }
    var kern_on = true;
    for (run.features) |f| {
        const t = (@as(u32, f.tag[0]) << 24) | (@as(u32, f.tag[1]) << 16) | (@as(u32, f.tag[2]) << 8) | f.tag[3];
        if (t == tag("kern")) kern_on = f.value != 0;
        add(&feats, &n, .{ .tag = t, .value = f.value, .stage = last });
    }
    var tags: [3]u32 = undefined;
    const nt = scriptTags(complex, run.script, &tags);
    var sp: ShapePlan = .{ .key = key, .ot = try ot.compilePlan(alloc, font, tags[0..nt], lang, feats[0..n]), .shaper = shaper };
    sp.kern_table = kern_on and !sp.ot.has_gpos_kern and sp.ot.kern_table.len != 0;
    sp.rtlm = sp.ot.maskOf(tag("rtlm"));
    if (complex) switch (shaper) {
        .arabic => for (arabic.form_tags, 0..) |t, i| {
            sp.arabic_masks[i] = sp.ot.maskOf(t);
        },
        .indic => sp.indic = indic.IndicPlan.create(&sp.ot, font, run.script),
        else => {},
    };
    return sp;
}

/// Hebrew: patah / qamats + sheva / hiriq + meteg-or-below are swapped so that the font's
/// mark positioning sees the order it expects. `normalize.ReorderHook`.
/// HarfBuzz `_hb_ot_shape_fallback_spaces`: a Unicode space the font has no glyph for is drawn with
/// the space glyph (normalize.zig) and given the width its kind asks for (`gl.x_adv` in font units:
/// the space glyph's advance on entry). Characters the font maps itself keep their own advance.
fn fallbackSpace(font: *const Font, gl: *ot.Glyph) void {
    if (font.glyphIndex(gl.cp) != 0) return;
    const upem: i32 = font.units_per_em;
    const em = struct {
        fn div(u: i32, n: i32) i32 {
            return @divTrunc(u + @divTrunc(n, 2), n);
        }
    }.div;
    gl.x_adv = switch (gl.cp) {
        0x2001, 0x2003, 0x3000 => upem,
        0x2000, 0x2002 => em(upem, 2),
        0x2004 => em(upem, 3),
        0x2005 => em(upem, 4),
        0x2009 => em(upem, 5),
        0x2006 => em(upem, 6),
        0x200a => em(upem, 16),
        0x205f => @divTrunc(upem * 4, 18),
        0x2007 => blk: { // figure space: the width of a digit
            var d: u21 = '0';
            while (d <= '9') : (d += 1) {
                const g = font.glyphIndex(d);
                if (g != 0) break :blk font.advanceWidth(g);
            }
            break :blk gl.x_adv;
        },
        0x2008 => blk: { // punctuation space: the width of '.' (or ',')
            const g = if (font.glyphIndex('.') != 0) font.glyphIndex('.') else font.glyphIndex(',');
            break :blk if (g != 0) font.advanceWidth(g) else gl.x_adv;
        },
        0x202f => @divTrunc(gl.x_adv, 2), // narrow no-break space: half a space
        else => gl.x_adv,
    };
}

fn reorderMarksHebrew(b: *ot.Buffer, start: usize, end: usize) void {
    const gs = b.g();
    var i = start + 2;
    while (i < end) : (i += 1) {
        const c0 = gs[i - 2].ccc;
        const c1 = gs[i - 1].ccc;
        const c2 = gs[i].ccc;
        if ((c0 == 20 or c0 == 21) and (c1 == 22 or c1 == 23) and (c2 == 25 or c2 == 220)) {
            b.mergeClusters(i - 1, i + 1);
            std.mem.swap(Glyph, &gs[i - 1], &gs[i]);
            break;
        }
    }
}

/// Thai / Lao: SARA AM is decomposed into NIKHAHIT + SARA AA and the nikhahit moved before any
/// tone marks (HarfBuzz `preprocess_text_thai`; the PUA fallback for GSUB-less fonts is not ported).
fn preprocessThai(b: *ot.Buffer) !void {
    var i: usize = 0;
    while (i < b.g().len) : (i += 1) {
        const u = b.g()[i].cp;
        if ((u & ~@as(u21, 0x80)) != 0x0e33) continue;
        var nik = b.g()[i];
        nik.cp = u - 0x0e33 + 0x0e4d;
        norm.setUnicodeProps(&nik, 0);
        nik.uprops = (nik.uprops & ~Glyph.U_GC) | 1 | Glyph.U_CONTINUATION;
        b.g()[i].cp = u - 1;
        b.g()[i].gid = 0;
        nik.gid = 0;
        norm.setUnicodeProps(&b.g()[i], 0);
        b.g()[i].uprops |= Glyph.U_CONTINUATION;
        try b.insert(i, nik);
        const gs = b.g();
        const end = i + 2;
        var start = i;
        while (start > 0 and isThaiAbove(gs[start - 1].cp)) start -= 1;
        if (start < i) {
            // move the nikhahit to the beginning of the mark sequence
            b.mergeClusters(start, end);
            const t = gs[i];
            std.mem.copyBackwards(Glyph, gs[start + 1 .. i + 1], gs[start..i]);
            gs[start] = t;
        } else if (start > 0) {
            b.mergeClusters(start - 1, end);
        }
        i += 1;
    }
}

fn isThaiAbove(cp: u21) bool {
    const x = cp & ~@as(u21, 0x80);
    return (x >= 0x0e34 and x <= 0x0e37) or (x >= 0x0e47 and x <= 0x0e4e) or x == 0x0e31 or x == 0x0e3b;
}

/// Whether `font` can render `cp` in the current cluster without falling back: it has the
/// glyph, or the character decomposes into glyphs it has, or it composes with the cluster's
/// running starter `starter` (updated). Used by font selection so that fallback agrees with
/// what `shape` will be able to do.
pub fn fontCovers(comptime complex: bool, font: *const Font, starter: *u21, cp: u21) bool {
    if (!complex) return font.glyphIndex(cp) != 0;
    if (uni.isMark(cp)) {
        if (starter.* != 0) {
            if (norm.compose(starter.*, cp)) |c| {
                if (font.glyphIndex(c) != 0) {
                    starter.* = c;
                    return true;
                }
            }
        }
        return font.glyphIndex(cp) != 0;
    }
    starter.* = cp;
    if (font.glyphIndex(cp) != 0) return true;
    // every part of the full decomposition must be there
    var cur = cp;
    var depth: u32 = 0;
    while (depth < 6) : (depth += 1) {
        const d = norm.decompose(cur) orelse return false;
        if (font.glyphIndex(d[1]) == 0) return false;
        if (font.glyphIndex(d[0]) != 0) return true;
        cur = d[0];
    }
    return false;
}

/// Shapes the buffer in place. On entry every glyph has `cp` and `cluster` set (logical order);
/// on return `gid`, `x_adv`, `x_off`, `y_off`, `kern` (font units) are final and the glyphs are
/// still in logical order (an RTL run is NOT reversed).
/// `shape`, the output taken from the cache's stored runs when the same input was shaped before
/// (`Cache.keep_results`): only the fields `Glyph` callers of a shaped run read are set (gid,
/// cluster, advances, offsets, kern).
pub fn shapeCached(comptime complex: bool, cache: *Cache, font: *const Font, b: *ot.Buffer, run: Run) !void {
    const in = b.list.items;
    if (!cache.keep_results or in.len == 0 or in.len > Cache.max_run) return shape(complex, cache, font, b, run);
    const key = try cache.resultKey(complex, font, b, run);
    const h = std.hash.XxHash64.hash(0x5eed, key); // (Wyhash: emulated 128-bit multiplies on wasm32)
    const base = in[0].cluster;
    if (cache.results.get(h)) |r| if (@import("../eql.zig").bytes(r.key, key)) {
        b.rtl = run.rtl;
        b.list.clearRetainingCapacity();
        try b.list.ensureTotalCapacity(b.alloc, r.out.len);
        for (r.out) |o| b.list.appendAssumeCapacity(.{ .gid = o.gid, .cluster = base +% o.cluster, .x_adv = o.x_adv, .x_off = o.x_off, .y_off = o.y_off, .kern = o.kern });
        return;
    };
    try shape(complex, cache, font, b, run);
    const gs = b.list.items;
    if (cache.result_glyphs + gs.len > Cache.max_result_glyphs) cache.clearResults();
    const slot = try cache.results.getOrPut(cache.alloc, h);
    if (slot.found_existing) return; // (a hash collision: the first run keeps the slot)
    errdefer cache.results.removeByPtr(slot.key_ptr);
    const kd = try cache.alloc.dupe(u8, key);
    errdefer cache.alloc.free(kd);
    const out = try cache.alloc.alloc(Cache.Shaped, gs.len);
    for (gs, out) |g, *o| o.* = .{ .gid = g.gid, .cluster = g.cluster -% base, .x_adv = g.x_adv, .x_off = g.x_off, .y_off = g.y_off, .kern = g.kern };
    slot.value_ptr.* = .{ .key = kd, .out = out };
    cache.result_glyphs += gs.len;
}

pub fn shape(comptime complex: bool, cache: *Cache, font: *const Font, b: *ot.Buffer, run: Run) !void {
    if (b.g().len == 0) return;
    const sp = try cache.get(complex, font, run);
    const plan = &sp.ot;
    b.rtl = run.rtl;
    b.begin();

    // Unicode properties and grapheme clusters
    {
        var prev: u21 = 0;
        var pict = false;
        var prev_cluster: u32 = 0;
        var ri_open = false;
        for (b.g(), 0..) |*gl, i| {
            if (complex) {
                norm.setUnicodeProps(gl, prev);
            } else {
                var u: u8 = 0;
                if (gl.cp >= 0x300) {
                    if (uni.isCombining(gl.cp)) u = 1;
                    if (uni.isContinuationSimple(prev, gl.cp)) u |= Glyph.U_CONTINUATION;
                    if (gl.cp == 0x200c) u |= Glyph.U_IGNORABLE | Glyph.U_ZWNJ;
                    if (gl.cp == 0x200d) u |= Glyph.U_IGNORABLE | Glyph.U_ZWJ;
                    if (gl.cp >= 0xfe00 and gl.cp <= 0xfe0f) u |= Glyph.U_IGNORABLE;
                }
                gl.uprops = u;
            }
            // the second of two regional indicators continues the flag
            if (gl.cp >= 0x1f1e6 and gl.cp <= 0x1f1ff) {
                if (ri_open) gl.uprops |= Glyph.U_CONTINUATION;
                ri_open = !ri_open;
            } else ri_open = false;
            if (i != 0 and gl.uprops & Glyph.U_CONTINUATION != 0) gl.cluster = prev_cluster;
            prev_cluster = gl.cluster;
            prev = uni.clusterPrev(complex, &pict, gl.cp);
            gl.mask = ot.global_mask;
        }
    }
    // HarfBuzz `hb_ensure_native_direction`: a run whose direction is not the native one of
    // its script (Latin under an RTL override, Arabic letters forced LTR) is shaped in the
    // native direction on the reversed text.
    var flip = false;
    if (complex) {
        var native_rtl = isRtlScript(run.script);
        if (native_rtl and !run.rtl) {
            // numbers in a right-to-left script are natively left-to-right
            var digit = false;
            var letter = false;
            for (b.g()) |gl| {
                const gc = gl.uprops & Glyph.U_GC;
                if (gc == 6) digit = true;
                if (gc == 5) letter = true;
            }
            if (digit and !letter) native_rtl = false;
        }
        if (native_rtl != run.rtl) {
            flip = true;
            reverseClusters(b);
            b.rtl = native_rtl;
        }
    }
    defer if (flip) std.mem.reverse(Glyph, b.g());
    if (complex and sp.shaper == .thai) try preprocessThai(b);
    if (complex and run.rtl) {
        for (b.g()) |*gl| {
            const m = uni.mirror(gl.cp);
            if (m != gl.cp and font.glyphIndex(m) != 0) {
                gl.cp = m;
                gl.gid = 0;
            } else gl.mask |= sp.rtlm;
        }
    }
    if (complex) {
        const hook: ?norm.ReorderHook = switch (sp.shaper) {
            .arabic => arabic.reorderMarks,
            .hebrew => reorderMarksHebrew,
            else => null,
        };
        try norm.normalize(font, b, if (sp.shaper == .indic) .indic else .composed, hook);
        switch (sp.shaper) {
            .arabic => arabic.setupMasks(b, &sp.arabic_masks),
            .indic => indic.setupMasks(b),
            else => {},
        }
    } else {
        for (b.g()) |*gl| {
            if (gl.gid == 0) gl.gid = font.glyphIndex(gl.cp);
        }
    }

    // GSUB
    ot.substituteStart(plan, b);
    if (plan.gsub.lookups.len != 0 or (complex and sp.shaper == .indic)) {
        var s: usize = 0;
        while (s < ot.max_stages) : (s += 1) {
            ot.substituteStage(plan, font, b, s);
            if (complex and sp.shaper == .indic) {
                if (s == indic.stage_syllables) indic.findSyllables(b);
                if (s == indic.stage_initial) try indic.initialReordering(&sp.indic, plan, b);
                if (s == indic.stage_basic_last) indic.finalReordering(&sp.indic, b);
                if (s == indic.stage_final) break;
            } else if (s + 1 < ot.max_stages and plan.gsub.stage_end[s] == plan.gsub.lookups.len) break;
        }
    }
    // drop untouched ZWJ / ZWNJ
    {
        const gs = b.g();
        var w: usize = 0;
        for (gs) |gl| {
            if (gl.isHiddenIgnorable()) continue;
            gs[w] = gl;
            w += 1;
        }
        b.list.shrinkRetainingCapacity(w);
    }

    // advances + GPOS
    const space_gid = font.glyphIndex(' ');
    for (b.g()) |*gl| {
        gl.x_adv = font.advanceWidth(gl.gid);
        gl.x_off = 0;
        gl.y_off = 0;
        gl.kern = 0;
        gl.attach_chain = 0;
        gl.attach_type = 0;
        if (space_gid != 0 and gl.gid == space_gid and gl.cp != ' ') fallbackSpace(font, gl);
    }
    const has_gpos = plan.gpos_table.len != 0;
    if (plan.gpos.lookups.len != 0) ot.position(plan, font, b);
    if (sp.kern_table) ot.kernTablePairs(plan.kern_table, b);
    if (!(complex and sp.shaper == .indic)) ot.zeroMarkAdvances(b, !has_gpos and !run.rtl);
    ot.finishPositions(b);
}
