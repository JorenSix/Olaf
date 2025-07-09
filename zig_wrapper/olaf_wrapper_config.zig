const std = @import("std");
const json = std.json;

const debug = std.log.scoped(.olaf_wrapper).debug;

pub const Config = struct {
    // Path configurations
    db_folder: []const u8 = "~/.olaf/db/",
    cache_folder: []const u8 = "~/.olaf/cache",

    // Wrapper specific configurations
    check_incoming_audio: bool = true,
    skip_duplicates: bool = true,
    fragment_duration_in_seconds: u32 = 30,
    target_sample_rate: u32 = 16000,
    allowed_audio_file_extensions: []const []const u8 = &.{
        ".m4a", ".wav", ".mp4", ".wv", ".ape", ".ogg", ".mp3", ".raw", ".flac", ".wma",
    },

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

        debug("Free cache_folder cleanup", .{});
        allocator.free(self.cache_folder);

        debug("Free db_folder cleanup", .{});
        allocator.free(self.db_folder);

        debug("Free allowed_audio_file_extensions cleanup", .{});
        for (self.allowed_audio_file_extensions) |ext| {
            debug("Free allowed_audio_file_extension '{s}'", .{ext});
            allocator.free(ext);
        }

        debug("Free allowed_audio_file_extensions cleanup", .{});
        allocator.free(self.allowed_audio_file_extensions);
    }

    pub fn debugPrint(self: *const Config) void {
        debug("Current Config:", .{});
        debug("  db_folder: {s}", .{self.db_folder});
        debug("  cache_folder: {s}", .{self.cache_folder});
        debug("  check_incoming_audio: {}", .{self.check_incoming_audio});
        debug("  skip_duplicates: {}", .{self.skip_duplicates});
        debug("  fragment_duration_in_seconds: {}", .{self.fragment_duration_in_seconds});
        debug("  target_sample_rate: {}", .{self.target_sample_rate});
        debug("  allowed_audio_file_extensions: ", .{});
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
};

/// Reads a JSON config file from the given `path`, returning a Config struct.
/// If the config keys are not present or invalid, it uses default values.
/// Every string is duplicated to ensure memory safety. Even if the defaults are used, they are duplicated to avoid dangling memory issues.
/// Returns an error if the JSON is invalid or if the file cannot be read.
pub fn readJsonConfigOrDefault(allocator: std.mem.Allocator, path: []const u8) !Config {
    var config = Config{}; // start with defaults

    const file_result = std.fs.cwd().openFile(path, .{});

    if (file_result) |file| {
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 10 * 1024);
        defer allocator.free(contents);

        const parsed = try json.parseFromSlice(json.Value, allocator, contents, .{});
        defer parsed.deinit();

        const value = parsed.value;
        if (value != .object) return error.InvalidJson;

        const obj = value.object;

        // String fields
        if (obj.get("db_folder")) |val| {
            if (val == .string) {
                config.db_folder = try allocator.dupe(u8, val.string);
            } else {
                config.db_folder = try allocator.dupe(u8, config.db_folder);
            }
        } else {
            config.db_folder = try allocator.dupe(u8, config.db_folder);
        }

        if (obj.get("cache_folder")) |val| {
            if (val == .string) {
                config.cache_folder = try allocator.dupe(u8, val.string);
            } else {
                config.cache_folder = try allocator.dupe(u8, config.cache_folder);
            }
        } else {
            config.cache_folder = try allocator.dupe(u8, config.cache_folder);
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
        if (obj.get("check_incoming_audio")) |val| {
            if (val == .bool) config.check_incoming_audio = val.bool;
        }
        if (obj.get("skip_duplicates")) |val| {
            if (val == .bool) config.skip_duplicates = val.bool;
        }
        if (obj.get("sqrt_magnitude")) |val| {
            if (val == .bool) config.sqrt_magnitude = val.bool;
        }
        if (obj.get("verbose")) |val| {
            if (val == .bool) config.verbose = val.bool;
        }
        if (obj.get("use_magnitude_info")) |val| {
            if (val == .bool) config.use_magnitude_info = val.bool;
        }

        // Integer fields
        if (obj.get("fragment_duration_in_seconds")) |val| {
            if (val == .integer) config.fragment_duration_in_seconds = @intCast(val.integer);
        }
        if (obj.get("target_sample_rate")) |val| {
            if (val == .integer) config.target_sample_rate = @intCast(val.integer);
        }
        if (obj.get("audio_block_size")) |val| {
            if (val == .integer) config.audio_block_size = @intCast(val.integer);
        }
        if (obj.get("audio_step_size")) |val| {
            if (val == .integer) config.audio_step_size = @intCast(val.integer);
        }
        if (obj.get("bytes_per_audio_sample")) |val| {
            if (val == .integer) config.bytes_per_audio_sample = @intCast(val.integer);
        }
        if (obj.get("max_event_points")) |val| {
            if (val == .integer) config.max_event_points = @intCast(val.integer);
        }
        if (obj.get("event_point_threshold")) |val| {
            if (val == .integer) config.event_point_threshold = @intCast(val.integer);
        }
        if (obj.get("filter_size_frequency")) |val| {
            if (val == .integer) config.filter_size_frequency = @intCast(val.integer);
        }
        if (obj.get("filter_size_time")) |val| {
            if (val == .integer) config.filter_size_time = @intCast(val.integer);
        }
        if (obj.get("max_event_point_usages")) |val| {
            if (val == .integer) config.max_event_point_usages = @intCast(val.integer);
        }
        if (obj.get("min_frequency_bin")) |val| {
            if (val == .integer) config.min_frequency_bin = @intCast(val.integer);
        }
        if (obj.get("number_of_eps_per_fp")) |val| {
            if (val == .integer) config.number_of_eps_per_fp = @intCast(val.integer);
        }
        if (obj.get("min_time_distance")) |val| {
            if (val == .integer) config.min_time_distance = @intCast(val.integer);
        }
        if (obj.get("max_time_distance")) |val| {
            if (val == .integer) config.max_time_distance = @intCast(val.integer);
        }
        if (obj.get("min_freq_distance")) |val| {
            if (val == .integer) config.min_freq_distance = @intCast(val.integer);
        }
        if (obj.get("max_freq_distance")) |val| {
            if (val == .integer) config.max_freq_distance = @intCast(val.integer);
        }
        if (obj.get("max_fingerprints")) |val| {
            if (val == .integer) config.max_fingerprints = @intCast(val.integer);
        }
        if (obj.get("max_results")) |val| {
            if (val == .integer) config.max_results = @intCast(val.integer);
        }
        if (obj.get("search_range")) |val| {
            if (val == .integer) config.search_range = @intCast(val.integer);
        }
        if (obj.get("min_match_count")) |val| {
            if (val == .integer) config.min_match_count = @intCast(val.integer);
        }
        if (obj.get("max_db_collisions")) |val| {
            if (val == .integer) config.max_db_collisions = @intCast(val.integer);
        }

        // Float fields
        if (obj.get("min_event_point_magnitude")) |val| {
            if (val == .float) {
                config.min_event_point_magnitude = @floatCast(val.float);
            } else if (val == .integer) {
                config.min_event_point_magnitude = @floatFromInt(val.integer);
            }
        }
        if (obj.get("min_match_time_diff")) |val| {
            if (val == .float) {
                config.min_match_time_diff = @floatCast(val.float);
            } else if (val == .integer) {
                config.min_match_time_diff = @floatFromInt(val.integer);
            }
        }
        if (obj.get("keep_matches_for")) |val| {
            if (val == .float) {
                config.keep_matches_for = @floatCast(val.float);
            } else if (val == .integer) {
                config.keep_matches_for = @floatFromInt(val.integer);
            }
        }
        if (obj.get("print_result_every")) |val| {
            if (val == .float) {
                config.print_result_every = @floatCast(val.float);
            } else if (val == .integer) {
                config.print_result_every = @floatFromInt(val.integer);
            }
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            debug("No config file found at \"{s}\" — using defaults.\n", .{path});

            // to keep the config memory use consistent, we dupe the default values
            config.db_folder = try allocator.dupe(u8, config.db_folder);
            config.cache_folder = try allocator.dupe(u8, config.cache_folder);
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

/// Attempts to load config from ~/.olaf/olaf_wrapper_config.json, then from olaf_config.json in the executable's directory.
/// Returns the config and the path used, or an error if neither is found.
pub fn olafWrapperConfig(allocator: std.mem.Allocator) !Config {
    // 1. Try ~/.olaf/olaf_config.json
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;

    if (home) |h| {
        defer allocator.free(h);
        const config_home_dir = try std.fmt.bufPrint(&home_buf, "{s}/.olaf/olaf_wrapper_config.json", .{h});

        if (std.fs.cwd().openFile(config_home_dir, .{})) |file| {
            file.close();

            debug("Config: found config at: {s}", .{config_home_dir});
            return try readJsonConfigOrDefault(allocator, config_home_dir);
        } else |err| switch (err) {
            error.FileNotFound => {
                debug("Config: No config in home dir: {s}", .{config_home_dir});
            },
            else => return err, // Propagate other errors
        }
    }

    // 2. Try olaf_config.json in the executable's directory
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&exe_path_buf);
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
    var config_path2_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_exe_dir = try std.fmt.bufPrint(&config_path2_buf, "{s}/olaf_wrapper_config.json", .{exe_dir});
    debug("Try reading config at: {s}", .{config_exe_dir});
    return try readJsonConfigOrDefault(allocator, config_exe_dir);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var config = try olafWrapperConfig(allocator);
    defer config.deinit(allocator);

    config.debugPrint();
}
