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
    @cInclude("olaf_db.h");
    @cInclude("olaf_fp_db_writer_cache.h");
    @cInclude("olaf_runner.h");
    @cInclude("olaf_stream_processor.h");
});

/// Numeric on-disk id of an audio identifier: the number itself when it is a
/// u32 decimal, otherwise its Jenkins hash (src/olaf_db_id.c).
pub fn nameToId(identifier: []const u8) u32 {
    return c.olaf_db_identifier_id(identifier.ptr, identifier.len);
}

/// True when the LMDB data file exists in `config.db_folder` (which always
/// ends in '/', see olaf_cli_config). Opening a read-only env on a missing
/// database would make the C core exit().
pub fn dbExists(allocator: std.mem.Allocator, config: *const olaf_cli_config.Config) !bool {
    const db_file_path = try std.fmt.allocPrint(allocator, "{s}data.mdb", .{config.db_folder});
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

fn copyConfig(config: *const olaf_cli_config.Config, c_config: *c.Olaf_Config) void {
    // Audio configurations
    c_config.audioBlockSize = @intCast(config.audio_block_size);
    c_config.audioSampleRate = @intCast(config.target_sample_rate);
    c_config.audioStepSize = @intCast(config.audio_step_size);
    c_config.bytesPerAudioSample = @intCast(config.bytes_per_audio_sample);

    // Event point configurations
    c_config.maxEventPoints = @intCast(config.max_event_points);
    c_config.eventPointThreshold = @intCast(config.event_point_threshold);
    c_config.sqrtMagnitude = config.sqrt_magnitude;
    c_config.filterSizeFrequency = @intCast(config.filter_size_frequency);
    c_config.halfFilterSizeFrequency = @intCast(config.filter_size_frequency / 2);
    c_config.filterSizeTime = @intCast(config.filter_size_time);
    c_config.halfFilterSizeTime = @intCast(config.filter_size_time / 2);
    c_config.minEventPointMagnitude = config.min_event_point_magnitude;
    c_config.maxEventPointUsages = @intCast(config.max_event_point_usages);
    c_config.minFrequencyBin = @intCast(config.min_frequency_bin);

    // Debug configuration
    c_config.verbose = config.verbose;

    // Fingerprint configurations
    c_config.numberOfEPsPerFP = @intCast(config.number_of_eps_per_fp);
    c_config.useMagnitudeInfo = config.use_magnitude_info;
    c_config.minTimeDistance = @intCast(config.min_time_distance);
    c_config.maxTimeDistance = @intCast(config.max_time_distance);
    c_config.minFreqDistance = @intCast(config.min_freq_distance);
    c_config.maxFreqDistance = @intCast(config.max_freq_distance);
    c_config.maxFingerprints = @intCast(config.max_fingerprints);

    // Matcher configurations
    c_config.maxResults = @intCast(config.max_results);
    c_config.searchRange = @intCast(config.search_range);
    c_config.minMatchCount = @intCast(config.min_match_count);
    c_config.minMatchTimeDiff = config.min_match_time_diff;
    c_config.keepMatchesFor = config.keep_matches_for;
    c_config.printResultEvery = config.print_result_every;
    c_config.maxDBCollisions = @intCast(config.max_db_collisions);
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

    const fields = .{
        "audioBlockSize",         "audioSampleRate",         "audioStepSize",  "bytesPerAudioSample",
        "maxEventPoints",         "eventPointThreshold",     "sqrtMagnitude",  "filterSizeFrequency",
        "halfFilterSizeFrequency", "filterSizeTime",         "halfFilterSizeTime", "minEventPointMagnitude",
        "maxEventPointUsages",    "minFrequencyBin",         "verbose",        "numberOfEPsPerFP",
        "useMagnitudeInfo",       "minTimeDistance",         "maxTimeDistance", "minFreqDistance",
        "maxFreqDistance",        "maxFingerprints",         "maxResults",     "searchRange",
        "minMatchCount",          "minMatchTimeDiff",        "keepMatchesFor", "printResultEvery",
        "maxDBCollisions",
    };
    inline for (fields) |field_name| {
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
