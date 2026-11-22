//! Digested dictionaries for decompression, from the original's
//! zstd_ddict.c.

const std = @import("std");
const assert = std.debug.assert;
const Error = @import("../error.zig").Error;
const params = @import("../params.zig");
const internal = @import("decompress_internal.zig");
const decompress = @import("decompress.zig");
const DCtx = internal.DCtx;
const DDict = internal.DDict;

/// `ZSTD_DDict_dictContent`.
pub fn dictContent(ddict: *const DDict) []const u8 {
    return ddict.dict_content;
}

/// `ZSTD_copyDDictParameters`: starts `dctx`'s frame on `ddict`: its
/// content is the window before the frame, and its tables, if any, are the
/// frame's first.
pub fn copyDDictParameters(dctx: *DCtx, ddict: *const DDict) void {
    dctx.dict_id = ddict.dict_id;
    dctx.prefix_start = @intFromPtr(ddict.dict_content.ptr);
    dctx.virtual_start = dctx.prefix_start;
    dctx.dict_end = dctx.prefix_start + ddict.dict_content.len;
    dctx.previous_dst_end = dctx.dict_end;
    if (ddict.entropy_present) {
        dctx.lit_entropy = true;
        dctx.fse_entropy = true;
        dctx.ll_tptr = &ddict.entropy.ll_table;
        dctx.ml_tptr = &ddict.entropy.ml_table;
        dctx.of_tptr = &ddict.entropy.of_table;
        dctx.huf_ptr = &ddict.entropy.huf_table;
        dctx.entropy.rep = ddict.entropy.rep;
    } else {
        dctx.lit_entropy = false;
        dctx.fse_entropy = false;
    }
}

/// `ZSTD_loadEntropy_intoDDict`.
fn loadEntropyIntoDDict(ddict: *DDict, dict_content_type: params.DictContentType) Error!void {
    ddict.dict_id = 0;
    ddict.entropy_present = false;
    if (dict_content_type == .raw_content) return;

    if (ddict.dict_content.len < 8) {
        // Only full dictionaries when they are asked for.
        if (dict_content_type == .full_dict) return error.DictionaryCorrupted;
        return;
    }
    const magic = std.mem.readInt(u32, ddict.dict_content[0..4], .little);
    if (magic != params.magic_dictionary) {
        if (dict_content_type == .full_dict) return error.DictionaryCorrupted;
        return;
    }
    ddict.dict_id = std.mem.readInt(u32, ddict.dict_content[4..8], .little);
    _ = decompress.loadDEntropy(&ddict.entropy, ddict.dict_content) catch return error.DictionaryCorrupted;
    ddict.entropy_present = true;
}

/// `ZSTD_initDDict_internal`.
fn initDDictInternal(
    ddict: *DDict,
    dict: []const u8,
    dict_load_method: params.DictLoadMethod,
    dict_content_type: params.DictContentType,
) Error!void {
    if (dict_load_method == .by_ref or dict.len == 0) {
        ddict.dict_buffer = null;
        ddict.dict_content = dict;
    } else {
        const gpa = ddict.c_mem orelse unreachable;
        const internal_buffer = gpa.alloc(u8, dict.len) catch {
            ddict.dict_buffer = null;
            ddict.dict_content = &.{};
            return error.MemoryAllocation;
        };
        ddict.dict_buffer = internal_buffer.ptr;
        ddict.dict_content = internal_buffer;
        @memcpy(internal_buffer, dict);
    }
    ddict.entropy.huf_table[0] = internal.EntropyDTables.huf_table_init;
    try loadEntropyIntoDDict(ddict, dict_content_type);
}

/// `ZSTD_createDDict_advanced`: a dictionary for decompression, copied or
/// referenced. A referenced `dict` must outlive the dictionary. Fails with
/// `error.DictionaryCorrupted` when a dictionary with the dictionary magic
/// number, or any `full_dict`, does not load.
pub fn createDDictAdvanced(
    gpa: std.mem.Allocator,
    dict: []const u8,
    dict_load_method: params.DictLoadMethod,
    dict_content_type: params.DictContentType,
) Error!*DDict {
    const ddict = gpa.create(DDict) catch return error.MemoryAllocation;
    ddict.c_mem = gpa;
    initDDictInternal(ddict, dict, dict_load_method, dict_content_type) catch |err| {
        freeDDict(ddict);
        return err;
    };
    return ddict;
}

/// `ZSTD_createDDict`: a copy of `dict`, digested.
pub fn createDDict(gpa: std.mem.Allocator, dict: []const u8) Error!*DDict {
    return createDDictAdvanced(gpa, dict, .by_copy, .auto);
}

/// `ZSTD_createDDict_byReference`: `dict` digested in place; it must
/// outlive the dictionary.
pub fn createDDictByReference(gpa: std.mem.Allocator, dict: []const u8) Error!*DDict {
    return createDDictAdvanced(gpa, dict, .by_ref, .auto);
}

/// `ZSTD_initStaticDDict`: a dictionary placed in `buffer`, with its copy
/// of `dict` after it unless loaded by reference. `buffer` must be aligned
/// on 8 and hold `estimateDDictSize(dict.len, dict_load_method)` bytes, and
/// outlive the dictionary, which is never freed. Null when `buffer` is too
/// small or misaligned, or the dictionary does not load.
pub fn initStaticDDict(
    buffer: []u8,
    dict_in: []const u8,
    dict_load_method: params.DictLoadMethod,
    dict_content_type: params.DictContentType,
) ?*const DDict {
    const needed_space = internal.ddict_object_size + (if (dict_load_method == .by_ref) 0 else dict_in.len);
    if (@intFromPtr(buffer.ptr) & 7 != 0) return null;
    if (buffer.len < needed_space) return null;
    const ddict: *DDict = @ptrCast(@alignCast(buffer.ptr));
    var dict = dict_in;
    if (dict_load_method == .by_copy) {
        const copy = buffer[internal.ddict_object_size..][0..dict.len];
        @memcpy(copy, dict);
        dict = copy;
    }
    ddict.c_mem = null;
    initDDictInternal(ddict, dict, .by_ref, dict_content_type) catch return null;
    return ddict;
}

/// `ZSTD_freeDDict`.
pub fn freeDDict(ddict: ?*DDict) void {
    const d = ddict orelse return;
    const gpa = d.c_mem orelse return;
    if (d.dict_buffer) |buffer| gpa.free(buffer[0..d.dict_content.len]);
    gpa.destroy(d);
}

/// `ZSTD_estimateDDictSize`: the bytes `initStaticDDict` needs.
pub fn estimateDDictSize(dict_size: usize, dict_load_method: params.DictLoadMethod) usize {
    return internal.ddict_object_size + (if (dict_load_method == .by_ref) 0 else dict_size);
}

/// `ZSTD_sizeof_DDict`: the original's size for this dictionary.
pub fn sizeofDDict(ddict: ?*const DDict) usize {
    const d = ddict orelse return 0;
    return internal.ddict_object_size + (if (d.dict_buffer != null) d.dict_content.len else 0);
}

/// `ZSTD_getDictID_fromDDict`: 0 for a raw-content dictionary.
pub fn getDictIdFromDDict(ddict: ?*const DDict) u32 {
    const d = ddict orelse return 0;
    return d.dict_id;
}

test {
    std.testing.refAllDecls(@This());
}
