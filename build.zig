const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const srt = b.dependency("srt", .{ .target = target, .optimize = optimize });
    const ffmpeg = b.dependency("ffmpeg", .{ .target = target, .optimize = optimize });
    const sqlite = b.dependency("sqlite", .{ .target = target, .optimize = optimize });
    const mime = b.dependency("mime", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "gael",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkSystemLibrary("curl");
    exe.linkLibrary(srt.artifact("srt"));
    exe.linkLibrary(ffmpeg.artifact("ffmpeg"));
    exe.root_module.addImport("mime", mime.module("mime"));
    exe.root_module.addAnonymousImport("index.html", .{ .root_source_file = .{ .path = "static/index.html" } });
    exe.root_module.addAnonymousImport("not_found.html", .{ .root_source_file = .{ .path = "static/not_found.html" } });
    exe.root_module.addAnonymousImport("internal_error.html", .{ .root_source_file = .{ .path = "static/internal_error.html" } });

    //  SQlite
    exe.addIncludePath(sqlite.path(""));
    exe.addCSourceFile(.{ .file = sqlite.path("sqlite3.c") });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
