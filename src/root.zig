//! Native root: pulls in every module's unit tests.
pub const json = @import("json.zig");
pub const render = @import("render.zig");
pub const paint = @import("paint.zig");
/// Feature switches for modules (`@import("root").bm_config`).
pub const bm_config = @import("config.zig");

test {
    _ = json;
    _ = render;
    _ = @import("dom.zig");
    _ = @import("text_control.zig");
    _ = @import("test_fixcss.zig");
    _ = @import("measure_xform.zig");
    _ = @import("animate.zig");
    _ = paint;
    _ = @import("bump.zig");
    _ = @import("style/style.zig");
    _ = @import("layout/layout.zig");
    _ = @import("font/font.zig");
    _ = @import("raster/raster.zig");
    _ = @import("codec/codec.zig");
    _ = @import("test_woff.zig");
    _ = @import("test_layout_fix.zig");
    _ = @import("perf_tests.zig");
    _ = @import("test_paged.zig");
    _ = @import("pdf/options.zig");
    _ = @import("pdf/pdf.zig");
    _ = @import("pdf/writer.zig");
    _ = @import("pdf/emit_geom.zig");
    _ = @import("pdf/emit_surface.zig");
    _ = @import("pdf/emit_shading.zig");
    _ = @import("pdf/emit_device.zig");
    _ = @import("pdf/emit_border.zig");
    _ = @import("pdf/emit_image.zig");
    _ = @import("pdf/png_krilla.zig");
    _ = @import("pdf/emit.zig");
    _ = @import("pdf/text.zig");
    _ = @import("pdf/interactive.zig");
    _ = @import("pdf/metadata.zig");
    _ = @import("pdf/attach.zig");
    _ = @import("pdf/counters.zig");
    _ = @import("pdf/bands.zig");
    _ = @import("pdf/paged.zig");
    _ = @import("pdf/page_rules.zig");
    _ = @import("pdf/emit_svg.zig");
    _ = @import("pdf/conform.zig");
    _ = @import("pdf/tags.zig");
    _ = @import("pdf/markers.zig");
    _ = @import("pdf/page_names.zig");
    _ = @import("pdf/filelayer_tests.zig");
    _ = @import("fuzz.zig");
}
