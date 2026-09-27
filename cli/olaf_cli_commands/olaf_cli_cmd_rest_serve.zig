const std = @import("std");
const rest = @import("olaf_rest");
const olaf_cli_session = @import("../olaf_cli_session.zig");
const olaf_cli_rest_backend = @import("../olaf_cli_rest_backend.zig");
const LocalBackend = olaf_cli_rest_backend.LocalBackend;
const Config = @import("../olaf_cli_config.zig").Config;
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "rest serve";
    pub const description = "Serve the REST API for this database on rest_listen (default 127.0.0.1:8920):\n\t\tPOST /api/store?identifier=id, POST /api/query, GET /api/stats, GET /api/healthz.\n\t\tThe database is db_folder/<host>_<port>/ (rest_append_db_path_with_addr).\n\t\t--listen host:port|port\t Listen there instead of rest_listen (a port alone: 127.0.0.1).\n\t\t-n count\t Serve count instances, on consecutive ports, each with its own database (backends for serve-lb).";
    pub const help = "[--listen host:port|port] [-n count]";
    pub const needs_audio_files = false;
    pub const flags = &[_]types.Flag{ .listen, .instances };
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    const listen = args.listen orelse config.rest_listen;
    const first = rest.parseListen(listen) orelse {
        std.log.err("config: 'rest_listen' must be host:port or a port (e.g. 127.0.0.1:8920 or 8920), got \"{s}\"", .{listen});
        return error.InvalidConfigValue;
    };
    const n: usize = args.instances;
    if (@as(usize, first.port) + n - 1 > std.math.maxInt(u16)) {
        std.log.err("-n {d} from port {d} goes past port 65535", .{ n, first.port });
        return error.InvalidConfigValue;
    }
    if (n > 1 and !config.rest_append_db_path_with_addr) {
        std.log.err("-n {d} needs rest_append_db_path_with_addr: the instances would share one database", .{n});
        return error.InvalidConfigValue;
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const configs = try arena.alloc(Config, n);
    const locals = try arena.alloc(LocalBackend, n);
    const backends = try arena.alloc(rest.Backend, n);
    const opts = try arena.alloc(rest.ServeOptions, n);
    const urls = try arena.alloc([]const u8, n);
    for (configs, locals, backends, opts, urls, 0..) |*cfg, *local, *backend, *o, *url, i| {
        const address: rest.ListenAddress = .{ .host = first.host, .port = first.port + @as(u16, @intCast(i)) };
        cfg.* = config.*;
        if (config.rest_append_db_path_with_addr) {
            cfg.db_folder = try olaf_cli_rest_backend.addrDbFolder(arena, config.db_folder, address);
            std.Io.Dir.cwd().createDirPath(args.io, cfg.db_folder) catch |err| {
                std.log.err("cannot create database folder '{s}' ({})", .{ cfg.db_folder, err });
                return err;
            };
        }
        // Create the database up front: requests never meet a missing one.
        try olaf_cli_session.prepareDb(allocator, cfg, true);
        std.debug.print("database for {s}:{d}: {s}\n", .{ address.host, address.port, cfg.db_folder });
        local.* = LocalBackend.init(cfg);
        backend.* = local.backend();
        url.* = try rest.clientUrl(arena, address);
        o.* = .{
            .host = address.host,
            .port = address.port,
            .max_body_bytes = @as(usize, config.rest_max_body_mb) * 1024 * 1024,
            .name = "olaf rest serve",
            .max_matches = config.max_results,
            .log_label = if (n > 1) try std.fmt.allocPrint(arena, "[{s}:{d}] ", .{ address.host, address.port }) else "",
        };
    }
    if (n > 1) {
        var line: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(urls, .{}, &line.writer);
        std.debug.print("rest_lb_backends for these instances: {s}\n", .{line.written()});
    }
    try rest.serveAll(allocator, args.io, backends, opts);
}
