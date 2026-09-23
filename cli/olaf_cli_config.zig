const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const json = std.json;
const olaf_cli_util = @import("olaf_cli_util.zig");

const debug = std.log.scoped(.olaf_cli).debug;

const IntFieldError = error{ IntOutOfRange, NotAnInteger };

/// Convert a JSON value to integer type `T`, rejecting other JSON types and
/// values outside `T`'s range (which `@intCast` would turn into a panic/UB).
fn castInt(comptime T: type, val: std.json.Value) IntFieldError!T {
    return switch (val) {
        .integer => |v| std.math.cast(T, v) orelse error.IntOutOfRange,
        else => error.NotAnInteger,
    };
}

/// Read an integer JSON field, coercing to `T`. Returns `cur` when the key is
/// absent; an invalid value is a config error rather than a silent fallback.
fn getInt(obj: std.json.ObjectMap, key: []const u8, comptime T: type, cur: T) !T {
    const val = obj.get(key) orelse return cur;
    return castInt(T, val) catch |err| {
        switch (err) {
            error.IntOutOfRange => std.log.err("config: '{s}' = {d} is out of range ({d}..{d})", .{ key, val.integer, std.math.minInt(T), std.math.maxInt(T) }),
            error.NotAnInteger => std.log.err("config: '{s}' must be an integer", .{key}),
        }
        return error.InvalidConfigValue;
    };
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
    // Microphone input configurations (used by the `microphone` command): the
    // ffmpeg input format and device of the platform's default microphone
    // (avfoundation on macOS, ALSA on Linux, DirectShow elsewhere). Override
    // them in the config file for another device or backend (e.g. "pulse").
    microphone_input_format: []const u8 = switch (builtin.os.tag) {
        .macos => "avfoundation",
        .linux => "alsa",
        else => "dshow",
    },
    microphone_device: []const u8 = switch (builtin.os.tag) {
        .macos => ":default",
        .linux => "default",
        else => "audio=default",
    },

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

    /// Owns every string of a loaded config (null for a `Config{}` literal).
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self.arena) |*a| a.deinit();
        self.arena = null;
    }

    /// Print every setting as "  name: value" (lists one entry per line).
    fn writeSettings(self: *const Config, w: *Io.Writer) !void {
        if (self.config_path) |p| {
            try w.print("Config file: {s}\n", .{p});
        } else {
            try w.print("Config file: <defaults — no config file found>\n", .{});
        }
        try w.writeAll("Current Config:\n");
        inline for (std.meta.fields(Config)) |field| {
            if (comptime isSetting(field.name)) {
                const value = @field(self, field.name);
                switch (field.type) {
                    []const u8 => try w.print("  {s}: {s}\n", .{ field.name, value }),
                    []const []const u8 => {
                        try w.print("  {s}:\n", .{field.name});
                        for (value) |item| try w.print("    {s}\n", .{item});
                    },
                    f32 => try w.print("  {s}: {d}\n", .{ field.name, value }),
                    else => try w.print("  {s}: {}\n", .{ field.name, value }),
                }
            }
        }
    }

    pub fn debugPrint(self: *const Config) void {
        var buf: [8192]u8 = undefined;
        var w = Io.Writer.fixed(&buf);
        self.writeSettings(&w) catch {};
        debug("{s}", .{w.buffered()});
    }

    pub fn infoPrint(self: *const Config) !void {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = Io.File.stdout().writerStreaming(olaf_cli_util.defaultIo(), &stdout_buffer);
        try self.writeSettings(&stdout_writer.interface);
        try stdout_writer.interface.flush();
    }
};

/// Config fields that are settings (read from JSON and printed), as opposed
/// to bookkeeping about where the config came from.
fn isSetting(comptime name: []const u8) bool {
    return !std.mem.eql(u8, name, "config_path") and !std.mem.eql(u8, name, "home") and !std.mem.eql(u8, name, "arena");
}

/// The value of setting `name` from the JSON object (`obj` null: no config
/// file), or its default `cur`. Strings are always copied into `a`, so a
/// loaded config owns all of them. A present integer that is out of range or
/// not an integer is an error; other wrong types fall back to the default.
fn loadField(comptime T: type, a: std.mem.Allocator, obj: ?std.json.ObjectMap, name: []const u8, cur: T) !T {
    const val: ?std.json.Value = if (obj) |o| o.get(name) else null;
    switch (T) {
        []const u8 => return a.dupe(u8, if (val) |v| (if (v == .string) v.string else cur) else cur),
        []const []const u8 => {
            if (val) |v| if (v == .array) {
                const list = try a.alloc([]const u8, v.array.items.len);
                for (v.array.items, list) |item, *dst| {
                    if (item != .string) return error.InvalidAudioExtension;
                    dst.* = try a.dupe(u8, item.string);
                }
                return list;
            };
            const list = try a.alloc([]const u8, cur.len);
            for (cur, list) |item, *dst| dst.* = try a.dupe(u8, item);
            return list;
        },
        bool => return if (val) |v| (if (v == .bool) v.bool else cur) else cur,
        // A float setting also accepts an integer literal like `4`.
        f32 => return if (val) |v| switch (v) {
            .float => @floatCast(v.float),
            .integer => @floatFromInt(v.integer),
            else => cur,
        } else cur,
        else => return if (obj) |o| getInt(o, name, T, cur) else cur,
    }
}

/// Reads a JSON config file from the given `path`; a missing file means all
/// defaults. Every setting absent from the file keeps its default. db_folder
/// and cache_folder have "~/" expanded, and db_folder always ends in '/'
/// (the C core and "{db_folder}data.mdb" lookups need it). Returns an error
/// if the JSON is invalid or the file cannot be read.
pub fn readJsonConfigOrDefault(allocator: std.mem.Allocator, io: Io, home: ?[]const u8, path: []const u8) !Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var config = Config{};
    config.home = if (home) |h| try a.dupe(u8, h) else null;

    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |p| p.deinit();

    if (Io.Dir.cwd().openFile(io, path, .{})) |file| {
        defer file.close(io);

        // Record the absolute path of the file actually loaded to show it later.
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_len = Io.Dir.cwd().realPathFile(io, path, &abs_buf) catch null;
        config.config_path = try a.dupe(u8, if (abs_len) |n| abs_buf[0..n] else path);

        var read_buf: [16 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &read_buf);
        const contents = try file_reader.interface.allocRemaining(a, .limited(10 * 1024));
        parsed = try json.parseFromSlice(json.Value, allocator, contents, .{});
        if (parsed.?.value != .object) return error.InvalidJson;
    } else |err| switch (err) {
        error.FileNotFound => debug("No config file found at \"{s}\" — using defaults.", .{path}),
        else => return err,
    }

    const obj: ?std.json.ObjectMap = if (parsed) |p| p.value.object else null;
    inline for (std.meta.fields(Config)) |field| {
        if (comptime isSetting(field.name)) {
            @field(config, field.name) = try loadField(field.type, a, obj, field.name, @field(config, field.name));
        }
    }
    config.db_folder = try olaf_cli_util.ensureTrailingSlash(a, try olaf_cli_util.expandPath(a, config.home, config.db_folder));
    config.cache_folder = try olaf_cli_util.expandPath(a, config.home, config.cache_folder);

    config.arena = arena;
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

test "castInt / getInt: range and type checks" {
    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator,
        \\{"neg":-1,"big":4294967296,"float":2.5,"str":"50","ok":7}
    , .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqual(@as(u32, 7), try getInt(obj, "ok", u32, 5));
    try std.testing.expectEqual(@as(u32, 5), try getInt(obj, "missing", u32, 5));
    // castInt carries the same checks as getInt without logging (the test
    // runner fails any test that emits log.err).
    try std.testing.expectError(error.IntOutOfRange, castInt(u32, obj.get("neg").?));
    try std.testing.expectError(error.IntOutOfRange, castInt(u32, obj.get("big").?));
    try std.testing.expectError(error.NotAnInteger, castInt(u32, obj.get("float").?));
    try std.testing.expectError(error.NotAnInteger, castInt(u32, obj.get("str").?));
}

test "readJsonConfigOrDefault loads every setting" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const defaults = Config{};

    // A JSON object giving every setting a non-default value.
    var json_out: Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();
    const w = &json_out.writer;
    try w.writeAll("{");
    var first = true;
    inline for (std.meta.fields(Config)) |field| {
        if (comptime isSetting(field.name)) {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("\"{s}\":", .{field.name});
            const d = @field(defaults, field.name);
            switch (field.type) {
                []const u8 => try w.print("\"/x/{s}\"", .{field.name}),
                []const []const u8 => try w.writeAll("[\".x1\",\".x2\"]"),
                bool => try w.print("{}", .{!d}),
                f32 => try w.print("{d}", .{d + 0.5}),
                else => try w.print("{d}", .{d + 1}),
            }
        }
    }
    try w.writeAll("}");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/olaf_config.json", .{dir});
    defer allocator.free(path);
    {
        const f = try Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, json_out.written());
    }

    var config = try readJsonConfigOrDefault(allocator, io, null, path);
    defer config.deinit();

    inline for (std.meta.fields(Config)) |field| {
        if (comptime isSetting(field.name)) {
            const got = @field(config, field.name);
            const d = @field(defaults, field.name);
            switch (field.type) {
                []const u8 => {
                    // db_folder is normalized to end in '/'.
                    const want = if (comptime std.mem.eql(u8, field.name, "db_folder")) "/x/db_folder/" else "/x/" ++ field.name;
                    try std.testing.expectEqualStrings(want, got);
                },
                []const []const u8 => {
                    try std.testing.expectEqual(@as(usize, 2), got.len);
                    try std.testing.expectEqualStrings(".x2", got[1]);
                },
                bool => try std.testing.expectEqual(!d, got),
                f32 => try std.testing.expectEqual(d + 0.5, got),
                else => try std.testing.expectEqual(d + 1, got),
            }
        }
    }
}
