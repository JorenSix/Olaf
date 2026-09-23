const std = @import("std");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");
const types = @import("../olaf_cli_types.zig");
const util = @import("../olaf_cli_util.zig");

const print = util.print;

pub const CommandInfo = struct {
    pub const name = "delete";
    pub const description = "Delete fingerprints from the database by audio identifier.";
    pub const help = "[audio_file...] | --with-ids [[audio_file audio_identifier] ...]";
    pub const needs_audio_files = true;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to delete.\n", .{});
        return;
    }

    // Deletes are LMDB writes and serialize on the writer lock anyway, so run
    // them one by one; executeParallel still applies the shared failure
    // policy (log, continue, error.ProcessingFailed at the end).
    try olaf_cli_threading.executeParallel(
        args.io,
        allocator,
        args.audio_files.items,
        args.config.?,
        .Delete,
        1,
        true,
        .csv,
        .human,
    );
}
