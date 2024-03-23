const std = @import("std");
const c = @cImport({
    @cInclude("libavutil/timestamp.h");
    @cInclude("libavutil/file.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavformat/avio.h");
    @cInclude("libavcodec/avcodec.h");
});
const SRTServer = @import("SRTServer.zig");

const out_filename = "stream.m3u8";
const avio_ctx_buffer_size: usize = 4096;

pub var read_lock: std.Thread.ResetEvent = .{};
pub var write_lock: std.Thread.ResetEvent = .{};
pub var eof_lock: std.Thread.ResetEvent = .{};

fn read_packet(userdata: ?*anyopaque, buf: [*c]u8, buf_size: c_int) callconv(.C) c_int {
    read_lock.wait();
    defer {
        read_lock.reset();
        write_lock.set();
    }

    if (eof_lock.isSet()) return c.AVERROR_EOF;
    const rb: *std.RingBuffer = @ptrCast(@alignCast(userdata.?));
    if (buf_size == 0) return c.AVERROR_EOF;
    const read = @min(rb.len(), @as(usize, @intCast(buf_size)));
    rb.readFirst(buf[0..@intCast(buf_size)], read) catch unreachable;
    return @intCast(read);
}

pub fn remux(rb: *std.RingBuffer) !void {
    var ifmt_ctx: ?*c.AVFormatContext = c.avformat_alloc_context() orelse {
        std.log.err("OOM", .{});
        return error.Fuck;
    };
    defer c.avformat_close_input(&ifmt_ctx);

    const avio_ctx_buffer: [*]u8 = @ptrCast(@alignCast(c.av_malloc(avio_ctx_buffer_size) orelse {
        std.log.err("OOM", .{});
        return error.Fuck;
    }));

    var avio_ctx = c.avio_alloc_context(
        avio_ctx_buffer,
        avio_ctx_buffer_size,
        0,
        @ptrCast(@alignCast(rb)),
        read_packet,
        null,
        null,
    ) orelse {
        std.log.err("OOM", .{});
        return error.Fuck;
    };
    defer c.avio_context_free(&avio_ctx);

    ifmt_ctx.?.pb = avio_ctx;

    var err = c.avformat_open_input(&ifmt_ctx, null, null, null);
    if (err < 0) {
        var buf: [200]u8 = undefined;
        std.log.err("could not open input file: {s}", .{c.av_make_error_string(&buf, buf.len, err)});
        return error.Fuck;
    }

    if (c.avformat_find_stream_info(ifmt_ctx, 0) < 0) {
        std.log.err("failed to retrieve input stream information", .{});
        return error.Fuck;
    }

    var ofmt_ctx: ?*c.AVFormatContext = null;
    err = c.avformat_alloc_output_context2(&ofmt_ctx, null, "hls", out_filename);
    if (ofmt_ctx == null) {
        std.log.err("could not create output context", .{});
        return error.Fuck;
    }
    defer {
        // close output
        if (ofmt_ctx.?.flags & c.AVFMT_NOFILE == 0) {
            _ = c.avio_closep(&ofmt_ctx.?.pb);
        }
        c.avformat_free_context(ofmt_ctx);
    }

    const ofmt: ?*const c.AVOutputFormat = ofmt_ctx.?.oformat;

    const stream_mapping_size = ifmt_ctx.?.nb_streams;
    const stream_mapping = try std.heap.page_allocator.alloc(c_int, stream_mapping_size);
    defer std.heap.page_allocator.free(stream_mapping);

    for (0..ifmt_ctx.?.nb_streams) |i| {
        const in_stream: *c.AVStream = ifmt_ctx.?.streams[i];
        const in_codecpar: *c.AVCodecParameters = in_stream.codecpar;

        if (in_codecpar.codec_type != c.AVMEDIA_TYPE_AUDIO and
            in_codecpar.codec_type != c.AVMEDIA_TYPE_VIDEO and
            in_codecpar.codec_type != c.AVMEDIA_TYPE_SUBTITLE)
        {
            stream_mapping[i] = -1;
            continue;
        }

        stream_mapping[i] = @intCast(i);

        const out_stream: *c.AVStream = c.avformat_new_stream(ofmt_ctx, null) orelse {
            std.log.err("failed allocating output stream", .{});
            return error.Fuck;
        };

        if (c.avcodec_parameters_copy(out_stream.codecpar, in_codecpar) < 0) {
            std.log.err("failed to copy codec parameters", .{});
            return error.Fuck;
        }
        out_stream.codecpar[0].codec_tag = 0;
    }

    c.av_dump_format(ofmt_ctx, 0, out_filename, 1);

    if (ofmt.?.flags & c.AVFMT_NOFILE == 0) {
        err = c.avio_open(&ofmt_ctx.?.pb, out_filename, c.AVIO_FLAG_WRITE);
        if (err < 0) {
            var buf: [200]u8 = undefined;
            std.log.err("could not open output file: {s}", .{c.av_make_error_string(&buf, buf.len, err)});
            return error.Fuck;
        }
    }

    err = c.avformat_write_header(ofmt_ctx, null);
    if (err < 0) {
        var buf: [200]u8 = undefined;
        std.log.err("could not open output file: {s}", .{c.av_make_error_string(&buf, buf.len, err)});
        return error.Fuck;
    }

    var pkt: ?*c.AVPacket = c.av_packet_alloc() orelse {
        std.log.err("OOM", .{});
        return error.Fuck;
    };
    defer c.av_packet_free(&pkt);

    while (true) {
        if (c.av_read_frame(ifmt_ctx, pkt) < 0) break;

        const in_stream: *c.AVStream = ifmt_ctx.?.streams[@intCast(pkt.?.stream_index)].?;
        if (pkt.?.stream_index >= stream_mapping_size or
            stream_mapping[@intCast(pkt.?.stream_index)] < 0)
        {
            c.av_packet_unref(pkt);
            continue;
        }

        pkt.?.stream_index = stream_mapping[@intCast(pkt.?.stream_index)];
        const out_stream: *c.AVStream = ofmt_ctx.?.streams.?[@intCast(pkt.?.stream_index)].?;

        // copy packet
        c.av_packet_rescale_ts(pkt, in_stream.time_base, out_stream.time_base);
        pkt.?.pos = -1;

        // pkt is now blank (av_interleaved_write_frame() takes ownership of
        // its contents and resets pkt), so that no unreferencing is necessary.
        // This would be different if one used av_write_frame().
        if (c.av_interleaved_write_frame(ofmt_ctx, pkt) < 0) {
            std.log.err("muxing packet", .{});
            break;
        }
    }

    _ = c.av_write_trailer(ofmt_ctx);
}
