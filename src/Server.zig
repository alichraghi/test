const std = @import("std");
const IO = @import("iofthetiger").IO;
const allocator = @import("main.zig").allocator;

const os = std.os;
const log = std.log.scoped(.http);

const Server = @This();

const kernel_backlog = 128;
const recv_buf_len = 512;
const io_entries = 256;

io: IO,
address: std.net.Address,
socket: os.socket_t,
accepting: bool = true,

pub fn init(ip: [4]u8, port: u16) !Server {
    var io = try IO.init(io_entries, 0);
    const address = std.net.Address.initIp4(ip, port);
    const socket = try io.open_socket(address.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
    try os.setsockopt(socket, os.SOL.SOCKET, os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try os.bind(socket, &address.any, address.getOsSockLen());
    try os.listen(socket, kernel_backlog);

    log.info("HTTP Server is listening on {}.", .{address});

    return .{
        .io = io,
        .address = address,
        .socket = socket,
    };
}

pub fn deinit(server: *Server) void {
    os.close(server.socket);
    server.io.deinit();
}

pub fn tick(server: *Server) !void {
    // Start accepting.
    var acceptor_completion: IO.Completion = undefined;
    server.io.accept(*Server, server, accept_callback, &acceptor_completion, server.socket);

    // Wait while accepting.
    while (server.accepting) try server.io.tick();
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
    const client = allocator.create(Client) catch unreachable;
    client.* = .{
        .io = &server.io,
        .socket = result catch @panic("accept error"),
    };

    // Receive from client.
    server.io.recv(
        *Client,
        client,
        recv_callback,
        &client.completion,
        client.socket,
        &client.recv_buf,
    );

    server.accepting = false;
}

const Client = struct {
    io: *IO,
    socket: os.socket_t,
    completion: IO.Completion = undefined,
    recv_buf: [recv_buf_len]u8 = undefined,
    resp_buf: [2048]u8 = undefined,
};

fn recv_callback(
    client: *Client,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    const received = result catch |err| blk: {
        log.err("recv_callback error: {}", .{err});
        break :blk 0;
    };

    if (received == 0) {
        // Client connection closed.
        client.io.close(
            *Client,
            client,
            close_callback,
            completion,
            client.socket,
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

    client.io.send(
        *Client,
        client,
        send_callback,
        completion,
        client.socket,
        response,
    );
}

fn send_callback(
    client: *Client,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    _ = result catch {};
    // Try to receive from client again (keep-alive).
    client.io.recv(
        *Client,
        client,
        recv_callback,
        completion,
        client.socket,
        &client.recv_buf,
    );
}

fn close_callback(
    client: *Client,
    completion: *IO.Completion,
    result: IO.CloseError!void,
) void {
    _ = completion;
    _ = result catch @panic("close_callback");
    allocator.destroy(client);
}
