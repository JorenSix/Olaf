const std = @import("std");
const json = std.json;

const debug = std.log.scoped(.olaf_wrapper).debug;

pub const Config = struct {
    db_folder: []const u8 = "~/.olaf/db",
    cache_folder: []const u8 = "~/.olaf/cache",
    check_incoming_audio: bool = true,
    skip_duplicates: bool = true,
    fragment_duration_in_seconds: u32 = 30,
    target_sample_rate: u32 = 16000,
    allowed_audio_file_extensions: []const []const u8 = &.{
        ".m4a", ".wav", ".mp4", ".wv", ".ape", ".ogg", ".mp3", ".raw", ".flac", ".wma",
    },

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
        // free any other heap fields here
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
            debug(".   {s}", .{ext});
        }
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

        if (obj.get("db_folder")) |val| {
            if (val == .string) {
                config.db_folder = try allocator.dupe(u8, val.string);
            } else {
                config.db_folder = try allocator.dupe(u8, config.db_folder);
            }
        }

        if (obj.get("cache_folder")) |val| {
            if (val == .string) {
                config.cache_folder = try allocator.dupe(u8, val.string);
            } else {
                config.cache_folder = try allocator.dupe(u8, config.cache_folder);
            }
        }

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
        }

        if (obj.get("check_incoming_audio")) |val| {
            if (val == .bool)
                config.check_incoming_audio = val.bool;
        }

        if (obj.get("skip_duplicates")) |val| {
            if (val == .bool)
                config.skip_duplicates = val.bool;
        }

        if (obj.get("fragment_duration_in_seconds")) |val| {
            if (val == .integer)
                config.fragment_duration_in_seconds = @intCast(val.integer);
        }

        if (obj.get("target_sample_rate")) |val| {
            if (val == .integer)
                config.target_sample_rate = @intCast(val.integer);
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
    const config = try olafWrapperConfig(allocator);

    std.debug.print("DB folder: {s}\n", .{config.db_folder});
    std.debug.print("Extensions: ", .{});
    for (config.allowed_audio_file_extensions) |ext| {
        std.debug.print("{s} ", .{ext});
    }
    std.debug.print("\n", .{});
}
