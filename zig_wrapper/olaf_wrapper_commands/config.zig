const std = @import("std");
const types = @import("../olaf_wrapper_types.zig");

fn print(comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    _ = stdout.print(fmt, args) catch {};
    _ = stdout.flush() catch {};
}

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
