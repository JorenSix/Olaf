const std = @import("std");
const olaf_cli_util = @import("olaf_cli_util.zig");
const olaf_cli_config = @import("olaf_cli_config.zig");
const olaf_cli_output = @import("olaf_cli_output.zig");

/// Command-line options. Each command lists the ones it supports in
/// `CommandInfo.flags`; any other option is a usage error.
pub const Flag = enum { threads, no_identity_match, with_ids, fragmented, skip_store, format, force, verbose, listen, instances, threshold };

/// Shared Args type for all commands
pub const Args = struct {
    audio_files: std.ArrayList(olaf_cli_util.AudioFileWithId),
    threads: u32 = 1,
    fragmented: bool = false,
    use_audio_ids: bool = false,
    allow_identity_match: bool = true,
    skip_store: bool = false,
    force: bool = false,
    verbose: bool = false,
    /// --listen (rest serve, rest serve-lb), unparsed; null = the configured
    /// rest_listen / rest_lb_listen.
    listen: ?[]const u8 = null,
    /// -n (rest serve): instances on consecutive ports.
    instances: u16 = 1,
    /// The http(s):// URL argument of `rest store` / `rest query`; null =
    /// the `olaf rest serve` of the configured rest_listen.
    endpoint: ?[]const u8 = null,
    /// --threshold (has); null = the configured has_min_match_count.
    threshold: ?u32 = null,
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
