// const std = @import("std");
// const RTMPServer = @import("RTMPServer.zig");

// var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// pub const allocator = gpa.allocator();

// pub fn main() !void {
//     defer _ = gpa.deinit();
//     try rtmp_main();
// }

// pub var rtmp_server: RTMPServer = undefined;
// fn rtmp_main() !void {
//     rtmp_server = try RTMPServer.init(.{ 127, 0, 0, 1 }, 1935);
//     defer rtmp_server.deinit();

//     while (true) {
//         try rtmp_server.tick();
//     }
// }

// SRT

const std = @import("std");
// const IO = @import("iofthetiger").IO;
// const Server = @import("Server.zig");
const SRTServer = @import("SRTServer.zig");

var running = true;
// var fba_buf: [8 * 1024 * 1024 * 1024]u8 = undefined;
// var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub const allocator = gpa.allocator();

pub fn main() !void {
    defer _ = gpa.deinit();

    var srt_server = try SRTServer.init(.{ 127, 0, 0, 1 }, 1935);
    defer srt_server.deinit();

    // const http_thread = try std.Thread.spawn(.{}, http_handler, .{&srt_server});
    // defer http_thread.join();

    while (true) {
        try srt_server.tick();
    }
}

fn http_handler(srt: *SRTServer) !void {
    _ = srt;
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    var http_server = try addr.listen(.{ .reuse_address = true });
    while (true) {
        const conn = try http_server.accept();
        _ = try std.Thread.spawn(.{}, conn_handler, .{conn});
    }
}

fn conn_handler(conn: std.net.Server.Connection) !void {
    var send_buf: [2 * 1024 * 1024]u8 = undefined;
    var read_buf: [2 * 1024 * 1024]u8 = undefined;

    var buf: [1 * 1024 * 1024]u8 = undefined;
    var http_conn = std.http.Server.init(conn, &buf);
    var req = try http_conn.receiveHead();
    const file = std.fs.cwd().openFile(req.head.target[1..], .{}) catch {
        try req.respond("404", .{ .status = .not_found });
        return;
    };
    var resp = req.respondStreaming(.{ .send_buffer = &send_buf, .respond_options = .{ .transfer_encoding = .chunked } });
    while (true) {
        const read = file.read(&read_buf) catch break;
        if (read == 0) break;
        _ = try resp.write(read_buf[0..read]);
    }
    try resp.end();
}
