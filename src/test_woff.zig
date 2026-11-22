//! Test root for src/woff (the tests import ../codec and ../font, so the root must live at
//! src/ level). Also serves as the module root for the scratch wasm harness (`pub const woff`).
pub const woff = @import("woff/woff.zig");
/// (for scratch harnesses that check decoded fonts with the font parser)
pub const ttf = @import("font/ttf.zig");

test {
    _ = @import("woff/tests.zig");
    _ = @import("woff/sfnt.zig");
    _ = @import("woff/brotli.zig");
}
