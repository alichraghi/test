const std = @import("std");
const IO = @import("iofthetiger").IO;

const os = std.os;
const log = std.log.scoped(.http);

const HTTPServer = @This();

const kernel_backlog = 128;
const recv_buf_len = std.mem.page_size;
const io_entries = 256;

allocator: std.mem.Allocator,
io: IO,
address: std.net.Address,
socket: os.socket_t,
accepting: bool = true,

pub fn init(allocator: std.mem.Allocator, address: std.net.Address) !HTTPServer {
    var io = try IO.init(io_entries, 0);
    const socket = try io.open_socket(address.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
    try os.setsockopt(socket, os.SOL.SOCKET, os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try os.bind(socket, &address.any, address.getOsSockLen());
    try os.listen(socket, kernel_backlog);

    log.info("HTTP Server is listening on {}.", .{address});

    return .{
        .allocator = allocator,
        .io = io,
        .address = address,
        .socket = socket,
    };
}

pub fn deinit(server: *HTTPServer) void {
    os.close(server.socket);
    server.io.deinit();
}

pub fn tick(server: *HTTPServer) !void {
    // Start accepting.
    var acceptor_completion: IO.Completion = undefined;
    server.io.accept(*HTTPServer, server, accept_callback, &acceptor_completion, server.socket);

    // Wait while accepting.
    while (server.accepting) try server.io.tick();
    // Reset accepting flag.
    server.accepting = true;
}

fn accept_callback(
    server: *HTTPServer,
    completion: *IO.Completion,
    result: IO.AcceptError!os.socket_t,
) void {
    _ = completion;

    // Allocate and init new client.
    const client = server.allocator.create(Client) catch unreachable;
    client.* = .{
        .server = server,
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
    server: *HTTPServer,
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
        \\HTTPServer: server/0.1.0
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
    client.server.allocator.destroy(client);
}
