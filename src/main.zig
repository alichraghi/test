const std = @import("std");
const builtin = @import("builtin");
const HTTPServer = @import("HTTPServer.zig");
const SRTServer = @import("SRTServer.zig");
const Database = @import("Database.zig");

const log = std.log.scoped(.gael);
const Hash = std.crypto.auth.hmac.sha2.HmacSha256;

var fba_buf: [8 * 1024 * 1024]u8 = undefined; // 8MB
var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = if (builtin.mode == .Debug) gpa.allocator() else fba.threadSafeAllocator();

const key = "meow";

pub fn main() !void {
    defer _ = gpa.deinit();

    const exe_dir_path = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_dir_path);
    const exe_dir = try std.fs.openDirAbsolute(exe_dir_path, .{});
    try exe_dir.setAsCwd();

    const db = try Database.init();
    try db.setup();

    const insert_stmt = try db.prepare(Database.INSERT_USER);
    defer insert_stmt.deinit();
    try insert_stmt.bind(.{ 0, "ali", "123" });
    try insert_stmt.exec();

    const User = struct {
        id: i32,
        name: []const u8,
        password: []const u8,
    };

    const select_stmt = try db.prepare(Database.SELECT_USERS);
    defer select_stmt.deinit();
    const user = select_stmt.row(User) orelse unreachable;
    log.info("id: {}, name: {s}, pass: {s}", .{ user.id, user.name, user.password });

    // SRT-Server
    var srt_server = SRTServer.init(allocator, 9000) catch |err| {
        log.err("Initializing SRT Server failed: {s}", .{@errorName(err)});
        return;
    };
    defer srt_server.deinit();

    const srt_thread = try std.Thread.spawn(.{}, SRTServer.run, .{&srt_server});
    defer srt_thread.join();

    // HTTP-Server
    const http_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8000);
    var http_server = try HTTPServer.init(allocator, http_address);
    defer http_server.deinit();

    const http_thread = try std.Thread.spawn(.{}, HTTPServer.run, .{&http_server});
    defer http_thread.join();

    // var out: [Hash.mac_length]u8 = undefined;
    // Hash.create(key, "password", &out);

    // Main loop
    var running = true;
    _ = &running;
    while (running) {}
}
