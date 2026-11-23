//! CSS tables (CSS 2.1 §17 / css-tables-3) after Blink's LayoutNG table algorithm, as ported by takumi
//! (`ref/takumi/takumi-core/src/layout/table`): automatic and fixed column sizing, colspan / rowspan
//! distribution, `border-spacing`, `border-collapse` (conflicts resolved by width only: `Style` has no border
//! styles), row / section / table heights, cell `vertical-align`, captions, header / footer groups,
//! `visibility: collapse` rows and columns.
//!
//! The table box tree is VIRTUAL: missing row groups, rows and cells are never materialised as nodes.
//!  * children of a table that are not captions / columns / row groups form anonymous row groups (one per run)
//!  * children of a row group that are not rows form anonymous rows (one per run)
//!  * children of a row that are not cells form ONE anonymous cell per run; its nodes are laid out as the
//!    block-level children of that cell (a block formatting context root; no floats inside it)
//!  * a row group / row reached directly (its parent is not a table) is an anonymous table around that one
//!    node; the node's `Layout` is then the box of that anonymous table.
//! Row groups, rows and cells get their `Layout` here (relative to their parent NODE); real cells are laid
//! out as block containers (`block.zig`) at the size the grid gives them, their children shifted afterwards
//! for `vertical-align`.
//!
//! Sizing protocol notes (see `compute`):
//!  * `width` / `height` of a table are minimums (it is never narrower than its min-content width, its
//!    columns decide the final width, content and captions add to the height), so a `known` size that a
//!    parent derived from the table's own styles is not taken: a table under a block container, the root and
//!    an absolutely positioned table size themselves (shrink-to-fit in `in.parent[0]`)
//!  * the main size of a flex item is taken as fixed; a cross size / grid area is a stretch (a lower bound)
//!  * a row / row group that is a flex or grid item is blockified (laid out by block.zig)
//!  * rows and row groups are not computed through `computeNode`; `Tree.depth` is advanced for them
//!  * a `border-collapse: collapse` table and its cells are laid out with their USED borders (half of the
//!    winning collapsed edge on each side; the table has no padding): the cells' `Layout.border` and, through
//!    `Node.table_box`, the table's `Layout.border` / `.padding` report them. While a cell is computed its
//!    `style.border` temporarily holds the used widths.
//!  * the table's `Layout` covers its captions too; border and padding belong to the grid box between them
//!  * `direction: rtl` on the table (the parent, for an anonymous table) runs the columns right to left: the grid
//!    is built in logical order, cell positions and the left / right borders are converted (`S.rtl`)
//!  * not done here: `position: relative` offsets of rows / cells, `empty-cells`, floats
//!    inside anonymous cells, a static-position absolute child of a cell is not moved by `vertical-align`.
const std = @import("std");
const st = @import("style.zig");
const tr = @import("tree.zig");
const block = @import("block.zig");

const In = tr.In;
const Out = tr.Out;
const Box = tr.Box;
const Error = tr.Error;
const MarginSet = tr.MarginSet;
const NONE = tr.NONE;
const MAXC = tr.MAXC;
const MINC = tr.MINC;
const has = tr.has;
const orElse = tr.orElse;
const clampO = tr.clampO;
const maxO = tr.maxO;
const no_node = tr.no_node;

/// Blink's kMaxColSpan / kMaxRowSpan.
const max_colspan: u32 = 1000;
const max_rowspan: u32 = 65534;
/// Blink's TableTypes::kTableMaxInlineSize.
const table_max_inline: f32 = 1_000_000;
/// Collapsed-border edge grids larger than this many edges degrade to one width per grid line.
const max_edges: usize = 1 << 20;

// ---------------------------------------------------------------------------------------------------------
// LayoutUnit arithmetic (q = quantize64 mode)

inline fn lu(q: bool, v: anytype) @TypeOf(v) {
    return if (q) @trunc(v * 64) / 64 else v;
}
fn divI(q: bool, v: anytype, k: @TypeOf(v)) @TypeOf(v) {
    return if (q) @trunc(@trunc(v * 64) / k) / 64 else v / k;
}
/// LayoutUnit::ToFloat
inline fn ff(v: f64) f32 {
    return @floatCast(v);
}
/// LayoutUnit::FromFloat
inline fn luf(q: bool, v: f32) f64 {
    return lu(q, v);
}
inline fn hasW(v: f64) bool {
    return v == v;
}
/// LayoutUnit::MulDiv: a * b / d in wide integers, truncated.
fn mulDiv(q: bool, a: anytype, b: @TypeOf(a), d: @TypeOf(a)) @TypeOf(a) {
    if (d == 0) return 0;
    if (!q) return a * b / d;
    const n = @as(f64, @trunc(a * 64)) * @as(f64, @trunc(b * 64));
    return @floatCast(@trunc(n / @as(f64, @trunc(d * 64))) / 64);
}
/// Option<f32> ordering with NaN = None (None < Some).
inline fn gtOpt(a: f32, b: f32) bool {
    return has(a) and (!has(b) or a > b);
}

/// A sizing property as Blink's Length kinds: fixed px, percent (100% = 100), or neither.
const TL = struct { fixed: f32 = NONE, pct: f32 = NONE };
/// LayoutUnit::Max() is 2^25 px; lengths taken from styles are held to it
const max_len: f32 = 33554432;
fn tableLen(q: bool, d: st.Dim) TL {
    switch (d) {
        // (untrusted values: lengths are held to Blink's LayoutUnit range, percentages to a sane one)
        .px => |v| if (std.math.isFinite(v)) return .{ .fixed = lu(q, std.math.clamp(v, 0, max_len)) },
        .percent => |p| if (std.math.isFinite(p)) return .{ .pct = std.math.clamp(p, 0, 1e4) * 100 },
        .calc => |k| if (std.math.isFinite(k.px) and std.math.isFinite(k.percent)) {
            if (k.percent == 0) return .{ .fixed = lu(q, std.math.clamp(k.px, 0, max_len)) };
            if (k.px == 0) return .{ .pct = std.math.clamp(k.percent, 0, 1e4) * 100 };
        },
        else => {},
    }
    return .{};
}

// ---------------------------------------------------------------------------------------------------------
// data

const Sec = struct {
    /// row group node; no_node = anonymous
    node: u32,
    start: u32,
    n_rows: u32,
    tbody: bool,
    h: f32 = 0,
    pct: f32 = NONE,
    constrained: bool = false,
    redist: bool = false,
    /// block offset in the table box, final block size
    y: f32 = 0,
    hf: f32 = 0,
};

const Row = struct {
    /// row node; no_node = anonymous
    node: u32,
    first: u32,
    n: u32,
    h: f32 = 0,
    /// baseline the cells align to (NaN until known), baseline of the laid out row
    bl: f32 = NONE,
    fbl: f32 = 0,
    pct: f32 = NONE,
    constrained: bool = false,
    span_start: bool = false,
    collapsed: bool = false,
    cls: u8 = 0,
    /// block offset in its section
    y: f32 = 0,
};

const Cell = struct {
    /// the cell node; for an anonymous cell the first node of its run
    node: u32,
    /// anonymous cell: last node of the run
    last: u32,
    anon: bool,
    col: u32 = 0,
    colspan: u32 = 1,
    /// rowspan as specified (clamped), and held to the rows left in the section
    rowspan: u32 = 1,
    eff: u32 = 1,
    /// used border: left, top, right, bottom
    border: [4]f32 = .{ 0, 0, 0, 0 },
    /// (collapsing table) the node's own style while it is laid out with `S.used_style`
    orig: *const st.Style = undefined,
    valign: st.VerticalAlign = .baseline,
    has_content: bool = true,
    pct_dep: bool = false,
    constrained: bool = false,
    /// measured block size at the column width; intrinsic block size in the final pass
    mh: f32 = 0,
    ih: f32 = 0,
    /// final pass: first baseline before alignment, bottom border + padding, geometry, content extent
    fbl: f32 = NONE,
    bend: f32 = 0,
    x: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    cont: [2]f32 = .{ 0, 0 },
};

/// Blink's TableTypes::Column plus its location ([0] = all columns, [1] = collapsed columns removed).
const Col = struct {
    min: f64 = NONE,
    max: f64 = NONE,
    pct: f32 = NONE,
    pbp: f64 = 0,
    constrained: bool = false,
    collapsed: bool = false,
    mergeable: bool = false,
    size: f64 = 0,
    off: [2]f32 = .{ 0, 0 },
    w: [2]f32 = .{ 0, 0 },

    inline fn mn(c: *const Col) f64 {
        return if (hasW(c.min)) c.min else 0;
    }
    inline fn mx(c: *const Col) f64 {
        return if (hasW(c.max)) c.max else 0;
    }
    fn isFixed(c: *const Col) bool {
        return c.constrained and !has(c.pct) and hasW(c.max);
    }
    fn resolvePct(c: *const Col, q: bool, basis: f64) f64 {
        return @max(c.mn(), luf(q, orElse(c.pct, 0) * ff(basis) / 100) + c.pbp);
    }
};

/// Blink's CellInlineConstraint (also used for a colspan cell with start/span).
const CellC = struct {
    present: bool = false,
    min: f64 = 0,
    max: f64 = 0,
    pct: f32 = NONE,
    pbp: f64 = 0,
    constrained: bool = false,
    start: u32 = 0,
    span: u32 = 1,
};

const RowSpan = struct { start: u32, span: u32, min: f32 };
const Span = struct { start: u32, end: u32, left: u32 };

/// Blink's RowBaselineTabulator.
const Tab = struct {
    asc: f32 = NONE,
    desc: f32 = NONE,
    fb: f32 = NONE,
    dep_max: bool = false,
    dep_fb: bool = false,

    fn process(s: *Tab, h: f32, bl: f32, bend: f32, is_bl: bool, content: bool, spanned: bool, dep: bool) void {
        if (is_bl and content and has(bl)) {
            s.dep_max = s.dep_max or dep;
            s.asc = if (has(s.asc)) @max(s.asc, bl) else bl;
            s.desc = if (spanned) orElse(s.desc, 0) else if (has(s.desc)) @max(s.desc, h - bl) else h - bl;
        }
        // without a line box the baseline is the bottom of the cell's content edge
        if (!has(s.asc)) {
            s.dep_fb = s.dep_fb or dep;
            s.fb = if (has(s.fb)) @min(s.fb, bend) else bend;
        }
    }
    fn rowBlockSize(s: *const Tab, m: f32) f32 {
        return if (has(s.asc) and has(s.desc)) @max(m, s.asc + s.desc) else m;
    }
    fn baseline(s: *const Tab, h: f32) f32 {
        if (has(s.asc)) return s.asc;
        if (has(s.fb)) return @max(h - s.fb, 0);
        return 0;
    }
    fn depends(s: *const Tab) bool {
        return if (has(s.asc)) s.dep_max else has(s.fb) and s.dep_fb;
    }
};

/// Per-table state kept in the tree's scratch arena (see `Tree.computeNode` on stack discipline).
const S = struct {
    in: In,
    box: Box,
    /// box of the child being placed
    cb: Box,
    ci: In,
    co: Out,
    active: MarginSet,
    area: [4]f32,
    sp: tr.StaticPos,
    content: [2]f32,
    cic: CellC,
    isz: [4]f32,
    tab: Tab,

    node: u32,
    q: bool,
    is_table: bool,
    fixed: bool,
    collapse: bool,
    /// (collapsing table) the style of the cell being laid out, with its used border
    used_style: st.Style = undefined,
    did_layout: bool,
    has_collapsed: bool,
    dry: bool,
    grid_ok: bool,
    spacing: [2]f32,

    secs: []Sec,
    rows: []Row,
    cells: []Cell,
    cols: []Col,
    cc: []CellC,
    cs: []CellC,
    rs: []RowSpan,
    idx: []u32,
    spans: []Span,
    sizes: []f64,
    edges: []f32,

    n_secs: u32,
    n_rows: u32,
    n_cells: u32,
    n_caps: u32,
    n_colnodes: u32,
    n_cols: u32,
    n_cellcols: u32,
    n_cs: u32,
    n_spancells: u32,
    n_rowspans: u32,
    n_rs: u32,
    col_cap: u32,
    /// collapsed-border grid: columns, edges per row, rows of edges
    bc: u32,
    epr: usize,
    erows: usize,

    tbl_w: f32,
    grid_w: f32,
    sec_w: f32,
    sec_x: f32,
    /// `direction: rtl` on the table: the columns run right to left (the grid is built in logical order;
    /// cell positions and the left / right borders are converted)
    rtl: bool,
    cap_min: f32,
    top_h: f32,
    bot_h: f32,
    bottom_y: f32,
    block_size: f32,
    min_grid_h: f32,
    an_h: f32,
    an_bl: f32,
};

/// Scratch array of `n` items (one out-of-line allocation path for every element type).
inline fn arr(t: anytype, comptime T: type, n: usize) Error![]T {
    const p = try scratchBytes(t, n *| @sizeOf(T));
    return @as([*]T, @ptrCast(@alignCast(p)))[0..n];
}
noinline fn scratchBytes(t: anytype, bytes: usize) Error![*]align(16) u8 {
    const s = try t.scratch.alloc(t.alloc, u128, bytes / 16 + 1);
    return @ptrCast(s.ptr);
}
/// The block sizes a stretched table broken over pages shared among its rows (fragment.zig
/// `TableStretch`); null: none beyond the one it is laid out at.
fn stretchOf(t: anytype, node: u32) ?[]const @import("fragment.zig").StretchSeg {
    if (comptime !@import("style.zig").frag_enabled) return null;
    for (t.paged.table_stretches) |ts| if (ts.node == node and ts.segs.len > 1) return ts.segs;
    return null;
}
inline fn styleOf(t: anytype, n: u32) *const st.Style {
    return t.nodes.items[n].style;
}
fn isTableAlgo(d: st.Display) bool {
    return switch (d) {
        .table, .inline_table, .table_row, .table_row_group, .table_header_group, .table_footer_group => true,
        else => false,
    };
}
fn isSection(d: st.Display) bool {
    return d == .table_row_group or d == .table_header_group or d == .table_footer_group;
}
inline fn skipped(s: *const st.Style) bool {
    return s.display == .none or s.position.isOut();
}
fn zeroBox(b: *Box) void {
    b.* = .{
        .padding = .{ 0, 0, 0, 0 },
        .border = .{ 0, 0, 0, 0 },
        .margin = .{ 0, 0, 0, 0 },
        .margin_auto = .{ false, false, false, false },
        .pb = .{ 0, 0 },
        .size = .{ NONE, NONE },
        .min = .{ NONE, NONE },
        .max = .{ NONE, NONE },
    };
}
fn setBorder(b: *Box, border: [4]f32) void {
    b.border = border;
    b.pb = .{ b.padding[0] + b.padding[2] + border[0] + border[2], b.padding[1] + b.padding[3] + border[1] + border[3] };
}

// ---------------------------------------------------------------------------------------------------------
// paint geometry (what a painter needs of a laid-out table: Blink's table fragment data)

/// A column of the grid: inline-start edge relative to the sections' inline start, inline size (0 for a
/// collapsed / merged column).
pub const GeomCol = struct { x: f32, w: f32, collapsed: bool };
/// A `<col>` / `<colgroup>` node and the columns it covers, in tree order (a group before its columns).
pub const GeomColEl = struct { node: u32, start: u32, span: u32, group: bool };
/// A row group. `node` = `no_node` for an anonymous one (when the laid-out node is itself a row group, that
/// node). `y` is its block offset in the table node's border box, `h` its block size.
pub const GeomSec = struct { node: u32, start: u32, n_rows: u32, y: f32, h: f32 };
/// A row of section `sec`, holding `cells[first..first + n]`. `node` = `no_node` for an anonymous one. `y` is
/// relative to its section.
pub const GeomRow = struct { node: u32, sec: u32, first: u32, n: u32, y: f32, h: f32, collapsed: bool };
/// A cell: `node` is the cell node (for an anonymous cell the first node of its run, `anon` set); grid position
/// (`row` = table row index, `rowspan` / `colspan` held to the section / grid); border box in the table node's
/// border-box coordinates. `hidden`: its row is collapsed or every column it spans is.
pub const GeomCell = struct { node: u32, row: u32, col: u32, rowspan: u32, colspan: u32, x: f32, y: f32, w: f32, h: f32, anon: bool, has_content: bool, hidden: bool };
/// Geometry of one laid-out table (or of the anonymous table around a row / row group node), recorded by
/// the final layout pass; see `Tree.tableGeom`. All slices live in the tree's allocator.
pub const Geom = struct {
    /// the table node (a row / row-group node for an anonymous table)
    node: u32 = no_node,
    is_table: bool = false,
    /// `border-collapse: collapse` with a resolved edge grid (`Layout.border` of the cells are half edges)
    collapse: bool = false,
    /// columns of the collapsed-border grid (Blink's table_column_count); 0 unless `collapse`
    n_bcols: u32 = 0,
    /// the table box (everything but the captions) in the node's border box: block offset and size
    grid_y: f32 = 0,
    grid_h: f32 = 0,
    /// inline offset of the sections in the node's border box, their inline size
    sec_x: f32 = 0,
    /// right-to-left table: `cols[k].x` is measured from the RIGHT edge of the sections (cells are physical)
    rtl: bool = false,
    sec_w: f32 = 0,
    cols: []GeomCol = &.{},
    colels: []GeomColEl = &.{},
    secs: []GeomSec = &.{},
    rows: []GeomRow = &.{},
    cells: []GeomCell = &.{},
};

fn geomSlice(t: anytype, comptime T: type, old: []T, n: usize) Error![]T {
    if (old.len == n) return old;
    const new = t.alloc.alloc(T, n) catch return error.OutOfMemory;
    t.alloc.free(old);
    return new;
}

/// Records the `Geom` of the table just laid out (final pass). A repeated final layout of the same node
/// reuses its record.
noinline fn recordGeom(t: anytype, c: *S) Error!void {
    const node = c.node;
    var gi = t.nodes.items[node].table_geom;
    if (gi >= t.table_geoms.items.len or t.table_geoms.items[gi].node != node) {
        gi = @intCast(t.table_geoms.items.len);
        t.table_geoms.append(t.alloc, .{}) catch return error.OutOfMemory;
        t.nodes.items[node].table_geom = gi;
    }
    const g = &t.table_geoms.items[gi];
    g.node = node;
    g.is_table = c.is_table;
    g.collapse = c.collapse and c.grid_ok;
    g.n_bcols = if (g.collapse) c.bc else 0;
    g.grid_y = c.top_h;
    g.grid_h = c.bottom_y - c.top_h;
    g.sec_x = c.sec_x;
    g.rtl = c.rtl;
    g.sec_w = c.sec_w;
    g.cols = try geomSlice(t, GeomCol, g.cols, c.n_cols);
    for (g.cols, c.cols[0..c.n_cols]) |*o, *col| o.* = .{ .x = col.off[1] - c.spacing[0], .w = col.w[1], .collapsed = col.collapsed };
    g.secs = try geomSlice(t, GeomSec, g.secs, c.n_secs);
    for (g.secs, c.secs[0..c.n_secs]) |*o, *sec| o.* = .{ .node = sec.node, .start = sec.start, .n_rows = sec.n_rows, .y = sec.y, .h = sec.hf };
    g.rows = try geomSlice(t, GeomRow, g.rows, c.n_rows);
    g.cells = try geomSlice(t, GeomCell, g.cells, c.n_cells);
    for (c.secs[0..c.n_secs], 0..) |*sec, si| {
        for (0..sec.n_rows) |k| {
            const ri = sec.start + k;
            const row = &c.rows[ri];
            g.rows[ri] = .{ .node = row.node, .sec = @intCast(si), .first = row.first, .n = row.n, .y = row.y, .h = row.h, .collapsed = row.collapsed };
            for (row.first..row.first + row.n) |i| {
                const cell = &c.cells[i];
                var hidden = row.collapsed;
                if (!hidden and c.n_cols > 0) {
                    // Blink's is_hidden_due_to_layout: every column the cell spans is collapsed
                    const last = c.n_cols - 1;
                    var k2 = @min(cell.col, last);
                    const end = @min(cell.col +| (cell.colspan -| 1), last);
                    hidden = true;
                    while (k2 <= end) : (k2 += 1) {
                        if (!c.cols[k2].collapsed) {
                            hidden = false;
                            break;
                        }
                    }
                }
                g.cells[i] = .{
                    .node = cell.node,
                    .row = @intCast(ri),
                    .col = cell.col,
                    .rowspan = cell.eff,
                    .colspan = cell.colspan,
                    .x = c.sec_x + cell.x,
                    .y = sec.y + row.y,
                    .w = cell.w,
                    .h = cell.h,
                    .anon = cell.anon,
                    .has_content = cell.has_content,
                    .hidden = hidden,
                };
            }
        }
    }
    // <col> / <colgroup> elements (the walk of `visitCols`)
    var n_el: usize = 0;
    for (0..2) |pass| {
        if (pass == 1) g.colels = try geomSlice(t, GeomColEl, g.colels, n_el);
        n_el = 0;
        if (!c.is_table or c.n_cols == 0) continue;
        const limit = c.n_cols;
        var cur: u32 = 0;
        var ch = t.firstChild(node);
        while (ch != no_node and cur < limit) : (ch = t.nextSibling(ch)) {
            const s = styleOf(t, ch);
            if (s.position.isOut()) continue;
            if (s.display == .table_column) {
                const span = @min(colSpanOf(s), limit - cur);
                if (pass == 1) g.colels[n_el] = .{ .node = ch, .start = cur, .span = span, .group = false };
                n_el += 1;
                cur += span;
                continue;
            }
            if (s.display != .table_column_group) continue;
            const start = cur;
            const slot = n_el;
            n_el += 1;
            var any = false;
            var total: u32 = 0;
            var k = t.firstChild(ch);
            while (k != no_node) : (k = t.nextSibling(k)) {
                const ks = styleOf(t, k);
                if (ks.display != .table_column) continue;
                any = true;
                const span = @min(colSpanOf(ks), limit - cur);
                if (pass == 1) g.colels[n_el] = .{ .node = k, .start = cur, .span = span, .group = false };
                n_el += 1;
                cur += span;
                total += span;
                if (cur >= limit) break;
            }
            if (!any) {
                total = @min(colSpanOf(s), limit - cur);
                cur += total;
            }
            if (pass == 1) g.colels[slot] = .{ .node = ch, .start = start, .span = total, .group = true };
        }
    }
}

// ---------------------------------------------------------------------------------------------------------
// structure (virtual anonymous boxes)

const G = struct { fill: bool, anon_row: bool = false, anon_cell: bool = false };

fn openSec(c: *S, g: *G, node: u32, tbody: bool) void {
    if (g.fill) c.secs[c.n_secs] = .{ .node = node, .start = c.n_rows, .n_rows = 0, .tbody = tbody };
    c.n_secs += 1;
    g.anon_row = false;
}
fn openRow(c: *S, g: *G, node: u32) void {
    if (g.fill) {
        c.rows[c.n_rows] = .{ .node = node, .first = c.n_cells, .n = 0 };
        c.secs[c.n_secs - 1].n_rows += 1;
    }
    c.n_rows += 1;
    g.anon_cell = false;
}
fn rowChild(t: anytype, c: *S, g: *G, ch: u32) void {
    const s = styleOf(t, ch);
    if (s.display == .table_cell) {
        g.anon_cell = false;
    } else if (g.anon_cell) {
        if (g.fill) {
            c.cells[c.n_cells - 1].last = ch;
            c.cells[c.n_cells - 1].pct_dep = c.cells[c.n_cells - 1].pct_dep or pctDep(s);
        }
        return;
    } else g.anon_cell = true;
    if (g.fill) {
        const cell = &c.cells[c.n_cells];
        cell.* = .{ .node = ch, .last = ch, .anon = g.anon_cell };
        if (g.anon_cell) {
            cell.pct_dep = pctDep(s);
        } else {
            const n = &t.nodes.items[ch];
            cell.colspan = std.math.clamp(@as(u32, s.col_span), 1, max_colspan);
            cell.rowspan = if (s.row_span == 0) max_rowspan else @min(@as(u32, s.row_span), max_rowspan);
            cell.valign = s.vertical_align;
            cell.has_content = n.measured;
            var k = n.first_child;
            while (k != no_node) : (k = t.nextSibling(k)) {
                const ks = styleOf(t, k);
                if (skipped(ks)) continue;
                cell.has_content = true;
                cell.pct_dep = cell.pct_dep or pctDep(ks);
            }
        }
        c.rows[c.n_rows - 1].n += 1;
    }
    c.n_cells += 1;
}
/// Blink's DependsOnPercentageBlockSize for a child of a cell.
fn pctDep(s: *const st.Style) bool {
    return s.size[1].hasPercent() or s.min_size[1].hasPercent() or s.max_size[1].hasPercent() or
        (s.position == .relative and (s.inset.top.hasPercent() or s.inset.bottom.hasPercent()));
}
fn walkRow(t: anytype, c: *S, g: *G, row: u32) void {
    var ch = t.firstChild(row);
    while (ch != no_node) : (ch = t.nextSibling(ch)) {
        if (!skipped(styleOf(t, ch))) rowChild(t, c, g, ch);
    }
}
fn secChild(t: anytype, c: *S, g: *G, ch: u32) void {
    if (styleOf(t, ch).display == .table_row) {
        g.anon_row = false;
        openRow(c, g, ch);
        walkRow(t, c, g, ch);
    } else {
        if (!g.anon_row) {
            openRow(c, g, no_node);
            g.anon_row = true;
        }
        rowChild(t, c, g, ch);
    }
}
fn walkSec(t: anytype, c: *S, g: *G, sec: u32) void {
    var ch = t.firstChild(sec);
    while (ch != no_node) : (ch = t.nextSibling(ch)) {
        if (!skipped(styleOf(t, ch))) secChild(t, c, g, ch);
    }
}

/// Counts (fill = false) or records the sections, rows and cells in layout order: header group, bodies, footer.
fn gather(t: anytype, c: *S, fill: bool) void {
    var g: G = .{ .fill = fill };
    c.n_secs = 0;
    c.n_rows = 0;
    c.n_cells = 0;
    c.n_caps = 0;
    c.n_colnodes = 0;
    const node = c.node;
    const d = styleOf(t, node).display;
    if (d == .table_row) {
        openSec(c, &g, no_node, true);
        openRow(c, &g, node);
        walkRow(t, c, &g, node);
        return;
    }
    if (!d.isTable()) {
        openSec(c, &g, node, d == .table_row_group);
        walkSec(t, c, &g, node);
        return;
    }
    var hdr: u32 = no_node;
    var ftr: u32 = no_node;
    var ch = t.firstChild(node);
    while (ch != no_node) : (ch = t.nextSibling(ch)) {
        const s = styleOf(t, ch);
        if (skipped(s)) continue;
        switch (s.display) {
            .table_header_group => if (hdr == no_node) {
                hdr = ch;
            },
            .table_footer_group => if (ftr == no_node) {
                ftr = ch;
            },
            .table_caption => c.n_caps += 1,
            .table_column => c.n_colnodes += 1,
            .table_column_group => c.n_colnodes += 1 + t.nodes.items[ch].child_count,
            else => {},
        }
    }
    for (0..3) |pass| {
        var in_run = false;
        ch = t.firstChild(node);
        while (ch != no_node) : (ch = t.nextSibling(ch)) {
            const s = styleOf(t, ch);
            if (skipped(s)) continue;
            switch (s.display) {
                .table_caption, .table_column, .table_column_group => in_run = false,
                .table_row_group, .table_header_group, .table_footer_group => {
                    in_run = false;
                    const which: usize = if (ch == hdr) 0 else if (ch == ftr) 2 else 1;
                    if (which == pass) {
                        openSec(c, &g, ch, which == 1);
                        walkSec(t, c, &g, ch);
                    }
                },
                else => if (pass == 1) {
                    if (!in_run) {
                        openSec(c, &g, no_node, true);
                        in_run = true;
                    }
                    secChild(t, c, &g, ch);
                },
            }
        }
    }
}

/// Blink's ColspanCellTabulator: the column of every cell, past the cells that rows above still span.
noinline fn assignColumns(c: *S) void {
    const cap = c.col_cap;
    const half = c.spans.len / 2;
    c.n_cellcols = 0;
    c.n_spancells = 0;
    c.n_rowspans = 0;
    for (c.secs[0..c.n_secs]) |*sec| {
        var n_sp: usize = 0;
        for (0..sec.n_rows) |k| {
            const row = &c.rows[sec.start + k];
            const old = n_sp;
            var cur: u32 = 0;
            var p: usize = 0;
            const rows_left: u32 = sec.n_rows - @as(u32, @intCast(k));
            for (c.cells[row.first .. row.first + row.n]) |*cell| {
                while (p < old and c.spans[p].start <= cur) : (p += 1) {
                    if (c.spans[p].end > cur) cur = c.spans[p].end;
                }
                const raw = cell.colspan;
                cell.col = @min(cur, cap - 1);
                cell.colspan = @min(raw, cap - cell.col);
                cell.eff = @max(@min(cell.rowspan, rows_left), 1);
                if (cell.rowspan > 1 and n_sp < half) {
                    c.spans[n_sp] = .{ .start = cur, .end = cur +| raw, .left = cell.rowspan };
                    n_sp += 1;
                }
                cur +|= raw;
                c.n_cellcols = @max(c.n_cellcols, if (c.fixed) cell.col + cell.colspan else cell.col + 1);
                if (cell.colspan > 1) c.n_spancells += 1;
                if (cell.eff > 1) c.n_rowspans += 1;
            }
            // end of row: drop the spans that are done, keep the rest ordered by their first column
            var a: usize = 0;
            for (c.spans[0..old]) |sp| {
                if (sp.left > 1) {
                    c.spans[a] = .{ .start = sp.start, .end = sp.end, .left = sp.left - 1 };
                    a += 1;
                }
            }
            var b: usize = 0;
            for (c.spans[old..n_sp]) |sp| {
                if (sp.left > 1) {
                    c.spans[half + b] = .{ .start = sp.start, .end = sp.end, .left = sp.left - 1 };
                    b += 1;
                }
            }
            // merge the new ones (ordered) into the old ones (ordered), from the back
            var i = a;
            var j = b;
            n_sp = a + b;
            var o = n_sp;
            while (j > 0) {
                o -= 1;
                if (i > 0 and c.spans[i - 1].start > c.spans[half + j - 1].start) {
                    i -= 1;
                    c.spans[o] = c.spans[i];
                } else {
                    j -= 1;
                    c.spans[o] = c.spans[half + j];
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------
// <col> / <colgroup>

fn colSpanOf(s: *const st.Style) u32 {
    return std.math.clamp(@as(u32, s.col_span), 1, max_colspan);
}

/// Blink's TableTypes::CreateColumn.
fn colOf(q: bool, s: *const st.Style, default: f32, fixed: bool) Col {
    const w = tableLen(q, s.size[0]);
    const mnl = tableLen(q, s.min_size[0]).fixed;
    const mxl = tableLen(q, s.max_size[0]);
    var size = orElse(w.fixed, default);
    if (has(mnl) and has(size)) size = @max(size, mnl);
    var pct = w.pct;
    if (has(pct) and has(mxl.pct)) pct = @min(pct, mxl.pct);
    if (pct == 0) pct = NONE;
    return .{
        .min = orElse(mnl, 0),
        .max = @as(f64, size),
        .pct = pct,
        .constrained = has(size),
        .collapsed = s.visibility_collapse,
        .mergeable = !fixed and orElse(size, 0) == 0 and orElse(pct, 0) == 0,
    };
}

/// Walks the table's columns and column groups (Blink's VisitLayoutTableColumn) up to `limit` columns.
/// mode 0: count; 1: record the column constraints; 2: merge column borders; 3: merge column group borders.
fn visitCols(t: anytype, c: *S, limit: u32, mode: u2) u32 {
    if (!c.is_table) return 0;
    var cur: u32 = 0;
    var ch = t.firstChild(c.node);
    while (ch != no_node and cur < limit) : (ch = t.nextSibling(ch)) {
        const s = styleOf(t, ch);
        if (s.position.isOut()) continue;
        if (s.display == .table_column) {
            const span = @min(colSpanOf(s), limit - cur);
            colVisit(c, mode, s, NONE, cur, span);
            cur += span;
            continue;
        }
        if (s.display != .table_column_group) continue;
        const start = cur;
        var any = false;
        var total: u32 = 0;
        const group = colOf(c.q, s, NONE, c.fixed);
        var k = t.firstChild(ch);
        while (k != no_node) : (k = t.nextSibling(k)) {
            const ks = styleOf(t, k);
            if (ks.display != .table_column) continue;
            any = true;
            const span = @min(colSpanOf(ks), limit - cur);
            colVisit(c, mode, ks, if (c.fixed) NONE else ff(group.max), cur, span);
            cur += span;
            total += span;
            if (cur >= limit) break;
        }
        if (!any) {
            total = @min(colSpanOf(s), limit - cur);
            if (mode == 1) {
                for (cur..cur + total) |i| c.cols[i] = group;
            }
            cur += total;
        }
        if (mode == 3) markEdges(c, 0, start, c.n_rows, total, s, false, c.dry);
    }
    return cur;
}
fn colVisit(c: *S, mode: u2, s: *const st.Style, default: f32, start: u32, span: u32) void {
    if (mode == 1) {
        const col = colOf(c.q, s, default, c.fixed);
        for (start..start + span) |i| c.cols[i] = col;
    } else if (mode == 2) {
        for (start..start + span) |i| markEdges(c, 0, @intCast(i), c.n_rows, 1, s, false, c.dry);
    }
}

// ---------------------------------------------------------------------------------------------------------
// collapsed borders (Blink's TableBorders with every border `solid`: the widest border wins an edge)
//
// The edge grid is Blink's flat array: `epr` edges per row of cells (for column k the edge at its left, 2k,
// and the edge at its top, 2k + 1) and one row of edges more than the last row a border reaches. As in
// Blink the grid only grows as far as a border (or a spanning cell) needs it, and reading the borders of a
// cell past that wraps into the next row of edges: reproduced, since it decides sizes.
// Edge values: 0 = empty, > 0 = the widest border merged so far, NaN = inside a spanning cell (never filled),
// -1 = a `hidden` border (`Style.border_hidden`), which wins the edge for good and takes no space.

fn bw(c: *const S, v: f32) f32 {
    return if (v > 0 and std.math.isFinite(v)) lu(c.q, v) else 0;
}
/// Blink's EnsureCellColumnFits / EnsureCellRowFits (the grid is allocated once, after a dry run).
fn fitEdges(c: *S, row: u32, col: u32) void {
    c.epr = @max(c.epr, (@as(usize, col) + 2) * 2);
    c.erows = @max(c.erows, @as(usize, row) + 2);
}
fn putEdge(c: *S, i: usize, w: f32) void {
    if (i >= c.edges.len) return;
    const e = c.edges[i];
    if (w < 0) {
        if (e == e) c.edges[i] = -1;
    } else if (e >= 0 and w > e) c.edges[i] = w;
}
/// Blink's MergeBorders for a box covering rows r0..r0+rs, columns c0..c0+cs. `dry`: only size the grid.
fn markEdges(c: *S, r0: u32, c0: u32, rs: u32, cs_in: u32, s: *const st.Style, is_cell: bool, dry: bool) void {
    if (rs == 0 or cs_in == 0) return;
    const cs = @min(cs_in, c.bc -| c0);
    if (cs == 0) return;
    const b = s.border;
    const hid = s.border_hidden;
    // (inline-start / inline-end edge)
    var wl: f32 = if (hid.left) -1 else bw(c, b.left);
    const wt: f32 = if (hid.top) -1 else bw(c, b.top);
    var wr: f32 = if (hid.right) -1 else bw(c, b.right);
    if (c.rtl) std.mem.swap(f32, &wl, &wr);
    const wb: f32 = if (hid.bottom) -1 else bw(c, b.bottom);
    const inner = is_cell and (rs > 1 or cs > 1);
    if (inner) {
        fitEdges(c, r0 + rs - 1, c0 + cs - 1);
    } else {
        if (wl == 0 and wt == 0 and wr == 0 and wb == 0) return;
        // only the edges a border fills need to exist
        fitEdges(c, if (wl == 0 and wr == 0 and wb == 0) r0 else r0 + rs - 1, if (wr == 0 and wt == 0 and wb == 0) c0 else c0 + cs - 1);
    }
    if (dry) return;
    const epr = c.epr;
    if (wt != 0) {
        for (0..cs) |k| putEdge(c, epr * r0 + (c0 + k) * 2 + 1, wt);
    }
    if (wb != 0) {
        for (0..cs) |k| putEdge(c, epr * (@as(usize, r0) + rs) + (c0 + k) * 2 + 1, wb);
    }
    if (wl != 0) {
        for (0..rs) |k| putEdge(c, epr * (r0 + k) + @as(usize, c0) * 2, wl);
    }
    if (wr != 0) {
        for (0..rs) |k| putEdge(c, epr * (r0 + k) + (@as(usize, c0) + cs) * 2, wr);
    }
    if (inner) {
        // MarkInnerBordersAsDoNotFill: no part of the table draws inside a spanning cell
        for (0..rs) |k| {
            const base = epr * (r0 + k) + @as(usize, c0) * 2;
            for (1..cs) |j| blockEdge(c, base + j * 2);
            if (k != 0) {
                for (0..cs) |j| blockEdge(c, base + j * 2 + 1);
            }
        }
    }
}
fn blockEdge(c: *S, i: usize) void {
    if (i < c.edges.len and c.edges[i] == 0) c.edges[i] = NONE;
}
inline fn edgeW(c: *const S, i: usize) f32 {
    return if (i < c.edges.len and c.edges[i] > 0) c.edges[i] else 0;
}
/// Blink's GetCellBorders: half of the widest edge along each side (left, top, right, bottom).
fn edgeBorders(c: *const S, row: u32, col: u32, rs: u32, cs: u32) [4]f32 {
    const epr = c.epr;
    if (epr == 0 or @as(usize, col) * 2 >= epr or row >= c.edges.len / epr) return .{ 0, 0, 0, 0 };
    var m: [4]f32 = .{ 0, 0, 0, 0 };
    const first_start = epr * row + @as(usize, col) * 2;
    const first_end = first_start + @as(usize, cs) * 2;
    for (0..rs) |k| {
        const start = first_start + k * epr;
        m[0] = @max(m[0], edgeW(c, start));
        if (start >= c.edges.len) break;
        m[2] = @max(m[2], edgeW(c, first_end + k * epr));
    }
    for (0..cs) |k| {
        const column_edge = @as(usize, col) * 2 + 1 + k * 2;
        if (column_edge >= epr) break;
        const start = epr * row + column_edge;
        m[1] = @max(m[1], edgeW(c, start));
        m[3] = @max(m[3], edgeW(c, start + @as(usize, rs) * epr));
    }
    for (&m) |*v| v.* = divI(c.q, v.*, 2);
    if (c.rtl) std.mem.swap(f32, &m[0], &m[2]);
    return m;
}

/// Every box's borders merged into the grid, in Blink's order: cells, rows, row groups, columns, column
/// groups, the table.
fn mergeBorders(t: anytype, c: *S, dry: bool) void {
    for (c.secs[0..c.n_secs]) |*sec| {
        for (0..sec.n_rows) |k| {
            const ri: u32 = sec.start + @as(u32, @intCast(k));
            const row = &c.rows[ri];
            for (c.cells[row.first .. row.first + row.n]) |*cell| {
                if (!cell.anon) markEdges(c, ri, cell.col, cell.eff, cell.colspan, styleOf(t, cell.node), true, dry);
            }
        }
    }
    for (c.rows[0..c.n_rows], 0..) |*row, ri| {
        if (row.node != no_node) markEdges(c, @intCast(ri), 0, 1, c.bc, styleOf(t, row.node), false, dry);
    }
    for (c.secs[0..c.n_secs]) |*sec| {
        if (sec.node != no_node) markEdges(c, sec.start, 0, sec.n_rows, c.bc, styleOf(t, sec.node), false, dry);
    }
    c.dry = dry;
    _ = visitCols(t, c, c.bc, 2);
    _ = visitCols(t, c, c.bc, 3);
    if (c.is_table) markEdges(c, 0, 0, c.n_rows, c.bc, styleOf(t, c.node), false, dry);
}

/// Blink's ComputeTableBorders: the used border of every cell (and the grid for the table's own).
/// Returns false when the grid would be unreasonably large (the borders then stay separate).
noinline fn computeBorders(t: anytype, c: *S) Error!bool {
    c.epr = 0;
    c.erows = 0;
    c.edges = &.{};
    mergeBorders(t, c, true);
    if (c.epr == 0) return true;
    const len = std.math.mul(usize, c.epr, c.erows) catch return false;
    if (len > max_edges) return false;
    c.edges = try arr(t, f32, len);
    @memset(c.edges, 0);
    mergeBorders(t, c, false);
    for (c.rows[0..c.n_rows], 0..) |*row, ri| {
        for (c.cells[row.first .. row.first + row.n]) |*cell| {
            cell.border = edgeBorders(c, @intCast(ri), cell.col, cell.eff, @max(@min(cell.colspan, c.bc -| cell.col), 1));
        }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------------------
// column constraints and sizes (Blink's table_layout_utils.cc)
//
// Column sizes are kept in f64: a percentage column makes Blink reach for kTableMaxInlineSize (10^6 px),
// and sums of such values with 1/64 px fractions do not fit an f32. Where Blink itself computes in `float`
// (percentages, scale factors) the same f32 operations are used.

/// Column::Encompass.
fn colEncompass(col: *Col, cell: *const CellC, fixed: bool) void {
    if (!cell.present) return;
    if (col.constrained and fixed) return;
    if (!fixed) col.mergeable = false;
    if (hasW(col.min)) {
        col.min = @max(col.min, cell.min);
        col.max = if (col.constrained and !cell.constrained) @max(col.mx(), cell.min) else @max(col.mx(), cell.max);
    } else {
        col.min = cell.min;
        col.max = cell.max;
    }
    col.max = @max(col.min, col.max);
    if (gtOpt(cell.pct, col.pct)) {
        col.pct = cell.pct;
        col.pbp = cell.pbp;
    }
    col.constrained = col.constrained or cell.constrained;
}

/// CellInlineConstraint::Encompass.
fn cellEncompass(a: *CellC, b: *const CellC) void {
    if (!a.present) {
        a.* = b.*;
        a.present = true;
        return;
    }
    const amax = a.max;
    a.max = if (a.constrained and !b.constrained) @max(amax, b.min) else if (!a.constrained and b.constrained) @max(a.min, b.max) else @max(amax, b.max);
    a.min = @max(a.min, b.min);
    a.constrained = a.constrained or b.constrained;
    if (gtOpt(b.pct, a.pct)) {
        a.pct = b.pct;
        a.pbp = b.pbp;
    }
}

fn innerSpacing(span: []const Col, spacing: f64) f64 {
    var n: f64 = 0;
    for (span) |*col| n += @floatFromInt(@intFromBool(!col.mergeable));
    return spacing * @max(n - 1, 0);
}

/// DistributeColspanCellToColumnsFixed.
noinline fn colspanFixed(q: bool, span: []Col, cell: *const CellC, spacing: f64) void {
    const inner = innerSpacing(span, spacing);
    var eff: f32 = 0;
    for (span) |*col| eff += @floatFromInt(@intFromBool(!col.mergeable));
    if (eff == 0) return;
    const mn: f64 = if (cell.constrained) @max(cell.min - inner, 0) else 0;
    const mx: f64 = @max(cell.max - inner, 0);
    var min_err = mn;
    var max_err = mx;
    const new_min = luf(q, ff(mn) / eff);
    const new_max = luf(q, ff(mx) / eff);
    const new_pct = if (has(cell.pct)) cell.pct / eff else NONE;
    var last: ?*Col = null;
    for (span) |*col| {
        if (col.mergeable) continue;
        last = col;
        min_err -= new_min;
        max_err -= new_max;
        if (!hasW(col.min)) {
            col.constrained = col.constrained or cell.constrained;
            col.min = new_min;
        }
        if (!hasW(col.max)) {
            col.constrained = col.constrained or cell.constrained;
            col.max = new_max;
        }
        // percentages only get distributed over auto columns
        if (!has(col.pct) and !col.constrained and has(new_pct)) col.pct = new_pct;
    }
    if (last) |col| {
        col.min = col.mn() + min_err;
        col.max = col.mx() + max_err;
    }
}

/// DistributeColspanCellToColumnsAuto.
noinline fn colspanAuto(q: bool, span: []Col, cell: *const CellC, spacing: f64, sizes: []f64) void {
    if (span.len == 0) return;
    const inner = innerSpacing(span, spacing);
    const mn = @max(cell.min - inner, 0);
    const mx = @max(cell.max - inner, 0);
    if (has(cell.pct)) {
        var cols_pct: f32 = 0;
        var all: u32 = 0;
        var n_pct: u32 = 0;
        var n_non: f32 = 0;
        var non_max: f64 = 0;
        for (span) |*col| {
            col.max = col.mx();
            col.min = col.mn();
            if (col.mergeable) continue;
            all += 1;
            if (has(col.pct)) {
                n_pct += 1;
                cols_pct += col.pct;
            } else {
                n_non += 1;
                non_max += col.max;
            }
        }
        const surplus = cell.pct - cols_pct;
        if (surplus > 0 and all > n_pct) {
            for (span) |*col| {
                if (has(col.pct) or col.mergeable) continue;
                col.pct = if (non_max != 0) surplus * ff(col.max) / ff(non_max) else surplus / n_non;
            }
        }
    }
    for (span) |*col| {
        col.min = col.mn();
        col.max = col.mx();
    }
    distributeAuto(q, mn, span, true, sizes);
    for (span, sizes[0..span.len]) |*col, sz| col.min = @max(col.min, sz);
    distributeAuto(q, mx, span, cell.constrained, sizes);
    for (span, sizes[0..span.len]) |*col, sz| col.max = @max(@max(col.min, col.max), sz);
}

fn share(q: bool, distributable: f64, increase: f64, total: f64, count: f64) f64 {
    return if (total > 0) mulDiv(q, distributable, increase, total) else divI(q, distributable, @max(count, 1));
}

/// DistributeInlineSizeToComputedInlineSizeAuto (css-tables-3 width distribution): `target` shared out over
/// `cols` into `sizes`. A `constrained` target may grow fixed columns past their widths.
/// Column kinds: 0 = percentage, 1 = fixed (constrained), 2 = auto. Of the four guesses (every column at
/// its minimum; + percentages resolved; + fixed columns at their width; + auto columns at their maximum)
/// the first that reaches the target decides which kind takes up the slack.
fn distributeAuto(q: bool, target_in: f64, cols: []const Col, constrained: bool, sizes: []f64) void {
    var gs: [4]f64 = .{ 0, 0, 0, 0 };
    var gi: [4]f64 = .{ 0, 0, 0, 0 };
    // per kind: number of columns, sum of their maximums
    var n: [3]f64 = .{ 0, 0, 0 };
    var kind_max: [3]f64 = .{ 0, 0, 0 };
    var total_pct: f32 = 0;
    for (cols) |*col| {
        if (col.mergeable) continue;
        const mn = col.mn();
        const mx = col.mx();
        const k: usize = if (has(col.pct)) 0 else if (col.constrained) 1 else 2;
        // the size of the column in the guesses from k + 1 on
        const upper = if (k == 0) col.resolvePct(q, target_in) else mx;
        if (k == 0) total_pct += col.pct;
        n[k] += 1;
        kind_max[k] += mx;
        for (&gs, 0..) |*g, i| g.* += if (i > k) upper else mn;
        gi[k + 1] += upper - mn;
    }
    // distributing never takes a column below its minimum
    const target = @max(target_in, gs[0]);
    var guess: usize = 4;
    for (gs, 0..) |g, i| {
        if (g >= target) {
            guess = i;
            break;
        }
    }
    // the kind that grows (-1: none), what it shares
    var grow: i32 = @as(i32, @intCast(guess)) - 1;
    var d: f64 = 0;
    var exact = false;
    if (guess == 4) {
        d = target - gs[3];
        grow = if (n[2] > 0) 2 else if (n[1] > 0 and constrained) 1 else if (n[0] > 0) 0 else -1;
    } else if (guess > 0) {
        d = target - gs[guess - 1];
        // an exact match usually is an auto table sized to its content: do not round a column short
        exact = guess == 3 and target == gs[3];
    }
    var deficit: f64 = if (exact or grow < 0) 0 else d;
    var last: ?usize = null;
    for (cols, sizes[0..cols.len], 0..) |*col, *o, i| {
        o.* = 0;
        if (col.mergeable) continue;
        const k: i32 = if (has(col.pct)) 0 else if (col.constrained) 1 else 2;
        const mn = col.mn();
        const upper = if (k == 0) col.resolvePct(q, target) else col.mx();
        var delta: f64 = 0;
        if (guess == 4) {
            // above every maximum: auto columns grow by their maximums, else fixed ones, else percentages
            // (the other columns then get nothing)
            if (k != grow) {
                if (grow > 0) o.* = upper;
                continue;
            }
            delta = if (k != 0) share(q, d, upper, kind_max[@intCast(k)], n[@intCast(k)]) else if (total_pct != 0) luf(q, ff(d) * col.pct / total_pct) else divI(q, d, n[0]);
            o.* = upper + delta;
        } else if (k != grow or exact) {
            o.* = if (k < grow or exact) upper else mn;
            continue;
        } else {
            delta = share(q, d, upper - mn, gi[guess], n[@intCast(k)]);
            o.* = mn + delta;
        }
        last = i;
        deficit -= delta;
    }
    // (Blink skips a deficit owed to the first column when percentages take the slack)
    if (last) |l| {
        if (!(guess == 4 and grow <= 0 and l == 0)) sizes[l] += deficit;
    }
}

/// ApplyCellConstraintsToColumnConstraints.
noinline fn applyCellConstraints(c: *S) void {
    const q = c.q;
    const n_cc = c.n_cellcols;
    if (c.n_cols < n_cc) {
        for (c.cols[c.n_cols..n_cc]) |*col| col.* = .{ .mergeable = !c.fixed };
        c.n_cols = n_cc;
    } else {
        while (c.n_cols > n_cc and c.cols[c.n_cols - 1].mergeable) c.n_cols -= 1;
    }
    const cols = c.cols[0..c.n_cols];
    const spans = c.cs[0..c.n_cs];
    for (spans) |*sp| {
        // EnsureDistributableColumnExists
        const end = @min(sp.start + sp.span, c.n_cols);
        if (sp.start >= end) continue;
        const range = cols[sp.start..end];
        var done = false;
        for (range) |*col| {
            if (!col.collapsed) {
                col.mergeable = false;
                done = true;
                break;
            }
        }
        if (!done) range[0].mergeable = false;
    }
    for (cols[0..@min(c.n_cols, n_cc)], c.cc[0..@min(c.n_cols, n_cc)]) |*col, *cell| colEncompass(col, cell, c.fixed);

    // narrower spans first, then by start column (stable)
    const idx = c.idx[0..c.n_cs];
    for (idx, 0..) |*v, i| v.* = @intCast(i);
    mergeSort(idx, c.idx[c.idx.len / 2 ..][0..c.n_cs], @as([]const CellC, spans), struct {
        fn less(s: []const CellC, a: u32, b: u32) bool {
            return if (s[a].span != s[b].span) s[a].span < s[b].span else s[a].start < s[b].start;
        }
    }.less);
    for (idx) |i| {
        const sp = &spans[i];
        const end = @min(sp.start + sp.span, c.n_cols);
        if (sp.start >= end) continue;
        if (c.fixed) colspanFixed(q, cols[sp.start..end], sp, c.spacing[0]) else colspanAuto(q, cols[sp.start..end], sp, c.spacing[0], c.sizes);
    }

    // auto tables leave each column no more than what earlier columns left of 100%, fixed tables scale
    var total: f32 = 0;
    for (cols) |*col| {
        if (has(col.pct)) {
            if (!c.fixed and col.pct + total > 100) col.pct = 100 - total;
            total += col.pct;
        }
        col.min = col.mn();
        col.max = col.mx();
    }
    if (c.fixed and total > 100) {
        for (cols) |*col| {
            if (has(col.pct)) col.pct = col.pct * 100 / total;
        }
    }
}

/// Stable merge sort of an index array (`tmp` same length).
fn mergeSort(idx: []u32, tmp: []u32, ctx: anytype, comptime less: fn (@TypeOf(ctx), u32, u32) bool) void {
    const n = idx.len;
    var src = idx;
    var dst = tmp;
    var width: usize = 1;
    while (width < n) : (width *= 2) {
        var i: usize = 0;
        while (i < n) : (i += 2 * width) {
            const mid = @min(i + width, n);
            const end = @min(i + 2 * width, n);
            var a = i;
            var b = mid;
            var k = i;
            while (a < mid and b < end) : (k += 1) {
                if (less(ctx, src[b], src[a])) {
                    dst[k] = src[b];
                    b += 1;
                } else {
                    dst[k] = src[a];
                    a += 1;
                }
            }
            while (a < mid) : (k += 1) {
                dst[k] = src[a];
                a += 1;
            }
            while (b < end) : (k += 1) {
                dst[k] = src[b];
                b += 1;
            }
        }
        const sw = src;
        src = dst;
        dst = sw;
    }
    if (src.ptr != idx.ptr) @memcpy(idx, src);
}

/// ComputeGridInlineMinMax.
fn gridMinMax(c: *const S, undist: f64, allow_pct: bool) [2]f64 {
    const q = c.q;
    var mn: f64 = 0;
    var mx: f64 = 0;
    var pct_est: f64 = 0;
    var non_pct_sum: f64 = 0;
    var pct_sum: f32 = 0;
    for (c.cols[0..c.n_cols]) |*col| {
        if (hasW(col.min)) {
            // in fixed layout, constrained cells' minimum inline size is their maximum
            mn += if (c.fixed and col.isFixed()) col.mx() else col.min;
            if (has(col.pct) and col.pct > 0) {
                if (col.mx() > 0) pct_est = @max(pct_est, luf(q, 100 / col.pct * ff(col.mx() - col.pbp)));
            } else non_pct_sum += col.mx();
        }
        if (hasW(col.max)) mx += col.max;
        if (has(col.pct)) pct_sum += col.pct;
    }
    pct_sum = @min(pct_sum, 100);
    if (pct_sum > 0 and allow_pct) {
        const from_pct: f64 = if (non_pct_sum == 0) 0 else if (pct_sum == 100) table_max_inline else luf(q, 100 / (100 - pct_sum) * ff(non_pct_sum));
        mx = @max(@max(mx, from_pct), pct_est);
    }
    mx = @max(mn, mx);
    return .{ mn + undist, mx + undist };
}

/// SynchronizeAssignableTableInlineSizeAndColumnsFixed.
noinline fn sizesFixed(c: *S, target: f64) void {
    const q = c.q;
    const cols = c.cols[0..c.n_cols];
    var n_pct: f32 = 0;
    var n_auto: f32 = 0;
    var n_fixed: f32 = 0;
    var n_zero: usize = 0;
    var total_pct: f64 = 0;
    var total_fixed: f64 = 0;
    var assigned: f64 = 0;
    var last: ?*Col = null;
    for (cols) |*col| {
        col.size = 0;
        if (has(col.pct)) {
            n_pct += 1;
            total_pct += col.resolvePct(q, target);
        } else if (col.isFixed() and col.mx() != 0) {
            n_fixed += 1;
            total_fixed += col.mx();
        } else if (col.constrained and col.max == 0) {
            n_zero += 1;
        } else n_auto += 1;
    }
    if (n_fixed > 0) {
        const target_fixed = @max(target - total_pct, 0);
        const up = total_fixed < target_fixed and n_auto == 0;
        const down = total_fixed > target;
        const scale: f32 = if (!(up or down)) 1 else if (total_fixed != 0) ff(target_fixed) / ff(total_fixed) else NONE;
        for (cols) |*col| {
            if (has(col.pct) or !(col.isFixed() and col.mx() != 0)) continue;
            last = col;
            col.size = if (has(scale)) luf(q, scale * ff(col.mx())) else luf(q, ff(target) / n_fixed);
            assigned += col.size;
        }
    }
    if (assigned >= target) return;
    if (n_pct > 0) {
        const room = target - assigned;
        const up = total_pct < room and n_auto == 0;
        const down = total_pct > room;
        const scale: f32 = if (!(up or down)) 1 else if (total_pct != 0) ff(room) / ff(total_pct) else NONE;
        for (cols) |*col| {
            if (!has(col.pct)) continue;
            last = col;
            col.size = if (has(scale)) luf(q, scale * ff(col.resolvePct(q, target))) else luf(q, ff(room) / n_pct);
            assigned += col.size;
        }
    }
    // auto columns, and zero-width ones only if every column is one
    const distributing = target - assigned;
    const all_zero = n_zero == cols.len;
    for (cols) |*col| {
        if (has(col.pct) or (col.isFixed() and col.mx() != 0)) continue;
        const zero = col.constrained and col.max == 0;
        if (zero and !all_zero) continue;
        last = col;
        const cnt: f32 = if (all_zero) @floatFromInt(n_zero) else n_auto;
        col.size = luf(q, ff(distributing) / @max(cnt, 1));
        assigned += col.size;
    }
    if (last) |col| col.size += target - assigned;
}

/// ComputeLocationsFromColumns.
fn locations(c: *S, v: usize) void {
    var first = true;
    const sp: f64 = c.spacing[0];
    var off = sp;
    for (c.cols[0..c.n_cols]) |*col| {
        if (col.collapsed) c.has_collapsed = true;
        if ((col.mergeable and col.size == 0) or (v == 1 and col.collapsed)) {
            col.off[v] = ff(off);
            col.w[v] = 0;
            continue;
        }
        if (first) first = false else off += sp;
        col.off[v] = ff(off);
        col.w[v] = ff(col.size);
        off += col.size;
    }
}
fn sizeFromCols(c: *const S, v: usize) f32 {
    const last = &c.cols[c.n_cols - 1];
    return last.off[v] + last.w[v] + c.box.pb[0] + c.spacing[0];
}
/// Inline size of the columns a cell spans.
fn spanW(c: *const S, cell: *const Cell, v: usize) f32 {
    if (c.n_cols == 0) return 0;
    const last = c.n_cols - 1;
    const a = @min(cell.col, last);
    const b = @min(cell.col + cell.colspan - 1, last);
    return c.cols[b].off[v] + c.cols[b].w[v] - c.cols[a].off[v];
}

// ---------------------------------------------------------------------------------------------------------
// rows (Blink's table_layout_utils.cc)

const cls_orig: u8 = 1;
const cls_deficit: u8 = 2;
const cls_empty: u8 = 4;
const cls_constrained: u8 = 8;

fn rowDeficit(q: bool, row: *const Row, basis: f32) f32 {
    return @max(lu(q, orElse(row.pct, 0) * basis / 100) - row.h, 0);
}

/// DistributeExcessBlockSizeToRows (`basis` NaN = no percentage resolution size).
fn distributeExcess(q: bool, rows: []Row, desired: f32, is_rowspan: bool, sv: f32, basis: f32) void {
    if (rows.len == 0) return;
    var total: f32 = 0;
    var pct_deficit: f32 = 0;
    var unc_ne_sum: f32 = 0;
    var n_orig: f32 = 0;
    var n_def: usize = 0;
    var n_unc_ne: usize = 0;
    var n_empty: usize = 0;
    var n_ne: usize = 0;
    var n_unc_empty: f32 = 0;
    var n_con_ne: usize = 0;
    for (rows, 0..) |*row, k| {
        var cls: u8 = 0;
        total += row.h;
        if (is_rowspan and k != 0 and row.span_start) {
            cls |= cls_orig;
            n_orig += 1;
        }
        var empty = row.h == 0;
        if (has(row.pct) and has(basis) and row.pct != 0) {
            const d = rowDeficit(q, row, basis);
            if (d != 0) {
                cls |= cls_deficit;
                n_def += 1;
                pct_deficit += d;
                empty = false;
            }
        }
        // only percent rows that resolve count as constrained
        const constrained = row.constrained and (!has(row.pct) or has(basis));
        if (constrained) cls |= cls_constrained;
        if (empty) {
            cls |= cls_empty;
            n_empty += 1;
            if (!constrained) n_unc_empty += 1;
        } else {
            n_ne += 1;
            if (constrained) n_con_ne += 1 else {
                n_unc_ne += 1;
                unc_ne_sum += row.h;
            }
        }
        row.cls = cls;
    }
    var dist = (desired - sv * @as(f32, @floatFromInt(rows.len - 1))) - total;
    if (dist <= 0) return;

    // 1: percentage rows grow to no more than their percentage size
    if (n_def > 0) {
        const pd = @min(pct_deficit, dist);
        var rem = pd;
        var last: *Row = &rows[0];
        for (rows) |*row| {
            if (row.cls & cls_deficit == 0) continue;
            const delta = mulDiv(q, pd, rowDeficit(q, row, basis), pct_deficit);
            row.h += delta;
            dist -= delta;
            rem -= delta;
            last = row;
        }
        last.h += rem;
        dist -= rem;
        if (dist <= 0) return;
    }
    // 2: rows a rowspan starts in
    if (n_orig > 0) {
        var rem = dist;
        var last: *Row = &rows[0];
        for (rows) |*row| {
            if (row.cls & cls_orig == 0) continue;
            const delta = divI(q, dist, n_orig);
            row.h += delta;
            rem -= delta;
            last = row;
        }
        last.h = @max(last.h + rem, 0);
        return;
    }
    // 3: unconstrained rows with content, in proportion to their block size
    if (n_unc_ne > 0) {
        var rem = dist;
        var last: *Row = &rows[0];
        for (rows) |*row| {
            if (row.cls & (cls_empty | cls_constrained) != 0) continue;
            const delta = mulDiv(q, dist, row.h, unc_ne_sum);
            row.h += delta;
            rem -= delta;
            last = row;
        }
        last.h += rem;
        return;
    }
    // 4: empty rows, once every row is empty or constrained
    if (n_empty > 0) {
        const only_empty = n_empty == rows.len;
        if (is_rowspan) {
            if (only_empty) {
                rows[rows.len - 1].h += dist;
                return;
            }
        } else if (only_empty or n_empty + n_con_ne == rows.len) {
            const unc = n_unc_empty > 0;
            const cnt: f32 = if (unc) n_unc_empty else @floatFromInt(n_empty);
            var rem = dist;
            var last: *Row = &rows[0];
            for (rows) |*row| {
                if (row.cls & cls_empty == 0 or (unc and row.cls & cls_constrained != 0)) continue;
                const delta = divI(q, dist, cnt);
                row.h = delta;
                rem -= delta;
                last = row;
            }
            last.h += rem;
            return;
        }
    }
    // 5: every row with content, in proportion to its block size
    if (n_ne > 0) {
        var rem = dist;
        var last: *Row = &rows[0];
        for (rows) |*row| {
            if (row.cls & cls_empty != 0) continue;
            const delta = mulDiv(q, dist, row.h, total);
            row.h += delta;
            rem -= delta;
            last = row;
        }
        last.h += rem;
    }
}

fn secPctSize(q: bool, sec: *const Sec, d: f32) f32 {
    return @max(sec.h, lu(q, orElse(sec.pct, 0) * d / 100));
}
inline fn secKind(sec: *const Sec) u8 {
    return if (has(sec.pct)) 2 else if (sec.constrained) 1 else 0;
}

/// DistributeTableBlockSizeToSections.
noinline fn distributeToSections(c: *S, table_block_size: f32) void {
    const q = c.q;
    const sv = c.spacing[1];
    const secs = c.secs[0..c.n_secs];
    if (secs.len == 0) return;
    const d = @max(table_block_size - sv * @as(f32, @floatFromInt(secs.len + 1)), 0);
    var min_guess: f32 = 0;
    var pct_guess: f32 = 0;
    var has_tbody = false;
    // [kind][all, tbody]
    var cnt: [3][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
    var sum: [3][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
    for (secs) |*sec| {
        const k = secKind(sec);
        min_guess += sec.h;
        pct_guess += if (k == 2) secPctSize(q, sec, d) else sec.h;
        has_tbody = has_tbody or sec.tbody;
        cnt[k][0] += 1;
        if (k != 2) sum[k][0] += sec.h;
        if (sec.tbody) {
            cnt[k][1] += 1;
            if (k != 2) sum[k][1] += sec.h;
        }
    }
    if (d <= min_guess) return;

    if (cnt[2][0] > 0 and pct_guess > min_guess) {
        const dist = @min(pct_guess, d) - min_guess;
        const diff = pct_guess - min_guess;
        var rem = dist;
        var last: *Sec = &secs[0];
        for (secs) |*sec| {
            if (secKind(sec) != 2) continue;
            const delta = mulDiv(q, dist, secPctSize(q, sec, d) - sec.h, diff);
            sec.h += delta;
            sec.redist = true;
            rem -= delta;
            min_guess += delta;
            sum[2][0] += sec.h;
            if (sec.tbody) sum[2][1] += sec.h;
            last = sec;
        }
        last.h += rem;
        sum[2][0] += rem;
        min_guess += rem;
        if (last.tbody) sum[2][1] += rem;
    }

    // bodies grow before headers and footers; of either, auto sections before fixed ones, fixed before percent
    const tb: usize = @intFromBool(has_tbody);
    const kind: u8 = if (cnt[0][tb] > 0) 0 else if (cnt[1][tb] > 0) 1 else 2;
    const dist = d - min_guess;
    if (dist > 0 and cnt[kind][tb] > 0) {
        var rem = dist;
        var last: *Sec = &secs[0];
        for (secs) |*sec| {
            if (secKind(sec) != kind or (has_tbody and !sec.tbody)) continue;
            const delta = if (sum[kind][tb] > 0) mulDiv(q, dist, sec.h, sum[kind][tb]) else divI(q, dist, cnt[kind][tb]);
            sec.h += delta;
            sec.redist = true;
            rem -= delta;
            last = sec;
        }
        last.h += rem;
    }
    for (secs) |*sec| {
        if (sec.redist) distributeExcess(q, c.rows[sec.start .. sec.start + sec.n_rows], sec.h, false, sv, sec.h);
    }
}

/// RowspanCell::operator<: a span another encloses distributes first, of two equal spans the taller one.
fn rowspanLess(rs: []const RowSpan, ai: u32, bi: u32) bool {
    const a = &rs[ai];
    const b = &rs[bi];
    if (a.start == b.start and a.span == b.span) return a.min > b.min;
    if (a.start >= b.start and a.start + a.span <= b.start + b.span) return true;
    if (b.start >= a.start and b.start + b.span <= a.start + a.span) return false;
    return a.start < b.start;
}

// ---------------------------------------------------------------------------------------------------------
// child computations (everything below that reaches `computeNode` is noinline and keeps its state in `S`)

/// Computes real cell `i` with the request in `c.ci` into `c.co`, laid out with its used (collapsed) border.
/// `direct` = final pass: the cell's block layout runs uncached, so its children's positions are always the
/// unshifted ones afterwards.
noinline fn cellCompute(t: anytype, c: *S, i: usize, direct: bool) Error!void {
    const cell = &c.cells[i];
    const node = cell.node;
    if (c.collapse) {
        // (the node's style is shared: the cell is laid out with a copy holding its used border)
        cell.orig = t.nodes.items[node].style;
        c.used_style = cell.orig.*;
        c.used_style.border = tr.toEdges(cell.border);
        t.nodes.items[node].style = &c.used_style;
    }
    defer if (c.collapse) {
        t.nodes.items[node].style = cell.orig;
    };
    const n = &t.nodes.items[node];
    if (direct and n.child_count != 0 and !n.measured) {
        c.ci.avail = .{ MAXC, MAXC };
        try block.compute(t, node, &c.ci, &c.co);
    } else try t.computeNode(node, &c.ci, &c.co);
}

/// Box of real cell `i` (padding against `basis`, used border, no margins) into `c.cb`.
fn cellBox(t: anytype, c: *S, i: usize, basis: f32) void {
    const cell = &c.cells[i];
    t.rbox(&c.cb, styleOf(t, cell.node), .{ basis, NONE });
    c.cb.margin = .{ 0, 0, 0, 0 };
    c.cb.margin_auto = .{ false, false, false, false };
    setBorder(&c.cb, cell.border);
}

/// Min- / max-content inline size of the content of a cell: the widest contribution of the sibling nodes
/// `first`..`last` (no_node = to the end) as block-level boxes.
noinline fn runIntrinsic(t: anytype, c: *S, first: u32, last: u32, avail: f32) Error!f32 {
    var widest: f32 = 0;
    var ch = first;
    while (ch != no_node) : (ch = t.nextSibling(ch)) {
        const cs = styleOf(t, ch);
        if (!skipped(cs)) {
            t.rbox(&c.cb, cs, .{ NONE, NONE });
            const tbl = isTableAlgo(cs.display);
            var w = clampO(c.cb.size[0], c.cb.min[0], c.cb.max[0]);
            if (!has(w) or tbl) {
                c.ci = .{
                    .known = .{ NONE, if (tbl) NONE else clampO(c.cb.size[1], c.cb.min[1], c.cb.max[1]) },
                    .avail = .{ avail, MAXC },
                };
                w = try t.measureChild(ch, &c.ci, 0);
            }
            // (a table sizes itself: no specified width below its min-content, no padding when it collapses)
            widest = @max(widest, (if (tbl) w else @max(w, c.cb.pb[0])) + c.cb.marginSum(0));
        }
        if (ch == last) break;
    }
    return widest;
}

/// Lays out the nodes of anonymous cell `i` as the block-level children of a formatting context root `w`
/// wide (`inner_h`: definite content height for their percentages, or NaN). Results: `c.an_h` (border-box
/// height of the content) and `c.an_bl` (first baseline, NaN = none). With `place` the children get their
/// layout, the cell's border-box origin being at (`px`, `py`) in their parent node.
noinline fn anonCell(t: anytype, c: *S, i: usize, w: f32, inner_h: f32, place: bool, px: f32, py: f32) Error!void {
    const cell = &c.cells[i];
    const inner_w = @max(w - cell.border[0] - cell.border[2], 0);
    var y = cell.border[1];
    c.active = .{};
    var first_bl: f32 = NONE;
    var ch = cell.node;
    while (ch != no_node) : (ch = t.nextSibling(ch)) {
        const cs = styleOf(t, ch);
        if (!skipped(cs)) {
            t.rbox(&c.cb, cs, .{ inner_w, inner_h });
            const cb = &c.cb;
            const ms = cb.marginSum(0);
            const tbl = isTableAlgo(cs.display);
            const ckh = maxO(clampO(cb.size[1], cb.min[1], cb.max[1]), cb.pb[1]);
            const ckw = orElse(cb.size[0], inner_w - ms);
            const self_sized = tbl or cs.size[0].isKeyword() or (!has(cb.size[0]) and has(t.ratio(cs, cb, 0, ckh)));
            c.ci = .{
                .known = .{ if (self_sized) NONE else @max(clampO(ckw, cb.min[0], cb.max[0]), cb.pb[0]), if (tbl) NONE else ckh },
                .parent = .{ inner_w, inner_h },
                .avail = .{ inner_w, MAXC },
                .layout = true,
            };
            try t.computeNode(ch, &c.ci, &c.co);
            const o = &c.co;
            const free_x = @max(inner_w - o.size[0] - ms, 0);
            const n_auto: f32 = @floatFromInt(@as(u8, @intFromBool(cb.margin_auto[0])) + @intFromBool(cb.margin_auto[2]));
            if (n_auto > 0) {
                if (cb.margin_auto[0]) cb.margin[0] = t.div(free_x, n_auto);
                if (cb.margin_auto[2]) cb.margin[2] = t.div(free_x, n_auto);
            }
            const top = (MarginSet{}).with(cb.margin[1]);
            const y_margin = c.active.merge(top).resolve();
            if (place) t.setLayout(ch, .{ px + cell.border[0] + cb.margin[0], py + y + y_margin }, o, cb);
            if (!has(first_bl) and has(o.baseline)) first_bl = y + y_margin + o.baseline;
            y += o.size[1] + y_margin;
            c.active = (MarginSet{}).with(cb.margin[3]);
        }
        if (ch == cell.last) break;
    }
    c.an_h = y + c.active.resolve() + cell.border[3];
    c.an_bl = first_bl;
}

/// Blink's CreateCellInlineConstraint for cell `i`, into `c.cic`.
noinline fn cellConstraint(t: anytype, c: *S, i: usize) Error!void {
    const q = c.q;
    const cell = &c.cells[i];
    var bp = cell.border[0] + cell.border[2];
    // width, min-width, max-width, percent
    c.isz = .{ NONE, NONE, NONE, NONE };
    var content_box = false;
    if (!cell.anon) {
        const cs = styleOf(t, cell.node);
        t.rbox(&c.cb, cs, .{ NONE, NONE });
        bp += c.cb.padding[0] + c.cb.padding[2];
        content_box = cs.box_sizing == .content_box;
        const w = tableLen(q, cs.size[0]);
        const mxl = tableLen(q, cs.max_size[0]);
        const mnl = tableLen(q, cs.min_size[0]).fixed;
        if (has(mnl)) c.isz[1] = if (content_box) mnl + bp else @max(mnl, bp);
        if (has(mxl.fixed)) c.isz[2] = maxO(if (content_box) mxl.fixed + bp else @max(mxl.fixed, bp), c.isz[1]);
        if (has(w.fixed)) c.isz[0] = if (content_box) w.fixed + bp else @max(w.fixed, bp);
        c.isz[3] = if (has(w.pct) and has(mxl.pct)) @min(w.pct, mxl.pct) else w.pct;
    }
    // (measured lazily: a fixed table with a fixed `width` never needs the content)
    var cmin: f32 = 0;
    var cmax: f32 = 0;
    if (!c.fixed) cmin = try cellIntrinsic(t, c, i, MINC);
    if (!has(c.isz[0])) cmax = try cellIntrinsic(t, c, i, MAXC);
    var mn: f32 = if (c.fixed) 0 else @max(cmin, orElse(c.isz[1], 0));
    var content_max = orElse(c.isz[0], cmax);
    if (has(c.isz[2])) {
        content_max = @min(content_max, c.isz[2]);
        mn = @min(mn, c.isz[2]);
    }
    c.cic = .{
        .present = true,
        .min = mn,
        .max = @max(mn, content_max),
        .pct = c.isz[3],
        .pbp = if (c.fixed and has(c.isz[3]) and content_box) bp else 0,
        .constrained = has(c.isz[0]),
        .start = cell.col,
        .span = cell.colspan,
    };
}

noinline fn cellIntrinsic(t: anytype, c: *S, i: usize, avail: f32) Error!f32 {
    const cell = &c.cells[i];
    if (cell.anon) return try runIntrinsic(t, c, cell.node, cell.last, avail) + cell.border[0] + cell.border[2];
    const node = cell.node;
    if (!t.nodes.items[node].measured) {
        // block.zig takes a child's specified width (and at least its padding + border) as its intrinsic
        // contribution; a table child sizes itself, so a cell holding one is measured here
        var k = t.firstChild(node);
        while (k != no_node) : (k = t.nextSibling(k)) {
            const ks = styleOf(t, k);
            if (skipped(ks) or !isTableAlgo(ks.display)) continue;
            cellBox(t, c, i, NONE);
            const bp = c.cb.pb[0];
            return try runIntrinsic(t, c, t.firstChild(node), no_node, avail) + bp;
        }
    }
    c.ci = .{ .avail = .{ avail, MAXC }, .content_sizing = true, .cs_axis = 0, .width_only = true };
    try cellCompute(t, c, i, false);
    return c.co.size[0];
}

/// Blink's ComputeColumnConstraints.
noinline fn columnConstraints(t: anytype, c: *S) Error!void {
    for (c.cc) |*x| x.* = .{};
    c.n_cs = 0;
    var first_sec = true;
    for (c.secs[0..c.n_secs]) |*sec| {
        if (sec.n_rows == 0) continue;
        for (0..sec.n_rows) |k| {
            // a fixed table only looks at its first row
            if (c.fixed and (!first_sec or k != 0)) break;
            const row = &c.rows[sec.start + k];
            for (row.first..row.first + row.n) |i| {
                try cellConstraint(t, c, i);
                if (c.cic.span == 1) {
                    if (c.cic.start < c.cc.len) cellEncompass(&c.cc[c.cic.start], &c.cic);
                } else if (c.n_cs < c.cs.len) {
                    c.cs[c.n_cs] = c.cic;
                    c.n_cs += 1;
                }
            }
        }
        first_sec = false;
    }
    applyCellConstraints(c);
}

/// Blink's ComputeCaptionConstraint: the widest caption's min-content contribution with its margins.
noinline fn captionMin(t: anytype, c: *S) Error!void {
    c.cap_min = 0;
    var ch = t.firstChild(c.node);
    while (ch != no_node) : (ch = t.nextSibling(ch)) {
        const cs = styleOf(t, ch);
        if (cs.display != .table_caption or cs.position.isOut()) continue;
        t.rbox(&c.cb, cs, .{ NONE, c.in.parent[1] });
        const ms = t.marginSumOf(cs, 0, c.in.parent[0]);
        var w = clampO(c.cb.size[0], c.cb.min[0], c.cb.max[0]);
        if (!has(w)) {
            c.ci = .{ .known = .{ NONE, clampO(c.cb.size[1], c.cb.min[1], c.cb.max[1]) }, .parent = .{ NONE, c.in.parent[1] }, .avail = .{ MINC, MAXC } };
            w = try t.measureChild(ch, &c.ci, 0);
        }
        c.cap_min = @max(c.cap_min, @max(w, c.cb.pb[0]) + ms);
    }
}

/// Lays out the top or bottom captions at the table's inline size (Blink's LayoutCaption), stacking them
/// from `y0`; returns the block size they take with their margins.
noinline fn captions(t: anytype, c: *S, bottom: bool, place: bool, y0: f32) Error!f32 {
    var y = y0;
    const tw = c.tbl_w;
    var ch = t.firstChild(c.node);
    while (ch != no_node) : (ch = t.nextSibling(ch)) {
        const cs = styleOf(t, ch);
        if (cs.display != .table_caption or cs.position.isOut() or cs.caption_bottom != bottom) continue;
        t.rbox(&c.cb, cs, .{ tw, NONE });
        const cb = &c.cb;
        const ms = cb.marginSum(0);
        const ckh = maxO(clampO(cb.size[1], cb.min[1], cb.max[1]), cb.pb[1]);
        const ckw = orElse(cb.size[0], tw - ms);
        const self_sized = cs.size[0].isKeyword() or (!has(cb.size[0]) and has(t.ratio(cs, cb, 0, ckh)));
        c.ci = .{
            .known = .{ if (self_sized) NONE else @max(clampO(ckw, cb.min[0], cb.max[0]), cb.pb[0]), ckh },
            .parent = .{ tw, NONE },
            .avail = .{ tw, MAXC },
            .layout = place,
        };
        try t.computeNode(ch, &c.ci, &c.co);
        // ResolveInlineAutoMargins
        const free = tw - c.co.size[0] - ms;
        if (cb.margin_auto[0] and cb.margin_auto[2]) {
            cb.margin[0] = @max(t.div(free, 2), 0);
            cb.margin[2] = @max(free - cb.margin[0], 0);
        } else if (cb.margin_auto[0]) {
            cb.margin[0] = @max(free, 0);
        } else if (cb.margin_auto[2]) cb.margin[2] = @max(free, 0);
        y += cb.margin[1];
        if (place) t.setLayout(ch, .{ cb.margin[0], y }, &c.co, cb);
        y += c.co.size[1] + cb.margin[3];
    }
    return y - y0;
}

/// Blink's ComputeMinimumRowBlockSize: measures each cell of row `ri` at the width of its columns.
noinline fn rowMin(t: anytype, c: *S, ri: u32, sec_collapsed: bool) Error!void {
    const q = c.q;
    const row = &c.rows[ri];
    var max_h: f32 = 0;
    var row_pct: f32 = NONE;
    var constrained = false;
    var span_start = false;
    c.tab = .{};
    for (row.first..row.first + row.n) |i| {
        const cell = &c.cells[i];
        const w = spanW(c, cell, 0);
        const is_bl = cell.valign == .baseline;
        var hl: TL = .{};
        var content_box = false;
        var bp = cell.border[1] + cell.border[3];
        var bend = cell.border[3];
        var bl: f32 = NONE;
        if (cell.anon) {
            try anonCell(t, c, i, w, NONE, false, 0, 0);
            if (!c.in.layout) c.did_layout = true;
            cell.mh = c.an_h;
            bl = c.an_bl;
        } else {
            const cs = styleOf(t, cell.node);
            cellBox(t, c, i, c.grid_w);
            bp += c.cb.padding[1] + c.cb.padding[3];
            bend += c.cb.padding[3];
            const need_bl = is_bl and cell.has_content;
            c.ci = .{ .known = .{ w, NONE }, .parent = .{ c.grid_w, NONE }, .content_sizing = true, .cs_axis = 1, .layout = need_bl };
            try cellCompute(t, c, i, false);
            if (need_bl and !c.in.layout) c.did_layout = true;
            cell.mh = c.co.size[1];
            if (need_bl) bl = c.co.baseline;
            hl = tableLen(q, cs.size[1]);
            content_box = cs.box_sizing == .content_box;
        }
        // (a baseline-aligned cell without a baseline uses the bottom of its content box)
        if (is_bl and !has(bl)) bl = cell.mh - bend;
        cell.constrained = has(hl.fixed);
        const spanned = cell.eff > 1;
        constrained = constrained or (cell.constrained and !spanned);
        c.tab.process(cell.mh, bl, bend, is_bl, cell.has_content, spanned, cell.pct_dep);
        const css_h: f32 = if (has(hl.fixed)) (if (content_box) hl.fixed + bp else @max(hl.fixed, bp)) else NONE;
        if (spanned) {
            span_start = true;
            if (c.n_rs < c.rs.len) {
                c.rs[c.n_rs] = .{ .start = ri, .span = cell.eff, .min = maxO(cell.mh, css_h) };
                c.n_rs += 1;
            }
        } else {
            if (has(css_h) or has(hl.pct)) constrained = true;
            if (has(hl.pct)) row_pct = @max(orElse(row_pct, 0), hl.pct);
            max_h = @max(@max(max_h, cell.mh), orElse(css_h, 0));
        }
    }
    var collapsed = sec_collapsed;
    if (row.node != no_node) {
        // A resumed row keeps the block size its first fragment's table assigned.
        // Reflow at a wider page can end the cell text early; it does not discard
        // the row's remaining block space (takumi RowLayoutAlgorithm::given_block_size).
        if (comptime @import("style.zig").frag_enabled) for (t.paged.row_minimums) |minimum| {
            if (minimum.node == row.node) {
                max_h = @max(max_h, minimum.height);
            }
        };
        const rsty = styleOf(t, row.node);
        const rl = tableLen(q, rsty.size[1]);
        if (has(rl.pct)) {
            constrained = true;
            row_pct = @max(orElse(row_pct, 0), rl.pct);
        } else if (has(rl.fixed)) {
            constrained = true;
            max_h = @max(max_h, rl.fixed);
        }
        collapsed = collapsed or rsty.visibility_collapse;
    }
    row.h = c.tab.rowBlockSize(max_h);
    // (a baseline that a percentage block size may move is found again as the row lays out)
    row.bl = if (c.tab.depends()) NONE else c.tab.baseline(row.h);
    row.pct = row_pct;
    row.constrained = constrained;
    row.span_start = span_start;
    row.collapsed = collapsed;
}

/// Blink's ComputeRows up to the sections' minimum block sizes; returns their sum.
noinline fn computeRows(t: anytype, c: *S) Error!f32 {
    const q = c.q;
    const sv = c.spacing[1];
    var total_min: f32 = 0;
    for (c.secs[0..c.n_secs]) |*sec| {
        const sec_sty: ?*const st.Style = if (sec.node != no_node) styleOf(t, sec.node) else null;
        const sec_collapsed = if (sec_sty) |s| s.visibility_collapse else false;
        c.n_rs = 0;
        var total_pct: f32 = 0;
        for (0..sec.n_rows) |k| {
            const ri: u32 = sec.start + @as(u32, @intCast(k));
            try rowMin(t, c, ri, sec_collapsed);
            const row = &c.rows[ri];
            if (has(row.pct)) {
                row.pct = @min(100 - total_pct, row.pct);
                total_pct += row.pct;
            }
        }
        const rows = c.rows[sec.start .. sec.start + sec.n_rows];
        if (c.n_rs > 0) {
            const idx = c.idx[0..c.n_rs];
            for (idx, 0..) |*v, i| v.* = @intCast(i);
            mergeSort(idx, c.idx[c.idx.len / 2 ..][0..c.n_rs], @as([]const RowSpan, c.rs[0..c.n_rs]), rowspanLess);
            for (idx) |i| {
                const r = &c.rs[i];
                distributeExcess(q, c.rows[r.start..@min(r.start + r.span, c.n_rows)], r.min, true, sv, NONE);
            }
        }
        var sh: f32 = 0;
        for (rows) |*row| sh += row.h;
        if (rows.len > 1) sh += sv * @as(f32, @floatFromInt(rows.len - 1));
        var sl: TL = .{};
        if (sec_sty) |s| sl = tableLen(q, s.size[1]);
        if (has(sl.fixed) and sl.fixed > sh) {
            distributeExcess(q, rows, sl.fixed, false, sv, sl.fixed);
            sh = sl.fixed;
        }
        sec.h = sh;
        sec.pct = sl.pct;
        sec.constrained = has(sl.fixed) or has(sl.pct);
        total_min += sh;
    }
    return total_min;
}

fn shiftNodes(t: anytype, first: u32, last: u32, off: f32) void {
    if (off == 0) return;
    var ch = first;
    while (ch != no_node) : (ch = t.nextSibling(ch)) {
        if (!skipped(styleOf(t, ch))) t.layouts.items[ch].y += off;
        if (ch == last) break;
    }
}

/// Blink's TableSectionLayoutAlgorithm + TableRowLayoutAlgorithm: lays every cell out at the block size of
/// the rows it spans, aligns its content, and writes the layouts of cells, rows and sections.
noinline fn placeCells(t: anytype, c: *S, height_specified: bool, sv: f32) Error!void {
    const q = c.q;
    for (c.secs[0..c.n_secs]) |*sec| {
        const sec_real = sec.node != no_node and sec.node != c.node;
        const sec_pos: [2]f32 = .{ c.sec_x, sec.y };
        for (0..sec.n_rows) |k| {
            const ri = sec.start + k;
            const row = &c.rows[ri];
            const row_real = row.node != no_node and row.node != c.node;
            const row_y = sec_pos[1] + row.y;
            // origin of the cells' parent node in table coordinates
            const ox: f32 = if (row_real or sec_real) sec_pos[0] else 0;
            const oy: f32 = if (row_real) row_y else if (sec_real) sec_pos[1] else 0;
            c.tab = .{};
            for (row.first..row.first + row.n) |i| {
                const cell = &c.cells[i];
                // ComputeCellBlockSize
                var span_h: f32 = 0;
                if (!row.collapsed) {
                    for (0..cell.eff) |o| {
                        if (ri + o >= c.n_rows) break;
                        const r2 = &c.rows[ri + o];
                        if (r2.collapsed) continue;
                        span_h += r2.h;
                        if (o != 0) span_h += sv;
                    }
                }
                const h = if (cell.eff > 1) span_h else row.h;
                const indef = !(cell.constrained or (span_h > cell.mh and height_specified));
                cell.w = spanW(c, cell, 1);
                cell.h = h;
                cell.x = (if (cell.col < c.n_cols) c.cols[cell.col].off[1] else 0) - c.spacing[0];
                if (c.rtl) cell.x = c.sec_w - cell.x - cell.w;
                const px = sec_pos[0] + cell.x - ox;
                const py = row_y - oy;
                if (cell.anon) {
                    try anonCell(t, c, i, cell.w, if (indef) NONE else @max(h - cell.border[1] - cell.border[3], 0), true, px, py);
                    cell.fbl = c.an_bl;
                    cell.bend = cell.border[3];
                    cell.ih = c.an_h;
                } else {
                    c.ci = .{ .known = .{ cell.w, h }, .parent = .{ c.sec_w, NONE }, .layout = true, .indef_h = indef };
                    try cellCompute(t, c, i, true);
                    cell.fbl = c.co.baseline;
                    cell.cont = c.co.content;
                    cellBox(t, c, i, c.sec_w);
                    cell.bend = c.cb.border[3] + c.cb.padding[3];
                    cell.ih = cell.mh;
                    if ((cell.pct_dep and !indef) or cell.w != spanW(c, cell, 0)) {
                        // percentages resolved against the cell's block size, or a narrower cell (collapsed
                        // columns): its content is not what was measured
                        var bottom = c.cb.border[1] + c.cb.padding[1];
                        var kid = t.firstChild(cell.node);
                        while (kid != no_node) : (kid = t.nextSibling(kid)) {
                            if (skipped(styleOf(t, kid))) continue;
                            const l = &t.layouts.items[kid];
                            bottom = @max(bottom, l.y + l.h + l.margin.bottom);
                        }
                        cell.ih = bottom + cell.bend;
                    }
                }
                const is_bl = cell.valign == .baseline;
                c.tab.process(h, if (is_bl) orElse(cell.fbl, cell.ih - cell.bend) else NONE, cell.bend, is_bl, cell.has_content, cell.eff > 1, cell.pct_dep);
            }
            if (!has(row.bl)) row.bl = c.tab.baseline(row.h);
            c.tab = .{};
            for (row.first..row.first + row.n) |i| {
                const cell = &c.cells[i];
                // FinalizeTableCellLayout: the free space goes above the content
                // (middle / bottom are safe alignments: overflowing content stays at the top)
                const free = @max(cell.h - cell.ih, 0);
                const bl = orElse(cell.fbl, cell.ih - cell.bend);
                const off: f32 = switch (cell.valign) {
                    .top => 0,
                    .middle => divI(q, free, 2),
                    .bottom => free,
                    .baseline => if (cell.has_content) row.bl - bl else 0,
                };
                c.tab.process(cell.h, bl + off, cell.bend, cell.valign == .baseline, cell.has_content, cell.eff > 1, cell.pct_dep);
                if (cell.anon) {
                    shiftNodes(t, cell.node, cell.last, off);
                    continue;
                }
                shiftNodes(t, t.firstChild(cell.node), no_node, off);
                cellBox(t, c, i, c.sec_w);
                c.co = .{ .size = .{ cell.w, cell.h }, .content = .{ cell.cont[0], cell.cont[1] + @max(off, 0) }, .baseline = bl + off };
                t.setLayout(cell.node, .{ sec_pos[0] + cell.x - ox, row_y - oy }, &c.co, &c.cb);
            }
            row.fbl = c.tab.baseline(row.h);
            if (row_real) {
                zeroBox(&c.cb);
                c.co = .{ .size = .{ c.sec_w, row.h }, .content = .{ c.sec_w, row.h }, .baseline = row.fbl };
                t.setLayout(row.node, .{ if (sec_real) 0 else sec_pos[0], if (sec_real) row.y else row_y }, &c.co, &c.cb);
            }
        }
        if (sec_real) {
            zeroBox(&c.cb);
            c.co = .{ .size = .{ c.sec_w, sec.hf }, .content = .{ c.sec_w, sec.hf } };
            if (sec.n_rows > 0) c.co.baseline = c.rows[sec.start].y + c.rows[sec.start].fbl;
            t.setLayout(sec.node, sec_pos, &c.co, &c.cb);
        }
    }
}

/// display:none and out-of-flow children of a table part: hidden / placed against the part's box
/// (`x`, `y`, `w`, `h`: its padding box in its own coordinates; static position at `sx`, `sy`).
noinline fn strays(t: anytype, c: *S, container: u32, area: [4]f32, sx: f32, sy: f32) Error!void {
    var ch = t.firstChild(container);
    while (ch != no_node) : (ch = t.nextSibling(ch)) {
        const cs = styleOf(t, ch);
        if (cs.display == .none) {
            t.hide(ch);
        } else if (c.is_table and container == c.node and (cs.display == .table_column or cs.display == .table_column_group)) {
            // (columns and column groups generate no box)
            t.hide(ch);
        } else if (cs.position.isOut()) {
            c.area = area;
            c.sp = .{ .rect = .{ sx, sy, area[2], 0 } };
            try t.placeAbsolute(container, ch, &c.area, &c.sp);
        }
    }
}

/// A size-only request laid cells out (for their baselines): layouts below the table changed, so no final
/// result of the table or of an ancestor may be reused.
noinline fn invalidateFinals(t: anytype, node: u32) void {
    var n = node;
    var guard: u32 = 0;
    while (n != no_node and guard <= tr.max_depth) : (guard += 1) {
        t.caches.items[n].valid &= 0x7fff;
        n = t.nodes.items[n].parent;
    }
}

/// Blink's AllowColumnPercentages: a table inside a cell, flex item or grid item does not let column
/// percentages widen its max-content size.
noinline fn allowsIntrinsicPct(t: anytype, node: u32) bool {
    var child = node;
    var p = t.nodes.items[node].parent;
    var guard: u32 = 0;
    while (p != no_node and guard <= tr.max_depth) : (guard += 1) {
        const pd = styleOf(t, p).display;
        const cd = styleOf(t, child).display;
        switch (pd) {
            .flex, .grid, .table_cell, .table_row => return false,
            .table_row_group, .table_header_group, .table_footer_group => if (cd != .table_row) return false,
            .table, .inline_table => if (cd != .table_caption and !isSection(cd)) return false,
            else => {},
        }
        child = p;
        p = t.nodes.items[p].parent;
    }
    return true;
}

pub noinline fn compute(t: anytype, node: u32, in_: *const In, out: *Out) Error!void {
    {
        // a row / row group as a flex or grid item is blockified (its cells then stack as blocks)
        const d = styleOf(t, node).display;
        const par = t.nodes.items[node].parent;
        if (!d.isTable() and par != no_node) {
            const pd = styleOf(t, par).display;
            if (pd == .flex or pd == .grid) return block.compute(t, node, in_, out);
        }
    }
    const mark = t.scratch.mark();
    defer t.scratch.release(mark);
    const c = try t.scratch.create(t.alloc, S);
    c.in = in_.*;
    const in = &c.in;
    const s = styleOf(t, node);
    const q = t.q64;
    c.node = node;
    c.q = q;
    c.is_table = s.display.isTable();
    // (the anonymous table around a stray row / row group takes the direction of the node's parent)
    c.rtl = if (c.is_table) s.rtl else if (t.nodes.items[node].parent != no_node) styleOf(t, t.nodes.items[node].parent).rtl else false;
    c.collapse = s.border_collapse;
    c.fixed = c.is_table and s.table_fixed and s.size[0] != .auto and s.size[0] != .max_content;
    c.did_layout = false;
    c.has_collapsed = false;
    c.dry = false;
    c.grid_ok = false;
    c.content = .{ 0, 0 };
    c.bc = 0;
    c.spacing = .{ 0, 0 };
    if (!c.collapse) {
        for (0..2) |a| c.spacing[a] = if (s.border_spacing[a] > 0 and std.math.isFinite(s.border_spacing[a])) lu(q, @min(s.border_spacing[a], 1e6)) else 0;
    }

    // ---- structure
    gather(t, c, false);
    c.secs = try arr(t, Sec, c.n_secs);
    c.rows = try arr(t, Row, c.n_rows);
    c.cells = try arr(t, Cell, c.n_cells);
    c.spans = try arr(t, Span, @as(usize, c.n_cells) * 2);
    c.col_cap = 1000 +| 4 *| (c.n_cells +| c.n_colnodes);
    gather(t, c, true);
    // rows and row groups are not computed through computeNode: account for their nesting levels
    var levels: u32 = 1;
    for (c.secs) |*sec| {
        if (sec.node != no_node and sec.node != node) levels = 2;
    }
    t.depth += levels;
    defer t.depth -= levels;
    assignColumns(c);
    const n_elem = visitCols(t, c, c.col_cap, 0);
    c.cols = try arr(t, Col, @max(n_elem, c.n_cellcols));
    c.sizes = try arr(t, f64, c.cols.len);
    c.cc = try arr(t, CellC, c.n_cellcols);
    c.cs = try arr(t, CellC, c.n_spancells);
    c.rs = try arr(t, RowSpan, c.n_rowspans);
    c.idx = try arr(t, u32, 2 * @as(usize, @max(c.n_spancells, c.n_rowspans)));
    c.n_cols = visitCols(t, c, c.col_cap, 1);

    // ---- the table box
    if (c.is_table) t.sbox(&c.box, s, in) else zeroBox(&c.box);
    const box = &c.box;
    for (&box.border) |*b| {
        // (untrusted styles: resolveBox lets an infinite border width through)
        if (!std.math.isFinite(b.*)) b.* = 0;
    }
    setBorder(box, box.border);
    // (content sizing: the parent applies the size styles itself and asks for the size without them)
    for (0..2) |a| {
        if (in.content_sizing and !has(in.known[a])) box.size[a] = NONE;
    }
    if (c.collapse) {
        // the collapsed-border grid ends at the last column a cell or a sized <col> reaches
        var nm: u32 = 0;
        for (c.cols[0..c.n_cols], 0..) |*col, i| {
            if (!col.mergeable) nm = @intCast(i + 1);
        }
        c.bc = @max(nm, c.n_cellcols);
        const grid_ok = try computeBorders(t, c);
        c.grid_ok = grid_ok;
        if (!grid_ok) {
            for (c.cells) |*cell| {
                if (cell.anon) continue;
                const b = styleOf(t, cell.node).border;
                cell.border = .{ bw(c, b.left), bw(c, b.top), bw(c, b.right), bw(c, b.bottom) };
            }
        } else if (c.is_table) {
            // a collapsing table has no padding and half of its outer edges as border
            const old = box.pb;
            box.padding = .{ 0, 0, 0, 0 };
            setBorder(box, edgeBorders(c, 0, 0, c.n_rows, c.bc));
            if (s.box_sizing == .content_box) {
                for (0..2) |a| {
                    box.size[a] += box.pb[a] - old[a];
                    box.min[a] += box.pb[a] - old[a];
                    box.max[a] += box.pb[a] - old[a];
                }
            }
        }
    } else {
        for (c.cells) |*cell| {
            if (cell.anon) continue;
            const b = styleOf(t, cell.node).border;
            cell.border = .{ bw(c, b.left), bw(c, b.top), bw(c, b.right), bw(c, b.bottom) };
        }
    }
    const pb = box.pb;

    // What a `known` size means depends on who set it:
    //  * a block container, the root and absolute positioning pre-resolve it from the styles, which a table
    //    treats as minimums: dropped, the table sizes itself in the containing width
    //  * the main size of a flex item is fixed (Blink's is_fixed_inline_size / is_fixed_block_size)
    //  * a cross size of a flex item or a grid area is a stretch: the table is at least as large as its
    //    content, and as wide as its columns
    var known = in.known;
    var avail = in.avail[0];
    var fixed_w = false;
    var fixed_h = false;
    {
        const par = t.nodes.items[node].parent;
        const flow = node == t.root or par == no_node or s.position.isOut() or switch (styleOf(t, par).display) {
            .block, .table_cell, .table_caption, .table_column, .table_column_group => true,
            else => false,
        };
        if (flow) {
            if (has(known[0])) avail = if (has(in.parent[0])) in.parent[0] else MAXC;
            known = .{ NONE, NONE };
        } else if (styleOf(t, par).display == .flex) {
            const dir = styleOf(t, par).flex_direction;
            fixed_w = dir == .row or dir == .row_reverse;
            fixed_h = !fixed_w;
        }
    }
    fixed_w = fixed_w and has(known[0]);
    fixed_h = fixed_h and has(known[1]);
    // a stretch only applies to an automatic size, and a cross size that is not the stretched one is just
    // the table's own measured size: in both cases the table sizes itself (fit-content in the containing width)
    if (!fixed_w and has(known[0])) {
        const stretched = !has(in.parent[0]) or @abs(known[0] + box.marginSum(0) - in.parent[0]) < 0.02;
        if (has(box.size[0]) or !stretched) {
            known[0] = NONE;
            avail = if (has(in.parent[0])) in.parent[0] else MAXC;
        }
    }
    if (!fixed_h and has(known[1]) and has(box.size[1])) known[1] = NONE;

    // ---- inline sizes
    try columnConstraints(t, c);
    var n_taking: f32 = 0;
    for (c.cols[0..c.n_cols]) |*col| n_taking += @floatFromInt(@intFromBool(!col.mergeable));
    // ComputeUndistributableTableSpace
    const undist: f64 = @as(f64, pb[0]) + @as(f64, c.spacing[0]) * (2 + @max(n_taking - 1, 0));
    if (c.n_caps > 0) try captionMin(t, c) else c.cap_min = 0;
    const w_style: st.Dim = if (c.is_table) s.size[0] else .auto;
    const allow_pct = w_style != .max_content;
    var assignable: f64 = undefined;
    if (fixed_w) {
        assignable = @max(@as(f64, known[0]) - undist, 0);
    } else if (has(known[0])) {
        const mm = gridMinMax(c, undist, allow_pct);
        assignable = @max(@max(@as(f64, known[0]), mm[0]), @as(f64, c.cap_min)) - undist;
    } else {
        var mm = gridMinMax(c, undist, allow_pct);
        const intrinsic = !tr.isDef(avail);
        if (intrinsic) {
            // ComputeMinMaxSizes
            mm = gridMinMax(c, undist, allow_pct and allowsIntrinsicPct(t, node));
            mm[0] = @max(mm[0], c.cap_min);
            mm[1] = @max(mm[1], c.cap_min);
            if (c.fixed and w_style == .percent) mm[1] = table_max_inline;
            mm[1] = @max(mm[1], mm[0]);
        }
        var extent: f64 = box.size[0];
        if (!hasW(extent)) extent = switch (w_style) {
            .min_content => mm[0],
            .max_content => mm[1],
            // fit-content
            else => @min(mm[1], @max(mm[0], @as(f64, avail - box.marginSum(0)))),
        };
        // tables can't shrink below their min-intrinsic size
        const lo = @max(@as(f64, orElse(box.min[0], 0)), mm[0]);
        const hi = @max(@as(f64, orElse(box.max[0], MAXC)), lo);
        const used = @max(@max(@min(extent, hi), lo), @as(f64, c.cap_min));
        if (intrinsic and in.width_only) {
            out.* = .{ .size = .{ ff(used), NONE } };
            return;
        }
        assignable = used - undist;
    }
    if (c.fixed) sizesFixed(c, assignable) else {
        distributeAuto(q, assignable, c.cols[0..c.n_cols], true, c.sizes);
        for (c.cols[0..c.n_cols], c.sizes[0..c.n_cols]) |*col, sz| col.size = sz;
    }
    locations(c, 0);
    locations(c, 1);
    const empty = c.n_cols == 0;
    // ComputeEmptyTableInlineSize
    const empty_w: f32 = if (fixed_w or w_style != .auto or (c.is_table and s.min_size[0] != .auto))
        ff(assignable + undist)
    else if (c.cap_min > 0)
        @max(c.cap_min, pb[0])
    else if (c.collapse) 0 else ff(assignable + pb[0]);
    const before = if (empty) empty_w else sizeFromCols(c, 0);
    c.tbl_w = if (fixed_w) known[0] else if (empty) empty_w else @max(sizeFromCols(c, 1), c.cap_min);
    c.grid_w = before - pb[0];
    if (in.width_only) {
        out.* = .{ .size = .{ c.tbl_w, NONE } };
        return;
    }

    // ---- block sizes
    c.top_h = 0;
    c.bot_h = 0;
    if (c.n_caps > 0) {
        c.top_h = try captions(t, c, false, in.layout, 0);
        c.bot_h = try captions(t, c, true, false, 0);
    }
    const total_min = try computeRows(t, c);
    // (a table stretched in a row flex line that pagination grew past the line's end: its rows'
    // minimum block sizes, which every block size it had shares out again, fragment.zig `TableStretch`)
    const stretch_segs = stretchOf(t, node);
    var min_rows: []f32 = &.{};
    var min_secs: []f32 = &.{};
    if (stretch_segs != null) {
        min_rows = try arr(t, f32, c.rows.len);
        for (min_rows, c.rows) |*h, *row| h.* = row.h;
        min_secs = try arr(t, f32, c.secs.len);
        for (min_secs, c.secs) |*h, *sec| h.* = sec.h;
    }
    // the table's block size to share among its sections (Blink's css_table_block_size)
    var tbs: f32 = NONE;
    if (has(known[1])) {
        tbs = @max(known[1] - c.top_h - c.bot_h, 0);
    } else if (!in.flex_main) {
        var h = box.size[1];
        if (!has(h) and has(box.min[1])) h = pb[1];
        if (has(h)) {
            const lo = orElse(box.min[1], 0);
            tbs = @max(@max(@min(h, @max(orElse(box.max[1], MAXC), lo)), lo), pb[1]);
        }
    }
    c.min_grid_h = 0;
    if (has(tbs)) {
        c.min_grid_h = tbs;
        const distributable = @max(tbs - pb[1], 0);
        if (distributable > total_min) distributeToSections(c, distributable);
    }
    if (stretch_segs) |segs| {
        // each row takes the block size the table shared out when the fragment it is in was laid
        // out (each time over the rows as the size before left them: takumi / Blink keep the rows
        // in the break token); the grid is its rows (the line it stretches to has grown with them)
        const heights = try arr(t, f32, c.rows.len);
        for (c.rows, min_rows) |*row, h| row.h = h;
        for (c.secs, min_secs) |*sec, h| sec.h = h;
        for (segs, 0..) |seg, si| {
            for (c.secs) |*sec| sec.redist = false;
            const distributable = @max(seg.size - pb[1], 0);
            if (distributable > total_min) distributeToSections(c, distributable);
            const end = @min(if (si + 1 < segs.len) segs[si + 1].row else c.rows.len, c.rows.len);
            var r: usize = @min(seg.row, end);
            while (r < end) : (r += 1) heights[r] = c.rows[r].h;
        }
        for (c.rows, heights) |*row, h| row.h = h;
        c.min_grid_h = 0;
    }
    for (c.rows) |*row| {
        if (!row.collapsed) continue;
        // collapsed rows take no block size and shrink the table's minimum
        if (c.min_grid_h != 0) {
            c.min_grid_h -= row.h;
            if (c.n_rows > 1) c.min_grid_h -= c.spacing[1];
        }
        row.h = 0;
    }

    // ---- stacking (Blink's GenerateFragment)
    const sh: f32 = if (empty) 0 else c.spacing[0];
    const sv: f32 = if (empty) 0 else c.spacing[1];
    c.sec_w = @max(c.tbl_w - pb[0] - sh * 2, 0);
    c.sec_x = box.border[0] + box.padding[0] + sh;
    {
        var y = c.top_h;
        const start = y;
        y += box.border[1] + box.padding[1];
        var after: f32 = 0;
        for (c.secs) |*sec| {
            const childless = y;
            y += sv;
            var off: f32 = 0;
            var first_nc = true;
            for (c.rows[sec.start .. sec.start + sec.n_rows]) |*row| {
                if (!first_nc and !row.collapsed) off += sv;
                if (comptime @import("style.zig").frag_enabled) for (t.paged.row_minimums) |minimum| {
                    if (minimum.node == row.node) if (minimum.top) |settled| {
                        off = @max(off, settled);
                    };
                };
                row.y = off;
                off += row.h;
                first_nc = first_nc and row.collapsed;
            }
            sec.hf = if (sec.n_rows == 0) sec.h else off;
            // an empty section takes no border spacing before it
            if (sec.n_rows == 0) y = childless;
            sec.y = y;
            y += sec.hf;
            after = sv;
        }
        // EndTableBoxLayout
        const end = y + after + box.border[3] + box.padding[3];
        y = start + @max(end - start, c.min_grid_h);
        c.bottom_y = y;
        y += c.bot_h;
        c.block_size = if (fixed_h and stretch_segs == null) known[1] else if (fixed_h) @max(known[1], y) else @max(y, 0);
    }
    if (!in.layout) {
        if (c.did_layout) invalidateFinals(t, node);
        out.* = .{ .size = .{ c.tbl_w, c.block_size } };
        return;
    }

    // ---- final layout
    try placeCells(t, c, c.is_table and s.size[1] != .auto, sv);
    if (c.n_caps > 0) _ = try captions(t, c, true, true, c.bottom_y);
    const grid_h = c.bottom_y - c.top_h;
    try strays(t, c, node, .{ box.border[0], c.top_h + box.border[1], c.tbl_w - box.border[0] - box.border[2], grid_h - box.border[1] - box.border[3] }, box.border[0] + box.padding[0], c.top_h + box.border[1] + box.padding[1]);
    for (c.secs) |*sec| {
        if (sec.node != no_node and sec.node != node) try strays(t, c, sec.node, .{ 0, 0, c.sec_w, sec.hf }, 0, 0);
    }
    for (c.rows) |*row| {
        if (row.node != no_node and row.node != node) try strays(t, c, row.node, .{ 0, 0, c.sec_w, row.h }, 0, 0);
    }
    var first_bl: f32 = NONE;
    for (c.secs) |*sec| {
        if (sec.n_rows == 0) continue;
        const row = &c.rows[sec.start];
        first_bl = sec.y + row.y + row.fbl;
        break;
    }
    c.content = .{ c.tbl_w, c.block_size };
    {
        var ch = t.firstChild(node);
        while (ch != no_node) : (ch = t.nextSibling(ch)) {
            if (styleOf(t, ch).display != .none) t.accumContent(&c.content, ch);
        }
    }
    // a collapsing table has no padding and half of its outer edges as border: reported in its Layout (the
    // parent's setLayout keeps both, see Tree.setLayout)
    const used_box = c.collapse and c.is_table and (box.padding[0] + box.padding[1] + box.padding[2] + box.padding[3] == 0);
    t.nodes.items[node].table_box = used_box;
    if (used_box) {
        t.layouts.items[node].border = tr.toEdges(box.border);
        t.layouts.items[node].padding = .all(0);
    }
    try recordGeom(t, c);
    out.* = .{ .size = .{ c.tbl_w, c.block_size }, .content = c.content, .baseline = first_bl };
}
