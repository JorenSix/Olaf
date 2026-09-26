const std = @import("std");
const olaf_cli_has = @import("../olaf_cli_has.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "has";
    pub const description = "Check whether audio is in the database: a fragmented query per file, a match when the best match_count\n\t\treaches has_min_match_count (default 20). JSON by default, with the ffprobe tags of the matched file.\n\t\t--threshold n\t The match_count needed for a match.\n\t\t--threads n\t The number of threads to use.\n\t\t--format <json|text>\t Output format (default: json).";
    pub const help = "[--threshold n] [--threads n] [--format <json|text>] [audio_file...] | --with-ids [[audio_file audio_identifier]...]";
    pub const needs_audio_files = true;
    pub const flags = &[_]types.Flag{ .threads, .with_ids, .format, .threshold };
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    try olaf_cli_has.runLocal(allocator, args.audio_files.items, args.threads, .{
        .io = args.io,
        .config = config,
        .threshold = args.threshold orelse config.has_min_match_count,
        .format = try format(args),
    });
}

/// json (default) or text; has has no csv.
pub fn format(args: *const types.Args) !olaf_cli_has.Format {
    const f = args.format orelse .json;
    if (f == .csv) {
        olaf_cli_util.print("'has' prints json or text; use --format json or --format text.\n", .{});
        return error.Usage;
    }
    return f;
}
