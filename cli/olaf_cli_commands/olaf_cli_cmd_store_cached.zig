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

        // Read first line to extract audio filename
        const audio_filename = blk: {
            // Read entire file (cache files contain only metadata, so they're small)
            const content = try fs.cwd().readFileAlloc(allocator, cache_file_path, 1024 * 1024); // 1MB max
            defer allocator.free(content);

            // Get first line
            const first_line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
            const first_line = content[0..first_line_end];

            // Parse format: index/total,full_path,fingerprint_data
            var parts = std.mem.tokenizeScalar(u8, first_line, ',');
            _ = parts.next(); // skip index/total
            if (parts.next()) |path_part| {
                const trimmed = std.mem.trim(u8, path_part, " \t");
                break :blk try allocator.dupe(u8, trimmed);
            }

            break :blk null;
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

            try olaf_cli_bridge.olaf_store_cached_files(allocator, &[_][]const u8{cache_file_path}, config);

            print("{d}/{d}, {s}, stored from cache\n", .{ index, total, filename });
        } else {
            print("{d}/{d}, WARNING: {s} could not be parsed (no audio filename found)\n", .{ index, total, cache_file_path });
        }
    }

    print("Stored {d} cache files\n", .{file_count});
}
