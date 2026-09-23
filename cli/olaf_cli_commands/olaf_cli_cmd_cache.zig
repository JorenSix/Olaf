const std = @import("std");

const olaf_cli_config = @import("../olaf_cli_config.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const olaf_cli_core = @import("../olaf_cli_core.zig");
const olaf_cli_session = @import("../olaf_cli_session.zig");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");
const types = @import("../olaf_cli_types.zig");

const debug = std.log.scoped(.olaf_cli_cache).debug;
const Io = std.Io;

const CacheCtx = struct {
    io: Io,
    config: *const olaf_cli_config.Config,
    /// -f: re-cache files that already have a cache entry.
    force: bool,
};

pub const CommandInfo = struct {
    pub const name = "cache";
    pub const description = "Extracts fingerprints and caches them in text files for later storage.\n\t\t-f, --force\t Re-cache files that are already cached.\n\t\t--threads n\t The number of threads to use for parallel extraction.";
    pub const help = "[-f] [--threads n] audio_files...";
    pub const needs_audio_files = true;
    pub const flags = &[_]types.Flag{ .threads, .force, .with_ids };
};

const print = olaf_cli_util.print;

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to cache.\n", .{});
        return;
    }

    if (args.threads == 1) {
        debug("Warning: only using a single thread. Speed up with e.g. --threads 8\n", .{});
    }

    const error_count = try olaf_cli_threading.forEachParallel(
        olaf_cli_util.AudioFileWithId,
        CacheCtx,
        args.io,
        allocator,
        args.audio_files.items,
        args.threads,
        .{ .io = args.io, .config = args.config.?, .force = args.force },
        cacheWorker,
        olaf_cli_threading.audioFileLabel,
    );

    if (error_count > 0) {
        return error.ProcessingFailed;
    }
}

fn cacheWorker(ctx: CacheCtx, audio_file: olaf_cli_util.AudioFileWithId, index: usize, total: usize, allocator: std.mem.Allocator) !void {
    try cacheAudioFile(ctx.io, allocator, audio_file, ctx.config, ctx.force, index, total);
}

fn cacheAudioFile(
    io: Io,
    allocator: std.mem.Allocator,
    audio_file: olaf_cli_util.AudioFileWithId,
    config: *const olaf_cli_config.Config,
    force: bool,
    index: usize,
    total: usize,
) !void {
    debug("Caching audio file {d}/{d}: {s}", .{ index + 1, total, audio_file.path });

    // Get audio identifier (hash)
    const audio_id = olaf_cli_core.nameToId(audio_file.identifier);

    // Create cache file path
    const cache_folder_expanded = try olaf_cli_util.expandPath(allocator, config.home, config.cache_folder);
    defer allocator.free(cache_folder_expanded);

    // Ensure cache folder exists
    Io.Dir.cwd().createDirPath(io, cache_folder_expanded) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    const cache_file_path = try std.fmt.allocPrint(allocator, "{s}/{d}.tdb", .{ cache_folder_expanded, audio_id });
    defer allocator.free(cache_file_path);

    const meta_file_path = try std.fmt.allocPrint(allocator, "{s}/{d}.meta", .{ cache_folder_expanded, audio_id });
    defer allocator.free(meta_file_path);

    // Already cached: both files are only ever renamed into place when
    // complete (below), so their presence means a finished entry.
    const complete = blk: {
        Io.Dir.cwd().access(io, cache_file_path, .{}) catch break :blk false;
        Io.Dir.cwd().access(io, meta_file_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (complete and !force) {
        print("{d}/{d}, {s}, {s}, SKIPPED: cache file already present\n", .{ index + 1, total, audio_file.path, cache_file_path });
        return;
    }

    const raw = try olaf_cli_threading.TempRaw.create(io, allocator, audio_file.path, config, null);
    defer raw.deinit();

    // Write <name>.part files and rename them into place when complete, so
    // an interrupted run (Ctrl-C, kill) never leaves a partial entry that
    // later runs would skip as "already present". The .meta goes first: a
    // .tdb then always has its .meta.
    const cache_part = try std.fmt.allocPrint(allocator, "{s}.part", .{cache_file_path});
    defer allocator.free(cache_part);
    const meta_part = try std.fmt.allocPrint(allocator, "{s}.part", .{meta_file_path});
    defer allocator.free(meta_part);
    errdefer Io.Dir.cwd().deleteFile(io, cache_part) catch {};
    errdefer Io.Dir.cwd().deleteFile(io, meta_part) catch {};

    try olaf_cli_session.cacheToFiles(allocator, raw.path, audio_file.identifier, config, cache_part, meta_part);
    try Io.Dir.cwd().rename(meta_part, Io.Dir.cwd(), meta_file_path, io);
    try Io.Dir.cwd().rename(cache_part, Io.Dir.cwd(), cache_file_path, io);

    print("{d}/{d}, {s}, {s}\n", .{ index + 1, total, audio_file.path, cache_file_path });
}

