const std = @import("std");

const olaf_cli_config = @import("../olaf_cli_config.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const olaf_cli_session = @import("../olaf_cli_session.zig");
const types = @import("../olaf_cli_types.zig");

const debug = std.log.scoped(.olaf_cli_store_cached).debug;
const Io = std.Io;

pub const CommandInfo = struct {
    pub const name = "store_cached";
    pub const description = "Stores fingerprints cached in text files into the database.\n\tAfter caching fingerprints with 'olaf cache audio_files...' use store_cached to index them.\n\tAlready indexed files are skipped (skip_duplicates); -f stores them anyway.";
    pub const help = "[-f]";
    pub const needs_audio_files = false;
};

const print = olaf_cli_util.print;

fn readMetaPath(io: Io, allocator: std.mem.Allocator, meta_file_path: []const u8) !?[]u8 {
    const content = try Io.Dir.cwd().readFileAlloc(io, meta_file_path, allocator, .limited(64 * 1024));
    defer allocator.free(content);

    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "path=")) {
            const value = std.mem.trim(u8, line["path=".len..], " \t");
            if (value.len == 0) return null;
            return try allocator.dupe(u8, value);
        }
    }
    return null;
}

/// A cached fingerprint file plus the audio identifier recorded in its .meta.
const CacheEntry = struct {
    cache_path: []u8,
    identifier: []u8,

    fn lessThan(_: void, a: CacheEntry, b: CacheEntry) bool {
        return std.mem.lessThan(u8, a.cache_path, b.cache_path);
    }
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    const io = args.io;

    // Expand cache folder path
    const cache_folder_expanded = try olaf_cli_util.expandPath(allocator, config.home, config.cache_folder);
    defer allocator.free(cache_folder_expanded);

    var cache_dir = Io.Dir.cwd().openDir(io, cache_folder_expanded, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            print("Cache folder does not exist: {s}\n", .{cache_folder_expanded});
            return;
        }
        return err;
    };
    defer cache_dir.close(io);

    // Collect every {id}.tdb with a readable {id}.meta first, so the database
    // is opened once for the duplicate check and once for all writes.
    var entries: std.ArrayList(CacheEntry) = .empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.cache_path);
            allocator.free(e.identifier);
        }
        entries.deinit(allocator);
    }
    var warnings: usize = 0;

    var iter = cache_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".tdb")) continue;

        const stem = entry.name[0 .. entry.name.len - ".tdb".len];
        const meta_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.meta", .{ cache_folder_expanded, stem });
        defer allocator.free(meta_file_path);

        const identifier = readMetaPath(io, allocator, meta_file_path) catch |err| {
            print("WARNING: {s} could not be read ({}): skipping\n", .{ meta_file_path, err });
            warnings += 1;
            continue;
        } orelse {
            print("WARNING: {s} has no path= entry: skipping\n", .{meta_file_path});
            warnings += 1;
            continue;
        };
        errdefer allocator.free(identifier);

        const cache_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_folder_expanded, entry.name });
        try entries.append(allocator, .{ .cache_path = cache_file_path, .identifier = identifier });
    }

    if (entries.items.len == 0) {
        print("No cache files found in {s}\n", .{cache_folder_expanded});
        return;
    }
    std.mem.sort(CacheEntry, entries.items, {}, CacheEntry.lessThan);

    // Quiet duplicate check (olaf_has printed a CSV header + row per file to
    // stdout, and crashed on a database that does not exist yet).
    const identifiers = try allocator.alloc([]const u8, entries.items.len);
    defer allocator.free(identifiers);
    for (entries.items, identifiers) |e, *id| id.* = e.identifier;

    const stored = if (config.skip_duplicates and !args.force)
        try olaf_cli_session.storedFlags(allocator, config, identifiers)
    else
        try allocator.alloc(bool, identifiers.len);
    defer allocator.free(stored);
    if (!(config.skip_duplicates and !args.force)) @memset(stored, false);

    var to_store: std.ArrayList(olaf_cli_session.CachedFile) = .empty;
    defer to_store.deinit(allocator);

    for (entries.items, stored) |e, is_stored| {
        if (!is_stored) try to_store.append(allocator, .{ .cache_path = e.cache_path, .audio_path = e.identifier });
    }

    if (to_store.items.len > 0) {
        debug("Storing {d} cache files", .{to_store.items.len});
        try olaf_cli_session.storeCachedFiles(allocator, to_store.items, config);
    }

    const total = entries.items.len;
    for (entries.items, stored, 1..) |e, is_stored, index| {
        const status = if (is_stored) "SKIPPED: already indexed audio file" else "stored from cache";
        print("{d}/{d}, {s}, {s}\n", .{ index, total, e.identifier, status });
    }

    print("Stored {d} cache file(s), skipped {d} already indexed, {d} warning(s)\n", .{ to_store.items.len, total - to_store.items.len, warnings });
}
