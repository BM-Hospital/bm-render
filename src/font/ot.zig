//! OpenType layout engine (GSUB / GPOS / GDEF), modelled on HarfBuzz's `hb-ot-layout`:
//!  * script / language-system selection, feature -> lookup collection in stages (`Plan`);
//!  * GSUB lookup types 1-8 and GPOS lookup types 1-9 over a glyph `Buffer`, with lookup flags
//!    (ignore base / ligature / mark, mark filtering sets, mark attachment classes), GDEF glyph
//!    classes, ligature ids / components for mark-to-ligature, ZWJ / ZWNJ skipping rules,
//!    per-syllable matching and feature masks;
//!  * cursive and mark attachment resolution (`finishPositions`), legacy `kern` table.
//! Everything is bounds-checked: malformed tables yield "lookup does not apply". Device tables
//! are ignored; VariationIndex deltas are applied when the `Font` exposes `itemVariationDelta`.
//!
//! The first section (collectLookups / pairLookup / lookupDigest) is the phase-1 API still used
//! by `ttf.zig`'s `Font.kerning`.
const std = @import("std");
const ttf = @import("ttf.zig");
const tail = ttf.tail;

// Out-of-line bounds-checked readers: the engine has several hundred read sites, inlining the
// checks everywhere costs ~10 KB of wasm for no measurable speed (hot searches use `be16`).
noinline fn rd16(t: []const u8, off: u32) u16 {
    return ttf.rd16(t, off);
}
fn rdi16(t: []const u8, off: u32) i16 {
    return @bitCast(rd16(t, off));
}
noinline fn rd32(t: []const u8, off: u32) u32 {
    return ttf.rd32(t, off);
}
const Font = ttf.Font;

pub inline fn tag(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | s[3];
}

pub const FeatureSel = struct { tag: u32, flag: u16 };

const tag_latn: u32 = tag("latn");
const tag_dflt: u32 = tag("DFLT");

/// Phase-1 helper: collects the lookup indices of the given features from the default LangSys
/// of the `latn` script (else `DFLT`, else the first script). Result is sorted ascending and
/// de-duplicated; `flag` of the selecting feature is OR-ed into the stored index.
pub fn collectLookups(table: []const u8, feats: []const FeatureSel, out: []u16) usize {
    if (table.len < 10) return 0;
    const scripts = tail(table, rd16(table, 4));
    const features = tail(table, rd16(table, 6));
    const n_scripts: u32 = rd16(scripts, 0);
    if (n_scripts == 0) return 0;
    var script_off: u32 = rd16(scripts, 2 + 4);
    var rank: u32 = 0;
    var i: u32 = 0;
    while (i < n_scripts) : (i += 1) {
        const t = rd32(scripts, 2 + i * 6);
        const r: u32 = if (t == tag_latn) 2 else if (t == tag_dflt) 1 else 0;
        if (r > rank) {
            rank = r;
            script_off = rd16(scripts, 2 + i * 6 + 4);
        }
    }
    const script = tail(scripts, script_off);
    var lang_off: u32 = rd16(script, 0);
    if (lang_off == 0) {
        if (rd16(script, 2) == 0) return 0;
        lang_off = rd16(script, 4 + 4);
    }
    const lang = tail(script, lang_off);
    // counts larger than the tables can hold are damage (past the end every index reads 0)
    const n_feat: u32 = @min(rd16(lang, 4), @as(u32, @intCast((lang.len -| 6) / 2)));
    const total_feat: u32 = rd16(features, 0);
    var n: usize = 0;
    // lookup indices visited; real fonts need a few hundred, damaged ones can make every
    // feature record point at the same huge lookup list (quadratic in the table size)
    var budget: u32 = 1 << 16;
    i = 0;
    while (i < n_feat) : (i += 1) {
        const fi: u32 = rd16(lang, 6 + i * 2);
        if (fi >= total_feat) continue;
        const ftag = rd32(features, 2 + fi * 6);
        for (feats) |sel| {
            if (sel.tag != ftag) continue;
            const feat = tail(features, rd16(features, 2 + fi * 6 + 4));
            const nl: u32 = rd16(feat, 2);
            var k: u32 = 0;
            while (k < nl) : (k += 1) {
                if (6 + k * 2 > feat.len) break;
                if (budget == 0) return n;
                budget -= 1;
                const li = rd16(feat, 4 + k * 2);
                if (li > 0x7fff) continue;
                var pos: usize = 0;
                while (pos < n and (out[pos] & 0x7fff) < li) pos += 1;
                if (pos < n and (out[pos] & 0x7fff) == li) {
                    out[pos] &= li | sel.flag;
                    continue;
                }
                if (n >= out.len) continue;
                var m = n;
                while (m > pos) : (m -= 1) out[m] = out[m - 1];
                out[pos] = li | sel.flag;
                n += 1;
            }
        }
    }
    return n;
}

/// Unchecked big-endian u16 load (the caller has validated the range).
inline fn be16(p: [*]const u8, off: usize) u16 {
    return @byteSwap(@as(*align(1) const u16, @ptrCast(p + off)).*);
}

/// Coverage index of `gid`, or null.
pub fn coverage(t: []const u8, gid: u16) ?u32 {
    if (t.len < 4) return null;
    const p = t.ptr;
    const format = be16(p, 0);
    var count: u32 = be16(p, 2);
    var lo: u32 = 0;
    if (format == 1) {
        // the whole array is validated once, the search then reads unchecked
        count = @min(count, @as(u32, @intCast((t.len - 4) / 2)));
        var hi = count;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (be16(p, 4 + mid * 2) < gid) lo = mid + 1 else hi = mid;
        }
        if (lo < count and be16(p, 4 + lo * 2) == gid) return lo;
    } else if (format == 2) {
        count = @min(count, @as(u32, @intCast((t.len - 4) / 6)));
        var hi = count;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (be16(p, 4 + mid * 6 + 2) < gid) lo = mid + 1 else hi = mid;
        }
        const r = 4 + lo * 6;
        if (lo < count and be16(p, r) <= gid)
            return @as(u32, be16(p, r + 4)) + (gid - be16(p, r));
    }
    return null;
}

pub fn classOf(t: []const u8, gid: u16) u16 {
    if (t.len < 4) return 0;
    const format = rd16(t, 0);
    if (format == 1) {
        const start = rd16(t, 2);
        if (gid < start or gid - start >= rd16(t, 4)) return 0;
        return rd16(t, 6 + @as(u32, gid - start) * 2);
    } else if (format == 2) {
        const p = t.ptr;
        const count: u32 = @min(be16(p, 2), @as(u32, @intCast((t.len - 4) / 6)));
        var lo: u32 = 0;
        var hi: u32 = count;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (be16(p, 4 + mid * 6 + 2) < gid) lo = mid + 1 else hi = mid;
        }
        const r = 4 + lo * 6;
        if (lo < count and be16(p, r) <= gid) return be16(p, r + 4);
    }
    return 0;
}

const Lookup = struct { t: []const u8, kind: u16, count: u32, flags: u32 };

fn lookupAt(table: []const u8, index: u16) Lookup {
    const list = tail(table, rd16(table, 8));
    if (index >= rd16(list, 0)) return .{ .t = &.{}, .kind = 0, .count = 0, .flags = 0 };
    const t = tail(list, rd16(list, 2 + @as(u32, index) * 2));
    // a subtable count larger than the lookup can hold is damage: past the end every offset
    // reads 0 and the "subtables" would all re-parse the lookup header
    const count: u32 = @min(rd16(t, 4), @as(u32, @intCast((t.len -| 6) / 2)));
    var flags: u32 = rd16(t, 2);
    if (flags & 0x10 != 0) flags |= @as(u32, rd16(t, 6 + count * 2)) << 16;
    return .{ .t = t, .kind = rd16(t, 0), .count = count, .flags = flags };
}

/// Resolves subtable `i` of a lookup, following extension subtables (`ext_type` 9 for GPOS,
/// 7 for GSUB). Returns the effective lookup type through `kind`.
fn subtable(l: Lookup, i: u32, ext_type: u16, kind: *u16) []const u8 {
    var st = tail(l.t, ttf.rd16(l.t, 6 + i * 2));
    kind.* = l.kind;
    if (l.kind == ext_type) {
        if (rd16(st, 0) != 1) return &.{};
        kind.* = rd16(st, 2);
        if (kind.* == ext_type) return &.{};
        st = tail(st, rd32(st, 4));
    }
    return st;
}

/// Bloom-style glyph set (HarfBuzz "set digest"): a cheap may-contain test that lets the shaper
/// skip lookups that cannot apply to a glyph. Never gives false negatives.
pub const Digest = struct {
    m: [3]u64 = .{ 0, 0, 0 },
    const shifts = [3]u4{ 0, 4, 9 };
    /// May contain every glyph.
    pub const full: Digest = .{ .m = @splat(~@as(u64, 0)) };

    pub inline fn add(d: *Digest, g: u16) void {
        inline for (shifts, 0..) |s, i| d.m[i] |= @as(u64, 1) << @as(u6, @truncate(g >> s));
    }
    /// False only when no glyph can be in both sets.
    pub inline fn mayIntersect(d: *const Digest, o: *const Digest) bool {
        return d.m[0] & o.m[0] != 0 and d.m[1] & o.m[1] != 0 and d.m[2] & o.m[2] != 0;
    }
    pub inline fn mayHave(d: *const Digest, g: u16) bool {
        return (d.m[0] >> @as(u6, @truncate(g))) & (d.m[1] >> @as(u6, @truncate(g >> 4))) & (d.m[2] >> @as(u6, @truncate(g >> 9))) & 1 != 0;
    }
    fn addRange(d: *Digest, a: u16, b: u16) void {
        if (b < a) return;
        for (shifts, 0..) |s, i| {
            const lo: u32 = a >> s;
            const hi: u32 = b >> s;
            if (hi - lo >= 63) {
                d.m[i] = ~@as(u64, 0);
            } else {
                var v = lo;
                while (v <= hi) : (v += 1) d.m[i] |= @as(u64, 1) << @as(u6, @truncate(v));
            }
        }
    }
    /// Adds a coverage table, spending at most `budget.*` entries of work. When the budget runs
    /// out the digest becomes full (may contain anything), which is always correct.
    fn addCoverage(d: *Digest, t: []const u8, budget: *u32) void {
        const format = rd16(t, 0);
        var n: u32 = rd16(t, 2);
        n = @min(n, @as(u32, @intCast(t.len / 2)));
        if (n > budget.*) {
            d.* = full;
            budget.* = 0;
            return;
        }
        budget.* -= n;
        if (format == 1) {
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const g = rd16(t, 4 + i * 2);
                d.addRange(g, g);
            }
        } else if (format == 2) {
            n = @min(n, @as(u32, @intCast(t.len / 6)));
            var i: u32 = 0;
            while (i < n) : (i += 1) d.addRange(rd16(t, 4 + i * 6), rd16(t, 4 + i * 6 + 2));
        }
    }
};

/// Digest of the first-glyph coverages of every subtable of a lookup (`ext_type`: 9 for GPOS,
/// 7 for GSUB).
pub fn lookupDigest(table: []const u8, index: u16, ext_type: u16) Digest {
    var d: Digest = .{};
    const l = lookupAt(table, index);
    var budget: u32 = digest_budget;
    var i: u32 = 0;
    while (i < l.count) : (i += 1) {
        if (budget == 0) return Digest.full;
        const sd = subtableDigest(l, i, ext_type, &budget);
        for (&d.m, sd.m) |*a, b| a.* |= b;
    }
    return d;
}

/// Coverage entries a digest computation may visit (per lookup for `lookupDigest`, per table for
/// a shape plan). Damaged fonts can make many lookups x subtables point at the same large
/// coverage table (cubic in the font size); real fonts stay far below this.
const digest_budget: u32 = 1 << 20;

fn subtableDigest(l: Lookup, i: u32, ext_type: u16, budget: *u32) Digest {
    if (budget.* == 0) return Digest.full;
    budget.* -= 1;
    var d: Digest = .{};
    var kind: u16 = 0;
    const st = subtable(l, i, ext_type, &kind);
    const format = rd16(st, 0);
    var cov: u32 = 2;
    // (chained) context format 3 keeps its first input coverage elsewhere
    const ctx: u16 = if (ext_type == 7) 5 else 7;
    if (format == 3 and kind == ctx + 1) {
        cov = 4 + @as(u32, rd16(st, 2)) * 2 + 2;
    } else if (format == 3 and kind == ctx) {
        cov = 6;
    }
    d.addCoverage(tail(st, rd16(st, cov)), budget);
    return d;
}

pub const PairAdjust = struct { adv1: i32 = 0, place1: i32 = 0, adv2: i32 = 0, place2: i32 = 0 };

inline fn valueSize(format: u16) u32 {
    return @as(u32, @popCount(format)) * 2;
}

fn readValue(t: []const u8, off: u32, format: u16, place: *i32, adv: *i32) void {
    var o = off;
    if (format & 1 != 0) {
        place.* += rdi16(t, o);
        o += 2;
    }
    if (format & 2 != 0) o += 2;
    if (format & 4 != 0) adv.* += rdi16(t, o);
}

/// Phase-1 helper: applies one GPOS pair lookup to (left, right), accumulating into `r`.
pub fn pairLookup(gpos: []const u8, index: u16, left: u16, right: u16, r: *PairAdjust) void {
    const l = lookupAt(gpos, index);
    var i: u32 = 0;
    while (i < l.count) : (i += 1) {
        var kind: u16 = 0;
        const st = subtable(l, i, 9, &kind);
        if (kind != 2 or st.len < 10) continue;
        const format = rd16(st, 0);
        const ci = coverage(tail(st, rd16(st, 2)), left) orelse continue;
        const vf1 = rd16(st, 4);
        const vf2 = rd16(st, 6);
        const s1 = valueSize(vf1);
        const s2 = valueSize(vf2);
        if (format == 1) {
            const p = pairSetFind(st, ci, right, s1 + s2) orelse continue;
            const set = tail(st, rd16(st, 10 + ci * 2));
            readValue(set, p + 2, vf1, &r.place1, &r.adv1);
            readValue(set, p + 2 + s1, vf2, &r.place2, &r.adv2);
            return;
        } else if (format == 2) {
            const p = pairClassFind(st, left, right, s1 + s2) orelse continue;
            readValue(st, p, vf1, &r.place1, &r.adv1);
            readValue(st, p + s1, vf2, &r.place2, &r.adv2);
            return;
        }
    }
}

/// PairPos format 1: offset (inside the pair set) of the record for `right`.
fn pairSetFind(st: []const u8, ci: u32, right: u16, vsize: u32) ?u32 {
    if (ci >= rd16(st, 8)) return null;
    const set = tail(st, rd16(st, 10 + ci * 2));
    if (set.len < 2) return null;
    const rec = 2 + vsize;
    // records validated once, then searched with unchecked reads
    const count: u32 = @min(be16(set.ptr, 0), @as(u32, @intCast((set.len - 2) / rec)));
    var lo: u32 = 0;
    var hi: u32 = count;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (be16(set.ptr, 2 + mid * rec) < right) lo = mid + 1 else hi = mid;
    }
    const p = 2 + lo * rec;
    if (lo >= count or be16(set.ptr, p) != right) return null;
    return p;
}

/// PairPos format 2: offset (inside the subtable) of the class pair record.
fn pairClassFind(st: []const u8, left: u16, right: u16, vsize: u32) ?u32 {
    const c1: u32 = classOf(tail(st, rd16(st, 8)), left);
    const c2: u32 = classOf(tail(st, rd16(st, 10)), right);
    const n1: u32 = rd16(st, 12);
    const n2: u32 = rd16(st, 14);
    if (c1 >= n1 or c2 >= n2) return null;
    const p = 16 +| (c1 * n2 + c2) *| vsize;
    if (p > st.len or vsize > st.len - p) return null;
    return p;
}

// ==========================================================================================
// Full engine
// ==========================================================================================

/// Returns the sfnt table `t` of the face `f` was parsed from (empty if absent). Used for tables
/// `Font` does not keep a slice of (GDEF).
pub fn findTable(f: *const Font, t: u32) []const u8 {
    const data = f.data;
    var n_dirs: u32 = 1;
    var ttc = false;
    if (rd32(data, 0) == tag("ttcf")) {
        ttc = true;
        n_dirs = @min(rd32(data, 8), 4096);
    }
    var d: u32 = 0;
    while (d < n_dirs) : (d += 1) {
        const dir: u32 = if (ttc) rd32(data, 12 +| d *| 4) else 0;
        const num: u32 = rd16(data, dir +| 4);
        var found: []const u8 = &.{};
        var is_face = !ttc;
        var i: u32 = 0;
        while (i < num) : (i += 1) {
            const rec = dir +| 12 +| i * 16;
            const off = rd32(data, rec +| 8);
            const len = rd32(data, rec +| 12);
            if (off > data.len or len > data.len - off) continue;
            const tg = rd32(data, rec);
            if (tg == t) found = data[off..][0..len];
            // a .ttc face is identified by its hmtx / head slices
            if (tg == tag("head") and f.head.len != 0 and data[off..].ptr == f.head.ptr) is_face = true;
        }
        if (is_face) return found;
    }
    return &.{};
}

pub const Gdef = struct {
    classes: []const u8 = &.{},
    mark_attach: []const u8 = &.{},
    mark_sets: []const u8 = &.{},
    table: []const u8 = &.{},

    pub fn init(t: []const u8) Gdef {
        if (t.len < 12 or rd16(t, 0) != 1) return .{};
        var g: Gdef = .{ .table = t };
        if (rd16(t, 4) != 0) g.classes = tail(t, rd16(t, 4));
        if (rd16(t, 10) != 0) g.mark_attach = tail(t, rd16(t, 10));
        if (rd16(t, 2) >= 2 and t.len >= 14 and rd16(t, 12) != 0) g.mark_sets = tail(t, rd16(t, 12));
        return g;
    }
    pub inline fn hasClasses(g: *const Gdef) bool {
        return g.classes.len != 0;
    }
    /// Glyph props (class bit + mark attachment class in the high byte).
    pub fn propsMemo(g: *const Gdef, b: *Buffer, gid: u16) u16 {
        return switch (b.cls(g.classes, gid)) {
            1 => Glyph.BASE,
            2 => Glyph.LIGATURE,
            3 => Glyph.MARK | (classOf(g.mark_attach, gid) << 8),
            else => 0,
        };
    }
    pub fn props(g: *const Gdef, gid: u16) u16 {
        return switch (classOf(g.classes, gid)) {
            1 => Glyph.BASE,
            2 => Glyph.LIGATURE,
            3 => Glyph.MARK | (classOf(g.mark_attach, gid) << 8),
            else => 0,
        };
    }
    fn markSetCovers(g: *const Gdef, set: u32, gid: u16) bool {
        const t = g.mark_sets;
        if (rd16(t, 0) != 1 or set >= rd16(t, 2)) return false;
        return coverage(tail(t, rd32(t, 4 + set * 4)), gid) != null;
    }
};

pub const Glyph = struct {
    gid: u16 = 0,
    /// GDEF class bits + substitution history; mark attachment class in the high byte.
    props: u16 = 0,
    /// Index of the first source character (into the paragraph's character array).
    cluster: u32 = 0,
    cp: u21 = 0,
    mask: u32 = 0,
    /// lig_id << 5 | IS_LIG_BASE | (component count | component index).
    lig: u8 = 0,
    syllable: u8 = 0,
    /// Unicode props: coarse general category (bits 0-2) + U_* flags.
    uprops: u8 = 0,
    /// (HarfBuzz-modified) canonical combining class.
    ccc: u8 = 0,
    /// Shaper scratch: Arabic joining action / Indic category and position.
    cat: u8 = 0,
    pos: u8 = 0,
    attach_type: u8 = 0,
    attach_chain: i16 = 0,
    x_adv: i32 = 0,
    x_off: i32 = 0,
    y_off: i32 = 0,
    /// Part of `x_adv` contributed by pair positioning with the FOLLOWING glyph.
    kern: i32 = 0,

    pub const BASE: u16 = 0x02;
    pub const LIGATURE: u16 = 0x04;
    pub const MARK: u16 = 0x08;
    pub const SUBSTITUTED: u16 = 0x10;
    pub const LIGATED: u16 = 0x20;
    pub const MULTIPLIED: u16 = 0x40;
    const PRESERVE: u16 = 0x70;

    pub const U_GC: u8 = 0x07;
    pub const U_IGNORABLE: u8 = 0x08;
    pub const U_ZWNJ: u8 = 0x10;
    pub const U_ZWJ: u8 = 0x20;
    pub const U_CONTINUATION: u8 = 0x40;

    const IS_LIG_BASE: u8 = 0x10;

    pub inline fn isMark(g: *const Glyph) bool {
        return g.props & MARK != 0;
    }
    pub inline fn ligated(g: *const Glyph) bool {
        return g.props & LIGATED != 0;
    }
    pub inline fn multiplied(g: *const Glyph) bool {
        return g.props & MULTIPLIED != 0;
    }
    pub inline fn ligatedAndDidntMultiply(g: *const Glyph) bool {
        return g.props & (LIGATED | MULTIPLIED) == LIGATED;
    }
    inline fn ligId(g: *const Glyph) u8 {
        return g.lig >> 5;
    }
    inline fn ligComp(g: *const Glyph) u8 {
        return if (g.lig & IS_LIG_BASE != 0) 0 else g.lig & 0x0f;
    }
    inline fn ligNumComps(g: *const Glyph) u8 {
        return if (g.props & LIGATURE != 0 and g.lig & IS_LIG_BASE != 0) g.lig & 0x0f else 1;
    }
    /// Default-ignorable (ZWJ / ZWNJ) that no substitution has touched.
    pub inline fn isHiddenIgnorable(g: *const Glyph) bool {
        return g.uprops & U_IGNORABLE != 0 and g.props & SUBSTITUTED == 0;
    }
};

/// Direct-mapped memo of coverage / class lookups. Text repeats the same few dozen glyphs, so
/// most of the binary searches of the hot lookups (kerning, ccmp ligatures, GDEF classes) are
/// answered from here. Keyed by table address + glyph, so it stays valid across runs and fonts.
const Memo = struct {
    ptr: usize = 0,
    gid: u16 = 0,
    val: u32 = 0,
};
const memo_size = 256;

pub const Buffer = struct {
    alloc: std.mem.Allocator,
    memo: [memo_size]Memo = @splat(.{}),
    list: std.ArrayList(Glyph) = .empty,
    rtl: bool = false,
    serial: u8 = 0,
    /// Upper bound for the glyph count (guards against expansion bombs).
    max_len: usize = 0,
    /// Work budget for nested lookups.
    ops: i32 = 0,
    has_attach: bool = false,
    /// Set whenever a substitution changes a glyph id or the glyph count.
    changed: bool = false,

    pub fn deinit(b: *Buffer) void {
        b.list.deinit(b.alloc);
    }
    pub inline fn g(b: *Buffer) []Glyph {
        return b.list.items;
    }
    pub fn reset(b: *Buffer, rtl: bool) void {
        b.list.clearRetainingCapacity();
        b.rtl = rtl;
        b.serial = 0;
        b.has_attach = false;
    }
    /// Call once the input glyphs are in place.
    pub fn begin(b: *Buffer) void {
        const n = b.list.items.len;
        b.max_len = n * 8 + 64;
        b.ops = @intCast(@min(n * 1024 + 16384, 0x3fff_ffff));
    }
    inline fn memoSlot(b: *Buffer, t: []const u8, gid: u16) *Memo {
        const h = (@intFromPtr(t.ptr) >> 1) ^ (@as(usize, gid) *% 0x9e37);
        return &b.memo[h & (memo_size - 1)];
    }
    /// Memoized `coverage`.
    pub fn cov(b: *Buffer, t: []const u8, gid: u16) ?u32 {
        if (t.len == 0) return null;
        const m = b.memoSlot(t, gid);
        if (m.ptr != @intFromPtr(t.ptr) or m.gid != gid) {
            m.* = .{ .ptr = @intFromPtr(t.ptr), .gid = gid, .val = coverage(t, gid) orelse 0xffff_ffff };
        }
        return if (m.val == 0xffff_ffff) null else m.val;
    }
    /// Memoized `classOf` (class definitions and coverages never share an address).
    pub fn cls(b: *Buffer, t: []const u8, gid: u16) u16 {
        if (t.len == 0) return 0;
        const m = b.memoSlot(t, gid);
        if (m.ptr != @intFromPtr(t.ptr) or m.gid != gid) {
            m.* = .{ .ptr = @intFromPtr(t.ptr), .gid = gid, .val = classOf(t, gid) };
        }
        return @truncate(m.val);
    }
    fn allocLigId(b: *Buffer) u8 {
        b.serial +%= 1;
        if (b.serial & 7 == 0) b.serial +%= 1;
        return b.serial & 7;
    }
    /// Merges the clusters of glyphs [start, end) to their minimum.
    pub fn mergeClusters(b: *Buffer, start: usize, end_in: usize) void {
        const gs = b.list.items;
        const end = @min(end_in, gs.len);
        if (end <= start + 1) return;
        var c = gs[start].cluster;
        for (gs[start + 1 .. end]) |x| c = @min(c, x.cluster);
        // extend to whole clusters on both sides (HarfBuzz keeps clusters monotonic)
        var e = end;
        while (e < gs.len and gs[e].cluster == gs[e - 1].cluster) e += 1;
        var s = start;
        while (s > 0 and gs[s - 1].cluster == gs[s].cluster) s -= 1;
        for (gs[s..e]) |*x| x.cluster = c;
    }
    pub fn remove(b: *Buffer, i: usize) void {
        b.changed = true;
        _ = b.list.orderedRemove(i);
    }
    pub fn insert(b: *Buffer, i: usize, gl: Glyph) !void {
        if (b.list.items.len >= b.max_len) return error.OutOfMemory;
        try b.list.insert(b.alloc, i, gl);
    }
};

// ---------------------------------------------------------------------------- plan

pub const F_GLOBAL: u8 = 1;
pub const F_MANUAL_ZWNJ: u8 = 2;
pub const F_MANUAL_ZWJ: u8 = 4;
pub const F_PER_SYLLABLE: u8 = 8;
pub const F_MANUAL_JOINERS: u8 = F_MANUAL_ZWNJ | F_MANUAL_ZWJ;

/// A requested feature: enabled for all glyphs (`F_GLOBAL`, `value` 0 turns it off, values > 1
/// select an alternate) or driven by a per-glyph mask the shaper sets (`Plan.maskOf`).
pub const FeatureReq = struct { tag: u32, flags: u8 = F_GLOBAL, stage: u8 = 0, value: u16 = 1 };

pub const max_stages = 24;
const max_features = 64;
pub const global_mask: u32 = 1;

pub const LookupRef = struct {
    index: u16,
    /// LF_* flags.
    flags: u8,
    /// Alternate index for AlternateSubst (feature value).
    alt: u8,
    mask: u32,
    digest: Digest,
    /// Per-subtable digests: `TablePlan.sub_digests[sub_start..][0..sub_count]` (0 = not kept).
    sub_start: u32 = 0,
    sub_count: u16 = 0,

    pub const AUTO_ZWNJ: u8 = 1;
    pub const AUTO_ZWJ: u8 = 2;
    pub const PER_SYLLABLE: u8 = 4;
};

pub const FeatureInfo = struct { tag: u32, mask: u32, stage: u8 };

pub const TablePlan = struct {
    lookups: []LookupRef = &.{},
    sub_digests: []Digest = &.{},
    /// lookups[stage_end[s-1] .. stage_end[s]] belong to stage s.
    stage_end: [max_stages]u16 = @splat(0),
    script_tag: u32 = 0,
    found_script: bool = false,

    pub fn stage(p: *const TablePlan, s: usize) []const LookupRef {
        if (s >= max_stages) return &.{};
        const a: usize = if (s == 0) 0 else p.stage_end[s - 1];
        return p.lookups[a..p.stage_end[s]];
    }
};

/// Feature -> lookup map of one (font, script, language, feature set) combination.
pub const Plan = struct {
    gsub: TablePlan = .{},
    gpos: TablePlan = .{},
    gsub_table: []const u8 = &.{},
    gpos_table: []const u8 = &.{},
    kern_table: []const u8 = &.{},
    gdef: Gdef = .{},
    feats: [max_features]FeatureInfo = undefined,
    n_feats: u8 = 0,
    /// GPOS has a `kern` / `mark` feature for the selected script.
    has_gpos_kern: bool = false,
    has_gpos_mark: bool = false,

    /// Mask of a found feature (the global bit for global features), 0 when the font has none.
    pub fn maskOf(p: *const Plan, t: u32) u32 {
        for (p.feats[0..p.n_feats]) |f| if (f.tag == t) return f.mask;
        return 0;
    }
    /// GSUB lookups of feature `t` (requires the feature to be alone in its stage, or global
    /// there). Used for would-substitute queries.
    pub fn featureLookups(p: *const Plan, t: u32) []const LookupRef {
        for (p.feats[0..p.n_feats]) |f| if (f.tag == t) return p.gsub.stage(f.stage);
        return &.{};
    }
    pub fn deinit(p: *Plan, alloc: std.mem.Allocator) void {
        alloc.free(p.gsub.sub_digests);
        alloc.free(p.gsub.lookups);
        alloc.free(p.gpos.sub_digests);
        alloc.free(p.gpos.lookups);
    }
};

const LangSys = struct { t: []const u8 = &.{}, features: []const u8 = &.{} };

fn selectLangSys(table: []const u8, script_tags: []const u32, lang: u32, tp: *TablePlan) LangSys {
    if (table.len < 10) return .{};
    const scripts = tail(table, rd16(table, 4));
    const n: u32 = rd16(scripts, 0);
    var script: []const u8 = &.{};
    const fallbacks = [_]u32{ tag("DFLT"), tag("dflt"), tag("latn") };
    var pass: usize = 0;
    outer: while (pass < script_tags.len + fallbacks.len) : (pass += 1) {
        const want = if (pass < script_tags.len) script_tags[pass] else fallbacks[pass - script_tags.len];
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (2 + i * 6 + 6 > scripts.len) break;
            if (rd32(scripts, 2 + i * 6) == want) {
                script = tail(scripts, rd16(scripts, 2 + i * 6 + 4));
                tp.script_tag = want;
                tp.found_script = pass < script_tags.len;
                break :outer;
            }
        }
    }
    if (script.len == 0) return .{};
    var off: u32 = rd16(script, 0);
    if (lang != 0) {
        const nl: u32 = rd16(script, 2);
        var i: u32 = 0;
        while (i < nl) : (i += 1) {
            if (4 + i * 6 + 6 > script.len) break;
            if (rd32(script, 4 + i * 6) == lang) {
                off = rd16(script, 4 + i * 6 + 4);
                break;
            }
        }
    }
    if (off == 0) return .{};
    return .{ .t = tail(script, off), .features = tail(table, rd16(table, 6)) };
}

/// Feature table with tag `t` in the language system, or null.
fn findFeature(ls: LangSys, t: u32) ?[]const u8 {
    const n: u32 = rd16(ls.t, 4);
    const total: u32 = rd16(ls.features, 0);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (6 + i * 2 + 2 > ls.t.len) break;
        const fi: u32 = rd16(ls.t, 6 + i * 2);
        if (fi >= total) continue;
        if (rd32(ls.features, 2 + fi * 6) == t) return tail(ls.features, rd16(ls.features, 2 + fi * 6 + 4));
    }
    return null;
}

/// The default language system of the first of `script_tags`, DFLT, dflt, latn that the table has
/// lists feature `t` (Blink `OpenTypeCapsSupport::SupportsOpenTypeFeature`).
pub fn langSysHasFeature(table: []const u8, script_tags: []const u32, t: u32) bool {
    var tp: TablePlan = .{};
    const ls = selectLangSys(table, script_tags, 0, &tp);
    if (ls.t.len < 6) return false;
    return findFeature(ls, t) != null;
}

const Merged = struct { tag: u32, flags: u8, stage: u8, value: u16, mask: u32 = 0, found: bool = false };

/// Compiles a plan. `feats` are processed in order; a later entry with the same tag overrides
/// the value / global-ness of an earlier one (user features go last) but keeps the earlier
/// stage. `script_tags` are tried in order, then `DFLT`, `dflt`, `latn`.
pub fn compilePlan(alloc: std.mem.Allocator, font: *const Font, script_tags: []const u32, lang: u32, feats: []const FeatureReq) !Plan {
    var p: Plan = .{ .gsub_table = font.gsub, .gpos_table = font.gpos, .kern_table = font.kern };
    p.gdef = Gdef.init(if (@hasField(Font, "gdef")) font.gdef else findTable(font, tag("GDEF")));

    var merged: [max_features]Merged = undefined;
    var nm: usize = 0;
    for (feats) |f| {
        var j: usize = 0;
        while (j < nm and merged[j].tag != f.tag) j += 1;
        if (j == nm) {
            if (nm == max_features) continue;
            merged[nm] = .{ .tag = f.tag, .flags = f.flags, .stage = f.stage, .value = f.value };
            nm += 1;
        } else {
            // HarfBuzz: the first occurrence keeps its flags and stage, a later one decides
            // global-ness and value
            if (f.flags & F_GLOBAL != 0) {
                merged[j].flags |= F_GLOBAL;
                merged[j].value = f.value;
            } else {
                merged[j].flags &= ~F_GLOBAL;
                merged[j].value = @max(merged[j].value, f.value);
            }
        }
    }
    const ls_sub = selectLangSys(p.gsub_table, script_tags, lang, &p.gsub);
    const ls_pos = selectLangSys(p.gpos_table, script_tags, lang, &p.gpos);
    // allocate mask bits: non-global features found in either table get their own bit
    var next_bit: u5 = 1;
    for (merged[0..nm]) |*m| {
        m.found = findFeature(ls_sub, m.tag) != null or findFeature(ls_pos, m.tag) != null;
        if (!m.found or m.value == 0) continue;
        if (m.flags & F_GLOBAL != 0) {
            m.mask = global_mask;
        } else if (next_bit < 31) {
            m.mask = @as(u32, 1) << next_bit;
            next_bit += 1;
        }
        p.feats[p.n_feats] = .{ .tag = m.tag, .mask = m.mask, .stage = m.stage };
        p.n_feats += 1;
    }
    try compileTable(alloc, &p.gsub, p.gsub_table, ls_sub, merged[0..nm], 7);
    errdefer {
        alloc.free(p.gsub.sub_digests);
        alloc.free(p.gsub.lookups);
    }
    try compileTable(alloc, &p.gpos, p.gpos_table, ls_pos, merged[0..nm], 9);
    for (merged[0..nm]) |m| {
        if (m.mask == 0) continue;
        if (m.tag == tag("kern") and findFeature(ls_pos, m.tag) != null) p.has_gpos_kern = true;
        if (m.tag == tag("mark") and findFeature(ls_pos, m.tag) != null) p.has_gpos_mark = true;
    }
    return p;
}

fn compileTable(alloc: std.mem.Allocator, tp: *TablePlan, table: []const u8, ls: LangSys, merged: []const Merged, ext: u16) !void {
    var list: std.ArrayList(LookupRef) = .empty;
    errdefer list.deinit(alloc);
    const n_lookups: u32 = rd16(tail(table, rd16(table, 8)), 0);
    var stage: u8 = 0;
    while (stage < max_stages) : (stage += 1) {
        const first = list.items.len;
        if (stage == 0 and ls.t.len >= 4) {
            // required feature
            const req: u32 = rd16(ls.t, 2);
            if (req != 0xffff and req < rd16(ls.features, 0))
                try addFeatureLookups(alloc, &list, tail(ls.features, rd16(ls.features, 2 + req * 6 + 4)), n_lookups, global_mask, 0, 1);
        }
        for (merged) |m| {
            if (m.stage != stage or m.mask == 0) continue;
            const ft = findFeature(ls, m.tag) orelse continue;
            var fl: u8 = 0;
            if (m.flags & F_MANUAL_ZWNJ == 0) fl |= LookupRef.AUTO_ZWNJ;
            if (m.flags & F_MANUAL_ZWJ == 0) fl |= LookupRef.AUTO_ZWJ;
            if (m.flags & F_PER_SYLLABLE != 0) fl |= LookupRef.PER_SYLLABLE;
            try addFeatureLookups(alloc, &list, ft, n_lookups, m.mask, fl, @intCast(@min(m.value, 255)));
        }
        // sort by lookup index, merge duplicates
        const items = list.items[first..];
        // insertion sort (feature lookup lists are short and mostly ascending; std.mem.sort
        // would cost several KB of wasm)
        for (1..@max(items.len, 1)) |r| {
            const it = items[r];
            var k = r;
            while (k > 0 and items[k - 1].index > it.index) : (k -= 1) items[k] = items[k - 1];
            items[k] = it;
        }
        var w: usize = 0;
        for (items, 0..) |it, r| {
            if (r != 0 and items[w - 1].index == it.index) {
                items[w - 1].mask |= it.mask;
                items[w - 1].flags = (items[w - 1].flags & it.flags & 3) | ((items[w - 1].flags | it.flags) & LookupRef.PER_SYLLABLE);
            } else {
                items[w] = it;
                w += 1;
            }
        }
        list.shrinkRetainingCapacity(first + w);
        if (list.items.len > 0xffff) return error.OutOfMemory;
        tp.stage_end[stage] = @intCast(list.items.len);
    }
    var subs: std.ArrayList(Digest) = .empty;
    errdefer subs.deinit(alloc);
    var budget: u32 = digest_budget;
    for (list.items) |*it| {
        if (budget == 0) {
            it.digest = Digest.full;
            continue;
        }
        const l = lookupAt(table, it.index);
        const keep = l.count >= 2 and l.count <= 512;
        if (keep) it.sub_start = @intCast(subs.items.len);
        var i: u32 = 0;
        while (i < l.count) : (i += 1) {
            const sd = subtableDigest(l, i, ext, &budget);
            for (&it.digest.m, sd.m) |*a, b| a.* |= b;
            if (keep) try subs.append(alloc, sd);
        }
        if (keep) it.sub_count = @intCast(l.count);
    }
    tp.sub_digests = try subs.toOwnedSlice(alloc);
    errdefer alloc.free(tp.sub_digests);
    tp.lookups = try list.toOwnedSlice(alloc);
}

fn addFeatureLookups(alloc: std.mem.Allocator, list: *std.ArrayList(LookupRef), ft: []const u8, n_lookups: u32, mask: u32, flags: u8, alt: u8) !void {
    const nl: u32 = rd16(ft, 2);
    var k: u32 = 0;
    while (k < nl) : (k += 1) {
        if (6 + k * 2 > ft.len) break;
        const li = rd16(ft, 4 + k * 2);
        if (li >= n_lookups) continue;
        try list.append(alloc, .{ .index = li, .flags = flags, .alt = alt, .mask = mask, .digest = .{} });
    }
}

// ---------------------------------------------------------------------------- matching

const max_context = 64;
const max_nesting = 6;

const IGNORE_FLAGS: u32 = 0x0e;
const LF_RTL: u32 = 0x01;
const LF_USE_MARK_SET: u32 = 0x10;
const LF_MARK_ATTACH: u32 = 0xff00;

const MatchKind = enum { glyph, class, coverage };

/// How a sequence of u16 values in the font matches glyphs.
const Seq = struct {
    kind: MatchKind = .glyph,
    /// Values (count entries of u16) start here.
    vals: []const u8 = &.{},
    /// Class definition table, or the base the coverage offsets are relative to.
    data: []const u8 = &.{},

    inline fn matches(s: Seq, k: u32, gid: u16) bool {
        const v = rd16(s.vals, k * 2);
        return switch (s.kind) {
            .glyph => gid == v,
            .class => classOf(s.data, gid) == v,
            .coverage => coverage(tail(s.data, v), gid) != null,
        };
    }
};

const Ctx = struct {
    b: *Buffer,
    table: []const u8,
    gdef: *const Gdef,
    font: *const Font,
    is_gpos: bool,
    mask: u32 = 0,
    auto_zwnj: bool = true,
    auto_zwj: bool = true,
    per_syllable: bool = false,
    alt: u8 = 1,
    /// Lookup flags | mark filtering set << 16 of the lookup being applied.
    props: u32 = 0,
    nesting: u8 = 0,
    idx: usize = 0,
    /// Subtable digests of the top-level lookup being applied (empty for nested lookups).
    subs: []const Digest = &.{},

    fn checkProps(c: *const Ctx, gl: *const Glyph, props: u32) bool {
        const gp: u32 = gl.props;
        if (gp & props & IGNORE_FLAGS != 0) return false;
        if (gp & Glyph.MARK != 0) {
            if (props & LF_USE_MARK_SET != 0) return c.gdef.markSetCovers(props >> 16, gl.gid);
            if (props & LF_MARK_ATTACH != 0) return (props & LF_MARK_ATTACH) == (gp & LF_MARK_ATTACH);
        }
        return true;
    }

    const Skip = enum { no, yes, maybe };

    fn maySkip(c: *const Ctx, gl: *const Glyph, props: u32, context: bool) Skip {
        if (!c.checkProps(gl, props)) return .yes;
        if (gl.isHiddenIgnorable()) {
            const ignore_zwnj = c.is_gpos or (context and c.auto_zwnj);
            const ignore_zwj = context or c.auto_zwj;
            if ((ignore_zwnj or gl.uprops & Glyph.U_ZWNJ == 0) and (ignore_zwj or gl.uprops & Glyph.U_ZWJ == 0)) return .maybe;
        }
        return .no;
    }

    const M = enum { match, not_match, skip };

    /// `seq == null`: any glyph matches ("maybe").
    fn match(c: *const Ctx, gl: *const Glyph, props: u32, context: bool, syllable: u8, seq: ?Seq, k: u32) M {
        // fast path: nothing to skip (no ignore flag hit, no mark filter in play, visible)
        const skip: Skip = if (gl.props & props & IGNORE_FLAGS == 0 and (gl.props & Glyph.MARK == 0 or props & (LF_USE_MARK_SET | LF_MARK_ATTACH) == 0) and gl.uprops & Glyph.U_IGNORABLE == 0) .no else c.maySkip(gl, props, context);
        if (skip == .yes) return .skip;
        const mask_ok = (context or gl.mask & c.mask != 0) and (syllable == 0 or syllable == gl.syllable);
        if (mask_ok) {
            if (seq) |s| {
                if (s.matches(k, gl.gid)) return .match;
            } else if (skip == .no) return .match;
        }
        return if (skip == .no) .not_match else .skip;
    }

    inline fn syl(c: *const Ctx, i: usize) u8 {
        return if (!c.is_gpos and c.per_syllable) c.b.g()[i].syllable else 0;
    }

    /// Next non-skipped glyph after `from` (input-style matching, no value test).
    fn next(c: *const Ctx, from: usize, props: u32) ?usize {
        const gs = c.b.g();
        var i = from + 1;
        while (i < gs.len) : (i += 1) {
            switch (c.match(&gs[i], props, false, 0, null, 0)) {
                .match => return i,
                .not_match => return null,
                .skip => {},
            }
        }
        return null;
    }
    fn prev(c: *const Ctx, from: usize, props: u32) ?usize {
        const gs = c.b.g();
        var i = from;
        while (i > 0) {
            i -= 1;
            switch (c.match(&gs[i], props, false, 0, null, 0)) {
                .match => return i,
                .not_match => return null,
                .skip => {},
            }
        }
        return null;
    }

    /// Matches `count` input glyphs starting at c.idx (the first is taken as matched); the
    /// remaining count-1 against `seq`. Fills `pos`, returns the position after the match.
    fn matchInput(c: *const Ctx, count: u32, seq: Seq, pos: *[max_context]u32, total_comps: ?*u32) ?usize {
        if (count == 0 or count > max_context) return null;
        const gs = c.b.g();
        const first = &gs[c.idx];
        pos[0] = @intCast(c.idx);
        const syllable = c.syl(c.idx);
        const first_id = first.ligId();
        const first_comp = first.ligComp();
        var comps: u32 = first.ligNumComps();
        var ligbase: enum { unchecked, may_not, may } = .unchecked;
        var i: usize = c.idx;
        var k: u32 = 1;
        while (k < count) : (k += 1) {
            i += 1;
            while (true) : (i += 1) {
                if (i >= gs.len) return null;
                switch (c.match(&gs[i], c.props, false, syllable, seq, k - 1)) {
                    .match => break,
                    .not_match => return null,
                    .skip => {},
                }
            }
            pos[k] = @intCast(i);
            if (total_comps != null) {
                const this_id = gs[i].ligId();
                const this_comp = gs[i].ligComp();
                if (first_id != 0 and first_comp != 0) {
                    // all components must hang off the same ligature component ...
                    if (first_id != this_id or first_comp != this_comp) {
                        // ... unless that ligature is itself skippable
                        if (ligbase == .unchecked) {
                            var found = false;
                            var j: usize = c.idx;
                            while (j > 0 and gs[j - 1].ligId() == first_id) {
                                j -= 1;
                                if (gs[j].ligComp() == 0) {
                                    found = true;
                                    break;
                                }
                            }
                            ligbase = if (found and c.maySkip(&gs[j], c.props, false) == .yes) .may else .may_not;
                        }
                        if (ligbase == .may_not) return null;
                    }
                } else if (this_id != 0 and this_comp != 0 and this_id != first_id) return null;
                comps += gs[i].ligNumComps();
            }
        }
        if (total_comps) |tc| tc.* = comps;
        return i + 1;
    }

    fn matchBack(c: *const Ctx, count: u32, seq: Seq) bool {
        const gs = c.b.g();
        const sy = c.syl(c.idx);
        var i: usize = c.idx;
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            while (true) {
                if (i == 0) return false;
                i -= 1;
                switch (c.match(&gs[i], c.props, true, sy, seq, k)) {
                    .match => break,
                    .not_match => return false,
                    .skip => {},
                }
            }
        }
        return true;
    }

    fn matchAhead(c: *const Ctx, count: u32, seq: Seq, start: usize) bool {
        const gs = c.b.g();
        // HarfBuzz quirk: the lookahead is confined to the syllable only for 1-glyph inputs
        const sy = if (start == c.idx + 1) c.syl(c.idx) else 0;
        var i: usize = start;
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            while (true) : (i += 1) {
                if (i >= gs.len) return false;
                switch (c.match(&gs[i], c.props, true, sy, seq, k)) {
                    .match => break,
                    .not_match => return false,
                    .skip => {},
                }
            }
            i += 1;
        }
        return true;
    }

    /// Sets a glyph after substitution, refreshing its GDEF class (HarfBuzz `_set_glyph_class`).
    fn setGlyph(c: *const Ctx, gl: *Glyph, gid: u16, class_guess: u16, ligature: bool, component: bool) void {
        var p = gl.props | Glyph.SUBSTITUTED;
        if (ligature) {
            p |= Glyph.LIGATED;
            p &= ~Glyph.MULTIPLIED;
        }
        if (component) p |= Glyph.MULTIPLIED;
        if (c.gdef.hasClasses()) {
            p = (p & Glyph.PRESERVE) | c.gdef.propsMemo(c.b, gid);
        } else if (class_guess != 0) {
            p = (p & Glyph.PRESERVE) | class_guess;
        }
        gl.props = p;
        gl.gid = gid;
        c.b.changed = true;
    }

    // ------------------------------------------------------------------ nested lookups

    /// Applies the SequenceLookupRecords of a matched context (HarfBuzz `apply_lookup`).
    fn applyRecords(c: *Ctx, count_in: u32, pos: *[max_context]u32, recs: []const u8, nrec: u32, match_end: usize) void {
        if (c.nesting >= max_nesting) {
            c.idx = match_end;
            return;
        }
        var count: i32 = @intCast(count_in);
        var end: i32 = @intCast(match_end);
        var r: u32 = 0;
        while (r < nrec) : (r += 1) {
            if (r * 4 + 4 > recs.len) break;
            const si: i32 = rd16(recs, r * 4);
            if (si >= count) continue;
            const s: usize = @intCast(si);
            const orig_len: i32 = @intCast(c.b.g().len);
            if (pos[s] >= orig_len) continue;
            c.b.ops -= 1;
            if (c.b.ops <= 0) break;
            const saved_props = c.props;
            c.idx = pos[s];
            c.nesting += 1;
            const applied = c.applyLookupAt(rd16(recs, r * 4 + 2));
            c.nesting -= 1;
            c.props = saved_props;
            if (!applied) continue;
            const new_len: i32 = @intCast(c.b.g().len);
            var delta = new_len - orig_len;
            if (delta == 0) continue;
            end += delta;
            if (end < @as(i32, @intCast(pos[s]))) {
                delta += @as(i32, @intCast(pos[s])) - end;
                end = @intCast(pos[s]);
            }
            var nxt: i32 = si + 1;
            if (delta > 0) {
                if (delta + count > max_context) break;
            } else {
                delta = @max(delta, nxt - count);
                nxt -= delta;
            }
            // shift
            const cnt: usize = @intCast(count);
            const nx: usize = @intCast(nxt);
            if (delta > 0) {
                var j: usize = cnt;
                while (j > nx) {
                    j -= 1;
                    pos[j + @as(usize, @intCast(delta))] = pos[j];
                }
            } else {
                var j: usize = nx;
                while (j < cnt) : (j += 1) pos[@intCast(@as(i32, @intCast(j)) + delta)] = pos[j];
            }
            nxt += delta;
            count += delta;
            var j: usize = s + 1;
            while (j < @as(usize, @intCast(nxt))) : (j += 1) pos[j] = pos[j - 1] + 1;
            j = @intCast(nxt);
            while (j < @as(usize, @intCast(count))) : (j += 1) pos[j] = @intCast(@as(i32, @intCast(pos[j])) + delta);
        }
        c.idx = @intCast(@max(end, 0));
        if (c.idx > c.b.g().len) c.idx = c.b.g().len;
    }

    /// Applies lookup `index` at c.idx (first matching subtable). Used for nested lookups.
    fn applyLookupAt(c: *Ctx, index: u16) bool {
        const l = lookupAt(c.table, index);
        c.props = l.flags;
        const saved = c.subs;
        c.subs = &.{};
        defer c.subs = saved;
        return c.applySubtables(l);
    }

    fn applySubtables(c: *Ctx, l: Lookup) bool {
        const gid = c.b.g()[c.idx].gid;
        var s: u32 = 0;
        while (s < l.count) : (s += 1) {
            if (s < c.subs.len and !c.subs[s].mayHave(gid)) continue;
            var kind: u16 = 0;
            const st = subtable(l, s, if (c.is_gpos) 9 else 7, &kind);
            if (st.len < 4) continue;
            const ok = if (c.is_gpos) c.applyPos(kind, st) else (c.applySub(kind, st) catch false);
            if (ok) return true;
        }
        return false;
    }

    /// Context (GSUB 5 / GPOS 7) and chained context (GSUB 6 / GPOS 8), all formats.
    fn applyContext(c: *Ctx, st: []const u8, chained: bool) bool {
        const gs = c.b.g();
        const gid = gs[c.idx].gid;
        const format = rd16(st, 0);
        var pos: [max_context]u32 = undefined;
        if (format == 3) {
            var nb: u32 = 0;
            var in_off: u32 = 2;
            if (chained) {
                nb = rd16(st, 2);
                in_off = 4 + nb * 2;
            }
            const ni: u32 = rd16(st, in_off);
            if (ni == 0) return false;
            var nla: u32 = 0;
            var nrec: u32 = undefined;
            var rec_off: u32 = undefined;
            const in_vals = in_off + (if (chained) @as(u32, 2) else 4);
            if (chained) {
                const la_off = in_vals + ni * 2;
                nla = rd16(st, la_off);
                nrec = rd16(st, la_off + 2 + nla * 2);
                rec_off = la_off + 4 + nla * 2;
                if (c.b.cov(tail(st, rd16(st, in_vals)), gid) == null) return false;
                const end = c.matchInput(ni, .{ .kind = .coverage, .vals = tail(st, in_vals + 2), .data = st }, &pos, null) orelse return false;
                if (!c.matchBack(nb, .{ .kind = .coverage, .vals = tail(st, 4), .data = st })) return false;
                if (!c.matchAhead(nla, .{ .kind = .coverage, .vals = tail(st, la_off + 2), .data = st }, end)) return false;
                c.applyRecords(ni, &pos, tail(st, rec_off), nrec, end);
                return true;
            }
            nrec = rd16(st, 4);
            rec_off = in_vals + ni * 2;
            if (coverage(tail(st, rd16(st, in_vals)), gid) == null) return false;
            const end = c.matchInput(ni, .{ .kind = .coverage, .vals = tail(st, in_vals + 2), .data = st }, &pos, null) orelse return false;
            c.applyRecords(ni, &pos, tail(st, rec_off), nrec, end);
            return true;
        }
        if (format != 1 and format != 2) return false;
        const ci = c.b.cov(tail(st, rd16(st, 2)), gid) orelse return false;
        var kind: MatchKind = .glyph;
        var cd_back: []const u8 = &.{};
        var cd_in: []const u8 = &.{};
        var cd_ahead: []const u8 = &.{};
        var set_index: u32 = ci;
        var sets_off: u32 = 4;
        if (format == 2) {
            kind = .class;
            if (chained) {
                cd_back = tail(st, rd16(st, 4));
                cd_in = tail(st, rd16(st, 6));
                cd_ahead = tail(st, rd16(st, 8));
                sets_off = 10;
            } else {
                cd_in = tail(st, rd16(st, 4));
                sets_off = 6;
            }
            set_index = classOf(cd_in, gid);
        }
        if (set_index >= rd16(st, sets_off)) return false;
        const so = rd16(st, sets_off + 2 + set_index * 2);
        if (so == 0) return false;
        const set = tail(st, so);
        const nrules: u32 = rd16(set, 0);
        var r: u32 = 0;
        while (r < nrules) : (r += 1) {
            const ro = rd16(set, 2 + r * 2);
            if (ro == 0) continue;
            const rule = tail(set, ro);
            if (rule.len < 4) continue;
            if (chained) {
                const nb: u32 = rd16(rule, 0);
                const ni: u32 = rd16(rule, 2 + nb * 2);
                if (ni == 0) continue;
                const la_off = 4 + nb * 2 + (ni - 1) * 2;
                const nla: u32 = rd16(rule, la_off);
                const rec_off = la_off + 2 + nla * 2;
                if (rec_off + 2 > rule.len) continue;
                const end = c.matchInput(ni, .{ .kind = kind, .vals = tail(rule, 4 + nb * 2), .data = cd_in }, &pos, null) orelse continue;
                if (!c.matchBack(nb, .{ .kind = kind, .vals = tail(rule, 2), .data = cd_back })) continue;
                if (!c.matchAhead(nla, .{ .kind = kind, .vals = tail(rule, la_off + 2), .data = cd_ahead }, end)) continue;
                c.applyRecords(ni, &pos, tail(rule, rec_off + 2), rd16(rule, rec_off), end);
                return true;
            } else {
                const ni: u32 = rd16(rule, 0);
                if (ni == 0) continue;
                const end = c.matchInput(ni, .{ .kind = kind, .vals = tail(rule, 4), .data = cd_in }, &pos, null) orelse continue;
                c.applyRecords(ni, &pos, tail(rule, 4 + (ni - 1) * 2), rd16(rule, 2), end);
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------ GSUB

    fn applySub(c: *Ctx, kind: u16, st: []const u8) !bool {
        const b = c.b;
        const gs = b.g();
        const gl = &gs[c.idx];
        const gid = gl.gid;
        const format = ttf.rd16(st, 0);
        switch (kind) {
            1 => {
                const ci = b.cov(tail(st, rd16(st, 2)), gid) orelse return false;
                var out: u16 = undefined;
                if (format == 1) {
                    out = gid +% rd16(st, 4);
                } else if (format == 2 and ci < rd16(st, 4)) {
                    out = rd16(st, 6 + ci * 2);
                } else return false;
                c.setGlyph(gl, out, 0, false, false);
                c.idx += 1;
                return true;
            },
            2 => {
                if (format != 1) return false;
                const ci = coverage(tail(st, rd16(st, 2)), gid) orelse return false;
                if (ci >= rd16(st, 4)) return false;
                const seq = tail(st, rd16(st, 6 + ci * 2));
                const n: u32 = rd16(seq, 0);
                if (2 + n * 2 > seq.len) return false;
                if (n == 1) {
                    c.setGlyph(gl, rd16(seq, 2), 0, false, false);
                    c.idx += 1;
                    return true;
                }
                if (n == 0) {
                    b.remove(c.idx);
                    return true;
                }
                if (gs.len + n - 1 > b.max_len) return false;
                const klass: u16 = if (gl.props & Glyph.LIGATURE != 0) Glyph.BASE else 0;
                const attached = gl.ligId() != 0;
                const proto = gl.*;
                var k: u32 = 0;
                while (k < n) : (k += 1) {
                    if (k != 0) try b.list.insert(b.alloc, c.idx + k, proto);
                    const x = &b.g()[c.idx + k];
                    // if attached to a ligature, don't disturb that
                    if (!attached) x.lig = @intCast(@min(k, 15));
                    c.setGlyph(x, rd16(seq, 2 + k * 2), klass, false, true);
                }
                c.idx += n;
                return true;
            },
            3 => {
                if (format != 1) return false;
                const ci = coverage(tail(st, rd16(st, 2)), gid) orelse return false;
                if (ci >= rd16(st, 4)) return false;
                const set = tail(st, rd16(st, 6 + ci * 2));
                const n: u32 = rd16(set, 0);
                if (c.alt == 0 or c.alt > n) return false;
                c.setGlyph(gl, rd16(set, 2 + (@as(u32, c.alt) - 1) * 2), 0, false, false);
                c.idx += 1;
                return true;
            },
            4 => {
                if (format != 1) return false;
                const ci = b.cov(tail(st, ttf.rd16(st, 2)), gid) orelse return false;
                if (ci >= rd16(st, 4)) return false;
                const set = tail(st, rd16(st, 6 + ci * 2));
                const nl: u32 = rd16(set, 0);
                var pos: [max_context]u32 = undefined;
                // fast reject on the second component (HarfBuzz does the same): valid when
                // the next glyph is one no ligature could skip over
                // (HarfBuzz matches "always" here: a skippable-maybe glyph such as ZWJ, which
                // a ligature may list as a component, stops the fast path)
                var second: u32 = 0x1_0000;
                {
                    var j = c.idx + 1;
                    while (j < gs.len and c.maySkip(&gs[j], c.props, false) == .yes) j += 1;
                    if (j < gs.len and c.maySkip(&gs[j], c.props, false) == .no) second = gs[j].gid;
                }
                var k: u32 = 0;
                while (k < nl) : (k += 1) {
                    const lig = tail(set, rd16(set, 2 + k * 2));
                    const nc: u32 = rd16(lig, 2);
                    if (nc == 0 or lig.len < 4) continue;
                    if (nc >= 2 and second != 0x1_0000 and rd16(lig, 4) != second) continue;
                    if (nc == 1) {
                        c.setGlyph(gl, rd16(lig, 0), 0, false, false);
                        c.idx += 1;
                        return true;
                    }
                    var total: u32 = 0;
                    const end = c.matchInput(nc, .{ .kind = .glyph, .vals = tail(lig, 4) }, &pos, &total) orelse continue;
                    c.ligate(nc, &pos, end, rd16(lig, 0), total);
                    return true;
                }
                return false;
            },
            5 => return c.applyContext(st, false),
            6 => return c.applyContext(st, true),
            8 => {
                if (format != 1 or c.nesting != 0) return false;
                const ci = coverage(tail(st, rd16(st, 2)), gid) orelse return false;
                const nb: u32 = rd16(st, 4);
                const la_off = 6 + nb * 2;
                const nla: u32 = rd16(st, la_off);
                const sub_off = la_off + 2 + nla * 2;
                if (ci >= rd16(st, sub_off)) return false;
                if (!c.matchBack(nb, .{ .kind = .coverage, .vals = tail(st, 6), .data = st })) return false;
                if (!c.matchAhead(nla, .{ .kind = .coverage, .vals = tail(st, la_off + 2), .data = st }, c.idx + 1)) return false;
                c.setGlyph(gl, rd16(st, sub_off + 2 + ci * 2), 0, false, false);
                return true;
            },
            else => return false,
        }
    }

    /// HarfBuzz `ligate_input`: replaces the first component with the ligature, removes the
    /// others and renumbers the ligature components of the marks in between / after.
    fn ligate(c: *Ctx, count: u32, pos: *[max_context]u32, end: usize, lig_gid: u16, total_comps: u32) void {
        const b = c.b;
        const gs = b.g();
        const first = &gs[pos[0]];
        var is_base_lig = first.props & Glyph.BASE != 0;
        var is_mark_lig = first.isMark();
        var k: u32 = 1;
        while (k < count) : (k += 1) {
            if (!gs[pos[k]].isMark()) {
                is_base_lig = false;
                is_mark_lig = false;
                break;
            }
        }
        const is_lig = !is_base_lig and !is_mark_lig;
        const klass: u16 = if (is_lig) Glyph.LIGATURE else 0;
        const lig_id: u8 = if (is_lig) b.allocLigId() else 0;
        var last_id = first.ligId();
        var last_n: u32 = first.ligNumComps();
        var so_far: u32 = last_n;
        if (is_lig) {
            first.lig = (lig_id << 5) | Glyph.IS_LIG_BASE | @as(u8, @intCast(@min(total_comps, 15)));
            if (first.uprops & Glyph.U_GC == 1) first.uprops &= ~Glyph.U_GC; // Mn -> other
        }
        c.setGlyph(first, lig_gid, klass, true, false);
        b.mergeClusters(pos[0], end);

        k = 1;
        var i: usize = pos[0] + 1;
        while (k < count) : (k += 1) {
            while (i < pos[k]) : (i += 1) {
                if (is_lig) {
                    var this_comp: u32 = gs[i].ligComp();
                    if (this_comp == 0) this_comp = last_n;
                    const new_comp = so_far - last_n + @min(this_comp, last_n);
                    gs[i].lig = (lig_id << 5) | @as(u8, @intCast(@min(new_comp, 15)));
                }
            }
            last_id = gs[i].ligId();
            last_n = gs[i].ligNumComps();
            so_far += last_n;
            i += 1; // the component itself
        }
        if (!is_mark_lig and last_id != 0) {
            // re-adjust components of any marks following
            var j = i;
            while (j < gs.len) : (j += 1) {
                if (gs[j].ligId() != last_id) break;
                const this_comp: u32 = gs[j].ligComp();
                if (this_comp == 0) break;
                const new_comp = so_far - last_n + @min(this_comp, last_n);
                gs[j].lig = (lig_id << 5) | @as(u8, @intCast(@min(new_comp, 15)));
            }
        }
        // remove components back to front
        k = count;
        while (k > 1) {
            k -= 1;
            b.remove(pos[k]);
        }
        c.idx = end - (count - 1);
    }

    // ------------------------------------------------------------------ GPOS

    fn deviceDelta(c: *const Ctx, base: []const u8, off: u16) i32 {
        if (off == 0 or !@hasDecl(Font, "itemVariationDelta")) return 0;
        const d = tail(base, off);
        if (rd16(d, 4) != 0x8000 or c.gdef.table.len < 18) return 0;
        const delta = c.font.itemVariationDelta(c.gdef.table, rd32(c.gdef.table, 14), rd16(d, 0), rd16(d, 2));
        return @intFromFloat(@round(std.math.clamp(delta, -30000.0, 30000.0)));
    }

    /// Applies a value record located at `t[off..]`; device offsets are relative to `base`.
    fn applyValue(c: *const Ctx, base: []const u8, t: []const u8, off: u32, format: u16, gl: *Glyph) i32 {
        var o = off;
        var xa: i32 = 0;
        var v: [4]i32 = .{ 0, 0, 0, 0 };
        for (0..4) |k| {
            if (format & (@as(u16, 1) << @intCast(k)) != 0) {
                v[k] = rdi16(t, o);
                o += 2;
            }
        }
        for (0..4) |k| {
            if (format & (@as(u16, 0x10) << @intCast(k)) != 0) {
                v[k] += c.deviceDelta(base, rd16(t, o));
                o += 2;
            }
        }
        gl.x_off += v[0];
        gl.y_off += v[1];
        xa = v[2];
        gl.x_adv += xa;
        return xa;
    }

    const Pt = struct { x: i32, y: i32 };

    fn anchor(c: *const Ctx, t: []const u8) Pt {
        var p: Pt = .{ .x = rdi16(t, 2), .y = rdi16(t, 4) };
        if (rd16(t, 0) == 3) {
            p.x += c.deviceDelta(t, rd16(t, 6));
            p.y += c.deviceDelta(t, rd16(t, 8));
        }
        return p;
    }

    /// MarkArray application shared by mark-to-base / ligature / mark.
    fn attachMark(c: *Ctx, st: []const u8, mark_index: u32, base_anchor_t: []const u8, target: usize) bool {
        const marks = tail(st, rd16(st, 8));
        if (mark_index >= rd16(marks, 0) or base_anchor_t.len < 6) return false;
        const ma = c.anchor(tail(marks, rd16(marks, 2 + mark_index * 4 + 2)));
        const ba = c.anchor(base_anchor_t);
        const gl = &c.b.g()[c.idx];
        gl.x_off = ba.x - ma.x;
        gl.y_off = ba.y - ma.y;
        gl.attach_type = 1;
        gl.attach_chain = @intCast(std.math.clamp(@as(i64, @intCast(target)) - @as(i64, @intCast(c.idx)), -32768, 32767));
        c.b.has_attach = true;
        c.idx += 1;
        return true;
    }

    fn markClass(st: []const u8, mark_index: u32) u32 {
        const marks = tail(st, rd16(st, 8));
        return rd16(marks, 2 + mark_index * 4);
    }

    fn applyPos(c: *Ctx, kind: u16, st: []const u8) bool {
        const b = c.b;
        const gs = b.g();
        const gl = &gs[c.idx];
        const gid = gl.gid;
        const format = rd16(st, 0);
        switch (kind) {
            1 => {
                const ci = coverage(tail(st, rd16(st, 2)), gid) orelse return false;
                const vf = rd16(st, 4);
                if (format == 1) {
                    _ = c.applyValue(st, st, 6, vf, gl);
                } else if (format == 2 and ci < rd16(st, 6)) {
                    _ = c.applyValue(st, st, 8 + ci * valueSize(vf), vf, gl);
                } else return false;
                c.idx += 1;
                return true;
            },
            2 => {
                if (st.len < 10) return false;
                const ci = b.cov(tail(st, ttf.rd16(st, 2)), gid) orelse return false;
                const j = c.next(c.idx, c.props) orelse return false;
                const vf1 = rd16(st, 4);
                const vf2 = rd16(st, 6);
                const s1 = valueSize(vf1);
                const s2 = valueSize(vf2);
                if (format == 1) {
                    const p = pairSetFind(st, ci, gs[j].gid, s1 + s2) orelse return false;
                    const set = tail(st, rd16(st, 10 + ci * 2));
                    gl.kern += c.applyValue(set, set, p + 2, vf1, gl);
                    _ = c.applyValue(set, set, p + 2 + s1, vf2, &gs[j]);
                } else if (format == 2) {
                    // class pair record (memoized class lookups)
                    const c1: u32 = b.cls(tail(st, rd16(st, 8)), gid);
                    const c2: u32 = b.cls(tail(st, rd16(st, 10)), gs[j].gid);
                    const n2: u32 = rd16(st, 14);
                    if (c1 >= rd16(st, 12) or c2 >= n2) return false;
                    const p = 16 +| (c1 * n2 + c2) *| (s1 + s2);
                    if (p > st.len or s1 + s2 > st.len - p) return false;
                    gl.kern += c.applyValue(st, st, p, vf1, gl);
                    _ = c.applyValue(st, st, p + s1, vf2, &gs[j]);
                } else return false;
                c.idx = if (vf2 != 0) j + 1 else j;
                return true;
            },
            3 => {
                if (format != 1) return false;
                const ci = coverage(tail(st, rd16(st, 2)), gid) orelse return false;
                if (ci >= rd16(st, 4)) return false;
                const entry_off = rd16(st, 6 + ci * 4);
                if (entry_off == 0) return false;
                const i = c.prev(c.idx, c.props) orelse return false;
                const pi = coverage(tail(st, rd16(st, 2)), gs[i].gid) orelse return false;
                if (pi >= rd16(st, 4)) return false;
                const exit_off = rd16(st, 6 + pi * 4 + 2);
                if (exit_off == 0) return false;
                const ex = c.anchor(tail(st, exit_off));
                const en = c.anchor(tail(st, entry_off));
                const j = c.idx;
                if (!b.rtl) {
                    gs[i].x_adv = ex.x + gs[i].x_off;
                    const d = en.x + gs[j].x_off;
                    gs[j].x_adv -= d;
                    gs[j].x_off -= d;
                } else {
                    const d = ex.x + gs[i].x_off;
                    gs[i].x_adv -= d;
                    gs[i].x_off -= d;
                    gs[j].x_adv = en.x + gs[j].x_off;
                }
                var child = i;
                var parent = j;
                var y_offset = en.y - ex.y;
                if (c.props & LF_RTL == 0) {
                    child = j;
                    parent = i;
                    y_offset = -y_offset;
                }
                reverseCursive(gs, child, parent, 0);
                gs[child].attach_type = 2;
                gs[child].attach_chain = @intCast(std.math.clamp(@as(i64, @intCast(parent)) - @as(i64, @intCast(child)), -32768, 32767));
                b.has_attach = true;
                gs[child].y_off = y_offset;
                if (gs[parent].attach_chain == -gs[child].attach_chain) {
                    gs[parent].attach_chain = 0;
                    gs[parent].y_off = 0;
                }
                c.idx += 1;
                return true;
            },
            4, 5 => {
                if (format != 1) return false;
                const mi = coverage(tail(st, rd16(st, 2)), gid) orelse return false;
                const base_cov = tail(st, rd16(st, 4));
                // search backwards for a non-mark glyph
                var j = c.idx;
                var found: ?usize = null;
                while (j > 0) {
                    j -= 1;
                    var m = c.match(&gs[j], 0x08, false, 0, null, 0);
                    if (m == .match and kind == 4 and !acceptBase(gs, j) and coverage(base_cov, gs[j].gid) == null) m = .skip;
                    if (m == .match) {
                        found = j;
                        break;
                    }
                    if (m == .not_match) break;
                }
                const bi = found orelse return false;
                const bidx = coverage(base_cov, gs[bi].gid) orelse return false;
                const class_count: u32 = rd16(st, 6);
                const mc = markClass(st, mi);
                if (mc >= class_count) return false;
                const arr = tail(st, rd16(st, 10));
                if (bidx >= rd16(arr, 0)) return false;
                if (kind == 4) {
                    const ao = rd16(arr, 2 + (bidx * class_count + mc) * 2);
                    if (ao == 0) return false;
                    return c.attachMark(st, mi, tail(arr, ao), bi);
                }
                const lig_attach = tail(arr, rd16(arr, 2 + bidx * 2));
                const comp_count: u32 = rd16(lig_attach, 0);
                if (comp_count == 0) return false;
                const lig_id = gs[bi].ligId();
                const mark_id = gl.ligId();
                const mark_comp: u32 = gl.ligComp();
                const comp_index = if (lig_id != 0 and lig_id == mark_id and mark_comp > 0) @min(comp_count, mark_comp) - 1 else comp_count - 1;
                const ao = rd16(lig_attach, 2 + (comp_index * class_count + mc) * 2);
                if (ao == 0) return false;
                return c.attachMark(st, mi, tail(lig_attach, ao), bi);
            },
            6 => {
                if (format != 1) return false;
                const mi = coverage(tail(st, rd16(st, 2)), gid) orelse return false;
                const j = c.prev(c.idx, c.props & ~IGNORE_FLAGS) orelse return false;
                if (!gs[j].isMark()) return false;
                const id1 = gl.ligId();
                const id2 = gs[j].ligId();
                const comp1 = gl.ligComp();
                const comp2 = gs[j].ligComp();
                const good = if (id1 == id2) (id1 == 0 or comp1 == comp2) else ((id1 > 0 and comp1 == 0) or (id2 > 0 and comp2 == 0));
                if (!good) return false;
                const m2 = coverage(tail(st, rd16(st, 4)), gs[j].gid) orelse return false;
                const class_count: u32 = rd16(st, 6);
                const mc = markClass(st, mi);
                if (mc >= class_count) return false;
                const arr = tail(st, rd16(st, 10));
                if (m2 >= rd16(arr, 0)) return false;
                const ao = rd16(arr, 2 + (m2 * class_count + mc) * 2);
                if (ao == 0) return false;
                return c.attachMark(st, mi, tail(arr, ao), j);
            },
            7 => return c.applyContext(st, false),
            8 => return c.applyContext(st, true),
            else => return false,
        }
    }
};

/// Only the first glyph of a MultipleSubst sequence takes marks (HarfBuzz `accept`).
fn acceptBase(gs: []const Glyph, idx: usize) bool {
    const gl = &gs[idx];
    return !gl.multiplied() or gl.ligComp() == 0 or
        (idx == 0 or gs[idx - 1].isMark() or !gs[idx - 1].multiplied() or
            gl.ligId() != gs[idx - 1].ligId() or gl.ligComp() != gs[idx - 1].ligComp() + 1);
}

fn reverseCursive(gs: []Glyph, i: usize, new_parent: usize, depth: u32) void {
    const chain = gs[i].attach_chain;
    const ty = gs[i].attach_type;
    if (chain == 0 or ty != 2 or depth > 64) return;
    gs[i].attach_chain = 0;
    const jj = @as(i64, @intCast(i)) + chain;
    if (jj < 0 or jj >= gs.len) return;
    const j: usize = @intCast(jj);
    if (j == new_parent) return;
    reverseCursive(gs, j, new_parent, depth + 1);
    gs[j].y_off = -gs[i].y_off;
    gs[j].attach_chain = -chain;
    gs[j].attach_type = ty;
}

// ---------------------------------------------------------------------------- drivers

/// Sets GDEF glyph classes (or synthesises them from the Unicode category when the font has no
/// GDEF class definition) and clears ligature state. Call after cmap mapping, before GSUB.
pub fn substituteStart(plan: *const Plan, b: *Buffer) void {
    const has = plan.gdef.hasClasses();
    for (b.g()) |*gl| {
        gl.lig = 0;
        gl.props = if (has) plan.gdef.propsMemo(b, gl.gid) else if (gl.uprops & Glyph.U_GC == 1 and gl.uprops & Glyph.U_IGNORABLE == 0) Glyph.MARK else Glyph.BASE;
    }
}

fn applyLookup(c: *Ctx, tp: *const TablePlan, ref: *const LookupRef) void {
    const b = c.b;
    if (b.g().len == 0 or ref.mask == 0) return;
    const l = lookupAt(c.table, ref.index);
    if (l.count == 0) return;
    c.mask = ref.mask;
    c.auto_zwnj = ref.flags & LookupRef.AUTO_ZWNJ != 0;
    c.auto_zwj = ref.flags & LookupRef.AUTO_ZWJ != 0;
    c.per_syllable = ref.flags & LookupRef.PER_SYLLABLE != 0;
    c.alt = ref.alt;
    c.props = l.flags;
    c.nesting = 0;
    c.subs = tp.sub_digests[ref.sub_start..][0..ref.sub_count];
    if (!c.is_gpos and l.kind == 8) {
        // reverse chaining: in-place, back to front
        var i = b.g().len;
        while (i > 0) {
            i -= 1;
            const gl = &b.g()[i];
            if (ref.digest.mayHave(gl.gid) and gl.mask & ref.mask != 0 and c.checkProps(gl, l.flags)) {
                c.idx = i;
                _ = c.applySubtables(l);
            }
        }
        return;
    }
    c.idx = 0;
    while (c.idx < b.g().len) {
        const gl = &b.g()[c.idx];
        if (ref.digest.mayHave(gl.gid) and gl.mask & ref.mask != 0 and c.checkProps(gl, l.flags)) {
            const before = c.idx;
            c.props = l.flags;
            if (c.applySubtables(l)) {
                // a deletion leaves idx in place; guard against lookups that do not advance
                if (c.idx == before and b.g().len != 0 and b.ops > 0) {
                    b.ops -= 1;
                    continue;
                }
                if (c.idx <= before) c.idx = before + 1;
                continue;
            }
        }
        c.idx += 1;
    }
}

/// Applies the GSUB lookups of stage `s`.
pub fn substituteStage(plan: *const Plan, font: *const Font, b: *Buffer, s: usize) void {
    const refs = plan.gsub.stage(s);
    if (refs.len == 0) return;
    var c: Ctx = .{ .b = b, .table = plan.gsub_table, .gdef = &plan.gdef, .font = font, .is_gpos = false };
    // digest of the buffer: lookups that cannot touch any glyph are skipped outright. It is
    // refreshed whenever a lookup may have changed glyphs.
    var bd = bufferDigest(b);
    for (refs) |*ref| {
        if (!ref.digest.mayIntersect(&bd)) continue;
        b.changed = false;
        applyLookup(&c, &plan.gsub, ref);
        if (b.changed) bd = bufferDigest(b);
    }
}

fn bufferDigest(b: *Buffer) Digest {
    var d: Digest = .{};
    for (b.g()) |gl| d.add(gl.gid);
    return d;
}

/// Applies every GPOS lookup of the plan (advances must already be set) and resolves
/// attachments. Does nothing about zeroing mark advances: see `zeroMarkAdvances`.
pub fn position(plan: *const Plan, font: *const Font, b: *Buffer) void {
    var c: Ctx = .{ .b = b, .table = plan.gpos_table, .gdef = &plan.gdef, .font = font, .is_gpos = true };
    const bd = bufferDigest(b);
    for (plan.gpos.lookups) |*ref| {
        if (ref.digest.mayIntersect(&bd)) applyLookup(&c, &plan.gpos, ref);
    }
}

/// GDEF marks get a zero advance (`adjust`: keep them hanging over the previous glyph, used
/// when the font has no GPOS).
pub fn zeroMarkAdvances(b: *Buffer, adjust: bool) void {
    for (b.g()) |*gl| {
        if (!gl.isMark()) continue;
        if (adjust) gl.x_off -= gl.x_adv;
        gl.x_adv = 0;
    }
}

/// Turns attachment chains into final offsets (HarfBuzz `position_finish_offsets`).
pub fn finishPositions(b: *Buffer) void {
    if (!b.has_attach) return;
    const gs = b.g();
    for (0..gs.len) |i| propagate(gs, i, b.rtl, 0);
}

fn propagate(gs: []Glyph, i: usize, rtl: bool, depth: u32) void {
    const chain = gs[i].attach_chain;
    const ty = gs[i].attach_type;
    if (chain == 0) return;
    gs[i].attach_chain = 0;
    const jj = @as(i64, @intCast(i)) + chain;
    if (jj < 0 or jj >= gs.len or depth > 64) return;
    const j: usize = @intCast(jj);
    propagate(gs, j, rtl, depth + 1);
    if (ty == 2) {
        gs[i].y_off += gs[j].y_off;
    } else {
        gs[i].x_off += gs[j].x_off;
        gs[i].y_off += gs[j].y_off;
        if (j >= i) return;
        if (!rtl) {
            for (gs[j..i]) |x| gs[i].x_off -= x.x_adv;
        } else {
            for (gs[j + 1 .. i + 1]) |x| gs[i].x_off += x.x_adv;
        }
    }
}

/// Legacy `kern` table (format 0 subtables) applied to adjacent non-mark pairs, split between
/// both glyphs the way HarfBuzz's kern machine does.
pub fn kernTablePairs(kern: []const u8, b: *Buffer) void {
    const gs = b.g();
    if (kern.len < 4 or rd16(kern, 0) != 0) return;
    var i: usize = 0;
    while (i < gs.len) {
        if (gs[i].isMark()) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < gs.len and gs[j].isMark()) j += 1;
        if (j >= gs.len) break;
        const k = kernTableValue(kern, gs[i].gid, gs[j].gid);
        if (k != 0) {
            const k1 = k >> 1;
            const k2 = k - k1;
            gs[i].x_adv += k1;
            gs[i].kern += k1;
            gs[j].x_adv += k2;
            gs[j].x_off += k2;
        }
        i = j;
    }
}

fn kernTableValue(t: []const u8, left: u16, right: u16) i32 {
    const n: u32 = rd16(t, 2);
    const key: u32 = (@as(u32, left) << 16) | right;
    var off: u32 = 4;
    var sum: i32 = 0;
    var i: u32 = 0;
    while (i < n and off + 14 <= t.len) : (i += 1) {
        const len: u32 = rd16(t, off + 2);
        const cov = rd16(t, off + 4);
        if (cov >> 8 == 0 and cov & 0x7 == 1) {
            const avail: u32 = @intCast((t.len - off - 14) / 6);
            var hi: u32 = @min(rd16(t, off + 6), avail);
            var lo: u32 = 0;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (rd32(t, off + 14 + mid * 6) < key) lo = mid + 1 else hi = mid;
            }
            const p = off + 14 + lo * 6;
            if (p + 6 <= t.len and rd32(t, p) == key) sum += rdi16(t, p + 4);
        }
        if (len < 6) break;
        off += len;
    }
    return sum;
}

/// Whether GSUB lookup `index` would substitute the glyph sequence `glyphs` on its own
/// (HarfBuzz `would_substitute`; `zero_context`: chained rules with context do not count).
pub fn wouldSubstitute(gsub: []const u8, index: u16, glyphs: []const u16, zero_context: bool) bool {
    if (glyphs.len == 0) return false;
    const l = lookupAt(gsub, index);
    var s: u32 = 0;
    while (s < l.count) : (s += 1) {
        var kind: u16 = 0;
        const st = subtable(l, s, 7, &kind);
        if (st.len < 6) continue;
        const format = rd16(st, 0);
        const g0 = glyphs[0];
        switch (kind) {
            1, 2, 3 => if (glyphs.len == 1 and coverage(tail(st, rd16(st, 2)), g0) != null) return true,
            4 => {
                const ci = coverage(tail(st, rd16(st, 2)), g0) orelse continue;
                if (ci >= rd16(st, 4)) continue;
                const set = tail(st, rd16(st, 6 + ci * 2));
                const nl: u32 = rd16(set, 0);
                var k: u32 = 0;
                while (k < nl) : (k += 1) {
                    const lig = tail(set, rd16(set, 2 + k * 2));
                    if (rd16(lig, 2) != glyphs.len) continue;
                    var ok = true;
                    for (glyphs[1..], 0..) |gg, m| {
                        if (rd16(lig, 4 + @as(u32, @intCast(m)) * 2) != gg) ok = false;
                    }
                    if (ok) return true;
                }
            },
            5, 6 => {
                const chained = kind == 6;
                if (format == 3) {
                    var in_off: u32 = 2;
                    var nb: u32 = 0;
                    if (chained) {
                        nb = rd16(st, 2);
                        in_off = 4 + nb * 2;
                    }
                    const ni: u32 = rd16(st, in_off);
                    if (ni != glyphs.len) continue;
                    const vals = in_off + (if (chained) @as(u32, 2) else 4);
                    if (chained and zero_context and (nb != 0 or rd16(st, vals + ni * 2) != 0)) continue;
                    var ok = true;
                    for (glyphs, 0..) |gg, m| {
                        if (coverage(tail(st, rd16(st, vals + @as(u32, @intCast(m)) * 2)), gg) == null) ok = false;
                    }
                    if (ok) return true;
                    continue;
                }
                if (format != 1 and format != 2) continue;
                const ci = coverage(tail(st, rd16(st, 2)), g0) orelse continue;
                var cd_in: []const u8 = &.{};
                var sets_off: u32 = 4;
                var set_index = ci;
                if (format == 2) {
                    cd_in = tail(st, rd16(st, if (chained) 6 else 4));
                    sets_off = if (chained) 10 else 6;
                    set_index = classOf(cd_in, g0);
                }
                if (set_index >= rd16(st, sets_off)) continue;
                const so = rd16(st, sets_off + 2 + set_index * 2);
                if (so == 0) continue;
                const set = tail(st, so);
                var r: u32 = 0;
                while (r < rd16(set, 0)) : (r += 1) {
                    const rule = tail(set, rd16(set, 2 + r * 2));
                    var nb: u32 = 0;
                    var ni: u32 = undefined;
                    var vals: u32 = undefined;
                    if (chained) {
                        nb = rd16(rule, 0);
                        ni = rd16(rule, 2 + nb * 2);
                        vals = 4 + nb * 2;
                        if (ni == 0) continue;
                        if (zero_context and (nb != 0 or rd16(rule, vals + (ni - 1) * 2) != 0)) continue;
                    } else {
                        ni = rd16(rule, 0);
                        vals = 4;
                    }
                    if (ni != glyphs.len) continue;
                    var ok = true;
                    for (glyphs[1..], 0..) |gg, m| {
                        const v = rd16(rule, vals + @as(u32, @intCast(m)) * 2);
                        if (if (format == 1) gg != v else classOf(cd_in, gg) != v) ok = false;
                    }
                    if (ok) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

test "digest never has false negatives" {
    var d: Digest = .{};
    d.addRange(10, 20);
    d.addRange(700, 700);
    var g: u16 = 10;
    while (g <= 20) : (g += 1) try std.testing.expect(d.mayHave(g));
    try std.testing.expect(d.mayHave(700));
}

fn put16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .big);
}

fn elapsedMs(io: std.Io, t0: std.Io.Timestamp) i64 {
    return t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
}

test "damaged feature counts stay cheap: collectLookups (fuzz regression)" {
    // GSUB-like table: one `latn` script whose default LangSys claims 0xffff feature records
    // (past the real data they all read feature 0), feature 0 = `kern` with 8000 lookups. This
    // walked 65535 x 8000 lookup indices (seconds); now bounded by the table size and a budget.
    const n_lookups = 8000;
    var buf: [42 + n_lookups * 2]u8 = @splat(0);
    put16(&buf, 0, 1);
    put16(&buf, 4, 10); // script list at 10
    put16(&buf, 6, 30); // feature list at 30
    put16(&buf, 10, 1);
    @memcpy(buf[12..16], "latn");
    put16(&buf, 16, 8); // script at 18
    put16(&buf, 18, 4); // default LangSys at 22
    put16(&buf, 24, 0xffff); // no required feature
    put16(&buf, 26, 0xffff); // feature index count (damaged)
    put16(&buf, 30, 1);
    @memcpy(buf[32..36], "kern");
    put16(&buf, 36, 8); // feature at 38
    put16(&buf, 40, n_lookups);
    for (0..n_lookups) |k| put16(&buf, 42 + k * 2, @intCast(k));
    const io = std.testing.io;
    const t0 = std.Io.Clock.awake.now(io);
    var out: [24]u16 = undefined;
    const n = collectLookups(&buf, &.{.{ .tag = tag("kern"), .flag = 0 }}, &out);
    try std.testing.expectEqual(@as(usize, 24), n);
    try std.testing.expectEqual(@as(u16, 0), out[0]);
    try std.testing.expect(elapsedMs(io, t0) < 1000);
}

test "damaged subtable lists stay cheap: digests (fuzz regression)" {
    // One lookup whose 16000 subtables all point at the same 16000-glyph coverage table: a
    // digest visited 16000 x 16000 coverage entries (seconds); now a budget makes it full.
    const n = 16000;
    const lk = 14; // lookup list at 10 (one entry) -> lookup at 14
    const st = lk + 6 + n * 2; // the shared subtable
    var buf: [st + 10 + n * 2]u8 = @splat(0);
    put16(&buf, 8, 10);
    put16(&buf, 10, 1);
    put16(&buf, 12, lk - 10);
    put16(&buf, lk, 1); // single substitution
    put16(&buf, lk + 4, n);
    for (0..n) |i| put16(&buf, lk + 6 + i * 2, st - lk);
    put16(&buf, st, 1);
    put16(&buf, st + 2, 6); // coverage at st + 6
    put16(&buf, st + 6, 1);
    put16(&buf, st + 8, n);
    for (0..n) |i| put16(&buf, st + 10 + i * 2, @intCast(i));
    const io = std.testing.io;
    const t0 = std.Io.Clock.awake.now(io);
    const d = lookupDigest(&buf, 0, 7);
    try std.testing.expect(d.mayHave(5) and d.mayHave(12000));
    try std.testing.expect(elapsedMs(io, t0) < 1000);
}
