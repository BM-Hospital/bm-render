//! JPEG decoder: baseline / extended sequential (SOF0/SOF1) and progressive (SOF2) Huffman,
//! 8-bit precision, 1 or 3 components (YCbCr, grayscale, Adobe/JFIF-less RGB), any H/V
//! sampling factors 1..4 whose ratio to the maximum is integral, restart intervals.
//! Reconstruction mirrors libjpeg-turbo defaults: "islow" integer IDCT, "fancy" triangle
//! upsampling for h2v1 / h1v2 / h2v2 chroma (replication for other ratios), libjpeg's
//! fixed-point YCbCr->RGB. Output is RGBA8 with alpha 255.
//!
//! Untrusted input: every read is bounds-checked; entropy data past the end of the buffer or
//! at a marker reads as zero bits (truncated files decode with the missing area grey), and all
//! loops are bounded by the block count. Allocations: coefficient buffers (progressive only),
//! one sample plane per component, the output image; all through `alloc`.
const std = @import("std");
const types = @import("types.zig");

const Error = types.Error;

/// zigzag index -> natural (row-major) index.
const dezigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

const Huff = struct {
    /// 9-bit lookahead: (len << 8) | symbol, 0 = longer code (slow path).
    lut: [512]u16,
    maxcode: [17]i32,
    valoff: [17]i32,
    vals: [256]u8,
    nvals: u16,
    defined: bool,
};

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    td: u8 = 0,
    ta: u8 = 0,
    /// Blocks per row / column of the MCU-padded component.
    bw: u32 = 0,
    bh: u32 = 0,
    /// Actual sample dimensions of the component (ceil(W*h/hmax), ceil(H*v/vmax)).
    cw: u32 = 0,
    ch: u32 = 0,
    pred: i32 = 0,
    coefs: []i16 = &.{},
    plane: []u8 = &.{},
};

const Bits = struct {
    data: []const u8,
    pos: usize,
    acc: u64 = 0,
    n: u32 = 0,
    /// Zero bytes synthesised past a marker / end of data (used to stop decoding garbage early).
    pad: u32 = 0,

    fn refill(b: *Bits) void {
        while (b.n <= 56) {
            var byte: u64 = 0;
            if (b.pos < b.data.len) {
                const c = b.data[b.pos];
                if (c == 0xFF) {
                    const nx: u8 = if (b.pos + 1 < b.data.len) b.data[b.pos + 1] else 0xD9;
                    if (nx == 0) {
                        b.pos += 2;
                        byte = 0xFF;
                    } else if (nx == 0xFF) {
                        b.pos += 1;
                        continue;
                    } else b.pad +|= 1; // a marker: feed zeros and stay put
                } else {
                    b.pos += 1;
                    byte = c;
                }
            } else b.pad +|= 1;
            b.acc |= byte << @intCast(56 - b.n);
            b.n += 8;
        }
    }

    inline fn consume(b: *Bits, k: u32) void {
        b.acc <<= @intCast(k);
        b.n -= k;
    }

    /// Reads `k` (0..16) bits as an unsigned value.
    fn get(b: *Bits, k: u32) u32 {
        if (k == 0) return 0;
        if (b.n < k) b.refill();
        const v: u32 = @intCast(b.acc >> @intCast(64 - k));
        b.consume(k);
        return v;
    }

    fn bit(b: *Bits) bool {
        return b.get(1) != 0;
    }

    /// Reads `s` bits and sign-extends per JPEG (F.12). `s` must be <= 16.
    fn extend(b: *Bits, s: u32) i32 {
        if (s == 0) return 0;
        const v: i32 = @intCast(b.get(s));
        const half: i32 = @as(i32, 1) << @intCast(s - 1);
        return if (v < half) v - (half << 1) + 1 else v;
    }

    fn sym(b: *Bits, h: *const Huff) Error!u8 {
        if (b.n < 16) b.refill();
        const e = h.lut[@intCast(b.acc >> 55)];
        if (e != 0) {
            b.consume(e >> 8);
            return @truncate(e);
        }
        const code16: u32 = @intCast(b.acc >> 48);
        var l: u32 = 10;
        while (l <= 16) : (l += 1) {
            const c: i32 = @intCast(code16 >> @intCast(16 - l));
            if (c <= h.maxcode[l]) {
                const idx = c + h.valoff[l];
                if (idx < 0 or idx >= h.nvals) return error.InvalidData;
                b.consume(l);
                return h.vals[@intCast(idx)];
            }
        }
        return error.InvalidData;
    }

    /// Discards buffered bits and skips past the next RSTn marker (if any is found before
    /// another marker). Used at restart-interval boundaries.
    fn restart(b: *Bits) void {
        b.acc = 0;
        b.n = 0;
        var p = b.pos;
        while (p + 1 < b.data.len) : (p += 1) {
            if (b.data[p] != 0xFF) continue;
            const m = b.data[p + 1];
            if (m >= 0xD0 and m <= 0xD7) {
                b.pos = p + 2;
                b.pad = 0;
                return;
            }
            if (m != 0 and m != 0xFF) break; // some other marker: leave it for the parser
        }
        b.pos = p;
    }
};

/// Maximum SOS segments per image (a progressive JPEG needs ~10; libjpeg-turbo tools cap at 1000).
const max_scans: u32 = 1000;

const Decoder = struct {
    alloc: std.mem.Allocator,
    data: []const u8,
    limits: types.Limits,
    qt: [4][64]u16 = @splat(@splat(0)),
    qt_defined: [4]bool = @splat(false),
    huff: [8]Huff = undefined, // 0..3 DC, 4..7 AC
    comps: [3]Component = undefined,
    ncomp: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    hmax: u32 = 1,
    vmax: u32 = 1,
    mcux: u32 = 0,
    mcuy: u32 = 0,
    progressive: bool = false,
    frame: bool = false,
    scans: u32 = 0,
    restart_interval: u32 = 0,
    eobrun: u32 = 0,
    adobe_transform: i32 = -1,
    orientation: u8 = 1,

    fn deinit(d: *Decoder) void {
        for (d.comps[0..d.ncomp]) |*c| {
            if (c.coefs.len != 0) d.alloc.free(c.coefs);
            if (c.plane.len != 0) d.alloc.free(c.plane);
        }
    }

    fn be16(s: []const u8, i: usize) u32 {
        return (@as(u32, s[i]) << 8) | s[i + 1];
    }

    fn parseDqt(d: *Decoder, seg: []const u8) Error!void {
        var i: usize = 0;
        while (i < seg.len) {
            const pq = seg[i] >> 4;
            const tq = seg[i] & 15;
            i += 1;
            if (tq > 3 or pq > 1) return error.InvalidData;
            const n: usize = if (pq == 0) 64 else 128;
            if (seg.len - i < n) return error.InvalidData;
            for (0..64) |k| {
                const q: u16 = if (pq == 0) seg[i + k] else @intCast(be16(seg, i + 2 * k));
                d.qt[tq][dezigzag[k]] = q;
            }
            d.qt_defined[tq] = true;
            i += n;
        }
    }

    fn parseDht(d: *Decoder, seg: []const u8) Error!void {
        var i: usize = 0;
        while (i < seg.len) {
            if (seg.len - i < 17) return error.InvalidData;
            const tc = seg[i] >> 4;
            const th = seg[i] & 15;
            if (tc > 1 or th > 3) return error.InvalidData;
            const counts = seg[i + 1 .. i + 17];
            i += 17;
            var total: usize = 0;
            for (counts) |c| total += c;
            if (total > 256 or seg.len - i < total) return error.InvalidData;
            const h = &d.huff[@as(usize, tc) * 4 + th];
            @memset(&h.lut, 0);
            @memcpy(h.vals[0..total], seg[i .. i + total]);
            h.nvals = @intCast(total);
            i += total;
            var code: i32 = 0;
            var k: i32 = 0;
            h.maxcode[0] = -1;
            h.valoff[0] = 0;
            for (1..17) |l| {
                const cnt: i32 = counts[l - 1];
                h.valoff[l] = k - code;
                if (l <= 9) {
                    var j: i32 = 0;
                    while (j < cnt) : (j += 1) {
                        const shift: u5 = @intCast(9 - l);
                        const first: usize = @intCast(@as(i32, code + j) << shift);
                        const count: usize = @as(usize, 1) << shift;
                        if (first + count > 512) return error.InvalidData;
                        const entry: u16 = @intCast((l << 8) | h.vals[@intCast(k + j)]);
                        @memset(h.lut[first .. first + count], entry);
                    }
                }
                code += cnt;
                k += cnt;
                h.maxcode[l] = if (cnt == 0) -1 else code - 1;
                if (code > (@as(i32, 1) << @intCast(l))) return error.InvalidData;
                code <<= 1;
            }
            h.defined = true;
        }
    }

    fn parseSof(d: *Decoder, seg: []const u8) Error!void {
        if (d.frame) return error.InvalidData;
        if (seg.len < 6) return error.InvalidData;
        if (seg[0] != 8) return error.UnsupportedFormat;
        d.height = be16(seg, 1);
        d.width = be16(seg, 3);
        const nf = seg[5];
        if (d.width == 0 or d.height == 0) return error.InvalidData; // DNL not supported
        if (nf != 1 and nf != 3) return error.UnsupportedFormat;
        if (seg.len < 6 + 3 * @as(usize, nf)) return error.InvalidData;
        _ = try types.checkSize(d.width, d.height, d.limits);
        d.hmax = 1;
        d.vmax = 1;
        for (0..nf) |c| {
            const p = seg[6 + 3 * c ..];
            const h = p[1] >> 4;
            const v = p[1] & 15;
            if (h == 0 or h > 4 or v == 0 or v > 4 or p[2] > 3) return error.InvalidData;
            d.comps[c] = .{ .id = p[0], .h = h, .v = v, .tq = p[2] };
            d.hmax = @max(d.hmax, h);
            d.vmax = @max(d.vmax, v);
        }
        d.ncomp = nf;
        for (d.comps[0..nf]) |c| {
            if (d.hmax % c.h != 0 or d.vmax % c.v != 0) return error.UnsupportedFormat;
        }
        d.mcux = (d.width + 8 * d.hmax - 1) / (8 * d.hmax);
        d.mcuy = (d.height + 8 * d.vmax - 1) / (8 * d.vmax);
        // Total sample bytes (planes) and, for progressive, coefficient bytes, as a sanity bound.
        var total: u64 = 0;
        for (d.comps[0..nf]) |*c| {
            c.bw = d.mcux * c.h;
            c.bh = d.mcuy * c.v;
            c.cw = @intCast((@as(u64, d.width) * c.h + d.hmax - 1) / d.hmax);
            c.ch = @intCast((@as(u64, d.height) * c.v + d.vmax - 1) / d.vmax);
            const blocks = @as(u64, c.bw) * c.bh;
            total += blocks * 64 * (if (d.progressive) @as(u64, 3) else 1);
        }
        if (total > d.limits.max_pixels *| 8 or total > std.math.maxInt(usize) / 2) return error.ImageTooLarge;
        d.ncomp = 0; // set after successful allocation, so deinit frees only what exists
        for (0..nf) |ci| {
            const c = &d.comps[ci];
            const n: usize = @intCast(@as(u64, c.bw) * c.bh * 64);
            c.plane = try d.alloc.alloc(u8, n);
            c.coefs = &.{};
            d.ncomp += 1;
            @memset(c.plane, 128);
            if (d.progressive) {
                c.coefs = try d.alloc.alloc(i16, n);
                @memset(c.coefs, 0);
            }
        }
        d.frame = true;
    }

    fn parseApp(d: *Decoder, marker: u8, seg: []const u8) void {
        if (marker == 0xEE and seg.len >= 12 and std.mem.eql(u8, seg[0..5], "Adobe")) {
            d.adobe_transform = seg[11];
        } else if (marker == 0xE1 and seg.len >= 14 and std.mem.eql(u8, seg[0..6], "Exif\x00\x00")) {
            d.orientation = exifOrientation(seg[6..]);
        }
    }

    fn decodeScan(d: *Decoder, seg: []const u8, scan_data_start: usize) Error!usize {
        if (!d.frame) return error.InvalidData;
        // Each scan walks every MCU of the image; cap them like libjpeg-turbo's scan limit.
        if (d.scans >= max_scans) return error.InvalidData;
        if (seg.len < 1) return error.InvalidData;
        const ns = seg[0];
        if (ns == 0 or ns > d.ncomp or seg.len < 4 + 2 * @as(usize, ns)) return error.InvalidData;
        var sc: [3]*Component = undefined;
        for (0..ns) |i| {
            const id = seg[1 + 2 * i];
            const t = seg[2 + 2 * i];
            var found: ?*Component = null;
            for (d.comps[0..d.ncomp]) |*c| {
                if (c.id == id) found = c;
            }
            const c = found orelse return error.InvalidData;
            for (sc[0..i]) |prev| if (prev == c) return error.InvalidData;
            c.td = t >> 4;
            c.ta = t & 15;
            if (c.td > 3 or c.ta > 3) return error.InvalidData;
            sc[i] = c;
        }
        const p = 1 + 2 * @as(usize, ns);
        const ss: u32 = seg[p];
        const se: u32 = seg[p + 1];
        const ah: u32 = seg[p + 2] >> 4;
        const al: u32 = seg[p + 2] & 15;
        const Mode = enum { baseline, dc_first, dc_refine, ac_first, ac_refine };
        var mode: Mode = .baseline;
        if (d.progressive) {
            if (se > 63 or ss > se or al > 13) return error.InvalidData;
            if (ss == 0) {
                if (se != 0) return error.InvalidData;
                mode = if (ah == 0) .dc_first else .dc_refine;
            } else {
                if (ns != 1) return error.InvalidData;
                mode = if (ah == 0) .ac_first else .ac_refine;
            }
        }
        for (sc[0..ns]) |c| {
            const need_dc = mode == .baseline or mode == .dc_first;
            const need_ac = mode == .baseline or mode == .ac_first or mode == .ac_refine;
            if (need_dc and !d.huff[c.td].defined) return error.InvalidData;
            if (need_ac and !d.huff[4 + @as(usize, c.ta)].defined) return error.InvalidData;
            if (mode == .baseline and !d.qt_defined[c.tq]) return error.InvalidData;
            c.pred = 0;
        }
        d.eobrun = 0;
        d.scans += 1;

        var bits = Bits{ .data = d.data, .pos = scan_data_start };
        const ri = d.restart_interval;
        var todo: u32 = ri; // MCUs left until a restart marker

        const single = ns == 1;
        const nx: u32 = if (single) (sc[0].cw + 7) / 8 else d.mcux;
        const ny: u32 = if (single) (sc[0].ch + 7) / 8 else d.mcuy;

        var blk: [64]i32 = undefined;
        var my: u32 = 0;
        while (my < ny) : (my += 1) {
            // Entropy data ran out (truncated / corrupt): stop instead of decoding zeros for
            // possibly millions of blocks. Undecoded blocks stay grey.
            if (bits.pad > 4096) break;
            var mx: u32 = 0;
            while (mx < nx) : (mx += 1) {
                if (ri != 0) {
                    if (todo == 0) {
                        bits.restart();
                        for (sc[0..ns]) |c| c.pred = 0;
                        d.eobrun = 0;
                        todo = ri;
                    }
                    todo -= 1;
                }
                for (sc[0..ns]) |c| {
                    const hh: u32 = if (single) 1 else c.h;
                    const vv: u32 = if (single) 1 else c.v;
                    var by: u32 = 0;
                    while (by < vv) : (by += 1) {
                        var bx: u32 = 0;
                        while (bx < hh) : (bx += 1) {
                            const x = mx * hh + bx;
                            const y = my * vv + by;
                            const bi = @as(usize, y) * c.bw + x;
                            switch (mode) {
                                .baseline => {
                                    try d.decodeBaseline(&bits, c, &blk);
                                    idct(&blk, c.plane[(@as(usize, y) * 8 * c.bw + x) * 8 ..], @as(usize, c.bw) * 8);
                                },
                                .dc_first => {
                                    const s = try bits.sym(&d.huff[c.td]);
                                    if (s > 16) return error.InvalidData;
                                    c.pred +%= bits.extend(s);
                                    c.coefs[bi * 64] = @truncate(c.pred *% (@as(i32, 1) << @intCast(al)));
                                },
                                .dc_refine => {
                                    if (bits.bit()) c.coefs[bi * 64] |= @as(i16, 1) << @intCast(al);
                                },
                                .ac_first => try d.decodeAcFirst(&bits, c, c.coefs[bi * 64 ..][0..64], ss, se, al),
                                .ac_refine => try d.decodeAcRefine(&bits, c, c.coefs[bi * 64 ..][0..64], ss, se, al),
                            }
                        }
                    }
                }
            }
        }
        // Leave pos at the next marker for the segment parser.
        return bits.pos;
    }

    fn decodeBaseline(d: *Decoder, bits: *Bits, c: *Component, blk: *[64]i32) Error!void {
        @memset(blk, 0);
        const q = &d.qt[c.tq];
        const s = try bits.sym(&d.huff[c.td]);
        if (s > 16) return error.InvalidData;
        c.pred +%= bits.extend(s);
        blk[0] = clampCoef(c.pred *% q[0]);
        const ac = &d.huff[4 + @as(usize, c.ta)];
        var k: u32 = 1;
        while (k < 64) {
            const rs = try bits.sym(ac);
            const r = rs >> 4;
            const sz = rs & 15;
            if (sz == 0) {
                if (r != 15) break;
                k += 16;
                continue;
            }
            k += r;
            if (k > 63) return error.InvalidData;
            const z = dezigzag[k];
            blk[z] = clampCoef(bits.extend(sz) *% q[z]);
            k += 1;
        }
    }

    fn decodeAcFirst(d: *Decoder, bits: *Bits, c: *Component, co: *[64]i16, ss: u32, se: u32, al: u32) Error!void {
        if (d.eobrun > 0) {
            d.eobrun -= 1;
            return;
        }
        const ac = &d.huff[4 + @as(usize, c.ta)];
        var k = ss;
        while (k <= se) {
            const rs = try bits.sym(ac);
            const r: u32 = rs >> 4;
            const s: u32 = rs & 15;
            if (s == 0) {
                if (r < 15) {
                    d.eobrun = (@as(u32, 1) << @intCast(r)) - 1;
                    if (r != 0) d.eobrun += bits.get(r);
                    break;
                }
                k += 16;
                continue;
            }
            k += r;
            if (k > 63) return error.InvalidData;
            co[dezigzag[k]] = @truncate(bits.extend(s) *% (@as(i32, 1) << @intCast(al)));
            k += 1;
        }
    }

    fn decodeAcRefine(d: *Decoder, bits: *Bits, c: *Component, co: *[64]i16, ss: u32, se: u32, al: u32) Error!void {
        const p1: i16 = @as(i16, 1) << @intCast(al);
        const m1: i16 = -%p1;
        var k = ss;
        if (d.eobrun == 0) {
            const ac = &d.huff[4 + @as(usize, c.ta)];
            while (k <= se) {
                const rs = try bits.sym(ac);
                var r: u32 = rs >> 4;
                const s: u32 = rs & 15;
                var val: i16 = 0;
                if (s == 0) {
                    if (r < 15) {
                        d.eobrun = (@as(u32, 1) << @intCast(r));
                        if (r != 0) d.eobrun += bits.get(r);
                        break; // remaining coefficients refined below as part of the EOB run
                    }
                } else {
                    if (s != 1) return error.InvalidData;
                    val = if (bits.bit()) p1 else m1;
                }
                while (k <= se) {
                    const z = dezigzag[k];
                    k += 1;
                    if (co[z] != 0) {
                        refineBit(bits, &co[z], p1);
                    } else {
                        if (r == 0) {
                            co[z] = val;
                            break;
                        }
                        r -= 1;
                    }
                }
            }
        }
        if (d.eobrun > 0) {
            while (k <= se) : (k += 1) {
                const z = dezigzag[k];
                if (co[z] != 0) refineBit(bits, &co[z], p1);
            }
            d.eobrun -= 1;
        }
    }

    fn refineBit(bits: *Bits, v: *i16, p1: i16) void {
        if (bits.bit() and (v.* & p1) == 0) {
            v.* = if (v.* >= 0) v.* +% p1 else v.* -% p1;
        }
    }

    fn run(d: *Decoder) Error!void {
        const s = d.data;
        if (s.len < 4 or s[0] != 0xFF or s[1] != 0xD8) return error.InvalidData;
        var pos: usize = 2;
        while (true) {
            // Find the next marker.
            while (pos < s.len and s[pos] != 0xFF) pos += 1;
            while (pos < s.len and s[pos] == 0xFF) pos += 1;
            if (pos >= s.len) break;
            const m = s[pos];
            pos += 1;
            if (m == 0 or m == 0x01 or m == 0xD8 or (m >= 0xD0 and m <= 0xD7)) continue;
            if (m == 0xD9) break;
            if (s.len - pos < 2) break;
            const len = be16(s, pos);
            if (len < 2 or s.len - pos < len) {
                if (d.scans > 0) break; // truncated trailer after image data: keep what we have
                return error.InvalidData;
            }
            const seg = s[pos + 2 .. pos + len];
            pos += len;
            switch (m) {
                0xC0, 0xC1, 0xC2 => {
                    d.progressive = m == 0xC2;
                    try d.parseSof(seg);
                },
                0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.UnsupportedFormat,
                0xC4 => try d.parseDht(seg),
                0xDB => try d.parseDqt(seg),
                0xDD => {
                    if (seg.len < 2) return error.InvalidData;
                    d.restart_interval = be16(seg, 0);
                },
                0xDA => pos = try d.decodeScan(seg, pos),
                0xE0...0xEF => d.parseApp(m, seg),
                else => {},
            }
        }
        if (!d.frame or d.scans == 0) return error.InvalidData;
    }

    fn finishProgressive(d: *Decoder) void {
        var blk: [64]i32 = undefined;
        for (d.comps[0..d.ncomp]) |*c| {
            const q = &d.qt[c.tq];
            const stride = @as(usize, c.bw) * 8;
            var by: usize = 0;
            while (by < c.bh) : (by += 1) {
                var bx: usize = 0;
                while (bx < c.bw) : (bx += 1) {
                    const co = c.coefs[(by * c.bw + bx) * 64 ..][0..64];
                    for (0..64) |i| blk[i] = clampCoef(@as(i32, co[i]) *% q[i]);
                    idct(&blk, c.plane[(by * 8 * c.bw + bx) * 8 ..], stride);
                }
            }
        }
    }

    fn output(d: *Decoder) Error!types.Image {
        const W = d.width;
        const H = d.height;
        const nbytes = try types.checkSize(W, H, d.limits);
        const out = try d.alloc.alloc(u8, nbytes);
        errdefer d.alloc.free(out);
        const nc = d.ncomp;
        // Row buffers for upsampled components + one i32 column-sum buffer.
        const scratch = try d.alloc.alloc(u8, @as(usize, W) * nc);
        defer d.alloc.free(scratch);
        var maxcw: usize = 0;
        for (d.comps[0..nc]) |c| maxcw = @max(maxcw, @as(usize, c.cw));
        const colsum = try d.alloc.alloc(i32, maxcw + 2);
        defer d.alloc.free(colsum);

        const rgb_mode = nc == 3 and (d.adobe_transform == 0 or
            (d.adobe_transform < 0 and d.comps[0].id == 'R' and d.comps[1].id == 'G' and d.comps[2].id == 'B'));

        var rows: [3][]const u8 = undefined;
        var y: u32 = 0;
        while (y < H) : (y += 1) {
            for (0..nc) |ci| {
                const c = &d.comps[ci];
                rows[ci] = upsampleRow(c, d.hmax / c.h, d.vmax / c.v, y, W, scratch[ci * W ..][0..W], colsum);
            }
            const o = out[@as(usize, y) * W * 4 ..][0 .. @as(usize, W) * 4];
            if (nc == 1) {
                const g = rows[0][0..W];
                for (0..W) |x| {
                    o[x * 4 + 0] = g[x];
                    o[x * 4 + 1] = g[x];
                    o[x * 4 + 2] = g[x];
                    o[x * 4 + 3] = 255;
                }
            } else if (rgb_mode) {
                for (0..W) |x| {
                    o[x * 4 + 0] = rows[0][x];
                    o[x * 4 + 1] = rows[1][x];
                    o[x * 4 + 2] = rows[2][x];
                    o[x * 4 + 3] = 255;
                }
            } else {
                yccRow(rows[0][0..W], rows[1][0..W], rows[2][0..W], o);
            }
        }
        if (d.limits.apply_exif_orientation and d.orientation > 1 and d.orientation <= 8) {
            const rot = try orient(d.alloc, out, W, H, d.orientation);
            d.alloc.free(out);
            return rot;
        }
        return .{ .width = W, .height = H, .data = out };
    }
};

fn clampCoef(v: i32) i32 {
    return std.math.clamp(v, -32768, 32767);
}

const little_endian = @import("builtin").cpu.arch.endian() == .little;
const V8i = @Vector(8, i32);

fn yccRow(yr: []const u8, cbr: []const u8, crr: []const u8, o: []u8) void {
    var x: usize = 0;
    if (little_endian) {
        const half: V8i = @splat(32768);
        const s16: @Vector(8, u5) = @splat(16);
        while (x + 8 <= yr.len) : (x += 8) {
            const yv: V8i = @intCast(@as(@Vector(8, u8), yr[x..][0..8].*));
            const cb = @as(V8i, @intCast(@as(@Vector(8, u8), cbr[x..][0..8].*))) - @as(V8i, @splat(128));
            const cr = @as(V8i, @intCast(@as(@Vector(8, u8), crr[x..][0..8].*))) - @as(V8i, @splat(128));
            const r = clampV(yv + ((cr * @as(V8i, @splat(91881)) + half) >> s16));
            const g = clampV(yv + ((cb * @as(V8i, @splat(-22554)) + cr * @as(V8i, @splat(-46802)) + half) >> s16));
            const b = clampV(yv + ((cb * @as(V8i, @splat(116130)) + half) >> s16));
            const px = r | (g << @splat(8)) | (b << @splat(16)) | @as(@Vector(8, u32), @splat(0xFF000000));
            o[x * 4 ..][0..32].* = @bitCast(px);
        }
    }
    while (x < yr.len) : (x += 1) {
        const yv: i32 = yr[x];
        const cb: i32 = @as(i32, cbr[x]) - 128;
        const cr: i32 = @as(i32, crr[x]) - 128;
        o[x * 4 + 0] = clamp8(yv + ((91881 * cr + 32768) >> 16));
        o[x * 4 + 1] = clamp8(yv + ((-22554 * cb - 46802 * cr + 32768) >> 16));
        o[x * 4 + 2] = clamp8(yv + ((116130 * cb + 32768) >> 16));
        o[x * 4 + 3] = 255;
    }
}

inline fn clampV(v: V8i) @Vector(8, u32) {
    return @intCast(@max(@min(v, @as(V8i, @splat(255))), @as(V8i, @splat(0))));
}

const interleave_mask = blk: {
    var m: [16]i32 = undefined;
    for (0..8) |j| {
        m[2 * j] = j;
        m[2 * j + 1] = ~@as(i32, j);
    }
    break :blk m;
};

inline fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// Produces output row `y` (full resolution, `w` samples) of component `c` whose horizontal /
/// vertical upsampling ratios are `sx`, `sy`. Fancy (triangle) filtering for ratios 1/2,
/// replication otherwise. Returns a slice of length >= w.
fn upsampleRow(c: *const Component, sx: u32, sy: u32, y: u32, w: u32, buf: []u8, colsum: []i32) []const u8 {
    const stride = @as(usize, c.bw) * 8;
    const cw: usize = c.cw;
    const last_row = c.ch - 1;
    if (sx == 1 and sy == 1) return c.plane[@as(usize, y) * stride ..][0..w];
    const fancy = sx <= 2 and sy <= 2;
    if (!fancy) {
        const src = c.plane[@as(usize, @min(y / sy, last_row)) * stride ..][0..stride];
        for (buf[0..w], 0..) |*o, x| o.* = src[@min(x / sx, cw - 1)];
        return buf[0..w];
    }
    // Vertical pass into colsum[1..cw+1], scaled by 4 when sy == 2 (else by 1).
    const iy = y / sy;
    const cur = c.plane[@as(usize, iy) * stride ..][0..cw];
    if (sy == 2) {
        const oy: u32 = if (y & 1 == 0) (if (iy == 0) 0 else iy - 1) else @min(iy + 1, last_row);
        const oth = c.plane[@as(usize, oy) * stride ..][0..cw];
        for (colsum[1 .. cw + 1], cur, oth) |*s, a, b| s.* = @as(i32, a) * 3 + b;
    } else {
        for (colsum[1 .. cw + 1], cur) |*s, a| s.* = a;
    }
    if (sx == 1) {
        // h1v2: (3a + b + 1) >> 2 (matches libjpeg-turbo/mozjpeg output bit-exactly).
        const bias: i32 = 1;
        for (buf[0..w], colsum[1 .. w + 1]) |*o, s| o.* = @intCast((s + bias) >> 2);
        return buf[0..w];
    }
    colsum[0] = colsum[1];
    colsum[cw + 1] = colsum[cw];
    const sh: u5 = if (sy == 2) 4 else 2;
    const be: i32 = if (sy == 2) 8 else 1;
    const bo: i32 = if (sy == 2) 7 else 2;
    var x: usize = 0;
    var i: usize = 1;
    {
        const vbe: V8i = @splat(be);
        const vbo: V8i = @splat(bo);
        const vsh: @Vector(8, u5) = @splat(sh);
        while (i + 8 <= cw + 1 and x + 16 <= w) : ({
            x += 16;
            i += 8;
        }) {
            const t = @as(V8i, colsum[i..][0..8].*) * @as(V8i, @splat(3));
            // (`@truncate` of the 0..255 results: an `@intCast` narrowing of the i32 vectors
            // miscompiled on x86-64-v2 (SSE4.2) and gave the native addon other pixels than wasm)
            const e: @Vector(8, u8) = @truncate(@as(@Vector(8, u32), @bitCast((t + @as(V8i, colsum[i - 1 ..][0..8].*) + vbe) >> vsh)));
            const od: @Vector(8, u8) = @truncate(@as(@Vector(8, u32), @bitCast((t + @as(V8i, colsum[i + 1 ..][0..8].*) + vbo) >> vsh)));
            buf[x..][0..16].* = @shuffle(u8, e, od, interleave_mask);
        }
    }
    while (x + 1 < w) : ({
        x += 2;
        i += 1;
    }) {
        const t = colsum[i] * 3;
        buf[x] = @intCast((t + colsum[i - 1] + be) >> sh);
        buf[x + 1] = @intCast((t + colsum[i + 1] + bo) >> sh);
    }
    if (x < w) buf[x] = @intCast((colsum[i] * 3 + colsum[i - 1] + be) >> sh);
    return buf[0..w];
}

// libjpeg "islow" IDCT (jidctint.c): CONST_BITS 13, PASS1_BITS 2. Wrapping arithmetic so
// garbage coefficients cannot trap; inputs are clamped to i16 range beforehand.
const F_0_298 = 2446;
const F_0_390 = 3196;
const F_0_541 = 4433;
const F_0_765 = 6270;
const F_0_899 = 7373;
const F_1_175 = 9633;
const F_1_501 = 12299;
const F_1_847 = 15137;
const F_1_961 = 16069;
const F_2_053 = 16819;
const F_2_562 = 20995;
const F_3_072 = 25172;

const V8 = @Vector(8, i32);

inline fn vc(comptime c: i32) V8 {
    return @splat(c);
}

/// One 8-point islow 1-D IDCT applied lane-wise to 8 vectors (s[k] = k-th input of each lane).
inline fn idct1d(s: [8]V8, comptime shift: u5, comptime round: i32) [8]V8 {
    // even part
    const z1 = (s[2] +% s[6]) *% vc(F_0_541);
    const t2 = z1 +% s[6] *% vc(-F_1_847);
    const t3 = z1 +% s[2] *% vc(F_0_765);
    const t0 = (s[0] +% s[4]) << @splat(13);
    const t1 = (s[0] -% s[4]) << @splat(13);
    const t10 = t0 +% t3 +% vc(round);
    const t13 = t0 -% t3 +% vc(round);
    const t11 = t1 +% t2 +% vc(round);
    const t12 = t1 -% t2 +% vc(round);
    // odd part
    const z5 = (s[7] +% s[3] +% s[5] +% s[1]) *% vc(F_1_175);
    const y1 = (s[7] +% s[1]) *% vc(-F_0_899);
    const y2 = (s[5] +% s[3]) *% vc(-F_2_562);
    const y3 = (s[7] +% s[3]) *% vc(-F_1_961) +% z5;
    const y4 = (s[5] +% s[1]) *% vc(-F_0_390) +% z5;
    const o0 = s[7] *% vc(F_0_298) +% y1 +% y3;
    const o1 = s[5] *% vc(F_2_053) +% y2 +% y4;
    const o2 = s[3] *% vc(F_3_072) +% y2 +% y3;
    const o3 = s[1] *% vc(F_1_501) +% y1 +% y4;
    const sh: @Vector(8, u5) = @splat(shift);
    return .{
        (t10 +% o3) >> sh, (t11 +% o2) >> sh, (t12 +% o1) >> sh, (t13 +% o0) >> sh,
        (t13 -% o0) >> sh, (t12 -% o1) >> sh, (t11 -% o2) >> sh, (t10 -% o3) >> sh,
    };
}

/// Inverse DCT of dequantized natural-order coefficients into an 8x8 block of `dst`
/// (row stride `stride`), level-shifted and clamped to 0..255. Bit-exact with libjpeg's
/// jidctint.c; vectorised across the 8 columns (pass 1) and 8 rows (pass 2).
fn idct(blk: *const [64]i32, dst: []u8, stride: usize) void {
    var rows: [8]V8 = undefined;
    for (0..8) |r| rows[r] = blk[r * 8 ..][0..8].*;
    // Pass 1 (columns): result p[k] is row k of the workspace, scaled by 2^PASS1_BITS.
    const p = idct1d(rows, 11, 1 << 10);
    var t: [8][8]i32 = undefined;
    for (0..8) |k| {
        const a: [8]i32 = p[k];
        for (0..8) |c| t[c][k] = a[c];
    }
    var cols: [8]V8 = undefined;
    for (0..8) |c| cols[c] = t[c];
    // Pass 2 (rows): q[k] lane r = output sample (row r, column k). Rounding + level shift folded in.
    const q = idct1d(cols, 18, (1 << 17) + (128 << 18));
    for (0..8) |k| {
        const v: [8]i32 = @max(@min(q[k], vc(255)), vc(0));
        for (0..8) |r| dst[r * stride + k] = @intCast(v[r]);
    }
}

/// Extracts the EXIF Orientation (tag 0x0112) from a TIFF block; 1 if absent/invalid.
fn exifOrientation(t: []const u8) u8 {
    if (t.len < 8) return 1;
    const le = t[0] == 'I' and t[1] == 'I';
    if (!le and !(t[0] == 'M' and t[1] == 'M')) return 1;
    const r16 = struct {
        fn f(b: []const u8, i: usize, l: bool) u32 {
            return if (l) @as(u32, b[i]) | (@as(u32, b[i + 1]) << 8) else (@as(u32, b[i]) << 8) | b[i + 1];
        }
    }.f;
    const ifd: usize = (@as(usize, r16(t, 4, le)) << 16 | r16(t, 6, le));
    const ifd0: usize = if (le) (@as(usize, r16(t, 6, le)) << 16) | r16(t, 4, le) else ifd;
    if (ifd0 > t.len or t.len - ifd0 < 2) return 1;
    const n = r16(t, ifd0, le);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = ifd0 + 2 + i * 12;
        if (e + 12 > t.len) return 1;
        if (r16(t, e, le) == 0x0112) {
            const v = r16(t, e + 8, le);
            return if (v >= 1 and v <= 8) @intCast(v) else 1;
        }
    }
    return 1;
}

/// Applies EXIF orientation `o` (2..8) to an RGBA image, returning a new buffer.
fn orient(alloc: std.mem.Allocator, src: []const u8, w: u32, h: u32, o: u8) Error!types.Image {
    const swap = o >= 5;
    const ow = if (swap) h else w;
    const oh = if (swap) w else h;
    const dst = try alloc.alloc(u8, src.len);
    var oy: u32 = 0;
    while (oy < oh) : (oy += 1) {
        var ox: u32 = 0;
        while (ox < ow) : (ox += 1) {
            var sx: u32 = ox;
            var sy: u32 = oy;
            switch (o) {
                2 => sx = w - 1 - ox,
                3 => {
                    sx = w - 1 - ox;
                    sy = h - 1 - oy;
                },
                4 => sy = h - 1 - oy,
                5 => {
                    sx = oy;
                    sy = ox;
                },
                6 => {
                    sx = oy;
                    sy = h - 1 - ox;
                },
                7 => {
                    sx = w - 1 - oy;
                    sy = h - 1 - ox;
                },
                else => { // 8
                    sx = w - 1 - oy;
                    sy = ox;
                },
            }
            const si = (@as(usize, sy) * w + sx) * 4;
            const di = (@as(usize, oy) * ow + ox) * 4;
            @memcpy(dst[di..][0..4], src[si..][0..4]);
        }
    }
    return .{ .width = ow, .height = oh, .data = dst };
}

/// Decodes a JPEG into straight RGBA8 (alpha 255). EXIF orientation is applied only when
/// `limits.apply_exif_orientation` is set (takumi/zune-jpeg does not apply it).
/// The returned `Image.data` is allocated with `alloc`; all temporaries are freed before return.
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8, limits: types.Limits) Error!types.Image {
    var d = Decoder{ .alloc = alloc, .data = bytes, .limits = limits };
    for (&d.huff) |*h| h.defined = false;
    defer d.deinit();
    try d.run();
    if (d.progressive) d.finishProgressive();
    return d.output();
}

/// Header-only scan for the frame size: returns {width, height} as stored in the SOFn
/// segment (before any EXIF orientation), or null if no valid SOF is found.
pub fn dimensions(bytes: []const u8) ?[2]u32 {
    const s = bytes;
    if (s.len < 4 or s[0] != 0xFF or s[1] != 0xD8) return null;
    var pos: usize = 2;
    while (pos < s.len) {
        while (pos < s.len and s[pos] != 0xFF) pos += 1;
        while (pos < s.len and s[pos] == 0xFF) pos += 1;
        if (pos >= s.len) return null;
        const m = s[pos];
        pos += 1;
        if (m == 0 or m == 0x01 or m == 0xD8 or (m >= 0xD0 and m <= 0xD7)) continue;
        if (m == 0xD9 or m == 0xDA) return null;
        if (s.len - pos < 2) return null;
        const len = Decoder.be16(s, pos);
        if (len < 2 or s.len - pos < len) return null;
        const is_sof = (m >= 0xC0 and m <= 0xCF) and m != 0xC4 and m != 0xC8 and m != 0xCC;
        if (is_sof) {
            if (len < 7) return null;
            const hh = Decoder.be16(s, pos + 3);
            const ww = Decoder.be16(s, pos + 5);
            if (ww == 0 or hh == 0) return null;
            return .{ ww, hh };
        }
        pos += len;
    }
    return null;
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

fn diffRgb(img: types.Image, ref: []const u8) [2]f64 {
    var mx: u32 = 0;
    var sum: u64 = 0;
    const n = @as(usize, img.width) * img.height;
    for (0..n) |i| {
        for (0..3) |ch| {
            const a: i32 = img.data[i * 4 + ch];
            const b: i32 = ref[i * 3 + ch];
            const dd: u32 = @abs(a - b);
            mx = @max(mx, dd);
            sum += dd;
        }
    }
    return .{ @floatFromInt(mx), @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n * 3)) };
}

const vectors = [_]struct { name: []const u8, jpg: []const u8, rgb: []const u8 }{
    .{ .name = "b444", .jpg = @embedFile("testdata/jpeg_b444.jpg"), .rgb = @embedFile("testdata/jpeg_b444.rgb") },
    .{ .name = "b422", .jpg = @embedFile("testdata/jpeg_b422.jpg"), .rgb = @embedFile("testdata/jpeg_b422.rgb") },
    .{ .name = "b420", .jpg = @embedFile("testdata/jpeg_b420.jpg"), .rgb = @embedFile("testdata/jpeg_b420.rgb") },
    .{ .name = "b440", .jpg = @embedFile("testdata/jpeg_b440.jpg"), .rgb = @embedFile("testdata/jpeg_b440.rgb") },
    .{ .name = "b411", .jpg = @embedFile("testdata/jpeg_b411.jpg"), .rgb = @embedFile("testdata/jpeg_b411.rgb") },
    .{ .name = "b420r", .jpg = @embedFile("testdata/jpeg_b420r.jpg"), .rgb = @embedFile("testdata/jpeg_b420r.rgb") },
    .{ .name = "gray", .jpg = @embedFile("testdata/jpeg_gray.jpg"), .rgb = @embedFile("testdata/jpeg_gray.rgb") },
    .{ .name = "p420", .jpg = @embedFile("testdata/jpeg_p420.jpg"), .rgb = @embedFile("testdata/jpeg_p420.rgb") },
    .{ .name = "p444", .jpg = @embedFile("testdata/jpeg_p444.jpg"), .rgb = @embedFile("testdata/jpeg_p444.rgb") },
    .{ .name = "p333", .jpg = @embedFile("testdata/jpeg_p333.jpg"), .rgb = @embedFile("testdata/jpeg_p333.rgb") },
    .{ .name = "pgray", .jpg = @embedFile("testdata/jpeg_pgray.jpg"), .rgb = @embedFile("testdata/jpeg_pgray.rgb") },
    .{ .name = "mozb420", .jpg = @embedFile("testdata/jpeg_mozb420.jpg"), .rgb = @embedFile("testdata/jpeg_mozb420.rgb") },
};

test "jpeg: small vectors vs libjpeg-turbo (mozjpeg) reference" {
    // References were decoded with @jsquash/jpeg (mozjpeg = libjpeg-turbo decoder: islow IDCT,
    // fancy upsampling). Synthetic 61x43 image; baseline variants from a patched jpeg-js
    // encoder (sampling 1x1/2x1/2x2/1x2/4x1, restart intervals), progressive from mozjpeg.
    for (vectors) |v| {
        const img = try decode(testing.allocator, v.jpg, .{});
        defer img.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 61), img.width);
        try testing.expectEqual(@as(u32, 43), img.height);
        const dm = diffRgb(img, v.rgb);
        if (dm[0] > 0) {
            std.debug.print("{s}: max {d} mean {d:.4}\n", .{ v.name, dm[0], dm[1] });
            return error.TestUnexpectedResult;
        }
        const dims = dimensions(v.jpg).?;
        try testing.expectEqual(@as(u32, 61), dims[0]);
        try testing.expectEqual(@as(u32, 43), dims[1]);
    }
}

fn sparseDiff(img: types.Image, ref: []const u8, step: u32) [2]f64 {
    var mx: u32 = 0;
    var sum: u64 = 0;
    var n: u64 = 0;
    var i: usize = 0;
    var y: u32 = 0;
    while (y < img.height) : (y += step) {
        var x: u32 = 0;
        while (x < img.width) : (x += step) {
            const p = (@as(usize, y) * img.width + x) * 4;
            for (0..3) |ch| {
                const dd: u32 = @abs(@as(i32, img.data[p + ch]) - ref[i]);
                i += 1;
                mx = @max(mx, dd);
                sum += dd;
                n += 1;
            }
        }
    }
    return .{ @floatFromInt(mx), @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n)) };
}

test "jpeg: real progressive photos vs takumi (zune-jpeg) output" {
    // References: @takumi-rs/wasm rendering {type:"image"} at intrinsic size, format "raw",
    // sampled every 5th / 16th pixel.
    const cases = .{
        .{ @embedFile("testdata/jpeg_luma_prog.jpg"), @embedFile("testdata/jpeg_luma_prog.takumi_s5.rgb"), 5, 525, 525 },
        .{ @embedFile("testdata/jpeg_martin_prog.jpg"), @embedFile("testdata/jpeg_martin_prog.takumi_s16.rgb"), 16, 1920, 1280 },
    };
    inline for (cases) |cs| {
        const img = try decode(testing.allocator, cs[0], .{});
        defer img.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, cs[3]), img.width);
        try testing.expectEqual(@as(u32, cs[4]), img.height);
        const dm = sparseDiff(img, cs[1], cs[2]);
        if (dm[0] > 6 or dm[1] > 0.5) {
            std.debug.print("takumi diff: max {d} mean {d:.4}\n", .{ dm[0], dm[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "jpeg: arithmetic coding / lossless are rejected cleanly" {
    var buf: [4096]u8 = undefined;
    const src = vectors[0].jpg;
    @memcpy(buf[0..src.len], src);
    const i = std.mem.indexOf(u8, src, "\xFF\xC0").?;
    buf[i + 1] = 0xC9;
    try testing.expectError(error.UnsupportedFormat, decode(testing.allocator, buf[0..src.len], .{}));
    buf[i + 1] = 0xC3;
    try testing.expectError(error.UnsupportedFormat, decode(testing.allocator, buf[0..src.len], .{}));
}

test "jpeg: limits" {
    try testing.expectError(error.ImageTooLarge, decode(testing.allocator, vectors[0].jpg, .{ .max_pixels = 100 }));
}

test "jpeg: EXIF orientation" {
    const base = try decode(testing.allocator, vectors[0].jpg, .{});
    defer base.deinit(testing.allocator);
    var o: u8 = 1;
    while (o <= 8) : (o += 1) {
        // Insert an APP1 Exif segment (big-endian TIFF, one IFD0 entry) after SOI.
        const app1 = [_]u8{ 0xFF, 0xE1, 0, 34, 'E', 'x', 'i', 'f', 0, 0, 'M', 'M', 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, o, 0, 0, 0, 0, 0, 0 };
        var buf: [4096]u8 = undefined;
        const src = vectors[0].jpg;
        @memcpy(buf[0..2], src[0..2]);
        @memcpy(buf[2..][0..app1.len], &app1);
        @memcpy(buf[2 + app1.len ..][0 .. src.len - 2], src[2..]);
        const bytes = buf[0 .. src.len + app1.len];
        const plain = try decode(testing.allocator, bytes, .{});
        defer plain.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, base.data, plain.data);
        const img = try decode(testing.allocator, bytes, .{ .apply_exif_orientation = true });
        defer img.deinit(testing.allocator);
        const W = base.width;
        const H = base.height;
        if (o >= 5) {
            try testing.expectEqual(H, img.width);
            try testing.expectEqual(W, img.height);
        } else try testing.expectEqual(W, img.width);
        // Check where source pixel (sx,sy)=(3,1) lands.
        const sx: u32 = 3;
        const sy: u32 = 1;
        const dst: [2]u32 = switch (o) {
            1 => .{ sx, sy },
            2 => .{ W - 1 - sx, sy },
            3 => .{ W - 1 - sx, H - 1 - sy },
            4 => .{ sx, H - 1 - sy },
            5 => .{ sy, sx },
            6 => .{ H - 1 - sy, sx },
            7 => .{ H - 1 - sy, W - 1 - sx },
            else => .{ sy, W - 1 - sx },
        };
        const a = base.data[(sy * W + sx) * 4 ..][0..4];
        const b = img.data[(dst[1] * img.width + dst[0]) * 4 ..][0..4];
        try testing.expectEqualSlices(u8, a, b);
    }
}

test "jpeg: fuzz (mutations + truncations) without crash or leak" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    const seeds = [_][]const u8{ vectors[0].jpg, vectors[2].jpg, vectors[5].jpg, vectors[6].jpg, vectors[7].jpg, vectors[9].jpg, vectors[10].jpg };
    var buf: [8192]u8 = undefined;
    var ok: usize = 0;
    var iter: usize = 0;
    while (iter < 6000) : (iter += 1) {
        const src = seeds[iter % seeds.len];
        var len = src.len;
        @memcpy(buf[0..len], src);
        const kind = rnd.uintLessThan(u32, 4);
        if (kind == 0) {
            len = rnd.uintLessThan(usize, len);
        } else {
            const nmut = 1 + rnd.uintLessThan(usize, 8);
            for (0..nmut) |_| {
                const p = rnd.uintLessThan(usize, len);
                buf[p] = switch (rnd.uintLessThan(u32, 3)) {
                    0 => rnd.int(u8),
                    1 => buf[p] ^ (@as(u8, 1) << rnd.int(u3)),
                    else => 0xFF,
                };
            }
            if (kind == 3) len = rnd.uintLessThan(usize, len + 1);
        }
        _ = dimensions(buf[0..len]);
        if (decode(testing.allocator, buf[0..len], .{ .max_pixels = 1 << 20, .apply_exif_orientation = true })) |img| {
            img.deinit(testing.allocator);
            ok += 1;
        } else |_| {}
    }
    // Pure random garbage too.
    iter = 0;
    while (iter < 2000) : (iter += 1) {
        const len = 2 + rnd.uintLessThan(usize, 600);
        rnd.bytes(buf[0..len]);
        buf[0] = 0xFF;
        buf[1] = 0xD8;
        if (decode(testing.allocator, buf[0..len], .{ .max_pixels = 1 << 20 })) |img| img.deinit(testing.allocator) else |_| {}
    }
    try testing.expect(ok > 0);
}

test "jpeg: too many scans are rejected" {
    const a = testing.allocator;
    const src = vectors[0].jpg;
    // Repeat the first scan (SOS header + entropy data up to the next marker) past the cap.
    const sos = std.mem.indexOf(u8, src, "\xFF\xDA").?;
    var end = sos + 2 + std.mem.readInt(u16, src[sos + 2 ..][0..2], .big);
    while (end + 1 < src.len and !(src[end] == 0xFF and src[end + 1] != 0 and (src[end + 1] < 0xD0 or src[end + 1] > 0xD7))) end += 1;
    const scan = src[sos..end];
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(a);
    try file.appendSlice(a, src[0..sos]);
    for (0..max_scans + 1) |_| try file.appendSlice(a, scan);
    try file.appendSlice(a, "\xFF\xD9");
    try testing.expectError(error.InvalidData, decode(a, file.items, .{}));
    // At the cap it still decodes.
    file.shrinkRetainingCapacity(sos + max_scans * scan.len);
    try file.appendSlice(a, "\xFF\xD9");
    const img = try decode(a, file.items, .{});
    img.deinit(a);
}
