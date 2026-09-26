const std = @import("std");
const rest = @import("olaf_rest");
const olaf_cli_session = @import("../olaf_cli_session.zig");
const LocalBackend = @import("../olaf_cli_rest_backend.zig").LocalBackend;
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "rest serve";
    pub const description = "Serve the REST API for this database on rest_host:rest_port (default 127.0.0.1:8920):\n\t\tPOST /api/store?identifier=id, POST /api/query, GET /api/stats, GET /api/healthz.\n\t\t--port n\t Listen on port n instead of rest_port.";
    pub const help = "[--port n]";
    pub const needs_audio_files = false;
    pub const flags = &[_]types.Flag{.port};
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    // Create the database up front: requests never meet a missing one.
    try olaf_cli_session.prepareDb(allocator, config, true);
    var local = LocalBackend.init(config);
    try rest.serve(allocator, args.io, local.backend(), .{
        .host = config.rest_host,
        .port = args.port orelse @intCast(config.rest_port),
        .max_body_bytes = @as(usize, config.rest_max_body_mb) * 1024 * 1024,
        .name = "olaf rest serve",
        .max_matches = config.max_results,
    });
}
