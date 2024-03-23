const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const iofthetiger = b.dependency("iofthetiger", .{ .target = target, .optimize = optimize });
    const srt = b.dependency("srt", .{ .target = target, .optimize = optimize });
    const ffmpeg = b.dependency("ffmpeg", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "gael",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("iofthetiger", iofthetiger.module("io"));
    exe.linkLibrary(srt.artifact("srt"));
    exe.linkLibrary(ffmpeg.artifact("ffmpeg"));
    b.installArtifact(exe);

    // const transcode = b.addExecutable(.{
    //     .name = "transcode",
    //     .root_source_file = .{ .path = "transcode.zig" },
    //     .target = target,
    //     .optimize = optimize,
    // });
    // transcode.linkLibrary(ffmpeg.artifact("ffmpeg"));
    // b.installArtifact(transcode);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
