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
    // Streaming, not positional: a positional writer starts at offset 0 on
    // every call, so with stdout redirected to a file each print overwrote
    // the previous one (and `>>` appends clobbered the file).
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
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

/// Expands a path, replacing '~/' with `home` if present. Returns a newly
/// allocated string. When `home` is null (HOME not set), the path is returned
/// unchanged. In 0.16 the process environment is not globally accessible, so
/// the resolved HOME is captured once in `main` and threaded in here.
pub fn expandPath(allocator: std.mem.Allocator, home: ?[]const u8, path: []const u8) ![]u8 {
    const tilde = std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/") or std.mem.startsWith(u8, path, "~\\");
    if (!tilde) return allocator.dupe(u8, path);
    // Without a home directory "~" would stay literal and create a "./~"
    // folder next to wherever olaf happens to run.
    const h = home orelse {
        l_err("cannot expand '{s}': neither HOME nor USERPROFILE is set", .{path});
        return error.NoHomeDirectory;
    };
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ h, path[1..] });
}

test "expandPath" {
    const a = std.testing.allocator;
    const p = try expandPath(a, "/home/me", "~/.olaf/db/");
    defer a.free(p);
    try std.testing.expectEqualStrings("/home/me/.olaf/db/", p);
    const bare = try expandPath(a, "/home/me", "~");
    defer a.free(bare);
    try std.testing.expectEqualStrings("/home/me", bare);
    const plain = try expandPath(a, null, "/data/db/");
    defer a.free(plain);
    try std.testing.expectEqualStrings("/data/db/", plain);
}

/// Returns `path` with a trailing '/' appended when it has none. Takes
/// ownership of `path` (freed when a new, longer slice is returned). The C core
/// and the "{db_folder}data.mdb" lookups require the trailing separator.
pub fn ensureTrailingSlash(allocator: std.mem.Allocator, path: []u8) ![]u8 {
    if (path.len == 0 or path[path.len - 1] == '/' or path[path.len - 1] == '\\') return path;
    defer allocator.free(path);
    return std.fmt.allocPrint(allocator, "{s}/", .{path});
}

test "ensureTrailingSlash" {
    const a = std.testing.allocator;
    const with = try ensureTrailingSlash(a, try a.dupe(u8, "/data/olaf"));
    defer a.free(with);
    try std.testing.expectEqualStrings("/data/olaf/", with);
    const kept = try ensureTrailingSlash(a, try a.dupe(u8, "/data/olaf/"));
    defer a.free(kept);
    try std.testing.expectEqualStrings("/data/olaf/", kept);
}

/// Canonical path used for audio paths and default identifiers, so the same
/// file always maps to the same id however it was typed (relative, absolute,
/// via a symlinked directory). Existing paths are fully resolved (realpath);
/// a path that does not exist falls back to `absolutePath` so the caller can
/// report it. Caller owns the result.
pub fn canonicalPath(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    var buf: [fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, path, &buf) catch return absolutePath(allocator, io, path);
    return allocator.dupe(u8, buf[0..n]);
}

/// Absolute, normalized form of `path` (like Ruby's File.expand_path, which
/// the original wrapper used): relative paths are resolved against the working
/// directory and `.`/`..` are removed; symlinks are not followed.
/// Caller owns the result.
pub fn absolutePath(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    if (fs.path.isAbsolute(path)) return fs.path.resolve(allocator, &.{path});
    var cwd_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}

test "absolutePath normalizes absolute paths" {
    const a = std.testing.allocator;
    const p = try absolutePath(a, std.testing.io, "/music/./a/../b.mp3");
    defer a.free(p);
    try std.testing.expectEqualStrings("/music/b.mp3", p);
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
    const home_expanded = try expandPath(allocator, home, audio_file_path);
    defer allocator.free(home_expanded);
    const expanded = try canonicalPath(allocator, io, home_expanded);
    defer allocator.free(expanded);

    const stat = Io.Dir.cwd().statFile(io, expanded, .{}) catch |err| {
        l_err("Could not find: {s}\n", .{expanded});
        return err;
    };

    switch (stat.kind) {
        .file => {
            if (isAudioFile(expanded, allowed_audio_file_extensions)) {
                const path = try allocator.dupe(u8, expanded);
                errdefer allocator.free(path);
                const identifier = try allocator.dupe(u8, audio_file_identifier);
                errdefer allocator.free(identifier);
                debug("Found audio file: {s} with identifier: {s}", .{ path, identifier });
                try files.append(allocator, .{ .path = path, .identifier = identifier });
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
/// If `arg` is a directory, all audio files inside are added, sorted by path.
/// If `arg` is a .txt file, each line is handled like a command-line argument
/// (file or directory); empty lines and `#` comments are ignored, and bad
/// lines are reported and skipped instead of aborting the run.
/// If `arg` is a file, it is added if it matches allowed extensions.
/// When no explicit identifier is provided, the canonical path is used as the identifier.
pub fn audioFileList(
    allocator: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    arg: []const u8,
    files: *std.ArrayList(AudioFileWithId),
    allowed_audio_file_extensions: []const []const u8,
) !void {
    try addPath(allocator, io, home, arg, files, allowed_audio_file_extensions, null);
}

/// Where a path came from when it was read from a `.txt` list.
const ListLine = struct { list: []const u8, line: usize };

fn addPath(
    allocator: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    arg: []const u8,
    files: *std.ArrayList(AudioFileWithId),
    allowed_audio_file_extensions: []const []const u8,
    from_list: ?ListLine,
) anyerror!void { // explicit: addPath and addList recurse into each other
    const home_expanded = try expandPath(allocator, home, arg);
    defer allocator.free(home_expanded);
    const expanded = try canonicalPath(allocator, io, home_expanded);
    defer allocator.free(expanded);

    const stat = Io.Dir.cwd().statFile(io, expanded, .{}) catch |err| {
        if (from_list) |l| {
            l_err("{s}:{d}: could not find {s}, skipping", .{ l.list, l.line, expanded });
            return;
        }
        l_err("Could not find: {s}", .{expanded});
        return err;
    };

    switch (stat.kind) {
        .directory => try addDirectory(allocator, io, expanded, files, allowed_audio_file_extensions),
        .file => {
            if (std.mem.endsWith(u8, expanded, ".txt")) {
                if (from_list) |l| {
                    l_err("{s}:{d}: nested list {s} is not supported, skipping", .{ l.list, l.line, expanded });
                    return;
                }
                try addList(allocator, io, home, expanded, files, allowed_audio_file_extensions);
            } else if (isAudioFile(expanded, allowed_audio_file_extensions)) {
                try appendAudioFile(allocator, files, expanded);
            } else {
                if (from_list) |l| {
                    l_err("{s}:{d}: not an audio file {s}, skipping", .{ l.list, l.line, expanded });
                    return;
                }
                l_err("File is not an audio file: {s}", .{expanded});
                return error.NotAudioFile;
            }
        },
        else => {},
    }
}

fn appendAudioFile(allocator: std.mem.Allocator, files: *std.ArrayList(AudioFileWithId), path: []const u8) !void {
    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    const identifier = try allocator.dupe(u8, path);
    errdefer allocator.free(identifier);
    try files.append(allocator, .{ .path = path_copy, .identifier = identifier });
}

fn lessThanByPath(_: void, a: AudioFileWithId, b: AudioFileWithId) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Add every (non-hidden) audio file below `dir_path`. Walk order depends on
/// the file system (e.g. hash order on ext4), so the files found for this
/// directory are sorted to make file indices and output order reproducible.
fn addDirectory(
    allocator: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    files: *std.ArrayList(AudioFileWithId),
    allowed_audio_file_extensions: []const []const u8,
) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    debug("Walking directory: {s}", .{dir_path});

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    const start = files.items.len;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (std.mem.startsWith(u8, entry.basename, ".") or !isAudioFile(entry.path, allowed_audio_file_extensions)) continue;
        const full_path = try fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(full_path);
        if (entry.kind == .sym_link) {
            // A symlinked file (e.g. a library manager's link farm) is
            // identified by its target, like a symlink given directly.
            const stat = Io.Dir.cwd().statFile(io, full_path, .{}) catch continue; // dangling
            if (stat.kind != .file) continue;
            const target = try canonicalPath(allocator, io, full_path);
            defer allocator.free(target);
            try appendAudioFile(allocator, files, target);
        } else {
            try appendAudioFile(allocator, files, full_path);
        }
        debug("Found audio file: {s}", .{full_path});
    }
    std.mem.sort(AudioFileWithId, files.items[start..], {}, lessThanByPath);
}

fn addList(
    allocator: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    list_path: []const u8,
    files: *std.ArrayList(AudioFileWithId),
    allowed_audio_file_extensions: []const []const u8,
) !void {
    const content = try Io.Dir.cwd().readFileAlloc(io, list_path, allocator, .limited(1024 * 1024 * 10));
    defer allocator.free(content);

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try addPath(allocator, io, home, trimmed, files, allowed_audio_file_extensions, .{ .list = list_path, .line = line_no });
    }
}
