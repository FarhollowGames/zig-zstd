//! Encodes the benchmark photos with zig-bcn.
//!
//! Usage: gen-textures <photo dir> <output dir>
//!
//! Reads `<photo dir>/photos.txt` (lines "<name> <width> <height>") and each
//! `<photo dir>/<name>.rgba` written by extract.py, and writes per photo:
//!
//!   <name>.bc7  the photo, BC7, `bcn.bc7.Params.init(.basic, true)`
//!   <name>.bc5  a tangent-space normal map made from the photo, BC5
//!
//! Both are raw blocks, 16 bytes per 4x4 block, in row-major block order.

const std = @import("std");
const bcn = @import("bcn");

/// Scale of the height field's slopes before normalising: a height step of
/// 1/255 across one pixel tilts the normal by about 4/255.
const normal_strength: f64 = 4.0;

/// Block rows per parallel task. The bytes do not depend on it.
const band_rows: u32 = 4;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: {s} <photo dir> <output dir>\n", .{if (args.len > 0) args[0] else "gen-textures"});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    var in_dir = try cwd.openDir(io, args[1], .{});
    defer in_dir.close(io);
    try cwd.createDirPath(io, args[2]);
    var out_dir = try cwd.openDir(io, args[2], .{});
    defer out_dir.close(io);

    const manifest = try in_dir.readFileAlloc(io, "photos.txt", gpa, .limited(1 << 16));
    defer gpa.free(manifest);

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
        try encodePhoto(gpa, io, in_dir, out_dir, name, width, height);
    }
}

fn encodePhoto(
    gpa: std.mem.Allocator,
    io: std.Io,
    in_dir: std.Io.Dir,
    out_dir: std.Io.Dir,
    name: []const u8,
    width: u32,
    height: u32,
) !void {
    const pixels: usize = @as(usize, width) * height;
    var path_buf: [256]u8 = undefined;

    const rgba_path = try std.fmt.bufPrint(&path_buf, "{s}.rgba", .{name});
    const rgba = try in_dir.readFileAlloc(io, rgba_path, gpa, .limited(pixels * 4 + 1));
    defer gpa.free(rgba);
    if (rgba.len != pixels * 4) return error.BadRgbaSize;

    const blocks = try gpa.alloc(u8, bcn.encodedLen(16, width, height));
    defer gpa.free(blocks);

    // BC7 of the photo.
    const bc7: bcn.Encoding = .{ .bc7 = bcn.bc7.Params.init(.basic, true) };
    try bcn.encodeImageParallel(io, &bc7, .{ .unorm8 = bcn.Image(u8).init(rgba, width, height, 4) }, blocks, band_rows);
    try out_dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buf, "{s}.bc7", .{name}), .data = blocks });

    // BC5 of its normal map: X in channel 0, Y in channel 1.
    const normals = try gpa.alloc(u8, pixels * 2);
    defer gpa.free(normals);
    try normalMap(gpa, rgba, width, height, normals);
    const bc5: bcn.Encoding = .bc5;
    try bcn.encodeImageParallel(io, &bc5, .{ .unorm8 = bcn.Image(u8).init(normals, width, height, 2) }, blocks, band_rows);
    try out_dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buf, "{s}.bc5", .{name}), .data = blocks });

    std.debug.print("{s}: {d}x{d}, {d} blocks\n", .{ name, width, height, blocks.len / 16 });
}

/// Writes the X and Y bytes of a tangent-space normal map of `rgba`, taking
/// its luminance as a height field, into `out` (2 bytes per pixel).
///
/// - Height: 54 R + 183 G + 19 B (Rec. 709 weights in 256ths), an integer
///   from 0 to 65280 standing for 0 to 1.
/// - Slopes: 3x3 Sobel filters, edge pixels repeated; each sum is divided by
///   8 so it is a slope per pixel.
/// - Normal: (-s dh/dx, +s dh/dy, 1) normalised, with y counted down the
///   image, so +Y points up the image (the OpenGL convention), s = 4.
/// - Bytes: floor((n * 0.5 + 0.5) * 255 + 0.5) for x and y.
fn normalMap(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32, out: []u8) !void {
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
            out[(y * w + x) * 2 + 0] = toByte(nx / len);
            out[(y * w + x) * 2 + 1] = toByte(ny / len);
        }
    }
}

fn toByte(v: f64) u8 {
    const b = @floor((v * 0.5 + 0.5) * 255.0 + 0.5);
    return @intFromFloat(std.math.clamp(b, 0.0, 255.0));
}
