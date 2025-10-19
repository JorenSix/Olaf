const std = @import("std");
const olaf_cli_util = @import("olaf_cli_util.zig");
const olaf_cli_config = @import("olaf_cli_config.zig");

/// Shared Args type for all commands
pub const Args = struct {
    audio_files: std.ArrayList(olaf_cli_util.AudioFileWithId),
    threads: u32 = 1,
    fragmented: bool = false,
    fragment_duration: u32 = 30,
    use_audio_ids: bool = false,
    allow_identity_match: bool = true,
    skip_store: bool = false,
    force: bool = false,
    config: ?*const olaf_cli_config.Config = null,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        for (self.audio_files.items) |item| {
            item.deinit(allocator);
        }
        self.audio_files.deinit(allocator);
    }
};
