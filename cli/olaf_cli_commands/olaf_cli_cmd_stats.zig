const std = @import("std");
const olaf_cli_bridge = @import("../olaf_cli_bridge.zig");
const olaf_cli_config = @import("../olaf_cli_config.zig");
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "stats";
    pub const description = "Print statistics about the audio files in the database.";
    pub const help = "";
    pub const needs_audio_files = false;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {

    //config: *const olaf_cli_config.Config = args.config;

    try olaf_cli_bridge.olaf_stats(allocator, args.config.?);
}
