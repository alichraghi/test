const std = @import("std");

pub const Segment = struct {
    name: []const u8,
    duration: i32,
    discontinuity: bool = false,
};

pub const M3u8 = struct {
    version: u16 = 3,
    target_duration: i32 = 6,

    pub fn write_header(m3u8: M3u8, writer: anytype) !void {
        try writer.print(
            \\#EXTM3U
            \\#EXT-X-VERSION:{}
            \\#EXT-X-TARGETDURATION:{}
            \\#EXT-X-MEDIA-SEQUENCE:{}
            \\
        ,
            .{
                m3u8.version,
                m3u8.target_duration,
                0,
            },
        );
    }

    pub fn write(m3u8: M3u8, writer: anytype, segments: []const Segment) !void {
        try m3u8.write_header(writer);

        for (segments) |segment| {
            if (segment.discontinuity) {
                _ = try writer.write("#EXT-X-DISCONTINUITY\n");
            }
            try writer.print(
                "#EXTINF:{d:.3}\n{s}\n",
                .{ @as(f32, @floatFromInt(segment.duration)), segment.name },
            );
        }

        _ = try writer.write("#EXT-X-ENDLIST\n");
    }
};
