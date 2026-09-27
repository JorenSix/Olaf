const std = @import("std");
const rest = @import("olaf_rest");
const olaf_cli_session = @import("../olaf_cli_session.zig");
const LocalBackend = @import("../olaf_cli_rest_backend.zig").LocalBackend;
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "rest serve";
    pub const description = "Serve the REST API for this database on rest_listen (default 127.0.0.1:8920):\n\t\tPOST /api/store?identifier=id, POST /api/query, GET /api/stats, GET /api/healthz.\n\t\t--listen host:port|port\t Listen there instead of rest_listen (a port alone: 127.0.0.1).";
    pub const help = "[--listen host:port|port]";
    pub const needs_audio_files = false;
    pub const flags = &[_]types.Flag{.listen};
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    const listen = args.listen orelse config.rest_listen;
    const address = rest.parseListen(listen) orelse {
        std.log.err("config: 'rest_listen' must be host:port or a port (e.g. 127.0.0.1:8920 or 8920), got \"{s}\"", .{listen});
        return error.InvalidConfigValue;
    };
    // Create the database up front: requests never meet a missing one.
    try olaf_cli_session.prepareDb(allocator, config, true);
    var local = LocalBackend.init(config);
    try rest.serve(allocator, args.io, local.backend(), .{
        .host = address.host,
        .port = address.port,
        .max_body_bytes = @as(usize, config.rest_max_body_mb) * 1024 * 1024,
        .name = "olaf rest serve",
        .max_matches = config.max_results,
    });
}
