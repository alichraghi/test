const std = @import("std");
const IO = @import("iofthetiger").IO;
const io = &@import("main.zig").io;
const allocator = @import("main.zig").allocator;

const os = std.os;
const log = std.log.scoped(.server);

const Server = @This();

const kernel_backlog = 128;
const recv_buf_len = 512;

address: std.net.Address,
socket: os.socket_t,
accepting: bool = true,

pub fn init(ip: [4]u8, port: u16) !Server {
    const address = std.net.Address.initIp4(ip, port);
    const socket = try io.open_socket(address.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
    try os.setsockopt(socket, os.SOL.SOCKET, os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try os.bind(socket, &address.any, address.getOsSockLen());
    try os.listen(socket, kernel_backlog);

    log.info("server listening on IP {s} port {}.", .{ ip, port });

    return .{ .address = address, .socket = socket };
}

pub fn deinit(server: *Server) void {
    os.close(server.socket);
}

pub fn tick(server: *Server) !void {
    // Start accepting.
    var acceptor_completion: IO.Completion = undefined;
    io.accept(*Server, server, accept_callback, &acceptor_completion, server.socket);

    // Wait while accepting.
    while (server.accepting) try io.tick();
    // Reset accepting flag.
    server.accepting = true;
}

fn accept_callback(
    server: *Server,
    completion: *IO.Completion,
    result: IO.AcceptError!os.socket_t,
) void {
    _ = completion;

    // Allocate and init new client.
    const client_ptr = allocator.create(Client) catch unreachable;
    client_ptr.* = .{ .socket = result catch @panic("accept error") };

    // Receive from client.
    io.recv(
        *Client,
        client_ptr,
        recv_callback,
        &client_ptr.completion,
        client_ptr.socket,
        &client_ptr.recv_buf,
    );

    server.accepting = false;
}

const Client = struct {
    socket: os.socket_t,
    completion: IO.Completion = undefined,
    recv_buf: [recv_buf_len]u8 = undefined,
};

fn recv_callback(
    client_ptr: *Client,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    const received = result catch |err| blk: {
        log.err("recv_callback error: {}", .{err});
        break :blk 0;
    };

    if (received == 0) {
        // Client connection closed.
        io.close(
            *Client,
            client_ptr,
            close_callback,
            completion,
            client_ptr.socket,
        );
        return;
    }

    const response =
        \\HTTP/1.1 200 OK
        \\Connection: Keep-Alive
        \\Keep-Alive: timeout=1
        \\Content-Type: text/plain
        \\Content-Length: 6
        \\Server: server/0.1.0
        \\
        \\Hello
        \\
    ;

    io.send(
        *Client,
        client_ptr,
        send_callback,
        completion,
        client_ptr.socket,
        response,
    );
}

fn send_callback(
    client_ptr: *Client,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    _ = result catch {};
    // Try to receive from client again (keep-alive).
    io.recv(
        *Client,
        client_ptr,
        recv_callback,
        completion,
        client_ptr.socket,
        &client_ptr.recv_buf,
    );
}

fn close_callback(
    client_ptr: *Client,
    completion: *IO.Completion,
    result: IO.CloseError!void,
) void {
    _ = completion;
    _ = result catch @panic("close_callback");
    allocator.destroy(client_ptr);
}
