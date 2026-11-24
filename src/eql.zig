//! Byte-slice equality for hot cache lookups. `std.mem.eql(u8, ..)` compares with SIMD vectors,
//! which V8 runs several times slower than plain 8-byte words for keys of a few dozen bytes (the
//! text shaping and font matching caches, the inline style table: measured on wasm32).
const std = @import("std");

pub fn bytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i + 8 <= a.len) : (i += 8) {
        if (std.mem.readInt(u64, a[i..][0..8], .little) != std.mem.readInt(u64, b[i..][0..8], .little)) return false;
    }
    while (i < a.len) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

test bytes {
    try std.testing.expect(bytes("", ""));
    try std.testing.expect(bytes("abcdefghijk", "abcdefghijk"));
    try std.testing.expect(!bytes("abcdefghijk", "abcdefghijx"));
    try std.testing.expect(!bytes("abcdefghijk", "xbcdefghijk"));
    try std.testing.expect(!bytes("abc", "abcd"));
}
