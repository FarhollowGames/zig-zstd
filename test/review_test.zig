//! The compressor review's skeptic (25 November 2026): a failing test per
//! finding, and the probes that held up. Allocation failures go through every
//! entry point that allocates: each run fails one allocation (or every one
//! from it on), checks that the port refuses with `error.MemoryAllocation`,
//! frees all it took, and that the same objects then give the original's
//! frame or bytes once memory is back.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");

const testing = std.testing;
const gpa = common.gpa;
const io = std.testing.io;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// An allocator that fails its allocation number `fail_at` (counting from
/// 0), or with `sticky` every one from it on, and counts the bytes it holds.
/// Safe to use from several threads.
const Failing = struct {
    backing: Allocator,
    fail_at: std.atomic.Value(usize),
    sticky: bool,
    index: std.atomic.Value(usize) = .init(0),
    induced: std.atomic.Value(bool) = .init(false),
    live: std.atomic.Value(isize) = .init(0),

    fn init(backing: Allocator, fail_at: usize, sticky: bool) Failing {
        return .{ .backing = backing, .fail_at = .init(fail_at), .sticky = sticky };
    }

    fn allocator(self: *Failing) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    /// No allocation fails from now on.
    fn disable(self: *Failing) void {
        self.fail_at.store(std.math.maxInt(usize), .seq_cst);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Failing = @ptrCast(@alignCast(ctx));
        const i = self.index.fetchAdd(1, .seq_cst);
        const at = self.fail_at.load(.seq_cst);
        if (i == at or (self.sticky and i >= at)) {
            self.induced.store(true, .seq_cst);
            return null;
        }
        const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        _ = self.live.fetchAdd(@intCast(len), .seq_cst);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        const self: *Failing = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ra)) return false;
        _ = self.live.fetchAdd(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)), .seq_cst);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Failing = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        _ = self.live.fetchAdd(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)), .seq_cst);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *Failing = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
        _ = self.live.fetchSub(@intCast(memory.len), .seq_cst);
    }
};

/// Whether `result` is a success or `error.MemoryAllocation`; any other
/// error fails the test.
fn refusedForMemory(result: anytype) !bool {
    _ = result catch |err| {
        if (err == error.MemoryAllocation) return true;
        std.debug.print("expected error.MemoryAllocation, got {t}\n", .{err});
        return error.UnexpectedError;
    };
    return false;
}

/// Runs `scenario` with each allocation failing in turn, then with every
/// allocation from each one on failing, until a run makes no allocation
/// fail. Each run must free all it allocated.
fn everyFailure(scenario: anytype, args: anytype) !void {
    for ([_]bool{ false, true }) |sticky| {
        var n: usize = 0;
        while (true) : (n += 1) {
            var failing: Failing = .init(gpa, n, sticky);
            errdefer std.debug.print("allocation {d} failing{s}\n", .{ n, if (sticky) " and every one after" else "" });
            try @call(.auto, scenario, .{&failing} ++ args);
            try testing.expectEqual(0, failing.live.load(.seq_cst));
            if (!failing.induced.load(.seq_cst)) break;
            if (n > 10_000) return error.TooManyAllocations;
        }
    }
}

fn upstreamFrame(src: []const u8, level: i32, checksum: bool) ![]u8 {
    return common.upstreamCompress2(&.{
        .{ .param = 100, .value = level },
        .{ .param = 201, .value = @intFromBool(checksum) },
    }, src);
}

fn oneShot(failing: *Failing, src: []const u8, level: i32, expected: []const u8) !void {
    const dst = try gpa.alloc(u8, c.ZSTD_compressBound(src.len));
    defer gpa.free(dst);
    const result = zstd.compress(failing.allocator(), dst, src, level);
    if (try refusedForMemory(result)) return;
    try testing.expectEqualSlices(u8, expected, dst[0..try result]);
}

test "review: compress, every allocation failing in turn" {
    const src = try common.generated(200_000, 0.5, 0.3, 901);
    defer gpa.free(src);
    for ([_]i32{ -5, 1, 3, 7, 16, 19 }) |level| {
        errdefer std.debug.print("level {d}\n", .{level});
        const expected = try upstreamFrame(src, level, false);
        defer gpa.free(expected);
        try everyFailure(oneShot, .{ src, level, expected });
    }
}

/// A context's frames at `levels` in turn, so that its workspace grows and
/// shrinks; after a refusal, the same context with memory back.
fn reusedContext(
    failing: *Failing,
    src: []const u8,
    levels: []const i32,
    expected: []const []const u8,
    dict: ?[]const u8,
) !void {
    const cctx = zstd.CCtx.create(failing.allocator()) catch |err| {
        try testing.expectEqual(error.MemoryAllocation, err);
        return;
    };
    defer cctx.destroy() catch unreachable;
    const dst = try gpa.alloc(u8, c.ZSTD_compressBound(src.len));
    defer gpa.free(dst);
    for (levels, expected) |level, frame| {
        _ = try cctx.setParameter(.compression_level, level);
        _ = try cctx.setParameter(.checksum_flag, 1);
        if (dict) |d| {
            if (try refusedForMemory(cctx.loadDictionary(d))) {
                failing.disable();
                try cctx.loadDictionary(d);
            }
        }
        const result = cctx.compress2(dst, src);
        if (try refusedForMemory(result)) {
            failing.disable();
            const again = try cctx.compress2(dst, src);
            try testing.expectEqualSlices(u8, frame, dst[0..again]);
        } else {
            try testing.expectEqualSlices(u8, frame, dst[0..try result]);
        }
    }
}

test "review: compress2 on a reused context, every allocation failing in turn" {
    const src = try common.generated(300_000, 0.5, 0.3, 902);
    defer gpa.free(src);
    const levels = [_]i32{ 1, 19, 3, 22, 5 };
    var expected: [levels.len][]u8 = undefined;
    for (&expected, levels) |*e, level| e.* = try upstreamFrame(src, level, true);
    defer for (expected) |e| gpa.free(e);
    try everyFailure(reusedContext, .{ src, &levels, @as([]const []const u8, &expected), null });
}

test "review: loadDictionary and compress2, every allocation failing in turn" {
    const src = try common.generated(100_000, 0.5, 0.3, 903);
    defer gpa.free(src);
    const dict = try common.generated(40_000, 0.5, 0.3, 904);
    defer gpa.free(dict);
    const levels = [_]i32{ 3, 19, 1 };
    var expected: [levels.len][]u8 = undefined;
    for (&expected, levels) |*e, level| {
        const cctx = try common.upstreamCCtx(&.{
            .{ .param = 100, .value = level },
            .{ .param = 201, .value = 1 },
        });
        defer _ = c.ZSTD_freeCCtx(cctx);
        try testing.expect(c.ZSTD_isError(c.ZSTD_CCtx_loadDictionary(cctx, dict.ptr, dict.len)) == 0);
        const out = try gpa.alloc(u8, c.ZSTD_compressBound(src.len));
        const size = c.ZSTD_compress2(cctx, out.ptr, out.len, src.ptr, src.len);
        try testing.expect(c.ZSTD_isError(size) == 0);
        e.* = out[0..size];
    }
    defer for (expected, levels) |e, _| gpa.free(e.ptr[0..c.ZSTD_compressBound(src.len)]);
    try everyFailure(reusedContext, .{ src, &levels, @as([]const []const u8, &expected), dict });
}

fn withCDict(failing: *Failing, src: []const u8, dict: []const u8, level: i32, expected: []const u8) !void {
    const cdict = zstd.internal.compress.createCDict(failing.allocator(), dict, level) catch |err| {
        try testing.expectEqual(error.MemoryAllocation, err);
        return;
    };
    defer zstd.internal.compress.freeCDict(cdict);
    const cctx = zstd.CCtx.create(failing.allocator()) catch |err| {
        try testing.expectEqual(error.MemoryAllocation, err);
        return;
    };
    defer cctx.destroy() catch unreachable;
    const dst = try gpa.alloc(u8, c.ZSTD_compressBound(src.len));
    defer gpa.free(dst);
    const result = cctx.compressUsingCDict(dst, src, cdict);
    if (try refusedForMemory(result)) {
        failing.disable();
        const again = try cctx.compressUsingCDict(dst, src, cdict);
        try testing.expectEqualSlices(u8, expected, dst[0..again]);
    } else {
        try testing.expectEqualSlices(u8, expected, dst[0..try result]);
    }
}

test "review: createCDict and compressUsingCDict, every allocation failing in turn" {
    const src = try common.generated(100_000, 0.5, 0.3, 905);
    defer gpa.free(src);
    const dict = try common.generated(40_000, 0.5, 0.3, 906);
    defer gpa.free(dict);
    for ([_]i32{ 1, 3, 9, 19 }) |level| {
        errdefer std.debug.print("level {d}\n", .{level});
        const cdict = c.ZSTD_createCDict(dict.ptr, dict.len, level) orelse return error.OutOfMemory;
        defer _ = c.ZSTD_freeCDict(cdict);
        const cctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
        defer _ = c.ZSTD_freeCCtx(cctx);
        const expected = try gpa.alloc(u8, c.ZSTD_compressBound(src.len));
        defer gpa.free(expected);
        const size = c.ZSTD_compress_usingCDict(cctx, expected.ptr, expected.len, src.ptr, src.len, cdict);
        try testing.expect(c.ZSTD_isError(size) == 0);
        try everyFailure(withCDict, .{ src, dict, level, expected[0..size] });
    }
}

/// `src` streamed in pieces of `piece` bytes into windows of `window` bytes,
/// with a flush after the first piece; returns the frame's size in `dst`.
fn portStream(cctx: *zstd.CCtx, dst: []u8, src: []const u8, piece: usize, window: usize) !usize {
    var out_pos: usize = 0;
    var in_pos: usize = 0;
    var calls: usize = 0;
    while (true) : (calls += 1) {
        const in_end = @min(src.len, in_pos + piece);
        const directive: zstd.EndDirective = if (in_end == src.len) .end else if (calls == 1) .flush else .@"continue";
        var input: zstd.InBuffer = .{ .src = src[0..in_end], .pos = in_pos };
        var output: zstd.OutBuffer = .{ .dst = dst[0..@min(dst.len, out_pos + window)], .pos = out_pos };
        const left = try cctx.compressStream2(&output, &input, directive);
        in_pos = input.pos;
        out_pos = output.pos;
        if (directive == .end and left == 0) return out_pos;
    }
}

fn upstreamStream(cctx: *c.ZSTD_CCtx, dst: []u8, src: []const u8, piece: usize, window: usize) !usize {
    var out_pos: usize = 0;
    var in_pos: usize = 0;
    var calls: usize = 0;
    while (true) : (calls += 1) {
        const in_end = @min(src.len, in_pos + piece);
        const directive: c_uint = if (in_end == src.len) 2 else if (calls == 1) 1 else 0;
        var input: c.ZSTD_inBuffer = .{ .src = src.ptr, .size = in_end, .pos = in_pos };
        var output: c.ZSTD_outBuffer = .{ .dst = dst.ptr, .size = @min(dst.len, out_pos + window), .pos = out_pos };
        const left = c.ZSTD_compressStream2(cctx, &output, &input, directive);
        if (c.ZSTD_isError(left) != 0) return error.UpstreamFailed;
        in_pos = input.pos;
        out_pos = output.pos;
        if (directive == 2 and left == 0) return out_pos;
    }
}

const StreamSetup = struct {
    level: i32,
    workers: i32 = 0,
    ldm: bool = false,
    window_log: i32 = 0,
    piece: usize = 10_000,
    window: usize = 4096,
};

fn streamed(failing: *Failing, src: []const u8, setup: StreamSetup, expected: []const u8) !void {
    const cctx = zstd.CCtx.create(failing.allocator()) catch |err| {
        try testing.expectEqual(error.MemoryAllocation, err);
        return;
    };
    defer cctx.destroy() catch unreachable;
    cctx.setIo(io);
    _ = try cctx.setParameter(.compression_level, setup.level);
    _ = try cctx.setParameter(.checksum_flag, 1);
    _ = try cctx.setParameter(.nb_workers, setup.workers);
    _ = try cctx.setParameter(.window_log, setup.window_log);
    _ = try cctx.setParameter(.enable_long_distance_matching, if (setup.ldm) 1 else 2);
    const dst = try gpa.alloc(u8, c.ZSTD_compressBound(src.len) + 1024);
    defer gpa.free(dst);
    const result = portStream(cctx, dst, src, setup.piece, setup.window);
    if (try refusedForMemory(result)) {
        failing.disable();
        try cctx.reset(.session_only);
        const again = try portStream(cctx, dst, src, setup.piece, setup.window);
        try testing.expectEqualSlices(u8, expected, dst[0..again]);
    } else {
        try testing.expectEqualSlices(u8, expected, dst[0..try result]);
    }
}

fn expectStreamed(src: []const u8, setup: StreamSetup) !void {
    errdefer std.debug.print("{any}\n", .{setup});
    const cctx = try common.upstreamCCtx(&.{
        .{ .param = 100, .value = setup.level },
        .{ .param = 201, .value = 1 },
        .{ .param = 400, .value = setup.workers },
        .{ .param = 101, .value = setup.window_log },
        .{ .param = 160, .value = if (setup.ldm) 1 else 2 },
    });
    defer _ = c.ZSTD_freeCCtx(cctx);
    const expected = try gpa.alloc(u8, c.ZSTD_compressBound(src.len) + 1024);
    defer gpa.free(expected);
    const size = try upstreamStream(cctx, expected, src, setup.piece, setup.window);
    try everyFailure(streamed, .{ src, setup, expected[0..size] });
}

test "review: compressStream2, every allocation failing in turn" {
    const src = try common.generated(400_000, 0.5, 0.3, 907);
    defer gpa.free(src);
    try expectStreamed(src, .{ .level = 1 });
    try expectStreamed(src, .{ .level = 19, .piece = 70_000, .window = 100_000 });
    try expectStreamed(src, .{ .level = 3, .ldm = true, .window_log = 22, .piece = 50_000 });
}

test "review: compressStream2 with workers, every allocation failing in turn" {
    const src = try common.generated(1_500_000, 0.5, 0.3, 908);
    defer gpa.free(src);
    try expectStreamed(src, .{ .level = 3, .workers = 2, .piece = 200_000, .window = 300_000 });
    try expectStreamed(src, .{ .level = 3, .workers = 3, .ldm = true, .window_log = 20, .piece = 300_000, .window = 1 << 20 });
}

fn generatedSequences(failing: *Failing, src: []const u8, expected: []const zstd.params.Sequence) !void {
    const cctx = try zstd.CCtx.create(gpa);
    defer cctx.destroy() catch unreachable;
    _ = try cctx.setParameter(.compression_level, 5);
    const seqs = try gpa.alloc(zstd.params.Sequence, zstd.sequenceBound(src.len));
    defer gpa.free(seqs);
    const result = cctx.generateSequences(failing.allocator(), seqs, src);
    if (try refusedForMemory(result)) {
        failing.disable();
        const again = try cctx.generateSequences(failing.allocator(), seqs, src);
        try testing.expectEqualSlices(zstd.params.Sequence, expected, seqs[0..again]);
    } else {
        try testing.expectEqualSlices(zstd.params.Sequence, expected, seqs[0..try result]);
    }
}

test "review: generateSequences, every allocation failing in turn" {
    const src = try common.generated(200_000, 0.5, 0.3, 909);
    defer gpa.free(src);
    const cctx = try common.upstreamCCtx(&.{.{ .param = 100, .value = 5 }});
    defer _ = c.ZSTD_freeCCtx(cctx);
    const bound = c.ZSTD_sequenceBound(src.len);
    const expected = try gpa.alloc(zstd.params.Sequence, bound);
    defer gpa.free(expected);
    const n = c.ZSTD_generateSequences(cctx, @ptrCast(expected.ptr), bound, src.ptr, src.len);
    try testing.expect(c.ZSTD_isError(n) == 0);
    try everyFailure(generatedSequences, .{ src, expected[0..n] });
}

fn withThreadPool(failing: *Failing, src: []const u8, expected: []const u8) !void {
    const pool = zstd.createThreadPool(failing.allocator(), io, 2) orelse return;
    defer zstd.freeThreadPool(pool);
    const cctx = zstd.CCtx.create(failing.allocator()) catch |err| {
        try testing.expectEqual(error.MemoryAllocation, err);
        return;
    };
    defer cctx.destroy() catch unreachable;
    try cctx.refThreadPool(pool);
    cctx.setIo(io);
    _ = try cctx.setParameter(.compression_level, 3);
    _ = try cctx.setParameter(.checksum_flag, 1);
    _ = try cctx.setParameter(.nb_workers, 2);
    const dst = try gpa.alloc(u8, c.ZSTD_compressBound(src.len));
    defer gpa.free(dst);
    const result = cctx.compress2(dst, src);
    if (try refusedForMemory(result)) {
        failing.disable();
        const again = try cctx.compress2(dst, src);
        try testing.expectEqualSlices(u8, expected, dst[0..again]);
    } else {
        try testing.expectEqualSlices(u8, expected, dst[0..try result]);
    }
}

test "review: a shared thread pool and workers, every allocation failing in turn" {
    const src = try common.generated(1_500_000, 0.5, 0.3, 910);
    defer gpa.free(src);
    const expected = try common.upstreamCompress2(&.{
        .{ .param = 100, .value = 3 },
        .{ .param = 201, .value = 1 },
        .{ .param = 400, .value = 2 },
    }, src);
    defer gpa.free(expected);
    try everyFailure(withThreadPool, .{ src, expected });
}

const Decode = enum { one_shot, context, ddict, loaded, stream };

fn decoded(failing: *Failing, how: Decode, frame: []const u8, dict: []const u8, expected: []const u8) !void {
    const out = try gpa.alloc(u8, expected.len + 64);
    defer gpa.free(out);
    const a = failing.allocator();
    if (how == .one_shot) {
        const result = zstd.decompress(a, out, frame);
        if (try refusedForMemory(result)) return;
        return testing.expectEqualSlices(u8, expected, out[0..try result]);
    }
    const dctx = zstd.DCtx.create(a) catch |err| {
        try testing.expectEqual(error.MemoryAllocation, err);
        return;
    };
    defer dctx.destroy() catch unreachable;
    var ddict: ?*zstd.DDict = null;
    defer zstd.freeDDict(ddict);
    switch (how) {
        .ddict => ddict = zstd.createDDict(a, dict) catch |err| {
            try testing.expectEqual(error.MemoryAllocation, err);
            return;
        },
        .loaded => if (try refusedForMemory(dctx.loadDictionary(dict))) {
            failing.disable();
            try dctx.loadDictionary(dict);
        },
        else => {},
    }
    const Run = struct {
        fn run(d: *zstd.DCtx, h: Decode, o: []u8, f: []const u8, dd: ?*zstd.DDict) !usize {
            switch (h) {
                .ddict => return d.decompressUsingDDict(o, f, dd),
                .stream => {
                    var input: zstd.InBuffer = .{ .src = f[0..0] };
                    var output: zstd.OutBuffer = .{ .dst = o[0..0] };
                    while (true) {
                        input.src = f[0..@min(f.len, input.pos + 7_000)];
                        output.dst = o[0..@min(o.len, output.pos + 5_000)];
                        const left = try d.decompressStream(&output, &input);
                        if (left == 0) return output.pos;
                    }
                },
                else => return d.decompressDCtx(o, f),
            }
        }
    };
    const result = Run.run(dctx, how, out, frame, ddict);
    if (try refusedForMemory(result)) {
        failing.disable();
        try dctx.reset(.session_only);
        const again = try Run.run(dctx, how, out, frame, ddict);
        try testing.expectEqualSlices(u8, expected, out[0..again]);
    } else {
        try testing.expectEqualSlices(u8, expected, out[0..try result]);
    }
}

test "review: decompression, every allocation failing in turn" {
    const src = try common.generated(300_000, 0.5, 0.3, 911);
    defer gpa.free(src);
    const dict = try common.generated(40_000, 0.5, 0.3, 912);
    defer gpa.free(dict);
    const plain = try upstreamFrame(src, 19, true);
    defer gpa.free(plain);
    const cctx = try common.upstreamCCtx(&.{ .{ .param = 100, .value = 3 }, .{ .param = 201, .value = 1 } });
    defer _ = c.ZSTD_freeCCtx(cctx);
    try testing.expect(c.ZSTD_isError(c.ZSTD_CCtx_loadDictionary(cctx, dict.ptr, dict.len)) == 0);
    const with_dict = try gpa.alloc(u8, c.ZSTD_compressBound(src.len));
    defer gpa.free(with_dict);
    const size = c.ZSTD_compress2(cctx, with_dict.ptr, with_dict.len, src.ptr, src.len);
    try testing.expect(c.ZSTD_isError(size) == 0);
    for ([_]Decode{ .one_shot, .context, .stream }) |how| {
        errdefer std.debug.print("{t}\n", .{how});
        try everyFailure(decoded, .{ how, plain, &.{}, src });
    }
    for ([_]Decode{ .ddict, .loaded }) |how| {
        errdefer std.debug.print("{t}\n", .{how});
        try everyFailure(decoded, .{ how, with_dict[0..size], dict, src });
    }
}

const Sequence = zstd.params.Sequence;

/// A length or offset at or near a bound of its 32 bits, or of a block.
fn extreme(random: std.Random) u32 {
    const values = [_]u32{
        std.math.maxInt(u32),
        std.math.maxInt(u32) - 2,
        std.math.maxInt(u32) - 3,
        1 << 31,
        (1 << 31) - 1,
        (1 << 17) + 1,
        1 << 17,
        0x10000,
        0xFFFF,
    };
    return values[random.uintLessThan(usize, values.len)];
}

/// Random sequences, mostly short and some at their bounds, with or
/// without block delimiters, for an input of about the length they cover.
/// No sequence has an offset of 0 with a match: the port asserts on those,
/// as `doc/parity.md` says.
fn randomSequences(random: std.Random, explicit: bool, list: *std.ArrayList(Sequence)) !u64 {
    var covered: u64 = 0;
    const n = random.uintLessThan(usize, 600);
    // One case in 4 has a few lengths and offsets at their bounds.
    const extremes = random.uintLessThan(u32, 4) == 0;
    for (0..n) |_| {
        const r = if (extremes) random.uintLessThan(u32, 100) else 5 + random.uintLessThan(u32, 95);
        const ll: u32 = if (r < 2) extreme(random) else random.uintLessThan(u32, 200);
        var ml: u32 = if (r >= 2 and r < 4) extreme(random) else random.uintLessThan(u32, 300);
        var off: u32 = if (r == 4)
            extreme(random)
        else
            1 + random.uintLessThan(u32, @intCast(@min(covered + 64, 1 << 20)));
        if (explicit and random.uintLessThan(u32, 25) == 0) {
            off = 0;
            ml = 0;
        } else if (ml == 0 and !explicit) {
            ml = 3;
        }
        if (ml == 0) off = 0;
        try list.append(gpa, .{ .offset = off, .lit_length = ll, .match_length = ml, .rep = 0 });
        covered += @as(u64, ll) + ml;
    }
    if (explicit) {
        const ll: u32 = random.uintLessThan(u32, 100);
        try list.append(gpa, .{ .offset = 0, .lit_length = ll, .match_length = 0, .rep = 0 });
        covered += ll;
    }
    return covered;
}

/// Whether the original's computations on `seqs` stay in range: its
/// lengths and offsets are 32-bit, and it adds them in 32 bits.
fn originalInRange(seqs: []const Sequence) bool {
    for (seqs) |s| {
        if (@as(u64, s.lit_length) + s.match_length >= (1 << 32) - (1 << 18)) return false;
        if (s.offset > std.math.maxInt(u32) - 3) return false;
    }
    return true;
}

test "review: compressSequences, random and out-of-range sequences, validation on" {
    const pool = try common.generated(600_000, 0.5, 0.3, 920);
    defer gpa.free(pool);
    const upstream = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
    defer _ = c.ZSTD_freeCCtx(upstream);
    const port = try zstd.CCtx.create(gpa);
    defer port.destroy() catch unreachable;
    var seqs: std.ArrayList(Sequence) = .empty;
    defer seqs.deinit(gpa);
    const out_size = c.ZSTD_compressBound(pool.len) + 1024;
    const expected = try gpa.alloc(u8, out_size);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, out_size);
    defer gpa.free(actual);
    var compared: usize = 0;
    var framed: usize = 0;
    for (0..common.fuzz_cases) |case| {
        const seed = common.fuzzSeed(921) +% case;
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        errdefer std.debug.print("fuzz seed {d}, case {d}\n", .{ seed, case });
        const explicit = random.boolean();
        seqs.clearRetainingCapacity();
        const covered = try randomSequences(random, explicit, &seqs);
        const src_len: usize = switch (random.uintLessThan(u32, 4)) {
            0 => random.uintLessThan(usize, 300_000),
            else => @intCast(@min(covered, pool.len)),
        };
        const src = pool[0..src_len];
        const levels = [_]i32{ 1, 3, 5, 12, 19 };
        const level = levels[random.uintLessThan(usize, levels.len)];
        const settings = [_]struct { u32, i32 }{
            .{ 100, level },
            .{ 1008, @intFromBool(explicit) }, // ZSTD_c_blockDelimiters
            .{ 1009, 1 }, // ZSTD_c_validateSequences
            .{ 1016, @intCast(random.uintLessThan(u32, 3)) }, // ZSTD_c_repcodeResolution
            .{ 201, @intFromBool(random.boolean()) },
            .{ 101, if (random.boolean()) 0 else 10 + @as(i32, @intCast(random.uintLessThan(u32, 14))) },
            .{ 105, if (random.boolean()) 0 else 3 },
        };
        try testing.expect(c.ZSTD_isError(c.ZSTD_CCtx_reset(upstream, 3)) == 0);
        try port.reset(.session_and_parameters);
        for (settings) |s| {
            const code = c.ZSTD_CCtx_setParameter(upstream, s[0], s[1]);
            const result = port.setParameter(@fromBackingInt(s[0]), s[1]);
            try @import("frame_test.zig").expectSameResult(code, result);
        }
        const result = port.compressSequences(actual, seqs.items, src);
        if (!originalInRange(seqs.items)) {
            // The original adds the lengths in 32 bits and goes on with the
            // wrapped sums, reading past its input, when it reaches such a
            // sequence; the port refuses it, or never reaches it.
            if (result) |_| {} else |err| try testing.expectEqual(error.ExternalSequencesInvalid, err);
            continue;
        }
        compared += 1;
        const code = c.ZSTD_compressSequences(
            upstream,
            expected.ptr,
            expected.len,
            @ptrCast(seqs.items.ptr),
            seqs.items.len,
            src.ptr,
            src.len,
        );
        try @import("frame_test.zig").expectSameResult(code, result);
        const n = result catch continue;
        framed += 1;
        try common.expectSameFrame(expected[0..code], actual[0..n]);
    }
    std.debug.print("compressSequences: {d} cases compared, {d} frames\n", .{ compared, framed });
}

const SharedPoolJob = struct {
    pool: *zstd.ThreadPool,
    src: []const u8,
    level: i32,
    workers: i32,
    expected: []const u8,
    frames: usize,
    failure: ?anyerror = null,

    fn run(job: *SharedPoolJob) void {
        job.compress() catch |err| {
            job.failure = err;
        };
    }

    fn compress(job: *SharedPoolJob) !void {
        const cctx = try zstd.CCtx.create(std.heap.c_allocator);
        defer cctx.destroy() catch unreachable;
        try cctx.refThreadPool(job.pool);
        cctx.setIo(io);
        _ = try cctx.setParameter(.compression_level, job.level);
        _ = try cctx.setParameter(.checksum_flag, 1);
        _ = try cctx.setParameter(.nb_workers, job.workers);
        _ = try cctx.setParameter(.job_size, 1 << 19);
        const dst = try std.heap.c_allocator.alloc(u8, c.ZSTD_compressBound(job.src.len));
        defer std.heap.c_allocator.free(dst);
        for (0..job.frames) |_| {
            const n = try cctx.compress2(dst, job.src);
            if (!std.mem.eql(u8, job.expected, dst[0..n])) return error.FramesDiffer;
        }
    }
};

test "review: contexts on four threads sharing a pool of two" {
    const pool = zstd.createThreadPool(gpa, io, 2) orelse return error.OutOfMemory;
    defer zstd.freeThreadPool(pool);
    var jobs: [4]SharedPoolJob = undefined;
    var inputs: [4][]u8 = undefined;
    for (&jobs, &inputs, 0..) |*job, *in, i| {
        in.* = try common.generated(1_200_000 + i * 300_000, 0.5, 0.3, @intCast(930 + i));
        const level: i32 = @intCast(1 + 4 * i);
        const workers: i32 = @intCast(1 + i % 3);
        const expected = try common.upstreamCompress2(&.{
            .{ .param = 100, .value = level },
            .{ .param = 201, .value = 1 },
            .{ .param = 400, .value = workers },
            .{ .param = 401, .value = 1 << 19 },
        }, in.*);
        job.* = .{ .pool = pool, .src = in.*, .level = level, .workers = workers, .expected = expected, .frames = 4 };
    }
    defer for (jobs, inputs) |job, in| {
        gpa.free(job.expected);
        gpa.free(in);
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, &jobs) |*t, *job| t.* = try std.Thread.spawn(.{}, SharedPoolJob.run, .{job});
    for (threads) |t| t.join();
    for (jobs) |job| if (job.failure) |err| return err;
}
