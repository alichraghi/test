//! Thread-safe, Multi-Threaded and Sync HTTP Server used for serving static files and API

const std = @import("std");
const mime = @import("mime");

const index_page = @embedFile("index.html");
const not_found_page = @embedFile("not_found.html");
const internal_error_page = @embedFile("internal_error.html");

const posix = std.posix;
const log = std.log.scoped(.http);

const HTTPServer = @This();

const RECV_BUF_LEN = std.mem.page_size;
const WORKER_THREADS = 12 - 1; // One is running in the main thread

allocator: std.mem.Allocator,
address: std.net.Address,
listener: std.net.Server,
running: std.atomic.Value(bool) = .{ .raw = true },
workers: [WORKER_THREADS]std.Thread = undefined,
file_cache_mutex: std.Thread.Mutex = .{},
file_cache: std.StringHashMapUnmanaged(FileCache) = .{},

const FileCache = struct {
    mime: mime.Type,
    data: []const u8,
};

pub fn init(allocator: std.mem.Allocator, address: std.net.Address) !HTTPServer {
    const listener = try address.listen(.{ .reuse_address = true });

    log.info("HTTP Server is listening on {}.", .{address});

    return .{
        .allocator = allocator,
        .address = address,
        .listener = listener,
    };
}

pub fn deinit(server: *HTTPServer) void {
    server.stop();
    for (server.workers) |worker| worker.join();

    var file_cache_iter = server.file_cache.valueIterator();
    while (file_cache_iter.next()) |cached_file| server.allocator.free(cached_file.data);

    server.listener.deinit();
}

pub fn stop(server: *HTTPServer) void {
    server.running.store(false, .release);
}

pub fn run(server: *HTTPServer) !void {
    for (&server.workers) |*worker| worker.* = try std.Thread.spawn(.{}, handleConnections, .{server});
    handleConnections(server);
}

fn handleConnections(server: *HTTPServer) void {
    var recv_buf: [RECV_BUF_LEN]u8 = undefined;

    while (server.running.load(.monotonic)) {
        const conn = server.listener.accept() catch |err| {
            log.warn("accepting failed: {}", .{err});
            continue;
        };
        defer conn.stream.close();

        log.info("New connection: {}", .{conn.address});

        var http_server = std.http.Server.init(conn, &recv_buf);
        var req = http_server.receiveHead() catch |err| {
            log.warn("parsing header failed: {}", .{err});
            break;
        };

        if (std.mem.eql(u8, "/", req.head.target)) {
            respondFile(&req, index_page, .@"text/html");
        } else {
            server.file_cache_mutex.lock();
            defer server.file_cache_mutex.unlock();

            const path = req.head.target[1..];

            if (server.file_cache.get(path)) |cached_file| {
                respondFile(&req, cached_file.data, cached_file.mime);
                continue;
            } else {
                const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
                    error.FileNotFound => {
                        respondNotFound(&req);
                        continue;
                    },
                    else => {
                        log.warn("opening file failed: {}", .{err});
                        respondInternalError(&req);
                        continue;
                    },
                };
                const file_mime = mime.extension_map.get(path) orelse .@"text/plain";
                const file_data = file.readToEndAlloc(server.allocator, 100 * 1024 * 1024) catch @panic("OOM");
                server.file_cache.put(server.allocator, path, .{ .mime = file_mime, .data = file_data }) catch @panic("OOM");
                respondFile(&req, file_data, file_mime);
                continue;
            }
        }
    }
}

fn respondFile(request: *std.http.Server.Request, file_data: []const u8, file_mime: mime.Type) void {
    request.respond(file_data, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = @tagName(file_mime) },
            .{ .name = "connection", .value = "close" },
        },
    }) catch |err| {
        log.warn("responding failed: {}", .{err});
        return;
    };
}

fn respondNotFound(request: *std.http.Server.Request) void {
    respondFile(request, not_found_page, .@"text/html");
}

fn respondInternalError(request: *std.http.Server.Request) void {
    respondFile(request, internal_error_page, .@"text/html");
}
