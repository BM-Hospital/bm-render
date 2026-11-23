//! Motion geometry shared by measured transforms and all paint backends.
const std = @import("std");
const c = @import("computed.zig");
const raster = @import("../raster/raster.zig");
const data = @import("../svg/pathdata.zig");
const measure = @import("../raster/path_measure.zig");
const Env = @import("values.zig").Env;

/// A shape whose reference box is only known per element: in paged output (takumi-pdf lays
/// content out on a viewport of unbounded height) `offset-path` resolves against the viewport
/// width and the element's own border-box height (takumi `local_transform`: the query
/// container, else the viewport size, else the element). Each height is measured once.
pub const Lazy = struct {
    a: std.mem.Allocator,
    shape: ?c.BasicShape,
    dpr: f32,
    width: f32,
    entries: std.ArrayList(struct { h: f32, m: ?*const measure.Measure }) = .empty,

    fn get(l: *Lazy, h: f32) ?*const measure.Measure {
        for (l.entries.items) |e| if (e.h == h) return e.m;
        const m = build(l.a, l.shape, l.dpr, l.width, h) catch return null;
        l.entries.append(l.a, .{ .h = h, .m = m }) catch {};
        return m;
    }
};

/// Without a viewport height (`env.vh_unbounded`) the reference box takes the element's (see `Lazy`).
pub fn compile(a: std.mem.Allocator, shape: ?c.BasicShape, ray: ?c.MotionRay, env: Env) !*const c.MotionPath {
    const paged = env.vh_unbounded;
    const out = try a.create(c.MotionPath);
    out.* = .{ .ray = ray, .reference = .{ env.vw, if (paged) 0 else env.vh } };
    if (ray != null) return out;
    const by_height = if (shape) |sh| sh != .path else true;
    if (paged and by_height) {
        const lazy = try a.create(Lazy);
        lazy.* = .{ .a = a, .shape = shape, .dpr = env.dpr, .width = env.vw };
        out.lazy = lazy;
        return out;
    }
    out.measured = try build(a, shape, env.dpr, env.vw, env.vh);
    return out;
}

fn build(a: std.mem.Allocator, shape: ?c.BasicShape, dpr: f32, w: f32, h: f32) !?*const measure.Measure {
    var p: raster.Path = .empty;
    defer p.deinit(a);
    if (shape) |sh| switch (sh) {
        .path => |v| {
            try data.parse(a, v.d, &p, null);
            for (p.points.items) |*point| {
                point.x *= dpr;
                point.y *= dpr;
            }
        },
        .polygon => |v| if (v.points.len > 0) {
            try p.moveTo(a, v.points[0][0].resolve(w), v.points[0][1].resolve(h));
            for (v.points[1..]) |point| try p.lineTo(a, point[0].resolve(w), point[1].resolve(h));
            try p.close(a);
        },
        .circle => |v| {
            const x = v.at[0].resolve(w);
            const y = v.at[1].resolve(h);
            const r = switch (v.r) {
                .lp => |lp| lp.resolve(@sqrt((w * w + h * h) / 2)),
                .closest_side => @min(@min(@abs(x), @abs(w - x)), @min(@abs(y), @abs(h - y))),
                .farthest_side => @max(@max(@abs(x), @abs(w - x)), @max(@abs(y), @abs(h - y))),
            };
            try data.ellipse(a, &p, x, y, r, r);
        },
        .ellipse => |v| {
            const x = v.at[0].resolve(w);
            const y = v.at[1].resolve(h);
            try data.ellipse(a, &p, x, y, radius(v.rx, x, w), radius(v.ry, y, h));
        },
        .inset => |v| {
            const x = v.sides[3].resolve(w);
            const y = v.sides[0].resolve(h);
            try data.rect(a, &p, x, y, w - x - v.sides[1].resolve(w), h - y - v.sides[2].resolve(h), 0, 0);
        },
    } else try data.rect(a, &p, 0, 0, w, h, 0, 0);
    const m = try a.create(measure.Measure);
    m.* = .{};
    return if (try m.build(a, &p)) m else null;
}

fn radius(r: c.ShapeRadius, x: f32, full: f32) f32 {
    return switch (r) {
        .lp => |v| v.resolve(full),
        .closest_side => @min(@abs(x), @abs(full - x)),
        .farthest_side => @max(@abs(x), @abs(full - x)),
    };
}

pub fn sample(cs: *const c.ComputedStyle, w: f32, h: f32) ?measure.Sample {
    const path = cs.offset_path orelse return null;
    if (if (path.lazy) |lazy| lazy.get(h) else path.measured) |m| {
        const distance: f64 = cs.offset_distance.resolve(@floatCast(m.length));
        const at = if (m.closed) @mod(distance, m.length) else distance;
        return m.sampleCss(at);
    }
    const ray = path.ray orelse return null;
    const width = if (path.reference[0] > 0) path.reference[0] else w;
    const height = if (path.reference[1] > 0) path.reference[1] else h;
    const position = ray.at orelse cs.offset_position orelse c.center2;
    const x = position[0].resolve(width);
    const y = position[1].resolve(height);
    const rads = ray.angle * (std.math.pi / 180.0);
    const direction = rads - std.math.pi / 2.0;
    var length: f32 = 0;
    switch (ray.size) {
        .closest_side => length = @min(@min(@abs(x), @abs(width - x)), @min(@abs(y), @abs(height - y))),
        .farthest_side => length = @max(@max(@abs(x), @abs(width - x)), @max(@abs(y), @abs(height - y))),
        .closest_corner, .farthest_corner => {
            length = if (ray.size == .closest_corner) std.math.inf(f32) else 0;
            for ([_][2]f32{ .{ 0, 0 }, .{ width, 0 }, .{ width, height }, .{ 0, height } }) |corner| {
                const dx = corner[0] - x;
                const dy = corner[1] - y;
                const distance = @sqrt(dx * dx + dy * dy);
                length = if (ray.size == .closest_corner) @min(length, distance) else @max(length, distance);
            }
        },
        .sides => if (x >= 0 and x <= width and y >= 0 and y <= height) {
            const sin = @sin(rads);
            const cos = @cos(rads);
            const vertical = if (cos >= 0) y else height - y;
            const horizontal = if (sin >= 0) width - x else x;
            length = if (vertical * @abs(sin) > horizontal * @abs(cos)) horizontal / @abs(sin) else vertical / @abs(cos);
        },
    }
    const distance = cs.offset_distance.resolve(length);
    return .{ .x = x + distance * @cos(direction), .y = y + distance * @sin(direction), .angle = direction };
}

/// Inserted after individual translate/rotate/scale, before the transform list.
pub fn transform(cs: *const c.ComputedStyle, w: f32, h: f32) ?raster.Affine {
    const p = sample(cs, w, h) orelse return null;
    const ox = cs.transform_origin[0].resolve(w);
    const oy = cs.transform_origin[1].resolve(h);
    const angle = cs.offset_rotate.angle * (std.math.pi / 180.0) + switch (cs.offset_rotate.mode) {
        .auto => p.angle,
        .reverse => p.angle + std.math.pi,
        .fixed => @as(f32, 0),
    };
    var m = raster.Affine.translate(p.x - ox, p.y - oy).mul(raster.Affine.rotate(angle));
    if (cs.offset_anchor) |anchor| m = m.mul(raster.Affine.translate(ox - anchor[0].resolve(w), oy - anchor[1].resolve(h)));
    return if (m.isFinite()) m else null;
}
