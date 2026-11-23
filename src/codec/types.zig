//! Shared codec types. Kept in its own tiny file so every codec can import it
//! without pulling in the others.
const std = @import("std");

/// A decoded image: STRAIGHT-alpha RGBA8, row-major, `data.len == width*height*4`.
/// `data` is owned by the allocator passed to the decoder.
pub const Image = struct {
    width: u32,
    height: u32,
    data: []u8,

    pub fn deinit(self: Image, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
    }
};

/// Decoder resource limits (inputs are untrusted).
pub const Limits = struct {
    /// Maximum width*height accepted by any decoder (checked before the pixel buffer is allocated).
    max_pixels: u64 = 64 << 20,
    /// Maximum frames of an animation walked by `anim.Animator` (never above `Animator.max_frames`).
    max_frames: u32 = std.math.maxInt(u32),
    /// Apply the JPEG EXIF Orientation tag (rotate/flip). takumi (zune-jpeg) does NOT apply it,
    /// so the default `false` mirrors takumi; browsers do apply it for <img>.
    apply_exif_orientation: bool = false,
};

pub const Error = error{
    /// Malformed / truncated / inconsistent stream.
    InvalidData,
    /// Valid file of a kind we do not decode (e.g. lossy WebP, arithmetic-coded JPEG, CMYK).
    UnsupportedFormat,
    /// Dimensions exceed `Limits.max_pixels` (or are zero).
    ImageTooLarge,
    OutOfMemory,
};

/// Checks `w*h` against the limits; returns the RGBA byte size.
pub fn checkSize(w: u32, h: u32, limits: Limits) Error!usize {
    if (w == 0 or h == 0) return error.InvalidData;
    const px = @as(u64, w) * @as(u64, h);
    if (px > limits.max_pixels) return error.ImageTooLarge;
    if (px > std.math.maxInt(usize) / 4) return error.ImageTooLarge;
    return @intCast(px * 4);
}
