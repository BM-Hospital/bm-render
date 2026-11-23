//! Image XObjects (krilla `graphics/image/mod.rs`, takumi-pdf `raster.rs` / `paint.rs`
//! `rasterized_image`). An image source's encoded bytes go in as krilla takes them when no colour
//! filter recolours it:
//!
//! * a JPEG embeds its original bytes (`/DCTDecode`, the colour space zune-jpeg reads from its
//!   headers: an Adobe APP14 transform 0 means CMYK, CMYK / YCCK get `/Decode[1 0 ...]`, an
//!   embedded ICC profile becomes `[/ICCBased ..]`);
//! * a PNG that is grayscale, RGB or indexed without transparency and not interlaced embeds its
//!   IDAT stream with `/DecodeParms` PNG predictors (15), an `/Indexed` colour space for a palette;
//! * any other PNG is decoded the way krilla decodes it (png_krilla.zig): grayscale stays
//!   DeviceGray, 16-bit samples stay 16-bit, straight (not premultiplied) colours, a soft mask for
//!   the alpha channel; a PNG that fails to decode fails the document with the `png` crate's
//!   message;
//! * a WebP embeds its decoded first frame, straight RGB plus an alpha soft mask;
//! * a PNG's or JPEG's ICC profile (iCCP / APP2) becomes an `[/ICCBased ..]` colour space when
//!   the PDF version supports its version and its colour space matches the image's.
//!
//! Without the bytes (a raw bitmap) or under a colour filter, takumi-pdf decodes the image itself,
//! with takumi-core's PNG decoder only: the decoded pixmap is embedded demultiplied, filtered,
//! as RGB plus a DeviceGray `/SMask` when any pixel is not opaque; a JPEG or WebP then cannot be
//! drawn (an error) and a GIF draws nothing. One object per distinct source and colour filter.
//!
//! Not ported: PDF/A's ICC-based sGrey for gray images (they stay DeviceGray).
const std = @import("std");
const w = @import("writer.zig");
const sf = @import("emit_surface.zig");
const raster = @import("../raster/raster.zig");
const render = @import("../render.zig");
const checksum = @import("../codec/checksum.zig");
const codec = @import("../codec/codec.zig");
const webp = @import("../codec/webp_dec.zig");
const pk = @import("png_krilla.zig");

const Ref = w.Ref;
const Ctx = sf.Ctx;

/// Colour transform applied to every pixel (CSS colour `filter`s), or null.
pub const PixelFilter = struct {
    ctx: *const anyopaque,
    apply: *const fn (ctx: *const anyopaque, rgba: [4]u8) [4]u8,
    key: u64,
};

/// zune-jpeg's `input_colorspace`.
const JpegSpace = enum { luma, ycbcr, rgb, cmyk, ycck };

const Jpeg = struct { w: u16, h: u16, comps: u8, space: JpegSpace, icc: ?[]const u8 = null };

/// What zune-jpeg's `decode_headers` reads (krilla `jpeg_metadata`): the markers up to the first
/// SOS, which must be reached; the frame header (8-bit samples); the colour space, in file order:
/// YCbCr by default, an Adobe APP14 transform 0 / 1 / 2 sets CMYK / YCbCr / YCCK, a frame of one
/// component Luma, of four CMYK (unless YCCK); the ICC profile from the APP2 `ICC_PROFILE`
/// segments, concatenated (in `a`).
fn jpegInfo(a: ?std.mem.Allocator, b: []const u8) ?Jpeg {
    if (b.len < 4 or b[0] != 0xFF or b[1] != 0xD8) return null;
    var i: usize = 2;
    var out: ?Jpeg = null;
    var space: JpegSpace = .ycbcr;
    var icc: std.ArrayList(u8) = .empty;
    while (i + 4 <= b.len) {
        if (b[i] != 0xFF) return null;
        const m = b[i + 1];
        if (m == 0xFF) {
            i += 1;
            continue;
        }
        if (m == 0xD8 or (m >= 0xD0 and m <= 0xD7) or m == 0x01) {
            i += 2;
            continue;
        }
        const len = (@as(usize, b[i + 2]) << 8) | b[i + 3];
        if (len < 2 or i + 2 + len > b.len) return null;
        const seg = b[i + 4 .. i + 2 + len];
        if (m == 0xEE and seg.len >= 12 and std.mem.eql(u8, seg[0..5], "Adobe")) {
            space = switch (seg[11]) {
                0 => .cmyk,
                1 => .ycbcr,
                2 => .ycck,
                else => return null,
            };
        }
        if (m == 0xE2 and seg.len >= 14 and std.mem.eql(u8, seg[0..12], "ICC_PROFILE\x00")) {
            if (a) |al| icc.appendSlice(al, seg[14..]) catch return null;
        }
        if (m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC) {
            if (seg.len < 6) return null;
            if (seg[0] != 8) return null; // 12-bit JPEGs are not DCT-passed
            const comps = seg[5];
            if (comps == 1) space = .luma;
            if (comps == 4 and space != .ycck) space = .cmyk;
            out = .{ .h = (@as(u16, seg[1]) << 8) | seg[2], .w = (@as(u16, seg[3]) << 8) | seg[4], .comps = comps, .space = space };
        }
        if (m == 0xDA) {
            var o = out orelse return null;
            o.space = space;
            if (icc.items.len > 0) o.icc = icc.items;
            return o;
        }
        i += 2 + len;
    }
    return null;
}

/// Whether `v` (the PDF version) embeds an ICC profile of `p`'s version (krilla
/// `PdfVersion::supports_icc`), and the number of components of its colour space (0: unknown).
fn iccComponents(v: w.Version, p: []const u8) u8 {
    if (p.len < 20) return 0;
    const major = p[8];
    const minor = p[9] >> 4;
    const ok = switch (v) {
        .v1_4 => major <= 2 and minor <= 2,
        .v1_5 => major <= 4,
        .v1_6 => major <= 4 and minor <= 1,
        .v1_7, .v2_0 => major <= 4 and minor <= 2,
    };
    if (!ok) return 0;
    const cs = p[16..20];
    const three = [_][]const u8{ "XYZ ", "Lab ", "Luv ", "YCbr", "Yxy ", "LMS ", "RGB ", "HSV ", "HLS ", "CMY ", "3CLR" };
    for (three) |t| if (std.mem.eql(u8, cs, t)) return 3;
    if (std.mem.eql(u8, cs, "GRAY") or std.mem.eql(u8, cs, "1CLR")) return 1;
    if (std.mem.eql(u8, cs, "CMYK") or std.mem.eql(u8, cs, "4CLR")) return 4;
    return 0;
}

/// krilla `ICCBasedColorSpace`: `[/ICCBased stream]` (category `color_spaces`) over the profile
/// stream (`/N /Range`, Flate, category `icc_profiles`), once per profile; null when the profile
/// does not fit an image of `comps` components or the PDF version.
fn iccSpace(cx: *Ctx, profile: ?[]const u8, comps: u8) ?Ref {
    const p = profile orelse return null;
    if (iccComponents(cx.version, p) != comps) return null;
    var h = sf.Hasher.init('C');
    h.bytes(p);
    const key = h.final();
    if (cx.doc.cacheGet(key)) |r| return r;
    const d = cx.doc;
    const pr = d.alloc();
    const e = d.encode(p, .flate);
    const sb = d.beginStream(pr, .icc_profiles, e);
    sb.pairInt("N", comps);
    sb.key("Range");
    sb.reals(([_]f32{ 0, 1, 0, 1, 0, 1, 0, 1 })[0 .. 2 * @as(usize, comps)]);
    sb.filter(e);
    d.endDict();
    const r = d.alloc();
    const b = d.begin(r, .color_spaces);
    b.arr();
    b.name("ICCBased");
    b.ref(pr);
    b.arrEnd();
    d.end();
    d.cachePut(key, r);
    return r;
}

/// The encoded bytes of image source `src` (a `data:` URL or a registered resource), if known.
pub fn sourceBytes(r: *render.Renderer, a: std.mem.Allocator, src: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, src, "data:")) return render.decodeDataUri(a, src);
    for (r.images.items) |*e| {
        if (e.width == 0 and std.mem.eql(u8, e.src, src)) return e.data;
    }
    return null;
}

/// A JPEG source embedded as is (krilla `Image::from_jpeg`); null when `bytes` is no 8-bit
/// JPEG with 1, 3 or 4 components.
pub fn regJpeg(cx: *Ctx, bytes: []const u8, bytes_hash: u64) ?Ref {
    var h = sf.Hasher.init('J');
    h.u64_(bytes.len);
    h.u64_(bytes_hash);
    const key = h.final();
    if (cx.doc.cacheGet(key)) |r| return r;
    const info = jpegInfo(cx.a, bytes) orelse return null;
    // krilla's image colour space (`ImageColorspace` from zune's input colour space)
    const comps: u8 = switch (info.space) {
        .luma => 1,
        .ycbcr, .rgb => 3,
        .cmyk, .ycck => 4,
    };
    const icc = iccSpace(cx, info.icc, comps);
    const r = cx.doc.alloc();
    const b = cx.doc.beginStream(r, .images, .{ .data = bytes });
    b.pairName("Type", "XObject");
    b.pairName("Subtype", "Image");
    b.pairName("Filter", "DCTDecode");
    b.pairInt("Width", info.w);
    b.pairInt("Height", info.h);
    if (icc) |cs| b.pairRef("ColorSpace", cs) else if (comps == 3) {
        if (@import("conform.zig").rgbSpace(cx)) |cs| b.pairRef("ColorSpace", cs) else b.pairName("ColorSpace", "DeviceRGB");
    } else b.pairName("ColorSpace", if (comps == 1) "DeviceGray" else "DeviceCMYK");
    if (comps == 4) {
        // krilla inverts every CMYK / YCCK JPEG (Photoshop convention)
        b.key("Decode");
        b.reals(&.{ 1, 0, 1, 0, 1, 0, 1, 0 });
    }
    b.pairInt("BitsPerComponent", 8);
    cx.doc.endDict();
    cx.doc.cachePut(key, r);
    return r;
}

const Png = struct { w: u32, h: u32, depth: u8, color: u8, idat: []const u8, palette: ?[]const u8 };

/// krilla `PngData::new`: a PNG whose IDAT stream can be embedded as is: not interlaced, grayscale,
/// RGB or indexed (with its palette), no `tRNS`, valid CRCs on the critical chunks, no unknown
/// critical chunk, ending in IEND. The IDAT data is concatenated into `a`.
fn pngInfo(a: std.mem.Allocator, b: []const u8) ?Png {
    const magic = "\x89PNG\r\n\x1a\n";
    if (b.len < magic.len or !std.mem.eql(u8, b[0..magic.len], magic)) return null;
    var i: usize = magic.len;
    var out: Png = .{ .w = 0, .h = 0, .depth = 0, .color = 0, .idat = &.{}, .palette = null };
    var idat: std.ArrayList(u8) = .empty;
    var seen_idat = false;
    var palette_seen = false;
    var first = true;
    while (i < b.len) {
        if (i + 12 > b.len) return null;
        const len = std.mem.readInt(u32, b[i..][0..4], .big);
        if (len > b.len - i - 12) return null;
        const kind = b[i + 4 .. i + 8];
        const data = b[i + 8 .. i + 8 + len];
        const crc = std.mem.readInt(u32, b[i + 8 + len ..][0..4], .big);
        i += 12 + len;
        const critical = kind[0] & 0x20 == 0;
        const crc_ok = checksum.crc32(checksum.crc32(0, kind), data) == crc;
        if (first) {
            first = false;
            if (!std.mem.eql(u8, kind, "IHDR") or !crc_ok or data.len != 13) return null;
            out.w = std.mem.readInt(u32, data[0..4], .big);
            out.h = std.mem.readInt(u32, data[4..8], .big);
            out.depth = data[8];
            out.color = data[9];
            const depth_ok = switch (out.color) {
                0 => out.depth == 1 or out.depth == 2 or out.depth == 4 or out.depth == 8 or out.depth == 16,
                2 => out.depth == 8 or out.depth == 16,
                3 => out.depth == 1 or out.depth == 2 or out.depth == 4 or out.depth == 8,
                4, 6 => out.depth == 8 or out.depth == 16,
                else => false,
            };
            if (!depth_ok or out.w == 0 or out.h == 0 or data[10] != 0 or data[11] != 0 or data[12] > 1) return null;
            // interlaced, or with an alpha channel
            if (data[12] != 0 or !(out.color == 0 or out.color == 2 or out.color == 3)) return null;
            continue;
        }
        if (critical and !crc_ok) return null;
        if (std.mem.eql(u8, kind, "IHDR") or std.mem.eql(u8, kind, "tRNS")) return null;
        if (std.mem.eql(u8, kind, "PLTE")) {
            const max_len: usize = switch (out.color) {
                3 => 3 * (@as(usize, 1) << @intCast(out.depth)),
                2 => 3 * 256,
                else => return null,
            };
            if (palette_seen or seen_idat or data.len == 0 or data.len % 3 != 0 or data.len > max_len) return null;
            palette_seen = true;
            if (out.color == 3) out.palette = data;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            seen_idat = true;
            idat.appendSlice(a, data) catch return null;
        } else if (std.mem.eql(u8, kind, "IEND")) {
            if (out.color == 3 and out.palette == null) return null;
            if (!seen_idat) return null;
            out.idat = idat.items;
            return out;
        } else if (critical) return null;
    }
    return null;
}

/// A PNG source whose IDAT stream is embedded as is (krilla `Image::from_png` / `PngRepr`):
/// `/FlateDecode` with the PNG predictors, `/Indexed` over DeviceRGB for a palette image; null
/// when the PNG cannot take that path (it is then decoded).
pub fn regPng(cx: *Ctx, bytes: []const u8, bytes_hash: u64) ?Ref {
    var h = sf.Hasher.init('P');
    h.u64_(bytes.len);
    h.u64_(bytes_hash);
    const key = h.final();
    if (cx.doc.cacheGet(key)) |r| return r;
    const info = pngInfo(cx.a, bytes) orelse return null;
    const colors: i64 = switch (info.color) {
        2 => 3,
        else => 1,
    };
    // the profile `read_info` found, for the expanded colour type (a palette expands to RGB)
    const md = pk.meta(cx.a, bytes) orelse return null;
    const icc = iccSpace(cx, md.icc, if (info.color == 0) 1 else 3);
    const base: ?Ref = icc orelse if (info.color != 0) @import("conform.zig").rgbSpace(cx) else null;
    const r = cx.doc.alloc();
    const b = cx.doc.beginStream(r, .images, .{ .data = info.idat, .flate = true });
    b.pairName("Type", "XObject");
    b.pairName("Subtype", "Image");
    b.pairName("Filter", "FlateDecode");
    b.key("DecodeParms");
    b.dict();
    b.pairInt("Predictor", 15);
    b.pairInt("Colors", colors);
    b.pairInt("BitsPerComponent", info.depth);
    b.pairInt("Columns", info.w);
    b.dictEnd();
    b.pairInt("Width", info.w);
    b.pairInt("Height", info.h);
    b.key("ColorSpace");
    if (info.palette) |pal| {
        b.arr();
        b.name("Indexed");
        if (base) |cs| b.ref(cs) else b.name("DeviceRGB");
        b.int(@intCast(pal.len / 3 - 1));
        b.str(pal);
        b.arrEnd();
    } else if (base) |cs| b.ref(cs) else b.name(if (info.color == 2) "DeviceRGB" else "DeviceGray");
    b.pairInt("BitsPerComponent", info.depth);
    cx.doc.endDict();
    cx.doc.cachePut(key, r);
    return r;
}

/// What drawing an image source comes to (takumi-pdf `rasterized_image` + `drawable`).
pub const Drawn = union(enum) {
    ref: Ref,
    /// nothing to draw (no source, a GIF, an undecodable bitmap takumi-core skips)
    none,
    /// the document fails: `msg` ++ `arg`
    fail: struct { msg: []const u8, arg: []const u8 = "" },
};

/// The colour and alpha samples of a decoded image as an XObject plus soft mask (krilla `Repr::Sampled`).
fn regSampled(cx: *Ctx, key: u64, wd: u32, ht: u32, luma: bool, bits: u8, color: []const u8, alpha: ?[]const u8, icc_profile: ?[]const u8) Ref {
    var smask: ?Ref = null;
    if (alpha) |al| {
        const sr = cx.doc.alloc();
        const e = cx.doc.encode(al, .flate);
        const b = cx.doc.beginStream(sr, .images, e);
        b.pairName("Type", "XObject");
        b.pairName("Subtype", "Image");
        b.filter(e);
        b.pairInt("Width", wd);
        b.pairInt("Height", ht);
        b.pairName("ColorSpace", "DeviceGray");
        b.pairInt("BitsPerComponent", bits);
        cx.doc.endDict();
        smask = sr;
    }
    const icc = iccSpace(cx, icc_profile, if (luma) 1 else 3) orelse if (!luma) @import("conform.zig").rgbSpace(cx) else null;
    const r = cx.doc.alloc();
    const e = cx.doc.encode(color, .flate);
    const b = cx.doc.beginStream(r, .images, e);
    b.pairName("Type", "XObject");
    b.pairName("Subtype", "Image");
    b.filter(e);
    b.pairInt("Width", wd);
    b.pairInt("Height", ht);
    if (icc) |cs| b.pairRef("ColorSpace", cs) else b.pairName("ColorSpace", if (luma) "DeviceGray" else "DeviceRGB");
    b.pairInt("BitsPerComponent", bits);
    if (smask) |sr| b.pairRef("SMask", sr);
    cx.doc.endDict();
    cx.doc.cachePut(key, r);
    return r;
}

const fail_prefix = "Writing the PDF failed: failed to process image: ";

/// krilla `Image::from_png` + `decode_png` for a PNG it does not pass through.
fn regPngDecoded(cx: *Ctx, bytes: []const u8, bytes_hash: u64) ?Drawn {
    var h = sf.Hasher.init('Q');
    h.u64_(bytes.len);
    h.u64_(bytes_hash);
    const key = h.final();
    if (cx.doc.cacheGet(key)) |r| return .{ .ref = r };
    const md = pk.meta(cx.a, bytes) orelse return null;
    if (md.depth == 16 and !cx.version.atLeast(.v1_5)) return .{ .fail = .{ .msg = "Writing the PDF failed: sixteen bit images require PDF 1.5 or newer, but the selected PDF version does not support them" } };
    switch (pk.decode(cx.a, bytes, render.Renderer.max_image_pixels)) {
        .no_meta => return null,
        .fail => |m| return .{ .fail = .{ .msg = fail_prefix, .arg = m } },
        .ok => |d| return .{ .ref = regSampled(cx, key, d.w, d.h, d.space == .luma, d.bits, d.color, d.alpha, md.icc) },
    }
}

/// krilla `Image::from_webp`: the first frame, decoded, straight RGB plus the alpha channel when
/// the file declares one (VP8X flag, VP8L header bit) and a pixel is not opaque.
fn regWebp(cx: *Ctx, bytes: []const u8, bytes_hash: u64) ?Drawn {
    var h = sf.Hasher.init('W');
    h.u64_(bytes.len);
    h.u64_(bytes_hash);
    const key = h.final();
    if (cx.doc.cacheGet(key)) |r| return .{ .ref = r };
    const body = webp.riffBody(bytes) orelse return null;
    var it = webp.Chunks{ .data = body };
    const first = it.next() orelse return null;
    var has_alpha = false;
    if (std.mem.eql(u8, &first.tag, "VP8X")) {
        if (first.body.len < 10) return null;
        has_alpha = first.body[0] & 0x10 != 0;
    } else if (std.mem.eql(u8, &first.tag, "VP8L")) {
        if (first.body.len < 5) return null;
        has_alpha = (std.mem.readInt(u32, first.body[1..5], .little) >> 28) & 1 != 0;
    } else if (!std.mem.eql(u8, &first.tag, "VP8 ")) return null;
    const img = webp.decode(cx.a, bytes, .{ .max_pixels = render.Renderer.max_image_pixels }) catch |e| return .{ .fail = .{ .msg = fail_prefix, .arg = switch (e) {
        error.OutOfMemory => "out of memory",
        else => "invalid data",
    } } };
    const n: usize = @as(usize, img.width) * img.height;
    const rgb = cx.a.alloc(u8, n * 3) catch return null;
    const al = cx.a.alloc(u8, n) catch return null;
    var translucent = false;
    for (0..n) |i| {
        rgb[i * 3 ..][0..3].* = img.data[i * 4 ..][0..3].*;
        al[i] = img.data[i * 4 + 3];
        if (al[i] != 255) translucent = true;
    }
    return .{ .ref = regSampled(cx, key, img.width, img.height, false, 8, rgb, if (has_alpha and translucent) al else null, null) };
}

/// takumi-pdf `rasterized_image` for an image source `src` (bytes from `sourceBytes`, decoded
/// pixmap `pmx`) under colour filter `filter`; `label` names the image in an error.
/// `bytes_hash`: XxHash64 of `bytes` seeded with their length (render.Renderer.contentHash), 0:
/// computed here.
pub fn draw(cx: *Ctx, bytes: ?[]const u8, bytes_hash: u64, pmx: ?*const raster.Pixmap, filter: ?PixelFilter, label: []const u8) Drawn {
    var key: u64 = 0;
    if (bytes) |b| {
        const bh = if (bytes_hash != 0) bytes_hash else std.hash.XxHash64.hash(b.len, b);
        if (filter == null) {
            // takumi-pdf `embedded_image`: the bytes as krilla takes them
            // (an APNG is takumi-core's `AnimatedSource`, decoded by takumi: the pixmap path)
            if (std.mem.startsWith(u8, b, "\x89PNG\r\n\x1a\n") and @import("../codec/png.zig").apngFrameCount(b) == 0) {
                if (regPng(cx, b, bh)) |r| return .{ .ref = r };
                if (regPngDecoded(cx, b, bh)) |d| return d;
            } else if (b.len >= 3 and b[0] == 0xFF and b[1] == 0xD8 and b[2] == 0xFF) {
                if (regJpeg(cx, b, bh)) |r| return .{ .ref = r };
            } else if (b.len >= 12 and std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "WEBP")) {
                if (regWebp(cx, b, bh)) |d| return d;
            }
        }
        // takumi-core decodes PNG only in takumi-pdf: a JPEG or WebP cannot be drawn, a GIF is skipped
        switch (codec.sniff(b)) {
            .jpeg, .webp => return .{ .fail = .{
                .msg = "Image could not be decoded: ",
                .arg = std.fmt.allocPrint(cx.a, "{s}: {s}An error occurred while decoding the image data: the image format is not supported", .{ label, if (filter != null) "a filter needs the image's pixels: " else "" }) catch "",
            } },
            .gif => return .none,
            // takumi-pdf `rasterized_image`: a filter needs the pixels, so a PNG whose pixels do not
            // decode stops the render (UndrawableImage) instead of leaving the image out
            .png => if (filter != null and pmx == null) switch (pk.decode(cx.a, b, render.Renderer.max_image_pixels)) {
                .fail => |m| return .{ .fail = .{
                    .msg = "Image could not be decoded: ",
                    .arg = std.fmt.allocPrint(cx.a, "{s}: a filter needs the image's pixels: An error occurred while decoding the image data: {s}", .{ label, m }) catch "",
                } },
                else => {},
            },
            else => {},
        }
        key = bh | 1;
    }
    const pm = pmx orelse return .none;
    return .{ .ref = regPixmap(cx, pm, key, filter) };
}

/// The intrinsic size takumi reads from an image's header when bm-render cannot decode it (a CMYK
/// JPEG, a PNG that fails to decode): PNG IHDR, JPEG frame header, WebP header; null otherwise.
pub fn headerSize(bytes: []const u8) ?[2]u32 {
    const d = switch (codec.sniff(bytes)) {
        .png, .jpeg, .webp => codec.dimensions(bytes) orelse return null,
        else => return null,
    };
    if (d.w == 0 or d.h == 0) return null;
    return .{ d.w, d.h };
}

/// A premultiplied pixmap as an image XObject (krilla `Image::from_rgba8` after takumi's
/// `bitmap_image`: demultiplied, filtered). `key` identifies the pixels (e.g. the source bytes
/// hash); 0 hashes the pixels.
pub fn regPixmap(cx: *Ctx, pm: *const raster.Pixmap, key_in: u64, filter: ?PixelFilter) Ref {
    var h = sf.Hasher.init('I');
    if (key_in != 0) h.u64_(key_in) else h.bytes(pm.data);
    h.u64_(pm.width);
    h.u64_(pm.height);
    h.u64_(if (filter) |f| f.key else 0);
    const key = h.final();
    if (cx.doc.cacheGet(key)) |r| return r;
    const a = cx.a;
    const n: usize = @as(usize, pm.width) * pm.height;
    const px = a.dupe(u8, pm.data[0 .. n * 4]) catch return oom(cx);
    render.unpremultiply(px);
    const rgb = a.alloc(u8, n * 3) catch return oom(cx);
    const alpha = a.alloc(u8, n) catch return oom(cx);
    var translucent = false;
    // (the filter is a pure function of the pixel: images repeat colours, so the results of
    // recent ones are kept in a small direct-mapped table)
    var memo_in: [256]u32 = undefined;
    var memo_out: [256][4]u8 = undefined;
    var memo_ok: [256]bool = @splat(false);
    for (0..n) |i| {
        var p: [4]u8 = px[i * 4 ..][0..4].*;
        if (filter) |f| {
            const k: u32 = @bitCast(p);
            const slot = (k *% 0x9E37_79B1) >> 24;
            if (memo_ok[slot] and memo_in[slot] == k) {
                p = memo_out[slot];
            } else {
                p = f.apply(f.ctx, p);
                memo_in[slot] = k;
                memo_out[slot] = p;
                memo_ok[slot] = true;
            }
        }
        rgb[i * 3 ..][0..3].* = p[0..3].*;
        alpha[i] = p[3];
        if (p[3] != 255) translucent = true;
    }
    var smask: ?Ref = null;
    if (translucent) {
        const sr = cx.doc.alloc();
        const e = cx.doc.encode(alpha, .flate);
        const b = cx.doc.beginStream(sr, .images, e);
        b.pairName("Type", "XObject");
        b.pairName("Subtype", "Image");
        b.filter(e);
        b.pairInt("Width", pm.width);
        b.pairInt("Height", pm.height);
        b.pairName("ColorSpace", "DeviceGray");
        b.pairInt("BitsPerComponent", 8);
        cx.doc.endDict();
        smask = sr;
    }
    const r = cx.doc.alloc();
    const e = cx.doc.encode(rgb, .flate);
    const icc = @import("conform.zig").rgbSpace(cx); // [conformance] PDF/A: ICC-based sRGB
    const b = cx.doc.beginStream(r, .images, e);
    b.pairName("Type", "XObject");
    b.pairName("Subtype", "Image");
    b.filter(e);
    b.pairInt("Width", pm.width);
    b.pairInt("Height", pm.height);
    if (icc) |cs| b.pairRef("ColorSpace", cs) else b.pairName("ColorSpace", "DeviceRGB");
    b.pairInt("BitsPerComponent", 8);
    if (smask) |sr| b.pairRef("SMask", sr);
    cx.doc.endDict();
    cx.doc.cachePut(key, r);
    return r;
}

fn oom(cx: *Ctx) Ref {
    cx.doc.b.failed = true;
    return cx.doc.alloc();
}

test "jpeg frame header" {
    // SOI, APP0 (len 4), SOF0: 8-bit, 2x3, 3 components
    const b = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0, 0xFF, 0xC0, 0, 17, 8, 0, 3, 0, 2, 3, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1, 0xFF, 0xDA, 0, 2 };
    const info = jpegInfo(null, &b).?;
    try std.testing.expectEqual(@as(u16, 2), info.w);
    try std.testing.expectEqual(@as(u16, 3), info.h);
    try std.testing.expectEqual(@as(u8, 3), info.comps);
    try std.testing.expectEqual(JpegSpace.ycbcr, info.space);
    // an Adobe APP14 with transform 0 before the frame: zune reads CMYK, whatever the components
    const adobe = [_]u8{ 0xFF, 0xD8, 0xFF, 0xEE, 0, 14, 'A', 'd', 'o', 'b', 'e', 0, 100, 0, 0, 0, 0, 0 } ++ b[8..].*;
    try std.testing.expectEqual(JpegSpace.cmyk, jpegInfo(null, &adobe).?.space);
    // cut before the scan: not readable
    try std.testing.expect(jpegInfo(null, b[0 .. b.len - 4]) == null);
}

test "icc profile version and colour space" {
    var p: [20]u8 = @splat(0);
    p[8] = 4;
    p[9] = 0x20;
    @memcpy(p[16..20], "RGB ");
    try std.testing.expectEqual(@as(u8, 3), iccComponents(.v1_7, &p));
    try std.testing.expectEqual(@as(u8, 0), iccComponents(.v1_4, &p));
    @memcpy(p[16..20], "GRAY");
    try std.testing.expectEqual(@as(u8, 1), iccComponents(.v1_7, &p));
}

test "png passthrough eligibility" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const Build = struct {
        fn chunk(out: *std.ArrayList(u8), al: std.mem.Allocator, kind: []const u8, data: []const u8) !void {
            var len: [4]u8 = undefined;
            std.mem.writeInt(u32, &len, @intCast(data.len), .big);
            try out.appendSlice(al, &len);
            try out.appendSlice(al, kind);
            try out.appendSlice(al, data);
            var crc: [4]u8 = undefined;
            std.mem.writeInt(u32, &crc, checksum.crc32(checksum.crc32(0, kind), data), .big);
            try out.appendSlice(al, &crc);
        }
        fn png(al: std.mem.Allocator, color: u8, extra: ?[]const u8) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(al, "\x89PNG\r\n\x1a\n");
            try chunk(&out, al, "IHDR", &.{ 0, 0, 0, 2, 0, 0, 0, 3, 8, color, 0, 0, 0 });
            if (color == 3) try chunk(&out, al, "PLTE", &.{ 255, 0, 0, 0, 0, 255 });
            if (extra) |k| try chunk(&out, al, k, &.{ 1, 2 });
            try chunk(&out, al, "IDAT", "abc");
            try chunk(&out, al, "tEXt", "k\x00v");
            try chunk(&out, al, "IDAT", "de");
            try chunk(&out, al, "IEND", "");
            return out.items;
        }
    };
    const rgb = pngInfo(aa, try Build.png(aa, 2, null)).?;
    try std.testing.expectEqual(@as(u32, 2), rgb.w);
    try std.testing.expectEqual(@as(u32, 3), rgb.h);
    try std.testing.expectEqualStrings("abcde", rgb.idat);
    try std.testing.expect(rgb.palette == null);
    const pal = pngInfo(aa, try Build.png(aa, 3, null)).?;
    try std.testing.expectEqual(@as(usize, 6), pal.palette.?.len);
    // transparency, an alpha channel, an unknown critical chunk: decoded instead
    try std.testing.expect(pngInfo(aa, try Build.png(aa, 2, "tRNS")) == null);
    try std.testing.expect(pngInfo(aa, try Build.png(aa, 6, null)) == null);
    try std.testing.expect(pngInfo(aa, try Build.png(aa, 2, "ABCD")) == null);
}
