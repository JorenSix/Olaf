//! Running work over many audio files: one bounded-parallel executor
//! (`forEachParallel`), the per-file audio jobs built on it (store / query /
//! delete, plain or fragmented), the to_raw/to_wav transcode jobs, and the
//! shared temp-raw-audio and fragment helpers.
const std = @import("std");
const Io = std.Io;

const olaf_cli_config = @import("olaf_cli_config.zig");
const olaf_cli_util = @import("olaf_cli_util.zig");
const olaf_cli_util_audio = @import("olaf_cli_util_audio.zig");
const olaf_cli_core = @import("olaf_cli_core.zig");
const olaf_cli_output = @import("olaf_cli_output.zig");
const olaf_cli_session = @import("olaf_cli_session.zig");

const Config = olaf_cli_config.Config;
const AudioFileWithId = olaf_cli_util.AudioFileWithId;

const debug = std.log.scoped(.olaf_cli_threading).debug;

// ---------------------------------------------------------------------------
// Temp raw audio and fragments
// ---------------------------------------------------------------------------

// Process-local counter so two workers never land on the same temp path; the
// thread id in the name is only for debugging.
var temp_path_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// Directory under which temp raw audio is written; set once at startup from
// $TMPDIR / $TEMP / $TMP (see olaf_cli.zig) before any worker runs.
var temp_root: []const u8 = "/tmp";

pub fn setTempRoot(dir: []const u8) void {
    temp_root = dir;
}

fn createTempRawPath(io: Io, allocator: std.mem.Allocator) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ temp_root, "olaf_raw_audio_cache" });
    defer allocator.free(dir);
    Io.Dir.cwd().createDirPath(io, dir) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };
    const seq = temp_path_counter.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(allocator, "{s}/olaf_audio_{d}_{d}.raw", .{ dir, std.Thread.getCurrentId(), seq });
}

/// Raw f32le mono audio decoded (by ffmpeg) into a unique temp file, deleted
/// again by `deinit`. `start`/`duration` select a fragment (seconds).
pub const TempRaw = struct {
    path: []u8,
    io: Io,
    allocator: std.mem.Allocator,

    pub fn create(io: Io, allocator: std.mem.Allocator, input: []const u8, config: *const Config, fragment: ?Fragment) !TempRaw {
        const path = try createTempRawPath(io, allocator);
        errdefer allocator.free(path);
        errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
        try olaf_cli_util_audio.convertAudioWithOptions(allocator, io, input, path, .{
            .sample_rate = config.target_sample_rate,
            .start = if (fragment) |f| f.start else null,
            .duration = if (fragment) |f| f.length else null,
        });
        return .{ .path = path, .io = io, .allocator = allocator };
    }

    pub fn deinit(self: TempRaw) void {
        Io.Dir.cwd().deleteFile(self.io, self.path) catch |err| debug("Could not delete temp file {s}: {}", .{ self.path, err });
        self.allocator.free(self.path);
    }
};

pub const Fragment = struct { start: f32, length: f32 };

/// Consecutive fragments of `step` seconds covering `total` seconds; the last
/// one is shorter when `total` is not a multiple of `step`.
pub const FragmentIterator = struct {
    total: f32,
    step: f32,
    next_start: f32 = 0,

    pub fn next(self: *FragmentIterator) ?Fragment {
        if (self.next_start >= self.total) return null;
        const f = Fragment{ .start = self.next_start, .length = @min(self.step, self.total - self.next_start) };
        self.next_start += f.length;
        return f;
    }
};

/// Fragments of `step_seconds` over `total` seconds. A step of 0 would never
/// advance: that is a config error.
pub fn fragments(total: f32, step_seconds: u32) !FragmentIterator {
    if (step_seconds == 0) {
        std.log.err("config: 'fragment_duration_in_seconds' must be > 0", .{});
        return error.InvalidConfigValue;
    }
    return .{ .total = total, .step = @floatFromInt(step_seconds) };
}

// ---------------------------------------------------------------------------
// The executor
// ---------------------------------------------------------------------------

/// Run `worker(ctx, item, index, total, allocator)` over every item, serially
/// when `num_threads <= 1`, otherwise concurrently (bounded to `num_threads`).
/// Either way every item is attempted, and a failure is logged as
/// "Failed to process <label(item)>: <error>" and counted. Returns the number
/// of failures (0 = all succeeded).
///
/// The worker owns its own output synchronization (an uncontended mutex lock
/// is a no-op when serial).
pub fn forEachParallel(
    comptime Item: type,
    comptime Ctx: type,
    io: Io,
    allocator: std.mem.Allocator,
    items: []const Item,
    num_threads: u32,
    ctx: Ctx,
    comptime worker: fn (Ctx, Item, usize, usize, std.mem.Allocator) anyerror!void,
    comptime label: fn (Item) []const u8,
) !usize {
    const actual_threads = @min(num_threads, items.len);

    if (actual_threads <= 1) {
        var failures: usize = 0;
        for (items, 0..) |item, i| {
            worker(ctx, item, i, items.len, allocator) catch |err| {
                failures += 1;
                std.log.err("Failed to process {s}: {}", .{ label(item), err });
            };
        }
        return failures;
    }

    var sem: Io.Semaphore = .{ .permits = actual_threads };
    var error_mutex: Io.Mutex = .init;
    var error_count: usize = 0;

    const Runner = struct {
        fn run(r_io: Io, c: Ctx, item: Item, index: usize, total: usize, alloc: std.mem.Allocator, s: *Io.Semaphore, m: *Io.Mutex, count: *usize) void {
            s.waitUncancelable(r_io);
            defer s.post(r_io);
            worker(c, item, index, total, alloc) catch |err| {
                m.lockUncancelable(r_io);
                defer m.unlock(r_io);
                count.* += 1;
                std.log.err("Failed to process {s}: {}", .{ label(item), err });
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

pub fn audioFileLabel(f: AudioFileWithId) []const u8 {
    return f.path;
}

// ---------------------------------------------------------------------------
// Audio jobs: store / query / delete one file (a query optionally fragmented)
// ---------------------------------------------------------------------------

pub const ProcessAction = enum { Query, Store, Delete };

const AudioJob = struct {
    io: Io,
    config: *const Config,
    action: ProcessAction,
    output_format: olaf_cli_output.OutputFormat,
    store_format: olaf_cli_output.StoreFormat,
    /// Drop matches against the query's own identifier (dedup).
    filter_identity: bool,
    /// Query in fragments of this many seconds instead of the whole file.
    fragment_seconds: ?u32 = null,
};

fn audioWorker(job: AudioJob, file: AudioFileWithId, index: usize, total: usize, allocator: std.mem.Allocator) !void {
    debug("Processing audio file {d}/{d}: {s}", .{ index + 1, total, file.path });
    const exclude: u32 = if (job.filter_identity) olaf_cli_core.nameToId(file.identifier) else 0;

    if (job.fragment_seconds) |step| {
        var it = try fragments(try olaf_cli_util_audio.getAudioDuration(allocator, job.io, file.path), step);
        while (it.next()) |fragment| {
            const raw = try TempRaw.create(job.io, allocator, file.path, job.config, fragment);
            defer raw.deinit();
            try olaf_cli_session.query(allocator, .{ .index = index, .total = total, .path = file.path, .offset = fragment.start }, raw.path, file.identifier, job.config, exclude, job.output_format);
        }
        return;
    }

    const raw = try TempRaw.create(job.io, allocator, file.path, job.config, null);
    defer raw.deinit();
    switch (job.action) {
        .Query => try olaf_cli_session.query(allocator, .{ .index = index, .total = total, .path = file.path, .offset = 0 }, raw.path, file.identifier, job.config, exclude, job.output_format),
        .Store => {
            const r = try olaf_cli_session.store(allocator, raw.path, file.identifier, job.config);
            try olaf_cli_output.writeStoreSummary(job.store_format, .{
                .index = index,
                .total = total,
                .audio_identifier = file.identifier,
                .internal_id = r.internal_id,
                .fingerprints = r.stats.fingerprints,
                .audio_seconds = r.stats.audio_seconds,
                .cpu_seconds = r.stats.cpu_seconds,
            });
        },
        .Delete => try olaf_cli_session.delete(allocator, raw.path, file.identifier, job.config),
    }
}

fn runAudioJob(io: Io, allocator: std.mem.Allocator, files: []const AudioFileWithId, num_threads: u32, job: AudioJob) !void {
    try olaf_cli_session.prepareDb(allocator, job.config, job.action != .Delete);
    const failures = try forEachParallel(AudioFileWithId, AudioJob, io, allocator, files, num_threads, job, audioWorker, audioFileLabel);
    if (failures > 0) return error.ProcessingFailed;
}

/// Store, query or delete every file. When `allow_identity_match` is false
/// and the action is `.Query`, matches against a file's own identifier are
/// dropped (used by dedup).
pub fn executeParallel(
    io: Io,
    allocator: std.mem.Allocator,
    audio_files: []const AudioFileWithId,
    config: *const Config,
    action: ProcessAction,
    num_threads: u32,
    allow_identity_match: bool,
    output_format: olaf_cli_output.OutputFormat,
    store_format: olaf_cli_output.StoreFormat,
) !void {
    try runAudioJob(io, allocator, audio_files, num_threads, .{
        .io = io,
        .config = config,
        .action = action,
        .output_format = output_format,
        .store_format = store_format,
        .filter_identity = action == .Query and !allow_identity_match,
    });
}

/// Query every file in consecutive fragments of `fragment_duration` seconds;
/// each result reports its fragment start as query_offset. Files run in
/// parallel, the fragments of one file in order.
pub fn executeFragmentedQuery(
    io: Io,
    allocator: std.mem.Allocator,
    audio_files: []const AudioFileWithId,
    config: *const Config,
    num_threads: u32,
    fragment_duration: u32,
    allow_identity_match: bool,
    output_format: olaf_cli_output.OutputFormat,
) !void {
    // Validate once up front rather than failing every file.
    _ = try fragments(0, fragment_duration);
    try runAudioJob(io, allocator, audio_files, num_threads, .{
        .io = io,
        .config = config,
        .action = .Query,
        .output_format = output_format,
        .store_format = .human,
        .filter_identity = !allow_identity_match,
        .fragment_seconds = fragment_duration,
    });
}

// ---------------------------------------------------------------------------
// Transcode jobs (to_raw / to_wav)
// ---------------------------------------------------------------------------

/// One `to_raw` / `to_wav` conversion. `input_abs` is only used to detect an
/// output that would overwrite its own input; `col1`/`col2` form the progress
/// line `index/total,col1,col2`.
pub const TranscodeJob = struct {
    input: []const u8,
    input_abs: []const u8,
    output: []const u8,
    col1: []const u8,
    col2: []const u8,

    fn label(job: TranscodeJob) []const u8 {
        return job.input;
    }
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
    failures += try forEachParallel(TranscodeJob, TranscodeCtx, io, allocator, runnable.items, num_threads, ctx, transcodeWorker, TranscodeJob.label);
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

test "fragments cover the duration, the last one shorter" {
    var it = try fragments(65, 30);
    try std.testing.expectEqual(Fragment{ .start = 0, .length = 30 }, it.next().?);
    try std.testing.expectEqual(Fragment{ .start = 30, .length = 30 }, it.next().?);
    try std.testing.expectEqual(Fragment{ .start = 60, .length = 5 }, it.next().?);
    try std.testing.expectEqual(@as(?Fragment, null), it.next());
}
