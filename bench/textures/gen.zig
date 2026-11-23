//! Encodes the benchmark photos with zig-bcn.
//!
//! Usage:
//!
//!   gen-textures <photo dir> <output dir>
//!   gen-textures --atlas <photo dir> <output dir>
//!
//! Both read `<photo dir>/photos.txt` (lines "<name> <width> <height>") and
//! each `<photo dir>/<name>.rgba` written by extract.py.
//!
//! The first form writes, per photo:
//!
//!   <name>.bc7  the photo, BC7, `bcn.bc7.Params.init(.basic, true)`
//!   <name>.bc5  a tangent-space normal map made from the photo, BC5
//!
//! `--atlas` writes four 2048 x 2048 mosaics of the photos (see `atlases`)
//! with their mip chains, levels 0 to 9 (2048 down to 4):
//!
//!   tex<k>.mip<L>.bc7  level L of mosaic k, BC7, the same settings
//!   tex<k>.mip<L>.bc5  level L of mosaic k's normal map, BC5
//!
//! Every file is raw blocks, 16 bytes per 4x4 block, in row-major block order.

const std = @import("std");
const bcn = @import("bcn");

/// Scale of the height field's slopes before normalising: a height step of
/// 1/255 across one pixel tilts the normal by about 4/255.
const normal_strength: f64 = 4.0;

/// Block rows per parallel task. The bytes do not depend on it.
const band_rows: u32 = 4;

const bc7_encoding: bcn.Encoding = .{ .bc7 = bcn.bc7.Params.init(.basic, true) };
const bc5_encoding: bcn.Encoding = .bc5;

/// Side of the mosaics, and their number of mip levels (2048 down to 4).
const atlas_side: u32 = 2048;
const atlas_levels: u32 = 10;
/// Height of the strips the photos are cut into for the mosaics.
const strip_height: u32 = 128;

/// One mosaic: the photo order of its ribbon and where along the ribbon its
/// first pixel is.
const Atlas = struct {
    order: [7][]const u8,
    start: u32,
};

const atlases = [_]Atlas{
    .{ .order = .{ "astronaut", "chelsea", "coffee", "rocket", "hubble_deep_field", "retina", "ihc" }, .start = 0 },
    .{ .order = .{ "retina", "coffee", "ihc", "hubble_deep_field", "chelsea", "rocket", "astronaut" }, .start = 7552 },
    .{ .order = .{ "hubble_deep_field", "astronaut", "rocket", "retina", "ihc", "coffee", "chelsea" }, .start = 15104 },
    .{ .order = .{ "ihc", "rocket", "retina", "chelsea", "astronaut", "hubble_deep_field", "coffee" }, .start = 22656 },
};

const Photo = struct {
    name: []const u8,
    width: u32,
    height: u32,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(arena);
    const atlas_mode = all_args.len == 4 and std.mem.eql(u8, all_args[1], "--atlas");
    const args = if (atlas_mode) all_args[2..] else all_args[1..];
    if (args.len != 2) {
        std.debug.print("usage: gen-textures [--atlas] <photo dir> <output dir>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    var in_dir = try cwd.openDir(io, args[0], .{});
    defer in_dir.close(io);
    try cwd.createDirPath(io, args[1]);
    var out_dir = try cwd.openDir(io, args[1], .{});
    defer out_dir.close(io);

    const manifest = try in_dir.readFileAlloc(io, "photos.txt", arena, .limited(1 << 16));
    const photos = try parseManifest(arena, manifest);

    if (atlas_mode) {
        const pixels = try arena.alloc([]const u8, photos.len);
        for (photos, pixels) |p, *px| px.* = try readRgba(arena, io, in_dir, p);
        for (atlases, 0..) |atlas, k| try encodeAtlas(gpa, io, out_dir, photos, pixels, atlas, @intCast(k));
    } else {
        for (photos) |p| {
            const rgba = try readRgba(gpa, io, in_dir, p);
            defer gpa.free(rgba);
            try encodePhoto(gpa, io, out_dir, p, rgba);
        }
    }
}

fn parseManifest(arena: std.mem.Allocator, manifest: []const u8) ![]Photo {
    var photos: std.ArrayList(Photo) = .empty;
    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const name = fields.next() orelse continue;
        const width = try std.fmt.parseInt(u32, fields.next() orelse return error.BadManifest, 10);
        const height = try std.fmt.parseInt(u32, fields.next() orelse return error.BadManifest, 10);
        if (fields.next() != null) return error.BadManifest;
        if (width == 0 or height == 0 or width % 4 != 0 or height % 4 != 0) return error.BadSize;
        if (width > 16384 or height > 16384) return error.BadSize;
        try photos.append(arena, .{ .name = name, .width = width, .height = height });
    }
    return photos.items;
}

fn readRgba(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, photo: Photo) ![]u8 {
    const len = @as(usize, photo.width) * photo.height * 4;
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}.rgba", .{photo.name});
    const rgba = try dir.readFileAlloc(io, path, gpa, .limited(len + 1));
    if (rgba.len != len) return error.BadRgbaSize;
    return rgba;
}

/// Encodes `pixels` (`channels` per pixel) and writes the blocks to `name`.
fn encodeTo(
    gpa: std.mem.Allocator,
    io: std.Io,
    out_dir: std.Io.Dir,
    name: []const u8,
    encoding: *const bcn.Encoding,
    pixels: []const u8,
    width: u32,
    height: u32,
    channels: u8,
) !void {
    const blocks = try gpa.alloc(u8, encoding.encodedLen(width, height));
    defer gpa.free(blocks);
    try bcn.encodeImageParallel(io, encoding, .{ .unorm8 = bcn.Image(u8).init(pixels, width, height, channels) }, blocks, band_rows);
    try out_dir.writeFile(io, .{ .sub_path = name, .data = blocks });
}

fn encodePhoto(gpa: std.mem.Allocator, io: std.Io, out_dir: std.Io.Dir, photo: Photo, rgba: []const u8) !void {
    const w = photo.width;
    const h = photo.height;
    var path_buf: [256]u8 = undefined;

    // BC7 of the photo.
    try encodeTo(gpa, io, out_dir, try std.fmt.bufPrint(&path_buf, "{s}.bc7", .{photo.name}), &bc7_encoding, rgba, w, h, 4);

    // BC5 of its normal map: X in channel 0, Y in channel 1.
    const vectors = try gpa.alloc([3]f64, @as(usize, w) * h);
    defer gpa.free(vectors);
    try normalVectors(gpa, rgba, w, h, vectors);
    const normals = try gpa.alloc(u8, vectors.len * 2);
    defer gpa.free(normals);
    normalBytes(vectors, normals);
    try encodeTo(gpa, io, out_dir, try std.fmt.bufPrint(&path_buf, "{s}.bc5", .{photo.name}), &bc5_encoding, normals, w, h, 2);

    std.debug.print("{s}: {d}x{d}, {d} blocks\n", .{ photo.name, w, h, (w / 4) * (h / 4) });
}

/// Builds mosaic `k` and writes its BC7 and BC5 mip chains.
fn encodeAtlas(
    gpa: std.mem.Allocator,
    io: std.Io,
    out_dir: std.Io.Dir,
    photos: []const Photo,
    pixels: []const []const u8,
    atlas: Atlas,
    k: u32,
) !void {
    const side: usize = atlas_side;
    var rgba = try gpa.alloc(u8, side * side * 4);
    defer gpa.free(rgba);
    try buildMosaic(gpa, photos, pixels, atlas, rgba);

    var vectors = try gpa.alloc([3]f64, side * side);
    defer gpa.free(vectors);
    try normalVectors(gpa, rgba, atlas_side, atlas_side, vectors);
    const normals = try gpa.alloc(u8, side * side * 2);
    defer gpa.free(normals);

    var path_buf: [256]u8 = undefined;
    var level: u32 = 0;
    var s: u32 = atlas_side;
    while (true) {
        const n = @as(usize, s) * s;
        try encodeTo(gpa, io, out_dir, try std.fmt.bufPrint(&path_buf, "tex{d}.mip{d}.bc7", .{ k, level }), &bc7_encoding, rgba[0 .. n * 4], s, s, 4);
        normalBytes(vectors[0..n], normals[0 .. n * 2]);
        try encodeTo(gpa, io, out_dir, try std.fmt.bufPrint(&path_buf, "tex{d}.mip{d}.bc5", .{ k, level }), &bc5_encoding, normals[0 .. n * 2], s, s, 2);
        level += 1;
        if (level == atlas_levels) break;
        downsampleRgba(rgba, s);
        downsampleNormals(vectors, s);
        s /= 2;
    }
    std.debug.print("tex{d}: {d} levels, {d} down to {d}\n", .{ k, atlas_levels, atlas_side, s });
}

/// Fills `out` (atlas_side squared, RGBA8) with mosaic `atlas`.
///
/// Each photo, in `atlas.order`, is cut into strips of `strip_height` rows
/// from the top (rows below the last whole strip are left out), and the
/// strips are laid end to end into one long ribbon `strip_height` rows high:
/// photo by photo, top strip first. The canvas is 16 bands of
/// `strip_height` rows, filled left to right and top to bottom from the
/// ribbon, starting `atlas.start` pixels into it; band b, column x is ribbon
/// pixel `start + b * atlas_side + x`. A strip that reaches the right edge
/// goes on at the left of the next band. The ribbon is shorter than the
/// canvas needs, so it repeats; on every second pass each strip is mirrored
/// left to right, so that no part of the canvas is a copy of another.
fn buildMosaic(
    gpa: std.mem.Allocator,
    photos: []const Photo,
    pixels: []const []const u8,
    atlas: Atlas,
    out: []u8,
) !void {
    const Strip = struct { photo: usize, row: u32, pos: u64 };
    var strips: std.ArrayList(Strip) = .empty;
    defer strips.deinit(gpa);
    var ribbon_len: u64 = 0;
    for (atlas.order) |name| {
        const index = for (photos, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, name)) break i;
        } else return error.MissingPhoto;
        const p = photos[index];
        var row: u32 = 0;
        while (row + strip_height <= p.height) : (row += strip_height) {
            try strips.append(gpa, .{ .photo = index, .row = row, .pos = ribbon_len });
            ribbon_len += p.width;
        }
    }

    const side: usize = atlas_side;
    const bands = atlas_side / strip_height;
    for (0..bands) |band| {
        var x: u32 = 0;
        var strip_index: usize = 0;
        while (x < atlas_side) {
            const t: u64 = atlas.start + band * side + x;
            const mirrored = (t / ribbon_len) % 2 == 1;
            const u = t % ribbon_len;
            // The strip that holds ribbon pixel u.
            strip_index = 0;
            while (strip_index + 1 < strips.items.len and strips.items[strip_index + 1].pos <= u) strip_index += 1;
            const strip = strips.items[strip_index];
            const p = photos[strip.photo];
            const col0: u32 = @intCast(u - strip.pos);
            const run = @min(p.width - col0, atlas_side - x);
            for (0..strip_height) |r| {
                const src_row = pixels[strip.photo][(@as(usize, strip.row) + r) * p.width * 4 ..][0 .. @as(usize, p.width) * 4];
                const dst_row = out[(band * strip_height + r) * side * 4 ..][0 .. side * 4];
                for (0..run) |c| {
                    const col = col0 + c;
                    const src_col = if (mirrored) p.width - 1 - col else col;
                    dst_row[(x + c) * 4 ..][0..4].* = src_row[src_col * 4 ..][0..4].*;
                }
            }
            x += run;
        }
    }
}

/// Replaces the first (s/2)^2 pixels of `rgba`, an s x s RGBA8 image, with
/// its 2x2 box average: (a + b + c + d + 2) / 4 per channel.
fn downsampleRgba(rgba: []u8, s: u32) void {
    const half = s / 2;
    for (0..half) |y| {
        for (0..half) |x| {
            const tl = (2 * y * s + 2 * x) * 4;
            const bl = tl + @as(usize, s) * 4;
            var px: [4]u8 = undefined;
            for (0..4) |c| {
                const sum = @as(u32, rgba[tl + c]) + rgba[tl + 4 + c] + rgba[bl + c] + rgba[bl + 4 + c];
                px[c] = @intCast((sum + 2) / 4);
            }
            // The destination pixel comes before every source pixel still
            // to be read, so the image can shrink in place.
            rgba[(y * half + x) * 4 ..][0..4].* = px;
        }
    }
}

/// Replaces the first (s/2)^2 vectors of `v`, an s x s normal map, with the
/// normalised sum of each 2x2 square (top left, top right, bottom left,
/// bottom right, in that order).
fn downsampleNormals(v: [][3]f64, s: u32) void {
    const half = s / 2;
    for (0..half) |y| {
        for (0..half) |x| {
            const tl = 2 * y * s + 2 * x;
            const bl = tl + s;
            var n: [3]f64 = undefined;
            for (0..3) |c| n[c] = ((v[tl][c] + v[tl + 1][c]) + v[bl][c]) + v[bl + 1][c];
            const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
            v[y * half + x] = .{ n[0] / len, n[1] / len, n[2] / len };
        }
    }
}

/// Writes the unit tangent-space normals of `rgba`, taking its luminance as
/// a height field, into `out` (one per pixel).
///
/// - Height: 54 R + 183 G + 19 B (Rec. 709 weights in 256ths), an integer
///   from 0 to 65280 standing for 0 to 1.
/// - Slopes: 3x3 Sobel filters, edge pixels repeated; each sum is divided by
///   8 so it is a slope per pixel.
/// - Normal: (-s dh/dx, +s dh/dy, 1) normalised, with y counted down the
///   image, so +Y points up the image (the OpenGL convention), s = 4.
fn normalVectors(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32, out: [][3]f64) !void {
    const w: usize = width;
    const h: usize = height;
    const lum = try gpa.alloc(i32, w * h);
    defer gpa.free(lum);
    for (lum, 0..) |*l, i| {
        const p = rgba[i * 4 ..][0..3];
        l.* = 54 * @as(i32, p[0]) + 183 * @as(i32, p[1]) + 19 * @as(i32, p[2]);
    }

    const scale = normal_strength / (8.0 * 65280.0);
    for (0..h) |y| {
        const ym = if (y == 0) 0 else y - 1;
        const yp = @min(y + 1, h - 1);
        for (0..w) |x| {
            const xm = if (x == 0) 0 else x - 1;
            const xp = @min(x + 1, w - 1);
            const gx = (lum[ym * w + xp] + 2 * lum[y * w + xp] + lum[yp * w + xp]) -
                (lum[ym * w + xm] + 2 * lum[y * w + xm] + lum[yp * w + xm]);
            const gy = (lum[yp * w + xm] + 2 * lum[yp * w + x] + lum[yp * w + xp]) -
                (lum[ym * w + xm] + 2 * lum[ym * w + x] + lum[ym * w + xp]);
            const nx = -@as(f64, @floatFromInt(gx)) * scale;
            const ny = @as(f64, @floatFromInt(gy)) * scale;
            const len = @sqrt(nx * nx + ny * ny + 1.0);
            out[y * w + x] = .{ nx / len, ny / len, 1.0 / len };
        }
    }
}

/// The X and Y bytes of each normal: floor((n * 0.5 + 0.5) * 255 + 0.5).
fn normalBytes(vectors: []const [3]f64, out: []u8) void {
    for (vectors, 0..) |n, i| {
        out[i * 2 + 0] = toByte(n[0]);
        out[i * 2 + 1] = toByte(n[1]);
    }
}

fn toByte(v: f64) u8 {
    const b = @floor((v * 0.5 + 0.5) * 255.0 + 0.5);
    return @intFromFloat(std.math.clamp(b, 0.0, 255.0));
}
