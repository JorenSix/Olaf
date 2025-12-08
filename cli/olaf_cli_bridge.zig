const std = @import("std");
const process = std.process;
const debug = std.log.scoped(.olaf_cli_bridge).debug;
const File = std.fs.File;

const olaf_cli_config = @import("olaf_cli_config.zig");

const olaf = @cImport({
    @cInclude("string.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h"); // Add this for fdopen

    @cInclude("olaf_cli_bridge.h");
    @cInclude("olaf_db.h");
    @cInclude("olaf_fp_db_writer_cache.h");
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

fn copy_to_c_config(config: *const olaf_cli_config.Config, c_config: *olaf.Olaf_Config) !void {
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

pub fn olaf_store(allocator: std.mem.Allocator, raw_audio_path: []const u8, audio_identifier: []const u8, config: *const olaf_cli_config.Config) !void {
    const c_config = olaf.olaf_default_config(); // Ensure the default config is set
    try copy_to_c_config(config, c_config);

    // Path configuration - Replace C-allocated dbFolder with Zig-allocated one
    if (c_config.*.dbFolder) |original_db_folder| {
        olaf.free(original_db_folder);
    }

    const c_db_folder = try allocator.dupeZ(u8, config.db_folder);
    c_config.*.dbFolder = c_db_folder.ptr;

    defer {
        // Manual cleanup: free dbFolder (with Zig allocator) then config (with C allocator)
        allocator.free(c_db_folder);
        olaf.free(c_config);
    }

    const c_raw_audio_path = try allocator.dupeZ(u8, raw_audio_path);
    defer allocator.free(c_raw_audio_path);

    const c_audio_identifier = try allocator.dupeZ(u8, audio_identifier);
    defer allocator.free(c_audio_identifier);

    olaf.olaf_store(c_config, c_raw_audio_path, c_audio_identifier);
}

pub fn olaf_query(allocator: std.mem.Allocator, q_index: usize, q_total: usize, query_path: []const u8, raw_audio_path: []const u8, audio_identifier: []const u8, config: *const olaf_cli_config.Config) !void {
    const c_config = olaf.olaf_default_config(); // Ensure the default config is set
    try copy_to_c_config(config, c_config);

    // Path configuration - Replace C-allocated dbFolder with Zig-allocated one
    if (c_config.*.dbFolder) |original_db_folder| {
        olaf.free(original_db_folder);
    }

    const c_db_folder = try allocator.dupeZ(u8, config.db_folder);
    c_config.*.dbFolder = c_db_folder.ptr;

    defer {
        // Manual cleanup: free dbFolder (with Zig allocator) then config (with C allocator)
        allocator.free(c_db_folder);
        olaf.free(c_config);
    }

    const c_raw_audio_path = try allocator.dupeZ(u8, raw_audio_path);
    defer allocator.free(c_raw_audio_path);

    const c_audio_identifier = try allocator.dupeZ(u8, audio_identifier);
    defer allocator.free(c_audio_identifier);

    const c_query_path = try allocator.dupeZ(u8, query_path);
    defer allocator.free(c_query_path);

    olaf.olaf_query(c_config, q_index, q_total, c_query_path, c_raw_audio_path, c_audio_identifier);
}

pub fn olaf_delete(allocator: std.mem.Allocator, raw_audio_path: []const u8, audio_identifier: []const u8, config: *const olaf_cli_config.Config) !void {
    const c_config = olaf.olaf_default_config(); // Ensure the default config is set
    try copy_to_c_config(config, c_config);

    // Path configuration - Replace C-allocated dbFolder with Zig-allocated one
    if (c_config.*.dbFolder) |original_db_folder| {
        olaf.free(original_db_folder);
    }

    const c_db_folder = try allocator.dupeZ(u8, config.db_folder);
    c_config.*.dbFolder = c_db_folder.ptr;

    defer {
        // Manual cleanup: free dbFolder (with Zig allocator) then config (with C allocator)
        allocator.free(c_db_folder);
        olaf.free(c_config);
    }

    const c_raw_audio_path = try allocator.dupeZ(u8, raw_audio_path);
    defer allocator.free(c_raw_audio_path);

    const c_audio_identifier = try allocator.dupeZ(u8, audio_identifier);
    defer allocator.free(c_audio_identifier);

    olaf.olaf_delete(c_config, c_raw_audio_path, c_audio_identifier);
}

pub fn olaf_stats(allocator: std.mem.Allocator, config: *const olaf_cli_config.Config) !void {
    const c_config = olaf.olaf_default_config(); // Ensure the default config is set
    try copy_to_c_config(config, c_config);

    // Path configuration - Replace C-allocated dbFolder with Zig-allocated one
    if (c_config.*.dbFolder) |original_db_folder| {
        olaf.free(original_db_folder);
    }

    const c_db_folder = try allocator.dupeZ(u8, config.db_folder);
    c_config.*.dbFolder = c_db_folder.ptr;

    defer {
        // Manual cleanup: free dbFolder (with Zig allocator) then config (with C allocator)
        allocator.free(c_db_folder);
        olaf.free(c_config);
    }

    std.debug.print("Fetching statistics from database in folder: {s}\n", .{config.db_folder});

    // Check if database file exists
    const db_file_path = try std.fmt.allocPrint(allocator, "{s}data.mdb", .{config.db_folder});
    defer allocator.free(db_file_path);

    const file_exists = blk: {
        std.fs.cwd().access(db_file_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!file_exists) {
        // Print empty stats when database doesn't exist
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        _ = try stdout.print("Number of songs (#):\t0\n", .{});
        _ = try stdout.flush();
        _ = try stdout.print("Total duration (s):\t0.0\n", .{});
        _ = try stdout.flush();
        _ = try stdout.print("Avg prints/s (fp/s):\t0.0\n", .{});
        _ = try stdout.flush();

        std.debug.print("File does not exist: {s}\n", .{db_file_path});
        return;
    } else {
        std.debug.print("File exists: {s}\n", .{db_file_path});
    }

    // Call the C stats function
    _ = olaf.olaf_stats(c_config);
}

pub fn olaf_print(allocator: std.mem.Allocator, raw_audio_path: []const u8, audio_identifier: []const u8, config: *const olaf_cli_config.Config) !void {
    const c_config = olaf.olaf_default_config();
    try copy_to_c_config(config, c_config);

    // Path configuration - Replace C-allocated dbFolder with Zig-allocated one
    // Free the original dbFolder allocated by olaf_default_config
    if (c_config.*.dbFolder) |original_db_folder| {
        olaf.free(original_db_folder);
    }

    // Allocate with Zig allocator and store slice for later cleanup
    const c_db_folder = try allocator.dupeZ(u8, config.db_folder);
    c_config.*.dbFolder = c_db_folder.ptr;

    defer {
        // Manual cleanup: free dbFolder (with Zig allocator) then config (with C allocator)
        allocator.free(c_db_folder);
        olaf.free(c_config);
    }

    const c_raw_audio_path = try allocator.dupeZ(u8, raw_audio_path);
    defer allocator.free(c_raw_audio_path);

    const c_audio_identifier = try allocator.dupeZ(u8, audio_identifier);
    defer allocator.free(c_audio_identifier);

    olaf.olaf_print(c_config, c_raw_audio_path, c_audio_identifier);
}

pub fn olaf_print_to_file(allocator: std.mem.Allocator, raw_audio_path: []const u8, audio_identifier: []const u8, config: *const olaf_cli_config.Config, output_file_path: []const u8) !void {
    const c_config = olaf.olaf_default_config();
    try copy_to_c_config(config, c_config);

    // Path configuration - Replace C-allocated dbFolder with Zig-allocated one
    // Free the original dbFolder allocated by olaf_default_config
    if (c_config.*.dbFolder) |original_db_folder| {
        olaf.free(original_db_folder);
    }

    // Allocate with Zig allocator and store slice for later cleanup
    const c_db_folder = try allocator.dupeZ(u8, config.db_folder);
    c_config.*.dbFolder = c_db_folder.ptr;

    defer {
        // Manual cleanup: free dbFolder (with Zig allocator) then config (with C allocator)
        allocator.free(c_db_folder);
        olaf.free(c_config);
    }

    const c_raw_audio_path = try allocator.dupeZ(u8, raw_audio_path);
    defer allocator.free(c_raw_audio_path);

    const c_audio_identifier = try allocator.dupeZ(u8, audio_identifier);
    defer allocator.free(c_audio_identifier);

    std.debug.print("Opening FILE* for output file path: {s}\n", .{output_file_path});

    const c_output_path = try allocator.dupeZ(u8, output_file_path);
    defer allocator.free(c_output_path);

    const c_file = olaf.fopen(c_output_path, "w");
    if (c_file == null) return error.FdopenFailed;

    olaf.olaf_print_to_file(c_config, c_raw_audio_path, c_audio_identifier, c_file);
}

pub fn olaf_name_to_id(allocator: std.mem.Allocator, audio_identifier: []const u8) !u32 {
    const c_audio_identifier = try allocator.dupeZ(u8, audio_identifier);
    defer allocator.free(c_audio_identifier);

    return olaf.olaf_name_to_id(c_audio_identifier);
}

pub fn olaf_store_cached_files(allocator: std.mem.Allocator, cache_files: []const []const u8, config: *const olaf_cli_config.Config) !void {
    const c_config = olaf.olaf_default_config();
    try copy_to_c_config(config, c_config);

    // Path configuration
    const c_db_folder = try allocator.dupeZ(u8, config.db_folder);
    c_config.*.dbFolder = c_db_folder;
    defer allocator.free(c_db_folder);

    // Open database
    const db = olaf.olaf_db_new(c_db_folder, false);
    defer olaf.olaf_db_destroy(db);

    // Process each cache file
    for (cache_files) |cache_file| {
        const c_cache_file = try allocator.dupeZ(u8, cache_file);
        defer allocator.free(c_cache_file);

        const cache_writer = olaf.olaf_fp_db_writer_cache_new(db, c_config, c_cache_file);
        olaf.olaf_fp_db_writer_cache_store(cache_writer);
        olaf.olaf_fp_db_writer_cache_destroy(cache_writer);
    }

    olaf.olaf_config_destroy(c_config);
}

pub fn olaf_has(allocator: std.mem.Allocator, audio_identifiers: []const []const u8, config: *const olaf_cli_config.Config) ![]bool {
    const c_config = olaf.olaf_default_config();
    try copy_to_c_config(config, c_config);

    // Path configuration
    const c_db_folder = try allocator.dupeZ(u8, config.db_folder);
    c_config.*.dbFolder = c_db_folder;
    defer allocator.free(c_db_folder);

    // Convert audio identifiers to C strings
    var c_audio_identifiers = try allocator.alloc([*c]const u8, audio_identifiers.len);
    defer allocator.free(c_audio_identifiers);

    var c_strings = try allocator.alloc([]const u8, audio_identifiers.len);
    defer {
        for (c_strings) |c_str| {
            allocator.free(c_str);
        }
        allocator.free(c_strings);
    }

    for (audio_identifiers, 0..) |id, i| {
        c_strings[i] = try allocator.dupeZ(u8, id);
        c_audio_identifiers[i] = c_strings[i].ptr;
    }

    // Allocate result array
    const has_audio_identifier = try allocator.alloc(bool, audio_identifiers.len);
    errdefer allocator.free(has_audio_identifier);

    // Call C function
    olaf.olaf_has(c_config, audio_identifiers.len, c_audio_identifiers.ptr, @ptrCast(has_audio_identifier.ptr));

    olaf.olaf_config_destroy(c_config);

    return has_audio_identifier;
}
