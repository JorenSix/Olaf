const std = @import("std");
const fs = std.fs;
const Io = std.Io;

const debug = std.log.scoped(.olaf_cli).debug;
const l_err = std.log.scoped(.olaf_cli).err;

const epoch = std.time.epoch;

/// Io used for fire-and-forget CLI output (the `print` helper). Concurrent work
/// threads `init.io` explicitly; stdout writes here are serialized by callers
/// (per-command output mutex) and errors are swallowed, so the global
/// single-threaded Io is sufficient and lets `print` stay io-free at call sites.
pub fn defaultIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Print formatted text to stdout, flushing immediately. Errors are swallowed,
/// matching the fire-and-forget CLI output behavior used across commands.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const io = defaultIo();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    _ = stdout.print(fmt, args) catch {};
    _ = stdout.flush() catch {};
}

/// Returns the modification date (year, month, day) of a file at `path`.
pub fn getFileModificationDate(io: Io, path: []const u8) !struct { year: i64, month: u32, day: u32 } {
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    const mtime_ns = @as(u64, @intCast(stat.mtime.nanoseconds));

    // Convert nanoseconds to seconds
    const mtime_s = @divTrunc(mtime_ns, std.time.ns_per_s);

    // Use Zig's built-in epoch time handling
    const epoch_seconds = epoch.EpochSeconds{ .secs = mtime_s };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1, // day_index is 0-based
    };
}

/// Returns the total size (in MB) of all files in the directory at `path` (recursively).
pub fn folderSize(io: Io, path: []const u8) !f64 {
    var total_size: u64 = 0;
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) {
            const file_path = try fs.path.join(allocator, &.{ path, entry.path });
            const stat = try Io.Dir.cwd().statFile(io, file_path, .{});
            total_size += stat.size;
        }
    }
    return @as(f64, @floatFromInt(total_size)) / (1024.0 * 1024.0);
}
/// Expands a path, replacing '~/' with `home` if present. Returns a newly
/// allocated string. When `home` is null (HOME not set), the path is returned
/// unchanged. In 0.16 the process environment is not globally accessible, so
/// the resolved HOME is captured once in `main` and threaded in here.
pub fn expandPath(allocator: std.mem.Allocator, home: ?[]const u8, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        if (home) |h| {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ h, path[1..] });
        }
        return allocator.dupe(u8, path);
    }
    return allocator.dupe(u8, path);
}

/// Represents an audio file with its associated identifier
pub const AudioFileWithId = struct {
    path: []const u8,
    identifier: []const u8,

    pub fn deinit(self: AudioFileWithId, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.identifier);
    }
};

pub fn audioFileListWithId(
    allocator: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    audio_file_path: []const u8,
    audio_file_identifier: []const u8,
    files: *std.ArrayList(AudioFileWithId),
    allowed_audio_file_extensions: []const []const u8,
) !void {
    const expanded = try expandPath(allocator, home, audio_file_path);
    defer allocator.free(expanded);

    const stat = Io.Dir.cwd().statFile(io, expanded, .{}) catch |err| {
        l_err("Could not find: {s}\n", .{expanded});
        return err;
    };

    switch (stat.kind) {
        .file => {
            if (isAudioFile(expanded, allowed_audio_file_extensions)) {
                const audio_file = AudioFileWithId{
                    .path = try allocator.dupe(u8, expanded),
                    .identifier = try allocator.dupe(u8, audio_file_identifier),
                };
                debug("Found audio file: {s} with identifier: {s}", .{ audio_file.path, audio_file.identifier });
                try files.append(allocator, audio_file);
            } else {
                l_err("File is not an audio file: {s}\n", .{expanded});
                return error.NotAudioFile;
            }
        },
        .directory => {
            l_err("Directories are not supported: {s}\n", .{expanded});
            return error.DirectoryNotSupported;
        },
        else => {
            l_err("Unsupported file type: {s}\n", .{expanded});
            return error.UnsupportedFileType;
        },
    }
}

/// Returns true if the file at `path` has an extension in `allowed_audio_file_extensions` (case-insensitive).
pub fn isAudioFile(path: []const u8, allowed_audio_file_extensions: []const []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (allowed_audio_file_extensions) |allowed_ext| {
        if (std.ascii.eqlIgnoreCase(ext, allowed_ext)) {
            debug("Found audio file: {s} with extension {s}", .{ path, ext });
            return true;
        }
    }
    return false;
}

/// Populates `files` with audio file paths found from the argument `arg`.
/// If `arg` is a directory, all audio files inside are added.
/// If `arg` is a .txt file, each line is treated as a path and expanded.
/// If `arg` is a file, it is added if it matches allowed extensions.
/// When no explicit identifier is provided, the full path is used as the identifier.
pub fn audioFileList(
    allocator: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    arg: []const u8,
    files: *std.ArrayList(AudioFileWithId),
    allowed_audio_file_extensions: []const []const u8,
) !void {
    const expanded = try expandPath(allocator, home, arg);
    defer allocator.free(expanded);

    const stat = Io.Dir.cwd().statFile(io, expanded, .{}) catch |err| {
        l_err("Could not find: {s}\n", .{expanded});
        return err;
    };

    switch (stat.kind) {
        .directory => {
            var dir = try Io.Dir.cwd().openDir(io, expanded, .{ .iterate = true });
            defer dir.close(io);

            debug("Walking directory: {s}", .{expanded});

            var walker = try dir.walk(allocator);
            defer walker.deinit();

            while (try walker.next(io)) |entry| {
                if (entry.kind == .file and !std.mem.startsWith(u8, entry.basename, ".")) {
                    if (isAudioFile(entry.path, allowed_audio_file_extensions)) {
                        const full_path = try fs.path.join(allocator, &.{ expanded, entry.path });
                        debug("Found audio file: {s}", .{full_path});

                        const audio_file = AudioFileWithId{
                            .path = full_path,
                            .identifier = try allocator.dupe(u8, full_path),
                        };
                        try files.append(allocator, audio_file);
                    }
                }
            }
        },
        .file => {
            if (std.mem.endsWith(u8, expanded, ".txt")) {
                const content = try Io.Dir.cwd().readFileAlloc(io, expanded, allocator, .limited(1024 * 1024 * 10));
                defer allocator.free(content);

                var it = std.mem.tokenizeAny(u8, content, "\n");
                while (it.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r\n");
                    if (trimmed.len > 0) {
                        const audio_path = try expandPath(allocator, home, trimmed);

                        const audio_file = AudioFileWithId{
                            .path = audio_path,
                            .identifier = try allocator.dupe(u8, audio_path),
                        };
                        try files.append(allocator, audio_file);
                    }
                }
            } else {
                if (isAudioFile(expanded, allowed_audio_file_extensions)) {
                    const path_copy = try allocator.dupe(u8, expanded);

                    const audio_file = AudioFileWithId{
                        .path = path_copy,
                        .identifier = try allocator.dupe(u8, path_copy),
                    };
                    try files.append(allocator, audio_file);
                } else {
                    l_err("File is not an audio file: {s}\n", .{expanded});
                    return error.NotAudioFile;
                }
            }
        },
        else => {},
    }
}

/// Runs a command given by `argv`, capturing stdout and stderr output.
/// Returns the process termination status and output as slices.
/// Caller owns the returned stdout/stderr memory.
pub fn runCommand(allocator: std.mem.Allocator, io: Io, argv: []const []const u8) !std.process.RunResult {
    if (@import("builtin").mode == .Debug) {
        const cmd_str = try std.mem.join(allocator, " ", argv);
        defer allocator.free(cmd_str);
        debug("Running command: {s}", .{cmd_str});
    }

    return std.process.run(allocator, io, .{ .argv = argv });
}
