//! `zig build bench-features`: the port against the original on the features that
//! `zig build bench` and `zig build bench-decompress` do not time: streaming compression in
//! small pieces, dictionaries (`CDict` and `DDict`), long distance matching, target block
//! sizes (super-blocks), `compressSequences` and `compressSequencesAndLiterals`, and streaming
//! decompression. The port is built in ReleaseFast and the original from reference/ at -O3,
//! both for the same target, one thread.
//!
//! The inputs need no download beyond the Canterbury corpus: its text files and the C sources
//! of reference/lib, one frame a file ("files"), and its large and Calgary sets with those
//! sources joined into one input ("joined", about 12 MB). Each row's warm-up compares the
//! two sides' output byte for byte, then the sides take turns for `--runs` passes (default
//! 11), each pass repeated to at least 32 MB of input. The table gives the median and the
//! min-max of a pass's time; "within noise" where the two spreads overlap.
//!
//! Arguments after `--`: `--runs N`, `--rows a,b` (row names, see `rows`), `--markdown`.

const std = @import("std");
const builtin = @import("builtin");
const zstd = @import("zstd");
const c = @import("upstream");
const bench_options = @import("bench_options");

const gpa = std.heap.c_allocator;
const Sequence = zstd.params.Sequence;

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("bench-features: " ++ format ++ "\n", args);
    std.process.exit(1);
}

fn check(code: usize, what: []const u8) usize {
    if (c.ZSTD_isError(code) != 0) fatal("original {s}: {s}", .{ what, c.ZSTD_getErrorName(code) });
    return code;
}

const Kind = enum {
    stream,
    cdict,
    ldm,
    target_block,
    sequences,
    sequences_and_literals,
    decompress_stream,
    ddict,
};

const Row = struct {
    name: []const u8,
    kind: Kind,
    level: i32,
    /// The "joined" input rather than the files.
    joined: bool,
    /// Streaming: the size of an input (or frame) piece and an output window.
    piece: usize = 4096,
};

const rows = [_]Row{
    .{ .name = "stream-1", .kind = .stream, .level = 1, .joined = true },
    .{ .name = "stream-3", .kind = .stream, .level = 3, .joined = true },
    .{ .name = "stream-19", .kind = .stream, .level = 19, .joined = false },
    .{ .name = "cdict-1", .kind = .cdict, .level = 1, .joined = false },
    .{ .name = "cdict-3", .kind = .cdict, .level = 3, .joined = false },
    .{ .name = "cdict-19", .kind = .cdict, .level = 19, .joined = false },
    .{ .name = "ldm-3", .kind = .ldm, .level = 3, .joined = true },
    .{ .name = "ldm-19", .kind = .ldm, .level = 19, .joined = false },
    .{ .name = "target-block-3", .kind = .target_block, .level = 3, .joined = true },
    .{ .name = "sequences-3", .kind = .sequences, .level = 3, .joined = true },
    .{ .name = "sequences-and-literals-3", .kind = .sequences_and_literals, .level = 3, .joined = true },
    .{ .name = "decompress-stream-3", .kind = .decompress_stream, .level = 3, .joined = true },
    .{ .name = "decompress-stream-19", .kind = .decompress_stream, .level = 19, .joined = true },
    .{ .name = "ddict-19", .kind = .ddict, .level = 19, .joined = false },
};

fn label(row: Row) []const u8 {
    return switch (row.kind) {
        .stream => "compressStream2, 4 KiB pieces",
        .cdict => "compressUsingCDict, 110 KB dictionary",
        .ldm => "long distance matching, window log 27",
        .target_block => "targetCBlockSize 1340",
        .sequences => "compressSequences, explicit delimiters",
        .sequences_and_literals => "compressSequencesAndLiterals",
        .decompress_stream => "decompressStream, 4 KiB pieces",
        .ddict => "decompressUsingDDict, 110 KB dictionary",
    };
}

/// A unit of work: an input, with what a row needs made from it ahead of time.
const Item = struct {
    input: []const u8,
    /// The original's frame, for the decompression rows.
    frame: []const u8 = &.{},
    seqs: []const Sequence = &.{},
    literals: []const u8 = &.{},
};

/// Everything a row works on, and both sides' objects.
const Work = struct {
    row: Row,
    items: []const Item,
    bytes: u64,
    largest: usize,
    dict: []const u8,

    port_cctx: *zstd.CCtx,
    port_dctx: *zstd.DCtx,
    port_cdict: ?*zstd.CDict = null,
    port_ddict: ?*zstd.DDict = null,
    original_cctx: *c.ZSTD_CCtx,
    original_dctx: *c.ZSTD_DCtx,
    original_cdict: ?*c.ZSTD_CDict = null,
    original_ddict: ?*c.ZSTD_DDict = null,

    fn init(row: Row, items: []const Item, dict: []const u8) !Work {
        var bytes: u64 = 0;
        var largest: usize = 0;
        for (items) |item| {
            bytes += item.input.len;
            largest = @max(largest, item.input.len);
        }
        var work: Work = .{
            .row = row,
            .items = items,
            .bytes = bytes,
            .largest = largest,
            .dict = dict,
            .port_cctx = try zstd.CCtx.create(gpa),
            .port_dctx = try zstd.DCtx.create(gpa),
            .original_cctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory,
            .original_dctx = c.ZSTD_createDCtx() orelse return error.OutOfMemory,
        };
        try work.set(.compression_level, row.level);
        switch (row.kind) {
            .ldm => {
                try work.set(.enable_long_distance_matching, 1);
                try work.set(.window_log, 27);
            },
            .target_block => try work.set(.target_cblock_size, 1340),
            .sequences, .sequences_and_literals => {
                try work.set(.block_delimiters, 1);
            },
            .cdict => {
                work.port_cdict = try zstd.CDict.create(gpa, dict, row.level);
                work.original_cdict = c.ZSTD_createCDict(dict.ptr, dict.len, row.level) orelse
                    return error.OutOfMemory;
            },
            .ddict => {
                work.port_ddict = try zstd.createDDict(gpa, dict);
                work.original_ddict = c.ZSTD_createDDict(dict.ptr, dict.len) orelse
                    return error.OutOfMemory;
            },
            else => {},
        }
        return work;
    }

    fn deinit(work: *Work) void {
        work.port_cctx.destroy() catch unreachable;
        work.port_dctx.destroy() catch unreachable;
        if (work.port_cdict) |d| d.destroy();
        zstd.freeDDict(work.port_ddict);
        _ = c.ZSTD_freeCCtx(work.original_cctx);
        _ = c.ZSTD_freeDCtx(work.original_dctx);
        _ = c.ZSTD_freeCDict(work.original_cdict);
        _ = c.ZSTD_freeDDict(work.original_ddict);
    }

    fn set(work: *Work, param: zstd.params.CParameter, value: i32) !void {
        _ = try work.port_cctx.setParameter(param, value);
        _ = check(c.ZSTD_CCtx_setParameter(work.original_cctx, @backingInt(param), value), "setParameter");
    }

    /// One item through the port; the bytes it wrote to `out`.
    fn port(work: *Work, item: Item, out: []u8) usize {
        const cctx = work.port_cctx;
        return switch (work.row.kind) {
            .stream => portStream(cctx, out, item.input, work.row.piece),
            .cdict => cctx.compressUsingCDict(out, item.input, work.port_cdict.?) catch |e| fatal("port: {t}", .{e}),
            .ldm, .target_block => cctx.compress2(out, item.input) catch |e| fatal("port: {t}", .{e}),
            .sequences => cctx.compressSequences(out, item.seqs, item.input) catch |e| fatal("port: {t}", .{e}),
            .sequences_and_literals => cctx.compressSequencesAndLiterals(
                out,
                item.seqs,
                item.literals,
                item.literals.len,
                item.input.len,
            ) catch |e| fatal("port: {t}", .{e}),
            .decompress_stream => portDecompressStream(work.port_dctx, out, item.frame, work.row.piece),
            .ddict => work.port_dctx.decompressUsingDDict(out, item.frame, work.port_ddict) catch |e| fatal("port: {t}", .{e}),
        };
    }

    fn original(work: *Work, item: Item, out: []u8) usize {
        const cctx = work.original_cctx;
        const in = item.input;
        return switch (work.row.kind) {
            .stream => originalStream(cctx, out, in, work.row.piece),
            .cdict => check(c.ZSTD_compress_usingCDict(cctx, out.ptr, out.len, in.ptr, in.len, work.original_cdict.?), "compress_usingCDict"),
            .ldm, .target_block => check(c.ZSTD_compress2(cctx, out.ptr, out.len, in.ptr, in.len), "compress2"),
            .sequences => check(c.ZSTD_compressSequences(
                cctx,
                out.ptr,
                out.len,
                @ptrCast(item.seqs.ptr),
                item.seqs.len,
                in.ptr,
                in.len,
            ), "compressSequences"),
            .sequences_and_literals => check(c.ZSTD_compressSequencesAndLiterals(
                cctx,
                out.ptr,
                out.len,
                @ptrCast(item.seqs.ptr),
                item.seqs.len,
                item.literals.ptr,
                item.literals.len,
                item.literals.len,
                in.len,
            ), "compressSequencesAndLiterals"),
            .decompress_stream => originalDecompressStream(work.original_dctx, out, item.frame, work.row.piece),
            .ddict => check(c.ZSTD_decompress_usingDDict(
                work.original_dctx,
                out.ptr,
                out.len,
                item.frame.ptr,
                item.frame.len,
                work.original_ddict,
            ), "decompress_usingDDict"),
        };
    }
};

fn portStream(cctx: *zstd.CCtx, out: []u8, src: []const u8, piece: usize) usize {
    var input: zstd.InBuffer = .{ .src = src[0..0] };
    var output: zstd.OutBuffer = .{ .dst = out };
    while (true) {
        const end = @min(src.len, input.pos + piece);
        input.src = src[0..end];
        const directive: zstd.EndDirective = if (end == src.len) .end else .@"continue";
        const left = cctx.compressStream2(&output, &input, directive) catch |e| fatal("port: {t}", .{e});
        if (directive == .end and left == 0) return output.pos;
    }
}

fn originalStream(cctx: *c.ZSTD_CCtx, out: []u8, src: []const u8, piece: usize) usize {
    var input: c.ZSTD_inBuffer = .{ .src = src.ptr, .size = 0, .pos = 0 };
    var output: c.ZSTD_outBuffer = .{ .dst = out.ptr, .size = out.len, .pos = 0 };
    while (true) {
        input.size = @min(src.len, input.pos + piece);
        const directive: c_uint = if (input.size == src.len) 2 else 0;
        const left = check(c.ZSTD_compressStream2(cctx, &output, &input, directive), "compressStream2");
        if (directive == 2 and left == 0) return output.pos;
    }
}

/// `frame` fed in pieces of `piece` bytes, the output taken in windows of the same size.
fn portDecompressStream(dctx: *zstd.DCtx, out: []u8, frame: []const u8, piece: usize) usize {
    var input: zstd.InBuffer = .{ .src = frame[0..0] };
    var output: zstd.OutBuffer = .{ .dst = out[0..0] };
    while (true) {
        input.src = frame[0..@min(frame.len, input.pos + piece)];
        output.dst = out[0..@min(out.len, output.pos + piece)];
        const left = dctx.decompressStream(&output, &input) catch |e| fatal("port: {t}", .{e});
        if (left == 0) return output.pos;
    }
}

fn originalDecompressStream(dctx: *c.ZSTD_DCtx, out: []u8, frame: []const u8, piece: usize) usize {
    var input: c.ZSTD_inBuffer = .{ .src = frame.ptr, .size = 0, .pos = 0 };
    var output: c.ZSTD_outBuffer = .{ .dst = out.ptr, .size = 0, .pos = 0 };
    while (true) {
        input.size = @min(frame.len, input.pos + piece);
        output.size = @min(out.len, output.pos + piece);
        const left = check(c.ZSTD_decompressStream(dctx, &output, &input), "decompressStream");
        if (left == 0) return output.pos;
    }
}

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

    fn seconds(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1e9;
    }

    fn rate(t: Timing, bytes: u64) f64 {
        return @as(f64, @floatFromInt(bytes)) / 1e6 / seconds(t.median_ns);
    }
};

/// A pass works through the row's items this many times, at least this many input bytes.
const pass_bytes_min = 32_000_000;

/// One pass of a side; the time of one run through the items.
fn timedPass(io: std.Io, work: *Work, side: enum { port, original }, out: []u8) u64 {
    const repeats = std.math.divCeil(u64, pass_bytes_min, work.bytes) catch unreachable;
    const t0 = std.Io.Clock.awake.now(io);
    for (0..repeats) |_| {
        for (work.items) |item| {
            const n = switch (side) {
                .port => work.port(item, out),
                .original => work.original(item, out),
            };
            std.mem.doNotOptimizeAway(n);
            std.mem.doNotOptimizeAway(out);
        }
    }
    const t1 = std.Io.Clock.awake.now(io);
    return @as(u64, @intCast(t0.durationTo(t1).nanoseconds)) / repeats;
}

const Result = struct { port: Timing, original: Timing, output_bytes: u64 };

fn measure(io: std.Io, work: *Work, runs: usize) !Result {
    const capacity = c.ZSTD_compressBound(work.largest) + 1024;
    const port_out = try gpa.alloc(u8, capacity);
    defer gpa.free(port_out);
    const original_out = try gpa.alloc(u8, capacity);
    defer gpa.free(original_out);
    var output_bytes: u64 = 0;
    // The warm-up: the same bytes from both sides.
    for (work.items) |item| {
        const a = work.port(item, port_out);
        const b = work.original(item, original_out);
        if (!std.mem.eql(u8, port_out[0..a], original_out[0..b])) fatal("{s}: the sides' output differs", .{work.row.name});
        output_bytes += a;
    }
    const samples = try gpa.alloc(u64, 2 * runs);
    defer gpa.free(samples);
    for (0..runs) |run| {
        if (run % 2 == 0) {
            samples[runs + run] = timedPass(io, work, .original, original_out);
            samples[run] = timedPass(io, work, .port, port_out);
        } else {
            samples[run] = timedPass(io, work, .port, port_out);
            samples[runs + run] = timedPass(io, work, .original, original_out);
        }
    }
    return .{ .port = .of(samples[0..runs]), .original = .of(samples[runs..]), .output_bytes = output_bytes };
}

// --------------------------------------------------------
// The inputs
// --------------------------------------------------------

const canterbury_text = [_][]const u8{
    "canterbury/alice29.txt", "canterbury/asyoulik.txt", "canterbury/cp.html",
    "canterbury/fields.c",    "canterbury/grammar.lsp",  "canterbury/lcet10.txt",
    "canterbury/plrabn12.txt", "canterbury/xargs.1",     "large/bible.txt",
    "large/world192.txt",
};

const joined_files = [_][]const u8{
    "large/E.coli",   "large/bible.txt", "large/world192.txt", "calgary/bib",
    "calgary/book1",  "calgary/book2",   "calgary/geo",        "calgary/news",
    "calgary/obj1",   "calgary/obj2",    "calgary/paper1",     "calgary/pic",
    "calgary/progc",  "calgary/progl",   "calgary/progp",      "calgary/trans",
};

fn readFile(io: std.Io, arena: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(arena, &.{ dir, name });
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
}

/// The C sources and headers of reference/lib, sorted by name within each directory.
fn readSources(io: std.Io, arena: std.mem.Allocator) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    inline for (.{ "common", "compress", "decompress", "dictBuilder" }) |sub| {
        const path = try std.fs.path.join(arena, &.{ bench_options.reference, "lib", sub });
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".c") and !std.mem.endsWith(u8, entry.name, ".h")) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names.items) |name| try files.append(arena, try dir.readFileAlloc(io, name, arena, .unlimited));
    }
    return files.items;
}

/// A dictionary of `capacity` bytes trained by the original's trainer on `samples`.
fn trainDictionary(arena: std.mem.Allocator, samples: []const []const u8, capacity: usize) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    const sizes = try arena.alloc(usize, samples.len);
    for (samples, sizes) |s, *size| {
        try joined.appendSlice(arena, s);
        size.* = s.len;
    }
    const dict = try arena.alloc(u8, capacity);
    const n = c.ZDICT_trainFromBuffer(dict.ptr, dict.len, joined.items.ptr, sizes.ptr, @intCast(sizes.len));
    if (c.ZDICT_isError(n) != 0) fatal("dictionary training failed", .{});
    return dict[0..n];
}

/// Splits `input` into pieces of at most 1 MiB, the items of the sequence rows, with the
/// original's sequences and their literals.
fn sequenceItems(arena: std.mem.Allocator, input: []const u8, level: i32) ![]const Item {
    const cctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
    defer _ = c.ZSTD_freeCCtx(cctx);
    _ = check(c.ZSTD_CCtx_setParameter(cctx, 100, level), "setParameter");
    var items: std.ArrayList(Item) = .empty;
    var pos: usize = 0;
    while (pos < input.len) {
        const piece = input[pos..@min(input.len, pos + (1 << 20))];
        pos += piece.len;
        const seqs = try arena.alloc(Sequence, c.ZSTD_sequenceBound(piece.len));
        const n = check(c.ZSTD_generateSequences(cctx, @ptrCast(seqs.ptr), seqs.len, piece.ptr, piece.len), "generateSequences");
        var literals: std.ArrayList(u8) = .empty;
        var at: usize = 0;
        for (seqs[0..n]) |s| {
            try literals.appendSlice(arena, piece[at..][0..s.lit_length]);
            at += s.lit_length + s.match_length;
        }
        try items.append(arena, .{ .input = piece, .seqs = seqs[0..n], .literals = literals.items });
    }
    return items.items;
}

fn frameItems(arena: std.mem.Allocator, inputs: []const []const u8, level: i32, dict: ?[]const u8) ![]const Item {
    const cctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
    defer _ = c.ZSTD_freeCCtx(cctx);
    _ = check(c.ZSTD_CCtx_setParameter(cctx, 100, level), "setParameter");
    _ = check(c.ZSTD_CCtx_setParameter(cctx, 201, 1), "setParameter");
    const items = try arena.alloc(Item, inputs.len);
    for (items, inputs) |*item, input| {
        if (dict) |d| _ = check(c.ZSTD_CCtx_loadDictionary(cctx, d.ptr, d.len), "loadDictionary");
        const frame = try arena.alloc(u8, c.ZSTD_compressBound(input.len));
        const n = check(c.ZSTD_compress2(cctx, frame.ptr, frame.len, input.ptr, input.len), "compress2");
        item.* = .{ .input = input, .frame = frame[0..n] };
    }
    return items;
}

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

/// Whether `--rows` names `row`, or is not given.
fn isSelected(selected: ?[]const u8, row: Row) bool {
    const list = selected orelse return true;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |name| {
        if (std.mem.eql(u8, name, row.name)) return true;
    }
    return false;
}

/// The logical CPUs /proc/cpuinfo lists, whatever this process may run on.
fn cpuCount(io: std.Io, arena: std.mem.Allocator) usize {
    const file = std.Io.Dir.cwd().openFile(io, "/proc/cpuinfo", .{}) catch return 0;
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);
    const text = reader.interface.allocRemaining(arena, .limited(1 << 22)) catch return 0;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "processor")) count += 1;
    }
    return count;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // The inputs' arena takes its memory from malloc, so the benchmark also runs under
    // valgrind, whose address layout the page allocator's placement hints do not fit.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var runs: usize = 11;
    var markdown = false;
    var selected: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--markdown")) {
            markdown = true;
        } else if (std.mem.eql(u8, arg, "--runs") and i + 1 < args.len) {
            i += 1;
            runs = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--rows") and i + 1 < args.len) {
            i += 1;
            selected = args[i];
        } else fatal("unknown argument {s}", .{arg});
    }
    if (bench_options.canterbury.len == 0) fatal("the Canterbury corpus is not fetched (-Dcorpus=false?)", .{});
    if (builtin.os.tag == .linux) _ = try std.posix.prctl(.SET_THP_DISABLE, .{ 1, 0, 0, 0 });

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    var files: std.ArrayList([]const u8) = .empty;
    for (canterbury_text) |name| try files.append(arena, try readFile(io, arena, bench_options.canterbury, name));
    const sources = try readSources(io, arena);
    try files.appendSlice(arena, sources);
    var joined: std.ArrayList(u8) = .empty;
    for (joined_files) |name| try joined.appendSlice(arena, try readFile(io, arena, bench_options.canterbury, name));
    for (sources) |s| try joined.appendSlice(arena, s);
    // Long distance matching: the joined input twice, so its second half repeats the first
    // from 12 MB back.
    const doubled = try arena.alloc(u8, 2 * joined.items.len);
    @memcpy(doubled[0..joined.items.len], joined.items);
    @memcpy(doubled[joined.items.len..], joined.items);
    // For the slow levels: its first 4 MiB twice.
    const sample = joined.items[0..@min(joined.items.len, 4 << 20)];
    const doubled_sample = try arena.alloc(u8, 2 * sample.len);
    @memcpy(doubled_sample[0..sample.len], sample);
    @memcpy(doubled_sample[sample.len..], sample);
    // Only the dictionary rows need one; training takes seconds.
    const dict: []const u8 = for (rows) |row| {
        if ((row.kind == .cdict or row.kind == .ddict) and isSelected(selected, row))
            break try trainDictionary(arena, files.items, 110 * 1024);
    } else &.{};

    const bullet = if (markdown) "- " else "";
    try w.print("{s}machine: {s}, {d} logical CPUs, {d} of them available to this process; one thread\n", .{
        bullet,
        cpuModel(io, arena) orelse "unknown CPU",
        cpuCount(io, arena),
        std.Thread.getCpuCount() catch 0,
    });
    try w.print("{s}Zig {s}, target {t}-{t}, CPU model {s}; port ReleaseFast, original -O3 (as `zig build bench`)\n", .{
        bullet, builtin.zig_version_string, builtin.cpu.arch, builtin.os.tag, builtin.cpu.model.name,
    });
    try w.print("{s}files: {d} Canterbury text files and {d} C files of reference/lib, {d} bytes; joined: {d} bytes; dictionary: {d} bytes, trained by the original on the files\n", .{
        bullet, canterbury_text.len, sources.len, blk: {
            var n: usize = 0;
            for (files.items) |f| n += f.len;
            break :blk n;
        }, joined.items.len, dict.len,
    });
    try w.print("{s}method: a warm-up that compares the two sides' output, then {d} passes each, the sides taking turns, each pass repeated to {d} MB of input; median (min-max) seconds a pass; transparent huge pages off\n\n", .{ bullet, runs, pass_bytes_min / 1_000_000 });
    try w.writeAll("| row | input | MB in | output bytes | original MB/s | port MB/s | original s (min-max) | port s (min-max) | port / original |\n");
    try w.writeAll("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n");
    try w.flush();

    for (rows) |row| {
        if (!isSelected(selected, row)) continue;
        const inputs: []const []const u8 = if (row.kind == .ldm and row.joined)
            &.{doubled}
        else if (row.kind == .ldm)
            &.{doubled_sample}
        else if (row.joined)
            &.{joined.items}
        else
            files.items;
        const items: []const Item = switch (row.kind) {
            .sequences, .sequences_and_literals => try sequenceItems(arena, joined.items, row.level),
            .decompress_stream => try frameItems(arena, inputs, row.level, null),
            .ddict => try frameItems(arena, inputs, row.level, dict),
            else => blk: {
                const list = try arena.alloc(Item, inputs.len);
                for (list, inputs) |*item, input| item.* = .{ .input = input };
                break :blk list;
            },
        };
        var work: Work = try .init(row, items, dict);
        defer work.deinit();
        const r = try measure(io, &work, runs);
        const ratio = Timing.seconds(r.port.median_ns) / Timing.seconds(r.original.median_ns);
        const overlap = r.port.min_ns <= r.original.max_ns and r.original.min_ns <= r.port.max_ns;
        var verdict_buffer: [64]u8 = undefined;
        const verdict = if (overlap)
            try std.fmt.bufPrint(&verdict_buffer, "{d:.3}, within noise", .{ratio})
        else
            try std.fmt.bufPrint(&verdict_buffer, "{d:.3}, {d:.1}% {s}", .{
                ratio, @abs(1 - ratio) * 100, if (ratio < 1) "faster" else "slower",
            });
        try w.print("| {s}, level {d} | {s} | {d:.1} | {d} | {d:.1} | {d:.1} | {d:.4} ({d:.4}-{d:.4}) | {d:.4} ({d:.4}-{d:.4}) | {s} |\n", .{
            label(row),
            row.level,
            if (row.kind == .ldm and row.joined) "joined, twice" else if (row.kind == .ldm) "4 MiB of joined, twice" else if (row.joined) "joined" else "files",
            @as(f64, @floatFromInt(work.bytes)) / 1e6,
            r.output_bytes,
            r.original.rate(work.bytes),
            r.port.rate(work.bytes),
            Timing.seconds(r.original.median_ns),
            Timing.seconds(r.original.min_ns),
            Timing.seconds(r.original.max_ns),
            Timing.seconds(r.port.median_ns),
            Timing.seconds(r.port.min_ns),
            Timing.seconds(r.port.max_ns),
            verdict,
        });
        try w.flush();
    }
}
