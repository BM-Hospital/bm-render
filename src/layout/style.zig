//! Style inputs for the layout engine. Plain data; the integrator maps parsed CSS onto `Style`.
//! Defaults follow what takumi containers need most often (flex, border-box), NOT the CSS initial values.

/// `calc()` reduced to a length plus a percentage: px + percent * basis.
pub const Calc = struct {
    px: f32 = 0,
    /// 0..1 fraction
    percent: f32 = 0,
};

/// Size-like value: `auto`, pixels, or a fraction (0..1) of the containing dimension.
pub const Dim = union(enum) {
    auto,
    px: f32,
    /// 0..1 fraction (50% == 0.5)
    percent: f32,
    /// px + percent * basis; behaves as auto where a percentage would (indefinite basis)
    calc: Calc,
    /// Intrinsic sizing keywords. Only meaningful for `size` (width/height) and `flex_basis`; as a height,
    /// min/max size, margin or inset they behave as `auto`.
    min_content,
    max_content,
    fit_content,

    /// true when the value depends on the containing size
    pub fn hasPercent(d: Dim) bool {
        return d == .percent or (d == .calc and d.calc.percent != 0);
    }
    pub fn isKeyword(d: Dim) bool {
        return d == .min_content or d == .max_content or d == .fit_content;
    }
};

/// Length or percentage (fraction 0..1). Used for padding and gap.
pub const LengthPercentage = union(enum) {
    px: f32,
    percent: f32,
    /// px + percent * basis (the percentage part is 0 against an indefinite basis)
    calc: Calc,

    pub fn hasPercent(d: LengthPercentage) bool {
        return d == .percent or (d == .calc and d.calc.percent != 0);
    }
};

pub fn Edges(comptime T: type) type {
    return struct {
        top: T,
        right: T,
        bottom: T,
        left: T,

        pub fn all(v: T) @This() {
            return .{ .top = v, .right = v, .bottom = v, .left = v };
        }
    };
}

pub const Display = enum(u8) {
    flex,
    block,
    grid,
    none,
    /// `display: table` (block-level table wrapper + grid box). See table.zig.
    table,
    /// `display: inline-table`: lays out like `table` (it only differs as a child of an `inline_row`).
    inline_table,
    table_row_group,
    table_header_group,
    table_footer_group,
    table_row,
    table_cell,
    table_caption,
    table_column,
    table_column_group,
    /// Anonymous line container: its children (atomic inline boxes and measured text leaves) are laid out
    /// left to right on wrapping lines. See inline.zig.
    inline_row,

    pub fn isTablePart(d: Display) bool {
        return @backingInt(d) >= @backingInt(Display.table_row_group) and @backingInt(d) <= @backingInt(Display.table_column_group);
    }
    pub fn isTable(d: Display) bool {
        return d == .table or d == .inline_table;
    }
};
/// `static` only matters for absolutely positioned descendants: a static box is not their containing block.
/// `fixed` is absolute positioning against the initial containing block (the `available` size of `compute`,
/// positioned at the root's containing-block origin) whatever the ancestors are.
pub const Position = enum(u8) {
    relative,
    absolute,
    static,
    fixed,

    /// absolute or fixed
    pub inline fn isOut(p: Position) bool {
        return p == .absolute or p == .fixed;
    }
};
pub const Float = enum(u8) { none, left, right };
pub const Clear = enum(u8) { none, left, right, both };
/// Alignment of a table cell's content / of an inline-level box on its line.
pub const VerticalAlign = enum(u8) { baseline, top, middle, bottom };
pub const TextAlign = enum(u8) { start, center, end, justify };
/// `safe` keyword per alignment property (overflowing content falls back to `start`); the default is the
/// property's normal behaviour (`unsafe` for explicit alignments).
pub const AlignSafe = packed struct(u8) {
    align_items: bool = false,
    align_self: bool = false,
    align_content: bool = false,
    justify_content: bool = false,
    justify_items: bool = false,
    justify_self: bool = false,
    _pad: u2 = 0,
};
pub const BoxSizing = enum(u8) { border_box, content_box };
pub const Overflow = enum(u8) { visible, hidden, scroll, clip };
pub const FlexDirection = enum(u8) { row, column, row_reverse, column_reverse };
pub const FlexWrap = enum(u8) { nowrap, wrap, wrap_reverse };

/// One enum for every alignment property. `null` in `Style` means `normal`/`auto`.
/// Values that are invalid for a given property fall back to `start`
/// (e.g. `space_between` for align-items) or `flex_start` (`stretch` for flex justify-content).
pub const Align = enum(u8) {
    start,
    end,
    flex_start,
    flex_end,
    center,
    stretch,
    baseline,
    space_between,
    space_around,
    space_evenly,
};

/// One side of a grid track sizing function.
pub const TrackBreadth = union(enum) {
    px: f32,
    /// 0..1 fraction of the grid container's content box
    percent: f32,
    /// flex factor; only meaningful as `max`
    fr: f32,
    auto,
    min_content,
    max_content,
    /// fit-content(limit); only meaningful as `max` (with `min = .auto`)
    fit_content: LengthPercentage,
};

/// Grid track sizing function `minmax(min, max)`.
/// `repeat(n, ...)` must be pre-expanded by the caller; see `AutoRepeat` for auto-fill/auto-fit.
pub const Track = struct {
    min: TrackBreadth = .auto,
    max: TrackBreadth = .auto,
    /// Track-set id. Tracks produced by one `repeat(n, <one track>)` share a non-zero id: Blink sizes them as
    /// one set and splits the set's size between its tracks (remainder layout units go to the first ones).
    /// 0 = a set of its own.
    set: u16 = 0,

    pub const auto: Track = .{};
    pub const min_content: Track = .{ .min = .min_content, .max = .min_content };
    pub const max_content: Track = .{ .min = .max_content, .max = .max_content };
    pub fn px(v: f32) Track {
        return .{ .min = .{ .px = v }, .max = .{ .px = v } };
    }
    pub fn percent(v: f32) Track {
        return .{ .min = .{ .percent = v }, .max = .{ .percent = v } };
    }
    /// `<flex>` == minmax(auto, <flex>)
    pub fn fr(v: f32) Track {
        return .{ .min = .auto, .max = .{ .fr = v } };
    }
    pub fn minmax(mn: TrackBreadth, mx: TrackBreadth) Track {
        return .{ .min = mn, .max = mx };
    }
    pub fn fitContent(limit: LengthPercentage) Track {
        return .{ .min = .auto, .max = .{ .fit_content = limit } };
    }
};

/// `repeat(auto-fill | auto-fit, <tracks>)` inside a track template.
pub const AutoRepeat = struct {
    /// true = auto-fit (empty repeated tracks collapse), false = auto-fill
    fit: bool = false,
    /// the repeated track list (caller-owned)
    tracks: []const Track,
    /// index in the explicit template (grid_template_columns/rows) before which the repetition is inserted
    at: u16 = 0,
};

pub const Line = union(enum) {
    auto,
    /// 1-based grid line; negative counts from the end of the explicit grid (-1 = its last line); 0 is one line
    /// further (the takumi oracle resolves `grid-column: 0` so: Blink's ResolveGridPosition with integer 0)
    line: i16,
    span: u16,
};

pub const Placement = struct {
    start: Line = .auto,
    end: Line = .auto,
};

pub const GridAutoFlow = enum(u8) { row, column, row_dense, column_dense };

/// Pagination (fragment.zig) is compiled with the PDF feature only (`config.enable_pdf` through the root
/// module; on in standalone module tests). With it off `Breaks` is empty and `Style` does not grow.
pub const frag_enabled: bool = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "bm_config") and @hasDecl(root.bm_config, "enable_pdf")) root.bm_config.enable_pdf else true;
};
/// `break-before` / `break-after` for paged output. `avoid` = avoid | avoid-page; `page` = page | always |
/// left | right | recto | verso; `column` = column (no page break, but it outranks `avoid` when the values
/// of adjoining boxes are joined, as in Blink); avoid-column maps to `auto`.
pub const BreakBetween = enum(u8) { auto, avoid, column, page };
/// Fragmentation inputs of a box (only read by `fragment.paginate`).
pub const Breaks = if (frag_enabled) struct {
    before: BreakBetween = .auto,
    after: BreakBetween = .auto,
    /// `break-inside: avoid | avoid-page`
    avoid_inside: bool = false,
    /// `box-decoration-break: clone` (carried for the painter; the layout slices)
    clone: bool = false,
    /// never split across pages (replaced content, `line-clamp` boxes); measured leaves without line
    /// boxes and atomic inline boxes are monolithic anyway
    monolithic: bool = false,
    /// inherited `widows` / `orphans` of the block container that owns the lines (>= 1)
    widows: u8 = 2,
    orphans: u8 = 2,
    /// the `page` property: a page name id (0 = `auto`, the parent's), the caller's numbering; a
    /// change of used page name between block siblings forces a page break (Blink's named pages)
    page: u32 = 0,
} else struct {};

pub const Style = struct {
    display: Display = .flex,
    position: Position = .relative,
    box_sizing: BoxSizing = .border_box,
    /// Only affects the automatic minimum size (min-width:auto -> 0 when not visible) and
    /// block margin collapsing (hidden/scroll establish a formatting context).
    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,

    inset: Edges(Dim) = .all(.auto),
    /// [width, height]
    size: [2]Dim = .{ .auto, .auto },
    min_size: [2]Dim = .{ .auto, .auto },
    max_size: [2]Dim = .{ .auto, .auto },
    /// width / height
    aspect_ratio: ?f32 = null,

    margin: Edges(Dim) = .all(.{ .px = 0 }),
    padding: Edges(LengthPercentage) = .all(.{ .px = 0 }),
    border: Edges(f32) = .all(0),
    /// [column-gap (between columns, along x), row-gap (between rows, along y)]
    gap: [2]LengthPercentage = .{ .{ .px = 0 }, .{ .px = 0 } },

    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .nowrap,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: Dim = .auto,

    align_items: ?Align = null,
    align_self: ?Align = null,
    align_content: ?Align = null,
    justify_content: ?Align = null,
    justify_items: ?Align = null,
    justify_self: ?Align = null,

    // grid container (slices are caller-owned and must outlive `compute`)
    grid_template_columns: []const Track = &.{},
    grid_template_rows: []const Track = &.{},
    grid_auto_columns: []const Track = &.{},
    grid_auto_rows: []const Track = &.{},
    grid_auto_repeat_columns: ?AutoRepeat = null,
    grid_auto_repeat_rows: ?AutoRepeat = null,
    grid_auto_flow: GridAutoFlow = .row,
    // grid item
    grid_column: Placement = .{},
    grid_row: Placement = .{},

    /// flex / grid item order (stable among equal values); the tree order is used when all are 0
    order: i32 = 0,
    /// `safe` alignment keywords
    safe: AlignSafe = .{},
    /// `visibility: collapse` on a flex item (takes no main-axis space but still props up the line's cross
    /// size) or a table row / row group / column (removed, the table keeps its other dimension)
    visibility_collapse: bool = false,

    // block formatting context (floats.zig / block.zig)
    float: Float = .none,
    clear: Clear = .none,
    /// `display: flow-root` (and anything else that makes a block container establish a formatting context)
    flow_root: bool = false,
    /// An absolutely positioned outside list marker whose item has no line of its own to join (its
    /// first content is a flex / grid / table / replaced box): placed at its static position in
    /// the inline axis and with its baseline on the item's first baseline (Blink
    /// `PositionListMarkerBesideChild`: the first in-flow child with one), else at the item's
    /// content-box top (`PositionListMarkerWithoutLineBoxes`). block.zig only.
    list_marker: bool = false,
    /// The node is the inline content of a block container (a measured text leaf or an `inline_row`): with
    /// `Config.inline_fn` it keeps its full width next to floats and its lines are shortened instead of
    /// the whole box avoiding them (flow.zig).
    is_inline_content: bool = false,

    // tables (table.zig)
    col_span: u16 = 1,
    row_span: u16 = 1,
    /// cell content alignment in a table row; alignment of an inline-level box in an `inline_row` line
    vertical_align: VerticalAlign = .baseline,
    /// [horizontal, vertical] px
    border_spacing: [2]f32 = .{ 0, 0 },
    border_collapse: bool = false,
    /// sides whose border-style is `hidden` (their `border` width is 0): in a collapsing table a hidden border
    /// suppresses every other border on its edge (CSS 2.1 §17.6.2.1)
    border_hidden: Edges(bool) = .all(false),
    /// `table-layout: fixed`
    table_fixed: bool = false,
    /// `caption-side: bottom` (on a table-caption box)
    caption_bottom: bool = false,

    /// `direction: rtl`. A flex / grid container is then laid out in mirrored space (Blink lays out in
    /// logical coordinates and converts: x = container width - logical x - width): its own left / right
    /// padding and border and its children's left / right margins and insets swap, and the children are
    /// flipped once placed. In a block container an over-constrained child is aligned to the right and
    /// static positions are at the right edge; a table orders its columns right to left.
    rtl: bool = false,
    /// (engine, set by `appendChild`) the parent is a mirrored (`rtl` flex / grid) container
    mirror_out: bool = false,

    // inline rows (inline.zig)
    text_align: TextAlign = .start,
    /// strut of the line container: every line is at least this tall around its baseline
    strut_ascent: f32 = 0,
    strut_descent: f32 = 0,
    /// Distance from the baseline up to the line where `vertical-align: middle` items are centred
    /// (CSS: half the x-height of the container's font). null = unknown: the middle of the strut is used.
    strut_middle: ?f32 = null,

    /// pagination inputs (empty unless the PDF feature is compiled in)
    breaks: Breaks = .{},
};

pub const AvailableSpace = union(enum) {
    definite: f32,
    min_content,
    max_content,
};
