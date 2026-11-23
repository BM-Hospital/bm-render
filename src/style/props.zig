//! Property table (camelCase name -> handler), per-property value parsers and the CSS-wide
//! keyword machinery. Every handler parses the complete value or returns InvalidStyleValue.
const std = @import("std");
const tok = @import("tokenizer.zig");
const values = @import("values.zig");
const colorm = @import("color.zig");
const gradient = @import("gradient.zig");
const c = @import("computed.zig");

const Allocator = std.mem.Allocator;
const Error = tok.Error;
const Token = tok.Token;
const Lexer = tok.Lexer;
const LP = values.LP;
const Env = values.Env;
const S = c.ComputedStyle;
const ColorValue = colorm.ColorValue;

/// Build feature switches (src/config.zig via the root module; everything on in standalone tests).
/// A property of a compiled-out feature is accepted and ignored (its value is not parsed).
const cfg = struct {
    const root = @import("root");
    const on = @hasDecl(root, "bm_config");
    const animation = if (on) root.bm_config.enable_animation else true;
    const effects = if (on) root.bm_config.enable_effects else true;
    const generated = if (on) root.bm_config.enable_generated_content else true;
    const tables = if (on) root.bm_config.enable_tables else true;
    const variable_fonts = if (on) root.bm_config.enable_variable_fonts else true;
    /// paged output: `break-*` / `page-break-*` / `widows` / `orphans`
    const pdf = if (!on) true else if (@hasDecl(root.bm_config, "enable_pdf")) root.bm_config.enable_pdf else false;
};

pub const Prop = enum(u16) {
    WebkitBackdropFilter,
    WebkitBoxDecorationBreak,
    WebkitBoxOrient,
    WebkitClipPath,
    WebkitHyphens,
    WebkitLineClamp,
    WebkitMask,
    WebkitMaskClip,
    WebkitMaskComposite,
    WebkitMaskImage,
    WebkitMaskOrigin,
    WebkitMaskPosition,
    WebkitMaskRepeat,
    WebkitMaskSize,
    WebkitTextFillColor,
    WebkitTextStroke,
    WebkitTextStrokeColor,
    WebkitTextStrokeWidth,
    WebkitUserSelect,
    alignContent,
    alignItems,
    alignSelf,
    animation,
    animationDelay,
    animationDirection,
    animationDuration,
    animationFillMode,
    animationIterationCount,
    animationName,
    animationPlayState,
    animationTimingFunction,
    aspectRatio,
    backdropFilter,
    background,
    backgroundAttachment,
    backgroundBlendMode,
    backgroundClip,
    backgroundColor,
    backgroundImage,
    backgroundOrigin,
    backgroundPosition,
    backgroundPositionX,
    backgroundPositionY,
    backgroundRepeat,
    backgroundSize,
    blockSize,
    border,
    borderBlock,
    borderBlockColor,
    borderBlockEnd,
    borderBlockEndColor,
    borderBlockEndStyle,
    borderBlockEndWidth,
    borderBlockStart,
    borderBlockStartColor,
    borderBlockStartStyle,
    borderBlockStartWidth,
    borderBlockStyle,
    borderBlockWidth,
    borderBottom,
    borderBottomColor,
    borderBottomLeftRadius,
    borderBottomRightRadius,
    borderBottomStyle,
    borderBottomWidth,
    borderCollapse,
    borderColor,
    borderEndEndRadius,
    borderEndStartRadius,
    borderInline,
    borderInlineColor,
    borderInlineEnd,
    borderInlineEndColor,
    borderInlineEndStyle,
    borderInlineEndWidth,
    borderInlineStart,
    borderInlineStartColor,
    borderInlineStartStyle,
    borderInlineStartWidth,
    borderInlineStyle,
    borderInlineWidth,
    borderLeft,
    borderLeftColor,
    borderLeftStyle,
    borderLeftWidth,
    borderRadius,
    borderRight,
    borderRightColor,
    borderRightStyle,
    borderRightWidth,
    borderSpacing,
    borderStartEndRadius,
    borderStartStartRadius,
    borderStyle,
    borderTop,
    borderTopColor,
    borderTopLeftRadius,
    borderTopRightRadius,
    borderTopStyle,
    borderTopWidth,
    borderWidth,
    bottom,
    boxDecorationBreak,
    boxShadow,
    boxSizing,
    breakAfter,
    breakBefore,
    breakInside,
    captionSide,
    clear,
    clipPath,
    color,
    columnGap,
    contain,
    content,
    counterIncrement,
    counterReset,
    counterSet,
    cursor,
    direction,
    display,
    emptyCells,
    filter,
    flex,
    flexBasis,
    flexDirection,
    flexFlow,
    flexGrow,
    flexShrink,
    flexWrap,
    float,
    font,
    fontFamily,
    fontFeatureSettings,
    fontKerning,
    fontOpticalSizing,
    fontSize,
    fontStretch,
    fontStyle,
    fontSynthesis,
    fontSynthesisSmallCaps,
    fontSynthesisStyle,
    fontSynthesisWeight,
    fontVariant,
    fontVariantCaps,
    fontVariantEastAsian,
    fontVariantLigatures,
    fontVariantNumeric,
    fontVariantPosition,
    fontVariationSettings,
    fontWeight,
    gap,
    grid,
    gridArea,
    gridAutoColumns,
    gridAutoFlow,
    gridAutoRows,
    gridColumn,
    gridColumnEnd,
    gridColumnStart,
    gridRow,
    gridRowEnd,
    gridRowStart,
    gridTemplate,
    gridTemplateAreas,
    gridTemplateColumns,
    gridTemplateRows,
    height,
    hyphens,
    imageRendering,
    inlineSize,
    inset,
    insetBlock,
    insetBlockEnd,
    insetBlockStart,
    insetInline,
    insetInlineEnd,
    insetInlineStart,
    isolation,
    justifyContent,
    justifyItems,
    justifySelf,
    left,
    letterSpacing,
    lineBreak,
    lineClamp,
    lineHeight,
    listStyle,
    listStyleImage,
    listStylePosition,
    listStyleType,
    margin,
    marginBlock,
    marginBlockEnd,
    marginBlockStart,
    marginBottom,
    marginInline,
    marginInlineEnd,
    marginInlineStart,
    marginLeft,
    marginRight,
    marginTop,
    mask,
    maskClip,
    maskComposite,
    maskImage,
    maskMode,
    maskOrigin,
    maskPosition,
    maskRepeat,
    maskSize,
    maskType,
    maxBlockSize,
    maxHeight,
    maxInlineSize,
    maxWidth,
    minBlockSize,
    minHeight,
    minInlineSize,
    minWidth,
    mixBlendMode,
    objectFit,
    objectPosition,
    offset,
    offsetAnchor,
    offsetDistance,
    offsetPath,
    offsetPosition,
    offsetRotate,
    opacity,
    order,
    orphans,
    outline,
    outlineColor,
    outlineOffset,
    outlineStyle,
    outlineWidth,
    overflow,
    overflowBlock,
    overflowInline,
    overflowWrap,
    overflowX,
    overflowY,
    padding,
    paddingBlock,
    paddingBlockEnd,
    paddingBlockStart,
    paddingBottom,
    paddingInline,
    paddingInlineEnd,
    paddingInlineStart,
    paddingLeft,
    paddingRight,
    paddingTop,
    pageBreakAfter,
    pageBreakBefore,
    pageBreakInside,
    paintOrder,
    placeContent,
    placeItems,
    placeSelf,
    pointerEvents,
    position,
    right,
    rotate,
    rowGap,
    scale,
    tabSize,
    tableLayout,
    textAlign,
    textAlignLast,
    textCombineUpright,
    textDecoration,
    textDecorationColor,
    textDecorationLine,
    textDecorationSkipInk,
    textDecorationStyle,
    textDecorationThickness,
    textIndent,
    textOrientation,
    textOverflow,
    textShadow,
    textTransform,
    textUnderlineOffset,
    textUnderlinePosition,
    textWrap,
    textWrapMode,
    textWrapStyle,
    top,
    transform,
    transformOrigin,
    transition,
    transitionBehavior,
    transitionDelay,
    transitionDuration,
    transitionProperty,
    transitionTimingFunction,
    translate,
    unicodeBidi,
    userSelect,
    verticalAlign,
    visibility,
    whiteSpace,
    whiteSpaceCollapse,
    widows,
    width,
    willChange,
    wordBreak,
    wordSpacing,
    wordWrap,
    writingMode,
    zIndex,
};

const tag_names = @typeInfo(Prop).@"enum".field_names;
const n_props = tag_names.len;
/// All property names in one string (no separators) + start offsets: compact binary-search table.
const prop_pack: []const u8 = blk: {
    var out: []const u8 = "";
    for (tag_names) |n| out = out ++ n;
    break :blk out;
};
const prop_off: [n_props + 1]u16 = blk: {
    var o: [n_props + 1]u16 = undefined;
    var k: usize = 0;
    for (tag_names, 0..) |n, i| {
        o[i] = k;
        k += n.len;
    }
    o[n_props] = k;
    break :blk o;
};

comptime {
    // The enum is declared in byte order so lookup can binary-search the tag names directly.
    @setEvalBranchQuota(100000);
    for (1..n_props) |i| {
        if (std.mem.order(u8, tag_names[i - 1], tag_names[i]) != .lt) @compileError("Prop enum not sorted: " ++ tag_names[i]);
    }
}

/// camelCase property name -> Prop (case-sensitive, like takumi).
pub fn lookup(name: []const u8) ?Prop {
    var lo: usize = 0;
    var hi: usize = n_props;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, prop_pack[prop_off[mid]..prop_off[mid + 1]], name)) {
            .eq => return @fromBackingInt(@intCast(mid)),
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

// ------------------------------------------------------------------ longhand metadata
const FieldRef = struct { name: []const u8, idx: i8 = -1 };

fn fr(comptime n: []const u8) FieldRef {
    return .{ .name = n };
}
fn fi(comptime n: []const u8, comptime i: i8) FieldRef {
    return .{ .name = n, .idx = i };
}

/// Fields of ComputedStyle written by each property (used for inherit/initial/unset).
fn fieldsOf(comptime p: Prop) []const FieldRef {
    return switch (p) {
        .WebkitBoxOrient => &.{}, // validated, not stored
        .WebkitLineClamp, .lineClamp => &.{ fr("line_clamp"), fr("block_ellipsis"), fr("block_ellipsis_string") },
        .WebkitTextStroke => &.{ fr("webkit_text_stroke_width"), fr("webkit_text_stroke_color") },
        .WebkitTextStrokeColor => &.{fr("webkit_text_stroke_color")},
        .WebkitTextStrokeWidth => &.{fr("webkit_text_stroke_width")},
        .alignContent => &.{ fr("align_content"), fi("align_safe", 2) },
        .alignItems => &.{ fr("align_items"), fi("align_safe", 0) },
        .alignSelf => &.{ fr("align_self"), fi("align_safe", 1) },
        .aspectRatio => &.{fr("aspect_ratio")},
        .background => &.{ fr("background_color"), fr("background_image"), fr("background_size"), fr("background_position"), fr("background_repeat"), fr("background_clip"), fr("background_origin") },
        .backgroundClip => &.{fr("background_clip")},
        .backgroundColor => &.{fr("background_color")},
        .backgroundImage => &.{fr("background_image")},
        .backgroundOrigin => &.{fr("background_origin")},
        .backgroundPosition => &.{fr("background_position")},
        .backgroundRepeat => &.{fr("background_repeat")},
        .backgroundSize => &.{fr("background_size")},
        .border => &.{ fr("border_width"), fr("border_style"), fr("border_color") },
        .borderTop => &.{ fi("border_width", 0), fi("border_style", 0), fi("border_color", 0) },
        .borderRight => &.{ fi("border_width", 1), fi("border_style", 1), fi("border_color", 1) },
        .borderBottom => &.{ fi("border_width", 2), fi("border_style", 2), fi("border_color", 2) },
        .borderLeft => &.{ fi("border_width", 3), fi("border_style", 3), fi("border_color", 3) },
        .borderColor => &.{fr("border_color")},
        .borderStyle => &.{fr("border_style")},
        .borderWidth => &.{fr("border_width")},
        .borderTopColor => &.{fi("border_color", 0)},
        .borderRightColor => &.{fi("border_color", 1)},
        .borderBottomColor => &.{fi("border_color", 2)},
        .borderLeftColor => &.{fi("border_color", 3)},
        .borderTopStyle => &.{fi("border_style", 0)},
        .borderRightStyle => &.{fi("border_style", 1)},
        .borderBottomStyle => &.{fi("border_style", 2)},
        .borderLeftStyle => &.{fi("border_style", 3)},
        .borderTopWidth => &.{fi("border_width", 0)},
        .borderRightWidth => &.{fi("border_width", 1)},
        .borderBottomWidth => &.{fi("border_width", 2)},
        .borderLeftWidth => &.{fi("border_width", 3)},
        .borderRadius => &.{fr("border_radius")},
        .borderTopLeftRadius => &.{fi("border_radius", 0)},
        .borderTopRightRadius => &.{fi("border_radius", 1)},
        .borderBottomRightRadius => &.{fi("border_radius", 2)},
        .borderBottomLeftRadius => &.{fi("border_radius", 3)},
        .top => &.{fi("inset", 0)},
        .right => &.{fi("inset", 1)},
        .bottom => &.{fi("inset", 2)},
        .left => &.{fi("inset", 3)},
        .inset => &.{fr("inset")},
        .boxShadow => &.{fr("box_shadow")},
        .boxSizing => &.{fr("box_sizing")},
        .color => &.{fr("color")},
        .columnGap => &.{fr("column_gap")},
        .rowGap => &.{fr("row_gap")},
        .gap => &.{ fr("row_gap"), fr("column_gap") },
        .direction => &.{fr("direction")},
        .display => &.{fr("display")},
        .filter => &.{fr("filter")},
        .flex => &.{ fr("flex_grow"), fr("flex_shrink"), fr("flex_basis") },
        .flexBasis => &.{fr("flex_basis")},
        .flexDirection => &.{fr("flex_direction")},
        .flexFlow => &.{ fr("flex_direction"), fr("flex_wrap") },
        .flexGrow => &.{fr("flex_grow")},
        .flexShrink => &.{fr("flex_shrink")},
        .flexWrap => &.{fr("flex_wrap")},
        .font => &.{ fr("font_style"), fr("font_weight"), fr("font_size"), fr("line_height"), fr("font_family"), fr("font_stretch"), fr("font_variant_ligatures"), fr("font_variant_numeric"), fr("font_variant_caps"), fr("font_variant_position"), fr("font_variant_east_asian"), fr("font_kerning"), fr("font_optical_sizing"), fr("font_feature_settings"), fr("font_variation_settings") },
        .fontFamily => &.{fr("font_family")},
        .fontSize => &.{fr("font_size")},
        .fontStyle => &.{fr("font_style")},
        .fontWeight => &.{fr("font_weight")},
        .gridArea => &.{ fr("grid_row_start"), fr("grid_column_start"), fr("grid_row_end"), fr("grid_column_end"), fr("grid_line_names") },
        .gridAutoColumns => &.{fr("grid_auto_columns")},
        .gridAutoRows => &.{fr("grid_auto_rows")},
        .gridAutoFlow => &.{fr("grid_auto_flow")},
        .gridColumn => &.{ fr("grid_column_start"), fr("grid_column_end"), fi("grid_line_names", 1), fi("grid_line_names", 3) },
        .gridColumnEnd => &.{ fr("grid_column_end"), fi("grid_line_names", 3) },
        .gridColumnStart => &.{ fr("grid_column_start"), fi("grid_line_names", 1) },
        .gridRow => &.{ fr("grid_row_start"), fr("grid_row_end"), fi("grid_line_names", 0), fi("grid_line_names", 2) },
        .gridRowEnd => &.{ fr("grid_row_end"), fi("grid_line_names", 2) },
        .gridRowStart => &.{ fr("grid_row_start"), fi("grid_line_names", 0) },
        .gridTemplateColumns => &.{fr("grid_template_columns")},
        .gridTemplateRows => &.{fr("grid_template_rows")},
        .width => &.{fr("width")},
        .height => &.{fr("height")},
        .minWidth => &.{fr("min_width")},
        .minHeight => &.{fr("min_height")},
        .maxWidth => &.{fr("max_width")},
        .maxHeight => &.{fr("max_height")},
        .imageRendering => &.{fr("image_rendering")},
        .justifyContent => &.{ fr("justify_content"), fi("align_safe", 3) },
        .justifyItems => &.{ fr("justify_items"), fi("align_safe", 4) },
        .justifySelf => &.{ fr("justify_self"), fi("align_safe", 5) },
        .letterSpacing => &.{fr("letter_spacing")},
        .lineHeight => &.{fr("line_height")},
        .margin => &.{fr("margin")},
        .marginTop => &.{fi("margin", 0)},
        .marginRight => &.{fi("margin", 1)},
        .marginBottom => &.{fi("margin", 2)},
        .marginLeft => &.{fi("margin", 3)},
        .padding => &.{fr("padding")},
        .paddingTop => &.{fi("padding", 0)},
        .paddingRight => &.{fi("padding", 1)},
        .paddingBottom => &.{fi("padding", 2)},
        .paddingLeft => &.{fi("padding", 3)},
        .mixBlendMode => &.{fr("mix_blend_mode")},
        .objectFit => &.{fr("object_fit")},
        .objectPosition => &.{fr("object_position")},
        .offset => &.{ fr("offset_path"), fr("offset_distance"), fr("offset_anchor"), fr("offset_position"), fr("offset_rotate") },
        .offsetPath => &.{fr("offset_path")},
        .offsetDistance => &.{fr("offset_distance")},
        .offsetAnchor => &.{fr("offset_anchor")},
        .offsetPosition => &.{fr("offset_position")},
        .offsetRotate => &.{fr("offset_rotate")},
        .opacity => &.{fr("opacity")},
        .order => &.{fr("order")},
        .outline => &.{ fr("outline_width"), fr("outline_style"), fr("outline_color") },
        .outlineColor => &.{fr("outline_color")},
        .outlineOffset => &.{fr("outline_offset")},
        .outlineStyle => &.{fr("outline_style")},
        .outlineWidth => &.{fr("outline_width")},
        .overflow => &.{ fr("overflow_x"), fr("overflow_y") },
        .overflowX => &.{fr("overflow_x")},
        .overflowY => &.{fr("overflow_y")},
        .overflowWrap, .wordWrap => &.{fr("overflow_wrap")},
        .placeContent => &.{ fr("align_content"), fr("justify_content"), fi("align_safe", 2), fi("align_safe", 3) },
        .placeItems => &.{ fr("align_items"), fr("justify_items"), fi("align_safe", 0), fi("align_safe", 4) },
        .placeSelf => &.{ fr("align_self"), fr("justify_self"), fi("align_safe", 1), fi("align_safe", 5) },
        .position => &.{fr("position")},
        .rotate => &.{fr("rotate")},
        .scale => &.{fr("scale")},
        .translate => &.{fr("translate")},
        .tabSize => &.{fr("tab_size")},
        .textAlign => &.{fr("text_align")},
        .textDecoration => &.{ fr("text_decoration_line"), fr("text_decoration_style"), fr("text_decoration_color"), fr("text_decoration_thickness"), fr("text_decoration_from_font") },
        .textDecorationColor => &.{fr("text_decoration_color")},
        .textDecorationLine => &.{fr("text_decoration_line")},
        .textDecorationStyle => &.{fr("text_decoration_style")},
        .textDecorationThickness => &.{ fr("text_decoration_thickness"), fr("text_decoration_from_font") },
        .textIndent => &.{ fr("text_indent"), fr("text_indent_flags") },
        .textOverflow => &.{ fr("text_overflow"), fr("text_overflow_string") },
        .textShadow => &.{fr("text_shadow")},
        .textTransform => &.{fr("text_transform")},
        .textWrap => &.{ fr("text_wrap_mode"), fr("text_wrap_style") },
        .textWrapMode => &.{fr("text_wrap_mode")},
        .textWrapStyle => &.{fr("text_wrap_style")},
        .transform => &.{fr("transform")},
        .transformOrigin => &.{fr("transform_origin")},
        .visibility => &.{fr("visibility")},
        .whiteSpace => &.{ fr("white_space_collapse"), fr("text_wrap_mode") },
        .whiteSpaceCollapse => &.{fr("white_space_collapse")},
        .wordBreak => &.{fr("word_break")},
        .wordSpacing => &.{fr("word_spacing")},
        .zIndex => &.{fr("z_index")},
        // logical properties: fields come from the physical mapping (physicalProps), none here
        .marginInline, .marginInlineStart, .marginInlineEnd, .marginBlock, .marginBlockStart, .marginBlockEnd, .paddingInline, .paddingInlineStart, .paddingInlineEnd, .paddingBlock, .paddingBlockStart, .paddingBlockEnd, .insetInline, .insetInlineStart, .insetInlineEnd, .insetBlock, .insetBlockStart, .insetBlockEnd, .inlineSize, .blockSize, .minInlineSize, .minBlockSize, .maxInlineSize, .maxBlockSize, .borderInline, .borderInlineStart, .borderInlineEnd, .borderInlineWidth, .borderInlineStyle, .borderInlineColor, .borderInlineStartWidth, .borderInlineStartStyle, .borderInlineStartColor, .borderInlineEndWidth, .borderInlineEndStyle, .borderInlineEndColor, .borderBlock, .borderBlockStart, .borderBlockEnd, .borderBlockWidth, .borderBlockStyle, .borderBlockColor, .borderBlockStartWidth, .borderBlockStartStyle, .borderBlockStartColor, .borderBlockEndWidth, .borderBlockEndStyle, .borderBlockEndColor, .borderStartStartRadius, .borderStartEndRadius, .borderEndStartRadius, .borderEndEndRadius => &.{},
        // accepted and ignored
        .backgroundAttachment, .willChange, .pointerEvents, .cursor, .userSelect, .WebkitUserSelect, .transitionBehavior, .maskComposite, .WebkitMaskComposite => &.{},
        .overflowInline => &.{fr("overflow_x")},
        .overflowBlock => &.{fr("overflow_y")},
        .gridTemplateAreas => &.{fr("grid_template_areas")},
        .gridTemplate => &.{ fr("grid_template_rows"), fr("grid_template_columns"), fr("grid_template_areas") },
        .grid => &.{ fr("grid_template_rows"), fr("grid_template_columns"), fr("grid_template_areas"), fr("grid_auto_rows"), fr("grid_auto_columns"), fr("grid_auto_flow") },
        .backgroundPositionX, .backgroundPositionY => &.{fr("background_position")},
        .backgroundBlendMode => &.{fr("background_blend_mode")},
        .float => &.{fr("float")},
        .clear => &.{fr("clear")},
        .tableLayout => &.{fr("table_layout")},
        .borderCollapse => &.{fr("border_collapse")},
        .borderSpacing => &.{fr("border_spacing")},
        .captionSide => &.{fr("caption_side")},
        .emptyCells => &.{fr("empty_cells")},
        .boxDecorationBreak, .WebkitBoxDecorationBreak => &.{fr("box_decoration_break")},
        .breakBefore, .pageBreakBefore => &.{fr("break_before")},
        .breakAfter, .pageBreakAfter => &.{fr("break_after")},
        .breakInside, .pageBreakInside => &.{fr("break_inside")},
        .widows => &.{fr("widows")},
        .orphans => &.{fr("orphans")},
        .listStyle => &.{ fr("list_style_type"), fr("list_style_position"), fr("list_style_image") },
        .listStyleType => &.{fr("list_style_type")},
        .listStylePosition => &.{fr("list_style_position")},
        .listStyleImage => &.{fr("list_style_image")},
        .content => &.{fr("content")},
        .counterReset => &.{fr("counter_reset")},
        .counterIncrement => &.{fr("counter_increment")},
        .counterSet => &.{fr("counter_set")},
        .contain => &.{fr("contain")},
        .isolation => &.{fr("isolation")},
        .verticalAlign => &.{fr("vertical_align")},
        .unicodeBidi => &.{fr("unicode_bidi")},
        .writingMode => &.{fr("writing_mode")},
        .textOrientation => &.{fr("text_orientation")},
        .textCombineUpright => &.{fr("text_combine_upright")},
        .backdropFilter, .WebkitBackdropFilter => &.{fr("backdrop_filter")},
        .clipPath, .WebkitClipPath => &.{fr("clip_path")},
        .mask, .WebkitMask => &.{ fr("mask_image"), fr("mask_size"), fr("mask_position"), fr("mask_repeat"), fr("mask_clip"), fr("mask_origin"), fr("mask_mode") },
        .maskImage, .WebkitMaskImage => &.{fr("mask_image")},
        .maskSize, .WebkitMaskSize => &.{fr("mask_size")},
        .maskPosition, .WebkitMaskPosition => &.{fr("mask_position")},
        .maskRepeat, .WebkitMaskRepeat => &.{fr("mask_repeat")},
        .maskClip, .WebkitMaskClip => &.{fr("mask_clip")},
        .maskOrigin, .WebkitMaskOrigin => &.{fr("mask_origin")},
        .maskMode => &.{fr("mask_mode")},
        .maskType => &.{fr("mask_type")},
        .textDecorationSkipInk => &.{fr("text_decoration_skip_ink")},
        .textUnderlineOffset => &.{fr("text_underline_offset")},
        .textUnderlinePosition => &.{fr("text_underline_position")},
        .WebkitTextFillColor => &.{fr("webkit_text_fill_color")},
        .paintOrder => &.{fr("paint_order")},
        .textAlignLast => &.{fr("text_align_last")},
        .hyphens, .WebkitHyphens => &.{fr("hyphens")},
        .lineBreak => &.{fr("line_break")},
        .fontStretch => &.{fr("font_stretch")},
        .fontVariationSettings => &.{fr("font_variation_settings")},
        .fontFeatureSettings => &.{fr("font_feature_settings")},
        .fontVariant => &.{ fr("font_variant_ligatures"), fr("font_variant_numeric"), fr("font_variant_caps"), fr("font_variant_position"), fr("font_variant_east_asian") },
        .fontVariantLigatures => &.{fr("font_variant_ligatures")},
        .fontVariantNumeric => &.{fr("font_variant_numeric")},
        .fontVariantCaps => &.{fr("font_variant_caps")},
        .fontVariantPosition => &.{fr("font_variant_position")},
        .fontVariantEastAsian => &.{fr("font_variant_east_asian")},
        .fontKerning => &.{fr("font_kerning")},
        .fontOpticalSizing => &.{fr("font_optical_sizing")},
        .fontSynthesis, .fontSynthesisWeight, .fontSynthesisStyle, .fontSynthesisSmallCaps => &.{fr("font_synthesis")},
        .animation => &.{ fr("animation_name"), fr("animation_duration"), fr("animation_timing_function"), fr("animation_delay"), fr("animation_iteration_count"), fr("animation_direction"), fr("animation_fill_mode"), fr("animation_play_state") },
        .animationName => &.{fr("animation_name")},
        .animationDuration => &.{fr("animation_duration")},
        .animationTimingFunction => &.{fr("animation_timing_function")},
        .animationDelay => &.{fr("animation_delay")},
        .animationIterationCount => &.{fr("animation_iteration_count")},
        .animationDirection => &.{fr("animation_direction")},
        .animationFillMode => &.{fr("animation_fill_mode")},
        .animationPlayState => &.{fr("animation_play_state")},
        .transition => &.{ fr("transition_property"), fr("transition_duration"), fr("transition_timing_function"), fr("transition_delay") },
        .transitionProperty => &.{fr("transition_property")},
        .transitionDuration => &.{fr("transition_duration")},
        .transitionTimingFunction => &.{fr("transition_timing_function")},
        .transitionDelay => &.{fr("transition_delay")},
    };
}

pub fn isInherited(p: Prop) bool {
    return switch (p) {
        .WebkitTextStroke, .WebkitTextStrokeColor, .WebkitTextStrokeWidth, .color, .direction, .font, .fontFamily, .fontSize, .fontStyle, .fontWeight, .imageRendering, .letterSpacing, .lineHeight, .overflowWrap, .wordWrap, .tabSize, .textAlign, .textIndent, .textShadow, .textTransform, .textWrap, .textWrapMode, .textWrapStyle, .visibility, .whiteSpace, .whiteSpaceCollapse, .wordBreak, .wordSpacing, .borderCollapse, .borderSpacing, .captionSide, .emptyCells, .listStyle, .listStyleType, .listStylePosition, .listStyleImage, .writingMode, .textOrientation, .textCombineUpright, .textAlignLast, .hyphens, .WebkitHyphens, .lineBreak, .textDecorationSkipInk, .textUnderlineOffset, .textUnderlinePosition, .WebkitTextFillColor, .paintOrder, .fontStretch, .fontVariationSettings, .fontFeatureSettings, .fontVariant, .fontVariantLigatures, .fontVariantNumeric, .fontVariantCaps, .fontVariantPosition, .fontVariantEastAsian, .fontKerning, .fontOpticalSizing, .fontSynthesis, .fontSynthesisWeight, .fontSynthesisStyle, .fontSynthesisSmallCaps, .widows, .orphans => true,
        else => false,
    };
}

/// Byte range of a ComputedStyle field (or array element) — CSS-wide keywords copy these ranges.
const Range = struct { off: u16, len: u16 };

fn rangeOf(comptime f: FieldRef) Range {
    const off = @offsetOf(S, f.name);
    const T = @FieldType(S, f.name);
    if (f.idx < 0) return .{ .off = off, .len = @sizeOf(T) };
    const E = @typeInfo(T).array.child;
    return .{ .off = off + @as(usize, @intCast(f.idx)) * @sizeOf(E), .len = @sizeOf(E) };
}

const n_ranges = blk: {
    @setEvalBranchQuota(200000);
    var total: usize = 0;
    for (0..n_props) |i| total += fieldsOf(@fromBackingInt(@intCast(i))).len;
    break :blk total;
};
const range_list: [n_ranges]Range = blk: {
    @setEvalBranchQuota(200000);
    var ranges: [n_ranges]Range = undefined;
    var k: usize = 0;
    for (0..n_props) |i| {
        for (fieldsOf(@fromBackingInt(@intCast(i)))) |f| {
            ranges[k] = rangeOf(f);
            k += 1;
        }
    }
    break :blk ranges;
};
const range_starts: [n_props + 1]u16 = blk: {
    @setEvalBranchQuota(200000);
    var starts: [n_props + 1]u16 = undefined;
    var k: usize = 0;
    for (0..n_props) |i| {
        starts[i] = k;
        k += fieldsOf(@fromBackingInt(@intCast(i))).len;
    }
    starts[n_props] = k;
    break :blk starts;
};

/// Copies every field `p` writes from `src` into `dst`.
pub fn copyProp(p: Prop, dst: *S, src: *const S) void {
    const i = @backingInt(p);
    const db = std.mem.asBytes(dst);
    const sb = std.mem.asBytes(src);
    for (range_list[range_starts[i]..range_starts[i + 1]]) |r| {
        @memcpy(db[r.off..][0..r.len], sb[r.off..][0..r.len]);
    }
}

/// Copies all inherited properties from parent.
pub fn inheritAll(dst: *S, parent: *const S) void {
    for (0..n_props) |i| {
        const p: Prop = @fromBackingInt(@intCast(i));
        if (isInherited(p)) copyProp(p, dst, parent);
    }
    dst.custom_props = parent.custom_props;
}

// ------------------------------------------------------------------ parsing context
pub const Cx = struct {
    a: Allocator,
    s: *S,
    /// em base for lengths (this element's font size once known)
    env: Env,
    parent_fs: f32,
    parent_weight: u16,
    parent_color: colorm.Color,
    /// PDF builds only (`void` otherwise): the style is computed for a frame a PDF is drawn from
    /// (`style.Context.paged`). When false, the paged-output properties and values (`break-*`,
    /// `widows`, `orphans`, `background-clip: border-area`) behave exactly as in a build without
    /// the PDF feature, so an image render is the same on every build.
    paged: Paged = paged_off,
};

/// Whether the paged-output properties exist in this build.
pub const pdf_build = cfg.pdf;
pub const Paged = if (cfg.pdf) bool else void;
pub const paged_off: Paged = if (cfg.pdf) false else {};

/// Paged-output properties: ignored (as in a build without the PDF feature) unless `cx.paged`.
pub fn pagedOnly(p: Prop) bool {
    return switch (p) {
        .breakBefore, .breakAfter, .breakInside, .pageBreakBefore, .pageBreakAfter, .pageBreakInside, .widows, .orphans => true,
        else => false,
    };
}

const bad = error.InvalidStyleValue;

fn need(comptime T: type, v: ?T) Error!T {
    return v orelse bad;
}

fn ieq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn kwNext(comptime E: type, l: *Lexer) Error!E {
    return tok.kw(E, l.next()) orelse bad;
}

fn isEnd(t: Token) bool {
    return t.kind == .eof or t.kind == .comma;
}

fn lp(cx: *Cx, t: Token) Error!LP {
    return need(LP, values.lengthPct(t, &cx.env));
}

fn len(cx: *Cx, t: Token) Error!f32 {
    return need(f32, values.length(t, &cx.env));
}

fn colorOf(t: Token) Error!ColorValue {
    return need(ColorValue, colorm.fromToken(t));
}

/// `thin | medium | thick | <length>` (>= 0).
fn lineWidth(cx: *Cx, t: Token) Error!?f32 {
    if (t.kind == .ident) {
        const d = cx.env.dpr;
        if (ieq(t.text, "thin")) return 1 * d;
        if (ieq(t.text, "medium")) return 3 * d;
        if (ieq(t.text, "thick")) return 5 * d;
        // takumi's line width is a <length>, whose `auto` resolves to 0
        if (ieq(t.text, "auto")) return 0;
        return null;
    }
    // (a percentage resolves against 0 in takumi: `to_border_px(sizing, 0.0)`)
    if (t.kind == .percentage) return if (t.num < 0) bad else 0;
    const v = (values.length(t, &cx.env)) orelse return null;
    if (v < 0) return bad;
    return v;
}

/// Expands 1-4 values into [top, right, bottom, left].
fn expand4(comptime T: type, v: []const T) Error![4]T {
    return switch (v.len) {
        1 => .{ v[0], v[0], v[0], v[0] },
        2 => .{ v[0], v[1], v[0], v[1] },
        3 => .{ v[0], v[1], v[2], v[1] },
        4 => .{ v[0], v[1], v[2], v[3] },
        else => bad,
    };
}

/// Reads 1-4 value tokens (stopping at end or '/') and expands them to [top, right, bottom, left].
fn fourTokens(l: *Lexer) Error![4]Token {
    var buf: [4]Token = undefined;
    var n: usize = 0;
    while (!l.atEnd() and l.peek().kind != .slash) {
        if (n == 4) return bad;
        buf[n] = l.next();
        n += 1;
    }
    return expand4(Token, buf[0..n]);
}
// ------------------------------------------------------------------ simple property parsers
const AMask = u32;
fn amask(comptime tags: []const c.Align) AMask {
    var m: AMask = 0;
    for (tags) |t| m |= @as(AMask, 1) << @as(u5, @intCast(@backingInt(t)));
    return m;
}
// The keyword sets are takumi's (`declare_box_alignment_enum_impl!`), narrower than CSS: no `left` /
// `right` / `legacy` / `first baseline` / `last baseline`, no `auto` for the *-self properties, and
// `safe` / `unsafe` only before a positional keyword. `flow-start` / `flow-end` (content properties) are the
// start / end of the flow: stored as flex-start / flex-end.
const positional_mask = amask(&.{ .start, .end, .flex_start, .flex_end, .center, .self_start, .self_end });
const content_mask = amask(&.{ .normal, .stretch, .start, .end, .flex_start, .flex_end, .center, .space_between, .space_around, .space_evenly });
const items_mask = amask(&.{ .normal, .stretch, .start, .end, .flex_start, .flex_end, .center, .baseline, .self_start, .self_end });
const self_mask = items_mask;

/// Indexes of `ComputedStyle.align_safe`.
const safe_align_items = 0;
const safe_align_self = 1;
const safe_align_content = 2;
const safe_justify_content = 3;
const safe_justify_items = 4;
const safe_justify_self = 5;

const Aligned = struct { v: c.Align, safe: bool };

fn parseAlign(l: *Lexer, mask: AMask, content: bool) Error!Aligned {
    var t = l.next();
    var safe = false;
    if (t.isIdent("safe") or t.isIdent("unsafe")) {
        safe = t.isIdent("safe");
        t = l.next();
    }
    if (t.kind != .ident) return bad;
    var v: c.Align = undefined;
    if (content and t.isIdent("flow-start")) {
        v = .flex_start;
    } else if (content and t.isIdent("flow-end")) {
        v = .flex_end;
    } else v = tok.kw(c.Align, t) orelse return bad;
    const bit = @as(AMask, 1) << @as(u5, @intCast(@backingInt(v)));
    if (mask & bit == 0) return bad;
    // (`unsafe` is skipped before any keyword; `safe` needs a positional one)
    if (safe and positional_mask & bit == 0) return bad;
    return .{ .v = v, .safe = safe };
}

fn setAlign(s: *S, field: *c.Align, comptime idx: usize, a: Aligned) void {
    field.* = a.v;
    s.align_safe[idx] = a.safe;
}

/// A plain negative number/dimension/percentage token (not calc()).
fn isNegative(t: Token) bool {
    return (t.kind == .number or t.kind == .dimension or t.kind == .percentage) and t.num < 0;
}

fn paddingValue(cx: *Cx, t: Token) Error!LP {
    if (t.isIdent("auto")) return .{}; // takumi accepts padding:auto
    if (isNegative(t)) return bad;
    return lp(cx, t);
}

fn parseNonNegNumber(t: Token) Error!f32 {
    const v = try need(f32, values.number(t));
    return @max(v, 0);
}

fn parseFlexBasis(cx: *Cx, t: Token) Error!?c.FlexBasis {
    if (t.kind == .ident) {
        if (t.isIdent("content")) return .content;
        const sz = (values.size(t, &cx.env)) orelse return null;
        return switch (sz) {
            .auto => if (t.isIdent("auto")) .auto else null,
            .min_content => .min_content,
            .max_content => .max_content,
            .fit_content => .fit_content,
            .stretch, .fit_content_lp => null,
            .lp => null,
        };
    }
    return if (values.lengthPct(t, &cx.env)) |v| .{ .lp = v } else null;
}

fn parseFlex(cx: *Cx, l: *Lexer) Error!void {
    const s = cx.s;
    const f = l.peek();
    if (f.isIdent("none")) {
        _ = l.next();
        s.flex_grow = 0;
        s.flex_shrink = 0;
        s.flex_basis = .auto;
        return;
    }
    if (f.isIdent("auto")) {
        _ = l.next();
        s.flex_grow = 1;
        s.flex_shrink = 1;
        s.flex_basis = .auto;
        return;
    }
    var grow: ?f32 = null;
    var shrink: ?f32 = null;
    var basis: ?c.FlexBasis = null;
    while (!l.atEnd()) {
        const t = l.next();
        if (grow == null and (t.kind == .number or (t.kind == .function and (values.number(t)) != null))) {
            grow = try parseNonNegNumber(t);
            const n = l.peek();
            if (n.kind == .number) {
                _ = l.next();
                shrink = try parseNonNegNumber(n);
            }
            continue;
        }
        if (basis == null) {
            if (try parseFlexBasis(cx, t)) |b| {
                basis = b;
                continue;
            }
        }
        return bad;
    }
    if (grow == null and basis == null) return bad;
    s.flex_grow = grow orelse 1;
    s.flex_shrink = shrink orelse 1;
    s.flex_basis = basis orelse .{ .lp = .{ .pct = 0 } };
}

fn parseAspect(l: *Lexer) Error!?f32 {
    var ratio: ?f32 = null;
    var saw_auto = false;
    while (!l.atEnd()) {
        const t = l.next();
        if (t.isIdent("auto") and !saw_auto) {
            saw_auto = true;
            continue;
        }
        if (ratio != null) return bad;
        const w = try parseNonNegNumber(t);
        var h: f32 = 1;
        if (l.peek().kind == .slash) {
            _ = l.next();
            h = try parseNonNegNumber(l.next());
        }
        ratio = if (w <= 0 or h <= 0) 0 else w / h;
    }
    if (ratio == null and !saw_auto) return bad;
    if (ratio) |r| if (r == 0) return null; // degenerate ratio behaves as auto
    return ratio;
}

// ------------------------------------------------------------------ grid
fn trackBreadth(cx: *Cx, t: Token) Error!?c.TrackSize {
    if (t.kind == .ident) {
        if (t.isIdent("auto")) return .auto;
        if (t.isIdent("min-content")) return .min_content;
        if (t.isIdent("max-content")) return .max_content;
        return null;
    }
    if (t.kind == .dimension and ieq(t.text, "fr")) {
        if (t.num < 0) return bad;
        return .{ .fr = t.num };
    }
    return if (values.lengthPct(t, &cx.env)) |v| .{ .lp = v } else null;
}

fn trackSize(cx: *Cx, t: Token) Error!?c.Track {
    if (t.isFunc("minmax")) {
        var l = Lexer.init(t.args);
        const mn = try need(c.TrackSize, try trackBreadth(cx, l.next()));
        if (mn == .fr) return bad;
        if (l.next().kind != .comma) return bad;
        const mx = try need(c.TrackSize, try trackBreadth(cx, l.next()));
        if (!l.atEnd()) return bad;
        return .{ .min = mn, .max = mx };
    }
    if (t.isFunc("fit-content")) {
        var l = Lexer.init(t.args);
        const v = try lp(cx, l.next());
        if (!l.atEnd()) return bad;
        return .{ .min = .auto, .max = .{ .fit_content = v } };
    }
    const b = (try trackBreadth(cx, t)) orelse return null;
    if (b == .fr) return .{ .min = .auto, .max = b };
    return .{ .min = b, .max = b };
}

const max_tracks = 10000;

const NameList = tok.List(c.LineName);

fn isReservedLineName(t: Token) bool {
    return t.isIdent("span") or t.isIdent("auto");
}

/// `[a b]` -> names at grid line `line` (relative to the repeat group when `rel`).
fn addNames(cx: *Cx, names: *NameList, args: []const u8, line: usize, rel: bool) Error!void {
    var bl = Lexer.init(args);
    while (!bl.atEnd()) {
        const t = bl.next();
        if (t.kind != .ident or isReservedLineName(t)) return bad;
        if (names.items.len >= max_tracks) return bad;
        try names.append(cx.a, .{ .name = t.text, .line = @intCast(@min(line, 65535)), .in_repeat = rel });
    }
}

/// Track list (stops at a top-level '/'). `rel_start` != null: inside `repeat(auto-*)`, names are
/// stored relative to that track index.
fn trackList(cx: *Cx, l: *Lexer, out: *tok.List(c.Track), tmpl: ?*c.GridTemplate, nested: bool, names: *NameList, rel_start: ?usize) Error!void {
    while (!l.atEnd()) {
        if (!nested and l.peek().kind == .slash) break;
        const t = l.next();
        if (t.kind == .bracket) {
            const line = if (rel_start) |r| out.items.len - r else out.items.len;
            try addNames(cx, names, t.args, line, rel_start != null);
            continue;
        }
        if (t.isFunc("repeat")) {
            if (nested) return bad;
            var rl = Lexer.init(t.args);
            const cnt_t = rl.next();
            var mode: c.AutoRepeat = .none;
            var count: u32 = 0;
            if (cnt_t.isIdent("auto-fill")) {
                mode = .fill;
            } else if (cnt_t.isIdent("auto-fit")) {
                mode = .fit;
            } else {
                const n = try need(i32, values.integer(cnt_t));
                if (n < 1) return bad;
                count = @intCast(@min(n, max_tracks));
            }
            if (rl.next().kind != .comma) return bad;
            const start = out.items.len;
            const names0 = names.items.len;
            try trackList(cx, &rl, out, null, true, names, if (mode != .none) start else null);
            const group = out.items.len - start;
            if (group == 0) return bad;
            if (mode != .none) {
                const tp = tmpl orelse return bad;
                if (tp.auto_repeat != .none) return bad;
                tp.auto_repeat = mode;
                tp.auto_repeat_start = @intCast(start);
                tp.auto_repeat_len = @intCast(group);
            } else {
                if (group * count > max_tracks) return bad;
                const names1 = names.items.len;
                var k: u32 = 1;
                while (k < count) : (k += 1) {
                    try out.appendSlice(cx.a, out.items[start .. start + group]);
                    var q = names0;
                    while (q < names1) : (q += 1) {
                        if (names.items.len >= max_tracks) return bad;
                        var nm = names.items[q];
                        nm.line = @intCast(@min(@as(usize, nm.line) + k * group, 65535));
                        try names.append(cx.a, nm);
                    }
                }
            }
        } else {
            const tr = try need(c.Track, try trackSize(cx, t));
            try out.append(cx.a, tr);
        }
        if (out.items.len > max_tracks) return bad;
    }
}

fn parseTemplate(cx: *Cx, l: *Lexer) Error!c.GridTemplate {
    var g: c.GridTemplate = .{};
    if (l.peek().isIdent("none")) {
        _ = l.next();
        return g;
    }
    var out: tok.List(c.Track) = .{};
    var names: NameList = .{};
    try trackList(cx, l, &out, &g, false, &names, null);
    if (out.items.len == 0) return bad;
    g.tracks = out.items;
    g.line_names = names.items;
    return g;
}

fn parseAutoTracks(cx: *Cx, l: *Lexer) Error![]const c.Track {
    var out: tok.List(c.Track) = .{};
    while (!l.atEnd()) {
        if (l.peek().kind == .slash) break;
        if (out.items.len >= max_tracks) return bad;
        try out.append(cx.a, try need(c.Track, try trackSize(cx, l.next())));
    }
    if (out.items.len == 0) return bad;
    return out.items;
}

const LineSpec = struct { line: c.GridLine = .auto, ref: c.GridLineRef = .{}, ident_only: bool = false };

/// One grid line as takumi parses it (`GridPlacement::from_css`), which is narrower than CSS:
/// `auto | span <integer> | span <custom-ident> | <custom-ident> | <number>`.
///  * `<integer> <custom-ident>` and `span <integer> <custom-ident>` (any order) are rejected
///  * `span` must come first; `span n` with n < 1 is `span 1`
///  * a number is truncated to an integer and wrapped to i16; 0 is kept (`GridLine.line` = 0)
fn gridLine(l: *Lexer) Error!LineSpec {
    const t = l.next();
    if (t.kind == .ident) {
        if (t.isIdent("auto")) return .{};
        if (t.isIdent("span")) {
            const u = l.peek();
            if (u.kind == .ident) {
                _ = l.next();
                return .{ .ref = .{ .name = u.text, .n = 1, .span = true } };
            }
            const v = try need(i32, values.integer(u));
            _ = l.next();
            return .{ .line = .{ .span = @intCast(std.math.clamp(v, 1, 65535)) } };
        }
        return .{ .ref = .{ .name = t.text, .n = 1 }, .ident_only = true };
    }
    if (t.kind != .number or !std.math.isFinite(t.num)) return bad;
    const iv: i32 = @intFromFloat(std.math.clamp(@trunc(t.num), -2147483648.0, 2147483520.0));
    const w: i16 = @truncate(iv);
    return .{ .line = .{ .line = w } };
}

/// `<line> [/ <line>]*` up to `max` parts; `got` = number written.
fn gridLines(l: *Lexer, comptime max: usize, got: *usize) Error![max]LineSpec {
    var out: [max]LineSpec = @splat(.{});
    var n: usize = 0;
    while (true) {
        if (n == max) return bad;
        out[n] = try gridLine(l);
        n += 1;
        const t = l.next();
        if (t.kind == .eof) break;
        if (t.kind != .slash) return bad;
    }
    got.* = n;
    return out;
}

/// grid-area: omitted lines copy a lone custom-ident (CSS Grid §8.4), else auto.
fn identOr(s: LineSpec) LineSpec {
    return if (s.ident_only) s else .{};
}

fn setLine(s: *S, idx: usize, v: LineSpec) void {
    s.grid_line_names[idx] = v.ref;
    switch (idx) {
        0 => s.grid_row_start = v.line,
        1 => s.grid_column_start = v.line,
        2 => s.grid_row_end = v.line,
        else => s.grid_column_end = v.line,
    }
}

/// grid-template-areas strings -> named rectangles.
fn parseAreas(cx: *Cx, l: *Lexer) Error!c.GridAreas {
    if (l.peek().isIdent("none")) {
        _ = l.next();
        return .{};
    }
    var cells: tok.List(u16) = .{}; // per cell: area index + 1, 0 = null cell
    var areas: tok.List(c.GridArea) = .{};
    var rows: usize = 0;
    var cols: usize = 0;
    while (!l.atEnd()) {
        const p = l.peek();
        if (p.kind != .string) break;
        _ = l.next();
        const n = try areaRow(cx, p.text, &cells, &areas);
        if (n == 0) return bad;
        if (rows == 0) cols = n else if (n != cols) return bad;
        rows += 1;
        if (rows * cols > max_tracks) return bad;
    }
    if (rows == 0) return bad;
    var g: c.GridAreas = .{ .rows = @intCast(rows), .cols = @intCast(cols), .areas = areas.items };
    try finishAreas(&g, cells.items);
    return g;
}

fn areaRow(cx: *Cx, s: []const u8, cells: *tok.List(u16), areas: *tok.List(c.GridArea)) Error!usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 12) {
            i += 1;
            continue;
        }
        if (ch == '.') {
            while (i < s.len and s[i] == '.') i += 1;
            try cells.append(cx.a, 0);
        } else if (tok.isNameChar(ch)) {
            const b = i;
            while (i < s.len and tok.isNameChar(s[i])) i += 1;
            const name = s[b..i];
            var idx: usize = 0;
            while (idx < areas.items.len and !std.mem.eql(u8, areas.items[idx].name, name)) idx += 1;
            if (idx == areas.items.len) {
                if (idx >= 4096) return bad;
                try areas.append(cx.a, .{ .name = name, .row_start = 0, .row_end = 0, .col_start = 0, .col_end = 0 });
            }
            try cells.append(cx.a, @intCast(idx + 1));
        } else return bad;
        n += 1;
        if (cells.items.len > max_tracks) return bad;
    }
    return n;
}

/// `grid-template`: none | <rows> / <cols> | [<names>? <string> <track-size>? <names>?]+ [/ <cols>]?
fn parseGridTemplate(cx: *Cx, l: *Lexer) Error!void {
    const s = cx.s;
    if (l.peek().isIdent("none")) {
        _ = l.next();
        s.grid_template_rows = .{};
        s.grid_template_columns = .{};
        s.grid_template_areas = .{};
        return;
    }
    // areas form?
    var probe = l.*;
    var has_string = false;
    while (!probe.atEnd()) {
        const t = probe.next();
        if (t.kind == .slash) break;
        if (t.kind == .string) has_string = true;
    }
    if (!has_string) {
        const rows = try parseTemplate(cx, l);
        if (l.next().kind != .slash) return bad;
        const colsv = try parseTemplate(cx, l);
        s.grid_template_rows = rows;
        s.grid_template_columns = colsv;
        s.grid_template_areas = .{};
        return;
    }
    var tracks: tok.List(c.Track) = .{};
    var names: NameList = .{};
    var cells: tok.List(u16) = .{};
    var areas: tok.List(c.GridArea) = .{};
    var rows: usize = 0;
    var cols: usize = 0;
    while (!l.atEnd()) {
        const t = l.peek();
        if (t.kind == .slash) break;
        _ = l.next();
        if (t.kind == .bracket) {
            try addNames(cx, &names, t.args, tracks.items.len, false);
            continue;
        }
        if (t.kind != .string) return bad;
        const n = try areaRow(cx, t.text, &cells, &areas);
        if (n == 0) return bad;
        if (rows == 0) cols = n else if (n != cols) return bad;
        rows += 1;
        if (rows * cols > max_tracks) return bad;
        var tr: c.Track = .{ .min = .auto, .max = .auto };
        const nx = l.peek();
        if (nx.kind != .eof and nx.kind != .slash and nx.kind != .string and nx.kind != .bracket) {
            _ = l.next();
            tr = try need(c.Track, try trackSize(cx, nx));
        }
        try tracks.append(cx.a, tr);
    }
    var colsv: c.GridTemplate = .{};
    if (l.peek().kind == .slash) {
        _ = l.next();
        colsv = try parseTemplate(cx, l);
        if (colsv.auto_repeat != .none) return bad;
    }
    var tmp: c.GridAreas = .{ .rows = @intCast(rows), .cols = @intCast(cols), .areas = areas.items };
    try finishAreas(&tmp, cells.items);
    s.grid_template_rows = .{ .tracks = tracks.items, .line_names = names.items };
    s.grid_template_columns = colsv;
    s.grid_template_areas = tmp;
}

fn finishAreas(g: *c.GridAreas, cells: []const u16) Error!void {
    const cols: usize = g.cols;
    if (cols == 0) return bad;
    const areas: []c.GridArea = @constCast(g.areas);
    for (areas, 0..) |*ar, ai| {
        var r0: usize = std.math.maxInt(usize);
        var r1: usize = 0;
        var c0: usize = cols;
        var c1: usize = 0;
        var count: usize = 0;
        for (cells, 0..) |v, k| {
            if (v != ai + 1) continue;
            r0 = @min(r0, k / cols);
            r1 = @max(r1, k / cols + 1);
            c0 = @min(c0, k % cols);
            c1 = @max(c1, k % cols + 1);
            count += 1;
        }
        if (count == 0 or count != (r1 - r0) * (c1 - c0)) return bad;
        ar.* = .{ .name = ar.name, .row_start = @intCast(r0), .row_end = @intCast(r1), .col_start = @intCast(c0), .col_end = @intCast(c1) };
    }
}

/// `grid`: <grid-template> | <rows> / auto-flow && dense? <auto-cols>? | auto-flow && dense? <auto-rows>? / <cols>
fn parseGrid(cx: *Cx, l: *Lexer) Error!void {
    const s = cx.s;
    var probe = l.*;
    var side: u8 = 0; // 1 = auto-flow before '/', 2 = after
    var after_slash = false;
    while (!probe.atEnd()) {
        const t = probe.next();
        if (t.kind == .slash) after_slash = true;
        if (t.isIdent("auto-flow")) side = if (after_slash) 2 else 1;
    }
    s.grid_auto_rows = &.{};
    s.grid_auto_columns = &.{};
    s.grid_auto_flow = .{};
    if (side == 0) return parseGridTemplate(cx, l);
    var flow: c.GridAutoFlow = .{ .column = side == 2 };
    if (side == 1) {
        try autoFlowKw(l, &flow);
        if (l.peek().kind != .slash) s.grid_auto_rows = try parseAutoTracks(cx, l);
        if (l.next().kind != .slash) return bad;
        s.grid_template_columns = try parseTemplate(cx, l);
        s.grid_template_rows = .{};
    } else {
        s.grid_template_rows = try parseTemplate(cx, l);
        if (l.next().kind != .slash) return bad;
        try autoFlowKw(l, &flow);
        if (!l.atEnd()) s.grid_auto_columns = try parseAutoTracks(cx, l);
        s.grid_template_columns = .{};
    }
    s.grid_template_areas = .{};
    s.grid_auto_flow = flow;
}

fn autoFlowKw(l: *Lexer, flow: *c.GridAutoFlow) Error!void {
    var seen = false;
    while (true) {
        const t = l.peek();
        if (t.isIdent("auto-flow") and !seen) {
            seen = true;
        } else if (t.isIdent("dense") and !flow.dense) {
            flow.dense = true;
        } else break;
        _ = l.next();
    }
    if (!seen) return bad;
}

// ------------------------------------------------------------------ borders / backgrounds
const BorderParts = struct { w: f32, st: c.BorderStyle, col: ColorValue };

fn borderParts(cx: *Cx, l: *Lexer) Error!BorderParts {
    var w: ?f32 = null;
    var st: ?c.BorderStyle = null;
    var col: ?ColorValue = null;
    var n: usize = 0;
    while (!l.atEnd()) {
        const t = l.next();
        n += 1;
        // takumi's `Border::from_css`: each token is tried as width, style, colour in that order, and a
        // repeated component replaces the earlier one (`auto` is a width: 0)
        if (try lineWidth(cx, t)) |v| {
            w = v;
            continue;
        }
        if (tok.kw(c.BorderStyle, t)) |v| {
            st = v;
            continue;
        }
        if (colorm.fromToken(t)) |v| {
            col = v;
            continue;
        }
        return bad;
    }
    if (n == 0) return bad;
    return .{ .w = w orelse 3 * cx.env.dpr, .st = st orelse .none, .col = col orelse .current };
}

fn radiusPair(cx: *Cx, l: *Lexer) Error![2]LP {
    const x = try lp(cx, l.next());
    const y = if (l.atEnd()) x else try lp(cx, l.next());
    return .{ x, y };
}

fn parseBorderRadius(cx: *Cx, l: *Lexer) Error![4][2]LP {
    const ht = try fourTokens(l);
    var vt = ht;
    if (l.peek().kind == .slash) {
        _ = l.next();
        vt = try fourTokens(l);
    }
    var out: [4][2]LP = undefined;
    for (0..4) |i| {
        out[i] = .{ try lp(cx, ht[i]), try lp(cx, vt[i]) };
    }
    return out;
}

fn bgSizeItem(cx: *Cx, l: *Lexer) Error!c.BgSize {
    const t = l.next();
    if (t.isIdent("cover")) return .cover;
    if (t.isIdent("contain")) return .contain;
    const a = try need(c.LengthAuto, values.lengthAuto(t, &cx.env));
    var b: c.LengthAuto = .auto;
    const p = l.peek();
    if (!isEnd(p)) {
        if (values.lengthAuto(p, &cx.env)) |v| {
            _ = l.next();
            b = v;
        }
    }
    return .{ .size = .{ a, b } };
}

fn repeatKw(t: Token) ?c.BgRepeat {
    return tok.kw(c.BgRepeat, t);
}

fn bgRepeatItem(l: *Lexer) Error!?[2]c.BgRepeat {
    const t = l.peek();
    if (t.isIdent("repeat-x")) {
        _ = l.next();
        return .{ .repeat, .no_repeat };
    }
    if (t.isIdent("repeat-y")) {
        _ = l.next();
        return .{ .no_repeat, .repeat };
    }
    const a = repeatKw(t) orelse return null;
    _ = l.next();
    if (repeatKw(l.peek())) |b| {
        _ = l.next();
        return .{ a, b };
    }
    return .{ a, a };
}

fn bgBox(cx: *const Cx, t: Token, allow_text: bool) ?c.BgBox {
    const b = tok.kw(c.BgBox, t) orelse return null;
    if (b == .text and !allow_text) return null;
    // (`border-area`, PDF build only and only for a frame a PDF is drawn from, is a `background-clip`
    // value, as `text`)
    if (comptime @hasField(c.BgBox, "border_area")) if (b == .border_area and (!allow_text or !cx.paged)) return null;
    return b;
}

const ItemKind = enum { size, position, repeat, clip, origin, image };

/// Comma-separated list of one background component.
fn bgList(comptime T: type, comptime kind: ItemKind, cx: *Cx, l: *Lexer) Error![]const T {
    var out: tok.List(T) = .{};
    while (true) {
        const item: T = switch (kind) {
            .size => try bgSizeItem(cx, l),
            .position => try need([2]LP, values.position(l, &cx.env, 4)),
            .repeat => try need([2]c.BgRepeat, try bgRepeatItem(l)),
            .clip => bgBox(cx, l.next(), true) orelse return bad,
            .origin => bgBox(cx, l.next(), false) orelse return bad,
            .image => try need(c.Image, try gradient.image(cx.a, l.next(), &cx.env)),
        };
        try out.append(cx.a, item);
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (sep.kind != .comma) return bad;
        if (out.items.len > 1024) return bad;
    }
    return out.items;
}

fn isPosStart(t: Token, env: *const Env) bool {
    return switch (t.kind) {
        .ident => tok.kw(values.PosKw, t) != null,
        .number, .percentage => true,
        .dimension => values.lengthUnit(t.text, env) != null,
        .function => values.isMathFn(t),
        else => false,
    };
}

/// `background` (mask = false) or `mask` / `-webkit-mask` (mask = true) layer lists.
fn parseBackground(cx: *Cx, l: *Lexer, mask: bool) Error!void {
    var modes: tok.List(c.MaskMode) = .{};
    var images: tok.List(c.Image) = .{};
    var sizes: tok.List(c.BgSize) = .{};
    var poss: tok.List([2]LP) = .{};
    var reps: tok.List([2]c.BgRepeat) = .{};
    var clips: tok.List(c.BgBox) = .{};
    var origins: tok.List(c.BgBox) = .{};
    var bg_color: ColorValue = .{ .rgba = colorm.Color.transparent };
    var color_seen = false;
    while (true) {
        var img: ?c.Image = null;
        var pos: ?[2]LP = null;
        var sz: ?c.BgSize = null;
        var rep: ?[2]c.BgRepeat = null;
        var boxes: [2]c.BgBox = undefined;
        var nbox: usize = 0;
        var attach = false;
        var col: ?ColorValue = null;
        var mode: ?c.MaskMode = null;
        var nitems: usize = 0;
        while (true) {
            const t = l.peek();
            if (isEnd(t)) break;
            nitems += 1;
            if (pos == null and isPosStart(t, &cx.env)) {
                pos = try need([2]LP, values.position(l, &cx.env, 4));
                if (l.peek().kind == .slash) {
                    _ = l.next();
                    sz = try bgSizeItem(cx, l);
                }
                continue;
            }
            if (rep == null) {
                if (try bgRepeatItem(l)) |r| {
                    rep = r;
                    continue;
                }
            }
            _ = l.next();
            if (img == null) {
                if (try gradient.image(cx.a, t, &cx.env)) |im| {
                    img = im;
                    continue;
                }
            }
            const kw_attach = if (mask) "add\x00subtract\x00intersect\x00exclude" else "scroll\x00fixed\x00local";
            if (!attach and t.kind == .ident and tok.matchPacked(t.text, kw_attach) != null) {
                attach = true; // attachment (bg) / compositing operator (mask): accepted, ignored
                continue;
            }
            if (nbox < 2) {
                if (if (mask) maskBox(t) else bgBox(cx, t, true)) |b| {
                    boxes[nbox] = b;
                    nbox += 1;
                    continue;
                }
            }
            if (mask) {
                if (mode == null) if (tok.kw(c.MaskMode, t)) |m| {
                    mode = m;
                    continue;
                };
                return bad;
            }
            if (col == null) {
                if (colorm.fromToken(t)) |v| {
                    col = v;
                    continue;
                }
            }
            return bad;
        }
        if (nitems == 0) return bad;
        try images.append(cx.a, img orelse .none);
        try sizes.append(cx.a, sz orelse c.default_bg_size[0]);
        try poss.append(cx.a, pos orelse c.zero2);
        try reps.append(cx.a, rep orelse c.default_bg_repeat[0]);
        var origin: c.BgBox = if (mask) .border_box else .padding_box;
        var clip: c.BgBox = .border_box;
        try modes.append(cx.a, mode orelse .match_source);
        if (nbox == 1) {
            if (boxes[0] == .text) clip = .text else {
                origin = boxes[0];
                clip = boxes[0];
            }
        } else if (nbox == 2) {
            if (boxes[0] == .text) return bad;
            origin = boxes[0];
            clip = boxes[1];
        }
        try origins.append(cx.a, origin);
        try clips.append(cx.a, clip);
        if (col) |v| {
            bg_color = v;
            color_seen = true;
        }
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (images.items.len > 1024) return bad;
    }
    const s = cx.s;
    if (mask) {
        s.mask_image = images.items;
        s.mask_size = sizes.items;
        s.mask_position = poss.items;
        s.mask_repeat = reps.items;
        s.mask_clip = clips.items;
        s.mask_origin = origins.items;
        s.mask_mode = modes.items;
        return;
    }
    s.background_color = bg_color;
    s.background_image = images.items;
    s.background_size = sizes.items;
    s.background_position = poss.items;
    s.background_repeat = reps.items;
    s.background_clip = clips.items;
    s.background_origin = origins.items;
}

// ------------------------------------------------------------------ effects
fn parseShadows(cx: *Cx, l: *Lexer, box: bool) Error![]const c.Shadow {
    if (l.peek().isIdent("none")) {
        _ = l.next();
        return &.{};
    }
    var out: tok.List(c.Shadow) = .{};
    while (true) {
        try out.append(cx.a, try shadowItem(cx, l, box));
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (sep.kind != .comma) return bad;
        if (out.items.len > 1024) return bad;
    }
    return out.items;
}

fn shadowItem(cx: *Cx, l: *Lexer, box: bool) Error!c.Shadow {
    var sh: c.Shadow = .{};
    var inset = false;
    var col: ?ColorValue = null;
    var nlen: usize = 0;
    const max_len: usize = if (box) 4 else 3;
    while (true) {
        const t = l.peek();
        if (isEnd(t)) break;
        _ = l.next();
        if (box and !inset and t.isIdent("inset")) {
            inset = true;
            continue;
        }
        if (nlen == 0) {
            if (values.length(t, &cx.env)) |v0| {
                var lens: [4]f32 = .{ v0, 0, 0, 0 };
                nlen = 1;
                while (nlen < max_len) {
                    const p = l.peek();
                    if (isEnd(p)) break;
                    const v = (values.length(p, &cx.env)) orelse break;
                    _ = l.next();
                    lens[nlen] = v;
                    nlen += 1;
                }
                if (nlen < 2) return bad;
                lens[2] = @max(lens[2], 0);
                sh.x = lens[0];
                sh.y = lens[1];
                sh.blur = lens[2];
                sh.spread = lens[3];
                continue;
            }
        }
        if (col == null) {
            if (colorm.fromToken(t)) |v| {
                col = v;
                continue;
            }
        }
        return bad;
    }
    if (nlen == 0) return bad;
    sh.inset = inset;
    sh.color = col orelse .current;
    return sh;
}

fn filterAmount(t: Token, default: f32, clamp1: bool) Error!f32 {
    if (t.kind == .eof) return default;
    const v = try need(f32, values.numberOrPct(t));
    if (v < 0) return bad;
    return if (clamp1) @min(v, 1) else v;
}

fn parseFilter(cx: *Cx, l: *Lexer) Error![]const c.Filter {
    if (l.peek().isIdent("none")) {
        _ = l.next();
        return &.{};
    }
    var out: tok.List(c.Filter) = .{};
    while (!l.atEnd()) {
        const t = l.next();
        if (t.kind != .function) return bad;
        var al = Lexer.init(t.args);
        const n = t.text;
        if (ieq(n, "url")) {
            // This renderer has no SVG filter rasterizer (Takumi's PDF build has the same
            // limitation). Treat the URL reference as an identity filter, but keep parsing
            // later CSS filter functions in the list instead of dropping the whole declaration.
            if (al.next().kind == .eof or !al.atEnd()) return bad;
            continue;
        }
        const f: c.Filter = blk: {
            if (ieq(n, "drop-shadow")) {
                const sh = try shadowItem(cx, &al, false);
                break :blk .{ .drop_shadow = sh };
            }
            const a = al.next();
            if (ieq(n, "blur")) {
                const v: f32 = if (a.kind == .eof) 0 else try len(cx, a);
                break :blk .{ .blur = @max(v, 0) };
            }
            if (ieq(n, "hue-rotate")) break :blk .{ .hue_rotate = if (a.kind == .eof) 0 else try need(f32, values.angle(a, false)) };
            if (ieq(n, "brightness")) break :blk .{ .brightness = try filterAmount(a, 1, false) };
            if (ieq(n, "contrast")) break :blk .{ .contrast = try filterAmount(a, 1, false) };
            if (ieq(n, "saturate")) break :blk .{ .saturate = try filterAmount(a, 1, false) };
            if (ieq(n, "grayscale")) break :blk .{ .grayscale = try filterAmount(a, 1, true) };
            if (ieq(n, "invert")) break :blk .{ .invert = try filterAmount(a, 1, true) };
            if (ieq(n, "opacity")) break :blk .{ .opacity = try filterAmount(a, 1, true) };
            if (ieq(n, "sepia")) break :blk .{ .sepia = try filterAmount(a, 1, true) };
            return bad;
        };
        if (!al.atEnd()) return bad;
        try out.append(cx.a, f);
        if (out.items.len > 256) return bad;
    }
    // A URL reference can be the only filter when its SVG filter resource is unavailable.
    // In that case the CSS filter list is an identity operation, not an invalid declaration.
    return out.items;
}

/// Reads up to `max` comma-separated argument tokens of a function.
fn fnArgs(args: []const u8, out: []Token) Error!usize {
    var l = Lexer.init(args);
    var n: usize = 0;
    if (l.atEnd()) return 0;
    while (true) {
        if (n == out.len) return bad;
        const t = l.next();
        if (isEnd(t)) return bad;
        out[n] = t;
        n += 1;
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (sep.kind != .comma) return bad;
    }
    return n;
}

fn angleArg(t: Token) Error!f32 {
    return need(f32, values.angle(t, true));
}

const transform_fns = "translate\x00translatex\x00translatey\x00scale\x00scalex\x00scaley\x00rotate\x00rotatez\x00skew\x00skewx\x00skewy\x00matrix";
/// per function: min args, max args
const transform_arity = [_][2]u8{ .{ 1, 2 }, .{ 1, 1 }, .{ 1, 1 }, .{ 1, 2 }, .{ 1, 1 }, .{ 1, 1 }, .{ 1, 1 }, .{ 1, 1 }, .{ 1, 2 }, .{ 1, 1 }, .{ 1, 1 }, .{ 6, 6 } };

fn parseTransform(cx: *Cx, l: *Lexer) Error![]const c.TransformOp {
    if (l.peek().isIdent("none")) {
        _ = l.next();
        return &.{};
    }
    var out: tok.List(c.TransformOp) = .{};
    while (!l.atEnd()) {
        const t = l.next();
        if (t.kind != .function) return bad;
        const fi_ = tok.matchPacked(t.text, transform_fns) orelse return bad;
        var a: [6]Token = undefined;
        const n = try fnArgs(t.args, &a);
        if (n < transform_arity[fi_][0] or n > transform_arity[fi_][1]) return bad;
        const op: c.TransformOp = switch (fi_) {
            0...2 => blk: {
                var v: [2]LP = .{ .{}, .{} };
                for (a[0..n], 0..) |x, i| v[i] = try lp(cx, x);
                if (fi_ == 2) {
                    v[1] = v[0];
                    v[0] = .{};
                }
                break :blk .{ .translate = v };
            },
            3...5 => blk: {
                var v: [2]f32 = .{ 1, 1 };
                for (a[0..n], 0..) |x, i| v[i] = values.numberOrPct(x) orelse return bad;
                if (fi_ == 3 and n == 1) v[1] = v[0];
                if (fi_ == 5) {
                    v[1] = v[0];
                    v[0] = 1;
                }
                break :blk .{ .scale = v };
            },
            6, 7 => .{ .rotate = try angleArg(a[0]) },
            8...10 => blk: {
                var v: [2]f32 = .{ 0, 0 };
                for (a[0..n], 0..) |x, i| v[i] = try angleArg(x);
                if (fi_ == 10) {
                    v[1] = v[0];
                    v[0] = 0;
                }
                break :blk .{ .skew = v };
            },
            else => blk: {
                var m: [6]f32 = undefined;
                for (0..6) |i| m[i] = values.number(a[i]) orelse return bad;
                m[4] *= cx.env.dpr;
                m[5] *= cx.env.dpr;
                break :blk .{ .matrix = m };
            },
        };
        try out.append(cx.a, op);
        if (out.items.len > 256) return bad;
    }
    if (out.items.len == 0) return bad;
    return out.items;
}

// ------------------------------------------------------------------ fonts / text
const font_size_kw = [_]struct { []const u8, f32 }{
    .{ "xx-small", 9 }, .{ "x-small", 10 }, .{ "small", 13 },    .{ "medium", 16 },
    .{ "large", 18 },   .{ "x-large", 24 }, .{ "xx-large", 32 }, .{ "xxx-large", 48 },
};

/// font-size value: lengths/% relative to the PARENT font size. Clamped to [0, 1e6] device px
/// (takumi accepts negative sizes; nested `larger` must not overflow).
fn fontSizeValue(cx: *Cx, t: Token) Error!?f32 {
    const v = (try fontSizeRaw(cx, t)) orelse return null;
    return std.math.clamp(v, 0, 1.0e6);
}

fn fontSizeRaw(cx: *Cx, t: Token) Error!?f32 {
    if (t.kind == .ident) {
        for (font_size_kw) |e| if (std.ascii.eqlIgnoreCase(t.text, e[0])) return e[1] * cx.env.dpr;
        if (t.isIdent("smaller")) return cx.parent_fs / 1.2;
        if (t.isIdent("larger")) return cx.parent_fs * 1.2;
        return null;
    }
    var env = cx.env;
    env.em = cx.parent_fs;
    const v = (values.lengthPct(t, &env)) orelse return null;
    const px = v.resolve(cx.parent_fs);
    return @max(px, 0);
}

fn weightValue(cx: *Cx, t: Token) Error!?u16 {
    if (t.kind == .ident) {
        if (t.isIdent("normal")) return 400;
        if (t.isIdent("bold")) return 700;
        const p = cx.parent_weight;
        if (t.isIdent("bolder")) return if (p < 350) 400 else if (p < 550) 700 else if (p < 900) 900 else p;
        if (t.isIdent("lighter")) return if (p < 100) p else if (p < 550) 100 else if (p < 750) 400 else 700;
        return null;
    }
    const v = (values.number(t)) orelse return null;
    if (!(v >= 1 and v <= 1000)) return bad;
    return @intFromFloat(@round(v));
}

fn lineHeightValue(cx: *Cx, t: Token) Error!c.LineHeight {
    if (t.isIdent("normal")) return .normal;
    if (t.kind == .number or (t.kind == .function and !(t.isFunc("min") or t.isFunc("max") or t.isFunc("clamp")))) {
        if (values.number(t)) |v| {
            return .{ .number = @max(v, 0) };
        }
    }
    const v = try lp(cx, t);
    return .{ .px = @max(v.resolve(cx.s.font_size), 0) };
}

fn spacingValue(cx: *Cx, t: Token) Error!f32 {
    if (t.isIdent("normal")) return 0;
    const v = try lp(cx, t);
    return v.resolve(cx.s.font_size);
}

fn parseFamilies(cx: *Cx, l: *Lexer) Error![]const []const u8 {
    var out: tok.List([]const u8) = .{};
    while (true) {
        const t = l.next();
        if (t.kind == .string) {
            try out.append(cx.a, t.text);
        } else if (t.kind == .ident) {
            if (t.isIdent("inherit") or t.isIdent("initial") or t.isIdent("unset") or t.isIdent("default")) return bad;
            const base = @intFromPtr(l.s.ptr);
            const first_off = @intFromPtr(t.text.ptr) - base;
            var last_end = first_off + t.text.len;
            var simple = true;
            while (l.peek().kind == .ident) {
                const n = l.next();
                const off = @intFromPtr(n.text.ptr) - base;
                if (off != last_end + 1 or l.s[last_end] != ' ') simple = false;
                last_end = off + n.text.len;
            }
            const span = l.s[first_off..last_end];
            if (simple) {
                try out.append(cx.a, span);
            } else {
                // re-join with single spaces
                var buf: tok.List(u8) = .{};
                var sub = Lexer.init(span);
                while (!sub.atEnd()) {
                    const p = sub.next();
                    if (buf.items.len > 0) try buf.append(cx.a, ' ');
                    try buf.appendSlice(cx.a, p.text);
                }
                try out.append(cx.a, buf.items);
            }
        } else return bad;
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (sep.kind != .comma) return bad;
        if (out.items.len > 256) return bad;
    }
    return out.items;
}

const stretch_kw = "ultra-condensed\x00extra-condensed\x00condensed\x00semi-condensed\x00semi-expanded\x00expanded\x00extra-expanded\x00ultra-expanded";

fn parseFontShorthand(cx: *Cx, l: *Lexer) Error!void {
    const s = cx.s;
    var style: ?c.FontStyle = null;
    var weight: ?u16 = null;
    var variant = false;
    var stretch: ?f32 = null;
    var pre: usize = 0;
    var size_t: Token = undefined;
    while (true) {
        const t = l.next();
        if (t.kind == .eof) return bad;
        if (pre < 4) {
            if (t.isIdent("normal")) {
                pre += 1;
                continue;
            }
            if (style == null) {
                if (tok.kw(c.FontStyle, t)) |st| {
                    style = st;
                    pre += 1;
                    if (st == .oblique) {
                        if (values.angle(l.peek(), false)) |_| _ = l.next();
                    }
                    continue;
                }
            }
            if (!variant and t.isIdent("small-caps")) {
                variant = true;
                pre += 1;
                continue;
            }
            if (stretch == null and t.kind == .ident and tok.matchPacked(t.text, stretch_kw) != null) {
                stretch = fontStretchValue(t);
                pre += 1;
                continue;
            }
            if (weight == null and (t.kind == .number or (t.kind == .ident and !t.isIdent("smaller") and !t.isIdent("larger")))) {
                if (try weightValue(cx, t)) |w| {
                    weight = w;
                    pre += 1;
                    continue;
                }
            }
        }
        size_t = t;
        break;
    }
    const fs = try need(f32, try fontSizeValue(cx, size_t));
    var lh: c.LineHeight = .normal;
    if (l.peek().kind == .slash) {
        _ = l.next();
        // line-height ems refer to the new font size
        const saved = s.font_size;
        s.font_size = fs;
        lh = try lineHeightValue(cx, l.next());
        s.font_size = saved;
    }
    const fam = try parseFamilies(cx, l);
    s.font_style = style orelse .normal;
    s.font_weight = weight orelse 400;
    s.font_size = fs;
    s.line_height = lh;
    s.font_family = fam;
    s.font_stretch = stretch orelse 100;
    s.font_variant_caps = if (variant) .small_caps else .normal;
    s.font_variant_ligatures = .{};
    s.font_variant_numeric = .{};
    s.font_variant_east_asian = .{};
    s.font_variant_position = .normal;
    s.font_kerning = .auto;
    s.font_optical_sizing = .auto;
    s.font_feature_settings = &.{};
    s.font_variation_settings = &.{};
}

fn decoLine(l: *Lexer) Error!?c.DecorationLine {
    var d: c.DecorationLine = .{};
    var any = false;
    if (l.peek().isIdent("none")) {
        _ = l.next();
        return d;
    }
    while (true) {
        const t = l.peek();
        if (t.isIdent("underline")) {
            d.underline = true;
        } else if (t.isIdent("overline")) {
            d.overline = true;
        } else if (t.isIdent("line-through")) {
            d.line_through = true;
        } else if (t.isIdent("blink")) {} else break;
        _ = l.next();
        any = true;
    }
    return if (any) d else null;
}

fn decoThickness(cx: *Cx, t: Token) Error!??f32 {
    if (t.isIdent("auto") or t.isIdent("from-font")) return @as(?f32, null);
    const v = (values.lengthPct(t, &cx.env)) orelse return null;
    return @as(?f32, v.resolve(cx.s.font_size));
}

fn parseTextDecoration(cx: *Cx, l: *Lexer) Error!void {
    var line: ?c.DecorationLine = null;
    var style: ?c.DecorationStyle = null;
    var col: ?ColorValue = null;
    var thick: ??f32 = null;
    var from_font = false;
    var n: usize = 0;
    while (!l.atEnd()) {
        n += 1;
        if (line == null) {
            if (try decoLine(l)) |d| {
                line = d;
                continue;
            }
        }
        const t = l.next();
        if (style == null) {
            if (tok.kw(c.DecorationStyle, t)) |v| {
                style = v;
                continue;
            }
        }
        if (col == null) {
            if (colorm.fromToken(t)) |v| {
                col = v;
                continue;
            }
        }
        if (thick == null) {
            if (try decoThickness(cx, t)) |v| {
                thick = v;
                from_font = t.isIdent("from-font");
                continue;
            }
        }
        return bad;
    }
    if (n == 0) return bad;
    const s = cx.s;
    s.text_decoration_line = line orelse .{};
    s.text_decoration_style = style orelse .solid;
    s.text_decoration_color = col orelse .current;
    s.text_decoration_thickness = thick orelse null;
    s.text_decoration_from_font = from_font;
}

fn parseWhiteSpace(cx: *Cx, l: *Lexer) Error!void {
    const s = cx.s;
    const t = l.peek();
    const Pair = struct { []const u8, c.WhiteSpaceCollapse, c.TextWrapMode };
    const tbl = [_]Pair{
        .{ "normal", .collapse, .wrap },          .{ "nowrap", .collapse, .nowrap },
        .{ "pre", .preserve, .nowrap },           .{ "pre-wrap", .preserve, .wrap },
        .{ "pre-line", .preserve_breaks, .wrap }, .{ "break-spaces", .break_spaces, .wrap },
    };
    if (t.kind == .ident) {
        for (tbl) |e| if (std.ascii.eqlIgnoreCase(t.text, e[0])) {
            _ = l.next();
            s.white_space_collapse = e[1];
            s.text_wrap_mode = e[2];
            return;
        };
    }
    var col: ?c.WhiteSpaceCollapse = null;
    var mode: ?c.TextWrapMode = null;
    while (!l.atEnd()) {
        const x = l.next();
        if (col == null) {
            if (tok.kw(c.WhiteSpaceCollapse, x)) |v| {
                col = v;
                continue;
            }
        }
        if (mode == null) {
            if (tok.kw(c.TextWrapMode, x)) |v| {
                mode = v;
                continue;
            }
        }
        return bad;
    }
    if (col == null and mode == null) return bad;
    s.white_space_collapse = col orelse .collapse;
    s.text_wrap_mode = mode orelse .wrap;
}

fn parseTextWrap(cx: *Cx, l: *Lexer) Error!void {
    var mode: ?c.TextWrapMode = null;
    var style: ?c.TextWrapStyle = null;
    while (!l.atEnd()) {
        const t = l.next();
        if (mode == null) {
            if (tok.kw(c.TextWrapMode, t)) |v| {
                mode = v;
                continue;
            }
        }
        if (style == null) {
            if (tok.kw(c.TextWrapStyle, t)) |v| {
                style = v;
                continue;
            }
        }
        return bad;
    }
    if (mode == null and style == null) return bad;
    cx.s.text_wrap_mode = mode orelse .wrap;
    cx.s.text_wrap_style = style orelse .auto;
}

fn parseStroke(cx: *Cx, l: *Lexer) Error!void {
    var w: ?f32 = null;
    var col: ?ColorValue = null;
    while (!l.atEnd()) {
        const t = l.next();
        if (w == null) {
            if (try lineWidth(cx, t)) |v| {
                w = v;
                continue;
            }
        }
        if (col == null) {
            if (colorm.fromToken(t)) |v| {
                col = v;
                continue;
            }
        }
        return bad;
    }
    if (w == null and col == null) return bad;
    cx.s.webkit_text_stroke_width = w orelse 0;
    cx.s.webkit_text_stroke_color = col orelse .current;
}

fn lineClampValue(l: *Lexer) Error!u32 {
    const t = l.next();
    if (t.isIdent("none")) return 0;
    const n = try need(i32, values.integer(t));
    return if (n < 1) 0 else @intCast(n);
}

/// `line-clamp` (takumi / css-overflow-4): none | [<integer> || auto || <block-ellipsis>] | -webkit-legacy,
/// <block-ellipsis> = none | no-ellipsis | auto | <string>. `auto` (clamp by block size) and
/// `-webkit-legacy` are accepted and ignored.
fn parseLineClamp(s: *S, l: *Lexer) Error!void {
    s.block_ellipsis = .auto;
    s.block_ellipsis_string = "";
    if (l.peek().isIdent("none")) {
        var probe = l.*;
        _ = probe.next();
        if (probe.atEnd()) {
            _ = l.next();
            s.line_clamp = 0;
            return;
        }
    }
    var lines: ?u32 = null;
    var auto = false;
    var have_ell = false;
    while (!l.atEnd()) {
        const t = l.next();
        if (t.isIdent("-webkit-legacy")) continue;
        if (!auto and t.isIdent("auto")) {
            auto = true;
        } else if (!have_ell and (t.isIdent("none") or t.isIdent("no-ellipsis"))) {
            have_ell = true;
            s.block_ellipsis = .none;
        } else if (!have_ell and t.kind == .string) {
            have_ell = true;
            s.block_ellipsis = .string;
            s.block_ellipsis_string = t.text;
        } else if (lines == null) {
            const n = try need(i32, values.integer(t));
            lines = if (n < 1) 0 else @intCast(n);
        } else return bad;
    }
    if (lines == null and !auto and !have_ell) return bad;
    s.line_clamp = lines orelse 0;
}

fn parseTabSize(cx: *Cx, t: Token) Error!c.TabSize {
    if (t.kind == .number) {
        if (t.num < 0) return bad;
        return .{ .number = t.num };
    }
    const v = try len(cx, t);
    if (v < 0) return bad;
    return .{ .px = v };
}

// ------------------------------------------------------------------ single-keyword properties (table-driven)
const KwEntry = struct { names: []const u8, off: u16 };

fn ke(comptime E: type, comptime f: FieldRef) KwEntry {
    if (@sizeOf(E) != 1) @compileError("keyword field must be a u8 enum");
    return .{ .names = tok.packedNames(E), .off = rangeOf(f).off };
}

fn kwEntryOf(comptime p: Prop) ?KwEntry {
    return switch (p) {
        .position => ke(c.Position, fr("position")),
        .boxSizing => ke(c.BoxSizing, fr("box_sizing")),
        .overflowX => ke(c.Overflow, fr("overflow_x")),
        .overflowY => ke(c.Overflow, fr("overflow_y")),
        .visibility => ke(c.Visibility, fr("visibility")),
        .flexDirection => ke(c.FlexDirection, fr("flex_direction")),
        .flexWrap => ke(c.FlexWrap, fr("flex_wrap")),
        .borderTopStyle => ke(c.BorderStyle, fi("border_style", 0)),
        .borderRightStyle => ke(c.BorderStyle, fi("border_style", 1)),
        .borderBottomStyle => ke(c.BorderStyle, fi("border_style", 2)),
        .borderLeftStyle => ke(c.BorderStyle, fi("border_style", 3)),
        .objectFit => ke(c.ObjectFit, fr("object_fit")),
        .mixBlendMode => ke(c.BlendMode, fr("mix_blend_mode")),
        .textDecorationStyle => ke(c.DecorationStyle, fr("text_decoration_style")),
        .whiteSpaceCollapse => ke(c.WhiteSpaceCollapse, fr("white_space_collapse")),
        .textWrapMode => ke(c.TextWrapMode, fr("text_wrap_mode")),
        .textWrapStyle => ke(c.TextWrapStyle, fr("text_wrap_style")),
        .wordBreak => ke(c.WordBreak, fr("word_break")),
        .overflowWrap, .wordWrap => ke(c.OverflowWrap, fr("overflow_wrap")),
        .direction => ke(c.Direction, fr("direction")),
        .overflowInline => ke(c.Overflow, fr("overflow_x")),
        .overflowBlock => ke(c.Overflow, fr("overflow_y")),
        .float => ke(c.Float, fr("float")),
        .clear => ke(c.Clear, fr("clear")),
        .tableLayout => ke(c.TableLayout, fr("table_layout")),
        .borderCollapse => ke(c.BorderCollapse, fr("border_collapse")),
        .captionSide => ke(c.CaptionSide, fr("caption_side")),
        .emptyCells => ke(c.EmptyCells, fr("empty_cells")),
        .boxDecorationBreak, .WebkitBoxDecorationBreak => ke(c.BoxDecorationBreak, fr("box_decoration_break")),
        // (the legacy `page-break-*` properties are aliases, as in takumi; `always` = `page`)
        .breakBefore, .pageBreakBefore => if (cfg.pdf) ke(c.BreakBetween, fr("break_before")) else null,
        .breakAfter, .pageBreakAfter => if (cfg.pdf) ke(c.BreakBetween, fr("break_after")) else null,
        .breakInside, .pageBreakInside => if (cfg.pdf) ke(c.BreakInside, fr("break_inside")) else null,
        .isolation => ke(c.Isolation, fr("isolation")),
        .unicodeBidi => ke(c.UnicodeBidi, fr("unicode_bidi")),
        .writingMode => ke(c.WritingMode, fr("writing_mode")),
        .textOrientation => ke(c.TextOrientation, fr("text_orientation")),
        .textCombineUpright => ke(c.TextCombineUpright, fr("text_combine_upright")),
        .textDecorationSkipInk => ke(c.SkipInk, fr("text_decoration_skip_ink")),
        .textAlignLast => ke(c.TextAlignLast, fr("text_align_last")),
        .hyphens, .WebkitHyphens => ke(c.Hyphens, fr("hyphens")),
        .lineBreak => ke(c.LineBreak, fr("line_break")),
        .fontKerning => ke(c.FontKerning, fr("font_kerning")),
        .fontOpticalSizing => ke(c.FontOpticalSizing, fr("font_optical_sizing")),
        .fontVariantCaps => ke(c.VariantCaps, fr("font_variant_caps")),
        .fontVariantPosition => ke(c.VariantPosition, fr("font_variant_position")),
        .maskType => ke(c.MaskType, fr("mask_type")),
        .listStylePosition => ke(c.ListStylePosition, fr("list_style_position")),
        else => null,
    };
}

const kw_count = blk: {
    var n: usize = 0;
    for (0..n_props) |i| {
        if (kwEntryOf(@fromBackingInt(@intCast(i))) != null) n += 1;
    }
    break :blk n;
};
const kw_entries: [kw_count]KwEntry = blk: {
    @setEvalBranchQuota(100000);
    var o: [kw_count]KwEntry = undefined;
    var n: usize = 0;
    for (0..n_props) |i| {
        if (kwEntryOf(@fromBackingInt(@intCast(i)))) |e| {
            o[n] = e;
            n += 1;
        }
    }
    break :blk o;
};
/// Prop -> index into kw_entries (0xff = not a single-keyword property).
const kw_index: [n_props]u8 = blk: {
    @setEvalBranchQuota(100000);
    var o: [n_props]u8 = undefined;
    var n: usize = 0;
    for (0..n_props) |i| {
        if (kwEntryOf(@fromBackingInt(@intCast(i))) != null) {
            o[i] = n;
            n += 1;
        } else o[i] = 0xff;
    }
    break :blk o;
};

// ------------------------------------------------------------------ logical properties
/// The physical properties whose fields `p` writes, for horizontal writing modes (`rtl` flips the
/// inline axis). Physical properties map to themselves. Pairs are [start, end].
pub fn physicalProps(p: Prop, rtl: bool, buf: *[4]Prop) []const Prop {
    const Map = struct { Prop, Prop, Prop }; // logical, ltr, rtl
    const singles = [_]Map{
        .{ .marginInlineStart, .marginLeft, .marginRight },                            .{ .marginInlineEnd, .marginRight, .marginLeft },
        .{ .marginBlockStart, .marginTop, .marginTop },                                .{ .marginBlockEnd, .marginBottom, .marginBottom },
        .{ .paddingInlineStart, .paddingLeft, .paddingRight },                         .{ .paddingInlineEnd, .paddingRight, .paddingLeft },
        .{ .paddingBlockStart, .paddingTop, .paddingTop },                             .{ .paddingBlockEnd, .paddingBottom, .paddingBottom },
        .{ .insetInlineStart, .left, .right },                                         .{ .insetInlineEnd, .right, .left },
        .{ .insetBlockStart, .top, .top },                                             .{ .insetBlockEnd, .bottom, .bottom },
        .{ .inlineSize, .width, .width },                                              .{ .blockSize, .height, .height },
        .{ .minInlineSize, .minWidth, .minWidth },                                     .{ .minBlockSize, .minHeight, .minHeight },
        .{ .maxInlineSize, .maxWidth, .maxWidth },                                     .{ .maxBlockSize, .maxHeight, .maxHeight },
        .{ .borderInlineStart, .borderLeft, .borderRight },                            .{ .borderInlineEnd, .borderRight, .borderLeft },
        .{ .borderBlockStart, .borderTop, .borderTop },                                .{ .borderBlockEnd, .borderBottom, .borderBottom },
        .{ .borderInlineStartWidth, .borderLeftWidth, .borderRightWidth },             .{ .borderInlineEndWidth, .borderRightWidth, .borderLeftWidth },
        .{ .borderInlineStartStyle, .borderLeftStyle, .borderRightStyle },             .{ .borderInlineEndStyle, .borderRightStyle, .borderLeftStyle },
        .{ .borderInlineStartColor, .borderLeftColor, .borderRightColor },             .{ .borderInlineEndColor, .borderRightColor, .borderLeftColor },
        .{ .borderBlockStartWidth, .borderTopWidth, .borderTopWidth },                 .{ .borderBlockEndWidth, .borderBottomWidth, .borderBottomWidth },
        .{ .borderBlockStartStyle, .borderTopStyle, .borderTopStyle },                 .{ .borderBlockEndStyle, .borderBottomStyle, .borderBottomStyle },
        .{ .borderBlockStartColor, .borderTopColor, .borderTopColor },                 .{ .borderBlockEndColor, .borderBottomColor, .borderBottomColor },
        .{ .borderStartStartRadius, .borderTopLeftRadius, .borderTopRightRadius },     .{ .borderStartEndRadius, .borderTopRightRadius, .borderTopLeftRadius },
        .{ .borderEndStartRadius, .borderBottomLeftRadius, .borderBottomRightRadius }, .{ .borderEndEndRadius, .borderBottomRightRadius, .borderBottomLeftRadius },
    };
    for (singles) |m| if (m[0] == p) {
        buf[0] = if (rtl) m[2] else m[1];
        return buf[0..1];
    };
    const pairs = [_]Map{
        .{ .marginInline, .marginInlineStart, .marginInlineEnd },                .{ .marginBlock, .marginBlockStart, .marginBlockEnd },
        .{ .paddingInline, .paddingInlineStart, .paddingInlineEnd },             .{ .paddingBlock, .paddingBlockStart, .paddingBlockEnd },
        .{ .insetInline, .insetInlineStart, .insetInlineEnd },                   .{ .insetBlock, .insetBlockStart, .insetBlockEnd },
        .{ .borderInline, .borderInlineStart, .borderInlineEnd },                .{ .borderBlock, .borderBlockStart, .borderBlockEnd },
        .{ .borderInlineWidth, .borderInlineStartWidth, .borderInlineEndWidth }, .{ .borderBlockWidth, .borderBlockStartWidth, .borderBlockEndWidth },
        .{ .borderInlineStyle, .borderInlineStartStyle, .borderInlineEndStyle }, .{ .borderBlockStyle, .borderBlockStartStyle, .borderBlockEndStyle },
        .{ .borderInlineColor, .borderInlineStartColor, .borderInlineEndColor }, .{ .borderBlockColor, .borderBlockStartColor, .borderBlockEndColor },
    };
    for (pairs) |m| if (m[0] == p) {
        var b2: [4]Prop = undefined;
        buf[0] = physicalProps(m[1], rtl, &b2)[0];
        buf[1] = physicalProps(m[2], rtl, &b2)[0];
        return buf[0..2];
    };
    buf[0] = p;
    return buf[0..1];
}

/// `physicalProps` for an element of style `s`: its `direction`, and its `writing-mode`, which in a
/// vertical writing mode turns the inline axis vertical (inline-start = top, or bottom when `rtl`)
/// and puts the block start on the right (`vertical-rl`, `sideways-rl`) or on the left.
pub fn physicalPropsOf(p: Prop, s: *const S, buf: *[4]Prop) []const Prop {
    const rtl = s.direction == .rtl;
    if (s.writing_mode == .horizontal_tb) return physicalProps(p, rtl, buf);
    var hb: [4]Prop = undefined;
    // (the mapping of a horizontal left-to-right flow, turned: physical properties stay)
    const h = physicalProps(p, false, &hb);
    if (h.len == 1 and h[0] == p) {
        buf[0] = p;
        return buf[0..1];
    }
    const rl = s.writing_mode != .vertical_lr and s.writing_mode != .sideways_lr;
    for (h, 0..) |q, i| buf[i] = turnProp(q, rtl, rl);
    return buf[0..h.len];
}

/// A physical property of a horizontal left-to-right flow (left = inline-start, top = block-start)
/// mapped to the one at the same logical place in a vertical flow.
fn turnProp(q: Prop, rtl: bool, rl: bool) Prop {
    const fams = [_][4]Prop{
        .{ .marginTop, .marginRight, .marginBottom, .marginLeft },
        .{ .paddingTop, .paddingRight, .paddingBottom, .paddingLeft },
        .{ .top, .right, .bottom, .left },
        .{ .borderTop, .borderRight, .borderBottom, .borderLeft },
        .{ .borderTopWidth, .borderRightWidth, .borderBottomWidth, .borderLeftWidth },
        .{ .borderTopStyle, .borderRightStyle, .borderBottomStyle, .borderLeftStyle },
        .{ .borderTopColor, .borderRightColor, .borderBottomColor, .borderLeftColor },
    };
    // side index 0 top, 1 right, 2 bottom, 3 left -> its vertical-flow side
    const is_side: usize = if (rtl) 2 else 0; // inline-start
    const ie_side: usize = if (rtl) 0 else 2; // inline-end
    const bs_side: usize = if (rl) 1 else 3; // block-start
    const be_side: usize = if (rl) 3 else 1; // block-end
    const turn = [4]usize{ bs_side, ie_side, be_side, is_side };
    for (fams) |fam| {
        for (fam, 0..) |x, k| if (x == q) return fam[turn[k]];
    }
    // corners: [block side][inline side] of the horizontal flow
    const corners = [_]struct { Prop, usize, usize }{
        .{ .borderTopLeftRadius, 0, 3 },    .{ .borderTopRightRadius, 0, 1 },
        .{ .borderBottomLeftRadius, 2, 3 }, .{ .borderBottomRightRadius, 2, 1 },
    };
    for (corners) |cr| if (cr[0] == q) {
        const v = turn[cr[1]]; // vertical flow: the block side is now left / right
        const hz = turn[cr[2]]; // the inline side top / bottom
        const top = hz == 0;
        const right = v == 1;
        return if (top) (if (right) .borderTopRightRadius else .borderTopLeftRadius) else (if (right) .borderBottomRightRadius else .borderBottomLeftRadius);
    };
    return switch (q) {
        .width => .height,
        .height => .width,
        .minWidth => .minHeight,
        .minHeight => .minWidth,
        .maxWidth => .maxHeight,
        .maxHeight => .maxWidth,
        else => q,
    };
}

/// True for the two-value logical shorthands `start [end]`.
fn isSplitPair(p: Prop) bool {
    return switch (p) {
        .marginInline, .marginBlock, .paddingInline, .paddingBlock, .insetInline, .insetBlock, .borderInlineWidth, .borderBlockWidth, .borderInlineStyle, .borderBlockStyle, .borderInlineColor, .borderBlockColor => true,
        else => false,
    };
}

/// Source text of the next token (for re-dispatching part of a value).
fn tokenText(l: *Lexer) []const u8 {
    _ = l.atEnd(); // skip whitespace
    const b = l.i;
    _ = l.next();
    return l.s[b..l.i];
}

fn applyLogical(cx: *Cx, p: Prop, l: *Lexer, phys: []const Prop) Error!void {
    if (phys.len == 1) return apply(cx, phys[0], l);
    if (!isSplitPair(p) or l.forced != null) {
        var l2 = l.*;
        try apply(cx, phys[0], l);
        return apply(cx, phys[1], &l2);
    }
    const a = tokenText(l);
    const b = if (l.atEnd()) a else tokenText(l);
    if (!l.atEnd()) return bad;
    var la = Lexer.init(a);
    try apply(cx, phys[0], &la);
    var lb = Lexer.init(b);
    try apply(cx, phys[1], &lb);
}

// ------------------------------------------------------------------ misc box properties
fn parseDisplay(l: *Lexer) Error!c.Display {
    const t = l.next();
    if (t.kind != .ident) return bad;
    if (t.isIdent("-webkit-box")) return .webkit_box;
    if (t.isIdent("-webkit-inline-box")) return .webkit_inline_box;
    if (t.isIdent("-webkit-flex")) return .flex;
    if (t.isIdent("-webkit-inline-flex")) return .inline_flex;
    const d = tok.kw(c.Display, t) orelse return bad;
    if (d == .webkit_box or d == .webkit_inline_box) return bad; // only the dashed spelling
    return d;
}

fn parseBorderSpacing(cx: *Cx, l: *Lexer) Error![2]f32 {
    const h = try len(cx, l.next());
    const v = if (l.atEnd()) h else try len(cx, l.next());
    if (h < 0 or v < 0) return bad;
    return .{ h, v };
}

fn parseVerticalAlign(cx: *Cx, t: Token) Error!c.VerticalAlign {
    if (t.kind == .ident) {
        const names = "baseline\x00sub\x00super\x00top\x00middle\x00bottom\x00text-top\x00text-bottom";
        const i = tok.matchPacked(t.text, names) orelse return bad;
        const tags = [_]c.VerticalAlign{ .baseline, .sub, .super, .top, .middle, .bottom, .text_top, .text_bottom };
        return tags[i];
    }
    return .{ .lp = try lp(cx, t) };
}

fn parseContain(l: *Lexer) Error!c.Contain {
    var v: c.Contain = .{};
    const f = l.peek();
    if (f.isIdent("none")) {
        _ = l.next();
        return v;
    }
    if (f.isIdent("strict") or f.isIdent("content")) {
        _ = l.next();
        return .{ .size = f.isIdent("strict"), .layout = true, .style = true, .paint = true };
    }
    var n: usize = 0;
    while (!l.atEnd()) : (n += 1) {
        const t = l.next();
        const i = tok.matchPacked(t.text, "size\x00inline-size\x00layout\x00style\x00paint") orelse return bad;
        if (t.kind != .ident) return bad;
        const bit = @as(u8, 1) << @intCast(i);
        const cur: u8 = @bitCast(v);
        if (cur & bit != 0) return bad;
        v = @bitCast(cur | bit);
    }
    if (n == 0 or (v.size and v.inline_size)) return bad;
    return v;
}

/// The rest of the value as written (trimmed), consuming it.
fn rawRest(l: *Lexer) Error![]const u8 {
    if (l.forced != null) return bad;
    const r = std.mem.trim(u8, l.s[@min(l.i, l.s.len)..], " \t\r\n\x0c");
    l.i = l.s.len;
    if (r.len == 0) return bad;
    return r;
}

fn parseCounters(l: *Lexer) Error![]const u8 {
    const r = try rawRest(l);
    var v = Lexer.init(r);
    if (v.next().isIdent("none") and v.atEnd()) return "";
    var sub = Lexer.init(r);
    while (!sub.atEnd()) {
        const t = sub.next();
        if (t.kind != .ident and !(t.kind == .number and t.int)) return bad;
    }
    return r;
}

fn parseContent(l: *Lexer) Error![]const u8 {
    const r = try rawRest(l);
    var sub = Lexer.init(r);
    while (!sub.atEnd()) {
        const t = sub.next();
        switch (t.kind) {
            .ident, .string, .function, .slash => {},
            else => return bad,
        }
    }
    return r;
}

fn listStyleTypeValue(t: Token) Error!?c.ListStyleType {
    if (t.kind == .string) return .{ .string = t.text };
    if (t.kind != .ident) return null;
    if (t.isIdent("none")) return .none;
    if (t.isIdent("inside") or t.isIdent("outside")) return null;
    return .{ .ident = t.text };
}

fn parseListStyle(cx: *Cx, l: *Lexer) Error!void {
    var ty: ?c.ListStyleType = null;
    var pos: ?c.ListStylePosition = null;
    var img: ?c.Image = null;
    var nones: u8 = 0;
    var n: usize = 0;
    while (!l.atEnd()) : (n += 1) {
        const t = l.next();
        if (t.isIdent("none")) {
            nones += 1;
            continue;
        }
        if (pos == null) if (tok.kw(c.ListStylePosition, t)) |v| {
            pos = v;
            continue;
        };
        if (img == null and t.kind == .function) {
            if (try gradient.image(cx.a, t, &cx.env)) |im| {
                img = im;
                continue;
            }
        }
        if (ty == null) if (try listStyleTypeValue(t)) |v| {
            ty = v;
            continue;
        };
        return bad;
    }
    if (n == 0) return bad;
    // `none` fills whichever of type / image is unset
    var k = nones;
    if (k > 0 and ty == null) {
        ty = .none;
        k -= 1;
    }
    if (k > 0 and img == null) {
        img = .none;
        k -= 1;
    }
    if (k > 0) return bad;
    cx.s.list_style_type = ty orelse .{ .ident = "disc" };
    cx.s.list_style_position = pos orelse .outside;
    cx.s.list_style_image = img orelse .none;
}

// ------------------------------------------------------------------ clip-path / masks
fn fillRule(l: *Lexer) Error!c.FillRule {
    const p = l.peek();
    if (p.isIdent("nonzero") or p.isIdent("evenodd")) {
        _ = l.next();
        if (l.next().kind != .comma) return bad;
        return if (p.isIdent("evenodd")) .evenodd else .nonzero;
    }
    return .nonzero;
}

fn shapeRadius(cx: *Cx, t: Token) Error!?c.ShapeRadius {
    if (t.isIdent("closest-side")) return .closest_side;
    if (t.isIdent("farthest-side")) return .farthest_side;
    const v = values.lengthPct(t, &cx.env) orelse return null;
    if (v.px < 0 or v.pct < 0) return bad;
    return .{ .lp = v };
}

fn shapeAt(cx: *Cx, l: *Lexer) Error![2]LP {
    if (l.atEnd()) return c.center2;
    if (!l.next().isIdent("at")) return bad;
    return need([2]LP, values.position(l, &cx.env, 4));
}

fn basicShape(cx: *Cx, t: Token) Error!?c.BasicShape {
    if (t.kind != .function) return null;
    var l = Lexer.init(t.args);
    const n = t.text;
    var sh: c.BasicShape = undefined;
    if (ieq(n, "inset")) {
        var buf: [4]Token = undefined;
        var k: usize = 0;
        while (!l.atEnd() and !l.peek().isIdent("round")) {
            if (k == 4) return bad;
            buf[k] = l.next();
            k += 1;
        }
        const ts = try expand4(Token, buf[0..k]);
        var sides: [4]LP = undefined;
        for (ts, 0..) |x, i| sides[i] = try lp(cx, x);
        var radius: [4][2]LP = .{ c.zero2, c.zero2, c.zero2, c.zero2 };
        if (l.peek().isIdent("round")) {
            _ = l.next();
            radius = try parseBorderRadius(cx, &l);
        }
        sh = .{ .inset = .{ .sides = sides, .radius = radius } };
    } else if (ieq(n, "circle")) {
        var r: c.ShapeRadius = .closest_side;
        if (!l.atEnd() and !l.peek().isIdent("at")) r = try need(c.ShapeRadius, try shapeRadius(cx, l.next()));
        sh = .{ .circle = .{ .r = r, .at = try shapeAt(cx, &l) } };
    } else if (ieq(n, "ellipse")) {
        var rx: c.ShapeRadius = .closest_side;
        var ry: c.ShapeRadius = .closest_side;
        if (!l.atEnd() and !l.peek().isIdent("at")) {
            rx = try need(c.ShapeRadius, try shapeRadius(cx, l.next()));
            ry = try need(c.ShapeRadius, try shapeRadius(cx, l.next()));
        }
        sh = .{ .ellipse = .{ .rx = rx, .ry = ry, .at = try shapeAt(cx, &l) } };
    } else if (ieq(n, "polygon")) {
        const rule = try fillRule(&l);
        var pts: tok.List([2]LP) = .{};
        while (true) {
            const x = try lp(cx, l.next());
            const y = try lp(cx, l.next());
            try pts.append(cx.a, .{ x, y });
            const sep = l.next();
            if (sep.kind == .eof) break;
            if (sep.kind != .comma or pts.items.len > 4096) return bad;
        }
        sh = .{ .polygon = .{ .rule = rule, .points = pts.items } };
    } else if (ieq(n, "path")) {
        const rule = try fillRule(&l);
        const s = l.next();
        if (s.kind != .string) return bad;
        sh = .{ .path = .{ .rule = rule, .d = s.text } };
    } else return null;
    if (!l.atEnd()) return bad;
    return sh;
}

fn geometryBox(t: Token) ?c.GeometryBox {
    return tok.kw(c.GeometryBox, t);
}

fn parseClipPath(cx: *Cx, l: *Lexer) Error!?*const c.ClipPath {
    const f = l.peek();
    if (f.isIdent("none")) {
        _ = l.next();
        return null;
    }
    var cp: c.ClipPath = .{};
    if (f.isFunc("url")) {
        _ = l.next();
        cp.url = std.mem.trim(u8, f.args, " \t\"'");
    } else {
        var have_box = false;
        var n: usize = 0;
        while (!l.atEnd()) : (n += 1) {
            const t = l.next();
            if (!have_box) if (geometryBox(t)) |b| {
                cp.box = b;
                have_box = true;
                continue;
            };
            if (cp.shape == null) if (try basicShape(cx, t)) |sh| {
                cp.shape = sh;
                continue;
            };
            return bad;
        }
        if (n == 0) return bad;
    }
    const out = try cx.a.create(c.ClipPath);
    out.* = cp;
    return out;
}

fn offsetPosition(cx: *Cx, l: *Lexer, anchor: bool) Error!?[2]LP {
    if (l.peek().isIdent("auto") or (!anchor and l.peek().isIdent("normal"))) {
        _ = l.next();
        return null;
    }
    return try motionPosition(cx, l);
}

// Pinned Takumi's ShapePosition accepts one/two lengths, without CSS side keywords.
fn motionPosition(cx: *Cx, l: *Lexer) Error![2]LP {
    const x = try lp(cx, l.next());
    const y = values.lengthPct(l.peek(), &cx.env);
    if (y != null) _ = l.next();
    return .{ x, y orelse LP{ .pct = 0.5 } };
}

fn offsetRotate(l: *Lexer) Error!c.OffsetRotate {
    var out: c.OffsetRotate = .{};
    var have_mode = false;
    var have_angle = false;
    while (!l.atEnd() and l.peek().kind != .slash) {
        const t = l.peek();
        if (!have_mode and (t.isIdent("auto") or t.isIdent("reverse"))) {
            out.mode = if (t.isIdent("auto")) .auto else .reverse;
            have_mode = true;
        } else if (!have_angle and values.angle(t, true) != null) {
            out.angle = try angleArg(t);
            have_angle = true;
        } else break;
        _ = l.next();
    }
    if (!have_mode and !have_angle) return bad;
    if (!have_mode) out.mode = .fixed;
    return out;
}

fn offsetPath(cx: *Cx, l: *Lexer) Error!?*const c.MotionPath {
    const t = l.next();
    if (t.isIdent("none")) return null;
    var ray: ?c.MotionRay = null;
    var shape: ?c.BasicShape = null;
    if (t.isFunc("ray")) {
        var args = Lexer.init(t.args);
        var r: c.MotionRay = .{ .angle = 0 };
        var have_angle = false;
        var have_size = false;
        var contain = false;
        while (!args.atEnd()) {
            const item = args.peek();
            if (!have_size) if (tok.kw(@FieldType(c.MotionRay, "size"), item)) |size| {
                r.size = size;
                have_size = true;
                _ = args.next();
                continue;
            };
            if (!contain and item.isIdent("contain")) {
                contain = true;
                _ = args.next();
                continue;
            }
            if (r.at == null and item.isIdent("at")) {
                _ = args.next();
                r.at = try motionPosition(cx, &args);
                continue;
            }
            if (have_angle) return bad;
            r.angle = try angleArg(args.next());
            have_angle = true;
        }
        if (!have_angle) return bad;
        ray = r;
    } else if (geometryBox(t) == null) {
        shape = (try basicShape(cx, t)) orelse return bad;
        if (t.isFunc("circle") or t.isFunc("ellipse")) {
            var args = Lexer.init(t.args);
            while (!args.atEnd()) if (args.next().isIdent("at")) {
                _ = try motionPosition(cx, &args);
                if (!args.atEnd()) return bad;
                break;
            };
        }
    }
    if (geometryBox(l.peek()) != null) _ = l.next();
    return try @import("motion_path.zig").compile(cx.a, shape, ray, cx.env);
}

fn offsetShorthand(cx: *Cx, l: *Lexer) Error!void {
    const s = cx.s;
    s.offset_position = null;
    s.offset_path = null;
    s.offset_distance = .{};
    s.offset_rotate = .{};
    s.offset_anchor = null;
    const t = l.peek();
    if (!t.isIdent("none") and !t.isFunc("ray") and t.kind != .function and geometryBox(t) == null) s.offset_position = try offsetPosition(cx, l, false);
    if (!l.atEnd() and l.peek().kind != .slash) s.offset_path = try offsetPath(cx, l);
    if (s.offset_path != null) {
        var have_distance = false;
        var have_rotate = false;
        while (!l.atEnd() and l.peek().kind != .slash) {
            if (!have_distance) if (values.lengthPct(l.peek(), &cx.env)) |distance| {
                s.offset_distance = distance;
                have_distance = true;
                _ = l.next();
                continue;
            };
            if (have_rotate) return bad;
            s.offset_rotate = try offsetRotate(l);
            have_rotate = true;
        }
    }
    if (l.peek().kind == .slash) {
        _ = l.next();
        s.offset_anchor = try offsetPosition(cx, l, true);
    }
}

/// mask `<geometry-box> | no-clip` -> BgBox (margin/fill/stroke/view-box and no-clip map to border-box).
fn maskBox(t: Token) ?c.BgBox {
    if (t.isIdent("no-clip")) return .border_box;
    const g = geometryBox(t) orelse return null;
    return switch (g) {
        .padding_box => .padding_box,
        .content_box => .content_box,
        else => .border_box,
    };
}

/// `background-position-x/y` list: `[center | <side> <lp>? | <lp>]#`.
fn parsePosAxis(cx: *Cx, l: *Lexer, y: bool) Error!void {
    var out: tok.List([2]LP) = .{};
    const old = cx.s.background_position;
    while (true) {
        const t = l.next();
        var v: LP = undefined;
        if (t.kind == .ident) {
            const lo = if (y) t.isIdent("top") else t.isIdent("left");
            const hi = if (y) t.isIdent("bottom") else t.isIdent("right");
            if (t.isIdent("center")) {
                v = .{ .pct = 0.5 };
            } else if (lo or hi) {
                v = if (hi) .{ .pct = 1 } else .{};
                if (!isEnd(l.peek())) {
                    const o = try lp(cx, l.next());
                    v = if (hi) .{ .px = -o.px, .pct = 1 - o.pct } else o;
                }
            } else return bad;
        } else v = try lp(cx, t);
        var e: [2]LP = if (old.len > 0) old[out.items.len % old.len] else c.zero2;
        e[@intFromBool(y)] = v;
        try out.append(cx.a, e);
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (sep.kind != .comma or out.items.len > 1024) return bad;
    }
    cx.s.background_position = out.items;
}

// ------------------------------------------------------------------ text / font extras
fn parseUnderlinePosition(l: *Lexer) Error!c.UnderlinePosition {
    var v: c.UnderlinePosition = .{};
    if (l.peek().isIdent("auto")) {
        _ = l.next();
        return v;
    }
    var n: usize = 0;
    while (!l.atEnd()) : (n += 1) {
        const t = l.next();
        if (t.isIdent("from-font") and !v.from_font and !v.under) {
            v.from_font = true;
        } else if (t.isIdent("under") and !v.from_font and !v.under) {
            v.under = true;
        } else if ((t.isIdent("left") or t.isIdent("right")) and !v.left and !v.right) {
            if (t.isIdent("left")) v.left = true else v.right = true;
        } else return bad;
    }
    if (n == 0) return bad;
    return v;
}

fn parsePaintOrder(l: *Lexer) Error!c.PaintOrder {
    const t = l.next();
    if (t.isIdent("normal")) return .normal;
    const first = tok.kw(c.PaintOrder, t) orelse return bad;
    if (first == .normal) return bad;
    // Text has no markers phase. Resolve its first relevant phase while the CSS declaration
    // still contains the full order (e.g. `markers stroke` means stroke before fill for text).
    var text_first: ?c.PaintOrder = if (first == .markers) null else first;
    var seen: u8 = @as(u8, 1) << @intCast(@backingInt(first));
    while (!l.atEnd()) {
        const x = tok.kw(c.PaintOrder, l.next()) orelse return bad;
        const bit = @as(u8, 1) << @intCast(@backingInt(x));
        if (x == .normal or seen & bit != 0) return bad;
        seen |= bit;
        if (text_first == null and x != .markers) text_first = x;
    }
    return text_first orelse .fill;
}

const stretch_pct = [_]f32{ 50, 62.5, 75, 87.5, 112.5, 125, 150, 200 };

fn fontStretchValue(t: Token) ?f32 {
    if (t.isIdent("normal")) return 100;
    if (t.kind == .ident) {
        const i = tok.matchPacked(t.text, stretch_kw) orelse return null;
        return stretch_pct[i];
    }
    if (t.kind == .percentage and t.num >= 0) return t.num;
    return null;
}

/// 4-character OpenType tag string (printable ASCII).
fn otTag(t: Token) Error![4]u8 {
    if (t.kind != .string or t.text.len != 4) return bad;
    for (t.text) |ch| if (ch < 0x20 or ch > 0x7e) return bad;
    return t.text[0..4].*;
}

fn parseFeatures(cx: *Cx, l: *Lexer) Error![]const c.FontFeature {
    if (l.peek().isIdent("normal")) {
        _ = l.next();
        return &.{};
    }
    var out: tok.List(c.FontFeature) = .{};
    while (true) {
        const tag = try otTag(l.next());
        var v: u32 = 1;
        const p = l.peek();
        if (p.isIdent("on") or p.isIdent("off")) {
            _ = l.next();
            v = @intFromBool(p.isIdent("on"));
        } else if (!isEnd(p)) {
            const n = try need(i32, values.integer(l.next()));
            if (n < 0) return bad;
            v = @intCast(n);
        }
        try out.append(cx.a, .{ .tag = tag, .value = v });
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (sep.kind != .comma or out.items.len > 256) return bad;
    }
    return out.items;
}

fn parseVariations(cx: *Cx, l: *Lexer) Error![]const c.FontVariation {
    if (l.peek().isIdent("normal")) {
        _ = l.next();
        return &.{};
    }
    var out: tok.List(c.FontVariation) = .{};
    while (true) {
        const tag = try otTag(l.next());
        const v = try need(f32, values.number(l.next()));
        try out.append(cx.a, .{ .tag = tag, .value = v });
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (sep.kind != .comma or out.items.len > 256) return bad;
    }
    return out.items;
}

/// font-variant-* keyword sets. `which` limits the accepted groups (bit 0 ligatures, 1 numeric,
/// 2 east-asian, 3 caps, 4 position). Returns false if `t` is not a keyword of those groups.
const Variants = struct {
    lig: c.VariantLigatures = .{},
    num: c.VariantNumeric = .{},
    ea: c.VariantEastAsian = .{},
    caps: c.VariantCaps = .normal,
    pos: c.VariantPosition = .normal,
    seen: u32 = 0,
};

const variant_kw = "common-ligatures\x00no-common-ligatures\x00discretionary-ligatures\x00no-discretionary-ligatures\x00historical-ligatures\x00no-historical-ligatures\x00contextual\x00no-contextual" ++
    "\x00lining-nums\x00oldstyle-nums\x00proportional-nums\x00tabular-nums\x00diagonal-fractions\x00stacked-fractions\x00ordinal\x00slashed-zero" ++
    "\x00jis78\x00jis83\x00jis90\x00jis04\x00simplified\x00traditional\x00full-width\x00proportional-width\x00ruby" ++
    "\x00small-caps\x00all-small-caps\x00petite-caps\x00all-petite-caps\x00unicase\x00titling-caps\x00sub\x00super";
/// per keyword: group bit, exclusive-slot id (keywords sharing a slot are mutually exclusive)
const variant_group = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 4, 4 };
const variant_slot = [_]u8{ 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 8, 9, 9, 9, 9, 9, 9, 10, 10, 11, 12, 12, 12, 12, 12, 12, 13, 13 };

fn variantKw(v: *Variants, t: Token, which: u8) Error!bool {
    if (t.kind != .ident) return false;
    const i = tok.matchPacked(t.text, variant_kw) orelse return false;
    if ((which >> @intCast(variant_group[i])) & 1 == 0) return false;
    const slot = @as(u32, 1) << @intCast(variant_slot[i]);
    if (v.seen & slot != 0) return bad;
    v.seen |= slot;
    const on: c.LigState = if (i % 2 == 0) .on else .off;
    switch (i) {
        0, 1 => v.lig.common = on,
        2, 3 => v.lig.discretionary = on,
        4, 5 => v.lig.historical = on,
        6, 7 => v.lig.contextual = on,
        8 => v.num.figure = .lining,
        9 => v.num.figure = .oldstyle,
        10 => v.num.spacing = .proportional,
        11 => v.num.spacing = .tabular,
        12 => v.num.fraction = .diagonal,
        13 => v.num.fraction = .stacked,
        14 => v.num.ordinal = true,
        15 => v.num.slashed_zero = true,
        16...21 => v.ea.form = @fromBackingInt(@intCast(i - 15)),
        22 => v.ea.width = .full,
        23 => v.ea.width = .proportional,
        24 => v.ea.ruby = true,
        25...30 => v.caps = @fromBackingInt(@intCast(i - 24)),
        31 => v.pos = .sub,
        else => v.pos = .super,
    }
    return true;
}

/// Parses `normal | [keywords of `which`]+` (+ `none` for ligatures when allowed).
fn parseVariants(l: *Lexer, which: u8, allow_none: bool) Error!Variants {
    var v: Variants = .{};
    const f = l.peek();
    if (f.isIdent("normal")) {
        _ = l.next();
        return v;
    }
    if (allow_none and f.isIdent("none")) {
        _ = l.next();
        v.lig = .{ .common = .off, .discretionary = .off, .historical = .off, .contextual = .off };
        return v;
    }
    var n: usize = 0;
    while (!l.atEnd()) : (n += 1) {
        if (!try variantKw(&v, l.next(), which)) return bad;
    }
    if (n == 0) return bad;
    return v;
}

fn parseSynthesis(l: *Lexer) Error!c.FontSynthesis {
    var v: c.FontSynthesis = .{ .weight = false, .style = false, .small_caps = false, .position = false };
    if (l.peek().isIdent("none")) {
        _ = l.next();
        return v;
    }
    var n: usize = 0;
    while (!l.atEnd()) : (n += 1) {
        const t = l.next();
        const i = tok.matchPacked(t.text, "weight\x00style\x00small-caps\x00position") orelse return bad;
        if (t.kind != .ident) return bad;
        const b: u8 = @bitCast(v);
        const bit = @as(u8, 1) << @intCast(i);
        if (b & bit != 0) return bad;
        v = @bitCast(b | bit);
    }
    if (n == 0) return bad;
    return v;
}

// ------------------------------------------------------------------ animations / transitions
/// `<time>` in milliseconds (`0` unitless accepted).
fn timeMs(t: Token) ?f32 {
    if (t.kind == .number and t.num == 0) return 0;
    if (t.kind != .dimension) return null;
    if (ieq(t.text, "s")) return t.num * 1000;
    if (ieq(t.text, "ms")) return t.num;
    return null;
}

const timing_kw = "linear\x00ease\x00ease-in\x00ease-out\x00ease-in-out\x00step-start\x00step-end";
const timing_cubic = [_][4]f32{ .{ 0, 0, 1, 1 }, .{ 0.25, 0.1, 0.25, 1 }, .{ 0.42, 0, 1, 1 }, .{ 0, 0, 0.58, 1 }, .{ 0.42, 0, 0.58, 1 } };

fn timingFn(cx: *Cx, t: Token) Error!?c.TimingFunction {
    if (t.kind == .ident) {
        const i = tok.matchPacked(t.text, timing_kw) orelse return null;
        if (i < 5) return .{ .cubic = timing_cubic[i] };
        return .{ .steps = .{ .n = 1, .pos = if (i == 5) .jump_start else .jump_end } };
    }
    if (t.kind != .function) return null;
    var a: [4]Token = undefined;
    if (t.isFunc("cubic-bezier")) {
        if (try fnArgs(t.args, &a) != 4) return bad;
        var v: [4]f32 = undefined;
        for (0..4) |i| v[i] = try need(f32, values.number(a[i]));
        if (v[0] < 0 or v[0] > 1 or v[2] < 0 or v[2] > 1) return bad;
        return .{ .cubic = v };
    }
    if (t.isFunc("steps")) {
        var l = Lexer.init(t.args);
        const n = try need(i32, values.integer(l.next()));
        var pos: c.StepPos = .jump_end;
        if (!l.atEnd()) {
            if (l.next().kind != .comma) return bad;
            const p = l.next();
            const i = tok.matchPacked(p.text, "jump-start\x00jump-end\x00jump-none\x00jump-both\x00start\x00end") orelse return bad;
            if (p.kind != .ident) return bad;
            pos = @fromBackingInt(@intCast(if (i == 4) 0 else if (i == 5) 1 else i));
            if (!l.atEnd()) return bad;
        }
        if (n < 1 or (pos == .jump_none and n < 2)) return bad;
        return .{ .steps = .{ .n = @intCast(n), .pos = pos } };
    }
    if (t.isFunc("linear")) return .{ .linear_points = try linearPoints(cx, t.args) };
    return null;
}

/// css-easing-2 `linear()` stop list -> canonical [input, output] points.
fn linearPoints(cx: *Cx, args: []const u8) Error![]const [2]f32 {
    const nan = std.math.nan(f32);
    var pts: tok.List([2]f32) = .{}; // [input (nan = unset), output]
    var l = Lexer.init(args);
    while (true) {
        const out = try need(f32, values.number(l.next()));
        var k: usize = 0;
        while (k < 2 and l.peek().kind == .percentage) : (k += 1) {
            try pts.append(cx.a, .{ l.next().num / 100, out });
        }
        if (k == 0) try pts.append(cx.a, .{ nan, out });
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (sep.kind != .comma or pts.items.len > 1024) return bad;
    }
    const p = pts.items;
    if (p.len < 2) return bad;
    if (p[0][0] != p[0][0]) p[0][0] = 0;
    if (p[p.len - 1][0] != p[p.len - 1][0]) p[p.len - 1][0] = 1;
    var maxin: f32 = p[0][0];
    var i: usize = 1;
    while (i < p.len) : (i += 1) {
        if (p[i][0] == p[i][0]) {
            p[i][0] = @max(p[i][0], maxin);
            maxin = p[i][0];
            continue;
        }
        var j = i + 1;
        while (j < p.len and p[j][0] != p[j][0]) j += 1;
        // j has an input (the last always does)
        const end_in = @max(p[j][0], maxin);
        const steps: f32 = @floatFromInt(j - i + 1);
        var k: usize = i;
        while (k < j) : (k += 1) p[k][0] = maxin + (end_in - maxin) * @as(f32, @floatFromInt(k - i + 1)) / steps;
        i = j - 1;
    }
    return p;
}

fn listOf(comptime T: type, cx: *Cx, l: *Lexer, comptime item: fn (*Cx, Token) Error!?T) Error![]const T {
    var out: tok.List(T) = .{};
    while (true) {
        try out.append(cx.a, try need(T, try item(cx, l.next())));
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (sep.kind != .comma or out.items.len > 1024) return bad;
    }
    return out.items;
}

fn durItem(_: *Cx, t: Token) Error!?f32 {
    const v = timeMs(t) orelse return null;
    if (v < 0) return bad;
    return v;
}
fn delayItem(_: *Cx, t: Token) Error!?f32 {
    return timeMs(t);
}
fn countItem(_: *Cx, t: Token) Error!?f32 {
    if (t.isIdent("infinite")) return std.math.inf(f32);
    const v = values.number(t) orelse return null;
    if (v < 0) return bad;
    return v;
}
fn nameItem(_: *Cx, t: Token) Error!?[]const u8 {
    if (t.kind == .string) return t.text;
    if (t.kind != .ident) return null;
    return t.text;
}
fn dirItem(_: *Cx, t: Token) Error!?c.AnimDirection {
    return tok.kw(c.AnimDirection, t);
}
fn fillItem(_: *Cx, t: Token) Error!?c.FillMode {
    return tok.kw(c.FillMode, t);
}
fn playItem(_: *Cx, t: Token) Error!?c.PlayState {
    return tok.kw(c.PlayState, t);
}
fn propItem(_: *Cx, t: Token) Error!?[]const u8 {
    return if (t.kind == .ident) t.text else null;
}

/// `animation` (transition = false) or `transition` (transition = true) shorthand lists.
fn parseAnimation(cx: *Cx, l: *Lexer, transition: bool) Error!void {
    var names: tok.List([]const u8) = .{};
    var durs: tok.List(f32) = .{};
    var tfs: tok.List(c.TimingFunction) = .{};
    var delays: tok.List(f32) = .{};
    var counts: tok.List(f32) = .{};
    var dirs: tok.List(c.AnimDirection) = .{};
    var fills: tok.List(c.FillMode) = .{};
    var plays: tok.List(c.PlayState) = .{};
    while (true) {
        var name: ?[]const u8 = null;
        var dur: ?f32 = null;
        var delay: ?f32 = null;
        var tf: ?c.TimingFunction = null;
        var count: ?f32 = null;
        var dir: ?c.AnimDirection = null;
        var fill: ?c.FillMode = null;
        var play: ?c.PlayState = null;
        var behavior = false;
        var n: usize = 0;
        while (!isEnd(l.peek())) : (n += 1) {
            const t = l.next();
            if (timeMs(t)) |v| {
                if (dur == null) {
                    if (v < 0) return bad;
                    dur = v;
                } else if (delay == null) delay = v else return bad;
                continue;
            }
            if (tf == null) if (try timingFn(cx, t)) |v| {
                tf = v;
                continue;
            };
            if (transition) {
                if (!behavior and (t.isIdent("allow-discrete") or t.isIdent("normal"))) {
                    behavior = true;
                    continue;
                }
            } else {
                if (count == null and (t.kind == .number or t.isIdent("infinite"))) {
                    count = try need(f32, try countItem(cx, t));
                    continue;
                }
                if (dir == null) if (tok.kw(c.AnimDirection, t)) |v| {
                    dir = v;
                    continue;
                };
                if (fill == null and !t.isIdent("none")) if (tok.kw(c.FillMode, t)) |v| {
                    fill = v;
                    continue;
                };
                if (play == null) if (tok.kw(c.PlayState, t)) |v| {
                    play = v;
                    continue;
                };
            }
            if (name == null and (t.kind == .ident or (!transition and t.kind == .string))) {
                name = t.text;
                continue;
            }
            // a second `none` is the fill mode
            if (!transition and fill == null and t.isIdent("none")) {
                fill = .none;
                continue;
            }
            return bad;
        }
        if (n == 0) return bad;
        try names.append(cx.a, name orelse if (transition) "all" else "none");
        try durs.append(cx.a, dur orelse 0);
        try tfs.append(cx.a, tf orelse c.TimingFunction.ease);
        try delays.append(cx.a, delay orelse 0);
        if (!transition) {
            try counts.append(cx.a, count orelse 1);
            try dirs.append(cx.a, dir orelse .normal);
            try fills.append(cx.a, fill orelse .none);
            try plays.append(cx.a, play orelse .running);
        }
        const sep = l.next();
        if (sep.kind == .eof) break;
        if (names.items.len > 1024) return bad;
    }
    const s = cx.s;
    if (transition) {
        s.transition_property = names.items;
        s.transition_duration = durs.items;
        s.transition_timing_function = tfs.items;
        s.transition_delay = delays.items;
        return;
    }
    s.animation_name = names.items;
    s.animation_duration = durs.items;
    s.animation_timing_function = tfs.items;
    s.animation_delay = delays.items;
    s.animation_iteration_count = counts.items;
    s.animation_direction = dirs.items;
    s.animation_fill_mode = fills.items;
    s.animation_play_state = plays.items;
}

fn timingItem(cx: *Cx, t: Token) Error!?c.TimingFunction {
    return timingFn(cx, t);
}

fn blendItem(_: *Cx, t: Token) Error!?c.BlendMode {
    return tok.kw(c.BlendMode, t);
}

fn maskModeItem(_: *Cx, t: Token) Error!?c.MaskMode {
    return tok.kw(c.MaskMode, t);
}

fn maskBoxItem(_: *Cx, t: Token) Error!?c.BgBox {
    return maskBox(t);
}

fn imageItem(cx: *Cx, t: Token) Error!?c.Image {
    return gradient.image(cx.a, t, &cx.env);
}

/// Consumes any value (properties accepted for compatibility but not used).
fn ignoreRest(l: *Lexer) void {
    while (!l.atEnd()) _ = l.next();
}

// ------------------------------------------------------------------ dispatch
fn sideIndex(p: Prop) usize {
    return switch (p) {
        .top, .marginTop, .paddingTop, .borderTop, .borderTopColor, .borderTopStyle, .borderTopWidth, .borderTopLeftRadius => 0,
        .right, .marginRight, .paddingRight, .borderRight, .borderRightColor, .borderRightStyle, .borderRightWidth, .borderTopRightRadius => 1,
        .bottom, .marginBottom, .paddingBottom, .borderBottom, .borderBottomColor, .borderBottomStyle, .borderBottomWidth, .borderBottomRightRadius => 2,
        else => 3,
    };
}

/// Parses `l` as the value of `p` and stores it into `cx.s`. The whole input must be consumed.
pub fn apply(cx: *Cx, p: Prop, l: *Lexer) Error!void {
    const s = cx.s;
    const env = &cx.env;
    var pbuf: [4]Prop = undefined;
    const phys = physicalPropsOf(p, s, &pbuf);
    if (phys.len != 1 or phys[0] != p) return applyLogical(cx, p, l, phys);
    const ki = kw_index[@backingInt(p)];
    if (ki < kw_count) {
        const e = kw_entries[ki];
        const t = l.next();
        if (t.kind != .ident) return bad;
        const v = tok.matchPacked(t.text, e.names) orelse return bad;
        std.mem.asBytes(s)[e.off] = @intCast(v);
    } else switch (p) {
        .display => s.display = try parseDisplay(l),
        .top, .right, .bottom, .left => s.inset[sideIndex(p)] = try need(c.LengthAuto, values.lengthAuto(l.next(), env)),
        .inset, .margin => {
            const ts = try fourTokens(l);
            const dst = if (p == .inset) &s.inset else &s.margin;
            for (ts, 0..) |t, i| dst[i] = values.lengthAuto(t, env) orelse return bad;
        },
        .zIndex => {
            const t = l.next();
            s.z_index = if (t.isIdent("auto")) null else try need(i32, values.integer(t));
        },
        .width, .height, .minWidth, .minHeight, .maxWidth, .maxHeight => {
            const t = l.next();
            const v = try need(c.Size, values.size(t, env));
            if (isNegative(t)) return bad;
            if (t.isIdent("none") and p != .maxWidth and p != .maxHeight) return bad;
            switch (p) {
                .width => s.width = v,
                .height => s.height = v,
                .minWidth => s.min_width = v,
                .minHeight => s.min_height = v,
                .maxWidth => s.max_width = v,
                else => s.max_height = v,
            }
        },
        .aspectRatio => s.aspect_ratio = try parseAspect(l),
        .overflow => {
            const x = try kwNext(c.Overflow, l);
            s.overflow_x = x;
            s.overflow_y = if (l.atEnd()) x else try kwNext(c.Overflow, l);
        },
        .marginTop, .marginRight, .marginBottom, .marginLeft => s.margin[sideIndex(p)] = try need(c.LengthAuto, values.lengthAuto(l.next(), env)),
        .padding => for (try fourTokens(l), 0..) |t, i| {
            s.padding[i] = try paddingValue(cx, t);
        },
        .paddingTop, .paddingRight, .paddingBottom, .paddingLeft => s.padding[sideIndex(p)] = try paddingValue(cx, l.next()),
        .gap, .rowGap, .columnGap => {
            const a = l.next();
            const r: LP = if (a.isIdent("normal")) .{} else try lp(cx, a);
            var col = r;
            if (p == .gap and !l.atEnd()) {
                const b = l.next();
                col = if (b.isIdent("normal")) .{} else try lp(cx, b);
            }
            switch (p) {
                .gap => {
                    s.row_gap = r;
                    s.column_gap = col;
                },
                .rowGap => s.row_gap = r,
                else => s.column_gap = r,
            }
        },
        .flex => try parseFlex(cx, l),
        .flexGrow => s.flex_grow = try parseNonNegNumber(l.next()),
        .flexShrink => s.flex_shrink = try parseNonNegNumber(l.next()),
        .flexBasis => s.flex_basis = try need(c.FlexBasis, try parseFlexBasis(cx, l.next())),
        .flexFlow => {
            var d: ?c.FlexDirection = null;
            var w: ?c.FlexWrap = null;
            while (!l.atEnd()) {
                const t = l.next();
                if (d == null) if (tok.kw(c.FlexDirection, t)) |v| {
                    d = v;
                    continue;
                };
                if (w == null) if (tok.kw(c.FlexWrap, t)) |v| {
                    w = v;
                    continue;
                };
                return bad;
            }
            if (d == null and w == null) return bad;
            s.flex_direction = d orelse .row;
            s.flex_wrap = w orelse .nowrap;
        },
        .justifyContent, .alignContent, .alignItems, .justifyItems, .alignSelf, .justifySelf => {
            const content = p == .justifyContent or p == .alignContent;
            const mask: AMask = if (content) content_mask else if (p == .alignItems or p == .justifyItems) items_mask else self_mask;
            const a = try parseAlign(l, mask, content);
            switch (p) {
                .justifyContent => setAlign(s, &s.justify_content, safe_justify_content, a),
                .alignContent => setAlign(s, &s.align_content, safe_align_content, a),
                .alignItems => setAlign(s, &s.align_items, safe_align_items, a),
                .justifyItems => setAlign(s, &s.justify_items, safe_justify_items, a),
                .alignSelf => setAlign(s, &s.align_self, safe_align_self, a),
                else => setAlign(s, &s.justify_self, safe_justify_self, a),
            }
        },
        .placeContent, .placeItems, .placeSelf => {
            // `<align> <justify>?`: one value sets both
            const content = p == .placeContent;
            const mask: AMask = if (content) content_mask else if (p == .placeItems) items_mask else self_mask;
            const a = try parseAlign(l, mask, content);
            const j = if (l.atEnd()) a else try parseAlign(l, mask, content);
            switch (p) {
                .placeContent => {
                    setAlign(s, &s.align_content, safe_align_content, a);
                    setAlign(s, &s.justify_content, safe_justify_content, j);
                },
                .placeItems => {
                    setAlign(s, &s.align_items, safe_align_items, a);
                    setAlign(s, &s.justify_items, safe_justify_items, j);
                },
                else => {
                    setAlign(s, &s.align_self, safe_align_self, a);
                    setAlign(s, &s.justify_self, safe_justify_self, j);
                },
            }
        },
        .order => s.order = try need(i32, values.integer(l.next())),
        .gridTemplateColumns => s.grid_template_columns = try parseTemplate(cx, l),
        .gridTemplateRows => s.grid_template_rows = try parseTemplate(cx, l),
        .gridAutoColumns => s.grid_auto_columns = try parseAutoTracks(cx, l),
        .gridAutoRows => s.grid_auto_rows = try parseAutoTracks(cx, l),
        .gridAutoFlow => {
            var f: c.GridAutoFlow = .{};
            var dir = false;
            var n: usize = 0;
            while (!l.atEnd()) {
                const t = l.next();
                n += 1;
                if (!dir and (t.isIdent("row") or t.isIdent("column"))) {
                    dir = true;
                    f.column = t.isIdent("column");
                } else if (!f.dense and t.isIdent("dense")) {
                    f.dense = true;
                } else return bad;
            }
            if (n == 0) return bad;
            s.grid_auto_flow = f;
        },
        .gridRowStart, .gridColumnStart, .gridRowEnd, .gridColumnEnd => {
            var n: usize = 0;
            const v = try gridLines(l, 1, &n);
            const idx: usize = switch (p) {
                .gridRowStart => 0,
                .gridColumnStart => 1,
                .gridRowEnd => 2,
                else => 3,
            };
            setLine(s, idx, v[0]);
        },
        .gridColumn, .gridRow => {
            var n: usize = 0;
            const v = try gridLines(l, 2, &n);
            const base: usize = if (p == .gridRow) 0 else 1;
            setLine(s, base, v[0]);
            // (takumi: an omitted end line is auto even after a lone custom-ident; grid-area copies it)
            setLine(s, base + 2, if (n > 1) v[1] else .{});
        },
        .gridArea => {
            var n: usize = 0;
            const v = try gridLines(l, 4, &n);
            const cs = if (n > 1) v[1] else identOr(v[0]);
            setLine(s, 0, v[0]);
            setLine(s, 1, cs);
            setLine(s, 2, if (n > 2) v[2] else identOr(v[0]));
            setLine(s, 3, if (n > 3) v[3] else identOr(cs));
        },
        .gridTemplateAreas => s.grid_template_areas = try parseAreas(cx, l),
        .gridTemplate => try parseGridTemplate(cx, l),
        .grid => try parseGrid(cx, l),
        .backgroundPositionX, .backgroundPositionY => try parsePosAxis(cx, l, p == .backgroundPositionY),
        .backgroundBlendMode => if (comptime cfg.effects) {
            s.background_blend_mode = try listOf(c.BlendMode, cx, l, blendItem);
        } else ignoreRest(l),
        .backgroundAttachment, .willChange, .pointerEvents, .cursor, .userSelect, .WebkitUserSelect, .transitionBehavior, .maskComposite, .WebkitMaskComposite => ignoreRest(l),
        .borderSpacing => if (comptime cfg.tables) {
            s.border_spacing = try parseBorderSpacing(cx, l);
        } else ignoreRest(l),
        .verticalAlign => s.vertical_align = try parseVerticalAlign(cx, l.next()),
        .contain => s.contain = try parseContain(l),
        .content => if (comptime cfg.generated) {
            s.content = try parseContent(l);
        } else ignoreRest(l),
        .counterReset => if (comptime cfg.generated) {
            s.counter_reset = try parseCounters(l);
        } else ignoreRest(l),
        .counterIncrement => if (comptime cfg.generated) {
            s.counter_increment = try parseCounters(l);
        } else ignoreRest(l),
        .counterSet => if (comptime cfg.generated) {
            s.counter_set = try parseCounters(l);
        } else ignoreRest(l),
        .listStyle => if (comptime cfg.generated) try parseListStyle(cx, l) else ignoreRest(l),
        .listStyleType => if (comptime cfg.generated) {
            s.list_style_type = try need(c.ListStyleType, try listStyleTypeValue(l.next()));
        } else ignoreRest(l),
        .listStyleImage => if (comptime cfg.generated) {
            s.list_style_image = try need(c.Image, try gradient.image(cx.a, l.next(), env));
        } else ignoreRest(l),
        .backdropFilter, .WebkitBackdropFilter => if (comptime cfg.effects) {
            s.backdrop_filter = try parseFilter(cx, l);
        } else ignoreRest(l),
        .clipPath, .WebkitClipPath => if (comptime cfg.effects) {
            s.clip_path = try parseClipPath(cx, l);
        } else ignoreRest(l),
        .mask, .WebkitMask => if (comptime cfg.effects) try parseBackground(cx, l, true) else ignoreRest(l),
        .maskImage, .WebkitMaskImage => if (comptime cfg.effects) {
            s.mask_image = try listOf(c.Image, cx, l, imageItem);
        } else ignoreRest(l),
        .maskSize, .WebkitMaskSize => if (comptime cfg.effects) {
            s.mask_size = try bgList(c.BgSize, .size, cx, l);
        } else ignoreRest(l),
        .maskPosition, .WebkitMaskPosition => if (comptime cfg.effects) {
            s.mask_position = try bgList([2]LP, .position, cx, l);
        } else ignoreRest(l),
        .maskRepeat, .WebkitMaskRepeat => if (comptime cfg.effects) {
            s.mask_repeat = try bgList([2]c.BgRepeat, .repeat, cx, l);
        } else ignoreRest(l),
        .maskClip, .WebkitMaskClip => if (comptime cfg.effects) {
            s.mask_clip = try listOf(c.BgBox, cx, l, maskBoxItem);
        } else ignoreRest(l),
        .maskOrigin, .WebkitMaskOrigin => if (comptime cfg.effects) {
            s.mask_origin = try listOf(c.BgBox, cx, l, maskBoxItem);
        } else ignoreRest(l),
        .maskMode => if (comptime cfg.effects) {
            s.mask_mode = try listOf(c.MaskMode, cx, l, maskModeItem);
        } else ignoreRest(l),
        .textUnderlineOffset => {
            const t = l.next();
            s.text_underline_offset = if (t.isIdent("auto")) null else (try lp(cx, t)).resolve(s.font_size);
        },
        .textUnderlinePosition => s.text_underline_position = try parseUnderlinePosition(l),
        .WebkitTextFillColor => s.webkit_text_fill_color = try colorOf(l.next()),
        .paintOrder => s.paint_order = try parsePaintOrder(l),
        .fontStretch => s.font_stretch = try need(f32, fontStretchValue(l.next())),
        .fontFeatureSettings => s.font_feature_settings = try parseFeatures(cx, l),
        .fontVariationSettings => if (comptime cfg.variable_fonts) {
            s.font_variation_settings = try parseVariations(cx, l);
        } else ignoreRest(l),
        .fontVariant, .fontVariantLigatures, .fontVariantNumeric, .fontVariantEastAsian => {
            const which: u8 = switch (p) {
                .fontVariant => 0x1f,
                .fontVariantLigatures => 1,
                .fontVariantNumeric => 2,
                else => 4,
            };
            const v = try parseVariants(l, which, p == .fontVariant or p == .fontVariantLigatures);
            if (which & 1 != 0) s.font_variant_ligatures = v.lig;
            if (which & 2 != 0) s.font_variant_numeric = v.num;
            if (which & 4 != 0) s.font_variant_east_asian = v.ea;
            if (which & 8 != 0) s.font_variant_caps = v.caps;
            if (which & 16 != 0) s.font_variant_position = v.pos;
        },
        .fontSynthesis => s.font_synthesis = try parseSynthesis(l),
        .fontSynthesisWeight, .fontSynthesisStyle, .fontSynthesisSmallCaps => {
            const t = l.next();
            const on = if (t.isIdent("auto")) true else if (t.isIdent("none")) false else return bad;
            switch (p) {
                .fontSynthesisWeight => s.font_synthesis.weight = on,
                .fontSynthesisStyle => s.font_synthesis.style = on,
                else => s.font_synthesis.small_caps = on,
            }
        },
        .animation => if (comptime cfg.animation) try parseAnimation(cx, l, false) else ignoreRest(l),
        .animationName => if (comptime cfg.animation) {
            s.animation_name = try listOf([]const u8, cx, l, nameItem);
        } else ignoreRest(l),
        .animationDuration => if (comptime cfg.animation) {
            s.animation_duration = try listOf(f32, cx, l, durItem);
        } else ignoreRest(l),
        .animationTimingFunction => if (comptime cfg.animation) {
            s.animation_timing_function = try listOf(c.TimingFunction, cx, l, timingItem);
        } else ignoreRest(l),
        .animationDelay => if (comptime cfg.animation) {
            s.animation_delay = try listOf(f32, cx, l, delayItem);
        } else ignoreRest(l),
        .animationIterationCount => if (comptime cfg.animation) {
            s.animation_iteration_count = try listOf(f32, cx, l, countItem);
        } else ignoreRest(l),
        .animationDirection => if (comptime cfg.animation) {
            s.animation_direction = try listOf(c.AnimDirection, cx, l, dirItem);
        } else ignoreRest(l),
        .animationFillMode => if (comptime cfg.animation) {
            s.animation_fill_mode = try listOf(c.FillMode, cx, l, fillItem);
        } else ignoreRest(l),
        .animationPlayState => if (comptime cfg.animation) {
            s.animation_play_state = try listOf(c.PlayState, cx, l, playItem);
        } else ignoreRest(l),
        .transition => if (comptime cfg.animation) try parseAnimation(cx, l, true) else ignoreRest(l),
        .transitionProperty => if (comptime cfg.animation) {
            s.transition_property = try listOf([]const u8, cx, l, propItem);
        } else ignoreRest(l),
        .transitionDuration => if (comptime cfg.animation) {
            s.transition_duration = try listOf(f32, cx, l, durItem);
        } else ignoreRest(l),
        .transitionTimingFunction => if (comptime cfg.animation) {
            s.transition_timing_function = try listOf(c.TimingFunction, cx, l, timingItem);
        } else ignoreRest(l),
        .transitionDelay => if (comptime cfg.animation) {
            s.transition_delay = try listOf(f32, cx, l, delayItem);
        } else ignoreRest(l),
        .border => {
            const b = try borderParts(cx, l);
            s.border_width = @splat(b.w);
            s.border_style = @splat(b.st);
            s.border_color = @splat(b.col);
        },
        .borderTop, .borderRight, .borderBottom, .borderLeft => {
            const b = try borderParts(cx, l);
            const i = sideIndex(p);
            s.border_width[i] = b.w;
            s.border_style[i] = b.st;
            s.border_color[i] = b.col;
        },
        .borderWidth => for (try fourTokens(l), 0..) |t, i| {
            s.border_width[i] = try need(f32, try lineWidth(cx, t));
        },
        .borderStyle => for (try fourTokens(l), 0..) |t, i| {
            s.border_style[i] = tok.kw(c.BorderStyle, t) orelse return bad;
        },
        .borderColor => for (try fourTokens(l), 0..) |t, i| {
            s.border_color[i] = try colorOf(t);
        },
        .borderTopWidth, .borderRightWidth, .borderBottomWidth, .borderLeftWidth => s.border_width[sideIndex(p)] = try need(f32, try lineWidth(cx, l.next())),
        .borderTopColor, .borderRightColor, .borderBottomColor, .borderLeftColor => s.border_color[sideIndex(p)] = try colorOf(l.next()),
        .borderRadius => s.border_radius = try parseBorderRadius(cx, l),
        .borderTopLeftRadius, .borderTopRightRadius, .borderBottomRightRadius, .borderBottomLeftRadius => s.border_radius[sideIndex(p)] = try radiusPair(cx, l),
        .outline => {
            const b = try borderParts(cx, l);
            s.outline_width = b.w;
            s.outline_style = b.st;
            s.outline_color = b.col;
        },
        .outlineWidth => s.outline_width = try need(f32, try lineWidth(cx, l.next())),
        .outlineStyle => {
            const t = l.next();
            // (takumi has no `outline-style: auto`)
            s.outline_style = tok.kw(c.BorderStyle, t) orelse return bad;
        },
        .outlineColor => {
            const t = l.next();
            // (takumi has no outline-color: auto)
            s.outline_color = try colorOf(t);
        },
        .outlineOffset => {
            // (a <length> in takumi, whose auto is 0; its percentages, of the box width, are not supported)
            const t = l.next();
            s.outline_offset = if (t.isIdent("auto")) 0 else try len(cx, t);
        },
        .backgroundColor => s.background_color = try colorOf(l.next()),
        .backgroundImage => s.background_image = try bgList(c.Image, .image, cx, l),
        .backgroundSize => s.background_size = try bgList(c.BgSize, .size, cx, l),
        .backgroundPosition => s.background_position = try bgList([2]LP, .position, cx, l),
        .backgroundRepeat => s.background_repeat = try bgList([2]c.BgRepeat, .repeat, cx, l),
        .backgroundClip => s.background_clip = try bgList(c.BgBox, .clip, cx, l),
        .backgroundOrigin => s.background_origin = try bgList(c.BgBox, .origin, cx, l),
        .background => try parseBackground(cx, l, false),
        .boxShadow => s.box_shadow = try parseShadows(cx, l, true),
        .textShadow => s.text_shadow = try parseShadows(cx, l, false),
        .opacity => s.opacity = std.math.clamp(try need(f32, values.numberOrPct(l.next())), 0, 1),
        .filter => s.filter = try parseFilter(cx, l),
        .transform => s.transform = try parseTransform(cx, l),
        .translate => {
            const t = l.next();
            if (t.isIdent("none")) {
                s.translate = c.zero2;
            } else {
                const x = try lp(cx, t);
                var y: LP = .{};
                if (!l.atEnd()) y = try lp(cx, l.next());
                s.translate = .{ x, y };
            }
        },
        .rotate => {
            const t = l.next();
            if (t.isIdent("none")) {
                s.rotate = 0;
            } else if (t.isIdent("z")) {
                s.rotate = try angleArg(l.next());
            } else {
                s.rotate = try angleArg(t);
                if (l.peek().isIdent("z")) _ = l.next();
            }
        },
        .scale => {
            const t = l.next();
            if (t.isIdent("none")) {
                s.scale = .{ 1, 1 };
            } else {
                const x = try need(f32, values.numberOrPct(t));
                var y = x;
                if (!l.atEnd()) {
                    y = try need(f32, values.numberOrPct(l.next()));
                    if (!l.atEnd()) _ = try need(f32, values.numberOrPct(l.next()));
                }
                s.scale = .{ x, y };
            }
        },
        .transformOrigin => {
            s.transform_origin = try need([2]LP, values.position(l, env, 2));
            if (!l.atEnd()) _ = try len(cx, l.next()); // z offset ignored
        },
        .objectPosition => s.object_position = try need([2]LP, values.position(l, env, 4)),
        .offset => try offsetShorthand(cx, l),
        .offsetPath => s.offset_path = try offsetPath(cx, l),
        .offsetDistance => s.offset_distance = try lp(cx, l.next()),
        .offsetAnchor => s.offset_anchor = try offsetPosition(cx, l, true),
        .offsetPosition => s.offset_position = try offsetPosition(cx, l, false),
        .offsetRotate => s.offset_rotate = try offsetRotate(l),
        .imageRendering => {
            const t = l.next();
            s.image_rendering = if (t.isIdent("high-quality") or t.isIdent("optimizeQuality"))
                .smooth
            else if (t.isIdent("optimizeSpeed") or t.isIdent("-webkit-optimize-contrast"))
                .pixelated
            else
                tok.kw(c.ImageRendering, t) orelse return bad;
        },
        .color => {
            const v = try colorOf(l.next());
            s.color = v.resolve(cx.parent_color);
        },
        .fontFamily => s.font_family = try parseFamilies(cx, l),
        .fontSize => s.font_size = try need(f32, try fontSizeValue(cx, l.next())),
        .fontWeight => s.font_weight = try need(u16, try weightValue(cx, l.next())),
        .fontStyle => {
            s.font_style = try kwNext(c.FontStyle, l);
            if (s.font_style == .oblique and !l.atEnd()) _ = try angleArg(l.next());
        },
        .font => try parseFontShorthand(cx, l),
        .lineHeight => s.line_height = try lineHeightValue(cx, l.next()),
        .letterSpacing => s.letter_spacing = try spacingValue(cx, l.next()),
        .wordSpacing => s.word_spacing = try spacingValue(cx, l.next()),
        .textAlign => {
            const t = l.next();
            s.text_align = if (t.isIdent("match-parent") or t.isIdent("-webkit-auto")) .start else tok.kw(c.TextAlign, t) orelse return bad;
        },
        .textIndent => {
            s.text_indent = try lp(cx, l.next());
            s.text_indent_flags = 0;
            while (!l.atEnd()) {
                const t = l.next();
                if (t.isIdent("each-line")) s.text_indent_flags |= 1 else if (t.isIdent("hanging")) s.text_indent_flags |= 2 else return bad;
            }
        },
        .widows, .orphans => if (comptime cfg.pdf) {
            // an integer >= 1 (takumi's MinLines)
            const v = try need(i32, values.integer(l.next()));
            if (v < 1) return bad;
            const lines: u8 = @intCast(@min(v, 255));
            if (p == .widows) s.widows = lines else s.orphans = lines;
        } else ignoreRest(l),
        .breakBefore, .breakAfter, .breakInside, .pageBreakBefore, .pageBreakAfter, .pageBreakInside => ignoreRest(l),
        .tabSize => s.tab_size = try parseTabSize(cx, l.next()),
        .textDecoration => try parseTextDecoration(cx, l),
        .textDecorationLine => s.text_decoration_line = try need(c.DecorationLine, try decoLine(l)),
        .textDecorationColor => s.text_decoration_color = try colorOf(l.next()),
        .textDecorationThickness => {
            const t = l.next();
            s.text_decoration_thickness = try need(?f32, try decoThickness(cx, t));
            s.text_decoration_from_font = t.isIdent("from-font");
        },
        .textTransform => {
            var flags: u8 = 0;
            var any = false;
            while (!l.atEnd()) {
                const item = l.next();
                if (item.isIdent("none") and !any and l.atEnd()) {
                    s.text_transform = .none;
                    return;
                }
                const flag: u8 = if (item.isIdent("uppercase")) 1 else if (item.isIdent("lowercase")) 2 else if (item.isIdent("capitalize")) 3 else if (item.isIdent("full-width")) 4 else if (item.isIdent("full-size-kana")) 8 else return bad;
                if ((flags & (if (flag < 4) @as(u8, 3) else flag)) != 0) return bad;
                flags |= flag;
                any = true;
            }
            if (!any) return bad;
            s.text_transform = @fromBackingInt(flags);
        },
        .whiteSpace => try parseWhiteSpace(cx, l),
        .textWrap => try parseTextWrap(cx, l),
        .WebkitLineClamp => {
            s.line_clamp = try lineClampValue(l);
            s.block_ellipsis = .auto;
            s.block_ellipsis_string = "";
        },
        .lineClamp => try parseLineClamp(s, l),
        .WebkitTextStroke => try parseStroke(cx, l),
        .WebkitTextStrokeWidth => s.webkit_text_stroke_width = try need(f32, try lineWidth(cx, l.next())),
        .WebkitTextStrokeColor => s.webkit_text_stroke_color = try colorOf(l.next()),
        .WebkitBoxOrient => _ = tok.matchPacked(l.next().text, "horizontal\x00vertical\x00inline-axis\x00block-axis") orelse return bad,
        .textOverflow => {
            const t = l.next();
            if (t.kind == .string) {
                s.text_overflow = .string;
                s.text_overflow_string = t.text;
            } else {
                s.text_overflow = tok.kw(c.TextOverflow, t) orelse return bad;
                if (s.text_overflow == .string) return bad;
                s.text_overflow_string = "";
            }
        },
        else => return bad, // single-keyword properties are handled above
    }
    if (!l.atEnd()) return bad;
}
