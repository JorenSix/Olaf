const std = @import("std");
const rest = @import("olaf_rest");
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "rest serve-lb";
    pub const description = "Serve the REST API on rest_lb_listen (default 127.0.0.1:9920), answered by the\n\t\t`olaf rest serve` instances in rest_lb_backends: a store goes to one of them (rest_lb_store_strategy),\n\t\tquery, stats and health to all, with the results of every instance in one response.\n\t\t--listen host:port|port\t Listen there instead of rest_lb_listen (a port alone: 127.0.0.1).";
    pub const help = "[--listen host:port|port]";
    pub const needs_audio_files = false;
    pub const flags = &[_]types.Flag{.listen};
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    const listen = args.listen orelse config.rest_lb_listen;
    const address = rest.parseListen(listen) orelse {
        std.log.err("config: 'rest_lb_listen' must be host:port or a port (e.g. 127.0.0.1:9920 or 9920), got \"{s}\"", .{listen});
        return error.InvalidConfigValue;
    };
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
    }
    // Informational: an unreachable backend is still used once it is up.
    {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const problems = try rest.lb.probe(arena_state.allocator(), args.io, backends);
        std.debug.print("olaf rest serve-lb: {d} backend{s}, store strategy {s}\n", .{ backends.len, if (backends.len == 1) "" else "s", @tagName(strategy) });
        for (backends, problems) |b, problem| std.debug.print("  {s}: {s}\n", .{ b, problem orelse "ok" });
    }

    var lb = rest.LbBackend.init(args.io, backends, strategy);
    try rest.serve(allocator, args.io, lb.backend(), .{
        .host = address.host,
        .port = address.port,
        .max_body_bytes = @as(usize, config.rest_max_body_mb) * 1024 * 1024,
        .name = "olaf rest serve-lb",
        .max_matches = config.max_results,
    });
}
