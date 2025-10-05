const std = @import("std");
const olaf_wrapper_threading = @import("../olaf_wrapper_threading.zig");
const types = @import("../olaf_wrapper_types.zig");

const debug = std.log.scoped(.olaf_wrapper_query).debug;

fn print(comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    _ = stdout.print(fmt, args) catch {};
    _ = stdout.flush() catch {};
}

pub const CommandInfo = struct {
    pub const name = "query";
    pub const description = "Query for fingerprint matches.";
    pub const help = "[--threads n]  [audio_file...] | --with-ids [audio_file audio_identifier]";
    pub const needs_audio_files = true;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to query.\n", .{});
        return;
    }

    try olaf_wrapper_threading.executeParallel(
        allocator,
        args.audio_files.items,
        args.config.?,
        .Query,
        args.threads,
    );
}
