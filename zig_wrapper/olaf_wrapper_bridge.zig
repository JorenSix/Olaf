const std = @import("std");
const process = std.process;
const debug = std.log.scoped(.olaf_wrapper_bridge).debug;

const olaf_wrapper_config = @import("olaf_wrapper_config.zig");

const olaf = @cImport({
    @cInclude("olaf_wrapper_bridge.h");
});

fn olaf_main(allocator: std.mem.Allocator, args_list: []const []const u8) !void {
    var c_argv = try allocator.alloc([*c]const u8, args_list.len);
    defer allocator.free(c_argv);
    for (args_list, 0..) |arg, i| {
        c_argv[i] = arg.ptr;
    }
    _ = olaf.olaf_main(@intCast(args_list.len), c_argv.ptr);
    debug("olaf main with custom args\n", .{});
}

fn copy_to_c_config(config: *const olaf_wrapper_config.Config, c_config: *olaf.Olaf_Config) !void {
    debug("Copying configuration to C struct", .{});

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

    debug("Configuration copy complete", .{});
}

pub fn olaf_store(allocator: std.mem.Allocator, raw_audio_path: []const u8, audio_identifier: []const u8, config: *const olaf_wrapper_config.Config) !void {
    const c_config = olaf.olaf_default_config(); // Ensure the default config is set
    try copy_to_c_config(config, c_config);

    // Path configuration
    const c_db_folder = try allocator.dupeZ(u8, config.db_folder);
    c_config.*.dbFolder = c_db_folder;
    defer {
        allocator.free(c_db_folder);
    }

    const c_raw_audio_path = try allocator.dupeZ(u8, raw_audio_path);
    defer allocator.free(c_raw_audio_path);

    const c_audio_identifier = try allocator.dupeZ(u8, audio_identifier);
    defer allocator.free(c_audio_identifier);

    olaf.olaf_store(c_config, c_raw_audio_path, c_audio_identifier);
}

pub fn olaf_query(allocator: std.mem.Allocator, input_raw: []const u8, input_path: []const u8) !void {
    const args = [_][]const u8{
        "olaf", // program name
        "query", // command
        input_raw, // input file
        input_path, // input file name full path original
    };
    try olaf_main(allocator, &args);
}

pub fn olaf_stats(allocator: std.mem.Allocator, config: *const olaf_wrapper_config.Config) !void {
    const c_config = olaf.olaf_default_config(); // Ensure the default config is set
    try copy_to_c_config(config, c_config);

    // Path configuration
    const c_db_folder = try allocator.dupeZ(u8, config.db_folder);
    c_config.*.dbFolder = c_db_folder;
    defer {
        allocator.free(c_db_folder);
    }
    _ = olaf.olaf_stats(c_config);
}
