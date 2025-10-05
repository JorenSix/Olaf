const std = @import("std");
const olaf_wrapper_util = @import("olaf_wrapper_util.zig");
const olaf_wrapper_config = @import("olaf_wrapper_config.zig");

/// Shared Args type for all commands
pub const Args = struct {
    audio_files: std.ArrayList(olaf_wrapper_util.AudioFileWithId),
    threads: u32 = 1,
    fragmented: bool = false,
    use_audio_ids: bool = false,
    allow_identity_match: bool = true,
    skip_store: bool = false,
    force: bool = false,
    config: ?*const olaf_wrapper_config.Config = null,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        for (self.audio_files.items) |item| {
            item.deinit(allocator);
        }
        self.audio_files.deinit(allocator);
    }
};
