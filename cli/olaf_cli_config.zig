const std = @import("std");
const Io = std.Io;
const json = std.json;
const olaf_cli_util = @import("olaf_cli_util.zig");

const debug = std.log.scoped(.olaf_cli).debug;

/// Read an integer JSON field, coercing to `T`. Returns `cur` when the key is
/// absent or not a JSON integer.
fn getInt(obj: std.json.ObjectMap, key: []const u8, comptime T: type, cur: T) T {
    if (obj.get(key)) |val| {
        if (val == .integer) return @intCast(val.integer);
    }
    return cur;
}

/// Read a boolean JSON field. Returns `cur` when absent or not a JSON bool.
fn getBool(obj: std.json.ObjectMap, key: []const u8, cur: bool) bool {
    if (obj.get(key)) |val| {
        if (val == .bool) return val.bool;
    }
    return cur;
}

/// Read a float JSON field, coercing to `T`. Accepts both JSON float and
/// integer values (an integer literal like `4` is a valid float config value).
/// Returns `cur` when absent or neither numeric tag.
fn getFloat(obj: std.json.ObjectMap, key: []const u8, comptime T: type, cur: T) T {
    if (obj.get(key)) |val| {
        if (val == .float) return @floatCast(val.float);
        if (val == .integer) return @floatFromInt(val.integer);
    }
    return cur;
}

pub const Config = struct {
    // Absolute path of the config file actually loaded, or null when defaults are used.
    config_path: ?[]const u8 = null,

    // Resolved value of $HOME (owned, dup'd), captured once at config load so
    // path expansion ("~/...") works without global env access (removed in 0.16).
    // Null when HOME is unset. Borrowed by expandPath callers; freed in deinit.
    home: ?[]const u8 = null,

    // Path configurations
    db_folder: []const u8 = "~/.olaf/db/",
    cache_folder: []const u8 = "~/.olaf/cache",

    // CLI specific configurations
    check_incoming_audio: bool = true,
    skip_duplicates: bool = true,
    fragment_duration_in_seconds: u32 = 30,
    target_sample_rate: u32 = 16000,
    allowed_audio_file_extensions: []const []const u8 = &.{
        ".m4a", ".wav", ".mp4", ".wv", ".ape", ".ogg", ".mp3", ".raw", ".flac", ".wma",
    },

    // Microphone input configurations (used by the `microphone` command).
    // The default targets the macOS CoreAudio default microphone via ffmpeg's
    // avfoundation input. On other platforms override these in the config file
    // (e.g. "alsa" / "default" on Linux).
    microphone_input_format: []const u8 = "avfoundation",
    microphone_device: []const u8 = ":default",

    // Audio configurations
    audio_block_size: u32 = 1024,
    audio_step_size: u32 = 128,
    bytes_per_audio_sample: u32 = 4,

    // Event point configurations
    max_event_points: u32 = 60,
    event_point_threshold: u32 = 30,
    sqrt_magnitude: bool = false,
    filter_size_frequency: u32 = 103,
    filter_size_time: u32 = 24,
    min_event_point_magnitude: f32 = 0.001,
    max_event_point_usages: u32 = 10,
    min_frequency_bin: u32 = 9,

    // Debug configuration
    verbose: bool = false,

    // Fingerprint configurations
    number_of_eps_per_fp: u32 = 3,
    use_magnitude_info: bool = false,
    min_time_distance: u32 = 2,
    max_time_distance: u32 = 33,
    min_freq_distance: u32 = 1,
    max_freq_distance: u32 = 128,
    max_fingerprints: u32 = 300,

    // Matcher configurations
    max_results: u32 = 50,
    search_range: u32 = 5,
    min_match_count: u32 = 6,
    min_match_time_diff: f32 = 0,
    keep_matches_for: f32 = 0,
    print_result_every: f32 = 0,
    max_db_collisions: u32 = 2000,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        debug("Config deinit", .{});

        if (self.config_path) |p| {
            debug("Free config_path cleanup", .{});
            allocator.free(p);
        }

        if (self.home) |h| {
            debug("Free home cleanup", .{});
            allocator.free(h);
        }

        debug("Free cache_folder cleanup", .{});
        allocator.free(self.cache_folder);

        debug("Free db_folder cleanup", .{});
        allocator.free(self.db_folder);

        debug("Free microphone settings cleanup", .{});
        allocator.free(self.microphone_input_format);
        allocator.free(self.microphone_device);

        debug("Free allowed_audio_file_extensions cleanup", .{});
        for (self.allowed_audio_file_extensions) |ext| {
            debug("Free allowed_audio_file_extension '{s}'", .{ext});
            allocator.free(ext);
        }

        debug("Free allowed_audio_file_extensions cleanup", .{});
        allocator.free(self.allowed_audio_file_extensions);
    }

    fn printConfigToWriter(self: *const Config, writer: anytype) !void {
        if (self.config_path) |p| {
            try writer.print("Config file: {s}\n", .{p});
        } else {
            try writer.print("Config file: <defaults — no config file found>\n", .{});
        }
        try writer.print("Current Config:\n", .{});
        try writer.print("  db_folder: {s}\n", .{self.db_folder});
        try writer.print("  cache_folder: {s}\n", .{self.cache_folder});
        try writer.print("  check_incoming_audio: {}\n", .{self.check_incoming_audio});
        try writer.print("  skip_duplicates: {}\n", .{self.skip_duplicates});
        try writer.print("  fragment_duration_in_seconds: {}\n", .{self.fragment_duration_in_seconds});
        try writer.print("  target_sample_rate: {}\n", .{self.target_sample_rate});
        try writer.print("  microphone_input_format: {s}\n", .{self.microphone_input_format});
        try writer.print("  microphone_device: {s}\n", .{self.microphone_device});
        try writer.print("  allowed_audio_file_extensions:\n", .{});
        for (self.allowed_audio_file_extensions) |ext| {
            try writer.print("    {s}\n", .{ext});
        }
        try writer.print("  audio_block_size: {}\n", .{self.audio_block_size});
        try writer.print("  audio_step_size: {}\n", .{self.audio_step_size});
        try writer.print("  bytes_per_audio_sample: {}\n", .{self.bytes_per_audio_sample});
        try writer.print("  max_event_points: {}\n", .{self.max_event_points});
        try writer.print("  event_point_threshold: {}\n", .{self.event_point_threshold});
        try writer.print("  sqrt_magnitude: {}\n", .{self.sqrt_magnitude});
        try writer.print("  filter_size_frequency: {}\n", .{self.filter_size_frequency});
        try writer.print("  filter_size_time: {}\n", .{self.filter_size_time});
        try writer.print("  min_event_point_magnitude: {d}\n", .{self.min_event_point_magnitude});
        try writer.print("  max_event_point_usages: {}\n", .{self.max_event_point_usages});
        try writer.print("  min_frequency_bin: {}\n", .{self.min_frequency_bin});
        try writer.print("  verbose: {}\n", .{self.verbose});
        try writer.print("  number_of_eps_per_fp: {}\n", .{self.number_of_eps_per_fp});
        try writer.print("  use_magnitude_info: {}\n", .{self.use_magnitude_info});
        try writer.print("  min_time_distance: {}\n", .{self.min_time_distance});
        try writer.print("  max_time_distance: {}\n", .{self.max_time_distance});
        try writer.print("  min_freq_distance: {}\n", .{self.min_freq_distance});
        try writer.print("  max_freq_distance: {}\n", .{self.max_freq_distance});
        try writer.print("  max_fingerprints: {}\n", .{self.max_fingerprints});
        try writer.print("  max_results: {}\n", .{self.max_results});
        try writer.print("  search_range: {}\n", .{self.search_range});
        try writer.print("  min_match_count: {}\n", .{self.min_match_count});
        try writer.print("  min_match_time_diff: {d}\n", .{self.min_match_time_diff});
        try writer.print("  keep_matches_for: {d}\n", .{self.keep_matches_for});
        try writer.print("  print_result_every: {d}\n", .{self.print_result_every});
        try writer.print("  max_db_collisions: {}\n", .{self.max_db_collisions});
    }

    pub fn debugPrint(self: *const Config) void {
        if (self.config_path) |p| {
            debug("Config file: {s}", .{p});
        } else {
            debug("Config file: <defaults — no config file found>", .{});
        }
        debug("Current Config:", .{});
        debug("  db_folder: {s}", .{self.db_folder});
        debug("  cache_folder: {s}", .{self.cache_folder});
        debug("  check_incoming_audio: {}", .{self.check_incoming_audio});
        debug("  skip_duplicates: {}", .{self.skip_duplicates});
        debug("  fragment_duration_in_seconds: {}", .{self.fragment_duration_in_seconds});
        debug("  target_sample_rate: {}", .{self.target_sample_rate});
        debug("  microphone_input_format: {s}", .{self.microphone_input_format});
        debug("  microphone_device: {s}", .{self.microphone_device});
        debug("  allowed_audio_file_extensions:", .{});
        for (self.allowed_audio_file_extensions) |ext| {
            debug("    {s}", .{ext});
        }
        debug("  audio_block_size: {}", .{self.audio_block_size});
        debug("  audio_step_size: {}", .{self.audio_step_size});
        debug("  bytes_per_audio_sample: {}", .{self.bytes_per_audio_sample});
        debug("  max_event_points: {}", .{self.max_event_points});
        debug("  event_point_threshold: {}", .{self.event_point_threshold});
        debug("  sqrt_magnitude: {}", .{self.sqrt_magnitude});
        debug("  filter_size_frequency: {}", .{self.filter_size_frequency});
        debug("  filter_size_time: {}", .{self.filter_size_time});
        debug("  min_event_point_magnitude: {d}", .{self.min_event_point_magnitude});
        debug("  max_event_point_usages: {}", .{self.max_event_point_usages});
        debug("  min_frequency_bin: {}", .{self.min_frequency_bin});
        debug("  verbose: {}", .{self.verbose});
        debug("  number_of_eps_per_fp: {}", .{self.number_of_eps_per_fp});
        debug("  use_magnitude_info: {}", .{self.use_magnitude_info});
        debug("  min_time_distance: {}", .{self.min_time_distance});
        debug("  max_time_distance: {}", .{self.max_time_distance});
        debug("  min_freq_distance: {}", .{self.min_freq_distance});
        debug("  max_freq_distance: {}", .{self.max_freq_distance});
        debug("  max_fingerprints: {}", .{self.max_fingerprints});
        debug("  max_results: {}", .{self.max_results});
        debug("  search_range: {}", .{self.search_range});
        debug("  min_match_count: {}", .{self.min_match_count});
        debug("  min_match_time_diff: {d}", .{self.min_match_time_diff});
        debug("  keep_matches_for: {d}", .{self.keep_matches_for});
        debug("  print_result_every: {d}", .{self.print_result_every});
        debug("  max_db_collisions: {}", .{self.max_db_collisions});
    }

    pub fn infoPrint(self: *const Config) !void {
        const io = olaf_cli_util.defaultIo();
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
        const stdout = &stdout_writer.interface;
        try self.printConfigToWriter(stdout);
        try stdout.flush();
    }
};

/// Reads a JSON config file from the given `path`, returning a Config struct.
/// If the config keys are not present or invalid, it uses default values.
/// Every string is duplicated to ensure memory safety. Even if the defaults are used, they are duplicated to avoid dangling memory issues.
/// Returns an error if the JSON is invalid or if the file cannot be read.
pub fn readJsonConfigOrDefault(allocator: std.mem.Allocator, io: Io, home: ?[]const u8, path: []const u8) !Config {
    var config = Config{}; // start with defaults
    config.home = if (home) |h| try allocator.dupe(u8, h) else null;
    errdefer if (config.home) |h| allocator.free(h);

    const file_result = Io.Dir.cwd().openFile(io, path, .{});

    if (file_result) |file| {
        defer file.close(io);

        // Record the absolute path of the file actually loaded so we can show it later.
        // Dupe a non-sentinel slice so deinit's allocator.free length matches the
        // allocation (realPathFileAlloc returns a [:0]u8 of n+1 bytes, which would
        // mismatch a free of the n-length slice).
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (Io.Dir.cwd().realPathFile(io, path, &abs_buf)) |abs_len| {
            config.config_path = try allocator.dupe(u8, abs_buf[0..abs_len]);
        } else |_| {
            config.config_path = try allocator.dupe(u8, path);
        }
        errdefer if (config.config_path) |p| allocator.free(p);

        var read_buf: [16 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &read_buf);
        const contents = try file_reader.interface.allocRemaining(allocator, .limited(10 * 1024));
        defer allocator.free(contents);

        const parsed = try json.parseFromSlice(json.Value, allocator, contents, .{});
        defer parsed.deinit();

        const value = parsed.value;
        if (value != .object) return error.InvalidJson;

        const obj = value.object;

        // String fields
        var db_folder: []u8 = undefined;
        if (obj.get("db_folder")) |val| {
            if (val == .string) {
                db_folder = try allocator.dupe(u8, val.string);
            } else {
                db_folder = try allocator.dupe(u8, config.db_folder);
            }
        } else {
            db_folder = try allocator.dupe(u8, config.db_folder);
        }
        defer allocator.free(db_folder);
        config.db_folder = try olaf_cli_util.expandPath(allocator, config.home, db_folder);

        var cache_folder: []u8 = undefined;
        if (obj.get("cache_folder")) |val| {
            if (val == .string) {
                cache_folder = try allocator.dupe(u8, val.string);
            } else {
                cache_folder = try allocator.dupe(u8, config.cache_folder);
            }
        } else {
            cache_folder = try allocator.dupe(u8, config.cache_folder);
        }
        defer allocator.free(cache_folder);
        config.cache_folder = try olaf_cli_util.expandPath(allocator, config.home, cache_folder);

        // Microphone settings (plain strings, not paths — no expandPath).
        if (obj.get("microphone_input_format")) |val| {
            config.microphone_input_format = if (val == .string)
                try allocator.dupe(u8, val.string)
            else
                try allocator.dupe(u8, config.microphone_input_format);
        } else {
            config.microphone_input_format = try allocator.dupe(u8, config.microphone_input_format);
        }

        if (obj.get("microphone_device")) |val| {
            config.microphone_device = if (val == .string)
                try allocator.dupe(u8, val.string)
            else
                try allocator.dupe(u8, config.microphone_device);
        } else {
            config.microphone_device = try allocator.dupe(u8, config.microphone_device);
        }

        // Array field
        if (obj.get("allowed_audio_file_extensions")) |val| {
            if (val == .array) {
                const arr = val.array;
                const ext_list = try allocator.alloc([]const u8, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    if (item != .string) return error.InvalidAudioExtension;
                    ext_list[i] = try allocator.dupe(u8, item.string);
                }
                config.allowed_audio_file_extensions = ext_list;
            } else {
                const ext_list = try allocator.alloc([]const u8, config.allowed_audio_file_extensions.len);
                for (config.allowed_audio_file_extensions, 0..) |ext, i| {
                    ext_list[i] = try allocator.dupe(u8, ext);
                }
                config.allowed_audio_file_extensions = ext_list;
            }
        } else {
            const ext_list = try allocator.alloc([]const u8, config.allowed_audio_file_extensions.len);
            for (config.allowed_audio_file_extensions, 0..) |ext, i| {
                ext_list[i] = try allocator.dupe(u8, ext);
            }
            config.allowed_audio_file_extensions = ext_list;
        }

        // Boolean fields
        config.check_incoming_audio = getBool(obj, "check_incoming_audio", config.check_incoming_audio);
        config.skip_duplicates = getBool(obj, "skip_duplicates", config.skip_duplicates);
        config.sqrt_magnitude = getBool(obj, "sqrt_magnitude", config.sqrt_magnitude);
        config.verbose = getBool(obj, "verbose", config.verbose);
        config.use_magnitude_info = getBool(obj, "use_magnitude_info", config.use_magnitude_info);

        // Integer fields
        config.fragment_duration_in_seconds = getInt(obj, "fragment_duration_in_seconds", @TypeOf(config.fragment_duration_in_seconds), config.fragment_duration_in_seconds);
        config.target_sample_rate = getInt(obj, "target_sample_rate", @TypeOf(config.target_sample_rate), config.target_sample_rate);
        config.audio_block_size = getInt(obj, "audio_block_size", @TypeOf(config.audio_block_size), config.audio_block_size);
        config.audio_step_size = getInt(obj, "audio_step_size", @TypeOf(config.audio_step_size), config.audio_step_size);
        config.bytes_per_audio_sample = getInt(obj, "bytes_per_audio_sample", @TypeOf(config.bytes_per_audio_sample), config.bytes_per_audio_sample);
        config.max_event_points = getInt(obj, "max_event_points", @TypeOf(config.max_event_points), config.max_event_points);
        config.event_point_threshold = getInt(obj, "event_point_threshold", @TypeOf(config.event_point_threshold), config.event_point_threshold);
        config.filter_size_frequency = getInt(obj, "filter_size_frequency", @TypeOf(config.filter_size_frequency), config.filter_size_frequency);
        config.filter_size_time = getInt(obj, "filter_size_time", @TypeOf(config.filter_size_time), config.filter_size_time);
        config.max_event_point_usages = getInt(obj, "max_event_point_usages", @TypeOf(config.max_event_point_usages), config.max_event_point_usages);
        config.min_frequency_bin = getInt(obj, "min_frequency_bin", @TypeOf(config.min_frequency_bin), config.min_frequency_bin);
        config.number_of_eps_per_fp = getInt(obj, "number_of_eps_per_fp", @TypeOf(config.number_of_eps_per_fp), config.number_of_eps_per_fp);
        config.min_time_distance = getInt(obj, "min_time_distance", @TypeOf(config.min_time_distance), config.min_time_distance);
        config.max_time_distance = getInt(obj, "max_time_distance", @TypeOf(config.max_time_distance), config.max_time_distance);
        config.min_freq_distance = getInt(obj, "min_freq_distance", @TypeOf(config.min_freq_distance), config.min_freq_distance);
        config.max_freq_distance = getInt(obj, "max_freq_distance", @TypeOf(config.max_freq_distance), config.max_freq_distance);
        config.max_fingerprints = getInt(obj, "max_fingerprints", @TypeOf(config.max_fingerprints), config.max_fingerprints);
        config.max_results = getInt(obj, "max_results", @TypeOf(config.max_results), config.max_results);
        config.search_range = getInt(obj, "search_range", @TypeOf(config.search_range), config.search_range);
        config.min_match_count = getInt(obj, "min_match_count", @TypeOf(config.min_match_count), config.min_match_count);
        config.max_db_collisions = getInt(obj, "max_db_collisions", @TypeOf(config.max_db_collisions), config.max_db_collisions);

        // Float fields (accept JSON integer literals too)
        config.min_event_point_magnitude = getFloat(obj, "min_event_point_magnitude", @TypeOf(config.min_event_point_magnitude), config.min_event_point_magnitude);
        config.min_match_time_diff = getFloat(obj, "min_match_time_diff", @TypeOf(config.min_match_time_diff), config.min_match_time_diff);
        config.keep_matches_for = getFloat(obj, "keep_matches_for", @TypeOf(config.keep_matches_for), config.keep_matches_for);
        config.print_result_every = getFloat(obj, "print_result_every", @TypeOf(config.print_result_every), config.print_result_every);
    } else |err| switch (err) {
        error.FileNotFound => {
            debug("No config file found at \"{s}\" — using defaults.\n", .{path});

            // to keep the config memory use consistent, we dupe the default values.
            // db/cache folders are expanded (~/ -> $HOME) like the file-present
            // branch so the C layer receives an absolute path, not a literal "~".
            config.db_folder = try olaf_cli_util.expandPath(allocator, config.home, config.db_folder);
            config.cache_folder = try olaf_cli_util.expandPath(allocator, config.home, config.cache_folder);
            config.microphone_input_format = try allocator.dupe(u8, config.microphone_input_format);
            config.microphone_device = try allocator.dupe(u8, config.microphone_device);
            const ext_list = try allocator.alloc([]const u8, config.allowed_audio_file_extensions.len);
            for (config.allowed_audio_file_extensions, 0..) |ext, i| {
                ext_list[i] = try allocator.dupe(u8, ext);
            }
            config.allowed_audio_file_extensions = ext_list;
        },
        else => return err,
    }

    return config;
}

/// Attempts to load config from ~/.olaf/olaf_config.json, then from olaf_config.json in the executable's directory.
/// `home` is the resolved $HOME value (or null), captured by the caller from
/// the process environment (no longer globally accessible in 0.16).
/// Returns the config and the path used, or an error if neither is found.
pub fn olafWrapperConfig(allocator: std.mem.Allocator, io: Io, home: ?[]const u8) !Config {
    // 1. Try ~/.olaf/olaf_config.json
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (home) |h| {
        const config_home_dir = try std.fmt.bufPrint(&home_buf, "{s}/.olaf/olaf_config.json", .{h});

        if (Io.Dir.cwd().openFile(io, config_home_dir, .{})) |file| {
            file.close(io);

            debug("Config: found config at: {s}", .{config_home_dir});
            return try readJsonConfigOrDefault(allocator, io, home, config_home_dir);
        } else |err| switch (err) {
            error.FileNotFound => {
                debug("Config: No config in home dir: {s}", .{config_home_dir});
            },
            else => return err, // Propagate other errors
        }
    }

    // 2. Try olaf_config.json in the executable's directory
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path_len = try std.process.executablePath(io, &exe_path_buf);
    const exe_path = exe_path_buf[0..exe_path_len];
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
    var config_path2_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_exe_dir = try std.fmt.bufPrint(&config_path2_buf, "{s}/olaf_config.json", .{exe_dir});
    debug("Try reading config at: {s}", .{config_exe_dir});
    return try readJsonConfigOrDefault(allocator, io, home, config_exe_dir);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var config = try olafWrapperConfig(allocator, io, null);
    defer config.deinit(allocator);

    config.debugPrint();
}
