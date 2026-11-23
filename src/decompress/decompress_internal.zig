//! The decompressor's types, from the original's
//! zstd_decompress_internal.h and zstd_ddict.c: the decoding tables, the
//! decompression context and the digested dictionary, with the original's
//! object sizes for the size functions.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const params = @import("../params.zig");
const zstd_internal = @import("../common/zstd_internal.zig");
const huf_decompress = @import("huf_decompress.zig");
const decompress = @import("decompress.zig");
const block_impl = @import("decompress_block.zig");
const ddict_impl = @import("ddict.zig");

pub const max_ll = zstd_internal.max_ll;
pub const max_ml = zstd_internal.max_ml;
pub const max_off = zstd_internal.max_off;

/// `LL_base`: the first literal length of each code.
pub const ll_base = [max_ll + 1]u32{
    0,      1,      2,      3,       4,     5,     6,     7,
    8,      9,      10,     11,      12,    13,    14,    15,
    16,     18,     20,     22,      24,    28,    32,    40,
    48,     64,     0x80,   0x100,   0x200, 0x400, 0x800, 0x1000,
    0x2000, 0x4000, 0x8000, 0x10000,
};

/// `OF_base`: the first offset value of each code.
pub const of_base = [max_off + 1]u32{
    0,        1,         1,         5,         0xD,       0x1D,       0x3D,       0x7D,
    0xFD,     0x1FD,     0x3FD,     0x7FD,     0xFFD,     0x1FFD,     0x3FFD,     0x7FFD,
    0xFFFD,   0x1FFFD,   0x3FFFD,   0x7FFFD,   0xFFFFD,   0x1FFFFD,   0x3FFFFD,   0x7FFFFD,
    0xFFFFFD, 0x1FFFFFD, 0x3FFFFFD, 0x7FFFFFD, 0xFFFFFFD, 0x1FFFFFFD, 0x3FFFFFFD, 0x7FFFFFFD,
};

/// `OF_bits`: the extra bits of each offset code.
pub const of_bits = blk: {
    var bits: [max_off + 1]u8 = undefined;
    for (&bits, 0..) |*b, i| b.* = i;
    break :blk bits;
};

/// `ML_base`: the first match length of each code.
pub const ml_base = [max_ml + 1]u32{
    3,      4,      5,      6,      7,       8,     9,     10,
    11,     12,     13,     14,     15,      16,    17,    18,
    19,     20,     21,     22,     23,      24,    25,    26,
    27,     28,     29,     30,     31,      32,    33,    34,
    35,     37,     39,     41,     43,      47,    51,    59,
    67,     83,     99,     0x83,   0x103,   0x203, 0x403, 0x803,
    0x1003, 0x2003, 0x4003, 0x8003, 0x10003,
};

/// `ZSTD_seqSymbol_header`: the first entry of a sequence decoding table.
pub const SeqSymbolHeader = extern struct {
    fast_mode: u32,
    table_log: u32,
};

/// `ZSTD_seqSymbol`.
pub const SeqSymbol = extern struct {
    next_state: u16,
    nb_additional_bits: u8,
    nb_bits: u8,
    base_value: u32,
};

/// `SEQSYMBOL_TABLE_SIZE`.
pub fn seqSymbolTableSize(log: u32) usize {
    return 1 + (@as(usize, 1) << @intCast(log));
}

/// `ZSTD_BUILD_FSE_TABLE_WKSP_SIZE` and its u32 count.
pub const build_fse_table_wksp_size = @sizeOf(i16) * (zstd_internal.max_seq + 1) +
    (1 << zstd_internal.max_fse_log) + @sizeOf(u64);
pub const build_fse_table_wksp_size_u32 = (build_fse_table_wksp_size + 3) / 4;

/// `ZSTD_HUFFDTABLE_CAPACITY_LOG`.
pub const huf_dtable_capacity_log = 12;

/// `ZSTD_entropyDTables_t`: the tables a block decodes with. The three
/// sequence tables are laid out together, as the dictionary loader uses
/// them as one workspace.
pub const EntropyDTables = extern struct {
    ll_table: [seqSymbolTableSize(zstd_internal.ll_fse_log)]SeqSymbol,
    of_table: [seqSymbolTableSize(zstd_internal.off_fse_log)]SeqSymbol,
    ml_table: [seqSymbolTableSize(zstd_internal.ml_fse_log)]SeqSymbol,
    huf_table: [huf_decompress.dtableSize(huf_dtable_capacity_log)]u32,
    rep: [zstd_internal.rep_num]u32,
    workspace: [build_fse_table_wksp_size_u32]u32,

    /// The three sequence tables as a workspace of u32s.
    pub fn seqTablesAsWorkspace(entropy: *EntropyDTables) []u32 {
        const size = @sizeOf(@TypeOf(entropy.ll_table)) + @sizeOf(@TypeOf(entropy.of_table)) +
            @sizeOf(@TypeOf(entropy.ml_table));
        return @as([*]u32, @ptrCast(&entropy.ll_table))[0 .. size / 4];
    }

    /// The first u32 of an empty Huffman table that can hold
    /// `huf_dtable_capacity_log`.
    pub const huf_table_init: u32 = huf_dtable_capacity_log * 0x1000001;
};

comptime {
    assert(@offsetOf(EntropyDTables, "of_table") ==
        @offsetOf(EntropyDTables, "ll_table") + @sizeOf(@FieldType(EntropyDTables, "ll_table")));
    assert(@offsetOf(EntropyDTables, "ml_table") ==
        @offsetOf(EntropyDTables, "of_table") + @sizeOf(@FieldType(EntropyDTables, "of_table")));
}

/// `ZSTD_dStage`: where the buffer-less decoder is in a frame.
pub const DStage = enum(u32) {
    get_frame_header_size,
    decode_frame_header,
    decode_block_header,
    decompress_block,
    decompress_last_block,
    check_checksum,
    decode_skippable_header,
    skip_frame,
};

/// `ZSTD_dStreamStage`: where the streaming decoder is.
pub const DStreamStage = enum(u32) { init = 0, load_header, read, load, flush };

/// `ZSTD_dictUses_e`.
pub const DictUses = enum(i32) {
    /// Use the dictionary for every frame.
    use_indefinitely = -1,
    /// Use no dictionary, and free a local one.
    dont_use = 0,
    /// Use the dictionary for the next frame only.
    use_once = 1,
};

/// `ZSTD_litLocation_e`: where a block's decoded literals are.
pub const LitLocation = enum(u32) {
    /// All in the context's extra buffer.
    not_in_dst = 0,
    /// All in the output, after the block's room.
    in_dst = 1,
    /// Split between the end of the block's output and the extra buffer.
    split = 2,
};

/// `streaming_operation`.
pub const StreamingOperation = enum { not_streaming, is_streaming };

/// `ZSTD_DECODER_INTERNAL_BUFFER`, `ZSTD_LBMIN`, `ZSTD_LBMAX`.
pub const decoder_internal_buffer = 1 << 16;
pub const lbmin = 64;
pub const lbmax = 128 << 10;
/// `ZSTD_LITBUFFEREXTRASIZE`: the context's own room for literals.
pub const lit_buffer_extra_size = std.math.clamp(decoder_internal_buffer, lbmin, lbmax);

/// `ZSTD_MAXWINDOWSIZE_DEFAULT`.
pub const max_window_size_default: usize = (@as(u32, 1) << params.window_log_limit_default) + 1;
/// `ZSTD_NO_FORWARD_PROGRESS_MAX`.
pub const no_forward_progress_max = 16;

/// `ZSTD_DDict`: a dictionary digested for decompression, shared by any
/// number of contexts. Made by `createDDict*` (freed by `freeDDict`) or
/// `initStaticDDict` over a caller's buffer.
pub const DDict = struct {
    /// The copy the dictionary owns, if any, of `dict_content.len` bytes.
    dict_buffer: ?[*]u8,
    /// The dictionary's bytes: `dict_buffer`, or the caller's, which must
    /// outlive the dictionary when loaded by reference.
    dict_content: []const u8,
    entropy: EntropyDTables,
    dict_id: u32,
    entropy_present: bool,
    /// The allocator that made it; null for a static dictionary.
    c_mem: ?std.mem.Allocator,

    pub const create = ddict_impl.createDDict;
    pub const createByReference = ddict_impl.createDDictByReference;
    pub const createAdvanced = ddict_impl.createDDictAdvanced;
    pub const initStatic = ddict_impl.initStaticDDict;
    pub const destroy = ddict_impl.freeDDict;
    pub const sizeof = ddict_impl.sizeofDDict;
    pub const getDictId = ddict_impl.getDictIdFromDDict;
};

/// `ZSTD_DDictHashSet`: the dictionaries a context references with
/// `ref_multiple_ddicts`, by dictionary id. An open-addressing table
/// whose size is a power of 2.
pub const DDictHashSet = struct {
    ddict_ptr_table: []?*const DDict,
    ddict_ptr_count: usize,
};

/// `ZSTD_DCtx`: a decompression context, which is also a decompression
/// stream (`DStream`). Made by `createDCtx` (freed by `freeDCtx`),
/// `initStaticDCtx` over a caller's buffer, or `initDCtx` on a context the
/// caller places, which never allocates.
///
/// The context keeps pointers into itself between the calls of one frame,
/// so it must not move while a frame is in progress (between
/// `decompressBegin*` or the first `decompressStream` of a frame and the
/// frame's end).
pub const DCtx = struct {
    ll_tptr: [*]const SeqSymbol,
    ml_tptr: [*]const SeqSymbol,
    of_tptr: [*]const SeqSymbol,
    huf_ptr: [*]const u32,
    entropy: EntropyDTables,
    /// The room the Huffman table readers work in.
    workspace: [huf_decompress.decompress_workspace_size_u32]u32,
    // The window, as addresses, since they are offsets from one another
    // that may point outside any buffer (0 for none):
    /// Where the last output ended, to tell whether the next one follows it.
    previous_dst_end: usize,
    /// The start of the current output segment.
    prefix_start: usize,
    /// Where the previous segment would start if it were just before the
    /// current one.
    virtual_start: usize,
    /// The end of the previous segment.
    dict_end: usize,
    expected: usize,
    f_params: params.FrameHeader,
    processed_csize: u64,
    decoded_size: u64,
    b_type: zstd_internal.BlockType,
    stage: DStage,
    lit_entropy: bool,
    fse_entropy: bool,
    xxh_state: std.hash.XxHash64,
    header_size: usize,
    format: params.Format,
    force_ignore_checksum: params.ForceIgnoreChecksum,
    validate_checksum: bool,
    lit_ptr: [*]const u8,
    /// The context's allocator; null for a static context.
    custom_mem: ?std.mem.Allocator,
    lit_size: usize,
    rle_size: usize,
    /// The size of the caller's buffer for a static context, else 0.
    static_size: usize,
    is_frame_decompression: bool,

    // The dictionary.
    ddict_local: ?*DDict,
    ddict: ?*const DDict,
    dict_id: u32,
    /// The dictionary is new to this context, so presumed out of cache.
    ddict_is_cold: bool,
    dict_uses: DictUses,
    ddict_set: ?*DDictHashSet,
    ref_multiple_ddicts: params.RefMultipleDDicts,
    disable_huf_asm: bool,
    max_block_size_param: i32,

    // Streaming.
    stream_stage: DStreamStage,
    /// The input buffer, followed by the output buffer, in one allocation
    /// (or in a static context's workspace).
    in_buff: ?[*]u8,
    in_buff_size: usize,
    in_pos: usize,
    max_window_size: usize,
    out_buff: [*]u8,
    out_buff_size: usize,
    out_start: usize,
    out_end: usize,
    lh_size: usize,
    hostage_byte: bool,
    no_forward_progress: u32,
    out_buffer_mode: zstd_internal.BufferMode,
    /// The output buffer of the last call, which a stable output must
    /// repeat: its start, size and position.
    expected_out_buffer: struct { ptr: usize, size: usize, pos: usize },

    // The literals' room.
    lit_buffer: [*]u8,
    lit_buffer_end: [*]const u8,
    lit_buffer_location: LitLocation,
    lit_extra_buffer: [lit_buffer_extra_size + zstd_internal.wildcopy_overlength]u8,
    header_buffer: [params.frame_header_size_max]u8,

    oversized_duration: usize,

    pub const create = decompress.createDCtx;
    pub const destroy = decompress.freeDCtx;
    pub const init = decompress.initDCtx;
    pub const initStatic = decompress.initStaticDCtx;
    pub const copy = decompress.copyDCtx;
    pub const sizeof = decompress.sizeofDCtx;
    pub const setParameter = decompress.setParameter;
    pub const getParameter = decompress.getParameter;
    pub const setMaxWindowSize = decompress.setMaxWindowSize;
    pub const setFormat = decompress.setFormat;
    pub const reset = decompress.reset;
    pub const loadDictionary = decompress.loadDictionary;
    pub const loadDictionaryByReference = decompress.loadDictionaryByReference;
    pub const loadDictionaryAdvanced = decompress.loadDictionaryAdvanced;
    pub const refPrefix = decompress.refPrefix;
    pub const refPrefixAdvanced = decompress.refPrefixAdvanced;
    pub const refDDict = decompress.refDDict;
    pub const decompressDCtx = decompress.decompressDCtx;
    pub const decompressUsingDict = decompress.decompressUsingDict;
    pub const decompressUsingDDict = decompress.decompressUsingDDict;
    pub const decompressFrameExact = decompress.decompressFrameExact;
    pub const decompressBegin = decompress.decompressBegin;
    pub const decompressBeginUsingDict = decompress.decompressBeginUsingDict;
    pub const decompressBeginUsingDDict = decompress.decompressBeginUsingDDict;
    pub const decompressContinue = decompress.decompressContinue;
    pub const nextSrcSizeToDecompress = decompress.nextSrcSizeToDecompress;
    pub const nextInputType = decompress.nextInputType;
    pub const decompressBlock = block_impl.decompressBlock;
    pub const insertBlock = decompress.insertBlock;
    pub const decompressStream = decompress.decompressStream;
    pub const decompressStreamSimpleArgs = decompress.decompressStreamSimpleArgs;
    pub const initDStream = decompress.initDStream;
    pub const initDStreamUsingDict = decompress.initDStreamUsingDict;
    pub const initDStreamUsingDDict = decompress.initDStreamUsingDDict;
    pub const resetDStream = decompress.resetDStream;
};

/// The original's object layouts, for `sizeof` and `estimate*`: they
/// report the original's sizes, and static objects take as much room as
/// the original's do.
pub const c_layout = struct {
    const Ptr = ?*anyopaque;
    const Enum = c_uint;

    /// Whether the original's context keeps a BMI2 flag: it dispatches at
    /// run time on x86 and x86-64 targets without BMI2 (`DYNAMIC_BMI2`).
    const dynamic_bmi2 = (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) and
        !std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2);
    /// Whether it keeps a trace context, as the compressor's does.
    const has_trace = builtin.object_format == .elf and switch (builtin.cpu.arch) {
        .x86_64, .x86, .aarch64, .riscv32, .riscv64 => true,
        else => false,
    } and !builtin.os.tag.isDarwin() and builtin.os.tag != .windows;

    const CFrameHeader = extern struct {
        frame_content_size: u64,
        window_size: u64,
        fields: [7]c_uint,
    };
    const CXxh64State = extern struct { fields: [9]u64, memsize: u32, reserved32: u32, reserved64: u64 };
    const CCustomMem = extern struct { alloc: Ptr, free: Ptr, opaque_ptr: Ptr };
    const COutBuffer = extern struct { dst: Ptr, size: usize, pos: usize };

    pub const DCtxLayout = extern struct {
        tptrs: [4]Ptr,
        entropy: EntropyDTables,
        workspace: [huf_decompress.decompress_workspace_size_u32]u32,
        window: [4]Ptr,
        expected: usize,
        f_params: CFrameHeader,
        processed_csize: u64,
        decoded_size: u64,
        b_type: Enum,
        stage: Enum,
        lit_entropy: u32,
        fse_entropy: u32,
        xxh_state: CXxh64State,
        header_size: usize,
        format: Enum,
        force_ignore_checksum: Enum,
        validate_checksum: u32,
        lit_ptr: Ptr,
        custom_mem: CCustomMem,
        lit_size: usize,
        rle_size: usize,
        static_size: usize,
        is_frame_decompression: c_int,
        bmi2: [@intFromBool(dynamic_bmi2)]c_int,
        ddict_local: Ptr,
        ddict: Ptr,
        dict_id: u32,
        ddict_is_cold: c_int,
        dict_uses: c_int,
        ddict_set: Ptr,
        ref_multiple_ddicts: Enum,
        disable_huf_asm: c_int,
        max_block_size_param: c_int,
        stream_stage: Enum,
        in_buff: Ptr,
        in_buff_size: usize,
        in_pos: usize,
        max_window_size: usize,
        out_buff: Ptr,
        out_buff_size: usize,
        out_start: usize,
        out_end: usize,
        lh_size: usize,
        hostage_byte: u32,
        no_forward_progress: c_int,
        out_buffer_mode: Enum,
        expected_out_buffer: COutBuffer,
        lit_buffer: Ptr,
        lit_buffer_end: Ptr,
        lit_buffer_location: Enum,
        lit_extra_buffer: [lit_buffer_extra_size + zstd_internal.wildcopy_overlength]u8,
        header_buffer: [params.frame_header_size_max]u8,
        oversized_duration: usize,
        trace_ctx: [@intFromBool(has_trace)]u64,
    };

    const DDictLayout = extern struct {
        dict_buffer: Ptr,
        dict_content: Ptr,
        dict_size: usize,
        entropy: EntropyDTables,
        dict_id: u32,
        entropy_present: u32,
        c_mem: CCustomMem,
    };
};

/// The original's `sizeof(ZSTD_DCtx)` and `sizeof(ZSTD_DDict)`.
pub const dctx_object_size = @sizeOf(c_layout.DCtxLayout);
pub const ddict_object_size = @sizeOf(c_layout.DDictLayout);

comptime {
    assert(@sizeOf(DCtx) <= dctx_object_size);
    assert(@alignOf(DCtx) <= 8);
    assert(@sizeOf(DDict) <= ddict_object_size);
    assert(@alignOf(DDict) <= 8);
}

test {
    std.testing.refAllDecls(@This());
}
