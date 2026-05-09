const std = @import("std");

const olaf_cli_config = @import("../olaf_cli_config.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const olaf_cli_bridge = @import("../olaf_cli_bridge.zig");
const types = @import("../olaf_cli_types.zig");

const debug = std.log.scoped(.olaf_cli_store_cached).debug;
const fs = std.fs;

pub const CommandInfo = struct {
    pub const name = "store_cached";
    pub const description = "Stores fingerprints cached in text files into the database.\n\tAfter caching fingerprints with 'olaf cache audio_files...' use store_cached to index them.";
    pub const help = "";
    pub const needs_audio_files = false;
};

fn print(comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    _ = stdout.print(fmt, args) catch {};
    _ = stdout.flush() catch {};
}

fn readMetaPath(allocator: std.mem.Allocator, meta_file_path: []const u8) !?[]u8 {
    const content = try fs.cwd().readFileAlloc(allocator, meta_file_path, 64 * 1024);
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

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;

    // Expand cache folder path
    const cache_folder_expanded = try olaf_cli_util.expandPath(allocator, config.cache_folder);
    defer allocator.free(cache_folder_expanded);

    // Process all .tdb files in cache folder
    var cache_dir = fs.cwd().openDir(cache_folder_expanded, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            print("Cache folder does not exist: {s}\n", .{cache_folder_expanded});
            return;
        }
        return err;
    };
    defer cache_dir.close();

    // Count files first
    var file_count: usize = 0;
    {
        var iter = cache_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".tdb")) {
                file_count += 1;
            }
        }
    }

    if (file_count == 0) {
        print("No cache files found in {s}\n", .{cache_folder_expanded});
        return;
    }

    debug("Found {d} cache files to process\n", .{file_count});

    // Process each cache file
    var current_index: usize = 0;
    var iter = cache_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".tdb")) continue;

        const cache_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_folder_expanded, entry.name });
        defer allocator.free(cache_file_path);

        const i = current_index;
        current_index += 1;
        const index = i + 1;
        const total = file_count;

        // Read sibling .meta file to recover audio file path.
        // Cache writes "{id}.tdb" (fingerprints) + "{id}.meta" (path=, duration=, fingerprints=).
        const stem_len = entry.name.len - ".tdb".len;
        const meta_basename = entry.name[0..stem_len];
        const meta_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.meta", .{ cache_folder_expanded, meta_basename });
        defer allocator.free(meta_file_path);

        const audio_filename = readMetaPath(allocator, meta_file_path) catch |err| {
            print("{d}/{d}, WARNING: {s} could not be read ({}): skipping\n", .{ index, total, meta_file_path, err });
            continue;
        };

        if (audio_filename) |filename| {
            defer allocator.free(filename);

            // Check if already indexed (if configured to skip duplicates)
            if (config.skip_duplicates) {
                const has_results = try olaf_cli_bridge.olaf_has(allocator, &[_][]const u8{filename}, config);
                defer allocator.free(has_results);

                if (has_results[0]) {
                    print("{d}/{d}, {s}, SKIPPED: already indexed audio file\n", .{ index, total, filename });
                    continue;
                }
            }

            // Store cached fingerprints
            debug("Processing cache file {d}/{d}: {s}\n", .{ index, total, cache_file_path });

            try olaf_cli_bridge.olaf_store_cached_files(
                allocator,
                &[_]olaf_cli_bridge.CachedFile{.{ .cache_path = cache_file_path, .audio_path = filename }},
                config,
            );

            print("{d}/{d}, {s}, stored from cache\n", .{ index, total, filename });
        } else {
            print("{d}/{d}, WARNING: {s} has no path= entry: skipping\n", .{ index, total, meta_file_path });
        }
    }

    print("Stored {d} cache files\n", .{file_count});
}
