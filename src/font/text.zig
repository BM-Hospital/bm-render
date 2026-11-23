//! Paragraph shaping and layout following takumi's (= Blink's) inline layout rules. Shaping is
//! delegated to `shape.zig` (HarfBuzz-style OpenType shaping); with `complex = true` the
//! paragraph is also run through the Unicode bidi algorithm, split into script runs, broken
//! with the full UAX #14 rules and laid out in visual order. Layout rules:
//!  * glyph advance = round(units * size * 65536 / upem) / 65536 px, letter-spacing added after
//!    every glyph (and disables liga/clig/calt), word-spacing added to U+0020 / U+00A0;
//!  * widths that feed layout are ceiled to 1/64 px (`LayoutUnit`), line heights floored to 1/64;
//!  * font ascent / descent / lineGap are each rounded to whole px at the font size;
//!    `line-height: normal` = asc + desc + gap; the half-leading above the baseline is
//!    floor((line_height - (asc + desc)) / 2) in whole px, the rest goes below;
//!  * a line box is the strut (font + line-height of the block); with `line-height: normal` it is
//!    united with the normal-line-height box of every font actually used on the line. With an
//!    explicit line-height the strut alone decides for plain runs.
//!  * inline formatting (`Paragraph.complex`): runs may lie in inline boxes (`InlineBox`: own strut,
//!    `vertical-align`, inline edges that take space on the first / last fragment, `nowrap`) and
//!    may be objects (`Object`: atomic inlines with caller-given metrics, floats, out-of-flow
//!    boxes). Lines are then built by Blink's inline box state machine (`lineBox`), and a `Flow`
//!    gives every line the inline range left free by floats (`measureFlow` / `layoutFlow`).
//!    Plain paragraphs never touch that machinery.
const std = @import("std");
const ttf = @import("ttf.zig");
const uni = @import("unicode.zig");
const coll = @import("collection.zig");
const ot = @import("ot.zig");
const shp = @import("shape.zig");
const bidi = @import("bidi.zig");
const color = @import("color.zig");
const case = @import("case.zig");
const Font = ttf.Font;
const FaceId = coll.FaceId;
const FontCollection = coll.FontCollection;

pub const TextStyle = struct {
    unicode_bidi: BidiMode = .normal,
    rtl: bool = false,
    /// `hyphens: none`: a soft hyphen in the run is no break opportunity.
    no_hyphens: bool = false,
    /// Family names in priority order (ASCII case-insensitive). Unknown / empty lists fall back to
    /// every registered family in registration order.
    families: []const []const u8 = &.{},
    weight: u16 = 400,
    italic: bool = false,
    /// Font size in px.
    size: f32 = 16,
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    /// Per-run CSS tab width; absent uses ParagraphOptions.tab_size.
    tab_spaces: ?u16 = null,
    tab_length: ?f32 = null,
    /// Opaque id copied to every glyph of the run (colour / paint index).
    user: u32 = 0,
    /// font-stretch in percent (drives `wdth` of variable fonts and face selection).
    stretch: f32 = 100,
    /// font-optical-sizing: auto (drives `opsz` from the font size).
    optical_sizing: bool = true,
    /// font-variation-settings.
    variations: []const coll.AxisValue = &.{},
    /// font-feature-settings / font-variant-* of this run, applied after
    /// `ParagraphOptions.features` (together at most 32 entries).
    features: []const shp.FeatureSetting = &.{},
    /// font-variant-caps: the caps features go before `features`; a face without them gets
    /// Blink's fallback (petite -> small caps) or synthesized small caps (see `Builder.flushCaps`).
    caps: Caps = .normal,
    /// font-synthesis-small-caps: auto (false = none: no synthesized small caps).
    synth_small_caps: bool = true,
};

pub const BidiMode = enum { normal, embed, isolate, bidi_override, isolate_override, plaintext };

pub const Caps = enum(u3) { normal, small, all_small, petite, all_petite, unicase, titling };

/// Fallback chain for a style (variable-font instances included).
fn matchStyle(fonts: *const FontCollection, st: TextStyle, out: []FaceId) []FaceId {
    return fonts.matchEx(.{
        .families = st.families,
        .weight = st.weight,
        .italic = st.italic,
        .stretch = st.stretch,
        .size = if (st.optical_sizing) st.size else 0,
        .variations = st.variations,
    }, out);
}

pub const FeatureSetting = shp.FeatureSetting;
pub const ShapeCache = shp.Cache;
pub const Direction = enum { ltr, rtl };
pub const TextWrap = enum { wrap, balance, pretty };

pub const Run = struct {
    text: []const u8,
    style: TextStyle = .{},
    /// A forced line break follows this run in every white-space mode (HTML `<br>`: pass an
    /// empty or non-empty run with this set). U+2028 inside the text does the same.
    hard_break_after: bool = false,
    /// `white-space` of this run when it differs from the paragraph's (a `nowrap` span inside
    /// wrapping text): collapsing follows the run, a soft wrap opportunity between two characters
    /// exists when either side wraps.
    white_space: ?WhiteSpace = null,
    /// `overflow-wrap` of this run when it differs from the paragraph's (an `anywhere` span inside
    /// normal text): an emergency break before a glyph follows the run of that glyph, as in Blink
    /// and takumi.
    overflow_wrap: ?OverflowWrap = null,
    /// Innermost inline box (index into `ParagraphOptions.boxes`) the run lies in, `no_box` =
    /// directly in the block. An empty run still opens / closes its boxes.
    box: u32 = no_box,
    /// The run is a non-text inline item (its `text` is ignored): see `Object`.
    object: ?Object = null,
};

pub const no_box: u32 = 0xffff_ffff;

/// `vertical-align` of an inline box or atomic inline (percentages already resolved against the
/// element's own line-height; `length` is positive upwards).
pub const VerticalAlign = union(enum) { baseline, sub, super, top, text_top, middle, bottom, text_bottom, length: f32 };

/// A non-text inline item at the position of its run.
///  * `atomic`: an inline-block / replaced element. It takes part in line breaking as one
///    unbreakable unit (a soft wrap opportunity before and after it) with the size found in
///    `Flow.objects[id]`, and is aligned by `valign`; its position is reported in
///    `TextLayout.objects`.
///  * `float`: transparent to text; when the line it occurs on is laid out, `Flow.float_fn` is
///    asked to place it (beside the line when it fits, else below it).
///  * `out_of_flow`: transparent; its static position is reported in `TextLayout.objects`.
pub const Object = struct {
    id: u32,
    kind: Kind = .atomic,
    valign: VerticalAlign = .baseline,
    /// out_of_flow only: the box was block-level before it was positioned (static position below
    /// the line instead of at the current point).
    block_level: bool = false,

    pub const Kind = enum(u8) { atomic, float, out_of_flow };
};

/// An inline box (`<span>`): its font and line-height make a strut on every line it has a
/// fragment on, its `valign` shifts everything inside, its inline-start / -end edges take
/// inline space before its first / after its last character.
pub const InlineBox = struct {
    parent: u32 = no_box,
    style: TextStyle = .{},
    /// null = the paragraph's line-height
    line_height: ?LineHeight = null,
    valign: VerticalAlign = .baseline,
    /// margin + border + padding at the inline start / end (may be negative through margins)
    start: f32 = 0,
    end: f32 = 0,
    /// the margin part of `start` / `end` (outside the painted fragment)
    margin_start: f32 = 0,
    margin_end: f32 = 0,
    /// `box-decoration-break: clone`: every fragment has both edges (a line the box continues on
    /// starts with its start edge and reserves room for its end edge).
    clone: bool = false,
    /// The box paints something (background, border): its fragments are wanted in
    /// `TextLayout.boxes` even when it does not affect the layout.
    decorated: bool = false,
    /// Margins / padding with a percentage: the parts of the edges ([inline start, inline end]). When
    /// set, `start` / `end` / `margin_*` are derived from it for the percentage base of the moment
    /// (`Paragraph.setPercentBase`: the containing block width; 0 in intrinsic sizing).
    pct: ?EdgeParts = null,
    /// `position: relative` offset of the box (px, x to the right, y down): its fragments and everything
    /// inside it are shifted by it after the lines are laid out.
    rel: [2]f32 = .{ 0, 0 },
    /// The box continues from / into another paragraph (block-in-inline): its fragments never have the
    /// start / end edge (pass 0 for that edge).
    no_start: bool = false,
    no_end: bool = false,
    /// `direction: rtl` on the box: its inline-start edge is its right one (`start` / `end` are
    /// logical). On a line the edges are placed visually (Blink's box fragments): the left edge left of
    /// the box's leftmost content, the right edge right of its rightmost.
    rtl: bool = false,
};

/// The parts of the inline edges of an `InlineBox`, [inline start, inline end]: margin and padding as
/// px + fraction of the percentage base, border width in px.
pub const EdgeParts = struct {
    margin: [2]f32 = .{ 0, 0 },
    margin_pct: [2]f32 = .{ 0, 0 },
    padding: [2]f32 = .{ 0, 0 },
    padding_pct: [2]f32 = .{ 0, 0 },
    border: [2]f32 = .{ 0, 0 },
};

pub const LineHeight = union(enum) {
    normal,
    /// Absolute line height in px.
    px: f32,
    /// Multiple of the strut font size (CSS `line-height: <number>`).
    multiple: f32,
};

pub const TextAlign = enum { left, right, center, justify, start, end };
pub const WhiteSpace = enum { normal, nowrap, pre, pre_wrap, pre_line };
pub const WordBreak = uni.WordBreak;
pub const OverflowWrap = enum { normal, anywhere, break_word };

pub const ParagraphOptions = struct {
    /// Wrap width used when `Paragraph.measure` / `layout` are called with `null`
    /// (null here as well = no wrapping; only forced breaks).
    max_width: ?f32 = null,
    text_align: TextAlign = .left,
    /// `text-align-last`: the alignment of the last line and of lines that end in a forced break;
    /// null (`auto`) = `text_align`, start for `justify`
    text_align_last: ?TextAlign = null,
    line_height: LineHeight = .normal,
    white_space: WhiteSpace = .normal,
    word_break: WordBreak = .normal,
    overflow_wrap: OverflowWrap = .normal,
    /// line-clamp: keep at most this many lines. As in takumi, a clamped paragraph always gets
    /// "…" on its last kept line (independently of `ellipsis`).
    max_lines: ?u32 = null,
    /// text-overflow: ellipsis — "…" on the last allowed line when clamped, and on any line that
    /// still overflows `max_width` (nowrap / unbreakable content).
    ellipsis: bool = false,
    /// text-overflow: <string> — the marker that replaces "…" on an overflowing line (raw CSS
    /// string contents: escapes are processed, forced line breaks become one space). Shaped
    /// with `strut`, fallback fonts and the paragraph direction (takumi `LineTruncator`).
    /// null = "…" (or "..." when the font has no U+2026). Not used on a line-clamp line.
    ellipsis_text: ?[]const u8 = null,
    /// line-clamp's block-ellipsis: null = auto ("…"), otherwise the marker string (raw CSS
    /// string contents, as `ellipsis_text`).
    clamp_text: ?[]const u8 = null,
    /// line-clamp's block-ellipsis is `none`: a clamped line gets no marker.
    clamp_no_ellipsis: bool = false,
    /// Style of the containing block (Blink's "strut": its font metrics take part in every line
    /// box, and it is the font the ellipsis is shaped with). Defaults to the first run's style.
    strut: ?TextStyle = null,
    /// Tab stops every `tab_size` space advances (white-space: pre / pre-wrap).
    tab_size: u16 = 8,
    /// CSS `direction`: paragraph base direction for bidi; `text-align: start / end` follow it.
    /// (Only honoured by the complex path; the simple path is always left-to-right.)
    direction: Direction = .ltr,
    /// BCP 47 language (selects the OpenType language system, e.g. for `locl`).
    lang: []const u8 = "",
    /// text-wrap-style. `balance` (at most 6 lines) and `pretty` (last 4 lines) use Blink's
    /// score-based breaker, `balance` falling back to bisecting the available width.
    /// Ignored together with `max_lines`.
    text_wrap: TextWrap = .wrap,
    /// font-feature-settings / font-variant-* as OpenType features, applied after the defaults.
    features: []const FeatureSetting = &.{},
    /// Long-lived shape-plan cache (see `shape.Cache`); null = rebuild plans per paragraph.
    shape_cache: ?*ShapeCache = null,
    /// Working memory of `init` (the characters, their break classes and bidi levels, the shaping
    /// buffer): nothing the paragraph keeps is allocated from it, so the caller may rewind it once
    /// `init` returns. Null: the paragraph's allocator (where, in a bump arena, most of it stays).
    scratch: ?std.mem.Allocator = null,
    /// Inline boxes referenced by `Run.box` (parents before children). Only read during `init`.
    boxes: []const InlineBox = &.{},
    /// text-indent: `indent` px plus `indent_pct` (a fraction) of the width the lines are broken at (0
    /// in intrinsic sizing), applied at the inline start of the first line, and of every line after a
    /// forced break with `indent_each_line`; `indent_hanging` indents the other lines instead. The indent
    /// is part of the line width (Blink: LineInfo::ComputeWidth).
    indent: f32 = 0,
    indent_pct: f32 = 0,
    indent_each_line: bool = false,
    indent_hanging: bool = false,
    /// PDF builds only (`void` otherwise; set for the frames a PDF is drawn from, so a raster
    /// render is untouched): a line's glyphs sit at their item's origin plus their advance within
    /// the item, summed exactly (takumi's fragment builder: `origin.x + glyph.x`, the advances of
    /// `ShapeResultView::for_each_glyph` summed in 1/65536 px fixed point), not at one running
    /// f32 line position, which rounds once it passes 256 px: the PDF's text positioning shows
    /// the last bits.
    item_origin: if (item_origin_build) bool else void = if (item_origin_build) false else {},
};

/// Whether `ParagraphOptions.item_origin` exists (src/config.zig `enable_pdf` via the root module; on in
/// standalone module tests).
const item_origin_build = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "bm_config")) root.bm_config.enable_pdf else true;
};

/// Where `ParagraphOptions.item_origin` places a line's glyphs (an empty struct in other builds):
/// the current item's origin, the advance within it so far (exact in f64, as takumi's fixed-point
/// sum) and the face of the glyph before.
const ItemPos = if (item_origin_build) struct {
    org: f32,
    loc: f64 = 0,
    last_face: ?FaceId = null,

    fn init(x: f32) ItemPos {
        return .{ .org = x };
    }
    /// The next item starts where this one ends, its width snapped up to the LayoutUnit grid
    /// (Blink's `SnappedWidth`): its origin.
    fn nextItem(p: *ItemPos) f32 {
        p.org += ceil64(@floatCast(p.loc));
        p.loc = 0;
        return p.org;
    }
    /// A run of another face restarts from the f32 total so far (`ShapeResultView::for_each_glyph`
    /// converts the sum at each part).
    fn face(p: *ItemPos, f: FaceId) void {
        if (p.last_face) |lf| if (lf != f) {
            p.loc = @as(f32, @floatCast(p.loc));
        };
        p.last_face = f;
    }
    /// Advances by `adv`; the pen position.
    fn add(p: *ItemPos, adv: f32) f32 {
        p.loc += adv;
        return p.org + @as(f32, @floatCast(p.loc));
    }
    /// takumi: `origin.x + (advance + offset.x)`.
    fn glyphX(p: *const ItemPos, x_offset: f32) f32 {
        return p.org + (@as(f32, @floatCast(p.loc)) + x_offset);
    }
} else struct {
    fn init(_: f32) ItemPos {
        return .{};
    }
};

/// Size of an atomic inline: margin-box width, and the margin-box extent above / below its
/// baseline (`ascent + descent` = margin-box height).
pub const ObjectMetrics = struct { width: f32 = 0, ascent: f32 = 0, descent: f32 = 0 };

/// Free inline range of a line box, as offsets from the paragraph's left edge.
pub const Band = struct {
    x0: f32,
    x1: f32,
    /// Lowest y below which the range may be wider (NaN = the range is already the full width).
    next_y: f32 = std.math.nan(f32),
};

pub const FloatPlace = enum(u8) { leading, beside, below, undo };

/// The environment a paragraph with objects, or one beside floats, is laid out in
/// (`Paragraph.measureFlow` / `layoutFlow`).
pub const Flow = struct {
    /// Scratch for the line box builder (small; a per-render arena is the expected choice).
    alloc: std.mem.Allocator,
    /// Indexed by `Object.id` (atomic objects); missing entries are zero-sized.
    objects: []const ObjectMetrics = &.{},
    /// Free range for a line box spanning [y, y + h) (y from the paragraph top); null = the whole
    /// width at every position.
    band_fn: ?*const fn (flow: *const Flow, y: f32, h: f32) Band = null,
    /// Places float `id`. `.leading` / `.below`: place it at or below `y` (always succeeds).
    /// `.beside`: the float occurs on a line at `y` that already has `used` px of content and
    /// `avail` px of room; return true when it was placed on that line (the line is then broken
    /// again with the new band), false to have it placed `.below` the finished line.
    /// `.undo`: take back the float placed by the last `.beside` call (the shortened line ended
    /// before the inline box the float is in: it belongs to the next line).
    float_fn: ?*const fn (flow: *const Flow, id: u32, y: f32, used: f32, avail: f32, how: FloatPlace) bool = null,
    ctx: ?*anyopaque = null,
};

pub const ShapedGlyph = struct {
    face: FaceId,
    gid: u16,
    /// Byte offset of the source character in the concatenated run texts.
    cluster: u32,
    /// Advance in px, including kerning, letter- and word-spacing.
    x_advance: f32,
    x_offset: f32 = 0,
    y_offset: f32 = 0,
    /// Part of `x_advance` that comes from pair kerning with the FOLLOWING glyph (px); undone
    /// when a line ends right after this glyph.
    kern: f32 = 0,
    /// Index into `Paragraph.metrics` (style + face this glyph was shaped with).
    metric: u16 = 0,
    flags: u8 = 0,
    /// Bidi embedding level (odd = right-to-left).
    level: u8 = 0,
    /// Inline item (style run x bidi run): its origin is snapped to 1/64 px.
    item: u16 = 0,
    /// Minimum tab advance (half the space width), independent of a run's tab count.
    tab_min: f32 = 0,

    /// Soft wrap opportunity before this glyph.
    pub const BREAK_BEFORE: u8 = 1;
    /// Collapsible / hanging space: excluded from line width at line end.
    pub const SPACE: u8 = 2;
    /// Forced line break marker (no glyph to paint).
    pub const HARD_BREAK: u8 = 4;
    /// Word separator (U+0020 / U+00A0): word-spacing and justification apply.
    pub const WORD_SPACE: u8 = 8;
    /// Not the first glyph of its cluster (marks, reordered parts): no emergency break before it.
    pub const NO_SPLIT: u8 = 16;
    /// The break opportunity before this glyph comes from a soft hyphen (U+00AD).
    pub const SOFT_HYPHEN: u8 = 32;
    /// Tab (white-space: pre / pre-wrap): `x_advance` holds the tab-stop interval; the real
    /// advance depends on the position in the line (`Paragraph` resolves it).
    pub const TAB: u8 = 64;
    /// Not a glyph: an inline box edge or an object. `gid` holds the `Special` kind, `cluster`
    /// the inline box (internal index) or the `Object.id`, `x_advance` the edge width.
    pub const SPECIAL: u8 = 128;
};

const Special = struct {
    const open: u16 = 0;
    const close: u16 = 1;
    const atomic: u16 = 2;
    const float: u16 = 3;
    const oof: u16 = 4;
    /// `oof` whose box was block-level
    const oof_block: u16 = 5;
};

pub const PositionedGlyph = struct {
    face: FaceId,
    gid: u16,
    /// Glyph origin (baseline) in paragraph space, px, y down. Not rounded.
    x: f32,
    y: f32,
    /// Font size in px to scale the outline with.
    size: f32,
    user: u32,
    cluster: u32,
    /// Bidi embedding level of the glyph (odd = part of a right-to-left run).
    bidi_level: u8 = 0,
    /// Text generated by layout (a hyphen at a discretionary break), with its own mapping.
    generated: ?u21 = null,
    /// (PDF builds, `ParagraphOptions.item_origin`) the pen position after the glyph's advance and
    /// word spacing, exact within its item: a run ends at its last glyph's, as takumi's runs end at
    /// their origin plus their advance; NaN when not placed so.
    x_end: if (item_origin_build) f32 else void = if (item_origin_build) std.math.nan(f32) else {},
};

pub const Line = struct {
    /// Y of the baseline, top of the line box, and line box height (paragraph space).
    baseline: f32,
    top: f32,
    height: f32,
    /// Left edge after alignment and exact (unrounded) advance width of the visible content
    /// (trailing spaces excluded, ellipsis included).
    x: f32,
    width: f32,
    /// Range into `TextLayout.glyphs`.
    glyph_start: u32,
    glyph_end: u32,
    /// Line box extent above / below the baseline (half-leading included).
    ascent: f32,
    descent: f32,
    /// Paragraph direction is right-to-left (glyph x positions are visual either way).
    rtl: bool = false,
    /// (PDF builds) `glyphs[marker0..marker1]` are the line's overflow marker (`text-overflow` /
    /// line-clamp), drawn in place of the hidden text; none when equal.
    marker0: if (item_origin_build) u32 else void = if (item_origin_build) 0 else {},
    marker1: if (item_origin_build) u32 else void = if (item_origin_build) 0 else {},
    /// (PDF builds) the paragraph's shaped glyph the line starts at (`Paragraph.cut` of another
    /// layout of the same paragraph: src/pdf/paged.zig)
    start: if (item_origin_build) u32 else void = if (item_origin_build) 0 else {},
};

/// Position of an atomic inline (margin-box top-left) or the static position of an out-of-flow
/// box, in paragraph space.
pub const ObjectPos = struct { id: u32, x: f32, y: f32, line: u32 };

/// Fragment of an inline box on one line: the horizontal extent of its border box (edges
/// included when `first` / `last`) and the baseline its text sits on.
pub const BoxFragment = struct {
    /// index into `ParagraphOptions.boxes`
    box: u32,
    line: u32,
    x0: f32,
    x1: f32,
    baseline: f32,
    /// the fragment has the box's inline-start / inline-end edge
    first: bool = false,
    last: bool = false,
    /// the start edge is on the right (fragment of a right-to-left run)
    rtl: bool = false,
    /// primary face of the box's font
    face: FaceId = 0,
    /// (internal: vertical shift slot)
    slot: u32 = 0,
};

/// Shaping segments longer than this many characters are split at the start of a word.
/// Ligatures and multiple substitutions edit the shaping buffer in place (O(segment) each), so
/// one 120k-character run cost seconds; real text never shapes across thousands of characters.
const max_segment = 4096;

/// Whether a long segment may end before `cp` (after `prev`): at a word start, or past 4 x
/// `max_segment` between any two Latin-range characters (never a cluster continuation).
fn longSegmentBreak(prev: u21, cp: u21, len: usize) bool {
    if (prev == ' ' and cp != ' ') return true;
    return len >= 4 * max_segment and prev < 0x300 and cp < 0x300;
}

/// Stable sort of fragments by box (paint order: box by box, each box line by line). A counting
/// sort: an insertion sort here was quadratic when many lines each add fragments of several
/// boxes (a 125 KB text run spent 0.6 s here).
fn sortFragsByBox(alloc: std.mem.Allocator, fr: []BoxFragment) !void {
    var max_box: u32 = 0;
    var sorted = true;
    for (fr, 0..) |f, i| {
        max_box = @max(max_box, f.box);
        if (i > 0 and fr[i - 1].box > f.box) sorted = false;
    }
    if (sorted) return;
    const start = try alloc.alloc(u32, @as(usize, max_box) + 1);
    defer alloc.free(start);
    const tmp = try alloc.dupe(BoxFragment, fr);
    defer alloc.free(tmp);
    @memset(start, 0);
    for (fr) |f| start[f.box] += 1;
    var sum: u32 = 0;
    for (start) |*s| {
        const c = s.*;
        s.* = sum;
        sum += c;
    }
    for (tmp) |f| {
        fr[start[f.box]] = f;
        start[f.box] += 1;
    }
}

test "sortFragsByBox is a stable sort by box" {
    var fr = [_]BoxFragment{
        .{ .box = 2, .line = 0, .x0 = 0, .x1 = 0, .baseline = 0 },
        .{ .box = 1, .line = 0, .x0 = 0, .x1 = 0, .baseline = 0 },
        .{ .box = 2, .line = 1, .x0 = 0, .x1 = 0, .baseline = 0 },
        .{ .box = 0, .line = 1, .x0 = 0, .x1 = 0, .baseline = 0 },
        .{ .box = 1, .line = 1, .x0 = 0, .x1 = 0, .baseline = 0 },
    };
    try sortFragsByBox(std.testing.allocator, &fr);
    const want = [_][2]u32{ .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 2, 0 }, .{ 2, 1 } };
    for (fr, want) |f, w| try std.testing.expectEqual(w, [2]u32{ f.box, f.line });
}

/// A maximal sequence of glyphs of one run on one line (`glyphs[g0..g1]`), with its exact
/// horizontal extent and its (possibly shifted) baseline.
/// `box`: (internal) innermost inline box of the run, 0 = none.
pub const Segment = struct { g0: u32, g1: u32, x0: f32, x1: f32, baseline: f32, line: u32, box: u32 = 0 };

pub const Size = struct {
    /// Widest line, ceiled to 1/64 px (what takumi reports as the text box inline size).
    width: f32,
    /// Sum of the line box heights.
    height: f32,
    line_count: u32 = 0,
    /// Widest line, exact float.
    exact_width: f32 = 0,
    /// Baseline of the first / last line from the top (0 without lines).
    first_baseline: f32 = 0,
    last_baseline: f32 = 0,
};

pub const TextLayout = struct {
    width: f32,
    height: f32,
    /// Widest line before the 1/64 ceil.
    exact_width: f32,
    lines: []Line,
    glyphs: []PositionedGlyph,
    /// Paragraphs with inline boxes / objects (`Paragraph.complex`) only: atomic inlines and
    /// out-of-flow static positions, inline box fragments (ordered by box, outer boxes first,
    /// then by line), and the run segments covering `glyphs` in order.
    objects: []ObjectPos = &.{},
    boxes: []BoxFragment = &.{},
    segments: []Segment = &.{},
    /// The percentage base the inline box edges were resolved against (`Paragraph.setPercentBase`).
    pct_base: f32 = 0,

    pub fn deinit(self: *TextLayout, alloc: std.mem.Allocator) void {
        alloc.free(self.objects);
        alloc.free(self.boxes);
        alloc.free(self.segments);
        alloc.free(self.lines);
        alloc.free(self.glyphs);
        self.* = undefined;
    }
};

/// Per (run, face) data shared by glyphs.
pub const Metric = struct {
    run: u16,
    face: FaceId,
    size: f32,
    user: u32,
    /// Line box contribution above / below the baseline for `line-height: normal` (rounded
    /// font ascent / descent plus the font's line gap split as half-leading), px.
    ascent: f32,
    descent: f32,
    /// Unrounded font ascent / descent at this size (for decoration / selection boxes).
    font_ascent: f32,
    font_descent: f32,
    /// Hyphen shown when a line breaks at a soft hyphen (U+2010, else '-', in this face).
    hyphen_gid: u16 = 0,
    hyphen_cp: u21 = '-',
    hyphen_adv: f32 = 0,
    /// The run does not wrap (no emergency break inside it either).
    nowrap: bool = false,
    /// `overflow-wrap` of the run: whether an overflowing word may be split before a glyph of it.
    ow: OverflowWrap = .normal,
};

pub inline fn ceil64(x: f32) f32 {
    return @ceil(x * 64.0) * (1.0 / 64.0);
}
inline fn ceil64d(x: f64) f64 {
    return @ceil(x * 64.0) * (1.0 / 64.0);
}
pub inline fn floor64(x: f32) f32 {
    return @trunc(x * 64.0) * (1.0 / 64.0);
}

/// Round half away from zero (Rust `f32::round`), without pulling in compiler-rt's `round`.
inline fn roundAway(x: f32) f32 {
    return if (x >= 0) @floor(x + 0.5) else -@floor(0.5 - x);
}

fn computeMetric(font: *const Font, size: f32, lh: LineHeight) [4]f32 {
    const lm = font.lineMetrics();
    const s = size / @as(f32, @floatFromInt(font.units_per_em));
    const fa = @as(f32, @floatFromInt(lm.ascent)) * s;
    const fd = @as(f32, @floatFromInt(lm.descent)) * s;
    const a = roundAway(fa);
    const d = roundAway(fd);
    const line_height = switch (lh) {
        .normal => a + d + roundAway(@as(f32, @floatFromInt(lm.leading)) * s),
        // Blink `ComputedLineHeightAsFixed` (takumi font_style.rs): a length rounds to the nearest
        // layout unit; a number (kept as a percentage) multiplies the font size rounded to a layout
        // unit and truncates. Truncating `m * size` directly is 1/64 px short per line at sizes such
        // as 9.5pt (12.67px x 1.3), which adds up over long pages.
        .px => |v| roundAway(v * 64.0) * (1.0 / 64.0),
        .multiple => |m| floor64(roundAway(size * 64.0) * (1.0 / 64.0) * (m * 100.0) / 100.0),
    };
    const lead_a = @floor((line_height - (a + d)) * 0.5);
    const lead_d = line_height - (a + d) - lead_a;
    return .{ a + lead_a, d + lead_d, fa, fd };
}

/// Advance of `units` font units at `size` px, rounded to 16.16 like HarfBuzz positions.
inline fn scaleAdvance(units: i32, scale: f64) f32 {
    const v = @as(f64, @floatFromInt(units)) * scale;
    const r = if (v >= 0) @floor(v + 0.5) else -@floor(0.5 - v);
    return @floatCast(r * (1.0 / 65536.0));
}

const Char = struct {
    cp: u21,
    brk: bool = false,
    level: u8 = 0,
    run: u16,
    cluster: u32,
    /// the run does not wrap (white-space: nowrap / pre)
    nw: bool = false,
    /// stands for an atomic inline (U+FFFC)
    obj: bool = false,
};

const CharInfo = struct { n: usize = 0, any_wrap: bool = false, any_nowrap: bool = false, any_obj: bool = false };

/// Per inline box data resolved at `init` ([0] = the block itself).
const BoxInfo = struct {
    parent: u32 = 0,
    valign: VerticalAlign = .baseline,
    /// strut of the box (its font with the half-leading of its line-height)
    ascent: f32 = 0,
    descent: f32 = 0,
    /// rounded font ascent (Blink's text top) and the unrounded font ascent / descent
    text_ascent: f32 = 0,
    font_ascent: f32 = 0,
    font_descent: f32 = 0,
    x_height: f32 = 0,
    font_size: f32 = 0,
    /// line-height: normal (every font used inside grows the box)
    normal_lh: bool = true,
    start: f32 = 0,
    end: f32 = 0,
    margin_start: f32 = 0,
    margin_end: f32 = 0,
    face: FaceId = 0,
    clone: bool = false,
    rtl: bool = false,
    no_start: bool = false,
    no_end: bool = false,
    rel: [2]f32 = .{ 0, 0 },
    pct: ?EdgeParts = null,

    /// `start` / `end` / `margin_*` of a box with percentage edges for the base `base` (each part on
    /// the 1/64 px grid, like the px-only edges).
    fn resolveEdges(bi: *BoxInfo, base: f32) void {
        const e = bi.pct orelse return;
        var m: [2]f32 = undefined;
        var r: [2]f32 = undefined;
        for (0..2) |k| {
            m[k] = @trunc((e.margin[k] + e.margin_pct[k] * base) * 64) / 64;
            r[k] = m[k] + @trunc(e.border[k] * 64) / 64 + @trunc(@max(e.padding[k] + e.padding_pct[k] * base, 0) * 64) / 64;
            if (!std.math.isFinite(m[k]) or !std.math.isFinite(r[k])) return;
        }
        bi.start = r[0];
        bi.end = r[1];
        bi.margin_start = m[0];
        bi.margin_end = m[1];
    }
};

const ObjInfo = struct { box: u32, valign: VerticalAlign };

fn wsWraps(ws: WhiteSpace) bool {
    return ws != .nowrap and ws != .pre;
}

noinline fn boxInfo(fonts: *const FontCollection, st: TextStyle, lh: LineHeight) BoxInfo {
    var bi: BoxInfo = .{ .font_size = st.size, .normal_lh = lh == .normal };
    var buf: [max_faces]FaceId = undefined;
    const faces = matchStyle(fonts, st, &buf);
    if (faces.len == 0) return bi;
    const f = fonts.font(faces[0]);
    const m = computeMetric(f, st.size, lh);
    bi.face = faces[0];
    bi.ascent = m[0];
    bi.descent = m[1];
    bi.font_ascent = m[2];
    bi.font_descent = m[3];
    bi.text_ascent = roundAway(m[2]);
    const xh = f.xHeight();
    const upm: f32 = @floatFromInt(@max(f.units_per_em, 1));
    // (Blink's fallback without an OS/2 x-height)
    bi.x_height = if (xh > 0) @as(f32, @floatFromInt(xh)) * st.size / upm else m[2] * 0.56;
    return bi;
}

const max_faces = 16;

/// Shapes `text` with one style: UTF-8 -> glyphs with fallback, ligatures, kerning and spacing.
/// No white-space processing except: control characters are dropped and zero-width characters
/// produce no glyph. Glyphs are in logical order. Returned slice is owned by the caller
/// (`alloc.free`).
pub fn shape(alloc: std.mem.Allocator, fonts: *const FontCollection, text: []const u8, style: TextStyle) ![]ShapedGlyph {
    var p = try Paragraph.init(alloc, fonts, &.{.{ .text = text, .style = style }}, .{ .white_space = .pre });
    defer p.deinit();
    var n: usize = 0;
    for (p.glyphs) |g| {
        if (g.flags & ShapedGlyph.HARD_BREAK == 0) {
            p.glyphs[n] = g;
            n += 1;
        }
    }
    return alloc.dupe(ShapedGlyph, p.glyphs[0..n]);
}

/// An overflow marker: one glyph `count` times (the default "…" / "..."), or a shaped string.
pub const Marker = struct {
    on: bool = false,
    face: FaceId = 0,
    gid: u16 = 0,
    count: u8 = 0,
    adv: f32 = 0,
    size: f32 = 0,
    user: u32 = 0,
    /// Shaped custom string (x from the marker start, y from the baseline; visual order).
    /// Non-empty overrides face / gid / count.
    glyphs: []PositionedGlyph = &.{},
    /// Advance width of the whole marker.
    w: f32 = 0,

    fn len(m: *const Marker) usize {
        return if (m.glyphs.len > 0) m.glyphs.len else m.count;
    }
};

/// A paragraph shaped once; line breaking for different widths is cheap (`measure` allocates
/// nothing, `layout` allocates only the result).
pub const Paragraph = struct {
    alloc: std.mem.Allocator,
    opts: ParagraphOptions,
    /// Shaped glyphs in logical order (a right-to-left run is stored first-character-first).
    glyphs: []ShapedGlyph,
    metrics: []Metric,
    /// Strut line box contribution.
    strut_ascent: f32 = 0,
    strut_descent: f32 = 0,
    strut_size: f32 = 16,
    /// text-overflow marker / line-clamp marker
    ell: Marker = .{},
    clamp_ell: Marker = .{},
    /// More than one inline item (style run or bidi run).
    multi_run: bool = false,
    /// Paragraph direction is right-to-left.
    rtl: bool = false,
    /// `unicode-bidi: plaintext`: the direction of each bidi paragraph, when one differs from
    /// `rtl` (a line's alignment, reordering and ellipsis side follow its paragraph's).
    plain_paras: []PlainPara = &.{},
    /// Some glyph has a non-zero bidi level (lines need visual reordering).
    has_bidi: bool = false,
    /// Some run allows soft wraps.
    any_wrap: bool = true,
    /// The paragraph has objects, or inline boxes with edges / a `vertical-align` / a strut of
    /// their own: `glyphs` then contains `SPECIAL` entries, lines are built by the inline box
    /// state machine and `layout*` reports `objects`, `boxes` and `segments`.
    /// `measureFlow` / `layoutFlow` must be used when there are atomic objects.
    complex: bool = false,
    /// complex only: [0] = the block, [k + 1] = `ParagraphOptions.boxes[k]`
    boxes: []BoxInfo = &.{},
    /// complex only: internal box index per run
    run_box: []u32 = &.{},
    /// complex only: indexed by `ShapedGlyph.metric` of object specials
    objs: []ObjInfo = &.{},
    /// Some inline box with edges is `box-decoration-break: clone`.
    has_clone: bool = false,
    /// `opts.indent` / `opts.indent_pct` is set (text-indent)
    has_indent: bool = false,
    /// Some inline box is `direction: rtl` (its edges need visual placement on every line).
    has_rtl_box: bool = false,
    /// Some inline box has percentage margins / padding; the base they are resolved for at the moment.
    has_pct_edges: bool = false,
    pct_base: f32 = 0,
    /// Some inline box is relatively positioned (`InlineBox.rel`).
    has_rel: bool = false,
    /// (PDF builds) a line ends right before this shaped glyph, everything before it on one line
    /// (`no_stop`: none): a paragraph continued on a page of another width starts its lines there
    /// (src/pdf/paged.zig).
    cut: if (item_origin_build) u32 else void = if (item_origin_build) no_stop else {},

    /// Compile-time selection of the optional text machinery (see `initWith`).
    pub const Features = struct {
        /// Bidi, script shapers (Arabic, Hebrew, Thai, Indic), normalisation, full UAX #14.
        /// false: default shaper only, left-to-right, none of the Unicode tables are linked.
        complex: bool = true,
        /// Emoji-presentation clusters prefer a face with colour tables (links `color.zig`'s
        /// emoji scanner and `ColorTables`).
        color_emoji: bool = false,
    };

    /// Shapes `runs` (concatenated into one paragraph) with complex-text support (bidi, script
    /// shapers, normalisation, full UAX #14). `alloc` owns the cached glyphs until `deinit`
    /// (a per-render arena is fine). `fonts` is only used during `init`; the texts are not
    /// referenced afterwards.
    /// (In an engine build the complex machinery follows the `complex_text` build switch, read
    /// through `@import("root").bm_config`, so helper callers such as SVG text do not link it.)
    pub fn init(alloc: std.mem.Allocator, fonts: *const FontCollection, runs: []const Run, opts: ParagraphOptions) !Paragraph {
        return initWith(.{ .complex = build_complex }, alloc, fonts, runs, opts);
    }

    const build_complex = blk: {
        const root = @import("root");
        break :blk if (@hasDecl(root, "bm_config")) root.bm_config.enable_complex_text else true;
    };

    /// `init` with complex text selectable at compile time (no colour-emoji font preference).
    pub fn initEx(comptime complex: bool, alloc: std.mem.Allocator, fonts: *const FontCollection, runs: []const Run, opts: ParagraphOptions) !Paragraph {
        return initWith(.{ .complex = complex }, alloc, fonts, runs, opts);
    }

    /// `init` with the optional machinery selected at compile time: code and tables of a
    /// feature that is off are not referenced, so they do not reach the binary.
    pub fn initWith(comptime feat: Features, alloc: std.mem.Allocator, fonts: *const FontCollection, runs: []const Run, opts: ParagraphOptions) !Paragraph {
        var p = try initCore(feat, alloc, fonts, runs, opts);
        if (opts.ellipsis_text == null and opts.clamp_text == null and !opts.clamp_no_ellipsis) return p;
        errdefer p.deinit();
        if (opts.clamp_no_ellipsis) {
            p.clamp_ell = .{};
        } else if (opts.clamp_text) |t| {
            if (p.ell.on and opts.max_lines != null) p.clamp_ell = try shapeMarker(feat, alloc, fonts, runs, opts, t);
        }
        if (opts.ellipsis_text) |t| {
            if (p.ell.on and opts.ellipsis) p.ell = try shapeMarker(feat, alloc, fonts, runs, opts, t);
        }
        return p;
    }

    /// Shapes a custom overflow marker (takumi `LineTruncator::setup_ellipsis`): the string in
    /// the block's style and the paragraph direction, laid out on one line.
    noinline fn shapeMarker(comptime feat: Features, alloc: std.mem.Allocator, fonts: *const FontCollection, runs: []const Run, opts: ParagraphOptions, raw: []const u8) !Marker {
        const st: TextStyle = opts.strut orelse if (runs.len > 0) runs[0].style else .{};
        const text = try markerText(alloc, raw);
        defer alloc.free(text);
        var mk: Marker = .{ .on = true, .size = st.size, .user = st.user };
        if (text.len == 0) return mk;
        // (the block options, minus everything about lines: one unwrapped, preserved line)
        var so = opts;
        so.max_width = null;
        so.text_align = .left;
        so.white_space = .pre;
        so.max_lines = null;
        so.ellipsis = false;
        so.ellipsis_text = null;
        so.clamp_text = null;
        so.strut = st;
        so.text_wrap = .wrap;
        so.boxes = &.{};
        var sub = try initCore(feat, alloc, fonts, &.{.{ .text = text, .style = st }}, so);
        defer sub.deinit();
        var tl = try sub.layout(alloc, null);
        defer tl.deinit(alloc);
        if (tl.lines.len == 0) return mk;
        const ln = tl.lines[0];
        if (ln.glyph_end <= ln.glyph_start or ln.glyph_end > tl.glyphs.len) return mk;
        const gl = try alloc.alloc(PositionedGlyph, ln.glyph_end - ln.glyph_start);
        for (gl, tl.glyphs[ln.glyph_start..ln.glyph_end]) |*o, g| {
            o.* = g;
            o.x = g.x - ln.x;
            o.y = g.y - ln.baseline;
        }
        mk.glyphs = gl;
        mk.w = ceil64(ln.width);
        return mk;
    }

    noinline fn initCore(comptime feat: Features, alloc: std.mem.Allocator, fonts: *const FontCollection, runs: []const Run, opts: ParagraphOptions) !Paragraph {
        const complex = feat.complex;
        var total: usize = 0;
        for (runs) |r| total += r.text.len;
        if (total > 0x3fff_ffff or runs.len > 0xffff) return error.OutOfMemory;

        const tmp = opts.scratch orelse alloc;
        const chars = try tmp.alloc(Char, total + 2 * runs.len);
        defer tmp.free(chars);
        var info: CharInfo = .{};
        collectChars(runs, opts, chars, &info);
        const n_chars = info.n;
        const rtl_base = complex and opts.direction == .rtl;
        if (info.any_wrap) {
            if (complex) {
                try markBreaksFull(tmp, chars[0..n_chars], opts);
            } else markBreaks(chars[0..n_chars], opts);
            if (info.any_nowrap or info.any_obj) fixBreaks(chars[0..n_chars]);
            // `hyphens: none` (CSS Text 3 §5.4): not even a soft hyphen breaks a word
            if (n_chars > 1) for (chars[1..n_chars], chars[0 .. n_chars - 1]) |*c, prev| {
                if (c.brk and prev.cp == 0xad and prev.run < runs.len and runs[prev.run].style.no_hyphens) c.brk = false;
            };
        }
        var plain_paras: std.ArrayList(PlainPara) = .empty;
        errdefer plain_paras.deinit(alloc);
        if (complex) {
            var css_bidi = if (opts.strut) |s| s.unicode_bidi != .normal else false;
            for (runs) |r| css_bidi = css_bidi or r.style.unicode_bidi != .normal;
            for (opts.boxes) |box| css_bidi = css_bidi or box.style.unicode_bidi != .normal;
            if (css_bidi) try resolveCssBidi(tmp, chars[0..n_chars], runs, opts, &plain_paras, alloc) else try resolveBidi(tmp, chars[0..n_chars], rtl_base);
        }

        var local_cache = shp.Cache.init(tmp);
        defer local_cache.deinit();
        var b: Builder = .{
            .alloc = alloc,
            .fonts = fonts,
            .opts = opts,
            .chars = chars[0..n_chars],
            .cache = opts.shape_cache orelse &local_cache,
            .buf = .{ .alloc = tmp },
            .tmp = tmp,
        };
        defer b.buf.deinit();
        errdefer b.glyphs.deinit(alloc);
        errdefer b.metrics.deinit(alloc);
        errdefer b.objs.deinit(alloc);
        errdefer alloc.free(b.boxes);
        errdefer alloc.free(b.run_box);
        defer b.open_tmp.deinit(tmp);
        try b.prepareBoxes(runs);
        // (exact: the list is handed over as is, and a bump arena keeps all its capacity)
        try b.glyphs.ensureTotalCapacityPrecise(alloc, n_chars);
        try b.buf.list.ensureTotalCapacity(tmp, @min(n_chars, 256));
        try b.build(feat, runs);
        if (b.cx) moveBreaks(b.glyphs.items);

        var p: Paragraph = .{ .alloc = alloc, .opts = opts, .glyphs = &.{}, .metrics = &.{}, .multi_run = b.item > 1, .rtl = rtl_base, .has_bidi = b.any_rtl or rtl_base, .any_wrap = info.any_wrap, .complex = b.cx };
        p.opts.boxes = &.{};
        p.opts.scratch = null;
        p.has_indent = opts.indent != 0 or opts.indent_pct != 0;
        // strut + ellipsis
        const strut_style: ?TextStyle = opts.strut orelse if (runs.len > 0) runs[0].style else null;
        if (strut_style) |st| {
            var buf: [max_faces]FaceId = undefined;
            const faces = matchStyle(fonts, st, &buf);
            p.strut_size = st.size;
            if (faces.len > 0) {
                const m = computeMetric(fonts.font(faces[0]), st.size, opts.line_height);
                p.strut_ascent = m[0];
                p.strut_descent = m[1];
                if (opts.ellipsis or opts.max_lines != null) {
                    var cp: u21 = 0x2026;
                    var count: u8 = 1;
                    var pick = pickFace(fonts, faces, cp);
                    if (pick.gid == 0) {
                        cp = '.';
                        count = 3;
                        pick = pickFace(fonts, faces, cp);
                    }
                    const f = fonts.font(pick.face);
                    const adv = scaleAdvance(f.advanceWidth(pick.gid), @as(f64, st.size) * 65536.0 / @as(f64, @floatFromInt(f.units_per_em)));
                    p.ell = .{ .on = true, .face = pick.face, .gid = pick.gid, .count = count, .size = st.size, .user = st.user, .adv = adv, .w = ceil64(adv * @as(f32, @floatFromInt(count))) };
                    p.clamp_ell = p.ell;
                }
            }
        }
        if (b.cx and b.boxes.len > 0) {
            // the block's own box: the strut
            b.boxes[0].ascent = p.strut_ascent;
            b.boxes[0].descent = p.strut_descent;
        }
        p.glyphs = try b.glyphs.toOwnedSlice(alloc);
        errdefer alloc.free(p.glyphs);
        p.metrics = try b.metrics.toOwnedSlice(alloc);
        errdefer alloc.free(p.metrics);
        p.objs = try b.objs.toOwnedSlice(alloc);
        errdefer alloc.free(p.objs);
        // (one paragraph whose direction is the block's: nothing per line to look up)
        if (plain_paras.items.len > 1 or (plain_paras.items.len == 1 and plain_paras.items[0].rtl != rtl_base)) {
            p.plain_paras = try plain_paras.toOwnedSlice(alloc);
        } else plain_paras.deinit(alloc);
        p.has_clone = b.cx and b.has_clone;
        p.has_rtl_box = b.cx and b.has_rtl_box;
        p.has_pct_edges = b.cx and b.has_pct;
        p.has_rel = b.cx and b.has_rel;
        p.boxes = b.boxes;
        p.run_box = b.run_box;
        return p;
    }

    pub fn deinit(self: *Paragraph) void {
        if (self.clamp_ell.glyphs.len > 0) self.alloc.free(self.clamp_ell.glyphs);
        if (self.ell.glyphs.len > 0) self.alloc.free(self.ell.glyphs);
        self.alloc.free(self.glyphs);
        self.alloc.free(self.metrics);
        self.alloc.free(self.objs);
        self.alloc.free(self.boxes);
        self.alloc.free(self.run_box);
        self.alloc.free(self.plain_paras);
        self.* = undefined;
    }

    /// The base direction of the line starting at glyph `start` (`plain_paras`).
    fn lineRtl(self: *const Paragraph, start: u32) bool {
        if (self.plain_paras.len == 0) return self.rtl;
        const cluster = if (start < self.glyphs.len) self.glyphs[start].cluster else if (self.glyphs.len > 0) self.glyphs[self.glyphs.len - 1].cluster else 0;
        var rtl = self.rtl;
        for (self.plain_paras) |pp| {
            if (pp.cluster > cluster) break;
            rtl = pp.rtl;
        }
        return rtl;
    }

    fn wraps(self: *const Paragraph) bool {
        return self.any_wrap;
    }

    /// Resolves the percentage margins / padding of the inline boxes against `base` (the width of the
    /// containing block; 0 or a non-finite value = intrinsic sizing, where they are 0) for the measure /
    /// layout calls that follow. Cheap when nothing changes; a paragraph without such boxes ignores it.
    pub fn setPercentBase(self: *Paragraph, base: f32) void {
        if (!self.has_pct_edges) return;
        const b: f32 = if (std.math.isFinite(base) and base > 0) base else 0;
        if (b == self.pct_base) return;
        self.pct_base = b;
        for (self.boxes) |*bi| bi.resolveEdges(b);
        for (self.glyphs) |*g| {
            if (g.flags & ShapedGlyph.SPECIAL == 0 or g.gid > Special.close or g.cluster >= self.boxes.len) continue;
            const bi = &self.boxes[g.cluster];
            if (bi.pct != null) g.x_advance = if (g.gid == Special.open) bi.start else bi.end;
        }
    }

    const LineInfo = struct {
        start: u32,
        /// End of the visible content (trailing spaces excluded; after ellipsis truncation).
        end: u32,
        next: u32,
        width: f32,
        /// Width used for alignment (differs from `width` only for hanging pre-wrap spaces).
        content_w: f32 = 0,
        /// Line ends the paragraph or at a forced break (not justified).
        last: bool,
        /// Line ends at a forced break.
        hard: bool = false,
        /// Broken at a soft hyphen: a visible hyphen follows the content.
        hyphen: bool = false,
        ellipsis: bool = false,
        /// The ellipsis is the line-clamp marker (`clamp_ell`), not the text-overflow one.
        ell_clamp: bool = false,
        /// Paragraph-cumulative advance at `next`.
        cum: f64 = 0,
        ascent: f32 = 0,
        descent: f32 = 0,
        /// Width without hanging spaces (what has to fit beside a float).
        ink_w: f32 = 0,
        /// Flow layout: top of the line box, start and width of its free inline range.
        top: f32 = 0,
        band_x: f32 = 0,
        band_w: f32 = 0,
        /// Flow layout: the line holds nothing but floats / out-of-flow boxes (no line box).
        empty: bool = false,
        /// text-indent applied to the line (included in the widths)
        indent: f32 = 0,
    };

    const Mode = struct {
        avail: ?f32,
        /// Honour max_lines / ellipsis.
        clamp: bool = true,
        /// Emergency breaks (inside an overflowing word) may be taken where the run of the glyph allows
        /// them (`Metric.ow`, see `emergencyAt`).
        emergency: bool,
        /// Min-content sizing: only `overflow-wrap: anywhere` splits words (`break-word` does not, as in CSS).
        min_content: bool = false,
        /// text-wrap strategy (only set by measure / layout proper, not by min/max content).
        strategy: TextWrap = .wrap,
        /// Sizes of the atomic objects (null: they are zero-sized).
        flow: ?*const Flow = null,
        /// text-indent of the line being broken (set per line by `LineIter`)
        indent: f32 = 0,
    };

    const no_stop: u32 = 0xffff_ffff;

    /// Greedy line breaker reproducing Blink's `ShapingLineBreaker` arithmetic: glyph positions
    /// are cumulative from the paragraph start (`s_cum` at `start`), each ceiled to 1/64 px, and
    /// a break fits when ceil64(position of the break) <= ceil64(position of the line start) +
    /// available width. Kerning against the glyph after a non-space break is undone (Blink
    /// reshapes the line end) and a soft-hyphen break must also fit its hyphen.
    /// `stop_at` != `no_stop` forces the line to end exactly before that glyph (score breaker).
    fn nextLine(self: *const Paragraph, start: u32, s_cum: f64, m: Mode, stop_at: u32) LineInfo {
        var li = self.breakLine(start, s_cum, m, stop_at);
        if (m.indent != 0) {
            li.indent = m.indent;
            li.width += m.indent;
            li.content_w += m.indent;
            li.ink_w += m.indent;
        }
        return li;
    }

    /// Whether an overflowing word may be split before a glyph of metric `metric`: its run's
    /// `overflow-wrap` (the paragraph's unless the run has its own) decides.
    inline fn emergencyAt(self: *const Paragraph, m: Mode, metric: u16) bool {
        if (!m.emergency or metric >= self.metrics.len) return false;
        const ow = self.metrics[metric].ow;
        return if (m.min_content) ow == .anywhere else ow != .normal;
    }

    fn breakLine(self: *const Paragraph, start: u32, s_cum: f64, m: Mode, stop_at: u32) LineInfo {
        return self.breakLineShrunk(start, s_cum, m, stop_at, 0);
    }

    /// `breakLine` with the available width less `shrink` for every fit except a soft hyphen's
    /// own hyphen (Blink's ShapingLineBreaker retry: a hyphen that does not fit after the content
    /// before it shrinks the width by the hyphen and looks for the break again).
    fn breakLineShrunk(self: *const Paragraph, start: u32, s_cum: f64, m: Mode, stop_at: u32, shrink: f64) LineInfo {
        const gs = self.glyphs;
        const n: u32 = @intCast(gs.len);
        const forced = stop_at != no_stop and stop_at <= n;
        const end_i = if (forced) stop_at else n;
        const wrap = !forced and m.avail != null and self.wraps();
        // fit checks compare against the available width plus one layout unit (Blink
        // `AvailableWidthToFit` = `AvailableWidth().AddEpsilon()`, takumi line_breaker.rs): content
        // whose snapped width exceeds the width by less than 1/64 px still fits
        var limit: f64 = ceil64d(s_cum) + @as(f64, if (m.avail) |a| floor64(@max(a, 0)) + 1.0 / 64.0 else 0) - m.indent;
        var i = start;
        var cum = s_cum;
        // box-decoration-break: clone: the end edges of the open cloned boxes (room reserved at
        // the line end); the boxes continued from the previous line start with their start edge
        var clone_end: f64 = 0;
        if (self.has_clone and start < n) {
            var b = self.boxBefore(start);
            while (b != 0) : (b = self.boxes[b].parent) {
                if (!self.boxes[b].clone) continue;
                cum += self.boxes[b].start;
                clone_end += self.boxes[b].end;
            }
            limit -= clone_end;
        }
        // (the hyphen of a soft hyphen fits the width before any retry shrank it)
        const hyphen_limit = limit;
        limit -= shrink;
        var cum_content = cum;
        var content_end = start;
        var brk: LineInfo = undefined;
        var has_brk = false;
        // the last breakpoint whose content fits is a soft hyphen whose hyphen does not: the width
        // to shrink by when the line has to break (0: none)
        var shy_retry: f64 = 0;
        // collapsible spaces since the last content; width of the closing edges after such spaces
        // (Blink: trailable items, they may overhang the line end)
        var sp = false;
        var oh: f64 = 0;
        while (i < end_i) : (i += 1) {
            const g = gs[i];
            // every inline item (style run / bidi run) has its origin snapped to 1/64 px
            if (self.multi_run and i > start and g.item != gs[i - 1].item)
                cum = s_cum + ceil64d(cum - s_cum);
            if (g.flags & ShapedGlyph.HARD_BREAK != 0) {
                // closing edges right after a forced break still belong to its line
                var nx = i + 1;
                if (self.complex) while (nx < n) : (nx += 1) {
                    const q = gs[nx];
                    if (q.flags & ShapedGlyph.SPECIAL == 0) break;
                    if (q.gid == Special.close) {
                        if (self.has_clone and q.cluster < self.boxes.len and self.boxes[q.cluster].clone) clone_end -= self.boxes[q.cluster].end;
                        cum += q.x_advance;
                        cum_content += q.x_advance;
                        content_end = nx + 1;
                    } else break;
                };
                return self.fin(.{ .start = start, .end = content_end, .next = nx, .width = @floatCast(cum_content - s_cum + clone_end), .last = true, .hard = true, .cum = cum }, s_cum);
            }
            if (wrap and i > start and g.flags & ShapedGlyph.BREAK_BEFORE != 0) {
                var e = cum_content;
                var hyphen = false;
                const end = content_end;
                var hyphen_misses = false;
                if (content_end == i) {
                    e -= gs[i - 1].kern;
                    if (g.flags & ShapedGlyph.SOFT_HYPHEN != 0) {
                        hyphen = true;
                        const ha = self.metrics[gs[i - 1].metric].hyphen_adv;
                        // (the content fits, its hyphen does not: Blink shrinks the width by the
                        // hyphen and breaks again, unless a later breakpoint fits)
                        hyphen_misses = e - oh <= limit and e + ha - oh > hyphen_limit;
                        if (hyphen_misses) shy_retry = ha;
                        e += ha;
                    }
                }
                const fits = if (hyphen) e - oh <= hyphen_limit and e - self.metrics[gs[i - 1].metric].hyphen_adv - oh <= limit else e - oh <= limit;
                if (!has_brk or fits) {
                    has_brk = true;
                    brk = .{ .start = start, .end = end, .next = i, .width = @floatCast(e - s_cum + clone_end), .last = false, .hyphen = hyphen, .cum = cum };
                }
                if (fits) shy_retry = 0;
            }
            const nc = cum + self.advanceOf(g, @floatCast(cum - s_cum), m.flow);
            if (g.flags & (ShapedGlyph.SPACE | ShapedGlyph.SPECIAL) != 0) {
                if (g.flags & ShapedGlyph.SPECIAL == 0) {
                    cum = nc;
                    sp = true;
                    continue;
                }
                // floats and out-of-flow boxes are transparent
                if (g.gid >= Special.float) continue;
                if (self.has_clone and g.cluster < self.boxes.len and self.boxes[g.cluster].clone) {
                    const ee: f64 = self.boxes[g.cluster].end;
                    const d: f64 = if (g.gid == Special.open) ee else -ee;
                    clone_end += d;
                    limit -= d;
                }
                if (g.gid == Special.atomic) {
                    sp = false;
                    oh = 0;
                    if (wrap and has_brk and ceil64d(nc) > limit) {
                        if (shy_retry > 0 and shrink + shy_retry < limit - s_cum) return self.breakLineShrunk(start, s_cum, m, stop_at, shrink + shy_retry);
                        return self.fin(brk, s_cum);
                    }
                    cum = nc;
                    cum_content = nc;
                    content_end = i + 1;
                    continue;
                }
                // an inline box edge: spaces before it collapse when the line ends after it, and a
                // closing edge after such spaces never forces a break (it overhangs)
                const cc = cum_content + (nc - cum);
                // (at the end of the paragraph the space before the edge is collapsed away, not hanging:
                // the edge has to fit)
                if (g.gid == Special.close and (sp or oh > 0) and !self.endsWithEdges(i + 1)) {
                    oh += nc - cum;
                } else {
                    oh = 0;
                    if (wrap and has_brk and ceil64d(cc) > limit) {
                        if (shy_retry > 0 and shrink + shy_retry < limit - s_cum) return self.breakLineShrunk(start, s_cum, m, stop_at, shrink + shy_retry);
                        return self.fin(brk, s_cum);
                    }
                }
                cum = nc;
                cum_content = cc;
                content_end = i + 1;
                continue;
            }
            // (the glyph fits where the line could end after it: without the kerning with the glyph
            // that follows, which a line ending there drops; Blink reshapes the line up to the break.
            // "MATR" in a cell as wide as "MA" unkerned breaks after "M", not after the A that the
            // A-T kerning made narrower)
            if (wrap and ceil64d(nc - g.kern) > limit) {
                if (shy_retry > 0 and shrink + shy_retry < limit - s_cum) return self.breakLineShrunk(start, s_cum, m, stop_at, shrink + shy_retry);
                if (has_brk) return self.fin(brk, s_cum);
                if (self.emergencyAt(m, g.metric) and i > start and g.flags & ShapedGlyph.NO_SPLIT == 0 and !self.metrics[g.metric].nowrap)
                    return self.fin(.{ .start = start, .end = content_end, .next = i, .width = @floatCast(cum_content - gs[i - 1].kern - s_cum + clone_end), .last = false, .cum = cum }, s_cum);
            }
            cum = nc;
            cum_content = nc;
            content_end = i + 1;
            sp = false;
            oh = 0;
        }
        if (forced and i < n) {
            if (gs[i].flags & ShapedGlyph.HARD_BREAK != 0)
                return self.fin(.{ .start = start, .end = content_end, .next = i + 1, .width = @floatCast(cum_content - s_cum), .last = true, .hard = true, .cum = cum }, s_cum);
            var e = cum_content;
            var hyphen = false;
            if (content_end == i and i > start) {
                e -= gs[i - 1].kern;
                if (gs[i].flags & ShapedGlyph.SOFT_HYPHEN != 0) {
                    hyphen = true;
                    e += self.metrics[gs[i - 1].metric].hyphen_adv;
                }
            }
            return self.fin(.{ .start = start, .end = content_end, .next = i, .width = @floatCast(e - s_cum + clone_end), .last = false, .hyphen = hyphen, .cum = cum }, s_cum);
        }
        return self.fin(.{ .start = start, .end = content_end, .next = n, .width = @floatCast(cum_content - s_cum + clone_end), .last = true, .cum = cum }, s_cum);
    }

    /// Nothing but closing edges and transparent items from glyph `from` to the paragraph end.
    fn endsWithEdges(self: *const Paragraph, from: u32) bool {
        for (self.glyphs[from..]) |g| {
            if (g.flags & ShapedGlyph.SPECIAL == 0 or g.gid == Special.open or g.gid == Special.atomic) return false;
        }
        return true;
    }

    /// pre-wrap: hanging spaces count in the reported width (as takumi reports them) but only
    /// take part in alignment on the last line of a paragraph.
    fn fin(self: *const Paragraph, line: LineInfo, s_cum: f64) LineInfo {
        var li = line;
        li.content_w = li.width;
        li.ink_w = li.width;
        if (self.opts.white_space == .pre_wrap) {
            li.width = @max(li.width, @as(f32, @floatCast(li.cum - s_cum)));
            if (li.last) li.content_w = li.width;
        }
        return li;
    }

    /// Advance of a glyph at `line_pos` px from the line start (tabs depend on the position).
    inline fn advanceOf(self: *const Paragraph, g: ShapedGlyph, line_pos: f32, flow: ?*const Flow) f32 {
        if (g.flags & (ShapedGlyph.TAB | ShapedGlyph.SPECIAL) == 0) return g.x_advance;
        return self.advanceSlow(g, line_pos, flow);
    }

    fn advanceSlow(_: *const Paragraph, g: ShapedGlyph, line_pos: f32, flow: ?*const Flow) f32 {
        if (g.flags & ShapedGlyph.SPECIAL != 0) {
            if (g.gid != Special.atomic) return g.x_advance;
            const fl = flow orelse return 0;
            if (g.cluster >= fl.objects.len) return 0;
            const w = fl.objects[g.cluster].width;
            return if (std.math.isFinite(w)) w else 0;
        }
        const interval = g.x_advance;
        if (!(interval > 0)) return 0;
        var d = interval - (line_pos - interval * @floor(line_pos / interval));
        // Blink: a tab is at least half a space wide
        if (d < g.tab_min) d += interval;
        return d;
    }

    /// Build switch `text_wrap_balance` (src/config.zig via the root module; on in standalone
    /// tests): without it `balance` / `pretty` wrap greedily like `wrap`.
    const wrap_balance = blk: {
        const root = @import("root");
        break :blk if (@hasDecl(root, "bm_config")) root.bm_config.enable_text_wrap_balance else true;
    };
    const max_balance_lines = 6;
    const max_pretty_lines = 4;
    const max_candidates = 192;

    const LineIter = struct {
        p: *const Paragraph,
        mode: Mode,
        pos: u32 = 0,
        index: u32 = 0,
        cum: f64 = 0,
        /// Break points chosen by the score breaker for the next lines (glyph indices).
        forced: [max_balance_lines]u32 = undefined,
        n_forced: u8 = 0,
        forced_i: u8 = 0,
        /// The current paragraph part has been examined: no new attempt until it ends.
        suspended: bool = false,
        /// Flow layout (`measureFlow` / `layoutFlow`): top of the next line, scratch of the line
        /// box builder, first glyph whose float has not been handled yet.
        y: f32 = 0,
        cx: ?*Cx = null,
        float_next: u32 = 0,
        /// text-indent: the resolved amount (NaN = not yet), no line box so far, the previous line
        /// ended at a forced break
        indent: f32 = std.math.nan(f32),
        first_line: bool = true,
        after_hard: bool = false,
        /// text-wrap: balance by bisection: the width the lines are broken at (NaN = not balanced)
        bal_w: f32 = std.math.nan(f32),

        /// text-indent of the next line (`first`: it is the first formatted line).
        noinline fn indentFor(it: *LineIter, first: bool) f32 {
            const o = &it.p.opts;
            if (it.indent != it.indent) {
                // (a percentage refers to the width the paragraph is broken at; nothing in intrinsic sizing)
                const base: f32 = if (it.mode.avail) |a| (if (it.mode.clamp or it.cx != null) @max(a, 0) else 0) else 0;
                const v = o.indent + o.indent_pct * base;
                it.indent = if (std.math.isFinite(v)) trunc64(v) else 0;
            }
            return if ((first or (it.after_hard and o.indent_each_line)) != o.indent_hanging) it.indent else 0;
        }

        /// Blink's `LineWidths`: the available width of every line when it is known without layout:
        /// the first `n_ex` lines (beside one float) have `ex` px, the others `def`.
        const LineW = struct {
            def: f32,
            ex: f32 = 0,
            n_ex: u32 = 0,

            inline fn at(w: LineW, line: u32) f32 {
                return if (line < w.n_ex) w.ex else w.def;
            }
        };

        /// Blink's `ScoreLineBreaker` for the paragraph part starting at the current position:
        /// fills `forced` when better break points than the greedy ones are found; `balance`
        /// falls back to bisecting the available width (`may_bisect`: the part is the whole
        /// paragraph in one layout opportunity; the result goes to `bal_w`).
        noinline fn prepare(it: *LineIter, w: LineW, may_bisect: bool) void {
            const p = it.p;
            const balance = it.mode.strategy == .balance;
            const max_lines: u32 = if (balance) max_balance_lines else max_pretty_lines;
            const n: u32 = @intCast(p.glyphs.len);
            var greedy: Mode = .{ .avail = w.def, .clamp = false, .emergency = it.mode.emergency, .flow = it.mode.flow };
            const ind_first: f32 = if (p.has_indent) it.indentFor(it.first_line) else 0;
            const ind_rest: f32 = if (p.has_indent) it.indentFor(false) else 0;
            // greedy pass
            var pos = it.pos;
            var cum = it.cum;
            var lines: u32 = 0;
            var width_sum: f32 = 0;
            var last: LineInfo = undefined;
            while (true) {
                greedy.avail = w.at(lines);
                greedy.indent = if (lines == 0) ind_first else ind_rest;
                last = p.nextLine(pos, cum, greedy, no_stop);
                lines += 1;
                width_sum += last.width;
                pos = last.next;
                cum = last.cum;
                if (last.last or pos >= n) break;
                if (lines >= max_lines) return; // too long: try again at the next line (pretty)
            }
            it.suspended = true;
            if (lines <= 1) return;
            if (!balance) {
                // worth it only when the greedy last line is short and a single word
                if (!(last.width < w.def / 3.0)) return;
                var k = last.start + 1;
                while (k < last.end) : (k += 1) {
                    if (p.glyphs[k].flags & ShapedGlyph.BREAK_BEFORE != 0) return;
                }
            }
            // (cloned box decorations take scoring away)
            if (!p.has_clone and it.score(w, lines, balance, ind_first)) return;
            if (!balance or !may_bisect or pos < n or it.pos != 0) return;
            // bisection: the narrowest width (to 1 px) that keeps the number of lines
            var upper = w.def;
            var lower = floor64(width_sum / @as(f32, @floatFromInt(lines)) * 0.8 + 1.0 / 128.0);
            while (lower + 1.0 < upper) {
                const mid = floor64((upper + lower) * 0.5);
                var m2 = greedy;
                m2.avail = mid;
                var q: u32 = 0;
                var c2: f64 = 0;
                var cnt: u32 = 0;
                while (q < n and cnt <= lines) : (cnt += 1) {
                    m2.indent = if (cnt == 0) ind_first else ind_rest;
                    const li = p.nextLine(q, c2, m2, no_stop);
                    q = li.next;
                    c2 = li.cum;
                }
                if (cnt <= lines) upper = mid else lower = mid;
            }
            it.bal_w = upper;
        }

        /// Blink's `LineBreakCandidateContext` + `ComputeScores`. Candidates: every break
        /// opportunity of the part between two sentinels, with the position of the line end when
        /// the line breaks there (`pos_if`: without trailing spaces) and when it does not
        /// (`pos_no`). An inline box edge or an atomic inline starts on the layout-unit grid; an
        /// edge leaves the position-with-a-break where the content before it ended (Blink: "opaque
        /// items leave the position with a break, as trailing spaces do"), and an opportunity right
        /// after an edge / atomic inline is a candidate of that item.
        fn score(it: *LineIter, w: LineW, greedy_lines: u32, balance: bool, first_indent: f32) bool {
            const p = it.p;
            const gs = p.glyphs;
            const n: u32 = @intCast(gs.len);
            var glyph: [max_candidates]u32 = undefined;
            var pos_no: [max_candidates]f32 = undefined;
            var pos_if: [max_candidates]f32 = undefined;
            var pen: [max_candidates]f32 = undefined;
            const justified = p.opts.text_align == .justify;
            const wfs = @max(w.def, 0) * p.strut_size;
            const hyphen_penalty: f32 = if (justified) wfs / 2.0 else wfs * 2.0;
            const line_penalty: f32 = if (justified) 0 else hyphen_penalty * 2.0;
            var nc: usize = 1;
            glyph[0] = it.pos;
            pos_no[0] = 0;
            pos_if[0] = 0;
            pen[0] = 0;
            const s_cum = it.cum;
            var cum = s_cum;
            var cum_content = s_cum;
            var content_end = it.pos;
            var last_hyphen_run = true;
            // glyph whose break-before opportunity is already a candidate (made by the item before it)
            var done_at: u32 = no_stop;
            var i = it.pos;
            while (i < n) : (i += 1) {
                const g = gs[i];
                if (p.multi_run and i > it.pos and g.item != gs[i - 1].item) cum = s_cum + ceil64d(cum - s_cum);
                if (g.flags & ShapedGlyph.HARD_BREAK != 0) break;
                if (i > it.pos and i != done_at and g.flags & ShapedGlyph.BREAK_BEFORE != 0) {
                    if (nc + 1 >= max_candidates) return false;
                    var e = cum_content;
                    var hy = false;
                    if (content_end == i) {
                        e -= gs[i - 1].kern;
                        if (g.flags & ShapedGlyph.SOFT_HYPHEN != 0) {
                            hy = true;
                            e += p.metrics[gs[i - 1].metric].hyphen_adv;
                        }
                    }
                    glyph[nc] = i;
                    pos_no[nc] = @floatCast(cum - s_cum);
                    pos_if[nc] = @floatCast(e - s_cum);
                    pen[nc] = if (hy) hyphen_penalty else 0;
                    nc += 1;
                }
                if (g.flags & ShapedGlyph.SPECIAL != 0) {
                    // floats and out-of-flow boxes are transparent
                    if (g.gid >= Special.float) continue;
                    const end = s_cum + ceil64d(cum - s_cum) + p.advanceOf(g, @floatCast(cum - s_cum), it.mode.flow);
                    // a negative size breaks the candidates' monotonic positions
                    if (end < cum) return false;
                    cum = end;
                    if (g.gid == Special.atomic) {
                        cum_content = end;
                        content_end = i + 1;
                    }
                    var j = i + 1;
                    while (j < n and gs[j].flags & ShapedGlyph.SPECIAL != 0 and gs[j].gid >= Special.float) j += 1;
                    if (j < n and gs[j].flags & ShapedGlyph.BREAK_BEFORE != 0 and gs[j].flags & ShapedGlyph.HARD_BREAK == 0) {
                        if (nc + 1 >= max_candidates) return false;
                        glyph[nc] = j;
                        pos_no[nc] = @floatCast(end - s_cum);
                        pos_if[nc] = @floatCast(cum_content - s_cum);
                        pen[nc] = 0;
                        nc += 1;
                        done_at = j;
                    }
                    continue;
                }
                const nx = cum + p.advanceOf(g, @floatCast(cum - s_cum), null);
                cum = nx;
                if (g.flags & ShapedGlyph.SPACE != 0) continue;
                cum_content = nx;
                content_end = i + 1;
            }
            glyph[nc] = i;
            pos_no[nc] = @floatCast(cum_content - s_cum);
            pos_if[nc] = pos_no[nc];
            pen[nc] = 0;
            nc += 1;
            if (nc < 3 + 2) return false;
            // orphans cost more: the last opportunity (and hyphenated ones before it)
            {
                var k = nc - 1;
                while (k > 1 and last_hyphen_run) {
                    k -= 1;
                    last_hyphen_run = pen[k] != 0;
                    pen[k] += 10000.0;
                }
            }
            const overfull: f32 = 1e12;
            var sc: [max_candidates]f32 = undefined;
            var prev: [max_candidates]u8 = undefined;
            var line_ix: [max_candidates]u8 = undefined;
            sc[0] = 0;
            prev[0] = 0;
            line_ix[0] = 0;
            var active: usize = 0;
            var end: usize = 1;
            while (end < nc) : (end += 1) {
                const is_last = end == nc - 1;
                var best: f32 = std.math.floatMax(f32);
                var best_prev: usize = 0;
                // (the width of the line that would start at a candidate: by its line index, the
                // first one narrower by its text-indent)
                var last_line: u8 = line_ix[active];
                var fit = @max(w.at(last_line) - (if (last_line == 0) first_indent else 0), 0) + 1.0 / 64.0;
                var start_edge = pos_if[end] - fit;
                var best_hope: f32 = 0;
                var st: usize = active;
                while (st < end) : (st += 1) {
                    if (line_ix[st] != last_line) {
                        last_line = line_ix[st];
                        const nf = @max(w.at(last_line) - (if (last_line == 0) first_indent else 0), 0) + 1.0 / 64.0;
                        if (nf != fit) {
                            fit = nf;
                            start_edge = pos_if[end] - fit;
                            best_hope = 0;
                        }
                    }
                    if (sc[st] + best_hope >= best) continue;
                    const delta = pos_no[st] - start_edge;
                    var width_score: f32 = 0;
                    var extra: f32 = 0;
                    if (delta < 0) {
                        width_score = overfull;
                    } else if (is_last and !balance) {
                        extra = 4.0 * pen[st];
                    } else width_score = delta * delta;
                    if (delta < 0) active = st + 1 else best_hope = width_score;
                    const s = sc[st] + width_score + extra;
                    if (s <= best) {
                        best = s;
                        best_prev = st;
                    }
                }
                sc[end] = best + pen[end] + line_penalty;
                prev[end] = @intCast(best_prev);
                line_ix[end] = line_ix[best_prev] +| 1;
            }
            if (line_ix[nc - 1] != greedy_lines or greedy_lines > max_balance_lines) return false;
            var k = nc - 1;
            var li: usize = greedy_lines;
            while (k > 0 and li > 0) {
                li -= 1;
                it.forced[li] = glyph[k];
                k = prev[k];
            }
            if (k != 0 or li != 0) return false;
            it.n_forced = @intCast(greedy_lines);
            it.forced_i = 0;
            return true;
        }

        /// Flow layout: the line widths of the paragraph part at the current position, whose first
        /// line is at `y` with the free range `band` (its leading floats are placed), and whether a
        /// balanced paragraph may bisect. Null: the widths are not known without layout (Blink's
        /// `LineWidths::Set`): more than one exclusion, floats inside the text, atomic inlines,
        /// shifted boxes or fonts taller than the strut beside a float.
        noinline fn lineWidths(it: *const LineIter, band: Band, y: f32, may_bisect: *bool) ?LineW {
            const p = it.p;
            const flow = it.cx.?.flow;
            const narrowed = band.next_y == band.next_y;
            // (Blink: the paragraph has a float anywhere; the other conditions look at the part)
            var has_float = false;
            for (p.glyphs[0..it.pos]) |g| {
                if (g.flags & ShapedGlyph.SPECIAL != 0 and g.gid == Special.float) has_float = true;
            }
            var late_float = false;
            var uneven = false;
            var leading = it.pos == 0;
            // (a font taller than the strut makes its line taller)
            const strut_only = p.opts.line_height != .normal;
            var tall = false;
            var last_m: u16 = 0xffff;
            for (p.glyphs[it.pos..]) |g| {
                if (g.flags & ShapedGlyph.SPECIAL == 0) {
                    leading = false;
                    if (g.metric != last_m and g.metric < p.metrics.len) {
                        last_m = g.metric;
                        const mt = p.metrics[g.metric];
                        if (!strut_only and (mt.ascent > p.strut_ascent or mt.descent > p.strut_descent)) tall = true;
                        // (the strut of the inline box the text is in)
                        if (mt.run < p.run_box.len and p.run_box[mt.run] < p.boxes.len) {
                            const bi = p.boxes[p.run_box[mt.run]];
                            if (bi.ascent > p.strut_ascent or bi.descent > p.strut_descent) tall = true;
                        }
                    }
                    continue;
                }
                switch (g.gid) {
                    Special.float => {
                        has_float = true;
                        if (!leading) late_float = true;
                    },
                    Special.atomic => {
                        uneven = true;
                        leading = false;
                    },
                    Special.open => if (g.cluster < p.boxes.len and p.boxes[g.cluster].valign != .baseline) {
                        uneven = true;
                    },
                    else => {},
                }
            }
            const bw = floor64(@max(band.x1 - band.x0, 0));
            may_bisect.* = !narrowed and !has_float;
            if (!narrowed and !has_float) return .{ .def = bw };
            if (late_float or uneven or tall) return null;
            if (!narrowed) return .{ .def = bw };
            const bf = flow.band_fn orelse return null;
            const b2 = bf(flow, band.next_y, 0);
            if (b2.next_y == b2.next_y or !(b2.x1 >= b2.x0)) return null;
            const lh = p.strut_ascent + p.strut_descent;
            if (!(lh > 0) or !(band.next_y > y)) return null;
            const nl = @ceil((band.next_y - y) / lh);
            if (!(nl < 64)) return null;
            return .{ .def = floor64(b2.x1 - b2.x0), .ex = bw, .n_ex = @intFromFloat(nl) };
        }

        fn next(it: *LineIter) ?LineInfo {
            if (it.cx != null) return it.nextFlow();
            const p = it.p;
            const n: u32 = @intCast(p.glyphs.len);
            if (comptime item_origin_build) if (p.cut == n) return null;
            if (it.pos >= n) return null;
            if (it.mode.clamp) {
                if (p.opts.max_lines) |ml| if (it.index >= ml) return null;
            }
            var stop: u32 = no_stop;
            if (comptime item_origin_build) if (it.pos < p.cut and p.cut <= n) {
                stop = p.cut;
            };
            if ((comptime wrap_balance) and it.mode.strategy != .wrap and stop == no_stop) {
                if (it.forced_i >= it.n_forced and !it.suspended and (it.mode.strategy == .pretty or it.pos == 0)) {
                    it.prepare(.{ .def = floor64(@max(it.mode.avail.?, 0)) }, true);
                    if (it.bal_w == it.bal_w) it.mode.avail = it.bal_w;
                }
                if (it.forced_i < it.n_forced) {
                    stop = it.forced[it.forced_i];
                    it.forced_i += 1;
                    // the last forced point is the end of the part: break normally there
                    if (stop >= n) stop = no_stop;
                }
            }
            if (p.has_indent) it.mode.indent = it.indentFor(it.first_line);
            var li = p.nextLine(it.pos, it.cum, it.mode, stop);
            it.first_line = false;
            it.after_hard = li.hard;
            if (li.last) {
                // paragraph part ended: `pretty` looks at the next part afresh
                it.n_forced = 0;
                it.forced_i = 0;
                it.suspended = it.mode.strategy == .balance;
            }
            it.pos = li.next;
            it.cum = li.cum;
            it.index += 1;
            it.clampLine(&li, it.mode.avail);
            p.simpleBox(&li);
            return li;
        }

        /// One line of a paragraph laid out in a `Flow`: the line gets the inline range that is
        /// free beside the floats at its position (asked again when the line box turns out
        /// taller), moves below them when not even its first unbreakable unit fits, and floats
        /// occurring on it are placed beside it or below it.
        noinline fn nextFlow(it: *LineIter) ?LineInfo {
            const p = it.p;
            const cx = it.cx.?;
            const flow = cx.flow;
            const gs = p.glyphs;
            const n: u32 = @intCast(gs.len);
            if (comptime item_origin_build) if (p.cut == n) return null;
            if (it.pos >= n) return null;
            if (it.mode.clamp) {
                if (p.opts.max_lines) |ml| if (it.index >= ml) return null;
            }
            const full = it.mode.avail;
            var y = it.y;
            var hq: f32 = 0;
            var tries: u32 = 0;
            var li: LineInfo = undefined;
            var band: Band = undefined;
            var deferred: u32 = no_stop;
            var h: f32 = 0;
            // the float placed beside this line last, and a break position that is settled
            var beside: u32 = no_stop;
            var stop: u32 = no_stop;
            // text-wrap: balance / pretty: the break point chosen for this line
            const cut_here = if (comptime item_origin_build) it.pos < p.cut and p.cut <= n else false;
            if (comptime item_origin_build) if (cut_here) {
                stop = p.cut;
            };
            const scored = (comptime wrap_balance) and it.mode.strategy != .wrap and full != null and !cut_here;
            var prepared = !scored;
            if (scored and it.forced_i < it.n_forced) {
                stop = it.forced[it.forced_i];
                it.forced_i += 1;
                if (stop >= n) stop = no_stop;
                prepared = true;
            }
            while (true) {
                band = .{ .x0 = 0, .x1 = @max(full orelse 0, 0) };
                // (the text before a cut is one line no page shows: it keeps its place, not moved
                // below the floats it is too wide to sit beside, so the lines after it wrap where
                // they did on the page before)
                if (full != null and !cut_here) if (flow.band_fn) |bf| {
                    band = bf(flow, y, hq);
                    if (!std.math.isFinite(band.x0)) band.x0 = 0;
                    if (!(band.x1 >= band.x0) or !std.math.isFinite(band.x1)) band.x1 = band.x0;
                };
                var m = it.mode;
                if (full != null) m.avail = band.x1 - band.x0;
                if (m.avail) |a| {
                    if (it.bal_w < a) m.avail = it.bal_w;
                }
                if (p.has_indent) m.indent = it.indentFor(it.first_line);
                li = p.nextLine(it.pos, it.cum, m, stop);
                it.clampLine(&li, m.avail);
                deferred = no_stop;
                if (flow.float_fn) |ff| {
                    if (beside != no_stop) {
                        // The line shortened by a float ends before the inline box that float is in
                        // (Blink rewinds trailing open tags, and the floats after them): the float
                        // belongs to the next line, this one keeps its break.
                        var undo = false;
                        if (li.next <= beside) for (gs[li.next..beside]) |g| {
                            if (g.flags & ShapedGlyph.SPECIAL != 0 and g.gid == Special.open) undo = true;
                        };
                        const b = beside;
                        beside = no_stop;
                        if (undo) {
                            _ = ff(flow, gs[b].cluster, y, 0, 0, .undo);
                            it.float_next = @min(it.float_next, b);
                            stop = li.next;
                            continue;
                        }
                    }
                    var placed = false;
                    var k = @max(it.pos, it.float_next);
                    while (k < li.next) : (k += 1) {
                        const g = gs[k];
                        if (g.flags & ShapedGlyph.SPECIAL == 0 or g.gid != Special.float) continue;
                        const how: FloatPlace = if (p.leadingAt(it.pos, k)) .leading else .beside;
                        if (ff(flow, g.cluster, y, p.widthTo(it.pos, k, it.cum, flow) + m.indent, band.x1 - band.x0, how)) {
                            it.float_next = k + 1;
                            placed = true;
                            if (how == .beside and stop == no_stop) beside = k;
                        } else deferred = k;
                        break;
                    }
                    // (bounded: `float_next` grows with every float placed)
                    if (placed) continue;
                }
                if ((comptime wrap_balance) and !prepared) {
                    // the leading floats are placed: the widths of the lines are known now
                    prepared = true;
                    if (stop == no_stop and !it.suspended and (it.mode.strategy == .pretty or it.pos == 0)) {
                        var may_bisect = false;
                        // (unknown widths: `pretty` tries again at the next line)
                        if (it.lineWidths(band, y, &may_bisect)) |lw| it.prepare(lw, may_bisect);
                        if (it.forced_i < it.n_forced) {
                            stop = it.forced[it.forced_i];
                            it.forced_i += 1;
                            if (stop >= n) stop = no_stop else continue;
                        } else if (it.bal_w == it.bal_w) continue;
                    }
                }
                // a line without text, atomic inlines, inline edges or a forced break has no line box
                // (a line broken again starts its fragments again)
                if (cx.frags) |fr| fr.items.len = @min(cx.frag_start, fr.items.len);
                li.empty = !li.hard;
                if (li.empty) for (gs[li.start..li.end]) |g| {
                    if (g.flags & ShapedGlyph.SPECIAL == 0 or g.gid == Special.atomic or g.x_advance != 0) {
                        li.empty = false;
                        break;
                    }
                };
                if (li.empty) {
                    li.ascent = 0;
                    li.descent = 0;
                } else p.lineBox(&li, cx);
                h = li.ascent + li.descent;
                if (full != null and tries < 16) if (flow.band_fn) |bf| {
                    if (h > hq) {
                        const b2 = bf(flow, y, h);
                        if (b2.x0 != band.x0 or b2.x1 != band.x1) {
                            hq = h;
                            tries += 1;
                            continue;
                        }
                    }
                    // (a line that does not fit moves below the floats, unless the block does not wrap)
                    if (band.next_y > y and wsWraps(p.opts.white_space) and ceil64(li.ink_w) > floor64(band.x1 - band.x0) + 1.0 / 128.0) {
                        y = band.next_y;
                        hq = 0;
                        tries += 1;
                        continue;
                    }
                };
                break;
            }
            if (flow.float_fn) |ff| {
                if (deferred != no_stop) {
                    var k = deferred;
                    while (k < li.next) : (k += 1) {
                        const g = gs[k];
                        if (g.flags & ShapedGlyph.SPECIAL != 0 and g.gid == Special.float) _ = ff(flow, g.cluster, y + h, 0, 0, .below);
                    }
                }
                it.float_next = @max(it.float_next, li.next);
            }
            if (!li.empty) {
                it.first_line = false;
                it.after_hard = li.hard;
            }
            if (li.last) {
                // paragraph part ended: `pretty` looks at the next part afresh
                it.n_forced = 0;
                it.forced_i = 0;
                it.suspended = it.mode.strategy == .balance;
            }
            li.top = y;
            li.band_x = band.x0;
            li.band_w = band.x1 - band.x0;
            it.y = y + h;
            it.pos = li.next;
            it.cum = li.cum;
            it.index += 1;
            return li;
        }

        /// The line's content is all left-to-right glyphs (even bidi levels), without tabs.
        fn keepEnd(gs: []const ShapedGlyph) bool {
            if (gs.len == 0) return false;
            for (gs) |g| {
                if (g.level & 1 != 0 or g.flags & (ShapedGlyph.TAB | ShapedGlyph.SPECIAL) != 0) return false;
            }
            return true;
        }

        /// text-overflow / line-clamp: truncates `li` (line number `it.index + 1`) so that its
        /// content and the ellipsis fit `avail_w`.
        fn clampLine(it: *const LineIter, li: *LineInfo, avail_w: ?f32) void {
            const p = it.p;
            const n: u32 = @intCast(p.glyphs.len);
            const index = if (it.cx != null) it.index + 1 else it.index;
            if (it.mode.clamp and p.ell.on) {
                var clamped = if (p.opts.max_lines) |ml| index >= ml and li.next < n else false;
                // block-ellipsis: none — the clamp line gets no marker
                if (clamped and !p.clamp_ell.on) clamped = false;
                const ell_w = if (clamped) p.clamp_ell.w else p.ell.w;
                li.ell_clamp = clamped;
                if (avail_w) |a| {
                    const avail = floor64(@max(a, 0));
                    if ((p.opts.ellipsis and ceil64(li.width) > avail) or (clamped and ceil64(li.width + ell_w) > avail)) {
                        // truncate so that content + ellipsis fits
                        if (p.rtl and !p.complex and keepEnd(p.glyphs[li.start..li.end])) {
                            // left-to-right text in a right-to-left line keeps its end (Blink
                            // TruncateText: the line and the run directions differ)
                            // (the widths include the line's text-indent, as below)
                            var w: f32 = li.indent;
                            var k = li.end;
                            while (k > li.start) : (k -= 1) {
                                const nw = w + p.glyphs[k - 1].x_advance;
                                if (ceil64(nw + ell_w) > avail) break;
                                w = nw;
                            }
                            while (k < li.end and p.glyphs[k].flags & ShapedGlyph.NO_SPLIT != 0) : (k += 1) w -= p.glyphs[k].x_advance;
                            li.start = k;
                            li.width = w + ell_w;
                            li.content_w = li.width;
                            li.ellipsis = true;
                            li.ell_clamp = clamped;
                            return;
                        }
                        var w: f32 = li.indent;
                        var k = li.start;
                        while (k < li.end) : (k += 1) {
                            const nw = w + p.advanceOf(p.glyphs[k], w, it.mode.flow);
                            if (ceil64(nw + ell_w) > avail) break;
                            w = nw;
                        }
                        // keep clusters (marks, reordered syllable parts) whole
                        while (k > li.start and k < li.end and p.glyphs[k].flags & ShapedGlyph.NO_SPLIT != 0) {
                            k -= 1;
                            w -= p.glyphs[k].x_advance;
                        }
                        li.end = k;
                        li.width = w + ell_w;
                        li.content_w = li.width;
                        li.ellipsis = true;
                        li.hyphen = false;
                    } else if (clamped) {
                        li.width += ell_w;
                        li.content_w = li.width;
                        li.ellipsis = true;
                    }
                } else if (clamped) {
                    li.width += ell_w;
                    li.content_w = li.width;
                    li.ellipsis = true;
                }
            }
        }
    };

    /// Line box of a line without inline boxes: the strut united with every (run, face) on it.
    inline fn simpleBox(p: *const Paragraph, li: *LineInfo) void {
        var a = p.strut_ascent;
        var d = p.strut_descent;
        if (p.opts.line_height != .normal) {
            // explicit line-height: the strut alone decides (takumi/Blink text items)
        } else if (p.metrics.len == 1) {
            a = @max(a, p.metrics[0].ascent);
            d = @max(d, p.metrics[0].descent);
        } else {
            var last_m: u16 = 0xffff;
            for (p.glyphs[li.start..li.end]) |g| {
                if (g.metric == last_m or g.flags & ShapedGlyph.SPECIAL != 0) continue;
                last_m = g.metric;
                a = @max(a, p.metrics[g.metric].ascent);
                d = @max(d, p.metrics[g.metric].descent);
            }
        }
        li.ascent = a;
        li.descent = d;
    }

    /// Advance from glyph `start` (cumulative position `s_cum`) up to glyph `k`.
    fn widthTo(self: *const Paragraph, start: u32, k: u32, s_cum: f64, flow: ?*const Flow) f32 {
        const gs = self.glyphs;
        var cum = s_cum;
        var i = start;
        while (i < k) : (i += 1) {
            const g = gs[i];
            if (self.multi_run and i > start and g.item != gs[i - 1].item) cum = s_cum + ceil64d(cum - s_cum);
            cum += self.advanceOf(g, @floatCast(cum - s_cum), flow);
        }
        return @floatCast(cum - s_cum);
    }

    /// Nothing but floats, out-of-flow boxes and opening edges in glyphs [start, k).
    fn leadingAt(self: *const Paragraph, start: u32, k: u32) bool {
        for (self.glyphs[start..k]) |g| {
            if (g.flags & ShapedGlyph.SPECIAL == 0 or g.gid == Special.close or g.gid == Special.atomic) return false;
        }
        return true;
    }

    // ---- inline box state machine (complex paragraphs), after Blink's InlineBoxState

    const no_state: u32 = 0xffff_ffff;

    const BoxState = struct {
        /// index into `boxes` (`no_state` for an atomic inline)
        box: u32,
        /// first shift slot of the box's content
        start: u32,
        /// everything in the box, relative to the box's own baseline
        asc: f32,
        desc: f32,
        valign: VerticalAlign,
    };

    const Pending = struct { owner: u32, start: u32, end: u32, asc: f32, desc: f32, valign: VerticalAlign };

    /// Scratch of one `measureFlow` / `layoutFlow` call.
    const Cx = struct {
        flow: *const Flow,
        alloc: std.mem.Allocator,
        stack: std.ArrayList(BoxState) = .empty,
        pending: std.ArrayList(Pending) = .empty,
        tmp: std.ArrayList(u32) = .empty,
        /// layout only: vertical shift per slot of the current line (one per box continued
        /// from the previous line, then one per glyph of the line)
        dy: std.ArrayList(f32) = .empty,
        want_dy: bool = false,
        n_cont: u32 = 0,
        /// layout only: the fragments of the boxes on the lines so far
        frags: ?*std.ArrayList(BoxFragment) = null,
        frag_alloc: std.mem.Allocator = undefined,
        /// index of the line being built and of its first fragment
        line: u32 = 0,
        frag_start: usize = 0,
        oom: bool = false,
        /// layout only: the visual box fragments of the current line (`visualRanges`)
        vr: std.ArrayList(VRange) = .empty,

        fn deinit(cx: *Cx) void {
            cx.vr.deinit(cx.alloc);
            cx.dy.deinit(cx.alloc);
            cx.tmp.deinit(cx.alloc);
            cx.pending.deinit(cx.alloc);
            cx.stack.deinit(cx.alloc);
        }

        fn push(cx: *Cx, st: BoxState) void {
            cx.stack.append(cx.alloc, st) catch {
                cx.oom = true;
            };
        }

        fn move(cx: *Cx, start: u32, end: u32, shift: f32) void {
            if (!cx.want_dy or shift == 0) return;
            const d = cx.dy.items;
            const e = @min(end, d.len);
            if (start < e) for (d[start..e]) |*v| {
                v.* += shift;
            };
        }
    };

    inline fn trunc64(v: f32) f32 {
        return @trunc(v * 64.0) * (1.0 / 64.0);
    }

    /// A box fragment in visual order: `frag` (index into the fragment list) covers the visual items
    /// [a, b] of the line; `left` / `right` = the edge (margin + border + padding) placed before `a` /
    /// after `b`, `left_m` / `right_m` its margin part.
    const VRange = struct { frag: u32, box: u32, a: u32, b: u32, left: f32 = 0, left_m: f32 = 0, right: f32 = 0, right_m: f32 = 0 };

    fn endsAt(cx: *const Cx, v: u32) bool {
        for (cx.vr.items) |r| {
            if (r.b == v) return true;
        }
        return false;
    }

    /// Places the line-right edges of the fragments ending at visual item `v` (inner boxes first).
    fn edgesAfter(cx: *const Cx, frags: []BoxFragment, v: u32, x_in: f32) f32 {
        var x = x_in;
        var k = cx.vr.items.len;
        while (k > 0) {
            k -= 1;
            const r = cx.vr.items[k];
            if (r.b != v) continue;
            x += r.right;
            if (r.frag < frags.len) frags[r.frag].x1 = x - r.right_m;
        }
        return x;
    }

    /// Is visual item `v` of line `li` content of inline box `box` (a glyph that is laid out, an atomic
    /// inline; with `edges`: an edge marker of the box itself, for a box without content on the line)?
    fn inBox(self: *const Paragraph, li: *const LineInfo, order: ?[]const u32, v: u32, tail: u32, box: u32, edges: bool) bool {
        const gi = li.start + (if (order) |o| o[v] else v);
        const g = self.glyphs[gi];
        var b: u32 = 0;
        if (g.flags & ShapedGlyph.SPECIAL != 0) {
            if (g.gid <= Special.close) return edges and g.cluster == box;
            if (edges or g.gid != Special.atomic or g.metric >= self.objs.len) return false;
            b = self.objs[g.metric].box;
        } else {
            if (edges or gi >= tail or g.flags & ShapedGlyph.HARD_BREAK != 0 or g.metric >= self.metrics.len) return false;
            const r = self.metrics[g.metric].run;
            if (r < self.run_box.len) b = self.run_box[r];
        }
        while (b != 0 and b < self.boxes.len) : (b = self.boxes[b].parent) {
            if (b == box) return true;
        }
        return false;
    }

    /// Blink's box fragments of a line whose items are in visual order (`order`, null = logical): the
    /// content of a box that is not contiguous after bidi reordering makes one fragment per run of
    /// items; the box's line-left edge goes to its leftmost fragment, the line-right edge to the
    /// rightmost (`InlineLayoutStateStack::UpdateAfterReorder`), where line-left is the start edge of
    /// an ltr box and the end edge of an rtl one. Fills `cx.vr` (sorted by box: outer boxes first) and
    /// adds the extra fragments to `frags`. Returns false when the line is left to the logical path.
    noinline fn visualRanges(self: *const Paragraph, cx: *Cx, frags: *std.ArrayList(BoxFragment), alloc: std.mem.Allocator, frag_start: usize, li: *const LineInfo, order: ?[]const u32, tail: u32) !bool {
        cx.vr.clearRetainingCapacity();
        const count = li.end - li.start;
        const n_fr = frags.items.len - frag_start;
        // (bounded work on hostile input: boxes x items x nesting)
        if (n_fr == 0 or n_fr > 4096 or @as(u64, n_fr) * count > (1 << 18)) return false;
        var fi: usize = 0;
        while (fi < n_fr) : (fi += 1) {
            const f0 = frags.items[frag_start + fi];
            const box = f0.box + 1;
            if (box >= self.boxes.len) continue;
            const bi = self.boxes[box];
            const first_r = cx.vr.items.len;
            var pass: u8 = 0;
            while (pass < 2 and cx.vr.items.len == first_r) : (pass += 1) {
                var v: u32 = 0;
                while (v < count) {
                    if (!self.inBox(li, order, v, tail, box, pass == 1)) {
                        v += 1;
                        continue;
                    }
                    const a = v;
                    while (v < count and self.inBox(li, order, v, tail, box, pass == 1)) v += 1;
                    var fidx = frag_start + fi;
                    if (cx.vr.items.len != first_r) {
                        fidx = frags.items.len;
                        try frags.append(alloc, f0);
                    }
                    try cx.vr.append(cx.alloc, .{ .frag = @intCast(fidx), .box = box, .a = a, .b = v - 1 });
                }
            }
            const rs = cx.vr.items[first_r..];
            if (rs.len == 0) continue;
            const l_has = if (bi.rtl) f0.last else f0.first;
            const r_has = if (bi.rtl) f0.first else f0.last;
            if (l_has) {
                rs[0].left = if (bi.rtl) bi.end else bi.start;
                rs[0].left_m = if (bi.rtl) bi.margin_end else bi.margin_start;
            }
            if (r_has) {
                rs[rs.len - 1].right = if (bi.rtl) bi.start else bi.end;
                rs[rs.len - 1].right_m = if (bi.rtl) bi.margin_start else bi.margin_end;
            }
            for (rs, 0..) |r, k| {
                const hl = l_has and k == 0;
                const hr = r_has and k == rs.len - 1;
                const f = &frags.items[r.frag];
                f.rtl = bi.rtl;
                f.first = if (bi.rtl) hr else hl;
                f.last = if (bi.rtl) hl else hr;
                f.x0 = std.math.inf(f32);
                f.x1 = -std.math.inf(f32);
            }
        }
        return cx.vr.items.len != 0;
    }

    /// Aligns the pending descendants of stack entry `idx` (`text-top` / `text-bottom` against
    /// its font, then `top` / `bottom` against its extent, which they may grow).
    fn resolvePending(self: *const Paragraph, cx: *Cx, idx: u32) void {
        const st = &cx.stack.items[idx];
        const bi = self.boxes[st.box];
        var any_tb = false;
        for (cx.pending.items) |*c| {
            if (c.owner != idx) continue;
            var shift: f32 = 0;
            switch (c.valign) {
                .text_top => shift = c.asc - bi.text_ascent,
                .text_bottom => shift = trunc64(bi.font_descent) - c.desc,
                else => {
                    any_tb = true;
                    continue;
                },
            }
            st.asc = @max(st.asc, c.asc - shift);
            st.desc = @max(st.desc, c.desc + shift);
            cx.move(c.start, c.end, shift);
        }
        if (any_tb) {
            // a taller box aligned `top` / `bottom` keeps one edge and extends the other
            const ma = st.asc;
            const md = st.desc;
            var xa = ma;
            var xd = md;
            for (cx.pending.items) |c| {
                if (c.owner != idx or (c.valign != .top and c.valign != .bottom)) continue;
                const lh = c.asc + c.desc;
                if (lh > xa + xd) {
                    if (c.valign == .top) {
                        xa = ma;
                        xd = lh - ma;
                    } else {
                        xa = lh - md;
                        xd = md;
                    }
                }
            }
            for (cx.pending.items) |c| {
                if (c.owner != idx or (c.valign != .top and c.valign != .bottom)) continue;
                const shift = if (c.valign == .top) c.asc - xa else xd - c.desc;
                st.asc = @max(st.asc, c.asc - shift);
                st.desc = @max(st.desc, c.desc + shift);
                cx.move(c.start, c.end, shift);
            }
        }
        // drop the resolved entries
        var w: usize = 0;
        for (cx.pending.items) |c| {
            if (c.owner == idx) continue;
            cx.pending.items[w] = c;
            w += 1;
        }
        cx.pending.items.len = w;
    }

    /// Ends the innermost open box (or atomic inline) at shift slot `end`: applies its
    /// `vertical-align` and unites it into its parent, or leaves it pending.
    fn endBox(self: *const Paragraph, cx: *Cx, end: u32) void {
        const idx: u32 = @intCast(cx.stack.items.len - 1);
        if (cx.stack.items[idx].box != no_state) self.resolvePending(cx, idx);
        if (idx == 0) return;
        const st = cx.stack.items[idx];
        cx.stack.items.len = idx;
        const parent = &cx.stack.items[idx - 1];
        const pbi = self.boxes[parent.box];
        var shift: f32 = 0;
        switch (st.valign) {
            .baseline => {},
            .sub => shift = @trunc(@round(pbi.font_size * 64.0) / 5.0) / 64.0 + 1.0,
            .super => shift = -(@trunc(@round(pbi.font_size * 64.0) / 3.0) / 64.0 + 1.0),
            .length => |v| shift = -trunc64(v),
            .middle => shift = @trunc((st.asc - st.desc) * 64.0 / 2.0) / 64.0 - @round(pbi.x_height * 0.5 * 64.0) / 64.0,
            .top, .bottom, .text_top, .text_bottom => {
                var owner = idx - 1;
                if (st.valign == .top or st.valign == .bottom) {
                    while (owner > 0) : (owner -= 1) {
                        const ov = cx.stack.items[owner].valign;
                        if (ov == .top or ov == .bottom) break;
                    }
                }
                cx.pending.append(cx.alloc, .{ .owner = owner, .start = st.start, .end = end, .asc = st.asc, .desc = st.desc, .valign = st.valign }) catch {
                    cx.oom = true;
                };
                return;
            },
        }
        cx.move(st.start, end, shift);
        parent.asc = @max(parent.asc, st.asc - shift);
        parent.desc = @max(parent.desc, st.desc + shift);
    }

    /// Innermost inline box that is open just before glyph `i`.
    fn boxBefore(self: *const Paragraph, i: u32) u32 {
        const g = self.glyphs[i];
        if (g.flags & ShapedGlyph.SPECIAL != 0) {
            const b: u32 = switch (g.gid) {
                Special.open => if (g.cluster < self.boxes.len) self.boxes[g.cluster].parent else 0,
                Special.close => g.cluster,
                else => if (g.metric < self.objs.len) self.objs[g.metric].box else 0,
            };
            return if (b < self.boxes.len) b else 0;
        }
        if (g.metric >= self.metrics.len) return 0;
        const r = self.metrics[g.metric].run;
        return if (r < self.run_box.len) self.run_box[r] else 0;
    }

    /// The fragment of `box` on the current line ends with the box's end edge.
    fn markLast(cx: *Cx, box: u32) void {
        const fr = cx.frags orelse return;
        var k = fr.items.len;
        while (k > 0) {
            k -= 1;
            if (fr.items[k].line != cx.line) break;
            if (fr.items[k].box == box - 1) {
                fr.items[k].last = true;
                break;
            }
        }
    }

    fn openState(self: *const Paragraph, cx: *Cx, box: u32, slot: u32, first_in: bool) void {
        const bi = self.boxes[box];
        const first = (first_in and !bi.no_start) or bi.clone;
        cx.push(.{ .box = box, .start = slot, .asc = bi.ascent, .desc = bi.descent, .valign = bi.valign });
        if (cx.frags) |fr| {
            fr.append(cx.frag_alloc, .{ .box = box - 1, .line = cx.line, .x0 = std.math.inf(f32), .x1 = -std.math.inf(f32), .baseline = 0, .first = first, .face = bi.face, .slot = slot }) catch {
                cx.oom = true;
            };
        }
    }

    /// Line box of `li`: every inline box with a fragment on the line contributes its strut,
    /// text under `line-height: normal` the fonts it used, atomic inlines their margin box, each
    /// aligned by its `vertical-align`. With `cx.want_dy` the vertical shifts are left in `cx.dy`.
    noinline fn lineBox(self: *const Paragraph, li: *LineInfo, cx: *Cx) void {
        if (!self.complex or self.boxes.len == 0) return self.simpleBox(li);
        const gs = self.glyphs;
        cx.stack.clearRetainingCapacity();
        cx.pending.clearRetainingCapacity();
        cx.tmp.clearRetainingCapacity();
        cx.push(.{ .box = 0, .start = 0, .asc = self.boxes[0].ascent, .desc = self.boxes[0].descent, .valign = .baseline });
        if (cx.stack.items.len == 0) return self.simpleBox(li);
        // boxes continued from the previous line, outer first
        if (li.start < gs.len) {
            var b = self.boxBefore(li.start);
            while (b != 0) : (b = self.boxes[b].parent) cx.tmp.append(cx.alloc, b) catch {
                cx.oom = true;
            };
        }
        const n_cont: u32 = @intCast(cx.tmp.items.len);
        const count = li.end - li.start;
        cx.n_cont = n_cont;
        if (cx.want_dy) {
            cx.dy.resize(cx.alloc, n_cont + count) catch {
                cx.oom = true;
                cx.dy.items.len = 0;
            };
            @memset(cx.dy.items, 0);
        }
        {
            var k = n_cont;
            while (k > 0) {
                k -= 1;
                self.openState(cx, cx.tmp.items[k], n_cont - 1 - k, false);
            }
        }
        var last_m: u32 = 0xffff_ffff;
        for (gs[li.start..li.end], 0..) |g, off| {
            const slot: u32 = n_cont + @as(u32, @intCast(off));
            const top = &cx.stack.items[cx.stack.items.len - 1];
            if (g.flags & ShapedGlyph.SPECIAL == 0) {
                // the fonts used by the text grow a box whose line-height is normal
                if (g.metric != last_m and self.boxes[top.box].normal_lh and g.metric < self.metrics.len) {
                    last_m = g.metric;
                    top.asc = @max(top.asc, self.metrics[g.metric].ascent);
                    top.desc = @max(top.desc, self.metrics[g.metric].descent);
                }
                continue;
            }
            last_m = 0xffff_ffff;
            switch (g.gid) {
                Special.open => if (g.cluster < self.boxes.len and g.cluster != 0) self.openState(cx, g.cluster, slot, true),
                Special.close => if (cx.stack.items.len > 1 and top.box == g.cluster) {
                    if (g.cluster < self.boxes.len and !self.boxes[g.cluster].no_end) markLast(cx, g.cluster);
                    self.endBox(cx, slot + 1);
                },
                Special.atomic => {
                    var om: ObjectMetrics = .{};
                    if (g.cluster < cx.flow.objects.len) om = cx.flow.objects[g.cluster];
                    if (!std.math.isFinite(om.ascent) or !std.math.isFinite(om.descent)) om = .{};
                    const before = cx.stack.items.len;
                    cx.push(.{ .box = no_state, .start = slot, .asc = om.ascent, .desc = om.descent, .valign = if (g.metric < self.objs.len) self.objs[g.metric].valign else .baseline });
                    if (cx.stack.items.len > before) self.endBox(cx, slot + 1);
                },
                else => {},
            }
        }
        const end = n_cont + count;
        while (cx.stack.items.len > 1) {
            const tb = cx.stack.items[cx.stack.items.len - 1].box;
            if (self.has_clone and tb < self.boxes.len and self.boxes[tb].clone) markLast(cx, tb);
            self.endBox(cx, end);
        }
        self.resolvePending(cx, 0);
        li.ascent = cx.stack.items[0].asc;
        li.descent = cx.stack.items[0].desc;
    }

    fn modeFor(self: *const Paragraph, max_width: ?f32) Mode {
        const avail = max_width orelse self.opts.max_width;
        return .{
            .avail = avail,
            .emergency = true,
            .strategy = if (avail != null and self.opts.max_lines == null and self.wraps()) self.opts.text_wrap else .wrap,
        };
    }

    /// Size of the paragraph wrapped at `max_width` (null = `opts.max_width`, which may itself
    /// be null = no wrapping). Allocation-free for plain paragraphs; safe to call repeatedly from
    /// a measure callback. (A `complex` paragraph is measured in an empty `Flow`: objects are
    /// zero-sized; use `measureFlow` to give them sizes.)
    pub fn measure(self: *const Paragraph, max_width: ?f32) Size {
        if (self.complex) return self.measureFlow(&.{ .alloc = self.alloc }, max_width);
        return self.measureMode(self.modeFor(max_width));
    }

    /// Continuation prefix compression must not enlarge a table/flex item's intrinsic size.
    pub noinline fn measureIntrinsic(self: *const Paragraph, max_width: ?f32) Size {
        if (comptime item_origin_build) {
            var uncut = self.*;
            uncut.cut = no_stop;
            return uncut.measure(max_width);
        }
        return self.measure(max_width);
    }

    fn measureMode(self: *const Paragraph, m: Mode) Size {
        var it: LineIter = .{ .p = self, .mode = m };
        var s: Size = .{ .width = 0, .height = 0 };
        while (it.next()) |li| {
            s.exact_width = @max(s.exact_width, li.width);
            s.last_baseline = s.height + li.ascent;
            if (s.line_count == 0) s.first_baseline = li.ascent;
            s.height += li.ascent + li.descent;
            s.line_count += 1;
        }
        s.width = ceil64(s.exact_width);
        return s;
    }

    /// `measure` in a `Flow`: atomic objects have the sizes of `flow.objects`, every line gets
    /// the inline range `flow.band_fn` reports for its position (when `max_width` is definite)
    /// and floats in the paragraph are handed to `flow.float_fn`. `Size.width` is the widest
    /// line (not its right edge), `Size.height` the bottom of the last line.
    pub fn measureFlow(self: *const Paragraph, flow: *const Flow, max_width: ?f32) Size {
        var cx: Cx = .{ .flow = flow, .alloc = flow.alloc };
        defer cx.deinit();
        var m = self.modeFor(max_width);
        m.flow = flow;
        var it: LineIter = .{ .p = self, .mode = m, .cx = &cx };
        var s: Size = .{ .width = 0, .height = 0 };
        while (it.next()) |li| {
            if (li.empty) continue;
            s.exact_width = @max(s.exact_width, li.width);
            s.last_baseline = li.top + li.ascent;
            if (s.line_count == 0) s.first_baseline = s.last_baseline;
            s.line_count += 1;
        }
        s.height = it.y;
        s.width = ceil64(s.exact_width);
        return s;
    }

    /// Widest line when breaking only at forced breaks (1/64-ceiled).
    pub fn maxContentWidth(self: *const Paragraph) f32 {
        return self.maxContentWidthFlow(null);
    }

    /// Widest unbreakable piece (1/64-ceiled): the width when every soft wrap opportunity is
    /// taken (`overflow-wrap: anywhere` also splits words; `break-word` does not, as in CSS).
    pub fn minContentWidth(self: *const Paragraph) f32 {
        return self.minContentWidthFlow(null);
    }

    /// `maxContentWidth` / `minContentWidth` with the atomic objects sized by `flow.objects`
    /// (floats and bands do not take part in intrinsic sizes).
    pub fn maxContentWidthFlow(self: *const Paragraph, flow: ?*const Flow) f32 {
        if (comptime item_origin_build) if (self.cut != no_stop) {
            var uncut = self.*;
            uncut.cut = no_stop;
            return uncut.maxContentWidthFlow(flow);
        };
        return self.measureMode(.{ .avail = null, .clamp = false, .emergency = false, .flow = flow }).width;
    }
    pub fn minContentWidthFlow(self: *const Paragraph, flow: ?*const Flow) f32 {
        if (comptime item_origin_build) if (self.cut != no_stop) {
            var uncut = self.*;
            uncut.cut = no_stop;
            return uncut.minContentWidthFlow(flow);
        };
        const m: Mode = .{ .avail = 0, .clamp = false, .emergency = true, .min_content = true, .flow = flow };
        if (!self.complex) return self.measureMode(m).width;
        // Blink's fast min-content path makes one item of a text run, as wide as its widest word,
        // and the closing edges after a run that ends in a space trail on that item's "line":
        // they add to the widest word of the run, not to its last one (oracle-verified quirk).
        const gs = self.glyphs;
        var it: LineIter = .{ .p = self, .mode = m };
        var best: f32 = 0;
        var run_max: f32 = 0;
        var cur_run: u32 = no_stop;
        while (it.next()) |li| {
            best = @max(best, li.width);
            var trail: f32 = 0;
            var k = li.end;
            while (k > li.start and gs[k - 1].flags & ShapedGlyph.SPECIAL != 0 and gs[k - 1].gid == Special.close) : (k -= 1) trail += gs[k - 1].x_advance;
            var plain = true;
            var run: u32 = no_stop;
            for (gs[li.start..k]) |g| {
                if (g.flags & ShapedGlyph.SPECIAL != 0) {
                    if (g.gid == Special.atomic or g.x_advance != 0) plain = false;
                } else if (run == no_stop and g.metric < self.metrics.len) run = self.metrics[g.metric].run;
            }
            if (!plain or run == no_stop or li.hard) {
                run_max = 0;
                cur_run = no_stop;
                continue;
            }
            if (run != cur_run) run_max = 0;
            cur_run = run;
            run_max = @max(run_max, li.width - trail);
            if (k < li.end) {
                if (k > li.start and gs[k - 1].flags & ShapedGlyph.SPACE != 0) best = @max(best, run_max + trail);
                run_max = 0;
                cur_run = no_stop;
            }
        }
        return ceil64(best);
    }

    /// Full layout at `max_width` (null = `opts.max_width`; alignment then uses the widest
    /// line as the container width when both are null). The result is allocated with `alloc`
    /// (typically the per-render arena) and freed with `TextLayout.deinit`. Glyph x positions
    /// are visual (left to right on screen) whatever the direction of their run.
    pub fn layout(self: *const Paragraph, alloc: std.mem.Allocator, max_width: ?f32) !TextLayout {
        if (self.complex) return self.layoutFlow(alloc, &.{ .alloc = alloc }, max_width);
        return self.layoutImpl(alloc, self.modeFor(max_width), null);
    }

    /// `layout` in a `Flow` (see `measureFlow`): lines are aligned inside their own free range,
    /// `TextLayout.objects` reports the atomic objects and out-of-flow static positions.
    /// `TextLayout.height` is the bottom of the last line.
    pub fn layoutFlow(self: *const Paragraph, alloc: std.mem.Allocator, flow: *const Flow, max_width: ?f32) !TextLayout {
        var cx: Cx = .{ .flow = flow, .alloc = flow.alloc, .want_dy = self.complex };
        defer cx.deinit();
        var m = self.modeFor(max_width);
        m.flow = flow;
        return self.layoutImpl(alloc, m, &cx);
    }

    fn touchBox(frags: []BoxFragment, box: u32, x0: f32, x1: f32) void {
        var k = frags.len;
        while (k > 0) {
            k -= 1;
            if (frags[k].box == box - 1) {
                frags[k].x0 = @min(frags[k].x0, x0);
                frags[k].x1 = @max(frags[k].x1, x1);
                return;
            }
        }
    }

    /// Extends the fragments (of the current line) of `box` and its ancestors over [x0, x1].
    noinline fn touchChain(self: *const Paragraph, frags: []BoxFragment, box_in: u32, xa: f32, xb: f32) void {
        var b = box_in;
        while (b != 0 and b < self.boxes.len) : (b = self.boxes[b].parent) touchBox(frags, b, @min(xa, xb), @max(xa, xb));
    }

    /// Sum of the `position: relative` offsets of inline box `box_in` and its ancestors.
    noinline fn relOf(self: *const Paragraph, box_in: u32) [2]f32 {
        var r: [2]f32 = .{ 0, 0 };
        var b = box_in;
        while (b != 0 and b < self.boxes.len) : (b = self.boxes[b].parent) {
            r[0] += self.boxes[b].rel[0];
            r[1] += self.boxes[b].rel[1];
        }
        return r;
    }

    /// Relative positioning (after layout, it moves no line): the glyphs, segments, fragments and
    /// atomic inlines of the boxes with an offset.
    noinline fn applyRel(self: *const Paragraph, acc: *LayoutAcc, rel_objs: []const [2]f32) void {
        for (acc.segs.items) |*s| {
            const r = self.relOf(s.box);
            if (r[0] == 0 and r[1] == 0) continue;
            s.x0 += r[0];
            s.x1 += r[0];
            s.baseline += r[1];
            const gl = acc.out.items;
            for (gl[@min(s.g0, gl.len)..@min(s.g1, gl.len)]) |*g| {
                g.x += r[0];
                g.y += r[1];
            }
        }
        for (acc.frags.items) |*f| {
            const r = self.relOf(f.box +% 1);
            f.x0 += r[0];
            f.x1 += r[0];
            f.baseline += r[1];
        }
        for (acc.objects.items, 0..) |*o, k| {
            if (k >= rel_objs.len) break;
            o.x += rel_objs[k][0];
            o.y += rel_objs[k][1];
        }
    }

    noinline fn pushObj(list: *std.ArrayList(ObjectPos), alloc: std.mem.Allocator, id: u32, x: f32, y: f32, line: usize) !void {
        try list.append(alloc, .{ .id = id, .x = x, .y = y, .line = @intCast(line) });
    }

    /// Ends a run segment `glyphs[g0..g1]` spanning [x0, x1]: records it and grows the fragments of
    /// the boxes around run `run`.
    noinline fn pushSeg(self: *const Paragraph, list: *std.ArrayList(Segment), alloc: std.mem.Allocator, frags: []BoxFragment, run: u32, g0: usize, g1: usize, x0: f32, x1: f32, baseline: f32, line: usize) !void {
        if (g1 <= g0) return;
        try list.append(alloc, .{ .g0 = @intCast(g0), .g1 = @intCast(g1), .x0 = x0, .x1 = x1, .baseline = baseline, .line = @intCast(line), .box = if (run < self.run_box.len) self.run_box[run] else 0 });
        if (run < self.run_box.len) self.touchChain(frags, self.run_box[run], x0, x1);
    }

    /// `cx_` = null: plain layout (lines counted first, contiguous line boxes); else a flow layout.
    noinline fn layoutImpl(self: *const Paragraph, alloc: std.mem.Allocator, m: Mode, cx_: ?*Cx) !TextLayout {
        const flow = cx_ != null;
        const size: Size = if (flow) .{ .width = 0, .height = 0 } else self.measureMode(m);
        // scratch for visual reordering (allocated first: the outputs can then grow in place
        // in a bump arena)
        const scratch_n = if (self.has_bidi) self.glyphs.len else 0;
        const order = try alloc.alloc(u32, scratch_n);
        defer alloc.free(order);
        const levels = try alloc.alloc(u8, scratch_n);
        defer alloc.free(levels);
        var acc: LayoutAcc = .{};
        errdefer acc.deinit(alloc);
        var rel_objs: std.ArrayList([2]f32) = .empty;
        defer rel_objs.deinit(alloc);
        const lines = &acc.lines;
        const out = &acc.out;
        const objects = &acc.objects;
        const frags = &acc.frags;
        const segs = &acc.segs;
        if (!flow) try lines.ensureTotalCapacityPrecise(alloc, size.line_count);
        try out.ensureTotalCapacityPrecise(alloc, self.glyphs.len + (if (flow) 8 else @as(usize, size.line_count) * (@max(self.ell.len(), self.clamp_ell.len()) + 1)));
        const cplx = flow and self.complex;
        if (flow) {
            cx_.?.frags = if (cplx) frags else null;
            cx_.?.frag_alloc = alloc;
        }

        var container: f32 = if (m.avail) |a| a else size.width;
        var it: LineIter = .{ .p = self, .mode = m, .cx = cx_ };
        var top: f32 = 0;
        var li_index: usize = 0;
        var max_w: f32 = 0;
        while (true) : (li_index +%= 1) {
            const frag_start = frags.items.len;
            if (flow) {
                cx_.?.line = @intCast(lines.items.len);
                cx_.?.frag_start = frag_start;
            }
            const li = it.next() orelse break;
            if (flow) {
                if (li.empty) {
                    // (only floats / out-of-flow boxes: their static position is the line top)
                    if (cplx) for (self.glyphs[li.start..li.next]) |g| {
                        if (g.flags & ShapedGlyph.SPECIAL != 0 and (g.gid == Special.oof or g.gid == Special.oof_block))
                            try pushObj(objects, alloc, g.cluster, li.band_x, li.top, lines.items.len);
                    };
                    li_index -%= 1;
                    continue;
                }
                try lines.ensureUnusedCapacity(alloc, 1);
                try out.ensureUnusedCapacity(alloc, (li.end - li.start) + @max(self.ell.len(), self.clamp_ell.len()) + 2);
                top = li.top;
                if (m.avail != null) container = li.band_w;
                max_w = @max(max_w, li.width);
            } else if (li_index >= size.line_count) break;
            // the line's base direction: its bidi paragraph's under `unicode-bidi: plaintext`
            // (takumi / Blink `ComputeBaseDirection`), else the block's
            const line_rtl = self.lineRtl(li.start);
            const base_level: u8 = @intFromBool(line_rtl);
            // Blink aligns on the LayoutUnit grid: free space = available - snapped line width
            const free_raw = floor64(container) - ceil64(li.content_w);
            const free = @max(free_raw, 0);
            var extra: f32 = 0;
            // (the last line and a line before a forced break: `text-align-last`)
            const al: TextAlign = if (!li.last) self.opts.text_align else self.opts.text_align_last orelse
                (if (self.opts.text_align == .justify) TextAlign.start else self.opts.text_align);
            if (al == .justify and !li.ellipsis and free > 0) {
                var spaces: u32 = 0;
                for (self.glyphs[li.start..li.end]) |g| {
                    if (g.flags & ShapedGlyph.WORD_SPACE != 0) spaces += 1;
                }
                if (spaces > 0) extra = free / @as(f32, @floatFromInt(spaces));
            }
            var x: f32 = switch (al) {
                .left => 0,
                .right => free,
                .center => floor64(free * 0.5),
                .start => if (line_rtl) free else 0,
                .end => if (line_rtl) 0 else free,
                .justify => if (line_rtl and extra == 0) free else 0,
            };
            // an overflowing line keeps its start edge: in a right-to-left paragraph it sticks
            // out on the left
            if (free_raw < 0) x = if (line_rtl) free_raw else 0;
            // (the indent is at the inline start of the line box: on the right in a right-to-left paragraph)
            if (!line_rtl) x += li.indent;
            if (flow) x += li.band_x;
            const line_x = x;
            const baseline = top + li.ascent;
            const g_start = out.items.len;
            const count: usize = li.end - li.start;
            const ell_cluster: u32 = if (li.end < self.glyphs.len) self.glyphs[li.end].cluster else if (li.end > 0) self.glyphs[li.end - 1].cluster else 0;
            // visual order of the line's glyphs (L1 + L2)
            var visual = false;
            if (self.has_bidi and count != 0) {
                const lv = levels[0..count];
                var trailing = true;
                var k = count;
                while (k > 0) {
                    k -= 1;
                    const g = self.glyphs[li.start + k];
                    lv[k] = g.level;
                    if (g.flags & ShapedGlyph.SPECIAL != 0 and g.gid <= Special.close) {
                        // inline box edges are opaque to reordering: they take the level after them
                        // (Blink: the placeholder of an empty box)
                        lv[k] = if (k + 1 < count) lv[k + 1] else base_level;
                        if (lv[k] != 0) visual = true;
                        continue;
                    }
                    // L1: tabs, and white space before them / at the line end, take the paragraph level
                    if (g.flags & ShapedGlyph.TAB != 0) {
                        lv[k] = base_level;
                        trailing = true;
                    } else if (trailing and g.flags & ShapedGlyph.WORD_SPACE != 0) {
                        lv[k] = base_level;
                    } else trailing = false;
                    if (lv[k] != 0) visual = true;
                }
                if (visual) bidi.reorderVisual(lv, order[0..count]);
            }
            // complex lines: the spaces before a closing edge at the line end are collapsed
            var tail: u32 = li.end;
            // the open run segment: first output glyph, left edge, run, shift
            var seg_g0: usize = out.items.len;
            var seg_x0: f32 = x;
            var seg_run: u32 = 0xffff_ffff;
            var seg_dy: f32 = 0;
            if (cplx) {
                while (tail > li.start) : (tail -= 1) {
                    const q = self.glyphs[tail - 1];
                    if (q.flags & ShapedGlyph.SPECIAL != 0) {
                        if (q.gid == Special.atomic) break;
                    } else if (q.flags & ShapedGlyph.SPACE == 0) break;
                }
            }
            // lines with reordered runs or right-to-left boxes: the box edges are placed visually
            var ve = false;
            if (cplx and (visual or self.has_rtl_box) and frags.items.len > frag_start)
                ve = try self.visualRanges(cx_.?, frags, alloc, frag_start, &li, if (visual) order[0..count] else null, tail);
            if (cplx and self.has_clone and !ve) {
                // start edges of the cloned boxes continued from the previous line (outer first)
                const cx = cx_.?;
                var k: usize = @min(cx.n_cont, cx.tmp.items.len);
                while (k > 0) {
                    k -= 1;
                    const b = cx.tmp.items[k];
                    const bi = self.boxes[b];
                    if (!bi.clone) continue;
                    touchBox(frags.items[frag_start..], b, x + bi.margin_start, x + bi.start);
                    self.touchChain(frags.items[frag_start..], bi.parent, x, x + bi.start);
                    x += bi.start;
                }
                seg_x0 = x;
            }
            // in a right-to-left paragraph the ellipsis sits at the left (end) edge
            var mk0: u32 = 0;
            var mk1: u32 = 0;
            var rtl_marker_seg: ?usize = null;
            if (li.ellipsis and line_rtl) {
                mk0 = @intCast(out.items.len);
                // (its brush is the last kept logical item's, as on the right of an LTR line)
                var user = self.ell.user;
                var k = li.end;
                while (k > li.start) {
                    k -= 1;
                    const g = self.glyphs[k];
                    if (g.flags & ShapedGlyph.SPECIAL == 0 and g.metric < self.metrics.len) {
                        user = self.metrics[g.metric].user;
                        break;
                    }
                }
                x = self.putEllipsis(out, x, baseline, ell_cluster, li.ell_clamp, user);
                mk1 = @intCast(out.items.len);
                rtl_marker_seg = segs.items.len;
                if (cplx) try self.pushSeg(segs, alloc, &.{}, no_stop, g_start, out.items.len, line_x, x, baseline, lines.items.len);
            }
            var prev_item: u32 = 0xffff_ffff;
            // (`ParagraphOptions.item_origin`, PDF builds)
            const item_origin = if (comptime item_origin_build) self.opts.item_origin else false;
            var ip = ItemPos.init(x);
            _ = &ip;
            var v: usize = 0;
            while (v < count) : (v += 1) {
                if (ve and v > 0 and endsAt(cx_.?, @intCast(v - 1))) {
                    // line-right edges of the fragments that ended with the previous item
                    if (seg_run < 0xffff_fffe) try self.pushSeg(segs, alloc, &.{}, seg_run, seg_g0, out.items.len, seg_x0, x, baseline + seg_dy, lines.items.len);
                    seg_run = 0xffff_ffff;
                    // (item_origin: the edges advance the pen like the edge markers of the logical placement)
                    const xe = edgesAfter(cx_.?, frags.items, @intCast(v - 1), x);
                    x = if (item_origin) ip.add(xe - x) else xe;
                }
                const gi = li.start + (if (visual) order[v] else @as(u32, @intCast(v)));
                const g = self.glyphs[gi];
                if (self.multi_run and g.item != prev_item) {
                    if (item_origin) {
                        if (prev_item != 0xffff_ffff) x = ip.nextItem();
                    } else if (prev_item != 0xffff_ffff) x = line_x + ceil64(x - line_x);
                    prev_item = g.item;
                }
                if (item_origin) ip.face(g.face);
                var dy: f32 = 0;
                if (cplx) {
                    const cx = cx_.?;
                    const slot = cx.n_cont + (gi - li.start);
                    if (slot < cx.dy.items.len) dy = cx.dy.items[slot];
                    const run: u32 = if (g.flags & ShapedGlyph.SPECIAL != 0) 0xffff_fffe else if (g.metric < self.metrics.len) self.metrics[g.metric].run else 0;
                    if (ve) {
                        // fragments starting at this item: their line-left edges, outer boxes first
                        var opened = false;
                        for (cx.vr.items) |r| {
                            if (r.a != @as(u32, @intCast(v))) continue;
                            if (!opened and seg_run < 0xffff_fffe) try self.pushSeg(segs, alloc, &.{}, seg_run, seg_g0, out.items.len, seg_x0, x, baseline + seg_dy, lines.items.len);
                            opened = true;
                            frags.items[r.frag].x0 = x + r.left_m;
                            if (item_origin) {
                                x = ip.add(r.left);
                            } else x += r.left;
                        }
                        if (opened) seg_run = 0xffff_ffff;
                    }
                    if (run != seg_run) {
                        // close the open segment
                        if (seg_run < 0xffff_fffe) try self.pushSeg(segs, alloc, if (ve) &.{} else frags.items[frag_start..], seg_run, seg_g0, out.items.len, seg_x0, x, baseline + seg_dy, lines.items.len);
                        seg_g0 = out.items.len;
                        seg_x0 = x;
                        seg_run = run;
                        seg_dy = dy;
                    }
                    if (g.flags & ShapedGlyph.SPECIAL != 0) {
                        // (visual placement: the edge markers take no room where they are)
                        const adv = if (ve and g.gid <= Special.close) 0 else self.advanceOf(g, x - line_x, m.flow);
                        const fr: []BoxFragment = if (ve) &.{} else frags.items[frag_start..];
                        switch (g.gid) {
                            Special.open, Special.close => if (!ve and g.cluster < self.boxes.len and g.cluster != 0) {
                                const bi = self.boxes[g.cluster];
                                const is_open = g.gid == Special.open;
                                const rtl_run = g.level & 1 != 0;
                                const mg = if (is_open) bi.margin_start else bi.margin_end;
                                // (the margin is on the outer side of the edge)
                                if (is_open != rtl_run) {
                                    touchBox(fr, g.cluster, x + mg, x + adv);
                                } else touchBox(fr, g.cluster, x, x + adv - mg);
                                self.touchChain(fr, bi.parent, x, x + adv);
                            },
                            Special.atomic => {
                                var asc: f32 = 0;
                                if (g.cluster < m.flow.?.objects.len) asc = m.flow.?.objects[g.cluster].ascent;
                                if (!std.math.isFinite(asc)) asc = 0;
                                try pushObj(objects, alloc, g.cluster, x, baseline + dy - asc, lines.items.len);
                                if (self.has_rel) {
                                    // (kept beside the object list: the offset of the boxes around the atomic inline)
                                    while (rel_objs.items.len < objects.items.len) try rel_objs.append(alloc, .{ 0, 0 });
                                    rel_objs.items[objects.items.len - 1] = self.relOf(if (g.metric < self.objs.len) self.objs[g.metric].box else 0);
                                }
                                if (g.metric < self.objs.len) self.touchChain(fr, self.objs[g.metric].box, x, x + adv);
                            },
                            Special.oof => try pushObj(objects, alloc, g.cluster, x, top, lines.items.len),
                            // a block-level box: below the line when something precedes it
                            Special.oof_block => try pushObj(objects, alloc, g.cluster, if (self.rtl) (m.avail orelse 0) else 0, if (x != line_x or out.items.len > g_start) top + li.ascent + li.descent else top, lines.items.len),
                            else => {},
                        }
                        if (item_origin) {
                            x = ip.add(adv);
                        } else x += adv;
                        continue;
                    }
                    if (gi >= tail or g.flags & ShapedGlyph.HARD_BREAK != 0) continue;
                }
                const mt = self.metrics[g.metric];
                // soft-hyphen break: the hyphen follows the last logical glyph of the line
                const hyphen_here = li.hyphen and gi + 1 == li.end;
                if (hyphen_here and g.level & 1 != 0) {
                    out.appendAssumeCapacity(.{ .face = mt.face, .gid = mt.hyphen_gid, .x = x, .y = baseline + dy, .size = mt.size, .user = mt.user, .cluster = g.cluster, .bidi_level = g.level, .generated = mt.hyphen_cp });
                    if (item_origin) {
                        x = ip.add(mt.hyphen_adv - g.kern);
                    } else x += mt.hyphen_adv - g.kern;
                }
                out.appendAssumeCapacity(.{
                    .face = g.face,
                    .gid = g.gid,
                    // (takumi: `origin.x + (advance + offset.x)`)
                    .x = if (item_origin) ip.glyphX(g.x_offset) else x + g.x_offset,
                    .y = baseline + dy - g.y_offset,
                    .size = mt.size,
                    .user = mt.user,
                    .cluster = g.cluster,
                    .bidi_level = g.level,
                });
                if (item_origin) {
                    _ = ip.add(self.advanceOf(g, x - line_x, null));
                    x = ip.add(if (g.flags & ShapedGlyph.WORD_SPACE != 0) extra else 0);
                    if (comptime item_origin_build) out.items[out.items.len - 1].x_end = x;
                } else {
                    x += self.advanceOf(g, x - line_x, null);
                    if (g.flags & ShapedGlyph.WORD_SPACE != 0) x += extra;
                }
                if (hyphen_here and g.level & 1 == 0) {
                    // (item_origin: Blink places the hyphen after the item's snapped inline size)
                    const hx = if (item_origin) ip.org + ceil64(@floatCast(ip.loc - g.kern)) else x - g.kern;
                    out.appendAssumeCapacity(.{ .face = mt.face, .gid = mt.hyphen_gid, .x = hx, .y = baseline + dy, .size = mt.size, .user = mt.user, .cluster = g.cluster, .bidi_level = g.level, .generated = mt.hyphen_cp });
                    if (item_origin) {
                        x = ip.add(mt.hyphen_adv - g.kern);
                    } else x += mt.hyphen_adv - g.kern;
                }
            }
            if (ve and count > 0 and endsAt(cx_.?, @intCast(count - 1))) {
                if (seg_run < 0xffff_fffe) try self.pushSeg(segs, alloc, &.{}, seg_run, seg_g0, out.items.len, seg_x0, x, baseline + seg_dy, lines.items.len);
                seg_run = 0xffff_ffff;
                x = edgesAfter(cx_.?, frags.items, @intCast(count - 1), x);
            }
            if (cplx) {
                if (seg_run < 0xffff_fffe) try self.pushSeg(segs, alloc, if (ve) &.{} else frags.items[frag_start..], seg_run, seg_g0, out.items.len, seg_x0, x, baseline + seg_dy, lines.items.len);
                // end edges of the cloned boxes that continue on the next line (inner first)
                if (self.has_clone and !ve and li.end < self.glyphs.len) {
                    var b = self.boxBefore(li.end);
                    while (b != 0) : (b = self.boxes[b].parent) {
                        const bi = self.boxes[b];
                        if (!bi.clone) continue;
                        touchBox(frags.items[frag_start..], b, x, x + bi.end - bi.margin_end);
                        self.touchChain(frags.items[frag_start..], bi.parent, x, x + bi.end);
                        x += bi.end;
                    }
                }
                // out-of-flow boxes after the visible content
                for (self.glyphs[li.end..li.next]) |g| {
                    if (g.flags & ShapedGlyph.SPECIAL == 0) continue;
                    if (g.gid == Special.oof) try pushObj(objects, alloc, g.cluster, x, top, lines.items.len);
                    if (g.gid == Special.oof_block) try pushObj(objects, alloc, g.cluster, if (self.rtl) (m.avail orelse 0) else 0, top + li.ascent + li.descent, lines.items.len);
                }
                const cx = cx_.?;
                for (frags.items[frag_start..]) |*f| {
                    f.baseline = baseline + (if (f.slot < cx.dy.items.len) cx.dy.items[f.slot] else 0);
                    f.line = @intCast(lines.items.len);
                }
            }
            // (PDF builds) a right-to-left line's marker is visually first but its last logical
            // item (takumi `LineTruncator`): its segment follows the line's other segments, so
            // the content stream / extracted text has it after the content it stands in for
            if (comptime item_origin_build) if (rtl_marker_seg) |k| if (cplx and k + 1 < segs.items.len and segs.items[k].g0 == mk0 and segs.items[k].g1 == mk1) {
                std.mem.rotate(Segment, segs.items[k..], 1);
            };
            if (li.ellipsis and !line_rtl) {
                const e0 = out.items.len;
                // The marker is a new logical item: its origin follows the preceding item's
                // snapped inline size, and its brush belongs to that item (font stays strut).
                x = if (item_origin) ip.nextItem() else line_x + ceil64(x - line_x);
                const ex = x;
                const user = if (out.items.len > g_start) out.items[out.items.len - 1].user else self.ell.user;
                x = self.putEllipsis(out, x, baseline, ell_cluster, li.ell_clamp, user);
                mk0 = @intCast(e0);
                mk1 = @intCast(out.items.len);
                if (cplx) try self.pushSeg(segs, alloc, &.{}, no_stop, e0, out.items.len, ex, x, baseline, lines.items.len);
            }
            lines.appendAssumeCapacity(.{
                .baseline = baseline,
                .top = top,
                .height = li.ascent + li.descent,
                .x = line_x,
                .width = if (extra != 0) x - line_x else li.width - li.indent,
                .glyph_start = @intCast(g_start),
                .glyph_end = @intCast(out.items.len),
                .ascent = li.ascent,
                .descent = li.descent,
                .rtl = line_rtl,
                .marker0 = if (item_origin_build) mk0 else {},
                .marker1 = if (item_origin_build) mk1 else {},
                .start = if (item_origin_build) li.start else {},
            });
            top += li.ascent + li.descent;
        }
        if (flow and cx_.?.oom) return error.OutOfMemory;
        if (self.has_rel) self.applyRel(&acc, rel_objs.items);

        // paint order: box by box (outer boxes first), each box line by line
        try sortFragsByBox(alloc, frags.items);
        var res: TextLayout = .{
            .width = if (flow) ceil64(max_w) else size.width,
            .height = if (flow) it.y else size.height,
            .exact_width = if (flow) max_w else size.exact_width,
            .lines = &.{},
            .glyphs = &.{},
            .pct_base = self.pct_base,
        };
        return acc.finish(alloc, &res);
    }

    /// Output lists of `layoutImpl` (one cleanup path for all of them).
    const LayoutAcc = struct {
        lines: std.ArrayList(Line) = .empty,
        out: std.ArrayList(PositionedGlyph) = .empty,
        objects: std.ArrayList(ObjectPos) = .empty,
        frags: std.ArrayList(BoxFragment) = .empty,
        segs: std.ArrayList(Segment) = .empty,

        noinline fn deinit(a: *LayoutAcc, alloc: std.mem.Allocator) void {
            a.lines.deinit(alloc);
            a.out.deinit(alloc);
            a.objects.deinit(alloc);
            a.frags.deinit(alloc);
            a.segs.deinit(alloc);
        }

        noinline fn finish(a: *LayoutAcc, alloc: std.mem.Allocator, res: *TextLayout) !TextLayout {
            errdefer {
                alloc.free(res.objects);
                alloc.free(res.boxes);
                alloc.free(res.segments);
                alloc.free(res.lines);
            }
            res.objects = try a.objects.toOwnedSlice(alloc);
            res.boxes = try a.frags.toOwnedSlice(alloc);
            res.segments = try a.segs.toOwnedSlice(alloc);
            res.lines = try a.lines.toOwnedSlice(alloc);
            res.glyphs = try a.out.toOwnedSlice(alloc);
            return res.*;
        }
    };

    noinline fn putEllipsis(self: *const Paragraph, out: *std.ArrayList(PositionedGlyph), x_in: f32, baseline: f32, cluster: u32, clamp: bool, user: u32) f32 {
        const mk = if (clamp) &self.clamp_ell else &self.ell;
        if (mk.glyphs.len > 0) {
            for (mk.glyphs) |g| {
                var o = g;
                o.x = x_in + g.x;
                o.y = baseline + g.y;
                o.cluster = cluster;
                o.user = user;
                out.appendAssumeCapacity(o);
            }
            return x_in + mk.w;
        }
        var x = x_in;
        var k: u8 = 0;
        while (k < mk.count) : (k += 1) {
            out.appendAssumeCapacity(.{ .face = mk.face, .gid = mk.gid, .x = x, .y = baseline, .size = mk.size, .user = user, .cluster = cluster, .bidi_level = @intFromBool(self.rtl) });
            x += mk.adv;
        }
        return x_in + mk.w;
    }

    /// Alias of `layout` (name used in the module brief).
    pub fn breakLines(self: *const Paragraph, alloc: std.mem.Allocator, max_width: ?f32) !TextLayout {
        return self.layout(alloc, max_width);
    }
};

/// One-shot convenience: shape + lay out at `opts.max_width`.
pub fn layoutText(alloc: std.mem.Allocator, fonts: *const FontCollection, runs: []const Run, opts: ParagraphOptions) !TextLayout {
    var p = try Paragraph.init(alloc, fonts, runs, opts);
    defer p.deinit();
    return p.layout(alloc, null);
}

// ------------------------------------------------------------------ internals

/// Text of a custom overflow marker from raw CSS string contents: CSS escapes processed
/// (`\` + 1-6 hex digits + one optional whitespace, `\` + char, escaped newline dropped), every
/// run of forced line breaks replaced by one space (Blink `SuppressLineBreaks`). Invalid UTF-8
/// bytes become U+FFFD.
fn markerText(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    // worst case: "\0" (2 bytes) -> U+FFFD (3 bytes); a stray byte -> U+FFFD (3 bytes)
    const out = try alloc.alloc(u8, raw.len * 3 + 4);
    defer alloc.free(out);
    var n: usize = 0;
    var i: usize = 0;
    var after_break = false;
    while (i < raw.len) {
        var cp: u21 = 0xFFFD;
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            var v: u32 = 0;
            var digits: usize = 0;
            while (digits < 6 and i < raw.len and std.ascii.isHex(raw[i])) : (digits += 1) {
                v = v * 16 + (std.fmt.charToDigit(raw[i], 16) catch 0);
                i += 1;
            }
            if (digits > 0) {
                if (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\n')) i += 1;
                if (v != 0 and v <= 0x10FFFF and !(v >= 0xD800 and v <= 0xDFFF)) cp = @intCast(v);
            } else if (raw[i] == '\n') {
                i += 1;
                continue;
            } else cp = decodeAt(raw, &i);
        } else cp = decodeAt(raw, &i);
        const forced = switch (cp) {
            '\n', 0x0B, 0x0C, 0x85, 0x2028, 0x2029 => true,
            else => false,
        };
        if (forced) {
            if (!after_break) {
                out[n] = ' ';
                n += 1;
            }
            after_break = true;
            continue;
        }
        after_break = false;
        n += encodeUtf8(cp, out[n..][0..4]);
    }
    return alloc.dupe(u8, out[0..n]);
}

/// UTF-8 encoding of a scalar value (surrogates never reach here: decoders yield U+FFFD).
fn encodeUtf8(cp: u21, out: *[4]u8) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = @intCast(0xF0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

/// One UTF-8 character of `s` at `i.*` (U+FFFD for a malformed sequence); advances `i`.
fn decodeAt(s: []const u8, i: *usize) u21 {
    const d = uni.decodeUtf8(s, i.*);
    i.* += d.len;
    return d.cp;
}

const hard_break_cp: u21 = '\n';

/// White-space processing: UTF-8 decode all runs into `out`, collapsing / preserving spaces
/// per `white-space`. Returns the number of characters written.
fn collectChars(runs: []const Run, opts: ParagraphOptions, out: []Char, info: *CharInfo) void {
    var n: usize = 0;
    var base: u32 = 0;
    var prev_space = true; // strips leading collapsible space
    var prev_cr = false;
    defer info.n = n;
    if (runs.len == 0) info.any_wrap = wsWraps(opts.white_space);
    for (runs, 0..) |r, ri| {
        const ws = r.white_space orelse opts.white_space;
        const collapse = switch (ws) {
            .normal, .nowrap, .pre_line => true,
            .pre, .pre_wrap => false,
        };
        const nw = !wsWraps(ws);
        if (nw) info.any_nowrap = true else info.any_wrap = true;
        if (r.object) |o| {
            // an atomic inline is one character (U+FFFC) that is no white space; floats and
            // out-of-flow boxes are transparent
            if (o.kind == .atomic) {
                out[n] = .{ .cp = 0xfffc, .run = @intCast(ri), .cluster = base, .nw = nw, .obj = true };
                n += 1;
                info.any_obj = true;
                prev_space = false;
                prev_cr = false;
            }
            if (r.hard_break_after) {
                if (collapse and n > 0 and out[n - 1].cp == ' ') n -= 1;
                if (collapse) prev_space = true;
                out[n] = .{ .cp = hard_break_cp, .run = @intCast(ri), .cluster = base, .nw = nw };
                n += 1;
            }
            continue;
        }
        const s = r.text;
        var i: usize = 0;
        while (i < s.len) {
            const d = uni.decodeUtf8(s, i);
            const cluster = base + @as(u32, @intCast(i));
            i += d.len;
            var cp = d.cp;
            const was_cr = prev_cr;
            prev_cr = cp == '\r';
            if (cp == 0x2028) {
                // LINE SEPARATOR: a preserved segment break in every white-space mode
                if (collapse and n > 0 and out[n - 1].cp == ' ') n -= 1;
                if (collapse) prev_space = true;
                out[n] = .{ .cp = hard_break_cp, .run = @intCast(ri), .cluster = cluster, .nw = nw };
                n += 1;
                continue;
            }
            if (cp == '\n' or cp == '\r' or cp == 0x0c) {
                if (collapse and ws != .pre_line) {
                    cp = ' ';
                } else {
                    if (cp == '\n' and was_cr) continue; // CRLF
                    if (collapse) {
                        // pre-line: spaces around a preserved newline vanish
                        if (n > 0 and out[n - 1].cp == ' ') n -= 1;
                        prev_space = true;
                    }
                    out[n] = .{ .cp = hard_break_cp, .run = @intCast(ri), .cluster = cluster, .nw = nw };
                    n += 1;
                    continue;
                }
            }
            if (collapse) {
                if (cp == ' ' or cp == '\t') {
                    if (prev_space) continue;
                    prev_space = true;
                    cp = ' ';
                } else prev_space = false;
            }
            if (cp != '\t' and (cp < 0x20 or (cp >= 0x7f and cp < 0xa0))) {
                // (PDF frames, `item_origin`: takumi ignores only carriage return and form feed and
                // shapes the other control characters, which no font draws: `uncoveredText`
                // decides, as for any character no font covers; a raster render drops them)
                const keep = if (comptime item_origin_build) opts.item_origin and cp != 0x0d and cp != 0x0c else false;
                if (!keep) continue;
            }
            out[n] = .{ .cp = cp, .run = @intCast(ri), .cluster = cluster, .nw = nw };
            n += 1;
        }
        base += @intCast(s.len);
        if (r.hard_break_after) {
            if (collapse and n > 0 and out[n - 1].cp == ' ') n -= 1;
            if (collapse) prev_space = true;
            out[n] = .{ .cp = hard_break_cp, .run = @intCast(ri), .cluster = base, .nw = nw };
            n += 1;
            prev_cr = false;
        }
    }
    // (PDF frames, `item_origin`: a collapsible space that ends the paragraph is removed before
    // shaping, as Blink / takumi remove it, so the glyph before it keeps no kerning with it; a
    // raster render shapes it and hangs it)
    if (comptime item_origin_build) {
        if (opts.item_origin and n > 0 and out[n - 1].cp == ' ' and !out[n - 1].obj) {
            const last = runs[out[n - 1].run];
            const ws = last.white_space orelse opts.white_space;
            if (ws == .normal or ws == .nowrap or ws == .pre_line) n -= 1;
        }
    }
}

/// Soft wrap opportunities around non-wrapping runs and atomic inlines (Blink's `LineBreaker`):
/// none between two characters of non-wrapping runs; always one before an atomic inline and one
/// after it (unless a space follows: the opportunity is then after the spaces).
fn fixBreaks(chars: []Char) void {
    for (chars, 0..) |*c, i| {
        if (i == 0) continue;
        const prev = chars[i - 1];
        if (c.nw and prev.nw) {
            c.brk = false;
        } else if (c.cp == hard_break_cp or prev.cp == hard_break_cp) {
            // (forced breaks are not opportunities)
        } else if (c.obj) {
            if (!c.nw) c.brk = true;
        } else if (prev.obj and !prev.nw and c.cp != ' ' and c.cp != '\t') c.brk = true;
    }
}

/// A break opportunity before the first character of an inline box is one before its opening
/// edge (the edge stays with the text); floats and out-of-flow boxes between that edge and the
/// text go to the next line with it.
fn moveBreaks(gs: []ShapedGlyph) void {
    for (gs, 0..) |*g, i| {
        if (g.flags & ShapedGlyph.BREAK_BEFORE == 0 or i == 0) continue;
        if (gs[i - 1].flags & ShapedGlyph.SPECIAL == 0) continue;
        g.flags &= ~ShapedGlyph.SOFT_HYPHEN;
        var target = i;
        var j = i;
        while (j > 0) : (j -= 1) {
            const q = gs[j - 1];
            if (q.flags & ShapedGlyph.SPECIAL == 0) break;
            if (q.gid == Special.open) {
                target = j - 1;
            } else if (q.gid < Special.float) break;
        }
        if (target != i) {
            g.flags &= ~ShapedGlyph.BREAK_BEFORE;
            gs[target].flags |= ShapedGlyph.BREAK_BEFORE;
        }
    }
}

fn markBreaks(chars: []Char, opts: ParagraphOptions) void {
    var bb: u21 = 0;
    var b: u21 = 0;
    for (chars, 0..) |*c, i| {
        if (i > 0 and b != hard_break_cp and c.cp != hard_break_cp)
            c.brk = uni.canBreak(bb, if (b == '\t') ' ' else b, if (c.cp == '\t') ' ' else c.cp, opts.word_break);
        bb = b;
        b = c.cp;
    }
}

/// `markBreaks` with the full UAX #14 rules (`unicode.lineBreaks`) behind Blink's overrides:
/// always break after a run of spaces, Chromium's table for printable-ASCII pairs.
fn markBreaksFull(alloc: std.mem.Allocator, chars: []Char, opts: ParagraphOptions) !void {
    // pure ASCII without break-all never consults UAX #14
    var need_uax = opts.word_break == .break_all;
    if (!need_uax) {
        for (chars) |c| {
            if (c.cp >= 0x80) {
                need_uax = true;
                break;
            }
        }
    }
    const cls = try alloc.alloc(u8, if (need_uax) chars.len else 0);
    defer alloc.free(cls);
    if (need_uax) {
        for (chars, cls) |c, *k| {
            k.* = if (c.cp == hard_break_cp) @backingInt(uni.Lb.bk) else if (c.cp == '\t') @backingInt(uni.Lb.sp) else uni.lbByte(c.cp);
        }
        uni.lineBreaksPrepare(cls, opts.word_break);
    }
    var bb: u21 = 0;
    var b: u21 = 0;
    for (chars, 0..) |*c, i| {
        const a: u21 = if (c.cp == '\t') ' ' else c.cp;
        if (b != 0 and b != hard_break_cp and a != hard_break_cp) {
            if (b == ' ') {
                c.brk = a != ' ';
            } else if (uni.isAsciiPair(b, a)) {
                c.brk = uni.asciiPairBreak(bb, b, a) or (opts.word_break == .break_all and uni.lineBreakAt(cls, i));
            } else c.brk = uni.lineBreakAt(cls, i);
        }
        bb = b;
        b = a;
    }
}

/// UAX #9 levels for every paragraph part (parts are separated by forced breaks).
fn resolveBidi(alloc: std.mem.Allocator, chars: []Char, rtl_base: bool) !void {
    const n = chars.len;
    if (n == 0) return;
    var need = rtl_base;
    if (!need) {
        for (chars) |c| {
            if (c.cp >= 0x590) {
                need = true;
                break;
            }
        }
    }
    if (!need) return;
    const cps = try alloc.alloc(u21, n);
    defer alloc.free(cps);
    for (chars, cps) |c, *p| p.* = c.cp;
    if (!rtl_base and !bidi.needsBidi(cps)) return;
    const levels = try alloc.alloc(u8, n);
    defer alloc.free(levels);
    const base: u8 = @intFromBool(rtl_base);
    var s: usize = 0;
    while (s < n) {
        var e = s;
        while (e < n and cps[e] != hard_break_cp) e += 1;
        try bidi.resolve(alloc, cps[s..e], levels[s..e], base);
        if (e < n) levels[e] = base;
        s = e + 1;
    }
    for (chars, levels) |*c, l| c.level = l;
}

/// CSS bidi contexts are virtual UAX #9 controls: never glyphs, never source clusters.
/// Preserve the inline ancestry across runs, so an override also applies inside nested spans.
/// `unicode-bidi: plaintext` on the block: the base direction each bidi paragraph (forced-break
/// separated) takes from its first strong character, by first cluster.
const PlainPara = struct { cluster: u32, rtl: bool };

fn resolveCssBidi(alloc: std.mem.Allocator, chars: []Char, runs: []const Run, opts: ParagraphOptions, plain: ?*std.ArrayList(PlainPara), plain_alloc: std.mem.Allocator) !void {
    const Scope = struct { key: u32, mode: BidiMode, rtl: bool };
    const Control = struct {
        fn open(a: std.mem.Allocator, out: *std.ArrayList(u21), scope: Scope) !void {
            if (scope.mode == .isolate_override) try out.append(a, if (scope.rtl) 0x2067 else 0x2066);
            try out.append(a, switch (scope.mode) {
                .embed => if (scope.rtl) @as(u21, 0x202b) else 0x202a,
                .bidi_override, .isolate_override => if (scope.rtl) @as(u21, 0x202e) else 0x202d,
                .isolate => if (scope.rtl) @as(u21, 0x2067) else 0x2066,
                .plaintext => 0x2068,
                .normal => unreachable,
            });
        }
        fn close(a: std.mem.Allocator, out: *std.ArrayList(u21), scope: Scope) !void {
            if (scope.mode == .isolate_override) try out.append(a, 0x202c);
            try out.append(a, if (scope.mode == .isolate or scope.mode == .isolate_override or scope.mode == .plaintext) 0x2069 else 0x202c);
        }
    };
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(alloc);
    const map = try alloc.alloc(usize, chars.len);
    defer alloc.free(map);
    var start: usize = 0;
    while (start < chars.len) {
        var end = start;
        while (end < chars.len and chars[end].cp != hard_break_cp) : (end += 1) {}
        cps.clearRetainingCapacity();
        var active: [130]Scope = undefined;
        var n_active: usize = 0;
        for (chars[start..end], start..) |ch, index| {
            var next: [130]Scope = undefined;
            var count: usize = 0;
            if (opts.strut) |s| if (s.unicode_bidi != .normal and s.unicode_bidi != .plaintext) {
                next[count] = .{ .key = no_box, .mode = s.unicode_bidi, .rtl = s.rtl };
                count += 1;
            };
            var chain: [128]u32 = undefined;
            var n_chain: usize = 0;
            var box = runs[ch.run].box;
            while (box < opts.boxes.len and n_chain < chain.len) {
                chain[n_chain] = box;
                n_chain += 1;
                box = opts.boxes[box].parent;
            }
            while (n_chain > 0) {
                n_chain -= 1;
                const key = chain[n_chain];
                const s = opts.boxes[key].style;
                if (s.unicode_bidi != .normal) {
                    next[count] = .{ .key = key, .mode = s.unicode_bidi, .rtl = s.rtl };
                    count += 1;
                }
            }
            const run = runs[ch.run];
            // A boxed run already has the element's scope in its ancestry. The block's own
            // run is likewise covered by the strut scope; avoid applying either twice.
            const covered = (run.box < opts.boxes.len and opts.boxes[run.box].style.unicode_bidi == run.style.unicode_bidi and opts.boxes[run.box].style.rtl == run.style.rtl) or
                (run.box == no_box and opts.strut != null and opts.strut.?.unicode_bidi == run.style.unicode_bidi and opts.strut.?.rtl == run.style.rtl);
            if (!covered and run.style.unicode_bidi != .normal) {
                next[count] = .{ .key = 0x80000000 + @as(u32, ch.run), .mode = run.style.unicode_bidi, .rtl = run.style.rtl };
                count += 1;
            }
            var common: usize = 0;
            while (common < count and common < n_active and std.meta.eql(next[common], active[common])) : (common += 1) {}
            while (n_active > common) {
                n_active -= 1;
                try Control.close(alloc, &cps, active[n_active]);
            }
            for (next[common..count]) |scope| try Control.open(alloc, &cps, scope);
            @memcpy(active[0..count], next[0..count]);
            n_active = count;
            map[index] = cps.items.len;
            try cps.append(alloc, ch.cp);
        }
        while (n_active > 0) {
            n_active -= 1;
            try Control.close(alloc, &cps, active[n_active]);
        }
        var base: u8 = @intFromBool(opts.direction == .rtl);
        if (opts.strut != null and opts.strut.?.unicode_bidi == .plaintext) {
            // UAX #9 P2 / P3: the first strong character, else left-to-right (takumi
            // `BidiParagraph::new(text, None)`), whatever `direction` says.
            base = 0;
            for (chars[start..end]) |ch| {
                switch (uni.bidiClass(ch.cp)) {
                    .l => break,
                    .r, .al => {
                        base = 1;
                        break;
                    },
                    else => {},
                }
            }
            if (plain) |list| if (start < chars.len) try list.append(plain_alloc, .{ .cluster = chars[start].cluster, .rtl = base == 1 });
        }
        const levels = try alloc.alloc(u8, cps.items.len);
        defer alloc.free(levels);
        try bidi.resolve(alloc, cps.items, levels, base);
        for (chars[start..end], start..) |*ch, i| ch.level = levels[map[i]];
        if (end < chars.len) chars[end].level = base;
        start = end + 1;
    }
}

test "CSS bidi override contexts cover nested inline runs without source controls" {
    var chars = [_]Char{ .{ .cp = 'a', .run = 0, .cluster = 0 }, .{ .cp = 'b', .run = 1, .cluster = 1 }, .{ .cp = 'c', .run = 0, .cluster = 2 } };
    const runs = [_]Run{ .{ .text = "ac", .box = 0 }, .{ .text = "b", .box = 1 } };
    const boxes = [_]InlineBox{
        .{ .style = .{ .unicode_bidi = .bidi_override, .rtl = true } },
        .{ .parent = 0, .style = .{ .unicode_bidi = .bidi_override, .rtl = false } },
    };
    try resolveCssBidi(std.testing.allocator, &chars, &runs, .{ .boxes = &boxes }, null, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), chars[0].level & 1);
    try std.testing.expectEqual(@as(u8, 0), chars[1].level & 1);
    try std.testing.expectEqual(@as(u8, 1), chars[2].level & 1);
    try std.testing.expectEqual(@as(u32, 1), chars[1].cluster);
}

const Pick = struct { face: FaceId, gid: u16 };

fn pickFace(fonts: *const FontCollection, faces: []const FaceId, cp: u21) Pick {
    for (faces) |id| {
        if (!fonts.allows(id, cp)) continue;
        const g = fonts.font(id).glyphIndex(cp);
        if (g != 0) return .{ .face = id, .gid = g };
    }
    return .{ .face = faces[0], .gid = 0 };
}

const BracketRec = struct { close: u16, script: u8 };

const Builder = struct {
    alloc: std.mem.Allocator,
    /// working memory (`ParagraphOptions.scratch`): `buf`, `open_tmp` and copies of the buffer
    tmp: std.mem.Allocator,
    fonts: *const FontCollection,
    opts: ParagraphOptions,
    chars: []Char,
    runs: []const Run = &.{},
    cache: *shp.Cache,
    /// Pending segment (same style run, face, script and bidi level) awaiting shaping.
    buf: ot.Buffer,
    glyphs: std.ArrayList(ShapedGlyph) = .empty,
    metrics: std.ArrayList(Metric) = .empty,
    seg_face: FaceId = 0,
    seg_metric: u16 = 0,
    seg_script: u8 = 0,
    seg_level: u8 = 0,
    /// Running starter of the current cluster (for composition-aware font fallback).
    starter: u21 = 0,
    prev_cp: u21 = 0,
    /// GB11 state for `prev_cp` (see `unicode.clusterPrev`)
    prev_pict: bool = false,
    /// Inline item counter (style run x bidi run).
    item: u16 = 0,
    /// Features of the current style run (`ParagraphOptions.features` + `TextStyle.features`).
    feats: [32]shp.FeatureSetting = undefined,
    n_feats: u8 = 0,
    /// Open brackets and the script of the run they were opened in.
    brackets: [32]BracketRec = undefined,
    n_brackets: u8 = 0,
    any_rtl: bool = false,
    /// Index of the first char whose break flag has not been attributed to a glyph yet.
    brk_from: usize = 0,
    // inline boxes / objects (see `Paragraph.complex`)
    cx: bool = false,
    boxes: []BoxInfo = &.{},
    run_box: []u32 = &.{},
    objs: std.ArrayList(ObjInfo) = .empty,
    open_tmp: std.ArrayList(u32) = .empty,
    /// innermost open inline box / first run whose boxes and objects have not been entered yet
    cur_box: u32 = 0,
    next_run: u32 = 0,
    /// spaces of the current run hang at a line end (its white-space is not `pre`)
    hang: bool = true,
    nowrap: bool = false,
    /// `overflow-wrap` of the current run
    ow: OverflowWrap = .normal,
    has_clone: bool = false,
    has_rtl_box: bool = false,
    has_pct: bool = false,
    has_rel: bool = false,
    base_level: u8 = 0,

    /// Resolves `ParagraphOptions.boxes` and decides whether the paragraph needs the inline box
    /// machinery at all (plain styled runs do not).
    fn prepareBoxes(b: *Builder, runs: []const Run) !void {
        const src = b.opts.boxes;
        var cx = false;
        for (runs) |r| {
            if (r.object != null) cx = true;
        }
        if (!cx and src.len == 0) return;
        if (src.len >= 0x7fff_ffff) return error.OutOfMemory;
        const ib = try b.alloc.alloc(BoxInfo, src.len + 1);
        errdefer b.alloc.free(ib);
        const strut_style: TextStyle = b.opts.strut orelse (if (runs.len > 0) runs[0].style else TextStyle{});
        ib[0] = boxInfo(b.fonts, strut_style, b.opts.line_height);
        for (src, 1..) |s, k| {
            var bi = boxInfo(b.fonts, s.style, s.line_height orelse b.opts.line_height);
            bi.parent = if (s.parent != no_box and s.parent + 1 < k) s.parent + 1 else 0;
            bi.valign = switch (s.valign) {
                .length => |v| if (std.math.isFinite(v)) s.valign else .baseline,
                else => s.valign,
            };
            const e = [4]f32{ s.start, s.end, s.margin_start, s.margin_end };
            if (std.math.isFinite(e[0]) and std.math.isFinite(e[1]) and std.math.isFinite(e[2]) and std.math.isFinite(e[3])) {
                bi.start = e[0];
                bi.end = e[1];
                bi.margin_start = e[2];
                bi.margin_end = e[3];
                bi.clone = s.clone and (e[0] != 0 or e[1] != 0);
                if (bi.clone) b.has_clone = true;
            }
            bi.rtl = s.rtl;
            bi.no_start = s.no_start;
            bi.no_end = s.no_end;
            if (std.math.isFinite(s.rel[0]) and std.math.isFinite(s.rel[1]) and (s.rel[0] != 0 or s.rel[1] != 0)) {
                bi.rel = s.rel;
                b.has_rel = true;
                cx = true;
            }
            if (s.rtl) b.has_rtl_box = true;
            if (s.pct) |ep| {
                bi.pct = ep;
                bi.resolveEdges(0);
                bi.clone = s.clone;
                if (bi.clone) b.has_clone = true;
                b.has_pct = true;
                cx = true;
            }
            ib[k] = bi;
            if (s.decorated or bi.valign != .baseline or bi.start != 0 or bi.end != 0 or bi.normal_lh != ib[0].normal_lh or
                (!bi.normal_lh and (bi.ascent != ib[0].ascent or bi.descent != ib[0].descent))) cx = true;
        }
        if (!cx) {
            b.alloc.free(ib);
            return;
        }
        b.run_box = try b.alloc.alloc(u32, runs.len);
        b.boxes = ib;
        for (runs, b.run_box) |r, *rb| rb.* = if (r.box < src.len) r.box + 1 else 0;
        b.cx = true;
    }

    fn special(b: *Builder, kind: u16, id: u32, adv: f32, metric: u16, level: u8, flags: u8) !void {
        b.item +|= 1;
        try b.glyphs.append(b.alloc, .{ .face = 0, .gid = kind, .cluster = id, .x_advance = adv, .metric = metric, .flags = ShapedGlyph.SPECIAL | ShapedGlyph.NO_SPLIT | flags, .level = level, .item = b.item });
        b.item +|= 1;
    }

    fn objIndex(b: *Builder, o: Object) !u16 {
        if (b.objs.items.len >= 0xffff) return error.OutOfMemory;
        try b.objs.append(b.alloc, .{ .box = b.cur_box, .valign = o.valign });
        return @intCast(b.objs.items.len - 1);
    }

    /// Closes / opens inline boxes until `to` is the innermost open one.
    fn moveToBox(b: *Builder, to: u32, level: u8) !void {
        var a = b.cur_box;
        var t = to;
        b.open_tmp.clearRetainingCapacity();
        // (a parent always has a smaller index than its children)
        while (a != t) {
            if (a > t) {
                const lv = if (b.glyphs.items.len > 0) b.glyphs.items[b.glyphs.items.len - 1].level else b.base_level;
                try b.special(Special.close, a, b.boxes[a].end, 0, lv, 0);
                a = b.boxes[a].parent;
            } else {
                try b.open_tmp.append(b.tmp, t);
                t = b.boxes[t].parent;
            }
        }
        var k = b.open_tmp.items.len;
        while (k > 0) {
            k -= 1;
            const x = b.open_tmp.items[k];
            try b.special(Special.open, x, b.boxes[x].start, 0, level, 0);
        }
        b.cur_box = to;
    }

    /// Box edges and transparent objects of the runs up to and including `upto`.
    fn enterRuns(b: *Builder, runs: []const Run, upto: usize, level: u8) !void {
        while (b.next_run <= upto and b.next_run < runs.len) : (b.next_run += 1) {
            const r = b.next_run;
            try b.moveToBox(b.run_box[r], level);
            if (runs[r].object) |o| if (o.kind != .atomic) {
                const oi = try b.objIndex(o);
                try b.special(if (o.kind == .float) Special.float else if (o.block_level) Special.oof_block else Special.oof, o.id, 0, oi, level, 0);
            };
        }
    }

    fn metricFor(b: *Builder, run: u16, face: FaceId, style: TextStyle) !u16 {
        for (b.metrics.items, 0..) |m, i| {
            if (m.run == run and m.face == face and m.size == style.size) return @intCast(i);
        }
        if (b.metrics.items.len >= 0xffff) return error.OutOfMemory;
        const f = b.fonts.font(face);
        const m = computeMetric(f, style.size, .normal);
        var hy = f.glyphIndex(0x2010);
        if (hy == 0) hy = f.glyphIndex('-');
        try b.metrics.append(b.alloc, .{
            .run = run,
            .face = face,
            .size = style.size,
            .user = style.user,
            .ascent = m[0],
            .descent = m[1],
            .font_ascent = m[2],
            .font_descent = m[3],
            .hyphen_gid = hy,
            .hyphen_cp = if (f.glyphIndex(0x2010) == hy) 0x2010 else '-',
            .hyphen_adv = scaleAdvance(f.advanceWidth(hy), @as(f64, style.size) * 65536.0 / @as(f64, @floatFromInt(f.units_per_em))),
            .nowrap = b.nowrap,
            .ow = b.ow,
        });
        return @intCast(b.metrics.items.len - 1);
    }

    /// Break flags (BREAK_BEFORE / SOFT_HYPHEN) for a glyph whose first character is `upto`,
    /// gathering the opportunities of skipped (zero-width) characters before it.
    fn takeBreak(b: *Builder, upto: usize) u8 {
        var fl: u8 = 0;
        if (upto < b.brk_from) return 0;
        var i = b.brk_from;
        while (i <= upto) : (i += 1) {
            if (b.chars[i].brk) {
                fl |= ShapedGlyph.BREAK_BEFORE;
                if (i > 0 and b.chars[i - 1].cp == 0xad) fl |= ShapedGlyph.SOFT_HYPHEN;
            }
        }
        b.brk_from = upto + 1;
        return fl;
    }

    const ZwOnly = struct { face: FaceId, cluster: u32, metric: u16, level: u8, item: u16 };

    /// A line (the paragraph, or the part after a forced break) whose only characters are default
    /// ignorables (U+200B, U+2060, U+200D, U+00AD, U+FEFF, direction marks, ...) still makes a line
    /// box in Blink and in takumi (HarfBuzz keeps them as the space glyph without advance); the
    /// shaper drops them, which would leave the line without glyphs and so without a line. Puts one
    /// such invisible glyph back for that line only: lines with any other glyph are unchanged.
    fn lineOfIgnorables(b: *Builder, zw: *?ZwOnly, line_start: usize) !void {
        const z = zw.* orelse return;
        zw.* = null;
        for (b.glyphs.items[@min(line_start, b.glyphs.items.len)..]) |g| if (g.flags & ShapedGlyph.SPECIAL == 0) return;
        const f = b.fonts.font(z.face);
        try b.glyphs.append(b.alloc, .{ .face = z.face, .gid = f.glyphIndex(' '), .cluster = z.cluster, .x_advance = 0, .metric = z.metric, .flags = 0, .level = z.level, .item = z.item });
    }

    fn build(b: *Builder, comptime feat: Paragraph.Features, runs: []const Run) !void {
        b.runs = runs;
        const complex = feat.complex;
        // characters left in the current emoji-presentation cluster, and its colour face
        var emoji_left: usize = 0;
        var emoji_face: ?FaceId = null;
        var faces_buf: [max_faces]FaceId = undefined;
        var faces: []FaceId = &.{};
        var cur_run: u32 = 0xffff_ffff;
        var cur_level: u8 = 0;
        var primary_metric: u16 = 0;
        var style: TextStyle = .{};
        // script of the last strong character (Common / Inherited characters take it)
        var cur_script: u8 = 0;
        // the first default-ignorable character dropped since the paragraph start / the last forced
        // break, and where that line's glyphs start (see `lineOfIgnorables`)
        var zw_only: ?ZwOnly = null;
        var line_start: usize = b.glyphs.items.len;
        b.hang = b.opts.white_space != .pre;
        b.base_level = @intFromBool(complex and b.opts.direction == .rtl);
        try b.glyphs.ensureUnusedCapacity(b.alloc, b.chars.len);
        for (b.chars, 0..) |c, ci| {
            if (c.run != cur_run or c.level != cur_level) {
                const join = cur_run < runs.len and c.level == cur_level and c.level & 1 == 0 and
                    !c.obj and sameShapeStyle(style, runs[c.run].style) and
                    runs[cur_run].white_space == runs[c.run].white_space and runs[cur_run].overflow_wrap == runs[c.run].overflow_wrap and
                    b.transparentBoundary(runs, cur_run, c.run);
                if (!join) try b.flush(complex, style);
                if (c.run != cur_run) {
                    if (b.cx and b.buf.g().len == 0) try b.enterRuns(runs, c.run, c.level);
                    cur_run = c.run;
                    style = runs[c.run].style;
                    b.hang = (runs[c.run].white_space orelse b.opts.white_space) != .pre;
                    b.nowrap = !wsWraps(runs[c.run].white_space orelse b.opts.white_space);
                    b.ow = runs[c.run].overflow_wrap orelse b.opts.overflow_wrap;
                    faces = matchStyle(b.fonts, style, &faces_buf);
                    // paragraph features first, then the run's own
                    b.n_feats = 0;
                    for ([_][]const shp.FeatureSetting{ b.opts.features, style.features }) |list| {
                        for (list) |ft| {
                            if (b.n_feats < b.feats.len) {
                                b.feats[b.n_feats] = ft;
                                b.n_feats += 1;
                            }
                        }
                    }
                    if (faces.len > 0) primary_metric = try b.metricFor(c.run, faces[0], style);
                    if (!join) cur_script = 0;
                }
                cur_level = c.level;
                if (c.level != 0) b.any_rtl = true;
                b.item +|= 1;
            }
            if (c.obj) {
                if (!b.cx) continue;
                try b.flush(complex, style);
                const o = runs[c.run].object orelse continue;
                const fl = b.takeBreak(ci);
                try b.special(Special.atomic, o.id, 0, try b.objIndex(o), c.level, fl & ShapedGlyph.BREAK_BEFORE);
                continue;
            }
            if (faces.len == 0) continue; // no fonts registered: nothing to shape
            if (c.cp == hard_break_cp) {
                try b.flush(complex, style);
                try b.lineOfIgnorables(&zw_only, line_start);
                _ = b.takeBreak(ci);
                try b.glyphs.append(b.alloc, .{ .face = faces[0], .gid = 0, .cluster = c.cluster, .x_advance = 0, .metric = primary_metric, .flags = ShapedGlyph.HARD_BREAK, .level = c.level, .item = b.item });
                line_start = b.glyphs.items.len;
                continue;
            }
            const joiner = uni.isShapingControl(c.cp);
            if (c.cp == 0xad and ci > 0 and (b.chars[ci - 1].cp == ' ' or b.chars[ci - 1].cp == '\t') and !b.nowrap) {
                // A soft hyphen right after spaces keeps an invisible glyph of its own: Blink breaks
                // before the space run there (the spaces hang) and after the soft hyphen (hyphenated,
                // the spaces then being content), two places a dropped soft hyphen would merge. A line
                // may then start with it and hold only its hyphen ("aaa" / "‐" / "bbb").
                try b.flush(complex, style);
                const pick = pickFace(b.fonts, faces, ' ');
                const fl = b.takeBreak(ci);
                try b.glyphs.append(b.alloc, .{ .face = pick.face, .gid = pick.gid, .cluster = c.cluster, .x_advance = 0, .metric = primary_metric, .flags = fl, .level = c.level, .item = b.item });
                continue;
            }
            if (uni.isZeroWidth(c.cp)) {
                // (a joiner is shaped, but alone it gives no glyph either)
                if (zw_only == null) zw_only = .{ .face = faces[0], .cluster = c.cluster, .metric = primary_metric, .level = c.level, .item = b.item };
                if (!joiner) continue;
            }
            if (c.cp == '\t') {
                try b.flush(complex, style);
                const pick = pickFace(b.fonts, faces, ' ');
                const f = b.fonts.font(pick.face);
                const sp = scaleAdvance(f.advanceWidth(pick.gid), @as(f64, style.size) * 65536.0 / @as(f64, @floatFromInt(f.units_per_em))) + style.letter_spacing + style.word_spacing;
                const tab_w = style.tab_length orelse sp * @as(f32, @floatFromInt(style.tab_spaces orelse b.opts.tab_size));
                var flags: u8 = ShapedGlyph.TAB | (if (b.hang) ShapedGlyph.SPACE else 0);
                flags |= b.takeBreak(ci);
                try b.glyphs.append(b.alloc, .{ .face = pick.face, .gid = pick.gid, .cluster = c.cluster, .x_advance = @max(tab_w, 0), .tab_min = sp / 2, .metric = primary_metric, .flags = flags, .level = c.level, .item = b.item });
                continue;
            }
            const pending = b.buf.g().len != 0;
            // font: joiners and cluster continuations stay with the face of their base when it
            // can render them; everything else takes the first face that covers it
            var face: FaceId = if (pending) b.seg_face else faces[0];
            var gid: u16 = 0;
            if (feat.color_emoji and emoji_left == 0 and (c.cp >= 0x203c or c.cp == '#' or c.cp == '*' or (c.cp >= '0' and c.cp <= '9') or c.cp == 0xa9 or c.cp == 0xae)) {
                // emoji sequence starting here? (Blink segments emoji-presentation runs and
                // gives them to colour faces first)
                var look: [24]u21 = undefined;
                var nl: usize = 0;
                while (nl < look.len and ci + nl < b.chars.len and b.chars[ci + nl].run == c.run) : (nl += 1) look[nl] = b.chars[ci + nl].cp;
                const cl = color.scanEmoji(look[0..nl]);
                if (cl.len != 0 and cl.emoji_presentation) {
                    emoji_left = cl.len;
                    emoji_face = null;
                    for (faces) |id| {
                        if (!b.fonts.allows(id, c.cp)) continue;
                        const fnt = b.fonts.font(id);
                        if (fnt.glyphIndex(c.cp) != 0 and color.ColorTables.init(fnt).hasColor()) {
                            emoji_face = id;
                            break;
                        }
                    }
                    // an emoji run never shares a segment with the text before it
                    if (pending and emoji_face != null and emoji_face.? != b.seg_face) try b.flush(complex, style);
                }
            }
            var forced = false;
            if (feat.color_emoji and emoji_left != 0) {
                emoji_left -= 1;
                if (emoji_face) |ef| {
                    face = ef;
                    gid = b.fonts.font(ef).glyphIndex(c.cp);
                    b.starter = c.cp;
                    forced = true;
                }
            }
            if (joiner or forced) {
                // never a reason to fall back
            } else {
                // A cluster continuation stays in its base face. Starter selection checks marks
                // ahead and picks a fallback that covers the cluster when one exists; otherwise
                // the base face keeps the missing mark (not a cross-font keycap, e.g. Inter "1" + U+20E3).
                const cont = pending and (if (complex) uni.isContinuation(b.prev_cp, c.cp) else uni.isContinuationSimple(b.prev_cp, c.cp));
                if (cont) {
                    gid = b.fonts.font(b.seg_face).glyphIndex(c.cp);
                } else {
                    face = faces[0];
                    var base_face: ?FaceId = null;
                    var base_gid: u16 = 0;
                    var cluster_face_found = false;
                    for (faces) |id| {
                        if (!b.fonts.allows(id, c.cp)) continue;
                        const candidate = b.fonts.font(id);
                        const candidate_gid = candidate.glyphIndex(c.cp);
                        var st: u21 = 0;
                        const covers_base = candidate_gid != 0 or (complex and c.cp >= 0xc0 and shp.fontCovers(complex, candidate, &st, c.cp));
                        if (!covers_base) continue;
                        if (base_face == null) {
                            base_face = id;
                            base_gid = candidate_gid;
                        }
                        if (coversFollowingMarks(b, complex, id, ci, if (st != 0) st else c.cp)) {
                            face = id;
                            gid = candidate_gid;
                            cluster_face_found = true;
                            break;
                        }
                    }
                    if (!cluster_face_found) if (base_face) |id| {
                        face = id;
                        gid = base_gid;
                    };
                    b.starter = c.cp;
                }
            }
            b.prev_cp = uni.clusterPrev(complex, &b.prev_pict, c.cp);
            var metric = primary_metric;
            if (face != faces[0]) metric = try b.metricFor(c.run, face, style);
            // script: strong characters decide, the rest follow
            var script = cur_script;
            if (!joiner) {
                const s: u8 = if (complex) uni.script(c.cp) else shp.simpleScript(c.cp);
                const strong = if (complex) s > 2 else s != 0;
                if (strong) {
                    script = s;
                    // brackets opened before the run had a script take it now
                    if (complex and cur_script == 0) {
                        for (b.brackets[0..b.n_brackets]) |*e| {
                            if (e.script == 0) e.script = s;
                        }
                    }
                } else if (complex and c.cp < 0x10000) {
                    // Blink's ScriptRunIterator: a closing bracket takes the script of its opener
                    if (uni.bracket(c.cp)) |br| {
                        if (br.open) {
                            if (b.n_brackets == b.brackets.len) {
                                std.mem.copyForwards(BracketRec, b.brackets[0 .. b.brackets.len - 1], b.brackets[1..]);
                                b.n_brackets -= 1;
                            }
                            b.brackets[b.n_brackets] = .{ .close = @intCast(br.pair), .script = cur_script };
                            b.n_brackets += 1;
                        } else {
                            var k = b.n_brackets;
                            while (k > 0) {
                                k -= 1;
                                if (b.brackets[k].close == c.cp) {
                                    if (b.brackets[k].script != 0) script = b.brackets[k].script;
                                    b.n_brackets = k + 1;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            if (pending) {
                if (face != b.seg_face or (metric != b.seg_metric and !sameShapeStyle(runs[b.metrics.items[b.seg_metric].run].style, style))) {
                    try b.flush(complex, style);
                } else if (script != b.seg_script) {
                    // a segment that has seen no strong character yet adopts the script
                    if (b.seg_script == 0) b.seg_script = script else try b.flush(complex, style);
                } else if (b.buf.g().len >= max_segment and !joiner and longSegmentBreak(b.chars[ci - 1].cp, c.cp, b.buf.g().len)) {
                    try b.flush(complex, style);
                }
            }
            cur_script = script;
            if (b.buf.g().len == 0) {
                b.buf.reset(c.level & 1 != 0);
                b.seg_face = face;
                b.seg_metric = metric;
                b.seg_script = script;
                b.seg_level = c.level;
            }
            try b.buf.list.append(b.tmp, .{ .cp = c.cp, .cluster = @intCast(ci), .gid = gid });
        }
        try b.flush(complex, style);
        try b.lineOfIgnorables(&zw_only, line_start);
        if (b.cx) {
            try b.enterRuns(runs, runs.len, b.base_level);
            try b.moveToBox(0, b.base_level);
        }
    }

    /// Paint-only span boundaries do not divide a shaping run. Box edges that occupy
    /// inline space, objects and vertical alignment still form independent segments.
    fn transparentBoundary(b: *const Builder, runs: []const Run, from: u32, to: u32) bool {
        if (to <= from) return false;
        for (runs[from .. to + 1]) |run| if (run.object != null or run.hard_break_after) return false;
        if (!b.cx) return true;
        var a = b.run_box[from];
        var z = b.run_box[to];
        while (a != z) {
            const id = @max(a, z);
            const box = b.boxes[id];
            if (box.start != 0 or box.end != 0 or box.valign != .baseline or box.rel[0] != 0 or box.rel[1] != 0) return false;
            if (a == id) a = box.parent else z = box.parent;
        }
        return true;
    }

    fn sameShapeStyle(a: TextStyle, b: TextStyle) bool {
        if (a.size != b.size or a.weight != b.weight or a.italic != b.italic or a.stretch != b.stretch or
            a.optical_sizing != b.optical_sizing or a.letter_spacing != b.letter_spacing or a.word_spacing != b.word_spacing or
            a.caps != b.caps or a.synth_small_caps != b.synth_small_caps or a.unicode_bidi != b.unicode_bidi or a.rtl != b.rtl or
            a.families.len != b.families.len or a.features.len != b.features.len or a.variations.len != b.variations.len) return false;
        for (a.families, b.families) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        for (a.features, b.features) |x, y| if (!std.meta.eql(x, y)) return false;
        for (a.variations, b.variations) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    /// Prefer a face that covers the whole base-plus-mark cluster. If no face does, retain the
    /// first face that covers the starter so missing-glyph handling keeps its existing behavior.
    fn coversFollowingMarks(b: *Builder, comptime complex: bool, face: FaceId, ci: usize, starter_in: u21) bool {
        const f = b.fonts.font(face);
        var starter = starter_in;
        var prev = b.chars[ci].cp;
        var pict = false;
        prev = uni.clusterPrev(complex, &pict, prev);
        var j = ci + 1;
        while (j < b.chars.len and b.chars[j].run == b.chars[ci].run) : (j += 1) {
            const cp = b.chars[j].cp;
            const continuation = if (complex) uni.isContinuation(prev, cp) else uni.isContinuationSimple(prev, cp);
            if (!continuation) break;
            // Preserve the text-digit keycap behavior: U+20E3 stays with its base face.
            if (uni.isMark(cp) and cp != 0x20e3 and !shp.fontCovers(complex, f, &starter, cp)) return false;
            prev = uni.clusterPrev(complex, &pict, cp);
        }
        return true;
    }

    /// Shapes the pending segment and appends its glyphs: advances, kerning, spacing, flags.
    fn flush(b: *Builder, comptime complex: bool, style: TextStyle) !void {
        if (b.buf.g().len == 0) return;
        if (style.caps != .normal) return b.flushCaps(complex, style);
        return b.shapeOut(complex, style, b.feats[0..b.n_feats], style.size, b.seg_metric);
    }

    const CapsSupport = enum { full, fallback, none };
    const CapsSynth = enum { none, lower, upper, both };
    const CaseRun = enum { upper_needed, same };

    fn hasFeat(comptime complex: bool, f: *const Font, script: u8, comptime t: *const [4]u8) bool {
        return shp.hasGsubFeature(complex, f, script, ot.tag(t));
    }

    /// font-variant-caps on the pending segment: Blink's HarfBuzzShaper::ShapeSegment caps
    /// handling (OpenTypeCapsSupport, SmallCapsIterator). A face with the caps feature gets it as
    /// is; otherwise the text is split into runs of characters that change when uppercased and the
    /// rest, and a run that needs synthesis is uppercased (lowercased for unicase) and shaped at
    /// round(size * 0.7) (Blink SimpleFontData::SmallCapsFontData).
    noinline fn flushCaps(b: *Builder, comptime complex: bool, style: TextStyle) !void {
        const f = b.fonts.font(b.seg_face);
        const sc = b.seg_script;
        var support: CapsSupport = .full;
        var synth: CapsSynth = .none;
        switch (style.caps) {
            .normal => {},
            .small => if (!hasFeat(complex, f, sc, "smcp")) {
                support = .none;
                synth = .lower;
            },
            .all_small => if (!(hasFeat(complex, f, sc, "smcp") and hasFeat(complex, f, sc, "c2sc"))) {
                support = .none;
                synth = .both;
            },
            .petite => if (!hasFeat(complex, f, sc, "pcap")) {
                if (hasFeat(complex, f, sc, "smcp")) {
                    support = .fallback;
                } else {
                    support = .none;
                    synth = .lower;
                }
            },
            .all_petite => if (!(hasFeat(complex, f, sc, "pcap") and hasFeat(complex, f, sc, "c2pc"))) {
                if (hasFeat(complex, f, sc, "smcp") and hasFeat(complex, f, sc, "c2sc")) {
                    support = .fallback;
                } else {
                    support = .none;
                    synth = .both;
                }
            },
            .unicase => if (!hasFeat(complex, f, sc, "unic")) {
                support = if (hasFeat(complex, f, sc, "smcp")) .fallback else .none;
                synth = .upper;
            },
            .titling => if (!hasFeat(complex, f, sc, "titl")) {
                support = .none;
            },
        }
        const split = support != .full and style.caps != .titling and style.synth_small_caps and b.seg_level & 1 == 0;
        if (!split) return b.shapeCaps(complex, style, support, synth, .same, false);
        // split the segment at case changes (combining marks follow their base)
        const saved = try b.tmp.dupe(ot.Glyph, b.buf.list.items);
        defer b.tmp.free(saved);
        const n = saved.len;
        var i: usize = 0;
        while (i < n) {
            var kind: ?CaseRun = null;
            var j = i;
            while (j < n) : (j += 1) {
                const cp = saved[j].cp;
                if (kind != null and uni.isCombining(cp)) continue;
                const k: CaseRun = if (case.changesWhenUppercased(cp)) .upper_needed else .same;
                if (kind == null) {
                    kind = k;
                } else if (k != kind.?) break;
            }
            b.buf.list.clearRetainingCapacity();
            try b.buf.list.appendSlice(b.tmp, saved[i..j]);
            try b.shapeCaps(complex, style, support, synth, kind orelse .same, true);
            i = j;
        }
    }

    /// Shapes the pending buffer as one case run of flushCaps.
    fn shapeCaps(b: *Builder, comptime complex: bool, style: TextStyle, support: CapsSupport, synth: CapsSynth, run_case: CaseRun, allowed: bool) !void {
        // case change (OpenTypeCapsSupport::NeedsCaseChange)
        const to_upper = allowed and support == .none and run_case == .upper_needed and (synth == .lower or synth == .both);
        const to_lower = allowed and support == .fallback and run_case == .same and (synth == .both or synth == .upper);
        if (to_upper or to_lower) {
            const src = try b.tmp.dupe(ot.Glyph, b.buf.list.items);
            defer b.tmp.free(src);
            b.buf.list.clearRetainingCapacity();
            for (src) |gl| {
                var m: [3]u21 = undefined;
                var k: usize = 1;
                if (to_upper) {
                    k = case.upper(gl.cp, &m);
                } else m[0] = case.lower(gl.cp);
                for (m[0..k]) |cp| try b.buf.list.append(b.tmp, .{ .cp = cp, .cluster = gl.cluster, .gid = if (cp == gl.cp) gl.gid else 0 });
            }
        }
        // synthetic font (NeedsSyntheticFont)
        const synthetic = allowed and support == .none and switch (run_case) {
            .upper_needed => synth == .lower or synth == .both,
            .same => synth == .upper or synth == .both,
        };
        // caps features (FontFeatureToUse), before the run's own features
        var fbuf: [36]shp.FeatureSetting = undefined;
        var nf: usize = 0;
        const caps: Caps = switch (support) {
            .full => style.caps,
            .none => .normal,
            .fallback => switch (style.caps) {
                .all_petite => .all_small,
                .petite => .small,
                .unicase => if (run_case == .same) .small else .normal,
                else => .normal,
            },
        };
        const tags: []const *const [4]u8 = switch (caps) {
            .normal => &.{},
            .small => &.{"smcp"},
            .all_small => &.{ "c2sc", "smcp" },
            .petite => &.{"pcap"},
            .all_petite => &.{ "c2pc", "pcap" },
            .unicase => &.{"unic"},
            .titling => &.{"titl"},
        };
        for (tags) |t| {
            fbuf[nf] = .{ .tag = t.*, .value = 1 };
            nf += 1;
        }
        for (b.feats[0..b.n_feats]) |ft| {
            fbuf[nf] = ft;
            nf += 1;
        }
        var size = style.size;
        var metric = b.seg_metric;
        if (synthetic) {
            size = @round(style.size * 0.7);
            var st = style;
            st.size = size;
            const run = if (b.seg_metric < b.metrics.items.len) b.metrics.items[b.seg_metric].run else 0;
            metric = try b.metricFor(run, b.seg_face, st);
        }
        return b.shapeOut(complex, style, fbuf[0..nf], size, metric);
    }

    /// Shapes the pending buffer with features at size and appends its glyphs (spacing from style).
    fn shapeOut(b: *Builder, comptime complex: bool, style: TextStyle, features: []const shp.FeatureSetting, size: f32, metric: u16) !void {
        const f = b.fonts.font(b.seg_face);
        const rtl = b.seg_level & 1 != 0;
        try shp.shapeCached(complex, b.cache, f, &b.buf, .{
            .script = b.seg_script,
            .rtl = rtl,
            .lang = b.opts.lang,
            .spaced = style.letter_spacing != 0,
            .features = features,
        });
        const gs = b.buf.g();
        defer b.buf.list.clearRetainingCapacity();
        try b.glyphs.ensureUnusedCapacity(b.alloc, gs.len);
        const scale = @as(f64, size) * 65536.0 / @as(f64, @floatFromInt(f.units_per_em));
        const hang = b.hang;
        const spacing: f32 = if (complex and shp.isCursiveScript(b.seg_script)) 0 else style.letter_spacing;
        var paint_run: u32 = 0xffff_ffff;
        for (gs, 0..) |g, j| {
            const first = j == 0 or gs[j - 1].cluster != g.cluster;
            const last = j + 1 == gs.len or gs[j + 1].cluster != g.cluster;
            const ci: usize = @min(g.cluster, b.chars.len - 1);
            const c = b.chars[ci];
            if (b.cx) try b.enterRuns(b.runs, c.run, b.seg_level);
            if (paint_run != c.run) {
                if (j != 0) b.item +|= 1;
                paint_run = c.run;
            }
            var paint_style = b.runs[c.run].style;
            paint_style.size = size;
            const paint_metric = if (b.metrics.items[metric].run == c.run) metric else try b.metricFor(c.run, b.seg_face, paint_style);
            var flags: u8 = 0;
            var adv: f32 = scaleAdvance(g.x_adv, scale);
            const kern: f32 = if (g.kern != 0 and g.x_adv != 0) adv - scaleAdvance(g.x_adv - g.kern, scale) else 0;
            // letter-spacing goes after every cluster (on its last glyph; the first one in a
            // right-to-left run, where it is the visually last)
            if (if (rtl) first else last) adv += spacing;
            if (first) {
                if (c.cp == ' ' or c.cp == 0xa0) {
                    adv += style.word_spacing;
                    flags |= ShapedGlyph.WORD_SPACE;
                    if (c.cp == ' ' and hang) flags |= ShapedGlyph.SPACE;
                } else if (c.cp == 0x3000 and hang) {
                    // the ideographic space hangs at the line end like a preserved space, in every
                    // white-space mode that wraps (Blink `IsOtherSpaceSeparator` in `HandleTrailingSpaces`,
                    // takumi line_breaker.rs): "ab\u{3000}cd" too narrow for "ab\u{3000}" breaks after it,
                    // not before it. Other Unicode spaces (U+2003, ...) do not hang in Blink.
                    flags |= ShapedGlyph.SPACE;
                }
                flags |= b.takeBreak(ci);
            } else flags |= ShapedGlyph.NO_SPLIT;
            try b.glyphs.append(b.alloc, .{
                .face = b.seg_face,
                .gid = g.gid,
                .cluster = c.cluster,
                .x_advance = adv,
                .x_offset = if (g.x_off != 0) scaleAdvance(g.x_off, scale) else 0,
                .y_offset = if (g.y_off != 0) scaleAdvance(g.y_off, scale) else 0,
                .kern = kern,
                .metric = paint_metric,
                .flags = flags,
                .level = b.seg_level,
                .item = b.item,
            });
        }
    }
};
