//! Brotli decompressor (RFC 7932), written for WOFF2 but usable on its own.
//!
//! The whole output stays in memory, so the sliding window is simply the output buffer itself
//! (no ring buffer, no extra copy). Supported: every stream feature of RFC 7932 (simple and
//! complex prefix codes, block types and counts, literal/distance context maps with RLE and
//! inverse move-to-front, NPOSTFIX/NDIRECT, the last-distance ring, uncompressed and metadata
//! meta-blocks, window sizes 10..24 and the 122,784-byte static dictionary with its 121 word
//! transforms). The non-standard "large window" extension is rejected.
//!
//! The static dictionary is embedded as a brotli stream of (dictionary XOR 0x80) that provably
//! contains no dictionary references (checked by a test); it is decoded on first use into memory
//! from the caller's allocator and freed before returning, so streams that never reference the
//! dictionary (the common case) pay nothing.
//!
//! Untrusted input: every read is bounds checked, the output never exceeds the caller's cap
//! (brotli bombs end with `error.OutputTooLarge`), recursion-free, memory is bounded by the
//! output plus ~3 MiB worst-case prefix-code tables plus the 120 KiB dictionary.
//!
//! Allocation: `alloc` receives the output (`decompressAlloc`), prefix-code tables (grown and
//! reused across meta-blocks) and the lazily decoded dictionary; all temporaries are freed.
const std = @import("std");
const tables = @import("brotli_tables.zig");

pub const Error = error{ InvalidData, OutputTooLarge, OutOfMemory };

/// Decompresses a complete brotli stream into `dst`. Returns the number of bytes produced.
/// A stream producing more than `dst.len` bytes fails with `error.OutputTooLarge`.
pub fn decompressInto(alloc: std.mem.Allocator, src: []const u8, dst: []u8) Error!usize {
    var d = Decoder{ .alloc = alloc, .br = .{ .src = src }, .out = dst, .limit = dst.len };
    defer d.deinit();
    try d.run();
    return d.pos;
}

/// Decompresses a complete brotli stream into a newly allocated, exactly sized buffer of at most
/// `max_out` bytes (owned by the caller).
pub fn decompressAlloc(alloc: std.mem.Allocator, src: []const u8, max_out: usize) Error![]u8 {
    var d = Decoder{ .alloc = alloc, .br = .{ .src = src }, .out = &.{}, .limit = max_out, .growable = true };
    defer d.deinit();
    errdefer if (d.out.len != 0) alloc.free(d.out);
    try d.run();
    if (d.pos == d.out.len) {
        const r = d.out;
        d.out = &.{};
        return r;
    }
    if (d.pos != 0 and alloc.resize(d.out, d.pos)) {
        const r = d.out[0..d.pos];
        d.out = &.{};
        return r;
    }
    const r = try alloc.alloc(u8, d.pos);
    @memcpy(r, d.out[0..d.pos]);
    alloc.free(d.out);
    d.out = &.{};
    return r;
}

// ------------------------------------------------------------------ static dictionary

const dict_size = 122784;
/// brotli(dictionary ^ 0x80): XOR-ing keeps the encoder from emitting dictionary references.
const dict_blob = @embedFile("brotli_dict.br");

const ndbits = [25]u5{ 0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5 };
const doffset = blk: {
    var o: [25]u32 = undefined;
    var acc: u32 = 0;
    for (0..25) |l| {
        o[l] = acc;
        if (l >= 4) acc += @as(u32, l) << ndbits[l];
    }
    if (acc != dict_size) @compileError("dictionary layout");
    break :blk o;
};

fn loadDictionary(alloc: std.mem.Allocator) Error![]u8 {
    const buf = try alloc.alloc(u8, dict_size);
    errdefer alloc.free(buf);
    var d = Decoder{ .alloc = alloc, .br = .{ .src = dict_blob }, .out = buf, .limit = dict_size, .allow_dict = false };
    defer d.deinit();
    d.run() catch return error.InvalidData;
    if (d.pos != dict_size) return error.InvalidData;
    for (buf) |*b| b.* ^= 0x80;
    return buf;
}

// ------------------------------------------------------------------ bit reader

const BitReader = struct {
    src: []const u8,
    /// Next byte to load (may run past the end: missing bytes read as zero, see `overrun`).
    pos: usize = 0,
    buf: u64 = 0,
    cnt: u32 = 0,

    fn refill(br: *BitReader) void {
        if (br.pos + 8 <= br.src.len) {
            const v = std.mem.littleToNative(u64, @as(*align(1) const u64, @ptrCast(br.src.ptr + br.pos)).*);
            br.buf |= v << @as(u6, @intCast(br.cnt));
            const add = (63 - br.cnt) >> 3;
            br.pos += add;
            br.cnt += add << 3;
        } else {
            while (br.cnt <= 56) {
                const b: u64 = if (br.pos < br.src.len) br.src[br.pos] else 0;
                br.buf |= b << @as(u6, @intCast(br.cnt));
                br.pos += 1;
                br.cnt += 8;
            }
        }
    }

    inline fn drop(br: *BitReader, n: u32) void {
        br.buf >>= @as(u6, @intCast(n));
        br.cnt -= n;
    }

    /// Reads `n` <= 24 bits.
    inline fn bits(br: *BitReader, n: u32) u32 {
        if (br.cnt < n) br.refill();
        const v: u32 = @as(u32, @truncate(br.buf)) & ((@as(u32, 1) << @as(u5, @intCast(n))) -% 1);
        br.drop(n);
        return v;
    }

    inline fn bit(br: *BitReader) u32 {
        return br.bits(1);
    }

    /// True once more bits were consumed than the input holds.
    fn overrun(br: *const BitReader) bool {
        return @as(u64, br.pos) * 8 - br.cnt > @as(u64, br.src.len) * 8;
    }

    /// Cheap conservative check used inside loops (certainly overrun, or not yet detectable).
    inline fn farOverrun(br: *const BitReader) bool {
        return br.pos > br.src.len + 8;
    }

    /// Skips to the next byte boundary; the skipped bits must be zero.
    fn alignByte(br: *BitReader) Error!void {
        const n = br.cnt & 7;
        if (n != 0 and br.bits(n) != 0) return error.InvalidData;
    }

    /// Byte position of the next unread byte (call after `alignByte`).
    fn bytePos(br: *const BitReader) usize {
        return br.pos - (br.cnt >> 3);
    }

    fn seek(br: *BitReader, p: usize) void {
        br.pos = p;
        br.buf = 0;
        br.cnt = 0;
    }
};

// ------------------------------------------------------------------ prefix codes

/// Table entry: low 4 bits = number of bits; high 12 bits = symbol, or (root entries with a
/// bit count > 8) the offset of a second-level table indexed by (bits - 8) further bits.
const root_bits = 8;

/// Upper bound of the table size (root 8 bits, max code length 15) per alphabet size, from the
/// reference decoder (kMaxHuffmanTableSize, indexed by (alphabet + 31) >> 5).
fn maxTableSize(alphabet: u32) u32 {
    const t = [_]u16{ 256, 402, 436, 468, 500, 534, 566, 598, 630, 662, 694, 726, 758, 790, 822, 854, 886, 920, 952, 984, 1016, 1048, 1080 };
    return t[@min((alphabet + 31) >> 5, t.len - 1)];
}

inline fn readSym(br: *BitReader, table: [*]const u16) u32 {
    if (br.cnt < 15) br.refill();
    const b: u32 = @truncate(br.buf);
    var e: u32 = table[b & 0xff];
    var nb = e & 15;
    if (nb > root_bits) {
        br.drop(root_bits);
        const sub_mask = (@as(u32, 1) << @as(u5, @intCast(nb - root_bits))) - 1;
        e = table[(e >> 4) + ((b >> root_bits) & sub_mask)];
        nb = e & 15;
    }
    br.drop(nb);
    return e >> 4;
}

inline fn rev(code: u32, len: u32) u32 {
    return @as(u32, @bitReverse(@as(u16, @truncate(code)))) >> @as(u5, @intCast(16 - len));
}

/// Builds a canonical prefix-code lookup table from per-symbol code lengths (0 = unused, max 15).
/// A single used symbol becomes a 0-bit code. The code must be complete. Returns the entries used.
fn buildTable(table: []u16, lengths: []const u8) Error!u32 {
    if (table.len < 256) return error.InvalidData;
    var count: [16]u16 = @splat(0);
    var single: u16 = 0;
    for (lengths, 0..) |l, s| {
        if (l > 15) return error.InvalidData;
        count[l] += 1;
        if (l != 0) single = @intCast(s);
    }
    const used = lengths.len - count[0];
    if (used == 0) return error.InvalidData;
    if (used == 1) {
        @memset(table[0..256], single << 4);
        return 256;
    }
    var left: i32 = 1;
    for (1..16) |l| {
        left = (left << 1) - count[l];
        if (left < 0) return error.InvalidData;
    }
    if (left != 0) return error.InvalidData;

    var start: [16]u16 = undefined;
    start[0] = 0;
    start[1] = 0;
    for (2..16) |l| start[l] = (start[l - 1] + count[l - 1]) << 1;

    // Pass 1: longest code under each root prefix (for codes longer than 8 bits).
    var maxlen: [256]u8 = @splat(0);
    var next = start;
    for (lengths) |l| {
        if (l <= root_bits) {
            if (l != 0) next[l] += 1;
            continue;
        }
        const c = next[l];
        next[l] += 1;
        const r = rev(c >> @as(u4, @intCast(l - root_bits)), root_bits);
        if (l > maxlen[r]) maxlen[r] = l;
    }
    var off: [256]u16 = undefined;
    var cur: u32 = 256;
    for (0..256) |r| {
        const m = maxlen[r];
        if (m == 0) continue;
        if (cur > 4095) return error.InvalidData;
        off[r] = @intCast(cur);
        table[r] = @intCast((cur << 4) | m);
        cur += @as(u32, 1) << @as(u5, @intCast(m - root_bits));
        if (cur > table.len) return error.InvalidData;
    }
    // Pass 2: fill entries.
    next = start;
    for (lengths, 0..) |l, sym| {
        if (l == 0) continue;
        const c = next[l];
        next[l] += 1;
        const s16: u16 = @intCast(sym);
        if (l <= root_bits) {
            var j = rev(c, l);
            const step = @as(u32, 1) << @as(u5, @intCast(l));
            const e: u16 = (s16 << 4) | l;
            while (j < 256) : (j += step) table[j] = e;
        } else {
            const sl: u32 = l - root_bits;
            const r = rev(c >> @as(u4, @intCast(sl)), root_bits);
            const m: u32 = maxlen[r] - root_bits;
            const base: u32 = off[r];
            var j = rev(c & ((@as(u32, 1) << @as(u5, @intCast(sl))) - 1), sl);
            const step = @as(u32, 1) << @as(u5, @intCast(sl));
            const e: u16 = (s16 << 4) | @as(u16, @intCast(sl));
            while (j < (@as(u32, 1) << @as(u5, @intCast(m)))) : (j += step) table[base + j] = e;
        }
    }
    return cur;
}

const cl_order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
const cl_val = [16]u8{ 0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5 };
const cl_len = [16]u8{ 2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4 };

/// Reads one prefix code over an alphabet of `alphabet` (2..704) symbols into `table`.
fn readPrefixCode(br: *BitReader, alphabet: u32, table: []u16) Error!void {
    var lengths: [704]u8 = undefined;
    if (alphabet < 2 or alphabet > lengths.len) return error.InvalidData;
    const lens = lengths[0..alphabet];
    @memset(lens, 0);
    const hskip = br.bits(2);
    if (hskip == 1) {
        const nsym = br.bits(2) + 1;
        const abits: u32 = 32 - @clz(alphabet - 1);
        var syms: [4]u32 = undefined;
        for (0..nsym) |i| {
            const s = br.bits(abits);
            if (s >= alphabet) return error.InvalidData;
            for (syms[0..i]) |p| if (p == s) return error.InvalidData;
            syms[i] = s;
        }
        switch (nsym) {
            1 => lens[syms[0]] = 1,
            2 => {
                lens[syms[0]] = 1;
                lens[syms[1]] = 1;
            },
            3 => {
                lens[syms[0]] = 1;
                lens[syms[1]] = 2;
                lens[syms[2]] = 2;
            },
            else => {
                if (br.bit() == 0) {
                    for (syms) |s| lens[s] = 2;
                } else {
                    lens[syms[0]] = 1;
                    lens[syms[1]] = 2;
                    lens[syms[2]] = 3;
                    lens[syms[3]] = 3;
                }
            },
        }
        _ = try buildTable(table, lens);
        return;
    }
    // Complex prefix code: code lengths of the code-length alphabet first.
    var cl_lens: [18]u8 = @splat(0);
    var space: i32 = 32;
    var num: u32 = 0;
    var i: u32 = hskip;
    while (i < 18) : (i += 1) {
        if (br.cnt < 4) br.refill();
        const p: u32 = @as(u32, @truncate(br.buf)) & 15;
        br.drop(cl_len[p]);
        const v = cl_val[p];
        cl_lens[cl_order[i]] = v;
        if (v != 0) {
            space -= @as(i32, 32) >> @as(u5, @intCast(v));
            num += 1;
            if (space <= 0) break;
        }
    }
    if (num != 1 and space != 0) return error.InvalidData;
    var cl_table: [256]u16 = undefined;
    _ = try buildTable(&cl_table, &cl_lens);

    var sym: u32 = 0;
    var prev_len: u8 = 8;
    var repeat: u32 = 0;
    var repeat_len: u8 = 0;
    var sp: i32 = 32768;
    while (sym < alphabet and sp > 0) {
        if (br.farOverrun()) return error.InvalidData;
        const c = readSym(br, &cl_table);
        if (c < 16) {
            repeat = 0;
            lens[sym] = @intCast(c);
            if (c != 0) {
                prev_len = @intCast(c);
                sp -= @as(i32, 32768) >> @as(u5, @intCast(c));
            }
            sym += 1;
        } else {
            const extra: u32 = if (c == 16) 2 else 3;
            const new_len: u8 = if (c == 16) prev_len else 0;
            if (repeat_len != new_len) {
                repeat = 0;
                repeat_len = new_len;
            }
            const old = repeat;
            if (repeat > 0) repeat = (repeat - 2) << @as(u5, @intCast(extra));
            repeat += br.bits(extra) + 3;
            const delta = repeat -% old;
            if (delta > alphabet - sym) return error.InvalidData;
            @memset(lens[sym..][0..delta], repeat_len);
            sym += delta;
            if (repeat_len != 0) sp -= @as(i32, @intCast(delta << @as(u5, @intCast(15 - repeat_len))));
        }
    }
    if (sp != 0) return error.InvalidData;
    _ = try buildTable(table, lens);
}

// ------------------------------------------------------------------ length/count tables

const blen_base = [26]u32{ 1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625 };
const blen_extra = [26]u8{ 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24 };
const ins_base = [24]u32{ 0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594 };
const ins_extra = [24]u8{ 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24 };
const copy_base = [24]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118 };
const copy_extra = [24]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24 };
/// Per 64-symbol cell of the insert-and-copy alphabet: insert code base, copy code base.
const cell_ins = [11]u8{ 0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16 };
const cell_copy = [11]u8{ 0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16 };

fn readVarLen8(br: *BitReader) u32 {
    if (br.bit() == 0) return 0;
    const n = br.bits(3);
    if (n == 0) return 1;
    return (@as(u32, 1) << @as(u5, @intCast(n))) + br.bits(n);
}

// ------------------------------------------------------------------ decoder

const Decoder = struct {
    alloc: std.mem.Allocator,
    br: BitReader,
    out: []u8,
    pos: usize = 0,
    limit: usize,
    growable: bool = false,
    allow_dict: bool = true,
    dict: ?[]u8 = null,
    tabs: []u16 = &.{},
    cmaps: []u8 = &.{},
    /// Last four distances, d[0] most recent.
    dist: [4]u32 = .{ 4, 11, 15, 16 },
    window: usize = 0,

    fn deinit(d: *Decoder) void {
        if (d.dict) |x| d.alloc.free(x);
        if (d.tabs.len != 0) d.alloc.free(d.tabs);
        if (d.cmaps.len != 0) d.alloc.free(d.cmaps);
        d.dict = null;
        d.tabs = &.{};
        d.cmaps = &.{};
    }

    /// Makes room for `n` more output bytes.
    fn ensure(d: *Decoder, n: usize) Error!void {
        if (n > d.limit - d.pos) return error.OutputTooLarge;
        const need = d.pos + n;
        if (need <= d.out.len) return;
        if (!d.growable) return error.OutputTooLarge;
        var cap = @max(d.out.len * 2, 4096);
        while (cap < need) cap *= 2;
        cap = @min(cap, d.limit);
        if (d.out.len != 0 and d.alloc.resize(d.out, cap)) {
            d.out = d.out.ptr[0..cap];
            return;
        }
        const nb = try d.alloc.alloc(u8, cap);
        @memcpy(nb[0..d.pos], d.out[0..d.pos]);
        if (d.out.len != 0) d.alloc.free(d.out);
        d.out = nb;
    }

    fn growTabs(d: *Decoder, n: usize) Error!void {
        if (d.tabs.len >= n) return;
        if (d.tabs.len != 0) d.alloc.free(d.tabs);
        d.tabs = &.{};
        d.tabs = try d.alloc.alloc(u16, n);
    }

    fn growCmaps(d: *Decoder, n: usize) Error!void {
        if (d.cmaps.len >= n) return;
        if (d.cmaps.len != 0) d.alloc.free(d.cmaps);
        d.cmaps = &.{};
        d.cmaps = try d.alloc.alloc(u8, n);
    }

    noinline fn run(d: *Decoder) Error!void {
        const br = &d.br;
        // Stream header: WBITS.
        var wbits: u32 = 16;
        if (br.bit() != 0) {
            const n = br.bits(3);
            if (n != 0) {
                wbits = 17 + n;
            } else {
                const m = br.bits(3);
                if (m == 1) return error.InvalidData; // large-window streams are not RFC 7932
                wbits = if (m != 0) 8 + m else 17;
            }
        }
        d.window = (@as(usize, 1) << @as(u5, @intCast(wbits))) - 16;

        while (true) {
            if (br.overrun()) return error.InvalidData;
            const is_last = br.bit() != 0;
            if (is_last and br.bit() != 0) break; // ISLASTEMPTY
            const mn = br.bits(2);
            if (mn == 3) {
                // Metadata block.
                if (br.bit() != 0) return error.InvalidData;
                const skip_bytes = br.bits(2);
                var skip: usize = 0;
                if (skip_bytes > 0) {
                    for (0..skip_bytes) |i| {
                        const b = br.bits(8);
                        if (i + 1 == skip_bytes and skip_bytes > 1 and b == 0) return error.InvalidData;
                        skip |= @as(usize, b) << @as(u5, @intCast(8 * i));
                    }
                    skip += 1;
                }
                try br.alignByte();
                const p = br.bytePos();
                if (p > br.src.len or skip > br.src.len - p) return error.InvalidData;
                br.seek(p + skip);
                if (is_last) break;
                continue;
            }
            const nibbles = mn + 4;
            var mlen: usize = 0;
            for (0..nibbles) |i| {
                const v = br.bits(4);
                if (i + 1 == nibbles and nibbles > 4 and v == 0) return error.InvalidData;
                mlen |= @as(usize, v) << @as(u5, @intCast(4 * i));
            }
            mlen += 1;
            try d.ensure(mlen);
            if (!is_last and br.bit() != 0) {
                // Uncompressed block.
                try br.alignByte();
                const p = br.bytePos();
                if (p > br.src.len or mlen > br.src.len - p) return error.InvalidData;
                @memcpy(d.out[d.pos..][0..mlen], br.src[p..][0..mlen]);
                d.pos += mlen;
                br.seek(p + mlen);
            } else {
                try d.metaBlock(mlen);
            }
            if (is_last) break;
        }
        if (br.overrun()) return error.InvalidData;
    }

    fn metaBlock(d: *Decoder, mlen: usize) Error!void {
        const br = &d.br;
        var nbl: [3]u32 = undefined;
        var btype = [3]u32{ 0, 0, 0 };
        var bprev = [3]u32{ 1, 1, 1 };
        var blen: [3]u32 = undefined;
        var type_tab: [3][662]u16 = undefined;
        var count_tab: [3][402]u16 = undefined;
        for (0..3) |c| {
            nbl[c] = readVarLen8(br) + 1;
            if (nbl[c] >= 2) {
                try readPrefixCode(br, nbl[c] + 2, &type_tab[c]);
                try readPrefixCode(br, 26, &count_tab[c]);
                blen[c] = readBlockCount(br, &count_tab[c]);
            } else blen[c] = 1 << 24;
        }
        const npostfix: u5 = @intCast(br.bits(2));
        const ndirect: u32 = br.bits(4) << npostfix;
        const dist_alpha: u32 = 16 + ndirect + (@as(u32, 48) << npostfix);

        var cmodes: [256]u8 = undefined;
        for (0..nbl[0]) |i| cmodes[i] = @intCast(br.bits(2));

        const lmap_len = 64 * nbl[0];
        const dmap_len = 4 * nbl[2];
        try d.growCmaps(lmap_len + dmap_len);
        const lmap = d.cmaps[0..lmap_len];
        const dmap = d.cmaps[lmap_len..][0..dmap_len];
        const ntl = readVarLen8(br) + 1;
        if (ntl >= 2) try readContextMap(br, ntl, lmap) else @memset(lmap, 0);
        const ntd = readVarLen8(br) + 1;
        if (ntd >= 2) try readContextMap(br, ntd, dmap) else @memset(dmap, 0);

        const lit_b: usize = maxTableSize(256);
        const ins_b: usize = maxTableSize(704);
        const dst_b: usize = maxTableSize(dist_alpha);
        const lit_n = ntl * lit_b;
        const ins_n = nbl[1] * ins_b;
        try d.growTabs(lit_n + ins_n + ntd * dst_b);
        const lit_tabs = d.tabs[0..lit_n];
        const ins_tabs = d.tabs[lit_n..][0..ins_n];
        const dist_tabs = d.tabs[lit_n + ins_n ..][0 .. ntd * dst_b];
        for (0..ntl) |i| try readPrefixCode(br, 256, lit_tabs[i * lit_b ..][0..lit_b]);
        for (0..nbl[1]) |i| try readPrefixCode(br, 704, ins_tabs[i * ins_b ..][0..ins_b]);
        for (0..ntd) |i| try readPrefixCode(br, dist_alpha, dist_tabs[i * dst_b ..][0..dst_b]);
        if (br.overrun()) return error.InvalidData;

        const out = d.out;
        var pos = d.pos;
        const end = pos + mlen;
        var p1: u8 = if (pos > 0) out[pos - 1] else 0;
        var p2: u8 = if (pos > 1) out[pos - 2] else 0;
        var lit_base: usize = 0;
        var cmode: u8 = cmodes[0];
        var ins_tab: [*]const u16 = ins_tabs.ptr;
        const postfix_mask: u32 = (@as(u32, 1) << npostfix) - 1;

        while (pos < end) {
            if (br.farOverrun()) return error.InvalidData;
            if (blen[1] == 0) {
                switchBlock(br, 1, &nbl, &btype, &bprev, &blen, &type_tab, &count_tab);
                ins_tab = ins_tabs.ptr + btype[1] * ins_b;
            }
            blen[1] -= 1;
            const cmd = readSym(br, ins_tab);
            const cell = cmd >> 6;
            const ic = cell_ins[cell] + ((cmd >> 3) & 7);
            const cc = cell_copy[cell] + (cmd & 7);
            const insert_len = ins_base[ic] + br.bits(ins_extra[ic]);
            const copy_len = copy_base[cc] + br.bits(copy_extra[cc]);
            if (insert_len > end - pos) return error.InvalidData;

            var k: u32 = 0;
            while (k < insert_len) : (k += 1) {
                if (blen[0] == 0) {
                    switchBlock(br, 0, &nbl, &btype, &bprev, &blen, &type_tab, &count_tab);
                    lit_base = btype[0] * 64;
                    cmode = cmodes[btype[0]];
                }
                blen[0] -= 1;
                const ctx: u32 = switch (cmode) {
                    0 => p1 & 63,
                    1 => p1 >> 2,
                    2 => tables.lut0[p1] | tables.lut1[p2],
                    else => (@as(u32, tables.lut2[p1]) << 3) | tables.lut2[p2],
                };
                const tree: usize = lmap[lit_base + ctx];
                const b: u8 = @truncate(readSym(br, lit_tabs.ptr + tree * lit_b));
                out[pos] = b;
                pos += 1;
                p2 = p1;
                p1 = b;
            }
            if (pos >= end) break;

            var distance: u32 = undefined;
            var push = false;
            if (cmd < 128) {
                distance = d.dist[0];
            } else {
                if (blen[2] == 0) switchBlock(br, 2, &nbl, &btype, &bprev, &blen, &type_tab, &count_tab);
                blen[2] -= 1;
                const dctx: u32 = if (copy_len > 4) 3 else copy_len - 2;
                const tree: usize = dmap[btype[2] * 4 + dctx];
                const dc = readSym(br, dist_tabs.ptr + tree * dst_b);
                if (dc < 16) {
                    const delta = [16]i8{ 0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3 };
                    const src_i: usize = if (dc < 4) dc else if (dc < 10) 0 else 1;
                    const v: i64 = @as(i64, d.dist[src_i]) + delta[dc];
                    if (v <= 0) return error.InvalidData;
                    distance = @intCast(v);
                    push = dc != 0;
                } else if (dc < 16 + ndirect) {
                    distance = dc - 15;
                    push = true;
                } else {
                    const x = dc - ndirect - 16;
                    const nd: u32 = 1 + (x >> (npostfix + 1));
                    const hcode = x >> npostfix;
                    const lcode = x & postfix_mask;
                    const offset: u32 = ((2 + (hcode & 1)) << @as(u5, @intCast(nd))) - 4;
                    distance = ((offset + br.bits(nd)) << npostfix) + lcode + ndirect + 1;
                    push = true;
                }
            }

            const max_dist = @min(pos, d.window);
            if (distance > max_dist) {
                pos += try d.dictWord(pos, end, copy_len, @intCast(distance - max_dist - 1));
            } else {
                if (push) {
                    // (temporary copy: an array literal reading its own destination would alias)
                    const old = d.dist;
                    d.dist = .{ distance, old[0], old[1], old[2] };
                }
                if (copy_len > end - pos) return error.InvalidData;
                copyMatch(out, pos, distance, copy_len);
                pos += copy_len;
            }
            // A transformed dictionary word can emit 0 or 1 bytes, so pos may still be < 2 here (RFC 7932: the
            // context bytes before the start of the stream are 0).
            p1 = if (pos > 0) out[pos - 1] else 0;
            p2 = if (pos > 1) out[pos - 2] else 0;
        }
        d.pos = pos;
    }

    /// Emits a transformed static dictionary word; returns its length.
    noinline fn dictWord(d: *Decoder, pos: usize, end: usize, len: u32, word_id: u32) Error!usize {
        if (!d.allow_dict or len < 4 or len > 24) return error.InvalidData;
        const nb: u5 = ndbits[len];
        const idx = word_id & ((@as(u32, 1) << nb) - 1);
        const tid = word_id >> nb;
        if (tid > 120) return error.InvalidData;
        if (d.dict == null) d.dict = try loadDictionary(d.alloc);
        const word = d.dict.?[doffset[len] + idx * len ..][0..len];
        var buf: [64]u8 = undefined;
        const n = transformWord(&buf, word, tid);
        if (n > end - pos) return error.InvalidData;
        @memcpy(d.out[pos..][0..n], buf[0..n]);
        return n;
    }
};

fn copyMatch(out: []u8, pos: usize, distance: usize, len: usize) void {
    const src = pos - distance;
    if (distance >= len) {
        @memcpy(out[pos..][0..len], out[src..][0..len]);
        return;
    }
    if (distance == 1) {
        @memset(out[pos..][0..len], out[src]);
        return;
    }
    // Periodic pattern: grow the copied run geometrically, each chunk non-overlapping.
    var done: usize = 0;
    while (done < len) {
        const chunk = @min(len - done, distance + done);
        @memcpy(out[pos + done ..][0..chunk], out[src..][0..chunk]);
        done += chunk;
    }
}

fn switchBlock(
    br: *BitReader,
    c: usize,
    nbl: *const [3]u32,
    btype: *[3]u32,
    bprev: *[3]u32,
    blen: *[3]u32,
    type_tab: *const [3][662]u16,
    count_tab: *const [3][402]u16,
) void {
    if (nbl[c] < 2) {
        blen[c] = 1 << 24;
        return;
    }
    const s = readSym(br, &type_tab[c]);
    var t: u32 = switch (s) {
        0 => bprev[c],
        1 => btype[c] + 1,
        else => s - 2,
    };
    if (t >= nbl[c]) t -= nbl[c];
    if (t >= nbl[c]) t = 0;
    bprev[c] = btype[c];
    btype[c] = t;
    blen[c] = readBlockCount(br, &count_tab[c]);
}

fn ferment(w: []u8, p: usize) usize {
    const c = w[p];
    if (c < 192) {
        if (c >= 'a' and c <= 'z') w[p] ^= 32;
        return 1;
    }
    if (c < 224) {
        if (p + 1 < w.len) w[p + 1] ^= 32;
        return 2;
    }
    if (p + 2 < w.len) w[p + 2] ^= 5;
    return 3;
}

fn transformWord(dst: *[64]u8, word: []const u8, tid: u32) usize {
    const t = tables.transforms[tid * 3 ..][0..3];
    const pre = tables.affix_pool[t[0] + 1 ..][0..tables.affix_pool[t[0]]];
    const suf = tables.affix_pool[t[2] + 1 ..][0..tables.affix_pool[t[2]]];
    const typ = t[1];
    var n: usize = pre.len;
    @memcpy(dst[0..n], pre);
    var w = word;
    if (typ >= 12) {
        w = w[0 .. w.len - @min(typ - 11, w.len)];
    } else if (typ >= 3) {
        w = w[@min(typ - 2, w.len)..];
    }
    @memcpy(dst[n..][0..w.len], w);
    const ws = dst[n..][0..w.len];
    n += w.len;
    if (typ == 1) {
        if (ws.len > 0) _ = ferment(ws, 0);
    } else if (typ == 2) {
        var i: usize = 0;
        while (i < ws.len) i += ferment(ws, i);
    }
    @memcpy(dst[n..][0..suf.len], suf);
    return n + suf.len;
}

fn readBlockCount(br: *BitReader, table: []const u16) u32 {
    const s = readSym(br, table.ptr);
    const k = @min(s, 25);
    return blen_base[k] + br.bits(blen_extra[k]);
}

/// Reads a context map of `map.len` entries with values < `ntrees`.
fn readContextMap(br: *BitReader, ntrees: u32, map: []u8) Error!void {
    var rlemax: u32 = 0;
    if (br.bit() != 0) rlemax = br.bits(4) + 1;
    var tab: [662]u16 = undefined;
    try readPrefixCode(br, ntrees + rlemax, &tab);
    var i: usize = 0;
    while (i < map.len) {
        if (br.farOverrun()) return error.InvalidData;
        const s = readSym(br, &tab);
        if (s == 0) {
            map[i] = 0;
            i += 1;
        } else if (s <= rlemax) {
            const run = (@as(usize, 1) << @as(u5, @intCast(s))) + br.bits(s);
            if (run > map.len - i) return error.InvalidData;
            @memset(map[i..][0..run], 0);
            i += run;
        } else {
            const v = s - rlemax;
            if (v >= ntrees) return error.InvalidData;
            map[i] = @intCast(v);
            i += 1;
        }
    }
    if (br.bit() != 0) {
        // Inverse move-to-front.
        var mtf: [256]u8 = undefined;
        for (&mtf, 0..) |*m, k| m.* = @intCast(k);
        for (map) |*m| {
            const idx = m.*;
            const v = mtf[idx];
            m.* = v;
            var k: usize = idx;
            while (k > 0) : (k -= 1) mtf[k] = mtf[k - 1];
            mtf[0] = v;
        }
    }
}

/// Test hook: decodes the embedded static dictionary (caller frees).
pub fn loadDictionaryForTest(alloc: std.mem.Allocator) Error![]u8 {
    return loadDictionary(alloc);
}

test "brotli: transformed dictionary word emitting 0 bytes at stream start does not underflow" {
    // Hand-built stream: one meta-block (MLEN 10), single-symbol prefix codes, insert&copy symbol 130
    // (insert 0, copy 4), distance code 42 with extra bits making distance 34817 -> static dictionary word with
    // transform 34 (omit-first-9), which emits 0 bytes while pos is still 0.
    const W = struct {
        buf: [64]u8 = @splat(0),
        n: usize = 0,
        fn put(w: *@This(), v: u32, k: u5) void {
            var i: u5 = 0;
            while (i < k) : (i += 1) {
                if ((v >> i) & 1 != 0) w.buf[w.n >> 3] |= @as(u8, 1) << @intCast(w.n & 7);
                w.n += 1;
            }
        }
    };
    var w = W{};
    w.put(0, 1); // WBITS=16
    w.put(1, 1); // ISLAST
    w.put(0, 1); // !ISLASTEMPTY
    w.put(0, 2); // MNIBBLES=4
    w.put(9, 16); // MLEN-1
    w.put(0, 1); // NBLTYPESL = 1
    w.put(0, 1); // NBLTYPESI = 1
    w.put(0, 1); // NBLTYPESD = 1
    w.put(0, 2); // NPOSTFIX
    w.put(0, 4); // NDIRECT
    w.put(0, 2); // context mode
    w.put(0, 1); // NTREESL = 1
    w.put(0, 1); // NTREESD = 1
    w.put(1, 2); // literal code: simple, 1 symbol
    w.put(0, 2);
    w.put('a', 8);
    w.put(1, 2); // insert&copy code: simple, 1 symbol
    w.put(0, 2);
    w.put(130, 10);
    w.put(1, 2); // distance code: simple, 1 symbol
    w.put(0, 2);
    w.put(42, 6);
    w.put(2052, 14); // distance extra bits
    var dst: [16]u8 = undefined;
    // Must not panic (integer overflow on `pos - 2`); either result is acceptable.
    _ = decompressInto(std.testing.allocator, w.buf[0 .. (w.n + 7) / 8 + 8], &dst) catch {};
}
