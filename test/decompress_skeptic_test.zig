//! The decompressor skeptic's tests: one per confirmed finding, named
//! `skeptic: ...`, each failing before its fix; and the probes that held
//! up, named `skeptic probe: ...`, kept as regression tests. The tests
//! that end in a panic of the port (ReleaseSafe) come last.

const std = @import("std");
const builtin = @import("builtin");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const dc = @import("decompress_common.zig");
const test_options = @import("test_options");

const gpa = dc.gpa;
const Pair = dc.Pair;
const Result = dc.Result;
const expectSameResult = dc.expectSameResult;
const testing = std.testing;
const params = zstd.params;

// --------------------------------------------------------
// Helpers
// --------------------------------------------------------

/// A buffer of `len` bytes between two inaccessible pages: placed at the
/// end of its pages (`at_end`), any access past its end faults, else any
/// access before its start does.
const Guarded = struct {
    mapping: []align(std.heap.page_size_min) u8,
    bytes: []u8,

    fn init(len: usize, at_end: bool) !Guarded {
        const page = std.heap.pageSize();
        const pages = std.math.divCeil(usize, @max(len, 1), page) catch unreachable;
        const mapping = try std.posix.mmap(null, (pages + 2) * page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        errdefer std.posix.munmap(mapping);
        if (std.os.linux.mprotect(mapping.ptr, page, .{}) != 0) return error.Mprotect;
        if (std.os.linux.mprotect(mapping.ptr + (pages + 1) * page, page, .{}) != 0) return error.Mprotect;
        const start = if (at_end) page + pages * page - len else page;
        return .{ .mapping = mapping, .bytes = mapping[start..][0..len] };
    }

    fn deinit(g: Guarded) void {
        std.posix.munmap(g.mapping);
    }

    fn dupe(src: []const u8, at_end: bool) !Guarded {
        const g = try init(src.len, at_end);
        @memcpy(g.bytes, src);
        return g;
    }
};

fn randomInput(random: std.Random) ![]u8 {
    const size = switch (random.uintLessThan(u32, 16)) {
        0 => random.uintAtMost(usize, 1 << 20),
        1, 2, 3, 4 => random.uintAtMost(usize, 100),
        else => random.uintAtMost(usize, 300_000),
    };
    if (random.boolean()) return dc.mixedInput(size, random.int(u32));
    return common.generated(size, random.float(f64), random.float(f64), random.int(u32));
}

fn randomParams(random: std.Random, list: *std.ArrayList(common.Param)) !void {
    try list.append(gpa, .{ .param = dc.c_level, .value = random.intRangeAtMost(i32, -7, 19) });
    if (random.boolean()) try list.append(gpa, .{ .param = dc.c_checksum_flag, .value = 1 });
    if (random.uintLessThan(u32, 3) == 0) try list.append(gpa, .{ .param = dc.c_content_size_flag, .value = 0 });
    if (random.uintLessThan(u32, 3) == 0) try list.append(gpa, .{ .param = dc.c_window_log, .value = random.intRangeAtMost(i32, 10, 23) });
    if (random.uintLessThan(u32, 6) == 0) try list.append(gpa, .{ .param = dc.c_literal_compression_mode, .value = random.intRangeAtMost(i32, 0, 2) });
    if (random.uintLessThan(u32, 6) == 0) try list.append(gpa, .{ .param = dc.c_target_cblock_size, .value = random.intRangeAtMost(i32, 1340, 20_000) });
    if (random.uintLessThan(u32, 6) == 0) try list.append(gpa, .{ .param = dc.c_max_block_size, .value = random.intRangeAtMost(i32, 1024, 1 << 17) });
}

fn corrupt(random: std.Random, frame: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, frame);
    for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
        if (bytes.items.len == 0) break;
        const at = if (random.boolean())
            random.uintLessThan(usize, @min(bytes.items.len, 64))
        else
            random.uintLessThan(usize, bytes.items.len);
        switch (random.uintLessThan(u32, 6)) {
            0, 1 => bytes.items[at] ^= @as(u8, 1) << random.int(u3),
            2 => bytes.items[at] = random.int(u8),
            3 => _ = bytes.orderedRemove(at),
            4 => try bytes.insert(gpa, at, random.int(u8)),
            else => bytes.shrinkRetainingCapacity(at),
        }
    }
    return bytes.toOwnedSlice(gpa);
}

// --------------------------------------------------------
// Findings
// --------------------------------------------------------

test "skeptic: readSkippableFrame on a frame that is not skippable, and on a skippable size that wraps" {
    // A regular frame: the original's `readSkippableFrameSize` error is not
    // returned, its `isSkippableFrame` check gives frameParameter_unsupported.
    const input = "a regular frame, not a skippable one, of a few dozen bytes; " ++
        "a regular frame, not a skippable one, of a few dozen bytes; " ++
        "a regular frame, not a skippable one, of a few dozen bytes.";
    const frame = try dc.compress(&.{.{ .param = dc.c_level, .value = 3 }}, input);
    defer gpa.free(frame);
    var c_dst: [512]u8 = undefined;
    var p_dst: [512]u8 = undefined;
    var failure: anyerror!void = {};
    {
        var c_magic: c_uint = 0;
        var p_magic: u32 = 0;
        const code = c.ZSTD_readSkippableFrame(&c_dst, c_dst.len, &c_magic, frame.ptr, frame.len);
        const result = zstd.readSkippableFrame(&p_dst, &p_magic, frame);
        expectSameResult(code, result) catch |err| {
            std.debug.print("a regular frame\n", .{});
            failure = err;
        };
    }
    // A skippable frame whose size field is 0xFFFFFFFF: the original's
    // overflow error is not returned either, its size check gives
    // srcSize_wrong.
    var skippable: [16]u8 = @splat(0);
    std.mem.writeInt(u32, skippable[0..4], params.magic_skippable_start + 5, .little);
    std.mem.writeInt(u32, skippable[4..8], 0xFFFF_FFFF, .little);
    {
        var c_magic: c_uint = 0;
        var p_magic: u32 = 0;
        const code = c.ZSTD_readSkippableFrame(&c_dst, c_dst.len, &c_magic, &skippable, skippable.len);
        const result = zstd.readSkippableFrame(&p_dst, &p_magic, &skippable);
        expectSameResult(code, result) catch |err| {
            std.debug.print("a skippable frame of size 0xFFFFFFFF\n", .{});
            failure = err;
        };
    }
    return failure;
}

test "skeptic: nextSrcSizeToDecompress after a block that fails" {
    // A frame of 100 bytes in one RLE block, then one compressed block
    // that does not decode: after decompressContinue fails on the block,
    // the original has set `expected` to 0, the port has not.
    var rle_frame: [10]u8 = undefined;
    std.mem.writeInt(u32, rle_frame[0..4], params.magic_number, .little);
    rle_frame[4] = 0x20; // single segment, 1-byte content size
    rle_frame[5] = 100;
    std.mem.writeInt(u24, rle_frame[6..9], (100 << 3) | (1 << 1) | 1, .little);
    rle_frame[9] = 'x';
    const input = try common.generated(50_000, 0.5, 0.3, 3);
    defer gpa.free(input);
    const good = try dc.compress(&.{.{ .param = dc.c_level, .value = 3 }}, input);
    defer gpa.free(good);
    const compressed = try gpa.dupe(u8, good);
    defer gpa.free(compressed);

    var failure: anyerror!void = {};
    for ([_][]const u8{ &rle_frame, compressed }, [_]usize{ 10, input.len / 2 }, [_][]const u8{ "RLE", "compressed" }) |frame, capacity, name| {
        const pair = try Pair.initNoAsm();
        defer pair.deinit();
        try expectSameResult(c.ZSTD_decompressBegin(pair.upstream), pair.port.decompressBegin());
        const c_out = try gpa.alloc(u8, input.len);
        defer gpa.free(c_out);
        const p_out = try gpa.alloc(u8, input.len);
        defer gpa.free(p_out);
        var pos: usize = 0;
        var out: usize = 0;
        var failed = false;
        while (true) {
            const next = c.ZSTD_nextSrcSizeToDecompress(pair.upstream);
            testing.expectEqual(next, pair.port.nextSrcSizeToDecompress()) catch |err| {
                std.debug.print("after a failed {s} block\n", .{name});
                failure = err;
                break;
            };
            try testing.expectEqual(c.ZSTD_nextInputType(pair.upstream), @backingInt(pair.port.nextInputType()));
            if (next == 0 or failed) break;
            if (pos + next > frame.len) break;
            const room = @min(capacity, input.len) - @min(out, @min(capacity, input.len));
            const code = c.ZSTD_decompressContinue(pair.upstream, c_out.ptr + out, room, frame.ptr + pos, next);
            const result = pair.port.decompressContinue(p_out[out..][0..room], frame[pos..][0..next]);
            try expectSameResult(code, result);
            if (c.ZSTD_isError(code) != 0) {
                failed = true;
                continue;
            }
            out += code;
            pos += next;
        }
        try testing.expect(failed);
    }
    return failure;
}

test "skeptic: decompressFrameExact on a context with several DDicts decodes with the wrong one" {
    // With `ref_multiple_ddicts`, decompressFrameExact starts the frame on
    // the last referenced DDict's content and tables, then picks the
    // frame's DDict by id, which only changes the id it checks (as the
    // original's one-shot functions do). A frame of the first DDict, with
    // no checksum, then decodes to wrong bytes with no error, where the
    // doc comment promises the dictionary the context refers to.
    const corpus = try common.generated(1 << 20, 0.4, 0.2, 905);
    defer gpa.free(corpus);
    var dicts: [2][]u8 = undefined;
    var ddicts: [2]*zstd.DDict = undefined;
    for (&dicts, &ddicts, 0..) |*d, *dd, i| {
        d.* = try dc.train(corpus[i * 400_000 ..], 16 << 10);
        std.mem.writeInt(u32, d.*[4..8], @intCast(7000 + i), .little);
        dd.* = try zstd.createDDict(gpa, d.*);
    }
    defer for (dicts, ddicts) |d, dd| {
        gpa.free(d);
        zstd.freeDDict(dd);
    };
    const input = corpus[100_000..][0..50_000];
    const frame = try dc.compressWithDict(input, dicts[0], 3, false);
    defer gpa.free(frame);
    const dctx = try zstd.DCtx.create(gpa);
    defer zstd.freeDCtx(dctx) catch unreachable;
    try dctx.setParameter(.ref_multiple_ddicts, 1);
    try dctx.refDDict(ddicts[0]);
    try dctx.refDDict(ddicts[1]);
    const out = try gpa.alloc(u8, input.len);
    defer gpa.free(out);
    @memset(out, 0);
    var failure: anyerror!void = {};
    if (dctx.decompressFrameExact(out, frame, .{})) |_| {
        testing.expectEqualSlices(u8, input, out) catch |err| {
            failure = err;
        };
    } else |err| {
        std.debug.print("decompressFrameExact: {t}\n", .{err});
        failure = err;
    }
    // A stream, after it, picks the frame's DDict before it starts the
    // frame.
    {
        var in: params.InBuffer = .{ .src = frame };
        var o: params.OutBuffer = .{ .dst = out };
        try dctx.setParameter(.stable_out_buffer, 1);
        while (in.pos < in.src.len) _ = try dctx.decompressStream(&o, &in);
        try testing.expectEqualSlices(u8, input, out);
    }
    return failure;
}

// --------------------------------------------------------
// Probes that held up
// --------------------------------------------------------

test "skeptic probe: frames decode with their output and input against inaccessible pages" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(901));
    const random = prng.random();
    const cases = @max(common.fuzz_cases / 4, 50);
    for (0..cases) |case| {
        errdefer std.debug.print("case {d}\n", .{case});
        const input = try randomInput(random);
        defer gpa.free(input);
        var list: std.ArrayList(common.Param) = .empty;
        defer list.deinit(gpa);
        try randomParams(random, &list);
        const frame = dc.compress(list.items, input) catch continue;
        defer gpa.free(frame);
        const variants = [_][]const u8{ frame, try corrupt(random, frame) };
        defer gpa.free(variants[1]);
        for (variants, 0..) |src_bytes, v| {
            for ([_]bool{ true, false }) |at_end| {
                const src = try Guarded.dupe(src_bytes, at_end);
                defer src.deinit();
                const capacity = switch (random.uintLessThan(u32, 3)) {
                    0 => input.len,
                    1 => random.uintAtMost(usize, input.len),
                    else => input.len + random.uintAtMost(usize, 200),
                };
                const dst = try Guarded.init(capacity, at_end);
                defer dst.deinit();
                const expected = try gpa.alloc(u8, capacity);
                defer gpa.free(expected);
                const upstream = c.ZSTD_createDCtx() orelse return error.OutOfMemory;
                defer _ = c.ZSTD_freeDCtx(upstream);
                _ = c.ZSTD_DCtx_setParameter(upstream, dc.d_disable_huffman_assembly, 1);
                const code = c.ZSTD_decompressDCtx(upstream, expected.ptr, expected.len, src_bytes.ptr, src_bytes.len);
                var dctx: zstd.DCtx = undefined;
                dctx.init();
                const result = dctx.decompressDCtx(dst.bytes, src.bytes);
                try expectSameResult(code, result);
                try dc.expectSameOutput(Result.of(code), expected, dst.bytes);
                if (v == 0 and capacity == input.len) {
                    try dctx.decompressFrameExact(dst.bytes, src.bytes, .{});
                    try testing.expectEqualSlices(u8, input, dst.bytes);
                } else {
                    dctx.decompressFrameExact(dst.bytes, src.bytes, .{}) catch {};
                }
                // Streamed into a stable output of the same size.
                const pstream = try zstd.DCtx.create(gpa);
                defer zstd.freeDCtx(pstream) catch unreachable;
                try pstream.setParameter(.stable_out_buffer, 1);
                var in: params.InBuffer = .{ .src = src.bytes };
                var out: params.OutBuffer = .{ .dst = dst.bytes };
                for (0..64) |_| {
                    const r = pstream.decompressStream(&out, &in) catch break;
                    if (r == 0) break;
                }
            }
        }
    }
}

test "skeptic probe: in-place decoding with the original's margin and smaller ones" {
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(902));
    const random = prng.random();
    const cases = @max(common.fuzz_cases / 8, 30);
    for (0..cases) |case| {
        errdefer std.debug.print("case {d}\n", .{case});
        const input = try randomInput(random);
        defer gpa.free(input);
        var list: std.ArrayList(common.Param) = .empty;
        defer list.deinit(gpa);
        try randomParams(random, &list);
        const good = dc.compress(list.items, input) catch continue;
        defer gpa.free(good);
        const frame = if (random.uintLessThan(u32, 3) == 0) try corrupt(random, good) else try gpa.dupe(u8, good);
        defer gpa.free(frame);
        const margin_code = c.ZSTD_decompressionMargin(frame.ptr, frame.len);
        try expectSameResult(margin_code, zstd.decompressionMargin(frame));
        const margin: usize = if (c.ZSTD_isError(margin_code) != 0) frame.len else margin_code;
        const less = switch (random.uintLessThan(u32, 3)) {
            0 => 0,
            1 => random.uintAtMost(usize, @min(margin, 64)),
            else => random.uintAtMost(usize, margin),
        };
        const size = input.len + margin - less;
        if (size < frame.len) continue;
        const c_buf = try gpa.alloc(u8, size);
        defer gpa.free(c_buf);
        const p_buf = try gpa.alloc(u8, size);
        defer gpa.free(p_buf);
        @memcpy(c_buf[size - frame.len ..], frame);
        @memcpy(p_buf[size - frame.len ..], frame);
        const pair = try Pair.initNoAsm();
        defer pair.deinit();
        const code = c.ZSTD_decompressDCtx(pair.upstream, c_buf.ptr, size, c_buf.ptr + size - frame.len, frame.len);
        const result = pair.port.decompressDCtx(p_buf, p_buf[size - frame.len ..]);
        try expectSameResult(code, result);
        try dc.expectSameOutput(Result.of(code), c_buf, p_buf);
        if (less == 0 and frame.len == good.len and std.mem.eql(u8, frame, good)) {
            try testing.expect(c.ZSTD_isError(code) == 0);
            try testing.expectEqualSlices(u8, input, p_buf[0..input.len]);
        }
        // The input before the output, overlapping it: the output catches
        // up with input it has not read. The original's copies are then
        // undefined (memcpy of overlapping ranges); the port's must not
        // fail a safety check.
        {
            const shift = random.uintAtMost(usize, @min(frame.len, 300));
            const buf = try gpa.alloc(u8, @max(frame.len, input.len + 1000) + shift);
            defer gpa.free(buf);
            @memcpy(buf[0..frame.len], frame);
            var dctx: zstd.DCtx = undefined;
            dctx.init();
            _ = dctx.decompressDCtx(buf[shift..], buf[0..frame.len]) catch {};
        }
    }
}

test "skeptic probe: frame size readers on corrupted sequences of frames" {
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(903));
    const random = prng.random();
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(gpa);
    for (0..6) |_| {
        const input = try common.generated(random.uintAtMost(usize, 3000), 0.5, 0.3, random.int(u32));
        defer gpa.free(input);
        const frame = try dc.compress(&.{
            .{ .param = dc.c_level, .value = 1 },
            .{ .param = dc.c_checksum_flag, .value = @intFromBool(random.boolean()) },
            .{ .param = dc.c_content_size_flag, .value = @intFromBool(random.boolean()) },
        }, input);
        defer gpa.free(frame);
        try frames.appendSlice(gpa, frame);
        var skippable: [24]u8 = undefined;
        const n = try zstd.writeSkippableFrame(&skippable, "skippable", random.uintLessThan(u32, 16));
        try frames.appendSlice(gpa, skippable[0..n]);
    }
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("case {d}\n", .{case});
        const bad = try corrupt(random, frames.items);
        defer gpa.free(bad);
        const start = random.uintAtMost(usize, @min(bad.len, 40));
        const src = bad[if (random.boolean()) 0 else start..];
        try testing.expectEqual(c.ZSTD_findDecompressedSize(src.ptr, src.len), zstd.findDecompressedSize(src));
        try testing.expectEqual(c.ZSTD_decompressBound(src.ptr, src.len), zstd.decompressBound(src));
        try testing.expectEqual(c.ZSTD_getDecompressedSize(src.ptr, src.len), zstd.getDecompressedSize(src));
        try expectSameResult(c.ZSTD_findFrameCompressedSize(src.ptr, src.len), zstd.findFrameCompressedSize(src));
        try expectSameResult(c.ZSTD_decompressionMargin(src.ptr, src.len), zstd.decompressionMargin(src));
        try testing.expectEqual(c.ZSTD_getDictID_fromFrame(src.ptr, src.len), zstd.getDictIdFromFrame(src));
        try testing.expectEqual(c.ZSTD_isFrame(src.ptr, src.len) != 0, zstd.isFrame(src));
        var c_dst: [64]u8 = undefined;
        var p_dst: [64]u8 = undefined;
        var c_magic: c_uint = 0;
        var p_magic: u32 = 0;
        const code = c.ZSTD_readSkippableFrame(&c_dst, c_dst.len, &c_magic, src.ptr, src.len);
        const result = zstd.readSkippableFrame(&p_dst, &p_magic, src);
        // The first finding: only compared where the frame is skippable.
        if (zstd.isSkippableFrame(src) and src.len >= 8 and std.mem.readInt(u32, src[4..8], .little) < 0xFFFF_FFF8) {
            try expectSameResult(code, result);
        }
    }
}

test "skeptic probe: corrupted frames through the buffer-less API, dictionaries, blocks and the magicless format" {
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(904));
    const random = prng.random();
    const corpus = try common.generated(1 << 20, 0.5, 0.2, 904);
    defer gpa.free(corpus);
    const dict = try dc.train(corpus, 16 << 10);
    defer gpa.free(dict);
    const u_ddict = c.ZSTD_createDDict(dict.ptr, dict.len) orelse return error.OutOfMemory;
    defer _ = c.ZSTD_freeDDict(u_ddict);
    const p_ddict = try zstd.createDDict(gpa, dict);
    defer zstd.freeDDict(p_ddict);
    const Frame = struct { bytes: []u8, size: usize, dict: bool, magicless: bool };
    var pool: std.ArrayList(Frame) = .empty;
    defer {
        for (pool.items) |f| gpa.free(f.bytes);
        pool.deinit(gpa);
    }
    for (0..30) |i| {
        const size = random.uintAtMost(usize, 300_000);
        const start = random.uintAtMost(usize, corpus.len - size);
        const input = corpus[start..][0..size];
        const use_dict = i % 3 == 0;
        const magicless = i % 5 == 1;
        const frame = if (use_dict)
            try dc.compressWithDict(input, dict, random.intRangeAtMost(i32, 1, 19), random.boolean())
        else
            try dc.compress(&.{
                .{ .param = dc.c_level, .value = random.intRangeAtMost(i32, -3, 19) },
                .{ .param = dc.c_checksum_flag, .value = @intFromBool(random.boolean()) },
                .{ .param = dc.c_format, .value = @intFromBool(magicless) },
                .{ .param = dc.c_window_log, .value = random.intRangeAtMost(i32, 10, 20) },
            }, input);
        try pool.append(gpa, .{ .bytes = frame, .size = size, .dict = use_dict, .magicless = magicless });
    }
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("case {d}\n", .{case});
        const f = pool.items[random.uintLessThan(usize, pool.items.len)];
        const bad = try corrupt(random, f.bytes);
        defer gpa.free(bad);
        const capacity = switch (random.uintLessThan(u32, 3)) {
            0 => f.size,
            1 => random.uintAtMost(usize, f.size),
            else => f.size + random.uintAtMost(usize, 300_000),
        };
        const pair = try Pair.initNoAsm();
        defer pair.deinit();
        if (f.magicless) try pair.set(.format, 1);
        // One shot, with the dictionary as bytes, or as a DDict.
        if (f.dict) {
            _ = try pair.decompressUsingDict(bad, capacity, dict);
            const expected = try gpa.alloc(u8, capacity);
            defer gpa.free(expected);
            const actual = try gpa.alloc(u8, capacity);
            defer gpa.free(actual);
            const code = c.ZSTD_decompress_usingDDict(pair.upstream, expected.ptr, capacity, bad.ptr, bad.len, u_ddict);
            const result = pair.port.decompressUsingDDict(actual, bad, p_ddict);
            try expectSameResult(code, result);
            try dc.expectSameOutput(Result.of(code), expected, actual);
        } else {
            _ = try pair.decompressDCtx(bad, capacity);
        }
        // Buffer-less, into one buffer, until the first error.
        {
            if (f.dict) {
                try expectSameResult(c.ZSTD_decompressBegin_usingDict(pair.upstream, dict.ptr, dict.len), pair.port.decompressBeginUsingDict(dict));
            } else {
                try expectSameResult(c.ZSTD_decompressBegin(pair.upstream), pair.port.decompressBegin());
            }
            const expected = try gpa.alloc(u8, capacity);
            defer gpa.free(expected);
            const actual = try gpa.alloc(u8, capacity);
            defer gpa.free(actual);
            var ip: usize = 0;
            var op: usize = 0;
            while (true) {
                const next = c.ZSTD_nextSrcSizeToDecompress(pair.upstream);
                try testing.expectEqual(next, pair.port.nextSrcSizeToDecompress());
                try testing.expectEqual(c.ZSTD_nextInputType(pair.upstream), @backingInt(pair.port.nextInputType()));
                if (next == 0 or ip + next > bad.len) break;
                const room = @min(capacity - op, 140_000);
                const code = c.ZSTD_decompressContinue(pair.upstream, expected[op..].ptr, room, bad[ip..].ptr, next);
                const result = pair.port.decompressContinue(actual[op..][0..room], bad[ip..][0..next]);
                try expectSameResult(code, result);
                if (c.ZSTD_isError(code) != 0) break;
                try testing.expectEqualSlices(u8, expected[op..][0..code], actual[op..][0..code]);
                op += code;
                ip += next;
            }
        }
        // The first block alone, with decompressBlock.
        if (!f.magicless and bad.len > 18) {
            var zfh: zstd.FrameHeader = .{};
            const header = zstd.getFrameHeader(&zfh, bad) catch 0;
            if (header == 0 and zfh.header_size + 3 < bad.len) {
                const block_src = bad[zfh.header_size + 3 ..];
                const n = @min(block_src.len, random.uintAtMost(usize, 140_000));
                try expectSameResult(c.ZSTD_decompressBegin(pair.upstream), pair.port.decompressBegin());
                const expected = try gpa.alloc(u8, capacity);
                defer gpa.free(expected);
                const actual = try gpa.alloc(u8, capacity);
                defer gpa.free(actual);
                const code = c.ZSTD_decompressBlock(pair.upstream, expected.ptr, capacity, block_src.ptr, n);
                const result = pair.port.decompressBlock(actual, block_src[0..n]);
                try expectSameResult(code, result);
                try dc.expectSameOutput(Result.of(code), expected, actual);
            }
        }
    }
}

/// The blocks of a frame, headers included.
fn frameBlocks(frame: []const u8, list: *std.ArrayList([]const u8)) !void {
    var zfh: zstd.FrameHeader = .{};
    if (try zstd.getFrameHeader(&zfh, frame) != 0) return;
    var ip: usize = zfh.header_size;
    while (ip + 3 <= frame.len) {
        const header = std.mem.readInt(u24, frame[ip..][0..3], .little);
        const block_type = (header >> 1) & 3;
        const size: usize = if (block_type == 1) 1 else header >> 3;
        if (ip + 3 + size > frame.len) return;
        try list.append(gpa, frame[ip..][0 .. 3 + size]);
        ip += 3 + size;
        if (header & 1 != 0) return;
    }
}

test "skeptic probe: frames spliced from the blocks of other frames" {
    // Blocks taken from different frames and put in a new one: treeless
    // literals and repeated tables of another frame's block, repeat
    // offsets and matches reaching into history that is not there, blocks
    // larger than the new window, and every block type in any order.
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(906));
    const random = prng.random();
    var frames: std.ArrayList([]u8) = .empty;
    defer {
        for (frames.items) |f| gpa.free(f);
        frames.deinit(gpa);
    }
    var blocks: std.ArrayList([]const u8) = .empty;
    defer blocks.deinit(gpa);
    for (0..40) |_| {
        const input = try randomInput(random);
        defer gpa.free(input);
        var list: std.ArrayList(common.Param) = .empty;
        defer list.deinit(gpa);
        try randomParams(random, &list);
        const frame = dc.compress(list.items, input) catch continue;
        try frames.append(gpa, frame);
        try frameBlocks(frame, &blocks);
    }
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("case {d}\n", .{case});
        frame.clearRetainingCapacity();
        var head: [14]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], params.magic_number, .little);
        const checksum = random.uintLessThan(u32, 4) == 0;
        var n: usize = 6;
        if (random.boolean()) {
            // A window descriptor, no content size.
            head[4] = if (checksum) 0x04 else 0x00;
            head[5] = random.intRangeAtMost(u8, 0, 0x68);
        } else {
            // Single segment, a 4-byte content size.
            head[4] = 0xA0 | @as(u8, if (checksum) 0x04 else 0x00);
            std.mem.writeInt(u32, head[5..9], random.uintAtMost(u32, 600_000), .little);
            n = 9;
        }
        try frame.appendSlice(gpa, head[0..n]);
        const nb = random.intRangeAtMost(usize, 1, 6);
        for (0..nb) |k| {
            const b = blocks.items[random.uintLessThan(usize, blocks.items.len)];
            const at = frame.items.len;
            try frame.appendSlice(gpa, b);
            var header = std.mem.readInt(u24, frame.items[at..][0..3], .little);
            header = (header & ~@as(u24, 1)) | @intFromBool(k == nb - 1);
            std.mem.writeInt(u24, frame.items[at..][0..3], header, .little);
        }
        if (checksum) try frame.appendSlice(gpa, &.{ 1, 2, 3, 4 });
        const capacity = random.uintAtMost(usize, 700_000);
        const pair = try Pair.initNoAsm();
        defer pair.deinit();
        if (random.boolean()) try pair.set(.force_ignore_checksum, 1);
        _ = try pair.decompressDCtx(frame.items, capacity);
        try @import("decompress_test.zig").expectSameStream(pair, frame.items, @max(capacity, 1), random.intRangeAtMost(usize, 1, 200_000), random.intRangeAtMost(usize, 1, 200_000));
    }
}

// --------------------------------------------------------
// Findings that end in a panic of the port
// --------------------------------------------------------

/// The index the original's set of DDicts gives `dict_id` in a table of
/// `size` entries.
fn hashSetIndex(dict_id: u32, size: usize) usize {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, dict_id, .little);
    return @truncate(std.hash.XxHash64.hash(0, &bytes) & (size - 1));
}

test "skeptic: a frame's dictionary id probing past the last slot of the DDict set" {
    // With `ref_multiple_ddicts`, a frame's dictionary id is looked up in
    // an open-addressing table of 64 entries. The probe goes from index i
    // to (i & 63) + 1, so from slot 63 it reads slot 64, one past the
    // table (the original reads past its allocation too). A context with
    // one DDict in slot 63 and a frame whose id also hashes to 63 makes the
    // port index the table out of bounds: a panic in ReleaseSafe, a read
    // past the allocation in ReleaseFast.
    var ids: [2]u32 = undefined;
    var found: usize = 0;
    var id: u32 = 1;
    while (found < 2) : (id += 1) {
        if (hashSetIndex(id, 64) == 63) {
            ids[found] = id;
            found += 1;
        }
    }
    const dict_file = try common.readFile(test_options.reference, "tests/golden-dictionaries/http-dict-missing-symbols");
    defer gpa.free(dict_file);
    std.mem.writeInt(u32, dict_file[4..8], ids[0], .little);
    const ddict = try zstd.createDDict(gpa, dict_file);
    defer zstd.freeDDict(ddict);
    const dctx = try zstd.DCtx.create(gpa);
    defer zstd.freeDCtx(dctx) catch unreachable;
    try dctx.setParameter(.ref_multiple_ddicts, 1);
    try dctx.refDDict(ddict);
    // A frame asking for the other id: magic, a 4-byte dictionary id, a
    // window byte, the id, and an empty last raw block.
    var frame: [13]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], params.magic_number, .little);
    frame[4] = 0x03;
    frame[5] = 0x00;
    std.mem.writeInt(u32, frame[6..10], ids[1], .little);
    std.mem.writeInt(u24, frame[10..13], 1, .little);
    var out: [16]u8 = undefined;
    // The frame names a dictionary the context does not have.
    try testing.expectError(error.DictionaryWrong, dctx.decompressDCtx(&out, &frame));
}

test "skeptic: estimateDStreamSize of a window near the address space wraps as the original's" {
    // The port adds the sizes with `+`: an integer overflow panic in
    // ReleaseSafe, where the original's size_t sums wrap.
    const window = std.math.maxInt(usize) - 256 * 1024 - 64;
    try testing.expectEqual(c.ZSTD_estimateDStreamSize(window), try zstd.estimateDStreamSize(window));
}

test "skeptic: estimateDDictSize of a size near the address space wraps as the original's" {
    const dict_size = std.math.maxInt(usize) - 100;
    try testing.expectEqual(c.ZSTD_estimateDDictSize(dict_size, 0), zstd.estimateDDictSize(dict_size, .by_copy));
}

test "skeptic: decompressionMarginBound of a size near the address space wraps as ZSTD_DECOMPRESSION_MARGIN" {
    const original = std.math.maxInt(usize) - 10;
    try testing.expectEqual(c.reference_decompressionMargin(original, 1 << 17), zstd.decompressionMarginBound(original, 1 << 17));
}

test "skeptic: a second DDict whose id hashes to the last slot of the DDict set" {
    // The same probe when a DDict is added: the second of two DDicts whose
    // ids both hash to slot 63 is looked for, then stored, at slot 64.
    var ids: [2]u32 = undefined;
    var found: usize = 0;
    var id: u32 = 1;
    while (found < 2) : (id += 1) {
        if (hashSetIndex(id, 64) == 63) {
            ids[found] = id;
            found += 1;
        }
    }
    const dict_file = try common.readFile(test_options.reference, "tests/golden-dictionaries/http-dict-missing-symbols");
    defer gpa.free(dict_file);
    var ddicts: [2]*zstd.DDict = undefined;
    for (&ddicts, ids) |*d, i| {
        std.mem.writeInt(u32, dict_file[4..8], i, .little);
        d.* = try zstd.createDDict(gpa, dict_file);
    }
    defer for (ddicts) |d| zstd.freeDDict(d);
    const dctx = try zstd.DCtx.create(gpa);
    defer zstd.freeDCtx(dctx) catch unreachable;
    try dctx.setParameter(.ref_multiple_ddicts, 1);
    try dctx.refDDict(ddicts[0]);
    try dctx.refDDict(ddicts[1]);
}
