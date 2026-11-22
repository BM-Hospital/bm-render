//! `zig build fuzz -- [target...|all] [--seconds S] [--seed N] [--slow-ms MS] [--out DIR] [--replay FILE]`:
//! a deterministic mutation driver for the targets of src/fuzz.zig (ReleaseSafe). It needs no
//! fuzzing runtime and complements `zig build test --fuzz`: mutations include large span
//! repetitions and splices, which find quadratic / allocation blow-ups that coverage guidance
//! rarely reaches. On a panic or a hang (an input still running after 20 x `fuzz.slow_ns`) the
//! current input is written to `<out>/crash-<target>.bin` (Linux); an input slower than
//! `fuzz.slow_ns` (or `--slow-ms`) is saved as `<out>/slow-<target>-<n>.bin` and the run fails. The run is
//! deterministic for a given `--seed`.
const std = @import("std");
const fuzz = @import("fuzz.zig");

/// Feature switches for modules (`@import("root").bm_config`), as in src/root.zig.
pub const bm_config = @import("config.zig");

var started_ns = std.atomic.Value(i64).init(0);
/// The input being run, and where to dump it (NUL-terminated) on a panic or hang.
var cur_input: []const u8 = "";
var crash_path: [512:0]u8 = @splat(0);

fn dumpInput() void {
    if (@import("builtin").os.tag != .linux) return;
    const linux = std.os.linux;
    const rc = linux.open(&crash_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(rc);
    var off: usize = 0;
    while (off < cur_input.len) {
        const w = linux.write(fd, cur_input[off..].ptr, cur_input.len - off);
        if (linux.errno(w) != .SUCCESS or w == 0) break;
        off += w;
    }
    _ = linux.close(fd);
    std.debug.print("\ninput ({d} bytes) saved to {s}\n", .{ cur_input.len, std.mem.sliceTo(&crash_path, 0) });
}

fn onPanic(msg: []const u8, ra: ?usize) noreturn {
    if (started_ns.load(.acquire) != 0) dumpInput();
    std.debug.defaultPanic(msg, ra);
}
pub const panic = std.debug.FullPanic(onPanic);

fn nowNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn watchdog(io: std.Io) void {
    const hang_ns: i64 = @intCast(fuzz.slow_ns * 20);
    while (true) {
        std.Io.sleep(io, .fromMilliseconds(250), .awake) catch return;
        const s = started_ns.load(.acquire);
        if (s != 0 and nowNs(io) - s > hang_ns) {
            std.debug.print("\nHANG: one input ran for more than {d} s\n", .{@divTrunc(hang_ns, std.time.ns_per_s)});
            dumpInput();
            std.process.exit(3);
        }
    }
}

const Rng = std.Random.DefaultPrng;

/// Tokens worth splicing in for text formats.
const dict = [_][]const u8{
    "<",           ">",                  "</",    "<!--",             "-->",              "&amp;",    "&#x10FFFF;",       "=",                "\"",             "'",
    "{",           "}",                  "(",     ")",                ";",                ":",        ",",                "@media ",          "@layer ",        "@supports ",
    ":is(",        ":has(",              ":not(", ":nth-child(2n+1)", "var(--a)",         "calc(",    "1e38",             "-1e38",            "NaN",            "url(#a)",
    "<g>",         "<use href=\"#a\"/>", "<svg>", "<div>",            "<table>",          "<td>",     "<style>",          "</style>",         "\"children\":[", "{\"type\":\"container\",",
    "\"style\":{", "]",                  "[",     "\x00",             "\xff\xff\xff\xff", "\x7f\xff", "\x80\x00\x00\x00", "\x00\x00\x00\x00", "\xff",           "\\",
};

fn mutate(rng: std.Random, buf: []u8, len_in: usize, seeds: []const []const u8) usize {
    var len = len_in;
    const n = 1 + rng.uintLessThan(u32, 8);
    for (0..n) |_| {
        switch (rng.uintLessThan(u32, 11)) {
            0 => if (len > 0) { // bit flip
                buf[rng.uintLessThan(usize, len)] ^= @as(u8, 1) << rng.int(u3);
            },
            1 => if (len > 0) { // random byte, biased towards the header
                const at = if (rng.boolean()) rng.uintLessThan(usize, @min(len, 64)) else rng.uintLessThan(usize, len);
                buf[at] = rng.int(u8);
            },
            2 => if (len >= 4) { // interesting integer (big or little endian)
                const vals = [_]u32{ 0, 1, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff, 0x10000, 0x7fffffff, 0x80000000, 0xffffffff };
                const v = vals[rng.uintLessThan(usize, vals.len)];
                const at = rng.uintLessThan(usize, len - 3);
                std.mem.writeInt(u32, buf[at..][0..4], v, if (rng.boolean()) .big else .little);
            },
            3 => if (len > 0) { // delete span
                const at = rng.uintLessThan(usize, len);
                const l = @min(len - at, 1 + rng.uintLessThan(usize, 64));
                std.mem.copyForwards(u8, buf[at .. len - l], buf[at + l .. len]);
                len -= l;
            },
            4, 5 => if (len > 0) { // repeat a span k times (quadratic / blow-up hunting)
                const at = rng.uintLessThan(usize, len);
                const l = @min(len - at, 1 + rng.uintLessThan(usize, 32));
                const k = if (rng.uintLessThan(u32, 4) == 0) 1 + rng.uintLessThan(usize, 4000) else 1 + rng.uintLessThan(usize, 8);
                var span: [32]u8 = undefined;
                @memcpy(span[0..l], buf[at..][0..l]);
                for (0..k) |_| {
                    if (len + l > buf.len) break;
                    std.mem.copyBackwards(u8, buf[at + l .. len + l], buf[at..len]);
                    @memcpy(buf[at..][0..l], span[0..l]);
                    len += l;
                }
            },
            6 => { // insert a dictionary token
                const tok = dict[rng.uintLessThan(usize, dict.len)];
                if (len + tok.len <= buf.len) {
                    const at = rng.uintLessThan(usize, len + 1);
                    std.mem.copyBackwards(u8, buf[at + tok.len .. len + tok.len], buf[at..len]);
                    @memcpy(buf[at..][0..tok.len], tok);
                    len += tok.len;
                }
            },
            7 => if (len > 0) { // truncate
                len = rng.uintLessThan(usize, len);
            },
            8 => { // splice: keep a prefix, append the tail of another seed
                const o = seeds[rng.uintLessThan(usize, seeds.len)];
                if (o.len > 0) {
                    const at = rng.uintLessThan(usize, len + 1);
                    const from = rng.uintLessThan(usize, o.len);
                    const l = @min(o.len - from, buf.len - at);
                    @memcpy(buf[at..][0..l], o[from..][0..l]);
                    len = at + l;
                }
            },
            9 => if (len > 2) { // copy a span elsewhere (overwrite)
                const a = rng.uintLessThan(usize, len);
                const b = rng.uintLessThan(usize, len);
                const l = @min(len - @max(a, b), 1 + rng.uintLessThan(usize, 16));
                std.mem.copyForwards(u8, buf[b..][0..l], buf[a..][0..l]);
            },
            else => if (len > 0) { // increment / decrement a byte
                const at = rng.uintLessThan(usize, len);
                buf[at] +%= if (rng.boolean()) 1 else 0xff;
            },
        }
    }
    return len;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var seconds: u64 = 60;
    var seed: u64 = 1;
    var out: []const u8 = "zig-out/fuzz";
    var replay: ?[]const u8 = null;
    var slow_ns: i64 = @intCast(fuzz.slow_ns);
    var targets: std.ArrayList(fuzz.Target) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--seconds")) {
            i += 1;
            seconds = try std.fmt.parseUnsigned(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--seed")) {
            i += 1;
            seed = try std.fmt.parseUnsigned(u64, args[i], 0);
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            out = args[i];
        } else if (std.mem.eql(u8, a, "--slow-ms")) {
            i += 1;
            slow_ns = @as(i64, @intCast(try std.fmt.parseUnsigned(u32, args[i], 10))) * std.time.ns_per_ms;
        } else if (std.mem.eql(u8, a, "--replay")) {
            i += 1;
            replay = args[i];
        } else if (std.mem.eql(u8, a, "all")) {
            for (std.enums.values(fuzz.Target)) |t| try targets.append(gpa, t);
        } else {
            const t = std.meta.stringToEnum(fuzz.Target, a) orelse {
                std.debug.print("unknown target '{s}'; targets:", .{a});
                for (std.enums.values(fuzz.Target)) |t| std.debug.print(" {t}", .{t});
                std.debug.print(" all\n", .{});
                return error.InvalidArgument;
            };
            try targets.append(gpa, t);
        }
    }
    defer targets.deinit(gpa);
    if (targets.items.len == 0) for (std.enums.values(fuzz.Target)) |t| try targets.append(gpa, t);

    const cwd = std.Io.Dir.cwd();
    if (replay) |path| {
        const data = try cwd.readFileAlloc(io, path, gpa, .limited(64 << 20));
        defer gpa.free(data);
        for (targets.items) |t| {
            const t0 = nowNs(io);
            fuzz.run(t, gpa, data);
            std.debug.print("{t}: {d} bytes, {d} ms\n", .{ t, data.len, @divTrunc(nowNs(io) - t0, std.time.ns_per_ms) });
        }
        return;
    }

    try cwd.createDirPath(io, out);
    _ = try std.Thread.spawn(.{}, watchdog, .{io});
    const buf = try gpa.alloc(u8, fuzz.max_input);
    defer gpa.free(buf);
    var failures: u32 = 0;
    for (targets.items) |t| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const all_seeds = try fuzz.seeds(arena.allocator(), t);
        var seeds: std.ArrayList([]const u8) = .empty;
        for (all_seeds) |s| if (s.len <= fuzz.max_input) try seeds.append(arena.allocator(), s);
        const cp = try arena.allocator().print("{s}/crash-{t}.bin", .{ out, t });
        @memcpy(crash_path[0..cp.len], cp);
        crash_path[cp.len] = 0;
        var rng = Rng.init(seed ^ (@as(u64, @backingInt(t)) *% 0x9e3779b97f4a7c15));
        const r = rng.random();
        const deadline = nowNs(io) + @as(i64, @intCast(seconds)) * std.time.ns_per_s;
        var iters: u64 = 0;
        var slowest: i64 = 0;
        var len: usize = 0;
        while (nowNs(io) < deadline) : (iters += 1) {
            // mostly fresh mutations of a seed, sometimes keep mutating the previous input
            if (iters % 4 != 0 or len == 0) {
                const s = seeds.items[r.uintLessThan(usize, seeds.items.len)];
                @memcpy(buf[0..s.len], s);
                len = s.len;
            }
            len = mutate(r, buf, len, seeds.items);
            cur_input = buf[0..len];
            const t0 = nowNs(io);
            started_ns.store(t0, .release);
            fuzz.run(t, gpa, buf[0..len]);
            started_ns.store(0, .release);
            const dt = nowNs(io) - t0;
            slowest = @max(slowest, dt);
            if (dt > slow_ns) {
                failures += 1;
                const p = try arena.allocator().print("{s}/slow-{t}-{d}.bin", .{ out, t, iters });
                try cwd.writeFile(io, .{ .sub_path = p, .data = buf[0..len] });
                std.debug.print("SLOW {t}: {d} bytes took {d} ms -> {s}\n", .{ t, len, @divTrunc(dt, std.time.ns_per_ms), p });
            }
        }
        std.debug.print("{t}: {d} inputs in {d} s, slowest {d} ms\n", .{ t, iters, seconds, @divTrunc(slowest, std.time.ns_per_ms) });
    }
    if (failures != 0) {
        std.debug.print("{d} slow inputs\n", .{failures});
        std.process.exit(1);
    }
}
