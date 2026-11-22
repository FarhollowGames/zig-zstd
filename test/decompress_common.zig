//! Helpers the decompressor's oracle tests share: a context of each side,
//! one-shot decoding compared byte for byte, a walker that counts the
//! features a set of frames uses, test frames, and dictionaries.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const frame = @import("frame_test.zig");

pub const gpa = common.gpa;
pub const Result = common.Result;
pub const expectSameResult = frame.expectSameResult;
pub const portResult = frame.portResult;

/// The original's parameter numbers.
pub const d_window_log_max = 100;
pub const d_format = 1000;
pub const d_stable_out_buffer = 1001;
pub const d_force_ignore_checksum = 1002;
pub const d_ref_multiple_ddicts = 1003;
pub const d_disable_huffman_assembly = 1004;
pub const d_max_block_size = 1005;

/// A decompression context of each side, freed by `deinit`.
pub const Pair = struct {
    port: *zstd.DCtx,
    upstream: *c.ZSTD_DCtx,

    pub fn init() !Pair {
        const port = try zstd.DCtx.create(gpa);
        errdefer zstd.freeDCtx(port) catch unreachable;
        const upstream = c.ZSTD_createDCtx() orelse return error.OutOfMemory;
        return .{ .port = port, .upstream = upstream };
    }

    /// With the original's x86-64 assembly Huffman loops off, so that both
    /// sides run the same C loops on corrupt input too; on valid input the
    /// assembly gives the same bytes.
    pub fn initNoAsm() !Pair {
        const pair = try init();
        try pair.set(.disable_huffman_assembly, 1);
        return pair;
    }

    pub fn deinit(pair: Pair) void {
        zstd.freeDCtx(pair.port) catch unreachable;
        _ = c.ZSTD_freeDCtx(pair.upstream);
    }

    /// Sets `param` on both, checking they agree.
    pub fn set(pair: Pair, param: zstd.params.DParameter, value: i32) !void {
        const code = c.ZSTD_DCtx_setParameter(pair.upstream, @backingInt(param), value);
        const result = pair.port.setParameter(param, value);
        expectSameResult(code, result) catch |err| {
            std.debug.print("{t} = {d}\n", .{ param, value });
            return err;
        };
    }

    /// Decodes `src` with `decompressDCtx` into `capacity` bytes on both;
    /// checks the results and, on success, the whole output buffers, which
    /// start out the same. Returns the original's result.
    pub fn decompressDCtx(pair: Pair, src: []const u8, capacity: usize) !Result {
        const expected = try gpa.alloc(u8, capacity);
        defer gpa.free(expected);
        const actual = try gpa.alloc(u8, capacity);
        defer gpa.free(actual);
        @memset(expected, 0xA5);
        @memset(actual, 0xA5);
        const code = c.ZSTD_decompressDCtx(pair.upstream, expected.ptr, expected.len, src.ptr, src.len);
        const result = pair.port.decompressDCtx(actual, src);
        try expectSameResult(code, result);
        try expectSameOutput(Result.of(code), expected, actual);
        return Result.of(code);
    }

    /// As `decompressDCtx`, with `dict` through `decompressUsingDict`.
    pub fn decompressUsingDict(pair: Pair, src: []const u8, capacity: usize, dict: []const u8) !Result {
        const expected = try gpa.alloc(u8, capacity);
        defer gpa.free(expected);
        const actual = try gpa.alloc(u8, capacity);
        defer gpa.free(actual);
        @memset(expected, 0xA5);
        @memset(actual, 0xA5);
        const code = c.ZSTD_decompress_usingDict(pair.upstream, expected.ptr, expected.len, src.ptr, src.len, dict.ptr, dict.len);
        const result = pair.port.decompressUsingDict(actual, src, dict);
        try expectSameResult(code, result);
        try expectSameOutput(Result.of(code), expected, actual);
        return Result.of(code);
    }
};

/// After a success, the decoded bytes must be the same. Past them both
/// sides leave over-copied bytes, read from their own scratch buffers,
/// whose contents are not the same.
pub fn expectSameOutput(result: Result, expected: []const u8, actual: []const u8) !void {
    if (result != .size) return;
    const n = result.size;
    if (std.mem.eql(u8, expected[0..n], actual[0..n])) return;
    const first = std.mem.indexOfDiff(u8, expected[0..n], actual[0..n]).?;
    std.debug.print("outputs differ at byte {d} of {d}\n", .{ first, n });
    return error.OutputsDiffer;
}

/// Decodes `src` on both sides with fresh contexts, through the one-shot
/// API with an output of the exact size and of the size plus a margin,
/// and through `decompressFrameExact` where the frame has a size; checks
/// the output is `expected` when given.
pub fn expectDecodes(src: []const u8, expected: ?[]const u8) !void {
    const pair = try Pair.init();
    defer pair.deinit();
    const size = if (expected) |e| e.len else blk: {
        const bound = c.ZSTD_decompressBound(src.ptr, src.len);
        break :blk if (bound >= zstd.params.content_size_error) 1 << 20 else @as(usize, @intCast(bound));
    };
    for ([_]usize{ size, size + 200_000 }) |capacity| {
        const result = try pair.decompressDCtx(src, capacity);
        if (expected) |e| {
            if (result != .size or result.size != e.len) {
                std.debug.print("expected {d} bytes, got {any}\n", .{ e.len, result });
                return error.WrongSize;
            }
        }
    }
    if (expected) |e| {
        const out = try gpa.alloc(u8, e.len);
        defer gpa.free(out);
        const n = try pair.port.decompressDCtx(out, src);
        try std.testing.expectEqualSlices(u8, e, out[0..n]);
    }
}

/// The features a set of frames uses, counted from their headers.
pub const Stats = struct {
    frames: usize = 0,
    skippable_frames: usize = 0,
    checksums: usize = 0,
    dict_ids: usize = 0,
    single_segment: usize = 0,
    /// Raw, RLE and compressed blocks.
    blocks: [3]usize = @splat(0),
    /// Literals sections: raw, RLE, Huffman with a new table, Huffman with
    /// the last one (treeless).
    literals: [4]usize = @splat(0),
    huffman_1_stream: usize = 0,
    huffman_4_streams: usize = 0,
    /// 4-stream sections with a new table, by the decoder the original's
    /// cost model picks: single-symbol (X1), double-symbol (X2).
    huffman_x1: usize = 0,
    huffman_x2: usize = 0,
    /// Sections over 64 KiB, which a streaming or exact-size output splits
    /// between the output and the context.
    literals_over_64k: usize = 0,
    /// Blocks without sequences.
    no_sequences: usize = 0,
    /// Table modes of literal lengths, offsets and match lengths:
    /// predefined, RLE, FSE, repeat.
    seq_modes: [3][4]usize = @splat(@splat(0)),

    /// Adds the frames of `src`.
    pub fn add(stats: *Stats, src_in: []const u8) !void {
        var src = src_in;
        while (src.len > 0) {
            const magic = std.mem.readInt(u32, src[0..4], .little);
            if (magic & zstd.params.magic_skippable_mask == zstd.params.magic_skippable_start) {
                stats.skippable_frames += 1;
                src = src[try zstd.findFrameCompressedSize(src)..];
                continue;
            }
            const size = try zstd.findFrameCompressedSize(src);
            try stats.addFrame(src[0..size]);
            src = src[size..];
        }
    }

    fn addFrame(stats: *Stats, src: []const u8) !void {
        var zfh: zstd.FrameHeader = .{};
        if (try zstd.getFrameHeader(&zfh, src) != 0) return error.Truncated;
        stats.frames += 1;
        if (zfh.checksum_flag) stats.checksums += 1;
        if (zfh.dict_id != 0) stats.dict_ids += 1;
        if (src[4] & 0x20 != 0) stats.single_segment += 1;
        var ip: usize = zfh.header_size;
        while (true) {
            const header = std.mem.readInt(u24, src[ip..][0..3], .little);
            const last = header & 1 != 0;
            const block_type = (header >> 1) & 3;
            const c_size: usize = header >> 3;
            ip += 3;
            stats.blocks[block_type] += 1;
            switch (block_type) {
                0 => ip += c_size,
                1 => ip += 1,
                2 => {
                    stats.addBlock(src[ip..][0..c_size]);
                    ip += c_size;
                },
                else => return error.Reserved,
            }
            if (last) break;
        }
    }

    fn addBlock(stats: *Stats, b: []const u8) void {
        const lit_type = b[0] & 3;
        const lhl = (b[0] >> 2) & 3;
        stats.literals[lit_type] += 1;
        var section: usize = undefined;
        switch (lit_type) {
            0, 1 => {
                const lh_size: usize = switch (lhl) {
                    0, 2 => 1,
                    1 => 2,
                    else => 3,
                };
                const lit_size: usize = switch (lhl) {
                    0, 2 => b[0] >> 3,
                    1 => std.mem.readInt(u16, b[0..2], .little) >> 4,
                    else => std.mem.readInt(u24, b[0..3], .little) >> 4,
                };
                if (lit_size > 1 << 16) stats.literals_over_64k += 1;
                section = lh_size + if (lit_type == 0) lit_size else 1;
            },
            else => {
                const lhc = std.mem.readInt(u32, b[0..4], .little);
                var lh_size: usize = undefined;
                var lit_size: usize = undefined;
                var lit_csize: usize = undefined;
                switch (lhl) {
                    0, 1 => {
                        lh_size = 3;
                        lit_size = (lhc >> 4) & 0x3FF;
                        lit_csize = (lhc >> 14) & 0x3FF;
                    },
                    2 => {
                        lh_size = 4;
                        lit_size = (lhc >> 4) & 0x3FFF;
                        lit_csize = lhc >> 18;
                    },
                    else => {
                        lh_size = 5;
                        lit_size = (lhc >> 4) & 0x3FFFF;
                        lit_csize = (lhc >> 22) + (@as(usize, b[4]) << 10);
                    },
                }
                if (lhl == 0) stats.huffman_1_stream += 1 else stats.huffman_4_streams += 1;
                if (lhl != 0 and lit_type == 2) {
                    if (c.HUF_selectDecoder(lit_size, lit_csize) != 0) stats.huffman_x2 += 1 else stats.huffman_x1 += 1;
                }
                if (lit_size > 1 << 16) stats.literals_over_64k += 1;
                section = lh_size + lit_csize;
            },
        }
        const seqs = b[section..];
        var ip: usize = 1;
        var nb_seq: usize = seqs[0];
        if (nb_seq == 0xFF) {
            nb_seq = @as(usize, std.mem.readInt(u16, seqs[1..3], .little)) + 0x7F00;
            ip = 3;
        } else if (nb_seq > 0x7F) {
            nb_seq = ((nb_seq - 0x80) << 8) + seqs[1];
            ip = 2;
        }
        if (nb_seq == 0) {
            stats.no_sequences += 1;
            return;
        }
        const modes = seqs[ip];
        stats.seq_modes[0][modes >> 6] += 1;
        stats.seq_modes[1][(modes >> 4) & 3] += 1;
        stats.seq_modes[2][(modes >> 2) & 3] += 1;
    }
};

/// `src` compressed by the original with `params`; the caller frees it.
pub const compress = common.upstreamCompress2;

/// The original's parameter numbers for compression.
pub const c_level = 100;
pub const c_window_log = 101;
pub const c_strategy = 107;
pub const c_ldm = 160;
pub const c_content_size_flag = 200;
pub const c_checksum_flag = 201;
pub const c_dict_id_flag = 202;
pub const c_format = 10;
pub const c_literal_compression_mode = 1002;
pub const c_target_cblock_size = 130;
pub const c_max_block_size = 1015;

/// A dictionary of `capacity` bytes trained on 1 KiB samples of `corpus`.
pub fn train(corpus: []const u8, capacity: usize) ![]u8 {
    var sizes: [1000]usize = @splat(1024);
    const nb_samples: c_uint = @intCast(@min(sizes.len, corpus.len / 1024));
    const dict = try gpa.alloc(u8, capacity);
    errdefer gpa.free(dict);
    const code = c.ZDICT_trainFromBuffer(dict.ptr, dict.len, corpus.ptr, &sizes, nb_samples);
    if (c.ZDICT_isError(code) != 0) return error.TrainingFailed;
    return gpa.realloc(dict, code);
}

/// `src` compressed by the original with `dict` at `level`; the caller
/// frees it.
pub fn compressWithDict(src: []const u8, dict: []const u8, level: i32, checksum: bool) ![]u8 {
    const cctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
    defer _ = c.ZSTD_freeCCtx(cctx);
    _ = c.ZSTD_CCtx_setParameter(cctx, c_level, level);
    _ = c.ZSTD_CCtx_setParameter(cctx, c_checksum_flag, @intFromBool(checksum));
    if (c.ZSTD_isError(c.ZSTD_CCtx_loadDictionary(cctx, dict.ptr, dict.len)) != 0) return error.UpstreamFailed;
    const dst = try gpa.alloc(u8, c.ZSTD_compressBound(src.len));
    errdefer gpa.free(dst);
    const code = c.ZSTD_compress2(cctx, dst.ptr, dst.len, src.ptr, src.len);
    if (c.ZSTD_isError(code) != 0) return error.UpstreamFailed;
    return gpa.realloc(dst, code);
}

/// Inputs that make every kind of block and section: text-like data,
/// noise (raw blocks and literals), runs (RLE), and mixes.
pub fn mixedInput(size: usize, seed: u32) ![]u8 {
    const out = try gpa.alloc(u8, size);
    errdefer gpa.free(out);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var pos: usize = 0;
    while (pos < size) {
        const len = @min(size - pos, random.intRangeAtMost(usize, 1, 150_000));
        const piece = out[pos..][0..len];
        switch (random.uintLessThan(u32, 5)) {
            0 => random.bytes(piece),
            1 => @memset(piece, random.int(u8)),
            2 => {
                const g = try common.generated(len, random.float(f64), random.float(f64), random.int(u32));
                defer gpa.free(g);
                @memcpy(piece, g);
            },
            3 => for (piece) |*b| {
                b.* = random.uintLessThan(u8, 4) + 'a';
            },
            else => {
                const g = try common.generated(len, 0.5, 0.0, random.int(u32));
                defer gpa.free(g);
                @memcpy(piece, g);
            },
        }
        pos += len;
    }
    return out;
}
