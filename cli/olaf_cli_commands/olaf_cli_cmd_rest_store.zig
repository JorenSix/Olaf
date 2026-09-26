const std = @import("std");
const olaf_cli_output = @import("../olaf_cli_output.zig");
const olaf_cli_rest_client = @import("../olaf_cli_rest_client.zig");
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "rest store";
    pub const description = "Store audio through an olaf rest serve (or serve-lb) endpoint, printing what 'olaf store' prints.\n\t\turl\t The endpoint, e.g. http://127.0.0.1:8920 (default: config rest_endpoint).\n\t\t--threads n\t The number of files sent at the same time.\n\t\t-f, --force\t Re-store audio that is already indexed.\n\t\t--format <human|csv|json>\t Store record format (default: human).";
    pub const help = "[url] [--threads n] [-f] [--format <human|csv|json>] [audio_file...] | --with-ids [[audio_file audio_identifier]...]";
    pub const needs_audio_files = true;
    pub const accepts_endpoint = true;
    pub const flags = &[_]types.Flag{ .threads, .with_ids, .format, .force };
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    const url = try olaf_cli_rest_client.endpointUrl(args, config);
    // One CSV header before any record, as `olaf store` prints it.
    if (args.storeFormat() == .csv) {
        try std.Io.File.stderr().writeStreamingAll(args.io, olaf_cli_output.store_csv_header);
    }
    try olaf_cli_rest_client.run(allocator, args.audio_files.items, args.threads, .{
        .io = args.io,
        .config = config,
        .url = url,
        .action = .store,
        .store_format = args.storeFormat(),
        .query_format = args.queryFormat(),
        .force = args.force,
        .allow_identity_match = true,
        .fragmented = false,
    });
}
