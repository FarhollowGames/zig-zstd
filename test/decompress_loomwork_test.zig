//! Loomwork's review of the decompressor: what a game engine that reads its
//! packs with `DCtx.decompressFrameExact` relies on. Each asset of a pack
//! is one frame made by the port's compressor at level 19 with an 8 MiB
//! window, a checksum and the content size; the engine knows each asset's
//! decoded size, keeps one context per loader thread placed by `DCtx.init`,
//! reuses it for every asset, and reads packs that may be corrupt or
//! hostile. A test per confirmed finding is named `loomwork: ...`; the
//! probes that held up are named `loomwork probe: ...`.

const std = @import("std");
const builtin = @import("builtin");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const dc = @import("decompress_common.zig");
const test_options = @import("test_options");

const gpa = dc.gpa;
const testing = std.testing;
const params = zstd.params;

// --------------------------------------------------------
// Helpers
// --------------------------------------------------------

/// Loomwork's bake: the port's compressor at level 19, window log 23, with
/// a checksum and the content size.
const Bake = struct {
    cctx: *zstd.CCtx,

    fn init() !Bake {
        const cctx = try zstd.CCtx.create(gpa);
        errdefer cctx.destroy() catch unreachable;
        _ = try cctx.setParameter(.compression_level, 19);
        _ = try cctx.setParameter(.window_log, 23);
        _ = try cctx.setParameter(.checksum_flag, 1);
        return .{ .cctx = cctx };
    }

    fn deinit(bake: Bake) void {
        bake.cctx.destroy() catch unreachable;
    }

    /// The asset's frame; the caller frees it.
    fn frame(bake: Bake, asset: []const u8) ![]u8 {
        const dst = try gpa.alloc(u8, try zstd.compressBound(asset.len));
        errdefer gpa.free(dst);
        const size = try bake.cctx.compress2(dst, asset);
        return gpa.realloc(dst, size);
    }
};

/// `size` bytes of BC7 blocks: test/data/bc7.bin over and over, each lap
/// XORed with its own byte, so that laps do not match one another but keep
/// the blocks' statistics. The caller frees it.
fn textureLike(bc7: []const u8, size: usize, lap0: u8) ![]u8 {
    const out = try gpa.alloc(u8, size);
    for (out, 0..) |*b, i| {
        const lap: u8 = @truncate(i / bc7.len);
        b.* = bc7[i % bc7.len] ^ (lap0 +% lap *% 0x9D);
    }
    return out;
}

fn readBc7() ![]u8 {
    return common.readFile(test_options.data, "bc7.bin");
}

/// A context of the original, with its assembly Huffman loops off so that
/// it runs the C loops the port translates on corrupt input too.
fn upstreamDCtx() !*c.ZSTD_DCtx {
    const dctx = c.ZSTD_createDCtx() orelse return error.OutOfMemory;
    _ = c.ZSTD_DCtx_setParameter(dctx, dc.d_disable_huffman_assembly, 1);
    return dctx;
}

/// A buffer of `len` bytes against an inaccessible page: after its end
/// (`at_end`), or before its start.
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

/// The original's verdict on `frame` as one Loomwork asset of
/// `expected.len` bytes: whether `ZSTD_decompressDCtx` decodes exactly that
/// many bytes from one frame (not skippable) that spans all of `frame`,
/// into `expected`. An empty `expected` is passed as NULL, as a C caller
/// passes an empty buffer.
fn upstreamAccepts(udctx: *c.ZSTD_DCtx, frame: []const u8, expected: []u8) bool {
    if (frame.len >= 4 and std.mem.readInt(u32, frame[0..4], .little) & params.magic_skippable_mask == params.magic_skippable_start) return false;
    const fsize = c.ZSTD_findFrameCompressedSize(frame.ptr, frame.len);
    if (c.ZSTD_isError(fsize) != 0 or fsize != frame.len) return false;
    const dst: ?*anyopaque = if (expected.len == 0) null else expected.ptr;
    const code = c.ZSTD_decompressDCtx(udctx, dst, expected.len, frame.ptr, frame.len);
    return c.ZSTD_isError(code) == 0 and code == expected.len;
}

// --------------------------------------------------------
// Probes that held up
// --------------------------------------------------------

test "loomwork probe: the bake's frames of every asset size decode to the asset on one reused context" {
    const bc7 = try readBc7();
    defer gpa.free(bc7);
    const bake = try Bake.init();
    defer bake.deinit();
    const udctx = try upstreamDCtx();
    defer _ = c.ZSTD_freeDCtx(udctx);
    // One context for every asset, in memory the engine owns.
    const dctx = try gpa.create(zstd.DCtx);
    defer gpa.destroy(dctx);
    dctx.init();

    var stats: dc.Stats = .{};
    const block = 128 << 10;
    // Around the content size field's widths (1, 2 and 4 bytes), the
    // 64 KiB of literals the context holds, the block size, and the mip
    // sizes of a 2048 x 2048 BC7 texture, its whole chain last.
    const sizes = [_]usize{
        0,         1,         2,         15,        16,        17,        64,        255,
        256,       257,       1024,      4096,      16384,     65535,     65536,     65537,
        65791,     65792,     block - 1, block,     block + 1, 2 * block, 2 * block + 1, 3 * block - 1,
        262144 + 65536 + 16384, 1 << 20, 4 << 20, 5592400,
    };
    for (0..sizes.len + 8) |k| {
        // Textures, then constant assets (RLE blocks) and mixed ones
        // (text-like data, noise and runs).
        const size = if (k < sizes.len) sizes[k] else sizes[16 + (k - sizes.len)];
        errdefer std.debug.print("size {d}, kind {d}\n", .{ size, k });
        const asset = if (k < sizes.len)
            try textureLike(bc7, size, @truncate(k))
        else if (k % 2 == 0) blk: {
            const a = try gpa.alloc(u8, size);
            @memset(a, @truncate(k));
            break :blk a;
        } else try dc.mixedInput(size, @intCast(k));
        defer gpa.free(asset);
        const frame = try bake.frame(asset);
        defer gpa.free(frame);
        try stats.add(frame);
        var zfh: zstd.FrameHeader = .{};
        try testing.expectEqual(@as(usize, 0), try zstd.getFrameHeader(&zfh, frame));
        try testing.expectEqual(@as(u64, size), zfh.frame_content_size);
        try testing.expect(zfh.checksum_flag);
        // Single segment up to the window.
        try testing.expectEqual(size <= 8 << 20, frame[4] & 0x20 != 0);
        // An empty asset is one empty raw block, which the finding about
        // empty compressed blocks below does not reach.
        if (size == 0) try testing.expectEqual(@as(u8, 1), frame[zfh.header_size] & 7);

        // An exact buffer from an allocator, as the engine's: a 0-byte one
        // has the allocator's placeholder address.
        const out = try gpa.alloc(u8, size);
        defer gpa.free(out);
        @memset(out, 0xA5);
        try dctx.decompressFrameExact(out, frame, .{ .require_checksum = true });
        try testing.expectEqualSlices(u8, asset, out);
        const expected = try gpa.alloc(u8, size);
        defer gpa.free(expected);
        try testing.expect(upstreamAccepts(udctx, frame, expected));
        try testing.expectEqualSlices(u8, expected, out);
    }
    // The frames reach raw, RLE and compressed blocks, both Huffman
    // decoders, literals split between the output and the context,
    // predefined and FSE tables for each sequence field, and repeated
    // literal lengths tables.
    for (stats.blocks) |n| try testing.expect(n > 0);
    try testing.expect(stats.huffman_x1 > 0 and stats.huffman_x2 > 0 and stats.literals_over_64k > 0);
    for (stats.seq_modes) |modes| try testing.expect(modes[0] > 0 and modes[2] > 0);
    try testing.expect(stats.seq_modes[0][3] > 0);
}

test "loomwork probe: windows at and past the bake's, multi-segment frames" {
    const bc7 = try readBc7();
    defer gpa.free(bc7);
    const bake = try Bake.init();
    defer bake.deinit();
    var dctx: zstd.DCtx = undefined;
    dctx.init();
    for ([_]usize{ (8 << 20) - 1, 8 << 20, (8 << 20) + 1, (8 << 20) + (128 << 10) + 7 }) |size| {
        errdefer std.debug.print("size {d}\n", .{size});
        const asset = try textureLike(bc7, size, 3);
        defer gpa.free(asset);
        const frame = try bake.frame(asset);
        defer gpa.free(frame);
        var zfh: zstd.FrameHeader = .{};
        _ = try zstd.getFrameHeader(&zfh, frame);
        try testing.expectEqual(size <= 8 << 20, frame[4] & 0x20 != 0);
        if (size > 8 << 20) try testing.expectEqual(@as(u64, 8 << 20), zfh.window_size);
        const out = try gpa.alloc(u8, size);
        defer gpa.free(out);
        try dctx.decompressFrameExact(out, frame, .{ .require_checksum = true });
        try testing.expectEqualSlices(u8, asset, out);
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

/// A corrupted copy of `frame`: bits flipped, bytes set, removed or
/// inserted, the end cut, or a block header's size or type changed; mostly
/// near the frame's and the blocks' starts, where the headers are.
fn corrupt(random: std.Random, frame: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, frame);
    var blocks: std.ArrayList([]const u8) = .empty;
    defer blocks.deinit(gpa);
    try frameBlocks(frame, &blocks);
    for (0..random.intRangeAtMost(usize, 1, 3)) |_| {
        if (bytes.items.len == 0) break;
        const len = bytes.items.len;
        // Near a block's start: its header, literals and sequences headers.
        const near_block = if (blocks.items.len > 0) blk: {
            const b = blocks.items[random.uintLessThan(usize, blocks.items.len)];
            const start = @intFromPtr(b.ptr) - @intFromPtr(frame.ptr);
            break :blk @min(len - 1, start + random.uintLessThan(usize, @min(b.len, 24)));
        } else 0;
        const at = switch (random.uintLessThan(u32, 4)) {
            0 => random.uintLessThan(usize, @min(len, 16)),
            1 => near_block,
            2 => len - 1 - random.uintLessThan(usize, @min(len, 8)),
            else => random.uintLessThan(usize, len),
        };
        switch (random.uintLessThan(u32, 8)) {
            0, 1, 2 => bytes.items[at] ^= @as(u8, 1) << random.int(u3),
            3 => bytes.items[at] = random.int(u8),
            4 => _ = bytes.orderedRemove(at),
            5 => try bytes.insert(gpa, at, random.int(u8)),
            6 => bytes.shrinkRetainingCapacity(at),
            else => if (blocks.items.len > 0) {
                // A block header: another size or type, or the last flag.
                const b = blocks.items[random.uintLessThan(usize, blocks.items.len)];
                const start = @intFromPtr(b.ptr) - @intFromPtr(frame.ptr);
                if (start + 3 <= bytes.items.len) {
                    var header = std.mem.readInt(u24, bytes.items[start..][0..3], .little);
                    switch (random.uintLessThan(u32, 3)) {
                        0 => header ^= @as(u24, 1) << random.intRangeAtMost(u5, 3, 23),
                        1 => header ^= @as(u24, random.intRangeAtMost(u2, 1, 3)) << 1,
                        else => header ^= 1,
                    }
                    std.mem.writeInt(u24, bytes.items[start..][0..3], header, .little);
                }
            },
        }
    }
    return bytes.toOwnedSlice(gpa);
}

/// Writes the checksum of `content` into the last 4 bytes of `frame`.
fn fixChecksum(frame: []u8, content: []const u8) void {
    const h: u32 = @truncate(std.hash.XxHash64.hash(0, content));
    std.mem.writeInt(u32, frame[frame.len - 4 ..][0..4], h, .little);
}

fn hasChecksum(frame: []const u8) bool {
    var zfh: zstd.FrameHeader = .{};
    const r = zstd.getFrameHeader(&zfh, frame) catch return false;
    return r == 0 and zfh.frame_type == .frame and zfh.checksum_flag;
}

test "loomwork probe: hostile frames against guard pages on one reused context, as the original judges them" {
    // Each case corrupts one of the bake's frames, or splices blocks of
    // several, and decodes it with decompressFrameExact from a buffer
    // against an inaccessible page into an exact buffer against another,
    // on one context reused for every case. The port must accept exactly
    // the frames the original decodes to the asset's size, with the same
    // bytes; where the original decodes a corrupted frame, its checksum is
    // set to the original's output, so that the port must agree on frames
    // that are wrong but consistent. After every case the context decodes
    // a good frame.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const bc7 = try readBc7();
    defer gpa.free(bc7);
    const bake = try Bake.init();
    defer bake.deinit();
    const udctx = try upstreamDCtx();
    defer _ = c.ZSTD_freeDCtx(udctx);
    const uignore = try upstreamDCtx();
    defer _ = c.ZSTD_freeDCtx(uignore);
    _ = c.ZSTD_DCtx_setParameter(uignore, dc.d_force_ignore_checksum, 1);
    var dctx: zstd.DCtx = undefined;
    dctx.init();

    const Asset = struct { input: []u8, frame: []u8 };
    var assets: std.ArrayList(Asset) = .empty;
    defer {
        for (assets.items) |a| {
            gpa.free(a.input);
            gpa.free(a.frame);
        }
        assets.deinit(gpa);
    }
    var blocks: std.ArrayList([]const u8) = .empty;
    defer blocks.deinit(gpa);
    for ([_]usize{ 16, 300, 5000, 65536, 131072, 131073, 200_000, 600_000, 1 << 20 }, 0..) |size, k| {
        const input = try textureLike(bc7, size, @truncate(k * 7));
        errdefer gpa.free(input);
        const frame = try bake.frame(input);
        try assets.append(gpa, .{ .input = input, .frame = frame });
    }
    // Mixed data too (text-like data, noise and runs), for other Huffman
    // tables and sequence table modes than the textures'.
    for ([_]usize{ 40_000, 300_000 }, 0..) |size, k| {
        const input = try dc.mixedInput(size, @intCast(k + 31));
        errdefer gpa.free(input);
        const frame = try bake.frame(input);
        try assets.append(gpa, .{ .input = input, .frame = frame });
    }
    for (assets.items) |a| try frameBlocks(a.frame, &blocks);

    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(4401));
    const random = prng.random();
    var spliced: std.ArrayList(u8) = .empty;
    defer spliced.deinit(gpa);
    var accepted: usize = 0;
    var consistent: usize = 0;
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("case {d}\n", .{case});
        const asset = assets.items[random.uintLessThan(usize, assets.items.len)];
        const bad: []u8 = if (random.uintLessThan(u32, 5) != 0) try corrupt(random, asset.frame) else blk: {
            // The header of `asset`, then blocks of any of the frames.
            spliced.clearRetainingCapacity();
            var zfh: zstd.FrameHeader = .{};
            _ = try zstd.getFrameHeader(&zfh, asset.frame);
            try spliced.appendSlice(gpa, asset.frame[0..zfh.header_size]);
            const nb = random.intRangeAtMost(usize, 1, 5);
            for (0..nb) |k| {
                const b = blocks.items[random.uintLessThan(usize, blocks.items.len)];
                const at = spliced.items.len;
                try spliced.appendSlice(gpa, b);
                var header = std.mem.readInt(u24, spliced.items[at..][0..3], .little);
                header = (header & ~@as(u24, 1)) | @intFromBool(k == nb - 1);
                std.mem.writeInt(u24, spliced.items[at..][0..3], header, .little);
            }
            try spliced.appendSlice(gpa, &.{ 0, 0, 0, 0 });
            break :blk try gpa.dupe(u8, spliced.items);
        };
        defer gpa.free(bad);
        var size = asset.input.len;
        if (random.uintLessThan(u32, 4) == 0) size = random.uintAtMost(usize, size + 300);

        // Where the original decodes the frame, its checksum ignored, to
        // `size` bytes, the checksum is set to match its output.
        const expected = try gpa.alloc(u8, size);
        defer gpa.free(expected);
        if (hasChecksum(bad) and upstreamAccepts(uignore, bad, expected)) {
            fixChecksum(bad, expected);
            consistent += 1;
        }
        const upstream_ok = upstreamAccepts(udctx, bad, expected);

        const src = try Guarded.dupe(bad, random.boolean());
        defer src.deinit();
        const dst = try Guarded.init(size, random.boolean());
        defer dst.deinit();
        @memset(dst.bytes, 0x5A);
        const require = random.boolean();
        const result = dctx.decompressFrameExact(dst.bytes, src.bytes, .{ .require_checksum = require });
        if (result) |_| {
            accepted += 1;
            if (!upstream_ok) {
                std.debug.print("the port accepts a frame the original refuses\n", .{});
                return error.AcceptedRefused;
            }
            try testing.expect(hasChecksum(bad) or !require);
            try testing.expectEqualSlices(u8, expected, dst.bytes);
        } else |err| {
            if (upstream_ok and (hasChecksum(bad) or !require)) {
                std.debug.print("the port refuses a frame the original decodes: {t}\n", .{err});
                return error.RefusedAccepted;
            }
        }

        // The context is good for the next asset.
        const good = assets.items[random.uintLessThan(usize, assets.items.len)];
        const out = try gpa.alloc(u8, good.input.len);
        defer gpa.free(out);
        try dctx.decompressFrameExact(out, good.frame, .{ .require_checksum = true });
        try testing.expectEqualSlices(u8, good.input, out);
    }
    // The probe reaches both sides of the verdict.
    try testing.expect(accepted > 0);
    try testing.expect(consistent > 0);
}

test "loomwork probe: a context placed over garbage, moved and copied between frames" {
    // DCtx.init over random bytes, then the context moved to other memory
    // and its first place unmapped, then copied by value and its second
    // place unmapped: each decodes every asset, after failed frames too,
    // so nothing between frames points into where the context was.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const bc7 = try readBc7();
    defer gpa.free(bc7);
    const bake = try Bake.init();
    defer bake.deinit();
    const Asset = struct { input: []u8, frame: []u8 };
    var assets: [5]Asset = undefined;
    const sizes = [_]usize{ 300, 70_000, 131_073, 400_000, 200_000 };
    for (&assets, sizes, 0..) |*a, size, k| {
        a.input = if (k == 4) try dc.mixedInput(size, 5) else try textureLike(bc7, size, @truncate(k));
        a.frame = try bake.frame(a.input);
    }
    defer for (assets) |a| {
        gpa.free(a.input);
        gpa.free(a.frame);
    };
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(4402));
    const random = prng.random();

    const decodeAll = struct {
        fn run(dctx: *zstd.DCtx, list: []const Asset, rand: std.Random) !void {
            for (list, 0..) |a, k| {
                const out = try gpa.alloc(u8, a.input.len);
                defer gpa.free(out);
                // A failed frame first: the asset with a byte changed in its
                // literals, then cut short.
                const bad = try gpa.dupe(u8, a.frame);
                defer gpa.free(bad);
                bad[bad.len / 2] ^= 0x10;
                dctx.decompressFrameExact(out, bad, .{ .require_checksum = true }) catch {};
                dctx.decompressFrameExact(out, a.frame[0 .. a.frame.len - 1 - rand.uintLessThan(usize, 8)], .{}) catch {};
                try dctx.decompressFrameExact(out, a.frame, .{ .require_checksum = true });
                errdefer std.debug.print("asset {d}\n", .{k});
                try testing.expectEqualSlices(u8, a.input, out);
            }
        }
    }.run;

    const size = @sizeOf(zstd.DCtx);
    const first = try Guarded.init(size, false);
    var first_mapped = true;
    defer if (first_mapped) first.deinit();
    random.bytes(first.bytes);
    const a: *zstd.DCtx = @ptrCast(@alignCast(first.bytes.ptr));
    a.init();
    try decodeAll(a, &assets, random);

    // Moved: the bytes copied elsewhere, the first place gone.
    const second = try Guarded.init(size, false);
    var second_mapped = true;
    defer if (second_mapped) second.deinit();
    @memcpy(second.bytes, first.bytes);
    first.deinit();
    first_mapped = false;
    const b: *zstd.DCtx = @ptrCast(@alignCast(second.bytes.ptr));
    try decodeAll(b, &assets, random);

    // Copied by value, the source gone.
    const copy = try gpa.create(zstd.DCtx);
    defer gpa.destroy(copy);
    copy.* = b.*;
    second.deinit();
    second_mapped = false;
    try decodeAll(copy, &assets, random);
}

test "loomwork probe: nothing of one asset reaches the next on a reused context" {
    // An asset decoded into an arena, then a frame whose only block is a
    // later block of that asset (treeless literals, repeated sequence
    // tables, repeat offsets, matches into the asset's bytes), decoded into
    // the arena right after the asset, where its matches would land in the
    // asset if the context still held its window. The original refuses it,
    // or decodes it without the asset; the port gives the same error, or
    // the same bytes.
    const bc7 = try readBc7();
    defer gpa.free(bc7);
    const bake = try Bake.init();
    defer bake.deinit();
    const udctx = try upstreamDCtx();
    defer _ = c.ZSTD_freeDCtx(udctx);
    var dctx: zstd.DCtx = undefined;
    dctx.init();
    var refused: usize = 0;
    var decoded: usize = 0;
    for (0..2) |kind| {
        const input = if (kind == 0) try dc.mixedInput(900_000, 77) else try textureLike(bc7, 900_000, 9);
        defer gpa.free(input);
        const frame = try bake.frame(input);
        defer gpa.free(frame);
        var blocks: std.ArrayList([]const u8) = .empty;
        defer blocks.deinit(gpa);
        try frameBlocks(frame, &blocks);
        const arena = try gpa.alloc(u8, input.len + (1 << 17));
        defer gpa.free(arena);
        var spliced: std.ArrayList(u8) = .empty;
        defer spliced.deinit(gpa);
        for (blocks.items[1..], 1..) |b, n| {
            errdefer std.debug.print("kind {d}, block {d}\n", .{ kind, n });
            try dctx.decompressFrameExact(arena[0..input.len], frame, .{ .require_checksum = true });
            // No content size or checksum, an 8 MiB window, the block last.
            spliced.clearRetainingCapacity();
            try spliced.appendSlice(gpa, &.{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x68 });
            try spliced.appendSlice(gpa, b);
            spliced.items[6] |= 1;
            const expected = try gpa.alloc(u8, 1 << 17);
            defer gpa.free(expected);
            const code = c.ZSTD_decompressDCtx(udctx, expected.ptr, expected.len, spliced.items.ptr, spliced.items.len);
            const rest = arena[input.len..];
            if (c.ZSTD_isError(code) != 0) {
                refused += 1;
                try dc.expectSameResult(code, dctx.decompressFrameExact(rest, spliced.items, .{}));
            } else {
                decoded += 1;
                try dctx.decompressFrameExact(rest[0..code], spliced.items, .{});
                try testing.expectEqualSlices(u8, expected[0..code], rest[0..code]);
            }
        }
    }
    try testing.expect(refused > 0);
}

test "loomwork probe: the context's size and alignment are as the docs give them" {
    // README: "about 96 KB"; the static context's room is the original's
    // size, which holds the port's.
    try testing.expect(@alignOf(zstd.DCtx) <= 8);
    try testing.expect(@sizeOf(zstd.DCtx) >= 94_000 and @sizeOf(zstd.DCtx) < 98_000);
    try testing.expect(@sizeOf(zstd.DCtx) <= zstd.estimateDCtxSize());
}

// --------------------------------------------------------
// Findings
// --------------------------------------------------------

test "loomwork: an empty asset's valid frame is refused when its empty buffer comes from an allocator" {
    // A frame of content size 0 whose one block is an empty compressed
    // block (no literals, no sequences), as upstream's golden
    // empty-block.zst but with its size. `Allocator.alloc(u8, 0)` gives the
    // address maxInt(usize); the block decoder's check of a `dst` within
    // 1 MiB of the top of the address space then refuses the frame
    // (`error.DstSizeTooSmall`), where an empty array on the stack decodes
    // it, and the original decodes it into NULL, which a C caller passes
    // for an empty buffer. The engine's buffer for an empty asset is an
    // allocator's.
    const frame = [_]u8{
        0x28, 0xb5, 0x2f, 0xfd, // magic
        0x80, 0x00, 0, 0, 0, 0, // a window, content size 0 in 4 bytes
        0x15, 0x00, 0x00, // the last block, compressed, 2 bytes
        0x00, 0x00, // no literals, no sequences
    };
    const udctx = try upstreamDCtx();
    defer _ = c.ZSTD_freeDCtx(udctx);
    try testing.expectEqual(@as(usize, 0), c.ZSTD_decompressDCtx(udctx, null, 0, &frame, frame.len));
    var dctx: zstd.DCtx = undefined;
    dctx.init();
    var on_stack: [0]u8 = .{};
    try dctx.decompressFrameExact(&on_stack, &frame, .{});
    const empty = try gpa.alloc(u8, 0);
    defer gpa.free(empty);
    try testing.expectEqual(std.math.maxInt(usize), @intFromPtr(empty.ptr));
    try dctx.decompressFrameExact(empty, &frame, .{});
}

// --------------------------------------------------------
// Findings that end in a panic of the port (ReleaseSafe)
// --------------------------------------------------------

test "loomwork: a distribution of table log 15 with one symbol in all 32768 cells overflows readNCount's i16" {
    // `readNCount` (src/common/entropy_common.zig) stores each count with
    // `@intCast` into an i16. A header of table log 15 whose first symbol
    // takes every cell gives a count of 32768: the original stores
    // `(short)count`, -32768, and its callers then refuse the table log
    // (the largest a frame may use is 9). The port's cast overflows
    // first: a panic in a safe build, undefined behaviour in ReleaseFast.
    // Two frames of 64 bytes reach it, one through a literal lengths table,
    // one through the FSE-compressed weights of a Huffman table; a
    // dictionary reaches it through its offsets table.
    const ncount = [_]u8{ 0xFA, 0xFF, 0x0F, 0x00 }; // log 15, then 16 one bits
    const dict = [_]u8{
        0x37, 0xA4, 0x30, 0xEC, 1, 0, 0, 0, // the dictionary magic number, id 1
        0x81, 0x11, // Huffman weights 1, 1 (and 2)
    } ++ ncount ++ @as([40]u8, @splat(0));
    try testing.expect(c.ZSTD_createDDict(&dict, dict.len) == null);
    try testing.expectError(error.DictionaryCorrupted, zstd.createDDict(gpa, &dict));
    const seq_frame = [_]u8{
        0x28, 0xb5, 0x2f, 0xfd, 0x24, 0x40, // single segment, checksum, 64 bytes
        0x55, 0x00, 0x00, // the last block, compressed, 10 bytes
        0x00, // no literals
        0x01, 0x80, // one sequence; literal lengths FSE, the rest predefined
    } ++ ncount ++ [_]u8{ 0, 0, 0 } ++ [_]u8{ 0, 0, 0, 0 };
    const lit_frame = [_]u8{
        0x28, 0xb5, 0x2f, 0xfd, 0x24, 0x40,
        0x85, 0x00, 0x00, // the last block, compressed, 16 bytes
        0x02, 0x01, 0x03, // Huffman literals, 1 stream, 16 bytes from 12
        0x08, // 8 bytes of FSE-compressed weights
    } ++ ncount ++ [_]u8{ 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{0} ++ [_]u8{ 0, 0, 0, 0 };
    const udctx = try upstreamDCtx();
    defer _ = c.ZSTD_freeDCtx(udctx);
    for ([_][]const u8{ &seq_frame, &lit_frame }) |frame| {
        var expected: [64]u8 = undefined;
        const code = c.ZSTD_decompressDCtx(udctx, &expected, expected.len, frame.ptr, frame.len);
        try testing.expectEqual(@as(usize, 20), c.ZSTD_getErrorCode(code)); // corruption_detected
        var dctx: zstd.DCtx = undefined;
        dctx.init();
        var out: [64]u8 = undefined;
        try dc.expectSameResult(code, dctx.decompressFrameExact(&out, frame, .{ .require_checksum = true }));
    }
}
