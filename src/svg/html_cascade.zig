//! Reach inline SVG descendants with the page's selector engine, keeping image SVGs isolated.
//! Match the SVG subtree with page rules; serialize resolved declarations into the image source.
const std = @import("std");
const rt = @import("../render.zig");
const html_dom = @import("../dom.zig");
const css = @import("../css/css.zig");
const svg_dom = @import("dom.zig");
const svg_css = @import("css.zig");
const xml = @import("xml.zig");
const style = @import("../style/style.zig");

fn escape(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, attribute: bool) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '"' => if (attribute) try out.appendSlice(a, "&quot;") else try out.append(a, c),
        else => try out.append(a, c),
    };
}

const Writer = struct {
    a: std.mem.Allocator,
    nodes: []const svg_dom.Node,
    styles: []const []const u8,
    out: std.ArrayList(u8) = .empty,
    fn node(w: *Writer, index: u32) error{OutOfMemory}!void {
        const n = &w.nodes[index];
        if (n.tag == .style) return;
        if (n.tag == .textnode) return escape(w.a, &w.out, n.text, false);
        if (n.tag == .unknown) return;
        const tag = svg_dom.tag_names[@backingInt(n.tag)];
        try w.out.append(w.a, '<');
        try w.out.appendSlice(w.a, tag);
        for (n.attrs) |attr| {
            if (std.mem.eql(u8, attr.name, "style")) continue;
            try w.out.append(w.a, ' ');
            try w.out.appendSlice(w.a, attr.name);
            try w.out.appendSlice(w.a, "=\"");
            try escape(w.a, &w.out, attr.value, true);
            try w.out.append(w.a, '"');
        }
        if (w.styles[index].len > 0) {
            try w.out.appendSlice(w.a, " style=\"");
            try escape(w.a, &w.out, w.styles[index], true);
            try w.out.append(w.a, '"');
        }
        try w.out.append(w.a, '>');
        var child = n.first_child;
        while (child != svg_dom.NONE) : (child = w.nodes[child].next_sibling) try w.node(child);
        try w.out.appendSlice(w.a, "</");
        try w.out.appendSlice(w.a, tag);
        try w.out.append(w.a, '>');
    }
};

/// The inherited SVG properties the HTML ancestors of an inline `<svg>` declare (page rules and
/// `style` attributes), the nearest one winning. The font comes from the host's computed style
/// (`hostFont`), `color` reaches the SVG as its current colour and `visibility` hides the host.
fn htmlInherited(f: *rt.Frame, host: u32) rt.Error![svg_dom.Prop.COUNT]?[]const u8 {
    var out: [svg_dom.Prop.COUNT]?[]const u8 = @splat(null);
    var chain: std.ArrayList(u32) = .empty;
    var up = f.dom.at(host).parent;
    while (up != html_dom.none) : (up = f.dom.at(up).parent) try chain.append(f.a, up);
    if (chain.items.len == 0) return out;
    var scratch = css.Scratch.init(f.a);
    const vt = rt.CssDom.vtable(&f.dom);
    var declarations: @TypeOf(f.cssx.decls) = .empty;
    var normal: std.ArrayList(svg_dom.Decl) = .empty;
    var important: std.ArrayList(svg_dom.Decl) = .empty;
    var i = chain.items.len;
    while (i > 0) {
        i -= 1;
        const id = chain.items[i];
        declarations.clearRetainingCapacity();
        const matched = try css.match(&f.cssx.m, &scratch, &vt, id, .none, &declarations);
        normal.clearRetainingCapacity();
        important.clearRetainingCapacity();
        const el = f.dom.at(id);
        if (el.style == .text) try svg_css.parseDecls(f.a, el.style.text, &normal, &important);
        var own: [svg_dom.Prop.COUNT]?[]const u8 = @splat(null);
        for (declarations.items[0..matched.important_start]) |d| if (svg_dom.Prop.fromName(d.name)) |p| {
            own[@backingInt(p)] = d.value;
        };
        for (normal.items) |d| own[@backingInt(d.prop)] = d.value;
        for (declarations.items[matched.important_start..]) |d| if (svg_dom.Prop.fromName(d.name)) |p| {
            own[@backingInt(p)] = d.value;
        };
        for (important.items) |d| own[@backingInt(d.prop)] = d.value;
        for (own, 0..) |value, p| {
            const prop: svg_dom.Prop = @fromBackingInt(@intCast(p));
            if (!prop.inherited()) continue;
            switch (prop) {
                .color, .visibility, .font_size, .font_family, .font_weight, .font_style, .font_stretch, .font_variant, .text_decoration, .text_decoration_line => continue,
                else => {},
            }
            const v = value orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, v, " \t\r\n"), "inherit")) continue;
            out[p] = if (style.hasVar(v)) try style.substituteVars(f.a, el.cs.custom_props, v) else v;
        }
    }
    return out;
}

/// The host's computed font as SVG declarations, where the root element sets none.
fn hostFont(f: *rt.Frame, cs: *const style.ComputedStyle, values: *[svg_dom.Prop.COUNT]?[]const u8) rt.Error!void {
    const dpr = if (f.opts.dpr > 0) f.opts.dpr else 1;
    if (values[@backingInt(svg_dom.Prop.font_size)] == null)
        values[@backingInt(svg_dom.Prop.font_size)] = try std.fmt.allocPrint(f.a, "{d}px", .{cs.font_size / dpr});
    if (values[@backingInt(svg_dom.Prop.font_family)] == null and cs.font_family.len > 0) {
        var text: std.ArrayList(u8) = .empty;
        for (cs.font_family, 0..) |family, i| {
            if (i > 0) try text.appendSlice(f.a, ", ");
            try text.appendSlice(f.a, family);
        }
        values[@backingInt(svg_dom.Prop.font_family)] = text.items;
    }
    if (values[@backingInt(svg_dom.Prop.font_weight)] == null)
        values[@backingInt(svg_dom.Prop.font_weight)] = try std.fmt.allocPrint(f.a, "{d}", .{cs.font_weight});
    if (values[@backingInt(svg_dom.Prop.font_style)] == null and cs.font_style != .normal)
        values[@backingInt(svg_dom.Prop.font_style)] = "italic";
    if (values[@backingInt(svg_dom.Prop.font_stretch)] == null and cs.font_stretch != 100)
        values[@backingInt(svg_dom.Prop.font_stretch)] = try std.fmt.allocPrint(f.a, "{d}%", .{cs.font_stretch});
}

/// `parent` (sorted by name) with the custom properties an SVG element declares in matched rules
/// and its `style` attribute, their own `var()`s resolved against `parent`.
fn withCustoms(a: std.mem.Allocator, parent: []const style.computed.CustomProp, matched: anytype, inline_style: []const u8) rt.Error![]const style.computed.CustomProp {
    var list: std.ArrayList(style.computed.CustomProp) = .empty;
    const Add = struct {
        fn one(al: std.mem.Allocator, l: *std.ArrayList(style.computed.CustomProp), base: []const style.computed.CustomProp, name: []const u8, raw: []const u8) rt.Error!void {
            if (l.items.len == 0) try l.appendSlice(al, base);
            const value = (try style.substituteVars(al, base, std.mem.trim(u8, raw, " \t\r\n"))) orelse return;
            for (l.items) |*c| if (std.mem.eql(u8, c.name, name)) {
                c.value = value;
                return;
            };
            var at: usize = 0;
            while (at < l.items.len and std.mem.order(u8, l.items[at].name, name) == .lt) at += 1;
            try l.insert(al, at, .{ .name = name, .value = value });
        }
    };
    for (matched) |d| if (std.mem.startsWith(u8, d.name, "--")) try Add.one(a, &list, parent, d.name, d.value);
    var it = std.mem.splitScalar(u8, inline_style, ';');
    while (it.next()) |decl| {
        const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
        const name = std.mem.trim(u8, decl[0..colon], " \t\r\n");
        if (std.mem.startsWith(u8, name, "--")) try Add.one(a, &list, parent, name, decl[colon + 1 ..]);
    }
    return if (list.items.len == 0) parent else list.items;
}

pub fn generate(f: *rt.Frame) rt.Error!void {
    // (also without page rules: the SVG still inherits from its HTML ancestors' `style`
    // attributes, custom properties and font)
    const count = f.dom.els.items.len;
    for (0..count) |host| {
        const el = f.dom.els.items[host];
        if (el.kind != .image or !std.ascii.eqlIgnoreCase(el.tag, "svg")) continue;
        const source = el.src orelse continue;
        const parsed = xml.parse(f.a, source) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        if (parsed.nodes.len == 0) continue;
        // Takumi gives the SVG layout its subtree and the page rules, rather than a live
        // HTML ancestor chain. Selectors can cross SVG ancestors, but not the image boundary.
        var combined: html_dom.Dom = .{};
        var root = el;
        const root_attrs = try f.a.alloc(html_dom.Attr, parsed.nodes[0].attrs.len);
        for (parsed.nodes[0].attrs, root_attrs) |attr, *dst| dst.* = .{ .name = attr.name, .value = attr.value };
        root.attrs = root_attrs;
        root.parent = html_dom.none;
        root.first = html_dom.none;
        root.last = html_dom.none;
        root.prev = html_dom.none;
        root.next = html_dom.none;
        combined.root = try combined.add(f.a, root, html_dom.none);
        const ids = try f.a.alloc(u32, parsed.nodes.len);
        ids[0] = combined.root;
        for (parsed.nodes[1..], 1..) |n, i| {
            const attrs = try f.a.alloc(html_dom.Attr, n.attrs.len);
            for (n.attrs, attrs) |attr, *dst| dst.* = .{ .name = attr.name, .value = attr.value };
            ids[i] = try combined.add(f.a, .{
                .kind = if (n.tag == .textnode) .text else .container,
                .run = n.tag == .textnode,
                .text = n.text,
                .tag = if (n.tag == .textnode) "" else svg_dom.tag_names[@backingInt(n.tag)],
                .id = n.attr("id") orelse "",
                .class = n.attr("class") orelse "",
                .attrs = attrs,
            }, ids[n.parent]);
        }
        // The page's already active rules and the SVG's own sheets share one cascade.
        var sheet: css.Stylesheet = .{};
        try sheet.layer_names.appendSlice(f.a, f.cssx.m.layer_names);
        for (f.cssx.m.rules) |active| {
            var rule = active.rule.*;
            rule.gates = &.{};
            rule.layer = if (active.layer == f.cssx.m.layer_count) css.sheet.no_layer else active.layer;
            try sheet.rules.append(f.a, rule);
        }
        for (parsed.nodes) |n| if (n.tag == .style) try css.parse(f.a, n.text, &sheet);
        const matcher = try css.prepare(f.a, &sheet, .{ .viewport_w = f.ctx.viewport_w, .viewport_h = f.ctx.viewport_h, .print = if (comptime @import("../config.zig").enable_pdf) f.tree.paged.pdf else false, .dpr = f.opts.dpr });
        var scratch = css.Scratch.init(f.a);
        const vt = rt.CssDom.vtable(&combined);
        var declarations: @TypeOf(f.cssx.decls) = .empty;
        const styles = try f.a.alloc([]const u8, parsed.nodes.len);
        // The custom properties each SVG element sees: the host's computed ones, then those its
        // SVG ancestors and itself declare.
        const customs = try f.a.alloc([]const style.computed.CustomProp, parsed.nodes.len);
        const inherited = try htmlInherited(f, @intCast(host));
        for (parsed.nodes, 0..) |n, i| {
            declarations.clearRetainingCapacity();
            const matched = try css.match(&matcher, &scratch, &vt, ids[i], .none, &declarations);
            customs[i] = if (i == 0) el.cs.custom_props else try withCustoms(f.a, customs[n.parent], declarations.items, n.attr("style") orelse "");
            var normal: std.ArrayList(svg_dom.Decl) = .empty;
            var important: std.ArrayList(svg_dom.Decl) = .empty;
            try svg_css.parseDecls(f.a, n.attr("style") orelse "", &normal, &important);
            var values: [svg_dom.Prop.COUNT]?[]const u8 = @splat(null);
            for (declarations.items[0..matched.important_start]) |d| if (svg_dom.Prop.fromName(d.name)) |p| {
                values[@backingInt(p)] = d.value;
            };
            for (normal.items) |d| values[@backingInt(d.prop)] = d.value;
            for (declarations.items[matched.important_start..]) |d| if (svg_dom.Prop.fromName(d.name)) |p| {
                values[@backingInt(p)] = d.value;
            };
            for (important.items) |d| values[@backingInt(d.prop)] = d.value;
            // presentation attributes that need `var()`: the lowest origin of the cascade
            for (n.attrs) |attr| if (svg_dom.Prop.fromName(attr.name)) |p| {
                if (values[@backingInt(p)] == null and style.hasVar(attr.value)) values[@backingInt(p)] = attr.value;
            };
            // `var()` resolves against the element's custom properties; an invalid reference
            // leaves the property unset (inherited, or its initial value).
            for (&values) |*value| if (value.*) |v| if (style.hasVar(v)) {
                value.* = try style.substituteVars(f.a, customs[i], v);
            };
            if (i == 0) {
                // The host's HTML box already applies these properties around the SVG viewport.
                // Descendant SVG elements still use them in SVG paint space.
                for ([_]svg_dom.Prop{ .opacity, .transform, .mix_blend_mode, .isolation, .clip_path, .mask, .filter }) |p|
                    values[@backingInt(p)] = null;
                // The root inherits the SVG properties of its HTML ancestors (takumi lays the SVG
                // out in the host's style context) and the host's computed font.
                for (&values, inherited) |*value, from_html| if (value.* == null) {
                    value.* = from_html;
                };
                try hostFont(f, el.cs, &values);
            }
            var text: std.ArrayList(u8) = .empty;
            for (values, 0..) |value, p| if (value) |v| {
                const name = @tagName(@as(svg_dom.Prop, @fromBackingInt(@intCast(p))));
                for (name) |c| try text.append(f.a, if (c == '_') '-' else c);
                try text.append(f.a, ':');
                try text.appendSlice(f.a, v);
                try text.appendSlice(f.a, "!important;");
            };
            styles[i] = text.items;
        }
        var writer: Writer = .{ .a = f.a, .nodes = parsed.nodes, .styles = styles };
        try writer.node(0);
        f.dom.els.items[host].src = writer.out.items;
    }
}
