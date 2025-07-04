const std = @import("std");
const json = std.json;

pub const Config = struct {
    db_folder: []const u8 = "~/.olaf/db",
    cache_folder: []const u8 = "~/.olaf/cache",
    executable_location: []const u8 = "./olaf_c",
    check_incoming_audio: bool = true,
    skip_duplicates: bool = true,
    fragment_duration_in_seconds: u32 = 30,
    target_sample_rate: u32 = 16000,
    allowed_audio_file_extensions: []const []const u8 = &.{
        ".m4a", ".wav", ".mp4", ".wv", ".ape", ".ogg", ".mp3", ".raw", ".flac", ".wma",
    },

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.db_folder);
        //allocator.free(self.cache_folder);
        for (self.allowed_audio_file_extensions) |ext| {
            allocator.free(ext);
        }
        allocator.free(self.allowed_audio_file_extensions);
        // free any other heap fields here
    }
};

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
            if (val == .string)
                config.db_folder = try allocator.dupe(u8, val.string);
        }

        if (obj.get("cache_folder")) |val| {
            if (val == .string)
                config.cache_folder = try allocator.dupe(u8, val.string);
        }

        if (obj.get("executable_location")) |val| {
            if (val == .string)
                config.executable_location = try allocator.dupe(u8, val.string);
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

        if (obj.get("allowed_audio_file_extensions")) |val| {
            if (val == .array) {
                const arr = val.array;
                const ext_list = try allocator.alloc([]const u8, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    if (item != .string) return error.InvalidAudioExtension;
                    ext_list[i] = try allocator.dupe(u8, item.string);
                }
                config.allowed_audio_file_extensions = ext_list;
            }
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("No config file found at \"{s}\" — using defaults.\n", .{path});
        },
        else => return err,
    }

    return config;
}

/// Attempts to load config from ~/.olaf/olaf_config.json, then from olaf_config.json in the executable's directory.
/// Returns the config and the path used, or an error if neither is found.
pub fn olafWrapperConfig(allocator: std.mem.Allocator) !Config {
    // 1. Try ~/.olaf/olaf_config.json
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;

    if (home) |h| {
        defer allocator.free(h); // <-- Free HOME after use
        const config_path1 = try std.fmt.bufPrint(&home_buf, "{s}/.olaf/olaf_wrapper_config.json", .{h});
        if (std.fs.cwd().openFile(config_path1, .{})) |file| {
            file.close();
            return try readJsonConfigOrDefault(allocator, config_path1);
        } else |_| {}
    }

    // 2. Try olaf_config.json in the executable's directory
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&exe_path_buf);
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
    var config_path2_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path2 = try std.fmt.bufPrint(&config_path2_buf, "{s}/olaf_wrapper_config.json", .{exe_dir});
    if (std.fs.cwd().openFile(config_path2, .{})) |file| {
        file.close();
        return try readJsonConfigOrDefault(allocator, config_path2);
    } else |_| {}

    // Not found, return default config
    return Config{};
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
