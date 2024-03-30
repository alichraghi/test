//! Thread-safe, Multi-Threaded (by libav) Remuxer that converts an H.264/AAC stream into MPEG-TS files

const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavformat/avio.h");
    @cInclude("libavcodec/avcodec.h");
});
const SRTServer = @import("SRTServer.zig");

const Remuxer = @This();

const RING_BUFFER_SIZE: usize = std.mem.page_size * 10;
const AVIO_BUFFER_SIZE: usize = std.mem.page_size * 2;
const RingBuffer = std.fifo.LinearFifo(u8, .{ .Static = RING_BUFFER_SIZE });
const log = std.log.scoped(.remuxer);

mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
running: std.atomic.Value(bool) = .{ .raw = true },
allocator: std.mem.Allocator,
ring_buffer: RingBuffer,

pub fn init(allocator: std.mem.Allocator) !Remuxer {
    return .{
        .allocator = allocator,
        .ring_buffer = RingBuffer.init(),
    };
}

pub fn deinit(remuxer: *Remuxer) void {
    remuxer.running.store(false, .release);
    remuxer.cond.broadcast();
}

pub fn remux(remuxer: *Remuxer, output_path: [:0]const u8) !void {
    if (builtin.mode != .Debug) {
        c.av_log_set_callback(empty_logger);
    }

    // NOTE: Managed by avio context
    const avio_buffer: *anyopaque = c.av_malloc(AVIO_BUFFER_SIZE) orelse return error.OutOfMemory;

    // Create AVIO context
    var avio_ctx = c.avio_alloc_context(
        @ptrCast(@alignCast(avio_buffer)),
        AVIO_BUFFER_SIZE,
        0,
        @ptrCast(@alignCast(remuxer)),
        readCallback,
        null,
        null,
    ) orelse return error.OutOfMemory;
    defer c.avio_context_free(&avio_ctx);

    // Create input format context
    var ifmt_ctx: ?*c.AVFormatContext = c.avformat_alloc_context() orelse return error.OutOfMemory;
    defer c.avformat_close_input(&ifmt_ctx);
    ifmt_ctx.?.pb = avio_ctx;
    ifmt_ctx.?.flags |= c.AVFMT_FLAG_CUSTOM_IO | c.AVFMT_NOFILE;

    if (c.avformat_open_input(&ifmt_ctx, null, null, null) < 0) {
        log.err("Could not open input file", .{});
        return error.OpeningResource;
    }

    if (c.avformat_find_stream_info(ifmt_ctx, 0) < 0) {
        log.err("Failed to retrieve input stream information", .{});
        return error.OpeningResource;
    }

    // Create output format context
    var ofmt_ctx: ?*c.AVFormatContext = null;
    _ = c.avformat_alloc_output_context2(&ofmt_ctx, null, null, output_path);
    if (ofmt_ctx == null) {
        log.err("Could not create output context", .{});
        return error.OpeningResource;
    }
    defer {
        _ = c.avio_closep(&ofmt_ctx.?.pb);
        c.avformat_free_context(ofmt_ctx);
    }
    const ofmt: ?*const c.AVOutputFormat = ofmt_ctx.?.oformat;

    // Filter out all streams except audio/video/subtitle
    const stream_mapping_size = ifmt_ctx.?.nb_streams;
    const stream_mapping = try remuxer.allocator.alloc(c_int, stream_mapping_size);
    defer remuxer.allocator.free(stream_mapping);

    for (ifmt_ctx.?.streams[0..ifmt_ctx.?.nb_streams], 0..) |input_stream, i| {
        switch (input_stream.*.codecpar.*.codec_type) {
            c.AVMEDIA_TYPE_AUDIO,
            c.AVMEDIA_TYPE_VIDEO,
            c.AVMEDIA_TYPE_SUBTITLE,
            => {
                stream_mapping[i] = @intCast(i);
            },
            else => {
                stream_mapping[i] = -1;
                continue;
            },
        }

        const out_stream = c.avformat_new_stream(ofmt_ctx, null) orelse {
            log.err("Could not allocate output stream", .{});
            return error.OutOfMemory;
        };

        if (c.avcodec_parameters_copy(out_stream.*.codecpar, input_stream.*.codecpar) < 0) {
            log.err("Could not copy codec parameters", .{});
            return error.InvalidArg;
        }
        out_stream.*.codecpar.*.codec_tag = 0;
    }

    // Create/Open output file and write file header
    c.av_dump_format(ofmt_ctx, 0, output_path, 1);

    if (ofmt.?.flags & c.AVFMT_NOFILE == 0) {
        if (c.avio_open(&ofmt_ctx.?.pb, output_path, c.AVIO_FLAG_WRITE) < 0) {
            log.err("Could not open output file", .{});
            return error.Fuck;
        }
    }

    if (c.avformat_write_header(ofmt_ctx, null) < 0) {
        log.err("Could not write into output file", .{});
        return error.Fuck;
    }

    // Write
    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(&pkt);

    while (remuxer.running.load(.monotonic)) {
        if (c.av_read_frame(ifmt_ctx, pkt) < 0) break;

        defer c.av_packet_unref(pkt);

        const in_stream = ifmt_ctx.?.streams[@intCast(pkt.*.stream_index)].*;
        const stream_index = stream_mapping[@intCast(pkt.*.stream_index)];
        std.debug.assert(stream_index >= 0);

        if (pkt.*.stream_index >= stream_mapping_size) {
            continue;
        } else {
            pkt.*.stream_index = stream_index;
        }

        const out_stream = ofmt_ctx.?.streams[@intCast(pkt.*.stream_index)].*;

        // copy packet
        c.av_packet_rescale_ts(pkt, in_stream.time_base, out_stream.time_base);
        // -1 = unknown
        pkt.*.pos = -1;

        if (c.av_interleaved_write_frame(ofmt_ctx, pkt) < 0) {
            log.err("muxing packet", .{});
            break;
        }
    }

    _ = c.av_write_trailer(ofmt_ctx);
}

pub fn write(remuxer: *Remuxer, slice: []const u8) !void {
    remuxer.mutex.lock();
    defer {
        remuxer.mutex.unlock();
        remuxer.cond.signal();
    }

    while (remuxer.ring_buffer.writableLength() < slice.len) {
        if (!remuxer.running.load(.monotonic)) break;
        remuxer.cond.wait(&remuxer.mutex);
    }
    remuxer.ring_buffer.writeAssumeCapacity(slice);
}

fn readCallback(userdata: ?*anyopaque, buf: [*c]u8, buf_size: c_int) callconv(.C) c_int {
    const remuxer: *Remuxer = @ptrCast(@alignCast(userdata.?));

    remuxer.mutex.lock();
    defer {
        remuxer.mutex.unlock();
        remuxer.cond.signal();
    }

    while (remuxer.ring_buffer.readableLength() == 0) {
        if (!remuxer.running.load(.monotonic)) return c.AVERROR_EOF;
        remuxer.cond.wait(&remuxer.mutex);
    }
    const read_size = remuxer.ring_buffer.read(buf[0..@intCast(buf_size)]);
    return @intCast(read_size);
}

fn empty_logger(_: ?*anyopaque, _: c_int, _: [*c]const u8, _: [*c]c.struct___va_list_tag_2) callconv(.C) void {}
