const std = @import("std");
const olaf_cli_util = @import("olaf_cli_util.zig");
const olaf_cli_config = @import("olaf_cli_config.zig");
const olaf_cli_output = @import("olaf_cli_output.zig");

/// Shared Args type for all commands
pub const Args = struct {
    audio_files: std.ArrayList(olaf_cli_util.AudioFileWithId),
    threads: u32 = 1,
    fragmented: bool = false,
    use_audio_ids: bool = false,
    allow_identity_match: bool = true,
    skip_store: bool = false,
    force: bool = false,
    /// --format; null = the command's default (store: human, query: csv).
    format: ?olaf_cli_output.Format = null,
    config: ?*const olaf_cli_config.Config = null,
    io: std.Io = undefined,

    pub fn storeFormat(self: *const Args) olaf_cli_output.StoreFormat {
        return self.format orelse .human;
    }

    pub fn queryFormat(self: *const Args) olaf_cli_output.OutputFormat {
        return if ((self.format orelse .csv) == .json) .json else .csv;
    }

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        for (self.audio_files.items) |item| {
            item.deinit(allocator);
        }
        self.audio_files.deinit(allocator);
    }
};
