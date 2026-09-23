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
    /// Reserved: currently has no effect (kept so existing configs stay valid).
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

/// The JSON type a setting of type `T` must have, for error messages.
fn expectedJsonType(comptime T: type) []const u8 {
    return switch (T) {
        []const u8 => "string",
        []const []const u8 => "list of strings",
        bool => "boolean",
        f32 => "number",
        else => "integer",
    };
}

/// Whether `v` has the JSON type a setting of type `T` needs (integer range
/// checks are separate, see castInt). A float setting also accepts an
/// integer literal like `4`.
fn hasSettingType(comptime T: type, v: std.json.Value) bool {
    return switch (T) {
        []const u8 => v == .string,
        []const []const u8 => v == .array and for (v.array.items) |item| {
            if (item != .string) break false;
        } else true,
        bool => v == .bool,
        f32 => v == .float or v == .integer,
        else => v == .integer,
    };
}

/// The value of setting `name` from the JSON object (`obj` null: no config
/// file), or its default `cur`. Strings are always copied into `a`, so a
/// loaded config owns all of them. A present value of the wrong JSON type,
/// or an integer out of range, is a config error rather than a silent
/// fallback to the default.
fn loadField(comptime T: type, a: std.mem.Allocator, obj: ?std.json.ObjectMap, comptime name: []const u8, cur: T) !T {
    const val: ?std.json.Value = if (obj) |o| o.get(name) else null;
    if (val) |v| if (!hasSettingType(T, v)) {
        std.log.err("config: '{s}' must be a {s}", .{ name, expectedJsonType(T) });
        return error.InvalidConfigValue;
    };
    switch (T) {
        []const u8 => return a.dupe(u8, if (val) |v| v.string else cur),
        []const []const u8 => {
            const src: []const []const u8 = if (val) |v| blk: {
                const items = try a.alloc([]const u8, v.array.items.len);
                for (v.array.items, items) |item, *dst| dst.* = item.string;
                break :blk items;
            } else cur;
            const list = try a.alloc([]const u8, src.len);
            for (src, list) |item, *dst| dst.* = try a.dupe(u8, item);
            return list;
        },
        bool => return if (val) |v| v.bool else cur,
        f32 => return if (val) |v| switch (v) {
            .float => @floatCast(v.float),
            .integer => @floatFromInt(v.integer),
            else => unreachable, // checked by hasSettingType
        } else cur,
        else => {
            const v = if (obj) |o| try getInt(o, name, T, cur) else cur;
            if (val != null and !inBounds(name, v)) {
                const b = comptime boundsOf(name);
                std.log.err("config: '{s}' = {d} is out of range ({d}..{d})", .{ name, v, b.min orelse 0, b.max orelse std.math.maxInt(c_int) });
                return error.InvalidConfigValue;
            }
            return v;
        },
    }
}

/// Numeric bounds of settings, enforced when loading and documented as
/// minimum/maximum in cli/olaf_config.schema.json (a test keeps both equal).
/// Every integer setting must in addition fit the C `int` it is copied into.
const setting_bounds = .{
    .{ "fragment_duration_in_seconds", 1, null },
    .{ "target_sample_rate", 4000, 48000 },
};

const Bounds = struct { min: ?i64, max: ?i64 };

fn boundsOf(comptime name: []const u8) Bounds {
    inline for (setting_bounds) |b| {
        if (comptime std.mem.eql(u8, b[0], name)) return .{ .min = b[1], .max = b[2] };
    }
    return .{ .min = null, .max = null };
}

/// Whether integer `v` is allowed for setting `name` (pure, for tests).
fn inBounds(comptime name: []const u8, v: i64) bool {
    const b = comptime boundsOf(name);
    if (v > std.math.maxInt(c_int)) return false;
    if (b.min) |min| if (v < min) return false;
    if (b.max) |max| if (v > max) return false;
    return true;
}

fn isSettingName(name: []const u8) bool {
    inline for (std.meta.fields(Config)) |field| {
        if (comptime isSetting(field.name)) {
            if (std.mem.eql(u8, name, field.name)) return true;
        }
    }
    return false;
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
        const contents = try file_reader.interface.allocRemaining(a, .limited(1024 * 1024));
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
    // A misspelled setting would otherwise be ignored silently. Keys starting
    // with '$' (e.g. "$schema" for editor support) are not settings.
    if (obj) |o| {
        var it = o.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, key, "$") and !isSettingName(key)) {
                std.log.warn("config: unknown setting '{s}' in {s} is ignored", .{ key, path });
            }
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
/// When neither file exists the built-in defaults are used; an unreadable or
/// invalid config file is an error.
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

test "hasSettingType: every setting type rejects the wrong JSON type" {
    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator,
        \\{"str":"x","num":4,"flt":0.5,"bool":true,"list":[".a"],"mixed":[".a",3]}
    , .{});
    defer parsed.deinit();
    const o = parsed.value.object;

    try std.testing.expect(hasSettingType([]const u8, o.get("str").?));
    try std.testing.expect(!hasSettingType([]const u8, o.get("bool").?));
    try std.testing.expect(hasSettingType(bool, o.get("bool").?));
    try std.testing.expect(!hasSettingType(bool, o.get("str").?));
    try std.testing.expect(hasSettingType(f32, o.get("flt").?));
    try std.testing.expect(hasSettingType(f32, o.get("num").?));
    try std.testing.expect(!hasSettingType(f32, o.get("str").?));
    try std.testing.expect(hasSettingType([]const []const u8, o.get("list").?));
    try std.testing.expect(!hasSettingType([]const []const u8, o.get("mixed").?));
    try std.testing.expect(!hasSettingType([]const []const u8, o.get("num").?));
    try std.testing.expect(!hasSettingType(u32, o.get("flt").?));
    try std.testing.expect(isSettingName("max_results"));
    try std.testing.expect(!isSettingName("max_result"));
    try std.testing.expect(!isSettingName("arena"));
}

test "inBounds: schema bounds and the C int limit" {
    try std.testing.expect(inBounds("target_sample_rate", 16000));
    try std.testing.expect(!inBounds("target_sample_rate", 2000));
    try std.testing.expect(!inBounds("target_sample_rate", 96000));
    try std.testing.expect(!inBounds("fragment_duration_in_seconds", 0));
    try std.testing.expect(inBounds("max_results", 50));
    try std.testing.expect(!inBounds("max_results", 3000000000));
}

// Keeps cli/olaf_config.schema.json in step with the Config struct: every
// setting documented with its type, default and bounds, and nothing else.
test "olaf_config.schema.json matches the Config struct" {
    const allocator = std.testing.allocator;
    const text = Io.Dir.cwd().readFileAlloc(std.testing.io, "cli/olaf_config.schema.json", allocator, .limited(1 << 20)) catch return error.SkipZigTest;
    defer allocator.free(text);
    const parsed = try json.parseFromSlice(json.Value, allocator, text, .{});
    defer parsed.deinit();
    const props = parsed.value.object.get("properties").?.object;

    const defaults = Config{};
    var settings: usize = 0;
    inline for (std.meta.fields(Config)) |field| {
        if (comptime isSetting(field.name)) {
            settings += 1;
            const prop = (props.get(field.name) orelse {
                std.debug.print("schema is missing setting '{s}'\n", .{field.name});
                return error.SchemaMismatch;
            }).object;
            const want_type = switch (field.type) {
                []const u8 => "string",
                []const []const u8 => "array",
                bool => "boolean",
                f32 => "number",
                else => "integer",
            };
            try std.testing.expectEqualStrings(want_type, prop.get("type").?.string);

            const d = @field(defaults, field.name);
            // Platform-dependent defaults are described, not given.
            const platform_default = comptime std.mem.startsWith(u8, field.name, "microphone_");
            if (!platform_default) {
                const sd = prop.get("default") orelse {
                    std.debug.print("schema has no default for '{s}'\n", .{field.name});
                    return error.SchemaMismatch;
                };
                switch (field.type) {
                    []const u8 => try std.testing.expectEqualStrings(d, sd.string),
                    []const []const u8 => {
                        try std.testing.expectEqual(d.len, sd.array.items.len);
                        for (d, sd.array.items) |x, y| try std.testing.expectEqualStrings(x, y.string);
                    },
                    bool => try std.testing.expectEqual(d, sd.bool),
                    f32 => try std.testing.expectEqual(d, @as(f32, switch (sd) {
                        .float => @floatCast(sd.float),
                        .integer => @floatFromInt(sd.integer),
                        else => return error.SchemaMismatch,
                    })),
                    else => try std.testing.expectEqual(@as(i64, d), sd.integer),
                }
            }

            if (field.type == u32) {
                const b = comptime boundsOf(field.name);
                const smin: ?i64 = if (prop.get("minimum")) |m| m.integer else null;
                const smax: ?i64 = if (prop.get("maximum")) |m| m.integer else null;
                std.testing.expectEqual(b.min, smin) catch |e| {
                    std.debug.print("minimum of '{s}' differs between code and schema\n", .{field.name});
                    return e;
                };
                try std.testing.expectEqual(b.max, smax);
            }
        }
    }
    try std.testing.expectEqual(settings, props.count());
}
