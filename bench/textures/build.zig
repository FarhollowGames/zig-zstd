const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Always ReleaseFast: the BC7 encoder is slow in Debug, and the bytes do
    // not depend on the mode.
    const optimize: std.builtin.Optimize = .fast;

    const bcn = b.dependency("bcn", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "gen-textures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bcn", .module = bcn.module("bcn") }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Encode the photos: zig build run -- <photo dir> <output dir>").dependOn(&run.step);
}
