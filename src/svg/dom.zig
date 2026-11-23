//! Parsed SVG tree: element nodes with raw attributes and cascaded style declarations.
//! Everything is owned by the arena passed to `svg.parse`.
const std = @import("std");

pub const NONE: u32 = std.math.maxInt(u32);

/// Hard limits for untrusted input.
pub const MAX_NODES: u32 = 100_000;
pub const MAX_DEPTH: u32 = 64;

pub const Tag = enum(u8) {
    unknown,
    svg,
    g,
    path,
    rect,
    circle,
    ellipse,
    line,
    polyline,
    polygon,
    use,
    symbol,
    defs,
    a,
    @"switch",
    style,
    linearGradient,
    radialGradient,
    stop,
    pattern,
    clipPath,
    mask,
    image,
    marker,
    filter,
    text,
    tspan,
    textPath,
    feGaussianBlur,
    feOffset,
    feFlood,
    feColorMatrix,
    feComposite,
    feMerge,
    feMergeNode,
    feBlend,
    feDropShadow,
    feComponentTransfer,
    feFuncR,
    feFuncG,
    feFuncB,
    feFuncA,
    // unsupported filter primitives (filter is ignored when present)
    feImage,
    feTile,
    feTurbulence,
    feMorphology,
    feConvolveMatrix,
    feDisplacementMap,
    feDiffuseLighting,
    feSpecularLighting,
    foreignObject,
    /// character data inside `text` / `tspan` / `textPath` (ordered child pseudo-node)
    textnode,

    pub fn fromName(name: []const u8) Tag {
        return @fromBackingInt(@intCast(lookup(&tag_names, name) orelse 0));
    }

    pub fn isShape(t: Tag) bool {
        return switch (t) {
            .path, .rect, .circle, .ellipse, .line, .polyline, .polygon => true,
            else => false,
        };
    }

    pub fn isFilterPrimitive(t: Tag) bool {
        return @backingInt(t) >= @backingInt(Tag.feGaussianBlur) and @backingInt(t) <= @backingInt(Tag.feSpecularLighting);
    }
};

/// Style properties understood by the renderer (CSS name = tag name with '_' -> '-').
pub const Prop = enum(u8) {
    fill,
    fill_opacity,
    fill_rule,
    stroke,
    stroke_width,
    stroke_opacity,
    stroke_linecap,
    stroke_linejoin,
    stroke_miterlimit,
    stroke_dasharray,
    stroke_dashoffset,
    paint_order,
    color,
    visibility,
    clip_rule,
    marker_start,
    marker_mid,
    marker_end,
    font_size,
    font_family,
    font_weight,
    font_style,
    font_stretch,
    font_variant,
    letter_spacing,
    word_spacing,
    text_anchor,
    dominant_baseline,
    text_decoration,
    text_decoration_line,
    color_interpolation_filters,
    // ---- not inherited ----
    opacity,
    display,
    clip_path,
    mask,
    filter,
    stop_color,
    stop_opacity,
    flood_color,
    flood_opacity,
    transform,
    overflow,
    vector_effect,
    mask_type,
    image_rendering,
    mix_blend_mode,
    isolation,
    alignment_baseline,
    baseline_shift,
    // shorthand, expanded at parse time
    marker,

    pub const COUNT = @typeInfo(Prop).@"enum".field_names.len;

    pub fn fromName(name: []const u8) ?Prop {
        if (name.len == 0 or name.len > 32) return null;
        var buf: [32]u8 = undefined;
        for (name, 0..) |c, i| buf[i] = if (c == '-') '_' else std.ascii.toLower(c);
        const n = buf[0..name.len];
        return @fromBackingInt(@intCast(lookup(&prop_names, n) orelse return null));
    }

    pub fn inherited(p: Prop) bool {
        return @backingInt(p) < @backingInt(Prop.opacity);
    }
};

pub const Attr = struct { name: []const u8, value: []const u8 };
pub const Decl = struct { prop: Prop, value: []const u8 };

pub const Node = struct {
    tag: Tag,
    parent: u32 = NONE,
    first_child: u32 = NONE,
    last_child: u32 = NONE,
    next_sibling: u32 = NONE,
    depth: u8 = 0,
    attrs: []const Attr = &.{},
    /// Cascaded declarations (presentation attrs < stylesheet < style attr, `!important` honoured).
    decls: []const Decl = &.{},
    /// Character data (only kept for `style`, `text`, `tspan`, `textPath`).
    text: []const u8 = "",

    /// Attribute by local name. `href` also matches any `prefix:href` (xlink:href).
    pub fn attr(self: *const Node, name: []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (self.attrs) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
            if (found == null and std.mem.eql(u8, name, "href") and a.name.len > 5 and
                std.mem.endsWith(u8, a.name, ":href")) found = a.value;
        }
        return found;
    }

    pub fn decl(self: *const Node, p: Prop) ?[]const u8 {
        for (self.decls) |d| if (d.prop == p) return d.value;
        return null;
    }
};

/// Features seen in the document that this renderer does not implement (the integrator can
/// report them). Set at parse time.
pub const Unsupported = packed struct(u32) {
    text: bool = false,
    filter_primitive: bool = false,
    foreign_object: bool = false,
    /// `<image>` / `<use>` / `<feImage>` referencing something other than `#id` or `data:`
    external_href: bool = false,
    /// a `<style>` rule with an unsupported selector was dropped
    css_selector: bool = false,
    _pad: u27 = 0,
};

pub const Document = struct {
    nodes: []const Node,
    /// Open-addressing table of node indices keyed by `id` (first occurrence wins).
    id_table: []const u32,
    unsupported: Unsupported = .{},

    pub fn root(self: *const Document) *const Node {
        return &self.nodes[0];
    }

    pub fn byId(self: *const Document, id: []const u8) ?u32 {
        if (self.id_table.len == 0 or id.len == 0) return null;
        const mask = self.id_table.len - 1;
        var i = hash(id) & mask;
        var probes: usize = 0;
        while (probes < self.id_table.len) : (probes += 1) {
            const n = self.id_table[i];
            if (n == NONE) return null;
            if (std.mem.eql(u8, self.nodes[n].attr("id") orelse "", id)) return n;
            i = (i + 1) & mask;
        }
        return null;
    }

    /// `url(#id)` / `#id` -> node index.
    pub fn byRef(self: *const Document, ref: []const u8) ?u32 {
        var s = std.mem.trim(u8, ref, " \t\r\n");
        if (std.mem.startsWith(u8, s, "url(")) {
            const e = std.mem.indexOfScalar(u8, s, ')') orelse return null;
            s = std.mem.trim(u8, s[4..e], " \t\r\n\"'");
        }
        if (s.len < 2 or s[0] != '#') return null;
        return self.byId(s[1..]);
    }
};

pub fn hash(s: []const u8) usize {
    var h: u32 = 2166136261;
    for (s) |c| h = (h ^ c) *% 16777619;
    return h;
}

/// Builds `Document.id_table`.
pub fn buildIds(arena: std.mem.Allocator, nodes: []const Node) ![]u32 {
    var n_ids: usize = 0;
    for (nodes) |*n| {
        if (n.attr("id") != null) n_ids += 1;
    }
    if (n_ids == 0) return &.{};
    var cap: usize = 16;
    while (cap < n_ids * 2) cap *= 2;
    const t = try arena.alloc(u32, cap);
    @memset(t, NONE);
    for (nodes, 0..) |*n, ni| {
        const id = n.attr("id") orelse continue;
        if (id.len == 0) continue;
        var i = hash(id) & (cap - 1);
        while (true) {
            const cur = t[i];
            if (cur == NONE) {
                t[i] = @intCast(ni);
                break;
            }
            if (std.mem.eql(u8, nodes[cur].attr("id").?, id)) break; // first wins
            i = (i + 1) & (cap - 1);
        }
    }
    return t;
}

/// Name tables as plain slices (a runtime `@tagName` lowers to a large generated switch).
fn names(comptime E: type) [@typeInfo(E).@"enum".field_names.len][]const u8 {
    const f = @typeInfo(E).@"enum".field_names;
    var out: [f.len][]const u8 = undefined;
    for (f, 0..) |n, i| out[i] = n;
    return out;
}
pub const tag_names = names(Tag);
const prop_names = names(Prop);

fn lookup(table: []const []const u8, name: []const u8) ?u8 {
    for (table, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
    return null;
}
