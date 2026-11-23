//! Numeric value parsing: lengths/percentages (incl. calc/min/max/clamp), numbers, angles,
//! sizes and `<position>`. All absolute lengths come out in DEVICE px.
const std = @import("std");
const tok = @import("tokenizer.zig");
const color = @import("color.zig");

const Token = tok.Token;
const Lexer = tok.Lexer;

/// A linear `<length-percentage>`: `px + pct * reference`. `px` is in device pixels, `pct` is a
/// fraction (50% -> 0.5). `calc(100% - 20px)` = `{ .px = -20, .pct = 1 }`.
pub const LP = struct {
    px: f32 = 0,
    pct: f32 = 0,
    /// Non-linear math (`min()/max()/clamp()` mixing % and absolute lengths). When set, it is the
    /// whole value and `px`/`pct` hold an approximation (the expression evaluated with a
    /// reference of 0 in `px`, `pct` = 0). Always use `resolve()` / `isCalc()`; null in the common case.
    calc: ?*const CalcNode = null,

    pub fn resolve(v: LP, reference: f32) f32 {
        if (v.calc) |c| return c.eval(reference);
        return v.px + v.pct * reference;
    }
    pub fn fromPx(px: f32) LP {
        return .{ .px = px };
    }
    pub fn fromPct(frac: f32) LP {
        return .{ .pct = frac };
    }
    pub fn isCalc(v: LP) bool {
        return v.calc != null;
    }
    pub fn eql(a: LP, b: LP) bool {
        return a.px == b.px and a.pct == b.pct and a.calc == b.calc;
    }
};

/// Expression tree for non-linear `<length-percentage>` math. Every node's value is
/// `px + pct * reference + combine(args)` where combine is: leaf -> 0, sum -> Σ args,
/// min/max -> min/max of args, clamp -> clamp(args[0], args[1], args[2]) (CSS: max(MIN, min(VAL, MAX))),
/// scale -> px * args[0] (pct ignored).
pub const CalcNode = struct {
    op: Op = .leaf,
    px: f32 = 0,
    pct: f32 = 0,
    args: []const CalcNode = &.{},

    pub const Op = enum(u8) { leaf, sum, min, max, clamp, scale };

    pub fn eval(n: *const CalcNode, ref: f32) f32 {
        return evalDepth(n, ref, 0);
    }

    fn evalDepth(n: *const CalcNode, ref: f32, depth: u32) f32 {
        if (depth > 64) return 0;
        const base = n.px + n.pct * ref;
        switch (n.op) {
            .leaf => return base,
            .scale => return if (n.args.len > 0) n.px * evalDepth(&n.args[0], ref, depth + 1) else 0,
            .sum => {
                var acc: f32 = base;
                for (n.args) |*a| acc += evalDepth(a, ref, depth + 1);
                return acc;
            },
            .min, .max => {
                if (n.args.len == 0) return base;
                var acc = evalDepth(&n.args[0], ref, depth + 1);
                for (n.args[1..]) |*a| {
                    const v = evalDepth(a, ref, depth + 1);
                    acc = if (n.op == .min) @min(acc, v) else @max(acc, v);
                }
                return acc;
            },
            .clamp => {
                if (n.args.len != 3) return base;
                const lo = evalDepth(&n.args[0], ref, depth + 1);
                const v = evalDepth(&n.args[1], ref, depth + 1);
                const hi = evalDepth(&n.args[2], ref, depth + 1);
                return @max(lo, @min(v, hi));
            },
        }
    }
};

/// `width`/`height`/`min-*`/`max-*` value. For `max-*`, `none` is stored as `.auto`.
/// `fit_content_lp` = `fit-content(<length-percentage>)`.
pub const Size = union(enum) {
    auto,
    lp: LP,
    min_content,
    max_content,
    fit_content,
    stretch,
    fit_content_lp: LP,
};

/// `auto | <length-percentage>` (margins, insets).
pub const LengthAuto = union(enum) {
    auto,
    lp: LP,
};

/// Everything a length needs to resolve to device px at compute time.
pub const Env = struct {
    dpr: f32 = 1,
    vw: f32 = 0, // viewport width, output px
    vh: f32 = 0,
    /// The viewport has no height of its own (paged output, or a render without a height): `vh`
    /// is only the unit. CSS motion paths then take the element's height (motion_path.zig `Lazy`).
    vh_unbounded: bool = false,
    em: f32 = 16, // font-size the `em` unit refers to (device px)
    rem: f32 = 16, // root font-size (device px)
    /// font-metric ratios relative to `em` (ch = advance of "0", ex = x-height, cap = cap height,
    /// ic = advance of "水").
    ch: f32 = 0.5,
    ex: f32 = 0.5,
    cap: f32 = 0.7,
    ic: f32 = 1,
    /// computed line-height of the element / root element in device px (`lh` / `rlh`)
    lh: f32 = 19.2,
    rlh: f32 = 19.2,
    /// When set, `min()/max()/clamp()` mixing percentages and absolute lengths build a
    /// `CalcNode` tree in this allocator; otherwise such values are rejected.
    alloc: ?std.mem.Allocator = null,
};

fn ieq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Device px per unit, or null if `unit` is not a length unit.
const unit_names = "px\x00pt\x00pc\x00in\x00cm\x00mm\x00q\x00em\x00rem\x00ch\x00ex\x00vw\x00vh\x00vmin\x00vmax\x00lh\x00rlh\x00cap\x00ic\x00svw\x00lvw\x00dvw\x00svh\x00lvh\x00dvh\x00vi\x00vb";
const abs_units = [_]f32{ 1, 4.0 / 3.0, 16, 96, 96.0 / 2.54, 96.0 / 25.4, 96.0 / 101.6 };

pub fn lengthUnit(unit: []const u8, env: *const Env) ?f32 {
    const i = tok.matchPacked(unit, unit_names) orelse return null;
    if (i < abs_units.len) return abs_units[i] * env.dpr;
    return switch (i) {
        7 => env.em,
        8 => env.rem,
        9 => env.em * env.ch,
        10 => env.em * env.ex,
        11, 20, 21, 22, 26 => env.vw / 100,
        12, 23, 24, 25, 27 => env.vh / 100,
        13 => @min(env.vw, env.vh) / 100,
        14 => @max(env.vw, env.vh) / 100,
        15 => env.lh,
        16 => env.rlh,
        17 => env.em * env.cap,
        else => env.em * env.ic,
    };
}

// ------------------------------------------------------------------ calc
const Dim = enum(u8) { number, length, angle, percent };
/// Linear value `v + pct*ref`, or (length/percent dims only) a non-linear `node` that replaces v/pct.
const CV = struct { v: f32 = 0, pct: f32 = 0, dim: Dim, node: ?*const CalcNode = null };

/// The CalcNode for a value (leaf when linear).
fn asNode(a: CV, alloc: std.mem.Allocator) ?*const CalcNode {
    if (a.node) |n| return n;
    const n = alloc.create(CalcNode) catch return null;
    n.* = .{ .op = .leaf, .px = a.v, .pct = a.pct };
    return n;
}

fn mkNode(alloc: std.mem.Allocator, op: CalcNode.Op, k: f32, args: []const CV) ?*const CalcNode {
    const arr = alloc.alloc(CalcNode, args.len) catch return null;
    for (args, 0..) |a, i| arr[i] = (asNode(a, alloc) orelse return null).*;
    const n = alloc.create(CalcNode) catch return null;
    n.* = .{ .op = op, .px = k, .args = arr };
    return n;
}

fn scaleCV(a: *CV, k: f32, env: *const Env) bool {
    if (a.node) |_| {
        const al = env.alloc orelse return false;
        a.node = mkNode(al, .scale, k, &.{a.*}) orelse return false;
        return true;
    }
    a.v *= k;
    a.pct *= k;
    return true;
}

const max_calc_depth = 24;

pub fn isMathFn(t: Token) bool {
    if (t.kind != .function) return false;
    return ieq(t.text, "calc") or ieq(t.text, "min") or ieq(t.text, "max") or ieq(t.text, "clamp") or ieq(t.text, "-webkit-calc");
}

fn finite(x: f32) bool {
    return x == x and @abs(x) <= 3.0e38;
}

fn mathFn(t: Token, env: *const Env, depth: u32) ?CV {
    if (depth > max_calc_depth) return null;
    var l = Lexer.init(t.args);
    if (ieq(t.text, "calc") or ieq(t.text, "-webkit-calc")) {
        const r = sum(&l, env, depth + 1) orelse return null;
        if (!l.atEnd()) return null;
        return r;
    }
    const is_min = ieq(t.text, "min");
    const is_clamp = ieq(t.text, "clamp");
    var args: [16]CV = undefined;
    var n: usize = 0;
    var acc: CV = undefined;
    var mixed = false;
    while (true) {
        const a = sum(&l, env, depth + 1) orelse return null;
        if (n >= args.len) return null;
        args[n] = a;
        if (n == 0) {
            acc = a;
        } else {
            // comparable: same dimension; mixed shapes (abs + %) need a calc tree
            const ad: Dim = if (a.dim == .percent) .length else a.dim;
            const cd: Dim = if (acc.dim == .percent) .length else acc.dim;
            if (ad != cd) return null;
            if (a.node != null or acc.node != null or ((a.pct != 0 or acc.pct != 0) and (a.v != 0 or acc.v != 0))) mixed = true;
            if (!is_clamp and !mixed) {
                const av = a.v + a.pct;
                const cv = acc.v + acc.pct;
                const take = if (is_min) av < cv else av > cv;
                if (take) acc = a;
            }
        }
        n += 1;
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (sep.kind != .comma) return null;
    }
    if (is_clamp and n != 3) return null;
    if (mixed) {
        const al = env.alloc orelse return null;
        const op: CalcNode.Op = if (is_clamp) .clamp else if (is_min) .min else .max;
        const node = mkNode(al, op, 0, args[0..n]) orelse return null;
        return .{ .dim = .length, .node = node };
    }
    if (is_clamp) {
        const lo = args[0].v + args[0].pct;
        const mid = args[1].v + args[1].pct;
        const hi = args[2].v + args[2].pct;
        var r = args[1];
        if (mid > hi) r = args[2];
        if (@min(mid, hi) < lo) r = args[0];
        _ = &r;
        return r;
    }
    return acc;
}

fn leaf(t: Token, env: *const Env, depth: u32) ?CV {
    switch (t.kind) {
        .number => return .{ .v = t.num, .dim = .number },
        .percentage => return .{ .pct = t.num / 100, .dim = .percent },
        .dimension => {
            if (lengthUnit(t.text, env)) |f| return .{ .v = t.num * f, .dim = .length };
            if (color.angleFactor(t.text)) |f| return .{ .v = t.num * f, .dim = .angle };
            return null;
        },
        .block => {
            if (depth > max_calc_depth) return null;
            var l = Lexer.init(t.args);
            const r = sum(&l, env, depth + 1) orelse return null;
            if (!l.atEnd()) return null;
            return r;
        },
        .function => {
            if (!isMathFn(t)) return null;
            return mathFn(t, env, depth + 1);
        },
        .ident => {
            if (ieq(t.text, "pi")) return .{ .v = std.math.pi, .dim = .number };
            if (ieq(t.text, "e")) return .{ .v = std.math.e, .dim = .number };
            return null;
        },
        else => return null,
    }
}

fn product(l: *Lexer, env: *const Env, depth: u32) ?CV {
    var a = leaf(l.next(), env, depth) orelse return null;
    var guard: u32 = 0;
    while (true) : (guard += 1) {
        if (guard > 256) return null;
        const p = l.peek();
        const is_mul = p.isDelim('*');
        if (!is_mul and p.kind != .slash) return a;
        _ = l.next();
        const b = leaf(l.next(), env, depth) orelse return null;
        if (is_mul) {
            if (a.dim == .number) {
                const k = a.v;
                a = b;
                if (!scaleCV(&a, k, env)) return null;
            } else if (b.dim == .number) {
                if (!scaleCV(&a, b.v, env)) return null;
            } else return null;
        } else {
            if (b.dim != .number or b.v == 0) return null;
            if (!scaleCV(&a, 1 / b.v, env)) return null;
        }
    }
}

fn sum(l: *Lexer, env: *const Env, depth: u32) ?CV {
    var a = product(l, env, depth) orelse return null;
    var guard: u32 = 0;
    while (true) : (guard += 1) {
        if (guard > 256) return null;
        const p = l.peek();
        const plus = p.isDelim('+');
        if (!plus and !p.isDelim('-')) break;
        _ = l.next();
        const b = product(l, env, depth) orelse return null;
        const s: f32 = if (plus) 1 else -1;
        if ((a.dim == .number) != (b.dim == .number)) return null;
        if (a.dim != .percent and b.dim != .percent and a.dim != b.dim) return null;
        if (a.dim == .percent) a.dim = b.dim;
        if (a.node != null or b.node != null) {
            const al = env.alloc orelse return null;
            var nb = b;
            if (!plus and !scaleCV(&nb, -1, env)) return null;
            a.node = mkNode(al, .sum, 0, &.{ a, nb }) orelse return null;
            a.v = 0;
            a.pct = 0;
            continue;
        }
        a.v += s * b.v;
        a.pct += s * b.pct;
    }
    if (!finite(a.v) or !finite(a.pct)) return null;
    return a;
}

// ------------------------------------------------------------------ public value parsers

/// `<length-percentage>` (unitless numbers are px, as in takumi). Returns null if `t` is not a
/// length-ish token at all; errors on malformed math functions.
pub fn lengthPct(t: Token, env: *const Env) ?LP {
    const v = lengthPctRaw(t, env) orelse return null;
    // Reject absurd magnitudes so layout never sees inf/NaN.
    if (!(@abs(v.px) <= 1.0e9) or !(@abs(v.pct) <= 1.0e7)) return null;
    return v;
}

fn lengthPctRaw(t: Token, env: *const Env) ?LP {
    switch (t.kind) {
        .number => return .{ .px = t.num * env.dpr },
        .percentage => return .{ .pct = t.num / 100 },
        .dimension => {
            const f = lengthUnit(t.text, env) orelse return null;
            return .{ .px = t.num * f };
        },
        .function => {
            if (!isMathFn(t)) return null;
            const r = mathFn(t, env, 0) orelse return null;
            if (r.node) |nd| {
                if (r.dim == .angle or r.dim == .number) return null;
                const v0 = nd.eval(0);
                if (!finite(v0)) return null;
                return .{ .px = v0, .calc = nd };
            }
            return switch (r.dim) {
                .number => .{ .px = r.v * env.dpr },
                .length, .percent => .{ .px = r.v, .pct = r.pct },
                .angle => null,
            };
        },
        else => return null,
    }
}

/// `<length>` (no percentages).
pub fn length(t: Token, env: *const Env) ?f32 {
    if (t.kind == .percentage) return null;
    const v = lengthPct(t, env) orelse return null;
    if (v.pct != 0 or v.calc != null) return null;
    return v.px;
}

/// `<number>` (incl. calc() of numbers).
pub fn number(t: Token) ?f32 {
    if (t.kind == .number) return t.num;
    if (t.kind == .function and isMathFn(t)) {
        const env: Env = .{};
        const r = mathFn(t, &env, 0) orelse return null;
        if (r.dim != .number) return null;
        return r.v;
    }
    return null;
}

/// `<number> | <percentage>` -> number (50% -> 0.5).
pub fn numberOrPct(t: Token) ?f32 {
    if (t.kind == .percentage) return t.num / 100;
    return number(t);
}

/// `<integer>`.
pub fn integer(t: Token) ?i32 {
    const v = number(t) orelse return null;
    if (t.kind == .number and !t.int) return null;
    if (@floor(v) != v or @abs(v) > 1.0e9) return null;
    return @intFromFloat(v);
}

/// `<angle>` in degrees (unitless 0 allowed; unitless non-zero accepted as degrees only if `loose`).
pub fn angle(t: Token, loose: bool) ?f32 {
    switch (t.kind) {
        .number => return if (t.num == 0 or loose) t.num else null,
        .dimension => {
            const f = color.angleFactor(t.text) orelse return null;
            return t.num * f;
        },
        .function => {
            if (!isMathFn(t)) return null;
            const env: Env = .{};
            const r = mathFn(t, &env, 0) orelse return null;
            if (r.dim != .angle and !(r.dim == .number and r.v == 0)) return null;
            return r.v;
        },
        else => return null,
    }
}

/// `<angle-percentage>` used by conic stops: returned as LP with `px` = degrees, `pct` = fraction of a turn.
pub fn anglePct(t: Token) ?LP {
    switch (t.kind) {
        .percentage => return .{ .pct = t.num / 100 },
        .function => {
            if (!isMathFn(t)) return null;
            const env: Env = .{};
            const r = mathFn(t, &env, 0) orelse return null;
            if (r.dim == .angle or r.dim == .percent) return .{ .px = r.v, .pct = r.pct };
            if (r.dim == .number and r.v == 0) return .{};
            return null;
        },
        else => return if (angle(t, false)) |d| .{ .px = d } else null,
    }
}

/// width/height/min-*/max-* value.
pub fn size(t: Token, env: *const Env) ?Size {
    if (t.kind == .ident) {
        const s = t.text;
        if (ieq(s, "auto") or ieq(s, "none")) return .auto;
        if (ieq(s, "min-content") or ieq(s, "-webkit-min-content")) return .min_content;
        if (ieq(s, "max-content") or ieq(s, "-webkit-max-content")) return .max_content;
        if (ieq(s, "fit-content") or ieq(s, "-webkit-fit-content")) return .fit_content;
        if (ieq(s, "stretch") or ieq(s, "-webkit-fill-available")) return .stretch;
        return null;
    }
    if (t.isFunc("fit-content") or t.isFunc("-webkit-fit-content")) {
        var l = Lexer.init(t.args);
        const v = lengthPct(l.next(), env) orelse return null;
        if (!l.atEnd() or v.px < 0 or v.pct < 0) return null;
        return .{ .fit_content_lp = v };
    }
    return if (lengthPct(t, env)) |v| .{ .lp = v } else null;
}

pub fn lengthAuto(t: Token, env: *const Env) ?LengthAuto {
    if (t.isIdent("auto")) return .auto;
    return if (lengthPct(t, env)) |v| .{ .lp = v } else null;
}

// ------------------------------------------------------------------ <position>
pub const PosKw = enum { left, center, right, top, bottom };
const PosItem = union(enum) { kw: PosKw, lp: LP };

fn posItem(t: Token, env: *const Env) ?PosItem {
    if (t.kind == .ident) {
        if (tok.kw(PosKw, t)) |k| return .{ .kw = k };
        return null;
    }
    return if (lengthPct(t, env)) |v| .{ .lp = v } else null;
}

fn kwLP(k: PosKw) LP {
    return switch (k) {
        .left, .top => .{},
        .center => .{ .pct = 0.5 },
        .right, .bottom => .{ .pct = 1 },
    };
}

fn isH(k: PosKw) bool {
    return k == .left or k == .right;
}
fn isV(k: PosKw) bool {
    return k == .top or k == .bottom;
}

/// Parses a `<position>` / `<bg-position>` (1-4 values, `max_items` 2 or 4) from the lexer, consuming
/// only position tokens. Returns null if no position token is next. Result = [x, y].
pub fn position(l: *Lexer, env: *const Env, max_items: usize) ?[2]LP {
    var items: [4]PosItem = undefined;
    var n: usize = 0;
    while (n < max_items) {
        const save = l.*;
        const it = posItem(l.next(), env) orelse {
            l.* = save;
            break;
        };
        items[n] = it;
        n += 1;
    }
    if (n == 0) return null;
    switch (n) {
        1 => switch (items[0]) {
            .lp => |v| return .{ v, .{ .pct = 0.5 } },
            .kw => |k| return if (isV(k)) .{ .{ .pct = 0.5 }, kwLP(k) } else .{ kwLP(k), .{ .pct = 0.5 } },
        },
        2 => {
            const a = items[0];
            const b = items[1];
            // keyword pair in either order
            if (a == .kw and b == .kw) {
                const ka = a.kw;
                const kb = b.kw;
                if (isV(ka) or isH(kb)) {
                    if (isV(kb) or isH(ka)) return null;
                    return .{ kwLP(kb), kwLP(ka) };
                }
                return .{ kwLP(ka), kwLP(kb) };
            }
            const x: LP = switch (a) {
                .lp => |v| v,
                .kw => |k| if (isV(k)) return null else kwLP(k),
            };
            const y: LP = switch (b) {
                .lp => |v| v,
                .kw => |k| if (isH(k)) return null else kwLP(k),
            };
            return .{ x, y };
        },
        else => {
            // 3/4-value: two groups `keyword [offset]`, one per axis.
            var res: [2]?LP = .{ null, null };
            var pending_center: u8 = 0;
            var i: usize = 0;
            var groups: usize = 0;
            while (i < n) {
                const k = switch (items[i]) {
                    .kw => |k| k,
                    .lp => return null,
                };
                i += 1;
                var off: ?LP = null;
                if (i < n and items[i] == .lp) {
                    if (k == .center) return null;
                    off = items[i].lp;
                    i += 1;
                }
                groups += 1;
                const axis: usize = if (isH(k)) 0 else if (isV(k)) 1 else 2;
                var v = kwLP(k);
                if (off) |o| {
                    if (k == .right or k == .bottom) {
                        v = .{ .px = -o.px, .pct = 1 - o.pct };
                    } else v = o;
                }
                if (axis == 2) {
                    pending_center += 1;
                    continue;
                }
                if (res[axis] != null) return null;
                res[axis] = v;
            }
            if (groups != 2) return null;
            while (pending_center > 0) : (pending_center -= 1) {
                if (res[0] == null) res[0] = .{ .pct = 0.5 } else if (res[1] == null) res[1] = .{ .pct = 0.5 } else return null;
            }
            return .{ res[0] orelse return null, res[1] orelse return null };
        },
    }
}

// ------------------------------------------------------------------ tests
const T = std.testing;

fn lp1(s: []const u8, env: *const Env) !LP {
    var l = Lexer.init(s);
    const v = lengthPct(l.next(), env) orelse return error.NotLength;
    if (!l.atEnd()) return error.Trailing;
    return v;
}

fn expectLP(s: []const u8, env: *const Env, px: f32, pct: f32) !void {
    const v = lp1(s, env) catch |e| {
        std.debug.print("'{s}' -> {}\n", .{ s, e });
        return e;
    };
    if (!std.math.approxEqAbs(f32, v.px, px, 1e-3) or !std.math.approxEqAbs(f32, v.pct, pct, 1e-5)) {
        std.debug.print("'{s}' -> px {d} pct {d}, expected {d} {d}\n", .{ s, v.px, v.pct, px, pct });
        return error.TestUnexpectedResult;
    }
}

test "units dpr=2" {
    const env: Env = .{ .dpr = 2, .vw = 100, .vh = 50, .em = 32, .rem = 32 };
    try expectLP("10px", &env, 20, 0);
    try expectLP("10", &env, 20, 0);
    try expectLP("50vw", &env, 50, 0);
    try expectLP("10vh", &env, 5, 0);
    try expectLP("10vmin", &env, 5, 0);
    try expectLP("10vmax", &env, 10, 0);
    try expectLP("1em", &env, 32, 0);
    try expectLP("2rem", &env, 64, 0);
    try expectLP("12pt", &env, 32, 0);
    try expectLP("1in", &env, 192, 0);
    try expectLP("1pc", &env, 32, 0);
    try expectLP("2.54cm", &env, 192, 0);
    try expectLP("25.4mm", &env, 192, 0);
    try expectLP("4Q", &env, 192.0 / 25.4, 0);
    try expectLP("10PX", &env, 20, 0);
    try expectLP("50%", &env, 0, 0.5);
    try expectLP("-5px", &env, -10, 0);
}

test "calc" {
    const env: Env = .{ .dpr = 1, .vw = 200, .vh = 100, .em = 10, .rem = 16 };
    try expectLP("calc(100% - 20px)", &env, -20, 1);
    try expectLP("calc((100% - 20px) / 2)", &env, -10, 0.5);
    try expectLP("calc(2 * (1em + 5px))", &env, 30, 0);
    try expectLP("calc(10px + 2 * 3px - 1px)", &env, 15, 0);
    try expectLP("calc(50% + 50%)", &env, 0, 1);
    try expectLP("calc(10vw/4)", &env, 5, 0);
    try expectLP("calc(calc(1px + 1px) * 3)", &env, 6, 0);
    try expectLP("min(10px, 2em, 30px)", &env, 10, 0);
    try expectLP("max(10px, 2em)", &env, 20, 0);
    try expectLP("clamp(10px, 5px, 30px)", &env, 10, 0);
    try expectLP("clamp(10px, 50px, 30px)", &env, 30, 0);
    try expectLP("clamp(10px, 20px, 30px)", &env, 20, 0);
    try expectLP("min(10%, 20%)", &env, 0, 0.1);
    try expectLP("calc(1px + min(2px, 3px))", &env, 3, 0);
    const bad = [_][]const u8{
        "calc(100% -20px)", "calc(10px * 2px)", "calc(10px / 0)", "calc(10px + 2)", "calc(1px +)",
        "min(10%, 20px)",   "calc(1deg + 1px)", "calc(foo)",      "clamp(1px, 2px)", "calc(1px 2px)",
        "calc(((((((((((((((((((((((((((((1px)))))))))))))))))))))))))))))",
    };
    for (bad) |s| {
        if (lp1(s, &env)) |v| {
            std.debug.print("expected error for '{s}', got {any}\n", .{ s, v });
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

fn expectPos(s: []const u8, max: usize, x: LP, y: LP) !void {
    const env: Env = .{};
    var l = Lexer.init(s);
    const p = position(&l, &env, max) orelse return error.NoPos;
    try T.expect(l.atEnd());
    if (!p[0].eql(x) or !p[1].eql(y)) {
        std.debug.print("pos '{s}' = {any}\n", .{ s, p });
        return error.TestUnexpectedResult;
    }
}

test "position" {
    try expectPos("center", 4, .{ .pct = 0.5 }, .{ .pct = 0.5 });
    try expectPos("left", 4, .{}, .{ .pct = 0.5 });
    try expectPos("top", 4, .{ .pct = 0.5 }, .{});
    try expectPos("10px", 4, .{ .px = 10 }, .{ .pct = 0.5 });
    try expectPos("top left", 4, .{}, .{});
    try expectPos("right bottom", 4, .{ .pct = 1 }, .{ .pct = 1 });
    try expectPos("center top", 4, .{ .pct = 0.5 }, .{});
    try expectPos("top center", 4, .{ .pct = 0.5 }, .{});
    try expectPos("25% 75%", 4, .{ .pct = 0.25 }, .{ .pct = 0.75 });
    try expectPos("right 10px bottom 20%", 4, .{ .px = -10, .pct = 1 }, .{ .pct = 0.8 });
    try expectPos("bottom 5px right", 4, .{ .pct = 1 }, .{ .px = -5, .pct = 1 });
    try expectPos("left 10px top", 4, .{ .px = 10 }, .{});
    try expectPos("center bottom 3px", 4, .{ .pct = 0.5 }, .{ .px = -3, .pct = 1 });
    const env: Env = .{};
    const bad = [_][]const u8{ "top 10px", "left right", "10px left", "left 10px 20px", "center 10px top 5px", "top bottom" };
    for (bad) |s| {
        var l = Lexer.init(s);
        if (position(&l, &env, 4) != null and l.atEnd()) {
            std.debug.print("expected bad pos '{s}'\n", .{s});
            return error.TestUnexpectedResult;
        }
    }
}
