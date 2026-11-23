//! The block decoder, from the original's zstd_decompress_block.c: the
//! literals section, the sequences section's tables, the sequence decoder
//! and the three sequence loops (in order, with literals split between the
//! output and the context, and with prefetching), and the block entry
//! points. Every function reads untrusted bytes and gives the original's
//! result, an error or the output, on any input.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Error = @import("../error.zig").Error;
const params = @import("../params.zig");
const zstd_internal = @import("../common/zstd_internal.zig");
const bitstream = @import("../common/bitstream.zig");
const entropy_common = @import("../common/entropy_common.zig");
const huf = @import("../common/huf.zig");
const fse = @import("../common/fse.zig");
const huf_decompress = @import("huf_decompress.zig");
const internal = @import("decompress_internal.zig");
const DCtx = internal.DCtx;
const SeqSymbol = internal.SeqSymbol;
const SeqSymbolHeader = internal.SeqSymbolHeader;
const DStream = bitstream.DStream;
const highbit32 = bitstream.highbit32;
const wildcopy_overlength = zstd_internal.wildcopy_overlength;
const wildcopy_veclen = zstd_internal.wildcopy_veclen;
const lit_buffer_extra_size = internal.lit_buffer_extra_size;

const is_32bit = @sizeOf(usize) == 4;

/// `blockProperties_t`.
pub const BlockProperties = struct {
    block_type: zstd_internal.BlockType,
    last_block: bool,
    orig_size: u32,
};

/// `ZSTD_blockSizeMax`.
fn blockSizeMax(dctx: *const DCtx) usize {
    const size: usize = if (dctx.is_frame_decompression) dctx.f_params.block_size_max else params.block_size_max;
    assert(size <= params.block_size_max);
    return size;
}

/// `ZSTD_getcBlockSize`: reads a block header; returns the block's size in
/// the frame (1 for an RLE block).
pub fn getcBlockSize(src: []const u8, bp: *BlockProperties) Error!usize {
    if (src.len < zstd_internal.block_header_size) return error.SrcSizeWrong;
    const header = std.mem.readInt(u24, src[0..3], .little);
    const c_size: u32 = header >> 3;
    bp.last_block = header & 1 != 0;
    bp.block_type = @fromBackingInt(@as(u2, @truncate(header >> 1)));
    bp.orig_size = c_size;
    if (bp.block_type == .rle) return 1;
    if (bp.block_type == .reserved) return error.CorruptionDetected;
    return c_size;
}

// --------------------------------------------------------
// Literals
// --------------------------------------------------------

/// `ZSTD_allocateLiteralsBuffer`: where the block's literals go: after the
/// block in `dst` when there is room and no window to protect, else in
/// the context's extra buffer, or split between the end of the block's
/// output and the extra buffer.
fn allocateLiteralsBuffer(
    dctx: *DCtx,
    dst: [*]u8,
    dst_capacity: usize,
    lit_size: usize,
    streaming: internal.StreamingOperation,
    expected_write_size: usize,
    split_immediately: bool,
) void {
    const block_size_max = blockSizeMax(dctx);
    assert(lit_size <= block_size_max);
    assert(expected_write_size <= block_size_max);
    if (streaming == .not_streaming and
        dst_capacity > block_size_max + wildcopy_overlength + lit_size + wildcopy_overlength)
    {
        dctx.lit_buffer = dst + block_size_max + wildcopy_overlength;
        dctx.lit_buffer_end = dctx.lit_buffer + lit_size;
        dctx.lit_buffer_location = .in_dst;
    } else if (lit_size <= lit_buffer_extra_size) {
        dctx.lit_buffer = &dctx.lit_extra_buffer;
        dctx.lit_buffer_end = dctx.lit_buffer + lit_size;
        dctx.lit_buffer_location = .not_in_dst;
    } else {
        assert(block_size_max > lit_buffer_extra_size);
        // The tail of the literals goes in the extra buffer, the rest at
        // the end of the block, with room for over-reads, never more than
        // the block past `dst`, which in a stream could be the window.
        if (split_immediately) {
            dctx.lit_buffer = dst + expected_write_size - lit_size + lit_buffer_extra_size - wildcopy_overlength;
            dctx.lit_buffer_end = dctx.lit_buffer + lit_size - lit_buffer_extra_size;
        } else {
            // Decoded whole into `dst` first, then partly moved.
            dctx.lit_buffer = dst + expected_write_size - lit_size;
            dctx.lit_buffer_end = dst + expected_write_size;
        }
        dctx.lit_buffer_location = .split;
    }
}

/// `ZSTD_decodeLiteralsBlock`: decodes the literals section at the start of
/// `src`, a compressed block; returns the section's size.
pub fn decodeLiteralsBlock(
    dctx: *DCtx,
    src: []const u8,
    dst: []u8,
    streaming: internal.StreamingOperation,
) Error!usize {
    if (src.len < zstd_internal.min_cblock_size) return error.CorruptionDetected;
    const istart = src.ptr;
    const lit_enc_type: zstd_internal.SymbolEncodingType = @fromBackingInt(@as(u2, @truncate(istart[0])));
    const block_size_max = blockSizeMax(dctx);
    const lhl_code: u2 = @truncate(istart[0] >> 2);
    const expected_write_size = @min(block_size_max, dst.len);

    switch (lit_enc_type) {
        .repeat, .compressed => {
            if (lit_enc_type == .repeat and !dctx.lit_entropy) return error.DictionaryCorrupted;
            if (src.len < 5) return error.CorruptionDetected;
            var lh_size: usize = undefined;
            var lit_size: usize = undefined;
            var lit_csize: usize = undefined;
            var single_stream = false;
            const lhc = std.mem.readInt(u32, istart[0..4], .little);
            switch (lhl_code) {
                0, 1 => {
                    // 2 - 2 - 10 - 10
                    single_stream = lhl_code == 0;
                    lh_size = 3;
                    lit_size = (lhc >> 4) & 0x3FF;
                    lit_csize = (lhc >> 14) & 0x3FF;
                },
                2 => {
                    // 2 - 2 - 14 - 14
                    lh_size = 4;
                    lit_size = (lhc >> 4) & 0x3FFF;
                    lit_csize = lhc >> 18;
                },
                3 => {
                    // 2 - 2 - 18 - 18
                    lh_size = 5;
                    lit_size = (lhc >> 4) & 0x3FFFF;
                    lit_csize = (lhc >> 22) + (@as(usize, istart[4]) << 10);
                },
            }
            if (lit_size > block_size_max) return error.CorruptionDetected;
            if (!single_stream and lit_size < zstd_internal.min_literals_for_4_streams) {
                return error.LiteralsHeaderWrong;
            }
            if (lit_csize + lh_size > src.len) return error.CorruptionDetected;
            if (expected_write_size < lit_size) return error.DstSizeTooSmall;
            allocateLiteralsBuffer(dctx, dst.ptr, dst.len, lit_size, streaming, expected_write_size, false);

            const lit_dst = dctx.lit_buffer[0..lit_size];
            const lit_src = src[lh_size..][0..lit_csize];
            const flags: huf.Flags = .{ .disable_asm = dctx.disable_huf_asm };
            const huf_result = if (lit_enc_type == .repeat)
                (if (single_stream)
                    huf_decompress.decompress1XUsingDTable(lit_dst, lit_src, dctx.huf_ptr, flags)
                else
                    huf_decompress.decompress4XUsingDTable(lit_dst, lit_src, dctx.huf_ptr, flags))
            else if (single_stream)
                huf_decompress.decompress1X1DCtxWksp(&dctx.entropy.huf_table, lit_dst, lit_src, &dctx.workspace, flags)
            else
                huf_decompress.decompress4XHufOnlyWksp(&dctx.entropy.huf_table, lit_dst, lit_src, &dctx.workspace, flags);

            if (dctx.lit_buffer_location == .split) {
                assert(lit_size > lit_buffer_extra_size);
                @memcpy(dctx.lit_extra_buffer[0..lit_buffer_extra_size], (dctx.lit_buffer_end - lit_buffer_extra_size)[0..lit_buffer_extra_size]);
                @memmove(
                    (dctx.lit_buffer + lit_buffer_extra_size - wildcopy_overlength)[0 .. lit_size - lit_buffer_extra_size],
                    dctx.lit_buffer[0 .. lit_size - lit_buffer_extra_size],
                );
                dctx.lit_buffer += lit_buffer_extra_size - wildcopy_overlength;
                dctx.lit_buffer_end -= wildcopy_overlength;
            }
            _ = huf_result catch return error.CorruptionDetected;

            dctx.lit_ptr = dctx.lit_buffer;
            dctx.lit_size = lit_size;
            dctx.lit_entropy = true;
            if (lit_enc_type == .compressed) dctx.huf_ptr = &dctx.entropy.huf_table;
            return lit_csize + lh_size;
        },
        .basic => {
            var lh_size: usize = undefined;
            var lit_size: usize = undefined;
            switch (lhl_code) {
                0, 2 => {
                    lh_size = 1;
                    lit_size = istart[0] >> 3;
                },
                1 => {
                    lh_size = 2;
                    lit_size = std.mem.readInt(u16, istart[0..2], .little) >> 4;
                },
                3 => {
                    lh_size = 3;
                    if (src.len < 3) return error.CorruptionDetected;
                    lit_size = std.mem.readInt(u24, istart[0..3], .little) >> 4;
                },
            }
            if (lit_size > block_size_max) return error.CorruptionDetected;
            if (expected_write_size < lit_size) return error.DstSizeTooSmall;
            allocateLiteralsBuffer(dctx, dst.ptr, dst.len, lit_size, streaming, expected_write_size, true);

            if (lh_size + lit_size + wildcopy_overlength > src.len) {
                // Too close to the end of `src` to read past the literals.
                if (lit_size + lh_size > src.len) return error.CorruptionDetected;
                if (dctx.lit_buffer_location == .split) {
                    @memmove(dctx.lit_buffer[0 .. lit_size - lit_buffer_extra_size], src[lh_size..][0 .. lit_size - lit_buffer_extra_size]);
                    @memcpy(dctx.lit_extra_buffer[0..lit_buffer_extra_size], src[lh_size + lit_size - lit_buffer_extra_size ..][0..lit_buffer_extra_size]);
                } else {
                    @memmove(dctx.lit_buffer[0..lit_size], src[lh_size..][0..lit_size]);
                }
                dctx.lit_ptr = dctx.lit_buffer;
                dctx.lit_size = lit_size;
                return lh_size + lit_size;
            }
            // The literals are read in place, from `src`.
            dctx.lit_ptr = istart + lh_size;
            dctx.lit_size = lit_size;
            dctx.lit_buffer_end = dctx.lit_ptr + lit_size;
            dctx.lit_buffer_location = .not_in_dst;
            return lh_size + lit_size;
        },
        .rle => {
            var lh_size: usize = undefined;
            var lit_size: usize = undefined;
            switch (lhl_code) {
                0, 2 => {
                    lh_size = 1;
                    lit_size = istart[0] >> 3;
                },
                1 => {
                    lh_size = 2;
                    if (src.len < 3) return error.CorruptionDetected;
                    lit_size = std.mem.readInt(u16, istart[0..2], .little) >> 4;
                },
                3 => {
                    lh_size = 3;
                    if (src.len < 4) return error.CorruptionDetected;
                    lit_size = std.mem.readInt(u24, istart[0..3], .little) >> 4;
                },
            }
            if (lit_size > block_size_max) return error.CorruptionDetected;
            if (expected_write_size < lit_size) return error.DstSizeTooSmall;
            allocateLiteralsBuffer(dctx, dst.ptr, dst.len, lit_size, streaming, expected_write_size, true);
            if (dctx.lit_buffer_location == .split) {
                @memset(dctx.lit_buffer[0 .. lit_size - lit_buffer_extra_size], istart[lh_size]);
                @memset(dctx.lit_extra_buffer[0..lit_buffer_extra_size], istart[lh_size]);
            } else {
                @memset(dctx.lit_buffer[0..lit_size], istart[lh_size]);
            }
            dctx.lit_ptr = dctx.lit_buffer;
            dctx.lit_size = lit_size;
            return lh_size + 1;
        },
    }
}

// --------------------------------------------------------
// Sequence tables
// --------------------------------------------------------

/// A predefined table from its entries and log, after the original's
/// header {1, 1, 1, log}.
fn defaultTable(comptime log: u32, comptime entries: []const [4]u32) [(1 << log) + 1]SeqSymbol {
    var table: [(1 << log) + 1]SeqSymbol = undefined;
    table[0] = .{ .next_state = 1, .nb_additional_bits = 1, .nb_bits = 1, .base_value = log };
    assert(entries.len == 1 << log);
    for (entries, 1..) |e, i| {
        table[i] = .{ .next_state = e[0], .nb_additional_bits = e[1], .nb_bits = e[2], .base_value = e[3] };
    }
    return table;
}

/// `LL_defaultDTable`: the table of the predefined distribution, as the original
/// writes it out, after a header of {1, 1, 1, log} read as {fast mode, log}.
pub const ll_default_dtable = defaultTable(zstd_internal.ll_default_norm_log, &.{
    .{ 0, 0, 4, 0 },
    .{ 16, 0, 4, 0 },
    .{ 32, 0, 5, 1 },
    .{ 0, 0, 5, 3 },
    .{ 0, 0, 5, 4 },
    .{ 0, 0, 5, 6 },
    .{ 0, 0, 5, 7 },
    .{ 0, 0, 5, 9 },
    .{ 0, 0, 5, 10 },
    .{ 0, 0, 5, 12 },
    .{ 0, 0, 6, 14 },
    .{ 0, 1, 5, 16 },
    .{ 0, 1, 5, 20 },
    .{ 0, 1, 5, 22 },
    .{ 0, 2, 5, 28 },
    .{ 0, 3, 5, 32 },
    .{ 0, 4, 5, 48 },
    .{ 32, 6, 5, 64 },
    .{ 0, 7, 5, 128 },
    .{ 0, 8, 6, 256 },
    .{ 0, 10, 6, 1024 },
    .{ 0, 12, 6, 4096 },
    .{ 32, 0, 4, 0 },
    .{ 0, 0, 4, 1 },
    .{ 0, 0, 5, 2 },
    .{ 32, 0, 5, 4 },
    .{ 0, 0, 5, 5 },
    .{ 32, 0, 5, 7 },
    .{ 0, 0, 5, 8 },
    .{ 32, 0, 5, 10 },
    .{ 0, 0, 5, 11 },
    .{ 0, 0, 6, 13 },
    .{ 32, 1, 5, 16 },
    .{ 0, 1, 5, 18 },
    .{ 32, 1, 5, 22 },
    .{ 0, 2, 5, 24 },
    .{ 32, 3, 5, 32 },
    .{ 0, 3, 5, 40 },
    .{ 0, 6, 4, 64 },
    .{ 16, 6, 4, 64 },
    .{ 32, 7, 5, 128 },
    .{ 0, 9, 6, 512 },
    .{ 0, 11, 6, 2048 },
    .{ 48, 0, 4, 0 },
    .{ 16, 0, 4, 1 },
    .{ 32, 0, 5, 2 },
    .{ 32, 0, 5, 3 },
    .{ 32, 0, 5, 5 },
    .{ 32, 0, 5, 6 },
    .{ 32, 0, 5, 8 },
    .{ 32, 0, 5, 9 },
    .{ 32, 0, 5, 11 },
    .{ 32, 0, 5, 12 },
    .{ 0, 0, 6, 15 },
    .{ 32, 1, 5, 18 },
    .{ 32, 1, 5, 20 },
    .{ 32, 2, 5, 24 },
    .{ 32, 2, 5, 28 },
    .{ 32, 3, 5, 40 },
    .{ 32, 4, 5, 48 },
    .{ 0, 16, 6, 65536 },
    .{ 0, 15, 6, 32768 },
    .{ 0, 14, 6, 16384 },
    .{ 0, 13, 6, 8192 },
});

/// `OF_defaultDTable`: the table of the predefined distribution, as the original
/// writes it out, after a header of {1, 1, 1, log} read as {fast mode, log}.
pub const of_default_dtable = defaultTable(zstd_internal.of_default_norm_log, &.{
    .{ 0, 0, 5, 0 },
    .{ 0, 6, 4, 61 },
    .{ 0, 9, 5, 509 },
    .{ 0, 15, 5, 32765 },
    .{ 0, 21, 5, 2097149 },
    .{ 0, 3, 5, 5 },
    .{ 0, 7, 4, 125 },
    .{ 0, 12, 5, 4093 },
    .{ 0, 18, 5, 262141 },
    .{ 0, 23, 5, 8388605 },
    .{ 0, 5, 5, 29 },
    .{ 0, 8, 4, 253 },
    .{ 0, 14, 5, 16381 },
    .{ 0, 20, 5, 1048573 },
    .{ 0, 2, 5, 1 },
    .{ 16, 7, 4, 125 },
    .{ 0, 11, 5, 2045 },
    .{ 0, 17, 5, 131069 },
    .{ 0, 22, 5, 4194301 },
    .{ 0, 4, 5, 13 },
    .{ 16, 8, 4, 253 },
    .{ 0, 13, 5, 8189 },
    .{ 0, 19, 5, 524285 },
    .{ 0, 1, 5, 1 },
    .{ 16, 6, 4, 61 },
    .{ 0, 10, 5, 1021 },
    .{ 0, 16, 5, 65533 },
    .{ 0, 28, 5, 268435453 },
    .{ 0, 27, 5, 134217725 },
    .{ 0, 26, 5, 67108861 },
    .{ 0, 25, 5, 33554429 },
    .{ 0, 24, 5, 16777213 },
});

/// `ML_defaultDTable`: the table of the predefined distribution, as the original
/// writes it out, after a header of {1, 1, 1, log} read as {fast mode, log}.
pub const ml_default_dtable = defaultTable(zstd_internal.ml_default_norm_log, &.{
    .{ 0, 0, 6, 3 },
    .{ 0, 0, 4, 4 },
    .{ 32, 0, 5, 5 },
    .{ 0, 0, 5, 6 },
    .{ 0, 0, 5, 8 },
    .{ 0, 0, 5, 9 },
    .{ 0, 0, 5, 11 },
    .{ 0, 0, 6, 13 },
    .{ 0, 0, 6, 16 },
    .{ 0, 0, 6, 19 },
    .{ 0, 0, 6, 22 },
    .{ 0, 0, 6, 25 },
    .{ 0, 0, 6, 28 },
    .{ 0, 0, 6, 31 },
    .{ 0, 0, 6, 34 },
    .{ 0, 1, 6, 37 },
    .{ 0, 1, 6, 41 },
    .{ 0, 2, 6, 47 },
    .{ 0, 3, 6, 59 },
    .{ 0, 4, 6, 83 },
    .{ 0, 7, 6, 131 },
    .{ 0, 9, 6, 515 },
    .{ 16, 0, 4, 4 },
    .{ 0, 0, 4, 5 },
    .{ 32, 0, 5, 6 },
    .{ 0, 0, 5, 7 },
    .{ 32, 0, 5, 9 },
    .{ 0, 0, 5, 10 },
    .{ 0, 0, 6, 12 },
    .{ 0, 0, 6, 15 },
    .{ 0, 0, 6, 18 },
    .{ 0, 0, 6, 21 },
    .{ 0, 0, 6, 24 },
    .{ 0, 0, 6, 27 },
    .{ 0, 0, 6, 30 },
    .{ 0, 0, 6, 33 },
    .{ 0, 1, 6, 35 },
    .{ 0, 1, 6, 39 },
    .{ 0, 2, 6, 43 },
    .{ 0, 3, 6, 51 },
    .{ 0, 4, 6, 67 },
    .{ 0, 5, 6, 99 },
    .{ 0, 8, 6, 259 },
    .{ 32, 0, 4, 4 },
    .{ 48, 0, 4, 4 },
    .{ 16, 0, 4, 5 },
    .{ 32, 0, 5, 7 },
    .{ 32, 0, 5, 8 },
    .{ 32, 0, 5, 10 },
    .{ 32, 0, 5, 11 },
    .{ 0, 0, 6, 14 },
    .{ 0, 0, 6, 17 },
    .{ 0, 0, 6, 20 },
    .{ 0, 0, 6, 23 },
    .{ 0, 0, 6, 26 },
    .{ 0, 0, 6, 29 },
    .{ 0, 0, 6, 32 },
    .{ 0, 16, 6, 65539 },
    .{ 0, 15, 6, 32771 },
    .{ 0, 14, 6, 16387 },
    .{ 0, 13, 6, 8195 },
    .{ 0, 12, 6, 4099 },
    .{ 0, 11, 6, 2051 },
    .{ 0, 10, 6, 1027 },
});

/// `ZSTD_buildSeqTable_rle`: a table of one symbol.
fn buildSeqTableRle(dt: [*]SeqSymbol, base_value: u32, nb_add_bits: u8) void {
    const header: *SeqSymbolHeader = @ptrCast(dt);
    header.table_log = 0;
    header.fast_mode = 0;
    dt[1] = .{ .nb_bits = 0, .next_state = 0, .nb_additional_bits = nb_add_bits, .base_value = base_value };
}

/// `ZSTD_buildFSETable`: the decoding table of a normalized distribution,
/// already validated by `readNCount`. `wksp` holds
/// `build_fse_table_wksp_size` bytes.
pub fn buildFSETable(
    dt: [*]SeqSymbol,
    normalized_counter: []const i16,
    max_symbol_value: u32,
    base_value: []const u32,
    nb_additional_bits: []const u8,
    table_log: u32,
    wksp: []u32,
) void {
    const table_decode = dt + 1;
    const max_sv1 = max_symbol_value + 1;
    const table_size = @as(u32, 1) << @intCast(table_log);
    const wksp_bytes = std.mem.sliceAsBytes(wksp);
    assert(wksp_bytes.len >= internal.build_fse_table_wksp_size);
    const symbol_next: [*]u16 = @ptrCast(wksp.ptr);
    const spread = wksp_bytes[@sizeOf(u16) * (zstd_internal.max_seq + 1) ..];
    var high_threshold = table_size - 1;

    assert(max_symbol_value <= zstd_internal.max_seq);
    assert(table_log <= zstd_internal.max_fse_log);

    // Lay down the low-probability symbols.
    {
        var header: SeqSymbolHeader = .{ .table_log = table_log, .fast_mode = 1 };
        const large_limit: i16 = @intCast(@as(u32, 1) << @intCast(table_log - 1));
        for (0..max_sv1) |s| {
            if (normalized_counter[s] == -1) {
                table_decode[high_threshold].base_value = @intCast(s);
                high_threshold -%= 1;
                symbol_next[s] = 1;
            } else {
                if (normalized_counter[s] >= large_limit) header.fast_mode = 0;
                symbol_next[s] = @intCast(normalized_counter[s]);
            }
        }
        @as(*SeqSymbolHeader, @ptrCast(dt)).* = header;
    }

    // Spread the symbols.
    assert(table_size <= 512);
    if (high_threshold == table_size - 1) {
        // No low-probability symbols: lay the symbols down in order, 8
        // bytes at a time, then spread the positions with no variable
        // inner loop. The workspace has 8 bytes past the table for the
        // overwrite.
        const table_mask: usize = table_size - 1;
        const step: usize = fse.tableStep(table_size);
        {
            var pos: usize = 0;
            var sv: u64 = 0;
            for (0..max_sv1) |s| {
                const n: usize = @intCast(normalized_counter[s]);
                std.mem.writeInt(u64, spread[pos..][0..8], sv, .little);
                var i: usize = 8;
                while (i < n) : (i += 8) std.mem.writeInt(u64, spread[pos + i ..][0..8], sv, .little);
                pos += n;
                sv +%= 0x0101010101010101;
            }
        }
        var position: usize = 0;
        var s: usize = 0;
        while (s < table_size) : (s += 2) {
            table_decode[position & table_mask].base_value = spread[s];
            table_decode[(position + step) & table_mask].base_value = spread[s + 1];
            position = (position + 2 * step) & table_mask;
        }
        assert(position == 0);
    } else {
        const table_mask = table_size - 1;
        const step = fse.tableStep(table_size);
        var position: u32 = 0;
        for (0..max_sv1) |s| {
            const n = normalized_counter[s];
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                table_decode[position].base_value = @intCast(s);
                position = (position + step) & table_mask;
                // Skip the low-probability area.
                while (position > high_threshold) position = (position + step) & table_mask;
            }
        }
        // `readNCount` checked the distribution, so every cell is reached once.
        assert(position == 0);
    }

    // The decoding table.
    for (table_decode[0..table_size]) |*entry| {
        const symbol = entry.base_value;
        const next_state: u32 = symbol_next[symbol];
        symbol_next[symbol] += 1;
        entry.nb_bits = @intCast(table_log - highbit32(next_state));
        entry.next_state = @intCast((next_state << @intCast(entry.nb_bits)) - table_size);
        entry.nb_additional_bits = nb_additional_bits[symbol];
        entry.base_value = base_value[symbol];
    }
}

/// `ZSTD_buildSeqTable`: the table of one sequence field, by its mode;
/// returns the bytes of `src` it read.
fn buildSeqTable(
    dtable_space: [*]SeqSymbol,
    dtable_ptr: *[*]const SeqSymbol,
    set_type: zstd_internal.SymbolEncodingType,
    max_in: u32,
    max_log: u32,
    src: []const u8,
    base_value: []const u32,
    nb_additional_bits: []const u8,
    default_table: [*]const SeqSymbol,
    flag_repeat_table: bool,
    ddict_is_cold: bool,
    nb_seq: i32,
    wksp: []u32,
) Error!usize {
    switch (set_type) {
        .rle => {
            if (src.len == 0) return error.SrcSizeWrong;
            if (src[0] > max_in) return error.CorruptionDetected;
            const symbol = src[0];
            buildSeqTableRle(dtable_space, base_value[symbol], nb_additional_bits[symbol]);
            dtable_ptr.* = dtable_space;
            return 1;
        },
        .basic => {
            dtable_ptr.* = default_table;
            return 0;
        },
        .repeat => {
            if (!flag_repeat_table) return error.CorruptionDetected;
            // A cold dictionary's table, about to be used, is prefetched.
            if (ddict_is_cold and nb_seq > 24) {
                const start: [*]const u8 = @ptrCast(dtable_ptr.*);
                const size = @sizeOf(SeqSymbol) * internal.seqSymbolTableSize(max_log);
                var offset: usize = 0;
                while (offset < size) : (offset += 64) @prefetch(start + offset, .{});
            }
            return 0;
        },
        .compressed => {
            var max = max_in;
            var table_log: u32 = undefined;
            var norm: [zstd_internal.max_seq + 1]i16 = undefined;
            const header_size = entropy_common.readNCount(&norm, &max, &table_log, src) catch
                return error.CorruptionDetected;
            if (table_log > max_log) return error.CorruptionDetected;
            buildFSETable(dtable_space, &norm, max, base_value, nb_additional_bits, table_log, wksp);
            dtable_ptr.* = dtable_space;
            return header_size;
        },
    }
}

/// `ZSTD_decodeSeqHeaders`: reads the number of sequences and the three
/// tables; returns the bytes read.
pub fn decodeSeqHeaders(dctx: *DCtx, nb_seq_ptr: *i32, src: []const u8) Error!usize {
    var ip: usize = 0;
    if (src.len < zstd_internal.min_sequences_size) return error.SrcSizeWrong;

    var nb_seq: i32 = src[ip];
    ip += 1;
    if (nb_seq > 0x7F) {
        if (nb_seq == 0xFF) {
            if (ip + 2 > src.len) return error.SrcSizeWrong;
            nb_seq = @as(i32, std.mem.readInt(u16, src[ip..][0..2], .little)) + zstd_internal.long_nb_seq;
            ip += 2;
        } else {
            if (ip >= src.len) return error.SrcSizeWrong;
            nb_seq = ((nb_seq - 0x80) << 8) + src[ip];
            ip += 1;
        }
    }
    nb_seq_ptr.* = nb_seq;

    if (nb_seq == 0) {
        // No sequences: the section ends here.
        if (ip != src.len) return error.CorruptionDetected;
        return ip;
    }

    // The table modes; the low 2 bits are reserved and must be 0.
    if (ip + 1 > src.len) return error.SrcSizeWrong;
    if (src[ip] & 3 != 0) return error.CorruptionDetected;
    const ll_type: zstd_internal.SymbolEncodingType = @fromBackingInt(@as(u2, @truncate(src[ip] >> 6)));
    const of_type: zstd_internal.SymbolEncodingType = @fromBackingInt(@as(u2, @truncate(src[ip] >> 4)));
    const ml_type: zstd_internal.SymbolEncodingType = @fromBackingInt(@as(u2, @truncate(src[ip] >> 2)));
    ip += 1;

    ip += buildSeqTable(
        &dctx.entropy.ll_table,
        &dctx.ll_tptr,
        ll_type,
        internal.max_ll,
        zstd_internal.ll_fse_log,
        src[ip..],
        &internal.ll_base,
        &zstd_internal.ll_bits,
        &ll_default_dtable,
        dctx.fse_entropy,
        dctx.ddict_is_cold,
        nb_seq,
        &dctx.workspace,
    ) catch return error.CorruptionDetected;
    ip += buildSeqTable(
        &dctx.entropy.of_table,
        &dctx.of_tptr,
        of_type,
        internal.max_off,
        zstd_internal.off_fse_log,
        src[ip..],
        &internal.of_base,
        &internal.of_bits,
        &of_default_dtable,
        dctx.fse_entropy,
        dctx.ddict_is_cold,
        nb_seq,
        &dctx.workspace,
    ) catch return error.CorruptionDetected;
    ip += buildSeqTable(
        &dctx.entropy.ml_table,
        &dctx.ml_tptr,
        ml_type,
        internal.max_ml,
        zstd_internal.ml_fse_log,
        src[ip..],
        &internal.ml_base,
        &zstd_internal.ml_bits,
        &ml_default_dtable,
        dctx.fse_entropy,
        dctx.ddict_is_cold,
        nb_seq,
        &dctx.workspace,
    ) catch return error.CorruptionDetected;
    return ip;
}

// --------------------------------------------------------
// Sequences
// --------------------------------------------------------

/// `seq_t`.
pub const Seq = struct {
    lit_length: usize,
    match_length: usize,
    offset: usize,
};

/// `ZSTD_fseState`.
const FseState = struct {
    state: usize,
    table: [*]const SeqSymbol,

    /// `ZSTD_initFseState`.
    fn init(bit_d: *DStream, dt: [*]const SeqSymbol) FseState {
        const header: *const SeqSymbolHeader = @ptrCast(dt);
        const state = bit_d.readBits(header.table_log);
        _ = bit_d.reload();
        return .{ .state = state, .table = dt + 1 };
    }

    /// `ZSTD_updateFseStateWithDInfo`.
    inline fn update(fse_state: *FseState, bit_d: *DStream, next_state: u16, nb_bits: u32) void {
        const low_bits = bit_d.readBits(nb_bits);
        fse_state.state = next_state + low_bits;
    }
};

/// `seqState_t`.
const SeqState = struct {
    d_stream: DStream,
    state_ll: FseState,
    state_offb: FseState,
    state_ml: FseState,
    prev_offset: [zstd_internal.rep_num]usize,
};

/// `LONG_OFFSETS_MAX_EXTRA_BITS_32`: the offset bits a 32-bit reader takes
/// after a reload in the middle of a long offset.
const long_offsets_max_extra_bits_32 = params.window_log_max_32 - 25;
const stream_accumulator_min_32 = 25;
const stream_accumulator_min_64 = 57;

/// `ZSTD_decodeSequence`: one sequence, and the states moved to the next
/// unless it is the last. `long_offsets` is used only on 32-bit targets.
inline fn decodeSequence(seq_state: *SeqState, long_offsets: bool, is_last_seq: bool) Seq {
    const ll_dinfo = seq_state.state_ll.table[seq_state.state_ll.state];
    const ml_dinfo = seq_state.state_ml.table[seq_state.state_ml.state];
    const of_dinfo = seq_state.state_offb.table[seq_state.state_offb.state];
    var seq: Seq = .{
        .match_length = ml_dinfo.base_value,
        .lit_length = ll_dinfo.base_value,
        .offset = undefined,
    };
    const of_base: usize = of_dinfo.base_value;
    const ll_bits = ll_dinfo.nb_additional_bits;
    const ml_bits = ml_dinfo.nb_additional_bits;
    const of_bits = of_dinfo.nb_additional_bits;
    const total_bits = @as(u32, ll_bits) + ml_bits + of_bits;
    const bit_d = &seq_state.d_stream;

    {
        var offset: usize = undefined;
        if (of_bits > 1) {
            if (is_32bit and long_offsets and of_bits >= stream_accumulator_min_32) {
                // Always read the extra bits: simpler, and never 0 bits.
                const extra_bits = long_offsets_max_extra_bits_32;
                offset = of_base + (bit_d.readBitsFast(of_bits - extra_bits) << extra_bits);
                _ = bit_d.reload();
                offset += bit_d.readBitsFast(extra_bits);
            } else {
                offset = of_base + bit_d.readBitsFast(of_bits);
                if (is_32bit) _ = bit_d.reload();
            }
            seq_state.prev_offset[2] = seq_state.prev_offset[1];
            seq_state.prev_offset[1] = seq_state.prev_offset[0];
            seq_state.prev_offset[0] = offset;
        } else {
            const ll0: usize = @intFromBool(ll_dinfo.base_value == 0);
            if (of_bits == 0) {
                offset = seq_state.prev_offset[ll0];
                seq_state.prev_offset[1] = seq_state.prev_offset[1 - ll0];
                seq_state.prev_offset[0] = offset;
            } else {
                offset = of_base + ll0 + bit_d.readBitsFast(1);
                var temp = if (offset == 3) seq_state.prev_offset[0] -% 1 else seq_state.prev_offset[offset];
                // 0 is not valid: corrupt input; -1 makes the sequence fail.
                temp -%= @intFromBool(temp == 0);
                if (offset != 1) seq_state.prev_offset[2] = seq_state.prev_offset[1];
                seq_state.prev_offset[1] = seq_state.prev_offset[0];
                offset = temp;
                seq_state.prev_offset[0] = offset;
            }
        }
        seq.offset = offset;
    }

    if (ml_bits > 0) seq.match_length += bit_d.readBitsFast(ml_bits);
    if (is_32bit and @as(u32, ml_bits) + ll_bits >= stream_accumulator_min_32 - long_offsets_max_extra_bits_32) {
        _ = bit_d.reload();
    }
    if (!is_32bit and total_bits >= stream_accumulator_min_64 - (zstd_internal.ll_fse_log + zstd_internal.ml_fse_log + zstd_internal.off_fse_log)) {
        _ = bit_d.reload();
    }
    if (ll_bits > 0) seq.lit_length += bit_d.readBitsFast(ll_bits);
    if (is_32bit) _ = bit_d.reload();

    if (!is_last_seq) {
        // The last sequence's states are not moved.
        seq_state.state_ll.update(bit_d, ll_dinfo.next_state, ll_dinfo.nb_bits);
        seq_state.state_ml.update(bit_d, ml_dinfo.next_state, ml_dinfo.nb_bits);
        if (is_32bit) _ = bit_d.reload();
        seq_state.state_offb.update(bit_d, of_dinfo.next_state, of_dinfo.nb_bits);
        _ = bit_d.reload();
    }
    return seq;
}

/// `ZSTD_copy4`.
inline fn copy4(dst: [*]u8, src: [*]const u8) void {
    const bytes: [4]u8 = src[0..4].*;
    dst[0..4].* = bytes;
}

/// `ZSTD_copy8`.
inline fn copy8(dst: [*]u8, src: [*]const u8) void {
    const bytes: [8]u8 = src[0..8].*;
    dst[0..8].* = bytes;
}

const copy16 = zstd_internal.copy16;

/// `ZSTD_wildcopy`, for the decoder: copies `length` bytes in 16-byte steps
/// (8-byte steps for close overlaps), so it may read and write up to
/// `wildcopy_overlength` bytes past both ranges. Corrupt input can bring
/// the ranges closer than `overlap` promises; the copy then gives the
/// original's bytes, as it copies in the same steps.
inline fn wildcopy(dst: [*]u8, src: [*]const u8, length: isize, comptime overlap: zstd_internal.Overlap) void {
    const diff = @as(isize, @bitCast(@intFromPtr(dst))) -% @as(isize, @bitCast(@intFromPtr(src)));
    var ip = src;
    var op = dst;
    const oend = @intFromPtr(op) +% @as(usize, @bitCast(length));
    if (overlap == .src_before_dst and diff < wildcopy_veclen) {
        while (true) {
            copy8(op, ip);
            op += 8;
            ip += 8;
            if (@intFromPtr(op) >= oend) break;
        }
    } else {
        copy16(op, ip);
        if (16 >= length) return;
        op += 16;
        ip += 16;
        while (true) {
            copy16(op, ip);
            op += 16;
            ip += 16;
            copy16(op, ip);
            op += 16;
            ip += 16;
            if (@intFromPtr(op) >= oend) break;
        }
    }
}

/// `ZSTD_overlapCopy8`: copies 8 bytes from `ip.*` to `op.*`, `ip.*` at or
/// before `op.*`, and moves both; an offset under 8 is spread so the two
/// end at least 8 apart. `ip` is an address: it steps back past the match
/// on the way.
inline fn overlapCopy8(op: *[*]u8, ip: *usize, offset: usize) void {
    if (offset < 8) {
        const dec32table = [8]u32{ 0, 1, 2, 1, 4, 4, 4, 4 };
        const dec64table = [8]u32{ 8, 8, 8, 7, 8, 9, 10, 11 };
        const sub2 = dec64table[offset];
        const src: [*]const u8 = @ptrFromInt(ip.*);
        op.*[0] = src[0];
        op.*[1] = src[1];
        op.*[2] = src[2];
        op.*[3] = src[3];
        ip.* += dec32table[offset];
        copy4(op.* + 4, @ptrFromInt(ip.*));
        ip.* -%= sub2;
    } else {
        copy8(op.*, @ptrFromInt(ip.*));
    }
    ip.* +%= 8;
    op.* += 8;
}

/// `ZSTD_safecopy`: a copy that may read up to `wildcopy_overlength` past
/// the input and write up to 16 past `oend_w`, for sequences near the end
/// of the output. `ip` is at least 8 bytes from `op`, or before it.
fn safecopy(op_in: [*]u8, oend_w: usize, ip_in: usize, length_in: isize, comptime ovtype: zstd_internal.Overlap) void {
    var op = op_in;
    var ip = ip_in;
    var length = length_in;
    const diff = @intFromPtr(op) -% ip;
    const oend = @intFromPtr(op) +% @as(usize, @bitCast(length));
    if (length < 8) {
        // Short lengths.
        while (@intFromPtr(op) < oend) {
            op[0] = @as(*const u8, @ptrFromInt(ip)).*;
            op += 1;
            ip += 1;
        }
        return;
    }
    if (ovtype == .src_before_dst) {
        // 8 bytes, which spreads an offset under 8 to at least 8.
        overlapCopy8(&op, &ip, diff);
        length -= 8;
    }
    if (oend <= oend_w) {
        // No risk of writing past the end.
        wildcopy(op, @ptrFromInt(ip), length, ovtype);
        return;
    }
    if (@intFromPtr(op) <= oend_w) {
        // Wildcopy until near the end.
        const n = oend_w - @intFromPtr(op);
        wildcopy(op, @ptrFromInt(ip), @intCast(n), ovtype);
        ip += n;
        op += n;
    }
    // The rest.
    while (@intFromPtr(op) < oend) {
        op[0] = @as(*const u8, @ptrFromInt(ip)).*;
        op += 1;
        ip += 1;
    }
}

/// `ZSTD_safecopyDstBeforeSrc`: as `safecopy`, where the output may be
/// before the input and overlap it.
fn safecopyDstBeforeSrc(op_in: [*]u8, ip_in: [*]const u8, length: isize) void {
    var op = op_in;
    var ip = ip_in;
    const diff = @as(isize, @bitCast(@intFromPtr(op))) -% @as(isize, @bitCast(@intFromPtr(ip)));
    const oend = @intFromPtr(op) +% @as(usize, @bitCast(length));
    if (length < 8 or diff > -8) {
        // Short lengths, close overlaps, and output after input.
        while (@intFromPtr(op) < oend) {
            op[0] = ip[0];
            op += 1;
            ip += 1;
        }
        return;
    }
    if (@intFromPtr(op) <= oend -% wildcopy_overlength and diff < -wildcopy_veclen) {
        const n = oend - wildcopy_overlength - @intFromPtr(op);
        wildcopy(op, ip, @intCast(n), .no_overlap);
        ip += n;
        op += n;
    }
    while (@intFromPtr(op) < oend) {
        op[0] = ip[0];
        op += 1;
        ip += 1;
    }
}

/// The window a sequence copies from: the current segment from
/// `prefix_start`, and before it the previous segment, which ends at
/// `dict_end` and would start at `virtual_start` if it came just before.
const Window = struct {
    prefix_start: usize,
    virtual_start: usize,
    dict_end: usize,
};

/// The match part of `execSequence*` once the literals are copied: the
/// part of a match in the previous segment, then the rest. Returns true
/// when the match ended in the previous segment and is fully copied.
inline fn copyMatchFromDict(op: *[*]u8, o_lit_end: [*]u8, sequence: *Seq, match: *usize, w: Window) Error!bool {
    if (sequence.offset > @intFromPtr(o_lit_end) -% w.prefix_start) {
        // The offset reaches into the previous segment.
        if (sequence.offset > @intFromPtr(o_lit_end) -% w.virtual_start) return error.CorruptionDetected;
        match.* = w.dict_end -% (w.prefix_start -% match.*);
        if (match.* +% sequence.match_length <= w.dict_end) {
            const from: [*]const u8 = @ptrFromInt(match.*);
            @memmove(o_lit_end[0..sequence.match_length], from[0..sequence.match_length]);
            return true;
        }
        // The match spans both segments.
        const length1 = w.dict_end - match.*;
        const from: [*]const u8 = @ptrFromInt(match.*);
        @memmove(o_lit_end[0..length1], from[0..length1]);
        op.* = o_lit_end + length1;
        sequence.match_length -= length1;
        match.* = w.prefix_start;
    }
    return false;
}

/// `ZSTD_execSequenceEnd`: a sequence near the end of the output, with
/// every bound checked.
noinline fn execSequenceEnd(
    op_in: [*]u8,
    oend: [*]u8,
    sequence_in: Seq,
    lit_ptr: *[*]const u8,
    lit_limit: [*]const u8,
    w: Window,
) Error!usize {
    var op = op_in;
    var sequence = sequence_in;
    const o_lit_end_addr = @intFromPtr(op) +% sequence.lit_length;
    const sequence_length = sequence.lit_length +% sequence.match_length;
    const oend_w = @intFromPtr(oend) -% wildcopy_overlength;

    if (sequence_length > @intFromPtr(oend) - @intFromPtr(op)) return error.DstSizeTooSmall;
    if (sequence.lit_length > @intFromPtr(lit_limit) -% @intFromPtr(lit_ptr.*)) return error.CorruptionDetected;
    const o_lit_end: [*]u8 = @ptrFromInt(o_lit_end_addr);
    var match = o_lit_end_addr -% sequence.offset;

    // The literals.
    safecopy(op, oend_w, @intFromPtr(lit_ptr.*), @intCast(sequence.lit_length), .no_overlap);
    op = o_lit_end;
    lit_ptr.* += sequence.lit_length;

    // The match.
    if (try copyMatchFromDict(&op, o_lit_end, &sequence, &match, w)) return sequence_length;
    safecopy(op, oend_w, match, @intCast(sequence.match_length), .src_before_dst);
    return sequence_length;
}

/// `ZSTD_execSequenceEndSplitLitBuffer`: `execSequenceEnd` while the
/// literals are still partly in the output, which the output must not
/// overrun.
noinline fn execSequenceEndSplitLitBuffer(
    op_in: [*]u8,
    oend: [*]u8,
    oend_w: usize,
    sequence_in: Seq,
    lit_ptr: *[*]const u8,
    lit_limit: [*]const u8,
    w: Window,
) Error!usize {
    var op = op_in;
    var sequence = sequence_in;
    const o_lit_end_addr = @intFromPtr(op) +% sequence.lit_length;
    const sequence_length = sequence.lit_length +% sequence.match_length;

    if (sequence_length > @intFromPtr(oend) - @intFromPtr(op)) return error.DstSizeTooSmall;
    if (sequence.lit_length > @intFromPtr(lit_limit) -% @intFromPtr(lit_ptr.*)) return error.CorruptionDetected;
    const o_lit_end: [*]u8 = @ptrFromInt(o_lit_end_addr);
    var match = o_lit_end_addr -% sequence.offset;

    // The output must not catch up with the literals and overwrite them.
    if (@intFromPtr(op) > @intFromPtr(lit_ptr.*) and
        @intFromPtr(op) < @intFromPtr(lit_ptr.*) + sequence.lit_length) return error.DstSizeTooSmall;
    safecopyDstBeforeSrc(op, lit_ptr.*, @intCast(sequence.lit_length));
    op = o_lit_end;
    lit_ptr.* += sequence.lit_length;

    if (try copyMatchFromDict(&op, o_lit_end, &sequence, &match, w)) return sequence_length;
    safecopy(op, oend_w, match, @intCast(sequence.match_length), .src_before_dst);
    return sequence_length;
}

/// `ZSTD_execSequence` and, with `split`, `ZSTD_execSequenceSplitLitBuffer`
/// (whose `oend_w` the caller gives): copies a sequence's literals and
/// match to `op`; returns its length.
inline fn execSequenceGeneric(
    comptime split: bool,
    op_in: [*]u8,
    oend: [*]u8,
    oend_w_split: usize,
    sequence_in: Seq,
    lit_ptr: *[*]const u8,
    lit_limit: [*]const u8,
    w: Window,
) Error!usize {
    var op = op_in;
    var sequence = sequence_in;
    const o_lit_end_addr = @intFromPtr(op) +% sequence.lit_length;
    const sequence_length = sequence.lit_length +% sequence.match_length;
    const o_match_end = @intFromPtr(op) +% sequence_length;
    const oend_w = if (split) oend_w_split else @intFromPtr(oend) -% wildcopy_overlength;
    const i_lit_end = @intFromPtr(lit_ptr.*) +% sequence.lit_length;

    // The slow path: literals past their end, a match within
    // `wildcopy_overlength` of the end, or on 32-bit a length that wraps.
    if (i_lit_end > @intFromPtr(lit_limit) or o_match_end > oend_w or
        (is_32bit and @intFromPtr(oend) -% @intFromPtr(op) < sequence_length +% wildcopy_overlength))
    {
        return if (split)
            execSequenceEndSplitLitBuffer(op, oend, oend_w, sequence, lit_ptr, lit_limit, w)
        else
            execSequenceEnd(op, oend, sequence, lit_ptr, lit_limit, w);
    }
    const o_lit_end: [*]u8 = @ptrFromInt(o_lit_end_addr);
    var match = o_lit_end_addr -% sequence.offset;

    // The literals: nearly always 16 or fewer.
    copy16(op, lit_ptr.*);
    if (sequence.lit_length > 16) {
        wildcopy(op + 16, lit_ptr.* + 16, @intCast(sequence.lit_length - 16), .no_overlap);
    }
    op = o_lit_end;
    lit_ptr.* = @ptrFromInt(i_lit_end);

    // The match.
    if (try copyMatchFromDict(&op, o_lit_end, &sequence, &match, w)) return sequence_length;

    // In the current segment, of 1 byte or more. Nearly all offsets are
    // at least `wildcopy_veclen`, so the copy needs no overlap check.
    if (sequence.offset >= wildcopy_veclen) {
        wildcopy(op, @ptrFromInt(match), @intCast(sequence.match_length), .no_overlap);
        return sequence_length;
    }
    // 8 bytes, spreading the offset to at least 8, then the rest.
    overlapCopy8(&op, &match, sequence.offset);
    if (sequence.match_length > 8) {
        wildcopy(op, @ptrFromInt(match), @as(isize, @intCast(sequence.match_length)) - 8, .src_before_dst);
    }
    return sequence_length;
}

inline fn execSequence(op: [*]u8, oend: [*]u8, sequence: Seq, lit_ptr: *[*]const u8, lit_limit: [*]const u8, w: Window) Error!usize {
    return execSequenceGeneric(false, op, oend, 0, sequence, lit_ptr, lit_limit, w);
}

inline fn execSequenceSplitLitBuffer(op: [*]u8, oend: [*]u8, oend_w: usize, sequence: Seq, lit_ptr: *[*]const u8, lit_limit: [*]const u8, w: Window) Error!usize {
    return execSequenceGeneric(true, op, oend, oend_w, sequence, lit_ptr, lit_limit, w);
}

/// The sequence state at the start of a block's sequences.
fn initSeqState(dctx: *DCtx, seq_src: []const u8) Error!SeqState {
    var seq_state: SeqState = undefined;
    dctx.fse_entropy = true;
    for (&seq_state.prev_offset, dctx.entropy.rep) |*prev, rep| prev.* = rep;
    seq_state.d_stream = DStream.init(seq_src) catch return error.CorruptionDetected;
    seq_state.state_ll = .init(&seq_state.d_stream, dctx.ll_tptr);
    seq_state.state_offb = .init(&seq_state.d_stream, dctx.of_tptr);
    seq_state.state_ml = .init(&seq_state.d_stream, dctx.ml_tptr);
    return seq_state;
}

fn saveReps(dctx: *DCtx, seq_state: *const SeqState) void {
    for (&dctx.entropy.rep, seq_state.prev_offset) |*rep, prev| rep.* = @truncate(prev);
}

fn windowOf(dctx: *const DCtx) Window {
    return .{
        .prefix_start = dctx.prefix_start,
        .virtual_start = dctx.virtual_start,
        .dict_end = dctx.dict_end,
    };
}

/// `ZSTD_decompressSequences_bodySplitLitBuffer`: the sequences of a block
/// whose literals are split between the end of its output and the
/// context's extra buffer.
fn decompressSequencesSplitLitBuffer(dctx: *DCtx, dst: []u8, seq_src: []const u8, nb_seq_in: i32, is_long_offset: bool) Error!usize {
    var nb_seq = nb_seq_in;
    const ostart = dst.ptr;
    const oend = dst.ptr + dst.len;
    var op = ostart;
    var lit_ptr = dctx.lit_ptr;
    var lit_buffer_end = dctx.lit_buffer_end;
    const w = windowOf(dctx);

    if (nb_seq != 0) {
        var seq_state = try initSeqState(dctx, seq_src);
        var sequence: Seq = .{ .lit_length = 0, .match_length = 0, .offset = 0 };

        // While the literals are split between `dst` and the extra buffer.
        while (nb_seq != 0) : (nb_seq -= 1) {
            sequence = decodeSequence(&seq_state, is_long_offset, nb_seq == 1);
            if (@intFromPtr(lit_ptr) +% sequence.lit_length > @intFromPtr(dctx.lit_buffer_end)) break;
            const one_seq_size = try execSequenceSplitLitBuffer(
                op,
                oend,
                @intFromPtr(lit_ptr) +% sequence.lit_length -% wildcopy_overlength,
                sequence,
                &lit_ptr,
                lit_buffer_end,
                w,
            );
            op += one_seq_size;
        }

        // The next sequences read their literals from the extra buffer:
        // copy the rest of the ones in `dst`, then switch.
        if (nb_seq > 0) {
            const leftover_lit = @intFromPtr(dctx.lit_buffer_end) - @intFromPtr(lit_ptr);
            if (leftover_lit != 0) {
                if (leftover_lit > @intFromPtr(oend) - @intFromPtr(op)) return error.DstSizeTooSmall;
                safecopyDstBeforeSrc(op, lit_ptr, @intCast(leftover_lit));
                sequence.lit_length -= leftover_lit;
                op += leftover_lit;
            }
            lit_ptr = &dctx.lit_extra_buffer;
            lit_buffer_end = lit_ptr + lit_buffer_extra_size;
            dctx.lit_buffer_location = .not_in_dst;
            const one_seq_size = try execSequence(op, oend, sequence, &lit_ptr, lit_buffer_end, w);
            op += one_seq_size;
            nb_seq -= 1;
        }

        // The literals left are all in the extra buffer.
        while (nb_seq > 0) : (nb_seq -= 1) {
            const seq = decodeSequence(&seq_state, is_long_offset, nb_seq == 1);
            const one_seq_size = try execSequence(op, oend, seq, &lit_ptr, lit_buffer_end, w);
            op += one_seq_size;
        }

        if (nb_seq != 0) return error.CorruptionDetected;
        if (!seq_state.d_stream.endOfStream()) return error.CorruptionDetected;
        saveReps(dctx, &seq_state);
    }

    // The last literals.
    if (dctx.lit_buffer_location == .split) {
        // The split is not reached: first the literals in `dst`.
        const last_ll_size = @intFromPtr(lit_buffer_end) - @intFromPtr(lit_ptr);
        if (last_ll_size > @intFromPtr(oend) - @intFromPtr(op)) return error.DstSizeTooSmall;
        @memmove(op[0..last_ll_size], lit_ptr[0..last_ll_size]);
        op += last_ll_size;
        lit_ptr = &dctx.lit_extra_buffer;
        lit_buffer_end = lit_ptr + lit_buffer_extra_size;
        dctx.lit_buffer_location = .not_in_dst;
    }
    const last_ll_size = @intFromPtr(lit_buffer_end) - @intFromPtr(lit_ptr);
    if (last_ll_size > @intFromPtr(oend) - @intFromPtr(op)) return error.DstSizeTooSmall;
    @memmove(op[0..last_ll_size], lit_ptr[0..last_ll_size]);
    op += last_ll_size;
    return @intFromPtr(op) - @intFromPtr(ostart);
}

/// `ZSTD_decompressSequences_body`: the sequences of a block whose
/// literals are in one place.
fn decompressSequences(dctx: *DCtx, dst: []u8, seq_src: []const u8, nb_seq_in: i32, is_long_offset: bool) Error!usize {
    var nb_seq = nb_seq_in;
    const ostart = dst.ptr;
    const oend: [*]u8 = if (dctx.lit_buffer_location == .not_in_dst) dst.ptr + dst.len else dctx.lit_buffer;
    var op = ostart;
    var lit_ptr = dctx.lit_ptr;
    const lit_end = lit_ptr + dctx.lit_size;
    const w = windowOf(dctx);

    if (nb_seq != 0) {
        var seq_state = try initSeqState(dctx, seq_src);
        while (nb_seq != 0) : (nb_seq -= 1) {
            const sequence = decodeSequence(&seq_state, is_long_offset, nb_seq == 1);
            const one_seq_size = try execSequence(op, oend, sequence, &lit_ptr, lit_end, w);
            op += one_seq_size;
        }
        if (!seq_state.d_stream.endOfStream()) return error.CorruptionDetected;
        saveReps(dctx, &seq_state);
    }

    // The last literals.
    const last_ll_size = @intFromPtr(lit_end) - @intFromPtr(lit_ptr);
    if (last_ll_size > @intFromPtr(oend) - @intFromPtr(op)) return error.DstSizeTooSmall;
    @memmove(op[0..last_ll_size], lit_ptr[0..last_ll_size]);
    op += last_ll_size;
    return @intFromPtr(op) - @intFromPtr(ostart);
}

/// `ZSTD_prefetchMatch`: prefetches the match of `sequence`, whose
/// literals start `prefetch_pos` bytes after the segment's start; returns
/// the position after it. The address may be anywhere on corrupt input:
/// it is only prefetched, never read.
inline fn prefetchMatch(prefetch_pos_in: usize, sequence: Seq, prefix_start: usize, dict_end: usize) usize {
    const prefetch_pos = prefetch_pos_in +% sequence.lit_length;
    const match_base = if (sequence.offset > prefetch_pos) dict_end else prefix_start;
    const match = match_base +% prefetch_pos -% sequence.offset;
    if (match != 0 and match < std.math.maxInt(usize) - 64) {
        @prefetch(@as([*]const u8, @ptrFromInt(match)), .{});
        @prefetch(@as([*]const u8, @ptrFromInt(match + 64)), .{});
    }
    return prefetch_pos +% sequence.match_length;
}

const stored_seqs = 8;
const stored_seqs_mask = stored_seqs - 1;
const advanced_seqs = stored_seqs;

/// One sequence of `decompressSequencesLong`: switches the literals to the
/// extra buffer when they reach the split, then runs it.
inline fn execLongSequence(
    dctx: *DCtx,
    op: *[*]u8,
    oend: [*]u8,
    sequence: *Seq,
    lit_ptr: *[*]const u8,
    lit_buffer_end: *[*]const u8,
    w: Window,
) Error!void {
    if (dctx.lit_buffer_location == .split and
        @intFromPtr(lit_ptr.*) +% sequence.lit_length > @intFromPtr(dctx.lit_buffer_end))
    {
        // The literals reach the split: empty the part in `dst`, and go on
        // in the extra buffer.
        const leftover_lit = @intFromPtr(dctx.lit_buffer_end) - @intFromPtr(lit_ptr.*);
        if (leftover_lit != 0) {
            if (leftover_lit > @intFromPtr(oend) - @intFromPtr(op.*)) return error.DstSizeTooSmall;
            safecopyDstBeforeSrc(op.*, lit_ptr.*, @intCast(leftover_lit));
            sequence.lit_length -= leftover_lit;
            op.* += leftover_lit;
        }
        lit_ptr.* = &dctx.lit_extra_buffer;
        lit_buffer_end.* = lit_ptr.* + lit_buffer_extra_size;
        dctx.lit_buffer_location = .not_in_dst;
        op.* += try execSequence(op.*, oend, sequence.*, lit_ptr, lit_buffer_end.*, w);
    } else {
        // The literals are all on one side of the split, or not split.
        op.* += if (dctx.lit_buffer_location == .split)
            try execSequenceSplitLitBuffer(
                op.*,
                oend,
                @intFromPtr(lit_ptr.*) +% sequence.lit_length -% wildcopy_overlength,
                sequence.*,
                lit_ptr,
                lit_buffer_end.*,
                w,
            )
        else
            try execSequence(op.*, oend, sequence.*, lit_ptr, lit_buffer_end.*, w);
    }
}

/// `ZSTD_decompressSequencesLong_body`: decodes sequences 8 ahead of the
/// ones it runs and prefetches their matches, for blocks with many long
/// offsets or a dictionary out of cache.
fn decompressSequencesLong(dctx: *DCtx, dst: []u8, seq_src: []const u8, nb_seq: i32, is_long_offset: bool) Error!usize {
    const ostart = dst.ptr;
    const oend: [*]u8 = if (dctx.lit_buffer_location == .in_dst) dctx.lit_buffer else dst.ptr + dst.len;
    var op = ostart;
    var lit_ptr = dctx.lit_ptr;
    var lit_buffer_end = dctx.lit_buffer_end;
    const w = windowOf(dctx);

    if (nb_seq != 0) {
        var sequences: [stored_seqs]Seq = undefined;
        const seq_advance: i32 = @min(nb_seq, advanced_seqs);
        var prefetch_pos: usize = @intFromPtr(op) -% w.prefix_start;
        var seq_state = try initSeqState(dctx, seq_src);

        // Decode ahead.
        var seq_nb: i32 = 0;
        while (seq_nb < seq_advance) : (seq_nb += 1) {
            const sequence = decodeSequence(&seq_state, is_long_offset, seq_nb == nb_seq - 1);
            prefetch_pos = prefetchMatch(prefetch_pos, sequence, w.prefix_start, w.dict_end);
            sequences[@intCast(seq_nb)] = sequence;
        }

        // Run each sequence once the one 8 ahead of it is decoded.
        while (seq_nb < nb_seq) : (seq_nb += 1) {
            const sequence = decodeSequence(&seq_state, is_long_offset, seq_nb == nb_seq - 1);
            const ahead: usize = @intCast((seq_nb - advanced_seqs) & stored_seqs_mask);
            try execLongSequence(dctx, &op, oend, &sequences[ahead], &lit_ptr, &lit_buffer_end, w);
            prefetch_pos = prefetchMatch(prefetch_pos, sequence, w.prefix_start, w.dict_end);
            sequences[@intCast(seq_nb & stored_seqs_mask)] = sequence;
        }
        if (!seq_state.d_stream.endOfStream()) return error.CorruptionDetected;

        // Run the queue.
        seq_nb -= seq_advance;
        while (seq_nb < nb_seq) : (seq_nb += 1) {
            const sequence = &sequences[@intCast(seq_nb & stored_seqs_mask)];
            try execLongSequence(dctx, &op, oend, sequence, &lit_ptr, &lit_buffer_end, w);
        }
        saveReps(dctx, &seq_state);
    }

    // The last literals.
    if (dctx.lit_buffer_location == .split) {
        // First the literals in `dst`, then the extra buffer.
        const last_ll_size = @intFromPtr(lit_buffer_end) - @intFromPtr(lit_ptr);
        if (last_ll_size > @intFromPtr(oend) - @intFromPtr(op)) return error.DstSizeTooSmall;
        @memmove(op[0..last_ll_size], lit_ptr[0..last_ll_size]);
        op += last_ll_size;
        lit_ptr = &dctx.lit_extra_buffer;
        lit_buffer_end = lit_ptr + lit_buffer_extra_size;
    }
    const last_ll_size = @intFromPtr(lit_buffer_end) - @intFromPtr(lit_ptr);
    if (last_ll_size > @intFromPtr(oend) - @intFromPtr(op)) return error.DstSizeTooSmall;
    @memmove(op[0..last_ll_size], lit_ptr[0..last_ll_size]);
    op += last_ll_size;
    return @intFromPtr(op) - @intFromPtr(ostart);
}

/// `ZSTD_OffsetInfo`.
const OffsetInfo = struct {
    long_offset_share: u32 = 0,
    max_nb_additional_bits: u32 = 0,
};

/// `ZSTD_getOffsetInfo`: the share of long offsets (over 2^23) in the
/// offset table, out of `1 << off_fse_log`, and the most extra bits.
fn getOffsetInfo(off_table: [*]const SeqSymbol, nb_seq: i32) OffsetInfo {
    var info: OffsetInfo = .{};
    // With no sequences the table may not be set, and both are 0.
    if (nb_seq != 0) {
        const table_log = @as(*const SeqSymbolHeader, @ptrCast(off_table)).table_log;
        const table = off_table + 1;
        const max = @as(u32, 1) << @intCast(table_log);
        assert(max <= 1 << zstd_internal.off_fse_log);
        for (table[0..max]) |entry| {
            info.max_nb_additional_bits = @max(info.max_nb_additional_bits, entry.nb_additional_bits);
            if (entry.nb_additional_bits > 22) info.long_offset_share += 1;
        }
        info.long_offset_share <<= @intCast(zstd_internal.off_fse_log - table_log);
    }
    return info;
}

/// `ZSTD_maxShortOffset`: the largest offset read without a reload in the
/// middle of its bits.
fn maxShortOffset() usize {
    if (!is_32bit) return std.math.maxInt(usize);
    const max_offbase = (@as(usize, 1) << (stream_accumulator_min_32 + 1)) - 1;
    return max_offbase - zstd_internal.rep_num;
}

/// `ZSTD_decompressBlock_internal`: decodes a compressed block into `dst`;
/// returns its size.
pub fn decompressBlockInternal(dctx: *DCtx, dst: []u8, src_in: []const u8, streaming: internal.StreamingOperation) Error!usize {
    // A compressed block may be exactly the largest block size.
    if (src_in.len > blockSizeMax(dctx)) return error.SrcSizeWrong;

    const lit_csize = try decodeLiteralsBlock(dctx, src_in, dst, streaming);
    var src = src_in[lit_csize..];

    // The largest block, which must work outside frames too, and no more
    // than `dst`, so the history size fits a usize.
    const block_size_max = @min(dst.len, blockSizeMax(dctx));
    const total_history_size = (@intFromPtr(dst.ptr) +% block_size_max) -% dctx.virtual_start;
    // On 32-bit targets, offsets can be too long to read in one go once the
    // history is long enough; later the table says whether any can be.
    var is_long_offset = is_32bit and total_history_size > maxShortOffset();
    var use_prefetch_decoder = dctx.ddict_is_cold;

    var nb_seq: i32 = undefined;
    const seq_h_size = try decodeSeqHeaders(dctx, &nb_seq, src);
    src = src[seq_h_size..];
    if (dst.len == 0 and nb_seq > 0) return error.DstSizeTooSmall;
    // An output near the top of the address space is refused. An empty
    // output is the original's NULL, which passes: an allocator's empty
    // slice has the address maxInt(usize).
    if (!is_32bit and dst.len != 0 and std.math.maxInt(usize) - @intFromPtr(dst.ptr) < 1 << 20) {
        return error.DstSizeTooSmall;
    }

    // With possible long offsets, or a block that may gain from
    // prefetching, look at the offset table.
    if (is_long_offset or (!use_prefetch_decoder and total_history_size > 1 << 24 and nb_seq > 8)) {
        const info = getOffsetInfo(dctx.of_tptr, nb_seq);
        if (is_long_offset and info.max_nb_additional_bits <= stream_accumulator_min_32) {
            // No offset in this table is too long.
            is_long_offset = false;
        }
        if (!use_prefetch_decoder) {
            // 2.73% on 64-bit targets, 7.81% on 32-bit ones.
            const min_share: u32 = if (is_32bit) 20 else 7;
            use_prefetch_decoder = info.long_offset_share >= min_share;
        }
    }

    dctx.ddict_is_cold = false;

    if (use_prefetch_decoder) return decompressSequencesLong(dctx, dst, src, nb_seq, is_long_offset);
    if (dctx.lit_buffer_location == .split) return decompressSequencesSplitLitBuffer(dctx, dst, src, nb_seq, is_long_offset);
    return decompressSequences(dctx, dst, src, nb_seq, is_long_offset);
}

/// `ZSTD_checkContinuity`: when `dst` does not follow the last output, the
/// last segment becomes the previous one and `dst` starts a new one.
pub fn checkContinuity(dctx: *DCtx, dst: [*]const u8, dst_size: usize) void {
    if (@intFromPtr(dst) != dctx.previous_dst_end and dst_size > 0) {
        dctx.dict_end = dctx.previous_dst_end;
        dctx.virtual_start = @intFromPtr(dst) -% (dctx.previous_dst_end -% dctx.prefix_start);
        dctx.prefix_start = @intFromPtr(dst);
        dctx.previous_dst_end = @intFromPtr(dst);
    }
}

/// `ZSTD_decompressBlock`: decodes one compressed block, outside a frame,
/// after `decompressBegin*`; returns its size. Earlier blocks' outputs are
/// its window, and must stay where they are.
pub fn decompressBlock(dctx: *DCtx, dst: []u8, src: []const u8) Error!usize {
    dctx.is_frame_decompression = false;
    checkContinuity(dctx, dst.ptr, dst.len);
    const d_size = try decompressBlockInternal(dctx, dst, src, .not_streaming);
    dctx.previous_dst_end = @intFromPtr(dst.ptr) + d_size;
    return d_size;
}

test {
    std.testing.refAllDecls(@This());
}
