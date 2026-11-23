//! CSS style-value parsing + cascade -> per-node `ComputedStyle`.
//!
//! There is no selector engine here: a node's style comes from ordered declaration LAYERS (takumi's
//! cascade: `preset` (UA) < presentation attributes / author rules / Tailwind < inline `style`), plus
//! inheritance from the parent. `compute` takes the two JSON objects of a node; `computeEx` adds an
//! ordered list of rule-origin `Declaration`s between them; `computeLayers` is the general form.
//!
//! Cascade: within normal declarations later wins; every `!important` declaration beats every normal
//! one; among important ones the later layer (and later declaration) wins.
//!
//! Property names: camelCase (`backgroundColor`, `WebkitLineClamp`) are matched exactly; names
//! containing '-' are kebab-case / vendor (`background-color`, `-webkit-line-clamp`) and matched
//! case-insensitively; `--name` is a custom property. JSON objects (takumi rule) ignore kebab keys.
//!
//! Error policy: in STRICT layers (JSON preset/style, as in takumi) a known property with an invalid
//! value fails with `error.InvalidStyleValue` (`Diagnostics` names the property and value). In
//! LENIENT layers (stylesheet rules) invalid declarations are dropped (CSS behaviour). Unknown names
//! are always ignored, `null` JSON values mean "no declaration". `inherit`, `initial`, `unset`,
//! `revert`, `revert-layer` work for every property.
//!
//! Custom properties + `var()`: `--x` declarations are inherited (`ComputedStyle.custom_props`,
//! name-sorted, shared with the parent when the element declares none). `var(--x, fallback)` is
//! substituted textually anywhere in a value at computed-value time against the element's own
//! custom properties (cycles / depth > 32 / missing without fallback -> the custom property is
//! invalid; a normal property becomes `unset` — never an error).
//!
//! Memory: `compute*` allocate lists (font families, shadows, gradients, tracks, substituted values,
//! ...) in `arena`, which must outlive the returned style; strings may alias the input.
const std = @import("std");
const json = @import("testjson.zig"); // referenced from tests only (see compute())
pub const tokenizer = @import("tokenizer.zig");
pub const color = @import("color.zig");
pub const values = @import("values.zig");
pub const gradient = @import("gradient.zig");
pub const computed = @import("computed.zig");
pub const props = @import("props.zig");
/// Keyframe interpolation + easing (see interp.zig); only linked in when referenced.
pub const interp = @import("interp.zig");

pub const Color = color.Color;
pub const ColorValue = color.ColorValue;
pub const LP = values.LP;
pub const CalcNode = values.CalcNode;
pub const Size = values.Size;
pub const LengthAuto = values.LengthAuto;
pub const Gradient = gradient.Gradient;
pub const GradientStop = gradient.Stop;
pub const ResolvedStop = gradient.ResolvedStop;
pub const Image = gradient.Image;
pub const resolveStops = gradient.resolveStops;
pub const ComputedStyle = computed.ComputedStyle;
pub const BgLayer = computed.BgLayer;
pub const MaskLayer = computed.MaskLayer;
pub const Shadow = computed.Shadow;
pub const Filter = computed.Filter;
pub const TransformOp = computed.TransformOp;
pub const Track = computed.Track;
pub const TrackSize = computed.TrackSize;
pub const GridTemplate = computed.GridTemplate;
pub const GridLine = computed.GridLine;
pub const Display = computed.Display;
pub const Align = computed.Align;
pub const TimingFunction = computed.TimingFunction;
pub const usedLineWidth = computed.usedLineWidth;
pub const Prop = props.Prop;

pub const Error = error{ InvalidStyleValue, OutOfMemory };

pub const Context = struct {
    /// devicePixelRatio: multiplies absolute lengths (px, pt, ...) and font sizes. Outputs are DEVICE px.
    dpr: f32 = 1,
    /// Output pixels; vw/vh resolve against these directly (not divided by dpr). Missing dimension = 0.
    viewport_w: f32,
    viewport_h: f32,
    /// The viewport has no height (a render without one, paged output): see `Env.vh_unbounded`.
    viewport_h_unbounded: bool = false,
    /// Root element font-size in device px (16*dpr until the root computes its own); `rem` base.
    root_font_size: f32,
    /// Font metrics for `ch` / `ex` / `cap` / `ic` units as fractions of the element's font-size
    /// (the integrator may fill these from the primary font; CSS fallback values by default).
    ch_width_ratio: f32 = 0.5,
    x_height_ratio: f32 = 0.5,
    cap_height_ratio: f32 = 0.7,
    ic_width_ratio: f32 = 1,
    /// `line-height: normal` as a multiple of font-size, used only for the `lh`/`rlh` units.
    normal_line_height_ratio: f32 = 1.2,
    /// Root element's computed line-height in device px (`rlh`); 0 = normal ratio * root_font_size.
    root_line_height: f32 = 0,
    /// PDF builds only: the frame is one a PDF is drawn from (see `props.Cx.paged`).
    paged: props.Paged = props.paged_off,
};

/// Filled on error.InvalidStyleValue. `value` is "" for JSON-number values.
pub const Diagnostics = struct { property: []const u8 = "", value: []const u8 = "" };

/// One declaration from any origin. `name`: camelCase, kebab-case, vendor or `--custom`.
/// `value`: the raw value text (a trailing `!important` in it is also recognised). `number`:
/// set instead of `value` for JSON numbers (takumi: unitless numbers are px for lengths).
pub const Declaration = struct {
    name: []const u8,
    value: []const u8,
    important: bool = false,
    number: ?f64 = null,
};

/// An ordered group of declarations of one origin. `lenient`: drop invalid declarations silently
/// (CSS rules) instead of failing the computation (JSON style objects, as in takumi).
pub const Layer = struct { decls: []const Declaration, lenient: bool = false };

fn sanitizedDpr(ctx: *const Context) f32 {
    return if (ctx.dpr > 0 and ctx.dpr < 1.0e6) ctx.dpr else 1;
}

/// takumi initial values (display = inline, box-sizing = border-box, font-size 16*dpr, ...).
pub fn initial(ctx: *const Context) ComputedStyle {
    return computed.initialStyle(sanitizedDpr(ctx));
}

/// A declaration value: the subset of `json.Value` (src/json.zig) that style cares about.
pub const RawValue = union(enum) { null, number: f64, string: []const u8, other };

/// Computes a node's style from its JSON `preset` (lowest priority) and `style` objects.
///
/// `preset` / `style` are `?json.Value` (src/json.zig). They are taken as `anytype` only so that this
/// directory can be unit-tested standalone (importing ../json.zig is outside the module path when
/// src/style is the test root); any union with `.null`, `.number: f64`, `.string`, `.object: []{key, value}`
/// works, and passing `null` is fine. A non-object, non-null source -> InvalidStyleValue (property "style").
pub fn compute(
    arena: std.mem.Allocator,
    ctx: *const Context,
    parent: ?*const ComputedStyle,
    preset: anytype,
    style: anytype,
    diag: *Diagnostics,
) Error!ComputedStyle {
    return computeEx(arena, ctx, parent, preset, &.{}, style, diag);
}

/// takumi cascade order: `preset_json` (strict) < `rules` (lenient: presentation attributes,
/// author stylesheet rules and Tailwind utilities, already in cascade order) < `style_json`
/// (strict, inline style). JSON sources as in `compute`.
pub fn computeEx(
    arena: std.mem.Allocator,
    ctx: *const Context,
    parent: ?*const ComputedStyle,
    preset_json: anytype,
    rules: []const Declaration,
    style_json: anytype,
    diag: *Diagnostics,
) Error!ComputedStyle {
    const layers = [3]Layer{
        .{ .decls = try jsonDecls(arena, preset_json, diag) },
        .{ .decls = rules, .lenient = true },
        .{ .decls = try jsonDecls(arena, style_json, diag) },
    };
    return computeLayers(arena, ctx, parent, &layers, diag);
}

/// Converts a JSON style object to declarations (kebab keys dropped, `!important` split off).
/// Generic only over the JSON value type (see `compute`).
pub fn jsonDecls(arena: std.mem.Allocator, src: anytype, diag: *Diagnostics) Error![]const Declaration {
    const Src = @TypeOf(src);
    if (Src == @TypeOf(null)) return &.{};
    const v = if (@typeInfo(Src) == .optional) (src orelse return &.{}) else src;
    switch (v) {
        .null => return &.{},
        .object => |members| {
            const out = try arena.alloc(Declaration, members.len);
            var n: usize = 0;
            for (members) |m| {
                const custom = isCustomName(m.key);
                if (!custom and std.mem.indexOfScalar(u8, m.key, '-') != null) continue;
                switch (m.value) {
                    .null => continue,
                    .number => |x| out[n] = .{ .name = m.key, .value = "", .number = x },
                    .string => |str| {
                        const sv = splitImportant(str);
                        out[n] = .{ .name = m.key, .value = sv.value, .important = sv.important };
                    },
                    else => {
                        if (custom or props.lookup(m.key) == null) continue;
                        diag.* = .{ .property = m.key, .value = "" };
                        return error.InvalidStyleValue;
                    },
                }
                n += 1;
            }
            return out[0..n];
        },
        else => {
            diag.* = .{ .property = "style", .value = "" };
            return error.InvalidStyleValue;
        },
    }
}

fn isCustomName(n: []const u8) bool {
    return n.len > 2 and n[0] == '-' and n[1] == '-';
}

/// Property id for a declaration name: camelCase exact, kebab-case/vendor case-insensitive.
/// Null for unknown names and custom properties.
/// A vendor-prefixed name that no property of its own matches is the unprefixed property (takumi
/// `strip_vendor_prefix`: `-webkit-background-clip` is `background-clip`).
pub fn propertyId(name: []const u8) ?Prop {
    if (std.mem.indexOfScalar(u8, name, '-') == null) return props.lookup(name) orelse unprefixed(name);
    if (isCustomName(name) or name.len >= 48) return null;
    var buf: [48]u8 = undefined;
    var n: usize = 0;
    var up = false;
    for (name) |ch| {
        if (ch == '-') {
            up = true;
            continue;
        }
        const lo = std.ascii.toLower(ch);
        buf[n] = if (up) std.ascii.toUpper(lo) else lo;
        up = false;
        n += 1;
    }
    return props.lookup(buf[0..n]) orelse unprefixed(buf[0..n]);
}

/// The property of camelCase `name` without its `Webkit` / `Moz` / `Ms` / `O` prefix, if any.
fn unprefixed(name: []const u8) ?Prop {
    inline for (.{ "Webkit", "webkit", "Moz", "moz", "Ms", "ms", "O", "o" }) |pre| {
        if (name.len > pre.len and name.len <= 48 + pre.len and std.mem.startsWith(u8, name, pre) and std.ascii.isUpper(name[pre.len])) {
            var buf: [48]u8 = undefined;
            const rest = name[pre.len..];
            @memcpy(buf[0..rest.len], rest);
            buf[0] = std.ascii.toLower(buf[0]);
            return props.lookup(buf[0..rest.len]);
        }
    }
    return null;
}

const SplitValue = struct { value: []const u8, important: bool };

fn splitImportant(s0: []const u8) SplitValue {
    const s = std.mem.trim(u8, s0, " \t\r\n\x0c");
    const bang = std.mem.lastIndexOfScalar(u8, s, '!') orelse return .{ .value = s, .important = false };
    const rest = std.mem.trim(u8, s[bang + 1 ..], " \t\r\n\x0c");
    if (!std.ascii.eqlIgnoreCase(rest, "important")) return .{ .value = s, .important = false };
    return .{ .value = std.mem.trimEnd(u8, s[0..bang], " \t\r\n\x0c"), .important = true };
}

// ---------------------------------------------------------------------------------------------
// cascade

const Mode = enum { font_size, font_metrics, all };

/// One cascaded declaration: `prop` null = custom property.
const Item = struct { d: *const Declaration, prop: ?Prop, lenient: bool };

const State = struct {
    init: *const ComputedStyle,
    parent: ?*const ComputedStyle,
    diag: *Diagnostics,
};

/// General cascade: `layers` in increasing precedence (see module doc for `!important`).
pub fn computeLayers(
    arena: std.mem.Allocator,
    ctx: *const Context,
    parent: ?*const ComputedStyle,
    layers: []const Layer,
    diag: *Diagnostics,
) Error!ComputedStyle {
    const dpr = sanitizedDpr(ctx);
    const init_s = computed.initialStyle(dpr);
    var s = init_s;
    if (parent) |p| props.inheritAll(&s, p);
    const pfs = if (parent) |p| p.font_size else init_s.font_size;
    const rem = if (ctx.root_font_size > 0) ctx.root_font_size else 16 * dpr;
    const nlh = if (ctx.normal_line_height_ratio > 0) ctx.normal_line_height_ratio else 1.2;
    var cx: props.Cx = .{
        .a = arena,
        .s = &s,
        .env = .{
            .dpr = dpr,
            .vw = if (ctx.viewport_w > 0) ctx.viewport_w else 0,
            .vh = if (ctx.viewport_h > 0) ctx.viewport_h else 0,
            .vh_unbounded = ctx.viewport_h_unbounded,
            .em = pfs,
            .rem = rem,
            .ch = ctx.ch_width_ratio,
            .ex = ctx.x_height_ratio,
            .cap = ctx.cap_height_ratio,
            .ic = ctx.ic_width_ratio,
            .lh = if (parent) |p| lineHeightPx(p, nlh) else nlh * pfs,
            .rlh = if (ctx.root_line_height > 0) ctx.root_line_height else nlh * rem,
            .alloc = arena,
        },
        .parent_fs = pfs,
        .parent_weight = if (parent) |p| p.font_weight else 400,
        .parent_color = if (parent) |p| p.color else Color.black,
        .paged = ctx.paged,
    };
    const st: State = .{ .init = &init_s, .parent = parent, .diag = diag };

    // flatten: normal declarations in layer order, then important ones
    var total: usize = 0;
    for (layers) |ly| total += ly.decls.len;
    if (total == 0) return s;
    const items = try arena.alloc(Item, total);
    var n: usize = 0;
    var n_custom: usize = 0;
    for ([2]bool{ false, true }) |imp| {
        for (layers) |ly| for (ly.decls) |*d| {
            const sv = splitImportant(d.value);
            if ((d.important or sv.important) != imp) continue;
            const custom = isCustomName(d.name);
            const p = if (custom) null else (propertyId(d.name) orelse continue);
            if (custom) n_custom += 1;
            items[n] = .{ .d = d, .prop = p, .lenient = ly.lenient };
            n += 1;
        };
    }
    const list = items[0..n];
    if (n_custom > 0) try buildCustom(&cx, &st, list, n_custom);

    for ([3]Mode{ .font_size, .font_metrics, .all }) |mode| {
        for (list) |it| {
            const p = it.prop orelse continue;
            const want = switch (mode) {
                .font_size => p == .fontSize or p == .font,
                .font_metrics => p == .lineHeight or p == .font or p == .direction or p == .writingMode,
                .all => true,
            };
            if (want) try applyItem(&cx, &st, it, p);
        }
        if (mode == .font_size) cx.env.em = s.font_size;
        if (mode == .font_metrics) cx.env.lh = lineHeightPx(&s, nlh);
    }
    return s;
}

fn lineHeightPx(s: *const ComputedStyle, normal_ratio: f32) f32 {
    return switch (s.line_height) {
        .normal => normal_ratio * s.font_size,
        .number => |k| k * s.font_size,
        .px => |v| v,
    };
}

const CssWide = enum { inherit, initial, unset };

fn cssWide(s: []const u8) ?CssWide {
    if (std.ascii.eqlIgnoreCase(s, "inherit")) return .inherit;
    if (std.ascii.eqlIgnoreCase(s, "initial")) return .initial;
    if (std.ascii.eqlIgnoreCase(s, "unset") or std.ascii.eqlIgnoreCase(s, "revert") or std.ascii.eqlIgnoreCase(s, "revert-layer")) return .unset;
    return null;
}

fn containsVar(s: []const u8) bool {
    return findVar(s, 0) != null;
}

/// Applies the CSS-wide keyword `k` to `p` (logical properties map through the direction).
fn applyWide(cx: *props.Cx, st: *const State, p: Prop, k: CssWide) void {
    var buf: [4]Prop = undefined;
    for (props.physicalProps(p, cx.s.direction == .rtl, &buf)) |q| {
        const use_parent = switch (k) {
            .inherit => true,
            .initial => false,
            .unset => props.isInherited(q),
        };
        const src: *const ComputedStyle = if (use_parent) (st.parent orelse st.init) else st.init;
        props.copyProp(q, cx.s, src);
    }
}

fn applyItem(cx: *props.Cx, st: *const State, it: Item, p: Prop) Error!void {
    const d = it.d;
    // (PDF builds, a frame no PDF is drawn from: accepted and ignored, as without the feature)
    if (comptime props.pdf_build) if (!cx.paged and props.pagedOnly(p)) return;
    if (d.number) |num| {
        var l = tokenizer.Lexer.initNumber(num);
        return applyParsed(cx, st, it, p, &l);
    }
    var text = splitImportant(d.value).value;
    if (containsVar(text)) {
        var sc: SubCtx = .{ .a = cx.a, .list = cx.s.custom_props };
        text = (try sc.substitute(text, 0)) orelse {
            applyWide(cx, st, p, .unset); // invalid at computed-value time
            return;
        };
        text = std.mem.trim(u8, text, " \t\r\n\x0c");
    }
    if (cssWide(text)) |k| return applyWide(cx, st, p, k);
    if (text.len == 0) return fail(st, it, text);
    var l = tokenizer.Lexer.init(text);
    return applyParsed(cx, st, it, p, &l);
}

fn fail(st: *const State, it: Item, text: []const u8) Error!void {
    if (it.lenient) return;
    st.diag.* = .{ .property = it.d.name, .value = text };
    return error.InvalidStyleValue;
}

fn applyParsed(cx: *props.Cx, st: *const State, it: Item, p: Prop, l: *tokenizer.Lexer) Error!void {
    if (!it.lenient) {
        props.apply(cx, p, l) catch |e| {
            if (e == error.InvalidStyleValue) st.diag.* = .{ .property = it.d.name, .value = if (it.d.number != null) "" else splitImportant(it.d.value).value };
            return e;
        };
        return;
    }
    // lenient: a failed declaration must leave no partial writes behind
    var saved: ComputedStyle = undefined;
    var buf: [4]Prop = undefined;
    const phys = props.physicalProps(p, cx.s.direction == .rtl, &buf);
    for (phys) |q| props.copyProp(q, &saved, cx.s);
    props.apply(cx, p, l) catch |e| {
        if (e == error.OutOfMemory) return e;
        for (phys) |q| props.copyProp(q, cx.s, &saved);
    };
}

// ---------------------------------------------------------------------------------------------
// custom properties

const max_var_depth = 32;
const max_subst_len = 64 * 1024;

/// Replaces every `var()` in `text` from `list` (resolved custom properties sorted by name, as
/// `ComputedStyle.custom_props`); `text` itself when it has none, null when a reference is
/// invalid (inline SVG declarations, src/svg/html_cascade.zig).
pub fn substituteVars(a: std.mem.Allocator, list: []const computed.CustomProp, text: []const u8) error{OutOfMemory}!?[]const u8 {
    var sc: SubCtx = .{ .a = a, .list = list };
    return sc.substitute(text, 0) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// Whether `text` holds a `var()` reference.
pub fn hasVar(text: []const u8) bool {
    return findVar(text, 0) != null;
}

/// var() substitution against a name-sorted custom property list. While the element's own custom
/// properties are being resolved, `state` tracks per-entry progress (cycle detection).
const SubCtx = struct {
    a: std.mem.Allocator,
    list: []const computed.CustomProp,
    /// null = every entry is resolved; else 0 = done, 1 = pending, 2 = resolving, 3 = invalid
    state: ?[]u8 = null,
    vals: ?[]computed.CustomProp = null,
    /// entry where a detected cycle closes; set while unwinding through the cycle members
    cycle_root: ?usize = null,

    fn find(c: *const SubCtx, name: []const u8) ?usize {
        var lo: usize = 0;
        var hi: usize = c.list.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            switch (std.mem.order(u8, c.list[mid].name, name)) {
                .eq => return mid,
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }

    /// Resolved value of custom property `name`, or null (missing / invalid / cycle).
    fn get(c: *SubCtx, name: []const u8, depth: u32) Error!?[]const u8 {
        const i = c.find(name) orelse return null;
        const stv = c.state orelse return c.list[i].value;
        switch (stv[i]) {
            0 => return c.list[i].value,
            2 => {
                if (c.cycle_root == null) c.cycle_root = i;
                return null;
            },
            3 => return null,
            else => {},
        }
        stv[i] = 2;
        const r = try c.substitute(c.list[i].value, depth + 1);
        if (c.cycle_root) |root| {
            // every member of the cycle is invalid; referencers outside it may use fallbacks
            stv[i] = 3;
            if (root == i) c.cycle_root = null;
            return null;
        }
        if (r) |v| {
            c.vals.?[i].value = v;
            stv[i] = 0;
        } else stv[i] = 3;
        return r;
    }

    /// Replaces every `var()` in `text`; null if any reference is invalid.
    fn substitute(c: *SubCtx, text: []const u8, depth: u32) Error!?[]const u8 {
        if (depth > max_var_depth) return null;
        var first = findVar(text, 0) orelse return text;
        var out: tokenizer.List(u8) = .{};
        var pos: usize = 0;
        while (true) {
            try out.appendSlice(c.a, text[pos..first]);
            const close = matchParen(text, first + 4) orelse return null;
            const args = text[first + 4 .. close];
            const comma = topComma(args);
            const name = std.mem.trim(u8, args[0 .. comma orelse args.len], " \t\r\n\x0c");
            if (!isCustomName(name)) return null;
            var rep: ?[]const u8 = try c.get(name, depth);
            if (rep == null and c.cycle_root != null) return null;
            if (rep == null) {
                const cm = comma orelse return null;
                rep = (try c.substitute(std.mem.trim(u8, args[cm + 1 ..], " \t\r\n\x0c"), depth + 1)) orelse return null;
            }
            const r = rep.?;
            // keep adjacent tokens apart (`var(--a)px` must not form a dimension)
            if (r.len > 0 and out.items.len > 0 and tokenizer.isNameChar(out.items[out.items.len - 1]) and tokenizer.isNameChar(r[0])) try out.append(c.a, ' ');
            try out.appendSlice(c.a, r);
            pos = close + 1;
            if (pos < text.len and r.len > 0 and tokenizer.isNameChar(text[pos]) and tokenizer.isNameChar(r[r.len - 1])) try out.append(c.a, ' ');
            if (out.items.len > max_subst_len) return null;
            first = findVar(text, pos) orelse break;
        }
        try out.appendSlice(c.a, text[pos..]);
        return out.items;
    }
};

/// Index of the next `var(` function (case-insensitive, outside strings) at or after `from`.
fn findVar(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 4 <= s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '"' or ch == '\'') {
            i += 1;
            while (i < s.len and s[i] != ch) : (i += 1) {
                if (s[i] == '\\') i += 1;
            }
            continue;
        }
        if (ch == '\\') {
            i += 1;
            continue;
        }
        if ((ch == 'v' or ch == 'V') and std.ascii.eqlIgnoreCase(s[i .. i + 4], "var(") and (i == 0 or !tokenizer.isNameChar(s[i - 1]))) return i;
    }
    return null;
}

/// Index of the `)` closing the block whose contents start at `start`.
fn matchParen(s: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        switch (ch) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth == 0) return if (ch == ')') i else null;
                depth -= 1;
            },
            '"', '\'' => {
                i += 1;
                while (i < s.len and s[i] != ch) : (i += 1) {
                    if (s[i] == '\\') i += 1;
                }
            },
            '\\' => i += 1,
            else => {},
        }
    }
    return null;
}

fn topComma(s: []const u8) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            ',' => if (depth == 0) return i,
            '"', '\'' => {
                const q = s[i];
                i += 1;
                while (i < s.len and s[i] != q) : (i += 1) {
                    if (s[i] == '\\') i += 1;
                }
            },
            '\\' => i += 1,
            else => {},
        }
    }
    return null;
}

/// Collects the winning `--name` declarations, merges them over the parent's map and resolves
/// their var() references (cycles -> invalid -> dropped).
fn buildCustom(cx: *props.Cx, st: *const State, list: []const Item, n_custom: usize) Error!void {
    const a = cx.a;
    const parent_list: []const computed.CustomProp = if (st.parent) |p| p.custom_props else &.{};
    // own declarations, last wins; value null = remove (initial / guaranteed-invalid)
    const Own = struct { name: []const u8, value: ?[]const u8 };
    const own = try a.alloc(Own, n_custom);
    var no: usize = 0;
    for (list) |it| {
        if (it.prop != null) continue;
        const d = it.d;
        var v: ?[]const u8 = undefined;
        if (d.number) |num| {
            v = try fmtNum(a, num);
        } else {
            const raw = splitImportant(d.value).value;
            if (cssWide(raw)) |k| {
                v = if (k == .initial) null else computed.findCustom(parent_list, d.name);
            } else v = raw;
        }
        var k: usize = 0;
        while (k < no and !std.mem.eql(u8, own[k].name, d.name)) k += 1;
        own[k] = .{ .name = d.name, .value = v };
        if (k == no) no += 1;
    }
    // merge (both sorted) into a fresh array
    // insertion sort (small n; avoids pulling std.sort into the binary)
    for (1..no) |x| {
        const v = own[x];
        var y = x;
        while (y > 0 and std.mem.order(u8, own[y - 1].name, v.name) == .gt) : (y -= 1) own[y] = own[y - 1];
        own[y] = v;
    }
    const merged = try a.alloc(computed.CustomProp, parent_list.len + no);
    const state = try a.alloc(u8, parent_list.len + no);
    var m: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < parent_list.len or j < no) {
        const take_own = j < no and (i >= parent_list.len or std.mem.order(u8, own[j].name, parent_list[i].name) != .gt);
        if (take_own) {
            if (i < parent_list.len and std.mem.eql(u8, own[j].name, parent_list[i].name)) i += 1;
            if (own[j].value) |v| {
                merged[m] = .{ .name = own[j].name, .value = v };
                state[m] = if (containsVar(v)) 1 else 0;
                m += 1;
            }
            j += 1;
        } else {
            merged[m] = parent_list[i];
            state[m] = 0;
            m += 1;
            i += 1;
        }
    }
    var sc: SubCtx = .{ .a = a, .list = merged[0..m], .state = state[0..m], .vals = merged[0..m] };
    for (0..m) |k| {
        if (state[k] == 1) _ = try sc.get(merged[k].name, 0);
    }
    var w: usize = 0;
    for (0..m) |k| {
        if (state[k] == 3) continue;
        merged[w] = merged[k];
        w += 1;
    }
    cx.s.custom_props = merged[0..w];
}

/// Shortest-ish decimal text for a JSON number used as a custom property value.
fn fmtNum(a: std.mem.Allocator, x0: f64) Error![]const u8 {
    var buf: [48]u8 = undefined;
    var n: usize = 0;
    var x = x0;
    if (!(x == x) or @abs(x) > 1.0e15) return "0";
    if (x < 0) {
        buf[n] = '-';
        n += 1;
        x = -x;
    }
    var ip: u64 = @intFromFloat(@floor(x));
    var frac = x - @floor(x);
    var digits: [20]u8 = undefined;
    var nd: usize = 0;
    while (true) {
        digits[nd] = @as(u8, @intCast(ip % 10)) + '0';
        nd += 1;
        ip /= 10;
        if (ip == 0) break;
    }
    while (nd > 0) {
        nd -= 1;
        buf[n] = digits[nd];
        n += 1;
    }
    if (frac > 1e-9) {
        buf[n] = '.';
        n += 1;
        var k: usize = 0;
        while (k < 6 and frac > 1e-9) : (k += 1) {
            frac *= 10;
            const dgt: u8 = @intFromFloat(@floor(frac));
            buf[n] = @as(u8, '0') + @min(dgt, 9);
            n += 1;
            frac -= @floor(frac);
        }
    }
    return a.dupe(u8, buf[0..n]);
}

// ---------------------------------------------------------------------------------------------
// declaration blocks

/// Parses `style="a: b; c: d !important"` attribute / rule-body text into declarations (in order).
/// Handles strings, nested ()/[]/{} blocks, comments and escapes; malformed declarations (no name
/// or no ':') are skipped. Names are returned as written (trimmed); values are trimmed with
/// `!important` split off. Slices alias `text` except when comments had to be removed.
pub fn parseDeclarationBlock(arena: std.mem.Allocator, text: []const u8) Error![]Declaration {
    var out: tokenizer.List(Declaration) = .{};
    var i: usize = 0;
    while (i < text.len) {
        // find the end of this declaration: ';' at depth 0
        const start = i;
        var depth: usize = 0;
        var colon: ?usize = null;
        var has_comment = false;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            switch (ch) {
                ';' => if (depth == 0) break,
                ':' => if (depth == 0 and colon == null) {
                    colon = i;
                },
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                '"', '\'' => {
                    i += 1;
                    while (i < text.len and text[i] != ch and text[i] != '\n') : (i += 1) {
                        if (text[i] == '\\') i += 1;
                    }
                    if (i >= text.len) break;
                },
                '\\' => i += 1,
                '/' => if (i + 1 < text.len and text[i + 1] == '*') {
                    has_comment = true;
                    i += 2;
                    while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) i += 1;
                    i += 1;
                },
                else => {},
            }
        }
        const end = @min(i, text.len);
        i = end + 1;
        if (out.items.len >= 1 << 16) break;
        var body = text[start..end];
        var col = (colon orelse continue) - start;
        if (has_comment) {
            const sc = try stripComments(arena, body, col);
            body = sc.text;
            col = sc.colon orelse continue;
        }
        const name = std.mem.trim(u8, body[0..col], " \t\r\n\x0c");
        if (name.len == 0) continue;
        var ok = true;
        for (name) |ch| if (!tokenizer.isNameChar(ch)) {
            ok = false;
        };
        if (!ok) continue;
        const sv = splitImportant(body[col + 1 ..]);
        try out.append(arena, .{ .name = name, .value = sv.value, .important = sv.important });
    }
    return out.items;
}

/// Copy of `s` without /* comments */ (outside strings); also maps the colon index.
fn stripComments(a: std.mem.Allocator, s: []const u8, colon: usize) Error!struct { text: []const u8, colon: ?usize } {
    var out = try a.alloc(u8, s.len);
    var n: usize = 0;
    var new_colon: ?usize = null;
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch == '/' and i + 1 < s.len and s[i + 1] == '*') {
            i += 2;
            while (i + 1 < s.len and !(s[i] == '*' and s[i + 1] == '/')) i += 1;
            i = @min(i + 2, s.len);
            out[n] = ' ';
            n += 1;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            const b = i;
            i += 1;
            while (i < s.len and s[i] != ch) : (i += 1) {
                if (s[i] == '\\') i += 1;
            }
            i = @min(i + 1, s.len);
            @memcpy(out[n .. n + (i - b)], s[b..i]);
            n += i - b;
            continue;
        }
        if (i == colon) new_colon = n;
        out[n] = ch;
        n += 1;
        i += 1;
    }
    // a colon inside a comment is not the separator: re-find the first top-level ':'
    if (new_colon == null) new_colon = std.mem.indexOfScalar(u8, out[0..n], ':');
    return .{ .text = out[0..n], .colon = new_colon };
}

// =============================================================================================
// tests
// =============================================================================================
const T = std.testing;

test {
    _ = interp;
    _ = tokenizer;
    _ = color;
    _ = values;
    _ = gradient;
    _ = computed;
    _ = props;
}

const TestCx = struct {
    arena: std.heap.ArenaAllocator,
    ctx: Context = .{ .dpr = 1, .viewport_w = 1200, .viewport_h = 630, .root_font_size = 16 },
    diag: Diagnostics = .{},

    fn init() TestCx {
        return .{ .arena = std.heap.ArenaAllocator.init(T.allocator) };
    }
    fn deinit(t: *TestCx) void {
        t.arena.deinit();
    }
    fn a(t: *TestCx) std.mem.Allocator {
        return t.arena.allocator();
    }
    /// Computes from a JSON style object text.
    fn style(t: *TestCx, parent: ?*const ComputedStyle, src: []const u8) !ComputedStyle {
        const v = try json.parse(t.a(), src);
        return compute(t.a(), &t.ctx, parent, null, v, &t.diag);
    }
    /// Computes `{ key: value }` with a string value.
    fn one(t: *TestCx, key: []const u8, value: []const u8) !ComputedStyle {
        const members = try t.a().alloc(json.Member, 1);
        members[0] = .{ .key = key, .value = .{ .string = value } };
        return compute(t.a(), &t.ctx, null, null, json.Value{ .object = members }, &t.diag);
    }
    fn bad(t: *TestCx, key: []const u8, value: []const u8) !void {
        if (t.one(key, value)) |_| {
            std.debug.print("expected InvalidStyleValue for {s}: '{s}'\n", .{ key, value });
            return error.TestUnexpectedResult;
        } else |e| {
            try T.expectEqual(error.InvalidStyleValue, e);
            try T.expectEqualStrings(key, t.diag.property);
        }
    }
};

fn approx(a: f32, b: f32) bool {
    return @abs(a - b) < 1e-3;
}
fn expectLP(v: LP, px: f32, pct: f32) !void {
    if (!approx(v.px, px) or !approx(v.pct, pct)) {
        std.debug.print("LP {d},{d} expected {d},{d}\n", .{ v.px, v.pct, px, pct });
        return error.TestUnexpectedResult;
    }
}

test "property table lookup" {
    try T.expectEqual(props.Prop.width, props.lookup("width").?);
    try T.expectEqual(props.Prop.WebkitLineClamp, props.lookup("WebkitLineClamp").?);
    try T.expectEqual(props.Prop.zIndex, props.lookup("zIndex").?);
    try T.expectEqual(props.Prop.WebkitLineClamp, props.lookup("WebkitLineClamp").?);
    try T.expect(props.lookup("min-width") == null);
    try T.expect(props.lookup("WebkitBoxOrient") != null);
    try T.expect(props.lookup("Width") == null);
    for (std.enums.values(props.Prop)) |p| try T.expectEqual(p, props.lookup(@tagName(p)).?);
}

test "motion paths share distance wrapping, anchors and ray geometry across backends" {
    var t = TestCx.init();
    defer t.deinit();
    const motion = @import("motion_path.zig");
    const s = try t.style(null,
        \\{"offsetPath":"path('M0 0 L100 0 L100 100 Z')","offsetDistance":"125px","offsetRotate":"reverse 10deg","offsetAnchor":"0% 0%"}
    );
    const point = motion.sample(&s, 20, 10).?;
    try T.expectApproxEqAbs(@as(f32, 100), point.x, 0.001);
    try T.expectApproxEqAbs(@as(f32, 25), point.y, 0.001);
    try T.expectEqual(computed.OffsetRotate{ .mode = .reverse, .angle = 10 }, s.offset_rotate);
    var r = try t.one("offset", "ray(90deg sides at 20px 30px) 50% / 0% 0%");
    const ray = motion.sample(&r, 20, 10).?;
    try T.expectApproxEqAbs(@as(f32, 610), ray.x, 0.001);
    try T.expectApproxEqAbs(@as(f32, 30), ray.y, 0.001);
    r = try t.style(null,
        \\{"offsetPath":"path('M0 0 L100 0')","offsetDistance":"200%"}
    );
    try T.expectApproxEqAbs(@as(f32, 100), motion.sample(&r, 20, 10).?.x, 0.001);
    _ = try t.one("offset", "0% 0% circle(20px at 30px 40px) auto 20deg 10px / 50%");
    try t.bad("offsetAnchor", "left top");
    try t.bad("offsetPath", "ray(sides)");
    try t.bad("offsetRotate", "auto reverse");
}

test "motion paths without a viewport height take the element's height as the reference box" {
    var t = TestCx.init();
    defer t.deinit();
    const motion = @import("motion_path.zig");
    t.ctx.viewport_w = 200;
    t.ctx.viewport_h = 100;
    // a viewport of its own height: the border box reference is 200 x 100 (300px is half its edge)
    var s = try t.style(null,
        \\{"offsetPath":"border-box","offsetDistance":"50%"}
    );
    var p = motion.sample(&s, 60, 24).?;
    try T.expectApproxEqAbs(@as(f32, 200), p.x, 0.001);
    try T.expectApproxEqAbs(@as(f32, 100), p.y, 0.001);
    // paged output (takumi-pdf's unbounded column): 200 wide, as tall as the element
    t.ctx.viewport_h_unbounded = true;
    s = try t.style(null,
        \\{"offsetPath":"border-box","offsetDistance":"50%"}
    );
    p = motion.sample(&s, 60, 24).?;
    try T.expectApproxEqAbs(@as(f32, 200), p.x, 0.001);
    try T.expectApproxEqAbs(@as(f32, 24), p.y, 0.001);
    // measured once per height
    try T.expectApproxEqAbs(@as(f32, 40), motion.sample(&s, 60, 40).?.y, 0.001);
    // a ray's sides take the element's height too: from (100, 12) straight down to y = 24
    s = try t.style(null,
        \\{"offsetPath":"ray(180deg closest-side at 50% 50%)","offsetDistance":"100%"}
    );
    p = motion.sample(&s, 60, 24).?;
    try T.expectApproxEqAbs(@as(f32, 24), p.y, 0.001);
}

test "var() substitution for declarations outside the cascade (inline SVG)" {
    var t = TestCx.init();
    defer t.deinit();
    const list = [_]computed.CustomProp{ .{ .name = "--a", .value = "#0a0" }, .{ .name = "--b", .value = "2px" } };
    try T.expectEqualStrings("#0a0", (try substituteVars(t.a(), &list, "var(--a)")).?);
    try T.expectEqualStrings("2px solid", (try substituteVars(t.a(), &list, "var(--b) solid")).?);
    try T.expectEqualStrings("red", (try substituteVars(t.a(), &list, "var(--missing, red)")).?);
    try T.expect((try substituteVars(t.a(), &list, "var(--missing)")) == null);
    try T.expect(hasVar("rgb(var(--x) 0 0)") and !hasVar("variable"));
}

test "initial values" {
    const ctx: Context = .{ .dpr = 2, .viewport_w = 100, .viewport_h = 100, .root_font_size = 32 };
    const s = initial(&ctx);
    try T.expectEqual(Display.@"inline", s.display);
    try T.expectEqual(computed.BoxSizing.border_box, s.box_sizing);
    try T.expectEqual(@as(f32, 32), s.font_size);
    try T.expectEqual(@as(f32, 6), s.border_width[0]);
    try T.expectEqual([4]f32{ 0, 0, 0, 0 }, s.usedBorderWidths());
    try T.expect(s.color.eql(Color.black));
    try T.expect(s.line_height == .normal);
    try expectLP(s.transform_origin[0], 0, 0.5);
    try T.expectEqual(computed.ObjectFit.fill, s.object_fit);
    try T.expectEqual(@as(f32, 1), s.flex_shrink);
}

test "ignored keys, null, errors, important, var" {
    var t = TestCx.init();
    defer t.deinit();
    const s = try t.style(null,
        \\{"min-width": "banana", "unknownProp": "x", "--x": "1px", "width": null, "WebkitBoxOrient": "vertical",
        \\ "height": "10px !important", "minHeight": "5px!IMPORTANT"}
    );
    try T.expect(s.width == .auto);
    try expectLP(s.height.lp, 10, 0);
    try expectLP(s.min_height.lp, 5, 0);
    try t.bad("width", "banana");
    try T.expectEqualStrings("banana", t.diag.value);
    // var() never errors: invalid at computed-value time -> unset
    try T.expect((try t.one("width", "var(--x)")).width == .auto);
    try T.expect((try t.one("color", "calc(var(--a) * 1)")).color.eql(Color.black));
    try t.bad("width", "");
    try t.bad("width", "10px 20px");
    try t.bad("width", "none");
    try T.expect((try t.one("maxWidth", "auto")).max_width == .auto); // takumi accepts
    try t.bad("width", "-10px");
    try t.bad("WebkitBoxOrient", "banana");
    _ = try t.one("WebkitBoxOrient", "vertical");
    // non-string/number value
    try T.expectError(error.InvalidStyleValue, t.style(null, "{\"width\": true}"));
    try T.expectError(error.InvalidStyleValue, t.style(null, "{\"width\": [1]}"));
    // last declaration wins; preset < style
    const preset = try json.parse(t.a(), "{\"width\": 5, \"height\": 7}");
    const sty = try json.parse(t.a(), "{\"width\": 1, \"width\": 2}");
    const s2 = try compute(t.a(), &t.ctx, null, preset, sty, &t.diag);
    try expectLP(s2.width.lp, 2, 0);
    try expectLP(s2.height.lp, 7, 0);
}

test "units with dpr=2" {
    var t = TestCx.init();
    defer t.deinit();
    t.ctx = .{ .dpr = 2, .viewport_w = 100, .viewport_h = 50, .root_font_size = 32 };
    const s = try t.style(null,
        \\{"width": 10, "height": "10", "minWidth": "50vw", "minHeight": "1em", "maxWidth": "2rem",
        \\ "maxHeight": "calc(100% - 1em)", "fontSize": 20, "top": "10vh", "left": "1pt"}
    );
    try T.expectEqual(@as(f32, 40), s.font_size);
    try expectLP(s.width.lp, 20, 0);
    try expectLP(s.height.lp, 20, 0);
    try expectLP(s.min_width.lp, 50, 0); // vw not scaled by dpr
    try expectLP(s.min_height.lp, 40, 0); // em = own (device) font size
    try expectLP(s.max_width.lp, 64, 0);
    try expectLP(s.max_height.lp, -40, 1);
    try expectLP(s.inset[0].lp, 5, 0);
    try expectLP(s.inset[3].lp, 8.0 / 3.0, 0);
    try T.expect(s.inset[1] == .auto);
}

test "font-size: em uses parent, keywords, relative" {
    var t = TestCx.init();
    defer t.deinit();
    t.ctx.dpr = 2;
    t.ctx.root_font_size = 32;
    const root = try t.style(null, "{\"fontSize\": \"20px\"}");
    try T.expectEqual(@as(f32, 40), root.font_size);
    const child = try t.style(&root, "{\"fontSize\": \"2em\", \"width\": \"1em\"}");
    try T.expectEqual(@as(f32, 80), child.font_size);
    try expectLP(child.width.lp, 80, 0);
    // width declared before fontSize still uses the final font size
    const c2 = try t.style(&root, "{\"width\": \"1em\", \"fontSize\": \"50%\"}");
    try T.expectEqual(@as(f32, 20), c2.font_size);
    try expectLP(c2.width.lp, 20, 0);
    const kws = [_]struct { []const u8, f32 }{
        .{ "xx-small", 18 },        .{ "x-small", 20 },  .{ "small", 26 },     .{ "medium", 32 }, .{ "large", 36 },
        .{ "x-large", 48 },         .{ "xx-large", 64 }, .{ "xxx-large", 96 }, .{ "1rem", 32 },   .{ "larger", 48 },
        .{ "smaller", 40.0 / 1.2 },
    };
    for (kws) |k| {
        const members = try t.a().alloc(json.Member, 1);
        members[0] = .{ .key = "fontSize", .value = .{ .string = k[0] } };
        const s = try compute(t.a(), &t.ctx, &root, null, json.Value{ .object = members }, &t.diag);
        if (!approx(s.font_size, k[1])) {
            std.debug.print("fontSize {s} = {d}\n", .{ k[0], s.font_size });
            return error.TestUnexpectedResult;
        }
    }
    try T.expectEqual(@as(f32, 0), (try t.one("fontSize", "-1px")).font_size); // takumi accepts
    try t.bad("fontSize", "big");
}

test "inheritance" {
    var t = TestCx.init();
    defer t.deinit();
    const parent = try t.style(null,
        \\{"color": "red", "fontFamily": "Inter, 'Noto Sans', sans-serif", "fontSize": 20, "lineHeight": 1.5,
        \\ "backgroundColor": "blue", "width": 100, "fontWeight": "bold", "textAlign": "center", "letterSpacing": "0.1em",
        \\ "textDecoration": "underline", "textOverflow": "ellipsis", "lineClamp": 2, "visibility": "hidden"}
    );
    try T.expectEqual(@as(usize, 3), parent.font_family.len);
    try T.expectEqualStrings("Noto Sans", parent.font_family[1]);
    try T.expectEqualStrings("sans-serif", parent.font_family[2]);
    try T.expect(approx(parent.letter_spacing, 2));
    const child = try t.style(&parent, "{\"fontSize\": 10}");
    try T.expect(child.color.eql(.{ .r = 255, .a = 255 }));
    try T.expectEqual(@as(usize, 3), child.font_family.len);
    try T.expectEqual(@as(u16, 700), child.font_weight);
    try T.expectEqual(computed.TextAlign.center, child.text_align);
    try T.expect(child.line_height == .number and child.line_height.number == 1.5); // re-multiplied by layout with 10px
    try T.expect(approx(child.letter_spacing, 2)); // computed px inherits
    try T.expect(child.background_color == .rgba and child.background_color.rgba.a == 0);
    try T.expect(child.width == .auto);
    try T.expect(!child.text_decoration_line.underline);
    try T.expectEqual(computed.TextOverflow.clip, child.text_overflow);
    try T.expectEqual(@as(u32, 0), child.line_clamp);
    try T.expectEqual(computed.Visibility.hidden, child.visibility);
    // lineHeight length computes to px at the declaring element and inherits as px
    const p2 = try t.style(null, "{\"fontSize\": 20, \"lineHeight\": \"1.5em\"}");
    try T.expect(p2.line_height == .px and approx(p2.line_height.px, 30));
    const c2 = try t.style(&p2, "{\"fontSize\": 10}");
    try T.expect(c2.line_height == .px and approx(c2.line_height.px, 30));
    const p3 = try t.style(null, "{\"fontSize\": 20, \"lineHeight\": \"150%\"}");
    try T.expect(p3.line_height == .px and approx(p3.line_height.px, 30));
    // currentColor for `color` = parent's colour
    const c3 = try t.style(&parent, "{\"color\": \"currentColor\", \"borderColor\": \"currentcolor\"}");
    try T.expect(c3.color.eql(.{ .r = 255, .a = 255 }));
    try T.expect(c3.border_color[0] == .current);
}

test "css-wide keywords" {
    var t = TestCx.init();
    defer t.deinit();
    const parent = try t.style(null, "{\"color\": \"red\", \"width\": 50, \"padding\": 4, \"fontSize\": 30, \"border\": \"2px solid blue\"}");
    const c1 = try t.style(&parent,
        \\{"color": "inherit", "width": "inherit", "padding": "INHERIT", "border": "inherit", "fontSize": "initial"}
    );
    try T.expect(c1.color.eql(.{ .r = 255, .a = 255 }));
    try expectLP(c1.width.lp, 50, 0);
    try expectLP(c1.padding[2], 4, 0);
    try T.expectEqual(computed.BorderStyle.solid, c1.border_style[1]);
    try T.expectEqual(@as(f32, 16), c1.font_size);
    const c2 = try t.style(&parent, "{\"color\": \"blue\", \"width\": 3}");
    const c3 = try t.style(&c2, "{\"color\": \"initial\", \"width\": \"unset\", \"fontSize\": \"unset\", \"paddingTop\": \"revert\"}");
    try T.expect(c3.color.eql(Color.black));
    try T.expect(c3.width == .auto);
    try T.expectEqual(@as(f32, 30), c3.font_size);
    const c4 = try t.style(&parent, "{\"color\": \"unset\", \"borderTop\": \"inherit\"}");
    try T.expect(c4.color.eql(.{ .r = 255, .a = 255 }));
    try T.expectEqual(computed.BorderStyle.solid, c4.border_style[0]);
    try T.expectEqual(computed.BorderStyle.none, c4.border_style[1]);
    // root: inherit = initial
    const r = try t.style(null, "{\"color\": \"inherit\", \"display\": \"inherit\"}");
    try T.expect(r.color.eql(Color.black));
    try T.expectEqual(Display.@"inline", r.display);
}

test "display / position / box keywords" {
    var t = TestCx.init();
    defer t.deinit();
    const cases = [_]struct { []const u8, Display }{
        .{ "none", .none },                 .{ "flex", .flex },                             .{ "inline-flex", .inline_flex },
        .{ "grid", .grid },                 .{ "inline-grid", .inline_grid },               .{ "block", .block },
        .{ "inline", .@"inline" },          .{ "inline-block", .inline_block },             .{ "contents", .contents },
        .{ "flow-root", .flow_root },       .{ "FLEX", .flex },                             .{ "table", .table },
        .{ "list-item", .list_item },       .{ "-webkit-box", .webkit_box },                .{ "table-cell", .table_cell },
        .{ "inline-table", .inline_table }, .{ "table-header-group", .table_header_group }, .{ "-webkit-inline-box", .webkit_inline_box },
    };
    for (cases) |cs| try T.expectEqual(cs[1], (try t.one("display", cs[0])).display);
    try t.bad("display", "flexbox");
    try t.bad("display", "1");
    try t.bad("display", "webkit-box");
    try t.bad("display", "block flex"); // takumi rejects the two-value syntax
    try T.expectEqual(computed.Position.absolute, (try t.one("position", "absolute")).position);
    try T.expectEqual(computed.Position.sticky, (try t.one("position", "sticky")).position);
    try t.bad("position", "absolut");
    try T.expectEqual(computed.BoxSizing.content_box, (try t.one("boxSizing", "content-box")).box_sizing);
    const s = try t.one("overflow", "hidden scroll");
    try T.expect(s.overflow_x == .hidden and s.overflow_y == .scroll);
    try T.expect((try t.one("overflow", "clip")).overflow_y == .clip);
    try T.expect((try t.one("overflowY", "auto")).overflow_y == .auto);
    try t.bad("overflow", "a b");
    try T.expectEqual(@as(?i32, 5), (try t.one("zIndex", "5")).z_index);
    try T.expectEqual(@as(?i32, -3), (try t.one("zIndex", "-3")).z_index);
    try T.expectEqual(@as(?i32, null), (try t.one("zIndex", "auto")).z_index);
    try t.bad("zIndex", "1.5");
    try T.expectEqual(@as(i32, -2), (try t.one("order", "-2")).order);
    try T.expectEqual(computed.Visibility.collapse, (try t.one("visibility", "collapse")).visibility);
    try T.expectEqual(@as(?f32, 16.0 / 9.0), (try t.one("aspectRatio", "16 / 9")).aspect_ratio);
    try T.expectEqual(@as(?f32, 1.5), (try t.one("aspectRatio", "1.5")).aspect_ratio);
    try T.expectEqual(@as(?f32, null), (try t.one("aspectRatio", "auto")).aspect_ratio);
    try T.expectEqual(@as(?f32, 2), (try t.one("aspectRatio", "auto 2/1")).aspect_ratio);
    try t.bad("aspectRatio", "16/");
    try T.expectEqual(@as(?f32, null), (try t.one("aspectRatio", "-1")).aspect_ratio);
    const sz = try t.style(null,
        \\{"width": "min-content", "height": "max-content", "minWidth": "fit-content", "minHeight": "stretch", "maxWidth": "none", "maxHeight": "50%"}
    );
    try T.expect(sz.width == .min_content and sz.height == .max_content and sz.min_width == .fit_content and sz.min_height == .stretch);
    try T.expect(sz.max_width == .auto);
    try expectLP(sz.max_height.lp, 0, 0.5);
}

test "margin / padding / inset / gap shorthands" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try t.one("margin", "1px");
    for (s.margin) |m| try expectLP(m.lp, 1, 0);
    s = try t.one("margin", "1px auto");
    try expectLP(s.margin[0].lp, 1, 0);
    try T.expect(s.margin[1] == .auto and s.margin[3] == .auto);
    try expectLP(s.margin[2].lp, 1, 0);
    s = try t.one("margin", "1px 2px 3px");
    try expectLP(s.margin[3].lp, 2, 0);
    try expectLP(s.margin[2].lp, 3, 0);
    s = try t.one("padding", "1px 2px 3px 4%");
    try expectLP(s.padding[0], 1, 0);
    try expectLP(s.padding[1], 2, 0);
    try expectLP(s.padding[2], 3, 0);
    try expectLP(s.padding[3], 0, 0.04);
    s = try t.style(null, "{\"padding\": 10, \"paddingLeft\": 3, \"marginTop\": \"auto\", \"inset\": \"0 auto\"}");
    try expectLP(s.padding[0], 10, 0);
    try expectLP(s.padding[3], 3, 0);
    try T.expect(s.margin[0] == .auto);
    try expectLP(s.inset[0].lp, 0, 0);
    try T.expect(s.inset[1] == .auto);
    try t.bad("margin", "1px 2px 3px 4px 5px");
    try t.bad("padding", "-1px");
    try expectLP((try t.one("padding", "auto")).padding[0], 0, 0); // takumi accepts
    s = try t.one("gap", "10px 20%");
    try expectLP(s.row_gap, 10, 0);
    try expectLP(s.column_gap, 0, 0.2);
    s = try t.one("gap", "5px");
    try expectLP(s.column_gap, 5, 0);
    s = try t.one("rowGap", "normal");
    try expectLP(s.row_gap, 0, 0);
}

fn expectFlex(t: *TestCx, v: []const u8, g: f32, sh: f32, basis: computed.FlexBasis) !void {
    const s = try t.one("flex", v);
    const ok = s.flex_grow == g and s.flex_shrink == sh and std.meta.eql(s.flex_basis, basis);
    if (!ok) {
        std.debug.print("flex '{s}' -> {d} {d} {any}\n", .{ v, s.flex_grow, s.flex_shrink, s.flex_basis });
        return error.TestUnexpectedResult;
    }
}

test "flex shorthand truth table" {
    var t = TestCx.init();
    defer t.deinit();
    const zero_pct: computed.FlexBasis = .{ .lp = .{ .pct = 0 } };
    try expectFlex(&t, "1", 1, 1, zero_pct);
    try expectFlex(&t, "auto", 1, 1, .auto);
    try expectFlex(&t, "none", 0, 0, .auto);
    try expectFlex(&t, "2 3", 2, 3, zero_pct);
    try expectFlex(&t, "1 30px", 1, 1, .{ .lp = .{ .px = 30 } });
    try expectFlex(&t, "0 0 100px", 0, 0, .{ .lp = .{ .px = 100 } });
    try expectFlex(&t, "30px", 1, 1, .{ .lp = .{ .px = 30 } });
    try expectFlex(&t, "0", 0, 1, zero_pct);
    try expectFlex(&t, "1 0 0", 1, 0, .{ .lp = .{ .px = 0 } });
    try expectFlex(&t, "2 content", 2, 1, .content);
    try expectFlex(&t, "50% 2", 2, 1, .{ .lp = .{ .pct = 0.5 } });
    try expectFlex(&t, "1 1 auto", 1, 1, .auto);
    const s = try t.style(null, "{\"flex\": 1}");
    try T.expect(s.flex_grow == 1 and s.flex_shrink == 1 and std.meta.eql(s.flex_basis, zero_pct));
    const s2 = try t.one("flex", "initial");
    try T.expect(s2.flex_grow == 0 and s2.flex_shrink == 1 and s2.flex_basis == .auto);
    try expectFlex(&t, "1 2 3", 1, 2, .{ .lp = .{ .px = 3 } }); // takumi: unitless basis = px
    try expectFlex(&t, "-1", 0, 1, zero_pct); // takumi accepts negatives; clamped
    try t.bad("flex", "auto 1");
    try t.bad("flex", "10px 20px");
    const fb = try t.style(null, "{\"flexGrow\": 2, \"flexShrink\": \"0\", \"flexBasis\": \"content\", \"flexDirection\": \"column-reverse\", \"flexWrap\": \"wrap\"}");
    try T.expect(fb.flex_grow == 2 and fb.flex_shrink == 0 and fb.flex_basis == .content);
    try T.expect(fb.flex_direction == .column_reverse and fb.flex_wrap == .wrap);
    const ff = try t.one("flexFlow", "wrap-reverse column");
    try T.expect(ff.flex_direction == .column and ff.flex_wrap == .wrap_reverse);
    try T.expectEqual(@as(f32, 0), (try t.one("flexGrow", "-1")).flex_grow);
}

test "alignment" {
    var t = TestCx.init();
    defer t.deinit();
    const s = try t.style(null,
        \\{"justifyContent": "space-between", "alignItems": "center", "alignSelf": "flex-end", "alignContent": "space-evenly",
        \\ "justifyItems": "start", "justifySelf": "self-end"}
    );
    try T.expect(s.justify_content == .space_between and s.align_items == .center and s.align_self == .flex_end);
    try T.expect(s.align_content == .space_evenly and s.justify_items == .start and s.justify_self == .self_end);
    try T.expect((try t.one("alignItems", "normal")).align_items == .normal);
    try T.expect((try t.one("alignItems", "baseline")).align_items == .baseline);
    // takumi's keyword sets (oracle: bench/probe/f2/align.mjs)
    try t.bad("alignItems", "last baseline");
    try t.bad("alignItems", "first baseline");
    try t.bad("alignItems", "left");
    try t.bad("justifyItems", "legacy center");
    try t.bad("alignSelf", "auto");
    try t.bad("justifySelf", "auto");
    try t.bad("justifyContent", "right");
    try t.bad("justifyContent", "baseline");
    try t.bad("justifyContent", "self-start");
    try t.bad("alignItems", "flow-start");
    try T.expect((try t.one("justifyContent", "flow-end")).justify_content == .flex_end);
    try T.expect((try t.one("alignContent", "unsafe flow-start")).align_content == .flex_start);
    // safe / unsafe: only before a positional keyword; `safe` is kept per property
    var sf = try t.one("justifyContent", "safe center");
    try T.expect(sf.justify_content == .center and sf.align_safe[3] and sf.alignSafe().justify_content and !sf.alignSafe().align_items);
    sf = try t.one("justifyContent", "unsafe center");
    try T.expect(sf.justify_content == .center and !sf.align_safe[3]);
    sf = try t.one("alignSelf", "SAFE self-end");
    try T.expect(sf.align_self == .self_end and sf.align_safe[1] and @as(u8, @bitCast(sf.alignSafe())) == 2);
    sf = try t.one("placeItems", "safe center unsafe end");
    try T.expect(sf.align_items == .center and sf.justify_items == .end and sf.align_safe[0] and !sf.align_safe[4]);
    sf = try t.one("placeContent", "safe end");
    try T.expect(sf.align_safe[2] and sf.align_safe[3]);
    try t.bad("alignItems", "safe stretch");
    try t.bad("alignItems", "safe baseline");
    try t.bad("alignItems", "safe normal");
    try t.bad("justifyContent", "safe space-between");
    try t.bad("justifyContent", "safe safe center");
    try t.bad("justifyContent", "center safe");
    try t.bad("justifyContent", "safe");
    try t.bad("alignItems", "space-between");
    try t.bad("justifyContent", "auto");
    const p = try t.one("placeItems", "center end");
    try T.expect(p.align_items == .center and p.justify_items == .end);
    const p2 = try t.one("placeContent", "space-around");
    try T.expect(p2.align_content == .space_around and p2.justify_content == .space_around);
    const p3 = try t.one("placeSelf", "stretch");
    try T.expect(p3.align_self == .stretch and p3.justify_self == .stretch);
}

test "grid" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try t.one("gridTemplateColumns", "[a] 100px repeat(2, 1fr [b] minmax(10px, auto)) fit-content(40%) [end]");
    const tr = s.grid_template_columns.tracks;
    try T.expectEqual(@as(usize, 6), tr.len);
    try expectLP(tr[0].min.lp, 100, 0);
    try T.expect(tr[1].min == .auto and tr[1].max == .fr and tr[1].max.fr == 1);
    try expectLP(tr[2].min.lp, 10, 0);
    try T.expect(tr[2].max == .auto);
    try T.expect(tr[3].max.fr == 1);
    try T.expect(tr[5].min == .auto and tr[5].max == .fit_content);
    try T.expect(s.grid_template_columns.auto_repeat == .none);
    s = try t.one("gridTemplateRows", "50px repeat(auto-fill, minmax(100px, 1fr)) 20px");
    const g = s.grid_template_rows;
    try T.expect(g.auto_repeat == .fill and g.auto_repeat_start == 1 and g.auto_repeat_len == 1 and g.tracks.len == 3);
    s = try t.one("gridTemplateColumns", "repeat(auto-fit, 10px 20px)");
    try T.expect(s.grid_template_columns.auto_repeat == .fit and s.grid_template_columns.auto_repeat_len == 2);
    s = try t.one("gridTemplateColumns", "none");
    try T.expectEqual(@as(usize, 0), s.grid_template_columns.tracks.len);
    s = try t.one("gridTemplateColumns", "repeat(3, 1fr)");
    try T.expectEqual(@as(usize, 3), s.grid_template_columns.tracks.len);
    s = try t.one("gridAutoRows", "min-content 2fr");
    try T.expect(s.grid_auto_rows.len == 2 and s.grid_auto_rows[0].min == .min_content);
    try t.bad("gridTemplateColumns", "repeat(0, 1fr)");
    try t.bad("gridTemplateColumns", "repeat(auto-fill, 1fr) repeat(auto-fit, 2px)");
    try t.bad("gridTemplateColumns", "minmax(1fr, 2fr)");
    try t.bad("gridTemplateColumns", "repeat(2, repeat(2, 1px))");
    try t.bad("gridTemplateColumns", "banana");
    try t.bad("gridTemplateColumns", "repeat(5000, 1px 2px 3px)");
    try T.expectEqual(@as(usize, 10000), (try t.one("gridTemplateColumns", "repeat(100000, 1px)")).grid_template_columns.tracks.len);
    s = try t.one("gridAutoFlow", "dense column");
    try T.expect(s.grid_auto_flow.column and s.grid_auto_flow.dense);
    s = try t.one("gridAutoFlow", "dense");
    try T.expect(!s.grid_auto_flow.column and s.grid_auto_flow.dense);
    s = try t.one("gridColumn", "1 / span 2");
    try T.expect(s.grid_column_start.line == 1 and s.grid_column_end.span == 2);
    s = try t.one("gridRow", "-1");
    try T.expect(s.grid_row_start.line == -1 and s.grid_row_end == .auto);
    s = try t.one("gridRow", "span 3 / auto");
    try T.expect(s.grid_row_start.span == 3 and s.grid_row_end == .auto);
    s = try t.one("gridArea", "1 / 2 / 3 / 4");
    try T.expect(s.grid_row_start.line == 1 and s.grid_column_start.line == 2 and s.grid_row_end.line == 3 and s.grid_column_end.line == 4);
    s = try t.one("gridArea", "2 / 3");
    try T.expect(s.grid_row_start.line == 2 and s.grid_column_start.line == 3 and s.grid_row_end == .auto);
    s = try t.style(null, "{\"gridColumnStart\": 2, \"gridColumnEnd\": \"span 2\", \"gridRowStart\": \"auto\", \"gridRowEnd\": \"3\"}");
    try T.expect(s.grid_column_start.line == 2 and s.grid_column_end.span == 2 and s.grid_row_end.line == 3);
    // takumi keeps line 0 (one line past the explicit grid), truncates numbers, clamps spans to >= 1
    try T.expect((try t.one("gridColumn", "0")).grid_column_start.line == 0);
    try T.expect((try t.one("gridColumn", "2.9")).grid_column_start.line == 2);
    try T.expect((try t.one("gridColumn", "header / span 2")).grid_column_start == .auto);
    try T.expect((try t.one("gridColumn", "span -1")).grid_column_start.span == 1);
    try T.expect((try t.one("gridColumn", "span 0")).grid_column_start.span == 1);
    try t.bad("gridArea", "1/2/3/4/5");
}

test "borders and outline" {
    var t = TestCx.init();
    defer t.deinit();
    t.ctx.dpr = 2;
    var s = try t.one("border", "2px solid red");
    for (0..4) |i| {
        try T.expectEqual(@as(f32, 4), s.border_width[i]);
        try T.expectEqual(computed.BorderStyle.solid, s.border_style[i]);
        try T.expect(s.border_color[i].rgba.eql(.{ .r = 255, .a = 255 }));
    }
    s = try t.one("border", "dashed");
    try T.expectEqual(@as(f32, 6), s.border_width[0]); // medium * dpr
    try T.expect(s.border_color[0] == .current);
    s = try t.one("border", "#000 thick double");
    try T.expectEqual(@as(f32, 10), s.border_width[2]);
    try T.expectEqual(computed.BorderStyle.double, s.border_style[2]);
    s = try t.style(null, "{\"border\": \"1px solid\", \"borderLeft\": \"thin dotted blue\", \"borderTopWidth\": 0.3, \"borderRightStyle\": \"none\"}");
    try T.expectEqual(computed.BorderStyle.dotted, s.border_style[3]);
    try T.expectEqual(@as(f32, 2), s.border_width[3]);
    try T.expect(approx(s.border_width[0], 0.6));
    const used = s.usedBorderWidths();
    try T.expectEqual([4]f32{ 1, 0, 2, 2 }, used);
    s = try t.one("borderWidth", "1px 2.7px");
    try T.expectEqual([4]f32{ 2, 5.4, 2, 5.4 }, s.border_width);
    try T.expectEqual(@as(f32, 0), s.usedBorderWidths()[0]); // style none
    s = try t.one("borderStyle", "solid none groove");
    try T.expectEqual([4]computed.BorderStyle{ .solid, .none, .groove, .none }, s.border_style);
    s = try t.one("borderColor", "red green blue yellow");
    try T.expect(s.border_color[3].rgba.eql(.{ .r = 255, .g = 255, .a = 255 }));
    // takumi's border shorthand: a repeated component replaces the earlier one; a line width is a <length>
    // whose `auto` and percentages are 0 (oracle: bench/probe/f2/accept2.mjs)
    s = try t.one("border", "2px 3px solid");
    try T.expectEqual([4]f32{ 6, 6, 6, 6 }, s.border_width);
    s = try t.one("border", "solid dashed");
    try T.expect(s.border_style[0] == .dashed);
    s = try t.one("border", "auto solid red");
    try T.expect(s.border_width[0] == 0 and s.border_style[0] == .solid);
    s = try t.one("borderWidth", "10% auto");
    try T.expectEqual([4]f32{ 0, 0, 0, 0 }, s.border_width);
    try t.bad("borderWidth", "-1px");
    try t.bad("borderWidth", "-10%");
    try t.bad("borderStyle", "wavy");
    try t.bad("borderStyle", "auto");
    // `auto` in the outline shorthand is a width (0), not a style; outline-style / outline-color have no auto
    s = try t.one("outline", "3px auto");
    try T.expect(s.outline_style == .none and s.outline_width == 0);
    try t.bad("outlineStyle", "auto");
    try t.bad("outlineColor", "auto");
    try T.expect((try t.one("outlineOffset", "auto")).outline_offset == 0);
    s = try t.style(null, "{\"outlineColor\": \"red\", \"outlineOffset\": \"-2px\", \"outlineStyle\": \"dashed\", \"outlineWidth\": \"thin\"}");
    try T.expect(s.outline_offset == -4 and s.outline_style == .dashed and s.outline_width == 2);
    try T.expectEqual(@as(f32, 2), s.usedOutlineWidth());
}

test "border radius" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try t.one("borderRadius", "10px");
    for (s.border_radius) |r| {
        try expectLP(r[0], 10, 0);
        try expectLP(r[1], 10, 0);
    }
    s = try t.one("borderRadius", "1px 2px 3px 4px / 5% 6%");
    try expectLP(s.border_radius[0][0], 1, 0);
    try expectLP(s.border_radius[2][0], 3, 0);
    try expectLP(s.border_radius[0][1], 0, 0.05);
    try expectLP(s.border_radius[1][1], 0, 0.06);
    try expectLP(s.border_radius[2][1], 0, 0.05);
    try expectLP(s.border_radius[3][1], 0, 0.06);
    s = try t.one("borderRadius", "1px 2px 3px");
    try expectLP(s.border_radius[3][0], 2, 0);
    s = try t.style(null, "{\"borderRadius\": 8, \"borderTopLeftRadius\": \"4px 50%\", \"borderBottomLeftRadius\": 0}");
    try expectLP(s.border_radius[0][0], 4, 0);
    try expectLP(s.border_radius[0][1], 0, 0.5);
    try expectLP(s.border_radius[3][0], 0, 0);
    try expectLP(s.border_radius[1][1], 8, 0);
    _ = try t.one("borderRadius", "-1px"); // takumi accepts
    try t.bad("borderRadius", "1px / 2px / 3px");
    try t.bad("borderRadius", "1px 2px 3px 4px 5px");
}

test "backgrounds" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try t.one("backgroundColor", "#ff000080");
    try T.expect(s.background_color.rgba.eql(.{ .r = 255, .a = 128 }));
    s = try t.one("backgroundImage", "linear-gradient(red, blue), url(\"a.png\"), none");
    try T.expectEqual(@as(usize, 3), s.background_image.len);
    try T.expect(s.background_image[0] == .gradient);
    try T.expectEqualStrings("a.png", s.background_image[1].url);
    try T.expect(s.background_image[2] == .none);
    s = try t.style(null,
        \\{"backgroundImage": "url(a), url(b), url(c)", "backgroundSize": "cover, 10px auto",
        \\ "backgroundPosition": "right 10px top", "backgroundRepeat": "no-repeat, repeat-x",
        \\ "backgroundClip": "content-box", "backgroundOrigin": "border-box, content-box"}
    );
    const l2 = s.bgLayer(2);
    try T.expect(l2.size == .cover);
    try T.expect(s.bgLayer(1).size.size[0].lp.px == 10 and s.bgLayer(1).size.size[1] == .auto);
    try expectLP(l2.position[0], -10, 1);
    try expectLP(l2.position[1], 0, 0);
    try T.expectEqual([2]computed.BgRepeat{ .no_repeat, .no_repeat }, l2.repeat);
    try T.expectEqual([2]computed.BgRepeat{ .repeat, .no_repeat }, s.bgLayer(1).repeat);
    try T.expect(l2.clip == .content_box and l2.origin == .border_box);
    try T.expect(s.bgColorClip() == .content_box);
    s = try t.one("backgroundRepeat", "space round");
    try T.expectEqual([2]computed.BgRepeat{ .space, .round }, s.background_repeat[0]);
    s = try t.one("backgroundSize", "50%");
    try T.expect(s.background_size[0].size[0].lp.pct == 0.5 and s.background_size[0].size[1] == .auto);
    s = try t.one("backgroundClip", "text");
    try T.expect(s.background_clip[0] == .text);
    try t.bad("backgroundOrigin", "text");
    try t.bad("backgroundSize", "cover cover");
    try t.bad("backgroundImage", "foo(1)");
    try t.bad("backgroundImage", "url(a),");
    try t.bad("backgroundPosition", "top 10px");
}

test "background shorthand" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try t.one("background", "red");
    try T.expect(s.background_color.rgba.eql(.{ .r = 255, .a = 255 }));
    try T.expectEqual(@as(usize, 1), s.background_image.len);
    try T.expect(s.background_image[0] == .none);
    s = try t.one("background", "url(x.png) center / contain no-repeat padding-box content-box fixed, linear-gradient(red, blue) #00f");
    try T.expectEqual(@as(usize, 2), s.background_image.len);
    const l0 = s.bgLayer(0);
    try T.expectEqualStrings("x.png", l0.image.url);
    try expectLP(l0.position[0], 0, 0.5);
    try T.expect(l0.size == .contain);
    try T.expectEqual([2]computed.BgRepeat{ .no_repeat, .no_repeat }, l0.repeat);
    try T.expect(l0.origin == .padding_box and l0.clip == .content_box);
    const l1 = s.bgLayer(1);
    try T.expect(l1.image == .gradient and l1.clip == .border_box and l1.origin == .padding_box);
    try T.expect(s.background_color.rgba.eql(.{ .b = 255, .a = 255 }));
    s = try t.one("background", "content-box radial-gradient(circle, red, blue) 10px 20px / 5px 6px repeat-y");
    const l = s.bgLayer(0);
    try T.expect(l.origin == .content_box and l.clip == .content_box);
    try expectLP(l.position[0], 10, 0);
    try expectLP(l.size.size[1].lp, 6, 0);
    // background resets previously set longhands
    s = try t.style(null, "{\"backgroundColor\": \"red\", \"backgroundSize\": \"cover\", \"background\": \"none\"}");
    try T.expect(s.background_color.rgba.a == 0 and s.background_size[0] != .cover);
    s = try t.one("background", "red, url(a)"); // takumi accepts a colour in a non-final layer
    try T.expect(s.background_color.rgba.r == 255 and s.background_image.len == 2);
    try t.bad("background", "url(a) url(b)");
    try t.bad("background", "red blue");
    try t.bad("background", "center / ");
    try t.bad("background", ",red");
}

test "shadows" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try t.one("boxShadow", "0 12px 40px rgba(0,0,0,0.35)");
    try T.expectEqual(@as(usize, 1), s.box_shadow.len);
    var sh = s.box_shadow[0];
    try T.expect(sh.x == 0 and sh.y == 12 and sh.blur == 40 and sh.spread == 0 and !sh.inset);
    try T.expect(sh.color.rgba.eql(.{ .a = 89 }));
    s = try t.one("boxShadow", "inset red 1px 2px 3px 4px, 5px 6px, 1px 1px blue inset");
    try T.expectEqual(@as(usize, 3), s.box_shadow.len);
    sh = s.box_shadow[0];
    try T.expect(sh.inset and sh.spread == 4 and sh.color.rgba.r == 255);
    try T.expect(s.box_shadow[1].color == .current and !s.box_shadow[1].inset);
    try T.expect(s.box_shadow[2].inset and s.box_shadow[2].color.rgba.b == 255);
    s = try t.one("boxShadow", "none");
    try T.expectEqual(@as(usize, 0), s.box_shadow.len);
    try t.bad("boxShadow", "1px");
    try T.expectEqual(@as(f32, 0), (try t.one("boxShadow", "1px 2px -3px")).box_shadow[0].blur); // takumi accepts
    try t.bad("boxShadow", "1px 2px red 3px");
    try t.bad("boxShadow", "1px 2px 3px 4px 5px");
    try t.bad("boxShadow", "inset inset 1px 1px");
    try t.bad("boxShadow", "1px 1px,");
    try t.bad("boxShadow", "10% 1px");
    s = try t.one("textShadow", "1px 1px 2px black, 0 0 1em blue");
    try T.expectEqual(@as(usize, 2), s.text_shadow.len);
    try T.expect(s.text_shadow[1].blur == 16);
    try t.bad("textShadow", "1px 1px 1px 1px");
    try t.bad("textShadow", "inset 1px 1px");
}

test "opacity / filter / blend / object / image-rendering" {
    var t = TestCx.init();
    defer t.deinit();
    try T.expectEqual(@as(f32, 0.5), (try t.one("opacity", "50%")).opacity);
    try T.expectEqual(@as(f32, 1), (try t.one("opacity", "2")).opacity);
    try T.expectEqual(@as(f32, 0), (try t.one("opacity", "-1")).opacity);
    try T.expectEqual(@as(f32, 0.25), (try t.style(null, "{\"opacity\": 0.25}")).opacity);
    try t.bad("opacity", "half");
    const s = try t.one("filter", "blur(4px) brightness(150%) contrast(2) grayscale(2) invert() opacity(.5) saturate(0) sepia(100%) hue-rotate(90deg) drop-shadow(1px 2px 3px red)");
    try T.expectEqual(@as(usize, 10), s.filter.len);
    try T.expect(s.filter[0].blur == 4 and s.filter[1].brightness == 1.5 and s.filter[2].contrast == 2);
    try T.expect(s.filter[3].grayscale == 1 and s.filter[4].invert == 1 and s.filter[5].opacity == 0.5);
    try T.expect(s.filter[8].hue_rotate == 90 and s.filter[9].drop_shadow.blur == 3);
    try T.expectEqual(@as(usize, 0), (try t.one("filter", "none")).filter.len);
    try T.expectEqual(@as(f32, 0), (try t.one("filter", "blur(-1px)")).filter[0].blur);
    try T.expectEqual(@as(usize, 0), (try t.one("filter", "url(#f)")).filter.len);
    const url_then_grayscale = try t.one("filter", "url(#f) grayscale(1)");
    try T.expectEqual(@as(usize, 1), url_then_grayscale.filter.len);
    try T.expect(url_then_grayscale.filter[0].grayscale == 1);
    try t.bad("filter", "brightness(-1)");
    try t.bad("filter", "blur(1px, 2px)");
    try T.expect((try t.one("mixBlendMode", "color-dodge")).mix_blend_mode == .color_dodge);
    try T.expect((try t.one("mixBlendMode", "plus-lighter")).mix_blend_mode == .plus_lighter);
    try t.bad("mixBlendMode", "add");
    try T.expect((try t.one("objectFit", "scale-down")).object_fit == .scale_down);
    const op = try t.one("objectPosition", "left bottom");
    try expectLP(op.object_position[0], 0, 0);
    try expectLP(op.object_position[1], 0, 1);
    try T.expect((try t.one("imageRendering", "pixelated")).image_rendering == .pixelated);
    try T.expect((try t.one("imageRendering", "crisp-edges")).image_rendering == .crisp_edges);
    try T.expect((try t.one("imageRendering", "high-quality")).image_rendering == .smooth);
}

test "transforms" {
    var t = TestCx.init();
    defer t.deinit();
    t.ctx.dpr = 2;
    var s = try t.one("transform", "translate(10px, 50%) translateX(1px) translateY(-5%) scale(2) scale(1, 50%) scaleX(3) scaleY(.5) rotate(90deg) rotate(0.5turn) rotate(3.14159rad) skew(10deg) skewX(5deg) skewY(1grad) matrix(1, 0, 0, 1, 10, 20)");
    const o = s.transform;
    try T.expectEqual(@as(usize, 14), o.len);
    try expectLP(o[0].translate[0], 20, 0);
    try expectLP(o[0].translate[1], 0, 0.5);
    try expectLP(o[1].translate[0], 2, 0);
    try expectLP(o[2].translate[1], 0, -0.05);
    try T.expectEqual([2]f32{ 2, 2 }, o[3].scale);
    try T.expectEqual([2]f32{ 1, 0.5 }, o[4].scale);
    try T.expectEqual([2]f32{ 3, 1 }, o[5].scale);
    try T.expectEqual([2]f32{ 1, 0.5 }, o[6].scale);
    try T.expectEqual(@as(f32, 90), o[7].rotate);
    try T.expectEqual(@as(f32, 180), o[8].rotate);
    try T.expect(approx(o[9].rotate, 180));
    try T.expectEqual([2]f32{ 10, 0 }, o[10].skew);
    try T.expectEqual([2]f32{ 0, 0.9 }, o[12].skew);
    try T.expectEqual([6]f32{ 1, 0, 0, 1, 20, 40 }, o[13].matrix);
    try T.expectEqual(@as(usize, 0), (try t.one("transform", "none")).transform.len);
    try T.expectEqual(@as(f32, 0), (try t.one("transform", "rotate(0)")).transform[0].rotate);
    try T.expectEqual(@as(f32, 45), (try t.one("transform", "rotate(45)")).transform[0].rotate); // takumi: unitless = deg
    try t.bad("transform", "translate3d(1px, 2px, 3px)");
    try t.bad("transform", "matrix(1, 2)");
    try t.bad("transform", "translate(1px 2px)");
    try t.bad("transform", "scale()");
    try t.bad("transform", "rotate(45deg),");
    s = try t.style(null, "{\"translate\": \"10px 20%\", \"rotate\": \"45deg\", \"scale\": \"2 3\", \"transformOrigin\": \"top left\"}");
    try expectLP(s.translate[0], 20, 0);
    try expectLP(s.translate[1], 0, 0.2);
    try T.expectEqual(@as(f32, 45), s.rotate);
    try T.expectEqual([2]f32{ 2, 3 }, s.scale);
    try expectLP(s.transform_origin[0], 0, 0);
    try expectLP(s.transform_origin[1], 0, 0);
    s = try t.one("transformOrigin", "20px 30% 5px");
    try expectLP(s.transform_origin[0], 40, 0);
    try expectLP(s.transform_origin[1], 0, 0.3);
    s = try t.one("transformOrigin", "bottom");
    try expectLP(s.transform_origin[0], 0, 0.5);
    try expectLP(s.transform_origin[1], 0, 1);
    try T.expectEqual([2]f32{ 1.5, 1.5 }, (try t.one("scale", "150%")).scale);
    try T.expectEqual(@as(f32, 0), (try t.one("rotate", "none")).rotate);
    try t.bad("rotate", "x 10deg");
}

test "font properties" {
    var t = TestCx.init();
    defer t.deinit();
    const parent = try t.style(null, "{\"fontWeight\": 300}");
    const wts = [_]struct { []const u8, u16 }{
        .{ "normal", 400 }, .{ "bold", 700 }, .{ "bolder", 400 }, .{ "lighter", 100 }, .{ "1", 1 }, .{ "1000", 1000 }, .{ "550", 550 },
    };
    for (wts) |w| {
        const members = try t.a().alloc(json.Member, 1);
        members[0] = .{ .key = "fontWeight", .value = .{ .string = w[0] } };
        const s = try compute(t.a(), &t.ctx, &parent, null, json.Value{ .object = members }, &t.diag);
        try T.expectEqual(w[1], s.font_weight);
    }
    const p6 = try t.style(null, "{\"fontWeight\": 600}");
    try T.expectEqual(@as(u16, 900), (try t.style(&p6, "{\"fontWeight\": \"bolder\"}")).font_weight);
    try T.expectEqual(@as(u16, 400), (try t.style(&p6, "{\"fontWeight\": \"lighter\"}")).font_weight);
    try t.bad("fontWeight", "0");
    try t.bad("fontWeight", "1001");
    try t.bad("fontWeight", "heavy");
    try T.expectEqual(computed.FontStyle.italic, (try t.one("fontStyle", "italic")).font_style);
    try T.expectEqual(computed.FontStyle.oblique, (try t.one("fontStyle", "oblique 10deg")).font_style);
    var s = try t.one("fontFamily", "\"Helvetica Neue\",  Times   New Roman , monospace");
    try T.expectEqual(@as(usize, 3), s.font_family.len);
    try T.expectEqualStrings("Helvetica Neue", s.font_family[0]);
    try T.expectEqualStrings("Times New Roman", s.font_family[1]);
    try T.expectEqualStrings("monospace", s.font_family[2]);
    try t.bad("fontFamily", "Arial,");
    try t.bad("fontFamily", "12px");
    s = try t.one("font", "italic bold 20px/1.5 Inter, sans-serif");
    try T.expect(s.font_style == .italic and s.font_weight == 700 and s.font_size == 20);
    try T.expect(s.line_height.number == 1.5 and s.font_family.len == 2);
    s = try t.one("font", "12px/30px Georgia");
    try T.expect(s.font_size == 12 and s.line_height.px == 30 and s.font_weight == 400);
    s = try t.one("font", "small-caps 600 condensed 2em/1em 'A B'");
    try T.expect(s.font_size == 32 and s.line_height.px == 32 and s.font_weight == 600);
    s = try t.style(null, "{\"fontWeight\": 700, \"lineHeight\": 3, \"font\": \"16px serif\"}");
    try T.expect(s.font_weight == 400 and s.line_height == .normal);
    try t.bad("font", "bold");
    try t.bad("font", "12px");
    try t.bad("font", "caption");
    s = try t.style(null, "{\"lineHeight\": \"normal\"}");
    try T.expect(s.line_height == .normal);
    s = try t.style(null, "{\"lineHeight\": \"1.25\"}");
    try T.expect(s.line_height.number == 1.25);
    s = try t.style(null, "{\"lineHeight\": 24}");
    try T.expect(s.line_height.number == 24);
    s = try t.style(null, "{\"lineHeight\": \"24px\"}");
    try T.expect(s.line_height.px == 24);
    s = try t.style(null, "{\"lineHeight\": \"calc(1 + 0.5)\"}");
    try T.expect(s.line_height.number == 1.5);
    try T.expect((try t.one("lineHeight", "-1")).line_height.number == 0);
}

test "text properties" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try t.style(null,
        \\{"fontSize": 20, "letterSpacing": "0.5em", "wordSpacing": "normal", "textAlign": "justify", "textTransform": "uppercase",
        \\ "textIndent": "10%", "tabSize": 4, "direction": "rtl", "wordBreak": "break-all", "overflowWrap": "anywhere",
        \\ "textOverflow": "ellipsis", "WebkitLineClamp": 3, "WebkitTextStroke": "2px red"}
    );
    try T.expect(s.letter_spacing == 10 and s.word_spacing == 0 and s.text_align == .justify and s.text_transform == .uppercase);
    try expectLP(s.text_indent, 0, 0.1);
    try T.expect(s.tab_size.number == 4 and s.direction == .rtl and s.word_break == .break_all and s.overflow_wrap == .anywhere);
    try T.expect(s.text_overflow == .ellipsis and s.line_clamp == 3);
    try T.expect(s.webkit_text_stroke_width == 2 and s.webkit_text_stroke_color.rgba.r == 255);
    try T.expect((try t.one("wordWrap", "break-word")).overflow_wrap == .break_word);
    try T.expect((try t.one("lineClamp", "none")).line_clamp == 0);
    try T.expect((try t.one("lineClamp", "0")).line_clamp == 0);
    s = try t.one("lineClamp", "2 \" >\"");
    try T.expect(s.line_clamp == 2 and s.block_ellipsis == .string and std.mem.eql(u8, s.block_ellipsis_string, " >"));
    s = try t.one("lineClamp", "\"x\" 3");
    try T.expect(s.line_clamp == 3 and s.block_ellipsis == .string);
    s = try t.one("lineClamp", "3 no-ellipsis");
    try T.expect(s.line_clamp == 3 and s.block_ellipsis == .none);
    try T.expect((try t.one("WebkitLineClamp", "2")).block_ellipsis == .auto);
    try t.bad("lineClamp", "2 3");
    try t.bad("WebkitLineClamp", "2 \"x\"");
    s = try t.one("textOverflow", "\"--\"");
    try T.expect(s.text_overflow == .string and std.mem.eql(u8, s.text_overflow_string, "--"));
    try t.bad("textOverflow", "string");
    try t.bad("translate", "1px 2px 3px");
    try t.bad("textAlign", "middle");
    try T.expect((try t.one("tabSize", "20px")).tab_size.px == 20);
    // white-space
    const ws = [_]struct { []const u8, computed.WhiteSpaceCollapse, computed.TextWrapMode }{
        .{ "normal", .collapse, .wrap },            .{ "nowrap", .collapse, .nowrap },        .{ "pre", .preserve, .nowrap },
        .{ "pre-wrap", .preserve, .wrap },          .{ "pre-line", .preserve_breaks, .wrap }, .{ "break-spaces", .break_spaces, .wrap },
        .{ "preserve nowrap", .preserve, .nowrap },
    };
    for (ws) |w| {
        s = try t.one("whiteSpace", w[0]);
        try T.expect(s.white_space_collapse == w[1] and s.text_wrap_mode == w[2]);
    }
    try t.bad("whiteSpace", "pre pre");
    s = try t.one("textWrap", "balance");
    try T.expect(s.text_wrap_style == .balance and s.text_wrap_mode == .wrap);
    s = try t.one("textWrap", "nowrap");
    try T.expect(s.text_wrap_mode == .nowrap);
    s = try t.style(null, "{\"textWrapMode\": \"nowrap\", \"textWrapStyle\": \"pretty\", \"whiteSpaceCollapse\": \"preserve-breaks\"}");
    try T.expect(s.text_wrap_mode == .nowrap and s.text_wrap_style == .pretty and s.white_space_collapse == .preserve_breaks);
    // text-decoration
    s = try t.one("textDecoration", "underline line-through wavy red 2px");
    try T.expect(s.text_decoration_line.underline and s.text_decoration_line.line_through and !s.text_decoration_line.overline);
    try T.expect(s.text_decoration_style == .wavy and s.text_decoration_color.rgba.r == 255 and s.text_decoration_thickness.? == 2);
    s = try t.one("textDecoration", "none");
    try T.expect(!s.text_decoration_line.underline);
    s = try t.style(null, "{\"textDecorationLine\": \"overline\", \"textDecorationColor\": \"blue\", \"textDecorationStyle\": \"dotted\", \"textDecorationThickness\": \"from-font\"}");
    try T.expect(s.text_decoration_line.overline and s.text_decoration_style == .dotted and s.text_decoration_thickness == null);
    try T.expect((try t.one("textDecoration", "underline underline")).text_decoration_line.underline);
    try t.bad("textDecorationLine", "solid");
    try t.bad("letterSpacing", "wide");
}

// ---------------------------------------------------------------------------------------------
// phase 2 tests

/// Computes from a CSS declaration block given as lenient rules (plus optional strict JSON style).
fn css(t: *TestCx, parent: ?*const ComputedStyle, text: []const u8) !ComputedStyle {
    const d = try parseDeclarationBlock(t.a(), text);
    return computeEx(t.a(), &t.ctx, parent, null, d, null, &t.diag);
}

test "property names: camel, kebab, vendor" {
    try T.expectEqual(Prop.backgroundColor, propertyId("backgroundColor").?);
    try T.expectEqual(Prop.backgroundColor, propertyId("background-color").?);
    try T.expectEqual(Prop.backgroundColor, propertyId("BACKGROUND-COLOR").?);
    try T.expectEqual(Prop.WebkitLineClamp, propertyId("-webkit-line-clamp").?);
    try T.expectEqual(Prop.WebkitLineClamp, propertyId("WebkitLineClamp").?);
    try T.expectEqual(Prop.WebkitMaskImage, propertyId("-webkit-mask-image").?);
    try T.expectEqual(Prop.borderStartStartRadius, propertyId("border-start-start-radius").?);
    try T.expect(propertyId("--x") == null);
    try T.expectEqual(Prop.backgroundClip, propertyId("-webkit-background-clip").?);
    try T.expectEqual(Prop.backgroundClip, propertyId("WebkitBackgroundClip").?);
    try T.expectEqual(Prop.WebkitTextFillColor, propertyId("-webkit-text-fill-color").?);
    try T.expect(propertyId("-webkit-nonsense") == null);
    try T.expect(propertyId("Webkit") == null);
    try T.expect(propertyId("-moz-thing") == null);
    try T.expect(propertyId("background--color") != null); // empty segment collapses; harmless
    try T.expect(propertyId("") == null);
}

test "parseDeclarationBlock" {
    var t = TestCx.init();
    defer t.deinit();
    const d = try parseDeclarationBlock(t.a(),
        \\ color: red; background: url("a;b.png") no-repeat ; --x: { a; b } ;
        \\ /* c: d; */ width : 10px !important; content: "x\";y" ; bad ; :novalue; height:/*:*/5px ! IMPORTANT;font-family: 'a;b'
    );
    const want = [_]struct { []const u8, []const u8, bool }{
        .{ "color", "red", false },           .{ "background", "url(\"a;b.png\") no-repeat", false },
        .{ "--x", "{ a; b }", false },        .{ "width", "10px", true },
        .{ "content", "\"x\\\";y\"", false }, .{ "height", "5px", true },
        .{ "font-family", "'a;b'", false },
    };
    try T.expectEqual(want.len, d.len);
    for (want, d) |w, x| {
        try T.expectEqualStrings(w[0], x.name);
        try T.expectEqualStrings(w[1], std.mem.trim(u8, x.value, " "));
        try T.expectEqual(w[2], x.important);
    }
    try T.expectEqual(@as(usize, 0), (try parseDeclarationBlock(t.a(), "")).len);
    try T.expectEqual(@as(usize, 0), (try parseDeclarationBlock(t.a(), ";;; ; /* x */")).len);
    try T.expectEqual(@as(usize, 1), (try parseDeclarationBlock(t.a(), "a:b; \"unterminated: x")).len);
}

test "cascade: layers, !important, lenient" {
    var t = TestCx.init();
    defer t.deinit();
    const preset = try json.parse(t.a(), "{\"width\": 1, \"height\": \"2px !important\", \"color\": \"red\"}");
    const sty = try json.parse(t.a(), "{\"width\": 3, \"height\": 4, \"minWidth\": \"5px\"}");
    const rules = try parseDeclarationBlock(t.a(), "width: 7px; height: 8px; min-width: 9px !important; color: blue; padding: banana; margin-top: 6px; margin-top: nope");
    const s = try computeEx(t.a(), &t.ctx, null, preset, rules, sty, &t.diag);
    try expectLP(s.width.lp, 3, 0); // inline style beats rules
    try expectLP(s.height.lp, 2, 0); // important preset beats everything normal
    try expectLP(s.min_width.lp, 9, 0); // important rule beats normal inline
    try T.expect(s.color.eql(.{ .b = 255, .a = 255 }));
    try expectLP(s.margin[0].lp, 6, 0); // invalid later declaration dropped
    try expectLP(s.padding[0], 0, 0);
    // among important, the later layer wins
    const p2 = try json.parse(t.a(), "{\"width\": \"1px !important\"}");
    const s2 = try computeEx(t.a(), &t.ctx, null, p2, try parseDeclarationBlock(t.a(), "width: 2px !important"), null, &t.diag);
    try expectLP(s2.width.lp, 2, 0);
    // lenient: a partially-parsed invalid value leaves no writes
    const s3 = try css(&t, null, "padding: 1px 2px; padding: 5px 6px banana zz q");
    try expectLP(s3.padding[0], 1, 0);
    try expectLP(s3.padding[3], 2, 0);
    // strict inline style still throws, rules never do
    const bad_style = try json.parse(t.a(), "{\"width\": \"banana\"}");
    try T.expectError(error.InvalidStyleValue, computeEx(t.a(), &t.ctx, null, null, rules, bad_style, &t.diag));
    try T.expectEqualStrings("width", t.diag.property);
    // generic layers
    const l1 = [_]Declaration{.{ .name = "opacity", .value = "0.5" }};
    const l2 = [_]Declaration{ .{ .name = "opacity", .value = "0.25" }, .{ .name = "z-index", .value = "", .number = 4 } };
    const s4 = try computeLayers(t.a(), &t.ctx, null, &.{ .{ .decls = &l2, .lenient = true }, .{ .decls = &l1 } }, &t.diag);
    try T.expectEqual(@as(f32, 0.5), s4.opacity);
    try T.expectEqual(@as(?i32, 4), s4.z_index);
}

test "custom properties and var()" {
    var t = TestCx.init();
    defer t.deinit();
    const root = try css(&t, null, "--gap: 4px; --c: red; --pad: var(--gap) 2px; --b: var(--a); --a: var(--b); --self: var(--self, 1px)");
    try T.expectEqualStrings("4px", root.customProperty("--gap").?);
    try T.expectEqualStrings("4px 2px", root.customProperty("--pad").?);
    try T.expect(root.customProperty("--a") == null); // cycle -> invalid
    try T.expect(root.customProperty("--b") == null);
    try T.expect(root.customProperty("--self") == null);
    const child = try css(&t, &root, "padding: var(--pad); color: var(--c); margin-top: var(--missing, var(--gap)); width: var(--a, 3px); --c: blue; border-color: var(--c)");
    try expectLP(child.padding[0], 4, 0);
    try expectLP(child.padding[1], 2, 0);
    try T.expect(child.color.eql(.{ .b = 255, .a = 255 })); // own --c overrides inherited
    try expectLP(child.margin[0].lp, 4, 0);
    try expectLP(child.width.lp, 3, 0); // invalid var -> fallback
    try T.expectEqualStrings("4px", child.customProperty("--gap").?); // inherited
    try T.expect(child.border_color[0].rgba.eql(.{ .b = 255, .a = 255 }));
    // invalid at computed-value time -> unset (inherits for inherited properties)
    const p = try css(&t, null, "color: green; --bad: banana");
    const c2 = try css(&t, &p, "color: var(--bad); width: var(--nope); font-size: calc(var(--n, 2) * 10px)");
    try T.expect(c2.color.eql(.{ .g = 128, .a = 255 }));
    try T.expect(c2.width == .auto);
    try T.expectEqual(@as(f32, 20), c2.font_size);
    // JSON style also supports var and custom props (numbers formatted)
    const s = try t.style(null, "{\"--w\": 12, \"--h\": 1.5, \"width\": \"var(--w)\", \"lineHeight\": \"var(--h)\", \"--i\": \"initial\"}");
    try expectLP(s.width.lp, 12, 0);
    try T.expect(s.line_height.number == 1.5);
    try T.expect(s.customProperty("--i") == null);
    // inherit / unset on custom
    const c3 = try css(&t, &root, "--gap: inherit; --c: initial; height: var(--gap)");
    try expectLP(c3.height.lp, 4, 0);
    try T.expect(c3.customProperty("--c") == null);
    // token separation: var(--n)px must not form a dimension
    const c4 = try css(&t, null, "--n: 5; width: var(--n)px");
    try T.expect(c4.width == .auto);
    // exponential blow-up is bounded
    const bomb = try css(&t, null, "--a: xx xx xx xx xx xx xx xx; --b: var(--a)var(--a)var(--a)var(--a)var(--a)var(--a)var(--a)var(--a); --c: var(--b)var(--b)var(--b)var(--b)var(--b)var(--b)var(--b)var(--b); --d: var(--c)var(--c)var(--c)var(--c)var(--c)var(--c)var(--c)var(--c); --e: var(--d)var(--d)var(--d)var(--d)var(--d)var(--d)var(--d)var(--d)");
    try T.expect(bomb.customProperty("--e") == null);
    try T.expect(bomb.customProperty("--c") != null);
    // deep chain past the depth limit is invalid, short chain fine
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    for (0..40) |i| {
        const w = std.fmt.bufPrint(buf[n..], "--v{d}: var(--v{d});", .{ i, i + 1 }) catch unreachable;
        n += w.len;
    }
    const w2 = std.fmt.bufPrint(buf[n..], "--v40: 1px; width: var(--v0); height: var(--v35)", .{}) catch unreachable;
    n += w2.len;
    const deep = try css(&t, null, buf[0..n]);
    try T.expect(deep.width == .auto);
}

test "logical properties" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try css(&t, null, "margin-inline: 1px 2px; padding-block: 3px; inset-inline-start: 4px; border-inline-start: 2px solid red; inline-size: 50%; max-block-size: 10px; border-start-end-radius: 6px");
    try expectLP(s.margin[3].lp, 1, 0);
    try expectLP(s.margin[1].lp, 2, 0);
    try expectLP(s.padding[0], 3, 0);
    try expectLP(s.padding[2], 3, 0);
    try expectLP(s.inset[3].lp, 4, 0);
    try T.expect(s.border_style[3] == .solid and s.border_width[3] == 2);
    try expectLP(s.width.lp, 0, 0.5);
    try expectLP(s.max_height.lp, 10, 0);
    try expectLP(s.border_radius[1][0], 6, 0);
    // rtl flips the inline axis, even when direction is declared later
    s = try css(&t, null, "margin-inline: 1px 2px; padding-inline-end: 5px; border-start-end-radius: 6px; direction: rtl; border-inline-width: 1px 3px; border-inline-style: solid");
    try expectLP(s.margin[1].lp, 1, 0);
    try expectLP(s.margin[3].lp, 2, 0);
    try expectLP(s.padding[3], 5, 0);
    try expectLP(s.border_radius[0][0], 6, 0);
    try T.expect(s.border_width[1] == 1 and s.border_width[3] == 3 and s.border_style[1] == .solid);
    // css-wide keywords on logical properties
    const p = try css(&t, null, "margin-left: 7px; padding-left: 9px");
    s = try css(&t, &p, "margin-inline-start: inherit; padding-inline: inherit");
    try expectLP(s.margin[3].lp, 7, 0);
    try expectLP(s.padding[3], 9, 0);
    // JSON camelCase + numbers
    s = try t.style(null, "{\"marginInline\": 5, \"paddingBlockStart\": 2, \"blockSize\": \"fit-content(20px)\"}");
    try expectLP(s.margin[1].lp, 5, 0);
    try expectLP(s.padding[0], 2, 0);
    try T.expect(s.height == .fit_content_lp);
    try t.bad("marginInline", "1px 2px 3px");
}

test "grid: areas, names, shorthands" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try t.one("gridTemplateAreas", "\"head head\" \"nav main\" \". main\"");
    const g = s.grid_template_areas;
    try T.expect(g.rows == 3 and g.cols == 2 and g.areas.len == 3);
    try T.expectEqualStrings("head", g.areas[0].name);
    try T.expect(g.areas[0].row_start == 0 and g.areas[0].row_end == 1 and g.areas[0].col_end == 2);
    try T.expect(g.areas[2].row_start == 1 and g.areas[2].row_end == 3 and g.areas[2].col_start == 1);
    try t.bad("gridTemplateAreas", "\"a b\" \"b a\"");
    try t.bad("gridTemplateAreas", "\"a b\" \"a\"");
    try t.bad("gridTemplateAreas", "\"a ! b\"");
    s = try t.one("gridTemplateColumns", "[full-start] 1fr [main-start] repeat(2, [col] 10px) [main-end] repeat(auto-fill, [x] 5px [y])");
    const ln = s.grid_template_columns.line_names;
    try T.expectEqual(@as(usize, 7), ln.len);
    try T.expectEqualStrings("full-start", ln[0].name);
    try T.expect(ln[1].line == 1 and ln[2].line == 1 and ln[3].line == 2 and ln[4].line == 3);
    try T.expectEqualStrings("main-end", ln[4].name);
    try T.expect(ln[5].in_repeat and ln[5].line == 0 and ln[6].line == 1);
    try t.bad("gridTemplateColumns", "[span] 1fr");
    s = try t.one("gridArea", "main");
    for (s.grid_line_names) |r| try T.expectEqualStrings("main", r.name);
    try T.expect(s.grid_row_start == .auto);
    // grid-row / grid-column: the end stays auto after a lone name (takumi; grid-area copies it)
    s = try t.one("gridColumn", "main");
    try T.expectEqualStrings("main", s.grid_line_names[1].name);
    try T.expect(s.grid_line_names[3].name.len == 0 and s.grid_column_end == .auto);
    s = try t.one("gridColumn", "col / span col");
    try T.expect(s.grid_line_names[1].n == 1 and s.grid_line_names[3].span);
    // takumi rejects <integer> <name> and span <integer> <name> in any order
    try t.bad("gridColumn", "2 col / span col");
    try t.bad("gridColumn", "col 2");
    try t.bad("gridRowStart", "span 3 x");
    try t.bad("gridRowStart", "span x 3");
    try t.bad("gridRowStart", "x span");
    try t.bad("gridRowStart", "2 span");
    try t.bad("gridArea", "1 / 2 a");
    s = try t.one("gridRow", "1 / span 2");
    try T.expect(s.grid_row_start.line == 1 and s.grid_row_end.span == 2 and s.grid_line_names[0].name.len == 0);
    try t.bad("gridRow", "span");
    try t.bad("gridRow", "0 x");
    s = try t.one("gridTemplate", "[top] \"a a\" 40px [mid] \"b c\" / 1fr 2fr");
    try T.expect(s.grid_template_rows.tracks.len == 2 and s.grid_template_columns.tracks.len == 2 and s.grid_template_areas.areas.len == 3);
    try expectLP(s.grid_template_rows.tracks[0].min.lp, 40, 0);
    try T.expect(s.grid_template_rows.tracks[1].min == .auto);
    try T.expectEqual(@as(usize, 2), s.grid_template_rows.line_names.len);
    s = try t.one("gridTemplate", "100px 1fr / auto 50px");
    try T.expect(s.grid_template_rows.tracks.len == 2 and s.grid_template_columns.tracks.len == 2);
    s = try t.one("grid", "auto-flow dense 40px / 1fr 1fr");
    try T.expect(s.grid_auto_flow.dense and !s.grid_auto_flow.column and s.grid_auto_rows.len == 1 and s.grid_template_columns.tracks.len == 2);
    s = try t.one("grid", "100px / auto-flow 30px");
    try T.expect(s.grid_auto_flow.column and s.grid_auto_columns.len == 1 and s.grid_template_rows.tracks.len == 1);
    s = try t.one("grid", "\"a\" 10px / 20px");
    try T.expect(s.grid_template_areas.areas.len == 1 and s.grid_auto_rows.len == 0);
    try t.bad("grid", "auto-flow / auto-flow");
    try t.bad("gridTemplate", "1px");
}

test "box / table / list / misc keywords" {
    var t = TestCx.init();
    defer t.deinit();
    const s = try css(&t, null,
        \\float: inline-start; clear: both; table-layout: fixed; border-collapse: collapse; border-spacing: 2px 3px;
        \\caption-side: bottom; empty-cells: hide; box-decoration-break: clone; isolation: isolate; unicode-bidi: bidi-override;
        \\writing-mode: vertical-rl; vertical-align: text-top; contain: inline-size paint; will-change: transform;
        \\pointer-events: none; cursor: pointer; user-select: none; background-attachment: fixed, local;
        \\list-style: square inside; content: "a" counter(x) " b"; counter-reset: a 1 b; counter-increment: none;
        \\overflow-inline: hidden; background-blend-mode: multiply, screen; mask-type: alpha
    );
    try T.expect(s.float == .inline_start and s.clear == .both and s.table_layout == .fixed and s.border_collapse == .collapse);
    try T.expectEqual([2]f32{ 2, 3 }, s.border_spacing);
    try T.expect(s.caption_side == .bottom and s.empty_cells == .hide and s.box_decoration_break == .clone and s.isolation == .isolate);
    try T.expect(s.unicode_bidi == .bidi_override and s.writing_mode == .vertical_rl and s.vertical_align == .text_top);
    try T.expect(s.contain.inline_size and s.contain.paint and !s.contain.size);
    try T.expect(s.list_style_type == .ident and std.mem.eql(u8, s.list_style_type.ident, "square") and s.list_style_position == .inside);
    try T.expectEqualStrings("\"a\" counter(x) \" b\"", s.content);
    try T.expectEqualStrings("a 1 b", s.counter_reset);
    try T.expectEqualStrings("", s.counter_increment);
    try T.expect(s.overflow_x == .hidden);
    try T.expect(s.background_blend_mode.len == 2 and s.background_blend_mode[1] == .screen);
    try T.expect(s.mask_type == .alpha);
    // inherited table/list properties
    const c2 = try css(&t, &s, "width: 1px");
    try T.expect(c2.border_collapse == .collapse and c2.list_style_position == .inside and c2.float == .none);
    try T.expectEqual([2]f32{ 2, 3 }, c2.border_spacing);
    var x = try t.one("listStyle", "none");
    try T.expect(x.list_style_type == .none and x.list_style_image == .none);
    x = try t.one("listStyle", "url(a.png) \"-\"");
    try T.expect(x.list_style_type == .string and x.list_style_image == .url);
    x = try t.one("verticalAlign", "-2px");
    try expectLP(x.vertical_align.lp, -2, 0);
    x = try t.one("contain", "strict");
    try T.expect(x.contain.size and x.contain.paint);
    try t.bad("contain", "size size");
    try t.bad("contain", "size inline-size");
    try t.bad("float", "middle");
    try t.bad("borderSpacing", "-1px");
    try t.bad("listStyle", "none none none");
    try t.bad("counterReset", "a, b");
}

test "clip-path, masks, backdrop-filter" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try t.one("clipPath", "inset(10px 20% round 5px) padding-box");
    const cp = s.clip_path.?;
    try T.expect(cp.box == .padding_box);
    const in_ = cp.shape.?.inset;
    try expectLP(in_.sides[0], 10, 0);
    try expectLP(in_.sides[1], 0, 0.2);
    try expectLP(in_.sides[3], 0, 0.2);
    try expectLP(in_.radius[2][1], 5, 0);
    s = try t.one("clipPath", "circle(50% at left 10px top)");
    try expectLP(s.clip_path.?.shape.?.circle.r.lp, 0, 0.5);
    try expectLP(s.clip_path.?.shape.?.circle.at[0], 10, 0);
    s = try t.one("clipPath", "circle()");
    try T.expect(s.clip_path.?.shape.?.circle.r == .closest_side);
    try expectLP(s.clip_path.?.shape.?.circle.at[1], 0, 0.5);
    s = try t.one("clipPath", "ellipse(farthest-side 20px)");
    try T.expect(s.clip_path.?.shape.?.ellipse.rx == .farthest_side);
    s = try t.one("clipPath", "polygon(evenodd, 0 0, 100% 0, 50% 100%)");
    const poly = s.clip_path.?.shape.?.polygon;
    try T.expect(poly.rule == .evenodd and poly.points.len == 3);
    try expectLP(poly.points[2][1], 0, 1);
    s = try t.one("clipPath", "path(\"M0 0 L10 10 Z\")");
    try T.expectEqualStrings("M0 0 L10 10 Z", s.clip_path.?.shape.?.path.d);
    s = try t.one("clipPath", "content-box");
    try T.expect(s.clip_path.?.shape == null and s.clip_path.?.box == .content_box);
    s = try t.one("clipPath", "url(#c)");
    try T.expectEqualStrings("#c", s.clip_path.?.url);
    try T.expect((try t.one("clipPath", "none")).clip_path == null);
    try t.bad("clipPath", "circle(-1px)");
    try t.bad("clipPath", "polygon(1px)");
    try t.bad("clipPath", "inset()");
    try t.bad("clipPath", "circle() circle()");
    s = try t.one("mask", "url(m.png) center / contain no-repeat content-box luminance, linear-gradient(red, transparent)");
    try T.expectEqual(@as(usize, 2), s.mask_image.len);
    const m0 = s.maskLayer(0);
    try T.expect(m0.size == .contain and m0.origin == .content_box and m0.clip == .content_box and m0.mode == .luminance);
    try T.expectEqual([2]computed.BgRepeat{ .no_repeat, .no_repeat }, m0.repeat);
    try T.expect(s.maskLayer(1).image == .gradient and s.maskLayer(1).clip == .border_box);
    s = try css(&t, null, "-webkit-mask-image: url(a), none; mask-size: 10px; mask-mode: alpha; mask-clip: no-clip; -webkit-mask-repeat: repeat-x; mask-position: right");
    try T.expect(s.mask_image.len == 2 and s.maskLayer(1).mode == .alpha and s.maskLayer(0).repeat[1] == .no_repeat);
    try expectLP(s.maskLayer(0).position[0], 0, 1);
    s = try t.one("backdropFilter", "blur(4px) saturate(2)");
    try T.expect(s.backdrop_filter.len == 2 and s.backdrop_filter[0].blur == 4);
    s = try t.one("filter", "drop-shadow(1px 2px 3px red)");
    const ds = s.filter[0].drop_shadow;
    try T.expect(ds.x == 1 and ds.y == 2 and ds.blur == 3 and ds.color.rgba.r == 255);
    s = try t.one("backgroundPositionX", "right 4px, 30%");
    try T.expect(s.background_position.len == 2);
    try expectLP(s.background_position[0][0], -4, 1);
    try expectLP(s.background_position[1][0], 0, 0.3);
    s = try css(&t, null, "background-position: 1px 2px; background-position-y: bottom");
    try expectLP(s.background_position[0][0], 1, 0);
    try expectLP(s.background_position[0][1], 0, 1);
}

test "text and font extras" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try css(&t, null,
        \\font-size: 20px; text-decoration-skip-ink: none; text-underline-offset: 10%; text-underline-position: under left;
        \\-webkit-text-fill-color: transparent; paint-order: stroke fill; text-align-last: justify; hyphens: auto; line-break: strict;
        \\font-stretch: condensed; font-feature-settings: "liga" off, "ss01", "cv01" 3; font-variation-settings: "wght" 650, "wdth" 80.5;
        \\font-variant: small-caps tabular-nums no-common-ligatures super; font-kerning: none; font-optical-sizing: none; font-synthesis: weight
    );
    try T.expect(s.text_decoration_skip_ink == .none and s.text_underline_offset.? == 2);
    try T.expect(s.text_underline_position.under and s.text_underline_position.left);
    try T.expect(s.webkit_text_fill_color.?.rgba.a == 0 and s.paint_order == .stroke);
    try T.expect((try t.one("paintOrder", "markers stroke")).paint_order == .stroke);
    try T.expect((try t.one("paintOrder", "markers")).paint_order == .fill);
    try T.expect(s.text_align_last == .justify and s.hyphens == .auto and s.line_break == .strict and s.font_stretch == 75);
    try T.expectEqual(@as(usize, 3), s.font_feature_settings.len);
    try T.expect(std.mem.eql(u8, &s.font_feature_settings[0].tag, "liga") and s.font_feature_settings[0].value == 0 and s.font_feature_settings[1].value == 1 and s.font_feature_settings[2].value == 3);
    try T.expect(s.font_variation_settings.len == 2 and s.font_variation_settings[1].value == 80.5);
    try T.expect(s.font_variant_caps == .small_caps and s.font_variant_numeric.spacing == .tabular and s.font_variant_ligatures.common == .off and s.font_variant_position == .super);
    try T.expect(s.font_kerning == .none and s.font_optical_sizing == .none and s.font_synthesis.weight and !s.font_synthesis.style);
    // resolved features: variants first, then settings (takumi order; caps are applied by the text engine)
    const feats = try s.fontFeatures(t.a());
    const want = [_][]const u8{ "liga", "clig", "tnum", "sups", "kern", "liga", "ss01", "cv01" };
    try T.expectEqual(want.len, feats.len);
    for (want, feats) |w, f| try T.expectEqualStrings(w, &f.tag);
    // inherited
    const c2 = try css(&t, &s, "color: red");
    try T.expect(c2.font_variant_caps == .small_caps and c2.font_stretch == 75 and c2.hyphens == .auto and c2.webkit_text_fill_color != null);
    // font shorthand resets variants/features, sets stretch & caps
    s = try css(&t, &s, "font: small-caps expanded 12px serif");
    try T.expect(s.font_stretch == 125 and s.font_variant_caps == .small_caps and s.font_feature_settings.len == 0 and s.font_kerning == .auto);
    try T.expect(s.font_variant_numeric.spacing == .normal);
    s = try t.one("fontVariantLigatures", "none");
    try T.expect(s.font_variant_ligatures.contextual == .off);
    s = try t.one("fontVariantNumeric", "oldstyle-nums diagonal-fractions slashed-zero ordinal");
    try T.expect(s.font_variant_numeric.figure == .oldstyle and s.font_variant_numeric.fraction == .diagonal and s.font_variant_numeric.slashed_zero);
    s = try t.one("fontVariantEastAsian", "jis83 full-width ruby");
    try T.expect(s.font_variant_east_asian.form == .jis83 and s.font_variant_east_asian.width == .full and s.font_variant_east_asian.ruby);
    try T.expectEqual(@as(f32, 150), (try t.one("fontStretch", "150%")).font_stretch);
    try T.expectEqual(@as(f32, 200), (try t.one("fontStretch", "ultra-expanded")).font_stretch);
    try T.expect(!(try t.one("fontSynthesisStyle", "none")).font_synthesis.style);
    try T.expect(!(try t.one("fontSynthesis", "none")).font_synthesis.weight);
    try t.bad("fontVariantNumeric", "lining-nums oldstyle-nums");
    try t.bad("fontVariantCaps", "tabular-nums");
    try t.bad("fontFeatureSettings", "\"toolong\" 1");
    try t.bad("fontFeatureSettings", "liga");
    try t.bad("fontVariationSettings", "\"wght\"");
    try t.bad("fontStretch", "-5%");
    try t.bad("paintOrder", "fill fill");
    try t.bad("textUnderlinePosition", "under from-font");
    // kerning normal + letter-spacing disables ligatures
    s = try css(&t, null, "letter-spacing: 1px; font-kerning: normal");
    const f2 = try s.fontFeatures(t.a());
    try T.expectEqual(@as(usize, 6), f2.len);
    try T.expect(f2[0].value == 0 and std.mem.eql(u8, &f2[5].tag, "kern") and f2[5].value == 1);
    try T.expectEqual(@as(usize, 0), (try (try css(&t, null, "color: red")).fontFeatures(t.a())).len);
}

test "animations and transitions" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try t.one("animation", "spin 2s linear infinite, 300ms ease-in-out 1s 3 reverse both paused fade, none");
    try T.expectEqual(@as(usize, 3), s.animation_name.len);
    var a = s.animation(0);
    try T.expectEqualStrings("spin", a.name);
    try T.expect(a.duration_ms == 2000 and a.iteration_count == std.math.inf(f32) and a.timing.cubic[2] == 1 and a.delay_ms == 0);
    a = s.animation(1);
    try T.expectEqualStrings("fade", a.name);
    try T.expect(a.duration_ms == 300 and a.delay_ms == 1000 and a.iteration_count == 3 and a.direction == .reverse and a.fill_mode == .both and a.play_state == .paused);
    try T.expectEqualStrings("none", s.animation(2).name);
    s = try css(&t, null,
        \\animation-name: a, b; animation-duration: 1s; animation-timing-function: steps(4, jump-none), cubic-bezier(0.1, -1, 0.9, 2);
        \\animation-delay: -500ms; animation-iteration-count: 2.5; animation-direction: alternate-reverse; animation-fill-mode: forwards;
        \\animation-play-state: running, paused
    );
    a = s.animation(1);
    try T.expect(a.duration_ms == 1000 and a.timing.cubic[1] == -1 and a.delay_ms == -500 and a.iteration_count == 2.5 and a.play_state == .paused);
    try T.expect(s.animation(0).timing.steps.n == 4 and s.animation(0).timing.steps.pos == .jump_none);
    s = try t.one("animationTimingFunction", "linear(0, 0.25 25% 75%, 1)");
    const pts = s.animation_timing_function[0].linear_points;
    try T.expectEqual(@as(usize, 4), pts.len);
    try T.expect(pts[0][0] == 0 and pts[1][0] == 0.25 and pts[2][0] == 0.75 and pts[3][0] == 1 and pts[3][1] == 1);
    s = try t.one("animationTimingFunction", "linear(0, 0.5, 1)");
    try T.expect(s.animation_timing_function[0].linear_points[1][0] == 0.5);
    s = try t.one("animationTimingFunction", "step-start");
    try T.expect(s.animation_timing_function[0].steps.pos == .jump_start);
    s = try t.one("transition", "opacity 200ms, transform 1s ease-out 50ms");
    try T.expectEqual(@as(usize, 2), s.transition_property.len);
    try T.expectEqualStrings("transform", s.transition(1).property);
    try T.expect(s.transition(1).duration_ms == 1000 and s.transition(1).delay_ms == 50 and s.transition(1).timing.cubic[2] == 0.58);
    try T.expectEqualStrings("all", (try t.one("transition", "1s")).transition(0).property);
    try t.bad("animationDuration", "-1s");
    try t.bad("animationTimingFunction", "cubic-bezier(2, 0, 0, 1)");
    try t.bad("animationTimingFunction", "steps(0)");
    try t.bad("animationTimingFunction", "steps(1, jump-none)");
    try t.bad("animation", "a 1s 2s 3s");
    try t.bad("animationIterationCount", "-1");
    try t.bad("transition", "opacity 1s,");
    const init_s = try t.one("width", "1px");
    try T.expect(init_s.animation_name.len == 0 and init_s.transition_property.len == 1 and init_s.transition(0).duration_ms == 0);
}

test "mixed-unit math, fit-content(), font-relative units" {
    var t = TestCx.init();
    defer t.deinit();
    var s = try t.one("width", "min(100%, 300px)");
    const w = s.width.lp;
    try T.expect(w.isCalc());
    try T.expect(approx(w.resolve(200), 200) and approx(w.resolve(1000), 300));
    s = try t.one("width", "clamp(10px, 50% - 5px, 2em)");
    try T.expect(approx(s.width.lp.resolve(100), 32) and approx(s.width.lp.resolve(30), 10) and approx(s.width.lp.resolve(50), 20));
    s = try t.one("paddingLeft", "calc(2 * max(10%, 8px) + 1px)");
    try T.expect(approx(s.padding[3].resolve(50), 17) and approx(s.padding[3].resolve(200), 41));
    s = try t.one("marginTop", "calc(10px - min(5%, 3px))");
    try T.expect(approx(s.margin[0].lp.resolve(100), 7) and approx(s.margin[0].lp.resolve(20), 9));
    try t.bad("borderWidth", "min(10%, 2px)"); // <length> only
    s = try t.one("width", "fit-content(50%)");
    try expectLP(s.width.fit_content_lp, 0, 0.5);
    s = try t.one("minHeight", "-webkit-fill-available");
    try T.expect(s.min_height == .stretch);
    try t.bad("width", "fit-content(-1px)");
    // ch / ex / cap / ic / lh / rlh
    t.ctx.ch_width_ratio = 0.6;
    t.ctx.x_height_ratio = 0.4;
    s = try css(&t, null, "font-size: 20px; line-height: 30px; width: 2ch; height: 1ex; min-width: 1lh; max-width: 1rlh; margin-left: 1cap; margin-right: 1ic");
    try expectLP(s.width.lp, 24, 0);
    try expectLP(s.height.lp, 8, 0);
    try expectLP(s.min_width.lp, 30, 0);
    try expectLP(s.max_width.lp, 16 * 1.2, 0);
    try expectLP(s.margin[3].lp, 14, 0);
    try expectLP(s.margin[1].lp, 20, 0);
    s = try css(&t, null, "font-size: 10px; line-height: 2; padding-top: 2lh");
    try expectLP(s.padding[0], 40, 0);
}

test "fuzz: parsers never crash" {
    var arena_state = std.heap.ArenaAllocator.init(T.allocator);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    const seeds = [_][]const u8{
        "calc(100% - (2 * 3px))",                                                     "linear-gradient(45deg, red 10%, 30%, blue 50% 60%)",   "rgb(1 2 3 / 50%)",
        "repeat(auto-fill, minmax(10px, 1fr)) [a b]",                                 "inset 1px 2px 3px 4px red, 0 0 #fff",                  "url(\"a(b)\") center / cover no-repeat",
        "italic bold 12px/1.5 'Inter', sans-serif",                                   "radial-gradient(circle at 10% 20%, red, blue)",        "conic-gradient(from 10deg at center, red 0 10%, blue)",
        "translate(1px, 2%) rotate(1turn) matrix(1,2,3,4,5,6)",                       "1 / span 2",                                           "min(1px, max(2px, clamp(1px, 2px, 3px)))",
        "hsl(120deg 100% 25% / .5)",                                                  "drop-shadow(1px 1px red) blur(2px)",                   "right 10px bottom 20%",
        "1px 2px 3px 4px / 5px",                                                      "#0f08",                                                "((((((((",
        "\"unterminated",                                                             "/* comment",                                           "var(--a, var(--b, 1px)) var(--c)",
        "[a b] 1fr [c] repeat(2, [d] 10px)",                                          "\"a a\" 10px \". b\" / 1fr 2fr",                       "2 foo / span bar",
        "auto-flow dense 10px / 1fr",                                                 "inset(1px 2% round 3px / 4px)",                        "polygon(evenodd, 0 0, 100% 0, 50% 100%)",
        "circle(closest-side at 10% 20%)",                                            "path(\"M0 0 L1 1\") content-box",                      "url(m.png) center / contain no-repeat luminance, none",
        "spin 1s steps(3, jump-both) infinite alternate",                             "linear(0, 0.5 20% 40%, 1)",                            "cubic-bezier(0.1, 2, 0.3, -1)",
        "\"liga\" off, \"ss01\" 2",                                                   "small-caps tabular-nums no-contextual",                "min(100%, calc(50% + 10px), max(2em, 3ch))",
        "clamp(1lh, 10%, 2rlh)",                                                      "fit-content(10%)",                                     "oklch(0.7 0.1 200 / 50%)",
        "color-mix(in oklab, red 30%, blue)",                                         "lab(50 20 -30)",                                       "linear-gradient(in oklch longer hue, red, lab(50 20 30))",
        "color-mix(in oklch longer hue, red 20%, lab(50 1 2))",                       "lch(none none none / none)",                           "color(xyz-d50 1e30 -1e30 0)",
        "linear-gradient(in hsl decreasing hue 45deg, oklch(0.5 0.2 250), 30%, red)", "radial-gradient(circle at 1px 2px in lab, red, blue)", "light-dark(red, blue)",
    };
    const alphabet = "()[],/*+- .%#\"'0123456789pxemrdgaucltnbi!\\";
    var buf: [96]u8 = undefined;
    const ctx: Context = .{ .dpr = 1.5, .viewport_w = 100, .viewport_h = 100, .root_font_size = 16 };
    const parent = initial(&ctx);
    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();
        var n: usize = 0;
        if (rnd.boolean()) {
            const seed = seeds[rnd.uintLessThan(usize, seeds.len)];
            n = @min(seed.len, buf.len);
            @memcpy(buf[0..n], seed[0..n]);
            var m: usize = 0;
            while (m < 4) : (m += 1) {
                if (n == 0) break;
                const pos = rnd.uintLessThan(usize, n);
                switch (rnd.uintLessThan(u8, 3)) {
                    0 => buf[pos] = alphabet[rnd.uintLessThan(usize, alphabet.len)],
                    1 => n = pos,
                    else => buf[pos] = rnd.int(u8),
                }
            }
        } else {
            n = rnd.uintLessThan(usize, buf.len);
            for (buf[0..n]) |*b| b.* = if (rnd.boolean()) alphabet[rnd.uintLessThan(usize, alphabet.len)] else rnd.int(u8);
        }
        const val = buf[0..n];
        for (std.enums.values(props.Prop)) |p| {
            const members = try a.alloc(json.Member, 1);
            members[0] = .{ .key = @tagName(p), .value = .{ .string = val } };
            var d: Diagnostics = .{};
            _ = compute(a, &ctx, &parent, null, json.Value{ .object = members }, &d) catch {};
        }
        // declaration blocks + var() + lenient cascade
        const decls = parseDeclarationBlock(a, val) catch continue;
        var d: Diagnostics = .{};
        _ = computeEx(a, &ctx, &parent, null, decls, null, &d) catch {};
        const names = [_][]const u8{ "--a", "--b", "width", "grid-template", "margin-inline", "font", "background", "animation" };
        var vd: [names.len]Declaration = undefined;
        for (names, 0..) |nm, k| vd[k] = .{ .name = nm, .value = if (k % 2 == 0) val else "var(--a) var(--b)" };
        _ = computeEx(a, &ctx, &parent, null, &vd, null, &d) catch {};
    }
}

test "fragmentation properties (paged output)" {
    const root = @import("root");
    // (parsed only with the PDF feature; accepted and ignored without it)
    const on = if (@hasDecl(root, "bm_config")) (@hasDecl(root.bm_config, "enable_pdf") and root.bm_config.enable_pdf) else true;
    var t = TestCx.init();
    defer t.deinit();
    if (comptime props.pdf_build) {
        // a frame no PDF is drawn from: ignored, as without the feature (even an invalid value)
        const im = try css(&t, null, "break-before: page; widows: 0; orphans: 4; break-inside: sometimes");
        try T.expect(im.break_before == .auto and im.break_inside == .auto and im.widows == 2 and im.orphans == 2);
        try t.bad("backgroundClip", "border-area");
        t.ctx.paged = true;
        if (comptime @hasField(computed.BgBox, "border_area")) {
            try T.expect((try t.one("backgroundClip", "border-area")).background_clip[0] == .border_area);
        } else try t.bad("backgroundClip", "border-area");
    }
    const s = try css(&t, null, "break-before: page; break-after: avoid-page; break-inside: avoid; widows: 3; orphans: 4");
    if (!on) {
        try T.expect(s.break_before == .auto and s.break_inside == .auto and s.widows == 2 and s.orphans == 2);
        return;
    }
    try T.expect(s.break_before == .page and s.break_after == .avoid_page and s.break_inside == .avoid);
    try T.expect(s.widows == 3 and s.orphans == 4);
    try T.expect(s.break_before.forcesPage() and s.break_after.avoidsPage() and s.break_inside.avoidsPage());
    // the legacy aliases, and `always` as `page`
    const l = try css(&t, null, "page-break-before: always; page-break-after: left; page-break-inside: avoid");
    try T.expect(l.break_before == .always and l.break_before.forcesPage() and l.break_after == .left and l.break_inside == .avoid);
    try T.expect((try t.one("breakBefore", "recto")).break_before.forcesPage());
    try T.expect(!(try t.one("breakBefore", "column")).break_before.forcesPage());
    try T.expect(!(try t.one("breakAfter", "avoid-column")).break_after.avoidsPage());
    try T.expect(!(try t.one("breakInside", "avoid-column")).break_inside.avoidsPage());
    try T.expect((try t.one("pageBreakInside", "avoid")).break_inside == .avoid);
    // widows / orphans: integers >= 1, inherited
    try t.bad("widows", "0");
    try t.bad("orphans", "-2");
    try t.bad("widows", "2.5");
    try t.bad("orphans", "auto");
    try t.bad("breakBefore", "sometimes");
    const child = try css(&t, &s, "color: red");
    try T.expect(child.widows == 3 and child.orphans == 4 and child.break_before == .auto and child.break_inside == .auto);
}
