const std = @import("std");
const rest = @import("olaf_rest");
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "rest serve-lb";
    pub const description = "Serve the REST API on rest_host:rest_lb_port (default 127.0.0.1:8921), answered by the\n\t\t`olaf rest serve` instances in rest_lb_backends: a store goes to one of them (rest_lb_store_strategy),\n\t\tquery, stats and health to all, with the results of every instance in one response.\n\t\t--port n\t Listen on port n instead of rest_lb_port.";
    pub const help = "[--port n]";
    pub const needs_audio_files = false;
    pub const flags = &[_]types.Flag{.port};
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    const strategy = std.meta.stringToEnum(rest.StoreStrategy, config.rest_lb_store_strategy) orelse {
        std.log.err("config: 'rest_lb_store_strategy' must be \"random\" or \"hash\", got \"{s}\"", .{config.rest_lb_store_strategy});
        return error.InvalidConfigValue;
    };
    if (config.rest_lb_backends.len == 0) {
        std.log.err("config: 'rest_lb_backends' lists no backends", .{});
        return error.InvalidConfigValue;
    }
    const backends = try allocator.alloc([]const u8, config.rest_lb_backends.len);
    defer allocator.free(backends);
    for (config.rest_lb_backends, backends) |url, *b| {
        b.* = rest.lb.normalizeUrl(url) orelse {
            std.log.err("config: 'rest_lb_backends' entry \"{s}\" is not an http:// or https:// URL", .{url});
            return error.InvalidConfigValue;
        };
        std.debug.print("backend: {s}\n", .{b.*});
    }

    var lb = rest.LbBackend.init(args.io, backends, strategy);
    try rest.serve(allocator, args.io, lb.backend(), .{
        .host = config.rest_host,
        .port = args.port orelse @intCast(config.rest_lb_port),
        .max_body_bytes = @as(usize, config.rest_max_body_mb) * 1024 * 1024,
        .name = "olaf rest serve-lb",
        .max_matches = config.max_results,
    });
}
