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
    pub const description = "Query for fingerprint matches.\n\t\t--threads n\t The number of threads to use.\n\t\t--fragmented\t Chop queries into 30s fragments and match each fragment.\n\t\t--no-identity-match\t Identity matches are not reported.";
    pub const help = "[--fragmented] [--threads n] [audio_file...] | --with-ids [audio_file audio_identifier]";
    pub const needs_audio_files = true;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to query.\n", .{});
        return;
    }

    debug("Executing query with fragmented={}, threads={}", .{ args.fragmented, args.threads });

    if (args.fragmented) {
        try olaf_wrapper_threading.executeFragmentedParallel(
            allocator,
            args.audio_files.items,
            args.config.?,
            .Query,
            args.threads,
            args.fragment_duration,
            args.allow_identity_match,
        );
    } else {
        try olaf_wrapper_threading.executeParallel(
            allocator,
            args.audio_files.items,
            args.config.?,
            .Query,
            args.threads,
        );
    }
}
