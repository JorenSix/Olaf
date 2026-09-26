const std = @import("std");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const types = @import("../olaf_cli_types.zig");

/// The REST commands: servers (`serve`, `serve-lb`) and clients (`store`,
/// `query`, which mirror `olaf store` / `olaf query`).
pub const subcommands = .{
    @import("olaf_cli_cmd_rest_serve.zig"),
    @import("olaf_cli_cmd_rest_serve_lb.zig"),
    @import("olaf_cli_cmd_rest_store.zig"),
    @import("olaf_cli_cmd_rest_query.zig"),
    @import("olaf_cli_cmd_rest_has.zig"),
};

pub const CommandInfo = struct {
    pub const name = "rest";
    pub const description = "REST API: 'serve' a database, 'serve-lb' a load balancer over several, and 'store' / 'query' / 'has' through one of them.";
    pub const help = "<serve|serve-lb|store|query|has> ...";
    pub const needs_audio_files = false;
    pub const flags = &[_]types.Flag{};
};

/// Only reached without a subcommand (see the dispatch in olaf_cli.zig).
pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    _ = allocator;
    _ = args;
    olaf_cli_util.print("olaf rest {s}\n", .{CommandInfo.help});
    return error.Usage;
}
