//! Thread-safe, Asynchronous SRT Server

const std = @import("std");
const c = @cImport(@cInclude("srt.h"));
const Remuxer = @import("Remuxer.zig");

const posix = std.posix;
const Thread = std.Thread;
const log = std.log.scoped(.srt);

const SRTServer = @This();

const MAX_CONNECTIONS = 100;
const KERNEL_BACKLOG = 10;

allocator: std.mem.Allocator,
sfd: c.SRTSOCKET,
epid: c_int,
running: std.atomic.Value(bool) = .{ .raw = true },
connections: std.AutoHashMapUnmanaged(c.SRTSOCKET, Connection) = .{},
recv_buf: [1316]u8 = undefined,

pub fn init(allocator: std.mem.Allocator, port: u16) !SRTServer {
    _ = c.srt_startup();

    var port_str_buf: [5]u8 = undefined;
    const port_str = std.fmt.bufPrintZ(&port_str_buf, "{}", .{port}) catch unreachable;

    var addr: *c.addrinfo = undefined;
    if (c.getaddrinfo(null, port_str, &.{
        .ai_flags = std.c.AI.PASSIVE,
        .ai_family = std.c.AF.INET,
        .ai_socktype = std.c.SOCK.DGRAM,
        .ai_protocol = 0,
        .ai_addrlen = 0,
        .ai_addr = null,
        .ai_canonname = null,
        .ai_next = null,
    }, @ptrCast(&addr)) != 0) {
        log.err("Illegal port number or port is busy", .{});
        return error.SystemResources;
    }
    defer c.freeaddrinfo(addr);

    const sfd = c.srt_create_socket();
    if (sfd == c.SRT_INVALID_SOCK) {
        log.err("{s}", .{err_msg()});
        return error.SystemResources;
    }

    var opt_value = false;
    if (c.srt_setsockopt(sfd, 0, c.SRTO_RCVSYN, &opt_value, @sizeOf(bool)) == c.SRT_ERROR) {
        log.err("{s}", .{err_msg()});
        return error.SystemResources;
    }

    if (c.srt_bind(sfd, addr.ai_addr, @intCast(addr.ai_addrlen)) == c.SRT_ERROR) {
        log.err("{s}", .{err_msg()});
        return error.SystemResources;
    }

    log.info("SRT Server is listening on 127.0.0.1:{}", .{port});

    if (c.srt_listen(sfd, KERNEL_BACKLOG) == c.SRT_ERROR) {
        log.err("{s}", .{err_msg()});
        return error.SystemResources;
    }

    const epid = c.srt_epoll_create();
    if (epid < 0) {
        log.err("{s}", .{err_msg()});
        return error.SystemResources;
    }

    var events = c.SRT_EPOLL_IN | c.SRT_EPOLL_ERR | (-@as(c_int, @intCast(~c.SRT_EPOLL_ET)) - 1);
    if (c.srt_epoll_add_usock(epid, sfd, &events) == c.SRT_ERROR) {
        log.err("{s}", .{err_msg()});
        return error.SystemResources;
    }

    try std.fs.cwd().makePath("live");

    return .{
        .allocator = allocator,
        .sfd = sfd,
        .epid = epid,
    };
}

pub fn deinit(srt: *SRTServer) void {
    srt.running.store(false, .release);
    var conns = srt.connections.valueIterator();
    while (conns.next()) |conn| conn.remuxer.deinit();

    _ = c.srt_close(srt.sfd);
    _ = c.srt_epoll_release(srt.epid);
    _ = c.srt_cleanup();
}

pub fn run(srt: *SRTServer) !void {
    var sockets: [MAX_CONNECTIONS]c.SRTSOCKET = undefined;
    var sockets_len: c_int = sockets.len;

    while (srt.running.load(.monotonic)) {
        const ready_sockets = c.srt_epoll_wait(srt.epid, &sockets, &sockets_len, 0, 0, 100, 0, 0, 0, 0);
        if (ready_sockets < 0) continue;
        std.debug.assert(ready_sockets <= sockets_len);

        for (sockets[0..@intCast(ready_sockets)]) |s| {
            const status = c.srt_getsockstate(s);

            switch (status) {
                c.SRTS_INIT, c.SRTS_OPENED, c.SRTS_CLOSING, c.SRTS_CONNECTING => {},
                c.SRTS_BROKEN, c.SRTS_NONEXIST, c.SRTS_CLOSED => {
                    const conn = srt.connections.getPtr(s).?;
                    conn.deinit(srt.allocator);
                    _ = srt.connections.remove(s);
                    _ = c.srt_close(s);
                    log.info("Connection closed with status ({d})", .{status});
                    continue;
                },
                c.SRTS_LISTENING => {
                    std.debug.assert(s == srt.sfd);

                    var client_socket: c.SRTSOCKET = undefined;
                    var client_addr: c.sockaddr_storage = undefined;
                    var addrlen: c_int = @sizeOf(c.sockaddr_storage);

                    client_socket = c.srt_accept(srt.sfd, @ptrCast(&client_addr), &addrlen);
                    if (client_socket == c.SRT_INVALID_SOCK) {
                        log.warn("{s}", .{err_msg()});
                        continue;
                    }

                    var stream_id_buf: [128]u8 = undefined;
                    var stream_id_len: c_int = stream_id_buf.len;
                    _ = c.srt_getsockflag(client_socket, c.SRTO_STREAMID, &stream_id_buf, &stream_id_len);
                    const stream_id = stream_id_buf[0..@intCast(stream_id_len)];

                    var client_ip: [c.NI_MAXHOST]u8 = undefined;
                    var client_port: [c.NI_MAXSERV]u8 = undefined;
                    _ = c.getnameinfo(
                        @ptrCast(&client_addr),
                        @intCast(addrlen),
                        &client_ip,
                        client_ip.len,
                        &client_port,
                        client_port.len,
                        c.NI_NUMERICHOST | c.NI_NUMERICSERV,
                    );
                    log.info("New connection: {s}:{s}", .{ std.mem.sliceTo(&client_ip, 0), std.mem.sliceTo(&client_port, 0) });

                    const output_path = try std.fmt.allocPrintZ(srt.allocator, "live/{s}.m3u8", .{stream_id});
                    const gop = try srt.connections.getOrPut(srt.allocator, client_socket);
                    std.debug.assert(!gop.found_existing);

                    gop.value_ptr.* = .{
                        .remuxer = try Remuxer.init(srt.allocator),
                        .output_path = output_path,
                        .thread = undefined,
                    };
                    gop.value_ptr.*.thread = try Thread.spawn(.{}, Remuxer.remux, .{ &gop.value_ptr.remuxer, output_path });

                    var events = c.SRT_EPOLL_IN | c.SRT_EPOLL_ERR | (-@as(c_int, @intCast(~c.SRT_EPOLL_ET)) - 1);
                    if (c.srt_epoll_add_usock(srt.epid, client_socket, &events) == c.SRT_ERROR) {
                        log.warn("{s}", .{err_msg()});
                        continue;
                    }
                },
                c.SRTS_CONNECTED => {
                    while (true) {
                        const read = c.srt_recvmsg(s, &srt.recv_buf, srt.recv_buf.len);
                        if (read == c.SRT_ERROR) {
                            // EAGAIN
                            if (c.srt_getlasterror(null) != c.SRT_EASYNCRCV) {
                                log.warn("{s}", .{err_msg()});
                                continue;
                            }
                            break;
                        }

                        const conn = srt.connections.getPtr(s).?;
                        try conn.remuxer.write(srt.recv_buf[0..@intCast(read)]);
                    }
                },
                else => unreachable,
            }
        }
    }
}

const Connection = struct {
    remuxer: Remuxer,
    output_path: [:0]const u8,
    thread: Thread,

    fn deinit(conn: *Connection, allocator: std.mem.Allocator) void {
        conn.remuxer.deinit();
        conn.thread.join();
        allocator.free(conn.output_path);
    }
};

fn err_msg() [:0]const u8 {
    const err = c.srt_getlasterror_str();
    std.debug.assert(err != c.SRT_SUCCESS);
    return std.mem.span(err);
}
