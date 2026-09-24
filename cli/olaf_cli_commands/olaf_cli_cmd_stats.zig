const std = @import("std");
const olaf_cli_session = @import("../olaf_cli_session.zig");
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "stats";
    pub const description = "Print database summary statistics. Include the per-file table with --verbose or config verbose=true.";
    pub const help = "[--verbose]";
    pub const needs_audio_files = false;
    pub const flags = &[_]types.Flag{.verbose};
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    try olaf_cli_session.printStats(allocator, config, config.verbose or args.verbose);
}
