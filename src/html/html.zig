//! Tolerant HTML parser + Chromium UA presets for bm-render (port of takumi-core `html/` minus node building).
//!
//! Standalone (std only). Mirrors the behaviour of takumi's `html::parse_html` tree construction, which is a
//! pragmatic subset of the WHATWG algorithm (see the "Scope" list below), so the node tree an integrator builds
//! from it has the same shape as takumi's.
//!
//! Memory: every allocation goes through the `arena` passed to `parse`; nothing is freed individually. Result
//! slices (`Node.text`, attribute values, ...) may point INTO the input `html` slice when no decoding was needed,
//! so keep the input alive as long as the Document.
//!
//! Scope (what is implemented, mirrors takumi):
//!  * tokenizer: tags, attributes (quoted / unquoted / boolean, duplicates: first wins, names lowercased),
//!    comments (dropped), doctype (only used for the quirks-mode flag), `<?...>` / `<!...>` bogus comments,
//!    `\r\n`/`\r` normalised to `\n`, leading BOM stripped, character references (numeric incl. the Windows-1252
//!    C1 remap, named: 338 of the 2231 HTML names, see entity_data.zig; all legacy no-semicolon names kept).
//!  * raw text (`script style xmp iframe noembed noframes noscript`), RCDATA (`textarea title`, entities decoded),
//!    leading newline after `<pre>`/`<listing>`/`<textarea>` dropped, void elements, `</br>` == `<br>`.
//!  * implied end tags (checked against the innermost open element only, like takumi): `p` (by the ENDS_P list, and by
//!    `table` outside quirks mode), `li`, `dt/dd`, `option/optgroup`, `td/th/tr`, `tr`; implied `tbody`/`tr` inside
//!    `table`. An end tag closes everything above the nearest same-named open element (no scope checks).
//!  * document mode (source starts with a doctype or `<html`): head-type elements before body content do not
//!    reach the body; `<html>/<body>` attributes are collected; whitespace before body content is dropped.
//!    Fragment mode (anything else): `<html>/<head>/<body>` tags are ignored, no wrappers are added.
//!  * `<template>`: element kept, contents discarded. `<svg>...</svg>`: ONE node (tag "svg", `attrs` of the start
//!    tag, no children) whose `text` is the exact source slice of the whole element (nested svg, comments, CDATA
//!    and quoted `>` are skipped correctly). No SVG attribute/element case repair (takumi re-serialises with it).
//!  * `<style>` text (type empty or text/css, `@media X {..}` wrapped when it has a `media` attribute) goes to
//!    `Document.styles` in document order; `<title>`; `<meta name=.. content=..>` pairs.
//!  * `<style>/<script>/<meta>/<link>` elements STAY in the tree (as takumi's DOM does, because they influence its
//!    "element holds only text" rule); the integrator must skip `isUnrendered(tag)` elements when building boxes.
//!
//! Not implemented (same gaps as takumi): adoption agency / formatting-element reconstruction, foster parenting,
//! `<math>` namespace, SVG-in-HTML breakouts, `<select>`/`<frameset>`/`<plaintext>` insertion modes, scripting.
//! Documented deviations: nesting deeper than `max_depth` -> error.TooDeep (takumi: MaxDepthExceeded at the same
//! depth +- 2, it counts html/body); explicit `<body>` arriving while body-level elements are still open is
//! handled as if they had been closed; content of `<head>` other than head-type tags goes to the body (spec).

const std = @import("std");
const entity_data = @import("entity_data.zig");
const preset_data = @import("preset_data.zig");

pub const Error = error{ OutOfMemory, TooDeep };

/// Maximum number of simultaneously open elements.
pub const max_depth = 512;

pub const Attr = struct { name: []const u8, value: []const u8 };
pub const Meta = struct { name: []const u8, content: []const u8 };

pub const Node = struct {
    kind: enum { element, text },
    /// Lowercased tag name (elements only).
    tag: []const u8 = "",
    /// Text nodes: decoded character data. `svg` elements: the exact source slice of the whole element.
    /// Raw-text elements keep their raw text as a single text child instead.
    text: []const u8 = "",
    /// Name lowercased, value entity-decoded; first duplicate wins.
    attrs: []const Attr = &.{},
    children: []const *Node = &.{},

    pub fn attr(self: *const Node, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }

    /// takumi turns an element whose children are all text (comments ignored) and not all ASCII white space into a
    /// text node. Adjacent text is already merged, so that is: exactly one child, a text node, with a non-space char.
    /// Returns that text, or null when the element must stay a container.
    pub fn soleText(self: *const Node) ?[]const u8 {
        if (self.kind != .element or self.children.len != 1) return null;
        const c = self.children[0];
        if (c.kind != .text) return null;
        for (c.text) |ch| {
            if (!isWs(ch)) return c.text;
        }
        return null;
    }
};

pub const Document = struct {
    /// Children of `<body>` (document mode) or the top-level nodes (fragment mode).
    root_children: []const *Node,
    /// Attributes of an explicit `<html>` tag (document mode).
    html_attrs: []const Attr,
    /// Attributes of `<body>` (document mode; first tag plus attributes later `<body>` tags add).
    body_attrs: []const Attr,
    /// Text of every CSS `<style>` element in document order (outside svg).
    styles: []const []const u8,
    /// Text of the first `<title>`, or "".
    title: []const u8,
    /// `<meta name=.. content=..>` pairs in order (content "" when absent).
    metas: []const Meta,
    /// Source opened with a doctype or `<html>`: takumi then builds an `html` root (display:block) with the `body`
    /// (preset margin:8px) inside it. Otherwise it is a fragment: roots are used as is.
    is_document: bool,

    pub fn meta(self: *const Document, name: []const u8) ?[]const u8 {
        for (self.metas) |m| {
            if (std.mem.eql(u8, m.name, name)) return m.content;
        }
        return null;
    }
};

/// Tags takumi drops from its node tree (`UNRENDERED_TAGS`); the parser still keeps them in the DOM.
pub fn isUnrendered(tag: []const u8) bool {
    const t = [_][]const u8{ "head", "meta", "link", "style", "script" };
    for (t) |x| if (std.mem.eql(u8, tag, x)) return true;
    return false;
}

/// takumi has NO sniffing: in its wasm binding every JS *string* is HTML and a JSON tree is passed as `{json: str}`.
/// For a byte buffer of unknown origin this returns false when it (after BOM / white space) starts with `{` or `[`
/// (a JSON node tree) and true otherwise.
pub fn looksLikeHtml(text: []const u8) bool {
    var s = text;
    if (std.mem.startsWith(u8, s, "\xEF\xBB\xBF")) s = s[3..];
    for (s) |c| {
        if (isWs(c) or c == 0x0b) continue;
        return c != '{' and c != '[';
    }
    return true;
}

/// Parse `html` (UTF-8; invalid bytes pass through untouched). Never fails on malformed markup.
pub fn parse(arena: std.mem.Allocator, html: []const u8) Error!Document {
    var src = html;
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src = src[3..];
    if (std.mem.indexOfScalar(u8, src, '\r') != null) {
        const buf = try arena.alloc(u8, src.len);
        var o: usize = 0;
        var i: usize = 0;
        while (i < src.len) : (i += 1) {
            var c = src[i];
            if (c == '\r') {
                c = '\n';
                if (i + 1 < src.len and src[i + 1] == '\n') i += 1;
            }
            buf[o] = c;
            o += 1;
        }
        src = buf[0..o];
    }
    const is_doc = isDocument(src);
    var p: Parser = .{ .a = arena, .src = src, .document = is_doc, .quirks = is_doc };
    while (p.pos < p.src.len) try p.step();
    try p.closeTo(0);
    return .{
        .root_children = try arena.dupe(*Node, p.kids.items),
        .html_attrs = p.html_attrs.items,
        .body_attrs = p.body_attrs.items,
        .styles = p.styles.items,
        .title = p.title orelse "",
        .metas = p.metas.items,
        .is_document = is_doc,
    };
}

/// takumi's `is_document`: after white space and comments, a doctype or an `<html` tag.
pub fn isDocument(source: []const u8) bool {
    var rest = std.mem.trimStart(u8, source, " \t\r\n\x0b\x0c");
    while (true) {
        if (rest.len >= 9 and std.ascii.eqlIgnoreCase(rest[0..9], "<!doctype")) return true;
        if (std.mem.startsWith(u8, rest, "<!--")) {
            const e = std.mem.indexOf(u8, rest, "-->") orelse return false;
            rest = std.mem.trimStart(u8, rest[e + 3 ..], " \t\r\n\x0b\x0c");
            continue;
        }
        if (rest.len >= 5 and std.ascii.eqlIgnoreCase(rest[0..5], "<html")) {
            if (rest.len == 5) return false;
            const c = rest[5];
            return c == '>' or c == '/' or isWs(c) or c == 0x0b;
        }
        return false;
    }
}

// ------------------------------------------------------------------------------------------------ parser

const Open = struct { node: *Node, kid_start: u32, to_head: bool, sp: Sp };

const Tag = struct { name: []const u8, attrs: []const Attr, self_closing: bool };

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    document: bool,
    quirks: bool,
    body_started: bool = false,
    body_open: bool = false,
    html_seen: bool = false,
    tpl_depth: u32 = 0,
    open: std.ArrayList(Open) = .empty,
    kids: std.ArrayList(*Node) = .empty,
    styles: std.ArrayList([]const u8) = .empty,
    metas: std.ArrayList(Meta) = .empty,
    html_attrs: std.ArrayList(Attr) = .empty,
    body_attrs: std.ArrayList(Attr) = .empty,
    attr_buf: std.ArrayList(Attr) = .empty,
    /// Name sets mirroring `attr_buf` / `html_attrs` / `body_attrs` once they grow past `attr_set_min`, so the
    /// first-wins duplicate check stays linear (see `hasAttr`).
    attr_set: AttrSet = .empty,
    html_set: AttrSet = .empty,
    body_set: AttrSet = .empty,
    /// The text node that adjacent text is currently merged into, and its growable buffer (geometric growth,
    /// so merging many small pieces is amortised linear instead of copying the whole run each time).
    run_node: ?*Node = null,
    run_buf: std.ArrayList(u8) = .empty,
    title: ?[]const u8 = null,

    const AttrSet = std.StringHashMapUnmanaged(void);
    const attr_set_min = 16;

    /// Whether `list` (names unique, append-only since `set` was last cleared) already holds `name`.
    fn hasAttr(p: *Parser, list: []const Attr, set: *AttrSet, name: []const u8) Error!bool {
        if (list.len < attr_set_min) {
            for (list) |e| {
                if (std.mem.eql(u8, e.name, name)) return true;
            }
            return false;
        }
        // Catch the set up with names appended since the last call (names are unique, so count == synced prefix).
        while (set.count() < list.len) try set.put(p.a, list[set.count()].name, {});
        return set.contains(name);
    }

    fn step(p: *Parser) Error!void {
        const rest = p.src[p.pos..];
        var i: usize = 0;
        var found: ?usize = null;
        while (std.mem.indexOfScalarPos(u8, rest, i, '<')) |lt| {
            if (lt + 1 < rest.len) {
                const n = rest[lt + 1];
                if (std.ascii.isAlphabetic(n) or n == '/' or n == '!' or n == '?') {
                    found = lt;
                    break;
                }
            }
            i = lt + 1;
        }
        if (found == null or found.? != 0) {
            const end = found orelse rest.len;
            p.pos += end;
            try p.insertText(try decode(p.a, rest[0..end], false));
            return;
        }
        try p.markup();
    }

    fn markup(p: *Parser) Error!void {
        const rest = p.src[p.pos..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            const after = rest[4..];
            if (std.mem.startsWith(u8, after, ">")) {
                p.pos += 5;
            } else if (std.mem.startsWith(u8, after, "->")) {
                p.pos += 6;
            } else if (std.mem.indexOf(u8, after, "-->")) |e| {
                p.pos += 4 + e + 3;
            } else p.pos = p.src.len;
        } else if (std.mem.startsWith(u8, rest, "<!") or std.mem.startsWith(u8, rest, "<?")) {
            const body = rest[2..];
            const e = std.mem.indexOfScalar(u8, body, '>');
            const decl = if (e) |x| body[0..x] else body;
            p.pos += 2 + (if (e) |x| x + 1 else body.len);
            if (decl.len >= 7 and std.ascii.eqlIgnoreCase(decl[0..7], "doctype") and !p.html_seen) {
                const t = std.mem.trimStart(u8, decl[7..], " \t\r\n\x0c");
                var n: usize = 0;
                while (n < t.len and !isWs(t[n])) n += 1;
                p.quirks = !std.ascii.eqlIgnoreCase(t[0..n], "html");
            }
        } else if (std.mem.startsWith(u8, rest, "</")) {
            if (rest.len > 2 and std.ascii.isAlphabetic(rest[2])) {
                p.pos += 2;
                const tag = try p.readTag();
                try p.endTag(tag.name);
            } else {
                const body = rest[2..];
                const e = std.mem.indexOfScalar(u8, body, '>');
                p.pos += 2 + (if (e) |x| x + 1 else body.len);
            }
        } else {
            const start = p.pos;
            p.pos += 1;
            const tag = try p.readTag();
            try p.startTag(tag, start);
        }
    }

    /// Reads a tag from its name to its closing `>` (p.pos is just after `<` or `</`).
    fn readTag(p: *Parser) Error!Tag {
        const s = p.src;
        var i = p.pos;
        const ns = i;
        while (i < s.len and !isTagDelim(s[i])) i += 1;
        const name = try lower(p.a, s[ns..i]);
        p.attr_buf.clearRetainingCapacity();
        p.attr_set.clearRetainingCapacity();
        var self_closing = false;
        while (true) {
            while (i < s.len and isWs(s[i])) i += 1;
            if (i >= s.len) break;
            if (s[i] == '/' and i + 1 < s.len and s[i + 1] == '>') {
                i += 2;
                self_closing = true;
                break;
            }
            if (s[i] == '>') {
                i += 1;
                break;
            }
            if (s[i] == '/') {
                i += 1;
                continue;
            }
            // attribute name: first byte always belongs to it (may be '=')
            var ne = i + 1;
            while (ne < s.len and !isTagDelim(s[ne]) and s[ne] != '=') ne += 1;
            const aname = s[i..ne];
            var j = ne;
            while (j < s.len and isWs(s[j])) j += 1;
            var value: []const u8 = "";
            if (j < s.len and s[j] == '=') {
                j += 1;
                while (j < s.len and isWs(s[j])) j += 1;
                if (j < s.len and (s[j] == '"' or s[j] == '\'')) {
                    const q = s[j];
                    const vs = j + 1;
                    const ve = std.mem.indexOfScalarPos(u8, s, vs, q);
                    value = s[vs .. ve orelse s.len];
                    j = if (ve) |x| x + 1 else s.len;
                } else {
                    const vs = j;
                    while (j < s.len and !isWs(s[j]) and s[j] != '>') j += 1;
                    value = s[vs..j];
                }
                i = j;
            } else i = ne;
            const lname = try lower(p.a, aname);
            if (!try p.hasAttr(p.attr_buf.items, &p.attr_set, lname)) try p.attr_buf.append(p.a, .{ .name = lname, .value = try decode(p.a, value, true) });
        }
        p.pos = i;
        return .{ .name = name, .attrs = p.attr_buf.items, .self_closing = self_closing };
    }

    fn startTag(p: *Parser, tag: Tag, tag_start: usize) Error!void {
        const name = tag.name;
        const inf = info(name);
        const sp = inf.sp;
        if (sp == .svg) return p.svgElement(tag, tag_start);
        if (sp == .html or sp == .head or sp == .body) {
            if (p.document) try p.documentElement(tag, sp);
            return;
        }
        try p.closeImpliedBy(inf);
        try p.openImpliedTableParents(inf);

        const raw = inf.flags & F_RAW != 0;
        const rcdata = sp == .title or sp == .textarea;
        const opens = inf.flags & F_VOID == 0 and !raw and !rcdata;
        const to_head = p.placeBody(inf.flags & F_HEAD != 0);
        const node = try p.newElement(name, tag.attrs);

        if (sp == .pre or sp == .textarea) {
            if (p.pos < p.src.len and p.src[p.pos] == '\n') p.pos += 1;
        }
        if (raw or rcdata) {
            const text = p.rawText(name);
            const t = if (rcdata) try decode(p.a, text, false) else text;
            if (t.len != 0) {
                const tn = try p.a.create(Node);
                tn.* = .{ .kind = .text, .text = t };
                const ch = try p.a.alloc(*Node, 1);
                ch[0] = tn;
                node.children = ch;
            }
            if (p.tpl_depth == 0) {
                if (sp == .style) try p.addStyle(node, t);
                if (sp == .title and p.title == null) p.title = t;
            }
            try p.attach(node, to_head);
        } else if (opens) {
            if (p.open.items.len >= max_depth) return error.TooDeep;
            if (sp == .template) p.tpl_depth += 1;
            try p.open.append(p.a, .{ .node = node, .kid_start = @intCast(p.kids.items.len), .to_head = to_head, .sp = sp });
        } else {
            if (sp == .meta and p.tpl_depth == 0) {
                if (node.attr("name")) |n| try p.metas.append(p.a, .{ .name = n, .content = node.attr("content") orelse "" });
            }
            try p.attach(node, to_head);
        }
    }

    fn addStyle(p: *Parser, node: *Node, text: []const u8) Error!void {
        if (node.attr("type")) |t| {
            if (t.len != 0 and !std.ascii.eqlIgnoreCase(t, "text/css")) return;
        }
        if (text.len == 0) return;
        if (node.attr("media")) |m0| {
            const m = std.mem.trim(u8, m0, " \t\r\n\x0c");
            if (m.len != 0) {
                const out = try p.a.alloc(u8, 8 + m.len + 2 + text.len + 1);
                var o: usize = 0;
                inline for (.{ "@media ", m, " {", text, "}" }) |part| {
                    @memcpy(out[o .. o + part.len], part);
                    o += part.len;
                }
                try p.styles.append(p.a, out[0..o]);
                return;
            }
        }
        try p.styles.append(p.a, text);
    }

    /// Decides where a new node goes; returns true when it belongs to `<head>` (document mode, not in the tree).
    fn placeBody(p: *Parser, head_el: bool) bool {
        if (!p.document or p.open.items.len != 0 or p.body_started) return false;
        p.html_seen = true;
        if (head_el) return true;
        p.body_started = true;
        return false;
    }

    fn newElement(p: *Parser, name: []const u8, attrs: []const Attr) Error!*Node {
        const n = try p.a.create(Node);
        n.* = .{ .kind = .element, .tag = name, .attrs = try p.a.dupe(Attr, attrs) };
        return n;
    }

    fn attach(p: *Parser, node: *Node, to_head: bool) Error!void {
        if (to_head) return;
        try p.kids.append(p.a, node);
    }

    fn svgElement(p: *Parser, tag: Tag, tag_start: usize) Error!void {
        const to_head = p.placeBody(false);
        const node = try p.newElement("svg", tag.attrs);
        if (!tag.self_closing) p.pos = skipSvg(p.src, p.pos);
        node.text = p.src[tag_start..p.pos];
        try p.attach(node, to_head);
    }

    fn documentElement(p: *Parser, tag: Tag, sp: Sp) Error!void {
        p.html_seen = true;
        const target: ?*std.ArrayList(Attr) = if (sp == .html) &p.html_attrs else if (sp == .body) &p.body_attrs else null;
        if (sp == .body and !p.body_started) {
            p.body_started = true;
            p.body_open = true;
        }
        if (target) |t| {
            const set = if (sp == .html) &p.html_set else &p.body_set;
            for (tag.attrs) |at| {
                if (!try p.hasAttr(t.items, set, at.name)) try t.append(p.a, at);
            }
        }
    }

    fn insertText(p: *Parser, text: []const u8) Error!void {
        if (text.len == 0) return;
        if (p.document and p.open.items.len == 0 and !p.body_started) {
            var all_ws = true;
            for (text) |c| {
                if (!isWs(c)) {
                    all_ws = false;
                    break;
                }
            }
            if (all_ws) return;
            p.html_seen = true;
            p.body_started = true;
        }
        const cs: usize = if (p.open.items.len > 0) p.open.items[p.open.items.len - 1].kid_start else 0;
        if (p.kids.items.len > cs) {
            const last = p.kids.items[p.kids.items.len - 1];
            if (last.kind == .text) {
                // `last` is only referenced from `kids` (it is copied into a parent's children when that closes,
                // and is never the last kid again afterwards), so it can be extended in place.
                if (p.run_node != last) {
                    // Start a new run; the previous run's buffer stays alive in the arena for its node.
                    p.run_buf = .empty;
                    try p.run_buf.ensureTotalCapacity(p.a, 2 * (last.text.len + text.len));
                    p.run_buf.appendSliceAssumeCapacity(last.text);
                    p.run_node = last;
                }
                try p.run_buf.appendSlice(p.a, text);
                last.text = p.run_buf.items;
                return;
            }
        }
        const n = try p.a.create(Node);
        n.* = .{ .kind = .text, .text = text };
        try p.kids.append(p.a, n);
    }

    fn endTag(p: *Parser, name: []const u8) Error!void {
        const sp = info(name).sp;
        if (sp == .br) return p.startTag(.{ .name = "br", .attrs = &.{}, .self_closing = false }, p.pos);
        if (p.document and sp == .body) {
            if (p.body_open) {
                try p.closeTo(0);
                p.body_open = false;
            }
            return;
        }
        if (sp == .html or sp == .head or sp == .body) return;
        var i = p.open.items.len;
        while (i > 0) {
            i -= 1;
            if (eq(p.open.items[i].node.tag, name)) {
                try p.closeTo(i);
                return;
            }
        }
    }

    fn closeTo(p: *Parser, idx: usize) Error!void {
        while (p.open.items.len > idx) {
            const o = p.open.pop().?;
            const node = o.node;
            if (o.sp == .template) {
                p.tpl_depth -|= 1;
                node.children = &.{};
            } else {
                node.children = try p.a.dupe(*Node, p.kids.items[o.kid_start..]);
            }
            p.kids.shrinkRetainingCapacity(o.kid_start);
            try p.attach(node, o.to_head);
        }
    }

    fn closeImpliedBy(p: *Parser, inf: Info) Error!void {
        while (p.open.items.len > 0) {
            const n = inf.sp;
            const closes = switch (p.open.items[p.open.items.len - 1].sp) {
                .p => inf.flags & F_ENDSP != 0 or (n == .table and !p.quirks),
                .li => n == .li,
                .dtdd => n == .dtdd,
                .option => n == .option or n == .optgroup,
                .td, .th => n == .td or n == .th or n == .tr,
                .tr => n == .tr,
                else => false,
            };
            if (!closes) break;
            try p.closeTo(p.open.items.len - 1);
        }
    }

    fn openImpliedTableParents(p: *Parser, inf: Info) Error!void {
        if (p.open.items.len == 0) return;
        const n = inf.sp;
        const implied: []const u8 = switch (p.open.items[p.open.items.len - 1].sp) {
            .table => if (n == .tr or n == .td or n == .th) "tbody" else return,
            .tsec => if (n == .td or n == .th) "tr" else return,
            else => return,
        };
        try p.startTag(.{ .name = implied, .attrs = &.{}, .self_closing = false }, p.pos);
        try p.openImpliedTableParents(inf);
    }

    /// Text of a raw-text/RCDATA element up to its end tag (consumed); everything when unterminated.
    fn rawText(p: *Parser, name: []const u8) []const u8 {
        const s = p.src;
        const start = p.pos;
        var i = start;
        while (std.mem.indexOfScalarPos(u8, s, i, '<')) |lt| {
            i = lt + 1;
            const after = lt + 2 + name.len;
            if (s.len >= after and s[lt + 1] == '/' and std.ascii.eqlIgnoreCase(s[lt + 2 .. after], name) and
                (after == s.len or isTagDelim(s[after])))
            {
                const gt = std.mem.indexOfScalarPos(u8, s, after, '>');
                p.pos = if (gt) |g| g + 1 else s.len;
                return s[start..lt];
            }
        }
        p.pos = s.len;
        return s[start..];
    }
};

/// Position just after the `</svg>` matching an already-opened svg (src[from..] is its content).
fn skipSvg(s: []const u8, from: usize) usize {
    var depth: usize = 1;
    var i = from;
    while (std.mem.indexOfScalarPos(u8, s, i, '<')) |lt| {
        const r = s[lt..];
        if (std.mem.startsWith(u8, r, "<!--")) {
            i = if (std.mem.indexOf(u8, r[4..], "-->")) |e| lt + 4 + e + 3 else return s.len;
        } else if (std.mem.startsWith(u8, r, "<![CDATA[")) {
            i = if (std.mem.indexOf(u8, r[9..], "]]>")) |e| lt + 9 + e + 3 else return s.len;
        } else if (r.len > 1 and (std.ascii.isAlphabetic(r[1]) or r[1] == '/')) {
            const closing = r[1] == '/';
            var k = lt + (if (closing) @as(usize, 2) else 1);
            const ns = k;
            while (k < s.len and !isTagDelim(s[k])) k += 1;
            const is_svg = std.ascii.eqlIgnoreCase(s[ns..k], "svg");
            // scan to the end of the tag honouring quotes
            var q: u8 = 0;
            var self_close = false;
            while (k < s.len) : (k += 1) {
                const c = s[k];
                if (q != 0) {
                    if (c == q) q = 0;
                } else if (c == '"' or c == '\'') {
                    q = c;
                } else if (c == '>') {
                    self_close = s[k - 1] == '/';
                    break;
                }
            }
            if (k >= s.len) return s.len;
            i = k + 1;
            if (is_svg) {
                if (closing) {
                    depth -= 1;
                    if (depth == 0) return i;
                } else if (!self_close) depth += 1;
            }
        } else i = lt + 1;
    }
    return s.len;
}

// ------------------------------------------------------------------------------------------------ helpers

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0c or c == '\r';
}
fn isTagDelim(c: u8) bool {
    return isWs(c) or c == '/' or c == '>';
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn lower(a: std.mem.Allocator, s: []const u8) Error![]const u8 {
    for (s, 0..) |c, i| {
        if (c >= 'A' and c <= 'Z') {
            const out = try a.alloc(u8, s.len);
            @memcpy(out[0..i], s[0..i]);
            for (s[i..], i..) |d, j| out[j] = std.ascii.toLower(d);
            return out;
        }
    }
    return s;
}

const F_VOID: u8 = 1;
const F_RAW: u8 = 2;
const F_HEAD: u8 = 4;
const F_ENDSP: u8 = 8;

/// Tags with a role in tree construction; the discriminant is stored in the packed tag table.
const Sp = enum(u8) { none, p, li, dtdd, option, optgroup, td, th, tr, table, tsec, br, svg, html, head, body, template, pre, textarea, title, style, meta };
const Info = struct { flags: u8, sp: Sp };

const tag_rows = .{
    // ends an open <p> (and a few more roles)
    .{ "address", F_ENDSP, .none }, .{ "article", F_ENDSP, .none }, .{ "aside", F_ENDSP, .none }, .{ "blockquote", F_ENDSP, .none },
    .{ "center", F_ENDSP, .none }, .{ "dd", F_ENDSP, .dtdd }, .{ "details", F_ENDSP, .none }, .{ "dialog", F_ENDSP, .none },
    .{ "dir", F_ENDSP, .none }, .{ "div", F_ENDSP, .none }, .{ "dl", F_ENDSP, .none }, .{ "dt", F_ENDSP, .dtdd },
    .{ "fieldset", F_ENDSP, .none }, .{ "figcaption", F_ENDSP, .none }, .{ "figure", F_ENDSP, .none }, .{ "footer", F_ENDSP, .none },
    .{ "form", F_ENDSP, .none }, .{ "h1", F_ENDSP, .none }, .{ "h2", F_ENDSP, .none }, .{ "h3", F_ENDSP, .none },
    .{ "h4", F_ENDSP, .none }, .{ "h5", F_ENDSP, .none }, .{ "h6", F_ENDSP, .none }, .{ "header", F_ENDSP, .none },
    .{ "hgroup", F_ENDSP, .none }, .{ "hr", F_ENDSP | F_VOID, .none }, .{ "li", F_ENDSP, .li }, .{ "listing", F_ENDSP, .pre },
    .{ "main", F_ENDSP, .none }, .{ "menu", F_ENDSP, .none }, .{ "nav", F_ENDSP, .none }, .{ "ol", F_ENDSP, .none },
    .{ "p", F_ENDSP, .p }, .{ "plaintext", F_ENDSP, .none }, .{ "pre", F_ENDSP, .pre }, .{ "search", F_ENDSP, .none },
    .{ "section", F_ENDSP, .none }, .{ "summary", F_ENDSP, .none }, .{ "ul", F_ENDSP, .none }, .{ "xmp", F_ENDSP | F_RAW, .none },
    // void
    .{ "area", F_VOID, .none }, .{ "basefont", F_VOID, .none }, .{ "bgsound", F_VOID, .none }, .{ "col", F_VOID, .none },
    .{ "embed", F_VOID, .none }, .{ "frame", F_VOID, .none }, .{ "img", F_VOID, .none }, .{ "input", F_VOID, .none },
    .{ "keygen", F_VOID, .none }, .{ "param", F_VOID, .none }, .{ "source", F_VOID, .none }, .{ "track", F_VOID, .none },
    .{ "wbr", F_VOID, .none }, .{ "br", F_VOID, .br },
    // head-type
    .{ "base", F_VOID | F_HEAD, .none }, .{ "link", F_VOID | F_HEAD, .none }, .{ "meta", F_VOID | F_HEAD, .meta },
    .{ "script", F_RAW | F_HEAD, .none }, .{ "style", F_RAW | F_HEAD, .style }, .{ "noscript", F_RAW | F_HEAD, .none },
    .{ "title", F_HEAD, .title },
    // raw text
    .{ "iframe", F_RAW, .none }, .{ "noembed", F_RAW, .none }, .{ "noframes", F_RAW, .none }, .{ "textarea", 0, .textarea },
    // structure
    .{ "option", 0, .option }, .{ "optgroup", 0, .optgroup }, .{ "td", 0, .td }, .{ "th", 0, .th },
    .{ "tr", 0, .tr }, .{ "table", 0, .table }, .{ "tbody", 0, .tsec }, .{ "thead", 0, .tsec },
    .{ "tfoot", 0, .tsec }, .{ "svg", 0, .svg }, .{ "html", 0, .html }, .{ "head", 0, .head },
    .{ "body", 0, .body }, .{ "template", 0, .template },
};

/// Packed table: name bytes (< 0x80), then 0x80|flags, 0x80|Sp.
const tag_table = blk: {
    var out: []const u8 = "";
    for (tag_rows) |r| out = out ++ r[0] ++ &[_]u8{ 0x80 | r[1], 0x80 | @intFromEnum(@as(Sp, r[2])) };
    break :blk out;
};

fn info(name: []const u8) Info {
    const t = tag_table;
    var i: usize = 0;
    while (i < t.len) {
        var j: usize = i;
        while (t[j] < 0x80) j += 1;
        if (j - i == name.len and std.mem.eql(u8, t[i..j], name)) return .{ .flags = t[j] & 0x7f, .sp = @enumFromInt(t[j + 1] & 0x7f) };
        i = j + 2;
    }
    return .{ .flags = 0, .sp = .none };
}

// ------------------------------------------------------------------------------------------------ entities

const c1_map = [32]u16{
    0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
    0x90,   0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
};

/// Decodes character references. Returns `s` itself when there is no `&`. Output is never longer than the input.
pub fn decode(a: std.mem.Allocator, s: []const u8, in_attr: bool) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    const out = try a.alloc(u8, s.len);
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c != '&') {
            out[o] = c;
            o += 1;
            i += 1;
            continue;
        }
        const after = s[i + 1 ..];
        var consumed: usize = 0;
        if (after.len > 0 and after[0] == '#') {
            consumed = numeric(after[1..], out[o..], &o);
        } else {
            consumed = named(after, in_attr, out[o..], &o);
        }
        if (consumed == 0) {
            out[o] = '&';
            o += 1;
            i += 1;
        } else i += 1 + consumed;
    }
    return out[0..o];
}

/// Returns bytes consumed after '&#' (0 = not a reference); writes UTF-8 to dst and advances o.
fn numeric(t: []const u8, dst: []u8, o: *usize) usize {
    var k: usize = 0;
    var radix: u32 = 10;
    if (t.len > 0 and (t[0] == 'x' or t[0] == 'X')) {
        radix = 16;
        k = 1;
    }
    const ds = k;
    var cp: u32 = 0;
    while (k < t.len) : (k += 1) {
        const d = std.fmt.charToDigit(t[k], @intCast(radix)) catch break;
        cp = cp *| radix +| d;
    }
    if (k == ds) return 0;
    if (k < t.len and t[k] == ';') k += 1;
    var ch: u21 = 0xFFFD;
    if (cp >= 0x80 and cp <= 0x9f) {
        ch = c1_map[cp - 0x80];
    } else if (cp != 0 and cp <= 0x10FFFF and !(cp >= 0xD800 and cp <= 0xDFFF)) {
        ch = @intCast(cp);
    }
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(ch, &tmp) catch 0;
    if (n > dst.len) return 0;
    @memcpy(dst[0..n], tmp[0..n]);
    o.* += n;
    return k + 1; // + the '#'
}

fn lookup(name: []const u8, legacy_only: bool) ?[]const u8 {
    const b = entity_data.blob;
    var i: usize = 0;
    while (i < b.len) {
        const h = b[i];
        const nl: usize = h & 0x7f;
        const vl: usize = b[i + 1 + nl];
        if (nl == name.len and (!legacy_only or h & 0x80 != 0) and std.mem.eql(u8, b[i + 1 .. i + 1 + nl], name))
            return b[i + 2 + nl .. i + 2 + nl + vl];
        i += 2 + nl + vl;
    }
    return null;
}

/// Returns bytes consumed after '&' (0 = none).
fn named(t: []const u8, in_attr: bool, dst: []u8, o: *usize) usize {
    var rl: usize = 0;
    while (rl < t.len and rl < 32 and std.ascii.isAlphanumeric(t[rl])) rl += 1;
    if (rl < t.len and t[rl] == ';') {
        if (lookup(t[0..rl], false)) |v| return emit(v, rl + 1, dst, o);
    }
    var len = @min(rl, 6);
    while (len >= 2) : (len -= 1) {
        if (lookup(t[0..len], true)) |v| {
            if (in_attr and len < t.len and (t[len] == '=' or std.ascii.isAlphanumeric(t[len]))) return 0;
            return emit(v, len, dst, o);
        }
    }
    return 0;
}

fn emit(v: []const u8, consumed: usize, dst: []u8, o: *usize) usize {
    if (v.len > dst.len) return 0;
    @memcpy(dst[0..v.len], v);
    o.* += v.len;
    return consumed;
}

// ------------------------------------------------------------------------------------------------ presets

pub const Decl = struct { name: []const u8, value: []const u8 };

const PresetEntry = struct { key: []const u8, decls: []const Decl };

fn parseDecls(comptime css: []const u8) []const Decl {
    comptime {
        @setEvalBranchQuota(100000);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, css, ';');
        while (it.next()) |_| n += 1;
        var arr: [n]Decl = undefined;
        var k: usize = 0;
        it = std.mem.splitScalar(u8, css, ';');
        while (it.next()) |d| {
            const c = std.mem.indexOfScalar(u8, d, ':').?;
            arr[k] = .{ .name = d[0..c], .value = d[c + 1 ..] };
            k += 1;
        }
        const final = arr;
        return &final;
    }
}

/// "key\0css\0key\0css\0..." (no pointers, so the compact path costs only the text).
const css_blob = blk: {
    var o: []const u8 = "";
    for (preset_data.rows) |r| o = o ++ r[0] ++ "\x00" ++ r[1] ++ "\x00";
    break :blk o;
};

/// Chromium UA style of an HTML element named `tag` (lowercase) as CSS declaration text exactly as takumi writes it
/// (`"font-size:2em;margin-top:0.67em;..."`), "" for tags without a preset. This is takumi's `DEFAULT_PRESETS` table
/// (takumi-core/src/html/mod.rs; it applies it to HTML input at the lowest cascade layer, below presentation attributes,
/// stylesheets and the `style` attribute). Also answers the form-control keys `input[type=search]`, `input:disabled`,
/// `textarea[wrap=off]`, ... This is the cheapest entry point (no per-declaration pointer tables in the binary).
pub fn presetCss(tag: []const u8) []const u8 {
    const b = css_blob;
    // (per row: key offset / length and css length into the blob, the css right after the key's
    // terminator; a look-up compares lengths first instead of scanning the blob for terminators)
    for (css_rows) |r| {
        if (r.key_len != tag.len) continue;
        const k = b[r.at..][0..r.key_len];
        if (std.mem.eql(u8, k, tag)) return b[r.at + r.key_len + 1 ..][0..r.css_len];
    }
    return "";
}

const CssRow = struct { at: u16, key_len: u8, css_len: u16 };
const css_rows = blk: {
    @setEvalBranchQuota(100_000);
    var rows: [preset_data.rows.len]CssRow = undefined;
    var at: usize = 0;
    for (preset_data.rows, 0..) |r, i| {
        rows[i] = .{ .at = at, .key_len = r[0].len, .css_len = r[1].len };
        at += r[0].len + 1 + r[1].len + 1;
    }
    std.debug.assert(at == css_blob.len);
    const final = rows;
    break :blk final;
};

const decl_table = blk: {
    var e: [preset_data.rows.len]PresetEntry = undefined;
    for (preset_data.rows, 0..) |r, i| e[i] = .{ .key = r[0], .decls = parseDecls(r[1]) };
    break :blk e;
};

/// Same data as `presetCss`, pre-split into declarations (name in kebab-case, value text). Empty for unknown tags.
/// Costs ~16 bytes of binary per declaration more than `presetCss`; prefer that one when you have a CSS declaration parser.
pub fn preset(tag: []const u8) []const Decl {
    for (&decl_table) |*e| {
        if (std.mem.eql(u8, e.key, tag)) return e.decls;
    }
    return &.{};
}

/// takumi's `form_control_preset`: the preset rows (CSS text, apply in order, later declarations win) of an `<input>` or
/// `<textarea>` node, depending on `type`, `wrap` and disabled state. `in_disabled_fieldset` = inside a `<fieldset disabled>`
/// and not inside its first `<legend>`. Returns the number of rows written to `out` (0 = no preset, e.g. checkbox inputs).
/// (`preset("input")`/`presetCss("input")` alone is only the base text-field row.)
pub fn formControlPresets(node: *const Node, in_disabled_fieldset: bool, out: *[3][]const u8) usize {
    var n: usize = 0;
    var disabled_key: []const u8 = "";
    if (eq(node.tag, "textarea")) {
        out[0] = presetCss("textarea");
        n = 1;
        if (node.attr("wrap")) |w| {
            if (std.ascii.eqlIgnoreCase(w, "off")) {
                out[n] = presetCss("textarea[wrap=off]");
                n += 1;
            }
        }
        disabled_key = "textarea:disabled";
    } else if (eq(node.tag, "input")) {
        const ty = node.attr("type") orelse "text";
        const non_text = [_][]const u8{ "date", "month", "week", "time", "datetime-local", "range", "color", "checkbox", "radio", "file", "submit", "image", "reset", "button" };
        var is_text = true;
        for (non_text) |x| if (std.ascii.eqlIgnoreCase(ty, x)) {
            is_text = false;
        };
        if (std.ascii.eqlIgnoreCase(ty, "hidden")) {
            out[0] = presetCss("input[type=hidden]");
            n = 1;
        } else if (is_text) {
            out[0] = presetCss("input");
            n = 1;
            if (std.ascii.eqlIgnoreCase(ty, "search")) {
                out[1] = presetCss("input[type=search]");
                n = 2;
            } else if (std.ascii.eqlIgnoreCase(ty, "tel")) {
                out[1] = presetCss("input[type=tel]");
                n = 2;
            }
            disabled_key = "input:disabled";
        }
    }
    if (n != 0 and disabled_key.len != 0 and n < 3 and (in_disabled_fieldset or node.attr("disabled") != null)) {
        out[n] = presetCss(disabled_key);
        n += 1;
    }
    return n;
}

// ------------------------------------------------------------------------------------------------ fixtures

/// Render options implied by a takumi HTML fixture file (tests/html_fixtures.rs): `<body style="width:Wpx;height:Hpx">`
/// is the viewport in CSS px, `<meta name="takumi-device-pixel-ratio" content="N">` the (integer) DPR (output
/// viewport = px * dpr, `devicePixelRatio` = dpr), `<meta name="takumi-presets" content="chromium">` opts INTO the
/// element presets (fixtures otherwise run with NO presets). These are conventions of takumi's TEST HARNESS only:
/// `renderer.render(htmlString)` ignores them and always applies the Chromium presets. The harness also parses
/// only the body's INNER html as a fragment, with `<style>` text as the stylesheet.
pub const Fixture = struct { width: ?u32 = null, height: ?u32 = null, dpr: u32 = 1, chromium_presets: bool = false };

pub fn fixtureOptions(doc: *const Document) Fixture {
    var f: Fixture = .{};
    for (doc.body_attrs) |a| {
        if (!eq(a.name, "style")) continue;
        var it = std.mem.splitScalar(u8, a.value, ';');
        while (it.next()) |d| {
            const c = std.mem.indexOfScalar(u8, d, ':') orelse continue;
            const k = std.mem.trim(u8, d[0..c], " \t\r\n");
            var v = std.mem.trim(u8, d[c + 1 ..], " \t\r\n");
            v = std.mem.trimEnd(u8, v, "px");
            const num = std.fmt.parseUnsigned(u32, v, 10) catch continue;
            if (eq(k, "width")) f.width = num;
            if (eq(k, "height")) f.height = num;
        }
    }
    if (doc.meta("takumi-device-pixel-ratio")) |r| f.dpr = std.fmt.parseUnsigned(u32, r, 10) catch 1;
    if (doc.meta("takumi-presets")) |r| f.chromium_presets = eq(r, "chromium");
    return f;
}

// ------------------------------------------------------------------------------------------------ tests

const testing = std.testing;

fn run(arena: *std.heap.ArenaAllocator, src: []const u8) !Document {
    return parse(arena.allocator(), src);
}

/// Serialise the tree compactly for assertions: <tag a=v>children</tag>, text as is.
fn dump(w: *std.ArrayList(u8), a: std.mem.Allocator, n: *const Node) !void {
    if (n.kind == .text) {
        try w.appendSlice(a, n.text);
        return;
    }
    try w.append(a, '<');
    try w.appendSlice(a, n.tag);
    for (n.attrs) |at| {
        try w.append(a, ' ');
        try w.appendSlice(a, at.name);
        try w.append(a, '=');
        try w.appendSlice(a, at.value);
    }
    try w.append(a, '>');
    if (eq(n.tag, "svg")) {
        try w.appendSlice(a, "{");
        try w.appendSlice(a, n.text);
        try w.appendSlice(a, "}");
    }
    for (n.children) |c| try dump(w, a, c);
    try w.appendSlice(a, "</");
    try w.appendSlice(a, n.tag);
    try w.append(a, '>');
}

fn tree(arena: *std.heap.ArenaAllocator, src: []const u8) ![]const u8 {
    const a = arena.allocator();
    const d = try parse(a, src);
    var w: std.ArrayList(u8) = .empty;
    for (d.root_children) |c| try dump(&w, a, c);
    return w.items;
}

fn expectTree(src: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(want, try tree(&arena, src));
}

test "basic structure, attributes" {
    try expectTree("<div a=1 b='2' c=\"3\" d A=dup>hi</div>", "<div a=1 b=2 c=3 d=>hi</div>");
    try expectTree("<DIV ID=x><Span>t</SPAN></div>", "<div id=x><span>t</span></div>");
    try expectTree("<a href=x/>t</a>", "<a href=x/>t</a>");
    try expectTree("<p =a>x", "<p =a=>x</p>");
    try expectTree("<div a=\"unterminated>x</div>", "<div a=unterminated>x</div>></div>");
}

test "text, stray lt, comments, doctype" {
    try expectTree("a < b <3 c", "a < b <3 c");
    try expectTree("a<!-- c -->b<!---->c<!-->d<!--->e", "abcde");
    try expectTree("<!DOCTYPE html><div>x</div>", "<div>x</div>");
    try expectTree("<?php x ?>y", "y");
    try expectTree("x</>y</ >z</3>", "xyz");
    try expectTree("<div>a\r\nb\rc</div>", "<div>a\nb\nc</div>");
}

test "merged text runs, many pieces" {
    try expectTree("<div>a<!---->b</div>c<!---->d<p>e<!---->f<!---->g</p>h", "<div>ab</div>cd<p>efg</p>h");
    try expectTree("<!DOCTYPE html><body>x<body>y<!---->z<body a=1>w", "xyzw");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = 200_000;
    const piece = "x<!---->";
    const src = try arena.allocator().alloc(u8, piece.len * n);
    for (0..n) |k| @memcpy(src[k * piece.len ..][0..piece.len], piece);
    const doc = try parse(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 1), doc.root_children.len);
    try testing.expectEqual(@as(usize, n), doc.root_children[0].text.len);
    try testing.expect(std.mem.allEqual(u8, doc.root_children[0].text, 'x'));
    // linear growth: far below the quadratic n^2/2 bytes
    try testing.expect(arena.queryCapacity() < 64 * n);

    // document mode, text split by repeated <body> tags
    _ = arena.reset(.retain_capacity);
    const piece2 = "ab<body>";
    const src2 = try arena.allocator().alloc(u8, 15 + piece2.len * n);
    @memcpy(src2[0..15], "<!DOCTYPE html>");
    for (0..n) |k| @memcpy(src2[15 + k * piece2.len ..][0..piece2.len], piece2);
    const doc2 = try parse(arena.allocator(), src2);
    try testing.expectEqual(@as(usize, 1), doc2.root_children.len);
    try testing.expectEqual(@as(usize, 2 * n), doc2.root_children[0].text.len);
}

test "many attributes: first wins, order kept, near-linear" {
    try expectTree("<div b=1 a=2 B=3 c=4 a=5>t</div>", "<div b=1 a=2 c=4>t</div>");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 60_000;
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "<!DOCTYPE html><html");
    for (0..n) |k| try src.print(a, " x{d}={d}", .{ k, k });
    try src.appendSlice(a, " X0=dup><body");
    for (0..n) |k| try src.print(a, " y{d}", .{k});
    try src.appendSlice(a, "><body y5=dup z=1><a");
    for (0..n) |k| try src.print(a, " x{d}={d}", .{ k, k });
    for (0..n) |k| try src.print(a, " X{d}=dup", .{k});
    try src.appendSlice(a, ">t</a>");
    const doc = try parse(a, src.items);
    try testing.expectEqual(@as(usize, n), doc.html_attrs.len);
    try testing.expectEqualStrings("0", doc.html_attrs[0].value);
    try testing.expectEqual(@as(usize, n + 1), doc.body_attrs.len);
    try testing.expectEqualStrings("", doc.body_attrs[5].value);
    try testing.expectEqualStrings("z", doc.body_attrs[n].name);
    const el = doc.root_children[0];
    try testing.expectEqual(@as(usize, n), el.attrs.len);
    for (el.attrs, 0..) |at, k| {
        var nb: [16]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&nb, "x{d}", .{k}), at.name);
        try testing.expectEqualStrings(try std.fmt.bufPrint(&nb, "{d}", .{k}), at.value);
    }
}

test "entities" {
    try expectTree("<p>&lt;a&gt; &amp; &#169;&#xA9; &unknown; &amp</p>", "<p><a> & \u{a9}\u{a9} &unknown; &</p>");
    try expectTree("<p>a&Tab;b&NewLine;c&nbspd&notit; &#65&#x42 &#0; &#x110000; &#128; &#xD800;</p>", "<p>a\tb\nc\u{a0}d\u{ac}it; AB \u{fffd} \u{fffd} \u{20ac} \u{fffd}</p>");
    try expectTree("<a title=\"&amp=&ampx&amp;x&amp\">", "<a title=&amp=&ampx&x&></a>");
    try expectTree("&copy;&reg;&hellip;&mdash;&euro;&rarr;&alpha;", "\u{a9}\u{ae}\u{2026}\u{2014}\u{20ac}\u{2192}\u{3b1}");
    try expectTree("&#;&#x;&", "&#;&#x;&");
}

test "entity table sanity" {
    const b = entity_data.blob;
    var i: usize = 0;
    var n: usize = 0;
    var prev: []const u8 = "";
    while (i < b.len) : (n += 1) {
        const nl: usize = b[i] & 0x7f;
        const name = b[i + 1 .. i + 1 + nl];
        const vl: usize = b[i + 1 + nl];
        try testing.expect(vl <= nl + 1);
        try testing.expect(std.mem.order(u8, prev, name) == .lt);
        prev = name;
        i += 2 + nl + vl;
    }
    try testing.expectEqual(b.len, i);
    try testing.expect(n > 300);
    try testing.expect(b.len < 4000);
}

test "raw text and rcdata" {
    try expectTree("<script>if (a < b) '</div>'</SCRIPT ><i>x</i>", "<script>if (a < b) '</div>'</script><i>x</i>");
    try expectTree("<textarea>\n&lt;b&gt;</textarea>", "<textarea><b></textarea>");
    try expectTree("<pre>\nx</pre>", "<pre>x</pre>");
    try expectTree("<title>a &amp; <b></title>", "<title>a & <b></title>");
    try expectTree("<style>a{}", "<style>a{}</style>");
    try expectTree("<div><noscript><p>x</p></noscript></div>", "<div><noscript><p>x</p></noscript></div>");
}

test "void elements, br, implied closes" {
    try expectTree("<p>a<br>b<img src=x>c</br>d</p>", "<p>a<br></br>b<img src=x></img>c<br></br>d</p>");
    try expectTree("<p>a<div>b</div><ul><li>c<li>d</ul>", "<p>a</p><div>b</div><ul><li>c</li><li>d</li></ul>");
    try expectTree("<ul><li><p>a<li>b</ul><dl><dt><p>c<dd>d</dl>", "<ul><li><p>a</p></li><li>b</li></ul><dl><dt><p>c</p></dt><dd>d</dd></dl>");
    try expectTree("<table><tr><td>a<td>b<tr><td>c</table>", "<table><tbody><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></tbody></table>");
    try expectTree("<select><option>a<option>b</select>", "<select><option>a</option><option>b</option></select>");
    try expectTree("<p>a<table></table>", "<p>a</p><table></table>");
    try expectTree("<div><span>a", "<div><span>a</span></div>");
    try expectTree("<div>a</span></div>b", "<div>a</div>b");
    try expectTree("<b><i>x</b>y</i>", "<b><i>x</i></b>y");
}

test "template, svg, html/body in fragment" {
    try expectTree("<template><img src=a></template><p>b</p>", "<template></template><p>b</p>");
    try expectTree("<html><body><div>a</div></body></html>", "<div>a</div>");
    try expectTree("<svg width=10 viewbox='0 0 1 1'><g><svg><rect/></svg></g><!-- </svg> --><text>a>b</text></svg><p>after",
        "<svg width=10 viewbox=0 0 1 1>{<svg width=10 viewbox='0 0 1 1'><g><svg><rect/></svg></g><!-- </svg> --><text>a>b</text></svg>}</svg><p>after</p>");
    try expectTree("<p>a<svg/>b</p>", "<p>a<svg>{<svg/>}</svg>b</p>");
    try expectTree("<svg><![CDATA[</svg>]]></svg>x", "<svg>{<svg><![CDATA[</svg>]]></svg>}</svg>x");
    try expectTree("<svg><title title='</svg>'>x</title>", "<svg>{<svg><title title='</svg>'>x</title>}</svg>");
}

test "document mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const d = try run(&arena,
        \\<!DOCTYPE html>
        \\<html lang=en class=h>
        \\<head><meta charset=utf-8><meta name="takumi-device-pixel-ratio" content="2" /><title>T &amp; U</title>
        \\<style>.a{color:red}</style><style media="print">b{}</style><style type="text/less">no</style></head>
        \\<body style="width: 400px; height:300px" id=b>
        \\  <div>x</div><style>.c{}</style>
        \\</body></html>
    );
    try testing.expect(d.is_document);
    try testing.expectEqualStrings("T & U", d.title);
    try testing.expectEqual(@as(usize, 3), d.styles.len);
    try testing.expectEqualStrings(".a{color:red}", d.styles[0]);
    try testing.expectEqualStrings("@media print {b{}}", d.styles[1]);
    try testing.expectEqualStrings(".c{}", d.styles[2]);
    try testing.expectEqualStrings("en", d.html_attrs[0].value);
    try testing.expectEqualStrings("b", d.body_attrs[1].value);
    try testing.expectEqualStrings("2", d.meta("takumi-device-pixel-ratio").?);
    const f = fixtureOptions(&d);
    try testing.expectEqual(@as(?u32, 400), f.width);
    try testing.expectEqual(@as(?u32, 300), f.height);
    try testing.expectEqual(@as(u32, 2), f.dpr);
    // body children: "\n  " text, div, "\n" (style kept in tree, flagged by isUnrendered)
    var n_el: usize = 0;
    for (d.root_children) |c| if (c.kind == .element) {
        n_el += 1;
    };
    try testing.expectEqual(@as(usize, 2), n_el);
    try testing.expect(isUnrendered(d.root_children[2].tag));
}

test "document mode without head/body tags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const d = try run(&arena, "<!doctype html>\n<title>t</title>\n<div>a</div>\ntail");
    try testing.expectEqual(@as(usize, 2), d.root_children.len);
    try testing.expectEqualStrings("div", d.root_children[0].tag);
    try testing.expectEqualStrings("\ntail", d.root_children[1].text);
    const e = try run(&arena, "<!doctype html>");
    try testing.expectEqual(@as(usize, 0), e.root_children.len);
    const q = try run(&arena, "<html><p>a<table></table>");
    try testing.expectEqual(@as(usize, 1), q.root_children.len); // quirks: table stays inside p
}

test "soleText / looksLikeHtml / isDocument / depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const d = try run(&arena, "<b>x<!-- c -->y</b><i> </i><u></u>");
    try testing.expectEqualStrings("xy", d.root_children[0].soleText().?);
    try testing.expect(d.root_children[1].soleText() == null);
    try testing.expect(d.root_children[2].soleText() == null);
    try testing.expect(looksLikeHtml("  <div/>"));
    try testing.expect(looksLikeHtml("hello"));
    try testing.expect(!looksLikeHtml("\n {\"type\":\"container\"}"));
    try testing.expect(isDocument(" <!-- x --> <!DocType html>"));
    try testing.expect(isDocument("<HTML>"));
    try testing.expect(!isDocument("<htmlx>"));
    try testing.expect(!isDocument("<div>"));
    var deep: std.ArrayList(u8) = .empty;
    for (0..600) |_| try deep.appendSlice(arena.allocator(), "<div>");
    try testing.expectError(error.TooDeep, parse(arena.allocator(), deep.items));
    deep.clearRetainingCapacity();
    for (0..500) |_| try deep.appendSlice(arena.allocator(), "<div>");
    _ = try parse(arena.allocator(), deep.items);
}

test "presets" {
    const h1 = preset("h1");
    try testing.expectEqualStrings("font-size", h1[0].name);
    try testing.expectEqualStrings("2em", h1[0].value);
    try testing.expectEqualStrings("display", h1[h1.len - 1].name);
    try testing.expectEqualStrings("block", preset("div")[0].value);
    try testing.expectEqualStrings("1em 0", preset("pre")[2].value);
    try testing.expectEqual(@as(usize, 0), preset("span").len);
    try testing.expectEqualStrings("display:block", presetCss("div"));
    try testing.expect(std.mem.indexOf(u8, presetCss("pre"), ";margin:1em 0;") != null);
    try testing.expectEqualStrings("", presetCss("span"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const d = try run(&arena, "<input type=search disabled><input type=checkbox><textarea wrap=off></textarea><input type=hidden>");
    var out: [3][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 3), formControlPresets(d.root_children[0], false, &out));
    try testing.expectEqual(@as(usize, 0), formControlPresets(d.root_children[1], false, &out));
    try testing.expectEqual(@as(usize, 2), formControlPresets(d.root_children[2], false, &out));
    try testing.expectEqual(@as(usize, 1), formControlPresets(d.root_children[3], false, &out));
}

test "fuzz: mutated input never crashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const seeds = [_][]const u8{
        "<!DOCTYPE html><html><head><style>a{}</style></head><body style='width:1px'><div class=a><p>x<b>y</p><svg viewBox='0 0 1 1'><g/></svg>&amp;&#x41;<table><tr><td>1</table></div></body></html>",
        "<ul><li>a<li>b<script>x</script><textarea>&lt;</textarea><template><i>t</i></template></ul><!-- c -->",
    };
    var prng = std.Random.DefaultPrng.init(12345);
    const rnd = prng.random();
    const alphabet = "<>/!-?\"'=&#; \n\rabpdivsvgtable";
    var buf: [400]u8 = undefined;
    for (0..4000) |_| {
        const s = seeds[rnd.uintLessThan(usize, seeds.len)];
        @memcpy(buf[0..s.len], s);
        var len = s.len;
        for (0..rnd.uintLessThan(usize, 12)) |_| {
            const at = rnd.uintLessThan(usize, len);
            switch (rnd.uintLessThan(u8, 3)) {
                0 => buf[at] = alphabet[rnd.uintLessThan(usize, alphabet.len)],
                1 => {
                    len = at + 1;
                },
                else => buf[at] = rnd.int(u8),
            }
        }
        _ = arena.reset(.retain_capacity);
        _ = parse(arena.allocator(), buf[0..len]) catch {};
    }
}

test "real takumi fixtures (testdata)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const files = .{
        .{ @embedFile("testdata/style_background_color.html"), 1200, 630 },
        .{ @embedFile("testdata/text_basic.html"), 1200, 630 },
        .{ @embedFile("testdata/text_align.html"), 600, 256 },
        .{ @embedFile("testdata/style_position.html"), 400, 200 },
        .{ @embedFile("testdata/showcase_grid_hero.html"), 1200, 630 },
        .{ @embedFile("testdata/image_svg_text.html"), 1200, 630 },
        .{ @embedFile("testdata/table_baseline.html"), 480, 260 },
        .{ @embedFile("testdata/font_language_override.html"), 560, 420 },
        .{ @embedFile("testdata/svg_color_filters.html"), 480, 140 },
    };
    inline for (files) |f| {
        const d = try parse(arena.allocator(), f[0]);
        try testing.expect(d.is_document);
        const o = fixtureOptions(&d);
        try testing.expectEqual(@as(?u32, f[1]), o.width);
        try testing.expectEqual(@as(?u32, f[2]), o.height);
        try testing.expect(d.title.len > 0);
        try testing.expect(d.styles.len >= 0);
        var elements: usize = 0;
        for (d.root_children) |c| elements += @intFromBool(c.kind == .element);
        try testing.expect(elements >= 1);
    }
    // an inline svg inside a fixture is kept as one node with its exact source
    const d = try parse(arena.allocator(), @embedFile("testdata/svg_color_filters.html"));
    var found = false;
    var stack: std.ArrayList(*const Node) = .empty;
    for (d.root_children) |c| try stack.append(arena.allocator(), c);
    while (stack.pop()) |n| {
        if (n.kind != .element) continue;
        if (eq(n.tag, "svg")) {
            found = true;
            try testing.expect(std.mem.startsWith(u8, n.text, "<svg"));
            try testing.expect(std.mem.endsWith(u8, n.text, "</svg>"));
            try testing.expectEqual(@as(usize, 0), n.children.len);
        }
        for (n.children) |c| try stack.append(arena.allocator(), c);
    }
    try testing.expect(found);
}
