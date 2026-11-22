const std = @import("std");

/// Optional features (see src/config.zig) and the profiles that enable them. Every flag can be
/// overridden on top of a profile with `-D<name>=true|false`.
const Feature = struct { name: []const u8, desc: []const u8, standard: bool };
const features = [_]Feature{
    .{ .name = "css", .desc = "stylesheets (`css` option, HTML <style>), selectors, @keyframes", .standard = true },
    .{ .name = "tw", .desc = "Tailwind `tw` utilities", .standard = true },
    .{ .name = "html", .desc = "HTML markup input", .standard = true },
    .{ .name = "svg", .desc = "SVG images (image src / url(), clip-path path())", .standard = true },
    .{ .name = "woff", .desc = "WOFF / WOFF2 fonts (brotli)", .standard = true },
    .{ .name = "variable_fonts", .desc = "variable fonts (fvar/gvar/HVAR/MVAR/avar instances)", .standard = true },
    .{ .name = "cff", .desc = "CFF / CFF2 outlines (OpenType .otf)", .standard = true },
    .{ .name = "effects", .desc = "clip-path, masks, mix-/background-blend-mode, backdrop-filter, isolation", .standard = true },
    .{ .name = "modern_color", .desc = "lab/lch/oklab/oklch/color()/color-mix()/light-dark(), gradient `in <space>`", .standard = true },
    .{ .name = "tables", .desc = "table layout", .standard = true },
    .{ .name = "floats", .desc = "floats", .standard = true },
    .{ .name = "webp_gif_decode", .desc = "WebP (lossless) and GIF image sources", .standard = true },
    .{ .name = "text_wrap_balance", .desc = "text-wrap: balance / pretty (score-based line breaking)", .standard = true },
    .{ .name = "color_fonts", .desc = "colour glyphs (COLR v0/v1, CBDT/sbix PNG), emoji presentation", .standard = false },
    .{ .name = "bitmap_glyphs", .desc = "colour bitmap glyphs only (CBDT/CBLC, sbix PNG emoji) + emoji presentation; implied by color_fonts", .standard = true },
    .{ .name = "complex_text", .desc = "bidi, Arabic/Hebrew/Indic/Thai shaping, normalisation", .standard = false },
    .{ .name = "animation", .desc = "CSS animations / transitions, renderAnimation, animated image sources", .standard = false },
    .{ .name = "extra_codecs", .desc = "WebP lossy (VP8) decode, animated GIF/APNG/WebP decode + encode, ICO output", .standard = false },
    .{ .name = "render_svg", .desc = "renderSvg (vector SVG output)", .standard = false },
    // Only the `pdf` profile (= full + pdf) turns this on; never part of core / standard / full.
    .{ .name = "pdf", .desc = "renderPdf (PDF output)", .standard = false },
};

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.Optimize, "wasm-optimize", "wasm optimize mode (small|fast|safe|debug)") orelse .small;
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .simd128, .bulk_memory, .sign_ext, .nontrapping_fptoint, .mutable_globals }),
    });
    const strip = b.option(bool, "strip", "strip wasm debug info (default true)") orelse true;
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .strip = strip,
        .unwind_tables = .none,
        .single_threaded = true,
    });
    // Feature flags (see src/config.zig): -Dprofile=core|standard|full (default full).
    const profile = b.option([]const u8, "profile", "feature preset: core | standard | full (default) | pdf (= full + pdf)") orelse "full";
    const level: u2 = if (std.mem.eql(u8, profile, "core")) 0 else if (std.mem.eql(u8, profile, "standard")) 1 else if (std.mem.eql(u8, profile, "full") or std.mem.eql(u8, profile, "pdf")) 2 else {
        std.debug.panic("unknown -Dprofile={s} (core | standard | full | pdf)", .{profile});
    };
    const is_pdf = std.mem.eql(u8, profile, "pdf");
    const flags = b.addOptions();
    // The native addon (`zig build native`) is built from the same options with one difference: `pdf`
    // is on unless `-Dpdf=false` says otherwise (the addon serves both `bm-render` and `bm-render/pdf`).
    const native_flags = b.addOptions();
    inline for (features) |ft| {
        const is_pdf_flag = comptime std.mem.eql(u8, ft.name, "pdf");
        const def = if (is_pdf_flag) is_pdf else (level == 2 or (level == 1 and ft.standard));
        const given = b.option(bool, ft.name, ft.desc);
        flags.addOption(bool, ft.name, given orelse def);
        native_flags.addOption(bool, ft.name, given orelse (def or is_pdf_flag));
    }
    flags.addOption([]const u8, "profile", profile);
    native_flags.addOption([]const u8, "profile", profile);
    wasm_mod.addOptions("build_options", flags);

    const stack = (b.option(u64, "stack-kib", "wasm shadow stack size in KiB (default 1024)") orelse 1024) * 1024;
    const wasm = b.addExecutable(.{ .name = "bm_render", .root_module = wasm_mod });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.import_memory = false;
    wasm.stack_size = stack;
    b.installArtifact(wasm);

    // Stand-alone add-on modules (lazy-loaded by js/addons.mjs): WOFF/WOFF2 -> sfnt.
    const woff_mod = b.createModule(.{
        .root_source_file = b.path("src/addon_woff.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .strip = strip,
        .unwind_tables = .none,
        .single_threaded = true,
    });
    const woff = b.addExecutable(.{ .name = "bm_woff", .root_module = woff_mod });
    woff.entry = .disabled;
    woff.rdynamic = true;
    woff.import_memory = false;
    woff.stack_size = 256 * 1024;
    const woff_install = b.addInstallArtifact(woff, .{});
    b.getInstallStep().dependOn(&woff_install.step);
    b.step("addons", "Build the add-on wasm modules only").dependOn(&woff_install.step);

    const native_target = b.standardTargetOptions(.{});
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = .debug,
    });
    test_mod.addOptions("build_options", flags);
    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this string");
    // LLVM backend: the self-hosted x86_64 backend (default for Debug on Linux in Zig 0.17.1) miscompiles
    // raster/blur.zig (segfault in columnPass); the same tests pass under LLVM.
    const tests = b.addTest(.{ .use_llvm = true, .root_module = test_mod, .filters = if (test_filter) |filter| &.{filter} else &.{} });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    addNative(b, native_target, native_flags);
}

/// `zig build native -Dtarget=<triple> [-Dnative-optimize=fast|safe|small|debug]`: the Node-API addon
/// (src/native.zig, docs/NATIVE.md) as `zig-out/native/bm-render.<platform>-<arch>[-<abi>].node`.
/// All eight release targets are cross-compiled by scripts/build-native.mjs.
fn addNative(b: *std.Build, target_in: std.Build.ResolvedTarget, flags: *std.Build.Step.Options) void {
    // A fixed CPU level per architecture, never the build host's. x86-64: x86-64-v2 (SSE4.2, SSSE3,
    // POPCNT; no AVX and no FMA, so no multiply-add can ever be fused there). The SSE2-only baseline
    // makes the pixel loops slower than the wasm build under V8; a CPU older than v2 is detected when
    // the addon registers (src/native.zig `cpuIsSupported`) and gets the wasm build instead.
    // arm64: the architecture baseline (NEON).
    var query = target_in.query;
    query.cpu_model = if (target_in.result.cpu.arch == .x86_64) .{ .explicit = &std.Target.x86.cpu.x86_64_v2 } else .baseline;
    const target = b.resolveTargetQuery(query);
    const t = target.result;
    const optimize = b.option(std.builtin.OptimizeMode, "native-optimize", "addon optimize mode (default fast)") orelse .fast;
    const strip = b.option(bool, "native-strip", "strip the addon's debug info (default true)") orelse true;
    const mod = b.createModule(.{
        .root_source_file = b.path("src/native.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .unwind_tables = .none,
        .single_threaded = false,
        .pic = true,
        // Windows: no C runtime at all (kernel32 only). Elsewhere libc gives malloc and pthreads.
        .link_libc = t.os.tag != .windows,
    });
    mod.addOptions("build_options", flags);
    const lib = b.addLibrary(.{ .linkage = .dynamic, .name = "bm_render_node", .root_module = mod });
    // The napi_* symbols come from the host executable at load time: undefined in the shared object
    // (ELF) / `-undefined dynamic_lookup` (Mach-O). Windows resolves them at run time (src/native/napi.zig).
    lib.linker_allow_shlib_undefined = true;
    const platform = switch (t.os.tag) {
        .windows => "win32",
        .macos => "darwin",
        else => @tagName(t.os.tag),
    };
    const arch = switch (t.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => @tagName(t.cpu.arch),
    };
    // npm naming (as napi-rs): win32 packages are called "-msvc" whatever toolchain built the DLL.
    const abi = switch (t.os.tag) {
        .windows => "-msvc",
        .linux => if (t.abi.isMusl()) "-musl" else "-gnu",
        else => "",
    };
    const file = b.fmt("bm-render.{s}-{s}{s}.node", .{ platform, arch, abi });
    const install = b.addInstallFileWithDir(lib.getEmittedBin(), .{ .custom = "native" }, file);
    b.step("native", "Build the Node-API addon (zig-out/native/*.node)").dependOn(&install.step);
}
