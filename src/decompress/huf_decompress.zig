//! The Huffman decoder, from the original's huf_decompress.c: the table
//! readers for single-symbol (X1) and double-symbol (X2) tables, the 1- and
//! 4-stream decoders, and the fast 4-stream loops. The original has an
//! x86-64 assembly version of the fast loops (huf_decompress_amd64.S); the
//! port translates its C loops, which decode the same bits to the same
//! bytes.
//!
//! A `DTable` is the original's `HUF_DTable` array: a `DTableDesc` in its
//! first u32, then the entries. All the decoders read untrusted bytes and
//! give the original's result on any input, an error or the output.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Error = @import("../error.zig").Error;
const huf = @import("../common/huf.zig");
const bitstream = @import("../common/bitstream.zig");
const entropy_common = @import("../common/entropy_common.zig");
const zstd_internal = @import("../common/zstd_internal.zig");
const DStream = bitstream.DStream;
const highbit32 = bitstream.highbit32;

/// `HUF_DECODER_FAST_TABLELOG`: the table log the fast loops decode with.
pub const decoder_fast_table_log = 11;

/// `HUF_DTable`.
pub const DTable = u32;

/// `HUF_DTABLE_SIZE`: the u32s of a table of `max_table_log`.
pub fn dtableSize(max_table_log: u32) usize {
    return 1 + (@as(usize, 1) << @intCast(max_table_log));
}

/// `HUF_DECOMPRESS_WORKSPACE_SIZE`, in bytes and in u32s.
pub const decompress_workspace_size = (2 << 10) + (1 << 9);
pub const decompress_workspace_size_u32 = decompress_workspace_size / @sizeOf(u32);

/// `DTableDesc`: the header in a table's first u32.
pub const DTableDesc = packed struct(u32) {
    max_table_log: u8,
    table_type: u8,
    table_log: u8,
    reserved: u8,
};

fn getDTableDesc(table: [*]const DTable) DTableDesc {
    return @bitCast(table[0]);
}

fn setDTableDesc(table: [*]DTable, dtd: DTableDesc) void {
    table[0] = @bitCast(dtd);
}

const is_64bit = @sizeOf(usize) == 8;

/// The four decodes the safe decoders make between reloads, as the
/// original's `HUF_DECODE_SYMBOLX{1,2}_2`, `_1`, `_2`, `_0`: true for those
/// made on 64-bit targets only (`_2`). `_1` decodes on every target, as the
/// largest table log is 12.
const symbols_between_reloads = [4]bool{ true, false, true, false };

/// The fast loops need 64-bit little-endian words.
const fast_loop_supported = @sizeOf(usize) == 8 and builtin.cpu.arch.endian() == .little;

/// `value` unchanged, held in a general register. The fast loops keep the
/// four streams' containers apart with it: LLVM's SLP vectorizer otherwise
/// packs them into one vector register and pays an extract and an insert
/// for every symbol's table lookup, a third slower on x86-64.
inline fn inRegister(value: u64) u64 {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return value;
    return asm (""
        : [out] "=r" (-> u64),
        : [in] "0" (value),
    );
}

/// `HUF_initFastDStream`: the fast loops' bit container, read from the MSB
/// down, with a 1 set below the lowest valid bit.
inline fn initFastDStream(ip: [*]const u8) u64 {
    const last_byte = ip[7];
    const bits_consumed: u6 = if (last_byte != 0) @intCast(8 - highbit32(last_byte)) else 0;
    const value = std.mem.readInt(u64, ip[0..8], .little) | 1;
    return value << bits_consumed;
}

/// `HUF_DecompressFastArgs`: the state of the fast loops. `ip[i]` is where
/// stream `i`'s container was last read, `op[i]` its output, `iend[i]` its
/// end; the loops may read down to `ilowest`.
const FastArgs = struct {
    ip: [4][*]const u8,
    op: [4][*]u8,
    bits: [4]u64,
    dt: [*]const DTable,
    ilowest: [*]const u8,
    oend: [*]u8,
    iend: [4][*]const u8,
};

/// `HUF_DecompressFastArgs_init`: true when the fast loop can run, false
/// when the fallback decoder must.
fn initFastArgs(args: *FastArgs, dst: []u8, src: []const u8, dtable: [*]const DTable) Error!bool {
    const dt_log = getDTableDesc(dtable).table_log;
    if (!fast_loop_supported) return false;
    if (dst.len == 0) return false;
    // The jump table and one byte per stream.
    if (src.len < 10) return error.CorruptionDetected;
    if (dt_log != decoder_fast_table_log) return false;

    const istart = src.ptr;
    const length1: usize = std.mem.readInt(u16, istart[0..2], .little);
    const length2: usize = std.mem.readInt(u16, istart[2..4], .little);
    const length3: usize = std.mem.readInt(u16, istart[4..6], .little);
    const length4 = src.len -% (length1 + length2 + length3 + 6);
    args.iend[0] = istart + 6;
    args.iend[1] = args.iend[0] + length1;
    args.iend[2] = args.iend[1] + length2;
    args.iend[3] = args.iend[2] + length3;
    // `initFastDStream` reads 8 bytes, and inputs this small do not gain.
    if (length1 < 8 or length2 < 8 or length3 < 8 or length4 < 8) return false;
    if (length4 > src.len) return error.CorruptionDetected;

    args.ip[0] = args.iend[1] - 8;
    args.ip[1] = args.iend[2] - 8;
    args.ip[2] = args.iend[3] - 8;
    args.ip[3] = src.ptr + src.len - 8;

    const segment = (dst.len + 3) / 4;
    args.op[0] = dst.ptr;
    // Past the output for tiny outputs: compared, never written.
    const op3 = 3 * segment;
    if (op3 >= dst.len) return false;
    args.op[1] = dst.ptr + segment;
    args.op[2] = dst.ptr + 2 * segment;
    args.op[3] = dst.ptr + op3;

    for (0..4) |i| args.bits[i] = initFastDStream(args.ip[i]);
    args.ilowest = istart;
    args.oend = dst.ptr + dst.len;
    args.dt = dtable + 1;
    return true;
}

/// `HUF_initRemainingDStream`: the bit stream that finishes stream
/// `stream` after the fast loop.
fn initRemainingDStream(bit: *DStream, args: *const FastArgs, stream: usize, segment_end: [*]u8) Error!void {
    if (@intFromPtr(args.op[stream]) > @intFromPtr(segment_end)) return error.CorruptionDetected;
    // `ip` may be up to 8 below the stream's end: the next bit to read is
    // the container's MSB, and the stream may be read whole.
    if (@intFromPtr(args.ip[stream]) + 8 < @intFromPtr(args.iend[stream])) return error.CorruptionDetected;
    bit.bit_container = bitstream.readContainer(args.ip[stream]);
    bit.bits_consumed = @ctz(args.bits[stream]);
    bit.start = args.ilowest;
    bit.limit_ptr = bit.start + @sizeOf(usize);
    bit.ptr = args.ip[stream];
}

// --------------------------------------------------------
// Single-symbol decoding
// --------------------------------------------------------

/// `HUF_DEltX1`.
const DEltX1 = extern struct {
    nb_bits: u8,
    byte: u8,
};

/// `HUF_DEltX1_set4`: four entries in a u64.
fn deltX1Set4(symbol: u8, nb_bits: u8) u64 {
    const d4: u64 = (@as(u64, symbol) << 8) + nb_bits;
    return d4 *% 0x0001000100010001;
}

/// `HUF_rescaleStats`: raises the table log to `target_table_log`, scaling
/// the weights. Returns the new table log.
fn rescaleStats(huff_weight: []u8, rank_val: []u32, nb_symbols: u32, table_log: u32, target_table_log: u32) u32 {
    if (table_log > target_table_log) return table_log;
    if (table_log < target_table_log) {
        const scale = target_table_log - table_log;
        for (huff_weight[0..nb_symbols]) |*w| {
            if (w.* != 0) w.* += @intCast(scale);
        }
        var s = target_table_log;
        while (s > scale) : (s -= 1) rank_val[s] = rank_val[s - scale];
        s = scale;
        while (s > 0) : (s -= 1) rank_val[s] = 0;
    }
    return target_table_log;
}

/// `HUF_ReadDTableX1_Workspace`.
const ReadDTableX1Workspace = extern struct {
    rank_val: [huf.table_log_absolute_max + 1]u32,
    rank_start: [huf.table_log_absolute_max + 1]u32,
    stats_wksp: [huf.read_stats_workspace_size_u32]u32,
    symbols: [huf.symbol_value_max + 1]u8,
    huff_weight: [huf.symbol_value_max + 1]u8,
};

/// `HUF_readDTableX1_wksp`: reads a Huffman table header into a
/// single-symbol table; returns the header's size.
pub fn readDTableX1Wksp(dtable: [*]DTable, src: []const u8, workspace: []u32) Error!usize {
    if (@sizeOf(ReadDTableX1Workspace) > workspace.len * 4) return error.TableLogTooLarge;
    const wksp: *ReadDTableX1Workspace = @ptrCast(workspace.ptr);
    const dt: [*]DEltX1 = @ptrCast(dtable + 1);
    var table_log: u32 = 0;
    var nb_symbols: u32 = 0;
    const i_size = try entropy_common.readStatsWksp(
        &wksp.huff_weight,
        &wksp.rank_val,
        &nb_symbols,
        &table_log,
        src,
        std.mem.asBytes(&wksp.stats_wksp),
    );

    {
        var dtd = getDTableDesc(dtable);
        const max_table_log: u32 = @as(u32, dtd.max_table_log) + 1;
        const target_table_log = @min(max_table_log, decoder_fast_table_log);
        table_log = rescaleStats(&wksp.huff_weight, &wksp.rank_val, nb_symbols, table_log, target_table_log);
        if (table_log > @as(u32, dtd.max_table_log) + 1) return error.TableLogTooLarge;
        dtd.table_type = 0;
        dtd.table_log = @intCast(table_log);
        setDTableDesc(dtable, dtd);
    }

    // The symbols ordered by weight, and where each weight starts.
    {
        var next_rank_start: u32 = 0;
        for (0..table_log + 1) |n| {
            const curr = next_rank_start;
            next_rank_start += wksp.rank_val[n];
            wksp.rank_start[n] = curr;
        }
        for (0..nb_symbols) |n| {
            const w = wksp.huff_weight[n];
            wksp.symbols[wksp.rank_start[w]] = @intCast(n);
            wksp.rank_start[w] += 1;
        }
    }

    // Fill the table weight by weight, so a weight's run length is fixed.
    {
        var symbol: usize = wksp.rank_val[0];
        var rank_start: usize = 0;
        var w: u32 = 1;
        while (w < table_log + 1) : (w += 1) {
            const symbol_count: usize = wksp.rank_val[w];
            const length: usize = (@as(usize, 1) << @intCast(w)) >> 1;
            var u_start = rank_start;
            const nb_bits: u8 = @intCast(table_log + 1 - w);
            for (wksp.symbols[symbol..][0..symbol_count]) |sym| {
                if (length < 4) {
                    const d: DEltX1 = .{ .byte = sym, .nb_bits = nb_bits };
                    @memset(dt[u_start..][0..length], d);
                } else {
                    const d4 = deltX1Set4(sym, nb_bits);
                    const words: [*]align(1) u64 = @ptrCast(dt + u_start);
                    @memset(words[0 .. length / 4], d4);
                }
                u_start += length;
            }
            symbol += symbol_count;
            rank_start += symbol_count * length;
        }
    }
    return i_size;
}

/// `HUF_decodeSymbolX1`.
inline fn decodeSymbolX1(d: *DStream, dt: [*]const DEltX1, dt_log: u32) u8 {
    const val = d.lookBitsFast(dt_log);
    const entry = dt[val];
    d.skipBits(entry.nb_bits);
    return entry.byte;
}

/// `HUF_decodeStreamX1`: decodes into `p[0..p_end - p]`.
inline fn decodeStreamX1(p_start: [*]u8, bit_d: *DStream, p_end: [*]u8, dt: [*]const DEltX1, dt_log: u32) usize {
    var p = p_start;
    const left = @intFromPtr(p_end) - @intFromPtr(p);
    if (left > 3) {
        // Up to 4 symbols at a time; 2 on 32-bit targets.
        while ((bit_d.reload() == .unfinished) and @intFromPtr(p) < @intFromPtr(p_end) - 3) {
            inline for (symbols_between_reloads) |wide| {
                if (!wide or is_64bit) {
                    p[0] = decodeSymbolX1(bit_d, dt, dt_log);
                    p += 1;
                }
            }
        }
    } else {
        _ = bit_d.reload();
    }
    if (@sizeOf(usize) == 4) {
        while ((bit_d.reload() == .unfinished) and @intFromPtr(p) < @intFromPtr(p_end)) {
            p[0] = decodeSymbolX1(bit_d, dt, dt_log);
            p += 1;
        }
    }
    // No more data to retrieve from the stream; no reload needed.
    while (@intFromPtr(p) < @intFromPtr(p_end)) {
        p[0] = decodeSymbolX1(bit_d, dt, dt_log);
        p += 1;
    }
    return @intFromPtr(p_end) - @intFromPtr(p_start);
}

/// `HUF_decompress1X1_usingDTable_internal`.
fn decompress1X1UsingDTableInternal(dst: []u8, c_src: []const u8, dtable: [*]const DTable) Error!usize {
    const dt: [*]const DEltX1 = @ptrCast(dtable + 1);
    const dt_log = getDTableDesc(dtable).table_log;
    var bit_d = try DStream.init(c_src);
    _ = decodeStreamX1(dst.ptr, &bit_d, dst.ptr + dst.len, dt, dt_log);
    if (!bit_d.endOfStream()) return error.CorruptionDetected;
    return dst.len;
}

/// The four streams of a 4-stream block: the jump table read, each
/// stream's bits started.
const FourStreams = struct {
    bit_d: [4]DStream,
    segment_size: usize,
};

fn initFourStreams(dst_len: usize, c_src: []const u8) Error!FourStreams {
    if (c_src.len < 10) return error.CorruptionDetected;
    if (dst_len < 6) return error.CorruptionDetected;
    const istart = c_src.ptr;
    const length1: usize = std.mem.readInt(u16, istart[0..2], .little);
    const length2: usize = std.mem.readInt(u16, istart[2..4], .little);
    const length3: usize = std.mem.readInt(u16, istart[4..6], .little);
    const length4 = c_src.len -% (length1 + length2 + length3 + 6);
    const segment_size = (dst_len + 3) / 4;
    if (length4 > c_src.len) return error.CorruptionDetected;
    if (3 * segment_size > dst_len) return error.CorruptionDetected;
    const start1 = 6;
    const start2 = start1 + length1;
    const start3 = start2 + length2;
    const start4 = start3 + length3;
    return .{
        .bit_d = .{
            try DStream.init(c_src[start1..][0..length1]),
            try DStream.init(c_src[start2..][0..length2]),
            try DStream.init(c_src[start3..][0..length3]),
            try DStream.init(c_src[start4..][0..length4]),
        },
        .segment_size = segment_size,
    };
}

/// `HUF_decompress4X1_usingDTable_internal_body`: `dst` holds at least 6.
fn decompress4X1UsingDTableBody(dst: []u8, c_src: []const u8, dtable: [*]const DTable) Error!usize {
    var streams = try initFourStreams(dst.len, c_src);
    const bit_d = &streams.bit_d;
    const ostart = dst.ptr;
    const oend = ostart + dst.len;
    const olimit = @intFromPtr(oend) - 3;
    const dt: [*]const DEltX1 = @ptrCast(dtable + 1);
    const dt_log = getDTableDesc(dtable).table_log;
    const op_start = [4][*]u8{
        ostart,
        ostart + streams.segment_size,
        ostart + 2 * streams.segment_size,
        ostart + 3 * streams.segment_size,
    };
    var op = op_start;

    // Up to 16 symbols a loop, 4 a stream; 2 a stream on 32-bit targets,
    // whose container holds fewer bits (the original's
    // `HUF_DECODE_SYMBOLX1_2` decodes on 64-bit targets only).
    if (@intFromPtr(oend) - @intFromPtr(op[3]) >= @sizeOf(usize)) {
        var end_signal = true;
        while (end_signal and @intFromPtr(op[3]) < olimit) {
            inline for (symbols_between_reloads) |wide| {
                if (!wide or is_64bit) {
                    inline for (0..4) |s| {
                        op[s][0] = decodeSymbolX1(&bit_d[s], dt, dt_log);
                        op[s] += 1;
                    }
                }
            }
            // Every stream reloads, as the original's `&=` does.
            inline for (0..4) |s| end_signal = (bit_d[s].reloadFast() == .unfinished) and end_signal;
        }
    }

    if (@intFromPtr(op[0]) > @intFromPtr(op_start[1])) return error.CorruptionDetected;
    if (@intFromPtr(op[1]) > @intFromPtr(op_start[2])) return error.CorruptionDetected;
    if (@intFromPtr(op[2]) > @intFromPtr(op_start[3])) return error.CorruptionDetected;

    // Finish the streams one by one.
    _ = decodeStreamX1(op[0], &bit_d[0], op_start[1], dt, dt_log);
    _ = decodeStreamX1(op[1], &bit_d[1], op_start[2], dt, dt_log);
    _ = decodeStreamX1(op[2], &bit_d[2], op_start[3], dt, dt_log);
    _ = decodeStreamX1(op[3], &bit_d[3], oend, dt, dt_log);

    const end_check = bit_d[0].endOfStream() and bit_d[1].endOfStream() and
        bit_d[2].endOfStream() and bit_d[3].endOfStream();
    if (!end_check) return error.CorruptionDetected;
    return dst.len;
}

/// `HUF_decompress4X1_usingDTable_internal_fast_c_loop`: decodes 5 symbols
/// from each stream between bounds checks, until a stream nears its end.
fn decompress4X1FastLoop(args: *FastArgs) void {
    var bits = args.bits;
    var ip = args.ip;
    var op = args.op;
    const dtable: [*]const u16 = @ptrCast(args.dt);
    const oend = args.oend;
    const ilowest = args.ilowest;

    while (true) {
        // Each iteration writes 5 symbols per stream and reads up to
        // 5 * 11 = 55 bits, under 7 bytes, per stream.
        const oiters = (@intFromPtr(oend) - @intFromPtr(op[3])) / 5;
        const iiters = (@intFromPtr(ip[0]) - @intFromPtr(ilowest)) / 7;
        const iters = @min(oiters, iiters);
        const olimit = @intFromPtr(op[3]) + iters * 5;
        if (@intFromPtr(op[3]) == olimit) break;
        // Each stream's pointer must stay at or above the one before.
        inline for (1..4) |s| {
            if (@intFromPtr(ip[s]) < @intFromPtr(ip[s - 1])) {
                args.bits = bits;
                args.ip = ip;
                args.op = op;
                return;
            }
        }
        while (true) {
            inline for (0..5) |symbol| {
                inline for (0..4) |s| {
                    const index: usize = @intCast(bits[s] >> 53);
                    const entry = dtable[index];
                    bits[s] = inRegister(bits[s] << @intCast(entry & 0x3F));
                    op[s][symbol] = @truncate(entry >> 8);
                }
            }
            inline for (0..4) |s| {
                const ctz = @ctz(bits[s]);
                const nb_bits: u6 = @intCast(ctz & 7);
                const nb_bytes = ctz >> 3;
                op[s] += 5;
                ip[s] -= nb_bytes;
                bits[s] = std.mem.readInt(u64, ip[s][0..8], .little) | 1;
                bits[s] <<= nb_bits;
            }
            if (@intFromPtr(op[3]) >= olimit) break;
        }
    }
    args.bits = bits;
    args.ip = ip;
    args.op = op;
}

/// `HUF_decompress4X1_usingDTable_internal_fast`: 0 when the fallback
/// decoder must run.
fn decompress4X1Fast(dst: []u8, c_src: []const u8, dtable: [*]const DTable) Error!usize {
    const dt: [*]const DEltX1 = @ptrCast(dtable + 1);
    var args: FastArgs = undefined;
    if (!try initFastArgs(&args, dst, c_src, dtable)) return 0;
    decompress4X1FastLoop(&args);
    return finishFast(DEltX1, dst, &args, dt);
}

/// The end of `HUF_decompress4X{1,2}_usingDTable_internal_fast`: each
/// stream finished by the safe decoder, which must end at its segment's end.
fn finishFast(comptime Elt: type, dst: []u8, args: *FastArgs, dt: [*]const Elt) Error!usize {
    const oend = dst.ptr + dst.len;
    const segment_size = (dst.len + 3) / 4;
    var segment_end: [*]u8 = dst.ptr;
    for (0..4) |i| {
        var bit: DStream = undefined;
        if (segment_size <= @intFromPtr(oend) - @intFromPtr(segment_end)) {
            segment_end += segment_size;
        } else {
            segment_end = oend;
        }
        try initRemainingDStream(&bit, args, i, segment_end);
        args.op[i] += if (Elt == DEltX1)
            decodeStreamX1(args.op[i], &bit, segment_end, dt, decoder_fast_table_log)
        else
            decodeStreamX2(args.op[i], &bit, segment_end, dt, decoder_fast_table_log);
        if (args.op[i] != segment_end) return error.CorruptionDetected;
    }
    return dst.len;
}

/// `HUF_decompress4X1_usingDTable_internal`.
fn decompress4X1UsingDTableInternal(dst: []u8, c_src: []const u8, dtable: [*]const DTable, flags: huf.Flags) Error!usize {
    if (!flags.disable_fast) {
        const ret = try decompress4X1Fast(dst, c_src, dtable);
        if (ret != 0) return ret;
    }
    return decompress4X1UsingDTableBody(dst, c_src, dtable);
}

/// `HUF_decompress4X1_DCtx_wksp`.
fn decompress4X1DCtxWksp(dtable: [*]DTable, dst: []u8, c_src: []const u8, workspace: []u32, flags: huf.Flags) Error!usize {
    const h_size = try readDTableX1Wksp(dtable, c_src, workspace);
    if (h_size >= c_src.len) return error.SrcSizeWrong;
    return decompress4X1UsingDTableInternal(dst, c_src[h_size..], dtable, flags);
}

/// `HUF_decompress1X1_DCtx_wksp`.
pub fn decompress1X1DCtxWksp(dtable: [*]DTable, dst: []u8, c_src: []const u8, workspace: []u32, flags: huf.Flags) Error!usize {
    _ = flags;
    const h_size = try readDTableX1Wksp(dtable, c_src, workspace);
    if (h_size >= c_src.len) return error.SrcSizeWrong;
    return decompress1X1UsingDTableInternal(dst, c_src[h_size..], dtable);
}

// --------------------------------------------------------
// Double-symbol decoding
// --------------------------------------------------------

/// `HUF_DEltX2`: one or two symbols in `sequence`.
const DEltX2 = packed struct(u32) {
    sequence: u16,
    nb_bits: u8,
    length: u8,
};

const rank_val_col_len = huf.table_log_max + 1;
const RankValCol = [rank_val_col_len]u32;

/// `HUF_buildDEltX2U32`.
fn buildDEltX2U32(symbol: u32, nb_bits: u32, base_seq: u32, level: u32) u32 {
    const seq = if (level == 1) symbol else base_seq + (symbol << 8);
    return seq + (nb_bits << 16) + (level << 24);
}

fn buildDEltX2(symbol: u32, nb_bits: u32, base_seq: u32, level: u32) DEltX2 {
    return @bitCast(buildDEltX2U32(symbol, nb_bits, base_seq, level));
}

/// `HUF_fillDTableX2ForWeight`: the entries of every symbol in `symbols`,
/// each `nb_bits` long, from `rank`.
fn fillDTableX2ForWeight(rank: [*]DEltX2, symbols: []const u8, nb_bits: u32, table_log: u32, base_seq: u16, level: u32) void {
    const length = @as(usize, 1) << @intCast((table_log - nb_bits) & 0x1F);
    var p = rank;
    for (symbols) |symbol| {
        @memset(p[0..length], buildDEltX2(symbol, nb_bits, base_seq, level));
        p += length;
    }
}

/// `HUF_fillDTableX2Level2`.
fn fillDTableX2Level2(
    dtable: [*]DEltX2,
    target_log: u32,
    consumed_bits: u32,
    rank_val: *const RankValCol,
    min_weight: u32,
    max_weight1: u32,
    sorted_symbols: []const u8,
    rank_start: []const u32,
    nb_bits_baseline: u32,
    base_seq: u16,
) void {
    // The positions up to `rank_val[min_weight]` get one symbol only: the
    // combined weight is too large.
    if (min_weight > 1) {
        const length = @as(u32, 1) << @intCast((target_log - consumed_bits) & 0x1F);
        const delt = buildDEltX2(base_seq, consumed_bits, 0, 1);
        const skip_size: usize = rank_val[min_weight];
        assert(length > 1);
        assert(skip_size < length);
        // The original writes two entries at a time, and from 8 entries,
        // eight at a time, past `skip_size`; later fills overwrite them.
        switch (length) {
            2 => @memset(dtable[0..2], delt),
            4 => @memset(dtable[0..4], delt),
            else => {
                var i: usize = 0;
                while (i < skip_size) : (i += 8) @memset(dtable[i..][0..8], delt);
            },
        }
    }
    // The second symbols, weight by weight.
    var w = min_weight;
    while (w < max_weight1) : (w += 1) {
        const begin = rank_start[w];
        const end = rank_start[w + 1];
        const nb_bits = nb_bits_baseline - w;
        const total_bits = nb_bits + consumed_bits;
        fillDTableX2ForWeight(dtable + rank_val[w], sorted_symbols[begin..end], total_bits, target_log, base_seq, 2);
    }
}

/// `HUF_fillDTableX2`.
fn fillDTableX2(
    dtable: [*]DEltX2,
    target_log: u32,
    sorted_list: []const u8,
    rank_start: []const u32,
    rank_val_origin: *const [huf.table_log_max]RankValCol,
    max_weight: u32,
    nb_bits_baseline: u32,
) void {
    const rank_val = &rank_val_origin[0];
    const scale_log: i32 = @as(i32, @intCast(nb_bits_baseline)) - @as(i32, @intCast(target_log));
    const min_bits = nb_bits_baseline - max_weight;
    const w_end = max_weight + 1;
    var w: u32 = 1;
    while (w < w_end) : (w += 1) {
        const begin = rank_start[w];
        const end = rank_start[w + 1];
        const nb_bits = nb_bits_baseline - w;
        if (target_log - nb_bits >= min_bits) {
            // Room for a second symbol.
            var start: usize = rank_val[w];
            const length = @as(usize, 1) << @intCast((target_log - nb_bits) & 0x1F);
            var min_weight: i32 = @as(i32, @intCast(nb_bits)) + scale_log;
            if (min_weight < 1) min_weight = 1;
            for (sorted_list[begin..end]) |symbol| {
                fillDTableX2Level2(
                    dtable + start,
                    target_log,
                    nb_bits,
                    &rank_val_origin[nb_bits],
                    @intCast(min_weight),
                    w_end,
                    sorted_list,
                    rank_start,
                    nb_bits_baseline,
                    symbol,
                );
                start += length;
            }
        } else {
            fillDTableX2ForWeight(dtable + rank_val[w], sorted_list[begin..end], nb_bits, target_log, 0, 1);
        }
    }
}

/// `HUF_ReadDTableX2_Workspace`.
const ReadDTableX2Workspace = extern struct {
    rank_val: [huf.table_log_max]RankValCol,
    rank_stats: [huf.table_log_max + 1]u32,
    rank_start0: [huf.table_log_max + 3]u32,
    sorted_symbol: [huf.symbol_value_max + 1]u8,
    weight_list: [huf.symbol_value_max + 1]u8,
    callee_wksp: [huf.read_stats_workspace_size_u32]u32,
};

/// `HUF_readDTableX2_wksp`: reads a Huffman table header into a
/// double-symbol table; returns the header's size.
pub fn readDTableX2Wksp(dtable: [*]DTable, src: []const u8, workspace: []u32) Error!usize {
    var dtd = getDTableDesc(dtable);
    var max_table_log: u32 = dtd.max_table_log;
    const dt: [*]DEltX2 = @ptrCast(dtable + 1);
    if (@sizeOf(ReadDTableX2Workspace) > workspace.len * 4) return error.Generic;
    const wksp: *ReadDTableX2Workspace = @ptrCast(workspace.ptr);
    const rank_start = wksp.rank_start0[1..];
    @memset(&wksp.rank_stats, 0);
    @memset(&wksp.rank_start0, 0);
    if (max_table_log > huf.table_log_max) return error.TableLogTooLarge;

    var nb_symbols: u32 = undefined;
    var table_log: u32 = undefined;
    const i_size = try entropy_common.readStatsWksp(
        &wksp.weight_list,
        &wksp.rank_stats,
        &nb_symbols,
        &table_log,
        src,
        std.mem.asBytes(&wksp.callee_wksp),
    );

    if (table_log > max_table_log) return error.TableLogTooLarge;
    if (table_log <= decoder_fast_table_log and max_table_log > decoder_fast_table_log) {
        max_table_log = decoder_fast_table_log;
    }

    // The largest weight; there is one before 0.
    var max_w = table_log;
    while (wksp.rank_stats[max_w] == 0) max_w -= 1;

    // Where each weight starts.
    {
        var next_rank_start: u32 = 0;
        var w: u32 = 1;
        while (w < max_w + 1) : (w += 1) {
            const curr = next_rank_start;
            next_rank_start += wksp.rank_stats[w];
            rank_start[w] = curr;
        }
        // The weight-0 symbols go at the end of the sorted list.
        rank_start[0] = next_rank_start;
        rank_start[max_w + 1] = next_rank_start;
    }

    // Sort the symbols by weight.
    for (0..nb_symbols) |s| {
        const w = wksp.weight_list[s];
        const r = rank_start[w];
        rank_start[w] += 1;
        wksp.sorted_symbol[r] = @intCast(s);
    }
    // Forget the weight-0 symbols: this is the start of weight 1.
    rank_start[0] = 0;

    // The rank values.
    {
        const rank_val0 = &wksp.rank_val[0];
        const rescale: i32 = @as(i32, @intCast(max_table_log - table_log)) - 1;
        var next_rank_val: u32 = 0;
        var w: u32 = 1;
        while (w < max_w + 1) : (w += 1) {
            const curr = next_rank_val;
            const shift: u32 = @intCast(@as(i32, @intCast(w)) + rescale);
            next_rank_val +%= wksp.rank_stats[w] << @intCast(shift);
            rank_val0[w] = curr;
        }
        const min_bits = table_log + 1 - max_w;
        var consumed = min_bits;
        while (consumed < max_table_log - min_bits + 1) : (consumed += 1) {
            const rank_val_ptr = &wksp.rank_val[consumed];
            w = 1;
            while (w < max_w + 1) : (w += 1) rank_val_ptr[w] = rank_val0[w] >> @intCast(consumed);
        }
    }

    fillDTableX2(dt, max_table_log, &wksp.sorted_symbol, &wksp.rank_start0, &wksp.rank_val, max_w, table_log + 1);

    dtd.table_log = @intCast(max_table_log);
    dtd.table_type = 1;
    setDTableDesc(dtable, dtd);
    return i_size;
}

/// `HUF_decodeSymbolX2`: writes two bytes, returns how many are symbols.
inline fn decodeSymbolX2(op: [*]u8, d: *DStream, dt: [*]const DEltX2, dt_log: u32) u32 {
    const val = d.lookBitsFast(dt_log);
    const entry = dt[val];
    std.mem.writeInt(u16, op[0..2], entry.sequence, .little);
    d.skipBits(entry.nb_bits);
    return entry.length;
}

/// `HUF_decodeLastSymbolX2`: writes one byte.
inline fn decodeLastSymbolX2(op: [*]u8, d: *DStream, dt: [*]const DEltX2, dt_log: u32) u32 {
    const val = d.lookBitsFast(dt_log);
    const entry = dt[val];
    op[0] = @truncate(entry.sequence);
    if (entry.length == 1) {
        d.skipBits(entry.nb_bits);
    } else if (d.bits_consumed < @bitSizeOf(bitstream.Container)) {
        d.skipBits(entry.nb_bits);
        // The last symbol's bits may run past the container; the original
        // clamps, as it cannot tell the first symbol's bits apart.
        if (d.bits_consumed > @bitSizeOf(bitstream.Container)) {
            d.bits_consumed = @bitSizeOf(bitstream.Container);
        }
    }
    return 1;
}

/// `HUF_decodeStreamX2`.
inline fn decodeStreamX2(p_start: [*]u8, bit_d: *DStream, p_end: [*]u8, dt: [*]const DEltX2, dt_log: u32) usize {
    var p = p_start;
    const end = @intFromPtr(p_end);
    if (end - @intFromPtr(p) >= @sizeOf(bitstream.Container)) {
        if (dt_log <= 11 and @sizeOf(usize) == 8) {
            // Up to 10 symbols at a time.
            while ((bit_d.reload() == .unfinished) and @intFromPtr(p) < end - 9) {
                inline for (0..5) |_| p += decodeSymbolX2(p, bit_d, dt, dt_log);
            }
        } else {
            // Up to 8 symbols at a time.
            while ((bit_d.reload() == .unfinished) and @intFromPtr(p) < end - (@sizeOf(bitstream.Container) - 1)) {
                inline for (symbols_between_reloads) |wide| {
                    if (!wide or is_64bit) p += decodeSymbolX2(p, bit_d, dt, dt_log);
                }
            }
        }
    } else {
        _ = bit_d.reload();
    }

    // Closer to the end: up to 2 symbols at a time.
    if (end - @intFromPtr(p) >= 2) {
        while ((bit_d.reload() == .unfinished) and @intFromPtr(p) <= end - 2) {
            p += decodeSymbolX2(p, bit_d, dt, dt_log);
        }
        while (@intFromPtr(p) <= end - 2) p += decodeSymbolX2(p, bit_d, dt, dt_log);
    }
    if (@intFromPtr(p) < end) p += decodeLastSymbolX2(p, bit_d, dt, dt_log);
    return @intFromPtr(p) - @intFromPtr(p_start);
}

/// `HUF_decompress1X2_usingDTable_internal`.
fn decompress1X2UsingDTableInternal(dst: []u8, c_src: []const u8, dtable: [*]const DTable) Error!usize {
    var bit_d = try DStream.init(c_src);
    const dt: [*]const DEltX2 = @ptrCast(dtable + 1);
    _ = decodeStreamX2(dst.ptr, &bit_d, dst.ptr + dst.len, dt, getDTableDesc(dtable).table_log);
    if (!bit_d.endOfStream()) return error.CorruptionDetected;
    return dst.len;
}

/// `HUF_decompress4X2_usingDTable_internal_body`: `dst` holds at least 6.
fn decompress4X2UsingDTableBody(dst: []u8, c_src: []const u8, dtable: [*]const DTable) Error!usize {
    var streams = try initFourStreams(dst.len, c_src);
    const bit_d = &streams.bit_d;
    const ostart = dst.ptr;
    const oend = ostart + dst.len;
    const olimit = @intFromPtr(oend) - (@sizeOf(usize) - 1);
    const dt: [*]const DEltX2 = @ptrCast(dtable + 1);
    const dt_log = getDTableDesc(dtable).table_log;
    const op_start = [4][*]u8{
        ostart,
        ostart + streams.segment_size,
        ostart + 2 * streams.segment_size,
        ostart + 3 * streams.segment_size,
    };
    var op = op_start;

    // 16 to 32 symbols a loop, 4 to 8 a stream, in the order the original
    // takes when clang builds it for x86: stream by stream, two streams
    // before their reloads.
    if (@intFromPtr(oend) - @intFromPtr(op[3]) >= @sizeOf(usize)) {
        var end_signal = true;
        while (end_signal and @intFromPtr(op[3]) < olimit) {
            inline for (.{ 0, 2 }) |first| {
                inline for (first..first + 2) |s| {
                    inline for (symbols_between_reloads) |wide| {
                        if (!wide or is_64bit) op[s] += decodeSymbolX2(op[s], &bit_d[s], dt, dt_log);
                    }
                }
                inline for (first..first + 2) |s| {
                    end_signal = (bit_d[s].reloadFast() == .unfinished) and end_signal;
                }
            }
        }
    }

    if (@intFromPtr(op[0]) > @intFromPtr(op_start[1])) return error.CorruptionDetected;
    if (@intFromPtr(op[1]) > @intFromPtr(op_start[2])) return error.CorruptionDetected;
    if (@intFromPtr(op[2]) > @intFromPtr(op_start[3])) return error.CorruptionDetected;

    _ = decodeStreamX2(op[0], &bit_d[0], op_start[1], dt, dt_log);
    _ = decodeStreamX2(op[1], &bit_d[1], op_start[2], dt, dt_log);
    _ = decodeStreamX2(op[2], &bit_d[2], op_start[3], dt, dt_log);
    _ = decodeStreamX2(op[3], &bit_d[3], oend, dt, dt_log);

    const end_check = bit_d[0].endOfStream() and bit_d[1].endOfStream() and
        bit_d[2].endOfStream() and bit_d[3].endOfStream();
    if (!end_check) return error.CorruptionDetected;
    return dst.len;
}

/// `HUF_decompress4X2_usingDTable_internal_fast_c_loop`.
fn decompress4X2FastLoop(args: *FastArgs) void {
    var bits = args.bits;
    var ip = args.ip;
    var op = args.op;
    const oend = [4]usize{
        @intFromPtr(op[1]),
        @intFromPtr(op[2]),
        @intFromPtr(op[3]),
        @intFromPtr(args.oend),
    };
    const dtable: [*]const DEltX2 = @ptrCast(args.dt);
    const ilowest = args.ilowest;

    outer: while (true) {
        // Up to 7 bytes in, and up to 10 out, per stream an iteration.
        var iters = (@intFromPtr(ip[0]) - @intFromPtr(ilowest)) / 7;
        inline for (0..4) |s| iters = @min(iters, (oend[s] - @intFromPtr(op[s])) / 10);
        // Each iteration writes at least 5 symbols to stream 3.
        const olimit = @intFromPtr(op[3]) + iters * 5;
        if (@intFromPtr(op[3]) == olimit) break;
        inline for (1..4) |s| {
            if (@intFromPtr(ip[s]) < @intFromPtr(ip[s - 1])) break :outer;
        }
        while (true) {
            // 5 symbols from each of the first 3 streams, then stream 3's
            // decoded between the reloads.
            inline for (0..5) |_| {
                inline for (0..3) |s| decodeX2Fast(&bits[s], &op[s], dtable);
            }
            decodeX2Fast(&bits[3], &op[3], dtable);
            inline for (0..4) |s| {
                decodeX2Fast(&bits[3], &op[3], dtable);
                const ctz = @ctz(bits[s]);
                const nb_bits: u6 = @intCast(ctz & 7);
                const nb_bytes = ctz >> 3;
                ip[s] -= nb_bytes;
                bits[s] = std.mem.readInt(u64, ip[s][0..8], .little) | 1;
                bits[s] <<= nb_bits;
            }
            if (@intFromPtr(op[3]) >= olimit) break;
        }
    }
    args.bits = bits;
    args.ip = ip;
    args.op = op;
}

/// One symbol of the X2 fast loop (`HUF_4X2_DECODE_SYMBOL`).
inline fn decodeX2Fast(bits: *u64, op: *[*]u8, dtable: [*]const DEltX2) void {
    const index: usize = @intCast(bits.* >> 53);
    const entry = dtable[index];
    std.mem.writeInt(u16, op.*[0..2], entry.sequence, .little);
    bits.* = inRegister(bits.* << @intCast(entry.nb_bits & 0x3F));
    op.* += entry.length;
}

/// `HUF_decompress4X2_usingDTable_internal_fast`.
fn decompress4X2Fast(dst: []u8, c_src: []const u8, dtable: [*]const DTable) Error!usize {
    const dt: [*]const DEltX2 = @ptrCast(dtable + 1);
    var args: FastArgs = undefined;
    if (!try initFastArgs(&args, dst, c_src, dtable)) return 0;
    decompress4X2FastLoop(&args);
    return finishFast(DEltX2, dst, &args, dt);
}

/// `HUF_decompress4X2_usingDTable_internal`.
fn decompress4X2UsingDTableInternal(dst: []u8, c_src: []const u8, dtable: [*]const DTable, flags: huf.Flags) Error!usize {
    if (!flags.disable_fast) {
        const ret = try decompress4X2Fast(dst, c_src, dtable);
        if (ret != 0) return ret;
    }
    return decompress4X2UsingDTableBody(dst, c_src, dtable);
}

/// `HUF_decompress1X2_DCtx_wksp`.
pub fn decompress1X2DCtxWksp(dtable: [*]DTable, dst: []u8, c_src: []const u8, workspace: []u32, flags: huf.Flags) Error!usize {
    _ = flags;
    const h_size = try readDTableX2Wksp(dtable, c_src, workspace);
    if (h_size >= c_src.len) return error.SrcSizeWrong;
    return decompress1X2UsingDTableInternal(dst, c_src[h_size..], dtable);
}

/// `HUF_decompress4X2_DCtx_wksp`.
fn decompress4X2DCtxWksp(dtable: [*]DTable, dst: []u8, c_src: []const u8, workspace: []u32, flags: huf.Flags) Error!usize {
    const h_size = try readDTableX2Wksp(dtable, c_src, workspace);
    if (h_size >= c_src.len) return error.SrcSizeWrong;
    return decompress4X2UsingDTableInternal(dst, c_src[h_size..], dtable, flags);
}

// --------------------------------------------------------
// Selectors
// --------------------------------------------------------

const AlgoTime = struct { table_time: u32, decode256_time: u32 };

/// `algoTime`: the cost model behind `selectDecoder`, by compression ratio
/// in sixteenths, for X1 and X2.
const algo_time = [16][2]AlgoTime{
    .{ .{ .table_time = 0, .decode256_time = 0 }, .{ .table_time = 1, .decode256_time = 1 } },
    .{ .{ .table_time = 0, .decode256_time = 0 }, .{ .table_time = 1, .decode256_time = 1 } },
    .{ .{ .table_time = 150, .decode256_time = 216 }, .{ .table_time = 381, .decode256_time = 119 } },
    .{ .{ .table_time = 170, .decode256_time = 205 }, .{ .table_time = 514, .decode256_time = 112 } },
    .{ .{ .table_time = 177, .decode256_time = 199 }, .{ .table_time = 539, .decode256_time = 110 } },
    .{ .{ .table_time = 197, .decode256_time = 194 }, .{ .table_time = 644, .decode256_time = 107 } },
    .{ .{ .table_time = 221, .decode256_time = 192 }, .{ .table_time = 735, .decode256_time = 107 } },
    .{ .{ .table_time = 256, .decode256_time = 189 }, .{ .table_time = 881, .decode256_time = 106 } },
    .{ .{ .table_time = 359, .decode256_time = 188 }, .{ .table_time = 1167, .decode256_time = 109 } },
    .{ .{ .table_time = 582, .decode256_time = 187 }, .{ .table_time = 1570, .decode256_time = 114 } },
    .{ .{ .table_time = 688, .decode256_time = 187 }, .{ .table_time = 1712, .decode256_time = 122 } },
    .{ .{ .table_time = 825, .decode256_time = 186 }, .{ .table_time = 1965, .decode256_time = 136 } },
    .{ .{ .table_time = 976, .decode256_time = 185 }, .{ .table_time = 2131, .decode256_time = 150 } },
    .{ .{ .table_time = 1180, .decode256_time = 186 }, .{ .table_time = 2070, .decode256_time = 175 } },
    .{ .{ .table_time = 1377, .decode256_time = 185 }, .{ .table_time = 1731, .decode256_time = 202 } },
    .{ .{ .table_time = 1412, .decode256_time = 185 }, .{ .table_time = 1695, .decode256_time = 202 } },
};

/// `HUF_selectDecoder`: 0 for X1, 1 for X2, whichever the cost model says
/// decodes faster. `dst_size` is from 1 to 128 KiB.
pub fn selectDecoder(dst_size: usize, c_src_size: usize) u32 {
    assert(dst_size > 0);
    assert(dst_size <= 128 * 1024);
    const q: usize = if (c_src_size >= dst_size) 15 else c_src_size * 16 / dst_size;
    const d256: u32 = @intCast(dst_size >> 8);
    const d_time0 = algo_time[q][0].table_time + algo_time[q][0].decode256_time * d256;
    var d_time1 = algo_time[q][1].table_time + algo_time[q][1].decode256_time * d256;
    // A small advantage to the decoder with the smaller table.
    d_time1 += d_time1 >> 5;
    return @intFromBool(d_time1 < d_time0);
}

/// `HUF_decompress1X_DCtx_wksp`.
pub fn decompress1XDCtxWksp(dtable: [*]DTable, dst: []u8, c_src: []const u8, workspace: []u32, flags: huf.Flags) Error!usize {
    if (dst.len == 0) return error.DstSizeTooSmall;
    if (c_src.len > dst.len) return error.CorruptionDetected;
    if (c_src.len == dst.len) {
        @memcpy(dst, c_src);
        return dst.len;
    }
    if (c_src.len == 1) {
        @memset(dst, c_src[0]);
        return dst.len;
    }
    return if (selectDecoder(dst.len, c_src.len) != 0)
        decompress1X2DCtxWksp(dtable, dst, c_src, workspace, flags)
    else
        decompress1X1DCtxWksp(dtable, dst, c_src, workspace, flags);
}

/// `HUF_decompress1X_usingDTable`.
pub fn decompress1XUsingDTable(dst: []u8, c_src: []const u8, dtable: [*]const DTable, flags: huf.Flags) Error!usize {
    _ = flags;
    return if (getDTableDesc(dtable).table_type != 0)
        decompress1X2UsingDTableInternal(dst, c_src, dtable)
    else
        decompress1X1UsingDTableInternal(dst, c_src, dtable);
}

/// `HUF_decompress4X_usingDTable`.
pub fn decompress4XUsingDTable(dst: []u8, c_src: []const u8, dtable: [*]const DTable, flags: huf.Flags) Error!usize {
    return if (getDTableDesc(dtable).table_type != 0)
        decompress4X2UsingDTableInternal(dst, c_src, dtable, flags)
    else
        decompress4X1UsingDTableInternal(dst, c_src, dtable, flags);
}

/// `HUF_decompress4X_hufOnly_wksp`.
pub fn decompress4XHufOnlyWksp(dtable: [*]DTable, dst: []u8, c_src: []const u8, workspace: []u32, flags: huf.Flags) Error!usize {
    if (dst.len == 0) return error.DstSizeTooSmall;
    if (c_src.len == 0) return error.CorruptionDetected;
    return if (selectDecoder(dst.len, c_src.len) != 0)
        decompress4X2DCtxWksp(dtable, dst, c_src, workspace, flags)
    else
        decompress4X1DCtxWksp(dtable, dst, c_src, workspace, flags);
}

test {
    std.testing.refAllDecls(@This());
}
