//! Everything the CLI does with the Olaf C core: one runner/stream-processor
//! lifecycle (`Session.run`) and the store / query / delete / cache
//! operations built on it, plus read-only database access. Only the public
//! core API (src/*.h) is used.
const std = @import("std");
const Io = std.Io;
const debug = std.log.scoped(.olaf_cli_session).debug;

const core = @import("olaf_cli_core.zig");
const c = core.c;
const output = @import("olaf_cli_output.zig");
const olaf_cli_config = @import("olaf_cli_config.zig");
const olaf_cli_util = @import("olaf_cli_util.zig");

const Config = olaf_cli_config.Config;

pub const Match = output.Match;

/// Per-file processing statistics reported by the stream processor.
pub const RunStats = struct {
    audio_seconds: f64,
    cpu_seconds: f64,
    fingerprints: usize,
};

pub const Mode = enum(c_int) {
    query = c.OLAF_RUNNER_MODE_QUERY,
    store = c.OLAF_RUNNER_MODE_STORE,
    delete = c.OLAF_RUNNER_MODE_DELETE,
    cache = c.OLAF_RUNNER_MODE_CACHE,
};

// ---------------------------------------------------------------------------
// Match sink: the core reports matches through a plain C callback without a
// user-data pointer, so the destination lives in a thread-local. The callback
// runs synchronously inside olaf_stream_processor_process on the same thread.
// ---------------------------------------------------------------------------

pub const Sink = struct {
    /// Drop matches against this id (self-matches in dedup); 0 = keep all.
    exclude: u32 = 0,
    target: union(enum) {
        /// Print CSV rows as they are reported (the matchCount == 0 "no
        /// results" row too, so every query has an end marker).
        print: output.QueryInfo,
        /// Collect real matches (paths copied into `allocator`).
        collect: struct { allocator: std.mem.Allocator, list: *std.ArrayList(Match) },
    },
    err: ?anyerror = null,
    /// Whether a CSV row was printed (see `query`).
    printed: bool = false,
};

threadlocal var current_sink: ?*Sink = null;

fn resultCallback(
    match_count: c_int,
    query_start: f32,
    query_stop: f32,
    path: [*c]const u8,
    match_identifier: u32,
    reference_start: f32,
    reference_stop: f32,
) callconv(.c) void {
    const sink = current_sink orelse return;
    if (sink.exclude != 0 and match_count > 0 and match_identifier == sink.exclude) return;
    const m = Match{
        .match_count = match_count,
        .query_start = query_start,
        .query_stop = query_stop,
        .path = if (path) |p| std.mem.span(p) else "",
        .match_identifier = match_identifier,
        .reference_start = reference_start,
        .reference_stop = reference_stop,
    };
    switch (sink.target) {
        .print => |q| {
            output.writeMatchRow(q, m);
            sink.printed = true;
        },
        .collect => |col| {
            if (match_count == 0) return; // the "no results" sentinel
            var owned = m;
            owned.path = col.allocator.dupe(u8, m.path) catch |e| {
                sink.err = e;
                return;
            };
            col.list.append(col.allocator, owned) catch |e| {
                col.allocator.free(owned.path);
                sink.err = e;
            };
        },
    }
}

pub fn freeMatches(allocator: std.mem.Allocator, matches: []Match) void {
    for (matches) |m| allocator.free(m.path);
    allocator.free(matches);
}

// ---------------------------------------------------------------------------
// Session: C config + the single runner / stream processor lifecycle
// ---------------------------------------------------------------------------

pub const RunOptions = struct {
    /// CACHE mode output files; ownership passes to the core, which closes
    /// them (also when the audio cannot be opened, see `run`).
    cache_files: ?struct { fingerprints: *c.FILE, meta: *c.FILE } = null,
    sink: ?*Sink = null,
    /// CSV header the core prints before each block of results.
    header: ?[:0]const u8 = null,
    /// Suppress the core's human-readable summary line on stderr.
    suppress_summary: bool = false,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    config: core.CoreConfig,

    pub fn init(allocator: std.mem.Allocator, config: *const Config) !Session {
        return .{ .allocator = allocator, .config = try core.CoreConfig.init(allocator, config) };
    }

    pub fn deinit(self: *Session) void {
        self.config.deinit();
    }

    /// Run one stream processor over `raw_path` (null = stdin).
    pub fn run(self: *Session, mode: Mode, raw_path: ?[]const u8, identifier: []const u8, opts: RunOptions) !RunStats {
        const files = opts.cache_files;
        // Until the core's file writer takes the cache files over (inside
        // processing), they are ours to close on any early failure.
        var own_files = files != null;
        errdefer if (own_files) {
            _ = c.fclose(files.?.meta);
            _ = c.fclose(files.?.fingerprints);
        };
        const c_raw = if (raw_path) |p| try self.allocator.dupeZ(u8, p) else null;
        defer if (c_raw) |p| self.allocator.free(p);
        const c_id = try self.allocator.dupeZ(u8, identifier);
        defer self.allocator.free(c_id);

        const runner = c.olaf_runner_new(@intFromEnum(mode), self.config.ptr, if (files) |f| f.fingerprints else null, if (files) |f| f.meta else null) orelse return core.constructorError(error.CoreInitializationFailed);
        defer c.olaf_runner_destroy(runner);

        // (The file writer that would close the cache files is only created
        // while processing, so the errdefer above closes them here too.)
        const processor = c.olaf_stream_processor_new(runner, if (c_raw) |p| p.ptr else null, c_id.ptr) orelse return core.constructorError(error.AudioOpenFailed);
        defer c.olaf_stream_processor_destroy(processor);

        if (opts.sink != null) c.olaf_stream_processor_set_result_callback(processor, resultCallback);
        if (opts.header) |h| c.olaf_stream_processor_set_result_header(processor, h.ptr);
        if (opts.suppress_summary) c.olaf_stream_processor_set_suppress_summary(processor, true);

        const previous = current_sink;
        current_sink = opts.sink;
        defer current_sink = previous;
        own_files = false; // closed by the core's file writer from here on
        c.olaf_stream_processor_process(processor);
        if (opts.sink) |s| if (s.err) |e| return e;

        return .{
            .audio_seconds = c.olaf_stream_processor_audio_duration(processor),
            .cpu_seconds = c.olaf_stream_processor_cpu_time(processor),
            .fingerprints = c.olaf_stream_processor_total_fingerprints(processor),
        };
    }

    /// Create the database when there is none yet, so the read-only env of a
    /// query never meets a missing data file (which exit()s in C). An
    /// existing database is left alone: queries need only read access.
    fn ensureDb(self: *Session) !void {
        if (try core.dbExists(self.allocator, self.config.db_folder)) return;
        c.olaf_db_destroy(c.olaf_db_new(self.config.db_folder.ptr, false));
    }
};

fn openCacheFiles(fingerprints_path: [:0]const u8, meta_path: [:0]const u8) !@FieldType(RunOptions, "cache_files") {
    const fp = c.fopen(fingerprints_path.ptr, "w") orelse return error.CacheFileOpenFailed;
    const meta = c.fopen(meta_path.ptr, "w") orelse {
        _ = c.fclose(fp);
        return error.CacheFileOpenFailed;
    };
    return .{ .fingerprints = fp, .meta = meta };
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

pub const StoreResult = struct {
    internal_id: u32,
    stats: RunStats,
};

/// Store one audio file, in three phases so that `store --threads N` runs the
/// expensive part in parallel:
///
/// 1. Extract without a database. A STORE-mode runner opens the LMDB env up
///    front, holding LMDB's writer transaction until the runner is destroyed,
///    which would serialize every worker's FFT and hashing. A CACHE-mode
///    runner never opens the DB; it writes to a temporary .tdb file instead.
/// 2. Parse the .tdb into LMDB keys/values, still unlocked.
/// 3. Begin a write transaction in the shared DB environment, store the data,
///    commit.
///
/// The stored keys, values and meta-data are exactly what the STORE-mode
/// path writes (see the equivalence test below). Prints nothing.
pub fn store(allocator: std.mem.Allocator, raw_audio_path: []const u8, identifier: []const u8, config: *const Config) !StoreResult {
    var session = try Session.init(allocator, config);
    defer session.deinit();

    // Resolve the identifier to its on-disk numeric id (the number itself for
    // --with-ids 173050, else hash(identifier)); query results report the
    // same value as match_identifier.
    const internal_id = core.nameToId(identifier);

    // Phase 1: extract into <raw>.tdb / <raw>.meta (no DB, no lock).
    const io = olaf_cli_util.defaultIo();
    // Report unreadable audio as such, before creating the cache files next to it.
    Io.Dir.cwd().access(io, raw_audio_path, .{}) catch return error.AudioOpenFailed;

    const tdb_path = try std.fmt.allocPrintSentinel(allocator, "{s}.tdb", .{raw_audio_path}, 0);
    defer allocator.free(tdb_path);
    defer Io.Dir.cwd().deleteFile(io, tdb_path) catch {};
    const meta_path = try std.fmt.allocPrintSentinel(allocator, "{s}.meta", .{raw_audio_path}, 0);
    defer allocator.free(meta_path);
    defer Io.Dir.cwd().deleteFile(io, meta_path) catch {};

    const run_stats = try session.run(.cache, raw_audio_path, identifier, .{
        .cache_files = try openCacheFiles(tdb_path, meta_path),
        .suppress_summary = true,
    });

    // Phase 2: parse the cached fingerprints (still unlocked).
    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(allocator);
    var values: std.ArrayList(u64) = .empty;
    defer values.deinit(allocator);
    try parseCachedFingerprints(allocator, io, tdb_path, internal_id, &keys, &values);

    // Phase 3: writers serialize per database, including LMDB cross-process locking.
    // olaf_db_destroy commits before releasing the environment reference.
    const db = c.olaf_db_new(session.config.db_folder.ptr, false);
    defer c.olaf_db_destroy(db);
    writeFingerprints(db, keys.items, values.items, identifier, @floatCast(run_stats.audio_seconds), @intCast(run_stats.fingerprints));

    return .{ .internal_id = internal_id, .stats = run_stats };
}

/// Store fingerprints and the meta-data of one audio file: exactly what the
/// STORE-mode stream processor writes (same batch size as the core writer).
fn writeFingerprints(db: ?*c.Olaf_DB, keys: []u64, values: []u64, identifier: []const u8, duration: f32, fingerprints: i64) void {
    const chunk: usize = 1 << 12;
    var off: usize = 0;
    while (off < keys.len) : (off += chunk) {
        const n = @min(chunk, keys.len - off);
        c.olaf_db_store(db, keys[off..].ptr, values[off..].ptr, n);
    }

    var meta: c.Olaf_Resource_Meta_data = std.mem.zeroes(c.Olaf_Resource_Meta_data);
    meta.duration = duration;
    meta.fingerprints = @intCast(fingerprints);
    const path_len = @min(identifier.len, meta.path.len - 1);
    @memcpy(meta.path[0..path_len], identifier[0..path_len]);
    var key: u32 = core.nameToId(identifier);
    c.olaf_db_store_meta_data(db, &key, &meta);
}

/// Read a fingerprint cache file written by the CACHE-mode file writer
/// (header line, then "hash, t1, f1, m1, ..." per fingerprint) into LMDB
/// keys/values, encoded exactly like olaf_fp_db_writer_store:
/// key = hash, value = (t1 << 32) + audio_id.
fn parseCachedFingerprints(
    allocator: std.mem.Allocator,
    io: Io,
    tdb_path: []const u8,
    audio_id: u32,
    keys: *std.ArrayList(u64),
    values: *std.ArrayList(u64),
) !void {
    const content = try Io.Dir.cwd().readFileAlloc(io, tdb_path, allocator, .unlimited);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // header: "fp_hash, t1, f1, m1, ..."
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, ',');
        const hash_str = std.mem.trim(u8, cols.next() orelse return error.MalformedCacheFile, " \t\r");
        const t1_str = std.mem.trim(u8, cols.next() orelse return error.MalformedCacheFile, " \t\r");
        const hash = std.fmt.parseInt(u64, hash_str, 10) catch return error.MalformedCacheFile;
        const t1 = std.fmt.parseInt(u64, t1_str, 10) catch return error.MalformedCacheFile;
        try keys.append(allocator, hash);
        try values.append(allocator, (t1 << 32) + audio_id);
    }
}

/// Query one raw audio file, printing CSV rows (as they are reported) or one
/// JSON object per query to stdout.
pub fn query(
    allocator: std.mem.Allocator,
    info: output.QueryInfo,
    raw_audio_path: []const u8,
    identifier: []const u8,
    config: *const Config,
    exclude_identifier: u32,
    format: output.OutputFormat,
) !void {
    var session = try Session.init(allocator, config);
    defer session.deinit();
    try session.ensureDb();

    switch (format) {
        .csv => {
            var sink = Sink{ .exclude = exclude_identifier, .target = .{ .print = info } };
            _ = try session.run(.query, raw_audio_path, identifier, .{ .sink = &sink, .header = output.query_csv_header });
            // The core only sends its "no results" row when there are no
            // matches at all; when every match was a filtered self-match the
            // query would otherwise leave no row (no end marker) at all.
            if (!sink.printed) output.writeMatchRow(info, .{
                .match_count = 0,
                .query_start = 0,
                .query_stop = 0,
                .path = "",
                .match_identifier = 0,
                .reference_start = 0,
                .reference_stop = 0,
            });
        },
        .json => {
            var list: std.ArrayList(Match) = .empty;
            defer {
                for (list.items) |m| allocator.free(m.path);
                list.deinit(allocator);
            }
            var sink = Sink{ .exclude = exclude_identifier, .target = .{ .collect = .{ .allocator = allocator, .list = &list } } };
            const run_stats = try session.run(.query, raw_audio_path, identifier, .{ .sink = &sink, .suppress_summary = true });
            try output.writeQueryJson(allocator, info, .{
                .fingerprints = run_stats.fingerprints,
                .audio_seconds = run_stats.audio_seconds,
                .cpu_seconds = run_stats.cpu_seconds,
            }, list.items);
        },
    }
}

/// Query raw f32le PCM arriving on this process's stdin, printing CSV rows
/// live. The identifier must be "stdin": the core only prints its live
/// "Time: …s fps: …" progress line to stderr for that name.
pub fn queryStdin(allocator: std.mem.Allocator, query_path: []const u8, config: *const Config) !void {
    var session = try Session.init(allocator, config);
    defer session.deinit();
    session.config.applyLiveStreamDefaults();
    try session.ensureDb();

    var sink = Sink{ .target = .{ .print = .{ .index = 0, .total = 1, .path = query_path, .offset = 0 } } };
    _ = try session.run(.query, null, "stdin", .{ .sink = &sink, .header = output.query_csv_header });
}

/// Query and return the matches instead of printing them (TUI). Caller frees
/// with `freeMatches`.
pub fn queryCollect(allocator: std.mem.Allocator, raw_audio_path: []const u8, identifier: []const u8, config: *const Config, exclude_identifier: u32) ![]Match {
    var session = try Session.init(allocator, config);
    defer session.deinit();
    try session.ensureDb();

    var list: std.ArrayList(Match) = .empty;
    errdefer {
        for (list.items) |m| allocator.free(m.path);
        list.deinit(allocator);
    }
    var sink = Sink{ .exclude = exclude_identifier, .target = .{ .collect = .{ .allocator = allocator, .list = &list } } };
    _ = try session.run(.query, raw_audio_path, identifier, .{ .sink = &sink, .suppress_summary = true });
    return list.toOwnedSlice(allocator);
}

pub const DeleteResult = union(enum) {
    /// Deleted; the number of fingerprints removed.
    deleted: usize,
    not_indexed,
    no_database,
};

/// Whether `identifier` can be deleted. Both other outcomes must be caught
/// before the core runs: opening a missing database, or deleting a resource
/// that is not indexed (MDB_NOTFOUND), makes it exit() mid-batch.
pub fn deleteStatus(allocator: std.mem.Allocator, identifier: []const u8, config: *const Config) !DeleteResult {
    var db = try ReadDb.open(allocator, config) orelse return .no_database;
    defer db.close();
    return if (db.isStored(identifier)) .{ .deleted = 0 } else .not_indexed;
}

pub fn delete(allocator: std.mem.Allocator, raw_audio_path: []const u8, identifier: []const u8, config: *const Config) !DeleteResult {
    const status = try deleteStatus(allocator, identifier, config);
    if (status != .deleted) return status;
    var session = try Session.init(allocator, config);
    defer session.deinit();
    const stats_ = try session.run(.delete, raw_audio_path, identifier, .{ .suppress_summary = true });
    return .{ .deleted = stats_.fingerprints };
}

/// Extract fingerprints into a cache file pair (`olaf cache`).
pub fn cacheToFiles(allocator: std.mem.Allocator, raw_audio_path: []const u8, identifier: []const u8, config: *const Config, fingerprints_path: []const u8, meta_path: []const u8) !void {
    var session = try Session.init(allocator, config);
    defer session.deinit();
    const fp_z = try allocator.dupeZ(u8, fingerprints_path);
    defer allocator.free(fp_z);
    const meta_z = try allocator.dupeZ(u8, meta_path);
    defer allocator.free(meta_z);
    // The command prints its own line per file; the core's summary would
    // be a second one, on the other stream.
    _ = try session.run(.cache, raw_audio_path, identifier, .{ .cache_files = try openCacheFiles(fp_z, meta_z), .suppress_summary = true });
}

/// What a `.meta` file written by `olaf cache` records: the identifier (as
/// `path=`), the exact duration and the fingerprint count.
pub const CacheMeta = struct {
    identifier: []u8,
    duration: f32,
    fingerprints: i64,
};

/// Parse a `.meta` file; null when it has no `path=` entry. Caller owns
/// `identifier`.
pub fn readCacheMeta(io: Io, allocator: std.mem.Allocator, meta_path: []const u8) !?CacheMeta {
    const content = try Io.Dir.cwd().readFileAlloc(io, meta_path, allocator, .limited(64 * 1024));
    defer allocator.free(content);

    var path: ?[]const u8 = null;
    var duration: f32 = 0;
    var fingerprints: i64 = 0;
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const key = line[0..eq];
        if (std.mem.eql(u8, key, "path")) {
            path = value;
        } else if (std.mem.eql(u8, key, "duration")) {
            duration = std.fmt.parseFloat(f32, value) catch return error.MalformedCacheFile;
        } else if (std.mem.eql(u8, key, "fingerprints")) {
            fingerprints = std.fmt.parseInt(i64, value, 10) catch return error.MalformedCacheFile;
        }
    }
    const p = path orelse return null;
    if (p.len == 0) return null;
    return .{ .identifier = try allocator.dupe(u8, p), .duration = duration, .fingerprints = fingerprints };
}

pub const CachedFile = struct {
    cache_path: []const u8,
    meta: CacheMeta,
};

/// Store cache files written by `olaf cache` (`olaf store_cached`), in one
/// database session, with the same content `olaf store` would write: the
/// fingerprints from the `.tdb` and the exact duration and count from the
/// `.meta`. (The core's cache writer is not used: it stores the `.tdb` header
/// line as a fingerprint and approximates the duration.)
///
/// `results[i]` receives the error for entry i (null = stored). A malformed
/// cache file is parsed before anything is written, so it is skipped whole
/// and the other entries are still stored.
pub fn storeCachedFiles(allocator: std.mem.Allocator, entries: []const CachedFile, config: *const Config, results: []?anyerror) !void {
    std.debug.assert(results.len == entries.len);
    var session = try Session.init(allocator, config);
    defer session.deinit();
    const io = olaf_cli_util.defaultIo();

    const db = c.olaf_db_new(session.config.db_folder.ptr, false);
    defer c.olaf_db_destroy(db);

    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(allocator);
    var values: std.ArrayList(u64) = .empty;
    defer values.deinit(allocator);
    for (entries, results) |entry, *result| {
        keys.clearRetainingCapacity();
        values.clearRetainingCapacity();
        parseCachedFingerprints(allocator, io, entry.cache_path, core.nameToId(entry.meta.identifier), &keys, &values) catch |err| {
            result.* = err;
            continue;
        };
        writeFingerprints(db, keys.items, values.items, entry.meta.identifier, entry.meta.duration, entry.meta.fingerprints);
        result.* = null;
    }
}

// ---------------------------------------------------------------------------
// Read-only database access
// ---------------------------------------------------------------------------

/// Aggregated database statistics.
pub const Stats = struct {
    song_count: u32,
    total_duration: f32,
    total_fingerprints: i64,
};

/// Metadata for a stored resource, looked up by numeric audio id.
pub const ResourceMeta = struct {
    duration: f32,
    fingerprints: i64,
    path: []const u8,
};

/// A read-only database handle. `open` returns null when there is no
/// database yet (a read-only open of a missing database exit()s in C).
pub const ReadDb = struct {
    session: Session,
    db: *c.Olaf_DB,

    pub fn open(allocator: std.mem.Allocator, config: *const Config) !?ReadDb {
        if (!try core.dbExists(allocator, config.db_folder)) return null;
        var session = try Session.init(allocator, config);
        errdefer session.deinit();
        const db = c.olaf_db_new(session.config.db_folder.ptr, true) orelse return error.DatabaseOpenFailed;
        return .{ .session = session, .db = db };
    }

    pub fn close(self: *ReadDb) void {
        c.olaf_db_destroy(self.db);
        self.session.deinit();
    }

    pub fn isStored(self: *ReadDb, identifier: []const u8) bool {
        var key = core.nameToId(identifier);
        return c.olaf_db_has_meta_data(self.db, &key);
    }

    /// Metadata for `id`, or null. Caller owns `path`.
    pub fn meta(self: *ReadDb, allocator: std.mem.Allocator, id: u32) !?ResourceMeta {
        var key = id;
        if (!c.olaf_db_has_meta_data(self.db, &key)) return null;
        var m: c.Olaf_Resource_Meta_data = undefined;
        c.olaf_db_find_meta_data(self.db, &key, &m);
        return .{
            .duration = m.duration,
            .fingerprints = @intCast(m.fingerprints),
            .path = try allocator.dupe(u8, std.mem.sliceTo(&m.path, 0)),
        };
    }

    pub fn stats(self: *ReadDb) Stats {
        const s = c.olaf_db_stats_struct(self.db);
        return .{ .song_count = s.song_count, .total_duration = s.total_duration, .total_fingerprints = @intCast(s.total_fingerprints) };
    }

    /// The core's human-readable statistics on stdout (`olaf stats`).
    pub fn printStats(self: *ReadDb, include_files: bool) void {
        c.olaf_db_print_stats(self.db, include_files);
    }
};

/// Check the database before any worker starts, and create it when missing.
/// LMDB failures inside the core call exit() (src/olaf_db.c), which would
/// abort a parallel batch midway without cleanup, so the common causes are
/// reported here, cleanly, instead:
/// - with `create`, a missing database is created once, on this thread
///   (parallel queries on a fresh index would otherwise race to create it);
///   `delete` passes false: there is nothing to delete from a missing one;
/// - the folder and the data/lock files must be writable. The bundled LMDB
///   opens a write-only descriptor on data.mdb even to read, so this holds
///   for queries too.
/// Failures that cannot be foreseen (e.g. a disk filling up mid-run) still
/// end in the core's exit().
pub fn prepareDb(allocator: std.mem.Allocator, config: *const Config, create: bool) !void {
    const io = olaf_cli_util.defaultIo();
    const folder = config.db_folder;
    Io.Dir.cwd().access(io, folder, .{ .write = true }) catch |err| {
        std.log.err("database folder '{s}' is not writable ({})", .{ folder, err });
        return error.DatabaseNotWritable;
    };
    for ([_][]const u8{ "data.mdb", "lock.mdb" }) |name| {
        const path = try std.fs.path.join(allocator, &.{ folder, name });
        defer allocator.free(path);
        Io.Dir.cwd().access(io, path, .{ .read = true, .write = true }) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                std.log.err("database file '{s}' is not readable and writable ({}); the bundled LMDB needs write access even to query", .{ path, err });
                return error.DatabaseNotWritable;
            },
        };
    }
    if (!create) return;
    var session = try Session.init(allocator, config);
    defer session.deinit();
    try session.ensureDb();
}

/// For each identifier, whether it is already indexed. Caller owns the slice.
pub fn storedFlags(allocator: std.mem.Allocator, config: *const Config, identifiers: []const []const u8) ![]bool {
    const flags = try allocator.alloc(bool, identifiers.len);
    errdefer allocator.free(flags);
    @memset(flags, false);
    if (identifiers.len == 0) return flags;
    var db = try ReadDb.open(allocator, config) orelse return flags;
    defer db.close();
    for (identifiers, flags) |identifier, *flag| flag.* = db.isStored(identifier);
    return flags;
}

/// Database statistics; zeros when there is no database yet.
pub fn stats(allocator: std.mem.Allocator, config: *const Config) !Stats {
    var db = try ReadDb.open(allocator, config) orelse return .{ .song_count = 0, .total_duration = 0, .total_fingerprints = 0 };
    defer db.close();
    return db.stats();
}

/// Metadata for `id`; null when unknown or there is no database yet.
pub fn lookupMeta(allocator: std.mem.Allocator, config: *const Config, id: u32) !?ResourceMeta {
    var db = try ReadDb.open(allocator, config) orelse return null;
    defer db.close();
    return db.meta(allocator, id);
}

/// `olaf stats`: the core's statistics, or zeros when there is no database.
pub fn printStats(allocator: std.mem.Allocator, config: *const Config, include_files: bool) !void {
    var db = try ReadDb.open(allocator, config) orelse {
        olaf_cli_util.print("Number of songs (#):\t0\nTotal duration (s):\t0.0\nAvg prints/s (fp/s):\t0.0\n", .{});
        return;
    };
    defer db.close();
    db.printStats(include_files);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "session calls report a raw audio file that cannot be opened" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);
    const db_folder = try std.fmt.allocPrint(allocator, "{s}/", .{tmp_path});
    defer allocator.free(db_folder);

    const config = Config{ .db_folder = db_folder };
    const missing = "/nonexistent/olaf_missing_audio.raw";
    const info = output.QueryInfo{ .index = 0, .total = 1, .path = "missing", .offset = 0 };

    try std.testing.expectError(error.AudioOpenFailed, store(allocator, missing, "missing", &config));
    try std.testing.expectError(error.AudioOpenFailed, query(allocator, info, missing, "missing", &config, 0, .csv));
    try std.testing.expectError(error.AudioOpenFailed, query(allocator, info, missing, "missing", &config, 0, .json));
    // Not indexed: nothing to delete, so the (missing) audio is never read.
    try std.testing.expectEqual(DeleteResult.not_indexed, try delete(allocator, missing, "missing", &config));

    // The cache files are opened (and must be closed) before the audio fails.
    const tdb = try std.fmt.allocPrint(allocator, "{s}1.tdb", .{db_folder});
    defer allocator.free(tdb);
    const meta = try std.fmt.allocPrint(allocator, "{s}1.meta", .{db_folder});
    defer allocator.free(meta);
    try std.testing.expectError(error.AudioOpenFailed, cacheToFiles(allocator, missing, "missing", &config, tdb, meta));

    // Unopenable cache path: fails cleanly without touching the core.
    try std.testing.expectError(error.CacheFileOpenFailed, cacheToFiles(allocator, missing, "missing", &config, "/nonexistent/dir/1.tdb", meta));
    try std.testing.expectError(error.CacheFileOpenFailed, cacheToFiles(allocator, missing, "missing", &config, tdb, "/nonexistent/dir/1.meta"));
}

test "cache writes every fingerprint from a 20 second dataset excerpt" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ref = "dataset/ref/11266.mp3";
    Io.Dir.cwd().access(io, ref, .{}) catch return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const raw = try std.fs.path.join(allocator, &.{ dir, "ref.raw" });
    defer allocator.free(raw);
    const tdb = try std.fs.path.join(allocator, &.{ dir, "ref.tdb" });
    defer allocator.free(tdb);
    const meta_path = try std.fs.path.join(allocator, &.{ dir, "ref.meta" });
    defer allocator.free(meta_path);
    ffmpegToRaw(allocator, io, ref, raw, &.{ "-t", "20" }) catch return error.SkipZigTest;
    try cacheToFiles(allocator, raw, ref, &Config{}, tdb, meta_path);
    const meta = (try readCacheMeta(io, allocator, meta_path)).?;
    defer allocator.free(meta.identifier);
    const content = try Io.Dir.cwd().readFileAlloc(io, tdb, allocator, .unlimited);
    defer allocator.free(content);
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    _ = lines.next(); // CSV header
    var rows: i64 = 0;
    var latest: u64 = 0;
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, ',');
        _ = cols.next(); // hash
        const t1 = try std.fmt.parseInt(u64, std.mem.trim(u8, cols.next().?, " \t"), 10);
        latest = @max(latest, t1);
        rows += 1;
    }
    errdefer std.debug.print("\nEOF cache: metadata={d}, rows={d}, latest anchor={d:.3}s\n", .{
        meta.fingerprints, rows, @as(f64, @floatFromInt(latest)) * 128 / 16000,
    });
    try std.testing.expect(rows > 0);
    try std.testing.expectEqual(meta.fingerprints, rows);
}

test "three-phase store preserves tail matches from a 20 second dataset excerpt" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const ref = "dataset/ref/11266.mp3";
    Io.Dir.cwd().access(io, ref, .{}) catch return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const raw = try std.fmt.allocPrint(allocator, "{s}/ref.raw", .{tmp_path});
    defer allocator.free(raw);
    const cut = try std.fmt.allocPrint(allocator, "{s}/cut.raw", .{tmp_path});
    defer allocator.free(cut);
    // Plain ffmpeg calls: importing olaf_cli_util_audio would add nothing here.
    ffmpegToRaw(allocator, io, ref, raw, &.{ "-t", "20" }) catch return error.SkipZigTest; // no ffmpeg
    const samples = try Io.Dir.cwd().readFileAlloc(io, raw, allocator, .unlimited);
    defer allocator.free(samples);
    try std.testing.expectEqual(@as(usize, 20 * 16000 * 4), samples.len);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = cut, .data = samples[12 * 16000 * 4 ..] });

    const db_a = try std.fmt.allocPrint(allocator, "{s}/a/", .{tmp_path});
    defer allocator.free(db_a);
    const db_b = try std.fmt.allocPrint(allocator, "{s}/b/", .{tmp_path});
    defer allocator.free(db_b);
    try Io.Dir.cwd().createDirPath(io, db_a);
    try Io.Dir.cwd().createDirPath(io, db_b);
    const config_a = Config{ .db_folder = db_a };
    const config_b = Config{ .db_folder = db_b };

    const id = "/music/reference.mp3";
    {
        // Direct STORE-mode path: the core's own fingerprint DB writer.
        var session = try Session.init(allocator, &config_a);
        defer session.deinit();
        _ = try session.run(.store, raw, id, .{ .suppress_summary = true });
    }
    _ = try store(allocator, raw, id, &config_b); // three-phase path

    const internal_id = core.nameToId(id);
    const meta_a = (try lookupMeta(allocator, &config_a, internal_id)).?;
    defer allocator.free(meta_a.path);
    const meta_b = (try lookupMeta(allocator, &config_b, internal_id)).?;
    defer allocator.free(meta_b.path);
    try std.testing.expectEqual(meta_a.duration, meta_b.duration);
    try std.testing.expectEqual(meta_a.fingerprints, meta_b.fingerprints);
    try std.testing.expectEqualStrings(meta_a.path, meta_b.path);

    // Query the tail, where the final extraction batch contributes matches.
    const matches_a = try queryCollect(allocator, cut, "cut", &config_a, 0);
    defer freeMatches(allocator, matches_a);
    const matches_b = try queryCollect(allocator, cut, "cut", &config_b, 0);
    defer freeMatches(allocator, matches_b);
    errdefer std.debug.print("\nEOF matches: direct={any}\ncache-backed={any}\n", .{ matches_a, matches_b });
    try std.testing.expect(matches_a.len > 0);
    try std.testing.expectEqual(matches_a.len, matches_b.len);
    for (matches_a, matches_b) |ma, mb| {
        try std.testing.expectEqual(ma.match_identifier, mb.match_identifier);
        try std.testing.expectEqual(ma.match_count, mb.match_count);
        try std.testing.expectEqual(ma.query_start, mb.query_start);
        try std.testing.expectEqual(ma.query_stop, mb.query_stop);
        try std.testing.expectEqual(ma.reference_start, mb.reference_start);
        try std.testing.expectEqual(ma.reference_stop, mb.reference_stop);
    }
}

fn ffmpegToRaw(allocator: std.mem.Allocator, io: Io, input: []const u8, output_path: []const u8, extra: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "ffmpeg", "-hide_banner", "-y", "-loglevel", "error", "-i", input });
    try argv.appendSlice(allocator, extra);
    try argv.appendSlice(allocator, &.{ "-ac", "1", "-ar", "16000", "-f", "f32le", "-acodec", "pcm_f32le", output_path });
    const r = try std.process.run(allocator, io, .{ .argv = argv.items });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) return error.FFmpegFailed;
}
