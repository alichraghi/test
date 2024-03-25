const std = @import("std");
const IO = @import("iofthetiger").IO;
const HTTPServer = @import("HTTPServer.zig");
const SRTServer = @import("SRTServer.zig");

const log = std.log.scoped(.gael);

var running = std.atomic.Value(bool).init(true);

pub fn main() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa.deinit();
    // const allocator = gpa.allocator();

    var fba_buf: [8 * 1024 * 1024]u8 = undefined; // 8MB
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const allocator = fba.allocator();

    const srt_thread = try std.Thread.spawn(.{}, srt_server_thread, .{});
    defer srt_thread.join();

    const http_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8000);
    var http_server = try HTTPServer.init(allocator, http_address);
    defer http_server.deinit();

    while (running.load(.Monotonic)) {
        try http_server.tick();
    }
}

fn srt_server_thread() void {
    var fba_buf: [8 * 1024 * 1024]u8 = undefined; // 8MB
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const allocator = fba.allocator();

    const srt_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 9000);
    var srt_server = SRTServer.init(allocator, srt_address) catch |err| {
        log.err("Initializing SRT Server failed: {s}", .{@errorName(err)});
        running.store(false, .Monotonic);
        return;
    };
    defer srt_server.deinit();

    while (running.load(.Monotonic)) {
        srt_server.tick() catch |err| {
            log.warn("SRT Server: {s}", .{@errorName(err)});
        };
    }
}
