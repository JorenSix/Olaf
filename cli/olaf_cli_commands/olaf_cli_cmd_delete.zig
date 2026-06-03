const std = @import("std");
const olaf_cli_bridge = @import("../olaf_cli_bridge.zig");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");
const types = @import("../olaf_cli_types.zig");
const util = @import("../olaf_cli_util.zig");

const debug = std.log.scoped(.olaf_cli_delete).debug;

const print = util.print;

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
        olaf_cli_threading.processAudioFile(
            args.io,
            allocator,
            audio_file,
            args.config.?,
            index,
            args.audio_files.items.len,
            .Delete,
            0,
            .csv,
            .human,
        ) catch |err| {
            return err;
        };
    }
}
