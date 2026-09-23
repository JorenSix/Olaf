const std = @import("std");
const Io = std.Io;
const types = @import("../olaf_cli_types.zig");

pub const CommandInfo = struct {
    pub const name = "clear";
    pub const description = "Delete the database and/or cached fingerprints.";
    pub const help =
        \\Deletes the database files (data.mdb, lock.mdb) and cached
        \\fingerprints (*.tdb, *.meta) after confirmation. Other files
        \\in those folders are left alone.
        \\Use -f or --force to skip confirmation prompts.
        \\
        \\Examples:
        \\  olaf clear              # Interactive deletion with prompts
        \\  olaf clear -f           # Force deletion without prompts
    ;
    pub const needs_audio_files = false;
    pub const flags = &[_]types.Flag{ .force };
};

/// Which Olaf-owned folder is being cleared. Only files Olaf itself writes
/// are touched, so a misconfigured db_folder/cache_folder (e.g. "~/") can
/// never wipe unrelated data.
const Target = enum { db, cache };

fn isOlafFile(target: Target, name: []const u8) bool {
    return switch (target) {
        .db => std.mem.eql(u8, name, "data.mdb") or std.mem.eql(u8, name, "lock.mdb"),
        .cache => std.mem.endsWith(u8, name, ".tdb") or
            std.mem.endsWith(u8, name, ".meta") or
            std.mem.endsWith(u8, name, ".part"), // left by an interrupted cache
    };
}

/// Total size in MB of the files `clearTarget` would delete (non-recursive).
fn targetSizeMB(io: Io, folder: []const u8, target: Target) f64 {
    var dir = Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return 0.0;
    defer dir.close(io);

    var total: u64 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file or !isOlafFile(target, entry.name)) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        total += stat.size;
    }
    return @as(f64, @floatFromInt(total)) / (1024.0 * 1024.0);
}

/// Delete the Olaf-owned files directly inside `folder` (non-recursive).
/// A missing folder is reported and treated as nothing to delete.
fn clearTarget(allocator: std.mem.Allocator, io: Io, stdout: *Io.Writer, folder: []const u8, target: Target) !usize {
    var dir = Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.print("{s} folder does not exist: {s}\n", .{ @tagName(target), folder });
            try stdout.flush();
            return 0;
        }
        return err;
    };
    defer dir.close(io);

    // Collect names first so the directory is not mutated mid-iteration.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and isOlafFile(target, entry.name)) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    for (names.items) |name| try dir.deleteFile(io, name);

    try stdout.print("Deleted {d} file(s) from {s}\n", .{ names.items.len, folder });
    try stdout.flush();
    return names.items.len;
}

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config orelse return error.ConfigNotLoaded;
    const io = args.io;

    const db_folder = config.db_folder;
    const cache_folder = config.cache_folder;

    var delete_db = args.force;
    var delete_cache = args.force;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (!args.force) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);
        const reader: *Io.Reader = &stdin_reader.interface;

        try stdout.print("Proceed with deleting the olaf db ({d:.0} MB in {s})? (yes/no)\n", .{ targetSizeMB(io, db_folder, .db), db_folder });
        try stdout.flush();
        delete_db = try confirmed(reader) orelse return nothingDeleted(stdout);

        try stdout.print("Proceed with deleting the olaf cache ({d:.0} MB in {s})? (yes/no)\n", .{ targetSizeMB(io, cache_folder, .cache), cache_folder });
        try stdout.flush();
        delete_cache = try confirmed(reader) orelse return nothingDeleted(stdout);

        if (!delete_db and !delete_cache) return nothingDeleted(stdout);
    }

    if (delete_db) _ = try clearTarget(allocator, io, stdout, db_folder, .db);
    if (delete_cache) _ = try clearTarget(allocator, io, stdout, cache_folder, .cache);
}

/// Read one answer line. Returns null on end of input (treated as "abort").
fn confirmed(reader: *Io.Reader) !?bool {
    // takeDelimiter consumes the '\n' (takeDelimiterExclusive does not, which
    // made every prompt after the first read an empty line).
    const line = try reader.takeDelimiter('\n') orelse return null;
    return std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "yes");
}

fn nothingDeleted(stdout: *Io.Writer) !void {
    try stdout.print("Nothing deleted\n", .{});
    try stdout.flush();
}
