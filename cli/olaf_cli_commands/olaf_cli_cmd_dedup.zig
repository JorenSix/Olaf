const std = @import("std");
const olaf_cli_output = @import("../olaf_cli_output.zig");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const types = @import("../olaf_cli_types.zig");
const cmd_store = @import("olaf_cli_cmd_store.zig");

const debug = std.log.scoped(.olaf_cli_dedup).debug;

const print = olaf_cli_util.print;

pub const CommandInfo = struct {
    pub const name = "dedup";
    pub const description = "Find duplicate audio content in a folder. Each file is stored, then queried against the index with self-matches filtered out.\n\t\t--threads n\t The number of threads to use (store and query steps).\n\t\t--format <human|csv|json>\t Store records on stderr as with store; query results as csv (human) or json.\n\t\t-f, --force\t Re-store files that are already indexed.\n\t\t--fragmented\t Chop queries into fragments of fragment_duration_in_seconds (default 30s) and match each fragment.\n\t\t--skip-store\t Skip the store step (use when the index already contains the folder).";
    pub const help = "[-f] [--fragmented] [--threads n] [--skip-store] [--format <human|csv|json>] audio_files...";
    pub const needs_audio_files = true;
    pub const flags = &[_]types.Flag{ .threads, .fragmented, .skip_store, .format, .force, .with_ids };
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
        // Already indexed files are skipped (skip_duplicates), so re-running
        // dedup on a folder only fingerprints what is new.
        // Same stderr records as `olaf store`, including its CSV header.
        if (args.storeFormat() == .csv) try std.Io.File.stderr().writeStreamingAll(args.io, olaf_cli_output.store_csv_header);
        try cmd_store.storeFiles(allocator, args);
    }

    // dedup means "find duplicates" — self-matches are always filtered.
    if (args.fragmented) {
        try olaf_cli_threading.executeFragmentedQuery(
            args.io,
            allocator,
            args.audio_files.items,
            args.config.?,
            args.threads,
            args.config.?.fragment_duration_in_seconds,
            false,
            args.queryFormat(),
        );
    } else {
        try olaf_cli_threading.executeParallel(
            args.io,
            allocator,
            args.audio_files.items,
            args.config.?,
            .Query,
            args.threads,
            false,
            args.queryFormat(),
            args.storeFormat(),
        null,
    );
    }
}
