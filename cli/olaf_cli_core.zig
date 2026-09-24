//! Binding to the Olaf C core (src/). This is the only file that imports the
//! core headers; everything else goes through olaf_cli_session.zig. Only the
//! public core API is used, the core itself is never modified.
const std = @import("std");
const Io = std.Io;

const olaf_cli_config = @import("olaf_cli_config.zig");
const olaf_cli_util = @import("olaf_cli_util.zig");

pub const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");

    @cInclude("olaf_config.h");
    if (@import("builtin").is_test) @cInclude("olaf_config_parity.h");
    @cInclude("olaf_db.h");
    @cInclude("olaf_runner.h");
    @cInclude("olaf_stream_processor.h");
});

/// Numeric on-disk id of an audio identifier: the number itself when it is a
/// u32 decimal, otherwise its Jenkins hash (src/olaf_db_id.c).
pub fn nameToId(identifier: []const u8) u32 {
    return c.olaf_db_identifier_id(identifier.ptr, identifier.len);
}

/// True when the LMDB data file exists in `db_folder` (which always ends in
/// '/', see olaf_cli_config). Opening a read-only env on a missing database
/// would make the C core exit().
pub fn dbExists(allocator: std.mem.Allocator, db_folder: []const u8) !bool {
    const db_file_path = try std.fmt.allocPrint(allocator, "{s}data.mdb", .{db_folder});
    defer allocator.free(db_file_path);
    Io.Dir.cwd().access(olaf_cli_util.defaultIo(), db_file_path, .{}) catch return false;
    return true;
}

/// A C `Olaf_Config` filled from the CLI config. Owns the C struct and the
/// Zig-allocated dbFolder that replaces the C-allocated default.
pub const CoreConfig = struct {
    ptr: *c.Olaf_Config,
    db_folder: [:0]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: *const olaf_cli_config.Config) !CoreConfig {
        try olaf_cli_config.validate(config);
        const ptr: *c.Olaf_Config = c.olaf_config_default() orelse return error.OutOfMemory;
        errdefer c.olaf_config_destroy(ptr);
        copyConfig(config, ptr);
        const db_folder = try allocator.dupeZ(u8, config.db_folder);
        // Free the strdup'd default so freeing the struct doesn't double-free.
        if (ptr.dbFolder) |original| c.free(original);
        ptr.dbFolder = db_folder.ptr;
        return .{ .ptr = ptr, .db_folder = db_folder, .allocator = allocator };
    }

    pub fn deinit(self: *CoreConfig) void {
        self.allocator.free(self.db_folder);
        c.free(self.ptr);
    }

    /// Stdin/live queries have no natural end of stream, so results must be
    /// printed periodically and old matches aged out (mirrors src/olaf.c
    /// stdin mode). Only fills in values left at 0, the batch-query
    /// defaults, so an explicit config value still wins.
    pub fn applyLiveStreamDefaults(self: *CoreConfig) void {
        if (self.ptr.printResultEvery == 0) self.ptr.printResultEvery = 3;
        if (self.ptr.keepMatchesFor == 0) self.ptr.keepMatchesFor = 10;
    }
};

/// CLI config field -> C `Olaf_Config` field. Every algorithm setting is
/// listed once; copyConfig and the drift test below both use this table.
const c_fields = .{
    // Audio
    .{ "audio_block_size", "audioBlockSize" },
    .{ "target_sample_rate", "audioSampleRate" },
    .{ "audio_step_size", "audioStepSize" },
    .{ "bytes_per_audio_sample", "bytesPerAudioSample" },
    // Event points
    .{ "max_event_points", "maxEventPoints" },
    .{ "event_point_threshold", "eventPointThreshold" },
    .{ "sqrt_magnitude", "sqrtMagnitude" },
    .{ "filter_size_frequency", "filterSizeFrequency" },
    .{ "filter_size_time", "filterSizeTime" },
    .{ "min_event_point_magnitude", "minEventPointMagnitude" },
    .{ "max_event_point_usages", "maxEventPointUsages" },
    .{ "min_frequency_bin", "minFrequencyBin" },
    .{ "verbose", "verbose" },
    // Fingerprints
    .{ "number_of_eps_per_fp", "numberOfEPsPerFP" },
    .{ "use_magnitude_info", "useMagnitudeInfo" },
    .{ "min_time_distance", "minTimeDistance" },
    .{ "max_time_distance", "maxTimeDistance" },
    .{ "min_freq_distance", "minFreqDistance" },
    .{ "max_freq_distance", "maxFreqDistance" },
    .{ "max_fingerprints", "maxFingerprints" },
    // Matcher
    .{ "max_results", "maxResults" },
    .{ "search_range", "searchRange" },
    .{ "min_match_count", "minMatchCount" },
    .{ "min_match_time_diff", "minMatchTimeDiff" },
    .{ "keep_matches_for", "keepMatchesFor" },
    .{ "print_result_every", "printResultEvery" },
    .{ "max_db_collisions", "maxDBCollisions" },
};

/// C fields derived from other settings rather than copied.
const c_derived_fields = .{ "halfFilterSizeFrequency", "halfFilterSizeTime" };

fn copyConfig(config: *const olaf_cli_config.Config, c_config: *c.Olaf_Config) void {
    inline for (c_fields) |pair| {
        const Dest = @TypeOf(@field(c_config, pair[1]));
        const value = @field(config, pair[0]);
        @field(c_config, pair[1]) = if (@typeInfo(Dest) == .int) @intCast(value) else value;
    }
    c_config.halfFilterSizeFrequency = @intCast(config.filter_size_frequency / 2);
    c_config.halfFilterSizeTime = @intCast(config.filter_size_time / 2);
}

// Guards against drift between the hand-maintained defaults in
// src/olaf_config.c and cli/olaf_cli_config.zig: run the default Zig config
// through copyConfig and compare every mapped field against the C
// defaults. Changing a default on one side only fails this test.
test "config defaults: olaf_cli_config.zig matches olaf_config.c" {
    const c_default = c.olaf_config_default();
    defer c.olaf_config_destroy(c_default);

    const zig_default = olaf_cli_config.Config{};
    const c_from_zig = c.olaf_config_default();
    defer c.olaf_config_destroy(c_from_zig);
    copyConfig(&zig_default, c_from_zig);

    const checked = comptime blk: {
        var names: [c_fields.len + c_derived_fields.len][]const u8 = undefined;
        for (c_fields, 0..) |pair, i| names[i] = pair[1];
        for (c_derived_fields, 0..) |name, i| names[c_fields.len + i] = name;
        break :blk names;
    };
    inline for (checked) |field_name| {
        const c_value = @field(c_default.*, field_name);
        const zig_value = @field(c_from_zig.*, field_name);
        std.testing.expectEqual(c_value, zig_value) catch |err| {
            std.debug.print("config default drift in '{s}': olaf_config.c={any} olaf_cli_config.zig={any}\n", .{ field_name, c_value, zig_value });
            return err;
        };
    }
}

test "applyLiveStreamDefaults fills only zeroed live settings" {
    var cfg = try CoreConfig.init(std.testing.allocator, &olaf_cli_config.Config{});
    defer cfg.deinit();

    cfg.ptr.printResultEvery = 0;
    cfg.ptr.keepMatchesFor = 0;
    cfg.applyLiveStreamDefaults();
    try std.testing.expectEqual(@as(f32, 3), cfg.ptr.printResultEvery);
    try std.testing.expectEqual(@as(f32, 10), cfg.ptr.keepMatchesFor);

    cfg.ptr.printResultEvery = 1;
    cfg.ptr.keepMatchesFor = 5;
    cfg.applyLiveStreamDefaults();
    try std.testing.expectEqual(@as(f32, 1), cfg.ptr.printResultEvery);
    try std.testing.expectEqual(@as(f32, 5), cfg.ptr.keepMatchesFor);
}

/// Read immediately after a failed C constructor, before deferred cleanup.
pub fn constructorError(fallback: anyerror) anyerror {
    return switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
        .INVAL => error.InvalidConfigValue,
        .NOMEM => error.OutOfMemory,
        else => fallback,
    };
}

test "Zig and C configuration safety rules agree" {
    try std.testing.expectEqual(@as(usize, 4 * @sizeOf(c_int)), @sizeOf(c.struct_eventpoint));
    try std.testing.expectEqual(@as(usize, 9 * @sizeOf(c_int)), @sizeOf(c.struct_fingerprint));
    const ptr = c.olaf_config_default() orelse return error.OutOfMemory;
    defer c.olaf_config_destroy(ptr);
    inline for (.{ .{ "audio_block_size", 2048 }, .{ "audio_step_size", 0 }, .{ "bytes_per_audio_sample", 8 }, .{ "max_results", 0 }, .{ "number_of_eps_per_fp", 4 }, .{ "filter_size_time", 1 }, .{ "event_point_threshold", 60 }, .{ "min_frequency_bin", 512 }, .{ "min_time_distance", 34 }, .{ "min_freq_distance", 129 }, .{ "max_event_point_usages", std.math.maxInt(c_int) } }) |pair| {
        var config = olaf_cli_config.Config{};
        @field(config, pair[0]) = pair[1];
        copyConfig(&config, ptr);
        try std.testing.expect(olaf_cli_config.validationIssue(&config) != null);
        try std.testing.expect(c.olaf_test_config_error(ptr) != null);
        try std.testing.expectError(error.InvalidConfigValue, CoreConfig.init(std.testing.allocator, &config));
    }
    for ([_]u32{ 2, 3, 4, 13, 24 }) |size| {
        const config = olaf_cli_config.Config{ .filter_size_time = size };
        copyConfig(&config, ptr);
        try std.testing.expect(olaf_cli_config.validationIssue(&config) == null);
        try std.testing.expect(c.olaf_test_config_error(ptr) == null);
    }
}
