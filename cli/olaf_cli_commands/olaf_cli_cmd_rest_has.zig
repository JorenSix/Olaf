const std = @import("std");
const olaf_cli_rest_client = @import("../olaf_cli_rest_client.zig");
const cmd_has = @import("olaf_cli_cmd_has.zig");
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "rest has";
    pub const description = "'olaf has' through an olaf rest serve (or serve-lb) endpoint, with the same output.\n\t\turl\t The endpoint, e.g. http://127.0.0.1:8920 (default: config rest_endpoint).\n\t\t--threshold n\t The match_count needed for a match (default: has_min_match_count).\n\t\t--threads n\t The number of files sent at the same time.\n\t\t--format <json|text>\t Output format (default: json).";
    pub const help = "[url] [--threshold n] [--threads n] [--format <json|text>] [audio_file...] | --with-ids [[audio_file audio_identifier]...]";
    pub const needs_audio_files = true;
    pub const accepts_endpoint = true;
    pub const flags = &[_]types.Flag{ .threads, .with_ids, .format, .threshold };
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    try olaf_cli_rest_client.run(allocator, args.audio_files.items, args.threads, .{
        .io = args.io,
        .config = config,
        .url = try olaf_cli_rest_client.endpointUrl(args, config),
        .action = .has,
        .store_format = .human,
        .query_format = .json,
        .force = false,
        .allow_identity_match = true,
        .fragmented = true,
        .threshold = args.threshold orelse config.has_min_match_count,
        .has_format = try cmd_has.format(args),
    });
}
