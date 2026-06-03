const std = @import("std");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const types = @import("../olaf_cli_types.zig");

const debug = std.log.scoped(.olaf_cli_query).debug;

const print = olaf_cli_util.print;

pub const CommandInfo = struct {
    pub const name = "query";
    pub const description = "Query for fingerprint matches.\n\t\t--threads n\t The number of threads to use.\n\t\t--fragmented\t Chop queries into 30s fragments and match each fragment.\n\t\t--no-identity-match\t Identity matches are not reported.\n\t\t--format <csv|json>\t Output format (default: csv).";
    pub const help = "[--fragmented] [--threads n] [--format <csv|json>] [audio_file...] | --with-ids [[audio_file audio_identifier]...]";
    pub const needs_audio_files = true;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to query.\n", .{});
        return;
    }

    debug("Executing query with fragmented={}, threads={}", .{ args.fragmented, args.threads });

    if (args.fragmented) {
        try olaf_cli_threading.executeFragmentedParallel(
            args.io,
            allocator,
            args.audio_files.items,
            args.config.?,
            .Query,
            args.threads,
            args.fragment_duration,
            args.allow_identity_match,
            args.output_format,
            args.store_format,
        );
    } else {
        try olaf_cli_threading.executeParallel(
            args.io,
            allocator,
            args.audio_files.items,
            args.config.?,
            .Query,
            args.threads,
            args.allow_identity_match,
            args.output_format,
            args.store_format,
        );
    }
}
