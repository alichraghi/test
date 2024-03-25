const std = @import("std");
const c = @cImport({
    @cInclude("srt.h");
});
const Remuxer = @import("Remuxer.zig");

const os = std.os;
const log = std.log.scoped(.srt);

const SRTServer = @This();

const srtrfdslenmax = 100;

sfd: c.SRTSOCKET,
epid: c_int,
allocator: std.mem.Allocator,
remuxer: Remuxer,
srtrfds: [srtrfdslenmax]c.SRTSOCKET = undefined,
recv_buf: [1316]u8 = undefined,
threads: std.ArrayListUnmanaged(std.Thread) = .{},

pub fn init(allocator: std.mem.Allocator, address: std.net.Address) !SRTServer {
    _ = address;

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
        log.err("{s}", .{getError()});
        return error.Fuck;
    }

    var no = false;
    if (c.srt_setsockopt(sfd, 0, c.SRTO_RCVSYN, &no, @sizeOf(bool)) == c.SRT_ERROR) {
        log.err("{s}", .{getError()});
        return error.Fuck;
    }

    if (c.srt_bind(sfd, res.ai_addr, @intCast(res.ai_addrlen)) == c.SRT_ERROR) {
        log.err("{s}", .{getError()});
        return error.Fuck;
    }

    c.freeaddrinfo(res);

    log.info("Listening at :9000", .{});

    if (c.srt_listen(sfd, 10) == c.SRT_ERROR) {
        log.err("{s}", .{getError()});
        return error.Fuck;
    }

    const epid = c.srt_epoll_create();
    if (epid < 0) {
        log.err("{s}", .{getError()});
        return error.Fuck;
    }

    var events = c.SRT_EPOLL_IN | c.SRT_EPOLL_ERR;
    if (c.srt_epoll_add_usock(epid, sfd, &events) == c.SRT_ERROR) {
        log.err("{s}", .{getError()});
        return error.Fuck;
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
    var srtrfdslen: c_int = srtrfdslenmax;
    const n = c.srt_epoll_wait(srt.epid, &srt.srtrfds[0], &srtrfdslen, 0, 0, 100, 0, 0, 0, 0);
    if (n < 0) return;
    std.debug.assert(n <= srtrfdslen);
    for (0..@intCast(n)) |i| {
        const s = srt.srtrfds[i];
        const status = c.srt_getsockstate(s);
        if ((status == c.SRTS_BROKEN) or
            (status == c.SRTS_NONEXIST) or
            (status == c.SRTS_CLOSED))
        {
            log.err("source disconnected. status={}", .{status});
            srt.remuxer.stop();
            _ = c.srt_close(s);
            continue;
        } else if (s == srt.sfd) {
            std.debug.assert(status == c.SRTS_LISTENING);

            var fhandle: c.SRTSOCKET = undefined;
            var clientaddr: c.sockaddr_storage = undefined;
            var addrlen: c_int = @sizeOf(c.sockaddr_storage);

            fhandle = c.srt_accept(srt.sfd, @ptrCast(&clientaddr), &addrlen);
            if (fhandle == c.SRT_INVALID_SOCK) {
                log.err("{s}", .{getError()});
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

            const exe_dir_path = try std.fs.selfExeDirPathAlloc(srt.allocator);
            defer srt.allocator.free(exe_dir_path);
            var exe_dir = try std.fs.cwd().openDir(exe_dir_path, .{});
            defer exe_dir.close();
            try exe_dir.makePath("live");
            _ = try std.Thread.spawn(.{}, Remuxer.remux, .{ &srt.remuxer, "zig-out/bin/live/stream.m3u8" });

            var events = c.SRT_EPOLL_IN | c.SRT_EPOLL_ERR;
            if (c.srt_epoll_add_usock(srt.epid, fhandle, &events) == c.SRT_ERROR) {
                log.err("{s}", .{getError()});
                return error.Fuck;
            }
        } else {
            while (true) {
                const ret = c.srt_recvmsg(s, &srt.recv_buf, srt.recv_buf.len);
                if (ret == c.SRT_ERROR) {
                    // EAGAIN for SRT READING
                    if (c.srt_getlasterror(null) != c.SRT_EASYNCRCV) {
                        log.err("{s}", .{getError()});
                        return error.Fuck;
                    }
                    break;
                } else {
                    try srt.remuxer.write(srt.recv_buf[0..@intCast(ret)]);
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

fn getError() [:0]const u8 {
    return std.mem.span(c.srt_getlasterror_str());
}
