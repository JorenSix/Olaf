const std = @import("std");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");
const types = @import("../olaf_cli_types.zig");

const debug = std.log.scoped(.olaf_cli_dedup).debug;

fn print(comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    _ = stdout.print(fmt, args) catch {};
    _ = stdout.flush() catch {};
}

pub const CommandInfo = struct {
    pub const name = "dedup";
    pub const description = "Find duplicate audio content in a folder. Each file is stored, then queried against the index with self-matches filtered out.\n\t\t--threads n\t The number of threads to use for the store step.\n\t\t--fragmented\t Chop queries into 30s fragments and match each fragment.\n\t\t--skip-store\t Skip the store step (use when the index already contains the folder).";
    pub const help = "[--fragmented] [--threads n] [--skip-store] audio_files...";
    pub const needs_audio_files = true;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to dedup.\n", .{});
        return;
    }

    debug("Dedup over {d} files (skip_store={}, fragmented={}, threads={})", .{
        args.audio_files.items.len, args.skip_store, args.fragmented, args.threads,
    });

    if (!args.skip_store) {
        try olaf_cli_threading.executeParallel(
            allocator,
            args.audio_files.items,
            args.config.?,
            .Store,
            args.threads,
            true,
        );
    }

    // dedup means "find duplicates" — self-matches are always filtered.
    if (args.fragmented) {
        try olaf_cli_threading.executeFragmentedParallel(
            allocator,
            args.audio_files.items,
            args.config.?,
            .Query,
            args.threads,
            args.fragment_duration,
            false,
        );
    } else {
        try olaf_cli_threading.executeParallel(
            allocator,
            args.audio_files.items,
            args.config.?,
            .Query,
            args.threads,
            false,
        );
    }
}
