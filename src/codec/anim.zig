//! Animated image frame access: GIF (disposal 1/2/3, transparency, local palettes,
//! interlace), animated WebP (ANIM/ANMF, blend + dispose flags, lossy or lossless frames,
//! libwebp WebPAnimDecoder compositing) and APNG (acTL/fcTL/fdAT, dispose + blend ops).
//! Each returned frame is the fully composited canvas (straight RGBA) for that frame.
//!
//! `decodeFrame(i)` composites frames 0..i from scratch (O(i) frame decodes); to walk a
//! whole animation use `Animator` (one decode per frame). Temporaries live in an internal
//! arena on top of `alloc`; only the returned `Frame.image.data` stays allocated.
//! Untrusted input: bounds-checked; every frame decode respects `Limits`.
const std = @import("std");
const types = @import("types.zig");
const gif = @import("gif.zig");
const png = @import("png.zig");
const webp_dec = @import("webp_dec.zig");

const Image = types.Image;
const Limits = types.Limits;
const Error = types.Error;

pub const Frame = struct {
    /// Composited canvas for this frame, straight RGBA8 (owned by the caller's allocator).
    image: Image,
    delay_ms: u32,
};

const Kind = enum { gif, webp, apng, png_still, webp_still, none };

fn kindOf(bytes: []const u8) Kind {
    if (bytes.len >= 6 and std.mem.eql(u8, bytes[0..3], "GIF")) return .gif;
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &png.signature)) {
        return if (png.apngFrameCount(bytes) > 0) .apng else .png_still;
    }
    if (webp_dec.riffBody(bytes)) |body| {
        var it = webp_dec.Chunks{ .data = body };
        while (it.next()) |c| {
            if (std.mem.eql(u8, &c.tag, "VP8X")) {
                if (c.body.len >= 1 and c.body[0] & 2 != 0) return .webp;
                break;
            }
        }
        return .webp_still;
    }
    return .none;
}

/// Number of frames: GIF image count, ANMF count, APNG fcTL count, 1 for still PNG/WebP,
/// 0 for anything else (callers treat other still formats as one frame).
pub fn frameCount(bytes: []const u8) u32 {
    return switch (kindOf(bytes)) {
        .gif => gif.frameCount(bytes),
        .apng => png.apngFrameCount(bytes),
        .webp => blk: {
            var n: u32 = 0;
            var it = webp_dec.Chunks{ .data = webp_dec.riffBody(bytes).? };
            while (it.next()) |c| n += @intFromBool(std.mem.eql(u8, &c.tag, "ANMF"));
            break :blk n;
        },
        .png_still, .webp_still => 1,
        .none => 0,
    };
}

/// Decodes frame `index` (0-based) fully composited. `index >= frameCount` => InvalidData;
/// unsupported container => UnsupportedFormat.
pub fn decodeFrame(alloc: std.mem.Allocator, bytes: []const u8, index: u32, limits: Limits) Error!Frame {
    switch (kindOf(bytes)) {
        .png_still, .webp_still => {
            if (index != 0) return error.InvalidData;
            const img = if (bytes[0] == 0x89) try png.decode(alloc, bytes, limits) else try webp_dec.decode(alloc, bytes, limits);
            return .{ .image = img, .delay_ms = 0 };
        },
        .none => return error.UnsupportedFormat,
        else => {},
    }
    var a = try Animator.init(alloc, bytes, limits);
    defer a.deinit();
    var delay: u32 = 0;
    var i: u32 = 0;
    while (i <= index) : (i += 1) delay = (try a.next()) orelse return error.InvalidData;
    const out = try alloc.dupe(u8, a.canvas);
    return .{ .image = .{ .width = a.w, .height = a.h, .data = out }, .delay_ms = delay };
}

/// Sequential compositor for GIF / animated WebP / APNG. `canvas` holds the current frame
/// after each successful `next()` (valid until the next call / `deinit`).
pub const Animator = struct {
    /// Maximum frames per animation (or `Limits.max_frames` when lower); `next()` fails with
    /// ImageTooLarge past it.
    pub const max_frames: u32 = 10000;
    /// Total work budget per animation, in multiples of `Limits.max_pixels`.
    pub const max_work_factor: u64 = 16;

    arena_state: std.heap.ArenaAllocator,
    /// Per-frame temporaries (decoded frame, LZW buffers); reset at every `next()`.
    scratch: std.heap.ArenaAllocator,
    bytes: []const u8,
    limits: Limits,
    kind: Kind,
    w: u32 = 0,
    h: u32 = 0,
    canvas: []u8 = &.{},
    /// Copy of the canvas for "restore previous" disposal (GIF 3 / APNG 2).
    saved: []u8 = &.{},
    index: u32 = 0,
    /// Pixels decoded / composited so far (see `charge`).
    work: u64 = 0,
    // pending disposal of the previous frame
    prev_dispose: u8 = 0, // 0 none, 1 clear rect, 2 restore saved
    prev_rect: [4]u32 = .{ 0, 0, 0, 0 },
    // format state
    gif_state: gif.Gif = undefined,
    webp_it: webp_dec.Chunks = .{ .data = &.{} },

    pub fn init(alloc: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Animator {
        const kind = kindOf(bytes);
        var a = Animator{ .arena_state = std.heap.ArenaAllocator.init(alloc), .scratch = std.heap.ArenaAllocator.init(alloc), .bytes = bytes, .limits = limits, .kind = kind };
        errdefer a.deinit();
        switch (kind) {
            .gif => a.gif_state = try gif.Gif.init(bytes),
            .apng => {
                const d = png.dimensions(bytes) orelse return error.InvalidData;
                try a.setCanvas(d[0], d[1]);
            },
            .webp => {
                const body = webp_dec.riffBody(bytes).?;
                a.webp_it = .{ .data = body };
                while (a.webp_it.next()) |c| {
                    if (std.mem.eql(u8, &c.tag, "VP8X")) {
                        if (c.body.len < 10) return error.InvalidData;
                        try a.setCanvas(rd24(c.body[4..7]) + 1, rd24(c.body[7..10]) + 1);
                        break;
                    }
                }
                if (a.canvas.len == 0) return error.InvalidData;
            },
            else => return error.UnsupportedFormat,
        }
        return a;
    }

    pub fn deinit(a: *Animator) void {
        a.scratch.deinit();
        a.arena_state.deinit();
    }

    fn setCanvas(a: *Animator, w: u32, h: u32) Error!void {
        const n = try types.checkSize(w, h, a.limits);
        a.w = w;
        a.h = h;
        a.canvas = try a.arena_state.allocator().alloc(u8, n);
        @memset(a.canvas, 0);
    }

    /// Composites the next frame; returns its delay in ms, or null after the last frame.
    pub fn next(a: *Animator) Error!?u32 {
        _ = a.scratch.reset(.retain_capacity);
        if (a.index >= @min(max_frames, a.limits.max_frames)) return error.ImageTooLarge;
        a.applyDispose();
        const delay: ?u32 = switch (a.kind) {
            .gif => try a.nextGif(),
            .apng => try a.nextApng(),
            .webp => try a.nextWebp(),
            else => null,
        };
        if (delay != null) a.index += 1;
        return delay;
    }

    /// Accounts `px` pixels of per-frame work (frame decode + canvas copies); fails with
    /// ImageTooLarge once the animation exceeds `max_work_factor * max_pixels` in total.
    fn charge(a: *Animator, px: u64) Error!void {
        a.work +|= px;
        if (a.work > a.limits.max_pixels *| max_work_factor) return error.ImageTooLarge;
    }

    fn applyDispose(a: *Animator) void {
        switch (a.prev_dispose) {
            1 => a.fillRect(a.prev_rect, 0),
            2 => if (a.saved.len == a.canvas.len) @memcpy(a.canvas, a.saved),
            else => {},
        }
        a.prev_dispose = 0;
    }

    fn fillRect(a: *Animator, r: [4]u32, v: u8) void {
        if (r[0] >= a.w or r[1] >= a.h) return;
        const x1 = @min(a.w, @as(u64, r[0]) + r[2]);
        const y1 = @min(a.h, @as(u64, r[1]) + r[3]);
        var y: u64 = r[1];
        while (y < y1) : (y += 1) {
            const row = @as(usize, @intCast(y)) * a.w * 4;
            @memset(a.canvas[row + @as(usize, r[0]) * 4 .. row + @as(usize, @intCast(x1)) * 4], v);
        }
    }

    fn save(a: *Animator) Error!void {
        const arena = a.arena_state.allocator();
        if (a.saved.len != a.canvas.len) a.saved = try arena.alloc(u8, a.canvas.len);
        @memcpy(a.saved, a.canvas);
    }

    fn nextGif(a: *Animator) Error!?u32 {
        const fd = (try a.gif_state.next()) orelse return null;
        if (a.index == 0) {
            const sz = a.gif_state.canvasSize(fd);
            try a.setCanvas(sz[0], sz[1]);
        }
        try a.charge(clippedArea(fd.x, fd.y, fd.w, fd.h, a.w, a.h) + if (fd.disposal == 3) 2 * @as(u64, a.w) * a.h else 0);
        if (fd.disposal == 3) try a.save();
        try gif.drawFrame(a.scratch.allocator(), a.bytes, fd, a.canvas, a.w, a.h, a.limits);
        a.prev_rect = .{ fd.x, fd.y, fd.w, fd.h };
        a.prev_dispose = switch (fd.disposal) {
            2 => 1,
            3 => 2,
            else => 0,
        };
        return @as(u32, fd.delay_cs) * 10;
    }

    fn nextApng(a: *Animator) Error!?u32 {
        const fr = png.apngFrame(a.bytes, a.index) orelse return null;
        if (fr.w == 0 or fr.h == 0 or fr.x > a.w or fr.y > a.h or fr.w > a.w - fr.x or fr.h > a.h - fr.y) return error.InvalidData;
        var dispose = fr.dispose_op;
        if (dispose > 2) return error.InvalidData;
        if (a.index == 0 and dispose == 2) dispose = 1;
        try a.charge(@as(u64, fr.w) * fr.h + if (dispose == 2) 2 * @as(u64, a.w) * a.h else 0);
        if (dispose == 2) try a.save();
        const img = try png.decodeApngFrame(a.scratch.allocator(), a.bytes, fr, a.limits);
        a.composite(img, fr.x, fr.y, fr.blend_op == 1);
        a.prev_rect = .{ fr.x, fr.y, fr.w, fr.h };
        a.prev_dispose = dispose;
        return fr.delay_ms;
    }

    fn nextWebp(a: *Animator) Error!?u32 {
        while (a.webp_it.next()) |c| {
            if (!std.mem.eql(u8, &c.tag, "ANMF")) continue;
            const b = c.body;
            if (b.len < 16) return error.InvalidData;
            const x = rd24(b[0..3]) * 2;
            const y = rd24(b[3..6]) * 2;
            const fw = rd24(b[6..9]) + 1;
            const fh = rd24(b[9..12]) + 1;
            const duration = rd24(b[12..15]);
            const blend = b[15] & 2 == 0;
            // Reject a frame that does not fit the canvas before decoding it.
            if (x > a.w or y > a.h or fw > a.w - x or fh > a.h - y) return error.InvalidData;
            try a.charge(@as(u64, fw) * fh);
            const img = try webp_dec.decodeImageChunks(a.scratch.allocator(), b[16..], a.limits, .{});
            if (img.width != fw or img.height != fh) return error.InvalidData;
            // libwebp: the first frame is never blended (canvas starts transparent).
            a.composite(img, x, y, blend and a.index > 0);
            a.prev_rect = .{ x, y, fw, fh };
            a.prev_dispose = if (b[15] & 1 != 0) 1 else 0;
            return duration;
        }
        return null;
    }

    /// Copies (or alpha-blends) `img` onto the canvas at (x, y), clipped.
    fn composite(a: *Animator, img: Image, x: u32, y: u32, blend: bool) void {
        if (x >= a.w or y >= a.h) return;
        const wc: usize = @min(img.width, a.w - x);
        var row: u32 = 0;
        while (row < img.height and y + row < a.h) : (row += 1) {
            const d = a.canvas[(@as(usize, y + row) * a.w + x) * 4 ..][0 .. wc * 4];
            const s = img.data[@as(usize, row) * img.width * 4 ..][0 .. wc * 4];
            if (!blend) {
                @memcpy(d, s);
            } else {
                var i: usize = 0;
                while (i < d.len) : (i += 4) blendPixel(d[i..][0..4], s[i..][0..4].*);
            }
        }
    }
};

/// Area of the rect (x, y, w, h) clipped to a `cw`x`ch` canvas.
fn clippedArea(x: u32, y: u32, w: u32, h: u32, cw: u32, ch: u32) u64 {
    if (x >= cw or y >= ch) return 0;
    return @as(u64, @min(w, cw - x)) * @min(h, ch - y);
}

/// libwebp's BlendPixelNonPremult (straight-alpha "over"); alpha 255 copies, alpha 0 keeps.
pub fn blendPixel(dst: *[4]u8, src: [4]u8) void {
    const sa: u32 = src[3];
    if (sa == 255) {
        dst.* = src;
        return;
    }
    if (sa == 0) return;
    const dfa: u32 = (@as(u32, dst[3]) * (256 - sa)) >> 8;
    const ba = sa + dfa;
    const scale: u64 = (@as(u64, 1) << 24) / ba;
    for (0..3) |c| {
        const un: u64 = @as(u64, src[c]) * sa + @as(u64, dst[c]) * dfa;
        dst[c] = @intCast(@min(255, (un * scale) >> 24));
    }
    dst[3] = @intCast(ba);
}

fn rd24(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
}

// ------------------------------------------------------------------------------- tests

const testing = std.testing;

fn checkAgainstRefs(comptime name: []const u8, delays: []const u32) !void {
    const a = testing.allocator;
    const file = @embedFile("testdata/" ++ name);
    const refs = @embedFile("testdata/" ++ name[0..comptime std.mem.lastIndexOfScalar(u8, name, '.').?] ++ ".frames.rgba");
    try testing.expectEqual(@as(u32, @intCast(delays.len)), frameCount(file));
    var an = try Animator.init(a, file, .{});
    defer an.deinit();
    const fsz = refs.len / delays.len;
    for (delays, 0..) |dl, i| {
        const got = (try an.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(dl, got);
        try testing.expectEqual(fsz, an.canvas.len);
        const ref = refs[i * fsz ..][0..fsz];
        var maxd: u32 = 0;
        for (an.canvas, ref, 0..) |x, y, k| {
            // Fully transparent pixels: only alpha is meaningful.
            if (ref[k | 3] == 0 and an.canvas[k | 3] == 0) continue;
            maxd = @max(maxd, if (x > y) x - y else y - x);
        }
        if (maxd != 0) std.debug.print("{s} frame {}: max diff {}\n", .{ name, i, maxd });
        try testing.expectEqual(@as(u32, 0), maxd);
    }
    try testing.expectEqual(@as(?u32, null), try an.next());
    // Random access matches sequential compositing.
    const f3 = try decodeFrame(a, file, 3, .{});
    defer f3.image.deinit(a);
    try testing.expectEqual(delays[3], f3.delay_ms);
    for (f3.image.data, refs[3 * fsz ..][0..fsz], 0..) |x, y, k| {
        if (refs[3 * fsz + (k | 3)] == 0 and f3.image.data[k | 3] == 0) continue;
        try testing.expectEqual(y, x);
    }
    try testing.expectError(error.InvalidData, decodeFrame(a, file, @intCast(delays.len), .{}));
}

test "animated webp frames match libwebp WebPAnimDecoder (anim_dump)" {
    try checkAgainstRefs("anim_lossy.webp", &.{ 70, 70, 70, 70, 70 });
    try checkAgainstRefs("anim_mixed.webp", &.{ 50, 50, 120, 120, 120 });
    try checkAgainstRefs("anim_ll.webp", &.{ 40, 40, 40, 40, 40 });
    try checkAgainstRefs("anim_gif.webp", &.{ 100, 50, 200, 100, 70 }); // gif2webp maps delay 0 to 100
}

test "animated gif frames match libwebp anim_util (giflib) compositing" {
    try checkAgainstRefs("anim.gif", &.{ 100, 50, 200, 0, 70 });
}

fn putChunk(l: *std.ArrayList(u8), a: std.mem.Allocator, typ: *const [4]u8, data: []const u8) !void {
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(data.len), .big);
    hdr[4..8].* = typ.*;
    try l.appendSlice(a, &hdr);
    try l.appendSlice(a, data);
    const crc = @import("checksum.zig").crc32(@import("checksum.zig").crc32(0, typ), data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc, .big);
    try l.appendSlice(a, &c);
}

/// IDAT payload of an RGBA (colour type 6) PNG encoding of `rgba`.
fn idatOf(a: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    const f = try png.encode(a, rgba, w, h, .{ .palette = false, .strip_opaque_alpha = false });
    defer a.free(f);
    var p: usize = 8;
    var out: std.ArrayList(u8) = .empty;
    while (nextChunkT(f, &p)) |c| if (std.mem.eql(u8, c[0], "IDAT")) try out.appendSlice(a, c[1]);
    return out.toOwnedSlice(a);
}
fn nextChunkT(b: []const u8, p: *usize) ?struct { *const [4]u8, []const u8 } {
    if (p.* + 12 > b.len) return null;
    const len = std.mem.readInt(u32, b[p.*..][0..4], .big);
    const r = .{ b[p.* + 4 ..][0..4], b[p.* + 8 ..][0..len] };
    p.* += 12 + len;
    return r;
}

test "apng: offsets, dispose none/background/previous, blend source/over" {
    const a = testing.allocator;
    const W = 8;
    const H = 6;
    const Fr = struct { x: u32, y: u32, w: u32, h: u32, dispose: u8, blend: u8, delay: u16, px: [4]u8 };
    const frs = [_]Fr{
        .{ .x = 0, .y = 0, .w = W, .h = H, .dispose = 0, .blend = 0, .delay = 10, .px = .{ 10, 20, 30, 255 } },
        .{ .x = 2, .y = 1, .w = 3, .h = 3, .dispose = 1, .blend = 1, .delay = 20, .px = .{ 200, 100, 0, 128 } },
        .{ .x = 1, .y = 2, .w = 4, .h = 2, .dispose = 2, .blend = 0, .delay = 30, .px = .{ 0, 255, 0, 64 } },
        .{ .x = 7, .y = 5, .w = 1, .h = 1, .dispose = 0, .blend = 1, .delay = 40, .px = .{ 1, 2, 3, 0 } },
    };
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(a);
    try file.appendSlice(a, &png.signature);
    var ihdr = [13]u8{ 0, 0, 0, W, 0, 0, 0, H, 8, 6, 0, 0, 0 };
    try putChunk(&file, a, "IHDR", &ihdr);
    try putChunk(&file, a, "acTL", &.{ 0, 0, 0, frs.len, 0, 0, 0, 0 });
    var seq: u32 = 0;
    // Reference compositor (straightforward, independent of Animator).
    var canvas: [W * H * 4]u8 = @splat(0);
    var expect: [frs.len][W * H * 4]u8 = undefined;
    for (frs, 0..) |f, i| {
        var fc: [26]u8 = undefined;
        std.mem.writeInt(u32, fc[0..4], seq, .big);
        seq += 1;
        std.mem.writeInt(u32, fc[4..8], f.w, .big);
        std.mem.writeInt(u32, fc[8..12], f.h, .big);
        std.mem.writeInt(u32, fc[12..16], f.x, .big);
        std.mem.writeInt(u32, fc[16..20], f.y, .big);
        std.mem.writeInt(u16, fc[20..22], f.delay, .big);
        std.mem.writeInt(u16, fc[22..24], 1000, .big);
        fc[24] = f.dispose;
        fc[25] = f.blend;
        try putChunk(&file, a, "fcTL", &fc);
        const rgba = try a.alloc(u8, f.w * f.h * 4);
        defer a.free(rgba);
        for (0..f.w * f.h) |k| rgba[k * 4 ..][0..4].* = f.px;
        const z = try idatOf(a, rgba, f.w, f.h);
        defer a.free(z);
        if (i == 0) try putChunk(&file, a, "IDAT", z) else {
            const fd = try a.alloc(u8, z.len + 4);
            defer a.free(fd);
            std.mem.writeInt(u32, fd[0..4], seq, .big);
            seq += 1;
            @memcpy(fd[4..], z);
            try putChunk(&file, a, "fdAT", fd);
        }
        const before = canvas;
        for (0..f.h) |y| for (0..f.w) |x| {
            const d = canvas[((f.y + y) * W + f.x + x) * 4 ..][0..4];
            if (f.blend == 0) d.* = f.px else blendPixel(d, f.px);
        };
        expect[i] = canvas;
        if (f.dispose == 1) {
            for (0..f.h) |y| for (0..f.w) |x| {
                canvas[((f.y + y) * W + f.x + x) * 4 ..][0..4].* = .{ 0, 0, 0, 0 };
            };
        } else if (f.dispose == 2) canvas = before;
    }
    try putChunk(&file, a, "IEND", "");

    try testing.expectEqual(@as(u32, frs.len), frameCount(file.items));
    var an = try Animator.init(a, file.items, .{});
    defer an.deinit();
    for (frs, 0..) |f, i| {
        try testing.expectEqual(@as(?u32, f.delay), try an.next());
        try testing.expectEqualSlices(u8, &expect[i], an.canvas);
    }
    try testing.expectEqual(@as(?u32, null), try an.next());
    // Plain decode = default image.
    const img = try png.decode(a, file.items, .{});
    defer img.deinit(a);
    try testing.expectEqualSlices(u8, &expect[0], img.data);
    // Spot-check the blend: (200,100,0,128) over (10,20,30,255); libwebp integer math truncates.
    try testing.expectEqualSlices(u8, &.{ 105, 60, 14, 255 }, expect[1][((1 * W) + 2) * 4 ..][0..4]);
}

test "round trip: anim_enc outputs decode to the input frames" {
    const a = testing.allocator;
    const enc = @import("anim_enc.zig");
    const W = 23;
    const H = 17;
    var bufs: [4][W * H * 4]u8 = undefined;
    var frames: [4]enc.AnimFrame = undefined;
    for (&bufs, 0..) |*b, f| {
        for (0..W * H) |k| {
            const x = k % W;
            const y = k / W;
            const on = (x + f * 3) % 7 < 3 and y > f;
            b[k * 4 ..][0..4].* = if (x < 2) .{ 0, 0, 0, 0 } else if (on) .{ @intCast(40 * f), 200, @intCast(x * 9), 255 } else .{ 250, @intCast(y * 10), 5, 255 };
        }
        frames[f] = .{ .rgba = b, .delay_ms = 50 + @as(u32, @intCast(f)) * 10 };
    }
    const outs = [_][]u8{
        try enc.encodeGif(a, &frames, W, H, .{}),
        try enc.encodeApng(a, &frames, W, H, .{}),
        try enc.encodeWebpAnim(a, &frames, W, H, .{ .frame_diff = false }),
    };
    defer for (outs) |o| a.free(o);
    for (outs) |o| {
        try testing.expectEqual(@as(u32, 4), frameCount(o));
        for (0..4) |i| {
            const fr = try decodeFrame(a, o, @intCast(i), .{});
            defer fr.image.deinit(a);
            try testing.expectEqual(frames[i].delay_ms, fr.delay_ms);
            for (0..W * H) |k| {
                const exp = bufs[i][k * 4 ..][0..4];
                const got = fr.image.data[k * 4 ..][0..4];
                if (exp[3] == 0) {
                    try testing.expectEqual(@as(u8, 0), got[3]);
                } else try testing.expectEqualSlices(u8, exp, got);
            }
        }
    }
}

test "fuzz animation decoders" {
    const a = testing.allocator;
    const bases = [_][]const u8{
        @embedFile("testdata/anim_lossy.webp"),
        @embedFile("testdata/anim_ll.webp"),
        @embedFile("testdata/anim.gif"),
        @embedFile("testdata/gif_takumi.gif"),
    };
    var prng = std.Random.DefaultPrng.init(77);
    const rnd = prng.random();
    var buf: [4096]u8 = undefined;
    for (0..3000) |i| {
        const base = bases[i % bases.len];
        const n = @min(base.len, buf.len);
        const b = buf[0..n];
        @memcpy(b, base[0..n]);
        for (0..1 + rnd.uintLessThan(usize, 6)) |_| b[rnd.uintLessThan(usize, n)] = rnd.int(u8);
        const len = if (i % 4 == 0) rnd.uintLessThan(usize, n) else n;
        _ = frameCount(b[0..len]);
        var an = Animator.init(a, b[0..len], .{ .max_pixels = 1 << 18 }) catch continue;
        defer an.deinit();
        var k: u32 = 0;
        while (k < 8) : (k += 1) {
            const r = an.next() catch break;
            if (r == null) break;
        }
    }
}

test "fuzz apng frame access" {
    const a = testing.allocator;
    const enc = @import("anim_enc.zig");
    var px: [3][12 * 9 * 4]u8 = undefined;
    var frames: [3]enc.AnimFrame = undefined;
    for (&px, 0..) |*p, f| {
        for (p, 0..) |*v, k| v.* = @truncate(k * (f + 3) ^ (k >> 3));
        frames[f] = .{ .rgba = p, .delay_ms = 30 };
    }
    const base = try enc.encodeApng(a, &frames, 12, 9, .{});
    defer a.free(base);
    const buf = try a.alloc(u8, base.len);
    defer a.free(buf);
    var prng = std.Random.DefaultPrng.init(99);
    const rnd = prng.random();
    for (0..3000) |i| {
        @memcpy(buf, base);
        for (0..1 + rnd.uintLessThan(usize, 4)) |_| buf[rnd.uintLessThan(usize, buf.len)] = rnd.int(u8);
        const len = if (i % 4 == 0) rnd.uintLessThan(usize, buf.len) else buf.len;
        _ = frameCount(buf[0..len]);
        var an = Animator.init(a, buf[0..len], .{ .max_pixels = 1 << 16 }) catch continue;
        defer an.deinit();
        for (0..4) |_| {
            const r = an.next() catch break;
            if (r == null) break;
        }
    }
}

test "animated webp: frame larger than the canvas is rejected before decoding" {
    const a = testing.allocator;
    const enc = @import("anim_enc.zig");
    const W = 23;
    const H = 17;
    var px: [2][W * H * 4]u8 = undefined;
    var frames: [2]enc.AnimFrame = undefined;
    for (&px, 0..) |*p, f| {
        for (p, 0..) |*v, k| v.* = @truncate(k * (f + 1));
        frames[f] = .{ .rgba = p, .delay_ms = 40 };
    }
    const file = try enc.encodeWebpAnim(a, &frames, W, H, .{ .frame_diff = false });
    defer a.free(file);
    // Shrink the VP8X canvas to 4x4: every 23x17 ANMF frame now overflows it.
    const v = std.mem.indexOf(u8, file, "VP8X").? + 8;
    file[v + 4 ..][0..6].* = .{ 3, 0, 0, 3, 0, 0 };
    var fa = std.testing.FailingAllocator.init(a, .{});
    var an = try Animator.init(fa.allocator(), file, .{});
    defer an.deinit();
    // Any allocation from here on (i.e. a frame decode) would fail with OutOfMemory.
    fa.fail_index = fa.alloc_index;
    try testing.expectError(error.InvalidData, an.next());
}

test "animator: frame count cap" {
    const a = testing.allocator;
    // 1x1 GIF with max_frames + 5 tiny frames (LZW data = EOI only).
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(a);
    try file.appendSlice(a, "GIF89a\x01\x00\x01\x00\x00\x00\x00");
    for (0..Animator.max_frames + 5) |_| try file.appendSlice(a, &.{ 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 1, 0x05, 0 });
    try file.append(a, 0x3b);
    var an = try Animator.init(a, file.items, .{});
    defer an.deinit();
    var n: u32 = 0;
    const err = while (an.next()) |r| {
        if (r == null) break error.TestUnexpectedResult;
        n += 1;
    } else |e| e;
    try testing.expectEqual(error.ImageTooLarge, err);
    try testing.expectEqual(Animator.max_frames, n);
}

test "animator: total work budget" {
    const a = testing.allocator;
    // 64x64 GIF, 100 full-canvas frames with disposal 3 (save + restore): 100 * 3 * 4096 px
    // exceeds 16 * max_pixels when max_pixels = 8192.
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(a);
    try file.appendSlice(a, "GIF89a\x40\x00\x40\x00\x00\x00\x00");
    for (0..100) |_| {
        try file.appendSlice(a, "\x21\xf9\x04\x0c\x00\x00\x00\x00");
        try file.appendSlice(a, &.{ 0x2c, 0, 0, 0, 0, 64, 0, 64, 0, 0, 2, 1, 0x05, 0 });
    }
    try file.append(a, 0x3b);
    var an = try Animator.init(a, file.items, .{ .max_pixels = 8192 });
    defer an.deinit();
    var n: u32 = 0;
    const err = while (an.next()) |r| {
        if (r == null) break error.TestUnexpectedResult;
        n += 1;
    } else |e| e;
    try testing.expectEqual(error.ImageTooLarge, err);
    try testing.expect(n > 5 and n < 100);
}

test "animator: Limits.max_frames lowers the frame cap" {
    const a = testing.allocator;
    // 1x1 GIF with 20 tiny frames, walked under a 7-frame limit.
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(a);
    try file.appendSlice(a, "GIF89a\x01\x00\x01\x00\x00\x00\x00");
    for (0..20) |_| try file.appendSlice(a, &.{ 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 1, 0x05, 0 });
    try file.append(a, 0x3b);
    var an = try Animator.init(a, file.items, .{ .max_frames = 7 });
    defer an.deinit();
    var n: u32 = 0;
    const err = while (an.next()) |r| {
        if (r == null) break error.TestUnexpectedResult;
        n += 1;
    } else |e| e;
    try testing.expectEqual(error.ImageTooLarge, err);
    try testing.expectEqual(@as(u32, 7), n);
}
