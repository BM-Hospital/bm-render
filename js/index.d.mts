// Public API of bm-render (js/index.mjs = `bm-render`; the profile entries bm-render/core, /standard, /full
// add `profile`, `wasmUrl` and a default for init(), see core.d.mts). The node format and options follow
// `@takumi-rs/wasm` 2.20; see the parity table at the top of js/index.mjs.

declare global {
  // `Symbol.dispose` for projects whose `lib` predates esnext.disposable (same declaration as TypeScript 5.2+ / @types/node).
  interface SymbolConstructor {
    readonly dispose: unique symbol;
  }
  // Lets the typings compile without the DOM lib (Node-only projects); merges with lib.dom / workers types.
  namespace WebAssembly {
    interface Module {}
  }
}

import type { PdfMeasureOptions, PdfRenderOptions, MeasuredSize } from "./pdf-types.mjs";

export type ByteBuf = Uint8Array | ArrayBuffer | ArrayBufferView;
/**
 * A fresh Uint8Array that owns its ArrayBuffer (`Uint8Array<ArrayBuffer>` on TypeScript 5.7+, so it can be passed
 * straight to `new Response()` / `Blob`; plain `Uint8Array` on older versions).
 */
export type OutputBytes = ReturnType<Uint8Array["slice"]>;

/** A CSS value: a string as in CSS, or a number (px for lengths, a plain number otherwise). */
export type StyleValue = string | number | null | undefined;

/**
 * CSS declarations with camelCase keys: the properties bm-render parses (src/style/props.zig). Properties
 * of a feature compiled out of the loaded build are accepted and ignored. Custom properties (`"--x"`) and
 * any other key are allowed by the index signature.
 */
export interface Style {
  WebkitBackdropFilter?: StyleValue; WebkitBoxDecorationBreak?: StyleValue; WebkitBoxOrient?: StyleValue;
  WebkitClipPath?: StyleValue; WebkitHyphens?: StyleValue; WebkitLineClamp?: StyleValue; WebkitMask?: StyleValue;
  WebkitMaskClip?: StyleValue; WebkitMaskComposite?: StyleValue; WebkitMaskImage?: StyleValue;
  WebkitMaskOrigin?: StyleValue; WebkitMaskPosition?: StyleValue; WebkitMaskRepeat?: StyleValue;
  WebkitMaskSize?: StyleValue; WebkitTextFillColor?: StyleValue; WebkitTextStroke?: StyleValue;
  WebkitTextStrokeColor?: StyleValue; WebkitTextStrokeWidth?: StyleValue; WebkitUserSelect?: StyleValue;
  alignContent?: StyleValue; alignItems?: StyleValue; alignSelf?: StyleValue; animation?: StyleValue;
  animationDelay?: StyleValue; animationDirection?: StyleValue; animationDuration?: StyleValue;
  animationFillMode?: StyleValue; animationIterationCount?: StyleValue; animationName?: StyleValue;
  animationPlayState?: StyleValue; animationTimingFunction?: StyleValue; aspectRatio?: StyleValue;
  backdropFilter?: StyleValue; background?: StyleValue; backgroundAttachment?: StyleValue;
  backgroundBlendMode?: StyleValue; backgroundClip?: StyleValue; backgroundColor?: StyleValue;
  backgroundImage?: StyleValue; backgroundOrigin?: StyleValue; backgroundPosition?: StyleValue;
  backgroundPositionX?: StyleValue; backgroundPositionY?: StyleValue; backgroundRepeat?: StyleValue;
  backgroundSize?: StyleValue; blockSize?: StyleValue; border?: StyleValue; borderBlock?: StyleValue;
  borderBlockColor?: StyleValue; borderBlockEnd?: StyleValue; borderBlockEndColor?: StyleValue;
  borderBlockEndStyle?: StyleValue; borderBlockEndWidth?: StyleValue; borderBlockStart?: StyleValue;
  borderBlockStartColor?: StyleValue; borderBlockStartStyle?: StyleValue; borderBlockStartWidth?: StyleValue;
  borderBlockStyle?: StyleValue; borderBlockWidth?: StyleValue; borderBottom?: StyleValue;
  borderBottomColor?: StyleValue; borderBottomLeftRadius?: StyleValue; borderBottomRightRadius?: StyleValue;
  borderBottomStyle?: StyleValue; borderBottomWidth?: StyleValue; borderCollapse?: StyleValue;
  borderColor?: StyleValue; borderEndEndRadius?: StyleValue; borderEndStartRadius?: StyleValue;
  borderInline?: StyleValue; borderInlineColor?: StyleValue; borderInlineEnd?: StyleValue;
  borderInlineEndColor?: StyleValue; borderInlineEndStyle?: StyleValue; borderInlineEndWidth?: StyleValue;
  borderInlineStart?: StyleValue; borderInlineStartColor?: StyleValue; borderInlineStartStyle?: StyleValue;
  borderInlineStartWidth?: StyleValue; borderInlineStyle?: StyleValue; borderInlineWidth?: StyleValue;
  borderLeft?: StyleValue; borderLeftColor?: StyleValue; borderLeftStyle?: StyleValue; borderLeftWidth?: StyleValue;
  borderRadius?: StyleValue; borderRight?: StyleValue; borderRightColor?: StyleValue; borderRightStyle?: StyleValue;
  borderRightWidth?: StyleValue; borderSpacing?: StyleValue; borderStartEndRadius?: StyleValue;
  borderStartStartRadius?: StyleValue; borderStyle?: StyleValue; borderTop?: StyleValue; borderTopColor?: StyleValue;
  borderTopLeftRadius?: StyleValue; borderTopRightRadius?: StyleValue; borderTopStyle?: StyleValue;
  borderTopWidth?: StyleValue; borderWidth?: StyleValue; bottom?: StyleValue; boxDecorationBreak?: StyleValue;
  boxShadow?: StyleValue; boxSizing?: StyleValue; captionSide?: StyleValue; clear?: StyleValue;
  clipPath?: StyleValue; color?: StyleValue; columnGap?: StyleValue; contain?: StyleValue; content?: StyleValue;
  counterIncrement?: StyleValue; counterReset?: StyleValue; counterSet?: StyleValue; cursor?: StyleValue;
  direction?: StyleValue; display?: StyleValue; emptyCells?: StyleValue; filter?: StyleValue; flex?: StyleValue;
  flexBasis?: StyleValue; flexDirection?: StyleValue; flexFlow?: StyleValue; flexGrow?: StyleValue;
  flexShrink?: StyleValue; flexWrap?: StyleValue; float?: StyleValue; font?: StyleValue; fontFamily?: StyleValue;
  fontFeatureSettings?: StyleValue; fontKerning?: StyleValue; fontOpticalSizing?: StyleValue; fontSize?: StyleValue;
  fontStretch?: StyleValue; fontStyle?: StyleValue; fontSynthesis?: StyleValue; fontSynthesisSmallCaps?: StyleValue;
  fontSynthesisStyle?: StyleValue; fontSynthesisWeight?: StyleValue; fontVariant?: StyleValue;
  fontVariantCaps?: StyleValue; fontVariantEastAsian?: StyleValue; fontVariantLigatures?: StyleValue;
  fontVariantNumeric?: StyleValue; fontVariantPosition?: StyleValue; fontVariationSettings?: StyleValue;
  fontWeight?: StyleValue; gap?: StyleValue; grid?: StyleValue; gridArea?: StyleValue; gridAutoColumns?: StyleValue;
  gridAutoFlow?: StyleValue; gridAutoRows?: StyleValue; gridColumn?: StyleValue; gridColumnEnd?: StyleValue;
  gridColumnStart?: StyleValue; gridRow?: StyleValue; gridRowEnd?: StyleValue; gridRowStart?: StyleValue;
  gridTemplate?: StyleValue; gridTemplateAreas?: StyleValue; gridTemplateColumns?: StyleValue;
  gridTemplateRows?: StyleValue; height?: StyleValue; hyphens?: StyleValue; imageRendering?: StyleValue;
  inlineSize?: StyleValue; inset?: StyleValue; insetBlock?: StyleValue; insetBlockEnd?: StyleValue;
  insetBlockStart?: StyleValue; insetInline?: StyleValue; insetInlineEnd?: StyleValue; insetInlineStart?: StyleValue;
  isolation?: StyleValue; justifyContent?: StyleValue; justifyItems?: StyleValue; justifySelf?: StyleValue;
  left?: StyleValue; letterSpacing?: StyleValue; lineBreak?: StyleValue; lineClamp?: StyleValue;
  lineHeight?: StyleValue; listStyle?: StyleValue; listStyleImage?: StyleValue; listStylePosition?: StyleValue;
  listStyleType?: StyleValue; margin?: StyleValue; marginBlock?: StyleValue; marginBlockEnd?: StyleValue;
  marginBlockStart?: StyleValue; marginBottom?: StyleValue; marginInline?: StyleValue; marginInlineEnd?: StyleValue;
  marginInlineStart?: StyleValue; marginLeft?: StyleValue; marginRight?: StyleValue; marginTop?: StyleValue;
  mask?: StyleValue; maskClip?: StyleValue; maskComposite?: StyleValue; maskImage?: StyleValue;
  maskMode?: StyleValue; maskOrigin?: StyleValue; maskPosition?: StyleValue; maskRepeat?: StyleValue;
  maskSize?: StyleValue; maskType?: StyleValue; maxBlockSize?: StyleValue; maxHeight?: StyleValue;
  maxInlineSize?: StyleValue; maxWidth?: StyleValue; minBlockSize?: StyleValue; minHeight?: StyleValue;
  minInlineSize?: StyleValue; minWidth?: StyleValue; mixBlendMode?: StyleValue; objectFit?: StyleValue;
  objectPosition?: StyleValue; opacity?: StyleValue; order?: StyleValue; outline?: StyleValue;
  outlineColor?: StyleValue; outlineOffset?: StyleValue; outlineStyle?: StyleValue; outlineWidth?: StyleValue;
  overflow?: StyleValue; overflowBlock?: StyleValue; overflowInline?: StyleValue; overflowWrap?: StyleValue;
  overflowX?: StyleValue; overflowY?: StyleValue; padding?: StyleValue; paddingBlock?: StyleValue;
  paddingBlockEnd?: StyleValue; paddingBlockStart?: StyleValue; paddingBottom?: StyleValue;
  paddingInline?: StyleValue; paddingInlineEnd?: StyleValue; paddingInlineStart?: StyleValue;
  paddingLeft?: StyleValue; paddingRight?: StyleValue; paddingTop?: StyleValue; paintOrder?: StyleValue;
  placeContent?: StyleValue; placeItems?: StyleValue; placeSelf?: StyleValue; pointerEvents?: StyleValue;
  position?: StyleValue; right?: StyleValue; rotate?: StyleValue; rowGap?: StyleValue; scale?: StyleValue;
  tabSize?: StyleValue; tableLayout?: StyleValue; textAlign?: StyleValue; textAlignLast?: StyleValue;
  textDecoration?: StyleValue; textDecorationColor?: StyleValue; textDecorationLine?: StyleValue;
  textDecorationSkipInk?: StyleValue; textDecorationStyle?: StyleValue; textDecorationThickness?: StyleValue;
  textIndent?: StyleValue; textOverflow?: StyleValue; textShadow?: StyleValue; textTransform?: StyleValue;
  textUnderlineOffset?: StyleValue; textUnderlinePosition?: StyleValue; textWrap?: StyleValue;
  textWrapMode?: StyleValue; textWrapStyle?: StyleValue; top?: StyleValue; transform?: StyleValue;
  transformOrigin?: StyleValue; transition?: StyleValue; transitionBehavior?: StyleValue;
  transitionDelay?: StyleValue; transitionDuration?: StyleValue; transitionProperty?: StyleValue;
  transitionTimingFunction?: StyleValue; translate?: StyleValue; unicodeBidi?: StyleValue; userSelect?: StyleValue;
  verticalAlign?: StyleValue; visibility?: StyleValue; whiteSpace?: StyleValue; whiteSpaceCollapse?: StyleValue;
  width?: StyleValue; willChange?: StyleValue; wordBreak?: StyleValue; wordSpacing?: StyleValue;
  wordWrap?: StyleValue; writingMode?: StyleValue; zIndex?: StyleValue;
  [property: string]: StyleValue;
}

export type NodeMetadata = {
  style?: Style;
  /** user-agent style layer, applied below `style` (takumi `preset`) */
  preset?: Style;
  /** Tailwind utility classes (`tw` feature: standard / full) */
  tw?: string;
  /**
   * element name, used only to match type selectors (`p { ... }`, `div > span`) in `css`; it does NOT apply
   * the HTML user-agent default styles of that element to a node tree (set them in `style` / `preset`)
   */
  tagName?: string;
  className?: string;
  id?: string;
  attributes?: Record<string, string>;
  dir?: "ltr" | "rtl" | "auto";
  lang?: string;
};
export type ContainerNode = NodeMetadata & { type: "container"; children?: (Node | null | undefined)[] };
export type TextNode = NodeMetadata & { type: "text"; text: string };
/** Raw pixels as an image source (straight alpha unless `premultiplied`). */
export type RgbaImage = { width: number; height: number; data: ByteBuf; premultiplied?: boolean };
export type ImageNode = NodeMetadata & {
  type: "image";
  /** data: URI, inline `<svg>` markup, a key of the `images` option, encoded bytes, or raw RGBA. */
  src: string | ByteBuf | RgbaImage;
  width?: number;
  height?: number;
};
export type Node = ContainerNode | TextNode | ImageNode;
/** A node tree, `{ json }` (the tree as JSON text) or an HTML string (`html` feature: standard / full). */
export type Source = Node | string | { json: string };

/** An entry of the `images` option: `src` is the key nodes refer to; `data` the encoded bytes. */
export type ImageSource = { src: string; data: ByteBuf | (() => ByteBuf | Promise<ByteBuf>) | Promise<ByteBuf>; cache?: "auto" | "none" };
export type ImagesInput = ImageSource[] | { sources?: ImageSource[]; cache?: "auto" | "none" };
/** takumi rule object (`{ selector, style }`, `{ keyframes, steps }`, ...) or stylesheet text (`css` feature). */
export type CssInput = string | Record<string, unknown>;
export type KeyframesMap = Record<string, Record<string, Style>>;
export type KeyframesRuleList = { name: string; keyframes: { offsets: number[]; declarations: Style }[] }[];
export type Keyframes = KeyframesMap | KeyframesRuleList;

export type FontData = ByteBuf | (() => ByteBuf | Promise<ByteBuf>) | Promise<ByteBuf>;
export type FontDetails = {
  /** family name (default: the font's own family name) */
  name?: string;
  data: FontData;
  /** weight override (default: from the font) */
  weight?: number;
  /** "normal" | "italic" | "oblique" override (default: from the font) */
  style?: string;
  /** PDF async preparation/rendering skips subsets whose characters are unused; image rendering registers eagerly. */
  unicodeRange?: [number, number][] | string;
  /** accepted, ignored */
  subsetOf?: string;
  /** accepted, ignored */
  generic?: string;
};
/** FontDetails whose `data` is available synchronously (registerFont then returns synchronously). */
export type SyncFontDetails = FontDetails & { data: ByteBuf };
/** A font: bytes, a URL (fetched), or details. */
export type FontLoader = string | URL | ByteBuf | FontDetails;
export type RegisteredFace = { weight: number; style: string; width: number; index: number };
export type RegisteredFamily = { name: string; faces: RegisteredFace[]; weight?: number; style?: string };

/** Output formats. `ico` needs the full profile; `raw` = straight RGBA8, width*height*4 bytes. */
export type OutputFormat = "png" | "jpeg" | "webp" | "ico" | "raw";
export type AnimationOutputFormat = "webp" | "apng" | "gif";

export type CommonOptions = {
  devicePixelRatio?: number;
  images?: ImagesInput;
  /** stylesheets / rule objects (`css` feature: standard / full) */
  css?: CssInput[] | string;
  /** deprecated alias of `css` (strings) */
  stylesheets?: string[];
  /** deprecated top-level keyframes */
  keyframes?: Keyframes;
  /** root font-family fallback stack */
  fontFamilies?: string[];
  /** root language (`:lang()`, OpenType language system) */
  lang?: string;
  /** Fonts registered before rendering, once per renderer (deduped across calls). The sync methods take bytes and `{ data: bytes }` entries; a URL, a promise or a lazy `data()` loader needs the async API. */
  fonts?: FontLoader[] | Promise<FontLoader[]>;
  /** checked before rendering */
  signal?: AbortSignal;
  /** accepted, ignored */
  drawDebugBorder?: boolean;
};

export type RenderOptions = CommonOptions & {
  /** output width in pixels (default: the root's laid-out width); `devicePixelRatio` scales CSS lengths, not the image */
  width?: number;
  /** output height in pixels (default: the root's laid-out height) */
  height?: number;
  format?: OutputFormat;
  /** jpeg quality 1..100 (default 75); ignored for webp (always lossless) */
  quality?: number;
  /** accepted, ignored (webp is always lossless, like takumi-wasm) */
  lossless?: boolean;
  /** CSS animation timeline position in ms (integer; default 0) */
  timeMs?: number;
  /** accepted, ignored */
  dithering?: "none" | "ordered-bayer" | "floyd-steinberg";
};

export type AnimationScene = { node: Source; durationMs: number };
export type RenderAnimationOptions = CommonOptions & {
  scenes: AnimationScene[];
  width: number;
  height: number;
  /** frames per second (gif <= 50, webp / apng <= 90) */
  fps: number;
  format?: AnimationOutputFormat;
  /** accepted, ignored */
  quality?: number;
  /** accepted, ignored */
  lossless?: boolean;
};

export type MeasuredTextRun = { text?: string; x: number; y: number; width: number; height: number };
export type MeasuredNode = {
  width: number;
  height: number;
  /** transform: 2D affine matrix [a, b, c, d, e, f] of the node relative to the canvas, not to its parent (e, f = its absolute position) */
  transform: [number, number, number, number, number, number];
  children: MeasuredNode[];
  runs: MeasuredTextRun[];
};

/** Opaque handle returned by `prepare` / `prepareAnimation`. */
export declare class Prepared {
  private constructor();
  /** nominal brand (not a runtime property) */
  private readonly __bmEnginePrepared: true;
}

/** What init() accepts: wasm bytes, a URL / Request / Response to fetch, or a compiled module. */
export type InitInput = string | URL | Request | Response | ArrayBuffer | ArrayBufferView | WebAssembly.Module;
export type InitArgument = InitInput | Promise<InitInput> | { module_or_path: InitInput | Promise<InitInput> };
export type InitSyncArgument = ArrayBuffer | ArrayBufferView | WebAssembly.Module | { module: ArrayBuffer | ArrayBufferView | WebAssembly.Module };
/** The raw exports of the instantiated wasm module (C ABI; not a stable API). */
export type WasmExports = Record<string, unknown>;

/**
 * Instantiates the wasm module. Idempotent: once initialised, further calls resolve to the same instance
 * (their argument is ignored); concurrent calls share one instantiation; a failed call can be retried.
 * The `bm-render` entry needs the argument; bm-render/core, /standard and /full default to their own wasm
 * file. On Node.js every entry is already initialised on import.
 */
export declare function init(input: InitArgument): Promise<WasmExports>;
/** Synchronous variant of init (bytes or a compiled module only). */
export declare function initSync(input: InitSyncArgument): WasmExports;
export default init;
/** accepted and ignored (fixed 8 MiB glyph budget) */
export declare function setGlyphCacheMaxBytes(bytes: number): void;
/** @internal used by bm-render/woff (installs the WOFF -> sfnt converter shared by every entry) */
export declare function setWoffDecoder(fn: ((bytes: Uint8Array) => Uint8Array) | null): void;

/** Optional features of the loaded binary (filled by init / initSync; all false before). */
export type Features = {
  /** stylesheets (`css` option, HTML `<style>`), selectors, @keyframes */
  css: boolean;
  /** Tailwind `tw` utilities */
  tw: boolean;
  /** HTML string sources */
  html: boolean;
  /** SVG images */
  svg: boolean;
  /** WOFF / WOFF2 fonts built in (otherwise see bm-render/woff) */
  woff: boolean;
  variableFonts: boolean;
  /** CFF / CFF2 outlines (.otf) */
  cff: boolean;
  /** clip-path, masks, blend modes, backdrop-filter */
  effects: boolean;
  /** lab / lch / oklab / oklch / color() / color-mix() */
  modernColor: boolean;
  tables: boolean;
  floats: boolean;
  /** WebP (lossless) and GIF image sources */
  webpGifDecode: boolean;
  /** text-wrap: balance / pretty */
  textWrapBalance: boolean;
  /** colour emoji (COLR / CBDT / sbix) */
  colorFonts: boolean;
  /** bidi, Arabic / Hebrew / Indic / Thai shaping */
  complexText: boolean;
  /** CSS animations, renderAnimation, animated image sources */
  animation: boolean;
  /** lossy WebP decode, animated codecs, ICO output */
  extraCodecs: boolean;
  /** renderSvg */
  renderSvg: boolean;
  /** renderPdf / measurePdf: true only on bm-render/pdf (its wasm profile, or the native addon on Node.js); false on every other entry */
  pdf: boolean;
};
export declare const features: Readonly<Features>;
/**
 * Which engine build serves this entry: "wasm", or "native" when `bm-render` on Node.js (Bun, Deno) found the
 * Node-API addon for the platform (optional package `@hunghg255/bm-render-<platform>-<arch>`). Both have the same API and
 * produce the same bytes; natively the async methods run on the thread pool and init() / initSync() are no-ops.
 * Force one with the environment variable BM_RENDER_BACKEND=wasm|native, or by importing `bm-render/full`
 * (always wasm) / `bm-render/native` (native or an import error).
 */
export declare const backend: "wasm" | "native";

export type RendererOptions = {
  /** accepted, ignored (fixed 96 MiB decoded-image budget) */
  cacheMaxBytes?: number;
  /** accepted, ignored (fixed 8 MiB glyph budget) */
  fontCacheMaxBytes?: number;
  /**
   * wasm backend: run the async methods (`render`, `renderAsDataUrl`, `renderSvg`, `measure`, `renderPdf`,
   * `measurePdf`, `renderAnimation`) on up to this many workers (Web Workers; `worker_threads` on Node.js),
   * started on first use, so they do not block the event loop. Same bytes as in-thread; fonts registered on
   * the renderer reach every worker; `signal` drops a queued call and rejects a running one at once (its result
   * is discarded). The `*Sync` methods and `registerFont` stay on the calling thread. `free()` terminates the
   * workers. 0 / omitted: in-thread (the default). Ignored by the native backend, which already renders off-thread.
   */
  workers?: number;
};

export declare class Renderer {
  /** Throws unless the entry is initialised. */
  constructor(options?: RendererOptions);
  /** Registers every face of a TTF / OTF / TTC (WOFF / WOFF2 with the `woff` feature or bm-render/woff). */
  registerFont(font: ByteBuf | SyncFontDetails): RegisteredFamily[];
  /** URL strings, promises and lazy `data` make it asynchronous. */
  registerFont(font: FontLoader | Promise<FontLoader>): RegisteredFamily[] | Promise<RegisteredFamily[]>;
  /** takumi-compatible alias of registerFont */
  loadFont(font: ByteBuf | SyncFontDetails): RegisteredFamily[];
  loadFont(font: FontLoader | Promise<FontLoader>): RegisteredFamily[] | Promise<RegisteredFamily[]>;
  /** Removes every face of the family; true when something was removed. */
  unregisterFont(family: string | { name: string }): boolean;
  clearFonts(): void;

  /** Renders to an encoded image (PNG by default) or raw RGBA. */
  renderSync(source: Source | Prepared, options?: RenderOptions): OutputBytes;
  render(source: Source | Prepared, options?: RenderOptions): Promise<OutputBytes>;
  /** `data:<mime>;base64,...` (not for `raw`) */
  renderAsDataUrlSync(source: Source | Prepared, options?: RenderOptions): string;
  renderAsDataUrl(source: Source | Prepared, options?: RenderOptions): Promise<string>;
  /** SVG document output (`renderSvg` feature: the full profile; otherwise throws) */
  renderSvgSync(source: Source | Prepared, options?: RenderOptions): string;
  renderSvg(source: Source | Prepared, options?: RenderOptions): Promise<string>;
  /** takumi-pdf output: a PDF file (`pdf` feature: bm-render/pdf; otherwise throws "renderPdf is not supported by this build"). */
  renderPdfSync(source: Source | Prepared, options?: PdfRenderOptions): OutputBytes;
  renderPdf(source: Source | Prepared, options?: PdfRenderOptions): Promise<OutputBytes>;
  /** takumi-pdf `measure`: laid-out size in CSS px at the page width (`pdf` feature). */
  measurePdfSync(source: Source | Prepared, options?: PdfMeasureOptions): MeasuredSize;
  measurePdf(source: Source | Prepared, options?: PdfMeasureOptions): Promise<MeasuredSize>;
  /** Layout only. */
  measureSync(source: Source | Prepared, options?: RenderOptions): MeasuredNode;
  measure(source: Source | Prepared, options?: RenderOptions): Promise<MeasuredNode>;

  /** Resolves `fonts` / lazy `images` once; render*, measure* accept the handle. */
  prepare(source: Source, options?: RenderOptions): Promise<Prepared>;
  prepareAnimation(options: RenderAnimationOptions): Promise<Prepared>;
  /** Animated WebP (default) / APNG / GIF (`animation` feature: the full profile). */
  renderAnimationSync(options: RenderAnimationOptions | Prepared): OutputBytes;
  renderAnimation(options: RenderAnimationOptions): Promise<OutputBytes>;
  renderAnimation(prepared: Prepared, options?: { signal?: AbortSignal }): Promise<OutputBytes>;

  /** current wasm linear memory size in bytes (shared by every renderer of this entry); native backend: bytes allocated by the addon */
  memoryBytes(): number;
  /** same as memoryBytes(); 0 before init */
  static memoryBytes(): number;
  /** Releases the renderer's fonts and caches (and terminates its `workers`, rejecting pending calls); later calls on it throw. */
  free(): void;
  /** `using r = new Renderer()` calls free() (falls back to Symbol.for("nodejs.dispose") on old runtimes) */
  [Symbol.dispose](): void;
}
