const std = @import("std");
const olaf_wrapper_bridge = @import("../olaf_wrapper_bridge.zig");
const types = @import("../olaf_wrapper_types.zig");

pub const CommandInfo = struct {
    pub const name = "stats";
    pub const description = "Print statistics about the audio files in the database.";
    pub const help = "";
    pub const needs_audio_files = false;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    try olaf_wrapper_bridge.olaf_stats(allocator, args.config.?);
}
