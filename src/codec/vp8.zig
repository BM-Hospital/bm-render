//! Lossy WebP (VP8 key frame) decoder, a bit-exact port of libwebp's decoder
//! (src/dec/vp8_dec.c, tree_dec.c, quant_dec.c, frame_dec.c, dsp/dec.c, dsp/upsampling.c):
//! boolean decoder, segmentation, quantizer deltas, token partitions, all intra modes
//! (16x16 / 4x4 luma, 8x8 chroma), WHT + DCT inverse transforms, simple and normal loop
//! filters, then YUV420 -> RGB with libwebp's "fancy" upsampler (WebPDecodeRGBA defaults).
//! Optional alpha from a VP8X `ALPH` chunk (raw or VP8L-compressed; none/horizontal/
//! vertical/gradient unfiltering). No dithering (libwebp's default is off too).
//!
//! Untrusted input: every read is bounds-checked; truncated streams fail like libwebp's
//! (premature end of partition => error.InvalidData). Memory: Y/U/V planes padded to whole
//! macroblocks (~1.5 bytes/pixel) + small per-column state, all freed before returning;
//! only `Image.data` stays allocated from `alloc`.
const std = @import("std");
const types = @import("types.zig");
const webp_dec = @import("webp_dec.zig");

const Image = types.Image;
const Limits = types.Limits;
const Error = types.Error;

/// Width/height of a raw `VP8 ` chunk payload (key frame header), or null.
pub fn dimensions(vp8: []const u8) ?[2]u32 {
    if (vp8.len < 10) return null;
    if (vp8[0] & 1 != 0) return null; // not a key frame
    if (vp8[3] != 0x9d or vp8[4] != 0x01 or vp8[5] != 0x2a) return null;
    const w = (@as(u32, vp8[6]) | (@as(u32, vp8[7]) << 8)) & 0x3fff;
    const h = (@as(u32, vp8[8]) | (@as(u32, vp8[9]) << 8)) & 0x3fff;
    if (w == 0 or h == 0) return null;
    return .{ w, h };
}

/// Decodes a `VP8 ` chunk payload to straight RGBA8. `alph` is the optional `ALPH` chunk
/// payload of a VP8X file (null => opaque). Result allocated from `alloc`.
pub fn decode(alloc: std.mem.Allocator, vp8: []const u8, alph: ?[]const u8, limits: Limits) Error!Image {
    const dims = dimensions(vp8) orelse return error.InvalidData;
    const nbytes = try types.checkSize(dims[0], dims[1], limits);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f = try decodeYuv(arena, vp8);
    const out = try alloc.alloc(u8, nbytes);
    errdefer alloc.free(out);
    toRgba(&f, out);
    if (alph) |a| {
        const plane = try arena.alloc(u8, nbytes / 4);
        try decodeAlpha(arena, a, f.w, f.h, plane);
        for (plane, 0..) |v, i| out[i * 4 + 3] = v;
    }
    return .{ .width = f.w, .height = f.h, .data = out };
}

// =============================================================================== bool decoder

const BoolDec = struct {
    data: []const u8 = &.{},
    pos: usize = 0,
    value: u64 = 0,
    bits: i32 = -8,
    range: u32 = 255 - 1,
    eof: bool = false,

    /// Mirrors VP8InitBitReader; false if the first byte is already out of range.
    fn init(data: []const u8) BoolDec {
        var b = BoolDec{ .data = data };
        b.loadNewBytes();
        return b;
    }
    fn valid(b: *const BoolDec) bool {
        return (b.value >> @intCast(@max(b.bits, 0))) <= b.range;
    }
    fn loadNewBytes(b: *BoolDec) void {
        if (b.data.len >= 8 and b.pos <= b.data.len - 8) {
            const raw = @as(*align(1) const u64, @ptrCast(b.data[b.pos..][0..8])).*;
            const v = std.mem.bigToNative(u64, raw);
            b.pos += 7;
            b.value = (v >> 8) | (b.value << 56);
            b.bits += 56;
        } else if (b.pos < b.data.len) {
            b.bits += 8;
            b.value = @as(u64, b.data[b.pos]) | (b.value << 8);
            b.pos += 1;
        } else if (!b.eof) {
            b.value <<= 8;
            b.bits += 8;
            b.eof = true;
        } else {
            b.bits = 0;
        }
    }
    fn getBit(b: *BoolDec, prob: u32) u32 {
        return b.getBitInl(prob);
    }
    /// Inlined variant for the token loop.
    inline fn getBitInl(b: *BoolDec, prob: u32) u32 {
        var range = b.range;
        if (b.bits < 0) b.loadNewBytes();
        const pos: u6 = @intCast(b.bits);
        const split = (range * prob) >> 8;
        const value: u32 = @truncate(b.value >> pos);
        var bit: u32 = 0;
        if (value > split) {
            range -= split;
            b.value -%= @as(u64, split + 1) << pos;
            bit = 1;
        } else {
            range = split + 1;
        }
        const shift: u5 = @intCast(7 ^ std.math.log2_int(u32, range));
        range <<= shift;
        b.bits -= shift;
        b.range = range - 1;
        return bit;
    }
    fn get(b: *BoolDec) u32 {
        return b.getBit(0x80);
    }
    fn getValue(b: *BoolDec, n: u5) u32 {
        var v: u32 = 0;
        var i = n;
        while (i > 0) {
            i -= 1;
            v |= b.getBit(0x80) << i;
        }
        return v;
    }
    fn getSignedValue(b: *BoolDec, n: u5) i32 {
        const v: i32 = @intCast(b.getValue(n));
        return if (b.get() != 0) -v else v;
    }
    fn optSigned(b: *BoolDec, n: u5) i32 {
        return if (b.get() != 0) b.getSignedValue(n) else 0;
    }
};

// =============================================================================== decoder

const BPS = 32;
const Y_OFF = BPS * 1 + 8;
const U_OFF = Y_OFF + BPS * 16 + BPS;
const V_OFF = U_OFF + 16;
const YUV_SIZE = BPS * 17 + BPS * 9;

// Intra modes (libwebp numbering).
const B_DC = 0;
const B_TM = 1;
const B_VE = 2;
const B_HE = 3;
const B_RD = 4;
const B_VR = 5;
const B_LD = 6;
const B_VL = 7;
const B_HD = 8;
const B_HU = 9;
const DC_NOTOP = 4;
const DC_NOLEFT = 5;
const DC_NOTOPLEFT = 6;

const Quant = struct { y1: [2]i32, y2: [2]i32, uv: [2]i32 };
const FInfo = struct { limit: u8 = 0, ilevel: u8 = 0, inner: bool = false, hev: u8 = 0 };

/// Decoded planes (padded to whole macroblocks).
pub const Yuv = struct {
    w: u32,
    h: u32,
    y_stride: usize,
    uv_stride: usize,
    y: []u8,
    u: []u8,
    v: []u8,
};

const Dec = struct {
    mb_w: u32,
    mb_h: u32,
    br: BoolDec,
    parts: [8]BoolDec = @splat(.{}),
    num_parts_m1: u32 = 0,
    // segment header
    use_segment: bool = false,
    update_map: bool = false,
    absolute_delta: bool = true,
    quantizer: [4]i32 = @splat(0),
    filter_strength: [4]i32 = @splat(0),
    seg_proba: [3]u32 = @splat(255),
    // filter header
    filter_type: u2 = 0,
    level: i32 = 0,
    sharpness: i32 = 0,
    use_lf_delta: bool = false,
    ref_lf_delta: [4]i32 = @splat(0),
    mode_lf_delta: [4]i32 = @splat(0),
    dqm: [4]Quant = undefined,
    proba: [4][8][3][11]u8 = undefined,
    use_skip_proba: bool = false,
    skip_p: u32 = 0,
    fstrengths: [4][2]FInfo = undefined,
    // per-row state
    intra_t: []u8,
    intra_l: [4]u8 = @splat(B_DC),
    nz: []u8, // per column: bits 0-3 luma top nz, 4-7 chroma (as libwebp mb->nz)
    nz_dc: []u8,
    left_nz: u8 = 0,
    left_nz_dc: u8 = 0,
    yuv_t: []u8, // 32 bytes per column: y[16] u[8] v[8] (unfiltered bottom row of the MB above)
    finfo: []u8, // per MB: fstrength index (seg*2+i4x4) | inner << 3
    yuv_b: [YUV_SIZE]u8 = undefined,
    coeffs: [384]i16 = undefined,
    // current MB
    segment: u8 = 0,
    skip: bool = false,
    is_i4x4: bool = false,
    imodes: [16]u8 = undefined,
    uvmode: u8 = 0,
    non_zero_y: u32 = 0,
    non_zero_uv: u32 = 0,
};

/// Parses and reconstructs a key frame into Y/U/V planes allocated from `arena`.
pub fn decodeYuv(arena: std.mem.Allocator, vp8: []const u8) Error!Yuv {
    const dims = dimensions(vp8) orelse return error.InvalidData;
    const bits = @as(u32, vp8[0]) | (@as(u32, vp8[1]) << 8) | (@as(u32, vp8[2]) << 16);
    const profile = (bits >> 1) & 7;
    const show = (bits >> 4) & 1;
    const part_len: usize = bits >> 5;
    if (profile > 3) return error.InvalidData;
    if (show == 0) return error.UnsupportedFormat;
    const rest = vp8[10..];
    if (part_len > rest.len) return error.InvalidData;

    const mb_w = (dims[0] + 15) >> 4;
    const mb_h = (dims[1] + 15) >> 4;
    var d = try arena.create(Dec);
    d.* = .{
        .mb_w = mb_w,
        .mb_h = mb_h,
        .br = BoolDec.init(rest[0..part_len]),
        .intra_t = try arena.alloc(u8, 4 * @as(usize, mb_w)),
        .nz = try arena.alloc(u8, mb_w),
        .nz_dc = try arena.alloc(u8, mb_w),
        .yuv_t = try arena.alloc(u8, 32 * @as(usize, mb_w)),
        .finfo = try arena.alloc(u8, @as(usize, mb_w) * mb_h),
    };
    if (!d.br.valid()) return error.InvalidData;
    const br = &d.br;
    _ = br.get(); // colorspace
    _ = br.get(); // clamp type (decoder always clamps)

    // Segment header.
    d.use_segment = br.get() != 0;
    if (d.use_segment) {
        d.update_map = br.get() != 0;
        if (br.get() != 0) {
            d.absolute_delta = br.get() != 0;
            for (&d.quantizer) |*q| q.* = br.optSigned(7);
            for (&d.filter_strength) |*q| q.* = br.optSigned(6);
        }
        if (d.update_map) {
            for (&d.seg_proba) |*p| p.* = if (br.get() != 0) br.getValue(8) else 255;
        }
    }
    if (br.eof) return error.InvalidData;

    // Filter header.
    const simple = br.get() != 0;
    d.level = @intCast(br.getValue(6));
    d.sharpness = @intCast(br.getValue(3));
    d.use_lf_delta = br.get() != 0;
    if (d.use_lf_delta and br.get() != 0) {
        for (&d.ref_lf_delta) |*v| {
            if (br.get() != 0) v.* = br.getSignedValue(6);
        }
        for (&d.mode_lf_delta) |*v| {
            if (br.get() != 0) v.* = br.getSignedValue(6);
        }
    }
    d.filter_type = if (d.level == 0) 0 else if (simple) 1 else 2;
    if (br.eof) return error.InvalidData;

    // Partitions.
    {
        const buf = rest[part_len..];
        const last: usize = (@as(usize, 1) << @intCast(br.getValue(2))) - 1;
        d.num_parts_m1 = @intCast(last);
        if (buf.len < 3 * last) return error.InvalidData;
        var start = 3 * last;
        var left = buf.len - 3 * last;
        for (0..last) |p| {
            var psize: usize = @as(usize, buf[p * 3]) | (@as(usize, buf[p * 3 + 1]) << 8) | (@as(usize, buf[p * 3 + 2]) << 16);
            if (psize > left) psize = left;
            d.parts[p] = BoolDec.init(buf[start .. start + psize]);
            if (!d.parts[p].valid()) return error.InvalidData;
            start += psize;
            left -= psize;
        }
        d.parts[last] = BoolDec.init(buf[start..]);
        if (!d.parts[last].valid()) return error.InvalidData;
        if (start >= buf.len) return error.InvalidData;
    }

    // Quantizers.
    {
        const base_q0: i32 = @intCast(br.getValue(7));
        const dqy1_dc = br.optSigned(4);
        const dqy2_dc = br.optSigned(4);
        const dqy2_ac = br.optSigned(4);
        const dquv_dc = br.optSigned(4);
        const dquv_ac = br.optSigned(4);
        for (0..4) |i| {
            var q: i32 = undefined;
            if (d.use_segment) {
                q = d.quantizer[i];
                if (!d.absolute_delta) q += base_q0;
            } else if (i > 0) {
                d.dqm[i] = d.dqm[0];
                continue;
            } else q = base_q0;
            const m = &d.dqm[i];
            m.y1 = .{ dc_table[clip(q + dqy1_dc, 127)], ac_table[clip(q, 127)] };
            m.y2 = .{ @as(i32, dc_table[clip(q + dqy2_dc, 127)]) * 2, (@as(i32, ac_table[clip(q + dqy2_ac, 127)]) * 101581) >> 16 };
            if (m.y2[1] < 8) m.y2[1] = 8;
            m.uv = .{ dc_table[clip(q + dquv_dc, 117)], ac_table[clip(q + dquv_ac, 127)] };
        }
    }
    _ = br.get(); // update_proba (ignored)

    // Coefficient probabilities.
    {
        const flat: *[1056]u8 = @ptrCast(&d.proba);
        for (flat, 0..) |*p, i| {
            p.* = if (br.getBit(coeffs_update_proba[i]) != 0) @intCast(br.getValue(8)) else coeffs_proba0[i];
        }
        d.use_skip_proba = br.get() != 0;
        if (d.use_skip_proba) d.skip_p = br.getValue(8);
    }
    precomputeFilterStrengths(d);

    // Planes.
    const y_stride = @as(usize, mb_w) * 16;
    const uv_stride = @as(usize, mb_w) * 8;
    const yp = try arena.alloc(u8, y_stride * @as(usize, mb_h) * 16);
    const up = try arena.alloc(u8, uv_stride * @as(usize, mb_h) * 8);
    const vp = try arena.alloc(u8, uv_stride * @as(usize, mb_h) * 8);

    @memset(d.intra_t, B_DC);
    @memset(d.nz, 0);
    @memset(d.nz_dc, 0);
    var mb_y: u32 = 0;
    while (mb_y < mb_h) : (mb_y += 1) {
        const tbr = &d.parts[mb_y & d.num_parts_m1];
        d.intra_l = @splat(B_DC);
        d.left_nz = 0;
        d.left_nz_dc = 0;
        var mb_x: u32 = 0;
        while (mb_x < mb_w) : (mb_x += 1) {
            parseIntraMode(d, mb_x);
            var skip = d.use_skip_proba and d.skip;
            if (!skip) {
                skip = parseResiduals(d, mb_x, tbr);
            } else {
                d.left_nz = 0;
                d.nz[mb_x] = 0;
                if (!d.is_i4x4) {
                    d.left_nz_dc = 0;
                    d.nz_dc[mb_x] = 0;
                }
                d.non_zero_y = 0;
                d.non_zero_uv = 0;
            }
            if (tbr.eof) return error.InvalidData;
            d.finfo[@as(usize, mb_y) * mb_w + mb_x] = d.segment * 2 + @intFromBool(d.is_i4x4) | (@as(u8, @intFromBool(!skip)) << 3);
            reconstruct(d, mb_x, mb_y);
            // Copy the macroblock out of the work buffer.
            const yo = @as(usize, mb_y) * 16 * y_stride + @as(usize, mb_x) * 16;
            for (0..16) |j| @memcpy(yp[yo + j * y_stride ..][0..16], d.yuv_b[Y_OFF + j * BPS ..][0..16]);
            const uo = @as(usize, mb_y) * 8 * uv_stride + @as(usize, mb_x) * 8;
            for (0..8) |j| {
                @memcpy(up[uo + j * uv_stride ..][0..8], d.yuv_b[U_OFF + j * BPS ..][0..8]);
                @memcpy(vp[uo + j * uv_stride ..][0..8], d.yuv_b[V_OFF + j * BPS ..][0..8]);
            }
        }
        if (br.eof) return error.InvalidData;
    }

    if (d.filter_type > 0) {
        mb_y = 0;
        while (mb_y < mb_h) : (mb_y += 1) {
            var mb_x: u32 = 0;
            while (mb_x < mb_w) : (mb_x += 1) filterMb(d, mb_x, mb_y, yp, up, vp, y_stride, uv_stride);
        }
    }
    return .{ .w = dims[0], .h = dims[1], .y_stride = y_stride, .uv_stride = uv_stride, .y = yp, .u = up, .v = vp };
}

inline fn clip(v: i32, m: i32) usize {
    return @intCast(if (v < 0) 0 else if (v > m) m else v);
}

fn precomputeFilterStrengths(d: *Dec) void {
    for (0..4) |s| {
        var base: i32 = d.level;
        if (d.use_segment) {
            base = d.filter_strength[s];
            if (!d.absolute_delta) base += d.level;
        }
        for (0..2) |k4| {
            var level = base;
            if (d.use_lf_delta) {
                level += d.ref_lf_delta[0];
                if (k4 == 1) level += d.mode_lf_delta[0];
            }
            level = std.math.clamp(level, 0, 63);
            var info = FInfo{ .inner = k4 == 1 };
            if (level > 0) {
                var ilevel = level;
                if (d.sharpness > 0) {
                    ilevel >>= if (d.sharpness > 4) 2 else 1;
                    if (ilevel > 9 - d.sharpness) ilevel = 9 - d.sharpness;
                }
                if (ilevel < 1) ilevel = 1;
                info.ilevel = @intCast(ilevel);
                info.limit = @intCast(2 * level + ilevel);
                info.hev = if (level >= 40) 2 else if (level >= 15) 1 else 0;
            }
            d.fstrengths[s][k4] = info;
        }
    }
}

fn parseIntraMode(d: *Dec, mb_x: u32) void {
    const br = &d.br;
    const top = d.intra_t[@as(usize, mb_x) * 4 ..][0..4];
    const left = &d.intra_l;
    d.segment = 0;
    if (d.update_map) {
        d.segment = @intCast(if (br.getBit(d.seg_proba[0]) == 0) br.getBit(d.seg_proba[1]) else br.getBit(d.seg_proba[2]) + 2);
    }
    if (d.use_skip_proba) d.skip = br.getBit(d.skip_p) != 0;
    d.is_i4x4 = br.getBit(145) == 0;
    if (!d.is_i4x4) {
        const ymode: u8 = if (br.getBit(156) != 0)
            (if (br.getBit(128) != 0) B_TM else B_HE)
        else
            (if (br.getBit(163) != 0) B_VE else B_DC);
        d.imodes[0] = ymode;
        top.* = @splat(ymode);
        left.* = @splat(ymode);
    } else {
        for (0..4) |y| {
            var ymode = left[y];
            for (0..4) |x| {
                const prob = bmodes_proba[(@as(usize, top[x]) * 10 + ymode) * 9 ..][0..9];
                ymode = if (br.getBit(prob[0]) == 0) B_DC else if (br.getBit(prob[1]) == 0) B_TM else if (br.getBit(prob[2]) == 0) B_VE else if (br.getBit(prob[3]) == 0)
                    (if (br.getBit(prob[4]) == 0) B_HE else if (br.getBit(prob[5]) == 0) B_RD else B_VR)
                else if (br.getBit(prob[6]) == 0) B_LD else if (br.getBit(prob[7]) == 0) B_VL else if (br.getBit(prob[8]) == 0) B_HD else B_HU;
                top[x] = ymode;
            }
            d.imodes[y * 4 ..][0..4].* = top.*;
            left[y] = ymode;
        }
    }
    d.uvmode = if (br.getBit(142) == 0) B_DC else if (br.getBit(114) == 0) B_VE else if (br.getBit(183) != 0) B_TM else B_HE;
}

const zigzag = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
const bands = [17]u8{ 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 };
const cat3456 = [4][]const u8{
    &.{ 173, 148, 140 },
    &.{ 176, 155, 140, 135 },
    &.{ 180, 157, 141, 134, 130 },
    &.{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 },
};

fn getLargeValue(br: *BoolDec, p: *const [11]u8) u32 {
    var v: u32 = undefined;
    if (br.getBit(p[3]) == 0) {
        v = if (br.getBit(p[4]) == 0) 2 else 3 + br.getBit(p[5]);
    } else if (br.getBit(p[6]) == 0) {
        if (br.getBit(p[7]) == 0) {
            v = 5 + br.getBit(159);
        } else {
            v = 7 + 2 * br.getBit(165);
            v += br.getBit(145);
        }
    } else {
        const bit1 = br.getBit(p[8]);
        const bit0 = br.getBit(p[9 + bit1]);
        const cat = 2 * bit1 + bit0;
        v = 0;
        for (cat3456[cat]) |t| v = v + v + br.getBit(t);
        v += 3 + (@as(u32, 8) << @intCast(cat));
    }
    return v;
}

/// Returns the index after the last non-zero coefficient (libwebp GetCoeffs).
fn getCoeffs(br: *BoolDec, prob: *const [8][3][11]u8, ctx: u32, dq: [2]i32, n0: u32, out: *[16]i16) u32 {
    var n = n0;
    var p = &prob[bands[n]][ctx];
    while (n < 16) : (n += 1) {
        if (br.getBitInl(p[0]) == 0) return n;
        while (br.getBitInl(p[1]) == 0) {
            n += 1;
            if (n == 16) return 16;
            p = &prob[bands[n]][0];
        }
        const pn = &prob[bands[n + 1]];
        var v: u32 = undefined;
        if (br.getBitInl(p[2]) == 0) {
            v = 1;
            p = &pn[1];
        } else {
            v = getLargeValue(br, p);
            p = &pn[2];
        }
        const sv: i32 = if (br.getBitInl(0x80) != 0) -@as(i32, @intCast(v)) else @intCast(v);
        out[zigzag[n]] = @truncate(sv *% dq[@intFromBool(n > 0)]);
    }
    return 16;
}

inline fn nzCodeBits(nz_coeffs: u32, nz: u32, dc_nz: bool) u32 {
    return (nz_coeffs << 2) | (if (nz > 3) 3 else if (nz > 1) 2 else @as(u32, @intFromBool(dc_nz)));
}

/// Returns true when all coefficients are zero.
fn parseResiduals(d: *Dec, mb_x: u32, br: *BoolDec) bool {
    const q = &d.dqm[d.segment];
    const dst = &d.coeffs;
    @memset(dst, 0);
    var first: u32 = 0;
    var ac_proba: *const [8][3][11]u8 = &d.proba[3];
    if (!d.is_i4x4) {
        var dc: [16]i16 = @splat(0);
        const ctx: u32 = d.nz_dc[mb_x] + d.left_nz_dc;
        const nz = getCoeffs(br, &d.proba[1], ctx, q.y2, 0, &dc);
        const has: u8 = @intFromBool(nz > 0);
        d.nz_dc[mb_x] = has;
        d.left_nz_dc = has;
        if (nz > 1) {
            transformWht(&dc, dst);
        } else {
            const dc0: i16 = @intCast((@as(i32, dc[0]) + 3) >> 3);
            var i: usize = 0;
            while (i < 256) : (i += 16) dst[i] = dc0;
        }
        first = 1;
        ac_proba = &d.proba[0];
    }
    var tnz: u32 = d.nz[mb_x] & 0x0f;
    var lnz: u32 = d.left_nz & 0x0f;
    var non_zero_y: u32 = 0;
    var non_zero_uv: u32 = 0;
    var blk: usize = 0;
    for (0..4) |_| {
        var l: u32 = lnz & 1;
        var nz_coeffs: u32 = 0;
        for (0..4) |_| {
            const ctx = l + (tnz & 1);
            const out: *[16]i16 = dst[blk * 16 ..][0..16];
            const nz = getCoeffs(br, ac_proba, ctx, q.y1, first, out);
            l = @intFromBool(nz > first);
            tnz = (tnz >> 1) | (l << 7);
            nz_coeffs = nzCodeBits(nz_coeffs, nz, out[0] != 0);
            blk += 1;
        }
        tnz >>= 4;
        lnz = (lnz >> 1) | (l << 7);
        non_zero_y = (non_zero_y << 8) | nz_coeffs;
    }
    var out_t_nz = tnz;
    var out_l_nz = lnz >> 4;
    var ch: u5 = 0;
    while (ch < 4) : (ch += 2) {
        var nz_coeffs: u32 = 0;
        tnz = @as(u32, d.nz[mb_x]) >> (4 + ch);
        lnz = @as(u32, d.left_nz) >> (4 + ch);
        for (0..2) |_| {
            var l: u32 = lnz & 1;
            for (0..2) |_| {
                const ctx = l + (tnz & 1);
                const out: *[16]i16 = dst[blk * 16 ..][0..16];
                const nz = getCoeffs(br, &d.proba[2], ctx, q.uv, 0, out);
                l = @intFromBool(nz > 0);
                tnz = (tnz >> 1) | (l << 3);
                nz_coeffs = nzCodeBits(nz_coeffs, nz, out[0] != 0);
                blk += 1;
            }
            tnz >>= 2;
            lnz = (lnz >> 1) | (l << 5);
        }
        non_zero_uv |= nz_coeffs << (4 * ch);
        out_t_nz |= (tnz << 4) << ch;
        out_l_nz |= (lnz & 0xf0) << ch;
    }
    d.nz[mb_x] = @truncate(out_t_nz);
    d.left_nz = @truncate(out_l_nz);
    d.non_zero_y = non_zero_y;
    d.non_zero_uv = non_zero_uv;
    return (non_zero_y | non_zero_uv) == 0;
}

// ------------------------------------------------------------------------------- transforms

// The products are taken in 64 bits: the second pass of `transformOne` sees values up to
// ~2^17 from corrupt coefficient data, and `a * 35468` would overflow i32 (libwebp's C relies on
// wrap-around there; valid streams never get close). Results always fit i32 again.
inline fn mul1(a: i32) i32 {
    return @as(i32, @intCast((@as(i64, a) * 20091) >> 16)) + a;
}
inline fn mul2(a: i32) i32 {
    return @intCast((@as(i64, a) * 35468) >> 16);
}
inline fn clip8(v: i32) u8 {
    return if (v < 0) 0 else if (v > 255) 255 else @intCast(v);
}
inline fn store(b: []u8, at: usize, v: i32) void {
    b[at] = clip8(@as(i32, b[at]) + (v >> 3));
}

fn transformOne(in: *const [16]i16, b: []u8, dst: usize) void {
    var c: [16]i32 = undefined;
    for (0..4) |i| {
        const a = @as(i32, in[i]) + in[8 + i];
        const bb = @as(i32, in[i]) - in[8 + i];
        const cc = mul2(in[4 + i]) - mul1(in[12 + i]);
        const dd = mul1(in[4 + i]) + mul2(in[12 + i]);
        c[i * 4 + 0] = a + dd;
        c[i * 4 + 1] = bb + cc;
        c[i * 4 + 2] = bb - cc;
        c[i * 4 + 3] = a - dd;
    }
    for (0..4) |i| {
        const dc = c[i] + 4;
        const a = dc + c[8 + i];
        const bb = dc - c[8 + i];
        const cc = mul2(c[4 + i]) - mul1(c[12 + i]);
        const dd = mul1(c[4 + i]) + mul2(c[12 + i]);
        const o = dst + i * BPS;
        store(b, o + 0, a + dd);
        store(b, o + 1, bb + cc);
        store(b, o + 2, bb - cc);
        store(b, o + 3, a - dd);
    }
}

fn transformAc3(in: *const [16]i16, b: []u8, dst: usize) void {
    const a = @as(i32, in[0]) + 4;
    const c4 = mul2(in[4]);
    const d4 = mul1(in[4]);
    const c1 = mul2(in[1]);
    const d1 = mul1(in[1]);
    const rows = [4]i32{ a + d4, a + c4, a - c4, a - d4 };
    for (rows, 0..) |dc, y| {
        const o = dst + y * BPS;
        store(b, o + 0, dc + d1);
        store(b, o + 1, dc + c1);
        store(b, o + 2, dc - c1);
        store(b, o + 3, dc - d1);
    }
}

fn transformDc(in: *const [16]i16, b: []u8, dst: usize) void {
    const dc = @as(i32, in[0]) + 4;
    for (0..4) |y| for (0..4) |x| store(b, dst + y * BPS + x, dc);
}

fn transformWht(in: *const [16]i16, out: *[384]i16) void {
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const a0 = @as(i32, in[0 + i]) + in[12 + i];
        const a1 = @as(i32, in[4 + i]) + in[8 + i];
        const a2 = @as(i32, in[4 + i]) - in[8 + i];
        const a3 = @as(i32, in[0 + i]) - in[12 + i];
        tmp[0 + i] = a0 + a1;
        tmp[8 + i] = a0 - a1;
        tmp[4 + i] = a3 + a2;
        tmp[12 + i] = a3 - a2;
    }
    for (0..4) |i| {
        const dc = tmp[0 + i * 4] + 3;
        const a0 = dc + tmp[3 + i * 4];
        const a1 = tmp[1 + i * 4] + tmp[2 + i * 4];
        const a2 = tmp[1 + i * 4] - tmp[2 + i * 4];
        const a3 = dc - tmp[3 + i * 4];
        const o = i * 64;
        out[o + 0] = @truncate((a0 + a1) >> 3);
        out[o + 16] = @truncate((a3 + a2) >> 3);
        out[o + 32] = @truncate((a0 - a1) >> 3);
        out[o + 48] = @truncate((a3 - a2) >> 3);
    }
}

fn doTransform(bits: u32, in: *const [16]i16, b: []u8, dst: usize) void {
    switch (bits >> 30) {
        3 => transformOne(in, b, dst),
        2 => transformAc3(in, b, dst),
        1 => transformDc(in, b, dst),
        else => {},
    }
}

fn doUvTransform(bits: u32, in: *const [64]i16, b: []u8, dst: usize) void {
    if (bits & 0xff == 0) return;
    const offs = [4]usize{ 0, 4, 4 * BPS, 4 * BPS + 4 };
    for (0..4) |k| {
        const blk: *const [16]i16 = in[k * 16 ..][0..16];
        if (bits & 0xaa != 0) {
            transformOne(blk, b, dst + offs[k]);
        } else if (blk[0] != 0) transformDc(blk, b, dst + offs[k]);
    }
}

// ------------------------------------------------------------------------------- prediction

inline fn avg3(a: u32, b: u32, c: u32) u8 {
    return @intCast((a + 2 * b + c + 2) >> 2);
}
inline fn avg2(a: u32, b: u32) u8 {
    return @intCast((a + b + 1) >> 1);
}

fn trueMotion(b: []u8, dst: usize, size: usize) void {
    const tl: i32 = b[dst - BPS - 1];
    for (0..size) |y| {
        const row = dst + y * BPS;
        const l: i32 = b[row - 1];
        for (0..size) |x| b[row + x] = clip8(@as(i32, b[dst - BPS + x]) + l - tl);
    }
}

fn fill(b: []u8, dst: usize, size: usize, v: u8) void {
    for (0..size) |y| @memset(b[dst + y * BPS ..][0..size], v);
}

/// 16x16 luma (size 16) or 8x8 chroma (size 8) prediction; `mode` after checkMode.
fn predBlock(b: []u8, dst: usize, size: usize, mode: u8) void {
    const shift: u5 = if (size == 16) 5 else 4;
    switch (mode) {
        B_DC => {
            var dc: u32 = @intCast(size);
            for (0..size) |j| dc += @as(u32, b[dst - 1 + j * BPS]) + b[dst + j - BPS];
            fill(b, dst, size, @intCast(dc >> shift));
        },
        B_TM => trueMotion(b, dst, size),
        B_VE => for (0..size) |j| @memcpy(b[dst + j * BPS ..][0..size], b[dst - BPS ..][0..size]),
        B_HE => for (0..size) |j| @memset(b[dst + j * BPS ..][0..size], b[dst + j * BPS - 1]),
        DC_NOTOP, DC_NOLEFT => {
            var dc: u32 = @intCast(size / 2);
            for (0..size) |j| dc += if (mode == DC_NOTOP) b[dst - 1 + j * BPS] else b[dst + j - BPS];
            fill(b, dst, size, @intCast(dc >> (shift - 1)));
        },
        else => fill(b, dst, size, 0x80),
    }
}

fn pred4(b: []u8, dst: usize, mode: u8) void {
    const top = dst - BPS;
    const A: u32 = b[top];
    const B: u32 = b[top + 1];
    const C: u32 = b[top + 2];
    const D: u32 = b[top + 3];
    const E: u32 = b[top + 4];
    const F: u32 = b[top + 5];
    const G: u32 = b[top + 6];
    const H: u32 = b[top + 7];
    const X: u32 = b[top - 1];
    const I: u32 = b[dst - 1];
    const J: u32 = b[dst - 1 + BPS];
    const K: u32 = b[dst - 1 + 2 * BPS];
    const L: u32 = b[dst - 1 + 3 * BPS];
    var o: [4][4]u8 = undefined; // o[y][x]
    switch (mode) {
        B_DC => {
            var dc: u32 = 4;
            for (0..4) |i| dc += @as(u32, b[top + i]) + b[dst - 1 + i * BPS];
            o = @splat(@splat(@intCast(dc >> 3)));
        },
        B_TM => return trueMotion(b, dst, 4),
        B_VE => o = @splat(.{ avg3(X, A, B), avg3(A, B, C), avg3(B, C, D), avg3(C, D, E) }),
        B_HE => {
            o[0] = @splat(avg3(X, I, J));
            o[1] = @splat(avg3(I, J, K));
            o[2] = @splat(avg3(J, K, L));
            o[3] = @splat(avg3(K, L, L));
        },
        B_RD => {
            o[3][0] = avg3(J, K, L);
            o[3][1] = avg3(I, J, K);
            o[2][0] = o[3][1];
            o[3][2] = avg3(X, I, J);
            o[2][1] = o[3][2];
            o[1][0] = o[3][2];
            o[3][3] = avg3(A, X, I);
            o[2][2] = o[3][3];
            o[1][1] = o[3][3];
            o[0][0] = o[3][3];
            o[2][3] = avg3(B, A, X);
            o[1][2] = o[2][3];
            o[0][1] = o[2][3];
            o[1][3] = avg3(C, B, A);
            o[0][2] = o[1][3];
            o[0][3] = avg3(D, C, B);
        },
        B_LD => {
            o[0][0] = avg3(A, B, C);
            o[0][1] = avg3(B, C, D);
            o[1][0] = o[0][1];
            o[0][2] = avg3(C, D, E);
            o[1][1] = o[0][2];
            o[2][0] = o[0][2];
            o[0][3] = avg3(D, E, F);
            o[1][2] = o[0][3];
            o[2][1] = o[0][3];
            o[3][0] = o[0][3];
            o[1][3] = avg3(E, F, G);
            o[2][2] = o[1][3];
            o[3][1] = o[1][3];
            o[2][3] = avg3(F, G, H);
            o[3][2] = o[2][3];
            o[3][3] = avg3(G, H, H);
        },
        B_VR => {
            o[0][0] = avg2(X, A);
            o[2][1] = o[0][0];
            o[0][1] = avg2(A, B);
            o[2][2] = o[0][1];
            o[0][2] = avg2(B, C);
            o[2][3] = o[0][2];
            o[0][3] = avg2(C, D);
            o[3][0] = avg3(K, J, I);
            o[2][0] = avg3(J, I, X);
            o[1][0] = avg3(I, X, A);
            o[3][1] = o[1][0];
            o[1][1] = avg3(X, A, B);
            o[3][2] = o[1][1];
            o[1][2] = avg3(A, B, C);
            o[3][3] = o[1][2];
            o[1][3] = avg3(B, C, D);
        },
        B_VL => {
            o[0][0] = avg2(A, B);
            o[0][1] = avg2(B, C);
            o[2][0] = o[0][1];
            o[0][2] = avg2(C, D);
            o[2][1] = o[0][2];
            o[0][3] = avg2(D, E);
            o[2][2] = o[0][3];
            o[1][0] = avg3(A, B, C);
            o[1][1] = avg3(B, C, D);
            o[3][0] = o[1][1];
            o[1][2] = avg3(C, D, E);
            o[3][1] = o[1][2];
            o[1][3] = avg3(D, E, F);
            o[3][2] = o[1][3];
            o[2][3] = avg3(E, F, G);
            o[3][3] = avg3(F, G, H);
        },
        B_HU => {
            o[0][0] = avg2(I, J);
            o[0][2] = avg2(J, K);
            o[1][0] = o[0][2];
            o[1][2] = avg2(K, L);
            o[2][0] = o[1][2];
            o[0][1] = avg3(I, J, K);
            o[0][3] = avg3(J, K, L);
            o[1][1] = o[0][3];
            o[1][3] = avg3(K, L, L);
            o[2][1] = o[1][3];
            const l: u8 = @intCast(L);
            o[2][2] = l;
            o[2][3] = l;
            o[3] = @splat(l);
        },
        else => { // B_HD
            o[0][0] = avg2(I, X);
            o[1][2] = o[0][0];
            o[1][0] = avg2(J, I);
            o[2][2] = o[1][0];
            o[2][0] = avg2(K, J);
            o[3][2] = o[2][0];
            o[3][0] = avg2(L, K);
            o[0][3] = avg3(A, B, C);
            o[0][2] = avg3(X, A, B);
            o[0][1] = avg3(I, X, A);
            o[1][3] = o[0][1];
            o[1][1] = avg3(J, I, X);
            o[2][3] = o[1][1];
            o[2][1] = avg3(K, J, I);
            o[3][3] = o[2][1];
            o[3][1] = avg3(L, K, J);
        },
    }
    for (0..4) |y| b[dst + y * BPS ..][0..4].* = o[y];
}

inline fn checkMode(mb_x: u32, mb_y: u32, mode: u8) u8 {
    if (mode != B_DC) return mode;
    if (mb_x == 0) return if (mb_y == 0) DC_NOTOPLEFT else DC_NOLEFT;
    return if (mb_y == 0) DC_NOTOP else B_DC;
}

const scan = [16]u16{
    0 + 0 * BPS,  4 + 0 * BPS,  8 + 0 * BPS,  12 + 0 * BPS,
    0 + 4 * BPS,  4 + 4 * BPS,  8 + 4 * BPS,  12 + 4 * BPS,
    0 + 8 * BPS,  4 + 8 * BPS,  8 + 8 * BPS,  12 + 8 * BPS,
    0 + 12 * BPS, 4 + 12 * BPS, 8 + 12 * BPS, 12 + 12 * BPS,
};

/// Port of libwebp ReconstructRow for one macroblock (work buffer `yuv_b` persists along a row).
fn reconstruct(d: *Dec, mb_x: u32, mb_y: u32) void {
    const b: []u8 = &d.yuv_b;
    if (mb_x == 0) {
        for (0..16) |j| b[Y_OFF + j * BPS - 1] = 129;
        for (0..8) |j| {
            b[U_OFF + j * BPS - 1] = 129;
            b[V_OFF + j * BPS - 1] = 129;
        }
        if (mb_y > 0) {
            b[Y_OFF - 1 - BPS] = 129;
            b[U_OFF - 1 - BPS] = 129;
            b[V_OFF - 1 - BPS] = 129;
        } else {
            @memset(b[Y_OFF - BPS - 1 ..][0 .. 16 + 4 + 1], 127);
            @memset(b[U_OFF - BPS - 1 ..][0 .. 8 + 1], 127);
            @memset(b[V_OFF - BPS - 1 ..][0 .. 8 + 1], 127);
        }
    } else {
        var j: usize = 0;
        while (j < 17) : (j += 1) { // rows -1..15
            const r = Y_OFF + j * BPS - BPS;
            @memcpy(b[r - 4 ..][0..4], b[r + 12 ..][0..4]);
        }
        j = 0;
        while (j < 9) : (j += 1) {
            const ru = U_OFF + j * BPS - BPS;
            @memcpy(b[ru - 4 ..][0..4], b[ru + 4 ..][0..4]);
            const rv = V_OFF + j * BPS - BPS;
            @memcpy(b[rv - 4 ..][0..4], b[rv + 4 ..][0..4]);
        }
    }
    const top = d.yuv_t[@as(usize, mb_x) * 32 ..][0..32];
    if (mb_y > 0) {
        @memcpy(b[Y_OFF - BPS ..][0..16], top[0..16]);
        @memcpy(b[U_OFF - BPS ..][0..8], top[16..24]);
        @memcpy(b[V_OFF - BPS ..][0..8], top[24..32]);
    }
    var bits = d.non_zero_y;
    if (d.is_i4x4) {
        const tr = Y_OFF - BPS + 16;
        if (mb_y > 0) {
            if (mb_x >= d.mb_w - 1) {
                @memset(b[tr..][0..4], top[15]);
            } else {
                @memcpy(b[tr..][0..4], d.yuv_t[(@as(usize, mb_x) + 1) * 32 ..][0..4]);
            }
        }
        for (1..4) |k| @memcpy(b[tr + k * 4 * BPS ..][0..4], b[tr..][0..4]);
        for (0..16) |n| {
            const dst = Y_OFF + @as(usize, scan[n]);
            pred4(b, dst, d.imodes[n]);
            doTransform(bits, d.coeffs[n * 16 ..][0..16], b, dst);
            bits <<= 2;
        }
    } else {
        predBlock(b, Y_OFF, 16, checkMode(mb_x, mb_y, d.imodes[0]));
        if (bits != 0) {
            for (0..16) |n| {
                doTransform(bits, d.coeffs[n * 16 ..][0..16], b, Y_OFF + @as(usize, scan[n]));
                bits <<= 2;
            }
        }
    }
    const uvm = checkMode(mb_x, mb_y, d.uvmode);
    predBlock(b, U_OFF, 8, uvm);
    predBlock(b, V_OFF, 8, uvm);
    doUvTransform(d.non_zero_uv, d.coeffs[256..320], b, U_OFF);
    doUvTransform(d.non_zero_uv >> 8, d.coeffs[320..384], b, V_OFF);
    @memcpy(top[0..16], b[Y_OFF + 15 * BPS ..][0..16]);
    @memcpy(top[16..24], b[U_OFF + 7 * BPS ..][0..8]);
    @memcpy(top[24..32], b[V_OFF + 7 * BPS ..][0..8]);
}

// ------------------------------------------------------------------------------- loop filter

/// One edge of `N` pixels (16 luma / 8 chroma), all positions at once (lane-wise identical
/// to libwebp's scalar FilterLoop26 / FilterLoop24): `hs` steps across the edge, `vs` along it.
fn filterLoop(comptime N: usize, buf: []u8, start: usize, hs: usize, vs: usize, thresh: i32, ithresh: i32, hev_thresh: i32, outer: bool) void {
    const V = @Vector(N, i16);
    const B = @Vector(N, bool);
    var r: [8]V = undefined; // p3 p2 p1 p0 q0 q1 q2 q3
    loadRows(N, buf, start, hs, vs, &r);
    const t2: V = @splat(@intCast(2 * thresh + 1));
    const it: V = @splat(@intCast(ithresh));
    const ht: V = @splat(@intCast(hev_thresh));
    const p2 = r[1];
    const p1 = r[2];
    const p0 = r[3];
    const q0 = r[4];
    const q1 = r[5];
    const q2 = r[6];
    var m: B = vabs(p0 - q0) * @as(V, @splat(4)) + vabs(p1 - q1) <= t2;
    inline for (.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 7, 6 }, .{ 6, 5 }, .{ 5, 4 } }) |pr| {
        m = vand(m, vabs(r[pr[0]] - r[pr[1]]) <= it);
    }
    if (!@reduce(.Or, m)) return;
    const hev: B = vor(vabs(p1 - p0) > ht, vabs(q1 - q0) > ht);
    const m2 = vand(m, hev); // DoFilter2 lanes
    const mx = vand(m, vnot(hev)); // DoFilter6 / DoFilter4 lanes
    const three: V = @splat(3);
    // DoFilter2.
    const a = three * (q0 - p0) + vclamp(p1 - q1, -128, 127);
    const f2a1 = vclamp((a + @as(V, @splat(4))) >> @splat(3), -16, 15);
    const f2a2 = vclamp((a + three) >> @splat(3), -16, 15);
    var np0 = @select(i16, m2, p0 + f2a2, p0);
    var nq0 = @select(i16, m2, q0 - f2a1, q0);
    if (outer) {
        const w = vclamp(a, -128, 127);
        const c63: V = @splat(63);
        const a1 = (@as(V, @splat(27)) * w + c63) >> @splat(7);
        const a2 = (@as(V, @splat(18)) * w + c63) >> @splat(7);
        const a3 = (@as(V, @splat(9)) * w + c63) >> @splat(7);
        r[1] = @select(i16, mx, p2 + a3, p2);
        r[2] = @select(i16, mx, p1 + a2, p1);
        np0 = @select(i16, mx, p0 + a1, np0);
        nq0 = @select(i16, mx, q0 - a1, nq0);
        r[5] = @select(i16, mx, q1 - a2, q1);
        r[6] = @select(i16, mx, q2 - a3, q2);
    } else {
        const a4 = three * (q0 - p0);
        const a1 = vclamp((a4 + @as(V, @splat(4))) >> @splat(3), -16, 15);
        const a2 = vclamp((a4 + three) >> @splat(3), -16, 15);
        const a3 = (a1 + @as(V, @splat(1))) >> @splat(1);
        r[2] = @select(i16, mx, p1 + a3, p1);
        np0 = @select(i16, mx, p0 + a2, np0);
        nq0 = @select(i16, mx, q0 - a1, nq0);
        r[5] = @select(i16, mx, q1 - a3, q1);
    }
    r[3] = np0;
    r[4] = nq0;
    storeRows(N, buf, start, hs, vs, &r, if (outer) 1 else 2, if (outer) 7 else 6);
}

fn simpleFilter(buf: []u8, start: usize, hs: usize, vs: usize, thresh: i32) void {
    const V = @Vector(16, i16);
    var r: [8]V = undefined;
    loadRows(16, buf, start, hs, vs, &r);
    const p1 = r[2];
    const p0 = r[3];
    const q0 = r[4];
    const q1 = r[5];
    const t2: V = @splat(@intCast(2 * thresh + 1));
    const m = vabs(p0 - q0) * @as(V, @splat(4)) + vabs(p1 - q1) <= t2;
    if (!@reduce(.Or, m)) return;
    const a = @as(V, @splat(3)) * (q0 - p0) + vclamp(p1 - q1, -128, 127);
    const a1 = vclamp((a + @as(V, @splat(4))) >> @splat(3), -16, 15);
    const a2 = vclamp((a + @as(V, @splat(3))) >> @splat(3), -16, 15);
    r[3] = @select(i16, m, p0 + a2, p0);
    r[4] = @select(i16, m, q0 - a1, q0);
    storeRows(16, buf, start, hs, vs, &r, 3, 5);
}

/// Loads the 8 pixel rows p3..q3 around an edge (row k = offset (k-4)*hs, lanes along vs).
inline fn loadRows(comptime N: usize, buf: []u8, start: usize, hs: usize, vs: usize, r: *[8]@Vector(N, i16)) void {
    const base = buf.ptr + start - 4 * hs;
    for (0..8) |k| {
        const row = base + k * hs;
        if (vs == 1) {
            const v: @Vector(N, u8) = row[0..N].*;
            r[k] = v;
        } else {
            var t: [N]u8 = undefined;
            for (0..N) |j| t[j] = row[j * vs];
            r[k] = @as(@Vector(N, u8), t);
        }
    }
}

/// Stores rows `k0..k1` (clamped to 0..255) back.
inline fn storeRows(comptime N: usize, buf: []u8, start: usize, hs: usize, vs: usize, r: *const [8]@Vector(N, i16), k0: usize, k1: usize) void {
    const base = buf.ptr + start - 4 * hs;
    for (k0..k1) |k| {
        const c: @Vector(N, u8) = @truncate(@as(@Vector(N, u16), @bitCast(vclamp(r[k], 0, 255))));
        const row = base + k * hs;
        if (vs == 1) {
            row[0..N].* = c;
        } else {
            const t: [N]u8 = c;
            for (0..N) |j| row[j * vs] = t[j];
        }
    }
}

inline fn vabs(v: anytype) @TypeOf(v) {
    return @select(i16, v < @as(@TypeOf(v), @splat(0)), -v, v);
}
inline fn vclamp(v: anytype, comptime lo: i16, comptime hi: i16) @TypeOf(v) {
    const T = @TypeOf(v);
    return @min(@max(v, @as(T, @splat(lo))), @as(T, @splat(hi)));
}
inline fn vand(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @select(bool, a, b, @as(@TypeOf(a), @splat(false)));
}
inline fn vor(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @select(bool, a, @as(@TypeOf(a), @splat(true)), b);
}
inline fn vnot(a: anytype) @TypeOf(a) {
    return @select(bool, a, @as(@TypeOf(a), @splat(false)), @as(@TypeOf(a), @splat(true)));
}

fn filterMb(d: *const Dec, mb_x: u32, mb_y: u32, yp: []u8, up: []u8, vp: []u8, ys: usize, uvs: usize) void {
    const fi = d.finfo[@as(usize, mb_y) * d.mb_w + mb_x];
    const f = d.fstrengths[(fi & 7) >> 1][fi & 1];
    const inner = f.inner or (fi & 8) != 0;
    const limit: i32 = f.limit;
    if (limit == 0) return;
    const yo = @as(usize, mb_y) * 16 * ys + @as(usize, mb_x) * 16;
    if (d.filter_type == 1) {
        if (mb_x > 0) simpleFilter(yp, yo, 1, ys, limit + 4);
        if (inner) for (1..4) |k| simpleFilter(yp, yo + 4 * k, 1, ys, limit);
        if (mb_y > 0) simpleFilter(yp, yo, ys, 1, limit + 4);
        if (inner) for (1..4) |k| simpleFilter(yp, yo + 4 * k * ys, ys, 1, limit);
        return;
    }
    const uo = @as(usize, mb_y) * 8 * uvs + @as(usize, mb_x) * 8;
    const il: i32 = f.ilevel;
    const ht: i32 = f.hev;
    if (mb_x > 0) {
        filterLoop(16, yp, yo, 1, ys, limit + 4, il, ht, true);
        filterLoop(8, up, uo, 1, uvs, limit + 4, il, ht, true);
        filterLoop(8, vp, uo, 1, uvs, limit + 4, il, ht, true);
    }
    if (inner) {
        for (1..4) |k| filterLoop(16, yp, yo + 4 * k, 1, ys, limit, il, ht, false);
        filterLoop(8, up, uo + 4, 1, uvs, limit, il, ht, false);
        filterLoop(8, vp, uo + 4, 1, uvs, limit, il, ht, false);
    }
    if (mb_y > 0) {
        filterLoop(16, yp, yo, ys, 1, limit + 4, il, ht, true);
        filterLoop(8, up, uo, uvs, 1, limit + 4, il, ht, true);
        filterLoop(8, vp, uo, uvs, 1, limit + 4, il, ht, true);
    }
    if (inner) {
        for (1..4) |k| filterLoop(16, yp, yo + 4 * k * ys, ys, 1, limit, il, ht, false);
        filterLoop(8, up, uo + 4 * uvs, uvs, 1, limit, il, ht, false);
        filterLoop(8, vp, uo + 4 * uvs, uvs, 1, limit, il, ht, false);
    }
}

// ------------------------------------------------------------------------------- YUV -> RGB

inline fn multHi(v: i32, c: i32) i32 {
    return (v * c) >> 8;
}
inline fn clipYuv(v: i32) u8 {
    return if (v & ~@as(i32, 16383) == 0) @intCast(v >> 6) else if (v < 0) 0 else 255;
}
inline fn yuvToRgb(y: u32, u: u32, v: u32, out: *[4]u8) void {
    const yy = multHi(@intCast(y), 19077);
    const uu: i32 = @intCast(u);
    const vv: i32 = @intCast(v);
    out.* = .{
        clipYuv(yy + multHi(vv, 26149) - 14234),
        clipYuv(yy - multHi(uu, 6419) - multHi(vv, 13320) + 8708),
        clipYuv(yy + multHi(uu, 33050) - 17685),
        255,
    };
}

/// libwebp UpsampleRgbaLinePair (fancy upsampling); uv packed as u | v << 16.
fn upsamplePair(top_y: []const u8, bot_y: ?[]const u8, tu: []const u8, tv: []const u8, cu: []const u8, cv: []const u8, top_dst: []u8, bot_dst: []u8, len: usize) void {
    const last_pair = (len - 1) >> 1;
    var tl_uv: u32 = @as(u32, tu[0]) | (@as(u32, tv[0]) << 16);
    var l_uv: u32 = @as(u32, cu[0]) | (@as(u32, cv[0]) << 16);
    {
        const uv0 = (3 * tl_uv + l_uv + 0x00020002) >> 2;
        yuvToRgb(top_y[0], uv0 & 0xff, uv0 >> 16, top_dst[0..4]);
    }
    if (bot_y) |by| {
        const uv0 = (3 * l_uv + tl_uv + 0x00020002) >> 2;
        yuvToRgb(by[0], uv0 & 0xff, uv0 >> 16, bot_dst[0..4]);
    }
    var x: usize = 1;
    while (x <= last_pair) : (x += 1) {
        const t_uv = @as(u32, tu[x]) | (@as(u32, tv[x]) << 16);
        const uv = @as(u32, cu[x]) | (@as(u32, cv[x]) << 16);
        const avg = tl_uv + t_uv + l_uv + uv + 0x00080008;
        const diag_12 = (avg + 2 * (t_uv + l_uv)) >> 3;
        const diag_03 = (avg + 2 * (tl_uv + uv)) >> 3;
        {
            const uv0 = (diag_12 + tl_uv) >> 1;
            const uv1 = (diag_03 + t_uv) >> 1;
            yuvToRgb(top_y[2 * x - 1], uv0 & 0xff, (uv0 >> 16) & 0xff, top_dst[(2 * x - 1) * 4 ..][0..4]);
            yuvToRgb(top_y[2 * x], uv1 & 0xff, (uv1 >> 16) & 0xff, top_dst[(2 * x) * 4 ..][0..4]);
        }
        if (bot_y) |by| {
            const uv0 = (diag_03 + l_uv) >> 1;
            const uv1 = (diag_12 + uv) >> 1;
            yuvToRgb(by[2 * x - 1], uv0 & 0xff, (uv0 >> 16) & 0xff, bot_dst[(2 * x - 1) * 4 ..][0..4]);
            yuvToRgb(by[2 * x], uv1 & 0xff, (uv1 >> 16) & 0xff, bot_dst[(2 * x) * 4 ..][0..4]);
        }
        tl_uv = t_uv;
        l_uv = uv;
    }
    if (len & 1 == 0) {
        {
            const uv0 = (3 * tl_uv + l_uv + 0x00020002) >> 2;
            yuvToRgb(top_y[len - 1], uv0 & 0xff, uv0 >> 16, top_dst[(len - 1) * 4 ..][0..4]);
        }
        if (bot_y) |by| {
            const uv0 = (3 * l_uv + tl_uv + 0x00020002) >> 2;
            yuvToRgb(by[len - 1], uv0 & 0xff, uv0 >> 16, bot_dst[(len - 1) * 4 ..][0..4]);
        }
    }
}

/// Converts decoded planes to opaque RGBA (`out.len == w*h*4`) like libwebp EmitFancyRGB.
pub fn toRgba(f: *const Yuv, out: []u8) void {
    const w: usize = f.w;
    const h: usize = f.h;
    const row = w * 4;
    const ys = f.y_stride;
    const uvs = f.uv_stride;
    upsamplePair(f.y[0..w], null, f.u, f.v, f.u, f.v, out[0..row], &.{}, w);
    var y: usize = 1;
    while (y + 1 < h) : (y += 2) {
        const k = (y + 1) / 2; // uv row of the bottom line
        upsamplePair(f.y[y * ys ..][0..w], f.y[(y + 1) * ys ..][0..w], f.u[(k - 1) * uvs ..], f.v[(k - 1) * uvs ..], f.u[k * uvs ..], f.v[k * uvs ..], out[y * row ..][0..row], out[(y + 1) * row ..][0..row], w);
    }
    if (h & 1 == 0 and h > 1) {
        const k = h / 2 - 1;
        const uu = f.u[k * uvs ..];
        const vv = f.v[k * uvs ..];
        upsamplePair(f.y[(h - 1) * ys ..][0..w], null, uu, vv, uu, vv, out[(h - 1) * row ..][0..row], &.{}, w);
    }
}

// ------------------------------------------------------------------------------- alpha

/// Decodes an `ALPH` chunk payload into `out` (w*h bytes).
pub fn decodeAlpha(alloc: std.mem.Allocator, alph: []const u8, w: u32, h: u32, out: []u8) Error!void {
    if (alph.len <= 1) return error.InvalidData;
    const hdr = alph[0];
    const method = hdr & 3;
    const filter = (hdr >> 2) & 3;
    const pre = (hdr >> 4) & 3;
    if (method > 1 or pre > 1 or (hdr >> 6) != 0) return error.InvalidData;
    const n = @as(usize, w) * h;
    if (out.len != n) return error.InvalidData;
    const data = alph[1..];
    if (method == 0) {
        if (data.len < n) return error.InvalidData;
        @memcpy(out, data[0..n]);
    } else {
        try webp_dec.decodeAlphaStream(alloc, data, w, h, out);
    }
    unfilterAlpha(out, w, h, filter);
}

/// In-place inverse of the WebP alpha prediction filters (libwebp filters.c *Unfilter_C).
pub fn unfilterAlpha(a: []u8, w: usize, h: usize, filter: u8) void {
    if (filter == 0) return;
    for (0..h) |y| {
        const cur = a[y * w ..][0..w];
        if (y == 0 or filter == 1) {
            var pred: u8 = if (y == 0) 0 else a[(y - 1) * w];
            for (cur) |*c| {
                c.* +%= pred;
                pred = c.*;
            }
            continue;
        }
        const prev = a[(y - 1) * w ..][0..w];
        if (filter == 2) {
            for (cur, prev) |*c, p| c.* +%= p;
        } else {
            var left: u8 = prev[0];
            var top_left: u8 = prev[0];
            for (cur, prev) |*c, top| {
                const g = @as(i32, left) + top - top_left;
                left = c.* +% clip8(g);
                top_left = top;
                c.* = left;
            }
        }
    }
}

// ------------------------------------------------------------------------------- tables

const dc_table = [128]u8{
    4,   5,   6,   7,   8,   9,   10,  10,  11,  12,  13,  14,  15,  16,  17,  17,
    18,  19,  20,  20,  21,  21,  22,  22,  23,  23,  24,  25,  25,  26,  27,  28,
    29,  30,  31,  32,  33,  34,  35,  36,  37,  37,  38,  39,  40,  41,  42,  43,
    44,  45,  46,  46,  47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,
    59,  60,  61,  62,  63,  64,  65,  66,  67,  68,  69,  70,  71,  72,  73,  74,
    75,  76,  76,  77,  78,  79,  80,  81,  82,  83,  84,  85,  86,  87,  88,  89,
    91,  93,  95,  96,  98,  100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118,
    122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157,
};

const ac_table = [128]u16{
    4,   5,   6,   7,   8,   9,   10,  11,  12,  13,  14,  15,  16,  17,  18,  19,
    20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,  32,  33,  34,  35,
    36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,  49,  50,  51,
    52,  53,  54,  55,  56,  57,  58,  60,  62,  64,  66,  68,  70,  72,  74,  76,
    78,  80,  82,  84,  86,  88,  90,  92,  94,  96,  98,  100, 102, 104, 106, 108,
    110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152,
    155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209,
    213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284,
};

const coeffs_proba0 = [1056]u8{
    128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
    128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128,
    189, 129, 242, 255, 227, 213, 255, 219, 128, 128, 128, 106, 126, 227, 252, 214, 209, 255, 255, 128, 128, 128,
    1, 98, 248, 255, 236, 226, 255, 255, 128, 128, 128, 181, 133, 238, 254, 221, 234, 255, 154, 128, 128, 128,
    78, 134, 202, 247, 198, 180, 255, 219, 128, 128, 128, 1, 185, 249, 255, 243, 255, 128, 128, 128, 128, 128,
    184, 150, 247, 255, 236, 224, 128, 128, 128, 128, 128, 77, 110, 216, 255, 236, 230, 128, 128, 128, 128, 128,
    1, 101, 251, 255, 241, 255, 128, 128, 128, 128, 128, 170, 139, 241, 252, 236, 209, 255, 255, 128, 128, 128,
    37, 116, 196, 243, 228, 255, 255, 255, 128, 128, 128, 1, 204, 254, 255, 245, 255, 128, 128, 128, 128, 128,
    207, 160, 250, 255, 238, 128, 128, 128, 128, 128, 128, 102, 103, 231, 255, 211, 171, 128, 128, 128, 128, 128,
    1, 152, 252, 255, 240, 255, 128, 128, 128, 128, 128, 177, 135, 243, 255, 234, 225, 128, 128, 128, 128, 128,
    80, 129, 211, 255, 194, 224, 128, 128, 128, 128, 128, 1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    246, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
    198, 35, 237, 223, 193, 187, 162, 160, 145, 155, 62, 131, 45, 198, 221, 172, 176, 220, 157, 252, 221, 1,
    68, 47, 146, 208, 149, 167, 221, 162, 255, 223, 128, 1, 149, 241, 255, 221, 224, 255, 255, 128, 128, 128,
    184, 141, 234, 253, 222, 220, 255, 199, 128, 128, 128, 81, 99, 181, 242, 176, 190, 249, 202, 255, 255, 128,
    1, 129, 232, 253, 214, 197, 242, 196, 255, 255, 128, 99, 121, 210, 250, 201, 198, 255, 202, 128, 128, 128,
    23, 91, 163, 242, 170, 187, 247, 210, 255, 255, 128, 1, 200, 246, 255, 234, 255, 128, 128, 128, 128, 128,
    109, 178, 241, 255, 231, 245, 255, 255, 128, 128, 128, 44, 130, 201, 253, 205, 192, 255, 255, 128, 128, 128,
    1, 132, 239, 251, 219, 209, 255, 165, 128, 128, 128, 94, 136, 225, 251, 218, 190, 255, 255, 128, 128, 128,
    22, 100, 174, 245, 186, 161, 255, 199, 128, 128, 128, 1, 182, 249, 255, 232, 235, 128, 128, 128, 128, 128,
    124, 143, 241, 255, 227, 234, 128, 128, 128, 128, 128, 35, 77, 181, 251, 193, 211, 255, 205, 128, 128, 128,
    1, 157, 247, 255, 236, 231, 255, 255, 128, 128, 128, 121, 141, 235, 255, 225, 227, 255, 255, 128, 128, 128,
    45, 99, 188, 251, 195, 217, 255, 224, 128, 128, 128, 1, 1, 251, 255, 213, 255, 128, 128, 128, 128, 128,
    203, 1, 248, 255, 255, 128, 128, 128, 128, 128, 128, 137, 1, 177, 255, 224, 255, 128, 128, 128, 128, 128,
    253, 9, 248, 251, 207, 208, 255, 192, 128, 128, 128, 175, 13, 224, 243, 193, 185, 249, 198, 255, 255, 128,
    73, 17, 171, 221, 161, 179, 236, 167, 255, 234, 128, 1, 95, 247, 253, 212, 183, 255, 255, 128, 128, 128,
    239, 90, 244, 250, 211, 209, 255, 255, 128, 128, 128, 155, 77, 195, 248, 188, 195, 255, 255, 128, 128, 128,
    1, 24, 239, 251, 218, 219, 255, 205, 128, 128, 128, 201, 51, 219, 255, 196, 186, 128, 128, 128, 128, 128,
    69, 46, 190, 239, 201, 218, 255, 228, 128, 128, 128, 1, 191, 251, 255, 255, 128, 128, 128, 128, 128, 128,
    223, 165, 249, 255, 213, 255, 128, 128, 128, 128, 128, 141, 124, 248, 255, 255, 128, 128, 128, 128, 128, 128,
    1, 16, 248, 255, 255, 128, 128, 128, 128, 128, 128, 190, 36, 230, 255, 236, 255, 128, 128, 128, 128, 128,
    149, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128, 1, 226, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    247, 192, 255, 128, 128, 128, 128, 128, 128, 128, 128, 240, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    1, 134, 252, 255, 255, 128, 128, 128, 128, 128, 128, 213, 62, 250, 255, 255, 128, 128, 128, 128, 128, 128,
    55, 93, 255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
    128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
    202, 24, 213, 235, 186, 191, 220, 160, 240, 175, 255, 126, 38, 182, 232, 169, 184, 228, 174, 255, 187, 128,
    61, 46, 138, 219, 151, 178, 240, 170, 255, 216, 128, 1, 112, 230, 250, 199, 191, 247, 159, 255, 255, 128,
    166, 109, 228, 252, 211, 215, 255, 174, 128, 128, 128, 39, 77, 162, 232, 172, 180, 245, 178, 255, 255, 128,
    1, 52, 220, 246, 198, 199, 249, 220, 255, 255, 128, 124, 74, 191, 243, 183, 193, 250, 221, 255, 255, 128,
    24, 71, 130, 219, 154, 170, 243, 182, 255, 255, 128, 1, 182, 225, 249, 219, 240, 255, 224, 128, 128, 128,
    149, 150, 226, 252, 216, 205, 255, 171, 128, 128, 128, 28, 108, 170, 242, 183, 194, 254, 223, 255, 255, 128,
    1, 81, 230, 252, 204, 203, 255, 192, 128, 128, 128, 123, 102, 209, 247, 188, 196, 255, 233, 128, 128, 128,
    20, 95, 153, 243, 164, 173, 255, 203, 128, 128, 128, 1, 222, 248, 255, 216, 213, 128, 128, 128, 128, 128,
    168, 175, 246, 252, 235, 205, 255, 255, 128, 128, 128, 47, 116, 215, 255, 211, 212, 255, 255, 128, 128, 128,
    1, 121, 236, 253, 212, 214, 255, 255, 128, 128, 128, 141, 84, 213, 252, 201, 202, 255, 219, 128, 128, 128,
    42, 80, 160, 240, 162, 185, 255, 205, 128, 128, 128, 1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    244, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128, 238, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
};
const coeffs_update_proba = [1056]u8{
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 176, 246, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    223, 241, 252, 255, 255, 255, 255, 255, 255, 255, 255, 249, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 244, 252, 255, 255, 255, 255, 255, 255, 255, 255, 234, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 246, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    239, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255, 251, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 254, 253, 255, 254, 255, 255, 255, 255, 255, 255, 250, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255,
    254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    217, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 225, 252, 241, 253, 255, 255, 254, 255, 255, 255, 255,
    234, 250, 241, 250, 253, 255, 253, 254, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    223, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 238, 253, 254, 254, 255, 255, 255, 255, 255, 255, 255,
    255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255, 249, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    247, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 252, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255, 250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    186, 251, 250, 255, 255, 255, 255, 255, 255, 255, 255, 234, 251, 244, 254, 255, 255, 255, 255, 255, 255, 255,
    251, 251, 243, 253, 254, 255, 254, 255, 255, 255, 255, 255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    236, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 251, 253, 253, 254, 254, 255, 255, 255, 255, 255, 255,
    255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 254, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    248, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 250, 254, 252, 254, 255, 255, 255, 255, 255, 255, 255,
    248, 254, 249, 253, 255, 255, 255, 255, 255, 255, 255, 255, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
    246, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255, 252, 254, 251, 254, 254, 255, 255, 255, 255, 255, 255,
    255, 254, 252, 255, 255, 255, 255, 255, 255, 255, 255, 248, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255,
    253, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    245, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255, 253, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 251, 253, 255, 255, 255, 255, 255, 255, 255, 255, 252, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 252, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    249, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
};
const bmodes_proba = [900]u8{
    231, 120, 48, 89, 115, 113, 120, 152, 112, 152, 179, 64, 126, 170, 118, 46, 70, 95, 175, 69, 143, 80,
    85, 82, 72, 155, 103, 56, 58, 10, 171, 218, 189, 17, 13, 152, 114, 26, 17, 163, 44, 195, 21, 10,
    173, 121, 24, 80, 195, 26, 62, 44, 64, 85, 144, 71, 10, 38, 171, 213, 144, 34, 26, 170, 46, 55,
    19, 136, 160, 33, 206, 71, 63, 20, 8, 114, 114, 208, 12, 9, 226, 81, 40, 11, 96, 182, 84, 29,
    16, 36, 134, 183, 89, 137, 98, 101, 106, 165, 148, 72, 187, 100, 130, 157, 111, 32, 75, 80, 66, 102,
    167, 99, 74, 62, 40, 234, 128, 41, 53, 9, 178, 241, 141, 26, 8, 107, 74, 43, 26, 146, 73, 166,
    49, 23, 157, 65, 38, 105, 160, 51, 52, 31, 115, 128, 104, 79, 12, 27, 217, 255, 87, 17, 7, 87,
    68, 71, 44, 114, 51, 15, 186, 23, 47, 41, 14, 110, 182, 183, 21, 17, 194, 66, 45, 25, 102, 197,
    189, 23, 18, 22, 88, 88, 147, 150, 42, 46, 45, 196, 205, 43, 97, 183, 117, 85, 38, 35, 179, 61,
    39, 53, 200, 87, 26, 21, 43, 232, 171, 56, 34, 51, 104, 114, 102, 29, 93, 77, 39, 28, 85, 171,
    58, 165, 90, 98, 64, 34, 22, 116, 206, 23, 34, 43, 166, 73, 107, 54, 32, 26, 51, 1, 81, 43,
    31, 68, 25, 106, 22, 64, 171, 36, 225, 114, 34, 19, 21, 102, 132, 188, 16, 76, 124, 62, 18, 78,
    95, 85, 57, 50, 48, 51, 193, 101, 35, 159, 215, 111, 89, 46, 111, 60, 148, 31, 172, 219, 228, 21,
    18, 111, 112, 113, 77, 85, 179, 255, 38, 120, 114, 40, 42, 1, 196, 245, 209, 10, 25, 109, 88, 43,
    29, 140, 166, 213, 37, 43, 154, 61, 63, 30, 155, 67, 45, 68, 1, 209, 100, 80, 8, 43, 154, 1,
    51, 26, 71, 142, 78, 78, 16, 255, 128, 34, 197, 171, 41, 40, 5, 102, 211, 183, 4, 1, 221, 51,
    50, 17, 168, 209, 192, 23, 25, 82, 138, 31, 36, 171, 27, 166, 38, 44, 229, 67, 87, 58, 169, 82,
    115, 26, 59, 179, 63, 59, 90, 180, 59, 166, 93, 73, 154, 40, 40, 21, 116, 143, 209, 34, 39, 175,
    47, 15, 16, 183, 34, 223, 49, 45, 183, 46, 17, 33, 183, 6, 98, 15, 32, 183, 57, 46, 22, 24,
    128, 1, 54, 17, 37, 65, 32, 73, 115, 28, 128, 23, 128, 205, 40, 3, 9, 115, 51, 192, 18, 6,
    223, 87, 37, 9, 115, 59, 77, 64, 21, 47, 104, 55, 44, 218, 9, 54, 53, 130, 226, 64, 90, 70,
    205, 40, 41, 23, 26, 57, 54, 57, 112, 184, 5, 41, 38, 166, 213, 30, 34, 26, 133, 152, 116, 10,
    32, 134, 39, 19, 53, 221, 26, 114, 32, 73, 255, 31, 9, 65, 234, 2, 15, 1, 118, 73, 75, 32,
    12, 51, 192, 255, 160, 43, 51, 88, 31, 35, 67, 102, 85, 55, 186, 85, 56, 21, 23, 111, 59, 205,
    45, 37, 192, 55, 38, 70, 124, 73, 102, 1, 34, 98, 125, 98, 42, 88, 104, 85, 117, 175, 82, 95,
    84, 53, 89, 128, 100, 113, 101, 45, 75, 79, 123, 47, 51, 128, 81, 171, 1, 57, 17, 5, 71, 102,
    57, 53, 41, 49, 38, 33, 13, 121, 57, 73, 26, 1, 85, 41, 10, 67, 138, 77, 110, 90, 47, 114,
    115, 21, 2, 10, 102, 255, 166, 23, 6, 101, 29, 16, 10, 85, 128, 101, 196, 26, 57, 18, 10, 102,
    102, 213, 34, 20, 43, 117, 20, 15, 36, 163, 128, 68, 1, 26, 102, 61, 71, 37, 34, 53, 31, 243,
    192, 69, 60, 71, 38, 73, 119, 28, 222, 37, 68, 45, 128, 34, 1, 47, 11, 245, 171, 62, 17, 19,
    70, 146, 85, 55, 62, 70, 37, 43, 37, 154, 100, 163, 85, 160, 1, 63, 9, 92, 136, 28, 64, 32,
    201, 85, 75, 15, 9, 9, 64, 255, 184, 119, 16, 86, 6, 28, 5, 64, 255, 25, 248, 1, 56, 8,
    17, 132, 137, 255, 55, 116, 128, 58, 15, 20, 82, 135, 57, 26, 121, 40, 164, 50, 31, 137, 154, 133,
    25, 35, 218, 51, 103, 44, 131, 131, 123, 31, 6, 158, 86, 40, 64, 135, 148, 224, 45, 183, 128, 22,
    26, 17, 131, 240, 154, 14, 1, 209, 45, 16, 21, 91, 64, 222, 7, 1, 197, 56, 21, 39, 155, 60,
    138, 23, 102, 213, 83, 12, 13, 54, 192, 255, 68, 47, 28, 85, 26, 85, 85, 128, 128, 32, 146, 171,
    18, 11, 7, 63, 144, 171, 4, 4, 246, 35, 27, 10, 146, 174, 171, 12, 26, 128, 190, 80, 35, 99,
    180, 80, 126, 54, 45, 85, 126, 47, 87, 176, 51, 41, 20, 32, 101, 75, 128, 139, 118, 146, 116, 128,
    85, 56, 41, 15, 176, 236, 85, 37, 9, 62, 71, 30, 17, 119, 118, 255, 17, 18, 138, 101, 38, 60,
    138, 55, 70, 43, 26, 142, 146, 36, 19, 30, 171, 255, 97, 27, 20, 138, 45, 61, 62, 219, 1, 81,
    188, 64, 32, 41, 20, 117, 151, 142, 20, 21, 163, 112, 19, 12, 61, 195, 128, 48, 4, 24,
};

test "vp8 compiles" {
    std.testing.refAllDecls(@This());
}

test "inverse transform of extreme (corrupt) coefficients does not overflow (fuzz regression)" {
    var in: [16]i16 = undefined;
    for (&in, 0..) |*c, i| c.* = if (i % 3 == 0) std.math.minInt(i16) else std.math.maxInt(i16);
    var b: [4 * BPS]u8 = @splat(128);
    transformOne(&in, &b, 0);
    transformAc3(&in, &b, 0);
    in = @splat(std.math.maxInt(i16));
    transformOne(&in, &b, 0);
}

test "lossy webp matches libwebp (WebPDecodeRGBA) exactly" {
    const a = std.testing.allocator;
    const names = .{ "q75", "q10", "q95", "q50simple", "q30sharp", "q60nofilter", "q85part", "big", "q2", "flat", "solid", "cw_avatar", "cw_icon", "cw_photo", "tiny", "thin", "alpha_raw", "alpha_ll", "alpha_fast" };
    inline for (names) |n| {
        const file = @embedFile("testdata/vp8_" ++ n ++ ".webp");
        const ref = @embedFile("testdata/vp8_" ++ n ++ ".rgba");
        const img = try webp_dec.decode(a, file, .{});
        defer img.deinit(a);
        try std.testing.expectEqual(ref.len, img.data.len);
        var maxd: u32 = 0;
        var ndiff: usize = 0;
        for (img.data, ref) |x, y| {
            const dd: u32 = if (x > y) x - y else y - x;
            maxd = @max(maxd, dd);
            ndiff += @intFromBool(dd != 0);
        }
        if (maxd != 0) std.debug.print("{s}: {}x{} max diff {} ({} bytes differ)\n", .{ n, img.width, img.height, maxd, ndiff });
        try std.testing.expectEqual(@as(u32, 0), maxd);
    }
}

test "fuzz lossy webp: mutated / truncated inputs never crash" {
    const a = std.testing.allocator;
    const bases = [_][]const u8{
        @embedFile("testdata/vp8_q30sharp.webp"),
        @embedFile("testdata/vp8_alpha_ll.webp"),
        @embedFile("testdata/vp8_alpha_raw.webp"),
        @embedFile("testdata/vp8_q85part.webp"),
    };
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var buf: [4096]u8 = undefined;
    for (bases) |base| {
        var cut: usize = 0;
        while (cut < base.len) : (cut += 7) {
            if (webp_dec.decode(a, base[0..cut], .{ .max_pixels = 1 << 20 })) |img| img.deinit(a) else |_| {}
        }
    }
    for (0..3000) |i| {
        const base = bases[i % bases.len];
        const b = buf[0..base.len];
        @memcpy(b, base);
        const nmut = 1 + rnd.uintLessThan(usize, 8);
        for (0..nmut) |_| {
            // Bias mutations towards the headers (first 64 bytes) half the time.
            const lim = if (rnd.boolean()) @min(b.len, 64) else b.len;
            b[rnd.uintLessThan(usize, lim)] = rnd.int(u8);
        }
        const len = if (i % 5 == 0) rnd.uintLessThan(usize, b.len) else b.len;
        if (webp_dec.decode(a, b[0..len], .{ .max_pixels = 1 << 20 })) |img| img.deinit(a) else |_| {}
    }
}
