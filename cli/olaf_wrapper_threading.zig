const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const WaitGroup = Thread.WaitGroup;

const olaf_wrapper_config = @import("olaf_wrapper_config.zig");
const olaf_wrapper_util = @import("olaf_wrapper_util.zig");
const olaf_wrapper_util_audio = @import("olaf_wrapper_util_audio.zig");
const olaf_wrapper_bridge = @import("olaf_wrapper_bridge.zig");

const debug = std.log.scoped(.olaf_wrapper_threading).debug;
const fs = std.fs;

// Shared action enum type
pub const ProcessAction = enum { Query, Store };

// Worker task structure for processing audio files
pub const AudioProcessTask = struct {
    allocator: std.mem.Allocator,
    audio_file: olaf_wrapper_util.AudioFileWithId,
    config: *const olaf_wrapper_config.Config,
    index: usize,
    total: usize,
    action: ProcessAction,
    error_mutex: *Mutex,
    error_list: *std.ArrayList([]const u8),
};

// Helper function to create a temporary raw audio file path
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

// Helper function to process an audio file and convert it to raw format
fn processAudioFile(
    allocator: std.mem.Allocator,
    audio_file_with_id: olaf_wrapper_util.AudioFileWithId,
    config: *const olaf_wrapper_config.Config,
    index: usize,
    total: usize,
    action: ProcessAction,
) !void {
    debug("Processing audio file {d}/{d}: {s}", .{ index + 1, total, audio_file_with_id.path });

    const raw_audio_path = try createTempRawPath(allocator);
    defer allocator.free(raw_audio_path);
    defer fs.cwd().deleteFile(raw_audio_path) catch {};

    try olaf_wrapper_util_audio.convertToRaw(allocator, audio_file_with_id.path, raw_audio_path, config.target_sample_rate);

    switch (action) {
        .Query => try olaf_wrapper_bridge.olaf_query(allocator, raw_audio_path, audio_file_with_id.identifier, config),
        .Store => try olaf_wrapper_bridge.olaf_store(allocator, raw_audio_path, audio_file_with_id.identifier, config),
    }
}

pub fn processAudioFileThreaded(task: AudioProcessTask) void {
    processAudioFile(
        task.allocator,
        task.audio_file,
        task.config,
        task.index,
        task.total,
        task.action,
    ) catch |process_err| {
        task.error_mutex.lock();
        defer task.error_mutex.unlock();

        const err_msg = std.fmt.allocPrint(task.allocator, "Failed to process {s}: {}", .{ task.audio_file.path, process_err }) catch "Out of memory";
        task.error_list.append(task.allocator, err_msg) catch {};
        std.log.err("{s}", .{err_msg});
    };
}

/// Execute audio processing in parallel using thread pool
pub fn executeParallel(
    allocator: std.mem.Allocator,
    audio_files: []const olaf_wrapper_util.AudioFileWithId,
    config: *const olaf_wrapper_config.Config,
    action: ProcessAction,
    num_threads: u32,
) !void {
    const actual_threads = @min(num_threads, audio_files.len);

    if (actual_threads <= 1) {
        // Single-threaded execution
        debug("Processing {d} audio files (single-threaded)", .{audio_files.len});
        for (audio_files, 0..) |audio_file, i| {
            try processAudioFile(allocator, audio_file, config, i, audio_files.len, action);
        }
    } else {
        // Multi-threaded execution
        debug("Processing {d} audio files with {d} threads", .{ audio_files.len, actual_threads });

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
            const task = AudioProcessTask{
                .allocator = allocator,
                .audio_file = audio_file,
                .config = config,
                .index = i,
                .total = audio_files.len,
                .action = action,
                .error_mutex = &error_mutex,
                .error_list = &error_list,
            };

            pool.spawnWg(&wait_group, processAudioFileThreaded, .{task});
        }

        pool.waitAndWork(&wait_group);

        if (error_list.items.len > 0) {
            return error.ProcessingFailed;
        }
    }
}

/// Process a single fragment of an audio file
fn processAudioFragment(
    allocator: std.mem.Allocator,
    audio_file_with_id: olaf_wrapper_util.AudioFileWithId,
    config: *const olaf_wrapper_config.Config,
    index: usize,
    total: usize,
    fragment_start: f32,
    fragment_duration: u32,
    action: ProcessAction,
) !void {
    _ = index;
    _ = total;
    debug("Processing fragment at {d}s for {d}s from {s}", .{ fragment_start, fragment_duration, audio_file_with_id.path });

    const raw_audio_path = try createTempRawPath(allocator);
    defer allocator.free(raw_audio_path);
    defer fs.cwd().deleteFile(raw_audio_path) catch {};

    // Convert the fragment to raw audio
    const options = olaf_wrapper_util_audio.AudioOptions{
        .sample_rate = config.target_sample_rate,
        .output_channels = 1,
        .output_format = "f32le",
        .output_codec = "pcm_f32le",
        .start = fragment_start,
        .duration = @floatFromInt(fragment_duration),
    };

    try olaf_wrapper_util_audio.convertAudioWithOptions(
        allocator,
        audio_file_with_id.path,
        raw_audio_path,
        options,
    );

    // Create identifier with fragment offset
    const fragment_identifier = try std.fmt.allocPrint(
        allocator,
        "{s}@{d}",
        .{ audio_file_with_id.identifier, fragment_start },
    );
    defer allocator.free(fragment_identifier);

    switch (action) {
        .Query => try olaf_wrapper_bridge.olaf_query(allocator, raw_audio_path, fragment_identifier, config),
        .Store => try olaf_wrapper_bridge.olaf_store(allocator, raw_audio_path, fragment_identifier, config),
    }
}

/// Execute fragmented audio processing in parallel
pub fn executeFragmentedParallel(
    allocator: std.mem.Allocator,
    audio_files: []const olaf_wrapper_util.AudioFileWithId,
    config: *const olaf_wrapper_config.Config,
    action: ProcessAction,
    num_threads: u32,
    fragment_duration: u32,
    allow_identity_match: bool,
) !void {
    _ = allow_identity_match; // TODO: Implement identity match filtering

    debug("Processing {d} audio files in fragments of {d}s with {d} threads", .{ audio_files.len, fragment_duration, num_threads });

    for (audio_files, 0..) |audio_file, file_index| {
        // Get the total duration of the audio file
        const total_duration = try olaf_wrapper_util_audio.getAudioDuration(allocator, audio_file.path);

        var fragment_start: f32 = 0.0;
        var fragment_index: usize = 0;

        while (fragment_start < total_duration) {
            const remaining = total_duration - fragment_start;
            const current_duration = @min(@as(f32, @floatFromInt(fragment_duration)), remaining);

            if (num_threads <= 1) {
                try processAudioFragment(
                    allocator,
                    audio_file,
                    config,
                    file_index,
                    audio_files.len,
                    fragment_start,
                    fragment_duration,
                    action,
                );
            } else {
                // TODO: Implement parallel fragment processing with thread pool
                try processAudioFragment(
                    allocator,
                    audio_file,
                    config,
                    file_index,
                    audio_files.len,
                    fragment_start,
                    fragment_duration,
                    action,
                );
            }

            fragment_start += current_duration;
            fragment_index += 1;
        }
    }
}
