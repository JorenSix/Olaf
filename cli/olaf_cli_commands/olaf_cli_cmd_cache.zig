const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const WaitGroup = Thread.WaitGroup;

const c = @cImport({
    @cInclude("stdio.h");
});

const olaf_cli_config = @import("../olaf_cli_config.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const olaf_cli_util_audio = @import("../olaf_cli_util_audio.zig");
const olaf_cli_bridge = @import("../olaf_cli_bridge.zig");
const types = @import("../olaf_cli_types.zig");

const debug = std.log.scoped(.olaf_cli_cache).debug;
const fs = std.fs;

pub const CommandInfo = struct {
    pub const name = "cache";
    pub const description = "Extracts fingerprints and caches them in text files for later storage.\n\t\t--threads n\t The number of threads to use for parallel extraction.";
    pub const help = "[--threads n] audio_files...";
    pub const needs_audio_files = true;
};

fn print(comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    _ = stdout.print(fmt, args) catch {};
    _ = stdout.flush() catch {};
}

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to cache.\n", .{});
        return;
    }

    if (args.threads == 1) {
        debug("Warning: only using a single thread. Speed up with e.g. --threads 8\n", .{});
    }

    try executeCacheParallel(allocator, args.audio_files.items, args.config.?, args.threads);
}

// Cache task structure
const CacheTask = struct {
    allocator: std.mem.Allocator,
    audio_file: olaf_cli_util.AudioFileWithId,
    config: *const olaf_cli_config.Config,
    index: usize,
    total: usize,
    error_mutex: *Mutex,
    error_list: *std.ArrayList([]const u8),
};

fn createTempRawPath(allocator: std.mem.Allocator) ![]u8 {
    const tmp_dir = if (std.process.getEnvVarOwned(allocator, "TMPDIR")) |dir| dir else |_| try allocator.dupe(u8, "/tmp/");
    defer allocator.free(tmp_dir);

    const olaf_cache_dir = try std.fmt.allocPrint(allocator, "{s}olaf_raw_audio_cache", .{tmp_dir});
    defer allocator.free(olaf_cache_dir);

    fs.cwd().makePath(olaf_cache_dir) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    return try std.fmt.allocPrint(allocator, "{s}/olaf_audio_{d}.raw", .{ olaf_cache_dir, std.time.milliTimestamp() });
}

fn cacheAudioFile(
    allocator: std.mem.Allocator,
    audio_file: olaf_cli_util.AudioFileWithId,
    config: *const olaf_cli_config.Config,
    index: usize,
    total: usize,
) !void {
    debug("Caching audio file {d}/{d}: {s}", .{ index + 1, total, audio_file.path });

    // Get audio identifier (hash)
    const audio_id = try olaf_cli_bridge.olaf_name_to_id(allocator, audio_file.identifier);

    // Create cache file path
    const cache_folder_expanded = try olaf_cli_util.expandPath(allocator, config.cache_folder);
    defer allocator.free(cache_folder_expanded);

    // Ensure cache folder exists
    fs.cwd().makePath(cache_folder_expanded) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    const cache_file_path = try std.fmt.allocPrint(allocator, "{s}/{d}.tdb", .{ cache_folder_expanded, audio_id });
    defer allocator.free(cache_file_path);

    // Check if cache file already exists
    if (fs.cwd().access(cache_file_path, .{})) |_| {
        print("{d}/{d}, {s}, {s}, SKIPPED: cache file already present\n", .{ index + 1, total, audio_file.path, cache_file_path });
        return;
    } else |_| {}

    const meta_file_path = try std.fmt.allocPrint(allocator, "{s}/{d}.meta", .{ cache_folder_expanded, audio_id });
    defer allocator.free(meta_file_path);

    // olaf_has needs the database to check against, which we don't want to access here.
    // So this part is commented out for now.

    // Check if already indexed (if configured to skip duplicates)
    // if (config.skip_duplicates) {
    //     const has_results = try olaf_cli_bridge.olaf_has(allocator, &[_][]const u8{audio_file.identifier}, config);
    //     defer allocator.free(has_results);

    //     if (has_results[0]) {
    //         print("{d}/{d}, {s}, SKIPPED: already indexed audio file\n", .{ index + 1, total, audio_file.path });
    //         return;
    //     }
    // }

    // Convert to raw audio
    const raw_audio_path = try createTempRawPath(allocator);
    defer allocator.free(raw_audio_path);
    defer fs.cwd().deleteFile(raw_audio_path) catch {};

    try olaf_cli_util_audio.convertToRaw(allocator, audio_file.path, raw_audio_path, config.target_sample_rate);

    // Create temporary file for capturing olaf_print output
    const temp_output_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{cache_file_path});
    defer allocator.free(temp_output_path);
    defer fs.cwd().deleteFile(temp_output_path) catch {};

    const temp_file = try fs.cwd().createFile(temp_output_path, .{});
    defer temp_file.close();

    // Call olaf_print (this will write to the file)
    try olaf_cli_bridge.olaf_print_to_file(allocator, raw_audio_path, audio_file.identifier, config, cache_file_path, meta_file_path);

    // Get absolute path for audio f
    print("{d}/{d}, {s}, {s}\n", .{ index + 1, total, audio_file.path, cache_file_path });
}

fn cacheAudioFileThreaded(task: CacheTask) void {
    cacheAudioFile(
        task.allocator,
        task.audio_file,
        task.config,
        task.index,
        task.total,
    ) catch |cache_err| {
        task.error_mutex.lock();
        defer task.error_mutex.unlock();

        const err_msg = std.fmt.allocPrint(task.allocator, "Failed to cache {s}: {}", .{ task.audio_file.path, cache_err }) catch "Out of memory";
        task.error_list.append(task.allocator, err_msg) catch {};
        std.log.err("{s}", .{err_msg});
    };
}

fn executeCacheParallel(
    allocator: std.mem.Allocator,
    audio_files: []const olaf_cli_util.AudioFileWithId,
    config: *const olaf_cli_config.Config,
    num_threads: u32,
) !void {
    const actual_threads = @min(num_threads, audio_files.len);

    if (actual_threads <= 1) {
        // Single-threaded execution
        debug("Caching {d} audio files (single-threaded)", .{audio_files.len});
        for (audio_files, 0..) |audio_file, i| {
            try cacheAudioFile(allocator, audio_file, config, i, audio_files.len);
        }
    } else {
        // Multi-threaded execution
        debug("Caching {d} audio files with {d} threads", .{ audio_files.len, actual_threads });

        var pool: Thread.Pool = undefined;
        try pool.init(.{ .allocator = allocator, .n_jobs = actual_threads });
        defer pool.deinit();

        var wait_group: WaitGroup = undefined;
        wait_group.reset();

        var error_mutex = Mutex{};
        var error_list = std.ArrayList([]const u8){};
        defer {
            for (error_list.items) |err_msg| {
                allocator.free(err_msg);
            }
            error_list.deinit(allocator);
        }

        for (audio_files, 0..) |audio_file, i| {
            const task = CacheTask{
                .allocator = allocator,
                .audio_file = audio_file,
                .config = config,
                .index = i,
                .total = audio_files.len,
                .error_mutex = &error_mutex,
                .error_list = &error_list,
            };

            pool.spawnWg(&wait_group, cacheAudioFileThreaded, .{task});
        }

        pool.waitAndWork(&wait_group);

        if (error_list.items.len > 0) {
            return error.CachingFailed;
        }
    }
}
