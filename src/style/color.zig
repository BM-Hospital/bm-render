//! CSS colour parsing: hex, rgb()/rgba(), hsl()/hsla(), hwb(), named colours, transparent, currentColor.
//! Modern spaces and keyword-only relative colours are enabled by the modern_color build feature.
const std = @import("std");
const tok = @import("tokenizer.zig");
const cmath = @import("cmath.zig");
const Error = tok.Error;
const Token = tok.Token;
const Lexer = tok.Lexer;

/// Straight (non-premultiplied) sRGB colour.
pub const Color = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub const transparent: Color = .{};
    pub const black: Color = .{ .a = 255 };

    pub fn eql(x: Color, y: Color) bool {
        return x.r == y.r and x.g == y.g and x.b == y.b and x.a == y.a;
    }
};

/// A computed colour that may still refer to the element's `color` (currentColor).
pub const ColorValue = union(enum) {
    rgba: Color,
    current,

    pub fn resolve(v: ColorValue, current_color: Color) Color {
        return switch (v) {
            .rgba => |c| c,
            .current => current_color,
        };
    }
};

fn clampByte(v: f32) u8 {
    if (!(v > 0)) return 0; // also NaN
    if (v >= 255) return 255;
    return @intFromFloat(@round(v));
}

/// Parses a colour from an already-read token. Returns null if the token cannot start a colour
/// or is malformed; callers treat null as "not a colour", which ends in InvalidStyleValue wherever
/// a colour is required. Modern functions (lab/lch/oklab/oklch/color()/color-mix()/light-dark())
/// are converted to 8-bit sRGB immediately, clipping out-of-gamut channels (as takumi does via the
/// `color` crate's `to_rgba8`). `currentColor` inside color-mix()/light-dark() is rejected
/// (takumi rejects it too).
pub fn fromToken(t: Token) ?ColorValue {
    if (t.kind == .ident and std.ascii.eqlIgnoreCase(t.text, "currentcolor")) return .current;
    return .{ .rgba = colorOf(t, 0) orelse return null };
}

const max_color_depth = 8;

test "relative colors substitute channels, preserve alpha and reject unsupported slots" {
    if (comptime !modern_color) return;
    try expectColor("rgb(from #336699 r g b)", 51, 102, 153, 255);
    try expectColor("rgb(from red r g 200)", 255, 0, 200, 255);
    try expectColor("rgb(from rgb(10 20 30 / .5) r g b / .25)", 10, 20, 30, 64);
    try expectColor("rgb(from rgb(10 20 30 / .5) b r g / alpha)", 30, 10, 20, 128);
    try expectColor("hsl(from red 120deg s l)", 0, 255, 0, 255);
    try expectColor("hwb(from red h 20% 10%)", 230, 51, 51, 255);
    for ([_][]const u8{ "lab", "lch", "oklab", "oklch" }) |space| {
        var buf: [100]u8 = undefined;
        const source = try std.fmt.bufPrint(&buf, "{s}(from #336699 l {s} / alpha)", .{ space, if (std.mem.endsWith(u8, space, "lch")) "c h" else "a b" });
        try expectColor(source, 51, 102, 153, 255);
    }
    for ([_][]const u8{ "rgb(from red calc(r + 1) g b)", "rgb(from currentColor r g b)", "hsl(from red 10% s l)", "rgb(from red r g b junk)" }) |invalid|
        try std.testing.expectError(error.InvalidStyleValue, parse(invalid));
}

/// Build switch `modern_color` (src/config.zig via the root module; on in standalone tests): without
/// it lab()/lch()/oklab()/oklch()/color()/color-mix()/light-dark() are invalid colours.
pub const modern_color = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "bm_config")) root.bm_config.enable_modern_color else true;
};

fn colorOf(t: Token, depth: u32) ?Color {
    switch (t.kind) {
        .hash => return parseHex(t.text),
        .ident => return named(t.text),
        .function => {
            const n = t.text;
            const fi = tok.matchPacked(n, func_names) orelse return null;
            var args = Lexer.init(t.args);
            if (args.next().isIdent("from")) {
                if (comptime !modern_color) return null;
                if (depth >= max_color_depth) return null;
                const space: Space = switch (fi) {
                    0, 1 => .srgb, 2, 3 => .hsl, 4 => .hwb,
                    5 => .lab, 6 => .lch, 7 => .oklab, 8 => .oklch,
                    else => return null,
                };
                return parseRelative(&args, space, depth + 1);
            }
            return switch (fi) {
                0, 1 => parseFunc(t.args, .rgb),
                2, 3 => parseFunc(t.args, .hsl),
                4 => parseFunc(t.args, .hwb),
                else => if (comptime !modern_color) null else if (depth >= max_color_depth) null else parseModern(fi - 5, t.args, depth),
            };
        },
        else => return null,
    }
}

const func_names = "rgb\x00rgba\x00hsl\x00hsla\x00hwb\x00lab\x00lch\x00oklab\x00oklch\x00color\x00color-mix\x00light-dark";

/// True for the colour functions whose presence switches a gradient's default interpolation
/// space to Oklab (lab, lch, oklab, oklch, color, color-mix — takumi `MODERN_COLOR_FUNCTIONS`).
pub fn isModernColorToken(t: Token) bool {
    if (t.kind != .function) return false;
    const i = tok.matchPacked(t.text, func_names) orelse return false;
    if (i >= 5 and i <= 10) return true;
    // Relative syntax (`rgb(from ...)`) is modern whatever the function name (takumi
    // `peeks_modern_color_function`; CSS Color 5: its result is not a legacy colour).
    if (i <= 4) {
        var args = Lexer.init(t.args);
        return args.next().isIdent("from");
    }
    return false;
}

test "relative colour syntax counts as a modern colour for gradient interpolation" {
    for ([_][]const u8{ "rgb(from red r g b)", "hsl(from red h s l)", "oklch(.5 .1 10)", "color-mix(in srgb, red, blue)" }) |src| {
        var l = Lexer.init(src);
        try std.testing.expect(isModernColorToken(l.next()));
    }
    for ([_][]const u8{ "rgb(1 2 3)", "hsla(10, 20%, 30%, .5)", "light-dark(red, blue)" }) |src| {
        var l = Lexer.init(src);
        try std.testing.expect(!isModernColorToken(l.next()));
    }
}

/// Parses a whole string as one colour (whitespace allowed around it).
pub fn parse(s: []const u8) Error!ColorValue {
    var l = Lexer.init(s);
    const c = fromToken(l.next()) orelse return error.InvalidStyleValue;
    if (!l.atEnd()) return error.InvalidStyleValue;
    return c;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn parseHex(h: []const u8) ?Color {
    var d: [8]u8 = undefined;
    if (h.len != 3 and h.len != 4 and h.len != 6 and h.len != 8) return null;
    for (h, 0..) |c, i| d[i] = hexVal(c) orelse return null;
    if (h.len <= 4) {
        return .{ .r = d[0] * 17, .g = d[1] * 17, .b = d[2] * 17, .a = if (h.len == 4) d[3] * 17 else 255 };
    }
    return .{
        .r = d[0] * 16 + d[1],
        .g = d[2] * 16 + d[3],
        .b = d[4] * 16 + d[5],
        .a = if (h.len == 8) d[6] * 16 + d[7] else 255,
    };
}

const FuncKind = enum { rgb, hsl, hwb };

const Arg = struct { v: f32, pct: bool, none: bool = false };

fn angleDeg(t: Token) ?f32 {
    if (t.kind == .number) return t.num;
    if (t.kind != .dimension) return null;
    const f = angleFactor(t.text) orelse return null;
    return t.num * f;
}

pub fn angleFactor(unit: []const u8) ?f32 {
    if (std.ascii.eqlIgnoreCase(unit, "deg")) return 1;
    if (std.ascii.eqlIgnoreCase(unit, "rad")) return 180.0 / std.math.pi;
    if (std.ascii.eqlIgnoreCase(unit, "grad")) return 0.9;
    if (std.ascii.eqlIgnoreCase(unit, "turn")) return 360;
    return null;
}

fn parseFunc(args: []const u8, kind: FuncKind) ?Color {
    var l = Lexer.init(args);
    var vals: [4]Arg = undefined;
    var n: usize = 0;
    var legacy: ?bool = null; // comma syntax?
    var saw_slash = false;
    while (true) {
        var cur = l.next();
        if (cur.kind == .eof) break;
        if (n > 0) {
            if (legacy == null) legacy = (cur.kind == .comma);
            if (legacy.?) {
                if (cur.kind != .comma) return null;
                cur = l.next();
            } else if (cur.kind == .slash) {
                if (n != 3 or saw_slash) return null;
                saw_slash = true;
                cur = l.next();
            } else if (n == 3) return null; // modern alpha needs '/'
        }
        if (n >= 4) return null;
        vals[n] = switch (cur.kind) {
            .number => .{ .v = cur.num, .pct = false },
            .percentage => .{ .v = cur.num, .pct = true },
            .dimension => if (n == 0 and kind != .rgb)
                .{ .v = angleDeg(cur) orelse return null, .pct = false }
            else
                return null,
            .ident => if (legacy != true and std.ascii.eqlIgnoreCase(cur.text, "none"))
                .{ .v = 0, .pct = false, .none = true }
            else
                return null,
            else => return null,
        };
        n += 1;
    }
    if (n < 3) return null;
    if (legacy == true and kind == .hwb) return null;
    var a: u8 = 255;
    if (n == 4) {
        const av = if (vals[3].pct) vals[3].v / 100 else vals[3].v;
        a = clampByte(std.math.clamp(av, 0, 1) * 255);
    }
    switch (kind) {
        .rgb => {
            var out: [3]u8 = undefined;
            for (0..3) |i| out[i] = clampByte(if (vals[i].pct) vals[i].v * 2.55 else vals[i].v);
            return .{ .r = out[0], .g = out[1], .b = out[2], .a = a };
        },
        .hsl, .hwb => {
            if (vals[0].pct) return null;
            if (legacy == true and (!vals[1].pct or !vals[2].pct)) return null;
            const h = vals[0].v;
            const p1 = std.math.clamp(vals[1].v * 0.01, 0, 1);
            const p2 = std.math.clamp(vals[2].v * 0.01, 0, 1);
            var rgb: [3]f32 = undefined;
            if (kind == .hsl) {
                rgb = hslToRgb(h, p1, p2);
            } else {
                const w = p1;
                const bk = p2;
                if (w + bk >= 1) {
                    const g = w / (w + bk);
                    rgb = .{ g, g, g };
                } else {
                    rgb = hslToRgb(h, 1, 0.5);
                    for (&rgb) |*c| c.* = c.* * (1 - w - bk) + w;
                }
            }
            return .{ .r = clampByte(rgb[0] * 255), .g = clampByte(rgb[1] * 255), .b = clampByte(rgb[2] * 255), .a = a };
        },
    }
}

fn hslToRgb(h_deg: f32, s: f32, l: f32) [3]f32 {
    // same f32 operation order as the `color` crate (exact .5 cases round the same way)
    const h: f32 = if (@abs(h_deg) < 1.0e6) h_deg else 0; // NaN / inf guard
    var out: [3]f32 = undefined;
    const ns = [3]f32{ 0, 8, 4 };
    for (ns, 0..) |n, i| {
        const kk = n + h * (1.0 / 30.0);
        const k = kk - 12 * @floor(kk * (1.0 / 12.0));
        const a = s * @min(l, 1 - l);
        out[i] = l - a * @max(-1, @min(@min(k - 3, 9 - k), 1));
    }
    return out;
}

// =============================================================================================
// Modern colour spaces (CSS Color 4/5). Mirrors the `color` crate 0.3 used by takumi:
// components parsed per space, converted through XYZ-D65 in f64, clipped per channel to sRGB and
// rounded to 8 bits. Interpolation premultiplies, treats powerless hues as missing and fixes up
// hues per the hue method.
// =============================================================================================

/// Colour spaces usable in `color()`, `color-mix(in ...)` and gradient `in ...`.
pub const Space = enum(u8) { srgb, srgb_linear, display_p3, a98_rgb, prophoto_rgb, rec2020, xyz_d50, xyz_d65, lab, lch, oklab, oklch, hsl, hwb };
pub const HueMethod = enum(u8) { shorter, longer, increasing, decreasing };

const space_names = "srgb\x00srgb-linear\x00display-p3\x00a98-rgb\x00prophoto-rgb\x00rec2020\x00xyz-d50\x00xyz-d65\x00lab\x00lch\x00oklab\x00oklch\x00hsl\x00hwb\x00xyz";

/// `<color-space>` ident (as in `in <space>`; `xyz` = xyz-d65).
pub fn spaceFromIdent(t: Token) ?Space {
    if (t.kind != .ident) return null;
    const i = tok.matchPacked(t.text, space_names) orelse return null;
    return if (i == 14) .xyz_d65 else @fromBackingInt(@intCast(i));
}

pub fn isCylindrical(s: Space) bool {
    return s == .lch or s == .oklch or s == .hsl or s == .hwb;
}

/// Parses `<color-space> [<hue-method> hue]` (after the `in` keyword). Hue method on a
/// non-cylindrical space is an error (null).
pub fn parseInterpolationMethod(l: *Lexer) ?struct { space: Space, hue: HueMethod } {
    const space = spaceFromIdent(l.next()) orelse return null;
    var hue: HueMethod = .shorter;
    const p = l.peek();
    if (p.kind == .ident) {
        if (tok.matchPacked(p.text, "shorter\x00longer\x00increasing\x00decreasing")) |h| {
            _ = l.next();
            if (!l.next().isIdent("hue")) return null;
            if (!isCylindrical(space)) return null;
            hue = @fromBackingInt(@intCast(h));
        }
    }
    return .{ .space = space, .hue = hue };
}

const M3 = [9]f64;

noinline fn mul3(m: *const M3, v: [3]f64) [3]f64 {
    return .{
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    };
}

// CSS Color 4 sample-code matrices.
const srgb_to_xyz: M3 = .{ 0.41239079926595934, 0.357584339383878, 0.1804807884018343, 0.21263900587151027, 0.715168678767756, 0.07219231536073371, 0.01933081871559182, 0.11919477979462598, 0.9505321522496607 };
const xyz_to_srgb: M3 = .{ 3.2409699419045226, -1.537383177570094, -0.4986107602930034, -0.9692436362808796, 1.8759675015077202, 0.04155505740717559, 0.05563007969699366, -0.20397695888897652, 1.0569715142428786 };
const p3_to_xyz: M3 = .{ 0.4865709486482162, 0.26566769316909306, 0.1982172852343625, 0.2289745640697488, 0.6917385218365064, 0.079286914093745, 0.0, 0.04511338185890264, 1.043944368900976 };
const xyz_to_p3: M3 = .{ 2.4934969119414254, -0.9313836179191239, -0.40271078445071684, -0.8294889695615747, 1.7626640603183463, 0.023624685841943577, 0.03584583024378447, -0.07617238926804182, 0.9568845240076872 };
const a98_to_xyz: M3 = .{ 0.5766690429101305, 0.1855582379065463, 0.1882286462349947, 0.29734497525053605, 0.6273635662554661, 0.07529145849399788, 0.02703136138641234, 0.07068885253582723, 0.9913375368376388 };
const xyz_to_a98: M3 = .{ 2.0415879038107465, -0.5650069742788596, -0.34473135077832956, -0.9692436362808795, 1.8759675015077202, 0.04155505740717557, 0.013444280632031142, -0.11836239223101838, 1.0151749943912054 };
const pp_to_xyz50: M3 = .{ 0.7977666449006423, 0.13518129740053308, 0.0313477341283922, 0.2880748288194013, 0.711835234241873, 0.00008993693872564, 0.0, 0.0, 0.8251046025104602 };
const xyz50_to_pp: M3 = .{ 1.3457868816471583, -0.25557208737979464, -0.05110186497554526, -0.5446307051249019, 1.5082477428451468, 0.02052744743642139, 0.0, 0.0, 1.2119675456389452 };
const r2020_to_xyz: M3 = .{ 0.6369580483012914, 0.14461690358620832, 0.1688809751641721, 0.2627002120112671, 0.6779980715188708, 0.05930171646986196, 0.0, 0.028072693049087428, 1.060985057710791 };
const xyz_to_r2020: M3 = .{ 1.716651187971268, -0.355670783776392, -0.253366281373660, -0.666684351832489, 1.616481236634939, 0.0157685458139111, 0.017639857445311, -0.042770613257809, 0.942103121235474 };
const d50_to_d65: M3 = .{ 0.955473421488075, -0.02309845494876471, 0.06325924320057072, -0.0283697093338637, 1.0099953980813041, 0.021041441191917323, 0.012314014864481998, -0.020507649298898964, 1.330365926242124 };
const d65_to_d50: M3 = .{ 1.0479297925449969, 0.022946870601609652, -0.05019226628920524, 0.02962780877005599, 0.9904344267538799, -0.017073799063418826, -0.009243040646204504, 0.015055191490298152, 0.7518742814281371 };
const xyz_to_lms: M3 = .{ 0.8190224379967030, 0.3619062600528904, -0.1288737815209879, 0.0329836539323885, 0.9292868615863434, 0.0361446663506424, 0.0481771893596242, 0.2642395317527308, 0.6335478284694309 };
const lms_to_oklab: M3 = .{ 0.2104542683093140, 0.7936177747023054, -0.0040720430116193, 1.9779985324311684, -2.4285922420485799, 0.4505937096174110, 0.0259040424655478, 0.7827717124575296, -0.8086757549230774 };
const oklab_to_lms: M3 = .{ 1.0, 0.3963377773761749, 0.2158037573099136, 1.0, -0.1055613458156586, -0.0638541728258133, 1.0, -0.0894841775298119, -1.2914855480194092 };
const lms_to_xyz: M3 = .{ 1.2268798758459243, -0.5578149944602171, 0.2813910456659647, -0.0405757452148008, 1.1122868032803170, -0.0717110580655164, -0.0763729366746601, -0.4214933324022432, 1.5869240198367816 };
const d50_white = [3]f64{ 0.3457 / 0.3585, 1.0, (1.0 - 0.3457 - 0.3585) / 0.3585 };
const lab_e: f64 = 216.0 / 24389.0;
const lab_k: f64 = 24389.0 / 27.0;

const r2020_a: f64 = 1.09929682680944;
const r2020_b: f64 = 0.018053968510807;

const Gamma = enum(u8) { linear, srgb, a98, prophoto, rec2020 };

/// Sign-preserving transfer function: to linear light when `dec`, else back to encoded.
noinline fn transfer(g: Gamma, c: f64, dec: bool) f64 {
    const a = @abs(c);
    const v: f64 = switch (g) {
        .linear => a,
        .srgb => if (dec)
            (if (a <= 0.04045) a / 12.92 else cmath.pow((a + 0.055) / 1.055, 2.4))
        else
            (if (a <= 0.0031308) a * 12.92 else 1.055 * cmath.pow(a, 1.0 / 2.4) - 0.055),
        .a98 => cmath.pow(a, if (dec) 563.0 / 256.0 else 256.0 / 563.0),
        .prophoto => if (dec)
            (if (a <= 16.0 / 512.0) a / 16 else cmath.pow(a, 1.8))
        else
            (if (a >= 1.0 / 512.0) cmath.pow(a, 1.0 / 1.8) else a * 16),
        .rec2020 => if (dec)
            (if (a < r2020_b * 4.5) a / 4.5 else cmath.pow((a + r2020_a - 1) / r2020_a, 1.0 / 0.45))
        else
            (if (a > r2020_b) r2020_a * cmath.pow(a, 0.45) - (r2020_a - 1) else 4.5 * a),
    };
    return if (c < 0) -v else v;
}

/// RGB-family spaces (Space tags 0..7): linear -> XYZ matrix (null = identity), transfer, white point.
const RgbDef = struct { to: ?*const M3, from: ?*const M3, gamma: Gamma, d50: bool = false };
const rgb_defs = [8]RgbDef{
    .{ .to = &srgb_to_xyz, .from = &xyz_to_srgb, .gamma = .srgb },
    .{ .to = &srgb_to_xyz, .from = &xyz_to_srgb, .gamma = .linear },
    .{ .to = &p3_to_xyz, .from = &xyz_to_p3, .gamma = .srgb },
    .{ .to = &a98_to_xyz, .from = &xyz_to_a98, .gamma = .a98 },
    .{ .to = &pp_to_xyz50, .from = &xyz50_to_pp, .gamma = .prophoto, .d50 = true },
    .{ .to = &r2020_to_xyz, .from = &xyz_to_r2020, .gamma = .rec2020 },
    .{ .to = null, .from = null, .gamma = .linear, .d50 = true },
    .{ .to = null, .from = null, .gamma = .linear },
};

fn polarToRect(c: [3]f64) [3]f64 {
    const sc = cmath.sinCosDeg(c[2]);
    return .{ c[0], c[1] * sc[1], c[1] * sc[0] };
}
fn rectToPolar(c: [3]f64) [3]f64 {
    const ch = @sqrt(c[1] * c[1] + c[2] * c[2]);
    var h = cmath.atan2Deg(c[2], c[1]);
    if (h < 0) h += 360;
    return .{ c[0], ch, h };
}

fn labToXyz50(c: [3]f64) [3]f64 {
    const fy = (c[0] + 16) / 116;
    const fx = c[1] / 500 + fy;
    const fz = fy - c[2] / 200;
    const x3 = fx * fx * fx;
    const z3 = fz * fz * fz;
    return .{
        d50_white[0] * (if (x3 > lab_e) x3 else (116 * fx - 16) / lab_k),
        d50_white[1] * (if (c[0] > lab_k * lab_e) fy * fy * fy else c[0] / lab_k),
        d50_white[2] * (if (z3 > lab_e) z3 else (116 * fz - 16) / lab_k),
    };
}
fn xyz50ToLab(v: [3]f64) [3]f64 {
    var f: [3]f64 = undefined;
    for (0..3) |i| {
        const x = v[i] / d50_white[i];
        f[i] = if (x > lab_e) cmath.cbrt(x) else (lab_k * x + 16) / 116;
    }
    return .{ 116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2]) };
}

/// hsl/hwb components: h in degrees, s/l (w/b) in 0..1.
fn hslToSrgb(c: [3]f64) [3]f64 {
    const r = hslToRgb(@floatCast(c[0]), @floatCast(c[1]), @floatCast(c[2]));
    return .{ r[0], r[1], r[2] };
}
fn srgbToHsl(c: [3]f64) [3]f64 {
    const mx = @max(c[0], @max(c[1], c[2]));
    const mn = @min(c[0], @min(c[1], c[2]));
    const l = (mx + mn) / 2;
    const d = mx - mn;
    var h: f64 = 0;
    var s: f64 = 0;
    if (d != 0) {
        s = if (l == 0 or l == 1) 0 else (mx - l) / @min(l, 1 - l);
        if (mx == c[0]) {
            h = (c[1] - c[2]) / d + (if (c[1] < c[2]) @as(f64, 6) else 0);
        } else if (mx == c[1]) {
            h = (c[2] - c[0]) / d + 2;
        } else h = (c[0] - c[1]) / d + 4;
        h *= 60;
    }
    if (s < 0) {
        s = -s;
        h += 180;
    }
    if (h >= 360) h -= 360;
    return .{ h, s, l };
}
fn hwbToSrgb(c: [3]f64) [3]f64 {
    const w = c[1];
    const b = c[2];
    if (w + b >= 1) {
        const g = w / (w + b);
        return .{ g, g, g };
    }
    var rgb = hslToSrgb(.{ c[0], 1, 0.5 });
    for (&rgb) |*x| x.* = x.* * (1 - w - b) + w;
    return rgb;
}
fn srgbToHwb(c: [3]f64) [3]f64 {
    const hsl = srgbToHsl(c);
    return .{ hsl[0], @min(c[0], @min(c[1], c[2])), 1 - @max(c[0], @max(c[1], c[2])) };
}

/// Space components -> XYZ D65.
noinline fn toXyz(s: Space, c0: [3]f64) [3]f64 {
    var c = c0;
    var rgb = s;
    switch (s) {
        .lab, .lch => {
            c = labToXyz50(if (s == .lch) polarToRect(c) else c);
            rgb = .xyz_d50;
        },
        .oklab, .oklch => {
            const lms = mul3(&oklab_to_lms, if (s == .oklch) polarToRect(c) else c);
            return mul3(&lms_to_xyz, .{ lms[0] * lms[0] * lms[0], lms[1] * lms[1] * lms[1], lms[2] * lms[2] * lms[2] });
        },
        .hsl, .hwb => {
            c = if (s == .hsl) hslToSrgb(c) else hwbToSrgb(c);
            rgb = .srgb;
        },
        else => {},
    }
    const d = rgb_defs[@backingInt(rgb)];
    for (&c) |*x| x.* = transfer(d.gamma, x.*, true);
    if (d.to) |m| c = mul3(m, c);
    return if (d.d50) mul3(&d50_to_d65, c) else c;
}

/// XYZ D65 -> space components.
noinline fn fromXyz(s: Space, v: [3]f64) [3]f64 {
    if (s == .oklab or s == .oklch) {
        const lms = mul3(&xyz_to_lms, v);
        const lab = mul3(&lms_to_oklab, .{ cmath.cbrt(lms[0]), cmath.cbrt(lms[1]), cmath.cbrt(lms[2]) });
        return if (s == .oklch) rectToPolar(lab) else lab;
    }
    const rgb: Space = switch (s) {
        .lab, .lch => .xyz_d50,
        .hsl, .hwb => .srgb,
        else => s,
    };
    const d = rgb_defs[@backingInt(rgb)];
    var c = if (d.d50) mul3(&d65_to_d50, v) else v;
    if (d.from) |m| c = mul3(m, c);
    for (&c) |*x| x.* = transfer(d.gamma, x.*, false);
    return switch (s) {
        .lab => xyz50ToLab(c),
        .lch => rectToPolar(xyz50ToLab(c)),
        .hsl => srgbToHsl(c),
        .hwb => srgbToHwb(c),
        else => c,
    };
}

fn convert(from: Space, to: Space, c: [3]f64) [3]f64 {
    if (from == to) return c;
    if (to == .srgb) {
        switch (from) {
            .hsl => return hslToSrgb(c),
            .hwb => return hwbToSrgb(c),
            else => {},
        }
    }
    if (from == .srgb) {
        switch (to) {
            .hsl => return srgbToHsl(c),
            .hwb => return srgbToHwb(c),
            else => {},
        }
    }
    return fromXyz(to, toXyz(from, c));
}

fn byte(v: f64) u8 {
    const x = v * 255;
    if (!(x > 0)) return 0;
    if (x >= 255) return 255;
    return @intFromFloat(@round(x));
}

/// Space components + alpha (0..1) -> 8-bit sRGB (per-channel clip; takumi `to_rgba8`).
noinline fn toColor(s: Space, c: [3]f64, alpha: f64) Color {
    const rgb = convert(s, .srgb, c);
    return .{ .r = byte(rgb[0]), .g = byte(rgb[1]), .b = byte(rgb[2]), .a = byte(alpha) };
}

/// Index of the hue component in a cylindrical space (hsl/hwb: 0, lch/oklch: 2).
fn hueIndex(s: Space) ?usize {
    return switch (s) {
        .hsl, .hwb => 0,
        .lch, .oklch => 2,
        else => null,
    };
}

const Comp = struct { c: [4]f64, missing: u4 = 0 };

/// 8-bit sRGB -> components in `s`; powerless hues (achromatic) are flagged missing.
fn fromColor(col: Color, s: Space) Comp {
    const src = [3]f64{ @as(f64, @floatFromInt(col.r)) / 255, @as(f64, @floatFromInt(col.g)) / 255, @as(f64, @floatFromInt(col.b)) / 255 };
    const c = convert(.srgb, s, src);
    var out: Comp = .{ .c = .{ c[0], c[1], c[2], @as(f64, @floatFromInt(col.a)) / 255 } };
    if (hueIndex(s)) |hi| {
        const powerless = switch (s) {
            .hsl => c[1] < 1e-6,
            .hwb => c[1] + c[2] >= 1 - 1e-6,
            else => c[1] < 1e-6,
        };
        if (powerless) {
            out.missing |= @as(u4, 1) << @intCast(hi);
            out.c[hi] = 0;
        }
    }
    return out;
}

/// Which non-alpha components are premultiplied in a space (bit i = component i).
fn premulMask(s: Space) u3 {
    return switch (s) {
        .hsl, .hwb => 0b110,
        .lch, .oklch => 0b011,
        else => 0b111,
    };
}

/// Interpolates two 8-bit colours at `t` in `space` (premultiplied, CSS Color 4 §12: powerless
/// hues become missing, missing components take the other colour's value, hue fix-up per `hue`),
/// returning 8-bit sRGB with `alpha_mul` applied to alpha. Mirrors the `color` crate's
/// `DynamicColor::interpolate(..).eval(t)` + `to_rgba8`.
pub noinline fn interpolateEx(a: Color, b: Color, t: f32, space: Space, hue: HueMethod, alpha_mul: f32) Color {
    var x = fromColor(a, space);
    var y = fromColor(b, space);
    for (0..4) |i| {
        const bit = @as(u4, 1) << @intCast(i);
        if (x.missing & bit != 0 and y.missing & bit == 0) x.c[i] = y.c[i];
        if (y.missing & bit != 0 and x.missing & bit == 0) y.c[i] = x.c[i];
    }
    const pm = premulMask(space);
    for (0..3) |i| {
        if (pm & (@as(u3, 1) << @intCast(i)) != 0) {
            x.c[i] *= x.c[3];
            y.c[i] *= y.c[3];
        }
    }
    if (hueIndex(space)) |hi| {
        const d = y.c[hi] - x.c[hi];
        switch (hue) {
            .shorter => if (d > 180) {
                x.c[hi] += 360;
            } else if (d < -180) {
                y.c[hi] += 360;
            },
            .longer => if (d > 0 and d < 180) {
                x.c[hi] += 360;
            } else if (d > -180 and d <= 0) {
                y.c[hi] += 360;
            },
            .increasing => if (d < 0) {
                y.c[hi] += 360;
            },
            .decreasing => if (d > 0) {
                x.c[hi] += 360;
            },
        }
    }
    const tt: f64 = t;
    var r: [4]f64 = undefined;
    for (0..4) |i| r[i] = x.c[i] + (y.c[i] - x.c[i]) * tt;
    if (r[3] != 0) {
        for (0..3) |i| {
            if (pm & (@as(u3, 1) << @intCast(i)) != 0) r[i] /= r[3];
        }
    }
    return toColor(space, .{ r[0], r[1], r[2] }, r[3] * alpha_mul);
}

/// takumi `Color::interpolate` (used per LUT sample by gradients in non-legacy spaces).
pub fn interpolate(a: Color, b: Color, t: f32, space: Space, hue: HueMethod) Color {
    if (a.eql(b)) return a;
    if (t <= std.math.floatEps(f32)) return a;
    if (t >= 1 - std.math.floatEps(f32)) return b;
    return interpolateEx(a, b, t, space, hue, 1);
}

/// One modern component: number, percentage (scaled by `pct_scale` per 100%), `none`, or (when
/// `hue`) an angle. Returns null on anything else.
fn modernComp(t: Token, pct_scale: f64, hue: bool) ?struct { v: f64, none: bool = false } {
    switch (t.kind) {
        .number => return .{ .v = t.num },
        .percentage => return if (hue) null else .{ .v = @as(f64, t.num) / 100 * pct_scale },
        .dimension => {
            if (!hue) return null;
            const f = angleFactor(t.text) orelse return null;
            return .{ .v = @as(f64, t.num) * f };
        },
        .ident => return if (std.ascii.eqlIgnoreCase(t.text, "none")) .{ .v = 0, .none = true } else null,
        else => return null,
    }
}

/// Pinned Takumi's keyword-only relative colours. Origins are computed rgba8 colours;
/// calc() channels and color(from ...) are outside that implementation's syntax.
fn parseRelative(l: *Lexer, space: Space, depth: u32) ?Color {
    const origin = colorOf(l.next(), depth) orelse return null;
    var values = convert(.srgb, space, .{
        @as(f64, @floatFromInt(origin.r)) / 255,
        @as(f64, @floatFromInt(origin.g)) / 255,
        @as(f64, @floatFromInt(origin.b)) / 255,
    });
    const scales: [3]f64 = switch (space) {
        .srgb => .{ 255, 255, 255 },
        .hsl, .hwb => .{ 1, 100, 100 },
        else => .{ 1, 1, 1 },
    };
    for (&values, scales) |*v, scale| v.* *= scale;
    const channels: [3][]const u8 = switch (space) {
        .srgb => .{ "r", "g", "b" }, .hsl => .{ "h", "s", "l" },
        .hwb => .{ "h", "w", "b" }, .lab, .oklab => .{ "l", "a", "b" },
        .lch, .oklch => .{ "l", "c", "h" }, else => unreachable,
    };
    const pct: [3]f64 = switch (space) {
        .srgb => .{ 255, 255, 255 }, .hsl, .hwb => .{ 100, 100, 100 },
        .lab => .{ 100, 125, 125 }, .lch => .{ 100, 150, 1 },
        .oklab => .{ 1, 0.4, 0.4 }, .oklch => .{ 1, 0.4, 1 }, else => unreachable,
    };
    const alpha: f64 = @as(f64, @floatFromInt(origin.a)) / 255;
    const slot = struct {
        fn read(t: Token, ns: [3][]const u8, vs: [3]f64, a: f64, percentage: f64, hue: bool) ?f64 {
            if (t.isIdent("alpha")) return a;
            if (t.kind == .ident) for (ns, vs) |name, v| {
                if (t.isIdent(name)) return v;
            };
            return (modernComp(t, percentage, hue) orelse return null).v;
        }
    }.read;
    var out: [3]f64 = undefined;
    for (&out, 0..) |*v, i| v.* = (slot(l.next(), channels, values, alpha, pct[i], hueIndex(space) == i) orelse return null) / scales[i];
    var a = alpha;
    const end = l.next();
    if (end.kind == .slash) {
        a = slot(l.next(), channels, values, alpha, 1, false) orelse return null;
        if (!l.atEnd()) return null;
    } else if (end.kind != .eof) return null;
    return toColor(space, out, std.math.clamp(a, 0, 1));
}

/// `c1 c2 c3 [/ alpha]` with per-slot percentage scales; slot 2 is a hue when `hue2`.
fn modernArgs(l: *Lexer, scales: [3]f64, hue2: bool) ?[4]f64 {
    var out: [4]f64 = .{ 0, 0, 0, 1 };
    for (0..3) |i| {
        const c = modernComp(l.next(), scales[i], hue2 and i == 2) orelse return null;
        out[i] = c.v;
    }
    const t = l.next();
    if (t.kind == .slash) {
        const a = modernComp(l.next(), 1, false) orelse return null;
        out[3] = if (a.none) 0 else std.math.clamp(a.v, 0, 1);
        if (l.next().kind != .eof) return null;
    } else if (t.kind != .eof) return null;
    for (out) |v| if (v != v or @abs(v) > 1.0e30) return null;
    return out;
}

/// fi: 0 lab, 1 lch, 2 oklab, 3 oklch, 4 color, 5 color-mix, 6 light-dark.
noinline fn parseModern(fi: usize, args: []const u8, depth: u32) ?Color {
    var l = Lexer.init(args);
    switch (fi) {
        0...3 => {
            const ok = fi >= 2;
            const lmax: f64 = if (ok) 1 else 100;
            const ab: f64 = if (ok) 0.4 else 125;
            const polar = fi == 1 or fi == 3;
            const cs: f64 = if (ok) 0.4 else 125; // color crate: lch 100% chroma = 125 (not 150)
            var v = modernArgs(&l, .{ lmax, if (polar) cs else ab, ab }, polar) orelse return null;
            v[0] = std.math.clamp(v[0], 0, lmax);
            if (polar) v[1] = @max(v[1], 0);
            const space: Space = switch (fi) {
                0 => .lab,
                1 => .lch,
                2 => .oklab,
                else => .oklch,
            };
            return toColor(space, .{ v[0], v[1], v[2] }, v[3]);
        },
        4 => {
            const st = l.next();
            if (st.kind != .ident) return null;
            const space = spaceFromIdent(st) orelse return null;
            if (@backingInt(space) > @backingInt(Space.xyz_d65)) return null;
            const v = modernArgs(&l, .{ 1, 1, 1 }, false) orelse return null;
            return toColor(space, .{ v[0], v[1], v[2] }, v[3]);
        },
        5 => {
            if (!l.next().isIdent("in")) return null;
            const m = parseInterpolationMethod(&l) orelse return null;
            var cols: [2]Color = undefined;
            var pcts: [2]?f32 = .{ null, null };
            for (0..2) |i| {
                if (l.next().kind != .comma) return null;
                var t = l.next();
                if (mixPct(t)) |p| {
                    pcts[i] = p;
                    t = l.next();
                    cols[i] = colorOf(t, depth + 1) orelse return null;
                } else {
                    cols[i] = colorOf(t, depth + 1) orelse return null;
                    if (mixPct(l.peek())) |p| {
                        _ = l.next();
                        pcts[i] = p;
                    }
                }
            }
            if (!l.atEnd()) return null;
            var p1: f32 = 0.5;
            var p2: f32 = 0.5;
            if (pcts[0]) |a| {
                p1 = a;
                p2 = pcts[1] orelse @max(1 - a, 0);
            } else if (pcts[1]) |b| {
                p2 = b;
                p1 = @max(1 - b, 0);
            }
            const sum = p1 + p2;
            if (!(sum > std.math.floatEps(f32))) return null;
            return interpolateEx(cols[0], cols[1], p2 / sum, m.space, m.hue, @min(sum, 1));
        },
        else => {
            // light-dark(light, dark): no colour scheme -> the light colour.
            const a = colorOf(l.next(), depth + 1) orelse return null;
            if (l.next().kind != .comma) return null;
            _ = colorOf(l.next(), depth + 1) orelse return null;
            if (!l.atEnd()) return null;
            return a;
        },
    }
}

/// color-mix percentage: `<number>` (a fraction, as takumi's PercentageNumber) or `<percentage>`.
fn mixPct(t: Token) ?f32 {
    const v: f32 = switch (t.kind) {
        .number => t.num,
        .percentage => t.num / 100,
        else => return null,
    };
    if (!(v >= 0 and v <= 1.0e6)) return null;
    return v;
}

// ---- named colours (CSS Color 4, 148 names), sorted for binary search ----
const Named = struct { n: []const u8, c: u32 };
const names = [_]Named{
    .{ .n = "aliceblue", .c = 0xf0f8ff },            .{ .n = "antiquewhite", .c = 0xfaebd7 },
    .{ .n = "aqua", .c = 0x00ffff },                 .{ .n = "aquamarine", .c = 0x7fffd4 },
    .{ .n = "azure", .c = 0xf0ffff },                .{ .n = "beige", .c = 0xf5f5dc },
    .{ .n = "bisque", .c = 0xffe4c4 },               .{ .n = "black", .c = 0x000000 },
    .{ .n = "blanchedalmond", .c = 0xffebcd },       .{ .n = "blue", .c = 0x0000ff },
    .{ .n = "blueviolet", .c = 0x8a2be2 },           .{ .n = "brown", .c = 0xa52a2a },
    .{ .n = "burlywood", .c = 0xdeb887 },            .{ .n = "cadetblue", .c = 0x5f9ea0 },
    .{ .n = "chartreuse", .c = 0x7fff00 },           .{ .n = "chocolate", .c = 0xd2691e },
    .{ .n = "coral", .c = 0xff7f50 },                .{ .n = "cornflowerblue", .c = 0x6495ed },
    .{ .n = "cornsilk", .c = 0xfff8dc },             .{ .n = "crimson", .c = 0xdc143c },
    .{ .n = "cyan", .c = 0x00ffff },                 .{ .n = "darkblue", .c = 0x00008b },
    .{ .n = "darkcyan", .c = 0x008b8b },             .{ .n = "darkgoldenrod", .c = 0xb8860b },
    .{ .n = "darkgray", .c = 0xa9a9a9 },             .{ .n = "darkgreen", .c = 0x006400 },
    .{ .n = "darkgrey", .c = 0xa9a9a9 },             .{ .n = "darkkhaki", .c = 0xbdb76b },
    .{ .n = "darkmagenta", .c = 0x8b008b },          .{ .n = "darkolivegreen", .c = 0x556b2f },
    .{ .n = "darkorange", .c = 0xff8c00 },           .{ .n = "darkorchid", .c = 0x9932cc },
    .{ .n = "darkred", .c = 0x8b0000 },              .{ .n = "darksalmon", .c = 0xe9967a },
    .{ .n = "darkseagreen", .c = 0x8fbc8f },         .{ .n = "darkslateblue", .c = 0x483d8b },
    .{ .n = "darkslategray", .c = 0x2f4f4f },        .{ .n = "darkslategrey", .c = 0x2f4f4f },
    .{ .n = "darkturquoise", .c = 0x00ced1 },        .{ .n = "darkviolet", .c = 0x9400d3 },
    .{ .n = "deeppink", .c = 0xff1493 },             .{ .n = "deepskyblue", .c = 0x00bfff },
    .{ .n = "dimgray", .c = 0x696969 },              .{ .n = "dimgrey", .c = 0x696969 },
    .{ .n = "dodgerblue", .c = 0x1e90ff },           .{ .n = "firebrick", .c = 0xb22222 },
    .{ .n = "floralwhite", .c = 0xfffaf0 },          .{ .n = "forestgreen", .c = 0x228b22 },
    .{ .n = "fuchsia", .c = 0xff00ff },              .{ .n = "gainsboro", .c = 0xdcdcdc },
    .{ .n = "ghostwhite", .c = 0xf8f8ff },           .{ .n = "gold", .c = 0xffd700 },
    .{ .n = "goldenrod", .c = 0xdaa520 },            .{ .n = "gray", .c = 0x808080 },
    .{ .n = "green", .c = 0x008000 },                .{ .n = "greenyellow", .c = 0xadff2f },
    .{ .n = "grey", .c = 0x808080 },                 .{ .n = "honeydew", .c = 0xf0fff0 },
    .{ .n = "hotpink", .c = 0xff69b4 },              .{ .n = "indianred", .c = 0xcd5c5c },
    .{ .n = "indigo", .c = 0x4b0082 },               .{ .n = "ivory", .c = 0xfffff0 },
    .{ .n = "khaki", .c = 0xf0e68c },                .{ .n = "lavender", .c = 0xe6e6fa },
    .{ .n = "lavenderblush", .c = 0xfff0f5 },        .{ .n = "lawngreen", .c = 0x7cfc00 },
    .{ .n = "lemonchiffon", .c = 0xfffacd },         .{ .n = "lightblue", .c = 0xadd8e6 },
    .{ .n = "lightcoral", .c = 0xf08080 },           .{ .n = "lightcyan", .c = 0xe0ffff },
    .{ .n = "lightgoldenrodyellow", .c = 0xfafad2 }, .{ .n = "lightgray", .c = 0xd3d3d3 },
    .{ .n = "lightgreen", .c = 0x90ee90 },           .{ .n = "lightgrey", .c = 0xd3d3d3 },
    .{ .n = "lightpink", .c = 0xffb6c1 },            .{ .n = "lightsalmon", .c = 0xffa07a },
    .{ .n = "lightseagreen", .c = 0x20b2aa },        .{ .n = "lightskyblue", .c = 0x87cefa },
    .{ .n = "lightslategray", .c = 0x778899 },       .{ .n = "lightslategrey", .c = 0x778899 },
    .{ .n = "lightsteelblue", .c = 0xb0c4de },       .{ .n = "lightyellow", .c = 0xffffe0 },
    .{ .n = "lime", .c = 0x00ff00 },                 .{ .n = "limegreen", .c = 0x32cd32 },
    .{ .n = "linen", .c = 0xfaf0e6 },                .{ .n = "magenta", .c = 0xff00ff },
    .{ .n = "maroon", .c = 0x800000 },               .{ .n = "mediumaquamarine", .c = 0x66cdaa },
    .{ .n = "mediumblue", .c = 0x0000cd },           .{ .n = "mediumorchid", .c = 0xba55d3 },
    .{ .n = "mediumpurple", .c = 0x9370db },         .{ .n = "mediumseagreen", .c = 0x3cb371 },
    .{ .n = "mediumslateblue", .c = 0x7b68ee },      .{ .n = "mediumspringgreen", .c = 0x00fa9a },
    .{ .n = "mediumturquoise", .c = 0x48d1cc },      .{ .n = "mediumvioletred", .c = 0xc71585 },
    .{ .n = "midnightblue", .c = 0x191970 },         .{ .n = "mintcream", .c = 0xf5fffa },
    .{ .n = "mistyrose", .c = 0xffe4e1 },            .{ .n = "moccasin", .c = 0xffe4b5 },
    .{ .n = "navajowhite", .c = 0xffdead },          .{ .n = "navy", .c = 0x000080 },
    .{ .n = "oldlace", .c = 0xfdf5e6 },              .{ .n = "olive", .c = 0x808000 },
    .{ .n = "olivedrab", .c = 0x6b8e23 },            .{ .n = "orange", .c = 0xffa500 },
    .{ .n = "orangered", .c = 0xff4500 },            .{ .n = "orchid", .c = 0xda70d6 },
    .{ .n = "palegoldenrod", .c = 0xeee8aa },        .{ .n = "palegreen", .c = 0x98fb98 },
    .{ .n = "paleturquoise", .c = 0xafeeee },        .{ .n = "palevioletred", .c = 0xdb7093 },
    .{ .n = "papayawhip", .c = 0xffefd5 },           .{ .n = "peachpuff", .c = 0xffdab9 },
    .{ .n = "peru", .c = 0xcd853f },                 .{ .n = "pink", .c = 0xffc0cb },
    .{ .n = "plum", .c = 0xdda0dd },                 .{ .n = "powderblue", .c = 0xb0e0e6 },
    .{ .n = "purple", .c = 0x800080 },               .{ .n = "rebeccapurple", .c = 0x663399 },
    .{ .n = "red", .c = 0xff0000 },                  .{ .n = "rosybrown", .c = 0xbc8f8f },
    .{ .n = "royalblue", .c = 0x4169e1 },            .{ .n = "saddlebrown", .c = 0x8b4513 },
    .{ .n = "salmon", .c = 0xfa8072 },               .{ .n = "sandybrown", .c = 0xf4a460 },
    .{ .n = "seagreen", .c = 0x2e8b57 },             .{ .n = "seashell", .c = 0xfff5ee },
    .{ .n = "sienna", .c = 0xa0522d },               .{ .n = "silver", .c = 0xc0c0c0 },
    .{ .n = "skyblue", .c = 0x87ceeb },              .{ .n = "slateblue", .c = 0x6a5acd },
    .{ .n = "slategray", .c = 0x708090 },            .{ .n = "slategrey", .c = 0x708090 },
    .{ .n = "snow", .c = 0xfffafa },                 .{ .n = "springgreen", .c = 0x00ff7f },
    .{ .n = "steelblue", .c = 0x4682b4 },            .{ .n = "tan", .c = 0xd2b48c },
    .{ .n = "teal", .c = 0x008080 },                 .{ .n = "thistle", .c = 0xd8bfd8 },
    .{ .n = "tomato", .c = 0xff6347 },               .{ .n = "transparent", .c = 0xffffffff },
    .{ .n = "turquoise", .c = 0x40e0d0 },            .{ .n = "violet", .c = 0xee82ee },
    .{ .n = "wheat", .c = 0xf5deb3 },                .{ .n = "white", .c = 0xffffff },
    .{ .n = "whitesmoke", .c = 0xf5f5f5 },           .{ .n = "yellow", .c = 0xffff00 },
    .{ .n = "yellowgreen", .c = 0x9acd32 },
};

// Runtime form of `names`: one concatenated string + u16 offsets + packed RGB (the slice table
// above is only used at comptime and in tests).
const color_pack: []const u8 = blk: {
    @setEvalBranchQuota(20000);
    var out: []const u8 = "";
    for (names) |n| out = out ++ n.n;
    break :blk out;
};
const color_off: [names.len + 1]u16 = blk: {
    var o: [names.len + 1]u16 = undefined;
    var k: usize = 0;
    for (names, 0..) |n, i| {
        o[i] = k;
        k += n.n.len;
    }
    o[names.len] = k;
    break :blk o;
};
const color_rgb: [names.len]u32 = blk: {
    var o: [names.len]u32 = undefined;
    for (names, 0..) |n, i| o[i] = n.c;
    break :blk o;
};

/// Case-insensitive named-colour lookup (includes `transparent`).
pub fn named(name: []const u8) ?Color {
    if (name.len < 3 or name.len > 20) return null;
    var buf: [20]u8 = undefined;
    const low = std.ascii.lowerString(&buf, name);
    var lo: usize = 0;
    var hi: usize = names.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, color_pack[color_off[mid]..color_off[mid + 1]], low)) {
            .eq => {
                const c = color_rgb[mid];
                if (c == 0xffffffff) return Color.transparent;
                return .{ .r = @truncate(c >> 16), .g = @truncate(c >> 8), .b = @truncate(c), .a = 255 };
            },
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

// ---------------------------------------------------------------------------------------------
const t_ = std.testing;

fn expectColor(s: []const u8, r: u8, g: u8, b: u8, a: u8) !void {
    const v = parse(s) catch |e| {
        std.debug.print("colour '{s}' failed: {}\n", .{ s, e });
        return e;
    };
    try t_.expect(v == .rgba);
    t_.expect(v.rgba.eql(.{ .r = r, .g = g, .b = b, .a = a })) catch |e| {
        std.debug.print("colour '{s}' = {any}\n", .{ s, v.rgba });
        return e;
    };
}

test "named table sorted and complete" {
    try t_.expectEqual(@as(usize, 149), names.len); // 148 + transparent
    for (1..names.len) |i| try t_.expect(std.mem.order(u8, names[i - 1].n, names[i].n) == .lt);
    for (names) |n| try t_.expect(named(n.n) != null);
}

test "colour vectors" {
    try expectColor("#f00", 255, 0, 0, 255);
    try expectColor("#0f08", 0, 255, 0, 136);
    try expectColor("#123456", 0x12, 0x34, 0x56, 255);
    try expectColor("#12345678", 0x12, 0x34, 0x56, 0x78);
    try expectColor("#ABCDEF", 0xab, 0xcd, 0xef, 255);
    try expectColor("red", 255, 0, 0, 255);
    try expectColor("RebeccaPurple", 0x66, 0x33, 0x99, 255);
    try expectColor("transparent", 0, 0, 0, 0);
    try expectColor("rgb(255, 0, 0)", 255, 0, 0, 255);
    try expectColor("rgba(255,0,0,0.5)", 255, 0, 0, 128);
    try expectColor("rgb(255 0 0 / 50%)", 255, 0, 0, 128);
    try expectColor("rgb(100% 50% 0%)", 255, 128, 0, 255);
    try expectColor("rgba(0 0 0 / .35)", 0, 0, 0, 89);
    try expectColor("rgb(300 -5 12.6)", 255, 0, 13, 255);
    try expectColor("rgb(255 0 0 / 2)", 255, 0, 0, 255);
    try expectColor("rgb(none 0 0)", 0, 0, 0, 255);
    try expectColor("rgba(255,0,0)", 255, 0, 0, 255);
    try expectColor("rgb(10 20 30 / 0)", 10, 20, 30, 0);
    try expectColor("hsl(120deg 100% 25%)", 0, 128, 0, 255);
    try expectColor("hsl(0, 100%, 50%)", 255, 0, 0, 255);
    try expectColor("hsla(240, 100%, 50%, 0.5)", 0, 0, 255, 128);
    try expectColor("hsl(0.5turn 100% 50%)", 0, 255, 255, 255);
    try expectColor("hsl(-120 100% 50%)", 0, 0, 255, 255);
    try expectColor("hsl(60 100 50)", 255, 255, 0, 255);
    try expectColor("hwb(0 0% 0%)", 255, 0, 0, 255);
    try expectColor("hwb(120 50% 50%)", 128, 128, 128, 255);
    try expectColor("hwb(240 20% 30% / 0.5)", 51, 51, 179, 128);
    const cc = try parse("currentColor");
    try t_.expect(cc == .current);
    try t_.expect((try parse("CURRENTCOLOR")) == .current);
}

test "colour errors" {
    const bad = [_][]const u8{
        "#ff",          "#fffff",             "#ggg",         "rgb(1,2)",        "rgb(1 2 3 4)",
        "rgb(1,2 3)",   "rgb(1, 2, 3, 4, 5)", "rgb(1px 2 3)", "hsl(1%, 2%, 3%)", "notacolor",
        "rgb(1 2 3 /)", "hwb(1, 2%, 3%)",     "rgb()",        "red blue",        "rgb(1 2 3 / 4 / 5)",
    };
    for (bad) |s| {
        if (parse(s)) |v| {
            std.debug.print("expected failure for '{s}', got {any}\n", .{ s, v });
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

/// (css, r, g, b, a) — every entry verified against @takumi-rs/wasm 2.20.0 (bench/probe/style/colors.mjs).
const modern_vectors = [_]struct { []const u8, u8, u8, u8, u8 }{
    .{ "lab(50 20 30)", 161, 105, 69, 255 },
    .{ "lab(50% 40 -60)", 140, 94, 223, 255 },
    .{ "lab(29.2345 39.3825 20.0664)", 125, 35, 41, 255 },
    .{ "lab(75 -20 80)", 178, 194, 0, 255 },
    .{ "lab(150 0 0)", 255, 255, 255, 255 },
    .{ "lab(-10 0 0)", 0, 0, 0, 255 },
    .{ "lab(50 125% -125%)", 228, 0, 255, 255 },
    .{ "lch(50 30 270)", 93, 120, 170, 255 },
    .{ "lch(62% 40 130deg)", 116, 162, 93, 255 },
    .{ "lch(50 -20 30)", 119, 119, 119, 255 },
    .{ "lch(70 50% 0.5turn)", 0, 199, 169, 255 },
    .{ "hsl(0 0% 50%)", 128, 128, 128, 255 },
    .{ "hsl(90 100% 50%)", 127, 255, 0, 255 },
    .{ "hsl(210 100% 50%)", 0, 128, 255, 255 },
    .{ "hsl(330 50% 50%)", 191, 64, 127, 255 },
    .{ "hwb(0 50% 50%)", 128, 128, 128, 255 },
    .{ "hsl(30 100% 50%)", 255, 128, 0, 255 },
    .{ "hsl(270 100% 50%)", 128, 0, 255, 255 },
    .{ "hsl(150 100% 50%)", 0, 255, 128, 255 },
    .{ "hsl(45 100% 75%)", 255, 223, 128, 255 },
    .{ "hwb(90 0% 0%)", 127, 255, 0, 255 },
    .{ "hsl(0 100% 25%)", 128, 0, 0, 255 },
    .{ "hsl(-30 60% 40%)", 163, 41, 102, 255 },
    .{ "hsl(400 70% 45%)", 195, 142, 34, 255 },
    .{ "hwb(200 10% 20%)", 25, 144, 204, 255 },
    .{ "lch(40 60 none)", 176, 29, 97, 255 },
    .{ "oklab(0.5 0.1 -0.1)", 129, 69, 154, 255 },
    .{ "oklab(50% 0.1 -0.1)", 129, 69, 154, 255 },
    .{ "oklab(0.8 -40% 30%)", 97, 221, 95, 255 },
    .{ "oklab(1.2 0 0)", 255, 255, 255, 255 },
    .{ "oklch(0.7 0.15 30)", 237, 118, 101, 255 },
    .{ "oklch(0.628 0.2577 29.23)", 255, 0, 0, 255 },
    .{ "oklch(60% 0.2 250)", 0, 129, 241, 255 },
    .{ "oklch(0.9 0.3 140)", 75, 255, 0, 255 },
    .{ "oklch(0.5 none 100)", 99, 99, 99, 255 },
    .{ "oklch(0.45 0.1 3.14rad)", 0, 103, 87, 255 },
    .{ "color(srgb 1 0.5 0)", 255, 128, 0, 255 },
    .{ "color(srgb 100% 50% 0%)", 255, 128, 0, 255 },
    .{ "color(srgb-linear 0.5 0.2 0.1)", 188, 124, 89, 255 },
    .{ "color(display-p3 1 0 0)", 255, 0, 0, 255 },
    .{ "color(display-p3 0.2 0.7 0.4)", 0, 182, 93, 255 },
    .{ "color(a98-rgb 0.3 0.6 0.9)", 0, 154, 233, 255 },
    .{ "color(prophoto-rgb 0.4 0.5 0.6)", 69, 151, 173, 255 },
    .{ "color(rec2020 0.6 0.3 0.2)", 194, 77, 60, 255 },
    .{ "color(xyz 0.2 0.3 0.4)", 0, 167, 164, 255 },
    .{ "color(xyz-d50 0.2 0.3 0.4)", 0, 168, 189, 255 },
    .{ "color(xyz-d65 0.5 0.5 0.5)", 204, 183, 180, 255 },
    .{ "color(srgb none 1 1)", 0, 255, 255, 255 },
    .{ "color-mix(in srgb, red, blue)", 128, 0, 128, 255 },
    .{ "color-mix(in srgb, red 25%, blue)", 64, 0, 191, 255 },
    .{ "color-mix(in srgb, red 30%, blue 30%)", 128, 0, 128, 153 },
    .{ "color-mix(in oklab, red, blue)", 140, 83, 162, 255 },
    .{ "color-mix(in oklch, red, blue)", 186, 0, 194, 255 },
    .{ "color-mix(in lab, #ff8800 30%, teal)", 123, 134, 101, 255 },
    .{ "color-mix(in lch, purple, plum)", 175, 92, 174, 255 },
    .{ "color-mix(in hsl shorter hue, hsl(50deg 50% 50%), hsl(330deg 50% 50%))", 191, 86, 64, 255 },
    .{ "color-mix(in hsl longer hue, hsl(50deg 50% 50%), hsl(330deg 50% 50%))", 64, 169, 191, 255 },
    .{ "color-mix(in hwb, red, blue 40%)", 255, 0, 204, 255 },
    .{ "color-mix(in srgb-linear, red, blue)", 188, 0, 188, 255 },
    .{ "color-mix(in xyz, white, black)", 188, 188, 188, 255 },
    .{ "color-mix(in display-p3, lime, blue)", 18, 128, 164, 255 },
    .{ "color-mix(in oklch, white, blue)", 116, 163, 255, 255 },
    .{ "color-mix(in oklch decreasing hue, red, blue)", 186, 0, 194, 255 },
    .{ "color-mix(in srgb, red 120%, blue 80%)", 153, 0, 102, 255 },
    .{ "color-mix(in srgb, red 0.5, blue 0.5)", 128, 0, 128, 255 },
    .{ "color-mix(in oklab, rgba(255,0,0,0.5), blue)", 101, 78, 194, 192 },
    .{ "color-mix(in srgb, color-mix(in srgb, red, blue), white)", 192, 128, 192, 255 },
    .{ "light-dark(red, blue)", 255, 0, 0, 255 },
    .{ "oklch(0.597 0.105 195.2)", 0, 146, 147, 255 },
    .{ "oklab(0.036 -0.097 -0.210)", 18, 0, 66, 255 },
    .{ "hsl(83.4 19.2% 61.7%)", 161, 176, 139, 255 },
    .{ "lch(25.67 29.48 178.4)", 0, 72, 59, 255 },
    .{ "color-mix(in lch, rgb(79,177,28) 84%, rgb(90,70,156))", 0, 170, 89, 255 },
    .{ "lab(16.03 19.71 16.34)", 68, 27, 17, 255 },
    .{ "color(srgb 0.726 0.744 0.059)", 185, 190, 15, 255 },
    .{ "oklch(0.105 0.181 18.3)", 43, 0, 0, 255 },
    .{ "oklab(0.020 -0.185 0.151)", 0, 5, 0, 255 },
    .{ "hsl(38.4 28.1% 99.6%)", 254, 254, 254, 255 },
    .{ "lch(87.56 122.61 69.8)", 255, 185, 0, 255 },
    .{ "color-mix(in lab, rgb(85,28,254) 75%, rgb(2,113,213))", 77, 60, 244, 255 },
    .{ "lab(28.14 51.46 80.54)", 140, 0, 0, 255 },
    .{ "color(rec2020 0.727 0.026 0.049)", 241, 0, 7, 255 },
    .{ "oklch(0.163 0.077 24.8)", 39, 0, 0, 255 },
    .{ "oklab(0.308 0.166 0.067)", 112, 0, 0, 255 },
    .{ "hsl(45.3 32.0% 39.4%)", 133, 117, 68, 255 },
    .{ "lch(67.71 67.16 89.1)", 190, 163, 20, 255 },
    .{ "color-mix(in srgb-linear, rgb(218,10,222) 86%, rgb(100,183,234))", 207, 74, 224, 255 },
    .{ "lab(30.07 -78.19 60.92)", 0, 92, 0, 255 },
    .{ "color(xyz-d50 0.205 0.212 0.938)", 0, 134, 255, 255 },
    .{ "oklch(0.304 0.003 132.1)", 46, 47, 46, 255 },
    .{ "oklab(0.055 -0.039 0.110)", 1, 1, 0, 255 },
    .{ "hsl(106.8 44.7% 61.4%)", 132, 201, 113, 255 },
    .{ "lch(95.65 37.29 102.3)", 247, 246, 171, 255 },
    .{ "color-mix(in rec2020, rgb(204,36,165) 76%, rgb(207,197,199))", 208, 85, 174, 255 },
    .{ "lab(46.37 -88.69 82.46)", 0, 138, 0, 255 },
    .{ "color(display-p3 0.048 0.409 0.982)", 0, 106, 255, 255 },
    .{ "oklch(0.238 0.300 153.9)", 0, 56, 0, 255 },
    .{ "oklab(0.493 -0.017 0.001)", 88, 101, 97, 255 },
    .{ "hsl(44.1 94.2% 75.9%)", 251, 221, 136, 255 },
    .{ "lch(67.45 8.80 264.5)", 157, 165, 180, 255 },
    .{ "color-mix(in lch, rgb(77,248,234) 99%, rgb(96,70,0))", 77, 246, 231, 255 },
    .{ "lab(86.70 43.30 39.50)", 255, 183, 145, 255 },
    .{ "color(rec2020 0.230 0.360 0.837)", 0, 108, 227, 255 },
    .{ "oklch(0.177 0.011 31.0)", 21, 15, 14, 255 },
    .{ "oklab(0.801 0.184 -0.155)", 255, 128, 255, 255 },
    .{ "hsl(101.7 28.2% 84.6%)", 211, 227, 205, 255 },
    .{ "lch(64.79 83.37 254.4)", 0, 174, 255, 255 },
    .{ "color-mix(in prophoto-rgb, rgb(205,253,177) 53%, rgb(0,5,149))", 141, 158, 168, 255 },
    .{ "lab(53.53 12.08 45.17)", 162, 119, 47, 255 },
    .{ "color(rec2020 0.690 0.656 0.439)", 192, 175, 117, 255 },
};
const modern_bad = [_][]const u8{ "color-mix(in srgb, currentColor, red)", "color-mix(in srgb longer hue, red, blue)", "color-mix(in srgb, red 0%, blue 0%)", "lab(50 20)", "oklch(0.5 0.1 10%)", "color(foo 1 1 1)", "canvastext" };

test "modern colour vectors (oracle-checked)" {
    for (modern_vectors) |v| try expectColor(v[0], v[1], v[2], v[3], v[4]);
    for (modern_bad) |b| try t_.expectError(error.InvalidStyleValue, parse(b));
    const more_bad = [_][]const u8{
        "lab(50 20 30 40)",        "lab(50, 20, 30)",                    "oklch(0.5 0.1 20deg / 1 / 1)",         "color(srgb 1 1)",              "color(lab 1 1 1)",
        "color-mix(in srgb, red)", "color-mix(srgb, red, blue)",         "color-mix(in srgb, red, blue, green)", "color-mix(in srgb red, blue)", "light-dark(red)",
        "lab(calc(10) 1 1)",       "color-mix(in srgb, red -10%, blue)", "lch(50 20 30%)",
    };
    for (more_bad) |b| try t_.expectError(error.InvalidStyleValue, parse(b));
    // currentColor is still a top-level colour; nesting depth is bounded
    try t_.expect((try parse("currentcolor")) == .current);
    var deep: [8192]u8 = undefined;
    var n: usize = 0;
    for (0..200) |_| {
        const p = "color-mix(in srgb, red, ";
        @memcpy(deep[n..][0..p.len], p);
        n += p.len;
    }
    try t_.expectError(error.InvalidStyleValue, parse(deep[0..n]));
}

test {
    _ = cmath;
}

test "isModernColorToken / interpolation method" {
    var l = Lexer.init("oklch(1 0 0) rgb(1 2 3) COLOR-MIX(in srgb, red, blue) red");
    try t_.expect(isModernColorToken(l.next()));
    try t_.expect(!isModernColorToken(l.next()));
    try t_.expect(isModernColorToken(l.next()));
    try t_.expect(!isModernColorToken(l.next()));
    var m = Lexer.init("oklch longer hue");
    const r = parseInterpolationMethod(&m).?;
    try t_.expect(r.space == .oklch and r.hue == .longer);
    var m2 = Lexer.init("srgb longer hue");
    try t_.expect(parseInterpolationMethod(&m2) == null);
    var m3 = Lexer.init("xyz");
    try t_.expect(parseInterpolationMethod(&m3).?.space == .xyz_d65);
    // interpolate endpoints and identical colours
    const red: Color = .{ .r = 255, .a = 255 };
    const blue: Color = .{ .b = 255, .a = 255 };
    try t_.expect(interpolate(red, blue, 0, .oklab, .shorter).eql(red));
    try t_.expect(interpolate(red, blue, 1, .oklab, .shorter).eql(blue));
    try t_.expect(interpolate(red, red, 0.5, .lch, .longer).eql(red));
    try t_.expect(interpolate(red, blue, 0.5, .oklab, .shorter).eql(.{ .r = 140, .g = 83, .b = 162, .a = 255 }));
}

test "fuzz: modern colour parsers never crash" {
    var prng = std.Random.DefaultPrng.init(0xc010);
    const rnd = prng.random();
    const seeds = [_][]const u8{
        "lab(50 20 30 / 0.5)",   "oklch(0.7 0.15 30deg)",      "color(display-p3 1 0 0)",     "color-mix(in oklch longer hue, red 20%, lab(50 1 2))",
        "light-dark(red, blue)", "lch(none none none / none)", "color(xyz-d50 1e30 -1e30 0)", "color-mix(in hsl, color-mix(in lab, red, blue), 50% white)",
    };
    const alphabet = "()/,% .-0123456789e+nonedegturnlabchoksrgbxyz";
    var buf: [80]u8 = undefined;
    for (0..20000) |_| {
        const seed = seeds[rnd.uintLessThan(usize, seeds.len)];
        var n: usize = @min(seed.len, buf.len);
        @memcpy(buf[0..n], seed[0..n]);
        for (0..3) |_| {
            if (n == 0) break;
            const pos = rnd.uintLessThan(usize, n);
            switch (rnd.uintLessThan(u8, 3)) {
                0 => buf[pos] = alphabet[rnd.uintLessThan(usize, alphabet.len)],
                1 => n = pos,
                else => buf[pos] = rnd.int(u8),
            }
        }
        _ = parse(buf[0..n]) catch {};
    }
}
