const std = @import("std");
const os = std.os;
// const xev = @import("xev");
const IO = @import("iofthetiger/src/io.zig").IO;

const CompletionPool = std.heap.MemoryPoolExtra(IO.Completion, .{});

var allocator_buffer: [8 * 1024 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&allocator_buffer);
var allocator = fba.allocator();

pub fn main() !void {
    var server = try Server.init();
    defer server.deinit();

    try server.run();
}

const Server = struct {
    io: IO,
    server: std.net.Server,
    completion_pool: CompletionPool,
    next_completion: *IO.Completion,

    const QUEUE_DEPTH = 32;

    fn init() !Server {
        const io = try IO.init(QUEUE_DEPTH, 0);
        const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
        const server = try address.listen(.{ .reuse_address = true });
        var completion_pool = CompletionPool.init(allocator);
        return .{
            .io = io,
            .server = server,
            .completion_pool = completion_pool,
            .next_completion = try completion_pool.create(),
        };
    }

    fn deinit(server: *Server) void {
        server.io.deinit();
        server.server.deinit();
    }

    fn run(server: *Server) !void {
        server.io.accept(*Server, server, Server.accept_callback, server.next_completion, server.server.stream.handle);
        while (true) {
            server.io.accept(*Server, server, Server.accept_callback, server.next_completion, server.server.stream.handle);
            try server.io.tick();
        }
    }

    fn accept_callback(
        server: *Server,
        completion: *IO.Completion,
        result: IO.AcceptError!os.socket_t,
    ) void {
        server.next_completion = server.completion_pool.create() catch @panic("OOM");
        const client_sock = result catch |err| std.debug.panic("accept error: {}", .{err});

        const handler = allocator.create(Handler) catch @panic("OOM");
        handler.* = .{ .server = server, .client_sock = client_sock };

        server.io.recv(
            *Handler,
            handler,
            Handler.recv_callback,
            completion,
            client_sock,
            &handler.recv_buf,
        );
    }
};

const Handler = struct {
    server: *Server,
    client_sock: os.socket_t,
    recv_buf: [2048]u8 = undefined,
    received: usize = 0,

    fn recv_callback(
        handler: *Handler,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        handler.received = result catch |err| std.debug.panic("recv error: {}", .{err});
        std.debug.print("{s}\n", .{handler.recv_buf[0..handler.received]});
        handler.server.io.close(
            *Handler,
            handler,
            close_callback,
            completion,
            handler.client_sock,
        );
    }

    fn close_callback(
        handler: *Handler,
        completion: *IO.Completion,
        result: IO.CloseError!void,
    ) void {
        _ = completion;
        result catch |err| std.debug.panic("close error: {}", .{err});
        allocator.destroy(handler);
    }
};
