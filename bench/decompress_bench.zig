//! `zig build bench-decompress`: three decoders on the same frames, one core: the port's
//! `decompressFrameExact`, Zig's `std.compress.zstd.Decompress`, and the original's
//! `ZSTD_decompressDCtx`, the original built from reference/ at -O3 with its x86-64 assembly
//! Huffman loops.
//!
//! The frames are made as Loomwork makes its packs: every input is cut into chunks, and each
//! chunk is one frame, compressed by the port at level 19 with a checksum and its content size.
//! The data sets are BC7 texture blocks and BC5 normal-map blocks (bench/textures/README.md
//! says how they are made), match-heavy text and source code (the Canterbury corpus's text
//! files when it is fetched, and the C sources in reference/lib), and a mixed set standing in
//! for a pack: the chunks of the other sets with test/data's mesh streams and snapshot pack,
//! taken in turn.
//!
//! Each decoder decodes every frame of a set into an output of the frame's size, reused, with
//! one reused context. An untimed warm-up of each decoder checks every output against the
//! input; then the decoders take turns for the timed passes, each of which decodes the set
//! over and over to at least 64 MB, and a row gives the median. MB are 1e6 decoded bytes.
//!
//! Arguments after `--`: `--textures DIR` (default zig-out/bench-textures), the directory of
//! the .bc7 and .bc5 files; `--runs N` (default 9); `--chunk KIB` adds rows of the BC7 set at
//! that chunk size; `--markdown` prints the tables for doc/BENCHMARKS.md.

const std = @import("std");
const builtin = @import("builtin");
const zstd = @import("zstd");
const c = @import("upstream");
const bench_options = @import("bench_options");

const gpa = std.heap.c_allocator;
const kib = 1024;
const chunk_default = 256 * kib;
const runs_default = 9;
const level = 19;
/// Loomwork stores a chunk raw when its frame is not at least a tenth smaller.
const raw_threshold = 0.9;

const original_flags = "-O3 -std=c99 -DXXH_NAMESPACE=ZSTD_ -DZSTD_MULTITHREAD " ++
    "-DZSTD_LEGACY_SUPPORT=0 -fno-sanitize=undefined -fPIC -fvisibility=hidden, " ++
    "plus huf_decompress_amd64.S on x86_64, as a shared library on glibc";

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("bench-decompress: " ++ format ++ "\n", args);
    std.process.exit(1);
}

/// One chunk: its bytes and its frame.
const Chunk = struct {
    input: []const u8,
    frame: []const u8,
};

const Set = struct {
    name: []const u8,
    chunks: []const Chunk,
    chunk_size: usize,
    files: usize,

    fn inputBytes(set: Set) u64 {
        var n: u64 = 0;
        for (set.chunks) |chunk| n += chunk.input.len;
        return n;
    }

    fn frameBytes(set: Set) u64 {
        var n: u64 = 0;
        for (set.chunks) |chunk| n += chunk.frame.len;
        return n;
    }

    /// The chunks that do not shrink by a tenth, which Loomwork stores raw.
    fn rawChunks(set: Set) usize {
        var n: usize = 0;
        for (set.chunks) |chunk| {
            const ratio = @as(f64, @floatFromInt(chunk.frame.len)) / @as(f64, @floatFromInt(chunk.input.len));
            if (ratio > raw_threshold) n += 1;
        }
        return n;
    }

    fn largestChunk(set: Set) usize {
        var n: usize = 0;
        for (set.chunks) |chunk| n = @max(n, chunk.input.len);
        return n;
    }
};

/// The port compressor at level 19 with a checksum, as Loomwork's bake.
const Compressor = struct {
    cctx: *zstd.CCtx,

    fn init() !Compressor {
        const cctx = try zstd.CCtx.create(gpa);
        _ = try cctx.setParameter(.compression_level, level);
        _ = try cctx.setParameter(.checksum_flag, 1);
        return .{ .cctx = cctx };
    }

    fn frame(self: Compressor, arena: std.mem.Allocator, input: []const u8) ![]const u8 {
        const dst = try arena.alloc(u8, try zstd.compressBound(input.len));
        const size = try self.cctx.compress2(dst, input);
        return dst[0..size];
    }
};

/// Cuts every file into chunks of `chunk_size` and compresses each.
fn makeSet(
    arena: std.mem.Allocator,
    compressor: Compressor,
    name: []const u8,
    files: []const []const u8,
    chunk_size: usize,
) !Set {
    var chunks: std.ArrayList(Chunk) = .empty;
    for (files) |file| {
        var pos: usize = 0;
        while (pos < file.len) {
            const n = @min(chunk_size, file.len - pos);
            const input = file[pos..][0..n];
            try chunks.append(arena, .{ .input = input, .frame = try compressor.frame(arena, input) });
            pos += n;
        }
    }
    return .{ .name = name, .chunks = chunks.items, .chunk_size = chunk_size, .files = files.len };
}

/// The port's decoder for one frame of a known size: `decompressFrameExact`, which checks
/// the checksum.
const Port = struct {
    dctx: *zstd.DCtx,

    fn init() !Port {
        const dctx = try gpa.create(zstd.DCtx);
        dctx.init();
        return .{ .dctx = dctx };
    }

    fn deinit(self: Port) void {
        gpa.destroy(self.dctx);
    }

    fn decode(self: Port, dst: []u8, frame: []const u8) void {
        self.dctx.decompressFrameExact(dst, frame, .{}) catch |err| fatal("port: {t}", .{err});
    }
};

/// The original's `ZSTD_decompressDCtx` with a reused context, which checks the checksum.
const Original = struct {
    dctx: *c.ZSTD_DCtx,

    fn init() !Original {
        return .{ .dctx = c.ZSTD_createDCtx() orelse return error.OutOfMemory };
    }

    fn deinit(self: Original) void {
        _ = c.ZSTD_freeDCtx(self.dctx);
    }

    fn decode(self: Original, dst: []u8, frame: []const u8) void {
        const code = c.ZSTD_decompressDCtx(self.dctx, dst.ptr, dst.len, frame.ptr, frame.len);
        if (c.ZSTD_isError(code) != 0) fatal("original: {s}", .{c.ZSTD_getErrorName(code)});
        if (code != dst.len) fatal("original: {d} of {d} bytes", .{ code, dst.len });
    }
};

/// Zig's std decoder, writing straight into the output, whose room it needs past the frame's
/// size for its block buffer. It cannot verify checksums: with `verify_checksum` it panics
/// (std 0.17.0), so it reads them and does not check them.
const Std = struct {
    room: []u8,

    fn init(largest: usize) !Std {
        return .{ .room = try gpa.alloc(u8, largest + std.compress.zstd.block_size_max) };
    }

    fn deinit(self: Std) void {
        gpa.free(self.room);
    }

    fn decode(self: Std, dst: []u8, frame: []const u8) void {
        var in: std.Io.Reader = .fixed(frame);
        var out: std.Io.Writer = .fixed(self.room[0 .. dst.len + std.compress.zstd.block_size_max]);
        var decompress: std.compress.zstd.Decompress = .init(&in, &.{}, .{
            .verify_checksum = false,
            .window_len = @intCast(@max(dst.len, std.compress.zstd.block_size_max)),
        });
        const n = decompress.reader.streamRemaining(&out) catch |err|
            fatal("std: {t} ({?t})", .{ err, decompress.err });
        if (n != dst.len) fatal("std: {d} of {d} bytes", .{ n, dst.len });
        // The output is already in place: copying it out would time a copy std does not need.
        std.mem.doNotOptimizeAway(out.buffer);
    }

    fn output(self: Std, len: usize) []const u8 {
        return self.room[0..len];
    }
};

const Timing = struct {
    median_ns: u64,
    min_ns: u64,
    max_ns: u64,

    fn of(samples: []u64) Timing {
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        const mid = samples.len / 2;
        return .{
            .median_ns = if (samples.len % 2 == 1) samples[mid] else (samples[mid - 1] + samples[mid]) / 2,
            .min_ns = samples[0],
            .max_ns = samples[samples.len - 1],
        };
    }

    fn rate(t: Timing, bytes: u64) f64 {
        return @as(f64, @floatFromInt(bytes)) / 1e6 / (@as(f64, @floatFromInt(t.median_ns)) / 1e9);
    }

    fn seconds(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1e9;
    }
};

const Result = struct {
    port: Timing,
    std_: Timing,
    original: Timing,
};

/// A timed pass decodes its set this many times, at least `pass_bytes_min` bytes, so that a
/// pass lasts long enough for the clock and the scheduler.
const pass_bytes_min = 64_000_000;

fn passRepeats(set: Set) usize {
    return std.math.divCeil(u64, pass_bytes_min, set.inputBytes()) catch unreachable;
}

/// One pass of `decoder` over every frame of `set`, `passRepeats` times; returns the time
/// of one decode of the set.
fn timedPass(io: std.Io, decoder: anytype, set: Set, dst: []u8) u64 {
    const repeats = passRepeats(set);
    const t0 = std.Io.Clock.awake.now(io);
    for (0..repeats) |_| {
        for (set.chunks) |chunk| {
            decoder.decode(dst[0..chunk.input.len], chunk.frame);
            std.mem.doNotOptimizeAway(dst);
        }
    }
    const t1 = std.Io.Clock.awake.now(io);
    return @as(u64, @intCast(t0.durationTo(t1).nanoseconds)) / repeats;
}

fn measure(io: std.Io, set: Set, runs: usize) !Result {
    const port: Port = try .init();
    defer port.deinit();
    const original: Original = try .init();
    defer original.deinit();
    const std_dec: Std = try .init(set.largestChunk());
    defer std_dec.deinit();
    const dst = try gpa.alloc(u8, set.largestChunk());
    defer gpa.free(dst);

    // The warm-up checks every decoder's output against the input.
    for (set.chunks) |chunk| {
        const out = dst[0..chunk.input.len];
        @memset(out, 0);
        port.decode(out, chunk.frame);
        if (!std.mem.eql(u8, out, chunk.input)) fatal("port: wrong output in {s}", .{set.name});
        @memset(out, 0);
        original.decode(out, chunk.frame);
        if (!std.mem.eql(u8, out, chunk.input)) fatal("original: wrong output in {s}", .{set.name});
        std_dec.decode(out, chunk.frame);
        if (!std.mem.eql(u8, std_dec.output(out.len), chunk.input)) fatal("std: wrong output in {s}", .{set.name});
    }

    const samples = try gpa.alloc(u64, 3 * runs);
    defer gpa.free(samples);
    const port_ns = samples[0..runs];
    const std_ns = samples[runs .. 2 * runs];
    const original_ns = samples[2 * runs ..];
    // Taking turns, the first decoder rotating, spreads drift in clock speed and cache state.
    for (0..runs) |run| {
        for (0..3) |k| switch ((run + k) % 3) {
            0 => port_ns[run] = timedPass(io, port, set, dst),
            1 => std_ns[run] = timedPass(io, std_dec, set, dst),
            else => original_ns[run] = timedPass(io, original, set, dst),
        };
    }
    return .{ .port = .of(port_ns), .std_ = .of(std_ns), .original = .of(original_ns) };
}

/// Every regular file in `dir` with a name ending in `suffix`, sorted by name.
fn readFiles(io: std.Io, arena: std.mem.Allocator, dir_path: []const u8, suffix: []const u8) ![]const []const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, suffix)) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var files: std.ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        try files.append(arena, try dir.readFileAlloc(io, name, arena, .unlimited));
    }
    return files.items;
}

/// The C sources and headers of reference/lib, by path, sorted.
fn readSources(io: std.Io, arena: std.mem.Allocator) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    inline for (.{ "common", "compress", "decompress", "dictBuilder" }) |sub| {
        const path = try std.fs.path.join(arena, &.{ bench_options.reference, "lib", sub });
        for (try readFiles(io, arena, path, ".c")) |f| try files.append(arena, f);
        for (try readFiles(io, arena, path, ".h")) |f| try files.append(arena, f);
    }
    return files.items;
}

const canterbury_text = [_][]const u8{
    "canterbury/alice29.txt", "canterbury/asyoulik.txt", "canterbury/cp.html",
    "canterbury/fields.c",    "canterbury/grammar.lsp",  "canterbury/lcet10.txt",
    "canterbury/plrabn12.txt", "canterbury/xargs.1",     "large/bible.txt",
    "large/world192.txt",
};

fn cpuModel(io: std.Io, arena: std.mem.Allocator) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, "/proc/cpuinfo", .{}) catch return null;
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);
    const text = reader.interface.allocRemaining(arena, .limited(1 << 22)) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "model name")) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn info(w: *std.Io.Writer, markdown: bool, comptime text: []const u8, args: anytype) !void {
    try w.writeAll(if (markdown) "- " else "");
    try w.print(text ++ "\n", args);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var textures: []const u8 = "zig-out/bench-textures";
    var runs: usize = runs_default;
    var markdown = false;
    var extra_chunks: std.ArrayList(usize) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--markdown")) {
            markdown = true;
        } else if (std.mem.eql(u8, arg, "--textures") and i + 1 < args.len) {
            i += 1;
            textures = args[i];
        } else if (std.mem.eql(u8, arg, "--runs") and i + 1 < args.len) {
            i += 1;
            runs = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--chunk") and i + 1 < args.len) {
            i += 1;
            try extra_chunks.append(arena, kib * try std.fmt.parseInt(usize, args[i], 10));
        } else fatal("unknown argument {s}", .{arg});
    }
    if (builtin.os.tag == .linux) _ = try std.posix.prctl(.SET_THP_DISABLE, .{ 1, 0, 0, 0 });

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    const bc7 = try readFiles(io, arena, textures, ".bc7");
    const bc5 = try readFiles(io, arena, textures, ".bc5");
    if (bc7.len == 0 or bc5.len == 0) {
        fatal("no .bc7 and .bc5 files in {s}; bench/textures/README.md says how to make them", .{textures});
    }
    var text: std.ArrayList([]const u8) = .empty;
    var canterbury_files: usize = 0;
    if (bench_options.canterbury.len != 0) {
        for (canterbury_text) |name| {
            const path = try std.fs.path.join(arena, &.{ bench_options.canterbury, name });
            try text.append(arena, try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited));
            canterbury_files += 1;
        }
    }
    const sources = try readSources(io, arena);
    for (sources) |s| try text.append(arena, s);
    var loomwork: std.ArrayList([]const u8) = .empty;
    inline for (.{ "mesh.bin", "snapshot.bin" }) |name| {
        const path = try std.fs.path.join(arena, &.{ bench_options.data, name });
        try loomwork.append(arena, try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited));
    }

    const compressor: Compressor = try .init();
    var sets: std.ArrayList(Set) = .empty;
    const bc7_set = try makeSet(arena, compressor, "BC7 textures", bc7, chunk_default);
    const bc5_set = try makeSet(arena, compressor, "BC5 normal maps", bc5, chunk_default);
    const text_set = try makeSet(arena, compressor, "text and source", text.items, chunk_default);
    const loomwork_set = try makeSet(arena, compressor, "mesh and snapshot", loomwork.items, chunk_default);
    // The mixed pack: the chunks of every set in turn.
    var mixed: std.ArrayList(Chunk) = .empty;
    {
        const parts = [_]Set{ bc7_set, bc5_set, text_set, loomwork_set };
        var k: usize = 0;
        var added = true;
        while (added) : (k += 1) {
            added = false;
            for (parts) |part| {
                if (k < part.chunks.len) {
                    try mixed.append(arena, part.chunks[k]);
                    added = true;
                }
            }
        }
    }
    try sets.appendSlice(arena, &.{ bc7_set, bc5_set, text_set, .{
        .name = "mixed pack",
        .chunks = mixed.items,
        .chunk_size = chunk_default,
        .files = bc7_set.files + bc5_set.files + text_set.files + loomwork_set.files,
    } });
    for (extra_chunks.items) |size| {
        try sets.append(arena, try makeSet(arena, compressor, "BC7 textures", bc7, size));
        try sets.append(arena, try makeSet(arena, compressor, "BC5 normal maps", bc5, size));
    }

    const version = c.ZSTD_versionNumber();
    try w.writeAll(if (markdown) "## zig-zstd decompression benchmark\n\n" else "zig-zstd decompression benchmark\n");
    try info(w, markdown, "machine: {s}, {d} logical CPUs; one thread", .{
        cpuModel(io, arena) orelse "unknown CPU",
        std.Thread.getCpuCount() catch 0,
    });
    try info(w, markdown, "Zig {s}, target {t}-{t}-{t}, CPU model {s}", .{
        builtin.zig_version_string, builtin.cpu.arch, builtin.os.tag, builtin.abi, builtin.cpu.model.name,
    });
    try info(w, markdown, "port and std: ReleaseFast, for that target", .{});
    try info(w, markdown, "original: zstd {d}.{d}.{d} from reference/, same target: {s}", .{
        version / 10000, version / 100 % 100, version % 100, original_flags,
    });
    try info(w, markdown, "frames: the port compressor at level {d} with a checksum, one frame a chunk", .{level});
    try info(w, markdown, "text and source: {d} Canterbury text files and {d} C files of reference/lib", .{
        canterbury_files, sources.len,
    });
    try info(w, markdown, "method: a reused context per decoder and an output of the chunk's size; an " ++
        "untimed warm-up of each decoder, checked against the input, then the median of {d} " ++
        "timed passes, each decoding the set over and over to at least {d} MB, the decoders " ++
        "taking turns; MB are 1e6 decoded bytes", .{ runs, pass_bytes_min / 1_000_000 });
    try info(w, markdown, "transparent huge pages off for the process", .{});
    try w.writeAll("\n");

    if (markdown) {
        try w.writeAll("| set | chunk | chunks | MB | ratio | chunks under 10% smaller | std MB/s | " ++
            "original MB/s | port MB/s | port / std | port / original |\n");
        try w.writeAll("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n");
    }
    var details: std.ArrayList(u8) = .empty;
    for (sets.items) |set| {
        const result = try measure(io, set, runs);
        const bytes = set.inputBytes();
        const ratio = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(set.frameBytes()));
        const port_rate = result.port.rate(bytes);
        const std_rate = result.std_.rate(bytes);
        const original_rate = result.original.rate(bytes);
        const row_args = .{
            set.name,  set.chunk_size / kib, set.chunks.len,       @as(f64, @floatFromInt(bytes)) / 1e6,
            ratio,     set.rawChunks(),      std_rate,             original_rate,
            port_rate, port_rate / std_rate, port_rate / original_rate,
        };
        if (markdown) {
            try w.print("| {s} | {d} KiB | {d} | {d:.1} | {d:.3} | {d} | {d:.1} | {d:.1} | {d:.1} | {d:.1}x | {d:.2} |\n", row_args);
        } else {
            try w.print("{s}, {d} KiB chunks: {d} chunks, {d:.1} MB, ratio {d:.3}, {d} under 10% smaller; " ++
                "std {d:.1} MB/s, original {d:.1} MB/s, port {d:.1} MB/s; port {d:.1}x std, {d:.2} of original\n", row_args);
        }
        try w.flush();
        var line: std.Io.Writer.Allocating = .init(arena);
        try line.writer.print("| {s}, {d} KiB | {d:.4} ({d:.4}-{d:.4}) | {d:.4} ({d:.4}-{d:.4}) | {d:.4} ({d:.4}-{d:.4}) |\n", .{
            set.name,                                  set.chunk_size / kib,
            Timing.seconds(result.std_.median_ns),     Timing.seconds(result.std_.min_ns),
            Timing.seconds(result.std_.max_ns),        Timing.seconds(result.original.median_ns),
            Timing.seconds(result.original.min_ns),    Timing.seconds(result.original.max_ns),
            Timing.seconds(result.port.median_ns),     Timing.seconds(result.port.min_ns),
            Timing.seconds(result.port.max_ns),
        });
        try details.appendSlice(arena, line.written());
    }
    try w.writeAll(if (markdown) "\nSeconds to decode each set once, median (min-max) of the passes:\n\n" else "\nseconds to decode each set once, median (min-max):\n");
    if (markdown) {
        try w.writeAll("| set | std | original | port |\n| --- | ---: | ---: | ---: |\n");
    }
    try w.writeAll(details.items);
    try w.flush();
}
