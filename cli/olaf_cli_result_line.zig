const std = @import("std");

const OlafResultLine = struct {
    valid: bool,
    empty_match: bool,
    index: u32,
    total: u32,
    query: []const u8,
    query_offset: f32,
    match_count: u32,
    query_start: f32,
    query_stop: f32,
    ref_path: []const u8,
    ref_id: []const u8,
    ref_start: f32,
    ref_stop: f32,

    fn parse(allocator: std.mem.Allocator, line: []const u8) !OlafResultLine {
        var parts = std.ArrayList([]const u8).init(allocator);
        defer parts.deinit();

        var it = std.mem.tokenizeAny(u8, line, ",");
        while (it.next()) |part| {
            try parts.append(std.mem.trim(u8, part, " \t\n\r"));
        }

        if (parts.items.len != 11) {
            return OlafResultLine{
                .valid = false,
                .empty_match = true,
                .index = 0,
                .total = 0,
                .query = "",
                .query_offset = 0,
                .match_count = 0,
                .query_start = 0,
                .query_stop = 0,
                .ref_path = "",
                .ref_id = "",
                .ref_start = 0,
                .ref_stop = 0,
            };
        }

        const match_count = try std.fmt.parseInt(u32, parts.items[4], 10);

        return OlafResultLine{
            .valid = true,
            .empty_match = match_count == 0,
            .index = try std.fmt.parseInt(u32, parts.items[0], 10),
            .total = try std.fmt.parseInt(u32, parts.items[1], 10),
            .query = parts.items[2],
            .query_offset = try std.fmt.parseFloat(f32, parts.items[3]),
            .match_count = match_count,
            .query_start = try std.fmt.parseFloat(f32, parts.items[5]),
            .query_stop = try std.fmt.parseFloat(f32, parts.items[6]),
            .ref_path = parts.items[7],
            .ref_id = parts.items[8],
            .ref_start = try std.fmt.parseFloat(f32, parts.items[9]),
            .ref_stop = try std.fmt.parseFloat(f32, parts.items[10]),
        };
    }
};
