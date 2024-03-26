const std = @import("std");
const c = @cImport({
    @cInclude("srt.h");
});
const Remuxer = @import("Remuxer.zig");

const os = std.os;
const log = std.log.scoped(.srt);

const SRTServer = @This();

const SRT_RFDS_LEN_MAX = 100;
const kernel_backlog = 10;

sfd: c.SRTSOCKET,
epid: c_int,
allocator: std.mem.Allocator,
remuxer: Remuxer,
sockets: [SRT_RFDS_LEN_MAX]c.SRTSOCKET = undefined,
recv_buf: [1316]u8 = undefined,
threads: std.ArrayListUnmanaged(std.Thread) = .{},

pub fn init(allocator: std.mem.Allocator, port: u16) !SRTServer {
    _ = c.srt_startup();

    var port_str_buf: [5]u8 = undefined;
    const port_str = std.fmt.bufPrintZ(&port_str_buf, "{}", .{port}) catch unreachable;

    var addr: *c.addrinfo = undefined;
    if (c.getaddrinfo(null, port_str, &.{
        .ai_flags = 1, // AI_PASSIVE
        .ai_family = std.os.AF.INET,
        .ai_socktype = std.os.SOCK.DGRAM,
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
        logErr();
        return error.SystemResources;
    }

    var opt_value = false;
    if (c.srt_setsockopt(sfd, 0, c.SRTO_RCVSYN, &opt_value, @sizeOf(bool)) == c.SRT_ERROR) {
        logErr();
        return error.SystemResources;
    }

    if (c.srt_bind(sfd, addr.ai_addr, @intCast(addr.ai_addrlen)) == c.SRT_ERROR) {
        logErr();
        return error.SystemResources;
    }

    log.info("SRT Server is listening on 127.0.0.1:{}", .{port});

    if (c.srt_listen(sfd, kernel_backlog) == c.SRT_ERROR) {
        logErr();
        return error.SystemResources;
    }

    const epid = c.srt_epoll_create();
    if (epid < 0) {
        logErr();
        return error.SystemResources;
    }

    var events = c.SRT_EPOLL_IN | c.SRT_EPOLL_ERR;
    if (c.srt_epoll_add_usock(epid, sfd, &events) == c.SRT_ERROR) {
        logErr();
        return error.SystemResources;
    }

    return .{
        .allocator = allocator,
        .sfd = sfd,
        .epid = epid,
        .remuxer = try Remuxer.init(allocator),
    };
}

pub fn deinit(srt: *SRTServer) void {
    for (srt.threads.items) |thread| thread.join();
    srt.threads.deinit(srt.allocator);

    _ = c.srt_close(srt.sfd);
    _ = c.srt_epoll_release(srt.epid);
    _ = c.srt_cleanup();
}

pub fn tick(srt: *SRTServer) !void {
    var sockets_len: c_int = srt.sockets.len;
    const ready_sockets = c.srt_epoll_wait(srt.epid, &srt.sockets, &sockets_len, 0, 0, 100, 0, 0, 0, 0);
    if (ready_sockets < 0) return;
    std.debug.assert(ready_sockets <= sockets_len);

    for (srt.sockets[0..@intCast(ready_sockets)]) |s| {
        const status = c.srt_getsockstate(s);

        switch (status) {
            c.SRTS_INIT, c.SRTS_OPENED, c.SRTS_CLOSING, c.SRTS_CONNECTING => {},
            c.SRTS_BROKEN, c.SRTS_NONEXIST, c.SRTS_CLOSED => {
                log.err("Connection closed with status ({d})", .{status});
                srt.remuxer.stop();
                _ = c.srt_close(s);
                continue;
            },
            c.SRTS_LISTENING => {
                std.debug.assert(s == srt.sfd);

                var fhandle: c.SRTSOCKET = undefined;
                var clientaddr: c.sockaddr_storage = undefined;
                var addrlen: c_int = @sizeOf(c.sockaddr_storage);

                fhandle = c.srt_accept(srt.sfd, @ptrCast(&clientaddr), &addrlen);
                if (fhandle == c.SRT_INVALID_SOCK) {
                    logErr();
                    return error.SystemResources;
                }

                var client_ip: [c.NI_MAXHOST]u8 = undefined;
                var client_port: [c.NI_MAXSERV]u8 = undefined;
                _ = c.getnameinfo(
                    @ptrCast(&clientaddr),
                    @intCast(addrlen),
                    &client_ip,
                    client_ip.len,
                    &client_port,
                    client_port.len,
                    c.NI_NUMERICHOST | c.NI_NUMERICSERV,
                );
                log.info("New connection: {s}:{s}", .{ std.mem.sliceTo(&client_ip, 0), std.mem.sliceTo(&client_port, 0) });

                const exe_dir_path = try std.fs.selfExeDirPathAlloc(srt.allocator);
                defer srt.allocator.free(exe_dir_path);
                var exe_dir = try std.fs.cwd().openDir(exe_dir_path, .{});
                defer exe_dir.close();
                try exe_dir.makePath("live");
                // const name = std.fmt.allocPrintZ(srt.allocator, "zig-out/bin/live/stream-{d}.m3u8", .{con_i});
                _ = try std.Thread.spawn(.{}, Remuxer.remux, .{ &srt.remuxer, "zig-out/bin/live/stream.m3u8" });

                var events = c.SRT_EPOLL_IN | c.SRT_EPOLL_ERR;
                if (c.srt_epoll_add_usock(srt.epid, fhandle, &events) == c.SRT_ERROR) {
                    logErr();
                    return error.SystemResources;
                }
            },
            c.SRTS_CONNECTED => {
                while (true) {
                    const read = c.srt_recvmsg(s, &srt.recv_buf, srt.recv_buf.len);
                    if (read == c.SRT_ERROR) {
                        // EAGAIN
                        if (c.srt_getlasterror(null) != c.SRT_EASYNCRCV) {
                            logErr();
                            return error.SystemResources;
                        }
                        break;
                    }

                    try srt.remuxer.write(srt.recv_buf[0..@intCast(read)]);
                }
            },
            else => unreachable,
        }
    }
}

const Client = struct {
    stream: std.net.Stream,
};

fn handle_conn(client: *Client) void {
    _ = client;
}

fn logErr() void {
    const err = c.srt_getlasterror_str();
    std.debug.assert(err != c.SRT_SUCCESS);

    const err_str = std.mem.span(err);
    log.err("{s}", .{err_str});
}
