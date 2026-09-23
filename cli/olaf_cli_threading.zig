const std = @import("std");
const Io = std.Io;

const olaf_cli_config = @import("olaf_cli_config.zig");
const olaf_cli_util = @import("olaf_cli_util.zig");
const olaf_cli_util_audio = @import("olaf_cli_util_audio.zig");
const olaf_cli_core = @import("olaf_cli_core.zig");
const olaf_cli_output = @import("olaf_cli_output.zig");
const olaf_cli_session = @import("olaf_cli_session.zig");

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
    output_format: olaf_cli_output.OutputFormat,
    store_format: olaf_cli_output.StoreFormat,
) !void {
    debug("Processing audio file {d}/{d}: {s}", .{ index + 1, total, audio_file_with_id.path });

    const raw_audio_path = try createTempRawPath(io, allocator);
    defer allocator.free(raw_audio_path);
    defer Io.Dir.cwd().deleteFile(io, raw_audio_path) catch |err| debug("Could not delete temp file {s}: {}", .{ raw_audio_path, err });

    try olaf_cli_util_audio.convertToRaw(allocator, io, audio_file_with_id.path, raw_audio_path, config.target_sample_rate);

    switch (action) {
        .Query => try olaf_cli_session.query(allocator, .{ .index = index, .total = total, .path = audio_file_with_id.path, .offset = 0 }, raw_audio_path, audio_file_with_id.identifier, config, exclude_identifier, output_format),
        .Store => {
            const r = try olaf_cli_session.store(allocator, raw_audio_path, audio_file_with_id.identifier, config);
            try olaf_cli_output.writeStoreSummary(store_format, .{
                .index = index,
                .total = total,
                .audio_identifier = audio_file_with_id.identifier,
                .internal_id = r.internal_id,
                .fingerprints = r.stats.fingerprints,
                .audio_seconds = r.stats.audio_seconds,
                .cpu_seconds = r.stats.cpu_seconds,
            });
        },
        .Delete => try olaf_cli_session.delete(allocator, raw_audio_path, audio_file_with_id.identifier, config),
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
    output_format: olaf_cli_output.OutputFormat,
    store_format: olaf_cli_output.StoreFormat,
) !void {
    const filter_identity = (action == .Query) and !allow_identity_match;
    const actual_threads = @min(num_threads, audio_files.len);

    if (actual_threads <= 1) {
        // Single-threaded execution. Same policy as the parallel path: a
        // failing file is logged and counted, the rest are still processed.
        debug("Processing {d} audio files (single-threaded, filter_identity={})", .{ audio_files.len, filter_identity });
        var failures: usize = 0;
        for (audio_files, 0..) |audio_file, i| {
            const exclude = if (filter_identity)
                olaf_cli_core.nameToId(audio_file.identifier)
            else
                @as(u32, 0);
            processAudioFile(io, allocator, audio_file, config, i, audio_files.len, action, exclude, output_format, store_format) catch |err| {
                failures += 1;
                std.log.err("Failed to process {s}: {}", .{ audio_file.path, err });
            };
        }
        if (failures > 0) return error.ProcessingFailed;
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
            out_fmt: olaf_cli_output.OutputFormat,
            store_fmt: olaf_cli_output.StoreFormat,
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
            olaf_cli_core.nameToId(audio_file.identifier)
        else
            @as(u32, 0);
        group.async(io, Runner.run, .{ io, allocator, audio_file, config, i, audio_files.len, action, exclude, output_format, store_format, &sem, &error_mutex, &error_count });
    }
    group.await(io) catch |err| std.log.err("Waiting for worker group failed: {}", .{err});

    if (error_count > 0) {
        return error.ProcessingFailed;
    }
}

/// Run `worker(ctx, item, index, total, allocator)` over every item, serially
/// when `num_threads <= 1`, otherwise concurrently (bounded to `num_threads`).
/// Either way worker errors are caught, logged, and counted, every item is
/// attempted, and the count is returned (0 = all succeeded). Callers map a
/// non-zero count to their own error and optional summary line.
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
        var failures: usize = 0;
        for (items, 0..) |item, i| {
            worker(ctx, item, i, items.len, allocator) catch |err| {
                failures += 1;
                std.log.err("Worker failed on item {d}/{d}: {}", .{ i + 1, items.len, err });
            };
        }
        return failures;
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

/// One `to_raw` / `to_wav` conversion. `input_abs` is only used to detect an
/// output that would overwrite its own input; `col1`/`col2` form the progress
/// line `index/total,col1,col2`.
pub const TranscodeJob = struct {
    input: []const u8,
    input_abs: []const u8,
    output: []const u8,
    col1: []const u8,
    col2: []const u8,
};

pub const ConvertFn = *const fn (std.mem.Allocator, Io, []const u8, []const u8, u32) anyerror!void;

const TranscodeCtx = struct {
    io: Io,
    convert: ConvertFn,
    sample_rate: u32,
    output_mutex: *Io.Mutex,
};

/// Shared driver for the transcoding commands. Rejects jobs whose output
/// would overwrite their input or an output already claimed by an earlier job
/// in this run (both used to be silently "skipped" as already converted),
/// then converts the rest. Returns the number of failed jobs.
pub fn runTranscodeJobs(
    io: Io,
    allocator: std.mem.Allocator,
    jobs: []const TranscodeJob,
    num_threads: u32,
    sample_rate: u32,
    convert: ConvertFn,
) !usize {
    var failures: usize = 0;
    var runnable: std.ArrayList(TranscodeJob) = .empty;
    defer runnable.deinit(allocator);

    var claimed: std.StringHashMap([]const u8) = .init(allocator);
    defer claimed.deinit();

    for (jobs) |job| {
        if (std.mem.eql(u8, job.output, job.input_abs)) {
            std.log.err("{s}: output would overwrite the input, skipping", .{job.input});
            failures += 1;
            continue;
        }
        const gop = try claimed.getOrPut(job.output);
        if (gop.found_existing) {
            std.log.err("{s}: output {s} is already produced by {s} in this run, skipping", .{ job.input, job.output, gop.value_ptr.* });
            failures += 1;
            continue;
        }
        gop.value_ptr.* = job.input;
        try runnable.append(allocator, job);
    }

    var output_mutex: Io.Mutex = .init;
    const ctx = TranscodeCtx{ .io = io, .convert = convert, .sample_rate = sample_rate, .output_mutex = &output_mutex };
    failures += try forEachParallel(TranscodeJob, TranscodeCtx, io, allocator, runnable.items, num_threads, ctx, transcodeWorker);
    return failures;
}

/// Skip the conversion if the output already exists (re-runs are cheap),
/// otherwise convert into `<output>.part` and rename it into place, so an
/// interrupted or failed ffmpeg run never leaves a partial output that a
/// later run would mistake for a finished one.
fn transcodeWorker(ctx: TranscodeCtx, job: TranscodeJob, index: usize, total: usize, allocator: std.mem.Allocator) !void {
    const io = ctx.io;
    if (Io.Dir.cwd().statFile(io, job.output, .{})) |_| {
        debug("Output already exists: {s}, skipping", .{job.output});
    } else |_| {
        const part = try std.fmt.allocPrint(allocator, "{s}.part", .{job.output});
        defer allocator.free(part);
        errdefer Io.Dir.cwd().deleteFile(io, part) catch {};
        try ctx.convert(allocator, io, job.input, part, ctx.sample_rate);
        try Io.Dir.cwd().rename(part, Io.Dir.cwd(), job.output, io);
    }

    // Uncontended no-op when single-threaded.
    ctx.output_mutex.lockUncancelable(io);
    defer ctx.output_mutex.unlock(io);
    olaf_cli_util.print("{d}/{d},{s},{s}\n", .{ index + 1, total, job.col1, job.col2 });
}

/// Query one fragment `[fragment_start, fragment_start + fragment_duration)`
/// of an audio file. The fragment start is reported as query_offset; match
/// times in the output are relative to it.
fn queryAudioFragment(
    io: Io,
    allocator: std.mem.Allocator,
    audio_file_with_id: olaf_cli_util.AudioFileWithId,
    config: *const olaf_cli_config.Config,
    index: usize,
    total: usize,
    fragment_start: f32,
    fragment_duration: f32,
    exclude_identifier: u32,
    output_format: olaf_cli_output.OutputFormat,
) !void {
    debug("Querying fragment at {d}s for {d}s from {s}", .{ fragment_start, fragment_duration, audio_file_with_id.path });

    const raw_audio_path = try createTempRawPath(io, allocator);
    defer allocator.free(raw_audio_path);
    defer Io.Dir.cwd().deleteFile(io, raw_audio_path) catch |err| debug("Could not delete temp file {s}: {}", .{ raw_audio_path, err });

    const options = olaf_cli_util_audio.AudioOptions{
        .sample_rate = config.target_sample_rate,
        .output_channels = 1,
        .output_format = "f32le",
        .output_codec = "pcm_f32le",
        .start = fragment_start,
        .duration = fragment_duration,
    };
    try olaf_cli_util_audio.convertAudioWithOptions(allocator, io, audio_file_with_id.path, raw_audio_path, options);

    try olaf_cli_session.query(allocator, .{ .index = index, .total = total, .path = audio_file_with_id.path, .offset = fragment_start }, raw_audio_path, audio_file_with_id.identifier, config, exclude_identifier, output_format);
}

/// Query each audio file in consecutive fragments of `fragment_duration`
/// seconds. Currently single-threaded: `num_threads` is accepted for API
/// symmetry but fragments are processed serially (parallelizing is a
/// deliberate follow-up).
pub fn executeFragmentedQuery(
    io: Io,
    allocator: std.mem.Allocator,
    audio_files: []const olaf_cli_util.AudioFileWithId,
    config: *const olaf_cli_config.Config,
    num_threads: u32,
    fragment_duration: u32,
    allow_identity_match: bool,
    output_format: olaf_cli_output.OutputFormat,
) !void {
    // A 0s fragment would never advance fragment_start: loop forever.
    if (fragment_duration == 0) {
        std.log.err("config: 'fragment_duration_in_seconds' must be > 0", .{});
        return error.InvalidConfigValue;
    }

    const filter_identity = !allow_identity_match;
    debug("Querying {d} audio files in fragments of {d}s with {d} threads (filter_identity={})", .{
        audio_files.len, fragment_duration, num_threads, filter_identity,
    });

    var failures: usize = 0;
    for (audio_files, 0..) |audio_file, file_index| {
        queryFragmentsOfFile(io, allocator, audio_file, config, file_index, audio_files.len, fragment_duration, filter_identity, output_format) catch |err| {
            failures += 1;
            std.log.err("Failed to process {s}: {}", .{ audio_file.path, err });
        };
    }
    if (failures > 0) return error.ProcessingFailed;
}

fn queryFragmentsOfFile(
    io: Io,
    allocator: std.mem.Allocator,
    audio_file: olaf_cli_util.AudioFileWithId,
    config: *const olaf_cli_config.Config,
    file_index: usize,
    total_files: usize,
    fragment_duration: u32,
    filter_identity: bool,
    output_format: olaf_cli_output.OutputFormat,
) !void {
    // Get the total duration of the audio file
    const total_duration = try olaf_cli_util_audio.getAudioDuration(allocator, io, audio_file.path);

    // Reference fingerprints are stored under the file identifier, so the
    // self-id is the hash of audio_file.identifier.
    const exclude = if (filter_identity)
        olaf_cli_core.nameToId(audio_file.identifier)
    else
        @as(u32, 0);

    var fragment_start: f32 = 0.0;
    while (fragment_start < total_duration) {
        const remaining = total_duration - fragment_start;
        const current_duration = @min(@as(f32, @floatFromInt(fragment_duration)), remaining);

        try queryAudioFragment(
            io,
            allocator,
            audio_file,
            config,
            file_index,
            total_files,
            fragment_start,
            current_duration,
            exclude,
            output_format,
        );

        fragment_start += current_duration;
    }
}
