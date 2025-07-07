const std = @import("std");
const fs = std.fs;

const debug = std.log.scoped(.olaf_wrapper).debug;
const l_err = std.log.scoped(.olaf_wrapper).err;

const epoch = std.time.epoch;

/// Returns the modification date (year, month, day) of a file at `path`.
pub fn getFileModificationDate(path: []const u8) !struct { year: i64, month: u32, day: u32 } {
    const stat = try fs.cwd().statFile(path);
    const mtime_ns = @as(u64, @intCast(stat.mtime));

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

/// Expands a path, replacing '~/' with the user's home directory if present. Returns a newly allocated string.
pub fn expandPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return allocator.dupe(u8, path),
            else => return err,
        };
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
    }
    return allocator.dupe(u8, path);
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

/// Returns the total size (in MB) of all files in the directory at `path` (recursively).
pub fn folderSize(path: []const u8) !f64 {
    var total_size: u64 = 0;
    var dir = try fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            const file_path = try fs.path.join(allocator, &.{ path, entry.path });
            const stat = try fs.cwd().statFile(file_path);
            total_size += stat.size;
        }
    }

    return @as(f64, @floatFromInt(total_size)) / (1024.0 * 1024.0);
}

/// Populates `files` with audio file paths found from the argument `arg`.
/// If `arg` is a directory, all audio files inside are added.
/// If `arg` is a .txt file, each line is treated as a path and expanded.
/// If `arg` is a file, it is added if it matches allowed extensions.
pub fn audioFileList(
    allocator: std.mem.Allocator,
    arg: []const u8,
    files: *std.ArrayList([]const u8),
    allowed_audio_file_extensions: []const []const u8,
) !void {
    const expanded = try expandPath(allocator, arg);
    defer allocator.free(expanded);

    const stat = fs.cwd().statFile(expanded) catch |err| {
        l_err("Could not find: {s}\n", .{expanded});
        return err;
    };

    switch (stat.kind) {
        .directory => {
            var dir = try fs.cwd().openDir(expanded, .{ .iterate = true });
            defer dir.close();

            debug("Walking directory: {s}", .{expanded});

            var walker = try dir.walk(allocator);
            defer walker.deinit();

            while (try walker.next()) |entry| {
                if (entry.kind == .file and !std.mem.startsWith(u8, entry.basename, ".")) {
                    if (isAudioFile(entry.path, allowed_audio_file_extensions)) {
                        const full_path = try fs.path.join(allocator, &.{ expanded, entry.path });
                        debug("Found audio file: {s}", .{full_path});
                        try files.append(full_path);
                    }
                }
            }
        },
        .file => {
            if (std.mem.endsWith(u8, expanded, ".txt")) {
                const content = try fs.cwd().readFileAlloc(allocator, expanded, 1024 * 1024 * 10);
                defer allocator.free(content);

                var it = std.mem.tokenizeAny(u8, content, "\n");
                while (it.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r\n");
                    if (trimmed.len > 0) {
                        const audio_path = try expandPath(allocator, trimmed);
                        try files.append(audio_path);
                    }
                }
            } else {
                try files.append(try allocator.dupe(u8, expanded));
            }
        },
        else => {},
    }
}

/// Runs a command given by `argv`, capturing stdout and stderr output.
/// Returns the process termination status and output as slices.
pub fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
} {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    const cmd_str = try std.mem.join(allocator, " ", argv);
    defer allocator.free(cmd_str);
    debug("Running command: {s}", .{cmd_str});

    try child.spawn();

    // Use ArrayList to collect output as it streams in
    var stdout_list = std.ArrayList(u8).init(allocator);
    defer stdout_list.deinit();
    var stderr_list = std.ArrayList(u8).init(allocator);
    defer stderr_list.deinit();

    var stdout_reader = child.stdout.?.reader();
    var stderr_reader = child.stderr.?.reader();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;

    // Read both streams until EOF
    var stdout_done = false;
    var stderr_done = false;
    while (!stdout_done or !stderr_done) {
        if (!stdout_done) {
            const n = stdout_reader.read(&stdout_buf) catch |err| return err;
            if (n == 0) {
                stdout_done = true;
            } else {
                //print the output to stdout
                debug("{s}", .{stdout_buf[0..n]}); // Uncomment to print stdout in real-time
                try stdout_list.appendSlice(stdout_buf[0..n]);
            }
        }
        if (!stderr_done) {
            const n = stderr_reader.read(&stderr_buf) catch |err| return err;
            if (n == 0) {
                stderr_done = true;
            } else {
                debug("{s}", .{stderr_buf[0..n]}); // Uncomment to print stdout in real-time
                try stderr_list.appendSlice(stderr_buf[0..n]);
            }
        }
    }

    const term = try child.wait();

    return .{
        .term = term,
        .stdout = try stdout_list.toOwnedSlice(),
        .stderr = try stderr_list.toOwnedSlice(),
    };
}
