//! Oracle tests of the decompressor, one or more per feature: frames and
//! skippable frames, the frame header, the three block types, every kind
//! of literals section and sequence table, repeat offsets, long offsets,
//! checksums and dictionaries. Each test decodes the same frames with the
//! original and the port and compares every result code and every output
//! byte, and counts from the frames' headers that the feature it names is
//! there. The frames are the original's own (its compressor's output and
//! its golden files) and the port compressor's.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const dc = @import("decompress_common.zig");
const test_options = @import("test_options");

const gpa = dc.gpa;
const Pair = dc.Pair;
const Stats = dc.Stats;
const Result = dc.Result;
const expectSameResult = dc.expectSameResult;
const testing = std.testing;
const params = zstd.params;

/// The levels the tests compress at: one of each strategy and the
/// negative levels' fast variant.
const levels = [_]i32{ -5, 1, 3, 5, 6, 8, 13, 16, 19, 22 };

/// The port compressor's frame of `src` at `level`, which the original's
/// would be byte for byte. The caller frees it.
fn portCompress(src: []const u8, level: i32, checksum: bool) ![]u8 {
    const cctx = try zstd.CCtx.create(gpa);
    defer cctx.destroy() catch unreachable;
    _ = try cctx.setParameter(.compression_level, level);
    _ = try cctx.setParameter(.checksum_flag, @intFromBool(checksum));
    const dst = try gpa.alloc(u8, try zstd.compressBound(src.len));
    errdefer gpa.free(dst);
    const size = try cctx.compress2(dst, src);
    return gpa.realloc(dst, size);
}

/// Frames of `src` at every test level by both compressors, decoded both
/// ways and counted into `stats`.
fn expectLevels(stats: *Stats, src: []const u8) !void {
    for (levels) |level| {
        errdefer std.debug.print("level {d}, {d} bytes\n", .{ level, src.len });
        const reference = try dc.compress(&.{
            .{ .param = dc.c_level, .value = level },
            .{ .param = dc.c_checksum_flag, .value = @intFromBool(level & 1 == 0) },
        }, src);
        defer gpa.free(reference);
        try stats.add(reference);
        try dc.expectDecodes(reference, src);
        const port = try portCompress(src, level, level & 1 == 0);
        defer gpa.free(port);
        try common.expectSameFrame(reference, port);
    }
}

test "frames: one, several, empty, and skippable frames between them" {
    const input = try dc.mixedInput(300_000, 1);
    defer gpa.free(input);
    var stats: Stats = .{};

    // One frame, and several back to back with skippable frames between.
    const a = try portCompress(input[0..100_000], 3, true);
    defer gpa.free(a);
    const b = try portCompress(input[100_000..], 19, false);
    defer gpa.free(b);
    const empty = try portCompress(&.{}, 1, false);
    defer gpa.free(empty);
    var skippable: [3][40]u8 = undefined;
    var skippable_sizes: [3]usize = undefined;
    for (&skippable, &skippable_sizes, [_]u32{ 0, 7, 15 }, [_]usize{ 0, 1, 31 }) |*s, *size, variant, len| {
        const content: [31]u8 = @splat(@intCast(variant));
        size.* = try zstd.writeSkippableFrame(s, content[0..len], variant);
    }
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    try joined.appendSlice(gpa, skippable[0][0..skippable_sizes[0]]);
    try joined.appendSlice(gpa, a);
    try joined.appendSlice(gpa, skippable[1][0..skippable_sizes[1]]);
    try joined.appendSlice(gpa, empty);
    try joined.appendSlice(gpa, b);
    try joined.appendSlice(gpa, skippable[2][0..skippable_sizes[2]]);
    try stats.add(joined.items);
    try testing.expect(stats.frames == 3 and stats.skippable_frames == 3);
    try dc.expectDecodes(joined.items, input);
    try dc.expectDecodes(a, input[0..100_000]);
    try dc.expectDecodes(empty, &.{});

    // Only skippable frames, and every cut of the joined input.
    try dc.expectDecodes(skippable[2][0..skippable_sizes[2]], &.{});
    const pair = try Pair.init();
    defer pair.deinit();
    var cut: usize = 0;
    while (cut <= joined.items.len) : (cut += 997) {
        _ = try pair.decompressDCtx(joined.items[0..cut], input.len);
    }
    // Garbage after a frame, and a frame too large for the output.
    try joined.appendSlice(gpa, "garbage!");
    _ = try pair.decompressDCtx(joined.items, input.len + 100);
    _ = try pair.decompressDCtx(a, 99_999);
}

test "frames: the magicless format" {
    const input = try dc.mixedInput(200_000, 2);
    defer gpa.free(input);
    for ([_]i32{ 1, 19 }) |level| {
        const frame = try dc.compress(&.{
            .{ .param = dc.c_level, .value = level },
            .{ .param = dc.c_format, .value = 1 },
            .{ .param = dc.c_checksum_flag, .value = 1 },
        }, input);
        defer gpa.free(frame);
        const pair = try Pair.init();
        defer pair.deinit();
        // Refused as a frame with a magic number, decoded without one.
        _ = try pair.decompressDCtx(frame, input.len);
        try pair.set(.format, 1);
        const result = try pair.decompressDCtx(frame, input.len);
        try testing.expectEqual(Result{ .size = input.len }, result);
        try pair.set(.format, 0);
        try expectSameResult(c.ZSTD_DCtx_setFormat(pair.upstream, 1), pair.port.setFormat(.zstd1_magicless));
        _ = try pair.decompressDCtx(frame, input.len);
    }
}

/// Compares `getFrameHeaderAdvanced` and the other readers on `src`.
fn expectSameHeader(src: []const u8, format: params.Format) !void {
    var expected: c.ZSTD_FrameHeader = std.mem.zeroes(c.ZSTD_FrameHeader);
    var actual: zstd.FrameHeader = .{};
    const code = c.ZSTD_getFrameHeader_advanced(&expected, src.ptr, src.len, @backingInt(format));
    const result = zstd.getFrameHeaderAdvanced(&actual, src, format);
    try expectSameResult(code, result);
    if (c.ZSTD_isError(code) == 0 and code == 0) {
        try testing.expectEqual(expected.frame_content_size, actual.frame_content_size);
        try testing.expectEqual(expected.window_size, actual.window_size);
        try testing.expectEqual(expected.block_size_max, actual.block_size_max);
        try testing.expectEqual(expected.frame_type, @backingInt(actual.frame_type));
        try testing.expectEqual(expected.header_size, actual.header_size);
        try testing.expectEqual(expected.dict_id, actual.dict_id);
        try testing.expectEqual(expected.checksum_flag, @intFromBool(actual.checksum_flag));
    }
    if (format != .zstd1) return;
    try expectSameResult(c.ZSTD_frameHeaderSize(src.ptr, src.len), zstd.frameHeaderSize(src));
    try testing.expectEqual(c.ZSTD_getFrameContentSize(src.ptr, src.len), zstd.getFrameContentSize(src));
    try testing.expectEqual(c.ZSTD_getDecompressedSize(src.ptr, src.len), zstd.getDecompressedSize(src));
    try testing.expectEqual(c.ZSTD_getDictID_fromFrame(src.ptr, src.len), zstd.getDictIdFromFrame(src));
    try testing.expectEqual(c.ZSTD_isFrame(src.ptr, src.len) != 0, zstd.isFrame(src));
    try testing.expectEqual(c.ZSTD_isSkippableFrame(src.ptr, src.len) != 0, zstd.isSkippableFrame(src));
    try expectSameResult(c.ZSTD_findFrameCompressedSize(src.ptr, src.len), zstd.findFrameCompressedSize(src));
    try testing.expectEqual(c.ZSTD_findDecompressedSize(src.ptr, src.len), zstd.findDecompressedSize(src));
    try testing.expectEqual(c.ZSTD_decompressBound(src.ptr, src.len), zstd.decompressBound(src));
    try expectSameResult(c.ZSTD_decompressionMargin(src.ptr, src.len), zstd.decompressionMargin(src));
    try expectSameResult(
        c.ZSTD_estimateDStreamSize_fromFrame(src.ptr, src.len),
        zstd.estimateDStreamSizeFromFrame(src),
    );
}

test "frame header: every descriptor, dictionary id and content size field" {
    // Every frame header descriptor byte, with every window byte and
    // field values at their edges, read whole and at every shorter length,
    // in both formats.
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(11));
    const random = prng.random();
    var buffer: [32]u8 = undefined;
    for (0..256) |fhd| {
        for ([_]u8{ 0, 7, 0x38, 0x79, 0xA8, 0xA9, 0xAF, 0xB0, 0xFF }) |wl| {
            for (0..3) |variant| {
                std.mem.writeInt(u32, buffer[0..4], params.magic_number, .little);
                buffer[4] = @intCast(fhd);
                buffer[5] = wl;
                for (buffer[6..]) |*byte| byte.* = switch (variant) {
                    0 => 0,
                    1 => 0xFF,
                    else => random.int(u8),
                };
                // A last block, empty and raw, after the header.
                for (0..buffer.len + 1) |len| try expectSameHeader(buffer[0..len], .zstd1);
                for (0..buffer.len - 3) |len| try expectSameHeader(buffer[4..][0..len], .zstd1_magicless);
            }
        }
    }
    // Every magic number of a skippable frame, and its truncations.
    var skippable: [64]u8 = @splat(0);
    for (0..16) |variant| {
        std.mem.writeInt(u32, skippable[0..4], params.magic_skippable_start + @as(u32, @intCast(variant)), .little);
        std.mem.writeInt(u32, skippable[4..8], @intCast(variant * 3), .little);
        for (0..12) |len| try expectSameHeader(skippable[0..len], .zstd1);
        var content: [64]u8 = undefined;
        var magic: c_uint = 99;
        var port_magic: u32 = 99;
        const code = c.ZSTD_readSkippableFrame(&content, content.len, &magic, &skippable, 8 + variant * 3);
        var port_content: [64]u8 = undefined;
        const result = zstd.readSkippableFrame(&port_content, &port_magic, skippable[0 .. 8 + variant * 3]);
        try expectSameResult(code, result);
        try testing.expectEqual(magic, port_magic);
        try testing.expectEqualSlices(u8, content[0..code], port_content[0..code]);
    }
    // Random bytes behind each magic number.
    for (0..common.fuzz_cases) |_| {
        random.bytes(&buffer);
        const magic: u32 = switch (random.uintLessThan(u32, 3)) {
            0 => params.magic_number,
            1 => params.magic_skippable_start + random.uintLessThan(u32, 16),
            else => random.int(u32),
        };
        std.mem.writeInt(u32, buffer[0..4], magic, .little);
        try expectSameHeader(buffer[0..random.uintAtMost(usize, buffer.len)], .zstd1);
    }
}

test "frame header: content sizes of 1, 2, 4 and 8 bytes, single segment, dictionary ids of 1, 2 and 4 bytes" {
    const input = try dc.mixedInput(300_000, 3);
    defer gpa.free(input);
    var stats: Stats = .{};
    // The compressor picks the smallest content size field.
    for ([_]usize{ 0, 1, 255, 256, 65791, 65792, 300_000 }) |size| {
        for ([_]i32{ 0, 1 }) |single| {
            const frame = try dc.compress(&.{
                .{ .param = dc.c_level, .value = 3 },
                .{ .param = dc.c_content_size_flag, .value = single },
            }, input[0..size]);
            defer gpa.free(frame);
            try stats.add(frame);
            try expectSameHeader(frame, .zstd1);
            try dc.expectDecodes(frame, input[0..size]);
        }
    }
    try testing.expect(stats.single_segment > 0);

    // An 8-byte content size: a header made by hand over one raw block.
    {
        var frame: [32]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], params.magic_number, .little);
        frame[4] = 0xC0; // 8-byte content size, a window byte
        frame[5] = 0;
        std.mem.writeInt(u64, frame[6..14], 3, .little);
        std.mem.writeInt(u24, frame[14..17], (3 << 3) | 1, .little);
        @memcpy(frame[17..20], "abc");
        try expectSameHeader(frame[0..20], .zstd1);
        try dc.expectDecodes(frame[0..20], "abc");
        std.mem.writeInt(u64, frame[6..14], 1 << 40, .little);
        try expectSameHeader(frame[0..20], .zstd1);
        const pair = try Pair.init();
        defer pair.deinit();
        _ = try pair.decompressDCtx(frame[0..20], 100);
    }

    // Dictionary ids of each size, set in a trained dictionary.
    const trained = try dc.train(input, 16 << 10);
    defer gpa.free(trained);
    for ([_]u32{ 200, 60_000, 0x12345678 }) |id| {
        const dict = try gpa.dupe(u8, trained);
        defer gpa.free(dict);
        std.mem.writeInt(u32, dict[4..8], id, .little);
        const frame = try dc.compressWithDict(input[0..50_000], dict, 5, true);
        defer gpa.free(frame);
        try stats.add(frame);
        try expectSameHeader(frame, .zstd1);
        try testing.expectEqual(id, zstd.getDictIdFromFrame(frame));
        const pair = try Pair.init();
        defer pair.deinit();
        const result = try pair.decompressUsingDict(frame, 50_000, dict);
        try testing.expectEqual(Result{ .size = 50_000 }, result);
        // The wrong dictionary and none are refused.
        _ = try pair.decompressUsingDict(frame, 50_000, trained);
        _ = try pair.decompressDCtx(frame, 50_000);
    }
    try testing.expect(stats.dict_ids == 3);
}

test "frame header: windows with a mantissa, and the largest window a stream accepts" {
    const input = try dc.mixedInput(1 << 20, 4);
    defer gpa.free(input);
    const frame = try dc.compress(&.{
        .{ .param = dc.c_level, .value = 3 },
        .{ .param = dc.c_window_log, .value = 17 },
        .{ .param = dc.c_content_size_flag, .value = 0 },
    }, input);
    defer gpa.free(frame);
    try testing.expect(frame[4] & 0x20 == 0);
    // A larger window, with every mantissa, decodes the same frame.
    for (0..8) |mantissa| {
        for ([_]u8{ 17, 20, 27, 28, 31 }) |window_log| {
            const patched = try gpa.dupe(u8, frame);
            defer gpa.free(patched);
            patched[5] = @intCast(((window_log - 10) << 3) | mantissa);
            try expectSameHeader(patched, .zstd1);
            const pair = try Pair.init();
            defer pair.deinit();
            _ = try pair.decompressDCtx(patched, input.len);
            for ([_]i32{ 0, 10, 17, 18, 27, 31 }) |log_max| {
                try pair.set(.window_log_max, log_max);
                try expectSameStream(pair, patched, input.len, 65536, 65536);
            }
        }
    }
}

/// Decodes `src` with `decompressStream` on both, in pieces of up to
/// `in_step` bytes into windows of up to `out_step`, until the frame ends,
/// a call fails or no call moves; every call's result and positions must
/// be the same, and so must the output.
pub fn expectSameStream(pair: Pair, src: []const u8, capacity: usize, in_step: usize, out_step: usize) !void {
    try expectSameResult(c.ZSTD_DCtx_reset(pair.upstream, 1), pair.port.reset(.session_only));
    const expected = try gpa.alloc(u8, capacity);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, capacity);
    defer gpa.free(actual);
    var in_pos: usize = 0;
    var out_pos: usize = 0;
    var calls: usize = 0;
    while (calls < 100_000) : (calls += 1) {
        const in_end = @min(src.len, in_pos + in_step);
        const out_end = @min(capacity, out_pos + out_step);
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
        if (!moved and in_pos == src.len) return;
        if (!moved and out_pos == capacity) return;
    }
    return error.TooManyCalls;
}

test "blocks: raw, RLE and compressed, and the largest block" {
    var stats: Stats = .{};
    const input = try dc.mixedInput(2 << 20, 5);
    defer gpa.free(input);
    try expectLevels(&stats, input);
    // A block of exactly the largest size, compressed or not.
    for ([_]usize{ (128 << 10) - 1, 128 << 10, (128 << 10) + 1 }) |size| {
        try expectLevels(&stats, input[0..size]);
    }
    std.debug.print("blocks: {any}\n", .{stats.blocks});
    for (stats.blocks) |count| try testing.expect(count > 0);
}

/// Matches from random places of a random start, a 'z' before each, so
/// that every literal after the start is a 'z': RLE literals, and literal
/// and match lengths of one code each.
fn rleLiteralsInput() ![]u8 {
    const out = try gpa.alloc(u8, 700_000);
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    random.bytes(out[0 .. 64 << 10]);
    var pos: usize = 64 << 10;
    while (pos < out.len) {
        out[pos] = 'z';
        const n = @min(40, out.len - pos - 1);
        const from = random.uintLessThan(usize, (64 << 10) - 64);
        @memcpy(out[pos + 1 ..][0..n], out[from..][0..n]);
        pos += 1 + n;
    }
    return out;
}

test "literals: raw, RLE, Huffman with 1 or 4 streams, new or repeated tables" {
    var stats: Stats = .{};
    // Short blocks of text: one stream.
    const text = try common.readFile(test_options.reference, "lib/zstd.h");
    defer gpa.free(text);
    for ([_]usize{ 20, 100, 200, 255, 256, 400, 1000, 2000 }) |size| {
        for (0..4) |i| try expectLevels(&stats, text[i * 7919 ..][0..size]);
    }
    try expectLevels(&stats, text);
    const rle = try rleLiteralsInput();
    defer gpa.free(rle);
    try expectLevels(&stats, rle);
    // Raw literals, by the compression parameter.
    const raw = try dc.compress(&.{
        .{ .param = dc.c_level, .value = 3 },
        .{ .param = dc.c_literal_compression_mode, .value = 2 },
    }, text);
    defer gpa.free(raw);
    try stats.add(raw);
    try dc.expectDecodes(raw, text);
    // Literal-heavy data from test/data, with sections over 64 KiB.
    const bc7 = try common.readFile(test_options.data, "bc7.bin");
    defer gpa.free(bc7);
    try expectLevels(&stats, bc7);

    std.debug.print("literals {any}, 1 stream {d}, 4 streams {d}, X1 {d}, X2 {d}, over 64 KiB {d}\n", .{
        stats.literals,         stats.huffman_1_stream, stats.huffman_4_streams,
        stats.huffman_x1,       stats.huffman_x2,       stats.literals_over_64k,
    });
    for (stats.literals) |count| try testing.expect(count > 0);
    try testing.expect(stats.huffman_1_stream > 0 and stats.huffman_4_streams > 0);
    try testing.expect(stats.huffman_x1 > 0 and stats.huffman_x2 > 0);
    try testing.expect(stats.literals_over_64k > 0);
}

test "sequences: predefined, RLE, FSE and repeated tables for each field" {
    var stats: Stats = .{};
    const text = try common.generated(1 << 20, 0.7, 0.1, 8);
    defer gpa.free(text);
    for ([_]usize{ 100, 3000, 1 << 20 }) |size| try expectLevels(&stats, text[0..size]);
    const rle = try rleLiteralsInput();
    defer gpa.free(rle);
    try expectLevels(&stats, rle);
    // A period of 100 bytes with every 37th byte changed: one literal,
    // then a match at the last offset, so one code for every field.
    const periodic = try gpa.alloc(u8, 500_000);
    defer gpa.free(periodic);
    {
        var prng = std.Random.DefaultPrng.init(81);
        prng.random().bytes(periodic[0..100]);
        for (periodic[100..], 100..) |*b, i| b.* = if (i % 37 == 0) prng.random().int(u8) else periodic[i - 100];
    }
    try expectLevels(&stats, periodic);
    // Bytes of 6 bits with no repeats a match finder takes: blocks of
    // literals only.
    const noise = try gpa.alloc(u8, 400_000);
    defer gpa.free(noise);
    var prng = std.Random.DefaultPrng.init(8);
    for (noise) |*b| b.* = prng.random().int(u6);
    for ([_]i32{ 1, 3 }) |level| {
        const frame = try dc.compress(&.{.{ .param = dc.c_level, .value = level }}, noise);
        defer gpa.free(frame);
        try stats.add(frame);
        try dc.expectDecodes(frame, noise);
    }
    std.debug.print("sequence modes (ll, of, ml): {any}, blocks with none {d}\n", .{ stats.seq_modes, stats.no_sequences });
    for (stats.seq_modes) |field| {
        for (field) |count| try testing.expect(count > 0);
    }
    try testing.expect(stats.no_sequences > 0);
}

test "sequences: repeat offsets, with and without literals" {
    // Sequences given to the compressor, so that every repeat code is in
    // the frames: offsets equal to each of the three last ones, after
    // literals and after none, and the first repeat minus one.
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(9));
    const random = prng.random();
    for (0..50) |case| {
        const src = try gpa.alloc(u8, 200_000);
        defer gpa.free(src);
        random.bytes(src[0..5000]);
        var seqs: std.ArrayList(params.Sequence) = .empty;
        defer seqs.deinit(gpa);
        var reps = [3]u32{ 1, 4, 8 };
        var pos: usize = 5000;
        var block_start: usize = 0;
        // The first sequence's literals start at 0.
        var lead: u32 = 5000;
        while (pos < src.len - 1000) {
            const lit: u32 = if (random.boolean()) 0 else random.uintAtMost(u32, 20);
            const ml: u32 = random.intRangeAtMost(u32, 6, 200);
            const pick = random.uintLessThan(u32, 5);
            var offset: u32 = switch (pick) {
                0, 1, 2 => reps[pick],
                3 => reps[0] -| 1,
                else => random.intRangeAtMost(u32, 1, 4000),
            };
            if (offset == 0 or offset > pos) offset = 1;
            random.bytes(src[pos..][0..lit]);
            for (0..ml) |i| src[pos + lit + i] = src[pos + lit + i - offset];
            try seqs.append(gpa, .{ .offset = offset, .lit_length = lead + lit, .match_length = ml, .rep = 0 });
            lead = 0;
            if (offset != reps[0]) {
                reps[2] = reps[1];
                reps[1] = reps[0];
                reps[0] = offset;
            }
            pos += lit + ml;
            // Blocks of about 20 KB, each ended by a delimiter.
            if (pos - block_start > 20_000) {
                try seqs.append(gpa, .{ .offset = 0, .lit_length = 0, .match_length = 0, .rep = 0 });
                block_start = pos;
            }
        }
        // The last literals, in a last delimiter.
        try seqs.append(gpa, .{ .offset = 0, .lit_length = @intCast(src.len - pos), .match_length = 0, .rep = 0 });
        random.bytes(src[pos..]);
        const cctx = try zstd.CCtx.create(gpa);
        defer cctx.destroy() catch unreachable;
        _ = try cctx.setParameter(.compression_level, @intCast(case % 19 + 1));
        _ = try cctx.setParameter(.checksum_flag, 1);
        _ = try cctx.setParameter(.block_delimiters, 1);
        const dst = try gpa.alloc(u8, try zstd.compressBound(src.len));
        defer gpa.free(dst);
        const size = cctx.compressSequences(dst, seqs.items, src) catch |err| {
            std.debug.print("compressSequences: {t}, {d} sequences\n", .{ err, seqs.items.len });
            return err;
        };
        try dc.expectDecodes(dst[0..size], src);
    }
}

test "sequences: long offsets past 16 MiB, and the prefetching decoder" {
    // 24 MiB with far repeats: offsets beyond 2^23 make the original pick
    // its prefetching decoder by the offset table.
    const size = 24 << 20;
    const src = try gpa.alloc(u8, size);
    defer gpa.free(src);
    const chunk = try common.generated(6 << 20, 0.3, 0.3, 10);
    defer gpa.free(chunk);
    for (0..4) |i| {
        @memcpy(src[i * chunk.len ..][0..chunk.len], chunk);
        src[i * chunk.len + i * 1000] +%= 1;
    }
    for ([_]i32{ 1, 19 }) |level| {
        const frame = try dc.compress(&.{
            .{ .param = dc.c_level, .value = level },
            .{ .param = dc.c_window_log, .value = 25 },
            .{ .param = dc.c_ldm, .value = 1 },
            .{ .param = dc.c_checksum_flag, .value = 1 },
        }, src);
        defer gpa.free(frame);
        try dc.expectDecodes(frame, src);
        const pair = try Pair.init();
        defer pair.deinit();
        try pair.set(.window_log_max, 25);
        try expectSameStream(pair, frame, src.len, 1 << 20, 1 << 20);
    }
}

test "checksum: verified, wrong, missing, and ignored" {
    const input = try dc.mixedInput(500_000, 12);
    defer gpa.free(input);
    const frame = try portCompress(input, 3, true);
    defer gpa.free(frame);
    try dc.expectDecodes(frame, input);
    const pair = try Pair.init();
    defer pair.deinit();
    for (0..4) |byte| {
        for ([_]u8{ 1, 0x80 }) |flip| {
            const bad = try gpa.dupe(u8, frame);
            defer gpa.free(bad);
            bad[bad.len - 4 + byte] ^= flip;
            // A failed stream stays mid-frame, where parameters are refused.
            try expectSameResult(c.ZSTD_DCtx_reset(pair.upstream, 1), pair.port.reset(.session_only));
            try pair.set(.force_ignore_checksum, 0);
            try testing.expect((try pair.decompressDCtx(bad, input.len)) == .error_code);
            try expectSameStream(pair, bad, input.len, 4096, 4096);
            try expectSameResult(c.ZSTD_DCtx_reset(pair.upstream, 1), pair.port.reset(.session_only));
            try pair.set(.force_ignore_checksum, 1);
            try testing.expect((try pair.decompressDCtx(bad, input.len)) == .size);
            try expectSameStream(pair, bad, input.len, 4096, 4096);
        }
    }
    try pair.set(.force_ignore_checksum, 0);
    // The checksum cut off, in part or whole.
    for (1..5) |cut| _ = try pair.decompressDCtx(frame[0 .. frame.len - cut], input.len);
}

test "dictionaries: raw content, full dictionaries, DDicts and prefixes" {
    const corpus = try common.generated(2 << 20, 0.4, 0.2, 13);
    defer gpa.free(corpus);
    const trained = try dc.train(corpus, 64 << 10);
    defer gpa.free(trained);
    const golden = try common.readFile(test_options.reference, "tests/golden-dictionaries/http-dict-missing-symbols");
    defer gpa.free(golden);
    const zero_weight = try common.readFile(test_options.reference, "tests/dict-files/zero-weight-dict");
    defer gpa.free(zero_weight);
    const raw = corpus[0 .. 100 << 10];
    const dicts = [_][]const u8{ trained, raw, golden, zero_weight };
    const input = corpus[corpus.len - (300 << 10) ..];

    for (dicts) |dict| {
        for ([_]i32{ 1, 5, 19 }) |level| {
            const frame = try dc.compressWithDict(input, dict, level, true);
            defer gpa.free(frame);
            const pair = try Pair.init();
            defer pair.deinit();
            try testing.expectEqual(Result{ .size = input.len }, try pair.decompressUsingDict(frame, input.len, dict));

            // Loaded into the context: copied, by reference, each content type.
            for ([_]u32{ 0, 1 }) |method| {
                for ([_]u32{ 0, 1, 2 }) |content_type| {
                    const code = c.ZSTD_DCtx_loadDictionary_advanced(pair.upstream, dict.ptr, dict.len, method, content_type);
                    const result = pair.port.loadDictionaryAdvanced(dict, @fromBackingInt(method), @fromBackingInt(content_type));
                    try expectSameResult(code, result);
                    _ = try pair.decompressDCtx(frame, input.len);
                    // A context's dictionary stays for every frame.
                    _ = try pair.decompressDCtx(frame, input.len);
                    try expectSameStream(pair, frame, input.len, 10_000, 7_000);
                }
            }
            try expectSameResult(c.ZSTD_DCtx_loadDictionary(pair.upstream, null, 0), pair.port.loadDictionary(&.{}));
            _ = try pair.decompressDCtx(frame, input.len);

            // A DDict, copied and by reference.
            const u_ddict = c.ZSTD_createDDict(dict.ptr, dict.len) orelse return error.OutOfMemory;
            defer _ = c.ZSTD_freeDDict(u_ddict);
            const p_ddict = try zstd.createDDict(gpa, dict);
            defer zstd.freeDDict(p_ddict);
            try testing.expectEqual(c.ZSTD_getDictID_fromDDict(u_ddict), zstd.getDictIdFromDDict(p_ddict));
            try testing.expectEqual(c.ZSTD_getDictID_fromDict(dict.ptr, dict.len), zstd.getDictIdFromDict(dict));
            try testing.expectEqual(c.ZSTD_sizeof_DDict(u_ddict), zstd.sizeofDDict(p_ddict));
            {
                const expected = try gpa.alloc(u8, input.len);
                defer gpa.free(expected);
                const actual = try gpa.alloc(u8, input.len);
                defer gpa.free(actual);
                const code = c.ZSTD_decompress_usingDDict(pair.upstream, expected.ptr, expected.len, frame.ptr, frame.len, u_ddict);
                const result = pair.port.decompressUsingDDict(actual, frame, p_ddict);
                try expectSameResult(code, result);
                try testing.expectEqualSlices(u8, expected, actual);
                try testing.expectEqualSlices(u8, input, actual);
            }
            try expectSameResult(c.ZSTD_DCtx_refDDict(pair.upstream, u_ddict), pair.port.refDDict(p_ddict));
            _ = try pair.decompressDCtx(frame, input.len);
            try expectSameResult(c.ZSTD_initDStream_usingDDict(pair.upstream, u_ddict), pair.port.initDStreamUsingDDict(p_ddict));
            try expectSameStream(pair, frame, input.len, 1 << 17, 1 << 17);
            try expectSameResult(c.ZSTD_initDStream_usingDict(pair.upstream, dict.ptr, dict.len), pair.port.initDStreamUsingDict(dict));
            try expectSameStream(pair, frame, input.len, 999, 1 << 17);
            try expectSameResult(c.ZSTD_initDStream(pair.upstream), pair.port.initDStream());
            try expectSameStream(pair, frame, input.len, 1 << 17, 1 << 17);
            const ref_ddict = c.ZSTD_createDDict_byReference(dict.ptr, dict.len) orelse return error.OutOfMemory;
            defer _ = c.ZSTD_freeDDict(ref_ddict);
            const p_ref_ddict = try zstd.createDDictByReference(gpa, dict);
            defer zstd.freeDDict(p_ref_ddict);
            try testing.expectEqual(c.ZSTD_sizeof_DDict(ref_ddict), zstd.sizeofDDict(p_ref_ddict));
            try expectSameResult(c.ZSTD_DCtx_refDDict(pair.upstream, ref_ddict), pair.port.refDDict(p_ref_ddict));
            _ = try pair.decompressDCtx(frame, input.len);
        }
    }

    // A prefix, raw or as a dictionary, for one frame only.
    for ([_]u32{ 0, 1, 2 }) |content_type| {
        for (dicts) |dict| {
            const cctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
            defer _ = c.ZSTD_freeCCtx(cctx);
            _ = c.ZSTD_CCtx_setParameter(cctx, dc.c_level, 6);
            _ = c.ZSTD_CCtx_refPrefix_advanced(cctx, dict.ptr, dict.len, content_type);
            const frame_buffer = try gpa.alloc(u8, c.ZSTD_compressBound(input.len));
            defer gpa.free(frame_buffer);
            const size = c.ZSTD_compress2(cctx, frame_buffer.ptr, frame_buffer.len, input.ptr, input.len);
            if (c.ZSTD_isError(size) != 0) continue;
            const frame = frame_buffer[0..size];
            const pair = try Pair.init();
            defer pair.deinit();
            try expectSameResult(
                c.ZSTD_DCtx_refPrefix_advanced(pair.upstream, dict.ptr, dict.len, content_type),
                pair.port.refPrefixAdvanced(dict, @fromBackingInt(content_type)),
            );
            _ = try pair.decompressDCtx(frame, input.len);
            // Gone for the next frame.
            _ = try pair.decompressDCtx(frame, input.len);
            try expectSameResult(c.ZSTD_DCtx_refPrefix(pair.upstream, dict.ptr, dict.len), pair.port.refPrefix(dict));
            try expectSameStream(pair, frame, input.len, 5000, 5000);
        }
    }
}

test "dictionaries: several DDicts, each frame picking its own by id" {
    const corpus = try common.generated(2 << 20, 0.4, 0.2, 14);
    defer gpa.free(corpus);
    const input = corpus[corpus.len - (200 << 10) ..];
    var dicts: [5][]u8 = undefined;
    var u_ddicts: [5]*c.ZSTD_DDict = undefined;
    var p_ddicts: [5]*zstd.DDict = undefined;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(gpa);
    var expected_out: std.ArrayList(u8) = .empty;
    defer expected_out.deinit(gpa);
    for (&dicts, &u_ddicts, &p_ddicts, 0..) |*dict, *u, *p, i| {
        dict.* = try dc.train(corpus[i * 300_000 ..], 16 << 10);
        std.mem.writeInt(u32, dict.*[4..8], @intCast(1000 + i * 77), .little);
        u.* = c.ZSTD_createDDict(dict.ptr, dict.len) orelse return error.OutOfMemory;
        p.* = try zstd.createDDict(gpa, dict.*);
        const frame = try dc.compressWithDict(input[i * 1000 ..], dict.*, 3, i % 2 == 0);
        defer gpa.free(frame);
        try frames.appendSlice(gpa, frame);
        try expected_out.appendSlice(gpa, input[i * 1000 ..]);
    }
    defer for (dicts, u_ddicts, p_ddicts) |dict, u, p| {
        gpa.free(dict);
        _ = c.ZSTD_freeDDict(u);
        zstd.freeDDict(p);
    };
    const pair = try Pair.init();
    defer pair.deinit();
    try pair.set(.ref_multiple_ddicts, 1);
    for (u_ddicts, p_ddicts) |u, p| {
        try expectSameResult(c.ZSTD_DCtx_refDDict(pair.upstream, u), pair.port.refDDict(p));
    }
    // One shot, the context's last dictionary is loaded before the frame
    // picks its own, as in the original: only the frames of that
    // dictionary decode. A stream picks before it loads.
    _ = try pair.decompressDCtx(frames.items, expected_out.items.len);
    try expectSameStream(pair, frames.items, expected_out.items.len, 30_000, 30_000);
    {
        const out = try gpa.alloc(u8, expected_out.items.len);
        defer gpa.free(out);
        var in: params.InBuffer = .{ .src = frames.items };
        var o: params.OutBuffer = .{ .dst = out };
        try pair.port.reset(.session_only);
        while (in.pos < in.src.len) _ = try pair.port.decompressStream(&o, &in);
        try testing.expectEqualSlices(u8, expected_out.items, o.dst[0..o.pos]);
    }
    // A dictionary referenced twice, and one replaced by one of its id.
    try expectSameResult(c.ZSTD_DCtx_refDDict(pair.upstream, u_ddicts[0]), pair.port.refDDict(p_ddicts[0]));
    _ = try pair.decompressDCtx(frames.items, expected_out.items.len);
    // Many dictionaries, past the set's first table size.
    var more_u: [100]*c.ZSTD_DDict = undefined;
    var more_p: [100]*zstd.DDict = undefined;
    for (&more_u, &more_p, 0..) |*u, *p, i| {
        const dict = try gpa.dupe(u8, dicts[0]);
        defer gpa.free(dict);
        std.mem.writeInt(u32, dict[4..8], @intCast(5000 + i), .little);
        u.* = c.ZSTD_createDDict(dict.ptr, dict.len) orelse return error.OutOfMemory;
        p.* = try zstd.createDDict(gpa, dict);
        try expectSameResult(c.ZSTD_DCtx_refDDict(pair.upstream, u.*), pair.port.refDDict(p.*));
    }
    defer for (more_u, more_p) |u, p| {
        _ = c.ZSTD_freeDDict(u);
        zstd.freeDDict(p);
    };
    try testing.expectEqual(c.ZSTD_sizeof_DCtx(pair.upstream), zstd.sizeofDCtx(pair.port));
    _ = try pair.decompressDCtx(frames.items, expected_out.items.len);
    // Without the parameter, the last referenced is the only one.
    try expectSameResult(c.ZSTD_DCtx_reset(pair.upstream, 3), pair.port.reset(.session_and_parameters));
    try expectSameResult(c.ZSTD_DCtx_refDDict(pair.upstream, u_ddicts[1]), pair.port.refDDict(p_ddicts[1]));
    _ = try pair.decompressDCtx(frames.items, expected_out.items.len);
}

test "dictionaries: corrupted and truncated dictionaries" {
    const corpus = try common.generated(1 << 20, 0.4, 0.2, 15);
    defer gpa.free(corpus);
    const trained = try dc.train(corpus, 32 << 10);
    defer gpa.free(trained);
    const frame = try dc.compressWithDict(corpus[0..100_000], trained, 3, false);
    defer gpa.free(frame);
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(16));
    const random = prng.random();
    // The header and tables are in the first few hundred bytes.
    for (0..common.fuzz_cases) |case| {
        const dict = try gpa.dupe(u8, trained);
        defer gpa.free(dict);
        const len = switch (case % 3) {
            0 => random.uintAtMost(usize, 600),
            else => dict.len,
        };
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
            const at = random.uintLessThan(usize, @min(dict.len, 600));
            dict[at] ^= @as(u8, 1) << random.int(u3);
        }
        const d = dict[0..len];
        // Digested, and used.
        for ([_]u32{ 0, 2 }) |content_type| {
            const u = c.ZSTD_createDDict_advanced(d.ptr, d.len, 0, content_type, .{});
            defer _ = c.ZSTD_freeDDict(u);
            const p = zstd.createDDictAdvanced(gpa, d, .by_copy, @fromBackingInt(content_type)) catch null;
            defer zstd.freeDDict(p);
            try testing.expectEqual(u == null, p == null);
        }
        const pair = try Pair.initNoAsm();
        defer pair.deinit();
        _ = try pair.decompressUsingDict(frame, 100_000, d);
    }
}

test "golden frames: upstream's frames to decode and to refuse" {
    const pair = try Pair.init();
    defer pair.deinit();
    inline for (.{
        "tests/golden-decompression/block-128k.zst",
        "tests/golden-decompression/empty-block.zst",
        "tests/golden-decompression/rle-first-block.zst",
        "tests/golden-decompression/zeroSeq_2B.zst",
        "tests/golden-decompression-errors/off0.bin.zst",
        "tests/golden-decompression-errors/truncated_huff_state.zst",
        "tests/golden-decompression-errors/zeroSeq_extraneous.zst",
    }, .{ true, true, true, true, false, false, false }) |name, ok| {
        const frame = try common.readFile(test_options.reference, name);
        defer gpa.free(frame);
        const result = try pair.decompressDCtx(frame, 1 << 20);
        try testing.expectEqual(ok, result == .size);
        try expectSameStream(pair, frame, 1 << 20, 7, 1000);
    }
    // The golden inputs, compressed by the original at every level.
    var stats: Stats = .{};
    inline for (.{
        "tests/golden-compression/PR-3517-block-splitter-corruption-test",
        "tests/golden-compression/http",
        "tests/golden-compression/huffman-compressed-larger",
        "tests/golden-compression/large-literal-and-match-lengths",
    }) |name| {
        const input = try common.readFile(test_options.reference, name);
        defer gpa.free(input);
        try expectLevels(&stats, input);
    }
}

test "corpus: Canterbury and test/data at levels of each strategy" {
    if (!test_options.canterbury_corpus) return error.SkipZigTest;
    var stats: Stats = .{};
    inline for (.{
        "canterbury/alice29.txt", "canterbury/cp.html",  "canterbury/fields.c",
        "canterbury/kennedy.xls", "canterbury/ptt5",     "canterbury/sum",
        "artificial/aaa.txt",     "artificial/random.txt", "large/E.coli",
        "large/bible.txt",        "large/world192.txt",
    }) |name| {
        const input = try common.readFile(test_options.canterbury, name);
        defer gpa.free(input);
        try expectLevels(&stats, input);
    }
    inline for (.{ "bc7.bin", "mesh.bin", "snapshot.bin" }) |name| {
        const input = try common.readFile(test_options.data, name);
        defer gpa.free(input);
        try expectLevels(&stats, input);
    }
}

test "decompressFrameExact: one frame into its exact size, the checksum checked" {
    const input = try dc.mixedInput(700_000, 17);
    defer gpa.free(input);
    var dctx: zstd.DCtx = undefined;
    dctx.init();
    for ([_]i32{ 1, 3, 19 }) |level| {
        for ([_]bool{ false, true }) |checksum| {
            for ([_]bool{ false, true }) |content_size| {
                const frame = try dc.compress(&.{
                    .{ .param = dc.c_level, .value = level },
                    .{ .param = dc.c_checksum_flag, .value = @intFromBool(checksum) },
                    .{ .param = dc.c_content_size_flag, .value = @intFromBool(content_size) },
                }, input);
                defer gpa.free(frame);
                const out = try gpa.alloc(u8, input.len);
                defer gpa.free(out);
                try dctx.decompressFrameExact(out, frame, .{});
                try testing.expectEqualSlices(u8, input, out);
                if (!checksum) {
                    try testing.expectError(error.ChecksumWrong, dctx.decompressFrameExact(out, frame, .{ .require_checksum = true }));
                } else {
                    try dctx.decompressFrameExact(out, frame, .{ .require_checksum = true });
                    // A wrong checksum, even when the context ignores them.
                    const bad = try gpa.dupe(u8, frame);
                    defer gpa.free(bad);
                    bad[bad.len - 1] ^= 1;
                    try dctx.setParameter(.force_ignore_checksum, 1);
                    try testing.expectError(error.ChecksumWrong, dctx.decompressFrameExact(out, bad, .{}));
                    try dctx.setParameter(.force_ignore_checksum, 0);
                }
                // Sizes other than the frame's.
                try testing.expectError(error.DstSizeTooSmall, dctx.decompressFrameExact(out[0 .. out.len - 1], frame, .{}));
                const larger = try gpa.alloc(u8, input.len + 1);
                defer gpa.free(larger);
                const wrong: zstd.Error = if (content_size) error.SrcSizeWrong else error.CorruptionDetected;
                try testing.expectError(wrong, dctx.decompressFrameExact(larger, frame, .{}));
                // Bytes after the frame, and a skippable frame.
                const two = try gpa.alloc(u8, frame.len + 1);
                defer gpa.free(two);
                @memcpy(two[0..frame.len], frame);
                two[frame.len] = 0;
                try testing.expectError(error.SrcSizeWrong, dctx.decompressFrameExact(out, two, .{}));
                var skippable: [16]u8 = undefined;
                const n = try zstd.writeSkippableFrame(&skippable, "12345678", 3);
                try testing.expectError(error.PrefixUnknown, dctx.decompressFrameExact(out[0..8], skippable[0..n], .{}));
                // Truncated: never a crash.
                var cut: usize = 0;
                while (cut < frame.len) : (cut += 1 + cut / 4) {
                    if (dctx.decompressFrameExact(out, frame[0..cut], .{})) |_| return error.TruncatedAccepted else |_| {}
                }
            }
        }
    }
    // With a dictionary the context refers to, and no allocation.
    const corpus = try common.generated(1 << 20, 0.4, 0.2, 18);
    defer gpa.free(corpus);
    const dict = try dc.train(corpus, 16 << 10);
    defer gpa.free(dict);
    var ddict_buffer: [256 << 10]u8 align(8) = undefined;
    const ddict = zstd.initStaticDDict(&ddict_buffer, dict, .by_ref, .auto) orelse return error.StaticDDict;
    try dctx.refDDict(ddict);
    const frame = try dc.compressWithDict(corpus[0..300_000], dict, 19, true);
    defer gpa.free(frame);
    const out = try gpa.alloc(u8, 300_000);
    defer gpa.free(out);
    try dctx.decompressFrameExact(out, frame, .{ .require_checksum = true });
    try testing.expectEqualSlices(u8, corpus[0..300_000], out);
}
