//! Text-control shadow editors (takumi-core layout/text_control.rs). Generated after the
//! authored cascade so document selectors cannot match the editor or expose password text.
const std = @import("std");
const render = @import("render.zig");
const dom = @import("dom.zig");
const style = @import("style/style.zig");
const font = @import("font/font.zig");

const CS = render.CS;
const LP = style.LP;
const none = render.none;
const spaces = " \t\r\n\x0c";

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn textField(typ: []const u8) bool {
    for ([_][]const u8{ "text", "search", "tel", "url", "email", "password", "number" }) |name| if (eq(typ, name)) return true;
    // Unknown input types have the text state.
    for ([_][]const u8{ "hidden", "date", "month", "week", "time", "datetime-local", "range", "color", "checkbox", "radio", "file", "submit", "image", "reset", "button" }) |name| if (eq(typ, name)) return false;
    return true;
}

fn positive(s: ?[]const u8, fallback: u32) u32 {
    const raw = std.mem.trimStart(u8, s orelse return fallback, spaces);
    var i: usize = @intFromBool(raw.len > 0 and raw[0] == '+');
    const start = i;
    while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) {}
    if (i == start) return fallback;
    const n = std.fmt.parseInt(u32, raw[start..i], 10) catch return fallback;
    return if (n > 0 and n <= 0x7fff_ffff) n else fallback;
}

/// HTML valid floating-point syntax, stricter than parseFloat (no leading +, spaces or infinity).
fn validNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = @intFromBool(s[0] == '-');
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const first = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
        if (i == first) return false;
    }
    if (digits == 0) return false;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const first = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (first == i) return false;
    }
    if (i != s.len) return false;
    return std.math.isFinite(std.fmt.parseFloat(f64, s) catch return false);
}

fn inputValue(a: std.mem.Allocator, raw: []const u8, typ: []const u8) ![]const u8 {
    if (eq(typ, "number")) return if (validNumber(raw)) raw else "";
    var out: std.ArrayList(u8) = .empty;
    const value = if (eq(typ, "url")) std.mem.trim(u8, raw, spaces) else raw;
    for (value) |c| if (c != '\r' and c != '\n') try out.append(a, c);
    const cleaned = if (eq(typ, "email")) std.mem.trim(u8, out.items, spaces) else out.items;
    if (!eq(typ, "password")) return cleaned;
    var masked: std.ArrayList(u8) = .empty;
    // Upstream masks Unicode scalar values, not grapheme clusters.
    for (cleaned) |c| if (c & 0xc0 != 0x80) try masked.appendSlice(a, "\u{2022}");
    return masked.items;
}

fn content(d: *const dom.Dom, id: u32, a: std.mem.Allocator, out: *std.ArrayList(u8), depth: u32) !void {
    if (depth > 128) return;
    const el = d.at(id);
    if (el.kind == .text) try out.appendSlice(a, el.text);
    var c = el.first;
    while (c != none) : (c = d.at(c).next) try content(d, c, a, out, depth + 1);
}

fn areaValue(f: *render.Frame, id: u32) ![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    try content(&f.dom, id, f.a, &raw, 0);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.items.len) : (i += 1) {
        const c = raw.items[i];
        try out.append(f.a, if (c == '\r') '\n' else c);
        if (c == '\r' and i + 1 < raw.items.len and raw.items[i + 1] == '\n') i += 1;
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') try out.append(f.a, '\n');
    return out.items;
}

/// Blink's kFontFamiliesWithInvalidCharWidth (takumi text_control.rs): families whose average
/// character width does not size a text field. Only the first family is consulted.
const invalid_char_width_families = [_][]const u8{
    "American Typewriter", "Arial Hebrew",   "Chalkboard",    "Cochin",        "Corsiva Hebrew", "Courier",
    "Euphemia UCAS",       "Geneva",         "Gill Sans",     "Hei",           "Helvetica",      "Hoefler Text",
    "InaiMathi",           "Kai",            "Lucida Grande", "Marker Felt",   "Monaco",         "Mshtakan",
    "New Peninim MT",      "Osaka",          "Raanana",       "STHeiti",       "Symbol",         "Times",
    "Apple Braille",       "Apple LiGothic", "Apple LiSung",  "Apple Symbols", "AppleGothic",    "AppleMyungjo",
    "#GungSeo",            "#HeadLineA",     "#PCMyungjo",    "#PilGi",
};

fn validCharWidthFamily(families: []const []const u8) bool {
    if (families.len == 0 or families[0].len == 0) return false;
    for (invalid_char_width_families) |name| if (std.mem.eql(u8, families[0], name)) return false;
    return true;
}

/// The border and padding of `cs` along the block (`axis` 0) or inline (1) axis; percentages as 0.
fn borderPadding(cs: *const CS, axis: u1) f32 {
    const bw = cs.usedBorderWidths();
    const a: usize = if (axis == 0) 0 else 1;
    const b: usize = a + 2;
    return bw[a] + bw[b] + cs.padding[a].resolve(0) + cs.padding[b].resolve(0);
}

const Metrics = struct { char: f32, max_char: f32, line: f32 };
fn metrics(f: *render.Frame, cs: *const CS) Metrics {
    var out: Metrics = .{ .char = cs.font_size / 2, .max_char = 0, .line = cs.font_size * 1.2 };
    var faces: [64]font.FaceId = undefined;
    const matched = f.r.fonts.matchEx(.{ .families = cs.font_family, .weight = cs.font_weight, .italic = cs.font_style != .normal, .size = cs.font_size }, &faces);
    if (matched.len > 0) {
        const ft = f.r.fonts.font(matched[0]);
        const scale = cs.font_size / @as(f32, @floatFromInt(@max(1, ft.unitsPerEm())));
        const zero_gid = ft.glyphIndex('0');
        const zero = if (zero_gid != 0) @as(f32, @floatFromInt(ft.advanceWidth(zero_gid))) * scale else cs.font_size / 2;
        // takumi PrimaryFontMetrics: OS/2 xAvgCharWidth, else the `x` advance, else the x-height.
        var avg = if (ft.os2.len >= 4) @as(f32, @floatFromInt(std.mem.readInt(i16, ft.os2[2..4], .big))) * scale else 0;
        if (avg == 0) {
            const x = ft.glyphIndex('x');
            avg = if (x != 0) @as(f32, @floatFromInt(ft.advanceWidth(x))) * scale else @as(f32, @floatFromInt(ft.xHeight())) * scale;
        }
        if (!(zero_gid != 0 and avg > zero * 1.7) and validCharWidthFamily(cs.font_family)) {
            out.char = @max(avg, @round(avg));
            // Blink's MaxCharWidth outside Windows/Apple: the `head` bounding box width, whole pixels.
            if (ft.head.len >= 44) {
                const x_min = std.mem.readInt(i16, ft.head[36..38], .big);
                const x_max = std.mem.readInt(i16, ft.head[40..42], .big);
                out.max_char = @round(@as(f32, @floatFromInt(@as(i32, x_max) - x_min)) * scale);
            }
        } else out.char = zero;
        const lm = ft.lineMetrics();
        out.line = @round(@as(f32, @floatFromInt(lm.ascent)) * scale) + @round(@as(f32, @floatFromInt(lm.descent)) * scale) + @round(@as(f32, @floatFromInt(lm.leading)) * scale);
    }
    out.line = switch (cs.line_height) {
        .normal => out.line,
        .number => |v| v * cs.font_size,
        .px => |v| v,
    };
    out.line = @floor(out.line * 64) / 64;
    return out;
}

pub fn generate(f: *render.Frame) render.Error!void {
    const count = f.dom.els.items.len;
    for (0..count) |idx| {
        const id: u32 = @intCast(idx);
        const el = f.dom.at(id);
        const area = eq(el.tag, "textarea");
        if (!area and !eq(el.tag, "input")) continue;
        const typ = f.dom.attr(id, "type") orelse "text";
        if (!area and !textField(typ)) continue;
        const value = if (area) try areaValue(f, id) else try inputValue(f.a, f.dom.attr(id, "value") orelse "", typ);
        const host = try f.a.create(CS);
        host.* = el.cs.*;
        if (host.display != .none) host.display = switch (host.display) {
            .@"inline", .inline_block, .inline_flex, .inline_grid, .inline_table => .inline_block,
            else => .block,
        };
        const m = metrics(f, host);
        const scrollbar: f32 = if (area and host.overflow_y == .visible) 15 else 0;
        if (area) {
            if (host.overflow_x == .visible) host.overflow_x = .hidden;
            if (host.overflow_y == .visible) host.overflow_y = .hidden;
        }
        const columns = positive(f.dom.attr(id, if (area) "cols" else "size"), 20);
        // The document root's auto inline size is supplied by its initial containing block.
        // Inner controls instead contribute their character-based preferred inline size.
        // The default sizes are content sizes: a border-box host (`input[type=search]`) adds its
        // border and padding, as takumi's min-max and intrinsic block sizes do.
        const border_box = host.box_sizing == .border_box;
        if (host.width == .auto and id != f.dom.root) host.width = .{ .lp = .{ .px = @ceil(m.char * @as(f32, @floatFromInt(if (!area and eq(typ, "number")) @as(u32, 20) else columns)) + (if (area) scrollbar else @max(0, m.max_char - m.char))) + (if (border_box) borderPadding(host, 1) else 0) } };
        const rows = if (area) positive(f.dom.attr(id, "rows"), 2) else 1;
        const auto_height = host.height == .auto;
        if (auto_height) host.height = .{ .lp = .{ .px = m.line * @as(f32, @floatFromInt(rows)) + (if (border_box) borderPadding(host, 0) else 0) } };
        var diag: style.Diagnostics = .{};
        const editor = try f.a.create(CS);
        editor.* = style.compute(f.a, &f.ctx, host, null, null, &diag) catch return error.OutOfMemory;
        editor.display = .block;
        const editable = f.dom.attr(id, "disabled") == null and f.dom.attr(id, "readonly") == null;
        if (!area or (editable and (editor.white_space_collapse == .collapse or
            (editor.white_space_collapse == .preserve_breaks and editor.text_wrap_mode == .wrap)))) editor.white_space_collapse = .preserve;
        if (!area) {
            editor.display = .flow_root;
            editor.overflow_x = .hidden;
            editor.overflow_y = .hidden;
            editor.text_wrap_mode = .nowrap;
            editor.overflow_wrap = .normal;
            editor.text_overflow = host.text_overflow;
            // takumi `removes_line_height`: the authored height (a percentage always, calc never)
            // against the host's truncated line height.
            const authored: ?LP = if (!auto_height and host.height == .lp) host.height.lp else null;
            const removes = if (authored) |h| (!h.isCalc() and (h.pct != 0 or h.px > @trunc(m.line))) else false;
            if (host.font_size >= @trunc(m.line) or removes) editor.line_height = .normal;
            const editor_line = metrics(f, editor).line;
            editor.min_height = .{ .lp = .{ .px = editor_line } };
            // AlignContentBlockCenter: half the content box's free space in LayoutUnits (1/64 px,
            // truncated toward zero), whatever overflows.
            const content_height = if (authored) |h| (if (h.isCalc() or h.pct != 0) m.line else h.px - (if (border_box) borderPadding(host, 0) else 0)) else m.line;
            editor.margin[0] = .{ .lp = .{ .px = @trunc((@max(0, content_height) - editor_line) * 32) / 64 } };
        }
        // Placeholder text is not painted by pinned Takumi's text_control.value either.
        // Keep it out of the value and PDF text layer until an authored placeholder pseudo exists.
        el.control_text = el.kind == .text;
        el.kind = .container;
        el.text = "";
        el.cs = host;
        el.first = none;
        el.last = none;
        el.before = none;
        el.after = none;
        el.own = none;
        _ = try f.dom.add(f.a, .{ .kind = if (value.len == 0) .container else .text, .tag = "div", .text = value, .cs = editor }, id);
    }
}

test "text controls sanitize numbers and mask Unicode scalars" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    for ([_][]const u8{ "-100.11", "0", ".5", "-.5", "1e3", "1E-3" }) |s| try std.testing.expect(validNumber(s));
    for ([_][]const u8{ "abc", "+1", " 1", "1 ", "1.", "inf", "-inf", "NaN", "1e999", "-" }) |s| try std.testing.expect(!validNumber(s));
    try std.testing.expectEqualStrings("abc", try inputValue(alloc, "a\r\nb\nc", "text"));
    try std.testing.expectEqualStrings("a@b", try inputValue(alloc, " a@b\n ", "email"));
    try std.testing.expectEqualStrings("\u{2022}\u{2022}", try inputValue(alloc, "é中", "password"));
}
