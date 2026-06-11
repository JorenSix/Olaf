const std = @import("std");
const Io = std.Io;

const olaf_cli_config = @import("olaf_cli_config.zig");
const olaf_cli_util = @import("olaf_cli_util.zig");
const olaf_cli_util_audio = @import("olaf_cli_util_audio.zig");
const olaf_cli_bridge = @import("olaf_cli_bridge.zig");

const debug = std.log.scoped(.olaf_cli_threading).debug;

// Process-local monotonic counter so that two workers spawned in the same
// millisecond cannot land on the same temp path. The thread id in the
// filename is for human-readable debugging; uniqueness comes from the
// counter. We use std.Thread.getCurrentId rather than a pid because it is
// portable across POSIX and Windows targets (std.c.pid_t is undefined on
// non-POSIX targets).
var temp_path_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// Shared action enum type
pub const ProcessAction = enum { Query, Store, Delete };

// Helper function to create a temporary raw audio file path.
// Uses thread id + an atomic counter so concurrent callers never collide.
pub fn createTempRawPath(io: Io, allocator: std.mem.Allocator) ![]u8 {
    // The process environment is no longer globally accessible in 0.16, so we
    // no longer honor $TMPDIR here; the system temp dir is used unconditionally.
    const olaf_cache_dir = try std.fmt.allocPrint(allocator, "{s}olaf_raw_audio_cache", .{"/tmp/"});
    defer allocator.free(olaf_cache_dir);

    Io.Dir.cwd().createDirPath(io, olaf_cache_dir) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    const seq = temp_path_counter.fetchAdd(1, .monotonic);
    return try std.fmt.allocPrint(allocator, "{s}/olaf_audio_{d}_{d}.raw", .{ olaf_cache_dir, std.Thread.getCurrentId(), seq });
}

// Helper function to process an audio file and convert it to raw format
pub fn processAudioFile(
    io: Io,
    allocator: std.mem.Allocator,
    audio_file_with_id: olaf_cli_util.AudioFileWithId,
    config: *const olaf_cli_config.Config,
    index: usize,
    total: usize,
    action: ProcessAction,
    exclude_identifier: u32,
    output_format: olaf_cli_bridge.OutputFormat,
    store_format: olaf_cli_bridge.StoreFormat,
) !void {
    debug("Processing audio file {d}/{d}: {s}", .{ index + 1, total, audio_file_with_id.path });

    const raw_audio_path = try createTempRawPath(io, allocator);
    defer allocator.free(raw_audio_path);
    defer Io.Dir.cwd().deleteFile(io, raw_audio_path) catch |err| debug("Could not delete temp file {s}: {}", .{ raw_audio_path, err });

    try olaf_cli_util_audio.convertToRaw(allocator, io, audio_file_with_id.path, raw_audio_path, config.target_sample_rate);

    switch (action) {
        .Query => try olaf_cli_bridge.olaf_query(allocator, index, total, audio_file_with_id.path, raw_audio_path, audio_file_with_id.identifier, config, exclude_identifier, output_format),
        .Store => try olaf_cli_bridge.olaf_store(allocator, raw_audio_path, audio_file_with_id.identifier, config, index, total, store_format),
        .Delete => try olaf_cli_bridge.olaf_delete(allocator, raw_audio_path, audio_file_with_id.identifier, config),
    }
}

/// Execute audio processing in parallel using structured concurrency.
/// When `allow_identity_match` is false and the action is `.Query`, the
/// C-side print callback suppresses any result whose match_identifier
/// equals the query's own audio identifier hash (used by dedup).
pub fn executeParallel(
    io: Io,
    allocator: std.mem.Allocator,
    audio_files: []const olaf_cli_util.AudioFileWithId,
    config: *const olaf_cli_config.Config,
    action: ProcessAction,
    num_threads: u32,
    allow_identity_match: bool,
    output_format: olaf_cli_bridge.OutputFormat,
    store_format: olaf_cli_bridge.StoreFormat,
) !void {
    const filter_identity = (action == .Query) and !allow_identity_match;
    const actual_threads = @min(num_threads, audio_files.len);

    if (actual_threads <= 1) {
        // Single-threaded execution
        debug("Processing {d} audio files (single-threaded, filter_identity={})", .{ audio_files.len, filter_identity });
        for (audio_files, 0..) |audio_file, i| {
            const exclude = if (filter_identity)
                try olaf_cli_bridge.olaf_name_to_id(allocator, audio_file.identifier)
            else
                @as(u32, 0);
            try processAudioFile(io, allocator, audio_file, config, i, audio_files.len, action, exclude, output_format, store_format);
        }
        return;
    }

    // Multi-threaded execution bounded to `actual_threads` concurrent workers.
    debug("Processing {d} audio files with {d} threads", .{ audio_files.len, actual_threads });

    var sem: Io.Semaphore = .{ .permits = actual_threads };
    var error_mutex: Io.Mutex = .init;
    var error_count: usize = 0;

    const Runner = struct {
        fn run(
            r_io: Io,
            alloc: std.mem.Allocator,
            audio_file: olaf_cli_util.AudioFileWithId,
            cfg: *const olaf_cli_config.Config,
            index: usize,
            total: usize,
            act: ProcessAction,
            exclude: u32,
            out_fmt: olaf_cli_bridge.OutputFormat,
            store_fmt: olaf_cli_bridge.StoreFormat,
            s: *Io.Semaphore,
            m: *Io.Mutex,
            count: *usize,
        ) void {
            s.waitUncancelable(r_io);
            defer s.post(r_io);
            processAudioFile(r_io, alloc, audio_file, cfg, index, total, act, exclude, out_fmt, store_fmt) catch |err| {
                m.lockUncancelable(r_io);
                defer m.unlock(r_io);
                count.* += 1;
                std.log.err("Failed to process {s}: {}", .{ audio_file.path, err });
            };
        }
    };

    var group: Io.Group = .init;
    for (audio_files, 0..) |audio_file, i| {
        const exclude = if (filter_identity)
            try olaf_cli_bridge.olaf_name_to_id(allocator, audio_file.identifier)
        else
            @as(u32, 0);
        group.async(io, Runner.run, .{ io, allocator, audio_file, config, i, audio_files.len, action, exclude, output_format, store_format, &sem, &error_mutex, &error_count });
    }
    group.await(io) catch |err| std.log.err("Waiting for worker group failed: {}", .{err});

    if (error_count > 0) {
        return error.ProcessingFailed;
    }
}

/// Run `worker(ctx, item, index, total, allocator)` over every item. When
/// `num_threads <= 1` items run serially and the first worker error propagates
/// immediately. Otherwise items run concurrently (bounded to `num_threads`);
/// worker errors are caught, logged, and counted, and the count is returned
/// (0 = all succeeded). Callers map a non-zero count to their own error and
/// optional summary line.
///
/// The worker owns its own output synchronization. Serial execution is
/// single-threaded so no locking is needed; the same worker body is safe there
/// because an uncontended mutex lock is a no-op.
pub fn forEachParallel(
    comptime Item: type,
    comptime Ctx: type,
    io: Io,
    allocator: std.mem.Allocator,
    items: []const Item,
    num_threads: u32,
    ctx: Ctx,
    comptime worker: fn (Ctx, Item, usize, usize, std.mem.Allocator) anyerror!void,
) !usize {
    const actual_threads = @min(num_threads, items.len);

    if (actual_threads <= 1) {
        for (items, 0..) |item, i| {
            try worker(ctx, item, i, items.len, allocator);
        }
        return 0;
    }

    var sem: Io.Semaphore = .{ .permits = actual_threads };
    var error_mutex: Io.Mutex = .init;
    var error_count: usize = 0;

    const Runner = struct {
        fn run(
            r_io: Io,
            c: Ctx,
            item: Item,
            index: usize,
            total: usize,
            alloc: std.mem.Allocator,
            s: *Io.Semaphore,
            m: *Io.Mutex,
            count: *usize,
        ) void {
            s.waitUncancelable(r_io);
            defer s.post(r_io);
            worker(c, item, index, total, alloc) catch |err| {
                m.lockUncancelable(r_io);
                defer m.unlock(r_io);
                count.* += 1;
                std.log.err("Worker failed on item {d}/{d}: {}", .{ index + 1, total, err });
            };
        }
    };

    var group: Io.Group = .init;
    for (items, 0..) |item, i| {
        group.async(io, Runner.run, .{ io, ctx, item, i, items.len, allocator, &sem, &error_mutex, &error_count });
    }
    group.await(io) catch |err| std.log.err("Waiting for worker group failed: {}", .{err});
    return error_count;
}

/// Shared body for the `to_raw` / `to_wav` transcoding commands: skip the
/// conversion if `output_path` already exists, otherwise run `convert`, then
/// emit one mutex-guarded progress line `index/total,col1,col2`. The two
/// commands differ only in the convert fn and how they name the output, so
/// they compute `col1`/`col2`/`output_path` themselves and share this kernel.
pub fn transcodeAndReport(
    io: Io,
    allocator: std.mem.Allocator,
    convert: *const fn (std.mem.Allocator, Io, []const u8, []const u8, u32) anyerror!void,
    input_path: []const u8,
    output_path: []const u8,
    sample_rate: u32,
    index: usize,
    total: usize,
    col1: []const u8,
    col2: []const u8,
    output_mutex: *Io.Mutex,
) !void {
    if (Io.Dir.cwd().statFile(io, output_path, .{})) |_| {
        debug("Output already exists: {s}, skipping", .{output_path});
    } else |_| {
        try convert(allocator, io, input_path, output_path, sample_rate);
    }

    // Uncontended no-op when single-threaded.
    output_mutex.lockUncancelable(io);
    defer output_mutex.unlock(io);
    olaf_cli_util.print("{d}/{d},{s},{s}\n", .{ index + 1, total, col1, col2 });
}

/// Process a single fragment of an audio file
fn processAudioFragment(
    io: Io,
    allocator: std.mem.Allocator,
    audio_file_with_id: olaf_cli_util.AudioFileWithId,
    config: *const olaf_cli_config.Config,
    index: usize,
    total: usize,
    fragment_start: f32,
    fragment_duration: u32,
    action: ProcessAction,
    exclude_identifier: u32,
    output_format: olaf_cli_bridge.OutputFormat,
    store_format: olaf_cli_bridge.StoreFormat,
) !void {
    debug("Processing fragment at {d}s for {d}s from {s}", .{ fragment_start, fragment_duration, audio_file_with_id.path });

    const raw_audio_path = try createTempRawPath(io, allocator);
    defer allocator.free(raw_audio_path);
    defer Io.Dir.cwd().deleteFile(io, raw_audio_path) catch |err| debug("Could not delete temp file {s}: {}", .{ raw_audio_path, err });

    // Convert the fragment to raw audio
    const options = olaf_cli_util_audio.AudioOptions{
        .sample_rate = config.target_sample_rate,
        .output_channels = 1,
        .output_format = "f32le",
        .output_codec = "pcm_f32le",
        .start = fragment_start,
        .duration = @floatFromInt(fragment_duration),
    };

    try olaf_cli_util_audio.convertAudioWithOptions(
        allocator,
        io,
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
        .Query => try olaf_cli_bridge.olaf_query(allocator, index, total, audio_file_with_id.path, raw_audio_path, fragment_identifier, config, exclude_identifier, output_format),
        .Store => try olaf_cli_bridge.olaf_store(allocator, raw_audio_path, audio_file_with_id.identifier, config, index, total, store_format),
        .Delete => try olaf_cli_bridge.olaf_delete(allocator, raw_audio_path, fragment_identifier, config),
    }
}

/// Execute fragmented audio processing. Currently single-threaded; io is
/// threaded through so it compiles on 0.16. Parallelizing fragment processing
/// is a deliberate follow-up.
pub fn executeFragmentedParallel(
    io: Io,
    allocator: std.mem.Allocator,
    audio_files: []const olaf_cli_util.AudioFileWithId,
    config: *const olaf_cli_config.Config,
    action: ProcessAction,
    num_threads: u32,
    fragment_duration: u32,
    allow_identity_match: bool,
    output_format: olaf_cli_bridge.OutputFormat,
    store_format: olaf_cli_bridge.StoreFormat,
) !void {
    const filter_identity = (action == .Query) and !allow_identity_match;
    debug("Processing {d} audio files in fragments of {d}s with {d} threads (filter_identity={})", .{
        audio_files.len, fragment_duration, num_threads, filter_identity,
    });

    for (audio_files, 0..) |audio_file, file_index| {
        // Get the total duration of the audio file
        const total_duration = try olaf_cli_util_audio.getAudioDuration(allocator, io, audio_file.path);

        // Reference fingerprints are stored under the un-suffixed file
        // identifier, so the self-id is the hash of audio_file.identifier
        // (NOT the fragment identifier processAudioFragment constructs).
        const exclude = if (filter_identity)
            try olaf_cli_bridge.olaf_name_to_id(allocator, audio_file.identifier)
        else
            @as(u32, 0);

        var fragment_start: f32 = 0.0;
        var fragment_index: usize = 0;

        while (fragment_start < total_duration) {
            const remaining = total_duration - fragment_start;
            const current_duration = @min(@as(f32, @floatFromInt(fragment_duration)), remaining);

            // TODO: Implement parallel fragment processing
            try processAudioFragment(
                io,
                allocator,
                audio_file,
                config,
                file_index,
                audio_files.len,
                fragment_start,
                fragment_duration,
                action,
                exclude,
                output_format,
                store_format,
            );

            fragment_start += current_duration;
            fragment_index += 1;
        }
    }
}
