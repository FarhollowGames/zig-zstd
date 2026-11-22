//! Frame decompression, from the original's zstd_decompress.c: the frame
//! readers, one-shot and buffer-less decompression, dictionaries,
//! parameters and streaming; and `decompressFrameExact`, the port's
//! one-frame entry point for callers that know the decoded size.

const std = @import("std");
const assert = std.debug.assert;
const Error = @import("../error.zig").Error;
const params = @import("../params.zig");
const zstd_internal = @import("../common/zstd_internal.zig");
const entropy_common = @import("../common/entropy_common.zig");
const bitstream = @import("../common/bitstream.zig");
const internal = @import("decompress_internal.zig");
const block = @import("decompress_block.zig");
const huf_decompress = @import("huf_decompress.zig");
const ddict_impl = @import("ddict.zig");
const DCtx = internal.DCtx;
const DDict = internal.DDict;
const DDictHashSet = internal.DDictHashSet;
const FrameHeader = params.FrameHeader;
const InBuffer = params.InBuffer;
const OutBuffer = params.OutBuffer;

const frame_id_size = zstd_internal.frame_id_size;
const block_header_size = zstd_internal.block_header_size;
const skippable_header_size = params.skippable_header_size;
const content_size_unknown = params.content_size_unknown;
const content_size_error = params.content_size_error;

fn isSkippableMagic(magic: u32) bool {
    return magic & params.magic_skippable_mask == params.magic_skippable_start;
}

fn readLE32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

// --------------------------------------------------------
// The set of referenced dictionaries
// --------------------------------------------------------

const ddict_hashset_max_load_factor_count_mult = 4;
const ddict_hashset_max_load_factor_size_mult = 3;
const ddict_hashset_table_base_size = 64;
const ddict_hashset_resize_factor = 2;

/// `ZSTD_DDictHashSet_getIndex`.
fn hashSetGetIndex(hash_set: *const DDictHashSet, dict_id: u32) usize {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, dict_id, .native);
    const hash = std.hash.XxHash64.hash(0, &bytes);
    return @truncate(hash & (hash_set.ddict_ptr_table.len - 1));
}

/// `ZSTD_DDictHashSet_emplaceDDict`: adds `ddict`, or replaces the one
/// with its id.
fn hashSetEmplaceDDict(hash_set: *DDictHashSet, ddict: *const DDict) Error!void {
    const dict_id = ddict_impl.getDictIdFromDDict(ddict);
    var idx = hashSetGetIndex(hash_set, dict_id);
    const idx_range_mask = hash_set.ddict_ptr_table.len - 1;
    if (hash_set.ddict_ptr_count == hash_set.ddict_ptr_table.len) return error.Generic;
    while (hash_set.ddict_ptr_table[idx]) |entry| {
        if (ddict_impl.getDictIdFromDDict(entry) == dict_id) {
            hash_set.ddict_ptr_table[idx] = ddict;
            return;
        }
        idx &= idx_range_mask;
        idx += 1;
    }
    hash_set.ddict_ptr_table[idx] = ddict;
    hash_set.ddict_ptr_count += 1;
}

/// `ZSTD_DDictHashSet_expand`: doubles the table.
fn hashSetExpand(hash_set: *DDictHashSet, gpa: std.mem.Allocator) Error!void {
    const new_table_size = hash_set.ddict_ptr_table.len * ddict_hashset_resize_factor;
    const new_table = gpa.alloc(?*const DDict, new_table_size) catch return error.MemoryAllocation;
    @memset(new_table, null);
    const old_table = hash_set.ddict_ptr_table;
    hash_set.ddict_ptr_table = new_table;
    hash_set.ddict_ptr_count = 0;
    for (old_table) |entry| {
        if (entry) |d| try hashSetEmplaceDDict(hash_set, d);
    }
    gpa.free(old_table);
}

/// `ZSTD_DDictHashSet_getDDict`: the dictionary with `dict_id`, or null.
fn hashSetGetDDict(hash_set: *const DDictHashSet, dict_id: u32) ?*const DDict {
    var idx = hashSetGetIndex(hash_set, dict_id);
    const idx_range_mask = hash_set.ddict_ptr_table.len - 1;
    while (true) {
        const curr_dict_id = ddict_impl.getDictIdFromDDict(hash_set.ddict_ptr_table[idx]);
        if (curr_dict_id == dict_id or curr_dict_id == 0) break;
        // Back to the start at the end of the table.
        idx &= idx_range_mask;
        idx += 1;
    }
    return hash_set.ddict_ptr_table[idx];
}

/// `ZSTD_createDDictHashSet`.
fn createDDictHashSet(gpa: std.mem.Allocator) ?*DDictHashSet {
    const ret = gpa.create(DDictHashSet) catch return null;
    const table = gpa.alloc(?*const DDict, ddict_hashset_table_base_size) catch {
        gpa.destroy(ret);
        return null;
    };
    @memset(table, null);
    ret.* = .{ .ddict_ptr_table = table, .ddict_ptr_count = 0 };
    return ret;
}

/// `ZSTD_freeDDictHashSet`.
fn freeDDictHashSet(hash_set: *DDictHashSet, gpa: std.mem.Allocator) void {
    gpa.free(hash_set.ddict_ptr_table);
    gpa.destroy(hash_set);
}

/// `ZSTD_DDictHashSet_addDDict`: grows the table past a load of 3/4.
fn hashSetAddDDict(hash_set: *DDictHashSet, ddict: *const DDict, gpa: std.mem.Allocator) Error!void {
    if (hash_set.ddict_ptr_count * ddict_hashset_max_load_factor_count_mult / hash_set.ddict_ptr_table.len *
        ddict_hashset_max_load_factor_size_mult != 0)
    {
        try hashSetExpand(hash_set, gpa);
    }
    try hashSetEmplaceDDict(hash_set, ddict);
}

// --------------------------------------------------------
// Contexts
// --------------------------------------------------------

/// `ZSTD_sizeof_DCtx`: the original's size for this context, with its
/// local dictionary and stream buffers.
pub fn sizeofDCtx(dctx: ?*const DCtx) usize {
    const d = dctx orelse return 0;
    return internal.dctx_object_size + ddict_impl.sizeofDDict(d.ddict_local) + d.in_buff_size + d.out_buff_size;
}

/// `ZSTD_estimateDCtxSize`: the size of a context, as the original's.
pub fn estimateDCtxSize() usize {
    return internal.dctx_object_size;
}

/// `ZSTD_startingInputLength`: the bytes needed to read a header's size.
fn startingInputLength(format: params.Format) usize {
    return frameHeaderSizePrefix(format);
}

/// `ZSTD_FRAMEHEADERSIZE_PREFIX`.
fn frameHeaderSizePrefix(format: params.Format) usize {
    return if (format == .zstd1) 5 else 1;
}

/// `ZSTD_DCtx_resetParameters`.
fn resetParameters(dctx: *DCtx) void {
    assert(dctx.stream_stage == .init);
    dctx.format = .zstd1;
    dctx.max_window_size = internal.max_window_size_default;
    dctx.out_buffer_mode = .buffered;
    dctx.force_ignore_checksum = .validate_checksum;
    dctx.ref_multiple_ddicts = .ref_single_ddict;
    dctx.disable_huf_asm = false;
    dctx.max_block_size_param = 0;
}

/// `ZSTD_initDCtx_internal`. The fields the original leaves to the first
/// frame are set here too, so that no field is ever undefined.
fn initDCtxInternal(dctx: *DCtx, gpa: ?std.mem.Allocator) void {
    dctx.ll_tptr = &dctx.entropy.ll_table;
    dctx.ml_tptr = &dctx.entropy.ml_table;
    dctx.of_tptr = &dctx.entropy.of_table;
    dctx.huf_ptr = &dctx.entropy.huf_table;
    dctx.previous_dst_end = 0;
    dctx.prefix_start = 0;
    dctx.virtual_start = 0;
    dctx.dict_end = 0;
    dctx.expected = 0;
    dctx.f_params = .{};
    dctx.processed_csize = 0;
    dctx.decoded_size = 0;
    dctx.b_type = .reserved;
    dctx.stage = .get_frame_header_size;
    dctx.lit_entropy = false;
    dctx.fse_entropy = false;
    dctx.xxh_state = .init(0);
    dctx.header_size = 0;
    dctx.validate_checksum = false;
    dctx.lit_ptr = &dctx.lit_extra_buffer;
    dctx.custom_mem = gpa;
    dctx.lit_size = 0;
    dctx.rle_size = 0;
    dctx.static_size = 0;
    dctx.ddict = null;
    dctx.ddict_local = null;
    dctx.dict_id = 0;
    dctx.ddict_is_cold = false;
    dctx.dict_uses = .dont_use;
    dctx.in_buff = null;
    dctx.in_buff_size = 0;
    dctx.in_pos = 0;
    dctx.out_buff = &dctx.lit_extra_buffer;
    dctx.out_buff_size = 0;
    dctx.out_start = 0;
    dctx.out_end = 0;
    dctx.lh_size = 0;
    dctx.hostage_byte = false;
    dctx.stream_stage = .init;
    dctx.no_forward_progress = 0;
    dctx.expected_out_buffer = .{ .ptr = 0, .size = 0, .pos = 0 };
    dctx.lit_buffer = &dctx.lit_extra_buffer;
    dctx.lit_buffer_end = &dctx.lit_extra_buffer;
    dctx.lit_buffer_location = .not_in_dst;
    dctx.oversized_duration = 0;
    dctx.is_frame_decompression = true;
    dctx.ddict_set = null;
    resetParameters(dctx);
}

/// `ZSTD_initStaticDCtx`: a context placed in `workspace`, which also holds
/// its stream buffers; it never allocates. `workspace` must be aligned on 8
/// and hold at least `estimateDCtxSize()` bytes (`estimateDStreamSize*` for
/// streaming), and must outlive the context, which is never freed. Null
/// when `workspace` is too small or misaligned.
pub fn initStaticDCtx(workspace: []u8) ?*DCtx {
    if (@intFromPtr(workspace.ptr) & 7 != 0) return null;
    if (workspace.len < internal.dctx_object_size) return null;
    const dctx: *DCtx = @ptrCast(@alignCast(workspace.ptr));
    initDCtxInternal(dctx, null);
    dctx.static_size = workspace.len;
    dctx.in_buff = workspace.ptr + internal.dctx_object_size;
    return dctx;
}

/// A context in memory the caller owns, for `decompressFrameExact` and the
/// one-shot functions with no stream buffers: it behaves as a static
/// context with no room past itself, and never allocates. It holds no
/// resources, so it needs no freeing; it must not move during a frame.
pub fn initDCtx(dctx: *DCtx) void {
    initDCtxInternal(dctx, null);
    dctx.static_size = internal.dctx_object_size;
}

/// `ZSTD_createDCtx`: a context that allocates from `gpa`.
pub fn createDCtx(gpa: std.mem.Allocator) Error!*DCtx {
    const dctx = gpa.create(DCtx) catch return error.MemoryAllocation;
    initDCtxInternal(dctx, gpa);
    return dctx;
}

/// `ZSTD_clearDict`.
fn clearDict(dctx: *DCtx) void {
    ddict_impl.freeDDict(dctx.ddict_local);
    dctx.ddict_local = null;
    dctx.ddict = null;
    dctx.dict_uses = .dont_use;
}

/// `ZSTD_freeDCtx`: a static context cannot be freed
/// (`error.MemoryAllocation`).
pub fn freeDCtx(dctx: ?*DCtx) Error!void {
    const d = dctx orelse return;
    if (d.static_size != 0) return error.MemoryAllocation;
    const gpa = d.custom_mem.?;
    clearDict(d);
    if (d.in_buff) |buffer| gpa.free(buffer[0 .. d.in_buff_size + d.out_buff_size]);
    d.in_buff = null;
    if (d.ddict_set) |set| {
        freeDDictHashSet(set, gpa);
        d.ddict_set = null;
    }
    gpa.destroy(d);
}

/// `ZSTD_copyDCtx`: copies `src`'s state up to its stream buffers into
/// `dst`, as the original's copy of the bytes before `inBuff` does, so that
/// `dst` can go on with the same frame of the buffer-less API. Like the
/// original's, the copy refers to what `src` refers to: its local
/// dictionary, its allocator, and its tables when `src` decodes with
/// them; `src` must outlive what `dst` does with them, and only one of
/// the two may be freed with a local dictionary.
pub fn copyDCtx(dst: *DCtx, src: *const DCtx) void {
    dst.ll_tptr = src.ll_tptr;
    dst.ml_tptr = src.ml_tptr;
    dst.of_tptr = src.of_tptr;
    dst.huf_ptr = src.huf_ptr;
    dst.entropy = src.entropy;
    dst.workspace = src.workspace;
    dst.previous_dst_end = src.previous_dst_end;
    dst.prefix_start = src.prefix_start;
    dst.virtual_start = src.virtual_start;
    dst.dict_end = src.dict_end;
    dst.expected = src.expected;
    dst.f_params = src.f_params;
    dst.processed_csize = src.processed_csize;
    dst.decoded_size = src.decoded_size;
    dst.b_type = src.b_type;
    dst.stage = src.stage;
    dst.lit_entropy = src.lit_entropy;
    dst.fse_entropy = src.fse_entropy;
    dst.xxh_state = src.xxh_state;
    dst.header_size = src.header_size;
    dst.format = src.format;
    dst.force_ignore_checksum = src.force_ignore_checksum;
    dst.validate_checksum = src.validate_checksum;
    dst.lit_ptr = src.lit_ptr;
    dst.custom_mem = src.custom_mem;
    dst.lit_size = src.lit_size;
    dst.rle_size = src.rle_size;
    dst.static_size = src.static_size;
    dst.is_frame_decompression = src.is_frame_decompression;
    dst.ddict_local = src.ddict_local;
    dst.ddict = src.ddict;
    dst.dict_id = src.dict_id;
    dst.ddict_is_cold = src.ddict_is_cold;
    dst.dict_uses = src.dict_uses;
    dst.ddict_set = src.ddict_set;
    dst.ref_multiple_ddicts = src.ref_multiple_ddicts;
    dst.disable_huf_asm = src.disable_huf_asm;
    dst.max_block_size_param = src.max_block_size_param;
    dst.stream_stage = src.stream_stage;
}

/// `ZSTD_DCtx_selectFrameDDict`: with several dictionaries referenced, the
/// one with the frame's dictionary id.
fn selectFrameDDict(dctx: *DCtx) void {
    assert(dctx.ref_multiple_ddicts == .ref_multiple_ddicts and dctx.ddict_set != null);
    if (dctx.ddict != null) {
        if (hashSetGetDDict(dctx.ddict_set.?, dctx.f_params.dict_id)) |frame_ddict| {
            clearDict(dctx);
            dctx.dict_id = dctx.f_params.dict_id;
            dctx.ddict = frame_ddict;
            dctx.dict_uses = .use_indefinitely;
        }
    }
}

// --------------------------------------------------------
// Frame readers
// --------------------------------------------------------

/// `ZSTD_isFrame`: whether `buffer` starts with a frame's or a skippable
/// frame's magic number.
pub fn isFrame(buffer: []const u8) bool {
    if (buffer.len < frame_id_size) return false;
    const magic = readLE32(buffer);
    return magic == params.magic_number or isSkippableMagic(magic);
}

/// `ZSTD_isSkippableFrame`.
pub fn isSkippableFrame(buffer: []const u8) bool {
    if (buffer.len < frame_id_size) return false;
    return isSkippableMagic(readLE32(buffer));
}

/// `ZSTD_frameHeaderSize_internal`.
fn frameHeaderSizeInternal(src: []const u8, format: params.Format) Error!usize {
    const min_input_size = startingInputLength(format);
    if (src.len < min_input_size) return error.SrcSizeWrong;
    const fhd = src[min_input_size - 1];
    const dict_id = fhd & 3;
    const single_segment = (fhd >> 5) & 1;
    const fcs_id = fhd >> 6;
    return min_input_size + @intFromBool(single_segment == 0) + zstd_internal.did_field_size[dict_id] +
        zstd_internal.fcs_field_size[fcs_id] + @intFromBool(single_segment != 0 and fcs_id == 0);
}

/// `ZSTD_frameHeaderSize`: the size of the frame header at the start of
/// `src`, from its first 5 bytes.
pub fn frameHeaderSize(src: []const u8) Error!usize {
    return frameHeaderSizeInternal(src, .zstd1);
}

/// `ZSTD_getFrameHeader_advanced`: reads the frame header at the start of
/// `src` into `zfh`. Returns 0 when it is read, or the size `src` needs to
/// hold it, when it is larger than `src`.
pub fn getFrameHeaderAdvanced(zfh: *FrameHeader, src: []const u8, format: params.Format) Error!usize {
    const ip = src;
    const min_input_size = startingInputLength(format);

    if (src.len < min_input_size) {
        if (src.len > 0 and format != .zstd1_magicless) {
            // The bytes there are must start a magic number.
            const to_copy = @min(4, src.len);
            var hbuf: [4]u8 = undefined;
            std.mem.writeInt(u32, &hbuf, params.magic_number, .little);
            @memcpy(hbuf[0..to_copy], src[0..to_copy]);
            if (readLE32(&hbuf) != params.magic_number) {
                std.mem.writeInt(u32, &hbuf, params.magic_skippable_start, .little);
                @memcpy(hbuf[0..to_copy], src[0..to_copy]);
                if (!isSkippableMagic(readLE32(&hbuf))) return error.PrefixUnknown;
            }
        }
        return min_input_size;
    }

    zfh.* = .{};
    if (format != .zstd1_magicless and readLE32(src) != params.magic_number) {
        if (isSkippableMagic(readLE32(src))) {
            // The magic number and the frame's size.
            if (src.len < skippable_header_size) return skippable_header_size;
            zfh.* = .{};
            zfh.frame_type = .skippable_frame;
            zfh.dict_id = readLE32(src) - params.magic_skippable_start;
            zfh.header_size = skippable_header_size;
            zfh.frame_content_size = readLE32(src[frame_id_size..]);
            return 0;
        }
        return error.PrefixUnknown;
    }

    {
        const fhsize = try frameHeaderSizeInternal(src, format);
        if (src.len < fhsize) return fhsize;
        zfh.header_size = @intCast(fhsize);
    }

    const fhd_byte = ip[min_input_size - 1];
    var pos = min_input_size;
    const dict_id_size_code = fhd_byte & 3;
    const checksum_flag = (fhd_byte >> 2) & 1;
    const single_segment = (fhd_byte >> 5) & 1;
    const fcs_id = fhd_byte >> 6;
    var window_size: u64 = 0;
    var dict_id: u32 = 0;
    var frame_content_size: u64 = content_size_unknown;
    if (fhd_byte & 0x08 != 0) return error.FrameParameterUnsupported;

    if (single_segment == 0) {
        const wl_byte = ip[pos];
        pos += 1;
        const window_log: u32 = (wl_byte >> 3) + zstd_internal.window_log_absolute_min;
        if (window_log > params.window_log_max) return error.FrameParameterWindowTooLarge;
        window_size = @as(u64, 1) << @intCast(window_log);
        window_size += (window_size >> 3) * (wl_byte & 7);
    }
    switch (dict_id_size_code) {
        0 => {},
        1 => {
            dict_id = ip[pos];
            pos += 1;
        },
        2 => {
            dict_id = std.mem.readInt(u16, ip[pos..][0..2], .little);
            pos += 2;
        },
        3 => {
            dict_id = readLE32(ip[pos..]);
            pos += 4;
        },
        else => unreachable,
    }
    switch (fcs_id) {
        0 => if (single_segment != 0) {
            frame_content_size = ip[pos];
        },
        1 => frame_content_size = @as(u64, std.mem.readInt(u16, ip[pos..][0..2], .little)) + 256,
        2 => frame_content_size = readLE32(ip[pos..]),
        3 => frame_content_size = std.mem.readInt(u64, ip[pos..][0..8], .little),
        else => unreachable,
    }
    if (single_segment != 0) window_size = frame_content_size;

    zfh.frame_type = .frame;
    zfh.frame_content_size = frame_content_size;
    zfh.window_size = window_size;
    zfh.block_size_max = @intCast(@min(window_size, params.block_size_max));
    zfh.dict_id = dict_id;
    zfh.checksum_flag = checksum_flag != 0;
    return 0;
}

/// `ZSTD_getFrameHeader`.
pub fn getFrameHeader(zfh: *FrameHeader, src: []const u8) Error!usize {
    return getFrameHeaderAdvanced(zfh, src, .zstd1);
}

/// `ZSTD_getFrameContentSize`: the decoded size the frame header at the
/// start of `src` gives; `content_size_unknown` when it gives none, 0 for a
/// skippable frame, `content_size_error` when there is no valid header.
pub fn getFrameContentSize(src: []const u8) u64 {
    var zfh: FrameHeader = .{};
    const result = getFrameHeader(&zfh, src) catch return content_size_error;
    if (result != 0) return content_size_error;
    if (zfh.frame_type == .skippable_frame) return 0;
    return zfh.frame_content_size;
}

/// `readSkippableFrameSize`.
fn readSkippableFrameSize(src: []const u8) Error!usize {
    if (src.len < skippable_header_size) return error.SrcSizeWrong;
    const size_u32 = readLE32(src[frame_id_size..]);
    if (size_u32 +% skippable_header_size < size_u32) return error.FrameParameterUnsupported;
    const skippable_size = skippable_header_size + @as(usize, size_u32);
    if (skippable_size > src.len) return error.SrcSizeWrong;
    return skippable_size;
}

/// `ZSTD_readSkippableFrame`: copies the content of the skippable frame at
/// the start of `src` into `dst`; returns its size, and its magic variant
/// in `magic_variant` when given.
pub fn readSkippableFrame(dst: []u8, magic_variant: ?*u32, src: []const u8) Error!usize {
    if (src.len < skippable_header_size) return error.SrcSizeWrong;
    const magic_number = readLE32(src);
    const skippable_frame_size = try readSkippableFrameSize(src);
    const skippable_content_size = skippable_frame_size - skippable_header_size;
    if (!isSkippableFrame(src)) return error.FrameParameterUnsupported;
    if (skippable_frame_size < skippable_header_size or skippable_frame_size > src.len) return error.SrcSizeWrong;
    if (skippable_content_size > dst.len) return error.DstSizeTooSmall;
    if (skippable_content_size > 0) {
        @memcpy(dst[0..skippable_content_size], src[skippable_header_size..][0..skippable_content_size]);
    }
    if (magic_variant) |variant| variant.* = magic_number - params.magic_skippable_start;
    return skippable_content_size;
}

/// `ZSTD_findDecompressedSize`: the sum of the content sizes of every frame
/// in `src`, which must be whole frames; `content_size_unknown` when one
/// does not say, `content_size_error` on an invalid frame or a sum that
/// overflows.
pub fn findDecompressedSize(src_in: []const u8) u64 {
    var src = src_in;
    var total_dst_size: u64 = 0;
    while (src.len >= startingInputLength(.zstd1)) {
        const magic_number = readLE32(src);
        if (isSkippableMagic(magic_number)) {
            const skippable_size = readSkippableFrameSize(src) catch return content_size_error;
            src = src[skippable_size..];
            continue;
        }
        const fcs = getFrameContentSize(src);
        if (fcs >= content_size_error) return fcs;
        if (total_dst_size +% fcs < total_dst_size) return content_size_error;
        total_dst_size += fcs;
        const frame_src_size = findFrameCompressedSize(src) catch return content_size_error;
        src = src[frame_src_size..];
    }
    if (src.len != 0) return content_size_error;
    return total_dst_size;
}

/// `ZSTD_getDecompressedSize`: `getFrameContentSize`, with 0 for an
/// unknown size or an error.
pub fn getDecompressedSize(src: []const u8) u64 {
    const ret = getFrameContentSize(src);
    return if (ret >= content_size_error) 0 else ret;
}

/// `ZSTD_decodeFrameHeader`: reads the header of `dctx`'s frame; `src` is
/// the whole header.
fn decodeFrameHeader(dctx: *DCtx, src: []const u8) Error!void {
    const result = try getFrameHeaderAdvanced(&dctx.f_params, src, dctx.format);
    if (result > 0) return error.SrcSizeWrong;

    // With several dictionaries referenced, the frame picks its own.
    if (dctx.ref_multiple_ddicts == .ref_multiple_ddicts and dctx.ddict_set != null) {
        selectFrameDDict(dctx);
    }
    if (dctx.f_params.dict_id != 0 and dctx.dict_id != dctx.f_params.dict_id) return error.DictionaryWrong;

    dctx.validate_checksum = dctx.f_params.checksum_flag and dctx.force_ignore_checksum == .validate_checksum;
    if (dctx.validate_checksum) dctx.xxh_state = .init(0);
    dctx.processed_csize += src.len;
}

/// `ZSTD_frameSizeInfo`.
const FrameSizeInfo = struct {
    nb_blocks: usize = 0,
    compressed_size: Error!usize = 0,
    decompressed_bound: u64 = 0,
};

fn errorFrameSizeInfo(err: Error) FrameSizeInfo {
    return .{ .compressed_size = err, .decompressed_bound = content_size_error };
}

/// `ZSTD_findFrameSizeInfo`: the size of the frame at the start of `src`,
/// its number of blocks, and a bound on its decoded size.
fn findFrameSizeInfo(src: []const u8, format: params.Format) FrameSizeInfo {
    if (format == .zstd1 and src.len >= skippable_header_size and isSkippableMagic(readLE32(src))) {
        return .{ .compressed_size = readSkippableFrameSize(src) };
    }
    var ip: usize = 0;
    var remaining_size = src.len;
    var nb_blocks: usize = 0;
    var zfh: FrameHeader = .{};
    {
        const ret = getFrameHeaderAdvanced(&zfh, src, format) catch |err| return errorFrameSizeInfo(err);
        if (ret > 0) return errorFrameSizeInfo(error.SrcSizeWrong);
    }
    ip += zfh.header_size;
    remaining_size -= zfh.header_size;

    // Every block.
    while (true) {
        var block_properties: block.BlockProperties = undefined;
        const c_block_size = block.getcBlockSize(src[ip..], &block_properties) catch |err|
            return errorFrameSizeInfo(err);
        if (block_header_size + c_block_size > remaining_size) return errorFrameSizeInfo(error.SrcSizeWrong);
        ip += block_header_size + c_block_size;
        remaining_size -= block_header_size + c_block_size;
        nb_blocks += 1;
        if (block_properties.last_block) break;
    }

    // The checksum.
    if (zfh.checksum_flag) {
        if (remaining_size < 4) return errorFrameSizeInfo(error.SrcSizeWrong);
        ip += 4;
    }

    return .{
        .nb_blocks = nb_blocks,
        .compressed_size = ip,
        .decompressed_bound = if (zfh.frame_content_size != content_size_unknown)
            zfh.frame_content_size
        else
            @as(u64, nb_blocks) * zfh.block_size_max,
    };
}

fn findFrameCompressedSizeAdvanced(src: []const u8, format: params.Format) Error!usize {
    return findFrameSizeInfo(src, format).compressed_size;
}

/// `ZSTD_findFrameCompressedSize`: the size of the frame, or skippable
/// frame, at the start of `src`.
pub fn findFrameCompressedSize(src: []const u8) Error!usize {
    return findFrameCompressedSizeAdvanced(src, .zstd1);
}

/// `ZSTD_decompressBound`: an upper bound on the decoded size of the
/// frames in `src`, which must be whole frames; `content_size_error` when
/// one is invalid.
pub fn decompressBound(src_in: []const u8) u64 {
    var src = src_in;
    var bound: u64 = 0;
    while (src.len > 0) {
        const info = findFrameSizeInfo(src, .zstd1);
        const compressed_size = info.compressed_size catch return content_size_error;
        if (info.decompressed_bound == content_size_error) return content_size_error;
        src = src[compressed_size..];
        bound +%= info.decompressed_bound;
    }
    return bound;
}

/// `ZSTD_decompressionMargin`: how much larger than the decoded size a
/// buffer must be to decode the frames in `src` in place, with `src` at
/// its end.
pub fn decompressionMargin(src_in: []const u8) Error!usize {
    var src = src_in;
    var margin: usize = 0;
    var max_block_size: u32 = 0;
    while (src.len > 0) {
        const info = findFrameSizeInfo(src, .zstd1);
        var zfh: FrameHeader = .{};
        _ = try getFrameHeader(&zfh, src);
        const compressed_size = info.compressed_size catch return error.CorruptionDetected;
        if (info.decompressed_bound == content_size_error) return error.CorruptionDetected;
        if (zfh.frame_type == .frame) {
            // The frame's header, checksum and block headers, and its
            // largest block.
            margin += zfh.header_size;
            margin += if (zfh.checksum_flag) 4 else 0;
            margin += 3 * info.nb_blocks;
            max_block_size = @max(max_block_size, zfh.block_size_max);
        } else {
            assert(zfh.frame_type == .skippable_frame);
            margin += compressed_size;
        }
        src = src[compressed_size..];
    }
    margin += max_block_size;
    return margin;
}

// --------------------------------------------------------
// Frame decompression
// --------------------------------------------------------

/// `ZSTD_insertBlock`: adds a block the caller stored uncompressed to the
/// window, for the next `decompressBlock`.
pub fn insertBlock(dctx: *DCtx, block_start: []const u8) usize {
    block.checkContinuity(dctx, block_start.ptr, block_start.len);
    dctx.previous_dst_end = @intFromPtr(block_start.ptr) + block_start.len;
    return block_start.len;
}

/// `ZSTD_copyRawBlock`.
fn copyRawBlock(dst: []u8, src: []const u8) Error!usize {
    if (src.len > dst.len) return error.DstSizeTooSmall;
    @memmove(dst[0..src.len], src);
    return src.len;
}

/// `ZSTD_setRleBlock`.
fn setRleBlock(dst: []u8, b: u8, regen_size: usize) Error!usize {
    if (regen_size > dst.len) return error.DstSizeTooSmall;
    @memset(dst[0..regen_size], b);
    return regen_size;
}

/// `ZSTD_decompressFrame`: decodes the frame at the start of `src_ptr.*`
/// into `dst`, and moves `src_ptr` past it.
fn decompressFrame(dctx: *DCtx, dst: []u8, src_ptr: *[]const u8) Error!usize {
    const istart = src_ptr.*;
    var ip: usize = 0;
    var op: usize = 0;
    var remaining_src_size = istart.len;

    // The header, with at least one block header after it.
    if (remaining_src_size < params.frameHeaderSizeMin(dctx.format) + block_header_size) return error.SrcSizeWrong;
    {
        const frame_header_size = try frameHeaderSizeInternal(istart[0..frameHeaderSizePrefix(dctx.format)], dctx.format);
        if (remaining_src_size < frame_header_size + block_header_size) return error.SrcSizeWrong;
        try decodeFrameHeader(dctx, istart[0..frame_header_size]);
        ip += frame_header_size;
        remaining_src_size -= frame_header_size;
    }

    if (dctx.max_block_size_param != 0) {
        dctx.f_params.block_size_max = @min(dctx.f_params.block_size_max, @as(u32, @intCast(dctx.max_block_size_param)));
    }

    // Every block.
    while (true) {
        var o_block_end = dst.len;
        var block_properties: block.BlockProperties = undefined;
        const c_block_size = try block.getcBlockSize(istart[ip..], &block_properties);
        ip += block_header_size;
        remaining_src_size -= block_header_size;
        if (c_block_size > remaining_src_size) return error.SrcSizeWrong;

        // Decoding in place: the block must not write past the input it
        // has not read yet.
        const ip_addr = @intFromPtr(istart.ptr) + ip;
        const op_addr = @intFromPtr(dst.ptr) + op;
        if (ip_addr >= op_addr and ip_addr < @intFromPtr(dst.ptr) + o_block_end) {
            o_block_end = op + (ip_addr - op_addr);
        }

        const block_src = istart[ip..][0..c_block_size];
        const decoded_size = switch (block_properties.block_type) {
            .compressed => blk: {
                assert(dctx.is_frame_decompression);
                break :blk try block.decompressBlockInternal(dctx, dst[op..o_block_end], block_src, .not_streaming);
            },
            .raw => try copyRawBlock(dst[op..], block_src),
            .rle => try setRleBlock(dst[op..o_block_end], block_src[0], block_properties.orig_size),
            .reserved => return error.CorruptionDetected,
        };
        if (dctx.validate_checksum) dctx.xxh_state.update(dst[op..][0..decoded_size]);
        op += decoded_size;
        ip += c_block_size;
        remaining_src_size -= c_block_size;
        if (block_properties.last_block) break;
    }

    if (dctx.f_params.frame_content_size != content_size_unknown) {
        if (op != dctx.f_params.frame_content_size) return error.CorruptionDetected;
    }
    if (dctx.f_params.checksum_flag) {
        // The checksum.
        if (remaining_src_size < 4) return error.ChecksumWrong;
        if (dctx.force_ignore_checksum == .validate_checksum) {
            const check_calc: u32 = @truncate(dctx.xxh_state.final());
            const check_read = readLE32(istart[ip..]);
            if (check_read != check_calc) return error.ChecksumWrong;
        }
        ip += 4;
        remaining_src_size -= 4;
    }
    src_ptr.* = istart[ip..];
    return op;
}

/// `ZSTD_decompressMultiFrame`: decodes every frame in `src`, skipping
/// skippable frames, each with `dict` or `ddict`.
fn decompressMultiFrame(
    dctx: *DCtx,
    dst_in: []u8,
    src_in: []const u8,
    dict_in: []const u8,
    ddict: ?*const DDict,
) Error!usize {
    var dst = dst_in;
    var src = src_in;
    var dict = dict_in;
    var more_than_1_frame = false;
    assert(dict.len == 0 or ddict == null);
    if (ddict) |d| dict = d.dict_content;

    while (src.len >= startingInputLength(dctx.format)) {
        if (dctx.format == .zstd1 and src.len >= 4) {
            const magic_number = readLE32(src);
            if (isSkippableMagic(magic_number)) {
                const skippable_size = try readSkippableFrameSize(src);
                src = src[skippable_size..];
                continue;
            }
        }
        if (ddict) |d| {
            try decompressBeginUsingDDict(dctx, d);
        } else {
            try decompressBeginUsingDict(dctx, dict);
        }
        block.checkContinuity(dctx, dst.ptr, dst.len);

        const res = decompressFrame(dctx, dst, &src) catch |err| {
            // After a whole frame, bytes that are not a frame more likely
            // mean a wrong size than corruption.
            if (err == error.PrefixUnknown and more_than_1_frame) return error.SrcSizeWrong;
            return err;
        };
        assert(res <= dst.len);
        dst = dst[res..];
        more_than_1_frame = true;
    }
    if (src.len != 0) return error.SrcSizeWrong;
    return @intFromPtr(dst.ptr) - @intFromPtr(dst_in.ptr);
}

/// `ZSTD_decompress_usingDict`: decodes the frames in `src` with `dict`, a
/// full dictionary or raw content, which may be empty.
pub fn decompressUsingDict(dctx: *DCtx, dst: []u8, src: []const u8, dict: []const u8) Error!usize {
    return decompressMultiFrame(dctx, dst, src, dict, null);
}

/// `ZSTD_getDDict`: the dictionary for the next frame, by its uses.
fn getDDict(dctx: *DCtx) ?*const DDict {
    switch (dctx.dict_uses) {
        .dont_use => {
            clearDict(dctx);
            return null;
        },
        .use_indefinitely => return dctx.ddict,
        .use_once => {
            dctx.dict_uses = .dont_use;
            return dctx.ddict;
        },
    }
}

/// `ZSTD_decompressDCtx`: decodes the frames in `src` into `dst` with the
/// context's dictionary; returns the decoded size.
pub fn decompressDCtx(dctx: *DCtx, dst: []u8, src: []const u8) Error!usize {
    return decompressUsingDDict(dctx, dst, src, getDDict(dctx));
}

/// `ZSTD_decompress`: decodes the frames in `src` into `dst`, with a
/// context from `gpa` (the original's default heap mode); returns the
/// decoded size.
pub fn decompress(gpa: std.mem.Allocator, dst: []u8, src: []const u8) Error!usize {
    const dctx = try createDCtx(gpa);
    defer freeDCtx(dctx) catch unreachable;
    return decompressDCtx(dctx, dst, src);
}

// --------------------------------------------------------
// Buffer-less decompression
// --------------------------------------------------------

/// `ZSTD_nextSrcSizeToDecompress`: the bytes the next `decompressContinue`
/// takes.
pub fn nextSrcSizeToDecompress(dctx: *const DCtx) usize {
    return dctx.expected;
}

/// `ZSTD_nextSrcSizeToDecompressWithInputSize`: as `nextSrcSizeToDecompress`,
/// but a raw block may be taken in pieces.
fn nextSrcSizeToDecompressWithInputSize(dctx: *const DCtx, input_size: usize) usize {
    if (!(dctx.stage == .decompress_block or dctx.stage == .decompress_last_block)) return dctx.expected;
    if (dctx.b_type != .raw) return dctx.expected;
    return std.math.clamp(input_size, 1, dctx.expected);
}

/// `ZSTD_nextInputType`.
pub fn nextInputType(dctx: *const DCtx) params.NextInputType {
    return switch (dctx.stage) {
        .get_frame_header_size, .decode_frame_header => .frame_header,
        .decode_block_header => .block_header,
        .decompress_block => .block,
        .decompress_last_block => .last_block,
        .check_checksum => .checksum,
        .decode_skippable_header, .skip_frame => .skippable_frame,
    };
}

fn isSkipFrame(dctx: *const DCtx) bool {
    return dctx.stage == .skip_frame;
}

/// `ZSTD_decompressContinue`: takes exactly `nextSrcSizeToDecompress()`
/// bytes (or part of a raw block), and returns the bytes it wrote to
/// `dst`, maybe 0. Earlier outputs of the frame are its window, and must
/// stay where they are.
pub fn decompressContinue(dctx: *DCtx, dst: []u8, src: []const u8) Error!usize {
    if (src.len != nextSrcSizeToDecompressWithInputSize(dctx, src.len)) return error.SrcSizeWrong;
    block.checkContinuity(dctx, dst.ptr, dst.len);
    dctx.processed_csize += src.len;

    switch (dctx.stage) {
        .get_frame_header_size => {
            if (dctx.format == .zstd1) {
                assert(src.len >= frame_id_size);
                if (isSkippableMagic(readLE32(src))) {
                    @memcpy(dctx.header_buffer[0..src.len], src);
                    // The rest of the skippable frame's header.
                    dctx.expected = skippable_header_size - src.len;
                    dctx.stage = .decode_skippable_header;
                    return 0;
                }
            }
            dctx.header_size = try frameHeaderSizeInternal(src, dctx.format);
            @memcpy(dctx.header_buffer[0..src.len], src);
            dctx.expected = dctx.header_size - src.len;
            dctx.stage = .decode_frame_header;
            return 0;
        },
        .decode_frame_header => {
            @memcpy(dctx.header_buffer[dctx.header_size - src.len ..][0..src.len], src);
            try decodeFrameHeader(dctx, dctx.header_buffer[0..dctx.header_size]);
            dctx.expected = block_header_size;
            dctx.stage = .decode_block_header;
            return 0;
        },
        .decode_block_header => {
            var bp: block.BlockProperties = undefined;
            const c_block_size = try block.getcBlockSize(src[0..block_header_size], &bp);
            if (c_block_size > dctx.f_params.block_size_max) return error.CorruptionDetected;
            dctx.expected = c_block_size;
            dctx.b_type = bp.block_type;
            dctx.rle_size = bp.orig_size;
            if (c_block_size != 0) {
                dctx.stage = if (bp.last_block) .decompress_last_block else .decompress_block;
                return 0;
            }
            // An empty block.
            if (bp.last_block) {
                if (dctx.f_params.checksum_flag) {
                    dctx.expected = 4;
                    dctx.stage = .check_checksum;
                } else {
                    // The end of the frame.
                    dctx.expected = 0;
                    dctx.stage = .get_frame_header_size;
                }
            } else {
                // The next block's header.
                dctx.expected = block_header_size;
                dctx.stage = .decode_block_header;
            }
            return 0;
        },
        .decompress_last_block, .decompress_block => {
            const r_size: usize = switch (dctx.b_type) {
                .compressed => blk: {
                    assert(dctx.is_frame_decompression);
                    const size = try block.decompressBlockInternal(dctx, dst, src, .is_streaming);
                    // A compressed block is taken whole.
                    dctx.expected = 0;
                    break :blk size;
                },
                .raw => blk: {
                    assert(src.len <= dctx.expected);
                    const size = try copyRawBlock(dst, src);
                    assert(size == src.len);
                    dctx.expected -= size;
                    break :blk size;
                },
                .rle => blk: {
                    const size = try setRleBlock(dst, src[0], dctx.rle_size);
                    dctx.expected = 0;
                    break :blk size;
                },
                .reserved => return error.CorruptionDetected,
            };
            if (r_size > dctx.f_params.block_size_max) return error.CorruptionDetected;
            dctx.decoded_size += r_size;
            if (dctx.validate_checksum) dctx.xxh_state.update(dst[0..r_size]);
            dctx.previous_dst_end = @intFromPtr(dst.ptr) + r_size;

            // More of a raw block to come.
            if (dctx.expected > 0) return r_size;

            if (dctx.stage == .decompress_last_block) {
                // The end of the frame.
                if (dctx.f_params.frame_content_size != content_size_unknown and
                    dctx.decoded_size != dctx.f_params.frame_content_size) return error.CorruptionDetected;
                if (dctx.f_params.checksum_flag) {
                    // Another round for the checksum.
                    dctx.expected = 4;
                    dctx.stage = .check_checksum;
                } else {
                    dctx.expected = 0;
                    dctx.stage = .get_frame_header_size;
                }
            } else {
                dctx.stage = .decode_block_header;
                dctx.expected = block_header_size;
            }
            return r_size;
        },
        .check_checksum => {
            assert(src.len == 4);
            if (dctx.validate_checksum) {
                const h32: u32 = @truncate(dctx.xxh_state.final());
                const check32 = readLE32(src);
                if (check32 != h32) return error.ChecksumWrong;
            }
            dctx.expected = 0;
            dctx.stage = .get_frame_header_size;
            return 0;
        },
        .decode_skippable_header => {
            assert(src.len <= skippable_header_size);
            assert(dctx.format != .zstd1_magicless);
            // The rest of the skippable frame's header.
            @memcpy(dctx.header_buffer[skippable_header_size - src.len ..][0..src.len], src);
            // Can be far larger than any buffer.
            dctx.expected = readLE32(dctx.header_buffer[frame_id_size..]);
            dctx.stage = .skip_frame;
            return 0;
        },
        .skip_frame => {
            dctx.expected = 0;
            dctx.stage = .get_frame_header_size;
            return 0;
        },
    }
}

/// `ZSTD_refDictContent`: `dict` becomes the segment before the frame.
fn refDictContent(dctx: *DCtx, dict: []const u8) void {
    dctx.dict_end = dctx.previous_dst_end;
    dctx.virtual_start = @intFromPtr(dict.ptr) -% (dctx.previous_dst_end -% dctx.prefix_start);
    dctx.prefix_start = @intFromPtr(dict.ptr);
    dctx.previous_dst_end = @intFromPtr(dict.ptr) + dict.len;
}

/// `ZSTD_loadDEntropy`: reads a full dictionary's tables and repeat
/// offsets into `entropy`; returns the size of its header (magic number,
/// id and tables). `dict` starts with the dictionary magic number.
pub fn loadDEntropy(entropy: *internal.EntropyDTables, dict: []const u8) Error!usize {
    if (dict.len <= 8) return error.DictionaryCorrupted;
    assert(readLE32(dict) == params.magic_dictionary);
    // After the magic number and the dictionary id.
    var dict_ptr: usize = 8;

    {
        // The sequence tables are the workspace.
        const workspace = entropy.seqTablesAsWorkspace();
        const h_size = huf_decompress.readDTableX2Wksp(&entropy.huf_table, dict[dict_ptr..], workspace) catch
            return error.DictionaryCorrupted;
        dict_ptr += h_size;
    }
    {
        var offcode_ncount: [internal.max_off + 1]i16 = undefined;
        var offcode_max_value: u32 = internal.max_off;
        var offcode_log: u32 = undefined;
        const offcode_header_size = entropy_common.readNCount(&offcode_ncount, &offcode_max_value, &offcode_log, dict[dict_ptr..]) catch
            return error.DictionaryCorrupted;
        if (offcode_max_value > internal.max_off) return error.DictionaryCorrupted;
        if (offcode_log > zstd_internal.off_fse_log) return error.DictionaryCorrupted;
        block.buildFSETable(&entropy.of_table, &offcode_ncount, offcode_max_value, &internal.of_base, &internal.of_bits, offcode_log, &entropy.workspace);
        dict_ptr += offcode_header_size;
    }
    {
        var matchlength_ncount: [internal.max_ml + 1]i16 = undefined;
        var matchlength_max_value: u32 = internal.max_ml;
        var matchlength_log: u32 = undefined;
        const matchlength_header_size = entropy_common.readNCount(&matchlength_ncount, &matchlength_max_value, &matchlength_log, dict[dict_ptr..]) catch
            return error.DictionaryCorrupted;
        if (matchlength_max_value > internal.max_ml) return error.DictionaryCorrupted;
        if (matchlength_log > zstd_internal.ml_fse_log) return error.DictionaryCorrupted;
        block.buildFSETable(&entropy.ml_table, &matchlength_ncount, matchlength_max_value, &internal.ml_base, &zstd_internal.ml_bits, matchlength_log, &entropy.workspace);
        dict_ptr += matchlength_header_size;
    }
    {
        var litlength_ncount: [internal.max_ll + 1]i16 = undefined;
        var litlength_max_value: u32 = internal.max_ll;
        var litlength_log: u32 = undefined;
        const litlength_header_size = entropy_common.readNCount(&litlength_ncount, &litlength_max_value, &litlength_log, dict[dict_ptr..]) catch
            return error.DictionaryCorrupted;
        if (litlength_max_value > internal.max_ll) return error.DictionaryCorrupted;
        if (litlength_log > zstd_internal.ll_fse_log) return error.DictionaryCorrupted;
        block.buildFSETable(&entropy.ll_table, &litlength_ncount, litlength_max_value, &internal.ll_base, &zstd_internal.ll_bits, litlength_log, &entropy.workspace);
        dict_ptr += litlength_header_size;
    }

    if (dict_ptr + 12 > dict.len) return error.DictionaryCorrupted;
    const dict_content_size = dict.len - (dict_ptr + 12);
    for (&entropy.rep) |*rep| {
        const value = readLE32(dict[dict_ptr..]);
        dict_ptr += 4;
        if (value == 0 or value > dict_content_size) return error.DictionaryCorrupted;
        rep.* = value;
    }
    return dict_ptr;
}

/// `ZSTD_decompress_insertDictionary`.
fn insertDictionary(dctx: *DCtx, dict_in: []const u8) Error!void {
    var dict = dict_in;
    if (dict.len < 8) return refDictContent(dctx, dict);
    if (readLE32(dict) != params.magic_dictionary) {
        // Raw content.
        return refDictContent(dctx, dict);
    }
    dctx.dict_id = readLE32(dict[frame_id_size..]);

    // The tables.
    const e_size = loadDEntropy(&dctx.entropy, dict) catch return error.DictionaryCorrupted;
    dict = dict[e_size..];
    dctx.lit_entropy = true;
    dctx.fse_entropy = true;

    // The content.
    refDictContent(dctx, dict);
}

/// `ZSTD_decompressBegin`: starts a frame of the buffer-less API, with no
/// dictionary.
pub fn decompressBegin(dctx: *DCtx) Error!void {
    dctx.expected = startingInputLength(dctx.format);
    dctx.stage = .get_frame_header_size;
    dctx.processed_csize = 0;
    dctx.decoded_size = 0;
    dctx.previous_dst_end = 0;
    dctx.prefix_start = 0;
    dctx.virtual_start = 0;
    dctx.dict_end = 0;
    dctx.entropy.huf_table[0] = internal.EntropyDTables.huf_table_init;
    dctx.lit_entropy = false;
    dctx.fse_entropy = false;
    dctx.dict_id = 0;
    dctx.b_type = .reserved;
    dctx.is_frame_decompression = true;
    dctx.entropy.rep = zstd_internal.rep_start_value;
    dctx.ll_tptr = &dctx.entropy.ll_table;
    dctx.ml_tptr = &dctx.entropy.ml_table;
    dctx.of_tptr = &dctx.entropy.of_table;
    dctx.huf_ptr = &dctx.entropy.huf_table;
}

/// `ZSTD_decompressBegin_usingDict`: with `dict` as the frame's dictionary;
/// it must stay where it is until the frame ends.
pub fn decompressBeginUsingDict(dctx: *DCtx, dict: []const u8) Error!void {
    try decompressBegin(dctx);
    if (dict.len != 0) insertDictionary(dctx, dict) catch return error.DictionaryCorrupted;
}

/// `ZSTD_decompressBegin_usingDDict`: with `ddict`, or none when null.
pub fn decompressBeginUsingDDict(dctx: *DCtx, ddict: ?*const DDict) Error!void {
    if (ddict) |d| {
        const dict_end = @intFromPtr(d.dict_content.ptr) + d.dict_content.len;
        // A dictionary the context did not end with is presumed cold.
        dctx.ddict_is_cold = dctx.dict_end != dict_end;
    }
    try decompressBegin(dctx);
    if (ddict) |d| ddict_impl.copyDDictParameters(dctx, d);
}

/// `ZSTD_getDictID_fromDict`: the id of a full dictionary, else 0.
pub fn getDictIdFromDict(dict: []const u8) u32 {
    if (dict.len < 8) return 0;
    if (readLE32(dict) != params.magic_dictionary) return 0;
    return readLE32(dict[frame_id_size..]);
}

/// `ZSTD_getDictID_fromFrame`: the dictionary id in the frame header at the
/// start of `src`, or 0 when there is none or the header is not whole.
pub fn getDictIdFromFrame(src: []const u8) u32 {
    var zfp: FrameHeader = .{};
    _ = getFrameHeader(&zfp, src) catch return 0;
    return zfp.dict_id;
}

/// `ZSTD_decompress_usingDDict`: decodes the frames in `src` with `ddict`,
/// or none when null.
pub fn decompressUsingDDict(dctx: *DCtx, dst: []u8, src: []const u8, ddict: ?*const DDict) Error!usize {
    return decompressMultiFrame(dctx, dst, src, &.{}, ddict);
}

// --------------------------------------------------------
// Dictionaries and parameters
// --------------------------------------------------------

/// `ZSTD_DStreamInSize`, `ZSTD_DStreamOutSize`: buffer sizes that suit
/// streaming.
pub fn dStreamInSize() usize {
    return params.block_size_max + block_header_size;
}
pub fn dStreamOutSize() usize {
    return params.block_size_max;
}

/// `ZSTD_DCtx_loadDictionary_advanced`: the dictionary for every frame
/// until it is replaced, digested into a local `DDict`. With `by_ref`,
/// `dict` must outlive its use. An empty `dict` clears the dictionary.
pub fn loadDictionaryAdvanced(
    dctx: *DCtx,
    dict: []const u8,
    dict_load_method: params.DictLoadMethod,
    dict_content_type: params.DictContentType,
) Error!void {
    if (dctx.stream_stage != .init) return error.StageWrong;
    clearDict(dctx);
    if (dict.len != 0) {
        const gpa = dctx.custom_mem orelse return error.MemoryAllocation;
        dctx.ddict_local = ddict_impl.createDDictAdvanced(gpa, dict, dict_load_method, dict_content_type) catch
            return error.MemoryAllocation;
        dctx.ddict = dctx.ddict_local;
        dctx.dict_uses = .use_indefinitely;
    }
}

/// `ZSTD_DCtx_loadDictionary_byReference`.
pub fn loadDictionaryByReference(dctx: *DCtx, dict: []const u8) Error!void {
    return loadDictionaryAdvanced(dctx, dict, .by_ref, .auto);
}

/// `ZSTD_DCtx_loadDictionary`: `dict` copied.
pub fn loadDictionary(dctx: *DCtx, dict: []const u8) Error!void {
    return loadDictionaryAdvanced(dctx, dict, .by_copy, .auto);
}

/// `ZSTD_DCtx_refPrefix_advanced`: `prefix` as the dictionary of the next
/// frame only; it must outlive that frame.
pub fn refPrefixAdvanced(dctx: *DCtx, prefix: []const u8, dict_content_type: params.DictContentType) Error!void {
    try loadDictionaryAdvanced(dctx, prefix, .by_ref, dict_content_type);
    dctx.dict_uses = .use_once;
}

/// `ZSTD_DCtx_refPrefix`: raw content.
pub fn refPrefix(dctx: *DCtx, prefix: []const u8) Error!void {
    return refPrefixAdvanced(dctx, prefix, .raw_content);
}

/// `ZSTD_initDStream_usingDict`.
pub fn initDStreamUsingDict(dctx: *DCtx, dict: []const u8) Error!usize {
    try reset(dctx, .session_only);
    try loadDictionary(dctx, dict);
    return startingInputLength(dctx.format);
}

/// `ZSTD_initDStream`.
pub fn initDStream(dctx: *DCtx) Error!usize {
    try reset(dctx, .session_only);
    try refDDict(dctx, null);
    return startingInputLength(dctx.format);
}

/// `ZSTD_initDStream_usingDDict`.
pub fn initDStreamUsingDDict(dctx: *DCtx, ddict: ?*const DDict) Error!usize {
    try reset(dctx, .session_only);
    try refDDict(dctx, ddict);
    return startingInputLength(dctx.format);
}

/// `ZSTD_resetDStream`.
pub fn resetDStream(dctx: *DCtx) Error!usize {
    try reset(dctx, .session_only);
    return startingInputLength(dctx.format);
}

/// `ZSTD_DCtx_refDDict`: `ddict` for every frame until replaced, or none
/// when null; it must outlive its use. With `ref_multiple_ddicts`, it is
/// added to the context's set, and each frame takes the one with its id.
pub fn refDDict(dctx: *DCtx, ddict: ?*const DDict) Error!void {
    if (dctx.stream_stage != .init) return error.StageWrong;
    clearDict(dctx);
    if (ddict) |d| {
        dctx.ddict = d;
        dctx.dict_uses = .use_indefinitely;
        if (dctx.ref_multiple_ddicts == .ref_multiple_ddicts) {
            // A static context cannot have set the parameter.
            const gpa = dctx.custom_mem.?;
            if (dctx.ddict_set == null) {
                dctx.ddict_set = createDDictHashSet(gpa) orelse return error.MemoryAllocation;
            }
            try hashSetAddDDict(dctx.ddict_set.?, d, gpa);
        }
    }
}

/// `ZSTD_DCtx_setMaxWindowSize`.
pub fn setMaxWindowSize(dctx: *DCtx, max_window_size: usize) Error!void {
    const bounds = dParamGetBounds(.window_log_max) catch unreachable;
    const min = @as(usize, 1) << @intCast(bounds.lower);
    const max = @as(usize, 1) << @intCast(bounds.upper);
    if (dctx.stream_stage != .init) return error.StageWrong;
    if (max_window_size < min) return error.ParameterOutOfBound;
    if (max_window_size > max) return error.ParameterOutOfBound;
    dctx.max_window_size = max_window_size;
}

/// `ZSTD_DCtx_setFormat`.
pub fn setFormat(dctx: *DCtx, format: params.Format) Error!void {
    return setParameter(dctx, .format, @intCast(@backingInt(format)));
}

/// `ZSTD_dParam_getBounds`.
pub fn dParamGetBounds(d_param: params.DParameter) Error!params.Bounds {
    return switch (d_param) {
        .window_log_max => .{ .lower = zstd_internal.window_log_absolute_min, .upper = params.window_log_max },
        .format => .{ .lower = 0, .upper = 1 },
        .stable_out_buffer => .{ .lower = 0, .upper = 1 },
        .force_ignore_checksum => .{ .lower = 0, .upper = 1 },
        .ref_multiple_ddicts => .{ .lower = 0, .upper = 1 },
        .disable_huffman_assembly => .{ .lower = 0, .upper = 1 },
        .max_block_size => .{ .lower = params.block_size_max_min, .upper = params.block_size_max },
    };
}

fn checkDBounds(d_param: params.DParameter, value: i32) Error!void {
    const bounds = try dParamGetBounds(d_param);
    if (value < bounds.lower or value > bounds.upper) return error.ParameterOutOfBound;
}

/// `ZSTD_DCtx_getParameter`.
pub fn getParameter(dctx: *const DCtx, param: params.DParameter) Error!i32 {
    return switch (param) {
        .window_log_max => @intCast(bitstream.highbit32(@truncate(dctx.max_window_size))),
        .format => @intCast(@backingInt(dctx.format)),
        .stable_out_buffer => @as(i32, @backingInt(dctx.out_buffer_mode)),
        .force_ignore_checksum => @intCast(@backingInt(dctx.force_ignore_checksum)),
        .ref_multiple_ddicts => @intCast(@backingInt(dctx.ref_multiple_ddicts)),
        .disable_huffman_assembly => @intFromBool(dctx.disable_huf_asm),
        .max_block_size => dctx.max_block_size_param,
    };
}

/// `ZSTD_DCtx_setParameter`: only between frames.
pub fn setParameter(dctx: *DCtx, d_param: params.DParameter, value_in: i32) Error!void {
    var value = value_in;
    if (dctx.stream_stage != .init) return error.StageWrong;
    switch (d_param) {
        .window_log_max => {
            if (value == 0) value = params.window_log_limit_default;
            try checkDBounds(.window_log_max, value);
            dctx.max_window_size = @as(usize, 1) << @intCast(value);
        },
        .format => {
            try checkDBounds(.format, value);
            dctx.format = @fromBackingInt(@as(u32, @intCast(value)));
        },
        .stable_out_buffer => {
            try checkDBounds(.stable_out_buffer, value);
            dctx.out_buffer_mode = @fromBackingInt(@as(u1, @intCast(value)));
        },
        .force_ignore_checksum => {
            try checkDBounds(.force_ignore_checksum, value);
            dctx.force_ignore_checksum = @fromBackingInt(@as(u32, @intCast(value)));
        },
        .ref_multiple_ddicts => {
            try checkDBounds(.ref_multiple_ddicts, value);
            if (dctx.static_size != 0) return error.ParameterUnsupported;
            dctx.ref_multiple_ddicts = @fromBackingInt(@as(u32, @intCast(value)));
        },
        .disable_huffman_assembly => {
            try checkDBounds(.disable_huffman_assembly, value);
            dctx.disable_huf_asm = value != 0;
        },
        .max_block_size => {
            if (value != 0) try checkDBounds(.max_block_size, value);
            dctx.max_block_size_param = value;
        },
    }
}

/// `ZSTD_DCtx_reset`: ends the session (a frame in progress is dropped),
/// resets the parameters and the dictionary, or both; the parameters only
/// between frames.
pub fn reset(dctx: *DCtx, directive: params.ResetDirective) Error!void {
    if (directive == .session_only or directive == .session_and_parameters) {
        dctx.stream_stage = .init;
        dctx.no_forward_progress = 0;
        dctx.is_frame_decompression = true;
    }
    if (directive == .parameters or directive == .session_and_parameters) {
        if (dctx.stream_stage != .init) return error.StageWrong;
        clearDict(dctx);
        resetParameters(dctx);
    }
}

// --------------------------------------------------------
// Streaming
// --------------------------------------------------------

/// `ZSTD_sizeof_DStream`.
pub fn sizeofDStream(dctx: ?*const DCtx) usize {
    return sizeofDCtx(dctx);
}

/// `ZSTD_decodingBufferSize_internal`.
fn decodingBufferSizeInternal(window_size: u64, frame_content_size: u64, block_size_max: usize) Error!usize {
    const block_size = @min(@as(usize, @intCast(@min(window_size, params.block_size_max))), block_size_max);
    // A block may be written at the end of the window, and the window
    // after it; the overlength is room for the wild copies.
    const needed_rb_size = window_size +% (block_size * 2) +% (zstd_internal.wildcopy_overlength * 2);
    const needed_size = @min(frame_content_size, needed_rb_size);
    if (needed_size > std.math.maxInt(usize)) return error.FrameParameterWindowTooLarge;
    return @intCast(needed_size);
}

/// `ZSTD_decodingBufferSize_min`: the output buffer a stream needs for a
/// window and frame size.
pub fn decodingBufferSizeMin(window_size: u64, frame_content_size: u64) Error!usize {
    return decodingBufferSizeInternal(window_size, frame_content_size, params.block_size_max);
}

/// `ZSTD_estimateDStreamSize`: the size of a stream for frames with
/// windows up to `window_size`.
pub fn estimateDStreamSize(window_size: usize) Error!usize {
    const block_size = @min(window_size, params.block_size_max);
    const in_buff_size = block_size;
    const out_buff_size = try decodingBufferSizeMin(window_size, content_size_unknown);
    return estimateDCtxSize() + in_buff_size + out_buff_size;
}

/// `ZSTD_estimateDStreamSize_fromFrame`.
pub fn estimateDStreamSizeFromFrame(src: []const u8) Error!usize {
    const window_size_max: u32 = @as(u32, 1) << params.window_log_max;
    var zfh: FrameHeader = .{};
    const err = try getFrameHeader(&zfh, src);
    if (err > 0) return error.SrcSizeWrong;
    if (zfh.window_size > window_size_max) return error.FrameParameterWindowTooLarge;
    return estimateDStreamSize(@intCast(zfh.window_size));
}

fn isOverflow(zds: *const DCtx, needed_in_buff_size: usize, needed_out_buff_size: usize) bool {
    return zds.in_buff_size + zds.out_buff_size >=
        (needed_in_buff_size + needed_out_buff_size) * zstd_internal.workspace_too_large_factor;
}

fn updateOversizedDuration(zds: *DCtx, needed_in_buff_size: usize, needed_out_buff_size: usize) void {
    if (isOverflow(zds, needed_in_buff_size, needed_out_buff_size)) {
        zds.oversized_duration += 1;
    } else {
        zds.oversized_duration = 0;
    }
}

fn isOversizedTooLong(zds: *const DCtx) bool {
    return zds.oversized_duration >= zstd_internal.workspace_too_large_max_duration;
}

/// `ZSTD_checkOutBuffer`: with a stable output, each call's output must be
/// the last call's.
fn checkOutBuffer(zds: *const DCtx, output: *const OutBuffer) Error!void {
    const expect = zds.expected_out_buffer;
    if (zds.out_buffer_mode != .stable) return;
    // The first call of a frame sets the buffer.
    if (zds.stream_stage == .init) return;
    if (expect.ptr == @intFromPtr(output.dst.ptr) and expect.pos == output.pos and expect.size == output.dst.len) return;
    return error.DstBufferWrong;
}

/// `ZSTD_decompressContinueStream`: one `decompressContinue` of a stream,
/// into its buffer or, with a stable output, straight into the output.
fn decompressContinueStream(zds: *DCtx, output: []u8, op: *usize, src: []const u8) Error!void {
    const is_skip_frame = isSkipFrame(zds);
    if (zds.out_buffer_mode == .buffered) {
        const dst_size = if (is_skip_frame) 0 else zds.out_buff_size - zds.out_start;
        const decoded_size = try decompressContinue(zds, (zds.out_buff + zds.out_start)[0..dst_size], src);
        if (decoded_size == 0 and !is_skip_frame) {
            zds.stream_stage = .read;
        } else {
            zds.out_end = zds.out_start + decoded_size;
            zds.stream_stage = .flush;
        }
    } else {
        // Write directly into the output.
        const dst_size = if (is_skip_frame) 0 else output.len - op.*;
        const decoded_size = try decompressContinue(zds, output[op.*..][0..dst_size], src);
        op.* += decoded_size;
        zds.stream_stage = .read;
        assert(op.* <= output.len);
        assert(zds.out_buffer_mode == .stable);
    }
}

/// `ZSTD_limitCopy`.
fn limitCopy(dst: []u8, src: []const u8) usize {
    const length = @min(dst.len, src.len);
    if (length > 0) @memcpy(dst[0..length], src[0..length]);
    return length;
}

/// `ZSTD_decompressStream`: decodes from `input` into `output`, moving both
/// positions, as far as both allow. Returns 0 when a frame is done and
/// flushed, else a hint of the input the next call wants.
pub fn decompressStream(zds: *DCtx, output: *OutBuffer, input: *InBuffer) Error!usize {
    const src = input.src;
    const istart = input.pos;
    const iend = input.src.len;
    var ip = istart;
    const dst = output.dst;
    const ostart = output.pos;
    const oend = output.dst.len;
    var op = ostart;
    var some_more_work = true;

    if (input.pos > input.src.len) return error.SrcSizeWrong;
    if (output.pos > output.dst.len) return error.DstSizeTooSmall;
    try checkOutBuffer(zds, output);

    while (some_more_work) {
        stage: switch (zds.stream_stage) {
            .init => {
                zds.stream_stage = .load_header;
                zds.lh_size = 0;
                zds.in_pos = 0;
                zds.out_start = 0;
                zds.out_end = 0;
                zds.hostage_byte = false;
                zds.expected_out_buffer = .{ .ptr = @intFromPtr(output.dst.ptr), .size = output.dst.len, .pos = output.pos };
                continue :stage .load_header;
            },
            .load_header => {
                const h_size_result = getFrameHeaderAdvanced(&zds.f_params, zds.header_buffer[0..zds.lh_size], zds.format);
                if (zds.ref_multiple_ddicts == .ref_multiple_ddicts and zds.ddict_set != null) {
                    selectFrameDDict(zds);
                }
                const h_size = try h_size_result;
                if (h_size != 0) {
                    // More input for the header.
                    const to_load = h_size - zds.lh_size;
                    const remaining_input = iend - ip;
                    if (to_load > remaining_input) {
                        // Not enough input for the whole header.
                        if (remaining_input > 0) {
                            @memcpy(zds.header_buffer[zds.lh_size..][0..remaining_input], src[ip..][0..remaining_input]);
                            zds.lh_size += remaining_input;
                        }
                        input.pos = input.src.len;
                        // The first bytes can show a wrong magic number.
                        _ = try getFrameHeaderAdvanced(&zds.f_params, zds.header_buffer[0..zds.lh_size], zds.format);
                        // The rest of the header and the next block header.
                        return (@max(params.frameHeaderSizeMin(zds.format), h_size) - zds.lh_size) + block_header_size;
                    }
                    @memcpy(zds.header_buffer[zds.lh_size..][0..to_load], src[ip..][0..to_load]);
                    zds.lh_size = h_size;
                    ip += to_load;
                    break :stage;
                }

                // A whole frame in the input, with room in the output: one
                // shot.
                if (zds.f_params.frame_content_size != content_size_unknown and
                    zds.f_params.frame_type != .skippable_frame and
                    @as(u64, oend - op) >= zds.f_params.frame_content_size)
                {
                    if (findFrameCompressedSizeAdvanced(src[istart..iend], zds.format)) |c_size| {
                        if (c_size <= iend - istart) {
                            const decompressed_size = try decompressUsingDDict(
                                zds,
                                dst[op..oend],
                                src[istart..][0..c_size],
                                getDDict(zds),
                            );
                            ip = istart + c_size;
                            op += decompressed_size;
                            zds.expected = 0;
                            zds.stream_stage = .init;
                            some_more_work = false;
                            break :stage;
                        }
                    } else |_| {}
                }

                // A stable output must hold the whole frame.
                if (zds.out_buffer_mode == .stable and
                    zds.f_params.frame_type != .skippable_frame and
                    zds.f_params.frame_content_size != content_size_unknown and
                    @as(u64, oend - op) < zds.f_params.frame_content_size)
                {
                    return error.DstSizeTooSmall;
                }

                // The header is read: start the frame.
                try decompressBeginUsingDDict(zds, getDDict(zds));
                if (zds.format == .zstd1 and isSkippableMagic(readLE32(&zds.header_buffer))) {
                    zds.expected = readLE32(zds.header_buffer[frame_id_size..]);
                    zds.stage = .skip_frame;
                } else {
                    try decodeFrameHeader(zds, zds.header_buffer[0..zds.lh_size]);
                    zds.expected = block_header_size;
                    zds.stage = .decode_block_header;
                }

                // The buffers.
                zds.f_params.window_size = @max(zds.f_params.window_size, @as(u64, 1) << zstd_internal.window_log_absolute_min);
                if (zds.f_params.window_size > zds.max_window_size) return error.FrameParameterWindowTooLarge;
                if (zds.max_block_size_param != 0) {
                    zds.f_params.block_size_max = @min(zds.f_params.block_size_max, @as(u32, @intCast(zds.max_block_size_param)));
                }
                {
                    // Room for the frame checksum, too.
                    const needed_in_buff_size: usize = @max(zds.f_params.block_size_max, 4);
                    const needed_out_buff_size: usize = if (zds.out_buffer_mode == .buffered)
                        try decodingBufferSizeInternal(zds.f_params.window_size, zds.f_params.frame_content_size, zds.f_params.block_size_max)
                    else
                        0;
                    updateOversizedDuration(zds, needed_in_buff_size, needed_out_buff_size);
                    const too_small = zds.in_buff_size < needed_in_buff_size or zds.out_buff_size < needed_out_buff_size;
                    const too_large = isOversizedTooLong(zds);
                    if (too_small or too_large) {
                        const buffer_size = needed_in_buff_size + needed_out_buff_size;
                        if (zds.static_size != 0) {
                            assert(zds.static_size >= internal.dctx_object_size);
                            if (buffer_size > zds.static_size - internal.dctx_object_size) return error.MemoryAllocation;
                        } else {
                            const gpa = zds.custom_mem.?;
                            if (zds.in_buff) |buffer| gpa.free(buffer[0 .. zds.in_buff_size + zds.out_buff_size]);
                            zds.in_buff_size = 0;
                            zds.out_buff_size = 0;
                            zds.in_buff = null;
                            const buffer = gpa.alloc(u8, buffer_size) catch return error.MemoryAllocation;
                            zds.in_buff = buffer.ptr;
                        }
                        zds.in_buff_size = needed_in_buff_size;
                        zds.out_buff = zds.in_buff.? + zds.in_buff_size;
                        zds.out_buff_size = needed_out_buff_size;
                    }
                }
                zds.stream_stage = .read;
                continue :stage .read;
            },
            .read => {
                const needed_in_size = nextSrcSizeToDecompressWithInputSize(zds, iend - ip);
                if (needed_in_size == 0) {
                    // The end of the frame.
                    zds.stream_stage = .init;
                    some_more_work = false;
                    break :stage;
                }
                if (iend - ip >= needed_in_size) {
                    // Decode straight from the input.
                    try decompressContinueStream(zds, dst[0..oend], &op, src[ip..][0..needed_in_size]);
                    ip += needed_in_size;
                    break :stage;
                }
                if (ip == iend) {
                    // No more input.
                    some_more_work = false;
                    break :stage;
                }
                zds.stream_stage = .load;
                continue :stage .load;
            },
            .load => {
                const needed_in_size = nextSrcSizeToDecompress(zds);
                const to_load = needed_in_size - zds.in_pos;
                const is_skip_frame = isSkipFrame(zds);
                var loaded_size: usize = undefined;
                assert(needed_in_size == nextSrcSizeToDecompressWithInputSize(zds, iend - ip));
                if (is_skip_frame) {
                    loaded_size = @min(to_load, iend - ip);
                } else {
                    if (to_load > zds.in_buff_size - zds.in_pos) return error.CorruptionDetected;
                    loaded_size = limitCopy((zds.in_buff.? + zds.in_pos)[0..to_load], src[ip..iend]);
                }
                if (loaded_size != 0) {
                    ip += loaded_size;
                    zds.in_pos += loaded_size;
                }
                if (loaded_size < to_load) {
                    // Not enough input: wait for more.
                    some_more_work = false;
                    break :stage;
                }
                // The input is taken.
                zds.in_pos = 0;
                try decompressContinueStream(zds, dst[0..oend], &op, zds.in_buff.?[0..needed_in_size]);
                break :stage;
            },
            .flush => {
                const to_flush_size = zds.out_end - zds.out_start;
                const flushed_size = limitCopy(dst[op..oend], (zds.out_buff + zds.out_start)[0..to_flush_size]);
                op += flushed_size;
                zds.out_start += flushed_size;
                if (flushed_size == to_flush_size) {
                    // The flush is done.
                    zds.stream_stage = .read;
                    if (zds.out_buff_size < zds.f_params.frame_content_size and
                        zds.out_start + zds.f_params.block_size_max > zds.out_buff_size)
                    {
                        // No room for another block: back to the buffer's start.
                        zds.out_start = 0;
                        zds.out_end = 0;
                    }
                    break :stage;
                }
                some_more_work = false;
            },
        }
    }

    // The positions.
    input.pos = ip;
    output.pos = op;
    zds.expected_out_buffer = .{ .ptr = @intFromPtr(output.dst.ptr), .size = output.dst.len, .pos = output.pos };

    if (ip == istart and op == ostart) {
        // No forward progress.
        zds.no_forward_progress += 1;
        if (zds.no_forward_progress >= internal.no_forward_progress_max) {
            if (op == oend) return error.NoForwardProgressDestFull;
            if (ip == iend) return error.NoForwardProgressInputEmpty;
        }
    } else {
        zds.no_forward_progress = 0;
    }

    var next_src_size_hint = nextSrcSizeToDecompress(zds);
    if (next_src_size_hint == 0) {
        // The frame is decoded.
        if (zds.out_end == zds.out_start) {
            // And flushed.
            if (zds.hostage_byte) {
                if (input.pos >= input.src.len) {
                    // Can't release the hostage byte yet.
                    zds.stream_stage = .read;
                    return 1;
                }
                // Release the hostage byte.
                input.pos += 1;
            }
            return 0;
        }
        // Not flushed: keep the last input byte back until it is, so the
        // caller calls again.
        if (!zds.hostage_byte) {
            input.pos -= 1;
            zds.hostage_byte = true;
        }
        return 1;
    }
    // Preload the next block's header.
    if (nextInputType(zds) == .block) next_src_size_hint += block_header_size;
    assert(zds.in_pos <= next_src_size_hint);
    // Less the part already loaded.
    next_src_size_hint -= zds.in_pos;
    return next_src_size_hint;
}

/// `ZSTD_decompressStream_simpleArgs`.
pub fn decompressStreamSimpleArgs(
    dctx: *DCtx,
    dst: []u8,
    dst_pos: *usize,
    src: []const u8,
    src_pos: *usize,
) Error!usize {
    var output: OutBuffer = .{ .dst = dst, .pos = dst_pos.* };
    var input: InBuffer = .{ .src = src, .pos = src_pos.* };
    const result = decompressStream(dctx, &output, &input);
    dst_pos.* = output.pos;
    src_pos.* = input.pos;
    return result;
}

// --------------------------------------------------------
// One frame of a known size
// --------------------------------------------------------

/// What `decompressFrameExact` requires of a frame.
pub const FrameExactOptions = struct {
    /// Refuse a frame without a checksum (`error.ChecksumWrong`), so that
    /// every frame decoded is verified.
    require_checksum: bool = false,
};

/// Decodes `src`, exactly one zstd frame, into `dst`, which must be the
/// frame's decoded size, with the dictionary `dctx` refers to. It
/// allocates nothing, so `dctx` can be one placed by `initDCtx`, and it
/// verifies the frame's checksum when the frame has one, whatever the
/// context's `force_ignore_checksum`. It refuses:
/// - `src` that is not one whole frame: a skippable frame
///   (`error.PrefixUnknown`), or bytes after the frame (`error.SrcSizeWrong`);
/// - a frame whose header gives a size other than `dst.len`
///   (`error.DstSizeTooSmall` when larger, `error.SrcSizeWrong` when
///   smaller), or that decodes to fewer bytes (`error.CorruptionDetected`)
///   or more (`error.DstSizeTooSmall`);
/// - a checksum that does not match, or with `require_checksum` none
///   (`error.ChecksumWrong`);
/// - and anything the original's decoder refuses, with its error.
/// On an error, the bytes of `dst` are unspecified.
pub fn decompressFrameExact(dctx: *DCtx, dst: []u8, src: []const u8, options: FrameExactOptions) Error!void {
    if (dctx.format == .zstd1 and isSkippableFrame(src)) return error.PrefixUnknown;
    var zfh: FrameHeader = .{};
    if (try getFrameHeaderAdvanced(&zfh, src, dctx.format) != 0) return error.SrcSizeWrong;
    if (zfh.frame_content_size != content_size_unknown) {
        if (zfh.frame_content_size > dst.len) return error.DstSizeTooSmall;
        if (zfh.frame_content_size < dst.len) return error.SrcSizeWrong;
    }
    if (options.require_checksum and !zfh.checksum_flag) return error.ChecksumWrong;

    try decompressBeginUsingDDict(dctx, getDDict(dctx));
    block.checkContinuity(dctx, dst.ptr, dst.len);
    const saved = dctx.force_ignore_checksum;
    dctx.force_ignore_checksum = .validate_checksum;
    defer dctx.force_ignore_checksum = saved;
    var rest = src;
    const size = try decompressFrame(dctx, dst, &rest);
    if (rest.len != 0) return error.SrcSizeWrong;
    if (size != dst.len) return error.CorruptionDetected;
}

test {
    std.testing.refAllDecls(@This());
}
