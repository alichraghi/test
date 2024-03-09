const std = @import("std");
const IO = @import("iofthetiger").IO;
const Server = @import("Server.zig");

var running = true;
var fba_buf: [8 * 1024 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&fba_buf);

pub var io: IO = undefined;

pub const io_entries = 256;
pub const allocator = fba.allocator();

pub fn main() !void {
    // Cross-platform IO setup.
    io = try IO.init(io_entries, 0);
    defer io.deinit();

    // Listener setup
    var server = try Server.init(.{ 127, 0, 0, 1 }, 8080);
    defer server.deinit();

    while (running) {
        try server.tick();
    }
}
