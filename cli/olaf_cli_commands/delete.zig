const std = @import("std");
const olaf_wrapper_bridge = @import("../olaf_wrapper_bridge.zig");
const olaf_wrapper_threading = @import("../olaf_wrapper_threading.zig");
const types = @import("../olaf_wrapper_types.zig");
const util = @import("../olaf_wrapper_util.zig");

const debug = std.log.scoped(.olaf_wrapper_delete).debug;

fn print(comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    _ = stdout.print(fmt, args) catch {};
    _ = stdout.flush() catch {};
}

pub const CommandInfo = struct {
    pub const name = "delete";
    pub const description = "Delete fingerprints from the database by audio identifier.";
    pub const help = "[audio_file...] | --with-ids [[audio_file audio_identifier] ...]";
    pub const needs_audio_files = true;
};

/// Wrapper for storing audio identifiers to delete
pub const AudioIdentifier = struct {
    identifier: []const u8,

    pub fn deinit(self: *const AudioIdentifier, allocator: std.mem.Allocator) void {
        allocator.free(self.identifier);
    }
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to query.\n", .{});
        return;
    }

    for (args.audio_files.items, 0..) |audio_file, index| {
        debug("Delete audio file: {s} with identifier: {s}", .{ audio_file.path, audio_file.identifier });
        olaf_wrapper_threading.processAudioFile(
            allocator,
            audio_file,
            args.config.?,
            index,
            args.audio_files.items.len,
            .Delete,
        ) catch |err| {
            return err;
        };
    }
}
