const std = @import("std");
const rest = @import("olaf_rest");
const types = @import("../olaf_cli_types.zig");
const log = std.log.scoped(.olaf_rest_lb);

pub const CommandInfo = struct {
    pub const name = "rest serve-lb";
    pub const description = "Serve the REST API on rest_lb_listen (default 127.0.0.1:9920), answered by the `olaf rest serve` instances in rest_lb_backends: a store goes to one of them (rest_lb_store_strategy); query, stats and health go to all, with the results of every instance in one response.";
    pub const options = &[_]types.Option{
        .{ .name = "--listen host:port|port", .text = "Listen there instead of rest_lb_listen (a port alone: 127.0.0.1)." },
    };
    pub const help = "[--listen host:port|port]";
    pub const needs_audio_files = false;
    pub const flags = &[_]types.Flag{.listen};
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    const listen = args.listen orelse config.rest_lb_listen;
    const address = rest.parseListen(listen) orelse {
        log.err("config: 'rest_lb_listen' must be host:port or a port (e.g. 127.0.0.1:9920 or 9920), got \"{s}\"", .{listen});
        return error.InvalidConfigValue;
    };
    const strategy = std.meta.stringToEnum(rest.StoreStrategy, config.rest_lb_store_strategy) orelse {
        log.err("config: 'rest_lb_store_strategy' must be \"random\" or \"hash\", got \"{s}\"", .{config.rest_lb_store_strategy});
        return error.InvalidConfigValue;
    };
    if (config.rest_lb_backends.len == 0) {
        log.err("config: 'rest_lb_backends' lists no backends", .{});
        return error.InvalidConfigValue;
    }
    const backends = try allocator.alloc([]const u8, config.rest_lb_backends.len);
    defer allocator.free(backends);
    for (config.rest_lb_backends, backends) |url, *b| {
        b.* = rest.lb.normalizeUrl(url) orelse {
            log.err("config: 'rest_lb_backends' entry \"{s}\" is not an http:// or https:// URL", .{url});
            return error.InvalidConfigValue;
        };
    }
    // Informational: an unreachable backend is still used once it is up.
    {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const problems = try rest.lb.probe(arena_state.allocator(), args.io, backends);
        log.info("{d} backend{s}, store strategy {s}", .{ backends.len, if (backends.len == 1) "" else "s", @tagName(strategy) });
        for (backends, problems) |b, problem| {
            if (problem) |p| log.warn("backend {s}: {s}", .{ b, p }) else log.info("backend {s}: ok", .{b});
        }
    }

    var lb = rest.LbBackend.init(args.io, backends, strategy);
    try rest.serve(allocator, args.io, lb.backend(), .{
        .host = address.host,
        .port = address.port,
        .max_body_bytes = @as(usize, config.rest_max_body_mb) * 1024 * 1024,
        .name = "olaf rest serve-lb",
        .scope = .olaf_rest_lb,
        .max_matches = config.max_results,
    });
}
