//! Resource discovery from computed styles, without requiring font bytes or laying out text.
const std = @import("std");
const rt = @import("../render.zig");
const dom = @import("../dom.zig");
const style = @import("../style/style.zig");
const css = @import("../css/css.zig");
const svg_dom = @import("../svg/dom.zig");
const svg_style = @import("../svg/style.zig");
const aType = std.mem.Allocator;
const json = @import("../json.zig");
const font_collection = @import("../font/collection.zig");
const counters = @import("counters.zig");

/// A `fonts` entry of the render with a `unicodeRange`, not loaded yet (takumi `PendingSource::Listed`):
/// what font fallback reads it as before its bytes arrive.
pub const Listed = struct {
    /// its index in the render's `fonts` list
    id: u32,
    name: []const u8,
    weight_min: u16 = 400,
    weight_max: u16 = 400,
    italic: bool = false,
    ranges: []const [2]u21 = &.{},

    fn covers(l: *const Listed, cp: u21) bool {
        for (l.ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
        return false;
    }
    /// CSS font matching distance to a request (style first, then weight)
    fn score(l: *const Listed, weight: u16, italic: bool) u64 {
        const have = std.math.clamp(weight, l.weight_min, @max(l.weight_min, l.weight_max));
        var d: u64 = font_collection.weightDistance(weight, have);
        if (l.italic != italic) d += 1 << 20;
        return d;
    }
};

/// The `listedFonts` of the options (`js/pdf-resources.mjs`): `[{ id, name, weight: [min, max],
/// italic, ranges: [[from, to], ...] }]`.
pub fn parseListed(a: aType, v: ?json.Value) ![]const Listed {
    const list = v orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList(Listed) = .empty;
    for (list.array) |item| {
        const id = (item.get("id") orelse continue).asNumber() orelse continue;
        const name = (item.get("name") orelse continue).asString() orelse continue;
        var l: Listed = .{ .id = @intFromFloat(@max(0, id)), .name = name };
        if (item.get("weight")) |w| if (w == .array and w.array.len == 2) {
            l.weight_min = @intFromFloat(std.math.clamp(w.array[0].asNumber() orelse 400, 1, 1000));
            l.weight_max = @intFromFloat(std.math.clamp(w.array[1].asNumber() orelse 400, 1, 1000));
        };
        if (item.get("italic")) |i| l.italic = i.asBool() orelse false;
        if (item.get("ranges")) |rs| if (rs == .array) {
            var ranges: std.ArrayList([2]u21) = .empty;
            for (rs.array) |r| {
                if (r != .array or r.array.len != 2) continue;
                const lo = r.array[0].asNumber() orelse continue;
                const hi = r.array[1].asNumber() orelse continue;
                try ranges.append(a, .{ @intFromFloat(std.math.clamp(lo, 0, 0x10ffff)), @intFromFloat(std.math.clamp(hi, 0, 0x10ffff)) });
            }
            l.ranges = ranges.items;
        };
        try out.append(a, l);
    }
    return out.items;
}

pub const Collector = struct {
    a: aType,
    images: std.StringHashMapUnmanaged(void) = .empty,
    text: std.ArrayList(u8) = .empty,
    requests: std.ArrayList(u8) = .empty,
    faces: std.ArrayList(u8) = .empty,
    /// the listed fonts not loaded yet, and the ids of those font fallback reaches
    listed: []const Listed = &.{},
    reached: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    /// (set by `collect`: the frame read)
    frame: ?*const rt.Frame = null,

    fn image(c: *Collector, value: style.Image) !void {
        if (value == .url and value.url.len > 0) try c.images.put(c.a, value.url, {});
    }
    fn textOf(c: *Collector, text: []const u8, cs: *const style.ComputedStyle) !void {
        if (text.len == 0 or cs.display == .none) return;
        const shown = try rt.transformText(c.a, text, cs.text_transform, cs.white_space_collapse == .preserve or cs.white_space_collapse == .preserve_spaces or cs.white_space_collapse == .break_spaces);
        try c.text.appendSlice(c.a, shown);
        if (c.requests.items.len > 0) try c.requests.append(c.a, ',');
        try c.requests.appendSlice(c.a, "{\"text\":");
        try rt.writeJsonString(c.a, &c.requests, shown);
        try c.requests.appendSlice(c.a, ",\"families\":[");
        for (cs.font_family, 0..) |name, i| {
            if (i != 0) try c.requests.append(c.a, ',');
            try rt.writeJsonString(c.a, &c.requests, name);
        }
        try c.requests.appendSlice(c.a, "],\"weight\":");
        try rt.writeNum(c.a, &c.requests, cs.font_weight);
        try c.requests.appendSlice(c.a, if (cs.font_style == .normal) ",\"style\":\"normal\"}" else ",\"style\":\"italic\"}");
        try c.fallback(shown, cs);
    }

    /// takumi `NeedsCollector::add_text`: the listed font each character of `text` makes font
    /// fallback load. The families of `cs`, then the render's `fontFamilies`, are walked in
    /// order: the best listed face (CSS matching) of the first family whose `unicodeRange`
    /// claims the character is reached, unless the family's registered faces draw it and match
    /// the weight and style at least as well (a registered face ends the walk). A listed face
    /// that, once loaded, lacks the glyph is registered then: the next read walks on past it.
    fn fallback(c: *Collector, text: []const u8, cs: *const style.ComputedStyle) !void {
        if (c.listed.len == 0) return;
        const f = c.frame orelse return;
        const fonts = &f.r.fonts;
        const italic = cs.font_style != .normal;
        var chain: std.ArrayList([]const u8) = .empty;
        for ([2][]const []const u8{ cs.font_family, f.opts.font_families }) |list| for (list) |name| {
            for (chain.items) |have| {
                if (std.ascii.eqlIgnoreCase(have, name)) break;
            } else try chain.append(c.a, name);
        };
        var seen: std.AutoHashMapUnmanaged(u21, void) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            const d = @import("../font/unicode.zig").decodeUtf8(text, i);
            i += d.len;
            if (d.cp < 0x20) continue;
            if ((try seen.getOrPut(c.a, d.cp)).found_existing) continue;
            for (chain.items) |family| {
                var pending: ?*const Listed = null;
                for (c.listed) |*l| {
                    if (!std.ascii.eqlIgnoreCase(l.name, family) or !l.covers(d.cp)) continue;
                    if (pending == null or l.score(cs.font_weight, italic) < pending.?.score(cs.font_weight, italic)) pending = l;
                }
                var buf: [32]@import("../font/font.zig").FaceId = undefined;
                const fams = [_][]const u8{family};
                var best: ?u64 = null;
                var draws = false;
                for (fonts.match(&fams, cs.font_weight, italic, &buf)) |id| {
                    const face = fonts.face(id);
                    if (!std.ascii.eqlIgnoreCase(face.family, family)) break;
                    if (best == null) {
                        const have = std.math.clamp(cs.font_weight, face.weight_min, @max(face.weight_min, face.weight_max));
                        best = font_collection.weightDistance(cs.font_weight, have) + @as(u64, if (face.italic != italic and !face.can_italic) 1 << 20 else 0);
                    }
                    if (fonts.allows(id, d.cp) and face.font.glyphIndex(d.cp) != 0) draws = true;
                }
                if (pending) |l| if (!draws or l.score(cs.font_weight, italic) < best.?) {
                    try c.reached.put(c.a, l.id, {});
                    break;
                };
                if (draws) break;
            }
        }
    }
    fn svgText(c: *Collector, f: *const rt.Frame, src: []const u8, cs: *const style.ComputedStyle) !void {
        if (comptime !@import("../config.zig").enable_svg) return;
        const source = f.r.resolveSvg(src) orelse return;
        const svg = @import("../svg/svg.zig");
        const tree = svg.parse(c.a, source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        try c.svgNode(&tree, 0, .{}, cs, false, 0);
    }
    fn svgNode(c: *Collector, tree: *const svg_dom.Document, id: u32, parent: svg_style.Style, cs: *const style.ComputedStyle, referenced: bool, depth: u32) rt.Error!void {
        if (depth >= svg_dom.MAX_DEPTH or id >= tree.nodes.len) return;
        const node = &tree.nodes[id];
        if (node.decl(.display)) |v| if (std.mem.eql(u8, std.mem.trim(u8, v, " \t\r\n"), "none")) return;
        if (!referenced) switch (node.tag) {
            .defs, .symbol, .clipPath, .mask, .pattern, .marker, .filter => return,
            else => {},
        };
        var inherited = parent;
        inherited.apply(node);
        if (node.tag == .textnode and inherited.visible and inherited.font_size > 0) {
            var text_cs = cs.*;
            text_cs.text_transform = .none;
            text_cs.font_style = .normal;
            const weight = std.mem.trim(u8, inherited.font_weight, " \t\r\n");
            text_cs.font_weight = if (std.mem.eql(u8, weight, "bold") or std.mem.eql(u8, weight, "bolder")) 700 else if (std.mem.eql(u8, weight, "lighter")) 300 else std.fmt.parseInt(u16, weight, 10) catch 400;
            if (text_cs.font_weight < 1 or text_cs.font_weight > 1000) text_cs.font_weight = 400;
            var families: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, inherited.font_family, ',');
            while (it.next()) |raw| {
                const name = std.mem.trim(u8, raw, " \t\r\n'\"");
                if (name.len > 0) try families.append(c.a, name);
            }
            if (families.items.len > 0) text_cs.font_family = families.items;
            try c.textOf(node.text, &text_cs);
        }
        if (node.tag == .use) {
            if (node.attr("href")) |href| if (tree.byRef(href)) |target| try c.svgNode(tree, target, inherited, cs, true, depth + 1);
            return;
        }
        var child = node.first_child;
        while (child != svg_dom.NONE) : (child = tree.nodes[child].next_sibling) try c.svgNode(tree, child, inherited, cs, false, depth + 1);
    }
    pub fn collect(c: *Collector, f: *const rt.Frame) !void {
        c.frame = f;
        defer c.frame = null;
        for (f.dom.els.items) |el| {
            if (el.cs.display == .none) continue;
            var parent = el.parent;
            var visible = true;
            var guard: u32 = 0;
            while (parent != dom.none and guard < 512) : (guard += 1) {
                const p = f.dom.at(parent);
                if (p.cs.display == .none) {
                    visible = false;
                    break;
                }
                parent = p.parent;
            }
            if (!visible) continue;
            if (el.kind == .image) if (el.src) |src| {
                if (src.len > 0 and src[0] != '<') try c.images.put(c.a, src, {});
                try c.svgText(f, src, el.cs);
            };
            for (el.cs.background_image) |v| {
                try c.image(v);
                if (v == .url) try c.svgText(f, v.url, el.cs);
            }
            for (el.cs.mask_image) |v| try c.image(v);
            if (el.cs.display == .list_item) try c.image(el.cs.list_style_image);
            try c.textOf(el.text, el.cs);
            // a page / target counter hook draws numerals no text holds yet: takumi reads them when
            // it writes the counter, so the face its style's characters fall in loads too
            if (!el.run) if (counters.hookOf(el.class) != null) try c.textOf(counters.CounterStyle.fromClasses(el.class).symbols(), el.cs);
        }
        for (f.pseudos.items) |p| {
            try c.textOf(p.text, p.cs);
            for (p.cs.background_image) |v| try c.image(v);
            if (p.parts) |parts| for (parts) |part| if (part == .url) try c.images.put(c.a, part.url, {});
        }
        if (comptime @import("../config.zig").enable_css) for (css.fontFaces(&f.cssx.m)) |face| {
            if (c.faces.items.len > 0) try c.faces.append(c.a, ',');
            try c.faces.appendSlice(c.a, "{\"name\":");
            try rt.writeJsonString(c.a, &c.faces, face.family);
            const fields = [_][]const u8{ "src", "font-weight", "font-style", "unicode-range" };
            const keys = [_][]const u8{ "src", "weight", "style", "unicodeRange" };
            for (fields, keys) |field, key| if (face.get(field)) |value| {
                try c.faces.append(c.a, ',');
                try rt.writeJsonString(c.a, &c.faces, key);
                try c.faces.append(c.a, ':');
                try rt.writeJsonString(c.a, &c.faces, value);
            };
            try c.faces.append(c.a, '}');
        };
    }
    pub fn finish(c: *Collector) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(c.a, "{\"images\":[");
        var it = c.images.keyIterator();
        var first = true;
        while (it.next()) |url| {
            if (!first) try out.append(c.a, ',');
            first = false;
            try rt.writeJsonString(c.a, &out, url.*);
        }
        try out.appendSlice(c.a, "],\"text\":");
        try rt.writeJsonString(c.a, &out, c.text.items);
        try out.appendSlice(c.a, ",\"requests\":[");
        try out.appendSlice(c.a, c.requests.items);
        try out.appendSlice(c.a, "],\"faces\":[");
        try out.appendSlice(c.a, c.faces.items);
        try out.appendSlice(c.a, "],\"fonts\":[");
        for (c.reached.keys(), 0..) |id, k| {
            if (k != 0) try out.append(c.a, ',');
            try rt.writeNum(c.a, &out, @floatFromInt(id));
        }
        try out.appendSlice(c.a, "]}");
        return out.items;
    }
};
