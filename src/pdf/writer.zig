//! Low-level PDF writer: the object model and file structure of `pdf-writer` 0.15 plus the
//! serialisation layer of takumi's vendored krilla (`chunk_container.rs`, `object_stream.rs`,
//! `document.rs`, `resource.rs`), byte-compatible with its non-pretty output:
//!
//! * tokens are separated lazily (a space only between two non-delimiter tokens:
//!   `<</Type/Pages/Count 1/Kids[5 0 R]>>`), numbers are integers when integral and otherwise
//!   the shortest round-trip decimal of the f32 (ryu), names `#xx`-escape irregular bytes,
//!   strings are literal for ASCII (balanced parentheses kept, `\n \r \t \b \f \\`, octal for the
//!   rest) and hex otherwise, text strings are PDFDocEncoding for printable ASCII and UTF-16BE
//!   with a BOM otherwise;
//! * objects are written into *categories* (krilla's chunk kinds) with provisional refs and
//!   renumbered at `finish` in krilla's chunk order (page tree, outline, ..., struct elements,
//!   ..., pages, ..., then the stream chunks: fonts, ..., page contents, ..., XObjects, images),
//!   so object numbers increase monotonically through the file exactly like takumi-pdf;
//! * `finish` writes the header (`%PDF-1.x` + binary marker), all objects, the struct-element
//!   object streams (PDF >= 1.5), the Info dictionary, the XMP metadata stream (via callback),
//!   the catalog and a FlateDecode cross-reference stream (PDF >= 1.5) or a classic xref table +
//!   trailer (PDF 1.4), with krilla's /ID (SipHash-1-3 128 of the bytes so far, base64).
//!
//! Errors while appending (out of memory) are sticky: the builders return nothing and `finish`
//! reports `error.OutOfMemory`. Everything is allocated from the allocator given to `Doc.init`
//! (the per-render bump arena); stream data passed to `beginStream` is referenced, not copied,
//! and must stay alive until `finish`.
const std = @import("std");
const builtin = @import("builtin");
const deflate = @import("../codec/deflate.zig");
const Bump = @import("../bump.zig").Bump;

const Allocator = std.mem.Allocator;

/// Provisional object reference (1-based; renumbered at `finish`). 0 is never a valid ref.
pub const Ref = u32;

pub const Error = error{ OutOfMemory, OpenObject, DanglingRef, DuplicateObject };

/// A ref placeholder inside an object body: the byte at `pos` (an `R`) becomes `<n> 0 R`.
const Patch = struct { pos: u32, ref: Ref };

/// pdf-writer `is_delimiter_character` (decides the lazy token padding).
pub fn isDelim(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '/', '%' => true,
        else => false,
    };
}

fn isNameRegular(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%', '#' => false,
        '!'...'"', '$', '&'...'\'', '*'...'.', '0'...';', '=', '?'...'Z', '\\', '^'...'z', '|', '~' => true,
        else => false,
    };
}

const hex_digits = "0123456789ABCDEF";

// ---------------------------------------------------------------------------------------------
// Number formatting
// ---------------------------------------------------------------------------------------------

const pow10 = blk: {
    var t: [23]f64 = undefined;
    var p: f64 = 1;
    for (&t) |*e| {
        e.* = p;
        p *= 10;
    }
    break :blk t;
};

/// "00" .. "99".
const digit_pairs: [200]u8 = blk: {
    var t: [200]u8 = undefined;
    for (0..100) |i| {
        t[2 * i] = '0' + @as(u8, @intCast(i / 10));
        t[2 * i + 1] = '0' + @as(u8, @intCast(i % 10));
    }
    break :blk t;
};

fn fmtU64(out: []u8, v: u64) usize {
    var tmp: [20]u8 = undefined;
    var k: usize = tmp.len;
    var w = v;
    // (64-bit divisions only above u32; then two digits per step)
    while (w > std.math.maxInt(u32)) {
        k -= 1;
        tmp[k] = @intCast('0' + w % 10);
        w /= 10;
    }
    var x: u32 = @intCast(w);
    while (x >= 100) {
        const r = x % 100;
        x /= 100;
        k -= 2;
        tmp[k..][0..2].* = digit_pairs[2 * r ..][0..2].*;
    }
    if (x >= 10) {
        k -= 2;
        tmp[k..][0..2].* = digit_pairs[2 * x ..][0..2].*;
    } else {
        k -= 1;
        tmp[k] = @intCast('0' + x);
    }
    @memcpy(out[0 .. tmp.len - k], tmp[k..]);
    return tmp.len - k;
}

/// Integer text (`itoa`).
pub fn fmtInt(out: *[24]u8, v: i64) []const u8 {
    var n: usize = 0;
    if (v < 0) {
        out[0] = '-';
        n = 1;
    }
    n += fmtU64(out[n..], @abs(v));
    return out[0..n];
}

/// pdf-writer `push_float` for an f32: integral values in i32 range as integers, everything else
/// as the shortest decimal that round-trips to the same f32 (ryu; values between 2^31 and 1e12
/// get ryu's `.0`). Never uses exponent notation. Non-finite values are written as `0`.
/// (Content streams repeat the same numbers, e.g. a glyph outline drawn for its fill, stroke and
/// shadows: single-threaded builds (wasm) keep the text of recent values in a small cache keyed by
/// the bits. The native addon renders on several threads and has no thread-local storage.)
pub fn fmtReal(out: *[48]u8, v: f32) []const u8 {
    if (!builtin.single_threaded) return fmtRealUncached(out, v);
    const bits: u32 = @bitCast(v);
    const slot = &real_cache[(bits *% 0x9E37_79B1) >> (32 - real_cache_bits)];
    if (slot.len != 0 and slot.bits == bits) {
        @memcpy(out[0..slot.len], slot.text[0..slot.len]);
        return out[0..slot.len];
    }
    const t = fmtRealUncached(out, v);
    if (t.len <= slot.text.len) {
        slot.* = .{ .bits = bits, .len = @intCast(t.len) };
        @memcpy(slot.text[0..t.len], t);
    }
    return t;
}

const real_cache_bits = 11;
const RealText = struct { bits: u32 = 0, len: u8 = 0, text: [19]u8 = undefined };
var real_cache: [1 << real_cache_bits]RealText = @splat(.{});

fn fmtRealUncached(out: *[48]u8, v: f32) []const u8 {
    if (!std.math.isFinite(v)) return "0";
    const av = @abs(v);
    var n: usize = 0;
    if (v < 0 and av != 0) {
        out[0] = '-';
        n = 1;
    }
    if (@trunc(av) == av) {
        if (av == 0) return "0";
        // (integral values beyond u64 are clamped; Rust would print all digits)
        n += fmtU64(out[n..], if (av < 1.8e19) @intFromFloat(av) else std.math.maxInt(u64));
        // outside i32 (`v as i32 as f32 != v`): ryu prints `123.0` below 1e12
        if (!(v >= -2147483648.0 and v < 2147483648.0) and av < 1.0e12) {
            out[n] = '.';
            out[n + 1] = '0';
            n += 2;
        }
        return out[0..n];
    }
    // shortest number of fractional digits k whose nearest decimal (ties to even, like ryu)
    // reads back as `v`
    const x: f64 = av;
    var k: usize = 1;
    var d: f64 = 0;
    while (true) : (k += 1) {
        const y = x * pow10[k];
        d = @floor(y + 0.5);
        if (d - y == 0.5 and @as(u64, @intFromFloat(d)) & 1 != 0) d -= 1;
        if (k == pow10.len - 1 or @as(f32, @floatCast(d / pow10[k])) == av) break;
    }
    var digits: [24]u8 = undefined;
    var di: u64 = @intFromFloat(@min(d, 1.0e19));
    while (k > 0 and di % 10 == 0 and di != 0) {
        di /= 10;
        k -= 1;
    }
    const nd = fmtU64(&digits, di);
    if (di == 0) return "0";
    if (nd > k) {
        @memcpy(out[n..][0 .. nd - k], digits[0 .. nd - k]);
        n += nd - k;
        if (k > 0) {
            out[n] = '.';
            n += 1;
            @memcpy(out[n..][0..k], digits[nd - k .. nd]);
            n += k;
        }
    } else {
        out[n] = '0';
        out[n + 1] = '.';
        n += 2;
        @memset(out[n..][0 .. k - nd], '0');
        n += k - nd;
        @memcpy(out[n..][0..nd], digits[0..nd]);
        n += nd;
    }
    return out[0..n];
}

// ---------------------------------------------------------------------------------------------
// Token buffer
// ---------------------------------------------------------------------------------------------

/// A PDF date (`(D:YYYYMMDDHHmmSS+HH'mm)` / `Z`); later fields are written only while all earlier
/// ones are present (pdf-writer `Date`).
pub const Date = struct {
    year: u16,
    month: ?u8 = null,
    day: ?u8 = null,
    hour: ?u8 = null,
    minute: ?u8 = null,
    second: ?u8 = null,
    utc_offset_hour: ?i8 = null,
    utc_offset_minute: u8 = 0,
};

/// pdf-writer `Limits` (what krilla's `check_validator_limits` reads) plus the q/Q nesting
/// fact of a content stream (krilla `ContentBuilder::content_save_state`).
pub const Limits = struct {
    /// longest string written, in bytes before escaping (`Str`: its bytes; `TextStr`: its UTF-8)
    str_len: u32 = 0,
    /// longest name written, in bytes before escaping
    name_len: u32 = 0,
    /// a content stream nested `q` deeper than `max_q_depth`
    q_over: bool = false,

    pub const max_str_len = 32767;
    pub const max_name_len = 127;
    pub const max_q_depth = 28;
    pub const max_objects = 8388607;

    pub fn merge(l: *Limits, o: Limits) void {
        l.str_len = @max(l.str_len, o.str_len);
        l.name_len = @max(l.name_len, o.name_len);
        l.q_over = l.q_over or o.q_over;
    }
};

/// Append-only byte buffer with pdf-writer's lazy token padding. Used for object bodies (through
/// `Doc`) and content streams (`content.zig`). Object values are written in order; dictionaries
/// are `dict()` + key/value pairs + `dictEnd()`, arrays `arr()` + items + `arrEnd()`.
pub const Buf = struct {
    a: Allocator,
    list: std.ArrayList(u8) = .empty,
    /// Ref placeholders (object bodies only; content streams never hold refs).
    patches: std.ArrayList(Patch) = .empty,
    /// Padding is only considered after this offset (start of the current object).
    base: usize = 0,
    failed: bool = false,
    /// lengths of the strings and names written so far
    limits: Limits = .{},

    pub fn init(a: Allocator) Buf {
        return .{ .a = a };
    }

    pub fn bytes(b: *const Buf) []const u8 {
        return b.list.items;
    }

    /// Appends bytes verbatim (no padding).
    pub fn raw(b: *Buf, s: []const u8) void {
        b.list.appendSlice(b.a, s) catch {
            b.failed = true;
        };
    }

    pub fn byte(b: *Buf, c: u8) void {
        b.list.append(b.a, c) catch {
            b.failed = true;
        };
    }

    /// Space before a token that starts with a regular character, unless the previous byte is
    /// a delimiter (or nothing precedes it in the current object).
    pub fn sep(b: *Buf) void {
        const it = b.list.items;
        if (it.len > b.base and !isDelim(it[it.len - 1])) b.byte(' ');
    }

    pub fn int(b: *Buf, v: i64) void {
        b.sep();
        var t: [24]u8 = undefined;
        b.raw(fmtInt(&t, v));
    }

    pub fn real(b: *Buf, v: f32) void {
        b.sep();
        var t: [48]u8 = undefined;
        b.raw(fmtReal(&t, v));
    }

    pub fn boolean(b: *Buf, v: bool) void {
        b.sep();
        b.raw(if (v) "true" else "false");
    }

    pub fn nul(b: *Buf) void {
        b.sep();
        b.raw("null");
    }

    /// `/name` with `#xx` escapes for bytes outside the regular printable range.
    pub fn name(b: *Buf, n: []const u8) void {
        b.limits.name_len = @max(b.limits.name_len, @as(u32, @truncate(@min(n.len, 0xffff_ffff))));
        b.byte('/');
        for (n) |c| {
            if (isNameRegular(c)) {
                b.byte(c);
            } else {
                b.raw(&.{ '#', hex_digits[c >> 4], hex_digits[c & 15] });
            }
        }
    }

    /// Indirect reference `<n> 0 R` (renumbered at `finish`; object bodies only).
    pub fn ref(b: *Buf, r: Ref) void {
        b.sep();
        b.patches.append(b.a, .{ .pos = @intCast(b.list.items.len), .ref = r }) catch {
            b.failed = true;
        };
        b.byte('R');
    }

    /// pdf-writer `Str`: literal string for ASCII bytes, hex string otherwise.
    pub fn str(b: *Buf, s: []const u8) void {
        b.noteStr(s.len);
        for (s) |c| if (c >= 0x80) return b.hexStr(s);
        b.literal(s);
    }

    fn noteStr(b: *Buf, len: usize) void {
        b.limits.str_len = @max(b.limits.str_len, @as(u32, @truncate(@min(len, 0xffff_ffff))));
    }

    fn literal(b: *Buf, s: []const u8) void {
        b.byte('(');
        var balanced: ?bool = null;
        for (s) |c| {
            switch (c) {
                '(', ')' => {
                    if (balanced == null) balanced = c != ')' and isBalanced(s);
                    if (!balanced.?) b.byte('\\');
                    b.byte(c);
                },
                '\\' => b.raw("\\\\"),
                ' '...'\'', '*'...'[', ']'...'~' => b.byte(c),
                '\n' => b.raw("\\n"),
                '\r' => b.raw("\\r"),
                '\t' => b.raw("\\t"),
                0x08 => b.raw("\\b"),
                0x0c => b.raw("\\f"),
                else => b.raw(&.{ '\\', '0' + (c >> 6), '0' + ((c >> 3) & 7), '0' + (c & 7) }),
            }
        }
        b.byte(')');
    }

    fn isBalanced(s: []const u8) bool {
        var depth: usize = 0;
        for (s) |c| {
            if (c == '(') depth += 1;
            if (c == ')') {
                if (depth == 0) return false;
                depth -= 1;
            }
        }
        return depth == 0;
    }

    /// `<HEX>` string (upper-case digits).
    pub fn hexStr(b: *Buf, s: []const u8) void {
        b.byte('<');
        for (s) |c| b.raw(&.{ hex_digits[c >> 4], hex_digits[c & 15] });
        b.byte('>');
    }

    /// pdf-writer `TextStr` from UTF-8: a literal string when every byte is printable ASCII,
    /// otherwise `<FEFF...>` UTF-16BE (invalid UTF-8 bytes become U+FFFD).
    pub fn textStr(b: *Buf, s: []const u8) void {
        b.noteStr(s.len);
        for (s) |c| {
            if (c < 32 or c > 126) break;
        } else return b.literal(s);
        b.raw("<FEFF");
        var i: usize = 0;
        while (i < s.len) {
            // lenient UTF-8 decode: malformed sequences become U+FFFD, one byte at a time
            const c0: u32 = s[i];
            const len: usize = if (c0 < 0x80) 1 else if (c0 >= 0xC2 and c0 < 0xE0) 2 else if (c0 >= 0xE0 and c0 < 0xF0) 3 else if (c0 >= 0xF0 and c0 < 0xF5) 4 else 0;
            var cp: u32 = if (len == 1) c0 else 0xFFFD;
            var step: usize = 1;
            if (len > 1 and i + len <= s.len) {
                var v: u32 = c0 & (@as(u32, 0x7F) >> @intCast(len));
                var ok = true;
                for (s[i + 1 .. i + len]) |cc| {
                    ok = ok and cc & 0xC0 == 0x80;
                    v = (v << 6) | (cc & 0x3F);
                }
                const min: u32 = if (len == 2) 0x80 else if (len == 3) 0x800 else 0x10000;
                if (ok and v >= min and v <= 0x10FFFF and !(v >= 0xD800 and v < 0xE000)) {
                    cp = v;
                    step = len;
                }
            }
            i += step;
            if (cp >= 0x10000) {
                const c = cp - 0x10000;
                b.hex16(@intCast(0xD800 + (c >> 10)));
                b.hex16(@intCast(0xDC00 + (c & 0x3FF)));
            } else b.hex16(@intCast(cp));
        }
        b.byte('>');
    }

    fn hex16(b: *Buf, v: u16) void {
        b.raw(&.{ hex_digits[v >> 12], hex_digits[(v >> 8) & 15], hex_digits[(v >> 4) & 15], hex_digits[v & 15] });
    }

    pub fn date(b: *Buf, d: Date) void {
        b.raw("(D:");
        var t: [8]u8 = undefined;
        b.raw(dig(&t, d.year, 4));
        blk: {
            for ([_]?u8{ d.month, d.day, d.hour, d.minute, d.second }) |f| {
                b.raw(dig(&t, f orelse break :blk, 2));
            }
            const oh = d.utc_offset_hour orelse break :blk;
            if (oh == 0 and d.utc_offset_minute == 0) {
                b.byte('Z');
            } else {
                b.byte(if (oh < 0) '-' else '+');
                b.raw(dig(&t, @abs(oh), 2));
                b.byte('\'');
                b.raw(dig(&t, d.utc_offset_minute, 2));
            }
        }
        b.byte(')');
    }

    fn dig(t: *[8]u8, v: u16, w: usize) []const u8 {
        var x = v;
        var i: usize = w;
        while (i > 0) {
            i -= 1;
            t[i] = @intCast('0' + x % 10);
            x /= 10;
        }
        return t[0..w];
    }

    pub fn dict(b: *Buf) void {
        b.raw("<<");
    }
    pub fn dictEnd(b: *Buf) void {
        b.raw(">>");
    }
    pub fn arr(b: *Buf) void {
        b.byte('[');
    }
    pub fn arrEnd(b: *Buf) void {
        b.byte(']');
    }

    /// Dictionary key (a name).
    pub fn key(b: *Buf, k: []const u8) void {
        b.name(k);
    }

    pub fn reals(b: *Buf, vs: []const f32) void {
        b.arr();
        for (vs) |v| b.real(v);
        b.arrEnd();
    }

    pub fn ints(b: *Buf, vs: []const i64) void {
        b.arr();
        for (vs) |v| b.int(v);
        b.arrEnd();
    }

    pub fn refs(b: *Buf, rs: []const Ref) void {
        b.arr();
        for (rs) |r| b.ref(r);
        b.arrEnd();
    }

    /// `[x0 y0 x1 y1]`
    pub fn rect(b: *Buf, r: [4]f32) void {
        b.reals(&r);
    }

    pub fn pairName(b: *Buf, k: []const u8, v: []const u8) void {
        b.name(k);
        b.name(v);
    }
    pub fn pairInt(b: *Buf, k: []const u8, v: i64) void {
        b.name(k);
        b.int(v);
    }
    pub fn pairReal(b: *Buf, k: []const u8, v: f32) void {
        b.name(k);
        b.real(v);
    }
    pub fn pairRef(b: *Buf, k: []const u8, v: Ref) void {
        b.name(k);
        b.ref(v);
    }
    pub fn pairBool(b: *Buf, k: []const u8, v: bool) void {
        b.name(k);
        b.boolean(v);
    }
    pub fn pairStr(b: *Buf, k: []const u8, v: []const u8) void {
        b.name(k);
        b.str(v);
    }
    pub fn pairText(b: *Buf, k: []const u8, v: []const u8) void {
        b.name(k);
        b.textStr(v);
    }
    pub fn pairRect(b: *Buf, k: []const u8, v: [4]f32) void {
        b.name(k);
        b.rect(v);
    }
    pub fn pairDate(b: *Buf, k: []const u8, v: Date) void {
        b.name(k);
        b.date(v);
    }

    /// `/Filter/FlateDecode` when the stream data is Flate-encoded.
    pub fn filter(b: *Buf, e: Encoded) void {
        if (e.flate) b.pairName("Filter", "FlateDecode");
    }
};

// ---------------------------------------------------------------------------------------------
// Document
// ---------------------------------------------------------------------------------------------

pub const Version = enum(u8) {
    v1_4 = 14,
    v1_5 = 15,
    v1_6 = 16,
    v1_7 = 17,
    v2_0 = 20,

    pub fn atLeast(v: Version, o: Version) bool {
        return @backingInt(v) >= @backingInt(o);
    }
};

/// krilla's chunk kinds, in output (= numbering) order. Objects of one category keep the order
/// in which they were written. Non-stream kinds first, then embedded PDFs, then stream kinds.
pub const Category = enum(u8) {
    page_tree,
    outline,
    page_label_tree,
    destination_profiles,
    struct_tree_root,
    /// Packed into object streams on PDF >= 1.5 (when there are at least two and none is a stream).
    struct_elements,
    page_labels,
    annotations,
    color_spaces,
    destinations,
    ext_g_states,
    resource_dictionaries,
    masks,
    fonts,
    shading_functions,
    patterns,
    pages,
    embedded_files,
    embedded_pdfs,
    font_streams,
    shading_function_streams,
    pattern_streams,
    /// Page content streams.
    content_streams,
    embedded_file_streams,
    icc_profiles,
    x_objects,
    images,
};

/// Stream data plus whether it is Flate-encoded (`Buf.filter` writes the matching /Filter).
pub const Encoded = struct {
    data: []const u8,
    flate: bool = false,
};

/// How `Doc.encode` treats stream data (krilla `FilterStreamBuilder`).
pub const Compress = enum {
    /// Content streams: Flate when `Doc.compress` is on (`new_from_content_stream`).
    content,
    /// Always Flate (`new_from_binary_data`: fonts, ICC profiles, image data, ...).
    flate,
    /// Flate only when it saves more than 25 % (`new_auto_compressed`).
    auto,
    /// Uncompressed (`new_from_uncompressed`; XMP metadata).
    none,
};

const Obj = struct {
    ref: Ref,
    cat: Category,
    start: u32,
    end: u32,
    plo: u32,
    phi: u32,
    data: ?[]const u8,
};

pub const Options = struct {
    version: Version = .v1_7,
    /// Compress content streams (krilla `compress_content_streams`) and object streams. Turn off
    /// for readable output in tests / debugging.
    compress: bool = true,
    /// Content streams (operators and numbers, the bulk of what a document compresses): greedy
    /// matching (`text` = `fast`'s parse, `default`'s zlib header) takes 27 % less time than lazy
    /// `default` (half on outline-heavy text) for 2 % more bytes, about what krilla's miniz level 6
    /// gives up against zlib 6. Other streams (font programs, images, object and xref streams:
    /// binary, compressed once) use `default`.
    level: deflate.Level = .text,
};

/// Document Info dictionary (written in this order; krilla `serialize_document_info`).
/// `date` is written as both /ModDate and /CreationDate.
pub const Info = struct {
    producer: ?[]const u8 = null,
    title: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    keywords: ?[]const u8 = null,
    author: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    date: ?Date = null,
};

/// Produces the XMP packet once the file ids are known (krilla writes the metadata stream after
/// the Info dictionary and before the catalog). Return the packet bytes (allocated from `a`).
pub const XmpFn = *const fn (ctx: ?*anyopaque, a: Allocator, instance_id: []const u8, document_id: []const u8) error{OutOfMemory}![]const u8;

pub const FinishOptions = struct {
    /// null: no Info dictionary (PDF/A-4 etc.). An Info with no entries is not written either.
    info: ?Info = null,
    xmp: ?XmpFn = null,
    xmp_ctx: ?*anyopaque = null,
    /// Explicit /ID document part (krilla derives it from metadata; see `StableHasher`);
    /// default: the instance id.
    document_id: ?[]const u8 = null,
    /// Bytes 10..14 of the header (`AAAA` for ASCII-compatible output).
    binary_marker: [4]u8 = .{ 0x80, 0x80, 0x80, 0x80 },
    /// Pack struct elements into object streams (PDF >= 1.5).
    object_streams: bool = true,
};

/// One PDF document under construction. Objects are written one at a time (no nesting):
/// `beginDict`/`beginStream`/`begin` ... `endDict`/`end`.
pub const Doc = struct {
    a: Allocator,
    version: Version,
    compress: bool,
    level: deflate.Level,
    b: Buf,
    objs: std.ArrayList(Obj) = .empty,
    catalog_parts: std.ArrayList(Obj) = .empty,
    page_refs: std.ArrayList(Ref) = .empty,
    next_ref: Ref = 1,
    page_tree: Ref = 0,
    cur: ?Obj = null,
    cur_catalog: bool = false,
    cache: std.AutoHashMapUnmanaged(u64, Ref) = .empty,
    /// Limits of the objects written (krilla: the limits of the final `Pdf` plus those of every
    /// content stream, see `noteLimits`). Complete after `finish`: structure elements count
    /// only when they were not packed into object streams (pdf-writer never sees the strings
    /// of a packed chunk).
    limits: Limits = .{},
    limits_struct: Limits = .{},
    /// Working memory of the compressor (its tables, about 450 KiB a stream), rewound after each
    /// stream; only the compressed bytes go to `a`. Null: everything from `a`.
    scratch: ?*Bump = null,

    pub fn init(a: Allocator, o: Options) Doc {
        var d: Doc = .{ .a = a, .version = o.version, .compress = o.compress, .level = o.level, .b = .init(a) };
        d.page_tree = d.alloc();
        return d;
    }

    /// New provisional reference. Every allocated ref must be written before `finish` if it is
    /// referenced anywhere (otherwise `error.DanglingRef`).
    pub fn alloc(d: *Doc) Ref {
        const r = d.next_ref;
        d.next_ref += 1;
        return r;
    }

    /// The /Pages ref (for each page's /Parent).
    pub fn pageTreeRef(d: *const Doc) Ref {
        return d.page_tree;
    }

    /// Allocates a page ref and appends it to the page tree's /Kids. Write the page object with
    /// `beginPage` (category `.pages`) before `finish`.
    pub fn addPage(d: *Doc) Ref {
        const r = d.alloc();
        d.page_refs.append(d.a, r) catch {
            d.b.failed = true;
        };
        return r;
    }

    pub fn pageCount(d: *const Doc) usize {
        return d.page_refs.items.len;
    }

    /// Starts indirect object `r` in category `cat`; write its value into the returned buffer,
    /// then call `end`.
    pub fn begin(d: *Doc, r: Ref, cat: Category) *Buf {
        if (d.cur != null) d.b.failed = true;
        const pos: u32 = @intCast(d.b.list.items.len);
        d.b.base = pos;
        d.cur = .{ .ref = r, .cat = cat, .start = pos, .end = pos, .plo = @intCast(d.b.patches.items.len), .phi = 0, .data = null };
        d.cur_catalog = false;
        d.limits.merge(d.b.limits);
        d.b.limits = .{};
        return &d.b;
    }

    /// krilla `register_limits` for a content stream built outside the document buffer.
    pub fn noteLimits(d: *Doc, l: Limits) void {
        d.limits.str_len = @max(d.limits.str_len, l.str_len);
        d.limits.name_len = @max(d.limits.name_len, l.name_len);
    }

    /// The number of indirect objects allocated exceeds what PDF/A-2 and A-3 allow.
    pub fn tooManyObjects(d: *const Doc) bool {
        return d.next_ref > Limits.max_objects;
    }

    pub fn end(d: *Doc) void {
        var o = d.cur orelse {
            d.b.failed = true;
            return;
        };
        o.end = @intCast(d.b.list.items.len);
        o.phi = @intCast(d.b.patches.items.len);
        if (o.cat == .struct_elements and !d.cur_catalog) d.limits_struct.merge(d.b.limits) else d.limits.merge(d.b.limits);
        d.b.limits = .{};
        const list = if (d.cur_catalog) &d.catalog_parts else &d.objs;
        list.append(d.a, o) catch {
            d.b.failed = true;
        };
        d.cur = null;
        d.cur_catalog = false;
    }

    /// `begin` + `<<`; finish with `endDict`.
    pub fn beginDict(d: *Doc, r: Ref, cat: Category) *Buf {
        const b = d.begin(r, cat);
        b.dict();
        return b;
    }

    /// `>>` + `end`.
    pub fn endDict(d: *Doc) void {
        d.b.dictEnd();
        d.end();
    }

    /// Stream object: writes `<</Length n`; add entries (`Buf.filter(e)` for /Filter) and call
    /// `endDict`. `e.data` is referenced until `finish`.
    pub fn beginStream(d: *Doc, r: Ref, cat: Category, e: Encoded) *Buf {
        const b = d.beginDict(r, cat);
        b.pairInt("Length", @intCast(e.data.len));
        if (d.cur) |*o| o.data = e.data;
        return b;
    }

    /// Extra catalog entries (`/Key value` pairs; refs allowed), written after /Pages and
    /// /Metadata in call order. Finish with `endCatalog`. May be called several times.
    pub fn beginCatalog(d: *Doc) *Buf {
        const b = d.begin(0, .page_tree);
        d.cur_catalog = true;
        // keys start with '/', so no padding questions arise
        return b;
    }

    pub fn endCatalog(d: *Doc) void {
        d.end();
    }

    /// Encodes stream data according to `mode` (see `Compress`). On allocation failure the data
    /// is returned uncompressed and the error surfaces at `finish`. Content (`.content`) is
    /// always in `a` afterwards, compressed or copied: it may come from a page's working memory
    /// (emit_surface.zig `Ctx.work`).
    pub fn encode(d: *Doc, data: []const u8, mode: Compress) Encoded {
        const want = switch (mode) {
            .content => d.compress,
            .flate, .auto => true,
            .none => false,
        };
        if (!want and mode == .content) return .{ .data = d.a.dupe(u8, data) catch blk: {
            d.b.failed = true;
            break :blk data;
        } };
        if (!want or (data.len == 0 and mode == .auto)) return .{ .data = data };
        const z = d.compressed(data, if (mode == .content) d.level else .default) catch {
            d.b.failed = true;
            return .{ .data = data };
        };
        if (mode == .auto and 100 * z.len / data.len > 75) return .{ .data = data };
        return .{ .data = z, .flate = true };
    }

    /// `data` zlib-compressed into `a` (the compressor's tables in `scratch` when there is one).
    fn compressed(d: *Doc, data: []const u8, level: deflate.Level) error{OutOfMemory}![]u8 {
        const s = d.scratch orelse return deflate.compressEx(d.a, data, .{ .level = level, .size_hint = data.len });
        defer s.reset();
        return d.a.dupe(u8, try deflate.compressEx(s.allocator(), data, .{ .level = level, .size_hint = data.len }));
    }

    /// Dedup cache for higher layers (krilla `cached_mappings`): content hash -> object ref.
    pub fn cacheGet(d: *Doc, h: u64) ?Ref {
        return d.cache.get(h);
    }

    pub fn cachePut(d: *Doc, h: u64, r: Ref) void {
        d.cache.put(d.a, h, r) catch {
            d.b.failed = true;
        };
    }

    // -- object helpers ------------------------------------------------------------------------

    /// Page content stream (`/Length/Filter`), encoded with `.content`, category `.content_streams`.
    pub fn contentStream(d: *Doc, r: Ref, content: []const u8) void {
        d.contentStreamEncoded(r, d.encode(content, .content));
    }

    /// `contentStream` of content already encoded with `encode(.., .content)`.
    pub fn contentStreamEncoded(d: *Doc, r: Ref, e: Encoded) void {
        const b = d.beginStream(r, .content_streams, e);
        b.filter(e);
        d.endDict();
    }

    /// Page object (category `.pages`), krilla key order. The dictionary is left open for extra
    /// entries; close it with `endDict`.
    pub fn beginPage(d: *Doc, r: Ref, p: Page) *Buf {
        const b = d.beginDict(r, .pages);
        b.pairName("Type", "Page");
        resourcesEntry(b, p.resources);
        b.pairRect("MediaBox", p.media_box);
        if (p.crop_box) |v| b.pairRect("CropBox", v);
        if (p.bleed_box) |v| b.pairRect("BleedBox", v);
        if (p.trim_box) |v| b.pairRect("TrimBox", v);
        if (p.art_box) |v| b.pairRect("ArtBox", v);
        if (p.struct_parents) |v| b.pairInt("StructParents", v);
        if (p.tabs) |v| b.pairName("Tabs", v);
        b.pairRef("Parent", d.page_tree);
        b.pairRef("Contents", p.contents);
        if (p.annots.len > 0) {
            b.key("Annots");
            b.refs(p.annots);
        }
        return b;
    }

    /// Form XObject (category `.x_objects`): `/Length/Type/XObject/Subtype/Form/Filter/Resources
    /// /BBox[/Matrix][/Group]` (krilla `XObject::serialize`). `content` is encoded with `.content`.
    pub fn formXObject(d: *Doc, r: Ref, content: []const u8, f: Form) void {
        const e = d.encode(content, .content);
        const b = d.beginStream(r, .x_objects, e);
        b.pairName("Type", "XObject");
        b.pairName("Subtype", "Form");
        b.filter(e);
        resourcesEntry(b, f.resources);
        b.pairRect("BBox", f.bbox);
        if (f.matrix) |m| {
            b.key("Matrix");
            b.reals(&m);
        }
        if (f.group) |g| {
            b.key("Group");
            b.dict();
            b.pairName("Type", "Group");
            b.pairName("S", "Transparency");
            if (g.isolated) b.pairBool("I", true);
            if (g.knockout) b.pairBool("K", true);
            if (g.cs_ref) |cr| b.pairRef("CS", cr) else if (g.cs) |cs| b.pairName("CS", cs);
            b.dictEnd();
        }
        d.endDict();
    }

    /// ExtGState dictionary (category `.ext_g_states`): `/Type/ExtGState/ca/CA/BM/SMask`.
    pub fn extGState(d: *Doc, r: Ref, g: ExtGState) void {
        const b = d.beginDict(r, .ext_g_states);
        b.pairName("Type", "ExtGState");
        if (g.fill_alpha) |v| b.pairReal("ca", v);
        if (g.stroke_alpha) |v| b.pairReal("CA", v);
        if (g.blend_mode) |v| b.pairName("BM", v);
        if (g.smask) |v| b.pairRef("SMask", v);
        if (g.smask_none) b.pairName("SMask", "None");
        d.endDict();
    }

    /// Soft-mask dictionary (category `.masks`): `/Type/Mask/S/<subtype>/G <group>[/BC[..]]`.
    pub fn softMask(d: *Doc, r: Ref, subtype: []const u8, group: Ref, backdrop: ?[]const f32) void {
        const b = d.beginDict(r, .masks);
        b.pairName("Type", "Mask");
        b.pairName("S", subtype);
        b.pairRef("G", group);
        if (backdrop) |bc| {
            b.key("BC");
            b.reals(bc);
        }
        d.endDict();
    }

    // -- finish --------------------------------------------------------------------------------

    /// Writes the whole file into `out` (appending). The Doc must not be used afterwards.
    pub fn finish(d: *Doc, out: *std.ArrayList(u8), o: FinishOptions) Error!void {
        if (d.cur != null) return error.OpenObject;
        {
            const b = d.beginDict(d.page_tree, .page_tree);
            b.pairName("Type", "Pages");
            b.pairInt("Count", @intCast(d.page_refs.items.len));
            b.key("Kids");
            b.refs(d.page_refs.items);
            d.endDict();
        }
        if (d.b.failed) return error.OutOfMemory;
        const a = d.a;

        // renumber in category order
        const map = try a.alloc(u32, d.next_ref);
        @memset(map, 0);
        const order = try a.alloc(u32, d.objs.items.len);
        var n_struct: usize = 0;
        var struct_streams = false;
        var num: u32 = 1;
        {
            var oi: usize = 0;
            var cat: u8 = 0;
            while (cat <= @backingInt(Category.images)) : (cat += 1) {
                for (d.objs.items, 0..) |ob, i| {
                    if (@backingInt(ob.cat) != cat) continue;
                    if (ob.ref == 0 or ob.ref >= d.next_ref or map[ob.ref] != 0) return error.DuplicateObject;
                    map[ob.ref] = num;
                    num += 1;
                    order[oi] = @intCast(i);
                    oi += 1;
                    if (ob.cat == .struct_elements) {
                        n_struct += 1;
                        if (ob.data != null) struct_streams = true;
                    }
                }
            }
        }
        const pack = o.object_streams and d.version.atLeast(.v1_5) and n_struct >= 2 and !struct_streams;
        if (!pack) d.limits.merge(d.limits_struct);

        // rows[n]: byte offset, or (stream number << 16 | index) when packed
        const Row = struct { v: u64 = 0, packed_: bool = false };
        const n_streams: u32 = if (pack) @intCast((n_struct + 0xFFFF) / 0x10000) else 0;
        const rows = try a.alloc(Row, num + n_streams + 4);
        @memset(rows, .{});

        // (the file at once: a list grown as it is written holds an old and a new copy of a long
        // document's file at its last growth; its objects are about their bodies and streams with
        // a header, a trailer and an xref row each)
        {
            var size: usize = out.items.len + 65536;
            // (structure elements packed into compressed object streams: their compressed size
            // grows the list)
            for (d.objs.items) |ob| {
                if (pack and ob.cat == .struct_elements) continue;
                size += 48 + (ob.end - ob.start) + (if (ob.data) |x| x.len else 0);
            }
            try out.ensureTotalCapacity(a, size);
        }
        var w: Out = .{ .a = a, .o = out };
        const start = out.items.len;
        try w.raw("%PDF-");
        const ver = @backingInt(d.version);
        try w.raw(&.{ '0' + ver / 10, '.', '0' + ver % 10, '\n', '%' });
        try w.raw(&o.binary_marker);
        try w.raw("\n\n");

        if (pack) {
            var idx: usize = 0;
            var first_obj: usize = 0;
            while (idx < n_struct) {
                const stream_num = num;
                num += 1;
                // (the header gives each body's offset: their lengths are known without writing
                // them, so a compressed stream takes the header and then the bodies one by one
                // instead of a copy of them all)
                var hdr: std.ArrayList(u8) = .empty;
                var sel: std.ArrayList(u32) = .empty;
                var body_len: usize = 0;
                var count: usize = 0;
                var seen: usize = 0;
                for (order) |oi| {
                    const ob = d.objs.items[oi];
                    if (ob.cat != .struct_elements) continue;
                    if (seen < first_obj) {
                        seen += 1;
                        continue;
                    }
                    if (count == 0x10000) break;
                    const n = map[ob.ref];
                    var t: [24]u8 = undefined;
                    try hdr.appendSlice(a, fmtInt(&t, n));
                    try hdr.append(a, ' ');
                    try hdr.appendSlice(a, fmtInt(&t, @intCast(body_len)));
                    try hdr.append(a, ' ');
                    try sel.append(a, oi);
                    body_len += try d.bodyLen(ob, map) + 1;
                    rows[n] = .{ .v = (@as(u64, stream_num) << 16) | @as(u64, count), .packed_ = true };
                    count += 1;
                    seen += 1;
                }
                first_obj += count;
                idx += count;
                const first = hdr.items.len;
                const e = try d.encodeObjStm(hdr.items, sel.items, map, first + body_len);
                if (d.b.failed) return error.OutOfMemory;
                rows[stream_num].v = out.items.len - start;
                var hb = Buf.init(a);
                hb.dict();
                hb.pairInt("Length", @intCast(e.data.len));
                hb.pairName("Type", "ObjStm");
                hb.pairInt("N", @intCast(count));
                hb.pairInt("First", @intCast(first));
                hb.filter(e);
                hb.dictEnd();
                if (hb.failed) return error.OutOfMemory;
                try w.objHead(stream_num);
                try w.raw(hb.bytes());
                try w.streamTail(e.data);
            }
        }

        for (order) |oi| {
            const ob = d.objs.items[oi];
            if (pack and ob.cat == .struct_elements) continue;
            const n = map[ob.ref];
            rows[n].v = out.items.len - start;
            try w.objHead(n);
            try d.emitBody(ob, map, &w);
            if (ob.data) |data| try w.streamTail(data) else try w.raw("\nendobj\n");
        }

        var tb = Buf.init(a);
        // Info
        var info_num: u32 = 0;
        if (o.info) |info| {
            inline for (.{ .{ "Producer", "producer" }, .{ "Title", "title" }, .{ "Subject", "subject" }, .{ "Keywords", "keywords" }, .{ "Author", "author" }, .{ "Creator", "creator" } }) |kv| {
                if (@field(info, kv[1])) |v| tb.pairText(kv[0], v);
            }
            if (info.date) |dt| {
                tb.pairDate("ModDate", dt);
                tb.pairDate("CreationDate", dt);
            }
            d.limits.merge(tb.limits);
            if (tb.list.items.len > 0) {
                if (tb.failed) return error.OutOfMemory;
                info_num = num;
                num += 1;
                rows[info_num].v = out.items.len - start;
                try w.objHead(info_num);
                try w.raw("<<");
                try w.raw(tb.bytes());
                try w.raw(">>\nendobj\n");
            }
        }

        // file ids
        var inst_buf: [24]u8 = undefined;
        const instance_id = stableHashBase64(&inst_buf, out.items[start..]);
        const document_id = o.document_id orelse instance_id;

        // XMP metadata
        var meta_num: u32 = 0;
        if (o.xmp) |xf| {
            const xmp = try xf(o.xmp_ctx, a, instance_id, document_id);
            meta_num = num;
            num += 1;
            rows[meta_num].v = out.items.len - start;
            try w.objHead(meta_num);
            tb.list.clearRetainingCapacity();
            tb.base = 0;
            tb.dict();
            tb.pairInt("Length", @intCast(xmp.len));
            tb.pairName("Type", "Metadata");
            tb.pairName("Subtype", "XML");
            tb.dictEnd();
            if (tb.failed) return error.OutOfMemory;
            try w.raw(tb.bytes());
            try w.streamTail(xmp);
        }

        // catalog
        const cat_num = num;
        num += 1;
        rows[cat_num].v = out.items.len - start;
        try w.objHead(cat_num);
        try w.raw("<</Type/Catalog/Pages ");
        try w.int(map[d.page_tree]);
        try w.raw(" 0 R");
        if (meta_num != 0) {
            try w.raw("/Metadata ");
            try w.int(meta_num);
            try w.raw(" 0 R");
        }
        for (d.catalog_parts.items) |part| try d.emitBody(part, map, &w);
        try w.raw(">>\nendobj\n");

        // trailer entries: /Size /Root /Info /ID
        const size: u32 = if (d.version.atLeast(.v1_5)) num + 1 else num;
        tb.list.clearRetainingCapacity();
        tb.base = 0;
        tb.pairInt("Size", size);
        tb.name("Root");
        tb.int(cat_num);
        tb.raw(" 0 R");
        if (info_num != 0) {
            tb.name("Info");
            tb.int(info_num);
            tb.raw(" 0 R");
        }
        tb.key("ID");
        tb.arr();
        tb.str(document_id);
        tb.str(instance_id);
        tb.arrEnd();
        if (tb.failed) return error.OutOfMemory;

        const xref_off = out.items.len - start;
        if (d.version.atLeast(.v1_5)) {
            const xref_num = num;
            rows[xref_num].v = xref_off;
            var width: usize = 0;
            var x = xref_off;
            while (x > 0) : (x >>= 8) width += 1;
            const row_len = 3 + width;
            const data = try a.alloc(u8, row_len * size);
            for (0..size) |i| {
                const row = data[i * row_len ..][0..row_len];
                var typ: u8 = 1;
                var f2: u64 = rows[i].v;
                var f3: u16 = 0;
                if (i == 0) {
                    typ = 0;
                    f2 = 0;
                    f3 = 0xFFFF;
                } else if (rows[i].packed_) {
                    typ = 2;
                    f2 = rows[i].v >> 16;
                    f3 = @truncate(rows[i].v);
                }
                row[0] = typ;
                var k: usize = width;
                while (k > 0) : (k -= 1) {
                    row[k] = @truncate(f2);
                    f2 >>= 8;
                }
                row[1 + width] = @intCast(f3 >> 8);
                row[2 + width] = @truncate(f3);
            }
            const z = deflate.compressEx(a, data, .{ .level = .default, .size_hint = data.len }) catch return error.OutOfMemory;
            try w.objHead(xref_num);
            try w.raw("<</Length ");
            try w.int(z.len);
            try w.raw("/Type/XRef/Filter/FlateDecode");
            try w.raw(tb.bytes());
            try w.raw("/W[1 ");
            try w.int(width);
            try w.raw(" 2]>>");
            try w.streamTail(z);
        } else {
            try w.raw("xref\n0 ");
            try w.int(size);
            try w.raw("\n0000000000 65535 f\r\n");
            for (1..size) |i| {
                var t: [10]u8 = undefined;
                var v = rows[i].v;
                var k: usize = 10;
                while (k > 0) {
                    k -= 1;
                    t[k] = @intCast('0' + v % 10);
                    v /= 10;
                }
                try w.raw(&t);
                try w.raw(" 00000 n\r\n");
            }
            try w.raw("trailer\n<<");
            try w.raw(tb.bytes());
            try w.raw(">>\n");
        }
        try w.raw("startxref\n");
        try w.int(xref_off);
        try w.raw("\n%%EOF");
    }

    /// The length `emitBody` writes for `ob`.
    fn bodyLen(d: *Doc, ob: Obj, map: []const u32) Error!usize {
        var len: usize = ob.end - ob.start;
        for (d.b.patches.items[ob.plo..ob.phi]) |p| {
            const n = if (p.ref < map.len) map[p.ref] else 0;
            if (n == 0) return error.DanglingRef;
            var t: [24]u8 = undefined;
            // (the one-byte placeholder becomes "n 0 R")
            len = len - 1 + fmtInt(&t, n).len + 4;
        }
        return len;
    }

    /// An object stream's data (`hdr`, then the bodies of objects `sel`, each followed by a
    /// newline; `total` bytes in all) encoded as `encode(.., .content)` would encode it, the bodies
    /// streamed into the compressor rather than gathered first.
    fn encodeObjStm(d: *Doc, hdr: []const u8, sel: []const u32, map: []const u32, total: usize) Error!Encoded {
        const a = d.a;
        var body: std.ArrayList(u8) = .empty;
        if (!d.compress) {
            var all: std.ArrayList(u8) = .empty;
            try all.ensureTotalCapacityPrecise(a, total);
            all.appendSliceAssumeCapacity(hdr);
            var bw: Out = .{ .a = a, .o = &all };
            for (sel) |oi| {
                try d.emitBody(d.objs.items[oi], map, &bw);
                try all.append(a, '\n');
            }
            return d.encode(all.items, .content);
        }
        // (`compressed`: the compressor's tables in `scratch` when there is one, the output then
        // copied into `a`)
        const sa = if (d.scratch) |s| s.allocator() else a;
        defer if (d.scratch) |s| s.reset();
        var s = try deflate.Stream.init(sa, .{ .level = d.level, .size_hint = total }, total / 2 + 64, 0, true);
        errdefer s.deinit();
        try s.write(hdr);
        for (sel) |oi| {
            // (in `a`, not after the compressor's output in `sa`, which then grows in place)
            body.clearRetainingCapacity();
            var bw: Out = .{ .a = a, .o = &body };
            try d.emitBody(d.objs.items[oi], map, &bw);
            try body.append(a, '\n');
            try s.write(body.items);
        }
        try s.finish();
        const z = try s.takeOutput();
        return .{ .data = if (d.scratch != null) try a.dupe(u8, z) else z, .flate = true };
    }

    fn emitBody(d: *Doc, ob: Obj, map: []const u32, w: *Out) Error!void {
        const src = d.b.list.items;
        var pos: usize = ob.start;
        for (d.b.patches.items[ob.plo..ob.phi]) |p| {
            try w.raw(src[pos..p.pos]);
            const n = if (p.ref < map.len) map[p.ref] else 0;
            if (n == 0) return error.DanglingRef;
            try w.int(n);
            try w.raw(" 0 R");
            pos = p.pos + 1;
        }
        try w.raw(src[pos..ob.end]);
    }
};

const Out = struct {
    a: Allocator,
    o: *std.ArrayList(u8),

    fn raw(w: *Out, s: []const u8) error{OutOfMemory}!void {
        try w.o.appendSlice(w.a, s);
    }
    fn int(w: *Out, v: u64) error{OutOfMemory}!void {
        var t: [24]u8 = undefined;
        try w.raw(fmtInt(&t, @intCast(v)));
    }
    fn objHead(w: *Out, n: u32) error{OutOfMemory}!void {
        try w.int(n);
        try w.raw(" 0 obj\n");
    }
    fn streamTail(w: *Out, data: []const u8) error{OutOfMemory}!void {
        try w.raw("\nstream\n");
        try w.raw(data);
        try w.raw("\nendstream\nendobj\n");
    }
};

fn resourcesEntry(b: *Buf, r: ?Ref) void {
    if (r) |v| b.pairRef("Resources", v) else b.raw("/Resources<<>>");
}

/// Page dictionary fields (`Doc.beginPage`). `resources` null writes an empty direct dictionary.
pub const Page = struct {
    resources: ?Ref,
    media_box: [4]f32,
    crop_box: ?[4]f32 = null,
    bleed_box: ?[4]f32 = null,
    trim_box: ?[4]f32 = null,
    art_box: ?[4]f32 = null,
    struct_parents: ?i32 = null,
    /// e.g. "S" (structure order)
    tabs: ?[]const u8 = null,
    contents: Ref,
    annots: []const Ref = &.{},
};

/// Transparency group attributes of a Form XObject.
pub const Group = struct {
    isolated: bool = false,
    knockout: bool = false,
    /// Device colour space name (krilla always writes one: "DeviceRGB") ...
    cs: ?[]const u8 = "DeviceRGB",
    /// ... or an ICC colour space object.
    cs_ref: ?Ref = null,
};

pub const Form = struct {
    resources: ?Ref,
    bbox: [4]f32,
    matrix: ?[6]f32 = null,
    group: ?Group = null,
};

pub const ExtGState = struct {
    /// /ca (non-stroking alpha)
    fill_alpha: ?f32 = null,
    /// /CA (stroking alpha)
    stroke_alpha: ?f32 = null,
    /// /BM blend mode name, e.g. "Multiply"
    blend_mode: ?[]const u8 = null,
    smask: ?Ref = null,
    smask_none: bool = false,
};

// ---------------------------------------------------------------------------------------------
// Resource dictionaries
// ---------------------------------------------------------------------------------------------

/// Resource kinds in krilla's dictionary order (Properties is not used by krilla; it comes last).
pub const ResKind = enum(u3) { color_space, ext_g_state, pattern, x_object, shading, font, properties };

const res_keys = [_][]const u8{ "ColorSpace", "ExtGState", "Pattern", "XObject", "Shading", "Font", "Properties" };
const res_prefix = [_]u8{ 'c', 'g', 'p', 'x', 's', 'f', 'm' };

/// A resource name such as `g0` / `x12` (prefix + per-kind index, krilla `ResourceMapper`).
pub const ResName = struct {
    buf: [12]u8 = undefined,
    len: u8 = 0,

    pub fn slice(n: *const ResName) []const u8 {
        return n.buf[0..n.len];
    }
};

/// Per-page / per-XObject resource dictionary builder: hands out stable names, deduplicated by
/// object ref, numbered per kind in first-use order.
pub const Resources = struct {
    a: Allocator,
    lists: [7]std.ArrayList(Ref) = @splat(.empty),
    failed: bool = false,

    pub fn init(a: Allocator) Resources {
        return .{ .a = a };
    }

    pub fn add(r: *Resources, kind: ResKind, ref: Ref) ResName {
        const l = &r.lists[@backingInt(kind)];
        const idx = for (l.items, 0..) |x, i| {
            if (x == ref) break i;
        } else blk: {
            l.append(r.a, ref) catch {
                r.failed = true;
            };
            break :blk l.items.len -| 1;
        };
        return nameOf(kind, idx);
    }

    pub fn nameOf(kind: ResKind, idx: usize) ResName {
        var n: ResName = .{};
        n.buf[0] = res_prefix[@backingInt(kind)];
        n.len = @intCast(1 + fmtU64(n.buf[1..], idx));
        return n;
    }

    /// A copy whose lists live in `a`.
    pub fn dupe(r: *const Resources, a: Allocator) Allocator.Error!Resources {
        var c: Resources = .{ .a = a, .failed = r.failed };
        for (r.lists, &c.lists) |l, *cl| cl.* = .fromOwnedSlice(try a.dupe(Ref, l.items));
        return c;
    }

    pub fn isEmpty(r: *const Resources) bool {
        for (r.lists) |l| if (l.items.len > 0) return false;
        return true;
    }

    /// Writes the dictionary as an object in `.resource_dictionaries` and returns its ref, or
    /// null when there is nothing to write (PDF 2.0 without entries; callers then write an empty
    /// direct `/Resources<<>>`, which `Page`/`Form` do for a null ref). Before PDF 2.0 krilla
    /// always writes `/ProcSet[/PDF/Text/ImageC/ImageB]`.
    pub fn write(r: *const Resources, d: *Doc) ?Ref {
        if (r.failed) d.b.failed = true;
        const proc = !d.version.atLeast(.v2_0);
        if (!proc and r.isEmpty()) return null;
        const ref = d.alloc();
        const b = d.beginDict(ref, .resource_dictionaries);
        if (proc) b.raw("/ProcSet[/PDF/Text/ImageC/ImageB]");
        for (r.lists, 0..) |l, k| {
            if (l.items.len == 0) continue;
            b.key(res_keys[k]);
            b.dict();
            for (l.items, 0..) |x, i| {
                const nm = nameOf(@fromBackingInt(@intCast(k)), i);
                b.name(nm.slice());
                b.ref(x);
            }
            b.dictEnd();
        }
        d.endDict();
        return ref;
    }
};

// ---------------------------------------------------------------------------------------------
// Stable hashes (krilla `stable_hash128` / `stable_hash_base64`)
// ---------------------------------------------------------------------------------------------

/// SipHash-1-3 (128-bit, zero key) fed like Rust's `Hash` with krilla's `StableHasher` (usize
/// as u64). Compose krilla's document-id inputs with `bytesSlice` (`&[u8]`), `str` (`&str`) and
/// `u64` (lengths, Option/enum discriminants).
pub const StableHasher = struct {
    s: std.crypto.auth.siphash.SipHash128(1, 3),

    pub fn init() StableHasher {
        return .{ .s = .init(&@splat(0)) };
    }
    pub fn raw(h: *StableHasher, b: []const u8) void {
        h.s.update(b);
    }
    pub fn u64_(h: *StableHasher, v: u64) void {
        var t: [8]u8 = undefined;
        std.mem.writeInt(u64, &t, v, .little);
        h.s.update(&t);
    }
    /// `<[u8] as Hash>`: length prefix + bytes.
    pub fn bytesSlice(h: *StableHasher, b: []const u8) void {
        h.u64_(b.len);
        h.s.update(b);
    }
    /// `<str as Hash>`: bytes + 0xFF.
    pub fn str(h: *StableHasher, b: []const u8) void {
        h.s.update(b);
        h.s.update(&.{0xFF});
    }
    /// base64(big-endian u128) into `out`.
    pub fn finalBase64(h: *StableHasher, out: *[24]u8) []const u8 {
        var be: [16]u8 = undefined;
        std.mem.writeInt(u128, &be, h.s.finalInt(), .big);
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        var i: usize = 0;
        var o: usize = 0;
        while (i < 16) : (i += 3) {
            const b0: u32 = be[i];
            const b1: u32 = if (i + 1 < 16) be[i + 1] else 0;
            const b2: u32 = if (i + 2 < 16) be[i + 2] else 0;
            const x = (b0 << 16) | (b1 << 8) | b2;
            out[o] = alphabet[x >> 18];
            out[o + 1] = alphabet[(x >> 12) & 63];
            out[o + 2] = if (i + 1 < 16) alphabet[(x >> 6) & 63] else '=';
            out[o + 3] = if (i + 2 < 16) alphabet[x & 63] else '=';
            o += 4;
        }
        return out[0..24];
    }
};

/// krilla `stable_hash_base64(bytes)` (the instance id: hash of the file written so far).
pub fn stableHashBase64(out: *[24]u8, bytes: []const u8) []const u8 {
    var h = StableHasher.init();
    h.bytesSlice(bytes);
    return h.finalBase64(out);
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

fn expectReal(v: f32, s: []const u8) !void {
    var t: [48]u8 = undefined;
    try testing.expectEqualStrings(s, fmtReal(&t, v));
}

test "real formatting matches pdf-writer" {
    try expectReal(0, "0");
    try expectReal(-0.0, "0");
    try expectReal(180, "180");
    try expectReal(-150, "-150");
    try expectReal(0.75, "0.75");
    try expectReal(-0.75, "-0.75");
    try expectReal(0.1333, "0.1333");
    try expectReal(245.37566, "245.37566");
    try expectReal(105.375656, "105.375656");
    try expectReal(24.939999, "24.939999");
    try expectReal(595.27563, "595.27563");
    try expectReal(0.2509804, "0.2509804");
    try expectReal(144.2, "144.2");
    try expectReal(0.001, "0.001");
    try expectReal(0.0000015, "0.0000015");
    try expectReal(1.0e10, "10000000000.0");
    try expectReal(std.math.nan(f32), "0");
}

test "real formatting: the per-thread cache returns what the formatter writes" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var a: [48]u8 = undefined;
    var b: [48]u8 = undefined;
    for (0..20000) |i| {
        // (a small pool of values so most lookups hit, colliding slots included)
        const v: f32 = if (i % 3 == 0) @bitCast(rnd.int(u32)) else @as(f32, @floatFromInt(rnd.uintLessThan(u32, 5000))) / 64.0 - 30.0;
        try testing.expectEqualStrings(fmtRealUncached(&b, v), fmtReal(&a, v));
        try testing.expectEqualStrings(fmtRealUncached(&b, v), fmtReal(&a, v));
    }
    var c: [24]u8 = undefined;
    for ([_]u64{ 0, 9, 10, 99, 100, 101, 4294967295, 4294967296, 18446744073709551615 }) |v| {
        var d: [24]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&d, "{d}", .{v}), c[0..fmtU64(&c, v)]);
    }
}

test "names, strings, text strings, dates" {
    var b = Buf.init(testing.allocator);
    defer b.list.deinit(testing.allocator);
    b.name("A B#/(x)");
    b.str("a(b)c");
    b.str("x)y(");
    b.str(&.{ 0, 1, 8, 12, 11, '\\', 'A' });
    b.str(&.{ 0x80, 0x01 });
    b.textStr("Hi");
    b.textStr("é😀");
    b.date(.{ .year = 2024, .month = 1, .day = 2, .hour = 3, .minute = 4, .second = 5, .utc_offset_hour = 0 });
    b.date(.{ .year = 2024, .month = 1, .day = 2, .hour = 3, .minute = 4, .second = 5, .utc_offset_hour = -5, .utc_offset_minute = 30 });
    b.date(.{ .year = 2024, .month = 12 });
    try testing.expectEqualStrings("/A#20B#23#2F#28x#29(a(b)c)(x\\)y\\()(\\000\\001\\b\\f\\013\\\\A)<8001>(Hi)<FEFF00E9D83DDE00>" ++
        "(D:20240102030405Z)(D:20240102030405-05'30)(D:202412)", b.bytes());
}

test "text strings: malformed UTF-8 and U+FFFD" {
    var b = Buf.init(testing.allocator);
    defer b.list.deinit(testing.allocator);
    b.textStr("a\xef\xbf\xbd\xff\xc3");
    b.textStr("\xe2\x82");
    try testing.expectEqualStrings("<FEFF0061FFFDFFFDFFFD><FEFFFFFDFFFD>", b.bytes());
}

test "lazy padding" {
    var b = Buf.init(testing.allocator);
    defer b.list.deinit(testing.allocator);
    defer b.patches.deinit(testing.allocator);
    b.dict();
    b.pairName("Type", "Pages");
    b.pairInt("Count", 2);
    b.key("Kids");
    b.refs(&.{ 5, 7 });
    b.pairReal("X", 1.5);
    b.key("A");
    b.arr();
    b.boolean(true);
    b.nul();
    b.str("s");
    b.int(-3);
    b.arrEnd();
    b.dictEnd();
    try testing.expectEqualStrings("<</Type/Pages/Count 2/Kids[R R]/X 1.5/A[true null(s)-3]>>", b.bytes());
    try testing.expectEqual(@as(usize, 2), b.patches.items.len);
}

test "resources dedup and names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r = Resources.init(arena.allocator());
    try testing.expectEqualStrings("g0", r.add(.ext_g_state, 4).slice());
    try testing.expectEqualStrings("g1", r.add(.ext_g_state, 5).slice());
    try testing.expectEqualStrings("g0", r.add(.ext_g_state, 4).slice());
    try testing.expectEqualStrings("x0", r.add(.x_object, 9).slice());
    try testing.expectEqualStrings("f10", Resources.nameOf(.font, 10).slice());
}

test "stable hash matches takumi fixture ids" {
    // The instance id of every takumi-pdf fixture with an Info dictionary (130 files) equals
    // `stableHashBase64(file[0..end of Info object])` (checked by a scratch program); this
    // vector was produced by that verified implementation.
    var t: [24]u8 = undefined;
    try testing.expectEqualStrings("GqJo2dwGvL/F7BWdOl0TyQ==", stableHashBase64(&t, "abc"));
}

fn buildSample(a: Allocator, compress: bool, version: Version) ![]u8 {
    var d = Doc.init(a, .{ .compress = compress, .version = version });
    const p = d.addPage();
    const c = d.alloc();
    var res = Resources.init(a);
    const gs = d.alloc();
    d.extGState(gs, .{ .fill_alpha = 0.6, .stroke_alpha = 0.6, .blend_mode = "Screen" });
    const g0 = res.add(.ext_g_state, gs);
    _ = g0;
    const rr = res.write(&d);
    d.contentStream(c, "q 1 0 0 rg 0 0 10 10 re\nf\nQ");
    _ = d.beginPage(p, .{ .resources = rr, .media_box = .{ 0, 0, 200, 100 }, .contents = c });
    d.endDict();
    const se1 = d.alloc();
    const se2 = d.alloc();
    var b = d.beginDict(se1, .struct_elements);
    b.pairName("Type", "StructElem");
    b.pairRef("P", se2);
    d.endDict();
    b = d.beginDict(se2, .struct_elements);
    b.pairName("Type", "StructElem");
    b.key("K");
    b.refs(&.{se1});
    d.endDict();
    b = d.beginCatalog();
    b.pairText("Lang", "en");
    d.endCatalog();
    var out: std.ArrayList(u8) = .empty;
    try d.finish(&out, .{ .info = .{ .producer = "test" } });
    return out.items;
}

test "document structure (uncompressed, classic xref)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pdf = try buildSample(arena.allocator(), false, .v1_4);
    const expect_prefix = "%PDF-1.4\n%\x80\x80\x80\x80\n\n" ++
        "1 0 obj\n<</Type/Pages/Count 1/Kids[6 0 R]>>\nendobj\n" ++
        "2 0 obj\n<</Type/StructElem/P 3 0 R>>\nendobj\n" ++
        "3 0 obj\n<</Type/StructElem/K[2 0 R]>>\nendobj\n" ++
        "4 0 obj\n<</Type/ExtGState/ca 0.6/CA 0.6/BM/Screen>>\nendobj\n" ++
        "5 0 obj\n<</ProcSet[/PDF/Text/ImageC/ImageB]/ExtGState<</g0 4 0 R>>>>\nendobj\n" ++
        "6 0 obj\n<</Type/Page/Resources 5 0 R/MediaBox[0 0 200 100]/Parent 1 0 R/Contents 7 0 R>>\nendobj\n" ++
        "7 0 obj\n<</Length 27>>\nstream\nq 1 0 0 rg 0 0 10 10 re\nf\nQ\nendstream\nendobj\n" ++
        "8 0 obj\n<</Producer(test)>>\nendobj\n" ++
        "9 0 obj\n<</Type/Catalog/Pages 1 0 R/Lang(en)>>\nendobj\n" ++
        "xref\n0 10\n0000000000 65535 f\r\n0000000016 00000 n\r\n";
    try testing.expectEqualStrings(expect_prefix, pdf[0..@min(pdf.len, expect_prefix.len)]);
    try testing.expect(std.mem.indexOf(u8, pdf, "trailer\n<</Size 10/Root 9 0 R/Info 8 0 R/ID[(") != null);
    try testing.expect(std.mem.endsWith(u8, pdf, "%%EOF"));
}

test "document structure (xref stream, object stream)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pdf = try buildSample(arena.allocator(), true, .v1_7);
    // object stream first, numbered after all regular objects
    try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.7\n%\x80\x80\x80\x80\n\n8 0 obj\n<</Length "));
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type/ObjStm/N 2/First 9/Filter/FlateDecode>>") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type/XRef/Filter/FlateDecode/Size 12/Root 10 0 R/Info 9 0 R/ID[(") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/W[1 2 2]>>") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "1 0 obj\n<</Type/Pages") != null);
}

test "dangling ref is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d = Doc.init(arena.allocator(), .{});
    const p = d.addPage();
    _ = d.beginPage(p, .{ .resources = null, .media_box = .{ 0, 0, 1, 1 }, .contents = d.alloc() });
    d.endDict();
    var out: std.ArrayList(u8) = .empty;
    try testing.expectError(error.DanglingRef, d.finish(&out, .{}));
}

test {
    _ = @import("content.zig");
}

test "limits: strings and names of the written objects; packed structure elements do not count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = try a.alloc(u8, 40000);
    @memset(long, 'a');
    for ([_]bool{ true, false }) |two| {
        var d = Doc.init(a, .{ .version = .v1_7, .compress = false });
        const page = d.addPage();
        const cs = d.alloc();
        d.contentStream(cs, "");
        _ = d.beginPage(page, .{ .resources = null, .media_box = .{ 0, 0, 10, 10 }, .contents = cs });
        d.endDict();
        const n: usize = if (two) 2 else 1;
        for (0..n) |_| {
            const b = d.beginDict(d.alloc(), .struct_elements);
            b.pairText("Alt", long);
            d.endDict();
        }
        const o = d.beginDict(d.alloc(), .annotations);
        o.pairName("S", long[0..128]);
        o.pairStr("URI", long[0..300]);
        d.endDict();
        var out: std.ArrayList(u8) = .empty;
        try d.finish(&out, .{ .info = .{ .title = long[0..500] } });
        // two structure elements are packed into an object stream, a single one is not
        try testing.expectEqual(@as(u32, if (two) 500 else 40000), d.limits.str_len);
        try testing.expectEqual(@as(u32, 128), d.limits.name_len);
    }
}
