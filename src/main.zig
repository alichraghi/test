const std = @import("std");
const builtin = @import("builtin");
const IO = @import("iofthetiger").IO;
const HTTPServer = @import("HTTPServer.zig");
const SRTServer = @import("SRTServer.zig");

const log = std.log.scoped(.gael);

var fba_buf: [8 * 1024 * 1024]u8 = undefined; // 8MB
var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = if (builtin.mode == .Debug) gpa.allocator() else fba.threadSafeAllocator();

var running = std.atomic.Value(bool).init(true);

pub fn main() !void {
    defer _ = gpa.deinit();

    const srt_thread = try std.Thread.spawn(.{}, srt_server_thread, .{});
    defer srt_thread.join();

    const http_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8000);
    var http_server = try HTTPServer.init(allocator, http_address);
    defer http_server.deinit();

    while (running.load(.monotonic)) {
        try http_server.tick();
    }
}

fn srt_server_thread() void {
    var srt_server = SRTServer.init(allocator, 9000) catch |err| {
        log.err("Initializing SRT Server failed: {s}", .{@errorName(err)});
        running.store(false, .monotonic);
        return;
    };
    defer srt_server.deinit();
    srt_server.run() catch unreachable;
}
