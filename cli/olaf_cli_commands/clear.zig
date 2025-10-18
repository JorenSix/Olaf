const std = @import("std");
const types = @import("../olaf_wrapper_types.zig");
const util = @import("../olaf_wrapper_util.zig");

pub const CommandInfo = struct {
    pub const name = "clear";
    pub const description = "Delete the database and/or cache folders.";
    pub const help =
        \\Deletes the database and cache folders after confirmation.
        \\Use -f or --force to skip confirmation prompts.
        \\
        \\Examples:
        \\  olaf clear              # Interactive deletion with prompts
        \\  olaf clear -f           # Force deletion without prompts
    ;
    pub const needs_audio_files = false;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config orelse return error.ConfigNotLoaded;

    const db_folder = config.db_folder;
    const cache_folder = config.cache_folder;

    var delete_db = args.force;
    var delete_cache = args.force;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (!args.force) {
        // Prompt for database deletion
        const db_size = util.folderSize(db_folder) catch 0.0;
        _ = try stdout.print("Proceed with deleting the olaf db ({d:.0} MB {s})? (yes/no)\n", .{ db_size, db_folder });
        _ = try stdout.flush();

        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);

        var buffer: [100]u8 = undefined;
        const n = try stdin_reader.read(&buffer);
        if (n > 0) {
            const trimmed_db = std.mem.trim(u8, buffer[0..n], " \t\r\n");

            if (std.mem.eql(u8, trimmed_db, "yes")) {
                delete_db = true;
            } else {
                _ = try stdout.print("Nothing deleted\n", .{});
                _ = try stdout.flush();
            }
        }

        // Prompt for cache deletion
        const cache_size = util.folderSize(cache_folder) catch 0.0;
        _ = try stdout.print("Proceed with deleting the olaf cache ({d:.0} MB {s})? (yes/no)\n", .{ cache_size, cache_folder });
        _ = try stdout.flush();

        const n2 = try stdin_reader.read(&buffer);
        if (n2 > 0) {
            const trimmed_cache = std.mem.trim(u8, buffer[0..n2], " \t\r\n");

            if (std.mem.eql(u8, trimmed_cache, "yes")) {
                delete_cache = true;
            } else {
                _ = try stdout.print("Operation cancelled.\n", .{});
                _ = try stdout.flush();
            }
        }
    }
    if (delete_db) {
        _ = try stdout.print("Clear the database folder.\n", .{});
        _ = try stdout.flush();
        var dir = std.fs.cwd().openDir(db_folder, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                _ = try stdout.print("Database folder does not exist.\n", .{});
                _ = try stdout.flush();
                return;
            }
            return err;
        };
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                try dir.deleteFile(entry.path);
            }
        }
    }

    if (delete_cache) {
        _ = try stdout.print("Clear the cache folder\n", .{});
        _ = try stdout.flush();
        var dir = std.fs.cwd().openDir(cache_folder, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                _ = try stdout.print("Cache folder does not exist.\n", .{});
                _ = try stdout.flush();
                return;
            }
            return err;
        };
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                try dir.deleteFile(entry.path);
            }
        }
    }
}
