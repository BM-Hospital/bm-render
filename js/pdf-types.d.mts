// PDF option types of bm-render (takumi-pdf `PdfRenderOptions` and friends; names and shapes follow
// takumi-pdf-js 's dts-header.d.ts / export.ts). Re-exported by bm-render/pdf (pdf.d.mts); the `Renderer`
// methods `renderPdf` / `measurePdf` of every entry use them (they throw on builds without the `pdf` feature).
import type { ByteBuf, CssInput, FontLoader, ImageSource, ImagesInput, Limits, Node, Prepared } from "./index.mjs";

/** Image entries and the fetch policy used by PDF resource preparation. */
export type PdfImagesInput = ImagesInput | {
  sources?: ImageSource[];
  fetch?: typeof globalThis.fetch;
  fetchCache?: { get(url: string): Promise<ArrayBuffer> | undefined; set(url: string, value: Promise<ArrayBuffer>): unknown; delete(url: string): unknown };
  throwOnError?: boolean;
  timeout?: number;
  maxBytes?: number;
  allowUrl?: (url: string) => boolean;
  signal?: AbortSignal;
};

/** A page size keyword CSS Paged Media defines, matched case-insensitively. Portrait. */
export type PageSizeName = "a3" | "a4" | "a5" | "b4" | "b5" | "jis-b4" | "jis-b5" | "ledger" | "legal" | "letter";

/** Explicit dimensions in CSS px (96 dpi). */
export type Dimensions = { width: number; height: number };

/** A single-page viewport. Omitting `height` sizes the page to the laid-out content. */
export type ViewportInput = { width: number; height?: number };

/** A page size: a preset name or explicit {@link Dimensions}. */
export type PageSize = PageSizeName | (string & {}) | Dimensions;

/**
 * One side of a page margin: a length in CSS px, or `"auto"` to fit the band that draws on that side.
 * `"auto"` never goes below the 37.8 px a page starts with, and the left and right sides hold no band,
 * so they land on it.
 */
export type PageMarginSide = number | "auto";

/** A page margin: one value for all sides, or per-side values (a side left out is `auto`). */
export type PageMargin = PageMarginSide | { top?: PageMarginSide; right?: PageMarginSide; bottom?: PageMarginSide; left?: PageMarginSide };

/** A band on a page: a node tree, an HTML string, or `false` for none. */
/**
 * A header / footer: a node tree, HTML, or `false` (none). As takumi-pdf, anything else goes through `fromJsx`: a
 * JSX element tree, and `true` / numbers / other objects written as their text.
 */
export type Band = Node | string | false | { $typeof: symbol; type: unknown; props: Record<string, unknown> };

/** What some pages draw instead of the document's own bands. A field left out falls through. */
export type PageOverride = { header?: Band; footer?: Band };

/** Overrides keyed by the pages they cover. `first` and `last` win over `odd` and `even`. */
export type PageRules = { first?: PageOverride; last?: PageOverride; odd?: PageOverride; even?: PageOverride };

/** A page to keep: a 1-based page number, or an inclusive span. An unset `from` starts at the first page; an unset `to` runs to the last. */
export type PageRange = number | { from?: number; to?: number };

/** A custom XMP namespace and the properties written under it. */
export type XmpSchema = {
  /** Human-readable name, e.g. "Factur-X PDF/A Extension". */
  name: string;
  /** Namespace prefix the properties are written under, e.g. "fx". */
  prefix: string;
  /** Namespace URI. */
  namespace: string;
  properties: XmpProperty[];
};

export type XmpProperty = {
  /** Property name, e.g. "DocumentFileName". */
  name: string;
  value: string;
  /** What the property means. PDF/A requires one. */
  description: string;
};

export type PdfMetadata = {
  title?: string;
  /** The info dictionary's subject. */
  description?: string;
  authors?: string[];
  keywords?: string[];
  /** The tool that created the source document. */
  creator?: string;
  /** UTC creation date, `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SS`. PDF/A output requires one when `metadata` is set. */
  creationDate?: string;
  /** Custom XMP schemas written into the packet. */
  xmp?: XmpSchema[];
};

/** A file attached to the PDF, shown in the viewer's attachment panel. */
export type Attachment = {
  /** File name in the PDF, e.g. "factur-x.xml". */
  name: string;
  /** The file's bytes, or a string encoded as UTF-8. */
  data: ByteBuf | string;
  /** IANA media type, e.g. "application/xml". The PDF/A-3 levels require one. */
  mimeType?: string;
  /** Human-readable description. The PDF/A-3 levels require one. */
  description?: string;
  /** How the file relates to the document (the PDF/A-3 AFRelationship). Defaults to "unspecified". */
  relationship?: "source" | "data" | "alternative" | "supplement" | "unspecified";
  /** UTC modification date, `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SS`; falls back to `metadata.creationDate`. The PDF/A-3 levels require one. */
  modificationDate?: string;
};

/** An attachment under the PDF/A-3 levels, which require the descriptive fields. */
export type ArchivalAttachment = Attachment & { mimeType: string; description: string };

/** PDF/A conformance level. Validation failures reject the render. */
export type Pdfa = "2a" | "2b" | "2u" | "3a" | "3b" | "3u" | "4" | "4f";

/** Structure-tree emission: off, on (default), or validated against an accessibility standard. */
export type Tagged = boolean | "ua1" | "ua2";

/** What a character no registered font covers turns into on the page. */
export type UncoveredText = "error" | "placeholder" | "blank";

/** Paged output (the default): content flows across pages of `size`, like Puppeteer's `page.pdf()`. */
type PagedOptions = {
  viewport?: never;
  /** Page size. Defaults to A4. */
  size?: PageSize;
  /** Swaps the page's width and height, including explicit sizes. */
  landscape?: boolean;
  /** Page margin. Defaults to `"auto"` on every side. */
  margin?: PageMargin;
  /** Band repeated at the top of every page. Nodes classed `pageNumber` / `totalPages` receive the counters. */
  header?: Band;
  /** Band repeated at the bottom of every page; same class hooks as `header`. */
  footer?: Band;
  /** What some pages draw differently from the rest. */
  pages?: PageRules;
  /** The pages the output keeps, e.g. `[1, { from: 4, to: 8 }]`. Page counters keep their full-output numbers. */
  pageRanges?: PageRange[];
};

/** Single-page output: a fixed viewport. Mutually exclusive with the paged fields. */
type ViewportOptions = {
  viewport: ViewportInput;
  size?: never;
  landscape?: never;
  margin?: never;
  header?: never;
  footer?: never;
  pages?: never;
  pageRanges?: never;
};

/**
 * Standards conformance. Invalid combinations are type errors (and runtime errors): the `a` levels imply a
 * structure tree so `tagged: false` is rejected, PDF/UA-1 is PDF 1.7-only and PDF/UA-2 is PDF 2.0-only so
 * each pairs with its own PDF/A levels, and only the PDF/A-3 levels, PDF/A-4f (or plain PDF) accept attachments.
 */
type ConformanceOptions =
  | { pdfa?: never; tagged?: Tagged; attachments?: Attachment[] }
  | { pdfa: "2b" | "2u"; tagged?: boolean | "ua1"; attachments?: never }
  | { pdfa: "2a"; tagged?: true | "ua1"; attachments?: never }
  | { pdfa: "3b" | "3u"; tagged?: boolean | "ua1"; attachments?: ArchivalAttachment[] }
  | { pdfa: "3a"; tagged?: true | "ua1"; attachments?: ArchivalAttachment[] }
  | { pdfa: "4"; tagged?: boolean | "ua2"; attachments?: never }
  | { pdfa: "4f"; tagged?: boolean | "ua2"; attachments?: ArchivalAttachment[] };

export type PdfRenderOptions = (PagedOptions | ViewportOptions) &
  ConformanceOptions & {
    /**
     * Fonts registered before rendering, once per renderer (deduped across calls, as takumi-pdf). The sync
     * methods take bytes and `{ data: bytes }` entries; a URL, a promise or a lazy `data()` loader needs the
     * async API.
     */
    fonts?: FontLoader[] | Promise<FontLoader[]>;
    /** Pre-fetched images for `src` URLs in the tree (and its bands), e.g. `[{ src: "https://…/logo.png", data: bytes }]`. */
    images?: PdfImagesInput;
    /** CSS to apply before layout (the `css` feature: standard / full / pdf). */
    css?: CssInput | readonly CssInput[];
    /** CSS custom properties for `:root`. A name without the `--` prefix gains it. */
    cssVariables?: Record<string, string>;
    /** Per-render font stack: ordered family names used as the fallback chain. */
    fontFamilies?: string[];
    /** @internal The `@font-face` files `prepare` failed to download or decode. */
    failedFontFiles?: string[];
    /** Default BCP-47 language tag applied to the root. */
    lang?: string;
    /** Document metadata; `lang` doubles as the metadata language. */
    metadata?: PdfMetadata;
    /** Generates a PDF outline (bookmarks) from `h1`–`h6` headings. */
    outline?: boolean;
    /** The paper colour as a CSS colour, painted under everything on every page. Unset leaves the page empty. */
    backgroundColor?: string;
    /**
     * What a character no registered font covers turns into: `"error"` (default) fails the render naming it,
     * `"placeholder"` draws the font's glyph 0, and `"blank"` draws nothing. `"placeholder"` is rejected with
     * any `pdfa` level or `tagged: "ua1"` / `"ua2"`, which forbid glyph 0.
     */
    uncoveredText?: UncoveredText;
    /** Stops the render before it reads the document or draws it. */
    signal?: AbortSignal;
    /** bm-render resource limits (see `Limits`): an image source over them fails the render. */
    limits?: Limits;
  };

/** Options for `measurePdf` / `PdfRenderer.measure`: page geometry (or a viewport) plus layout resources. Margins do not affect the result. */
export type PdfMeasureOptions = (
  | { size?: PageSize; landscape?: boolean; viewport?: never }
  | { viewport: ViewportInput; size?: never; landscape?: never }
) & Pick<PdfRenderOptions, "fonts" | "images" | "css" | "cssVariables" | "fontFamilies" | "lang" | "limits"> & {
    /** `Renderer.measurePdf` stops on an aborted one; `PdfRenderer.measure` does not read it (as takumi-pdf's `measure`). */
    signal?: AbortSignal;
  };

/** A node tree's laid-out size in CSS px. */
export type MeasuredSize = { width: number; height: number };

/** Prepared handle accepted by the PDF render / measure methods (same handle as `Renderer.prepare`). */
export type PdfPrepared = Prepared;
