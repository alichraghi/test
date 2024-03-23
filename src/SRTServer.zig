const std = @import("std");
const c = @cImport({
    @cInclude("srt.h");
});
const allocator = @import("main.zig").allocator;
const remux = @import("remux.zig");

const os = std.os;
const log = std.log.scoped(.srt);

const SRTServer = @This();

const srtrfdslenmax = 100;
var data_buf: [8192 * 1024]u8 = undefined;

sfd: c.SRTSOCKET,
epid: c_int,
srtrfds: [srtrfdslenmax]c.SRTSOCKET = undefined,
recv_buf: [1500]u8 = undefined,
rb: std.RingBuffer,
threads: std.ArrayListUnmanaged(std.Thread) = .{},

pub fn init(ip: [4]u8, port: u16) !SRTServer {
    _ = ip;
    _ = port;

    _ = c.srt_startup();

    const hints: c.addrinfo = .{
        .ai_flags = 1, // AI_PASSIVE
        .ai_family = std.os.AF.INET,
        .ai_socktype = std.os.SOCK.DGRAM,
        .ai_protocol = 0,
        .ai_addrlen = 0,
        .ai_addr = null,
        .ai_canonname = null,
        .ai_next = null,
    };
    var res: *c.addrinfo = undefined;

    if (c.getaddrinfo(null, "9000", &hints, @ptrCast(&res)) != 0) {
        log.err("illegal port number or port is busy", .{});
        return error.Fuck;
    }

    const sfd = c.srt_create_socket();
    if (sfd == c.SRT_INVALID_SOCK) {
        log.err("{s}", .{std.mem.span(c.srt_getlasterror_str())});
        return error.Fuck;
    }

    var no = false;
    if (c.srt_setsockopt(sfd, 0, c.SRTO_RCVSYN, &no, @sizeOf(bool)) == c.SRT_ERROR) {
        log.err("{s}", .{std.mem.span(c.srt_getlasterror_str())});
        return error.Fuck;
    }

    if (c.srt_bind(sfd, res.ai_addr, @intCast(res.ai_addrlen)) == c.SRT_ERROR) {
        log.err("{s}", .{std.mem.span(c.srt_getlasterror_str())});
        return error.Fuck;
    }

    c.freeaddrinfo(res);

    log.info("Listening at :9000", .{});

    if (c.srt_listen(sfd, 10) == c.SRT_ERROR) {
        log.err("{s}", .{std.mem.span(c.srt_getlasterror_str())});
        return error.Fuck;
    }

    const epid = c.srt_epoll_create();
    if (epid < 0) {
        log.err("{s}", .{std.mem.span(c.srt_getlasterror_str())});
        return error.Fuck;
    }

    var events = c.SRT_EPOLL_IN | c.SRT_EPOLL_ERR;
    if (c.srt_epoll_add_usock(epid, sfd, &events) == c.SRT_ERROR) {
        log.err("{s}", .{std.mem.span(c.srt_getlasterror_str())});
        return error.Fuck;
    }

    return .{
        .sfd = sfd,
        .epid = epid,
        .rb = try std.RingBuffer.init(allocator, 8192),
    };
}

pub fn deinit(server: *SRTServer) void {
    for (server.threads.items) |thread| thread.join();
    server.threads.deinit(allocator);

    _ = c.srt_close(server.sfd);
    _ = c.srt_epoll_release(server.epid);
    _ = c.srt_cleanup();
}

pub fn tick(server: *SRTServer) !void {
    var srtrfdslen: c_int = srtrfdslenmax;
    const n = c.srt_epoll_wait(server.epid, &server.srtrfds[0], &srtrfdslen, 0, 0, 100, 0, 0, 0, 0);
    if (n < 0) return;
    std.debug.assert(n <= srtrfdslen);
    for (0..@intCast(n)) |i| {
        const s = server.srtrfds[i];
        const status = c.srt_getsockstate(s);
        if ((status == c.SRTS_BROKEN) or
            (status == c.SRTS_NONEXIST) or
            (status == c.SRTS_CLOSED))
        {
            log.err("source disconnected. status={}", .{status});
            _ = c.srt_close(s);
            remux.read_lock.set();
            continue;
        } else if (s == server.sfd) {
            std.debug.assert(status == c.SRTS_LISTENING);

            var fhandle: c.SRTSOCKET = undefined;
            var clientaddr: c.sockaddr_storage = undefined;
            var addrlen: c_int = @sizeOf(c.sockaddr_storage);

            fhandle = c.srt_accept(server.sfd, @ptrCast(&clientaddr), &addrlen);
            if (fhandle == c.SRT_INVALID_SOCK) {
                log.err("{s}", .{std.mem.span(c.srt_getlasterror_str())});
                return error.Fuck;
            }

            var clienthost: [c.NI_MAXHOST]u8 = undefined;
            var clientservice: [c.NI_MAXSERV]u8 = undefined;
            _ = c.getnameinfo(
                @ptrCast(&clientaddr),
                @intCast(addrlen),
                &clienthost,
                @sizeOf(@TypeOf(clienthost)),
                &clientservice,
                @sizeOf(@TypeOf(clientservice)),
                c.NI_NUMERICHOST | c.NI_NUMERICSERV,
            );
            log.info("new connection: {s}:{s}", .{ std.mem.sliceTo(&clienthost, 0), std.mem.sliceTo(&clientservice, 0) });

            // TODO
            remux.write_lock.set();
            _ = try std.Thread.spawn(.{}, remux.remux, .{&server.rb});

            var events = c.SRT_EPOLL_IN | c.SRT_EPOLL_ERR;
            if (c.srt_epoll_add_usock(server.epid, fhandle, &events) == c.SRT_ERROR) {
                log.err("{s}", .{std.mem.span(c.srt_getlasterror_str())});
                return error.Fuck;
            }
        } else {
            while (true) {
                const ret = c.srt_recvmsg(s, &server.recv_buf, server.recv_buf.len);
                if (ret == c.SRT_ERROR) {
                    // EAGAIN for SRT READING
                    if (c.srt_getlasterror(null) != c.SRT_EASYNCRCV) {
                        log.err("{s}", .{std.mem.span(c.srt_getlasterror_str())});
                        return error.Fuck;
                    }
                    break;
                } else {
                    if (remux.eof_lock.isSet()) continue;

                    while (true) {
                        remux.write_lock.wait();
                        defer {
                            remux.write_lock.reset();
                            remux.read_lock.set();
                        }

                        server.rb.writeSlice(server.recv_buf[0..@intCast(ret)]) catch {
                            log.warn("RESET", .{});
                            remux.eof_lock.set();
                            continue;
                        };

                        // if (server.written > 1024 * 1024) {
                        //     remux.eof_lock.set();
                        // }

                        break;
                    }
                }
            }
        }
    }
}

const Client = struct {
    stream: std.net.Stream,
};

fn handle_conn(client: *Client) void {
    _ = client;
}
