//! Oracle tests of the decompressor's other ways in and of its parts:
//! streaming with every buffer size, stable output and bounded windows;
//! the buffer-less API with contiguous and scattered output; parameters,
//! sizes and static objects; the Huffman decoders on their own; and the
//! fuzzers, which decode random frames every way and corrupted frames in
//! one shot and streamed, comparing every result with the original's.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const dc = @import("decompress_common.zig");
const dtest = @import("decompress_test.zig");

const gpa = dc.gpa;
const Pair = dc.Pair;
const Result = dc.Result;
const Stats = dc.Stats;
const expectSameResult = dc.expectSameResult;
const testing = std.testing;
const params = zstd.params;

/// As `decompress_test.expectSameStream`, with sizes drawn from `random`
/// for each call, 0 among them; with `stable`, the output is the whole
/// buffer on every call, as a stable output must be.
fn expectSameStreamRandom(pair: Pair, src: []const u8, capacity: usize, random: std.Random, stable: bool) !void {
    try expectSameResult(c.ZSTD_DCtx_reset(pair.upstream, 1), pair.port.reset(.session_only));
    const expected = try gpa.alloc(u8, capacity);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, capacity);
    defer gpa.free(actual);
    var in_pos: usize = 0;
    var out_pos: usize = 0;
    var stuck: usize = 0;
    var calls: usize = 0;
    while (calls < 200_000) : (calls += 1) {
        const in_end = @min(src.len, in_pos + step(random));
        const out_end = if (stable) capacity else @min(capacity, out_pos + step(random));
        var c_in: c.ZSTD_inBuffer = .{ .src = src.ptr, .size = in_end, .pos = in_pos };
        var c_out: c.ZSTD_outBuffer = .{ .dst = expected.ptr, .size = out_end, .pos = out_pos };
        var p_in: params.InBuffer = .{ .src = src[0..in_end], .pos = in_pos };
        var p_out: params.OutBuffer = .{ .dst = actual[0..out_end], .pos = out_pos };
        const code = c.ZSTD_decompressStream(pair.upstream, &c_out, &c_in);
        const result = pair.port.decompressStream(&p_out, &p_in);
        expectSameResult(code, result) catch |err| {
            std.debug.print("call {d}, in {d}..{d}, out {d}..{d}\n", .{ calls, in_pos, in_end, out_pos, out_end });
            return err;
        };
        try testing.expectEqual(c_in.pos, p_in.pos);
        try testing.expectEqual(c_out.pos, p_out.pos);
        if (c.ZSTD_isError(code) != 0) return;
        const moved = c_in.pos != in_pos or c_out.pos != out_pos;
        in_pos = c_in.pos;
        out_pos = c_out.pos;
        try testing.expectEqualSlices(u8, expected[0..out_pos], actual[0..out_pos]);
        if (code == 0 and in_pos == src.len) return;
        stuck = if (moved) 0 else stuck + 1;
        // The original's limit on calls without progress is 16.
        if (stuck > 40) return;
    }
    return error.TooManyCalls;
}

/// A size for one streaming call: small, block-sized or large.
fn step(random: std.Random) usize {
    return switch (random.uintLessThan(u32, 8)) {
        0 => 0,
        1 => 1,
        2, 3 => random.uintAtMost(usize, 64),
        4, 5 => random.uintAtMost(usize, 4096),
        6 => random.uintAtMost(usize, 140_000),
        else => random.uintAtMost(usize, 1 << 20),
    };
}

test "streaming: every frame kind in pieces of every size" {
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(21));
    const random = prng.random();
    const input = try dc.mixedInput(1 << 20, 21);
    defer gpa.free(input);
    for ([_]i32{ -5, 1, 3, 7, 13, 19 }) |level| {
        for ([_]i32{ 0, 1 }) |content_size| {
            const frame = try dc.compress(&.{
                .{ .param = dc.c_level, .value = level },
                .{ .param = dc.c_checksum_flag, .value = 1 },
                .{ .param = dc.c_content_size_flag, .value = content_size },
                .{ .param = dc.c_window_log, .value = 18 },
            }, input);
            defer gpa.free(frame);
            const pair = try Pair.init();
            defer pair.deinit();
            for (0..4) |_| try expectSameStreamRandom(pair, frame, input.len, random, false);
            try expectSameStreamRandom(pair, frame, input.len + 1, random, false);
            // Several frames in a row on one context.
            const two = try std.mem.concat(gpa, u8, &.{ frame, frame });
            defer gpa.free(two);
            try expectSameStreamRandom(pair, two, 2 * input.len, random, false);
            // The simple arguments.
            var expected: [70_000]u8 = undefined;
            var actual: [70_000]u8 = undefined;
            var c_dst: usize = 0;
            var c_src: usize = 0;
            var p_dst: usize = 0;
            var p_src: usize = 0;
            _ = c.ZSTD_DCtx_reset(pair.upstream, 1);
            try pair.port.reset(.session_only);
            const code = c.ZSTD_decompressStream_simpleArgs(pair.upstream, &expected, expected.len, &c_dst, frame.ptr, frame.len, &c_src);
            const result = pair.port.decompressStreamSimpleArgs(&actual, &p_dst, frame, &p_src);
            try expectSameResult(code, result);
            try testing.expectEqual(c_dst, p_dst);
            try testing.expectEqual(c_src, p_src);
            try testing.expectEqualSlices(u8, expected[0..c_dst], actual[0..p_dst]);
            // The buffers the stream made.
            try testing.expectEqual(c.ZSTD_sizeof_DStream(pair.upstream), zstd.sizeofDStream(pair.port));
        }
    }
}

test "streaming: a stable output, and an output that moves when it must not" {
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(22));
    const random = prng.random();
    const input = try dc.mixedInput(800_000, 22);
    defer gpa.free(input);
    for ([_]i32{ 0, 1 }) |content_size| {
        const frame = try dc.compress(&.{
            .{ .param = dc.c_level, .value = 5 },
            .{ .param = dc.c_content_size_flag, .value = content_size },
        }, input);
        defer gpa.free(frame);
        const pair = try Pair.init();
        defer pair.deinit();
        try pair.set(.stable_out_buffer, 1);
        for (0..3) |_| try expectSameStreamRandom(pair, frame, input.len, random, true);
        // A stable output too small for the frame's size.
        try expectSameStreamRandom(pair, frame, input.len - 1, random, true);
        // Each call's output must be the last call's.
        try dtest.expectSameStream(pair, frame, input.len, 1000, 100_000);
        try testing.expectEqual(c.ZSTD_sizeof_DStream(pair.upstream), zstd.sizeofDStream(pair.port));
    }
}

test "streaming: windows past the largest the stream accepts, and static streams" {
    const input = try dc.mixedInput(3 << 20, 23);
    defer gpa.free(input);
    for ([_]i32{ 10, 17, 20, 22, 23 }) |window_log| {
        const frame = try dc.compress(&.{
            .{ .param = dc.c_level, .value = 3 },
            .{ .param = dc.c_window_log, .value = window_log },
            .{ .param = dc.c_content_size_flag, .value = 0 },
        }, input);
        defer gpa.free(frame);
        const pair = try Pair.init();
        defer pair.deinit();
        for ([_]i32{ 10, 17, 21, 22, 0 }) |log_max| {
            try pair.set(.window_log_max, log_max);
            try dtest.expectSameStream(pair, frame, input.len, 1 << 16, 1 << 16);
        }
        const window = @as(usize, 1) << @intCast(window_log);
        try testing.expectEqual(c.ZSTD_estimateDStreamSize(window), try zstd.estimateDStreamSize(window));
        try expectSameResult(c.ZSTD_DCtx_setMaxWindowSize(pair.upstream, window), pair.port.setMaxWindowSize(window));

        // Static streams of the estimated size, and of one byte less.
        const estimate = c.ZSTD_estimateDStreamSize_fromFrame(frame.ptr, frame.len);
        try testing.expectEqual(estimate, try zstd.estimateDStreamSizeFromFrame(frame));
        for ([_]usize{ estimate, estimate - 1 }) |size| {
            const u_buffer = try gpa.alignedAlloc(u8, .@"8", size);
            defer gpa.free(u_buffer);
            const p_buffer = try gpa.alignedAlloc(u8, .@"8", size);
            defer gpa.free(p_buffer);
            const u = c.ZSTD_initStaticDCtx(u_buffer.ptr, u_buffer.len) orelse return error.StaticDCtx;
            const p = zstd.initStaticDCtx(p_buffer) orelse return error.StaticDCtx;
            const static_pair: Pair = .{ .port = p, .upstream = u };
            try static_pair.set(.window_log_max, 23);
            try dtest.expectSameStream(static_pair, frame, input.len, 1 << 16, 1 << 16);
            try testing.expectEqual(c.ZSTD_sizeof_DStream(u), zstd.sizeofDStream(p));
        }
    }
}

test "buffer-less: decompressContinue, into one buffer and into scattered pieces" {
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(24));
    const random = prng.random();
    const input = try dc.mixedInput(1 << 20, 24);
    defer gpa.free(input);
    const corpus = try common.generated(1 << 20, 0.5, 0.1, 24);
    defer gpa.free(corpus);
    const dict = try dc.train(corpus, 16 << 10);
    defer gpa.free(dict);
    for ([_]i32{ 1, 3, 19 }) |level| {
        for ([_]bool{ false, true }) |use_dict| {
            const frame = if (use_dict)
                try dc.compressWithDict(input, dict, level, true)
            else
                try dc.compress(&.{
                    .{ .param = dc.c_level, .value = level },
                    .{ .param = dc.c_checksum_flag, .value = 1 },
                    .{ .param = dc.c_window_log, .value = 20 },
                }, input);
            defer gpa.free(frame);
            for ([_]bool{ false, true }) |scattered| {
                const pair = try Pair.init();
                defer pair.deinit();
                const room = input.len + 100_000 + 140_000;
                const expected = try gpa.alloc(u8, room);
                defer gpa.free(expected);
                const actual = try gpa.alloc(u8, room);
                defer gpa.free(actual);
                const u_dict: []const u8 = if (use_dict) dict else &.{};
                try expectSameResult(
                    c.ZSTD_decompressBegin_usingDict(pair.upstream, u_dict.ptr, u_dict.len),
                    pair.port.decompressBeginUsingDict(u_dict),
                );
                var ip: usize = 0;
                var op: usize = 0;
                var decoded: std.ArrayList(u8) = .empty;
                defer decoded.deinit(gpa);
                var moved_once = false;
                while (true) {
                    const next = c.ZSTD_nextSrcSizeToDecompress(pair.upstream);
                    try testing.expectEqual(next, pair.port.nextSrcSizeToDecompress());
                    try testing.expectEqual(c.ZSTD_nextInputType(pair.upstream), @backingInt(pair.port.nextInputType()));
                    if (next == 0) break;
                    // Scattered: the second half of the frame elsewhere,
                    // so the first half becomes the previous segment.
                    if (scattered and !moved_once and op >= input.len / 2) {
                        op += random.intRangeAtMost(usize, 1, 100_000);
                        moved_once = true;
                    }
                    const capacity = @min(room - op, 140_000);
                    const code = c.ZSTD_decompressContinue(pair.upstream, expected[op..].ptr, capacity, frame[ip..].ptr, next);
                    const result = pair.port.decompressContinue(actual[op..][0..capacity], frame[ip..][0..next]);
                    try expectSameResult(code, result);
                    if (c.ZSTD_isError(code) != 0) return error.UpstreamFailed;
                    try testing.expectEqualSlices(u8, expected[op..][0..code], actual[op..][0..code]);
                    try decoded.appendSlice(gpa, actual[op..][0..code]);
                    op += code;
                    ip += next;

                    // A copy of the context goes on with the same frame.
                    if (random.uintLessThan(u32, 8) == 0) {
                        const copy = try zstd.DCtx.create(gpa);
                        defer zstd.freeDCtx(copy) catch unreachable;
                        copy.copy(pair.port);
                        const u_copy = c.ZSTD_createDCtx() orelse return error.OutOfMemory;
                        defer _ = c.ZSTD_freeDCtx(u_copy);
                        c.ZSTD_copyDCtx(u_copy, pair.upstream);
                        try testing.expectEqual(c.ZSTD_nextSrcSizeToDecompress(u_copy), copy.nextSrcSizeToDecompress());
                    }
                }
                try testing.expectEqual(frame.len, ip);
                try testing.expectEqualSlices(u8, input, decoded.items);
            }
        }
    }
}

test "buffer-less: decompressBlock and insertBlock" {
    const input = try dc.mixedInput(1 << 20, 25);
    defer gpa.free(input);
    for ([_]i32{ 1, 5, 19 }) |level| {
        const cctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
        defer _ = c.ZSTD_freeCCtx(cctx);
        _ = c.ZSTD_compressBegin(cctx, level);
        const block_size = c.ZSTD_getBlockSize(cctx);
        const pair = try Pair.init();
        defer pair.deinit();
        try expectSameResult(c.ZSTD_decompressBegin(pair.upstream), pair.port.decompressBegin());
        const expected = try gpa.alloc(u8, input.len);
        defer gpa.free(expected);
        const actual = try gpa.alloc(u8, input.len);
        defer gpa.free(actual);
        var block: [140_000]u8 = undefined;
        var pos: usize = 0;
        while (pos < input.len) {
            const n = @min(block_size, input.len - pos);
            const size = c.ZSTD_compressBlock(cctx, &block, block.len, input[pos..].ptr, n);
            if (c.ZSTD_isError(size) != 0) return error.UpstreamFailed;
            if (size == 0) {
                // Not compressible: stored by the caller, and inserted.
                @memcpy(expected[pos..][0..n], input[pos..][0..n]);
                @memcpy(actual[pos..][0..n], input[pos..][0..n]);
                try testing.expectEqual(c.ZSTD_insertBlock(pair.upstream, expected[pos..].ptr, n), pair.port.insertBlock(actual[pos..][0..n]));
            } else {
                const code = c.ZSTD_decompressBlock(pair.upstream, expected[pos..].ptr, input.len - pos, &block, size);
                const result = pair.port.decompressBlock(actual[pos..], block[0..size]);
                try expectSameResult(code, result);
                try testing.expectEqual(n, code);
            }
            pos += n;
        }
        try testing.expectEqualSlices(u8, input, actual);
        try testing.expectEqualSlices(u8, expected, actual);
    }
}

test "parameters: bounds, every value at and past them, reset, and the stage" {
    const pair = try Pair.init();
    defer pair.deinit();
    inline for (@typeInfo(params.DParameter).@"enum".field_values) |value_number| {
        const param: params.DParameter = @fromBackingInt(@as(u32, value_number));
        const field = .{ .value = @as(c_uint, value_number) };
        const bounds = c.ZSTD_dParam_getBounds(field.value);
        const port_bounds = try zstd.dParamGetBounds(param);
        try testing.expectEqual(bounds.lower_bound, port_bounds.lower);
        try testing.expectEqual(bounds.upper_bound, port_bounds.upper);
        var value = bounds.lower_bound - 2;
        while (value <= bounds.upper_bound + 2) : (value += 1) {
            try pair.set(param, value);
            var expected: c_int = 0;
            const code = c.ZSTD_DCtx_getParameter(pair.upstream, field.value, &expected);
            const actual = try pair.port.getParameter(param);
            try testing.expect(c.ZSTD_isError(code) == 0);
            try testing.expectEqual(expected, actual);
        }
        for ([_]i32{ 0, std.math.minInt(i32), std.math.maxInt(i32) }) |v| try pair.set(param, v);
    }
    try expectSameResult(c.ZSTD_dParam_getBounds(999).@"error", @as(zstd.Error!void, error.ParameterUnsupported));
    // Unknown parameter numbers are refused by the original; the port's
    // parameters are an enum.
    var unused: c_int = 0;
    try testing.expect(c.ZSTD_isError(c.ZSTD_DCtx_getParameter(pair.upstream, 999, &unused)) != 0);

    // Mid-frame, parameters and dictionaries are refused until a reset.
    const input = try dc.mixedInput(300_000, 26);
    defer gpa.free(input);
    const frame = try dc.compress(&.{.{ .param = dc.c_level, .value = 3 }}, input);
    defer gpa.free(frame);
    var out: [1000]u8 = undefined;
    var u_out: [1000]u8 = undefined;
    var c_in: c.ZSTD_inBuffer = .{ .src = frame.ptr, .size = 2000, .pos = 0 };
    var c_out: c.ZSTD_outBuffer = .{ .dst = &u_out, .size = u_out.len, .pos = 0 };
    var p_in: params.InBuffer = .{ .src = frame[0..2000] };
    var p_out: params.OutBuffer = .{ .dst = &out };
    try expectSameResult(c.ZSTD_decompressStream(pair.upstream, &c_out, &c_in), pair.port.decompressStream(&p_out, &p_in));
    try pair.set(.window_log_max, 20);
    try expectSameResult(c.ZSTD_DCtx_loadDictionary(pair.upstream, input.ptr, 100), pair.port.loadDictionary(input[0..100]));
    try expectSameResult(c.ZSTD_DCtx_refDDict(pair.upstream, null), pair.port.refDDict(null));
    try expectSameResult(c.ZSTD_DCtx_setMaxWindowSize(pair.upstream, 1 << 20), pair.port.setMaxWindowSize(1 << 20));
    for ([_]u32{ 2, 3, 1, 2, 3 }) |directive| {
        try expectSameResult(c.ZSTD_DCtx_reset(pair.upstream, directive), pair.port.reset(@fromBackingInt(directive)));
    }
    for ([_]usize{ 0, 1023, 1024, 1 << 20, 1 << 31, (1 << 31) + 1 }) |size| {
        try expectSameResult(c.ZSTD_DCtx_setMaxWindowSize(pair.upstream, size), pair.port.setMaxWindowSize(size));
        var expected: c_int = 0;
        _ = c.ZSTD_DCtx_getParameter(pair.upstream, 100, &expected);
        try testing.expectEqual(expected, try pair.port.getParameter(.window_log_max));
    }
    try expectSameResult(c.ZSTD_resetDStream(pair.upstream), pair.port.resetDStream());
    try testing.expectEqual(c.ZSTD_DStreamInSize(), zstd.dStreamInSize());
    try testing.expectEqual(c.ZSTD_DStreamOutSize(), zstd.dStreamOutSize());
}

test "sizes: contexts, dictionaries and streams, and static objects" {
    try testing.expectEqual(c.ZSTD_estimateDCtxSize(), zstd.estimateDCtxSize());
    const pair = try Pair.init();
    defer pair.deinit();
    try testing.expectEqual(c.ZSTD_sizeof_DCtx(pair.upstream), zstd.sizeofDCtx(pair.port));
    try testing.expectEqual(c.ZSTD_sizeof_DCtx(null), zstd.sizeofDCtx(null));
    for ([_]usize{ 0, 1, 1000, 1 << 10, 1 << 17, (1 << 17) + 1, 1 << 20, 1 << 27 }) |window| {
        try testing.expectEqual(c.ZSTD_estimateDStreamSize(window), try zstd.estimateDStreamSize(window));
        for ([_]u64{ 0, 1, 1000, 1 << 20, params.content_size_unknown }) |content| {
            try testing.expectEqual(c.ZSTD_decodingBufferSize_min(window, content), try zstd.decodingBufferSizeMin(window, content));
        }
    }
    const corpus = try common.generated(1 << 20, 0.5, 0.1, 27);
    defer gpa.free(corpus);
    const dict = try dc.train(corpus, 16 << 10);
    defer gpa.free(dict);
    for ([_]u32{ 0, 1 }) |method| {
        const estimate = c.ZSTD_estimateDDictSize(dict.len, method);
        try testing.expectEqual(estimate, zstd.estimateDDictSize(dict.len, @fromBackingInt(method)));
        for ([_]usize{ estimate, estimate - 1 }) |size| {
            const u_buffer = try gpa.alignedAlloc(u8, .@"8", size);
            defer gpa.free(u_buffer);
            const p_buffer = try gpa.alignedAlloc(u8, .@"8", size);
            defer gpa.free(p_buffer);
            const u = c.ZSTD_initStaticDDict(u_buffer.ptr, u_buffer.len, dict.ptr, dict.len, method, 0);
            const p = zstd.initStaticDDict(p_buffer, dict, @fromBackingInt(method), .auto);
            try testing.expectEqual(u == null, p == null);
            if (u) |ud| {
                try testing.expectEqual(c.ZSTD_sizeof_DDict(ud), zstd.sizeofDDict(p.?));
                try expectSameResult(c.ZSTD_DCtx_refDDict(pair.upstream, ud), pair.port.refDDict(p.?));
                const frame = try dc.compressWithDict(corpus[0..100_000], dict, 3, true);
                defer gpa.free(frame);
                try testing.expectEqual(Result{ .size = 100_000 }, try pair.decompressDCtx(frame, 100_000));
                try expectSameResult(c.ZSTD_DCtx_refDDict(pair.upstream, null), pair.port.refDDict(null));
            }
        }
        // A dictionary loaded into the context counts in its size.
        try expectSameResult(
            c.ZSTD_DCtx_loadDictionary_advanced(pair.upstream, dict.ptr, dict.len, method, 0),
            pair.port.loadDictionaryAdvanced(dict, @fromBackingInt(method), .auto),
        );
        try testing.expectEqual(c.ZSTD_sizeof_DCtx(pair.upstream), zstd.sizeofDCtx(pair.port));
    }
    // Static contexts: too small, misaligned, and the right size.
    const size = c.ZSTD_estimateDCtxSize();
    const buffer = try gpa.alignedAlloc(u8, .@"8", size + 8);
    defer gpa.free(buffer);
    try testing.expect(zstd.initStaticDCtx(buffer[0 .. size - 1]) == null);
    try testing.expect(zstd.initStaticDCtx(buffer[1 .. size + 1]) == null);
    const static = zstd.initStaticDCtx(buffer[0..size]) orelse return error.StaticDCtx;
    try testing.expectError(error.MemoryAllocation, zstd.freeDCtx(static));
    try testing.expectError(error.ParameterUnsupported, static.setParameter(.ref_multiple_ddicts, 1));
    try testing.expectError(error.MemoryAllocation, static.loadDictionary(dict));
}

/// The Huffman sections of the compressed blocks of `frame`: their table
/// and streams, with their decoded size and stream count.
const HufSection = struct { src: []const u8, size: usize, four: bool };

fn hufSections(frame: []const u8, list: *std.ArrayList(HufSection)) !void {
    var zfh: zstd.FrameHeader = .{};
    _ = try zstd.getFrameHeader(&zfh, frame);
    var ip: usize = zfh.header_size;
    while (true) {
        const header = std.mem.readInt(u24, frame[ip..][0..3], .little);
        const block_type = (header >> 1) & 3;
        const c_size: usize = header >> 3;
        ip += 3;
        if (block_type == 2 and frame[ip] & 3 == 2) {
            const b = frame[ip..];
            const lhl = (b[0] >> 2) & 3;
            const lhc = std.mem.readInt(u32, b[0..4], .little);
            const lh: usize, const size: usize, const csize: usize = switch (lhl) {
                0, 1 => .{ 3, (lhc >> 4) & 0x3FF, (lhc >> 14) & 0x3FF },
                2 => .{ 4, (lhc >> 4) & 0x3FFF, lhc >> 18 },
                else => .{ 5, (lhc >> 4) & 0x3FFFF, (lhc >> 22) + (@as(usize, b[4]) << 10) },
            };
            try list.append(gpa, .{ .src = b[lh..][0..csize], .size = size, .four = lhl != 0 });
        }
        ip += if (block_type == 1) 1 else c_size;
        if (header & 1 != 0) break;
    }
}

/// Runs one Huffman decoder on both sides on `src` into `size` bytes, with
/// fresh tables and workspaces, and compares the results, the tables and
/// the output.
fn expectSameHuf(comptime which: enum { x1_1, x2_1, any_1, four, x1_then, x2_then }, src: []const u8, size: usize, fast: bool) !void {
    const table_u32 = 4097;
    var u_table: [table_u32]u32 = @splat(0);
    var p_table: [table_u32]u32 = @splat(0);
    u_table[0] = 12 * 0x1000001;
    p_table[0] = 12 * 0x1000001;
    var u_wksp: [640]u32 = undefined;
    var p_wksp: [640]u32 = undefined;
    const u_out = try gpa.alloc(u8, size + 64);
    defer gpa.free(u_out);
    const p_out = try gpa.alloc(u8, size + 64);
    defer gpa.free(p_out);
    @memset(u_out, 0);
    @memset(p_out, 0);
    const c_flags: c_int = 16 | (if (fast) @as(c_int, 0) else 32);
    const flags: zstd.internal.huf.Flags = .{ .disable_asm = true, .disable_fast = !fast };
    const hd = zstd.internal.huf_decompress;
    switch (which) {
        .x1_1 => try expectSameResult(
            c.HUF_decompress1X1_DCtx_wksp(&u_table, u_out.ptr, size, src.ptr, src.len, &u_wksp, @sizeOf(@TypeOf(u_wksp)), c_flags),
            hd.decompress1X1DCtxWksp(&p_table, p_out[0..size], src, &p_wksp, flags),
        ),
        .x2_1 => try expectSameResult(
            c.HUF_decompress1X2_DCtx_wksp(&u_table, u_out.ptr, size, src.ptr, src.len, &u_wksp, @sizeOf(@TypeOf(u_wksp)), c_flags),
            hd.decompress1X2DCtxWksp(&p_table, p_out[0..size], src, &p_wksp, flags),
        ),
        .any_1 => try expectSameResult(
            c.HUF_decompress1X_DCtx_wksp(&u_table, u_out.ptr, size, src.ptr, src.len, &u_wksp, @sizeOf(@TypeOf(u_wksp)), c_flags),
            hd.decompress1XDCtxWksp(&p_table, p_out[0..size], src, &p_wksp, flags),
        ),
        .four => try expectSameResult(
            c.HUF_decompress4X_hufOnly_wksp(&u_table, u_out.ptr, size, src.ptr, src.len, &u_wksp, @sizeOf(@TypeOf(u_wksp)), c_flags),
            hd.decompress4XHufOnlyWksp(&p_table, p_out[0..size], src, &p_wksp, flags),
        ),
        .x1_then, .x2_then => {
            // Read the table with one reader, then decode one or four
            // streams with it.
            const code = if (which == .x1_then)
                c.HUF_readDTableX1_wksp(&u_table, src.ptr, src.len, &u_wksp, @sizeOf(@TypeOf(u_wksp)), 0)
            else
                c.HUF_readDTableX2_wksp(&u_table, src.ptr, src.len, &u_wksp, @sizeOf(@TypeOf(u_wksp)), 0);
            const result = if (which == .x1_then)
                hd.readDTableX1Wksp(&p_table, src, &p_wksp)
            else
                hd.readDTableX2Wksp(&p_table, src, &p_wksp);
            try expectSameResult(code, result);
            try testing.expectEqualSlices(u32, &u_table, &p_table);
            if (c.ZSTD_isError(code) != 0 or code >= src.len) return;
            const rest = src[code..];
            try expectSameResult(
                c.HUF_decompress1X_usingDTable(u_out.ptr, size, rest.ptr, rest.len, &u_table, c_flags),
                hd.decompress1XUsingDTable(p_out[0..size], rest, &p_table, flags),
            );
            try expectSameResult(
                c.HUF_decompress4X_usingDTable(u_out.ptr, size, rest.ptr, rest.len, &u_table, c_flags),
                hd.decompress4XUsingDTable(p_out[0..size], rest, &p_table, flags),
            );
        },
    }
    try testing.expectEqualSlices(u32, &u_table, &p_table);
    try testing.expectEqualSlices(u8, u_out, p_out);
}

test "Huffman decoders: tables and streams of real blocks, intact and corrupted" {
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(28));
    const random = prng.random();
    var sections: std.ArrayList(HufSection) = .empty;
    defer sections.deinit(gpa);
    var frames: std.ArrayList([]u8) = .empty;
    defer {
        for (frames.items) |f| gpa.free(f);
        frames.deinit(gpa);
    }
    const text = try common.generated(1 << 20, 0.3, 0.3, 28);
    defer gpa.free(text);
    const bc7 = try common.readFile(@import("test_options").data, "bc7.bin");
    defer gpa.free(bc7);
    for ([_][]const u8{ text, bc7, text[0..300], text[0..5000] }) |input| {
        for ([_]i32{ 1, 19 }) |level| {
            const frame = try dc.compress(&.{.{ .param = dc.c_level, .value = level }}, input);
            try frames.append(gpa, frame);
            try hufSections(frame, &sections);
        }
    }
    var x2_tables: usize = 0;
    for (sections.items) |s| {
        for ([_]bool{ true, false }) |fast| {
            if (s.four) {
                try expectSameHuf(.four, s.src, s.size, fast);
                if (c.HUF_selectDecoder(s.size, s.src.len) != 0) x2_tables += 1;
            } else {
                try expectSameHuf(.x1_1, s.src, s.size, fast);
                try expectSameHuf(.x2_1, s.src, s.size, fast);
                try expectSameHuf(.any_1, s.src, s.size, fast);
            }
            try expectSameHuf(.x1_then, s.src, s.size, fast);
            try expectSameHuf(.x2_then, s.src, s.size, fast);
        }
    }
    try testing.expect(x2_tables > 0);
    // Corrupted: flipped bits, truncated, wrong sizes.
    for (0..common.fuzz_cases) |_| {
        const s = sections.items[random.uintLessThan(usize, sections.items.len)];
        const bad = try gpa.dupe(u8, s.src);
        defer gpa.free(bad);
        for (0..random.intRangeAtMost(usize, 1, 3)) |_| {
            bad[random.uintLessThan(usize, bad.len)] ^= @as(u8, 1) << random.int(u3);
        }
        const len = if (random.boolean()) bad.len else random.uintAtMost(usize, bad.len);
        const size = if (random.uintLessThan(u32, 4) == 0) random.uintAtMost(usize, s.size + 10) else s.size;
        const fast = random.boolean();
        if (s.four) try expectSameHuf(.four, bad[0..len], size, fast) else try expectSameHuf(.any_1, bad[0..len], size, fast);
        try expectSameHuf(.x1_then, bad[0..len], size, fast);
        try expectSameHuf(.x2_then, bad[0..len], size, fast);
    }
    // The cost model.
    for (0..2000) |_| {
        const dst = random.intRangeAtMost(usize, 1, 128 << 10);
        const src = random.uintAtMost(usize, dst + 100);
        try testing.expectEqual(c.HUF_selectDecoder(dst, src), zstd.internal.huf_decompress.selectDecoder(dst, src));
    }
}

/// Sets a random parameter set on `cctx`'s list for the original.
fn randomCompressionParams(random: std.Random, list: *std.ArrayList(common.Param)) !void {
    try list.append(gpa, .{ .param = dc.c_level, .value = random.intRangeAtMost(i32, -7, 22) });
    if (random.boolean()) try list.append(gpa, .{ .param = dc.c_checksum_flag, .value = 1 });
    if (random.uintLessThan(u32, 3) == 0) try list.append(gpa, .{ .param = dc.c_content_size_flag, .value = 0 });
    if (random.uintLessThan(u32, 3) == 0) try list.append(gpa, .{ .param = dc.c_window_log, .value = random.intRangeAtMost(i32, 10, 23) });
    if (random.uintLessThan(u32, 6) == 0) try list.append(gpa, .{ .param = dc.c_literal_compression_mode, .value = random.intRangeAtMost(i32, 0, 2) });
    if (random.uintLessThan(u32, 6) == 0) try list.append(gpa, .{ .param = dc.c_target_cblock_size, .value = random.intRangeAtMost(i32, 1340, 20_000) });
    if (random.uintLessThan(u32, 6) == 0) try list.append(gpa, .{ .param = dc.c_max_block_size, .value = random.intRangeAtMost(i32, 1024, 1 << 17) });
    if (random.uintLessThan(u32, 8) == 0) try list.append(gpa, .{ .param = dc.c_ldm, .value = 1 });
    if (random.uintLessThan(u32, 8) == 0) try list.append(gpa, .{ .param = dc.c_dict_id_flag, .value = 0 });
}

fn randomInput(random: std.Random) ![]u8 {
    const size = switch (random.uintLessThan(u32, 16)) {
        0 => random.uintAtMost(usize, 2 << 20),
        1, 2, 3 => random.uintAtMost(usize, 100),
        else => random.uintAtMost(usize, 300_000),
    };
    if (random.boolean()) return dc.mixedInput(size, random.int(u32));
    return common.generated(size, random.float(f64), random.float(f64), random.int(u32));
}

test "fuzz: frames of random parameters, decoded one shot, streamed, buffer-less and exact" {
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(29));
    const random = prng.random();
    var stats: Stats = .{};
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("case {d}\n", .{case});
        const input = try randomInput(random);
        defer gpa.free(input);
        var list: std.ArrayList(common.Param) = .empty;
        defer list.deinit(gpa);
        try randomCompressionParams(random, &list);
        const frame = dc.compress(list.items, input) catch continue;
        defer gpa.free(frame);
        try stats.add(frame);
        const pair = try Pair.init();
        defer pair.deinit();
        if (random.uintLessThan(u32, 4) == 0) try pair.set(.max_block_size, random.intRangeAtMost(i32, 1000, 1 << 17));
        if (random.uintLessThan(u32, 4) == 0) try pair.set(.window_log_max, random.intRangeAtMost(i32, 10, 23));
        if (random.uintLessThan(u32, 4) == 0) try pair.set(.disable_huffman_assembly, 1);
        const capacity = switch (random.uintLessThan(u32, 4)) {
            0 => input.len + random.uintAtMost(usize, 300_000),
            1 => random.uintAtMost(usize, input.len),
            else => input.len,
        };
        _ = try pair.decompressDCtx(frame, capacity);
        try expectSameStreamRandom(pair, frame, @max(capacity, 1), random, random.uintLessThan(u32, 4) == 0);
        if (input.len > 0) {
            var dctx: zstd.DCtx = undefined;
            dctx.init();
            const out = try gpa.alloc(u8, input.len);
            defer gpa.free(out);
            try dctx.decompressFrameExact(out, frame, .{});
            try testing.expectEqualSlices(u8, input, out);
        }
    }
    std.debug.print("fuzzed frames: blocks {any}, literals {any}, sequence modes {any}\n", .{ stats.blocks, stats.literals, stats.seq_modes });
}

/// Applies 1 to 4 random changes to `frame`: flipped bits, bytes set,
/// bytes removed or inserted, a cut; the caller frees the result.
fn corrupt(random: std.Random, frame: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, frame);
    for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
        if (bytes.items.len == 0) break;
        // Mostly near the start, where the headers and tables are.
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

test "fuzz: corrupted and truncated frames, one shot and streamed" {
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(30));
    const random = prng.random();
    var pool: std.ArrayList(struct { frame: []u8, size: usize }) = .empty;
    defer {
        for (pool.items) |p| gpa.free(p.frame);
        pool.deinit(gpa);
    }
    for (0..40) |_| {
        const input = try randomInput(random);
        defer gpa.free(input);
        var list: std.ArrayList(common.Param) = .empty;
        defer list.deinit(gpa);
        try randomCompressionParams(random, &list);
        const frame = dc.compress(list.items, input) catch continue;
        try pool.append(gpa, .{ .frame = frame, .size = input.len });
    }
    var refused: usize = 0;
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("case {d}\n", .{case});
        const p = pool.items[random.uintLessThan(usize, pool.items.len)];
        const bad = try corrupt(random, p.frame);
        defer gpa.free(bad);
        const pair = try Pair.initNoAsm();
        defer pair.deinit();
        const capacity = if (random.boolean()) p.size else p.size + random.uintAtMost(usize, 300_000);
        const result = try pair.decompressDCtx(bad, capacity);
        if (result == .error_code) refused += 1;
        if (random.uintLessThan(u32, 4) == 0) try pair.set(.force_ignore_checksum, 1);
        try expectSameStreamRandom(pair, bad, @max(capacity, 1), random, false);
    }
    std.debug.print("corrupted frames refused: {d} of {d}\n", .{ refused, common.fuzz_cases });
    // Every cut of a few frames.
    for (pool.items[0..6]) |p| {
        const pair = try Pair.initNoAsm();
        defer pair.deinit();
        var cut: usize = 0;
        while (cut < p.frame.len) : (cut += 1 + cut / 64) _ = try pair.decompressDCtx(p.frame[0..cut], p.size);
    }
}

test "fuzz: random bytes behind a valid frame header and block header" {
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(31));
    const random = prng.random();
    var buffer: [4096]u8 = undefined;
    for (0..common.fuzz_cases) |_| {
        random.bytes(&buffer);
        std.mem.writeInt(u32, buffer[0..4], params.magic_number, .little);
        // Single segment with a 2-byte content size, no checksum.
        buffer[4] = 0x60;
        const content = random.uintAtMost(u16, 60_000);
        std.mem.writeInt(u16, buffer[5..7], content, .little);
        // A last compressed block of the rest.
        const len = random.intRangeAtMost(usize, 10, buffer.len);
        std.mem.writeInt(u24, buffer[7..10], @intCast(((len - 10) << 3) | (2 << 1) | 1), .little);
        const pair = try Pair.initNoAsm();
        defer pair.deinit();
        _ = try pair.decompressDCtx(buffer[0..len], @as(usize, content) + 256);
    }
}
