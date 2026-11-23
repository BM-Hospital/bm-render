//! Registered font faces and CSS-like family / stretch / style / weight matching, including
//! lazily created instances of variable fonts.
//!
//! Face ids:
//!  * `0 .. count()`             — registered faces, in registration order (every face of a
//!                                 .ttc/.otc gets its own id);
//!  * `instance_base ..`         — instances of variable fonts created on demand by
//!                                 `match` / `matchEx` (a `Font` copy carrying variation
//!                                 coordinates; see `FontCollection.beginFrame` for lifetime).
const std = @import("std");
const ttf = @import("ttf.zig");
const variations = @import("variations.zig");
const Font = ttf.Font;
pub const AxisValue = ttf.AxisValue;

/// Stable handle of a face: an index into `FontCollection.faces`, or `instance_base + slot`
/// for a variable-font instance.
pub const FaceId = u16;

pub const UnicodeRange = struct { start: u21, end: u21 };

/// First id used for variable-font instances.
pub const instance_base: FaceId = 0x8000;
/// Capacity of the instance cache (distinct (face, coordinates) pairs alive at once).
pub const max_instances = 64;
const no_base: FaceId = 0xffff;

pub const RegisterOptions = struct {
    /// Overrides the family read from the `name` table.
    family: ?[]const u8 = null,
    /// Overrides the weight (OS/2 usWeightClass, or the `wght` axis range of a variable font:
    /// with an override the axis is pinned to this value, as in takumi / Blink).
    weight: ?u16 = null,
    /// Overrides the italic flag from OS/2 fsSelection / head.macStyle.
    italic: ?bool = null,
    /// Face index inside a .ttc / .otc; null registers every face of the file.
    face_index: ?u32 = null,
    /// Overrides the width (CSS font-stretch percentage; pins a `wdth` axis).
    width: ?f32 = null,
    /// CSS `unicode-range` for a registered subset; null means the whole Unicode range.
    unicode_range: ?[]const UnicodeRange = null,
    /// A last-resort face (takumi's bundled Geist, `FontResource::last_resort`): matched by its
    /// own family name, otherwise tried after every other registered family.
    last_resort: bool = false,
};

pub const Face = struct {
    font: Font,
    /// Family name (UTF-8). Owned by the registered face; instances borrow their base's.
    family: []u8,
    /// CSS weight. Registered variable face: the default instance's weight. Instance: the
    /// weight it was created for (see `matchEx`), which is what the painter must compare
    /// against to decide on synthetic bold.
    weight: u16,
    italic: bool,
    /// False after `unregister`; ids are never reused before `clear`.
    active: bool = true,
    /// CSS font-stretch percentage (OS/2 usWidthClass, or the `wdth` coordinate).
    width: f32 = 100,
    /// Index of the face inside its file.
    index: u32 = 0,
    /// True for a registered face with an `fvar` table (never for instances).
    variable: bool = false,
    /// Supported ranges: equal to weight / width for static faces and instances, the
    /// `wght` / `wdth` axis ranges for variable faces.
    weight_min: u16 = 0,
    weight_max: u16 = 0,
    width_min: f32 = 100,
    width_max: f32 = 100,
    /// Variable face that can reach italic through an `ital` axis or a negative `slnt`.
    can_italic: bool = false,
    /// Instances: the registered face they were derived from.
    base: FaceId = no_base,
    /// Null means unrestricted; a present empty list matches no character.
    unicode_range: ?[]UnicodeRange = null,
    /// See `RegisterOptions.last_resort`.
    last_resort: bool = false,
};

/// Request for `FontCollection.matchEx`.
pub const MatchRequest = struct {
    /// font-family list (ASCII case-insensitive).
    families: []const []const u8 = &.{},
    /// font-weight 1..1000; drives the `wght` axis.
    weight: u16 = 400,
    italic: bool = false,
    /// font-stretch in percent; drives the `wdth` axis.
    stretch: f32 = 100,
    /// Font size in CSS px for `font-optical-sizing: auto` (drives `opsz`); 0 = keep the
    /// axis default (`font-optical-sizing: none`).
    size: f32 = 0,
    /// font-variation-settings; applied after (overriding) the values derived above.
    variations: []const AxisValue = &.{},
};

pub const FaceInfo = struct {
    id: FaceId,
    weight: u16,
    weight_min: u16,
    weight_max: u16,
    italic: bool,
    width: f32,
    index: u32,
    variable: bool,
};

pub const FamilyInfo = struct {
    /// Borrowed from the collection (valid until the family is unregistered).
    name: []const u8,
    faces: []FaceInfo,
};

pub const Registered = struct { first: FaceId, count: u16 };

const Instances = struct {
    len: u16 = 0,
    epoch: u32 = 1,
    evictions: u32 = 0,
    stamp: [max_instances]u32 = @splat(0),
    faces: [max_instances]Face = undefined,
};

const width_classes = [_]f32{ 50, 62.5, 75, 87.5, 100, 112.5, 125, 150, 200 };

pub const FontCollection = struct {
    faces: std.ArrayList(Face) = .empty,
    /// Instance cache; allocated when the first variable font is registered. Mutated through
    /// the pointer by `match` (which takes a const collection).
    inst: ?*Instances = null,

    /// Frees everything. `alloc` must be the allocator used for `register`.
    pub fn deinit(self: *FontCollection, alloc: std.mem.Allocator) void {
        self.clear(alloc);
        self.faces.deinit(alloc);
        if (self.inst) |in| alloc.destroy(in);
        self.inst = null;
    }

    /// Registers the faces of a font file and returns the id of the first one: every face
    /// of a .ttc / .otc unless `opts.face_index` selects one (their ids are consecutive, see
    /// `registerAll` for the count). `data` is NOT copied and must stay alive until the faces
    /// are unregistered. `alloc` should be a long-lived allocator (the same one for every
    /// call on this collection). The data must be sfnt (TrueType or CFF flavoured); WOFF /
    /// WOFF2 have to be decoded first.
    pub fn register(self: *FontCollection, alloc: std.mem.Allocator, data: []const u8, opts: RegisterOptions) !FaceId {
        return (try self.registerAll(alloc, data, opts)).first;
    }

    /// Like `register`, also returning how many faces were added. Faces of a collection that
    /// fail to parse are skipped; an error is returned only when no face could be registered.
    pub fn registerAll(self: *FontCollection, alloc: std.mem.Allocator, data: []const u8, opts: RegisterOptions) !Registered {
        const n: u32 = if (opts.face_index != null) 1 else @max(1, ttf.faceCount(data));
        const first = self.faces.items.len;
        errdefer self.truncate(alloc, first);
        var first_err: ?ttf.Error = null;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const index = opts.face_index orelse i;
            const parsed = Font.init(data, index) catch |e| {
                if (first_err == null) first_err = e;
                continue;
            };
            try self.addFace(alloc, parsed, index, opts);
        }
        const added = self.faces.items.len - first;
        if (added == 0) return first_err orelse error.InvalidFont;
        return .{ .first = @intCast(first), .count = @intCast(added) };
    }

    fn truncate(self: *FontCollection, alloc: std.mem.Allocator, len: usize) void {
        while (self.faces.items.len > len) {
            const f = self.faces.pop().?;
            if (f.active) alloc.free(f.family);
            if (f.unicode_range) |ranges| alloc.free(ranges);
        }
    }

    fn addFace(self: *FontCollection, alloc: std.mem.Allocator, parsed: Font, index: u32, opts: RegisterOptions) !void {
        if (self.faces.items.len >= instance_base - 1) return error.OutOfMemory;
        var buf: [128]u8 = undefined;
        const fam = opts.family orelse parsed.familyName(&buf);
        var fc: Face = .{
            .font = parsed,
            .family = &.{},
            .weight = parsed.weightClass(),
            .italic = opts.italic orelse parsed.isItalic(),
            .index = index,
            .last_resort = opts.last_resort,
        };
        const wc = parsed.widthClass();
        if (wc >= 1 and wc <= 9) fc.width = width_classes[wc - 1];
        fc.weight_min = fc.weight;
        fc.weight_max = fc.weight;
        fc.width_min = fc.width;
        fc.width_max = fc.width;
        if (ttf.enable_variations and parsed.isVariable()) {
            fc.variable = true;
            if (parsed.findAxis("wght")) |a| {
                fc.weight = toWeight(a.default);
                fc.weight_min = toWeight(a.min);
                fc.weight_max = @max(fc.weight_min, toWeight(a.max));
            }
            if (parsed.findAxis("wdth")) |a| {
                fc.width = a.default;
                fc.width_min = a.min;
                fc.width_max = @max(a.min, a.max);
            }
            if (parsed.findAxis("ital")) |a| fc.can_italic = a.min <= 1 and a.max >= 1;
            if (parsed.findAxis("slnt")) |a| {
                if (a.min < 0) fc.can_italic = true;
            }
            if (self.inst == null) {
                const in = try alloc.create(Instances);
                in.len = 0;
                in.epoch = 1;
                in.evictions = 0;
                in.stamp = @splat(0);
                self.inst = in;
            }
        }
        if (opts.weight) |w| {
            fc.weight = w;
            fc.weight_min = w;
            fc.weight_max = w;
        }
        if (opts.width) |w| {
            fc.width = w;
            fc.width_min = w;
            fc.width_max = w;
        }
        fc.family = try alloc.dupe(u8, fam);
        errdefer alloc.free(fc.family);
        if (opts.unicode_range) |ranges| {
            fc.unicode_range = try alloc.dupe(UnicodeRange, ranges);
            errdefer alloc.free(fc.unicode_range.?);
        }
        try self.faces.append(alloc, fc);
    }

    fn toWeight(v: f32) u16 {
        return @intFromFloat(@floor(std.math.clamp(v, 1, 1000) + 0.5));
    }

    /// Deactivates a face (its id stays reserved; the caller may free the font bytes once
    /// every face of the file is unregistered). Instances derived from it are dropped.
    pub fn unregister(self: *FontCollection, alloc: std.mem.Allocator, id: FaceId) void {
        if (id >= self.faces.items.len) return;
        const f = &self.faces.items[id];
        if (!f.active) return;
        if (self.inst) |in| {
            for (in.faces[0..in.len], 0..) |*e, slot| {
                if (e.base == id) {
                    e.active = false;
                    e.base = no_base;
                    e.family = &.{};
                    in.stamp[slot] = 0;
                }
            }
        }
        f.active = false;
        alloc.free(f.family);
        f.family = &.{};
        if (f.unicode_range) |ranges| alloc.free(ranges);
        f.unicode_range = null;
    }

    /// Unregisters every face of a family (ASCII case-insensitive name). Returns whether
    /// any face was removed (takumi `unregisterFont(family)`).
    pub fn unregisterFamily(self: *FontCollection, alloc: std.mem.Allocator, name: []const u8) bool {
        var any = false;
        for (self.faces.items, 0..) |f, i| {
            if (f.active and std.ascii.eqlIgnoreCase(f.family, name)) {
                self.unregister(alloc, @intCast(i));
                any = true;
            }
        }
        return any;
    }

    /// Removes all faces and instances; ids restart at 0.
    pub fn clear(self: *FontCollection, alloc: std.mem.Allocator) void {
        self.truncate(alloc, 0);
        if (self.inst) |in| {
            in.len = 0;
            in.stamp = @splat(0);
        }
    }

    /// Number of registered face ids (inactive ones included, instances excluded).
    pub fn count(self: *const FontCollection) usize {
        return self.faces.items.len;
    }

    /// Lists the active families in registration order with their registered faces
    /// (instances are not listed). Everything is allocated in `alloc` (use an arena, or
    /// release with `freeFamilies`); names are borrowed from the collection.
    pub fn families(self: *const FontCollection, alloc: std.mem.Allocator) ![]FamilyInfo {
        var list: std.ArrayList(FamilyInfo) = .empty;
        errdefer {
            for (list.items) |fi| alloc.free(fi.faces);
            list.deinit(alloc);
        }
        for (self.faces.items, 0..) |f, i| {
            if (!f.active or !self.firstOfFamily(i)) continue;
            var n: usize = 0;
            for (self.faces.items[i..]) |o| {
                if (o.active and std.ascii.eqlIgnoreCase(o.family, f.family)) n += 1;
            }
            const infos = try alloc.alloc(FaceInfo, n);
            errdefer alloc.free(infos);
            n = 0;
            for (self.faces.items[i..], i..) |o, id| {
                if (!o.active or !std.ascii.eqlIgnoreCase(o.family, f.family)) continue;
                infos[n] = .{
                    .id = @intCast(id),
                    .weight = o.weight,
                    .weight_min = o.weight_min,
                    .weight_max = o.weight_max,
                    .italic = o.italic,
                    .width = o.width,
                    .index = o.index,
                    .variable = o.variable,
                };
                n += 1;
            }
            try list.append(alloc, .{ .name = f.family, .faces = infos });
        }
        return list.toOwnedSlice(alloc);
    }

    pub fn freeFamilies(alloc: std.mem.Allocator, list: []FamilyInfo) void {
        for (list) |fi| alloc.free(fi.faces);
        alloc.free(list);
    }

    /// The parsed font of a face. `id` must come from `register`/`match` (out-of-range ids
    /// are clamped to face 0; the collection must not be empty). The pointer stays valid
    /// until the next `register` (registered faces) / until the instance is evicted
    /// (instances: see `beginFrame`).
    pub fn font(self: *const FontCollection, id: FaceId) *const Font {
        return &self.face(id).font;
    }

    pub fn face(self: *const FontCollection, id: FaceId) *const Face {
        if (id >= instance_base) {
            if (self.inst) |in| {
                const slot = id - instance_base;
                if (slot < in.len) return &in.faces[slot];
            }
            return &self.faces.items[0];
        }
        const i = if (id < self.faces.items.len) id else 0;
        return &self.faces.items[i];
    }

    /// Whether a face is permitted to serve `cp` by its registered CSS unicode-range.
    pub fn allows(self: *const FontCollection, id: FaceId, cp: u21) bool {
        const ranges = self.face(id).unicode_range orelse return true;
        for (ranges) |r| if (cp >= r.start and cp <= r.end) return true;
        return false;
    }

    /// Marks the start of a new render / measure pass for the instance cache: instances
    /// handed out before this call may be evicted (their ids reused) once the cache
    /// (`max_instances`) is full; instances handed out after it are never evicted before the
    /// next call. Without any call the cache simply stops creating instances when full and
    /// `match` falls back to the default instance. Cheap; call it once per render.
    pub fn beginFrame(self: *const FontCollection) void {
        if (self.inst) |in| in.epoch +%= 1;
    }

    /// Number of instance ids that were recycled for different coordinates so far. Anything
    /// keyed by FaceId outside the collection (e.g. a glyph mask cache) must be flushed when
    /// this changes (it only changes inside `match` / `matchEx`, and never between two
    /// `beginFrame` calls for ids handed out in between).
    pub fn instanceEvictions(self: *const FontCollection) u32 {
        return if (self.inst) |in| in.evictions else 0;
    }

    /// CSS-like matching. Writes an ordered fallback list into `out` and returns the used prefix:
    /// first the best face (stretch, then style, then CSS font-weight matching) of each
    /// requested family in order (ASCII case-insensitive names), then the best face of every
    /// other registered family in registration order (takumi falls back to all registered
    /// families).
    /// A static face whose weight/italic differ from the request is returned as-is: the caller
    /// can compare `face(id).weight/italic` to synthesise bold/oblique. For a variable font
    /// an instance id is returned, see `matchEx`.
    pub fn match(self: *const FontCollection, fams: []const []const u8, weight: u16, italic: bool, out: []FaceId) []FaceId {
        return self.matchEx(.{ .families = fams, .weight = weight, .italic = italic }, out);
    }

    /// `match` with the full request. Variable fonts are instanced the way takumi / Blink do:
    ///  * `wght` = font-weight clamped to the axis range (or the registered override);
    ///  * `wdth` = font-stretch clamped to the axis range;
    ///  * `ital` = 1 for an italic request when the axis reaches 1, else 0; `slnt` = -14
    ///    (italic) or 0 clamped to the axis range unless `ital` was used;
    ///  * `req.variations` (font-variation-settings) override the above;
    ///  * `opsz` = `req.size` when non-zero and not set explicitly.
    /// The returned id is the registered face itself when that is the default instance,
    /// otherwise an instance face (cached by coordinates). Its `weight` is the clamped
    /// weight — or the requested weight when it exceeds a `wght` range that already reaches
    /// past 400, because Blink never emboldens such a font synthetically; its `italic` is
    /// true when `ital` / `slnt` produced the slant.
    pub fn matchEx(self: *const FontCollection, req: MatchRequest, out: []FaceId) []FaceId {
        var n: usize = 0;
        for (req.families) |fam| {
            if (n >= out.len) break;
            n = self.pushFamily(out, n, fam, &req);
        }
        // (every other family in registration order, the last-resort ones after them)
        for ([_]bool{ false, true }) |last| for (self.faces.items, 0..) |f, i| {
            if (n >= out.len) break;
            if (!f.active or f.last_resort != last or !self.firstOfFamily(i)) continue;
            n = self.pushFamily(out, n, f.family, &req);
        };
        return out[0..n];
    }

    /// Pushes the face of `family` that best matches `req`, together with every other face of the
    /// family registered with the same descriptors: such faces make one composite face (CSS
    /// `unicode-range` subsets registered under one name, weight and style), and a character the
    /// first one lacks is looked up in the others. As in takumi (and CSS Fonts 4 for overlapping
    /// ranges), the face registered last is tried first.
    fn pushFamily(self: *const FontCollection, out: []FaceId, n0: usize, family: []const u8, req: *const MatchRequest) usize {
        const best = self.bestInFamily(family, req) orelse return n0;
        const b = self.faces.items[best];
        var n = n0;
        var i = self.faces.items.len;
        while (i > 0 and n < out.len) {
            i -= 1;
            const f = self.faces.items[i];
            if (!f.active or !std.ascii.eqlIgnoreCase(f.family, family) or !sameDescriptors(f, b)) continue;
            n = push(out, n, self.resolve(@intCast(i), req));
        }
        return n;
    }

    fn sameDescriptors(a: Face, b: Face) bool {
        return a.weight_min == b.weight_min and a.weight_max == b.weight_max and a.italic == b.italic and
            a.can_italic == b.can_italic and a.width_min == b.width_min and a.width_max == b.width_max;
    }

    fn push(out: []FaceId, n: usize, id: FaceId) usize {
        if (std.mem.indexOfScalar(FaceId, out[0..n], id) != null) return n;
        out[n] = id;
        return n + 1;
    }

    /// True when no earlier active face has the family of face `i`.
    fn firstOfFamily(self: *const FontCollection, i: usize) bool {
        const fam = self.faces.items[i].family;
        for (self.faces.items[0..i]) |p| {
            if (p.active and std.ascii.eqlIgnoreCase(p.family, fam)) return false;
        }
        return true;
    }

    fn bestInFamily(self: *const FontCollection, family: []const u8, req: *const MatchRequest) ?FaceId {
        var best: ?FaceId = null;
        var best_score: u64 = std.math.maxInt(u64);
        for (self.faces.items, 0..) |f, i| {
            if (!f.active or !std.ascii.eqlIgnoreCase(f.family, family)) continue;
            const have = std.math.clamp(req.weight, f.weight_min, @max(f.weight_min, f.weight_max));
            var score: u64 = weightDistance(req.weight, have);
            if (f.italic != req.italic and !f.can_italic) score += 1 << 20;
            score += @as(u64, widthDistance(req.stretch, f.width_min, f.width_max)) << 24;
            if (score < best_score) {
                best_score = score;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// Maps a registered face to the instance for `req` (the face itself when static or when
    /// the request lands on the default instance).
    fn resolve(self: *const FontCollection, id: FaceId, req: *const MatchRequest) FaceId {
        const base = &self.faces.items[id];
        if (!ttf.enable_variations or !base.variable) return id;
        const in = self.inst orelse return id;
        const f = &base.font;

        var set: [5 + 16]AxisValue = undefined;
        var n: usize = 0;
        var italic = base.italic;
        var use_ital = false;
        if (f.findAxis("ital")) |a| {
            use_ital = req.italic and a.min <= 1 and a.max >= 1;
            set[n] = .{ .tag = "ital".*, .value = if (use_ital) 1 else 0 };
            n += 1;
            if (use_ital) italic = true;
        }
        const wght = std.math.clamp(req.weight, base.weight_min, @max(base.weight_min, base.weight_max));
        set[n] = .{ .tag = "wght".*, .value = @floatFromInt(wght) };
        n += 1;
        const stretch = if (req.stretch == req.stretch) req.stretch else 100;
        const wdth = @max(base.width_min, @min(stretch, base.width_max));
        set[n] = .{ .tag = "wdth".*, .value = wdth };
        n += 1;
        if (!use_ital) {
            if (f.findAxis("slnt")) |a| {
                const want: f32 = if (req.italic) -14 else 0;
                const v = @max(a.min, @min(want, @max(a.min, a.max)));
                set[n] = .{ .tag = "slnt".*, .value = v };
                n += 1;
                if (req.italic and v < 0) italic = true;
            }
        }
        var explicit_opsz = false;
        for (req.variations[0..@min(req.variations.len, 16)]) |v| {
            if (@as(u32, @bitCast(v.tag)) == @as(u32, @bitCast(@as([4]u8, "opsz".*)))) explicit_opsz = true;
            set[n] = v;
            n += 1;
        }
        if (!explicit_opsz and req.size > 0) {
            set[n] = .{ .tag = "opsz".*, .value = req.size };
            n += 1;
        }

        var coords: [ttf.max_axes]i16 = undefined;
        const nc = variations.normalize(f.fvar, f.avar, set[0..n], &coords);
        var varied = false;
        for (coords[0..nc]) |c| {
            if (c != 0) varied = true;
        }
        const weight: u16 = if (req.weight > base.weight_max and base.weight_max > 400) req.weight else wght;
        if (!varied and weight == base.weight and italic == base.italic) return id;

        var slot: usize = 0;
        find: while (slot < in.len) : (slot += 1) {
            const e = &in.faces[slot];
            if (!e.active or e.base != id or e.weight != weight or e.italic != italic) continue;
            for (coords[0..nc], e.font.coords[0..nc]) |x, y| {
                if (x != y) continue :find;
            }
            in.stamp[slot] = in.epoch;
            return instance_base + @as(FaceId, @intCast(slot));
        }
        if (slot >= max_instances) {
            // evict the least recently used instance of an earlier frame
            var best_age: u32 = 0;
            for (in.stamp, 0..) |st, k| {
                const age = in.epoch -% st;
                if (age > best_age) {
                    best_age = age;
                    slot = k;
                }
            }
            if (slot >= max_instances) return id;
            in.evictions +%= 1;
        } else in.len += 1;
        in.stamp[slot] = in.epoch;
        const e = &in.faces[slot];
        e.* = base.*;
        e.font.coords = coords;
        e.font.varied = varied;
        e.weight = weight;
        e.italic = italic;
        e.width = wdth;
        e.variable = false;
        e.can_italic = false;
        e.weight_min = weight;
        e.weight_max = weight;
        e.width_min = wdth;
        e.width_max = wdth;
        e.base = id;
        return instance_base + @as(FaceId, @intCast(slot));
    }
};

/// Rank of candidate weight `have` for requested weight `want` per the CSS font-weight matching
/// algorithm (lower is better).
pub fn weightDistance(want: u16, have: u16) u32 {
    const w: i32 = want;
    const h: i32 = have;
    if (h == w) return 0;
    const far: i32 = 2000;
    const d: i32 = if (w >= 400 and w <= 500) blk: {
        if (h > w and h <= 500) break :blk h - w; // up to 500 first
        if (h < w) break :blk 500 + (w - h); // then below, descending
        break :blk far + (h - w); // then above 500
    } else if (w < 400) blk: {
        if (h < w) break :blk w - h;
        break :blk far + (h - w);
    } else blk: {
        if (h > w) break :blk h - w;
        break :blk far + (w - h);
    };
    return @intCast(d);
}

/// Rank of a face supporting widths `lo..hi` for the requested font-stretch (CSS: for a
/// request <= 100% narrower faces are tried before wider ones, otherwise the reverse).
fn widthDistance(want_in: f32, lo: f32, hi: f32) u32 {
    const want = if (want_in == want_in) std.math.clamp(want_in, 1, 1000) else 100;
    if (want >= lo and want <= hi) return 0;
    const have = if (want < lo) lo else hi;
    const d: u32 = @intFromFloat(@min(@abs(want - have) * 10, 20000));
    const preferred = if (want <= 100) have < want else have > want;
    return 1 + d + if (preferred) @as(u32, 0) else 30000;
}

test "weight matching" {
    const t = std.testing;
    try t.expect(weightDistance(400, 500) < weightDistance(400, 300));
    try t.expect(weightDistance(400, 300) < weightDistance(400, 700));
    try t.expect(weightDistance(700, 900) < weightDistance(700, 600));
    try t.expect(weightDistance(300, 100) < weightDistance(300, 400));
    try t.expect(weightDistance(500, 400) < weightDistance(500, 600));
}

test "stretch matching" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0), widthDistance(100, 100, 100));
    try t.expectEqual(@as(u32, 0), widthDistance(80, 62, 125));
    // 75% wanted: condensed (62.5) beats normal (100); 125% wanted: 150 beats 100
    try t.expect(widthDistance(75, 62.5, 62.5) < widthDistance(75, 100, 100));
    try t.expect(widthDistance(125, 150, 150) < widthDistance(125, 100, 100));
    try t.expect(widthDistance(100, 87.5, 87.5) < widthDistance(100, 112.5, 112.5));
    try t.expect(widthDistance(std.math.nan(f32), 100, 100) == 0);
}
