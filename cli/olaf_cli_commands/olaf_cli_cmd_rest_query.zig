const std = @import("std");
const olaf_cli_rest_client = @import("../olaf_cli_rest_client.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "rest query";
    pub const description = "Query through an olaf rest serve (or serve-lb) endpoint, printing what 'olaf query' prints.\n\t\turl\t The endpoint, e.g. http://127.0.0.1:8920 (default: config rest_endpoint).\n\t\t--threads n\t The number of files sent at the same time.\n\t\t--fragmented\t Match fragments of the endpoint's fragment_duration_in_seconds.\n\t\t--no-identity-match\t Identity matches are not reported.\n\t\t--format <csv|json>\t Output format (default: csv).";
    pub const help = "[url] [--fragmented] [--threads n] [--format <csv|json>] [audio_file...] | --with-ids [[audio_file audio_identifier]...]";
    pub const needs_audio_files = true;
    pub const accepts_endpoint = true;
    pub const flags = &[_]types.Flag{ .threads, .fragmented, .no_identity_match, .format, .with_ids };
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    if (args.format == .human) {
        olaf_cli_util.print("query output has no human format; use --format csv or json.\n", .{});
        return error.Usage;
    }
    const config = args.config.?;
    try olaf_cli_rest_client.run(allocator, args.audio_files.items, args.threads, .{
        .io = args.io,
        .config = config,
        .url = try olaf_cli_rest_client.endpointUrl(args, config),
        .action = .query,
        .store_format = args.storeFormat(),
        .query_format = args.queryFormat(),
        .force = false,
        .allow_identity_match = args.allow_identity_match,
        .fragmented = args.fragmented,
    });
}
