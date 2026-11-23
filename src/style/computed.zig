//! Computed-style value types and `ComputedStyle` (one per node). All lengths are DEVICE px.
const std = @import("std");
const values = @import("values.zig");
const colorm = @import("color.zig");
const gradient = @import("gradient.zig");

pub const LP = values.LP;
pub const Size = values.Size;
pub const LengthAuto = values.LengthAuto;
pub const Color = colorm.Color;
pub const ColorValue = colorm.ColorValue;
pub const Image = gradient.Image;
pub const Gradient = gradient.Gradient;

/// `webkit_box` / `webkit_inline_box` = `-webkit-box` / `-webkit-inline-box` (legacy flexbox).
pub const Display = enum(u8) { @"inline", block, inline_block, flex, inline_flex, grid, inline_grid, none, contents, flow_root, list_item, table, inline_table, table_row, table_cell, table_row_group, table_header_group, table_footer_group, table_column, table_column_group, table_caption, webkit_box, webkit_inline_box };
pub const Position = enum(u8) { static, relative, absolute, fixed, sticky };
pub const BoxSizing = enum(u8) { border_box, content_box };
pub const Overflow = enum(u8) { visible, hidden, clip, scroll, auto };
pub const Visibility = enum(u8) { visible, hidden, collapse };
pub const FlexDirection = enum(u8) { row, row_reverse, column, column_reverse };
pub const FlexWrap = enum(u8) { nowrap, wrap, wrap_reverse };
/// Box-alignment keyword (justify-*/align-*). `normal` and `auto` are kept distinct.
/// The parser only produces takumi's keywords (no left / right / last_baseline, no `auto` from a declaration:
/// `auto` is the initial value of the *-self properties). `safe` is kept in `ComputedStyle.align_safe`.
pub const Align = enum(u8) { normal, stretch, start, end, flex_start, flex_end, center, baseline, space_between, space_around, space_evenly, auto, left, right, self_start, self_end, last_baseline };
/// `safe` alignment flags, bit-compatible with the layout engine's `AlignSafe`.
pub const AlignSafe = packed struct(u8) {
    align_items: bool = false,
    align_self: bool = false,
    align_content: bool = false,
    justify_content: bool = false,
    justify_items: bool = false,
    justify_self: bool = false,
    _pad: u2 = 0,
};
pub const FlexBasis = union(enum) { auto, content, lp: LP, min_content, max_content, fit_content };

/// One side of a grid track's sizing function.
pub const TrackSize = union(enum) { auto, lp: LP, fr: f32, min_content, max_content, fit_content: LP };
/// `minmax(min, max)`; a plain size `s` is `{s, s}`, `<flex>` is `{auto, fr}`, `fit-content(x)` is `{auto, fit_content(x)}`.
pub const Track = struct { min: TrackSize, max: TrackSize };
pub const AutoRepeat = enum(u8) { none, fill, fit };
/// `grid-template-columns/rows`. `tracks` is the flattened list with integer `repeat()` expanded.
/// When `auto_repeat != .none`, tracks[auto_repeat_start .. auto_repeat_start+auto_repeat_len] is the
/// `repeat(auto-fill|auto-fit, ...)` group (to be repeated by the layout engine).
pub const GridTemplate = struct {
    tracks: []const Track = &.{},
    auto_repeat: AutoRepeat = .none,
    auto_repeat_start: u16 = 0,
    auto_repeat_len: u16 = 0,
    /// `[a b]` line names in source order. `line` = index of the grid line in the flattened `tracks`
    /// (0 = before the first track, tracks.len = after the last). Names written inside the
    /// auto-repeat group have `in_repeat = true` and `line` relative to the group start
    /// (0..auto_repeat_len); integer `repeat()` names are expanded like the tracks.
    line_names: []const LineName = &.{},
};
pub const LineName = struct { name: []const u8, line: u16, in_repeat: bool = false };
pub const GridAutoFlow = packed struct(u8) { column: bool = false, dense: bool = false, _pad: u6 = 0 };
/// grid-row/column-start/end. A named reference (`foo`, `2 foo`, `span foo`) is stored as `.auto`
/// here and described by the matching `ComputedStyle.grid_line_names` entry.
/// `line` is 1-based, negative = from the end of the explicit grid; 0 (accepted by takumi) is the line one
/// track past the end of the explicit grid (`explicit tracks + 1`, 0-based).
pub const GridLine = union(enum) { auto, line: i32, span: u32 };
/// Named grid-line reference: `name` "" = none (use the GridLine). `n` = the integer (default 1,
/// may be negative); `span` = `span ...` form. An area name `foo` used as a start line means the
/// line `foo-start` (and `foo-end` for end lines) per CSS Grid §8.3 — resolve that in layout.
pub const GridLineRef = struct { name: []const u8 = "", n: i32 = 1, span: bool = false };
/// `grid-template-areas`: `rows` x `cols` cells; each named area is a rectangle of cells
/// (row/col start inclusive, end exclusive, 0-based). Empty = none.
pub const GridAreas = struct {
    rows: u16 = 0,
    cols: u16 = 0,
    areas: []const GridArea = &.{},
};
pub const GridArea = struct { name: []const u8, row_start: u16, row_end: u16, col_start: u16, col_end: u16 };

// ---- clip-path / masks
/// Reference box for clip-path / mask geometry.
pub const GeometryBox = enum(u8) { border_box, padding_box, content_box, margin_box, fill_box, stroke_box, view_box };
pub const FillRule = enum(u8) { nonzero, evenodd };
/// circle()/ellipse() radius.
pub const ShapeRadius = union(enum) { lp: LP, closest_side, farthest_side };
/// Basic shapes with UNRESOLVED lengths (percentages refer to the reference box: x against
/// width, y against height, circle radius against sqrt(w²+h²)/sqrt2).
pub const BasicShape = union(enum) {
    /// sides top,right,bottom,left (insets from each edge); radius per corner like border_radius
    inset: struct { sides: [4]LP, radius: [4][2]LP },
    circle: struct { r: ShapeRadius, at: [2]LP },
    ellipse: struct { rx: ShapeRadius, ry: ShapeRadius, at: [2]LP },
    polygon: struct { rule: FillRule, points: []const [2]LP },
    /// raw SVG path data (escapes not processed), coordinates in CSS px of the reference box
    /// (NOT scaled by dpr — multiply by dpr when building the path).
    path: struct { rule: FillRule, d: []const u8 },
};
/// `clip-path`: null shape + `has_box` = a bare geometry box (`clip-path: padding-box`).
/// `url()` references are stored in `url` (shape null).
pub const ClipPath = struct {
    shape: ?BasicShape = null,
    box: GeometryBox = .border_box,
    url: []const u8 = "",
};
pub const MotionRay = struct {
    angle: f32,
    size: enum { closest_side, closest_corner, farthest_side, farthest_corner, sides } = .closest_side,
    at: ?[2]LP = null,
};
pub const MotionPath = struct {
    ray: ?MotionRay = null,
    measured: ?*const @import("../raster/path_measure.zig").Measure = null,
    /// (paged output) a shape measured per element height: motion_path.zig `Lazy`
    lazy: ?*@import("motion_path.zig").Lazy = null,
    reference: [2]f32,
};
pub const OffsetRotate = struct { mode: enum { auto, reverse, fixed } = .auto, angle: f32 = 0 };
pub const MaskMode = enum(u8) { match_source, alpha, luminance };
pub const MaskType = enum(u8) { luminance, alpha };
pub const Isolation = enum(u8) { auto, isolate };

// ---- text extras
pub const SkipInk = enum(u8) { auto, none, all };
pub const UnderlinePosition = packed struct(u8) { from_font: bool = false, under: bool = false, left: bool = false, right: bool = false, _pad: u4 = 0 };
pub const TextAlignLast = enum(u8) { auto, start, end, left, right, center, justify, match_parent };
pub const Hyphens = enum(u8) { manual, none, auto };
pub const LineBreak = enum(u8) { auto, loose, normal, strict, anywhere };
pub const FontKerning = enum(u8) { auto, normal, none };
pub const FontOpticalSizing = enum(u8) { auto, none };
pub const FontSynthesis = packed struct(u8) { weight: bool = true, style: bool = true, small_caps: bool = true, position: bool = true, _pad: u4 = 0 };
/// `font-feature-settings` entry (value 1 = on, 0 = off).
pub const FontFeature = struct { tag: [4]u8, value: u32 };
/// `font-variation-settings` entry.
pub const FontVariation = struct { tag: [4]u8, value: f32 };
pub const LigState = enum(u2) { normal, on, off };
pub const VariantLigatures = packed struct(u8) { common: LigState = .normal, discretionary: LigState = .normal, historical: LigState = .normal, contextual: LigState = .normal };
pub const VariantNumeric = packed struct(u16) {
    figure: enum(u2) { normal, lining, oldstyle } = .normal,
    spacing: enum(u2) { normal, proportional, tabular } = .normal,
    fraction: enum(u2) { normal, diagonal, stacked } = .normal,
    ordinal: bool = false,
    slashed_zero: bool = false,
    _pad: u8 = 0,
};
pub const VariantEastAsian = packed struct(u8) {
    form: enum(u3) { normal, jis78, jis83, jis90, jis04, simplified, traditional } = .normal,
    width: enum(u2) { normal, full, proportional } = .normal,
    ruby: bool = false,
    _pad: u2 = 0,
};
pub const VariantCaps = enum(u8) { normal, small_caps, all_small_caps, petite_caps, all_petite_caps, unicase, titling_caps };
pub const VariantPosition = enum(u8) { normal, sub, super };
pub const VerticalAlign = union(enum) { baseline, sub, super, top, middle, bottom, text_top, text_bottom, lp: LP };
pub const UnicodeBidi = enum(u8) { normal, embed, isolate, bidi_override, isolate_override, plaintext };
pub const WritingMode = enum(u8) { horizontal_tb, vertical_rl, vertical_lr, sideways_rl, sideways_lr };
/// `text-orientation` (`sideways-right` is the legacy alias of `sideways`).
pub const TextOrientation = enum(u8) { mixed, upright, sideways, sideways_right };
/// `text-combine-upright` (`digits <n>` is not supported).
pub const TextCombineUpright = enum(u8) { none, all };
/// SVG/text `paint-order` (only the first component matters for text: stroke under fill when `.stroke`).
pub const PaintOrder = enum(u8) { normal, fill, stroke, markers };

// ---- box extras
pub const Float = enum(u8) { none, left, right, inline_start, inline_end };
pub const Clear = enum(u8) { none, left, right, both, inline_start, inline_end };
pub const TableLayout = enum(u8) { auto, fixed };
pub const BorderCollapse = enum(u8) { separate, collapse };
pub const CaptionSide = enum(u8) { top, bottom };
pub const EmptyCells = enum(u8) { show, hide };
pub const BoxDecorationBreak = enum(u8) { slice, clone };
/// `break-before` / `break-after` (Blink's EBreakBetween; `always` is the legacy spelling of `page`).
pub const BreakBetween = enum(u8) {
    auto,
    avoid,
    avoid_page,
    avoid_column,
    column,
    page,
    always,
    left,
    right,
    recto,
    verso,

    /// forces a page break in paged output (Blink's IsForcedBreakValue)
    pub fn forcesPage(b: BreakBetween) bool {
        return @backingInt(b) >= @backingInt(BreakBetween.page);
    }
    /// avoids a page break (Blink's IsAvoidBreakValue)
    pub fn avoidsPage(b: BreakBetween) bool {
        return b == .avoid or b == .avoid_page;
    }
};
/// `break-inside` (Blink's EBreakInside)
pub const BreakInside = enum(u8) {
    auto,
    avoid,
    avoid_page,
    avoid_column,

    pub fn avoidsPage(b: BreakInside) bool {
        return b == .avoid or b == .avoid_page;
    }
};
pub const Contain = packed struct(u8) { size: bool = false, inline_size: bool = false, layout: bool = false, style: bool = false, paint: bool = false, _pad: u3 = 0 };
pub const ListStylePosition = enum(u8) { outside, inside };
/// `list-style-type`: `ident` holds the counter-style name lower-cased as written (disc, decimal, ...),
/// `string` the raw string marker.
pub const ListStyleType = union(enum) { none, ident: []const u8, string: []const u8 };

// ---- animations / transitions
pub const StepPos = enum(u8) { jump_start, jump_end, jump_none, jump_both };
/// Easing function. Keywords map to `cubic` (linear = {0,0,1,1}), `step-start`/`step-end` to steps(1, ...).
/// `linear_points` = canonicalised `linear()` control points [input, output] (inputs non-decreasing).
pub const TimingFunction = union(enum) {
    cubic: [4]f32,
    steps: struct { n: u32, pos: StepPos },
    linear_points: []const [2]f32,

    pub const ease: TimingFunction = .{ .cubic = .{ 0.25, 0.1, 0.25, 1 } };
    pub const linear: TimingFunction = .{ .cubic = .{ 0, 0, 1, 1 } };
};
pub const AnimDirection = enum(u8) { normal, reverse, alternate, alternate_reverse };
pub const FillMode = enum(u8) { none, forwards, backwards, both };
pub const PlayState = enum(u8) { running, paused };
/// One resolved `animation` entry (see `ComputedStyle.animation(i)`). Times in milliseconds.
/// `iteration_count` = inf for `infinite`.
pub const Animation = struct {
    name: []const u8,
    duration_ms: f32,
    timing: TimingFunction,
    delay_ms: f32,
    iteration_count: f32,
    direction: AnimDirection,
    fill_mode: FillMode,
    play_state: PlayState,
};
/// One resolved `transition` entry. `property` is the raw name ("all", "opacity", ...).
pub const Transition = struct { property: []const u8, duration_ms: f32, timing: TimingFunction, delay_ms: f32 };

/// Custom property (`--name: value`), value = raw token text after var() substitution.
pub const CustomProp = struct { name: []const u8, value: []const u8 };

pub const BorderStyle = enum(u8) { none, hidden, solid, dashed, dotted, double, groove, ridge, inset, outset };
pub const BgRepeat = enum(u8) { repeat, no_repeat, space, round };
/// (`border-area` exists in the PDF build only: the raster painter does not draw it yet)
pub const BgBox = if (@import("../config.zig").enable_pdf) enum(u8) { border_box, padding_box, content_box, text, border_area } else enum(u8) { border_box, padding_box, content_box, text };
pub const BgSize = union(enum) { cover, contain, size: [2]LengthAuto };
pub const ObjectFit = enum(u8) { fill, contain, cover, none, scale_down };
pub const ImageRendering = enum(u8) { auto, smooth, pixelated, crisp_edges };
pub const BlendMode = enum(u8) { normal, multiply, screen, overlay, darken, lighten, color_dodge, color_burn, hard_light, soft_light, difference, exclusion, hue, saturation, color, luminosity, plus_lighter, plus_darker };

/// box-shadow / text-shadow / drop-shadow entry. Lengths in device px.
pub const Shadow = struct {
    x: f32 = 0,
    y: f32 = 0,
    blur: f32 = 0,
    spread: f32 = 0,
    color: ColorValue = .current,
    inset: bool = false,
};

/// `filter` functions. Amounts are plain factors (50% -> 0.5); blur in device px; hue_rotate in degrees.
pub const Filter = union(enum) {
    blur: f32,
    brightness: f32,
    contrast: f32,
    grayscale: f32,
    invert: f32,
    opacity: f32,
    saturate: f32,
    sepia: f32,
    hue_rotate: f32,
    drop_shadow: Shadow,
};

/// 2D transform functions in source order. Angles in DEGREES; translate % refers to the element's own
/// border box; matrix = (a b c d e f) with e/f in device px.
pub const TransformOp = union(enum) {
    translate: [2]LP,
    scale: [2]f32,
    rotate: f32,
    skew: [2]f32,
    matrix: [6]f32,
};

pub const FontStyle = enum(u8) { normal, italic, oblique };
pub const LineHeight = union(enum) { normal, number: f32, px: f32 };
pub const TextAlign = enum(u8) { start, end, left, right, center, justify };
/// Low two bits select case; full-width and full-size-kana compose with it.
pub const TextTransform = enum(u8) { none, uppercase, lowercase, capitalize, full_width = 4, full_size_kana = 8, _ };
pub const DecorationLine = packed struct(u8) { underline: bool = false, overline: bool = false, line_through: bool = false, _pad: u5 = 0 };
pub const DecorationStyle = enum(u8) { solid, double, dotted, dashed, wavy };
pub const WhiteSpaceCollapse = enum(u8) { collapse, preserve, preserve_breaks, preserve_spaces, break_spaces };
pub const TextWrapMode = enum(u8) { wrap, nowrap };
pub const TextWrapStyle = enum(u8) { auto, balance, pretty, stable };
pub const WordBreak = enum(u8) { normal, break_all, keep_all, break_word };
pub const OverflowWrap = enum(u8) { normal, break_word, anywhere };
/// `.string` = a custom marker in `text_overflow_string` (raw, escapes not processed).
pub const TextOverflow = enum(u8) { clip, ellipsis, string };
/// line-clamp's block-ellipsis: `.string` = the marker in `block_ellipsis_string` (raw, escapes not processed).
pub const BlockEllipsis = enum(u8) { auto, none, string };
pub const Direction = enum(u8) { ltr, rtl };
pub const TabSize = union(enum) { number: f32, px: f32 };

pub const center2: [2]LP = .{ .{ .pct = 0.5 }, .{ .pct = 0.5 } };
pub const zero2: [2]LP = .{ .{}, .{} };
const auto2: [2]LengthAuto = .{ .auto, .auto };

pub const default_bg_size = [_]BgSize{.{ .size = auto2 }};
pub const default_bg_position = [_][2]LP{zero2};
pub const default_bg_repeat = [_][2]BgRepeat{.{ .repeat, .repeat }};
pub const default_bg_clip = [_]BgBox{.border_box};
pub const default_bg_origin = [_]BgBox{.padding_box};
pub const default_mask_box = [_]BgBox{.border_box};
pub const default_mask_mode = [_]MaskMode{.match_source};
pub const zero_f32 = [_]f32{0};
pub const one_f32 = [_]f32{1};
pub const default_timing = [_]TimingFunction{TimingFunction.ease};
pub const default_transition_prop = [_][]const u8{"all"};

/// Side order everywhere: top, right, bottom, left. Corner order: top-left, top-right, bottom-right, bottom-left.
pub const ComputedStyle = struct {
    // ---- box / layout (not inherited)
    display: Display = .@"inline",
    position: Position = .static,
    box_sizing: BoxSizing = .border_box,
    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,
    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .nowrap,
    justify_content: Align = .normal,
    align_items: Align = .normal,
    align_self: Align = .auto,
    align_content: Align = .normal,
    justify_items: Align = .normal,
    justify_self: Align = .auto,
    /// `safe` overflow alignment per property (an overflowing item / content falls back to `start`), in the
    /// order of `AlignSafe`: align-items, align-self, align-content, justify-content, justify-items, justify-self.
    /// `unsafe` and no keyword behave alike in takumi and are not distinguished. See `alignSafe()`.
    align_safe: [6]bool = .{ false, false, false, false, false, false },
    grid_auto_flow: GridAutoFlow = .{},
    /// null = auto
    z_index: ?i32 = null,
    order: i32 = 0,
    inset: [4]LengthAuto = .{ .auto, .auto, .auto, .auto },
    width: Size = .auto,
    height: Size = .auto,
    min_width: Size = .auto,
    min_height: Size = .auto,
    /// `none` = .auto
    max_width: Size = .auto,
    max_height: Size = .auto,
    /// width / height; null = auto
    aspect_ratio: ?f32 = null,
    margin: [4]LengthAuto = .{ .{ .lp = .{} }, .{ .lp = .{} }, .{ .lp = .{} }, .{ .lp = .{} } },
    padding: [4]LP = .{ .{}, .{}, .{}, .{} },
    row_gap: LP = .{},
    column_gap: LP = .{},
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: FlexBasis = .auto,
    grid_template_columns: GridTemplate = .{},
    grid_template_rows: GridTemplate = .{},
    /// empty = a single `auto` track
    grid_auto_columns: []const Track = &.{},
    grid_auto_rows: []const Track = &.{},
    grid_row_start: GridLine = .auto,
    grid_row_end: GridLine = .auto,
    grid_column_start: GridLine = .auto,
    grid_column_end: GridLine = .auto,

    // ---- box decoration (not inherited)
    /// SPECIFIED widths (device px). Use `usedBorderWidths()` for painting/layout.
    border_width: [4]f32 = .{ 3, 3, 3, 3 },
    border_style: [4]BorderStyle = .{ .none, .none, .none, .none },
    border_color: [4]ColorValue = .{ .current, .current, .current, .current },
    /// [corner][x, y]
    border_radius: [4][2]LP = .{ zero2, zero2, zero2, zero2 },
    outline_width: f32 = 3,
    outline_style: BorderStyle = .none,
    outline_color: ColorValue = .current,
    outline_offset: f32 = 0,
    background_color: ColorValue = .{ .rgba = Color.transparent },
    /// One entry per layer (empty = no image layers). Other background lists repeat cyclically
    /// against this one (CSS list repetition); use `bgLayer(i)`.
    background_image: []const Image = &.{},
    background_size: []const BgSize = &default_bg_size,
    background_position: []const [2]LP = &default_bg_position,
    /// [x, y]
    background_repeat: []const [2]BgRepeat = &default_bg_repeat,
    background_clip: []const BgBox = &default_bg_clip,
    background_origin: []const BgBox = &default_bg_origin,
    box_shadow: []const Shadow = &.{},
    opacity: f32 = 1,
    filter: []const Filter = &.{},
    transform: []const TransformOp = &.{},
    /// individual transform properties (identity when unset); rotate in degrees
    translate: [2]LP = zero2,
    rotate: f32 = 0,
    scale: [2]f32 = .{ 1, 1 },
    transform_origin: [2]LP = center2,
    offset_path: ?*const MotionPath = null,
    offset_distance: LP = .{},
    offset_anchor: ?[2]LP = null,
    offset_position: ?[2]LP = null,
    offset_rotate: OffsetRotate = .{},
    object_fit: ObjectFit = .fill,
    object_position: [2]LP = center2,
    mix_blend_mode: BlendMode = .normal,
    visibility: Visibility = .visible, // inherited

    // ---- text (inherited unless noted)
    color: Color = Color.black,
    font_family: []const []const u8 = &.{},
    font_size: f32 = 16,
    font_weight: u16 = 400,
    font_style: FontStyle = .normal,
    line_height: LineHeight = .normal,
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    text_align: TextAlign = .start,
    text_transform: TextTransform = .none,
    /// percentage refers to the containing block width
    text_indent: LP = .{},
    /// `text-indent` keywords: bit 0 = each-line, bit 1 = hanging
    text_indent_flags: u8 = 0,
    tab_size: TabSize = .{ .number = 8 },
    white_space_collapse: WhiteSpaceCollapse = .collapse,
    text_wrap_mode: TextWrapMode = .wrap,
    text_wrap_style: TextWrapStyle = .auto,
    word_break: WordBreak = .normal,
    overflow_wrap: OverflowWrap = .normal,
    direction: Direction = .ltr,
    image_rendering: ImageRendering = .auto,
    text_shadow: []const Shadow = &.{},
    webkit_text_stroke_width: f32 = 0,
    webkit_text_stroke_color: ColorValue = .current,
    // not inherited text props
    text_decoration_line: DecorationLine = .{},
    text_decoration_style: DecorationStyle = .solid,
    text_decoration_color: ColorValue = .current,
    /// null = auto / from-font
    text_decoration_thickness: ?f32 = null,
    /// `text-decoration-thickness: from-font` (read by the PDF output only; the raster and SVG
    /// paths draw it as `auto`)
    text_decoration_from_font: bool = false,
    text_overflow: TextOverflow = .clip,
    text_overflow_string: []const u8 = "",
    /// 0 = none
    line_clamp: u32 = 0,
    block_ellipsis: BlockEllipsis = .auto,
    block_ellipsis_string: []const u8 = "",

    // ================= phase 2 additions =================
    // ---- custom properties (inherited): sorted by name, values already var()-substituted
    custom_props: []const CustomProp = &.{},

    // ---- grid extras (not inherited)
    grid_template_areas: GridAreas = .{},
    /// named references for [row_start, column_start, row_end, column_end]
    grid_line_names: [4]GridLineRef = .{ .{}, .{}, .{}, .{} },

    // ---- box extras (not inherited unless noted)
    float: Float = .none,
    clear: Clear = .none,
    table_layout: TableLayout = .auto,
    border_collapse: BorderCollapse = .separate, // inherited
    /// [horizontal, vertical] device px (inherited)
    border_spacing: [2]f32 = .{ 0, 0 },
    caption_side: CaptionSide = .top, // inherited
    empty_cells: EmptyCells = .show, // inherited
    box_decoration_break: BoxDecorationBreak = .slice,
    // fragmentation (paged output only)
    break_before: BreakBetween = .auto,
    break_after: BreakBetween = .auto,
    break_inside: BreakInside = .auto,
    /// fewest lines of a block a page break may leave after / before it (inherited, >= 1)
    widows: u8 = 2,
    orphans: u8 = 2,
    contain: Contain = .{},
    vertical_align: VerticalAlign = .baseline,
    unicode_bidi: UnicodeBidi = .normal,
    writing_mode: WritingMode = .horizontal_tb, // inherited
    text_orientation: TextOrientation = .mixed, // inherited
    text_combine_upright: TextCombineUpright = .none, // inherited
    isolation: Isolation = .auto,
    background_blend_mode: []const BlendMode = &.{},
    backdrop_filter: []const Filter = &.{},
    /// null = none
    clip_path: ?*const ClipPath = null,

    // ---- masks (not inherited); lists repeat against mask_image like backgrounds (`maskLayer(i)`)
    mask_image: []const Image = &.{},
    mask_size: []const BgSize = &default_bg_size,
    mask_position: []const [2]LP = &default_bg_position,
    mask_repeat: []const [2]BgRepeat = &default_bg_repeat,
    mask_clip: []const BgBox = &default_mask_box,
    mask_origin: []const BgBox = &default_mask_box,
    mask_mode: []const MaskMode = &default_mask_mode,
    mask_type: MaskType = .luminance,

    // ---- lists / generated content
    list_style_type: ListStyleType = .{ .ident = "disc" }, // inherited
    list_style_position: ListStylePosition = .outside, // inherited
    list_style_image: Image = .none, // inherited
    /// raw `content` value text ("normal", "none", or the item list as written)
    content: []const u8 = "normal",
    /// raw values ("" = none)
    counter_reset: []const u8 = "",
    counter_increment: []const u8 = "",
    counter_set: []const u8 = "",

    // ---- text extras (inherited unless noted)
    text_align_last: TextAlignLast = .auto,
    hyphens: Hyphens = .manual,
    line_break: LineBreak = .auto,
    text_decoration_skip_ink: SkipInk = .auto,
    /// device px; null = auto
    text_underline_offset: ?f32 = null,
    text_underline_position: UnderlinePosition = .{},
    /// null = use `color`
    webkit_text_fill_color: ?ColorValue = null,
    paint_order: PaintOrder = .normal,
    /// percent (100 = normal)
    font_stretch: f32 = 100,
    font_feature_settings: []const FontFeature = &.{},
    font_variation_settings: []const FontVariation = &.{},
    font_variant_ligatures: VariantLigatures = .{},
    font_variant_numeric: VariantNumeric = .{},
    font_variant_east_asian: VariantEastAsian = .{},
    font_variant_caps: VariantCaps = .normal,
    font_variant_position: VariantPosition = .normal,
    font_kerning: FontKerning = .auto,
    font_optical_sizing: FontOpticalSizing = .auto,
    font_synthesis: FontSynthesis = .{},

    // ---- animations / transitions (not inherited); per-longhand lists, see animation(i)/transition(i)
    animation_name: []const []const u8 = &.{},
    animation_duration: []const f32 = &zero_f32,
    animation_timing_function: []const TimingFunction = &default_timing,
    animation_delay: []const f32 = &zero_f32,
    animation_iteration_count: []const f32 = &one_f32,
    animation_direction: []const AnimDirection = &[_]AnimDirection{.normal},
    animation_fill_mode: []const FillMode = &[_]FillMode{.none},
    animation_play_state: []const PlayState = &[_]PlayState{.running},
    transition_property: []const []const u8 = &default_transition_prop,
    transition_duration: []const f32 = &zero_f32,
    transition_timing_function: []const TimingFunction = &default_timing,
    transition_delay: []const f32 = &zero_f32,

    /// Value of custom property `name` (with the leading `--`), or null if not defined.
    pub fn customProperty(s: *const ComputedStyle, name: []const u8) ?[]const u8 {
        return findCustom(s.custom_props, name);
    }

    /// The i-th mask layer (i < mask_image.len) with list repetition.
    pub fn maskLayer(s: *const ComputedStyle, i: usize) MaskLayer {
        return .{
            .image = s.mask_image[i],
            .size = pick(BgSize, s.mask_size, i, default_bg_size[0]),
            .position = pick([2]LP, s.mask_position, i, zero2),
            .repeat = pick([2]BgRepeat, s.mask_repeat, i, default_bg_repeat[0]),
            .clip = pick(BgBox, s.mask_clip, i, .border_box),
            .origin = pick(BgBox, s.mask_origin, i, .border_box),
            .mode = pick(MaskMode, s.mask_mode, i, .match_source),
        };
    }

    /// The i-th animation (i < animation_name.len; names "none" are included and must be skipped).
    pub fn animation(s: *const ComputedStyle, i: usize) Animation {
        return .{
            .name = s.animation_name[i],
            .duration_ms = pick(f32, s.animation_duration, i, 0),
            .timing = pick(TimingFunction, s.animation_timing_function, i, TimingFunction.ease),
            .delay_ms = pick(f32, s.animation_delay, i, 0),
            .iteration_count = pick(f32, s.animation_iteration_count, i, 1),
            .direction = pick(AnimDirection, s.animation_direction, i, .normal),
            .fill_mode = pick(FillMode, s.animation_fill_mode, i, .none),
            .play_state = pick(PlayState, s.animation_play_state, i, .running),
        };
    }

    /// The i-th transition (i < transition_property.len).
    pub fn transition(s: *const ComputedStyle, i: usize) Transition {
        return .{
            .property = s.transition_property[i],
            .duration_ms = pick(f32, s.transition_duration, i, 0),
            .timing = pick(TimingFunction, s.transition_timing_function, i, TimingFunction.ease),
            .delay_ms = pick(f32, s.transition_delay, i, 0),
        };
    }

    /// OpenType features for shaping, mirroring takumi `resolved_font_features`: the
    /// font-variant-* features (ligatures disabled when letter-spacing != 0), font-kerning, then
    /// font-feature-settings (later entries win on conflicts). Returns `font_feature_settings`
    /// itself when no variant applies. Allocates in `arena` otherwise.
    pub fn fontFeatures(s: *const ComputedStyle, arena: std.mem.Allocator) error{OutOfMemory}![]const FontFeature {
        var buf: [24]FontFeature = undefined;
        var n: usize = 0;
        const lig = if (s.letter_spacing != 0) VariantLigatures{ .common = .off, .discretionary = .off, .historical = .off, .contextual = .off } else s.font_variant_ligatures;
        const ligs = [_]struct { LigState, []const u8 }{ .{ lig.common, "ligaclig" }, .{ lig.discretionary, "dlig" }, .{ lig.historical, "hlig" }, .{ lig.contextual, "calt" } };
        for (ligs) |e| {
            if (e[0] == .normal) continue;
            var k: usize = 0;
            while (k < e[1].len) : (k += 4) {
                buf[n] = .{ .tag = e[1][k..][0..4].*, .value = if (e[0] == .on) 1 else 0 };
                n += 1;
            }
        }
        const num = s.font_variant_numeric;
        const add = struct {
            fn f(b: *[24]FontFeature, m: *usize, tag: *const [4]u8) void {
                if (m.* < b.len) {
                    b[m.*] = .{ .tag = tag.*, .value = 1 };
                    m.* += 1;
                }
            }
        }.f;
        switch (num.figure) {
            .lining => add(&buf, &n, "lnum"),
            .oldstyle => add(&buf, &n, "onum"),
            .normal => {},
        }
        switch (num.spacing) {
            .proportional => add(&buf, &n, "pnum"),
            .tabular => add(&buf, &n, "tnum"),
            .normal => {},
        }
        switch (num.fraction) {
            .diagonal => add(&buf, &n, "frac"),
            .stacked => add(&buf, &n, "afrc"),
            .normal => {},
        }
        if (num.ordinal) add(&buf, &n, "ordn");
        if (num.slashed_zero) add(&buf, &n, "zero");
        const ea = s.font_variant_east_asian;
        const forms = [_]*const [4]u8{ "jp78", "jp83", "jp90", "jp04", "smpl", "trad" };
        if (ea.form != .normal) add(&buf, &n, forms[@backingInt(ea.form) - 1]);
        switch (ea.width) {
            .full => add(&buf, &n, "fwid"),
            .proportional => add(&buf, &n, "pwid"),
            .normal => {},
        }
        if (ea.ruby) add(&buf, &n, "ruby");
        // (font-variant-caps is not a feature list here: the text engine applies the caps
        // features per face and synthesizes small caps, see font TextStyle.caps)
        switch (s.font_variant_position) {
            .sub => add(&buf, &n, "subs"),
            .super => add(&buf, &n, "sups"),
            .normal => {},
        }
        switch (s.font_kerning) {
            .normal => add(&buf, &n, "kern"),
            .none => {
                add(&buf, &n, "kern");
                buf[n - 1].value = 0;
            },
            .auto => {},
        }
        if (n == 0) return s.font_feature_settings;
        const out = try arena.alloc(FontFeature, n + s.font_feature_settings.len);
        @memcpy(out[0..n], buf[0..n]);
        @memcpy(out[n..], s.font_feature_settings);
        return out;
    }

    /// Used border widths (Blink rule): 0 when the side's style is none/hidden, otherwise the
    /// specified width floored to whole device px, but never below 1 when non-zero.
    /// `align_safe` as a packed struct with the layout engine's `layout.AlignSafe` bit layout
    /// (`layout_style.safe = @bitCast(cs.alignSafe())`).
    pub fn alignSafe(s: *const ComputedStyle) AlignSafe {
        const a = s.align_safe;
        return .{ .align_items = a[0], .align_self = a[1], .align_content = a[2], .justify_content = a[3], .justify_items = a[4], .justify_self = a[5] };
    }

    pub fn usedBorderWidths(s: *const ComputedStyle) [4]f32 {
        var out: [4]f32 = undefined;
        for (0..4) |i| out[i] = usedLineWidth(s.border_width[i], s.border_style[i]);
        return out;
    }

    pub fn usedOutlineWidth(s: *const ComputedStyle) f32 {
        return usedLineWidth(s.outline_width, s.outline_style);
    }

    /// The i-th background layer with CSS list repetition applied (i < background_image.len).
    pub fn bgLayer(s: *const ComputedStyle, i: usize) BgLayer {
        return .{
            .image = s.background_image[i],
            .size = pick(BgSize, s.background_size, i, default_bg_size[0]),
            .position = pick([2]LP, s.background_position, i, zero2),
            .repeat = pick([2]BgRepeat, s.background_repeat, i, default_bg_repeat[0]),
            .clip = pick(BgBox, s.background_clip, i, .border_box),
            .origin = pick(BgBox, s.background_origin, i, .padding_box),
        };
    }

    /// The background painting area of the bottom-most layer (`background-clip` of the last layer),
    /// which is what clips `background-color`.
    pub fn bgColorClip(s: *const ComputedStyle) BgBox {
        const n = @max(s.background_image.len, 1);
        return pick(BgBox, s.background_clip, n - 1, .border_box);
    }

    /// Resolves a ColorValue against this element's `color`.
    pub fn resolveColor(s: *const ComputedStyle, c: ColorValue) Color {
        return c.resolve(s.color);
    }
};

pub const BgLayer = struct {
    image: Image,
    size: BgSize,
    position: [2]LP,
    repeat: [2]BgRepeat,
    clip: BgBox,
    origin: BgBox,
};

pub const MaskLayer = struct {
    image: Image,
    size: BgSize,
    position: [2]LP,
    repeat: [2]BgRepeat,
    clip: BgBox,
    origin: BgBox,
    mode: MaskMode,
};

/// Binary search in a name-sorted custom property list.
pub fn findCustom(list: []const CustomProp, name: []const u8) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, list[mid].name, name)) {
            .eq => return list[mid].value,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

fn pick(comptime E: type, list: []const E, i: usize, def: E) E {
    if (list.len == 0) return def;
    return list[i % list.len];
}

pub fn usedLineWidth(w: f32, st: BorderStyle) f32 {
    if (st == .none or st == .hidden) return 0;
    if (!(w > 0)) return 0;
    const f = @floor(w);
    return if (f < 1) 1 else f;
}

/// takumi initial values (Blink initial + takumi's display:inline / box-sizing:border-box).
pub fn initialStyle(dpr: f32) ComputedStyle {
    var s: ComputedStyle = .{};
    s.font_size = 16 * dpr;
    s.border_width = .{ 3 * dpr, 3 * dpr, 3 * dpr, 3 * dpr };
    s.outline_width = 3 * dpr;
    return s;
}
