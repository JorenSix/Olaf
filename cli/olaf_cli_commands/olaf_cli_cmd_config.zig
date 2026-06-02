const std = @import("std");
const types = @import("../olaf_cli_types.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");

const print = olaf_cli_util.print;

pub const CommandInfo = struct {
    pub const name = "config";
    pub const description = "Prints the current configuration in use.";
    pub const help = "[audio_file...] | --with-ids [audio_file audio_identifier]";
    pub const needs_audio_files = false;
};

pub fn execute(_: std.mem.Allocator, args: *types.Args) !void {
    if (args.config) |config| {
        print("Current Olaf Configuration:\n", .{});
        try config.infoPrint();
    } else {
        print("No configuration loaded.\n", .{});
    }
}
